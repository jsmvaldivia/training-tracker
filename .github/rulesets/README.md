# Branch ruleset for `main`

`main.json` is the repository ruleset `main` (id 22219490) as it should be,
in the shape the GitHub REST API accepts. It is the source of truth for the
setting: apply it with the command below rather than editing the ruleset on
github.com, and check what is live before assuming the file is applied
(issue #19 tracks the gap).

What it enforces on `main`:

- pull requests only (no direct pushes), squash merges, linear history, no
  deletion, no force pushes;
- the code scanning (CodeQL), code quality, and code coverage (80 %) rules
  that were already in place;
- **required status checks** `backend` and `frontend`: the job ids of
  `.github/workflows/backend.yml` and `frontend.yml` (issues #13, #14, #19).
  Their path-filtered runs are twinned by `backend-noop.yml` and
  `frontend-noop.yml`, so a PR outside those paths still reports both checks
  instead of waiting on "Expected". `strict` means the PR branch must be up
  to date with `main` before merging.

Apply (or re-apply after editing the file):

```bash
gh api --method PUT repos/jsmvaldivia/training-tracker/rulesets/22219490 --input .github/rulesets/main.json
```

Check what is live:

```bash
gh api repos/jsmvaldivia/training-tracker/rulesets/22219490 | jq '[.rules[].type]'
```

To require the `live-e2e` and `contract` jobs too, add their contexts
(`live`, `schemathesis`) to `required_status_checks` once those workflows
have been green on `main` for a few runs (issues #15, #36) and re-apply.
