---
name: setup
description: First-run global setup wizard - git identity, git host (GitHub/GitLab/Bitbucket), cloud (AWS/GCP/Azure), database clients, and other service logins. Installs missing CLIs after confirmation, guides logins, verifies them, and records a no-secrets profile at ~/.claude/guyb/profile.md. Re-run any time to add or fix a provider.
disable-model-invocation: true
argument-hint: "[optional: only one area, e.g. git | cloud | db | other]"
---

Run the guyb global setup. Scope: "$ARGUMENTS" (empty = everything). Work through the sections in order, keeping a todo list. Do this in the main session, not in a subagent, because it needs the user's answers and logins.

## Ground rules (say these to the user once, briefly)
- guyb never stores secret values. Tools keep their own credentials (`gh`, `glab`, `aws`, `gcloud`, `az` each have their own credential store). guyb only records *which* accounts and profiles exist.
- Logins that open a browser or ask for a password are run **by the user** with the `!` prefix, e.g. `! gh auth login`. Never ask the user to paste a token, password, or key into the chat, because the chat transcript is saved. Shell commands typed with `!` are saved too, so values should never appear in them either.
- Every install command is shown and confirmed before it runs.

## 0. Detect (read-only, no questions yet)
Detect the OS and package manager (`winget` on Windows, `brew` on macOS, `apt`/`dnf` on Linux). Then check, in parallel, version and auth status for: `git` (+ `git config --global user.name/user.email`), `gh` (`gh auth status`), `glab` (`glab auth status`), `aws` (`aws configure list-profiles`, `aws sts get-caller-identity`), `gcloud` (`gcloud auth list`, `gcloud config list`), `az` (`az account show`), `psql`, `mysql`, `mongosh`, `redis-cli`, `docker`. Read `~/.claude/guyb/profile.md` if it exists.
Show one compact table: tool | installed | logged in as | notes.

## 1. Ask what the user uses
Ask with multiple-choice questions (multi-select where it makes sense), skipping anything already fully set up unless the user wants to change it:
- Git host(s): GitHub / GitLab (gitlab.com or self-hosted URL) / Bitbucket. Which one is the default for new repos?
- Cloud(s): AWS / Google Cloud / Azure / none. Default region for each.
- Databases: PostgreSQL / MySQL / MongoDB / Redis / other / none. Here guyb only installs the **clients**; connection credentials are per project (`/guyb:creds`).
- Other services with their own CLI login (e.g. Docker Hub, Vercel, Netlify, Stripe, Neon, Supabase, Cloudflare), or global API keys the user wants available in every project.

## 2. Install missing tools (confirm each)
Look up the exact package id first (`winget search <name>` / `brew search <name>`), show the command, and install only after the user says yes. Typical packages: GitHub CLI, GitLab CLI (glab), AWS CLI v2, Google Cloud SDK, Azure CLI, PostgreSQL client (macOS: `libpq`), MySQL client, mongosh. After installing on Windows, tell the user that a new terminal may be needed for PATH changes.

## 3. Git identity and host login
- If `user.name`/`user.email` are not set globally, ask what to use. For GitHub, offer the private no-reply address (`<id>+<user>@users.noreply.github.com`; get the id with `gh api user --jq .id` after login). Set it with `git config --global` after confirmation.
- GitHub: user runs `! gh auth login`. Then `gh auth setup-git` (with consent) so HTTPS pushes use the gh login. Check SSH too (`ssh -T git@github.com`); if no key is registered, prefer HTTPS.
- GitLab: user runs `! glab auth login` (add `--hostname <host>` for self-hosted).
- Bitbucket (no official CLI): the user creates an Atlassian API token for Bitbucket in their Atlassian account settings, then sets **user-level** env vars `BITBUCKET_EMAIL` and `BITBUCKET_API_TOKEN` themselves (Windows: System Properties -> Environment Variables; macOS/Linux: their shell rc or keychain). Verify with an API call that prints only the username.

## 4. Cloud login
- AWS: user runs `! aws configure sso` (preferred) or `! aws configure` with a non-root IAM user. Verify `aws sts get-caller-identity`.
- Google Cloud: user runs `! gcloud auth login` and, for app code, `! gcloud auth application-default login`. Set the default project/region with `gcloud config set` after confirmation. Verify `gcloud config list`.
- Azure: user runs `! az login`. Pick the default subscription (`az account set --subscription <id>` after confirmation). Verify `az account show`.

## 5. Other services and global keys
- Prefer each service's own login command (`vercel login`, `stripe login`, `neonctl auth`, `docker login`, ...); the user runs it with `!`.
- For a raw API key needed in every project, the user stores it as a **user-level environment variable** themselves (same method as Bitbucket above). Record only the variable *name*.

## 6. Permissions
The guyb installer already merged rules for gh, glab, aws, gcloud, and az. If the user added another CLI, offer to add read-only allow rules and destructive-command ask rules for it to `~/.claude/settings.json` (show the diff first).

## 7. Record the profile (no secrets)
Write `~/.claude/guyb/profile.md`:
```md
# guyb profile (no secrets - names and accounts only)
Updated: <date>
## Git
- identity: <name> <email>
- hosts: GitHub (<user>, default) | GitLab (<host>, <user>) | Bitbucket (<workspace>, env BITBUCKET_EMAIL/BITBUCKET_API_TOKEN)
## Cloud
- AWS: profile <p> (account <id>, region <r>) [default]
- GCP: configuration <c> (project <id>, region <r>)
- Azure: subscription <name> (<id>)
## Databases (clients installed)
- psql <ver>, mongosh <ver>
## Other services / global env var names
- vercel (logged in as <user>); OPENAI_API_KEY (user env var)
```

Finish with the table from step 0 updated (all green or what's left), and remind the user that project-specific credentials are added with `/guyb:creds` inside that project.
