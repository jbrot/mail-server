#!/usr/bin/env bash
# Deploy script for mail server using nixos-rebuild
# Usage: ./scripts/deploy.sh [OPTIONS]
#
# Phases:
#   test  - Run tests (nix flake check)
#   infra  - Deploy infrastructure (terraform apply)
#   deploy - Deploy NixOS configuration (nixos-rebuild switch --target-host)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_BASE_DIR="${PROJECT_DIR}/config"
TERRAFORM_DIR="${PROJECT_DIR}/terraform"

# Run from project directory for nix/terraform commands
cd "$PROJECT_DIR"

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
VERBOSE=false
ONLY_PHASE=""
SKIP_PHASES=()

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

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

log_verbose() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $1"
    fi
}

# Run terraform via nix using the pinned version from our flake
run_terraform() {
    nix run $NIX_VERBOSE .#terraform -- "$@"
}

# Run AWS CLI via nix using the pinned version from our flake
run_aws() {
    nix run $NIX_VERBOSE .#awscli -- "$@"
}

# Run openssl via nix using the pinned version from our flake
run_openssl() {
    nix run $NIX_VERBOSE .#openssl -- "$@"
}

# Run dig via nix shell since dnsutils has no default binary
run_dig() {
    nix shell $NIX_VERBOSE .#dig -c dig "$@"
}

# Run swaks via nix using the pinned version from our flake
# Suppress SMTP conversation output unless verbose mode is enabled
run_swaks() {
    local silent_flag=""
    if [[ "$VERBOSE" != "true" ]]; then
        silent_flag="--silent"
    fi
    nix run $NIX_VERBOSE .#swaks -- $silent_flag "$@"
}

# Check AWS credentials and prompt to configure if needed
ensure_aws_credentials() {
    log_info "Checking AWS credentials..."
    if run_aws sts get-caller-identity &>/dev/null; then
        local account_id
        account_id=$(run_aws sts get-caller-identity --query 'Account' --output text)
        log_info "Authenticated to AWS account: $account_id"
    else
        log_warn "No valid AWS credentials found."
        log_info "Running 'aws configure' to set up credentials..."
        echo ""
        run_aws configure
        echo ""
        # Verify it worked
        if ! run_aws sts get-caller-identity &>/dev/null; then
            log_error "AWS credentials still not valid after configuration."
            exit 1
        fi
        log_info "AWS credentials configured successfully!"
    fi
}

usage() {
    local default_config
    default_config=$(get_default_config)
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Deploy mail server to AWS EC2 using nixos-rebuild.

Options:
    -h, --help                 Show this help message
    -c, --config <name>        Config directory name (default: "$default_config")
                               Looks for config/<name>/mail-server.nix
    -s, --skip <phase>         Skip a phase (can be specified multiple times)
    -o, --only <phase>         Run only this phase (cannot combine with --skip)
    -v, --verbose              Show extra output (adds -L to nix commands)
    --list-configs             List available configurations

Phases:
    test   Run nix flake check
    infra   Generate tfvars from Nix config, run terraform apply
    deploy  Run nixos-rebuild switch --target-host
    e2e     Validate DNS, ACME certs, and TLS on deployed server

Available configs:
$(list_configs | sed 's/^/    /')

Examples:
    # Full deploy (all phases)
    ./scripts/deploy.sh -c production

    # Run tests only
    ./scripts/deploy.sh -o test

    # Deploy config only (no infra changes)
    ./scripts/deploy.sh -c production -o deploy

    # Infrastructure changes only
    ./scripts/deploy.sh -c production -o infra

    # Verbose output
    ./scripts/deploy.sh -v -c production
EOF
}

# Validate phase name
validate_phase() {
    local phase="$1"
    case "$phase" in
        test|infra|deploy|e2e) return 0 ;;
        *)
            log_error "Invalid phase: $phase"
            log_error "Valid phases are: test, infra, deploy, e2e"
            exit 1
            ;;
    esac
}

