# Contributing to J47

Thanks for considering a contribution. J47 is small on purpose: a handful of
patches, a build pipeline, and a benchmark. Contributions that keep it that way
are the most valuable.

## What is useful

| Kind | Example |
|---|---|
| **A patch** | A new ergonomic, a Windows-specific fix, a backport to another JDK |
| **A build fix** | "configure fails on my SDK version" |
| **A benchmark** | Results from different hardware, or a JMH LTO comparison |
| **A doc fix** | A pitfall we did not document |

Please open an issue first for anything that changes JVM behaviour, so we can
agree on the direction before you write the code.

## Rules for patches

These exist because each one was learned the hard way.

**1. Target exactly one upstream tag.** State it in the commit message, e.g.
`against jdk-21.0.13+7`. A patch that only applies to `master` at one moment is
not reviewable.

**2. Keep hunks small.** One behavioural change per hunk. If a reviewer cannot
read a hunk and immediately know what it does, it is too big.

**3. Guard every ergonomics change.**

```cpp
FLAG_SET_ERGO_IF_DEFAULT(SomeFlag, value);   // yes
SomeFlag = value;                            // no
```

Without the `_IF_DEFAULT` form you take the user's ability to override the flag
with `-XX:`, which is a functional regression even when the default is good.

**4. Never force `UseLargePages` from ergonomics.** This crashed every JVM start
with `EXCEPTION_INT_DIVIDE_BY_ZERO`. `os::large_page_init()` runs *before*
ergonomics, so `os::large_page_size()` is still `0` and the heap-alignment
`lcm()` divides by zero. Large pages stay opt-in per run.

**5. If you change a default, prove it did not regress something.** P99 pause can
improve while throughput or code-cache behaviour degrades. Show both.

**6. Mind JDK version differences.** `ZGenerational` is gone in JDK 24+. If your
change is version-specific, say which versions it targets.

## Before you open a pull request

```bash
# 1. does the patch set still reproduce the tree exactly?
powershell -ExecutionPolicy Bypass -File scripts/verify_patches.ps1

# 2. does the build still start, with the J47 defaults applied?
scripts/05_verify.ps1

# 3. did the numbers move? re-run and update benchmarks/
scripts/06_bench.ps1 -Jdk "C:\j47build\images\jdk" -Heap 1G -DurationSec 120
python scripts/07_gc_log_analyze.py --log out/bench-*/gc.log
```

Paste the command output in the pull request. A patch without evidence that it
does not regress anything will sit unmerged.

## Reporting numbers honestly

If a change makes something worse, say so and show the before/after. The project
already had to retract an "allocation stalls: 0" claim after re-reading the log;
keeping the published numbers traceable to a raw artefact is the entire point of
`benchmarks/RESULTS.md`. Every published figure should be reproducible with
`scripts/07_gc_log_analyze.py` against a log in `out/`.

## Line endings

Run `scripts/repo/00_organize_repo.sh` (or the `.ps1`) if you are unsure — it
normalises `*.sh`, `*.patch` and `*.py` to LF. `.gitattributes` enforces this,
but a CRLF patch will fail to apply on a Linux CI runner and that is a waste of
everyone's time.

## Commit messages

```
area: one-line summary

Why the change is needed, what was measured, and what the risk is.
```

Good examples from this repo's history:
* `hotspot: keep large pages opt-in to avoid lcm(0, n) heap-alignment crash`
* `build: auto-detect the Windows SDK instead of hardcoding the 8.3 path`

## Code of conduct

Participation is governed by [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).
