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

# Load API integration modules
if [ -f "${SCRIPT_DIR}/lib/cloudflare-api.sh" ]; then
    source "${SCRIPT_DIR}/lib/cloudflare-api.sh"
fi
if [ -f "${SCRIPT_DIR}/lib/github-api.sh" ]; then
    source "${SCRIPT_DIR}/lib/github-api.sh"
fi
if [ -f "${SCRIPT_DIR}/lib/komodo-api.sh" ]; then
    source "${SCRIPT_DIR}/lib/komodo-api.sh"
fi

# Global flags
AUTOMATED_MODE=false
DRY_RUN=false

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

# Load API credentials from environment or config file
load_api_credentials() {
    # Try to load from config file first
    if [ -f "config/api-credentials" ]; then
        set -a
        source "config/api-credentials" 2>/dev/null || true
        set +a
    fi
    
    # Environment variables take precedence
    export CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
    export GITHUB_TOKEN="${GITHUB_TOKEN:-}"
    export GITHUB_USERNAME="${GITHUB_USERNAME:-${GITHUB_USER:-}}"
    export KOMODO_BASE_URL="${KOMODO_BASE_URL:-}"
    export KOMODO_API_KEY="${KOMODO_API_KEY:-}"
    export KOMODO_API_SECRET="${KOMODO_API_SECRET:-}"
}

# Prompt for API credentials if not set
prompt_api_credentials() {
    if [ "$AUTOMATED_MODE" = true ]; then
        print_section "API Credentials Configuration"
        
        # Cloudflare API Token
        if [ -z "$CLOUDFLARE_API_TOKEN" ]; then
            echo -e "${BLUE}Enter your Cloudflare API Token:${NC}"
            echo -e "${YELLOW}(Required permissions: Zone:Read, Zone:Edit, Account:Cloudflare Tunnel:Edit)${NC}"
            read -p "Cloudflare API Token: " CLOUDFLARE_API_TOKEN
            export CLOUDFLARE_API_TOKEN
        fi
        
        # GitHub Token
        if [ -z "$GITHUB_TOKEN" ]; then
            echo -e "${BLUE}Enter your GitHub Personal Access Token:${NC}"
            echo -e "${YELLOW}(Required scopes: write:packages, read:packages)${NC}"
            read -p "GitHub Token: " GITHUB_TOKEN
            export GITHUB_TOKEN
        fi
        
        # GitHub Username
        if [ -z "$GITHUB_USERNAME" ] && [ -z "$GITHUB_USER" ]; then
            echo -e "${BLUE}Enter your GitHub username:${NC}"
            read -p "GitHub Username: " GITHUB_USERNAME
            export GITHUB_USERNAME
        elif [ -n "$GITHUB_USER" ] && [ -z "$GITHUB_USERNAME" ]; then
            export GITHUB_USERNAME="$GITHUB_USER"
        fi
        
        # Komodo credentials (optional)
        echo ""
        read -p "Do you want to configure Komodo deployment? (y/N): " configure_komodo
        if [[ $configure_komodo =~ ^[Yy]$ ]]; then
            if [ -z "$KOMODO_BASE_URL" ]; then
                echo -e "${BLUE}Enter your Komodo base URL (e.g., https://komodo.example.com):${NC}"
                read -p "Komodo Base URL: " KOMODO_BASE_URL
                export KOMODO_BASE_URL
            fi
            if [ -z "$KOMODO_API_KEY" ]; then
                echo -e "${BLUE}Enter your Komodo API Key:${NC}"
                read -p "Komodo API Key: " KOMODO_API_KEY
                export KOMODO_API_KEY
            fi
            if [ -z "$KOMODO_API_SECRET" ]; then
                echo -e "${BLUE}Enter your Komodo API Secret:${NC}"
                read -p "Komodo API Secret: " KOMODO_API_SECRET
                export KOMODO_API_SECRET
            fi
        fi
    fi
}

