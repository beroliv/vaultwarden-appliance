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
. "${REPO_DIR}/libexec/restore"

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
template="${temporary_dir}/template/${ARCHIVE_ROOT}"
mkdir -p -- \
    "${template}/vaultwarden/data/attachments" \
    "${template}/caddy/data/caddy/pki/authorities/local" \
    "${template}/caddy/config" \
    "${template}/appliance"
printf 'SQLite format 3\000fixture database\n' > "${template}/vaultwarden/db.sqlite3"
printf 'attachment\n' > "${template}/vaultwarden/data/attachments/item"
MSYS2_ARG_CONV_EXCL='/CN=' openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=Fixture Root' \
    -keyout "${template}/caddy/data/caddy/pki/authorities/local/root.key" \
    -out "${template}/caddy/data/caddy/pki/authorities/local/root.crt" >/dev/null 2>&1
printf 'config\n' > "${template}/caddy/config/autosave.json"
printf 'Vaultwarden Appliance\n' > "${template}/appliance/.vaultwarden-appliance"
printf '1.0.0\n' > "${template}/appliance/.appliance-version"
write_caddyfile_to "${template}/appliance/Caddyfile" vaultwarden.local
cat > "${template}/appliance/docker-compose.yml" <<'COMPOSE'
services:
  vaultwarden:
    image: vaultwarden/server:latest
    container_name: vaultwarden
    restart: unless-stopped
    environment:
      SIGNUPS_ALLOWED: "true"
    volumes:
      - ./data/vaultwarden:/data
    networks:
      - appliance
networks:
  appliance:
    name: vaultwarden-appliance
COMPOSE
cat > "${template}/appliance/docker-compose.override.yml" <<'COMPOSE'
services:
  caddy:
    image: caddy:2
    container_name: caddy
    restart: unless-stopped
    ports:
      - "443:443/tcp"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./data/caddy/data:/data
      - ./data/caddy/config:/config
    networks:
      - appliance
COMPOSE
write_vaultwarden_override_to \
    "${template}/appliance/docker-compose.vwctl.yml" vaultwarden.local true

write_manifest() {
    local destination=$1
    local schema=${2:-1}
    local version_value=${3:-1.0.0}

    cat > "${destination}" <<MANIFEST
backup_schema=${schema}
appliance_version=${version_value}
created_at_utc=2026-08-09T02:30:00Z
signup_allowed=true
vaultwarden_image=vaultwarden/server:latest
vaultwarden_version=1.34.3
caddy_image=caddy:2
caddy_version=2.10.0
source_architecture=aarch64
caddy_ca_included=yes
top_level_contents=manifest,vaultwarden,caddy,appliance
MANIFEST
}
write_manifest "${template}/manifest"
RESTORE_ACCESS_MODE=mdns
RESTORE_HOSTNAME=vaultwarden.local

make_generation() {
    local output_directory=$1
    local stamp=${2:-20260809-023000}
    local archive="${output_directory}/vaultwarden-appliance-${stamp}.tar.gz"

    mkdir -p -- "${output_directory}"
    tar -czf "${archive}" -C "${temporary_dir}/template" "${ARCHIVE_ROOT}"
    (cd -- "${output_directory}" && sha256sum -- "${archive##*/}") > "${archive}.sha256"
    printf '%s\n' "${archive}"
}

verify_extracted_generation() {
    local archive=$1
    local work=$2
    local listing="${work}/listing"
    local types="${work}/types"

    mkdir -p -- "${work}/extract"
    RESTORE_WORK_DIR=${work}
    restore_verify_archive_structure "${archive}" "${listing}" "${types}" &&
        restore_extract_archive "${archive}" "${work}/extract" &&
        restore_validate_extracted_backup "${work}/extract/${ARCHIVE_ROOT}"
}

valid_dir="${temporary_dir}/valid"
valid_archive=$(make_generation "${valid_dir}")
expect_success "schema-one archive and checksum are accepted" restore_generation_is_valid "${valid_archive}" "${temporary_dir}"
expect_success "valid backup extracts and passes semantic validation" \
    verify_extracted_generation "${valid_archive}" "${temporary_dir}/valid-work"
expect_equal "current hostname remains authoritative" vaultwarden.local "${RESTORE_HOSTNAME}"
expect_equal "manifest signup setting is retained" true "${RESTORE_SIGNUP_ALLOWED}"
valid_hash=$(restore_checksum_hash "${valid_archive}")
expect_equal "verified checksum is 64 characters" 64 "${#valid_hash}"

missing_checksum="${temporary_dir}/missing/vaultwarden-appliance-20260809-023001.tar.gz"
mkdir -p -- "${missing_checksum%/*}"
cp -- "${valid_archive}" "${missing_checksum}"
expect_failure "archive without checksum is rejected" restore_generation_is_valid "${missing_checksum}" "${temporary_dir}"
printf '%064d  %s\n' 0 "${missing_checksum##*/}" > "${missing_checksum}.sha256"
expect_failure "wrong checksum is rejected" restore_generation_is_valid "${missing_checksum}" "${temporary_dir}"
invalid_name="${temporary_dir}/missing/backup-latest.tar.gz"
cp -- "${valid_archive}" "${invalid_name}"
cp -- "${valid_archive}.sha256" "${invalid_name}.sha256"
expect_failure "non-appliance filename is rejected" restore_checksum_hash "${invalid_name}"
malformed_archive="${temporary_dir}/missing/vaultwarden-appliance-20260809-023099.tar.gz"
printf 'not a gzip archive\n' > "${malformed_archive}"
(cd -- "${malformed_archive%/*}" && sha256sum -- "${malformed_archive##*/}") > "${malformed_archive}.sha256"
expect_failure "malformed gzip/tar archive is rejected" \
    restore_generation_is_valid "${malformed_archive}" "${temporary_dir}"

