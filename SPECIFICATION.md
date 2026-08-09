# Vaultwarden Appliance — Specification

## 1. Project Goal

Vaultwarden Appliance provides a simple, reproducible way to deploy and operate a LAN-first Vaultwarden server on a Raspberry Pi or compatible Debian-based Linux system.

The appliance combines existing, trusted components rather than modifying or forking Vaultwarden itself.

Core components:

* Vaultwarden
* Caddy
* Docker
* Docker Compose
* Avahi/mDNS
* `vwctl` management utility
* Automated USB backups

The intended installation experience is:

```text
Fresh Debian / Raspberry Pi OS
        ↓
Run one installer command
        ↓
Answer a few simple questions
        ↓
Vaultwarden + HTTPS + Backup
        ↓
Ready-to-use LAN appliance
```

The project should favor simplicity, understandable code, safe defaults and predictable behavior over a large feature set.

---

## 2. Target Users

The appliance is intended for users who:

* can install and access a Raspberry Pi or Debian server;
* have basic Linux and networking knowledge;
* want to self-host Vaultwarden;
* do not want to manually configure Docker Compose, Caddy, certificates, backups and routine maintenance.

The appliance is **not intended to completely hide Linux or networking concepts**.

The appliance is LAN-only. Public Internet exposure is outside the project scope.

---

## 3. Scope of Version 1

Version 1 MUST provide:

* automated installation;
* Docker and Docker Compose prerequisite checks;
* Vaultwarden deployment;
* Caddy reverse proxy;
* HTTPS using Caddy's internal CA;
* LAN-first configuration;
* simple account registration;
* `vwctl` management utility;
* automatic USB backups;
* backup retention and storage overflow protection;
* backup restore;
* export of the Caddy root CA certificate;
* understandable status and error messages.

Version 1 MUST remain intentionally small.

---

## 4. Out of Scope

Version 1 will NOT automatically configure:

* public Internet access;
* public TLS certificates;
* Let's Encrypt;
* DynDNS;
* public DNS providers;
* Cloudflare;
* router port forwarding;
* router or local DNS configuration;
* static IP or DHCP reservation configuration;
* VPN services;
* NAS backup targets;
* cloud backup services;
* S3;
* Synology integration;
* Google Drive;
* OneDrive;
* Dropbox;
* email servers;
* monitoring platforms.

Advanced users may extend the standard Caddy and Docker Compose configuration themselves.

The appliance MUST NOT intentionally prevent such modifications.

---

## 5. Installation Path

The appliance MUST use:

```text
/opt/vaultwarden
```

as its installation directory.

This path is intentionally compatible with common existing Vaultwarden installations and should simplify future migration of existing deployments.

The project should avoid unnecessary directory restructuring that would make migration more difficult.

A possible layout is:

```text
/opt/vaultwarden/
├── docker-compose.yml
├── docker-compose.override.yml
├── docker-compose.vwctl.yml
├── .caddy-access
├── .env
├── Caddyfile
├── certs/
│   └── caddy-root-ca.crt
├── data/
│   ├── vaultwarden/
│   └── caddy/
│       ├── data/
│       └── config/
```

The final directory structure may evolve during implementation, but `/opt/vaultwarden` MUST remain the root directory.

The management command is installed separately as `/usr/local/bin/vwctl`.

The hostname-only access state contains one non-secret line:

```text
hostname=vaultwarden.local
```

The appliance also owns `/etc/default/vaultwarden-appliance-mdns` and
`/etc/systemd/system/vaultwarden-appliance-mdns.service`. These files persist
an explicit mDNS hostname-to-LAN-IPv4 publication without changing either the
Linux system hostname or Avahi's global hostname. The service runs
`avahi-publish-address -R --no-fail` continuously and stores the validated
`.local` hostname and detected LAN IPv4 address in the environment file. The
no-reverse option makes the name an additional alias without competing for the
reverse record of the machine's existing LAN address. An appliance-owned
wrapper MUST keep the publisher attached to systemd, verify the exact published
mapping and return a failure status if the publisher exits before or after
publication, including when the underlying utility reports a collision but
exits successfully.

---

## 6. Installer

Installation requires a complete repository checkout. From that checkout it is
launched with:

```bash
sudo ./install.sh
```

`install.sh` is not a remote bootstrap downloader. The repository copies of
`vwctl`, `mdns-publisher`, `VERSION`, and the shared `lib/` scripts MUST be
present beside it. The installer copies required runtime files into their final
system locations.

### 6.1 System Checks

Before making changes, the installer MUST check:

* supported operating system;
* CPU architecture;
* available disk space;
* Docker availability;
* Docker Compose availability;
* Docker daemon status;
* availability of required TCP port 443;
* existing `/opt/vaultwarden` installation;
* relevant network configuration.

Before significant changes, the installer MUST also require the basic commands
`curl`, `ip`, `timeout`, `sha256sum`, `cmp`, `flock`, `lsblk`, and `findmnt`.
On Debian it may install the corresponding normal packages where appropriate;
otherwise it MUST fail with clear package guidance. Docker Buildx, OpenSSL, and
`journalctl` remain optional or command-specific dependencies.

