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
  local version="${2:-2026.38.34}"
  cat > "${STUB_BIN}/aspect" <<EOF
#!/bin/bash
if [[ "\$1" == "version" ]]; then
  echo '${version}'
  exit 0
fi
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
if [[ "\$1" == "setup" && "\$2" == "bazelrc" ]]; then
  # A current CLI: the task needs no flags, and rejects ones it does not know
  # the way clap does, with exit 2.
  for arg in "\${@:3}"; do
    case "\$arg" in
      --home|--home=*|--remote|--remote=*|--force) ;;
      *) echo "error: unexpected argument '\$arg'" >&2; exit 2 ;;
    esac
  done
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

# An `aspect` that ships the bazelrc task but none of the flags this script can
# configure, the way a CLI older than one of them behaves: bare runs write the
# rc, anything with an argument exits 2.
stub_flagless_aspect() {
  cat > "${STUB_BIN}/aspect" <<EOF
#!/bin/bash
if [[ "\$1" == "setup" && "\$2" == "bazelrc" ]]; then
  if [[ -n "\${3:-}" ]]; then
    echo "error: unexpected argument '\$3' found" >&2
    exit 2
  fi
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

# A no-op `bazel`, so the vanilla path skips its Bazelisk install.
stub_bazel() {
  printf '#!/bin/bash\nexit 0\n' > "${STUB_BIN}/bazel"
  chmod +x "${STUB_BIN}/bazel"
  export PATH="${STUB_BIN}:${PATH}"
}

@test "uses no builtin the macOS system bash lacks" {
  # The shebang asks for `/bin/bash`, which on macOS is 3.2.57 — no `mapfile`
  # or `readarray`. A missing builtin there is quiet: the array stays empty and
  # the flags a pipeline configured never reach the command line. This image
  # runs bash 5, so only a scan catches one coming back.
  run grep -nE "^[[:space:]]*(mapfile|readarray)\\b" "${HOOK}"
  assert_failure
}

@test "points vanilla bazel at the Aspect remote cache when off a Workflows runner" {
  stub_cloud_aspect
  stub_bazel

  run_hook

  assert_success
  assert_output --partial "Not an Aspect Workflows runner"
  refute_output --partial "Detected Aspect Workflows runner"

  # The rc came from an unadorned `aspect setup bazelrc` and is echoed.
  assert_output --partial "aspect setup bazelrc"
  assert_output --partial "Wrote Aspect remote cache bazelrc to ${HOME}/.bazelrc"
  assert_output --partial "common --remote_cache=grpcs://cloud.aspect.build"
  [ -f "${ASPECT_STUB_RAN}" ]

  # Nothing on this path touches the Workflows-runner machinery.
  refute_output --partial "Wrote Workflows-tuned bazelrc"
}

@test "disables the cache in the rc when the token exchange fails" {
  cat > "${STUB_BIN}/aspect" <<EOF
#!/bin/bash
if [[ "\$1" == "auth" && "\$2" == "login" ]]; then
  echo "error: invalid token" >&2
  exit 1
fi
if [[ "\$1" == "setup" && "\$2" == "bazelrc" ]]; then
  echo "ran: \$*" > "\${HOME}/.bazelrc"
  exit 0
fi
exit 2
EOF
  chmod +x "${STUB_BIN}/aspect"
  export PATH="${STUB_BIN}:${PATH}"
  stub_bazel
  export ASPECT_API_TOKEN="client_id:secret"

  run_hook

  assert_success
  # Pointing Bazel at a cache it cannot authenticate to fails the build, so the
  # rc is written with the endpoints off rather than not written at all.
  assert_output --partial "will not enable the remote cache or BES"
  assert_output --partial "aspect setup bazelrc --remote=none"
}

@test "passes the configured remote, home and force through to the rc task" {
  stub_cloud_aspect
  stub_bazel
  export ASPECT_SETUP_REMOTE="exec"
  export ASPECT_SETUP_FORCE="true"

  run_hook

  assert_success
  assert_output --partial "aspect setup bazelrc --remote=exec --force"
}

@test "passes a configured home straight through" {
  stub_cloud_aspect
  stub_bazel
  export ASPECT_SETUP_HOME="false"

  run_hook

  assert_success
  assert_output --partial "aspect setup bazelrc --home=false"
}

@test "passes no rc flags when the orb is unconfigured" {
  stub_cloud_aspect
  stub_bazel

  run_hook

  assert_success
  # Unconfigured is an unadorned run: the CLI detects CI and picks the home rc.
  assert_output --partial "aspect setup bazelrc"
  refute_output --partial "--home"
  refute_output --partial "--remote="
  refute_output --partial "--force"
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

@test "writes no rc when generation is turned off" {
  stub_cloud_aspect
  stub_bazel
  export ASPECT_SETUP_GENERATE="false"

  run_hook

  # The point of the setting: everything but the rc still happens, which is what
  # makes it different from dropping the setup.
  assert_success
  assert_output --partial "leaving Bazel's configuration to this repository"
  refute_output --partial "aspect setup bazelrc"
  [ ! -f "${ASPECT_STUB_RAN}" ]
  assert_output --partial "\`aspect\` already on PATH"
}

@test "writes no rc on a Workflows runner either when generation is turned off" {
  export ASPECT_WORKFLOWS_RUNNER=1
  export ASPECT_SETUP_GENERATE="false"
  stub_aspect
  stub_rosetta

  run_hook

  assert_success
  assert_output --partial "leaving Bazel's configuration to this repository"
  refute_output --partial "Wrote Workflows-tuned bazelrc"
  [ ! -f "${ASPECT_STUB_RAN}" ]
}

@test "retries bare when the CLI rejects a configured flag" {
  stub_flagless_aspect
  stub_bazel
  export ASPECT_SETUP_FORCE="true"

  run_hook

  # A CLI too old for a configured flag still writes the rc without it.
  assert_success
  assert_output --partial "\`aspect setup bazelrc --force\` is unavailable"
  assert_output --partial "Wrote Aspect remote cache bazelrc to ${HOME}/.bazelrc"
  [ -f "${ASPECT_STUB_RAN}" ]
}

@test "warns without failing when the CLI has no bazelrc task at all" {
  stub_old_aspect
  stub_bazel

  run_hook

  # An unconfigurable CLI leaves the job uncached, not broken.
  assert_success
  assert_output --partial "cannot run \`aspect setup bazelrc\`"
  assert_output --partial "https://github.com/aspect-build/aspect-cli/releases"
}

@test "echoes the generated rc, not just the rc that imports it" {
  cat > "${STUB_BIN}/aspect" <<EOF
#!/bin/bash
if [[ "\$1" == "setup" && "\$2" == "bazelrc" ]]; then
  mkdir -p "\${HOME}/.aspect"
  echo "try-import \${HOME}/.aspect/bazelrc" > "\${HOME}/.bazelrc"
  {
    echo 'common:aspect-cloud --remote_cache=grpcs://cache.aspect.build'
    echo 'common:aspect-cloud --remote_header=x-aspect-token=secret-token-value'
  } > "\${HOME}/.aspect/bazelrc"
  exit 0
fi
exit 2
EOF
  chmod +x "${STUB_BIN}/aspect"
  export PATH="${STUB_BIN}:${PATH}"
  stub_bazel

  run_hook

  assert_success
  # The importing rc holds one line; the flags live in the rc it names.
  assert_output --partial "Generated ${HOME}/.aspect/bazelrc:"
  assert_output --partial "common:aspect-cloud --remote_cache=grpcs://cache.aspect.build"
  # Header values carry credentials, so the echo redacts them.
  assert_output --partial "--remote_header=x-aspect-token=<REDACTED>"
  refute_output --partial "secret-token-value"
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
  assert_output --partial "aspect-cli v2026.38.34 or newer"
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
  assert_output --partial "v2026.38.34 or newer"
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

@test "warns when the Aspect CLI is older than the minimum this integration supports" {
  export ASPECT_WORKFLOWS_RUNNER=1
  stub_aspect setup 2026.38.30

  run_hook

  assert_success
  assert_output --partial "Aspect CLI 2026.38.30 is older than v2026.38.34"
  assert_output --partial "Upgrade to the latest release"
}

@test "does not warn when the Aspect CLI is at or above the minimum" {
  export ASPECT_WORKFLOWS_RUNNER=1
  stub_aspect setup 2026.38.34

  run_hook

  assert_success
  refute_output --partial "is older than"
}

@test "compares versions as numbers, not as strings" {
  # 2026.39.9 is newer than 2026.38.34 despite sorting before it as text.
  export ASPECT_WORKFLOWS_RUNNER=1
  stub_aspect setup 2026.39.9

  run_hook

  assert_success
  refute_output --partial "is older than"
}

@test "says nothing about the version of a dev build" {
  export ASPECT_WORKFLOWS_RUNNER=1
  stub_aspect setup "0.0.0-dev (debug build)"

  run_hook

  assert_success
  refute_output --partial "is older than"
}
