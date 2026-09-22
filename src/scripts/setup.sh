#!/bin/bash
#
# Configure a CI runner so that raw `bazel <verb>` calls — not just
# `aspect <task>` — reach an Aspect cache.
#
# This is the provider-neutral core shared (vendored) by the Aspect CI
# integrations: the Buildkite plugin, the CircleCI orb, and the GitLab
# component. It takes one of two paths depending on the runner.
#
# On an Aspect Workflows runner it routes vanilla `bazel` through the runner's
# own caching infrastructure:
#
#   1. Log the runner's metadata (the ASPECT_WORKFLOWS_RUNNER_* table).
#   2. Wait for the runner's cache warming to complete — `aspect <task>` does
#      this itself, but a vanilla `bazel` call would otherwise race the still-running
#      bootstrap warming (competing for CPU/disk, missing the warmed caches).
#   3. Authenticate, if ASPECT_API_TOKEN is set.
#   4. Write the Workflows-tuned bazelrc, so every later `bazel` call in the job
#      picks up the runner's remote cache, repository cache and output paths.
#
# On any other runner — a stock Buildkite agent, CircleCI executor, or GitLab
# runner — it sets the job up against an Aspect deployment's remote cache
# instead, which is the whole setup needed to try Aspect on existing CI:
#
#   1. Install the Aspect CLI launcher and Bazelisk, each skipped when the
#      binary is already on PATH.
#   2. Authenticate, if ASPECT_API_TOKEN is set.
#   3. Run `aspect setup bazelrc`, which on CI writes ~/.aspect/bazelrc and a
#      try-import for it in ~/.bazelrc, pointing vanilla `bazel` at the
#      deployment's remote cache and BES. `aspect build --remote //...` reaches
#      the same deployment.
#
# No flags by default: the CLI detects CI and picks that layout over the
# <workspace>/.aspect/bazelrc pair meant to be committed. The `bazelrc-remote`,
# `bazelrc-home` and `bazelrc-force` settings override it when a pipeline asks,
# and `bazelrc-generate: false` skips ~/.aspect/bazelrc entirely.
#
# It must run AFTER the repository checkout (so .bazelversion / the workspace
# exist, with CWD at the workspace root) and BEFORE the first vanilla `bazel` call.
#
# Ported from aspect-build/setup-aspect's index.js. Each provider integration
# vendors a copy of this file and invokes it from its own entry point (Buildkite
# pre-command hook, CircleCI orb command, GitLab component before_script).

set -euo pipefail

# Path of the system bazelrc written by the legacy fallback. Overridable for
# tests (writing the real path requires root, which a test environment lacks).
SYSTEM_BAZELRC="${ASPECT_WORKFLOWS_PLUGIN_SYSTEM_BAZELRC:-/etc/bazel.bazelrc}"

# The oldest Aspect CLI this integration supports, as `aspect version` reports
# it, and where to get a newer one. `check_cli_version` warns below it, and the
# upgrade hints name it. It moves with the fixes a working setup depends on,
# which is why it is well past the release that first shipped the rc task.
ASPECT_CLI_MIN_VERSION="2026.38.34"
ASPECT_CLI_RELEASES_URL="https://github.com/aspect-build/aspect-cli/releases"
BAZELISK_RELEASES_URL="https://github.com/bazelbuild/bazelisk/releases"

# The rcs the bazelrc task writes in the home layout it picks on CI: the first
# user rc Bazel loads, which try-imports the second, which holds the flags. Both
# are echoed to the log after a run; in a checkout layout neither exists and the
# task's own report says what it wrote instead.
USER_BAZELRC="${HOME}/.bazelrc"
ASPECT_HOME_BAZELRC="${HOME}/.aspect/bazelrc"

# Where the launcher and Bazelisk are installed when this script has to fetch
# them, and which it prepends to PATH. Overridable so a job can place them on a
# cached volume, and so the tests can keep out of $HOME.
ASPECT_SETUP_BIN_DIR="${ASPECT_SETUP_BIN_DIR:-${HOME}/.aspect/setup-bin}"

# Optional pin for the Aspect CLI launcher, e.g. "2026.38.30". Empty installs
# the latest release. The *CLI* version is pinned by .aspect/version.axl in the
# repository, which the launcher reads on first use — this only pins the
# launcher that reads it.
ASPECT_LAUNCHER_VERSION="${ASPECT_LAUNCHER_VERSION:-}"

log() {
  echo "$@"
}

