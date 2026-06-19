# Scope: project — personal overrides go in CLAUDE.local.md

# Training Tracker

Web app for tracking the trainings and certifications I want to complete —
progress, milestones, and goals. Single user, local development only. Zig
backend (web service) + React frontend (Bun runtime). Keep it simple: prefer
the smallest dependency set that works and don't add infrastructure the app
doesn't need.

## Stack

**Backend** — `api/`
- Zig web service exposing the REST API defined in `api/openapi.yaml`
- JSON file storage (`api/data.json`) — single file, backend-private
- Migrate to SQLite once the domain model stabilizes

**Frontend** — `web/`
- React (Bun runtime, built-in JSX transform)
- API client codegen'd from `api/openapi.yaml` (typed fetch wrappers)
- Never touches `data.json` directly — only talks to the backend via HTTP

**Contract**: `api/openapi.yaml` is the source of truth; backend owns it,
frontend generates types from it. There are no external API consumers.

## MVP scope

Ship these entities first (defer the rest):
- **Pursuit** — name, type (training|certification), target_date, status, started_at, completed_at
- **Milestone** — name, date, pending|achieved, belongs to one pursuit
- **Status** — planned → in_progress → completed (explicit lifecycle)

**Deferred to later**: Plans (cross-pursuit strategy), Tags (filtering), Resources (learning material), Renewal (expiring cert follow-on), Progress gauges (time/achievement %), Timeline view.

See `docs/glossary/` for the full domain model.

## Build & Run

**Backend** (`api/`, Zig 0.16.0 — mind version-specific build API):
```bash
zig build              # compile
zig build run          # start the HTTP server
zig build test         # all tests — the pre-commit gate
zig build test:unit    # fast unit + acceptance tests (no sockets) — the dev loop
zig build test:http    # HTTP integration tests (real server + sockets)
zig build test -Dtest-filter="milestone"   # run a subset by name
zig fmt api/           # format (CI/agents check with: zig fmt --check api/)
```

Test layers: **unit** (`store.zig`, `time_util.zig`) and **acceptance**
(`pursuits.zig`, `acceptance_milestones.zig`) are socket-free and fast — use
`test:unit` while iterating. **Integration** (`http_test*.zig`) spins up a real
server on a background thread; reserve it for the gate. For the tightest loop,
run a single file directly: `zig test src/store.zig`.

**Frontend** (`web/`, React 19 + Tailwind 3 on Bun):
```bash
cd web
bun install       # install dependencies
bun dev           # dev server on http://localhost:3000 (proxies /api → :8080)
bun start         # production mode
```

**E2E Tests** (`web/e2e/`, Playwright):
```bash
cd web
bun test:e2e          # run all E2E tests headless
bun test:e2e:ui       # interactive UI mode (recommended for debugging)
bun test:e2e:headed   # run with visible browser
bun test:e2e:debug    # step-through debugger
```

**Test Coverage**: 46 tests validating core user flows:
- Dashboard view (cards, stats, filters)
- Timeline view (chronological layout)
- Filters & view toggle (all/certification/training)
- Detail panel (open/close, status changes, milestone toggles)
- Accessibility (keyboard navigation, ARIA, focus management)

API linting via Spectral (`api/.spectral.yaml`): `scripts/validate-oas.sh`
lints `api/openapi.yaml` (fails on warnings).

# Commits

- Use Conventional Commits (`feat:`, `fix:`, `chore:`, `refactor:`, …).
- YOU MUST NOT add `Co-Authored-By: Claude` or any Claude/Anthropic
  attribution line to commit messages.

# Testing

## E2E Tests with Playwright

**Two workflows available:**

### 1. Local Playwright (`@playwright/test`)
Installed in `web/` via `bun add -d @playwright/test`. Best for:
- Running full test suite in CI
- Debugging tests interactively (`bun test:e2e:ui`)
- Test-driven development

```bash
cd web
bun test:e2e           # headless run (CI mode)
bun test:e2e:ui        # interactive UI (best for debugging)
bun test:e2e:headed    # visible browser
bun test:e2e:debug     # step debugger
```

Test files: `web/e2e/*.spec.ts`  
Config: `web/playwright.config.ts`

### 2. MCP Playwright (Interactive Browser Automation)
Claude Code MCP server for ad-hoc browser automation and visual testing.

**Setup** (configured in `~/.claude/settings.json`):
```json
{
  "mcpServers": {
    "playwright": {
      "command": "npx",
      "args": ["-y", "@playwright/mcp@latest"],
      "env": {}
    }
  }
}
```

**Activation**: Restart Claude Code after configuration changes.

**Available MCP Tools** (after restart):
- `playwright_navigate` - navigate to URL
- `playwright_screenshot` - capture viewport
- `playwright_click` - click elements
- `playwright_fill` - fill form fields
- `playwright_evaluate` - run JavaScript in page context
- `playwright_select` - select dropdown options

**Use cases**:
- Visual regression checking (screenshot comparisons)
- Ad-hoc UI exploration without writing test code
- Quick validation of UI changes
- Interactive debugging sessions

**Example workflow**:
```
1. Navigate to http://localhost:3000
2. Screenshot the dashboard
3. Click on a pursuit card
4. Screenshot the detail panel
5. Compare before/after
```

**Note**: MCP Playwright is for **interactive exploration**. Use `@playwright/test` for **automated regression tests**.

# Environment

Two environments only: **local** (dev) and **prod** (when deployed). No staging,
no test env, no dev/staging/prod config splits. Keep it binary.

<!-- grill-me:glossary:start -->
## Project glossary
Ground answers about this project in `docs/glossary/index.md`.
Open discrepancies (code vs. intended): `docs/glossary/discrepancies.md`.
<!-- grill-me:glossary:end -->
