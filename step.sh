#!/usr/bin/env bash
#
# Bitrise step: Appflight App Store Compliance Check.
#
# Wraps the published `appflight` npm CLI. The CLI itself is unmodified; this
# script installs a pinned version, runs it, exports a JSON artifact, and maps
# the CLI's documented exit codes onto a build pass/fail.
#
# Exit-code contract (docs/cli-output-contract.md, contract version 1.2):
#   0  scan completed, nothing at/above the threshold  -> build passes
#   1  scan completed, findings at/above the threshold -> build fails (the gate)
#   2  usage or tool error, scan did NOT complete      -> build fails, distinctly
#
# The 1/2 split is the reason this script never collapses failures into a
# single "failed" path: a broken invocation must never be readable as "clean".

set -euo pipefail

readonly REPORT_BASENAME="appflight-report.json"

# ── Output helpers ───────────────────────────────────────────────────────────

info()  { echo "==> $*"; }
warn()  { echo "[warn] $*" >&2; }
err()   { echo "[error] $*" >&2; }
rule()  { echo "--------------------------------------------------------------"; }

# envman is present on Bitrise but not when running the test harness locally,
# so exporting degrades to a log line instead of failing the run.
export_output() {
  local key="$1" value="$2"
  if command -v envman >/dev/null 2>&1; then
    envman add --key "$key" --value "$value" >/dev/null
    echo "    exported ${key}=${value}"
  else
    echo "    (envman unavailable) ${key}=${value}"
  fi
}

# ── Inputs ───────────────────────────────────────────────────────────────────
# Bitrise passes step inputs as environment variables of the same name.

project_path="${project_path:-.}"
appflight_version="${appflight_version:-}"
fail_on="${fail_on:-critical}"
deep="${deep:-false}"
api_token="${api_token:-}"

# ── Validation ───────────────────────────────────────────────────────────────
# Every invalid configuration fails here, before anything is installed, so a
# typo never costs an npm install or a paid API call.

if [ -z "$appflight_version" ]; then
  err "appflight_version is required and must be an exact version (for example 0.7.2)."
  err "Pinning is deliberate: a compliance gate has to be reproducible."
  exit 1
fi

if [ "$appflight_version" = "latest" ]; then
  err "appflight_version must be an exact version, not 'latest'."
  err "An unpinned gate can turn a green build red without a change in your repo."
  exit 1
fi

case "$fail_on" in
  critical|warning|suggestion|none) ;;
  *)
    err "fail_on must be one of: critical, warning, suggestion, none (got '${fail_on}')."
    exit 1
    ;;
esac

case "$deep" in
  true|false) ;;
  *)
    err "deep must be 'true' or 'false' (got '${deep}')."
    exit 1
    ;;
esac

if [ ! -d "$project_path" ]; then
  err "project_path '${project_path}' is not a directory."
  exit 1
fi

# Fail fast rather than silently downgrading to a deterministic-only scan: a
# user who asked for --deep and got a local scan would read a green build as
# "the AI tier found nothing".
if [ "$deep" = "true" ] && [ -z "$api_token" ]; then
  err "deep is 'true' but api_token is empty."
  err ""
  err "The --deep tier requires authentication. Generate a token locally with:"
  err "    appflight login --print-token"
  err "then store it as a Bitrise secret and pass it to this step's api_token input."
  err ""
  err "Alternatively set deep: false to run the free deterministic scan, which"
  err "needs no account and sends no code off the machine."
  exit 1
fi

if [ "$deep" = "false" ] && [ -n "$api_token" ]; then
  warn "api_token is set but deep is 'false'; the token will not be used."
fi

# ── Resolve the report destination ───────────────────────────────────────────

deploy_dir="${BITRISE_DEPLOY_DIR:-}"
if [ -z "$deploy_dir" ]; then
  deploy_dir="$(pwd)"
  warn "BITRISE_DEPLOY_DIR is not set; writing the report to ${deploy_dir} instead."
  warn "Outside Bitrise this is expected. On Bitrise it means the report will NOT"
  warn "be exported as a build artifact."
fi
mkdir -p "$deploy_dir"
report_path="${deploy_dir}/${REPORT_BASENAME}"

# ── Install the pinned CLI ───────────────────────────────────────────────────
# This installs onto the ephemeral build machine. It is a real global install,
# not a no-op: the VM is discarded after the build, so the install does not
# persist, but it does happen.

# Test-harness seam. Not a supported production setting: it is announced loudly
# because skipping the pinned install means the log's version line no longer
# proves which ruleset produced the verdict.
if [ "${APPFLIGHT_STEP_SKIP_INSTALL:-false}" = "true" ]; then
  warn "APPFLIGHT_STEP_SKIP_INSTALL=true — the pinned install was SKIPPED."
  warn "Using whichever appflight binary is already on PATH. This is intended"
  warn "for this step's own test suite only; do not set it on a real build."
else
  info "Installing appflight@${appflight_version} on the build machine"

  if ! command -v npm >/dev/null 2>&1; then
    err "npm was not found on PATH. This step requires Node.js on the build stack."
    err "Add a Node.js installer step before this one, or use a stack that ships Node."
    exit 1
  fi

  npm_log="$(mktemp)"
  if ! npm install -g "appflight@${appflight_version}" >"$npm_log" 2>&1; then
    err "npm install -g appflight@${appflight_version} failed:"
    cat "$npm_log" >&2
    rm -f "$npm_log"
    exit 1
  fi
  rm -f "$npm_log"
