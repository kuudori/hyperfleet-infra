#!/usr/bin/env bash
set -euo pipefail

# Explicit context prevents accidentally testing a different current cluster.
context="${1:?Usage: test-network-policy-enforcement.sh <kubectl-context>}"
namespace="network-policy-smoke-$(date +%s)-$$"
server_image="${NETWORK_POLICY_SERVER_IMAGE:-nginx:1.28-alpine}"
client_image="${NETWORK_POLICY_CLIENT_IMAGE:-curlimages/curl:8.16.0}"

# Run kubectl against the explicit context, never the caller's current context.
k() {
    kubectl --context="${context}" "$@"
}

# Remove only the namespace created by this run and preserve failures on exit.
cleanup() {
    local status=$?
    if ! k delete namespace "${namespace}" --wait=false; then
        echo "ERROR: cleanup failed; delete scratch namespace ${namespace} in context ${context}" >&2
        status=1
    fi
    trap - EXIT
    exit "${status}"
}

# Install the cleanup trap only after successfully creating our own namespace.
if [ "$(k config get-contexts "${context}" -o name)" != "${context}" ]; then
    echo "ERROR: kubectl context does not exist: ${context}" >&2
    exit 1
fi
k create namespace "${namespace}"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
k -n "${namespace}" run server --image="${server_image}" --restart=Never --labels=app=network-policy-server
k -n "${namespace}" run client --image="${client_image}" --restart=Never --command -- sleep 1800
k -n "${namespace}" wait --for=condition=Ready pod/server pod/client --timeout=180s
server_ip=$(k -n "${namespace}" get pod server -o jsonpath='{.status.podIP}')
if [ -z "${server_ip}" ]; then
    echo "ERROR: server pod has no IP" >&2
    exit 1
fi

# Probe the server directly, with bounded connection and request timeouts.
curl_server() {
    # Direct pod IP avoids DNS or Service failures masquerading as enforcement.
    k -n "${namespace}" exec client -- curl --noproxy '*' -fsS \
        --connect-timeout 3 --max-time 5 "http://${server_ip}/" >/dev/null
}

# Allow startup or policy-removal propagation, but fail if access never returns.
wait_for_access() {
    for ((attempt = 0; attempt < 30; attempt++)); do
        if curl_server; then
            return 0
        fi
        sleep 2
    done
    echo "ERROR: client cannot reach server without a deny policy" >&2
    return 1
}

echo "Checking baseline connectivity in ${context}/${namespace}..."
wait_for_access

k -n "${namespace}" apply -f - <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
spec:
  podSelector: {}
  policyTypes:
    - Ingress
YAML

echo "Waiting for default-deny ingress enforcement..."
blocked=false
for ((attempt = 0; attempt < 30; attempt++)); do
    if curl_server; then
        sleep 2
    else
        status=$?
        # Only a curl timeout proves traffic was dropped. Exec failures, HTTP
        # errors, and connection refusals are not accepted as proof of enforcement.
        if [ "${status}" -ne 28 ]; then
            echo "ERROR: unexpected curl/exec failure (${status}); cannot prove enforcement" >&2
            exit 1
        fi
        blocked=true
        break
    fi
done
if [ "${blocked}" != true ]; then
    echo "ERROR: default-deny ingress was ignored; NetworkPolicy enforcement is missing" >&2
    exit 1
fi

k -n "${namespace}" delete networkpolicy default-deny-ingress
echo "Checking connectivity recovers after removing the policy..."
wait_for_access
echo "OK: baseline allowed, default-deny blocked, and connectivity restored"
