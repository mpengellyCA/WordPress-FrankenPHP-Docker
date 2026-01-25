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
CREDENTIALS_UNLOCKED=false

# Cleanup function for temporary credential files
cleanup_temp_files() {
    # Clean up any temporary credential files
    rm -f config/api-credentials.tmp 2>/dev/null || true
    rm -f config/api-credentials.existing.tmp 2>/dev/null || true
    rm -f config/api-credentials.merged.tmp 2>/dev/null || true
    rm -f config/api-credentials.enc.new 2>/dev/null || true
    rm -f config/api-credentials.verify.tmp 2>/dev/null || true
    rm -f config/api-credentials 2>/dev/null || true
}

# Trap handler for interruptions
handle_interrupt() {
    echo ""
    echo -e "${YELLOW}Process interrupted. Cleaning up...${NC}"
    cleanup_temp_files
    echo -e "${BLUE}Note: Any credentials entered and validated have been saved.${NC}"
    echo -e "${BLUE}Run the script again to continue or add missing credentials.${NC}"
    exit 130
}

# Set up trap for SIGINT (Ctrl+C) and SIGTERM
trap handle_interrupt SIGINT SIGTERM

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

# Encrypt credentials file with PIN
# Usage: encrypt_credentials <credentials_file> <encrypted_file>
encrypt_credentials() {
    local credentials_file="$1"
    local encrypted_file="$2"
    local pin="$3"
    
    if [ -z "$credentials_file" ] || [ -z "$encrypted_file" ] || [ -z "$pin" ]; then
        echo "Error: All parameters required for encryption" >&2
        return 1
    fi
    
    if [ ! -f "$credentials_file" ]; then
        echo "Error: Credentials file not found" >&2
        return 1
    fi
    
    # Use openssl to encrypt with the PIN as the key (using PBKDF2)
    echo "$pin" | openssl enc -aes-256-cbc -pbkdf2 -salt -in "$credentials_file" -out "$encrypted_file" -pass stdin 2>/dev/null
    
    if [ $? -eq 0 ]; then
        # Remove the unencrypted file
        rm -f "$credentials_file"
        chmod 600 "$encrypted_file"
        return 0
    else
        echo "Error: Failed to encrypt credentials" >&2
        return 1
    fi
}

# Decrypt credentials file with PIN
# Usage: decrypt_credentials <encrypted_file> <output_file>
decrypt_credentials() {
    local encrypted_file="$1"
    local output_file="$2"
    local pin="$3"
    
    if [ -z "$encrypted_file" ] || [ -z "$output_file" ] || [ -z "$pin" ]; then
        echo "Error: All parameters required for decryption" >&2
        return 1
    fi
    
    if [ ! -f "$encrypted_file" ]; then
        echo "Error: Encrypted credentials file not found" >&2
        return 1
    fi
    
    # Use openssl to decrypt with the PIN as the key
    echo "$pin" | openssl enc -aes-256-cbc -pbkdf2 -d -salt -in "$encrypted_file" -out "$output_file" -pass stdin 2>/dev/null
    
    if [ $? -eq 0 ]; then
        chmod 600 "$output_file"
        return 0
    else
        echo "Error: Failed to decrypt credentials (wrong PIN or corrupted file)" >&2
        rm -f "$output_file"
        return 1
    fi
}

# Check if encrypted credentials file is valid and accessible
# Usage: verify_encrypted_credentials <encrypted_file> <pin>
verify_encrypted_credentials() {
    local encrypted_file="$1"
    local pin="$2"
    local temp_verify="config/api-credentials.verify.tmp"
    
    if [ ! -f "$encrypted_file" ]; then
        return 1
    fi
    
    if decrypt_credentials "$encrypted_file" "$temp_verify" "$pin"; then
        rm -f "$temp_verify"
        return 0
    else
        rm -f "$temp_verify"
        return 1
    fi
}

# Unlock credentials with provided PIN
# Usage: unlock_credentials_with_pin <pin>
# Returns: 0 on success, 1 on failure
unlock_credentials_with_pin() {
    local pin="$1"
    local encrypted_file="config/api-credentials.enc"
    local temp_file="config/api-credentials.tmp"
    
    if [ ! -f "$encrypted_file" ] || [ -z "$pin" ]; then
        return 1
    fi
    
    if decrypt_credentials "$encrypted_file" "$temp_file" "$pin"; then
        # Load decrypted credentials into current shell
        set -a
        source "$temp_file" 2>/dev/null || true
        set +a
        
        # Export credentials to make sure they're available
        export CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
        export GITHUB_TOKEN="${GITHUB_TOKEN:-}"
        export GITHUB_USERNAME="${GITHUB_USERNAME:-${GITHUB_USER:-}}"
        export KOMODO_BASE_URL="${KOMODO_BASE_URL:-}"
        export KOMODO_API_KEY="${KOMODO_API_KEY:-}"
        export KOMODO_API_SECRET="${KOMODO_API_SECRET:-}"
        
        # Track unlocked state and keep the PIN for this session
        export PIN="${PIN:-$pin}"
        CREDENTIALS_UNLOCKED=true

        # Clean up temp file after a short delay to ensure it's loaded
        # (Don't delete immediately in case we need to reference it)
        # Actually, let's keep it for now in case we need to merge more credentials

        return 0
    else
        return 1
    fi
}

# Prompt for PIN and decrypt credentials (with retry)
# Usage: unlock_credentials
# Returns: 0 on success, 1 on failure
unlock_credentials() {
    local encrypted_file="config/api-credentials.enc"
    
    if [ ! -f "$encrypted_file" ]; then
        return 1
    fi
    
    local max_attempts=3
    local attempts=0
    
    while [ $attempts -lt $max_attempts ]; do
        echo ""
        echo -e "${BLUE}Enter PIN to unlock encrypted credentials:${NC}"
        read -s -p "PIN: " pin
        echo ""
        
        if unlock_credentials_with_pin "$pin"; then
            export PIN="$pin"
            CREDENTIALS_UNLOCKED=true
            echo -e "${GREEN}✓ Credentials unlocked${NC}"
            return 0
        else
            attempts=$((attempts + 1))
            remaining=$((max_attempts - attempts))
            if [ $remaining -gt 0 ]; then
                echo -e "${RED}Invalid PIN. ${remaining} attempt(s) remaining.${NC}"
            else
                echo -e "${RED}Maximum attempts reached. Cannot unlock credentials.${NC}"
                return 1
            fi
        fi
    done
    
    return 1
}