for missing_member in manifest vaultwarden/db.sqlite3 \
    caddy/data/caddy/pki/authorities/local/root.crt \
    caddy/data/caddy/pki/authorities/local/root.key; do
    fixture_name=${missing_member//\//-}
    missing_root="${temporary_dir}/missing-${fixture_name}/tree"
    mkdir -p -- "${missing_root}"
    cp -a -- "${temporary_dir}/template/${ARCHIVE_ROOT}" "${missing_root}/${ARCHIVE_ROOT}"
    rm -f -- "${missing_root}/${ARCHIVE_ROOT}/${missing_member}"
    missing_member_dir="${temporary_dir}/missing-${fixture_name}/generation"
    mkdir -p -- "${missing_member_dir}"
    missing_member_archive="${missing_member_dir}/vaultwarden-appliance-20260809-023014.tar.gz"
    tar -czf "${missing_member_archive}" -C "${missing_root}" "${ARCHIVE_ROOT}"
    (cd -- "${missing_member_dir}" && sha256sum -- "${missing_member_archive##*/}") > \
        "${missing_member_archive}.sha256"
    expect_failure "missing required ${missing_member} is rejected" \
        restore_generation_is_valid "${missing_member_archive}" "${temporary_dir}"
done

unsupported_dir="${temporary_dir}/unsupported"
write_manifest "${template}/manifest" 2
unsupported_archive=$(make_generation "${unsupported_dir}" 20260809-023002)
expect_success "unsupported schema remains structurally discoverable" \
    restore_generation_is_valid "${unsupported_archive}" "${temporary_dir}"
expect_failure "unsupported backup schema is rejected before confirmation" \
    verify_extracted_generation "${unsupported_archive}" "${temporary_dir}/unsupported-work"
write_manifest "${template}/manifest"

duplicate_dir="${temporary_dir}/duplicate"
mkdir -p -- "${duplicate_dir}"
duplicate_archive="${duplicate_dir}/vaultwarden-appliance-20260809-023003.tar.gz"
tar -czf "${duplicate_archive}" -C "${temporary_dir}/template" \
    "${ARCHIVE_ROOT}" "${ARCHIVE_ROOT}"
(cd -- "${duplicate_dir}" && sha256sum -- "${duplicate_archive##*/}") > "${duplicate_archive}.sha256"
expect_failure "duplicate archive members are rejected" \
    restore_generation_is_valid "${duplicate_archive}" "${temporary_dir}"

attack_source="${temporary_dir}/attack-source"
mkdir -p -- "${attack_source}"
printf 'escape\n' > "${attack_source}/entry"
for attack in traversal absolute; do
    attack_dir="${temporary_dir}/${attack}"
    mkdir -p -- "${attack_dir}"
    attack_archive="${attack_dir}/vaultwarden-appliance-20260809-023004.tar.gz"
    if [[ "${attack}" == traversal ]]; then
        transform='s,^entry,../escape,'
    else
        transform='s,^entry,/absolute-escape,'
    fi
    tar -czf "${attack_archive}" --transform="${transform}" -C "${attack_source}" entry
    (cd -- "${attack_dir}" && sha256sum -- "${attack_archive##*/}") > "${attack_archive}.sha256"
    expect_failure "${attack} archive path is rejected" \
        restore_generation_is_valid "${attack_archive}" "${temporary_dir}"
done

special_root="${temporary_dir}/special"
mkdir -p -- "${special_root}"
printf 'target\n' > "${special_root}/target"
if ln -s target "${special_root}/link" 2>/dev/null; then
    special_dir="${temporary_dir}/special-symlink"
    mkdir -p -- "${special_dir}"
    special_archive="${special_dir}/vaultwarden-appliance-20260809-023005.tar.gz"
    tar -czf "${special_archive}" --transform="s,^link,${ARCHIVE_ROOT}/unsafe-link," \
        -C "${special_root}" link
    (cd -- "${special_dir}" && sha256sum -- "${special_archive##*/}") > "${special_archive}.sha256"
    expect_failure "symlink archive member is rejected" \
        restore_generation_is_valid "${special_archive}" "${temporary_dir}"
else
    pass "symlink-member regression requires native symlink support"
fi
if ln "${special_root}/target" "${special_root}/hardlink" 2>/dev/null; then
    hardlink_dir="${temporary_dir}/special-hardlink"
    mkdir -p -- "${hardlink_dir}"
    hardlink_archive="${hardlink_dir}/vaultwarden-appliance-20260809-023006.tar.gz"
    tar -czf "${hardlink_archive}" --transform="s,^,${ARCHIVE_ROOT}/," \
        -C "${special_root}" target hardlink
    (cd -- "${hardlink_dir}" && sha256sum -- "${hardlink_archive##*/}") > "${hardlink_archive}.sha256"
    expect_failure "hardlink archive member is rejected" \
        restore_generation_is_valid "${hardlink_archive}" "${temporary_dir}"
else
    pass "hardlink-member regression requires native hardlink support"
fi
if mkfifo "${special_root}/pipe" 2>/dev/null; then
    fifo_dir="${temporary_dir}/special-fifo"
    mkdir -p -- "${fifo_dir}"
    fifo_archive="${fifo_dir}/vaultwarden-appliance-20260809-023007.tar.gz"
    tar -czf "${fifo_archive}" --transform="s,^pipe,${ARCHIVE_ROOT}/unsafe-pipe," \
        -C "${special_root}" pipe
    (cd -- "${fifo_dir}" && sha256sum -- "${fifo_archive##*/}") > "${fifo_archive}.sha256"
    expect_failure "FIFO archive member is rejected" \
        restore_generation_is_valid "${fifo_archive}" "${temporary_dir}"
else
    pass "FIFO-member regression requires native FIFO support"
fi

invalid_db_dir="${temporary_dir}/invalid-db"
printf 'not sqlite\n' > "${template}/vaultwarden/db.sqlite3"
invalid_db_archive=$(make_generation "${invalid_db_dir}" 20260809-023008)
expect_failure "non-SQLite database snapshot is rejected" \
    verify_extracted_generation "${invalid_db_archive}" "${temporary_dir}/invalid-db-work"
printf 'SQLite format 3\000fixture database\n' > "${template}/vaultwarden/db.sqlite3"

mismatch_key="${temporary_dir}/mismatch.key"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "${mismatch_key}" >/dev/null 2>&1
cp -- "${template}/caddy/data/caddy/pki/authorities/local/root.key" "${temporary_dir}/original.key"
cp -- "${mismatch_key}" "${template}/caddy/data/caddy/pki/authorities/local/root.key"
mismatch_archive=$(make_generation "${temporary_dir}/mismatch" 20260809-023009)
expect_failure "mismatched Caddy root certificate and private key are rejected" \
    verify_extracted_generation "${mismatch_archive}" "${temporary_dir}/mismatch-work"
cp -- "${temporary_dir}/original.key" "${template}/caddy/data/caddy/pki/authorities/local/root.key"

cp -- "${template}/manifest" "${temporary_dir}/manifest.original"
printf 'vaultwarden_version=$(touch %s)\n' "${temporary_dir}/manifest-pwned" >> "${template}/manifest"
injection_archive=$(make_generation "${temporary_dir}/injection" 20260809-023011)
expect_failure "duplicate or injection-like manifest content is rejected" \
    verify_extracted_generation "${injection_archive}" "${temporary_dir}/injection-work"
expect_failure "manifest content is never executed" test -e "${temporary_dir}/manifest-pwned"
cp -- "${temporary_dir}/manifest.original" "${template}/manifest"

cp -- "${template}/appliance/docker-compose.yml" "${temporary_dir}/base.original"
printf '\n    ports:\n      - "8080:80"\n' >> "${template}/appliance/docker-compose.yml"
published_archive=$(make_generation "${temporary_dir}/published" 20260809-023012)
expect_failure "backup claiming direct Vaultwarden host exposure is rejected" \
    verify_extracted_generation "${published_archive}" "${temporary_dir}/published-work"
cp -- "${temporary_dir}/base.original" "${template}/appliance/docker-compose.yml"

expect_success "exact restore confirmation is accepted" bash -c \
    '. "$1"; restore_confirm <<<"RESTORE VAULTWARDEN"' _ "${REPO_DIR}/libexec/restore"
expect_failure "lowercase restore confirmation is rejected" bash -c \
    '. "$1"; restore_confirm <<<"restore vaultwarden"' _ "${REPO_DIR}/libexec/restore"
expect_failure "confirmation with extra text is rejected" bash -c \
    '. "$1"; restore_confirm <<<"RESTORE VAULTWARDEN NOW"' _ "${REPO_DIR}/libexec/restore"

mkdir -p -- /tmp/restore-test-mount
findmnt() { printf '/tmp/restore-test-mount rw,nodev,nosuid,noexec\n'; }
expect_failure "existing read-write USB mount is rejected" restore_existing_mountpoint /dev/sdb1
findmnt() { printf '/tmp/restore-test-mount ro,nodev,nosuid,noexec\n'; }
expect_equal "safe existing read-only USB mount is reusable" /tmp/restore-test-mount \
    "$(restore_existing_mountpoint /dev/sdb1)"
unset -f findmnt
rmdir /tmp/restore-test-mount

source_copy="${temporary_dir}/source-copy/vaultwarden-appliance-20260809-023013.tar.gz"
mkdir -p -- "${source_copy%/*}"
cp -- "${valid_archive}" "${source_copy}"
(cd -- "${source_copy%/*}" && sha256sum -- "${source_copy##*/}") > "${source_copy}.sha256"
RESTORE_SOURCE_ARCHIVE=${source_copy}
RESTORE_SOURCE_KIND=local
RESTORE_SOURCE_HASH=$(restore_checksum_hash "${source_copy}")
expect_success "unchanged source passes post-confirmation revalidation" restore_revalidate_source
printf 'changed\n' >> "${source_copy}"
expect_failure "source changed after confirmation is rejected" restore_revalidate_source

empty_local="${temporary_dir}/empty-local"
mkdir -p -- "${empty_local}"
RESTORE_GENERATION_SOURCE=()
RESTORE_GENERATION_PATH=()
RESTORE_GENERATION_NAME=()
expect_success "empty safe local source produces no selectable generations" \
    restore_add_generations_from_directory local "${empty_local}"
expect_equal "no source leaves the generation list empty" 0 "${#RESTORE_GENERATION_PATH[@]}"
RESTORE_GENERATION_SOURCE=()
RESTORE_GENERATION_PATH=()
RESTORE_GENERATION_NAME=()
expect_success "valid local generation is discovered" \
    restore_add_generations_from_directory Local "${valid_dir}"
expect_equal "local discovery records one generation" 1 "${#RESTORE_GENERATION_PATH[@]}"
expect_equal "local discovery identifies its source" Local "${RESTORE_GENERATION_SOURCE[0]}"

RESTORE_TOPOLOGY=$(cat <<'TOPOLOGY'
/dev/mmcblk0||disk|179:0|32000000000|0|1
/dev/mmcblk0p2|/dev/mmcblk0|part|179:2|31000000000|0|0
/dev/sdb||disk|8:16|64000000000|0|1
/dev/sdb1|/dev/sdb|part|8:17|63900000000|0|0
/dev/zram0||zram|252:0|2000000000|0|0
TOPOLOGY
)
RESTORE_PROTECTED_DISKS='/dev/mmcblk0|/'
storage_lsblk_property() {
    case "$1:$2" in
        /dev/mmcblk0p2:UUID) printf 'SYSTEM-UUID\n' ;;
        /dev/mmcblk0p2:FSTYPE) printf 'exfat\n' ;;
        /dev/mmcblk0p2:LABEL) printf 'VWBACKUP\n' ;;
        /dev/sdb1:UUID) printf 'USB-UUID\n' ;;
        /dev/sdb1:FSTYPE) printf 'exfat\n' ;;
        /dev/sdb1:LABEL) printf 'VWBACKUP\n' ;;
        /dev/zram0:UUID) printf 'ZRAM-UUID\n' ;;
        /dev/zram0:FSTYPE) printf 'exfat\n' ;;
        /dev/zram0:LABEL) printf 'VWBACKUP\n' ;;
        *) return 1 ;;
    esac
}
expect_success "configured USB UUID resolves through existing safety logic" \
    storage_lookup_configured_backup "${RESTORE_TOPOLOGY}" "${RESTORE_PROTECTED_DISKS}" \
        USB-UUID VWBACKUP
