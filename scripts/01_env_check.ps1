#Requires -RunAsAdministrator
<#
.SYNOPSIS
    J47 01: verify the Windows build environment (run elevated).

.DESCRIPTION
    Checks that the Boot JDK 21 is present and runnable, reports whether
    SeLockMemoryPrivilege is held, and exports JAVA_HOME / BOOT_JDK at machine
    scope.

.NOTES
    Encoding: this file is deliberately ASCII-only. Windows PowerShell 5.1
    reads a BOM-less script using the system ANSI code page, which silently
    corrupts non-ASCII text and can turn it into a parse error. Keep every
    .ps1 in this repository ASCII, or give it a UTF-8 BOM.

    Large pages need "Lock Pages in Memory" (SeLockMemoryPrivilege). Without
    it, -XX:+UseLargePages falls back to regular pages. Grant it through
    gpedit.msc -> Local Security Policy -> User Rights Assignment, then sign
    out and back in.
#>
$ErrorActionPreference = "Stop"
$BootJdk = if ($env:J47_BOOT_JDK) { $env:J47_BOOT_JDK } else { "C:\tools\bootjdk-21" }

Write-Host "=== Boot JDK ==="
if (!(Test-Path "$BootJdk\bin\java.exe")) {
  throw "Boot JDK 21 not found at $BootJdk.`n" +
        "Unpack a JDK 21 (e.g. Azul Zulu 21) there, or set `$env:J47_BOOT_JDK."
}
& "$BootJdk\bin\java.exe" -version

Write-Host ""
Write-Host "=== SeLockMemoryPrivilege (required for -XX:+UseLargePages) ==="
$priv = whoami /priv | Select-String "SeLockMemoryPrivilege"
if ($priv) { $priv | ForEach-Object { Write-Host "  $_" } }
else { Write-Host "  SeLockMemoryPrivilege not listed - large pages will stay off." }
Write-Host "  If disabled: gpedit -> Local Security Policy -> User Rights Assignment"
Write-Host "  -> add your build account to 'Lock Pages in Memory', then sign out/in."

Write-Host ""
Write-Host "=== Toolchain ==="
$vs = @(
  "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat",
  "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat",
  "C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat",
  "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat"
) | Where-Object { Test-Path $_ }
if ($vs) { Write-Host "  Visual Studio 2022: $($vs[0])" }
else { Write-Host "  WARNING: vcvars64.bat not found in any standard location." }

if (Test-Path "C:\cygwin64\bin\bash.exe") { Write-Host "  Cygwin bash: C:\cygwin64\bin\bash.exe" }
else { Write-Host "  WARNING: Cygwin64 not found. The JDK build requires Cygwin." }

[Environment]::SetEnvironmentVariable("JAVA_HOME", $BootJdk, "Machine")
[Environment]::SetEnvironmentVariable("BOOT_JDK",  $BootJdk, "Machine")
Write-Host ""
Write-Host "OK: JAVA_HOME / BOOT_JDK = $BootJdk  (machine scope)"
Write-Host "Next: clone https://github.com/openjdk/jdk21u.git jdk21u, then apply patches/"

