#!/usr/bin/env bash
# Shared helpers for the jira-workflow scripts.
# Secrets come from the environment (for example via direnv).
# Per-project settings come from .jira-workspace.json (no secrets in it).

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_NAME=".jira-workspace.json"
WS_FILE="${WS_FILE:-}"

die() { echo "error: $*" >&2; exit 1; }
warn() { echo "warning: $*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is not installed. $2"; }

need jq "Install it with: brew install jq"

# Find .jira-workspace.json in the current folder or a parent folder.
# JIRA_WORKSPACE_FILE overrides the search.
find_workspace() {
  if [[ -n "${JIRA_WORKSPACE_FILE:-}" ]]; then
    [[ -f "$JIRA_WORKSPACE_FILE" ]] || { echo "error: JIRA_WORKSPACE_FILE points to a missing file: $JIRA_WORKSPACE_FILE" >&2; return 1; }
    echo "$JIRA_WORKSPACE_FILE"
    return
  fi
  local dir="$PWD"
  while :; do
    if [[ -f "$dir/$WORKSPACE_NAME" ]]; then echo "$dir/$WORKSPACE_NAME"; return; fi
    [[ "$dir" == "/" ]] && break
    dir="$(dirname "$dir")"
  done
  echo "error: no $WORKSPACE_NAME in $PWD or any parent folder." >&2
  echo "Create one with: $SKILL_DIR/scripts/workspace.sh init" >&2
  return 1
}

load_workspace() {
  [[ -n "$WS_FILE" ]] && return
  WS_FILE="$(find_workspace)" || exit 1
  jq empty "$WS_FILE" 2>/dev/null || die "$WS_FILE is not valid JSON"
}

# ws_get '.jira.project' -> value or empty string
ws_get() { jq -r "$1 // empty" "$WS_FILE"; }

urlencode() { jq -rn --arg v "$1" '$v | @uri'; }

# ---------- Jira ----------

jira_server() {
  local s; s="$(ws_get .jira.server)"
  [[ -n "$s" ]] || die "jira.server is missing in $WS_FILE"
  echo "${s%/}"
}
jira_installation() { local v; v="$(ws_get .jira.installation)"; echo "${v:-cloud}" | tr '[:upper:]' '[:lower:]'; }
jira_auth_type() {
  local v; v="$(ws_get .jira.authType)"
  if [[ -z "$v" ]]; then [[ "$(jira_installation)" == local ]] && v=bearer || v=basic; fi
  echo "$v"
}
jira_login() { echo "${JIRA_LOGIN:-$(ws_get .jira.login)}"; }

require_jira_env() {
  [[ -n "${JIRA_API_TOKEN:-}" ]] || die "JIRA_API_TOKEN is not set. Add it to your .envrc and run: direnv allow"
  if [[ "$(jira_auth_type)" == basic && -z "$(jira_login)" ]]; then
    die "JIRA_LOGIN is not set (your Jira email). Add it to your .envrc or set jira.login in $WS_FILE"
  fi
}

# Generate a jira-cli config for this workspace (once, or when the workspace file changes).
# Prints the config path.
ensure_jira_config() {
  need jira "Install it with: brew install jira-cli"
  require_jira_env
  local key dir cfg project board
  key="$(printf '%s' "$WS_FILE" | shasum | cut -c1-12)"
  dir="${XDG_CONFIG_HOME:-$HOME/.config}/jira-workflow"
  cfg="$dir/$key.yml"
  if [[ ! -f "$cfg" || "$WS_FILE" -nt "$cfg" ]]; then
    project="$(ws_get .jira.project)"
    board="$(ws_get .jira.board)"
    [[ -n "$project" ]] || die "jira.project is missing in $WS_FILE"
    mkdir -p "$dir"
    local args=(init --installation "$(jira_installation)" --server "$(jira_server)"
      --login "$(jira_login)" --auth-type "$(jira_auth_type)" --project "$project" --force)
    [[ -n "$board" ]] && args+=(--board "$board")
    echo "Setting up jira-cli for $WS_FILE ..." >&2
    JIRA_CONFIG_FILE="$cfg" jira "${args[@]}" </dev/null >&2 \
      || die "jira init failed. Check jira.server, jira.project, jira.board and your token."
  fi
  echo "$cfg"
}

# jira_rest METHOD /rest/api/2/... [curl args...]
# The token goes through a curl config on a file descriptor, so it never shows in `ps`.
jira_rest() {
  require_jira_env
  local method="$1" path="$2"; shift 2
  local authcfg
  if [[ "$(jira_auth_type)" == bearer ]]; then
    authcfg="$(printf 'header = "Authorization: Bearer %s"\n' "$JIRA_API_TOKEN")"
  else
    authcfg="$(printf 'user = "%s:%s"\n' "$(jira_login)" "$JIRA_API_TOKEN")"
  fi
  curl -sS -L --fail-with-body -X "$method" -K <(echo "$authcfg") \
    -H "Accept: application/json" -H "Content-Type: application/json" \
    "$(jira_server)$path" "$@"
}

# ---------- Bitbucket Cloud ----------

BB_API="${BITBUCKET_API_URL:-https://api.bitbucket.org/2.0}"

bb_workspace() {
  local w; w="$(ws_get .bitbucket.workspace)"
  [[ -n "$w" ]] || die "bitbucket.workspace is missing in $WS_FILE"
  echo "$w"
}
bb_default_repo() { local r; r="$(ws_get .bitbucket.defaultRepo)"; [[ -n "$r" ]] || r="$(ws_get '.bitbucket.repos[0]')"; echo "$r"; }
bb_repos() { jq -r '.bitbucket.repos // [] | .[]' "$WS_FILE"; }

bb_authcfg() {
  if [[ -n "${BITBUCKET_ACCESS_TOKEN:-}" ]]; then
    printf 'header = "Authorization: Bearer %s"\n' "$BITBUCKET_ACCESS_TOKEN"
  elif [[ -n "${BITBUCKET_API_TOKEN:-}" ]]; then
    local user="${BITBUCKET_EMAIL:-${BITBUCKET_USERNAME:-}}"
    [[ -n "$user" ]] || die "BITBUCKET_EMAIL is not set (needed with BITBUCKET_API_TOKEN)"
    printf 'user = "%s:%s"\n' "$user" "$BITBUCKET_API_TOKEN"
  else
    die "No Bitbucket token. Set BITBUCKET_EMAIL + BITBUCKET_API_TOKEN, or BITBUCKET_ACCESS_TOKEN, in your .envrc"
  fi
}

# bb_get /repositories/... [curl args...]  (path is relative to the 2.0 API, or a full URL)
bb_get() {
  local path="$1"; shift
  local url="$path"
  [[ "$url" == http* ]] || url="$BB_API$path"
  local authcfg; authcfg="$(bb_authcfg)"
  curl -sS -L --fail-with-body -K <(echo "$authcfg") "$url" "$@"
}
