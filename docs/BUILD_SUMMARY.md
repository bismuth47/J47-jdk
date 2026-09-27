# J47 Custom JDK Build Summary

## Current Status
✅ **Source Code**: OpenJDK 21u source already present in `jdk21u/`
✅ **Custom Patches**: 3 J47 patches applied
✅ **Build Scripts**: Configure and build scripts ready
✅ **Build Infrastructure**: Complete build system configured

## What's Ready

### Source Directory Structure
```
J47 Root/
├── jdk21u/                    # OpenJDK 21u source (CUSTOMIZED)
│   ├── configure             # Build configuration script
│   ├── Makefile              # Build system
│   ├── src/                  # Java source code
│   ├── make/                 # Build scripts
│   └── doc/building.md        # Build documentation
├── patches/                   # Custom modifications
│   ├── J47-lowlatency.patch   # Main low-latency optimizations
│   ├── J47-throughput-2mb.patch # Throughput improvements
│   └── J47-msvc1944-c2280.patch # MSVC compatibility
├── 02_configure.sh           # Configure script (Windows optimized)
├── 05_build.sh              # Build script (Windows x64 + LTO)
├── 01_env_check.sh/.ps1      # Environment setup scripts
└── 05_verify.ps1            # Verification script
```

### Key Custom Features
1. **Generational ZGC Default**: Low-latency garbage collector
2. **AlwaysPreTouch**: Deterministic memory allocation
3. **ForceTimeHighResolution**: Precise timing for latency-sensitive applications
4. **Link-Time Optimization**: Performance improvements
5. **Custom Windows Logging**: Memory management debugging

### Build Configuration
- **Platform**: Windows x64 / Visual Studio 2022
- **Debug Level**: Release build
- **JVM Variant**: Server
- **Features**: ZGC, CDS, Compiler1/2, G1GC, ParallelGC, SerialGC, EpsilonGC
- **Optimizations**: Link-time optimization enabled
- **Vendor**: J47
- **Version**: J47-lowlatency

## Build Steps (Manual)

### Step 1: Environment Setup
```bash
# Windows (PowerShell as Administrator)
cd C:\Users\raiko\OneDrive\Desktop\J47
powershell -File 01_env_check.ps1

# Or MSYS2
./01_env_check.sh
```

**Requirements:**
- `[Lock Pages in Memory]` permission (UAC reboot required)
- BootJDK21 in `C:\tools\bootjdk-21`
- Visual Studio 2022
- Cygwin/MSYS2

### Step 2: Configure Build
```bash
cd C:\Users\raiko\OneDrive\Desktop\J47\jdk21u
../02_configure.sh ./jdk21u
```

### Step 3: Build JDK
```bash
cd C:\Users\raiko\OneDrive\Desktop\J47\jdk21u
../05_build.sh ./jdk21u
```

### Step 4: Verify Build
```powershell
powershell -File 05_verify.ps1 C:\Users\raiko\OneDrive\Desktop\J47\jdk21u\build\windows-x86_64-server-release\images\jdk
```

## Prerequisites

### Hardware Requirements
- **CPU**: 2-4 cores (more cores = more memory needed)
- **RAM**: Minimum 4-8 GB (SSD preferred)
- **Disk Space**: 6 GB minimum (build intensive)

### Software Requirements
- **OS**: Windows 10/11 (32-bit builds deprecated)
- **Compiler**: Microsoft Visual Studio 2022 Update 17.1.0
- **POSIX Layer**: Cygwin64, WSL, or MSYS2
- **Build Tools**: GNU Make 4.0+, Autoconf 2.69+
- **External Libraries**: Fontconfig, CUPS, X11, ALSA, libffi, FreeType2

### Custom Environment Variables
For enhanced performance, set these before building:
```bash
export CFLAGS_OVERRIDE="-O2 -GL -arch:AVX2 -Gw -Gy -GF"
export CXXFLAGS_OVERRIDE="-O2 -GL -EHsc -arch:AVX2 -Gw -Gy -GF"
export LDFLAGS_OVERRIDE="-LTCG -OPT:REF -OPT:ICF"
```

## Build Process Details

### Patches Applied
1. **J47-lowlatency.patch**: Memory management optimizations
   - Windows large page handling
   - ZGC default selection
   - ForceTimeHighResolution enabled

