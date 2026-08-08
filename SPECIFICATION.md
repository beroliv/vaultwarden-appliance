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
`avahi-publish-address` continuously and stores the validated `.local` hostname
and detected LAN IPv4 address in the environment file. An appliance-owned
wrapper MUST keep the publisher attached to systemd, verify the exact published
mapping and return a failure status if the publisher exits before or after
publication, including when the underlying utility reports a collision but
exits successfully.

---

## 6. Installer

Installation should be launchable with a single command similar to:

```bash
curl -fsSL https://example/install.sh | sudo bash
```

The final URL will be determined when the project is published.

The initial `install.sh` SHOULD act primarily as a bootstrap installer.

It SHOULD download/install the required appliance files into `/opt/vaultwarden`.

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

For backward compatibility, an unmarked Phase 2 installation may be adopted
once only when it has `docker-compose.yml`, `data/vaultwarden`, the official
`vaultwarden/server` image and the expected `vaultwarden-appliance` Docker
network. After all checks pass, the installer creates the marker. Any other
unmarked `/opt/vaultwarden` directory MUST be treated as unknown and left
unchanged.

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
access MUST NOT call `hostnamectl` or `avahi-set-host-name`, permanently set an
Avahi hostname, or rename the host operating system. The narrowly scoped legacy
migration may reset Avahi's runtime hostname to the unchanged machine hostname.

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
IPv4 address and additionally checks `getent hosts` where available. The
obsolete `.caddy-hostname` file is removed only after safe state migration.

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
Caddyfile and `.caddy-access` state, then rebuilds only the Caddy container so
Caddy can obtain a server certificate for the selected hostname.
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

Phase 4 provides:

```bash
vwctl status
vwctl logs [vaultwarden|caddy]
sudo vwctl update
sudo vwctl restart
sudo vwctl access [hostname]
vwctl signup status
sudo vwctl signup on
sudo vwctl signup off
sudo vwctl cert export
```

Backup and restore commands remain future phases.

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

### 12.3 Logs and Restart

`vwctl logs` shows the last 100 lines from both services without following
indefinitely. An optional `vaultwarden` or `caddy` argument selects one service.

`sudo vwctl restart` force-recreates only the two appliance containers using
the existing Compose configuration and persistent bind mounts, then verifies
both containers and HTTPS. It preserves the internal root CA.

### 12.4 Access Configuration

`sudo vwctl access` and `sudo vwctl access hostname` both prompt for a new local
`.local` hostname, validate it, check for a conflicting mDNS advertisement and
request explicit confirmation. Direct-IP access is not supported. Hostname
changes never modify the Linux system hostname or any
external network configuration.

After validating the requested address and receiving explicit confirmation,
`vwctl` records the SHA-256 hash of Caddy's persistent public root CA. It stops
and removes only the Caddy service container, generates a complete formatted
appliance Caddyfile, rewrites the hostname-only `.caddy-access`, removes the obsolete
`.caddy-hostname` state and validates the new configuration with a one-off
Caddy Compose container. It updates and verifies the appliance-managed,
explicit Avahi hostname-to-LAN-IP publication, then creates Caddy with
`--no-deps`, leaving the Vaultwarden container untouched.

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
inspection. Vaultwarden remains running, and the administrator can correct the
reported problem and rerun `sudo vwctl access hostname`.

### 12.5 Signup Management

Signup changes use the appliance-managed override file:

```text
/opt/vaultwarden/docker-compose.vwctl.yml
```

This override contains only `SIGNUPS_ALLOWED`, preserving every other Compose
setting. A candidate override is validated before it replaces the managed
file. Compose recreates Vaultwarden only when required and the resulting
container environment is verified. On failure, the previous override and
signup state are restored.

### 12.6 Root CA Export

`sudo vwctl cert export` atomically refreshes only the public certificate at
`/opt/vaultwarden/certs/caddy-root-ca.crt`, sets readable permissions and
verifies it byte-for-byte against Caddy's persistent public root certificate.
Private CA keys are never read or exported.

### 12.7 Future Diagnostics

A diagnostic command remains desirable in a later phase:

```bash
vwctl doctor
```

Possible checks:

```text
Docker                 ✓
Docker Compose         ✓
Vaultwarden            ✓
Caddy                  ✓
HTTPS                  ✓
Database               ✓
Disk space             ✓
USB backup target      ✓
Last backup            ✓
Backup integrity       ✓
```

`vwctl doctor` is a SHOULD requirement rather than part of Phase 4.

---

## 13. USB Backup

