#!/usr/bin/env bash

mdns_resolved_ipv4s() {
    local hostname=$1

    timeout 4 avahi-resolve-host-name -4 "${hostname}" 2>/dev/null |
        awk 'NF >= 2 {print $2}' |
        sort -u
}

local_ipv4_addresses() {
    ip -o -4 addr show 2>/dev/null |
        awk '{split($4, address, "/"); print address[1]}' |
        sort -u
}

mdns_resolution_matches() {
    local expected_ip=$1
    local resolved=$2

    [[ "${resolved}" == "${expected_ip}" ]]
}

mdns_ready_file_matches() {
    local ready_file=$1
    local hostname=$2
    local ipv4=$3
    local ready_state=""

    [[ -f "${ready_file}" && ! -L "${ready_file}" ]] || return 1
    ready_state=$(<"${ready_file}") || return 1
    [[ "${ready_state}" == $'hostname='"${hostname}"$'\naddress='"${ipv4}" ]]
}
