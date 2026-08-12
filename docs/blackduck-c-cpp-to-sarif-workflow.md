# Black Duck C/C++ → SARIF: end-to-end workflow

This runbook shows the full path from a native C/C++ build to a SARIF report, using
`blackduck-c-cpp` for the scan and the community `blackduck-sarif-formatter` for the
SARIF conversion. It is written from a validated end-to-end run (curl 8.4.0 on
Windows), and it links to the skills that automate each stage.

```
 source ──▶ Coverity capture ──▶ blackduck-c-cpp scan ──▶ Black Duck BOM ──▶ SARIF
 (build)     (cov-build /            (sig + BDBA,           (project-           (blackduck-
             cov-cli)                upload)                 version)            sarif-formatter)
```

Related skills:
- [run-blackduck-c-cpp](../skills/run-blackduck-c-cpp/SKILL.md) — the default scan (tool drives the build).
- [run-blackduck-c-cpp-skip-build](../skills/run-blackduck-c-cpp-skip-build/SKILL.md) — reuse a manual Coverity capture (advanced/debug).
- [run-blackduck-sarif-formatter](../skills/run-blackduck-sarif-formatter/SKILL.md) — BOM → SARIF.
- [configure-blackduck-compilers](../skills/configure-blackduck-compilers/SKILL.md) — fix "unconfigured compiler" warnings.

## The two flavors of scan

| | Vanilla ([run-blackduck-c-cpp](../skills/run-blackduck-c-cpp/SKILL.md)) | skip_build ([run-blackduck-c-cpp-skip-build](../skills/run-blackduck-c-cpp-skip-build/SKILL.md)) |
|---|---|---|
| Who builds | `blackduck-c-cpp` runs your `build_cmd` under Coverity | You run `cov-build` yourself; tool reuses the `idir` |
| Coverity needed | Optional (auto-downloads a mini package from GCP) | **Full local install required** |
| Best for | Almost everyone — the default | Debugging, offline capture verification, re-scan without rebuild |
| Verify capture before upload? | No | **Yes** — inspect the `idir` offline first |

Default to **vanilla**. Use **skip_build** only when you specifically need manual capture
control and have local Coverity binaries.

## Worked example: curl 8.4.0 on Windows

### Environment
- Windows 11, Visual Studio Community 2022 (MSVC), CMake, Ninja, Git.
- Python 3.14.6 in a fresh venv. `blackduck-c-cpp` 3.0.6 installed cleanly — all native
  deps had `cp314` wheels.
- Coverity Build Capture **2026.3.0** at `C:\Coverity\cov-analysis-win64-2026.3.0`.
- Black Duck SCA server (field-test).

### Stage 0 — Prove the build in isolation
Build the target by itself first, so any later failure is unambiguously a Black Duck
tooling issue rather than a build issue.

```
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCURL_USE_SCHANNEL=ON `
      -DBUILD_CURL_EXE=ON -DCURL_ZLIB=OFF -DCURL_USE_LIBPSL=OFF -DBUILD_TESTING=OFF ...
cmake --build build
```
curl 8.4.0 built clean with MSVC + Ninja + Schannel and **zero external dependencies**
(Schannel is Windows' native TLS). Run under a `vcvarsall.bat x64` environment so
`cl.exe` is on `PATH`.

> Runtime note: a shared build puts `curl.exe` and `libcurl.dll` in different folders,
> so `curl.exe --version` exits 53 ("DLL not found") until the DLL is on the loader path.
> Irrelevant to capture (which keys off compile/link commands), but a classic head-scratcher.

### Stage 1 — Capture with Coverity (skip_build flavor shown)
```
cov-configure --config C:\capture\cov-config\coverity_config.xml --msvc
cov-build --dir C:\capture\idir --config ...\coverity_config.xml --emit-link-units cmake --build build --clean-first
```
Result: 213 C/C++ compilation units + 6 link units emitted (100%). `--clean-first`
forces a full recompile so capture sees every translation unit; `--emit-link-units` is
required for skip_build.

Verify **offline** before any server contact:
```
dir  C:\capture\idir\build-log.txt          # marker the tool keys on
cov-manage-emit --dir C:\capture\idir list  # should list your real .c files
```

### Stage 2 — Scan + upload with blackduck-c-cpp
`config.yaml` (default parser: `key: value`, `True/False`, unquoted values):
```yaml
skip_build: True
coverity_root: C:\Coverity\cov-analysis-win64-2026.3.0
cov_output_dir: C:\capture\idir
build_dir: C:\path\to\curl-8.4.0
output_dir: C:\capture\bdcpp-output
project_name: curl
project_version: 8.4.0
bd_url: https://sca.example.blackduck.com/
api_token: <token, or use BLACKDUCK_API_TOKEN env var>
modes: sig,bdba
verbose: True
```
```
blackduck-c-cpp --config config.yaml
```
Every phase reported `SUCCESS` (Cov Manage Emit → Cov-emit-link → BDBA → BD Signature
Scan). The server BOM then showed `curl 8.4.0`, `policyStatus=IN_VIOLATION`.

For the **vanilla** flavor, drop `skip_build`/`cov_output_dir`, add a `build_cmd`, and
let the tool capture — see [run-blackduck-c-cpp](../skills/run-blackduck-c-cpp/SKILL.md).

### Stage 3 — Convert the BOM to SARIF
```
python blackduckResultsToSarif.py `
  --url https://sca.example.blackduck.com `   # NO trailing slash
  --token <token> --project curl --version 8.4.0 `
  --policyCategories SECURITY --outputFile C:\out\curl-8.4.0.sarif.json --log_level INFO
```
Result: a valid SARIF 2.1.0 file with **36 results / 36 rules**, matching the Black
Duck UI's default vulnerability view for curl 8.4.0 exactly.

## Lessons learned (the reason these skills exist)

1. **`bd_url` trailing slash breaks the SARIF formatter (but not the scanner).**
   `blackduck-c-cpp` strips the slash; the formatter's `HubInstance` concatenates
   `baseurl + "/api/tokens/authenticate"` and a trailing slash produces a `//` path that
   some servers (behind Cloudflare) answer with **HTTP 400** — surfacing as a baffling
   `KeyError: 'x-csrf-token'`. Always pass the formatter a URL with no trailing slash.

2. **The SARIF formatter only reports policy-violating components.** It filters the BOM
   by `policyCategory` (default `SECURITY`). No matching policy violation → empty SARIF,
   even with a full BOM. Ensure the project has a policy that flags the components.

3. **Clean builds are mandatory for capture.** Coverity only records compilations that
   execute. A pre-built tree captures nothing and yields an empty BOM.

4. **Python 3.14 is fine.** `blackduck-c-cpp` 3.0.6 and its native deps ship `cp314`
   wheels; no downgrade needed.

5. **SARIF locations for C/C++ scans point to `sig_scan.zip`**, not to source files —
   inherent to the signature-scan path. Set expectations if the SARIF feeds GitHub code
   scanning and someone expects file/line annotations.

6. **Decompose to isolate failures.** Build the target alone (Stage 0), verify the
   Coverity capture offline (Stage 1) before any upload. Each checkpoint makes the next
   failure unambiguous.
