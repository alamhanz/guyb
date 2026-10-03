#!/usr/bin/env bash
# guyb PreToolUse guard: block `git commit` when secret-looking files are staged.
# Exit 2 blocks the tool call and feeds stderr back to Claude; any other exit lets it run.

files=$(git diff --cached --name-only 2>/dev/null) || exit 0
[ -z "$files" ] && exit 0

bad=$(printf '%s\n' "$files" \
  | grep -iE '(^|/)(\.env(\.[^/]*)?|[^/]*\.(pem|key|p12|pfx|jks|keystore)|id_(rsa|ed25519|ecdsa)[^/]*|credentials(\.[^/]*)?|[^/]*service[-_]?account[^/]*\.json)$' \
  | grep -viE '\.(example|sample|template|pub)$')

if [ -n "$bad" ]; then
  {
    echo "guyb: blocked git commit - secret-looking files are staged:"
    printf '  %s\n' $bad
    echo "Unstage them (git restore --staged <file>), add them to .gitignore, and commit again."
    echo "If a file is definitely not a secret, ask the user to confirm, then commit it manually."
  } >&2
  exit 2
fi
exit 0
