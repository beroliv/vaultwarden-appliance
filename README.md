# Vaultwarden Appliance

A LAN-only Vaultwarden appliance for Debian and Raspberry Pi OS using Docker,
Caddy HTTPS, mDNS, simple `vwctl` management, verified local-first backups, and
an appliance-format restore workflow.

Restore is implemented and fixture-tested. Its final destructive validation on
a fresh reference Raspberry Pi is still pending, so retain independent verified
backup copies.

## What it does

- Runs the official Vaultwarden and Caddy images with Docker Compose.
- Serves Vaultwarden as `https://vaultwarden.local` using Caddy's internal CA.
- Advertises the local name with mDNS; no router or DNS changes are normally
  required.
- Publishes only Caddy on TCP port 443. Vaultwarden has no direct LAN port.
- Provides an interactive `vwctl` menu and direct commands for administration.
- Creates verified local backups and keeps the newest 7 generations.
- Optionally copies backups to a safely initialized `VWBACKUP` USB filesystem
  and keeps the newest 30 USB generations.
- Runs the same verified backup automatically every day at 02:30 local time.
- Restores verified appliance backups from local storage or read-only USB while
  retaining the backup's Caddy internal CA.
- Provides a separate, deliberately destructive `remove.sh` uninstaller.

The appliance does not configure public Internet access, public certificates,
router settings, static addresses, or external backup services.

## Requirements

- Debian, Raspberry Pi OS, or a Debian-derived Linux system
- ARM64/aarch64 or x86-64/amd64 CPU
- At least 2 GiB free space for installation
- Root access through `sudo`
- A LAN with TCP port 443 available on the appliance host
- Internet access for the initial source, package, and container downloads
- An mDNS-capable client for `.local` name resolution

The normal reference platform is 64-bit Raspberry Pi OS on ARM64. TCP port 80
is not used or required.

## Quick install

The convenient installation path downloads the small bootstrap, which obtains
the complete repository under `/opt/vaultwarden-appliance-src` and then runs
the real installer:

```bash
curl -fsSL https://raw.githubusercontent.com/beroliv/vaultwarden-appliance/main/bootstrap.sh | sudo bash
```

The bootstrap installs Git only when it is missing. It adds the standard CA
certificate bundle only when an HTTPS checkout requires it. It clones over
HTTPS and does not duplicate installation logic from `install.sh`.

Piping a script into a root shell is convenient but requires trusting its
current contents; cryptographic release-signature verification is not yet
implemented. To inspect everything first, use the manual path:

```bash
sudo apt update
sudo apt install -y git

git clone https://github.com/beroliv/vaultwarden-appliance.git
cd vaultwarden-appliance
sudo ./install.sh
```

The complete checkout is required. `install.sh` uses `lib/`, `libexec/`,
`systemd/`, `VERSION`, `vwctl`, `mdns-publisher`, and other project helpers; do
not download `install.sh` by itself.

The installer checks the operating system, architecture, disk space, Docker,
Docker Compose v2, TCP port 443, the LAN address, and any existing appliance.
It can install Docker from Docker's official Debian repository when Docker is
missing. A working Docker installation is reused without modification.

## First use

1. Run the installer and accept or adjust the proposed local hostname.
2. Open `https://vaultwarden.local` from a client on the same LAN.
3. Trust the exported Caddy root CA on every client that should accept the
   appliance certificate.
4. Run `vwctl` for the interactive menu.
5. Run `vwctl health` for a read-only end-to-end check.

Account registration is enabled initially and the Vaultwarden admin panel is
not configured.

mDNS and HTTPS trust are separate. mDNS resolves `vaultwarden.local` to the
appliance's LAN address; it does not make the certificate trusted. The Caddy
root CA establishes HTTPS trust; installing it does not configure mDNS. Both
must work on a client.

The public root certificate is exported to:

```text
/opt/vaultwarden/certs/caddy-root-ca.crt
```

The private CA key is never exported by certificate commands.

## Common commands

```bash
vwctl
vwctl status
vwctl health
vwctl backup status
sudo vwctl backup
sudo vwctl restore
vwctl update check
sudo vwctl update
vwctl usb status
sudo vwctl usb setup
```

Use `vwctl help` for the complete direct-command list. Running `vwctl` without
arguments opens the terminal menu. The menu never invokes `sudo` automatically
or bypasses an existing confirmation.

Removal remains outside the menu:

```bash
cd /opt/vaultwarden-appliance-src
sudo ./remove.sh
```

## Source checkout and installer reruns

The bootstrap stores its root-owned checkout at:

```text
/opt/vaultwarden-appliance-src
```

Running the bootstrap one-liner again validates that this directory is the
expected HTTPS repository on branch `main`, is owned by root, is not
world-writable, and has no local changes. It then performs a fast-forward-only
update and reruns `install.sh`. An unexpected directory, remote, branch,
ownership state, or modified checkout causes a clear abort; the bootstrap never
uses `git reset --hard`.

The equivalent manual source update is:

```bash
cd /opt/vaultwarden-appliance-src
sudo git pull --ff-only origin main
sudo ./install.sh
```

Installer reruns preserve Vaultwarden data, Caddy's persistent internal CA,
local backups, and configured USB state. They reconcile missing
appliance-owned files and containers where safe.

A source update and a container update are different operations:

- Bootstrap or `git pull --ff-only` updates appliance scripts and installer
  source.
- `sudo vwctl update` pulls and applies Vaultwarden and Caddy container images.

The bootstrap never invokes `vwctl update` automatically.

## Backups

Every backup first creates a verified primary archive/checksum pair under:

```text
/opt/vaultwarden/backups
```

