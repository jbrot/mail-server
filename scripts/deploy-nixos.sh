#!/usr/bin/env bash
#
# Deploy NixOS configuration to the mail server
#
# Usage: ./scripts/deploy-nixos.sh [--build-only|--switch|--test] [--target HOST]
#
set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Get target host from Terraform or environment
get_target_host() {
    if [ -n "${TARGET_HOST:-}" ]; then
        echo "$TARGET_HOST"
        return
    fi

    # Try to get from Terraform
    if [ -d "$PROJECT_DIR/terraform" ]; then
        local ip
        ip=$(terraform -chdir="$PROJECT_DIR/terraform" output -raw instance_public_ip 2>/dev/null || true)
        if [ -n "$ip" ]; then
            echo "root@$ip"
            return
        fi
    fi

    log_error "Could not determine target host. Set TARGET_HOST environment variable or run terraform apply first."
    exit 1
}

# Build NixOS configuration locally
build_config() {
    log_info "Building NixOS configuration..."

    local result
    result=$(nix build "$PROJECT_DIR#nixosConfigurations.mail-server.config.system.build.toplevel" \
        --print-out-paths --no-link)

    if [ -z "$result" ]; then
        log_error "Failed to build NixOS configuration"
        return 1
    fi

    echo "$result"
}

# Copy configuration to target and switch
deploy_switch() {
    local target="$1"
    local config_path="$2"

    log_info "Copying configuration to $target..."

    # Copy the closure to the target
    nix copy --to "ssh://$target" "$config_path"

    log_info "Activating configuration..."

    # Switch to the new configuration
    ssh "$target" "nix-env -p /nix/var/nix/profiles/system --set $config_path && $config_path/bin/switch-to-configuration switch"

    log_info "Deployment complete!"
}

# Test configuration (activate without making it boot default)
deploy_test() {
    local target="$1"
    local config_path="$2"

    log_info "Copying configuration to $target..."
    nix copy --to "ssh://$target" "$config_path"

    log_info "Testing configuration (will revert on reboot)..."
    ssh "$target" "$config_path/bin/switch-to-configuration test"

    log_warn "Configuration is active but will revert on reboot. Use --switch to make permanent."
}

# Main
main() {
    cd "$PROJECT_DIR"

    # Parse arguments
    local action="switch"
    local target=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --build-only)
                action="build"
                shift
                ;;
            --switch)
                action="switch"
                shift
                ;;
            --test)
                action="test"
                shift
                ;;
            --target)
                target="$2"
                shift 2
                ;;
            *)
                echo "Usage: $0 [--build-only|--switch|--test] [--target HOST]"
                exit 1
                ;;
        esac
    done

    # Build configuration
    local config_path
    config_path=$(build_config)
    log_info "Built: $config_path"

    if [ "$action" = "build" ]; then
        log_info "Build complete. Configuration at: $config_path"
        exit 0
    fi

    # Get target if not specified
    if [ -z "$target" ]; then
        target=$(get_target_host)
    fi
    log_info "Target: $target"

    # Test SSH connection
    log_info "Testing SSH connection..."
    if ! ssh -o ConnectTimeout=10 "$target" "echo 'SSH OK'" > /dev/null 2>&1; then
        log_error "Cannot connect to $target via SSH"
        exit 1
    fi

    # Deploy
    case "$action" in
        switch)
            deploy_switch "$target" "$config_path"
            ;;
        test)
            deploy_test "$target" "$config_path"
            ;;
    esac
}

main "$@"
