#!/usr/bin/env bash
# shellcheck disable=SC2016
# The nested single-quoted scripts run in short-lived in-cluster curl pods.
# Exercise the gateway identity boundary, tenant isolation, machine callers,
# reconciliation, tenant-model switching, and the API ingress NetworkPolicy.

set -euo pipefail

PHASE="${1:-}"
NAMESPACE="${NAMESPACE:-}"
HELMFILE_ENV="${HELMFILE_ENV:-}"
OIDC_ISSUER_MODE="${OIDC_ISSUER_MODE:-}"
AUTH_MODE="${AUTH_MODE:-NONE}"
TENANT_ISOLATION_ENABLED="${TENANT_ISOLATION_ENABLED:-false}"
TENANT_MODEL="${TENANT_MODEL:-onprem}"
GATEWAY_SERVICE="${GATEWAY_SERVICE:-hyperfleet-gateway}"
API_SERVICE="${API_SERVICE:-hyperfleet-api}"
CILIUM_NAMESPACE="${CILIUM_NAMESPACE:-kube-system}"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:8.22.0@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777}"
GATEWAY_E2E_TIMEOUT="${GATEWAY_E2E_TIMEOUT:-300}"
GATEWAY_E2E_POLL_INTERVAL="${GATEWAY_E2E_POLL_INTERVAL:-5}"

api_path="/api/hyperfleet/v1"
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
run_id="$(date +%s)-${RANDOM}"
pod_labels="app.kubernetes.io/component=gateway-e2e,hyperfleet.io/gateway-e2e-run=${run_id}"
current_cluster_id=""
# Mock issuer tokens expire 600s after minting (helm/mock-oidc tokenExpiry).
# The Cluster owner's token is re-minted once it is half that old, so the
# reconciliation and deletion waits never send an expired token.
owner_token_max_age=300
owner_subject=""
owner_tenant=""
owner_subtenant=""
owner_token=""
owner_token_minted=0
temporary_service_account=""
restore_onprem=false
# Report state: the checks that passed, the check running now with a fix to
# suggest if it fails, and the last failure message.
results=()
current_check=""
current_hint=""
failure_reason=""

usage() {
    echo "usage: $0 {human|current-model|full}" >&2
}

error() {
    echo "ERROR: $*" >&2
}

fail() {
    failure_reason="$*"
    error "$@"
    exit 1
}

# Name the check that runs next. If the suite stops before pass, the report
# shows this check, the failure, and the optional hint.
check() {
    current_check="$1"
    current_hint="${2:-}"
}

pass() {
    results+=("PASS  ${TENANT_MODEL}  ${current_check}")
    printf 'PASS  %s  %s\n' "$TENANT_MODEL" "$current_check"
}

