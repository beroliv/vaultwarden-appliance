# Vaultwarden Appliance - Technical Specification

## 1. Purpose and implementation status

Vaultwarden Appliance deploys and operates a LAN-only Vaultwarden service on a
supported Debian-based Linux system. It combines upstream Vaultwarden, Caddy,
Docker, Docker Compose, and Avahi rather than modifying those projects.

The implemented appliance includes installation, local HTTPS, mDNS access,
`vwctl` lifecycle management, verified local-first backups, optional USB
replication, automatic retention, restore, and complete local removal.

Restore is implemented for the appliance's schema-1 backup format and covered
by non-destructive fixture tests. Its final destructive end-to-end validation
on a fresh Raspberry Pi using real backup media remains pending and MUST be
completed before a production-ready restore release is claimed.

## 2. Supported platform

The installer MUST support:

- Linux;
- Debian, Raspberry Pi OS, or a distribution whose `ID_LIKE` includes Debian;
- ARM64/aarch64 and x86-64/amd64;
- Docker Engine with Docker Compose v2 as `docker compose`;
- a LAN IPv4 address where one can be detected from the default route or a
  suitable non-container interface.

The reference platform is 64-bit Raspberry Pi OS on ARM64. At least 2048 MiB of
free space is required at installation time.

Root privileges are required for installation and every mutating management
operation. Internet access is required for initial source, package, and
container-image downloads. LAN clients require working mDNS support to resolve
the appliance's `.local` hostname.

## 3. Scope and exclusions

The appliance MUST remain LAN-only. It MUST NOT automatically configure:

- public Internet exposure or router port forwarding;
- public certificates, ACME, or Let's Encrypt;
- public, dynamic, or third-party DNS;
- router, DHCP-reservation, static-IP, gateway, or interface configuration;
- VPN services;
- Synology, NAS, SMB, NFS, cloud, S3, or other managed backup targets;
- automatic client certificate installation;
- telemetry or proprietary service accounts.

TCP port 80 MUST NOT be published or required. Caddy is the only LAN-facing
container and publishes only TCP port 443. Vaultwarden MUST NOT publish a host
port.

Administrators may inspect and extend the standard Compose and Caddy
configuration at their own responsibility. The appliance MUST fail closed when
it cannot positively identify state that it would modify.

## 4. Filesystem and installed paths

The appliance runtime root is fixed at:

```text
/opt/vaultwarden
```

The bootstrap-managed source checkout is separate and fixed at:

```text
/opt/vaultwarden-appliance-src
```

The runtime layout includes:

```text
/opt/vaultwarden/
  .vaultwarden-appliance
  .appliance-version
  .caddy-access
  .backup-device                  # only after USB setup
  docker-compose.yml
  docker-compose.override.yml
  docker-compose.vwctl.yml
  Caddyfile
  backups/
  certs/caddy-root-ca.crt
  data/vaultwarden/
  data/caddy/data/
  data/caddy/config/
```

The non-secret marker MUST contain exactly:

```text
Vaultwarden Appliance
```

Installed management files include:

```text
/usr/local/bin/vwctl
/usr/local/lib/vaultwarden-appliance/*.sh
/usr/local/libexec/vaultwarden-appliance-usb-setup
/usr/local/libexec/vaultwarden-appliance-backup
/usr/local/libexec/vaultwarden-appliance-restore
/usr/local/libexec/vaultwarden-appliance-mdns
/etc/default/vaultwarden-appliance-mdns
/etc/systemd/system/vaultwarden-appliance-mdns.service
/etc/systemd/system/vaultwarden-appliance-backup.service
/etc/systemd/system/vaultwarden-appliance-backup.timer
```

## 5. Source bootstrap

`bootstrap.sh` is a small source-acquisition wrapper. It is not the appliance
installer and MUST NOT duplicate deployment logic from `install.sh`.

The supported convenient invocation is:

```bash
curl -fsSL https://raw.githubusercontent.com/beroliv/vaultwarden-appliance/main/bootstrap.sh | sudo bash
```

The bootstrap MUST:

