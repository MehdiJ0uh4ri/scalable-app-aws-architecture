<#
.SYNOPSIS
    Runs the automated pytest test suite and coverage reports on Windows 11.
#>

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$AppDir = Join-Path $ProjectRoot "application"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Executing Automated Test Suite & Coverage Analysis       " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

Set-Location $AppDir

$PythonExe = Join-Path $AppDir ".venv\Scripts\python.exe"
if (-not (Test-Path $PythonExe)) {
    $PythonExe = "python"
}

& $PythonExe -m pytest -v --tb=short --cov=app --cov-report=term-missing
