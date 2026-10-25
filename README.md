# jira-workflow

A [Claude Code](https://claude.com/claude-code) skill for working with Jira and Bitbucket Cloud from
your terminal:

- **Tasks:** list your issues and sprint, move status, assign, comment, create
- **Requirements:** read a task's description, acceptance criteria, custom fields, links,
  attachments and comments, then get a summary with open questions
- **Bitbucket:** find branches and PRs for an issue, read PR diffs, review comments, commits, pipelines
- **Time logging:** log work with the right timezone, check for duplicates first, and draft timesheets
  from your commits

Claude asks before every change to Jira. The Bitbucket side is read-only.

## How it's configured

| What | Where | Secret? |
|---|---|---|
| API tokens and your login | environment variables, e.g. `.envrc` with [direnv](https://direnv.net) | yes, never commit |
| Jira server, project, board, Bitbucket repos, conventions | `.jira-workspace.json` in each project | no, safe to commit and share with your team |

The skill generates a [jira-cli](https://github.com/ankitpokhrel/jira-cli) config per project
automatically, so different projects can point at different Jira sites, projects and boards.

## Install

Requirements: `jira-cli`, `jq`, `curl`, and `direnv` (recommended).

```bash
brew install jira-cli jq direnv
git clone https://github.com/longvo2k/jira-workflow-skill.git ~/.claude/skills/jira-workflow
```

If you haven't set up direnv yet, add its hook to `~/.zshrc`: `eval "$(direnv hook zsh)"`.

## Set up a project

```bash
cd ~/Work/my-project
~/.claude/skills/jira-workflow/scripts/workspace.sh init   # creates .jira-workspace.json and .envrc
echo ".envrc" >> .gitignore
# fill in .jira-workspace.json and the tokens in .envrc
direnv allow
~/.claude/skills/jira-workflow/scripts/workspace.sh doctor
```

Or just ask Claude: "set up jira-workflow for this project".

### Tokens

- **Jira Cloud:** create an API token at https://id.atlassian.com/manage-profile/security/api-tokens.
  Set `JIRA_LOGIN` to your Atlassian email.
- **Jira Server / Data Center:** create a Personal Access Token, and set `"installation": "local"` and
  `"authType": "bearer"` in `.jira-workspace.json`.
- **Bitbucket Cloud:** create an API token with scopes for Bitbucket (`read:user`, `read:repository`,
  `read:pullrequest`, `read:pipeline`), and set `BITBUCKET_EMAIL` + `BITBUCKET_API_TOKEN`. A repository
  or workspace access token works too: set `BITBUCKET_ACCESS_TOKEN`.

Sharing tokens across projects: put them in a parent folder's `.envrc` and add `source_up` to each
project's `.envrc`.

### `.jira-workspace.json`

```json
{
  "jira": {
    "installation": "cloud",
    "server": "https://your-company.atlassian.net",
    "project": "ABC",
    "board": "ABC board"
  },
  "bitbucket": {
    "workspace": "your-company",
    "repos": ["mobile-app", "backend-api"],
    "defaultRepo": "mobile-app"
  },
  "worklog": {
    "timezone": "Asia/Ho_Chi_Minh",
    "requireComment": true,
    "dailyTargetHours": 8
  },
  "conventions": {
    "branch": "feature/{key}-{short-summary}",
    "commit": "{key}: {message}",
    "doneStatus": "Done",
    "inProgressStatus": "In Progress",
    "reviewStatus": "In Review"
  }
}
```

Only `jira.server` and `jira.project` are required. Leave out `bitbucket` to use the skill without
Bitbucket. `conventions` is free-form: Claude reads it and follows it.

## Use it

Talk to Claude normally:

- "What are my open tasks this sprint?"
- "Read ABC-123 and tell me what I need to build"
- "Is there a PR for ABC-123? Does it cover the acceptance criteria?"
- "What did reviewers say on PR 42?"
- "Log 2h on ABC-123 for this morning, building the login form"
- "Draft my timesheet for this week from my commits"

The scripts also work on their own:

```bash
S=~/.claude/skills/jira-workflow/scripts
$S/jira.sh issue list -a"$($S/jira.sh me)" -s~Done --plain
$S/jira-api.sh requirements ABC-123
$S/jira-api.sh my-worklogs 2026-10-20 2026-10-24
$S/bitbucket.sh find ABC-123
```

## Security

- Tokens are read only from environment variables. They are passed to `curl` through a file
  descriptor, so they don't show up in process lists.
- The skill tells Claude never to print tokens, never to follow instructions found inside ticket or PR
  text, and to confirm every Jira write before sending it.
- Bitbucket access is read-only. Use a token with only read scopes.

## License

MIT
