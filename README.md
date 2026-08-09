# vaultwarden-appliance

Simple LAN-only Vaultwarden appliance with Caddy, local HTTPS, mDNS, `vwctl`,
verified local backups, optional USB replication, and automatic retention.
Restore remains a later phase.

## Installation

Copy or clone the complete repository checkout to a supported Debian or 64-bit
Raspberry Pi OS system, enter that directory, and run:

```bash
sudo ./install.sh
```

The installer performs system checks, can install Docker Engine and Docker
Compose v2 from Docker's official Debian repository, and deploys the appliance
under `/opt/vaultwarden`. A working existing Docker installation is reused
without modification.

`install.sh` is not a remote bootstrap downloader. It requires the repository's
`vwctl`, `mdns-publisher`, `VERSION`, `lib/`, `libexec/`, and `systemd/` files
beside it.

The installer installs Debian's `avahi-daemon`, `avahi-utils`, and `libnss-mdns`
packages when needed. On a fresh configuration it asks:

```text
Local Vaultwarden name [vaultwarden.local]:
```

The name must be a single valid label below `.local`. An appliance-managed
systemd service uses `avahi-publish-address` to publish an explicit mapping from
that name to the detected LAN IPv4 address, so the normal URL is:

```text
https://vaultwarden.local
```

The appliance does not change the Raspberry Pi's system hostname or Avahi's
global hostname and does not
modify router, DNS, DHCP, static-IP, gateway, interface, or client hosts-file
settings. If the requested mDNS name is already advertised by another device,
the installer proposes an available alternative such as
`vaultwarden-2.local`.

Vaultwarden data is stored in `/opt/vaultwarden/data/vaultwarden` and has no
host-published port. Caddy is the only LAN-facing container and publishes only
TCP port 443. Its persistent data, including the internal CA, is stored below
`/opt/vaultwarden/data/caddy`.

Vaultwarden's external `DOMAIN` is managed as the same URL, for example
`DOMAIN=https://vaultwarden.local`. The appliance stores `DOMAIN` and the
current signup setting in `/opt/vaultwarden/docker-compose.vwctl.yml`.

The selected local name is stored as human-readable, non-secret state in:

```text
/opt/vaultwarden/.caddy-access
```

## mDNS and certificate trust are separate

mDNS makes `vaultwarden.local` resolve to the appliance's detected LAN address.
The appliance publication names that address explicitly, so Docker bridge
addresses are not published for the Vaultwarden name.
It does not make the HTTPS certificate trusted. Every client must also trust
Caddy's exported public root CA:

```text
/opt/vaultwarden/certs/caddy-root-ca.crt
```

The private CA key is never exported. Installing the public root certificate
does not configure mDNS, and mDNS resolution does not install the certificate.
Both must work on a client for a trusted `https://vaultwarden.local` connection.

mDNS is link-local multicast. It normally works only within the same LAN or
subnet and can be blocked by guest-Wi-Fi isolation, VLAN boundaries, multicast
filtering, VPNs, or client policy. Apple platforms include Bonjour support.
Modern Android includes `.local` mDNS resolution, while older or vendor-modified
devices and individual apps may vary. Windows application and policy behavior
can vary; Bonjour-capable software may be needed on affected clients. Linux
clients need working mDNS resolver integration, commonly `libnss-mdns` or an
appropriately configured `systemd-resolved`.

## Management

The installer copies `vwctl` to `/usr/local/bin/vwctl`:

```bash
vwctl
vwctl help
vwctl status
vwctl health
vwctl logs [vaultwarden|caddy]
sudo vwctl start
sudo vwctl stop
sudo vwctl update
vwctl update check
sudo vwctl restart
sudo vwctl access
sudo vwctl access hostname
vwctl version
vwctl signup status
sudo vwctl signup on
sudo vwctl signup off
vwctl cert info
sudo vwctl cert export
vwctl usb status
sudo vwctl usb setup
sudo vwctl backup
vwctl backup status
```

Running `vwctl` without arguments opens a plain interactive administration
menu suitable for SSH. It dispatches to the same command paths listed above;
existing confirmations and root checks remain in force. The menu never invokes
`sudo` automatically. Direct commands remain available and are recommended for
scripts and automation. Restore is not included yet.

`vwctl health` performs read-only checks of Docker, both containers and their
ports/network, mDNS, HTTPS with the exported root CA, persistent public CA
consistency, data directories, and free disk space. It reports every failed
check and exits non-zero if the appliance is not healthy.

`sudo vwctl start` starts existing appliance containers without unnecessarily
recreating them and starts the appliance mDNS publisher. `sudo vwctl stop`
stops both containers and that publisher without removing containers, the
Docker network, persistent data, or Caddy CA data. Avahi itself remains
running.

