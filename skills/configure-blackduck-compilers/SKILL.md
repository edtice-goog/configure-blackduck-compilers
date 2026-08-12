---
name: configure-blackduck-compilers
description: Diagnose and fix "unconfigured compiler" warnings from the blackduck-c-cpp scan tool by mapping detected compiler executables to Coverity compiler types and writing the resulting cov_configure_args entry into the tool's YAML config. Use when a user mentions blackduck-c-cpp, "unconfigured compilers", the scan-transparency directory, cov_configure_args, or asks how to make Black Duck recognize their compiler.
---

# Configure Black Duck C/C++ compilers

Black Duck's `blackduck-c-cpp` tool wraps Coverity's `cov-build` to capture C/C++ builds. On the first run it auto-detects compilers, but if it doesn't recognize one it writes a **subtle warning** and dumps the executable path(s) to a file called `unconfigured-compilers` inside the intermediate directory. The fix is to tell the tool which Coverity compiler type each unrecognized executable maps to, using a `cov_configure_args` entry in the YAML config, then rerun.

This skill automates that loop end-to-end.

**Baseline fact you must know before doing any matching:** Coverity's `cov-configure` itself has **zero** pre-configured compilers. But the `blackduck-c-cpp` wrapper ships a default `COVERITY_SITE_CC` capture list covering the GCC/binutils family:

```
*-g++ ; *-gcc ; ar ; g++ ; g++-* ; gcc ; gcc-* ; ld
```

Anything matching one of those patterns is recognized silently — it should never appear in `unconfigured-compilers` in the first place. Real-world entries in that file are things *outside* this list: MSVC `cl`, embedded/proprietary toolchains (IAR, TASKING, Green Hills, TI, Renesas, ARMCC), Intel `icc`/`icx`, `nvcc`, and cross-compilers with non-standard naming. See "Key facts and gotchas" below for the corollary — a GCC-family entry showing up here is itself a signal.

## When to invoke

Trigger on any of:
- The user mentions `blackduck-c-cpp`, `cov_configure_args`, "unconfigured compilers", or the file path `scan-transparency/unconfigured-compilers`.
- The user shares a build that seems to have completed but with too few files captured, and mentions Black Duck / Coverity.
- The user asks to configure a compiler for a Black Duck scan.
- The user shares an `idir/` directory and asks what's wrong with it.

Do **not** invoke for generic Coverity `cov-build` questions unrelated to `blackduck-c-cpp`, or for compiler configuration in Coverity Connect / Polaris workflows.

## Inputs you need

Before doing any work, establish these three things (ask the user if not obvious from context):

1. **The intermediate directory** (`idir`) — the folder that contains `scan-transparency/unconfigured-compilers`. Often called `idir/` but the user may have renamed it via the `--output_dir` or `-o` flag.
2. **The blackduck-c-cpp YAML config file** — usually named something like `application.yaml`, `bd-cpp.yaml`, or passed via `-c/--config`.
3. **Whether Coverity is on PATH** — check with `cov-configure --help` (should exit 0). If yes, prefer the live compiler-types list. If no, use the bundled `references/compile-types.txt`.

## Process

Work through these phases in order. Confirm with the user at the marked checkpoints.

### Phase 1 — Read the unconfigured-compilers file

Read `<idir>/scan-transparency/unconfigured-compilers`. Its format is one indexed entry per line:

```
1	C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.44.35207\bin\HostX86\x86\cl.exe
2	
```

Extract the compiler basenames — strip the directory prefix, strip a trailing `.exe` on Windows, and de-duplicate. From the example above you get `cl`.

If the file is missing, tell the user Black Duck didn't report any unconfigured compilers — either the scan succeeded, or you're looking at the wrong `idir`.

### Phase 2 — Load the compiler-types catalog

Try the live source first:

```
cov-configure --list-compiler-types
```

Each line is a comma-separated 5-tuple:

```
<type>,<def-name>,<language>,<family-role>,<description>
```

- **type** — the value that goes on the right side of the `cov_configure_args` entry (e.g. `msvc`, `tasking:tricore`).
- **def-name** — the default executable basename Coverity associates with this type (e.g. `cl` for `msvc`). Look this up to match executables from Phase 1. Some rows list `<no-def-name>` — those don't participate in this match step.
- **language** — `C`, `CXX`, `C#`, `CUDA`, `JAVA`, `OBJC`, `OBJCXX`, `NC`, etc.
- **family-role** — `FAMILY HEAD` (represents a family root, pulls in its children) or `SINGLE`.
- **description** — free text; useful for showing candidates to the user.

If `cov-configure` isn't on PATH, fall back to `references/compile-types.txt` bundled with this skill. Warn the user the bundle may lag their installed Coverity version.

### Phase 3 — Match each unconfigured executable to a compiler type

**Sanity check first.** For each basename, check whether it matches the wrapper's default `COVERITY_SITE_CC` patterns: `*-g++`, `*-gcc`, `ar`, `g++`, `g++-*`, `gcc`, `gcc-*`, `ld`. If any basename matches one of those, do **not** silently proceed to add a mapping — pause and tell the user: "This executable should already be recognized by the `blackduck-c-cpp` default `COVERITY_SITE_CC` list. Seeing it in `unconfigured-compilers` suggests something has overridden the default, the wrapper version is old, or the binary isn't a real GCC. Confirm before I add a mapping." Only add the mapping if the user confirms they still want it as a workaround.

For every remaining basename:

