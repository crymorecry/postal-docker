# postal-docker

Production-grade, fully Dockerized [Postal](https://docs.postalserver.io/) deployment designed for [Coolify](https://coolify.io/) Docker Compose deployments.

This stack runs **Postal 3.3.7** with MariaDB 10.11 — no bootstrap scripts, no host networking, and no hardcoded secrets. Everything is defined declaratively in Docker Compose and environment variables.

## Features

- **Postal 3.3.7** pinned (`ghcr.io/postalserver/postal:3.3.7`)
- Three Postal processes: `postal-web`, `postal-worker`, `postal-smtp`
- **MariaDB 10.11 LTS** for main and message databases
- **No RabbitMQ** — removed in Postal v3 (see [Why no RabbitMQ?](#why-no-rabbitmq))
- Idempotent initialization (database, migrations, admin user, DKIM signing key)
- Named volumes, healthchecks, `restart: unless-stopped`
- Internal bridge network — compatible with Coolify/Traefik for the web UI
- Raw TCP SMTP on ports **25** and **587** (not via HTTP reverse proxy)

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Coolify / Traefik (HTTP/HTTPS)                             │
│       │                                                     │
│       ▼                                                     │
│  postal-web:5000 ──┐                                        │
│  postal-worker     ├──► mariadb:3306                        │
│  postal-smtp:25    │                                        │
│       │            │                                        │
│       ▼            │                                        │
│  Internet (SMTP)   │                                        │
│  ports 25, 587     │                                        │
└────────────────────┴────────────────────────────────────────┘
```

Startup order: `mariadb` (healthy) → `postal-init` (one-shot) → web / worker / smtp.

## Prerequisites

- A server with Docker and Docker Compose v2 (Compose file format 3.9+)
- [Coolify](https://coolify.io/) installed (optional but recommended)
- A domain name with DNS access
- A static public IP address
- Outbound port 25 allowed (many cloud providers block this by default)
- Reverse DNS (PTR) configured for your sending IP

## ARM64 / Apple Silicon hosts

The official Postal image is published for **linux/amd64** only. All Postal services pin `platform: linux/amd64` in `docker-compose.yml`, so deploys on ARM64 machines (Apple Silicon, AWS Graviton, Ampere, etc.) pull and run via Docker's QEMU emulation instead of failing with "no matching manifest for linux/arm64".

MariaDB is **not** platform-pinned and runs natively on ARM64.

| Component | ARM64 behavior |
|-----------|----------------|
| `mariadb` | Native ARM64 |
| `postal-init`, `postal-web`, `postal-worker`, `postal-smtp` | amd64 via emulation |

On ARM64 Linux servers, ensure binfmt/QEMU is available (Docker Desktop on macOS includes this). For production mail workloads, prefer an **amd64 VPS** when possible — emulation adds CPU overhead.

## Quick Start (Docker Compose)

```bash
git clone https://github.com/fearlessfara/postal-docker.git
cd postal-docker
cp .env.example .env
# Edit .env with your values (see Configuration below)
docker compose up -d
```

The `postal-init` service will automatically:

1. Render `config/postal.yml` from templates and environment variables
2. Generate a DKIM signing key (`/config/signing.key`) if one does not exist
3. Initialize or upgrade the database schema
4. Create the first admin user (if `INITIAL_ADMIN_*` variables are set)

Access the web UI at your configured domain after Coolify/Traefik routing is set up.

## Configuration

Copy [`.env.example`](.env.example) to `.env` and configure all values:

| Variable | Description |
|----------|-------------|
| `POSTAL_VERSION` | Postal image tag (default: `3.3.7`) |
| `POSTAL_HOSTNAME` | Base domain (e.g. `example.com`) |
| `POSTAL_WEB_HOST` | Web UI hostname (e.g. `postal.example.com`) |
| `POSTAL_SMTP_HOST` | SMTP hostname (e.g. `postal.example.com`) |
| `SECRET_KEY` | Rails secret key — generate with `openssl rand -hex 64` |
| `RAILS_ENV` | Rails environment (default: `production`) |
| `DATABASE_*` | MariaDB connection settings |
| `DATABASE_ROOT_PASSWORD` | MariaDB root password (first init only) |
| `DNS_MX` | Comma-separated MX hostnames |
| `DNS_SPF` | SPF include hostname |
| `DNS_DKIM_SELECTOR` | DKIM selector (default: `postal`) |
| `DNS_RETURN_PATH` | Return-path domain |
| `LOG_LEVEL` | Log level (`debug`, `info`, `warn`, `error`) |
| `INITIAL_ADMIN_*` | First admin user credentials (optional) |

**Never commit `.env` to version control.**

Configuration files in [`config/`](config/) are templates rendered at deploy time. Do not edit generated files in the `postal-config` volume directly — change environment variables and redeploy.

## Why no RabbitMQ?

Postal **v3.0.0** (March 2024) removed the RabbitMQ dependency entirely. Background work is now handled internally by the worker process. Running RabbitMQ would add an unused service with no benefit.

See the [Postal v3 upgrade guide](https://docs.postalserver.io/getting-started/upgrade-to-v3/).

## DNS Records

Configure these DNS records **before** going live. Replace `example.com` with your domain.

### Required A/AAAA records

| Hostname | Type | Value |
|----------|------|-------|
| `postal.example.com` | A / AAAA | Your server IP |
| `mx1.example.com` | A / AAAA | Your server IP |
| `mx2.example.com` | A / AAAA | Your server IP (optional) |
| `rp.example.com` | A / AAAA | Your server IP |
| `routes.example.com` | A / AAAA | Your server IP |
| `track.example.com` | A / AAAA | Your server IP |
| `spf.example.com` | TXT | `v=spf1 a mx include:postal.example.com ~all` |

### MX record

```
example.com.  IN  MX  10  mx1.example.com.
example.com.  IN  MX  20  mx2.example.com.
```

### SPF

Add to your domain's SPF record:

```
example.com.  IN  TXT  "v=spf1 a mx include:spf.example.com ~all"
```

The `include:spf.example.com` points to the SPF record on your Postal SPF hostname (configured via `DNS_SPF`).

### DKIM

After deployment, retrieve your DKIM public key from the Postal web UI (Mail Server → DNS → DKIM) or run:

```bash
docker compose exec postal-web postal default-dkim-record
```

Add the TXT record at:

```
postal._domainkey.example.com.  IN  TXT  "v=DKIM1; k=rsa; p=..."
```

The selector defaults to `postal` (configured via `DNS_DKIM_SELECTOR`).

### DMARC

Start with monitoring, then enforce:

```
_dmarc.example.com.  IN  TXT  "v=DMARC1; p=none; rua=mailto:dmarc@example.com"
```

After confirming deliverability:

```
_dmarc.example.com.  IN  TXT  "v=DMARC1; p=quarantine; rua=mailto:dmarc@example.com"
```

### Return path and tracking CNAMEs

```
psrp.example.com.   IN  CNAME  rp.example.com.
track.example.com.  IN  CNAME  postal.example.com.
```

## Reverse DNS (PTR)

Your sending IP **must** have a PTR record matching your SMTP hostname. Without correct rDNS, most providers will reject or spam-folder your mail.

```
<your-ip>.in-addr.arpa.  IN  PTR  postal.example.com.
```

Configure PTR through your hosting provider (not your DNS registrar). On Oracle Cloud, set this in the VNIC or request it from Oracle support.

## Firewall Ports

| Port | Protocol | Service | Notes |
|------|----------|---------|-------|
| 443 | TCP | HTTPS | Web UI via Coolify/Traefik |
| 80 | TCP | HTTP | Redirect to HTTPS (Coolify handles this) |
| 25 | TCP | SMTP | Inbound mail + outbound delivery |
| 587 | TCP | SMTP submission | Maps to container port 25 (STARTTLS) |

**Port 465 is not exposed.** Postal's SMTP listener uses STARTTLS, not implicit TLS. Mapping `465:25` would break TLS handshakes. If you require SMTPS on 465, add a dedicated TLS-terminating proxy (e.g. HAProxy or stunnel) in front of Postal.

## Oracle Cloud Considerations

Oracle Cloud Infrastructure (OCI) has specific requirements for running a mail server:

### Port 25 egress block

By default, OCI **blocks outbound port 25** on Free Tier and many paid accounts. You must [request a limit increase](https://docs.oracle.com/en-us/iaas/Content/General/Reference/emaildelivery.htm) to send mail.

### Security Lists / Network Security Groups

Allow inbound TCP on ports **25**, **587**, **80**, and **443** to your instance's subnet or NSG.

### Reverse DNS

Configure a reverse DNS entry for your instance's public IP to match `POSTAL_SMTP_HOST`. This is configured in the OCI console under the VNIC's public IP settings.

### Shape and resources

Postal is moderately resource-intensive. Recommended minimum:

- 2 vCPU
- 4 GB RAM
- 20 GB disk (plus volume storage for MariaDB and logs)

## Coolify Deployment Walkthrough

### 1. Create a new Docker Compose resource

In Coolify, create a new **Docker Compose** application and point it at this repository.

### 2. Set environment variables

Coolify **auto-generates** database passwords and `SECRET_KEY` via magic variables in `docker-compose.yml` (`SERVICE_PASSWORD_*`, `SERVICE_BASE64_64_SECRET`). You only need to set:

| Variable | Required | Example |
|----------|----------|---------|
| `POSTAL_HOSTNAME` | Yes | `example.com` |
| `POSTAL_WEB_HOST` | Yes* | `postal.example.com` |
| `INITIAL_ADMIN_EMAIL` | Yes | `admin@example.com` |
| `INITIAL_ADMIN_PASSWORD` | Yes | strong password |
| `INITIAL_ADMIN_FIRST_NAME` | No | `Admin` |
| `INITIAL_ADMIN_LAST_NAME` | No | `User` |

\*If you assign a domain to **`postal-web`** in Coolify, `POSTAL_WEB_HOST` can be omitted — `init.sh` reads `SERVICE_FQDN_POSTAL-WEB` automatically.

Do **not** set `DATABASE_ROOT_PASSWORD` or `SECRET_KEY` manually unless overriding Coolify's generated values.

### 3. Configure the web service domain

Assign your domain (e.g. `postal.example.com`) to the **`postal-web`** service. The compose file declares `SERVICE_URL_POSTAL-WEB_5000` and `ports: "5000"` so Coolify/Traefik routes HTTPS automatically.

Do **not** route SMTP through Traefik — SMTP uses raw TCP and is published directly on the host via `ports` in `docker-compose.yml`.

### 4. Deploy

Deploy the stack. Coolify will:

1. Pull images
2. Create named volumes
3. Start MariaDB and wait for health
4. Run `postal-init` (one-shot)
5. Start web, worker, and SMTP services

### 5. Verify

- Web UI loads at `https://postal.example.com`
- Log in with your `INITIAL_ADMIN_*` credentials
- Create a mail server and verify DNS records in the UI
- Send a test message

### 6. SMTP port exposure on Coolify

Ensure your Coolify host firewall and any cloud security groups allow inbound **25** and **587**. These are mapped in `docker-compose.yml` on the `postal-smtp` service and bind to the host directly.

## Upgrading Postal

1. Update `POSTAL_VERSION` in your environment (e.g. `3.3.8`)
2. Redeploy the stack in Coolify (or run `docker compose up -d`)
3. The `postal-init` service runs `postal upgrade` automatically when it detects an existing schema

To manually run migrations:

```bash
docker compose run --rm postal-init
```

Or:

```bash
docker compose exec postal-web postal upgrade
```

Always back up before upgrading (see [Backups](#backups)).

## Backups

### What to back up

| Component | Method |
|-----------|--------|
| MariaDB data | `mysqldump` or volume snapshot |
| Postal config + signing key | `postal-config` volume |
| Postal uploads | `postal-uploads` volume |
| Postal logs | `postal-logs` volume (optional) |

### Database backup

```bash
docker compose exec mariadb mysqldump \
  -u root -p"${DATABASE_ROOT_PASSWORD}" \
  --all-databases \
  --single-transaction \
  > postal-backup-$(date +%Y%m%d).sql
```

### Volume backup

```bash
docker run --rm \
  -v postal-config:/data \
  -v $(pwd):/backup \
  alpine tar czf /backup/postal-config-$(date +%Y%m%d).tar.gz -C /data .
```

Repeat for `postal-mariadb-data`, `postal-uploads`, and `postal-data` volumes.

## Restoring Backups

### Database restore

```bash
docker compose stop postal-web postal-worker postal-smtp
cat postal-backup-YYYYMMDD.sql | docker compose exec -T mariadb \
  mysql -u root -p"${DATABASE_ROOT_PASSWORD}"
docker compose up -d
```

### Config volume restore

```bash
docker compose stop postal-web postal-worker postal-smtp postal-init
docker run --rm \
  -v postal-config:/data \
  -v $(pwd):/backup \
  alpine sh -c "cd /data && tar xzf /backup/postal-config-YYYYMMDD.tar.gz"
docker compose up -d
```

**Important:** The signing key in `postal-config` must match the key used when mail was sent, or DKIM verification will fail for previously sent mail.

## Troubleshooting

### Web UI returns 500 Internal Server Error

- Verify `SECRET_KEY` is set and not empty
- Check that `postal-init` completed successfully: `docker compose logs postal-init`
- Confirm database is initialized: `docker compose exec mariadb mariadb -u postal -p -e "SHOW TABLES" postal`

### postal-init fails or exits non-zero

```bash
docker compose logs postal-init
```

Common causes:

- Wrong `DATABASE_*` credentials
- MariaDB not healthy yet (increase `WAIT_FOR_TIMEOUT`)
- Missing required environment variables

### `exec /docker-entrypoint.sh: exec format error` (postal-init / Postal services)

This means the **Postal image is amd64** but your Coolify server CPU is **ARM64** (e.g. Oracle Ampere, AWS Graviton) and **QEMU emulation is not enabled**.

Check your server architecture (SSH into the Coolify host):

```bash
uname -m
# aarch64 = ARM64 — Postal needs amd64 emulation or an amd64 VPS
```

**Option A (recommended for production mail):** Use an **x86_64 / amd64** VPS for Coolify.

**Option B:** Enable amd64 emulation on the ARM server:

```bash
docker run --privileged --rm tonistiigi/binfmt --install amd64
```

Verify emulation works:

```bash
docker run --rm --platform linux/amd64 ghcr.io/postalserver/postal:3.3.7 postal version
```

Then redeploy in Coolify. MariaDB can stay on native ARM64; only the Postal containers require amd64.

Re-run init manually:

```bash
docker compose run --rm postal-init
```

### Cannot send mail / connection timeout on port 25

- Cloud provider may block outbound port 25 (especially Oracle Cloud Free Tier)
- Check security groups / firewall allow outbound 25
- Verify rDNS is configured correctly

### Inbound mail not arriving

- Confirm MX records point to your server
- Verify port 25 is open inbound on firewall and security groups
- Check SMTP logs: `docker compose logs postal-smtp`

### DKIM verification fails

- Ensure `signing.key` was not regenerated after going live (check `postal-config` volume)
- Verify DNS TXT record matches the key shown in Postal UI
- Allow 24–48 hours for DNS propagation

### Health checks failing

```bash
docker compose ps
docker compose logs postal-web postal-worker postal-smtp
```

- **postal-web**: probes TCP port 5000 — ensure `BIND_ADDRESS=0.0.0.0`
- **postal-worker**: probes health server on port 9090
- **postal-smtp**: probes health server on port 9091

### Create admin user manually

If `INITIAL_ADMIN_*` was not set during first deploy:

```bash
docker compose run --rm postal-web postal make-user
```

### View logs

```bash
docker compose logs -f postal-web
docker compose logs -f postal-worker
docker compose logs -f postal-smtp
docker compose logs -f mariadb
```

## Repository Structure

```
postal-docker/
├── docker-compose.yml      # Main stack definition
├── .env.example            # Environment variable template
├── config/
│   ├── postal.yml          # Postal config template (rendered at deploy)
│   └── smtp.yml            # SMTP config template (merged at deploy)
├── scripts/
│   ├── init.sh             # Idempotent initialization
│   ├── create-user.sh      # Admin user creation
│   ├── healthcheck.sh      # Service health probes
│   └── mariadb-init.sh     # MariaDB grants for postal-* databases
├── README.md
├── LICENSE
└── .gitignore
```

## Services

| Service | Image | Purpose |
|---------|-------|---------|
| `mariadb` | `mariadb:10.11` | Database |
| `postal-init` | `ghcr.io/postalserver/postal:3.3.7` | One-shot setup |
| `postal-web` | `ghcr.io/postalserver/postal:3.3.7` | Web UI and API |
| `postal-worker` | `ghcr.io/postalserver/postal:3.3.7` | Background mail processing |
| `postal-smtp` | `ghcr.io/postalserver/postal:3.3.7` | SMTP server |

## Volumes

| Volume | Purpose |
|--------|---------|
| `postal-mariadb-data` | MariaDB data files |
| `postal-config` | Rendered config + DKIM signing key |
| `postal-data` | Postal application data |
| `postal-uploads` | File uploads |
| `postal-logs` | Application logs |

## License

MIT — see [LICENSE](LICENSE).

## Links

- [Postal Documentation](https://docs.postalserver.io/)
- [Postal GitHub](https://github.com/postalserver/postal)
- [Postal Container Image](https://docs.postalserver.io/other/containers/)
- [Coolify Documentation](https://coolify.io/docs)