1. require root;
2. validate a supported Debian-based operating system and CPU architecture
   consistently with `install.sh`;
3. install Git only if it is missing and install the normal CA certificate
   bundle only when required for the HTTPS checkout;
4. verify HTTPS access to the `main` branch of
   `https://github.com/beroliv/vaultwarden-appliance.git`;
5. create a root-owned, non-world-writable checkout at
   `/opt/vaultwarden-appliance-src`;
6. obtain the complete repository rather than downloading individual files;
7. validate all files and directories required by `install.sh`; and
8. change to the checkout and invoke `bash ./install.sh`.

The bootstrap MUST work from standard input and MUST NOT depend on `$0` or the
bootstrap file being executable or locally present. Git errors MUST remain
visible. Cryptographic release-signature verification is not implemented.

For a new checkout, cloning SHOULD use a root-owned temporary directory below
`/opt` and move the complete checkout into place only after Git succeeds. A
partial clone MUST NOT be mistaken for a valid installed source checkout.

For an existing source path, the bootstrap MUST require all of the following:

- a real directory rather than a symbolic link;
- a standalone Git checkout whose top level is exactly the configured source
  path;
- the exact expected HTTPS `origin` URL;
- branch `main` rather than a detached or different branch;
- a clean tracked and untracked working tree;
- root ownership and no world-writable paths.

Only then may it update with `git pull --ff-only` or equivalent fast-forward-only
semantics. It MUST NOT reset, clean, overwrite, or silently discard local
changes. An unknown existing path MUST be left untouched.

The bootstrap MAY be run again for an existing appliance. After a safe source
update it reruns `install.sh`; it does not call `vwctl update`. Installer reruns
preserve runtime data as specified below.

## 6. Manual source installation and source updates

The supported auditable installation path is:

```bash
sudo apt update
sudo apt install -y git

git clone https://github.com/beroliv/vaultwarden-appliance.git
cd vaultwarden-appliance
sudo ./install.sh
```

A complete checkout is mandatory because `install.sh` consumes `lib/`,
`libexec/`, `systemd/`, `VERSION`, `vwctl`, `mdns-publisher`, and helper files.
Downloading `install.sh` alone is unsupported.

The bootstrap checkout can be updated manually with:

```bash
cd /opt/vaultwarden-appliance-src
sudo git pull --ff-only origin main
sudo ./install.sh
```

Source updates change appliance installer and management scripts. They are
distinct from `sudo vwctl update`, which changes configured Vaultwarden and
Caddy container images. Neither path MUST invoke the other implicitly.

## 7. Installer behavior

`install.sh` is the only full installer. Before significant changes it MUST
check:

- root privileges and the global appliance operation lock;
- operating system and architecture;
- required basic commands;
- at least 2048 MiB available space;
- Docker, Docker Compose v2, and Docker daemon availability;
- availability or appliance ownership of TCP port 443;
- the `/opt/vaultwarden` ownership marker;
- a practical LAN IPv4 address;
- required source helpers and systemd unit files.

If Docker is working, the installer MUST reuse it without reinstalling or
changing daemon configuration. If Docker is missing, it asks with Yes as the
default and installs Docker Engine and Compose v2 from Docker's official Debian
repository. Docker Compose v1 is unsupported.

When invoked through `sudo`, the installer validates `SUDO_USER` and `SUDO_UID`.
It may offer to add that existing non-root user to the standard `docker` group.
It MUST explain that membership grants effective root-level Docker control and
requires a new login session or reboot. Rootless Docker is not configured.

The installer installs missing Avahi and storage prerequisites only where the
implemented feature requires them. It MUST NOT make unrelated system changes.

### 7.1 Existing appliance reruns

An existing `/opt/vaultwarden` is recognized only when the exact regular
`.vaultwarden-appliance` marker exists. An unmarked or unsafe directory MUST be
left untouched and MUST NOT be adopted.

Marked installations are reconciled idempotently. Safe missing project files,
runtime directories, systemd units, managed overrides, and containers may be
recreated. Existing Vaultwarden data, Caddy persistent data and root CA, local
backups, access state, and USB state MUST NOT be overwritten or deleted.

