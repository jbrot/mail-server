{ pkgs
, lib ? pkgs.lib
}:

let
  # OpenSMTPd package
  opensmtpd = pkgs.opensmtpd;

  # Create a minimal passwd file for the mail user
  # UID 2000 for smtpd (unique per service for isolation)
  passwdFile = pkgs.writeText "passwd" ''
    root:x:0:0:root:/root:/bin/sh
    smtpd:x:2000:2000:OpenSMTPd:/var/empty:/bin/false
    smtpq:x:2001:2001:OpenSMTPd Queue:/var/empty:/bin/false
  '';

  groupFile = pkgs.writeText "group" ''
    root:x:0:
    smtpd:x:2000:
    smtpq:x:2001:
  '';

  # Entrypoint script
  # Container runs as root initially - smtpd drops privileges internally
  entrypoint = pkgs.writeShellScriptBin "entrypoint" ''
    set -e

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
    pkgs.opensmtpd-filter-rspamd
    entrypoint
    pkgs.coreutils
    pkgs.bash
    pkgs.cacert
  ];

  extraCommands = ''
    # Create directory structure
    mkdir -p etc/smtpd
    mkdir -p etc/ssl/certs
    mkdir -p var/empty
    mkdir -p data/certs
    mkdir -p tmp

    # Create spool directories (permissions set in fakeRootCommands)
    mkdir -p var/spool/smtpd
    mkdir -p var/spool/smtpd/offline
    mkdir -p var/spool/smtpd/purge

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

  # Use fakeRootCommands to set ownership and permissions (baked into image)
  fakeRootCommands = ''
    # Spool directory permissions required by OpenSMTPd
    chown root:root var/spool/smtpd
    chmod 711 var/spool/smtpd

    # offline: owned by root:smtpq, mode 770
    chown root:2001 var/spool/smtpd/offline
    chmod 770 var/spool/smtpd/offline

    # purge: owned by smtpq:root, mode 700
    chown 2001:root var/spool/smtpd/purge
    chmod 700 var/spool/smtpd/purge
  '';
  enableFakechroot = true;

  config = {
    Entrypoint = [ "${entrypoint}/bin/entrypoint" ];
    ExposedPorts = {
      "25/tcp" = {};
      "465/tcp" = {};
      "587/tcp" = {};
    };
    Volumes = {
      "/etc/smtpd" = {};
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
