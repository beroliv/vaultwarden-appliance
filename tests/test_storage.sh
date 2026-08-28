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
. "${REPO_DIR}/lib/storage.sh"
# shellcheck disable=SC1090
. "${REPO_DIR}/vwctl"

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

sd_inventory=$(printf '%s\n' \
    '/dev/mmcblk0||disk|179:0|64000000000|0|1' \
    '/dev/mmcblk0p1|/dev/mmcblk0|part|179:1|536870912|0|0' \
    '/dev/mmcblk0p2|/dev/mmcblk0|part|179:2|63400000000|0|0' \
    '/dev/sda||disk|8:0|32000000000|0|1' \
    '/dev/sda1|/dev/sda|part|8:1|31900000000|0|0')
sd_mounts=$(printf '%s\n' '/|/dev/mmcblk0p2' '/boot|/dev/mmcblk0p1')
sd_protected=$(storage_protected_disks_from_mounts "${sd_inventory}" "${sd_mounts}")
sd_candidates=$(storage_candidate_disks "${sd_inventory}" "${sd_protected}")

expect_equal "SD-root partition resolves to the whole SD disk" \
    '/dev/mmcblk0' "$(storage_resolve_physical_disks "${sd_inventory}" /dev/mmcblk0p2)"
expect_equal "SD system disk is protected" '/dev/mmcblk0|/, /boot' "${sd_protected}"
expect_equal "external USB-style disk remains selectable" '/dev/sda' "${sd_candidates}"
expect_failure "system SD disk never enters candidate list" grep -Fxq /dev/mmcblk0 <<<"${sd_candidates}"

usb_root_inventory=$(printf '%s\n' \
    '/dev/sda||disk|8:0|500000000000|0|1' \
    '/dev/sda1|/dev/sda|part|8:1|536870912|0|0' \
    '/dev/sda2|/dev/sda|part|8:2|499000000000|0|0' \
    '/dev/sdb||disk|8:16|64000000000|0|1')
usb_root_protected=$(storage_protected_disks_from_mounts \
    "${usb_root_inventory}" '/|/dev/sda2')
usb_root_candidates=$(storage_candidate_disks "${usb_root_inventory}" "${usb_root_protected}")
expect_equal "USB SSD containing root is protected regardless of transport" \
    '/dev/sda|/' "${usb_root_protected}"
expect_equal "USB-root fixture offers only the other disk" '/dev/sdb' "${usb_root_candidates}"

nvme_inventory=$(printf '%s\n' \
    '/dev/nvme0n1||disk|259:0|1000000000000|0|1' \
    '/dev/nvme0n1p2|/dev/nvme0n1|part|259:2|999000000000|0|0' \
    '/dev/sdc||disk|8:32|128000000000|0|1')
nvme_protected=$(storage_protected_disks_from_mounts "${nvme_inventory}" '/|/dev/nvme0n1p2')
nvme_candidates=$(storage_candidate_disks "${nvme_inventory}" "${nvme_protected}")
expect_equal "NVMe root partition resolves to the complete NVMe disk" \
    '/dev/nvme0n1' "$(storage_resolve_physical_disks "${nvme_inventory}" /dev/nvme0n1p2)"
expect_equal "NVMe system disk is absent from candidates" '/dev/sdc' "${nvme_candidates}"

multiple_inventory=$(printf '%s\n' \
    '/dev/mmcblk0||disk|179:0|64000000000|0|1' \
    '/dev/mmcblk0p2|/dev/mmcblk0|part|179:2|63000000000|0|0' \
    '/dev/sda||disk|8:0|32000000000|0|1' \
    '/dev/sdb||disk|8:16|500000000000|0|1' \
    '/dev/sdc||disk|8:32|1000000000|1|1')
multiple_protected=$(storage_protected_disks_from_mounts "${multiple_inventory}" '/|/dev/mmcblk0p2')
multiple_candidates=$(storage_candidate_disks "${multiple_inventory}" "${multiple_protected}")
expect_equal "multiple external disks are listed and read-only disks are excluded" \
    $'/dev/sda\n/dev/sdb' "${multiple_candidates}"