# Check if phase should run
should_run_phase() {
    local phase="$1"

    # If --only is set, only run that phase
    if [[ -n "$ONLY_PHASE" ]]; then
        [[ "$phase" == "$ONLY_PHASE" ]]
        return
    fi

    # Otherwise, run unless skipped
    if [[ ${#SKIP_PHASES[@]} -gt 0 ]]; then
        for skip in "${SKIP_PHASES[@]}"; do
            if [[ "$skip" == "$phase" ]]; then
                return 1
            fi
        done
    fi
    return 0
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
        -s|--skip)
            validate_phase "$2"
            SKIP_PHASES+=("$2")
            shift 2
            ;;
        -o|--only)
            validate_phase "$2"
            ONLY_PHASE="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        --list-configs)
            list_configs
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Validate --skip and --only are not combined
if [[ -n "$ONLY_PHASE" ]] && [[ ${#SKIP_PHASES[@]} -gt 0 ]]; then
    log_error "Cannot combine --skip and --only"
    exit 1
fi

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

# Build the override input argument (use absolute path for consistency)
OVERRIDE_ARG="--override-input mail-server-config path:${PROJECT_DIR}/${CONFIG_DIR}"

# Nix verbosity flag
NIX_VERBOSE=""
if [[ "$VERBOSE" == "true" ]]; then
    NIX_VERBOSE="-L"
fi

# Read configuration values from Nix config (only values needed for display/output)
read_nix_config() {
    local key="$1"
    nix eval --raw --file "$CONFIG_FILE" "$key" 2>/dev/null || echo ""
}

# Read boolean configuration value from Nix config
read_nix_config_bool() {
    local key="$1"
    nix eval --file "$CONFIG_FILE" "$key" 2>/dev/null || echo "false"
}

DOMAIN=$(read_nix_config "domain")
HOSTNAME=$(read_nix_config "hostname")
ARCH=$(read_nix_config "architecture")
AWS_REGION=$(read_nix_config "aws.region")
DKIM_ENABLE=$(read_nix_config_bool "dkim.enable")
DKIM_SELECTOR=$(read_nix_config "dkim.selector")
[[ -z "$ARCH" ]] && ARCH="x86_64-linux"
[[ -z "$DKIM_SELECTOR" ]] && DKIM_SELECTOR="mail"

# Convert Nix architecture to AWS architecture for display
case "$ARCH" in
    x86_64-linux)  AWS_ARCH="x86_64" ;;
    aarch64-linux) AWS_ARCH="arm64" ;;
    *)             AWS_ARCH="x86_64" ;;
esac

# Prevent accidental deployment of default configs
is_default_config() {
    [[ "$CONFIG_NAME" == default-* ]]
}

if is_default_config && { should_run_phase "infra" || should_run_phase "deploy" || should_run_phase "e2e"; }; then
    log_error "Cannot deploy a default config to AWS!"
    log_error "Default configs are for testing only."
    echo ""
    echo "Create a production config:"
    echo "  mkdir -p config/production"
    echo "  cp config/${CONFIG_NAME}/mail-server.nix config/production/"
    echo "  # Edit config/production/mail-server.nix with your settings"
    echo ""
    echo "Then deploy:"
    echo "  ./scripts/deploy.sh -c production"
    exit 1
fi

# ============================================================================
# Phase: test
# ============================================================================
phase_test() {
    log_step "Phase: test"

    log_verbose "Command: nix flake check $NIX_VERBOSE $OVERRIDE_ARG"

    if nix flake check $NIX_VERBOSE $OVERRIDE_ARG; then
        log_info "All tests passed!"
    else
        log_error "Tests failed. Fix the issues before deploying."
        exit 1
    fi
}

# ============================================================================
# Phase: infra
# ============================================================================
phase_infra() {
    log_step "Phase: infra"

    # Ensure AWS credentials are configured
    ensure_aws_credentials

    # Generate tfvars from Nix config
    log_info "Generating terraform variables from Nix..."
    log_verbose "Command: nix build $NIX_VERBOSE .#tfvars $OVERRIDE_ARG -o ${TERRAFORM_DIR}/from-nix.auto.tfvars"

    nix build $NIX_VERBOSE ".#tfvars" $OVERRIDE_ARG -o "${TERRAFORM_DIR}/from-nix.auto.tfvars"
    log_info "Generated: ${TERRAFORM_DIR}/from-nix.auto.tfvars"

    # Apply infrastructure
    log_info "Applying Terraform infrastructure..."
    run_terraform -chdir="$TERRAFORM_DIR" init -input=false
    run_terraform -chdir="$TERRAFORM_DIR" apply

    echo ""
    log_info "Infra phase complete!"
    echo ""
    run_terraform -chdir="$TERRAFORM_DIR" output
}

# ============================================================================
# Shared: SSH setup
# ============================================================================
setup_ssh() {
    # Skip if already set up
    [[ -n "${INSTANCE_IP:-}" ]] && return 0

    INSTANCE_IP=$(run_terraform -chdir="$TERRAFORM_DIR" output -raw instance_public_ip 2>/dev/null || echo "")
    if [[ -z "$INSTANCE_IP" ]]; then
        log_error "Could not get instance IP. Run infra phase first."
        exit 1
    fi
    log_info "Instance IP: $INSTANCE_IP"

    SSH_KEY_FILE=$(mktemp)
    trap "rm -f '$SSH_KEY_FILE'" EXIT
    if ! run_terraform -chdir="$TERRAFORM_DIR" output -raw private_key > "$SSH_KEY_FILE" 2>/dev/null; then
        log_error "Could not extract private key from Terraform."
        exit 1
    fi
    chmod 600 "$SSH_KEY_FILE"
    SSH_OPTS="-i $SSH_KEY_FILE -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new"
}

# ============================================================================
# Phase: deploy
# ============================================================================
phase_deploy() {
    log_step "Phase: deploy"
    setup_ssh

    # Wait for SSH to be available
    log_info "Waiting for SSH to be available..."
    local max_attempts=30
    local attempt=1
    while ! ssh $SSH_OPTS "root@${INSTANCE_IP}" true 2>/dev/null; do
        if [[ $attempt -ge $max_attempts ]]; then
            log_error "SSH not available after $max_attempts attempts"
            exit 1
        fi
        echo -ne "\r${BLUE}[WAIT]${NC} Attempt $attempt/$max_attempts...    "
        sleep 10
        ((attempt++))
    done
    echo ""
    log_info "SSH connection established!"

    # Build and deploy via nixos-rebuild
    log_info "Deploying NixOS configuration..."
    log_verbose "Command: NIX_SSHOPTS=\"$SSH_OPTS\" nixos-rebuild switch $NIX_VERBOSE --flake .#mail-server --target-host root@${INSTANCE_IP} $OVERRIDE_ARG"

    # nixos-rebuild uses NIX_SSHOPTS for SSH options
    # This passes the private key to all SSH connections (nix copy, activation, etc.)
    NIX_SSHOPTS="$SSH_OPTS" nixos-rebuild switch \
        $NIX_VERBOSE \
        --flake ".#mail-server" \
        --target-host "root@${INSTANCE_IP}" \
        $OVERRIDE_ARG

    echo ""
    log_info "Deploy phase complete!"
}

# ============================================================================
# Phase: e2e
# ============================================================================

# Wait for a systemd unit to be ready. Prints logs and returns 1 on failure.
# For long-running services, "active" means ready.
# For oneshot units, "inactive" with Result=success means completed successfully.
wait_for_unit() {
    local unit="$1"
    local max_attempts="${2:-30}"
    local attempt=1

    log_info "Waiting for $unit to finish..."
    while true; do
        local state result
        state=$(ssh $SSH_OPTS "root@${INSTANCE_IP}" \
            "systemctl is-active $unit 2>/dev/null || true" 2>/dev/null)
        state="${state:-unknown}"
        result=$(ssh $SSH_OPTS "root@${INSTANCE_IP}" \
            "systemctl show -p Result --value $unit 2>/dev/null" 2>/dev/null || echo "")

        case "$state" in
            active)
                log_info "$unit is active."
                return 0
                ;;
            inactive)
                # Oneshot units go inactive after completion — check Result
                if [[ "$result" == "success" ]]; then
                    log_info "$unit completed successfully."
                    return 0
                fi
                log_error "$unit is inactive (Result=$result)"
                log_error "--- journalctl for $unit ---"
                ssh $SSH_OPTS "root@${INSTANCE_IP}" \
                    "journalctl -u $unit --no-pager -n 50" 2>/dev/null || true
                log_error "--- end logs ---"
                return 1
                ;;
            failed)
                log_error "$unit failed (Result=$result)"
                log_error "--- journalctl for $unit ---"
                ssh $SSH_OPTS "root@${INSTANCE_IP}" \
                    "journalctl -u $unit --no-pager -n 50" 2>/dev/null || true
                log_error "--- end logs ---"
                return 1
                ;;
            activating)
                # still running, wait
                ;;
        esac

        if [[ $attempt -ge $max_attempts ]]; then
            log_error "$unit did not finish after $max_attempts attempts (last state: $state)"
            ssh $SSH_OPTS "root@${INSTANCE_IP}" \
                "journalctl -u $unit --no-pager -n 50" 2>/dev/null || true
            return 1
        fi

        echo -ne "\r${BLUE}[WAIT]${NC} $unit: $state (attempt $attempt/$max_attempts)...    "
        sleep 10
        ((attempt++))
    done
}

