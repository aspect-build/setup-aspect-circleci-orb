# Development

## Layout

| Path | What |
|---|---|
| `src/@orb.yml` | Orb metadata (version, description, display URLs). |
| `src/commands/setup.yml` | The `setup` command — inlines `scripts/setup.sh` via `<<include(...)>>`. |
| `src/scripts/setup.sh` | The vendored, provider-neutral setup logic: runner guard, metadata, warming wait, `.bazelversion` preflight, `rosetta bazelrc` → `/etc/bazel.bazelrc`, deprecation signal. Ported from `aspect-build/setup-aspect`. |
| `tests/setup.bats` | BATS tests over `src/scripts/setup.sh`, via the `buildkite/plugin-tester` image. |
| `.github/workflows/ci.yaml` | CI: BATS tests, shellcheck, and `circleci orb pack` + `validate`. |
| `.github/workflows/` | Weekly tagging and the manual release+publish workflow (+ their `release_*.sh` helpers). See [Releasing](#releasing). |

## The vendored `setup.sh`

`src/scripts/setup.sh` is **vendored** — a copy of the same provider-neutral
script used by the Buildkite plugin and (soon) the GitLab component. For now each
integration keeps its own copy; if it drifts, reconcile by hand. The script takes
no CircleCI-specific assumptions: it honors `$BASH_ENV` for cross-step env
propagation when present (the CircleCI mechanism) and otherwise plain-`export`s.

## Test

```sh
docker compose run --rm tests
```

Runs `tests/setup.bats` in the [`buildkite/plugin-tester`](https://github.com/buildkite-plugins/buildkite-plugin-tester)
image (BATS + `bats-assert`). Tests redirect the `/etc/bazel.bazelrc` write to a
temp file (`ASPECT_WORKFLOWS_PLUGIN_SYSTEM_BAZELRC`) so they don't need root, and
stub `rosetta` on `PATH`.

## Validate the orb

```sh
circleci orb pack src > orb.yml
circleci orb validate orb.yml
```

CI runs both on every PR (no CircleCI account needed — the CLI installs on the
GitHub Actions runner).

## Releasing

Two tiers of tags, matching `aspect-build/aspect-cli`:

| | Tag | Workflow | Trigger | Publishes orb? |
|---|---|---|---|---|
| **Weekly** | `YYYY.VV` (e.g. `2026.25`) | `weekly_tag.yaml` | cron + push to main | no |
| **Release** | `vYYYY.VV.N` (e.g. `v2026.25.0`) | `tag_release.yaml` | manual `workflow_dispatch` | yes |

`tag_release.yaml` computes `vYYYY.VV.N` (`release_version.sh`), then packs,
validates, and **publishes the orb** to the CircleCI registry as
`aspect-build/setup-aspect@YYYY.VV.N` (the bare form is valid semver), and
creates a GitHub Release whose notes lead with a copy-paste usage snippet.

Publishing requires a CircleCI personal API token with publish rights to the
`aspect-build` namespace, stored as the **`CIRCLECI_TOKEN`** repo secret.
