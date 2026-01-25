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

echo "Building Docker image..."
echo "  Image: ${FULL_IMAGE_NAME}:${VERSION}"
echo "  Also tagging as: ${FULL_IMAGE_NAME}:latest"

# Build the image
docker build -t "${FULL_IMAGE_NAME}:${VERSION}" \
             -t "${FULL_IMAGE_NAME}:latest" \
             .

echo ""
echo "Build complete!"
echo ""
echo "To push to registry:"
echo "  ./push.sh --user ${GITHUB_USER} --version ${VERSION}"
echo ""
echo "Or manually:"
echo "  docker push ${FULL_IMAGE_NAME}:${VERSION}"
echo "  docker push ${FULL_IMAGE_NAME}:latest"
