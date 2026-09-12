@echo off
REM AI9 one-click installer launcher (Antonio G. Garcia // Otaconskeep)
REM Double-click this file. It finds/installs Git Bash, then runs install_ai9.sh.
setlocal enabledelayedexpansion
title AI9 Installer

set "SCRIPT_DIR=%~dp0"
set "BASH_EXE="

if exist "%ProgramFiles%\Git\bin\bash.exe" set "BASH_EXE=%ProgramFiles%\Git\bin\bash.exe"
if not defined BASH_EXE if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" set "BASH_EXE=%ProgramFiles(x86)%\Git\bin\bash.exe"
if not defined BASH_EXE (
    for /f "delims=" %%B in ('where bash.exe 2^>nul') do (
        if not defined BASH_EXE set "BASH_EXE=%%B"
    )
)

if not defined BASH_EXE (
    echo Git Bash was not found. Installing Git for Windows first...
    where winget.exe >nul 2>nul
    if errorlevel 1 (
        echo winget is not available on this PC.
        echo Please install Git for Windows manually from https://git-scm.com/download/win
        echo then double-click install_ai9.bat again.
        pause
        exit /b 1
    )
    winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements
    if exist "%ProgramFiles%\Git\bin\bash.exe" set "BASH_EXE=%ProgramFiles%\Git\bin\bash.exe"
)

if not defined BASH_EXE (
    echo Git was just installed but Git Bash is not visible in this window yet.
    echo Close this window, reopen it ^(or just double-click install_ai9.bat again^), and it will continue.
    pause
    exit /b 1
)

echo Launching the AI9 installer in Git Bash...
echo.
"%BASH_EXE%" -lc "cd \"$(cygpath -u '%SCRIPT_DIR%')\" && ./install_ai9.sh"

echo.
echo ============================================================
echo  AI9 installer finished. Review any messages above.
echo ============================================================
pause
