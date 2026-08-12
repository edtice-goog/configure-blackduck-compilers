---
name: run-blackduck-c-cpp-skip-build
description: Run blackduck-c-cpp in skip_build mode, reusing a Coverity build capture (idir) that you produced yourself with local cov-build, instead of letting the tool drive the build. Use for debugging, for decoupling capture from upload (verify the capture offline before any server contact), or to re-scan without rebuilding. Requires LOCAL Coverity binaries (cov-build, cov-configure, cov-manage-emit, cov-emit-link). This is NOT the default path — prefer run-blackduck-c-cpp unless you specifically need manual capture control.
---

# Run blackduck-c-cpp with skip_build (reuse a manual Coverity capture)

In `skip_build` mode, `blackduck-c-cpp` does **not** run a build. It consumes an existing Coverity intermediate directory (`idir`) that you captured yourself, then runs the emit/link parsing, signature + BDBA matching, and upload. You own the capture; the tool owns the scan.

**This is an advanced/debug path. Do not default to it.** It requires a **full local Coverity install** (`cov-build`, `cov-configure`, `cov-manage-emit`, `cov-emit-link`) — the mini package `blackduck-c-cpp` auto-downloads for the vanilla path is not something most users have broken out on disk for hand-running. For the normal case use [run-blackduck-c-cpp](../run-blackduck-c-cpp/SKILL.md).

## Why you'd want this

- **Decouple capture from upload.** Produce and *verify* the capture entirely offline (correct source files present, expected translation-unit count) before anything talks to the Black Duck server. Great for isolating "is it a build/capture problem or a scan/upload problem?".
- **Re-scan without rebuilding.** Once the `idir` exists, you can re-run scans (e.g., try different `modes`, re-point at a different project-version) without paying for a rebuild each time.
- **Debug a capture** that the tool's own cov-cli/cov-build step handles poorly — you run `cov-build` by hand with exactly the flags you want.

## When to invoke

Trigger when the user explicitly wants manual/offline Coverity capture, mentions `skip_build`, `--emit-link-units`, reusing an `idir`, or "capture separately then scan". Also when debugging why the vanilla path produced an empty BOM and you want to inspect the capture in isolation.

Do **not** invoke as the first suggestion for a routine scan — that's [run-blackduck-c-cpp](../run-blackduck-c-cpp/SKILL.md).

## Prerequisites

1. **A local Coverity install** with the capture binaries, e.g. `C:\Coverity\cov-analysis-win64-2026.3.0\bin` containing `cov-build`, `cov-configure`, `cov-manage-emit`, `cov-emit-link`. Confirm with `cov-build --ident`.
2. Everything from the vanilla skill: Python venv with `blackduck-c-cpp`, `bd_url` + `api_token`, `project_name`/`project_version`.
3. On Windows, the MSVC developer environment (`vcvarsall.bat`) for the capture step.

## Process

### Phase 1 — Configure the compiler for Coverity (once)

`cov-build` needs a compiler configuration produced by `cov-configure`. Keep it in a dedicated dir so you don't mutate the Coverity install. On Windows/MSVC:

```bat
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat" x64
"%COV%\bin\cov-configure" --config C:\capture\cov-config\coverity_config.xml --msvc
```
`--msvc` configures `cl`/`devenv`/`lib`/`link`/`msbuild` in one shot. For GCC/Clang use `--gcc`/`--clang` (or a template, e.g. `--comptype gcc --compiler gcc`). See the [configure-blackduck-compilers](../configure-blackduck-compilers/SKILL.md) skill for mapping unusual compilers.

### Phase 2 — Capture a CLEAN build with `--emit-link-units`

`--emit-link-units` is **mandatory** for skip_build — the tool relies on link-unit data when it later reads the emit. Wrap a from-scratch build:

```bat
call "...\vcvarsall.bat" x64
cd /d C:\path\to\project
"%COV%\bin\cov-build" --dir C:\capture\idir --config C:\capture\cov-config\coverity_config.xml --emit-link-units cmake --build build --clean-first
```

A good capture ends with `Emitted N C/C++ compilation units (100%) successfully` and `Emitted M link units (100%)`. (The compilation-unit count is normally a bit lower than the number of build steps — resource-compile and link steps aren't C/C++ TUs.)

> For a `cov-cli` (`coverity capture`) capture instead of classic `cov-build`, pass the same flag through as `-o capture.build.cov-build-args=--emit-link-units`. Either engine produces an `idir` that skip_build can consume.

### Phase 3 — Verify the capture OFFLINE (the payoff)

Before any server contact:
- Confirm `C:\capture\idir\build-log.txt` exists (this is the marker blackduck-c-cpp keys on).
- List the emitted translation units and eyeball that your real sources are there:
  ```bat
  "%COV%\bin\cov-manage-emit" --dir C:\capture\idir list
  ```
  You should see your project's `.c`/`.cpp` files. If sources are missing, the build wasn't clean or a compiler wasn't configured — fix that before proceeding.

### Phase 4 — Write the skip_build config

Point `cov_output_dir` at the `idir` you just made. See `references/config.skip-build.sample.yaml`.

```yaml
skip_build: True
coverity_root: C:\Coverity\cov-analysis-win64-2026.3.0
cov_output_dir: C:\capture\idir          # contains build-log.txt -> used directly as the idir
build_dir: C:\path\to\project            # still REQUIRED by the parser, though nothing is built
output_dir: C:\capture\bdcpp-output      # keep OUTSIDE build_dir
project_name: myproject
project_version: 1.0.0
bd_url: https://sca.example.blackduck.com/
api_token: REPLACE_WITH_API_TOKEN
modes: sig,bdba
verbose: True
```

Run it:
```bash
.venv/Scripts/blackduck-c-cpp --config config.yaml
```
With `skip_build` set, the tool skips the build/capture step and goes straight to `cov-manage-emit` → `cov-emit-link` → sig/BDBA → upload.

### Phase 5 — Verify the BOM

Same as vanilla: confirm the project-version exists with a non-empty BOM (UI or `/components` API call).

## Key facts and gotchas

- **`--emit-link-units` is required.** The tool's own help says so, and the skip_build path assumes it. Omit it and the emit-link parsing degrades or fails.
- **How `cov_output_dir` is interpreted.** If the path you give **contains `build-log.txt`**, the tool treats it as the `idir` directly. Otherwise it looks for `<cov_output_dir>/idir`. Pass the actual `cov-build --dir` target and you're safe.
- **Capture engine (cov-build vs cov-cli) is YOUR choice here.** Because skip_build performs no capture, the `set_coverity_mode` / "cov-cli for ≥2023.9" behavior is irrelevant to the `blackduck-c-cpp` run — it only ever runs `cov-manage-emit`/`cov-emit-link` against your `idir`.
- **`coverity_root` is required** in this mode (the tool needs `cov-manage-emit`/`cov-emit-link` from it). There is no GCP auto-download to fall back on — that's the whole reason this path needs local Coverity.
- **`build_dir` is still a required argument** even though nothing is built. Point it at the project tree.
- **Clean build still matters — at capture time.** The capture in Phase 2 only records compilations that execute. A pre-built tree captures nothing; use `--clean-first` / `make clean` etc.
- **Windows MSVC env** applies to the `cov-build`/`cov-configure` steps (needs `cl.exe` on `PATH`), not to the later `blackduck-c-cpp` skip_build run.

## Bundled resources

- `references/config.skip-build.sample.yaml` — a correctly-formatted skip_build config.
- `references/capture-msvc.bat` — a template that runs `cov-configure --msvc` + `cov-build --emit-link-units` under the MSVC environment.
