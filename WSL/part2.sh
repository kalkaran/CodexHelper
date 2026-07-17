#!/usr/bin/env bash
set -euo pipefail

# part2.sh
# Quality gate setup for AI coding workflows on Ubuntu WSL.
# It detects likely repo types, offers to install missing dev quality tools,
# then wires Makefile targets for tools/scripts that exist.

DRY_RUN=0
YES=0
WIRE_MODE="ask"    # ask | yes | no
INSTALL_MODE="ask" # ask | yes | no
FIX_MODE="ask"     # ask | yes | no
FRESH_INSTALL=0
REPO_ROOT=""
PYTHON_INDEX_URL="${UV_DEFAULT_INDEX:-${PIP_INDEX_URL:-}}"

log() { printf '[ai-quality] %s\n' "$*"; }
warn() { printf '[warn] %s\n' "$*" >&2; }
err() { printf '[error] %s\n' "$*" >&2; }

usage() {
	cat <<'USAGE'
Usage: part2.sh [options]

Options:
  --dry-run          Show what would happen without writing files.
  --yes              Non-interactive defaults. Continues with available checks.
  --fresh-install    Fresh quality setup: install missing tools, wire Makefile, run safe fixes.
  --install          Install missing recommended quality tools without prompting.
  --no-install       Do not install tools; recommendations/wiring only.
  --wire             Write/update Makefile using only currently available checks.
  --no-wire          Do not write Makefile; recommendations only.
  --fix              Run safe automatic format/fix commands after wiring.
  --no-fix           Do not run automatic format/fix commands.
  --python-index-url URL
                     Use a Python package mirror for uv/pipx installs.
  --repo PATH        Run against a specific repo/path.
  -h, --help         Show this help.

Design:
  - Prompts before installing missing dev quality tools unless --yes/--install is used.
  - --fresh-install is equivalent to --install --wire --fix; existing Makefile is backed up.
  - Refreshes tool detection after installation before wiring checks.
  - Prompts to run safe automatic fixers after wiring unless --no-fix is used.
  - Keeps installs scoped to dev tooling.
  - Creates Makefile targets only for checks that actually exist.
  - Creates AI-capped *-ai targets that write full logs under .cache/ai-quality/.
  - Creates edited-ai to format, lint, and typecheck only edited files.
  - Preserves/adds wiki-ai when scripts/update-codebase-wiki.py exists.
  - Never creates fake lint/typecheck/test targets.
USAGE
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--dry-run)
		DRY_RUN=1
		shift
		;;
	--yes)
		YES=1
		shift
		;;
	--fresh-install)
		FRESH_INSTALL=1
		INSTALL_MODE="yes"
		WIRE_MODE="yes"
		FIX_MODE="yes"
		shift
		;;
	--install)
		INSTALL_MODE="yes"
		shift
		;;
	--no-install)
		INSTALL_MODE="no"
		shift
		;;
	--wire)
		WIRE_MODE="yes"
		shift
		;;
	--no-wire)
		WIRE_MODE="no"
		shift
		;;
	--fix)
		FIX_MODE="yes"
		shift
		;;
	--no-fix)
		FIX_MODE="no"
		shift
		;;
	--python-index-url)
		PYTHON_INDEX_URL="${2:-}"
		if [[ -z "$PYTHON_INDEX_URL" ]]; then
			err "--python-index-url requires a URL"
			exit 2
		fi
		shift 2
		;;
	--python-index-url=*)
		PYTHON_INDEX_URL="${1#*=}"
		shift
		;;
	--repo)
		REPO_ROOT="${2:-}"
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		err "Unknown option: $1"
		usage
		exit 2
		;;
	esac
done

ask_yn() {
	local prompt="$1"
	local default="${2:-n}" # y or n
	if [[ "$YES" -eq 1 ]]; then
		if [[ "$default" == "y" ]]; then return 0; else return 1; fi
	fi
	local suffix="[y/N]"
	[[ "$default" == "y" ]] && suffix="[Y/n]"
	local reply
	printf '%s %s ' "$prompt" "$suffix"
	read -r reply || reply=""
	reply="${reply:-$default}"
	[[ "$reply" =~ ^[Yy]$ ]]
}

find_repo_root() {
	if [[ -n "$REPO_ROOT" ]]; then
		cd "$REPO_ROOT"
	fi
	if command -v git >/dev/null 2>&1 && git rev-parse --show-toplevel >/dev/null 2>&1; then
		git rev-parse --show-toplevel
	else
		pwd
	fi
}

ROOT="$(find_repo_root)"
cd "$ROOT"
log "Working in: $ROOT"
[[ "$DRY_RUN" -eq 1 ]] && warn "Dry run: no files will be written."
[[ "$FRESH_INSTALL" -eq 1 ]] && log "Fresh quality setup enabled: install missing tools, wire Makefile, run safe fixes."
if [[ -n "$PYTHON_INDEX_URL" ]]; then
	export UV_DEFAULT_INDEX="$PYTHON_INDEX_URL"
	export PIP_INDEX_URL="$PYTHON_INDEX_URL"
	log "Using configured Python package index mirror for uv/pipx installs."
fi

has_file() { [[ -f "$1" ]]; }
cmd_exists() { command -v "$1" >/dev/null 2>&1; }

resolve_package_manager() {
	command -v apt-get
}

cmd_package_manager() { resolve_package_manager >/dev/null 2>&1; }

ensure_user_tool_path() {
	local dir="${UV_TOOL_BIN_DIR:-$HOME/.local/bin}"
	case ":$PATH:" in
	*":$dir:"*) ;;
	*) export PATH="$dir:$PATH" ;;
	esac
}

sudo_prefix() {
	if [[ "$(id -u)" -eq 0 ]]; then
		return 0
	fi
	if cmd_exists sudo; then
		printf '%s\n' sudo
		return 0
	fi
	warn "sudo is required for system package installs when not running as root."
	return 1
}

run_package_manager_install() {
	local manager_path sudo_cmd
	manager_path="$(resolve_package_manager 2>/dev/null || true)"
	if [[ -z "$manager_path" ]]; then
		warn "apt-get was not found. This quality bootstrap supports Ubuntu WSL."
		return 127
	fi
	sudo_cmd="$(sudo_prefix || true)"
	if [[ "$(id -u)" -ne 0 && -z "$sudo_cmd" ]]; then
		return 1
	fi

	run_install "package index" ${sudo_cmd:+"$sudo_cmd"} "$manager_path" update
	run_install "system packages" ${sudo_cmd:+"$sudo_cmd"} "$manager_path" install -y "$@"
}

ensure_pipx() {
	if cmd_exists pipx; then
		return 0
	fi
	if ! cmd_package_manager; then
		warn "pipx is missing and apt-get is not available."
		return 1
	fi
	if should_install "pipx is missing. Install pipx with apt-get?"; then
		run_package_manager_install pipx || return 1
		if cmd_exists pipx; then
			run_install "pipx ensurepath" pipx ensurepath || true
			ensure_user_tool_path
		fi
	fi
	cmd_exists pipx
}