print_report() {
    local status="$1"
    local failed_model="$2"
    local cleanup_status="$3"
    local restore_status="$4"
    local line
    printf '\nGateway e2e report (phase %s, namespace %s, AUTH_MODE=%s)\n' "$PHASE" "$NAMESPACE" "$AUTH_MODE"
    if (( ${#results[@]} > 0 )); then
        for line in "${results[@]}"; do
            printf '  %s\n' "$line"
        done
    fi
    if (( status != 0 )); then
        printf '  FAIL  %s  %s\n' "$failed_model" "$current_check"
        [[ -z "$failure_reason" ]] || printf '        %s\n' "$failure_reason"
        [[ -z "$current_hint" ]] || printf '        Fix: %s\n' "$current_hint"
    fi
    if (( cleanup_status != 0 )); then
        printf '  Cleanup failed: delete leftover hf-gateway-e2e-* pods, ServiceAccounts, and Clusters by hand.\n'
    fi
    if [[ "$restore_onprem" == "true" ]]; then
        if (( restore_status == 0 )); then
            printf '  Tenant model restored to onprem.\n'
        else
            printf '  Tenant model NOT restored. Run: HELMFILE_ENV=%s AUTH_MODE=%s OIDC_ISSUER_MODE=mock TENANT_ISOLATION_ENABLED=true make switch-tenant-model TENANT_MODEL=onprem\n' \
                "$HELMFILE_ENV" "$AUTH_MODE"
        fi
    fi
    if (( status != 0 )); then
        printf 'Result: FAILED (%d checks passed; the checks after the failure did not run)\n' "${#results[@]}"
    elif (( cleanup_status != 0 || restore_status != 0 )); then
        printf 'Result: FAILED after all %d checks passed (cleanup or restore)\n' "${#results[@]}"
    else
        printf 'Result: PASSED (%d checks)\n' "${#results[@]}"
    fi
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

response_status() {
    printf '%s' "$1" | head -n 1
}

response_body() {
    printf '%s' "$1" | tail -n +2
}

require_status() {
    local actual
    local expected="$2"
    local description="$3"
    actual=$(response_status "$1")
    [[ "$actual" == "$expected" ]] || fail "$description returned HTTP $actual, expected $expected"
}

require_denial() {
    local actual
    local description="$2"
    actual=$(response_status "$1")
    case "$actual" in
        401|403) ;;
        *) fail "$description returned HTTP $actual, expected 401 or 403" ;;
    esac
}

# Succeed when jq -e accepts the body with the remaining jq arguments.
body_matches() {
    local body="$1"
    shift
    printf '%s' "$body" | jq -e "$@" >/dev/null
}

validate_integer() {
    local name="$1"
    local value="$2"
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || fail "$name must be a positive integer"
}

validate_header() {
    local header="$1"
    [[ "$header" =~ ^[A-Za-z0-9-]+=[A-Za-z0-9._:@+-]*$ ]] || fail "unsupported forged header value"
}

configure_model() {
    case "$TENANT_MODEL" in
        onprem)
            required_key="org"
            optional_key="project"
            required_header="x-tenant-org"
            optional_header="x-tenant-project"
            tenant_a="hf-gateway-e2e-onprem-a-${run_id}"
            tenant_b="hf-gateway-e2e-onprem-b-${run_id}"
            subtenant_a="project-a"
            subtenant_b="project-b"
            ;;
        oracle)
            required_key="tenancy_ocid"
            optional_key="compartment_id"
            required_header="x-tenant-tenancy-ocid"
            optional_header="x-tenant-compartment"
            tenant_a="ocid1.tenancy.oc1..hf${run_id}a"
            tenant_b="ocid1.tenancy.oc1..hf${run_id}b"
            subtenant_a="ocid1.compartment.oc1..hf${run_id}a"
            subtenant_b="ocid1.compartment.oc1..hf${run_id}b"
            ;;
        *) fail "TENANT_MODEL must be onprem or oracle" ;;
    esac
}

validate_inputs() {
    case "$PHASE" in
        human|current-model|full) ;;
        *) usage; exit 1 ;;
    esac
    if [[ "$PHASE" == "full" && "$HELMFILE_ENV" != "kind" ]]; then
        fail "full requires HELMFILE_ENV=kind because it verifies Cilium NetworkPolicy enforcement"
    fi
    require_command kubectl
    require_command jq
    [[ -n "$NAMESPACE" ]] || fail "NAMESPACE is required"
    [[ "$OIDC_ISSUER_MODE" == "mock" ]] || fail "$PHASE requires OIDC_ISSUER_MODE=mock"
    [[ "$AUTH_MODE" == "EDGE" || "$AUTH_MODE" == "EDGE+API" ]] || fail "$PHASE requires AUTH_MODE=EDGE or EDGE+API"
    [[ "$TENANT_ISOLATION_ENABLED" == "true" ]] || fail "$PHASE requires TENANT_ISOLATION_ENABLED=true"
    validate_integer GATEWAY_E2E_TIMEOUT "$GATEWAY_E2E_TIMEOUT"
    validate_integer GATEWAY_E2E_POLL_INTERVAL "$GATEWAY_E2E_POLL_INTERVAL"
    configure_model
}

wait_for_deployment() {
    kubectl rollout status "deployment/$1" --namespace "$NAMESPACE" \
        --timeout="${GATEWAY_E2E_TIMEOUT}s" >/dev/null
}

