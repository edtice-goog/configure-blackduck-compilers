@echo off
REM ============================================================================
REM  Manual Coverity capture for blackduck-c-cpp skip_build mode (Windows/MSVC).
REM
REM  Produces an idir at %IDIR% that you can point cov_output_dir at.
REM  Edit the four variables below, then run from a normal cmd prompt.
REM ============================================================================

set "VCVARS=C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat"
set "COV=C:\Coverity\cov-analysis-win64-2026.3.0"
set "PROJECT_DIR=C:\path\to\project"
set "IDIR=C:\capture\idir"
set "COVCFG=C:\capture\cov-config\coverity_config.xml"

REM --- Bring the MSVC compiler onto PATH so cov-build can intercept cl.exe ---
call "%VCVARS%" x64
if errorlevel 1 (echo VCVARS FAILED & exit /b 1)

REM --- Configure the compiler for Coverity (cl/devenv/lib/link/msbuild) ---
"%COV%\bin\cov-configure" --config "%COVCFG%" --msvc
if errorlevel 1 (echo COV-CONFIGURE FAILED & exit /b 2)

REM --- Capture a CLEAN build.  --emit-link-units is REQUIRED for skip_build. ---
REM     Replace the build command after --emit-link-units with your own.
cd /d "%PROJECT_DIR%"
"%COV%\bin\cov-build" --dir "%IDIR%" --config "%COVCFG%" --emit-link-units cmake --build build --clean-first
if errorlevel 1 (echo COV-BUILD FAILED & exit /b 3)

REM --- Verify offline: build-log.txt should exist and sources should be listed ---
if not exist "%IDIR%\build-log.txt" (echo MISSING build-log.txt & exit /b 4)
echo === Captured translation units ===
"%COV%\bin\cov-manage-emit" --dir "%IDIR%" list

echo.
echo Capture complete. Point cov_output_dir at: %IDIR%
exit /b 0
