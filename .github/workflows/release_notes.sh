#!/usr/bin/env bash
# Emit the release-notes body for a release of this CircleCI orb. The headline
# content is a copy-paste snippet showing how to consume the published orb
# version. GitHub appends its auto-generated changelog below this body
# (generate_release_notes: true).
#
# Required env: REPO (owner/name), SHA (full commit), TAG (e.g. v2026.25.0),
#               ORB_VERSION (the bare semver, e.g. 2026.25.0).

set -o errexit -o nounset -o pipefail

cat <<EOF
### Use this release

Published to the CircleCI registry as
[\`aspect-build/setup-aspect@${ORB_VERSION}\`](https://circleci.com/developer/orbs/orb/aspect-build/setup-aspect?version=${ORB_VERSION}).

\`\`\`yaml
version: 2.1

orbs:
  setup-aspect: aspect-build/setup-aspect@${ORB_VERSION}

jobs:
  bazel-custom:
    machine: true
    resource_class: YOUR-ORG/aspect-default
    working_directory: /mnt/ephemeral/workdir
    steps:
      - checkout
      - aspect-workflows/setup
      - run: bazel run //hello:world
\`\`\`

Pin to a specific \`X.Y.Z\` version rather than a floating \`@volatile\` or major-only
range so builds are reproducible.
EOF
