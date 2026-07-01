#!/usr/bin/env bash
#
# fix-lxc-gid-mapping.sh
#
# Interactive tool for giving multiple unprivileged Proxmox LXC containers
# consistent access to a shared ZFS-backed directory, without resorting to
# 777 permissions or privileged containers.
#
# Run this ON THE PROXMOX HOST (e.g. after `ssh root@<proxmox-host>`), as root.
# It queries the host for running/stopped containers via `pct`, lets you pick
# one or more, and for each one:
#   1. confirms it's unprivileged and (optionally) bind-mounts the ZFS share
#   2. asks which in-container group should get access to the share
#   3. rewrites that container's /etc/pve/lxc/<CTID>.conf with an explicit
#      lxc.idmap that remaps just that one GID onto a single shared host GID,
#      leaving every other uid/gid mapped exactly as Proxmox's implicit
#      default would (0:100000:65536 by default)
#   4. chowns/chmods the shared directory on the host to that GID
#   5. offers to reboot the container so the new mapping takes effect
#
# Safe to re-run: it detects containers that already have an explicit idmap
# and won't clobber it without confirmation.

set -euo pipefail

# ===================== EDIT THESE BEFORE RUNNING =====================
# Path on the Proxmox host to the ZFS dataset/directory being shared.
ZFS_SHARE_HOST_PATH="/tank/shared"

# The single host-side GID that will own the shared directory, and that every
# selected container's chosen in-container group will be remapped onto.
# Must fall inside [SUBID_OFFSET, SUBID_OFFSET+SUBID_SIZE) -- see the check
# in check_subid_range() below for why.
SHARED_GID=110000

# Cosmetic name used if we need to create that GID on the host's /etc/group.
SHARED_GROUP_NAME="ctshare"

# Proxmox's default unprivileged-container uid/gid mapping window. Matches
# the "root:100000:65536" line normally already present in /etc/subuid and
# /etc/subgid on a stock Proxmox host. Only change this if you know your
# containers use a different offset/size.
SUBID_OFFSET=100000
SUBID_SIZE=65536

# Permissions applied to the shared directory on the host.
# 2770 = rwxrws--- (setgid so new files/dirs inherit the shared group).
SHARE_DIR_MODE=2770

# Where the share should appear inside each container (used only if we need
# to add the bind mount for a container that doesn't have it yet).
MOUNT_POINT_IN_CT="/mnt/shared"
# =======================================================================

