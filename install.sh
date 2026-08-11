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
readonly ACCESS_FILE="${INSTALL_DIR}/.access"
readonly BACKUP_STATE_FILE="${INSTALL_DIR}/.backup-device"
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
readonly RESTORE_SOURCE="${SCRIPT_DIR}/libexec/restore"
readonly RESTORE_TARGET="/usr/local/libexec/vaultwarden-appliance-restore"
readonly LOCAL_BACKUP_DIR="${INSTALL_DIR}/backups"
readonly BACKUP_SERVICE_SOURCE="${SCRIPT_DIR}/systemd/vaultwarden-appliance-backup.service"
readonly BACKUP_TIMER_SOURCE="${SCRIPT_DIR}/systemd/vaultwarden-appliance-backup.timer"
readonly BACKUP_SERVICE_FILE="/etc/systemd/system/vaultwarden-appliance-backup.service"
readonly BACKUP_TIMER_FILE="/etc/systemd/system/vaultwarden-appliance-backup.timer"
readonly BACKUP_TIMER="vaultwarden-appliance-backup.timer"
readonly BACKUP_LABEL="VWBACKUP"
readonly VERSION_SOURCE="${SCRIPT_DIR}/VERSION"
readonly VERSION_TARGET="${INSTALL_DIR}/.appliance-version"
readonly OPERATION_LOCK="/run/lock/vaultwarden-appliance.lock"
readonly DEFAULT_MDNS_HOSTNAME="vaultwarden.local"
readonly DEFAULT_DNS_HOSTNAME="vault.lan"
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
if [[ ! -f "${RESTORE_SOURCE}" || -L "${RESTORE_SOURCE}" ]] ||
   ! grep -Fxq '# Vaultwarden Appliance restore' "${RESTORE_SOURCE}"; then
    printf '[FAIL] Required restore helper is missing or unsafe: %s\n' \
        "${RESTORE_SOURCE}" >&2
    exit 1
fi
for unit_source in "${BACKUP_SERVICE_SOURCE}" "${BACKUP_TIMER_SOURCE}"; do
    if [[ ! -f "${unit_source}" || -L "${unit_source}" ]] ||
       ! grep -Fxq '# Vaultwarden Appliance automatic backup' "${unit_source}"; then
        printf '[FAIL] Required automatic-backup unit is missing or unsafe: %s\n' \
            "${unit_source}" >&2
        exit 1
    fi