semgrep_cert_file() {
	if [[ -n "${SSL_CERT_FILE:-}" && -r "${SSL_CERT_FILE:-}" ]]; then
		printf '%s\n' "$SSL_CERT_FILE"
		return 0
	fi

	local candidate
	for candidate in \
		"/etc/ssl/certs/ca-certificates.crt" \
		"/etc/ssl/cert.pem"; do
		if [[ -r "$candidate" ]]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done

	return 1
}
semgrep_cmd() {
	local cert
	cert="$(semgrep_cert_file 2>/dev/null || true)"
	printf 'mkdir -p .cache/semgrep && '
	if [[ -n "$cert" ]]; then
		printf 'SSL_CERT_FILE=%q ' "$cert"
	else
		true
	fi
	printf 'SEMGREP_LOG_FILE=.cache/semgrep/semgrep.log SEMGREP_SETTINGS_FILE=.cache/semgrep/settings.yml SEMGREP_VERSION_CACHE_PATH=.cache/semgrep/version-cache semgrep'
}

run_semgrep_cli() {
	local state_dir=".cache/semgrep"
	if [[ "$DRY_RUN" -eq 1 ]]; then
		state_dir="${TMPDIR:-/tmp}/ai-quality-semgrep-$$"
	fi
	mkdir -p "$state_dir"

	local cert
	cert="$(semgrep_cert_file 2>/dev/null || true)"
	if [[ -n "$cert" ]]; then
		SSL_CERT_FILE="$cert" \
			SEMGREP_LOG_FILE="$state_dir/semgrep.log" \
			SEMGREP_SETTINGS_FILE="$state_dir/settings.yml" \
			SEMGREP_VERSION_CACHE_PATH="$state_dir/version-cache" \
			semgrep "$@"
	else
		SEMGREP_LOG_FILE="$state_dir/semgrep.log" \
			SEMGREP_SETTINGS_FILE="$state_dir/settings.yml" \
			SEMGREP_VERSION_CACHE_PATH="$state_dir/version-cache" \
			semgrep "$@"
	fi
}

cmd_works() {
	local cmd="$1"
	command -v "$cmd" >/dev/null 2>&1 || return 1
	if [[ "$cmd" == "semgrep" ]]; then
		return 0
	fi
	"$cmd" --version >/dev/null 2>&1
}

UV_TOOL_BIN_DIR="${UV_TOOL_BIN_DIR:-$HOME/.local/bin}"
if [[ -d "$UV_TOOL_BIN_DIR" ]]; then
	ensure_user_tool_path
fi

has_any() {
	local match
	match="$(find . -maxdepth 4 \
		\( -name '.git' \
		-o -name 'node_modules' \
		-o -name 'vendor' \
		-o -name 'dist' \
		-o -name 'build' \
		-o -name 'coverage' \
		-o -name '.cache' \
		-o -name '.venv' \
		-o -name 'obsidian' \) -prune \
		-o "$@" -print -quit 2>/dev/null)"
	[[ -n "$match" ]]
}

local_bin_exists() {
	[[ -x "node_modules/.bin/$1" ]]
}

has_biome_config() {
	[[ -f biome.json || -f biome.jsonc ]]
}

should_install() {
	local prompt="$1"
	if [[ "$INSTALL_MODE" == "no" ]]; then
		return 1
	fi
	if [[ "$INSTALL_MODE" == "yes" || "$YES" -eq 1 ]]; then
		return 0
	fi
	ask_yn "$prompt" "y"
}

run_install() {
	local label="$1"
	shift
	printf '+'
	local arg
	for arg in "$@"; do printf ' %q' "$arg"; done
	printf '\n'
	if [[ "$DRY_RUN" -eq 1 ]]; then
		log "Would install: $label"
		return 0
	fi
	"$@"
}

warn_python_index_unreachable() {
	warn "$1 install failed. If uv timed out fetching pypi.org, WSL cannot reach PyPI."
	warn "Check network/proxy access with: curl -I https://pypi.org/simple/ruff/"
	warn "If you use a corporate proxy, set HTTPS_PROXY and HTTP_PROXY, then retry."
	warn "If your org uses an internal Python package mirror, set UV_DEFAULT_INDEX to that /simple URL."
}

install_missing_quality_tools() {
	if [[ "$INSTALL_MODE" == "no" ]]; then
		log "Tool installation disabled (--no-install)."
		return 0
	fi

	if [[ "$PYTHON" -eq 1 ]] && ! cmd_exists ruff; then
		if cmd_exists uv && should_install "Install Ruff with uv?"; then
			run_install "Ruff" uv tool install ruff || warn_python_index_unreachable "Ruff"
			ensure_user_tool_path
		else
			warn "ruff missing; run: export PATH=\"\$HOME/.local/bin:\$PATH\"; uv tool install ruff"
		fi
	fi

	local need_node_tools=0
	if [[ "$STATIC_WEB" -eq 1 || "$NODE_PKG" -eq 1 || "$TS" -eq 1 ]]; then
		if ! local_bin_exists biome || ! local_bin_exists htmlhint; then
			need_node_tools=1
		fi
	fi

	if [[ "$need_node_tools" -eq 1 ]]; then
		if ! cmd_exists npm; then
			warn "npm is missing; cannot install Biome/HTMLHint automatically."
		elif should_install "Install JavaScript/CSS/HTML quality tools with npm?"; then
			if [[ ! -f package.json ]]; then
				run_install "package.json" npm init -y || warn "npm init failed."
			fi
			run_install "Biome and HTMLHint" npm install --save-dev --save-exact @biomejs/biome htmlhint || warn "npm quality tool install failed."
		fi
	fi

	if [[ "$PHP_LANG" -eq 1 ]]; then
		if ! cmd_exists composer; then
			if cmd_package_manager && should_install "Composer is missing. Install Composer with apt-get?"; then
				run_package_manager_install composer || warn "Composer install failed."
			else
				warn "composer is missing; cannot install PHPCS/PHPStan automatically."
			fi
		fi

		if cmd_exists composer && { [[ ! -x vendor/bin/phpcs ]] || [[ ! -x vendor/bin/phpstan ]]; }; then
			if should_install "Install PHP_CodeSniffer and PHPStan with Composer?"; then
				run_install "PHPCS and PHPStan" composer require --dev squizlabs/php_codesniffer phpstan/phpstan || warn "Composer quality tool install failed."
			fi
		fi
	fi

	if [[ "$SHELL_LANG" -eq 1 ]]; then
		if ! cmd_exists shellcheck || ! cmd_exists shfmt; then
			if cmd_package_manager && should_install "Install ShellCheck and shfmt with apt-get?"; then
				run_package_manager_install shellcheck shfmt || warn "Shell tool install failed."
			else
				warn "shellcheck/shfmt missing and apt-get install unavailable or skipped."
			fi
		fi
	fi

	if ! cmd_exists semgrep; then
		if ensure_pipx && should_install "Install Semgrep with pipx?"; then
			run_install "Semgrep" pipx install semgrep || warn "Semgrep install failed."
			ensure_user_tool_path
		else
			warn "semgrep missing and pipx install unavailable or skipped."
		fi
	fi
}

