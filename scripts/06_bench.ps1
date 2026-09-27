# J47 06: Generational ZGC benchmark driver (PowerShell / Windows)
# JFR always on + verbose GC logging + a memory-pressure workload.
# Run from the repository root; the script relocates itself there if needed.
#
# usage:
#   powershell -ExecutionPolicy Bypass -File scripts\06_bench.ps1 `
#     -Jdk "C:\j47build\images\jdk" -Heap "4G" -DurationSec 120 -Threads 8
#   powershell -ExecutionPolicy Bypass -File scripts\06_bench.ps1 `
#     -JmhJar "bench\benchmarks.jar" -DurationSec 60
#
# output: out\bench-<timestamp>\  (bench.jfr, gc.log*, flags.txt, version.txt, result.txt)
# notes:
#  - "-version" goes to stderr, so "--version" (stdout) is used instead
#  - there is no "gc+safepoint" -Xlog tag combination; specifiy safepoint alone
#  - LiveMB is the TOTAL held by all workers; it is divided by Threads
param(
    # J47_JDK lets CI and other machines point at their own image without editing
    # this file. Default to the recommended out-of-source build root.
    [string]$Jdk = $(if ($env:J47_JDK) { $env:J47_JDK } else { "C:\j47build\images\jdk" }),
    [string]$Heap = "4G",
    [int]$DurationSec = 120,
    [int]$Threads = 0,
    [string]$OutDir = "",
    [string]$JmhJar = "",
    [string]$ExtraJvmArgs = "",
    [int]$AllocKB = 64,
    [int]$LargeKB = 4096,
    [int]$LiveMB = 512
)
$ErrorActionPreference = "Stop"
# This script lives in scripts/, so the repository root is its PARENT.
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$J47 = Split-Path -Parent $ScriptDir
# Run from the repository root so that out/ and bench/ land in predictable places.
Set-Location $J47

$Java = Join-Path $Jdk "bin\java.exe"
if (!(Test-Path $Java)) { throw "java.exe not found: $Java ( -Jdk を確認)" }
if ($Threads -le 0) { $Threads = [Environment]::ProcessorCount }

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
if ([string]::IsNullOrEmpty($OutDir)) { $OutDir = "out\bench-$stamp" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutFull = (Resolve-Path $OutDir).Path
$PerWorkerLiveMB = [Math]::Max(16, [int]($LiveMB / $Threads))

Write-Host "=== J47 bench ==="
Write-Host "JDK     : $Jdk"
Write-Host "Threads : $Threads  Heap: $Heap  Duration: ${DurationSec}s  LiveTotal: ${LiveMB}MB (per-worker $PerWorkerLiveMB MB)"
Write-Host "OutDir  : $OutDir"
& $Java --version > (Join-Path $OutDir "version.txt") 2>&1
Get-Content (Join-Path $OutDir "version.txt")
& $Java -XX:+PrintFlagsFinal --version > (Join-Path $OutDir "flags_all.txt") 2>&1
Select-String "UseZGC|ZGenerational|ConcGCThreads|UseLargePages|AlwaysPreTouch|UseNUMA" (Join-Path $OutDir "flags_all.txt") | ForEach-Object { $_.Line.Trim() } | Tee-Object (Join-Path $OutDir "flags.txt")

# JFR: profile設定で常時記録、終了時dump。disk=trueで長時間計測に対応
# GCログ: gc* + phases=debug + safepoint=info + ローテーション
# Windows低レイテンシ定番 (J47は既定でZGC/高分解能タイマ。ZGenerational は JDK24 で
# 削除済みなので渡さない - 渡すと起動ごとに "support was removed in 24.0" が出る)
$JvmCommon = @(
    "-Xms$Heap",
    "-Xmx$Heap",
    "-XX:+UseZGC",
    "-XX:+AlwaysPreTouch",
    "-XX:+UnlockDiagnosticVMOptions",
    "-XX:+DebugNonSafepoints",
    "-XX:+UnlockExperimentalVMOptions",
    "-XX:StartFlightRecording=name=J47Bench,settings=profile,disk=true,dumponexit=true,filename=$OutFull\bench.jfr,maxsize=1G",
    "-Xlog:gc*,gc+phases=debug,safepoint=info:file=$OutFull\gc.log:time,uptime,pid:filecount=5,filesize=100M",
    "-Xlog:safepoint,os+thread:file=$OutFull\safepoint.log:time,uptime,pid:filecount=3,filesize=50M",
    "-Xlog:jit+compilation:file=$OutFull\jit.log:time,uptime,pid:filecount=3,filesize=50M"
)
if ($ExtraJvmArgs -ne "") { $JvmCommon += $ExtraJvmArgs.Split(" ", [StringSplitOptions]::RemoveEmptyEntries) }

# 電源プラン注意喚起 (OSスレッドスケジューリングのズレ対策)
powercfg /getactivescheme 2>$null | Tee-Object (Join-Path $OutDir "powerscheme.txt")
Write-Host "NOTE: 高精度計測は [高パフォーマンス] プラン + Defender除外推奨。詳細は 08_perf_guide.md"

$sw = [Diagnostics.Stopwatch]::StartNew()
if ($JmhJar -ne "") {
    if (!(Test-Path $JmhJar)) { throw "JMH jar not found: $JmhJar" }
    Write-Host "--- JMH mode: $JmhJar ---"
    $prevErr = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $Java @JvmCommon -jar $JmhJar -f 1 -wi 2 -i 3 2>&1 | Tee-Object (Join-Path $OutDir "result.txt")
    } finally {
        $ErrorActionPreference = $prevErr
    }
} else {
    Write-Host "--- built-in MemPressureBench ---"
    $BenchSrc = "bench\MemPressureBench.java"
    if (!(Test-Path $BenchSrc)) { throw "bench source missing: $BenchSrc" }
    $Javac = Join-Path $Jdk "bin\javac.exe"
    & $Javac -d bench $BenchSrc
    if ($LASTEXITCODE -ne 0) { throw "javac failed" }
    $benchArgs = @("-cp", "bench", "MemPressureBench",
        "--threads", "$Threads", "--duration", "$DurationSec",
        "--alloc-kb", "$AllocKB", "--large-kb", "$LargeKB", "--live-mb", "$PerWorkerLiveMB")
    Write-Host ("JVM: " + ($JvmCommon -join " "))
    $prevErr = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $Java @JvmCommon @benchArgs 2>&1 | Tee-Object (Join-Path $OutDir "result.txt")
    } finally {
        $ErrorActionPreference = $prevErr
    }
    if ($LASTEXITCODE -ne 0) { throw "bench failed (exit=$LASTEXITCODE)" }
}
$sw.Stop()
Write-Host ("ELAPSED: {0:N1}s" -f $sw.Elapsed.TotalSeconds)
Get-ChildItem $OutDir | Format-Table Name, Length
Write-Host "NEXT: python 07_gc_log_analyze.py --log $OutDir\gc.log"
Write-Host "      <Jdk>\bin\jfr.exe summary $OutFull\bench.jfr  (JDK同梱jfrツール)"
