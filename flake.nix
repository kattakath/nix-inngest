{
  description = "Nix flake — hardened NixOS + home-manager modules for a self-hosted Inngest durable-execution server (`inngest start`). Signing/event keys via EnvironmentFile, never in argv or the Nix store; binds loopback by default.";

  inputs = {
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  nixConfig = {
    extra-substituters = [ "https://kattakath.cachix.org" ];
    extra-trusted-public-keys = [
      "kattakath.cachix.org-1:y/w6wnb4ZArdlbfWJ82c81uCXeYgG/sGDUYCszavmEw="
    ];
  };

  outputs =
    inputs@{
      self,
      flake-parts,
      home-manager,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ inputs.treefmt-nix.flakeModule ];

      systems = [
        "aarch64-darwin"
        "x86_64-linux"
        "aarch64-linux"
      ];

      flake = {
        nixosModules.inngest = ./modules/inngest.nix;
        nixosModules.default = self.nixosModules.inngest;

        homeManagerModules.inngest = ./modules/inngest-hm.nix;
        homeManagerModules.default = self.homeManagerModules.inngest;
      };

      perSystem =
        { pkgs, system, ... }:
        let
          inherit (inputs.nixpkgs) lib;

          # Test fixtures, named rather than inlined so each assertion below can
          # reference the exact value the module was configured with.
          envFile = "/run/inngest-env";
          # Peer-authenticated local socket: no user, no password, nothing secret.
          pgUri = "postgresql:///inngest?host=/run/postgresql";
          sdkUrl = "http://127.0.0.1:3000/api/inngest";
          pollSecs = 10;
          loopback = "127.0.0.1";
        in
        {
          # treefmt owns `nix fmt` and adds its own `checks.treefmt` gate. Bare nixfmt
          # as the formatter is a trap: `nix fmt` hands it every file in the tree,
          # including README.md and LICENSE, which it cannot parse.
          treefmt = {
            projectRootFile = "flake.nix";
            programs.nixfmt.enable = true;
            programs.deadnix.enable = true;
            programs.statix.enable = true;
          };

          checks =
            # ---- NixOS module: eval-only ------------------------------------------
            #
            # The package is STUBBED. Two reasons: the real `inngest` is unfree (SSPL)
            # so it is absent from cache.nixos.org, and it builds a large pnpm UI
            # closure — a CI check should drag in neither. The boundary under test is
            # this module's argv/hardening/secret handling, not upstream's build.
            # For a test that runs the real binary, see `packages.vm-test`.
            lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (
              let
                sys = lib.nixosSystem {
                  modules = [
                    self.nixosModules.default
                    (
                      { pkgs, ... }:
                      {
                        nixpkgs.hostPlatform = system;
                        boot.loader.grub.enable = false;
                        fileSystems."/" = {
                          device = "/dev/sda1";
                          fsType = "ext4";
                        };
                        system.stateVersion = "24.05";

                        services.inngest = {
                          enable = true;
                          package = pkgs.writeShellScriptBin "inngest" "exit 0";
                          environmentFile = envFile;
                          postgresUri = pgUri;
                          sdkUrls = [ sdkUrl ];
                          pollInterval = pollSecs;
                        };
                      }
                    )
                  ];
                };

                unit = sys.config.systemd.services.inngest.serviceConfig;
                execStart = unit.ExecStart;
                has = needle: lib.hasInfix needle execStart;

                # Match an escaped flag+value PAIR, not a bare substring. A loose
                # `has loopback` silently matched the sdkUrl instead of the --host
                # flag, so the loopback assertion could not fail. Caught by
                # negative-testing this check; keep the pairing.
                hasPair =
                  flag: value:
                  has (
                    lib.escapeShellArgs [
                      flag
                      value
                    ]
                  );

                # Asserted at EVAL time, so a regression fails before anything builds.
                ok = lib.all (a: lib.assertMsg a.cond a.msg) [
                  {
                    cond = !(has "--signing-key") && !(has "--event-key");
                    msg = "a credential flag leaked into ExecStart argv (must come via EnvironmentFile)";
                  }
                  {
                    cond = toString unit.EnvironmentFile == envFile;
                    msg = "EnvironmentFile is not wired to the configured path";
                  }
                  {
                    cond = hasPair "--host" loopback;
                    msg = "expected the loopback --host default, not upstream's 0.0.0.0";
                  }
                  {
                    cond = hasPair "--sdk-url" sdkUrl && hasPair "--poll-interval" (toString pollSecs);
                    msg = "sdkUrls / pollInterval did not reach argv";
                  }
                  {
                    cond = hasPair "--postgres-uri" pgUri;
                    msg = "postgresUri did not reach argv";
                  }
                  {
                    cond = !(has "--sqlite-dir");
                    msg = "--sqlite-dir must be omitted when postgresUri is set";
                  }
                  {
                    cond = unit.DynamicUser && toString unit.ProtectSystem == "strict";
                    msg = "systemd hardening is missing from the unit";
                  }
                  {
                    cond = toString unit.StateDirectory == "inngest";
                    msg = "StateDirectory is not set";
                  }
                ];
              in
              {
                module-eval =
                  assert ok;
                  pkgs.runCommand "inngest-module-eval" { } "touch $out";
              }
            )

            # ---- home-manager module: eval-only, darwin ----------------------------
            #
            # Asserts the launchd agent materialises with a `nix-inngest` arg0 (the BTM
            # naming rule — never a bare interpreter) and that no credential is written
            # into the world-readable plist.
            // lib.optionalAttrs (system == "aarch64-darwin") (
              let
                hm = home-manager.lib.homeManagerConfiguration {
                  inherit pkgs;
                  modules = [
                    self.homeManagerModules.default
                    (
                      { pkgs, ... }:
                      {
                        home.username = "test";
                        home.homeDirectory = "/Users/test";
                        home.stateVersion = "24.05";

                        services.inngest = {
                          enable = true;
                          package = pkgs.writeShellScriptBin "inngest" "exit 0";
                          environmentFile = envFile;
                        };
                      }
                    )
                  ];
                };

                agent = hm.config.launchd.agents.inngest.config;
                arg0 = builtins.head agent.ProgramArguments;

                # home-manager always populates EnvironmentVariables (PATH and
                # friends), so "the key is absent" is the wrong invariant. What must
                # hold is that no INNGEST_* credential is among them — the wrapper
                # sources them from environmentFile at start instead, keeping them
                # out of the world-readable plist.
                # (home-manager types this as nullable, so guard before attrNames.)
                envVars = if (agent.EnvironmentVariables or null) == null then { } else agent.EnvironmentVariables;
                leaked = lib.filter (lib.hasPrefix "INNGEST_") (lib.attrNames envVars);

                ok = lib.all (a: lib.assertMsg a.cond a.msg) [
                  {
                    cond = baseNameOf arg0 == "nix-inngest";
                    msg = "launchd arg0 basename must be nix-inngest, never a bare interpreter (BTM naming rule)";
                  }
                  {
                    cond = leaked == [ ];
                    msg = "INNGEST_* credentials leaked into the world-readable LaunchAgent plist: ${toString leaked}";
                  }
                  {
                    cond = agent.RunAtLoad;
                    msg = "agent should start at load";
                  }
                ];
              in
              {
                hm-eval =
                  assert ok;
                  pkgs.runCommand "inngest-hm-eval" { } "touch $out";
              }
            );

          # ---- Opt-in runtime test -------------------------------------------------
          #
          # NOT in `checks`: it builds the real unfree package (large pnpm UI closure,
          # absent from cache.nixos.org) and boots a VM. Run deliberately:
          #   nix build .#vm-test
          #
          # This is the test the eval check cannot be: it proves the service actually
          # starts, and — the assertion that matters most — that it is listening on
          # loopback rather than upstream's 0.0.0.0.
          packages = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
            vm-test =
              let
                pkgsUnfree = import inputs.nixpkgs {
                  inherit system;
                  config.allowUnfreePredicate = pkg: lib.getName pkg == "inngest";
                };
              in
              pkgsUnfree.testers.runNixOSTest {
                name = "inngest";
                nodes.machine =
                  { ... }:
                  {
                    imports = [ self.nixosModules.default ];
                    nixpkgs.config.allowUnfreePredicate = pkg: lib.getName pkg == "inngest";

                    # Test fixture only — an obviously-fake key, never a real credential.
                    environment.etc."inngest-env".text = ''
                      INNGEST_SIGNING_KEY=00112233445566778899aabbccddeeff
                      INNGEST_EVENT_KEY=test-event-key
                    '';

                    services.inngest = {
                      enable = true;
                      environmentFile = "/etc/inngest-env";
                    };

                    virtualisation.memorySize = 2048;
                  };

                testScript = ''
                  machine.wait_for_unit("inngest.service")
                  machine.wait_for_open_port(8288)

                  # The hardening that matters: bound to loopback, NOT 0.0.0.0.
                  machine.succeed("ss -ltn | grep -q '127.0.0.1:8288'")
                  machine.fail("ss -ltn | grep -q '0.0.0.0:8288'")

                  # The API answers.
                  machine.succeed("curl -fsS -o /dev/null http://127.0.0.1:8288/")

                  # SQLite persistence landed in the StateDirectory.
                  machine.succeed("test -d /var/lib/inngest")
                '';
              };
          };
        };
    };
}
