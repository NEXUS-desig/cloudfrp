@echo off
chcp 65001 >nul
title CloudFRP - Web Panel
setlocal enabledelayedexpansion

:: ============================================================
::  CloudFRP Web Panel - unified launcher (Windows)
::  Starts the canonical backend: webpanel/server.py (Flask, :3592)
::  Optional: pass "frps" to also start the FRP server first.
::    start.bat          -> web panel only
::    start.bat frps     -> frps + web panel
:: ============================================================

set "BASE=%~dp0"
cd /d "%BASE%"

echo.
echo  ============================================
echo    CloudFRP Web Panel
echo  ============================================
echo.

:: ---- locate Python ------------------------------------------
set "PY="
where python >nul 2>&1 && set "PY=python"
if not defined PY (
    where py >nul 2>&1 && set "PY=py"
)
if not defined PY (
    if exist "%LOCALAPPDATA%\Programs\Python\Python314\python.exe" set "PY=%LOCALAPPDATA%\Programs\Python\Python314\python.exe"
)
if not defined PY (
    echo  [ERROR] Python not found. Install Python 3.8+ from https://python.org
    pause
    exit /b 1
)
for /f "delims=" %%v in ('%PY% --version 2^>^&1') do echo  [OK] %%v

:: ---- install deps if missing --------------------------------
%PY% -c "import flask,pymysql,dotenv,bcrypt,psutil,dbutils,waitress" >nul 2>&1
if errorlevel 1 (
    echo  [..] Installing dependencies ^(first run only^)...
    %PY% -m pip install --quiet Flask pymysql python-dotenv bcrypt psutil dbutils requests waitress
    if errorlevel 1 (
        echo  [ERROR] pip install failed. Check your network / Python setup.
        pause
        exit /b 1
    )
    echo  [OK] Dependencies installed
) else (
    echo  [OK] Dependencies present
)

:: ---- optional: FRP server -----------------------------------
if /i "%~1"=="frps" (
    if exist "frps.exe" (
        echo  [..] Starting FRP server ^(frps.exe^)...
        start "CloudFRP-frps" cmd /k "cd /d "%BASE%" && frps.exe -c frps.toml"
        timeout /t 2 >nul
    ) else (
        echo  [WARN] frps.exe not found, skipping FRP server
    )
)

:: ---- start web panel ----------------------------------------
echo.
echo  Panel:   http://localhost:3592
echo  Admin:   admin / yunwang
echo  Stop:    Ctrl+C in this window
echo  ============================================
echo.
cd /d "%BASE%webpanel"
%PY% -c "import waitress" >nul 2>&1
if errorlevel 1 (
    echo  [WARN] waitress not installed, using Flask dev server
    %PY% server.py
) else (
    echo  [OK] waitress (production WSGI server)
    %PY% -m waitress --listen=0.0.0.0:3592 --threads=8 server:app
)

echo.
echo  Panel exited.
pause
