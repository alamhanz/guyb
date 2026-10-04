#!/usr/bin/env bash
# Tests for plugins/guyb/hooks/guard-secrets.sh (git -C/-c, chained commands, commit -a, target repo).
# Usage: bash tests/secrets.sh. Builds throwaway git repos in a temp dir (removed on exit); writes nothing
# in the repo, needs no network or secrets. Every case also runs against a copy of the guard that
# pretends jq is missing, to cover the sed fallback. Targets bash 3.2.
# PowerShell twin: secrets.ps1 (keep the cases in sync).
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/guyb-secrets.XXXXXX") || exit 1
tmp=$(cd "$tmp" && pwd)
trap 'rm -rf "$tmp"' EXIT
export GIT_TERMINAL_PROMPT=0
unset CLAUDE_CONFIG_DIR

win() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

pass=0; fail=0
ok() { pass=$((pass + 1)); }
no() { fail=$((fail + 1)); echo "FAIL: $*"; }
expect_eq() { if [ "$2" = "$3" ]; then ok; else no "$1: got '$2', want '$3'"; fi; }

guard="$root/plugins/guyb/hooks/guard-secrets.sh"
nojq="$tmp/guard-nojq.sh"
sed 's/command -v jq/command -v no-such-jq/' "$guard" > "$nojq"
if cmp -s "$guard" "$nojq"; then no "nojq copy differs from the guard"; fi

out="$tmp/out"; mkdir -p "$out"
par="$tmp/par"; r="$par/child"; sp="$tmp/sp dir [v2]"
mkdir -p "$r" "$sp"

mk() { # dir
  local w; w=$(win "$1")
  git -C "$w" init -q 2>/dev/null
  git -C "$w" config user.name secrets
  git -C "$w" config user.email secrets@example.invalid
  git -C "$w" config commit.gpgsign false
  printf '# fixture\n' > "$1/README.md"
  git -C "$w" add -A >/dev/null 2>&1
  git -C "$w" commit -q -m init >/dev/null 2>&1
}
mk "$r"; mk "$sp"
R=$(win "$r"); SP=$(win "$sp"); PAR=$(win "$par"); OUT=$(win "$out")
g() { git -C "$R" "$@" >/dev/null 2>&1; }
gs() { git -C "$SP" "$@" >/dev/null 2>&1; }

json_str() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }'; }
json() { printf '{"session_id":"s","cwd":"%s","tool_name":"Bash","tool_input":{"command":"%s"}}' "$(json_str "$1")" "$(json_str "$2")"; }

# run <guard> <cwd> <command>: exit code of the guard fed the hook JSON, process cwd = a non-repo dir
run() { json "$2" "$3" | (cd "$out" && bash "$1" >/dev/null 2>&1); echo $?; }
# chk <label> <want> <cwd> <command>: with jq (if installed) and with the sed fallback
chk() {
  expect_eq "$1" "$(run "$guard" "$3" "$4")" "$2"
  expect_eq "$1 (no jq)" "$(run "$nojq" "$3" "$4")" "$2"
}

echo "plain"
printf 'KEY=value\n' > "$r/.env"; printf 'KEY=\n' > "$r/.env.example"
g add .env
chk "plain staged .env" 2 "$R" 'git commit -m x'
g reset -q; g add .env.example
chk "plain staged .env.example" 0 "$R" 'git commit -m x'
g reset -q
chk "plain nothing staged" 0 "$R" 'git commit -m x'

echo "git options and target repo"
g add .env
chk "-C repo" 2 "$OUT" "git -C $R commit -m x"
chk "-C parent -C child" 2 "$OUT" "git -C $PAR -C child commit -m x"
chk "-c k=v" 2 "$R" 'git -c user.name=a commit -m x'
chk "--no-pager" 2 "$R" 'git --no-pager commit -m x'
chk "git.exe" 2 "$R" 'git.exe commit -m x'
chk "absolute git path" 2 "$R" '/usr/bin/git commit -m x'
chk "-C other clean repo" 0 "$R" "git -C $SP commit -m x"
chk "-C quoted spaced path" 0 "$R" "git -C \"$SP\" commit -m x"
gs reset -q

