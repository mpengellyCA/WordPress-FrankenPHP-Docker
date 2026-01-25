#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Generate secure random password
generate_password() {
    local length=${1:-32}
    openssl rand -base64 $length | tr -d "=+/" | cut -c1-$length
}

# Print section header
print_section() {
    echo ""
    echo -e "${BLUE}=== $1 ===${NC}"
    echo ""
}

# Print copy-paste delimiter
print_copy_delimiter() {
    echo ""
    echo -e "${GREEN}=== COPY BELOW ===${NC}"
}

# Print end delimiter
print_end_delimiter() {
    echo -e "${GREEN}=== END COPY ===${NC}"
    echo ""
}

# Validate domain name
validate_domain() {
    local domain=$1
    if [[ ! $domain =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        return 1
    fi
    return 0
}

# Detect Linux distribution
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    elif [ -f /etc/redhat-release ]; then
        echo "rhel"
    elif [ -f /etc/arch-release ]; then
        echo "arch"
    else
        echo "unknown"
    fi
}

# Install package based on distribution
install_package() {
    local package=$1
    local distro=$(detect_distro)
    
    case "$distro" in
        ubuntu|debian)
            if command -v apt-get &> /dev/null; then
                echo "Installing $package using apt-get..."
                sudo apt-get update && sudo apt-get install -y "$package"
                return $?
            fi
            ;;
        fedora|rhel|centos)
            if command -v dnf &> /dev/null; then
                echo "Installing $package using dnf..."
                sudo dnf install -y "$package"
                return $?
            elif command -v yum &> /dev/null; then
                echo "Installing $package using yum..."
                sudo yum install -y "$package"
                return $?
            fi
            ;;
        arch|manjaro)
            if command -v pacman &> /dev/null; then
                echo "Installing $package using pacman..."
                sudo pacman -S --noconfirm "$package"
                return $?
            fi
            ;;
    esac
    
    return 1
}