warn() {
  echo "⚠️  $*" >&2
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

# The Aspect CLI's own version, as `YYYY.WW.N`, or "" when there is nothing to
# compare.
#
# `aspect version` reports the CLI. `aspect --version` reports the *launcher*,
# which is versioned separately and says nothing about the CLI a repository
# pins, so it is the wrong question to ask here. Anything that is not a release
# version — a dev build reports `0.0.0-dev (debug build)` — comes back empty
# rather than being called old.
aspect_cli_version() {
  local reported
  reported="$(aspect version 2>/dev/null | head -1 | tr -d '[:space:]')" || return 0
  [[ "${reported}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 0
  printf '%s' "${reported}"
}

# Whether version $1 is at least $2, compared as numbers component by component:
# 2026.38.34 is newer than 2026.38.9, which a string compare gets backwards.
version_at_least() {
  local -a have want
  local i h w
  IFS='.' read -r -a have <<< "$1"
  IFS='.' read -r -a want <<< "$2"
  for i in 0 1 2; do
    h="${have[i]:-0}"
    w="${want[i]:-0}"
    if (( h > w )); then return 0; fi
    if (( h < w )); then return 1; fi
  done
  return 0
}

# Warn when the CLI on this runner is older than this integration supports.
#
# Advisory, like every other diagnostic here: an older CLI still runs, and what
# it gets wrong is not always visible in the job that runs it. Silent when the
# version cannot be read, so a dev build or a CLI that cannot start is not
# reported as out of date.
check_cli_version() {
  local version
  version="$(aspect_cli_version)"
  [[ -n "${version}" ]] || return 0
  version_at_least "${version}" "${ASPECT_CLI_MIN_VERSION}" && return 0
  warn "Aspect CLI ${version} is older than v${ASPECT_CLI_MIN_VERSION}, the minimum this integration supports. Upgrade to the latest release (${ASPECT_CLI_RELEASES_URL}); a repository pins the CLI it uses in .aspect/version.axl."
}

# Echo a generated rc file to the log so users can see exactly what was written
# and where it came from.
print_bazelrc() {
  local path="$1"
  [[ -f "${path}" ]] || return 0
  log "Generated ${path}:"
  # Redact header-flag values (gRPC/HTTP headers carry credentials and the
  # runner's x-identity) so the echoed rc doesn't leak them, keeping the flag
  # and header name visible: `--remote_header=x-identity=<uuid>` becomes
  # `--remote_header=x-identity=<REDACTED>`. Then indent so it reads as a quoted
  # block, not as live log directives.
  sed -E \
    -e 's/(--(remote_header|remote_cache_header|remote_exec_header|remote_downloader_header|bes_header)=[^=[:space:]]+=).*/\1<REDACTED>/' \
    -e 's/^/  /' \
    "${path}"
}
# Prepend a directory to PATH for this shell and, where the provider supports
# it, for the job's later steps. Buildkite hooks and GitLab before_script share
# one shell with the commands that follow, so the export alone carries; CircleCI
# runs each step in a fresh shell and sources ${BASH_ENV} into it, so the export
# is written there too.
add_to_path() {
  local dir="$1"
  export PATH="${dir}:${PATH}"
  if [[ -n "${BASH_ENV:-}" ]]; then
    echo "export PATH=\"${dir}:\${PATH}\"" >> "${BASH_ENV}"
  fi
}

# Download `url` to `dest` and make it executable. Written to a temp file first
# so a failed or partial download never leaves a truncated binary on PATH.
download_binary() {
  local url="$1" dest="$2" tmp
  tmp="$(mktemp "${dest}.XXXXXX")"
  if ! curl -fsSL --retry 3 -o "${tmp}" "${url}"; then
    rm -f "${tmp}"
    warn "Failed to download ${url}."
    return 1
  fi
  chmod +x "${tmp}"
  mv -f "${tmp}" "${dest}"
}

# This machine as "<arch> <platform>", in the spelling the Aspect launcher's
# release assets use (mirroring install.aspect.build). `ensure_bazel` maps the
# pair to Bazelisk's own spelling.
host_triple() {
  local arch platform
  case "$(uname -m)" in
    x86_64 | amd64) arch="x86_64" ;;
    arm64 | aarch64) arch="aarch64" ;;
    *) warn "Unsupported architecture $(uname -m) — the Aspect CI integrations support x86_64 and arm64."; return 1 ;;
  esac
  case "$(uname -s)" in
    Darwin) platform="apple-darwin" ;;
    Linux) platform="unknown-linux-musl" ;;
    *) warn "Unsupported platform $(uname -s) — the Aspect CI integrations support Linux and macOS only."; return 1 ;;
  esac
  echo "${arch} ${platform}"
}