The appliance keeps the newest 7 valid local generations. If a configured
`VWBACKUP` filesystem is present and passes its UUID, filesystem, topology, and
system-disk checks, the completed local pair is copied and verified there. The
newest 30 valid USB generations are retained.

The automatic timer runs daily at 02:30 local system time and calls the same
backup path as `sudo vwctl backup`. A missing or disconnected USB medium does
not fail the primary local backup. A present but invalid or failed USB target
is reported without deleting the successful local generation.

Backups contain sensitive Vaultwarden data and persistent Caddy state,
including internal CA private-key material needed to preserve client trust in a
future restore. Local and USB backups are not encrypted and must be protected
accordingly.

External replication remains the administrator's responsibility. Tools such as
Syncthing, rsync, NAS software, or other secure systems may independently copy
`/opt/vaultwarden/backups/`, but they are not configured or managed by this
appliance.

## USB backup media

`vwctl usb status` is read-only. It never mounts, unmounts, partitions, formats,
or changes a disk.

`sudo vwctl usb setup` is destructive. It lists only real whole physical disks
that are not part of the running system. System-disk protection follows the
actual backing topology for `/`, `/boot`, and `/boot/firmware`, regardless of
whether the system uses SD, SSD, NVMe, SATA, or USB storage.

The selected device is repeatedly revalidated before destructive steps. Setup
continues only after the exact, case-sensitive confirmation:

```text
ERASE USB
```

It then creates one GPT partition with an exFAT filesystem labeled `VWBACKUP`.

## Updates

Before applying any update, make sure a current backup exists outside the
system being updated.

Kein Backup, keine Gnade. No backup, no mercy.

Update appliance source and management scripts:

```bash
cd /opt/vaultwarden-appliance-src
sudo git pull --ff-only origin main
sudo ./install.sh
```

Check and update Vaultwarden/Caddy container images:

```bash
vwctl update check
sudo vwctl update
```

`vwctl update` asks for confirmation, preserves bind-mounted data and Caddy CA
state, and does not update Debian or prune Docker images.

## Certificates

Caddy issues the local server certificate through its persistent internal CA.
The public root certificate must be installed as trusted on each client.

```bash
vwctl cert info
sudo vwctl cert export
```

`cert export` refreshes only the public certificate at
`/opt/vaultwarden/certs/caddy-root-ca.crt`. It never exports private CA keys.

## Removal

Verify an external backup first, then run the separate source script:

```bash
cd /opt/vaultwarden-appliance-src
sudo ./remove.sh
```

The exact confirmation `REMOVE VAULTWARDEN` permanently deletes all local
appliance data, Caddy CA state, configuration, and local backup generations.
There is no keep-data mode. USB backup media remains untouched. Docker, Docker
Compose, Avahi, packages, images, users, and group membership remain installed.

After all critical cleanup and final verification succeed, `remove.sh` also
removes `/opt/vaultwarden-appliance-src` when it can positively identify that
directory as the root-owned canonical bootstrap checkout for this project. An
absent checkout is accepted. A symlink, unsafe ownership or permissions, wrong
Git origin or branch, invalid repository root, or missing project file causes
source cleanup to be skipped without broadening the deletion scope.

Arbitrary/manual Git clones elsewhere are always preserved. For a manual
installation outside the canonical bootstrap path, run `remove.sh` from the
complete checkout used for installation and remove that checkout separately if
desired.

Kein Backup, keine Gnade. No backup, no mercy.

## Restore

Run the root-only restore workflow with:

```bash
sudo vwctl restore
```

The command discovers valid appliance backup generations in
`/opt/vaultwarden/backups` and on a safe `VWBACKUP` USB filesystem. USB media is
mounted read-only with hardened options when necessary; restore never writes to
or deletes from it. An unconfigured but safely identified `VWBACKUP` medium can
be used after a fresh appliance installation.

The selected archive is copied to root-only staging under `/run` before the
confirmation prompt. Its checksum, tar paths and member types, schema-1
manifest, SQLite snapshot, appliance state, and matching Caddy internal CA
certificate/private key are verified. Restore proceeds only after the exact,
case-sensitive text:

```text
RESTORE VAULTWARDEN
```

The workflow temporarily stops automatic backup, mDNS, Caddy, and Vaultwarden;
replaces the verified Vaultwarden/Caddy persistent data; regenerates managed
hostname, Caddy, mDNS, `DOMAIN`, and signup configuration; then starts and
health-checks the appliance. Existing local backup generations are preserved.
The selected backup's Caddy root CA is restored and re-exported so clients that
already trust that CA remain valid.

There is no automatic pre-restore backup or automatic rollback after data
replacement begins. Keep a separate verified copy. Only backups created by
this appliance with `backup_schema=1` are accepted. For a foreign Vaultwarden
installation, use Vaultwarden's supported export/import path and explicitly
transfer any other required data instead of feeding foreign files to this
restore command.

The restore implementation has non-destructive fixture coverage, including
malicious archive cases. A destructive end-to-end restore on a clean reference
Raspberry Pi with real media remains the final release-validation step.

## Security and scope

- The appliance is LAN-only and has no public Internet exposure feature.
- Caddy is the only LAN-facing service and publishes only TCP port 443.
- TCP port 80 is neither published nor required.
- Vaultwarden's HTTP port is available only on the internal Docker network.
- HTTPS uses Caddy's internal CA; Let's Encrypt and public ACME are out of scope.
- Router, DHCP, static-IP, public DNS, and dynamic-DNS configuration are out of
  scope.
- Synology, cloud, S3, NAS, and other external backup integrations are not
  included.
- `VWBACKUP` USB media and backup archives are not encrypted.

The appliance favors data safety, predictable behavior, transparent standard
components, and narrowly scoped automation.
