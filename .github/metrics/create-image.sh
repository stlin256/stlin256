#!/usr/bin/env bash
#
# Build a locally patched copy of the lowlighter/metrics Docker image.
#
# See .github/metrics/README.md for the background: the upstream action silently
# renders a zeroed statistics card whenever the big repository GraphQL query hits
# the GitHub API timeout, because its batch-halving retry never actually retries.
#
# The action is then run with `use_prebuilt_image: "no"`, which makes it use a
# local image tagged `metrics:<version>` instead of pulling the unpatched one.
set -euo pipefail

# Image currently used by the pinned lowlighter/metrics action, and the version
# its package.json reports (this is the local tag the action looks for when
# prebuilt images are disabled).
UPSTREAM_IMAGE="ghcr.io/lowlighter/metrics:v3.34-beta"
LOCAL_IMAGE="metrics:3.34.0"

# sha256 of the unpatched source/plugins/base/index.mjs the patch is based on.
EXPECTED_UPSTREAM_SHA256="6ae13a4fe90653c35ceab836abc87710cf93dbf300869da479019210ba256176"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCHED_PLUGIN="${SCRIPT_DIR}/base-index.patched.mjs"

echo "Pulling ${UPSTREAM_IMAGE}"
docker image pull "${UPSTREAM_IMAGE}"

container="$(docker create "${UPSTREAM_IMAGE}")"
cleanup() {
  docker rm -f "${container}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker cp "${container}:/metrics/source/plugins/base/index.mjs" /tmp/base-index.upstream.mjs
actual_sha256="$(sha256sum /tmp/base-index.upstream.mjs | cut -d' ' -f1)"
echo "Upstream base plugin sha256: ${actual_sha256}"
if [ "${actual_sha256}" != "${EXPECTED_UPSTREAM_SHA256}" ]; then
  echo "::warning::Upstream base plugin differs from the version this patch was written for; check .github/metrics/base-index.patched.mjs"
fi

docker cp "${PATCHED_PLUGIN}" "${container}:/metrics/source/plugins/base/index.mjs"
docker commit "${container}" "${LOCAL_IMAGE}"

docker image inspect "${LOCAL_IMAGE}" >/dev/null
echo "Prepared ${LOCAL_IMAGE} from ${UPSTREAM_IMAGE}"
