#!/usr/bin/env bash
#
# Migrate mail data from existing server to new server
#
# Usage: ./scripts/migrate-mail.sh --source user@old-server --dest user@new-server
#
set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Default paths
SOURCE_MAIL_PATH="${SOURCE_MAIL_PATH:-/data/mail}"
DEST_MAIL_PATH="${DEST_MAIL_PATH:-/data/mail}"
RSPAMD_DATA_PATH="${RSPAMD_DATA_PATH:-/data/rspamd}"

# Colors
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

# Sync mail data
sync_mail() {
    local source="$1"
    local dest="$2"

    log_info "Syncing mail data from $source to $dest..."

    # Use rsync with archive mode, preserve permissions
    rsync -avz --progress \
        --delete \
        -e "ssh -o StrictHostKeyChecking=accept-new" \
        "$source:$SOURCE_MAIL_PATH/" \
        "$dest:$DEST_MAIL_PATH/"

    log_info "Mail sync complete"
}

# Sync rspamd data (Bayes database, DKIM keys)
sync_rspamd() {
    local source="$1"
    local dest="$2"

    log_info "Syncing Rspamd data from $source to $dest..."

    rsync -avz --progress \
        -e "ssh -o StrictHostKeyChecking=accept-new" \
        "$source:$RSPAMD_DATA_PATH/" \
        "$dest:$RSPAMD_DATA_PATH/"

    log_info "Rspamd data sync complete"
}

# Fix permissions on destination
fix_permissions() {
    local dest="$1"

    log_info "Fixing permissions on $dest..."

    ssh "$dest" "chown -R 5000:5000 $DEST_MAIL_PATH && chmod -R 700 $DEST_MAIL_PATH"
    ssh "$dest" "chown -R 1000:1000 $RSPAMD_DATA_PATH"

    log_info "Permissions fixed"
}

# Verify migration
verify_migration() {
    local source="$1"
    local dest="$2"

    log_info "Verifying migration..."

    # Count mailboxes on source
    local source_count
    source_count=$(ssh "$source" "find $SOURCE_MAIL_PATH -type d -name 'cur' | wc -l")

    # Count mailboxes on destination
    local dest_count
    dest_count=$(ssh "$dest" "find $DEST_MAIL_PATH -type d -name 'cur' | wc -l")

    log_info "Source mailboxes: $source_count"
    log_info "Destination mailboxes: $dest_count"

    if [ "$source_count" -eq "$dest_count" ]; then
        log_info "Mailbox count matches!"
    else
        log_warn "Mailbox count differs. Please verify manually."
    fi

    # Check disk usage
    log_info "Disk usage comparison:"
    echo "Source:"
    ssh "$source" "du -sh $SOURCE_MAIL_PATH"
    echo "Destination:"
    ssh "$dest" "du -sh $DEST_MAIL_PATH"
}

# Main
main() {
    local source=""
    local dest=""
    local sync_mail_flag=true
    local sync_rspamd_flag=true
    local verify_flag=true
    local dry_run=false

    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --source)
                source="$2"
                shift 2
                ;;
            --dest)
                dest="$2"
                shift 2
                ;;
            --no-mail)
                sync_mail_flag=false
                shift
                ;;
            --no-rspamd)
                sync_rspamd_flag=false
                shift
                ;;
            --no-verify)
                verify_flag=false
                shift
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            *)
                echo "Usage: $0 --source user@old-server --dest user@new-server [options]"
                echo ""
                echo "Options:"
                echo "  --source HOST     Source server (e.g., root@old-mail.example.com)"
                echo "  --dest HOST       Destination server (e.g., root@new-mail.example.com)"
                echo "  --no-mail         Skip mail data sync"
                echo "  --no-rspamd       Skip Rspamd data sync"
                echo "  --no-verify       Skip verification"
                echo "  --dry-run         Show what would be done without doing it"
                exit 1
                ;;
        esac
    done

    # Validate arguments
    if [ -z "$source" ] || [ -z "$dest" ]; then
        log_error "Both --source and --dest are required"
        exit 1
    fi

    log_info "Migration plan:"
    log_info "  Source: $source"
    log_info "  Destination: $dest"
    log_info "  Sync mail: $sync_mail_flag"
    log_info "  Sync rspamd: $sync_rspamd_flag"
    log_info "  Verify: $verify_flag"

    if [ "$dry_run" = true ]; then
        log_warn "Dry run mode - no changes will be made"
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
    ssh -o ConnectTimeout=10 "$source" "echo 'Source OK'" || {
        log_error "Cannot connect to source: $source"
        exit 1
    }
    ssh -o ConnectTimeout=10 "$dest" "echo 'Destination OK'" || {
        log_error "Cannot connect to destination: $dest"
        exit 1
    }

    # Stop services on destination before sync
    log_info "Stopping mail services on destination..."
    ssh "$dest" "systemctl stop podman-opensmtpd podman-dovecot || true"

    # Perform sync
    if [ "$sync_mail_flag" = true ]; then
        sync_mail "$source" "$dest"
    fi

    if [ "$sync_rspamd_flag" = true ]; then
        sync_rspamd "$source" "$dest"
    fi

    # Fix permissions
    fix_permissions "$dest"

    # Start services
    log_info "Starting mail services on destination..."
    ssh "$dest" "systemctl start podman-rspamd podman-dovecot podman-opensmtpd"

    # Verify
    if [ "$verify_flag" = true ]; then
        verify_migration "$source" "$dest"
    fi

    log_info "Migration complete!"
    log_warn "Remember to:"
    log_warn "  1. Test mail sending/receiving on new server"
    log_warn "  2. Update DNS records when ready"
    log_warn "  3. Keep old server running as fallback initially"
}

main "$@"