expect_success "unconfigured safe VWBACKUP medium is discovered" restore_discover_unconfigured_media
expect_equal "unconfigured discovery records the physical USB partition" /dev/sdb1 "${RESTORE_USB_DEVICE}"
expect_failure "system-disk VWBACKUP filesystem is never safe" \
    restore_safe_media_tuple /dev/mmcblk0p2 SYSTEM-UUID
expect_failure "virtual zram VWBACKUP filesystem is never safe" \
    restore_safe_media_tuple /dev/zram0 ZRAM-UUID

RESTORE_TOPOLOGY+=$'\n/dev/sdc||disk|8:32|128000000000|0|1\n/dev/sdc1|/dev/sdc|part|8:33|127000000000|0|0'
storage_lsblk_property() {
    case "$1:$2" in
        /dev/mmcblk0p2:UUID) printf 'SYSTEM-UUID\n' ;;
        /dev/mmcblk0p2:FSTYPE) printf 'exfat\n' ;;
        /dev/mmcblk0p2:LABEL) printf 'VWBACKUP\n' ;;
        /dev/sdb1:UUID) printf 'USB-UUID\n' ;;
        /dev/sdb1:FSTYPE) printf 'exfat\n' ;;
        /dev/sdb1:LABEL) printf 'VWBACKUP\n' ;;
        /dev/sdc1:UUID) printf 'SECOND-UUID\n' ;;
        /dev/sdc1:FSTYPE) printf 'exfat\n' ;;
        /dev/sdc1:LABEL) printf 'VWBACKUP\n' ;;
        *) return 1 ;;
    esac
}
expect_success "multiple safe VWBACKUP media require and accept a numbered choice" \
    restore_discover_unconfigured_media <<<"2"