# Initialize new WordPress site
cmd_init() {
    print_section "WordPress Docker Setup - Initialization"
    
    # Check if already initialized
    if [ -f "docker-compose.yml" ] || [ -f ".env" ]; then
        echo -e "${YELLOW}Warning: docker-compose.yml or .env already exists.${NC}"
        read -p "Do you want to overwrite? (y/N): " overwrite
        if [[ ! $overwrite =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 0
        fi
    fi
    
    # Get site name
    echo -e "${BLUE}Enter a name for this WordPress site (used for container names):${NC}"
    read -p "Site name [wordpress]: " site_name
    site_name=${site_name:-wordpress}
    site_name=$(echo "$site_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')
    
    # Get domain
    while true; do
        echo -e "${BLUE}Enter your domain name (e.g., example.com):${NC}"
        read -p "Domain: " domain
        if validate_domain "$domain"; then
            break
        else
            echo -e "${RED}Invalid domain name. Please try again.${NC}"
        fi
    done
    
    # Get database name
    read -p "Database name [${site_name}_db]: " db_name
    db_name=${db_name:-${site_name}_db}
    
    # Get database user
    read -p "Database user [${site_name}_user]: " db_user
    db_user=${db_user:-${site_name}_user}
    
    # Generate passwords
    echo ""
    echo -e "${GREEN}Generating secure passwords...${NC}"
    db_password=$(generate_password 32)
    db_root_password=$(generate_password 32)
    wp_auth_key=$(generate_password 64)
    wp_secure_auth_key=$(generate_password 64)
    wp_logged_in_key=$(generate_password 64)
    wp_nonce_key=$(generate_password 64)
    wp_auth_salt=$(generate_password 64)
    wp_secure_auth_salt=$(generate_password 64)
    wp_logged_in_salt=$(generate_password 64)
    wp_nonce_salt=$(generate_password 64)
    
    # Get Docker image
    read -p "Docker image [ghcr.io/yourusername/wordpress-frankenphp:latest]: " docker_image
    docker_image=${docker_image:-ghcr.io/yourusername/wordpress-frankenphp:latest}
    
    # Get GitHub username for image
    read -p "GitHub username (for image reference): " github_user
    github_user=${github_user:-yourusername}
    
    # Get table prefix
    read -p "Database table prefix [wp_]: " db_table_prefix
    db_table_prefix=${db_table_prefix:-wp_}
    
    print_section "Generating Configuration Files"
    
    # Create .env file
    cat > .env <<EOF
# WordPress Docker Configuration
SITE_NAME=${site_name}
DOMAIN=${domain}
DOCKER_IMAGE=${docker_image}
GITHUB_USER=${github_user}

# Database Configuration
DB_NAME=${db_name}
DB_USER=${db_user}
DB_PASSWORD=${db_password}
DB_ROOT_PASSWORD=${db_root_password}
DB_TABLE_PREFIX=${db_table_prefix}

# WordPress Security Keys
WP_AUTH_KEY=${wp_auth_key}
WP_SECURE_AUTH_KEY=${wp_secure_auth_key}
WP_LOGGED_IN_KEY=${wp_logged_in_key}
WP_NONCE_KEY=${wp_nonce_key}
WP_AUTH_SALT=${wp_auth_salt}
WP_SECURE_AUTH_SALT=${wp_secure_auth_salt}
WP_LOGGED_IN_SALT=${wp_logged_in_salt}
WP_NONCE_SALT=${wp_nonce_salt}

# Cloudflare Tunnel (will be set after tunnel creation)
TUNNEL_ID=
EOF
    
    echo -e "${GREEN}✓ Created .env file${NC}"
    
    # Check for envsubst
    if ! command -v envsubst &> /dev/null; then
        echo -e "${YELLOW}envsubst not found. Attempting to install...${NC}"
        
        local distro=$(detect_distro)
        local package_name=""
        
        case "$distro" in
            ubuntu|debian)
                package_name="gettext-base"
                ;;
            fedora|rhel|centos|arch|manjaro)
                package_name="gettext"
                ;;
            *)
                echo -e "${RED}Could not detect your Linux distribution.${NC}"
                echo -e "${YELLOW}Please install gettext manually:${NC}"
                echo "  Debian/Ubuntu: sudo apt-get install gettext-base"
                echo "  Fedora/RHEL/CentOS: sudo dnf install gettext (or sudo yum install gettext)"
                echo "  Arch/Manjaro: sudo pacman -S gettext"
                exit 1
                ;;
        esac
        
        if install_package "$package_name"; then
            echo -e "${GREEN}✓ Installed $package_name${NC}"
        else
            echo -e "${RED}Failed to install $package_name automatically.${NC}"
            echo -e "${YELLOW}Please install it manually:${NC}"
            case "$distro" in
                ubuntu|debian)
                    echo "  sudo apt-get install gettext-base"
                    ;;
                fedora|rhel|centos)
                    echo "  sudo dnf install gettext"
                    echo "  (or: sudo yum install gettext)"
                    ;;
                arch|manjaro)
                    echo "  sudo pacman -S gettext"
                    ;;
            esac
            exit 1
        fi
    fi
    
    # Export variables for envsubst
    export SITE_NAME=$site_name
    export DOMAIN=$domain
    export DOCKER_IMAGE=$docker_image
    export GITHUB_USER=$github_user
    export DB_NAME=$db_name
    export DB_USER=$db_user
    export DB_PASSWORD=$db_password
    export DB_ROOT_PASSWORD=$db_root_password
    export DB_TABLE_PREFIX=$db_table_prefix
    export WP_AUTH_KEY=$wp_auth_key
    export WP_SECURE_AUTH_KEY=$wp_secure_auth_key
    export WP_LOGGED_IN_KEY=$wp_logged_in_key
    export WP_NONCE_KEY=$wp_nonce_key
    export WP_AUTH_SALT=$wp_auth_salt
    export WP_SECURE_AUTH_SALT=$wp_secure_auth_salt
    export WP_LOGGED_IN_SALT=$wp_logged_in_salt
    export WP_NONCE_SALT=$wp_nonce_salt
    
    # Generate docker-compose.yml from template
    if [ -f "docker-compose.yml.template" ]; then
        envsubst < docker-compose.yml.template > docker-compose.yml
        echo -e "${GREEN}✓ Created docker-compose.yml${NC}"
    else
        echo -e "${YELLOW}Warning: docker-compose.yml.template not found. Using default.${NC}"
        # Create docker-compose.yml directly
        envsubst < "$SCRIPT_DIR/docker-compose.yml.template" > docker-compose.yml 2>/dev/null || {
            echo -e "${RED}Error: Could not generate docker-compose.yml${NC}"
            exit 1
        }
    fi
    
    # Create cloudflared directory
    mkdir -p cloudflared
    
    print_section "Configuration Summary"
    
    print_copy_delimiter
    echo "Site Name: ${site_name}"
    echo "Domain: ${domain}"
    echo "Database Name: ${db_name}"
    echo "Database User: ${db_user}"
    echo "Database Password: ${db_password}"
    echo "Database Root Password: ${db_root_password}"
    print_end_delimiter
    
    print_section "Cloudflare Tunnel Setup"
    
    echo -e "${YELLOW}Follow these steps to set up your Cloudflare Tunnel:${NC}"
    echo ""
    echo "1. Go to https://dash.cloudflare.com/"
    echo "2. Select your domain: ${domain}"
    echo "3. Navigate to: Zero Trust → Networks → Tunnels"
    echo "4. Click 'Create a tunnel'"
    echo "5. Select 'Cloudflared' as the connector"
    echo "6. Give your tunnel a name (e.g., ${site_name}-tunnel)"
    echo "7. After creation, you'll see a command to run. Copy the tunnel ID from the command."
    echo ""
    read -p "Enter your Cloudflare Tunnel ID: " tunnel_id
    
    if [ -z "$tunnel_id" ]; then
        echo -e "${YELLOW}No tunnel ID provided. You can add it later to .env file.${NC}"
    else
        # Update .env with tunnel ID
        sed -i "s/TUNNEL_ID=$/TUNNEL_ID=${tunnel_id}/" .env
        
        # Download tunnel credentials
        echo ""
        echo -e "${BLUE}You need to download your tunnel credentials file.${NC}"
        echo "1. In the Cloudflare dashboard, click on your tunnel"
        echo "2. Go to the 'Configure' tab"
        echo "3. Download the credentials file (JSON format)"
        echo ""
        read -p "Enter the path to your tunnel credentials JSON file (or press Enter to skip): " creds_file
        
        if [ -n "$creds_file" ] && [ -f "$creds_file" ]; then
            cp "$creds_file" "cloudflared/${tunnel_id}.json"
            echo -e "${GREEN}✓ Copied tunnel credentials${NC}"
        else
            echo -e "${YELLOW}Credentials file not provided. You'll need to manually place it at: cloudflared/${tunnel_id}.json${NC}"
        fi
        
        # Generate cloudflared config
        export TUNNEL_ID=$tunnel_id
        export DOMAIN=$domain
        if [ -f "cloudflared-config.yml.template" ]; then
            envsubst < cloudflared-config.yml.template > cloudflared/config.yml
        else
            envsubst < "$SCRIPT_DIR/cloudflared-config.yml.template" > cloudflared/config.yml
        fi
        echo -e "${GREEN}✓ Created cloudflared/config.yml${NC}"
    else
        # Create empty cloudflared directory structure
        mkdir -p cloudflared
        echo -e "${YELLOW}Note: Cloudflared config will be created when you add a tunnel ID.${NC}"
    fi
    
    print_section "Cloudflare DNS Configuration"
    
    echo -e "${YELLOW}Configure DNS in Cloudflare:${NC}"
    echo ""
    echo "1. Go to: DNS → Records"
    echo "2. Add a new CNAME record:"
    echo ""
    print_copy_delimiter
    echo "Type: CNAME"
    echo "Name: @ (or your subdomain)"
    echo "Target: ${tunnel_id}.cfargotunnel.com"
    echo "Proxy status: Proxied (orange cloud)"
    print_end_delimiter
    
    if [ -n "$tunnel_id" ]; then
        echo ""
        echo -e "${GREEN}Your tunnel target: ${tunnel_id}.cfargotunnel.com${NC}"
    fi
    
    print_section "Deployment Commands"
    
    echo -e "${GREEN}Your WordPress site is ready to deploy!${NC}"
    echo ""
    echo "Run the following command to start your site:"
    echo ""
    print_copy_delimiter
    echo "docker compose up -d"
    print_end_delimiter
    echo ""
    echo "To view logs:"
    print_copy_delimiter
    echo "docker compose logs -f"
    print_end_delimiter
    echo ""
    echo "To stop your site:"
    print_copy_delimiter
    echo "docker compose down"
    print_end_delimiter
    echo ""
    echo -e "${GREEN}Setup complete!${NC}"
}

