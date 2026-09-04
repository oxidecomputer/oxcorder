# Oxcorder: Like a tricorder, but for the rack.

Oxcorder reads an Oxide rack the way McCoy reads a readshirt:
quickly, accurately, and without laying a hand on it. Unlike the 
redshirt, the rack tends to survive the episode.

Oxcorder contains checks a customer can run over their own consumable surfaces:
the external API and oximeter timeseries (OxQL). The goal is to reduce
technician-port (techport) usage on the rack by moving health checks onto structured,
continuously-collected data.

The inspiration for this is an internal tool that, as one of it's features, retrieves 
a collection of health and inventory data from a fleet of Oxide racks. This is useful,
but does require tech port access as written. However, nearly all of this data is 
accessible to a rack operator with fleet level permissions (albeit indirectly in a few 
cases).

This is intended to be a reference to provide one view of how an operator can monitor
a rack, not as a drop-in service for rack monitoring. 


## Contents

- `techport-monitoring-spec.md` — the standing monitoring spec. Maps each of the
  twelve original health checks to a customer-consumable replacement, with OxQL
  queries, collection windows, alert thresholds, severities, and the required
  permission tier. Includes the one residual gap (NVMe SMART / U.2 block format).
- `example-output.md` — annotated real output (host, serials, and UUIDs
  scrubbed) for the full, short, coverage, and dry-run modes, plus the shape
  of a failure run.
- `oxcorder.sh` — read-only validation + inventory harness. Runs every
  API and OxQL route in the spec against a live rack and reports OK / EMPTY / DENIED /
  FAIL / SKIP per route, then adds per-sled inventory (threads, RAM, disks, zones,
  instances), per-sled storage capacity (U.2 vs M.2 pools), a rack-wide voltage anomaly
  scan, and a coverage table mapping each techport privileged-access check to the
  API/OxQL that satisfies it. Requires an authenticated `oxide` CLI and `jq`.

## Usage

```
./oxcorder.sh                # full report
./oxcorder.sh -s             # short: summary + anomalies only, non-zero exit on an issue
./oxcorder.sh -c             # coverage only: techport-check map + per-check run result
./oxcorder.sh -n             # dry run: print commands, run nothing
./oxcorder.sh -v             # verbose: echo each command and raw errors
./oxcorder.sh -w 30m         # use a lookback period of 30m instead of the default 5m
./oxcorder.sh -t 60          # 60s per-call timeout (raise for wide queries on a big fleet)
./oxcorder.sh -h             # help
```

Flags:

- `-w WINDOW` — OxQL lookback window (default `5m`). Widen on a quiet rack.
- `-t SECS` — per-call timeout in seconds (default `30`, or the `OXC_TIMEOUT` env var).
  Raise it if a wide query (e.g. `hardware_component:voltage` on a large fleet) is killed
  and shows `FAIL`.
- `-s` — short: Summary plus any anomalies only; exit non-zero on an issue. Runs every
  route but suppresses the detail sections. Meant to be called from a script.
- `-c` — coverage: show only the techport-check coverage table and the per-check run
  result. (`-s` and `-c` are mutually exclusive; the last one given wins.)
- `-v` — verbose: print each command and the raw error on failure.
- `-n` — dry run: print the commands without executing them.
- `-h` — help.

Exit status: `0` when every executed route is reachable and no voltage anomaly was
found; `1` if a route FAILED or was DENIED, or a rail read below 0.5 V. This holds in
every mode, so `-s` is safe to gate a script on.

## Permissions

- Every route is fleet-scoped and needs only the minimum role `fleet.viewer`.
  All timeseries are queried fleet-wide, across every silo, so the system endpoints
  (`/v1/system/...`) cover every silo as well.
- Every timeseries carries its own `rack_id`/`sled_id` fields, so results are a
  built-in dimension keyed per rack — ready to group or aggregate across racks as
  the fleet grows. There is no single-rack CLI restriction; queries read fleet-wide.
- Everything is read-only: nothing is created, modified, or deleted.

## Testing

Unit and smoke tests use [bats-core](https://github.com/bats-core/bats-core):

```
./tests/run.sh        # checks bats + jq are installed, then runs the suite
```

They exercise the jq transforms and verdict logic (zone grouping, the U.2/M.2
storage split, the voltage anomaly scan and its ignore list, the per-check
run-result, `classify_err`, and the timeout fallback) against fixtures under
`tests/fixtures/` — no rack needed — plus one end-to-end run driven by a fake
`oxide` on `PATH`. The harness is sourced by the tests via a `BASH_SOURCE`
main-guard, so sourcing it defines the functions without starting a run.

## Container

A pinned, self-contained image runs both the tests and live scans — Alpine plus
bash, jq, the `oxide` CLI (static musl build), and bats-core:

```
docker build -t oxcorder .
```

Tests (no rack or auth needed):

```
docker run --rm oxcorder test
```

Live scan with a `fleet.viewer` token:

```
docker run --rm \
  -e OXIDE_HOST="https://<silo>.sys.<rack>.example.com" \
  -e OXIDE_TOKEN="oxide-token-..." \
  oxcorder -s
```

Or, if you authenticate with `oxide auth login` (which writes `~/.config/oxide/`),
mount that instead of passing a token:

```
docker run --rm -v ~/.config/oxide:/root/.config/oxide:ro oxcorder -s
```

On a large fleet the wide queries can exceed the 30s per-call timeout and show
`FAIL`; give them more room with `-t` or the `OXC_TIMEOUT` env var:

```
docker run --rm -e OXC_TIMEOUT=90 -v ~/.config/oxide:/root/.config/oxide:ro oxcorder -s
```

`run` (the default) takes any oxcorder flag (`-s`, `-c`, `-w 30m`); `test` runs
the bats suite; `shell` drops you into bash. Pinned versions are build args —
`ALPINE_VERSION`, `OXIDE_VERSION`, `BATS_VERSION` — e.g. to move the CLI:

```
docker build --build-arg OXIDE_VERSION=v0.19.0+... -t oxcorder .
```

## Status

Queries are validated against the omicron OxQL grammar and the nexus authz code with
a rack running r22.1. If you are using a different release, please test against your rack
to confirm that it returns the expected results.

## Example output

Real output from a healthy rack, with the host, serial numbers, and UUIDs
scrubbed, is in [`example-output.md`](example-output.md). Under a good rack the
run ends with:

```
  All nominal — every sensor reading within expected parameters.
```
