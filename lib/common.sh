#!/usr/bin/env bash

# Low-level helpers shared by install.sh and vwctl.  These functions print no
# user-facing status messages; callers decide how failures are reported.

command_exists() {
    command -v "$1" >/dev/null 2>&1
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

appliance_url_for_hostname() {
    local hostname=$1

    validate_local_hostname "${hostname}" || return 1
    printf 'https://%s\n' "${hostname}"
}

read_access_hostname() {
    local state_file=$1
    local hostname
    local -a lines

    [[ -f "${state_file}" && ! -L "${state_file}" ]] || return 1
    mapfile -t lines < "${state_file}" || return 1
    (( ${#lines[@]} == 1 )) || return 1
    [[ "${lines[0]}" == hostname=* ]] || return 1
    hostname=${lines[0]#hostname=}
    validate_local_hostname "${hostname}" || return 1
    printf '%s\n' "${hostname}"
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
