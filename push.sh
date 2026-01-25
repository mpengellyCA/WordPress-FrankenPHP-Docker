#!/bin/bash

set -e

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Default values
GITHUB_USER="${GITHUB_USER:-}"
IMAGE_NAME="wordpress-frankenphp"
VERSION="${VERSION:-latest}"
REGISTRY="ghcr.io"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --user)
            GITHUB_USER="$2"
            shift 2
            ;;
        --version)
            VERSION="$2"
            shift 2
            ;;
        --registry)
            REGISTRY="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Check if GitHub user is set
if [ -z "$GITHUB_USER" ]; then
    echo "Error: GitHub username is required"
    echo "Usage: $0 --user <github-username> [--version <version>] [--registry <registry>]"
    echo "Example: $0 --user myusername --version 1.0.0"
    exit 1
fi

# Full image name
FULL_IMAGE_NAME="${REGISTRY}/${GITHUB_USER}/${IMAGE_NAME}"

echo "Pushing Docker image to registry..."
echo "  Image: ${FULL_IMAGE_NAME}:${VERSION}"
echo "  Also pushing: ${FULL_IMAGE_NAME}:latest"

# Check if user is logged in to GitHub Container Registry
if ! docker info | grep -q "Username"; then
    echo ""
    echo "Note: You may need to login to GitHub Container Registry first:"
    echo "  echo \$GITHUB_TOKEN | docker login ghcr.io -u USERNAME --password-stdin"
    echo ""
    read -p "Continue anyway? (y/N): " continue
    if [[ ! $continue =~ ^[Yy]$ ]]; then
        exit 0
    fi
fi

# Push the image
docker push "${FULL_IMAGE_NAME}:${VERSION}"
docker push "${FULL_IMAGE_NAME}:latest"

echo ""
echo "Push complete!"
echo ""
echo "Image is now available at:"
echo "  ${FULL_IMAGE_NAME}:${VERSION}"
echo "  ${FULL_IMAGE_NAME}:latest"
echo ""
echo "To use in docker-compose.yml:"
echo "  image: ${FULL_IMAGE_NAME}:latest"
