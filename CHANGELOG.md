# Changelog

All notable changes to J47. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html) for the
patch set.

## [Unreleased]

### Added
- Release tooling: `scripts/repo/00_organize_repo.{ps1,sh}` builds the folder
  layout from a loose working directory, normalises `*.sh` / `*.patch` / `*.py`
  to LF, and is idempotent with a backup of every relocated original.
- `scripts/repo/10_git_init_commit.{ps1,sh}` and
  `scripts/repo/20_check_repo_size.ps1` for initialising, staging and
  publishing this repository without committing an oversized blob.
- Windows SDK auto-detection in all three `02_configure*.sh` scripts, replacing
  hardcoded 8.3 paths. Override with `J47_SDK_VER` / `J47_WDK_ROOT`.
- `benchmarks/RESULTS.md` documenting the measurement methodology, and
  `benchmarks/README.md` for reproduction.

### Changed
- **Repository restructured** into `patches/`, `scripts/`, `benchmarks/`,
  `docs/`, `bench/`, `installer/`, with a strict `.gitignore` keeping the
  OpenJDK checkout, build output, installers and logs out of Git.
- All build scripts now resolve the repository root from their own location, so
  they work from any checkout path and on any machine.
- `run_build_tp2.cmd` / `run_build_j47build.cmd` auto-detect `vcvars64.bat`
  across VS editions, the Windows SDK `bin` directory, and the build root;
  all are overridable via environment variables.
- README rewritten for an international audience, with a Japanese summary.

### Fixed
- Large pages are no longer forced from ergonomics. The previous behaviour made
  **every** JVM start die with `EXCEPTION_INT_DIVIDE_BY_ZERO` in
  `GCArguments::compute_heap_alignment` (`lcm(0, alignment)`).
- `LoopStripMiningIter` / `UseCountedLoopSafepoints` are no longer forced to
  `1`, which had turned strip mining into a safepoint poll on every
  counted-loop iteration.
- `MaxVectorSize` is no longer forced to `64`, which produced a warning on every
  start on AVX2-only CPUs while the value was clamped to 32 anyway.

## [0.1.0] — 2026-09-27

Initial working build.

### Added
- `J47-lowlatency.patch` — Generational ZGC selected by default in
  `GCConfig::select_gc_ergonomically`; `ZGenerational`, `AlwaysPreTouch` and
  `ForceTimeHighResolution` flipped to `true` in `gc_globals.hpp` /
  `globals.hpp`; large-page diagnostics in `os_windows.cpp`.
- `J47-throughput-2mb.patch` — ZGC-gated JIT ergonomics.
- `J47-msvc1944-c2280.patch` — MSVC 19.44 C2280 compatibility.
- `J47-tp-ergo-fix.patch` — recorded diff of the ergonomics fix. **Superseded:**
  the fix is folded into `J47-throughput-2mb.patch`; do not apply separately.
- `J47-throughput-2mb-jdk25.patch` — experimental `jdk25u` backport.
- Build pipeline `01` → `98` and the `07_gc_log_analyze.py` GC log analyzer.

### Measured
- 668 GC cycles, 2,375 STW pause samples over a 10.7 s run.
- **P99 pause 0.027 ms, max pause 0.741 ms, 0 pauses above 1 ms.**
- 109 allocation-stall events totalling 317.2 ms (max 15.99 ms) on a
  deliberately over-subscribed 1 GB heap.

### Known issues
- The committed figures were originally reported as *2,381 samples / P99
  0.028 ms* and *"allocation stalls: 0"*. Both were incorrect; the first
  double-counted ZGC's end-of-run summary table, the second was never measured.
  Corrected in this release — see `benchmarks/RESULTS.md`.

[Unreleased]: https://github.com/<you>/<repo>/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/<you>/<repo>/releases/tag/v0.1.0
