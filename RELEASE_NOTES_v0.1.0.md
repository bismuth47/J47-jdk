> **日本語要約:** J47 v0.1.0 — Windows 向け超低レイテンシ独自 JDK のビルドキット初回リリース。
> P99 ポーズ **0.027 ms**、最大 **0.741 ms**、1 ms 超のポーズ **0 / 2,375**。
> 計測条件と解析手順は `benchmarks/RESULTS.md` にあります。

This is the first public release of **J47** — a patch set and build pipeline that
turns upstream OpenJDK 21u into a sub-millisecond-pause JVM tuned for Windows
and MSVC.

Generational ZGC is on by default, the Windows timer resolution is pinned high,
and HotSpot is linked with `/LTCG`. On a 16-vCPU Windows host the result is a
**P99 pause of 0.027 ms (27 µs)**, a **maximum of 0.741 ms**, and **zero** pauses
above 1 ms across 2,375 samples.

> J47 is **not** a drop-in replacement for Azul Prime (Zing), which is closed
> source and commercially licensed. It is an open, auditable way to reach
> Prime's latency class on Windows with a stock OpenJDK toolchain.

---

## The patches

| File | What it does |
|---|---|
| `J47-lowlatency.patch` | Generational ZGC selected by default; `ZGenerational`, `AlwaysPreTouch`, `ForceTimeHighResolution` flipped on; large-page diagnostics |
| `J47-throughput-2mb.patch` | ZGC-gated JIT ergonomics, and the removal of three measured regressions |
| `J47-msvc1944-c2280.patch` | MSVC 19.44 C2280 compatibility |
| `J47-tp-ergo-fix.patch` | **Superseded** — folded into the above; do not apply separately |
| `J47-throughput-2mb-jdk25.patch` | experimental `jdk25u` backport |

Every ergonomics change is wrapped in `FLAG_SET_ERGO_IF_DEFAULT`, so an explicit
`-XX:` on your command line still wins.

## The pipeline

`scripts/01` → `scripts/98`: environment check, patch verification, configure
(MSVC LTO), build, verify, benchmark, and a GC log analyzer
(`07_gc_log_analyze.py`).

```bash
git clone https://github.com/bismuth47/J47-jdk.git
cd J47-jdk
git clone --depth 1 --branch master https://github.com/openjdk/jdk21u.git jdk21u
cd jdk21u
git apply ../patches/J47-lowlatency.patch
git apply ../patches/J47-throughput-2mb.patch
git apply ../patches/J47-msvc1944-c2280.patch
# configure + build, from a shell where vcvars64.bat has been loaded
../scripts/02_configure_tp.sh ./jdk21u
../scripts/05_build.sh ./jdk21u
```

---

## Measured results

Re-derived from the raw unified log with the repository's own analyzer, not
carried over from an earlier report. Full methodology, including the parsing
traps, is in `benchmarks/RESULTS.md`.

| Metric | J47 | Target | Verdict |
|---|---:|---:|---|
| **P99 pause** | **0.027 ms** (27 µs) | < 1.0 ms | **37× better** |
| **Max pause** | **0.741 ms** | < 10 ms | **sub-millisecond** |
| **Pauses > 1 ms** | **0 of 2,375 (0.00 %)** | < 1 % | **pass** |
| Mean / P50 / P90 | 0.0139 / 0.013 / 0.019 ms | < 1 ms | pass |
| P99.9 / P99.99 | 0.101 / 0.657 ms | < 10 / < 50 ms | pass |
| Total STW | 33.1 ms over 668 GC cycles | — | — |
| Allocation stalls | 109 events, 317.2 ms total, 15.99 ms max | — | see below |

### Three corrections we are making loudly

