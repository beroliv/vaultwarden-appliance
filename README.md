# Vaultwarden Appliance

A LAN-only Vaultwarden appliance for Debian and Raspberry Pi OS using Docker,
Caddy HTTPS, optional mDNS or existing local DNS, simple `vwctl` management,
verified local-first backups, and an appliance-format restore workflow.

Version 0.1.2 is a maintenance and usability release after 0.1.1. Data and CA
restore no longer depends on DNS, mDNS, or HTTPS readiness, and post-restore
SQLite verification has been corrected. Existing `VWBACKUP` media can be
adopted safely without formatting, and backup-device state permissions support
unprivileged status checks. Privileged operations can be launched directly from
the `vwctl` menu, whose labels are clearer; restore selection now also offers
`0) Back`.

Real-system validation on Atlas, a Raspberry Pi, covers the public `curl`
bootstrap, installation, complete removal, reinstallation, manual backup, USB
backup replication, restore from an appliance backup, restored account login,
exact Caddy root CA fingerprint continuity, and the post-restore health check.

A complete disaster-recovery exercise starting from a freshly flashed SD card
remains pending. Retain independent verified backup copies.

## What it does

- Runs the official Vaultwarden and Caddy images with Docker Compose.
- Serves Vaultwarden as `https://vaultwarden.local` by default using Caddy's
  internal CA and mDNS, with an existing local DNS server as an alternative.
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
- An mDNS-capable client for the default `.local` name, or an existing local DNS
  server for a custom name

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

1. Run the installer, choose the access mode, and then choose its hostname.
   Press Enter twice for the default `vaultwarden.local` via mDNS.
2. Open the selected URL (default: `https://vaultwarden.local`) from a client on
   the same LAN.
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

mDNS uses local multicast name resolution, so `.local` normally works on the
local LAN. Normal routed VPN configurations such as WireGuard do not
automatically forward mDNS multicast or its name resolution. The appliance may
therefore be reachable by IP through the VPN while `vaultwarden.local` does not
resolve. External/local DNS is the recommended access mode for VPN use, and VPN
clients must be able to reach and use the DNS server that resolves the selected
Vaultwarden hostname.

If you already operate local DNS, enter a name such as `vault.lan`, answer Yes
to the external-DNS prompt, and manually create `vault.lan -> <Raspberry Pi LAN
IP>` on that DNS server. The appliance never changes DNS, hosts, router, DHCP,
or system-hostname settings. Rerun `sudo ./install.sh` to change the hostname or
switch between mDNS and external DNS later.

The current choice is stored as root-owned runtime configuration in
`/opt/vaultwarden/.access`:

