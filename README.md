# WordPress FrankenPHP Docker

A production-ready Docker setup for WordPress using FrankenPHP and Cloudflare Tunnel. This project provides an easy-to-deploy WordPress environment with automatic WordPress download, persistent storage, and secure Cloudflare integration.

## Features

- 🚀 **Automatic WordPress Download**: Latest production build downloaded during image build
- 💾 **Persistent Storage**: Docker volumes for WordPress files, database, and configs
- 🔒 **Cloudflare Integration**: Secure tunnel setup with guided configuration
- 🔐 **Security**: Secure password generation, no exposed ports
- 🛠️ **Production Ready**: Health checks, proper logging, error handling
- 📋 **Copy-Paste Friendly**: All configs and commands formatted for easy manual deployment
- ⚡ **Zero-Config Deployment**: CLI generates all necessary files ready for `docker compose up`

## Prerequisites

- Linux or WSL environment (Ubuntu, Debian, Fedora, Arch, or similar)
- Docker (version 20.10 or later)
- Docker Compose (version 2.0 or later)
- Bash shell
- Cloudflare account with a domain
- Basic command-line knowledge
- Sudo access (for automatic package installation if needed)

### Package Requirements

The CLI tool will automatically install `gettext` (required for `envsubst`) if missing. Supported distributions:

- **Debian/Ubuntu**: `gettext-base` (installed via apt-get)
- **Fedora/RHEL/CentOS**: `gettext` (installed via dnf/yum)
- **Arch/Manjaro**: `gettext` (installed via pacman)

If automatic installation fails, you can install manually:
```bash
# Debian/Ubuntu
sudo apt-get install gettext-base

# Fedora/RHEL/CentOS
sudo dnf install gettext
# or for older systems:
sudo yum install gettext

# Arch/Manjaro
sudo pacman -S gettext
```

## Quick Start

### 1. Clone or Download This Repository

```bash
git clone <repository-url>
cd WordPress-FrankenPHP-Docker
```

### 2. Initialize Your WordPress Site

Run the CLI tool to set up your WordPress site:

```bash
./wp-docker-cli.sh init
```

The tool will:
- Prompt you for site configuration (domain, database name, etc.)
- Generate secure passwords automatically
- Create `docker-compose.yml` and `.env` files
- Guide you through Cloudflare tunnel setup
- Provide copy-paste ready commands and configs

### 3. Set Up Cloudflare Tunnel

The CLI will guide you, but here's the process:

