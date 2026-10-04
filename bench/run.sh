#!/usr/bin/env bash
# guyb benchmark runner. SPENDS REAL MONEY unless --dry-run. See bench/README.md. Not run by CI.
# Targets bash 3.2 (macOS), GNU/BSD tools, Git Bash. Needs: claude (logged in), node >= 18, git.
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)

tasks="small,medium,parallel"
arms="A,B,C"
repeats=2
per_run=1.00
total_cap=10
dry=0
timeout_s=1200
out=""

usage() {
  cat <<'U'
Usage: bash bench/run.sh [options]
  --tasks LIST      comma list of: small,medium,parallel (default all)
  --arms LIST       comma list of: A,B,C (default all)
  --repeats N       runs per task and arm (default 2)
  --budget USD      --max-budget-usd per run (default 1.00)
  --total USD       stop before total spend could exceed this (default 10)
  --timeout SEC     kill a run after SEC seconds if timeout(1) exists (default 1200)
  --out FILE        results file (default bench/results/<timestamp>.jsonl)
  --dry-run         check prerequisites and print commands; spend nothing
Arms: A = plain, opus; B = plain, sonnet; C = guyb (this repo's working tree), opus orchestrator.
Env overrides: BENCH_MODEL_A, BENCH_MODEL_B, BENCH_MODEL_C (default opus, sonnet, opus).
U
}

die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --tasks|--arms|--repeats|--budget|--total|--timeout|--out)
      [ $# -ge 2 ] || die "$1 needs a value" ;;
  esac
  case "$1" in
    --tasks) tasks=$2; shift 2 ;;
    --arms) arms=$2; shift 2 ;;
    --repeats) repeats=$2; shift 2 ;;
    --budget) per_run=$2; shift 2 ;;
    --total) total_cap=$2; shift 2 ;;
    --timeout) timeout_s=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    --dry-run) dry=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$repeats" in ''|*[!0-9]*) die "--repeats must be a positive integer" ;; esac
[ "$repeats" -ge 1 ] || die "--repeats must be a positive integer"
num_ok() { case "$1" in ''|*[!0-9.]*|*.*.*) return 1 ;; esac; return 0; }
num_ok "$per_run" || die "--budget must be a number"
num_ok "$total_cap" || die "--total must be a number"
case "$timeout_s" in ''|*[!0-9]*) die "--timeout must be an integer" ;; esac

IFS=, read -r -a task_list <<<"$tasks"
IFS=, read -r -a arm_list <<<"$arms"
for t in "${task_list[@]}"; do [ -f "$here/tasks/$t/prompt.md" ] || die "unknown task: $t"; done
for a in "${arm_list[@]}"; do case "$a" in A|B|C) ;; *) die "unknown arm: $a" ;; esac; done

model_a=${BENCH_MODEL_A:-opus}
model_b=${BENCH_MODEL_B:-sonnet}
model_c=${BENCH_MODEL_C:-opus}

# Paths handed to native Windows programs (claude, node) must be mixed C:/... form under Git Bash.
win() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# Least privilege that works in -p mode: edits only inside the cwd (acceptEdits), prompts auto-denied,
# no user/local settings (setting-sources project), no MCP, and only these shell commands pre-approved.
allowed=(
  "Bash(node *)" "Bash(git *)" "Bash(ls *)" "Bash(cat *)" "Bash(grep *)" "Bash(mkdir *)" "Bash(cd *)"
  "Bash(pwd)" "Bash(echo *)" "Bash(head *)" "Bash(tail *)" "Bash(wc *)"
  "PowerShell(node *)" "PowerShell(git *)" "PowerShell(Get-ChildItem *)" "PowerShell(Get-Content *)"
  "PowerShell(New-Item *)" "PowerShell(Set-Location *)"
)

allowed_csv=$(IFS=,; echo "${allowed[*]}")

build_cmd() { # arm model -> sets cmd array
  cmd=(claude -p --model "$2" --output-format json --setting-sources project --strict-mcp-config
       --permission-mode acceptEdits --permission-prompts none --max-budget-usd "$per_run"
       --no-session-persistence --allowedTools "$allowed_csv")
  if [ "$1" = C ]; then cmd+=(--plugin-dir "$(win "$repo/plugins/guyb")"); fi
}
model_for() { case "$1" in A) echo "$model_a" ;; B) echo "$model_b" ;; C) echo "$model_c" ;; esac; }

# Same env for every arm: no user-level CLAUDE.md, no auto-memory leaking into the session.
export CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 CLAUDE_CODE_DISABLE_AUTO_MEMORY=1