```text
mode=mdns
hostname=vaultwarden.local
```

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
sudo vwctl usb adopt
sudo vwctl usb setup
```

Use `vwctl help` for the complete direct-command list. Running `vwctl` without
arguments opens the unprivileged terminal menu. A selected mutating operation
is launched directly as `sudo <vwctl-path> <command> ...`; only that operation
is elevated, using the system's normal sudo authentication. The menu does not
handle passwords and never bypasses an existing confirmation.

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
or changes a disk. If no backup medium is configured, status distinguishes an
existing safe `VWBACKUP` filesystem from a blank disk that would require setup.

`sudo vwctl usb adopt` safely registers an existing exFAT filesystem labeled
`VWBACKUP` by storing only its UUID and label in the appliance state. Adoption
uses the same physical-topology and system-disk exclusions as USB setup, but it
does not mount, write, partition, format, or otherwise modify the medium. This
is the correct command for a previously initialized backup stick.

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
be used after a fresh appliance installation. Its UUID is persisted only after
the restore's data and CA integrity checks succeed; running USB setup is not
part of disaster recovery.

The selected archive is copied to root-only staging under `/run` before the
confirmation prompt. Its checksum, tar paths and member types, schema-1
manifest, SQLite snapshot, appliance state, and matching Caddy internal CA
certificate/private key are verified. Restore proceeds only after the exact,
case-sensitive text:

```text
RESTORE VAULTWARDEN
```

The workflow temporarily stops automatic backup, the active appliance mDNS
publisher when applicable, Caddy, and Vaultwarden; replaces the verified
Vaultwarden/Caddy persistent data; regenerates Caddy and `DOMAIN` from the
currently installed `.access`; then starts Vaultwarden and Caddy. Restore
preflight does not require DNS, mDNS, HTTPS, or the configured hostname to be
reachable. The restored database and Caddy CA are verified locally before
Vaultwarden is started and before network health is evaluated. This preserves a
byte-for-byte snapshot check before Vaultwarden can legitimately write to the
restored SQLite database during startup.
Backups do not contain access configuration, so the current hostname and
mDNS/external-DNS choice are preserved. Existing local backup generations are
also preserved.
The selected backup's Caddy root CA is restored and re-exported so clients that
already trust that CA remain valid.

If the current DNS, mDNS, LAN address, or HTTPS endpoint is not ready, restore
still reports successful data and CA recovery and prints a network-health
warning with the configured URL and next steps. It never configures external
DNS. `sudo vwctl health` remains the strict follow-up check after network
configuration is complete.

There is no automatic pre-restore backup or automatic rollback after data
replacement begins. Keep a separate verified copy. Only backups created by
this appliance with `backup_schema=1` are accepted. For a foreign Vaultwarden
installation, use Vaultwarden's supported export/import path and explicitly
transfer any other required data instead of feeding foreign files to this
restore command.

The restore implementation has non-destructive fixture coverage, including
malicious archive cases. A real restore from an appliance backup has also been
validated on Atlas: the restored account login succeeded, the Caddy root CA
fingerprint exactly matched its pre-removal value, and the post-restore health
check passed. A complete disaster-recovery exercise starting from a freshly
flashed SD card remains pending.

## Last-resort manual recovery

**Preferred recovery:** `sudo vwctl restore`

**Last-resort recovery:** manually extract a verified appliance backup and
migrate its data into a normal new Vaultwarden installation. This fallback does
not require GitHub, this repository, `bootstrap.sh`, `vwctl`, the appliance
installer, Caddy, DNS, or mDNS after the archive and its adjacent checksum have
been obtained. It uses ordinary SHA-256, gzip/tar, SQLite, persistent files,
and standard PEM certificate/private-key material.

Manual extraction does not perform the appliance restore's strict checks for
duplicate or unsafe member names, unexpected file types, manifest/schema
consistency, or appliance identity. Use only a backup whose source you trust;
the checksum detects changes or corruption, not a malicious original archive.
Never extract an untrusted archive into `/`, `/opt`, or a live application
directory.

### Verify and extract into an empty directory

Set `ARCHIVE` to the obtained archive. Its `.sha256` file must be beside it and
must retain the appliance-generated filename recorded inside the checksum:

```bash
ARCHIVE=/path/to/vaultwarden-appliance-YYYYMMDD-HHMMSS.tar.gz
CHECKSUM="${ARCHIVE}.sha256"
RECOVERY_DIR="${PWD}/vaultwarden-manual-recovery"

cd -- "$(dirname -- "${ARCHIVE}")"
sha256sum --check --strict -- "$(basename -- "${CHECKSUM}")"
tar --list --verbose --gzip --file "$(basename -- "${ARCHIVE}")"

# RECOVERY_DIR must not already exist; stop if mkdir reports an error.
mkdir --mode=0700 -- "${RECOVERY_DIR}"
tar --extract --gzip --file "$(basename -- "${ARCHIVE}")" \
  --directory "${RECOVERY_DIR}" \
  --no-same-owner --no-same-permissions --delay-directory-restore

RECOVERY_ROOT="${RECOVERY_DIR}/vaultwarden-appliance-backup"
```

Before extraction, inspect the verbose listing. Every member in the current
format must be a regular file or directory below
`vaultwarden-appliance-backup/`; stop if it contains an absolute path, `..`, a
link, device, FIFO, or any other unexpected member.

The schema-1 archive has these recovery-relevant locations:

```text
vaultwarden-appliance-backup/
  manifest
  vaultwarden/
    db.sqlite3                    # consistent SQLite snapshot
    data/                         # remaining persistent /data contents
      attachments/               # when attachments existed
      sends/                     # when file-backed sends existed
      ...                         # keys and other persistent files, as present
  caddy/
    data/caddy/pki/authorities/local/root.crt
    data/caddy/pki/authorities/local/root.key
    ...                           # complete persistent Caddy data/config state
  appliance/                      # selected appliance metadata/configuration
