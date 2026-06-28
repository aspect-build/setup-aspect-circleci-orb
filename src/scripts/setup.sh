#!/bin/bash
#
# Configure an Aspect Workflows runner so that raw `bazel <verb>` calls — not
# just `aspect <task>` — route through the runner's caching infrastructure.
#
# This is the provider-neutral core shared (vendored) by the Aspect Workflows
# CI integrations: the Buildkite plugin, the CircleCI orb, and the GitLab
# component. It does, in order:
#
#   1. Guard on ASPECT_WORKFLOWS_RUNNER; no-op gracefully when unset.
#   2. Log the runner's metadata (the ASPECT_WORKFLOWS_RUNNER_* table).
#   3. Wait for the runner's cache warming to complete — `aspect <task>` does
#      this itself, but a vanilla `bazel` call would otherwise race the still-running
#      bootstrap warming (competing for CPU/disk, missing the warmed caches).
#   4. Pre-flight the .bazelversion check: `rosetta bazelrc` resolves the Bazel
#      version from .bazelversion with no fallback, so a missing file is fatal.
#      Detect it up front and fail with an actionable message.
#   5. Write the Workflows-tuned bazelrc to /etc/bazel.bazelrc (the first rc
#      Bazel loads) via `rosetta bazelrc`, capturing stdout and only writing on
#      success; surface rosetta's exit code on failure.
#   6. Emit a deprecation signal when `rosetta` is missing or the runner signals
#      a newer bazelrc-generation mechanism.
#
# It must run AFTER the repository checkout (so .bazelversion / the workspace
# exist, with CWD at the workspace root) and BEFORE the first vanilla `bazel` call.
#
# Ported from aspect-build/setup-aspect's setupOnWorkflowsRunner. Each provider
# integration vendors a copy of this file and invokes it from its own
# entry point (Buildkite pre-command hook, CircleCI orb command, GitLab
# component before_script).

set -euo pipefail

# Path of the system bazelrc written by the legacy `rosetta` fallback — the
# first rc Bazel loads. Overridable for tests (writing the real path requires
# root, which a test environment lacks).
SYSTEM_BAZELRC="${ASPECT_WORKFLOWS_PLUGIN_SYSTEM_BAZELRC:-/etc/bazel.bazelrc}"

# Minimum Aspect CLI version that ships `aspect ci bazelrc`, and where to get it.
# Shown when the runner's CLI is too old.
ASPECT_CI_BAZELRC_MIN_VERSION="v2026.26.37"
ASPECT_CLI_RELEASES_URL="https://github.com/aspect-build/aspect-cli/releases"

# Path `aspect ci bazelrc` writes to (its default, the first user rc Bazel loads).
USER_BAZELRC="${HOME}/.bazelrc"

# The env var this script exports (and downstream `aspect <task>` steps can read)
# when it detects it is out of date on the current Workflows runner.
readonly DEPRECATED_ENV_VAR="ASPECT_WORKFLOWS_PLUGIN_DEPRECATED"

log() {
  echo "$@"
}

warn() {
  echo "⚠️  $*" >&2
}

# Export NAME=VALUE for the current process and, where the CI provider gives us a
# per-job env file, append it there so the value propagates to later steps in the
# same job. Honors $BUILDKITE_ENV_FILE (Buildkite) and $BASH_ENV (CircleCI);
# GitLab shares one shell across before_script/script, so the plain export
# suffices. Analogue of GitHub Actions' core.exportVariable / $GITHUB_ENV.
export_env() {
  local name="$1" value="$2"
  export "${name}=${value}"
  if [[ -n "${BUILDKITE_ENV_FILE:-}" ]]; then
    echo "${name}=${value}" >> "${BUILDKITE_ENV_FILE}"
  elif [[ -n "${BASH_ENV:-}" ]]; then
    echo "export ${name}=${value}" >> "${BASH_ENV}"
  fi
}

# Emit a deprecation warning and export DEPRECATED_ENV_VAR=1 so downstream
# `aspect <task>` invocations can surface the same signal.
mark_deprecated() {
  warn "$1"
  export_env "${DEPRECATED_ENV_VAR}" "1"
}

# Render the `1`/unset boolean runner flags as yes/no, matching the Aspect CLI's
# own "Workflows runner metadata" block.
yesno() {
  [[ -n "$1" ]] && echo "yes" || echo "no"
}

