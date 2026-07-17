# Codex Helper

Codex Helper adds a small AI coding workflow to another repo.

Use `MacOS/` on macOS. Use `WSL/` inside Ubuntu WSL.

It helps Codex:

- read the right project instructions
- check files it edits
- keep long tool output short
- save useful repo knowledge in `codebase-wiki/`

## What The Parts Do

- `part1.sh` adds Codex instructions, hooks, repo memory files, helper scripts, and prerequisite package-manager checks.
- `part2.sh` detects what is in the repo, asks before installing matching quality tools, then creates Makefile commands for checks.
- `MacOS/` is for macOS.
- `WSL/` is for Ubuntu WSL.

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

For a fresh repo bootstrap refresh that also checks/installs `uv` and `pipx`, use `--fresh-install`:

```sh
bash /path/to/CodexHelper/MacOS/part1.sh --repo-only --fresh-install --no-apply-codex-config
```

If your network requires an internal Python package mirror for prerequisite Python tooling, pass it to `part1.sh`:

```sh
bash /path/to/CodexHelper/MacOS/part1.sh --repo-only --fresh-install --python-index-url=https://your-python-mirror.example.com/simple --no-apply-codex-config
```

To opt into Impeccable for frontend design work in Codex, run `part1.sh` with `--impeccable`, then restart Codex and approve the Impeccable hook in `/hooks`:

```sh
bash /path/to/CodexHelper/MacOS/part1.sh --repo-only --impeccable --no-apply-codex-config
```

Then preview and run the quality tooling setup:

```sh
bash /path/to/CodexHelper/MacOS/part2.sh --dry-run --fresh-install
bash /path/to/CodexHelper/MacOS/part2.sh --fresh-install
```

If your network requires an internal Python package mirror for quality-tool installs, pass it to `part2.sh`:

```sh
bash /path/to/CodexHelper/MacOS/part2.sh --fresh-install --python-index-url https://your-python-mirror.example.com/simple
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

For a fresh repo bootstrap refresh that also checks/installs `uv` and `pipx`, use `--fresh-install`:

```sh
bash /path/to/CodexHelper/WSL/part1.sh --repo-only --fresh-install --no-apply-codex-config
```

If your network requires an internal Python package mirror for prerequisite Python tooling, pass it to `part1.sh`:

```sh
bash /path/to/CodexHelper/WSL/part1.sh --repo-only --fresh-install --python-index-url=https://your-python-mirror.example.com/simple --no-apply-codex-config
```

To opt into Impeccable for frontend design work in Codex, run `part1.sh` with `--impeccable`, then restart Codex and approve the Impeccable hook in `/hooks`:

```sh
bash /path/to/CodexHelper/WSL/part1.sh --repo-only --impeccable --no-apply-codex-config
```

Then preview and run the quality tooling setup:

```sh
bash /path/to/CodexHelper/WSL/part2.sh --dry-run --fresh-install
bash /path/to/CodexHelper/WSL/part2.sh --fresh-install
```

If your network requires an internal Python package mirror for quality-tool installs, pass it to `part2.sh`:

```sh
bash /path/to/CodexHelper/WSL/part2.sh --fresh-install --python-index-url https://your-python-mirror.example.com/simple
```

## After Install

Restart Codex in the repo root so it reloads `AGENTS.md`. If project hooks were created, open `/hooks` in Codex CLI, review/trust the hooks, then start a new thread.

Run one manual check after setup to confirm the generated checker works:

```sh
make edited-ai
```

After that, trusted hooks handle normal edited-file checks automatically.

## Using The Workflow

Once hooks are trusted, Codex checks edited files automatically after edits and before it stops. The hooks do not literally run `make edited-ai`; they call the same underlying checker, `vibe_scripts/agent-check-edited.py`, for the files Codex edited.

You normally do not need to run `make edited-ai` after every small change.

What still has to be done manually:

- Trust project hooks in `/hooks` after install or after hook files change.
- Run `make edited-ai` once after setup, when hooks are not trusted, or when you want an explicit quick check.
- Run `make lint-ai` when you want broader non-Semgrep lint checks.
- Run `make verify-ai` for large, risky, security-sensitive, or cross-project changes.
- Run `make wiki-ai` only when stable project knowledge should be written to `codebase-wiki/`.
- Review generated `codebase-wiki/` changes before relying on them.

What the hooks do:

- `pre_tool_use_policy.py` runs before Codex shell commands. It blocks Git-writing commands and a few destructive shell commands when configured.
- `post_tool_use.py` runs after tools. It is a placeholder for future logging or checks and does not block anything today.
- `post_edit_check.py` runs after Codex edit tools. It checks the edited paths and records them for the stop hook.
- `stop_edited_check.py` runs before Codex stops. It rechecks recorded edited files and blocks stopping if the edited-file check fails.

Use these commands when needed:

- `make edited-ai` checks only edited files. Use it after setup, when hooks are not trusted, or when you want a quick manual check.
- `make lint-ai` runs broader lint checks without Semgrep.
- `make verify-ai` runs bigger checks. Use it for large, risky, security-sensitive, or cross-project changes. It may run Semgrep.
- `make wiki-ai` updates `codebase-wiki/`. Use it only when you learned stable facts that future agents should know.
- `./vibe_scripts/agent-verify.sh` runs the edited-file check by default. Pass `lint`, `verify`, `security`, or `graph` to choose another mode.

Semgrep can be verbose. It is not automatic. It runs only when you ask for security or verify checks, or when you start `part1.sh` with `--security-scan`.

Review generated `codebase-wiki/` changes before treating them as durable project memory.

## What This Sets Up

- Short output for AI checks, with full logs in `.cache/`.
- Checks for files Codex edited.
- Optional Codex hooks that run those edited-file checks automatically.
- `AGENTS.md` and `agent/` instructions for future Codex sessions.
- Optional Impeccable integration tells Codex to use `$impeccable` for frontend design creation, polish, audit, critique, responsive, typography, color, and design-system tasks when the skill is installed.
- Frontend edits automatically trigger the generated design touch gate in `agent/coding-rules.md`; the edited-file checker also runs `impeccable detect` on touched frontend files when Impeccable is already available locally.
- `codebase-wiki/` for stable project knowledge.

## Notes

- `part1.sh` does not auto-trust Codex hooks. Trust them manually with `/hooks`.
- `part2.sh` only wires checks for tools that are actually available.
- Semgrep is wired as an explicit security check, not as an automatic hook.
- The WSL scripts are intended for Ubuntu WSL, not every Linux distro.
- Full tool logs are stored under `.cache/`; AI-facing output is capped.
- Review generated `codebase-wiki/` sections before relying on them as durable project memory.