`vwctl version` reads the appliance version installed from the repository's
single `VERSION` file and reports available component versions or configured
images. `vwctl update check` reads remote container manifest metadata without
pulling an image or changing running containers; `sudo vwctl update` remains
the command that applies updates. `vwctl cert info` reads the exported public
root certificate and the live HTTPS leaf certificate. It never reads private
keys.

Immediately before `sudo vwctl update` pulls or changes images and containers,
it reminds the administrator to have a current backup and asks
`Continue? [y/N]`. Only a literal `y` or `Y` continues. The appliance does not
check for a backup or create one automatically; backup responsibility remains
with the administrator. `vwctl update check` stays read-only and does not ask.

Read-only commands can run without `sudo` when the user has access to Docker.
Commands that change appliance state require root and print the exact `sudo`
command when invoked without it. The installer and all mutating `vwctl`
commands use one non-blocking lock at
`/run/lock/vaultwarden-appliance.lock`; a second operation fails clearly instead
of waiting. Read-only commands do not take this lock.

`sudo vwctl access` and `sudo vwctl access hostname` change only the local
`.local` name. After validation, conflict detection, and confirmation, `vwctl`
updates the explicit mDNS hostname-to-LAN-IP publication, regenerates the
complete Caddyfile, updates Vaultwarden's `DOMAIN`, and rebuilds Caddy.
Vaultwarden is recreated only when the effective `DOMAIN` changes. Persistent
Vaultwarden data and Caddy data are not deleted, and the internal root CA hash
must remain unchanged while Caddy obtains a new leaf certificate for the new
hostname.

Direct-IP HTTPS access is no longer supported.

## Existing installations

Reruns recognize `/opt/vaultwarden/.vaultwarden-appliance` and remain
non-destructive. They reconcile missing appliance-owned files and containers,
including a first installation interrupted during an image pull, while
preserving Vaultwarden data and Caddy's persistent internal root CA. Existing
installations also receive the managed `DOMAIN` setting when needed.

Unknown `/opt/vaultwarden` directories without the appliance marker are left
unchanged and are not adopted.

Rerunning the installer refreshes the stored publication address from the
current default-route LAN IPv4 address without changing the Linux system
hostname or Avahi's global hostname. A remote device using the requested alias
remains a conflict.

The systemd service runs an appliance-owned wrapper around
`avahi-publish-address -R --no-fail`. `-R` suppresses the reverse record when
publishing an additional alias for the machine's already-published LAN address.
The wrapper remains active with the publisher, confirms that the hostname
resolves exclusively to the configured LAN IPv4 address, and turns an early
successful publisher exit into a service failure.

## Phase 5A/5B backup-media setup

`vwctl usb status` performs read-only block-device discovery. It inspects the
devices backing `/`, `/boot`, and `/boot/firmware` where present, follows
partitions and supported device-mapper stacks to their complete physical disks,
and marks every such disk as protected. Protection does not depend on whether
the operating system boots from SD, USB SSD, USB flash storage, SATA, or NVMe.

Other writable whole-disk devices are listed with available model, vendor,
serial, size, transport, removable, partition, filesystem, and mount
information. `TRAN=usb` is informative but is not required because some bridges
do not report it reliably. Loop, RAM, zram, optical, and device-mapper pseudo
devices are not selectable. If the system topology cannot be established
safely, discovery fails closed and offers no device.

`sudo vwctl usb setup` is destructive. It uses the global appliance operation
lock and lets the administrator select only a number from the internally
generated safe candidate list. The system disk is never numbered, and entering
a `/dev/...` path is not accepted. The selected disk is identified by its
major/minor number, exact size, serial/model/transport where available, and
resolved kernel device path. The complete topology and identity are scanned
again after selection, after the exact destructive confirmation, and immediately
before each destructive step.

The command displays mounted filesystems belonging to the selected simple disk
layout. Only after the user types the exact `ERASE USB` text are
those selected filesystems unmounted. It then replaces the partition table with
GPT, creates one Microsoft Basic Data partition spanning the usable disk, and
formats it as exFAT with label `VWBACKUP`. There is no default `y/N` confirmation
and no attempt to restore erased data.

After fresh verification of the GPT layout, exFAT label, UUID, unmounted state,
and system-disk protection, the non-secret state is installed atomically at:

```text
/opt/vaultwarden/.backup-device
```