expect_equal "multiple-media selection records the explicitly selected UUID" \
    SECOND-UUID "${RESTORE_USB_UUID}"
unset -f storage_lsblk_property

cleanup_log="${temporary_dir}/cleanup.log"
test_appliance_mount_cleanup() (
    restore_resume_timer() { return 0; }
    umount() { printf '%s\n' "${2:-$1}" > "${cleanup_log}"; }
    RESTORE_MOUNTED_BY_APPLIANCE=1
    RESTORE_USB_MOUNT=/safe/appliance-mount
    RESTORE_WORK_DIR=""
    RESTORE_MOUNTPOINT_CREATED=0
    restore_cleanup 0
)
expect_success "appliance-created restore mount is unmounted during cleanup" test_appliance_mount_cleanup
expect_equal "cleanup unmounts only the recorded mountpoint" /safe/appliance-mount "$(<"${cleanup_log}")"
rm -f -- "${cleanup_log}"
test_user_mount_cleanup() (
    restore_resume_timer() { return 0; }
    umount() { printf 'unexpected\n' > "${cleanup_log}"; }
    RESTORE_MOUNTED_BY_APPLIANCE=0
    RESTORE_USB_MOUNT=/safe/user-mount
    RESTORE_WORK_DIR=""
    RESTORE_MOUNTPOINT_CREATED=0
    restore_cleanup 0
)
expect_success "cleanup succeeds for a reused user mount" test_user_mount_cleanup
expect_failure "reused user mount is never unmounted" test -e "${cleanup_log}"

timer_log="${temporary_dir}/timer.log"
systemctl() {
    case "$1" in
        is-enabled|is-active) return 0 ;;
        *) printf '%s\n' "$*" >> "${timer_log}" ;;
    esac
}
RESTORE_TIMER_ENABLED=0
RESTORE_TIMER_ACTIVE=0
RESTORE_TIMER_CHANGED=0
expect_success "restore records and suspends enabled active backup timer" restore_record_and_stop_timer
expect_success "restore resumes the previous timer state" restore_resume_timer
expect_success "timer suspension stops timer and one-shot service" grep -Fq \
    'stop vaultwarden-appliance-backup.timer vaultwarden-appliance-backup.service' "${timer_log}"
