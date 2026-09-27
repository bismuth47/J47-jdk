@echo off
REM ============================================================================
REM  J47 - build wrapper (OUT-OF-SOURCE build via TP_BUILD_ROOT_CYG)
REM
REM  Same toolchain setup as run_build_tp2.cmd, but the build tree lives outside
REM  the source checkout. Keep it OFF OneDrive: writing the 357 MB interim
REM  java.base.jmod through a sync client took >15 minutes and produced
REM  sporadic LNK1327 (rc.exe) failures plus hung make/bash pairs.
REM
REM  NOTE: a directory junction is NOT a valid substitute - spec.gmk embeds
REM  absolute paths, so the tree must be moved and re-configured, not linked.
REM
REM  Override before running if your layout differs:
REM      set J47_ROOT=C:\src\J47
REM      set TP_BUILD_ROOT_CYG=/cygdrive/c/j47build
REM      set VCVARS=...   set CYGWIN_BASH=...
REM ============================================================================
setlocal
if not defined J47_ROOT          set "J47_ROOT=%~dp0.."
if not defined CYGWIN_BASH       set "CYGWIN_BASH=C:\cygwin64\bin\bash.exe"
if not defined TP_BUILD_ROOT_CYG set "TP_BUILD_ROOT_CYG=/cygdrive/c/j47build"

if not defined VCVARS (
  for %%E in (
    "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
    "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
    "C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat"
    "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat"
  ) do if exist %%E if not defined VCVARS set "VCVARS=%%~E"
)
if not defined VCVARS (echo ERROR: vcvars64.bat not found. Set VCVARS=... & exit /b 1)
if not exist "%CYGWIN_BASH%" (echo ERROR: bash not found: %CYGWIN_BASH% & exit /b 1)

call "%VCVARS%" >nul 2>&1

for /f "delims=" %%D in ('dir /b /ad "%ProgramFiles(x86)%\Windows Kits\10\bin" 2^>nul') do (
  if not defined WDK_BIN set "WDK_BIN=%ProgramFiles(x86)%\Windows Kits\10\bin\%%D\x64"
)
if defined WDK_BIN if exist "%WDK_BIN%" set "PATH=%WDK_BIN%;%PATH%"

if not defined TMP  set "TMP=%LOCALAPPDATA%\Temp"
if not defined TEMP set "TEMP=%LOCALAPPDATA%\Temp"

echo === toolchain sanity ===
where rc.exe
where link.exe
echo J47_ROOT=%J47_ROOT%
echo TP_BUILD_ROOT_CYG=%TP_BUILD_ROOT_CYG%
echo === build (out-of-source) ===
pushd "%J47_ROOT%"
"%CYGWIN_BASH%" --login -c "export TP_BUILD_ROOT_CYG='%TP_BUILD_ROOT_CYG%'; cd \"$(cygpath -u "%J47_ROOT%")\" && ./scripts/05_build.sh ./jdk21u"
set "BUILD_EXIT=%ERRORLEVEL%"
popd
echo BUILD_EXIT=%BUILD_EXIT%
exit /b %BUILD_EXIT%