# Prompt to create PIN and encrypt credentials
# Usage: create_pin_and_encrypt
create_pin_and_encrypt() {
    local credentials_file="config/api-credentials"
    local encrypted_file="config/api-credentials.enc"
    
    if [ ! -f "$credentials_file" ]; then
        echo "Error: No credentials file to encrypt" >&2
        return 1
    fi
    
    echo ""
    echo -e "${BLUE}Create a PIN to encrypt your API credentials:${NC}"
    echo -e "${YELLOW}(This PIN will be required to unlock credentials in the future)${NC}"
    
    while true; do
        read -s -p "Enter PIN: " pin1
        echo ""
        
        if [ -z "$pin1" ]; then
            echo -e "${RED}Error: PIN cannot be empty${NC}"
            continue
        fi
        
        if [ ${#pin1} -lt 4 ]; then
            echo -e "${RED}Error: PIN must be at least 4 characters${NC}"
            continue
        fi
        
        read -s -p "Confirm PIN: " pin2
        echo ""
        
        if [ "$pin1" != "$pin2" ]; then
            echo -e "${RED}Error: PINs do not match. Please try again.${NC}"
            continue
        fi
        
        # Encrypt the credentials
        if encrypt_credentials "$credentials_file" "$encrypted_file" "$pin1"; then
            echo -e "${GREEN}✓ Credentials encrypted and stored securely${NC}"
            echo -e "${YELLOW}Remember your PIN - you'll need it to unlock credentials!${NC}"
            return 0
        else
            echo -e "${RED}Error: Failed to encrypt credentials${NC}"
            return 1
        fi
    done
}

# Load API credentials from environment or config file
load_api_credentials() {
    local encrypted_file="config/api-credentials.enc"
    local unencrypted_file="config/api-credentials"
    
    # Environment variables take precedence (don't load from file if env vars are set)
    if [ -n "$CLOUDFLARE_API_TOKEN" ] || [ -n "$GITHUB_TOKEN" ] || [ -n "$KOMODO_API_KEY" ]; then
        # User has provided credentials via environment, use those
        export CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
        export GITHUB_TOKEN="${GITHUB_TOKEN:-}"
        export GITHUB_USERNAME="${GITHUB_USERNAME:-${GITHUB_USER:-}}"
        export KOMODO_BASE_URL="${KOMODO_BASE_URL:-}"
        export KOMODO_API_KEY="${KOMODO_API_KEY:-}"
        export KOMODO_API_SECRET="${KOMODO_API_SECRET:-}"
        return 0
    fi
    
    # Check for encrypted credentials first
    if [ -f "$encrypted_file" ]; then
        echo -e "${BLUE}Encrypted credentials found.${NC}"
        if unlock_credentials; then
            # Credentials are now loaded via unlock_credentials
            return 0
        else
            echo -e "${YELLOW}Failed to unlock credentials. Continuing without them...${NC}"
        fi
    fi
    
    # Try to load from unencrypted config file (for backward compatibility)
    if [ -f "$unencrypted_file" ]; then
        set -a
        source "$unencrypted_file" 2>/dev/null || true
        set +a
    fi
    
    # Export any loaded credentials
    export CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
    export GITHUB_TOKEN="${GITHUB_TOKEN:-}"
    export GITHUB_USERNAME="${GITHUB_USERNAME:-${GITHUB_USER:-}}"
    export KOMODO_BASE_URL="${KOMODO_BASE_URL:-}"
    export KOMODO_API_KEY="${KOMODO_API_KEY:-}"
    export KOMODO_API_SECRET="${KOMODO_API_SECRET:-}"
}

# Check which credentials are saved and display status
check_saved_credentials_status() {
    local has_cloudflare=false
    local has_github=false
    local has_komodo=false
    
    if [ -n "$CLOUDFLARE_API_TOKEN" ]; then
        has_cloudflare=true
    fi
    
    if [ -n "$GITHUB_TOKEN" ] && [ -n "$GITHUB_USERNAME" ]; then
        has_github=true
    fi
    
    if [ -n "$KOMODO_BASE_URL" ] && [ -n "$KOMODO_API_KEY" ] && [ -n "$KOMODO_API_SECRET" ]; then
        has_komodo=true
    fi
    
    # Display status
    echo ""
    echo -e "${BLUE}=== Saved Credentials Status ===${NC}"
    
    if [ "$has_cloudflare" = true ]; then
        echo -e "${GREEN}✓ Cloudflare API Token${NC}"
    else
        echo -e "${YELLOW}✗ Cloudflare API Token (missing)${NC}"
    fi
    
    if [ "$has_github" = true ]; then
        echo -e "${GREEN}✓ GitHub Token & Username${NC}"
    else
        echo -e "${YELLOW}✗ GitHub Token & Username (missing)${NC}"
    fi
    
    if [ "$has_komodo" = true ]; then
        echo -e "${GREEN}✓ Komodo Credentials${NC}"
    else
        echo -e "${YELLOW}  Komodo Credentials (not configured)${NC}"
    fi
    
    echo ""
    
    # Return codes: 0 = complete, 1 = incomplete, 2 = none
    if [ "$has_cloudflare" = true ] && [ "$has_github" = true ]; then
        return 0  # Complete (Komodo is optional)
    elif [ "$has_cloudflare" = true ] || [ "$has_github" = true ] || [ "$has_komodo" = true ]; then
        return 1  # Incomplete
    else
        return 2  # None
    fi
}

# Ask if user wants to use saved credentials
ask_use_saved_credentials() {
    # Check status and display
    check_saved_credentials_status
    local status=$?
    
    if [ $status -eq 2 ]; then
        # No credentials at all
        return 1
    elif [ $status -eq 1 ]; then
        # Incomplete credentials
        echo -e "${YELLOW}⚠ Warning: Saved credentials are incomplete!${NC}"
        echo ""
        echo "What would you like to do?"
        echo "1) Keep existing and add missing credentials"
        echo "2) Replace all credentials"
        echo "3) Cancel and exit"
        read -p "Choose an option (1-3): " choice
        
        case "$choice" in
            1)
                echo -e "${GREEN}Will keep existing credentials and prompt for missing ones.${NC}"
                return 0  # Use saved and add missing
                ;;
            2)
                echo -e "${YELLOW}Will prompt for all new credentials.${NC}"
                # Clear all credentials
                export CLOUDFLARE_API_TOKEN=""
                export GITHUB_TOKEN=""
                export GITHUB_USERNAME=""
                export KOMODO_BASE_URL=""
                export KOMODO_API_KEY=""
                export KOMODO_API_SECRET=""
                return 1  # Don't use saved
                ;;
            *)
                echo -e "${RED}Cancelled.${NC}"
                exit 0
                ;;
        esac
    else
        # Complete credentials
        echo -e "${GREEN}All required credentials are saved.${NC}"
        read -p "Do you want to use the saved credentials? (Y/n): " use_saved
        if [[ ! $use_saved =~ ^[Nn]$ ]]; then
            return 0  # Use saved credentials
        else
            # Clear saved credentials to prompt for new ones
            export CLOUDFLARE_API_TOKEN=""
            export GITHUB_TOKEN=""
            export GITHUB_USERNAME=""
            export KOMODO_BASE_URL=""
            export KOMODO_API_KEY=""
            export KOMODO_API_SECRET=""
            return 1  # Don't use saved, prompt for new
        fi
    fi
}