```

The `manifest` identifies `backup_schema=1`, versions, creation time,
architecture, and the top-level content groups, but it is not a complete path
inventory or a replacement for these recovery instructions. `.access` is
deliberately absent because a recovered installation supplies its own current
hostname and access configuration.

### Recover Vaultwarden into a normal installation

First verify the independent SQLite snapshot. A successful check prints
exactly `ok`:

```bash
sqlite3 "${RECOVERY_ROOT}/vaultwarden/db.sqlite3" 'PRAGMA integrity_check;'
```

Create a normal new Vaultwarden installation using upstream instructions and
identify its persistent `/data` directory. Then:

1. Stop Vaultwarden completely. Never replace a running SQLite database.
2. Back up or move aside the new installation's generated data and prepare an
   empty target data directory.
3. Copy the complete contents of `${RECOVERY_ROOT}/vaultwarden/data/` into that
   target. Do not select only familiar filenames: this directory preserves all
   ordinary persistent Vaultwarden files and directories that existed, except
   the database and explicitly excluded transient files.
4. Copy `${RECOVERY_ROOT}/vaultwarden/db.sqlite3` to `db.sqlite3` at the root of
   the target data directory.
5. Ensure `db.sqlite3-wal` and `db.sqlite3-shm` are absent before startup. The
   backup intentionally contains neither, and stale files from another running
   instance must not be copied.
6. Set ownership and permissions required by the new deployment. The database
   and private key material must remain restricted; files extracted with
   `--no-same-owner` intentionally do not retain the old system's numeric
   owner.
7. Start the new Vaultwarden instance and verify account login plus any
   attachments and sends.

The archive maps the appliance's remaining Vaultwarden `/data` tree directly
under `vaultwarden/data/`. Thus attachments are recovered from
`vaultwarden/data/attachments/`, file-backed sends from
`vaultwarden/data/sends/`, and RSA keys or other required persistent state from
their unchanged relative locations when they existed in the source data.
Always migrate the whole directory. Database-only recovery can lose
file-backed attachments, sends, keys, or other persistent state.

The backup excludes the live `db.sqlite3`, its WAL/SHM files, old built-in
`db_*.sqlite3` snapshots, and `tmp/` from that data tree because the separate
`vaultwarden/db.sqlite3` is the consistent snapshot created by Vaultwarden's
built-in backup command.

### Optionally preserve the old Caddy trust anchor

The old Caddy CA is not needed to recover Vaultwarden passwords, accounts,
attachments, sends, or other Vaultwarden data. A new reverse proxy may use a
new CA. Preserve the old CA only when existing clients should keep trusting the
same private trust anchor.

The backed-up public root and its corresponding private key are exactly:

```bash
CA_CERT="${RECOVERY_ROOT}/caddy/data/caddy/pki/authorities/local/root.crt"
CA_KEY="${RECOVERY_ROOT}/caddy/data/caddy/pki/authorities/local/root.key"

openssl x509 -in "${CA_CERT}" -noout -subject -issuer -sha256 -fingerprint
openssl pkey -in "${CA_KEY}" -check -noout
cmp <(openssl x509 -in "${CA_CERT}" -pubkey -noout) \
    <(openssl pkey -in "${CA_KEY}" -pubout)
```

The final command is silent and exits successfully only when the certificate
and private key match. The private key is highly sensitive: keep the recovery
directory mode `0700`, never publish or casually copy the key, and do not use
insecure TLS workarounds. If retaining the CA, restore the complete archived
`caddy/` tree into the corresponding persistent Caddy storage while Caddy is
stopped and apply the ownership/permissions required by that Caddy deployment.
How that volume is attached is specific to the replacement deployment.

The existing manifest is sufficient to identify schema 1 and its top-level
groups, but not to teach this procedure if all project documentation has
disappeared. A future backup format should therefore consider embedding a
small plain-text `RECOVERY.txt`; release 0.1.2 does not add or require one.

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