# Install WordPress
cmd_install() {
    if [ ! -f "docker-compose.yml" ]; then
        echo -e "${RED}Error: docker-compose.yml not found. Run 'init' first.${NC}"
        exit 1
    fi
    
    # Source .env if it exists
    if [ -f ".env" ]; then
        set -a
        source .env 2>/dev/null || true
        set +a
    fi
    
    print_section "WordPress Installation"
    
    echo "Starting containers..."
    docker compose up -d
    
    echo "Waiting for services to be ready..."
    sleep 10
    
    echo -e "${GREEN}WordPress is starting up.${NC}"
    echo "Once containers are running, visit https://${DOMAIN:-your-domain.com} to complete the WordPress installation."
    echo ""
    echo "To check container status:"
    echo "  docker compose ps"
    echo ""
    echo "To view logs:"
    echo "  docker compose logs -f wordpress"
}

# Update WordPress
cmd_update() {
    if [ ! -f "docker-compose.yml" ]; then
        echo -e "${RED}Error: docker-compose.yml not found.${NC}"
        exit 1
    fi
    
    print_section "Updating WordPress"
    
    echo "Pulling latest images..."
    docker compose pull
    
    echo "Restarting containers..."
    docker compose up -d
    
    echo -e "${GREEN}Update complete!${NC}"
}