Automatic external backup is part of Version 1.

A backup stored only on the same SD card or system disk as Vaultwarden MUST NOT be considered sufficient as the appliance's backup solution.

USB mass-storage devices will be the supported external backup target.

Other backup targets are outside Version 1 scope.

---

## 14. USB Device Detection

During installation, the appliance SHOULD detect suitable attached USB storage devices.

Example:

```text
Configure external USB backup? [Yes]

Detected devices:

1) SanDisk Ultra
   /dev/sda
   29.8 GB
   Filesystem: exFAT

2) Kingston
   /dev/sdb
   57.7 GB
   Filesystem: FAT32

Backup device [1]:
```

The installer MUST provide enough information to minimize the risk of selecting the wrong disk.

The appliance MUST NOT assume a fixed USB device name such as `/dev/sda`.

Persistent identification SHOULD use filesystem UUIDs or an equivalent stable identifier.

---

## 15. USB Filesystem

The recommended USB backup filesystem is:

```text
exFAT
```

The main reasons are portability and easy access from Windows, macOS and Linux systems.

Existing suitable filesystems may be retained if supported by the implementation.

The installer SHOULD offer to format the selected USB storage device as exFAT.

---

## 16. USB Formatting Safety

Formatting a storage device is destructive.

The installer MUST NOT format any device without explicit confirmation.

A simple Enter or default `Yes` MUST NOT be sufficient for the final destructive confirmation.

Example:

```text
WARNING

All data on the following device will be permanently deleted:

Device: SanDisk Ultra
Path:   /dev/sda
Size:   29.8 GB

Type YES to continue:
```

The installer MUST abort formatting if the expected confirmation is not entered.

Where practical, additional safeguards SHOULD prevent formatting the system disk.

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

The exact archive format may change if testing demonstrates a technically superior solution, but portability must remain a goal.

---

## 19. Backup Contents

The backup MUST contain all data required to restore the Vaultwarden service.

This includes at minimum the relevant Vaultwarden persistent data.

Configuration required for appliance recovery SHOULD also be backed up where appropriate.

The implementation must determine the correct procedure for safely backing up the Vaultwarden database.

A backup MUST NOT simply assume that copying a live database file always produces a valid backup.

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
Phase 5  USB detection and formatting
Phase 6  Backup + retention + overflow protection
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

The hostname-only mDNS architecture includes a narrowly scoped migration for
appliance-managed Phase 3/4 access state. A legacy two-line hostname state is
converted to `hostname=<name>` and its `.local` name is preserved. A legacy
direct-IP state, including the Atlas reference installation, is migrated by the
installer to `vaultwarden.local`, or to an explicitly accepted conflict-free
alternative when that name is already advertised on the LAN.

This access migration MUST:

* install and configure the appliance-managed explicit Avahi
  hostname-to-LAN-IP publication;
* regenerate the complete Caddyfile for the selected `.local` hostname;
* stop and recreate only the Caddy container;
* leave the Vaultwarden container and `/opt/vaultwarden/data/vaultwarden`
  untouched;
* leave `/opt/vaultwarden/data/caddy` untouched;
* verify that Caddy's internal root CA hash did not change when a root already
  exists;
* remove `.caddy-hostname` only after the new state is safely installed;
* verify mDNS resolution, Docker networking, TCP 443, HTTPS with explicit root
  CA trust, and the root CA export.

Old Caddy leaf certificates do not need to be preserved. Caddy may issue a new
leaf certificate for the `.local` hostname from the existing persistent root
CA, keeping already installed client root certificates valid.

An installer rerun MUST safely replace the obsolete appliance-owned systemd
service that called `avahi-set-host-name`. The installer MUST query Avahi's
actual runtime hostname rather than relying on the current unit file to detect
this stale state. If the runtime hostname equals the appliance hostname,
differs from the machine hostname and matches appliance-managed legacy state,
the installer resets Avahi's runtime hostname to the unchanged machine
hostname through Avahi's D-Bus API. It then starts the persistent explicit
publisher with the current detected LAN IPv4 address. Unrelated Avahi
configuration MUST remain untouched.

An address advertised by a different LAN device remains a real conflict. Local
addresses from stale appliance ownership or local Docker interfaces may be
recognized as belonging to this host during migration, but final mDNS
verification MUST reject every result other than the detected LAN IPv4 address.
The publisher service MUST remain active and expose verified runtime readiness;
on failure, installer diagnostics MUST include its recent journal so messages
such as `Local name collision` are not hidden.

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