log()  { printf '%s\n' "$*" >&2; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

confirm() {
    local prompt="$1" reply
    read -r -p "$prompt [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

require_root() {
    [[ "$(id -u)" -eq 0 ]] || die "Run this as root on the Proxmox host."
}

require_pct() {
    command -v pct >/dev/null 2>&1 || die "pct not found -- this must run on a Proxmox VE host."
}

check_subid_range() {
    if (( SHARED_GID < SUBID_OFFSET || SHARED_GID >= SUBID_OFFSET + SUBID_SIZE )); then
        warn "SHARED_GID ($SHARED_GID) is outside the default subgid window" \
             "[$SUBID_OFFSET, $((SUBID_OFFSET + SUBID_SIZE)))."
        warn "You'll also need a matching entry in /etc/subgid for root, e.g.:" \
             "  root:${SHARED_GID}:1"
        confirm "Continue anyway?" || exit 1
    fi
    for f in /etc/subuid /etc/subgid; do
        [[ -f "$f" ]] || warn "$f not found -- unexpected on a Proxmox host."
    done
}

ensure_host_share_dir() {
    if ! getent group "$SHARED_GID" >/dev/null 2>&1; then
        log "Creating host group '${SHARED_GROUP_NAME}' (GID ${SHARED_GID})..."
        groupadd -g "$SHARED_GID" "$SHARED_GROUP_NAME"
    fi

    mkdir -p "$ZFS_SHARE_HOST_PATH"
    chgrp "$SHARED_GID" "$ZFS_SHARE_HOST_PATH"
    chmod "$SHARE_DIR_MODE" "$ZFS_SHARE_HOST_PATH"
    log "Host share dir ready: $ZFS_SHARE_HOST_PATH (group=$SHARED_GID, mode=$SHARE_DIR_MODE)"
}

# Populate two parallel arrays: CT_IDS, CT_DESCS
discover_containers() {
    CT_IDS=()
    CT_DESCS=()
    while read -r vmid status name; do
        [[ "$vmid" =~ ^[0-9]+$ ]] || continue
        CT_IDS+=("$vmid")
        CT_DESCS+=("$vmid  $name  ($status)")
    done < <(pct list | awk 'NR>1 {print $1, $2, $NF}')
}

conf_path() { echo "/etc/pve/lxc/$1.conf"; }

is_unprivileged() {
    local ctid="$1"
    grep -qE '^unprivileged:\s*1' "$(conf_path "$ctid")"
}

has_explicit_idmap() {
    local ctid="$1"
    grep -qE '^lxc\.idmap:' "$(conf_path "$ctid")"
}

show_current_idmap() {
    local ctid="$1"
    if has_explicit_idmap "$ctid"; then
        log "Current explicit idmap for CT $ctid:"
        grep -E '^lxc\.idmap:' "$(conf_path "$ctid")" | sed 's/^/    /'
    else
        log "CT $ctid has no explicit idmap yet (using Proxmox's implicit default: 0:${SUBID_OFFSET}:${SUBID_SIZE})."
    fi
}

# Interactively pick a menu of containers; sets SELECTED_CTIDS array.
select_containers() {
    discover_containers
    (( ${#CT_IDS[@]} > 0 )) || die "No containers found (pct list returned nothing)."

    log ""
    log "Containers on this host:"
    local i
    for i in "${!CT_IDS[@]}"; do
        printf '  [%d] %s\n' "$((i+1))" "${CT_DESCS[$i]}"
    done
    log ""
    read -r -p "Which container(s) do you want to update? (space-separated numbers, or 'all'): " selection

    SELECTED_CTIDS=()
    if [[ "$selection" == "all" ]]; then
        SELECTED_CTIDS=("${CT_IDS[@]}")
    else
        local idx
        for idx in $selection; do
            [[ "$idx" =~ ^[0-9]+$ ]] || { warn "Skipping invalid entry: $idx"; continue; }
            local arr_i=$((idx-1))
            if (( arr_i >= 0 && arr_i < ${#CT_IDS[@]} )); then
                SELECTED_CTIDS+=("${CT_IDS[$arr_i]}")
            else
                warn "Skipping out-of-range entry: $idx"
            fi
        done
    fi

    (( ${#SELECTED_CTIDS[@]} > 0 )) || die "Nothing selected."
}

ensure_bind_mount() {
    local ctid="$1"
    if grep -qE "mp[0-9]+:\s*${ZFS_SHARE_HOST_PATH//\//\\/}," "$(conf_path "$ctid")"; then
        log "CT $ctid already bind-mounts $ZFS_SHARE_HOST_PATH."
        return
    fi

    if confirm "CT $ctid has no bind mount for $ZFS_SHARE_HOST_PATH -- add one at $MOUNT_POINT_IN_CT now?"; then
        local next_mp=0
        while grep -qE "^mp${next_mp}:" "$(conf_path "$ctid")"; do
            next_mp=$((next_mp+1))
        done
        pct set "$ctid" -mp"${next_mp}" "${ZFS_SHARE_HOST_PATH},mp=${MOUNT_POINT_IN_CT}"
        log "Added mp${next_mp} to CT $ctid: ${ZFS_SHARE_HOST_PATH} -> ${MOUNT_POINT_IN_CT}"
    else
        log "Skipping bind mount for CT $ctid -- add it yourself before the GID mapping will be useful."
    fi
}

# Resolve the in-container GID that should be remapped. Many community-scripts
# LXCs (e.g. qbittorrent) run their service as root with no dedicated service
# account, so the usual answer here is "create a new group and add root to it"
# rather than "point at an existing group". This handles both cases.
prompt_target_gid() {
    local ctid="$1" answer resolved gid member

    read -r -p "CT $ctid: existing in-container group name/GID to use, or a NEW group name to create: " answer

    if [[ "$answer" =~ ^[0-9]+$ ]]; then
        echo "$answer"
        return
    fi

    resolved=$(pct exec "$ctid" -- getent group "$answer" 2>/dev/null | cut -d: -f3 || true)
    if [[ -n "$resolved" ]]; then
        echo "$resolved"
        return
    fi

    log "Group '$answer' doesn't exist inside CT $ctid yet."
    confirm "Create it now?" || die "Aborting -- need a group to remap."

    read -r -p "GID to use for '$answer' inside CT $ctid (blank = let the container pick the next free one): " gid
    if [[ -n "$gid" ]]; then
        pct exec "$ctid" -- groupadd -g "$gid" "$answer"
    else
        pct exec "$ctid" -- groupadd "$answer"
    fi
    resolved=$(pct exec "$ctid" -- getent group "$answer" | cut -d: -f3)
    log "Created group '$answer' (GID $resolved) in CT $ctid."

    read -r -p "Which user(s) inside CT $ctid need this group (e.g. root, or the app's service user)? Space-separated, blank to skip: " member
    local u
    for u in $member; do
        pct exec "$ctid" -- usermod -aG "$answer" "$u"
        log "Added '$u' to group '$answer' in CT $ctid."
    done

    echo "$resolved"
}

# Build and append the explicit lxc.idmap lines for one container.
apply_idmap() {
    local ctid="$1" target_gid="$2" conf
    conf="$(conf_path "$ctid")"

    if (( target_gid <= 0 || target_gid >= SUBID_SIZE )); then
        die "Target GID $target_gid must be between 1 and $((SUBID_SIZE-1))."
    fi

    local -a new_lines=()
    new_lines+=("lxc.idmap: u 0 ${SUBID_OFFSET} ${SUBID_SIZE}")
    if (( target_gid > 0 )); then
        new_lines+=("lxc.idmap: g 0 ${SUBID_OFFSET} ${target_gid}")
    fi
    new_lines+=("lxc.idmap: g ${target_gid} ${SHARED_GID} 1")
    local remaining_start=$((target_gid+1))
    local remaining_count=$((SUBID_SIZE - target_gid - 1))
    if (( remaining_count > 0 )); then
        new_lines+=("lxc.idmap: g ${remaining_start} $((SUBID_OFFSET+remaining_start)) ${remaining_count}")
    fi

    log ""
    log "Planned lxc.idmap for CT $ctid (in-container GID ${target_gid} -> host GID ${SHARED_GID}):"
    printf '    %s\n' "${new_lines[@]}"

    if has_explicit_idmap "$ctid"; then
        warn "CT $ctid already has explicit lxc.idmap lines (shown above earlier)."
        confirm "Replace them with the plan above?" || { log "Skipping CT $ctid."; return; }
    else
        confirm "Apply this to CT $ctid?" || { log "Skipping CT $ctid."; return; }
    fi

    local backup="${conf}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$conf" "$backup"
    log "Backed up $conf -> $backup"

    grep -vE '^lxc\.idmap:' "$conf" > "${conf}.tmp"
    printf '%s\n' "${new_lines[@]}" >> "${conf}.tmp"
    mv "${conf}.tmp" "$conf"
    log "Updated $conf."

    if confirm "Reboot CT $ctid now so the new mapping takes effect?"; then
        pct reboot "$ctid"
        log "CT $ctid rebooted."
    else
        warn "CT $ctid must be rebooted before the new mapping takes effect."
    fi
}

process_container() {
    local ctid="$1"
    log ""
    log "==================== CT $ctid ===================="

    if ! is_unprivileged "$ctid"; then
        warn "CT $ctid is privileged -- GID remapping doesn't apply (privileged containers already see host UID/GIDs directly)."
        return
    fi

    show_current_idmap "$ctid"
    ensure_bind_mount "$ctid"

    local target_gid
    target_gid=$(prompt_target_gid "$ctid")
    apply_idmap "$ctid" "$target_gid"
}

main() {
    require_root
    require_pct
    check_subid_range
    ensure_host_share_dir

    if (( $# > 0 )); then
        SELECTED_CTIDS=("$@")
    else
        select_containers
    fi

    local ctid
    for ctid in "${SELECTED_CTIDS[@]}"; do
        process_container "$ctid"
    done

    log ""
    log "Done. Selected containers: ${SELECTED_CTIDS[*]}"
}

main "$@"
