@echo off
rem Winnow launcher - double-clickable, or run from cmd.
rem   winnow            guided flow
rem   winnow -Report    survey only, asks nothing
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0winnow.ps1" %*
endlocal
