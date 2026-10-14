#!/bin/bash
set -eo pipefail

LABEL_SELECTOR="${LABEL_SELECTOR:-hyperfleet.io/cluster-id hyperfleet.io/test-run}"
AGE_MINUTES="${AGE_MINUTES:-120}"
DRY_RUN="${DRY_RUN:-false}"

if [ -z "${LABEL_SELECTOR}" ]; then
  echo "[ERROR] LABEL_SELECTOR must not be empty" >&2; exit 1
fi
if ! echo "${AGE_MINUTES}" | grep -qE '^[1-9][0-9]*$'; then
  echo "[ERROR] AGE_MINUTES must be a positive integer, got: '${AGE_MINUTES}'" >&2; exit 1
fi
if [ "${DRY_RUN}" != "true" ] && [ "${DRY_RUN}" != "false" ]; then
  echo "[ERROR] DRY_RUN must be 'true' or 'false', got: '${DRY_RUN}'" >&2; exit 1
fi

NOW=$(date +%s)
AGE_SECONDS=$((AGE_MINUTES * 60))

# Parse an ISO 8601 timestamp to epoch seconds.
# Strips sub-second precision before parsing, then tries:
#   1. GNU date   (Linux, Debian-based images)
#   2. busybox date with -D format flag (Alpine)
#   3. BSD date   (macOS)
parse_timestamp() {
  local ts="${1%%.*}"   # strip sub-second precision
  ts="${ts%Z}Z"         # ensure exactly one trailing Z (handles timestamps with or without fractional seconds)
  date -d "${ts}" +%s 2>/dev/null \
    || date -D "%Y-%m-%dT%H:%M:%SZ" -d "${ts}" +%s 2>/dev/null \
    || TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "${ts}" +%s
}

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [INFO] Starting namespace cleaner (label_selector=${LABEL_SELECTOR}, age_minutes=${AGE_MINUTES}, dry_run=${DRY_RUN})"

# --- Delete stale namespaces (non-blocking) ---
# LABEL_SELECTOR may contain multiple space-separated selectors; each is matched
# independently (OR semantics). Namespaces already Terminating are skipped.
IFS=' ' read -ra _selectors <<< "${LABEL_SELECTOR}"
for selector in "${_selectors[@]}"; do
  kubectl get namespaces -l "${selector}" \
    -o go-template='{{range .items}}{{.metadata.name}}|{{.metadata.creationTimestamp}}|{{.status.phase}}{{"\n"}}{{end}}' \
  | while IFS='|' read -r ns_name created_at phase; do
      [ -z "${ns_name}" ] && continue
      [ "${phase}" != "Active" ] && continue

      created_seconds=$(parse_timestamp "${created_at}") || continue
      age=$((NOW - created_seconds))

      if [ "${age}" -gt "${AGE_SECONDS}" ]; then
        age_m=$((age / 60))
        if [ "${DRY_RUN}" = "true" ]; then
          echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [DRY-RUN] Would delete namespace '${ns_name}' (age=${age_m}m)"
        else
          echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [INFO] Deleting namespace '${ns_name}' (age=${age_m}m)"
          kubectl delete namespace "${ns_name}" --wait=false \
            && echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [INFO] Delete requested for namespace '${ns_name}'" \
            || echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [WARN] Failed to delete namespace '${ns_name}'"
        fi
      fi
    done
done

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [INFO] Namespace cleaner run complete"