# Wait for a TCP port to accept connections.
wait_for_port() {
    local host="$1"
    local port="$2"
    local max_attempts="${3:-18}"
    local attempt=1

    log_info "Waiting for $host:$port to open..."
    while ! ssh $SSH_OPTS "root@${INSTANCE_IP}" "ss -tln | grep -q ':${port} '" 2>/dev/null; do
        if [[ $attempt -ge $max_attempts ]]; then
            log_error "$host:$port not open after $max_attempts attempts"
            return 1
        fi
        echo -ne "\r${BLUE}[WAIT]${NC} $host:$port (attempt $attempt/$max_attempts)...    "
        sleep 10
        ((attempt++))
    done
    log_info "$host:$port is open."
    return 0
}

# Escape a string for use inside IMAP double-quoted strings in a bash heredoc.
# IMAP requires: \ -> \\, " -> \"
imap_quote() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

# Shared credentials for e2e tests
E2E_USER=""
E2E_EMAIL=""
E2E_PASSWORD=""

# Gather and validate credentials for e2e tests
gather_credentials() {
    log_info "=== Gathering credentials for e2e tests ==="

    # Auto-pick first user from config accounts directory
    local accounts_dir="${PROJECT_DIR}/${CONFIG_DIR}/accounts"
    if [[ ! -d "$accounts_dir" ]]; then
        log_error "No accounts directory found at $accounts_dir"
        return 1
    fi

    E2E_USER=$(ls "$accounts_dir" | head -1)
    if [[ -z "$E2E_USER" ]]; then
        log_error "No accounts found in $accounts_dir"
        return 1
    fi

    E2E_EMAIL="${E2E_USER}@${DOMAIN}"
    log_info "Using account: $E2E_EMAIL"

    # Wait for IMAP service to be ready for credential validation
    if ! wait_for_unit "podman-dovecot.service" 18; then
        log_error "Dovecot service not ready."
        return 1
    fi
    if ! wait_for_port "$HOSTNAME" 993 18; then
        log_error "IMAP port 993 not open."
        return 1
    fi

    # Password prompt loop (up to 3 attempts)
    local max_pw_attempts=3
    local pw_attempt=0

    while [[ $pw_attempt -lt $max_pw_attempts ]]; do
        ((pw_attempt++))
        echo -n "Enter password for $E2E_EMAIL (attempt $pw_attempt/$max_pw_attempts): "
        read -rs E2E_PASSWORD
        echo ""

        if [[ -z "$E2E_PASSWORD" ]]; then
            log_warn "Password cannot be empty."
            continue
        fi

        # Validate credentials via IMAP LOGIN
        local imap_response
        local q_user q_pass
        q_user=$(imap_quote "$E2E_USER")
        q_pass=$(imap_quote "$E2E_PASSWORD")
        imap_response=$(run_openssl s_client -connect "${HOSTNAME}:993" -quiet 2>/dev/null <<IMAP_EOF
a1 LOGIN "$q_user" "$q_pass"
a2 LOGOUT
IMAP_EOF
        ) || true

        if echo "$imap_response" | grep -q "a1 OK"; then
            log_info "IMAP authentication successful."
            return 0
        else
            log_warn "IMAP authentication failed."
            E2E_PASSWORD=""
        fi
    done

    log_error "Failed to authenticate after $max_pw_attempts attempts."
    return 1
}