Reruns MUST preserve an existing configured hostname and MUST NOT silently
select a new one.

## 8. Docker and network architecture

The Compose project uses:

```text
containers: vaultwarden, caddy
network:    vaultwarden-appliance
```

Both containers use official upstream images and `restart: unless-stopped`.
Vaultwarden persists `/data` below `/opt/vaultwarden/data/vaultwarden` and joins
the internal appliance network without any host port binding.

Caddy persists `/data` and `/config` below `/opt/vaultwarden/data/caddy`, joins
the same Docker network, and binds only `443:443/tcp` on the host. Caddy reaches
Vaultwarden by the service name `vaultwarden`, never by a hard-coded container
IP address. The Caddy admin API is not exposed to the LAN.

## 9. Local HTTPS and mDNS

The single supported access model is a valid lowercase single-label `.local`
hostname. The default is:

```text
https://vaultwarden.local
```

The selected hostname is stored as one non-secret line in
`/opt/vaultwarden/.caddy-access`:

```text
hostname=vaultwarden.local
```

Caddy's generated configuration is equivalent to:

```caddy
{
    auto_https disable_redirects
}

https://vaultwarden.local {
    tls internal
    reverse_proxy vaultwarden:80
}
```

`tls internal` MUST be used. Public ACME issuers MUST NOT be configured. Caddy's
persistent data MUST survive container recreation so its internal root CA
remains stable.

The installer and `vwctl access` validate the hostname and detect an existing
remote mDNS advertisement. A conflict MUST be rejected; duplicate ownership
MUST NOT be forced. A conflict-free alternative may be proposed.

The appliance publishes an explicit mapping from the hostname to the detected
default-route LAN IPv4 address through an appliance-owned systemd service and
`avahi-publish-address -R --no-fail`. `-R` prevents creation of a competing
reverse record for the machine's existing LAN address. The Linux hostname and
Avahi global hostname MUST remain unchanged.

The publisher wrapper stays attached to systemd and writes readiness state only
after `avahi-resolve-host-name -4` resolves exclusively to the configured LAN
IPv4 address. Early publisher exit, collision, wrong address, or inactive
service is a failure and recent journal output is diagnostic evidence.

mDNS resolution and certificate trust are independent. Resolving the hostname
does not trust Caddy's CA, and trusting the CA does not provide `.local` name
resolution. mDNS is link-local and may be blocked across VLANs, guest networks,
VPNs, multicast filters, or incompatible client resolver policies.

The appliance MUST NOT change router, DNS, DHCP, interface, gateway, static-IP,
or client hosts-file configuration.

## 10. Vaultwarden defaults

Fresh installations use:

```text
Account registration: enabled
Admin panel:          not configured
Admin token:          not configured
DOMAIN:               https://<selected-name>.local
```

The external `DOMAIN` and signup state are appliance-managed in
`docker-compose.vwctl.yml`. Changing these settings may recreate the
Vaultwarden container but MUST preserve its bind-mounted data.

## 11. Management interface

The installer copies `vwctl` to `/usr/local/bin/vwctl`. Read-only commands may
run without root when the caller can access Docker. Mutating commands require
root and print the corresponding `sudo vwctl ...` invocation rather than
invoking `sudo` themselves.

Running `vwctl` without arguments opens a terminal/SSH-friendly interactive
menu. The menu is a UI over the same command functions used by direct commands.
It MUST NOT bypass root checks, safety validation, or confirmations, and it MUST
NOT invoke `sudo` automatically. Invalid choices loop, `0` returns or exits, and
EOF exits cleanly. Direct commands remain the automation interface.

Implemented commands are:

```text
vwctl
vwctl help
vwctl status
vwctl health
vwctl logs [vaultwarden|caddy]
sudo vwctl start
sudo vwctl stop
vwctl update check
sudo vwctl update
sudo vwctl restart
sudo vwctl access [hostname]
vwctl version
vwctl signup status
sudo vwctl signup on|off
vwctl cert info
sudo vwctl cert export
vwctl usb status
sudo vwctl usb setup
vwctl backup status
sudo vwctl backup
sudo vwctl restore
```

