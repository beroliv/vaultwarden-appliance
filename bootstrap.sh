#!/usr/bin/env bash
# Vaultwarden Appliance source bootstrap

set -o errexit
set -o nounset
set -o pipefail

umask 022

readonly REPOSITORY_URL="https://github.com/beroliv/vaultwarden-appliance.git"
readonly REPOSITORY_BRANCH="main"
readonly SOURCE_DIR="/opt/vaultwarden-appliance-src"

STAGING_DIR=""
STAGING_PARENT=""

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    [[ -n "${STAGING_DIR}" ]] || return 0
    if [[ -n "${STAGING_PARENT}" && "${STAGING_DIR%/*}" == "${STAGING_PARENT}" &&
          "${STAGING_DIR##*/}" == .vaultwarden-appliance-src.* &&
          -d "${STAGING_DIR}" && ! -L "${STAGING_DIR}" ]]; then
        rm -rf --one-file-system -- "${STAGING_DIR}"
        return
    fi
    printf 'Warning: Refusing to clean unexpected bootstrap staging path: %s\n' \
        "${STAGING_DIR}" >&2
}

trap cleanup EXIT

require_root() {
    bootstrap_is_root || die "This bootstrap must run as root. Use: curl -fsSL <URL> | sudo bash"
}

bootstrap_is_root() {
    (( EUID == 0 ))
}

check_supported_system() {
    local id_like=""
    local machine

    [[ "$(uname -s)" == "Linux" ]] ||
        die "A Debian-based Linux system is required."
    [[ -r /etc/os-release ]] ||
        die "Cannot identify this system because /etc/os-release is unavailable."

    # Supplied by the operating system and intentionally matches install.sh.
    # shellcheck disable=SC1091
    . /etc/os-release
    id_like=${ID_LIKE:-}
    if [[ "${ID:-unknown}" != "debian" && "${ID:-unknown}" != "raspbian" &&
          " ${id_like} " != *" debian "* ]]; then
        die "Unsupported distribution '${ID:-unknown}'. Debian, Raspberry Pi OS, or a Debian-derived system is required."
    fi

    machine=$(uname -m)
    case "${machine}" in
        aarch64|arm64|x86_64|amd64) ;;
        *) die "Unsupported CPU architecture '${machine}'. Supported architectures are ARM64 and x86-64." ;;
    esac
}

