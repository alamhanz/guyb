---
name: report-issue
description: Report a guyb failure (script, skill, or step) to the guyb GitHub repo. Collects environment and error output, redacts personal data, shows the draft, and files only with the user's explicit yes. Use after a guyb failure or when the user asks to report a bug.
---

Read-only except for the GitHub issue the user approves. Never change the user's project.

1. Collect:
   - guyb version (installed plugin.json `version`), OS and version, shell and version (pwsh, powershell, bash, zsh), `claude --version`, terminal if known.
   - What failed: guyb script, skill, or step; the command; exit code; the error output trimmed to the relevant ~40 lines.
   - The workaround the session used, if any.
2. Redact before showing anything:
   - Home path and username become `~` and `<user>`; project names and paths become `<project>` unless the user says keep; hostnames, emails, tokens, and every env var value are removed.
   - Never include `.env` content, code from the user's project, or file contents beyond guyb's own output. guyb-repo paths may stay.
3. Dedupe: `gh issue list -R alamhanz/guyb --search "<key words>" --state all --limit 5`. If a likely match exists, show it and offer to comment on it instead of opening a new issue.
4. Draft title and body, show them in full, and ask for an explicit yes. State that the repo is PUBLIC. Without a yes, file nothing.

   Body sections: Summary; Environment (table); Steps / command; Error output (fenced); Workaround used; guyb version.
5. File, after the yes:
   - Write the body to a temp file. New issue: `gh issue create -R alamhanz/guyb --title "<title>" --body-file <file>`; add `--label platform --label bug` only for labels listed by `gh label list -R alamhanz/guyb`. Duplicate: `gh issue comment <n> -R alamhanz/guyb --body-file <file>`.
   - If `gh` is missing or not authenticated: give a prefilled `https://github.com/alamhanz/guyb/issues/new?title=<enc>&body=<enc>` URL, URL-encoded and under ~6000 chars (truncate the log first), for the user to open.
   - Delete the temp file. Report the issue or comment URL.
