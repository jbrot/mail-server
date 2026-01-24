{
  description = "Reproducible NixOS-based email server with containerized mail stack";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      # Systems we support
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];

      # Helper to generate outputs for each system
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      # Nixpkgs instantiated for each system
      nixpkgsFor = forAllSystems (system: import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      });

    in
    {
      # Container images built with dockerTools
      packages = forAllSystems (system:
        let
          pkgs = nixpkgsFor.${system};
        in
        {
          opensmtpd-image = pkgs.callPackage ./nix/containers/opensmtpd.nix { };
          dovecot-image = pkgs.callPackage ./nix/containers/dovecot.nix { };
          rspamd-image = pkgs.callPackage ./nix/containers/rspamd.nix { };
          redis-image = pkgs.callPackage ./nix/containers/redis.nix { };

          # Convenience target to build all images
          all-images = pkgs.linkFarm "all-images" [
            { name = "opensmtpd-image"; path = self.packages.${system}.opensmtpd-image; }
            { name = "dovecot-image"; path = self.packages.${system}.dovecot-image; }
            { name = "rspamd-image"; path = self.packages.${system}.rspamd-image; }
            { name = "redis-image"; path = self.packages.${system}.redis-image; }
          ];
        }
      );

      # NixOS configuration for the mail server
      nixosConfigurations.mail-server = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./nix/nixos/configuration.nix
          ./nix/nixos/hardware-ec2.nix
          ./nix/nixos/networking.nix
          ./nix/nixos/mail-server.nix
        ];
        specialArgs = {
          inherit self;
        };
      };

      # Development shell with useful tools
      devShells = forAllSystems (system:
        let
          pkgs = nixpkgsFor.${system};
        in
        {
          default = pkgs.mkShell {
            buildInputs = with pkgs; [
              # Terraform for infrastructure
              terraform

              # AWS CLI for ECR and other AWS operations
              awscli2

              # Container tools
              podman
              skopeo

              # Useful utilities
              jq
              openssl

              # Mail testing
              swaks
            ];

            shellHook = ''
              echo "Email server development environment"
              echo ""
              echo "Available commands:"
              echo "  nix build .#opensmtpd-image  - Build OpenSMTPd container"
              echo "  nix build .#dovecot-image    - Build Dovecot container"
              echo "  nix build .#rspamd-image     - Build Rspamd container"
              echo "  nix build .#all-images       - Build all containers"
              echo ""
              echo "  terraform -chdir=terraform plan   - Plan infrastructure"
              echo "  terraform -chdir=terraform apply  - Apply infrastructure"
              echo ""
              echo "  ./scripts/build-and-push.sh  - Build and push images to ECR"
              echo "  ./scripts/deploy-nixos.sh    - Deploy NixOS config to server"
            '';
          };
        }
      );

      # Checks for CI
      checks = forAllSystems (system:
        let
          pkgs = nixpkgsFor.${system};
          smokeTests = import ./nix/tests/container-smoke-tests.nix { inherit pkgs self; };
        in
        {
          # Verify container images build
          opensmtpd-image = self.packages.${system}.opensmtpd-image;
          dovecot-image = self.packages.${system}.dovecot-image;
          rspamd-image = self.packages.${system}.rspamd-image;
          redis-image = self.packages.${system}.redis-image;

          # Config validation tests (fast, no containers needed)
          inherit (smokeTests)
            rspamd-config-check
            opensmtpd-config-check
            dovecot-config-check;

          # Verify NixOS configuration evaluates
          nixos-config = self.nixosConfigurations.mail-server.config.system.build.toplevel;
        } // (if system == "x86_64-linux" then {
          # VM integration test (only on x86_64-linux due to QEMU)
          mail-server-integration = import ./nix/tests/mail-server-test.nix {
            inherit pkgs self;
          };

          # Standalone OpenSMTPd test (no Dovecot or Rspamd needed)
          opensmtpd-standalone = import ./nix/tests/opensmtpd-test.nix {
            inherit pkgs self;
          };

          # Standalone Dovecot test (IMAP/LMTP only)
          dovecot-standalone = import ./nix/tests/dovecot-test.nix {
            inherit pkgs self;
          };

          # Mail delivery integration test (OpenSMTPd + Dovecot)
          mail-delivery = import ./nix/tests/mail-delivery-test.nix {
            inherit pkgs self;
          };

          # Standalone Rspamd test (spam filtering without OpenSMTPd)
          rspamd-standalone = import ./nix/tests/rspamd-test.nix {
            inherit pkgs self;
          };

          # OpenSMTPd + Rspamd integration test (spam filtering and DKIM signing)
          opensmtpd-rspamd = import ./nix/tests/opensmtpd-rspamd-test.nix {
            inherit pkgs self;
          };
        } else {})
      );
    };
}
