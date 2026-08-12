# Black Duck C/C++ skills

A collection of skills for scanning C/C++ projects with Black Duck SCA and turning the
results into SARIF. Each skill is a self-contained directory under `skills/` with its own
`SKILL.md` and bundled resources.

## Skills

| Skill | What it does |
|-------|--------------|
| [`skills/run-blackduck-c-cpp`](skills/run-blackduck-c-cpp/SKILL.md) | **Default scan.** Run `blackduck-c-cpp` and let it drive the Coverity build capture, then upload signature + binary (BDBA) results to Black Duck. |
| [`skills/run-blackduck-c-cpp-skip-build`](skills/run-blackduck-c-cpp-skip-build/SKILL.md) | **Advanced/debug.** Reuse a Coverity `idir` you captured yourself (`skip_build`). Requires local Coverity binaries. Good for verifying capture offline or re-scanning without rebuilding. |
| [`skills/run-blackduck-sarif-formatter`](skills/run-blackduck-sarif-formatter/SKILL.md) | Convert a Black Duck project-version's findings to SARIF 2.1.0. Knows the trailing-slash URL gotcha and the policy-violation filter. |
| [`skills/configure-blackduck-compilers`](skills/configure-blackduck-compilers/SKILL.md) | Fix "unconfigured compiler" warnings by mapping compiler executables to Coverity compiler types via `cov_configure_args`. |

## Documentation

- [`docs/blackduck-c-cpp-to-sarif-workflow.md`](docs/blackduck-c-cpp-to-sarif-workflow.md) — human-readable end-to-end runbook (build → capture → scan → BOM → SARIF), with a worked example and the lessons the skills encode.

## Typical flow

1. Build your C/C++ project and scan it — [`run-blackduck-c-cpp`](skills/run-blackduck-c-cpp/SKILL.md) (or the `skip_build` variant for manual capture control).
2. If the scan warns about unconfigured compilers — [`configure-blackduck-compilers`](skills/configure-blackduck-compilers/SKILL.md), then re-scan.
3. Convert the resulting Black Duck BOM to SARIF — [`run-blackduck-sarif-formatter`](skills/run-blackduck-sarif-formatter/SKILL.md).