# Runner-metadata rows: "<label>|<env var>|<formatter>". Formatter is "" (verbatim),
# "upper", or "yesno". Ordering follows the Aspect CLI's metadata block.
readonly WORKFLOWS_METADATA_ROWS=(
  "Workflows version|ASPECT_WORKFLOWS_RUNNER_VERSION|"
  "Cloud provider|ASPECT_WORKFLOWS_RUNNER_CLOUD_PROVIDER|upper"
  "Region|ASPECT_WORKFLOWS_RUNNER_REGION|"
  "Availability zone|ASPECT_WORKFLOWS_RUNNER_AZ|"
  "Cloud account|ASPECT_WORKFLOWS_RUNNER_CLOUD_ACCOUNT|"
  "Instance type|ASPECT_WORKFLOWS_RUNNER_INSTANCE_TYPE|"
  "Instance name|ASPECT_WORKFLOWS_RUNNER_INSTANCE_NAME|"
  "Instance ID|ASPECT_WORKFLOWS_RUNNER_INSTANCE_ID|"
  "Image ID|ASPECT_WORKFLOWS_RUNNER_IMAGE_ID|"
  "Group name|ASPECT_WORKFLOWS_RUNNER_GROUP_NAME|"
  "Group queue|ASPECT_WORKFLOWS_RUNNER_GROUP_QUEUE|"
  "Resource type|ASPECT_WORKFLOWS_RUNNER_RESOURCE_TYPE|"
  "Aspect launcher version|ASPECT_WORKFLOWS_RUNNER_ASPECT_LAUNCHER_VERSION|"
  "CI agent version|ASPECT_WORKFLOWS_RUNNER_CI_AGENT_VERSION|"
  "NVMe storage|ASPECT_WORKFLOWS_RUNNER_HAS_NVME_STORAGE|yesno"
  "Preemptible|ASPECT_WORKFLOWS_RUNNER_PREEMPTIBLE|yesno"
  "Warming enabled|ASPECT_WORKFLOWS_RUNNER_WARMING_ENABLED|yesno"
)

log_workflows_runner_metadata() {
  local row label env_var fmt raw value
  for row in "${WORKFLOWS_METADATA_ROWS[@]}"; do
    IFS='|' read -r label env_var fmt <<< "${row}"
    raw="${!env_var:-}"
    [[ -z "${raw}" ]] && continue
    case "${fmt}" in
      upper) value="$(echo "${raw}" | tr '[:lower:]' '[:upper:]')" ;;
      yesno) value="$(yesno "${raw}")" ;;
      *)     value="${raw}" ;;
    esac
    log "${label}: ${value}"
  done
}

# Block until the runner's cache warming completes, mirroring the Aspect CLI's
# pre-task wait. Warming state is published by the runner agent: enabled when
# ASPECT_WORKFLOWS_RUNNER_WARMING_ENABLED is set, complete when the marker file
# named by ASPECT_WORKFLOWS_RUNNER_WARMING_COMPLETE_MARKER_FILE exists. The poll
# has no timeout by design: if warming hits a critical error the bootstrap
# terminates the runner (and this job with it), so the loop cannot hang.
wait_for_warming() {
  [[ -z "${ASPECT_WORKFLOWS_RUNNER_WARMING_ENABLED:-}" ]] && return 0

  local marker="${ASPECT_WORKFLOWS_RUNNER_WARMING_COMPLETE_MARKER_FILE:-}"
  if [[ -z "${marker}" ]]; then
    warn "Warming is enabled on this runner but ASPECT_WORKFLOWS_RUNNER_WARMING_COMPLETE_MARKER_FILE is not set — unable to wait for warming to complete."
    return 0
  fi

  if [[ ! -f "${marker}" ]]; then
    log "Warming is still in progress — waiting..."
    local start elapsed
    start="$(date +%s)"
    while [[ ! -f "${marker}" ]]; do
      sleep 1
    done
    elapsed=$(( $(date +%s) - start ))
    log "Warming completed after ${elapsed}s"
  fi

  local version_file="${ASPECT_WORKFLOWS_RUNNER_WARMING_CACHE_VERSION_FILE:-}"
  if [[ -n "${version_file}" && -f "${version_file}" ]]; then
    local cache_version
    cache_version="$(tr -d '[:space:]' < "${version_file}")"
    [[ -n "${cache_version}" ]] && log "Runner warmed from cache version: ${cache_version}"
  fi
}

# Echo a generated rc file to the log so users can see exactly what was written
# and where it came from — mirrors what the GitHub Action prints for rosetta.
print_bazelrc() {
  local path="$1"
  [[ -f "${path}" ]] || return 0
  log "Generated ${path}:"
  # Indent so it reads as a quoted block, not as live log directives.
  sed 's/^/  /' "${path}"
}

