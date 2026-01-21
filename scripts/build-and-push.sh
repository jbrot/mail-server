#!/usr/bin/env bash
#
# Build container images with Nix and push to AWS ECR
#
# Usage: ./scripts/build-and-push.sh [--all|--opensmtpd|--dovecot|--rspamd]
#
set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
AWS_REGION="${AWS_REGION:-us-east-1}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Get ECR registry URL from Terraform output or environment
get_ecr_registry() {
    if [ -n "${ECR_REGISTRY:-}" ]; then
        echo "$ECR_REGISTRY"
        return
    fi

    # Try to get from Terraform
    if [ -d "$PROJECT_DIR/terraform" ]; then
        local registry_id
        registry_id=$(terraform -chdir="$PROJECT_DIR/terraform" output -raw ecr_registry_id 2>/dev/null || true)
        if [ -n "$registry_id" ]; then
            echo "${registry_id}.dkr.ecr.${AWS_REGION}.amazonaws.com"
            return
        fi
    fi

    log_error "Could not determine ECR registry. Set ECR_REGISTRY environment variable or run terraform apply first."
    exit 1
}

# Login to ECR
ecr_login() {
    local registry="$1"
    log_info "Logging in to ECR..."
    aws ecr get-login-password --region "$AWS_REGION" | \
        podman login --username AWS --password-stdin "$registry"
}

# Build and push a single image
build_and_push() {
    local name="$1"
    local registry="$2"
    local project="${PROJECT_NAME:-email-server}"

    log_info "Building $name image..."

    # Build with Nix
    local result
    result=$(nix build "$PROJECT_DIR#${name}-image" --print-out-paths --no-link)

    if [ -z "$result" ]; then
        log_error "Failed to build $name image"
        return 1
    fi

    log_info "Loading image into Podman..."
    local loaded_image
    loaded_image=$(podman load -i "$result" | grep -oP 'Loaded image: \K.*' || true)

    if [ -z "$loaded_image" ]; then
        # Fallback: try to get image name from the tarball
        loaded_image="${name}:latest"
    fi

    log_info "Loaded image: $loaded_image"

    # Tag for ECR
    local ecr_image="${registry}/${project}/${name}:latest"
    local ecr_image_dated="${registry}/${project}/${name}:$(date +%Y%m%d-%H%M%S)"

    log_info "Tagging as $ecr_image"
    podman tag "$loaded_image" "$ecr_image"
    podman tag "$loaded_image" "$ecr_image_dated"

    # Push to ECR
    log_info "Pushing to ECR..."
    podman push "$ecr_image"
    podman push "$ecr_image_dated"

    log_info "Successfully pushed $name to ECR"

    # Cleanup local images
    podman rmi "$loaded_image" 2>/dev/null || true
}

# Main
main() {
    cd "$PROJECT_DIR"

    # Parse arguments
    local build_all=false
    local build_opensmtpd=false
    local build_dovecot=false
    local build_rspamd=false

    if [ $# -eq 0 ]; then
        build_all=true
    else
        case "$1" in
            --all)
                build_all=true
                ;;
            --opensmtpd)
                build_opensmtpd=true
                ;;
            --dovecot)
                build_dovecot=true
                ;;
            --rspamd)
                build_rspamd=true
                ;;
            *)
                echo "Usage: $0 [--all|--opensmtpd|--dovecot|--rspamd]"
                exit 1
                ;;
        esac
    fi

    # Get ECR registry
    local registry
    registry=$(get_ecr_registry)
    log_info "Using ECR registry: $registry"

    # Login to ECR
    ecr_login "$registry"

    # Build and push images
    if [ "$build_all" = true ] || [ "$build_opensmtpd" = true ]; then
        build_and_push "opensmtpd" "$registry"
    fi

    if [ "$build_all" = true ] || [ "$build_dovecot" = true ]; then
        build_and_push "dovecot" "$registry"
    fi

    if [ "$build_all" = true ] || [ "$build_rspamd" = true ]; then
        build_and_push "rspamd" "$registry"
    fi

    log_info "All done!"
}

main "$@"
