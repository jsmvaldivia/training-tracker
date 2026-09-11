---
name: resolve-issue
description: Turn one GitHub issue into a PR — triage, grill or design the spec when a human is needed, then run the autonomous test/implement/evaluate workflow and open the PR. Usage: /resolve-issue N
disable-model-invocation: true
---

# resolve-issue

Interactive half of the issue-resolution workflow (design record:
`docs/glossary/architecture.md`, "resolve-issue"). You run the steps that
need a human — triage verdicts, glossary and spec decisions, the board, the
PR — and hand the READY brief to the autonomous script in
`.claude/workflows/build-issue.js`.

Argument: the issue number `N`.

## 1. Start

1. `gh issue view N --comments`. Stop if it is closed.
2. Board card to **In Progress** (ids in `docs/glossary/architecture.md`,
   "Project board"):
   ```bash
   item=$(gh project item-list 3 --owner jsmvaldivia --format json --limit 200 | jq -r --argjson n N '.items[] | select(.content.number == $n) | .id')
   gh project item-edit --project-id PVT_kwHOAth7oc4BiY_Z --id "$item" --field-id PVTSSF_lAHOAth7oc4BiY_ZzhhROiM --single-select-option-id 47fc9ee4
   ```
3. `gh issue edit N --remove-label needs-triage`.

## 2. Triage

Agent tool, `subagent_type: issue-triager`, prompt `triage #N`. Read the
verdict in the brief it returns.

- **NEEDS_CONTEXT**: run the `grill-me` skill on each gap's topic with the
  user, until the glossary answers it. Then triage again.
- **SPEC_CHANGE**: when a term is missing, `grill-me` first. Then the
  `oas-designer` agent for the named resource (interactive with the user),
  then `scripts/validate-oas.sh` until it is clean. The spec is frozen from
  here. Then triage again.
- **READY**: continue.

Loop until READY. Done when the brief says READY and every section is filled.

## 3. Build

1. Worktree for the issue: the EnterWorktree tool (name `issue-N`), based on
   `main`.
2. From the brief's **Layers** section take the backend resource names
   (`resources`, `[]` when `api` is unchanged) and whether `web` changes.
3. Workflow tool with `scriptPath: .claude/workflows/build-issue.js` and
   `args: { issue: N, brief: "<the brief, verbatim>", resources: [...], web: true|false }`.
   Wait for its result: `{ verdict, rounds, findings }`.

**FAIL** after three rounds: report the findings to the user, leave the
worktree in place with its uncommitted work, and stop.

## 4. Ship

On **PASS**, in the worktree:

1. Commit everything with a Conventional Commit message (`feat:`, `fix:`,
   `test:`, `docs:`) whose body ends with `Closes #N`. No attribution lines
   (`AGENTS.md`, Commits).
2. `git push -u origin HEAD`.
3. `gh pr create --base main --title "<the commit subject>" --body "<summary of the change and the test plan>\n\nCloses #N"`.
4. Report the PR URL. The board moves the card to **Done** by itself when the
   PR merges and closes the issue.