# Put `aspect` on PATH, installing the launcher when it is missing.
#
# The launcher is a small binary that reads .aspect/version.axl from the
# repository and downloads the matching CLI on first use, so pinning the CLI
# stays the repository's job and ASPECT_LAUNCHER_VERSION only pins the reader.
ensure_aspect() {
  if command -v aspect > /dev/null 2>&1; then
    log "\`aspect\` already on PATH — skipping the Aspect CLI launcher install."
    return 0
  fi

  local arch platform
  read -r arch platform <<< "$(host_triple)" || return 1
  [[ -n "${platform}" ]] || return 1

  local asset="aspect-launcher-${arch}-${platform}" url
  if [[ -n "${ASPECT_LAUNCHER_VERSION}" ]]; then
    url="${ASPECT_CLI_RELEASES_URL}/download/v${ASPECT_LAUNCHER_VERSION#v}/${asset}"
  else
    url="${ASPECT_CLI_RELEASES_URL}/latest/download/${asset}"
  fi

  log "Installing the Aspect CLI launcher (${ASPECT_LAUNCHER_VERSION:-latest}) from ${url}"
  mkdir -p "${ASPECT_SETUP_BIN_DIR}"
  download_binary "${url}" "${ASPECT_SETUP_BIN_DIR}/aspect" || return 1
  add_to_path "${ASPECT_SETUP_BIN_DIR}"
  log "Installed \`aspect\` to ${ASPECT_SETUP_BIN_DIR}/aspect"
}

# Put `bazel` on PATH via Bazelisk, unless something already provides it (a
# setup-bazel-style step earlier in the pipeline, or the runner image).
#
# A failure here is only warned: the job may well not need `bazel` at all, and
# `aspect <task>` brings its own.
ensure_bazel() {
  if command -v bazel > /dev/null 2>&1; then
    log "\`bazel\` already on PATH — skipping the Bazelisk install."
    return 0
  fi

  local arch platform
  read -r arch platform <<< "$(host_triple)" || return 1
  [[ -n "${platform}" ]] || return 1

  # Bazelisk publishes the same hosts under Go's spelling of them.
  case "${arch}" in
    x86_64) arch="amd64" ;;
    aarch64) arch="arm64" ;;
  esac
  case "${platform}" in
    apple-darwin) platform="darwin" ;;
    unknown-linux-musl) platform="linux" ;;
  esac

  local url="${BAZELISK_RELEASES_URL}/latest/download/bazelisk-${platform}-${arch}"
  log "Installing Bazelisk from ${url}"
  mkdir -p "${ASPECT_SETUP_BIN_DIR}"
  download_binary "${url}" "${ASPECT_SETUP_BIN_DIR}/bazel" || return 1
  add_to_path "${ASPECT_SETUP_BIN_DIR}"
  log "Installed \`bazel\` (Bazelisk) to ${ASPECT_SETUP_BIN_DIR}/bazel"
}

# Exchange a long-lived ASPECT_API_TOKEN for a session JWT, which the CLI
# persists for every later `aspect` call in the job and which the `aspect`
# credential helper named by the generated rc hands to Bazel.
#
# The token is piped on stdin, never passed as an argument, so it stays out of
# the process table and the job log. A failure is warned, not fatal: a job that
# does not touch the Aspect API still runs fine unauthenticated.
login_if_api_token() {
  if [[ -z "${ASPECT_API_TOKEN:-}" ]]; then
    log "ASPECT_API_TOKEN is not set — skipping \`aspect auth login\`."
    return 0
  fi

  if ! command -v aspect > /dev/null 2>&1; then
    warn "ASPECT_API_TOKEN is set but \`aspect\` is not on PATH, so the token could not be exchanged for a session JWT."
    return 0
  fi

  log "Exchanging ASPECT_API_TOKEN for a session JWT"
  local status=0
  printf '%s' "${ASPECT_API_TOKEN}" | aspect auth login --with-api-token || status=$?
  if [[ "${status}" -ne 0 ]]; then
    warn "\`aspect auth login --with-api-token\` failed (exit ${status}). Later steps that need Aspect API access will fail to authenticate."
    return 1
  fi
  log "Persisted Aspect session JWT for later \`aspect\` invocations"
}

# Read the lines `$2 ...` prints into the array named by `$1`.
#
# What `mapfile -t` does, for the bash that ships with macOS: `/bin/bash` there
# is 3.2, which has no `mapfile`, and the shebang above asks for `/bin/bash`.
# The command runs in this shell, not a subshell, so the array outlives it.
read_lines() {
  local __name="$1"
  shift
  local __line
  eval "${__name}=()"
  while IFS= read -r __line; do
    eval "${__name}+=(\"\${__line}\")"
  done < <("$@")
}

