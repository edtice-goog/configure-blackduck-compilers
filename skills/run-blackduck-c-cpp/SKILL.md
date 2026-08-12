---
name: run-blackduck-c-cpp
description: Run a standard (vanilla) blackduck-c-cpp C/C++ scan where the tool drives its own Coverity build capture, then uploads signature and binary (BDBA) results to a Black Duck SCA server. Use when a user wants to scan a C/C++ project with Black Duck, mentions blackduck-c-cpp, "capture a build for Black Duck", cov-build/cov-cli capture, or wants to create a Black Duck project-version + BOM from a native build. This is the DEFAULT way to run the tool. For reusing an existing Coverity capture instead of letting the tool build, see run-blackduck-c-cpp-skip-build.
---

# Run blackduck-c-cpp (vanilla capture)

`blackduck-c-cpp` scans C/C++ projects for Black Duck SCA. It wraps a Coverity build-capture engine (`cov-cli` on Coverity ≥ 2023.9, `cov-build` on older) around **your build command**, captures every source/binary the build touches, then runs three matchers — package-manager, signature (Knowledge Base), and binary (BDBA) — and uploads the results to a Black Duck server, creating/updating a project-version and its BOM.

This skill covers the **default** flow: the tool performs the build capture itself. It is the right choice for almost everyone. Only reach for [run-blackduck-c-cpp-skip-build](../run-blackduck-c-cpp-skip-build/SKILL.md) when you need to reuse a hand-run Coverity capture (advanced/debug, and requires local Coverity binaries).

## When to invoke

Trigger on any of:
- The user wants to run a Black Duck C/C++ scan or "capture a build" for Black Duck.
- The user mentions `blackduck-c-cpp`, `cov-build`/`cov-cli` capture, a `config.yaml`/`application.yaml` for the tool, or `bd_url` + `api_token`.
- The user has a native build (Make/CMake/MSBuild/Ninja/etc.) and wants a Black Duck project-version + BOM from it.

