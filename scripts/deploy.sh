#!/usr/bin/env bash
# Deploy script for mail server using nixos-rebuild
# Usage: ./scripts/deploy.sh [OPTIONS]
#
# Phases:
#   tests  - Run tests (nix flake check)
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
    tests   Run nix flake check
    infra   Generate tfvars from Nix config, run terraform apply
    deploy  Run nixos-rebuild switch --target-host
    e2e     Validate DNS, ACME certs, and TLS on deployed server

Available configs:
$(list_configs | sed 's/^/    /')

Examples:
    # Full deploy (all phases)
    ./scripts/deploy.sh -c production

    # Run tests only
    ./scripts/deploy.sh -o tests

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
        tests|infra|deploy|e2e) return 0 ;;
        *)
            log_error "Invalid phase: $phase"
            log_error "Valid phases are: tests, infra, deploy, e2e"
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

DOMAIN=$(read_nix_config "domain")
HOSTNAME=$(read_nix_config "hostname")
ARCH=$(read_nix_config "architecture")
AWS_REGION=$(read_nix_config "aws.region")
[[ -z "$ARCH" ]] && ARCH="x86_64-linux"

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

if is_default_config && { should_run_phase "infra" || should_run_phase "deploy"; }; then
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
# Phase: tests
# ============================================================================
phase_tests() {
    log_step "Phase: tests"

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

phase_e2e() {
    log_step "Phase: e2e"
    setup_ssh

    local failed=0

    test_acme || failed=1

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

# Phase: tests
if should_run_phase "tests"; then
    phase_tests
else
    log_info "Skipping tests phase"
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

if should_run_phase "deploy"; then
    INSTANCE_IP=$(run_terraform -chdir="$TERRAFORM_DIR" output -raw instance_public_ip 2>/dev/null || echo "<IP>")
    echo ""
    echo "Next steps:"
    echo "  1. Wait for ACME certificate (~5 min after boot)"
    echo "     ssh root@${INSTANCE_IP} 'systemctl status acme-${HOSTNAME}'"
    echo ""
    echo "  2. Generate DKIM key and add DNS record"
    echo "     ssh root@${INSTANCE_IP} 'rspamadm dkim_keygen -s mail -d ${DOMAIN}'"
    echo ""
    echo "  3. Test mail delivery"
    echo "     swaks --to test@${DOMAIN} --server ${INSTANCE_IP}"
fi
