{ pkgs
, lib ? pkgs.lib
}:

let
  # Rspamd package
  rspamd = pkgs.rspamd;

  # Create a minimal passwd file
  # UID 3000 for rspamd (unique per service for isolation)
  passwdFile = pkgs.writeText "passwd" ''
    root:x:0:0:root:/root:/bin/sh
    rspamd:x:3000:3000:Rspamd:/var/lib/rspamd:/bin/false
    nobody:x:65534:65534:Nobody:/var/empty:/bin/false
  '';

  groupFile = pkgs.writeText "group" ''
    root:x:0:
    rspamd:x:3000:
    nobody:x:65534:
  '';

  # Entrypoint script
  # Directories created in extraCommands/fakeRootCommands with correct ownership
  # Host pre-creates /data/rspamd with correct ownership via tmpfiles.rules
  entrypoint = pkgs.writeShellScriptBin "entrypoint" ''
    set -e

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

  # Use fakeRootCommands to set ownership (baked into image)
  fakeRootCommands = ''
    # rspamd directories owned by rspamd user (UID 3000)
    chown -R 3000:3000 var/lib/rspamd
    chown -R 3000:3000 var/run/rspamd
  '';
  enableFakechroot = true;

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
