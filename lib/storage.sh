#!/usr/bin/env bash

# Read-only block-device topology helpers. Inventory records use "|" as an
# internal separator; validated device fields cannot contain that character.

storage_valid_device_path() {
    local path=$1

    [[ "${path}" =~ ^/dev/[A-Za-z0-9._+:-]+(/[A-Za-z0-9._+:-]+)*$ ]] || return 1
    [[ "${path}" != */./* && "${path}" != */../* &&
       "${path}" != */. && "${path}" != */.. ]]
}

storage_sysfs_disk_is_device_backed() {
    local major_minor=$1
    local sysfs_path

    [[ "${major_minor}" =~ ^[0-9]+:[0-9]+$ ]] || return 1
    command_exists readlink || return 1
    sysfs_path=$(readlink -f -- "/sys/dev/block/${major_minor}" 2>/dev/null) || return 1
    [[ "${sysfs_path}" == /sys/devices/* &&
       "${sysfs_path}" != /sys/devices/virtual/* ]]
}

storage_validate_inventory() {
    local inventory=$1
    local device_backed
    local extra
    local major_minor
    local name
    local parent
    local read_only
    local size
    local type
    local -A known_nodes=()
    local -A node_metadata=()

    [[ -n "${inventory}" ]] || return 1
    while IFS='|' read -r name parent type major_minor size read_only device_backed extra; do
        [[ -z "${extra:-}" ]] || return 1
        storage_valid_device_path "${name}" || return 1
        [[ -z "${parent}" ]] || storage_valid_device_path "${parent}" || return 1
        [[ "${type}" =~ ^[a-z0-9_-]+$ ]] || return 1
        [[ "${major_minor}" =~ ^[0-9]+:[0-9]+$ ]] || return 1
        [[ "${size}" =~ ^[0-9]+$ ]] || return 1
        [[ "${read_only}" == "0" || "${read_only}" == "1" ]] || return 1
        [[ "${device_backed}" == "0" || "${device_backed}" == "1" ]] || return 1
        [[ "${type}" == "disk" || "${device_backed}" == "0" ]] || return 1
        if [[ -n "${node_metadata[${name}]:-}" &&
              "${node_metadata[${name}]}" != "${type}|${major_minor}|${size}|${read_only}|${device_backed}" ]]; then
            return 1
        fi
        known_nodes["${name}"]=1
        node_metadata["${name}"]="${type}|${major_minor}|${size}|${read_only}|${device_backed}"
    done <<<"${inventory}"

    while IFS='|' read -r name parent type major_minor size read_only device_backed extra; do
        if [[ -n "${parent}" && -z "${known_nodes[${parent}]:-}" ]]; then
            return 1
        fi
        if [[ "${type}" == "disk" && -n "${parent}" ]]; then
            return 1
        fi
    done <<<"${inventory}"
}

storage_inventory_node_field() {
    local inventory=$1
    local requested_node=$2
    local field=$3
    local device_backed
    local extra
    local major_minor
    local name
    local parent
    local read_only
    local result=""
    local size
    local type
    local value

    storage_validate_inventory "${inventory}" || return 1
    while IFS='|' read -r name parent type major_minor size read_only device_backed extra; do
        [[ "${name}" == "${requested_node}" ]] || continue
        case "${field}" in
            type) value=${type} ;;
            major_minor) value=${major_minor} ;;
            size) value=${size} ;;
            read_only) value=${read_only} ;;
            device_backed) value=${device_backed} ;;
            *) return 1 ;;
        esac
        if [[ -n "${result}" && "${result}" != "${value}" ]]; then
            return 1
        fi
        result=${value}
    done <<<"${inventory}"
    [[ -n "${result}" ]] || return 1
    printf '%s\n' "${result}"
}

storage_inventory_parents() {
    local inventory=$1
    local requested_node=$2
    local device_backed
    local extra
    local major_minor
    local name
    local parent
    local read_only
    local size
    local type
    local -A parents=()

    storage_validate_inventory "${inventory}" || return 1
    while IFS='|' read -r name parent type major_minor size read_only device_backed extra; do
        [[ "${name}" == "${requested_node}" && -n "${parent}" ]] || continue
        parents["${parent}"]=1
    done <<<"${inventory}"
    ((${#parents[@]} > 0)) || return 1
    printf '%s\n' "${!parents[@]}" | sort
}

storage_inventory_node_by_major_minor() {
    local inventory=$1
    local requested_major_minor=$2
    local device_backed
    local extra
    local major_minor
    local name
    local parent
    local read_only
    local size
    local type
    local -A matches=()

    [[ "${requested_major_minor}" =~ ^[0-9]+:[0-9]+$ ]] || return 1
    storage_validate_inventory "${inventory}" || return 1
    while IFS='|' read -r name parent type major_minor size read_only device_backed extra; do
        [[ "${major_minor}" == "${requested_major_minor}" ]] || continue
        matches["${name}"]=1
    done <<<"${inventory}"
    ((${#matches[@]} == 1)) || return 1
    printf '%s\n' "${!matches[@]}"
}

storage_resolve_physical_disks() {
    local inventory=$1
    local start_node=$2
    local current
    local current_path
    local parent
    local type
    local -a parents=()
    local -a queue_nodes=("${start_node}")
    local -a queue_paths=("|${start_node}|")
    local -A disks=()
    local -A processed=()

    storage_validate_inventory "${inventory}" || return 1
    storage_valid_device_path "${start_node}" || return 1
    storage_inventory_node_field "${inventory}" "${start_node}" type >/dev/null || return 1

    while ((${#queue_nodes[@]} > 0)); do
        current=${queue_nodes[0]}
        current_path=${queue_paths[0]}
        queue_nodes=("${queue_nodes[@]:1}")
        queue_paths=("${queue_paths[@]:1}")
        [[ -z "${processed[${current}]:-}" ]] || continue
        processed["${current}"]=1

        type=$(storage_inventory_node_field "${inventory}" "${current}" type) || return 1
        if [[ "${type}" == "disk" ]]; then
            disks["${current}"]=1
            continue
        fi

        mapfile -t parents < <(storage_inventory_parents "${inventory}" "${current}")
        ((${#parents[@]} > 0)) || return 1
        for parent in "${parents[@]}"; do
            [[ "${current_path}" != *"|${parent}|"* ]] || return 1
            queue_nodes+=("${parent}")
            queue_paths+=("${current_path}${parent}|")
        done
    done

    ((${#disks[@]} > 0)) || return 1
    printf '%s\n' "${!disks[@]}" | sort
}

storage_protected_disks_from_mounts() {
    local inventory=$1
    local mounts=$2
    local disk
    local extra
    local mount_target
    local node
    local -a resolved_disks=()
    local -A reasons=()

    storage_validate_inventory "${inventory}" || return 1
    [[ -n "${mounts}" ]] || return 1
    while IFS='|' read -r mount_target node extra; do
        [[ -z "${extra:-}" ]] || return 1
        case "${mount_target}" in
            /|/boot|/boot/firmware) ;;
            *) return 1 ;;
        esac
        storage_valid_device_path "${node}" || return 1
        mapfile -t resolved_disks < <(storage_resolve_physical_disks "${inventory}" "${node}")
        ((${#resolved_disks[@]} > 0)) || return 1
        for disk in "${resolved_disks[@]}"; do
            if [[ -n "${reasons[${disk}]:-}" ]]; then
                case ",${reasons[${disk}]} ," in
                    *",${mount_target} ,"*) ;;
                    *) reasons["${disk}"]+=", ${mount_target}" ;;
                esac
            else
                reasons["${disk}"]=${mount_target}
            fi
        done
    done <<<"${mounts}"

    ((${#reasons[@]} > 0)) || return 1
    for disk in "${!reasons[@]}"; do
        printf '%s|%s\n' "${disk}" "${reasons[${disk}]}"
    done | sort
}

storage_candidate_disks() {
    local inventory=$1
    local protected=$2
    local device_backed
    local disk
    local extra
    local major_minor
    local name
    local parent
    local protected_disk
    local protected_reason
    local read_only
    local size
    local type
    local -A candidates=()
    local -A protected_disks=()

    storage_validate_inventory "${inventory}" || return 1
    [[ -n "${protected}" ]] || return 1
    while IFS='|' read -r protected_disk protected_reason extra; do
        [[ -z "${extra:-}" && -n "${protected_reason}" ]] || return 1
        storage_valid_device_path "${protected_disk}" || return 1
        [[ "$(storage_inventory_node_field "${inventory}" "${protected_disk}" type)" == "disk" ]] || return 1
        protected_disks["${protected_disk}"]=1
    done <<<"${protected}"

    # Any real block-composition node with an unresolved ancestry makes the
    # topology questionable. Pseudo devices are never candidates and need no
    # physical-parent resolution.
    while IFS='|' read -r name parent type major_minor size read_only device_backed extra; do
        case "${type}" in
            disk|loop|rom|ram|zram) ;;
            *) storage_resolve_physical_disks "${inventory}" "${name}" >/dev/null || return 1 ;;
        esac
    done <<<"${inventory}"

    while IFS='|' read -r name parent type major_minor size read_only device_backed extra; do
        [[ "${type}" == "disk" && "${device_backed}" == "1" &&
           "${read_only}" == "0" ]] || continue
        (( size > 0 )) || continue
        [[ -z "${protected_disks[${name}]:-}" ]] || continue
        candidates["${name}"]=1
    done <<<"${inventory}"

    ((${#candidates[@]} > 0)) || return 0
    printf '%s\n' "${!candidates[@]}" | sort
}

storage_selection_index() {
    local selection=$1
    local candidate_count=$2

    [[ "${candidate_count}" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ "${selection}" =~ ^[1-9][0-9]*$ ]] || return 1
    (( 10#${selection} <= candidate_count )) || return 1
    printf '%d\n' "$((10#${selection} - 1))"
}

storage_format_bytes() {
    local bytes=$1

    [[ "${bytes}" =~ ^[0-9]+$ ]] || return 1
    awk -v bytes="${bytes}" 'BEGIN {
        if (bytes >= 1000000000000) printf "%.1f TB\n", bytes / 1000000000000
        else if (bytes >= 1000000000) printf "%.1f GB\n", bytes / 1000000000
        else if (bytes >= 1000000) printf "%.1f MB\n", bytes / 1000000
        else if (bytes >= 1000) printf "%.1f kB\n", bytes / 1000
        else printf "%d B\n", bytes
    }'
}

storage_collect_topology() {
    local device_backed
    local initial=""
    local inventory=""
    local major_minor
    local name
    local parent
    local parent_output=""
    local read_only
    local size
    local slave_major_minor
    local slave_path
    local slaves_directory
    local type
    local -a node_major_minor=()
    local -a node_names=()
    local -a node_read_only=()
    local -a node_sizes=()
    local -a node_types=()
    local -a topology_parents=()
    local -A name_by_major_minor=()
    local index

    command_exists lsblk || return 1
    initial=$(lsblk --bytes --paths --noheadings --raw \
        --output NAME,TYPE,MAJ:MIN,SIZE,RO 2>/dev/null) || return 1
    [[ -n "${initial}" ]] || return 1

    while read -r name type major_minor size read_only; do
        storage_valid_device_path "${name}" || return 1
        [[ "${type}" =~ ^[a-z0-9_-]+$ ]] || return 1
        [[ "${major_minor}" =~ ^[0-9]+:[0-9]+$ ]] || return 1
        [[ "${size}" =~ ^[0-9]+$ ]] || return 1
        [[ "${read_only}" == "0" || "${read_only}" == "1" ]] || return 1
        if [[ -n "${name_by_major_minor[${major_minor}]:-}" &&
              "${name_by_major_minor[${major_minor}]}" != "${name}" ]]; then
            return 1
        fi
        [[ -n "${name_by_major_minor[${major_minor}]:-}" ]] && continue
        name_by_major_minor["${major_minor}"]=${name}
        node_names+=("${name}")
        node_types+=("${type}")
        node_major_minor+=("${major_minor}")
        node_sizes+=("${size}")
        node_read_only+=("${read_only}")
    done <<<"${initial}"

    for index in "${!node_names[@]}"; do
        name=${node_names[${index}]}
        type=${node_types[${index}]}
        major_minor=${node_major_minor[${index}]}
        size=${node_sizes[${index}]}
        read_only=${node_read_only[${index}]}
        device_backed=0
        # lsblk also reports virtual disks such as zram as TYPE=disk. Resolve
        # the kernel devpath so only non-virtual, device-backed whole disks can
        # become candidates; the transport value is intentionally irrelevant.
        if [[ "${type}" == "disk" ]] &&
           storage_sysfs_disk_is_device_backed "${major_minor}"; then
            device_backed=1
        fi
        topology_parents=()
        slaves_directory="/sys/dev/block/${major_minor}/slaves"

        if [[ -d "${slaves_directory}" ]]; then
            for slave_path in "${slaves_directory}"/*; do
                [[ -e "${slave_path}/dev" ]] || continue
                slave_major_minor=$(<"${slave_path}/dev") || return 1
                parent=${name_by_major_minor[${slave_major_minor}]:-}
                storage_valid_device_path "${parent}" || return 1
                topology_parents+=("${parent}")
            done
        fi

        if ((${#topology_parents[@]} == 0)) && [[ "${type}" != "disk" ]]; then
            parent_output=$(lsblk --nodeps --paths --noheadings --raw \
                --output PKNAME "${name}" 2>/dev/null) || return 1
            while IFS= read -r parent; do
                [[ -n "${parent}" ]] || continue
                [[ "${parent}" == /dev/* ]] || parent="/dev/${parent}"
                storage_valid_device_path "${parent}" || return 1
                topology_parents+=("${parent}")
            done <<<"${parent_output}"
        fi

        if ((${#topology_parents[@]} == 0)); then
            inventory+="${name}||${type}|${major_minor}|${size}|${read_only}|${device_backed}"$'\n'
        else
            for parent in "${topology_parents[@]}"; do
                inventory+="${name}|${parent}|${type}|${major_minor}|${size}|${read_only}|${device_backed}"$'\n'
            done
        fi
    done
    inventory=${inventory%$'\n'}
    storage_validate_inventory "${inventory}" || return 1
    printf '%s\n' "${inventory}"
}

storage_collect_system_mounts() {
    local inventory=$1
    local filesystem
    local major_minor
    local node
    local output=""
    local target

    command_exists findmnt || return 1
    storage_validate_inventory "${inventory}" || return 1
    for target in / /boot /boot/firmware; do
        [[ "${target}" == "/" || -e "${target}" ]] || continue
        if ! read -r major_minor filesystem < <(findmnt --noheadings --raw \
            --output MAJ:MIN,FSTYPE --target "${target}" 2>/dev/null); then
            return 1
        fi
        [[ "${major_minor}" =~ ^[0-9]+:[0-9]+$ && -n "${filesystem}" ]] || return 1
        # Multi-device Btrfs cannot be proven complete from a single findmnt
        # major:minor value alone, so Phase 5A deliberately fails closed.
        [[ "${filesystem}" != "btrfs" ]] || return 1
        node=$(storage_inventory_node_by_major_minor "${inventory}" "${major_minor}") || return 1
        output+="${target}|${node}"$'\n'
    done
    output=${output%$'\n'}
    [[ -n "${output}" ]] || return 1
    printf '%s\n' "${output}"
}

storage_sanitize_text() {
    printf '%s' "$1" | LC_ALL=C tr '\t\r\n' '   ' | LC_ALL=C tr -cd '[:print:]' |
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]][[:space:]]*/ /g'
}

storage_lsblk_property() {
    local device=$1
    local property=$2
    local value=""

    storage_valid_device_path "${device}" || return 1
    case "${property}" in
        MODEL|VENDOR|SERIAL|TRAN|RM|FSTYPE|MOUNTPOINTS) ;;
        *) return 1 ;;
    esac
    value=$(lsblk --nodeps --noheadings --output "${property}" "${device}" 2>/dev/null) || return 1
    storage_sanitize_text "${value}"
}

