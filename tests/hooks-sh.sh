#!/usr/bin/env bash
# Tests that the hook scripts sourced by hooks.json survive /bin/sh = dash (issue #18): each hook runs
# under dash and under bash and must give the same exit code and stdout, plus fixed expectations.
# Usage: bash tests/hooks-sh.sh. Shell under test: dash if on PATH, else sh when it is not bash, else
# "skip: no dash" (exit 0); GUYB_REQUIRE_DASH=1 turns the skip into a failure. Temp dir removed on exit.
# Targets bash 3.2.
root=$(cd "$(dirname "$0")/.." && pwd)
plugin="$root/plugins/guyb"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/guyb-hookssh.XXXXXX") || exit 1
tmp=$(cd "$tmp" && pwd)
trap 'rm -rf "$tmp"' EXIT
export GIT_TERMINAL_PROMPT=0
unset CLAUDE_CONFIG_DIR

win() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

pass=0; fail=0
ok() { pass=$((pass + 1)); }
no() { fail=$((fail + 1)); echo "FAIL: $*"; }
expect_eq() { if [ "$2" = "$3" ]; then ok; else no "$1: got '$2', want '$3'"; fi; }

dash=
if command -v dash >/dev/null 2>&1; then dash=$(command -v dash)
elif [ -x /bin/sh ] && ! /bin/sh -c 'test -n "${BASH_VERSION:-}"'; then dash=/bin/sh
fi
if [ -z "$dash" ]; then
  if [ "${GUYB_REQUIRE_DASH:-}" = 1 ]; then echo "FAIL: no dash"; exit 1; fi
  echo "skip: no dash"; exit 0
fi

# run <shell> <input-file> <hook path under plugin> [arg]: sets rc and so (stdout)
run() {
  so=$(CLAUDE_PLUGIN_ROOT="$plugin" "$1" -c '. "$CLAUDE_PLUGIN_ROOT/'"$3"'" '"${4:-}" < "$2" 2>/dev/null); rc=$?
}
# diff_case <name> <input-file> <hook> <want rc> [arg]: dash and bash agree, rc matches
diff_case() {
  local drc dso
  run "$dash" "$2" "$3" "${5:-}"; drc=$rc; dso=$so
  run bash "$2" "$3" "${5:-}"
  expect_eq "$1 rc dash vs bash" "$drc" "$rc"
  expect_eq "$1 stdout dash vs bash" "$dso" "$so"
  expect_eq "$1 rc" "$drc" "$4"
}

# (a) guard-secrets
r="$tmp/repo"; mkdir -p "$r"; rw=$(win "$r")
git -C "$rw" init -q 2>/dev/null
git -C "$rw" config user.name t; git -C "$rw" config user.email t@example.invalid
printf 'x\n' > "$r/a.txt"; printf 'K=1\n' > "$r/.env"
git -C "$rw" add a.txt .env >/dev/null 2>&1
printf '{"tool_input":{"command":"git commit -m x"},"cwd":"%s"}' "$rw" > "$tmp/c1.json"
printf '{"tool_input":{"command":"git status"},"cwd":"%s"}' "$rw" > "$tmp/c2.json"
diff_case "secrets .env staged" "$tmp/c1.json" hooks/guard-secrets.sh 2
diff_case "secrets non-commit" "$tmp/c2.json" hooks/guard-secrets.sh 0
git -C "$rw" rm -q --cached .env >/dev/null 2>&1
diff_case "secrets only a.txt" "$tmp/c1.json" hooks/guard-secrets.sh 0

# (b) guard-readonly
printf '{"agent_type":"code-reviewer","tool_input":{"command":"git add a"}}' > "$tmp/r1.json"
printf '{"tool_input":{"command":"git add a"}}' > "$tmp/r2.json"
diff_case "readonly reviewer git add" "$tmp/r1.json" hooks/guard-readonly.sh 2
diff_case "readonly main session" "$tmp/r2.json" hooks/guard-readonly.sh 0

# (c) usage-guard gate: the arg must reach the script
ud="$tmp/usage"; mkdir -p "$ud"
printf 'stop 5h 99 %s\n' "$(( $(date +%s) + 86400 ))" > "$ud/state"
: > "$tmp/empty.json"
export GUYB_USAGE_DIR="$ud"
run bash "$tmp/empty.json" hooks/usage-guard.sh gate; want=$so; wrc=$rc
run bash "$tmp/empty.json" hooks/usage-guard.sh; noarg=$so
case $want in *permissionDecision*) ok ;; *) no "usage gate (bash) printed no decision: '$want'" ;; esac
expect_eq "usage no-arg prints nothing" "$noarg" ""
run "$dash" "$tmp/empty.json" hooks/usage-guard.sh gate
expect_eq "usage gate stdout dash vs bash" "$so" "$want"
expect_eq "usage gate rc dash vs bash" "$rc" "$wrc"
unset GUYB_USAGE_DIR

# (d) connections.sh hook with an empty HOME
eh="$tmp/home"; mkdir -p "$eh"
run_conn() { so=$(cd "$eh" && HOME="$eh" CLAUDE_PLUGIN_ROOT="$plugin" "$1" -c '. "$CLAUDE_PLUGIN_ROOT/skills/setup/connections.sh" hook' < /dev/null 2>/dev/null); rc=$?; }
run_conn "$dash"; drc=$rc; dso=$so
run_conn bash
expect_eq "connections rc dash vs bash" "$drc" "$rc"
expect_eq "connections stdout dash vs bash" "$dso" "$so"
expect_eq "connections rc" "$drc" "0"

# (e) static: guard within the first 40 lines, and the prefix up to it parses under dash
for f in hooks/guard-secrets.sh hooks/guard-readonly.sh hooks/usage-guard.sh skills/setup/connections.sh; do
  n=$(head -40 "$plugin/$f" | grep -n 'BASH_VERSION' | head -1 | cut -d: -f1)
  if [ -z "$n" ]; then no "$f: no BASH_VERSION guard in the first 40 lines"; continue; fi
  ok
  head -"$n" "$plugin/$f" > "$tmp/prefix.sh"
  if "$dash" -n "$tmp/prefix.sh" 2>/dev/null; then ok; else no "$f: guard prefix does not parse under dash"; fi
done

echo "hooks-sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
