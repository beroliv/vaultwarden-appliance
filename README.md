# vaultwarden-appliance

Simple LAN-only Vaultwarden appliance with Caddy, local HTTPS, mDNS, and
`vwctl`. USB backup and restore are planned for later phases.

## Installation

On a supported Debian or 64-bit Raspberry Pi OS system, run:

```bash
sudo bash ./install.sh
```

The installer performs system checks, can install Docker Engine and Docker
Compose v2 from Docker's official Debian repository, and deploys the appliance
under `/opt/vaultwarden`. A working existing Docker installation is reused
without modification.

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
vwctl help
vwctl status
vwctl logs [vaultwarden|caddy]
sudo vwctl update
sudo vwctl restart
sudo vwctl access
sudo vwctl access hostname
vwctl signup status
sudo vwctl signup on
sudo vwctl signup off
sudo vwctl cert export
```

`sudo vwctl access` and `sudo vwctl access hostname` change only the local
`.local` name. After validation, conflict detection, and confirmation, `vwctl`
updates the explicit mDNS hostname-to-LAN-IP publication, regenerates the
complete Caddyfile, and rebuilds only Caddy. Vaultwarden is not stopped or recreated. Caddy's
persistent data is not deleted, and the internal root CA hash must remain
unchanged while Caddy obtains a new leaf certificate for the new hostname.

Direct-IP HTTPS access is no longer supported.

## Existing installations

Reruns recognize `/opt/vaultwarden/.vaultwarden-appliance` and remain
non-destructive. A legacy hostname configuration is converted to the
hostname-only state format. A legacy direct-IP configuration, including the
Atlas test installation, is migrated to `vaultwarden.local` (or an accepted
conflict-free alternative). The migration configures mDNS and rebuilds only
Caddy while preserving Vaultwarden data and Caddy's persistent internal root CA.

Unknown `/opt/vaultwarden` directories without the appliance marker or the
recognized legacy Phase 2 structure are left unchanged.

Rerunning the installer refreshes the stored publication address from the
current default-route LAN IPv4 address. It also automatically replaces the
older appliance-owned `avahi-set-host-name` service, without changing unrelated
Avahi configuration.

## Basic verification

After installation:

```bash
sudo vwctl status
systemctl is-active avahi-daemon
systemctl is-active vaultwarden-appliance-mdns
avahi-resolve-host-name -4 vaultwarden.local
curl --cacert /opt/vaultwarden/certs/caddy-root-ca.crt \
  https://vaultwarden.local/alive
docker inspect vaultwarden --format '{{json .HostConfig.PortBindings}}'
docker inspect caddy --format '{{json .HostConfig.PortBindings}}'
```

Use the actual hostname reported by `vwctl status` if a conflict-free
alternative was selected. Phase 5 and later USB backup and restore functionality
is not implemented yet.
