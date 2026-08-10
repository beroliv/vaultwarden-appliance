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

TESTS=0
FAILURES=0
declare -A MOCK_PROPERTIES=()

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

expect_failure() {
    local description=$1
    shift

    if "$@"; then fail "${description}"; else pass "${description}"; fi
}

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

temporary_state=$(mktemp)
trap 'rm -f -- "${temporary_state}"' EXIT
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

printf '1..%d\n' "${TESTS}"
(( FAILURES == 0 ))
