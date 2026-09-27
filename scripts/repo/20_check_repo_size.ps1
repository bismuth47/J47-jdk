<#
.SYNOPSIS
    Pre-commit guard: refuse to let an oversized blob reach Git.

.DESCRIPTION
    GitHub hard-rejects any single blob over 100 MB and starts warning at 50 MB.
    This repository is built in a directory that also holds a ~1.2 GB OpenJDK
    checkout and three ~190 MB installers, so a .gitignore mistake is easy to
    make and expensive to discover after the push.

    This script inspects the *staged* content and fails loudly if anything is
    too big. Run it before every commit, or wire it up as a pre-commit hook:

        git config core.hooksPath .githooks

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\repo\20_check_repo_size.ps1
    powershell -ExecutionPolicy Bypass -File scripts\repo\20_check_repo_size.ps1 -WarnMB 10
#>
[CmdletBinding()]
param(
    [int] $WarnMB  = 50,     # GitHub starts warning here
    [int] $FailMB  = 100,    # GitHub hard-rejects here
    [switch] $InstallHook
)

# See the note in 10_git_init_commit.ps1: git's normal stderr diagnostics must
# not become terminating errors here.
$ErrorActionPreference = 'Continue'
$Root  = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$FailB = $FailMB * 1MB
$WarnB = $WarnMB * 1MB

Set-Location $Root

if ($InstallHook) {
    $hookDir = Join-Path $Root '.githooks'
    New-Item -ItemType Directory -Force -Path $hookDir | Out-Null
    $hook = Join-Path $hookDir 'pre-commit'
    @'
#!/bin/sh
# Installed by scripts/repo/20_check_repo_size.ps1 -InstallHook
exec powershell -NoProfile -ExecutionPolicy Bypass -File "$(dirname "$0")/../scripts/repo/20_check_repo_size.ps1"
'@ | Set-Content -Path $hook -Encoding Ascii
    # Cygwin/Git-Bash runs the hook, so it needs a shebang and LF endings.
    (Get-Content $hook -Raw) -replace "`r`n", "`n" | Set-Content $hook -NoNewline -Encoding Ascii
    & git config core.hooksPath '.githooks'
    Write-Host "installed pre-commit hook -> $hook" -ForegroundColor Green
    Write-Host "make it executable under bash:  chmod +x .githooks/pre-commit" -ForegroundColor DarkGray
}

$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) { throw 'git not found on PATH' }

& git rev-parse --git-dir *> $null
if ($LASTEXITCODE -ne 0) { throw 'not a git repository yet - run 10_git_init_commit.ps1 first' }

# ---------------------------------------------------------------- staged files
$staged = & git diff --cached --name-only --diff-filter=ACMR
if (-not $staged) {
    Write-Host 'nothing staged - nothing to check' -ForegroundColor DarkGray
    exit 0
}

Write-Host ''
Write-Host '=== STAGED CONTENT AUDIT ===' -ForegroundColor Cyan
Write-Host ("  {0} file(s) staged; fail at >{1} MB, warn at >{2} MB" -f $staged.Count, $FailMB, $WarnMB)
Write-Host ''

$total = 0L; $problems = @(); $warns = @()
foreach ($f in $staged) {
    $p = Join-Path $Root $f
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $len = (Get-Item -LiteralPath $p).Length
    $total += $len
    $mb = [math]::Round($len / 1MB, 3)
    if ($len -gt $FailB) {
        $problems += $f
        Write-Host ("  [FAIL] {0,10:N2} MB  {1}" -f $mb, $f) -ForegroundColor Red
    }
    elseif ($len -gt $WarnB) {
        $warns += $f
        Write-Host ("  [WARN] {0,10:N2} MB  {1}" -f $mb, $f) -ForegroundColor Yellow
    }
    else {
        Write-Host ("  [ ok ] {0,10:N3} MB  {1}" -f $mb, $f) -ForegroundColor DarkGray
    }
}

Write-Host ''
Write-Host ("  total staged: {0:N2} MB" -f ($total / 1MB)) -ForegroundColor Cyan

# Directories that must never be tracked, whatever .gitignore says.
$forbidden = '^(jdk2\d?u|openjdk[\w-]*|build|out|images|tools|dist|\.git)/'
$leaks = $staged | Where-Object { $_ -match $forbidden -or $_ -match '\.(jfr|jmod|msi|zip|7z|dll|lib|exe|pdb|obj|class)$' }
if ($leaks) {
    $problems += $leaks
    Write-Host ''
    Write-Host '  FORBIDDEN CONTENT STAGED:' -ForegroundColor Red
    $leaks | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
}

if ($problems) {
    Write-Host ''
    Write-Host ("AUDIT FAILED: {0} file(s) must not be committed." -f $problems.Count) -ForegroundColor Red
    Write-Host '  Unstage them with:  git restore --staged <path>' -ForegroundColor Yellow
    Write-Host '  Then check .gitignore section 10 (the SAFETY NET).' -ForegroundColor Yellow
    exit 1
}

if ($warns) {
    Write-Host ''
    Write-Host ("AUDIT PASSED with {0} warning(s) - GitHub will accept these but will nag." -f $warns.Count) -ForegroundColor Yellow
    exit 0
}

Write-Host ''
Write-Host 'AUDIT PASSED: every staged file is small and allowed.' -ForegroundColor Green
exit 0
