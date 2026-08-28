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
printf 'extended Nova Caddyfile\n' > "${appliance_fixture}/Caddyfile"
expect_success "appliance configuration is staged without access state" \
    backup_copy_appliance_configuration "${appliance_fixture}" "${appliance_copy}"
expect_failure "access configuration is excluded from backup staging" \
    test -e "${appliance_copy}/.access"
expect_failure "Caddyfile is excluded from backup staging" \
    test -e "${appliance_copy}/Caddyfile"

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

# Backup generation verification, retention, replication, status, and timer coverage.
retention_test_dir="${temporary_dir}/retention"
mkdir -p -- "${retention_test_dir}"
template_root="${retention_test_dir}/template/vaultwarden-appliance-backup"
mkdir -p -- \
    "${template_root}/vaultwarden/data" \
    "${template_root}/caddy/data/caddy/pki/authorities/local" \
    "${template_root}/appliance"
printf 'backup_schema=1\n' > "${template_root}/manifest"
printf 'snapshot\n' > "${template_root}/vaultwarden/db.sqlite3"
printf 'public root\n' > "${template_root}/caddy/data/caddy/pki/authorities/local/root.crt"
printf 'private root\n' > "${template_root}/caddy/data/caddy/pki/authorities/local/root.key"
printf 'public intermediate\n' > "${template_root}/caddy/data/caddy/pki/authorities/local/intermediate.crt"
printf 'private intermediate\n' > "${template_root}/caddy/data/caddy/pki/authorities/local/intermediate.key"
template_archive="${retention_test_dir}/template.tar.gz"
command tar -czf "${template_archive}" -C "${retention_test_dir}/template" vaultwarden-appliance-backup

make_generation() {
    local directory=$1
    local stamp=$2
    local archive="${directory}/vaultwarden-appliance-${stamp}.tar.gz"

    cp -- "${template_archive}" "${archive}"
    (cd -- "${directory}" && command sha256sum -- "${archive##*/}") > "${archive}.sha256"
}

count_managed_archives() {
    local directory=$1
    local count=0
    local archive
    for archive in "${directory}"/vaultwarden-appliance-*.tar.gz; do
        [[ -e "${archive}" ]] || continue
        backup_archive_name_is_managed "${archive##*/}" && count=$((count + 1))
    done
    printf '%d\n' "${count}"
}

valid_dir="${retention_test_dir}/valid"
mkdir -p -- "${valid_dir}"
make_generation "${valid_dir}" 20260809-023000
valid_archive="${valid_dir}/vaultwarden-appliance-20260809-023000.tar.gz"
expect_success "complete archive and checksum form a valid generation" backup_verify_generation "${valid_archive}"
expect_success "local archive integrity is verified" backup_verify_archive "${valid_archive}" "${retention_test_dir}/valid.list"
expect_success "local checksum verifies" bash -c "cd '$valid_dir' && sha256sum --check --strict '${valid_archive##*/}.sha256' >/dev/null"
rm -f -- "${valid_archive}.sha256"
expect_failure "archive without checksum is not a generation" backup_verify_generation "${valid_archive}"
make_generation "${valid_dir}" 20260809-023000
printf 'corrupt\n' >> "${valid_archive}"
expect_failure "checksum corruption invalidates a generation" backup_verify_generation "${valid_archive}"
rm -f -- "${valid_archive}" "${valid_archive}.sha256"

retention_dir="${retention_test_dir}/local-retention"
mkdir -p -- "${retention_dir}"
for day in 01 02 03 04 05 06 07; do make_generation "${retention_dir}" "202608${day}-023000"; done
protected="${retention_dir}/vaultwarden-appliance-20260807-023000.tar.gz"
expect_success "local retention accepts one through seven generations" \
    backup_apply_retention "${retention_dir}" 7 "${protected}" "${retention_test_dir}"
expect_equal "seven local generations remain at the limit" 7 "$(count_managed_archives "${retention_dir}")"
make_generation "${retention_dir}" 20260808-023000
protected="${retention_dir}/vaultwarden-appliance-20260808-023000.tar.gz"
expect_success "local retention removes generations above seven" \
    backup_apply_retention "${retention_dir}" 7 "${protected}" "${retention_test_dir}"
expect_equal "local retention keeps exactly seven valid generations" 7 "$(count_managed_archives "${retention_dir}")"
expect_failure "oldest local archive was removed" test -e "${retention_dir}/vaultwarden-appliance-20260801-023000.tar.gz"
expect_success "newly created local generation is never deleted" test -f "${protected}"
printf 'unrelated\n' > "${retention_dir}/notes.txt"
expect_success "retention with unrelated local file succeeds" \
    backup_apply_retention "${retention_dir}" 7 "${protected}" "${retention_test_dir}"
expect_success "unrelated local file is preserved" test -f "${retention_dir}/notes.txt"

