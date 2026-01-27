#!/usr/bin/env bash
# Get an interactive SSH shell on the mail server using Terraform-managed credentials
# Usage: ./scripts/ssh.sh [command...]
#   No arguments: opens interactive shell
#   With arguments: runs command on remote host

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="${PROJECT_DIR}/terraform"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# Run terraform via nix using the pinned version from our flake
run_terraform() {
    nix run --quiet .#terraform -- "$@"
}

# Extract instance IP
INSTANCE_IP=$(run_terraform -chdir="$TERRAFORM_DIR" output -raw instance_public_ip 2>/dev/null || echo "")
if [[ -z "$INSTANCE_IP" ]]; then
    log_error "Could not get instance IP from Terraform. Have you run 'deploy.sh -o infra'?"
    exit 1
fi

# Extract private key to temp file
SSH_KEY_FILE=$(mktemp)
trap "rm -f '$SSH_KEY_FILE'" EXIT

if ! run_terraform -chdir="$TERRAFORM_DIR" output -raw private_key > "$SSH_KEY_FILE" 2>/dev/null; then
    log_error "Could not extract private key from Terraform."
    exit 1
fi
chmod 600 "$SSH_KEY_FILE"

SSH_OPTS="-i $SSH_KEY_FILE -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"

if [[ $# -eq 0 ]]; then
    log_info "Connecting to root@${INSTANCE_IP}..."
    ssh $SSH_OPTS "root@${INSTANCE_IP}"
else
    ssh $SSH_OPTS "root@${INSTANCE_IP}" "$@"
fi
