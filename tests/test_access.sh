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

expect_contains() {
    local description=$1 needle=$2 haystack=$3
    if [[ "${haystack}" == *"${needle}"* ]]; then pass "${description}"; else fail "${description}"; fi
}

expect_not_contains() {
    local description=$1 needle=$2 haystack=$3
    if [[ "${haystack}" == *"${needle}"* ]]; then fail "${description}"; else pass "${description}"; fi
}

expect_in_order() {
    local description=$1 first=$2 second=$3 haystack=$4
    local after_first

    if [[ "${haystack}" != *"${first}"* ]]; then
        fail "${description}"
        return
    fi
    after_first=${haystack#*"${first}"}
    if [[ "${after_first}" == *"${second}"* ]]; then pass "${description}"; else fail "${description}"; fi
}

run_access_prompt_case() {
    local current_mode=$1
    local current_hostname=$2
    shift 2

    bash -c '
        repository=$1
        current_mode=$2
        current_hostname=$3
        shift 3
        . "${repository}/install.sh"
        ACCESS_MODE=${current_mode}
        CADDY_ACCESS_ADDRESS=${current_hostname}
        IPV4_ADDRESS=192.168.0.192
        prompt_answers=("$@")
        prompt_index=0
        read_installer_answer() {
            local prompt=$1
            local destination=$2

            printf "%s\n" "${prompt}"
            (( prompt_index < ${#prompt_answers[@]} )) || return 1
            printf -v "${destination}" "%s" "${prompt_answers[${prompt_index}]}"
            prompt_index=$((prompt_index + 1))
        }
        prompt_for_access_configuration
        printf "RESULT mode=%s hostname=%s\n" "${ACCESS_MODE}" "${CADDY_ACCESS_ADDRESS}"
    ' access-prompt-test "${REPO_DIR}" "${current_mode}" "${current_hostname}" "$@"
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

expect_success "every installer run invokes access prompting" grep -Fq \
    '    prompt_for_access_configuration' "${REPO_DIR}/install.sh"

fresh_mdns=$(run_access_prompt_case mdns '' '' '')
expect_contains "installer explains the mDNS access mode" \
    '1) mDNS' "${fresh_mdns}"
expect_contains "installer explains the external DNS access mode" \
    '2) External/local DNS' "${fresh_mdns}"
expect_in_order "access mode is asked before the hostname" \
    'Select access mode [1]:' 'Vaultwarden mDNS hostname [vaultwarden.local]:' "${fresh_mdns}"
expect_contains "fresh installation defaults to mDNS" \
    'Select access mode [1]:' "${fresh_mdns}"
expect_contains "fresh mDNS hostname default is vaultwarden.local" \
    'Vaultwarden mDNS hostname [vaultwarden.local]:' "${fresh_mdns}"
expect_contains "fresh mDNS defaults produce the expected selection" \
    'RESULT mode=mdns hostname=vaultwarden.local' "${fresh_mdns}"

fresh_dns=$(run_access_prompt_case mdns '' 2 '')
expect_contains "fresh external DNS hostname default is vault.lan" \
    'Vaultwarden DNS hostname [vault.lan]:' "${fresh_dns}"
expect_contains "fresh external DNS selection produces the expected state" \
    'RESULT mode=dns hostname=vault.lan' "${fresh_dns}"

existing_mdns=$(run_access_prompt_case mdns passwords.local '' '')
expect_contains "existing mDNS mode is the default" \
    'Select access mode [1]:' "${existing_mdns}"
expect_contains "existing mDNS hostname is retained as the default" \
    'Vaultwarden mDNS hostname [passwords.local]:' "${existing_mdns}"
expect_contains "unchanged existing mDNS answers are idempotent" \
    'RESULT mode=mdns hostname=passwords.local' "${existing_mdns}"

existing_dns=$(run_access_prompt_case dns vault1.lan '' '')
expect_contains "existing external DNS mode is the default" \
    'Select access mode [2]:' "${existing_dns}"
expect_contains "existing DNS hostname is retained as the default" \
    'Vaultwarden DNS hostname [vault1.lan]:' "${existing_dns}"
expect_contains "unchanged existing DNS answers are idempotent" \
    'RESULT mode=dns hostname=vault1.lan' "${existing_dns}"

mdns_to_dns=$(run_access_prompt_case mdns passwords.local 2 '')
expect_contains "mDNS to DNS switch uses the DNS hostname default" \
    'Vaultwarden DNS hostname [vault.lan]:' "${mdns_to_dns}"
expect_not_contains "mDNS hostname is not offered after switching to DNS" \
    'Vaultwarden DNS hostname [passwords.local]:' "${mdns_to_dns}"
expect_contains "mDNS to DNS switch produces the expected selection" \
    'RESULT mode=dns hostname=vault.lan' "${mdns_to_dns}"

dns_to_mdns=$(run_access_prompt_case dns vault1.lan 1 '')
expect_contains "DNS to mDNS switch uses the mDNS hostname default" \
    'Vaultwarden mDNS hostname [vaultwarden.local]:' "${dns_to_mdns}"
expect_not_contains "DNS hostname is not offered after switching to mDNS" \
    'Vaultwarden mDNS hostname [vault1.lan]:' "${dns_to_mdns}"
expect_contains "DNS to mDNS switch produces the expected selection" \
    'RESULT mode=mdns hostname=vaultwarden.local' "${dns_to_mdns}"

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