outside_file="${retention_test_dir}/outside-sensitive"
printf 'keep\n' > "${outside_file}"
symlink_archive="${retention_dir}/vaultwarden-appliance-20260809-023000.tar.gz"
if ln -s "${outside_file}" "${symlink_archive}" 2>/dev/null && [[ -L "${symlink_archive}" ]]; then
    expect_failure "managed-name symlink makes retention fail closed" \
        backup_apply_retention "${retention_dir}" 7 "${protected}" "${retention_test_dir}"
    expect_equal "symlink target outside managed directory is untouched" keep "$(<"${outside_file}")"
else
    pass "managed-name symlink regression requires native symlink support"
    pass "outside-target preservation covered on native-symlink test hosts"
fi
rm -f -- "${symlink_archive}"
printf 'malformed\n' > "${retention_dir}/vaultwarden-appliance-latest.tar.gz"
printf 'malformed\n' > "${retention_dir}/vaultwarden-appliance-20260809-023000-extra.tar.gz"
expect_success "malformed backup-like filenames are rejected as generations" \
    test "$(count_managed_archives "${retention_dir}")" -eq 7
expect_success "malformed backup-like files are never deleted" \
    backup_apply_retention "${retention_dir}" 7 "${protected}" "${retention_test_dir}"
expect_success "malformed file remains unrelated" test -f "${retention_dir}/vaultwarden-appliance-latest.tar.gz"
expect_equal "production retention contains no recursive removal" 0 \
    "$(grep -Ec 'rm[[:space:]]+-r(f|[[:space:]])[^\n]*BACKUP|rm[[:space:]]+-r(f|[[:space:]])[^\n]*backup' "${REPO_DIR}/libexec/backup" || true)"

usb_dir="${retention_test_dir}/usb/backups"
mkdir -p -- "${usb_dir}" "${retention_test_dir}/work"
source_dir="${retention_test_dir}/source"
mkdir -p -- "${source_dir}"
make_generation "${source_dir}" 20260809-030000
source_archive="${source_dir}/vaultwarden-appliance-20260809-030000.tar.gz"
BACKUP_ACTIVE_MOUNTPOINT="${retention_test_dir}/usb"
BACKUP_WORK_DIR="${retention_test_dir}/work"
backup_available_bytes() { printf '999999999\n'; }
sync() { return 0; }
expect_success "USB present copies the completed local pair" \
    backup_copy_generation_to_usb "${source_archive}" "${usb_dir}"
usb_archive="${usb_dir}/${source_archive##*/}"
expect_success "USB copied checksum verifies" backup_verify_generation "${usb_archive}"
expect_success "USB copied archive remains readable" backup_verify_archive "${usb_archive}" "${retention_test_dir}/usb.list"
expect_success "existing appliance generation is recognized by the same filename and schema" \
    backup_verify_generation "${usb_archive}"
expect_success "repeat USB copy recognizes an identical completed generation" \
    backup_copy_generation_to_usb "${source_archive}" "${usb_dir}"

usb_retention="${retention_test_dir}/usb-retention"
mkdir -p -- "${usb_retention}"
for day in $(seq -w 1 30); do make_generation "${usb_retention}" "202607${day}-023000"; done
usb_protected="${usb_retention}/vaultwarden-appliance-20260730-023000.tar.gz"
expect_success "USB retention accepts thirty generations" \
    backup_apply_retention "${usb_retention}" 30 "${usb_protected}" "${retention_test_dir}"
expect_equal "USB retention leaves thirty generations at the limit" 30 "$(count_managed_archives "${usb_retention}")"
make_generation "${usb_retention}" 20260731-023000
usb_protected="${usb_retention}/vaultwarden-appliance-20260731-023000.tar.gz"
printf 'preserve\n' > "${usb_retention}/README-user.txt"
expect_success "USB retention removes generations above thirty" \
    backup_apply_retention "${usb_retention}" 30 "${usb_protected}" "${retention_test_dir}"
expect_equal "USB retention keeps exactly thirty valid generations" 30 "$(count_managed_archives "${usb_retention}")"
expect_success "unrelated USB files are preserved" test -f "${usb_retention}/README-user.txt"
expect_success "new USB generation is retained" test -f "${usb_protected}"

no_space_dir="${retention_test_dir}/usb-no-space"
mkdir -p -- "${no_space_dir}"
backup_available_bytes() { printf '0\n'; }
expect_status "insufficient USB space is reported before copying" 4 \
    backup_copy_generation_to_usb "${source_archive}" "${no_space_dir}"
expect_failure "insufficient USB space creates no final archive" test -e "${no_space_dir}/${source_archive##*/}"
expect_success "USB failure leaves the local generation intact" backup_verify_generation "${source_archive}"
unset -f backup_available_bytes sync

