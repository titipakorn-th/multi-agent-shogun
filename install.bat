@echo off
chcp 65001 >nul 2>&1
title multi-agent-shogun Installer

echo.
echo   +============================================================+
echo   ^|  [SHOGUN] multi-agent-shogun - WSL Installer                ^|
echo   ^|           WSL2 + Ubuntu Setup                              ^|
echo   +============================================================+
echo.

REM ===== Step 1: Check/Install WSL2 =====
echo   [1/2] Checking WSL2...

wsl.exe --version >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo   WSL2 not found. Installing automatically...
    echo.

    REM Check if running with Administrator privileges
    net session >nul 2>&1
    if %ERRORLEVEL% NEQ 0 (
        echo   +============================================================+
        echo   ^|  [WARN] Administrator privileges required!                 ^|
        echo   ^|         Administrator privileges required                  ^|
        echo   +============================================================+
        echo.
        echo   Right-click install.bat and select "Run as administrator"
        echo.
        pause
        exit /b 1
    )

    echo   Installing WSL2...
    powershell -Command "wsl --install --no-launch"

    echo.
    echo   +============================================================+
    echo   ^|  [!] Restart required!                                     ^|
    echo   ^|      System Restart required                               ^|
    echo   +============================================================+
    echo.
    echo   After restart, run install.bat again.
    echo.
    pause
    exit /b 0
)
echo   [OK] WSL2 OK
echo.

REM ===== Step 2: Check/Install Ubuntu =====
echo   [2/2] Checking Ubuntu...

REM Ubuntu check: use -d Ubuntu directly (avoids UTF-16LE pipe issue with findstr)
wsl.exe -d Ubuntu -- echo test >nul 2>&1
if %ERRORLEVEL% EQU 0 goto :ubuntu_ok

REM echo test failed - check if Ubuntu distro exists but needs initial setup
wsl.exe -d Ubuntu -- exit 0 >nul 2>&1
if %ERRORLEVEL% EQU 0 goto :ubuntu_needs_setup

REM Ubuntu not installed
echo.
echo   Ubuntu not found. Installing automatically...
echo.

powershell -Command "wsl --install -d Ubuntu --no-launch"

echo.
echo   +============================================================+
echo   ^|  [NOTE] Ubuntu installation started!                       ^|
echo   ^|         Ubuntu installation started                        ^|
echo   +============================================================+
echo.
echo   Restart your PC, then run install.bat again.
echo.
pause
exit /b 0

:ubuntu_needs_setup
REM Ubuntu exists but initial setup not completed
echo.
echo   +============================================================+
echo   ^|  [WARN] Ubuntu initial setup required!                     ^|
echo   ^|         Ubuntu initial setup required                      ^|
echo   +============================================================+
echo.
echo   1. Open Ubuntu from Start Menu
echo   2. Set your username and password
echo   3. Run install.bat again
echo.
pause
exit /b 1

:ubuntu_ok
echo   [OK] Ubuntu OK
echo.

REM Set Ubuntu as default WSL distribution
wsl --set-default Ubuntu

echo.
echo   +============================================================+
echo   ^|  [OK] WSL2 + Ubuntu ready!                                 ^|
echo   ^|       WSL2 + Ubuntu ready!                                 ^|
echo   +============================================================+
echo.
REM Get WSL home directory dynamically
FOR /F "tokens=*" %%i IN ('wsl -e bash -c "echo $HOME"') DO SET WSL_HOME=%%i

echo   +------------------------------------------------------------+
echo   ^|  [NEXT] Open Ubuntu and follow these steps:                ^|
echo   +------------------------------------------------------------+
echo   ^|                                                            ^|
echo   ^|  First time only:                                          ^|
echo   ^|    1. Set username and password when prompted              ^|
echo   ^|    2. cd %WSL_HOME%/multi-agent-shogun                      ^|
echo   ^|    3. ./first_setup.sh                                     ^|
echo   ^|                                                            ^|
echo   ^|  Every time you use:                                       ^|
echo   ^|    cd %WSL_HOME%/multi-agent-shogun                         ^|
echo   ^|    ./shutsujin_departure.sh                                ^|
echo   ^|                                                            ^|
echo   +------------------------------------------------------------+
echo.
pause
exit /b 0
