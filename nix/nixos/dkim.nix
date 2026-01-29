# DKIM key manager - generates keys on first boot and optionally creates Route53 TXT records
# nix/nixos/dkim.nix

{ config, lib, pkgs, ... }:

let
  cfg = config.services.dkimKeyManager;

  keyPath = "/data/rspamd/dkim/${cfg.domain}.${cfg.selector}.key";
  pubKeyPath = "/data/rspamd/dkim/${cfg.domain}.${cfg.selector}.txt";
  dnsRecordName = "${cfg.selector}._domainkey.${cfg.domain}";
in
{
  options.services.dkimKeyManager = {
    enable = lib.mkEnableOption "DKIM key manager";

    domain = lib.mkOption {
      type = lib.types.str;
      description = "Email domain for DKIM signing";
    };

    selector = lib.mkOption {
      type = lib.types.str;
      default = "mail";
      description = "DKIM selector";
    };

    route53 = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Create Route53 TXT record for DKIM public key";
      };

      zoneId = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Route53 hosted zone ID";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.dkim-key-manager = {
      description = "Generate DKIM key and optionally create Route53 record";
      wantedBy = [ "multi-user.target" ];
      before = [ "podman-rspamd.service" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      path = [ pkgs.rspamd pkgs.awscli2 pkgs.jq ];

      script = ''
        set -euo pipefail

        KEY_PATH="${keyPath}"
        PUB_PATH="${pubKeyPath}"
        SELECTOR="${cfg.selector}"
        DOMAIN="${cfg.domain}"
        DNS_RECORD="${dnsRecordName}"

        # Check if key already exists
        if [ -f "$KEY_PATH" ]; then
          echo "DKIM key already exists at $KEY_PATH"
          exit 0
        fi

        ${lib.optionalString cfg.route53.enable ''
        # Check if Route53 record already exists
        EXISTING=$(aws route53 list-resource-record-sets \
          --hosted-zone-id "${cfg.route53.zoneId}" \
          --query "ResourceRecordSets[?Name=='$DNS_RECORD.' && Type=='TXT']" \
          --output json)

        if [ "$(echo "$EXISTING" | jq 'length')" -gt 0 ]; then
          echo "ERROR: Route53 TXT record for $DNS_RECORD already exists!"
          echo "This means a DKIM key was previously generated but is now missing."
          echo "Either restore the key or use a different selector."
          exit 1
        fi
        ''}

        # Generate DKIM key
        echo "Generating DKIM key for $DOMAIN with selector $SELECTOR..."
        mkdir -p "$(dirname "$KEY_PATH")"
        rspamadm dkim_keygen -s "$SELECTOR" -d "$DOMAIN" \
          -k "$KEY_PATH" > "$PUB_PATH"

        # Fix permissions for rspamd container (UID 3000)
        chown 3000:3000 "$KEY_PATH" "$PUB_PATH"
        chmod 600 "$KEY_PATH"
        chmod 644 "$PUB_PATH"

        echo "DKIM key generated successfully"

        ${lib.optionalString cfg.route53.enable ''
        # Extract the full TXT record value from rspamadm output
        # The output format is: selector._domainkey.domain IN TXT ( "v=DKIM1; k=rsa; p=..." ) ;
        # We extract the quoted value(s) and use them directly
        TXT_VALUE=$(grep -oP '"\K[^"]+' "$PUB_PATH" | tr -d '\n')

        # Create Route53 TXT record
        echo "Creating Route53 TXT record for $DNS_RECORD..."
        aws route53 change-resource-record-sets \
          --hosted-zone-id "${cfg.route53.zoneId}" \
          --change-batch "{
            \"Changes\": [{
              \"Action\": \"CREATE\",
              \"ResourceRecordSet\": {
                \"Name\": \"$DNS_RECORD\",
                \"Type\": \"TXT\",
                \"TTL\": 3600,
                \"ResourceRecords\": [{
                  \"Value\": \"\\\"$TXT_VALUE\\\"\"
                }]
              }
            }]
          }"

        echo "Route53 TXT record created successfully"
        ''}
      '';
    };
  };
}