Restore is also available from the interactive menu. The menu displays the
same root instruction and does not invoke `sudo` itself.

### 11.1 Global operation lock

The installer, uninstaller, and every mutating `vwctl` operation use a
non-blocking root-owned lock at:

```text
/run/lock/vaultwarden-appliance.lock
```

Concurrent mutation MUST fail clearly rather than wait. Read-only commands do
not acquire the lock.

### 11.2 Status and health

`vwctl status` reports container, access URL, mDNS, resolved/current IPv4,
network, image, signup, and public root CA state.

`vwctl health` is read-only and reports every failed check before returning
non-zero. It verifies Docker and Compose, both containers, network membership,
host port exposure, Avahi and publisher readiness, mDNS address, Vaultwarden
`DOMAIN`, HTTPS `/alive` using the exported root CA, consistency of the public
CA export, persistent data directories, and free space.

### 11.3 Lifecycle operations

`start` starts existing containers without unnecessary recreation, starts mDNS,
and verifies the endpoint. `stop` stops mDNS and both containers without
removing containers, the network, data, or Caddy CA. Avahi remains running.
`restart` recreates only the appliance containers using existing bind mounts and
verifies the result.

`logs` prints the last 100 lines for both services or one selected service and
does not follow indefinitely.

### 11.4 Hostname changes

`sudo vwctl access [hostname]` supports `.local` hostname changes only. It
validates conflicts and confirmation, stores the persistent Caddy root CA hash,
regenerates the complete Caddyfile and access state, updates mDNS and
Vaultwarden `DOMAIN`, removes and recreates only Caddy where possible, and
verifies the resulting HTTPS endpoint with the exported CA.

Persistent Vaultwarden data and `/opt/vaultwarden/data/caddy` MUST NOT be
deleted. The internal root CA hash MUST remain unchanged. The command does not
alter system hostname or external network configuration.

If a hostname change fails, diagnostics identify the failing check. The
generated authoritative hostname configuration remains available for
inspection and a safe rerun; no destructive rollback or CA regeneration is
performed.

## 12. Updates

`vwctl update check` is read-only. It compares local container repository
digests with remote manifest metadata using Docker Buildx when available. It
does not pull images, change containers, update Debian, or prune Docker.

`sudo vwctl update` displays:

```text
Make sure you have a current backup.

Kein Backup, keine Gnade.
No backup, no mercy.

Continue? [y/N]
```

Only `y` or `Y` continues. The command pulls only configured Vaultwarden and
Caddy images and applies them with Docker Compose. Existing bind-mounted data,
access state, backups, and Caddy CA remain. It does not update appliance source,
operating-system packages, or remove images.

Source/bootstrap updates and container updates MUST remain separate and MUST
never invoke each other automatically.

## 13. Certificates

Caddy's persistent internal public root certificate is exported to:

```text
/opt/vaultwarden/certs/caddy-root-ca.crt
```

The exported file is public and readable for transfer to clients. Private CA
keys remain only in Caddy's persistent data and MUST NOT be exported by
certificate operations.

`vwctl cert info` validates and reports the public root and live HTTPS leaf
certificate without reading private keys. `sudo vwctl cert export` atomically
refreshes only the public certificate, validates it as X.509 when OpenSSL is
available, and verifies it byte-for-byte against Caddy's persistent public root.

Each client must explicitly trust the public root CA before Caddy's server
certificate is trusted.

## 14. Block-device discovery

`vwctl usb status` is read-only. It uses `lsblk`, `findmnt`, and Linux block
topology to identify every physical disk backing `/`, `/boot`, and
`/boot/firmware`. Partition and supported device-mapper/LVM parentage MUST be
followed conservatively to all physical backing disks.

System-disk protection is transport-independent. A protected SD, USB, SATA,
NVMe, or other physical disk MUST never be offered. If complete backing
topology cannot be established, including unsupported multi-device layouts,
discovery MUST fail closed.

Candidates MUST be writable, non-zero-size, real whole physical disks.
Partitions, loop, RAM, zram, optical, device-mapper, and other virtual or
composition devices MUST not be selectable. Missing or unknown `TRAN` metadata
MUST NOT by itself exclude a real physical disk.