test_acme() {
    log_info "=== ACME certificate tests ==="
    local failed=0

    # DNS resolution (with retries for propagation)
    log_info "Checking DNS resolution for $HOSTNAME..."
    local dns_ok=false
    local dns_attempts=18
    for ((i=1; i<=dns_attempts; i++)); do
        RESOLVED_IP=$(run_dig +short "$HOSTNAME" @8.8.8.8 | tail -1)
        if [[ "$RESOLVED_IP" == "$INSTANCE_IP" ]]; then
            dns_ok=true
            break
        fi
        echo -ne "\r${BLUE}[WAIT]${NC} DNS: ${RESOLVED_IP:-<empty>} != $INSTANCE_IP (attempt $i/$dns_attempts)...    "
        sleep 10
    done
    if $dns_ok; then
        log_info "DNS OK: $HOSTNAME -> $RESOLVED_IP"
    else
        log_error "DNS mismatch: $HOSTNAME -> ${RESOLVED_IP:-<empty>} (expected $INSTANCE_IP)"
        return 1
    fi

    # ACME cert exists (wait for acme systemd unit)
    log_info "Checking ACME certificate..."
    if ! wait_for_unit "acme-order-renew-${HOSTNAME}.service" 30; then
        log_error "ACME service failed — cannot verify certificate."
        return 1
    fi

    if ! ssh $SSH_OPTS "root@${INSTANCE_IP}" "test -f /data/certs/fullchain.pem" 2>/dev/null; then
        log_error "No certificate found at /data/certs/fullchain.pem"
        return 1
    fi

    # Validate certificate subject matches hostname
    local cert_cn
    cert_cn=$(ssh $SSH_OPTS "root@${INSTANCE_IP}" \
        "openssl x509 -noout -subject -nameopt multiline -in /data/certs/fullchain.pem | grep commonName | sed 's/.*= //'" 2>/dev/null || echo "")
    if [[ "$cert_cn" == "$HOSTNAME" ]]; then
        log_info "Certificate CN OK: $cert_cn"
    else
        log_error "Certificate CN mismatch: got '${cert_cn:-<empty>}', expected '$HOSTNAME'"
        failed=1
    fi

    # Check certificate issuer
    local cert_issuer
    cert_issuer=$(ssh $SSH_OPTS "root@${INSTANCE_IP}" \
        "openssl x509 -noout -issuer -in /data/certs/fullchain.pem" 2>/dev/null || echo "")
    log_info "Certificate issuer: $cert_issuer"
    if echo "$cert_issuer" | grep -qi "Let's Encrypt"; then
        log_info "Certificate issuer OK: Let's Encrypt"
    else
        log_error "Certificate not issued by Let's Encrypt"
        failed=1
    fi

    # Read file fingerprint (used by TLS checks below)
    local file_fp
    file_fp=$(ssh $SSH_OPTS "root@${INSTANCE_IP}" \
        "openssl x509 -noout -fingerprint -sha256 -in /data/certs/fullchain.pem | cut -d= -f2" 2>/dev/null || echo "")

    # SMTP serves correct cert (port 587, STARTTLS)
    log_info "Checking SMTP TLS certificate..."
    if wait_for_unit "podman-opensmtpd.service" 18 && wait_for_port "$HOSTNAME" 587 18; then
        local smtp_fp
        smtp_fp=$(run_openssl s_client -connect "${HOSTNAME}:587" -starttls smtp </dev/null 2>/dev/null | \
            sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' | \
            run_openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 || echo "")
        if [[ -n "$file_fp" && "$file_fp" == "$smtp_fp" ]]; then
            log_info "SMTP TLS OK: certificate matches"
        else
            log_error "SMTP TLS mismatch: file=${file_fp:-<empty>} smtp=${smtp_fp:-<empty>}"
            failed=1
        fi
    else
        log_error "SMTP service/port not ready — skipping TLS check."
        failed=1
    fi

    # IMAP serves correct cert (port 993, direct TLS)
    log_info "Checking IMAP TLS certificate..."
    if wait_for_unit "podman-dovecot.service" 18 && wait_for_port "$HOSTNAME" 993 18; then
        local imap_fp
        imap_fp=$(run_openssl s_client -connect "${HOSTNAME}:993" </dev/null 2>/dev/null | \
            sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' | \
            run_openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 || echo "")
        if [[ -n "$file_fp" && "$file_fp" == "$imap_fp" ]]; then
            log_info "IMAP TLS OK: certificate matches"
        else
            log_error "IMAP TLS mismatch: file=${file_fp:-<empty>} imap=${imap_fp:-<empty>}"
            failed=1
        fi
    else
        log_error "IMAP service/port not ready — skipping TLS check."
        failed=1
    fi

    return $failed
}

test_mail() {
    log_info "=== Mail send/receive test ==="

    # Wait for SMTP service
    if ! wait_for_unit "podman-opensmtpd.service" 18; then
        log_error "OpenSMTPd service not ready."
        return 1
    fi
    if ! wait_for_port "$HOSTNAME" 587 18; then
        log_error "SMTP submission port 587 not open."
        return 1
    fi

    # Send test email via authenticated SMTP submission
    local test_subject="deploy-test-$(date +%s)"
    log_info "Sending test email with subject: $test_subject"

    if ! run_swaks \
        --to "$E2E_EMAIL" \
        --from "$E2E_EMAIL" \
        --server "$HOSTNAME" \
        --port 587 \
        -tls \
        --auth-user "$E2E_USER" \
        --auth-password "$E2E_PASSWORD" \
        --header "Subject: $test_subject" \
        --body "E2E test from deploy.sh"; then
        log_error "swaks SMTP send failed."
        return 1
    fi
    log_info "Test email sent."

    # Wait briefly for delivery
    sleep 15

    # Verify receipt via IMAP
    log_info "Checking IMAP for delivered message..."
    local imap_search
    local q_user q_pass
    q_user=$(imap_quote "$E2E_USER")
    q_pass=$(imap_quote "$E2E_PASSWORD")
    imap_search=$(run_openssl s_client -connect "${HOSTNAME}:993" -quiet 2>/dev/null <<IMAP_EOF
a1 LOGIN "$q_user" "$q_pass"
a2 SELECT INBOX
a3 SEARCH SUBJECT "$test_subject"
a4 LOGOUT
IMAP_EOF
    ) || true

    if echo "$imap_search" | grep -q "^\* SEARCH [0-9]"; then
        log_info "Mail delivery verified: message found in INBOX."
    else
        log_error "Mail delivery verification failed: message not found in INBOX."
        log_error "IMAP response:"
        echo "$imap_search"
        return 1
    fi

    log_info "Mail send/receive test passed!"
    return 0
}

test_dkim() {
    log_info "=== DKIM verification tests ==="

    if [[ "$DKIM_ENABLE" != "true" ]]; then
        log_info "DKIM is disabled in config, skipping DKIM tests."
        return 0
    fi

    local dkim_record="${DKIM_SELECTOR}._domainkey.${DOMAIN}"
    local failed=0

    # Wait for DKIM key manager service
    log_info "Checking DKIM key manager service..."
    if ! wait_for_unit "dkim-key-manager.service" 30; then
        log_error "DKIM key manager service failed."
        return 1
    fi

    # Verify DKIM key files exist
    log_info "Checking DKIM key files..."
    if ! ssh $SSH_OPTS "root@${INSTANCE_IP}" "test -f /data/rspamd/dkim/${DOMAIN}.${DKIM_SELECTOR}.key" 2>/dev/null; then
        log_error "DKIM private key not found at /data/rspamd/dkim/${DOMAIN}.${DKIM_SELECTOR}.key"
        return 1
    fi
    if ! ssh $SSH_OPTS "root@${INSTANCE_IP}" "test -f /data/rspamd/dkim/${DOMAIN}.${DKIM_SELECTOR}.txt" 2>/dev/null; then
        log_error "DKIM TXT record file not found at /data/rspamd/dkim/${DOMAIN}.${DKIM_SELECTOR}.txt"
        return 1
    fi
    log_info "DKIM key files exist."

    # Check DNS for DKIM TXT record (with retries for propagation)
    log_info "Checking DNS for DKIM TXT record: $dkim_record"
    local dns_ok=false
    local dns_attempts=18
    local txt_value=""
    for ((i=1; i<=dns_attempts; i++)); do
        txt_value=$(run_dig +short TXT "$dkim_record" @8.8.8.8 2>/dev/null | tr -d '"' || echo "")
        if [[ -n "$txt_value" ]]; then
            dns_ok=true
            break
        fi
        echo -ne "\r${BLUE}[WAIT]${NC} DNS TXT record not found yet (attempt $i/$dns_attempts)...    "
        sleep 10
    done
    echo ""

    if $dns_ok; then
        log_info "DKIM DNS record found: $dkim_record"
        log_verbose "TXT value: $txt_value"
    else
        log_error "DKIM DNS record not found: $dkim_record"
        log_error "Expected Route53 to have created the TXT record automatically."
        return 1
    fi

    # Verify TXT record format
    log_info "Validating DKIM TXT record format..."
    if ! echo "$txt_value" | grep -q "v=DKIM1"; then
        log_error "DKIM TXT record missing 'v=DKIM1'"
        failed=1
    fi
    if ! echo "$txt_value" | grep -q "k=rsa"; then
        log_error "DKIM TXT record missing 'k=rsa'"
        failed=1
    fi
    if ! echo "$txt_value" | grep -q "p="; then
        log_error "DKIM TXT record missing public key 'p='"
        failed=1
    fi
    if [[ $failed -eq 0 ]]; then
        log_info "DKIM TXT record format is valid."
    fi

    # Verify public key in DNS matches private key on server
    log_info "Verifying DKIM public key matches private key..."
    local server_pubkey dns_pubkey

    # Extract public key from private key on server (base64, no headers, no newlines)
    server_pubkey=$(ssh $SSH_OPTS "root@${INSTANCE_IP}" \
        "openssl rsa -in /data/rspamd/dkim/${DOMAIN}.${DKIM_SELECTOR}.key -pubout 2>/dev/null" \
        | grep -v '^-' | tr -d '\n')

    # Extract public key from DNS TXT record (the p= value, strip any trailing junk)
    dns_pubkey=$(echo "$txt_value" | sed 's/.*p=//' | sed 's/[^A-Za-z0-9+/=].*//' | tr -d ' ')

    if [[ -z "$server_pubkey" ]]; then
        log_error "Could not extract public key from server private key"
        failed=1
    elif [[ -z "$dns_pubkey" ]]; then
        log_error "Could not extract public key from DNS TXT record"
        failed=1
    elif [[ "$server_pubkey" == "$dns_pubkey" ]]; then
        log_info "DKIM public keys match between server and DNS"
    else
        log_error "DKIM public key MISMATCH!"
        log_error "Server public key: $server_pubkey"
        log_error "DNS public key:    $dns_pubkey"
        failed=1
    fi

    # Send test email and verify DKIM signature
    log_info "Sending test email to verify DKIM signature..."

    # Wait for services
    if ! wait_for_unit "podman-opensmtpd.service" 18; then
        log_error "OpenSMTPd service not ready."
        return 1
    fi
    if ! wait_for_unit "podman-rspamd.service" 18; then
        log_error "Rspamd service not ready."
        return 1
    fi

    # Send authenticated email
    local test_subject="dkim-test-$(date +%s)"
    log_info "Sending DKIM test email with subject: $test_subject"

    if ! run_swaks \
        --to "$E2E_EMAIL" \
        --from "$E2E_EMAIL" \
        --server "$HOSTNAME" \
        --port 587 \
        -tls \
        --auth-user "$E2E_USER" \
        --auth-password "$E2E_PASSWORD" \
        --header "Subject: $test_subject" \
        --body "DKIM signature test from deploy.sh"; then
        log_error "swaks SMTP send failed."
        return 1
    fi

    # Wait for delivery
    sleep 15

    # Fetch the message via IMAP and check for DKIM signature
    log_info "Fetching message to verify DKIM signature..."

    local q_user q_pass
    q_user=$(imap_quote "$E2E_USER")
    q_pass=$(imap_quote "$E2E_PASSWORD")

    # Search for the message and get its UID
    local imap_search
    imap_search=$(run_openssl s_client -connect "${HOSTNAME}:993" -quiet 2>/dev/null <<IMAP_EOF
a1 LOGIN "$q_user" "$q_pass"
a2 SELECT INBOX
a3 SEARCH SUBJECT "$test_subject"
a4 LOGOUT
IMAP_EOF
    ) || true

    local msg_uid
    msg_uid=$(echo "$imap_search" | tr -d '\r' | grep "^\* SEARCH" | sed 's/\* SEARCH //' | awk '{print $1}')

    if [[ -z "$msg_uid" ]]; then
        log_error "Could not find test message in INBOX."
        return 1
    fi

    log_verbose "Fetching message UID: $msg_uid"

    # Fetch the message headers
    local msg_headers
    msg_headers=$(run_openssl s_client -connect "${HOSTNAME}:993" -quiet 2>/dev/null <<IMAP_EOF
a1 LOGIN "$q_user" "$q_pass"
a2 SELECT INBOX
a3 FETCH ${msg_uid} BODY[HEADER]
a4 LOGOUT
IMAP_EOF
    ) || true

    # Check for DKIM-Signature header
    if echo "$msg_headers" | grep -q "DKIM-Signature:"; then
        log_info "DKIM-Signature header found in message."
    else
        log_error "DKIM-Signature header NOT found in message."
        log_error "Message headers:"
        echo "$msg_headers" | head -50
        return 1
    fi

    # Verify DKIM signature contains correct domain and selector
    if echo "$msg_headers" | grep -q "d=${DOMAIN}"; then
        log_info "DKIM signature has correct domain: d=${DOMAIN}"
    else
        log_error "DKIM signature missing correct domain (d=${DOMAIN})"
        failed=1
    fi

    if echo "$msg_headers" | grep -q "s=${DKIM_SELECTOR}"; then
        log_info "DKIM signature has correct selector: s=${DKIM_SELECTOR}"
    else
        log_error "DKIM signature missing correct selector (s=${DKIM_SELECTOR})"
        failed=1
    fi

    if [[ $failed -eq 0 ]]; then
        log_info "DKIM verification tests passed!"
    fi

    return $failed
}

test_mail_dns() {
    log_info "=== Mail DNS record verification (SPF/DMARC) ==="

    local failed=0

    # Check if SPF is enabled
    local spf_enabled
    spf_enabled=$(nix eval $NIX_VERBOSE .#lib.mailDns.spfEnabled $OVERRIDE_ARG 2>/dev/null || echo "false")

    # Check if DMARC is enabled
    local dmarc_enabled
    dmarc_enabled=$(nix eval $NIX_VERBOSE .#lib.mailDns.dmarcEnabled $OVERRIDE_ARG 2>/dev/null || echo "false")

    # Verify SPF record
    if [ "$spf_enabled" = "true" ]; then
        log_info "Verifying SPF record..."

        # Build and read the expected SPF record
        local spf_drv
        spf_drv=$(nix build --no-link --print-out-paths $NIX_VERBOSE .#lib.mailDns.spfRecord $OVERRIDE_ARG 2>/dev/null)
        local expected_spf
        expected_spf=$(cat "$spf_drv")

        # Query actual SPF from DNS (with retries for propagation)
        local actual_spf=""
        local spf_attempts=18
        for ((i=1; i<=spf_attempts; i++)); do
            # SPF records are TXT records at the domain root
            # dig returns quoted strings, tr -d removes the quotes
            actual_spf=$(run_dig +short TXT "$DOMAIN" @8.8.8.8 2>/dev/null | grep "v=spf1" | tr -d '"' || echo "")
            if [[ -n "$actual_spf" ]]; then
                break
            fi
            echo -ne "\r${BLUE}[WAIT]${NC} SPF TXT record not found yet (attempt $i/$spf_attempts)...    "
            sleep 10
        done
        echo ""

        log_info "Expected SPF: $expected_spf"
        log_info "Actual SPF:   $actual_spf"

        if [ "$actual_spf" = "$expected_spf" ]; then
            log_info "SPF record matches"
        else
            log_error "SPF record mismatch!"
            failed=1
        fi
    else
        log_info "SPF disabled, skipping verification"
    fi

    # Verify DMARC record
    if [ "$dmarc_enabled" = "true" ]; then
        log_info "Verifying DMARC record..."

        # Build and read the expected DMARC record
        local dmarc_drv
        dmarc_drv=$(nix build --no-link --print-out-paths $NIX_VERBOSE .#lib.mailDns.dmarcRecord $OVERRIDE_ARG 2>/dev/null)
        local expected_dmarc
        expected_dmarc=$(cat "$dmarc_drv")

        # Query actual DMARC from DNS (with retries for propagation)
        local actual_dmarc=""
        local dmarc_attempts=18
        for ((i=1; i<=dmarc_attempts; i++)); do
            # DMARC records are TXT records at _dmarc.<domain>
            actual_dmarc=$(run_dig +short TXT "_dmarc.$DOMAIN" @8.8.8.8 2>/dev/null | tr -d '"' || echo "")
            if [[ -n "$actual_dmarc" ]]; then
                break
            fi
            echo -ne "\r${BLUE}[WAIT]${NC} DMARC TXT record not found yet (attempt $i/$dmarc_attempts)...    "
            sleep 10
        done
        echo ""

        log_info "Expected DMARC: $expected_dmarc"
        log_info "Actual DMARC:   $actual_dmarc"

        if [ "$actual_dmarc" = "$expected_dmarc" ]; then
            log_info "DMARC record matches"
        else
            log_error "DMARC record mismatch!"
            failed=1
        fi
    else
        log_info "DMARC disabled, skipping verification"
    fi

    if [[ $failed -eq 0 ]]; then
        log_info "Mail DNS verification passed!"
    fi

    return $failed
}

phase_e2e() {
    log_step "Phase: e2e"
    setup_ssh

    local failed=0

    test_acme || failed=1
    test_mail_dns || failed=1

    # Gather credentials once for mail and DKIM tests
    if ! gather_credentials; then
        log_error "Failed to gather credentials, skipping mail and DKIM tests."
        exit 1
    fi

    test_mail || failed=1
    test_dkim || failed=1

    # Summary
    if [[ $failed -eq 0 ]]; then
        log_info "All e2e checks passed!"
    else
        log_error "Some e2e checks failed."
        exit 1
    fi
}

# ============================================================================
# Main Execution
# ============================================================================
echo ""
echo "=========================================="
echo "  Mail Server Deployment"
echo "=========================================="
echo "  Config:   $CONFIG_NAME"
echo "  Domain:   $DOMAIN"
echo "  Hostname: $HOSTNAME"
echo "  Arch:     $ARCH ($AWS_ARCH)"
echo "  Region:   $AWS_REGION"
echo "=========================================="
echo ""

# Phase: test
if should_run_phase "test"; then
    phase_test
else
    log_info "Skipping test phase"
fi

# Phase: infra
if should_run_phase "infra"; then
    phase_infra
else
    log_info "Skipping infra phase"
fi

# Phase: deploy
if should_run_phase "deploy"; then
    phase_deploy
else
    log_info "Skipping deploy phase"
fi

# Phase: e2e
if should_run_phase "e2e"; then
    phase_e2e
else
    log_info "Skipping e2e phase"
fi

echo ""
log_info "Deployment complete!"