# Language/project detection
detect_file_signals() {
	PYTHON=0
	NODE_PKG=0
	STATIC_WEB=0
	PHP_LANG=0
	TS=0
	SHELL_LANG=0
	GO_LANG=0
	RUST_LANG=0
	DOTNET=0
	UNKNOWN=1
	PY_FILES=0
	PY_NOTEBOOKS=0
	PY_CONFIGS=0
	JS_FILES=0
	JSX_FILES=0
	TS_FILES=0
	TSX_FILES=0
	HTML_FILES=0
	CSS_FILES=0
	NODE_MANIFESTS=0
	ANGULAR_MANIFESTS=0
	PHP_FILES=0
	PHP_MANIFESTS=0
	SHELL_FILES=0
	GO_FILES=0
	GO_MANIFESTS=0
	RUST_FILES=0
	RUST_MANIFESTS=0
	DOTNET_FILES=0
	DOTNET_MANIFESTS=0

	local path base lower first_line
	while IFS= read -r -d '' path; do
		path="${path#./}"
		base="${path##*/}"
		lower="${path,,}"

		case "$base" in
		package.json) NODE_MANIFESTS=$((NODE_MANIFESTS + 1)) ;;
		angular.json) ANGULAR_MANIFESTS=$((ANGULAR_MANIFESTS + 1)) ;;
		composer.json) PHP_MANIFESTS=$((PHP_MANIFESTS + 1)) ;;
		go.mod) GO_MANIFESTS=$((GO_MANIFESTS + 1)) ;;
		Cargo.toml) RUST_MANIFESTS=$((RUST_MANIFESTS + 1)) ;;
		pyproject.toml | requirements*.txt | setup.py | setup.cfg | Pipfile | poetry.lock | uv.lock | ruff.toml | .ruff.toml | mypy.ini | pyrightconfig.json)
			PY_CONFIGS=$((PY_CONFIGS + 1))
			;;
		esac

		case "$lower" in
		*.py) PY_FILES=$((PY_FILES + 1)) ;;
		*.ipynb) PY_NOTEBOOKS=$((PY_NOTEBOOKS + 1)) ;;
		*.js) JS_FILES=$((JS_FILES + 1)) ;;
		*.jsx) JSX_FILES=$((JSX_FILES + 1)) ;;
		*.ts) TS_FILES=$((TS_FILES + 1)) ;;
		*.tsx) TSX_FILES=$((TSX_FILES + 1)) ;;
		*.html | *.htm) HTML_FILES=$((HTML_FILES + 1)) ;;
		*.css) CSS_FILES=$((CSS_FILES + 1)) ;;
		*.php) PHP_FILES=$((PHP_FILES + 1)) ;;
		*.sh | *.bash | *.zsh) SHELL_FILES=$((SHELL_FILES + 1)) ;;
		*.go) GO_FILES=$((GO_FILES + 1)) ;;
		*.rs) RUST_FILES=$((RUST_FILES + 1)) ;;
		*.cs) DOTNET_FILES=$((DOTNET_FILES + 1)) ;;
		*.csproj | *.sln) DOTNET_MANIFESTS=$((DOTNET_MANIFESTS + 1)) ;;
		*)
			if [[ -x "$path" && "$base" != *.* ]]; then
				first_line="$(sed -n '1p' "$path" 2>/dev/null || true)"
				case "$first_line" in
				'#!'*sh | '#!'*bash | '#!'*zsh) SHELL_FILES=$((SHELL_FILES + 1)) ;;
				esac
			fi
			;;
		esac
	done < <(find . \
		\( -name '.git' \
		-o -name 'node_modules' \
		-o -name 'vendor' \
		-o -name 'dist' \
		-o -name 'build' \
		-o -name 'coverage' \
		-o -name '.cache' \
		-o -name '.venv' \
		-o -name '__pycache__' \
		-o -name '.mypy_cache' \
		-o -name '.pytest_cache' \
		-o -name '.ruff_cache' \
		-o -name 'obsidian' \) -prune \
		-o -type f -print0 2>/dev/null)

	[[ "$PY_FILES" -gt 0 || "$PY_NOTEBOOKS" -gt 0 || "$PY_CONFIGS" -gt 0 ]] && PYTHON=1
	[[ "$NODE_MANIFESTS" -gt 0 ]] && NODE_PKG=1
	[[ "$TS_FILES" -gt 0 || "$TSX_FILES" -gt 0 ]] && TS=1
	[[ "$HTML_FILES" -gt 0 || "$CSS_FILES" -gt 0 || "$JS_FILES" -gt 0 || "$JSX_FILES" -gt 0 || "$TS_FILES" -gt 0 || "$TSX_FILES" -gt 0 ]] && STATIC_WEB=1
	[[ "$PHP_FILES" -gt 0 || "$PHP_MANIFESTS" -gt 0 ]] && PHP_LANG=1
	[[ "$SHELL_FILES" -gt 0 ]] && SHELL_LANG=1
	[[ "$GO_FILES" -gt 0 || "$GO_MANIFESTS" -gt 0 ]] && GO_LANG=1
	[[ "$RUST_FILES" -gt 0 || "$RUST_MANIFESTS" -gt 0 ]] && RUST_LANG=1
	[[ "$DOTNET_FILES" -gt 0 || "$DOTNET_MANIFESTS" -gt 0 ]] && DOTNET=1
	if [[ "$PYTHON" -eq 1 || "$NODE_PKG" -eq 1 || "$STATIC_WEB" -eq 1 || "$PHP_LANG" -eq 1 || "$SHELL_LANG" -eq 1 || "$GO_LANG" -eq 1 || "$RUST_LANG" -eq 1 || "$DOTNET" -eq 1 ]]; then
		UNKNOWN=0
	fi
	return 0
}

detect_file_signals

print_detection() {
	echo
	log "Detected repo signals:"
	[[ "$PYTHON" -eq 1 ]] && echo "  - Python: $PY_FILES .py, $PY_NOTEBOOKS .ipynb, $PY_CONFIGS config/manifest files"
	[[ "$NODE_PKG" -eq 1 || "$TS" -eq 1 || "$JS_FILES" -gt 0 || "$JSX_FILES" -gt 0 ]] && echo "  - Node/JS/TS: $NODE_MANIFESTS package.json, $ANGULAR_MANIFESTS angular.json, $JS_FILES .js, $JSX_FILES .jsx, $TS_FILES .ts, $TSX_FILES .tsx"
	[[ "$HTML_FILES" -gt 0 || "$CSS_FILES" -gt 0 ]] && echo "  - Web markup/styles: $HTML_FILES HTML, $CSS_FILES CSS"
	[[ "$PHP_LANG" -eq 1 ]] && echo "  - PHP: $PHP_FILES .php, $PHP_MANIFESTS composer.json"
	[[ "$SHELL_LANG" -eq 1 ]] && echo "  - Shell: $SHELL_FILES shell scripts"
	[[ "$GO_LANG" -eq 1 ]] && echo "  - Go: $GO_FILES .go, $GO_MANIFESTS go.mod"
	[[ "$RUST_LANG" -eq 1 ]] && echo "  - Rust: $RUST_FILES .rs, $RUST_MANIFESTS Cargo.toml"
	[[ "$DOTNET" -eq 1 ]] && echo "  - .NET: $DOTNET_FILES .cs, $DOTNET_MANIFESTS project/solution files"
	[[ "$UNKNOWN" -eq 1 ]] && echo "  - No clear project type detected yet" || true
	return 0
}

