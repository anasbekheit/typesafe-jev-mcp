#!/bin/sh
# Product installer: binary + key + skill + MCP registration.
# Blueprint: Codex CLI install.sh (https://chatgpt.com/codex/install.sh).
# Safe under `curl | sh` (prompts read /dev/tty).
set -eu

REPO=anasbekheit/typesafe-jev-mcp
DIST=https://github.com/${REPO}/releases/latest/download/typesafe-jev-mcp-installer.sh
MANIFEST=https://github.com/${REPO}/releases/latest/download/dist-manifest.json
SKILL_URL=https://raw.githubusercontent.com/${REPO}/main/skills/jev/SKILL.md
PS1=https://raw.githubusercontent.com/${REPO}/main/scripts/install.ps1
CONSOLE=https://console.typesafe.ai/
SERVICE=jev-mcp
TTY=/dev/tty
NON_INTERACTIVE="${TYPESAFE_NON_INTERACTIVE:-false}"

export PATH="${HOME}/.local/bin:${HOME}/.claude/bin:${HOME}/.opencode/bin:${HOME}/.cargo/bin:${PATH:-}"

step() { printf '==> %s\n' "$1"; }
warn() { printf 'WARNING: %s\n' "$1" >&2; }
die() { printf '%s\n' "$1" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

is_non_interactive() {
  case "$NON_INTERACTIVE" in
  1 | [Tt][Rr][Uu][Ee] | [Yy][Ee][Ss]) return 0 ;;
  *) return 1 ;;
  esac
}

can_tty() {
  ( : <"$TTY" ) 2>/dev/null
}

download_file() {
  url=$1
  out=$2
  if have curl; then
    curl -fsSL "$url" -o "$out"
    return
  fi
  if have wget; then
    wget -q -O "$out" "$url"
    return
  fi
  die "curl or wget is required"
}

download_text() {
  url=$1
  if have curl; then
    curl -fsSL "$url"
    return
  fi
  if have wget; then
    wget -q -O - "$url"
    return
  fi
  die "curl or wget is required"
}

resolve() {
  name=$1
  if command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
    return 0
  fi
  for p in \
    "${HOME}/.local/bin/${name}" \
    "${HOME}/.claude/local/bin/${name}" \
    "${HOME}/.opencode/bin/${name}" \
    "${HOME}/.nvm/versions/node/"*/bin/"${name}"; do
    if [ -x "$p" ]; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

run_quiet() {
  if have timeout; then
    timeout 3 "$@" >/dev/null 2>&1
  else
    "$@" >/dev/null 2>&1
  fi
}

open_url() {
  url=$1
  if have open && run_quiet open "$url"; then
    return 0
  fi
  if have xdg-open && run_quiet xdg-open "$url"; then
    return 0
  fi
  if have wslview && run_quiet wslview "$url"; then
    return 0
  fi
  return 1
}

resolved_version() {
  download_text "$MANIFEST" 2>/dev/null | sed -n 's/.*"announcement_tag": *"v\{0,1\}\([^"]*\)".*/\1/p' | head -n 1
}

version_from_binary() {
  p=$1
  [ -x "$p" ] || return 1
  "$p" --version 2>/dev/null | sed -n 's/^typesafe-jev-mcp //p' | head -n 1
}

persist_key() {
  key=$1
  case "$(uname -s)" in
  Darwin)
    security add-generic-password -a "$USER" -s "$SERVICE" -w "$key" -U
    KEY_COMMAND="security find-generic-password -s ${SERVICE} -w"
    step "Saved the key in Keychain (${SERVICE})"
    ;;
  *)
    dir="${HOME}/.config/typesafe-jev-mcp"
    mkdir -p "$dir"
    chmod 700 "$dir"
    umask 077
    printf '%s\n' "$key" >"${dir}/key"
    chmod 600 "${dir}/key"
    KEY_COMMAND="cat ${dir}/key"
    step "Saved the key at ${dir}/key"
    ;;
  esac
}

