#!/usr/bin/env bash
# Runs the bash test files concurrently and prints each log in a fixed order. Usage: bash tests/run.sh
# Each file uses its own temp dir (and a private tmux socket), so they do not interfere. Writes nothing in the repo.
# Exit 1 if any file failed. Targets bash 3.2. PowerShell twin: run.ps1.
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/guyb-run.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
names="lint smoke secrets tabs statusline"

for n in $names; do
  (
    start=$SECONDS
    bash "$root/tests/$n.sh" > "$tmp/$n.log" 2>&1
    echo $? > "$tmp/$n.rc"
    echo $((SECONDS - start)) > "$tmp/$n.secs"
  ) &
done
wait

failed=0
for n in $names; do
  rc=$(cat "$tmp/$n.rc" 2>/dev/null); rc=${rc:-1}
  echo "=== $n.sh: exit $rc, $(cat "$tmp/$n.secs" 2>/dev/null || echo '?') s"
  cat "$tmp/$n.log"
  [ "$rc" -eq 0 ] || failed=$((failed + 1))
done
if [ "$failed" -gt 0 ]; then echo "run: $failed file(s) failed"; exit 1; fi
echo "run: all ok"