install_packages() {
    (( $# > 0 )) || return 0
    command -v apt-get >/dev/null 2>&1 ||
        die "apt-get is required to install missing bootstrap packages: $*."
    printf 'Installing missing bootstrap package(s): %s\n' "$*"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

ensure_git() {
    local -a packages=()

    if ! command -v git >/dev/null 2>&1; then
        packages+=(git)
        [[ -r /etc/ssl/certs/ca-certificates.crt ]] || packages+=(ca-certificates)
    fi
    install_packages "${packages[@]}"
    command -v git >/dev/null 2>&1 || die "Git installation did not provide the git command."
}

check_network_access() {
    local repository_url=$1
    local repository_branch=$2

    printf 'Checking HTTPS access to the Vaultwarden Appliance repository...\n'
    if GIT_TERMINAL_PROMPT=0 git ls-remote --exit-code \
        "${repository_url}" "refs/heads/${repository_branch}" >/dev/null; then
        return 0
    fi
    if [[ ! -r /etc/ssl/certs/ca-certificates.crt ]]; then
        printf 'The standard CA bundle is missing; installing it before one retry.\n'
        install_packages ca-certificates
        GIT_TERMINAL_PROMPT=0 git ls-remote --exit-code \
            "${repository_url}" "refs/heads/${repository_branch}" >/dev/null && return 0
    fi
    die "Unable to reach the '${repository_branch}' branch at ${repository_url}."
}

path_owner() {
    stat -c '%u:%g' "$1" 2>/dev/null
}

path_permissions() {
    stat -c '%a' "$1" 2>/dev/null
}

canonical_path() {
    local resolved

    resolved=$(readlink -f -- "$1") || return 1
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m -- "${resolved}"
    else
        printf '%s\n' "${resolved}"
    fi
}

repository_url_matches() {
    local actual=$1
    local expected=$2

    [[ "${actual}" == "${expected}" ]] && return 0
    [[ "${actual}" != *://* && "${expected}" != *://* ]] || return 1
    [[ "$(canonical_path "${actual}")" == "$(canonical_path "${expected}")" ]]
}

validate_checkout_ownership() {
    local source_dir=$1
    local permissions
    local unsafe_path

    [[ "$(path_owner "${source_dir}")" == "0:0" ]] ||
        die "${source_dir} must be owned by root:root."
    permissions=$(path_permissions "${source_dir}") ||
        die "Cannot inspect permissions on ${source_dir}."
    [[ "${permissions}" =~ ^[0-7]{3,4}$ ]] ||
        die "Cannot interpret permissions on ${source_dir}."
    (( (8#${permissions} & 8#002) == 0 )) ||
        die "${source_dir} must not be world-writable."

    unsafe_path=$(find "${source_dir}" -xdev \( ! -user root -o ! -group root \) -print -quit)
    [[ -z "${unsafe_path}" ]] ||
        die "The source checkout contains a path not owned by root:root: ${unsafe_path}"
    unsafe_path=$(find "${source_dir}" -xdev -perm -0002 -print -quit)
    [[ -z "${unsafe_path}" ]] ||
        die "The source checkout contains a world-writable path: ${unsafe_path}"
}

validate_existing_checkout() {
    local source_dir=$1
    local repository_url=$2
    local repository_branch=$3
    local branch
    local origin
    local top_level

    [[ -d "${source_dir}" && ! -L "${source_dir}" ]] ||
        die "${source_dir} exists but is not a safe source directory."
    [[ -d "${source_dir}/.git" && ! -L "${source_dir}/.git" ]] ||
        die "${source_dir} exists but is not a standalone Git checkout owned by this bootstrap."
    validate_checkout_ownership "${source_dir}"

    top_level=$(git -C "${source_dir}" rev-parse --show-toplevel 2>/dev/null) ||
        die "${source_dir} is not a valid Git repository."
    [[ "$(canonical_path "${top_level}")" == "$(canonical_path "${source_dir}")" ]] ||
        die "${source_dir} is not the root of its Git repository."

    origin=$(git -C "${source_dir}" remote get-url origin 2>/dev/null) ||
        die "${source_dir} has no readable origin remote."
    repository_url_matches "${origin}" "${repository_url}" ||
        die "${source_dir} has an unexpected origin: ${origin}"

    branch=$(git -C "${source_dir}" symbolic-ref --quiet --short HEAD 2>/dev/null) ||
        die "${source_dir} is not on a branch. Expected '${repository_branch}'."
    [[ "${branch}" == "${repository_branch}" ]] ||
        die "${source_dir} is on branch '${branch}', not '${repository_branch}'."
    [[ -z "$(git -C "${source_dir}" status --porcelain=v1 --untracked-files=normal)" ]] ||
        die "${source_dir} contains local changes. Commit, move, or remove them before rerunning the bootstrap."

}

clone_checkout() {
    local source_dir=$1
    local repository_url=$2
    local repository_branch=$3
    local source_parent

    [[ ! -e "${source_dir}" && ! -L "${source_dir}" ]] ||
        die "Refusing to replace existing path ${source_dir}."
    source_parent=$(dirname -- "${source_dir}")
    [[ -d "${source_parent}" && ! -L "${source_parent}" ]] ||
        die "${source_parent} is unavailable or unsafe."

    STAGING_PARENT=${source_parent}
    STAGING_DIR=$(mktemp -d "${source_parent}/.vaultwarden-appliance-src.XXXXXXXX") ||
        die "Unable to create a temporary checkout directory below ${source_parent}."
    git clone --branch "${repository_branch}" --single-branch -- \
        "${repository_url}" "${STAGING_DIR}/repository" ||
        die "Git failed to clone ${repository_url}."
    mv -T -- "${STAGING_DIR}/repository" "${source_dir}" ||
        die "Unable to install the completed checkout at ${source_dir}."
    rmdir -- "${STAGING_DIR}" ||
        die "Unable to remove the empty checkout staging directory."
    STAGING_DIR=""
    STAGING_PARENT=""
    validate_checkout_ownership "${source_dir}"
}

update_checkout() {
    local source_dir=$1
    local repository_url=$2
    local repository_branch=$3

    validate_existing_checkout "${source_dir}" "${repository_url}" "${repository_branch}"
    printf 'Updating clean source checkout with fast-forward-only semantics...\n'
    GIT_TERMINAL_PROMPT=0 git -C "${source_dir}" pull --ff-only \
        origin "${repository_branch}" ||
        die "The source checkout could not be updated with fast-forward-only semantics."
    validate_existing_checkout "${source_dir}" "${repository_url}" "${repository_branch}"
}

validate_project_files() {
    local source_dir=$1
    local path
    local -a required_directories=(lib libexec systemd)
    local -a required_files=(
        install.sh remove.sh vwctl mdns-publisher VERSION
        lib/common.sh lib/network.sh lib/docker.sh lib/caddy.sh lib/mdns.sh lib/storage.sh
        libexec/backup libexec/usb-setup
        systemd/vaultwarden-appliance-backup.service
        systemd/vaultwarden-appliance-backup.timer
    )

    for path in "${required_directories[@]}"; do
        [[ -d "${source_dir}/${path}" && ! -L "${source_dir}/${path}" ]] ||
            die "Required project directory is missing or unsafe: ${path}"
    done
    for path in "${required_files[@]}"; do
        [[ -f "${source_dir}/${path}" && ! -L "${source_dir}/${path}" ]] ||
            die "Required project file is missing or unsafe: ${path}"
    done
}

run_installer() {
    local source_dir=$1

    printf 'Starting the full Vaultwarden Appliance installer...\n'
    cd -- "${source_dir}"
    bash ./install.sh
}

main() {
    (( $# == 0 )) || die "This bootstrap does not accept arguments."
    require_root
    check_supported_system
    ensure_git

    if [[ -e "${SOURCE_DIR}" || -L "${SOURCE_DIR}" ]]; then
        validate_existing_checkout "${SOURCE_DIR}" "${REPOSITORY_URL}" "${REPOSITORY_BRANCH}"
    fi
    check_network_access "${REPOSITORY_URL}" "${REPOSITORY_BRANCH}"

    if [[ -e "${SOURCE_DIR}" || -L "${SOURCE_DIR}" ]]; then
        update_checkout "${SOURCE_DIR}" "${REPOSITORY_URL}" "${REPOSITORY_BRANCH}"
    else
        printf 'Cloning Vaultwarden Appliance source to %s...\n' "${SOURCE_DIR}"
        clone_checkout "${SOURCE_DIR}" "${REPOSITORY_URL}" "${REPOSITORY_BRANCH}"
    fi

    validate_project_files "${SOURCE_DIR}"
    run_installer "${SOURCE_DIR}"
}

if (( ${#BASH_SOURCE[@]} <= 1 )); then
    main "$@"
fi
