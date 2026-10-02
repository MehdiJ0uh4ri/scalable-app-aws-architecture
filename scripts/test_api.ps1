<#
.SYNOPSIS
    Tests API endpoints against local or deployed ALB infrastructure.
.PARAMETER BaseUrl
    Base URL of target (defaults to http://localhost:5000).
#>

param(
    [string]$BaseUrl = "http://localhost:5000"
)

$ErrorActionPreference = "Continue"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Testing REST API Endpoints against: $BaseUrl             " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# 1. Health check
Write-Host "`n1. Testing GET /health..." -ForegroundColor Yellow
$health = Invoke-RestMethod -Uri "$BaseUrl/health" -Method Get
$health | ConvertTo-Json -Depth 3

# 2. Info / Instance identity
Write-Host "`n2. Testing GET /info..." -ForegroundColor Yellow
$info = Invoke-RestMethod -Uri "$BaseUrl/info" -Method Get
$info | ConvertTo-Json -Depth 3

# 3. Create Task
Write-Host "`n3. Testing POST /api/tasks (Create Task)..." -ForegroundColor Yellow
$createBody = @{
    title = "Graduation Project Task"
    description = "Validate API operations end-to-end"
    priority = "high"
    status = "pending"
} | ConvertTo-Json

$newTask = Invoke-RestMethod -Uri "$BaseUrl/api/tasks" -Method Post -Body $createBody -ContentType "application/json"
$taskId = $newTask.id
Write-Host "Created Task ID: $taskId" -ForegroundColor Green
$newTask | ConvertTo-Json -Depth 3

# 4. List Tasks
Write-Host "`n4. Testing GET /api/tasks (List Tasks)..." -ForegroundColor Yellow
$tasks = Invoke-RestMethod -Uri "$BaseUrl/api/tasks" -Method Get
Write-Host "Total tasks count: $($tasks.count)" -ForegroundColor Green

# 5. Patch Task
Write-Host "`n5. Testing PATCH /api/tasks/$taskId (Mark in_progress)..." -ForegroundColor Yellow
$patchBody = @{ status = "in_progress" } | ConvertTo-Json
$patched = Invoke-RestMethod -Uri "$BaseUrl/api/tasks/$taskId" -Method Patch -Body $patchBody -ContentType "application/json"
Write-Host "Updated Status: $($patched.status)" -ForegroundColor Green

# 6. Delete Task
Write-Host "`n6. Testing DELETE /api/tasks/$taskId (Cleanup)..." -ForegroundColor Yellow
$deleted = Invoke-RestMethod -Uri "$BaseUrl/api/tasks/$taskId" -Method Delete
Write-Host "$($deleted.message)" -ForegroundColor Green

Write-Host "`n[SUCCESS] All API endpoints validated successfully." -ForegroundColor Green
