# guyb benchmark

Measures what guyb costs and what it saves compared with plain Claude Code, on three small coding tasks. It spends real money. CI never runs it (it lives outside `tests/`).

## What it measures

Per run: pass/fail against hidden acceptance tests, wall seconds, `total_cost_usd`, tokens, turns, subagents spawned.

| arm | setup |
|---|---|
| A | plain Claude Code, no guyb, `--model opus` |
| B | plain Claude Code, no guyb, `--model sonnet` |
| C | guyb from this working tree (`--plugin-dir plugins/guyb`), `--model opus` orchestrator; subagents pick their own models |

Tasks (`bench/tasks/<name>/prompt.md` plus `acceptance.test.js`, copied into the project only after the run so the agent never sees it):

- `small`: one-file bug fix (`slugify`).
- `medium`: one feature plus tests (`truncate`).
- `parallel`: two independent features in separate modules (`csv.js`, `duration.js`), where guyb waves should help.

The fixture (`bench/fixture`) is a dependency-free Node project tested with `node --test`. Each run gets a fresh temp copy with `git init` and one commit. A run passes when its acceptance file passes; `full_suite_passed` also records the whole `node --test`.

## Prerequisites

`claude` CLI logged in (subscription or API key), Node >= 18, git, bash (Git Bash, macOS, Linux). `jq` is not needed. `timeout`/`gtimeout` is used if present.

## Commands

```
bash bench/run.sh --dry-run                       # check prerequisites, print commands, spend nothing
bash bench/run.sh                                 # all tasks, arms A,B,C, 2 repeats, $1.00 per run, $10 total cap
bash bench/run.sh --tasks parallel --arms A,C --repeats 3 --budget 2 --total 15
node bench/summarize.js                           # newest bench/results/*.jsonl (or pass a file)
```

Options: `--tasks`, `--arms`, `--repeats`, `--budget` (per run, `--max-budget-usd`), `--total` (cap), `--timeout`, `--out`. Env: `BENCH_MODEL_A/B/C` override the model aliases.

## Cost warning

The default plan is 18 runs. Opus runs with guyb can approach the per-run budget. Before each run the script stops if spent-so-far plus the per-run budget could exceed `--total`, so the default cap usually ends the run early; runs go repeat by repeat (task, then arm) so every arm stays balanced. `--max-budget-usd` is checked between turns, so a run can overshoot it slightly. A run that hits its budget is recorded as an error, usually failing.

## What is counted

Verified with one paid probe (sonnet main thread, one haiku subagent, cost $0.073):

- `total_cost_usd` includes subagent runs: it equaled the sum of `modelUsage[*].costUSD` across both models. Records carry `cost_includes_subagents` (true when several models are present and the sum matches).
- Top-level `usage` and `num_turns` cover the main thread only (the haiku tokens were missing from `usage`). Records therefore store `tokens_all_models` (summed from `modelUsage`) and `usage_top_level` separately; use the former.
- `subagent_stats.spawned` is recorded as `subagents_spawned`.
- Cost is the list-price estimate the CLI reports; on a subscription it is not your bill.

## Isolation and permissions

- `--setting-sources project`: user and local settings are not loaded, so your installed guyb plugin (enabled in user settings) is absent from A and B. Checked: the init event lists no guyb agents or hook for A, and lists guyb agents plus the SessionStart orchestrator hook for C (`--plugin-dir` works in `-p` mode). The project scope is the empty temp dir.
- `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1` and `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` for all arms: without them `~/.claude/CLAUDE.md` still leaked into the session. A clean `CLAUDE_CONFIG_DIR` was rejected because it drops the login on most setups. `--bare` was rejected because it skips plugin hooks (C would lose the orchestrator) and needs an API key.
- `--strict-mcp-config` with no MCP config: same tool surface for every arm.
- `--permission-mode acceptEdits --permission-prompts none` plus `--allowedTools` for node, git and a few read/list shell commands (Bash and PowerShell forms). Edits are auto-accepted only inside the project directory; anything else that would prompt is denied (checked: `curl` was denied). This is not a sandbox: allowed shell commands can still read elsewhere. `permission_denials` is recorded per run; a high count in one arm means the allow-list, not the model, shaped that run.
- `--no-session-persistence`: no transcripts left behind.

## Reading results

`node bench/summarize.js` prints, per task, mean cost, mean wall time and pass rate per arm, then C vs A and C vs B as percent change (negative wall time is a saving). Look at pass rate first: a cheaper or faster arm that fails is not a win. The hypothesis (cost up a little, time down on average) can fail; the table reports whatever happened.

## Known limitations

- Tiny n (default 2 per cell). One slow or lucky run moves a mean a lot; use more repeats for anything you intend to quote.
- Model aliases and prices drift; `models` in each record shows what actually ran. Re-run A and B alongside C, never compare across dates.
- Prompt caching: later runs may hit warm caches, and the large guyb prompt caches differently than a bare session. Wall time also depends on API load.
- The orchestrator in C is opus, so a guyb advantage on `small` is unlikely; the interesting cell is `parallel`.
- Tasks are small and synthetic; guyb is built for larger, multi-step work, so these results understate or overstate it in unknown directions.
- `--output-format json` gives totals only; there is no per-subagent timeline.