# Every wait returns explicitly: restore_model runs this from the EXIT trap in
# an || context, where set -e does not stop on a failed wait.
wait_for_components() {
    local sentinel_deployments adapter_deployments deployment
    wait_for_deployment hyperfleet-mock-oidc || return 1
    kubectl wait --for=condition=Ready authconfig/hyperfleet-tenant-policy \
        --namespace "$NAMESPACE" --timeout="${GATEWAY_E2E_TIMEOUT}s" >/dev/null || return 1
    wait_for_deployment "$GATEWAY_SERVICE" || return 1
    wait_for_deployment "$API_SERVICE" || return 1

    sentinel_deployments=$(kubectl get deployments --namespace "$NAMESPACE" \
        -l app.kubernetes.io/name=hyperfleet-sentinel -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}') || return 1
    adapter_deployments=$(kubectl get deployments --namespace "$NAMESPACE" \
        -l app.kubernetes.io/name=hyperfleet-adapter -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}') || return 1
    [[ -n "$sentinel_deployments" ]] || fail "no Sentinel deployments found in namespace $NAMESPACE"
    [[ -n "$adapter_deployments" ]] || fail "no adapter deployments found in namespace $NAMESPACE"
    for deployment in $sentinel_deployments $adapter_deployments; do
        wait_for_deployment "$deployment" || return 1
    done
}

