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

  # A bin dir we prepend to PATH for hand-rolled stubs.
  STUB_BIN="$(mktemp -d)"

  # A fake checked-out workspace, with a .bazelversion, that the hook runs in:
  # the rosetta fallback reads .bazelversion from CWD. Tests cd here before
  # invoking the hook (the missing-.bazelversion test omits the file).
  WORKSPACE_DIR="$(mktemp -d)"
  echo "9.0.0" > "${WORKSPACE_DIR}/.bazelversion"

  # Sandbox HOME so the `aspect setup bazelrc` path (writes ~/.bazelrc) and the
  # plugin's rc dump don't touch the real user's ~/.bazelrc.
  FAKE_HOME="$(mktemp -d)"
  export HOME="${FAKE_HOME}"

  # Marker file written by the `aspect` stub so a test can prove it ran.
  ASPECT_STUB_RAN="$(mktemp -u)"

  # Where the `aspect` stub saves the token it was fed on stdin, so a test can
  # prove the login ran and what it was given.
  ASPECT_STUB_TOKEN="$(mktemp -u)"

  # The vanilla-runner path installs the launcher and Bazelisk when they are
  # missing. Point that at a temp dir so it stays out of $HOME — every test that
  # takes this path stubs both binaries, so nothing here reaches the network.
  ASPECT_SETUP_BIN_DIR="$(mktemp -d)"
  export ASPECT_SETUP_BIN_DIR
}

teardown() {
  rm -rf "${BAZELRC_OUT}" "${STUB_BIN}" "${WORKSPACE_DIR}" "${FAKE_HOME}" \
    "${ASPECT_STUB_RAN}" "${ASPECT_STUB_TOKEN}" "${ASPECT_SETUP_BIN_DIR}"
}

# Run the hook from inside the fake workspace (CWD with a .bazelversion).
run_hook() {
  run bash -c "cd '${WORKSPACE_DIR}' && '${HOOK}'"
}

# Put an `aspect` on PATH that knows the bazelrc task under exactly one group
# name ("setup" on a current CLI, "ci" on one that predates the rename). It
# writes a stub rc to $HOME/.bazelrc (where the real command's default
# `--output` points) and records that it ran. Every other group is rejected the
# way clap rejects an unknown subcommand, so the setup script has to try the
# next name rather than mistaking a no-op for success.
stub_aspect() {
  local group="${1:-setup}"
  cat > "${STUB_BIN}/aspect" <<EOF
#!/bin/bash
if [[ "\$1" == "${group}" && "\$2" == "bazelrc" ]]; then
  {
    echo 'common --remote_cache=grpcs://example'
    echo 'common --remote_header=x-identity=00000000-0000-0000-0000-000000000000'
  } > "\${HOME}/.bazelrc"
  touch '${ASPECT_STUB_RAN}'
  exit 0
fi
echo "error: unrecognized subcommand '\$1'" >&2
exit 2
EOF
  chmod +x "${STUB_BIN}/aspect"
  export PATH="${STUB_BIN}:${PATH}"
}

# Put an `aspect` on PATH that knows the bazelrc task under no name at all (a
# CLI too old to ship it — clap exits 2 on an unknown subcommand).
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

# Put an `aspect` on PATH that behaves like a current CLI off a Workflows
# runner: it knows `setup bazelrc --home` and `auth login --with-api-token`, and
# records what it was asked to do. Anything else is rejected the way clap
# rejects an unknown subcommand.
stub_cloud_aspect() {
  cat > "${STUB_BIN}/aspect" <<EOF
#!/bin/bash
if [[ "\$1" == "auth" && "\$2" == "login" && "\$3" == "--with-api-token" ]]; then
  cat > '${ASPECT_STUB_TOKEN}'
  exit 0
fi
if [[ "\$1" == "setup" && "\$2" == "bazelrc" && "\$3" == "--home" ]]; then
  echo 'common --remote_cache=grpcs://cloud.aspect.build' > "\${HOME}/.bazelrc"
  touch '${ASPECT_STUB_RAN}'
  exit 0
fi
echo "error: unrecognized subcommand '\$*'" >&2
exit 2
EOF
  chmod +x "${STUB_BIN}/aspect"
  export PATH="${STUB_BIN}:${PATH}"
}

# An `aspect` from before `--home` shipped: it rejects the flag the way clap
# rejects an unexpected argument.
stub_homeless_aspect() {
  cat > "${STUB_BIN}/aspect" <<'EOF'
#!/bin/bash
echo "error: unexpected argument '--home' found" >&2
exit 2
EOF
  chmod +x "${STUB_BIN}/aspect"
  export PATH="${STUB_BIN}:${PATH}"
}

# A no-op `bazel`, so the vanilla path skips its Bazelisk install.
stub_bazel() {
  printf '#!/bin/bash\nexit 0\n' > "${STUB_BIN}/bazel"
  chmod +x "${STUB_BIN}/bazel"
  export PATH="${STUB_BIN}:${PATH}"
}

@test "points vanilla bazel at the Aspect remote cache when off a Workflows runner" {
  stub_cloud_aspect
  stub_bazel

  run_hook

  assert_success
  assert_output --partial "Not an Aspect Workflows runner"
  refute_output --partial "Detected Aspect Workflows runner"

  # The rc came from `aspect setup bazelrc --home` and its contents are echoed.
  assert_output --partial "aspect setup bazelrc --home"
  assert_output --partial "Wrote Aspect remote cache bazelrc to ${HOME}/.bazelrc"
  assert_output --partial "common --remote_cache=grpcs://cloud.aspect.build"
  [ -f "${ASPECT_STUB_RAN}" ]

  # Nothing on this path touches the Workflows-runner machinery.
  refute_output --partial "Wrote Workflows-tuned bazelrc"
}