storage_disk_nodes() {
    local inventory=$1
    local requested_disk=$2
    local device_backed
    local extra
    local major_minor
    local name
    local parent
    local read_only
    local resolved
    local size
    local type

    [[ "$(storage_inventory_node_field "${inventory}" "${requested_disk}" type)" == "disk" ]] || return 1
    printf '%s\n' "${requested_disk}"
    while IFS='|' read -r name parent type major_minor size read_only device_backed extra; do
        [[ "${name}" != "${requested_disk}" ]] || continue
        resolved=$(storage_resolve_physical_disks "${inventory}" "${name}" 2>/dev/null) || continue
        grep -Fxq "${requested_disk}" <<<"${resolved}" && printf '%s\n' "${name}"
    done <<<"${inventory}" | sort -u
}

storage_disk_property_values() {
    local inventory=$1
    local disk=$2
    local property=$3
    local node
    local value

    while IFS= read -r node; do
        value=$(storage_lsblk_property "${node}" "${property}" || true)
        [[ -n "${value}" ]] && printf '%s\n' "${value}"
    done < <(storage_disk_nodes "${inventory}" "${disk}") | sort -u
}

storage_join_lines() {
    awk 'NF {if (found) printf ", "; printf "%s", $0; found=1} END {if (found) print ""}'
}
