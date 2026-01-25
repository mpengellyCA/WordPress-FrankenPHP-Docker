#!/bin/bash

# GitHub API Integration Module
# Provides functions for interacting with GitHub API and GitHub Container Registry

# GitHub API base URL
GITHUB_API_BASE="https://api.github.com"
GITHUB_REGISTRY="ghcr.io"

# Initialize GitHub API
# Usage: github_init <github_token> <github_username>
github_init() {
    export GITHUB_TOKEN="$1"
    export GITHUB_USERNAME="$2"
    
    if [ -z "$GITHUB_TOKEN" ]; then
        echo "Error: GitHub token is required" >&2
        return 1
    fi
    
    if [ -z "$GITHUB_USERNAME" ]; then
        echo "Error: GitHub username is required" >&2
        return 1
    fi
}

# Validate GitHub token
# Usage: github_validate_token
# Returns: 0 if valid, 1 if invalid
github_validate_token() {
    if [ -z "$GITHUB_TOKEN" ]; then
        echo "Error: GitHub token is not set" >&2
        return 1
    fi
    
    local response=$(curl -s -w "\n%{http_code}" -X GET "${GITHUB_API_BASE}/user" \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github.v3+json")
    
    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | sed '$d')
    
    if [ "$http_code" = "200" ] && echo "$body" | grep -q '"login"'; then
        return 0
    else
        echo "Invalid GitHub token (HTTP $http_code)" >&2
        return 1
    fi
}

# Login to GitHub Container Registry
# Usage: github_registry_login
# Returns: 0 on success, 1 on error
github_registry_login() {
    if [ -z "$GITHUB_TOKEN" ] || [ -z "$GITHUB_USERNAME" ]; then
        echo "Error: GitHub token and username required for registry login" >&2
        return 1
    fi
    
    echo "$GITHUB_TOKEN" | docker login "$GITHUB_REGISTRY" -u "$GITHUB_USERNAME" --password-stdin
    
    return $?
}

# Build Docker image
# Usage: github_build_image <image_name> <tag> <dockerfile_path>
# Returns: 0 on success, 1 on error
github_build_image() {
    local image_name="$1"
    local tag="$2"
    local dockerfile_path="${3:-.}"
    
    if [ -z "$image_name" ] || [ -z "$tag" ]; then
        echo "Error: Image name and tag are required" >&2
        return 1
    fi
    
    local full_image_name="${GITHUB_REGISTRY}/${GITHUB_USERNAME}/${image_name}:${tag}"
    local latest_image_name="${GITHUB_REGISTRY}/${GITHUB_USERNAME}/${image_name}:latest"
    
    echo "Building Docker image: ${full_image_name}"
    
    docker build -t "$full_image_name" -t "$latest_image_name" "$dockerfile_path"
    
    return $?
}

# Push Docker image to GitHub Container Registry
# Usage: github_push_image <image_name> <tag>
# Returns: 0 on success, 1 on error
github_push_image() {
    local image_name="$1"
    local tag="$2"
    
    if [ -z "$image_name" ] || [ -z "$tag" ]; then
        echo "Error: Image name and tag are required" >&2
        return 1
    fi
    
    local full_image_name="${GITHUB_REGISTRY}/${GITHUB_USERNAME}/${image_name}:${tag}"
    local latest_image_name="${GITHUB_REGISTRY}/${GITHUB_USERNAME}/${image_name}:latest"
    
    echo "Pushing Docker image: ${full_image_name}"
    
    docker push "$full_image_name"
    local push_result=$?
    
    if [ $push_result -eq 0 ] && [ "$tag" != "latest" ]; then
        echo "Pushing latest tag: ${latest_image_name}"
        docker push "$latest_image_name"
        push_result=$?
    fi
    
    return $push_result
}

# Build and push Docker image in one step
# Usage: github_build_and_push_image <image_name> <tag> <dockerfile_path>
# Returns: 0 on success, 1 on error
github_build_and_push_image() {
    local image_name="$1"
    local tag="$2"
    local dockerfile_path="${3:-.}"
    
    if [ -z "$image_name" ] || [ -z "$tag" ]; then
        echo "Error: Image name and tag are required" >&2
        return 1
    fi
    
    # Login to registry
    if ! github_registry_login; then
        echo "Error: Failed to login to GitHub Container Registry" >&2
        return 1
    fi
    
    # Build image
    if ! github_build_image "$image_name" "$tag" "$dockerfile_path"; then
        echo "Error: Failed to build Docker image" >&2
        return 1
    fi
    
    # Push image
    if ! github_push_image "$image_name" "$tag"; then
        echo "Error: Failed to push Docker image" >&2
        return 1
    fi
    
    echo "Successfully built and pushed: ${GITHUB_REGISTRY}/${GITHUB_USERNAME}/${image_name}:${tag}"
    return 0
}

# Check if Docker image exists in registry
# Usage: github_check_image_exists <image_name> <tag>
# Returns: 0 if exists, 1 if not exists
github_check_image_exists() {
    local image_name="$1"
    local tag="${2:-latest}"
    
    if [ -z "$image_name" ] || [ -z "$GITHUB_TOKEN" ] || [ -z "$GITHUB_USERNAME" ]; then
        return 1
    fi
    
    local package_name="${image_name}"
    local response=$(curl -s -X GET \
        "${GITHUB_API_BASE}/user/packages/container/${package_name}/versions" \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github.v3+json")
    
    if echo "$response" | grep -q "\"name\":\"${tag}\""; then
        return 0
    else
        return 1
    fi
}

# Get full image name for use in docker-compose
# Usage: github_get_image_name <image_name> <tag>
# Returns: full image name
github_get_image_name() {
    local image_name="$1"
    local tag="${2:-latest}"
    
    echo "${GITHUB_REGISTRY}/${GITHUB_USERNAME}/${image_name}:${tag}"
}
