<#
.SYNOPSIS
    Initialise this repository, stage the release content, and commit to `main`.

.DESCRIPTION
    Creates the Git repository, stages an explicit ALLOWLIST of paths, audits
    the staged blobs for size, commits, and optionally attaches a remote and
    pushes.

    The allowlist is deliberate. `git add -A` would rely entirely on .gitignore
    being complete; this way, even if a rule were wrong, `jdk21u/`, `build/`,
    `out/` and the ~190 MB installers can never be staged.

    Idempotent: re-running after a fresh clone will not clobber an existing
    history, and -Force is required before amending anything.

.PARAMETER Remote
    Remote URL, e.g. git@github.com:<you>/<repo>.git

.PARAMETER Push
    Push `main` to the remote after committing.

.PARAMETER Message
    Commit message. Defaults to the initial-release message.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\repo\10_git_init_commit.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\repo\10_git_init_commit.ps1 `
        -Remote git@github.com:you/J47-jdk.git -Push
#>
[CmdletBinding()]
param(
    [string] $Remote   = '',
    [switch] $Push,
    [string] $Branch   = 'main',
    [string] $UserName = '',
    [string] $UserEmail= '',
    [string] $Message  = '',
    [string] $MessageFile = '',
    [switch] $Force
)

# NOTE on $ErrorActionPreference: this script drives `git` constantly, and git
# writes diagnostics to stderr for perfectly normal cases ("not a git
# repository yet", "nothing to commit"). Under -ErrorActionPreference Stop,
# Windows PowerShell 5.1 turns that stderr into a terminating NativeCommandError
# and the script dies before it can handle the condition. So we run with
# 'Continue' and check $LASTEXITCODE explicitly instead - which is the correct
# way to shell out anyway.
$ErrorActionPreference = 'Continue'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $Root

$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) { throw 'git not found on PATH' }
Write-Host ("git: {0}" -f (& git --version))

# ----------------------------------------------------------------- 0. identity
if ($UserName)  { & git config user.name  $UserName }
if ($UserEmail) { & git config user.email $UserEmail }
$haveName  = [bool](& git config user.name)
$haveEmail = [bool](& git config user.email)
if (-not ($haveName -and $haveEmail)) {
    Write-Host ''
    Write-Host 'Git identity is not fully configured. Set it with:' -ForegroundColor Yellow
    Write-Host '  git config user.name  "Your Name"'          -ForegroundColor Yellow
    Write-Host '  git config user.email "you@example.com"'     -ForegroundColor Yellow
    Write-Host 'or re-run with -UserName / -UserEmail.' -ForegroundColor Yellow
}

# -------------------------------------------------------------------- 1. init
$isRepo = (& git rev-parse --git-dir 2>$null) -eq '.git'
if (-not $isRepo) {
    Write-Host ''
    Write-Host "=== [1/5] git init (-b $Branch) ===" -ForegroundColor Cyan
    & git init "-b" $Branch
} else {
    Write-Host ''
    Write-Host '=== [1/5] existing repository detected ===' -ForegroundColor Cyan
    # NOTE: `git rev-parse --abbrev-ref HEAD` fails on a repository with no
    # commits yet ("fatal: ambiguous argument 'HEAD'"). `symbolic-ref` names the
    # current branch regardless, so use that.
    $cur = (& git symbolic-ref --short HEAD 2>$null)
    if (-not $cur) { $cur = '(detached)' }
    $hasCommits = (& git rev-parse --verify --quiet HEAD 2>$null)
    $commitCount = if ($hasCommits) { (& git rev-list --count HEAD) } else { '0' }
    Write-Host ("  branch: {0}   commits: {1}" -f $cur, $commitCount) -ForegroundColor DarkGray
    if ($cur -ne $Branch -and -not $Force) {
        Write-Host ("  NOTE: target branch is '{0}'. Pass -Force to switch." -f $Branch) -ForegroundColor Yellow
        Write-Host ("        git checkout -b {0}" -f $Branch) -ForegroundColor DarkGray
    }
}

# ------------------------------------------------------- EOL / CRLF safety
# `.gitattributes` already decides line endings per file type, and the patches
# MUST be LF for `git apply` to work. A global core.autocrlf=true (the Windows
# default) fights that and makes `git add` emit a conversion warning for every
# file. Pin it off in this repository so behaviour is deterministic and the
# warnings disappear.
Write-Host ''
Write-Host '=== repo config (line endings) ===' -ForegroundColor Cyan
& git config core.autocrlf false
& git config core.safecrlf  false
& git config core.eol       lf
& git config pull.rebase    true
foreach ($k in @('core.autocrlf', 'core.safecrlf', 'core.eol', 'pull.rebase')) {
    Write-Host ("  {0} = {1}" -f $k, (& git config $k)) -ForegroundColor DarkGray
}

# ------------------------------------------------------------------ 2. stage
# ALLOWLIST. Everything not named here stays out of Git no matter what
# .gitignore says.
$Allow = @(
    '.gitignore', '.gitattributes', '.editorconfig',
    'README.md', 'LICENSE', 'CHANGELOG.md',
    'CONTRIBUTING.md', 'SECURITY.md', 'CODE_OF_CONDUCT.md',
    '.github',
    'patches', 'scripts', 'benchmarks', 'docs', 'bench', 'installer'
)

Write-Host ''
Write-Host '=== [2/5] staging the allowlist ===' -ForegroundColor Cyan
foreach ($p in $Allow) {
    if (Test-Path -LiteralPath (Join-Path $Root $p)) {
        & git add -- $p
        Write-Host ("  staged {0}" -f $p) -ForegroundColor DarkGray
    } else {
        Write-Host ("  SKIP   {0} (not present)" -f $p) -ForegroundColor Yellow
    }
}

# ------------------------------------------------------------------ 3. audit
Write-Host ''
Write-Host '=== [3/5] size / content audit ===' -ForegroundColor Cyan
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '20_check_repo_size.ps1')
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host 'ABORTED: refusing to commit oversized or forbidden content.' -ForegroundColor Red
    exit 1
}

# ----------------------------------------------------------------- 4. commit
# Allow the message to come from a file: multi-line messages passed as a
# command-line argument are fragile across shells (PowerShell splits on newlines
# when forwarding to a child process).
if ($MessageFile) {
    if (!(Test-Path $MessageFile)) { throw "commit message file not found: $MessageFile" }
    $Message = (Get-Content -Raw $MessageFile)
}
$msg = if ($Message) { $Message } else {
@"
J47: ultra-low latency custom OpenJDK for Windows (Generational ZGC + MSVC LTO)

Build kit for a Windows-tuned OpenJDK 21u:
  - patches/    Generational ZGC by default, high-resolution Windows timer,
                ZGC-gated JIT ergonomics, MSVC 19.44 compatibility
  - scripts/    Cygwin + MSVC build pipeline, verifier, GC log analyzer
  - benchmarks/ aggregated results re-derived from the raw GC log

Measured on a 16-vCPU Windows host: P99 pause 0.027 ms, max pause 0.741 ms,
and 0 of 2,375 pauses above 1 ms. See benchmarks/RESULTS.md for methodology.

Heavy artefacts (OpenJDK checkout, build output, installers, logs) are excluded
by .gitignore and staged from an explicit allowlist; publish binaries through
GitHub Releases.
"@
}

Write-Host ''
Write-Host '=== [4/5] commit ===' -ForegroundColor Cyan
# Write the message to a file and use `git commit -F`. Passing it with -m
# requires the shell to round-trip embedded quotes and newlines, which is not
# reliable and produced "pathspec 'not' did not match" on a message that
# contained a quoted word.
$msgFile = Join-Path $env:TEMP "j47_commit_msg_$PID.txt"
[IO.File]::WriteAllText($msgFile, ($msg -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
& git -c core.autocrlf=false commit --file $msgFile
$commitRc = $LASTEXITCODE
Remove-Item $msgFile -ErrorAction SilentlyContinue

if ($commitRc -ne 0) {
    # Most likely "nothing to commit" on a re-run - that is not a failure.
    $porcelain = & git status --porcelain
    if (-not $porcelain) { Write-Host '  nothing to commit - working tree already clean.' -ForegroundColor DarkGray }
    else { Write-Host '  commit failed - see above.' -ForegroundColor Red; exit 1 }
} else {
    Write-Host ''
    & git --no-pager log --oneline -1
}

# ------------------------------------------------------- 5. remote and push
Write-Host ''
Write-Host '=== [5/5] remote / push ===' -ForegroundColor Cyan
if ($Remote) {
    $existing = & git remote
    if ($existing -contains 'origin') {
        Write-Host "  updating origin -> $Remote" -ForegroundColor DarkGray
        & git remote set-url origin $Remote
    } else {
        Write-Host "  adding origin -> $Remote" -ForegroundColor DarkGray
        & git remote add origin $Remote
    }
    & git remote -v

    if ($Push) {
        Write-Host ''
        Write-Host "  pushing to $Branch ..." -ForegroundColor Cyan
        & git push -u origin $Branch
        if ($LASTEXITCODE -ne 0) {
            Write-Host '  push failed. If the remote already has history, reconcile with:' -ForegroundColor Yellow
            Write-Host "    git pull --rebase origin $Branch" -ForegroundColor Yellow
            Write-Host '  or create the GitHub repo empty (no README/.gitignore) first.' -ForegroundColor Yellow
            exit 1
        }
        Write-Host '  PUSH OK' -ForegroundColor Green
    } else {
        Write-Host '  -Push not specified; skipping push.' -ForegroundColor DarkGray
    }
} else {
    Write-Host '  no -Remote given. Create the repo on GitHub, then run:' -ForegroundColor DarkGray
    Write-Host "    git remote add origin git@github.com:<you>/<repo>.git" -ForegroundColor DarkGray
    Write-Host "    git push -u origin $Branch" -ForegroundColor DarkGray
}

Write-Host ''
Write-Host 'DONE. Repository is ready.' -ForegroundColor Green
Write-Host ''
& git --no-pager status --short --branch
Write-Host ''
