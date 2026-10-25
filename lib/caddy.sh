#!/usr/bin/env bash

write_caddy_ca_download_routes() {
    # The exact matcher and fixed rewrite are the exposure boundary. Never use
    # a wildcard matcher, request-derived filename, browse, or pass_thru here.
    # Read Caddy's current public certificate on each request, so replacing its
    # data during restore or CA regeneration cannot leave a stale bind inode.
    cat <<'CADDY'
	handle /ca.crt {
		route {
			rewrite * /root.crt
			header Content-Type application/x-x509-ca-cert
			header Content-Disposition "attachment; filename=\"caddy-root-ca.crt\""
			header Cache-Control "no-store"
			file_server {
				root /data/caddy/pki/authorities/local
				hide *.key intermediate.crt
			}
		}
	}
	handle {
		reverse_proxy vaultwarden:80
	}
CADDY
}

write_caddyfile_to() {
    local destination=$1
    local hostname=$2

    validate_hostname "${hostname}" || return 1
    {
        printf '%s\n' \
        '{' \
        $'\tauto_https disable_redirects' \
        '}' \
        '' \
        "https://${hostname} {" \
        $'\ttls internal' || return 1
        write_caddy_ca_download_routes || return 1
        printf '}\n'
    } > "${destination}" || return 1
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
    validate_hostname "${hostname}" || return 1
    printf '%s\n' "${hostname}"
}
