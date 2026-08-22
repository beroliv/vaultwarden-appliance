#!/usr/bin/env bash
# shellcheck disable=SC1090 # The test intentionally sources the installer.

set -o errexit
set -o nounset
set -o pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly TEST_DIR
REPO_DIR=$(cd -- "${TEST_DIR}/.." && pwd -P)
readonly REPO_DIR

. "${REPO_DIR}/install.sh"

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

make_exact_preseed() {
    local installation_dir=$1
    local pki="${installation_dir}/data/caddy/data/caddy/pki/authorities/local"

    mkdir -p -- "${pki}"
    printf 'root certificate\n' > "${pki}/root.crt"
    printf 'root private key\n' > "${pki}/root.key"
    printf 'intermediate certificate\n' > "${pki}/intermediate.crt"
    printf 'intermediate private key\n' > "${pki}/intermediate.key"
}

temporary_dir=$(mktemp -d)
readonly temporary_dir
trap 'rm -rf -- "${temporary_dir}"' EXIT

nonexistent="${temporary_dir}/nonexistent"
expect_equal "nonexistent installation path is fresh" fresh \
    "$(classify_installation_path "${nonexistent}")"

empty="${temporary_dir}/empty"
mkdir -- "${empty}"
expect_equal "empty existing installation directory remains unknown" unknown \
    "$(classify_installation_path "${empty}")"

exact="${temporary_dir}/exact"
make_exact_preseed "${exact}"
expect_equal "exact four-file Caddy PKI preseed is accepted" preseed \
    "$(classify_installation_path "${exact}")"

incomplete="${temporary_dir}/incomplete"
make_exact_preseed "${incomplete}"
rm -- "${incomplete}/data/caddy/data/caddy/pki/authorities/local/intermediate.key"
expect_equal "incomplete Caddy PKI preseed is rejected" unknown \
    "$(classify_installation_path "${incomplete}")"

unexpected="${temporary_dir}/unexpected"
make_exact_preseed "${unexpected}"
printf 'unexpected\n' > "${unexpected}/data/caddy/data/caddy/pki/authorities/local/extra.pem"
expect_equal "Caddy PKI preseed with an unexpected file is rejected" unknown \
    "$(classify_installation_path "${unexpected}")"

unexpected_directory="${temporary_dir}/unexpected-directory"
make_exact_preseed "${unexpected_directory}"
mkdir -- "${unexpected_directory}/data/caddy/config"
expect_equal "Caddy PKI preseed with an unexpected directory is rejected" unknown \
    "$(classify_installation_path "${unexpected_directory}")"

symlinked="${temporary_dir}/symlinked"
make_exact_preseed "${symlinked}"
if ln -s -- "${symlinked}/data/caddy/data/caddy/pki/authorities/local/root.crt" \
    "${temporary_dir}/root-link" 2>/dev/null && [[ -L "${temporary_dir}/root-link" ]]; then
    rm -- "${symlinked}/data/caddy/data/caddy/pki/authorities/local/root.crt"
    mv -- "${temporary_dir}/root-link" \
        "${symlinked}/data/caddy/data/caddy/pki/authorities/local/root.crt"
    expect_equal "symlinked Caddy PKI preseed file is rejected" unknown \
        "$(classify_installation_path "${symlinked}")"
else
    pass "symlinked preseed rejection is covered on hosts with symlink support"
fi

symlinked_path="${temporary_dir}/symlinked-path"
mkdir -p -- "${symlinked_path}/data/caddy/data/caddy/pki/authorities"
if ln -s -- "${exact}/data/caddy/data/caddy/pki/authorities/local" \
    "${symlinked_path}/data/caddy/data/caddy/pki/authorities/local" 2>/dev/null &&
   [[ -L "${symlinked_path}/data/caddy/data/caddy/pki/authorities/local" ]]; then
    expect_equal "symlinked Caddy PKI preseed directory is rejected" unknown \
        "$(classify_installation_path "${symlinked_path}")"
else
    pass "symlinked preseed path rejection is covered on hosts with symlink support"
fi

marked="${temporary_dir}/marked"
mkdir -- "${marked}"
printf 'Vaultwarden Appliance\n' > "${marked}/.vaultwarden-appliance"
expect_equal "existing marked appliance is accepted normally" existing \
    "$(classify_installation_path "${marked}")"

printf '1..%d\n' "${TESTS}"
(( FAILURES == 0 ))
