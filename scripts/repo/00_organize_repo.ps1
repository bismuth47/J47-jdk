<#
.SYNOPSIS
    Restructures the J47 workspace into a distributable, Git-ready build kit.

.DESCRIPTION
    Creates the canonical folder layout, then relocates the scattered files that
    were previously sitting loose in the repository root:

        patches/     *.patch                       <- the product
        scripts/     00..98_*.sh, *.ps1, *.cmd     <- the build pipeline
        benchmarks/  aggregated *.csv / *.md / *.txt
        docs/        *.md (build & incident notes)
        bench/       *.java                        <- the workload
        installer/   *.nsi                         <- NSIS installer source

    Heavy artefacts (jdk21u/, build/, out/, *.log, *.msi, *.exe, *.zip) are left
    exactly where they are and are kept out of Git by .gitignore, so this script
    never has to move or delete a gigabyte of data.

    The script is IDEMPOTENT: files that are already in place are skipped, so it
    is safe to re-run. In the default -Mode Move the original is copied first
    into .j47-organize-backup/ so nothing is ever lost.

.PARAMETER Mode
    Move (default) relocates the file; Copy duplicates and leaves the original.

.PARAMETER IncludeLegacy
    Also move the one-off root analysis scripts (analysis_final.py,
    comprehensive_analysis.py, ...) into tools/legacy-analysis/, which is
    Git-ignored. Off by default so that a first run stays conservative.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\repo\00_organize_repo.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\repo\00_organize_repo.ps1 -Mode Copy -IncludeLegacy
#>
[CmdletBinding()]
param(
    [ValidateSet('Move', 'Copy')]
    [string] $Mode = 'Move',
    [switch] $IncludeLegacy,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
$Root      = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$BackupDir = Join-Path $Root '.j47-organize-backup'

# ---------------------------------------------------------------- directories
$Dirs = @(
    'patches', 'scripts', 'scripts\repo', 'benchmarks',
    'docs', 'bench', 'installer', 'tools\legacy-analysis'
)
foreach ($d in $Dirs) {
    $full = Join-Path $Root $d
    if (-not (Test-Path $full)) {
        if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $full | Out-Null }
        Write-Host ("  [dir ] {0}" -f $d) -ForegroundColor DarkGray
    }
}

