# Health Checks via API and Oximeter

This project contains checks a customer can run over their own consumable surfaces:
the external API and oximeter timeseries (OxQL). The goal is to reduce
technician-port (techport) usage on the rack by moving health checks onto structured,
continuously-collected data.

This is intended to be a reference to provide one view of how an operator can monitor
a rack, not as a drop-in service for rack monitoring.

## Contents

- `techport-monitoring-spec.md` — the standing monitoring spec. Maps each of the
  twelve original health checks to a customer-consumable replacement, with OxQL
  queries, collection windows, alert thresholds, severities, and the required
  permission tier. Includes the one residual gap (NVMe SMART / U.2 block format).
- `test-monitoring-routes.sh` — read-only validation + inventory harness. Runs every
  API and OxQL route in the spec against a live rack and reports OK / EMPTY / DENIED /
  FAIL / SKIP per route, then adds per-sled inventory (threads, RAM, disks, zones,
  instances), per-sled storage capacity (U.2 vs M.2 pools), a rack-wide voltage anomaly
  scan, and a coverage table mapping each techport privileged-access check to the
  API/OxQL that satisfies it. Requires an authenticated `oxide` CLI and `jq`.

## Usage

```
./test-monitoring-routes.sh                 # full report (auto-discover rack and sled)
./test-monitoring-routes.sh -s              # short: summary + anomalies only, non-zero exit on an issue
./test-monitoring-routes.sh -c              # coverage only: techport-check map + per-check run result
./test-monitoring-routes.sh -n              # dry run: print commands, run nothing
./test-monitoring-routes.sh -v              # verbose: echo each command and raw errors
./test-monitoring-routes.sh -r RACK_UUID -w 30m
./test-monitoring-routes.sh -h              # help
```

Flags:

- `-r RACK_UUID` — scope rack-wide OxQL queries to a rack. Auto-discovered if omitted
  (the API exposes no rack serial; the UUID is the rack's only identifier).
- `-w WINDOW` — OxQL lookback window (default `5m`). Widen on a quiet rack.
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
- Everything is read-only: nothing is created, modified, or deleted.

## Status

Queries are validated against the omicron OxQL grammar and the nexus authz code with
a rack running r22.1. If you are using a different release, please test against your rack
to confirm that it returns the expected results.