@test "exchanges ASPECT_API_TOKEN for a session JWT off a Workflows runner" {
  export ASPECT_API_TOKEN="client_id:secret"
  stub_cloud_aspect
  stub_bazel

  run_hook

  assert_success
  assert_output --partial "Persisted Aspect session JWT"
  # Fed on stdin, so the token never reaches the process table or the log.
  assert_equal "$(cat "${ASPECT_STUB_TOKEN}")" "client_id:secret"
  refute_output --partial "client_id:secret"
}

@test "skips the login when ASPECT_API_TOKEN is unset" {
  stub_cloud_aspect
  stub_bazel

  run_hook

  assert_success
  assert_output --partial "ASPECT_API_TOKEN is not set"
  refute_output --partial "Persisted Aspect session JWT"
  [ ! -f "${ASPECT_STUB_TOKEN}" ]
}

@test "skips the installs when aspect and bazel are already on PATH" {
  stub_cloud_aspect
  stub_bazel

  run_hook

  assert_success
  assert_output --partial "\`aspect\` already on PATH"
  assert_output --partial "\`bazel\` already on PATH"
  refute_output --partial "Installing the Aspect CLI launcher"
  refute_output --partial "Installing Bazelisk"
}

@test "warns without failing when the CLI predates \`--home\`" {
  stub_homeless_aspect
  stub_bazel

  run_hook

  # A CLI too old for the flag leaves the job uncached, not broken.
  assert_success
  assert_output --partial "cannot run \`aspect setup bazelrc --home\`"
  assert_output --partial "https://github.com/aspect-build/aspect-cli/releases"
}

@test "authenticates on a Workflows runner too, before generating the rc" {
  export ASPECT_WORKFLOWS_RUNNER=1
  export ASPECT_API_TOKEN="client_id:secret"
  cat > "${STUB_BIN}/aspect" <<EOF
#!/bin/bash
if [[ "\$1" == "auth" && "\$2" == "login" && "\$3" == "--with-api-token" ]]; then
  cat > '${ASPECT_STUB_TOKEN}'
  exit 0
fi
if [[ "\$1" == "setup" && "\$2" == "bazelrc" ]]; then
  # Prove the login landed first: the rc records whether the token file exists.
  [[ -f '${ASPECT_STUB_TOKEN}' ]] && echo 'common --remote_cache=grpcs://after-login' > "\${HOME}/.bazelrc"
  exit 0
fi
exit 2
EOF
  chmod +x "${STUB_BIN}/aspect"
  export PATH="${STUB_BIN}:${PATH}"

  run_hook

  assert_success
  assert_output --partial "Persisted Aspect session JWT"
  assert_output --partial "common --remote_cache=grpcs://after-login"
}

@test "prefers \`aspect setup bazelrc\` to generate ~/.bazelrc" {
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
  assert_output --partial "aspect setup bazelrc"

  # The aspect stub ran and wrote ~/.bazelrc; its contents are echoed to the log.
  [ -f "${ASPECT_STUB_RAN}" ]
  assert_output --partial "Wrote Workflows-tuned bazelrc to ${HOME}/.bazelrc"
  assert_output --partial "common --remote_cache=grpcs://example"
  assert_output --partial "common --remote_header=x-identity=<REDACTED>"
  refute_output --partial "x-identity=00000000-0000-0000-0000-000000000000"

  # The rosetta fallback's system rc was never written.
  refute_output --partial "${BAZELRC_OUT}"
}

@test "falls back to \`aspect ci bazelrc\` on a CLI that predates the rename" {
  export ASPECT_WORKFLOWS_RUNNER=1
  stub_aspect ci   # knows the task only under its older name
  stub_rosetta     # present but should NOT be used — the alias wins.

  run_hook

  assert_success
  # It tried the current name first, then the alias, and never reached rosetta.
  assert_output --partial "aspect setup bazelrc"
  assert_output --partial "aspect ci bazelrc"
  [ -f "${ASPECT_STUB_RAN}" ]
  assert_output --partial "Wrote Workflows-tuned bazelrc to ${HOME}/.bazelrc"
  refute_output --partial "Wrote Workflows-tuned bazelrc to ${BAZELRC_OUT}"
}

@test "falls back to \`rosetta bazelrc\` when aspect is too old, with an upgrade hint" {
  export ASPECT_WORKFLOWS_RUNNER=1
  stub_old_aspect
  stub_rosetta "build --remote_cache=grpcs://example"

  run_hook

  assert_success
  # The ci-command failure points users at the aspect-cli releases.
  assert_output --partial "aspect-cli v2026.38.10 or newer"
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
  assert_output --partial "Could not configure vanilla"
  assert_output --partial "v2026.38.10 or newer"
  assert_output --partial "https://github.com/aspect-build/aspect-cli/releases"
  refute_output --partial "Wrote Workflows-tuned bazelrc"
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
  assert_output --partial "Could not configure vanilla"
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
  assert_output --partial "Could not configure vanilla"
  refute_output --partial "Wrote Workflows-tuned bazelrc"

  # rosetta was never invoked past the guard; the existing system rc is untouched.
  run cat "${BAZELRC_OUT}"
  assert_output "build --pre-existing"
}
