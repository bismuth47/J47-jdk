#!/bin/bash
# J47 02: configure最適化 (Windows x64 / VS2022 / release / LTO)
# 使い方: ./02_configure.sh [openjdkソースdir]
# ビルドディレクトリの移設: TP_BUILD_ROOT を指定すると configure の絶対パスが
# その場所を指す (例: C:\j47build へ逃がして OneDrive 同期の影響を避ける)。
#   TP_BUILD_ROOT_CYG=/cygdrive/c/j47build ./02_configure.sh ./jdk21u
# 未設定なら従来どおりソース内 jdk21u/build に作成される。
set -eux
SRC_DIR="${1:-./jdk21u}"
BOOT_JDK="${J47_BOOT_JDK:-/cygdrive/c/tools/bootjdk-21}"

cd "$SRC_DIR"
SRC_ROOT="$(pwd)"   # configure は絶対パスで起動する (cwd を移すため)

# --with-conf-name を指定すると configure は <SRC>/build/<CONF> ではなく
# <TP_BUILD_ROOT_CYG>/<CONF> を使う (build ディレクトリがソース外になる)。
# TP_BUILD_ROOT_CYG を指定した場合、そのディレクトリで configure を起動する
# (configure は「ソース外の現在ディレクトリ」を出力先に使う = make/autoconf/
#  configure:63, basic.m4:390-404)。make も同じディレクトリで実行する。
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

bash "$SRC_ROOT/configure" \
  "${CONF_ARGS[@]}" \
  --with-boot-jdk="$BOOT_JDK" \
  --with-debug-level=release \
  --enable-headless-only=no \
  --with-jvm-variants=server \
  --with-jvm-features=zgc,cds,compiler1,compiler2,g1gc,parallelgc,serialgc,epsilongc \
  --enable-jvm-feature-link-time-opt \
  --disable-warnings-as-errors \
  --with-vendor-name=J47 \
  --with-vendor-version-string=J47-lowlatency \
  --with-version-opt=J47-ZGC-default \
  --with-native-debug-symbols=external \
  --with-extra-cflags="-I$SDK_UM -I$SDK_SHARED" \
  --with-extra-cxxflags="-I$SDK_UM -I$SDK_SHARED" \
  --with-extra-ldflags="-libpath:$SDK_LIB"

echo "=== configure done. 追加最適化を使う場合はビルド前に export ==="
echo 'export CFLAGS_OVERRIDE="-O2 -GL -arch:AVX2 -Gw -Gy -GF"'
echo 'export CXXFLAGS_OVERRIDE="-O2 -GL -EHsc -arch:AVX2 -Gw -Gy -GF"'
echo 'export LDFLAGS_OVERRIDE="-LTCG -OPT:REF -OPT:ICF"'
echo "PGO(/GENPROFILE)はconfigure非対応のため通常はLTOのみ推奨。必要時はREADME参照。"