# Print a response as a status line followed by its body. Credentials are read
# from standard input inside the pod and never appear in pod specs or argv.
api_request() {
    local method="$1"
    local path="$2"
    local scheme="$3"
    local token="$4"
    local body=""
    if (( $# >= 5 )); then
        body="$5"
        shift 5
    else
        shift 4
    fi
    local pod_name="hf-gateway-e2e-request-${run_id}-${RANDOM}"
    local header
    for header in "$@"; do
        validate_header "$header"
    done

    printf '%s\n' "$token" | kubectl run "$pod_name" \
        --namespace "$NAMESPACE" \
        --labels="$pod_labels" \
        --image="$CURL_IMAGE" \
        --restart=Never \
        --rm \
        --quiet \
        --stdin \
        --attach \
        --command -- sh -c '
set -eu
read -r token
method="$1"
path="$2"
scheme="$3"
body="$4"
gateway_service="$5"
shift 5
response_file=/tmp/response
headers="$*"
set -- -sS --connect-timeout 5 --max-time 20 -o "$response_file" -w "%{http_code}" -X "$method" "http://${gateway_service}:8000${path}"
if [ "$scheme" != "none" ]; then
    set -- "$@" -H "Authorization: ${scheme} ${token}"
fi
if [ -n "$body" ]; then
    set -- "$@" -H "Content-Type: application/json" --data-raw "$body"
fi
# Forged headers arrive as name=value pairs validated by the outer script to
# contain no whitespace, so this split keeps each one a single curl argument
# without eval. curl ignores a header without a colon, so convert each pair.
for header in $headers; do
    set -- "$@" -H "${header%%=*}: ${header#*=}"
done
status=$(curl "$@")
printf "%s\\n" "$status"
cat "$response_file"
' -- "$method" "$path" "$scheme" "$body" "$GATEWAY_SERVICE" "$@"
}

# The helper's per-token diagnostics are shown only when minting fails.
mint_human_token() {
    local subject="$1"
    local tenant="$2"
    local subtenant="$3"
    local missing_required="${4:-false}"
    local diagnostics token
    diagnostics=$(mktemp)
    if token=$(TOKEN_MISSING_REQUIRED="$missing_required" \
        TOKEN_AUDIENCE="${TOKEN_AUDIENCE:-hyperfleet-api}" \
        TOKEN_SUBJECT="$subject" \
        TOKEN_TENANT="$tenant" \
        TOKEN_SUBTENANT="$subtenant" \
        TENANT_MODEL="$TENANT_MODEL" \
        AUTH_MODE="$AUTH_MODE" \
        OIDC_ISSUER_MODE=mock NAMESPACE="$NAMESPACE" \
        "$SCRIPT_DIR/mint-human-token.sh" 2>"$diagnostics"); then
        rm -f "$diagnostics"
        printf '%s\n' "$token"
        return 0
    fi
    cat "$diagnostics" >&2
    rm -f "$diagnostics"
    return 1
}

# Mint the Cluster owner's token when it is missing or older than
# owner_token_max_age. Call it in this shell before each owner request.
refresh_owner_token() {
    if [[ -n "$owner_token" ]] && (( SECONDS - owner_token_minted < owner_token_max_age )); then
        return 0
    fi
    owner_token=$(mint_human_token "$owner_subject" "$owner_tenant" "$owner_subtenant") || return 1
    owner_token_minted=$SECONDS
}

set_owner() {
    owner_subject="$1"
    owner_tenant="$2"
    owner_subtenant="$3"
    owner_token=""
    refresh_owner_token
}

# Envoy logs UAEX (denied by ext_authz) and no upstream host ("-") for a
# request it answered without contacting the API. Requiring that entry, rather
# than the absence of an API log line, fails when the evidence is missing.
assert_denied_at_gateway() {
    local path="$1"
    local deadline=$((SECONDS + GATEWAY_E2E_TIMEOUT))
    local pods pod logs entry
    while (( SECONDS < deadline )); do
        pods=$(kubectl get pods --namespace "$NAMESPACE" \
            -l app.kubernetes.io/name=hyperfleet-gateway --field-selector=status.phase=Running \
            -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}') \
            || fail "could not list gateway pods for the denied request check"
        [[ -n "$pods" ]] || fail "could not find gateway pods for the denied request check"
        entry=""
        while IFS= read -r pod; do
            [[ -n "$pod" ]] || continue
            # A pod that cannot serve envoy logs yet is retried on the next poll.
            logs=$(kubectl logs "$pod" --namespace "$NAMESPACE" --container envoy --since=10m 2>/dev/null) || continue
            entry+=$(printf '%s\n' "$logs" | grep -F -- " ${path} " || true)
        done <<<"$pods"
        if [[ -n "$entry" ]]; then
            [[ "$entry" == *" UAEX "* && "$entry" == *'"-"' ]] \
                || fail "gateway forwarded $path to the API instead of denying it at ext_authz"
            return
        fi
        sleep "$GATEWAY_E2E_POLL_INTERVAL"
    done
    fail "gateway access log has no entry for denied request $path within ${GATEWAY_E2E_TIMEOUT}s"
}

assert_tenant_stamped() {
    local body="$1"
    local tenant="$2"
    body_matches "$body" --arg key "$required_key" --arg value "$tenant" \
        '[.. | objects | select(has($key)) | .[$key]] | any(. == $value)' \
        || fail "API response did not stamp ${required_key} from the gateway token"
}

assert_gateway_identity_stamped() {
    local body="$1"
    local subject="$2"
    body_matches "$body" --arg subject "$subject" \
        '[.. | objects | select(.created_by? == $subject or .updated_by? == $subject)] | length > 0' \
        || fail "API response did not record the gateway-derived audit identity"
}

assert_optional_tenant_stamped() {
    local body="$1"
    local subtenant="$2"
    if [[ -n "$subtenant" ]]; then
        body_matches "$body" --arg key "$optional_key" --arg value "$subtenant" \
            '[.. | objects | select(has($key)) | .[$key]] | any(. == $value)' \
            || fail "API response did not stamp optional ${optional_key} from the gateway token"
    else
        body_matches "$body" --arg key "$optional_key" '[.. | objects | select(has($key))] | length == 0' \
            || fail "API response unexpectedly contained optional ${optional_key}"
    fi
}

assert_cluster_absent_from_list() {
    local body="$1"
    local cluster_id="$2"
    body_matches "$body" --arg id "$cluster_id" '[.. | objects | .id? | select(. == $id)] | length == 0' \
        || fail "tenant B list unexpectedly contains tenant A cluster $cluster_id"
}

wait_for_reconciled() {
    local cluster_id="$1"
    local deadline=$((SECONDS + GATEWAY_E2E_TIMEOUT))
    local response
    while (( SECONDS < deadline )); do
        refresh_owner_token || fail "could not mint a token for the reconciliation poll"
        response=$(api_request GET "${api_path}/clusters/${cluster_id}" Bearer "$owner_token") || fail "reconciliation poll failed"
        if [[ "$(response_status "$response")" == "200" ]] && body_matches "$(response_body "$response")" \
            '.status.conditions[]? | select(.type == "Reconciled" and (.status == "True" or .status == true))'; then
            return
        fi
        sleep "$GATEWAY_E2E_POLL_INTERVAL"
    done
    fail "cluster $cluster_id did not reach Reconciled=True within ${GATEWAY_E2E_TIMEOUT}s"
}

cleanup_current_cluster() {
    if [[ -z "$current_cluster_id" ]]; then
        return 0
    fi
    local response status deadline
    refresh_owner_token || return 1
    response=$(api_request DELETE "${api_path}/clusters/${current_cluster_id}" Bearer "$owner_token") || return 1
    status=$(response_status "$response")
    case "$status" in
        200|202|404) ;;
        *) return 1 ;;
    esac
    deadline=$((SECONDS + GATEWAY_E2E_TIMEOUT))
    while (( SECONDS < deadline )); do
        refresh_owner_token || return 1
        response=$(api_request GET "${api_path}/clusters/${current_cluster_id}" Bearer "$owner_token") || return 1
        if [[ "$(response_status "$response")" == "404" ]]; then
            current_cluster_id=""
            return 0
        fi
        sleep "$GATEWAY_E2E_POLL_INTERVAL"
    done
    error "cluster cleanup did not return HTTP 404 within ${GATEWAY_E2E_TIMEOUT}s"
    return 1
}

