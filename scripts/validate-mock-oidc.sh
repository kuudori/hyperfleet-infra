#!/usr/bin/env bash

set -euo pipefail

HELM_DIR="${HELM_DIR:-helm}"

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

require_command helm
require_command helmfile

helm lint "$HELM_DIR/mock-oidc"
if ! out=$(helm template hyperfleet-mock-oidc "$HELM_DIR/mock-oidc" --namespace test); then
    echo "ERROR: mock OIDC chart failed to render" >&2
    exit 1
fi

assert_contains "$out" 'kind: NetworkPolicy' 'mock OIDC ingress NetworkPolicy is missing'
assert_contains "$out" 'app.kubernetes.io/component: token-helper' \
    'mock OIDC ingress does not allow the token helper pod'
assert_contains "$out" 'app.kubernetes.io/component: api' \
    'mock OIDC ingress does not allow hyperfleet-api to fetch JWKS in API mode'
assert_contains "$out" 'authorino-resource: authorino' \
    'mock OIDC ingress does not allow the Authorino pod'
if ! tls_out=$(helm template hyperfleet-mock-oidc "$HELM_DIR/mock-oidc" --namespace test --set tls.enabled=true); then
    echo 'ERROR: TLS mock OIDC chart failed to render' >&2
    exit 1
fi
assert_contains "$tls_out" 'duration: 876000h' \
    'mock OIDC TLS certificate is not explicitly long-lived'
assert_contains "$tls_out" 'policy: Disabled' \
    'mock OIDC TLS certificate has automatic renewal enabled'
assert_contains "$tls_out" 'rotationPolicy: Never' \
    'mock OIDC TLS private key rotation is enabled'
assert_contains "$tls_out" 'keyPassword\":\"changeit' \
    'mock OIDC server key password does not match the cert-manager PKCS#12 keystore password'
if grep -Fq 'kubernetes.io/metadata.name' <<<"$out"; then
    echo 'ERROR: mock OIDC ingress must not allow the entire namespace' >&2
    exit 1
fi
grep -Fq -- '--labels=app.kubernetes.io/component=token-helper' scripts/mint-human-token.sh || {
    echo 'ERROR: mock token helper pod label is missing' >&2
    exit 1
}

for environment in kind e2e-kind e2e-gcp; do
    namespace="hf-validate-$environment"
    if ! build=$(HELMFILE_ENV="$environment" NAMESPACE="$namespace" AUTH_MODE=EDGE \
        OIDC_ISSUER_MODE=mock OIDC_ISSUER_URL='' \
        helmfile -f helmfile/helmfile.yaml.gotmpl -e "$environment" build); then
        echo "ERROR: mock-mode build failed for $environment" >&2
        exit 1
    fi
    assert_contains "$build" 'name: hyperfleet-mock-oidc' \
        "mock OIDC release missing for $environment EDGE mode"

    if ! rendered=$(HELMFILE_ENV="$environment" NAMESPACE="$namespace" AUTH_MODE=EDGE \
        OIDC_ISSUER_MODE=mock OIDC_ISSUER_URL='' \
        helmfile -f helmfile/helmfile.yaml.gotmpl -e "$environment" -l component=gateway template); then
        echo "ERROR: mock-mode gateway render failed for $environment" >&2
        exit 1
    fi
    assert_contains "$rendered" \
        "issuerUrl: \"https://hyperfleet-mock-oidc.$namespace.svc.cluster.local:8443/default\"" \
        "TLS mock issuer was not passed to the gateway for $environment"
    assert_contains "$rendered" 'mountPath: /etc/pki/ca-trust/extracted/pem' \
        "gateway Authorino does not mount a TLS trust directory for $environment"
    assert_contains "$rendered" '  - hyperfleet-mock-oidc-tls' \
        "gateway Authorino does not trust the TLS mock issuer for $environment"
done

if HELMFILE_ENV=gcp NAMESPACE=hf-validate-gcp AUTH_MODE=EDGE OIDC_ISSUER_MODE=mock \
    helmfile -f helmfile/helmfile.yaml.gotmpl -e gcp build >/dev/null 2>&1; then
    echo 'ERROR: regular gcp accepted test-only mock OIDC' >&2
    exit 1
fi

if ! api_mode_rendered=$(HELMFILE_ENV=kind NAMESPACE=hf-validate-kind AUTH_MODE=API OIDC_ISSUER_MODE=mock \
    helmfile -f helmfile/helmfile.yaml.gotmpl -e kind -l component=api template); then
    echo 'ERROR: API-mode API render failed' >&2
    exit 1
fi
assert_contains "$api_mode_rendered" \
    'issuer_url: "https://hyperfleet-mock-oidc.hf-validate-kind.svc.cluster.local:8443/default"' \
    'API mode did not configure the TLS mock issuer'
assert_contains "$api_mode_rendered" \
    'jwk_cert_ca_file: "/etc/hyperfleet/mock-oidc-ca/ca.crt"' \
    'API mode did not mount the TLS mock issuer CA'
if grep -Fq 'http://hyperfleet-mock-oidc' <<<"$api_mode_rendered"; then
    echo 'ERROR: API mode configured an insecure mock issuer' >&2
    exit 1
fi

if HELMFILE_ENV=gcp NAMESPACE=hf-validate-gcp AUTH_MODE=EDGE OIDC_ISSUER_MODE=external \
    OIDC_ISSUER_URL=http://issuer.invalid \
    helmfile -f helmfile/helmfile.yaml.gotmpl -e gcp build >/dev/null 2>&1; then
    echo 'ERROR: external edge mode accepted an HTTP issuer' >&2
    exit 1
fi

if HELMFILE_ENV=kind NAMESPACE=hf-validate-kind AUTH_MODE=EDGE OIDC_ISSUER_MODE=external OIDC_ISSUER_URL='' \
    helmfile -f helmfile/helmfile.yaml.gotmpl -e kind build >/dev/null 2>&1; then
    echo 'ERROR: EDGE external mode accepted an empty issuer' >&2
    exit 1
fi
if HELMFILE_ENV=kind NAMESPACE=hf-validate-kind AUTH_MODE=EDGE+API OIDC_ISSUER_MODE=external OIDC_ISSUER_URL='' \
    helmfile -f helmfile/helmfile.yaml.gotmpl -e kind build >/dev/null 2>&1; then
    echo 'ERROR: EDGE+API external mode accepted an empty issuer' >&2
    exit 1
fi

if helm template gw "$HELM_DIR/hyperfleet-gateway" --set-string auth.mode=EDGE >/dev/null 2>&1; then
    echo 'ERROR: gateway accepted EDGE mode without a human identity provider' >&2
    exit 1
fi
if helm template gw "$HELM_DIR/hyperfleet-gateway" --set-string auth.mode=EDGE+API >/dev/null 2>&1; then
    echo 'ERROR: gateway accepted EDGE+API mode without a human identity provider' >&2
    exit 1
fi

echo 'OK: mock OIDC chart and AUTH_MODE integration valid'
