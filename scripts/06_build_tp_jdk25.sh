#!/bin/bash
# J47 06_build_tp_jdk25: make images for the jdk25u TP build.
#
# Prerequisite: 02_configure_tp_jdk25.sh has already run successfully.
# Run from a Cygwin bash started inside a shell where vcvars64.bat was loaded.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
SRC_DIR="${1:-$REPO_ROOT/jdk25u}"
NCPUS=$(nproc 2>/dev/null || echo 8)

if [ -n "${TP_BUILD_ROOT_CYG:-}" ]; then
  # configure created the SPEC-bearing Makefile directly under this root,
  # so CONF= must not be passed (make/Init.gmk forbids CONF= together with SPEC=).
  cd "$TP_BUILD_ROOT_CYG"
  make images JOBS="$NCPUS" LOG=info
  JAVA_EXE="images/jdk/bin/java.exe"
else
  cd "$SRC_DIR"
  make images JOBS="$NCPUS" LOG=info CONF=windows-x86_64-server-release
  JAVA_EXE="build/windows-x86_64-server-release/images/jdk/bin/java.exe"
fi

ls -lh "$JAVA_EXE"
echo "BUILD OK: $JAVA_EXE"