# The rc task's own flags, as the job configured them through ASPECT_SETUP_*.
# Empty unless the job sets them: leaving a flag off is what lets the CLI apply
# its own `auto`, which already detects the runner and the CI host, and keeps
# the command line free of flags an older CLI would reject.
#
# `$1` overrides the configured `remote` value, for the caller that has to name
# one the job did not ask for.
#
# Printed one per line for the caller to collect with `read_lines`.
rc_task_flags() {
  local remote="${1:-${ASPECT_SETUP_REMOTE:-}}"
  local -a flags=()
  if [[ -n "${remote}" ]]; then
    flags+=("--remote=${remote}")
  fi
  if [[ -n "${ASPECT_SETUP_HOME:-}" ]]; then
    flags+=("--home=${ASPECT_SETUP_HOME}")
  fi
  if [[ "${ASPECT_SETUP_FORCE:-false}" == "true" ]]; then
    flags+=("--force")
  fi
  # Nothing at all when nothing is configured: a bare `printf '%s\n'` would emit
  # one blank line, which becomes an empty argument on the command line.
  if [[ "${#flags[@]}" -gt 0 ]]; then
    printf '%s\n' "${flags[@]}"
  fi
}

# Run the rc-generating task, passing through any extra arguments, and report
# whether it wrote ~/.aspect/bazelrc.
#
# `ci` is the group the task shipped under, still accepted as an alias, so both
# are tried: a non-zero exit means this CLI does not know that name, or does not
# know a flag it was given, not that writing ~/.aspect/bazelrc failed.
run_bazelrc_task() {
  local description="$1"
  shift
  local -a extra=("$@")

  local group status=0
  for group in setup ci; do
    log "Generating ${USER_BAZELRC} via \`aspect ${group} bazelrc ${extra[*]:-}\`"
    status=0
    aspect "${group}" bazelrc ${extra[@]+"${extra[@]}"} || status=$?
    if [[ "${status}" -eq 0 ]]; then
      log "Wrote ${description} bazelrc to ${USER_BAZELRC}"
      print_bazelrc "${USER_BAZELRC}"
      print_bazelrc "${ASPECT_HOME_BAZELRC}"
      return 0
    fi
    log "\`aspect ${group} bazelrc ${extra[*]:-}\` is unavailable in this Aspect CLI (exit ${status})."
  done
  return "${status}"
}

# Run the rc task with whatever the job configured, then bare: a CLI too old
# for a configured flag still writes ~/.aspect/bazelrc without it, which is
# better than no rc at all. Returns the status of the last attempt.
run_configured_bazelrc_task() {
  local description="$1"

  local -a configured=()
  read_lines configured rc_task_flags

  local status=0
  run_bazelrc_task "${description}" ${configured[@]+"${configured[@]}"} || status=$?
  if [[ "${status}" -ne 0 && "${#configured[@]}" -gt 0 ]]; then
    status=0
    run_bazelrc_task "${description}" || status=$?
  fi
  return "${status}"
}

# Preferred generator on a Workflows runner: `aspect setup bazelrc`.
#
# Writes ~/.aspect/bazelrc, try-imported from ~/.bazelrc, with the runner's
# remote cache, repository cache and output flags — the same flags
# `aspect <task>` injects. It reads the runner's environment, not a Workflows
# config, so no throwaway config or `.bazelversion` plumbing is needed.
#
# Returns 0 once ~/.aspect/bazelrc is written, non-zero if this CLI cannot write it.
aspect_setup_bazelrc() {
  command -v aspect > /dev/null 2>&1 || return 127

  local status=0
  run_configured_bazelrc_task "Workflows-tuned" || status=$?
  [[ "${status}" -eq 0 ]] && return 0

  warn "This Aspect CLI cannot run \`aspect setup bazelrc\`; upgrade to aspect-cli v${ASPECT_CLI_MIN_VERSION} or newer (${ASPECT_CLI_RELEASES_URL}). Trying the legacy generator instead."
  return "${status}"
}
# Legacy fallback generator, for runners whose CLI predates the bazelrc task.
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
# Configure vanilla `bazel` calls on a Workflows runner. If no generator can
# run, warn — but do NOT fail the build: warming has already completed and
# `aspect <task>` steps still work; only vanilla `bazel` calls go unconfigured.
write_bazelrc() {
  if aspect_setup_bazelrc; then
    return 0
  fi

  if rosetta_bazelrc; then
    return 0
  fi

  warn "Could not configure vanilla \`bazel\` calls on this Workflows runner: no bazelrc generator is available. Warming completed and \`aspect <task>\` steps are unaffected, but vanilla \`bazel\` calls will not pick up the runner's remote cache, repository cache, or disk cache and so will not function correctly. Upgrade aspect-cli to v${ASPECT_CLI_MIN_VERSION} or newer (${ASPECT_CLI_RELEASES_URL})."
  return 0
}