Before Caddy is configured, the installer MUST ensure that Debian's
`avahi-daemon`, `avahi-utils`, and `libnss-mdns` packages are installed and that
Avahi is active. The appliance mDNS service MUST be enabled and active after a
hostname has been selected.

ARM64 Raspberry Pi systems MUST be supported.

Standard Debian-compatible x86-64 systems SHOULD be supported where possible without adding significant complexity.

### 6.2 Existing Docker Installation

If Docker is already installed and functional, the installer MUST use the existing installation.

It MUST NOT reinstall, replace or unnecessarily modify a working Docker installation.

If Docker is missing, the installer MUST ask whether it should install Docker,
with Yes as the default. Phase 2 installs Docker Engine and Docker Compose v2
from Docker's official Debian package repository. Docker Compose v2 MUST be
available as `docker compose`; Docker Compose v1 is not supported.

When the installer is run through `sudo`, it SHOULD validate `SUDO_USER` and
offer to add that non-root user to Docker's standard `docker` Unix group, with
Yes as the default. Existing group membership MUST be left unchanged. The
installer MUST explain that docker-group membership effectively grants
root-level control and that a new login session or reboot is required before a
new membership becomes active. This does not use Rootless Docker and does not
change the Docker daemon configuration.

### 6.3 Existing Appliance Installation

The installer MUST detect an existing appliance installation.

It MUST NOT silently overwrite an existing `/opt/vaultwarden` installation.

Installations created by the appliance MUST contain the non-secret marker file:

```text
/opt/vaultwarden/.vaultwarden-appliance
```

If both the installation directory and marker exist, rerunning the installer
MUST be treated as an existing appliance rather than an error. Non-destructive
checks, including Docker user/group configuration, should continue, but the
installer MUST NOT unnecessarily recreate configuration, overwrite data or
redeploy a running Vaultwarden container.

Marked installations are reconciled idempotently. Missing appliance-owned base
configuration, data directories, managed overrides, or containers are recreated
where safe, but existing persistent Vaultwarden data is never overwritten. This
allows a rerun to recover from a failed first image pull or container creation.
Any unmarked `/opt/vaultwarden` directory MUST be treated as unknown and left
unchanged; current releases do not adopt arbitrary or development-era layouts.

Existing installations and future migration scenarios must be considered before destructive operations are implemented.

---

## 7. Interactive Configuration

The installer SHOULD provide sensible recommended defaults.

A user should normally be able to accept the defaults by pressing Enter.

Example:

```text
Local Vaultwarden name [vaultwarden.local]:
HTTPS [Caddy internal]:
Account registration [Enabled]:
Automatic USB backup [Enabled]:
```

The installer should avoid asking questions whose answer can safely and reliably be detected automatically.

Advanced users may change configurable values.

---

## 8. Network Model

Version 1 is designed primarily for trusted local networks.

The default deployment MUST NOT require:

* a public domain;
* public DNS;
* Internet-facing ports;
* Let's Encrypt.

Caddy MUST provide HTTPS using its internal certificate authority.

The appliance publishes only Caddy's TCP port 443. TCP port 80 is not
published or required. The single supported access architecture is HTTPS using
a `.local` hostname advertised with mDNS. The default and recommended URL is
`https://vaultwarden.local`. Direct-IP HTTPS access is not supported.

The installer MUST NOT configure a static IP or modify NetworkManager, dhcpcd,
systemd-networkd, interfaces, DNS, gateways, routers, DHCP settings, or client
hosts files. The appliance's published mDNS mapping is independent of the Linux
system hostname and Avahi's global hostname. Configuring or changing appliance
access MUST NOT call `hostnamectl` or `avahi-set-host-name`, modify Avahi's
global hostname, or rename the host operating system.

A typical architecture is:

```text
Client
  ↓ HTTPS
Caddy
  ↓
Vaultwarden
```

Vaultwarden MUST NOT publish its HTTP port on the host. Vaultwarden and Caddy
must communicate through the `vaultwarden-appliance` Docker network.

On first Caddy configuration, the installer prompts `Local Vaultwarden name
[vaultwarden.local]:`. The value MUST be a single valid, lowercase DNS label
followed by `.local`. The installer checks whether the requested name is already
advertised by another LAN device. On conflict it MUST refuse to claim that name
and SHOULD offer a conflict-free alternative such as `vaultwarden-2.local`.

The selected hostname is stored in `/opt/vaultwarden/.caddy-access` as
non-secret, human-readable state. The appliance-managed systemd service uses
`avahi-publish-address` to publish exactly that hostname and the detected
default-route LAN IPv4 address. It MUST NOT publish Docker bridge or container
interface addresses for the appliance hostname. The installer verifies with
`avahi-resolve-host-name -4` that the result is exclusively the detected LAN
IPv4 address and additionally checks `getent hosts` where available.

