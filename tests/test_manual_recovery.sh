#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2317 # Sourced helper and indirect test commands are intentional.

set -o errexit
set -o nounset
set -o pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly TEST_DIR
REPO_DIR=$(cd -- "${TEST_DIR}/.." && pwd -P)
readonly REPO_DIR

. "${REPO_DIR}/libexec/backup"

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

temporary_dir=$(mktemp -d)
readonly temporary_dir
trap 'rm -rf -- "${temporary_dir}"' EXIT

sqlite_backend=""
if command -v sqlite3 >/dev/null 2>&1; then
    sqlite_backend=sqlite3
elif command -v python3 >/dev/null 2>&1; then
    sqlite_backend=python3
elif command -v python >/dev/null 2>&1; then
    sqlite_backend=python
fi
readonly sqlite_backend

create_sqlite_fixture() {
    local database=$1

    case "${sqlite_backend}" in
        sqlite3)
            sqlite3 "${database}" \
                'CREATE TABLE recovery_test (id INTEGER PRIMARY KEY, value TEXT); INSERT INTO recovery_test(value) VALUES ("manual recovery");'
            ;;
        python3|python)
            "${sqlite_backend}" - "${database}" <<'PYTHON'
import sqlite3
import sys

connection = sqlite3.connect(sys.argv[1])
connection.execute("CREATE TABLE recovery_test (id INTEGER PRIMARY KEY, value TEXT)")
connection.execute("INSERT INTO recovery_test(value) VALUES (?)", ("manual recovery",))
connection.commit()
connection.close()
PYTHON
            ;;
        *) return 1 ;;
    esac
}

sqlite_integrity_result() {
    local database=$1

    case "${sqlite_backend}" in
        sqlite3) sqlite3 "${database}" 'PRAGMA integrity_check;' ;;
        python3|python)
            "${sqlite_backend}" - "${database}" <<'PYTHON'
import sqlite3
import sys

connection = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True)
result = connection.execute("PRAGMA integrity_check").fetchone()[0]
connection.close()
print(result)
PYTHON
            ;;
        *) return 1 ;;
    esac
}

verify_checksum_independently() {
    local archive=$1

    (
        cd -- "$(dirname -- "${archive}")"
        sha256sum --check --strict -- "$(basename -- "${archive}").sha256"
    ) >/dev/null
}

write_checksum_quietly() {
    backup_write_checksum "$1" >/dev/null
}

list_archive_independently() {
    tar --list --verbose --gzip --file "$1" > "${temporary_dir}/archive.list"
}

work_dir="${temporary_dir}/work"
archive_dir="${temporary_dir}/backups"
data_dir="${temporary_dir}/data"
archive_root="${work_dir}/vaultwarden-appliance-backup"
snapshot="${archive_root}/vaultwarden/db.sqlite3"
ca_directory="${data_dir}/caddy/data/caddy/pki/authorities/local"
archive="${archive_dir}/vaultwarden-appliance-20260810-120000.tar.gz"
recovery_directory="${temporary_dir}/manual-recovery"
recovered_root="${recovery_directory}/vaultwarden-appliance-backup"

mkdir -p -- \
    "${archive_root}/vaultwarden" \
    "${archive_root}/appliance" \
    "${data_dir}/vaultwarden/attachments/item" \
    "${data_dir}/vaultwarden/sends/item" \
    "${data_dir}/vaultwarden/tmp" \
    "${ca_directory}" \
    "${data_dir}/caddy/config" \
    "${archive_dir}"

if [[ -z "${sqlite_backend}" ]]; then
    printf '1..0 # SKIP sqlite3 or Python sqlite3 support is required\n'
    exit 0
fi

backup_write_manifest "${archive_root}/manifest" \
    0.1.2 2026-08-10T12:00:00Z true \
    vaultwarden/server:latest 'Vaultwarden test' caddy:2 'Caddy test' aarch64
create_sqlite_fixture "${snapshot}"

printf 'Vaultwarden Appliance\n' > "${archive_root}/appliance/.vaultwarden-appliance"
printf '0.1.2\n' > "${archive_root}/appliance/.appliance-version"
printf 'compose base fixture\n' > "${archive_root}/appliance/docker-compose.yml"
printf 'compose caddy fixture\n' > "${archive_root}/appliance/docker-compose.override.yml"
printf 'compose vwctl fixture\n' > "${archive_root}/appliance/docker-compose.vwctl.yml"
printf 'caddy fixture\n' > "${archive_root}/appliance/Caddyfile"