expect_success "timer preservation re-enables the prior enabled timer" grep -Fq \
    'enable vaultwarden-appliance-backup.timer' "${timer_log}"
expect_success "timer preservation restarts the prior active timer" grep -Fq \
    'start vaultwarden-appliance-backup.timer' "${timer_log}"
unset -f systemctl

nonroot_restore_is_refused() {
    local output
    local status=0

    output=$(bash "${REPO_DIR}/vwctl" restore 2>&1) || status=$?
    (( status != 0 )) &&
        grep -Fxq 'This operation requires root privileges.' <<<"${output}" &&
        grep -Fxq 'Run:' <<<"${output}" &&
        grep -Fxq 'sudo vwctl restore' <<<"${output}"
}
if (( EUID != 0 )); then
    expect_success "direct restore command prints the exact root instruction" nonroot_restore_is_refused
else
    pass "direct non-root restore process test requires a non-root test runner"
fi

network_immediately_available() (
    local sleep_marker="${temporary_dir}/unexpected-network-sleep"

    SECONDS=0
    command_exists() { return 0; }
    detect_ipv4_address() { printf '192.168.0.192\n'; }
    container_is_running() { return 0; }
    systemctl() { return 0; }
    mdns_ready_file_matches() { return 0; }
    mdns_resolved_ipv4s() { printf '192.168.0.192\n'; }
    restore_https_alive_is_ready() { return 0; }
    sleep() { printf 'called\n' > "${sleep_marker}"; }
    restore_wait_for_network_health 5 1 && [[ ! -e "${sleep_marker}" ]]
)
expect_success "immediately healthy network incurs no retry delay" network_immediately_available

network_mdns_delayed() (
    local mdns_attempts=0

    SECONDS=0
    command_exists() { return 0; }
    detect_ipv4_address() { printf '192.168.0.192\n'; }
    container_is_running() { return 0; }
    systemctl() {
        if [[ "${3:-}" == "${MDNS_SERVICE}" ]]; then
            mdns_attempts=$((mdns_attempts + 1))
            (( mdns_attempts >= 3 ))
            return
        fi
        return 0
    }
    mdns_ready_file_matches() { return 0; }
    mdns_resolved_ipv4s() { printf '192.168.0.192\n'; }
    restore_https_alive_is_ready() { return 0; }
    sleep() { SECONDS=$((SECONDS + $1)); }
    restore_wait_for_network_health 6 1 && (( mdns_attempts == 3 ))
)
expect_success "mDNS becoming healthy after several polls succeeds" network_mdns_delayed

network_https_delayed() (
    local https_attempts=0

    SECONDS=0
    command_exists() { return 0; }
    detect_ipv4_address() { printf '192.168.0.192\n'; }
    container_is_running() { return 0; }
    systemctl() { return 0; }
    mdns_ready_file_matches() { return 0; }
    mdns_resolved_ipv4s() { printf '192.168.0.192\n'; }
    restore_https_alive_is_ready() {
        https_attempts=$((https_attempts + 1))
        (( https_attempts >= 3 ))
    }
    sleep() { SECONDS=$((SECONDS + $1)); }
    restore_wait_for_network_health 6 1 && (( https_attempts == 3 ))
)
expect_success "HTTPS becoming healthy after several polls succeeds" network_https_delayed

network_mdns_and_https_delayed() (
    local https_attempts=0
    local mdns_attempts=0

    SECONDS=0
    command_exists() { return 0; }
    detect_ipv4_address() { printf '192.168.0.192\n'; }
    container_is_running() { return 0; }
    systemctl() {
        if [[ "${3:-}" == "${MDNS_SERVICE}" ]]; then
            mdns_attempts=$((mdns_attempts + 1))
            (( mdns_attempts >= 3 ))
            return
        fi
        return 0
    }
    mdns_ready_file_matches() { return 0; }
    mdns_resolved_ipv4s() { printf '192.168.0.192\n'; }
    restore_https_alive_is_ready() {
        https_attempts=$((https_attempts + 1))
        (( https_attempts >= 3 ))
    }
    sleep() { SECONDS=$((SECONDS + $1)); }
    restore_wait_for_network_health 8 1 &&
        (( mdns_attempts >= 5 && https_attempts == 3 ))
)
expect_success "combined delayed mDNS and HTTPS health succeeds" network_mdns_and_https_delayed

network_external_dns() (
    RESTORE_ACCESS_MODE=dns
    RESTORE_HOSTNAME=vault.lan
    command_exists() { return 0; }
    detect_ipv4_address() { printf '192.168.0.192\n'; }
    container_is_running() { return 0; }
    dns_resolved_ipv4s() { printf '192.168.0.192\n'; }
    systemctl() { return 1; }
    mdns_ready_file_matches() { return 1; }
    mdns_resolved_ipv4s() { return 1; }
    restore_https_alive_is_ready() { return 0; }
    restore_network_conditions_are_ready 192.168.0.192
)
expect_success "external DNS health does not require mDNS or Avahi" network_external_dns

dns_restore_skips_mdns_state() (
    local detection_marker="${temporary_dir}/unexpected-dns-mdns-state"

    RESTORE_ACCESS_MODE=dns
    detect_ipv4_address() { printf 'called\n' > "${detection_marker}"; }
    restore_write_mdns_state && [[ ! -e "${detection_marker}" ]]
)
expect_success "external DNS restore does not recreate mDNS state" dns_restore_skips_mdns_state

