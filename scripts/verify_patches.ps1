# J47: patch-set reproducibility check.
# Applies patches/J47-lowlatency.patch -> patches/J47-throughput-2mb.patch ->
# patches/J47-msvc1944-c2280.patch to a pristine checkout of jdk21u in %TEMP%
# and compares the resulting working tree with the current jdk21u working tree.
# usage: powershell -ExecutionPolicy Bypass -File scripts\verify_patches.ps1
$ErrorActionPreference = "Continue"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$J47 = Split-Path -Parent $ScriptDir              # repository root
$Git = (Get-Command git -ErrorAction SilentlyContinue).Source
if (-not $Git) { $Git = "C:\Program Files\Git\bin\git.exe" }
$Repo = Join-Path $J47 "jdk21u"
$Tmp = Join-Path $env:TEMP "J47_patchtest"
$Patches = @("J47-lowlatency.patch", "J47-throughput-2mb.patch", "J47-msvc1944-c2280.patch")

Write-Host "=== [1/4] create pristine worktree at $Tmp ==="
& $Git -C $Repo worktree prune
Remove-Item $Tmp -Recurse -Force -ErrorAction SilentlyContinue
& $Git -C $Repo worktree add --detach $Tmp HEAD
if ($LASTEXITCODE -ne 0) { throw "git worktree add failed" }

Write-Host "=== [2/4] apply patch set in order ==="
foreach ($p in $Patches) {
  $full = Join-Path $J47 "patches\$p"
  & $Git -C $Tmp apply --verbose $full
  if ($LASTEXITCODE -ne 0) { throw "git apply failed: $p" }
  Write-Host "applied: $p"
}

Write-Host "=== [3/4] compare with current working tree ==="
$h1 = & $Git -C $Repo stash create
$h2 = & $Git -C $Tmp stash create
$t1 = & $Git -C $Repo rev-parse "$h1^{tree}"
$t2 = & $Git -C $Tmp rev-parse "$h2^{tree}"
Write-Host "current tree : $t1"
Write-Host "patched tree : $t2"
& $Git -C $Repo --no-pager diff --stat
Write-Host ""
& $Git -C $Tmp --no-pager diff --stat

Write-Host "=== [4/4] result ==="
if ($t1 -and $t2 -and ($t1 -eq $t2)) {
  Write-Host "PATCH SET OK: applying the patches reproduces the current tree exactly."
  $rc = 0
} else {
  Write-Host "PATCH SET MISMATCH: see diff --stat above."
  $rc = 1
}
& $Git -C $Repo worktree remove --force $Tmp
exit $rc
