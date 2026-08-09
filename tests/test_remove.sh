#!/usr/bin/env bash
# shellcheck disable=SC2317 # Test doubles are invoked indirectly by removal helpers.

set -o errexit
set -o nounset
set -o pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly TEST_DIR
REPO_DIR=$(cd -- "${TEST_DIR}/.." && pwd -P)
readonly REPO_DIR

# shellcheck disable=SC1090
. "${REPO_DIR}/remove.sh"

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

remove_is_root() { return 1; }
root_output=$(remove_require_root 2>&1 || true)
nonroot_is_refused() { remove_require_root >/dev/null 2>&1; }
expect_failure "non-root invocation exits non-zero" nonroot_is_refused
expect_success "non-root removal is refused" grep -Fq 'This operation requires root privileges.' <<<"${root_output}"
expect_success "non-root refusal prints exact sudo command" grep -Fxq 'sudo ./remove.sh' <<<"${root_output}"
remove_is_root() { return 0; }

remove_path_owner() { printf '0\n'; }
remove_path_permissions() { printf '644\n'; }
unknown_dir="${temporary_dir}/unknown"
mkdir -p -- "${unknown_dir}"
expect_failure "unknown installation directory is refused" remove_validate_appliance \
    "${unknown_dir}" "${unknown_dir}/.vaultwarden-appliance" "${unknown_dir}"
expect_failure "missing appliance marker is refused" remove_validate_appliance \
    "${unknown_dir}" "${unknown_dir}/.vaultwarden-appliance" "${unknown_dir}"
printf 'Foreign Vaultwarden\n' > "${unknown_dir}/.vaultwarden-appliance"
expect_failure "foreign marker content is refused" remove_validate_appliance \
    "${unknown_dir}" "${unknown_dir}/.vaultwarden-appliance" "${unknown_dir}"
printf 'Vaultwarden Appliance\n' > "${unknown_dir}/.vaultwarden-appliance"
expect_success "exact appliance marker validates ownership" remove_validate_appliance \
    "${unknown_dir}" "${unknown_dir}/.vaultwarden-appliance" "${unknown_dir}"

expect_success "exact destructive confirmation is accepted" remove_confirmation_matches 'REMOVE VAULTWARDEN'
expect_failure "wrong destructive confirmation is rejected" remove_confirmation_matches 'remove vaultwarden'
expect_failure "empty destructive confirmation is rejected" remove_confirmation_matches ''
sentinel="${temporary_dir}/cancel-sentinel"
printf 'preserve\n' > "${sentinel}"
remove_read_confirmation() { REPLY='cancel'; return 0; }
cancel_is_refused() { remove_confirm >/dev/null; }
expect_failure "cancelled confirmation does not continue" cancel_is_refused
expect_equal "cancellation changes no fixture data" preserve "$(<"${sentinel}")"

if command_exists flock; then
    lock_file="${temporary_dir}/operation.lock"
    flock -n "${lock_file}" -c 'sleep 2' &
    holder_pid=$!
    sleep 0.2
    expect_failure "global lock contention is rejected" acquire_appliance_lock "${lock_file}"
    wait "${holder_pid}"
else
    pass "global lock contention test skipped because flock is unavailable"
fi

declare -A CONTAINER_LABELS=()
remove_container_label() { printf '%s\n' "${CONTAINER_LABELS[$1|$2]:-}"; }
CONTAINER_LABELS['vaultwarden|com.docker.compose.project']=vaultwarden
CONTAINER_LABELS['vaultwarden|com.docker.compose.service']=vaultwarden
CONTAINER_LABELS['vaultwarden|com.docker.compose.project.working_dir']=/opt/vaultwarden
expect_success "owned Vaultwarden container labels are accepted" remove_container_is_owned vaultwarden vaultwarden
CONTAINER_LABELS['caddy|com.docker.compose.project']=vaultwarden
CONTAINER_LABELS['caddy|com.docker.compose.service']=caddy
CONTAINER_LABELS['caddy|com.docker.compose.project.working_dir']=/opt/vaultwarden
expect_success "owned Caddy container labels are accepted" remove_container_is_owned caddy caddy
CONTAINER_LABELS['vaultwarden|com.docker.compose.project']=foreign
expect_failure "foreign same-name container is rejected" remove_container_is_owned vaultwarden vaultwarden
CONTAINER_LABELS['vaultwarden|com.docker.compose.project']=vaultwarden

declare -A NETWORK_LABELS=()
remove_network_label() { printf '%s\n' "${NETWORK_LABELS[$1|$2]:-}"; }
NETWORK_LABELS['vaultwarden-appliance|com.docker.compose.project']=vaultwarden
NETWORK_LABELS['vaultwarden-appliance|com.docker.compose.network']=appliance
expect_success "owned appliance network labels are accepted" remove_network_is_owned vaultwarden-appliance
NETWORK_LABELS['vaultwarden-appliance|com.docker.compose.network']=foreign
expect_failure "foreign same-name network is rejected" remove_network_is_owned vaultwarden-appliance

remove_container_exists() { return 1; }
expect_success "missing container is handled idempotently" remove_container vaultwarden
remove_network_exists() { return 1; }
expect_success "missing network is handled idempotently" remove_network

absent_file="${temporary_dir}/already-absent"
expect_success "missing installed file is accepted for a partial-removal rerun" \
    remove_validate_owned_file "${absent_file}" '# marker'