# ---------------------------------------------------------------- file map
# Keys are paths relative to $Root. The order is the apply order and it matters
# only for readability, not for correctness.
$Map = [ordered]@{
    # --- build pipeline -> scripts/ -------------------------------------------
    '00_run_all.ps1'         = 'scripts\00_run_all.ps1'
    '01_env_check.ps1'       = 'scripts\01_env_check.ps1'
    '01_env_check.sh'        = 'scripts\01_env_check.sh'
    '02_configure.sh'        = 'scripts\02_configure.sh'
    '02_configure_tp.sh'     = 'scripts\02_configure_tp.sh'
    '02_configure_tp_jdk25.sh' = 'scripts\02_configure_tp_jdk25.sh'
    '05_build.sh'            = 'scripts\05_build.sh'
    '05_verify.ps1'          = 'scripts\05_verify.ps1'
    '06_bench.ps1'           = 'scripts\06_bench.ps1'
    '06_build_tp.sh'         = 'scripts\06_build_tp.sh'
    '06_build_tp_jdk25.sh'   = 'scripts\06_build_tp_jdk25.sh'
    '07_gc_log_analyze.py'   = 'scripts\07_gc_log_analyze.py'
    '08_perf_guide.md'       = 'scripts\08_perf_guide.md'
    '98_run_build_jdk25.sh'  = 'scripts\98_run_build_jdk25.sh'
    'verify_patches.ps1'     = 'scripts\verify_patches.ps1'
    'run_build_tp2.cmd'      = 'scripts\run_build_tp2.cmd'
    'run_build_j47build.cmd' = 'scripts\run_build_j47build.cmd'
    'vsenv.bat'              = 'scripts\vsenv.bat'
    'vsenv.sh'               = 'scripts\vsenv.sh'
    'install.ps1'            = 'scripts\install.ps1'
    'admin_tasks.ps1'        = 'scripts\admin_tasks.ps1'
    'run_configure_j47build.cmd' = 'scripts\run_configure_j47build.cmd'
    'msi\build_msi.ps1'      = 'scripts\build_msi.ps1'

    # --- aggregated results -> benchmarks/ ------------------------------------
    'gc_performance_analysis.csv'                 = 'benchmarks\gc-performance-summary.csv'
    'out\bench-v2\summary.csv'                    = 'benchmarks\bench-v2-gc-summary.csv'
    'out\bench-v2\result.txt'                     = 'benchmarks\bench-v2-result.txt'
    'out\bench-v2\version.txt'                    = 'benchmarks\bench-v2-version.txt'
    'out\bench-v2\flags.txt'                      = 'benchmarks\bench-v2-flags.txt'
    'out\bench-v2\powerscheme.txt'                = 'benchmarks\bench-v2-powerscheme.txt'
    'ANALYSIS_SUMMARY.md'                         = 'benchmarks\ANALYSIS_SUMMARY.md'
    'COMPREHENSIVE_PERFORMANCE_ANALYSIS.md'       = 'benchmarks\PERFORMANCE_ANALYSIS.md'

    # --- narrative -> docs/ ----------------------------------------------------
    'BUILD_SUMMARY.md' = 'docs\BUILD_SUMMARY.md'

    # --- workload + installer source ------------------------------------------
    'J47.nsi'          = 'installer\J47.nsi'
    'J47-JDK-21.wxs'   = 'installer\J47.wxs'
    'icon.png'         = 'installer\icon.png'
}

# patches/ is already the canonical home; we only assert that it exists.
$ExpectedPatches = @(
    'J47-lowlatency.patch',
    'J47-throughput-2mb.patch',
    'J47-msvc1944-c2280.patch'
)

# ------------------------------------------------------------------ relocate
$moved = 0; $skipped = 0; $missing = @()

foreach ($from in $Map.Keys) {
    $to = $Map[$from]
    $srcFull = Join-Path $Root $from
    $dstFull = Join-Path $Root $to
    $dstDir  = Split-Path -Parent $dstFull

    if (-not (Test-Path $srcFull)) {
        if (Test-Path $dstFull) { $skipped++ ; continue }   # already reorganised
        $missing += $from
        continue
    }
    if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }
    Write-Host ("  {0} {1}  ->  {2}" -f $Mode.ToUpper().PadRight(4), $from, $to) -ForegroundColor Cyan
    if (-not $DryRun) {
        if ($Mode -eq 'Move') {
            # Keep a pristine copy first, then relocate the original.
            $bak = Join-Path $BackupDir $from
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $bak) | Out-Null
            Copy-Item $srcFull $bak -Force
            Move-Item $srcFull $dstFull -Force
        }
        else { Copy-Item $srcFull $dstFull -Force }
        # Post-condition: never report success unless the file really landed.
        if (-not (Test-Path $dstFull)) { throw "organize failed: $from -> $to (destination missing)" }
    }
    $moved++
}

# ------------------------------------------------------------ optional: legacy
# The one-off analysis scripts were scratch tooling for the original numbers.
# They are preserved on disk but moved out of the published tree, because
# tools/legacy-analysis/ is covered by .gitignore.
if ($IncludeLegacy) {
    $legacy = @(
        'analysis_final.py', 'analyze_gc_logs.py', 'build_plan.py',
        'comprehensive_analysis.py', 'final_analysis.py', 'minimal_analysis.py',
        'run_analysis.py', 'simple_analysis.py'
    )
    foreach ($f in $legacy) {
        $srcFull = Join-Path $Root $f
        if (-not (Test-Path $srcFull)) { continue }
        Write-Host ("  MOVE {0}  ->  tools\legacy-analysis\{0}" -f $f) -ForegroundColor Cyan
        if (-not $DryRun) {
            $bak = Join-Path (Join-Path $BackupDir 'legacy') $f
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $bak) | Out-Null
            Copy-Item $srcFull $bak -Force
            Move-Item $srcFull (Join-Path $Root "tools\legacy-analysis\$f") -Force
        }
    }
}

