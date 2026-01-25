#!/bin/bash

# Cloudflare API Integration Module
# Provides functions for interacting with Cloudflare API to create tunnels and DNS records

# Cloudflare API base URL
CLOUDFLARE_API_BASE="https://api.cloudflare.com/client/v4"

# Initialize Cloudflare API
# Usage: cloudflare_init <api_token>
cloudflare_init() {
    export CLOUDFLARE_API_TOKEN="$1"
    if [ -z "$CLOUDFLARE_API_TOKEN" ]; then
        echo "Error: Cloudflare API token is required" >&2
        return 1
    fi
}

# Get Cloudflare zone ID for a domain
# Usage: cloudflare_get_zone_id <domain>
# Returns: zone_id or empty string on error
cloudflare_get_zone_id() {
    local domain="$1"
    if [ -z "$domain" ] || [ -z "$CLOUDFLARE_API_TOKEN" ]; then
        echo "Error: Domain and API token are required" >&2
        echo "" >&2
        return 1
    fi
    
    local response=$(curl -s -w "\n%{http_code}" -X GET "${CLOUDFLARE_API_BASE}/zones?name=${domain}" \
        -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
        -H "Content-Type: application/json")
    
    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | sed '$d')
    
    if [ "$http_code" != "200" ]; then
        local error_msg=$(echo "$body" | grep -o '"message":"[^"]*"' | head -1 | cut -d'"' -f4)
        echo "Error getting zone ID (HTTP $http_code): ${error_msg:-Unknown error}" >&2
        echo "" >&2
        return 1
    fi
    
    local zone_id=$(echo "$body" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
    
    if [ -z "$zone_id" ]; then
        local error_msg=$(echo "$body" | grep -o '"message":"[^"]*"' | head -1 | cut -d'"' -f4)
        echo "Error getting zone ID: ${error_msg:-Zone not found}" >&2
        echo "" >&2
        return 1
    fi
    
    echo "$zone_id"
}

