#!/usr/bin/env bash
#
# Commit the first complete metrics render as github-metrics.svg.
#
# The render attempts are written to /metrics_renders by the metrics action
# (with `output_action: none`). A render is only accepted when its stargazer
# count matches the value computed from the REST API, so a broken (zeroed)
# render can never overwrite a good card.
set -euo pipefail

RENDERS_DIR="/metrics_renders"
OUTPUT_FILE="github-metrics.svg"
TARGET_BRANCH="${TARGET_BRANCH:?TARGET_BRANCH env var is required}"

# Renders are written by the metrics container as root.
if [ -d "${RENDERS_DIR}" ]; then
  sudo chmod -R a+rX "${RENDERS_DIR}" 2>/dev/null || true
fi

# Expected stargazer count: owned, non-fork repositories (same definition metrics uses).
expected=""
if [ -n "${METRICS_TOKEN:-}" ]; then
  expected=0
  page=1
  while :; do
    response=""
    if ! response="$(curl -fsS --retry 2 \
      -H "Authorization: Bearer ${METRICS_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/user/repos?per_page=100&page=${page}&affiliation=owner&visibility=all")"; then
      expected=""
      break
    fi
    count="$(jq 'length' <<<"${response}")"
    if [ "${count}" -eq 0 ]; then
      break
    fi
    page_stars="$(jq '[.[] | select(.fork == false) | .stargazers_count] | add // 0' <<<"${response}")"
    expected=$((expected + page_stars))
    if [ "${count}" -lt 100 ]; then
      break
    fi
    page=$((page + 1))
  done
fi
echo "Expected stargazer count: ${expected:-unknown}"

min_stars=0
if [ -n "${expected}" ] && [ "${expected}" -gt 3 ]; then
  min_stars=$((expected - 3))
fi

valid_render=""
for render in "${RENDERS_DIR}"/metrics-attempt-*.svg; do
  if [ ! -f "${render}" ]; then
    continue
  fi
  stars="$(grep -oE '[0-9]+ Stargazers' "${render}" | head -n 1 | grep -oE '^[0-9]+' || true)"
  if [ -z "${stars}" ]; then
    echo "::warning::$(basename "${render}") does not contain repository statistics"
    continue
  fi
  echo "$(basename "${render}"): ${stars} stargazers"
  if [ -n "${expected}" ]; then
    if [ "${stars}" -ge "${min_stars}" ]; then
      valid_render="${render}"
      break
    fi
  elif [ "${stars}" -gt 0 ]; then
    valid_render="${render}"
    break
  fi
done

if [ -z "${valid_render}" ]; then
  echo "::warning::No complete metrics render was produced (GitHub API timeouts); keeping the previous stats card"
  exit 0
fi

echo "Selected $(basename "${valid_render}")"

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

for attempt in 1 2 3 4 5; do
  git fetch -q origin "${TARGET_BRANCH}"
  git reset -q --hard FETCH_HEAD
  cp "${valid_render}" "${OUTPUT_FILE}"
  git add "${OUTPUT_FILE}"
  if git diff --cached --quiet; then
    echo "Stats card did not change"
    exit 0
  fi
  git commit -q -m "Update ${OUTPUT_FILE} - [Skip GitHub Action]"
  if git push -q origin "HEAD:${TARGET_BRANCH}"; then
    echo "Committed updated stats card to ${TARGET_BRANCH}"
    exit 0
  fi
  echo "Push failed, retrying (attempt ${attempt}/5)"
  sleep $((attempt * 2))
done

echo "::error::Unable to push the updated stats card"
exit 1
