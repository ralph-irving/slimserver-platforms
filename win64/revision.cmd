@echo off
git rev-list --count HEAD | awk "{printf(\"r%%d\",$1)}" > revision.txt
git rev-parse --short HEAD | awk "{printf(\".%%s\r\n\",$1)}" >> revision.txt

git show --summary | grep "Date:" | awk "{printf(\"%%s %%s %%s %%s %%s\",$2,$3,$4,$5,$6)}" > DATE
set gitDate=< DATE
del DATE
gdate --date="%gitDate%" +%%s >> revision.txt
vim revision.txt -c "set viminfo= | set nobackup | set fileformat=unix | wq!"
