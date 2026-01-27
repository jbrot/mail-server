#!/usr/bin/env bash
# Create or update a mail server user account
# Usage: ./scripts/create-account.sh [OPTIONS]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_BASE_DIR="${PROJECT_DIR}/config"

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

# Run mkpasswd via nix using the pinned version from our flake
run_mkpasswd() {
    nix shell "$PROJECT_DIR#mkpasswd" -c mkpasswd "$@"
}

# List available configs (directories under config/)
list_configs() {
    find "$CONFIG_BASE_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort
}

# Default values
CONFIG_NAME=""
USERNAME=""

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Create or update a mail server user account.

Options:
    -h, --help              Show this help message
    -c, --config <name>     Config directory name (prompted if not specified)
    -u, --user <username>   Username for the account (prompted if not specified)

Examples:
    # Fully interactive
    ./scripts/create-account.sh

    # Specify config and username
    ./scripts/create-account.sh -c mail2.jbrot.com -u alice

    # Specify config, prompt for username
    ./scripts/create-account.sh -c mail2.jbrot.com
EOF
}

# Parse arguments
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
        -u|--user)
            USERNAME="$2"
            shift 2
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# --- Config selection ---
if [[ -z "$CONFIG_NAME" ]]; then
    echo "Available configurations:"
    echo ""
    mapfile -t configs < <(list_configs)
    for i in "${!configs[@]}"; do
        echo "  $((i+1)). ${configs[$i]}"
    done
    echo ""
    read -rp "Select config (number): " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#configs[@]} )); then
        CONFIG_NAME="${configs[$((choice-1))]}"
    else
        log_error "Invalid selection."
        exit 1
    fi
fi

CONFIG_DIR="${CONFIG_BASE_DIR}/${CONFIG_NAME}"
if [[ ! -d "$CONFIG_DIR" ]]; then
    log_error "Config directory not found: $CONFIG_DIR"
    exit 1
fi

log_info "Using config: $CONFIG_NAME"

# --- Username ---
if [[ -z "$USERNAME" ]]; then
    read -rp "Username: " USERNAME
fi

if [[ -z "$USERNAME" ]]; then
    log_error "Username cannot be empty."
    exit 1
fi

# Validate username (alphanumeric, dots, hyphens, underscores)
if [[ ! "$USERNAME" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    log_error "Invalid username: must contain only letters, numbers, dots, hyphens, or underscores."
    exit 1
fi

ACCOUNTS_DIR="${CONFIG_DIR}/accounts"
ACCOUNT_FILE="${ACCOUNTS_DIR}/${USERNAME}"

# --- Existing account check ---
if [[ -f "$ACCOUNT_FILE" ]]; then
    log_warn "Account '$USERNAME' already exists for config '$CONFIG_NAME'."
    read -rp "Change password? (y/N): " confirm
    if [[ "$confirm" != [yY] ]]; then
        log_info "Aborted."
        exit 0
    fi
fi

# --- Password entry ---
read -rsp "Password: " password
echo ""
read -rsp "Confirm password: " password_confirm
echo ""

if [[ "$password" != "$password_confirm" ]]; then
    log_error "Passwords do not match."
    exit 1
fi

if [[ -z "$password" ]]; then
    log_error "Password cannot be empty."
    exit 1
fi

# --- Hash and save ---
log_info "Generating password hash..."
hash=$(echo "$password" | run_mkpasswd -m sha-512 -s)

mkdir -p "$ACCOUNTS_DIR"
echo -n "$hash" > "$ACCOUNT_FILE"

log_info "Account '$USERNAME' saved to $ACCOUNT_FILE"
log_info "Deploy to apply: ./scripts/deploy.sh -c $CONFIG_NAME -o deploy"
