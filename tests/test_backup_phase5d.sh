#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2016 # Test doubles and literal source assertions are intentional.

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

pass() { TESTS=$((TESTS + 1)); printf 'ok %d - %s\n' "${TESTS}" "$1"; }
fail() { TESTS=$((TESTS + 1)); FAILURES=$((FAILURES + 1)); printf 'not ok %d - %s\n' "${TESTS}" "$1" >&2; }
expect_success() { local description=$1; shift; if "$@"; then pass "${description}"; else fail "${description}"; fi; }
expect_failure() { local description=$1; shift; if "$@"; then fail "${description}"; else pass "${description}"; fi; }
expect_equal() {
    local description=$1 expected=$2 actual=$3
    if [[ "${actual}" == "${expected}" ]]; then pass "${description}"; else fail "${description}"; fi
}
expect_status() {
    local description=$1 expected=$2 actual
    shift 2
    if "$@"; then actual=0; else actual=$?; fi
    expect_equal "${description}" "${expected}" "${actual}"
}

temporary_dir=$(mktemp -d)
readonly temporary_dir
trap 'rm -rf -- "${temporary_dir}"' EXIT
template_root="${temporary_dir}/template/vaultwarden-appliance-backup"
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
template_archive="${temporary_dir}/template.tar.gz"
command tar -czf "${template_archive}" -C "${temporary_dir}/template" vaultwarden-appliance-backup

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

valid_dir="${temporary_dir}/valid"
mkdir -p -- "${valid_dir}"
make_generation "${valid_dir}" 20260809-023000
valid_archive="${valid_dir}/vaultwarden-appliance-20260809-023000.tar.gz"
expect_success "complete archive and checksum form a valid generation" backup_verify_generation "${valid_archive}"
expect_success "local archive integrity is verified" backup_verify_archive "${valid_archive}" "${temporary_dir}/valid.list"
expect_success "local checksum verifies" bash -c "cd '$valid_dir' && sha256sum --check --strict '${valid_archive##*/}.sha256' >/dev/null"
rm -f -- "${valid_archive}.sha256"
expect_failure "archive without checksum is not a generation" backup_verify_generation "${valid_archive}"
make_generation "${valid_dir}" 20260809-023000
printf 'corrupt\n' >> "${valid_archive}"
expect_failure "checksum corruption invalidates a generation" backup_verify_generation "${valid_archive}"
rm -f -- "${valid_archive}" "${valid_archive}.sha256"

retention_dir="${temporary_dir}/local-retention"
mkdir -p -- "${retention_dir}"
for day in 01 02 03 04 05 06 07; do make_generation "${retention_dir}" "202608${day}-023000"; done
protected="${retention_dir}/vaultwarden-appliance-20260807-023000.tar.gz"
expect_success "local retention accepts one through seven generations" \
    backup_apply_retention "${retention_dir}" 7 "${protected}" "${temporary_dir}"
expect_equal "seven local generations remain at the limit" 7 "$(count_managed_archives "${retention_dir}")"
make_generation "${retention_dir}" 20260808-023000
protected="${retention_dir}/vaultwarden-appliance-20260808-023000.tar.gz"
expect_success "local retention removes generations above seven" \
    backup_apply_retention "${retention_dir}" 7 "${protected}" "${temporary_dir}"
expect_equal "local retention keeps exactly seven valid generations" 7 "$(count_managed_archives "${retention_dir}")"
expect_failure "oldest local archive was removed" test -e "${retention_dir}/vaultwarden-appliance-20260801-023000.tar.gz"
expect_success "newly created local generation is never deleted" test -f "${protected}"
printf 'unrelated\n' > "${retention_dir}/notes.txt"
expect_success "retention with unrelated local file succeeds" \
    backup_apply_retention "${retention_dir}" 7 "${protected}" "${temporary_dir}"
expect_success "unrelated local file is preserved" test -f "${retention_dir}/notes.txt"

