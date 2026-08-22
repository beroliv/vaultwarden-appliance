#!/usr/bin/env bash
# shellcheck disable=SC2317 # Test doubles are invoked indirectly by sourced helpers.

set -o errexit
set -o nounset
set -o pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly TEST_DIR
REPO_DIR=$(cd -- "${TEST_DIR}/.." && pwd -P)
readonly REPO_DIR

# shellcheck disable=SC1090
. "${REPO_DIR}/libexec/backup"

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

temporary_dir=$(mktemp -d)
readonly temporary_dir
trap 'rm -rf -- "${temporary_dir}"' EXIT

storage_lsblk_property() {
    local key="$1|$2"

    printf '%s\n' "${MOCK_PROPERTIES[${key}]:-}"
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

expect_status "configured backup medium absent" 2 storage_lookup_configured_backup \
    "${atlas_inventory}" "${atlas_protected}" 6E7F-FD0E VWBACKUP

MOCK_PROPERTIES['/dev/sda1|UUID']=6E7F-FD0E
MOCK_PROPERTIES['/dev/sda1|FSTYPE']=exfat
MOCK_PROPERTIES['/dev/sda1|LABEL']=VWBACKUP
expect_equal "valid unmounted backup medium resolves safely" $'/dev/sda1\n/dev/sda' \
    "$(storage_lookup_configured_backup \
        "${atlas_inventory}" "${atlas_protected}" 6E7F-FD0E VWBACKUP)"

findmnt() {
    if [[ " $* " == *' --output TARGET '* ]]; then
        printf '/media/atlas/VWBACKUP\n'
        return 0
    fi
    return 1
}
expect_equal "valid existing mountpoint is reused" '/media/atlas/VWBACKUP' \
    "$(backup_existing_mountpoint /dev/sda1)"

BACKUP_UUID=6E7F-FD0E
findmnt() {
    printf '/dev/sda1\n'
}
storage_lsblk_property() {
    [[ "$2" == UUID ]] || return 0
    printf 'WRONG-UUID\n'
}
expect_status "wrong UUID after mount is rejected" 2 backup_verify_mounted_media \
    /dev/sda1 /dev/sda "${temporary_dir}"

MOUNT_CALLS=0
backup_existing_mountpoint() {
    return 1
}
backup_prepare_runtime_directory() {
    return 0
}
mount() {
    MOUNT_CALLS=$((MOUNT_CALLS + 1))
}
backup_verify_mounted_media() {
    return 0
}
BACKUP_DEVICE=/dev/sda1
BACKUP_DISK=/dev/sda
BACKUP_MOUNTED_BY_APPLIANCE=0
backup_prepare_mount
expect_equal "valid unmounted medium is mounted exactly once" '1' "${MOUNT_CALLS}"
expect_equal "temporary mount is marked appliance-owned" '1' "${BACKUP_MOUNTED_BY_APPLIANCE}"
unset -f backup_existing_mountpoint backup_prepare_runtime_directory mount \
    backup_verify_mounted_media

storage_lsblk_property() {
    local key="$1|$2"

    printf '%s\n' "${MOCK_PROPERTIES[${key}]:-}"
}
MOCK_PROPERTIES=()
MOCK_PROPERTIES['/dev/mmcblk0p1|UUID']=6E7F-FD0E
MOCK_PROPERTIES['/dev/mmcblk0p1|FSTYPE']=exfat
MOCK_PROPERTIES['/dev/mmcblk0p1|LABEL']=VWBACKUP
expect_status "protected backing disk is rejected" 8 storage_lookup_configured_backup \
    "${atlas_inventory}" "${atlas_protected}" 6E7F-FD0E VWBACKUP

required=$(backup_estimated_required_bytes 1000000)
expect_failure "insufficient free space is rejected" backup_has_sufficient_space \
    "${required}" "$((required - 1))"
expect_success "sufficient free space is accepted" backup_has_sufficient_space \
    "${required}" "${required}"

snapshot_dir="${temporary_dir}/snapshot-source"
mkdir -p -- "${snapshot_dir}"
SNAPSHOT_DIR=${snapshot_dir}
DOCKER_BACKUP_MODE=fail
docker() {
    if [[ "${DOCKER_BACKUP_MODE}" == fail ]]; then
        printf 'synthetic snapshot failure\n'
        return 1
    fi
    printf 'consistent sqlite snapshot\n' > "${SNAPSHOT_DIR}/db_20260808_230000.sqlite3"
    printf "Backup to '/data/db_20260808_230000.sqlite3' was successful\n"
}
expect_failure "database snapshot command failure is reported" \
    backup_create_database_snapshot "${snapshot_dir}" "${temporary_dir}/failed.sqlite3"

printf 'pre-existing snapshot\n' > "${snapshot_dir}/db_20260807_220000.sqlite3"
DOCKER_BACKUP_MODE=success
expect_success "built-in database snapshot is captured" \
    backup_create_database_snapshot "${snapshot_dir}" "${temporary_dir}/db.sqlite3"
expect_success "pre-existing database snapshots are preserved" \
    test -f "${snapshot_dir}/db_20260807_220000.sqlite3"

work_dir="${temporary_dir}/work"
data_dir="${temporary_dir}/data"
archive_dir="${temporary_dir}/backups"
mkdir -p -- \
    "${work_dir}/vaultwarden-appliance-backup/vaultwarden" \
    "${work_dir}/vaultwarden-appliance-backup/appliance" \
    "${data_dir}/vaultwarden/attachments/item" \
    "${data_dir}/vaultwarden/sends" \
    "${data_dir}/caddy/data/caddy/pki/authorities/local" \
    "${data_dir}/caddy/config" \
    "${archive_dir}"
printf 'backup_schema=1\n' > "${work_dir}/vaultwarden-appliance-backup/manifest"
printf 'sqlite snapshot\n' > "${work_dir}/vaultwarden-appliance-backup/vaultwarden/db.sqlite3"
printf 'attachment\n' > "${data_dir}/vaultwarden/attachments/item/file"
printf 'live database must be excluded\n' > "${data_dir}/vaultwarden/db.sqlite3"
printf 'old snapshot must be excluded\n' > "${data_dir}/vaultwarden/db_20260801_010101.sqlite3"
printf 'public root\n' > "${data_dir}/caddy/data/caddy/pki/authorities/local/root.crt"
printf 'private root\n' > "${data_dir}/caddy/data/caddy/pki/authorities/local/root.key"
printf 'public intermediate\n' > "${data_dir}/caddy/data/caddy/pki/authorities/local/intermediate.crt"
printf 'private intermediate\n' > "${data_dir}/caddy/data/caddy/pki/authorities/local/intermediate.key"

manifest_test="${temporary_dir}/manifest"
expect_success "schema-one manifest is generated" backup_write_manifest \
    "${manifest_test}" 0.1.0 2026-08-08T23:30:00Z true \
    vaultwarden/server:latest 'Vaultwarden 1.37.0' caddy:2 v2.10.0 aarch64
expect_success "manifest records CA inclusion and expected contents" grep -Fxq \
    'caddy_ca_included=yes' "${manifest_test}"
expect_failure "manifest does not contain access configuration" grep -Eq \
    '^(access_|hostname=)' "${manifest_test}"
expect_failure "manifest rejects newline injection" backup_write_manifest \
    "${temporary_dir}/unsafe-manifest" 0.1.0 2026-08-08T23:30:00Z \
    $'true\nunexpected=value' vaultwarden/server:latest \
    'Vaultwarden 1.37.0' caddy:2 v2.10.0 aarch64

appliance_fixture="${temporary_dir}/appliance"
appliance_copy="${temporary_dir}/appliance-copy"
mkdir -p -- "${appliance_fixture}" "${appliance_copy}"
printf 'Vaultwarden Appliance\n' > "${appliance_fixture}/.vaultwarden-appliance"
printf '0.1.0\n' > "${appliance_fixture}/.appliance-version"
printf 'mode=dns\nhostname=vault.lan\n' > "${appliance_fixture}/.access"
printf 'compose\n' > "${appliance_fixture}/docker-compose.yml"
printf 'caddy compose\n' > "${appliance_fixture}/docker-compose.override.yml"
expect_success "appliance configuration is staged without access state" \
    backup_copy_appliance_configuration "${appliance_fixture}" "${appliance_copy}"
expect_failure "access configuration is excluded from backup staging" \
    test -e "${appliance_copy}/.access"

tar() {
    return 1
}
expect_failure "archive creation failure is reported" backup_create_archive \
    "${work_dir}" "${archive_dir}/failed.tar.gz" "${data_dir}"
unset -f tar

valid_archive="${archive_dir}/valid.tar.gz"
expect_success "synthetic complete archive is created" backup_create_archive \
    "${work_dir}" "${valid_archive}" "${data_dir}"
expect_success "synthetic complete archive passes integrity checks" backup_verify_archive \
    "${valid_archive}" "${temporary_dir}/valid.list"
expect_failure "live SQLite database is excluded from archive" grep -Fxq \
    'vaultwarden-appliance-backup/vaultwarden/data/db.sqlite3' "${temporary_dir}/valid.list"
expect_failure "old built-in snapshots are excluded from archive" grep -Fq \
    'db_20260801_010101.sqlite3' "${temporary_dir}/valid.list"

for missing_ca in root.crt root.key intermediate.crt intermediate.key; do
    missing_data="${temporary_dir}/missing-${missing_ca}/data"
    mkdir -p -- "${temporary_dir}/missing-${missing_ca}"
    cp -a -- "${data_dir}" "${missing_data}"
    rm -f -- "${missing_data}/caddy/data/caddy/pki/authorities/local/${missing_ca}"
    missing_archive="${archive_dir}/missing-${missing_ca}.tar.gz"
    expect_failure "backup creation rejects missing Caddy ${missing_ca}" \
        backup_create_archive "${temporary_dir}/work" "${missing_archive}" "${missing_data}"
done

printf 'not a tar archive\n' > "${archive_dir}/unreadable.tar.gz"
expect_failure "unreadable archive fails integrity verification" backup_verify_archive \
    "${archive_dir}/unreadable.tar.gz" "${temporary_dir}/unreadable.list"

make_incomplete_archive() {
    local kind=$1
    local root="${temporary_dir}/incomplete-${kind}/vaultwarden-appliance-backup"
    local archive="${archive_dir}/${kind}.tar.gz"

    mkdir -p -- "${root}/vaultwarden/data" \
        "${root}/caddy/data/caddy/pki/authorities/local"
    [[ "${kind}" == missing-manifest ]] || printf 'backup_schema=1\n' > "${root}/manifest"
    [[ "${kind}" == missing-database ]] || printf 'snapshot\n' > "${root}/vaultwarden/db.sqlite3"
    [[ "${kind}" == missing-caddy ]] || printf 'root\n' > \
        "${root}/caddy/data/caddy/pki/authorities/local/root.crt"
    command tar -czf "${archive}" -C "${temporary_dir}/incomplete-${kind}" \
        vaultwarden-appliance-backup
}

make_incomplete_archive missing-manifest
expect_status "archive missing manifest is rejected specifically" 2 backup_verify_archive \
    "${archive_dir}/missing-manifest.tar.gz" "${temporary_dir}/missing-manifest.list"
make_incomplete_archive missing-database
expect_status "archive missing database snapshot is rejected specifically" 3 backup_verify_archive \
    "${archive_dir}/missing-database.tar.gz" "${temporary_dir}/missing-database.list"
make_incomplete_archive missing-caddy
expect_status "archive missing Caddy data is rejected specifically" 5 backup_verify_archive \
    "${archive_dir}/missing-caddy.tar.gz" "${temporary_dir}/missing-caddy.list"

SHA256SUM_BIN=$(type -P sha256sum)
readonly SHA256SUM_BIN
checksum_archive="${archive_dir}/checksum-create-failure.tar.gz"
cp -- "${valid_archive}" "${checksum_archive}"
sha256sum() {
    return 1
}
expect_status "checksum creation failure is reported" 2 backup_write_checksum "${checksum_archive}"
unset -f sha256sum

checksum_archive="${archive_dir}/checksum-verify-failure.tar.gz"
cp -- "${valid_archive}" "${checksum_archive}"
sha256sum() {
    if [[ "${1:-}" == "--check" ]]; then
        return 1
    fi
    "${SHA256SUM_BIN}" "$@"
}
expect_status "checksum verification failure is reported" 3 backup_write_checksum "${checksum_archive}"
unset -f sha256sum

checksum_archive="${archive_dir}/checksum-valid.tar.gz"
cp -- "${valid_archive}" "${checksum_archive}"
expect_success "checksum is generated and verified" backup_write_checksum "${checksum_archive}"

cleanup_root="${temporary_dir}/runtime"
cleanup_work="${cleanup_root}/backup-work.test"
mkdir -p -- "${cleanup_work}/sensitive"
printf 'private CA material\n' > "${cleanup_work}/sensitive/root.key"
expect_success "sensitive staging is removed after failure cleanup" \
    backup_remove_work_directory "${cleanup_work}" "${cleanup_root}"
expect_failure "cleaned staging directory no longer exists" test -e "${cleanup_work}"

SYNC_CALLS=0
UMOUNT_CALLS=0
sync() {
    SYNC_CALLS=$((SYNC_CALLS + 1))
}
umount() {
    UMOUNT_CALLS=$((UMOUNT_CALLS + 1))
}
BACKUP_ACTIVE_MOUNTPOINT="${temporary_dir}"
BACKUP_MOUNTED_BY_APPLIANCE=1
backup_finish_mount >/dev/null
expect_equal "appliance-mounted filesystem is unmounted afterward" '1' "${UMOUNT_CALLS}"

UMOUNT_CALLS=0
BACKUP_MOUNTED_BY_APPLIANCE=0
backup_finish_mount >/dev/null
expect_equal "pre-existing user mount is never unmounted" '0' "${UMOUNT_CALLS}"
unset -f sync umount

timestamp=20260808-233000
existing_archive="${archive_dir}/vaultwarden-appliance-${timestamp}.tar.gz"
printf 'existing user backup\n' > "${existing_archive}"
chosen_archive=$(backup_choose_archive_path "${archive_dir}" "${timestamp}")
expect_equal "backup filename collision receives a suffix" \
    "${archive_dir}/vaultwarden-appliance-${timestamp}-01.tar.gz" "${chosen_archive}"
expect_equal "existing backup is never deleted" 'existing user backup' "$(<"${existing_archive}")"

expect_failure "archive contains no absolute paths" awk '/^\// {found=1} END {exit !found}' \
    "${temporary_dir}/valid.list"
expect_failure "archive contains no traversal paths" awk \
    '/(^|\/)\.\.($|\/)/ {found=1} END {exit !found}' "${temporary_dir}/valid.list"

if command_exists flock; then
    lock_file="${temporary_dir}/operation.lock"
    flock -n "${lock_file}" -c 'sleep 2' &
    holder_pid=$!
    sleep 0.2
    expect_failure "global appliance lock rejects a concurrent backup" \
        acquire_appliance_lock "${lock_file}"
    wait "${holder_pid}"
else
    pass "global appliance lock test skipped because flock is unavailable"
fi

printf '1..%d\n' "${TESTS}"
(( FAILURES == 0 ))