external_dns_reconciliation() (
    RESTORE_WORK_DIR="${temporary_dir}/dns-reconciliation"
    RESTORE_HOSTNAME=vault.lan
    RESTORE_SIGNUP_ALLOWED=true
    mkdir -p -- "${RESTORE_WORK_DIR}"
    docker() { return 0; }
    restore_validate_reconciliation &&
        grep -Fxq 'https://vault.lan {' "${RESTORE_WORK_DIR}/reconciled-Caddyfile" &&
        grep -Fxq '      DOMAIN: "https://vault.lan"' "${RESTORE_WORK_DIR}/reconciled-compose.yml"
)
expect_success "restore reconciles Caddy and DOMAIN from current external DNS access" \
    external_dns_reconciliation

network_never_available() (
    SECONDS=0
    detect_ipv4_address() { printf '192.168.0.192\n'; }
    container_is_running() { return 0; }
    systemctl() {
        [[ "${3:-}" != "${MDNS_SERVICE}" ]]
    }
    sleep() { SECONDS=$((SECONDS + $1)); }
    restore_wait_for_network_health 3 1
)
expect_failure "network-health retry is bounded and reports unhealthy" network_never_available

successful_apply_verifies_data_before_network_health() (
    RESTORE_WORK_DIR=/run/vaultwarden-appliance/restore-work.fixture
    restore_stop_services() { return 0; }
    restore_replace_data_directory() { return 0; }
    restore_install_database_snapshot() { return 0; }
    restore_write_configuration() { return 0; }
    restore_compose() { return 0; }
    restore_write_mdns_state() { return 0; }
    restore_export_root_ca() { return 0; }
    systemctl() { return 0; }
    restore_verify_data_recovery() { printf 'DATA\n'; }
    restore_wait_for_network_health() { printf 'NETWORK\n'; }
    restore_write_backup_state_after_success() { return 0; }
    restore_resume_timer() { return 0; }
    restore_apply
)
expect_equal "data recovery is verified before advisory network health" \
    $'DATA\nNETWORK' "$(successful_apply_verifies_data_before_network_health)"

simulated_data_verification_failure() (
    RESTORE_WORK_DIR=/run/vaultwarden-appliance/restore-work.fixture
    restore_stop_services() { return 0; }
    restore_replace_data_directory() { return 0; }
    restore_install_database_snapshot() { return 0; }
    restore_write_configuration() { return 0; }
    restore_compose() { return 0; }
    restore_write_mdns_state() { return 0; }
    restore_export_root_ca() { return 0; }
    systemctl() { return 0; }
    restore_verify_data_recovery() { return 1; }
    restore_wait_for_network_health() { return 0; }
    restore_die() { exit 1; }
    restore_apply
)
expect_failure "post-restore data or CA verification failure remains fatal" \
    simulated_data_verification_failure

simulated_network_failure_is_advisory() (
    RESTORE_WORK_DIR=/run/vaultwarden-appliance/restore-work.fixture
    restore_stop_services() { return 0; }
    restore_replace_data_directory() { return 0; }
    restore_install_database_snapshot() { return 0; }
    restore_write_configuration() { return 0; }
    restore_compose() { return 0; }
    restore_write_mdns_state() { return 0; }
    restore_export_root_ca() { return 0; }
    systemctl() { return 0; }
    restore_verify_data_recovery() { return 0; }
    restore_wait_for_network_health() { return 1; }
    restore_write_backup_state_after_success() { return 0; }
    restore_resume_timer() { return 0; }
    restore_die() { exit 1; }
    restore_apply && (( RESTORE_NETWORK_HEALTHY == 0 ))
)
expect_success "network failure does not invalidate verified data recovery" \
    simulated_network_failure_is_advisory

