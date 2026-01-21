{ pkgs
, lib ? pkgs.lib
}:

let
  # Dovecot package with required features
  dovecot = pkgs.dovecot;

  # Create a minimal passwd file
  passwdFile = pkgs.writeText "passwd" ''
    root:x:0:0:root:/root:/bin/sh
    dovecot:x:1000:1000:Dovecot:/var/empty:/bin/false
    dovenull:x:65534:65534:Dovecot Null:/var/empty:/bin/false
    vmail:x:5000:5000:Virtual Mail:/data/mail:/bin/false
  '';

  groupFile = pkgs.writeText "group" ''
    root:x:0:
    dovecot:x:1000:
    dovenull:x:65534:
    vmail:x:5000:
  '';

  # Entrypoint script
  entrypoint = pkgs.writeShellScriptBin "entrypoint" ''
    set -e

    # Create required directories
    mkdir -p /var/run/dovecot
    mkdir -p /var/lib/dovecot
    mkdir -p /data/mail
    mkdir -p /data/certs

    # Set permissions for mail directory
    chown -R vmail:vmail /data/mail
    chmod 700 /data/mail

    # Check for config file
    if [ ! -f /etc/dovecot/dovecot.conf ]; then
      echo "ERROR: /etc/dovecot/dovecot.conf not found"
      exit 1
    fi

    # Check configuration
    echo "Checking Dovecot configuration..."
    ${dovecot}/bin/doveconf -c /etc/dovecot/dovecot.conf -n > /dev/null

    echo "Starting Dovecot..."
    exec ${dovecot}/bin/dovecot -c /etc/dovecot/dovecot.conf -F
  '';

in
pkgs.dockerTools.buildLayeredImage {
  name = "dovecot";
  tag = "latest";

  contents = [
    dovecot
    entrypoint
    pkgs.coreutils
    pkgs.bash
    pkgs.cacert
  ];

  extraCommands = ''
    # Create directory structure
    mkdir -p etc/dovecot
    mkdir -p var/run/dovecot
    mkdir -p var/lib/dovecot
    mkdir -p data/mail
    mkdir -p data/certs
    mkdir -p tmp

    # Copy passwd and group files
    cp ${passwdFile} etc/passwd
    cp ${groupFile} etc/group

    # Create nsswitch.conf
    echo "passwd: files" > etc/nsswitch.conf
    echo "group: files" >> etc/nsswitch.conf
    echo "hosts: files dns" >> etc/nsswitch.conf
  '';

  config = {
    Entrypoint = [ "${entrypoint}/bin/entrypoint" ];
    ExposedPorts = {
      "24/tcp" = {};    # LMTP
      "993/tcp" = {};   # IMAPS
      "143/tcp" = {};   # IMAP (internal/optional)
    };
    Volumes = {
      "/etc/dovecot" = {};
      "/data/mail" = {};
      "/data/certs" = {};
    };
    Env = [
      "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
    ];
    Labels = {
      "org.opencontainers.image.title" = "Dovecot";
      "org.opencontainers.image.description" = "Minimal Dovecot IMAP/LMTP container built with Nix";
    };
  };
}
