# vaultwarden-appliance

Simple LAN-first Vaultwarden appliance with Caddy, `vwctl`, and USB backups.

## Phase 2: Vaultwarden deployment

The installer performs the Phase 1 system checks, optionally installs Docker
Engine and Docker Compose v2 from Docker's official Debian repository, and
deploys Vaultwarden under `/opt/vaultwarden`.

On a Debian-based test system, including 64-bit Raspberry Pi OS, run:

```bash
chmod +x install.sh
sudo ./install.sh
```

If Docker is missing, pressing Enter at the installation prompt accepts the
default of Yes. If Docker is already installed, its daemon must be running and
Docker Compose v2 must work as `docker compose`; a working installation is used
without modification.

Vaultwarden data is stored in `/opt/vaultwarden/data/vaultwarden`. Vaultwarden
has no host-published port in Phase 2, so it is not directly accessible from the
LAN. Caddy and HTTPS will be added in Phase 3.

To inspect the exit status:

```bash
sudo ./install.sh
echo "$?"
```

The installer refuses to overwrite an existing `/opt/vaultwarden` directory.
