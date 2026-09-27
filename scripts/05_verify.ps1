# J47 05: verify the built image (PowerShell)
# usage: powershell -ExecutionPolicy Bypass -File scripts\05_verify.ps1 [jdk-image-dir]
# NOTE: this script lives in scripts/, so the repository root is its PARENT.
# NOTE: `java -version` writes to stderr, so a raw &-invocation under
#       $ErrorActionPreference="Stop" aborts with NativeCommandError.
#       Start-Process + redirection is used to capture both streams safely.
$ErrorActionPreference = "Continue"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$J47 = Split-Path -Parent $ScriptDir              # repository root
# Default image locations, in priority order:
#   1. out-of-source build root (recommended, outside OneDrive)
#   2. in-source build/<conf>/images/jdk
$Candidates = @(
  (Join-Path $env:TP_BUILD_ROOT_WIN "images\jdk"),
  "C:\j47build\images\jdk",
  (Join-Path $J47 "jdk21u\build\windows-x86_64-server-release\images\jdk")
) | Where-Object { $_ -and $_ -ne "images\jdk" -and (Test-Path (Join-Path $_ "bin\java.exe")) }
$Jdk = if ($Candidates) { $Candidates[0] } else { "C:\j47build\images\jdk" }
if ($args.Count -ge 1) { $Jdk = $args[0] }
$java = Join-Path $Jdk "bin\java.exe"
if (!(Test-Path $java)) { throw "java.exe not found: $java (build images first)" }

function Invoke-Capture {
  param([string]$Exe, [string[]]$Arguments, [string]$Tag)
  $out = Join-Path $env:TEMP "j47_$Tag.out.txt"
  $err = Join-Path $env:TEMP "j47_$Tag.err.txt"
  Remove-Item $out, $err -ErrorAction SilentlyContinue
  $p = Start-Process -FilePath $Exe -ArgumentList $Arguments -NoNewWindow -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
  $so = Get-Content $out -Raw -ErrorAction SilentlyContinue
  $se = Get-Content $err -Raw -ErrorAction SilentlyContinue
  [pscustomobject]@{ ExitCode = $p.ExitCode; Text = (("" + $so + $se).Trim()) }
}

Write-Host "=== [1/4] JVM startup (the crash that was fixed) ==="
$r = Invoke-Capture $java @("-version") "version"
Write-Host $r.Text
Write-Host "exit=$($r.ExitCode)"
if ($r.ExitCode -ne 0) { Write-Host "NG: JVM failed to start"; exit 1 }

Write-Host ""
Write-Host "=== [2/4] J47 default flags (ZGC / pre-touch / timing / large pages) ==="
$rf = Invoke-Capture $java @("-XX:+PrintFlagsFinal", "-version") "flags"
$flags = $rf.Text -split "`r?`n"
$flags | Select-String "UseZGC|ZGenerational|AlwaysPreTouch|UseLargePages|ForceTimeHighResolution|LoopStripMiningIter|ConcGCThreads" | ForEach-Object { $_.Line.Trim() }

Write-Host ""
Write-Host "=== [3/4] GC log smoke test ==="
$gcLog = Join-Path $J47 "zgc.log"
$rg = Invoke-Capture $java @("-Xlog:gc*:file=$gcLog", "-version") "gclog"
Write-Host "exit=$($rg.ExitCode)"
if (Test-Path $gcLog) { Get-Content $gcLog | Select-String "ZGC|Pause" | Select-Object -First 20 | ForEach-Object { $_.Line } }

Write-Host ""
Write-Host "=== [4/4] verdict ==="
$zgcOk = [bool]($flags | Select-String "bool UseZGC\s*=\s*true")
$preOk = [bool]($flags | Select-String "bool AlwaysPreTouch\s*=\s*true")
$lp     = ($flags | Select-String "bool UseLargePages\s*=").Line
if ($zgcOk -and $preOk) {
  Write-Host "VERIFY OK: UseZGC=true / AlwaysPreTouch=true (J47 defaults applied)"
} else {
  Write-Host "VERIFY FAILED: UseZGC=$zgcOk AlwaysPreTouch=$preOk"
}
Write-Host "UseLargePages: $lp"
Write-Host "NOTE: large pages stay opt-in (-XX:+UseLargePages, needs SeLockMemoryPrivilege);"
Write-Host "      forcing them from ergonomics crashed the JVM (see BUILD_SUMMARY 2026-09-27)."

