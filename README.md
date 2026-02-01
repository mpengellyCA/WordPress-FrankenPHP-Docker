# WordPress FrankenPHP Docker

A production-ready Docker setup for WordPress using FrankenPHP and Cloudflare Tunnel. This project provides an easy-to-deploy WordPress environment with automatic WordPress download, persistent storage, and secure Cloudflare integration.

## Features

- 🚀 **Automatic WordPress Download**: Latest production build downloaded during image build
- 💾 **Persistent Storage**: Docker volumes for WordPress files, database, and configs
- 🔒 **Cloudflare Integration**: Secure tunnel setup with guided configuration
- 🤖 **Full API Automation**: Automatically create Cloudflare tunnels, DNS records, build/push images, and deploy to Komodo
- 🔐 **Security**: Secure password generation, no exposed ports
- 🛠️ **Production Ready**: Health checks, proper logging, error handling
- 📋 **Copy-Paste Friendly**: All configs and commands formatted for easy manual deployment
- ⚡ **Zero-Config Deployment**: CLI generates all necessary files ready for `docker compose up`

## Prerequisites

- Linux or WSL environment (Ubuntu, Debian, Fedora, Arch, or similar)
- Docker (version 20.10+), Docker Compose (version 2.0+), Bash shell
- Cloudflare account with a domain
- Sudo access (for automatic `gettext` installation if needed)

The CLI tool will automatically install `gettext` if missing. Manual installation:
```bash
# Debian/Ubuntu: sudo apt-get install gettext-base
# Fedora/RHEL/CentOS: sudo dnf install gettext
# Arch/Manjaro: sudo pacman -S gettext
```

## Quick Start

### 1. Clone and Initialize

```bash
git clone <repository-url>
cd WordPress-FrankenPHP-Docker
./wp-docker-cli.sh init
```

The tool will prompt for site configuration, generate secure passwords, create `docker-compose.yml` and `.env` files, and guide you through Cloudflare tunnel setup.

### 2. Set Up Cloudflare Tunnel (Manual)