# Point vanilla `bazel` at an Aspect deployment's remote cache and BES, by
# writing ~/.aspect/bazelrc with `aspect setup bazelrc`.
#
# The task defaults to the Aspect Cloud deployment and needs no login to write
# the rc; ASPECT_API_TOKEN is what lets Bazel authenticate to the cache the rc
# names, and what the task looks for before enabling those endpoints at all.
#
# `$1` is the exit status of the token exchange; non-zero writes ~/.aspect/bazelrc with the
# endpoints disabled rather than naming a cache nothing here can authenticate to.
#
# A failure is warned, not fatal: the job still builds, just without the cache.
write_cloud_bazelrc() {
  local login_status="${1:-0}"

  if ! command -v aspect > /dev/null 2>&1; then
    warn "\`aspect\` is not on PATH, so \`aspect setup bazelrc\` could not run and \`bazel\` will not reach the Aspect remote cache."
    return 0
  fi

  # A token that would not exchange will not authenticate the cache either, and
  # Bazel treats a credential helper that cannot produce a token as fatal — so an
  # rc naming the cache would fail every `bazel` call rather than merely leave it
  # uncached. Say so explicitly instead; the endpoints stay defined in
  # ~/.aspect/bazelrc and come back the moment the token is fixed. No bare retry: a CLI too old for
  # `--remote` enables nothing on this path anyway.
  if [[ "${login_status}" -ne 0 ]]; then
    warn "The ASPECT_API_TOKEN exchange failed, so the generated rc will not enable the remote cache or BES — pointing Bazel at a cache it cannot authenticate to would fail the build rather than slow it down. Fix the token to restore caching; \`--config=aspect-cloud\` in the rc still names the endpoints."
    local -a disabled=()
    read_lines disabled rc_task_flags none
    run_bazelrc_task "Aspect (cache disabled)" ${disabled[@]+"${disabled[@]}"} || true
    return 0
  fi

  local status=0
  run_configured_bazelrc_task "Aspect remote cache" || status=$?
  [[ "${status}" -eq 0 ]] && return 0

  warn "This Aspect CLI cannot run \`aspect setup bazelrc\`, so \`bazel\` will not reach the Aspect remote cache (${ASPECT_CLI_RELEASES_URL}). Upgrade the CLI, or configure Bazel's remote cache yourself."
  return 0
}

# Whether to write ~/.aspect/bazelrc and its `try-import` in ~/.bazelrc at all,
# from the `bazelrc-generate` setting.
#
# False writes neither ~/.aspect/bazelrc nor the `try-import` for it in
# ~/.bazelrc, leaving Bazel's configuration to the repository. Everything else still
# happens — the installs, the login, the warming wait on a runner — which is
# what makes this different from not running the setup at all. `aspect <task>`
# is unaffected either way: a task configures its own invocation.
generating_bazelrc() {
  [[ "${ASPECT_SETUP_GENERATE:-true}" != "false" ]]
}

# An Aspect Workflows runner: the caches are the runner's own, and
# ~/.aspect/bazelrc is generated from its environment rather than from a
# deployment.
setup_workflows_runner() {
  log "Detected Aspect Workflows runner (ASPECT_WORKFLOWS_RUNNER set)"

  log_workflows_runner_metadata

  wait_for_warming

  check_cli_version

  login_if_api_token

  if generating_bazelrc; then
    write_bazelrc
  else
    log "bazelrc-generate is false — leaving Bazel's configuration to this repository."
  fi
}

# Any other runner: install what the job needs, then point Bazel at the
# deployment's remote cache. This is the path that lets an existing Buildkite,
# CircleCI, or GitLab pipeline use Aspect without moving to Workflows runners.
setup_vanilla_runner() {
  log "Not an Aspect Workflows runner — setting up for the Aspect remote cache."

  ensure_aspect || return 0
  ensure_bazel || true

  check_cli_version

  local login_status=0
  login_if_api_token || login_status=$?

  if generating_bazelrc; then
    write_cloud_bazelrc "${login_status}"
  else
    log "bazelrc-generate is false — leaving Bazel's configuration to this repository."
  fi
}

main() {
  if [[ -n "${ASPECT_WORKFLOWS_RUNNER:-}" ]]; then
    setup_workflows_runner
  else
    setup_vanilla_runner
  fi
}

main "$@"
