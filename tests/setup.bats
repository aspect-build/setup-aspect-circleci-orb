#!/usr/bin/env bats

# Tests for the orb's vendored setup.sh (the script the `setup` command inlines),
# run via the buildkite/plugin-tester image (`docker-compose run --rm tests`).
# Drives the script through its branches with ASPECT_WORKFLOWS_RUNNER_* env vars.
#
# `aspect` and `rosetta` are stubbed with hand-rolled scripts placed on PATH
# rather than via bats-mock's `stub`: bats-mock derives an env-var prefix from
# the uppercased command name (ROSETTA_STUB_RUN, …), which Apple's Rosetta 2
# runtime intercepts and aborts when the suite runs under Docker Desktop on
# Apple Silicon. A PATH stub is portable across both real Linux CI agents and
# Apple Silicon dev hosts.

setup() {
  load "${BATS_PLUGIN_PATH}/load.bash"

  HOOK="${PWD}/src/scripts/setup.sh"

  # Redirect the legacy-rosetta system bazelrc write to a temp file so tests
  # don't need root.
  BAZELRC_OUT="$(mktemp)"
  export ASPECT_WORKFLOWS_PLUGIN_SYSTEM_BAZELRC="${BAZELRC_OUT}"

  # Isolate cross-step env propagation to a temp file.
  BUILDKITE_ENV_FILE="$(mktemp)"
  export BUILDKITE_ENV_FILE

  # A bin dir we prepend to PATH for hand-rolled stubs.
  STUB_BIN="$(mktemp -d)"

  # A fake checked-out workspace, with a .bazelversion, that the hook runs in:
  # the rosetta fallback reads .bazelversion from CWD. Tests cd here before
  # invoking the hook (the missing-.bazelversion test omits the file).
  WORKSPACE_DIR="$(mktemp -d)"
  echo "9.0.0" > "${WORKSPACE_DIR}/.bazelversion"

  # Sandbox HOME so the `aspect ci bazelrc` path (writes ~/.bazelrc) and the
  # plugin's rc dump don't touch the real user's ~/.bazelrc.
  FAKE_HOME="$(mktemp -d)"
  export HOME="${FAKE_HOME}"

  # Marker file written by the `aspect` stub so a test can prove it ran.
  ASPECT_STUB_RAN="$(mktemp -u)"
}

teardown() {
  rm -rf "${BAZELRC_OUT}" "${BUILDKITE_ENV_FILE}" "${STUB_BIN}" "${WORKSPACE_DIR}" "${FAKE_HOME}" "${ASPECT_STUB_RAN}"
}

# Run the hook from inside the fake workspace (CWD with a .bazelversion).
run_hook() {
  run bash -c "cd '${WORKSPACE_DIR}' && '${HOOK}'"
}

# Put an `aspect` on PATH whose `ci bazelrc` subcommand succeeds: it writes a
# stub rc to $HOME/.bazelrc (where the real command's default `--output` points)
# and records that it ran. Any other invocation (e.g. a real task) is a no-op.
stub_aspect() {
  cat > "${STUB_BIN}/aspect" <<EOF
#!/bin/bash
if [[ "\$1" == "ci" && "\$2" == "bazelrc" ]]; then
  echo 'common --remote_cache=grpcs://example' > "\${HOME}/.bazelrc"
  touch '${ASPECT_STUB_RAN}'
  exit 0
fi
exit 0
EOF
  chmod +x "${STUB_BIN}/aspect"
  export PATH="${STUB_BIN}:${PATH}"
}

# Put an `aspect` on PATH that fails `ci bazelrc` (e.g. a CLI too old to ship the
# subcommand — clap exits 2 on an unknown subcommand).
stub_old_aspect() {
  cat > "${STUB_BIN}/aspect" <<'EOF'
#!/bin/bash
echo "error: unrecognized subcommand 'ci'" >&2
exit 2
EOF
  chmod +x "${STUB_BIN}/aspect"
  export PATH="${STUB_BIN}:${PATH}"
}

# Put a `rosetta` on PATH whose `bazelrc` subcommand prints $1 (default rc text).
stub_rosetta() {
  local rc_content="${1:-build --remote_cache=grpcs://example}"
  cat > "${STUB_BIN}/rosetta" <<EOF
#!/bin/bash
# Args are: bazelrc --config <path>. Emit the rc on stdout.
echo '${rc_content}'
EOF
  chmod +x "${STUB_BIN}/rosetta"
  export PATH="${STUB_BIN}:${PATH}"
}