mDNS name resolution and HTTPS certificate trust are separate mechanisms.
mDNS maps the `.local` name to the appliance's current address. Caddy's internal
root CA must still be installed as trusted on each client. Neither mechanism
configures the other.

mDNS is link-local multicast and may not cross subnets, VLANs, guest-network
isolation, VPNs, or multicast-filtering access points. Apple platforms normally
provide Bonjour support. Modern Android provides `.local` mDNS resolution, but
older or customized devices and individual apps may vary. Windows support can
vary by application and policy, and Bonjour-capable software may be required on
affected clients. Linux clients require mDNS resolver integration such as
`libnss-mdns` or appropriately configured `systemd-resolved`.

---

## 9. Caddy

Caddy will provide the HTTPS reverse proxy.

The default configuration MUST use Caddy's internal CA.

Caddy runs as the official Docker image in the appliance Compose project. It
joins the same `vaultwarden-appliance` network as Vaultwarden, publishes only
host TCP port 443 and persists its `/data` and `/config` directories below
`/opt/vaultwarden/data/caddy`. Vaultwarden remains unpublished on the host.

Hostname configuration:

```caddy
https://vaultwarden.local {
    tls internal
    reverse_proxy vaultwarden:80
}
```

The final Caddy configuration must be generated by the installer based on the appliance configuration.

The generated Caddyfile uses the selected local hostname, `tls internal`, and
`reverse_proxy vaultwarden:80`. Caddy's reverse proxy provides WebSocket
upgrade support without a separate route. Automatic HTTP-to-HTTPS redirects
are disabled so that host TCP port 80 is not required.

On reruns, the installer reports and preserves the stored hostname, Caddy
configuration, persistent data and internal CA. It does not silently change a
current `.local` hostname or regenerate the CA.

The Phase 4 `vwctl access` command replaces the complete appliance-managed
Caddyfile and `.caddy-access` state, updates Vaultwarden's managed `DOMAIN`,
then rebuilds Caddy so it can obtain a server certificate for the selected
hostname. Vaultwarden is recreated only when its effective `DOMAIN` changes.
It never removes `/opt/vaultwarden/data/caddy`, so the existing internal root
CA continues to be used. Old Caddyfile content and container-local state are
not migrated to the rebuilt configuration.

Advanced users MUST be able to inspect and manually modify the Caddy configuration.

The project will not automatically configure public certificates in Version 1.

---

## 10. Vaultwarden Account Registration

The default installation SHOULD prioritize a simple first-run experience.

Default state:

```text
Account registration: ENABLED
Admin panel:          DISABLED
Admin token:          NOT CONFIGURED
```

Users can therefore open the Vaultwarden web interface and create an account directly.

Open registration does NOT provide access to existing user vaults.

For a LAN-only appliance, registration may remain enabled if the administrator accepts that any device able to reach the service can create an account.

Registration MUST be controllable through `vwctl`.

Vaultwarden's external URL MUST be explicit in its container environment:

```text
DOMAIN=https://<configured-name>.local
```

Fresh installations set it, installer reruns reconcile it, and access changes
update it together with Caddy and mDNS. The running value is part of the health
check. Persistent Vaultwarden data is not replaced when the container must be
recreated for a changed `DOMAIN`.

Required commands:

```bash
sudo vwctl signup on
sudo vwctl signup off
```

---

## 11. Vaultwarden Admin Panel

The Vaultwarden Admin Panel is not required for normal appliance operation.

It SHOULD therefore be disabled by default.

No Admin Token should be required during normal initial installation.

A future or optional command may provide:

```bash
vwctl admin enable
```

If implemented, the appliance SHOULD securely generate and configure the required Admin Token automatically.

Admin functionality is secondary to the Version 1 core requirements.

---

## 12. vwctl

The appliance MUST provide a management command named:

```bash
vwctl
```

`vwctl` should hide routine Docker Compose implementation details while keeping the underlying system transparent and accessible to advanced users.

The repository contains the Bash source script `vwctl`. The installer copies it
to `/usr/local/bin/vwctl` with executable permissions. Read-only commands work
without `sudo` when the user can access Docker. Mutating commands require root
and print the corresponding `sudo vwctl ...` command instead of invoking sudo.

The installer and every mutating `vwctl` command use the same non-blocking,
root-owned runtime lock at `/run/lock/vaultwarden-appliance.lock`. If another
operation holds it, the new operation fails clearly without waiting. The lock
applies to install, start, stop, restart, update, access, signup changes,
certificate export, `usb setup`, and manual `backup`. Status, health, logs, version, update
check, signup status, certificate info, `usb status`, and help do not acquire
it.

Phase 4 provides:

```bash
vwctl status
vwctl health
vwctl logs [vaultwarden|caddy]
sudo vwctl start
sudo vwctl stop
sudo vwctl update
vwctl update check
sudo vwctl restart
sudo vwctl access [hostname]
vwctl version
vwctl signup status
sudo vwctl signup on
sudo vwctl signup off
vwctl cert info
sudo vwctl cert export
```

