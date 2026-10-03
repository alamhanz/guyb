# guyb - State of the Project

## Overview
**guyb** is a Claude Code plugin that provides an orchestrator + specialist subagent team for code projects. It enables task delegation, project navigation, and integrated development workflows.

- **Repo**: https://github.com/alamhanz/guyb
- **License**: Proprietary (private repo)
- **Owner**: @alamhanz

## Current Status
- **Branch**: main (clean)
- **Latest commit**: bc2cd8d (2026-10-03, Merge PR #4 - Release 0.4.0)
- **Uncommitted work**: None
- **Open PRs**: None (all 4 recent PRs merged)

## Deployed Versions
- **Latest**: v0.4.0 (2026-10-03)
  - Root launcher opens tabs for picked project
  - Orchestrator delegates by default (no self-tasks)
  - Intake via architect, question log for agent questions
- **Previous**: v0.3.0 (run IDs, waves, progress files for subagents)
- **Base**: v0.2 (global setup, project credentials, multi-host git/cloud)

## Recent Changes (last 30 days)
- 2026-10-03 - Release 0.4.0: orchestrator delegation, root launcher tabs, intake/question log (bc2cd8d / PR #4)
- 2026-10-03 - Orchestrator delegates by default, intake via architect (40f5297 / PR #3)
- 2026-10-03 - Root session opens picked project in new tab (823f274 / PR #2)
- 2026-10-03 - Run IDs, waves, progress files for subagents (c989168 / PR #1, v0.3.0)

## Decisions
- **Delegation model**: Orchestrator is decision layer; subagents execute. Orchestrator delegates unless it's intake/routing (PR #3, commit 40f5297).
- **Tab management**: Root launcher opens projects in Terminal tabs, matching profile settings (PR #2).
- **Architecture**: Intake via architect skill; question log tracks agent inquiries for visibility.

## Open Issues
None known. All PRs resolved.

## Next Up
- Monitor usage and gather feedback on v0.4.0
- Consider next feature priorities (e.g., agent team expansion, better logging, CI/CD integration)
- Watch for issues in the guyb plugin usage across projects

---
**Last updated**: 2026-10-03 (initial state file)
