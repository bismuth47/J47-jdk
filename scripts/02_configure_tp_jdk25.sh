#!/bin/bash
# J47 02_configure_tp_jdk25: throughput-recovery configure for OpenJDK 25 (jdk25u, Windows x64)
#
# Usage:
#   Start from a shell where the VS 2022 x64 environment is already loaded
#   (vcvars64.bat), then run this from Cygwin bash:
#       ./02_configure_tp_jdk25.sh [openjdk-source-dir]
#
# Prerequisite - patch already applied:
#       cd jdk25u && git apply ../patches/J47-throughput-2mb-jdk25.patch
#
# Boot JDK: JDK 25 configure requires a boot JDK of 24 or newer.
#   Default: /cygdrive/c/tools/bootjdk-24  (override with J47_BOOT_JDK)
#
# Build root:
#   Set TP_BUILD_ROOT_CYG to run configure/make outside the source tree
#   (recommended: keeps heavy build I/O out of OneDrive).
#       export TP_BUILD_ROOT_CYG=/cygdrive/c/j47build25
set -eux

SRC_DIR="${1:-./jdk25u}"
BOOT_JDK="${J47_BOOT_JDK:-/cygdrive/c/tools/bootjdk-24}"

cd "$SRC_DIR"
SRC_ROOT="$(pwd)"

# With --with-conf-name, configure writes to <TP_BUILD_ROOT_CYG>/<CONF>
# instead of <SRC>/build/<CONF>. Run make from that same directory.
CONF_ARGS=()
if [ -n "${TP_BUILD_ROOT_CYG:-}" ]; then
  CONF_ARGS=(--with-conf-name=windows-x86_64-server-release)
  mkdir -p "$TP_BUILD_ROOT_CYG"
  cd "$TP_BUILD_ROOT_CYG"
fi

# Windows SDK discovery - see the long comment in 02_configure_tp.sh for why the
# `um`/`shared` include paths and the um/x64 lib path must be re-added manually
# (otherwise configure dies with LNK1104 cannot open file kernel32.lib).
WdkAuto=""
for root in "${J47_WDK_ROOT:-}" "/cygdrive/c/progra~2/wi3cf2~1" "/cygdrive/c/Program Files (x86)/Windows Kits/10"; do
  [ -n "$root" ] || continue
  for ver in ${J47_SDK_VER:+"$J47_SDK_VER"} $(ls "$root/include" 2>/dev/null | sort -r); do
    if [ -d "$root/include/$ver/um" ] && [ -d "$root/lib/$ver/um/x64" ]; then
      WdkAuto="$root $ver"; break 2
    fi
  done
done
if [ -z "$WdkAuto" ]; then
  echo "ERROR: Windows 10/11 SDK not found. Set J47_SDK_VER / J47_WDK_ROOT." >&2
  exit 1
fi
# Split "<root> <version>" WITHOUT word-splitting: the Windows Kits root
# contains spaces ("Program Files (x86)"), and `set -- $var` would tear it
# apart. Version numbers never contain spaces, so strip the last token instead.
WDK_ROOT="${WdkAuto% *}"
SDK_VER="${WdkAuto##* }"
SDK_UM="$WDK_ROOT/include/$SDK_VER/um"
SDK_SHARED="$WDK_ROOT/include/$SDK_VER/shared"
SDK_LIB="$WDK_ROOT/lib/$SDK_VER/um/x64"
echo "J47: using Windows SDK $SDK_VER at $WDK_ROOT"

# LTO = --enable-jvm-feature-link-time-opt (MSVC: -GL + -LTCG:INCREMENTAL)
# PGO (/GENPROFILE) is not supported by configure, so it is not included here.
# No /arch:AVX2: it would break startup on pre-AVX2 CPUs and lowers clock
# frequency on AVX-512 parts. The JIT defaults to UseAVX=3 and detects at runtime.
bash "$SRC_ROOT/configure" \
  "${CONF_ARGS[@]}" \
  --with-boot-jdk="$BOOT_JDK" \
  --with-debug-level=release \
  --with-jvm-variants=server \
  --with-jvm-features=zgc,cds,compiler1,compiler2,g1gc,parallelgc,serialgc,epsilongc \
  --enable-jvm-feature-link-time-opt \
  --disable-warnings-as-errors \
  --with-vendor-name=J47 \
  --with-vendor-version-string=J47-tp-jdk25 \
  --with-version-opt=J47-ZGC-tp-jdk25 \
  --with-native-debug-symbols=external \
  --with-extra-cflags="-I$SDK_UM -I$SDK_SHARED -Gw -Gy -GF -Oy-" \
  --with-extra-cxxflags="-I$SDK_UM -I$SDK_SHARED -EHsc -Gw -Gy -GF -Oy-" \
  --with-extra-ldflags="-libpath:$SDK_LIB -OPT:REF -OPT:ICF"

echo "=== configure done ==="
if [ -n "${TP_BUILD_ROOT_CYG:-}" ]; then
  echo "next: cd \$TP_BUILD_ROOT_CYG && make images JOBS=\$(nproc)"
else
  echo "next: cd $SRC_ROOT && make images JOBS=\$(nproc)"
fi
