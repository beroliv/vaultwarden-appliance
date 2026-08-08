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
    '/dev/mmcblk0||disk|179:0|64000000000|0' \
    '/dev/mmcblk0p1|/dev/mmcblk0|part|179:1|536870912|0' \
    '/dev/mmcblk0p2|/dev/mmcblk0|part|179:2|63400000000|0' \
    '/dev/sda||disk|8:0|32000000000|0' \
    '/dev/sda1|/dev/sda|part|8:1|31900000000|0')
sd_mounts=$(printf '%s\n' '/|/dev/mmcblk0p2' '/boot|/dev/mmcblk0p1')
sd_protected=$(storage_protected_disks_from_mounts "${sd_inventory}" "${sd_mounts}")
sd_candidates=$(storage_candidate_disks "${sd_inventory}" "${sd_protected}")

expect_equal "SD-root partition resolves to the whole SD disk" \
    '/dev/mmcblk0' "$(storage_resolve_physical_disks "${sd_inventory}" /dev/mmcblk0p2)"
expect_equal "SD system disk is protected" '/dev/mmcblk0|/, /boot' "${sd_protected}"
expect_equal "external USB-style disk remains selectable" '/dev/sda' "${sd_candidates}"
expect_failure "system SD disk never enters candidate list" grep -Fxq /dev/mmcblk0 <<<"${sd_candidates}"

usb_root_inventory=$(printf '%s\n' \
    '/dev/sda||disk|8:0|500000000000|0' \
    '/dev/sda1|/dev/sda|part|8:1|536870912|0' \
    '/dev/sda2|/dev/sda|part|8:2|499000000000|0' \
    '/dev/sdb||disk|8:16|64000000000|0')
usb_root_protected=$(storage_protected_disks_from_mounts \
    "${usb_root_inventory}" '/|/dev/sda2')
usb_root_candidates=$(storage_candidate_disks "${usb_root_inventory}" "${usb_root_protected}")
expect_equal "USB SSD containing root is protected regardless of transport" \
    '/dev/sda|/' "${usb_root_protected}"
expect_equal "USB-root fixture offers only the other disk" '/dev/sdb' "${usb_root_candidates}"

nvme_inventory=$(printf '%s\n' \
    '/dev/nvme0n1||disk|259:0|1000000000000|0' \
    '/dev/nvme0n1p2|/dev/nvme0n1|part|259:2|999000000000|0' \
    '/dev/sdc||disk|8:32|128000000000|0')
nvme_protected=$(storage_protected_disks_from_mounts "${nvme_inventory}" '/|/dev/nvme0n1p2')
nvme_candidates=$(storage_candidate_disks "${nvme_inventory}" "${nvme_protected}")
expect_equal "NVMe root partition resolves to the complete NVMe disk" \
    '/dev/nvme0n1' "$(storage_resolve_physical_disks "${nvme_inventory}" /dev/nvme0n1p2)"
expect_equal "NVMe system disk is absent from candidates" '/dev/sdc' "${nvme_candidates}"

multiple_inventory=$(printf '%s\n' \
    '/dev/mmcblk0||disk|179:0|64000000000|0' \
    '/dev/mmcblk0p2|/dev/mmcblk0|part|179:2|63000000000|0' \
    '/dev/sda||disk|8:0|32000000000|0' \
    '/dev/sdb||disk|8:16|500000000000|0' \
    '/dev/sdc||disk|8:32|1000000000|1')
multiple_protected=$(storage_protected_disks_from_mounts "${multiple_inventory}" '/|/dev/mmcblk0p2')
multiple_candidates=$(storage_candidate_disks "${multiple_inventory}" "${multiple_protected}")
expect_equal "multiple external disks are listed and read-only disks are excluded" \
    $'/dev/sda\n/dev/sdb' "${multiple_candidates}"

no_external_inventory=$(printf '%s\n' \
    '/dev/mmcblk0||disk|179:0|64000000000|0' \
    '/dev/mmcblk0p2|/dev/mmcblk0|part|179:2|63000000000|0')
no_external_protected=$(storage_protected_disks_from_mounts \
    "${no_external_inventory}" '/|/dev/mmcblk0p2')
expect_equal "no external disks is a clean empty candidate result" '' \
    "$(storage_candidate_disks "${no_external_inventory}" "${no_external_protected}")"

mapper_inventory=$(printf '%s\n' \
    '/dev/sda||disk|8:0|500000000000|0' \
    '/dev/sda2|/dev/sda|part|8:2|499000000000|0' \
    '/dev/mapper/vg-root|/dev/sda2|lvm|253:0|100000000000|0' \
    '/dev/sdb||disk|8:16|64000000000|0')
mapper_protected=$(storage_protected_disks_from_mounts \
    "${mapper_inventory}" '/|/dev/mapper/vg-root')
expect_equal "device-mapper root resolves through its partition to the physical disk" \
    '/dev/sda|/' "${mapper_protected}"
expect_equal "device-mapper system backing disk is never selectable" '/dev/sdb' \
    "$(storage_candidate_disks "${mapper_inventory}" "${mapper_protected}")"

malformed_inventory=$(printf '%s\n' \
    '/dev/sda||disk|8:0|500000000000|0' \
    '/dev/mapper/vg-root||lvm|253:0|100000000000|0' \
    '/dev/sdb||disk|8:16|64000000000|0')
expect_failure "unknown system topology fails closed" \
    storage_protected_disks_from_mounts "${malformed_inventory}" '/|/dev/mapper/vg-root'
expect_failure "missing parent reference makes inventory invalid" storage_validate_inventory \
    '/dev/sda1|/dev/missing|part|8:1|1000000000|0'

expect_equal "valid numbered selection maps to internal index" '1' \
    "$(storage_selection_index 2 3)"
expect_failure "zero is not a valid selection" storage_selection_index 0 2
expect_failure "out-of-range selection is rejected" storage_selection_index 3 2
expect_failure "manual device path cannot be selected" storage_selection_index /dev/sdb 2
expect_failure "protected device path cannot be manually selected" \
    storage_selection_index /dev/mmcblk0 1

printf '1..%d\n' "${TESTS}"
(( FAILURES == 0 ))
