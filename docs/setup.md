# Setup and machine migration

The repository carries project instructions, Claude's shared-instruction import
and agents, locked JavaScript dependencies, and a pinned Zig/Bun toolchain.
Personal agent preferences and live training data are separate.

## Prepare a machine

Supported hosts are macOS (including its Bash 3.2) and Playwright-supported
Ubuntu/Debian Linux. Install Git and [mise](https://mise.jdx.dev/getting-started.html)
using its instructions for your OS, then clone the repository. From its root:

```bash
mise trust
mise install
mise exec -- ./scripts/setup.sh
```

Review the repository before trusting its mise configuration. `mise.toml` is
the version source: Zig 0.16.0 and Bun 1.3.14. Use `mise exec -- <command>` to
select them explicitly in terminals, IDEs, and agent sessions. Shell activation
is optional. Installing the tools does not install Codex, Claude Code, or RTK.

Setup uses `bun install --frozen-lockfile` and the installed Playwright CLI to
download Chromium. Repeating it is safe; a failed install exits nonzero. Network
access is required for uncached packages and Playwright browser downloads.
Spectral is an exact development dependency in the frontend lockfile; linting
never downloads a different validator through bunx.

On Ubuntu/Debian, install Chromium's system libraries once, after dependencies
are installed. This Playwright command uses the system package manager and may
request administrator privileges; setup does not run it automatically:

```bash
mise exec -- bun web/node_modules/@playwright/test/cli.js install-deps chromium
```

Then run:

```bash
mise exec -- ./scripts/verify.sh
mise exec -- ./scripts/dev.sh
```

Verification checks tools, OpenAPI, Zig formatting, the full backend suite,
frontend unit tests, and Chromium E2E tests in order, stopping on failure.
Port 3000 must be free: E2E starts its own frontend with mocked API responses.
Stop the dev server before verification. Serialize Zig tests across agents and
worktrees on the same machine because they share temporary paths. Verification
uses `zig build test -j1` because imported module tests also share those paths
between binaries within a single build.

When changing setup or supervision scripts, run their socket-free regression
checks with `mise exec -- bun scripts/test-tooling.mjs`. They exercise temporary
fixtures under `/bin/bash`; `TEST_BASH` can select another Bash installation.
The application, validator, and Playwright commands use Bun explicitly and do
not require a separate Node installation.

Dev starts the API and frontend and shuts down both process groups when either
exits, on Ctrl-C, or on termination. API data is seeded only when the live file
does not exist. Setup and verification do not initialize or modify live data.

## Agent setup checklist

- Install Codex and/or Claude Code separately and sign in again on the new host.
- The repository's `AGENTS.md` contains shared guidance; `CLAUDE.md` imports it.
  Both agents use the same setup and verification commands. Claude's remote
  session hook invokes setup only when `CLAUDE_CODE_REMOTE=true`; pinned tools
  must be available on PATH before launching the agent. Local hooks do not install.
- Review and transfer selected global instructions from `~/.codex/AGENTS.md`
  and `~/.claude/CLAUDE.md`, plus relevant non-secret settings from their config
  files. Do not copy whole application state directories or credentials.
- If using RTK, install it separately and transfer its instruction files and
  hook configuration. Replace old absolute user paths with portable home
  references supported by the relevant tool. RTK is not needed by project scripts.
- Record installed plugins, skills, and connectors, reinstall those you use,
  and reconnect accounts. Review host-specific permissions instead of copying
  broad accumulated allowlists.
- Keep optional project overrides in `CLAUDE.local.md` or
  `.claude/settings.local.json`; repository ignore rules exclude them even on
  a host without global Git exclusions. Keep personal configuration outside
  this repository. A separate private dotfiles repository is optional.

## Transfer live training data

Git does not contain `api/data.json`. Stop both servers on the old machine
before copying it to your chosen private backup location. Transfer that backup
separately from Git and compare its SHA-256 checksum after transfer.

On the new machine, run setup and verification, then restore the backup to
`api/data.json` **before the first dev start**, with both servers stopped. If a
live file already exists, back it up before replacing it. Do not replace
`api/data.seed.json`; that is the tracked reference seed. Start dev and verify
your pursuits and milestones are present. Tests must never use the live file.

## Troubleshooting

- **Missing or wrong tool version:** run `mise install`, then use `mise exec`.
  A globally installed Bun or one in `node_modules/.bin` can otherwise shadow
  the desired version. The tool check reports the actual and required versions.
- **mise crashes:** update or repair mise using its official installation
  instructions. An older local installation crashed during readiness checks;
  project scripts do not repair global tools. Alternatively, install the exact
  versions from `mise.toml` yourself and put them on PATH.
- **Frozen lockfile error:** do not regenerate the lockfile during setup.
  Check that the manifest and lockfile come from the same checkout and that
  the pinned Bun is in use.
- **Browser download fails:** allow the download hosts named in Playwright's
  error (including `cdn.playwright.dev`) and rerun setup. On Linux, missing
  shared-library errors require the `install-deps chromium` step above.
- **Port 3000 unavailable:** stop its existing server and rerun verification.
  Verification never reuses a running development server.

References: [mise configuration](https://mise.jdx.dev/configuration.html),
[Bun frozen installs](https://bun.sh/docs/pm/cli/install), and
[Playwright browsers and system dependencies](https://playwright.dev/docs/browsers).
