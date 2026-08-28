# Shared core for `services.inngest` — declared once, consumed by both platform modules.
#
# The NixOS/systemd module (`inngest.nix`) and the home-manager/launchd module
# (`inngest-hm.nix`) differ only in how they supervise the process and deliver the
# environment file. Everything else — the option surface, the argv mapping, and the
# validation rules — lives here so the two can never drift.
#
# INVARIANT (the whole reason argv is built here and not per-platform): only
# NON-SECRET settings become flags. Credentials — the signing key, the event key,
# and any password-bearing Postgres/Redis URI — travel as environment variables read
# from `environmentFile`, because argv is world-readable via /proc.
{
  lib,
  pkgs,
  defaultStateDir,
}:
{
  options = {
    enable = lib.mkEnableOption "the Inngest durable-execution server (self-hosted, SSPL — see README)";

    package = lib.mkPackageOption pkgs "inngest" { };

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      example = "0.0.0.0";
      description = ''
        Address the API and connect gateway bind to. Defaults to loopback, which
        deliberately DIFFERS from upstream's 0.0.0.0 — expose it on purpose, via a
        reverse proxy or tunnel, rather than by default.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8288;
      description = "Port for the Inngest API, GraphQL endpoint and web UI.";
    };

    connectGatewayPort = lib.mkOption {
      type = lib.types.port;
      default = 8289;
      description = "Port for the connect gateway (WebSocket) endpoint.";
    };

    postgresUri = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "postgresql:///inngest?host=/run/postgresql";
      description = ''
        PostgreSQL URI for configuration and history persistence. `null` (the
        default) falls back to a SQLite database under `stateDir`.

        Use this option ONLY for a URI with no embedded password — a peer- or
        socket-authenticated local connection. A URI carrying a password must be
        supplied as `INNGEST_POSTGRES_URI` via `environmentFile` instead, so it
        never reaches argv.

        SQLite does not scale past a single node, and Inngest performs NO automatic
        row cleanup: events, runs and traces accumulate and must be pruned by you.
      '';
    };

    redisUri = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "redis://127.0.0.1:6379";
      description = ''
        Redis URI for the external queue and run state. `null` uses the bundled
        in-memory Redis with periodic snapshots — convenient, but with no
        persistence guarantee. Same password rule as `postgresUri`: use
        `INNGEST_REDIS_URI` via `environmentFile` when credentials are involved.
      '';
    };

    sdkUrls = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "http://127.0.0.1:3000/api/inngest" ];
      description = ''
        App serve URLs to sync on startup. Note that app sync polling is disabled
        unless `pollInterval` is set — without it, a redeployed app must be re-synced
        explicitly (`curl -X PUT <app>/api/inngest`), and events emitted before that
        sync are dropped with no replay.
      '';
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/agenix/inngest-env";
      description = ''
        Path to a file holding the credentials, one `KEY=value` per line. This is the
        ONLY supported way to pass them — there is no string option, because argv is
        world-readable.

        Recognised keys: `INNGEST_SIGNING_KEY` (hex, even number of characters),
        `INNGEST_EVENT_KEY`, and optionally `INNGEST_POSTGRES_URI` /
        `INNGEST_REDIS_URI` when those carry passwords.

        On NixOS this becomes a systemd `EnvironmentFile`. On darwin the launchd
        wrapper sources it at start, so the values stay out of the world-readable
        LaunchAgent plist.

        Place the file out-of-band (agenix/sops/manual); never commit it. Typed as a
        string, not a path, so it is never copied into the world-readable Nix store.
      '';
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = defaultStateDir;
      description = "State directory, used for the SQLite database when `postgresUri` is null.";
    };

    noUi = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Disable the web UI and the GraphQL API endpoint.";
    };

    queueWorkers = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = "Executor workers consuming steps from the queue. Null uses upstream's default of 100.";
    };

    pollInterval = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      example = 10;
      description = "Seconds between polls for app updates. Null leaves app-sync polling disabled.";
    };

    retryInterval = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = "Linear backoff retry interval in seconds. Must be 1 or above when set.";
    };

    logLevel = lib.mkOption {
      type = lib.types.enum [
        "trace"
        "debug"
        "info"
        "warn"
        "error"
      ];
      default = "info";
      description = "Server log level.";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "--tick"
        "100"
      ];
      description = "Extra arguments appended to `inngest start`.";
    };
  };

  # The `inngest start` argument vector. Secrets are structurally absent — see the
  # header invariant; the flake's eval check asserts no credential flag appears here.
  mkArgs =
    cfg:
    [
      "start"
      "--host"
      cfg.host
      "--port"
      (toString cfg.port)
      "--connect-gateway-port"
      (toString cfg.connectGatewayPort)
    ]
    ++ lib.optionals (cfg.postgresUri != null) [
      "--postgres-uri"
      cfg.postgresUri
    ]
    ++ lib.optionals (cfg.redisUri != null) [
      "--redis-uri"
      cfg.redisUri
    ]
    ++ lib.optionals (cfg.postgresUri == null) [
      "--sqlite-dir"
      cfg.stateDir
    ]
    ++ lib.concatMap (u: [
      "--sdk-url"
      u
    ]) cfg.sdkUrls
    ++ lib.optionals cfg.noUi [ "--no-ui" ]
    ++ lib.optionals (cfg.queueWorkers != null) [
      "--queue-workers"
      (toString cfg.queueWorkers)
    ]
    ++ lib.optionals (cfg.pollInterval != null) [
      "--poll-interval"
      (toString cfg.pollInterval)
    ]
    ++ lib.optionals (cfg.retryInterval != null) [
      "--retry-interval"
      (toString cfg.retryInterval)
    ]
    ++ [
      "--log-level"
      cfg.logLevel
    ]
    ++ cfg.extraArgs;

  mkValidation = cfg: {
    assertions = [
      {
        assertion = cfg.retryInterval == null || cfg.retryInterval >= 1;
        message = "services.inngest.retryInterval must be 1 or above when set (upstream rejects 0).";
      }
      {
        assertion = cfg.redisUri == null || cfg.postgresUri != null;
        message = ''
          services.inngest: an external redisUri alongside SQLite persistence is not a
          coherent pairing — set postgresUri too, or leave both unset to use the
          bundled SQLite + in-memory Redis.
        '';
      }
    ];

    warnings =
      lib.optional (cfg.postgresUri != null && lib.hasInfix "@" cfg.postgresUri) ''
        services.inngest.postgresUri appears to embed credentials ("@" present). argv is
        world-readable via /proc — pass it as INNGEST_POSTGRES_URI through environmentFile instead.
      ''
      ++ lib.optional (cfg.redisUri != null && lib.hasInfix "@" cfg.redisUri) ''
        services.inngest.redisUri appears to embed credentials ("@" present). Pass it as
        INNGEST_REDIS_URI through environmentFile instead.
      ''
      ++ lib.optional (cfg.environmentFile == null) ''
        services.inngest is enabled without an environmentFile, so no signing key or event
        key is set. Apps will not be able to authenticate to this server.
      '';
  };
}
