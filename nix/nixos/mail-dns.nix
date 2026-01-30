# Mail DNS records module (SPF and DMARC)
# nix/nixos/mail-dns.nix
#
# Generates and validates SPF/DMARC record strings for Terraform.
# Uses `config.mailDns.*` namespace (not services, since this is computed config).
#
# Key design: spfRecord and dmarcRecord are derivations, not strings.
# Reading them (via builtins.readFile) forces validation to run first.

{ config, lib, pkgs, ... }:

let
  cfg = config.mailDns;

  # Build SPF record string from structured options
  spfString = let
    m = cfg.spf.mechanisms;
    # For 'a' mechanism: "" means bare 'a', non-empty means 'a:domain'
    formatA = a: if a == "" then "a" else "a:${a}";
    parts = [ "v=spf1" ]
      ++ lib.optional m.mx "mx"
      ++ map formatA m.a
      ++ map (ip: "ip4:${ip}") m.ip4
      ++ map (ip: "ip6:${ip}") m.ip6
      ++ map (d: "include:${d}") m.include
      ++ [ cfg.spf.qualifier ];
  in
    lib.concatStringsSep " " parts;

  # Build DMARC record string from structured options
  dmarcString = let
    d = cfg.dmarc;
    parts = [ "v=DMARC1" "p=${d.policy}" ]
      ++ lib.optional (d.subdomainPolicy != null) "sp=${d.subdomainPolicy}"
      ++ lib.optional (d.pct != 100) "pct=${toString d.pct}"
      ++ lib.optional (d.rua != null) "rua=${d.rua}"
      ++ lib.optional (d.ruf != null) "ruf=${d.ruf}";
  in
    lib.concatStringsSep "; " parts;

  # SPF record derivation: validates then outputs the string
  # Reading this derivation's output forces validation to run
  spfRecordDrv = pkgs.runCommand "spf-record" {
    nativeBuildInputs = [ pkgs.python3Packages.checkdmarc ];
  } ''
    python3 << 'EOF'
    from checkdmarc.spf import parse_spf_record

    spf = "${spfString}"
    domain = "${cfg.domain}"

    print(f"Validating SPF: {spf}", flush=True)
    parse_spf_record(spf, domain)
    print("SPF valid", flush=True)
    EOF

    # Output the validated string (no trailing newline)
    printf '%s' "${spfString}" > $out
  '';

  # DMARC record derivation: validates then outputs the string
  dmarcRecordDrv = pkgs.runCommand "dmarc-record" {
    nativeBuildInputs = [ pkgs.python3Packages.checkdmarc ];
  } ''
    python3 << 'EOF'
    from checkdmarc.dmarc import parse_dmarc_record

    dmarc = "${dmarcString}"
    domain = "${cfg.domain}"

    print(f"Validating DMARC: {dmarc}", flush=True)
    parse_dmarc_record(dmarc, domain)
    print("DMARC valid", flush=True)
    EOF

    # Output the validated string (no trailing newline)
    printf '%s' "${dmarcString}" > $out
  '';

in
{
  options.mailDns = {
    enable = lib.mkEnableOption "Mail DNS record generation (SPF/DMARC)";

    domain = lib.mkOption {
      type = lib.types.str;
      description = "Email domain for DNS records";
    };

    # === SPF Options ===
    spf = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Create SPF DNS record via Terraform";
      };

      mechanisms = {
        mx = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Allow mail from MX record hosts";
        };

        a = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          example = [ "" "mail.example.com" ];
          description = ''
            A record hosts allowed to send mail.
            - "" (empty string) = current domain's A record (bare 'a')
            - "example.com" = specific domain's A record ('a:example.com')
          '';
        };

        ip4 = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          example = [ "192.0.2.1" "198.51.100.0/24" ];
          description = "IPv4 addresses/ranges allowed to send mail";
        };

        ip6 = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "IPv6 addresses/ranges allowed to send mail";
        };

        include = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          example = [ "_spf.google.com" ];
          description = "Other domains whose SPF records to include";
        };
      };

      qualifier = lib.mkOption {
        type = lib.types.enum [ "-all" "~all" "?all" "+all" ];
        default = "-all";
        description = ''
          SPF qualifier for non-matching senders:
          - "-all": Hard fail (reject)
          - "~all": Soft fail (accept but mark)
          - "?all": Neutral
          - "+all": Pass all (not recommended)
        '';
      };
    };

    # === DMARC Options ===
    dmarc = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Create DMARC DNS record via Terraform";
      };

      policy = lib.mkOption {
        type = lib.types.enum [ "none" "quarantine" "reject" ];
        default = "quarantine";
        description = ''
          DMARC policy for messages that fail authentication:
          - "none": Monitor only, don't affect delivery
          - "quarantine": Mark as spam/suspicious
          - "reject": Reject the message
        '';
      };

      subdomainPolicy = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum [ "none" "quarantine" "reject" ]);
        default = null;
        description = "DMARC policy for subdomains (sp=). Defaults to main policy if null.";
      };

      pct = lib.mkOption {
        type = lib.types.ints.between 0 100;
        default = 100;
        description = "Percentage of messages to apply DMARC policy to";
      };

      rua = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "mailto:dmarc-reports@example.com";
        description = "URI for aggregate DMARC reports";
      };

      ruf = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "URI for forensic DMARC reports";
      };
    };

    # === Output Options (read-only, set by module) ===
    # These are derivations, not strings. Use builtins.readFile to get the string.
    # Reading forces the derivation to build, which runs validation.
    spfRecord = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = "Derivation containing validated SPF record string";
    };

    dmarcRecord = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = "Derivation containing validated DMARC record string";
    };
  };

  config = lib.mkIf cfg.enable {
    mailDns.spfRecord = spfRecordDrv;
    mailDns.dmarcRecord = dmarcRecordDrv;
  };
}