fi

if ! command -v appflight >/dev/null 2>&1; then
  err "The appflight binary is not on PATH after installation."
  err "npm global bin directory: $(npm prefix -g 2>/dev/null || echo 'unknown')"
  exit 1
fi

# Print what actually ran, so the build log is self-documenting and an audit
# never has to infer the version from the step config.
resolved_version="$(appflight version 2>/dev/null || echo 'unknown')"
info "Resolved appflight CLI version: ${resolved_version}"

if [ "$resolved_version" != "$appflight_version" ] && [ "$resolved_version" != "unknown" ]; then
  warn "Requested ${appflight_version} but the CLI reports ${resolved_version}."
fi

# ── Report the configuration ─────────────────────────────────────────────────

info "Configuration"
echo "    project_path : ${project_path}"
echo "    fail_on      : ${fail_on}"
echo "    deep         : ${deep}"
if [ "$deep" = "true" ]; then
  echo "    data boundary: deterministic findings, a facts digest, and REDACTED"
  echo "                   code excerpts are sent to the Appflight API."
else
  echo "    data boundary: local only. No source code or project data is sent."
fi
echo "    report       : ${report_path}"

# ── Pass 1: human-readable output for the build log ──────────────────────────
# Always deterministic (never --deep) so this pass performs no network I/O and,
# when the AI tier is enabled, cannot bill a second time. The authoritative
# verdict comes from pass 2.

rule
info "Deterministic scan"
rule

set +e
appflight check "$project_path" --fail-on "$fail_on"
human_status=$?
set -e

# ── Pass 2: JSON artifact, and the authoritative gate ────────────────────────
# This is the run whose exit code decides the build, because it is the run that
# includes --deep when the AI tier is enabled.

json_args=(check "$project_path" --fail-on "$fail_on" --json)
if [ "$deep" = "true" ]; then
  json_args+=(--deep)
  export APPFLIGHT_TOKEN="$api_token"
  rule
  info "AI analysis (--deep) and JSON report"
  rule
fi

set +e
appflight "${json_args[@]}" >"$report_path"
gate_status=$?
set -e

# The CLI writes nothing useful to stdout on a tool error, which would leave a
# zero-byte file masquerading as a report.
if [ ! -s "$report_path" ]; then
  warn "No JSON report was produced (the scan did not complete)."
  rm -f "$report_path"
  report_path=""
fi

# ── Extract the finding count ────────────────────────────────────────────────
# Node is guaranteed here because npm was required above, so this needs no jq.

finding_count="unknown"
if [ -n "$report_path" ]; then
  finding_count="$(node -e '
    const fs = require("fs");
    try {
      const report = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const total = report?.summary?.total;
      process.stdout.write(Number.isInteger(total) ? String(total) : "unknown");
    } catch {
      process.stdout.write("unknown");
    }
  ' "$report_path" 2>/dev/null || echo "unknown")"
fi

# ── Export outputs ───────────────────────────────────────────────────────────
# Exported before any failure exit so later steps can read them on a red build.

rule
info "Outputs"
export_output "APPFLIGHT_FINDING_COUNT" "$finding_count"
export_output "APPFLIGHT_REPORT_PATH" "$report_path"

if [ -n "$report_path" ]; then
  info "JSON report written to ${report_path}"
  echo "    Add the 'Deploy to Bitrise.io' step after this one to export it."
fi

# ── Map the CLI exit code onto the build result ──────────────────────────────

rule
# When the AI tier adds findings the deterministic pass did not have, say so
# explicitly — otherwise the log above looks inconsistent with the verdict.
if [ "$deep" = "true" ] && [ "$human_status" -ne "$gate_status" ]; then
  info "Note: the verdict below comes from the --deep run. The deterministic"
  echo "    pass alone exited ${human_status}; with AI analysis it exited ${gate_status}."
fi

case "$gate_status" in
  0)
    info "PASSED — no findings at or above the '${fail_on}' threshold."
    if [ "$finding_count" != "unknown" ] && [ "$finding_count" -gt 0 ] 2>/dev/null; then
      echo "    ${finding_count} finding(s) below the threshold are in the report."
    fi
    exit 0
    ;;
  1)
    err "FAILED — findings at or above the '${fail_on}' threshold."
    err ""
    err "This is the compliance gate working as configured. Review the findings"
    err "above, or in the JSON artifact, and fix them before submitting."
    err ""
    err "To change the gate's strictness, adjust the step's fail_on input."
    exit 1
    ;;
  2)
    err "TOOL ERROR — the scan did not complete."
    err ""
    err "This is NOT a clean result and must not be read as one. No verdict was"
    err "produced, so the project's compliance status is unknown."
    err ""
    err "Common causes:"
    err "  - project_path points at a parent directory containing several"
    err "    independent app roots; use one step instance per app root."
    err "  - project_path is not an app project."
    err "  - --deep was requested with an invalid or expired token."
    err "  - the Appflight API was unreachable from the build machine."
    exit 1
    ;;
  *)
    err "UNEXPECTED EXIT CODE ${gate_status} from the appflight CLI."
    err "The documented contract defines only 0, 1, and 2. Treating this as a"
    err "failure. Please report this along with the CLI version above."
    exit 1
    ;;
esac