Backup and restore commands remain future phases.

Phase 5A adds read-only block-device discovery. Phase 5B turns the setup command
into explicit destructive backup-media initialization:

```bash
vwctl usb status
sudo vwctl usb setup
```

`vwctl usb status` remains read-only. `sudo vwctl usb setup` is destructive only
after numbered selection, repeated safety revalidation and an exact
`ERASE USB` confirmation. Phase 5B initializes media but does not
create a Vaultwarden backup.

### 12.1 Update

`sudo vwctl update` pulls only the configured Vaultwarden and Caddy images and
then applies them with Docker Compose:

```bash
docker compose pull vaultwarden caddy
docker compose up -d vaultwarden caddy
```

Compose recreates containers only when their image or effective configuration
changed. The command verifies both containers, the internal Docker network and
the HTTPS endpoint. It preserves all bind-mounted Vaultwarden and Caddy data,
the access state and the internal root CA. It does not update the operating
system or prune Docker images.

An update MUST NOT silently destroy existing data or configuration.

Immediately before the first image/container mutation, the command displays:

```text
Make sure you have a current backup.

Kein Backup, keine Gnade.
No backup, no mercy.

Continue? [y/N]
```

Only a literal `y` or `Y` continues. Enter, `n`, or any other input cancels
without pulling images or changing containers. The appliance neither creates a
backup nor checks backup existence or age: the administrator is responsible for
having a suitable current backup. `vwctl update check` remains read-only and
does not show this confirmation.

`vwctl update check` is read-only. It obtains each running container's local
repository digest and compares it with the configured image reference's remote
manifest digest using Docker Buildx. It does not pull images, recreate or
restart containers, update Debian, or prune anything. Results distinguish an
up-to-date image, an apparently available update, and metadata that could not
be determined. Registry access and Docker Buildx are required for this check.

### 12.2 Status

`vwctl status` presents human-readable Vaultwarden and Caddy state, configured
HTTPS URL, mDNS service state, advertised name, resolved LAN IPv4 address,
current appliance IPv4 address, Docker network status, container images, signup
state and root CA export state.

```text
Vaultwarden:       Running
Caddy:             Running
mDNS:              active
mDNS name:         vaultwarden.local
URL:               https://vaultwarden.local
Resolved IP:       192.168.0.192
Current IP:        192.168.0.192
Signup:            enabled
Root CA:           /opt/vaultwarden/certs/caddy-root-ca.crt
```

### 12.3 Health

`vwctl health` runs independent, read-only checks and reports every failure
before returning a non-zero status. It verifies Docker daemon and Compose v2
access; that Vaultwarden and Caddy exist, run, use the
`vaultwarden-appliance` network and publish only their intended ports; that
Avahi and the appliance mDNS publisher are active; that the ready file and
`.local` resolution match the detected LAN IPv4 address; that `/alive`
validates with the exported Caddy root CA; that the export matches Caddy's
persistent public root certificate; and that both data directories exist with
at least 2048 MiB of free space. The running Vaultwarden `DOMAIN` must also equal
the configured appliance URL.

The check does not modify the system. A user without access to Docker's Unix
socket may run it with `sudo`, although it is otherwise a read-only command.

### 12.4 Logs, Start, Stop and Restart

`vwctl logs` shows the last 100 lines from both services without following
indefinitely. An optional `vaultwarden` or `caddy` argument selects one service.

`sudo vwctl start` uses the existing Compose configuration to start
Vaultwarden and Caddy with `--no-recreate`, starts the appliance mDNS publisher
and verifies the containers, network, mDNS and HTTPS endpoint. It is safe when
services are already running.

`sudo vwctl stop` stops the appliance mDNS publisher followed by Caddy and
Vaultwarden. It verifies that all three are inactive. It does not remove
containers, the Docker network, persistent data, or Caddy CA data, and it
leaves `avahi-daemon` running for unrelated services.

`sudo vwctl restart` force-recreates only the two appliance containers using
the existing Compose configuration and persistent bind mounts, then verifies
both containers and HTTPS. It preserves the internal root CA.

### 12.5 Access Configuration

`sudo vwctl access` and `sudo vwctl access hostname` both prompt for a new local
`.local` hostname, validate it, check for a conflicting mDNS advertisement and
request explicit confirmation. Direct-IP access is not supported. Hostname
changes never modify the Linux system hostname or any
external network configuration.

After validating the requested address and receiving explicit confirmation,
`vwctl` records the SHA-256 hash of Caddy's persistent public root CA. It stops
and removes only the Caddy service container, generates a complete formatted
appliance Caddyfile, rewrites the hostname-only `.caddy-access`, and validates
the new configuration with a one-off Caddy Compose container. It writes the
same URL to the managed Vaultwarden `DOMAIN`, updates
and verifies the appliance-managed explicit Avahi hostname-to-LAN-IP
publication, applies the Vaultwarden configuration, and then creates Caddy with
`--no-deps`. Persistent Vaultwarden data remains untouched.

