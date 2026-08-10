#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2329,SC2016 # Test doubles and literal source audits are intentional.

set -o errexit
set -o nounset
set -o pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly TEST_DIR
REPO_DIR=$(cd -- "${TEST_DIR}/.." && pwd -P)
readonly REPO_DIR

# shellcheck disable=SC1090
. "${REPO_DIR}/vwctl"

TESTS=0
FAILURES=0

pass() { TESTS=$((TESTS + 1)); printf 'ok %d - %s\n' "${TESTS}" "$1"; }
fail() { TESTS=$((TESTS + 1)); FAILURES=$((FAILURES + 1)); printf 'not ok %d - %s\n' "${TESTS}" "$1" >&2; }
expect_success() { local description=$1; shift; if "$@"; then pass "${description}"; else fail "${description}"; fi; }
expect_failure() { local description=$1; shift; if "$@"; then fail "${description}"; else pass "${description}"; fi; }
expect_equal() {
    local description=$1
    local expected=$2
    local actual=$3
    if [[ "${actual}" == "${expected}" ]]; then pass "${description}"; else fail "${description}"; fi
}

temporary_root=$(mktemp -d)
trap 'rm -rf -- "${temporary_root}"' EXIT
chmod 0755 "${temporary_root}"
state_file="${temporary_root}/.backup-device"

status_reads_root_state() {
    printf 'filesystem_uuid=FEFB-F1A2\nfilesystem_label=VWBACKUP\n' > "${state_file}"
    chmod 0644 "${state_file}"
    if (( EUID == 0 )) && command -v runuser >/dev/null 2>&1 && id nobody >/dev/null 2>&1; then
        chown 0:0 "${temporary_root}" "${state_file}"
        runuser -u nobody -- env TEST_REPO_DIR="${REPO_DIR}" TEST_STATE_FILE="${state_file}" \
            bash -c '. "${TEST_REPO_DIR}/libexec/backup"; backup_read_state_file "${TEST_STATE_FILE}"; [[ "${BACKUP_UUID}" == FEFB-F1A2 ]]'
    else
        TEST_REPO_DIR="${REPO_DIR}" TEST_STATE_FILE="${state_file}" bash -c '
            . "${TEST_REPO_DIR}/libexec/backup"
            stat() {
                case "$*" in
                    *"%u"*) printf "0\n" ;;
                    *"%a"*) printf "644\n" ;;
                    *) command stat "$@" ;;
                esac
            }
            backup_read_state_file "${TEST_STATE_FILE}"
            [[ "${BACKUP_UUID}" == FEFB-F1A2 ]]
        '
    fi
}
expect_success "unprivileged backup status reads root-owned 0755/0644 state" status_reads_root_state

chown() { return 0; }
written_state="${temporary_root}/adopted-state"
expect_success "adoption state writer persists a UUID without touching storage" \
    usb_write_backup_state "${written_state}" ADOPT-UUID
expect_equal "adoption state stores only UUID and label" \
    $'filesystem_uuid=ADOPT-UUID\nfilesystem_label=VWBACKUP' \
    "$(<"${written_state}")"
expect_equal "adoption state is mode 0644" 644 "$(stat -c '%a' "${written_state}")"
expect_failure "existing configured state is never replaced" \
    usb_write_backup_state "${written_state}" REPLACEMENT-UUID
expect_equal "refused replacement leaves the original UUID unchanged" \
    'ADOPT-UUID|VWBACKUP' "$(storage_read_backup_state "${written_state}")"

require_root() { return 0; }
require_operation_lock() { return 0; }
require_appliance() { return 0; }
usb_adopt_terminal_is_available() { return 0; }
usb_backup_state_is_absent() { return 0; }
usb_print_adopt_candidates() { return 0; }
usb_print_adopt_candidate() { return 0; }
USB_DISCOVERY_COUNT=0
discover_storage_devices() { USB_DISCOVERY_COUNT=$((USB_DISCOVERY_COUNT + 1)); }
usb_read_backup_state() { return 2; }
usb_discover_adopt_candidates() {
    USB_ADOPT_CANDIDATES=(
        '/dev/sda1|/dev/sda|FIRST-UUID'
    )
}
USB_WRITTEN_UUID=""
usb_write_backup_state() { USB_WRITTEN_UUID=$2; }
usb_confirm_adoption() { return 0; }

