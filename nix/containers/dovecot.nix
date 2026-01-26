{ pkgs
, lib ? pkgs.lib
}:

let
  # Dovecot package with required features
  dovecot = pkgs.dovecot;

  # Pigeonhole package for sieve support (includes imap_sieve plugin)
  pigeonhole = pkgs.dovecot_pigeonhole;

  # Rspamd package for rspamc CLI (used for spam/ham learning)
  rspamd = pkgs.rspamd;

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
  # Directories created in extraCommands/fakeRootCommands with correct ownership
  # Host pre-creates /data/mail with correct ownership via tmpfiles.rules
  entrypoint = pkgs.writeShellScriptBin "entrypoint" ''
    set -e

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
    pigeonhole  # Sieve support including imap_sieve plugin
    rspamd  # For rspamc CLI (spam/ham learning via sieve)
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

    # Create modules directory with both dovecot and pigeonhole modules
    mkdir -p etc/dovecot/modules
    for mod in ${dovecot}/lib/dovecot/*.so; do
      ln -s "$mod" etc/dovecot/modules/
    done
    for mod in ${pigeonhole}/lib/dovecot/*.so; do
      ln -s "$mod" etc/dovecot/modules/
    done

    # Copy passwd and group files
    cp ${passwdFile} etc/passwd
    cp ${groupFile} etc/group

    # Create nsswitch.conf
    echo "passwd: files" > etc/nsswitch.conf
    echo "group: files" >> etc/nsswitch.conf
    echo "hosts: files dns" >> etc/nsswitch.conf

    # Create symlinks for rspamc in standard PATH locations
    mkdir -p usr/bin
    ln -s ${rspamd}/bin/rspamc usr/bin/rspamc
  '';

  # Use fakeRootCommands to set ownership (baked into image)
  # Dovecot master runs as root, workers run as vmail (5000)
  fakeRootCommands = ''
    # Runtime directories owned by root (dovecot master process)
    chown root:root var/run/dovecot
    chown root:root var/lib/dovecot
    # Mail directory owned by vmail (will be mounted from host anyway)
    chown 5000:5000 data/mail
    chmod 700 data/mail
  '';
  enableFakechroot = true;

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
