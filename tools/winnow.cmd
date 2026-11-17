@echo off
rem Winnow launcher for cmd.
rem   winnow               the space map; changes nothing
rem   winnow explain <id>  one item in detail
rem   winnow clean         remove every Clean item, after one yes
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0winnow.ps1" %*
endlocal