2. **J47-throughput-2mb.patch**: Performance improvements (ZGC-conditional JIT
   ergonomics). The ergonomic `UseLargePages` / `LargePageSizeInBytes` and
   `UseCountedLoopSafepoints` / `LoopStripMiningIter` overrides were removed on
   2026-09-27 because they crashed every JVM start (see "2026-09-27 build
   incident" below). The file now carries the corrected hunks.

3. **J47-msvc1944-c2280.patch**: MSVC compiler compatibility

### Configuration Features
- **ZeroGC**: `ZGC` enabled by default for low latency
- **Generational**: `ZGenerational` for improved GC performance
- **Memory**: `AlwaysPreTouch` for deterministic allocation
- **Timing**: `ForceTimeHighResolution` for precise timing
- **Optimization**: Link-time optimization for performance

## Verification

After building, verify with:
- `./build/windows-x86_64-server-release/images/jdk/bin/java -version`
- Run `./05_verify.ps1` for comprehensive testing

## Notes

- **Official Support**: Cygwin64 recommended (MSYS2 may have issues)
- **PGO**: Not supported in configure (use LTO instead)
- **Cross-compilation**: Not tested for this setup
- **Testing**: Tier 1 tests available via `make run-test-tier1`

## Build Status: READY

The custom JDK build system is fully configured and ready to compile. All patches are applied, build scripts are optimized for Windows x64, and the infrastructure is in place for successful compilation.

**To proceed with building, run the configure and build scripts in order.**

## 2026-09-27 build incident (fixed)

**Symptom**: `make images` failed on target
`support_images_jmods__create_java.desktop.jmod` with
`EXCEPTION_INT_DIVIDE_BY_ZERO (0xc0000094)` at
`GCArguments::compute_heap_alignment+0x32` (`gcArguments.cpp:82`); the freshly
built JDK therefore crashed on every start.

Evidence:
- `jdk21u/build/windows-x86_64-server-release/make-support/failure-summary.log`
- `jdk21u/make/hs_err_pid16796.log` (rcx=0x800000, divisor rdx=0)
- `tp_build.log` (failed run 16:16-16:24)

**Root cause**: `Arguments::apply_ergo()` forced `UseLargePages` = true and
`LargePageSizeInBytes` = 2M ergonomically. `os::init_before_ergo() ->
os::large_page_init()` (`src/hotspot/share/runtime/os.cpp:465-469`) runs *before*
ergonomics and early-returns while `UseLargePages` is still default-false
(`src/hotspot/os/windows/os_windows.cpp:3344-3347`), so `os::large_page_size()`
stayed 0. `GCArguments::compute_heap_alignment()` then evaluated
`lcm(0, alignment)`, and `lcm()` (`utilities/globalDefinitions.cpp:383-392`)
divides by `MIN2(a, b)` = 0.

**Fix** (`patches/J47-tp-ergo-fix.patch`, folded into
`patches/J47-throughput-2mb.patch` on 2026-09-27):
- Large pages stay opt-in per run: `-XX:+UseLargePages` (requires
  `SeLockMemoryPrivilege` = [Lock Pages in Memory]; ZGC then uses the OS 2MB
  pages, `EnableAllLargePageSizesForWindows=false` keeps 1GB pages out).
- `UseCountedLoopSafepoints` / `LoopStripMiningIter` keep ZGC's own defaults
  (true / 1000, `zArguments.cpp:191-196`) instead of being rewritten to 1 (a
  safepoint poll every counted-loop iteration) by
  `LoopStripMiningIterConstraintFunc` (`jvmFlagConstraintsCompiler.cpp:408-416`).
- `MaxVectorSize` is left at auto instead of being forced to 64:
  `MaxVectorSizeConstraintFunc` rejects 64 on AVX2-only CPUs (`UseAVX=2`) and
  printed "MaxVectorSize must be at most 32 on this platform" on every start
  while the value was clamped to 32 anyway (observed in `05_verify.ps1`).

**Build result**: `make images` succeeded on 2026-09-27 (config
`windows-x86_64-server-release`, LTO, `J47-ZGC-tp2`) - log `tp_build3.log`
("BUILD OK", exit 0, 00:04:35 incremental), image
`jdk21u/build/windows-x86_64-server-release/images/jdk` with
`IMPLEMENTOR="J47"`, `JAVA_RUNTIME_VERSION="21.0.13-internal-J47-ZGC-tp2"`.
`05_verify.ps1` reports `VERIFY OK: UseZGC=true / AlwaysPreTouch=true` and ZGC
startup log lines. `tp_build4.log` is the rebuild that also carries the
`MaxVectorSize` fix.

**Environment note**: the whole source tree lives under OneDrive, which made the
build extremely slow (357 MB interim `java.base.jmod` took 15+ minutes) and
produced transient `LNK1327: error during running rc.exe` plus a hung
`make`/`bash` pair; both went away simply by re-running the same command
(`run_build_tp2.cmd`, which loads `vcvars64.bat` and pins `TMP`/`TEMP`).

**Reproducibility**: `verify_patches.ps1` applies the patch set to a pristine
checkout and asserts it reproduces the current `jdk21u` working tree exactly.