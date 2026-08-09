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

TEST_PATH_OWNER=0
TEST_PATH_PERMISSIONS=644
remove_path_owner() { printf '%s\n' "${TEST_PATH_OWNER}"; }
remove_path_permissions() { printf '%s\n' "${TEST_PATH_PERMISSIONS}"; }
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

create_source_checkout() {
    local directory=$1
    local origin=${2:-https://github.com/beroliv/vaultwarden-appliance.git}
    local branch=${3:-main}
    local project_file

    mkdir -p -- "${directory}"
    git init --quiet "${directory}"
    git -C "${directory}" symbolic-ref HEAD "refs/heads/${branch}"
    git -C "${directory}" remote add origin "${origin}"
    for project_file in "${BOOTSTRAP_PROJECT_FILES[@]}"; do
        printf '# fixture\n' > "${directory}/${project_file}"
    done
}

valid_source="${temporary_dir}/canonical-valid"
create_source_checkout "${valid_source}"
expect_success "valid canonical bootstrap checkout is positively identified" \
    remove_validate_source_checkout "${valid_source}" "${valid_source}"
expect_success "valid canonical bootstrap checkout is removed" \
    remove_source_checkout_if_owned "${valid_source}" "${valid_source}"
expect_failure "removed canonical bootstrap checkout is absent" test -e "${valid_source}"

absent_source="${temporary_dir}/canonical-absent"
SOURCE_CHECKOUT_STATUS=unchanged
expect_success "absent canonical source path continues cleanly" \
    remove_source_checkout_if_owned "${absent_source}" "${absent_source}"
expect_equal "absent canonical source path is recorded" absent "${SOURCE_CHECKOUT_STATUS}"

symlink_target="${temporary_dir}/canonical-symlink-target"
symlink_source="${temporary_dir}/canonical-symlink"
create_source_checkout "${symlink_target}"
ln -s -- "${symlink_target}" "${symlink_source}"
if [[ -L "${symlink_source}" ]]; then
    SOURCE_CHECKOUT_STATUS=unchanged
    expect_success "canonical source symlink is safely skipped" \
        remove_source_checkout_if_owned "${symlink_source}" "${symlink_source}"
    expect_success "canonical source symlink target remains untouched" \
        test -f "${symlink_target}/VERSION"
    expect_equal "canonical source symlink is recorded as preserved" \
        preserved "${SOURCE_CHECKOUT_STATUS}"
else
    pass "canonical source symlink test skipped because this filesystem did not create a symbolic link"
    pass "canonical source symlink target test skipped because symbolic links are unavailable"
    pass "canonical source symlink status test skipped because symbolic links are unavailable"
fi

wrong_origin_source="${temporary_dir}/canonical-wrong-origin"
create_source_checkout "${wrong_origin_source}" 'https://example.invalid/foreign.git'
expect_failure "wrong Git origin cannot prove source ownership" \
    remove_validate_source_checkout "${wrong_origin_source}" "${wrong_origin_source}"
wrong_origin_output=$(remove_source_checkout_if_owned \
    "${wrong_origin_source}" "${wrong_origin_source}" 2>&1)
expect_success "wrong Git origin is not deleted" test -d "${wrong_origin_source}"
expect_success "uncertain source ownership reports skipped cleanup" grep -Fq \
    'Source cleanup was skipped because ownership could not be verified' \
    <<<"${wrong_origin_output}"

multiple_origin_source="${temporary_dir}/canonical-multiple-origins"
create_source_checkout "${multiple_origin_source}"
git -C "${multiple_origin_source}" remote set-url --add origin \
    'https://example.invalid/additional.git'
expect_failure "multiple Git origin URLs cannot prove exact source ownership" \
    remove_validate_source_checkout "${multiple_origin_source}" "${multiple_origin_source}"
expect_success "checkout with multiple Git origin URLs is safely skipped" \
    remove_source_checkout_if_owned "${multiple_origin_source}" "${multiple_origin_source}"
expect_success "checkout with multiple Git origin URLs remains" \
    test -d "${multiple_origin_source}"

wrong_branch_source="${temporary_dir}/canonical-wrong-branch"
create_source_checkout "${wrong_branch_source}" \
    'https://github.com/beroliv/vaultwarden-appliance.git' develop
expect_failure "wrong Git branch cannot prove source ownership" \
    remove_validate_source_checkout "${wrong_branch_source}" "${wrong_branch_source}"
expect_success "wrong Git branch is safely skipped" \
    remove_source_checkout_if_owned "${wrong_branch_source}" "${wrong_branch_source}"
expect_success "wrong Git branch checkout remains" test -d "${wrong_branch_source}"

non_git_source="${temporary_dir}/canonical-not-git"
mkdir -p -- "${non_git_source}"
for project_file in "${BOOTSTRAP_PROJECT_FILES[@]}"; do
    printf '# fixture\n' > "${non_git_source}/${project_file}"
done
expect_success "non-Git canonical source directory is safely skipped" \
    remove_source_checkout_if_owned "${non_git_source}" "${non_git_source}"
expect_success "non-Git canonical source directory is preserved" test -f "${non_git_source}/VERSION"

wrong_owner_source="${temporary_dir}/canonical-wrong-owner"
create_source_checkout "${wrong_owner_source}"
TEST_PATH_OWNER=1000
expect_success "non-root-owned canonical source directory is safely skipped" \
    remove_source_checkout_if_owned "${wrong_owner_source}" "${wrong_owner_source}"
expect_success "non-root-owned canonical source directory remains" test -d "${wrong_owner_source}"
TEST_PATH_OWNER=0

unsafe_permissions_source="${temporary_dir}/canonical-unsafe-permissions"
create_source_checkout "${unsafe_permissions_source}"
TEST_PATH_PERMISSIONS=777
expect_success "world-writable canonical source directory is safely skipped" \
    remove_source_checkout_if_owned \
    "${unsafe_permissions_source}" "${unsafe_permissions_source}"
expect_success "world-writable canonical source directory remains" \
    test -d "${unsafe_permissions_source}"
TEST_PATH_PERMISSIONS=644

missing_file_source="${temporary_dir}/canonical-missing-file"
create_source_checkout "${missing_file_source}"
rm -f -- "${missing_file_source}/VERSION"
expect_success "canonical source with a missing project file is safely skipped" \
    remove_source_checkout_if_owned "${missing_file_source}" "${missing_file_source}"
expect_success "canonical source with a missing project file remains" \
    test -d "${missing_file_source}"

canonical_fixture="${temporary_dir}/canonical-with-manual-clone"
manual_clone="${temporary_dir}/manual-clone"
create_source_checkout "${canonical_fixture}"
create_source_checkout "${manual_clone}"
expect_success "eligible canonical fixture is removed without touching another clone" \
    remove_source_checkout_if_owned "${canonical_fixture}" "${canonical_fixture}"
expect_success "manual clone elsewhere is never deleted" test -f "${manual_clone}/VERSION"

self_checkout="${temporary_dir}/self-checkout"
self_result="${temporary_dir}/self-result"
create_source_checkout "${self_checkout}"
self_removal_finishes() (
    cd -- "${self_checkout}"
    remove_source_checkout_if_owned "${self_checkout}" "${self_checkout}"
    remove_print_result > "${self_result}"
)
expect_success "removal safely finishes when invoked inside the source checkout" \
    self_removal_finishes
expect_failure "self-invoked source checkout is removed" test -e "${self_checkout}"
expect_success "self-invoked removal still prints its final result" \
    grep -Fq 'Vaultwarden Appliance removed.' "${self_result}"

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

flow_log="${temporary_dir}/removal-flow"
critical_cleanup_precedes_source_removal() (
    remove_require_root() { return 0; }
    remove_acquire_lock() { return 0; }
    remove_validate_appliance() { return 0; }
    remove_require_runtime() { return 0; }
    remove_validate_docker_resources() { return 0; }
    remove_validate_installed_files() { return 0; }
    remove_validate_systemd_units() { return 0; }
    remove_confirm() { return 0; }
    remove_stop_services() { printf 'services\n' >> "${flow_log}"; }
    remove_docker_resources() { printf 'docker\n' >> "${flow_log}"; }
    remove_installed_files() { printf 'files\n' >> "${flow_log}"; }
    remove_services_are_stopped() { return 0; }
    remove_container_is_absent() { return 0; }
    remove_installation_tree() { printf 'data\n' >> "${flow_log}"; }
    remove_final_verification() { printf 'verify\n' >> "${flow_log}"; }
    remove_bootstrap_source_checkout() { printf 'source\n' >> "${flow_log}"; }
    remove_print_result() { printf 'result\n' >> "${flow_log}"; }
    REMOVAL_ERRORS=0
    remove_main
)
expect_success "source checkout removal follows all critical cleanup and verification" \
    critical_cleanup_precedes_source_removal
expect_equal "critical cleanup order places source deletion last" \
    $'services\ndocker\nfiles\ndata\nverify\nsource\nresult' "$(<"${flow_log}")"

cancel_source_marker="${temporary_dir}/cancel-source-called"
cancellation_preserves_source_checkout() (
    remove_require_root() { return 0; }
    remove_acquire_lock() { return 0; }
    remove_validate_appliance() { return 0; }
    remove_require_runtime() { return 0; }
    remove_validate_docker_resources() { return 0; }
    remove_validate_installed_files() { return 0; }
    remove_validate_systemd_units() { return 0; }
    remove_confirm() { return 1; }
    remove_bootstrap_source_checkout() { : > "${cancel_source_marker}"; }
    remove_main
)
expect_success "cancellation before confirmation exits cleanly" \
    cancellation_preserves_source_checkout
expect_failure "cancellation never reaches source checkout cleanup" \
    test -e "${cancel_source_marker}"

partial_source_marker="${temporary_dir}/partial-source-called"
partial_failure_preserves_source_checkout() (
    remove_final_verification() { return 0; }
    remove_bootstrap_source_checkout() { : > "${partial_source_marker}"; }
    REMOVAL_ERRORS=1
    remove_finish >/dev/null 2>&1
)
expect_failure "partial appliance failure remains non-zero" \
    partial_failure_preserves_source_checkout
expect_failure "partial appliance failure never removes the source checkout" \
    test -e "${partial_source_marker}"

verification_source_marker="${temporary_dir}/verification-source-called"
failed_verification_preserves_source_checkout() (
    remove_final_verification() { return 1; }
    remove_bootstrap_source_checkout() { : > "${verification_source_marker}"; }
    REMOVAL_ERRORS=0
    remove_finish >/dev/null 2>&1
)
expect_failure "failed final verification remains non-zero" \
    failed_verification_preserves_source_checkout
expect_failure "failed final verification never removes the source checkout" \
    test -e "${verification_source_marker}"

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
# shellcheck disable=SC2016 # The literal canonical-path call is the assertion target.
expect_success "bootstrap source cleanup is called only with the canonical fixed path" grep -Fq \
    '"${BOOTSTRAP_SOURCE_DIR}" "${BOOTSTRAP_SOURCE_DIR}"' "${REPO_DIR}/remove.sh"
expect_failure "uninstaller never derives source deletion from its invocation directory" grep -Eq \
    'remove_(delete_tree|source_checkout_tree).*SCRIPT_DIR|rm .*SCRIPT_DIR' "${REPO_DIR}/remove.sh"

printf '1..%d\n' "${TESTS}"
(( FAILURES == 0 ))