# ------------------------------------------------- normalise line endings (EOL)
# This kit is authored on Windows, where editors default to CRLF. Bash refuses
# `do\r` / `then\r`, and `git apply` mis-parses CRLF hunks, so every shell and
# patch file is forced to LF. PowerShell/cmd files keep CRLF. This step makes the
# kit runnable on Cygwin/Git-Bash out of the box, before Git ever sees the files.
$eolFixed = 0
$lfGlobs = @('*.sh', '*.bash', '*.py', '*.patch', '*.diff')
# Scan ONLY the kit directories. A recursive sweep of $Root would walk the
# ~1.2 GB jdk21u checkout and take minutes; those trees are Git-ignored anyway.
$scanDirs = @('patches', 'scripts', 'benchmarks', 'docs', 'bench', 'installer')
$scanFiles = @()
foreach ($d in $scanDirs) {
    $p = Join-Path $Root $d
    if (Test-Path $p) { $scanFiles += Get-ChildItem -Path $p -Recurse -File -ErrorAction SilentlyContinue }
}
$scanFiles += Get-ChildItem -Path $Root -File -ErrorAction SilentlyContinue   # root level only
foreach ($f in $scanFiles) {
    if ($lfGlobs -notcontains $f.Name -and $f.Extension -notin @('.sh', '.bash', '.py', '.patch', '.diff')) { continue }
    $text = [IO.File]::ReadAllText($f.FullName)
    $fixed = $text -replace "`r`n", "`n"
    if ($fixed -cne $text) {
        if (-not $DryRun) {
            [IO.File]::WriteAllText($f.FullName, $fixed, (New-Object Text.UTF8Encoding $false))
        }
        Write-Host ("  EOL   {0}  -> LF" -f $f.FullName.Substring($Root.Length + 1)) -ForegroundColor DarkYellow
        $eolFixed++
    }
}

# -------------------------------------------------------------- verify patches
$patchState = foreach ($p in $ExpectedPatches) {
    $p1 = Join-Path $Root "patches\$p"
    [pscustomobject]@{ Patch = $p; Present = (Test-Path $p1); KiB = [math]::Round((Get-Item $p1).Length / 1KB, 1) }
}

# ------------------------------------------------------------------- summary
Write-Host ''
Write-Host '=== ORGANIZE SUMMARY ===' -ForegroundColor Green
Write-Host ("  relocated : {0}" -f $moved)
Write-Host ("  already ok: {0}" -f $skipped)
Write-Host ("  EOL->LF   : {0}" -f $eolFixed)
if ($missing.Count) {
    Write-Host ("  NOT FOUND : {0}" -f $missing.Count) -ForegroundColor Yellow
    $missing | ForEach-Object { Write-Host ("      - {0}" -f $_) -ForegroundColor Yellow }
}
Write-Host ''
Write-Host '  patches/:'
$patchState | ForEach-Object {
    $mark = if ($_.Present) { 'ok ' } else { 'MISSING' }
    $col  = if ($_.Present) { 'Green' } else { 'Red' }
    Write-Host ("    [{0}] {1,-32} {2} KiB" -f $mark, $_.Patch, $_.KiB) -ForegroundColor $col
}
if ($Mode -eq 'Move' -and $moved -gt 0) {
    Write-Host ''
    Write-Host ("  originals backed up to: {0}" -f $BackupDir) -ForegroundColor DarkGray
}
if ($DryRun) { Write-Host '  (DRY RUN - nothing was written)' -ForegroundColor Magenta }
Write-Host ''
Write-Host '  Next: scripts\repo\10_git_init_commit.ps1 -Remote git@github.com:<you>/<repo>.git'
Write-Host ''
