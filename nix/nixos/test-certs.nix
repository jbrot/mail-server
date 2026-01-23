# Reusable module for generating self-signed test certificates
# nix/nixos/test-certs.nix

{ config, lib, pkgs, ... }:

let
  cfg = config.services.testCerts;
in
{
  options.services.testCerts = {
    enable = lib.mkEnableOption "Generate self-signed test certificates";

    domain = lib.mkOption {
      type = lib.types.str;
      default = "localhost";
      description = "Domain name for the certificate CN";
    };

    certPath = lib.mkOption {
      type = lib.types.str;
      default = "/data/certs";
      description = "Directory path to store generated certificates";
    };
  };

  config = lib.mkIf cfg.enable {
    # Generate self-signed certs on boot
    systemd.services.generate-test-certs = {
      description = "Generate self-signed certificates for testing";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        mkdir -p ${cfg.certPath}
        ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:2048 -nodes \
          -keyout ${cfg.certPath}/key.pem -out ${cfg.certPath}/fullchain.pem \
          -days 1 -subj "/CN=${cfg.domain}"
        chmod 644 ${cfg.certPath}/fullchain.pem
        chmod 640 ${cfg.certPath}/key.pem
      '';
    };
  };
}