no_external_inventory=$(printf '%s\n' \
    '/dev/mmcblk0||disk|179:0|64000000000|0|1' \
    '/dev/mmcblk0p2|/dev/mmcblk0|part|179:2|63000000000|0|0')
no_external_protected=$(storage_protected_disks_from_mounts \
    "${no_external_inventory}" '/|/dev/mmcblk0p2')
expect_equal "no external disks is a clean empty candidate result" '' \
    "$(storage_candidate_disks "${no_external_inventory}" "${no_external_protected}")"

mapper_inventory=$(printf '%s\n' \
    '/dev/sda||disk|8:0|500000000000|0|1' \
    '/dev/sda2|/dev/sda|part|8:2|499000000000|0|0' \
    '/dev/mapper/vg-root|/dev/sda2|lvm|253:0|100000000000|0|0' \
    '/dev/sdb||disk|8:16|64000000000|0|1')
mapper_protected=$(storage_protected_disks_from_mounts \
    "${mapper_inventory}" '/|/dev/mapper/vg-root')
expect_equal "device-mapper root resolves through its partition to the physical disk" \
    '/dev/sda|/' "${mapper_protected}"
expect_equal "device-mapper system backing disk is never selectable" '/dev/sdb' \
    "$(storage_candidate_disks "${mapper_inventory}" "${mapper_protected}")"

malformed_inventory=$(printf '%s\n' \
    '/dev/sda||disk|8:0|500000000000|0|1' \
    '/dev/mapper/vg-root||lvm|253:0|100000000000|0|0' \
    '/dev/sdb||disk|8:16|64000000000|0|1')
expect_failure "unknown system topology fails closed" \
    storage_protected_disks_from_mounts "${malformed_inventory}" '/|/dev/mapper/vg-root'
expect_failure "missing parent reference makes inventory invalid" storage_validate_inventory \
    '/dev/sda1|/dev/missing|part|8:1|1000000000|0|0'

atlas_inventory=$(printf '%s\n' \
    '/dev/mmcblk0||disk|179:0|64000000000|0|1' \
    '/dev/mmcblk0p1|/dev/mmcblk0|part|179:1|536870912|0|0' \
    '/dev/mmcblk0p2|/dev/mmcblk0|part|179:2|63400000000|0|0' \
    '/dev/zram0||disk|252:0|2147483648|0|0')
atlas_mounts=$(printf '%s\n' \
    '/|/dev/mmcblk0p2' \
    '/boot|/dev/mmcblk0p1' \
    '/boot/firmware|/dev/mmcblk0p1')
atlas_protected=$(storage_protected_disks_from_mounts "${atlas_inventory}" "${atlas_mounts}")
expect_equal "Atlas system disk remains protected with zram present" \
    '/dev/mmcblk0|/, /boot, /boot/firmware' "${atlas_protected}"
expect_equal "Atlas zram reported as TYPE=disk is not a backup candidate" '' \
    "$(storage_candidate_disks "${atlas_inventory}" "${atlas_protected}")"

pseudo_inventory=$(printf '%s\n' \
    '/dev/mmcblk0||disk|179:0|64000000000|0|1' \
    '/dev/mmcblk0p2|/dev/mmcblk0|part|179:2|63000000000|0|0' \
    '/dev/loop0||loop|7:0|1000000000|0|0' \
    '/dev/ram0||disk|1:0|64000000|0|0' \
    '/dev/zram0||disk|252:0|2147483648|0|0' \
    '/dev/nbd0||disk|43:0|32000000000|0|0' \
    '/dev/sr0||rom|11:0|4700000000|1|0' \
    '/dev/sda||disk|8:0|32000000000|0|1')
pseudo_protected=$(storage_protected_disks_from_mounts \
    "${pseudo_inventory}" '/|/dev/mmcblk0p2')