# Store a credential and immediately save to encrypted file
store_credential() {
    local key="$1"
    local value="$2"
    local temp_creds_file="config/api-credentials.tmp"
    local encrypted_file="config/api-credentials.enc"
    local backup_file="config/api-credentials.enc.backup"
    
    mkdir -p config
    
    if [ -z "$PIN" ]; then
        echo "Error: PIN not set, cannot store credential" >&2
        return 1
    fi
    
    if [ -z "$key" ] || [ -z "$value" ]; then
        echo "Error: Key and value required" >&2
        return 1
    fi
    
    # Backup existing encrypted file if it exists (for recovery)
    if [ -f "$encrypted_file" ]; then
        cp "$encrypted_file" "$backup_file" 2>/dev/null || true
    fi
    
    # Merge with existing credentials
    local merged_file="config/api-credentials.merged.tmp"
    
    if [ -f "$encrypted_file" ]; then
        # Decrypt existing file to merge
        local existing_temp="config/api-credentials.existing.tmp"
        if decrypt_credentials "$encrypted_file" "$existing_temp" "$PIN"; then
            # Start with existing credentials, removing the key we're updating
            grep -v "^${key}=" "$existing_temp" > "$merged_file" 2>/dev/null || touch "$merged_file"
            rm -f "$existing_temp"
        else
            echo "Warning: Could not decrypt existing credentials for merge" >&2
            touch "$merged_file"
        fi
    else
        touch "$merged_file"
    fi
    
    # Add the new/updated credential
    echo "${key}=\"${value}\"" >> "$merged_file"
    
    # Create final credentials file with header
    local final_creds_file="config/api-credentials"
    cat > "$final_creds_file" <<EOF
# API Credentials (auto-generated)
# Keep this file secure and do not commit it to version control
# Last updated: $(date)

EOF
    cat "$merged_file" >> "$final_creds_file"
    
    # Encrypt and save atomically
    local temp_encrypted="config/api-credentials.enc.new"
    if encrypt_credentials "$final_creds_file" "$temp_encrypted" "$PIN"; then
        # Atomic move
        mv "$temp_encrypted" "$encrypted_file"
        rm -f "$merged_file" "$backup_file"
        echo -e "${GREEN}✓ Saved: ${key}${NC}" >&2
        return 0
    else
        echo "Error: Failed to save credential" >&2
        # Restore backup if it exists
        if [ -f "$backup_file" ]; then
            mv "$backup_file" "$encrypted_file"
            echo "Restored previous credentials from backup" >&2
        fi
        rm -f "$merged_file" "$temp_encrypted"
        return 1
    fi
}

# Encrypt and save all collected credentials
save_encrypted_credentials() {
    local temp_creds_file="config/api-credentials.tmp"
    local encrypted_file="config/api-credentials.enc"
    local pin="$1"
    
    if [ ! -f "$temp_creds_file" ]; then
        return 1
    fi
    
    # Add header comment
    local final_creds_file="config/api-credentials"
    cat > "$final_creds_file" <<EOF
# API Credentials (auto-generated)
# Keep this file secure and do not commit it to version control

EOF
    cat "$temp_creds_file" >> "$final_creds_file"
    
    # Encrypt it
    if encrypt_credentials "$final_creds_file" "$encrypted_file" "$pin"; then
        rm -f "$temp_creds_file"
        return 0
    else
        return 1
    fi
}

