# rkdeploy-health-monitoring

Replacing the `rkdeploy check-health` techport sweep with checks a customer can
run over their own consumable surfaces: the external API, wicket, and oximeter
timeseries (OxQL). The goal is to reduce technician-port usage on the rack by
moving health checks onto structured, continuously-collected data.

## Contents

- `rkdeploy-monitoring-spec.md` — the standing monitoring spec. Maps each of the
  twelve original health checks to a customer-consumable replacement, with OxQL
  queries, collection windows, alert thresholds, severities, and the required
  permission tier. Includes the one residual gap (NVMe SMART / U.2 block format).
- `test-monitoring-routes.sh` — read-only validation harness. Runs every API and
  OxQL route in the spec against a live rack and reports OK / EMPTY / DENIED /
  FAIL / SKIP per route. Requires an authenticated `oxide` CLI and `jq`.

## Usage

```
./test-monitoring-routes.sh          # full report (auto-discover rack and sled)
./test-monitoring-routes.sh -s       # short: summary + anomalies only, non-zero exit on an issue
./test-monitoring-routes.sh -c       # coverage only: rkdeploy-check map + per-check run result
./test-monitoring-routes.sh -n       # dry run: print commands, run nothing
./test-monitoring-routes.sh -v       # verbose errors
./test-monitoring-routes.sh -r RACK_UUID -p PROJECT -w 30m
```

## Permissions

- Fleet-scoped routes (all but one): minimum role `fleet.viewer`.
- Storage-I/O (`virtual_disk`) is queried fleet-wide via the system endpoint, so it needs only `fleet.viewer` and covers every silo.
- Wicket checks (rack setup, presence): technician-port + SSH, not silo RBAC.

## Status

Queries are validated against the omicron OxQL grammar and the nexus authz code,
but not yet against a live rack. Run the harness on dogfood or a colo rack to
confirm timeseries names and zone-naming assumptions before wiring alerts.
