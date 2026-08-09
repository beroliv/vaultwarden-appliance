#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly SCRIPT_DIR
readonly LIB_SOURCE_DIR="${SCRIPT_DIR}/lib"
readonly LIB_TARGET_DIR="/usr/local/lib/vaultwarden-appliance"

for library in common network docker caddy mdns storage; do
    library_path="${LIB_SOURCE_DIR}/${library}.sh"
    if [[ ! -f "${library_path}" || -L "${library_path}" ]]; then
        printf '[FAIL] Required installer library is missing or unsafe: %s\n' "${library_path}" >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    . "${library_path}"
done
unset library library_path

readonly INSTALL_DIR="/opt/vaultwarden"
readonly APPLIANCE_MARKER="${INSTALL_DIR}/.vaultwarden-appliance"
readonly BASE_COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
readonly VWCTL_COMPOSE_FILE="${INSTALL_DIR}/docker-compose.vwctl.yml"
readonly CADDY_ACCESS_FILE="${INSTALL_DIR}/.caddy-access"
readonly CADDYFILE="${INSTALL_DIR}/Caddyfile"
readonly CADDY_COMPOSE_FILE="${INSTALL_DIR}/docker-compose.override.yml"
readonly CADDY_DATA_DIR="${INSTALL_DIR}/data/caddy/data"
readonly CADDY_CONFIG_DIR="${INSTALL_DIR}/data/caddy/config"
readonly CADDY_ROOT_CA="${CADDY_DATA_DIR}/caddy/pki/authorities/local/root.crt"
readonly EXPORTED_ROOT_CA="${INSTALL_DIR}/certs/caddy-root-ca.crt"
readonly VWCTL_SOURCE="${SCRIPT_DIR}/vwctl"
readonly VWCTL_TARGET="/usr/local/bin/vwctl"
readonly USB_SETUP_SOURCE="${SCRIPT_DIR}/libexec/usb-setup"
readonly USB_SETUP_TARGET="/usr/local/libexec/vaultwarden-appliance-usb-setup"
readonly BACKUP_SOURCE="${SCRIPT_DIR}/libexec/backup"
readonly BACKUP_TARGET="/usr/local/libexec/vaultwarden-appliance-backup"
readonly VERSION_SOURCE="${SCRIPT_DIR}/VERSION"
readonly VERSION_TARGET="${INSTALL_DIR}/.appliance-version"
readonly OPERATION_LOCK="/run/lock/vaultwarden-appliance.lock"
readonly DEFAULT_MDNS_HOSTNAME="vaultwarden.local"
readonly MDNS_ENV_FILE="/etc/default/vaultwarden-appliance-mdns"
readonly MDNS_SERVICE_FILE="/etc/systemd/system/vaultwarden-appliance-mdns.service"
readonly MDNS_SERVICE="vaultwarden-appliance-mdns.service"
readonly MDNS_WRAPPER_SOURCE="${SCRIPT_DIR}/mdns-publisher"
readonly MDNS_WRAPPER_FILE="/usr/local/libexec/vaultwarden-appliance-mdns"
readonly MDNS_READY_FILE="/run/vaultwarden-appliance-mdns/ready"
readonly MIN_DISK_SPACE_MB=2048

if [[ ! -f "${USB_SETUP_SOURCE}" || -L "${USB_SETUP_SOURCE}" ]] ||
   ! grep -Fxq '# Vaultwarden Appliance USB setup' "${USB_SETUP_SOURCE}"; then
    printf '[FAIL] Required USB setup helper is missing or unsafe: %s\n' \
        "${USB_SETUP_SOURCE}" >&2
    exit 1
fi
if [[ ! -f "${BACKUP_SOURCE}" || -L "${BACKUP_SOURCE}" ]] ||
   ! grep -Fxq '# Vaultwarden Appliance manual backup' "${BACKUP_SOURCE}"; then
    printf '[FAIL] Required backup helper is missing or unsafe: %s\n' \
        "${BACKUP_SOURCE}" >&2
    exit 1
fi

ERRORS=0
WARNINGS=0
OS_NAME="unknown"
OS_ID="unknown"
OS_VERSION="unknown"
ARCH="unknown"
IPV4_ADDRESS="not detected"
DOCKER_READY=0
DOCKER_CODENAME=""
DOCKER_USER=""
DOCKER_GROUP_CHANGED=0
APPLIANCE_STATE="fresh"
CADDY_STATE="absent"
CADDY_ACCESS_ADDRESS=""

info() {
    printf '  [INFO] %s\n' "$*"
}

ok() {
    printf '  [ OK ] %s\n' "$*"
}

warn() {
    printf '  [WARN] %s\n' "$*" >&2
    WARNINGS=$((WARNINGS + 1))
}

error() {
    printf '  [FAIL] %s\n' "$*" >&2
    ERRORS=$((ERRORS + 1))
}

section() {
    printf '\n%s\n' "$*"
}

check_operating_system() {
    local id_like=""

    section "Operating system"

    if [[ "$(uname -s)" != "Linux" ]]; then
        error "Unsupported operating system: $(uname -s). A Debian-based Linux system is required."
        return
    fi

    if [[ ! -r /etc/os-release ]]; then
        error "Cannot identify this Linux distribution because /etc/os-release is unavailable."
        return
    fi

    # This file is supplied by the operating system and contains shell-style values.
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_NAME=${PRETTY_NAME:-${NAME:-unknown}}
    OS_ID=${ID:-unknown}
    OS_VERSION=${VERSION_ID:-unknown}
    DOCKER_CODENAME=${VERSION_CODENAME:-}
    id_like=${ID_LIKE:-}

    info "Detected: ${OS_NAME}"

    if [[ "${OS_ID}" == "debian" || "${OS_ID}" == "raspbian" || " ${id_like} " == *" debian "* ]]; then
        ok "Supported Debian-based operating system (${OS_ID} ${OS_VERSION})."
    else
        error "Unsupported distribution '${OS_ID}'. Debian, Raspberry Pi OS, or a Debian-derived system is required."
    fi
}

check_architecture() {
    local machine

    section "CPU architecture"
    machine=$(uname -m)

    case "${machine}" in
        aarch64|arm64)
            ARCH="arm64"
            ok "Supported ARM64 architecture detected (${machine})."
            ;;
        x86_64|amd64)
            ARCH="amd64"
            ok "Supported x86-64 architecture detected (${machine})."
            ;;
        *)
            ARCH=${machine}
            error "Unsupported CPU architecture '${machine}'. Supported architectures are ARM64 and x86-64."
            ;;
    esac
}

check_required_basic_tools() {
    local command
    local -a missing=()

    section "Required basic tools"
    for command in curl ip timeout sha256sum cmp flock lsblk findmnt; do
        if ! command_exists "${command}"; then
            missing+=("${command}")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        error "Required command(s) missing: ${missing[*]}."
        info "On Debian install the corresponding packages: curl iproute2 coreutils diffutils util-linux."
        return
    fi
    ok "Required networking, verification, comparison, and locking tools are available."
}