outside_file="${temporary_dir}/outside-sensitive"
printf 'keep\n' > "${outside_file}"
symlink_archive="${retention_dir}/vaultwarden-appliance-20260809-023000.tar.gz"
if ln -s "${outside_file}" "${symlink_archive}" 2>/dev/null && [[ -L "${symlink_archive}" ]]; then
    expect_failure "managed-name symlink makes retention fail closed" \
        backup_apply_retention "${retention_dir}" 7 "${protected}" "${temporary_dir}"
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
    backup_apply_retention "${retention_dir}" 7 "${protected}" "${temporary_dir}"
expect_success "malformed file remains unrelated" test -f "${retention_dir}/vaultwarden-appliance-latest.tar.gz"
expect_equal "production retention contains no recursive removal" 0 \
    "$(grep -Ec 'rm[[:space:]]+-r(f|[[:space:]])[^\n]*BACKUP|rm[[:space:]]+-r(f|[[:space:]])[^\n]*backup' "${REPO_DIR}/libexec/backup" || true)"

usb_dir="${temporary_dir}/usb/backups"
mkdir -p -- "${usb_dir}" "${temporary_dir}/work"
source_dir="${temporary_dir}/source"
mkdir -p -- "${source_dir}"
make_generation "${source_dir}" 20260809-030000
source_archive="${source_dir}/vaultwarden-appliance-20260809-030000.tar.gz"
BACKUP_ACTIVE_MOUNTPOINT="${temporary_dir}/usb"
BACKUP_WORK_DIR="${temporary_dir}/work"
backup_available_bytes() { printf '999999999\n'; }
sync() { return 0; }
expect_success "USB present copies the completed local pair" \
    backup_copy_generation_to_usb "${source_archive}" "${usb_dir}"
usb_archive="${usb_dir}/${source_archive##*/}"
expect_success "USB copied checksum verifies" backup_verify_generation "${usb_archive}"
expect_success "USB copied archive remains readable" backup_verify_archive "${usb_archive}" "${temporary_dir}/usb.list"
expect_success "existing Phase 5C generation is recognized by the same filename and schema" \
    backup_verify_generation "${usb_archive}"
expect_success "repeat USB copy recognizes an identical completed generation" \
    backup_copy_generation_to_usb "${source_archive}" "${usb_dir}"

usb_retention="${temporary_dir}/usb-retention"
mkdir -p -- "${usb_retention}"
for day in $(seq -w 1 30); do make_generation "${usb_retention}" "202607${day}-023000"; done
usb_protected="${usb_retention}/vaultwarden-appliance-20260730-023000.tar.gz"
expect_success "USB retention accepts thirty generations" \
    backup_apply_retention "${usb_retention}" 30 "${usb_protected}" "${temporary_dir}"
expect_equal "USB retention leaves thirty generations at the limit" 30 "$(count_managed_archives "${usb_retention}")"
make_generation "${usb_retention}" 20260731-023000
usb_protected="${usb_retention}/vaultwarden-appliance-20260731-023000.tar.gz"
printf 'preserve\n' > "${usb_retention}/README-user.txt"
expect_success "USB retention removes generations above thirty" \
    backup_apply_retention "${usb_retention}" 30 "${usb_protected}" "${temporary_dir}"
expect_equal "USB retention keeps exactly thirty valid generations" 30 "$(count_managed_archives "${usb_retention}")"
expect_success "unrelated USB files are preserved" test -f "${usb_retention}/README-user.txt"
expect_success "new USB generation is retained" test -f "${usb_protected}"

no_space_dir="${temporary_dir}/usb-no-space"
mkdir -p -- "${no_space_dir}"
backup_available_bytes() { printf '0\n'; }
expect_status "insufficient USB space is reported before copying" 4 \
    backup_copy_generation_to_usb "${source_archive}" "${no_space_dir}"
expect_failure "insufficient USB space creates no final archive" test -e "${no_space_dir}/${source_archive##*/}"
expect_success "USB failure leaves the local generation intact" backup_verify_generation "${source_archive}"
unset -f backup_available_bytes sync

status_empty="${temporary_dir}/status-empty"
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