cleanup_resources() {
    local rc=0
    cleanup_current_cluster || { error "failed to clean the suite-owned Cluster"; rc=1; }
    if [[ -n "$temporary_service_account" ]]; then
        kubectl delete serviceaccount "$temporary_service_account" --namespace "$NAMESPACE" \
            --ignore-not-found >/dev/null 2>&1 || { error "failed to delete temporary ServiceAccount"; rc=1; }
        temporary_service_account=""
    fi
    kubectl delete pod --namespace "$NAMESPACE" -l "$pod_labels" \
        --ignore-not-found --wait=false >/dev/null 2>&1 || rc=1
    return "$rc"
}

# Helmfile prints full release diffs, so show them only when the switch fails.
switch_model() {
    local output
    output=$(make -C "$REPO_ROOT" --no-print-directory switch-tenant-model TENANT_MODEL="$1" 2>&1) || {
        printf '%s\n' "$output" >&2
        return 1
    }
    TENANT_MODEL="$1"
    configure_model
    wait_for_components
}

restore_model() {
    echo "Restoring tenant model to onprem..." >&2
    switch_model onprem
}

on_exit() {
    local original_status="$1"
    local failed_model="$TENANT_MODEL"
    local cleanup_status=0
    local restore_status=0
    trap - EXIT
    cleanup_resources || cleanup_status=1
    if [[ "$restore_onprem" == "true" ]]; then
        restore_model || restore_status=1
    fi
    print_report "$original_status" "$failed_model" "$cleanup_status" "$restore_status"
    if (( original_status != 0 )); then
        exit "$original_status"
    fi
    if (( cleanup_status != 0 || restore_status != 0 )); then
        exit 1
    fi
}

