#!/usr/bin/env bash
# shellcheck disable=SC2016 # Literal source assertions are intentional.

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
. "${REPO_DIR}/lib/caddy.sh"
# shellcheck disable=SC1090
. "${REPO_DIR}/lib/docker.sh"

TESTS=0
FAILURES=0
pass() { TESTS=$((TESTS + 1)); printf 'ok %d - %s\n' "${TESTS}" "$1"; }
fail() { TESTS=$((TESTS + 1)); FAILURES=$((FAILURES + 1)); printf 'not ok %d - %s\n' "${TESTS}" "$1" >&2; }
expect_success() { local description=$1; shift; if "$@"; then pass "${description}"; else fail "${description}"; fi; }
expect_failure() { local description=$1; shift; if "$@"; then fail "${description}"; else pass "${description}"; fi; }
expect_equal() {
    local description=$1 expected=$2 actual=$3
    if [[ "${actual}" == "${expected}" ]]; then pass "${description}"; else fail "${description}"; fi
}

temporary_dir=$(mktemp -d)
readonly temporary_dir
trap 'rm -rf -- "${temporary_dir}"' EXIT

access_file="${temporary_dir}/.access"
write_access_config_atomic "${access_file}" mdns vaultwarden.local
expect_equal "fresh default access file has the exact format" \
    $'mode=mdns\nhostname=vaultwarden.local' "$(<"${access_file}")"
expect_equal "existing mDNS access file is parsed" $'mdns\tvaultwarden.local' \
    "$(read_access_config "${access_file}")"

write_access_config_atomic "${access_file}" dns vault.lan
expect_equal "external DNS access file has the exact format" \
    $'mode=dns\nhostname=vault.lan' "$(<"${access_file}")"
expect_equal "existing external DNS access file is parsed" $'dns\tvault.lan' \
    "$(read_access_config "${access_file}")"

expect_success "custom mDNS hostname is valid" validate_access_configuration mdns passwords.local
expect_success "external DNS hostname is valid" validate_access_configuration dns vault.home.arpa
expect_failure "invalid hostname is rejected" validate_access_configuration dns 'vault name.lan'
expect_failure "IP address is rejected" validate_access_configuration dns 192.168.0.192
expect_failure "mDNS requires .local" validate_access_configuration mdns vault.lan
expect_failure "external DNS rejects .local" validate_access_configuration dns vaultwarden.local

expect_success "installer contains the hostname prompt" grep -Fq \
    'Vaultwarden hostname [${default_hostname}]:' "${REPO_DIR}/install.sh"
expect_success "installer contains the default-mDNS DNS prompt" grep -Fq \
    'Use your own local DNS server for this hostname? [y/N]:' "${REPO_DIR}/install.sh"
expect_success "installer contains the existing-DNS default prompt" grep -Fq \
    'Use your own local DNS server for this hostname? [Y/n]:' "${REPO_DIR}/install.sh"
expect_success "every installer run invokes access prompting" grep -Fq \
    '    prompt_for_access_configuration' "${REPO_DIR}/install.sh"
expect_success "existing hostname is used as the prompt default" grep -Fq \
    'local default_hostname=${CADDY_ACCESS_ADDRESS:-${DEFAULT_MDNS_HOSTNAME}}' "${REPO_DIR}/install.sh"

expect_success "mDNS mode installs support" grep -Fq \
    '        install_mdns_support' "${REPO_DIR}/install.sh"
expect_success "mDNS mode configures the publisher" grep -Fq \
    '        configure_mdns' "${REPO_DIR}/install.sh"
expect_success "external DNS removes only the appliance publisher" grep -Fq \
    '        remove_appliance_mdns_configuration' "${REPO_DIR}/install.sh"
expect_success "external DNS reports the manual record" grep -Fq \
    '        report_external_dns' "${REPO_DIR}/install.sh"
expect_failure "installer never writes hosts or resolver configuration" grep -Eq \
    '(^|[[:space:]])(/etc/hosts|/etc/resolv\.conf)' "${REPO_DIR}/install.sh"
expect_failure "installer never changes the Linux hostname" grep -Eq \
    '^[[:space:]]*(hostnamectl|avahi-set-host-name|hostname[[:space:]])' "${REPO_DIR}/install.sh"
expect_failure "switching modes never uninstalls Avahi" grep -Eq \
    '(apt-get|apt)[[:space:]]+(remove|purge).*avahi' "${REPO_DIR}/install.sh"

write_caddyfile_to "${temporary_dir}/Caddyfile" vault.lan
expect_success "Caddy follows an external DNS hostname" grep -Fxq \
    'https://vault.lan {' "${temporary_dir}/Caddyfile"
write_vaultwarden_override_to "${temporary_dir}/override.yml" vault.lan true
expect_success "Vaultwarden DOMAIN follows an external DNS hostname" grep -Fxq \
    '      DOMAIN: "https://vault.lan"' "${temporary_dir}/override.yml"

expect_success "Caddy root CA data path remains persistent" grep -Fq \
    '      - ./data/caddy/data:/data' "${REPO_DIR}/install.sh"
expect_failure "access reconciliation never deletes Vaultwarden data" grep -Eq \
    'rm[^#\n]*/opt/vaultwarden/data/vaultwarden' "${REPO_DIR}/install.sh"
expect_failure "access reconciliation never deletes Caddy CA data" grep -Eq \
    'rm[^#\n]*/opt/vaultwarden/data/caddy' "${REPO_DIR}/install.sh"
expect_success "unchanged access state is compared before replacement" grep -Fq \
    'cmp -s "${temporary}" "${destination}"' "${REPO_DIR}/lib/common.sh"
expect_success "status reports external DNS mode" grep -Fq \
    "printf '%-15s %s\\n' 'Access mode:' 'external DNS'" "${REPO_DIR}/vwctl"
expect_success "health validates external DNS against the LAN IPv4" grep -Fq \
    'dns_resolution_matches "${current_ip}" "${resolved}"' "${REPO_DIR}/vwctl"
expect_success "health keeps the mDNS-specific branch" grep -Fq \
    'if [[ "${ACCESS_MODE}" == mdns ]]; then' "${REPO_DIR}/vwctl"
expect_success "restore reads the installed access configuration" grep -Fq \
    'parsed_access=$(read_access_config "${ACCESS_FILE}")' "${REPO_DIR}/libexec/restore"

printf '1..%d\n' "${TESTS}"
(( FAILURES == 0 ))
