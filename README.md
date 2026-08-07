# vaultwarden-appliance

Simple LAN-first Vaultwarden appliance with Caddy, `vwctl`, and USB backups.

## Phase 1: system preflight

The current installer implements system detection only. It makes no system
changes and does not install Docker or Vaultwarden.

On a Debian-based test system, including 64-bit Raspberry Pi OS, run:

```bash
chmod +x install.sh
./install.sh
```

The script checks the operating system, CPU architecture, free disk space,
Docker, Docker Compose, Docker daemon access, TCP ports 80 and 443, the
`/opt/vaultwarden` installation path, and the current IPv4 address. A failed
preflight exits with a non-zero status.

To inspect the exit status:

```bash
./install.sh
echo "$?"
```

Running the Phase 1 script with `sudo` is not necessary. If Docker is installed
but your user cannot access its daemon, the script reports that condition; you
may rerun the check with `sudo` to distinguish permissions from daemon failure.