expect_equal "only device-backed whole disks survive the pseudo-device filter" '/dev/sda' \
    "$(storage_candidate_disks "${pseudo_inventory}" "${pseudo_protected}")"
expect_failure "non-disk nodes cannot claim physical device backing" storage_validate_inventory \
    '/dev/sda1|/dev/sda|part|8:1|1000000000|0|1'

expect_equal "valid numbered selection maps to internal index" '1' \
    "$(storage_selection_index 2 3)"
expect_failure "zero is not a valid selection" storage_selection_index 0 2
expect_failure "out-of-range selection is rejected" storage_selection_index 3 2
expect_failure "manual device path cannot be selected" storage_selection_index /dev/sdb 2
expect_failure "protected device path cannot be manually selected" \
    storage_selection_index /dev/mmcblk0 1

# Configured-media lookup and non-destructive adoption discovery coverage.
declare -A MOCK_PROPERTIES=()

expect_lookup_status() {
    local description=$1
    local expected_status=$2
    local inventory=$3
    local protected=$4
    local actual_status

    if storage_lookup_configured_backup \
        "${inventory}" "${protected}" 6E7F-FD0E VWBACKUP >/dev/null; then
        actual_status=0
    else
        actual_status=$?
    fi
    if [[ "${actual_status}" == "${expected_status}" ]]; then
        pass "${description}"
    else
        fail "${description}"
    fi
}

storage_lsblk_property() {
    local device=$1
    local key
    local property=$2

    key="${device}|${property}"
    printf '%s\n' "${MOCK_PROPERTIES[${key}]:-}"
}

set_filesystem_properties() {
    local device=$1
    local filesystem=$2
    local label=$3
    local uuid=$4
    local mountpoints=$5

    MOCK_PROPERTIES["${device}|FSTYPE"]=${filesystem}
    MOCK_PROPERTIES["${device}|LABEL"]=${label}
    MOCK_PROPERTIES["${device}|UUID"]=${uuid}
    MOCK_PROPERTIES["${device}|MOUNTPOINTS"]=${mountpoints}
}

atlas_inventory=$(printf '%s\n' \
    '/dev/mmcblk0||disk|179:0|64000000000|0|1' \
    '/dev/mmcblk0p1|/dev/mmcblk0|part|179:1|536870912|0|0' \
    '/dev/mmcblk0p2|/dev/mmcblk0|part|179:2|63400000000|0|0' \
    '/dev/sda||disk|8:0|62100000000|0|1' \
    '/dev/sda1|/dev/sda|part|8:1|62000000000|0|0' \
    '/dev/zram0||disk|252:0|2147483648|0|0')
atlas_mounts=$(printf '%s\n' \
    '/|/dev/mmcblk0p2' \
    '/boot/firmware|/dev/mmcblk0p1')
atlas_protected=$(storage_protected_disks_from_mounts \
    "${atlas_inventory}" "${atlas_mounts}")

MOCK_PROPERTIES=()
set_filesystem_properties /dev/sda1 exfat VWBACKUP 6E7F-FD0E ''
expect_equal "Atlas UUID search succeeds even when zram sorts after the match" '/dev/sda1' \
    "$(storage_devices_for_uuid "${atlas_inventory}" 6E7F-FD0E)"
expect_equal "valid unmounted Atlas medium resolves to its physical disk" \
    $'/dev/sda1\n/dev/sda' \
    "$(storage_lookup_configured_backup \
        "${atlas_inventory}" "${atlas_protected}" 6E7F-FD0E VWBACKUP)"

MOCK_PROPERTIES=()
set_filesystem_properties /dev/sda1 exfat VWBACKUP 6E7F-FD0E /media/vwbackup
expect_equal "valid mounted Atlas medium resolves without requiring unmount" \
    $'/dev/sda1\n/dev/sda' \
    "$(storage_lookup_configured_backup \
        "${atlas_inventory}" "${atlas_protected}" 6E7F-FD0E VWBACKUP)"