# Prompt for PIN (first thing in automated mode)
prompt_for_pin() {
    local encrypted_file="config/api-credentials.enc"
    
    # If encrypted file exists, we need PIN to unlock
    if [ -f "$encrypted_file" ]; then
        echo ""
        echo -e "${BLUE}Enter PIN to unlock encrypted credentials:${NC}"
        read -s -p "PIN: " PIN
        echo ""
        export PIN
        return 0
    else
        # No encrypted file, need to create PIN for new credentials
        echo ""
        echo -e "${BLUE}Create a PIN to encrypt and store your API credentials:${NC}"
        echo -e "${YELLOW}(This PIN will be required to unlock credentials in the future)${NC}"
        
        while true; do
            read -s -p "Enter PIN: " pin1
            echo ""
            
            if [ -z "$pin1" ]; then
                echo -e "${RED}Error: PIN cannot be empty${NC}"
                continue
            fi
            
            if [ ${#pin1} -lt 4 ]; then
                echo -e "${RED}Error: PIN must be at least 4 characters${NC}"
                continue
            fi
            
            read -s -p "Confirm PIN: " pin2
            echo ""
            
            if [ "$pin1" != "$pin2" ]; then
                echo -e "${RED}Error: PINs do not match. Please try again.${NC}"
                continue
            fi
            
            export PIN="$pin1"
            return 0
        done
    fi
}

# Prompt for API credentials if not set
prompt_api_credentials() {
    if [ "$AUTOMATED_MODE" = true ]; then
        # Ask for PIN first unless credentials already unlocked
        if [ "$CREDENTIALS_UNLOCKED" != true ]; then
            if [ -z "$PIN" ] && ! prompt_for_pin; then
                echo -e "${RED}Failed to set up PIN. Cannot proceed with credential storage.${NC}"
                return 1
            fi
        fi

        # If we have a PIN and encrypted file exists, try to unlock (once)
        if [ -n "$PIN" ] && [ -f "config/api-credentials.enc" ] && [ "$CREDENTIALS_UNLOCKED" != true ]; then
            echo -e "${BLUE}Unlocking saved credentials...${NC}"
            if unlock_credentials_with_pin "$PIN"; then
                echo -e "${GREEN}✓ Credentials unlocked${NC}"

                # Ask if user wants to use saved credentials (shows status)
                if ask_use_saved_credentials; then
                    # User chose to keep/use saved credentials
                    # Don't return yet - we'll continue to prompt for missing ones
                    echo ""
                else
                    # User chose to replace all or cancelled
                    # If they cancelled, ask_use_saved_credentials will exit
                    # Otherwise credentials are cleared, continue to prompt for all
                    echo ""
                fi
            else
                echo -e "${RED}Failed to unlock with PIN. Will prompt for new credentials.${NC}"
                # Clear any partial credentials that might have loaded
                export CLOUDFLARE_API_TOKEN=""
                export GITHUB_TOKEN=""
                export GITHUB_USERNAME=""
                export KOMODO_BASE_URL=""
                export KOMODO_API_KEY=""
                export KOMODO_API_SECRET=""
            fi
        elif [ "$CREDENTIALS_UNLOCKED" = true ]; then
            # Credentials already unlocked via load_api_credentials()
            if ask_use_saved_credentials; then
                echo ""
            else
                echo ""
            fi
        fi
        
        print_section "API Credentials Configuration"
        
        # Cloudflare API Token
        if [ -z "$CLOUDFLARE_API_TOKEN" ]; then
            while true; do
                echo -e "${BLUE}Enter your Cloudflare API Token:${NC}"
                echo -e "${YELLOW}(Required permissions: Zone:Read, Zone:DNS:Edit, Account:Cloudflare Tunnel:Edit)${NC}"
                read -p "Cloudflare API Token: " CLOUDFLARE_API_TOKEN
                
                if [ -z "$CLOUDFLARE_API_TOKEN" ]; then
                    echo -e "${RED}Error: Token cannot be empty${NC}"
                    continue
                fi
                
                export CLOUDFLARE_API_TOKEN
                echo -e "${BLUE}Validating Cloudflare API token...${NC}"
                
                # Initialize and validate
                cloudflare_init "$CLOUDFLARE_API_TOKEN"
                account_id=$(cloudflare_get_account_id)
                if [ -n "$account_id" ]; then
                    if cloudflare_validate_token "$account_id"; then
                        echo -e "${GREEN}✓ Cloudflare API token is valid${NC}"
                        # Store the validated credential
                        store_credential "CLOUDFLARE_API_TOKEN" "$CLOUDFLARE_API_TOKEN"
                        break
                    else
                        echo -e "${RED}✗ Cloudflare API token is invalid${NC}"
                        read -p "Would you like to try again? (Y/n): " retry
                        if [[ $retry =~ ^[Nn]$ ]]; then
                            echo -e "${YELLOW}Skipping Cloudflare automation...${NC}"
                            CLOUDFLARE_API_TOKEN=""
                            export CLOUDFLARE_API_TOKEN
                            break
                        fi
                        CLOUDFLARE_API_TOKEN=""
                        continue
                    fi
                else
                    # Fallback to user endpoint
                    if cloudflare_validate_token; then
                        echo -e "${GREEN}✓ Cloudflare API token is valid${NC}"
                        break
                    else
                        echo -e "${RED}✗ Cloudflare API token is invalid${NC}"
                        read -p "Would you like to try again? (Y/n): " retry
                        if [[ $retry =~ ^[Nn]$ ]]; then
                            echo -e "${YELLOW}Skipping Cloudflare automation...${NC}"
                            CLOUDFLARE_API_TOKEN=""
                            export CLOUDFLARE_API_TOKEN
                            break
                        fi
                        CLOUDFLARE_API_TOKEN=""
                        continue
                    fi
                fi
            done
        else
            # Validate existing token
            echo -e "${BLUE}Validating existing Cloudflare API token...${NC}"
            cloudflare_init "$CLOUDFLARE_API_TOKEN"
            account_id=$(cloudflare_get_account_id)
            if [ -n "$account_id" ]; then
                if ! cloudflare_validate_token "$account_id"; then
                    echo -e "${RED}✗ Existing Cloudflare API token is invalid${NC}"
                    CLOUDFLARE_API_TOKEN=""
                    export CLOUDFLARE_API_TOKEN
                    prompt_api_credentials
                    return
                fi
            fi
        fi
        
        # GitHub Username (prompt first if needed, as it's required for token validation)
        if [ -z "$GITHUB_USERNAME" ] && [ -z "$GITHUB_USER" ]; then
            echo ""
            echo -e "${BLUE}Enter your GitHub username:${NC}"
            read -p "GitHub Username: " GITHUB_USERNAME
            export GITHUB_USERNAME
            # Store username immediately (it's not sensitive)
            if [ -n "$GITHUB_USERNAME" ]; then
                store_credential "GITHUB_USERNAME" "$GITHUB_USERNAME"
            fi
        elif [ -n "$GITHUB_USER" ] && [ -z "$GITHUB_USERNAME" ]; then
            export GITHUB_USERNAME="$GITHUB_USER"
            store_credential "GITHUB_USERNAME" "$GITHUB_USERNAME"
        fi
        
        # GitHub Token
        if [ -z "$GITHUB_TOKEN" ]; then
            while true; do
                echo ""
                echo -e "${BLUE}Enter your GitHub Personal Access Token:${NC}"
                echo -e "${YELLOW}(Required scopes: write:packages, read:packages)${NC}"
                read -p "GitHub Token: " GITHUB_TOKEN
                
                if [ -z "$GITHUB_TOKEN" ]; then
                    echo -e "${RED}Error: Token cannot be empty${NC}"
                    continue
                fi
                
                export GITHUB_TOKEN
                echo -e "${BLUE}Validating GitHub token...${NC}"
                
                # Initialize GitHub API with username (required)
                if [ -z "$GITHUB_USERNAME" ]; then
                    echo -e "${RED}Error: GitHub username is required for validation${NC}"
                    GITHUB_TOKEN=""
                    continue
                fi
                
                github_init "$GITHUB_TOKEN" "$GITHUB_USERNAME"
                
                if github_validate_token; then
                    echo -e "${GREEN}✓ GitHub token is valid${NC}"
                    # Store the validated credentials
                    store_credential "GITHUB_TOKEN" "$GITHUB_TOKEN"
                    if [ -n "$GITHUB_USERNAME" ]; then
                        store_credential "GITHUB_USERNAME" "$GITHUB_USERNAME"
                    fi
                    break
                else
                    echo -e "${RED}✗ GitHub token is invalid${NC}"
                    read -p "Would you like to try again? (Y/n): " retry
                    if [[ $retry =~ ^[Nn]$ ]]; then
                        echo -e "${YELLOW}Skipping GitHub automation...${NC}"
                        GITHUB_TOKEN=""
                        export GITHUB_TOKEN
                        break
                    fi
                    GITHUB_TOKEN=""
                    continue
                fi
            done
        else
            # Validate existing token
            if [ -z "$GITHUB_USERNAME" ]; then
                echo -e "${RED}Error: GitHub username is required but not set${NC}"
                echo -e "${YELLOW}Please set GITHUB_USERNAME or GITHUB_USER environment variable${NC}"
            else
                echo -e "${BLUE}Validating existing GitHub token...${NC}"
                github_init "$GITHUB_TOKEN" "$GITHUB_USERNAME"
                if ! github_validate_token; then
                    echo -e "${RED}✗ Existing GitHub token is invalid${NC}"
                    GITHUB_TOKEN=""
                    export GITHUB_TOKEN
                    prompt_api_credentials
                    return
                fi
            fi
        fi
        
        # Komodo credentials (optional)
        echo ""
        read -p "Do you want to configure Komodo deployment? (y/N): " configure_komodo
        if [[ $configure_komodo =~ ^[Yy]$ ]]; then
            # Komodo Base URL
            if [ -z "$KOMODO_BASE_URL" ]; then
                while true; do
                    echo -e "${BLUE}Enter your Komodo base URL (e.g., https://komodo.example.com):${NC}"
                    read -p "Komodo Base URL: " KOMODO_BASE_URL
                    
                    if [ -z "$KOMODO_BASE_URL" ]; then
                        echo -e "${RED}Error: Base URL cannot be empty${NC}"
                        continue
                    fi
                    
                    # Remove trailing slash if present
                    KOMODO_BASE_URL="${KOMODO_BASE_URL%/}"
                    export KOMODO_BASE_URL
                    break
                done
            fi
            
            # Komodo API Key
            if [ -z "$KOMODO_API_KEY" ]; then
                while true; do
                    echo -e "${BLUE}Enter your Komodo API Key:${NC}"
                    read -p "Komodo API Key: " KOMODO_API_KEY
                    
                    if [ -z "$KOMODO_API_KEY" ]; then
                        echo -e "${RED}Error: API Key cannot be empty${NC}"
                        continue
                    fi
                    
                    export KOMODO_API_KEY
                    
                    # If we have all three, validate
                    if [ -n "$KOMODO_BASE_URL" ] && [ -n "$KOMODO_API_KEY" ] && [ -n "$KOMODO_API_SECRET" ]; then
                        echo -e "${BLUE}Validating Komodo credentials...${NC}"
                        komodo_init "$KOMODO_BASE_URL" "$KOMODO_API_KEY" "$KOMODO_API_SECRET"
                        if komodo_validate_credentials; then
                            echo -e "${GREEN}✓ Komodo credentials are valid${NC}"
                            # Store the validated credentials
                            store_credential "KOMODO_BASE_URL" "$KOMODO_BASE_URL"
                            store_credential "KOMODO_API_KEY" "$KOMODO_API_KEY"
                            store_credential "KOMODO_API_SECRET" "$KOMODO_API_SECRET"
                            break
                        else
                            echo -e "${RED}✗ Komodo credentials are invalid${NC}"
                            read -p "Would you like to try again? (Y/n): " retry
                            if [[ $retry =~ ^[Nn]$ ]]; then
                                echo -e "${YELLOW}Skipping Komodo automation...${NC}"
                                KOMODO_API_KEY=""
                                export KOMODO_API_KEY
                                break
                            fi
                            KOMODO_API_KEY=""
                            continue
                        fi
                    fi
                    break
                done
            fi
            
            # Komodo API Secret
            if [ -z "$KOMODO_API_SECRET" ]; then
                while true; do
                    echo -e "${BLUE}Enter your Komodo API Secret:${NC}"
                    read -p "Komodo API Secret: " KOMODO_API_SECRET
                    
                    if [ -z "$KOMODO_API_SECRET" ]; then
                        echo -e "${RED}Error: API Secret cannot be empty${NC}"
                        continue
                    fi
                    
                    export KOMODO_API_SECRET
                    
                    # Validate all three together
                    if [ -n "$KOMODO_BASE_URL" ] && [ -n "$KOMODO_API_KEY" ] && [ -n "$KOMODO_API_SECRET" ]; then
                        echo -e "${BLUE}Validating Komodo credentials...${NC}"
                        komodo_init "$KOMODO_BASE_URL" "$KOMODO_API_KEY" "$KOMODO_API_SECRET"
                        if komodo_validate_credentials; then
                            echo -e "${GREEN}✓ Komodo credentials are valid${NC}"
                            # Store the validated credentials
                            store_credential "KOMODO_BASE_URL" "$KOMODO_BASE_URL"
                            store_credential "KOMODO_API_KEY" "$KOMODO_API_KEY"
                            store_credential "KOMODO_API_SECRET" "$KOMODO_API_SECRET"
                            break
                        else
                            echo -e "${RED}✗ Komodo credentials are invalid${NC}"
                            read -p "Would you like to try again? (Y/n): " retry
                            if [[ $retry =~ ^[Nn]$ ]]; then
                                echo -e "${YELLOW}Skipping Komodo automation...${NC}"
                                KOMODO_API_SECRET=""
                                export KOMODO_API_SECRET
                                break
                            fi
                            KOMODO_API_SECRET=""
                            continue
                        fi
                    fi
                    break
                done
            else
                # Validate existing credentials
                if [ -n "$KOMODO_BASE_URL" ] && [ -n "$KOMODO_API_KEY" ] && [ -n "$KOMODO_API_SECRET" ]; then
                    echo -e "${BLUE}Validating existing Komodo credentials...${NC}"
                    komodo_init "$KOMODO_BASE_URL" "$KOMODO_API_KEY" "$KOMODO_API_SECRET"
                    if ! komodo_validate_credentials; then
                        echo -e "${RED}✗ Existing Komodo credentials are invalid${NC}"
                        KOMODO_BASE_URL=""
                        KOMODO_API_KEY=""
                        KOMODO_API_SECRET=""
                        export KOMODO_BASE_URL KOMODO_API_KEY KOMODO_API_SECRET
                        prompt_api_credentials
                        return
                    fi
                fi
            fi
        fi
        
        # Show final summary and cleanup
        echo ""
        echo -e "${GREEN}=== Credentials Configuration Complete ===${NC}"
        check_saved_credentials_status
        cleanup_temp_files
        echo ""
    fi
}

# Get tunnel token from user
# Usage: get_tunnel_token <tunnel_id> <account_id>
# Returns: Sets TUNNEL_TOKEN variable, returns 0 on success, 1 on failure
get_tunnel_token() {
    local tunnel_id="$1"
    local account_id="$2"
    
    echo "" >&2
    echo -e "${BLUE}=== Cloudflare Tunnel Token Required ===${NC}" >&2
    echo "" >&2
    echo -e "${YELLOW}Cloudflare now uses tokens instead of JSON credential files.${NC}" >&2
    echo "" >&2
    echo -e "${BLUE}Please get your tunnel token:${NC}" >&2
    echo "" >&2
    echo "1. Open your browser and go to: https://dash.cloudflare.com/" >&2
    echo "2. Navigate to: Zero Trust → Networks → Tunnels" >&2
    echo "3. Find your tunnel and click on it" >&2
    echo "4. Look for the Docker command that starts with:" >&2
    echo -e "   ${GREEN}docker run cloudflare/cloudflared:latest tunnel...${NC}" >&2
    echo "5. Copy ONLY the token (the long string after '--token ')" >&2
    echo "" >&2
    echo -e "${YELLOW}Example token format:${NC}" >&2
    echo "   eyJhIjoiYWJjZGVmIiwidCI6IjEyMzQ1Njc4IiwicyI6Inh5ejEyMyJ9" >&2
    echo "" >&2
    
    # Try to get token from API first
    echo -e "${BLUE}Attempting to retrieve token via API...${NC}" >&2
    set +e
    local api_token=$(cloudflare_get_tunnel_token "$tunnel_id" "$account_id" 2>/dev/null)
    set -e
    
    if [ -n "$api_token" ]; then
        echo -e "${GREEN}✓ Token retrieved via API${NC}" >&2
        TUNNEL_TOKEN="$api_token"
        return 0
    fi
    
    echo -e "${YELLOW}Could not retrieve token via API. Please paste it manually.${NC}" >&2
    echo "" >&2
    read -p "Paste your tunnel token here: " TUNNEL_TOKEN </dev/tty >&2
    
    if [ -z "$TUNNEL_TOKEN" ]; then
        echo -e "${RED}No token provided${NC}" >&2
        return 1
    fi
    
    # Basic validation - tokens are base64 encoded and may contain = padding
    if [[ ! "$TUNNEL_TOKEN" =~ ^[A-Za-z0-9_=-]+$ ]]; then
        echo -e "${RED}Invalid token format${NC}" >&2
        return 1
    fi
    
    echo -e "${GREEN}✓ Token received${NC}" >&2
    return 0
}

# Handle tunnel name conflict
# Usage: handle_tunnel_conflict <tunnel_name> <account_id>
# Returns: tunnel_id on success, empty string on failure/cancellation
handle_tunnel_conflict() {
    local tunnel_name="$1"
    local account_id="$2"
    
    # Output to stderr so it's not captured by command substitution
    echo "" >&2
    echo -e "${YELLOW}⚠ A tunnel with the name '${tunnel_name}' already exists.${NC}" >&2
    echo "" >&2
    echo "What would you like to do?" >&2
    echo "1) Use the existing tunnel" >&2
    echo "2) Delete existing tunnel and create a new one" >&2
    echo "3) Choose a different name" >&2
    echo "4) Cancel and set up manually" >&2
    echo "" >&2
    
    while true; do
        read -p "Select option (1-4): " choice </dev/tty >&2
        
        case "$choice" in
            1)
                # Use existing tunnel
                echo "" >&2
                echo -e "${BLUE}Retrieving existing tunnel...${NC}" >&2
                local existing_id=$(cloudflare_get_tunnel_by_name "$tunnel_name" "$account_id")
                if [ -n "$existing_id" ]; then
                    echo -e "${GREEN}✓ Using existing tunnel: ${existing_id}${NC}" >&2
                    echo "$existing_id"
                    return 0
                else
                    echo -e "${RED}Error: Could not retrieve existing tunnel${NC}" >&2
                    return 1
                fi
                ;;
            2)
                # Delete and recreate
                echo "" >&2
                echo -e "${YELLOW}Attempting to delete existing tunnel...${NC}" >&2
                local existing_id=$(cloudflare_get_tunnel_by_name "$tunnel_name" "$account_id")
                if [ -z "$existing_id" ]; then
                    echo -e "${RED}Error: Could not find existing tunnel to delete${NC}" >&2
                    return 1
                fi
                
                echo -e "${BLUE}Found tunnel: ${existing_id}${NC}" >&2
                read -p "Are you sure you want to delete this tunnel? (y/N): " confirm </dev/tty >&2
                if [[ ! $confirm =~ ^[Yy]$ ]]; then
                    echo -e "${YELLOW}Delete cancelled${NC}" >&2
                    return 1
                fi
                
                if cloudflare_delete_tunnel "$existing_id" "$account_id"; then
                    echo -e "${GREEN}✓ Tunnel deleted${NC}" >&2
                    echo "" >&2
                    echo -e "${BLUE}Creating new tunnel...${NC}" >&2
                    local new_tunnel_id=$(cloudflare_create_tunnel "$tunnel_name" "$account_id")
                    local create_status=$?
                    if [ -n "$new_tunnel_id" ] && [ $create_status -eq 0 ]; then
                        echo -e "${GREEN}✓ New tunnel created: ${new_tunnel_id}${NC}" >&2
                        echo "$new_tunnel_id"
                        return 0
                    else
                        echo -e "${RED}Error: Could not create new tunnel${NC}" >&2
                        return 1
                    fi
                else
                    echo -e "${RED}Error: Could not delete existing tunnel${NC}" >&2
                    echo -e "${YELLOW}The tunnel may be in use or require manual deletion from the dashboard${NC}" >&2
                    return 1
                fi
                ;;
            3)
                # Choose different name
                echo "" >&2
                while true; do
                    read -p "Enter a new tunnel name: " new_name </dev/tty >&2
                    if [ -z "$new_name" ]; then
                        echo -e "${RED}Error: Name cannot be empty${NC}" >&2
                        continue
                    fi
                    
                    echo -e "${BLUE}Creating tunnel: ${new_name}...${NC}" >&2
                    local new_tunnel_id=$(cloudflare_create_tunnel "$new_name" "$account_id" 2>&1)
                    local create_status=$?
                    
                    # Check if this name also exists
                    if echo "$new_tunnel_id" | grep -q "TUNNEL_EXISTS"; then
                        echo -e "${RED}That name is also taken. Please try another name.${NC}" >&2
                        continue
                    fi
                    
                    if [ -n "$new_tunnel_id" ] && [ $create_status -eq 0 -o $create_status -eq 2 ]; then
                        echo -e "${GREEN}✓ Tunnel created: ${new_tunnel_id}${NC}" >&2
                        echo "$new_tunnel_id"
                        return 0
                    else
                        echo -e "${RED}Error: Could not create tunnel${NC}" >&2
                        read -p "Try another name? (Y/n): " retry </dev/tty >&2
                        if [[ $retry =~ ^[Nn]$ ]]; then
                            return 1
                        fi
                    fi
                done
                ;;
            4)
                # Cancel
                echo -e "${YELLOW}Cancelled. Will fall back to manual setup.${NC}" >&2
                return 1
                ;;
            *)
                echo -e "${RED}Invalid option. Please select 1-4.${NC}" >&2
                ;;
        esac
    done
}

