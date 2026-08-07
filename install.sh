#!/usr/bin/env bash

set -o nounset
set -o pipefail

readonly INSTALL_DIR="/opt/vaultwarden"
readonly MIN_DISK_SPACE_MB=2048

ERRORS=0
WARNINGS=0
OS_NAME="unknown"
OS_ID="unknown"
OS_VERSION="unknown"
ARCH="unknown"
IPV4_ADDRESS="not detected"

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

check_existing_installation() {
    section "Installation path"

    if [[ -e "${INSTALL_DIR}" ]]; then
        error "${INSTALL_DIR} already exists; it will not be modified or overwritten."
    else
        ok "${INSTALL_DIR} does not already exist."
    fi
}

check_docker() {
    local compose_found=0

    section "Docker"

    if ! command_exists docker; then
        error "Docker is not installed. Phase 1 only reports this and will not install it."
        info "Docker Compose and daemon checks cannot run without Docker."
        return
    fi

    ok "Docker is installed: $(docker --version 2>/dev/null || printf 'version unknown')"

    if docker compose version >/dev/null 2>&1; then
        ok "Docker Compose plugin is available: $(docker compose version --short 2>/dev/null || docker compose version 2>/dev/null)"
        compose_found=1
    elif command_exists docker-compose && docker-compose version >/dev/null 2>&1; then
        ok "Legacy docker-compose is available: $(docker-compose version --short 2>/dev/null || docker-compose version 2>/dev/null)"
        compose_found=1
    fi

    if (( compose_found == 0 )); then
        error "Docker Compose is not available ('docker compose' or 'docker-compose')."
    fi

    if docker info >/dev/null 2>&1; then
        ok "Docker daemon is running and accessible; the installer will not modify Docker."
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

print_summary() {
    section "Phase 1 summary"
    info "Installation target: ${INSTALL_DIR}"
    info "System: ${OS_NAME} (${OS_ID} ${OS_VERSION}), ${ARCH}"
    info "IPv4 address: ${IPV4_ADDRESS}"
    info "No system changes were made."

    if (( ERRORS > 0 )); then
        printf '\nPreflight failed with %d error(s) and %d warning(s).\n' "${ERRORS}" "${WARNINGS}" >&2
        return 1
    fi

    printf '\nPreflight passed with %d warning(s). Phase 1 is complete.\n' "${WARNINGS}"
}

main() {
    printf 'Vaultwarden Appliance - Phase 1 preflight\n'
    printf 'This version performs read-only checks and does not install anything.\n'

    check_operating_system
    check_architecture
    check_disk_space
    check_existing_installation
    check_docker
    check_ports
    detect_ipv4_address
    print_summary
}

main "$@"