# Validate API credentials
validate_api_credentials() {
    local errors=0
    
    if [ "$AUTOMATED_MODE" = true ]; then
        # Validate Cloudflare
        if [ -n "$CLOUDFLARE_API_TOKEN" ]; then
            echo -e "${BLUE}Validating Cloudflare API token...${NC}"
            if cloudflare_validate_token; then
                echo -e "${GREEN}✓ Cloudflare API token is valid${NC}"
            else
                echo -e "${RED}✗ Cloudflare API token is invalid${NC}"
                errors=$((errors + 1))
            fi
        fi
        
        # Validate GitHub
        if [ -n "$GITHUB_TOKEN" ] && [ -n "$GITHUB_USERNAME" ]; then
            echo -e "${BLUE}Validating GitHub token...${NC}"
            if github_validate_token; then
                echo -e "${GREEN}✓ GitHub token is valid${NC}"
            else
                echo -e "${RED}✗ GitHub token is invalid${NC}"
                errors=$((errors + 1))
            fi
        fi
        
        # Validate Komodo (if configured)
        if [ -n "$KOMODO_BASE_URL" ] && [ -n "$KOMODO_API_KEY" ] && [ -n "$KOMODO_API_SECRET" ]; then
            echo -e "${BLUE}Validating Komodo credentials...${NC}"
            if komodo_validate_credentials; then
                echo -e "${GREEN}✓ Komodo credentials are valid${NC}"
            else
                echo -e "${RED}✗ Komodo credentials are invalid${NC}"
                errors=$((errors + 1))
            fi
        fi
    fi
    
    return $errors
}

