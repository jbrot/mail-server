{ pkgs
, lib ? pkgs.lib
}:

let
  # OpenSMTPd package
  opensmtpd = pkgs.opensmtpd;
  opensmtpd-extras = pkgs.opensmtpd-extras;

  # Create a minimal passwd file for the mail user
  passwdFile = pkgs.writeText "passwd" ''
    root:x:0:0:root:/root:/bin/sh
    smtpd:x:1000:1000:OpenSMTPd:/var/empty:/bin/false
    smtpq:x:1001:1001:OpenSMTPd Queue:/var/empty:/bin/false
    vmail:x:5000:5000:Virtual Mail:/var/mail:/bin/false
  '';

  groupFile = pkgs.writeText "group" ''
    root:x:0:
    smtpd:x:1000:
    smtpq:x:1001:
    vmail:x:5000:
  '';

  # Entrypoint script
  entrypoint = pkgs.writeShellScriptBin "entrypoint" ''
    set -e

    # Create required directories
    mkdir -p /var/spool/smtpd
    mkdir -p /var/spool/smtpd/offline
    mkdir -p /var/spool/smtpd/purge
    mkdir -p /var/empty
    mkdir -p /data/mail
    mkdir -p /data/certs

    # Set permissions - spool must be owned by root with 711
    chown root:root /var/spool/smtpd
    chmod 711 /var/spool/smtpd

    # Subdirectories have different ownership
    # offline: owned by root:smtpq, mode 770
    chown root:smtpq /var/spool/smtpd/offline
    chmod 770 /var/spool/smtpd/offline
    # purge: owned by smtpq:root, mode 700
    chown smtpq:root /var/spool/smtpd/purge
    chmod 700 /var/spool/smtpd/purge

    # Check for config file
    if [ ! -f /etc/smtpd/smtpd.conf ]; then
      echo "ERROR: /etc/smtpd/smtpd.conf not found"
      exit 1
    fi

    # Check configuration
    echo "Checking OpenSMTPd configuration..."
    ${opensmtpd}/bin/smtpd -n -f /etc/smtpd/smtpd.conf

    echo "Starting OpenSMTPd..."
    exec ${opensmtpd}/bin/smtpd -d -f /etc/smtpd/smtpd.conf
  '';

in
pkgs.dockerTools.buildLayeredImage {
  name = "opensmtpd";
  tag = "latest";

  contents = [
    opensmtpd
    opensmtpd-extras
    entrypoint
    pkgs.coreutils
    pkgs.bash
    pkgs.cacert
  ];

  extraCommands = ''
    # Create directory structure
    mkdir -p etc/smtpd
    mkdir -p etc/ssl/certs
    mkdir -p var/spool/smtpd
    mkdir -p var/empty
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

    # Create symlink for CA certificates (OpenSMTPd expects this path)
    ln -sf ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt etc/ssl/certs/ca-certificates.crt
  '';

  config = {
    Entrypoint = [ "${entrypoint}/bin/entrypoint" ];
    ExposedPorts = {
      "25/tcp" = {};
      "465/tcp" = {};
      "587/tcp" = {};
    };
    Volumes = {
      "/etc/smtpd" = {};
      "/data/mail" = {};
      "/data/certs" = {};
    };
    Env = [
      "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
    ];
    Labels = {
      "org.opencontainers.image.title" = "OpenSMTPd";
      "org.opencontainers.image.description" = "Minimal OpenSMTPd container built with Nix";
    };
  };
}
