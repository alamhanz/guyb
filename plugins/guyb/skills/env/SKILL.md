---
name: env
description: Set up this project's local dev environment after consent - Python venv/dependencies, Node dependencies, Docker image pull. Project-local only; runtimes and Docker itself are shown as commands for the user to run.
disable-model-invocation: true
argument-hint: "[python | node | docker | all]"
---

Set up the local dev environment for the project in the current directory. Scope: "$ARGUMENTS" (empty = every gap found). Do this inline in the main session, not in a subagent: it needs a consent turn and the commands are short.

## Steps
1. Detect. Rerun the briefing script the way `/guyb:start` does (`${CLAUDE_PLUGIN_ROOT}/skills/start/brief.ps1` or `brief.sh`, then `<repo>/plugins/guyb/skills/start`) and read its `env:` lines. Also read the project files (`pyproject.toml`, `requirements*.txt`, `.python-version`, `uv.lock`, `package.json`, lockfiles, `compose.yaml`). Never read `.env` values.
2. Plan. Show a table: step | command | what it runs/writes. Skip ecosystems with no gaps.
3. Consent. Ask before running anything, and say that install scripts can run arbitrary code (npm `postinstall`, Python build backends).
4. Run only project-local steps, after consent:
   - python: `uv sync` when `uv.lock` or `[tool.uv]` exists and `uv` is installed; else `python -m venv .venv` (`py -3 -m venv .venv` on Windows without `python`), then install with the venv's own pip: `.venv/bin/pip` (macOS, Linux) or `.venv/Scripts/pip` (Windows; Git Bash accepts the same path, PowerShell `.venv\Scripts\pip.exe`), `install -r requirements.txt` or `-e .`. Check which of the two exists; do not assume. Activation is not needed.
   - node: `npm ci`; `pnpm install --frozen-lockfile`; `yarn install --immutable`; `bun install --frozen-lockfile`. With no lockfile, ask before `npm install`.
   - docker: `docker compose pull` only (podman: `podman compose pull`). Never `up`, never `login`; for private registries the user runs `! docker login` themselves.
5. Runtime gaps are not fixed here. For a Python or Node version mismatch, or a missing `uv`, docker or package manager, print the command for the user to run with `!` (`uv python install <ver>` everywhere; fnm: `winget install Schniz.fnm` / `brew install fnm` / the fnm install script on Linux, then `fnm install <ver>`; uv: `winget install astral-sh.uv` / `brew install uv` / `curl -LsSf https://astral.sh/uv/install.sh | sh`; Docker: `winget install Docker.DockerDesktop` / `brew install --cask docker` / `sudo apt install docker.io docker-compose-v2`; or podman). Pick the line for the OS in the script's `os` field. Docker Desktop on Windows needs admin and WSL2 and has license terms for larger companies.
6. Rules: no sudo; no global installs (`npm -g`, pip outside a venv, `--user`); write nothing outside the project except the created `.venv` and `node_modules`; report if a lockfile changed (`git status --short`); never print secret values.
7. Verify. Rerun the briefing script and report one line: what was set up, what is left for the user. A failing build or test afterwards goes to `guyb:implementer`.
