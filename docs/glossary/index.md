# Glossary index

Map of project knowledge. One line per entry; content lives in the topic pages.

## business-knowledge
- [Pursuit](business-knowledge.md#pursuit) — core entity; a certification or training
- [Milestone](business-knowledge.md#milestone) — named, dated checkpoint on a pursuit
- [Time Progress](business-knowledge.md#time-progress) — elapsed-time gauge
- [Achievement Progress](business-knowledge.md#achievement-progress) — milestones-reached gauge
- [Overdue](business-knowledge.md#overdue) — past deadline, not completed
- [Plan](business-knowledge.md#plan) — cross-pursuit strategy document (many-to-many)
- [Timeline](business-knowledge.md#timeline) — primary time-laid-out view
- [Status](business-knowledge.md#status) — explicit pursuit lifecycle state
- [Tag](business-knowledge.md#tag) — lightweight filtering label (many-to-many)
- [Resource](business-knowledge.md#resource) — learning material on a pursuit
- [Renewal](business-knowledge.md#renewal) — expiring cert renewed as a linked follow-on

## architecture
- [resource-implementer](architecture.md#resource-implementer-agent) — agent: TDD-implements one backend resource (HTTP→persistence)
- [oas-designer](architecture.md#oas-designer-agent) — agent: designs the OAS, writes no code
- [gate.sh](architecture.md#gatesh-script) — script: all deterministic checks, writes `.gate/result.json`
- [coverage gate](architecture.md#coverage-gate) — Bun threshold for web, diff rule for api

## Open discrepancies
- [discrepancies.md](discrepancies.md) — code-vs-intent conflicts (none yet)
