#!/usr/bin/env bash
# Migrate mail from old server to new mail server via local machine
# Usage: ./scripts/migrate-mail.sh --source user@old-server --source-path /path/to/Maildir --user username
#
# Examples:
#   ./scripts/migrate-mail.sh --source joshua@mail.jbrot.com --user joshua --sudo
#   ./scripts/migrate-mail.sh --source root@old.example.com --user alice  # defaults to /home/alice/Maildir

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="${PROJECT_DIR}/terraform"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# Run terraform via nix
run_terraform() {
    nix run --quiet .#terraform -- "$@"
}

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Migrate mail from old server to new mail server via local machine.
Uses Terraform state to connect to the new server (like ssh.sh).

Options:
    -h, --help                 Show this help message
    -s, --source HOST          Source server (e.g., user@mail.old.com)
    -p, --source-path PATH     Path to Maildir on source (default: /home/<user>/Maildir)
    -u, --user USERNAME        Mail user to migrate
    --sudo                     Use sudo on source server to access Maildir
    -n, --dry-run              Show what would be done without doing it

Examples:
    $(basename "$0") --source root@mail.jbrot.com --user joshua
    $(basename "$0") --source root@old.example.com --source-path /var/mail/alice --user alice
EOF
}

# Parse arguments
SOURCE_HOST=""
SOURCE_PATH=""
MAIL_USER=""
USE_SUDO=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        -s|--source)
            SOURCE_HOST="$2"
            shift 2
            ;;
        -p|--source-path)
            SOURCE_PATH="$2"
            shift 2
            ;;
        -u|--user)
            MAIL_USER="$2"
            shift 2
            ;;
        --sudo)
            USE_SUDO=true
            shift
            ;;
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Validate required arguments
if [[ -z "$SOURCE_HOST" ]]; then
    log_error "--source is required"
    usage
    exit 1
fi

if [[ -z "$MAIL_USER" ]]; then
    log_error "--user is required"
    usage
    exit 1
fi

# Default source path if not specified
if [[ -z "$SOURCE_PATH" ]]; then
    SOURCE_PATH="/home/${MAIL_USER}/Maildir"
fi

# Get destination server info from Terraform
log_info "Getting destination server info from Terraform..."
DEST_IP=$(run_terraform -chdir="$TERRAFORM_DIR" output -raw instance_public_ip 2>/dev/null || echo "")
if [[ -z "$DEST_IP" ]]; then
    log_error "Could not get instance IP from Terraform. Have you run 'deploy.sh -o infra'?"
    exit 1
fi

# Extract private key for destination
DEST_KEY_FILE=$(mktemp)
trap "rm -f '$DEST_KEY_FILE'" EXIT

if ! run_terraform -chdir="$TERRAFORM_DIR" output -raw private_key > "$DEST_KEY_FILE" 2>/dev/null; then
    log_error "Could not extract private key from Terraform."
    exit 1
fi
chmod 600 "$DEST_KEY_FILE"

DEST_SSH_OPTS="-i $DEST_KEY_FILE -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
DEST_PATH="/data/mail/${MAIL_USER}"

# Summary
echo ""
echo "=========================================="
echo "  Mail Migration"
echo "=========================================="
echo "  Source:      ${SOURCE_HOST}:${SOURCE_PATH}"
echo "  Destination: root@${DEST_IP}:${DEST_PATH}"
echo "  User:        ${MAIL_USER}"
echo "  Sudo:        ${USE_SUDO}"
echo "=========================================="
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "Dry run mode - no changes will be made"
    echo ""
    SUDO_OPT=""
    [[ "$USE_SUDO" == "true" ]] && SUDO_OPT=" --rsync-path='sudo rsync'"
    echo "Would execute:"
    echo "  1. rsync -avz${SUDO_OPT} ${SOURCE_HOST}:${SOURCE_PATH}/ <local-temp>/"
    echo "  2. rsync -avz <local-temp>/ root@${DEST_IP}:${DEST_PATH}/"
    echo "  3. ssh root@${DEST_IP} 'chown -R 5000:5000 ${DEST_PATH}'"
    exit 0
fi

# Confirm
read -p "Proceed with migration? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_info "Aborted"
    exit 0
fi

# Test connections
log_info "Testing SSH connections..."
if ! ssh -o ConnectTimeout=10 "$SOURCE_HOST" "echo 'Source OK'" 2>/dev/null; then
    log_error "Cannot connect to source: $SOURCE_HOST"
    exit 1
fi

if ! ssh $DEST_SSH_OPTS "root@${DEST_IP}" "echo 'Destination OK'" 2>/dev/null; then
    log_error "Cannot connect to destination: root@${DEST_IP}"
    exit 1
fi
log_info "Both connections OK"

# Create local temp directory
LOCAL_TEMP=$(mktemp -d)
trap "rm -rf '$LOCAL_TEMP' '$DEST_KEY_FILE'" EXIT
log_info "Using temp directory: $LOCAL_TEMP"

# Step 1: Pull from source to local
log_info "Step 1/3: Pulling mail from source..."
RSYNC_OPTS=(-avz --progress)
if [[ "$USE_SUDO" == "true" ]]; then
    RSYNC_OPTS+=(--rsync-path="sudo rsync")
fi
rsync "${RSYNC_OPTS[@]}" \
    "${SOURCE_HOST}:${SOURCE_PATH}/" \
    "${LOCAL_TEMP}/"

# Count messages
MSG_COUNT=$(find "$LOCAL_TEMP" -type f | wc -l)
log_info "Downloaded $MSG_COUNT files"

# Step 2: Push from local to destination
log_info "Step 2/3: Pushing mail to destination..."
ssh $DEST_SSH_OPTS "root@${DEST_IP}" "mkdir -p ${DEST_PATH}"
rsync -avz --progress \
    -e "ssh $DEST_SSH_OPTS" \
    "${LOCAL_TEMP}/" \
    "root@${DEST_IP}:${DEST_PATH}/"

# Step 3: Fix ownership
log_info "Step 3/3: Fixing ownership..."
ssh $DEST_SSH_OPTS "root@${DEST_IP}" "chown -R 5000:5000 ${DEST_PATH}"

# Verify
log_info "Verifying migration..."
DEST_COUNT=$(ssh $DEST_SSH_OPTS "root@${DEST_IP}" "find ${DEST_PATH} -type f | wc -l")
log_info "Source files: $MSG_COUNT"
log_info "Destination files: $DEST_COUNT"

if [[ "$MSG_COUNT" -eq "$DEST_COUNT" ]]; then
    log_info "File counts match!"
else
    log_warn "File counts differ - please verify manually"
fi

echo ""
log_info "Migration complete!"
log_warn "Remember to test IMAP access before switching DNS"
