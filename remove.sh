#!/usr/bin/env bash
# Vaultwarden Appliance uninstaller

set -o nounset
set -o pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly SCRIPT_DIR
readonly COMMON_LIBRARY="${SCRIPT_DIR}/lib/common.sh"

if [[ ! -f "${COMMON_LIBRARY}" || -L "${COMMON_LIBRARY}" ]]; then
    printf 'Error: Required appliance library is missing or unsafe: %s\n' \
        "${COMMON_LIBRARY}" >&2
    exit 1
fi
# shellcheck source=/dev/null
. "${COMMON_LIBRARY}"

readonly INSTALL_DIR="/opt/vaultwarden"
readonly APPLIANCE_MARKER="${INSTALL_DIR}/.vaultwarden-appliance"
readonly OPERATION_LOCK="/run/lock/vaultwarden-appliance.lock"
readonly COMPOSE_PROJECT="vaultwarden"
readonly APPLIANCE_NETWORK="vaultwarden-appliance"
readonly APPLIANCE_NETWORK_KEY="appliance"
readonly VWCTL_FILE="/usr/local/bin/vwctl"
readonly USB_SETUP_FILE="/usr/local/libexec/vaultwarden-appliance-usb-setup"
readonly BACKUP_FILE="/usr/local/libexec/vaultwarden-appliance-backup"
readonly MDNS_WRAPPER_FILE="/usr/local/libexec/vaultwarden-appliance-mdns"
readonly LIBRARY_DIR="/usr/local/lib/vaultwarden-appliance"
readonly MDNS_ENV_FILE="/etc/default/vaultwarden-appliance-mdns"
readonly MDNS_SERVICE_FILE="/etc/systemd/system/vaultwarden-appliance-mdns.service"
readonly BACKUP_SERVICE_FILE="/etc/systemd/system/vaultwarden-appliance-backup.service"
readonly BACKUP_TIMER_FILE="/etc/systemd/system/vaultwarden-appliance-backup.timer"
readonly MDNS_SERVICE="vaultwarden-appliance-mdns.service"
readonly BACKUP_SERVICE="vaultwarden-appliance-backup.service"
readonly BACKUP_TIMER="vaultwarden-appliance-backup.timer"
readonly CONFIRMATION_TEXT="REMOVE VAULTWARDEN"

readonly -a INSTALLED_FILES=(
    "${VWCTL_FILE}|# Vaultwarden Appliance vwctl"
    "${USB_SETUP_FILE}|# Vaultwarden Appliance USB setup"
    "${BACKUP_FILE}|# Vaultwarden Appliance manual backup"
    "${MDNS_WRAPPER_FILE}|# Vaultwarden Appliance mDNS publisher"
    "${MDNS_ENV_FILE}|# Vaultwarden Appliance mDNS"
    "${MDNS_SERVICE_FILE}|# Vaultwarden Appliance mDNS"
    "${BACKUP_SERVICE_FILE}|# Vaultwarden Appliance automatic backup"
    "${BACKUP_TIMER_FILE}|# Vaultwarden Appliance automatic backup"
)
readonly -a INSTALLED_LIBRARIES=(
    "${LIBRARY_DIR}/common.sh|command_exists() {"
    "${LIBRARY_DIR}/network.sh|detect_ipv4_address() {"
    "${LIBRARY_DIR}/docker.sh|container_exists() {"
    "${LIBRARY_DIR}/caddy.sh|write_caddyfile_to() {"
    "${LIBRARY_DIR}/mdns.sh|mdns_resolved_ipv4s() {"
    "${LIBRARY_DIR}/storage.sh|storage_collect_topology() {"
)
readonly -a SYSTEMD_UNITS=(
    "${MDNS_SERVICE}|${MDNS_SERVICE_FILE}|# Vaultwarden Appliance mDNS"
    "${BACKUP_SERVICE}|${BACKUP_SERVICE_FILE}|# Vaultwarden Appliance automatic backup"
    "${BACKUP_TIMER}|${BACKUP_TIMER_FILE}|# Vaultwarden Appliance automatic backup"
)

REMOVAL_ERRORS=0
DOCKER_COMPOSE_VERSION_BEFORE=""
DOCKER_VERSION_BEFORE=""
AVAHI_STATE_BEFORE=""

remove_info() {
    printf '[INFO] %s\n' "$*"
}

remove_ok() {
    printf '[ OK ] %s\n' "$*"
}

