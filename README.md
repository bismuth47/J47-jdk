# Ultra-Low Latency Custom OpenJDK for Windows
### *Generational ZGC + MSVC Link-Time Optimization — a reproducible build kit*

[![License: GPL-2.0 with Classpath Exception](https://img.shields.io/badge/License-GPLv2%20%2B%20CPE-blue.svg)](LICENSE)
[![Base: OpenJDK 21u](https://img.shields.io/badge/base-OpenJDK%2021u-437291.svg)](https://github.com/openjdk/jdk21u)
[![Platform: Windows x64](https://img.shields.io/badge/platform-Windows%20x64-0078D4.svg)](https://learn.microsoft.com/windows/)
[![GC: Generational ZGC](https://img.shields.io/badge/GC-Generational%20ZGC-8A2BE2.svg)](https://openjdk.org/jeps/439)

---

## TL;DR

**J47 is a patch set plus build pipeline that turns upstream OpenJDK 21u into a
sub-millisecond-pause JVM tuned for Windows and MSVC.** Generational ZGC is on
by default, the Windows timer resolution is pinned high, and HotSpot is linked
with `/LTCG`. On a 16-vCPU Windows box the result is a **P99 pause time of
0.027 ms (27 µs)** and a **maximum pause of 0.741 ms**, with **zero** pauses
above 1 ms across 2,375 samples.

The goal is to make an **Azul Prime (Zing)-class collector available on Windows
from fully open sources** — Prime is closed-source and commercially licensed,
so J47 is not a drop-in replacement for it. It is an open, auditable way to get
sub-millisecond tail latency on Windows with a stock OpenJDK toolchain.

### 日本語要約

**J47** は、OpenJDK 21u にパッチを適用し、Windows / MSVC 向けに最適化したビルドキットです。
Generational ZGC を既定collector にし、Windows の高精度タイマーを有効化し、
HotSpot を `/LTCG`（リンク時最適化）でビルドします。

実測結果（16 vCPU / Windows）:

| 項目 | 実測値 | 目標 | 判定 |
|---|---:|---:|---|
| **P99 ポーズ時間** | **0.027 ms (27 µs)** | < 1.0 ms | 目標の **1/37** |
| **最大ポーズ時間** | **0.741 ms** | < 10 ms | サブミリ秒達成 |
| **1 ms 超のポーズ** | **0 / 2,375 (0.00 %)** | < 1 % | 合格 |
| **Allocation Stall** | 109 回 / 計 317.2 ms | — | 解説あり ↓ |

> ⚠️ **Allocation Stall について:** 以前の本リポジトリでは「0 回」と報告していましたが、
> 生の GC ログを再解析すると実際には **109 回（計 317.2 ms、最大 15.99 ms）** でした。
> ここで-publishedする数値はログから再導出したもののみです。詳細と理由 →
> [`benchmarks/RESULTS.md`](benchmarks/RESULTS.md)

**Azul Prime (Zing) について:** Prime は商用・クローズソースであり、本リポジトリは
その代替ではなく、**Windows でサブミリ秒のテールレイテンシを完全オープンソースで
実現するための再現可能な手段**です。

---

## What J47 changes

Six HotSpot files are patched. Every change is small, guarded, and
revertible with a single `-XX` flag.

### 1. Generational ZGC by default

`patches/J47-lowlatency.patch` changes GC selection in
`src/hotspot/share/gc/shared/gcConfig.cpp` (`GCConfig::select_gc_ergonomically`)
so a server-class machine starts in ZGC instead of G1, and flips the flag
defaults in `gc_globals.hpp`:

| Flag | Upstream | J47 |
|---|---|---|
| `UseZGC` | `false` | `true` (ergonomic) |
| `ZGenerational` | `false` | `true` |
| `AlwaysPreTouch` | `false` | `true` |
| `ForceTimeHighResolution` | `false` | `true` |

All four are set with `FLAG_SET_ERGO_IF_DEFAULT`, so **an explicit `-XX:` on
your command line still wins.** Overriding JGC behaviour costs you nothing.

> The ergonomics change belongs in `gcConfig.cpp`, *not* in
> `Arguments::apply_ergo()` — the GC is selected before compiler ergonomics run.
> `ZGenerational` no longer exists in JDK 24+, so drop that hunk when backporting.

### 2. Safe 2 MB large-page ergonomics

Windows large pages are the single biggest win for TLB pressure, but they are
*not* free to turn on, and getting this wrong is the failure mode documented in
[`docs/BUILD_SUMMARY.md`](docs/BUILD_SUMMARY.md):

* Large pages need `SeLockMemoryPrivilege` (*Lock Pages in Memory*). Without it
  the JVM silently falls back to 4 KB pages.
* **`UseLargePages` must not be forced from ergonomics.** An earlier revision did
  exactly that and *every JVM start crashed* with
  `EXCEPTION_INT_DIVIDE_BY_ZERO` in `GCArguments::compute_heap_alignment`:
  `os::large_page_init()` runs *before* ergonomics, so `os::large_page_size()`
  was still `0`; forcing the flag on then made the JVM evaluate `lcm(0, alignment)`,
  which divides by `MIN2(0, …) = 0` (`utilities/globalDefinitions.cpp`).
* J47 therefore leaves large pages **opt-in per run** (`-XX:+UseLargePages`) and
  only adds diagnostics that make the decision visible:

  ```
  [info][gc] J47: Large pages selected (min=2097152, req=2097152).
  [warning][gc] J47: SeLockMemoryPrivilege missing ([Lock Pages in Memory] not
                    granted). Large pages disabled, continuing with regular pages.
  ```

  `EnableAllLargePageSizesForWindows` is left `false` so 1 GB pages stay out of
  the picture.

### 3. MSVC Link-Time Optimization

Enabled at configure time with `--enable-jvm-feature-link-time-opt`, which maps
to `-GL` at compile time and `/LTCG` at link time. The configure scripts also
pass `-Gw -Gy -GF` (enable common, inline and global data optimization) plus
`-OPT:REF -OPT:ICF` for dead-code and identical-function folding.

PGO (`/GENPROFILE`) is **not** supported by the JDK's `configure`; if you want
it, run the build manually in two passes.

### 4. High-resolution Windows timer

`ForceTimeHighResolution` defaults to `true`. The existing `DllMain` branch in
`os_windows.cpp` already calls `timeBeginPeriod(1L)` when this flag is set, so
no raw `timeBeginPeriod` call was added — that approach was tried and reverted.

### 5. Throughput-recovery ergonomics (ZGC-gated)

`patches/J47-throughput-2mb.patch` tunes the JIT **only when ZGC is active**, so
nothing leaks into non-ZGC runs:

```cpp
if (UseZGC) {
  FLAG_SET_ERGO_IF_DEFAULT(UseSuperWord, true);
  FLAG_SET_ERGO_IF_DEFAULT(InlineSmallCode, 2500);
  FLAG_SET_ERGO_IF_DEFAULT(FreqInlineSize, 325);
  FLAG_SET_ERGO_IF_DEFAULT(MaxInlineSize, 50);
  FLAG_SET_ERGO_IF_DEFAULT(CICompilerCount, 4);
  FLAG_SET_ERGO_IF_DEFAULT(ReservedCodeCacheSize, 512*M);
  FLAG_SET_ERGO_IF_DEFAULT(AlwaysPreTouch, true);
}
```

The deltas are deliberately small. Larger inline/unroll settings inflate
nmethods, hurt the i-cache, and *lengthen* the sub-millisecond pause budget —
the opposite of what this project is for.

Two things are **intentionally not** forced, both because forcing them was a
measured regression:

* **`LoopStripMiningIter` / `UseCountedLoopSafepoints`** — ZGC already sets
  these as defaults (`true` / `1000`, `zArguments.cpp`). Forcing them
  ergonomically made `LoopStripMiningIterConstraintFunc` print a warning on
  every start and rewrite the value to `1`, i.e. a safepoint poll on every
  counted-loop iteration instead of real strip mining.
* **`MaxVectorSize`** — `MaxVectorSizeConstraintFunc` rejects `64` on AVX2-only
  CPUs, so every start logged *"MaxVectorSize must be at most 32 on this
  platform"* while the value was clamped to 32 anyway. The auto default already
  picks the platform maximum.

### 6. MSVC 19.44 compatibility

`patches/J47-msvc1944-c2280.patch` works around the stricter C2280
(*pointers to members with explicit initializers*) diagnostic in MSVC 19.44 so
that recent VS 2022 toolchains can build HotSpot.

---

## Measured results in detail

Re-derived from the raw unified log by the repository's own analyzer
(`scripts/07_gc_log_analyze.py`). Full methodology in
[`benchmarks/RESULTS.md`](benchmarks/RESULTS.md).

| Metric | J47 | Target | Verdict |
|---|---:|---:|---|
| **P99 pause** | **0.027 ms** (27 µs) | < 1.0 ms | **37× better** |
| **Max pause** | **0.741 ms** | < 10 ms | **sub-millisecond** |
| **Pauses > 1 ms** | **0 of 2,375 (0.00 %)** | < 1 % | **pass** |
| Mean pause | 0.0139 ms | < 1 ms | pass |
| P50 / P90 | 0.013 / 0.019 ms | < 0.5 / < 5 ms | pass |
| P99.9 / P99.99 | 0.101 / 0.657 ms | < 10 / < 50 ms | pass |
| Total STW | 33.1 ms over 668 GC cycles | — | — |
| Allocation stalls | 109 events, 317.2 ms total, 15.99 ms max | — | [explained](benchmarks/RESULTS.md#note-on-allocation-stalls) |

> **Note on the sample count.** You may see *2,381 samples / P99 0.028 ms* quoted
> elsewhere for this build. Those numbers come from a parser that also counts the
> 6 rows of ZGC's end-of-run **summary table**, which are `min/max` column pairs
> rather than samples. The correct figures are **2,375** and **0.027 ms**.

---

## Requirements

| | Requirement | Notes |
|---|---|---|
| **OS** | Windows 10 / 11, x64 | 32-bit Windows is not supported by modern JDKs |
| **Compiler** | Visual Studio 2022 (17.x) | Community / Professional / Enterprise / Build Tools all work |
| **Windows SDK** | 10.0.22621.0 or later | auto-detected by the configure scripts |
| **POSIX layer** | **Cygwin64** | MSYS2 often fails at `configure`; see `scripts/01_env_check.sh` |
| **Boot JDK** | JDK 21+ | e.g. Azul Zulu 21, unpacked to `C:\tools\bootjdk-21` |
| **Disk** | ~6 GB free | build-heavy |
| **RAM** | 8 GB+ | 16 GB recommended |
| **Privilege** | `SeLockMemoryPrivilege` | only needed for `-XX:+UseLargePages` |

---

## Build and patch — step by step

### Step 0 — Get the kit

```powershell
git clone https://github.com/<you>/<this-repo>.git
cd <this-repo>
```

You should see `patches/`, `scripts/`, `benchmarks/`, `docs/`, `bench/`,
`installer/`. The OpenJDK source tree is **not** in the repository — you fetch
it in the next step.

### Step 1 — Check the environment

```powershell
# Elevated PowerShell: verifies BootJDK, SeLockMemoryPrivilege, sets JAVA_HOME
powershell -ExecutionPolicy Bypass -File scripts\01_env_check.ps1
```

Grant *Lock Pages in Memory* via `gpedit.msc` → *Local Security Policy* →
*User Rights Assignment* and sign out/in, or large pages stay off.

### Step 2 — Fetch the OpenJDK source

```powershell
git clone --depth 1 --branch master https://github.com/openjdk/jdk21u.git jdk21u
```

The committed results were produced against **`jdk-21.0.13+7`**
(commit `82c3abe72`). Patches are pinned to that layout; on a much newer
`master` the context lines may not match and `git apply` will refuse — that is
the correct behaviour, not a bug.

### Step 3 — Apply the patches, in order

```powershell
cd jdk21u
git apply ..\patches\J47-lowlatency.patch
git apply ..\patches\J47-throughput-2mb.patch
git apply ..\patches\J47-msvc1944-c2280.patch
git --no-pager diff --stat      # expect 6 files changed
```

> Verify reproducibility at any time with
> `powershell -ExecutionPolicy Bypass -File ..\scripts\verify_patches.ps1` —
> it applies the set to a pristine worktree and asserts the resulting tree hash
> matches your working tree exactly.

### Step 4 — Configure

`configure` must see a real MSVC environment, and it is easier to run from
Cygwin bash. Use the wrapper, which handles the `vcvars64.bat` handshake:

```powershell
cmd /c "call ""C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"" && C:\cygwin64\bin\bash.exe --login"
```

```bash
# inside Cygwin bash, at the repository root
./scripts/02_configure_tp.sh ./jdk21u
```

It auto-detects the Windows SDK and passes:

```
--with-debug-level=release
--with-jvm-variants=server
--with-jvm-features=zgc,cds,compiler1,compiler2,g1gc,parallelgc,serialgc,epsilongc
--enable-jvm-feature-link-time-opt
--disable-warnings-as-errors
--with-vendor-name=J47 --with-version-opt=J47-ZGC-tp2
```

> `--with-build-type` and `--enable-lto` are **not** valid for the JDK 21
> `configure`; use `--with-debug-level` and
> `--enable-jvm-feature-link-time-opt` as above.

### Step 5 — Build

```powershell
# back in the vcvars64 shell
scripts\run_build_tp2.cmd
```

or, from Cygwin bash:

```bash
./scripts/05_build.sh ./jdk21u
```

Expect roughly 20–40 minutes on 16 cores. The image lands in
`jdk21u/build/windows-x86_64-server-release/images/jdk`.

> **Do not build inside OneDrive, Dropbox, or any synced folder.** See
> [Known pitfalls](#known-pitfalls). Use the out-of-source mode instead:
> ```bash
> export TP_BUILD_ROOT_CYG=/cygdrive/c/j47build
> ./scripts/02_configure_tp.sh ./jdk21u
> ./scripts/05_build.sh ./jdk21u
> ```

### Step 6 — Verify

```powershell
scripts\05_verify.ps1
```

Checks that the JVM starts, that `UseZGC`, `ZGenerational` and `AlwaysPreTouch`
are on, and that ZGC initialises:

```
=== [1/4] JVM startup (the crash that was fixed) ===
=== [2/4] J47 default flags (ZGC / pre-touch / timing / large pages) ===
=== [3/4] GC log smoke test ===
=== [4/4] verdict ===
VERIFY OK: UseZGC=true / AlwaysPreTouch=true (J47 defaults applied)
```

### Step 7 — Run it

```powershell
$env:J47_JDK = "C:\j47build\images\jdk"
& "$env:J47_JDK\bin\java.exe" -XX:+PrintFlagsFinal -version 2>&1 |
  Select-String "UseZGC|ZGenerational|AlwaysPreTouch|ForceTimeHighResolution"

# representative low-latency run
& "$env:J47_JDK\bin\java.exe" `
  -Xms8G -Xmx8G -XX:+UseLargePages -XX:ReservedCodeCacheSize=512M `
  -XX:CICompilerCount=4 -XX:+ZAllocationSpikeTolerance=5 `
  -Xlog:gc*,gc+phases=debug:file=gc.log:time,uptime `
  -jar your-app.jar
```

`-XX:+UseZGC`, `-XX:+ZGenerational` and `-XX:+AlwaysPreTouch` are already the
defaults, so you only need them if you are running an older image.

### Step 8 — Benchmark and analyse

```powershell
scripts\06_bench.ps1 -Jdk "C:\j47build\images\jdk" -Heap 1G -DurationSec 120
python scripts\07_gc_log_analyze.py --log out\bench-*\gc.log
```

---

## Known pitfalls

These were all hit during development; each one cost real time.

### Never build inside OneDrive / a synced folder

Writing the 357 MB interim `support/interim-jmods/java.base.jmod` through the
OneDrive sync client took **over 15 minutes**, and produced sporadic
`LNK1327: error during running rc.exe` plus hung `make.exe` / `bash.exe` pairs.

Fix: build out of source, outside the sync tree.

```bash
export TP_BUILD_ROOT_CYG=/cygdrive/c/j47build
```

A directory **junction is not a valid substitute** — `spec.gmk` embeds absolute
paths, so the tree must be *moved and re-configured*, not linked. The proven
sequence is: `robocopy /MOVE` the old `images`, then a fresh out-of-source
`configure`, then `make images`.

### `configure` cannot find MSVC unless bash inherits `vcvars64`

`configure` detects the compiler through `VS170COMNTOOLS`, which
`vcvars64.bat` exports. Starting Cygwin bash from a plain prompt gives an empty
environment and `configure` fails. Always start bash *from* the vcvars shell
(`scripts/run_build_tp2.cmd` does this for you).

### `LNK1104: cannot open file kernel32.lib`

The extracted vcvars environment loses the SDK `um` and `shared` include
directories. The configure scripts re-add them via `--with-extra-cflags` /
`--with-extra-cxxflags` / `--with-extra-ldflags`, auto-detecting the SDK
version. Override with `J47_SDK_VER` and `J47_WDK_ROOT` if your layout differs.

### Building in a directory whose path contains spaces

Handled by the wrappers, but note the SDK path itself contains
`Program Files (x86)`. The configure scripts split the detected root without
word-splitting for exactly this reason.

### If the JVM dies instantly with `EXCEPTION_INT_DIVIDE_BY_ZERO`

You are on a build where `UseLargePages` was forced from ergonomics. That
regression is documented in [`docs/BUILD_SUMMARY.md`](docs/BUILD_SUMMARY.md);
the fix is to re-apply `patches/J47-throughput-2mb.patch` over the tree, which
removes the forced large-page, loop-strip-mining and `MaxVectorSize`
ergonomics.

### Hung build

```powershell
Get-Process make, bash -ErrorAction SilentlyContinue | Stop-Process -Force
```

then re-run. Pinning `TMP`/`TEMP` off the sync folder (the `.cmd` wrappers do
this) avoids most of it.

---

## Repository layout

```
.
├── patches/                  the product - 5 patch files
│   ├── J47-lowlatency.patch            ZGC / ergonomics defaults
│   ├── J47-throughput-2mb.patch        ZGC-gated JIT ergonomics
│   ├── J47-msvc1944-c2280.patch        MSVC 19.44 compatibility
│   ├── J47-tp-ergo-fix.patch           superseded - folded into the above
│   └── J47-throughput-2mb-jdk25.patch  backport for jdk25u
├── scripts/                  the build pipeline (00 -> 98)
│   ├── 01_env_check.{ps1,sh}
│   ├── 02_configure*.sh               3 variants (generic / TP / JDK 25)
│   ├── 05_build.sh   05_verify.ps1
│   ├── 06_bench.ps1   06_build_tp*.sh
│   ├── 07_gc_log_analyze.py           the GC log analyzer
│   ├── 08_perf_guide.md               tuning decision tree
│   ├── run_build_*.cmd                vcvars64 build wrappers
│   ├── verify_patches.ps1             patch-set reproducibility check
│   ├── install.ps1                    user-scope installer
│   └── repo/                          release tooling for this repository
│       ├── 00_organize_repo.{ps1,sh}  build the folder layout
│       ├── 10_git_init_commit.{ps1,sh} init, stage, commit, push
│       └── 20_check_repo_size.ps1     refuse to commit oversized blobs
├── benchmarks/               aggregated results (CSV / MD / small text only)
├── docs/                     build notes and the incident write-up
├── bench/                    MemPressureBench.java workload
├── installer/                J47.nsi (NSIS source) + icon
├── .gitignore  .gitattributes  .editorconfig  LICENSE  CHANGELOG.md
├── CONTRIBUTING.md  SECURITY.md  CODE_OF_CONDUCT.md
└── README.md
```

### Deliberately **not** in Git

The OpenJDK checkout, build output, installers and logs stay on disk and are
excluded by `.gitignore`:

| Path | Why |
|---|---|
| `jdk21u/`, `jdk25u/` | ~1.2 GB upstream source, and a git repo of its own |
| `build/`, `out/`, `images/` | build and benchmark output |
| `*.obj *.dll *.exe *.lib *.pdb *.jmod` | compiled artefacts |
| `*.jfr`, `gc.log*`, `safepoint.log*` | recordings; large and regenerable |
| `*.log`, `*.err` | `tp_build_j47build.log` alone is 23 MB |
| `*.msi`, `*.zip`, `*.exe` | the `J47-JDK-21` installers are ~190 MB each |
| `*.wxs`, `msi/` | the harvested WiX fragment bakes in 571 absolute `Source=` paths from the machine that produced it — shipping it would hand everyone a broken MSI |
| `tools/`, `.j47-organize-backup/` | local downloads and script backups |

Publish binaries through **GitHub Releases**, never through the Git tree.
`scripts/repo/20_check_repo_size.ps1` runs as a pre-commit guard so an
oversized blob cannot sneak in.

---

## Release tooling

These scripts maintain this repository itself.

```powershell
# 1. build the folder layout from a loose working directory (idempotent)
powershell -ExecutionPolicy Bypass -File scripts\repo\00_organize_repo.ps1

# 2. audit what is about to be committed, then init / stage / commit
powershell -ExecutionPolicy Bypass -File scripts\repo\20_check_repo_size.ps1
powershell -ExecutionPolicy Bypass -File scripts\repo\10_git_init_commit.ps1 `
    -Remote git@github.com:<you>/<repo>.git -Push
```

Bash equivalents live next to them (`00_organize_repo.sh`,
`10_git_init_commit.sh`). `00_organize_repo.sh` also normalises shell and patch
files to LF — Windows editors default to CRLF, which Bash rejects outright
(`do\r`) and which `git apply` mis-parses.

---

## Contributing

Patches are the interesting contribution. Please read
[`CONTRIBUTING.md`](CONTRIBUTING.md) before sending one; the short version:

* Target **one** upstream tag, and say which.
* Keep hunk sizes small and guard every ergonomics change with
  `FLAG_SET_ERGO_IF_DEFAULT` so `-XX:` overrides still work.
* Re-run `scripts/verify_patches.ps1` and paste its output.
* Re-run the benchmark and update `benchmarks/` — including the numbers that
  got *worse*, not only the ones that improved.

---

## License

GPL-2.0 with the Classpath Exception — the same license as OpenJDK itself.
The patches are derivative works of OpenJDK source, so the Classpath Exception
is what allows linking against the JDK APIs without dragging the whole runtime
into the GPL.

See [`LICENSE`](LICENSE).

## Acknowledgements

* **OpenJDK** — the entire base. `jdk21u`, licensed GPL-2.0+CPE.
* **Azul Zulu** — the BootJDK used to bootstrap the build.
* This project is **not** affiliated with, endorsed by, or derived from
  **Azul Systems / Azul Prime (Zing)**. Prime is referenced only as the
  commercial product whose latency class J47 aims to make reachable from
  open sources.

## 日本語補足

* 本リポジトリは **Windows 専用のビルドキット**です。Linux/macOS でのビルドには
  OpenJDK 上流の標準手順をご利用ください。
* 計測値は **1 台の Windows マシン（16 vCPU）**での実測です。ハードウェア・
  電源プラン・Defender 設定により値は変動します。
* 詳細な計測条件・解析手順・罠の解説は
  [`benchmarks/README.md`](benchmarks/README.md) と
  [`benchmarks/RESULTS.md`](benchmarks/RESULTS.md) に記載しています。

