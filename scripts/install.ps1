# J47 JDK installer (no elevation required, user scope)
# usage:
#   powershell -ExecutionPolicy Bypass -File scripts\install.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\install.ps1 -Dest "D:\JDK\J47"
#   powershell -ExecutionPolicy Bypass -File scripts\install.ps1 -Zip "C:\dl\J47-JDK-21.zip"
# The ZIP is a build artefact and is NOT tracked in Git (see .gitignore). Point
# -Zip (or $env:J47_DIST_ZIP) at a release you downloaded from the Releases page.
param(
    [string]$Dest = "C:\tools\J47-JDK-21",
    [string]$Zip  = $(if ($env:J47_DIST_ZIP) { $env:J47_DIST_ZIP } else { Join-Path (Split-Path -Parent $PSScriptRoot) "dist\J47-JDK-21.zip" })
)
$ErrorActionPreference = "Stop"

if (!(Test-Path $Zip)) {
  throw "Distribution ZIP not found: $Zip`n" +
        "Download a release from the project's Releases page, or set `$env:J47_DIST_ZIP," +
        " or pass -Zip <path>."
}
if (Test-Path $Dest) { Write-Host "Removing existing install: $Dest"; Remove-Item $Dest -Recurse -Force }
Write-Host "Extracting: $Zip -> $Dest"
Expand-Archive -Path $Zip -DestinationPath $Dest -Force

& "$Dest\bin\java.exe" -version
[Environment]::SetEnvironmentVariable("JAVA_HOME", $Dest, "User")
[Environment]::SetEnvironmentVariable("J47_JDK", $Dest, "User")
$bin = "$Dest\bin"
$path = [Environment]::GetEnvironmentVariable("Path", "User")
if ($path -notlike "*$bin*") {
  [Environment]::SetEnvironmentVariable("Path", "$bin;$path", "User")
  Write-Host "Added to user PATH: $bin (takes effect in a new terminal)"
}
Write-Host "Verifying J47 defaults:"
& "$Dest\bin\java.exe" -XX:+PrintFlagsFinal -version | Select-String "UseZGC |ZGenerational |AlwaysPreTouch "
Write-Host "INSTALL OK: $Dest"
