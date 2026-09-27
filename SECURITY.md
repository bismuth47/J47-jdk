# Security Policy

## Supported versions

J47 is a **build kit**, not a vendor-supported product. There is no Long-Term
Support stream and no patch release cadence. What you get is source you can
audit and build yourself — which is the point.

| Version | Status |
|---|---|
| `jdk21u` (current `main`) | actively developed |
| `jdk25u` | experimental backport; the `ZGenerational` hunk does not apply |

## Reporting a vulnerability

**Do not open a public issue for a security problem.**

Use GitHub's private vulnerability reporting:
**Security → Report a vulnerability** on this repository.

Please include:

* the OpenJDK tag you built from,
* the patch set you applied,
* a minimal reproducer,
* what an attacker gains.

You can expect an acknowledgement within a week. If a report is a genuine
security issue in **OpenJDK itself** rather than in J47's patches, please report
it to the OpenJDK security team as well — we will help you route it.

## Threat model

Realistically, this project is a set of diffs against OpenJDK plus build
scripts. The interesting surface is:

| Surface | Note |
|---|---|
| **`patches/*.patch`** | Changes JVM default behaviour. These are the only files that run in your JVM. |
| **`scripts/*.sh`, `*.ps1`, `*.cmd`** | Run once, by you, on your machine, usually with developer privileges. Read before running. |
| **`installer/J47.nsi`** | Packages a built image. |

### Things worth knowing

* **J47 changes garbage-collection defaults.** ZGC, `AlwaysPreTouch` and
  `ForceTimeHighResolution` are on by default. `AlwaysPreTouch` means the whole
  heap is committed and faulted in at startup — a large `-Xmx` will start more
  slowly and hold more resident memory. This is a deliberate trade for latency,
  and it is reversible with `-XX:-AlwaysPreTouch`.
* **`ForceTimeHighResolution` raises system timer resolution** for the JVM's
  lifetime. This is a documented, upstream-supported flag; the cost is slightly
  higher power draw. Reversible with `-XX:-ForceTimeHighResolution`.
* **The build scripts execute with your privileges.** `01_env_check.ps1`,
  `install.ps1` and `run_build_*.cmd` touch environment variables, `PATH`,
  machine-level `JAVA_HOME`, and (for the MSI route) run `winget` and DISM.
  Read them first; they are short.
* **Large pages require `SeLockMemoryPrivilege`.** Granting *Lock Pages in
  Memory* is a privilege increase for the account, not for the JVM alone.
* **No telemetry.** The scripts do not phone home. `06_bench.ps1` writes only
  into `out/`.

## Verifying what you are running

Because the whole point is auditability, it should be easy to check:

```powershell
# what changed relative to upstream?
cd jdk21u; git --no-pager diff --stat

# which flags does the binary actually default to?
& "C:\j47build\images\jdk\bin\java.exe" -XX:+PrintFlagsFinal -version 2>&1 |
  Select-String "UseZGC|ZGenerational|AlwaysPreTouch|ForceTimeHighResolution"

# does the patch set reproduce the tree exactly?
powershell -ExecutionPolicy Bypass -File scripts\verify_patches.ps1
```
