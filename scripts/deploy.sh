#!/usr/bin/env bash
# Deploy script for mail server AMI
# Usage: ./scripts/deploy.sh [--config <name>] [--skip-tests]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_BASE_DIR="${PROJECT_DIR}/config"

# Detect host architecture
detect_host_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  echo "x86_64-linux" ;;
        aarch64) echo "aarch64-linux" ;;
        arm64)   echo "aarch64-linux" ;;  # macOS reports arm64
        *)       echo "x86_64-linux" ;;   # fallback
    esac
}

# Get default config name based on host architecture
get_default_config() {
    local host_arch
    host_arch=$(detect_host_arch)
    case "$host_arch" in
        aarch64-linux) echo "default-aarch64" ;;
        *)             echo "default-x86_64" ;;
    esac
}

# List available configs
list_configs() {
    find "$CONFIG_BASE_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort
}

# Default values
CONFIG_NAME=""
SKIP_TESTS=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

usage() {
    local default_config
    default_config=$(get_default_config)
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Deploy mail server AMI to AWS.

Options:
    --config <name>    Config directory name (default: "$default_config")
                       Looks for config/<name>/mail-server.nix
    --skip-tests       Skip running the test suite before building
    --list-configs     List available configurations
    -h, --help         Show this help message

Available configs:
$(list_configs | sed 's/^/    /')

Examples:
    # Build with default config for your architecture, run tests first
    ./scripts/deploy.sh

    # Build with production config
    ./scripts/deploy.sh --config production

    # Build for aarch64 (Graviton)
    ./scripts/deploy.sh --config default-aarch64

    # Skip tests (useful for quick iteration)
    ./scripts/deploy.sh --config production --skip-tests

Phase 2 TODO: This script will be extended to upload and register the AMI.
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --config)
            CONFIG_NAME="$2"
            shift 2
            ;;
        --skip-tests)
            SKIP_TESTS=true
            shift
            ;;
        --list-configs)
            list_configs
            exit 0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Use default config if not specified
if [[ -z "$CONFIG_NAME" ]]; then
    CONFIG_NAME=$(get_default_config)
    log_info "Auto-selected config based on host architecture: $CONFIG_NAME"
fi

# Validate config directory exists
CONFIG_DIR="config/${CONFIG_NAME}"
CONFIG_FILE="${PROJECT_DIR}/${CONFIG_DIR}/mail-server.nix"

if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "Config file not found: $CONFIG_FILE"
    echo ""
    echo "Available configs:"
    list_configs | sed 's/^/  /'
    echo ""
    log_error "Create a new config by copying from an existing one:"
    log_error "  mkdir -p config/myconfig"
    log_error "  cp config/default-x86_64/mail-server.nix config/myconfig/"
    exit 1
fi

log_info "Using config: $CONFIG_DIR"

# Build the override input argument
OVERRIDE_ARG="--override-input mail-server-config path:./${CONFIG_DIR}"

# Read architecture from config
ARCH=$(nix eval --raw --file "$CONFIG_FILE" architecture 2>/dev/null || echo "x86_64-linux")
log_info "Target architecture: $ARCH"

# Check if host can build for target architecture
HOST_ARCH=$(detect_host_arch)
if [[ "$HOST_ARCH" != "$ARCH" ]]; then
    log_error "Host ($HOST_ARCH) differs from target ($ARCH)"
    log_error "Cross-architecture builds require QEMU binfmt emulation or a remote builder."
    log_error ""
    log_error "Options:"
    log_error "  1. Use a config matching your host: --config default-x86_64"
    log_error "  2. Build on an $ARCH machine"
    log_error "  3. Enable QEMU emulation (NixOS: boot.binfmt.emulatedSystems = [ \"$ARCH\" ])"
    # TODO: Detect if emulation is available (check /proc/sys/fs/binfmt_misc/qemu-aarch64)
    #       and allow the build to proceed if configured
    exit 1
fi

# Step 1: Run tests (unless skipped)
if [[ "$SKIP_TESTS" == "true" ]]; then
    log_warn "Skipping tests (--skip-tests specified)"
else
    log_info "Running test suite..."
    log_info "Command: nix flake check $OVERRIDE_ARG"

    if nix flake check $OVERRIDE_ARG; then
        log_info "All tests passed!"
    else
        log_error "Tests failed. Fix the issues before deploying."
        log_error "Use --skip-tests to bypass (not recommended for production)"
        exit 1
    fi
fi

# Step 2: Build AMI
log_info "Building AMI..."
log_info "Command: nix build .#packages.${ARCH}.mail-server-ami $OVERRIDE_ARG"

if nix build ".#packages.${ARCH}.mail-server-ami" $OVERRIDE_ARG; then
    log_info "AMI build successful!"
else
    log_error "AMI build failed."
    exit 1
fi

# Show result
AMI_PATH=$(readlink -f result)
log_info "AMI artifacts: $AMI_PATH"
ls -la "$AMI_PATH/"

# Find VHD file
VHD_FILE=$(find "$AMI_PATH" -name "*.vhd" -o -name "*.raw" 2>/dev/null | head -1)
if [[ -n "$VHD_FILE" ]]; then
    log_info "Image file: $VHD_FILE"
    log_info "Size: $(du -h "$VHD_FILE" | cut -f1)"
fi

echo ""
log_info "Phase 1 complete. AMI built successfully."
log_warn "Phase 2 (upload, import, deploy) not yet implemented."
echo ""
echo "Next steps (manual for now):"
echo "  1. Upload VHD to S3"
echo "  2. Import as EC2 snapshot"
echo "  3. Register as AMI"
echo "  4. Update Terraform and apply"