network_independent_dns_restore() (
    local resolution_case=$1
    local result="${temporary_dir}/dns-restore-${resolution_case}"
    local output

    mkdir -p -- "${result}/vaultwarden" "${result}/caddy" "${result}/certs" \
        "${result}/work"
    printf 'mode=dns\nhostname=vault1.lan\n' > "${result}/.access"
    cp -- "${result}/.access" "${result}/access-before"
    RESTORE_ACCESS_MODE=dns
    RESTORE_HOSTNAME=vault1.lan
    RESTORE_SIGNUP_ALLOWED=true
    RESTORE_WORK_DIR="${result}/work"
    RESTORE_NETWORK_HEALTHY=0
    command_exists() { return 0; }
    restore_stop_services() { return 0; }
    restore_replace_data_directory() {
        case "$1" in
            vaultwarden)
                cp -a -- "${template}/vaultwarden/data/." "${result}/vaultwarden/"
                ;;
            caddy)
                cp -a -- "${template}/caddy/." "${result}/caddy/"
                ;;
        esac
    }
    restore_install_database_snapshot() {
        cp -- "${template}/vaultwarden/db.sqlite3" "${result}/vaultwarden/db.sqlite3"
    }
    restore_write_configuration() {
        write_caddyfile_to "${result}/Caddyfile" "${RESTORE_HOSTNAME}" &&
            write_vaultwarden_override_to \
                "${result}/docker-compose.vwctl.yml" "${RESTORE_HOSTNAME}" "${RESTORE_SIGNUP_ALLOWED}"
    }
    restore_compose() { return 0; }
    restore_export_root_ca() {
        cp -- "${result}/caddy/${CADDY_ROOT_CA_RELATIVE}" "${result}/certs/caddy-root-ca.crt"
    }
    restore_verify_data_recovery() {
        restore_sqlite_snapshot_is_valid "${result}/vaultwarden/db.sqlite3" &&
            test -f "${result}/vaultwarden/attachments/item" &&
            restore_caddy_ca_pair_is_valid \
                "${result}/caddy/${CADDY_ROOT_CA_RELATIVE}" \
                "${result}/caddy/${CADDY_ROOT_KEY_RELATIVE}" &&
            cmp -s "${result}/caddy/${CADDY_ROOT_CA_RELATIVE}" \
                "${result}/certs/caddy-root-ca.crt" &&
            cmp -s "${result}/.access" "${result}/access-before" &&
            grep -Fxq 'https://vault1.lan {' "${result}/Caddyfile" &&
            grep -Fxq '      DOMAIN: "https://vault1.lan"' \
                "${result}/docker-compose.vwctl.yml"
    }
    restore_write_backup_state_after_success() { return 0; }
    restore_resume_timer() { return 0; }
    detect_ipv4_address() { printf '192.168.0.192\n'; }
    container_is_running() { return 0; }
    vaultwarden_domain_matches() { return 0; }
    restore_https_alive_is_ready() { return 0; }
    dns_resolved_ipv4s() {
        case "${resolution_case}" in
            unresolved) return 1 ;;
            unconfigured) return 0 ;;
            old-ip) printf '192.168.0.10\n' ;;
        esac
    }
    restore_wait_for_network_health() {
        restore_network_conditions_are_ready 192.168.0.192
    }

    restore_apply || return 1
    output=$(restore_report_completion)
    (( RESTORE_NETWORK_HEALTHY == 0 )) &&
        grep -Fq 'Restore completed successfully.' <<<"${output}" &&
        grep -Fq 'Vaultwarden data: restored' <<<"${output}" &&
        grep -Fq 'Caddy root CA: restored' <<<"${output}" &&
        grep -Fq 'Access configuration: preserved' <<<"${output}" &&
        grep -Fq 'WARNING: Network access is not currently healthy.' <<<"${output}" &&
        grep -Fq 'vault1.lan -> 192.168.0.192' <<<"${output}" &&
        grep -Fq 'sudo vwctl health' <<<"${output}"
)
expect_success "restore succeeds when external DNS lookup fails" \
    network_independent_dns_restore unresolved
expect_success "restore succeeds before external DNS is configured" \
    network_independent_dns_restore unconfigured
expect_success "restore succeeds after an IP change while DNS still points to the old IP" \
    network_independent_dns_restore old-ip

mdns_network_warning_is_actionable() (
    local output

    RESTORE_ACCESS_MODE=mdns
    RESTORE_HOSTNAME=vaultwarden.local
    RESTORE_NETWORK_HEALTHY=0
    RESTORE_NETWORK_LAST_HTTPS_ERROR=""
    detect_ipv4_address() { printf '192.168.0.192\n'; }
    output=$(restore_report_completion)
    grep -Fq 'WARNING: Network access is not currently healthy.' <<<"${output}" &&
        grep -Fq 'The appliance mDNS publisher is not ready' <<<"${output}" &&
        grep -Fq 'vaultwarden.local -> 192.168.0.192' <<<"${output}" &&
        grep -Fq 'systemctl status vaultwarden-appliance-mdns.service' <<<"${output}" &&
        grep -Fq 'sudo vwctl health' <<<"${output}"
)
expect_success "unhealthy mDNS produces an actionable advisory after restore" \
    mdns_network_warning_is_actionable

expect_success "vwctl exposes the root-only restore command" grep -Fq 'sudo vwctl restore' "${REPO_DIR}/vwctl"
expect_success "vwctl restore uses the global operation lock" bash -c \
    "grep -A7 -F 'command_restore()' '$REPO_DIR/vwctl' | grep -Fq require_operation_lock"
expect_success "installer installs the restore helper" grep -Fq \
    'install -m 0755 "${RESTORE_SOURCE}" "${RESTORE_TARGET}"' "${REPO_DIR}/install.sh"
expect_success "bootstrap requires the restore helper" grep -Fq \
    'libexec/backup libexec/restore libexec/usb-setup' "${REPO_DIR}/bootstrap.sh"
expect_success "uninstaller removes only the recognized restore helper" grep -Fq \
    '"${RESTORE_FILE}|# Vaultwarden Appliance restore"' "${REPO_DIR}/remove.sh"
expect_success "restore never runs source or eval on backup state" bash -c \
    "! grep -Eq '^[[:space:]]*(source|eval)[[:space:]]' '$REPO_DIR/libexec/restore'"
expect_success "restore contains no disk formatting commands" bash -c \
    "! grep -Eq 'mkfs|sfdisk|wipefs|parted' '$REPO_DIR/libexec/restore'"
expect_success "restore does not prune Docker resources" bash -c \
    "! grep -Eq 'docker[[:space:]]+(system|volume|image)[[:space:]]+prune' '$REPO_DIR/libexec/restore'"
expect_success "restore mounts appliance USB media read-only with hardened flags" grep -Fq \
    'mount -o ro,nodev,nosuid,noexec' "${REPO_DIR}/libexec/restore"
expect_success "restore unmounts only an appliance-mounted medium" grep -Fq \
    'RESTORE_MOUNTED_BY_APPLIANCE == 1' "${REPO_DIR}/libexec/restore"
expect_success "restore stages under the root-only runtime directory" grep -Fq \
    'mktemp -d "${RUNTIME_DIR}/restore-work.XXXXXXXX"' "${REPO_DIR}/libexec/restore"