# prerequisites
missing=0
for c in claude node git; do
  if command -v "$c" >/dev/null 2>&1; then echo "ok: $c"; else echo "MISSING: $c"; missing=1; fi
done
if command -v node >/dev/null 2>&1; then
  nmaj=$(node -p 'process.versions.node.split(".")[0]')
  if [ "$nmaj" -ge 18 ] 2>/dev/null; then echo "ok: node $nmaj"; else echo "MISSING: node >= 18"; missing=1; fi
fi
[ -d "$repo/plugins/guyb" ] || { echo "MISSING: $repo/plugins/guyb"; missing=1; }
tmo=()
if command -v timeout >/dev/null 2>&1; then tmo=(timeout "$timeout_s")
elif command -v gtimeout >/dev/null 2>&1; then tmo=(gtimeout "$timeout_s")
else echo "note: no timeout(1); runs are bounded by --budget only"; fi

total_runs=$(( ${#task_list[@]} * ${#arm_list[@]} * repeats ))
if [ "$dry" = 1 ]; then
  echo "dry run: nothing is executed. Planned: $total_runs runs, up to \$$per_run each, total cap \$$total_cap."
  for a in "${arm_list[@]}"; do
    build_cmd "$a" "$(model_for "$a")"
    printf 'arm %s: ' "$a"; printf '%q ' "${cmd[@]}"; echo '< tasks/<task>/prompt.md'
  done
  echo "per run: copy bench/fixture to a temp dir, git init + commit, run the command there, copy tasks/<task>/acceptance.test.js to tests/, run node --test."
  [ "$missing" = 0 ] || { echo "prerequisites missing"; exit 1; }
  echo "prerequisites ok"
  exit 0
fi
[ "$missing" = 0 ] || die "prerequisites missing"

mkdir -p "$here/results"
[ -n "$out" ] || out="$here/results/$(date +%Y%m%d-%H%M%S).jsonl"
echo "results: $out"
echo "WARNING: this spends real money. Planned $total_runs runs, up to \$$per_run each, cap \$$total_cap."

rec=$(win "$here/record.js")
spent=0
n=0
# repeat is the outermost loop so an early stop leaves every task and arm with the same number of runs (+-1)
r=1
while [ "$r" -le "$repeats" ]; do
  for t in "${task_list[@]}"; do
    for a in "${arm_list[@]}"; do
      over=$(node -e 'console.log(Number(process.argv[1]) + Number(process.argv[2]) > Number(process.argv[3]) ? 1 : 0)' "$spent" "$per_run" "$total_cap")
      if [ "$over" = 1 ]; then
        echo "stopping: spent \$$spent + per-run budget \$$per_run could exceed cap \$$total_cap"
        break 3
      fi
      n=$((n + 1))
      model=$(model_for "$a")
      work=$(mktemp -d "${TMPDIR:-/tmp}/guyb-bench.XXXXXX") || die "mktemp failed"
      raw="$work.out.json"
      cp -R "$here/fixture/." "$work/"
      ( cd "$work" && git init -q && git config user.email bench@example.invalid && git config user.name bench \
        && git config core.autocrlf false && git add -A && git commit -q -m fixture ) || die "git init failed"
      build_cmd "$a" "$model"
      echo "[$n/$total_runs] task=$t arm=$a repeat=$r model=$model"
      start=$(date +%s)
      ( cd "$work" && "${tmo[@]}" "${cmd[@]}" <"$here/tasks/$t/prompt.md" ) >"$raw" 2>"$work.err"
      end=$(date +%s)
      wall=$((end - start))
      cp "$here/tasks/$t/acceptance.test.js" "$work/tests/acceptance_$t.test.js"
      if ( cd "$work" && node --test "tests/acceptance_$t.test.js" ) >/dev/null 2>&1; then passed=true; else passed=false; fi
      if ( cd "$work" && node --test ) >/dev/null 2>&1; then full=true; else full=false; fi
      node "$rec" record "$(win "$raw")" task="$t" arm="$a" repeat="$r" model_requested="$model" \
        passed="$passed" full_suite_passed="$full" wall_s="$wall" ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$out"
      cost=$(node "$rec" cost "$(win "$raw")")
      spent=$(node -e 'console.log(Number(process.argv[1]) + Number(process.argv[2]))' "$spent" "$cost")
      echo "    pass=$passed wall=${wall}s cost=\$$cost spent=\$$spent"
      rm -rf "$work" "$raw" "$work.err"
    done
  done
  r=$((r + 1))
done
echo "done: $n runs, spent \$$spent. Summarize: node bench/summarize.js $out"