Discovery reports available device path, vendor/model, serial, size, transport,
removable state, partitions, filesystems, and mounts. It MUST NOT assume stable
names such as `/dev/sda`.

## 15. USB backup-media setup

`sudo vwctl usb setup` uses the global lock and accepts only a numbered entry
from the freshly generated safe candidate list. It records device path,
major/minor number, exact size, resolved non-virtual sysfs path, and available
serial/model/transport identity.

Topology and identity are rescanned before confirmation, after confirmation,
after unmounting, and immediately before filesystem creation. Disappearance,
device-path reuse, identity mismatch, new protected status, unsupported child
layout, or uncertain topology MUST abort without selecting another disk.

The command displays selected device identity and mount state. It proceeds only
after the exact, case-sensitive confirmation:

```text
ERASE USB
```

Any other input cancels without modifying the device. After confirmation, only
filesystems belonging to the selected simple device topology may be unmounted.
The command then creates GPT, one Microsoft Basic Data partition using available
capacity, and an exFAT filesystem labeled `VWBACKUP`. It MUST NOT use `dd`,
perform a full-device wipe, or assume a `${device}1` partition name.

Final verification requires unchanged device identity and system-disk
protection, GPT, exactly one expected partition, expected GPT type, exFAT,
label `VWBACKUP`, a non-empty UUID, and no unexpected mount.

Only after verification is the root-owned mode-0644 state file written:

```text
/opt/vaultwarden/.backup-device
filesystem_uuid=<UUID>
filesystem_label=VWBACKUP
```

UUID is authoritative. USB setup creates no backup, no `/etc/fstab` entry, and
does not leave the filesystem mounted.

## 16. Backup architecture

`sudo vwctl backup` always creates a local primary generation first under:

```text
/opt/vaultwarden/backups
```

The local directory is root-owned, group-readable by `docker`, mode `0750`, and
not world-writable. Managed archives and checksums are `root:docker` mode
`0640`. Root-only staging is below `/run`.

Filenames use UTC and never overwrite an existing generation:

```text
vaultwarden-appliance-YYYYMMDD-HHMMSS.tar.gz
vaultwarden-appliance-YYYYMMDD-HHMMSS.tar.gz.sha256
```

A valid generation is an exact regular non-symlink archive/checksum pair whose
SHA-256 checksum, gzip/tar integrity, required members, and safe archive paths
all verify.

### 16.1 Backup contents and consistency

The archive layout is:

```text
vaultwarden-appliance-backup/
  manifest
  vaultwarden/
    db.sqlite3
    data/
  caddy/
  appliance/
```

Vaultwarden's supported built-in backup command creates the SQLite snapshot
with `VACUUM INTO`. Live `db.sqlite3`, WAL, and SHM files MUST NOT be copied as
the snapshot. Vaultwarden remains running.

The archive contains remaining persistent Vaultwarden files, selected appliance
configuration/state, and complete Caddy persistent data so a future restore can
preserve the internal root CA. The manifest uses `backup_schema=1`, records
version, UTC time, hostname, signup state, image/version data where available,
architecture, CA inclusion, and expected contents, and contains no credential
or private-key content itself.

Complete Caddy data includes sensitive CA private-key material as opaque backup
files. Backups are not encrypted and MUST be protected physically and by access
controls.

### 16.2 Capacity, retention, and USB replication

Before local creation, the backup engine requires the source estimate plus 25
percent and 64 MiB overhead to fit in currently available space. Before a USB
copy, it requires the completed archive size plus 64 MiB overhead. Older
backups MUST NOT be deleted first to manufacture space.

After the new local generation verifies, retention keeps the newest 7 valid
local generations. It removes only older exact verified managed pairs from the
managed directory. Unrelated files, directories, symlinks, incomplete pairs,
ambiguous names, and the new generation MUST be preserved. Ambiguity fails
closed.

If the configured `VWBACKUP` UUID is absent, local backup remains successful
and USB replication is skipped. If present, it must resolve uniquely through
the full filesystem, virtual-device, topology, and system-disk safety checks.