1. Go to [Cloudflare Zero Trust Dashboard](https://dash.cloudflare.com/) → **Zero Trust → Networks → Tunnels**
2. Create a tunnel (select "Cloudflared"), copy the tunnel ID, and download credentials JSON
3. Place credentials in `cloudflared/<tunnel-id>.json`
4. In Cloudflare DNS, add CNAME record: Name `@`, Target `<tunnel-id>.cfargotunnel.com`, Proxy status: Proxied

### 3. Deploy

```bash
docker compose up -d
```

Visit `https://your-domain.com` to complete WordPress installation.

## Automated Deployment

The tool supports full automation via APIs for Cloudflare, GitHub, and Komodo, eliminating manual tunnel creation, DNS configuration, image building, and deployment.

### Setup API Credentials

**Option 1: Interactive** - Run `./wp-docker-cli.sh init --automated` and enter credentials when prompted.

**Option 2: Encrypted File** - Credentials are automatically encrypted with a PIN (AES-256) and stored in `config/api-credentials.enc`. Enter PIN on subsequent runs.

**Option 3: Manual File** - Copy `config/api-credentials.example` to `config/api-credentials`, edit with credentials, set `chmod 600`.

**Option 4: Environment Variables** - Set `CLOUDFLARE_API_TOKEN`, `GITHUB_TOKEN`, `GITHUB_USERNAME`, `KOMODO_BASE_URL`, `KOMODO_API_KEY`, `KOMODO_API_SECRET`.

### Required API Permissions

- **Cloudflare**: Token with Zone:Read/Edit, Account:Cloudflare Tunnel:Edit ([create token](https://dash.cloudflare.com/profile/api-tokens))
- **GitHub**: Personal Access Token with `write:packages`, `read:packages` ([create token](https://github.com/settings/tokens))
- **Komodo**: API key and secret from Komodo Settings → API Keys

### Using Automation

```bash
./wp-docker-cli.sh init --automated [--dry-run]
```

This will: validate credentials, create Cloudflare tunnel and DNS record, build/push Docker image to GitHub Container Registry, deploy to Komodo (if configured), and generate all config files.

**Deploy to Komodo later**: `./wp-docker-cli.sh deploy [server_name]`

**Dry run**: Test API calls without making changes using `--dry-run` flag.

If automation fails, the tool automatically falls back to manual setup instructions.

## CLI Tool Usage

```bash
./wp-docker-cli.sh init [--automated] [--dry-run]  # Initialize site
./wp-docker-cli.sh deploy [server_name]            # Deploy to Komodo
./wp-docker-cli.sh install                         # Start containers for WordPress install
./wp-docker-cli.sh update                          # Pull latest images and restart
./wp-docker-cli.sh start|stop|restart              # Manage containers
./wp-docker-cli.sh logs [wordpress|db]             # View logs
./wp-docker-cli.sh show-config                     # Display current configuration
```

## Manual Setup (Without CLI)

1. Copy `.env.example` to `.env` and edit values (generate passwords: `openssl rand -base64 32`, keys: `openssl rand -base64 64`)
2. Create `docker-compose.yml`: `envsubst < docker-compose.yml.template > docker-compose.yml`
3. Set up Cloudflare tunnel config in `cloudflared/`
4. Deploy: `docker compose up -d`

## Building and Publishing Docker Images

```bash
# Build
./build.sh --user <github-username> [--version <version>]

# Login and push
echo $GITHUB_TOKEN | docker login ghcr.io -u USERNAME --password-stdin
./push.sh --user <github-username> [--version <version>]
```

Image available at: `ghcr.io/<username>/wordpress-frankenphp:latest`

Set `DOCKER_IMAGE=ghcr.io/<username>/wordpress-frankenphp:latest` in `.env` or provide when prompted by CLI.

## Project Structure

```
WordPress-FrankenPHP-Docker/
├── Dockerfile, docker-compose.yml.template, entrypoint.sh
├── wp-docker-cli.sh, build.sh, push.sh
├── cloudflared-config.yml.template
├── lib/                    # API integration modules (cloudflare, github, komodo)
├── config/                 # api-credentials.example, api-credentials, api-credentials.enc
└── wordpress/wp-content/   # Persistent WordPress data
```

## Architecture

```
┌─────────────────────────────────────────┐
│         Cloudflare Tunnel               │
│      (cloudflared container)            │
└──────────────────┬──────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────┐
│      Docker Compose Environment         │
│  ┌──────────┐  ┌──────────┐  ┌──────┐ │
│  │WordPress │  │ MariaDB   │  │Cloud │ │
│  │(Franken  │  │(Database) │  │flared│ │
│  │  PHP)    │  │           │  │      │ │
│  └────┬─────┘  └─────┬─────┘  └──┬───┘ │
│       │              │            │     │
│  ┌────▼──────────────▼────────────▼───┐ │
│  │   Docker Volumes (Persistent)      │ │
│  └────────────────────────────────────┘ │
└─────────────────────────────────────────┘
```

## Environment Variables

Key variables (see `.env.example` for full list):

**WordPress**: `SITE_NAME`, `DOMAIN`, `DOCKER_IMAGE`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`, `DB_ROOT_PASSWORD`, `TUNNEL_ID`, `WP_*_KEY`, `WP_*_SALT`

**API Credentials** (for automation): `CLOUDFLARE_API_TOKEN`, `GITHUB_TOKEN`, `GITHUB_USERNAME`, `KOMODO_BASE_URL`, `KOMODO_API_KEY`, `KOMODO_API_SECRET`

Set in: `config/api-credentials` file (recommended), environment variables, or `.env` (not recommended for secrets).

## Maintenance

### Update WordPress

```bash
./wp-docker-cli.sh update
# Or manually: docker compose pull && docker compose up -d
```

### Backup and Restore

```bash
# Backup WordPress files
docker compose run --rm -v $(pwd)/backups:/backup wordpress tar czf /backup/wordpress-$(date +%Y%m%d).tar.gz /var/www/html

# Backup database
docker compose exec db mysqldump -u root -p${DB_ROOT_PASSWORD} ${DB_NAME} > backups/db-$(date +%Y%m%d).sql

# Restore files
docker compose run --rm -v $(pwd)/backups:/backup wordpress tar xzf /backup/wordpress-YYYYMMDD.tar.gz -C /

# Restore database
docker compose exec -T db mysql -u root -p${DB_ROOT_PASSWORD} ${DB_NAME} < backups/db-YYYYMMDD.sql
```

## Troubleshooting

**Containers won't start**: Check `docker compose ps` and logs, verify `.env` configuration.

**Database connection issues**: Ensure DB container is healthy (`docker compose ps db`), check logs (`docker compose logs db`), verify credentials in `.env`.

**Cloudflare tunnel not working**: Verify `cloudflared/<tunnel-id>.json` exists, check `cloudflared/config.yml`, view logs (`docker compose logs cloudflared`), verify DNS record points to `<tunnel-id>.cfargotunnel.com`.

**WordPress installation issues**: Ensure all containers running, check WordPress logs, verify `wp-config.php` exists.

**API automation errors**:
- **Cloudflare**: Verify token permissions (Zone:Read/Edit, Account:Cloudflare Tunnel:Edit), check token expiry, ensure domain added to account, verify Zero Trust access
- **GitHub**: Verify token has `write:packages`/`read:packages` scopes, check expiry, ensure logged into GHCR (`docker login ghcr.io`)
- **Komodo**: Verify API key/secret from Settings, check base URL includes `https://`, ensure server name exists
- **General**: Use `--dry-run` to test, check credentials with `./wp-docker-cli.sh show-config`, verify network connectivity

## Security Notes

- All passwords generated securely using OpenSSL
- WordPress security keys automatically generated
- No ports exposed to host (only through Cloudflare tunnel)
- Database only accessible within Docker network
- Use strong passwords in production, keep images updated, regularly update WordPress core and plugins

## Contributing & Support

Contributions welcome! Please submit a Pull Request.

**License**: MIT License

**Support**: Check troubleshooting section, review Docker/Cloudflare logs, or open an issue on GitHub.
