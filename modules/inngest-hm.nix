# Inngest — self-hosted durable-execution server, as a macOS launchd user agent.
#
# The darwin twin of ./inngest.nix, for running the local lane on a workstation.
# Option surface, argv mapping and validation are shared via ./common.nix; only the
# supervision differs.
#
# TWO PLATFORM CONSTRAINTS drive the wrapper this module builds:
#
#  1. launchd has NO EnvironmentFile. Putting credentials in `EnvironmentVariables`
#     would write them into ~/Library/LaunchAgents/*.plist, which is world-readable.
#     So the wrapper sources `environmentFile` itself at start and never exports the
#     values anywhere persistent.
#
#  2. arg0 MUST be `nix-inngest`, never a bare interpreter. macOS Background Task
#     Manager lists agents by their executable basename; a `sh` or `bash` there is
#     indistinguishable from third-party persistence. The wrapper is a
#     `writeShellScriptBin "nix-inngest"` precisely so BTM shows a name that
#     identifies its origin.
#
# No-op off darwin, so it is safe to import unconditionally.
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
    defaultStateDir = "${config.home.homeDirectory}/.local/state/inngest";
  };
  validation = common.mkValidation cfg;

  # arg0 basename is `nix-inngest` — see constraint 2 in the header.
  wrapper = pkgs.writeShellScriptBin "nix-inngest" ''
    set -euo pipefail
    mkdir -p ${lib.escapeShellArg cfg.stateDir}
    ${lib.optionalString (cfg.environmentFile != null) ''
      if [ -r ${lib.escapeShellArg cfg.environmentFile} ]; then
        # Exported for the child only; never echoed, never written back out.
        set -a
        # shellcheck disable=SC1091
        . ${lib.escapeShellArg cfg.environmentFile}
        set +a
      else
        echo "nix-inngest: environmentFile ${cfg.environmentFile} missing or unreadable" >&2
        echo "nix-inngest: refusing to start without a signing key" >&2
        exit 1
      fi
    ''}
    exec ${lib.escapeShellArgs ([ "${cfg.package}/bin/inngest" ] ++ common.mkArgs cfg)}
  '';
in
{
  options.services.inngest = common.options;

  config = lib.mkIf (cfg.enable && pkgs.stdenv.hostPlatform.isDarwin) {
    inherit (validation) assertions warnings;

    launchd.agents.inngest = {
      enable = true;
      config = {
        ProgramArguments = [ "${wrapper}/bin/nix-inngest" ];
        RunAtLoad = true;
        KeepAlive = {
          SuccessfulExit = false;
          Crashed = true;
        };
        ProcessType = "Background";
        StandardOutPath = "${cfg.stateDir}/inngest.log";
        StandardErrorPath = "${cfg.stateDir}/inngest.err.log";
      };
    };
  };
}