MOCK_PROPERTIES=()
expect_lookup_status "disconnected configured medium is reported as absent" 2 \
    "${atlas_inventory}" "${atlas_protected}"

MOCK_PROPERTIES=()
set_filesystem_properties /dev/sda1 exfat NOTBACKUP 6E7F-FD0E ''
expect_lookup_status "wrong filesystem label is rejected" 5 \
    "${atlas_inventory}" "${atlas_protected}"

MOCK_PROPERTIES=()
set_filesystem_properties /dev/sda1 ext4 VWBACKUP 6E7F-FD0E ''
expect_lookup_status "wrong filesystem type is rejected" 4 \
    "${atlas_inventory}" "${atlas_protected}"

duplicate_inventory=$(printf '%s\n%s\n%s\n' \
    "${atlas_inventory}" \
    '/dev/sdb||disk|8:16|32000000000|0|1' \
    '/dev/sdb1|/dev/sdb|part|8:17|31900000000|0|0')
MOCK_PROPERTIES=()
set_filesystem_properties /dev/sda1 exfat VWBACKUP 6E7F-FD0E ''
set_filesystem_properties /dev/sdb1 exfat VWBACKUP 6E7F-FD0E ''
expect_lookup_status "duplicate UUID matches are rejected" 3 \
    "${duplicate_inventory}" "${atlas_protected}"

MOCK_PROPERTIES=()
set_filesystem_properties /dev/mmcblk0p1 exfat VWBACKUP 6E7F-FD0E /boot/firmware
expect_lookup_status "matching filesystem on the protected system disk is rejected" 8 \
    "${atlas_inventory}" "${atlas_protected}"

MOCK_PROPERTIES=()
set_filesystem_properties /dev/zram0 exfat VWBACKUP 6E7F-FD0E ''
expect_lookup_status "matching filesystem on a virtual disk is rejected" 9 \
    "${atlas_inventory}" "${atlas_protected}"

storage_test_dir=$(mktemp -d)
readonly storage_test_dir
trap 'rm -rf -- "${storage_test_dir}"' EXIT
temporary_state="${storage_test_dir}/backup-state"
printf 'filesystem_uuid=6E7F-FD0E\nfilesystem_label=WRONG\n' > "${temporary_state}"
expect_failure "malformed backup state is rejected" storage_read_backup_state "${temporary_state}"

renamed_inventory=$(printf '%s\n' \
    '/dev/mmcblk0||disk|179:0|64000000000|0|1' \
    '/dev/mmcblk0p1|/dev/mmcblk0|part|179:1|536870912|0|0' \
    '/dev/mmcblk0p2|/dev/mmcblk0|part|179:2|63400000000|0|0' \
    '/dev/sdb||disk|8:16|62100000000|0|1' \
    '/dev/sdb1|/dev/sdb|part|8:17|62000000000|0|0')
MOCK_PROPERTIES=()
set_filesystem_properties /dev/sdb1 exfat VWBACKUP 6E7F-FD0E ''
expect_equal "UUID lookup survives a changed kernel device name" \
    $'/dev/sdb1\n/dev/sdb' \
    "$(storage_lookup_configured_backup \
        "${renamed_inventory}" "${atlas_protected}" 6E7F-FD0E VWBACKUP)"

composite_inventory=$(printf '%s\n' \
    '/dev/mmcblk0||disk|179:0|64000000000|0|1' \
    '/dev/mmcblk0p2|/dev/mmcblk0|part|179:2|63400000000|0|0' \
    '/dev/sda||disk|8:0|62100000000|0|1' \
    '/dev/sda1|/dev/sda|part|8:1|62000000000|0|0' \
    '/dev/mapper/backup|/dev/sda1|lvm|253:0|60000000000|0|0')
composite_protected=$(storage_protected_disks_from_mounts \
    "${composite_inventory}" '/|/dev/mmcblk0p2')