# Start containers
cmd_start() {
    if [ ! -f "docker-compose.yml" ]; then
        echo -e "${RED}Error: docker-compose.yml not found. Run 'init' first.${NC}"
        exit 1
    fi
    
    print_section "Starting WordPress"
    docker compose up -d
    echo -e "${GREEN}WordPress started!${NC}"
}

# Stop containers
cmd_stop() {
    if [ ! -f "docker-compose.yml" ]; then
        echo -e "${RED}Error: docker-compose.yml not found.${NC}"
        exit 1
    fi
    
    print_section "Stopping WordPress"
    docker compose down
    echo -e "${GREEN}WordPress stopped!${NC}"
}

# Restart containers
cmd_restart() {
    if [ ! -f "docker-compose.yml" ]; then
        echo -e "${RED}Error: docker-compose.yml not found.${NC}"
        exit 1
    fi
    
    print_section "Restarting WordPress"
    docker compose restart
    echo -e "${GREEN}WordPress restarted!${NC}"
}

# View logs
cmd_logs() {
    if [ ! -f "docker-compose.yml" ]; then
        echo -e "${RED}Error: docker-compose.yml not found.${NC}"
        exit 1
    fi
    
    local service=${1:-}
    if [ -n "$service" ]; then
        docker compose logs -f "$service"
    else
        docker compose logs -f
    fi
}

# Show configuration
cmd_show_config() {
    if [ ! -f ".env" ]; then
        echo -e "${RED}Error: .env file not found. Run 'init' first.${NC}"
        exit 1
    fi
    
    print_section "Current Configuration"
    
    # Source .env to get variables
    set -a
    source .env 2>/dev/null || true
    set +a
    
    print_copy_delimiter
    echo "Site Name: ${SITE_NAME:-not set}"
    echo "Domain: ${DOMAIN:-not set}"
    echo "Database Name: ${DB_NAME:-not set}"
    echo "Database User: ${DB_USER:-not set}"
    echo "Tunnel ID: ${TUNNEL_ID:-not set}"
    print_end_delimiter
}

# Show help
cmd_help() {
    echo "WordPress Docker CLI Tool"
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  init              Initialize a new WordPress site"
    echo "  install           Install and start WordPress"
    echo "  update            Update WordPress and containers"
    echo "  start             Start WordPress containers"
    echo "  stop              Stop WordPress containers"
    echo "  restart           Restart WordPress containers"
    echo "  logs [service]    View container logs (optionally for specific service)"
    echo "  show-config       Display current configuration"
    echo "  help              Show this help message"
    echo ""
}

# Main command dispatcher
main() {
    local cmd=${1:-help}
    
    case "$cmd" in
        init)
            cmd_init
            ;;
        install)
            cmd_install
            ;;
        update)
            cmd_update
            ;;
        start)
            cmd_start
            ;;
        stop)
            cmd_stop
            ;;
        restart)
            cmd_restart
            ;;
        logs)
            cmd_logs "$2"
            ;;
        show-config)
            cmd_show_config
            ;;
        help|--help|-h)
            cmd_help
            ;;
        *)
            echo -e "${RED}Unknown command: $cmd${NC}"
            echo ""
            cmd_help
            exit 1
            ;;
    esac
}

main "$@"
