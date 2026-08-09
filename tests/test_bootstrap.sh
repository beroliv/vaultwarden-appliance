#!/usr/bin/env bash
# shellcheck disable=SC2218,SC2317 # The late git test double and indirect doubles are intentional.

set -o errexit
set -o nounset
set -o pipefail

export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=core.autocrlf
export GIT_CONFIG_VALUE_0=false

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly TEST_DIR
REPO_DIR=$(cd -- "${TEST_DIR}/.." && pwd -P)
readonly REPO_DIR

# shellcheck disable=SC1090
. "${REPO_DIR}/bootstrap.sh"

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

create_project_tree() {
    local root=$1
    local path
    local -a directories=(lib libexec systemd)
    local -a files=(
        install.sh remove.sh vwctl mdns-publisher VERSION
        lib/common.sh lib/network.sh lib/docker.sh lib/caddy.sh lib/mdns.sh lib/storage.sh
        libexec/backup libexec/usb-setup
        systemd/vaultwarden-appliance-backup.service
        systemd/vaultwarden-appliance-backup.timer
    )

    mkdir -p -- "${root}"
    for path in "${directories[@]}"; do
        mkdir -p -- "${root}/${path}"
    done
    for path in "${files[@]}"; do
        printf 'fixture\n' > "${root}/${path}"
    done
    printf 'exit 0\n' > "${root}/install.sh"
}

bootstrap_is_root() { return 1; }
non_root_case() { (require_root) >/dev/null 2>&1; }
expect_failure "bootstrap refuses non-root execution" non_root_case
bootstrap_is_root() { return 0; }

complete_tree="${temporary_dir}/complete"
create_project_tree "${complete_tree}"
expect_success "complete repository tree is accepted" validate_project_files "${complete_tree}"
rm -f -- "${complete_tree}/install.sh"
missing_installer_case() { (validate_project_files "${complete_tree}") >/dev/null 2>&1; }
expect_failure "missing install.sh is refused" missing_installer_case
printf 'exit 0\n' > "${complete_tree}/install.sh"
rm -f -- "${complete_tree}/lib/storage.sh"
incomplete_tree_case() { (validate_project_files "${complete_tree}") >/dev/null 2>&1; }
expect_failure "incomplete repository tree is refused" incomplete_tree_case

seed="${temporary_dir}/seed"
remote="${temporary_dir}/origin.git"
fresh_checkout="${temporary_dir}/source"
create_project_tree "${seed}"
git -C "${seed}" init --initial-branch=main >/dev/null
git -C "${seed}" config user.name 'Bootstrap Test'
git -C "${seed}" config user.email 'bootstrap-test@example.invalid'
git -C "${seed}" add .
git -C "${seed}" commit -m initial >/dev/null
git clone --bare -- "${seed}" "${remote}" >/dev/null 2>&1
git -C "${seed}" remote add origin "${remote}"

# Temp fixtures are not root-owned on every test platform; ownership itself is
# enforced by production code and the remaining repository identity is real.
validate_checkout_ownership() { return 0; }

expect_success "fresh clone path obtains the complete repository" \
    clone_checkout "${fresh_checkout}" "${remote}" main
expect_success "fresh clone contains required project files" \
    validate_project_files "${fresh_checkout}"
expect_success "existing correct clean repository is accepted" \
    validate_existing_checkout "${fresh_checkout}" "${remote}" main

printf 'updated\n' > "${seed}/VERSION"
git -C "${seed}" add VERSION
git -C "${seed}" commit -m update >/dev/null
git -C "${seed}" push origin main >/dev/null 2>&1
expect_success "existing clean repository updates fast-forward-only" \
    update_checkout "${fresh_checkout}" "${remote}" main
expect_equal "fast-forward update installed the new revision" updated \
    "$(<"${fresh_checkout}/VERSION")"

printf 'local change\n' > "${fresh_checkout}/local-change"
dirty_checkout_case() {
    (validate_existing_checkout "${fresh_checkout}" "${remote}" main) >/dev/null 2>&1
}
expect_failure "dirty repository aborts" dirty_checkout_case
rm -f -- "${fresh_checkout}/local-change"

wrong_directory="${temporary_dir}/wrong"
mkdir -p -- "${wrong_directory}"
wrong_directory_case() {
    (validate_existing_checkout "${wrong_directory}" "${remote}" main) >/dev/null 2>&1
}
expect_failure "wrong non-project directory aborts" wrong_directory_case

wrong_origin_case() {
    (validate_existing_checkout "${fresh_checkout}" 'https://example.invalid/foreign.git' main) >/dev/null 2>&1
}
expect_failure "repository with unexpected origin is refused" wrong_origin_case

git -C "${fresh_checkout}" switch -c other >/dev/null
wrong_branch_case() {
    (validate_existing_checkout "${fresh_checkout}" "${remote}" main) >/dev/null 2>&1
}
expect_failure "repository on unexpected branch is refused" wrong_branch_case
git -C "${fresh_checkout}" switch main >/dev/null

failed_clone="${temporary_dir}/failed-clone"
git() { return 42; }
clone_failure_case() {
    (clone_checkout "${failed_clone}" 'https://example.invalid/failure.git' main) >/dev/null 2>&1
}
expect_failure "clone failure aborts" clone_failure_case
expect_failure "failed clone is never installed as source" test -e "${failed_clone}"
unset -f git

failed_installer="${temporary_dir}/failed-installer"
mkdir -p -- "${failed_installer}"
printf 'exit 23\n' > "${failed_installer}/install.sh"
set +o errexit
(run_installer "${failed_installer}") >/dev/null 2>&1
installer_status=$?
set -o errexit
expect_equal "install.sh failure status propagates" 23 "${installer_status}"

expect_failure "bootstrap never uses git reset --hard" \
    grep -Fq 'git reset --hard' "${REPO_DIR}/bootstrap.sh"
expect_failure "bootstrap never invokes vwctl update" \
    grep -Eq '(^|[[:space:]])(sudo[[:space:]]+)?vwctl[[:space:]]+update' "${REPO_DIR}/bootstrap.sh"
expect_success "production checkout path is fixed below /opt" \
    grep -Fq 'readonly SOURCE_DIR="/opt/vaultwarden-appliance-src"' "${REPO_DIR}/bootstrap.sh"
expect_success "production repository uses exact HTTPS origin" \
    grep -Fq 'readonly REPOSITORY_URL="https://github.com/beroliv/vaultwarden-appliance.git"' \
    "${REPO_DIR}/bootstrap.sh"
expect_success "production update uses fast-forward-only semantics" \
    grep -Fq 'pull --ff-only' "${REPO_DIR}/bootstrap.sh"
# shellcheck disable=SC2016 # The assertion intentionally searches for literal shell source.
expect_failure "bootstrap does not rely on dollar-zero as a local path" \
    grep -Fq '$0' "${REPO_DIR}/bootstrap.sh"
expect_failure "bootstrap never downloads individual project files with curl" \
    grep -Eq '^[[:space:]]*curl[[:space:]]' "${REPO_DIR}/bootstrap.sh"
# shellcheck disable=SC2016 # The assertion intentionally searches for literal shell source.
expect_equal "only one bounded staging cleanup is implemented" 1 \
    "$(grep -Fc 'rm -rf --one-file-system -- "${STAGING_DIR}"' "${REPO_DIR}/bootstrap.sh")"

printf '1..%d\n' "${TESTS}"
(( FAILURES == 0 ))
