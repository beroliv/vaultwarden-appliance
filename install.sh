#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

readonly INSTALL_DIR="/opt/vaultwarden"
readonly APPLIANCE_MARKER="${INSTALL_DIR}/.vaultwarden-appliance"
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

check_ports() {
    local port=443

    section "Network ports"

    if port_is_in_use "${port}"; then
        error "TCP port ${port} is already in use."
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
        error "Phase 2 installation must run as root. Re-run with sudo."
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

print_completion_summary() {
    section "Phase 2 complete"
    info "Installation directory: ${INSTALL_DIR}"
    info "Compose file: ${INSTALL_DIR}/docker-compose.yml"
    info "Persistent data: ${INSTALL_DIR}/data/vaultwarden"
    info "Docker network: vaultwarden-appliance"
    info "Vaultwarden is internal-only; Caddy and HTTPS are not configured yet."
    if [[ "${APPLIANCE_STATE}" == "existing" || "${APPLIANCE_STATE}" == "legacy" ]]; then
        info "Existing appliance files and any existing Vaultwarden container were left unchanged."
    fi
    if (( DOCKER_GROUP_CHANGED == 1 )); then
        info "User '${DOCKER_USER}' must start a new login session or reboot before using Docker without sudo."
    fi
}

main() {
    printf 'Vaultwarden Appliance - Phase 2 installer\n'

    check_operating_system
    check_architecture
    check_disk_space
    check_docker
    check_existing_installation
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

    print_completion_summary
}

main "$@"
