@echo off
rem fleet_smoke.cmd CLI - test/smoke/fleet_smoke.sh on native Windows, from cmd, PowerShell or an
rem ssh session (#357; the runbook is docs/windows-smoke.md). It runs the script through Git for
rem Windows' bash.exe by path: the bash.exe on the cmd PATH is WSL's (ADR 0001). A login shell, so
rem gh and claude are on PATH as in Git Bash; CHERE_INVOKING keeps it from cd-ing to HOME.
rem Env: HARNESS_BASH_EXE (Git's bin\bash.exe), SMOKE_BACKEND (default headless) and every SMOKE_*
rem fleet_smoke.sh reads.
setlocal
set "BASH_EXE=%HARNESS_BASH_EXE%"
if not defined BASH_EXE set "BASH_EXE=%ProgramFiles%\Git\bin\bash.exe"
if not exist "%BASH_EXE%" echo fleet_smoke.cmd: no Git bash.exe at "%BASH_EXE%" - install Git for Windows or set HARNESS_BASH_EXE 1>&2
if not exist "%BASH_EXE%" exit /b 2
if not defined SMOKE_BACKEND set "SMOKE_BACKEND=headless"
set "SCRIPT=%~dp0fleet_smoke.sh"
set "SCRIPT=%SCRIPT:\=/%"
set "CHERE_INVOKING=1"
"%BASH_EXE%" -l "%SCRIPT%" %*
exit /b %ERRORLEVEL%