Success requires Caddy and Vaultwarden to be running, Caddy to use the
`vaultwarden-appliance` network and publish only TCP 443, Vaultwarden to publish
no host ports, and the new HTTPS endpoint to validate using the exported root
CA. Avahi and the appliance mDNS service must be active, and the selected name
must resolve through mDNS to the current LAN IPv4 address. The persistent root
CA hash must remain unchanged. The public root certificate export is refreshed
and checked against the persistent root.

The access command never removes `/opt/vaultwarden/data/caddy/data` or
`/opt/vaultwarden/data/caddy/config`. This preserves the internal root CA while
the rebuilt Caddy configuration obtains the appropriate leaf certificate for
the selected address.

Access changes do not use automatic rollback. If formatting, validation,
container creation or verification fails, `vwctl` reports the failing check and
leaves the generated Caddyfile and authoritative hostname state in place for
inspection. The administrator can correct the
reported problem and rerun `sudo vwctl access hostname`.

### 12.6 Signup Management

Signup changes use the appliance-managed override file:

```text
/opt/vaultwarden/docker-compose.vwctl.yml
```

This override contains the appliance-managed `DOMAIN` and `SIGNUPS_ALLOWED`
values, preserving every other Compose setting. A candidate override is
validated before it replaces the managed file. Compose recreates Vaultwarden
only when required and both resulting values are verified. On signup-change
failure, the previous override and signup state are restored.

### 12.7 Version Information

The repository's `VERSION` file is the single authoritative appliance version
source. The installer validates it and copies it to the non-secret runtime
state file `/opt/vaultwarden/.appliance-version`. The initial development
version is `0.1.0-dev`; it does not claim a stable release.

`vwctl version` reports that appliance version, running Vaultwarden and Caddy
versions where they can be queried reliably, and Docker and Docker Compose
versions. When a container runtime version is unavailable, it reports the
configured image reference instead of guessing.

### 12.8 Certificate Information and Root CA Export

`vwctl cert info` uses OpenSSL to show the exported public root CA path,
SHA-256 fingerprint, subject, issuer and validity period. It obtains the live
HTTPS leaf certificate for the configured `.local` name through TCP 443,
validates it with the exported root CA and hostname, and reports its SHA-256
fingerprint, subject, issuer, validity period and subject alternative names.
The command fails clearly if OpenSSL is unavailable or the endpoint cannot be
validated. It never reads or displays a private key.

`sudo vwctl cert export` atomically refreshes only the public certificate at
`/opt/vaultwarden/certs/caddy-root-ca.crt`, sets readable permissions and
verifies it byte-for-byte against Caddy's persistent public root certificate.
Private CA keys are never read or exported.

The installer uses the same safety properties: it rejects a symbolic-link or
non-regular source, copies through a securely created temporary file, validates
the copy as X.509 when OpenSSL is available, and atomically installs only the
public root certificate. It never reads or copies Caddy's private CA key.

Future backup-specific diagnostics remain part of later phases and are not
included in `vwctl health` yet.

---

## 13. USB Backup

Automatic external backup is part of Version 1.

A backup stored only on the same SD card or system disk as Vaultwarden MUST NOT be considered sufficient as the appliance's backup solution.

USB mass-storage devices will be the supported external backup target.

Other backup targets are outside Version 1 scope.

---

## 14. USB Device Detection

Phase 5A provides block-device discovery through `vwctl usb status`. Phase 5B
uses the same discovery and protection logic for `sudo vwctl usb setup`, which
deliberately initializes one explicitly selected backup disk.

Discovery uses `lsblk`, `findmnt`, and the Linux block-device topology. The
physical disk or disks backing `/`, `/boot`, and `/boot/firmware` MUST be
resolved and marked as protected. Parent traversal MUST handle normal
partitions and conservatively resolve device-mapper or LVM stacks to all
physical backing disks. The protection is transport-independent: an SD card,
USB flash drive, USB SSD, SATA disk, or NVMe disk containing a protected system
mount MUST never be offered as a candidate.

If the backing physical disk cannot be established with confidence, discovery
MUST fail closed rather than expose a possibly destructive choice. Known
multi-device layouts that cannot be proven safe from the available topology,
including multi-device Btrfs system filesystems, MUST also fail closed.

Only writable, non-zero-size, whole real disks may be candidates. Partitions,
loop, RAM, zram, device-mapper, and similar pseudo or composition devices MUST
not be offered. Candidate detection MUST NOT require `TRAN=usb`, because USB
bridges and other legitimate external storage may omit or report misleading
transport metadata.

For protected disks and candidates, the command SHOULD report the device path,
vendor/model, serial number, size, transport, removable flag, partitions,
filesystems, and mount points where available. It MUST NOT assume a fixed
device name such as `/dev/sda`.

