# Setup Aspect CircleCI orb

A [CircleCI orb](https://circleci.com/docs/orb-intro/) that sets a job up so
that **raw `bazel <verb>` calls** — not just `aspect <task>` — reach an Aspect
cache.

The CircleCI counterpart of the [`aspect-build/setup-aspect`](https://github.com/aspect-build/setup-aspect)
GitHub Action and the [`aspect-build/setup-aspect-buildkite-plugin`](https://github.com/aspect-build/setup-aspect-buildkite-plugin)
Buildkite plugin.

## Two modes

The setup looks at `ASPECT_WORKFLOWS_RUNNER` and takes one of two paths.

### On any CircleCI executor — the Aspect remote cache

This is the path that lets an existing pipeline try Aspect without moving to
Aspect Workflows runners. It:

1. **Installs the Aspect CLI launcher and Bazelisk**, each skipped when the
   binary is already on `PATH`. The launcher reads `.aspect/version.axl` from
   your repository and fetches the matching CLI on first use, so the CLI version
   stays pinned by the repo; `ASPECT_LAUNCHER_VERSION` pins only the launcher.
2. **Authenticates** with `aspect auth login --with-api-token` when
   `ASPECT_API_TOKEN` is set. The token is piped on stdin — never an argument —
   and the short-lived JWT the CLI persists is what later `aspect` calls and the
   Bazel credential helper use.
3. **Writes `~/.bazelrc`** with `aspect setup bazelrc --home`, pointing vanilla
   `bazel` at the Aspect deployment's remote cache and BES. A plain
   `bazel build //...` then shares a cache with every other job and branch and
   streams the build to Aspect; `aspect build --remote //...` reaches the same
   deployment.

`--home` is what keeps the rc out of the checkout. Without it the task writes
`<workspace>/.aspect/bazelrc` and a `try-import` in the workspace `.bazelrc` —
files meant to be committed, not generated on a runner and thrown away with it.

### On an Aspect Workflows runner — the runner's own caches

`aspect <task>` already wires itself into the runner's remote cache, BES
backend, and local NVMe disk cache. Steps that call `bazel` directly would otherwise miss all of
that, so the setup:

1. **Logs the runner's metadata** for traceability.
2. **Waits for cache warming to complete.** `aspect <task>` performs this wait
   itself; a vanilla `bazel` call would otherwise race the still-running
   bootstrap warming — competing for CPU/disk and missing the warmed caches.
3. **Authenticates**, as above.
4. **Generates the runner's Bazel rc** via `aspect setup bazelrc`, with a legacy
   fallback for runners whose CLI predates that task. If neither is available it
   warns but **does not fail the build** — warming is done and `aspect <task>`
   steps are unaffected.

## Authentication

Set `ASPECT_API_TOKEN` to a long-lived `<CLIENT_ID>:<SECRET>` Aspect API token,
from a CircleCI context or project environment variable. Without it the rc is still written — the task defaults to the
Aspect Cloud deployment and needs no login — but Bazel will reach that cache
unauthenticated.

The orb appends its `PATH` additions to `${BASH_ENV}`, so `aspect` and `bazel`
are on `PATH` in the job's later steps, not just inside the `setup` command.


## Usage

Add the `setup` command after `checkout` and before any `bazel` step:

```yaml
version: 2.1

orbs:
  setup-aspect: aspect-build/setup-aspect@2026.25.0

jobs:
  bazel-custom:
    machine: true
    resource_class: YOUR-ORG/aspect-default
    working_directory: /mnt/ephemeral/workdir
    steps:
      - checkout
      - setup-aspect/setup
      - run: bazel run //hello:world
```

The rc generator reads the workspace's `.bazelversion`, so `setup` must run
**after** `checkout`.

`aspect <task>` jobs don't need the orb (they self-configure).

## Requirements

- An Aspect Workflows CircleCI runner (sets `ASPECT_WORKFLOWS_RUNNER`). On any
  other executor the `setup` command no-ops.
- A repo with a committed `.bazelversion` (the rc generator resolves the Bazel
  version from it and has no fallback).
- `aspect`, `bazel`, and `rosetta` are provided by the Workflows runner image.

## Versioning

Published to the CircleCI registry as `aspect-build/setup-aspect@X.Y.Z`,
where `X.Y` is the `YYYY.VV` (year.ISO-week) tag and `Z` is the commits since it
— matching the Aspect CLI's scheme. Pin to a concrete `X.Y.Z`, not a floating
range, for reproducible builds.

## Development

See [DEVELOPMENT.md](DEVELOPMENT.md):

```sh
docker compose run --rm tests   # BATS suite over src/scripts/setup.sh
circleci orb pack src | circleci orb validate -
```

## License

Apache-2.0. See [LICENSE](LICENSE).