ensure_key() {
  if [ -n "${TYPESAFE_API_KEY_COMMAND:-}" ]; then
    KEY_COMMAND=$TYPESAFE_API_KEY_COMMAND
    sh -c "$KEY_COMMAND" >/dev/null 2>&1 || die "TYPESAFE_API_KEY_COMMAND did not print a key"
    step "Using TYPESAFE_API_KEY_COMMAND"
    return 0
  fi

  if [ -n "${TYPESAFE_API_KEY:-}" ]; then
    persist_key "$TYPESAFE_API_KEY"
    return 0
  fi

  case "$(uname -s)" in
  Darwin)
    if security find-generic-password -s "$SERVICE" -w >/dev/null 2>&1; then
      KEY_COMMAND="security find-generic-password -s ${SERVICE} -w"
      step "Found an existing Keychain item (${SERVICE})"
      return 0
    fi
    ;;
  *)
    if [ -s "${HOME}/.config/typesafe-jev-mcp/key" ]; then
      KEY_COMMAND="cat ${HOME}/.config/typesafe-jev-mcp/key"
      step "Found ${HOME}/.config/typesafe-jev-mcp/key"
      return 0
    fi
    ;;
  esac

  if is_non_interactive || ! can_tty; then
    die "No key. Set TYPESAFE_API_KEY and re-run. ${CONSOLE}"
  fi

  if open_url "$CONSOLE"; then
    step "Opened ${CONSOLE}"
  else
    step "Open this URL: ${CONSOLE}"
  fi
  printf 'Paste the API key: ' >"$TTY"
  saved=$(stty -g <"$TTY")
  trap 'stty "$saved" <"$TTY"; exit 1' INT TERM
  stty -echo <"$TTY"
  IFS= read -r key <"$TTY" || true
  stty "$saved" <"$TTY"
  trap - INT TERM
  printf '\n' >"$TTY"
  key=$(printf '%s' "$key" | tr -d '\r\n')
  [ -n "$key" ] || die "Empty key"
  persist_key "$key"
}

register() {
  harness=$1
  shift
  if "$@" >/dev/null 2>&1; then
    step "Registered ${harness}"
    return 0
  fi
  step "Skipped ${harness} (already registered, or the CLI refused)"
}

cursor_mcp() {
  have python3 || return 0
  [ -d "${HOME}/.cursor" ] || return 0
  python3 - "$bin" "$KEY_COMMAND" <<'PY'
import json, pathlib, sys
bin, command = sys.argv[1], sys.argv[2]
path = pathlib.Path.home() / ".cursor" / "mcp.json"
data = {}
if path.exists() and path.stat().st_size:
    data = json.loads(path.read_text())
servers = data.setdefault("mcpServers", {})
servers["jev"] = {"command": bin, "env": {"TYPESAFE_API_KEY_COMMAND": command}}
path.write_text(json.dumps(data, indent=2) + "\n")
PY
  step "Registered Cursor (~/.cursor/mcp.json)"
}

place_skill() {
  label=$1
  dir=$2
  mkdir -p "${dir}/jev"
  download_file "$SKILL_URL" "${dir}/jev/SKILL.md"
  step "Skill → ${label}"
}

case "$(uname -s)" in
Darwin)
  os=darwin
  ;;
Linux)
  os=linux
  ;;
MINGW* | MSYS* | CYGWIN*)
  die "install.sh supports macOS and Linux. Use install.ps1 on Windows:
  powershell -ExecutionPolicy Bypass -c \"irm ${PS1} | iex\""
  ;;
*)
  die "install.sh supports macOS and Linux. Use install.ps1 on Windows."
  ;;
esac

case "$(uname -m)" in
x86_64 | amd64) arch=x86_64 ;;
arm64 | aarch64) arch=aarch64 ;;
*) die "Unsupported architecture: $(uname -m)" ;;
esac

if [ "$os" = darwin ] && [ "$arch" = x86_64 ]; then
  if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || true)" = 1 ]; then
    arch=aarch64
  fi
