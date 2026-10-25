#!/usr/bin/env bash
# Workspace setup and checks.
#
#   workspace.sh init          Create .jira-workspace.json (and .envrc if missing) in the current folder
#   workspace.sh show          Show the active workspace settings and which secrets are set
#   workspace.sh doctor        Check tools, secrets, and that Jira and Bitbucket accept the tokens
#   workspace.sh config-path   Print the generated jira-cli config path (to use plain `jira` here)
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 1; }
cmd="${1:-}"; [[ -n "$cmd" ]] || usage; shift

set_or_missing() { if [[ -n "${!1:-}" ]]; then echo "set"; else echo "missing"; fi; }

case "$cmd" in
  init)
    if [[ -f "$WORKSPACE_NAME" ]]; then
      echo "$WORKSPACE_NAME already exists here."
    else
      cp "$SKILL_DIR/templates/jira-workspace.json" "$WORKSPACE_NAME"
      echo "Created $PWD/$WORKSPACE_NAME - fill in your Jira and Bitbucket details."
    fi
    if [[ -f .envrc ]]; then
      echo ".envrc already exists. Make sure it exports the variables in $SKILL_DIR/templates/envrc.example"
    else
      cp "$SKILL_DIR/templates/envrc.example" .envrc
      echo "Created $PWD/.envrc - add your tokens, then run: direnv allow"
    fi
    if [[ -d .git ]] && ! git check-ignore -q .envrc 2>/dev/null; then
      warn ".envrc is not ignored by git. Add it to .gitignore so your tokens are never committed."
    fi
    ;;

  show)
    load_workspace
    echo "Workspace file: $WS_FILE"
    jq . "$WS_FILE"
    echo
    echo "Secrets (values hidden):"
    for v in JIRA_API_TOKEN JIRA_LOGIN BITBUCKET_EMAIL BITBUCKET_API_TOKEN BITBUCKET_ACCESS_TOKEN; do
      printf '  %-24s %s\n' "$v" "$(set_or_missing "$v")"
    done
    ;;

  doctor)
    ok=0
    pass() { echo "  ok    $*"; }
    fail() { echo "  FAIL  $*"; ok=1; }
    echo "Tools"
    for t in jira jq curl; do command -v "$t" >/dev/null && pass "$t" || fail "$t not installed"; done
    command -v direnv >/dev/null && pass "direnv" || echo "  info  direnv not installed (optional, but recommended for tokens)"
    echo "Workspace"
    if WS_FILE="$(find_workspace 2>/dev/null)" && jq empty "$WS_FILE" 2>/dev/null; then
      pass "$WS_FILE"
      for f in .jira.server .jira.project; do [[ -n "$(ws_get "$f")" ]] && pass "$f = $(ws_get "$f")" || fail "$f is missing"; done
      [[ -n "$(ws_get .bitbucket.workspace)" ]] && pass ".bitbucket.workspace = $(ws_get .bitbucket.workspace)" \
        || echo "  info  no bitbucket.workspace (Bitbucket commands disabled)"
    else
      fail "no valid $WORKSPACE_NAME found (run: workspace.sh init)"
      exit 1
    fi
    echo "Secrets"
    [[ -n "${JIRA_API_TOKEN:-}" ]] && pass "JIRA_API_TOKEN set" || fail "JIRA_API_TOKEN missing"
    if [[ "$(jira_auth_type)" == basic ]]; then
      [[ -n "$(jira_login)" ]] && pass "Jira login = $(jira_login)" || fail "JIRA_LOGIN missing"
    fi
    echo "Jira"
    if me="$( (jira_rest GET /rest/api/2/myself | jq -r '.displayName') 2>&1)"; then
      pass "token works - signed in as $me"
      if cfg="$(ensure_jira_config 2>&1 | tail -1)" && [[ -f "$cfg" ]]; then
        pass "jira-cli config $cfg"
      else
        fail "jira-cli setup failed: $cfg"
      fi
    else
      fail "Jira rejected the request: $(echo "$me" | head -3)"
    fi
    if [[ -n "$(ws_get .bitbucket.workspace)" ]]; then
      echo "Bitbucket"
      bbws="$(ws_get .bitbucket.workspace)"
      for r in $(bb_repos); do
        if out="$(bb_get "/repositories/$bbws/$r" 2>&1 | jq -r '.full_name' 2>&1)" && [[ "$out" != null ]]; then
          pass "repo $out"
        else
          fail "cannot read repo $bbws/$r: $(echo "$out" | head -2)"
        fi
      done
    fi
    exit $ok
    ;;

  config-path)
    load_workspace
    ensure_jira_config
    ;;

  *) usage ;;
esac