A unique existing safe mount is reused and left mounted. Otherwise the
appliance temporarily mounts at `/run/vaultwarden-appliance/backup` with
`nodev`, `nosuid`, and `noexec`, copies the verified local pair through temporary
filenames, flushes, renames, verifies, and unmounts. It MUST NOT write into an
unmounted empty directory on the system disk.

After a successful USB copy, retention keeps the newest 30 valid USB
generations under the USB root-level `backups/` directory. A present configured
USB copy or retention failure is non-zero but MUST preserve the successful
local generation.

### 16.3 Automatic backup and status

`vaultwarden-appliance-backup.timer` runs every day at 02:30 local system time
with `Persistent=true`. Its one-shot service invokes `/usr/local/bin/vwctl
backup`; scheduled and manual backups therefore share consistency, validation,
replication, retention, capacity, and locking behavior.

`vwctl backup status` is read-only. It validates/counts readable local
generations and reports USB configuration, presence, and timer state. It never
mounts USB. USB generations are inspected only when the validated medium is
already mounted at one unique safe mountpoint.

Administrators may independently replicate `/opt/vaultwarden/backups` with
Syncthing, rsync, NAS tools, or other secure systems. Those tools and targets are
not configured by the appliance.

## 17. Complete removal

Uninstallation is deliberately separate from `vwctl` and its menu:

```bash
cd /opt/vaultwarden-appliance-src
sudo ./remove.sh
```

There is no keep-data mode. Before any destructive action, `remove.sh` MUST:

- require root and acquire the common non-blocking lock;
- positively validate the exact root-owned runtime marker and safe path;
- validate expected containers and network with Compose project/service labels;
- validate systemd fragment paths and installed project-file markers; and
- display the complete deletion scope.

Only the exact, case-sensitive confirmation continues:

```text
REMOVE VAULTWARDEN
```

After confirmation, removal stops/disables only the appliance backup and mDNS
units, removes only positively identified `vaultwarden` and `caddy` containers
and the `vaultwarden-appliance` network, removes explicitly owned management
files, reloads systemd, and deletes `/opt/vaultwarden` only after revalidation
and successful service/container shutdown.

This intentionally deletes Vaultwarden data, database, attachments, sends,
keys, Caddy persistent CA and private keys, exported CA, local backups,
configuration, and USB state. It MUST NOT mount, unmount, format, erase, or
delete data from the actual USB medium.

Removal MUST preserve Docker, Compose, images, Avahi, packages, users, groups,
and unrelated resources. Partial removal must remain safely rerunnable where
ownership can still be proven. No automatic backup is created.

`remove.sh` does not delete `/opt/vaultwarden-appliance-src`. Source removal,
if desired after a successful uninstall, is a separate explicit administrator
action.

## 18. Restore

`sudo vwctl restore` uses the global operation lock and restores only backups
created by the current appliance schema (`backup_schema=1`). It discovers valid
generations under `/opt/vaultwarden/backups` and on a safely identified
`VWBACKUP` filesystem. A configured UUID is preferred. On a newly installed
appliance without USB state, an unconfigured medium may be offered only when
its label, exFAT filesystem, UUID, partition topology, physical backing disk,
and system-disk exclusion all validate. Multiple safe media require an explicit
selection.

USB restore access is read-only. The helper reuses only one unambiguous mount
that already has `ro,nodev,nosuid,noexec`; otherwise it mounts below `/run` with
those options and unmounts only that appliance-created mount. Restore MUST NOT
write to, delete from, format, partition, or otherwise modify USB media.

Before displaying the destructive confirmation, restore copies the selected
archive/checksum pair into a root-only staging directory below `/run` and
verifies all of the following:

- exact managed filename and one-line SHA-256 checksum;
- gzip and tar readability;
- no absolute or parent-traversal member names and no duplicate members;
- regular files and directories only (no symlinks, hardlinks, devices, or
  FIFOs);
- the exact schema-1 manifest keys and safe values without sourcing or
  evaluating backup content;
