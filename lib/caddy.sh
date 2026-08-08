#!/usr/bin/env bash

write_caddyfile_to() {
    local destination=$1
    local hostname=$2

    validate_local_hostname "${hostname}" || return 1
    printf '%s\n' \
        '{' \
        $'\tauto_https disable_redirects' \
        '}' \
        '' \
        "https://${hostname} {" \
        $'\ttls internal' \
        $'\treverse_proxy vaultwarden:80' \
        '}' > "${destination}" || return 1
    chmod 0644 "${destination}"
}

read_caddyfile_hostname() {
    local caddyfile=$1
    local hostname=""
    local -a hostnames

    [[ -f "${caddyfile}" && ! -L "${caddyfile}" ]] || return 1
    mapfile -t hostnames < <(awk '/^https:\/\/[^[:space:]]+[[:space:]]*\{$/ {
        value=$1
        sub(/^https:\/\//, "", value)
        print value
    }' "${caddyfile}")
    (( ${#hostnames[@]} == 1 )) || return 1
    hostname=${hostnames[0]}
    validate_local_hostname "${hostname}" || return 1
    printf '%s\n' "${hostname}"
}