remove_error() {
    printf 'Error: %s\n' "$*" >&2
}

remove_record_error() {
    remove_error "$*"
    REMOVAL_ERRORS=$((REMOVAL_ERRORS + 1))
}

remove_is_root() {
    (( EUID == 0 ))
}

remove_require_root() {
    if ! remove_is_root; then
        printf 'This operation requires root privileges.\n' >&2
        printf 'Run:\n' >&2
        printf 'sudo ./remove.sh\n' >&2
        return 1
    fi
}

remove_acquire_lock() {
    local result

    if acquire_appliance_lock "${OPERATION_LOCK}"; then
        return 0
    else
        result=$?
    fi
    case "${result}" in
        1) remove_error "Another Vaultwarden Appliance operation is already running." ;;
        2) remove_error "flock is required for appliance removal." ;;
        *) remove_error "Unable to create the root-owned appliance operation lock at ${OPERATION_LOCK}." ;;
    esac
    return 1
}

remove_path_owner() {
    stat -c '%u' "$1" 2>/dev/null
}

remove_path_permissions() {
    stat -c '%a' "$1" 2>/dev/null
}

remove_validate_appliance() {
    local directory=$1
    local marker=$2
    local expected_directory=$3
    local directory_owner
    local directory_permissions
    local marker_owner
    local marker_permissions
    local resolved
    local -a marker_lines=()

    [[ "${directory}" == "${expected_directory}" && "${expected_directory}" == /* &&
       "${expected_directory}" != "/" ]] || return 1
    [[ -d "${directory}" && ! -L "${directory}" ]] || return 1
    resolved=$(readlink -f -- "${directory}" 2>/dev/null) || return 1
    [[ "${resolved}" == "${expected_directory}" ]] || return 1
    [[ "${marker}" == "${directory}/.vaultwarden-appliance" &&
       -f "${marker}" && ! -L "${marker}" ]] || return 1
    directory_owner=$(remove_path_owner "${directory}") || return 1
    directory_permissions=$(remove_path_permissions "${directory}") || return 1
    marker_owner=$(remove_path_owner "${marker}") || return 1
    marker_permissions=$(remove_path_permissions "${marker}") || return 1
    [[ "${directory_owner}" == "0" && "${marker_owner}" == "0" &&
       "${directory_permissions}" =~ ^[0-7]{3,4}$ &&
       "${marker_permissions}" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#${directory_permissions} & 8#022) == 0 )) || return 1
    (( (8#${marker_permissions} & 8#022) == 0 )) || return 1
    mapfile -t marker_lines < "${marker}" || return 1
    (( ${#marker_lines[@]} == 1 )) || return 1
    [[ "${marker_lines[0]}" == "Vaultwarden Appliance" ]]
}

remove_docker() {
    docker "$@"
}

remove_systemctl() {
    systemctl "$@"
}

remove_unit_active_state() {
    local state

    state=$(remove_systemctl show "$1" --property=ActiveState --value 2>/dev/null) || return 2
    case "${state}" in
        active|activating|reloading|deactivating) return 0 ;;
        inactive|failed|'') return 1 ;;
        *) return 2 ;;
    esac
}

remove_unit_property() {
    remove_systemctl show "$1" --property="$2" --value 2>/dev/null
}

remove_unit_enabled_state() {
    local state
    local result=0

    state=$(remove_systemctl is-enabled "$1" 2>/dev/null) || result=$?
    case "${state}" in
        enabled|enabled-runtime|linked|linked-runtime|alias) return 0 ;;
        disabled|static|indirect|masked|masked-runtime|generated|transient|not-found|'')
            (( result == 0 || result == 1 || result == 3 || result == 4 )) && return 1
            ;;
    esac
    return 2
}

remove_unit_is_inactive() {
    local result

    if remove_unit_active_state "$1"; then
        return 1
    else
        result=$?
    fi
    (( result == 1 ))
}

remove_unit_is_disabled() {
    local result

    if remove_unit_enabled_state "$1"; then
        return 1
    else
        result=$?
    fi
    (( result == 1 ))
}

remove_unit_is_absent() {
    local load_state

    load_state=$(remove_unit_property "$1" LoadState) || return 2
    [[ "${load_state}" == "not-found" || -z "${load_state}" ]]
}

remove_container_exists() {
    local output

    output=$(remove_docker container ls --all --format '{{.Names}}' 2>/dev/null) || return 2
    grep -Fxq -- "$1" <<<"${output}"
}

remove_network_exists() {
    local output

    output=$(remove_docker network ls --format '{{.Name}}' 2>/dev/null) || return 2
    grep -Fxq -- "$1" <<<"${output}"
}

remove_container_is_absent() {
    local result

    if remove_container_exists "$1"; then
        return 1
    else
        result=$?
    fi
    (( result == 1 ))
}

remove_network_is_absent() {
    local result

    if remove_network_exists "$1"; then
        return 1
    else
        result=$?
    fi
    (( result == 1 ))
}

remove_container_label() {
    local container=$1
    local label=$2

    remove_docker container inspect --format "{{ index .Config.Labels \"${label}\" }}" \
        "${container}" 2>/dev/null
}

remove_network_label() {
    local network=$1
    local label=$2

    remove_docker network inspect --format "{{ index .Labels \"${label}\" }}" \
        "${network}" 2>/dev/null
}

remove_container_is_owned() {
    local container=$1
    local service=$2
    local project
    local actual_service
    local working_directory

    project=$(remove_container_label "${container}" com.docker.compose.project) || return 1
    actual_service=$(remove_container_label "${container}" com.docker.compose.service) || return 1
    working_directory=$(remove_container_label \
        "${container}" com.docker.compose.project.working_dir) || return 1
    [[ "${project}" == "${COMPOSE_PROJECT}" &&
       "${actual_service}" == "${service}" &&
       "${working_directory}" == "${INSTALL_DIR}" ]]
}

remove_network_is_owned() {
    local network=$1
    local project
    local network_key

    project=$(remove_network_label "${network}" com.docker.compose.project) || return 1
    network_key=$(remove_network_label "${network}" com.docker.compose.network) || return 1
    [[ "${project}" == "${COMPOSE_PROJECT}" &&
       "${network_key}" == "${APPLIANCE_NETWORK_KEY}" ]]
}

remove_validate_docker_resources() {
    local container
    local result
    local service

    for container in vaultwarden caddy; do
        service=${container}
        if remove_container_exists "${container}"; then
            remove_container_is_owned "${container}" "${service}" || {
                remove_error "Docker container '${container}' exists but is not positively identified as appliance-owned."
                return 1
            }
        else
            result=$?
            (( result == 1 )) || {
                remove_error "Unable to determine whether Docker container '${container}' exists."
                return 1
            }
        fi
    done
    if remove_network_exists "${APPLIANCE_NETWORK}"; then
        remove_network_is_owned "${APPLIANCE_NETWORK}" || {
            remove_error "Docker network '${APPLIANCE_NETWORK}' exists but is not positively identified as appliance-owned."
            return 1
        }
    else
        result=$?
        (( result == 1 )) || {
            remove_error "Unable to determine whether Docker network '${APPLIANCE_NETWORK}' exists."
            return 1
        }
    fi
}

remove_validate_owned_file() {
    local path=$1
    local marker=$2
    local owner
    local permissions

    [[ ! -e "${path}" && ! -L "${path}" ]] && return 0
    [[ -f "${path}" && ! -L "${path}" ]] || return 1
    owner=$(remove_path_owner "${path}") || return 1
    permissions=$(remove_path_permissions "${path}") || return 1
    [[ "${owner}" == "0" && "${permissions}" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#${permissions} & 8#022) == 0 )) || return 1
    grep -Fxq -- "${marker}" "${path}"
}

remove_validate_installed_files() {
    local entry
    local marker
    local owner
    local path
    local permissions

    if [[ -e "${LIBRARY_DIR}" || -L "${LIBRARY_DIR}" ]]; then
        [[ -d "${LIBRARY_DIR}" && ! -L "${LIBRARY_DIR}" ]] || {
            remove_error "Installed appliance library path is unsafe: ${LIBRARY_DIR}."
            return 1
        }
        owner=$(remove_path_owner "${LIBRARY_DIR}") || return 1
        permissions=$(remove_path_permissions "${LIBRARY_DIR}") || return 1
        [[ "${owner}" == "0" && "${permissions}" =~ ^[0-7]{3,4}$ ]] || return 1
        (( (8#${permissions} & 8#022) == 0 )) || return 1
    fi
    for entry in "${INSTALLED_FILES[@]}" "${INSTALLED_LIBRARIES[@]}"; do
        IFS='|' read -r path marker <<<"${entry}"
        remove_validate_owned_file "${path}" "${marker}" || {
            remove_error "Installed path exists but is not positively identified as appliance-owned: ${path}."
            return 1
        }
    done
}

remove_validate_systemd_units() {
    local entry
    local fragment_path
    local load_state
    local marker
    local path
    local unit

    for entry in "${SYSTEMD_UNITS[@]}"; do
        IFS='|' read -r unit path marker <<<"${entry}"
        load_state=$(remove_unit_property "${unit}" LoadState) || {
            remove_error "Unable to determine systemd ownership for ${unit}."
            return 1
        }
        if [[ "${load_state}" == "not-found" || -z "${load_state}" ]]; then
            continue
        fi
        fragment_path=$(remove_unit_property "${unit}" FragmentPath) || return 1
        if [[ "${fragment_path}" != "${path}" ]] ||
           ! remove_validate_owned_file "${path}" "${marker}"; then
            remove_error "Systemd unit '${unit}' is not positively identified as appliance-owned."
            return 1
        fi
    done
}

remove_require_runtime() {
    local command

    for command in docker systemctl flock stat readlink grep rm rmdir; do
        command_exists "${command}" || {
            remove_error "Required removal command '${command}' is unavailable."
            return 1
        }
    done
    remove_docker info >/dev/null 2>&1 || {
        remove_error "The Docker daemon is unavailable; container ownership cannot be verified."
        return 1
    }
    remove_systemctl list-unit-files --no-legend >/dev/null 2>&1 || {
        remove_error "systemd state is unavailable; appliance service ownership cannot be managed safely."
        return 1
    }
    DOCKER_VERSION_BEFORE=$(remove_docker --version 2>/dev/null) || return 1
    if DOCKER_COMPOSE_VERSION_BEFORE=$(remove_docker compose version 2>/dev/null); then
        :
    else
        DOCKER_COMPOSE_VERSION_BEFORE=unavailable
    fi
    if AVAHI_STATE_BEFORE=$(remove_systemctl is-active avahi-daemon.service 2>/dev/null); then
        :
    else
        AVAHI_STATE_BEFORE=inactive
    fi
}

remove_show_warning() {
    cat <<'WARNING'
Vaultwarden Appliance removal

WARNING: This permanently removes the Vaultwarden Appliance from this system.

The following appliance-owned data will be deleted:

  - Vaultwarden container and persistent data
  - Vaultwarden database, attachments, sends and keys
  - Caddy container and persistent data
  - Caddy internal CA and private keys
  - Exported root CA
  - Local backups in /opt/vaultwarden/backups
  - Appliance configuration and state
  - Appliance systemd units
  - Appliance mDNS publisher
  - /usr/local/bin/vwctl

USB backup media will NOT be erased or reformatted.

Docker itself will NOT be removed.
Avahi itself will NOT be removed.

Kein Backup, keine Gnade.
No backup, no mercy.

WARNING
    printf 'Type %s to continue: ' "${CONFIRMATION_TEXT}"
}

remove_read_confirmation() {
    [[ -r /dev/tty ]] || return 1
    IFS= read -r REPLY </dev/tty
}

remove_confirmation_matches() {
    [[ "$1" == "${CONFIRMATION_TEXT}" ]]
}

remove_confirm() {
    local answer=""

    remove_show_warning
    if remove_read_confirmation; then
        answer=${REPLY}
    fi
    printf '\n'
    remove_confirmation_matches "${answer}"
}

remove_stop_disable_unit() {
    local unit=$1
    local description=$2
    local active=0
    local enabled=0

    local state_result

    if remove_unit_active_state "${unit}"; then
        active=1
    else
        state_result=$?
        (( state_result == 1 )) || return 1
    fi
    if remove_unit_enabled_state "${unit}"; then
        enabled=1
    else
        state_result=$?
        (( state_result == 1 )) || return 1
    fi
    if (( active == 0 && enabled == 0 )); then
        remove_info "${description} is already stopped and disabled or absent."
        return 0
    fi
    if (( enabled == 1 )); then
        remove_systemctl disable "${unit}" >/dev/null 2>&1 || return 1
    fi
    if (( active == 1 )); then
        remove_systemctl stop "${unit}" || return 1
    fi
    remove_unit_is_inactive "${unit}" && remove_unit_is_disabled "${unit}" || return 1
    remove_ok "Stopped and disabled ${description}."
}

remove_stop_unit() {
    local unit=$1
    local description=$2

    local state_result

    if remove_unit_active_state "${unit}"; then
        :
    else
        state_result=$?
        (( state_result == 1 )) || return 1
        remove_info "${description} is already stopped or absent."
        return 0
    fi
    remove_systemctl stop "${unit}" || return 1
    remove_unit_is_inactive "${unit}" || return 1
    remove_ok "Stopped ${description}."
}

remove_stop_services() {
    remove_stop_disable_unit "${BACKUP_TIMER}" "Automatic-backup timer" ||
        remove_record_error "Unable to stop and disable ${BACKUP_TIMER}."
    remove_stop_unit "${BACKUP_SERVICE}" "Automatic-backup service" ||
        remove_record_error "Unable to stop ${BACKUP_SERVICE}."
    remove_stop_disable_unit "${MDNS_SERVICE}" "Appliance mDNS service" ||
        remove_record_error "Unable to stop and disable ${MDNS_SERVICE}."
}

remove_services_are_stopped() {
    remove_unit_is_inactive "${BACKUP_TIMER}" &&
        remove_unit_is_inactive "${BACKUP_SERVICE}" &&
        remove_unit_is_inactive "${MDNS_SERVICE}"
}

remove_container() {
    local container=$1
    local result

    if remove_container_exists "${container}"; then
        :
    else
        result=$?
        if (( result == 1 )); then
            remove_info "Docker container '${container}' is already absent."
            return 0
        fi
        return 1
    fi
    remove_container_is_owned "${container}" "${container}" || {
        remove_error "Container '${container}' changed ownership after confirmation; it was preserved."
        return 1
    }
    remove_docker container rm --force -- "${container}" >/dev/null || return 1
    remove_container_is_absent "${container}" || return 1
    remove_ok "Removed Docker container '${container}'."
}

remove_network() {
    local result

    if remove_network_exists "${APPLIANCE_NETWORK}"; then
        :
    else
        result=$?
        if (( result == 1 )); then
            remove_info "Docker network '${APPLIANCE_NETWORK}' is already absent."
            return 0
        fi
        return 1
    fi
    remove_network_is_owned "${APPLIANCE_NETWORK}" || {
        remove_error "Network '${APPLIANCE_NETWORK}' changed ownership after confirmation; it was preserved."
        return 1
    }
    remove_docker network rm "${APPLIANCE_NETWORK}" >/dev/null || return 1
    remove_network_is_absent "${APPLIANCE_NETWORK}" || return 1
    remove_ok "Removed Docker network '${APPLIANCE_NETWORK}'."
}

remove_docker_resources() {
    remove_container caddy || remove_record_error "Unable to remove the appliance Caddy container."
    remove_container vaultwarden || remove_record_error "Unable to remove the appliance Vaultwarden container."
    if ! remove_container_is_absent caddy || ! remove_container_is_absent vaultwarden; then
        remove_record_error "One or more appliance containers remain; the network and local data will be preserved."
        return
    fi
    remove_network || remove_record_error "Unable to remove the appliance Docker network."
}

remove_owned_file() {
    local path=$1
    local marker=$2

    if [[ ! -e "${path}" && ! -L "${path}" ]]; then
        remove_info "Already absent: ${path}"
        return 0
    fi
    remove_validate_owned_file "${path}" "${marker}" || return 1
    rm -f -- "${path}" || return 1
    [[ ! -e "${path}" && ! -L "${path}" ]]
}

remove_installed_files() {
    local entry
    local marker
    local path

    for entry in "${INSTALLED_FILES[@]}" "${INSTALLED_LIBRARIES[@]}"; do
        IFS='|' read -r path marker <<<"${entry}"
        remove_owned_file "${path}" "${marker}" ||
            remove_record_error "Refused or failed to remove appliance-owned file: ${path}."
    done
    if [[ -d "${LIBRARY_DIR}" && ! -L "${LIBRARY_DIR}" ]]; then
        if rmdir -- "${LIBRARY_DIR}" 2>/dev/null; then
            remove_ok "Removed empty appliance library directory."
        else
            remove_info "Preserved non-empty library directory ${LIBRARY_DIR}; unrelated contents were not removed."
        fi
    fi
    remove_systemctl daemon-reload || remove_record_error "systemctl daemon-reload failed."
}

remove_delete_tree() {
    rm -rf --one-file-system -- "$1"
}

remove_installation_tree() {
    local directory=$1
    local marker=$2
    local expected_directory=$3

    remove_validate_appliance "${directory}" "${marker}" "${expected_directory}" || return 1
    remove_delete_tree "${directory}" || return 1
    [[ ! -e "${directory}" && ! -L "${directory}" ]]
}

remove_verify_expected_files_absent() {
    local entry
    local marker
    local path

    for entry in "${INSTALLED_FILES[@]}" "${INSTALLED_LIBRARIES[@]}"; do
        IFS='|' read -r path marker <<<"${entry}"
        if [[ -e "${path}" || -L "${path}" ]]; then
            return 1
        fi
    done
}

remove_final_verification() {
    local avahi_state_after
    local compose_version_after
    local docker_version_after
    local entry
    local unit

    remove_container_is_absent vaultwarden || return 1
    remove_container_is_absent caddy || return 1
    remove_network_is_absent "${APPLIANCE_NETWORK}" || return 1
    for entry in "${SYSTEMD_UNITS[@]}"; do
        unit=${entry%%|*}
        remove_unit_is_absent "${unit}" || return 1
    done
    remove_verify_expected_files_absent || return 1
    [[ ! -e "${INSTALL_DIR}" && ! -L "${INSTALL_DIR}" ]] || return 1
    remove_docker info >/dev/null 2>&1 || return 1
    docker_version_after=$(remove_docker --version 2>/dev/null) || return 1
    [[ "${docker_version_after}" == "${DOCKER_VERSION_BEFORE}" ]] || return 1
    if compose_version_after=$(remove_docker compose version 2>/dev/null); then
        :
    else
        compose_version_after=unavailable
    fi
    [[ "${compose_version_after}" == "${DOCKER_COMPOSE_VERSION_BEFORE}" ]] || return 1
    if avahi_state_after=$(remove_systemctl is-active avahi-daemon.service 2>/dev/null); then
        :
    else
        avahi_state_after=inactive
    fi
    [[ "${avahi_state_after}" == "${AVAHI_STATE_BEFORE}" ]]
}

remove_print_result() {
    cat <<'RESULT'

Vaultwarden Appliance removed.

Removed:
  Vaultwarden and Caddy containers
  Appliance Docker network
  Appliance systemd services/timer
  Appliance management files
  /opt/vaultwarden and all local appliance data

Preserved:
  Docker and Docker Compose
  Avahi
  Docker images
  USB backup media

Kein Backup, keine Gnade.
No backup, no mercy.
RESULT
}

remove_main() {
    (( $# == 0 )) || {
        remove_error "Usage: sudo ./remove.sh"
        return 1
    }
    remove_require_root || return 1
    remove_acquire_lock || return 1
    if ! remove_validate_appliance "${INSTALL_DIR}" "${APPLIANCE_MARKER}" "${INSTALL_DIR}"; then
        remove_error "${INSTALL_DIR} is not positively identified as a Vaultwarden Appliance installation. Nothing was changed."
        return 1
    fi
    remove_require_runtime || return 1
    remove_validate_docker_resources || return 1
    remove_validate_installed_files || return 1
    remove_validate_systemd_units || return 1

    if ! remove_confirm; then
        remove_info "Removal cancelled; no changes were made."
        return 0
    fi

    remove_info "Stopping appliance systemd services and timer."
    remove_stop_services
    remove_info "Removing positively identified appliance Docker resources."
    remove_docker_resources
    remove_info "Removing appliance systemd, command, helper and library files."
    remove_installed_files

    if (( REMOVAL_ERRORS == 0 )) && remove_services_are_stopped &&
       remove_container_is_absent vaultwarden && remove_container_is_absent caddy; then
        if remove_installation_tree "${INSTALL_DIR}" "${APPLIANCE_MARKER}" "${INSTALL_DIR}"; then
            remove_ok "Removed ${INSTALL_DIR} and all local appliance data."
        else
            remove_record_error "Refused or failed to remove ${INSTALL_DIR}; ownership changed or deletion failed."
        fi
    else
        remove_record_error "Local appliance data was preserved because an earlier cleanup step failed. Rerun remove.sh after correcting the reported problem."
    fi

    if (( REMOVAL_ERRORS == 0 )) && remove_final_verification; then
        remove_print_result
        return 0
    fi
    remove_error "Vaultwarden Appliance removal is incomplete. Safe remaining resources were preserved for diagnosis and a rerun."
    return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    remove_main "$@"
fi
