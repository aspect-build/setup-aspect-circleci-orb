# Aspect Workflows CircleCI orb

A [CircleCI orb](https://circleci.com/docs/orb-intro/) that prepares an
[Aspect Workflows](https://docs.aspect.build/workflows) CI runner so that **raw
`bazel <verb>` calls** — not just `aspect <task>` — route through the runner's
caching infrastructure.

The CircleCI counterpart of the [`aspect-build/setup-aspect`](https://github.com/aspect-build/setup-aspect)
GitHub Action and the [`aspect-build/setup-aspect-buildkite-plugin`](https://github.com/aspect-build/setup-aspect-buildkite-plugin)
Buildkite plugin.

## Why

On an Aspect Workflows runner, `aspect <task>` already wires itself into the
runner's remote cache, BES backend, and local NVMe disk cache. Steps that call
`bazel` directly would otherwise miss all of that. The orb's `setup` command:

1. Logs the runner's metadata for traceability.
2. Waits for the runner's cache warming to complete (a raw `bazel` call would
   otherwise race the still-running bootstrap warming).
3. Generates a Bazel rc so raw `bazel` picks up the Workflows-tuned
   configuration: `aspect ci bazelrc` (writes `~/.bazelrc`) when available,
   falling back to `rosetta bazelrc` (writes `/etc/bazel.bazelrc`) on older
   runners. If neither is available it warns but does not fail the job.

On a non-Workflows runner it no-ops gracefully.

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
- A repo with a committed `.bazelversion` (`rosetta bazelrc` resolves the Bazel
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