# Get Cloudflare account ID
# Usage: cloudflare_get_account_id
# Returns: account_id or empty string on error
cloudflare_get_account_id() {
    if [ -z "$CLOUDFLARE_API_TOKEN" ]; then
        echo "" >&2
        return 1
    fi
    
    local response=$(curl -s -X GET "${CLOUDFLARE_API_BASE}/accounts" \
        -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
        -H "Content-Type: application/json")
    
    local account_id=$(echo "$response" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
    
    if [ -z "$account_id" ]; then
        local error_msg=$(echo "$response" | grep -o '"message":"[^"]*"' | head -1 | cut -d'"' -f4)
        echo "Error getting account ID: ${error_msg:-Unknown error}" >&2
        echo "" >&2
        return 1
    fi
    
    echo "$account_id"
}

# Create Cloudflare Zero Trust tunnel
# Usage: cloudflare_create_tunnel <tunnel_name> <account_id>
# Returns: tunnel_id or empty string on error
cloudflare_create_tunnel() {
    local tunnel_name="$1"
    local account_id="$2"
    
    if [ -z "$tunnel_name" ] || [ -z "$account_id" ] || [ -z "$CLOUDFLARE_API_TOKEN" ]; then
        echo "" >&2
        return 1
    fi
    
    local response=$(curl -s -X POST "${CLOUDFLARE_API_BASE}/accounts/${account_id}/cfd_tunnel" \
        -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"${tunnel_name}\",\"config_src\":\"cloudflare\"}")
    
    local tunnel_id=$(echo "$response" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
    
    if [ -z "$tunnel_id" ]; then
        local error_msg=$(echo "$response" | grep -o '"message":"[^"]*"' | head -1 | cut -d'"' -f4)
        # Check if tunnel already exists (various error messages)
        if echo "$response" | grep -qiE "(already exists|already have a tunnel)"; then
            # Just report the conflict, don't auto-retrieve
            echo "TUNNEL_EXISTS:${tunnel_name}" >&2
            return 3  # Return code 3 indicates tunnel exists (conflict)
        fi
        echo "Error creating tunnel: ${error_msg:-Unknown error}" >&2
        echo "" >&2
        return 1
    fi
    
    echo "$tunnel_id"
    return 0
}

# List all tunnels for an account
# Usage: cloudflare_list_tunnels <account_id>
# Returns: JSON array of tunnels
cloudflare_list_tunnels() {
    local account_id="$1"
    
    if [ -z "$account_id" ] || [ -z "$CLOUDFLARE_API_TOKEN" ]; then
        return 1
    fi
    
    local response=$(curl -s -X GET "${CLOUDFLARE_API_BASE}/accounts/${account_id}/cfd_tunnel" \
        -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
        -H "Content-Type: application/json")
    
    echo "$response"
}

# Get tunnel by name
# Usage: cloudflare_get_tunnel_by_name <tunnel_name> <account_id>
# Returns: tunnel_id or empty string
cloudflare_get_tunnel_by_name() {
    local tunnel_name="$1"
    local account_id="$2"
    
    if [ -z "$tunnel_name" ] || [ -z "$account_id" ] || [ -z "$CLOUDFLARE_API_TOKEN" ]; then
        return 1
    fi
    
    local response=$(curl -s -X GET "${CLOUDFLARE_API_BASE}/accounts/${account_id}/cfd_tunnel?name=${tunnel_name}" \
        -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
        -H "Content-Type: application/json")
    
    local tunnel_id=$(echo "$response" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
    
    if [ -n "$tunnel_id" ]; then
        echo "$tunnel_id"
        return 0
    fi
    
    return 1
}

# Delete a tunnel
# Usage: cloudflare_delete_tunnel <tunnel_id> <account_id>
# Returns: 0 on success, 1 on error
cloudflare_delete_tunnel() {
    local tunnel_id="$1"
    local account_id="$2"
    
    if [ -z "$tunnel_id" ] || [ -z "$account_id" ] || [ -z "$CLOUDFLARE_API_TOKEN" ]; then
        return 1
    fi
    
    local response=$(curl -s -w "\n%{http_code}" -X DELETE "${CLOUDFLARE_API_BASE}/accounts/${account_id}/cfd_tunnel/${tunnel_id}" \
        -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
        -H "Content-Type: application/json")
    
    local http_code=$(echo "$response" | tail -n1)
    
    if [ "$http_code" = "200" ] || [ "$http_code" = "204" ]; then
        return 0
    else
        local error_msg=$(echo "$response" | sed '$d' | grep -o '"message":"[^"]*"' | head -1 | cut -d'"' -f4)
        echo "Error deleting tunnel: ${error_msg:-Unknown error (HTTP $http_code)}" >&2
        return 1
    fi
}

# Get tunnel token
# Usage: cloudflare_get_tunnel_token <tunnel_id> <account_id>
# Returns: tunnel token or empty string on error
cloudflare_get_tunnel_token() {
    local tunnel_id="$1"
    local account_id="$2"
    
    if [ -z "$tunnel_id" ] || [ -z "$account_id" ] || [ -z "$CLOUDFLARE_API_TOKEN" ]; then
        return 1
    fi
    
    local response=$(curl -s -X GET "${CLOUDFLARE_API_BASE}/accounts/${account_id}/cfd_tunnel/${tunnel_id}/token" \
        -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
        -H "Content-Type: application/json")
    
    local token=$(echo "$response" | grep -o '"result":"[^"]*"' | head -1 | cut -d'"' -f4)
    
    if [ -n "$token" ]; then
        echo "$token"
        return 0
    else
        # Try alternative response format
        token=$(echo "$response" | grep -o '"token":"[^"]*"' | head -1 | cut -d'"' -f4)
        if [ -n "$token" ]; then
            echo "$token"
            return 0
        fi
    fi
    
    return 1
}

# Get tunnel credentials JSON
# Usage: cloudflare_get_tunnel_credentials <tunnel_id> <account_id> <output_file>
# Returns: 0 on success, 1 on error
# Note: Cloudflare API may not return tunnel_secret directly. This function attempts to
# retrieve it, but credentials may need to be downloaded manually from the dashboard.
cloudflare_get_tunnel_credentials() {
    local tunnel_id="$1"
    local account_id="$2"
    local output_file="$3"
    
    if [ -z "$tunnel_id" ] || [ -z "$account_id" ] || [ -z "$output_file" ] || [ -z "$CLOUDFLARE_API_TOKEN" ]; then
        echo "Error: All parameters are required" >&2
        return 1
    fi
    
    local response=$(curl -s -w "\n%{http_code}" -X GET "${CLOUDFLARE_API_BASE}/accounts/${account_id}/cfd_tunnel/${tunnel_id}" \
        -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
        -H "Content-Type: application/json")
    
    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | sed '$d')
    
    if [ "$http_code" != "200" ]; then
        echo "Error: Failed to get tunnel details (HTTP $http_code)" >&2
        return 1
    fi
    
    # Try to extract tunnel_secret from response
    # Note: The API may not return the secret for security reasons
    local tunnel_secret=$(echo "$body" | grep -o '"secret":"[^"]*"' | head -1 | cut -d'"' -f4)
    
    if [ -z "$tunnel_secret" ]; then
        # Try alternative field name
        tunnel_secret=$(echo "$body" | grep -o '"tunnel_secret":"[^"]*"' | head -1 | cut -d'"' -f4)
    fi
    
    if [ -z "$tunnel_secret" ]; then
        echo "Warning: Could not retrieve tunnel secret from API. You may need to download credentials manually from Cloudflare dashboard." >&2
        echo "Tunnel ID: ${tunnel_id}" >&2
        echo "Please download the credentials JSON file and place it at: ${output_file}" >&2
        return 1
    fi
    
    # Create the credentials JSON file in the format expected by cloudflared
    cat > "$output_file" <<EOF
{
  "AccountTag": "${account_id}",
  "TunnelID": "${tunnel_id}",
  "TunnelSecret": "${tunnel_secret}"
}
EOF
    
    if [ $? -eq 0 ]; then
        return 0
    else
        return 1
    fi
}

# Create DNS CNAME record
# Usage: cloudflare_create_dns_record <zone_id> <name> <target> <proxied>
# Returns: record_id or empty string on error
cloudflare_create_dns_record() {
    local zone_id="$1"
    local name="$2"
    local target="$3"
    local proxied="${4:-true}"
    
    if [ -z "$zone_id" ] || [ -z "$name" ] || [ -z "$target" ] || [ -z "$CLOUDFLARE_API_TOKEN" ]; then
        echo "" >&2
        return 1
    fi
    
    # Convert boolean to lowercase
    local proxied_lower=$(echo "$proxied" | tr '[:upper:]' '[:lower:]')
    
    local response=$(curl -s -X POST "${CLOUDFLARE_API_BASE}/zones/${zone_id}/dns_records" \
        -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"type\":\"CNAME\",\"name\":\"${name}\",\"content\":\"${target}\",\"proxied\":${proxied_lower}}")
    
    local record_id=$(echo "$response" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
    
    if [ -z "$record_id" ]; then
        local error_msg=$(echo "$response" | grep -o '"message":"[^"]*"' | head -1 | cut -d'"' -f4)
        # Check if record already exists
        if echo "$response" | grep -q "already exists"; then
            echo "DNS record already exists" >&2
            # Try to get existing record ID
            local existing_response=$(curl -s -X GET "${CLOUDFLARE_API_BASE}/zones/${zone_id}/dns_records?type=CNAME&name=${name}" \
                -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
                -H "Content-Type: application/json")
            record_id=$(echo "$existing_response" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
            if [ -n "$record_id" ]; then
                echo "$record_id"
                return 0
            fi
        fi
        echo "Error creating DNS record: ${error_msg:-Unknown error}" >&2
        echo "" >&2
        return 1
    fi
    
    echo "$record_id"
}

# Validate Cloudflare API token
# Usage: cloudflare_validate_token [account_id]
# Returns: 0 if valid, 1 if invalid
cloudflare_validate_token() {
    local account_id="$1"
    
    if [ -z "$CLOUDFLARE_API_TOKEN" ]; then
        echo "Error: Cloudflare API token is not set" >&2
        return 1
    fi
    
    # Use account-specific endpoint if account_id is provided, otherwise use user endpoint
    local endpoint
    if [ -n "$account_id" ]; then
        endpoint="${CLOUDFLARE_API_BASE}/accounts/${account_id}/tokens/verify"
    else
        endpoint="${CLOUDFLARE_API_BASE}/user/tokens/verify"
    fi
    
    local response=$(curl -s -w "\n%{http_code}" -X GET "$endpoint" \
        -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
        -H "Content-Type: application/json")
    
    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | sed '$d')
    
    # Check for success in response
    if [ "$http_code" = "200" ] && echo "$body" | grep -q '"success":true'; then
        return 0
    else
        # Try to extract error message
        local error_msg=$(echo "$body" | grep -o '"message":"[^"]*"' | head -1 | cut -d'"' -f4)
        if [ -n "$error_msg" ]; then
            echo "Invalid Cloudflare API token: ${error_msg} (HTTP $http_code)" >&2
        else
            echo "Invalid Cloudflare API token (HTTP $http_code)" >&2
        fi
        return 1
    fi
}
