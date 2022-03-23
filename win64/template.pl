#! /usr/bin/env perl

use strict;
use warnings;

use utf8;

use Getopt::Long;

use File::Spec;

my $interpreter;
my $script;
my $cxx_compiler;
my $output;

GetOptions(
  "int|i=s" => \$interpreter,
  "script|s=s" => \$script,
  "cxx|c=s" => \$cxx_compiler,
  "output|o=s" => \$output,
);

sub escape_wide_string_literal {
   my ($contents) = @_;
   my $out = q[];
   $out .= 'L"';
   $out .= ($contents =~ s/([\"\\])/\\$1/gr);
   $out .= '"';
   return $out;
}

sub defined_and_nonempty {
   my ($x) = @_;
   return (defined $x) && ($x ne q[]);
}

die "need interpreter (--int|-i)" unless defined_and_nonempty($interpreter);
die "need script (--script|-s)" unless defined_and_nonempty($script);
die "need C++ compiler (--cxx|-c)" unless defined_and_nonempty($cxx_compiler);
die "need output file (--output|-o)" unless defined_and_nonempty($output);

die "interpreter must exist (--int|-i)" unless (-f $interpreter);
die "script must exist (--script|-s)" unless (-f $script);
die "C++ compiler must exist (--cxx|-c)" unless (-f $cxx_compiler);

die "intepreter must be absolute path (--int|-i)" unless (File::Spec->file_name_is_absolute($interpreter));
die "script should be relative path with no separators (.\\ is okay) (--script|-s)" if ($script =~ /\\/ and not $script =~ /\A[.][\\][^\\]*\z/);

my $cxx_template;
do {
    local $/;
    $cxx_template = <DATA>;
};
close(DATA);

die "internal error" unless defined $cxx_template;

my $interpreter_literal = escape_wide_string_literal($interpreter);
$cxx_template =~ s/%%%%INTERPETER_NAME%%%%/$interpreter_literal/g;

my $script_literal = escape_wide_string_literal($script);
$cxx_template =~ s/%%%%SCRIPT_NAME%%%%/$script_literal/g;

open my $fh, '>', "temp.cpp";
print $fh $cxx_template;
close($fh);

system($cxx_compiler, "-O2", "-s", "-o", $output, "temp.cpp");

die "did not create file" unless (-f $output);


__DATA__
// The strings in this file are UTF-16LE for compat with the win32 api
// The source code itself is in UTF-8.

#undef NDEBUG

#include <windows.h> // GetCommandLineW
#include <iostream> // wcout
#include <string> // wstring
#include <cassert> // assert
#include <utility> // pair
#include <deque> // deque, size_type

// always debug. Assert is only used when we actually want to
// crash the wrapper process.

// unsigned index type, probably good enough for traversing
// a vector or deque
typedef std::deque<char>::size_type uidx;

// interpreter_name must be absolute path
std::wstring interpreter_name = %%%%INTERPETER_NAME%%%% ;
std::wstring script_name = %%%%SCRIPT_NAME%%%% ;


class Reaper {
public:
    HANDLE job_handle;
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limit_info;

    Reaper() {
        job_handle = CreateJobObject(NULL, NULL);
        assert(job_handle != NULL);
        limit_info = { 0 };
        limit_info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        DWORD set_success = SetInformationJobObject(
            job_handle,
            JobObjectExtendedLimitInformation,
            &limit_info,
            sizeof(limit_info));
        assert(set_success);
    }
};


Reaper& get_reaper(void) {
    static Reaper r;
    return r;
}


// the leading int is the error code.
std::pair<DWORD, std::deque<std::wstring>> argvw_of_cmdline(std::wstring command_line) {
    LPCWSTR cmd_line = command_line.c_str();
    int count = 0;
    LPWSTR *the_processed_args = CommandLineToArgvW(
        cmd_line, &count
    );
    // first we handle the error case
    if (the_processed_args == nullptr) {
        return {GetLastError(), std::deque<std::wstring>()};
    } else {
        std::deque<std::wstring> s;
        for (int i = 0; i < count; ++i) {
            s.push_back(the_processed_args[i]);
        }
        return {0, s};
    }
}


std::wstring escape_string(std::wstring ws) {
    bool contains_suspect_char = (std::wstring::npos != ws.find_first_of(L"\"" L"\\"));
    if (contains_suspect_char) {
        std::wstring out(L"\"");
        for (uidx i = 0; i < ws.size(); ++i) {
            if (ws[i] == L'"' || ws[i] == L'\\') {
                out += L'\\';
                out += ws[i];
            } else {
                out += ws[i];
            }
        }
        out += L'"';
        return out;
    } else {
        return ws;
    }
}


std::wstring cmdline_of_argvw(const std::deque<std::wstring> &argvw) {
    std::wstring the_line(L"");
    // this is okay even if the deque is empty
    // because the loop will be traversed zero times.
    uidx last_index = argvw.size() - 1;
    for (uidx i = 0; i < argvw.size() ; i++) {
        the_line += escape_string(argvw[i]);
        if (i != last_index) {
            the_line += L' ';
        }
    }
    return the_line;
}


struct RawWinProcessCreatorW {
    LPCWSTR app_name = NULL;
    LPWSTR command_line = NULL;
    LPSECURITY_ATTRIBUTES process_attributes = NULL;
    LPSECURITY_ATTRIBUTES thread_attributes = NULL;
    BOOL inherit_handles = false;
    DWORD creation_flags = 0;
    LPVOID environment = NULL;
    LPCWSTR current_directory = NULL;
    LPSTARTUPINFOW startup_info = NULL;
    LPPROCESS_INFORMATION process_information = NULL;

    bool run() {
        return CreateProcessW(
            app_name,
            command_line,
            process_attributes,
            thread_attributes,
            inherit_handles,
            creation_flags,
            environment,
            current_directory,
            startup_info,
            process_information
        );
    }
};

std::wstring current_exe_directory(void) {
    HMODULE h_module = GetModuleHandleW(nullptr);
    WCHAR path[MAX_PATH];
    memset(path, 0, sizeof(path)); 
    GetModuleFileNameW(h_module, path, MAX_PATH);
    std::wstring w_path(path);
    // if the last character is a path separator
    // remove it.
    if (w_path.back() == L'\\') {
       w_path.pop_back();
    }
    // keep popping until the last character is a \     -- thwart line continuation
    while (!w_path.empty()) {
        if (w_path.back() == L'\\') {
            w_path.pop_back();
            return w_path;
        } else {
            w_path.pop_back();
        }
    }
    return w_path;
}

int main(int argc, char **argv)
{
    // Hide the console window for cleanup.pl
    if (script_name == L"cleanup.pl")
        ::ShowWindow(::GetConsoleWindow(), SW_HIDE);

    std::wstring exe_dir(current_exe_directory());
    std::wstring fullpath;
    fullpath += exe_dir;
    fullpath += std::wstring(L"\\");
    fullpath += script_name;

    std::wstring old_command_line(GetCommandLineW());
    std::pair<DWORD, std::deque<std::wstring>> p = argvw_of_cmdline(old_command_line);
    DWORD err = p.first;
    assert(err == 0);
    std::deque<std::wstring> split_cl = p.second;

    // remove old executable (it's the current one)
    split_cl.pop_front();
    // need to push interpreter_name and script_name.
    // but the order is reversed.
    split_cl.push_front(fullpath);
    split_cl.push_front(interpreter_name);
    
    std::wstring command_line = cmdline_of_argvw(split_cl);

    // Each environment variable must be NULL terminated.
    // Install path C:\Program Files\Squeezebox\server
    std::string envVars;
    envVars += "PERL5LIB=C:\\Program Files\\Squeezebox\\server;C:\\Program Files\\Squeezebox\\server\\lib";
    envVars += "SystemDrive=C:";
    envVars += '\0';
    envVars += "SystemRoot=C:\\Windows";
    envVars += '\0';
    envVars += "windir=C:\\Windows";
    envVars += '\0';
    envVars += "PATH=C:\\Strawberry\\c\\bin;C:\\Strawberry\\perl\\site\\bin;C:\\Strawberry\\perl\\bin;C:\\Windows\\System32;C:\\Windows;C:\\Windows\\System32\\Wbem";
    envVars += '\0';
    
    // make sure to zero-initialize these things.
    STARTUPINFOW si = { 0 };
    PROCESS_INFORMATION pi = { 0 };

    RawWinProcessCreatorW r;
    r.app_name = (interpreter_name.c_str());
    r.command_line = const_cast<LPWSTR>(command_line.c_str());
    r.environment = LPVOID(envVars.c_str());
    r.inherit_handles = true;
    r.startup_info = &si;
    r.process_information = &pi;
    r.creation_flags |= CREATE_SUSPENDED;

    bool success = r.run();
    assert(success);
    // DWORD last_error = GetLastError();

    // assign to the job object whatever.
    DWORD assign_status = AssignProcessToJobObject(
        get_reaper().job_handle,
        pi.hProcess
    );
    assert(assign_status);

    // resume the process.
    DWORD resume_status = ResumeThread(pi.hThread);

    // wait for the process we spawned.
    DWORD wait_res = WaitForSingleObject(pi.hProcess, INFINITE);

    assert(wait_res != WAIT_ABANDONED);
    assert(wait_res != WAIT_TIMEOUT);
    assert(wait_res != WAIT_FAILED);

    // after the process is gone, try to figure out whether it succeeded
    // and use that information when deciding how to exit yourself.
    // we're using 10, bad environment, as a sentinel.
    DWORD child_exit_status = 10;
    bool recover_exit_status_success = GetExitCodeProcess(
        pi.hProcess,
        &child_exit_status
    );

    assert(recover_exit_status_success);
    assert(child_exit_status != 10);

    return child_exit_status;
}