- a valid SQLite snapshot header;
- the appliance marker, version, access, Caddyfile, official-image Compose,
  internal network, and signup state agree with the manifest; and
- Caddy's internal root certificate and private key are present, parseable,
  and form one cryptographic key pair.

Manifest metadata and the source are shown before the exact, case-sensitive
confirmation:

```text
RESTORE VAULTWARDEN
```

Any other input cancels before appliance data is changed. The selected source,
checksum, USB identity, topology, and read-only mount are revalidated after
confirmation.

Restore records and suspends the automatic-backup timer, stops the backup
service and appliance mDNS publisher, then stops Caddy and Vaultwarden. It
replaces only `/opt/vaultwarden/data/vaultwarden` and
`/opt/vaultwarden/data/caddy` from the verified staging tree and installs the
verified database snapshot without stale WAL/SHM files. Existing local backup
generations under `/opt/vaultwarden/backups` are outside that replacement and
MUST remain intact.

The currently installed management code and base/Caddy Compose files remain
authoritative. Restore regenerates only the appliance-managed access state,
Caddyfile, Vaultwarden `DOMAIN`/signup override, and mDNS state from the
validated backup manifest. Backed-up scripts or executables are never run or
installed.

The restored Caddy data includes the selected backup's original internal root
CA and private key. The public root is exported again, preserving trust for
clients that already trust that backup's CA. Vaultwarden and Caddy are started,
the hostname, mDNS mapping, `DOMAIN`, networks, host-port policy, HTTPS endpoint,
and CA continuity are checked through `vwctl health`, and only then may USB
UUID state be adopted and the prior timer state restored.

Restore does not create an automatic pre-restore backup and does not perform an
automatic data rollback after replacement begins. A critical post-confirmation
failure is explicit and leaves recovery evidence rather than guessing at an
unverified rollback. Administrators MUST retain an independent verified backup.

Foreign Vaultwarden backups, raw database copies, other archive layouts, and
future unknown schemas are rejected. Migration from another installation must
use Vaultwarden's supported export/import facilities and explicit transfer of
other required data rather than pretending a foreign archive is an appliance
restore.

The implementation has automated non-destructive security and workflow tests.
Destructive end-to-end restore validation on a freshly installed reference
Raspberry Pi with real local and USB backups remains a release-readiness task.

## 19. Error handling and safety

Critical failures MUST be explicit and non-zero. Destructive or mutating
operations MUST NOT silently continue when validation fails. Missing optional
USB media is informational only after local backup success.

Symbolic links, unexpected file types, ambiguous topology, foreign same-named
Docker/systemd resources, unknown installation paths, and concurrent mutation
MUST fail closed. A failure MUST NOT broaden deletion or storage-selection
scope.

The appliance MUST NOT use broad Docker prune operations, automatically remove
images, uninstall shared packages during removal, or change unrelated users,
groups, services, network configuration, or storage.

## 20. Testing and release readiness

Shell scripts MUST remain readable, Bash-specific where required, and suitable
for ShellCheck. Automated tests use mocks and temporary fixtures for storage,
backup, restore, menu, bootstrap, and removal behavior; they MUST NOT touch real
disks, live appliance data, or GitHub.

Required validation for changes includes:

- `bash -n` for every shell file;
- ShellCheck;
- all repository tests;
- `git diff --check`;
- targeted audits for prohibited destructive commands when storage, bootstrap,
  or removal behavior changes.

The reference end-to-end environment remains a clean supported Raspberry Pi.
Installation, mDNS, trusted HTTPS, Vaultwarden account creation, health checks,
manual/automatic backup, USB behavior, source updates, container updates,
restore, and removal require real-system validation. Restore code is complete,
but its destructive fresh-Pi validation remains pending as stated in section
18.

## 21. Project principles

Implementation decisions follow this order:

1. Data safety
2. Predictable behavior
3. Simple installation
4. Simple maintenance
5. Understandable implementation
6. Compatibility with upstream Vaultwarden, Caddy, Docker, and Avahi
7. Additional features

The project is not a general-purpose server-management platform. It is a small,
transparent, LAN-first appliance built from standard upstream components.