`sudo vwctl usb setup` uses the normal global appliance operation lock. It
numbers only the safe candidate list and accepts only a number generated for
that invocation. A raw device path such as `/dev/sdb`, an out-of-range value,
or a protected system disk is rejected.

At selection time the command records the device path, major/minor number,
exact size, resolved non-virtual sysfs path and available serial, model, and
transport values. Before confirmation, after confirmation, after unmounting,
and immediately before filesystem creation, it performs a fresh
`lsblk`/`findmnt`/sysfs scan. The disk must still have exactly the same identity,
remain a real whole physical candidate and remain outside the complete backing
set for `/`, `/boot`, and `/boot/firmware`. A disappearance, reused device path,
identity mismatch, new protected role, or unsupported composite layout aborts
the operation. No replacement candidate is selected automatically.

If filesystems on the selected disk or its simple child partitions are mounted,
their mountpoints are displayed before confirmation. After successful exact
confirmation, only those device nodes are unmounted. Failure to unmount or a
remaining mount aborts before the partition table is changed.

---

## 15. USB Filesystem

The recommended USB backup filesystem is:

```text
exFAT
```

The main reasons are portability and easy access from Windows, macOS and Linux systems.

Existing suitable filesystems may be retained if supported by the implementation.

Phase 5B uses `sfdisk` from Debian's `fdisk` package and `mkfs.exfat` from
`exfatprogs`. The installer installs only missing required packages and verifies
that `sfdisk`, `mkfs.exfat`, `lsblk`, `findmnt`, `umount`, and `readlink` are
available.

After exact destructive confirmation, the setup command creates:

```text
GPT partition table
one Microsoft Basic Data partition using the usable device capacity
exFAT filesystem labeled VWBACKUP
```

It does not use `dd`, perform a full-device wipe, or mount the resulting
filesystem. `sfdisk` replaces only the partition metadata required for the new
layout, asks the kernel to reread it and uses a block-device lock. The actual
child partition is rediscovered from block topology; `${device}1` is never
assumed.

Final verification requires GPT, exactly one expected partition, the Microsoft
Basic Data GPT type, exFAT, label `VWBACKUP`, a non-empty filesystem UUID, no
unexpected mountpoint, unchanged disk identity, and continued system-disk
protection.

Only after successful verification, the appliance atomically installs the
root-owned, non-secret state file `/opt/vaultwarden/.backup-device` with mode
`0644`:

```text
filesystem_uuid=<UUID>
filesystem_label=VWBACKUP
```

The file is not group- or world-writable. UUID is authoritative; `/dev/sdX` is
not stored. `vwctl usb status` requires exactly one UUID match, verifies exFAT
and label `VWBACKUP`, and resolves the filesystem through the safe topology to
one real, non-system physical disk. It reports label, UUID, presence, current
device path when uniquely present, and mount state. Absence is normal and does
not make the appliance unhealthy. Duplicate UUIDs, mismatched filesystem
metadata, protected backing disks, virtual devices, and unsupported backing
topologies fail clearly. Phase 5B creates no `/etc/fstab` entry and performs no
automatic mounting.

---

## 16. USB Formatting Safety

Formatting a storage device is destructive.

`vwctl usb status` remains entirely non-destructive. `sudo vwctl usb setup`
MUST make no disk change until all preflight checks and the exact destructive
confirmation have succeeded.

The installer MUST NOT format any device without explicit confirmation.

A simple Enter or default `Yes` MUST NOT be sufficient for the final destructive confirmation.

Example:

```text
WARNING

All data on the following device will be permanently deleted:

Device: SanDisk Ultra
Path:   /dev/sda
Size:   29.8 GB

Type ERASE USB to continue:
```

The setup command MUST cancel without modification if the exact expected text
`ERASE USB` is not entered. Device identity, serial, topology, system-disk
protection, and final destructive revalidation remain independent safety checks.

After destructive work begins, failures identify the failed step and do not
attempt to restore the old partition table or erased contents. The command does
not touch another disk and instructs the administrator to correct the problem
and rerun setup. Backup, restore, retention, scheduling, automatic mounting,
encryption, and multi-disk sets remain later or out-of-scope work.

---

## 17. USB Capacity

The appliance MUST NOT depend on one specific USB-stick capacity.

Common USB storage sizes should work without configuration changes.

Examples include:

```text
8 GB
16 GB
32 GB
64 GB
128 GB
256 GB
```

Smaller or larger devices may also work if sufficient free capacity exists.

The implementation SHOULD use available capacity rather than hard-coded assumptions.

---

## 18. Backup Format

Backups SHOULD be stored as portable archives.

Example:

```text
vaultwarden-2026-08-07_0300.tar.gz
```

This avoids relying on Unix ownership and permission metadata provided directly by exFAT.

The backup process must preserve all information required for a reliable restore.

The restore process MUST explicitly restore appropriate ownership and permissions on the Linux system.

Phase 5C uses gzip-compressed POSIX tar archives under `backups/` on the
configured `VWBACKUP` filesystem. Filenames use UTC:

