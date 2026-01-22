{ pkgs
, lib ? pkgs.lib
}:

let
  # Rspamd package
  rspamd = pkgs.rspamd;

  # Create a minimal passwd file
  passwdFile = pkgs.writeText "passwd" ''
    root:x:0:0:root:/root:/bin/sh
    rspamd:x:1000:1000:Rspamd:/var/lib/rspamd:/bin/false
    nobody:x:65534:65534:Nobody:/var/empty:/bin/false
  '';

  groupFile = pkgs.writeText "group" ''
    root:x:0:
    rspamd:x:1000:
    nobody:x:65534:
  '';

  # Entrypoint script
  entrypoint = pkgs.writeShellScriptBin "entrypoint" ''
    set -e

    # Create required directories
    mkdir -p /var/lib/rspamd
    mkdir -p /var/run/rspamd
    mkdir -p /data/rspamd
    mkdir -p /data/rspamd/dkim

    # Set permissions
    chown -R rspamd:rspamd /var/lib/rspamd
    chown -R rspamd:rspamd /var/run/rspamd
    chown -R rspamd:rspamd /data/rspamd

    # Link persistent data
    if [ ! -L /var/lib/rspamd/bayes.sqlite ]; then
      ln -sf /data/rspamd/bayes.sqlite /var/lib/rspamd/bayes.sqlite 2>/dev/null || true
    fi

    # Check for config directory
    if [ ! -d /etc/rspamd ]; then
      echo "ERROR: /etc/rspamd directory not found"
      exit 1
    fi

    # Check configuration
    echo "Checking Rspamd configuration..."
    ${rspamd}/bin/rspamadm configtest

    echo "Starting Rspamd..."
    exec ${rspamd}/bin/rspamd -f -u rspamd -g rspamd
  '';

in
pkgs.dockerTools.buildLayeredImage {
  name = "rspamd";
  tag = "latest";

  contents = [
    rspamd
    entrypoint
    pkgs.coreutils
    pkgs.bash
    pkgs.cacert
    pkgs.gnugrep
    pkgs.gawk
  ];

  extraCommands = ''
    # Create directory structure
    mkdir -p var/lib/rspamd
    mkdir -p var/run/rspamd
    mkdir -p data/rspamd/dkim
    mkdir -p tmp

    # Remove any existing etc/rspamd (may be symlinks from contents)
    rm -rf etc/rspamd

    # Copy default rspamd config (need actual files, not symlinks)
    mkdir -p etc/rspamd/local.d
    mkdir -p etc/rspamd/override.d
    cp -rL ${rspamd}/etc/rspamd/* etc/rspamd/

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
      "11332/tcp" = {};  # Milter/proxy
      "11333/tcp" = {};  # Normal worker
      "11334/tcp" = {};  # Web UI
    };
    Volumes = {
      "/etc/rspamd/local.d" = {};
      "/etc/rspamd/override.d" = {};
      "/data/rspamd" = {};
    };
    Env = [
      "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
    ];
    Labels = {
      "org.opencontainers.image.title" = "Rspamd";
      "org.opencontainers.image.description" = "Minimal Rspamd spam filter container built with Nix";
    };
  };
}
