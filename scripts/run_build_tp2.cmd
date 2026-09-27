@echo off
REM ============================================================================
REM  J47 - build wrapper (IN-SOURCE build: <repo>\jdk21u\build\<conf>)
REM
REM  Loads the VS 2022 x64 environment, puts the Windows SDK on PATH, pins TEMP
REM  off OneDrive, then hands over to Cygwin bash. The JDK `configure` script
REM  detects MSVC through VS170COMNTOOLS, which vcvars64.bat exports - so bash
REM  MUST be started from this shell, not from a plain prompt.
REM
REM  Override any of these before running if your layout differs:
REM      set J47_ROOT=C:\src\J47
REM      set VCVARS=C:\Program Files\...\vcvars64.bat
REM      set CYGWIN_BASH=C:\cygwin64\bin\bash.exe
REM ============================================================================
setlocal
if not defined J47_ROOT    set "J47_ROOT=%~dp0.."
if not defined CYGWIN_BASH set "CYGWIN_BASH=C:\cygwin64\bin\bash.exe"

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

REM The JDK build spawns rc.exe by bare name; vcvars does not put the SDK bin
REM directory on PATH in every VS layout.
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
echo TEMP=%TEMP%
echo === build ===
pushd "%J47_ROOT%"
"%CYGWIN_BASH%" --login -c "cd \"$(cygpath -u "%J47_ROOT%")\" && ./scripts/05_build.sh ./jdk21u"
set "BUILD_EXIT=%ERRORLEVEL%"
popd
echo BUILD_EXIT=%BUILD_EXIT%
exit /b %BUILD_EXIT%