MOCK_PROPERTIES=()
set_filesystem_properties /dev/mapper/backup exfat VWBACKUP 6E7F-FD0E ''
expect_lookup_status "unsupported composite backing topology is rejected" 7 \
    "${composite_inventory}" "${composite_protected}"

MOCK_PROPERTIES=()
set_filesystem_properties /dev/sda1 exfat VWBACKUP 6E7F-FD0E ''
expect_equal "safe unconfigured VWBACKUP is discoverable for non-destructive adoption" \
    '/dev/sda1|/dev/sda|6E7F-FD0E' \
    "$(storage_discover_backup_media "${atlas_inventory}" "${atlas_protected}")"

MOCK_PROPERTIES=()
set_filesystem_properties /dev/sda1 exfat OTHER 6E7F-FD0E ''
expect_equal "wrong-label filesystem is not adoptable" '' \
    "$(storage_discover_backup_media "${atlas_inventory}" "${atlas_protected}")"

MOCK_PROPERTIES=()
set_filesystem_properties /dev/sda1 ext4 VWBACKUP 6E7F-FD0E ''
expect_equal "wrong-filesystem VWBACKUP is not adoptable" '' \
    "$(storage_discover_backup_media "${atlas_inventory}" "${atlas_protected}")"

MOCK_PROPERTIES=()
set_filesystem_properties /dev/mmcblk0p1 exfat VWBACKUP SYSTEM-UUID /boot/firmware
expect_equal "VWBACKUP on the protected system disk is not adoptable" '' \
    "$(storage_discover_backup_media "${atlas_inventory}" "${atlas_protected}")"

MOCK_PROPERTIES=()
set_filesystem_properties /dev/zram0 exfat VWBACKUP ZRAM-UUID ''
expect_equal "virtual VWBACKUP storage is not adoptable" '' \
    "$(storage_discover_backup_media "${atlas_inventory}" "${atlas_protected}")"

multiple_media_inventory=$(printf '%s\n' \
    '/dev/mmcblk0||disk|179:0|64000000000|0|1' \
    '/dev/mmcblk0p2|/dev/mmcblk0|part|179:2|63400000000|0|0' \
    '/dev/sda||disk|8:0|62100000000|0|1' \
    '/dev/sda1|/dev/sda|part|8:1|62000000000|0|0' \
    '/dev/sdb||disk|8:16|32100000000|0|1' \
    '/dev/sdb1|/dev/sdb|part|8:17|32000000000|0|0')
multiple_media_protected=$(storage_protected_disks_from_mounts \
    "${multiple_media_inventory}" '/|/dev/mmcblk0p2')
MOCK_PROPERTIES=()
set_filesystem_properties /dev/sda1 exfat VWBACKUP FIRST-UUID ''
set_filesystem_properties /dev/sdb1 exfat VWBACKUP SECOND-UUID ''
expect_equal "multiple safe VWBACKUP media remain separate adoption choices" \
    $'/dev/sda1|/dev/sda|FIRST-UUID\n/dev/sdb1|/dev/sdb|SECOND-UUID' \
    "$(storage_discover_backup_media \
        "${multiple_media_inventory}" "${multiple_media_protected}")"

# Non-destructive VWBACKUP adoption and state-permission coverage.
adopt_test_root="${storage_test_dir}/adopt"
mkdir -p -- "${adopt_test_root}"
chmod 0755 "${adopt_test_root}"
state_file="${adopt_test_root}/.backup-device"

status_reads_root_state() {
    printf 'filesystem_uuid=FEFB-F1A2\nfilesystem_label=VWBACKUP\n' > "${state_file}"
    chmod 0644 "${state_file}"
    if (( EUID == 0 )) && command -v runuser >/dev/null 2>&1 && id nobody >/dev/null 2>&1; then
        chown 0:0 "${adopt_test_root}" "${state_file}"
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
written_state="${adopt_test_root}/adopted-state"
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