run_human_phase() {
    local subject tenant subtenant
    local response body name wrong_audience_token missing_token
    if [[ "$PHASE" == "human" ]]; then
        subject="${TOKEN_SUBJECT:-human@example.com}"
        tenant="${TOKEN_TENANT:-}"
        subtenant="${TOKEN_SUBTENANT:-}"
        [[ -n "$tenant" ]] || fail "TOKEN_TENANT is required for the human phase"
    else
        subject="hf-gateway-e2e-human-${run_id}@example.com"
        tenant="$tenant_a"
        subtenant="$subtenant_a"
    fi
    check "valid human token creates a Cluster stamped with its tenant"
    name="hf-gateway-e2e-human-${TENANT_MODEL}-${run_id}"
    set_owner "$subject" "$tenant" "$subtenant"
    response=$(api_request POST "${api_path}/clusters" Bearer "$owner_token" \
        "{\"kind\":\"Cluster\",\"name\":\"${name}\",\"spec\":{\"region\":\"us-east-1\"}}")
    require_status "$response" 201 "valid human token cluster creation"
    body=$(response_body "$response")
    current_cluster_id=$(printf '%s' "$body" | jq -er '.id | select(type == "string" and length > 0)') \
        || fail "valid human token response did not contain a cluster id"
    assert_tenant_stamped "$body" "$tenant"
    assert_optional_tenant_stamped "$body" "$subtenant"
    cleanup_current_cluster || fail "could not clean human token smoke resource"
    pass

    # The gateway JWT authentication enforces the audience, so a mismatch fails
    # authentication (401) rather than authorization (403).
    check "token for another audience fails authentication (401)"
    wrong_audience_token=$(TOKEN_AUDIENCE=some-other-app mint_human_token "$subject" "$tenant" "$subtenant")
    response=$(api_request GET "${api_path}/clusters" Bearer "$wrong_audience_token")
    require_status "$response" 401 "wrong-audience token"
    pass

    check "token without the required ${required_key} claim is denied (403)"
    missing_token=$(mint_human_token "$subject" "$tenant" "$subtenant" true)
    response=$(api_request GET "${api_path}/clusters" Bearer "$missing_token")
    require_status "$response" 403 "missing required claim token"
    pass
}

# Tenant B's token is minted for each check, so it is never older than the
# requests below.
assert_isolation() {
    local cluster_id="$1"
    local token_b response
    token_b=$(mint_human_token "hf-gateway-e2e-b-${run_id}@example.com" "$tenant_b" "$subtenant_b")
    response=$(api_request GET "${api_path}/clusters" Bearer "$token_b")
    require_status "$response" 200 "tenant B cluster list"
    assert_cluster_absent_from_list "$(response_body "$response")" "$cluster_id"
    for method in GET DELETE; do
        response=$(api_request "$method" "${api_path}/clusters/${cluster_id}" Bearer "$token_b")
        require_status "$response" 404 "tenant B $method on tenant A cluster"
    done
    response=$(api_request PATCH "${api_path}/clusters/${cluster_id}" Bearer "$token_b" \
        '{"spec":{"region":"us-west-2"}}')
    require_status "$response" 404 "tenant B PATCH on tenant A cluster"
}

# full runs this once per tenant model, so the ServiceAccount name carries the
# model and the account is deleted before the next pass.
run_machine_denials() {
    local token response
    temporary_service_account="hf-gateway-e2e-unlisted-${TENANT_MODEL}-${run_id}"
    kubectl create serviceaccount "$temporary_service_account" --namespace "$NAMESPACE" >/dev/null
    token=$(kubectl create token "$temporary_service_account" --namespace "$NAMESPACE" --audience=hyperfleet-api)
    response=$(api_request GET "${api_path}/clusters" ServiceAccount "$token")
    require_status "$response" 403 "unlisted ServiceAccount"
    response=$(api_request GET "${api_path}/clusters" Bearer "$token")
    require_denial "$response" "ServiceAccount token sent as Bearer"
    kubectl delete serviceaccount "$temporary_service_account" --namespace "$NAMESPACE" >/dev/null
    temporary_service_account=""
}

verify_tenant_body_immutable() {
    local cluster_id="$1"
    local tenant="$2"
    local response status
    refresh_owner_token
    response=$(api_request PATCH "${api_path}/clusters/${cluster_id}" Bearer "$owner_token" \
        "{\"spec\":{\"region\":\"us-east-1\"},\"${required_key}\":\"forged-body-tenant\"}")
    status=$(response_status "$response")
    case "$status" in
        400|422) ;;
        200)
            response=$(api_request GET "${api_path}/clusters/${cluster_id}" Bearer "$owner_token")
            require_status "$response" 200 "tenant immutability readback"
            assert_tenant_stamped "$(response_body "$response")" "$tenant"
            ;;
        *) fail "tenant immutability patch returned HTTP $status, expected 200, 400, or 422" ;;
    esac
}