done
unset unit_source

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
ACCESS_MODE="mdns"
CADDY_ACCESS_ADDRESS=""
CADDY_CONFIG_CHANGED=0

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
    for command in curl getent ip timeout sha256sum cmp flock lsblk findmnt; do
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
    local parsed_access=""
    local parsed_address=""
    local core_files=0

    section "Caddy configuration"

    if [[ -e "${CADDYFILE}" ]]; then
        core_files=$((core_files + 1))
    fi
    if [[ -e "${CADDY_COMPOSE_FILE}" ]]; then
        core_files=$((core_files + 1))
    fi

    if [[ -e "${ACCESS_FILE}" || -L "${ACCESS_FILE}" ]]; then
        if ! access_config_file_is_safe "${ACCESS_FILE}" ||
           ! parsed_access=$(read_access_config "${ACCESS_FILE}"); then
            error "The appliance access configuration is unsafe or invalid; existing access files will not be changed."
            return
        fi
        IFS=$'\t' read -r ACCESS_MODE CADDY_ACCESS_ADDRESS <<<"${parsed_access}"
    fi

    if (( core_files == 0 )) && [[ ! -e "${ACCESS_FILE}" ]]; then
        info "Caddy is not configured yet."
        return
    fi

    if [[ ! -e "${ACCESS_FILE}" ]]; then
        info "No appliance access configuration exists yet; it will be created from your choices."
        return
    fi

    if [[ -e "${CADDYFILE}" ]]; then
        if ! parsed_address=$(read_caddyfile_hostname "${CADDYFILE}"); then
            error "The existing Caddyfile does not contain one valid appliance hostname."
            return
        fi
        if [[ "${parsed_address}" != "${CADDY_ACCESS_ADDRESS}" ]]; then
            info "The Caddy hostname will be reconciled with the appliance access configuration."
            return
        fi
    fi

    if (( core_files == 2 )) && \
       [[ -f "${CADDYFILE}" && ! -L "${CADDYFILE}" ]] && \
       [[ -f "${CADDY_COMPOSE_FILE}" && ! -L "${CADDY_COMPOSE_FILE}" ]]; then
        ok "Existing Caddy configuration detected."
    else
        info "Appliance-owned partial Caddy configuration detected; missing files will be reconciled."
    fi
    info "Configured access mode: ${ACCESS_MODE}"
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
    container_exists caddy || return 1
    container_is_connected_to_network caddy vaultwarden-appliance || return 1
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

    section "Backup tools"

    command_exists tar || missing_packages+=(tar)
    command_exists gzip || missing_packages+=(gzip)
    if ! command_exists sha256sum || ! command_exists sync ||
       ! command_exists df || ! command_exists du || ! command_exists cp ||
       ! command_exists sort; then
        missing_packages+=(coreutils)
    fi
    command_exists find || missing_packages+=(findutils)
    command_exists openssl || missing_packages+=(openssl)
    if ! command_exists mount || ! command_exists umount; then
        missing_packages+=(mount)
    fi
    if ((${#missing_packages[@]} > 0)); then
        command_exists apt-get || {
            error "Backup support requires apt-get on this Debian-based system."
            return 1
        }
        info "Installing required backup packages: ${missing_packages[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing_packages[@]}"
    else
        ok "Required backup tools are already installed."
    fi

    for command in tar gzip sha256sum sync df du find mount umount cp sort openssl od tr; do
        command_exists "${command}" || {
            error "Required backup command '${command}' is unavailable after package installation."
            return 1
        }
    done
    ok "Archive, checksum, copy, and temporary-mount tools are available."
}

configure_local_backup_directory() {
    section "Local backup storage"

    if [[ -e "${LOCAL_BACKUP_DIR}" || -L "${LOCAL_BACKUP_DIR}" ]]; then
        [[ -d "${LOCAL_BACKUP_DIR}" && ! -L "${LOCAL_BACKUP_DIR}" ]] || {
            error "The local backup path is unsafe: ${LOCAL_BACKUP_DIR}."
            return 1
        }
    fi
    getent group docker >/dev/null 2>&1 || {
        error "The standard docker group is required for administrator-readable backup status."
        return 1
    }
    install -d -o root -g docker -m 0750 "${LOCAL_BACKUP_DIR}"
    [[ "$(stat -c '%u' "${LOCAL_BACKUP_DIR}")" == "0" ]] || {
        error "The local backup directory is not owned by root."
        return 1
    }
    (( (8#$(stat -c '%a' "${LOCAL_BACKUP_DIR}") & 8#002) == 0 )) || {
        error "The local backup directory is world-writable."
        return 1
    }
    ok "Local backups use ${LOCAL_BACKUP_DIR} with root:docker 0750 permissions."
}

reconcile_backup_state_permissions() {
    local owner
    local permissions

    [[ -e "${BACKUP_STATE_FILE}" || -L "${BACKUP_STATE_FILE}" ]] || return 0
    [[ -f "${BACKUP_STATE_FILE}" && ! -L "${BACKUP_STATE_FILE}" ]] || {
        error "The backup-media state path is unsafe: ${BACKUP_STATE_FILE}."
        return 1
    }
    owner=$(stat -c '%u' "${BACKUP_STATE_FILE}") || return 1
    permissions=$(stat -c '%a' "${BACKUP_STATE_FILE}") || return 1
    [[ "${owner}" == "0" && "${permissions}" =~ ^[0-7]{3,4}$ ]] || {
        error "The backup-media state ownership or permissions are invalid."
        return 1
    }
    (( (8#${permissions} & 8#022) == 0 )) || {
        error "The backup-media state file is group- or world-writable."
        return 1
    }
    storage_read_backup_state "${BACKUP_STATE_FILE}" >/dev/null || {
        error "The backup-media state file is invalid and will not be changed."
        return 1
    }
    chmod 0644 "${BACKUP_STATE_FILE}"
    ok "Backup-media state is root-owned and readable for unprivileged status checks."
}

install_backup_automation() {
    local source
    local target

    section "Automatic daily backup"
    command_exists systemctl || {
        error "Automatic backup requires systemd."
        return 1
    }
    for source in "${BACKUP_SERVICE_SOURCE}" "${BACKUP_TIMER_SOURCE}"; do
        [[ -f "${source}" && ! -L "${source}" ]] || {
            error "Automatic-backup unit source is missing or unsafe: ${source}."
            return 1
        }
    done
    for target in "${BACKUP_SERVICE_FILE}" "${BACKUP_TIMER_FILE}"; do
        if [[ -e "${target}" || -L "${target}" ]]; then
            if [[ ! -f "${target}" || -L "${target}" ]] ||
               ! grep -Fxq '# Vaultwarden Appliance automatic backup' "${target}"; then
                error "Existing systemd unit is not appliance-managed: ${target}."
                return 1
            fi
        fi
    done
    install -m 0644 "${BACKUP_SERVICE_SOURCE}" "${BACKUP_SERVICE_FILE}"
    install -m 0644 "${BACKUP_TIMER_SOURCE}" "${BACKUP_TIMER_FILE}"
    systemctl daemon-reload
    systemctl enable --now "${BACKUP_TIMER}"
    systemctl is-enabled --quiet "${BACKUP_TIMER}" || {
        error "The automatic-backup timer is not enabled."
        return 1
    }
    systemctl is-active --quiet "${BACKUP_TIMER}" || {
        error "The automatic-backup timer is not active."
        return 1
    }
    ok "Daily backups are scheduled for 02:30 local time with Persistent=true."
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

read_installer_answer() {
    local prompt=$1
    local destination=$2
    local value=""

    IFS= read -r -p "${prompt}" value </dev/tty || return 1
    printf -v "${destination}" '%s' "${value}"
}

prompt_for_access_configuration() {
    local current_mode=${ACCESS_MODE}
    local current_hostname=${CADDY_ACCESS_ADDRESS}
    local default_mode=1
    local default_hostname
    local answer=""
    local selected_hostname
    local selected_mode

    section "Vaultwarden access mode"

    validate_ipv4_address "${IPV4_ADDRESS}" || {
        error "A LAN IPv4 address is required to configure and verify appliance access."
        return 1
    }

    if [[ "${current_mode}" == dns ]]; then
        default_mode=2
    fi
    printf '\n1) mDNS\n'
    printf '   Simple setup for the local home network.\n'
    printf '   No local DNS server is required.\n'
    printf '   The appliance publishes a .local hostname automatically.\n'
    printf '   Not intended for access through normal routed VPN connections.\n'
    printf '\n2) External/local DNS\n'
    printf '   Use this if you already run AdGuard, Pi-hole, Unbound,\n'
    printf '   router DNS, or another local DNS server.\n'
    printf '   Recommended if Vaultwarden should also be reachable through a VPN.\n'
    printf '   You must create the DNS record yourself.\n\n'

    info "Detected LAN IPv4 address: ${IPV4_ADDRESS}"
    if [[ -n "${current_hostname}" ]] &&
       validate_access_configuration "${current_mode}" "${current_hostname}"; then
        printf '\nCurrent configuration:\n'
        printf 'mode=%s\n' "${current_mode}"
        printf 'hostname=%s\n' "${current_hostname}"
    fi

    while true; do
        if ! read_installer_answer "Select access mode [${default_mode}]: " answer; then
            error "Unable to read the access mode choice."
            return 1
        fi
        answer=${answer:-${default_mode}}
        case "${answer}" in
            1) selected_mode=mdns ;;
            2) selected_mode=dns ;;
            *)
                warn "Please enter 1 or 2."
                continue
                ;;
        esac
        break
    done

    if [[ "${selected_mode}" == "${current_mode}" ]] &&
       validate_access_configuration "${current_mode}" "${current_hostname}"; then
        default_hostname=${current_hostname}
    elif [[ "${selected_mode}" == mdns ]]; then
        default_hostname=${DEFAULT_MDNS_HOSTNAME}
    else
        default_hostname=${DEFAULT_DNS_HOSTNAME}
    fi

    while true; do
        if [[ "${selected_mode}" == mdns ]]; then
            if ! read_installer_answer \
                "Vaultwarden mDNS hostname [${default_hostname}]: " answer; then
                error "Unable to read the Vaultwarden mDNS hostname."
                return 1
            fi
        elif ! read_installer_answer \
            "Vaultwarden DNS hostname [${default_hostname}]: " answer; then
            error "Unable to read the Vaultwarden DNS hostname."
            return 1
        fi
        selected_hostname=${answer:-${default_hostname}}
        selected_hostname=${selected_hostname,,}

        if validate_access_configuration "${selected_mode}" "${selected_hostname}"; then
            break
        fi
        if validate_ipv4_address "${selected_hostname}"; then
            warn "IP addresses are not valid hostnames."
        elif [[ "${selected_mode}" == mdns ]]; then
            warn "mDNS requires a valid lowercase hostname ending in .local."
        else
            warn "External DNS requires a valid lowercase DNS hostname and does not accept .local."
        fi
    done

    ACCESS_MODE=${selected_mode}
    CADDY_ACCESS_ADDRESS=${selected_hostname}
    ok "Selected ${ACCESS_MODE} access at https://${CADDY_ACCESS_ADDRESS}."
}

resolve_selected_mdns_conflict() {
    local conflict_answer=""
    local suggestion=""

    if ! mdns_name_conflicts "${CADDY_ACCESS_ADDRESS}"; then
        return 0
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
        ""|y|Y|yes|YES|Yes) CADDY_ACCESS_ADDRESS=${suggestion} ;;
        *) error "The selected mDNS hostname conflicts with another LAN device."; return 1 ;;
    esac
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

remove_appliance_mdns_configuration() {
    local path
    local marker

    section "mDNS publisher"
    for path in "${MDNS_ENV_FILE}" "${MDNS_SERVICE_FILE}" "${MDNS_WRAPPER_FILE}"; do
        case "${path}" in
            "${MDNS_WRAPPER_FILE}") marker='# Vaultwarden Appliance mDNS publisher' ;;
            *) marker='# Vaultwarden Appliance mDNS' ;;
        esac
        if [[ -e "${path}" || -L "${path}" ]]; then
            if [[ ! -f "${path}" || -L "${path}" ]] || ! grep -Fxq "${marker}" "${path}"; then
                error "Existing mDNS path is not appliance-managed and will not be removed: ${path}"
                return 1
            fi
        fi
    done

    if [[ -f "${MDNS_SERVICE_FILE}" && ! -L "${MDNS_SERVICE_FILE}" ]]; then
        systemctl disable --now "${MDNS_SERVICE}" >/dev/null || return 1
    fi
    rm -f -- "${MDNS_ENV_FILE}" "${MDNS_SERVICE_FILE}" "${MDNS_WRAPPER_FILE}" "${MDNS_READY_FILE}"
    systemctl daemon-reload
    systemctl reset-failed "${MDNS_SERVICE}" >/dev/null 2>&1 || true
    ok "The appliance mDNS publisher is disabled and removed."
    info "Avahi itself and all installed Avahi packages were preserved."
}

report_external_dns() {
    local resolved=""

    section "External DNS"
    info "External DNS selected."
    info "Configure this DNS record on your local DNS server:"
    info "  ${CADDY_ACCESS_ADDRESS} -> ${IPV4_ADDRESS}"
    resolved=$(dns_resolved_ipv4s "${CADDY_ACCESS_ADDRESS}" || true)
    if dns_resolution_matches "${IPV4_ADDRESS}" "${resolved}"; then
        ok "${CADDY_ACCESS_ADDRESS} resolves to ${IPV4_ADDRESS}."
    else
        warn "${CADDY_ACCESS_ADDRESS} does not currently resolve to ${IPV4_ADDRESS}."
        info "Configure the DNS record on your local DNS server."
        [[ -z "${resolved}" ]] || info "Current IPv4 address(es): ${resolved//$'\n'/, }"
    fi
    info "The appliance did not modify DNS, hosts files, DHCP, the router, or the system hostname."
}

report_configured_caddy_access() {
    if [[ "${ACCESS_MODE}" == mdns ]]; then
        info "Configured access: local mDNS hostname."
        info "mDNS mapping: ${CADDY_ACCESS_ADDRESS} -> ${IPV4_ADDRESS}"
    else
        info "Configured access: external DNS hostname."
        info "Required DNS mapping: ${CADDY_ACCESS_ADDRESS} -> ${IPV4_ADDRESS}"
    fi
    info "HTTPS URL: https://${CADDY_ACCESS_ADDRESS}"
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
    local caddy_candidate
    local compose_candidate
    local existing_caddy_hostname=""
    local managed_caddy_candidate=""
    local path

    section "Caddy configuration"

    caddy_candidate=$(mktemp "${INSTALL_DIR}/.Caddyfile.install.XXXXXXXX") || return 1
    compose_candidate=$(mktemp "${INSTALL_DIR}/.docker-compose.caddy.install.XXXXXXXX") || {
        rm -f -- "${caddy_candidate}"
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
       ! chmod 0644 "${compose_candidate}"; then
        rm -f -- "${caddy_candidate}" "${compose_candidate}"
        error "Unable to generate the appliance Caddy configuration."
        return 1
    fi

    for path in "${CADDYFILE}" "${CADDY_COMPOSE_FILE}" "${ACCESS_FILE}"; do
        if [[ -e "${path}" && ( ! -f "${path}" || -L "${path}" ) ]]; then
            rm -f -- "${caddy_candidate}" "${compose_candidate}"
            error "The appliance Caddy path is unsafe: ${path}."
            return 1
        fi
    done
    if [[ -e "${CADDYFILE}" ]] && ! cmp -s "${CADDYFILE}" "${caddy_candidate}"; then
        existing_caddy_hostname=$(read_caddyfile_hostname "${CADDYFILE}" || true)
        managed_caddy_candidate=$(mktemp "${INSTALL_DIR}/.Caddyfile.current.XXXXXXXX") || {
            rm -f -- "${caddy_candidate}" "${compose_candidate}"
            return 1
        }
        if [[ -z "${existing_caddy_hostname}" ]] ||
           ! write_caddyfile_to "${managed_caddy_candidate}" "${existing_caddy_hostname}" ||
           ! cmp -s "${CADDYFILE}" "${managed_caddy_candidate}"; then
            rm -f -- "${caddy_candidate}" "${compose_candidate}" "${managed_caddy_candidate}"
            error "The existing Caddyfile is not appliance-managed; it will not be overwritten."
            return 1
        fi
        rm -f -- "${managed_caddy_candidate}"
    fi
    if [[ -e "${CADDY_COMPOSE_FILE}" ]] && ! cmp -s "${CADDY_COMPOSE_FILE}" "${compose_candidate}"; then
        rm -f -- "${caddy_candidate}" "${compose_candidate}"
        error "The existing Caddy Compose file differs from the appliance-managed configuration; it will not be overwritten."
        return 1
    fi

    if [[ -e "${CADDYFILE}" ]] && cmp -s "${CADDYFILE}" "${caddy_candidate}"; then
        rm -f -- "${caddy_candidate}"
    else
        mv -f -- "${caddy_candidate}" "${CADDYFILE}"
        CADDY_CONFIG_CHANGED=1
    fi
    if [[ -e "${CADDY_COMPOSE_FILE}" ]]; then rm -f -- "${compose_candidate}"; else mv -- "${compose_candidate}" "${CADDY_COMPOSE_FILE}"; fi
    write_access_config_atomic "${ACCESS_FILE}" "${ACCESS_MODE}" "${CADDY_ACCESS_ADDRESS}" || {
        error "Unable to write the appliance access configuration atomically."
        return 1
    }
    access_config_file_is_safe "${ACCESS_FILE}" || {
        error "The appliance access configuration is not root-owned and safely permissioned."
        return 1
    }
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

    if (( CADDY_CONFIG_CHANGED == 1 )); then
        compose up -d --force-recreate caddy
    else
        compose up -d caddy
    fi
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

    if [[ "${ACCESS_MODE}" == mdns ]]; then
        verify_mdns
    fi

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
    if [[ ! -f "${RESTORE_SOURCE}" || -L "${RESTORE_SOURCE}" ]] ||
       ! grep -Fxq '# Vaultwarden Appliance restore' "${RESTORE_SOURCE}"; then
        error "The appliance restore helper is missing or unsafe at ${RESTORE_SOURCE}."
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

    if [[ -e "${RESTORE_TARGET}" &&
          ( ! -f "${RESTORE_TARGET}" || -L "${RESTORE_TARGET}" ) ]]; then
        error "The restore helper target is unsafe: ${RESTORE_TARGET}."
        return 1
    fi
    if [[ -f "${RESTORE_TARGET}" ]] &&
       ! grep -Fxq '# Vaultwarden Appliance restore' "${RESTORE_TARGET}"; then
        error "The existing restore helper is not appliance-managed and will not be overwritten."
        return 1
    fi
    install -m 0755 "${RESTORE_SOURCE}" "${RESTORE_TARGET}"
    if [[ ! -x "${RESTORE_TARGET}" ]]; then
        error "The restore helper was copied but is not executable at ${RESTORE_TARGET}."
        return 1
    fi

    ok "Installed the appliance management command, USB setup, backup, and restore helpers."
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
    section "Phase 5D complete"
    info "Installation directory: ${INSTALL_DIR}"
    info "Compose file: ${INSTALL_DIR}/docker-compose.yml"
    info "Persistent data: ${INSTALL_DIR}/data/vaultwarden"
    info "Docker network: vaultwarden-appliance"
    if [[ "${ACCESS_MODE}" == mdns ]]; then
        info "Access mode: mDNS"
        info "mDNS mapping: ${CADDY_ACCESS_ADDRESS} -> ${IPV4_ADDRESS}"
        info "No local DNS configuration is required; Avahi advertises this name using mDNS."
    else
        info "Access mode: external DNS"
        info "Required DNS mapping: ${CADDY_ACCESS_ADDRESS} -> ${IPV4_ADDRESS}"
        info "The DNS record must be maintained on your local DNS server."
    fi
    info "HTTPS endpoint: https://${CADDY_ACCESS_ADDRESS}"
    info "Vaultwarden DOMAIN: https://${CADDY_ACCESS_ADDRESS}"
    info "Exported root CA: ${EXPORTED_ROOT_CA}"
    info "Management command: ${VWCTL_TARGET}"
    info "Local backups: ${LOCAL_BACKUP_DIR} (newest 7 valid generations)"
    info "Optional USB copies: ${BACKUP_LABEL} backups/ (newest 30 valid generations)"
    info "Automatic backup: daily at 02:30 local time"
    info "Restore command: sudo vwctl restore"
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
    install_usb_setup_support
    install_backup_support

    case "${APPLIANCE_STATE}" in
        fresh|existing) create_appliance_files ;;
        *)
            error "Unexpected or unsafe appliance state '${APPLIANCE_STATE}'."
            return 1
            ;;
    esac

    prompt_for_access_configuration

    if [[ "${ACCESS_MODE}" == mdns ]]; then
        install_mdns_support
        resolve_selected_mdns_conflict
        configure_mdns
    else
        remove_appliance_mdns_configuration
        report_external_dns
    fi

    reconcile_caddy_data_directories
    create_caddy_configuration
    ok "Preserved the existing Caddy persistent CA data."
    report_configured_caddy_access
    reconcile_vaultwarden_configuration
    deploy_vaultwarden
    deploy_caddy
    export_caddy_root_ca
    verify_phase3
    install_appliance_version
    install_vwctl
    configure_local_backup_directory
    reconcile_backup_state_permissions
    install_backup_automation

    print_completion_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