**1. "Allocation Stalls: 0" was never true.** Re-reading the log shows **109
events, 317.2 ms total, 15.99 ms max**, across 55 GC cycles with non-zero stall
counters. An allocation stall is not a GC pause — it is an *application* thread
waiting to allocate because the collector has not reclaimed enough — and it does
not appear in the STW budget above. It is also not caused by J47: the run capped
a 1 GB live set into a 1024 MB heap with 16 allocating threads, a deliberately
over-subscribed configuration. It is still real, and 317 ms is ~3 % of the run.

**2. The sample count is 2,375 and P99 is 0.027 ms, not 2,381 / 0.028 ms.** ZGC
prints a summary table at shutdown whose rows look like pause lines but are
`min / max` column pairs. A parser without a `"Pause:"` filter counts those 6
rows and reports the higher figures. `07_gc_log_analyze.py` excludes them, and
the CI has a self-test that keeps it honest.

**3. The numbers come from one 16-vCPU Windows host**, on the *Balanced* power
plan, with Defender left enabled — so they are conservative, not tuned. They are
not a claim about your hardware. Reproduce with `scripts/06_bench.ps1` plus
`scripts/07_gc_log_analyze.py`.

---

## Known issues

- Patches are pinned to **`jdk-21.0.13+7`**. On a much newer `master` the context
  lines will not match and `git apply` will refuse. That is intentional.
- Large pages require `SeLockMemoryPrivilege` and stay **opt-in per run**
  (`-XX:+UseLargePages`). Forcing them from ergonomics crashed every JVM start
  with `EXCEPTION_INT_DIVIDE_BY_ZERO` in `GCArguments::compute_heap_alignment`;
  CI has a regression guard for exactly this.
- `installer/J47.wxs` is deliberately not published. The harvested WiX fragment
  carries 571 absolute `Source=` paths from the machine that produced it, so
  shipping it would hand everyone a broken MSI. `scripts/build_msi.ps1` takes a
  product shell via `-Wxs` and re-harvests the file list itself.
- The attached `.msi` / `.zip` are the artefacts produced during development on
  that host; they are **not** rebuilt by CI in this release.
- **Do not build inside OneDrive, Dropbox or any synced folder.** Writing the
  357 MB interim `java.base.jmod` through a sync client took over 15 minutes and
  produced sporadic `LNK1327` (rc.exe) failures. Use the out-of-source mode
  described in the README.

---

## Continuous integration

`ci.yml` runs on every push and pull request in about a minute. It does not
compile a JVM — it guards what breaks silently: the patch set still applying to
the pinned tag, the J47 GC defaults still being flipped, the large-page
regression not returning, every `.ps1` still parsing, `.cmd`/`.bat` still
ASCII-only, shell and patch files still LF, the analyzer still correct, and the
README headline figures still agreeing with the published CSV.

The full build is `build-windows.yml`: **manual and self-hosted**, because a JDK
build needs Cygwin64, a Boot JDK, the Windows SDK and ~6 GB of scratch for 20–40
minutes, and GitHub-hosted Windows runners do not have Cygwin. Registration
instructions are in that workflow's header.

---

## Assets

| File | Size | Notes |
|---|---:|---|
| `J47-JDK-21.zip` | 182 MB | portable image; `bin/java.exe` verified to run and report the J47 defaults |
| `J47-JDK-21.msi` | 181 MB | Windows Installer package, x64 |

Both are Git-**ignored** build outputs, which is why they live here rather than
in the tree.

## License

GPL-2.0 with the Classpath Exception — the same license as OpenJDK. The patches
are derivative works of OpenJDK source; the Classpath Exception is what allows
independent modules to link against the JDK APIs.

## Acknowledgements

* **OpenJDK** — the entire base (`jdk21u`, GPL-2.0+CPE).
* **Azul Zulu** — the Boot JDK used to bootstrap the build.

This project is **not** affiliated with, endorsed by, or derived from **Azul
Systems / Azul Prime (Zing)**. Prime is referenced only as the commercial product
whose latency class J47 aims to make reachable from open sources.
