#!/usr/bin/env bash
# =============================================================================
#  10_git_init_commit.sh - initialise the repository, stage, audit, commit, push
#  (Bash equivalent of 10_git_init_commit.ps1)
#
#  Usage:
#     ./10_git_init_commit.sh
#     ./10_git_init_commit.sh -r git@github.com:you/J47-jdk.git
#     ./10_git_init_commit.sh -r git@github.com:you/J47-jdk.git -p
#
#  Flags:
#     -r REMOTE   remote URL (sets/updates origin)
#     -p          push to origin after committing
#     -b BRANCH   branch name (default: main)
#     -m MSG      commit message (default: initial-release message)
#     -u NAME     git user.name
#     -e EMAIL    git user.email
#
#  Why an ALLOWLIST instead of `git add -A`:
#  `git add -A` trusts .gitignore completely. This script names the paths it
#  is willing to publish, so jdk21u/, build/, out/ and the ~190 MB installers
#  cannot be staged even if an ignore rule is wrong.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$ROOT"

REMOTE=""; PUSH=0; BRANCH="main"; MSG=""; GNAME=""; GEMAIL=""
while getopts "r:pb:m:u:e:" opt; do
  case "$opt" in
    r) REMOTE="$OPTARG" ;;
    p) PUSH=1 ;;
    b) BRANCH="$OPTARG" ;;
    m) MSG="$OPTARG" ;;
    u) GNAME="$OPTARG" ;;
    e) GEMAIL="$OPTARG" ;;
    *) echo "usage: $0 [-r remote] [-p] [-b branch] [-m msg] [-u name] [-e email]" >&2; exit 2 ;;
  esac
done

command -v git >/dev/null 2>&1 || { echo "ERROR: git not found on PATH" >&2; exit 1; }
git --version

# ----------------------------------------------------------------- 0. identity
[ -n "$GNAME" ]  && git config user.name  "$GNAME"
[ -n "$GEMAIL" ] && git config user.email "$GEMAIL"
if [ -z "$(git config user.name || true)" ] || [ -z "$(git config user.email || true)" ]; then
  echo
  echo "WARNING: git identity is not fully configured. Set it with:" >&2
  echo '  git config user.name  "Your Name"' >&2
  echo '  git config user.email "you@example.com"' >&2
fi

# -------------------------------------------------------------------- 1. init
echo
if [ "$(git rev-parse --git-dir 2>/dev/null || true)" = ".git" ]; then
  echo "=== [1/5] existing repository detected ==="
  echo "  current branch: $(git rev-parse --abbrev-ref HEAD)  (target: $BRANCH)"
else
  echo "=== [1/5] git init (-b $BRANCH) ==="
  git init -b "$BRANCH"
fi

# ------------------------------------------------------------------ 2. stage
ALLOW=(
  .gitignore .gitattributes .editorconfig
  README.md LICENSE CHANGELOG.md
  CONTRIBUTING.md SECURITY.md CODE_OF_CONDUCT.md
  .github
  patches scripts benchmarks docs bench installer
)
echo
echo "=== [2/5] staging the allowlist ==="
for p in "${ALLOW[@]}"; do
  if [ -e "$p" ]; then
    git add -- "$p"
    echo "  staged $p"
  else
    echo "  SKIP   $p (not present)" >&2
  fi
done

# ------------------------------------------------------------------ 3. audit
echo
echo "=== [3/5] size / content audit ==="
AUDIT="$HERE/20_check_repo_size.ps1"
if command -v powershell.exe >/dev/null 2>&1; then
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$AUDIT")" || {
    echo "ABORTED: refusing to commit oversized or forbidden content." >&2
    exit 1
  }
else
  # Pure-git fallback when PowerShell is unavailable.
  FAIL=0
  while IFS= read -r f; do
    [ -e "$f" ] || continue
    case "$f" in
      jdk2?u/*|openjdk*/*|build/*|out/*|images/*|tools/*|dist/*)
        echo "  [FAIL] forbidden path: $f" >&2; FAIL=1; continue ;;
    esac
    case "$f" in
      *.jfr|*.jmod|*.msi|*.zip|*.7z|*.dll|*.lib|*.exe|*.pdb|*.obj|*.class)
        echo "  [FAIL] forbidden type: $f" >&2; FAIL=1; continue ;;
    esac
    sz=$(wc -c < "$f")
    printf '  [ ok ] %10.3f MB  %s\n' "$(echo "scale=6; $sz/1048576" | bc)" "$f"
  done < <(git diff --cached --name-only --diff-filter=ACMR)
  [ "$FAIL" -eq 0 ] || { echo "AUDIT FAILED" >&2; exit 1; }
  echo "AUDIT PASSED (git fallback)"
fi

# ----------------------------------------------------------------- 4. commit
if [ -z "$MSG" ]; then
  MSG=$(cat <<'EOF'
J47: ultra-low latency custom OpenJDK for Windows (Generational ZGC + MSVC LTO)

Build kit for a Windows-tuned OpenJDK 21u:
  - patches/    Generational ZGC by default, high-resolution Windows timer,
                ZGC-gated JIT ergonomics, MSVC 19.44 compatibility
  - scripts/    Cygwin + MSVC build pipeline, verifier, GC log analyzer
  - benchmarks/ aggregated results re-derived from the raw GC log

Measured on a 16-vCPU Windows host: P99 pause 0.027 ms, max pause 0.741 ms,
and 0 of 2,375 pauses above 1 ms. See benchmarks/RESULTS.md for methodology.

Heavy artefacts (OpenJDK checkout, build output, installers, logs) are excluded
by .gitignore and staged from an explicit allowlist; publish binaries through
GitHub Releases.
EOF
)
fi

echo
echo "=== [4/5] commit ==="
if git diff --cached --quiet; then
  echo "  nothing staged - working tree already clean."
else
  git -c core.autocrlf=false commit -m "$MSG"
  echo
  git --no-pager log --oneline -1
fi

# ------------------------------------------------------- 5. remote and push
echo
echo "=== [5/5] remote / push ==="
if [ -n "$REMOTE" ]; then
  if git remote | grep -qx origin; then
    echo "  updating origin -> $REMOTE"; git remote set-url origin "$REMOTE"
  else
    echo "  adding origin -> $REMOTE";    git remote add origin "$REMOTE"
  fi
  git remote -v
  if [ "$PUSH" -eq 1 ]; then
    echo
    echo "  pushing to $BRANCH ..."
    if ! git push -u origin "$BRANCH"; then
      echo "  push failed. Reconcile with: git pull --rebase origin $BRANCH" >&2
      echo "  or create the GitHub repo empty (no README/.gitignore) first." >&2
      exit 1
    fi
    echo "  PUSH OK"
  else
    echo "  push not requested (-p not given)"
  fi
else
  echo "  no remote given. After creating the repo on GitHub, run:"
  echo "    $0 -r git@github.com:<you>/<repo>.git -p"
fi

echo
echo "DONE. Repository is ready."
echo
git --no-pager status --short --branch
echo
