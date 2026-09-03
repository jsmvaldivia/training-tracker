# Scope: project — personal overrides go in CLAUDE.local.md

@AGENTS.md

## Claude Code specifics

- Subagents live in `.claude/agents/`: `oas-designer` (designs the contract,
  writes no code) and `resource-implementer` (TDDs one backend resource per
  instance, never edits the spec). Use them in that order for new resources.
- Ground answers about the domain in `docs/glossary/index.md`.
