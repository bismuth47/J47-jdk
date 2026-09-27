# Benchmarks — how to reproduce and how to read them

> **日本語要約:** ベンチマークの再現手順と結果の読み方です。
> 詳細は [`RESULTS.md`](RESULTS.md) に結果表があります。

## Environment used for the committed results

| Item | Value |
|---|---|
| OS | Windows (10/11, x64) |
| JVM under test | `21.0.13-internal-J47-ZGC-default` (64-Bit Server VM, mixed mode) |
| GC | Generational ZGC (default) |
| CPU | 16 vCPU available |
| RAM | 16,202 MB |
| Heap | 1024 MB fixed (`-Xms1G -Xmx1G`) |
| Workload | `bench/MemPressureBench.java`, 16 threads, 10.7 s |
| Power plan | *Balanced* (`381b4222-…`) — see `bench-v2-powerscheme.txt` |
| Logging | `-Xlog:gc*,gc+phases=debug,safepoint=info` |

For the tightest latency numbers, switch to the **High performance** power plan
and add the build output to Defender's exclusion list; both were left at
defaults here, so the published numbers are conservative.

## Reproducing

```powershell
# 1. Build (see the root README) and verify
powershell -ExecutionPolicy Bypass -File scripts\05_verify.ps1

# 2. Run the workload
#    -Jdk may be given explicitly, or exported as $env:J47_JDK
powershell -ExecutionPolicy Bypass -File scripts\06_bench.ps1 `
  -Jdk "C:\j47build\images\jdk" -Heap 1G -DurationSec 120 -Threads 16

# 3. Analyse the GC log
python scripts\07_gc_log_analyze.py --log out\bench-*\gc.log --csv summary.csv
```

Optional: collect a JFR recording and a safepoint trace in the same run —
`06_bench.ps1` already enables both and writes `bench.jfr` / `safepoint.log`.

```powershell
# Inspect the recording with the JFR tool shipped inside the built JDK
C:\j47build\images\jdk\bin\jfr.exe summary out\bench-*\bench.jfr
C:\j47build\images\jdk\bin\jfr.exe print --events jdk.SafepointBegin out\bench-*\bench.jfr
```

## Reading the output

`07_gc_log_analyze.py` prints one line per metric family:

```
Pause Phase (STW)  : n= 2375 avg=  0.014ms p50=  0.013 p99=  0.027 max=  0.741 total= 33.100
  Pause Young (Y/y): n= 2005 ...
  Pause Old (O)    : n=  370 ...
Cycle Young(Minor) : n=  474 ...
Cycle Old(Major)   : n=  185 ...
Concurrent Mark    : n=  853 ...
Concurrent Relocate: n=  853 ...
Allocation Stall   : n=  109 avg=  2.910ms p50=  2.202 p99= 13.948 max= 15.986 total= 317.208
```

**What counts as a "pause":** only `Pause Mark Start`, `Pause Mark End` and
`Pause Relocate Start` — the STW phases. Concurrent mark/relocate time is *not*
pause time; it runs on GC worker threads while the application keeps running.

**Two traps this analyzer already handles:**

1. **The shutdown summary table.** ZGC prints rows such as
   `Young Pause: Pause Mark Start   0.012 / 0.741   …  ms`. These are `min/max`
   column pairs, not samples. The parser drops any line containing `Pause:`.
   Without that filter the sample count inflates from 2,375 to 2,381 and P99
   moves from 0.027 ms to 0.028 ms.
2. **Two "Allocation Stall" line shapes.** The per-event form
   `Allocation Stall (thread) 4.340ms` is what the parser counts. The
   per-GC-counter form `Allocation Stalls:  2  2  2  0` is a summary of those
   events and must **not** be counted as additional stalls.

## Tuning checklist when you see problems

Full decision tree in [`../scripts/08_perf_guide.md`](../scripts/08_perf_guide.md).
Quick version:

| Symptom | First thing to try |
|---|---|
| Allocation stalls rising | raise `-Xmx`; then `-XX:ZAllocationSpikeTolerance=5` |
| Mark phase too slow | more `-XX:ConcGCThreads` |
| P99 pause creeping up | check safepoint sync time, not the collector |
| High safepoint sync on Windows | Defender exclusions + High performance power plan |
| JVM fails to start after patching | see the ergonomics crash note in the root README |
