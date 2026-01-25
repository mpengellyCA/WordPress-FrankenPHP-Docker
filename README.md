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

## Automated Deployment

The tool supports full automation via APIs for Cloudflare, GitHub, and Komodo. This eliminates manual steps for tunnel creation, DNS configuration, image building, and deployment.

### Automated Workflow

When using `--automated` flag, the tool will:

1. **Cloudflare**: Automatically create Zero Trust tunnel and DNS CNAME record
2. **GitHub**: Automatically build and push Docker image to GitHub Container Registry
3. **Komodo**: Deploy Docker Compose stack to your Komodo-managed servers

### Setting Up API Credentials

#### Option 1: Interactive Setup

Run the init command with `--automated` flag and enter credentials when prompted:

```bash
./wp-docker-cli.sh init --automated
```

#### Option 2: Configuration File

Create `config/api-credentials` from the example:

```bash
cp config/api-credentials.example config/api-credentials
chmod 600 config/api-credentials
# Edit config/api-credentials with your credentials
```

#### Option 3: Environment Variables

Set credentials as environment variables:

```bash
export CLOUDFLARE_API_TOKEN="your_token"
export GITHUB_TOKEN="ghp_your_token"
export GITHUB_USERNAME="your_username"
export KOMODO_BASE_URL="https://komodo.example.com"
export KOMODO_API_KEY="your_key"
export KOMODO_API_SECRET="your_secret"
```

### Required API Permissions

#### Cloudflare API Token

Create a token at [Cloudflare API Tokens](https://dash.cloudflare.com/profile/api-tokens) with:

- **Zone**: Read, Edit
- **Account**: Cloudflare Tunnel: Edit

#### GitHub Personal Access Token

Create a token at [GitHub Settings > Developer settings > Personal access tokens](https://github.com/settings/tokens) with:

- `write:packages` - Upload packages to GitHub Container Registry
- `read:packages` - Download packages from GitHub Container Registry

#### Komodo API Credentials

Get your API key and secret from your Komodo instance:
1. Go to Settings page in Komodo UI
2. Navigate to API Keys section
3. Create a new API key or use existing credentials

### Using Automated Deployment

#### Initialize with Automation

```bash
./wp-docker-cli.sh init --automated
```

The tool will:
- Prompt for API credentials (if not already configured)
- Validate all credentials
- Automatically create Cloudflare tunnel
- Automatically create DNS record
- Optionally build and push Docker image
- Generate all configuration files

#### Deploy to Komodo

After initialization, deploy your stack to Komodo:

```bash
./wp-docker-cli.sh deploy [server_name]
```

This will:
- Create or update the stack in Komodo
- Deploy the Docker Compose configuration
- Show deployment status

#### Dry Run Mode

Test API calls without making changes:

```bash
./wp-docker-cli.sh init --automated --dry-run
```

### Manual Fallback

If automated features fail, the tool will automatically fall back to manual setup instructions. You can also use the traditional manual workflow:

```bash
./wp-docker-cli.sh init
```

## CLI Tool Usage

The `wp-docker-cli.sh` script provides several commands:

### Initialize a New Site

```bash
./wp-docker-cli.sh init [--automated] [--dry-run]
```

Creates all necessary configuration files and guides you through setup.

- `--automated` or `-a`: Enable automated deployment (Cloudflare, GitHub, Komodo APIs)
- `--dry-run` or `-d`: Test API calls without making changes

### Deploy to Komodo

```bash
./wp-docker-cli.sh deploy [server_name]
```

Deploys the Docker Compose stack to Komodo. Requires Komodo credentials to be configured.

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
├── lib/                           # API integration modules
│   ├── cloudflare-api.sh          # Cloudflare API wrapper
│   ├── github-api.sh              # GitHub API wrapper
│   └── komodo-api.sh               # Komodo API wrapper
├── config/                        # Configuration files
│   └── api-credentials.example    # API credentials template
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

### WordPress Configuration

- `SITE_NAME`: Name for your site (used in container names)
- `DOMAIN`: Your domain name
- `DOCKER_IMAGE`: Docker image to use
- `DB_NAME`: Database name
- `DB_USER`: Database user
- `DB_PASSWORD`: Database password
- `DB_ROOT_PASSWORD`: Database root password
- `TUNNEL_ID`: Cloudflare tunnel ID
- `WP_*_KEY` and `WP_*_SALT`: WordPress security keys

### API Credentials (for automated deployment)

- `CLOUDFLARE_API_TOKEN`: Cloudflare API token (Zone:Read, Zone:Edit, Account:Cloudflare Tunnel:Edit)
- `GITHUB_TOKEN`: GitHub Personal Access Token (write:packages, read:packages)
- `GITHUB_USERNAME`: GitHub username
- `KOMODO_BASE_URL`: Komodo instance base URL
- `KOMODO_API_KEY`: Komodo API key
- `KOMODO_API_SECRET`: Komodo API secret

These can be set in:
1. `config/api-credentials` file (recommended)
2. Environment variables
3. `.env` file (not recommended for secrets)

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

### API Automation Issues

#### Cloudflare API Errors

1. **Invalid API Token**:
   - Verify token has correct permissions (Zone:Read, Zone:Edit, Account:Cloudflare Tunnel:Edit)
   - Check token is not expired
   - Regenerate token if needed

2. **Zone Not Found**:
   - Ensure domain is added to your Cloudflare account
   - Verify domain spelling matches exactly

3. **Tunnel Creation Failed**:
   - Check account has Zero Trust access
   - Verify tunnel name doesn't conflict with existing tunnels

#### GitHub API Errors

1. **Authentication Failed**:
   - Verify token has `write:packages` and `read:packages` scopes
   - Check token hasn't expired
   - Ensure username matches token owner

2. **Image Push Failed**:
   - Verify Docker is running
   - Check you're logged into GitHub Container Registry: `docker login ghcr.io`
   - Ensure package permissions allow your account

#### Komodo API Errors

1. **Invalid Credentials**:
   - Verify API key and secret from Komodo Settings page
   - Check base URL is correct (include https://)
   - Ensure API key hasn't been revoked

2. **Stack Deployment Failed**:
   - Verify server name exists in Komodo
   - Check Docker Compose file is valid
   - Review Komodo logs for detailed error messages

#### General Troubleshooting

- Use `--dry-run` flag to test API calls without making changes
- Check API credentials are loaded: `./wp-docker-cli.sh show-config`
- Verify network connectivity to API endpoints
- Review error messages for specific API error codes
- Fall back to manual setup if automation fails

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
