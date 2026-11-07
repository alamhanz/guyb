---
name: status
description: Portfolio status across all projects - git state, unpushed work, open PRs, CI, and hygiene issues.
disable-model-invocation: true
argument-hint: "[optional: projects root folder]"
---

Run the `guyb:repo-steward` agent in read-only portfolio-status mode. Root folder: "$ARGUMENTS" if given, else every `$GUYB_ROOT` entry (list separator `;` on Windows, `:` elsewhere), else the parent folder of the current directory.

Show the user its table (with a root column when there is more than one root) and the "needs attention" list, then offer the top 3 fixes as next actions.
