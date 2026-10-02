<#
.SYNOPSIS
    Validates Terraform configurations for the graduation project.
#>

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$TfDir = Join-Path $ProjectRoot "terraform"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Validating Terraform Infrastructure as Code Codebase    " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

Set-Location $TfDir

Write-Host "`n[*] Checking code formatting..." -ForegroundColor Yellow
terraform fmt -check -recursive

Write-Host "`n[*] Validating configuration syntax and resource definitions..." -ForegroundColor Yellow
terraform validate

Write-Host "`n[SUCCESS] Terraform configuration is clean and valid." -ForegroundColor Green
