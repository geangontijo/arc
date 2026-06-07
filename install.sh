#!/usr/bin/env bash
#
# arc (ai-codechecker) installer
#
# Usage:
#   ./install.sh                  Install to ~/.local/bin
#   ./install.sh --system         Install to /usr/local/bin (requires write access)
#   ./install.sh --prefix <dir>   Install to <dir>
#   ./install.sh --uninstall      Remove the installed binary
#   ./install.sh --help           Show this help
#
# Works on Linux, macOS, and other Unix-like systems. No external dependencies
# beyond POSIX utilities (mkdir, cp, chmod, dirname, basename, readlink).
#

set -euo pipefail

readonly APP_NAME="arc"
readonly SOURCE_SCRIPT="ci-requirements-check.sh"
readonly VERSION="0.1.0"
readonly MANIFEST_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/arc"
readonly MANIFEST_FILE="$MANIFEST_DIR/install.path"

# ── output helpers ───────────────────────────────────────────────────────────
info()    { printf '\033[0;34m[info]\033[0m  %s\n' "$*"; }
success() { printf '\033[0;32m[ok]\033[0m    %s\n' "$*"; }
warn()    { printf '\033[0;33m[warn]\033[0m  %s\n' "$*" >&2; }
error()   { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; }

# ── resolve the installer script's own directory (follows symlinks) ─────────
script_dir() {
  local src="${BASH_SOURCE[0]}"
  while [[ -L "$src" ]]; do
    local dir
    dir=$(cd -P "$(dirname "$src")" && pwd)
    src=$(readlink "$src")
    [[ "$src" != /* ]] && src="$dir/$src"
  done
  cd -P "$(dirname "$src")" && pwd
}

SCRIPT_DIR=$(script_dir)
SOURCE_PATH="$SCRIPT_DIR/$SOURCE_SCRIPT"

# ── usage ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
arc (ai-codechecker) installer v$VERSION

Usage:
  $0 [options]

Options:
  --prefix <dir>    Install to <dir>/$APP_NAME (default: \$HOME/.local/bin)
  --system          Install to /usr/local/bin (shortcut for --prefix /usr/local/bin)
  --uninstall       Remove the installed binary
  -h, --help        Show this help
  -v, --version     Show installer version

Examples:
  $0                       # user install
  $0 --system              # system-wide install
  $0 --prefix /opt/bin     # custom location
  $0 --uninstall           # remove installation
EOF
}

# ── argument parsing ──────────────────────────────────────────────────────────
PREFIX=""
ACTION="install"

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --prefix)    PREFIX="$2"; shift 2 ;;
      --system)    PREFIX="/usr/local/bin"; shift ;;
      --uninstall) ACTION="uninstall"; shift ;;
      -h|--help)   usage; exit 0 ;;
      -v|--version) echo "arc installer v$VERSION"; exit 0 ;;
      *) error "Unknown option: $1"; usage; exit 2 ;;
    esac
  done
}

# ── manifest helpers ──────────────────────────────────────────────────────────
manifest_load() {
  [[ -f "$MANIFEST_FILE" ]] && cat "$MANIFEST_FILE" || true
}

manifest_save() {
  mkdir -p "$MANIFEST_DIR"
  printf '%s\n' "$1" > "$MANIFEST_FILE"
}

manifest_clear() {
  rm -f "$MANIFEST_FILE"
}

# ── prefix resolution ─────────────────────────────────────────────────────────
resolve_prefix() {
  if [[ -n "$PREFIX" ]]; then
    echo "$PREFIX"
  elif local saved; saved=$(manifest_load); [[ -n "$saved" ]]; then
    echo "$saved"
  else
    echo "$HOME/.local/bin"
  fi
}

# ── prefix validation ─────────────────────────────────────────────────────────
validate_prefix() {
  local prefix="$1"
  if [[ "$prefix" != /* ]]; then
    error "Prefix must be an absolute path: $prefix"
    exit 1
  fi
  if [[ ! -d "$prefix" ]]; then
    if ! mkdir -p "$prefix" 2>/dev/null; then
      error "Cannot create directory: $prefix"
      error "Try --prefix \$HOME/bin or run with elevated permissions."
      exit 1
    fi
    success "Created directory: $prefix"
  fi
  if [[ ! -w "$prefix" ]]; then
    error "Directory is not writable: $prefix"
    error "Run with elevated permissions or choose a different --prefix."
    exit 1
  fi
}

# ── PATH check ────────────────────────────────────────────────────────────────
is_in_path() {
  local dir="$1" IFS=':' p
  for p in $PATH; do
    [[ "$p" == "$dir" ]] && return 0
  done
  return 1
}

# ── install ───────────────────────────────────────────────────────────────────
do_install() {
  if [[ ! -f "$SOURCE_PATH" ]]; then
    error "Source script not found: $SOURCE_PATH"
    error "Run install.sh from the ai-codechecker repository root."
    exit 1
  fi

  local prefix
  prefix=$(resolve_prefix)
  validate_prefix "$prefix"

  local target="$prefix/$APP_NAME"

  info "Installing $APP_NAME to $target"
  cp "$SOURCE_PATH" "$target"
  chmod 0755 "$target"
  manifest_save "$prefix"
  success "Installed $APP_NAME v$VERSION"

  if is_in_path "$prefix"; then
    success "Run '$APP_NAME' to get started"
  else
    warn "$prefix is not in your PATH"
    warn "Add this to your shell profile (~/.bashrc, ~/.zshrc, etc.):"
    warn "  export PATH=\"$prefix:\$PATH\""
  fi
}

# ── uninstall ─────────────────────────────────────────────────────────────────
do_uninstall() {
  local prefix
  prefix=$(resolve_prefix)
  local target="$prefix/$APP_NAME"

  if [[ -e "$target" ]]; then
    info "Removing $target"
    rm -f "$target"
    manifest_clear
    success "Uninstalled $APP_NAME"
    return 0
  fi

  info "Not installed at $target"
  local found=false alt
  for alt in "/usr/local/bin" "$HOME/bin"; do
    if [[ -e "$alt/$APP_NAME" ]]; then
      warn "Found installation at $alt/$APP_NAME"
      if [[ -w "$alt/$APP_NAME" ]]; then
        info "Removing $alt/$APP_NAME"
        rm -f "$alt/$APP_NAME"
        manifest_clear
        success "Uninstalled $APP_NAME from $alt"
        found=true
      else
        error "$alt/$APP_NAME is not writable. Run with elevated permissions."
      fi
      break
    fi
  done

  if [[ "$found" == false ]]; then
    info "No installation found in common locations."
    info "If installed with --prefix, pass the same --prefix to --uninstall."
  fi
}

# ── main ──────────────────────────────────────────────────────────────────────
main() {
  parse_args "$@"
  case "$ACTION" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
  esac
}

main "$@"