print_recommendations() {
	echo
	log "Recommended quality tools."

	if [[ "$PYTHON" -eq 1 ]]; then
		cat <<'PYREC'

Python:
  Linter/formatter: Ruff
    export PATH="$HOME/.local/bin:$PATH"
    uv tool install ruff

  If uv times out fetching pypi.org, check network/proxy access:
    curl -I https://pypi.org/simple/ruff/
    export HTTPS_PROXY=http://proxy.example.com:8080
    export HTTP_PROXY="$HTTPS_PROXY"

  Or rerun this script with your org's internal Python package mirror:
    bash part2.sh --fresh-install --python-index-url https://your-python-mirror.example.com/simple

  Tests, only when the project has a real Python environment:
    pytest
    - pyproject.toml project: uv add --dev pytest
    - requirements project: create/use .venv, then uv pip install pytest

  Type checking, optional later:
    mypy or pyright
    - pyproject.toml project: uv add --dev mypy
    - requirements project: create/use .venv, then uv pip install mypy
PYREC
	fi

	if [[ "$NODE_PKG" -eq 1 ]]; then
		cat <<'NODEREC'

Node/JavaScript/TypeScript with package.json:
  Prefer existing package scripts if present:
    npm run lint
    npm run typecheck
    npm test

  If missing, this script can install:
    npm install --save-dev --save-exact @biomejs/biome htmlhint
    # or ESLint/Prettier if the project already uses those
NODEREC
	elif [[ "$STATIC_WEB" -eq 1 ]]; then
		cat <<'WEBREC'

JS/TS/HTML/CSS files without package.json:
  This script can create package.json when you approve npm tool installation,
  so Biome and HTMLHint can be installed as repo-local dev dependencies.

  If you install them yourself:
    npm init -y
    npm install --save-dev --save-exact @biomejs/biome htmlhint
WEBREC
	fi

	if [[ "$PHP_LANG" -eq 1 ]]; then
		cat <<'PHPREC'

PHP:
  Recommended:
    composer require --dev squizlabs/php_codesniffer phpstan/phpstan

  Then you can wire:
    php -l path/to/file.php
    vendor/bin/phpcs --standard=PSR12 --extensions=php --ignore=vendor/*,node_modules/*,dist/*,build/*,coverage/*,.git/*,.cache/*,.venv/*,obsidian/* .
    find . \( -name 'vendor' -o -name 'node_modules' -o -name 'dist' -o -name 'build' -o -name 'coverage' -o -name '.git' -o -name '.cache' -o -name '.venv' -o -name 'obsidian' \) -prune -o -name '*.php' -print0 | xargs -0 vendor/bin/phpstan analyse --memory-limit=1G --no-progress --
PHPREC
	fi

	if [[ "$SHELL_LANG" -eq 1 ]]; then
		cat <<'SHREC'

Shell scripts:
  Recommended:
    sudo apt-get install shellcheck shfmt
SHREC
	fi

	if [[ "$GO_LANG" -eq 1 ]]; then
		cat <<'GOREC'

Go:
  Recommended:
    gofmt
    go vet ./...
    go test ./...
  Optional stronger linter:
    staticcheck ./...
GOREC
	fi

	if [[ "$RUST_LANG" -eq 1 ]]; then
		cat <<'RUSTREC'

Rust:
  Recommended:
    cargo fmt --check
    cargo clippy -- -D warnings
    cargo test
RUSTREC
	fi

	if [[ "$DOTNET" -eq 1 ]]; then
		cat <<'DOTNETREC'

.NET:
  Recommended:
    dotnet format --verify-no-changes
    dotnet build
    dotnet test
DOTNETREC
	fi

	if [[ "$UNKNOWN" -eq 1 ]]; then
		cat <<'UNKNOWNREC'

No clear project type yet:
  Start building the repo first, or decide which tools fit the files manually.
  The script will not create fake lint/test/typecheck targets.
UNKNOWNREC
	fi

	cat <<'SECURITYREC'

Security scanner:
  Semgrep:
    pipx install semgrep
    semgrep scan
SECURITYREC
	return 0
}

# Package.json script detection without jq. Prefer npm pkg if available.
npm_has_script() {
	local script="$1"
	[[ -f package.json ]] || return 1
	if cmd_exists npm; then
		local value
		value="$(npm pkg get "scripts.${script}" 2>/dev/null || true)"
		[[ -n "$value" && "$value" != "{}" && "$value" != "null" ]]
	else
		grep -Eq '"'"$script"'"[[:space:]]*:' package.json
	fi
}

# Detect currently available checks. Only these may be wired.
declare -a LINT_TARGETS=()
declare -a FORMAT_TARGETS=()
declare -a TYPE_TARGETS=()
declare -a TEST_TARGETS=()
declare -a SECURITY_TARGETS=()

declare -a LINT_CMDS=()
declare -a FORMAT_CMDS=()
declare -a TYPE_CMDS=()
declare -a TEST_CMDS=()
declare -a SECURITY_CMDS=()

add_check() {
	local kind="$1" name="$2" cmd="$3"
	case "$kind" in
	lint)
		LINT_TARGETS+=("$name")
		LINT_CMDS+=("$cmd")
		;;
	format)
		FORMAT_TARGETS+=("$name")
		FORMAT_CMDS+=("$cmd")
		;;
	type)
		TYPE_TARGETS+=("$name")
		TYPE_CMDS+=("$cmd")
		;;
	test)
		TEST_TARGETS+=("$name")
		TEST_CMDS+=("$cmd")
		;;
	security)
		SECURITY_TARGETS+=("$name")
		SECURITY_CMDS+=("$cmd")
		;;
	esac
}

reset_checks() {
	LINT_TARGETS=()
	FORMAT_TARGETS=()
	TYPE_TARGETS=()
	TEST_TARGETS=()
	SECURITY_TARGETS=()
	LINT_CMDS=()
	FORMAT_CMDS=()
	TYPE_CMDS=()
	TEST_CMDS=()
	SECURITY_CMDS=()
}

detect_available_checks() {
	reset_checks

	# Python checks
	if [[ "$PYTHON" -eq 1 ]]; then
		if cmd_exists ruff; then
			add_check lint python "ruff check ."
			add_check format python "ruff format ."
		fi
		if cmd_exists mypy; then
			add_check type python "mypy ."
		elif cmd_exists pyright; then
			add_check type python "pyright ."
		fi
		if cmd_exists pytest && has_any \( -path './tests/*' -o -name 'test_*.py' -o -name '*_test.py' \); then
			add_check test python "pytest -q"
		fi
	fi

	# Node/package.json checks
	if [[ "$NODE_PKG" -eq 1 ]]; then
		if npm_has_script lint; then add_check lint node "npm run lint"; fi
		if npm_has_script format; then add_check format node "npm run format"; fi
		if npm_has_script typecheck; then add_check type node "npm run typecheck"; fi
		if npm_has_script test; then add_check test node "npm test"; fi
	fi

	# Static web checks
	if [[ "$STATIC_WEB" -eq 1 ]]; then
		if local_bin_exists biome; then
			add_check lint web "npx biome check ."
			add_check format web "npx biome check --write ."
		elif cmd_exists biome; then
			add_check lint web "biome check ."
			add_check format web "biome check --write ."
		fi
		if has_any -name '*.html'; then
			if local_bin_exists htmlhint; then
				add_check lint html "npx htmlhint --ignore \"**/.git/**,**/node_modules/**,**/vendor/**,**/dist/**,**/build/**,**/coverage/**,**/.cache/**,**/.venv/**,**/obsidian/**\" \"**/*.html\""
			elif cmd_exists htmlhint; then
				add_check lint html "htmlhint --ignore \"**/.git/**,**/node_modules/**,**/vendor/**,**/dist/**,**/build/**,**/coverage/**,**/.cache/**,**/.venv/**,**/obsidian/**\" \"**/*.html\""
			fi
		fi
	fi

	# PHP checks
	if [[ "$PHP_LANG" -eq 1 ]]; then
		if cmd_exists php && has_any -name '*.php'; then
			add_check lint php-syntax "find . \\( -name 'vendor' -o -name 'node_modules' -o -name 'dist' -o -name 'build' -o -name 'coverage' -o -name '.git' -o -name '.cache' -o -name '.venv' -o -name 'obsidian' \\) -prune -o -name '*.php' -print0 | xargs -0 -n1 php -l"
		fi
		if [[ -x vendor/bin/phpcs ]]; then
			add_check lint phpcs "vendor/bin/phpcs --standard=PSR12 --extensions=php --ignore=vendor/*,node_modules/*,dist/*,build/*,coverage/*,.git/*,.cache/*,.venv/*,obsidian/* ."
		fi
		if [[ -x vendor/bin/phpcbf ]]; then
			add_check format phpcbf "vendor/bin/phpcbf --standard=PSR12 --extensions=php --ignore=vendor/*,node_modules/*,dist/*,build/*,coverage/*,.git/*,.cache/*,.venv/*,obsidian/* . || true"
		fi
		if [[ -x vendor/bin/phpstan ]]; then
			add_check type phpstan "find . \\( -name 'vendor' -o -name 'node_modules' -o -name 'dist' -o -name 'build' -o -name 'coverage' -o -name '.git' -o -name '.cache' -o -name '.venv' -o -name 'obsidian' \\) -prune -o -name '*.php' -print0 | xargs -0 vendor/bin/phpstan analyse --memory-limit=1G --no-progress --"
		fi
	fi

	# Shell checks
	if [[ "$SHELL_LANG" -eq 1 ]]; then
		if cmd_exists shellcheck; then add_check lint shell "find . \\( -name 'vendor' -o -name 'node_modules' -o -name 'dist' -o -name 'build' -o -name 'coverage' -o -name '.git' -o -name '.cache' -o -name '.venv' -o -name 'obsidian' \\) -prune -o -name '*.sh' -print0 | xargs -0 shellcheck"; fi
		if cmd_exists shfmt; then add_check format shell "find . \\( -name 'vendor' -o -name 'node_modules' -o -name 'dist' -o -name 'build' -o -name 'coverage' -o -name '.git' -o -name '.cache' -o -name '.venv' -o -name 'obsidian' \\) -prune -o -name '*.sh' -print0 | xargs -0 shfmt -w"; fi
	fi

	# Go checks
	if [[ "$GO_LANG" -eq 1 ]] && cmd_exists go; then
		add_check format go "gofmt -w ."
		add_check lint go "go vet ./..."
		add_check test go "go test ./..."
	fi
	if [[ "$GO_LANG" -eq 1 ]] && cmd_exists staticcheck; then
		add_check lint go-staticcheck "staticcheck ./..."
	fi

	# Rust checks
	if [[ "$RUST_LANG" -eq 1 ]] && cmd_exists cargo; then
		add_check format rust "cargo fmt --check"
		add_check lint rust "cargo clippy -- -D warnings"
		add_check type rust "cargo check"
		add_check test rust "cargo test"
	fi

	# .NET checks
	if [[ "$DOTNET" -eq 1 ]] && cmd_exists dotnet; then
		add_check format dotnet "dotnet format --verify-no-changes"
		add_check type dotnet "dotnet build"
		add_check test dotnet "dotnet test"
	fi

	# Security check
	if cmd_works semgrep; then
		add_check security semgrep "$(semgrep_cmd) scan"
	elif cmd_exists semgrep; then
		warn "Semgrep is installed but failed 'semgrep --version'; not wiring security until it runs cleanly."
	fi
}

