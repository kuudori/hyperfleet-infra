#!/usr/bin/env bash

set -euo pipefail

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: required command not found: $1" >&2
        exit 1
    }
}

assert_contains() {
    local output=$1 pattern=$2 message=$3
    grep -Fq -- "$pattern" <<<"$output" || {
        echo "ERROR: $message" >&2
        exit 1
    }
}

assert_not_contains() {
    local output=$1 pattern=$2 message=$3
    ! grep -Fq -- "$pattern" <<<"$output" || {
        echo "ERROR: $message" >&2
        exit 1
    }
}

render_api() {
    PATH="$fake_bin:$PATH" HELMFILE_ENV=kind NAMESPACE=hf-validate AUTH_MODE="$1" OIDC_ISSUER_MODE=external \
        OIDC_ISSUER_URL=https://human-issuer.invalid \
        OIDC_JWKS_URL=https://human-issuer.invalid/jwks \
        helmfile -f helmfile/helmfile.yaml.gotmpl -e kind -l component=api template
}

require_command helmfile

fake_bin=$(mktemp -d)
cleanup() {
    rm -rf "$fake_bin"
}
trap cleanup EXIT HUP INT TERM

cat >"$fake_bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
    "config current-context")
        echo "${FAKE_KUBECTL_CONTEXT:-kind-hf-validate}"
        ;;
    *"create clusterrolebinding hyperfleet-anonymous-service-account-issuer-discovery"*)
        cat <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
YAML
        ;;
    "apply -f -")
        cat >/dev/null
        ;;
    "get --raw=/.well-known/openid-configuration")
        if [[ "${FAKE_KUBECTL_CONTEXT:-kind-hf-validate}" == gke-* ]]; then
            cat <<JSON
{"issuer":"https://container.googleapis.com/v1/projects/test/locations/us-central1-a/clusters/test","jwks_uri":"https://10.100.0.68:443/openid/v1/jwks"}
JSON
        else
            cat <<JSON
{"issuer":"https://kubernetes.default.svc.cluster.local","jwks_uri":"https://kubernetes.default.svc.cluster.local/openid/v1/jwks"}
JSON
        fi
        ;;
    *)
        echo "unexpected kubectl invocation: $*" >&2
        exit 1
        ;;
esac
EOF
chmod +x "$fake_bin/kubectl"

for mode in NONE EDGE API EDGE+API; do
    if ! out=$(render_api "$mode"); then
        echo "ERROR: API render failed for AUTH_MODE=$mode" >&2
        exit 1
    fi

    case "$mode" in
        NONE|EDGE)
            assert_contains "$out" $'      jwt:\n      enabled: false' \
                "($mode): API JWT must be disabled"
            ;;
        API)
            assert_contains "$out" 'identity_claim_pattern: "^system:serviceaccount:' \
                'API mode lacks the Kubernetes ServiceAccount issuer configuration'
            assert_contains "$out" 'jwk_cert_url: "https://kubernetes.default.svc.cluster.local/openid/v1/jwks"' \
                'API mode does not use the discovered Kubernetes JWKS URL'
            assert_contains "$out" 'jwk_cert_ca_file: "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"' \
                'Kind API mode does not configure the Kubernetes ServiceAccount CA'
            assert_not_contains "$out" 'jwk_cert_file: "/etc/hyperfleet/kubernetes-oidc/jwks.json"' \
                'API mode must not use a local Kubernetes JWKS file'
            ;;
        EDGE+API)
            assert_contains "$out" \
                'issuer_url: "https://authorino-authorino-oidc.hf-validate.svc:8083/hf-validate/hyperfleet-tenant-policy/wristband"' \
                'EDGE+API does not validate the wristband issuer'
            assert_contains "$out" 'jwk_cert_ca_file: "/etc/hyperfleet/gateway-ca/ca.crt"' \
                'EDGE+API does not trust the gateway CA'
            assert_not_contains "$out" 'issuer_url: "https://kubernetes.default.svc.cluster.local"' \
                'EDGE+API must not accept original ServiceAccount tokens'
            ;;
    esac
done

if ! out=$(PATH="$fake_bin:$PATH" HELMFILE_ENV=kind NAMESPACE=hf-validate AUTH_MODE=API OIDC_ISSUER_MODE=external \
    OIDC_ISSUER_URL=https://human-issuer.invalid OIDC_JWKS_URL=https://human-issuer.invalid/jwks \
    helmfile -f helmfile/helmfile.yaml.gotmpl -e kind -l component=api template); then
    echo 'ERROR: API render failed with a human provider' >&2
    exit 1
fi

assert_contains "$out" 'issuer_url: "https://human-issuer.invalid"' \
    'API mode lacks the configured human issuer'
assert_contains "$out" 'jwk_cert_url: "https://human-issuer.invalid/jwks"' \
    'API mode lacks the configured human JWKS URL'
assert_contains "$out" 'audience: "hyperfleet-api"' \
    'API mode must use the fixed hyperfleet-api audience'
assert_contains "$out" 'identity_claim: "sub"' \
    'API mode must use the fixed sub identity claim'

if ! out=$(PATH="$fake_bin:$PATH" FAKE_KUBECTL_CONTEXT=gke-test \
    HELMFILE_ENV=kind NAMESPACE=hf-validate AUTH_MODE=API OIDC_ISSUER_MODE=external \
    OIDC_ISSUER_URL=https://human-issuer.invalid OIDC_JWKS_URL=https://human-issuer.invalid/jwks \
    helmfile -f helmfile/helmfile.yaml.gotmpl -e kind -l component=api template); then
    echo 'ERROR: API render failed with a GKE discovery response' >&2
    exit 1
fi

assert_contains "$out" \
    'jwk_cert_url: "https://container.googleapis.com/v1/projects/test/locations/us-central1-a/clusters/test/jwks"' \
    'GKE API mode did not replace the internal JWKS URL with the public endpoint'
assert_contains "$out" \
    'jwk_cert_ca_file: "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"' \
    'GKE API mode lost the Kubernetes CA configuration'

if out=$(PATH="$fake_bin:$PATH" HELMFILE_ENV=kind NAMESPACE=hf-validate AUTH_MODE=API OIDC_ISSUER_MODE=external \
    OIDC_ISSUER_URL=https://human-issuer.invalid \
    helmfile -f helmfile/helmfile.yaml.gotmpl -e kind -l component=api template 2>&1); then
    echo 'ERROR: API render succeeded without OIDC_JWKS_URL for the human provider' >&2
    exit 1
fi

assert_contains "$out" 'OIDC_JWKS_URL is required when OIDC_ISSUER_URL is set for the human provider' \
    'API render did not explain that the human provider requires OIDC_JWKS_URL'

echo 'OK: API authentication mode wiring valid'
