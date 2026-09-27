#!/bin/bash
# J47 05: run the build (works under both Cygwin and MSYS2)
# usage: ./scripts/05_build.sh [openjdk-source-dir]
# Build directory: TP_BUILD_ROOT_CYG (out-of-source). When unset, the build is
# done in <src>/build/<conf>. When set, 02_configure*.sh drops a SPEC-bearing
# Makefile directly into that root, so `make` must be run there and CONF= must
# NOT be passed (make/Init.gmk: "Cannot use CONF=... and SPEC=... at once").
set -eux
SRC_DIR="${1:-./jdk21u}"
CONF=windows-x86_64-server-release
NCPUS=$(nproc 2>/dev/null || echo 8)

if [ -n "${TP_BUILD_ROOT_CYG:-}" ]; then
  cd "$TP_BUILD_ROOT_CYG"
  make images JOBS="$NCPUS" LOG=info
  ls -lh "images/jdk/bin/java.exe"
else
  cd "$SRC_DIR"
  make images JOBS="$NCPUS" LOG=info CONF="$CONF"
  ls -lh "build/$CONF/images/jdk/bin/java.exe"
fi
echo "BUILD OK"