fi

if [ "$os" = darwin ]; then
  if [ "$arch" = aarch64 ]; then
    platform_label="macOS (Apple Silicon)"
  else
    platform_label="macOS (Intel)"
  fi
else
  if [ "$arch" = aarch64 ]; then
    platform_label="Linux (ARM64)"
  else
    platform_label="Linux (x64)"
  fi
fi

claude_bin=$(resolve claude || true)
codex_bin=$(resolve codex || true)
opencode_bin=$(resolve opencode || true)
agy_bin=$(resolve agy || true)

if [ -z "$claude_bin" ] && [ -z "$codex_bin" ] && [ -z "$opencode_bin" ] && [ -z "$agy_bin" ] && [ ! -d "${HOME}/.cursor" ]; then
  die "No coding agent found (claude, codex, opencode, agy, or ~/.cursor).
Claude Code lives at ~/.local/bin/claude — put it on PATH and re-run."
fi

resolved=$(resolved_version || true)
[ -n "$resolved" ] || warn "Could not read the latest release tag; will reinstall the binary."

step "Detected platform: ${platform_label}"
[ -n "$resolved" ] && step "Resolved version: ${resolved}"

installed=
if have typesafe-jev-mcp; then
  installed=$(version_from_binary "$(command -v typesafe-jev-mcp)" || true)
fi

if [ -n "$resolved" ] && [ -n "$installed" ] && [ "$installed" = "$resolved" ]; then
  step "typesafe-jev-mcp ${resolved} already installed"
else
  if [ -n "$installed" ] && [ -n "$resolved" ]; then
    step "Updating typesafe-jev-mcp from ${installed} to ${resolved}"
  else
    step "Installing typesafe-jev-mcp"
  fi
  download_text "$DIST" | sh
  export PATH="${HOME}/.cargo/bin:${HOME}/.local/bin:${PATH}"
  have typesafe-jev-mcp || die "binary not on PATH; add ~/.cargo/bin or ~/.local/bin and re-run"
fi
bin=$(command -v typesafe-jev-mcp)
step "$bin"

ensure_key
export TYPESAFE_API_KEY_COMMAND=$KEY_COMMAND

[ -n "$claude_bin" ] && place_skill "Claude Code" "${HOME}/.claude/skills"
[ -n "$codex_bin" ] && place_skill Codex "${HOME}/.codex/skills"
[ -n "$opencode_bin" ] && place_skill OpenCode "${XDG_CONFIG_HOME:-${HOME}/.config}/opencode/skills"
[ -n "$agy_bin" ] && place_skill Antigravity "${HOME}/.gemini/antigravity/skills"
[ -d "${HOME}/.cursor" ] && place_skill Cursor "${HOME}/.cursor/skills"

if [ -n "$claude_bin" ]; then
  register "Claude Code" "$claude_bin" mcp add jev -s user \
    -e "TYPESAFE_API_KEY_COMMAND=${KEY_COMMAND}" -- "$bin"
fi
if [ -n "$codex_bin" ]; then
  register Codex "$codex_bin" mcp add jev \
    --env "TYPESAFE_API_KEY_COMMAND=${KEY_COMMAND}" -- "$bin"
fi
if [ -n "$opencode_bin" ]; then
  register OpenCode "$opencode_bin" mcp add jev --global \
    --env "TYPESAFE_API_KEY_COMMAND=${KEY_COMMAND}" -- "$bin"
fi
if [ -n "$agy_bin" ]; then
  register Antigravity "$agy_bin" mcp add \
    -e "TYPESAFE_API_KEY_COMMAND=${KEY_COMMAND}" jev "$bin"
fi
cursor_mcp

step "Restart the agent, then: use evaluate to decide whether this is urgent"
step "Key is not in the agent config; the server runs: ${KEY_COMMAND}"
printf 'typesafe-jev-mcp %s installed successfully.\n' "${resolved:-}"