print_available_checks() {
	echo
	log "Currently available checks I can wire now:"
	local any=0
	if [[ ${#LINT_CMDS[@]} -gt 0 ]]; then
		any=1
		echo "  Lint:"
		printf '    - %s\n' "${LINT_CMDS[@]}"
	fi
	if [[ ${#FORMAT_CMDS[@]} -gt 0 ]]; then
		any=1
		echo "  Format:"
		printf '    - %s\n' "${FORMAT_CMDS[@]}"
	fi
	if [[ ${#TYPE_CMDS[@]} -gt 0 ]]; then
		any=1
		echo "  Typecheck:"
		printf '    - %s\n' "${TYPE_CMDS[@]}"
	fi
	if [[ ${#TEST_CMDS[@]} -gt 0 ]]; then
		any=1
		echo "  Test:"
		printf '    - %s\n' "${TEST_CMDS[@]}"
	fi
	if [[ ${#SECURITY_CMDS[@]} -gt 0 ]]; then
		any=1
		echo "  Security:"
		printf '    - %s\n' "${SECURITY_CMDS[@]}"
	fi
	[[ "$any" -eq 0 ]] && echo "  None. Install a recommended tool manually first." || true
	return 0
}

write_ai_quality_wrapper() {
	local path="scripts/ai-quality-wrapper.py"
	if [[ "$DRY_RUN" -eq 1 ]]; then
		log "Would write $path for AI-safe capped linter output."
		return 0
	fi

	mkdir -p scripts
	cat >"$path" <<'PYWRAPPER'
#!/usr/bin/env python3
"""Run a quality command with AI-safe output.

The full command output is saved to .cache/ai-quality. Stdout only receives a
small summary so AI tools do not ingest thousands of linter lines.
"""

from __future__ import annotations

import argparse
import datetime as dt
import os
import re
import subprocess
import sys
from pathlib import Path


DEFAULT_MAX_LINES = 30


def slugify(value: str) -> str:
    value = value.strip().lower()
    value = re.sub(r"[^a-z0-9._-]+", "-", value)
    return value.strip("-") or "quality-command"


def trim_lines(text: str, max_lines: int) -> tuple[list[str], bool]:
    lines = [line.rstrip() for line in text.splitlines() if line.strip()]
    if len(lines) <= max_lines:
        return lines, False

    head_count = max_lines // 2
    tail_count = max_lines - head_count
    return lines[:head_count] + ["... output truncated ..."] + lines[-tail_count:], True


def summarize_known_success(output: str, returncode: int) -> list[str] | None:
    if returncode != 0:
        return None

    lines = [line.rstrip() for line in output.splitlines() if line.strip()]
    if lines and all(line.startswith("No syntax errors detected in ") for line in lines):
        return [f"PHP syntax check passed for {len(lines)} files."]

    return None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run a command and print a capped AI-safe summary.")
    parser.add_argument("--label", required=True, help="Short name for this check.")
    parser.add_argument("--log-dir", default=".cache/ai-quality", help="Directory for full logs.")
    parser.add_argument("--max-lines", type=int, default=DEFAULT_MAX_LINES, help="Maximum output lines to print.")
    parser.add_argument("--shell", action="store_true", help="Run the command through the shell.")
    parser.add_argument("command", nargs=argparse.REMAINDER, help="Command after --.")
    args = parser.parse_args()

    if args.command and args.command[0] == "--":
        args.command = args.command[1:]
    if not args.command:
        parser.error("missing command after --")
    if args.max_lines < 4:
        parser.error("--max-lines must be at least 4")
    return args


def main() -> int:
    args = parse_args()
    log_dir = Path(args.log_dir)
    log_dir.mkdir(parents=True, exist_ok=True)

    timestamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    label = slugify(args.label)
    log_path = log_dir / f"{timestamp}-{label}.log"

    if args.shell:
        command_display = args.command[0]
        run_command: str | list[str] = args.command[0]
    else:
        command_display = " ".join(args.command)
        run_command = args.command

    env = os.environ.copy()
    env.setdefault("NO_COLOR", "1")

    completed = subprocess.run(
        run_command,
        shell=args.shell,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env=env,
        check=False,
    )

    output = completed.stdout or ""
    log_path.write_text(
        f"$ {command_display}\n"
        f"exit_code={completed.returncode}\n\n"
        f"{output}",
        encoding="utf-8",
    )

    status = "ok" if completed.returncode == 0 else f"failed ({completed.returncode})"
    print(f"[ai-quality] {args.label}: {status}")
    print(f"[ai-quality] full log: {log_path}")

    known_success = summarize_known_success(output, completed.returncode)
    if known_success is not None:
        print("[ai-quality] summary:")
        for line in known_success:
            print(line)
        return completed.returncode

    summary_lines, truncated = trim_lines(output, args.max_lines)
    if summary_lines:
        print(f"[ai-quality] capped output ({len(summary_lines)} lines):")
        for line in summary_lines:
            print(line)
    else:
        print("[ai-quality] no output")

    if truncated:
        print(f"[ai-quality] output was truncated for the AI transcript; inspect {log_path} for the full output.")

    return completed.returncode


if __name__ == "__main__":
    sys.exit(main())
PYWRAPPER
	chmod 0755 "$path"
	log "Wrote $path."
}

write_agent_check_edited() {
	local path="scripts/agent-check-edited.py"
	if [[ "$DRY_RUN" -eq 1 ]]; then
		log "Would write $path for formatter-first edited-file checks."
		return 0
	fi

	mkdir -p scripts
	cat >"$path" <<'PYCHECK'
#!/usr/bin/env python3
"""Format and verify files edited by the agent.

Default input is the current Git changed/untracked file set. Commands are routed
through scripts/ai-quality-wrapper.py so full output is logged while the AI
transcript receives capped summaries.
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import shutil
import subprocess
import sys
from pathlib import Path


EXCLUDED_DIRS = {
    ".cache",
    ".git",
    ".venv",
    "build",
    "coverage",
    "dist",
    "node_modules",
    "obsidian",
    "vendor",
}

BIOME_EXTS = {".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx", ".css", ".json", ".jsonc"}
HTML_EXTS = {".html", ".htm"}
PHP_EXTS = {".php"}
SHELL_EXTS = {".sh", ".bash", ".zsh"}


def run_capture(args: list[str], cwd: Path) -> str:
    completed = subprocess.run(args, cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False)
    return completed.stdout


def repo_root() -> Path:
    output = run_capture(["git", "rev-parse", "--show-toplevel"], Path.cwd()).strip()
    return Path(output) if output else Path.cwd()


def git_changed_files(root: Path) -> list[str]:
    changed = run_capture(["git", "diff", "--name-only", "--diff-filter=ACMRTUXB", "HEAD"], root).splitlines()
    untracked = run_capture(["git", "ls-files", "--others", "--exclude-standard"], root).splitlines()
    return sorted(set(changed + untracked))


def is_excluded(path: str) -> bool:
    return any(part in EXCLUDED_DIRS for part in Path(path).parts)


def existing_project_files(root: Path, files: list[str]) -> list[str]:
    result: list[str] = []
    for file in files:
        normalized = file.strip()
        if not normalized or is_excluded(normalized):
            continue
        full_path = (root / normalized).resolve()
        try:
            full_path.relative_to(root.resolve())
        except ValueError:
            continue
        if full_path.is_file():
            result.append(normalized)
    return sorted(set(result))


def split_by_ext(files: list[str]) -> dict[str, list[str]]:
    groups = {"biome": [], "html": [], "php": [], "shell": []}
    for file in files:
        suffix = Path(file).suffix.lower()
        if suffix in BIOME_EXTS:
            groups["biome"].append(file)
        if suffix in HTML_EXTS:
            groups["html"].append(file)
        if suffix in PHP_EXTS:
            groups["php"].append(file)
        if suffix in SHELL_EXTS:
            groups["shell"].append(file)
    return groups


def have_path(root: Path, path: str) -> bool:
    return (root / path).exists()


def have_command(command: str, root: Path) -> bool:
    return shutil.which(command) is not None


def npm_has_script(root: Path, name: str) -> bool:
    package_json = root / "package.json"
    if not package_json.is_file():
        return False
    try:
        data = json.loads(package_json.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return False
    scripts = data.get("scripts")
    return isinstance(scripts, dict) and isinstance(scripts.get(name), str)


def quote_files(files: list[str]) -> str:
    return " ".join(shlex.quote(file) for file in files)


def wrapper_command(root: Path, label: str, command: list[str], *, shell: bool = False, max_lines: int = 24) -> list[str]:
    wrapper = root / "scripts" / "ai-quality-wrapper.py"
    args = [sys.executable, str(wrapper), "--label", label, "--max-lines", str(max_lines)]
    if shell:
        args.append("--shell")
    args.append("--")
    args.extend(command)
    return args


def run_wrapped(root: Path, label: str, command: list[str], *, shell: bool = False, max_lines: int = 24) -> int:
    completed = subprocess.run(wrapper_command(root, label, command, shell=shell, max_lines=max_lines), cwd=root, check=False)
    return completed.returncode


def run_phase(root: Path, phase: str, commands: list[tuple[str, list[str], bool, int, bool]]) -> int:
    if not commands:
        print(f"[edited-check] {phase}: no applicable commands")
        return 0
    print(f"[edited-check] {phase}")
    sys.stdout.flush()
    failed = 0
    for label, command, shell, max_lines, allow_failure in commands:
        code = run_wrapped(root, label, command, shell=shell, max_lines=max_lines)
        if code != 0 and not allow_failure:
            failed = 1
    return failed


def build_commands(root: Path, groups: dict[str, list[str]]) -> tuple[list[tuple[str, list[str], bool, int, bool]], list[tuple[str, list[str], bool, int, bool]], list[tuple[str, list[str], bool, int, bool]]]:
    format_cmds: list[tuple[str, list[str], bool, int, bool]] = []
    lint_cmds: list[tuple[str, list[str], bool, int, bool]] = []
    type_cmds: list[tuple[str, list[str], bool, int, bool]] = []

    if groups["biome"] and have_path(root, "node_modules/.bin/biome"):
        files = quote_files(groups["biome"])
        format_cmds.append(("format-biome-edited", [f"npx biome check --write {files}"], True, 20, False))
        lint_cmds.append(("lint-biome-edited", [f"npx biome check --colors=off --max-diagnostics=20 {files}"], True, 24, False))

    if groups["html"] and have_path(root, "node_modules/.bin/htmlhint"):
        files = quote_files(groups["html"])
        lint_cmds.append(("lint-html-edited", [f"npx htmlhint --nocolor --format compact {files}"], True, 24, False))

    if groups["php"]:
        files = quote_files(groups["php"])
        syntax_loop = "for file in " + files + "; do php -l \"$file\"; done"
        if have_command("php", root):
            lint_cmds.append(("lint-php-syntax-edited", [syntax_loop], True, 20, False))
        if have_path(root, "vendor/bin/phpcbf"):
            format_cmds.append(("format-phpcbf-edited", [f"vendor/bin/phpcbf --standard=PSR12 --extensions=php {files} || true"], True, 20, True))
        if have_path(root, "vendor/bin/phpcs"):
            lint_cmds.append(("lint-phpcs-edited", [f"vendor/bin/phpcs --standard=PSR12 --extensions=php --report=summary -q {files}"], True, 24, False))
        if have_path(root, "vendor/bin/phpstan"):
            type_cmds.append(("type-phpstan-edited", [f"vendor/bin/phpstan analyse --memory-limit=1G --no-progress --error-format=table -- {files}"], True, 30, False))

    if groups["shell"]:
        files = quote_files(groups["shell"])
        if have_command("shfmt", root):
            format_cmds.append(("format-shfmt-edited", [f"shfmt -w {files}"], True, 20, False))
        if have_command("shellcheck", root):
            lint_cmds.append(("lint-shellcheck-edited", [f"shellcheck {files}"], True, 24, False))

    if (groups["biome"] or groups["html"]) and npm_has_script(root, "typecheck"):
        type_cmds.append(("type-npm-edited", ["npm run typecheck"], False, 30, False))

    return format_cmds, lint_cmds, type_cmds


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Format, lint, and typecheck edited files with capped AI output.")
    parser.add_argument("files", nargs="*", help="Specific files to check. Defaults to Git changed/untracked files.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = repo_root()
    os.chdir(root)
    files = existing_project_files(root, args.files if args.files else git_changed_files(root))
    groups = split_by_ext(files)
    relevant = sorted(set(groups["biome"] + groups["html"] + groups["php"] + groups["shell"]))

    print(f"[edited-check] root: {root}")
    if not relevant:
        print("[edited-check] no edited JS/CSS/JSON/HTML/PHP/shell files to check")
        return 0

    print(f"[edited-check] files: {len(relevant)}")
    for file in relevant[:30]:
        print(f"  - {file}")
    if len(relevant) > 30:
        print(f"  ... {len(relevant) - 30} more files hidden from AI output")
    sys.stdout.flush()

    format_cmds, lint_cmds, type_cmds = build_commands(root, groups)
    failed = 0
    failed |= run_phase(root, "format edited files", format_cmds)
    failed |= run_phase(root, "lint edited files", lint_cmds)
    failed |= run_phase(root, "typecheck edited files", type_cmds)

    if failed:
        print("[edited-check] errors found after formatting/linting/typechecking edited files")
        return 1
    print("[edited-check] edited-file checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYCHECK
	chmod 0755 "$path"
	log "Wrote $path."
}

ensure_cache_gitignored() {
	if [[ "$DRY_RUN" -eq 1 ]]; then
		log "Would ensure .cache/ is ignored in .gitignore."
		return 0
	fi
	touch .gitignore
	if ! grep -Fxq ".cache/" .gitignore; then
		printf '\n# Local tool logs and caches\n.cache/\n' >>.gitignore
		log "Added .cache/ to .gitignore."
	fi
}

emit_ai_cmd() {
	local label="$1"
	local cmd="$2"
	local escaped_cmd
	escaped_cmd="${cmd//\'/\'\\\'\'}"
	printf "\t@python3 scripts/ai-quality-wrapper.py --label %q --max-lines 30 --shell -- '%s'\n" "$label" "$escaped_cmd"
}

write_makefile() {
	local mf="Makefile"
	local tmp
	tmp="$(mktemp)"

	{
		echo "# Generated by part2.sh"
		echo "# Only targets backed by currently available tools/scripts are included."
		echo
		echo ".PHONY: verify"
		# This line is written for make, not expanded by this script.
		# shellcheck disable=SC2016
		echo 'export PATH := $(HOME)/.local/bin:$(PATH)'
		echo

		if [[ ${#LINT_CMDS[@]} -gt 0 ]]; then
			echo ".PHONY: lint"
			echo "lint:"
			local cmd
			for cmd in "${LINT_CMDS[@]}"; do echo "	$cmd"; done
			echo
			echo ".PHONY: lint-ai"
			echo "lint-ai:"
			local idx
			for idx in "${!LINT_CMDS[@]}"; do emit_ai_cmd "lint-${LINT_TARGETS[$idx]}" "${LINT_CMDS[$idx]}"; done
			echo
		fi

		if [[ ${#FORMAT_CMDS[@]} -gt 0 ]]; then
			echo ".PHONY: format fix"
			echo "format:"
			local cmd
			for cmd in "${FORMAT_CMDS[@]}"; do echo "	$cmd"; done
			echo
			echo "fix: format"
			echo
		fi

		if [[ ${#TYPE_CMDS[@]} -gt 0 ]]; then
			echo ".PHONY: typecheck"
			echo "typecheck:"
			local cmd
			for cmd in "${TYPE_CMDS[@]}"; do echo "	$cmd"; done
			echo
			echo ".PHONY: typecheck-ai"
			echo "typecheck-ai:"
			local idx
			for idx in "${!TYPE_CMDS[@]}"; do emit_ai_cmd "type-${TYPE_TARGETS[$idx]}" "${TYPE_CMDS[$idx]}"; done
			echo
		fi

		if [[ ${#TEST_CMDS[@]} -gt 0 ]]; then
			echo ".PHONY: test"
			echo "test:"
			local cmd
			for cmd in "${TEST_CMDS[@]}"; do echo "	$cmd"; done
			echo
			echo ".PHONY: test-ai"
			echo "test-ai:"
			local idx
			for idx in "${!TEST_CMDS[@]}"; do emit_ai_cmd "test-${TEST_TARGETS[$idx]}" "${TEST_CMDS[$idx]}"; done
			echo
		fi

		if [[ ${#SECURITY_CMDS[@]} -gt 0 ]]; then
			echo ".PHONY: security"
			echo "security:"
			local cmd
			for cmd in "${SECURITY_CMDS[@]}"; do echo "	$cmd"; done
			echo
			echo ".PHONY: security-ai"
			echo "security-ai:"
			local idx
			for idx in "${!SECURITY_CMDS[@]}"; do emit_ai_cmd "security-${SECURITY_TARGETS[$idx]}" "${SECURITY_CMDS[$idx]}"; done
			echo
		fi

		echo "verify:"
		local deps=0
		if [[ ${#LINT_CMDS[@]} -gt 0 ]]; then
			echo "	\$(MAKE) lint"
			deps=1
		fi
		if [[ ${#TYPE_CMDS[@]} -gt 0 ]]; then
			echo "	\$(MAKE) typecheck"
			deps=1
		fi
		if [[ ${#TEST_CMDS[@]} -gt 0 ]]; then
			echo "	\$(MAKE) test"
			deps=1
		fi
		if [[ ${#SECURITY_CMDS[@]} -gt 0 ]]; then
			echo "	\$(MAKE) security"
			deps=1
		fi
		if [[ "$deps" -eq 0 ]]; then
			echo "	@echo 'No quality checks configured yet. Install a recommended linter/tool manually and rerun this script.'"
			echo "	@exit 1"
		fi
		echo
		echo ".PHONY: verify-ai"
		echo "verify-ai:"
		local ai_deps=0
		if [[ ${#LINT_CMDS[@]} -gt 0 ]]; then
			echo "	@\$(MAKE) lint-ai"
			ai_deps=1
		fi
		if [[ ${#TYPE_CMDS[@]} -gt 0 ]]; then
			echo "	@\$(MAKE) typecheck-ai"
			ai_deps=1
		fi
		if [[ ${#TEST_CMDS[@]} -gt 0 ]]; then
			echo "	@\$(MAKE) test-ai"
			ai_deps=1
		fi
		if [[ ${#SECURITY_CMDS[@]} -gt 0 ]]; then
			echo "	@\$(MAKE) security-ai"
			ai_deps=1
		fi
		if [[ "$ai_deps" -eq 0 ]]; then
			echo "	@echo 'No AI-safe quality checks configured yet. Install a recommended linter/tool manually and rerun this script.'"
			echo "	@exit 1"
		fi
		echo
		echo ".PHONY: edited-ai"
		echo "edited-ai:"
		echo "	@python3 scripts/agent-check-edited.py"
		if [[ -f scripts/update-codebase-wiki.py || -d codebase-wiki ]]; then
			echo
			echo ".PHONY: wiki-ai"
			echo "wiki-ai:"
			echo "	@python3 scripts/update-codebase-wiki.py"
		fi
	} >"$tmp"

	if [[ "$DRY_RUN" -eq 1 ]]; then
		log "Would write $mf with:"
		sed 's/^/  /' "$tmp"
		rm -f "$tmp"
		return 0
	fi

	if [[ -f "$mf" ]]; then
		cp "$mf" "$mf.bak.$(date +%Y%m%d-%H%M%S)"
		log "Backed up existing Makefile."
	fi
	mv "$tmp" "$mf"
	log "Wrote $mf."
}

write_biome_config() {
	if [[ "$STATIC_WEB" -ne 1 ]]; then
		return 0
	fi
	if ! local_bin_exists biome && ! cmd_exists biome; then
		return 0
	fi
	if has_biome_config; then
		log "Biome config already exists; leaving it unchanged."
		return 0
	fi

	if [[ "$DRY_RUN" -eq 1 ]]; then
		log "Would create biome.json with common generated/vendor directories excluded."
		return 0
	fi

	cat >biome.json <<'BIOMEJSON'
{
  "root": true,
  "formatter": {
    "indentStyle": "space",
    "indentWidth": 2
  },
  "files": {
    "includes": [
      "**/*.js",
      "**/*.jsx",
      "**/*.mjs",
      "**/*.cjs",
      "**/*.ts",
      "**/*.tsx",
      "**/*.css",
      "biome.json",
      "package.json",
      "!!**/.git",
      "!!**/node_modules",
      "!!**/vendor",
      "!!**/dist",
      "!!**/build",
      "!!**/coverage",
      "!!**/.cache",
      "!!**/.venv",
      "!!**/obsidian",
      "!!**/composer.lock",
      "!!**/package-lock.json"
    ]
  }
}
BIOMEJSON
	log "Wrote biome.json."
}

print_semgrep_note() {
	if [[ ${#SECURITY_CMDS[@]} -eq 0 ]]; then
		return 0
	fi

	cat <<'SEMGREP_NOTE'

Semgrep note:
  Semgrep does not use LLM tokens. It is a local/static security scanner.
  The practical cost is runtime and findings noise, not Codex/OpenAI token usage.

  In the Makefile written by this script, Semgrep runs when you run:
    make security
    make security-ai
    make verify
    make verify-ai

  It does not run automatically on every query. It only runs when one of those
  commands is invoked, or if you later wire those commands into hooks or CI.
SEMGREP_NOTE
}

should_run_fixers() {
	if [[ ${#FORMAT_CMDS[@]} -eq 0 ]]; then
		return 1
	fi
	case "$FIX_MODE" in
	yes) return 0 ;;
	no) return 1 ;;
	esac
	if [[ "$YES" -eq 1 ]]; then
		return 0
	fi
	ask_yn "Run safe automatic fixers now?" "y"
}

run_fixers_now() {
	if [[ ${#FORMAT_CMDS[@]} -eq 0 ]]; then
		log "No automatic fixers are available for this repo."
		return 0
	fi

	if ! should_run_fixers; then
		log "Automatic fixers skipped."
		return 0
	fi

	echo
	log "Running safe automatic fixers."
	local cmd failed=0
	for cmd in "${FORMAT_CMDS[@]}"; do
		printf '+ %s\n' "$cmd"
		if [[ "$DRY_RUN" -eq 1 ]]; then
			continue
		fi
		if ! bash -lc "$cmd"; then
			failed=1
			warn "Fixer reported remaining issues: $cmd"
		fi
	done

	if [[ "$failed" -eq 1 ]]; then
		warn "Automatic fixers ran, but at least one tool still reported issues that need manual review."
	else
		log "Automatic fixers completed."
	fi
}

print_detection
print_recommendations
install_missing_quality_tools
detect_available_checks
print_available_checks

missing_core_linter=0
if [[ ${#LINT_CMDS[@]} -eq 0 ]]; then
	missing_core_linter=1
fi

if [[ "$missing_core_linter" -eq 1 ]]; then
	echo
	warn "No real linter is currently available to wire."
	warn "Install the recommended linter, then rerun this script."
	if [[ "$YES" -eq 0 ]]; then
		if ask_yn "Exit now so you can install the recommended tools first?" "y"; then
			log "Exiting before writing Makefile."
			exit 0
		fi
	fi
fi

if [[ "$WIRE_MODE" == "no" ]]; then
	log "Not writing Makefile because --no-wire was used."
	exit 0
fi

TOTAL_CHECKS=$((${#LINT_CMDS[@]} + ${#TYPE_CMDS[@]} + ${#TEST_CMDS[@]} + ${#SECURITY_CMDS[@]}))
if [[ "$TOTAL_CHECKS" -eq 0 ]]; then
	warn "No runnable quality checks are available. Not writing a Makefile."
	warn "Install a recommended tool manually first, then rerun this script."
	exit 0
fi

if [[ "$WIRE_MODE" == "ask" ]]; then
	if ! ask_yn "Write/update Makefile using only currently available checks?" "y"; then
		log "Not writing Makefile."
		exit 0
	fi
fi

write_ai_quality_wrapper
write_agent_check_edited
ensure_cache_gitignored
write_biome_config
write_makefile
run_fixers_now

if [[ "$DRY_RUN" -eq 0 ]]; then
	echo
	log "Final checks:"
	log "  make edited-ai   # format/lint/typecheck edited files with capped AI output"
	log "  make verify-ai   # broader AI-safe quality/security checks"
	if [[ -f scripts/update-codebase-wiki.py || -d codebase-wiki ]]; then
		log "  make wiki-ai     # refresh generated codebase-wiki sections"
	fi
	print_semgrep_note
fi