printf 'attachment payload\n' > "${data_dir}/vaultwarden/attachments/item/file"
printf 'send payload\n' > "${data_dir}/vaultwarden/sends/item/file"
printf 'rsa private fixture\n' > "${data_dir}/vaultwarden/rsa_key.pem"
printf 'other persistent fixture\n' > "${data_dir}/vaultwarden/config.json"
printf 'live database\n' > "${data_dir}/vaultwarden/db.sqlite3"
printf 'live wal\n' > "${data_dir}/vaultwarden/db.sqlite3-wal"
printf 'live shm\n' > "${data_dir}/vaultwarden/db.sqlite3-shm"
printf 'old snapshot\n' > "${data_dir}/vaultwarden/db_20260809_120000.sqlite3"
printf 'temporary data\n' > "${data_dir}/vaultwarden/tmp/transient"
printf 'caddy config fixture\n' > "${data_dir}/caddy/config/autosave.json"

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "${ca_directory}/root.key" \
    -out "${ca_directory}/root.crt" \
    -subj '/CN=Vaultwarden Appliance Manual Recovery Test' \
    -days 1 >/dev/null 2>&1
cp -- "${ca_directory}/root.crt" "${ca_directory}/intermediate.crt"
cp -- "${ca_directory}/root.key" "${ca_directory}/intermediate.key"

expect_success "current backup helper creates the recovery archive" \
    backup_create_archive "${work_dir}" "${archive}" "${data_dir}"
expect_success "current backup helper writes the adjacent checksum" \
    write_checksum_quietly "${archive}"
expect_success "manual SHA-256 verification succeeds" \
    verify_checksum_independently "${archive}"
expect_success "archive contents can be listed independently" \
    list_archive_independently "${archive}"

mkdir -- "${recovery_directory}"
expect_success "archive extracts independently into an empty directory" \
    tar --extract --gzip --file "${archive}" \
        --directory "${recovery_directory}" \
        --no-same-owner --no-same-permissions --delay-directory-restore

integrity=$(sqlite_integrity_result "${recovered_root}/vaultwarden/db.sqlite3")
expect_success "SQLite snapshot is found at the documented path" \
    test -f "${recovered_root}/vaultwarden/db.sqlite3"
expect_success "independent SQLite integrity check returns ok" \
    test "${integrity}" = ok
expect_success "attachment content is recoverable" cmp \
    "${data_dir}/vaultwarden/attachments/item/file" \
    "${recovered_root}/vaultwarden/data/attachments/item/file"
expect_success "file-backed send content is recoverable" cmp \
    "${data_dir}/vaultwarden/sends/item/file" \
    "${recovered_root}/vaultwarden/data/sends/item/file"
expect_success "persistent RSA key file is recoverable" cmp \
    "${data_dir}/vaultwarden/rsa_key.pem" \
    "${recovered_root}/vaultwarden/data/rsa_key.pem"
expect_success "other persistent Vaultwarden state is recoverable" cmp \
    "${data_dir}/vaultwarden/config.json" \
    "${recovered_root}/vaultwarden/data/config.json"
expect_failure "live SQLite database is not copied as persistent data" test -e \
    "${recovered_root}/vaultwarden/data/db.sqlite3"
expect_failure "SQLite WAL is not copied" test -e \
    "${recovered_root}/vaultwarden/data/db.sqlite3-wal"
expect_failure "SQLite SHM is not copied" test -e \
    "${recovered_root}/vaultwarden/data/db.sqlite3-shm"
expect_failure "transient Vaultwarden tmp data is not copied" test -e \
    "${recovered_root}/vaultwarden/data/tmp"

recovered_ca="${recovered_root}/caddy/data/caddy/pki/authorities/local/root.crt"
recovered_key="${recovered_root}/caddy/data/caddy/pki/authorities/local/root.key"
recovered_intermediate_ca="${recovered_root}/caddy/data/caddy/pki/authorities/local/intermediate.crt"
recovered_intermediate_key="${recovered_root}/caddy/data/caddy/pki/authorities/local/intermediate.key"
openssl x509 -in "${recovered_ca}" -pubkey -noout > "${temporary_dir}/certificate.pub"
openssl pkey -in "${recovered_key}" -pubout > "${temporary_dir}/private-key.pub"
expect_success "Caddy root certificate is found at the documented path" \
    openssl x509 -in "${recovered_ca}" -noout
expect_success "Caddy root private key is found at the documented path" \
    openssl pkey -in "${recovered_key}" -check -noout
expect_success "recovered Caddy root certificate and private key match" cmp \
    "${temporary_dir}/certificate.pub" "${temporary_dir}/private-key.pub"
expect_success "Caddy intermediate certificate is recoverable" test -f "${recovered_intermediate_ca}"
expect_success "Caddy intermediate private key is recoverable" test -f "${recovered_intermediate_key}"

printf '1..%d\n' "${TESTS}"
(( FAILURES == 0 ))