check_disk_space() {
    local check_path="/"
    local available_kb
    local available_mb

    section "Disk space"

    if [[ -d /opt ]]; then
        check_path="/opt"
    fi

    if ! available_kb=$(df -Pk "${check_path}" 2>/dev/null | awk 'NR == 2 {print $4}'); then
        error "Unable to determine free disk space for ${INSTALL_DIR}."
        return
    fi

    if [[ ! "${available_kb}" =~ ^[0-9]+$ ]]; then
        error "Unable to determine free disk space for ${INSTALL_DIR}."
        return
    fi

    available_mb=$((available_kb / 1024))
    info "Available where ${INSTALL_DIR} would be installed: ${available_mb} MiB."

    if (( available_mb < MIN_DISK_SPACE_MB )); then
        error "At least ${MIN_DISK_SPACE_MB} MiB of free disk space is required."
    else
        ok "Disk-space check passed (minimum ${MIN_DISK_SPACE_MB} MiB)."
    fi
}

check_existing_installation() {
    section "Installation path"

    if [[ ! -e "${INSTALL_DIR}" ]]; then
        APPLIANCE_STATE="fresh"
        ok "${INSTALL_DIR} does not already exist."
        return
    fi

    if [[ -f "${APPLIANCE_MARKER}" && ! -L "${APPLIANCE_MARKER}" ]]; then
        APPLIANCE_STATE="existing"
        ok "Existing Vaultwarden Appliance installation detected."
        return
    fi

    APPLIANCE_STATE="unknown"
    error "${INSTALL_DIR} exists without a valid appliance marker."
    info "The existing directory will not be modified."
}

detect_caddy_configuration() {
    local parsed_address=""
    local core_files=0

    section "Caddy configuration"

    if [[ -e "${CADDYFILE}" ]]; then
        core_files=$((core_files + 1))
    fi
    if [[ -e "${CADDY_COMPOSE_FILE}" ]]; then
        core_files=$((core_files + 1))
    fi

    if (( core_files == 0 )) && [[ ! -e "${CADDY_ACCESS_FILE}" ]]; then
        CADDY_STATE="absent"
        info "Caddy is not configured yet."
        return
    fi

    if [[ -e "${CADDY_ACCESS_FILE}" ]]; then
        if ! parsed_address=$(read_access_hostname "${CADDY_ACCESS_FILE}"); then
            error "The stored Caddy access state is missing or invalid; existing Caddy files will not be changed."
            return
        fi
        CADDY_ACCESS_ADDRESS=${parsed_address}
    else
        if [[ -e "${CADDYFILE}" ]]; then
            if ! parsed_address=$(read_caddyfile_hostname "${CADDYFILE}"); then
                error "The partial Caddyfile does not contain one valid appliance .local hostname."
                return
            fi
            CADDY_ACCESS_ADDRESS=${parsed_address}
            info "Recovered the selected hostname from the appliance Caddyfile: ${CADDY_ACCESS_ADDRESS}."
        fi
        CADDY_STATE="partial"
        info "Appliance-owned partial Caddy configuration detected; missing files will be reconciled."
        return
    fi

    if (( core_files == 2 )) && \
       [[ -f "${CADDYFILE}" && ! -L "${CADDYFILE}" ]] && \
       [[ -f "${CADDY_COMPOSE_FILE}" && ! -L "${CADDY_COMPOSE_FILE}" ]]; then
        CADDY_STATE="configured"
        ok "Existing Caddy configuration detected."
    else
        CADDY_STATE="partial"
        info "Appliance-owned partial Caddy configuration detected; missing files will be reconciled."
    fi
    info "Configured HTTPS URL: https://${CADDY_ACCESS_ADDRESS}"
}

check_docker() {
    section "Docker"

    if ! command_exists docker; then
        info "Docker is not installed."
        info "The installer can install Docker Engine and Docker Compose v2 after the preflight."
        return
    fi

    ok "Docker is installed: $(docker --version 2>/dev/null || printf 'version unknown')"

    if ! docker compose version >/dev/null 2>&1; then
        error "Docker Compose v2 is not available as 'docker compose'. The existing Docker installation will not be modified."
        return
    fi
    ok "Docker Compose v2 is available: $(docker compose version --short 2>/dev/null || docker compose version 2>/dev/null)"

    if docker info >/dev/null 2>&1; then
        ok "Docker daemon is running and accessible; the installer will not modify Docker."
        DOCKER_READY=1
    else
        error "Docker is installed, but the daemon is not running or is not accessible to this user."
    fi
}

caddy_owns_port_443() {
    [[ "${CADDY_STATE}" == "configured" ]] || return 1
    docker inspect --format '{{with (index .HostConfig.PortBindings "443/tcp")}}{{range .}}{{println .HostPort}}{{end}}{{end}}' caddy 2>/dev/null |
        grep -Fxq 443
}

check_ports() {
    local port=443

    section "Network ports"

    if port_is_in_use "${port}"; then
        if caddy_owns_port_443; then
            ok "TCP port ${port} is already in use by this appliance's Caddy container."
        else
            error "TCP port ${port} is already in use."
        fi
    else
        ok "TCP port ${port} appears available."
    fi
}

check_ipv4_address() {
    local candidate=""

    section "Network configuration"

    if candidate=$(detect_ipv4_address); then
        IPV4_ADDRESS=${candidate}
        ok "Detected LAN IPv4 address: ${IPV4_ADDRESS}"
    else
        warn "No usable LAN IPv4 address could be detected from the default route or a non-container interface."
    fi
}

print_preflight_summary() {
    section "Preflight summary"
    info "Installation target: ${INSTALL_DIR}"
    info "System: ${OS_NAME} (${OS_ID} ${OS_VERSION}), ${ARCH}"
    info "IPv4 address: ${IPV4_ADDRESS}"

    if (( ERRORS > 0 )); then
        printf '\nPreflight failed with %d error(s) and %d warning(s).\n' "${ERRORS}" "${WARNINGS}" >&2
        return 1
    fi

    printf '\nPreflight passed with %d warning(s).\n' "${WARNINGS}"
}

require_root() {
    if (( EUID != 0 )); then
        error "Appliance installation must run as root. Re-run with sudo."
        return 1
    fi
}

acquire_operation_lock() {
    local result=0

    if acquire_appliance_lock "${OPERATION_LOCK}"; then
        return 0
    else
        result=$?
    fi

    case "${result}" in
        1) error "Another Vaultwarden Appliance operation is already running." ;;
        2) error "flock is required for safe appliance operations; install the Debian util-linux package." ;;
        *) error "Unable to create the root-owned appliance operation lock at ${OPERATION_LOCK}." ;;
    esac
    return 1
}

