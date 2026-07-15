# Configuring compilers for the Black Duck C/C++ scan tool

This guide walks you through what to do when `blackduck-c-cpp` finishes a build but silently reports that one or more compilers were not configured. Left unfixed, the scan looks like it succeeded but Black Duck won't see the code you thought you scanned.

Homepage for the tool: https://pypi.org/project/blackduck-c-cpp/

There is also a companion Claude Code skill (`configure-blackduck-compilers/`) that automates this whole process. If you have Claude Code available, invoking the skill is faster and less error-prone than following these steps by hand. The manual walkthrough below is here for people without Claude Code, for CI/audit contexts, and to explain *why* each step matters.

---

## Table of contents

1. [Why this task exists](#1-why-this-task-exists)
2. [What you need before starting](#2-what-you-need-before-starting)
3. [Step 1 — Confirm you actually have unconfigured compilers](#step-1--confirm-you-actually-have-unconfigured-compilers)
4. [Step 2 — Extract the executable name(s)](#step-2--extract-the-executable-names)
5. [Step 3 — Look up the compiler type](#step-3--look-up-the-compiler-type)
6. [Step 4 — Choose the right type when there are several](#step-4--choose-the-right-type-when-there-are-several)
7. [Step 5 — Add the `cov_configure_args` entry to your YAML config](#step-5--add-the-cov_configure_args-entry-to-your-yaml-config)
8. [Step 6 — Rerun and verify](#step-6--rerun-and-verify)
9. [Worked example: MSVC `cl.exe`](#worked-example-msvc-clexe)
10. [Worked example: fleet of cross-compilers](#worked-example-fleet-of-cross-compilers)
11. [Troubleshooting](#troubleshooting)
12. [Reference tables](#reference-tables)

---

## 1. Why this task exists

`blackduck-c-cpp` is a Python wrapper around Synopsys/Black Duck Coverity's `cov-build`. It intercepts your build, sees which compilers ran, and asks Coverity to capture each translation unit. Coverity ships with configuration templates for hundreds of compilers — GCC, MSVC, IAR, Green Hills, TI, etc. — but it needs to know **which template applies to each executable it saw**.

> **Important distinction.** Coverity's `cov-configure` itself does **not** pre-configure any compiler. Every mapping must be told to it explicitly. However, the `blackduck-c-cpp` wrapper layered on top of Coverity does set a default site-wide capture list (`COVERITY_SITE_CC`) that covers the GCC/binutils family out of the box:
>
> ```
> *-g++ ; *-gcc ; ar ; g++ ; g++-* ; gcc ; gcc-* ; ld
> ```
>
> So if you're only running plain GCC or common GCC cross-compilers (like `arm-none-eabi-gcc`, `aarch64-linux-gnu-g++`), you shouldn't see anything in `unconfigured-compilers` — the wrapper handles them silently. The executables that *do* show up in that file are the ones outside this default list: MSVC's `cl`, embedded/proprietary toolchains (IAR, TASKING, Green Hills, TI, Renesas, ARMCC…), Intel `icc/icx`, `nvcc`, cross-compilers with unusual naming (`<vendor>cc` rather than `<triple>-gcc`), and so on.

On the first run the tool tries to auto-detect. If it can't identify a compiler executable, it does two things:

- Emits a warning that's easy to miss (buried in verbose output, no red banner, no non-zero exit code).
- Writes the offending executable path(s) to `<idir>/scan-transparency/unconfigured-compilers`.

If you don't notice, the scan appears to finish successfully, but any code compiled by that unrecognized compiler is **silently absent** from the emit database and therefore from Black Duck's component analysis. That's the failure mode this document exists to prevent.

The fix is to add an entry to a YAML key called `cov_configure_args` that tells the tool "when you see executable X, treat it as Coverity compiler type Y", then rerun.

---

## 2. What you need before starting

- The **intermediate directory** from the previous run, commonly called `idir/`. If you ran with `--output_dir`/`-o`, it's whatever you passed there.
- The **YAML config file** you're passing to `blackduck-c-cpp` via `-c` (or a positional argument). This is the file you'll edit.
- A Coverity installation (`cov-configure` on your PATH) so you can list all supported compiler types. Not strictly required — you can use the bundled `compile-types.txt` in this repository instead — but the live output is authoritative for your installed version.
- Read/write access to both directories above.

---

## Step 1 — Confirm you actually have unconfigured compilers

Open the file:

```
<idir>/scan-transparency/unconfigured-compilers
```

It's a plain text file with one indexed entry per line. On a real run it looks like this:

```
1	C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.44.35207\bin\HostX86\x86\cl.exe
2	
```

**If the file doesn't exist** or is empty, you have no unconfigured compilers and there's nothing to do. Your scan is fine (from this angle — component coverage is a different question).

**If it lists one or more paths**, note each one. You'll process each unique executable in the steps below.

> **Why this file?** It's the tool's built-in escape hatch for "I saw a compiler I don't know how to handle." It's the single source of truth for what needs fixing.

---

## Step 2 — Extract the executable name(s)

For each path in the file, take the **basename** and drop any trailing `.exe`:

| Full path from the file                                                                       | Executable basename |
|-----------------------------------------------------------------------------------------------|---------------------|
| `C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.44.35207\bin\HostX86\x86\cl.exe` | `cl`                |
| `/opt/gcc-arm-none-eabi-10.3/bin/arm-none-eabi-gcc`                                           | `arm-none-eabi-gcc` |
| `/usr/bin/aarch64-linux-gnu-g++`                                                              | `aarch64-linux-gnu-g++` |

De-duplicate. If the file lists `cl.exe` from three different Visual Studio installs, they all have the same basename (`cl`) and you only need one entry.

> **Why basename?** The YAML key you'll write in Step 5 is matched by name (or wildcard), not by path. A basename covers every install location of the same tool.

---

## Step 3 — Look up the compiler type

Every Coverity-supported compiler has a **type name** like `msvc`, `gcc`, `tasking:tricore`, or `iar:arm`. You'll use that name as the *value* in your YAML mapping. Two ways to get the list:

**Preferred — live output from your installed Coverity:**

```
cov-configure --list-compiler-types
```

**Fallback — the `compile-types.txt` shipped with this repo.** Use only if `cov-configure` isn't on your PATH. Be aware it may lag your installed Coverity version.

Each line has this format:

```
<type>,<def-name>,<language>,<family-role>,<description>
```

- **type** — what you'll put in the YAML (e.g. `msvc`).
- **def-name** — the default executable basename Coverity associates with this type (e.g. `cl`). **This is what you match against your Step 2 basename.**
- **language** — `C`, `CXX`, `C#`, `JAVA`, `NC`, etc.
- **family-role** — `FAMILY HEAD` (a family root that pulls in its children automatically) or `SINGLE` (a leaf).
- **description** — human-readable label.

Grep or search for your basename in the second column. For `cl`:

```
msvc,cl,C,FAMILY HEAD,Microsoft Visual Studio (CIT)
msvc_cxx,cl,CXX,SINGLE,Microsoft Visual Studio (C++) (CIT)
```

Two hits. Move to Step 4.

> **Why the def-name column and not the type column?** The type is what Coverity calls the *configuration*; the def-name is what the *executable* is named on disk. Your unconfigured-compilers file gives you the executable name, so you match on def-name.

---

## Step 4 — Choose the right type when there are several

The catalog often lists both a C variant and a C++ variant that share the same executable name (like `msvc`/`msvc_cxx` both mapping to `cl`, because `cl.exe` compiles both C and C++ depending on the input file's extension). You almost never want to enter both.

**Rule of thumb: pick the parent, not the child.** In this catalog the C variant is the parent — choosing it makes Coverity automatically pick up its C++/CXX/objcxx siblings when it needs them. That means:

- **Drop rows whose type name ends in `_cxx`, `_cpp`, `_cxxcc`, `_cppcc`, `cxx`, `cpp`.** These are the C++/CXX children.
- Prefer `FAMILY HEAD` rows over `SINGLE` rows.
- If only one row is left, that's your type.

For our `cl` example, after applying the rule:

- Drop `msvc_cxx` (ends in `_cxx`).
- Keep `msvc` (FAMILY HEAD, C).

Your mapping is `cl -> msvc`.

**When C and C++ really are separate executables** (like `gcc` and `g++`), the file will list each separately and each gets its own entry:

- `gcc` -> `gcc`
- `g++` -> `g++`

**When you get zero matches** — common for cross-compilers named things like `arm-none-eabi-gcc` — try:

1. Strip common prefixes/suffixes (`aarch64-linux-gnu-`, `arm-none-eabi-`, `x86_64-pc-linux-gnu-`) and re-match on the stem. If you'd match `gcc`, you can use a **wildcard** key like `"*-gcc"` or `"*gcc"` instead of the bare cross-compiler name. Wildcards are supported.
2. If still nothing, look for def-names that appear as a substring of your basename (e.g. `gcc` inside `arm-linux-gcc-11`).
3. If still nothing, the compiler may need explicit configuration by name — check Black Duck / Coverity documentation for that specific toolchain, or open a support case.

**When you get several remaining candidates** — for example both `armcc:armcc` and `armcc:armclang` are family heads with def-name `armcc` — you have to decide which one your toolchain actually is. Look at the description column; if you're not sure, run the compiler with `--version` and match.

---

## Step 5 — Add the `cov_configure_args` entry to your YAML config

Open the YAML file you pass to `blackduck-c-cpp`. Look for an existing `cov_configure_args:` line.

**Format** — the tool's documented syntax is **JSON-style flow inside YAML**:

```yaml
cov_configure_args: {"cl":"msvc"}
```

Multiple entries are comma-separated inside the same braces:

```yaml
cov_configure_args: {"ctc":"tasking:tricore","cctc":"tasking:tricore","cptc":"tasking_cxx:tricore"}
```

Wildcards work in keys:

```yaml
cov_configure_args: {"*g++":"gcc","*-gcc":"gcc"}
```

**If the line already exists**, merge your new entries into the existing dict. Don't replace anyone else's mappings. Example — before:

```yaml
cov_configure_args: {"ctc":"tasking:tricore"}
```

after adding `cl -> msvc`:

```yaml
cov_configure_args: {"ctc":"tasking:tricore","cl":"msvc"}
```

**If the line doesn't exist**, add it at the top level of the YAML (same indentation as `build_cmd`, `project_name`, etc. — no leading whitespace).

**Keep flow style.** Do not rewrite this as block-style YAML like:

```yaml
# DO NOT do this
cov_configure_args:
  cl: msvc
```

The tool's docs, examples, and community tooling all assume the flow form. Sticking with it avoids surprises.

Save the file.

> **Why flow style?** Consistency with the Black Duck docs, and because `cov_configure_args` is passed straight through to Coverity as a JSON blob on the `cov-configure` command line. The flow form makes that round-trip visually explicit.

---

## Step 6 — Rerun and verify

Rerun `blackduck-c-cpp` with the same config file. When it finishes:

1. Reopen `<idir>/scan-transparency/unconfigured-compilers`. It should be **empty or missing**. If it still lists the same executables, your key spelling doesn't match — check for typos, `.exe` suffixes, missing wildcards.
2. If it lists **different** executables than before, you've made progress; loop back to Step 2 with the new list.
3. Skim `blackduck-c-cpp.log` (default location: `<user_home>/.blackduck/blackduck-c-cpp/output/<project_name>/blackduck-c-cpp.log`) for the executable you just configured. You want to see it being invoked/captured without warnings.

You're done when both signals agree: `unconfigured-compilers` is empty **and** the log shows the compiler being captured cleanly.

---

## Worked example: MSVC `cl.exe`

Starting state — the file `idir/scan-transparency/unconfigured-compilers` contains:

```
1	C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\14.44.35207\bin\HostX86\x86\cl.exe
2	
```

Step 2 — basename: `cl` (dropped the path and the `.exe`).

Step 3 — `cov-configure --list-compiler-types | grep ',cl,'` returns:

```
msvc,cl,C,FAMILY HEAD,Microsoft Visual Studio (CIT)
msvc_cxx,cl,CXX,SINGLE,Microsoft Visual Studio (C++) (CIT)
```

Step 4 — apply the parent-picks-up-children rule. Drop `msvc_cxx` (ends in `_cxx`). Keep `msvc`. Mapping: `cl -> msvc`.

Step 5 — YAML edit. Before:

```yaml
build_cmd: msbuild MySolution.sln
build_dir: C:\src\myproject
project_name: myproject
project_version: 2026.1
bd_url: https://blackduck.example.com
api_token: <token>
```

After:

```yaml
build_cmd: msbuild MySolution.sln
build_dir: C:\src\myproject
project_name: myproject
project_version: 2026.1
bd_url: https://blackduck.example.com
api_token: <token>
cov_configure_args: {"cl":"msvc"}
```

Step 6 — rerun. `unconfigured-compilers` is now empty. Done.

---

## Worked example: fleet of cross-compilers

> **Note — this example is illustrative, not typical.** The `blackduck-c-cpp` wrapper's default `COVERITY_SITE_CC` list already covers `*-gcc`, `*-g++`, `gcc-*`, `g++-*`, plain `gcc`/`g++`, `ar`, and `ld` — so a fleet of standardly named GCC cross-compilers **won't** show up in `unconfigured-compilers` in the first place. It's included here because the wildcard technique is the same one you'll use for non-GCC-family fleets (e.g., a set of Renesas `ch*`/`nc*` variants, or `iccarm`/`icc430`/`iccrx` IAR toolchains). If a plain `arm-none-eabi-gcc`-shaped executable *does* land in `unconfigured-compilers`, that itself is a signal — see the troubleshooting entry below.

Starting state — `unconfigured-compilers` lists:

```
1	/opt/toolchains/aarch64-linux-gnu/bin/aarch64-linux-gnu-gcc
2	/opt/toolchains/arm-none-eabi/bin/arm-none-eabi-gcc
3	/opt/toolchains/riscv64-unknown-elf/bin/riscv64-unknown-elf-gcc
4	/opt/toolchains/aarch64-linux-gnu/bin/aarch64-linux-gnu-g++
```

Step 2 — basenames: `aarch64-linux-gnu-gcc`, `arm-none-eabi-gcc`, `riscv64-unknown-elf-gcc`, `aarch64-linux-gnu-g++`.

Step 3 — none of these are canonical def-names, but they all share a stem: `-gcc` or `-g++`. Applying the wildcard heuristic:

- All three `*-gcc` variants collapse to a single wildcard entry `"*-gcc": "gcc"`.
- The `*-g++` variant becomes `"*-g++": "g++"`.

Step 4 — one type per stem; nothing ambiguous.

Step 5 — add:

```yaml
cov_configure_args: {"*-gcc":"gcc","*-g++":"g++"}
```

Step 6 — rerun. Two wildcard entries handled four executables. `unconfigured-compilers` is empty.

---

## Troubleshooting

- **The scan looks successful but Black Duck reports 0 components.** Check `unconfigured-compilers` first. This is the single most common cause of "silent" failed scans.
- **The scan ran, `unconfigured-compilers` is empty, but Black Duck still misses code.** This isn't a compiler-configuration problem — check `blackduck-c-cpp.log` for capture warnings, verify `build_cmd` actually builds what you think it does, and confirm the affected source files are on disk when the scan runs.
- **The YAML edit didn't take effect.** Confirm you edited the file you're actually passing to the tool (`-c <path>` on the command line). If you have multiple candidate YAMLs, the tool uses the one it's told to.
- **`unconfigured-compilers` keeps listing the same executable after you configured it.** Common causes: the key includes `.exe`, the key is a full path instead of a basename, or the executable's real basename differs from what you expected. Print the exact bytes with `xxd` / `hexdump` if you suspect trailing whitespace or a hidden character.
- **`cov-configure --list-compiler-types` says command not found.** Source your Coverity environment (`bin/cov-configure` on Linux, `set-path.bat` or the equivalent on Windows), or use the bundled `compile-types.txt` in this repo.
- **A compiler you know is supported still won't match.** Look at the compiler's actual `--version` output and search descriptions in `compile-types.txt` for a matching phrase — some toolchains alias unexpectedly.
- **The warning wasn't visible in the console.** Set `verbose: True` in your YAML and rerun; the warning shows more prominently in verbose mode.
- **A plain GCC-family executable (`gcc`, `g++`, `*-gcc`, `*-g++`, `ar`, `ld`) shows up in `unconfigured-compilers`.** Unusual — those are pre-configured by the `blackduck-c-cpp` wrapper via its default `COVERITY_SITE_CC` list. Something else is off. Check: (a) your `blackduck-c-cpp` version isn't ancient, (b) nothing in your YAML or environment is overriding `COVERITY_SITE_CC`, (c) the executable actually is a GCC and not a differently named binary that happens to end in `gcc` (e.g., some Renesas tools). If all three check out, adding an explicit mapping is fine as a workaround but you should also file an issue upstream.

---

## Reference tables

### Common `unconfigured-compilers` executables and their canonical mappings

Entries marked **[default]** are already recognized by the `blackduck-c-cpp` wrapper's default `COVERITY_SITE_CC` list — you should not need to add them. They're included for completeness so you can recognize what's already covered.

| Executable         | YAML key       | Compiler type       | Notes                                                    |
|--------------------|----------------|---------------------|----------------------------------------------------------|
| `cl.exe`           | `cl`           | `msvc`              | Handles both C and C++ from one binary                   |
| `gcc`              | `gcc`          | `gcc`               | **[default]** already in `COVERITY_SITE_CC`              |
| `g++`              | `g++`          | `g++`               | **[default]** already in `COVERITY_SITE_CC`              |
| `arm-none-eabi-gcc`| `*-gcc`        | `gcc`               | **[default]** `*-gcc` already in `COVERITY_SITE_CC`      |
| `ar`               | `ar`           | `ar`                | **[default]** already in `COVERITY_SITE_CC` (archiver)   |
| `ld`               | `ld`           | `ld`                | **[default]** already in `COVERITY_SITE_CC` (linker)     |
| `clang`            | `clang`        | `clangcc`           | Or `clangcc:llvm` for LLVM specifically                  |
| `clang++`          | `clang++`      | `clangcxx`          |                                                          |
| `nvcc`             | `nvcc`         | `nvcc`              | CUDA compiler                                            |
| `icc`              | `icc`          | `intelcc:linux`     |                                                          |
| `icpx`             | `icpx`         | `intel_oneapi_icpx` | Intel OneAPI C++                                         |
| `icx`              | `icx`          | `intel_oneapi_icx`  | Intel OneAPI C                                           |
| `ctc`              | `ctc`          | `tasking:tricore`   | TASKING TriCore C compiler                               |
| `iccarm`           | `iccarm`       | `iar:arm`           | IAR ARM C compiler                                       |

### File and directory landmarks

| Path                                              | Purpose                                                     |
|---------------------------------------------------|-------------------------------------------------------------|
| `<idir>/scan-transparency/unconfigured-compilers` | List of compilers the tool couldn't identify — start here   |
| `<idir>/build-log.txt`                            | Full cov-build transcript (useful for debugging capture)    |
| `<idir>/emit/`                                    | Coverity's emit database — internal, don't touch            |
| `<user_home>/.blackduck/blackduck-c-cpp/output/<project_name>/blackduck-c-cpp.log` | Default location of the tool's own log |

### The five columns of `cov-configure --list-compiler-types`

```
<type>,<def-name>,<language>,<family-role>,<description>
```

- **type** — value on the right side of the YAML mapping.
- **def-name** — column to match against your Step 2 basename.
- **language** — `C`, `CXX`, `C#`, `CUDA`, `JAVA`, `NC`, `OBJC`, `OBJCXX`, `GO`, `KOTLIN`, `RAZOR`, `VB`.
- **family-role** — `FAMILY HEAD` or `SINGLE`.
- **description** — free text.