expect_success "one safe existing VWBACKUP is adopted after confirmation" command_usb_adopt
expect_equal "adoption persists the selected filesystem UUID" FIRST-UUID "${USB_WRITTEN_UUID}"
expect_equal "adoption performs a fresh revalidation after confirmation" 2 "${USB_DISCOVERY_COUNT}"

USB_DISCOVERY_COUNT=0
USB_WRITTEN_UUID=""
usb_discover_adopt_candidates() {
    USB_ADOPT_CANDIDATES=(
        '/dev/sda1|/dev/sda|FIRST-UUID'
        '/dev/sdb1|/dev/sdb|SECOND-UUID'
    )
}
usb_adopt_read_selection() { USB_ADOPT_SELECTION=2; }
expect_success "multiple VWBACKUP media require and honor explicit numbered selection" command_usb_adopt
expect_equal "only the explicitly selected UUID is persisted" SECOND-UUID "${USB_WRITTEN_UUID}"

USB_WRITTEN_UUID=""
usb_discover_adopt_candidates() {
    USB_ADOPT_CANDIDATES=(
        '/dev/sda1|/dev/sda|FIRST-UUID'
    )
}
usb_confirm_adoption() { return 1; }
expect_success "adoption cancellation exits cleanly" command_usb_adopt
expect_equal "adoption cancellation writes no state" '' "${USB_WRITTEN_UUID}"

USB_WRITTEN_UUID=""
usb_read_backup_state() { printf 'CONFIGURED-UUID|VWBACKUP\n'; }
expect_success "already configured backup state is left unchanged" command_usb_adopt
expect_equal "configured state is not silently replaced" '' "${USB_WRITTEN_UUID}"

expect_success "adoption implementation contains no destructive storage command" bash -c '
    source_file=$1
    function_body=$(sed -n "/^command_usb_adopt()/,/^}/p" "${source_file}")
    ! grep -Eq "(^|[^[:alnum:]_])(sfdisk|fdisk|wipefs|mkfs|mkfs\.exfat|dd|parted|fsck)([^[:alnum:]_]|$)" <<<"${function_body}"
' _ "${REPO_DIR}/vwctl"
expect_success "adoption never mounts or writes through a block-device path" bash -c '
    source_file=$1
    function_body=$(sed -n "/^command_usb_adopt()/,/^}/p" "${source_file}")
    ! grep -Eq "(^|[[:space:]])(mount|umount|cp|install|rm)[[:space:]].*/dev/" <<<"${function_body}"
' _ "${REPO_DIR}/vwctl"
expect_success "restore persists a discovered USB UUID only after integrity verification" bash -c '
    file=$1
    grep -Fq "RESTORE_SELECTED_USB_UUID" "${file}" &&
        grep -Fq "restore_write_backup_state_after_success" "${file}" &&
        grep -Fq "chmod 0644" "${file}"
' _ "${REPO_DIR}/libexec/restore"
expect_success "disaster recovery requires no destructive USB setup command" bash -c '
    file=$1
    body=$(sed -n "/^command_restore()/,/^}/p" "${file}")
    ! grep -Fq "usb setup" <<<"${body}"
' _ "${REPO_DIR}/vwctl"
expect_success "existing destructive setup confirmation remains unchanged" grep -Fq \
    'confirmation=$(storage_disk_confirmation_text "${identity}")' \
    "${REPO_DIR}/libexec/usb-setup"
expect_success "installer repairs recognized state to root-readable mode idempotently" grep -Fq \
    'chmod 0644 "${BACKUP_STATE_FILE}"' "${REPO_DIR}/install.sh"

printf '1..%d\n' "${TESTS}"
(( FAILURES == 0 ))
