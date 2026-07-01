# Shared ZFS access for unprivileged Proxmox LXC containers

`fix-lxc-gid-mapping.sh` gives multiple **unprivileged** LXC containers
consistent read/write access to one ZFS-backed directory on the Proxmox host,
without making the containers privileged and without resorting to `chmod 777`.

## Why this is needed

Unprivileged LXC containers remap their internal UID/GID 0-65535 to a
non-root range on the host (by default `100000-165535`, from
`/etc/subuid` / `/etc/subgid`). Each container's root (UID/GID 0) maps to
host UID/GID 100000 by default, and every other in-container ID shifts by the
same +100000 offset. Two different containers therefore normally can't share
a directory by GID, because "GID 1000" inside container A and "GID 1000"
inside container B both map to the **same host GID 101000** already (fine),
*but* the app inside each container may use a different internal GID, and you
don't want to just throw the shared folder open to the entire default
100000-165535 range (that's every UID/GID inside every unprivileged
container on the host).

The fix is a per-container `lxc.idmap` override: carve out **one** in-container
GID and repoint it at a single host GID that you control (e.g. `110000`),
while every other UID/GID keeps the normal default mapping. Put the app's
service group in that carved-out GID in every container that needs the
share, `chgrp`/`chmod` the shared directory to that same host GID once, and
every container can now read/write it via a single shared group — nothing
else on the host gains access.

## What the script does

Run it **on the Proxmox host itself** (SSH in first, e.g. `ssh root@<host>`),
as root:

```
./fix-lxc-gid-mapping.sh          # interactive: queries `pct list`, lets you pick containers
./fix-lxc-gid-mapping.sh 101 105  # non-interactive container selection; still prompts per-container
```

For each container you pick, it will:

1. Skip it if it's privileged (idmap remapping doesn't apply there).
2. Show any existing explicit `lxc.idmap` lines, so you can see what's already configured.
3. Check whether the container already bind-mounts the ZFS share; offer to add
   `pct set <CTID> -mpX <path>,mp=<mountpoint>` if not.
4. Ask for the in-container group that needs access. You can:
   - name an **existing** group/GID, or
   - name a **new** group to create — the script will `groupadd` it inside the
     container and offer to add users (e.g. `root`) to it with `usermod -aG`.
5. Compute and show the exact `lxc.idmap` lines that carve that one GID out to
   the shared host GID, ask for confirmation, back up the container's
   `/etc/pve/lxc/<CTID>.conf`, and write the change.
6. Offer to `pct reboot` the container (idmap changes only take effect after
   a restart).

It's safe to re-run against additional containers later — it's the same
script, just pick different ones from the menu each time.

## Variables to edit before running

At the top of `fix-lxc-gid-mapping.sh`:

| Variable | Meaning | Placeholder |
|---|---|---|
| `ZFS_SHARE_HOST_PATH` | Path to the ZFS dataset/directory on the Proxmox host | `/tank/shared` |
| `SHARED_GID` | Host GID that will own the share and that every container's chosen group gets remapped onto | `110000` |
| `SHARED_GROUP_NAME` | Cosmetic host-side group name for that GID | `ctshare` |
| `SUBID_OFFSET` / `SUBID_SIZE` | Your containers' default unprivileged UID/GID window (check `/etc/subuid`, `/etc/subgid` — Proxmox's stock default is `100000` / `65536`) | `100000` / `65536` |
| `SHARE_DIR_MODE` | Permissions on the shared directory (`2770` = owner+group rwx, setgid so new files inherit the group) | `2770` |
| `MOUNT_POINT_IN_CT` | Where the bind mount appears inside a container, if the script adds one | `/mnt/shared` |

`SHARED_GID` must fall inside `[SUBID_OFFSET, SUBID_OFFSET + SUBID_SIZE)` or
you'll also need a corresponding `root:<gid>:1` line added to `/etc/subgid` —
the script warns you if this is the case.

## Known app-specific gotcha: root-run services

Checked against the [community-scripts/ProxmoxVE](https://github.com/community-scripts/ProxmoxVE)
helper-script install scripts (what most people mean by "the Proxmox
userscripts site"): several of these LXC apps (e.g.
[`qbittorrent-install.sh`](https://github.com/community-scripts/ProxmoxVE/blob/main/install/qbittorrent-install.sh))
run their service as **root** via systemd (`User=root`, no dedicated service
account) rather than a per-app user like the LinuxServer.io Docker images use.
That means there's usually no existing "app user's group" to point at —
when the script asks for a group, answer with a **new** group name (e.g.
`media`) and add `root` as the member when prompted; that's the intended path
for these containers.

If you're running an app as a Docker container (e.g. inside a Docker-in-LXC
setup) instead of a native helper-script install, it likely already uses
`PUID`/`PGID` environment variables — in that case, set `PGID` to the
in-container GID you choose here instead of creating/joining a group.

## Prerequisites

- Root SSH access to the Proxmox host (key-based auth recommended).
- `pct` (already present on any Proxmox VE host — nothing else to install).
- The ZFS dataset/directory already exists (or will after you create it) at
  `ZFS_SHARE_HOST_PATH`.

No additional software needs installing on the containers themselves.
