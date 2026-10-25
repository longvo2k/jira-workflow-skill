#!/usr/bin/env bash
# Jira reads that jira-cli doesn't cover well. All commands are read-only.
#
#   jira-api.sh requirements KEY          Everything needed to start a task: description,
#                                         custom fields (acceptance criteria, story points...),
#                                         parent, subtasks, links, attachments, all comments
#   jira-api.sh attachment URL OUTFILE    Download an attachment (mockups, specs)
#   jira-api.sh transitions KEY           Statuses this issue can move to
#   jira-api.sh worklogs KEY              Time logged on an issue
#   jira-api.sh my-worklogs [FROM] [TO]   My time logged between dates (YYYY-MM-DD, default today)
#   jira-api.sh myself                    Who the token belongs to
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

load_workspace

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 1; }

cmd="${1:-}"; [[ -n "$cmd" ]] || usage; shift

case "$cmd" in
  requirements)
    key="${1:?issue key required}"
    jira_rest GET "/rest/api/2/issue/$(urlencode "$key")?expand=names&fields=*all" | jq -r '
      def s: if type == "string" or type == "number" or type == "boolean" then tostring
             elif type == "object" then ((.value // .name // .displayName // .key // empty) | tostring)
             elif type == "array" then (map(s) | map(select(. != "")) | join(", "))
             else empty end;
      . as $i | ($i.names // {}) as $names | $i.fields as $f |
      "\($i.key): \($f.summary)",
      "Type: \($f.issuetype.name // "-") | Status: \($f.status.name // "-") | Priority: \($f.priority.name // "-")",
      "Assignee: \($f.assignee.displayName // "Unassigned") | Reporter: \($f.reporter.displayName // "-")",
      "Labels: \(($f.labels // []) | join(", ") | if . == "" then "-" else . end) | Components: \(($f.components // []) | map(.name) | join(", ") | if . == "" then "-" else . end)",
      "Fix versions: \(($f.fixVersions // []) | map(.name) | join(", ") | if . == "" then "-" else . end)",
      "Time: estimate \($f.timetracking.originalEstimate // "-"), logged \($f.timetracking.timeSpent // "-"), remaining \($f.timetracking.remainingEstimate // "-")",
      (if $f.parent then "Parent: \($f.parent.key) \($f.parent.fields.summary // "")" else empty end),
      "",
      "## Description",
      ($f.description // "(empty)"),
      "",
      "## Other fields",
      ([$f | to_entries[] | select(.key | startswith("customfield_")) | select(.value != null)
        | {name: ($names[.key] // .key), value: (.value | s)} | select(.value != "" and .value != "{}")]
        | if length == 0 then "(none)" else (.[] | "- \(.name): \(.value)") end),
      "",
      "## Subtasks",
      (($f.subtasks // []) | if length == 0 then "(none)" else (.[] | "- \(.key) [\(.fields.status.name)] \(.fields.summary)") end),
      "",
      "## Linked issues",
      (($f.issuelinks // []) | if length == 0 then "(none)" else (.[] |
        if .outwardIssue then "- \(.type.outward) \(.outwardIssue.key) [\(.outwardIssue.fields.status.name)] \(.outwardIssue.fields.summary)"
        else "- \(.type.inward) \(.inwardIssue.key) [\(.inwardIssue.fields.status.name)] \(.inwardIssue.fields.summary)" end) end),
      "",
      "## Attachments",
      (($f.attachment // []) | if length == 0 then "(none)" else (.[] | "- \(.filename) (\(.mimeType), \(.size) bytes) \(.content)") end),
      "",
      "## Comments",
      (($f.comment.comments // []) | if length == 0 then "(none)" else (.[] | "--- \(.author.displayName) at \(.created[0:16])\n\(.body)") end)
    '
    ;;

  attachment)
    url="${1:?attachment URL required}"; out="${2:?output file required}"
    [[ "$url" == "$(jira_server)"* ]] || die "attachment URL must be on $(jira_server)"
    path="${url#"$(jira_server)"}"
    mkdir -p "$(dirname "$out")"
    jira_rest GET "$path" -H "Accept: */*" -o "$out"
    echo "Saved $out"
    ;;

  transitions)
    key="${1:?issue key required}"
    jira_rest GET "/rest/api/2/issue/$(urlencode "$key")/transitions" \
      | jq -r '.transitions[] | "- \(.name) -> \(.to.name)"'
    ;;

  worklogs)
    key="${1:?issue key required}"
    jira_rest GET "/rest/api/2/issue/$(urlencode "$key")/worklog" | jq -r '
      .worklogs | if length == 0 then "(no time logged)" else
      (.[] | "\(.started[0:16]) \(.timeSpent) by \(.author.displayName)\(if .comment then " - " + (.comment | tostring | gsub("\n"; " ")) else "" end)"),
      "Total: \((map(.timeSpentSeconds) | add) / 3600 * 100 | round / 100)h" end'
    ;;

  my-worklogs)
    today="$(date +%Y-%m-%d)"
    from="${1:-$today}"; to="${2:-$from}"
    me="$(jira_rest GET /rest/api/2/myself)"
    my_id="$(jq -r '.accountId // .key // .name' <<<"$me")"
    jql="worklogAuthor = currentUser() AND worklogDate >= \"$from\" AND worklogDate <= \"$to\""
    if [[ "$(jira_installation)" == cloud ]]; then
      issues="$(jira_rest GET "/rest/api/3/search/jql?jql=$(urlencode "$jql")&fields=summary&maxResults=100")"
    else
      issues="$(jira_rest GET "/rest/api/2/search?jql=$(urlencode "$jql")&fields=summary&maxResults=100")"
    fi
    all="[]"
    for key in $(jq -r '.issues[].key' <<<"$issues"); do
      summary="$(jq -r --arg k "$key" '.issues[] | select(.key == $k) | .fields.summary' <<<"$issues")"
      logs="$(jira_rest GET "/rest/api/2/issue/$key/worklog" | jq --arg id "$my_id" --arg from "$from" --arg to "$to" \
        --arg key "$key" --arg summary "$summary" '
        [.worklogs[] | select((.author.accountId // .author.key // .author.name) == $id)
         | select(.started[0:10] >= $from and .started[0:10] <= $to)
         | {date: .started[0:10], time: .started[11:16], key: $key, summary: $summary,
            spent: .timeSpent, seconds: .timeSpentSeconds, comment: (.comment // "" | tostring | gsub("\n"; " "))}]')"
      all="$(jq -s 'add' <(echo "$all") <(echo "$logs"))"
    done
    jq -r '
      if length == 0 then "(no time logged in this range)" else
      (sort_by(.date, .time) | group_by(.date)[] |
        "\(.[0].date)  total \((map(.seconds) | add) / 3600 * 100 | round / 100)h",
        (.[] | "  \(.time) \(.spent)  \(.key) \(.summary)\(if .comment != "" then "  - " + .comment else "" end)")),
      "Range total: \((map(.seconds) | add) / 3600 * 100 | round / 100)h" end' <<<"$all"
    ;;

  myself)
    jira_rest GET /rest/api/2/myself | jq -r '"\(.displayName) <\(.emailAddress // "-")> id=\(.accountId // .name) tz=\(.timeZone // "-")"'
    ;;

  *) usage ;;
esac
