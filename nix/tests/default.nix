# Test exports
# nix/tests/default.nix

{ pkgs, self }:

{
  mail-server-integration = pkgs.callPackage ./mail-server-test.nix {
    inherit self;
  };
}