detect_docker_user() {
    local candidate=${SUDO_USER:-}
    local candidate_uid
    local canonical_user

    section "Docker user access"

    if [[ -z "${candidate}" ]]; then
        info "No sudo-origin user was detected; Docker group configuration will be skipped."
        return
    fi

    if [[ "${candidate}" == "root" ]]; then
        info "The sudo-origin user is root; root will not be added to the docker group."
        return
    fi

    if [[ -z "${SUDO_UID:-}" || ! "${SUDO_UID}" =~ ^[0-9]+$ ]]; then
        warn "SUDO_UID is unavailable or invalid; Docker group configuration will be skipped."
        return
    fi

    if ! command_exists id || ! command_exists getent; then
        warn "Cannot validate SUDO_USER because id or getent is unavailable; Docker group configuration will be skipped."
        return
    fi

    if ! candidate_uid=$(id -u -- "${candidate}" 2>/dev/null); then
        warn "SUDO_USER '${candidate}' does not identify an existing user; Docker group configuration will be skipped."
        return
    fi

    if ! canonical_user=$(getent passwd "${candidate_uid}" 2>/dev/null | awk -F: 'NR == 1 {print $1}'); then
        warn "Unable to look up UID ${candidate_uid}; Docker group configuration will be skipped."
        return
    fi
    if [[ "${canonical_user}" != "${candidate}" ]]; then
        warn "SUDO_USER '${candidate}' does not match the account name for UID ${candidate_uid}; Docker group configuration will be skipped."
        return
    fi

    if [[ "${SUDO_UID}" != "${candidate_uid}" ]]; then
        warn "SUDO_USER and SUDO_UID do not identify the same account; Docker group configuration will be skipped."
        return
    fi

    DOCKER_USER=${candidate}
    ok "Validated sudo-origin user: ${DOCKER_USER} (UID ${candidate_uid})."
}

configure_docker_group() {
    local answer=""

    if [[ -z "${DOCKER_USER}" ]]; then
        return
    fi

    if ! getent group docker >/dev/null 2>&1; then
        error "The standard docker group does not exist."
        return 1
    fi

    info "Security note: membership in the docker group effectively grants root-level control of Docker."

    if id -nG -- "${DOCKER_USER}" | tr ' ' '\n' | grep -Fxq docker; then
        ok "User '${DOCKER_USER}' is already a member of the docker group; no change is needed."
        return
    fi

    if [[ ! -r /dev/tty ]]; then
        error "An interactive terminal is required to confirm Docker group membership."
        return 1
    fi

    if ! read -r -p "Allow user \"${DOCKER_USER}\" to use Docker without sudo? [Y/n] " answer </dev/tty; then
        error "Unable to read Docker group confirmation."
        return 1
    fi

    case "${answer}" in
        ""|y|Y|yes|YES|Yes)
            if ! command_exists usermod; then
                error "Cannot add '${DOCKER_USER}' to the docker group because usermod is unavailable."
                return 1
            fi
            usermod -aG docker "${DOCKER_USER}"
            DOCKER_GROUP_CHANGED=1
            ok "Added user '${DOCKER_USER}' to the docker group."
            info "A new login session or reboot is required before this group membership becomes active."
            ;;
        *)
            info "Docker group access was declined; user '${DOCKER_USER}' was not changed."
            ;;
    esac
}

confirm_docker_installation() {
    local answer=""

    printf '\nDocker is required but is not installed.\n'
    if [[ ! -r /dev/tty ]]; then
        error "Docker installation requires an interactive terminal for confirmation."
        return 1
    fi

    if ! read -r -p "Install Docker Engine and Docker Compose v2 now? [Y/n] " answer </dev/tty; then
        error "Unable to read Docker installation confirmation."
        return 1
    fi

    case "${answer}" in
        ""|y|Y|yes|YES|Yes)
            return 0
            ;;
        *)
            error "Docker installation was declined; no appliance files were created."
            return 1
            ;;
    esac
}

install_docker() {
    local dpkg_arch

    section "Docker installation"

    if [[ -z "${DOCKER_CODENAME}" || ! "${DOCKER_CODENAME}" =~ ^[a-z0-9.-]+$ ]]; then
        error "Cannot determine a valid Debian codename for the Docker repository."
        return 1
    fi

    if ! command_exists apt-get || ! command_exists dpkg; then
        error "Docker installation requires apt-get and dpkg on this Debian-based system."
        return 1
    fi

    dpkg_arch=$(dpkg --print-architecture)
    info "Configuring Docker's official Debian repository for ${DOCKER_CODENAME}/${dpkg_arch}."

    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    printf '%s\n' \
        'Types: deb' \
        'URIs: https://download.docker.com/linux/debian' \
        "Suites: ${DOCKER_CODENAME}" \
        'Components: stable' \
        "Architectures: ${dpkg_arch}" \
        'Signed-By: /etc/apt/keyrings/docker.asc' \
        > /etc/apt/sources.list.d/docker.sources

    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    systemctl enable --now docker
    hash -r
    ok "Docker packages were installed."
}

verify_docker() {
    section "Docker verification"

    if ! command_exists docker; then
        error "Docker installation completed, but the docker command is unavailable."
        return 1
    fi

    if ! docker info >/dev/null 2>&1; then
        error "Docker is installed, but the daemon verification failed."
        return 1
    fi

    if ! docker compose version >/dev/null 2>&1; then
        error "Docker Compose v2 verification failed; 'docker compose' is unavailable."
        return 1
    fi

    ok "Docker daemon is running: $(docker --version)"
    ok "Docker Compose v2 works: $(docker compose version --short 2>/dev/null || docker compose version)"
    DOCKER_READY=1
}

create_appliance_marker() {
    if ! (set -o noclobber; printf 'Vaultwarden Appliance\n' > "${APPLIANCE_MARKER}") 2>/dev/null; then
        error "Refusing to overwrite existing marker path ${APPLIANCE_MARKER}."
        return 1
    fi
    chmod 0644 "${APPLIANCE_MARKER}"
}

compose() {
    local -a compose_command=(
        docker compose
        --project-directory "${INSTALL_DIR}"
        --file "${BASE_COMPOSE_FILE}"
    )

    [[ -f "${CADDY_COMPOSE_FILE}" && ! -L "${CADDY_COMPOSE_FILE}" ]] &&
        compose_command+=(--file "${CADDY_COMPOSE_FILE}")
    [[ -f "${VWCTL_COMPOSE_FILE}" && ! -L "${VWCTL_COMPOSE_FILE}" ]] &&
        compose_command+=(--file "${VWCTL_COMPOSE_FILE}")
    "${compose_command[@]}" "$@"
}

compose_with_vaultwarden_candidate() {
    local candidate=$1
    shift
    local -a compose_command=(
        docker compose
        --project-directory "${INSTALL_DIR}"
        --file "${BASE_COMPOSE_FILE}"
    )

    [[ -f "${CADDY_COMPOSE_FILE}" && ! -L "${CADDY_COMPOSE_FILE}" ]] &&
        compose_command+=(--file "${CADDY_COMPOSE_FILE}")
    compose_command+=(--file "${candidate}")
    "${compose_command[@]}" "$@"
}

write_base_compose_to() {
    local destination=$1

    printf '%s\n' \
        'services:' \
        '  vaultwarden:' \
        '    image: vaultwarden/server:latest' \
        '    container_name: vaultwarden' \
        '    restart: unless-stopped' \
        '    environment:' \
        '      SIGNUPS_ALLOWED: "true"' \
        '    volumes:' \
        '      - ./data/vaultwarden:/data' \
        '    networks:' \
        '      - appliance' \
        '' \
        'networks:' \
        '  appliance:' \
        '    name: vaultwarden-appliance' > "${destination}" || return 1
    chmod 0644 "${destination}"
}