# Put a `rosetta` on PATH that prints an error to stderr and exits non-zero,
# mimicking a real `rosetta bazelrc` failure (e.g. ExitCode.ERROR == 200).
stub_failing_rosetta() {
  cat > "${STUB_BIN}/rosetta" <<'EOF'
#!/bin/bash
echo "rosetta: Unexpected error when generating bazelrc content" >&2
exit 200
EOF
  chmod +x "${STUB_BIN}/rosetta"
  export PATH="${STUB_BIN}:${PATH}"
}

@test "no-ops when not on an Aspect Workflows runner" {
  run_hook

  assert_success
  assert_output --partial "Not an Aspect Workflows runner"
  refute_output --partial "Detected Aspect Workflows runner"
}

@test "prefers \`aspect ci bazelrc\` to generate ~/.bazelrc" {
  export ASPECT_WORKFLOWS_RUNNER=1
  export ASPECT_WORKFLOWS_RUNNER_VERSION="2026.22.39"
  export ASPECT_WORKFLOWS_RUNNER_CLOUD_PROVIDER="aws"
  export ASPECT_WORKFLOWS_RUNNER_HAS_NVME_STORAGE=1
  stub_aspect
  stub_rosetta  # present but should NOT be used — aspect wins.

  run_hook

  assert_success
  assert_output --partial "Detected Aspect Workflows runner"
  assert_output --partial "Workflows version: 2026.22.39"
  assert_output --partial "Cloud provider: AWS"
  assert_output --partial "NVMe storage: yes"
  assert_output --partial "aspect ci bazelrc"

  # The aspect stub ran and wrote ~/.bazelrc; its contents are echoed to the log.
  [ -f "${ASPECT_STUB_RAN}" ]
  assert_output --partial "Wrote Workflows-tuned bazelrc to ${HOME}/.bazelrc"
  assert_output --partial "common --remote_cache=grpcs://example"

  # The rosetta fallback's system rc was never written.
  refute_output --partial "${BAZELRC_OUT}"
}

@test "falls back to \`rosetta bazelrc\` when aspect is too old, with an upgrade hint" {
  export ASPECT_WORKFLOWS_RUNNER=1
  stub_old_aspect
  stub_rosetta "build --remote_cache=grpcs://example"

  run_hook

  assert_success
  # The ci-command failure points users at the aspect-cli releases.
  assert_output --partial "Upgrade to the latest aspect-cli"
  assert_output --partial "https://github.com/aspect-build/aspect-cli/releases"
  # Then the rosetta fallback writes the system rc and echoes its contents.
  assert_output --partial "Wrote Workflows-tuned bazelrc to ${BAZELRC_OUT}"
  assert_output --partial "build --remote_cache=grpcs://example"
}

@test "falls back to rosetta when aspect is absent" {
  export ASPECT_WORKFLOWS_RUNNER=1
  # No aspect on PATH; rosetta present.
  export PATH="${STUB_BIN}:/usr/bin:/bin"
  stub_rosetta

  run_hook

  assert_success
  assert_output --partial "Wrote Workflows-tuned bazelrc to ${BAZELRC_OUT}"
}

@test "omits unset metadata rows" {
  export ASPECT_WORKFLOWS_RUNNER=1
  export ASPECT_WORKFLOWS_RUNNER_VERSION="2026.22.39"
  stub_aspect

  run_hook

  assert_success
  assert_output --partial "Workflows version: 2026.22.39"
  refute_output --partial "Region:"
  refute_output --partial "Instance type:"
}

@test "waits for warming until the marker file appears" {
  export ASPECT_WORKFLOWS_RUNNER=1
  export ASPECT_WORKFLOWS_RUNNER_WARMING_ENABLED=1
  local marker
  marker="$(mktemp -u)"
  export ASPECT_WORKFLOWS_RUNNER_WARMING_COMPLETE_MARKER_FILE="${marker}"
  stub_aspect

  # Create the marker shortly after the hook starts polling.
  ( sleep 2; touch "${marker}" ) &

  run_hook

  assert_success
  assert_output --partial "Warming is still in progress — waiting..."
  assert_output --partial "Warming completed after"

  rm -f "${marker}"
}

