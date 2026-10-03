---
name: creds
description: Set up project-specific credentials - finds which env vars/secrets/cloud accounts this project needs, makes sure .env is gitignored, has the user add values to .env themselves, verifies they work without printing them, and records the names in .claude/CLAUDE.md.
argument-hint: "[optional: what is needed, e.g. 'postgres for staging' or 'STRIPE_SECRET_KEY']"
---

Set up project-specific credentials for the project in the current directory. Request: "$ARGUMENTS" (empty = detect what the project needs). Do this in the main session; it needs the user.

## Rules
- **Never ask the user to paste a secret into the chat**, and never put one in a `!` command. Both end up in the saved transcript.
- **Never print secret values.** Check names only, e.g. `grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' .env | tr -d =`. Never `cat .env`.
- Values live in the project's **gitignored `.env`**. `.env.example` (committed) lists the same names with placeholder values.
- Cloud accounts aren't put in `.env`: use a named CLI profile instead (below).

## 1. Find what is needed
If the request names it, use that. Otherwise scan the project for env var references and config: `process.env.X`, `import.meta.env.X`, `os.environ[...]`, `os.getenv(...)`, `Deno.env.get`, `env("X")` in Prisma, `${X}` in docker-compose / serverless / terraform files, `.env.example`, framework config files. Compare with the names already in `.env` (names only). Show a table: name | used in | in .env? | in .env.example?

## 2. Make .env safe first
- `.gitignore` contains `.env` and `.env.*` with `!.env.example` (add any missing lines).
- `git ls-files | grep -E '(^|/)\.env'`: if a real `.env` is tracked, stop and tell the user. It must be removed from git (`git rm --cached .env`) and **the leaked values rotated**, since they're in history.
- Create or update `.env.example` with every needed name and a placeholder or description (no real values).

## 3. The user adds the values
Tell the user exactly which lines to add and where to get each value (e.g. "Neon console -> Connection string, pooled"). They open `.env` in their own editor (e.g. `! code .env` or `! notepad .env`, which opens the file without exposing its contents) and save. Wait for them to say done.

## 4. Cloud accounts for this project
If the project uses a cloud account different from the global default in `~/.claude/guyb/profile.md`:
- AWS: user runs `! aws configure sso --profile <project>-<env>`; record the profile name.
- GCP: `gcloud config configurations create <project>-<env>` (after confirmation), then the user runs `! gcloud auth login` and you set project/region in that configuration.
- Azure: record the subscription id; commands pass `--subscription <id>`.
- Different git identity for this repo (e.g. a work email): `git config user.email ...` (local, after confirmation).

## 5. Verify without printing
Run a harmless check that loads the env without echoing it, e.g. bash: `set -a; . ./.env; set +a; psql "$DATABASE_URL" -tAc 'select 1'`, an API "whoami" call that prints only the account name, or the project's own health/test command. Report pass/fail per credential.

## 6. Record names in the project config
Add or update a `## Credentials` section in `.claude/CLAUDE.md` with names and locations only:
```md
## Credentials (names only - values live in .env, which is gitignored)
- DATABASE_URL: Postgres (Neon, staging), .env - verified <date>
- STRIPE_SECRET_KEY: Stripe test mode, .env - verified <date>
- AWS profile: myapp-staging (account 1234..., ap-southeast-1)
```
Report what was added, what was verified, and anything still missing.
