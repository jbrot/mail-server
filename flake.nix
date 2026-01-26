{
  description = "Reproducible NixOS-based email server with containerized mail stack";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
    flake-utils.url = "github:numtide/flake-utils";

    # Config input - override for different configs:
    # nix build .#mail-server-ami --override-input mail-server-config path:./config/production
    # Default is x86_64; use deploy.sh which auto-selects based on host architecture
    mail-server-config = {
      url = "path:./config/default-x86_64";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, mail-server-config }:
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

      # Import mail server configuration from the config input
      mailServerConfig = import "${mail-server-config}/mail-server.nix";

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
        } // (if system == mailServerConfig.architecture then {
          # Custom NixOS AMI for EC2 deployment
          # Architecture determined by config (x86_64-linux or aarch64-linux)
          mail-server-ami = self.nixosConfigurations.mail-server.config.system.build.amazonImage;
        } else {})
      );

      # NixOS configuration for the mail server
      # Architecture determined by mailServerConfig.architecture
      nixosConfigurations.mail-server = nixpkgs.lib.nixosSystem {
        system = mailServerConfig.architecture;
        modules = [
          ./nix/nixos/configuration.nix
          ./nix/nixos/hardware-ec2.nix
          ./nix/nixos/networking.nix
          ./nix/nixos/mail-server.nix
        ];
        specialArgs = {
          inherit self mailServerConfig;
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
              echo "  nix build .#mail-server-ami  - Build EC2 AMI"
              echo ""
              echo "  nix flake check              - Run all tests"
              echo ""
              echo "  ./scripts/deploy.sh          - Build and deploy AMI"
              echo "  ./scripts/deploy.sh --help   - Show deploy options"
              echo ""

              # Enable tab completion for deploy.sh
              source ./scripts/deploy-completion.bash 2>/dev/null || true
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
        }
        # NixOS config and VM tests only on the configured architecture
        # (VM tests require KVM; nix flake check runs only checks matching host system)
        // (if system == mailServerConfig.architecture then {
          # Verify NixOS configuration evaluates
          nixos-config = self.nixosConfigurations.mail-server.config.system.build.toplevel;

          # VM integration test
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

          # Dovecot + Rspamd integration test (spam/ham learning via IMAP)
          dovecot-rspamd = import ./nix/tests/dovecot-rspamd-test.nix {
            inherit pkgs self;
          };
        } else {})
      );
    };
}
