# Bitrise Step: Appflight App Store Compliance Check

Scans an iOS project for App Store review risks on every build, writes a JSON
report as a build artifact, and fails the build on findings.

This repository is a thin wrapper around the published
[`appflight`](https://www.npmjs.com/package/appflight) npm CLI. The CLI is
unmodified; this step installs a pinned version, runs it, exports the report,
and maps the CLI's exit codes onto a build pass/fail.

---

## What it does on a build

1. Installs the pinned `appflight` version with `npm install -g` on the build
   machine, then prints the resolved version so the log records exactly what ran.
2. Runs the deterministic scan and prints its human-readable output to the log.
3. Runs the scan again with `--json` and writes
   `$BITRISE_DEPLOY_DIR/appflight-report.json`, so the
   **Deploy to Bitrise.io** step exports it as a build artifact.
4. Exports `APPFLIGHT_FINDING_COUNT` and `APPFLIGHT_REPORT_PATH` for later steps.
5. Fails the build on findings at or above the configured severity, and fails
   *distinctly* on a tool error so a broken scan is never read as a clean one.

The two passes are deliberate. The first is always deterministic and never uses
`--deep`, so it performs no network I/O and cannot bill the AI tier twice. The
second pass is the authoritative one, because it is the pass that includes
`--deep` when enabled.

---

## What runs where, and what leaves the machine

Your security review will ask this, so it is stated plainly.

### The step installs software on the build machine

`npm install -g appflight@<pinned-version>` runs on the Bitrise VM. This is a
real global install of a third-party npm package. It is not a no-op and it is
not vendored. It is, however, a **pinned** version on an **ephemeral** machine
that Bitrise destroys when the build ends, so nothing persists between builds.

### Default (`deep: false`): nothing leaves the machine

The deterministic scan is entirely local. No source code, file paths, finding
text, or repository identity is transmitted. Analysis happens in-process on the
build VM.

The CLI does schedule one anonymous, code-free usage event by default. To
disable all free-path network activity, set `APPFLIGHT_TELEMETRY=0` as an
environment variable on the workflow.

### Opt-in (`deep: true`): redacted excerpts are transmitted

Setting `deep: true` sends the following to the Appflight API:

- allowlisted deterministic findings
- a facts digest (detected SDKs, APIs, `Info.plist` keys, privacy-manifest state)
- up to 8 **redacted** code excerpts, each a few lines of context
- a salted SHA-256 hash of the project path, and the project directory's name

Secrets are redacted at extraction time, before they reach any payload. To see
the exact bytes that would be sent for your project without sending anything,
run this locally:

```sh
appflight check . --deep --dry-run
```

That prints the full payload and exits without making a network request.
The CLI's own disclosure document is
[`what-leaves-your-machine.md`](https://unpkg.com/appflight@0.7.2/docs/what-leaves-your-machine.md),
which ships inside the npm package itself, so the version you install is the
version the disclosure describes.

**Recommendation:** leave `deep: false` until a security review has explicitly
approved sending code excerpts to a third-party service. The deterministic gate
is useful on its own.

---

## Inputs

| Input | Default | Required | Description |
|---|---|---|---|
| `project_path` | `.` | yes | Directory to scan. Must be a **single app root**. |
| `appflight_version` | `0.7.2` | yes | Exact npm version. `latest` is rejected. |
| `fail_on` | `critical` | yes | `critical` \| `warning` \| `suggestion` \| `none` |
| `deep` | `false` | yes | `true` enables paid AI analysis and transmits excerpts. |
| `api_token` | *(empty)* | no | Token for `--deep`. Sensitive; use a Bitrise secret. |

### `project_path`

Point this at one app root. Scanning a parent directory containing several
independent app roots is a tool error (exit `2`) — use one step instance per app.

### `appflight_version` — why pinning is deliberate

This input intentionally rejects `latest`.

A compliance gate has to be reproducible. The same commit scanned on two
different days must produce the same verdict, and a rule shipped upstream must
never turn a green nightly build red without a reviewed change in your own
repository. Pinning also means the version printed in your build log is
sufficient evidence of which ruleset produced a given verdict.

Upgrade by bumping this value in a commit, so the new rules land on your
schedule and are attributable to a change you reviewed.

### `fail_on`

Maps directly to the CLI's `--fail-on`. A finding fails the build when its
severity ranks at or above the level (`critical` > `warning` > `suggestion`).

| Value | Fails on | Notes |
|---|---|---|
| `critical` | CRITICAL only | **Step default.** Adoptable on an existing pipeline without an immediate red build. |
| `warning` | CRITICAL + WARNING | The CLI's own default; the recommended steady state. |
| `suggestion` | any finding | Strictest. |
| `none` | never | Report-only. The artifact is still written. |

> The step defaults to `critical` while the CLI itself defaults to `warning`.
> This is intentional: a gate that goes red the day it is installed tends to get
> removed. Start at `critical`, then tighten to `warning`.

Findings below the threshold still appear in the log and the JSON artifact.

### `deep` and `api_token`

`deep: true` requires a token. If the token is missing the step fails
immediately with an explanation rather than quietly running a deterministic-only
scan, which would make a green build look like an AI-verified one.

Generate a token locally:

```sh
appflight login --print-token
```

Store it as a Bitrise **secret** environment variable (Workflow Editor →
Secrets), then reference the secret from the step input. Never commit it.

---

## Outputs

| Variable | Description |
|---|---|
| `APPFLIGHT_FINDING_COUNT` | Total findings across all severities, including those below the threshold. `unknown` if the scan errored. |
| `APPFLIGHT_REPORT_PATH` | Absolute path to the JSON report. |

Both are exported before the step exits, including on a failing build, so a
notification step can read them.

---

## Exit codes

| CLI exit | Meaning | Step behaviour |
|---|---|---|
| `0` | Nothing at or above the threshold | Build passes |
| `1` | Findings at or above the threshold | **Build fails** — the gate working |
| `2` | Tool or usage error; scan did not complete | **Build fails** with a distinct `TOOL ERROR` message |

The `1` / `2` split matters. On `2` no verdict was produced, so the compliance
status is *unknown*, not clean. The step never collapses these into one message,
and sets `APPFLIGHT_FINDING_COUNT=unknown` rather than `0`.

---

## Usage

### From this git repository (no marketplace needed)

```yaml
workflows:
  nightly-compliance:
    steps:
      - git-clone@8: {}
      - git::https://github.com/Azura2025/bitrise-step-appflight.git@main:
          title: Appflight compliance check
          inputs:
            - project_path: "."
            - appflight_version: "0.7.2"
            - fail_on: "critical"
            - deep: "false"
      - deploy-to-bitrise-io@2: {}
```

Pin to a tag instead of `main` once you have reviewed a release:

```yaml
      - git::https://github.com/Azura2025/bitrise-step-appflight.git@v1.0.0:
```

### Scheduled nightly build across several apps

```yaml
workflows:
  nightly-compliance:
    steps:
      - git-clone@8: {}
      - git::https://github.com/Azura2025/bitrise-step-appflight.git@main:
          title: Compliance — App One
          inputs:
            - project_path: "./AppOne"
            - appflight_version: "0.7.2"
            - fail_on: "critical"
      - git::https://github.com/Azura2025/bitrise-step-appflight.git@main:
          title: Compliance — App Two
          is_always_run: true
          inputs:
            - project_path: "./AppTwo"
            - appflight_version: "0.7.2"
            - fail_on: "critical"
      - deploy-to-bitrise-io@2: {}
```

`is_always_run: true` on later instances means one failing app does not hide the
results of the others — every app still gets a report by standup.

Trigger it from Bitrise's scheduled builds (for example 02:00 daily).

### With AI analysis enabled

```yaml
      - git::https://github.com/Azura2025/bitrise-step-appflight.git@main:
          inputs:
            - project_path: "."
            - appflight_version: "0.7.2"
            - fail_on: "warning"
            - deep: "true"
            - api_token: "$APPFLIGHT_API_TOKEN"   # a Bitrise secret
```

### Marketplace form (after submission)

Not yet published. Once accepted, the same configuration becomes:

```yaml
      - appflight-compliance-check@1:
          inputs:
            - project_path: "."
            - appflight_version: "0.7.2"
            - fail_on: "critical"
```

### Using the outputs

```yaml
      - script@1:
          title: Report to Slack
          is_always_run: true
          inputs:
            - content: |
                echo "Findings: $APPFLIGHT_FINDING_COUNT"
                echo "Report:   $APPFLIGHT_REPORT_PATH"
```

---

## Report artifact

`appflight-report.json` follows the CLI's versioned output contract
(currently schema `1.2`). The contract is a public API: within a schema
version, fields are only added, never renamed, removed, or retyped, so a
parser written against the shape below keeps working. Shape:

```json
{
  "schemaVersion": "1.2",
  "tool": { "name": "appflight", "version": "0.7.2" },
  "root": "/path/to/app",
  "scannedAt": "2026-08-11T02:00:00.000Z",
  "rulesetVersion": "d67d67f584fde857",
  "fileCount": 2,
  "gate": { "failOn": "critical", "triggered": true },
  "summary": { "total": 1, "critical": 1, "warning": 0, "suggestion": 0 },
  "findings": [
    {
      "id": "code_hardcoded_secret",
      "severity": "CRITICAL",
      "guideline": "1.6",
      "title": "Hardcoded live secret / API key detected",
      "description": "...",
      "fix": "...",
      "file": "Sources/Configuration.swift",
      "evidenceLocations": [
        { "file": "Sources/Configuration.swift", "line": 7, "snippet": "... [REDACTED]" }
      ]
    }
  ]
}
```

Evidence snippets are pre-redacted. Fields are only added within a schema
version, never renamed or retyped.

---

## Requirements

- Node.js on the build stack (any recent Bitrise Xcode stack ships it). The CLI
  requires Node **20.19.0 or newer**. If `npm` is absent, the step fails with a
  clear message; add a Node installer step before it.
- Network access to the npm registry for the install.
- Network access to the Appflight API **only** when `deep: true`.

---

## Testing

```sh
./test/run-tests.sh          # full: installs the pinned CLI per case
FAST=1 ./test/run-tests.sh   # reuse the appflight already on PATH
```

38 assertions across 7 cases: clean project passes, a hardcoded-secret project
fails with exit 1, `fail_on: none` is report-only, `deep` without a token fails
fast, invalid configuration is rejected before install, a CLI exit `2` is
surfaced as a distinct tool error, and a missing `BITRISE_DEPLOY_DIR` degrades
with a warning. The suite also asserts the fixture's live-looking secret never
reaches the log or the artifact.

`APPFLIGHT_STEP_SKIP_INSTALL=true` exists for the test harness only. It is
announced loudly in the log when set, because skipping the pinned install means
the version line no longer proves which ruleset produced the verdict. Do not set
it on a real build.

---

## Status

Not yet submitted to the Bitrise marketplace. Use the `git::` form above.

## License

MIT — see [LICENSE](LICENSE).
