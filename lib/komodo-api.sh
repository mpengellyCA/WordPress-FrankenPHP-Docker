#!/bin/bash

# Komodo API Integration Module
# Provides functions for interacting with Komodo API to deploy Docker Compose stacks

# Initialize Komodo API
# Usage: komodo_init <base_url> <api_key> <api_secret>
komodo_init() {
    export KOMODO_BASE_URL="$1"
    export KOMODO_API_KEY="$2"
    export KOMODO_API_SECRET="$3"
    
    if [ -z "$KOMODO_BASE_URL" ] || [ -z "$KOMODO_API_KEY" ] || [ -z "$KOMODO_API_SECRET" ]; then
        echo "Error: Komodo base URL, API key, and API secret are required" >&2
        return 1
    fi
    
    # Remove trailing slash from base URL if present
    KOMODO_BASE_URL="${KOMODO_BASE_URL%/}"
}

# Make Komodo API request
# Usage: komodo_api_request <endpoint> <request_type> <params_json>
# Returns: API response JSON
komodo_api_request() {
    local endpoint="$1"
    local request_type="$2"
    local params_json="$3"
    
    if [ -z "$KOMODO_BASE_URL" ] || [ -z "$KOMODO_API_KEY" ] || [ -z "$KOMODO_API_SECRET" ]; then
        echo "Error: Komodo API not initialized" >&2
        return 1
    fi
    
    local url="${KOMODO_BASE_URL}${endpoint}"
    local body="{\"type\":\"${request_type}\",\"params\":${params_json}}"
    
    local response=$(curl -s -X POST "$url" \
        -H "Content-Type: application/json" \
        -H "X-Api-Key: ${KOMODO_API_KEY}" \
        -H "X-Api-Secret: ${KOMODO_API_SECRET}" \
        -d "$body")

    if [ "${KOMODO_DEBUG:-0}" = "1" ]; then
        mkdir -p config
        local type_safe
        type_safe=$(echo "$request_type" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')
        echo "$body" > config/komodo-last-request.json
        echo "$response" > config/komodo-last-response.json
        echo "$body" > "config/komodo-last-request-${type_safe}.json"
        echo "$response" > "config/komodo-last-response-${type_safe}.json"
    fi
    
    echo "$response"
}

# Validate Komodo API credentials
# Usage: komodo_validate_credentials
# Returns: 0 if valid, 1 if invalid
komodo_validate_credentials() {
    if [ -z "$KOMODO_BASE_URL" ] || [ -z "$KOMODO_API_KEY" ] || [ -z "$KOMODO_API_SECRET" ]; then
        echo "Error: Komodo credentials are not fully configured" >&2
        return 1
    fi
    
    # Try to list stacks as a validation check
    local response=$(komodo_api_request "/read" "ListStacks" "{}")
    
    if echo "$response" | grep -q '"error"'; then
        local error_msg=$(echo "$response" | grep -o '"error":"[^"]*"' | head -1 | cut -d'"' -f4)
        echo "Invalid Komodo credentials: ${error_msg:-Unknown error}" >&2
        return 1
    else
        return 0
    fi
}

# List all stacks
# Usage: komodo_list_stacks
# Returns: JSON array of stacks
komodo_list_stacks() {
    komodo_api_request "/read" "ListStacks" "{}"
}

# List all servers
# Usage: komodo_list_servers
# Returns: JSON array of servers
komodo_list_servers() {
    komodo_api_request "/read" "ListServers" "{}"
}

# Get server id by name
# Usage: komodo_get_server_id_by_name <server_name>
# Returns: server id or empty string
komodo_get_server_id_by_name() {
    local server_name="$1"
    
    if [ -z "$server_name" ]; then
        return 1
    fi
    
    local response=$(komodo_list_servers)
    local server_line
    server_line=$(echo "$response" | tr '{' '\n' | grep -iF -m1 "\"name\":\"${server_name}\"")
    local server_id
    server_id=$(echo "$server_line" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
    
    if [ -n "$server_id" ]; then
        echo "$server_id"
        return 0
    fi
    
    return 1
}

# Get default server id (first server)
# Usage: komodo_get_default_server_id
# Returns: server id or empty string
komodo_get_default_server_id() {
    local response=$(komodo_list_servers)
    local server_id
    server_id=$(echo "$response" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
    
    if [ -n "$server_id" ]; then
        echo "$server_id"
        return 0
    fi
    
    return 1
}

# Extract server_id from GetStack response
# Usage: komodo_get_stack_server_id <stack_name>
# Returns: server_id or empty string
komodo_get_stack_server_id() {
    local stack_name="$1"
    
    if [ -z "$stack_name" ]; then
        return 1
    fi
    
    local stack_response=$(komodo_get_stack "$stack_name")
    local server_id
    server_id=$(echo "$stack_response" | grep -o '"server_id":"[^"]*"' | head -1 | cut -d'"' -f4)
    
    if [ -n "$server_id" ]; then
        echo "$server_id"
        return 0
    fi
    
    return 1
}

# Get stack by name
# Usage: komodo_get_stack <stack_name>
# Returns: Stack JSON or error
komodo_get_stack() {
    local stack_name="$1"
    
    if [ -z "$stack_name" ]; then
        echo "Error: Stack name is required" >&2
        return 1
    fi
    
    komodo_api_request "/read" "GetStack" "{\"stack\":\"${stack_name}\"}"
}

# Get stack id by name (fallback)
# Usage: komodo_get_stack_id_by_name <stack_name>
# Returns: stack id or empty string
komodo_get_stack_id_by_name() {
    local stack_name="$1"
    
    if [ -z "$stack_name" ]; then
        return 1
    fi
    
    local response=$(komodo_list_stacks)
    # Split objects roughly and find matching name
    local stack_line
    stack_line=$(echo "$response" | tr '{' '\n' | grep -m1 "\"name\":\"${stack_name}\"")
    local stack_id
    stack_id=$(echo "$stack_line" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
    
    if [ -n "$stack_id" ]; then
        echo "$stack_id"
        return 0
    fi
    
    return 1
}

# Create a new stack in Komodo
# Usage: komodo_create_stack <stack_name> <compose_file_path> <server_name>
# Returns: 0 on success, 1 on error
komodo_create_stack() {
    local stack_name="$1"
    local compose_file_path="$2"
    local server_name="${3:-}"
    
    if [ -z "$stack_name" ] || [ -z "$compose_file_path" ] || [ ! -f "$compose_file_path" ]; then
        echo "Error: Stack name and valid compose file path are required" >&2
        return 1
    fi
    
    # Resolve server id
    local server_id=""
    if [ -n "$server_name" ]; then
        server_id=$(komodo_get_server_id_by_name "$server_name")
    fi
    
    if [ -z "$server_id" ]; then
        server_id=$(komodo_get_default_server_id)
    fi
    
    if [ -z "$server_id" ]; then
        echo "Error: Komodo server not configured for stack '${stack_name}'" >&2
        echo "Provide a server name when deploying (e.g., ./wp-docker-cli.sh deploy <server_name>)" >&2
        return 1
    fi
    
    # Read docker-compose.yml content
    local compose_content=$(cat "$compose_file_path")
    
    # Escape JSON special characters and preserve newlines as \n for YAML parsing
    compose_content=$(echo "$compose_content" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    
    local config_json="{\"server_id\":\"${server_id}\",\"file_contents\":\"${compose_content}\"}"
    local params_json="{\"name\":\"${stack_name}\",\"config\":${config_json}}"
    
    local response=$(komodo_api_request "/write" "CreateStack" "$params_json")
    
    if echo "$response" | grep -q '"error"'; then
        local error_msg=$(echo "$response" | grep -o '"error":"[^"]*"' | head -1 | cut -d'"' -f4)
        echo "Error creating stack: ${error_msg:-Unknown error}" >&2
        return 1
    fi
    
    return 0
}

# Update an existing stack
# Usage: komodo_update_stack <stack_name> <compose_file_path> [stack_id] [server_name]
# Returns: 0 on success, 1 on error
komodo_update_stack() {
    local stack_name="$1"
    local compose_file_path="$2"
    local stack_id="${3:-}"
    local server_name="${4:-}"
    
    if [ -z "$stack_name" ] || [ -z "$compose_file_path" ] || [ ! -f "$compose_file_path" ]; then
        echo "Error: Stack name and valid compose file path are required" >&2
        return 1
    fi
    
    if [ -z "$stack_id" ]; then
        local stack_response=$(komodo_get_stack "$stack_name")
        stack_id=$(echo "$stack_response" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
        if [ -z "$stack_id" ]; then
            # Fallback to list stacks in case GetStack omits id
            stack_id=$(komodo_get_stack_id_by_name "$stack_name")
        fi
    fi
    
    if [ -z "$stack_id" ]; then
        echo "Error: Could not determine stack id for '${stack_name}'" >&2
        return 1
    fi
    
    # Resolve server id (prefer existing stack config)
    local server_id=""
    server_id=$(komodo_get_stack_server_id "$stack_name")
    if [ -z "$server_id" ] && [ -n "$server_name" ]; then
        server_id=$(komodo_get_server_id_by_name "$server_name")
    fi
    if [ -z "$server_id" ]; then
        server_id=$(komodo_get_default_server_id)
    fi
    
    if [ -z "$server_id" ]; then
        echo "Error: Stack '${stack_name}' has no server configured" >&2
        echo "Provide a server name when deploying (e.g., ./wp-docker-cli.sh deploy <server_name>)" >&2
        return 1
    fi
    
    # Read docker-compose.yml content
    local compose_content=$(cat "$compose_file_path")
    
    # Escape JSON special characters and preserve newlines as \n for YAML parsing
    compose_content=$(echo "$compose_content" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    
    local config_json="{\"name\":\"${stack_name}\",\"server_id\":\"${server_id}\",\"file_contents\":\"${compose_content}\"}"
    local params_json="{\"id\":\"${stack_id}\",\"config\":${config_json}}"
    
    local response=$(komodo_api_request "/write" "UpdateStack" "$params_json")
    
    if echo "$response" | grep -q '"error"'; then
        local error_msg=$(echo "$response" | grep -o '"error":"[^"]*"' | head -1 | cut -d'"' -f4)
        echo "Error updating stack: ${error_msg:-Unknown error}" >&2
        return 1
    fi
    
    return 0
}

# Deploy a stack
# Usage: komodo_deploy_stack <stack_name> [stop_time]
# Returns: 0 on success, 1 on error
komodo_deploy_stack() {
    local stack_name="$1"
    local stop_time="${2:-}"
    
    if [ -z "$stack_name" ]; then
        echo "Error: Stack name is required" >&2
        return 1
    fi
    
    local params_json="{\"stack\":\"${stack_name}\""
    if [ -n "$stop_time" ]; then
        params_json="${params_json},\"stop_time\":\"${stop_time}\""
    fi
    params_json="${params_json}}"
    
    local response=$(komodo_api_request "/execute" "DeployStack" "$params_json")
    
    if echo "$response" | grep -q '"error"'; then
        local error_msg=$(echo "$response" | grep -o '"error":"[^"]*"' | head -1 | cut -d'"' -f4)
        echo "Error deploying stack: ${error_msg:-Unknown error}" >&2
        return 1
    fi
    
    return 0
}

# Get deployment status
# Usage: komodo_get_deployment_status <deployment_id>
# Returns: Deployment status JSON
komodo_get_deployment_status() {
    local deployment_id="$1"
    
    if [ -z "$deployment_id" ]; then
        echo "Error: Deployment ID is required" >&2
        return 1
    fi
    
    komodo_api_request "/read" "GetDeployment" "{\"deployment\":\"${deployment_id}\"}"
}

# Create or update stack (idempotent)
# Usage: komodo_ensure_stack <stack_name> <compose_file_path> <server_name>
# Returns: 0 on success, 1 on error
komodo_ensure_stack() {
    local stack_name="$1"
    local compose_file_path="$2"
    local server_name="${3:-}"
    
    # Check if stack exists
    local existing_stack=$(komodo_get_stack "$stack_name")
    local existing_id=$(echo "$existing_stack" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
    if [ -z "$existing_id" ]; then
        existing_id=$(komodo_get_stack_id_by_name "$stack_name")
    fi
    
    if echo "$existing_stack" | grep -q '"error"' || [ -z "$existing_id" ]; then
        # Stack doesn't exist, create it
        echo "Creating new stack: ${stack_name}"
        komodo_create_stack "$stack_name" "$compose_file_path" "$server_name"
    else
        # Stack exists, update it
        echo "Updating existing stack: ${stack_name}"
        komodo_update_stack "$stack_name" "$compose_file_path" "$existing_id" "$server_name"
    fi
}
