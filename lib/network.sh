#!/usr/bin/env bash

detect_ipv4_address() {
    local address=""
    local interface_output=""
    local route_output=""
    local host_addresses=""

    if command_exists ip; then
        route_output=$(ip -4 route get 1.1.1.1 2>/dev/null) || route_output=""
        if [[ -n "${route_output}" ]]; then
            address=$(awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}' \
                <<<"${route_output}") || address=""
        fi
    fi

    if ! validate_ipv4_address "${address}" && command_exists ip; then
        interface_output=$(ip -o -4 addr show up scope global 2>/dev/null) || interface_output=""
        if [[ -n "${interface_output}" ]]; then
            address=$(awk '$2 !~ /^(docker[0-9]*|br-|veth|virbr|podman|cni)/ {
                split($4, candidate, "/")
                print candidate[1]
                exit
            }' <<<"${interface_output}") || address=""
        fi
    fi

    if ! validate_ipv4_address "${address}" && command_exists hostname; then
        host_addresses=$(hostname -I 2>/dev/null) || host_addresses=""
        if [[ -n "${host_addresses}" ]]; then
            address=$(awk '{for (i = 1; i <= NF; i++) if ($i !~ /^127\./) {print $i; exit}}' \
                <<<"${host_addresses}") || address=""
        fi
    fi

    validate_ipv4_address "${address}" || return 1
    printf '%s\n' "${address}"
}

port_is_in_use() {
    local port=$1

    if command_exists ss; then
        ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .
    elif command_exists netstat; then
        netstat -ltn 2>/dev/null | awk -v port=":${port}" '$4 ~ port "$" {found=1} END {exit !found}'
    else
        awk -v port_hex="$(printf '%04X' "${port}")" \
            'NR > 1 && $4 == "0A" && substr($2, length($2) - 3) == port_hex {found=1} END {exit !found}' \
            /proc/net/tcp /proc/net/tcp6 2>/dev/null
    fi
}
