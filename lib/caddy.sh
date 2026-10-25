#!/usr/bin/env bash

write_caddy_ca_download_handler() {
    local directive=${1:-handle}
    [[ "${directive}" == handle || "${directive}" == route ]] || return 1
    # The exact matcher and fixed rewrite are the exposure boundary. Never use
    # a wildcard matcher, request-derived filename, browse, or pass_thru here.
    # Read Caddy's current public certificate on each request, so replacing its
    # data during restore or CA regeneration cannot leave a stale bind inode.
    printf '\t%s /ca.crt {\n' "${directive}"
    cat <<'CADDY'
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
CADDY
}

write_caddy_ca_download_routes() {
    write_caddy_ca_download_handler || return 1
    cat <<'CADDY'
	handle {
		reverse_proxy vaultwarden:80
	}
CADDY
}

# Return the unique site's opening line, 2 when a CA handler already exists,
# or 1 for ambiguous/unsupported input. Tokenize quoted strings and comments so
# braces in headers, placeholders, comments and other hosts cannot move scope.
caddy_ca_migration_line() {
    local source=$1 hostname=$2
    validate_hostname "${hostname}" || return 1
    LC_ALL=C awk -v hostname="${hostname}" '
        function emit() {
            if (token != "") { words[++count]=token; quoted[count]=was_quoted }
            token=""; was_quoted=0
        }
        {
            delete words; delete quoted; count=0; token=""; was_quoted=(quote != "")
            for (i=1; i<=length($0); i++) {
                c=substr($0,i,1)
                if (escape) { token=token c; escape=0; continue }
                if (quote != "") {
                    if (c == quote) quote=""
                    else if (c == "\\" && quote == "\"") escape=1
                    else token=token c
                    continue
                }
                if (c == "#") break
                if (c == "\"" || c == "`") { quote=c; was_quoted=1; continue }
                if (c == " " || c == "\t" || c == "\r") { emit(); continue }
                token=token c
            }
            emit()
            if (depth == 0) {
                for (j=1; j<=count; j++) {
                    if (words[j] == hostname || words[j] == "https://" hostname) {
                        # Restrict migration to one complete, single-host header.
                        if (count != 2 || words[2] != "{" || quote != "") bad=1
                        else { sites++; opening=NR; target=1 }
                    }
                }
            }
            for (j=1; j<=count; j++) {
                if (target && depth >= 1) {
                    if (words[j] == "/ca.crt" && (words[1] == "handle" || words[1] == "handle_path" || words[1] == "route")) present=1
                    # Custom routing may consume the request before a route.
                    if (depth == 1 && (words[j] == "handle" || words[j] == "handle_path" || words[j] == "route" || words[j] == "import")) custom=1
                }
                if (!quoted[j] && words[j] == "{") depth++
                if (!quoted[j] && words[j] == "}") {
                    depth--; if (depth < 0) bad=1
                    if (target && depth == 0) target=0
                }
            }
        }
        END {
            if (bad || depth != 0 || quote != "" || sites != 1) exit 1
            if (present) exit 2
            if (custom) exit 1
            print opening
        }
    ' "${source}"
}

write_migrated_caddyfile_to() {
    local source=$1 destination=$2 opening=$3
    local line status number=0

    [[ "${opening}" =~ ^[1-9][0-9]*$ ]] || return 1
    # Preserve every original byte, including an unterminated final line.
    while :; do
        status=0
        IFS= read -r line || status=$?
        [[ -n "${line}" || ${status} == 0 ]] || break
        number=$((number + 1))
        printf '%s' "${line}" || return 1
        if (( status == 0 )); then printf '\n' || return 1; fi
        if (( number == opening )); then
            (( status == 0 )) || return 1
            write_caddy_ca_download_handler route || return 1
        fi
        (( status == 0 )) || break
    done < "${source}" > "${destination}"
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
