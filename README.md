# NixOS Mail Server

A reproducible, containerized mail server deployed to AWS EC2 using NixOS and Terraform.

I originally set this up on an EC2 instance by hand, following [Gilles Chehade's excellent guide](https://poolp.org/posts/2019-09-14/setting-up-a-mail-server-with-opensmtpd-dovecot-and-rspamd/).
That original setup was rock solid and I used it for 5 years without incident.

I created this repo to try out using Claude and see if together we could recreate the setup with some improved security, automation, and monitoring.
I intend to write a blogpost soon with more discussion on my experience, but overall it was very positive!
As you can see the project was quickly and successfully completed.

Maybe I'll make a version 3 in another 5 years, haha.

## Features

- **Full mail stack**: OpenSMTPd (SMTP), Dovecot (IMAP), Rspamd (spam filtering), Redis (Rspamd backend)
- **Containerized services**: Each service runs in an isolated Podman container with restricted network access
- **Reproducible builds**: All container images built with Nix, pinned dependencies via flake.lock
- **Automated DNS**: SPF, DMARC, DKIM, and SRV records managed via Terraform/Route53
- **TLS certificates**: Automatic Let's Encrypt certificates via ACME
- **Monitoring**: Monit alerts for disk space, memory, container health, and OOM detection
- **Automated backups**: Daily and weekly EBS snapshots via AWS Data Lifecycle Manager
- **Spam learning**: Move mail to/from Junk folder to train Rspamd's Bayes filter

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        AWS EC2 (NixOS)                      │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐          │
│  │  OpenSMTPd  │──│   Rspamd    │──│   Redis     │          │
│  │  (SMTP)     │  │  (filter)   │  │  (backend)  │          │
│  └─────────────┘  └─────────────┘  └─────────────┘          │
│         │                │                                  │
│         │         ┌──────┴──────┐                           │
│         └────────▶│   Dovecot   │◀── IMAP clients           │
│                   │   (IMAP)    │                           │
│                   └─────────────┘                           │
│                          │                                  │
│                   ┌──────┴──────┐                           │
│                   │  /data/mail │  (EBS volume)             │
│                   └─────────────┘                           │
└─────────────────────────────────────────────────────────────┘
```

## Prerequisites

- [Nix](https://nixos.org/download.html) with flakes enabled
- AWS account with credentials configured (`aws configure`)
- A domain with DNS managed by Route53 (or willingness to delegate to Route53)

## Quick Start

### 1. Create a configuration

```bash
# Copy the default config
mkdir -p config/myserver
cp config/default-x86_64/mail-server.nix config/myserver/

# Edit with your settings
$EDITOR config/myserver/mail-server.nix
```

Key settings to change:
- `domain` - Your email domain (e.g., "example.com")
- `hostname` - Mail server hostname (e.g., "mail.example.com")
- `acme.email` - Contact email for Let's Encrypt
- `aws.region` - AWS region
- `aws.route53.zoneId` - Your Route53 hosted zone ID

### 2. Create mail accounts

```bash
./scripts/create-account.sh -c myserver
# Follow prompts to enter username and password
```

### 3. Deploy

```bash
# Full deployment (test → infrastructure → NixOS config → e2e validation)
./scripts/deploy.sh -c myserver

# Or run phases individually:
./scripts/deploy.sh -c myserver -o test    # Run tests only
./scripts/deploy.sh -c myserver -o infra   # Terraform only
./scripts/deploy.sh -c myserver -o deploy  # NixOS rebuild only
./scripts/deploy.sh -c myserver -o e2e     # End-to-end validation only
```

### 4. Configure DNS

If using an existing Route53 zone, DNS records are created automatically. Otherwise, update your domain's nameservers to point to the Route53 zone created by Terraform.

Required DNS records (created automatically):
- `A` record for mail server hostname
- `MX` record for domain (when `aws.route53.createMX = true`)
- `SRV` records for auto-discovery (when `aws.route53.createSRV = true`)
- `TXT` record for SPF
- `TXT` record for DMARC (`_dmarc.domain`)
- `TXT` record for DKIM (`selector._domainkey.domain`)

## Configuration Reference

```nix
{
  # Mail settings
  domain = "example.com";
  hostname = "mail.example.com";

  aliases = {
    "postmaster" = "admin";
    "abuse" = "admin";
  };

  # DKIM - use dated selector for key rotation
  dkim = {
    enable = true;
    selector = "mail2025";
  };

  # SPF - who can send mail for your domain
  spf = {
    enable = true;
    mechanisms.mx = true;      # Allow MX hosts
    mechanisms.a = false;      # Allow A record
    mechanisms.ip4 = [];       # Additional IPv4
    mechanisms.include = [];   # Include other SPF records
    qualifier = "-all";        # Hard fail others
  };

  # DMARC - policy for failed authentication
  dmarc = {
    enable = true;
    policy = "reject";         # none, quarantine, reject
    rua = "mailto:dmarc@example.com";  # Aggregate reports
  };

  # Let's Encrypt
  acme = {
    email = "admin@example.com";
    staging = false;  # Set true for testing
  };

  # Monit alerts
  alertEmail = "postmaster";  # Or "" to disable

  # Architecture
  architecture = "x86_64-linux";  # or "aarch64-linux"

  # AWS settings
  aws = {
    project = "my-mail-server";
    region = "us-west-2";
    instanceType = "t3.nano";
    rootVolumeSize = 8;
    dataVolumeSize = 10;
    swapSize = 1;
    adminCidr = "auto";  # Or "1.2.3.4/32"

    route53 = {
      zoneId = "";       # Existing zone ID, or "" to create new
      createMX = false;  # Set true when ready to receive mail
      createSRV = false; # SRV records for email auto-discovery (RFC 6186)
    };

    # Elastic IP for static IP / rDNS (optional)
    eipAllocationId = "";  # e.g., "eipalloc-0123456789abcdef0"

    # Pin AMI and AZ after initial deploy to prevent instance/volume recreation
    # Get values with: aws ec2 describe-instances
    amiId = "";              # e.g., "ami-0123456789abcdef0"
    availabilityZone = "";   # e.g., "us-west-2a"

    backup = {
      enable = true;
      time = "03:00";      # UTC
      daily.retain = 7;
      weekly.retain = 4;
    };
  };

  # Container memory limits (MB)
  resources = {
    opensmtpd.memory = 192;
    dovecot.memory = 192;
    rspamd.memory = 384;
    redis.memory = 192;
  };
}
```

## Scripts

| Script | Description |
|--------|-------------|
| `deploy.sh` | Main deployment script (test, infra, deploy, e2e phases) |
| `create-account.sh` | Create mail user accounts |
| `ssh.sh` | SSH to mail server using Terraform credentials |
| `terraform.sh` | Run Terraform commands |
| `migrate-mail.sh` | Migrate mail from another server |

### Examples

```bash
# SSH to server
./scripts/ssh.sh

# Run command on server
./scripts/ssh.sh "systemctl status podman-opensmtpd"

# Terraform commands
./scripts/terraform.sh plan
./scripts/terraform.sh apply
./scripts/terraform.sh state list

# Migrate mail from old server
./scripts/migrate-mail.sh --source user@old.server.com --user alice --sudo
```

## Testing

```bash
# Run all tests
nix flake check

# Run specific test
nix build .#checks.x86_64-linux.mail-server-integration --print-build-logs
```

Available tests:
- `mail-server-integration` - Full stack integration test
- `opensmtpd-test` - OpenSMTPd standalone
- `dovecot-test` - Dovecot standalone
- `rspamd-test` - Rspamd spam filtering
- `monit-test` - Monitoring alerts

## Operations

### Viewing logs

```bash
./scripts/ssh.sh "journalctl -u podman-opensmtpd -f"
./scripts/ssh.sh "journalctl -u podman-dovecot -f"
./scripts/ssh.sh "journalctl -u podman-rspamd -f"
```

### Container management

```bash
./scripts/ssh.sh "podman ps"
./scripts/ssh.sh "podman logs opensmtpd"
./scripts/ssh.sh "podman exec -it dovecot doveadm mailbox list -u alice"
```

### Monit status

```bash
./scripts/ssh.sh "monit status"
./scripts/ssh.sh "monit summary"
```

### DKIM key rotation

1. Update `dkim.selector` in config (e.g., "mail2026")
2. Redeploy: `./scripts/deploy.sh -c myserver -o deploy`
3. New DKIM key auto-generated and DNS record created
4. Old selector continues working until you remove it from DNS

### Spam training

- Move spam to Junk folder → trains Rspamd to recognize spam
- Move ham out of Junk folder → trains Rspamd to recognize legitimate mail

## Project Structure

```
├── config/                  # Server configurations
│   ├── default-x86_64/     # Default x86_64 config
│   ├── default-aarch64/    # Default ARM64 config
│   └── <your-config>/      # Your custom config
├── nix/
│   ├── containers/         # Container image definitions
│   ├── nixos/              # NixOS modules
│   └── tests/              # NixOS VM tests
├── scripts/                # Deployment and utility scripts
├── terraform/              # AWS infrastructure
└── flake.nix              # Nix flake definition
```

## Security

- All containers run with restricted network access
- Redis only accessible by Rspamd (isolated network)
- Dovecot egress blocked (no outbound connections)
- Rspamd egress limited to DNS and rspamd.com (fuzzy hashes)
- SSH restricted to admin CIDR
- All EBS volumes encrypted
- TLS enforced for SMTP submission and IMAP

## License

GPL v3
