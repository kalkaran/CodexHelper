# Codex Helper

Two-part bootstrap for setting up a token-efficient Codex coding workflow in a repository.
Use `MacOS/` on macOS and `WSL/` inside Ubuntu WSL.

## Files

- `MacOS/part1.sh` - macOS Codex workflow bootstrap. Creates repo guidance, `agent/`, `codebase-wiki/`, Codex hook templates, verification scripts, and the `wiki-ai` workflow.
- `MacOS/part2.sh` - macOS quality tooling bootstrap. Installs/wires available formatters, linters, typecheckers, security checks, AI-capped `*-ai` targets, and `edited-ai`.
- `WSL/part1.sh` - Ubuntu WSL Codex workflow bootstrap. Uses `apt-get`, `.bashrc`, Ubuntu certificate paths, and isolated `uv`/`pipx` tool installs.
- `WSL/part2.sh` - Ubuntu WSL quality tooling bootstrap. Installs/wires available formatters, linters, typecheckers, security checks, AI-capped `*-ai` targets, and `edited-ai`.

## macOS Install Flow

From the repository you want to configure, preview the repo-only setup first:

```sh
bash /path/to/CodexHelper/MacOS/part1.sh --dry-run --repo-only --no-apply-codex-config
```

If the preview looks right, run it:

```sh
bash /path/to/CodexHelper/MacOS/part1.sh --repo-only --no-apply-codex-config
```

If you are refreshing an existing setup and want generated files overwritten after backups are made, add `--force`:

```sh
bash /path/to/CodexHelper/MacOS/part1.sh --repo-only --force --no-apply-codex-config
```

Then preview and run the quality tooling setup:

```sh
bash /path/to/CodexHelper/MacOS/part2.sh --dry-run --wire --fix
bash /path/to/CodexHelper/MacOS/part2.sh --wire --fix
```

## Ubuntu WSL Install Flow

Run these commands inside Ubuntu WSL, from the repository you want to configure.

Preview the repo-only setup first:

```sh
bash /path/to/CodexHelper/WSL/part1.sh --dry-run --repo-only --no-apply-codex-config
```

If the preview looks right, run it:

```sh
bash /path/to/CodexHelper/WSL/part1.sh --repo-only --no-apply-codex-config
```

If Ubuntu WSL is missing base tools and you want the bootstrap to install them with `apt-get`, use:

```sh
bash /path/to/CodexHelper/WSL/part1.sh --install-prereqs
```

Then preview and run the quality tooling setup:

```sh
bash /path/to/CodexHelper/WSL/part2.sh --dry-run --wire --fix
bash /path/to/CodexHelper/WSL/part2.sh --wire --fix
```

## After Install

Run the AI-safe checks and populate repo memory:

```sh
make edited-ai
make verify-ai
make wiki-ai
```

Restart Codex in the repo root so it reloads `AGENTS.md`. If project hooks were created, open `/hooks` in Codex CLI, review/trust the hooks, then start a new thread.

## What This Sets Up

- AI-capped linter/typechecker/security output so tools do not flood the Codex transcript.
- Edited-file checks that format first, then lint and typecheck only changed files.
- Optional Codex hooks that run edited-file checks after file edits and before Codex stops.
- `codebase-wiki/` repo memory generated from durable repo guidance and Graphify output.
- `AGENTS.md` and `agent/` instructions so Codex uses the workflow consistently.

## Notes

- `part1.sh` does not auto-trust Codex hooks. Trust them manually with `/hooks`.
- `part2.sh` only wires checks for tools that are actually available.
- The WSL scripts are intended for Ubuntu WSL, not every Linux distro.
- Full tool logs are stored under `.cache/`; AI-facing output is capped.
- Review generated `codebase-wiki/` sections before relying on them as durable project memory.
