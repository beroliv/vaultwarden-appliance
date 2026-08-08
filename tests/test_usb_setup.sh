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
. "${REPO_DIR}/libexec/usb-setup"

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

expect_status() {
    local description=$1
    local expected=$2
    local actual
    shift 2
    if "$@"; then actual=0; else actual=$?; fi
    if [[ "${actual}" == "${expected}" ]]; then pass "${description}"; else fail "${description}"; fi
}

selected_identity=$(storage_make_disk_identity \
    /dev/sda 8:0 62100000000 2790801320600048 'ADATA USB Flash Drive' usb \
    /sys/devices/platform/soc/usb1/1-1/block/sda)

expect_equal "destructive confirmation is device-specific" 'ERASE 2790801320600048' \
    "$(storage_disk_confirmation_text "${selected_identity}")"
expect_success "exact destructive confirmation is accepted" storage_confirmation_matches \
    "${selected_identity}" 'ERASE 2790801320600048'
expect_failure "incorrect destructive confirmation cancels" storage_confirmation_matches \
    "${selected_identity}" 'ERASE /dev/sda'
expect_failure "empty destructive confirmation cancels" storage_confirmation_matches \
    "${selected_identity}" ''

fallback_identity=$(storage_make_disk_identity \
    /dev/sdb 8:16 32000000000 '' 'Unknown bridge' '' \
    /sys/devices/platform/soc/usb1/1-2/block/sdb)
expect_equal "missing serial uses sysfs devpath and exact size for confirmation" \
    'ERASE /sys/devices/platform/soc/usb1/1-2/block/sdb 32000000000' \
    "$(storage_disk_confirmation_text "${fallback_identity}")"

safe_candidates='/dev/sda'
system_protected='/dev/mmcblk0|/, /boot, /boot/firmware'
expect_success "unchanged selected disk passes final revalidation" \
    storage_revalidate_selected_disk "${selected_identity}" "${selected_identity}" \
    "${safe_candidates}" "${system_protected}"
expect_status "selected device disappearance aborts revalidation" 2 \
    storage_revalidate_selected_disk "${selected_identity}" '' \
    "${safe_candidates}" "${system_protected}"

reused_path_identity=$(storage_make_disk_identity \
    /dev/sda 8:0 64000000000 DIFFERENT 'Different disk' usb \
    /sys/devices/platform/soc/usb1/1-1/block/sda)
expect_status "device path reused by another disk is rejected" 3 \
    storage_revalidate_selected_disk "${selected_identity}" "${reused_path_identity}" \
    "${safe_candidates}" "${system_protected}"

serial_mismatch_identity=$(storage_make_disk_identity \
    /dev/sda 8:0 62100000000 9999999999999999 'ADATA USB Flash Drive' usb \
    /sys/devices/platform/soc/usb1/1-1/block/sda)
expect_status "serial mismatch is rejected" 3 storage_revalidate_selected_disk \
    "${selected_identity}" "${serial_mismatch_identity}" "${safe_candidates}" "${system_protected}"

major_mismatch_identity=$(storage_make_disk_identity \
    /dev/sda 8:16 62100000000 2790801320600048 'ADATA USB Flash Drive' usb \
    /sys/devices/platform/soc/usb1/1-1/block/sda)
expect_status "major-minor mismatch is rejected" 3 storage_revalidate_selected_disk \
    "${selected_identity}" "${major_mismatch_identity}" "${safe_candidates}" "${system_protected}"

size_mismatch_identity=$(storage_make_disk_identity \
    /dev/sda 8:0 62000000000 2790801320600048 'ADATA USB Flash Drive' usb \
    /sys/devices/platform/soc/usb1/1-1/block/sda)
expect_status "exact-size mismatch is rejected" 3 storage_revalidate_selected_disk \
    "${selected_identity}" "${size_mismatch_identity}" "${safe_candidates}" "${system_protected}"

topology_mismatch_identity=$(storage_make_disk_identity \
    /dev/sda 8:0 62100000000 2790801320600048 'ADATA USB Flash Drive' usb \
    /sys/devices/platform/soc/usb2/2-1/block/sda)
expect_status "kernel topology mismatch is rejected" 3 storage_revalidate_selected_disk \
    "${selected_identity}" "${topology_mismatch_identity}" "${safe_candidates}" "${system_protected}"

expect_status "selected disk becoming a system disk is rejected" 4 \
    storage_revalidate_selected_disk "${selected_identity}" "${selected_identity}" '' \
    '/dev/sda|/'

sd_system_identity=$(storage_make_disk_identity \
    /dev/mmcblk0 179:0 64000000000 SD123 'Raspberry Pi SD' mmc \
    /sys/devices/platform/mmc/block/mmcblk0)
usb_system_identity=$(storage_make_disk_identity \
    /dev/sda 8:0 500000000000 USBROOT 'USB system SSD' usb \
    /sys/devices/platform/usb/block/sda)
nvme_system_identity=$(storage_make_disk_identity \
    /dev/nvme0n1 259:0 1000000000000 NVME123 'NVMe system disk' nvme \
    /sys/devices/pci0000:00/nvme/nvme0/nvme0n1)