foreign_file="${temporary_dir}/foreign-helper"
printf '# foreign\n' > "${foreign_file}"
expect_failure "foreign installed file is refused" \
    remove_validate_owned_file "${foreign_file}" '# Vaultwarden Appliance helper'

valid_tree="${temporary_dir}/valid-tree"
mkdir -p -- "${valid_tree}/data"
printf 'Vaultwarden Appliance\n' > "${valid_tree}/.vaultwarden-appliance"
printf 'sensitive\n' > "${valid_tree}/data/db.sqlite3"
expect_success "validated appliance tree may be removed" remove_installation_tree \
    "${valid_tree}" "${valid_tree}/.vaultwarden-appliance" "${valid_tree}"
expect_failure "validated tree is absent after removal" test -e "${valid_tree}"

invalid_tree="${temporary_dir}/invalid-tree"
mkdir -p -- "${invalid_tree}/data"
printf 'Foreign\n' > "${invalid_tree}/.vaultwarden-appliance"
printf 'preserve\n' > "${invalid_tree}/data/db.sqlite3"
expect_failure "installation tree is never removed without validation" remove_installation_tree \
    "${invalid_tree}" "${invalid_tree}/.vaultwarden-appliance" "${invalid_tree}"
expect_success "unknown installation data remains untouched" test -f "${invalid_tree}/data/db.sqlite3"

declare -A UNIT_FRAGMENT_PATHS=(
    ['vaultwarden-appliance-mdns.service']='/etc/systemd/system/vaultwarden-appliance-mdns.service'
    ['vaultwarden-appliance-backup.service']='/etc/systemd/system/vaultwarden-appliance-backup.service'
    ['vaultwarden-appliance-backup.timer']='/etc/systemd/system/vaultwarden-appliance-backup.timer'
)
remove_unit_property() {
    case "$2" in
        LoadState) printf 'loaded\n' ;;
        FragmentPath) printf '%s\n' "${UNIT_FRAGMENT_PATHS[$1]:-}" ;;
        *) return 1 ;;
    esac
}
remove_validate_owned_file() { return 0; }
expect_success "expected systemd fragment paths are accepted" remove_validate_systemd_units
UNIT_FRAGMENT_PATHS['vaultwarden-appliance-mdns.service']='/usr/lib/systemd/system/foreign.service'
expect_failure "foreign same-name systemd unit is rejected" remove_validate_systemd_units

implemented_units=$(sed -nE \
    's/.*remove_stop_(disable_)?unit "\$\{(BACKUP_TIMER|BACKUP_SERVICE|MDNS_SERVICE)\}".*/\2/p' \
    "${REPO_DIR}/remove.sh" | sort -u)
expect_equal "only the three expected appliance unit constants are stopped" \
    $'BACKUP_SERVICE\nBACKUP_TIMER\nMDNS_SERVICE' "${implemented_units}"
expected_units_are_explicit() {
    local unit
    for unit in vaultwarden-appliance-backup.timer \
        vaultwarden-appliance-backup.service vaultwarden-appliance-mdns.service; do
        grep -Fq "${unit}" "${REPO_DIR}/remove.sh" || return 1
    done
}
expect_success "expected systemd unit names remain explicit" expected_units_are_explicit

expect_failure "uninstaller never mounts USB" grep -Eq \
    '^[[:space:]]*(mount|umount)[[:space:]]' "${REPO_DIR}/remove.sh"
expect_failure "uninstaller never formats or partitions storage" grep -Eq \
    '^[[:space:]]*(mkfs|mkfs\.|sfdisk|fdisk|parted|wipefs)[[:space:]]' "${REPO_DIR}/remove.sh"
expect_failure "uninstaller never deletes USB backup paths" grep -Eq \
    'rm .*VWBACKUP|rm .*/run/vaultwarden-appliance/backup' "${REPO_DIR}/remove.sh"
expect_failure "Docker images and prune commands are never removed" grep -Eq \
    'docker .*\b(rmi|prune)\b|docker image rm|remove_docker .*\b(rmi|prune)\b|remove_docker image rm' \
    "${REPO_DIR}/remove.sh"
expect_failure "Docker and Avahi packages are never uninstalled" grep -Eq \
    '^[[:space:]]*(apt|apt-get|dnf|yum|pacman|zypper).*(remove|purge|uninstall)' \
    "${REPO_DIR}/remove.sh"
expect_failure "docker group membership is never modified" grep -Eq \
    '^[[:space:]]*(usermod|gpasswd|groupdel|deluser)[[:space:]]' "${REPO_DIR}/remove.sh"
expect_failure "Avahi daemon is never stopped or disabled" grep -Eq \
    '(stop|disable).*avahi-daemon|avahi-daemon.*(stop|disable)' "${REPO_DIR}/remove.sh"
expect_failure "no keep-data option exists" grep -Eq -- '--keep-data|keep_data|KEEP_DATA' "${REPO_DIR}/remove.sh"
expect_failure "no broad Docker cleanup command exists" grep -Eq \
    'docker (system|container|network|volume) prune|remove_docker (system|container|network|volume) prune' \
    "${REPO_DIR}/remove.sh"
# shellcheck disable=SC2016 # The literal implementation line is the assertion target.
expect_success "recursive deletion is fixed to the validated installation tree" grep -Fxq \
    '    rm -rf --one-file-system -- "$1"' "${REPO_DIR}/remove.sh"

printf '1..%d\n' "${TESTS}"
(( FAILURES == 0 ))
