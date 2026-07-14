{
  description = "A vfkit-based linux builder for Nix-darwin";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs =
    { self, nixpkgs }@inputs:

    let
      inherit (nixpkgs) lib;
      _lib = import ./lib { inherit lib; };

      darwinSystems = lib.systems.doubles.darwin;
      linuxSystems = _lib.helpers.doppelganger darwinSystems;

      pkgsFor = systems: f: lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));

      perDarwinSystem = pkgsFor darwinSystems;
      perLinuxSystem = pkgsFor linuxSystems;
    in

    {
      darwinModules = {
        default = self.darwinModules.virby;
        virby = import ./module { inherit _lib self; };
      };

      packages =
        perDarwinSystem (pkgs: {
          default = self.packages.${pkgs.stdenv.hostPlatform.system}.vm-runner;
          vm-runner = pkgs.python3Packages.callPackage ./pkgs/vm-runner { inherit _lib; };
        })
        // perLinuxSystem (pkgs: {
          default = self.packages.${pkgs.stdenv.hostPlatform.system}.vm-image;
          vm-image = pkgs.callPackage ./pkgs/vm-image { inherit _lib inputs lib; };
        });

      apps = perDarwinSystem (pkgs: {
        benchmark-vm = {
          type = "app";
          program = lib.getExe (pkgs.callPackage ./scripts/benchmark-vm { });
        };
        bump-version = {
          type = "app";
          program = lib.getExe (pkgs.callPackage ./scripts/bump-version { });
        };
      });

      checks =
        perDarwinSystem (pkgs: {
          vm-runner = self.packages.${pkgs.stdenv.hostPlatform.system}.vm-runner;
        })
        // perLinuxSystem (
          pkgs:
          let
            enabledImage = self.packages.${pkgs.stdenv.hostPlatform.system}.vm-image.override {
              timeSync = {
                enable = true;
                vsockPort = 2345;
              };
            };
            disabledImage = self.packages.${pkgs.stdenv.hostPlatform.system}.vm-image.override {
              timeSync = {
                enable = false;
                vsockPort = 2345;
              };
            };
            enabledConfig = enabledImage.nixosConfiguration.config;
            disabledConfig = disabledImage.nixosConfiguration.config;
            service = enabledConfig.systemd.services.virby-time-sync-agent;
            execStart = service.serviceConfig.ExecStart;
            qemuGuestAgent = pkgs.callPackage ./pkgs/vm-image/qemu-guest-agent.nix { };
            patchedQemuGuestAgentSource = pkgs.applyPatches {
              name = "virby-qemu-guest-agent-patched-source";
              inherit (qemuGuestAgent) src patches;
            };
          in
          {
            vm-runner = pkgs.python3Packages.callPackage ./pkgs/vm-runner {
              inherit _lib;
              vfkit = null;
            };
            vm-time-sync =
              assert lib.hasInfix "--method=vsock-listen" execStart;
              assert lib.hasInfix "--path=4294967295:2345" execStart;
              assert lib.hasInfix "--allow-rpcs=guest-set-time" execStart;
              assert lib.hasPrefix "${qemuGuestAgent.ga}/bin/qemu-ga " execStart;
              assert builtins.elem "CAP_SYS_TIME" service.serviceConfig.CapabilityBoundingSet;
              assert builtins.elem pkgs.util-linux enabledConfig.environment.systemPackages;
              assert !(builtins.hasAttr "virby-time-sync-agent" disabledConfig.systemd.services);
              pkgs.runCommand "virby-vm-time-sync-check" { nativeBuildInputs = [ pkgs.gnugrep ]; } ''
                commands=${patchedQemuGuestAgentSource}/qga/commands-posix.c

                grep -F '"/run/current-system/sw/bin/hwclock", "--noadjfile"' "$commands"
                grep -F '"--utc", has_time ? "-w" : "-s", NULL' "$commands"
                if grep -F 'argv[0] = "/sbin/hwclock"' "$commands"; then
                  echo "qemu-ga retains the unsafe /sbin/hwclock fallback" >&2
                  exit 1
                fi

                touch "$out"
              '';
          }
        );

      devShells = perDarwinSystem (pkgs: {
        default = pkgs.mkShellNoCC {
          name = "virby-dev";
          packages = [ pkgs.vfkit ];
        };
      });

      formatter =
        perDarwinSystem (
          pkgs: pkgs.nixfmt-tree.override { settings.formatter.nixfmt.options = [ "--strict" ]; }
        )
        // perLinuxSystem (
          pkgs: pkgs.nixfmt-tree.override { settings.formatter.nixfmt.options = [ "--strict" ]; }
        );
    };
}
