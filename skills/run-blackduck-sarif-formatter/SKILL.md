---
name: run-blackduck-sarif-formatter
description: Convert a Black Duck SCA project-version's findings into a SARIF 2.1.0 report using the community blackduck-sarif-formatter (blackduckResultsToSarif.py). Use after a Black Duck scan (e.g. from blackduck-c-cpp) when a user wants SARIF output, mentions blackduck-sarif-formatter, blackduckResultsToSarif, uploading Black Duck results to GitHub code scanning, or "convert Black Duck BOM to SARIF". Knows the two failure modes that bite everyone: a trailing slash in the URL (causes a cryptic x-csrf-token KeyError) and the fact that the formatter only reports components that violate a policy.
---

# Run blackduck-sarif-formatter

The community tool [blackduck-community/blackduck-sarif-formatter](https://github.com/blackduck-community/blackduck-sarif-formatter) reads a Black Duck project-version over the REST API and emits a **SARIF 2.1.0** report (e.g. for GitHub code scanning). It ships two scripts:

- **`blackduckResultsToSarif.py`** — for **full/intelligent** scans (this is what a `blackduck-c-cpp` scan produces). Reads the BOM from the server.
- **`blackduckRapidResultsToSarif.py`** — for **rapid** scans; reads a local Detect scan-output JSON instead of the server BOM.

This skill covers the full-scan script, which is the pairing for [run-blackduck-c-cpp](../run-blackduck-c-cpp/SKILL.md).

## Two things that will bite you (read first)

1. **The `--url` must NOT have a trailing slash.** The tool authenticates via the `hub-rest-api-python` `HubInstance`, which builds `baseurl + "/api/tokens/authenticate"` with a naive string concat. A trailing slash yields `https://host//api/tokens/authenticate`; some servers (notably behind Cloudflare) return **HTTP 400** for the double slash, so no `X-CSRF-TOKEN` header comes back and the tool dies with the misleading:
   ```
   KeyError: 'x-csrf-token'
   ```
   Pass `--url https://host` (no trailing slash). Note this is the opposite tolerance from `blackduck-c-cpp`, which strips the slash for you — so a `bd_url` that worked for the scan will break the formatter if copied verbatim with its slash.

2. **The formatter is policy-violation-driven, not BOM-driven.** It filters components with `filter=policyCategory:<category>` (from `--policyCategories`, **default `SECURITY`**). Only components that **violate a policy** in that category reach the SARIF; each such component then contributes all its vulnerabilities. If the project has no matching policy violations, you get a **valid but empty** SARIF no matter how many vulnerabilities are in the BOM. Make sure the Black Duck project has a policy that flags the components (most instances ship a default security policy), or the report will be empty.

## When to invoke

Trigger when the user wants SARIF from Black Duck, mentions the formatter/script by name, or wants to upload Black Duck SCA results to GitHub code scanning. Typically runs right after [run-blackduck-c-cpp](../run-blackduck-c-cpp/SKILL.md).

Do **not** invoke to *run* a scan (that's the c-cpp skills) or for rapid-scan output unless you switch to `blackduckRapidResultsToSarif.py` with a `--scanOutputPath`.

## Inputs you need

1. **Black Duck URL** — **without** a trailing slash.
2. **API token** — passed as `--token`. It becomes a process argument; read it from a file into a variable rather than pasting it literally (see the wrapper in `references/`).
3. **Project name and version** — must match what the scan created exactly.
4. **Output path** — `--outputFile`; if omitted the SARIF is printed to stdout.

## Process

### Phase 1 — Get the tool and its deps

```bash
git clone https://github.com/blackduck-community/blackduck-sarif-formatter.git
```
Install deps into a Python environment (the scripts import `blackduck` (hub-rest-api-python) and `requests`; the repo has no `requirements.txt`, matching its GitHub Action which just does `pip install blackduck requests`):
```bash
pip install blackduck requests
```
Requires **Python 3.10+** (the code uses `match`/`case`). If you already have a `blackduck-c-cpp` venv, it satisfies these imports too.

### Phase 2 — Run the formatter

```bash
python blackduckResultsToSarif.py \
  --url https://sca.example.blackduck.com \          # NO trailing slash
  --token "$BD_TOKEN" \
  --project myproject \
  --version 1.0.0 \
  --policyCategories SECURITY \                       # add LICENSE to include license policy violations
  --outputFile ./myproject.sarif.json \
  --log_level INFO
```
Run it from a **small/empty working directory**: when a component has no signature-matched files, the tool falls back to walking the *current directory* for package-manager manifests, and it writes a `.restconfig.json` in cwd. Don't run it from a huge tree.

Expect it to take a while on large BOMs: for every NVD vulnerability it makes an external **EPSS** call to `api.first.org`, plus several Black Duck API calls per component/vulnerability.

### Phase 3 — Validate the SARIF

- It's valid JSON with `"version": "2.1.0"` and a `runs[0].tool.driver` + `runs[0].results`.
- The **result count should match the project-version's vulnerability count in the Black Duck UI's default view.** (In practice the `policyCategory` filter lines up with that view.) If you get 0 results but the UI shows vulnerabilities, re-check the two gotchas above — almost always the trailing slash or a missing policy.

## Key facts and gotchas

- **URL trailing slash → `KeyError: 'x-csrf-token'`.** See the top of this file. First thing to check on any auth-time failure.
- **Empty SARIF despite a full BOM → policy.** The `policyCategory` filter. Add categories via `--policyCategories SECURITY,LICENSE`, and set `--policies true` to attach policy detail / include LICENSE-type policy violations as results.
- **CLI default `--policyCategories` is `SECURITY` only**, whereas the repo's GitHub Action defaults to `SECURITY,LICENSE`. Pass it explicitly to avoid surprises.
- **Rule IDs are Black Duck advisory names (BDSA-…), not CVE IDs.** A specific CVE appears inside a rule's description / related-vulnerability links, not as the rule `id`. Don't grep for `CVE-…` in rule ids and conclude it's missing.
- **Locations for `blackduck-c-cpp` scans point to `sig_scan.zip`.** Signature matches resolve to the scan archive the tool uploaded, not to source files/lines. So GitHub code-scanning annotations land on `sig_scan.zip:1`, not on real source. That's inherent to the signature-scan path, not a formatter bug — mention it if the user expects file/line annotations.
- **External EPSS dependency.** `api.first.org` is called per NVD vuln with TLS verification disabled. Needs outbound internet; a first.org outage slows/º degrades the run.
- **Token is a process argument.** Prefer the wrapper that reads it from a file into a variable so it never appears literally in a command you type or log.
- **Full vs rapid.** `blackduck-c-cpp` produces a full/intelligent scan → use `blackduckResultsToSarif.py`. For rapid scans use `blackduckRapidResultsToSarif.py --scanOutputPath <dir>` and run Detect with `--detect.scan.output.path` + `--detect.cleanup=false`.

## Bundled resources

- `references/run-formatter.ps1` — a Windows wrapper that reads `bd_url`/`api_token` from a `blackduck-c-cpp` config.yaml, **strips the trailing slash**, and invokes the formatter with the token in a variable.
