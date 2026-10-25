#!/usr/bin/env bash
# Run jira-cli with this project's settings.
# Usage: jira.sh <any jira-cli arguments>
#   jira.sh issue list -a"$(jira.sh me)" -s~Done --plain
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

load_workspace
cfg="$(ensure_jira_config)"
JIRA_CONFIG_FILE="$cfg" exec jira "$@"