1. Find all catalog rows where `def-name` equals that basename.
2. Apply the **parent-pulls-in-children rule**: prefer the row that represents the family parent, because Black Duck / Coverity auto-picks up the C++/CXX/CC/objcxx children of a chosen C parent. In practice this means:
   - **Drop rows whose type name ends in `_cxx`, `_cpp`, `_cxxcc`, `_cppcc`, `cxx`, `cpp`, `objc`, or `objcxx`** when a non-suffixed sibling exists with the same `def-name`. Example: for `cl`, keep `msvc` (C) and drop `msvc_cxx` (CXX).
   - If there is no C parent (only a C++ row), keep the C++ row.
3. Among the survivors, prefer `FAMILY HEAD` over `SINGLE`.
4. If exactly one row remains, that's your mapping. Record `basename -> type`.
5. If more than one row remains (real ambiguity — e.g., both `armcc:armcc` and `armcc:armclang` match `armcc`), stop and present the candidates to the user as a picklist. Show each candidate's type, language, family-role, and description. Wait for a choice before continuing.
6. If **zero** rows match (executable name isn't a canonical `def-name`, common for cross-compilers like `aarch64-linux-gnu-gcc`), try:
   - **Wildcard**: strip common prefixes/suffixes (`aarch64-linux-gnu-`, `x86_64-pc-linux-gnu-`, `arm-none-eabi-`) and re-match on the stem (`gcc`, `g++`). If that matches, propose a wildcard key like `"*-gcc"` or `"*gcc"` instead of the bare name.
   - **Substring**: match def-names that appear as a substring of the basename (e.g., `gcc` inside `arm-linux-gcc-11`).
   - **Ask**: if still nothing, present the top few "similar-looking" catalog rows and ask the user to pick or type a custom mapping.

### Phase 4 — Show the plan and get approval

Before touching any file, print a table of what you're about to add:

```
Executable                              Key in YAML    Compiler type
--------------------------------------  -------------  --------------------
C:\...\HostX86\x86\cl.exe               cl             msvc
C:\...\aarch64-linux-gnu-gcc            *-gcc          gcc
```

Note:
- Keys are executable basenames or wildcard patterns, **without** the `.exe` suffix on Windows.
- Wildcards use `*` (e.g., `"*g++"`).

Ask the user to confirm. Do not proceed until they say yes.

### Phase 5 — Update the YAML config

Read the existing YAML. If it already has a `cov_configure_args:` line, merge new entries into the existing dict (do not overwrite existing keys unless the user explicitly asked to replace them). If it doesn't, append a new line at the end of the file.

Preserve the tool's documented inline-flow syntax exactly:

```yaml
cov_configure_args: {"cl":"msvc","*-gcc":"gcc"}
```

Do **not** rewrite it as block-style YAML — the tool's docs and examples use flow style and reformatting risks breaking user tooling that greps for that literal shape.

If you can't safely merge (e.g., existing entry is on multiple lines or has comments you'd lose), fall back to showing the user the diff and asking them to paste it in themselves.

### Phase 6 — Verify by rerun

Ask the user to rerun `blackduck-c-cpp` with the same config, and to share:
- The new `<idir>/scan-transparency/unconfigured-compilers` (should be empty or missing for full success), and
- The `blackduck-c-cpp.log` (default under `<user_home>/.blackduck/blackduck-c-cpp/output/<project_name>/`) so you can confirm the compiler was captured.

If unconfigured-compilers is still populated with different executables, loop back to Phase 1 for the new list. If it still lists the *same* executables you just configured, the mapping likely didn't match — investigate the wildcard/basename spelling and try again.

## Key facts and gotchas

- **The warning is subtle.** The tool doesn't crash and doesn't print a huge red banner; it just says something like "some compilers were not configured, see …" and continues. Users routinely miss it and think their scan succeeded when it didn't. If a user reports "scan finished but Black Duck shows no components", check `unconfigured-compilers` first.
- **GCC/binutils family is pre-configured by the wrapper, not by Coverity.** Coverity's `cov-configure` has no built-in compiler defaults. The `blackduck-c-cpp` wrapper sets `COVERITY_SITE_CC = *-g++;*-gcc;ar;g++;g++-*;gcc;gcc-*;ld`, which covers plain GCC and standardly named GCC cross-compilers automatically. A GCC-family executable landing in `unconfigured-compilers` is anomalous — see the sanity check at the top of Phase 3.
- **Basename, not path.** The key in `cov_configure_args` is the executable name, not the full path. Windows callers may see `cl.exe` in the file but the YAML key should be `cl` (no extension).
- **Family parent picks up children automatically.** You almost never need both `msvc` and `msvc_cxx` — just `msvc`. Same for `gcc`/`g++cc`, `intel_oneapi_icx`/`intel_oneapi_icpx`, etc. The exception is when C and C++ are genuinely separate executables (like `gcc` vs `g++`) — then you need one entry per binary.
- **Wildcards work.** For a fleet of cross-compilers (`arm-none-eabi-gcc`, `aarch64-linux-gnu-gcc`, …) a single `"*-gcc": "gcc"` or `"*gcc": "gcc"` entry covers them all. Prefer wildcards when a stem repeats.
- **YAML flow syntax matters.** The Black Duck docs use `{"key":"value"}` flow-style. Keep it. Do not expand to block-style `key: value` — that mixes with YAML dict scoping and some downstream tooling breaks on it.
- **`.codesight/`, `emit/`, `output/`, `tmp/`** inside `idir/` are internal to Coverity's capture — ignore them.
- **`build-log.txt`** in `idir/` contains the cov-build transcript. Not usually needed for this task, but it's where to look if the mapping seems right but capture still fails (search for the executable path and check for `Cannot find compiler configuration for`).

## Bundled resources

- `references/compile-types.txt` — snapshot of `cov-configure --list-compiler-types` output for use when Coverity isn't on PATH. Update this file when Coverity ships a new release with new compiler support.