@test "skips the warming wait when the marker already exists" {
  export ASPECT_WORKFLOWS_RUNNER=1
  export ASPECT_WORKFLOWS_RUNNER_WARMING_ENABLED=1
  local marker
  marker="$(mktemp)"
  export ASPECT_WORKFLOWS_RUNNER_WARMING_COMPLETE_MARKER_FILE="${marker}"
  stub_aspect

  run_hook

  assert_success
  refute_output --partial "Warming is still in progress"

  rm -f "${marker}"
}

@test "logs the warmed cache version when published" {
  export ASPECT_WORKFLOWS_RUNNER=1
  export ASPECT_WORKFLOWS_RUNNER_WARMING_ENABLED=1
  local marker version_file
  marker="$(mktemp)"
  version_file="$(mktemp)"
  echo "cache-v123" > "${version_file}"
  export ASPECT_WORKFLOWS_RUNNER_WARMING_COMPLETE_MARKER_FILE="${marker}"
  export ASPECT_WORKFLOWS_RUNNER_WARMING_CACHE_VERSION_FILE="${version_file}"
  stub_aspect

  run_hook

  assert_success
  assert_output --partial "Runner warmed from cache version: cache-v123"

  rm -f "${marker}" "${version_file}"
}

@test "warns when warming enabled but marker var unset" {
  export ASPECT_WORKFLOWS_RUNNER=1
  export ASPECT_WORKFLOWS_RUNNER_WARMING_ENABLED=1
  stub_aspect

  run_hook

  assert_success
  assert_output --partial "ASPECT_WORKFLOWS_RUNNER_WARMING_COMPLETE_MARKER_FILE is not set"
}

@test "warns with an aspect-cli upgrade hint (without failing) when neither aspect nor rosetta can configure bazel" {
  export ASPECT_WORKFLOWS_RUNNER=1
  # Neither aspect nor rosetta on PATH. Restrict PATH so a real one (if any) on
  # the runner can't satisfy the lookup.
  export PATH="${STUB_BIN}:/usr/bin:/bin"

  run_hook

  # Build is NOT failed: warming is done and `aspect <task>` steps still work.
  assert_success
  assert_output --partial "Could not configure raw"
  assert_output --partial "Upgrade to the latest aspect-cli"
  assert_output --partial "https://github.com/aspect-build/aspect-cli/releases"
  refute_output --partial "Wrote Workflows-tuned bazelrc"

  run cat "${BUILDKITE_ENV_FILE}"
  assert_output --partial "ASPECT_WORKFLOWS_PLUGIN_DEPRECATED=1"
}

@test "does not fail the build when the rosetta fallback errors" {
  export ASPECT_WORKFLOWS_RUNNER=1
  # Pre-existing system rc that must NOT be clobbered by a failed run.
  echo "build --pre-existing" > "${BAZELRC_OUT}"
  # No aspect; rosetta present but failing.
  export PATH="${STUB_BIN}:/usr/bin:/bin"
  stub_failing_rosetta

  run_hook

  # rosetta's failure degrades to the min-version warning, not a build failure.
  assert_success
  assert_output --partial "rosetta bazelrc\` failed (exit 200)"
  assert_output --partial "Unexpected error when generating bazelrc content"
  assert_output --partial "Could not configure raw"
  refute_output --partial "Wrote Workflows-tuned bazelrc"

  # The existing system rc is untouched (not truncated to empty).
  run cat "${BAZELRC_OUT}"
  assert_output "build --pre-existing"
}

@test "does not fail when rosetta fallback hits a workspace with no .bazelversion" {
  export ASPECT_WORKFLOWS_RUNNER=1
  echo "build --pre-existing" > "${BAZELRC_OUT}"
  # No aspect; rosetta present, but the workspace lacks .bazelversion.
  export PATH="${STUB_BIN}:/usr/bin:/bin"
  stub_rosetta
  rm -f "${WORKSPACE_DIR}/.bazelversion"

  run_hook

  assert_success
  assert_output --partial "No .bazelversion file"
  assert_output --partial "Could not configure raw"
  refute_output --partial "Wrote Workflows-tuned bazelrc"

  # rosetta was never invoked past the guard; the existing system rc is untouched.
  run cat "${BAZELRC_OUT}"
  assert_output "build --pre-existing"
}
