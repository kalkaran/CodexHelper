# Codex Helper

Two-part bootstrap for setting up a token-efficient Codex coding workflow in a repository for MacOS

## Files

- `part1.sh` - main Codex workflow bootstrap. Creates repo guidance, `agent/`, `codebase-wiki/`, Codex hook templates, verification scripts, and the `wiki-ai` workflow.
- `part2.sh` - quality tooling bootstrap. Installs/wires available formatters, linters, typecheckers, security checks, AI-capped `*-ai` targets, and `edited-ai`.

## Recommended Install Flow

From the repository you want to configure, preview the repo-only setup first:

```sh
bash /path/to/CodexHelper/part1.sh --dry-run --repo-only --no-apply-codex-config
```

If the preview looks right, run it:

```sh
bash /path/to/CodexHelper/part1.sh --repo-only --no-apply-codex-config
```

If you are refreshing an existing Codex Helper setup and want generated files overwritten after backups are made, add `--force`:

```sh
bash /path/to/CodexHelper/part1.sh --repo-only --force --no-apply-codex-config
```

Then preview the quality tooling setup:

```sh
bash /path/to/CodexHelper/part2.sh --dry-run --wire --fix
```

If the preview looks right:

```sh
bash /path/to/CodexHelper/part2.sh --wire --fix
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
- Full tool logs are stored under `.cache/`; AI-facing output is capped.
- Review generated `codebase-wiki/` sections before relying on them as durable project memory.