1. Go to [Cloudflare Zero Trust Dashboard](https://dash.cloudflare.com/)
2. Select your domain
3. Navigate to: **Zero Trust → Networks → Tunnels**
4. Click **"Create a tunnel"**
5. Select **"Cloudflared"** as the connector
6. Give your tunnel a name
7. Copy the tunnel ID from the command shown
8. Download the tunnel credentials JSON file
9. Place the credentials file in `cloudflared/<tunnel-id>.json`

### 4. Configure DNS in Cloudflare

1. Go to **DNS → Records** in Cloudflare
2. Add a new CNAME record:
   - **Type**: CNAME
   - **Name**: @ (or your subdomain)
   - **Target**: `<your-tunnel-id>.cfargotunnel.com`
   - **Proxy status**: Proxied (orange cloud)

### 5. Deploy Your Site

```bash
docker compose up -d
```

### 6. Complete WordPress Installation

Visit `https://your-domain.com` in your browser and complete the WordPress installation wizard.

## CLI Tool Usage

The `wp-docker-cli.sh` script provides several commands:

### Initialize a New Site

```bash
./wp-docker-cli.sh init
```

Creates all necessary configuration files and guides you through setup.

### Install WordPress

```bash
./wp-docker-cli.sh install
```

Starts the containers and prepares WordPress for installation.

### Update WordPress

```bash
./wp-docker-cli.sh update
```

Pulls latest images and restarts containers.

### Manage Containers

```bash
./wp-docker-cli.sh start      # Start containers
./wp-docker-cli.sh stop       # Stop containers
./wp-docker-cli.sh restart    # Restart containers
```

### View Logs

```bash
./wp-docker-cli.sh logs              # View all logs
./wp-docker-cli.sh logs wordpress    # View WordPress logs only
./wp-docker-cli.sh logs db           # View database logs only
```

### Show Configuration

```bash
./wp-docker-cli.sh show-config
```

Displays current configuration in a copy-paste friendly format.

## Manual Setup (Without CLI)

If you prefer to set up manually:

1. Copy `.env.example` to `.env`:
   ```bash
   cp .env.example .env
   ```

2. Edit `.env` and fill in your values:
   - Generate secure passwords: `openssl rand -base64 32`
   - Generate WordPress keys: `openssl rand -base64 64`
   - Set your domain and tunnel ID

3. Create `docker-compose.yml` from template:
   ```bash
   envsubst < docker-compose.yml.template > docker-compose.yml
   ```

4. Set up Cloudflare tunnel config:
   ```bash
   mkdir -p cloudflared
   # Edit cloudflared/config.yml with your tunnel settings
   ```

5. Deploy:
   ```bash
   docker compose up -d
   ```

## Building and Publishing Docker Images

### Build the Image

```bash
./build.sh --user <your-github-username> [--version <version>]
```

Example:
```bash
./build.sh --user myusername --version 1.0.0
```

### Push to GitHub Container Registry

1. Login to GitHub Container Registry:
   ```bash
   echo $GITHUB_TOKEN | docker login ghcr.io -u USERNAME --password-stdin
   ```

2. Push the image:
   ```bash
   ./push.sh --user <your-github-username> [--version <version>]
   ```

The image will be available at: `ghcr.io/<username>/wordpress-frankenphp:latest`

### Using a Published Image

In your `.env` file, set:
```
DOCKER_IMAGE=ghcr.io/<username>/wordpress-frankenphp:latest
```

Or use the CLI tool and provide the image name when prompted.

## Project Structure

```
WordPress-FrankenPHP-Docker/
├── Dockerfile                      # WordPress + FrankenPHP image
├── docker-compose.yml.template     # Docker Compose template
├── wp-docker-cli.sh               # CLI tool for setup and management
├── build.sh                       # Build script for Docker image
├── push.sh                        # Push script for Docker image
├── entrypoint.sh                  # Container entrypoint script
├── cloudflared-config.yml.template # Cloudflared tunnel config template
├── .env.example                   # Example environment variables
├── .dockerignore                  # Files to exclude from Docker build
└── README.md                      # This file
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
│  │  wordpress_data, db_data, etc.     │ │
│  └────────────────────────────────────┘ │
└─────────────────────────────────────────┘
```

## Environment Variables

Key environment variables (see `.env.example` for full list):

- `SITE_NAME`: Name for your site (used in container names)
- `DOMAIN`: Your domain name
- `DOCKER_IMAGE`: Docker image to use
- `DB_NAME`: Database name
- `DB_USER`: Database user
- `DB_PASSWORD`: Database password
- `DB_ROOT_PASSWORD`: Database root password
- `TUNNEL_ID`: Cloudflare tunnel ID
- `WP_*_KEY` and `WP_*_SALT`: WordPress security keys

## Troubleshooting

### Containers Won't Start

1. Check if ports are in use:
   ```bash
   docker compose ps
   ```

2. View logs:
   ```bash
   docker compose logs
   ```

3. Check `.env` file is properly configured

### Database Connection Issues

1. Ensure database container is healthy:
   ```bash
   docker compose ps db
   ```

2. Check database logs:
   ```bash
   docker compose logs db
   ```

3. Verify database credentials in `.env`

### Cloudflare Tunnel Not Working

1. Verify tunnel credentials file exists:
   ```bash
   ls -la cloudflared/
   ```

2. Check tunnel config:
   ```bash
   cat cloudflared/config.yml
   ```

3. View cloudflared logs:
   ```bash
   docker compose logs cloudflared
   ```

4. Verify DNS record in Cloudflare dashboard points to `<tunnel-id>.cfargotunnel.com`

### WordPress Installation Issues

1. Ensure all containers are running:
   ```bash
   docker compose ps
   ```

2. Check WordPress logs:
   ```bash
   docker compose logs wordpress
   ```

3. Verify `wp-config.php` was created:
   ```bash
   docker compose exec wordpress ls -la /var/www/html/wp-config.php
   ```

## Updating WordPress

To update WordPress core:

```bash
./wp-docker-cli.sh update
```

Or manually:
```bash
docker compose pull
docker compose up -d
```

## Backup and Restore

### Backup

```bash
# Backup WordPress files
docker compose run --rm -v $(pwd)/backups:/backup wordpress tar czf /backup/wordpress-$(date +%Y%m%d).tar.gz /var/www/html

# Backup database
docker compose exec db mysqldump -u root -p${DB_ROOT_PASSWORD} ${DB_NAME} > backups/db-$(date +%Y%m%d).sql
```

### Restore

```bash
# Restore WordPress files
docker compose run --rm -v $(pwd)/backups:/backup wordpress tar xzf /backup/wordpress-YYYYMMDD.tar.gz -C /

# Restore database
docker compose exec -T db mysql -u root -p${DB_ROOT_PASSWORD} ${DB_NAME} < backups/db-YYYYMMDD.sql
```

## Security Notes

- All passwords are generated securely using OpenSSL
- WordPress security keys are automatically generated
- No ports are exposed to the host (only through Cloudflare tunnel)
- Database is only accessible within Docker network
- Use strong passwords in production
- Keep Docker images updated
- Regularly update WordPress core and plugins

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is open source and available under the MIT License.

## Support

For issues and questions:
1. Check the troubleshooting section above
2. Review Docker and Cloudflare logs
3. Open an issue on GitHub

## Example Output

When running `./wp-docker-cli.sh init`, you'll see output like:

```
=== WordPress Docker Setup - Initialization ===

Enter a name for this WordPress site (used for container names):
Site name [wordpress]: mysite

Enter your domain name (e.g., example.com):
Domain: example.com

...

=== COPY BELOW ===
Site Name: mysite
Domain: example.com
Database Name: mysite_db
Database User: mysite_user
Database Password: <generated-password>
=== END COPY ===

...

=== COPY BELOW ===
docker compose up -d
=== END COPY ===
```

All outputs are formatted for easy copy-pasting!