create_appliance_files() {
    local base_candidate

    section "Appliance files"

    if [[ "${APPLIANCE_STATE}" == "fresh" && -e "${INSTALL_DIR}" ]]; then
        error "${INSTALL_DIR} appeared during installation; refusing to overwrite it."
        return 1
    fi

    if [[ ! -e "${INSTALL_DIR}" ]]; then
        install -d -m 0755 "${INSTALL_DIR}"
    elif [[ ! -d "${INSTALL_DIR}" || -L "${INSTALL_DIR}" ]]; then
        error "The appliance installation path is not a safe directory."
        return 1
    fi

    if [[ -e "${INSTALL_DIR}/data/vaultwarden" &&
          ( ! -d "${INSTALL_DIR}/data/vaultwarden" || -L "${INSTALL_DIR}/data/vaultwarden" ) ]]; then
        error "The Vaultwarden data path is not a safe directory; it will not be changed."
        return 1
    fi
    install -d -m 0700 "${INSTALL_DIR}/data/vaultwarden"

    if [[ -e "${BASE_COMPOSE_FILE}" ]]; then
        if [[ ! -f "${BASE_COMPOSE_FILE}" || -L "${BASE_COMPOSE_FILE}" ]]; then
            error "The base Compose path is not a safe regular file."
            return 1
        fi
        ok "Preserved the existing base Compose file and Vaultwarden data."
    else
        base_candidate=$(mktemp "${INSTALL_DIR}/.docker-compose.install.XXXXXXXX") || return 1
        if ! write_base_compose_to "${base_candidate}" ||
           ! mv -- "${base_candidate}" "${BASE_COMPOSE_FILE}"; then
            rm -f -- "${base_candidate}"
            error "Unable to create the base Compose configuration."
            return 1
        fi
        ok "Created the missing base Compose configuration."
    fi

    if [[ "${APPLIANCE_STATE}" == "fresh" ]]; then
        create_appliance_marker
        APPLIANCE_STATE="existing"
        ok "Created the appliance marker after initializing the appliance directory."
    fi
}

current_signup_value() {
    local configured=""
    local environment=""

    if container_exists vaultwarden; then
        environment=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' vaultwarden \
            2>/dev/null) || environment=""
        configured=$(awk -F= '$1 == "SIGNUPS_ALLOWED" {print $2; found=1; exit} END {exit !found}' \
            <<<"${environment}") || configured=""
    fi
    if [[ "${configured}" != "true" && "${configured}" != "false" ]]; then
        configured=$(compose config 2>/dev/null |
            awk '$1 == "SIGNUPS_ALLOWED:" {gsub(/"/, "", $2); print $2; found=1; exit} END {exit !found}') ||
            configured=""
    fi
    [[ "${configured}" == "true" || "${configured}" == "false" ]] || configured="true"
    printf '%s\n' "${configured}"
}

reconcile_vaultwarden_configuration() {
    local candidate
    local signup_value

    section "Vaultwarden external URL"
    signup_value=$(current_signup_value) || {
        error "Unable to preserve the current signup setting."
        return 1
    }
    candidate=$(mktemp "${INSTALL_DIR}/.docker-compose.vwctl.install.XXXXXXXX") || return 1
    if ! write_vaultwarden_override_to "${candidate}" "${CADDY_ACCESS_ADDRESS}" "${signup_value}" ||
       ! compose_with_vaultwarden_candidate "${candidate}" config --quiet; then
        rm -f -- "${candidate}"
        error "The managed Vaultwarden DOMAIN configuration is invalid."
        return 1
    fi

    if [[ -e "${VWCTL_COMPOSE_FILE}" &&
          ( ! -f "${VWCTL_COMPOSE_FILE}" || -L "${VWCTL_COMPOSE_FILE}" ) ]]; then
        rm -f -- "${candidate}"
        error "The managed Vaultwarden Compose path is not a safe regular file."
        return 1
    fi
    if [[ -f "${VWCTL_COMPOSE_FILE}" ]] && cmp -s "${VWCTL_COMPOSE_FILE}" "${candidate}"; then
        rm -f -- "${candidate}"
        ok "Vaultwarden DOMAIN already matches https://${CADDY_ACCESS_ADDRESS}; no configuration change is needed."
    else
        mv -f -- "${candidate}" "${VWCTL_COMPOSE_FILE}"
        ok "Set Vaultwarden DOMAIN to https://${CADDY_ACCESS_ADDRESS} while preserving the signup setting."
    fi
}

deploy_vaultwarden() {
    section "Vaultwarden deployment"

    if ! compose config --quiet; then
        error "The generated Docker Compose configuration is invalid."
        return 1
    fi

    if ! docker image inspect vaultwarden/server:latest >/dev/null 2>&1; then
        compose pull vaultwarden
    fi
    compose up -d vaultwarden

    if [[ "$(docker inspect --format '{{.State.Running}}' vaultwarden 2>/dev/null)" != "true" ]]; then
        error "Vaultwarden was created but is not running. Inspect it with: docker logs vaultwarden"
        return 1
    fi

    if ! vaultwarden_domain_matches "${CADDY_ACCESS_ADDRESS}"; then
        error "The running Vaultwarden DOMAIN does not match https://${CADDY_ACCESS_ADDRESS}."
        return 1
    fi

    ok "Vaultwarden is running with the configured DOMAIN and without a host-published HTTP port."
}

package_is_installed() {
    dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null | grep -q '^ii '
}