# Validate API credentials
validate_api_credentials() {
    local errors=0
    
    if [ "$AUTOMATED_MODE" = true ]; then
        # Validate Cloudflare
        if [ -n "$CLOUDFLARE_API_TOKEN" ]; then
            echo -e "${BLUE}Validating Cloudflare API token...${NC}"
            # Initialize Cloudflare API first
            cloudflare_init "$CLOUDFLARE_API_TOKEN"
            # Get account ID to use account-specific validation endpoint
            account_id=$(cloudflare_get_account_id)
            if [ -n "$account_id" ]; then
                if cloudflare_validate_token "$account_id"; then
                    echo -e "${GREEN}✓ Cloudflare API token is valid${NC}"
                else
                    echo -e "${RED}✗ Cloudflare API token is invalid${NC}"
                    errors=$((errors + 1))
                fi
            else
                # Fallback to user endpoint if we can't get account ID
                echo -e "${YELLOW}Warning: Could not get account ID, trying user endpoint...${NC}"
                if cloudflare_validate_token; then
                    echo -e "${GREEN}✓ Cloudflare API token is valid${NC}"
                else
                    echo -e "${RED}✗ Cloudflare API token is invalid${NC}"
                    errors=$((errors + 1))
                fi
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
    
    # Set automated mode based on flag
    # If --automated flag was explicitly provided, always use automation (no prompt)
    if [ "$automated_flag" = true ]; then
        AUTOMATED_MODE=true
    else
        # Only prompt if flag was not provided at all
        echo ""
        read -p "Do you want to use automated deployment (Cloudflare, GitHub, Komodo APIs)? (y/N): " use_automated
        if [[ $use_automated =~ ^[Yy]$ ]]; then
            AUTOMATED_MODE=true
        fi
    fi
    
    # Prompt for API credentials if in automated mode
    # Credentials are now validated as they're entered, so we don't need separate validation
    if [ "$AUTOMATED_MODE" = true ]; then
        prompt_api_credentials
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
    BUILD_IMAGE=false
    
    # In automated mode, check if image exists or offer to build
    if [ "$AUTOMATED_MODE" = true ] && [ -n "$GITHUB_TOKEN" ] && [ -n "$GITHUB_USERNAME" ]; then
        github_init "$GITHUB_TOKEN" "$GITHUB_USERNAME"
        echo ""
        echo -e "${BLUE}Checking if Docker image exists in registry...${NC}"
        if github_check_image_exists "wordpress-frankenphp" "latest"; then
            echo -e "${GREEN}✓ Docker image already exists in registry${NC}"
            read -p "Do you want to rebuild and push the image now? (Y/n): " rebuild_image
            if [[ ! $rebuild_image =~ ^[Nn]$ ]]; then
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
TUNNEL_TOKEN=
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

    # Prepare persistent WordPress paths for bind mounts
    mkdir -p wordpress/wp-content/uploads
    mkdir -p wordpress/wp-content/plugins
    mkdir -p wordpress/wp-content/themes
    
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
                
                # Capture both stdout and stderr, and the return code
                set +e  # Temporarily disable exit on error
                tunnel_create_output=$(cloudflare_create_tunnel "$tunnel_name" "$account_id" 2>&1)
                tunnel_create_status=$?
                set -e  # Re-enable exit on error
                
                # Check result
                if [ $tunnel_create_status -eq 3 ] || echo "$tunnel_create_output" | grep -q "TUNNEL_EXISTS"; then
                    # Tunnel exists - show interactive menu
                    set +e  # Disable exit on error for interactive function
                    tunnel_id=$(handle_tunnel_conflict "$tunnel_name" "$account_id")
                    conflict_status=$?
                    set -e  # Re-enable exit on error
                    
                    if [ -z "$tunnel_id" ] || [ $conflict_status -ne 0 ]; then
                        echo -e "${YELLOW}Falling back to manual setup...${NC}"
                        AUTOMATED_MODE=false
                        tunnel_id=""
                    fi
                elif [ $tunnel_create_status -eq 0 ] && [ -n "$tunnel_create_output" ]; then
                    # Successfully created new tunnel
                    tunnel_id="$tunnel_create_output"
                    echo -e "${GREEN}✓ Tunnel created: ${tunnel_id}${NC}"
                else
                    # Error
                    echo -e "${RED}Error: Could not create Cloudflare tunnel${NC}"
                    if [ -n "$tunnel_create_output" ]; then
                        echo "$tunnel_create_output" >&2
                    fi
                    echo -e "${YELLOW}Falling back to manual setup...${NC}"
                    AUTOMATED_MODE=false
                    tunnel_id=""
                fi
                
                if [ -n "$tunnel_id" ]; then
                    # Get tunnel token
                    set +e  # Disable exit on error for token retrieval
                    get_tunnel_token "$tunnel_id" "$account_id"
                    token_status=$?
                    set -e  # Re-enable exit on error
                    
                    if [ $token_status -eq 0 ] && [ -n "$TUNNEL_TOKEN" ]; then
                        echo -e "${GREEN}✓ Tunnel token configured${NC}"
                        
                        # Store token securely in encrypted credentials if PIN is available
                        if [ -n "$PIN" ]; then
                            store_credential "TUNNEL_TOKEN" "$TUNNEL_TOKEN"
                        fi
                        
                        # Also store in .env file (safer method without sed)
                        if [ -f .env ]; then
                            # Remove old TUNNEL_TOKEN line if exists
                            grep -v "^TUNNEL_TOKEN=" .env > .env.tmp 2>/dev/null || true
                            mv .env.tmp .env
                        fi
                        # Append new token
                        echo "TUNNEL_TOKEN=${TUNNEL_TOKEN}" >> .env
                    else
                        echo -e "${YELLOW}Token setup cancelled. Falling back to manual setup...${NC}"
                        AUTOMATED_MODE=false
                        tunnel_id=""
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
        else
            # Get tunnel token
            set +e  # Disable exit on error for token retrieval
            get_tunnel_token "$tunnel_id" "unknown"
            token_status=$?
            set -e  # Re-enable exit on error
            
            if [ $token_status -eq 0 ] && [ -n "$TUNNEL_TOKEN" ]; then
                # Store token securely in encrypted credentials if PIN is available
                if [ -n "$PIN" ]; then
                    store_credential "TUNNEL_TOKEN" "$TUNNEL_TOKEN"
                fi
                
                # Also store in .env file (safer method without sed)
                if [ -f .env ]; then
                    # Remove old TUNNEL_TOKEN line if exists
                    grep -v "^TUNNEL_TOKEN=" .env > .env.tmp 2>/dev/null || true
                    mv .env.tmp .env
                fi
                # Append new token
                echo "TUNNEL_TOKEN=${TUNNEL_TOKEN}" >> .env
            else
                echo -e "${YELLOW}You'll need to add the tunnel token manually to the .env file later${NC}"
                echo -e "${YELLOW}Add this line: TUNNEL_TOKEN=your_token_here${NC}"
            fi
        fi
    fi
    
    # Update .env with tunnel ID if we have it
    if [ -n "$tunnel_id" ]; then
        sed -i "s/TUNNEL_ID=$/TUNNEL_ID=${tunnel_id}/" .env
        echo -e "${GREEN}✓ Tunnel ID saved to .env${NC}"
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
                dns_name="${domain}"
                dns_target="${tunnel_id}.cfargotunnel.com"
                echo "Creating CNAME record: ${dns_name} -> ${dns_target}..."
                
                # Capture both output and errors without exiting on non-zero
                set +e
                dns_output=$(cloudflare_create_dns_record "$zone_id" "$dns_name" "$dns_target" "true" 2>&1)
                dns_status=$?
                set -e
                
                if [ $dns_status -eq 0 ]; then
                    if echo "$dns_output" | grep -q "already exists"; then
                        echo -e "${GREEN}✓ DNS record already exists${NC}"
                    else
                        echo -e "${GREEN}✓ DNS record created successfully${NC}"
                    fi
                else
                    echo -e "${YELLOW}Warning: Could not create DNS record automatically${NC}"
                    
                    # Show specific error if available
                    if echo "$dns_output" | grep -qi "authentication\|auth"; then
                        echo -e "${RED}Authentication Error: Your API token may not have DNS edit permissions${NC}"
                        echo -e "${YELLOW}Required permission: Zone → DNS → Edit${NC}"
                    elif echo "$dns_output" | grep -qi "not found"; then
                        echo -e "${RED}Zone not found: Please verify the domain is in your Cloudflare account${NC}"
                    elif [ -n "$dns_output" ]; then
                        echo -e "${RED}Error: ${dns_output}${NC}"
                    fi
                    
                    echo ""
                    echo -e "${BLUE}Please create the DNS record manually:${NC}"
                    echo "1. Go to https://dash.cloudflare.com/"
                    echo "2. Select your domain: ${domain}"
                    echo "3. Go to DNS → Records"
                    echo "4. Add a CNAME record:"
                    echo "   Name: @ (or root)"
                    echo "   Target: ${dns_target}"
                    echo "   Proxy status: Proxied (orange cloud)"
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
                if [ "$AUTOMATED_MODE" = true ]; then
                    echo -e "${RED}Aborting automated deployment due to image build failure.${NC}"
                    exit 1
                fi
            fi
        fi
    fi

    # Deploy to Komodo automatically (if configured)
    if [ "$AUTOMATED_MODE" = true ] && [ -n "$KOMODO_BASE_URL" ] && [ -n "$KOMODO_API_KEY" ] && [ -n "$KOMODO_API_SECRET" ]; then
        print_section "Komodo Deployment"
        
        read -p "Komodo server name (leave blank for default): " komodo_server
        
        if [ "$DRY_RUN" = true ]; then
            echo -e "${YELLOW}[DRY RUN] Would create/update and deploy stack in Komodo${NC}"
        else
            if perform_komodo_deploy "${site_name}" "$komodo_server"; then
                echo -e "${GREEN}✓ Komodo stack deployed successfully${NC}"
            else
                echo -e "${RED}Error: Failed to deploy stack to Komodo${NC}"
                exit 1
            fi
        fi
    fi
    
    # Clean up temp file if it exists (credentials should already be saved individually)
    if [ -f "config/api-credentials.tmp" ]; then
        # Check if there are any unsaved credentials in temp file
        local temp_creds_file="config/api-credentials.tmp"
        local encrypted_file="config/api-credentials.enc"
        
        if [ -f "$encrypted_file" ] && [ -n "$PIN" ]; then
            # Merge any remaining credentials from temp file
            local final_creds_file="config/api-credentials"
            if decrypt_credentials "$encrypted_file" "$final_creds_file" "$PIN"; then
                # Merge temp file into decrypted file
                while IFS='=' read -r key value; do
                    if [[ "$key" =~ ^[A-Z_]+$ ]] && [ -n "$value" ]; then
                        # Remove quotes from value
                        value=$(echo "$value" | sed 's/^"//;s/"$//')
                        # Update or add this credential
                        grep -v "^${key}=" "$final_creds_file" > "${final_creds_file}.new" 2>/dev/null || true
                        echo "${key}=\"${value}\"" >> "${final_creds_file}.new"
                        mv "${final_creds_file}.new" "$final_creds_file"
                    fi
                done < "$temp_creds_file"
                
                # Re-encrypt
                encrypt_credentials "$final_creds_file" "$encrypted_file" "$PIN"
            fi
        fi
        
        # Clean up temp file
        rm -f "$temp_creds_file"
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

    # Load API credentials (for optional Komodo deployment)
    load_api_credentials
    if [ -f ".env" ]; then
        set -a
        source .env 2>/dev/null || true
        set +a
    fi
    
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

# Perform Komodo deployment (shared by init and deploy)
# Usage: perform_komodo_deploy <stack_name> [server_name]
perform_komodo_deploy() {
    local stack_name="$1"
    local server_name="${2:-}"
    local compose_path="docker-compose.yml"
    local komodo_compose="config/komodo-compose.yml"
    
    if [ -z "$stack_name" ]; then
        echo -e "${RED}Error: Stack name is required${NC}"
        return 1
    fi
    
    # Initialize Komodo API
    if ! komodo_init "$KOMODO_BASE_URL" "$KOMODO_API_KEY" "$KOMODO_API_SECRET"; then
        echo -e "${RED}Error: Failed to initialize Komodo API${NC}"
        return 1
    fi
    
    # Validate credentials
    if ! komodo_validate_credentials; then
        echo -e "${RED}Error: Invalid Komodo credentials${NC}"
        return 1
    fi

    # Prefer a freshly rendered compose file for Komodo to avoid YAML parsing issues
    if [ -f ".env" ]; then
        set -a
        source .env 2>/dev/null || true
        set +a
    fi

    if [ -f "docker-compose.yml.template" ] && [ -f ".env" ]; then
        if command -v envsubst &> /dev/null; then
            mkdir -p config
            envsubst < docker-compose.yml.template > "$komodo_compose"
            compose_path="$komodo_compose"
        else
            echo -e "${RED}Error: envsubst not found. Cannot render a fully hardcoded compose file for Komodo.${NC}"
            echo -e "${YELLOW}Install gettext (envsubst) and try again.${NC}"
            return 1
        fi
    fi

    if grep -q '\${' "$compose_path"; then
        echo -e "${RED}Error: Compose file still contains unresolved variables. Komodo requires a fully hardcoded file.${NC}"
        echo -e "${YELLOW}Ensure all variables are set in .env and try again.${NC}"
        return 1
    fi
    
    echo "Creating/updating stack: ${stack_name}"
    
    # Ensure stack exists (create or update)
    if komodo_ensure_stack "$stack_name" "$compose_path" "$server_name"; then
        echo -e "${GREEN}✓ Stack created/updated successfully${NC}"
        
        # Deploy the stack
        echo "Deploying stack..."
        if komodo_deploy_stack "$stack_name"; then
            echo -e "${GREEN}✓ Stack deployed successfully${NC}"
            return 0
        else
            echo -e "${RED}Error: Failed to deploy stack${NC}"
            return 1
        fi
    else
        echo -e "${RED}Error: Failed to create/update stack${NC}"
        return 1
    fi
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
    
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY RUN] Would create/update and deploy stack in Komodo${NC}"
        return 0
    fi

    if ! perform_komodo_deploy "$stack_name" "$server_name"; then
        echo -e "${RED}Error: Failed to deploy stack${NC}"
        exit 1
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