run_denial_at_gateway() {
    local missing_path invalid_path unknown_scheme_path response
    check "missing, invalid, and unknown-scheme credentials are denied at the gateway, never reaching the API"
    missing_path="${api_path}/gateway-e2e-missing-${TENANT_MODEL}-${run_id}"
    response=$(api_request GET "$missing_path" none "")
    require_denial "$response" "missing credential"
    assert_denied_at_gateway "$missing_path"
    invalid_path="${api_path}/gateway-e2e-invalid-${TENANT_MODEL}-${run_id}"
    response=$(api_request GET "$invalid_path" Bearer "not-a-jwt-${run_id}")
    require_denial "$response" "invalid credential"
    assert_denied_at_gateway "$invalid_path"
    # Only Bearer (humans) and ServiceAccount (machines) select an
    # authentication method, so any other scheme must be denied.
    unknown_scheme_path="${api_path}/gateway-e2e-unknown-scheme-${TENANT_MODEL}-${run_id}"
    response=$(api_request GET "$unknown_scheme_path" Basic "aGY6Z2F0ZXdheS1lMmU=")
    require_denial "$response" "unknown authorization scheme"
    assert_denied_at_gateway "$unknown_scheme_path"
    pass
}

run_current_model() {
    local subject_a="hf-gateway-e2e-a-${run_id}@example.com"
    local response body name
    run_human_phase
    run_denial_at_gateway
    # Authorino overwrites the forged required tenant, system, and identity
    # headers. Tenant A's token has no optional claim, so Authorino sets no
    # optional tenant header and only Envoy's stripping keeps the forged one
    # out of the stored tenancy.
    check "forged identity and tenant headers are replaced, and a forged ${optional_header} is stripped"
    set_owner "$subject_a" "$tenant_a" ""
    name="hf-gateway-e2e-${TENANT_MODEL}-${run_id}"
    response=$(api_request POST "${api_path}/clusters" Bearer "$owner_token" \
        "{\"kind\":\"Cluster\",\"name\":\"${name}\",\"spec\":{\"region\":\"us-east-1\"}}" \
        "${required_header}=forged-tenant" "${optional_header}=forged-subtenant" \
        'x-hyperfleet-system=true' "x-hyperfleet-identity=forged-${run_id}@example.com")
    require_status "$response" 201 "forged-header cluster creation"
    body=$(response_body "$response")
    current_cluster_id=$(printf '%s' "$body" | jq -er '.id | select(type == "string" and length > 0)') \
        || fail "forged-header cluster response did not contain a cluster id"
    assert_tenant_stamped "$body" "$tenant_a"
    assert_optional_tenant_stamped "$body" ""
    # Only EDGE+API gives the API a caller identity, the gateway wristband
    # subject. In EDGE mode the API records its system default instead.
    if [[ "$AUTH_MODE" == "EDGE+API" ]]; then
        assert_gateway_identity_stamped "$body" "$subject_a"
    fi
    pass

    check "client-supplied ${required_key} in the request body is not accepted"
    verify_tenant_body_immutable "$current_cluster_id" "$tenant_a"
    pass

    check "tenant B cannot list, read, patch, or delete tenant A's Cluster"
    assert_isolation "$current_cluster_id"
    pass

    check "unlisted ServiceAccount and a ServiceAccount token sent as Bearer are denied"
    run_machine_denials
    pass

    check "Cluster reaches Reconciled=True through Sentinel and adapters" \
        "check the Sentinel and adapter logs; they authenticate to the gateway with their ServiceAccounts"
    wait_for_reconciled "$current_cluster_id"
    pass

    check "tenant B is still isolated after reconciliation"
    assert_isolation "$current_cluster_id"
    pass

    check "Cluster is hard-deleted"
    cleanup_current_cluster || fail "could not hard-delete lifecycle Cluster"
    pass
}

verify_cilium_policy_posture() {
    kubectl rollout status daemonset/cilium --namespace "$CILIUM_NAMESPACE" \
        --timeout="${GATEWAY_E2E_TIMEOUT}s" >/dev/null
    kubectl get networkpolicy hyperfleet-api-ingress --namespace "$NAMESPACE" >/dev/null
}