# Initialize new WordPress site
cmd_init() {
    local automated_flag=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --automated|-a)
                automated_flag=true
                AUTOMATED_MODE=true
                shift
                ;;
            --dry-run|-d)
                DRY_RUN=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done
    
    print_section "WordPress Docker Setup - Initialization"
    
    # Load API credentials
    load_api_credentials
    
    # Check if already initialized
    if [ -f "docker-compose.yml" ] || [ -f ".env" ]; then
        echo -e "${YELLOW}Warning: docker-compose.yml or .env already exists.${NC}"
        read -p "Do you want to overwrite? (y/N): " overwrite
        if [[ ! $overwrite =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 0
        fi
    fi
    
    # Prompt for automated mode if not specified
    if [ "$automated_flag" = false ]; then
        echo ""
        read -p "Do you want to use automated deployment (Cloudflare, GitHub, Komodo APIs)? (y/N): " use_automated
        if [[ $use_automated =~ ^[Yy]$ ]]; then
            AUTOMATED_MODE=true
        fi
    fi
    
    # Prompt for API credentials if in automated mode
    if [ "$AUTOMATED_MODE" = true ]; then
        prompt_api_credentials
        
        # Validate credentials
        if ! validate_api_credentials; then
            echo -e "${RED}Error: Some API credentials are invalid. Please check and try again.${NC}"
            echo -e "${YELLOW}You can continue with manual setup, but automated features will not work.${NC}"
            read -p "Continue anyway? (y/N): " continue_anyway
            if [[ ! $continue_anyway =~ ^[Yy]$ ]]; then
                exit 1
            fi
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
    
    # Get Docker image configuration
    echo ""
    echo -e "${BLUE}Docker Image Configuration${NC}"
    echo -e "${YELLOW}The Docker image will be stored at GitHub Container Registry (ghcr.io).${NC}"
    echo ""
    
    # Use GitHub username from API credentials if available
    if [ -n "$GITHUB_USERNAME" ]; then
        github_user="$GITHUB_USERNAME"
        echo -e "${GREEN}Using GitHub username from credentials: ${github_user}${NC}"
    else
        # Get GitHub username for building the image
        echo -e "${BLUE}Enter your GitHub username (for building/pushing the Docker image):${NC}"
        read -p "GitHub username: " github_user
        while [ -z "$github_user" ] || [ "$github_user" = "yourusername" ]; do
            if [ -z "$github_user" ]; then
                echo -e "${RED}GitHub username is required.${NC}"
            else
                echo -e "${YELLOW}Please enter your actual GitHub username, not 'yourusername'.${NC}"
            fi
            read -p "GitHub username: " github_user
        done
    fi
    
    # Set Docker image based on GitHub username
    docker_image="ghcr.io/${github_user}/wordpress-frankenphp:latest"
    
    # In automated mode, check if image exists or offer to build
    if [ "$AUTOMATED_MODE" = true ] && [ -n "$GITHUB_TOKEN" ] && [ -n "$GITHUB_USERNAME" ]; then
        github_init "$GITHUB_TOKEN" "$GITHUB_USERNAME"
        echo ""
        echo -e "${BLUE}Checking if Docker image exists in registry...${NC}"
        if github_check_image_exists "wordpress-frankenphp" "latest"; then
            echo -e "${GREEN}✓ Docker image already exists in registry${NC}"
            read -p "Do you want to rebuild and push the image? (y/N): " rebuild_image
            if [[ $rebuild_image =~ ^[Yy]$ ]]; then
                BUILD_IMAGE=true
            else
                BUILD_IMAGE=false
            fi
        else
            echo -e "${YELLOW}Docker image not found in registry${NC}"
            read -p "Do you want to build and push the image now? (Y/n): " build_image
            if [[ ! $build_image =~ ^[Nn]$ ]]; then
                BUILD_IMAGE=true
            else
                BUILD_IMAGE=false
            fi
        fi
    else
        echo ""
        echo -e "${GREEN}✓ Docker image configured: ${docker_image}${NC}"
        if [ "$AUTOMATED_MODE" = false ]; then
            echo -e "${YELLOW}To build and push this image, run:${NC}"
            echo "  ./build.sh --user ${github_user}"
            echo "  ./push.sh --user ${github_user}"
        fi
        BUILD_IMAGE=false
    fi
    
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
    
    tunnel_id=""
    
    if [ "$AUTOMATED_MODE" = true ] && [ -n "$CLOUDFLARE_API_TOKEN" ]; then
        # Automated Cloudflare setup
        echo -e "${BLUE}Setting up Cloudflare tunnel automatically...${NC}"
        
        if [ "$DRY_RUN" = true ]; then
            echo -e "${YELLOW}[DRY RUN] Would create Cloudflare tunnel${NC}"
            tunnel_id="dry-run-tunnel-id"
        else
            # Initialize Cloudflare API
            cloudflare_init "$CLOUDFLARE_API_TOKEN"
            
            # Get account ID
            echo "Getting Cloudflare account ID..."
            account_id=$(cloudflare_get_account_id)
            if [ -z "$account_id" ]; then
                echo -e "${RED}Error: Could not get Cloudflare account ID${NC}"
                echo -e "${YELLOW}Falling back to manual setup...${NC}"
                AUTOMATED_MODE=false
            else
                echo -e "${GREEN}✓ Account ID: ${account_id}${NC}"
                
                # Create tunnel
                tunnel_name="${site_name}-tunnel"
                echo "Creating tunnel: ${tunnel_name}..."
                tunnel_id=$(cloudflare_create_tunnel "$tunnel_name" "$account_id")
                
                if [ -z "$tunnel_id" ]; then
                    echo -e "${RED}Error: Could not create Cloudflare tunnel${NC}"
                    echo -e "${YELLOW}Falling back to manual setup...${NC}"
                    AUTOMATED_MODE=false
                else
                    echo -e "${GREEN}✓ Tunnel created: ${tunnel_id}${NC}"
                    
                    # Get tunnel credentials
                    echo "Downloading tunnel credentials..."
                    mkdir -p cloudflared
                    if cloudflare_get_tunnel_credentials "$tunnel_id" "$account_id" "cloudflared/${tunnel_id}.json"; then
                        echo -e "${GREEN}✓ Tunnel credentials downloaded${NC}"
                    else
                        echo -e "${YELLOW}Warning: Could not download tunnel credentials automatically${NC}"
                    fi
                fi
            fi
        fi
    fi
    
    # Manual setup fallback
    if [ -z "$tunnel_id" ] || [ "$AUTOMATED_MODE" = false ]; then
        echo -e "${YELLOW}Manual Cloudflare Tunnel Setup${NC}"
        echo ""
        echo "Follow these steps to set up your Cloudflare Tunnel:"
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
            mkdir -p cloudflared
        else
            # Download tunnel credentials manually
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
        fi
    fi
    
    # Update .env with tunnel ID if we have it
    if [ -n "$tunnel_id" ]; then
        sed -i "s/TUNNEL_ID=$/TUNNEL_ID=${tunnel_id}/" .env
        
        # Generate cloudflared config
        export TUNNEL_ID=$tunnel_id
        export DOMAIN=$domain
        if [ -f "cloudflared-config.yml.template" ]; then
            envsubst < cloudflared-config.yml.template > cloudflared/config.yml
        else
            envsubst < "$SCRIPT_DIR/cloudflared-config.yml.template" > cloudflared/config.yml
        fi
        echo -e "${GREEN}✓ Created cloudflared/config.yml${NC}"
    fi
    
    print_section "Cloudflare DNS Configuration"
    
    if [ "$AUTOMATED_MODE" = true ] && [ -n "$CLOUDFLARE_API_TOKEN" ] && [ -n "$tunnel_id" ]; then
        # Automated DNS setup
        echo -e "${BLUE}Creating DNS record automatically...${NC}"
        
        if [ "$DRY_RUN" = true ]; then
            echo -e "${YELLOW}[DRY RUN] Would create DNS CNAME record${NC}"
        else
            # Get zone ID
            echo "Getting zone ID for domain: ${domain}..."
            zone_id=$(cloudflare_get_zone_id "$domain")
            
            if [ -z "$zone_id" ]; then
                echo -e "${RED}Error: Could not get zone ID for domain ${domain}${NC}"
                echo -e "${YELLOW}Please create the DNS record manually${NC}"
            else
                echo -e "${GREEN}✓ Zone ID: ${zone_id}${NC}"
                
                # Create DNS record
                dns_name="@"
                dns_target="${tunnel_id}.cfargotunnel.com"
                echo "Creating CNAME record: ${dns_name} -> ${dns_target}..."
                
                record_id=$(cloudflare_create_dns_record "$zone_id" "$dns_name" "$dns_target" "true")
                
                if [ -n "$record_id" ]; then
                    echo -e "${GREEN}✓ DNS record created successfully${NC}"
                else
                    echo -e "${YELLOW}Warning: Could not create DNS record automatically${NC}"
                    echo -e "${YELLOW}Please create it manually in Cloudflare dashboard${NC}"
                fi
            fi
        fi
    else
        # Manual DNS setup
        echo -e "${YELLOW}Configure DNS in Cloudflare:${NC}"
        echo ""
        echo "1. Go to: DNS → Records"
        echo "2. Add a new CNAME record:"
        echo ""
        print_copy_delimiter
        echo "Type: CNAME"
        echo "Name: @ (or your subdomain)"
        if [ -n "$tunnel_id" ]; then
            echo "Target: ${tunnel_id}.cfargotunnel.com"
        else
            echo "Target: <tunnel-id>.cfargotunnel.com"
        fi
        echo "Proxy status: Proxied (orange cloud)"
        print_end_delimiter
    fi
    
    if [ -n "$tunnel_id" ]; then
        echo ""
        echo -e "${GREEN}Your tunnel target: ${tunnel_id}.cfargotunnel.com${NC}"
    fi
    
    # Build and push Docker image if requested
    if [ "$BUILD_IMAGE" = true ] && [ "$AUTOMATED_MODE" = true ] && [ -n "$GITHUB_TOKEN" ] && [ -n "$GITHUB_USERNAME" ]; then
        print_section "Building and Pushing Docker Image"
        
        if [ "$DRY_RUN" = true ]; then
            echo -e "${YELLOW}[DRY RUN] Would build and push Docker image${NC}"
        else
            echo "Building Docker image..."
            if github_build_and_push_image "wordpress-frankenphp" "latest" "."; then
                echo -e "${GREEN}✓ Docker image built and pushed successfully${NC}"
            else
                echo -e "${RED}Error: Failed to build/push Docker image${NC}"
                echo -e "${YELLOW}You can build it manually later using:${NC}"
                echo "  ./build.sh --user ${github_user}"
                echo "  ./push.sh --user ${github_user}"
            fi
        fi
    fi
    
    # Save API credentials to config file if in automated mode
    if [ "$AUTOMATED_MODE" = true ]; then
        mkdir -p config
        cat > config/api-credentials <<EOF
# API Credentials (auto-generated)
# Keep this file secure and do not commit it to version control

CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GITHUB_USERNAME="${GITHUB_USERNAME:-}"
KOMODO_BASE_URL="${KOMODO_BASE_URL:-}"
KOMODO_API_KEY="${KOMODO_API_KEY:-}"
KOMODO_API_SECRET="${KOMODO_API_SECRET:-}"
EOF
        chmod 600 config/api-credentials
        echo -e "${GREEN}✓ API credentials saved to config/api-credentials${NC}"
    fi
    
    print_section "Deployment Commands"
    
    echo -e "${GREEN}Your WordPress site is ready to deploy!${NC}"
    echo ""
    
    if [ "$AUTOMATED_MODE" = true ] && [ -n "$KOMODO_BASE_URL" ] && [ -n "$KOMODO_API_KEY" ] && [ -n "$KOMODO_API_SECRET" ]; then
        echo "You can deploy to Komodo using:"
        print_copy_delimiter
        echo "./wp-docker-cli.sh deploy"
        print_end_delimiter
        echo ""
        echo "Or deploy locally with:"
    else
        echo "Run the following command to start your site:"
    fi
    
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

# Deploy to Komodo
cmd_deploy() {
    if [ ! -f "docker-compose.yml" ]; then
        echo -e "${RED}Error: docker-compose.yml not found. Run 'init' first.${NC}"
        exit 1
    fi
    
    # Load API credentials
    load_api_credentials
    
    if [ -z "$KOMODO_BASE_URL" ] || [ -z "$KOMODO_API_KEY" ] || [ -z "$KOMODO_API_SECRET" ]; then
        echo -e "${RED}Error: Komodo credentials not configured${NC}"
        echo -e "${YELLOW}Please set KOMODO_BASE_URL, KOMODO_API_KEY, and KOMODO_API_SECRET${NC}"
        echo "You can add them to config/api-credentials or environment variables"
        exit 1
    fi
    
    # Source .env to get site name
    if [ -f ".env" ]; then
        set -a
        source .env 2>/dev/null || true
        set +a
    fi
    
    local stack_name="${SITE_NAME:-wordpress}"
    local server_name="${1:-}"
    
    print_section "Deploying to Komodo"
    
    # Initialize Komodo API
    komodo_init "$KOMODO_BASE_URL" "$KOMODO_API_KEY" "$KOMODO_API_SECRET"
    
    # Validate credentials
    if ! komodo_validate_credentials; then
        echo -e "${RED}Error: Invalid Komodo credentials${NC}"
        exit 1
    fi
    
    echo "Creating/updating stack: ${stack_name}"
    
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY RUN] Would create/update stack in Komodo${NC}"
    else
        # Ensure stack exists (create or update)
        if komodo_ensure_stack "$stack_name" "docker-compose.yml" "$server_name"; then
            echo -e "${GREEN}✓ Stack created/updated successfully${NC}"
            
            # Deploy the stack
            echo "Deploying stack..."
            if komodo_deploy_stack "$stack_name"; then
                echo -e "${GREEN}✓ Stack deployed successfully${NC}"
            else
                echo -e "${RED}Error: Failed to deploy stack${NC}"
                exit 1
            fi
        else
            echo -e "${RED}Error: Failed to create/update stack${NC}"
            exit 1
        fi
    fi
}

# Show help
cmd_help() {
    echo "WordPress Docker CLI Tool"
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  init [--automated] [--dry-run]  Initialize a new WordPress site"
    echo "                                  --automated: Use API automation (Cloudflare, GitHub, Komodo)"
    echo "                                  --dry-run: Test API calls without making changes"
    echo "  deploy [server_name]            Deploy stack to Komodo (requires Komodo credentials)"
    echo "  install                        Install and start WordPress"
    echo "  update                         Update WordPress and containers"
    echo "  start                          Start WordPress containers"
    echo "  stop                           Stop WordPress containers"
    echo "  restart                        Restart WordPress containers"
    echo "  logs [service]                 View container logs (optionally for specific service)"
    echo "  show-config                    Display current configuration"
    echo "  help                           Show this help message"
    echo ""
    echo "Automated Deployment:"
    echo "  Use 'init --automated' to enable automatic:"
    echo "    - Cloudflare tunnel creation and DNS configuration"
    echo "    - GitHub Container Registry image building/pushing"
    echo "    - Komodo stack deployment (via 'deploy' command)"
    echo ""
}

# Main command dispatcher
main() {
    local cmd=${1:-help}
    shift || true
    
    case "$cmd" in
        init)
            cmd_init "$@"
            ;;
        deploy)
            cmd_deploy "$@"
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
            cmd_logs "$1"
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
