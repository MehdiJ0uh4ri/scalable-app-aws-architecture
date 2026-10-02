<#
.SYNOPSIS
    Starts the Flask Task Management application locally on Windows 11.
.DESCRIPTION
    Initializes the Python virtual environment if needed, installs dependencies,
    and starts the local Flask server on http://localhost:5000.
#>

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$AppDir = Join-Path $ProjectRoot "application"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Starting Task Manager Web Application (Local Dev Mode)  " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

Set-Location $AppDir

# Create virtual environment if it doesn't exist
$VenvDir = Join-Path $AppDir ".venv"
$PythonExe = Join-Path $VenvDir "Scripts\python.exe"

if (-not (Test-Path $PythonExe)) {
    Write-Host "[*] Creating virtual environment at .venv..." -ForegroundColor Yellow
    python -m venv .venv
}

# Ensure .env exists
$EnvFile = Join-Path $AppDir ".env"
$EnvExample = Join-Path $AppDir ".env.example"
if (-not (Test-Path $EnvFile)) {
    Write-Host "[*] Generating .env from .env.example..." -ForegroundColor Yellow
    Copy-Item $EnvExample $EnvFile
}

Write-Host "[*] Starting Flask application on http://localhost:5000..." -ForegroundColor Green
Write-Host "    Press Ctrl+C to stop.`n" -ForegroundColor Gray

& $PythonExe wsgi.py
