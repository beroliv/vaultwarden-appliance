#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly SCRIPT_DIR
readonly INSTALL_DIR="/opt/vaultwarden"
readonly APPLIANCE_MARKER="${INSTALL_DIR}/.vaultwarden-appliance"
readonly CADDY_ACCESS_FILE="${INSTALL_DIR}/.caddy-access"
readonly CADDY_HOSTNAME_FILE="${INSTALL_DIR}/.caddy-hostname"
readonly CADDYFILE="${INSTALL_DIR}/Caddyfile"
readonly CADDY_COMPOSE_FILE="${INSTALL_DIR}/docker-compose.override.yml"
readonly CADDY_DATA_DIR="${INSTALL_DIR}/data/caddy/data"
readonly CADDY_CONFIG_DIR="${INSTALL_DIR}/data/caddy/config"
readonly CADDY_ROOT_CA="${CADDY_DATA_DIR}/caddy/pki/authorities/local/root.crt"
readonly EXPORTED_ROOT_CA="${INSTALL_DIR}/certs/caddy-root-ca.crt"
readonly VWCTL_SOURCE="${SCRIPT_DIR}/vwctl"
readonly VWCTL_TARGET="/usr/local/bin/vwctl"
readonly DEFAULT_MDNS_HOSTNAME="vaultwarden.local"
readonly MDNS_ENV_FILE="/etc/default/vaultwarden-appliance-mdns"
readonly MDNS_SERVICE_FILE="/etc/systemd/system/vaultwarden-appliance-mdns.service"
readonly MDNS_SERVICE="vaultwarden-appliance-mdns.service"
readonly MIN_DISK_SPACE_MB=2048

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
CADDY_ACCESS_NEEDS_MIGRATION=0
LEGACY_IP_ADDRESS=""

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

