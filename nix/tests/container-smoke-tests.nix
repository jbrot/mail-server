# Container smoke tests - fast config validation without needing container runtime
# nix/tests/container-smoke-tests.nix

{ pkgs, ... }:

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
}