expect_status "SD system disk remains impossible to revalidate as a candidate" 4 \
    storage_revalidate_selected_disk "${sd_system_identity}" "${sd_system_identity}" '' '/dev/mmcblk0|/'
expect_status "USB SSD system disk remains impossible to revalidate as a candidate" 4 \
    storage_revalidate_selected_disk "${usb_system_identity}" "${usb_system_identity}" '' '/dev/sda|/'
expect_status "NVMe system disk remains impossible to revalidate as a candidate" 4 \
    storage_revalidate_selected_disk "${nvme_system_identity}" "${nvme_system_identity}" '' '/dev/nvme0n1|/'
expect_failure "virtual sysfs devices cannot form a destructive identity" \
    storage_make_disk_identity /dev/zram0 252:0 2147483648 '' zram '' \
    /sys/devices/virtual/block/zram0

mounted_inventory=$(printf '%s\n' \
    '/dev/sda||disk|8:0|62100000000|0|1' \
    '/dev/sda1|/dev/sda|part|8:1|62000000000|0|0' \
    '/dev/sdb||disk|8:16|32000000000|0|1' \
    '/dev/sdb1|/dev/sdb|part|8:17|31900000000|0|0')

findmnt() {
    local argument
    local source=""
    local want_target=0
    local previous=""

    for argument in "$@"; do
        [[ "${previous}" == "--source" ]] && source=${argument}
        [[ "${previous}" == "--output" && "${argument}" == "TARGET" ]] && want_target=1
        previous=${argument}
    done
    case "${source}" in
        /dev/sda1)
            (( want_target == 0 )) || printf '/media/adata\n'
            return 0
            ;;
        /dev/sdb1)
            (( want_target == 0 )) || printf '/media/unrelated\n'
            return 0
            ;;
        *) return 1 ;;
    esac
}

expect_equal "mounted candidate partitions are detected without unrelated disks" '/dev/sda1' \
    "$(usb_setup_mounted_nodes "${mounted_inventory}" /dev/sda)"

umount() {
    return 1
}
expect_failure "unmount failure aborts before partitioning" \
    usb_setup_unmount_selected "${mounted_inventory}" /dev/sda

expected_gpt=$(printf '%s\n' \
    'label: gpt' \
    'unit: sectors' \
    '' \
    'size=+, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="Vaultwarden Backup"')
expect_equal "GPT generation is deterministic" "${expected_gpt}" "$(storage_gpt_layout)"

expect_success "verified GPT plus labeled exFAT layout is accepted" \
    storage_validate_backup_layout gpt 1 \
    EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 exfat VWBACKUP ABCD-1234 ''
expect_failure "incorrect exFAT label is rejected" storage_validate_backup_layout \
    gpt 1 EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 exfat OTHER ABCD-1234 ''
expect_failure "unexpected mount after setup is rejected" storage_validate_backup_layout \
    gpt 1 EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 exfat VWBACKUP ABCD-1234 /media/adata

expected_state=$(printf '%s\n' \
    'filesystem_uuid=ABCD-1234' \
    'filesystem_label=VWBACKUP')
expect_equal "UUID state generation is minimal and deterministic" "${expected_state}" \
    "$(storage_backup_state_content ABCD-1234)"

state_file=$(mktemp)
trap 'rm -f -- "${state_file}"' EXIT
storage_backup_state_content ABCD-1234 > "${state_file}"
expect_equal "generated UUID state parses successfully" 'ABCD-1234|VWBACKUP' \
    "$(storage_read_backup_state "${state_file}")"

uuid_inventory=$(printf '%s\n' \
    '/dev/mmcblk0||disk|179:0|64000000000|0|1' \
    '/dev/mmcblk0p2|/dev/mmcblk0|part|179:2|63000000000|0|0' \
    '/dev/sda||disk|8:0|62100000000|0|1' \
    '/dev/sda1|/dev/sda|part|8:1|62000000000|0|0')

storage_lsblk_property() {
    local device=$1
    local property=$2
    [[ "${property}" == "UUID" && "${device}" == "/dev/sda1" ]] || return 0
    printf 'ABCD-1234\n'
}
expect_equal "configured backup filesystem is found by UUID when present" '/dev/sda1' \
    "$(storage_devices_for_uuid "${uuid_inventory}" ABCD-1234)"

storage_lsblk_property() {
    return 0
}
expect_equal "configured backup filesystem may be absent without failure" '' \
    "$(storage_devices_for_uuid "${uuid_inventory}" ABCD-1234)"

storage_lsblk_property() {
    local device=$1
    local property=$2
    [[ "${property}" == "MOUNTPOINTS" && "${device}" == "/dev/sda1" ]] || return 0
    printf '[SWAP]\n'
}
expect_equal "active swap on a selected partition is detected and blocked" '/dev/sda1' \
    "$(usb_setup_active_swap_nodes "${mounted_inventory}" /dev/sda)"

printf '1..%d\n' "${TESTS}"
(( FAILURES == 0 ))