install_usb_setup_support() {
    local package
    local -a missing_packages=()

    section "USB backup-media setup tools"

    command_exists sfdisk || missing_packages+=(fdisk)
    command_exists mkfs.exfat || missing_packages+=(exfatprogs)
    if ((${#missing_packages[@]} > 0)); then
        command_exists apt-get || {
            error "USB backup-media setup requires apt-get on this Debian-based system."
            return 1
        }
        info "Installing required USB setup packages: ${missing_packages[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing_packages[@]}"
    else
        ok "Required USB backup-media setup tools are already installed."
    fi

    for package in sfdisk mkfs.exfat lsblk findmnt umount readlink; do
        command_exists "${package}" || {
            error "Required USB setup command '${package}' is unavailable after package installation."
            return 1
        }
    done
    ok "GPT and exFAT setup tools are available."
}

install_backup_support() {
    local command
    local -a missing_packages=()

    section "Manual backup tools"

    command_exists tar || missing_packages+=(tar)
    command_exists gzip || missing_packages+=(gzip)
    if ! command_exists sha256sum || ! command_exists sync ||
       ! command_exists df || ! command_exists du; then
        missing_packages+=(coreutils)
    fi
    command_exists find || missing_packages+=(findutils)
    if ! command_exists mount || ! command_exists umount; then
        missing_packages+=(mount)
    fi
    if ((${#missing_packages[@]} > 0)); then
        command_exists apt-get || {
            error "Manual backup support requires apt-get on this Debian-based system."
            return 1
        }
        info "Installing required manual backup packages: ${missing_packages[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing_packages[@]}"
    else
        ok "Required manual backup tools are already installed."
    fi

    for command in tar gzip sha256sum sync df du find mount umount; do
        command_exists "${command}" || {
            error "Required manual backup command '${command}' is unavailable after package installation."
            return 1
        }
    done
    ok "Manual archive, checksum, and temporary-mount tools are available."
}

install_mdns_support() {
    local package
    local -a missing_packages=()

    section "mDNS support"

    command_exists apt-get || {
        error "mDNS setup requires apt-get on this Debian-based system."
        return 1
    }
    command_exists dpkg-query || {
        error "mDNS setup requires dpkg-query on this Debian-based system."
        return 1
    }
    command_exists systemctl || {
        error "mDNS setup requires systemd."
        return 1
    }
    for package in avahi-daemon avahi-utils libnss-mdns; do
        package_is_installed "${package}" || missing_packages+=("${package}")
    done

    if (( ${#missing_packages[@]} > 0 )); then
        info "Installing required Debian mDNS packages: ${missing_packages[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing_packages[@]}"
    else
        ok "Required mDNS packages are already installed."
    fi

    command_exists avahi-resolve-host-name || {
        error "avahi-resolve-host-name is unavailable after package installation."
        return 1
    }
    command_exists avahi-publish-address || {
        error "avahi-publish-address is unavailable after package installation."
        return 1
    }
    if [[ ! -f "${MDNS_WRAPPER_SOURCE}" || -L "${MDNS_WRAPPER_SOURCE}" ]] ||
       ! grep -Fxq '# Vaultwarden Appliance mDNS publisher' "${MDNS_WRAPPER_SOURCE}"; then
        error "The appliance mDNS publisher wrapper is missing or unsafe at ${MDNS_WRAPPER_SOURCE}."
        return 1
    fi

    systemctl enable --now avahi-daemon.service
    systemctl is-active --quiet avahi-daemon.service || {
        error "Avahi did not become active."
        return 1
    }
    ok "Avahi is installed and active."
}

mdns_name_conflicts() {
    local hostname=$1
    local address
    local local_addresses=""
    local resolved=""

    resolved=$(mdns_resolved_ipv4s "${hostname}" || true)
    [[ -n "${resolved}" ]] || return 1
    local_addresses=$(local_ipv4_addresses || true)

    while IFS= read -r address; do
        [[ "${address}" == "${IPV4_ADDRESS}" ]] && continue
        grep -Fxq "${address}" <<<"${local_addresses}" && continue
        return 0
    done <<<"${resolved}"
    return 1
}

next_available_mdns_hostname() {
    local base=${1%.local}
    local candidate
    local suffix

    for suffix in {2..99}; do
        candidate="${base}-${suffix}.local"
        if validate_local_hostname "${candidate}" && ! mdns_name_conflicts "${candidate}"; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done
    return 1
}

prompt_for_local_hostname() {
    local default_hostname=${DEFAULT_MDNS_HOSTNAME}
    local answer=""
    local conflict_answer=""
    local suggestion=""

    section "Local HTTPS name"

    validate_ipv4_address "${IPV4_ADDRESS}" || {
        error "A LAN IPv4 address is required to configure and verify mDNS."
        return 1
    }

    info "Detected LAN IPv4 address: ${IPV4_ADDRESS}"

    while true; do
        if ! read -r -p "Local Vaultwarden name [${default_hostname}]: " answer </dev/tty; then
            error "Unable to read the local Vaultwarden name."
            return 1
        fi

        CADDY_ACCESS_ADDRESS=${answer:-${default_hostname}}
        CADDY_ACCESS_ADDRESS=${CADDY_ACCESS_ADDRESS,,}
        if ! validate_local_hostname "${CADDY_ACCESS_ADDRESS}"; then
            warn "Invalid local name. Use one DNS label followed by .local, without spaces or underscores."
            continue
        fi

        if ! mdns_name_conflicts "${CADDY_ACCESS_ADDRESS}"; then
            break
        fi

        warn "The mDNS name ${CADDY_ACCESS_ADDRESS} is already advertised by another LAN device."
        suggestion=$(next_available_mdns_hostname "${CADDY_ACCESS_ADDRESS}") || {
            error "Unable to find an available alternative .local name."
            return 1
        }
        if ! read -r -p "Use available alternative ${suggestion}? [Y/n] " conflict_answer </dev/tty; then
            error "Unable to read the mDNS conflict choice."
            return 1
        fi
        case "${conflict_answer}" in
            ""|y|Y|yes|YES|Yes)
                CADDY_ACCESS_ADDRESS=${suggestion}
                break
                ;;
            *)
                info "Choose a different .local name."
                ;;
        esac
    done

    info "mDNS name: ${CADDY_ACCESS_ADDRESS} -> ${IPV4_ADDRESS}"
    info "Vaultwarden will be available on your local network at https://${CADDY_ACCESS_ADDRESS}."
    info "No local DNS configuration is required; this name is advertised using mDNS."
    info "Client devices must separately trust the exported Caddy root CA."
    info "The appliance will not change the system hostname, DNS, router, hosts files, or IP configuration."
}

write_mdns_service_configuration() {
    local wrapper_dir

    if [[ -e "${MDNS_ENV_FILE}" ]] && \
       { [[ ! -f "${MDNS_ENV_FILE}" || -L "${MDNS_ENV_FILE}" ]] || \
         ! grep -Fxq '# Vaultwarden Appliance mDNS' "${MDNS_ENV_FILE}" 2>/dev/null; }; then
        error "${MDNS_ENV_FILE} exists but is not appliance-managed; it will not be overwritten."
        return 1
    fi
    if [[ -e "${MDNS_SERVICE_FILE}" ]] && \
       { [[ ! -f "${MDNS_SERVICE_FILE}" || -L "${MDNS_SERVICE_FILE}" ]] || \
         ! grep -Fxq '# Vaultwarden Appliance mDNS' "${MDNS_SERVICE_FILE}" 2>/dev/null; }; then
        error "${MDNS_SERVICE_FILE} exists but is not appliance-managed; it will not be overwritten."
        return 1
    fi
    if [[ -e "${MDNS_WRAPPER_FILE}" ]] &&
       { [[ ! -f "${MDNS_WRAPPER_FILE}" || -L "${MDNS_WRAPPER_FILE}" ]] ||
         ! grep -Fxq '# Vaultwarden Appliance mDNS publisher' "${MDNS_WRAPPER_FILE}" 2>/dev/null; }; then
        error "${MDNS_WRAPPER_FILE} exists but is not appliance-managed; it will not be overwritten."
        return 1
    fi

    if [[ -f "${MDNS_SERVICE_FILE}" && ! -L "${MDNS_SERVICE_FILE}" ]]; then
        systemctl stop "${MDNS_SERVICE}" || true
    fi

    if mdns_name_conflicts "${CADDY_ACCESS_ADDRESS}"; then
        error "The mDNS name ${CADDY_ACCESS_ADDRESS} is advertised by another LAN device."
        return 1
    fi

    wrapper_dir=${MDNS_WRAPPER_FILE%/*}
    if [[ -e "${wrapper_dir}" && ( ! -d "${wrapper_dir}" || -L "${wrapper_dir}" ) ]]; then
        error "The mDNS wrapper directory ${wrapper_dir} is unsafe."
        return 1
    fi
    install -d -m 0755 "${wrapper_dir}"
    install -m 0755 "${MDNS_WRAPPER_SOURCE}" "${MDNS_WRAPPER_FILE}"

    cat > "${MDNS_ENV_FILE}" <<ENV
# Vaultwarden Appliance mDNS
VAULTWARDEN_MDNS_HOSTNAME=${CADDY_ACCESS_ADDRESS}
VAULTWARDEN_MDNS_IPV4=${IPV4_ADDRESS}
ENV
    chmod 0644 "${MDNS_ENV_FILE}"

    cat > "${MDNS_SERVICE_FILE}" <<'SERVICE'
# Vaultwarden Appliance mDNS
[Unit]
Description=Publish the Vaultwarden Appliance mDNS address mapping
Requires=avahi-daemon.service
Wants=network-online.target
After=network-online.target avahi-daemon.service

[Service]
Type=simple
EnvironmentFile=/etc/default/vaultwarden-appliance-mdns
RuntimeDirectory=vaultwarden-appliance-mdns
RuntimeDirectoryMode=0755
ExecStart=/usr/local/libexec/vaultwarden-appliance-mdns ${VAULTWARDEN_MDNS_HOSTNAME} ${VAULTWARDEN_MDNS_IPV4}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
SERVICE
    chmod 0644 "${MDNS_SERVICE_FILE}"

    systemctl daemon-reload
    systemctl enable "${MDNS_SERVICE}"
    systemctl restart "${MDNS_SERVICE}"
}

show_mdns_service_logs() {
    printf 'Recent %s log:\n' "${MDNS_SERVICE}" >&2
    if command_exists journalctl; then
        journalctl --unit "${MDNS_SERVICE}" --no-pager --lines 30 >&2 || true
    else
        systemctl status "${MDNS_SERVICE}" --no-pager >&2 || true
    fi
}

mdns_service_is_ready() {
    mdns_ready_file_matches "${MDNS_READY_FILE}" "${CADDY_ACCESS_ADDRESS}" "${IPV4_ADDRESS}"
}

verify_mdns() {
    local _attempt
    local getent_resolved=""
    local resolved=""

    systemctl is-active --quiet avahi-daemon.service || {
        error "Avahi is not active."
        return 1
    }
    for _attempt in {1..30}; do
        resolved=$(mdns_resolved_ipv4s "${CADDY_ACCESS_ADDRESS}" || true)
        if systemctl is-active --quiet "${MDNS_SERVICE}" &&
           mdns_service_is_ready &&
           mdns_resolution_matches "${IPV4_ADDRESS}" "${resolved}"; then
            ok "mDNS resolves ${CADDY_ACCESS_ADDRESS} to ${IPV4_ADDRESS}."
            if command_exists getent; then
                getent_resolved=$(timeout 4 getent hosts "${CADDY_ACCESS_ADDRESS}" 2>/dev/null |
                    awk '$1 ~ /^[0-9]+(\.[0-9]+){3}$/ && !seen[$1]++ {print $1}' || true)
                if mdns_resolution_matches "${IPV4_ADDRESS}" "${getent_resolved}"; then
                    ok "System host lookup also resolves ${CADDY_ACCESS_ADDRESS} to ${IPV4_ADDRESS}."
                else
                    warn "System host lookup does not yet resolve only to ${IPV4_ADDRESS}; Avahi-specific resolution is correct."
                    [[ -z "${getent_resolved}" ]] || info "getent IPv4 address(es): ${getent_resolved//$'\n'/, }"
                fi
            fi
            return 0
        fi
        sleep 1
    done

    if ! systemctl is-active --quiet "${MDNS_SERVICE}"; then
        error "The appliance mDNS publisher service is not active."
    elif ! mdns_service_is_ready; then
        error "The appliance mDNS publisher did not confirm that the explicit mapping is active."
    fi
    error "mDNS did not resolve ${CADDY_ACCESS_ADDRESS} exclusively to the detected LAN IPv4 address ${IPV4_ADDRESS}."
    [[ -z "${resolved}" ]] || info "Resolved IPv4 address(es): ${resolved//$'\n'/, }"
    show_mdns_service_logs
    return 1
}

configure_mdns() {
    write_mdns_service_configuration
    verify_mdns
}

report_configured_caddy_access() {
    info "Configured access: local mDNS hostname."
    info "HTTPS URL: https://${CADDY_ACCESS_ADDRESS}"
    info "mDNS mapping: ${CADDY_ACCESS_ADDRESS} -> ${IPV4_ADDRESS}"
}

reconcile_caddy_data_directories() {
    local directory

    for directory in "${CADDY_DATA_DIR}" "${CADDY_CONFIG_DIR}"; do
        if [[ -e "${directory}" && ( ! -d "${directory}" || -L "${directory}" ) ]]; then
            error "The Caddy persistent path is not a safe directory: ${directory}."
            return 1
        fi
    done
    install -d -m 0700 "${CADDY_DATA_DIR}" "${CADDY_CONFIG_DIR}"
}

create_caddy_configuration() {
    local access_candidate
    local caddy_candidate
    local compose_candidate
    local path

    section "Caddy configuration"

    caddy_candidate=$(mktemp "${INSTALL_DIR}/.Caddyfile.install.XXXXXXXX") || return 1
    compose_candidate=$(mktemp "${INSTALL_DIR}/.docker-compose.caddy.install.XXXXXXXX") || {
        rm -f -- "${caddy_candidate}"
        return 1
    }
    access_candidate=$(mktemp "${INSTALL_DIR}/.caddy-access.install.XXXXXXXX") || {
        rm -f -- "${caddy_candidate}" "${compose_candidate}"
        return 1
    }

    if ! write_caddyfile_to "${caddy_candidate}" "${CADDY_ACCESS_ADDRESS}" ||
       ! printf '%s\n' \
            'services:' \
            '  caddy:' \
            '    image: caddy:2' \
            '    container_name: caddy' \
            '    restart: unless-stopped' \
            '    ports:' \
            '      - "443:443/tcp"' \
            '    volumes:' \
            '      - ./Caddyfile:/etc/caddy/Caddyfile:ro' \
            '      - ./data/caddy/data:/data' \
            '      - ./data/caddy/config:/config' \
            '    networks:' \
            '      - appliance' > "${compose_candidate}" ||
       ! printf 'hostname=%s\n' "${CADDY_ACCESS_ADDRESS}" > "${access_candidate}" ||
       ! chmod 0644 "${compose_candidate}" "${access_candidate}"; then
        rm -f -- "${caddy_candidate}" "${compose_candidate}" "${access_candidate}"
        error "Unable to generate the appliance Caddy configuration."
        return 1
    fi

    for path in "${CADDYFILE}" "${CADDY_COMPOSE_FILE}" "${CADDY_ACCESS_FILE}"; do
        if [[ -e "${path}" && ( ! -f "${path}" || -L "${path}" ) ]]; then
            rm -f -- "${caddy_candidate}" "${compose_candidate}" "${access_candidate}"
            error "The appliance Caddy path is unsafe: ${path}."
            return 1
        fi
    done
    if [[ -e "${CADDYFILE}" ]] && ! cmp -s "${CADDYFILE}" "${caddy_candidate}"; then
        rm -f -- "${caddy_candidate}" "${compose_candidate}" "${access_candidate}"
        error "The existing Caddyfile differs from the appliance-managed configuration; it will not be overwritten."
        return 1
    fi
    if [[ -e "${CADDY_COMPOSE_FILE}" ]] && ! cmp -s "${CADDY_COMPOSE_FILE}" "${compose_candidate}"; then
        rm -f -- "${caddy_candidate}" "${compose_candidate}" "${access_candidate}"
        error "The existing Caddy Compose file differs from the appliance-managed configuration; it will not be overwritten."
        return 1
    fi
    if [[ -e "${CADDY_ACCESS_FILE}" ]] && ! cmp -s "${CADDY_ACCESS_FILE}" "${access_candidate}"; then
        rm -f -- "${caddy_candidate}" "${compose_candidate}" "${access_candidate}"
        error "The existing Caddy access state disagrees with the selected hostname."
        return 1
    fi

    if [[ -e "${CADDYFILE}" ]]; then rm -f -- "${caddy_candidate}"; else mv -- "${caddy_candidate}" "${CADDYFILE}"; fi
    if [[ -e "${CADDY_COMPOSE_FILE}" ]]; then rm -f -- "${compose_candidate}"; else mv -- "${compose_candidate}" "${CADDY_COMPOSE_FILE}"; fi
    if [[ -e "${CADDY_ACCESS_FILE}" ]]; then rm -f -- "${access_candidate}"; else mv -- "${access_candidate}" "${CADDY_ACCESS_FILE}"; fi
    CADDY_STATE="configured"
    ok "Reconciled Caddy configuration for https://${CADDY_ACCESS_ADDRESS}."
}

deploy_caddy() {
    section "Caddy deployment"

    if ! compose config --quiet; then
        error "The combined Vaultwarden and Caddy Compose configuration is invalid."
        return 1
    fi

    if ! compose config --services | grep -Fxq caddy; then
        error "The combined Compose configuration does not contain the Caddy service."
        return 1
    fi

    if ! docker image inspect caddy:2 >/dev/null 2>&1; then
        compose pull caddy
    fi

    compose up -d caddy
    ok "Caddy deployment requested without publishing TCP port 80."
}

export_caddy_root_ca() {
    local _attempt

    section "Caddy root CA export"

    for _attempt in {1..30}; do
        [[ -f "${CADDY_ROOT_CA}" && ! -L "${CADDY_ROOT_CA}" ]] && break
        sleep 1
    done

    if [[ ! -f "${CADDY_ROOT_CA}" || -L "${CADDY_ROOT_CA}" ]]; then
        error "Caddy's persistent root CA is missing or is not a safe regular file at ${CADDY_ROOT_CA}."
        return 1
    fi

    install -d -m 0755 "${INSTALL_DIR}/certs"

    if [[ -e "${EXPORTED_ROOT_CA}" ]]; then
        if [[ ! -f "${EXPORTED_ROOT_CA}" || -L "${EXPORTED_ROOT_CA}" ]]; then
            error "The CA export path exists but is not a regular managed file; it will not be overwritten."
            return 1
        fi
        if ! cmp -s "${CADDY_ROOT_CA}" "${EXPORTED_ROOT_CA}"; then
            error "The exported root CA differs from Caddy's persistent CA; refusing to overwrite it silently."
            return 1
        fi
        ok "Existing root CA export matches Caddy's persistent CA."
    else
        if ! copy_public_certificate_atomic "${CADDY_ROOT_CA}" "${EXPORTED_ROOT_CA}"; then
            error "Unable to validate and atomically export Caddy's public root CA certificate."
            return 1
        fi
        ok "Exported Caddy's public root CA certificate to ${EXPORTED_ROOT_CA}."
    fi

    info "Client devices must trust this root CA before https://${CADDY_ACCESS_ADDRESS} will be trusted."
    info "Caddy's private CA key remains only in the persistent Caddy data directory and is not exported."
}

verify_phase3() {
    local _attempt
    local endpoint_ok=0

    section "Phase 3 verification"

    verify_mdns

    if ! container_is_running vaultwarden; then
        error "Vaultwarden is not running."
        return 1
    fi
    ok "Vaultwarden container is running."

    if ! vaultwarden_domain_matches "${CADDY_ACCESS_ADDRESS}"; then
        error "The running Vaultwarden DOMAIN does not match https://${CADDY_ACCESS_ADDRESS}."
        return 1
    fi
    ok "Vaultwarden DOMAIN matches the configured appliance URL."

    if [[ "$(docker inspect --format '{{len .HostConfig.PortBindings}}' vaultwarden 2>/dev/null)" != "0" ]]; then
        error "Vaultwarden unexpectedly publishes a host port."
        return 1
    fi
    ok "Vaultwarden has no host-published ports."

    if [[ "$(docker inspect --format '{{.State.Running}}' caddy 2>/dev/null)" != "true" ]]; then
        error "Caddy is not running. Inspect it with: docker logs caddy"
        return 1
    fi
    ok "Caddy container is running."

    if [[ "$(docker inspect --format '{{len .HostConfig.PortBindings}}' caddy 2>/dev/null)" != "1" ]]; then
        error "Caddy must publish exactly one host port (TCP 443)."
        return 1
    fi

    if ! container_is_connected_to_network caddy vaultwarden-appliance; then
        error "Caddy is not connected to the vaultwarden-appliance Docker network."
        return 1
    fi
    ok "Caddy is connected to the internal appliance network."

    if ! caddy_owns_port_443 || ! port_is_in_use 443; then
        error "Caddy is not listening on host TCP port 443."
        return 1
    fi
    ok "Caddy is listening on host TCP port 443."

    if [[ ! -f "${EXPORTED_ROOT_CA}" ]]; then
        error "The exported Caddy root CA certificate is missing."
        return 1
    fi

    if ! command_exists curl; then
        error "curl is required to verify the local HTTPS endpoint."
        return 1
    fi

    for _attempt in {1..30}; do
        if curl --fail --silent --show-error \
            --noproxy '*' \
            --cacert "${EXPORTED_ROOT_CA}" \
            --connect-to "${CADDY_ACCESS_ADDRESS}:443:127.0.0.1:443" \
            "https://${CADDY_ACCESS_ADDRESS}/alive" >/dev/null 2>&1; then
            endpoint_ok=1
            break
        fi
        sleep 1
    done

    if (( endpoint_ok == 0 )); then
        error "The HTTPS health endpoint failed with explicit trust in the exported Caddy root CA."
        return 1
    fi

    ok "Caddy reached Vaultwarden over the internal Docker network."
    ok "The HTTPS endpoint responded with the exported root CA explicitly trusted."
}

install_vwctl() {
    local library
    local source_library
    local target_library

    section "vwctl installation"

    if [[ ! -f "${VWCTL_SOURCE}" || -L "${VWCTL_SOURCE}" ]]; then
        error "The vwctl source script is missing or unsafe at ${VWCTL_SOURCE}."
        info "Run install.sh from a complete repository checkout containing vwctl."
        return 1
    fi

    if ! grep -Fxq '# Vaultwarden Appliance vwctl' "${VWCTL_SOURCE}"; then
        error "The vwctl source script does not contain the expected appliance identifier."
        return 1
    fi
    if [[ ! -f "${USB_SETUP_SOURCE}" || -L "${USB_SETUP_SOURCE}" ]] ||
       ! grep -Fxq '# Vaultwarden Appliance USB setup' "${USB_SETUP_SOURCE}"; then
        error "The appliance USB setup helper is missing or unsafe at ${USB_SETUP_SOURCE}."
        return 1
    fi

    if [[ -e "${VWCTL_TARGET}" ]]; then
        if [[ ! -f "${VWCTL_TARGET}" || -L "${VWCTL_TARGET}" ]] || \
           ! grep -Fxq '# Vaultwarden Appliance vwctl' "${VWCTL_TARGET}"; then
            error "${VWCTL_TARGET} already exists but is not recognized as appliance-managed; it will not be overwritten."
            return 1
        fi
    fi

    if [[ -e "${LIB_TARGET_DIR}" &&
          ( ! -d "${LIB_TARGET_DIR}" || -L "${LIB_TARGET_DIR}" ) ]]; then
        error "The shared-library installation path is unsafe: ${LIB_TARGET_DIR}."
        return 1
    fi
    install -d -m 0755 "${LIB_TARGET_DIR}"
    for library in common network docker caddy mdns storage; do
        source_library="${LIB_SOURCE_DIR}/${library}.sh"
        target_library="${LIB_TARGET_DIR}/${library}.sh"
        if [[ ! -f "${source_library}" || -L "${source_library}" ]]; then
            error "Required shared library is missing or unsafe: ${source_library}."
            return 1
        fi
        if [[ -e "${target_library}" &&
              ( ! -f "${target_library}" || -L "${target_library}" ) ]]; then
            error "The shared-library target is unsafe: ${target_library}."
            return 1
        fi
        install -m 0644 "${source_library}" "${target_library}"
    done

    install -d -m 0755 /usr/local/bin
    install -m 0755 "${VWCTL_SOURCE}" "${VWCTL_TARGET}"
    if [[ ! -x "${VWCTL_TARGET}" ]]; then
        error "vwctl was copied but is not executable at ${VWCTL_TARGET}."
        return 1
    fi

    install -d -m 0755 /usr/local/libexec
    if [[ -e "${USB_SETUP_TARGET}" &&
          ( ! -f "${USB_SETUP_TARGET}" || -L "${USB_SETUP_TARGET}" ) ]]; then
        error "The USB setup helper target is unsafe: ${USB_SETUP_TARGET}."
        return 1
    fi
    install -m 0755 "${USB_SETUP_SOURCE}" "${USB_SETUP_TARGET}"
    if [[ ! -x "${USB_SETUP_TARGET}" ]]; then
        error "The USB setup helper was copied but is not executable at ${USB_SETUP_TARGET}."
        return 1
    fi

    if [[ -e "${BACKUP_TARGET}" &&
          ( ! -f "${BACKUP_TARGET}" || -L "${BACKUP_TARGET}" ) ]]; then
        error "The backup helper target is unsafe: ${BACKUP_TARGET}."
        return 1
    fi
    install -m 0755 "${BACKUP_SOURCE}" "${BACKUP_TARGET}"
    if [[ ! -x "${BACKUP_TARGET}" ]]; then
        error "The backup helper was copied but is not executable at ${BACKUP_TARGET}."
        return 1
    fi

    ok "Installed the appliance management command, USB setup helper, and backup helper."
}

install_appliance_version() {
    local version
    local -a lines

    section "Appliance version"

    if [[ ! -f "${VERSION_SOURCE}" || -L "${VERSION_SOURCE}" ]]; then
        error "The appliance version source is missing or unsafe at ${VERSION_SOURCE}."
        return 1
    fi
    mapfile -t lines < "${VERSION_SOURCE}"
    if (( ${#lines[@]} != 1 )) ||
       [[ ! "${lines[0]}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
        error "The appliance version source is invalid."
        return 1
    fi
    version=${lines[0]}

    if [[ -e "${VERSION_TARGET}" &&
          ( ! -f "${VERSION_TARGET}" || -L "${VERSION_TARGET}" ) ]]; then
        error "The appliance version path is unsafe and will not be overwritten."
        return 1
    fi

    install -m 0644 "${VERSION_SOURCE}" "${VERSION_TARGET}"
    ok "Installed Vaultwarden Appliance version ${version}."
}

print_completion_summary() {
    section "Phase 4 complete"
    info "Installation directory: ${INSTALL_DIR}"
    info "Compose file: ${INSTALL_DIR}/docker-compose.yml"
    info "Persistent data: ${INSTALL_DIR}/data/vaultwarden"
    info "Docker network: vaultwarden-appliance"
    info "Access: local mDNS hostname"
    info "HTTPS endpoint: https://${CADDY_ACCESS_ADDRESS}"
    info "Vaultwarden DOMAIN: https://${CADDY_ACCESS_ADDRESS}"
    info "mDNS mapping: ${CADDY_ACCESS_ADDRESS} -> ${IPV4_ADDRESS}"
    info "No local DNS configuration is required; Avahi advertises this name using mDNS."
    info "Exported root CA: ${EXPORTED_ROOT_CA}"
    info "Management command: ${VWCTL_TARGET}"
    info "Vaultwarden remains internal-only; only Caddy publishes host TCP port 443."
    info "Appliance-owned files and containers were reconciled idempotently; persistent Vaultwarden data was preserved."
    if (( DOCKER_GROUP_CHANGED == 1 )); then
        info "User '${DOCKER_USER}' must start a new login session or reboot before using Docker without sudo."
    fi
}

main() {
    printf 'Vaultwarden Appliance - Phase 4 installer\n'

    require_root
    acquire_operation_lock
    check_operating_system
    check_architecture
    check_required_basic_tools
    check_disk_space
    check_docker
    check_existing_installation
    detect_caddy_configuration
    check_ports
    check_ipv4_address
    print_preflight_summary

    detect_docker_user

    if (( DOCKER_READY == 0 )); then
        confirm_docker_installation
        install_docker
        verify_docker
    fi

    configure_docker_group
    install_mdns_support
    install_usb_setup_support
    install_backup_support

    case "${APPLIANCE_STATE}" in
        fresh|existing) create_appliance_files ;;
        *)
            error "Unexpected or unsafe appliance state '${APPLIANCE_STATE}'."
            return 1
            ;;
    esac

    if [[ "${CADDY_STATE}" == "absent" ||
          ( "${CADDY_STATE}" == "partial" && -z "${CADDY_ACCESS_ADDRESS}" ) ]]; then
        prompt_for_local_hostname
    else
        if mdns_name_conflicts "${CADDY_ACCESS_ADDRESS}"; then
            error "The configured mDNS name ${CADDY_ACCESS_ADDRESS} is now advertised by another LAN device."
            return 1
        fi
    fi

    reconcile_caddy_data_directories
    configure_mdns
    if [[ "${CADDY_STATE}" != "configured" ]]; then
        create_caddy_configuration
    else
        ok "Preserved the existing Caddy configuration and persistent CA data."
    fi
    report_configured_caddy_access
    reconcile_vaultwarden_configuration
    deploy_vaultwarden
    deploy_caddy
    export_caddy_root_ca
    verify_phase3
    install_appliance_version
    install_vwctl

    print_completion_summary
}

main "$@"
