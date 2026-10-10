---
name: launch
description: Activate guyb at the projects root and open a project in a new terminal tab. Use when the user says "activate guyb", "start guyb", "let's start guyb", "pick a project", "let's start <project>", "work on <project>", or "I want to work with project <project>" in a session that started at the projects root.
argument-hint: "[optional: project name]"
---

Open a project in its own tab from the projects root. Project name, if given: "$ARGUMENTS".

Rules for the whole flow: never `cd` (use absolute paths), never call the launcher without a name (it would prompt and hang), never print secret values.

## Intent
| User says | Intent | At the projects root | Inside a project |
|---|---|---|---|
| "activate guyb", "start guyb", "guyb" alone, "pick a project" | **activate** | run `guyb:launch` with no project (picker) | say guyb is already active; offer `/guyb:start` |
| "let's start X", "work on X" (X matches a folder under the root) | **start project X** | run `guyb:launch X` (no picker) | offer to open X in a new tab (confirm first) |
| "is guyb updated?", "guyb version", "update guyb" | **plugin question** | compare installed (`~/.claude/plugins/installed_plugins.json`) vs source version, read-only; offer `claude plugin marketplace update guyb; claude plugin update guyb@guyb` (then restart) only with consent | same |
A plugin question never launches anything and never `cd`s. If "start guyb" is ambiguous and a `guyb` folder exists under the root, treat it as **activate**.

1. **Root check.** The root is the folder the session started in (or `$GUYB_ROOT`). If the session started inside a project, stop: say guyb is already active here and offer `/guyb:start` (or, if another project was named, offer to open it in a new tab after confirming).

2. **Check setup (every session, no cache).** Run the read-only check script from `/guyb:setup`, passing the session start folder:
   - PowerShell: `pwsh -NoProfile -File "<dir>/check.ps1" -StartDir "<session start folder>"` (use `powershell` if `pwsh` is missing)
   - bash: `bash "<dir>/check.sh" "<session start folder>"`

   `<dir>`: same resolution as `/guyb:setup`: `${CLAUDE_PLUGIN_ROOT}/skills/setup`, then `<repo>/plugins/guyb/skills/setup` (repo from `~/.claude/plugins/known_marketplaces.json`, `guyb.source.path`). On Windows always use `check.ps1`; `check.sh` is for macOS/Linux. Strip any trailing `\` or `/` from the start folder before passing it (a trailing backslash breaks `pwsh -File` quoting).

   It prints JSON with no secrets: `{version, os, root, repo, blockingFailures, checks:[{id, status: ok|warn|fail|skip, blocking, detail, fix, fixBy}]}`.
   - **`blockingFailures > 0`:** stop. Explain each blocking `fail` in one line and offer its `fix` by `fixBy`: `claude-after-consent` (show the command, run it only after the user agrees), `user` (give the user the `! <command>` to type; you never run logins), `none` (nothing to run). Follow `/guyb:setup`'s rules, then re-run the check.
   - **Warnings** (`warn`, including a missing `gh` login): show them in one short line each and continue.

3. **List projects.** The launcher has a non-interactive list mode: `guyb -List` (PowerShell) / `guyb --list` (bash). Tool shells don't load the profile, so if `guyb` is undefined, dot-source the launcher first (`. <repo>\scripts\launch.ps1` / `source <repo>/scripts/launch.sh`), using `repo` from the check JSON. Set `GUYB_ROOT` to the JSON's `root` for that call. Output is one project per line, tab-separated, most recent first: `name`, absolute path, last activity (ISO UTC), git `y/n`, dirty count, has `.claude/guyb/STATE.md` (or legacy `.claude/STATE.md`) `y/n`.

4. **Pick.** If a project was named, match it to a folder name case-insensitively (a close match gets a one-line confirm; no match: show the list) and go to 5. Otherwise print the full numbered list as text, then ask with AskUserQuestion using the top 4 by recent activity, each described like "last commit 2d ago, 3 uncommitted, has STATE.md". With 4 or fewer projects, all become options. "Other" accepts a name or a number from the printed list.

5. **Launch.** Use only the exact folder name from the `-List` output, quoted, never raw user text: `guyb 'name'` (reject names that don't match a listed folder). In the same tool call as the dot-source. PowerShell opens a Windows Terminal tab (or a new window). bash/zsh: only when `$TMUX` is set; otherwise don't run it, and ask the user to run `guyb 'name'` themselves. The launcher locks the tab title to the project name and colours the tab from it (same name, same colour).

6. **Report.** "Opened `<name>` in a new tab. Switch to it; it runs `/guyb:start`." Stay the launcher: don't brief, spawn agents, or create `.claude/` files for that project from here.
