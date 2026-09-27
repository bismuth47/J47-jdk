# Benchmark Results — J47 Generational ZGC on Windows

> **日本語要約:** J47 のビルドで実測した ZGC ポーズ時間の結果です。
> P99 = **0.027 ms (27 µs)**、最大 = **0.741 ms**、1 ms 超のポーズは **0 回 / 2,375 サンプル**。
> 詳細的解析手順と再現方法は [`README.md`](README.md) を参照してください。

All numbers below were **re-derived from the raw unified-logging output**
(`out/bench-v2/gc.log`, 47,670 lines) using the repository's own analyzer,
`scripts/07_gc_log_analyze.py`. They are not carried over from a previous
report; see [Methodology](#methodology) for exactly how each figure is derived.

## Headline results

| Metric | J47 result | Target | Verdict |
|---|---:|---:|---|
| **P99 pause time** | **0.027 ms** (27 µs) | < 1.0 ms | **37× under target** |
| **Max pause time** | **0.741 ms** | < 10 ms | **sub-millisecond** |
| **Pauses > 1 ms** | **0 of 2,375 (0.00 %)** | < 1 % | **pass** |
| Mean pause | 0.0139 ms | < 1 ms | pass |
| P50 / P90 pause | 0.013 / 0.019 ms | < 0.5 / < 5 ms | pass |
| P99.9 / P99.99 pause | 0.101 / 0.657 ms | < 10 / < 50 ms | pass |
| Total STW over the run | 33.1 ms across 668 GC cycles | — | — |
| **Allocation stall events** | **109 (317.2 ms total, 15.99 ms max)** | — | see note |

### Pause time distribution

```
n = 2,375 pause phases   (max / p99.99 / p99.9 / p99 / p90 / p50 / mean)
 0.741 ms  ################################################
 0.657 ms  ################################################
 0.101 ms  #########################
 0.027 ms  #########
 0.019 ms  #######
 0.013 ms  #####       <- median
 0.014 ms  #####       <- mean
```

The distribution is extremely tight around ~13 µs with a long, thin tail that
never crosses 1 ms. This is the signature of a healthy concurrent collector: the
STW work is limited to root scanning and page-table updates, while marking and
relocation run concurrently.

### Concurrent phases (the actual work, off the pause path)

| Phase | Samples | Mean | Max | Total |
|---|---:|---:|---:|---:|
| Concurrent Mark | 853 | 3.95 ms | 17.26 ms | 3,367.9 ms |
| Concurrent Relocate | 853 | 2.12 ms | 10.68 ms | 1,809.1 ms |
| Young cycle | 474 | 11.03 ms | 21 ms | 5,229 ms |
| Old cycle | 185 | 53.07 ms | 104 ms | 9,818 ms |

~5.2 seconds of concurrent work were completed across a 10.7-second run, none
of which landed on the application threads as stop-the-world time.

## Note on allocation stalls

The run recorded **109 allocation-stall events totalling 317.2 ms (max
15.99 ms)** — visible both as `Allocation Stall (thread) X ms` lines and as
non-zero `Allocation Stalls:` counter rows on 55 GC cycles.

It is worth being precise about what this does and does not mean:

* An **allocation stall is not a GC pause.** It is an *application* thread
  waiting for the mutator to be able to allocate, because the collector has not
  yet reclaimed enough. It does not appear in the STW pause budget above and it
  is not caused by safepointing.
* It is also **not a J47 regression**. The heap was capped at 1024 MB
  (`Max Capacity: 1024M`) while 16 worker threads allocated 3×32 KB every 5 ms
  against a 1 GB live set — a deliberately over-subscribed configuration.
* The practical consequence is real, though: 317 ms of stall time is 3 % of the
  run. If you run J47 in production, size `-Xmx` so that the live set sits well
  below the cap, and tune `-XX:ZAllocationSpikeTolerance`. `scripts/08_perf_guide.md`
  has the full decision tree.

Earlier drafts of this project reported "Allocation Stalls: 0". That number does
not survive re-reading the log, so the table above reports what the log actually
contains.

## Methodology

* **Source of truth:** `out/bench-v2/gc.log`, produced by
  `scripts/06_bench.ps1` with
  `-Xlog:gc*,gc+phases=debug,safepoint=info`.
* **Parsing:** `python scripts/07_gc_log_analyze.py --log out/bench-v2/gc.log`
* **Percentiles:** linear interpolation between order statistics
  (numpy default). Nearest-rank values are noted where they differ.
* **Excluded — the end-of-run summary table.** ZGC prints a summary block at
  shutdown whose rows *look* like pause lines:
  ```
  Young Pause: Pause Mark Start       0.012 / 0.741   ...  ms
  ```
  Those are `min / max` column pairs, not samples. A regex without a
  `"Pause:"` exclusion picks up 6 of them and reports **2,381** samples and
  **P99 = 0.028 ms**. The analyzer excludes them, giving the correct
  **2,375** samples and **P99 = 0.027 ms**. Any figure quoting 2,381 samples
  or P99 = 0.028 ms was produced by the unfiltered parser.
* **Run configuration:** heap fixed at 1024 MB, 16 threads, 10.7 s duration,
  16 vCPU / 16,202 MB RAM, Windows power plan *Balanced* (see
  `bench-v2-powerscheme.txt`), 1 GB live set.
* **Build under test:** `21.0.13-internal-J47-ZGC-default` (see
  `bench-v2-version.txt` and `bench-v2-flags.txt`).

## Files in this directory

| File | Contents |
|---|---|
| `RESULTS.md` | This document |
| `README.md` | How to reproduce, environment details, caveats |
| `gc-performance-summary.csv` | Headline metrics, machine-readable |
| `bench-v2-gc-summary.csv` | Raw output of the analyzer for this run |
| `bench-v2-version.txt` | `java -version` of the build under test |
| `bench-v2-flags.txt` | Key `-XX:+PrintFlagsFinal` values |
| `bench-v2-result.txt` | Workload throughput and latency summary |
| `bench-v2-powerscheme.txt` | Windows power plan during the run |
| `ANALYSIS_SUMMARY.md` | Original analysis narrative |
| `PERFORMANCE_ANALYSIS.md` | Original long-form report |

The raw 5.9 MB `gc.log`, the JFR recording and the safepoint log are **not**
committed — they are regenerable and are covered by `.gitignore` under `out/`.