# Preferred generator: `aspect ci bazelrc`.
#
# Writes ~/.bazelrc (the first user rc Bazel loads) with the runner's remote
# cache, repository cache, and output flags — the same flags `aspect <task>`
# injects. It reads the runner's environment, not a Workflows config, so no
# throwaway config or `.bazelversion` plumbing is needed. Returns the command's
# exit code; non-zero means the CLI is too old to ship the subcommand (or it
# genuinely failed), in which case the caller falls back to `rosetta`.
aspect_ci_bazelrc() {
  command -v aspect > /dev/null 2>&1 || return 127
  log "Generating ${USER_BAZELRC} via \`aspect ci bazelrc\`"
  local status=0
  aspect ci bazelrc || status=$?
  if [[ "${status}" -ne 0 ]]; then
    warn "\`aspect ci bazelrc\` is unavailable in this Aspect CLI (exit ${status}); it requires aspect-cli ${ASPECT_CI_BAZELRC_MIN_VERSION} or newer (${ASPECT_CLI_RELEASES_URL}). Falling back to \`rosetta bazelrc\`."
    return "${status}"
  fi
  log "Wrote Workflows-tuned bazelrc to ${USER_BAZELRC}"
  print_bazelrc "${USER_BAZELRC}"
}

# Legacy fallback generator: `rosetta bazelrc` -> ${SYSTEM_BAZELRC}.
#
# `rosetta bazelrc` reads .aspect/workflows/config.yaml by default and fails if
# that file is absent or unreadable. We only need the generated rc, not a real
# Workflows config, so point it at a throwaway config. The schema requires a
# non-empty task list, so define a single placeholder task.
#
# rosetta resolves the Bazel version from the workspace's .bazelversion with no
# fallback, so a missing file is fatal (ExitCode.ERROR / 200). We pre-flight that
# check for an actionable message. CWD is the checked-out workspace root.
#
# rosetta's stdout (the rc content) is captured to a temp file and only moved
# into place once rosetta exits 0 — never redirect straight into ${SYSTEM_BAZELRC},
# which would truncate it before rosetta runs and leave a half-written rc on
# failure. Its own error is left on stderr and we add our exit code on top.
rosetta_bazelrc() {
  command -v rosetta > /dev/null 2>&1 || return 127

  if [[ ! -f .bazelversion ]]; then
    warn "No .bazelversion file in $(pwd). \`rosetta bazelrc\` resolves the Bazel version from .bazelversion and has no fallback, so it cannot generate a bazelrc here. Commit a .bazelversion to the repo (the same file Bazelisk reads), or run this setup only where the working directory contains one."
    return 1
  fi

  local work_dir
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/aspect-workflows-rosetta-XXXXXX")"
  # shellcheck disable=SC2064  # expand work_dir now, at trap-install time.
  trap "rm -rf '${work_dir}'" RETURN

  printf 'tasks:\n  - warming:\n' > "${work_dir}/config.yaml"

  local rc_out="${work_dir}/bazel.bazelrc" status=0
  rosetta bazelrc --config "${work_dir}/config.yaml" > "${rc_out}" || status=$?
  if [[ "${status}" -ne 0 ]]; then
    warn "\`rosetta bazelrc\` failed (exit ${status}); see its error above. ${SYSTEM_BAZELRC} was left unchanged."
    return "${status}"
  fi

  cat "${rc_out}" > "${SYSTEM_BAZELRC}"
  log "Wrote Workflows-tuned bazelrc to ${SYSTEM_BAZELRC}"
  print_bazelrc "${SYSTEM_BAZELRC}"
}

# Configure vanilla `bazel` calls: prefer `aspect ci bazelrc`, fall back to the
# legacy `rosetta bazelrc` on older runners. If neither can run, warn — but do
# NOT fail the build: warming has already completed and `aspect <task>` steps
# still work; only vanilla `bazel` calls go unconfigured.
write_bazelrc() {
  if aspect_ci_bazelrc; then
    return 0
  fi

  if rosetta_bazelrc; then
    return 0
  fi

  mark_deprecated "Could not configure vanilla \`bazel\` calls on this Workflows runner: \`aspect ci bazelrc\` is unavailable and the legacy \`rosetta\` fallback is not on PATH. Warming completed and \`aspect <task>\` steps are unaffected, but vanilla \`bazel\` calls will not pick up the runner's remote cache, repository cache, or disk cache and so will not function correctly. Upgrade aspect-cli to ${ASPECT_CI_BAZELRC_MIN_VERSION} or newer for \`aspect ci bazelrc\` (${ASPECT_CLI_RELEASES_URL})."
  return 0
}

main() {
  if [[ -z "${ASPECT_WORKFLOWS_RUNNER:-}" ]]; then
    log "Not an Aspect Workflows runner (ASPECT_WORKFLOWS_RUNNER unset) — skipping Aspect Workflows setup."
    return 0
  fi

  log "Detected Aspect Workflows runner (ASPECT_WORKFLOWS_RUNNER set)"

  log_workflows_runner_metadata

  wait_for_warming

  write_bazelrc
}

main "$@"