Do **not** invoke for: Black Duck Detect / package-manager-only scans, Coverity static-analysis (defect) workflows, or the SARIF conversion step (that's [run-blackduck-sarif-formatter](../run-blackduck-sarif-formatter/SKILL.md)).

## Inputs you need

Establish these before writing a config (ask the user if not obvious):

1. **Black Duck server URL** (`bd_url`) and an **API token** (`api_token`). The token can instead come from the `BLACKDUCK_API_TOKEN` (or `BD_HUB_TOKEN`) environment variable — prefer that over plaintext-in-config when the user cares about secret hygiene.
2. **Project name and version** (`project_name`, `project_version`) — how it will appear in Black Duck.
3. **A working, buildable project** plus its **build command** (`build_cmd`) and the **directory to run it from** (`build_dir`).
4. **Coverity availability** (`coverity_root`) — optional. If omitted, the tool auto-downloads a "mini" Coverity capture package from Google Cloud Storage for entitled customers (needs outbound `*.googleapis.com:443`). If the environment is air-gapped or you already have a local Coverity install, set `coverity_root` to it.
5. **Platform build environment** — on Windows, the tool must run inside a shell where the compiler is on `PATH` (see the MSVC gotcha below).

## Process

### Phase 1 — Prepare an isolated Python environment

Install into a fresh virtualenv so the tool's pinned deps don't collide with anything else:

```bash
python -m venv .venv
.venv/Scripts/python -m pip install --upgrade pip        # Windows
.venv/Scripts/python -m pip install blackduck-c-cpp
```

Sanity-check: `.venv/Scripts/blackduck-c-cpp --help` should print usage. (blackduck-c-cpp 3.0.6 installs cleanly on Python 3.10–3.14; recent releases ship `cp314` wheels for the native deps.)

### Phase 2 — Ensure a CLEAN build

Coverity capture only records compilations that **actually execute**. If the project is already built, the capture will be nearly empty and the BOM will be missing components. Make `build_cmd` a from-scratch build:
- CMake/Ninja: `cmake --build build --clean-first` (or delete the build dir and reconfigure first).
- Make: `make clean && make`.
- MSBuild: `msbuild /t:Rebuild`.

### Phase 3 — Write the config

`blackduck-c-cpp` uses configargparse's **default** config parser, not full YAML. Follow this exact style: one `key: value` per line, booleans as `True`/`False`, **values unquoted** (the parser keeps quotes literally, so quoting a path or token breaks it). A `#` starts a comment. See `references/config.sample.yaml`.

```yaml
project_name: myproject
project_version: 1.0.0
bd_url: https://sca.example.blackduck.com/
api_token: <paste-raw-unquoted-or-omit-and-use-env-var>
build_dir: /path/to/project
build_cmd: cmake --build build --clean-first
# coverity_root: /opt/coverity/cov-analysis-linux64-2026.3.0   # optional; omit to auto-download
output_dir: /path/to/bdcpp-output          # keep OUTSIDE build_dir
modes: all                                  # all | comma list of: bdba, sig, pkg_mgr
verbose: True
```

Run it:

```bash
.venv/Scripts/blackduck-c-cpp --config config.yaml
```

### Phase 4 — Verify the run and the BOM

A healthy run ends with a `final_status` block listing each phase as `SUCCESS`:
```
Phase BDBA status: SUCCESS
Phase BD Signature Scan status: SUCCESS
```
Then confirm the server side: the project-version exists and its BOM is non-empty. You can check in the Black Duck UI, or with a quick API call (authenticate at `POST /api/tokens/authenticate`, then GET the version's `/components`). An empty BOM after a "successful" run almost always means the build wasn't clean (Phase 2) or a compiler wasn't recognized — see the unconfigured-compilers note below.

## Key facts and gotchas

- **Clean build is mandatory.** The single most common cause of an empty/thin BOM. See Phase 2.
- **Windows: run inside the MSVC developer environment.** The capture engine intercepts the *compiler process*, so `cl.exe` must be on `PATH` with `INCLUDE`/`LIB` set. Launch via `vcvarsall.bat x64` (or a "Developer Command Prompt") and run `blackduck-c-cpp` in that same shell. A batch wrapper is reliable:
  ```bat
  call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat" x64
  blackduck-c-cpp --config config.yaml
  ```
- **Capture mode is chosen by Coverity version.** `cov-cli` (a.k.a. `coverity capture`) runs by default for Coverity ≥ 2023.9; `cov-build` for older. Force the classic engine with `set_coverity_mode: cov-build` if a build system doesn't capture cleanly under cov-cli.
- **`coverity_root` optional but network-gated when omitted.** Auto-download needs `*.googleapis.com:443` and Black Duck entitlement. In locked-down networks, install Coverity locally and set `coverity_root`.
- **`modes`.** `all` = `pkg_mgr` + `sig` + `bdba`. On Windows `pkg_mgr` is effectively a no-op (its detectors are Linux-package oriented) and may log `No linker files found` — harmless. To avoid ancillary noise you can set `modes: sig,bdba`.
- **`output_dir` must be outside `build_dir`.** The tool writes zips/BDIO/logs there; keeping it in the build tree pollutes captures and can recurse.
- **API token via env var.** `api_token` in config is read first, then `BLACKDUCK_API_TOKEN`, then `BD_HUB_TOKEN`. Use the env var to keep the token off disk.
- **Trailing slash on `bd_url` is tolerated here.** The tool strips it internally. (This is NOT true of the SARIF formatter — see that skill.)
- **Unrecognized compilers.** If the log mentions unconfigured compilers or `scan-transparency/unconfigured-compilers` is populated, the BOM will be missing whatever those compilers built. Fix with the [configure-blackduck-compilers](../configure-blackduck-compilers/SKILL.md) skill (maps the executable to a Coverity compiler type via `cov_configure_args`).
- **Logs.** Default under `<user_home>/.blackduck/blackduck-c-cpp/output/<project_name>/`. The tool logs to **stderr**; when capturing on Windows PowerShell with `*>`, PowerShell may wrap stderr lines as `NativeCommandError` — that's cosmetic, judge success by the exit code and the `final_status` block.

## Bundled resources

- `references/config.sample.yaml` — a minimal, correctly-formatted starting config.
