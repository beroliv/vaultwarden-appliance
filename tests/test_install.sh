#!/usr/bin/env bash
# shellcheck disable=SC1090 # The test intentionally sources the installer.

set -o errexit
set -o nounset
set -o pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly TEST_DIR
REPO_DIR=$(cd -- "${TEST_DIR}/.." && pwd -P)
readonly REPO_DIR

. "${REPO_DIR}/install.sh"

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

expect_equal() {
    local description=$1
    local expected=$2
    local actual=$3

    if [[ "${actual}" == "${expected}" ]]; then pass "${description}"; else fail "${description}"; fi
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

make_exact_preseed() {
    local installation_dir=$1
    local pki="${installation_dir}/data/caddy/data/caddy/pki/authorities/local"

    mkdir -p -- "${pki}"
    printf 'root certificate\n' > "${pki}/root.crt"
    printf 'root private key\n' > "${pki}/root.key"
    printf 'intermediate certificate\n' > "${pki}/intermediate.crt"
    printf 'intermediate private key\n' > "${pki}/intermediate.key"
}

temporary_dir=$(mktemp -d)
readonly temporary_dir
trap 'rm -rf -- "${temporary_dir}"' EXIT

nonexistent="${temporary_dir}/nonexistent"
expect_equal "nonexistent installation path is fresh" fresh \
    "$(classify_installation_path "${nonexistent}")"

empty="${temporary_dir}/empty"
mkdir -- "${empty}"
expect_equal "empty existing installation directory remains unknown" unknown \
    "$(classify_installation_path "${empty}")"

exact="${temporary_dir}/exact"
make_exact_preseed "${exact}"
expect_equal "exact four-file Caddy PKI preseed is accepted" preseed \
    "$(classify_installation_path "${exact}")"

incomplete="${temporary_dir}/incomplete"
make_exact_preseed "${incomplete}"
rm -- "${incomplete}/data/caddy/data/caddy/pki/authorities/local/intermediate.key"
expect_equal "incomplete Caddy PKI preseed is rejected" unknown \
    "$(classify_installation_path "${incomplete}")"

unexpected="${temporary_dir}/unexpected"
make_exact_preseed "${unexpected}"
printf 'unexpected\n' > "${unexpected}/data/caddy/data/caddy/pki/authorities/local/extra.pem"
expect_equal "Caddy PKI preseed with an unexpected file is rejected" unknown \
    "$(classify_installation_path "${unexpected}")"

unexpected_directory="${temporary_dir}/unexpected-directory"
make_exact_preseed "${unexpected_directory}"
mkdir -- "${unexpected_directory}/data/caddy/config"
expect_equal "Caddy PKI preseed with an unexpected directory is rejected" unknown \
    "$(classify_installation_path "${unexpected_directory}")"

symlinked="${temporary_dir}/symlinked"
make_exact_preseed "${symlinked}"
if ln -s -- "${symlinked}/data/caddy/data/caddy/pki/authorities/local/root.crt" \
    "${temporary_dir}/root-link" 2>/dev/null && [[ -L "${temporary_dir}/root-link" ]]; then
    rm -- "${symlinked}/data/caddy/data/caddy/pki/authorities/local/root.crt"
    mv -- "${temporary_dir}/root-link" \
        "${symlinked}/data/caddy/data/caddy/pki/authorities/local/root.crt"
    expect_equal "symlinked Caddy PKI preseed file is rejected" unknown \
        "$(classify_installation_path "${symlinked}")"
else
    pass "symlinked preseed rejection is covered on hosts with symlink support"
fi

symlinked_path="${temporary_dir}/symlinked-path"
mkdir -p -- "${symlinked_path}/data/caddy/data/caddy/pki/authorities"
if ln -s -- "${exact}/data/caddy/data/caddy/pki/authorities/local" \
    "${symlinked_path}/data/caddy/data/caddy/pki/authorities/local" 2>/dev/null &&
   [[ -L "${symlinked_path}/data/caddy/data/caddy/pki/authorities/local" ]]; then
    expect_equal "symlinked Caddy PKI preseed directory is rejected" unknown \
        "$(classify_installation_path "${symlinked_path}")"
else
    pass "symlinked preseed path rejection is covered on hosts with symlink support"
fi

marked="${temporary_dir}/marked"
mkdir -- "${marked}"
printf 'Vaultwarden Appliance\n' > "${marked}/.vaultwarden-appliance"
expect_equal "existing marked appliance is accepted normally" existing \
    "$(classify_installation_path "${marked}")"

# Shared installer validation, generated configuration, and operation-lock coverage.
expect_success "valid private IPv4 address" validate_ipv4_address 192.168.0.192
expect_failure "IPv4 octet above 255" validate_ipv4_address 192.168.0.256
expect_failure "unspecified IPv4 address" validate_ipv4_address 0.0.0.0
expect_failure "non-numeric IPv4 address" validate_ipv4_address 192.168.one.1
expect_success "external DNS matching accepts the exact LAN IPv4" \
    dns_resolution_matches 192.168.0.192 192.168.0.192
expect_failure "external DNS matching rejects a wrong IPv4" \
    dns_resolution_matches 192.168.0.192 192.168.0.193
expect_failure "external DNS matching rejects multiple IPv4 results" \
    dns_resolution_matches 192.168.0.192 $'192.168.0.192\n192.168.0.193'

expect_success "valid .local hostname" validate_local_hostname vaultwarden.local
expect_success "valid hyphenated .local hostname" validate_local_hostname vault-2.local
expect_failure "uppercase hostname" validate_local_hostname Vaultwarden.local
expect_failure "non-local hostname" validate_local_hostname vaultwarden.example
expect_success "valid external DNS hostname" validate_dns_hostname vault.home.arpa
expect_failure "external DNS rejects .local" validate_dns_hostname vaultwarden.local
expect_failure "hostname validator rejects URL" validate_hostname https://vault.lan
expect_failure "hostname validator rejects port" validate_hostname vault.lan:443
expect_failure "hostname validator rejects path" validate_hostname vault.lan/path
expect_failure "hostname validator rejects IP" validate_hostname 192.168.0.192
expect_failure "hostname validator rejects malformed IP text" validate_hostname 999.168.0.192

printf 'mode=mdns\nhostname=vaultwarden.local\n' > "${temporary_dir}/access"
if [[ "$(read_access_config "${temporary_dir}/access")" == $'mdns\tvaultwarden.local' ]]; then
    pass "mDNS access state parses"
else
    fail "mDNS access state parses"
fi
printf 'mode=dns\nhostname=vault.lan\n' > "${temporary_dir}/dns-access"
if [[ "$(read_access_config "${temporary_dir}/dns-access")" == $'dns\tvault.lan' ]]; then
    pass "external DNS access state parses"
else
    fail "external DNS access state parses"
fi
printf 'mode=mdns\nmode=dns\n' > "${temporary_dir}/duplicate-access"
expect_failure "duplicate access key is rejected" read_access_config "${temporary_dir}/duplicate-access"
printf 'hostname=vaultwarden.local\nmode=mdns\n' > "${temporary_dir}/reversed-access"
expect_failure "reordered access keys are rejected" read_access_config "${temporary_dir}/reversed-access"
printf 'mode=mdns\naddress=vaultwarden.local\n' > "${temporary_dir}/unknown-access"
expect_failure "unknown access key is rejected" read_access_config "${temporary_dir}/unknown-access"
printf 'mode=hostname\nhostname=vaultwarden.local\n' > "${temporary_dir}/mode-access"
expect_failure "unknown access mode is rejected" read_access_config "${temporary_dir}/mode-access"
printf 'mode=mdns\nhostname=192.168.0.192\n' > "${temporary_dir}/ip-access"
expect_failure "IP access state is rejected" read_access_config "${temporary_dir}/ip-access"
printf 'mode=dns\nhostname=vaultwarden.local\n' > "${temporary_dir}/dns-local-access"
expect_failure "external DNS .local state is rejected" read_access_config "${temporary_dir}/dns-local-access"

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
write_caddyfile_to "${temporary_dir}/Caddyfile-dns" vault.lan
if [[ "$(read_caddyfile_hostname "${temporary_dir}/Caddyfile-dns")" == "vault.lan" ]]; then
    pass "external DNS Caddyfile hostname parses"
else
    fail "external DNS Caddyfile hostname parses"
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
write_vaultwarden_override_to "${temporary_dir}/override-dns.yml" vault.lan true
expect_success "external DNS DOMAIN is generated" grep -Fxq \
    '      DOMAIN: "https://vault.lan"' "${temporary_dir}/override-dns.yml"

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