echo "chains"
chk "add && commit" 2 "$R" 'git add . && git commit -m x'
chk "cd && commit" 2 "$OUT" "cd $R && git commit -m x"
chk "semicolon" 2 "$R" 'git status; git commit -m x'
chk "or" 2 "$R" 'false || git commit -m x'
chk "pipe" 2 "$R" 'echo a | git commit -F - '
chk "newline" 2 "$R" $'echo hi\ngit commit -m x'
chk "VAR=x git commit" 2 "$R" 'GIT_AUTHOR_NAME=a git commit -m x'
chk "no commit word" 0 "$R" 'git status | cat'
chk "echo commit" 0 "$R" 'echo commit'
chk "recommit" 0 "$R" 'recommit now'
printf 'KEY=value\n' > "$sp/.env"; gs add .env
chk "cd quoted spaced repo" 2 "$OUT" "cd \"$SP\" ; git commit -m x"
chk "cd single-quoted spaced repo" 2 "$OUT" "cd '$SP' && git commit -m x"
chk "cd away from the bad repo" 0 "$R" "cd $PAR && git -C $OUT commit -m x"
gs reset -q

echo "heredoc message"
hd=$'git commit -m "$(cat <<\'EOF\'\nbody -a\nEOF\n)"'
chk "heredoc staged .env" 2 "$R" "$hd"
g reset -q
printf 'k\n' > "$r/deploy.key"; g add deploy.key; g commit -q -m key
printf 'k2\n' >> "$r/deploy.key"
chk "heredoc -a in body, nothing staged" 0 "$R" "$hd"

echo "commit -a and pathspecs"
chk "modified key, plain commit" 0 "$R" 'git commit -m x'
chk "-am" 2 "$R" 'git commit -am x'
chk "-qam" 2 "$R" 'git commit -qam x'
chk "--all" 2 "$R" 'git commit --all -m x'
chk "-a after -m" 2 "$R" 'git commit -m x -a'
chk "-a inside message" 0 "$R" 'git commit -m "note -a"'
chk "-a inside message (single quotes)" 0 "$R" "git commit -m 'note -a'"
chk "pathspec" 2 "$R" 'git commit deploy.key -m x'
chk "-- pathspec" 2 "$R" 'git commit -m x -- deploy.key'
chk "-o pathspec" 2 "$R" 'git commit -o deploy.key -m x'
chk "-C on another repo with -a" 2 "$OUT" "git -C $R commit -am x"

echo "deleted files never block"
g rm -q --cached deploy.key
chk "staged deletion" 0 "$R" 'git commit -m x'
chk "staged deletion -a" 0 "$R" 'git commit -am x'
g commit -q -m "rm key"
rm -f "$r/deploy.key"

echo "new patterns"
for f in .envrc k.p8 prod.tfvars prod.tfvars.json vault.kdbx .netrc .npmrc .pypirc; do
  printf 'x\n' > "$r/$f"; g add -f "$f"
  chk "staged $f" 2 "$R" 'git commit -m x'
  g reset -q; rm -f "$r/$f"
done
printf 'x\n' > "$r/notes.txt"; g add notes.txt
chk "ordinary file" 0 "$R" 'git commit -m x'
g reset -q; rm -f "$r/notes.txt"

echo "fallback"
g add .env
expect_eq "no stdin, staged .env" "$(cd "$r" && bash "$guard" </dev/null >/dev/null 2>&1; echo $?)" 2
expect_eq "no stdin, staged .env (no jq)" "$(cd "$r" && bash "$nojq" </dev/null >/dev/null 2>&1; echo $?)" 2
expect_eq "bad json" "$(printf '{bad commit' | (cd "$r" && bash "$guard" >/dev/null 2>&1); echo $?)" 2
expect_eq "bad json (no jq)" "$(printf '{bad commit' | (cd "$r" && bash "$nojq" >/dev/null 2>&1); echo $?)" 2
expect_eq "no stdin outside a repo" "$(cd "$out" && bash "$guard" </dev/null >/dev/null 2>&1; echo $?)" 0
chk "unknown dir falls back to cwd (not a repo)" 0 "$OUT" 'cd $UNSET && git commit -m x'
chk "unknown dir falls back to cwd (repo)" 2 "$R" 'cd $UNSET && git commit -m x'
chk "missing cwd dir" 0 "$tmp/no-such-dir" 'git commit -m x'
expect_eq "message names the repo" "$(json "$OUT" "git -C $R commit -m x" | (cd "$out" && bash "$guard" 2>&1 >/dev/null) | grep -c "would be committed (")" 1

if command -v cygpath >/dev/null 2>&1; then
  echo "windows-style cwd"
  W=$(cygpath -w "$r")
  chk "backslash cwd" 2 "$W" 'git commit -m x'
fi

echo "secrets: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
