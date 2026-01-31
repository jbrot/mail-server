#!/usr/bin/env bash
# Run terraform commands using the pinned version from our flake
# Usage: ./scripts/terraform.sh <command> [args...]
#
# Examples:
#   ./scripts/terraform.sh plan
#   ./scripts/terraform.sh apply
#   ./scripts/terraform.sh apply -replace="aws_ebs_volume.data"
#   ./scripts/terraform.sh state list

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="${PROJECT_DIR}/terraform"

# Run terraform via nix using the pinned version from our flake
run_terraform() {
    nix run --quiet .#terraform -- "$@"
}

if [[ $# -eq 0 ]]; then
    echo "Usage: $(basename "$0") <command> [args...]"
    echo ""
    echo "Examples:"
    echo "  $(basename "$0") plan"
    echo "  $(basename "$0") apply"
    echo "  $(basename "$0") apply -replace=\"aws_ebs_volume.data\""
    echo "  $(basename "$0") state list"
    exit 1
fi

# Initialize if needed (silent if already initialized)
run_terraform -chdir="$TERRAFORM_DIR" init -input=false > /dev/null 2>&1 || true

# Run terraform with provided arguments
run_terraform -chdir="$TERRAFORM_DIR" "$@"
