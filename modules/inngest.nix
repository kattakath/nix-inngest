# Inngest — self-hosted durable-execution server, as a hardened systemd unit.
#
# WHY THIS MODULE: nixpkgs ships the `inngest` binary but nothing runs it as a
# supervised service. This is that unit — the smallest hardened wrapper around
# `inngest start`, the self-host entrypoint (NOT `inngest dev`, which is the
# ephemeral development server and persists nothing).
#
# LICENSE — READ THIS FIRST. Inngest is SSPL v1.0, not an OSI-approved open source
# license, and nixpkgs marks it `unfree`. Consumers MUST opt in, e.g.
#   nixpkgs.config.allowUnfreePredicate = pkg: lib.getName pkg == "inngest";
# It is therefore absent from cache.nixos.org and builds locally. Each release
# carries a time-delayed grant converting it to Apache 2.0 on that release's third
# anniversary. See the README for the copyleft trigger.
#
# BINDS LOCALHOST BY DEFAULT. Upstream `inngest start` binds 0.0.0.0 — the API, the
# connect gateway, AND an executor gRPC server on :50053. This module defaults
# `host` to 127.0.0.1 so nothing is exposed by accident; :50053 is deliberately not
# covered by `openFirewall` because it should never be public.
#
# The option surface, argv mapping and validation live in ./common.nix, shared with
# the darwin/launchd module so the two cannot drift.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.inngest;
  common = import ./common.nix {
    inherit lib pkgs;
    defaultStateDir = "/var/lib/inngest";
  };
  validation = common.mkValidation cfg;
in
{
  options.services.inngest = common.options // {
    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Open `port` and `connectGatewayPort` in the firewall. The executor gRPC
        server on :50053 is deliberately NOT opened — it should never be public.
      '';
    };

    restartSec = lib.mkOption {
      type = lib.types.either lib.types.int lib.types.str;
      default = 5;
      description = "systemd `RestartSec` for the unit.";
    };
  };

  config = lib.mkIf cfg.enable {
    inherit (validation) assertions warnings;

    networking.firewall = lib.mkIf cfg.openFirewall {
      allowedTCPPorts = [
        cfg.port
        cfg.connectGatewayPort
      ];
    };

    # Surface a missing EnvironmentFile at activation. The unit fails and retries, so
    # this reports the root cause instead of leaving an unexplained restart loop.
    system.activationScripts.check-inngest-env = lib.mkIf (cfg.environmentFile != null) (
      lib.stringAfter [ "etc" ] ''
        if [ ! -f "${cfg.environmentFile}" ]; then
          echo "WARNING: services.inngest is enabled but environmentFile '${cfg.environmentFile}' does not exist." >&2
          echo "  Place a file with INNGEST_SIGNING_KEY=... and INNGEST_EVENT_KEY=... at that path." >&2
          echo "  inngest.service will keep retrying until it is present." >&2
        fi
      ''
    );

    systemd.services.inngest = {
      description = "Inngest durable-execution server (self-hosted)";
      after = [ "network-online.target" ] ++ lib.optional (cfg.postgresUri != null) "postgresql.service";
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        ExecStart = lib.escapeShellArgs ([ "${cfg.package}/bin/inngest" ] ++ common.mkArgs cfg);
        EnvironmentFile = lib.mkIf (cfg.environmentFile != null) cfg.environmentFile;

        Restart = "on-failure";
        RestartSec = cfg.restartSec;

        # ---- systemd hardening -------------------------------------------------
        DynamicUser = true;
        StateDirectory = "inngest";
        RuntimeDirectory = "inngest";
        WorkingDirectory = cfg.stateDir;
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
          "~@resources"
        ];
        SystemCallArchitectures = "native";
      };
    };
  };
}
