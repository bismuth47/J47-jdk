# J47 MSI packaging / admin prerequisites (run from an elevated shell)
$ErrorActionPreference = "Continue"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$log = Join-Path $env:TEMP "j47_admin_tasks.log"
"admin=$(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))" | Out-File $log
Write-Host "=== NetFx3 enable ==="
DISM /Online /Enable-Feature /FeatureName:NetFx3 /All /NoRestart 2>&1 | Select-Object -Last 4 | Out-File $log -Append
Write-Host "=== WiX3 install ==="
winget install --id WiXToolset.WiXToolset --accept-source-agreements --disable-interactivity 2>&1 | Select-Object -Last 4 | Out-File $log -Append
Write-Host "=== verify ==="
Get-Command candle.exe,light.exe -ErrorAction SilentlyContinue | Select-Object Source | Out-File $log -Append
Get-WindowsOptionalFeature -Online -FeatureName NetFx3 | Select-Object FeatureName,State | Out-File $log -Append
Write-Host "ADMIN TASKS DONE"
