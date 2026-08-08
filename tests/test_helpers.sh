#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly TEST_DIR
REPO_DIR=$(cd -- "${TEST_DIR}/.." && pwd -P)
readonly REPO_DIR

# shellcheck disable=SC1090
. "${REPO_DIR}/lib/common.sh"
# shellcheck disable=SC1090
. "${REPO_DIR}/lib/network.sh"
# shellcheck disable=SC1090
. "${REPO_DIR}/lib/docker.sh"
# shellcheck disable=SC1090
. "${REPO_DIR}/lib/caddy.sh"

TESTS=0
FAILURES=0

pass() {
    TESTS=$((TESTS + 1))
    printf 'ok %d - %s\n' "${TESTS}" "$1"
}

fail() {
    TESTS=$((TESTS + 1))
    FAILURES=$((FAILURES + 1))
    printf 'not ok %d - %s\n' "${TESTS}" "$1" >&2
}

expect_success() {
    local description=$1
    shift
    if "$@"; then pass "${description}"; else fail "${description}"; fi
}

expect_failure() {
    local description=$1
    shift
    if "$@"; then fail "${description}"; else pass "${description}"; fi
}

temporary_dir=$(mktemp -d)
readonly temporary_dir
trap 'rm -rf -- "${temporary_dir}"' EXIT

expect_success "valid private IPv4 address" validate_ipv4_address 192.168.0.192
expect_failure "IPv4 octet above 255" validate_ipv4_address 192.168.0.256
expect_failure "unspecified IPv4 address" validate_ipv4_address 0.0.0.0
expect_failure "non-numeric IPv4 address" validate_ipv4_address 192.168.one.1

expect_success "valid .local hostname" validate_local_hostname vaultwarden.local
expect_success "valid hyphenated .local hostname" validate_local_hostname vault-2.local
expect_failure "uppercase hostname" validate_local_hostname Vaultwarden.local
expect_failure "non-local hostname" validate_local_hostname vaultwarden.example

printf 'hostname=vaultwarden.local\n' > "${temporary_dir}/access"
if [[ "$(read_access_hostname "${temporary_dir}/access")" == "vaultwarden.local" ]]; then
    pass "current access state parses"
else
    fail "current access state parses"
fi
printf 'mode=hostname\naddress=vaultwarden.local\n' > "${temporary_dir}/legacy-access"
expect_failure "legacy two-line access state is rejected" read_access_hostname "${temporary_dir}/legacy-access"
printf 'hostname=192.168.0.192\n' > "${temporary_dir}/ip-access"
expect_failure "IP access state is rejected" read_access_hostname "${temporary_dir}/ip-access"

write_caddyfile_to "${temporary_dir}/Caddyfile" vaultwarden.local
if grep -Fxq 'https://vaultwarden.local {' "${temporary_dir}/Caddyfile" &&
   grep -Fxq $'\ttls internal' "${temporary_dir}/Caddyfile" &&
   grep -Fxq $'\treverse_proxy vaultwarden:80' "${temporary_dir}/Caddyfile"; then
    pass "generated Caddyfile uses hostname, internal TLS, and Docker DNS"
else
    fail "generated Caddyfile uses hostname, internal TLS, and Docker DNS"
fi
if [[ "$(read_caddyfile_hostname "${temporary_dir}/Caddyfile")" == "vaultwarden.local" ]]; then
    pass "generated Caddyfile hostname parses"
else
    fail "generated Caddyfile hostname parses"
fi

if [[ "$(vaultwarden_domain_for_hostname vaultwarden.local)" == "https://vaultwarden.local" ]]; then
    pass "DOMAIN URL generation"
else
    fail "DOMAIN URL generation"
fi
write_vaultwarden_override_to "${temporary_dir}/override.yml" vaultwarden.local false
if grep -Fxq '      DOMAIN: "https://vaultwarden.local"' "${temporary_dir}/override.yml" &&
   grep -Fxq '      SIGNUPS_ALLOWED: "false"' "${temporary_dir}/override.yml"; then
    pass "managed Compose override contains DOMAIN and signup state"
else
    fail "managed Compose override contains DOMAIN and signup state"
fi

if command_exists flock; then
    lock_file="${temporary_dir}/operation.lock"
    flock -n "${lock_file}" -c 'sleep 2' &
    holder_pid=$!
    sleep 0.2
    expect_failure "operation lock rejects a concurrent holder" acquire_appliance_lock "${lock_file}"
    wait "${holder_pid}"
    expect_success "operation lock can be acquired after release" acquire_appliance_lock "${lock_file}"
else
    pass "operation lock test skipped because flock is unavailable on this host"
fi

printf '1..%d\n' "${TESTS}"
(( FAILURES == 0 ))
