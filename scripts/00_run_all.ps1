# J47 00: all-stage orchestrator (run elevated for the env-check step)
# usage: powershell -ExecutionPolicy Bypass -File scripts\00_run_all.ps1
# NOTE: this script now lives in scripts/, so the repository root is its PARENT.
$ErrorActionPreference = "Continue"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$J47 = Split-Path -Parent $ScriptDir          # repository root
Set-Location $J47
$Git = "C:\Program Files\Git\bin\git.exe"

Write-Host "=== [1/5] env check ==="
powershell -ExecutionPolicy Bypass -File "$ScriptDir\01_env_check.ps1"

Write-Host "=== [2/5] source checkout ==="
if (!(Test-Path "$J47\jdk21u\configure")) {
  if (!(Get-Command git -ErrorAction SilentlyContinue)) { $env:Path += ";C:\Program Files\Git\bin" }
  git clone --depth 1 --branch master https://github.com/openjdk/jdk21u.git "$J47\jdk21u"
} else { Write-Host "jdk21u already present" }

Write-Host "=== [3/5] apply the patch set (in this order) ==="
Set-Location "$J47\jdk21u"
foreach ($p in @("J47-lowlatency.patch", "J47-throughput-2mb.patch", "J47-msvc1944-c2280.patch")) {
  Write-Host "  git apply ..\patches\$p"
  & $Git apply --check "$J47\patches\$p" 2>&1 | Select-Object -First 5
}
Write-Host "If --check passes, actually apply with:"
Write-Host '  cd jdk21u; git apply ..\patches\J47-lowlatency.patch ..\patches\J47-throughput-2mb.patch ..\patches\J47-msvc1944-c2280.patch'
Write-Host "Expected: 6 files modified. Verify with: git -C jdk21u diff --stat"

Write-Host "=== [4/5] configure/build run inside a vcvars64.bat shell ==="
Write-Host 'cmd /k "call ""C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"" && C:\cygwin64\bin\bash.exe --login"'
Write-Host "then inside bash:"
Write-Host "  cd /cygdrive/c/<your/path>/<repo>   # the repo root"
Write-Host "  ./scripts/02_configure_tp.sh ./jdk21u"
Write-Host "  ./scripts/05_build.sh ./jdk21u"

Write-Host "=== [5/5] verify ==="
Write-Host "  powershell -ExecutionPolicy Bypass -File scripts\05_verify.ps1"
