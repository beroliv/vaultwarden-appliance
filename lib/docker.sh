#!/usr/bin/env bash

container_exists() {
    docker inspect "$1" >/dev/null 2>&1
}

container_is_running() {
    [[ "$(docker inspect --format '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]
}

container_is_connected_to_network() {
    local container=$1
    local network=$2

    [[ "$(docker inspect --format "{{if index .NetworkSettings.Networks \"${network}\"}}yes{{end}}" \
        "${container}" 2>/dev/null)" == "yes" ]]
}

vaultwarden_domain_for_hostname() {
    appliance_url_for_hostname "$1"
}

write_vaultwarden_override_to() {
    local destination=$1
    local hostname=$2
    local signup_value=$3
    local domain

    domain=$(vaultwarden_domain_for_hostname "${hostname}") || return 1
    [[ "${signup_value}" == "true" || "${signup_value}" == "false" ]] || return 1

    printf '%s\n' \
        'services:' \
        '  vaultwarden:' \
        '    environment:' \
        "      DOMAIN: \"${domain}\"" \
        "      SIGNUPS_ALLOWED: \"${signup_value}\"" > "${destination}" || return 1
    chmod 0644 "${destination}"
}

running_vaultwarden_domain() {
    local environment=""

    environment=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' vaultwarden \
        2>/dev/null) || return 1
    awk -F= '$1 == "DOMAIN" {sub(/^[^=]*=/, ""); print; found=1; exit} END {exit !found}' \
        <<<"${environment}"
}

vaultwarden_domain_matches() {
    local hostname=$1
    local expected
    local running

    expected=$(vaultwarden_domain_for_hostname "${hostname}") || return 1
    running=$(running_vaultwarden_domain) || return 1
    [[ "${running}" == "${expected}" ]]
}
