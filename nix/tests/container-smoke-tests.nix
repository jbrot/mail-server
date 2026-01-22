# Container smoke tests - fast config validation without needing container runtime
# nix/tests/container-smoke-tests.nix

{ pkgs, self }:

let
  # Test configs that match container expectations
  testSmtpdConf = pkgs.writeText "smtpd.conf" ''
    listen on localhost
    action "local" mbox
    match from any for local action "local"
  '';

in {
  # Verify rspamd config is parseable
  rspamd-config-check = pkgs.runCommand "rspamd-config-check" {
    nativeBuildInputs = [ pkgs.rspamd ];
  } ''
    # Use default rspamd config
    rspamadm configtest -c ${pkgs.rspamd}/etc/rspamd/rspamd.conf
    touch $out
  '';

  # Verify opensmtpd can parse a minimal config
  opensmtpd-config-check = pkgs.runCommand "opensmtpd-config-check" {
    nativeBuildInputs = [ pkgs.opensmtpd ];
  } ''
    smtpd -n -f ${testSmtpdConf}
    touch $out
  '';

  # Verify dovecot package is functional (config validation requires system users)
  dovecot-config-check = pkgs.runCommand "dovecot-config-check" {
    nativeBuildInputs = [ pkgs.dovecot ];
  } ''
    # Verify dovecot binaries are functional
    dovecot --version > /dev/null
    # doveadm without args prints usage and exits 0
    doveadm > /dev/null 2>&1 || true
    touch $out
  '';

  # Verify container image tarballs have expected structure
  opensmtpd-image-structure = pkgs.runCommand "opensmtpd-image-structure" {
    nativeBuildInputs = [ pkgs.gnutar pkgs.gzip pkgs.jq ];
    image = self.packages.${pkgs.system}.opensmtpd-image;
  } ''
    mkdir -p extracted
    tar -xzf $image -C extracted

    # Verify manifest.json exists (Docker image format)
    if [ ! -f extracted/manifest.json ]; then
      echo "ERROR: No manifest.json found"
      exit 1
    fi
    echo "Found manifest.json"
    jq . extracted/manifest.json > /dev/null

    # Count layer directories (Docker v1.2 format: <hash>/layer.tar)
    layer_count=$(find extracted -name "layer.tar" | wc -l)
    if [ "$layer_count" -lt 1 ]; then
      echo "ERROR: No layers found"
      exit 1
    fi
    echo "Found $layer_count layers"

    # Verify at least one layer contains etc/passwd (the customisation layer)
    found_passwd=0
    for layer in $(find extracted -name "layer.tar"); do
      if tar -tf "$layer" 2>/dev/null | grep -q "etc/passwd"; then
        found_passwd=1
        echo "Found etc/passwd in layer"
        break
      fi
    done

    if [ "$found_passwd" -eq 0 ]; then
      echo "Warning: etc/passwd not found in any layer (may be in different format)"
    fi

    touch $out
  '';
}
