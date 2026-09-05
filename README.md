# nix-inngest

Hardened **NixOS** and **home-manager** modules for a self-hosted
[Inngest](https://www.inngest.com) durable-execution server.

nixpkgs ships the `inngest` binary but nothing supervises it. This is that unit — the
smallest well-behaved wrapper around `inngest start`, the self-host entrypoint (**not**
`inngest dev`, which is the ephemeral development server and persists nothing).

```nix
services.inngest = {
  enable = true;
  environmentFile = "/run/agenix/inngest-env";
  postgresUri = "postgresql:///inngest?host=/run/postgresql";
  sdkUrls = [ "http://127.0.0.1:3000/api/inngest" ];
};
```

## License — read this before deploying

**Inngest is [SSPL v1.0](https://github.com/inngest/inngest/blob/main/LICENSE.md), not an
OSI-approved open source license,** and nixpkgs marks it `unfree`. Consequences:

- **You must opt in explicitly**, or evaluation fails:
  ```nix
  nixpkgs.config.allowUnfreePredicate = pkg: lib.getName pkg == "inngest";
  ```
- **It is not in `cache.nixos.org`** and will build locally. The build includes a large
  pnpm UI closure — budget disk and time, or point `services.inngest.package` at your own
  prebuilt derivation.
- Each release carries an irrevocable grant converting it to **Apache 2.0 on that
  release's third anniversary**.

SSPL's copyleft triggers on *"making the functionality of the Program available to third
parties as a service."* Running it as internal infrastructure for your own product is the
ordinary reading of "not that" — but if that distinction becomes load-bearing in a
commercial product, take it to counsel rather than to a README.

**The modules in this repository are MIT.** That covers the Nix code only, not the server.

## Install

```nix
{
  inputs.nix-inngest.url = "github:kattakath/nix-inngest";

  # NixOS
  modules = [ inputs.nix-inngest.nixosModules.default ];

  # or home-manager, on darwin
  modules = [ inputs.nix-inngest.homeManagerModules.default ];
}
```

Both modules declare the same `services.inngest` option surface, shared from
`modules/common.nix` so they cannot drift. Only supervision differs: a systemd unit on
NixOS, a launchd user agent on darwin.

## Two deliberate divergences from upstream

**1. It binds loopback, not `0.0.0.0`.** Upstream `inngest start` binds all interfaces —
the API, the connect gateway, *and* an executor gRPC server on `:50053`. This module
defaults `host` to `127.0.0.1` so nothing is exposed by accident. Put a reverse proxy or
tunnel in front on purpose. `openFirewall` covers `port` and `connectGatewayPort` only;
`:50053` is never opened, because it should not be public.

**2. There is no string option for the signing key or event key.** They arrive *only* as
`INNGEST_SIGNING_KEY` / `INNGEST_EVENT_KEY` through `environmentFile`, because argv is
world-readable via `/proc`. A Postgres or Redis URI carrying a password belongs there too,
as `INNGEST_POSTGRES_URI` / `INNGEST_REDIS_URI` — the module warns if it spots an `@` in
the plain option.

```
# /run/agenix/inngest-env — place out-of-band, never commit
INNGEST_SIGNING_KEY=<hex, even number of characters>
INNGEST_EVENT_KEY=<key>
```

On NixOS this becomes a systemd `EnvironmentFile`. On darwin, launchd has no such
mechanism, so the wrapper sources the file at start — keeping the values out of the
world-readable `~/Library/LaunchAgents` plist. The darwin wrapper's `arg0` basename is
`nix-inngest` so macOS Background Task Manager shows a name that identifies its origin
rather than a bare interpreter.

## Persistence

| `postgresUri` | `redisUri` | Result |
|---|---|---|
| unset | unset | Bundled SQLite under `stateDir` + in-memory Redis. Zero dependencies, single node, no persistence guarantee for the queue. |
| set | set | External Postgres + Redis. The only configuration suitable for more than one node. |
| set | unset | External Postgres for configuration and history, bundled in-memory Redis for the queue. Durable state, but the queue keeps the single-node caveat. |
| unset | set | Rejected by an assertion — an external queue with SQLite state is not a coherent pairing. |

Two upstream behaviours worth knowing before you rely on this:

- **No automatic row cleanup.** Events, runs and traces accumulate in Postgres
  indefinitely; pruning is yours to schedule.
- **App sync does not poll by default.** Without `pollInterval`, a redeployed app must be
  re-synced explicitly (`curl -X PUT <app>/api/inngest`), and events emitted before that
  sync are **dropped with no replay**.

Inngest also states that its support team does not guarantee help for self-hosted
instances.

## Tests

```bash
nix flake check                 # eval checks: argv, secrets, hardening, launchd arg0
nix build .#vm-test             # opt-in: boots a VM and runs the real binary
```

The eval checks stub the package deliberately — they test *this module's* argv mapping,
secret handling and hardening, not upstream's build, and so stay fast and cache-friendly
despite the unfree dependency. `vm-test` is the complement: it builds the real package,
boots a NixOS VM, and asserts the service comes up **listening on loopback rather than
`0.0.0.0`** — the one claim an eval check cannot make. It is kept out of `checks` so
`nix flake check` never drags in the unfree closure.

Not `--all-systems`: every check is per-system (the NixOS `module-eval` on Linux, the
home-manager `hm-eval` on darwin), and that flag makes one machine try to BUILD the other
systems' checks, which fails with a `platform mismatch` unless a matching builder happens
to be attached. CI covers all three systems with one native runner each.

## Options

Beyond those above: `port` (8288), `connectGatewayPort` (8289), `stateDir`, `noUi`,
`queueWorkers`, `pollInterval`, `retryInterval`, `logLevel`, `extraArgs`, and — NixOS only
— `openFirewall` and `restartSec`. Every option carries a description; read them with
`nixos-option services.inngest` or in [`modules/common.nix`](modules/common.nix).