status_empty="${retention_test_dir}/status-empty"
mkdir -p -- "${status_empty}"
empty_output=$(backup_status_directory "${status_empty}")
expect_success "backup status reports no local backups" grep -Fq 'Generations:     0' <<<"${empty_output}"
status_output=$(backup_status_directory "${source_dir}")
expect_success "backup status reports local generations" grep -Fq 'Generations:     1' <<<"${status_output}"
expect_success "backup status reports the latest valid generation" grep -Fq 'Latest valid:    yes' <<<"${status_output}"

expect_success "installer creates the local backup directory" grep -Fq \
    'configure_local_backup_directory' "${REPO_DIR}/install.sh"
expect_success "installer assigns restrictive root docker permissions" grep -Fq \
    'install -d -o root -g docker -m 0750 "${LOCAL_BACKUP_DIR}"' "${REPO_DIR}/install.sh"
expect_success "timer service calls vwctl backup" grep -Fxq \
    'ExecStart=/usr/local/bin/vwctl backup' "${REPO_DIR}/systemd/vaultwarden-appliance-backup.service"
expect_success "manual command and timer therefore use one backup engine" grep -Fq \
    'bash "${BACKUP_HELPER}"' "${REPO_DIR}/vwctl"
expect_success "timer uses explicit daily 02:30 schedule" grep -Fxq \
    'OnCalendar=*-*-* 02:30:00' "${REPO_DIR}/systemd/vaultwarden-appliance-backup.timer"
expect_success "timer catches missed runs with Persistent true" grep -Fxq \
    'Persistent=true' "${REPO_DIR}/systemd/vaultwarden-appliance-backup.timer"
expect_success "installer enables and starts the timer" grep -Fq \
    'systemctl enable --now "${BACKUP_TIMER}"' "${REPO_DIR}/install.sh"
expect_success "scheduled path obtains the same vwctl global lock" bash -c \
    "grep -A6 -F 'command_backup()' '$REPO_DIR/vwctl' | grep -Fq require_operation_lock"
expect_success "backup status command does not obtain the mutation lock" bash -c \
    "! grep -A8 -F 'command_backup_status()' '$REPO_DIR/vwctl' | grep -Fq require_operation_lock"

backup_read_state() { return 2; }
expect_success "USB not configured keeps local-first run successful" backup_replicate_usb "${source_archive}"
backup_read_state() { BACKUP_UUID=6E7F-FD0E; return 0; }
backup_resolve_media() { return 2; }
expect_success "configured but absent USB keeps local-first run successful" backup_replicate_usb "${source_archive}"
usb_absent_output=$(backup_status_usb)
expect_success "backup status reports configured USB as absent without mounting" \
    grep -Fq 'Present:         no' <<<"${usb_absent_output}"
backup_resolve_media() { BACKUP_DEVICE=/dev/sda1; BACKUP_DISK=/dev/sda; return 0; }
backup_existing_mountpoint() { return 1; }
usb_present_output=$(backup_status_usb)
expect_success "backup status succeeds for a valid configured unmounted device" \
    grep -Fq 'Present:         yes' <<<"${usb_present_output}"
expect_success "read-only status does not mount a valid configured device" \
    grep -Fq 'safe status does not mount media' <<<"${usb_present_output}"

systemctl() {
    case "$1 $2" in
        'is-enabled vaultwarden-appliance-backup.timer') printf 'enabled\n' ;;
        'show vaultwarden-appliance-backup.service')
            [[ "$*" == *'ExecMainStartTimestamp'* ]] && printf 'Sun 2026-08-09 02:30:01 CEST\n' || printf 'success\n'
            ;;
        'show vaultwarden-appliance-backup.timer') printf 'Mon 2026-08-10 02:30:00 CEST\n' ;;
        *) return 1 ;;
    esac
}
timer_output=$(backup_status_timer)
expect_success "backup status reports an enabled automatic timer" grep -Fq 'Timer:           enabled' <<<"${timer_output}"
expect_success "backup status reports the fixed 02:30 schedule" grep -Fq 'daily at 02:30' <<<"${timer_output}"

mock_local_only_run() (
    backup_cleanup() { exit "$1"; }
    backup_require_environment() { return 0; }
    backup_source_bytes() { printf '1\n'; }
    backup_estimated_required_bytes() { printf '1\n'; }
    backup_available_bytes() { printf '2\n'; }
    backup_create_local_generation() { BACKUP_LOCAL_ARCHIVE=${source_archive}; }
    backup_apply_retention() { return 0; }
    backup_replicate_usb() { printf '[INFO] USB replication skipped for fixture.\n'; }
    BACKUP_WORK_DIR=""
    backup_main >/dev/null
)
expect_success "successful local-only backup completes without configured USB" mock_local_only_run

printf '1..%d\n' "${TESTS}"
(( FAILURES == 0 ))
