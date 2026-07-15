# configure-blackduck-compilers

Docs and a Claude Code skill for resolving "unconfigured compiler" warnings from the [`blackduck-c-cpp`](https://pypi.org/project/blackduck-c-cpp/) scan tool.

When `blackduck-c-cpp` encounters a compiler it doesn't recognize, it writes the executable path to `<idir>/scan-transparency/unconfigured-compilers` and continues — a subtle warning that's easy to miss. If it's missed, the scan appears successful but the affected code is silently absent from Black Duck's analysis. This repo contains two ways to fix that:

- **[CONFIGURE_COMPILERS.md](CONFIGURE_COMPILERS.md)** — step-by-step human walkthrough with worked examples, troubleshooting, and reference tables.
- **[skill/configure-blackduck-compilers/](skill/configure-blackduck-compilers/)** — a Claude Code skill that automates the same process. Drop it into `~/.claude/skills/` (user-scoped) or `.claude/skills/` (project-scoped) and invoke by asking Claude about `blackduck-c-cpp`, `unconfigured compilers`, or `cov_configure_args`.

## Quick start

1. Read [CONFIGURE_COMPILERS.md](CONFIGURE_COMPILERS.md) once so you understand the shape of the problem.
2. If you have Claude Code, copy `skill/configure-blackduck-compilers/` into your skills directory and let the skill drive the loop.
3. Otherwise follow the six numbered steps in the doc by hand.

## What's in `skill/configure-blackduck-compilers/`

- `SKILL.md` — trigger conditions, algorithm, and edit rules Claude follows.
- `references/compile-types.txt` — bundled snapshot of `cov-configure --list-compiler-types` used when Coverity isn't on `PATH`. Refresh this when your Coverity install upgrades.

## Sample artifacts

- [`documentation_example.yaml`](documentation_example.yaml) — a minimal `blackduck-c-cpp` YAML config, from upstream docs.
- [`format-sample.yaml.partial`](format-sample.yaml.partial) — one-line example of a `cov_configure_args` entry showing the expected flow syntax.
- [`compile-types.txt`](compile-types.txt) — full unfiltered `cov-configure --list-compiler-types` output at the top level for easy browsing/grep.

## License

TBD.
