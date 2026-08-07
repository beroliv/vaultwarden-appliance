# vaultwarden-appliance

Simple LAN-first Vaultwarden appliance with Caddy, `vwctl`, and USB backups.

## Phase 3: local HTTPS with Caddy

The installer performs the Phase 1 system checks, optionally installs Docker
Engine and Docker Compose v2 from Docker's official Debian repository, and
deploys Vaultwarden and Caddy under `/opt/vaultwarden`.

On a Debian-based test system, including 64-bit Raspberry Pi OS, run:

```bash
sudo ./install.sh
```

If Docker is missing, pressing Enter at the installation prompt accepts the
default of Yes. If Docker is already installed, its daemon must be running and
Docker Compose v2 must work as `docker compose`; a working installation is used
without modification.

Vaultwarden data is stored in `/opt/vaultwarden/data/vaultwarden`. Vaultwarden
has no host-published port. Caddy publishes only TCP port 443 and provides local
HTTPS through its internal CA.

Direct access through the detected LAN IPv4 address is the recommended default:

```text
https://192.168.0.192
```

This requires no local DNS, but the address should not change. Create a DHCP
reservation for the Raspberry Pi in the router or DHCP server. The installer
does not configure a static IP or modify any host, router, DNS or DHCP settings.

Local hostname access remains optional and defaults to `vaultwarden.local`.
When selected, the installer prints the DNS or hosts-file mapping that the
administrator must configure manually.

The selected mode and HTTPS address are stored in
`/opt/vaultwarden/.caddy-access`. Reruns report and preserve this state. An
existing hostname-based Phase 3 installation remains hostname-based.

Caddy's persistent data is stored below `/opt/vaultwarden/data/caddy`. Its
public root CA certificate is exported to:

```text
/opt/vaultwarden/certs/caddy-root-ca.crt
```

Install this certificate as a trusted root CA on every client that accesses the
appliance. The private CA key is never exported.

To inspect the exit status:

```bash
sudo ./install.sh
echo "$?"
```

The installer recognizes its own existing installations through
`/opt/vaultwarden/.vaultwarden-appliance` and performs a non-destructive rerun.
Unknown installations without a valid marker or recognized legacy Phase 2
structure are left unchanged.

Phase 4 and later functionality (`vwctl`, USB backup, and restore) is not
implemented yet.