It contains the filesystem UUID and `VWBACKUP` label. `vwctl usb status` locates
the medium by UUID rather than `/dev/sdX`, verifies its exFAT type and label,
and safely resolves it to one real, non-system physical disk. A disconnected
configured medium is reported normally. Phase 5B does not mount the filesystem,
add an `/etc/fstab` entry, create a backup, restore data, schedule jobs, or
implement retention.

## Phase 5D local-first backup

Create one backup with:

```bash
sudo vwctl backup
```

The command holds the global appliance operation lock and always creates and
verifies the primary generation under `/opt/vaultwarden/backups` first. This
directory is root-owned, group-readable by the standard `docker` administrator
group, mode `0750`, and not world-writable. Archives and checksums are installed
as `root:docker` mode `0640`. Backup staging remains root-only under `/run`.

Generations use UTC filenames:

```text
vaultwarden-appliance-20260808-233000.tar.gz
vaultwarden-appliance-20260808-233000.tar.gz.sha256
```

The archive has a predictable restore-oriented layout:

```text
vaultwarden-appliance-backup/
├── manifest
├── vaultwarden/
│   ├── db.sqlite3
│   └── data/
├── caddy/
└── appliance/
```

Vaultwarden's supported built-in `backup` command creates the consistent SQLite
snapshot with `VACUUM INTO`; the live database, WAL, and SHM files are never
copied blindly. Remaining persistent Vaultwarden files, selected appliance
configuration, and complete persistent Caddy state are included. The archive is
read-tested, required members are checked, and a SHA-256 checksum is created and
verified before success. Filename collisions receive a numeric suffix; existing
backups are never overwritten. Incomplete or invalid pairs are not counted as
generations and are never selected by retention.

The Caddy state includes the internal CA private key so a future restore can
preserve client trust. Backups are not encrypted: possession of a local archive
or USB medium can expose Vaultwarden data and the appliance's internal CA
private key.

After the new local archive and checksum have both passed checksum and archive
integrity checks, the appliance keeps the newest 7 valid local generations.
Only exact appliance archive/checksum pairs inside the managed backup directory
can be removed. Unrelated files, directories, symlinks, incomplete pairs, and
ambiguous names are preserved; retention fails closed. Older generations are
never removed to make room before a new backup succeeds.

USB is optional. With no configured medium, or with the configured medium
disconnected, the local backup remains successful and replication is skipped.
When the configured exFAT `VWBACKUP` medium is present and passes the existing
UUID/topology/system-disk checks, the appliance copies the completed local pair
through temporary filenames into its root-level `backups/` directory, flushes
and verifies the copy, then keeps the newest 30 valid USB generations. It does
not create a second archive. A configured-and-present USB copy or retention
failure returns non-zero but never removes the successful local backup. A mount
created by the appliance is unmounted; an existing safe mount is left intact.

Automatic backups are enabled by `install.sh` through
`vaultwarden-appliance-backup.timer`, scheduled every day at 02:30 local time
with `Persistent=true`. Its one-shot service invokes `/usr/local/bin/vwctl
backup`, so manual and scheduled runs use the same engine and global lock.

Inspect backup state without changing or mounting storage:

```bash
vwctl backup status
```

It fully validates readable local generations. It reports configured USB
identity and presence, but only counts USB generations when that medium is
already mounted at one unique safe mountpoint; otherwise counts are shown as
unavailable. It also shows timer enablement and available last/next-run data.
The command normally works for an administrator whose current login session is
in the `docker` group; `sudo vwctl backup status` may be used otherwise.

The appliance does not implement Synology, Syncthing, rsync, SMB, NFS, cloud,
S3, or remote SSH targets. Administrators may independently replicate
`/opt/vaultwarden/backups/` with appropriately secured tools. Restore and backup
encryption are not implemented yet.

## Basic verification

After installation, a concise end-to-end check is:

```bash
vwctl version
vwctl status
vwctl health
vwctl cert info
vwctl update check
vwctl usb status
vwctl backup status
systemctl status vaultwarden-appliance-backup.timer
systemctl is-active avahi-daemon
systemctl is-active vaultwarden-appliance-mdns
avahi-resolve-host-name -4 vaultwarden.local
curl --cacert /opt/vaultwarden/certs/caddy-root-ca.crt \
  https://vaultwarden.local/alive
docker inspect vaultwarden --format '{{json .HostConfig.PortBindings}}'
docker inspect caddy --format '{{json .HostConfig.PortBindings}}'
```

Use the actual hostname reported by `vwctl status` if a conflict-free
alternative was selected. Phase 5B initializes explicitly selected backup
media. Phase 5D uses local-first verified backups, optional USB copies, fixed
7/30-generation retention, and the daily 02:30 timer. Restore is not implemented
yet.