```text
vaultwarden-appliance-YYYYMMDD-HHMMSS.tar.gz
vaultwarden-appliance-YYYYMMDD-HHMMSS.tar.gz.sha256
```

Collisions receive a numeric suffix. Existing archives are never overwritten or
deleted. Every archive is read-tested, checked for required members and unsafe
paths, and accompanied by a verified `sha256sum`-compatible checksum.

---

## 19. Backup Contents

The backup MUST contain all data required to restore the Vaultwarden service.

This includes at minimum the relevant Vaultwarden persistent data.

Configuration required for appliance recovery SHOULD also be backed up where appropriate.

The implementation must determine the correct procedure for safely backing up the Vaultwarden database.

A backup MUST NOT simply assume that copying a live database file always produces a valid backup.

Phase 5C provides one manual operation:

```bash
sudo vwctl backup
```

It requires root, holds the global appliance mutation lock, and reuses the
Phase 5B UUID, filesystem, physical-topology, virtual-device, and system-disk
checks. An existing unique safe mount is reused and never unmounted by the
appliance. Otherwise the filesystem is temporarily mounted at
`/run/vaultwarden-appliance/backup` and unmounted on success or best-effort
cleanup. No `/etc/fstab` entry is created.

Vaultwarden 1.37.x's supported built-in `backup` command creates the SQLite
snapshot using `VACUUM INTO`. Only the newly generated snapshot is moved into
root-only runtime staging; live `db.sqlite3`, WAL, and SHM files are excluded
from the archive. Vaultwarden remains running. The archive layout is:

```text
vaultwarden-appliance-backup/
  manifest
  vaultwarden/
    db.sqlite3
    data/
  caddy/
  appliance/
```

The manifest uses independent `backup_schema=1` and records the appliance
version, UTC timestamp, access hostname, signup state, configured/running image
versions where available, source architecture, CA inclusion, and expected
contents. It contains no passwords, tokens, or private-key contents.

Persistent Caddy state is included so a future restore can preserve the
internal root CA and existing client trust. This includes sensitive CA private
key material as opaque files. Phase 5C adds no encryption, so the backup medium
MUST be physically protected. Private keys are never printed or parsed.

Before writing, Phase 5C requires a conservative estimate of source size plus
25 percent and 64 MiB overhead to fit in currently available space. It never
deletes older backups to make room. Failed artifacts may remain for diagnosis.
Restore, automatic backup, scheduling, retention, and backup listing remain out
of scope.

---

## 20. Backup Retention

Automatic backups MUST include retention management.

Users should not need to design their own backup rotation strategy.

Recommended initial defaults:

```text
Automatic backup:      Enabled
Backup time:           03:00

Daily backups:         7
Weekly backups:        4
Monthly backups:       6
```

These values should remain configurable.

The exact implementation of daily/weekly/monthly retention must avoid unnecessary duplicate archives where possible.

---

## 21. Backup Overflow Protection

The backup system MUST protect the USB storage device from filling completely.

Protection SHOULD be based primarily on the actual capacity of the selected storage device rather than a fixed number of gigabytes.

Initial proposed defaults:

```text
Maximum backup usage: 80 %
Reserve free space:   10 %
```

The final values may be refined during testing.

Before creating a backup, the system MUST check available storage.

Old backups should be removed according to the configured retention policy when appropriate.

If sufficient safe storage cannot be made available, the backup MUST fail cleanly rather than fill the filesystem.

---

## 22. Missing USB Protection

The appliance MUST verify that the configured USB filesystem is actually mounted before writing a backup.

If the USB device is missing or not mounted, the backup MUST NOT write into an empty mount directory on the Raspberry Pi's system disk.

Instead, the backup must abort and clearly report the problem.

This is a critical safety requirement.

---

## 23. Backup Directory Structure

A possible USB layout is:

```text
VW-BACKUP/
├── backups/
│   ├── daily/
│   ├── weekly/
│   └── monthly/
├── certificate/
│   └── vaultwarden-root-ca.crt
└── README.txt
```

The exact layout may be adjusted during implementation if this improves retention handling or restore reliability.

It should remain understandable when the USB device is connected to another computer.

---

## 24. Caddy Root CA Export

The Caddy internal root CA certificate MUST be easily exportable.

Phase 3 exports only Caddy's public root certificate to:

```text
/opt/vaultwarden/certs/caddy-root-ca.crt
```

The source certificate remains in Caddy's persistent data beneath
`/opt/vaultwarden/data/caddy/data`. The private CA key MUST remain there and
MUST NOT be copied or exported. Client devices must explicitly trust the
exported root certificate before the local HTTPS endpoint is trusted.

When USB backup is configured, the appliance SHOULD automatically place a copy on the USB storage device.

Example:

```text
VW-BACKUP/certificate/vaultwarden-root-ca.crt
```

The USB device SHOULD also contain a short README explaining that this certificate must be installed as a trusted root certificate on client devices that connect to the appliance.

The appliance MUST also provide:

