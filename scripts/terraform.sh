#!/usr/bin/env bash
# Terraform wrapper script - generates tfvars from Nix and runs terraform
# Usage: ./scripts/terraform.sh [OPTIONS] <terraform-command> [terraform-args...]
#
# Examples:
#   ./scripts/terraform.sh -c mail2.jbrot.com plan
#   ./scripts/terraform.sh -c mail2.jbrot.com apply
#   ./scripts/terraform.sh -c mail2.jbrot.com apply -replace="aws_ebs_volume.data"
#   ./scripts/terraform.sh -c mail2.jbrot.com state list
#   ./scripts/terraform.sh -c mail2.jbrot.com destroy

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_BASE_DIR="${PROJECT_DIR}/config"
TERRAFORM_DIR="${PROJECT_DIR}/terraform"

cd "$PROJECT_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Detect host architecture
detect_host_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  echo "x86_64-linux" ;;
        aarch64) echo "aarch64-linux" ;;
        arm64)   echo "aarch64-linux" ;;
        *)       echo "x86_64-linux" ;;
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

# Run terraform via nix
run_terraform() {
    nix run .#terraform -- "$@"
}

# Run AWS CLI via nix
run_aws() {
    nix run .#awscli -- "$@"
}

usage() {
    local default_config
    default_config=$(get_default_config)
    cat << EOF
Usage: $(basename "$0") [OPTIONS] <terraform-command> [terraform-args...]

Terraform wrapper that generates tfvars from Nix config and runs terraform.

Options:
    -h, --help             Show this help message
    -c, --config <name>    Config directory name (default: "$default_config")
    -n, --no-init          Skip terraform init
    -g, --no-generate      Skip tfvars generation (use existing)
    --list-configs         List available configurations

Examples:
    # Plan changes
    $(basename "$0") -c mail2.jbrot.com plan

    # Apply changes
    $(basename "$0") -c mail2.jbrot.com apply

    # Replace a specific resource (e.g., resize EBS volume)
    $(basename "$0") -c mail2.jbrot.com apply -replace="aws_ebs_volume.data"

    # View state
    $(basename "$0") -c mail2.jbrot.com state list

    # Import existing resource
    $(basename "$0") -c mail2.jbrot.com import aws_route53_zone.main ZONE_ID

    # Destroy infrastructure
    $(basename "$0") -c mail2.jbrot.com destroy

Available configs:
$(list_configs | sed 's/^/    /')
EOF
}

# Parse options
CONFIG_NAME=""
SKIP_INIT=false
SKIP_GENERATE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        -c|--config)
            CONFIG_NAME="$2"
            shift 2
            ;;
        -n|--no-init)
            SKIP_INIT=true
            shift
            ;;
        -g|--no-generate)
            SKIP_GENERATE=true
            shift
            ;;
        --list-configs)
            list_configs
            exit 0
            ;;
        -*)
            # Unknown option - might be for terraform, stop parsing
            break
            ;;
        *)
            # First non-option argument - terraform command
            break
            ;;
    esac
done

# Remaining arguments are for terraform
TF_ARGS=("$@")

if [[ ${#TF_ARGS[@]} -eq 0 ]]; then
    log_error "No terraform command specified"
    echo ""
    usage
    exit 1
fi

# Use default config if not specified
if [[ -z "$CONFIG_NAME" ]]; then
    CONFIG_NAME=$(get_default_config)
    log_info "Auto-selected config: $CONFIG_NAME"
fi

# Validate config directory exists
CONFIG_DIR="config/${CONFIG_NAME}"
CONFIG_FILE="${PROJECT_DIR}/${CONFIG_DIR}/mail-server.nix"

if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "Config file not found: $CONFIG_FILE"
    echo ""
    echo "Available configs:"
    list_configs | sed 's/^/  /'
    exit 1
fi

OVERRIDE_ARG="--override-input mail-server-config path:${PROJECT_DIR}/${CONFIG_DIR}"

# Check AWS credentials
log_info "Checking AWS credentials..."
if ! run_aws sts get-caller-identity &>/dev/null; then
    log_error "No valid AWS credentials. Run 'aws configure' first."
    exit 1
fi

# Generate tfvars from Nix
if [[ "$SKIP_GENERATE" != "true" ]]; then
    log_info "Generating terraform variables from Nix config..."
    nix build ".#tfvars" $OVERRIDE_ARG -o "${TERRAFORM_DIR}/from-nix.auto.tfvars"
fi

# Run terraform init if needed
if [[ "$SKIP_INIT" != "true" ]]; then
    log_info "Running terraform init..."
    run_terraform -chdir="$TERRAFORM_DIR" init -input=false
fi

# Run terraform with provided arguments
log_info "Running: terraform ${TF_ARGS[*]}"
run_terraform -chdir="$TERRAFORM_DIR" "${TF_ARGS[@]}"
