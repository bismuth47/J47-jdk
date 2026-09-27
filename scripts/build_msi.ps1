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
    # NOTE: force the result back into an array. A pipeline that filters down to a
    # single item returns a SCALAR, and $cands[0] on a string yields its first
    # *character* - which would silently turn "C:\j47build\images\jdk" into "C".
    $cands = @(
        (Join-Path $J47 "jdk21u\build\windows-x86_64-server-release\images\jdk"),
        "C:\j47build\images\jdk"
    ) | Where-Object { Test-Path (Join-Path $_ "bin\java.exe") }
    $cands = @($cands)
    if ($cands.Count -gt 0) { $JdkRoot = $cands[0] }
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
        # NOTE: `throw` takes a single argument; PowerShell has no `+` string
        # concatenation operator, so multi-line messages must be built first.
        $msg = "WiX tool not found: $(Join-Path $WixRoot $t)`n" +
               "Install WiX Toolset 3.x and unpack it to $WixRoot (see docs/BUILD_SUMMARY.md)."
        throw $msg
    }
}
if (!(Test-Path $Wxs)) {
    $msg = "WiX product fragment not found: $Wxs`n" +
           "This is a harvested, machine-specific artefact and is deliberately not" +
           " committed (see the .NOTES block at the top of this script)." +
           " Author your own and pass it with -Wxs <path>."
    throw $msg
}

$Out  = Join-Path $J47 "msi\out"
$Dist = Join-Path $J47 "dist"
New-Item -ItemType Directory -Force -Path $Out, $Dist | Out-Null
$Msi  = Join-Path $Dist "J47-JDK-21.msi"

# ---------------------------------------------------------------------------
# Pre-flight: the product fragment must be a SHELL, not a harvested file list.
#
# This script always regenerates the file half of the MSI with heat. If the
# fragment passed via -Wxs also contains harvested <File>/<Component> elements,
# light.exe fails with a wall of
#   LGHT0091 : Duplicate symbol 'Component:cmp...'
# because every id now exists twice. A fragment harvested by an earlier build is
# the usual cause, and it is exactly why no .wxs is committed to this repo.
# ---------------------------------------------------------------------------
$wxsText = Get-Content -Raw -Path $Wxs
$fileCount  = ([regex]::Matches($wxsText, '<File\b')).Count
$compCount  = ([regex]::Matches($wxsText, '<Component\b')).Count
if ($fileCount -gt 0 -or $compCount -gt 0) {
    Write-Host ''
    Write-Host ("PRE-FLIGHT FAILED: {0} does not look like a product shell." -f $Wxs) -ForegroundColor Red
    Write-Host ("  it contains {0} <File> and {1} <Component> element(s)." -f $fileCount, $compCount) -ForegroundColor Red
    Write-Host ''
    Write-Host '  This script harvests the file list itself, so the fragment you pass' -ForegroundColor Yellow
    Write-Host '  must contain only the hand-written <Product> / <Directory> /' -ForegroundColor Yellow
    Write-Host '  <Feature> / <RegistryValue> shell. Otherwise light.exe reports' -ForegroundColor Yellow
    Write-Host '  LGHT0091 "Duplicate symbol" for every id.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Fix: keep the <Product> shell, delete the harvested <Directory>/' -ForegroundColor Yellow
    Write-Host '  <Component>/<File> subtree, and re-run.' -ForegroundColor Yellow
    throw 'WiX product fragment contains a harvested file list.'
}

# Each WiX stage is invoked with its output captured, so the tool's own error
# text is shown on failure instead of just an opaque exit code. (light.exe in
# particular returns things like 92 for schema/duplicate-id problems, which is
# meaningless without the surrounding diagnostics.)
function Invoke-Wix {
    param([string]$Tool, [string]$Stage, [string[]]$ToolArgs)
    Write-Host "=== $Stage ==="
    $exe = Join-Path $WixRoot $Tool
    $out = & $exe @ToolArgs 2>&1
    $code = $LASTEXITCODE
    $out | ForEach-Object { Write-Host "    $_" }
    if ($code -ne 0) { throw "$Tool failed during $Stage (exit $code). See the tool output above." }
}

$heatArgs = @(
    'dir', $Src, '-dr', 'INSTALLDIR', '-cg', 'J47Files',
    '-gg', '-g1', '-scom', '-sreg', '-sfrag', '-srd',
    '-out', (Join-Path $Out 'J47files.wxs')
)
Invoke-Wix -Tool 'heat.exe'   -Stage 'heat'   -ToolArgs $heatArgs

$heatFrag = Join-Path $Out 'J47files.wxs'
if (!(Test-Path $heatFrag)) { throw "heat produced no fragment at $heatFrag" }

$candleArgs = @(
    '-arch', 'x64', '-out', "$Out\", $Wxs, $heatFrag,
    '-ext', (Join-Path $WixRoot 'WixUIExtension.dll')
)
Invoke-Wix -Tool 'candle.exe' -Stage 'candle' -ToolArgs $candleArgs

$lightArgs = @(
    '-out', $Msi,
    (Join-Path $Out 'J47.wixobj'), (Join-Path $Out 'J47files.wixobj'),
    '-b', $Src,
    '-ext', (Join-Path $WixRoot 'WixUIExtension.dll'),
    '-cultures:en-us'
)
Invoke-Wix -Tool 'light.exe'  -Stage 'light'  -ToolArgs $lightArgs

if (!(Test-Path $Msi)) { throw "light reported success but $Msi does not exist" }
Get-Item $Msi | Select-Object Name, Length
Write-Host "MSI OK: $Msi"
Write-Host "NOTE: this is a build artefact and is Git-ignored. Publish it as a GitHub Release."