```bash
sudo vwctl cert export
```

to export the certificate again when required.

Private CA keys MUST NOT be exported together with the public root certificate.

---

## 25. Restore

Version 1 MUST provide a usable restore procedure.

The primary interface should be:

```bash
vwctl restore
```

Example interaction:

```text
Available backups:

1) 2026-08-07 03:00
2) 2026-08-06 03:00
3) 2026-08-05 03:00

Select backup [1]:
```

Before restoring, the appliance MUST:

* verify that the selected backup exists;
* perform reasonable integrity checks;
* stop or isolate services when required;
* avoid restoring into an actively changing database;
* restore required ownership and permissions;
* restart the required services;
* verify service health after restoration.

A failed restore SHOULD leave enough diagnostic information for recovery.

---

## 26. Error Handling

The project should fail safely and provide understandable errors.

Scripts MUST NOT silently continue after critical failures.

Important operations should use appropriate exit codes.

Particular care is required for:

* disk formatting;
* restore operations;
* existing installations;
* Docker failures;
* missing USB backup targets;
* insufficient storage;
* invalid configuration;
* port conflicts.

---

## 27. Transparency

The appliance should simplify administration without hiding the underlying system unnecessarily.

Advanced users should still be able to:

* inspect Docker Compose configuration;
* inspect `.env`;
* inspect Caddy configuration;
* use normal Docker commands;
* modify Caddy manually;
* implement their own external backup solution.

The appliance MUST NOT require proprietary services, accounts or telemetry.

---

## 28. Security Philosophy

The project should avoid implementing security-critical functionality that is already provided by established upstream projects.

Vaultwarden remains responsible for Vaultwarden functionality.

Caddy remains responsible for HTTPS and certificate handling.

Docker remains responsible for container execution.

The appliance primarily provides:

* installation;
* configuration;
* lifecycle management;
* backup;
* restore;
* diagnostics.

Secure defaults should be preferred where they do not create unnecessary complexity for the LAN-first use case.

---

## 29. Development and Testing

Development should be incremental.

Large one-shot implementations should be avoided.

Recommended implementation phases:

```text
Phase 1  System detection and installer framework
Phase 2  Docker Compose + Vaultwarden
Phase 3  Caddy + internal HTTPS
Phase 4  vwctl basic management
Phase 5A Read-only block-device discovery and selection
Phase 5B Destructive backup-media setup and formatting
Phase 5C Manual verified backup
Phase 6  Automatic backup + retention + overflow protection
Phase 7  Restore
Phase 8  Diagnostics and polish
```

Each phase should be tested before beginning the next.

---

## 30. Reference Installation Test

A clean reference machine should be used for repeated installation testing.

The minimum end-to-end acceptance scenario is:

```text
Fresh supported OS
        ↓
Run installer
        ↓
Accept recommended defaults
        ↓
Avahi advertises vaultwarden.local
        ↓
Vaultwarden starts
        ↓
HTTPS works
        ↓
Create Vaultwarden account
        ↓
USB backup succeeds
        ↓
vwctl status works
        ↓
Update succeeds
        ↓
Restore succeeds
        ↓
Vaultwarden data remains intact
```

The process should be repeatable from a clean installation.

---

## 31. Migration

The use of `/opt/vaultwarden` is intended to simplify future migration from existing Vaultwarden installations.

Migration support does not need to be fully automated in the first implementation.

However, Version 1 development MUST avoid design choices that unnecessarily prevent later migration.

A migration procedure can be added after clean installation, backup and restore functionality have been proven reliable.

The supported appliance access state is one line:

```text
hostname=<name>.local
```

Development-only direct-IP state, two-line access state, and `.caddy-hostname`
fallbacks are no longer supported. A current marked appliance is reconciled in
place: its configured hostname is preserved, the managed Vaultwarden `DOMAIN`
is added or corrected when needed, and missing appliance-owned files or
containers are recreated without replacing persistent Vaultwarden or Caddy
data. An unmarked directory is never adopted automatically.

The persistent explicit publisher uses `avahi-publish-address -R --no-fail` so
the `.local` appliance name is an additional alias for the machine's already
published LAN IPv4 address. It MUST NOT modify the Linux hostname or Avahi's
global hostname. An address advertised by a different LAN device remains a real
conflict, and final verification MUST reject every result other than the
detected LAN IPv4 address. The publisher service remains active and exposes
verified runtime readiness; failure diagnostics include its recent journal.

---

## 32. Project Principles

Development decisions should follow these priorities, in order:

1. Data safety
2. Predictable behavior
3. Simple installation
4. Simple maintenance
5. Understandable implementation
6. Compatibility with upstream Vaultwarden and Caddy
7. Additional features

When a proposed feature significantly increases complexity without being essential to running a local Vaultwarden appliance, it should remain outside the project.

The goal is not to build a general-purpose server management platform.

The goal is:

> A small, reliable, LAN-first Vaultwarden appliance that is easy to install, update, back up and restore.

