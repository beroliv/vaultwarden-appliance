#!/usr/bin/env bash

# Low-level helpers shared by install.sh and vwctl.  These functions print no
# user-facing status messages; callers decide how failures are reported.

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

validate_local_hostname() {
    local hostname=$1

    validate_hostname "${hostname}" || return 1
    [[ "${hostname}" == *.local ]]
}

validate_dns_hostname() {
    local hostname=$1

    validate_hostname "${hostname}" || return 1
    [[ "${hostname}" != *.local ]]
}

validate_hostname() {
    local hostname=$1
    local label
    local -a labels

    [[ -n "${hostname}" && ${#hostname} -le 253 ]] || return 1
    [[ "${hostname}" == "${hostname,,}" ]] || return 1
    [[ "${hostname}" == *.* && "${hostname}" != .* && "${hostname}" != *. ]] || return 1
    [[ ! "${hostname}" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || return 1
    validate_ipv4_address "${hostname}" && return 1

    IFS='.' read -r -a labels <<<"${hostname}"
    (( ${#labels[@]} >= 2 )) || return 1
    for label in "${labels[@]}"; do
        [[ ${#label} -le 63 ]] || return 1
        [[ "${label}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
    done
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

appliance_url_for_hostname() {
    local hostname=$1

    validate_hostname "${hostname}" || return 1
    printf 'https://%s\n' "${hostname}"
}

validate_access_configuration() {
    local mode=$1
    local hostname=$2

    case "${mode}" in
        mdns) validate_local_hostname "${hostname}" ;;
        dns) validate_dns_hostname "${hostname}" ;;
        *) return 1 ;;
    esac
}

access_config_file_is_safe() {
    local state_file=$1
    local owner
    local permissions

    [[ -f "${state_file}" && ! -L "${state_file}" ]] || return 1
    owner=$(stat -c '%u' "${state_file}" 2>/dev/null) || return 1
    permissions=$(stat -c '%a' "${state_file}" 2>/dev/null) || return 1
    [[ "${owner}" == 0 && "${permissions}" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#${permissions} & 8#002) == 0 ))
}

read_access_config() {
    local state_file=$1
    local key
    local mode=""
    local hostname
    local value
    local line
    local -a lines

    [[ -f "${state_file}" && ! -L "${state_file}" ]] || return 1
    mapfile -t lines < "${state_file}" || return 1
    (( ${#lines[@]} == 2 )) || return 1
    [[ "${lines[0]}" == mode=* && "${lines[1]}" == hostname=* ]] || return 1
    hostname=""
    for line in "${lines[@]}"; do
        [[ "${line}" =~ ^([a-z]+)=([^=]+)$ ]] || return 1
        key=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]}
        case "${key}" in
            mode)
                [[ -z "${mode}" ]] || return 1
                mode=${value}
                ;;
            hostname)
                [[ -z "${hostname}" ]] || return 1
                hostname=${value}
                ;;
            *) return 1 ;;
        esac
    done
    validate_access_configuration "${mode}" "${hostname}" || return 1
    printf '%s\t%s\n' "${mode}" "${hostname}"
}

write_access_config_atomic() {
    local destination=$1
    local mode=$2
    local hostname=$3
    local directory
    local temporary=""

    validate_access_configuration "${mode}" "${hostname}" || return 1
    directory=$(dirname -- "${destination}") || return 1
    [[ -d "${directory}" && ! -L "${directory}" ]] || return 1
    if [[ -e "${destination}" || -L "${destination}" ]]; then
        [[ -f "${destination}" && ! -L "${destination}" ]] || return 1
    fi
    temporary=$(mktemp "${directory}/.access.XXXXXXXX") || return 1
    if ! printf 'mode=%s\nhostname=%s\n' "${mode}" "${hostname}" > "${temporary}" ||
       ! chmod 0644 "${temporary}"; then
        rm -f -- "${temporary}"
        return 1
    fi
    if [[ -f "${destination}" ]] && cmp -s "${temporary}" "${destination}" &&
       access_config_file_is_safe "${destination}"; then
        rm -f -- "${temporary}"
        return 0
    fi
    if ! mv -f -- "${temporary}" "${destination}"; then
        rm -f -- "${temporary}"
        return 1
    fi
}

acquire_appliance_lock() {
    local lock_file=$1
    local lock_owner=""

    command_exists flock || return 2
    [[ ! -L "${lock_file}" ]] || return 3
    if [[ -e "${lock_file}" && ! -f "${lock_file}" ]]; then
        return 3
    fi

    exec {APPLIANCE_LOCK_FD}>"${lock_file}" || return 3
    lock_owner=$(stat -c '%u' "${lock_file}" 2>/dev/null) || {
        exec {APPLIANCE_LOCK_FD}>&-
        return 3
    }
    if [[ "${lock_owner}" != "${EUID}" ]] || ! chmod 0644 "${lock_file}"; then
        exec {APPLIANCE_LOCK_FD}>&-
        return 3
    fi
    if ! flock -n "${APPLIANCE_LOCK_FD}"; then
        exec {APPLIANCE_LOCK_FD}>&-
        APPLIANCE_LOCK_FD=""
        return 1
    fi
}

copy_public_certificate_atomic() {
    local source=$1
    local destination=$2
    local destination_dir
    local temporary=""

    [[ -f "${source}" && ! -L "${source}" ]] || return 1
    destination_dir=$(dirname -- "${destination}") || return 1
    [[ -d "${destination_dir}" && ! -L "${destination_dir}" ]] || return 1
    if [[ -e "${destination}" && ( ! -f "${destination}" || -L "${destination}" ) ]]; then
        return 1
    fi

    temporary=$(mktemp "${destination_dir}/.caddy-root-ca.XXXXXXXX") || return 1
    if ! install -m 0600 -- "${source}" "${temporary}"; then
        rm -f -- "${temporary}"
        return 1
    fi

    if command_exists openssl &&
       ! openssl x509 -in "${temporary}" -noout >/dev/null 2>&1; then
        rm -f -- "${temporary}"
        return 1
    fi

    if ! chmod 0644 "${temporary}" || ! mv -f -- "${temporary}" "${destination}"; then
        rm -f -- "${temporary}"
        return 1
    fi
    cmp -s "${source}" "${destination}"
}
