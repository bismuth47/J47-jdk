#!/bin/bash
# J47 02_configure_tp: throughput-recovery configure (2MB large pages only, timer untouched)
# 使い方: ./02_configure_tp.sh [openjdkソースdir]
# 前提: パッチ適用済み (patches/J47-throughput-2mb.patch を jdk21u に git apply)
#   cd jdk21u && git apply --check ../patches/J47-throughput-2mb.patch && git apply ../patches/J47-throughput-2mb.patch
set -eux
SRC_DIR="${1:-./jdk21u}"
BOOT_JDK="${J47_BOOT_JDK:-/cygdrive/c/tools/bootjdk-21}"

cd "$SRC_DIR"
SRC_ROOT="$(pwd)"

# J47-TP: configure を TP_BUILD_ROOT_CYG (例: /cygdrive/c/j47build) で実行する。
# ソース内 build/ を使う場合は jdk21u/configure を直接叩く (従来どおり)。
# LTO = --enable-jvm-feature-link-time-opt (MSVC: -GL + -LTCG:INCREMENTAL)。
# PGO (/GENPROFILE) は configure 非対応のため含めない。必要時は別途手動2段階ビルド。
# /arch:AVX2/AVX512 は付けない (AVX2未満CPUで起動不可 + AVX-512周波数低下)。
# JITは UseAVX=3 既定で実行時CPU検出によりホットループのみAVX化する。
CONF_ARGS=()
if [ -n "${TP_BUILD_ROOT_CYG:-}" ]; then
  CONF_ARGS=(--with-conf-name=windows-x86_64-server-release)
  mkdir -p "$TP_BUILD_ROOT_CYG"
  cd "$TP_BUILD_ROOT_CYG"
fi

# ---------------------------------------------------------------------------
# Windows SDK paths.
#
# Known issue (measured on this machine): extracting the vcvars environment
# loses the SDK `um` and `shared` include directories, and configure then fails
# with `LNK1104 cannot open file kernel32.lib`. The workaround is to re-add them
# through --with-extra-cflags/cxxflags/ldflags.
#
# The location is auto-detected from the Windows Kits tree. Override with
#   J47_SDK_VER=10.0.22621.0   J47_WDK_ROOT=/cygdrive/c/progra~2/wi3cf2~1
# if the layout differs on your machine. If the directory cannot be found the
# script fails loudly rather than silently producing a broken build.
# ---------------------------------------------------------------------------
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
  echo "ERROR: Windows 10/11 SDK not found under the Windows Kits tree." >&2
  echo "       Set J47_SDK_VER and J47_WDK_ROOT explicitly and re-run." >&2
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

bash "$SRC_ROOT/configure" \
  "${CONF_ARGS[@]}" \
  --with-boot-jdk="$BOOT_JDK" \
  --with-debug-level=release \
  --with-jvm-variants=server \
  --with-jvm-features=zgc,cds,compiler1,compiler2,g1gc,parallelgc,serialgc,epsilongc \
  --enable-jvm-feature-link-time-opt \
  --disable-warnings-as-errors \
  --with-vendor-name=J47 \
  --with-vendor-version-string=J47-lowlatency-tp \
  --with-version-opt=J47-ZGC-tp2 \
  --with-native-debug-symbols=external \
  --with-extra-cflags="-I$SDK_UM -I$SDK_SHARED -Gw -Gy -GF -Oy-" \
  --with-extra-cxxflags="-I$SDK_UM -I$SDK_SHARED -EHsc -Gw -Gy -GF -Oy-" \
  --with-extra-ldflags="-libpath:$SDK_LIB -OPT:REF -OPT:ICF"

echo "=== configure done ==="
echo "next: ./scripts/05_build.sh $SRC_DIR"
echo ""
echo "recommended run flags (all J47 defaults are already ON, so -XX:+UseZGC,"
echo "-XX:+ZGenerational, -XX:+AlwaysPreTouch and the high-resolution timer can be omitted):"
echo "  -Xms<heap> -Xmx<heap> -XX:+UseLargePages -XX:CICompilerCount=4 \\"
echo "  -XX:ReservedCodeCacheSize=512M -XX:+SegmentedCodeCache -XX:+UseSuperWord \\"
echo "  -XX:+ZAllocationSpikeTolerance=5"
echo ""
echo "  UseLargePages is opt-in per run and needs SeLockMemoryPrivilege"
echo "  ([Lock Pages in Memory]). Forcing it from ergonomics crashed every JVM"
echo "  start - see docs/BUILD_SUMMARY.md."
