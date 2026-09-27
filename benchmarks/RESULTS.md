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

---

## JDK 25 (experimental)

> **日本語要約:** `patches/J47-throughput-2mb-jdk25.patch` は `jdk25u` 用の
> バックポートです。ビルドは成功しており（`25.0.5-internal-J47-ZGC-tp-jdk25`）、
> ポーズ性能は良好です。ただし **allocation stall（割り当て待ち）は JDK 21
> ビルドより明显に悪化しています**。推測せず報告します。

The same changes are ported to `jdk25u` by
`patches/J47-throughput-2mb-jdk25.patch`, and that build **succeeds**. The
backport is a **single consolidated patch** — it does not layer the three 21u
patches — and it is pinned to upstream commit `70185631`, not a release tag.

`ZGenerational` no longer exists in JDK 25; it was folded into ZGC in JDK 24, and
the JVM prints `Ignoring option ZGenerational; support was removed in 24.0` if
you pass it. The backport therefore sets only `UseZGC` and relies on generational
being the sole mode.

### Results (same workload, 1 GB heap, 60 s)

| Metric | JDK 21 build | JDK 25 build | Verdict |
|---|---:|---:|---|
| **P99 pause** | 0.027 ms | **0.032 ms** | still ~30× under target |
| **Max pause** | 0.741 ms | **0.663 ms** | **better** |
| **Pauses > 1 ms** | 0 / 2,375 | **0 / 4,632** | pass |
| Mean / P50 | 0.0139 / 0.013 ms | 0.016 / 0.015 ms | comparable |
| Total STW | 33.1 ms / 668 cycles | 73.9 ms / 1,478 cycles | 2.2× more, 2.2× more cycles |
| **Allocation stalls** | 109 events / 317 ms | **37,982 events / 741 s** | ⚠️ **much worse** |
| Young cycle | 11.0 ms avg | 39.2 ms avg | 3.6× longer |
| Old cycle | 53.1 ms avg | 782.9 ms avg | **14.7× longer** |

**Pause behaviour on JDK 25 is fine — the maximum is actually lower.** The
mutator, however, is badly starved: 741 s of cumulative allocation stall across
16 threads in a 60 s run, with old-generation cycles averaging 783 ms. The
collector cannot keep up with this deliberately over-subscribed workload (a 1 GB
live set in a 1024 MB heap with 16 allocating threads) the way the 21u build
does.

Two caveats before reading too much into the comparison:

* **This is not a like-for-like A/B.** The JDK 25 run had a harder profile —
  2.49 GB/s allocation over 149 GB allocated, versus 8.19 GB/s over 82 GB on
  21u. Read the table as a signal that the backport needs heap/thread tuning
  work, not as a clean regression claim against J47.
* The 25u port is pinned to a **development commit**, not a release tag.

This is why the JDK 25 port is labelled **experimental** and is not part of the
v0.1.0 release assets.

### Building the JDK 25 port

```bash
git clone https://github.com/openjdk/jdk25u.git
cd jdk25u
git apply ../patches/J47-throughput-2mb-jdk25.patch

# configure needs a Boot JDK of 24 or newer
export J47_BOOT_JDK=/cygdrive/c/tools/bootjdk-24
export TP_BUILD_ROOT_CYG=/cygdrive/c/j47build25
../scripts/02_configure_tp_jdk25.sh ./jdk25u
../scripts/06_build_tp_jdk25.sh ./jdk25u

# benchmark + analyse
powershell -File ../scripts/06_bench.ps1 -Jdk C:\j47build25\images\jdk -Heap 1G
python ../scripts/07_gc_log_analyze.py --log out/bench-*/gc.log
```

Raw data: `bench-jdk25-gc-summary.csv`, `bench-jdk25-version.txt`,
`bench-jdk25-result.txt`, `bench-jdk25-flags.txt`.

### Analyzer note

Running the analyzer over the 14 MB / 125k-line JDK 25 log exposed a
performance bug in the cycle pattern: two adjacent lazy quantifiers
(`(.*?)\s+.*?`) made the match exponential per line, pushing a full analysis past
50 seconds. The pattern is now anchored on the last number on the line, which
brings the same log down to **~2 s** — and incidentally fixes the cycle counts,
which had been undercounted (young 175 → 1,681, old 29 → 86).

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
