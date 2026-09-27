<#
.SYNOPSIS
    Build the J47 MSI with WiX Toolset 3.x (Windows only).

.DESCRIPTION
    Runs the WiX heat -> candle -> light pipeline over a built JDK image and
    produces J47-JDK-21.msi in the repository `dist/` directory.

    .NOTES
    `heat -srd` (Suppress Root Directory) is essential. Without it, heat emits
    a top-level directory element and the MSI ends up nesting everything under
    C:\Program Files\J47\JDK-21\jdk\ instead of directly under the install root.
    The $Src sanity check below enforces the same invariant: $Src must be the
    directory that directly contains bin\java.exe.

    WHY THERE IS NO J47.wxs IN THE REPOSITORY
    The WiX fragment this script consumes is a *harvested* artefact. In the
    reference build it carried 571 absolute Source= paths pointing at the
    original author's TEMP directory
    (C:\Users\<someone>\AppData\Local\Temp\J47dark\File\...). Committing it
    would ship those paths to every other user, where they resolve to nothing,
    and the resulting MSI would be broken. So msi/ and *.wxs are Git-ignored
    and you supply your own fragment with -Wxs.

    To produce a portable one, harvest it yourself and keep only the hand
    written <Product>/<Directory>/<Feature> shell, or author it from scratch.
    scripts/build_msi.ps1 regenerates the *file* half of the fragment on every
    run via heat; only the product shell has to be supplied.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\build_msi.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\build_msi.ps1 `
        -JdkRoot C:\j47build\images\jdk -Wxs C:\path\to\J47.wxs
#>

.NOTES
    `heat -srd` (Suppress Root Directory) is essential. Without it, heat emits
    a top-level directory element and the MSI ends up nesting everything under
    C:\Program Files\J47\JDK-21\jdk\ instead of directly under the install root.
    The $Src sanity check below enforces the same invariant: $Src must be the
    directory that directly contains bin\java.exe.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\build_msi.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\build_msi.ps1 -JdkRoot C:\j47build\images\jdk
#>
param(
    [string] $JdkRoot = '',
    [string] $WixRoot = '',
    [string] $Wxs     = ''
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$J47 = Split-Path -Parent $ScriptDir              # repository root

if (-not $WixRoot) { $WixRoot = Join-Path $J47 "tools\wix314" }
if (-not $Wxs)     { $Wxs     = Join-Path $J47 "msi\J47.wxs" }

if ([string]::IsNullOrWhiteSpace($JdkRoot)) {
    $cands = @(
        (Join-Path $J47 "jdk21u\build\windows-x86_64-server-release\images\jdk"),
        "C:\j47build\images\jdk"
    ) | Where-Object { Test-Path (Join-Path $_ "bin\java.exe") }
    if ($cands) { $JdkRoot = $cands[0] }
    else { throw "No JDK image found. Build first, or pass -JdkRoot <path>." }
}

# $Src must be the directory that directly contains bin\java.exe, otherwise
# heat -srd still produces the extra nested directory level.
$Src = $JdkRoot
if (!(Test-Path (Join-Path $Src "bin\java.exe"))) {
    if (Test-Path (Join-Path $Src "jdk\bin\java.exe")) {
        $Src = Join-Path $Src "jdk"
        Write-Host "Redirected JdkRoot to $Src"
    } else {
        throw "JDK not found at: $Src (expected bin\java.exe directly beneath it)"
    }
}

foreach ($t in @("heat.exe", "candle.exe", "light.exe")) {
    if (!(Test-Path (Join-Path $WixRoot $t))) {
        throw "WiX tool not found: $(Join-Path $WixRoot $t)`n" +
              "Install WiX Toolset 3.x and unpack it to $WixRoot (see docs/BUILD_SUMMARY.md)."
    }
}
if (!(Test-Path $Wxs)) {
  throw "WiX product fragment not found: $Wxs`n" +
        "This is a harvested, machine-specific artefact and is deliberately not" +
        " committed (see the .NOTES block at the top of this script)." +
        " Author your own and pass it with -Wxs <path>."
}

$Out  = Join-Path $J47 "msi\out"
$Dist = Join-Path $J47 "dist"
New-Item -ItemType Directory -Force -Path $Out, $Dist | Out-Null
$Msi  = Join-Path $Dist "J47-JDK-21.msi"

Write-Host "=== heat ==="
& (Join-Path $WixRoot "heat.exe") dir "$Src" -dr INSTALLDIR -cg J47Files `
    -gg -g1 -scom -sreg -sfrag -srd -out (Join-Path $Out "J47files.wxs")
if ($LASTEXITCODE -ne 0) { throw "heat failed: $LASTEXITCODE" }

Write-Host "=== candle ==="
& (Join-Path $WixRoot "candle.exe") -arch x64 -out "$Out\" `
    "$Wxs" (Join-Path $Out "J47files.wxs") -ext (Join-Path $WixRoot "WixUIExtension.dll")
if ($LASTEXITCODE -ne 0) { throw "candle failed: $LASTEXITCODE" }

Write-Host "=== light ==="
& (Join-Path $WixRoot "light.exe") -out "$Msi" `
    (Join-Path $Out "J47.wixobj") (Join-Path $Out "J47files.wixobj") `
    -b "$Src" -ext (Join-Path $WixRoot "WixUIExtension.dll") -cultures:en-us
if ($LASTEXITCODE -ne 0) { throw "light failed: $LASTEXITCODE" }

Get-Item $Msi | Select-Object Name, Length
Write-Host "MSI OK: $Msi"
Write-Host "NOTE: this is a build artefact and is Git-ignored. Publish it as a GitHub Release."