command_exists() {
    command -v "$1" >/dev/null 2>&1
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

check_disk_space() {
    local check_path="/"
    local available_kb
    local available_mb

    section "Disk space"

    if [[ -d /opt ]]; then
        check_path="/opt"
    fi

    available_kb=$(df -Pk "${check_path}" 2>/dev/null | awk 'NR == 2 {print $4}')

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

legacy_phase2_structure_matches() {
    local compose_config
    local images
    local networks
    local services

    [[ -f "${INSTALL_DIR}/docker-compose.yml" ]] || return 1
    [[ -d "${INSTALL_DIR}/data/vaultwarden" ]] || return 1
    command_exists docker || return 1
    docker compose version >/dev/null 2>&1 || return 1

    services=$(docker compose --project-directory "${INSTALL_DIR}" config --services 2>/dev/null) || return 1
    images=$(docker compose --project-directory "${INSTALL_DIR}" config --images 2>/dev/null) || return 1
    networks=$(docker compose --project-directory "${INSTALL_DIR}" config --networks 2>/dev/null) || return 1
    compose_config=$(docker compose --project-directory "${INSTALL_DIR}" config 2>/dev/null) || return 1

    [[ "${services}" == "vaultwarden" ]] || return 1
    [[ "${images}" =~ ^vaultwarden/server(:[^[:space:]]+|@sha256:[[:xdigit:]]+)$ ]] || return 1
    [[ "${networks}" == "appliance" ]] || return 1
    grep -Eq '^[[:space:]]+name:[[:space:]]+vaultwarden-appliance[[:space:]]*$' <<<"${compose_config}"
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

    if legacy_phase2_structure_matches; then
        APPLIANCE_STATE="legacy"
        ok "Legacy Phase 2 appliance installation detected."
        info "A marker will be added after the preflight without changing appliance data or configuration."
        return
    fi

    APPLIANCE_STATE="unknown"
    error "${INSTALL_DIR} exists without a valid appliance marker or recognized Phase 2 structure."
    info "The existing directory will not be modified."
}

validate_local_hostname() {
    local hostname=$1

    (( ${#hostname} <= 69 )) || return 1
    [[ "${hostname}" == "${hostname,,}" ]] || return 1
    [[ "${hostname}" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.local$ ]]
}

validate_ipv4_address() {
    local address=$1
    local octet
    local -a octets

    [[ "${address}" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || return 1
    IFS='.' read -r -a octets <<<"${address}"
    (( ${#octets[@]} == 4 )) || return 1

    for octet in "${octets[@]}"; do
        (( ${#octet} <= 3 )) || return 1
        (( 10#${octet} <= 255 )) || return 1
    done

    [[ "${address}" != "0.0.0.0" && "${address}" != "255.255.255.255" ]]
}

load_caddy_access_state() {
    local address
    local mode
    local -a lines

    mapfile -t lines < "${CADDY_ACCESS_FILE}"

    if (( ${#lines[@]} == 1 )) && [[ "${lines[0]}" == hostname=* ]]; then
        address=${lines[0]#hostname=}
        validate_local_hostname "${address}" || return 1
        CADDY_ACCESS_ADDRESS=${address}
        return 0
    fi

    (( ${#lines[@]} == 2 )) || return 1
    [[ "${lines[0]}" == mode=* && "${lines[1]}" == address=* ]] || return 1
    mode=${lines[0]#mode=}
    address=${lines[1]#address=}

    case "${mode}" in
        hostname)
            if validate_local_hostname "${address}"; then
                CADDY_ACCESS_ADDRESS=${address}
                CADDY_ACCESS_NEEDS_MIGRATION=1
            else
                CADDY_ACCESS_NEEDS_MIGRATION=2
            fi
            ;;
        ip)
            validate_ipv4_address "${address}" || return 1
            LEGACY_IP_ADDRESS=${address}
            CADDY_ACCESS_NEEDS_MIGRATION=2
            ;;
        *)
            return 1
            ;;
    esac
}

create_caddy_access_state() {
    if ! (set -o noclobber; printf 'hostname=%s\n' \
        "${CADDY_ACCESS_ADDRESS}" > "${CADDY_ACCESS_FILE}"); then
        error "Unable to create ${CADDY_ACCESS_FILE}."
        return 1
    fi

    chmod 0644 "${CADDY_ACCESS_FILE}"
}

detect_caddy_configuration() {
    local -a hostname_lines
    local core_files=0

    section "Caddy configuration"

    if [[ -e "${CADDYFILE}" ]]; then
        core_files=$((core_files + 1))
    fi
    if [[ -e "${CADDY_COMPOSE_FILE}" ]]; then
        core_files=$((core_files + 1))
    fi

    if (( core_files == 0 )) && \
       [[ ! -e "${CADDY_ACCESS_FILE}" && ! -e "${CADDY_HOSTNAME_FILE}" ]]; then
        CADDY_STATE="absent"
        info "Caddy is not configured yet."
        return
    fi

    if (( core_files != 2 )) || \
       [[ ! -f "${CADDYFILE}" || -L "${CADDYFILE}" ]] || \
       [[ ! -f "${CADDY_COMPOSE_FILE}" || -L "${CADDY_COMPOSE_FILE}" ]] || \
       [[ ! -d "${CADDY_DATA_DIR}" || ! -d "${CADDY_CONFIG_DIR}" ]]; then
        error "A partial or unrecognized Caddy configuration exists under ${INSTALL_DIR}; it will not be overwritten."
        return
    fi

    if [[ -e "${CADDY_ACCESS_FILE}" ]]; then
        if [[ ! -f "${CADDY_ACCESS_FILE}" || -L "${CADDY_ACCESS_FILE}" ]] || \
           ! load_caddy_access_state; then
            error "The stored Caddy access state is missing or invalid; existing Caddy files will not be changed."
            return
        fi

        if [[ -e "${CADDY_HOSTNAME_FILE}" ]]; then
            if [[ ! -f "${CADDY_HOSTNAME_FILE}" || -L "${CADDY_HOSTNAME_FILE}" ]]; then
                error "The legacy Caddy hostname state is not a regular file; existing Caddy files will not be changed."
                return
            fi
            mapfile -t hostname_lines < "${CADDY_HOSTNAME_FILE}"
            if (( CADDY_ACCESS_NEEDS_MIGRATION == 2 )) || \
               (( ${#hostname_lines[@]} != 1 )) || \
               [[ "${hostname_lines[0]}" != "${CADDY_ACCESS_ADDRESS}" ]]; then
                error "The current and legacy Caddy access state disagree; existing Caddy files will not be changed."
                return
            fi
            CADDY_ACCESS_NEEDS_MIGRATION=1
        fi
    else
        if [[ ! -f "${CADDY_HOSTNAME_FILE}" || -L "${CADDY_HOSTNAME_FILE}" ]]; then
            error "The stored Caddy access state is missing or invalid; existing Caddy files will not be changed."
            return
        fi

        mapfile -t hostname_lines < "${CADDY_HOSTNAME_FILE}"
        if (( ${#hostname_lines[@]} != 1 )); then
            error "The stored Caddy hostname is missing or invalid; existing Caddy files will not be changed."
            return
        fi

        if validate_local_hostname "${hostname_lines[0]}"; then
            CADDY_ACCESS_ADDRESS=${hostname_lines[0]}
            CADDY_ACCESS_NEEDS_MIGRATION=1
            info "Legacy hostname access state detected; its .local HTTPS address will be preserved."
        else
            CADDY_ACCESS_NEEDS_MIGRATION=2
        fi
    fi

    CADDY_STATE="configured"
    ok "Existing Caddy configuration detected."
    if (( CADDY_ACCESS_NEEDS_MIGRATION == 2 )); then
        info "The existing non-mDNS access configuration will be migrated to a .local hostname."
        [[ -z "${LEGACY_IP_ADDRESS}" ]] || info "Previous IP HTTPS address: ${LEGACY_IP_ADDRESS}"
    else
        info "Configured HTTPS URL: https://${CADDY_ACCESS_ADDRESS}"
    fi
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

port_is_in_use() {
    local port=$1
    local port_hex

    if command_exists ss; then
        ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .
        return
    fi

    if command_exists netstat; then
        netstat -ltn 2>/dev/null | awk -v port=":${port}" '$4 ~ port "$" {found=1} END {exit !found}'
        return
    fi

    printf -v port_hex '%04X' "${port}"
    awk -v port_hex="${port_hex}" '
        $4 == "0A" {
            split($2, address, ":")
            if (address[2] == port_hex) {
                found=1
            }
        }
        END {exit !found}
    ' /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

caddy_owns_port_443() {
    [[ "${CADDY_STATE}" == "configured" ]] || return 1
    docker inspect --format '{{with (index .HostConfig.PortBindings "443/tcp")}}{{range .}}{{println .HostPort}}{{end}}{{end}}' caddy 2>/dev/null |
        grep -Fxq 443
}

container_is_connected_to_network() {
    local container=$1
    local network=$2

    docker inspect --format '{{range $name, $settings := .NetworkSettings.Networks}}{{println $name}}{{end}}' "${container}" 2>/dev/null |
        grep -Fxq "${network}"
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

detect_ipv4_address() {
    local candidate=""

    section "Network configuration"

    if command_exists ip; then
        candidate=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}')
    fi

    if [[ -z "${candidate}" ]] && command_exists hostname; then
        candidate=$(hostname -I 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+\./) {print $i; exit}}')
    fi

    if [[ -n "${candidate}" ]]; then
        IPV4_ADDRESS=${candidate}
        ok "Detected IPv4 address: ${IPV4_ADDRESS}"
    else
        warn "No usable IPv4 address could be detected automatically."
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

    canonical_user=$(getent passwd "${candidate_uid}" | awk -F: 'NR == 1 {print $1}')
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

create_appliance_files() {
    section "Appliance files"

    if [[ -e "${INSTALL_DIR}" ]]; then
        error "${INSTALL_DIR} appeared during installation; refusing to overwrite it."
        return 1
    fi

    install -d -m 0755 "${INSTALL_DIR}"
    install -d -m 0700 "${INSTALL_DIR}/data/vaultwarden"

    cat > "${INSTALL_DIR}/docker-compose.yml" <<'COMPOSE'
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
    chmod 0644 "${INSTALL_DIR}/docker-compose.yml"
    create_appliance_marker
    ok "Created appliance files, persistent data directory, and marker."
}

deploy_vaultwarden() {
    section "Vaultwarden deployment"

    if ! docker compose --project-directory "${INSTALL_DIR}" config --quiet; then
        error "The generated Docker Compose configuration is invalid."
        return 1
    fi

    docker compose --project-directory "${INSTALL_DIR}" pull vaultwarden
    docker compose --project-directory "${INSTALL_DIR}" up -d vaultwarden

    if [[ "$(docker inspect --format '{{.State.Running}}' vaultwarden 2>/dev/null)" != "true" ]]; then
        error "Vaultwarden was created but is not running. Inspect it with: docker logs vaultwarden"
        return 1
    fi

    ok "Vaultwarden is running without a host-published HTTP port."
}

package_is_installed() {
    dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null | grep -q '^ii '
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
    command_exists avahi-set-host-name || {
        error "avahi-set-host-name is unavailable after package installation."
        return 1
    }

    systemctl enable --now avahi-daemon.service
    systemctl is-active --quiet avahi-daemon.service || {
        error "Avahi did not become active."
        return 1
    }
    ok "Avahi is installed and active."
}

mdns_resolved_ipv4s() {
    local hostname=$1

    timeout 4 avahi-resolve-host-name -4 "${hostname}" 2>/dev/null |
        awk 'NF >= 2 {print $2}'
}

mdns_name_conflicts() {
    local hostname=$1
    local resolved=""

    resolved=$(mdns_resolved_ipv4s "${hostname}" || true)
    [[ -n "${resolved}" ]] || return 1
    grep -Fxq "${IPV4_ADDRESS}" <<<"${resolved}" && return 1
    return 0
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
    local default_hostname=${1:-${DEFAULT_MDNS_HOSTNAME}}
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
    local label=${CADDY_ACCESS_ADDRESS%.local}

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

    cat > "${MDNS_ENV_FILE}" <<ENV
# Vaultwarden Appliance mDNS
VAULTWARDEN_MDNS_LABEL=${label}
ENV
    chmod 0644 "${MDNS_ENV_FILE}"

    cat > "${MDNS_SERVICE_FILE}" <<'SERVICE'
# Vaultwarden Appliance mDNS
[Unit]
Description=Advertise the Vaultwarden Appliance mDNS hostname
Requires=avahi-daemon.service
After=avahi-daemon.service
PartOf=avahi-daemon.service

[Service]
Type=oneshot
EnvironmentFile=/etc/default/vaultwarden-appliance-mdns
ExecStart=/usr/bin/avahi-set-host-name ${VAULTWARDEN_MDNS_LABEL}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE
    chmod 0644 "${MDNS_SERVICE_FILE}"

    systemctl daemon-reload
    systemctl enable "${MDNS_SERVICE}"
    systemctl restart "${MDNS_SERVICE}"
}

verify_mdns() {
    local _attempt
    local resolved=""

    systemctl is-active --quiet avahi-daemon.service || {
        error "Avahi is not active."
        return 1
    }
    systemctl is-active --quiet "${MDNS_SERVICE}" || {
        error "The appliance mDNS hostname service is not active."
        return 1
    }

    for _attempt in {1..30}; do
        resolved=$(mdns_resolved_ipv4s "${CADDY_ACCESS_ADDRESS}" || true)
        grep -Fxq "${IPV4_ADDRESS}" <<<"${resolved}" && {
            ok "mDNS resolves ${CADDY_ACCESS_ADDRESS} to ${IPV4_ADDRESS}."
            return 0
        }
        sleep 1
    done

    error "mDNS did not resolve ${CADDY_ACCESS_ADDRESS} to the detected LAN IPv4 address ${IPV4_ADDRESS}."
    [[ -z "${resolved}" ]] || info "Resolved IPv4 address(es): ${resolved//$'\n'/, }"
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

write_caddyfile_to() {
    local destination=$1

    cat > "${destination}" <<CADDY
{
	auto_https disable_redirects
}

https://${CADDY_ACCESS_ADDRESS} {
	tls internal
	reverse_proxy vaultwarden:80
}
CADDY
    chmod 0644 "${destination}"
}

store_caddy_access_state() {
    local candidate

    candidate=$(mktemp "${INSTALL_DIR}/.caddy-access.install.XXXXXXXX") || return 1
    if ! printf 'hostname=%s\n' "${CADDY_ACCESS_ADDRESS}" > "${candidate}" ||
       ! chmod 0644 "${candidate}" ||
       ! mv -f -- "${candidate}" "${CADDY_ACCESS_FILE}" ||
       ! rm -f -- "${CADDY_HOSTNAME_FILE}"; then
        rm -f -- "${candidate}"
        return 1
    fi
}

migrate_caddy_to_mdns() {
    local caddy_candidate
    local root_hash_after=""
    local root_hash_before=""
    local state_candidate

    section "Hostname-only access migration"
    command_exists sha256sum || {
        error "sha256sum is required to verify preservation of Caddy's root CA."
        return 1
    }
    if [[ -e "${CADDY_ROOT_CA}" && \
          ( ! -f "${CADDY_ROOT_CA}" || -L "${CADDY_ROOT_CA}" ) ]]; then
        error "Caddy's root CA path exists but is not a safe regular file."
        return 1
    fi
    if [[ -f "${CADDY_ROOT_CA}" && ! -L "${CADDY_ROOT_CA}" ]]; then
        root_hash_before=$(sha256sum -- "${CADDY_ROOT_CA}" | awk 'NR == 1 {print $1}')
    fi

    caddy_candidate=$(mktemp "${INSTALL_DIR}/.Caddyfile.install.XXXXXXXX") || return 1
    state_candidate=$(mktemp "${INSTALL_DIR}/.caddy-access.install.XXXXXXXX") || {
        rm -f -- "${caddy_candidate}"
        return 1
    }
    if ! write_caddyfile_to "${caddy_candidate}" ||
       ! printf 'hostname=%s\n' "${CADDY_ACCESS_ADDRESS}" > "${state_candidate}" ||
       ! chmod 0644 "${state_candidate}"; then
        rm -f -- "${caddy_candidate}" "${state_candidate}"
        error "Unable to generate the hostname-only Caddy configuration."
        return 1
    fi

    info "Stopping and removing only the Caddy container. Vaultwarden remains running."
    docker compose --project-directory "${INSTALL_DIR}" rm --stop --force caddy
    mv -f -- "${caddy_candidate}" "${CADDYFILE}"
    mv -f -- "${state_candidate}" "${CADDY_ACCESS_FILE}"
    rm -f -- "${CADDY_HOSTNAME_FILE}"

    docker compose --project-directory "${INSTALL_DIR}" config --quiet
    docker compose --project-directory "${INSTALL_DIR}" up -d --no-deps caddy

    if [[ -n "${root_hash_before}" ]]; then
        root_hash_after=$(sha256sum -- "${CADDY_ROOT_CA}" 2>/dev/null | awk 'NR == 1 {print $1}')
        if [[ "${root_hash_after}" != "${root_hash_before}" ]]; then
            error "Caddy's persistent internal root CA changed unexpectedly during migration."
            return 1
        fi
        ok "Caddy's persistent internal root CA was preserved."
    fi

    CADDY_ACCESS_NEEDS_MIGRATION=0
    ok "Migrated Caddy to hostname-only access at https://${CADDY_ACCESS_ADDRESS}."
}

create_caddy_configuration() {
    section "Caddy configuration"

    if [[ -e "${CADDY_ACCESS_FILE}" || -e "${CADDY_HOSTNAME_FILE}" || \
          -e "${CADDYFILE}" || -e "${CADDY_COMPOSE_FILE}" ]]; then
        error "Caddy configuration paths appeared during installation; refusing to overwrite them."
        return 1
    fi

    install -d -m 0700 "${CADDY_DATA_DIR}" "${CADDY_CONFIG_DIR}"

    if ! write_caddyfile_to "${CADDYFILE}"; then
        error "Unable to create ${CADDYFILE}."
        return 1
    fi

    if ! (set -o noclobber; cat > "${CADDY_COMPOSE_FILE}" <<'COMPOSE'
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
    ); then
        error "Unable to create ${CADDY_COMPOSE_FILE}."
        return 1
    fi

    chmod 0644 "${CADDYFILE}" "${CADDY_COMPOSE_FILE}"
    create_caddy_access_state
    CADDY_STATE="configured"
    ok "Created Caddy configuration for https://${CADDY_ACCESS_ADDRESS}."
}

deploy_caddy() {
    section "Caddy deployment"

    if ! docker compose --project-directory "${INSTALL_DIR}" config --quiet; then
        error "The combined Vaultwarden and Caddy Compose configuration is invalid."
        return 1
    fi

    if ! docker compose --project-directory "${INSTALL_DIR}" config --services | grep -Fxq caddy; then
        error "The combined Compose configuration does not contain the Caddy service."
        return 1
    fi

    if ! docker image inspect caddy:2 >/dev/null 2>&1; then
        docker compose --project-directory "${INSTALL_DIR}" pull caddy
    fi

    docker compose --project-directory "${INSTALL_DIR}" up -d caddy
    ok "Caddy deployment requested without publishing TCP port 80."
}

export_caddy_root_ca() {
    local _attempt

    section "Caddy root CA export"

    for _attempt in {1..30}; do
        [[ -f "${CADDY_ROOT_CA}" ]] && break
        sleep 1
    done

    if [[ ! -f "${CADDY_ROOT_CA}" ]]; then
        error "Caddy did not create its internal root CA certificate at ${CADDY_ROOT_CA}."
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
        install -m 0644 "${CADDY_ROOT_CA}" "${EXPORTED_ROOT_CA}"
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

    if [[ "$(docker inspect --format '{{.State.Running}}' vaultwarden 2>/dev/null)" != "true" ]]; then
        error "Vaultwarden is not running."
        return 1
    fi
    ok "Vaultwarden container is running."

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

    if [[ -e "${VWCTL_TARGET}" ]]; then
        if [[ ! -f "${VWCTL_TARGET}" || -L "${VWCTL_TARGET}" ]] || \
           ! grep -Fxq '# Vaultwarden Appliance vwctl' "${VWCTL_TARGET}"; then
            error "${VWCTL_TARGET} already exists but is not recognized as appliance-managed; it will not be overwritten."
            return 1
        fi
    fi

    install -d -m 0755 /usr/local/bin
    install -m 0755 "${VWCTL_SOURCE}" "${VWCTL_TARGET}"
    if [[ ! -x "${VWCTL_TARGET}" ]]; then
        error "vwctl was copied but is not executable at ${VWCTL_TARGET}."
        return 1
    fi

    ok "Installed the appliance management command at ${VWCTL_TARGET}."
}

print_completion_summary() {
    section "Phase 4 complete"
    info "Installation directory: ${INSTALL_DIR}"
    info "Compose file: ${INSTALL_DIR}/docker-compose.yml"
    info "Persistent data: ${INSTALL_DIR}/data/vaultwarden"
    info "Docker network: vaultwarden-appliance"
    info "Access: local mDNS hostname"
    info "HTTPS endpoint: https://${CADDY_ACCESS_ADDRESS}"
    info "mDNS mapping: ${CADDY_ACCESS_ADDRESS} -> ${IPV4_ADDRESS}"
    info "No local DNS configuration is required; Avahi advertises this name using mDNS."
    info "Exported root CA: ${EXPORTED_ROOT_CA}"
    info "Management command: ${VWCTL_TARGET}"
    info "Vaultwarden remains internal-only; only Caddy publishes host TCP port 443."
    if [[ "${APPLIANCE_STATE}" == "existing" || "${APPLIANCE_STATE}" == "legacy" ]]; then
        info "Existing appliance files and any existing Vaultwarden container were left unchanged."
    fi
    if (( DOCKER_GROUP_CHANGED == 1 )); then
        info "User '${DOCKER_USER}' must start a new login session or reboot before using Docker without sudo."
    fi
}

main() {
    printf 'Vaultwarden Appliance - Phase 4 installer\n'

    check_operating_system
    check_architecture
    check_disk_space
    check_docker
    check_existing_installation
    detect_caddy_configuration
    check_ports
    detect_ipv4_address
    print_preflight_summary

    require_root
    detect_docker_user

    if (( DOCKER_READY == 0 )); then
        confirm_docker_installation
        install_docker
        verify_docker
    fi

    configure_docker_group
    install_mdns_support

    case "${APPLIANCE_STATE}" in
        fresh)
            create_appliance_files
            deploy_vaultwarden
            ;;
        legacy)
            create_appliance_marker
            ok "Legacy Phase 2 installation adopted as a Vaultwarden Appliance."
            ;;
        existing)
            info "Skipping appliance file creation and Vaultwarden deployment on this rerun."
            ;;
        *)
            error "Unexpected appliance state '${APPLIANCE_STATE}'."
            return 1
            ;;
    esac

    if [[ "${CADDY_STATE}" == "absent" ]]; then
        prompt_for_local_hostname
        configure_mdns
        create_caddy_configuration
    else
        if (( CADDY_ACCESS_NEEDS_MIGRATION == 2 )); then
            CADDY_ACCESS_ADDRESS=${DEFAULT_MDNS_HOSTNAME}
            if mdns_name_conflicts "${CADDY_ACCESS_ADDRESS}"; then
                warn "The default mDNS name ${CADDY_ACCESS_ADDRESS} is already in use."
                prompt_for_local_hostname
            else
                info "Migrating existing access automatically to https://${CADDY_ACCESS_ADDRESS}."
            fi
            configure_mdns
            migrate_caddy_to_mdns
        else
            if mdns_name_conflicts "${CADDY_ACCESS_ADDRESS}"; then
                warn "The configured mDNS name ${CADDY_ACCESS_ADDRESS} is advertised by another LAN device."
                CADDY_ACCESS_NEEDS_MIGRATION=2
                prompt_for_local_hostname "${CADDY_ACCESS_ADDRESS}"
                configure_mdns
                migrate_caddy_to_mdns
            else
                configure_mdns
                if (( CADDY_ACCESS_NEEDS_MIGRATION == 1 )); then
                    store_caddy_access_state || {
                        error "Unable to migrate the legacy hostname state file."
                        return 1
                    }
                    CADDY_ACCESS_NEEDS_MIGRATION=0
                    ok "Stored the existing .local hostname in the hostname-only access state."
                fi
            fi
        fi
        report_configured_caddy_access
    fi

    deploy_caddy
    export_caddy_root_ca
    verify_phase3
    install_vwctl

    print_completion_summary
}

main "$@"