run_network_policy_probe() {
    local token response pod_name output curl_exit http_status
    check "direct in-cluster request to the API is dropped while the gateway stays reachable"
    token=$(mint_human_token "hf-gateway-e2e-probe-${run_id}@example.com" "$tenant_a" "")
    response=$(api_request GET "${api_path}/clusters" Bearer "$token")
    require_status "$response" 200 "gateway reachability before NetworkPolicy probe"
    pod_name="hf-gateway-e2e-netpol-${run_id}"
    output=$(kubectl run "$pod_name" --namespace "$NAMESPACE" \
        --labels="$pod_labels" \
        --image="$CURL_IMAGE" --restart=Never --rm --quiet --attach --command -- sh -c '
set +e
status=$(curl -k -sS --connect-timeout 5 --max-time 10 -o /tmp/body -w "%{http_code}" "https://$1:8000/api/hyperfleet/v1/clusters" 2>/dev/null)
rc=$?
printf "curl_exit=%s http_status=%s\\n" "$rc" "$status"
exit 0
' -- "$API_SERVICE") || fail "direct API NetworkPolicy probe pod failed"
    curl_exit=$(printf '%s\n' "$output" | sed -n 's/.*curl_exit=\([0-9][0-9]*\).*/\1/p')
    http_status=$(printf '%s\n' "$output" | sed -n 's/.*http_status=\([0-9][0-9]*\).*/\1/p')
    [[ "$curl_exit" == "28" && "$http_status" == "000" ]] || \
        fail "direct API probe was not dropped by NetworkPolicy (curl_exit=${curl_exit:-unknown} http_status=${http_status:-unknown})"
    response=$(api_request GET "${api_path}/clusters" Bearer "$token")
    require_status "$response" 200 "gateway reachability after NetworkPolicy probe"
    pass
}

run_full() {
    [[ "$TENANT_MODEL" == "onprem" ]] || fail "full must start with TENANT_MODEL=onprem"
    local onprem_subject="hf-gateway-e2e-old-${run_id}@example.com"
    local onprem_tenant onprem_token old_token_path response
    check "Cilium is running and the hyperfleet-api-ingress NetworkPolicy exists" \
        "use the kind cluster from make local-up-kind, which installs Cilium and the NetworkPolicies"
    verify_cilium_policy_posture
    pass
    run_current_model

    check "tenant model switches to Oracle through configuration only" \
        "nothing else may redeploy the gateway or API while the suite runs"
    # The mock issuer serves both models, so the on-prem token checked after
    # the switch is minted then, with the claims accepted just before it. No
    # token has to outlive the switch.
    onprem_tenant="$tenant_a"
    onprem_token=$(mint_human_token "$onprem_subject" "$onprem_tenant" "")
    response=$(api_request GET "${api_path}/clusters" Bearer "$onprem_token")
    require_status "$response" 200 "on-prem token before Oracle switch"
    restore_onprem=true
    switch_model oracle
    pass

    # A unique path lets the access log prove the gateway, not the API, denied
    # the old-model token.
    check "on-prem token is rejected at the gateway after the switch" \
        "nothing else may redeploy the gateway or API while the suite runs"
    onprem_token=$(TENANT_MODEL=onprem mint_human_token "$onprem_subject" "$onprem_tenant" "")
    old_token_path="${api_path}/gateway-e2e-old-token-${run_id}"
    response=$(api_request GET "$old_token_path" Bearer "$onprem_token")
    require_status "$response" 403 "on-prem token after Oracle switch"
    assert_denied_at_gateway "$old_token_path"
    pass

    run_current_model
    run_network_policy_probe
}

validate_inputs
trap 'on_exit $?' EXIT
check "HyperFleet stack is deployed and ready" \
    "bring it up with: HELMFILE_ENV=kind OIDC_ISSUER_MODE=mock TENANT_ISOLATION_ENABLED=true make local-up-kind"
wait_for_components
pass
case "$PHASE" in
    human) run_human_phase ;;
    current-model) run_current_model ;;
    full) run_full ;;
esac