expect_success "local backup directory is outside replaced persistent data" test \
    "${LOCAL_BACKUP_DIR}" = /opt/vaultwarden/backups
expect_success "Vaultwarden is stopped only after timer and mDNS handling" bash -c '
    file=$1
    timer=$(grep -n "restore_record_and_stop_timer" "$file" | tail -1 | cut -d: -f1)
    mdns=$(grep -n "systemctl stop.*MDNS_SERVICE" "$file" | cut -d: -f1)
    vault=$(grep -n "restore_compose stop vaultwarden" "$file" | cut -d: -f1)
    test "$timer" -lt "$mdns" && test "$mdns" -lt "$vault"
' _ "${REPO_DIR}/libexec/restore"
expect_success "backup-media adoption occurs only after data and CA verification" bash -c '
    file=$1
    verify=$(grep -n "restore_verify_data_recovery" "$file" | tail -1 | cut -d: -f1)
    adopt=$(grep -n "restore_write_backup_state_after_success" "$file" | tail -1 | cut -d: -f1)
    test "$verify" -lt "$adopt"
' _ "${REPO_DIR}/libexec/restore"
expect_success "staging and confirmation precede every destructive restore step" bash -c '
    file=$1
    stage=$(grep -n "restore_stage_and_verify_selection" "$file" | tail -1 | cut -d: -f1)
    confirm=$(grep -n "restore_confirm" "$file" | tail -1 | cut -d: -f1)
    apply=$(grep -n "restore_apply" "$file" | tail -1 | cut -d: -f1)
    test "$stage" -lt "$confirm" && test "$confirm" -lt "$apply"
' _ "${REPO_DIR}/libexec/restore"
expect_success "selected source archive is never a deletion target" bash -c \
    "! grep -Eq 'rm[^#\n]*RESTORE_SOURCE_ARCHIVE' '$REPO_DIR/libexec/restore'"
expect_success "restore never invokes package removal or installation" bash -c \
    "! grep -Eq 'apt(-get)?|dpkg|remove package|purge' '$REPO_DIR/libexec/restore'"
expect_success "restore never writes, syncs, retains, or deletes through the USB mount variable" bash -c \
    "! grep -Eq '(rm|mv|install|sync)[^#\n]*RESTORE_USB_MOUNT' '$REPO_DIR/libexec/restore'"
expect_success "restored database snapshot becomes live db.sqlite3" grep -Fq \
    'local destination="${VAULTWARDEN_DATA_DIR}/db.sqlite3"' "${REPO_DIR}/libexec/restore"
expect_success "backed management executables are never copied from staging" bash -c \
    "! grep -Eq '(/usr/local/bin|/usr/local/libexec).*ARCHIVE_ROOT|ARCHIVE_ROOT.*(/usr/local/bin|/usr/local/libexec)' '$REPO_DIR/libexec/restore'"
expect_success "current code regenerates Caddy hostname configuration" grep -Fq \
    'write_caddyfile_to "${caddy_candidate}" "${RESTORE_HOSTNAME}"' "${REPO_DIR}/libexec/restore"
expect_success "current code reconciles Vaultwarden DOMAIN and signup" grep -Fq \
    'write_vaultwarden_override_to "${override_candidate}"' "${REPO_DIR}/libexec/restore"
expect_failure "restore never writes the authoritative access configuration" grep -Eq \
    '(^|[[:space:]])(mv|install|cp)[^#]*ACCESS_FILE' "${REPO_DIR}/libexec/restore"
expect_success "restored Caddy root is re-exported byte-for-byte" grep -Fq \
    'cmp -s "${root_ca}" "${EXPORTED_ROOT_CA}"' "${REPO_DIR}/libexec/restore"
expect_success "restore preflight contains no hostname-resolution gate" bash -c \
    "! grep -Eq 'restore_hostname_is_available|current access hostname is unavailable' '$REPO_DIR/libexec/restore'"
expect_success "restore environment preflight requires no network-health commands" bash -c '
    file=$1
    section=$(awk "/^restore_require_environment\\(\\)/,/^restore_prepare_runtime_root\\(\\)/" "$file")
    ! grep -Eq "avahi-resolve-host-name|getent|curl|timeout" <<<"$section"
' _ "${REPO_DIR}/libexec/restore"
expect_success "restore never makes strict vwctl health authoritative" bash -c '
    ! grep -Fq "bash \"\${vwctl_command}\" health" "$1" &&
        ! grep -Fq "restore_verify_result" "$1"
' _ "${REPO_DIR}/libexec/restore"
expect_success "vwctl health remains strict for incorrect external DNS" bash -c '
    file=$1
    grep -Fq "dns_resolution_matches \"\${current_ip}\" \"\${resolved}\"" "$file" &&
        grep -Fq "health_fail \"External DNS\"" "$file"
' _ "${REPO_DIR}/vwctl"
expect_success "restore never configures external DNS or host resolution" bash -c \
    "! grep -Eq '/etc/(hosts|resolv\\.conf)|resolvectl|nmcli|networkctl|dhcpcd|hostnamectl' '$REPO_DIR/libexec/restore'"
expect_success "network checks occur only after verified data recovery" bash -c '
    file=$1
    verify=$(grep -n "restore_verify_data_recovery" "$file" | tail -1 | cut -d: -f1)
    network=$(grep -n "restore_wait_for_network_health" "$file" | tail -1 | cut -d: -f1)
    test "$verify" -lt "$network"
' _ "${REPO_DIR}/libexec/restore"

printf '1..%d\n' "${TESTS}"
(( FAILURES == 0 ))
