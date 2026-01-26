# Test exports
# nix/tests/default.nix

{ pkgs, self }:

{
  mail-server-integration = pkgs.callPackage ./mail-server-test.nix {
    inherit self;
  };

  # TODO: Re-enable after implementing seven-network setup
  # network-isolation = pkgs.callPackage ./network-isolation-test.nix {
  #   inherit self;
  # };
}
