# Technician-Port Health Check → Customer-Consumable Monitoring Spec

*Standing monitoring spec for replacing the technician-port (techport) privileged-access health check with external API, wicket, and oximeter/OxQL.*
*Target: latest release. Wicket scope: customer TUI only. Date: 2026-09-02.*
*OxQL validated against omicron `oximeter/db/src/oxql/ast/grammar.rs`; permissions against `nexus/src/app/metrics.rs`.*

## Purpose

The privileged-access health check (`check-health`) runs entirely over the technician port: SSH into the switch zone, SSH from there into every sled's global zone, plus a few wicketd calls on the same network. This spec replaces those checks with surfaces a customer already has — the external API, the wicket TUI, and oximeter timeseries queried through the API — so the checks can run 24/7/365 as standing monitors instead of a synchronous, techport-bound sweep.

The design assumption is continuous collection. A synchronous SSH check answers "healthy right now." A continuously collected timeseries answers "healthy, and trending which way," and it makes one thing queryable that has no direct API: the **absence of expected telemetry**. A control-plane zone that dies stops emitting its data-link and HTTP series; the monitor detects the gap, not the `svcs` state. Oxide support already uses this technique in the field (see cs-914, where a sled hang was pinned to the timestamp `sled_data_link:bytes_received` stopped emitting).

## Permissions

Two tiers, taken from the authz code, not inferred.

**Fleet read — minimum built-in role `fleet.viewer`.** Every monitor except M-STORAGE-IO needs this. `system_timeseries_query` authorizes `Action::Read` on `authz::FLEET` (`nexus/src/app/metrics.rs:138`), and the fleet timeseries (`ddm_session`, `hardware_component`, `sled_data_link`, `http_service`, `virtual_machine`, `zfs_pool`, `zfs_dataset`) are all `authz_scope = "fleet"`. The `/v1/system/hardware/*` endpoints sit on the same footing. Per `omicron/docs/debugging-authz.adoc`, the `viewer` role grants `read`, and `fleet.viewer` is "can read most resources in the system." A read-only fleet token suffices — no admin or collaborator.

**All routes are fleet-scoped.** Even M-STORAGE-IO, whose `virtual_disk` series carries `authz_scope = "project"`, is queried through the fleet `system_timeseries_query` endpoint, which injects no project filter (`insert_authz_filters` returns the query unchanged for `Fleet`) — so it runs with `fleet.viewer` and covers every silo's disks rack-wide. (A project viewer could instead read only their own project via the `--project` path, but the harness does not.)

Caveats: `metrics.rs` carries an explicit `TODO-security` — fleet timeseries have no finer-grained scoping yet, so `fleet.viewer` is all-or-nothing (it reads every silo's metrics; a token cannot be scoped to one rack's sleds). Wicket (checks 1, 2, 6) is a separate access path: physical technician-port plus SSH to the switch, not silo RBAC.

## OxQL conventions (validated)

Confirmed against the grammar:

- Table ops are `get`, `filter`, `align`, `group_by`, `join`, `limit`. Timeseries name is `target:metric`.
- `group_by [fields], <reducer>` supports **only `mean` and `sum`** — there is no `count` and no `max` reducer. To count sessions, zones, or links per group, enumerate the returned timeseries client-side (one series per unique field tuple); OxQL does not count server-side.
- `group_by` requires aligned input, so precede it with `align mean_within(<dur>)` (or `align interpolate(<dur>)`).
- Filter on a metric's value with the literal keyword **`datum`** (`filter datum > 0`), not the metric name. Filter on fields by name (`sled_id == "..."`), and on time with `timestamp > @now() - 5m`.
- A `datum` comparison must match the metric's numeric type: integer metrics take an integer literal (`datum > 0`), floating-point metrics — temperatures, voltages, anything `f32`/`f64` — take a decimal literal (`datum >= 95.0`). An integer literal against a float metric is rejected at query time. (Confirmed live: `amd_cpu_tctl` errored on `>= 95`, ran on `>= 95.0`.)
- Duration units: `Y M w d h m s ms`.

Data shapes: gauges (`imported_underlay_prefixes`, `usable_physical_ram`, `voltage`, `amd_cpu_tctl`) read as a current value; cumulative counters (`peer_expirations`, `check`, `incomplete_check`, `failed_reads`, `sensor_error_count`, `bytes_*`) are meaningless as a raw total — align and read the slope.

Severity is used consistently: **critical** means block commissioning or page an operator; **warning** means investigate.

---

## Monitors

### Group A — Control plane and instances

#### M-INST — Instance health (replaces check 3, `omdb db instance list`)

```
# Roster: per sled, iterate sled ids from /v1/system/hardware/sleds
oxide api /v1/system/hardware/sleds/{sled_id}/instances

# Instances the sled-agent reports failed (one series per failing instance)
oxide experimental timeseries query --query \
  'get virtual_machine:check
   | filter timestamp > @now() - 5m && state == "failed"'

# Instances Nexus could not check at all (the harder failure)
oxide experimental timeseries query --query \
  'get virtual_machine:incomplete_check
   | filter timestamp > @now() - 5m'
```

- **Window / cadence:** 5m window, evaluate every 1m.
- **Condition:** any instance emitting `incomplete_check`, or `check{state="failed"}`, with the counter still climbing across two consecutive windows. Enumerate the returned series (keyed by `instance_id`, `reason`/`failure_reason`) client-side.
- **Severity:** warning on a single window; critical if sustained past 5m or affecting more than one instance on a sled.
- **Notes:** detects *failed to converge*, not the exact STATE≠INTENT column, so it will not flag a benign in-flight transition — the intended behavior for a standing monitor.

### Group B — Underlay networking (DDM)

#### M-DDM-SLED — Per-sled DDM sessions (replaces check 11)

```
oxide experimental timeseries query --query \
  'get ddm_session:imported_underlay_prefixes
   | filter timestamp > @now() - 5m && datum > 0'
```

- **Window / cadence:** 5m window, evaluate every 1m.
- **Condition:** the result has one series per active session, keyed by `sled_id` and `interface`. Count series per `sled_id` client-side; expect 2 (one per switch zone). One means a lost path; zero or absent means the sled lost underlay peering.
- **Severity:** warning at 1, critical at 0 or absent.

#### M-DDM-RACK — Rack-wide DDM peering and flap (replaces check 4)

```
# Coverage: one series per active session, rack-wide
oxide experimental timeseries query --query \
  'get ddm_session:imported_underlay_prefixes
   | filter timestamp > @now() - 5m && rack_id == "<rack-uuid>" && datum > 0'

# Flap: expiration slope per sled
oxide experimental timeseries query --query \
  'get ddm_session:peer_expirations
   | filter timestamp > @now() - 1h && rack_id == "<rack-uuid>"
   | align mean_within(5m)
   | group_by [sled_id], sum'
```

- **Window / cadence:** 5m coverage, 1h flap; evaluate every 5m.
- **Condition:** coverage — enumerate `sled_id`s present and diff against the roster; every active sled should show 2 series. Flap — `peer_expirations` non-zero and climbing over the hour.
- **Severity:** critical on a coverage miss; warning on a flap trend, escalating if it persists past an hour.
- **Notes:** `ddm_session` is sled-side, so "both switches agree" is reconstructed as "2 sessions per sled" rather than read from the switch's peer list. For the switch vantage, pair with `ddm_router:originated_underlay_prefixes` and `switch_rib`.

### Group C — Sled and hardware presence

#### M-SLED-PRESENT — Sled presence and liveness (replaces check 6)

```
oxide api /v1/system/hardware/sleds

oxide experimental timeseries query --query \
  'get sled_data_link:bytes_received
   | filter timestamp > @now() - 5m && rack_id == "<rack-uuid>"'
```

- **Window / cadence:** 5m window, evaluate every 1m.
- **Condition:** enumerate distinct `sled_id` in the result. A sled in the API roster whose newest sample is older than roughly 90 seconds (about nine missed intervals) has gone dark.
- **Severity:** critical. Also visible directly in the wicket System Inventory power state.

#### M-MEM — Memory (replaces check 7, `prtconf -m`)

```
oxide api /v1/system/hardware/sleds/{sled_id}   # read usable_physical_ram

# DIMM rail dropout, as an early trend
oxide experimental timeseries query --query \
  'get hardware_component:voltage
   | filter timestamp > @now() - 5m && chassis_serial == "<serial>"'
```

- **Window / cadence:** `usable_physical_ram` is config-time — check daily or on inventory change. Voltage trend on 5m, evaluate every 5m.
- **Condition:** `usable_physical_ram` not equal to the model's expected value; or a DDR rail (`sensor == "V12_DDR5_GHIJKL_A0"`, etc.) reading near 0 V while the sled is powered. Filter by exact sensor name or enumerate the series.
- **Severity:** critical. A lost DIMM bank shows here before the sled falls over (cs-932, cs-914).

#### M-THERM — Component thermals and sensor errors (new, enabled by continuous collection)

```
oxide experimental timeseries query --query \
  'get hardware_component:amd_cpu_tctl
   | filter timestamp > @now() - 5m && datum >= 95.0'

oxide experimental timeseries query --query \
  'get hardware_component:sensor_error_count
   | filter timestamp > @now() - 15m
   | align mean_within(5m)
   | group_by [chassis_serial, sensor], sum'
```

- **Window / cadence:** 5m thermals, 15m error window; evaluate every 5m.
- **Condition:** any `amd_cpu_tctl` point at or above `95.0` (internal throttling; `100.0` is shutdown, per the metric's own doc) — the literal must be decimal because the metric is floating-point. `sensor_error_count`/`poll_error_count` are cumulative, so a nonzero total is the rack's lifetime count, not an active fault (a live run matched 193 series that way, none of them faults); alert on the per-window increase from the aligned query above, not on `datum > 0`.
- **Severity:** warning at Tctl 95, critical at 100 or on a rising sensor-error slope.
- **Notes:** not in the original check set, but the cheapest high-value thing continuous collection buys, and the failure mode that dominates the field issues.

### Group D — Storage

#### M-DISK-PRESENT — Physical disk presence and fault (replaces check 8, presence half)

```
oxide api /v1/system/hardware/sleds/{sled_id}/disks   # sled_physical_disk_list
```

- **Window / cadence:** poll every 5m.
- **Condition:** disk count per sled below expected, or any disk with `state` not `active` / `policy` expunged.
- **Severity:** critical.
- **Notes:** Nexus-level view — presence and faulted state. Does **not** cover SMART "Device Reliability" or the U.2 4096 block-format check (see Residual Gaps).

#### M-STORAGE-IO — Storage I/O failures (trend proxy for check 9, `zpool status -x`)

```
oxide experimental system timeseries query --query \
  'get virtual_disk:failed_reads
   | filter timestamp > @now() - 1h && datum > 0'
```

- **Window / cadence:** 1h window, evaluate every 5m. Run the same against `virtual_disk:failed_writes`.
- **Condition:** any disk with non-zero, climbing failed I/O; sustained zero is the healthy baseline.
- **Severity:** warning on first non-zero, critical on a sustained climb.
- **Notes:** downstream symptom, not `zpool status` — catches a pool hurting guests, not one degraded but still serving. Pair with M-DISK-PRESENT. Runs fleet-wide via the system timeseries endpoint (no project filter injected), so it covers every silo's disks with `fleet.viewer`.

#### M-POOL-CAP — Per-sled zpool capacity (new; the sled-wide storage signal that exists)

```
oxide experimental system timeseries query --query \
  'get zfs_pool:bytes_allocated
   | filter timestamp > @now() - 5m && rack_id == "<rack-uuid>"'
# pair with zfs_pool:bytes_total, joined on pool_id, to get percent-used
```

- **Window / cadence:** 5m window, evaluate every 5m (capacity moves slowly).
- **Condition:** join `bytes_allocated` and `bytes_total` by `pool_id`, aggregate per `sled_serial`, and alert when a sled's percent-used crosses a threshold or when one sled diverges from the rack. `zfs_dataset:bytes_used` gives the same at dataset granularity.
- **Severity:** warning at 80% used, critical at 90%.
- **Cross-check:** split pools by kind — external (`oxp_`, U.2 data) vs internal (`oxi_`, M.2 boot). On a healthy sled the external-pool count equals both its U.2 disk count (`sled_physical_disk_list`) and its crucible-zone count. A sled with fewer external pools than physical disks has a U.2 present but not in service — the field run caught two such sleds this way.
- **Notes:** fleet-scoped and keyed by `sled_id`/`sled_serial`, so this is a genuine per-sled view. **Disk IO, by contrast, has no sled-wide series.** The only IO metrics live on `virtual_disk` (`reads`, `writes`, `io_latency`, `io_size`, ...), which is `authz_scope = "project"` and carries `disk_id`, `attached_instance_id`, `project_id`, and `silo_id` but **no `sled_id`**. A `fleet.viewer` token can still query `virtual_disk` across every project (the fleet query path injects no project filter — `insert_authz_filters` returns the query unchanged for `Fleet`), but it can never attribute IO to a physical sled; and because Crucible replicates each disk's regions across three sleds, guest IO would not map to one sled's physical IO even if it were tagged. Physical NVMe IO is not exported to oximeter at all. So for storage, capacity is per-sled (here) and IO is project/virtual-disk-only.

### Group E — Services and zones

#### M-ZONES — Zone roster by telemetry presence (trend proxy for checks 5, 12)

```
oxide experimental timeseries query --query \
  'get sled_data_link:bytes_sent
   | filter timestamp > @now() - 5m && rack_id == "<rack-uuid>"'
```

- **Window / cadence:** 5m window, evaluate every 5m.
- **Condition:** enumerate distinct `(sled_id, zone_name)` in the result — the live per-sled zone roster. Diff against expected: every sled should show `oxz_ntp_*` and its `oxz_crucible_*` zones; scrimlets should also show `oxz_switch`. A missing zone name is the shortfall.
- **Severity:** critical on a missing control-plane zone.
- **Notes:** stronger than the snapshot for a zone present but wedged and no longer emitting; weaker in that a freshly started zone takes a collection interval to appear.

#### M-SVC — Control-plane service liveness (trend proxy for check 10, `svcs -xZ`)

```
oxide experimental timeseries query --query \
  'get http_service:request_latency_histogram
   | filter timestamp > @now() - 15m'
```

- **Window / cadence:** 15m window, evaluate every 5m.
- **Condition:** enumerate distinct `name` (the emitting HTTP services). Alert on any baseline service that drops out, or whose latency distribution shifts materially.
- **Severity:** warning on a latency shift, critical on a service going silent.
- **Notes:** covers the dropshot services (Nexus and internal HTTP servers). Does not see SMF maintenance state for non-HTTP services — that half stays a gap.

### Group F — Rack setup (commissioning-time, not standing)

Checks 1 (`rss_time`) and 2 (`rss_state`) are one-shot commissioning values. The customer path is the wicket Rack Setup tab — the TUI surface over the same wicketd state the privileged-access check reads today. Once initialized, external API liveness (`ping`, `rack_list` returning) confirms the same fact.

---

## Summary

| Monitor | Replaces | Source | Scope | Window | Eval | Alert condition | Severity |
|---------|----------|--------|-------|--------|------|-----------------|----------|
| M-INST | instances | API + `vm_health_check` | fleet | 5m | 1m | failed/incomplete check climbing | warn→crit |
| M-DDM-SLED | sled ddm_peers | `ddm_session` | fleet | 5m | 1m | session series per sled < 2 | warn/crit |
| M-DDM-RACK | rack ddm_peers | `ddm_session` | fleet | 5m/1h | 5m | sled missing, or expiration flap | crit/warn |
| M-SLED-PRESENT | sled presence | API + `sled_data_link` | fleet | 5m | 1m | in roster but no recent sample | crit |
| M-MEM | memory | `usable_physical_ram` + `hardware_component` | fleet | 1d/5m | 5m | RAM ≠ expected, or DIMM rail ~0 V | crit |
| M-THERM | (new) | `hardware_component` | fleet | 5m/15m | 5m | Tctl ≥ 95/100, sensor errors rising | warn/crit |
| M-DISK-PRESENT | disks (presence) | `physical_disk_list` | fleet | — | 5m | count low or disk not active | crit |
| M-STORAGE-IO | zpools | `virtual_disk:failed_*` | fleet | 1h | 5m | failed I/O climbing | warn/crit |
| M-POOL-CAP | (new) | `zfs_pool` (+ `zfs_dataset`) | fleet | 5m | 5m | pool percent-used high, or a sled diverges | warn/crit |
| M-ZONES | zones | `sled_data_link` | fleet | 5m | 5m | expected zone not emitting | crit |
| M-SVC | services | `http_service` | fleet | 15m | 5m | service silent or latency shift | warn/crit |

Seven of the original twelve checks become full replacements; four become trend proxies arguably better than the snapshot they replace; M-THERM is a bonus the original never had.

## Residual gaps

One check has no customer-consumable telemetry at any cadence, confirmed by the absence of any NVMe, SMART, wear, or reliability timeseries in the API spec:

- **NVMe SMART "Device Reliability"** (check 8) — Nexus knows a disk is faulted, not that SMART predicts failure. Continuous collection does not help because the metric does not exist.
- **U.2 block format (4096)** (check 8) — no customer surface exposes the block size.

Both are commissioning-time correctness checks, so their absence matters most during bring-up. To survive the move off the techport, the ask is a new sled-agent/oximeter timeseries carrying per-disk SMART critical-warning fields and block format, scoped to fleet. That is the one feature request this migration depends on.

## Field validation

First live run on 2026-09-03 (rack `de608e01-b8e4-4d93-b972-a7dbed36dd22`, latest release). All routes reachable with a `fleet.viewer` token; the project-scoped storage check ran clean at project scope. Corrections applied from that run:

- `amd_cpu_tctl` threshold must use a decimal literal (`>= 95.0`); an integer literal errored (see the numeric-typing rule under OxQL conventions).
- `sensor_error_count` is cumulative — the initial `datum > 0` matched lifetime totals (193 series), so the query and condition now read the per-window increase instead.

Observations worth a second look, not blockers:

- `GET /v1/system/hardware/switches` returned 0 rows on this rack. Switch presence in this spec already routes through the wicket System Inventory, not this endpoint, so the monitors are unaffected — but if the API path is wanted for switch presence, confirm why it is empty on a running rack before relying on it.

## Sources

- `rkdeploy/crates/rack-core/src/health.rs`, `rack.rs`, `zone.rs` — the privileged-access (techport) checks being replaced (the `rkdeploy` repository is internal to Oxide; not customer-accessible).
- `omicron/oximeter/db/src/oxql/ast/grammar.rs` — OxQL grammar (reducers `mean`/`sum` only; `align mean_within`; `filter datum`).
- `omicron/nexus/src/app/metrics.rs` — timeseries authz (`Action::Read` on `FLEET`; project-scoped variant).
- `omicron/docs/debugging-authz.adoc` — role model (`viewer` grants read; `fleet.viewer` reads the system).
- `docs/app/specs/api.json` — external API endpoints.
- `docs/app/specs/tables/{vm-health-check,ddm-session,ddm-router,hardware-component,sled-data-link,http-service,virtual-disk,switch-rib}.toml` — timeseries schemas and `authz_scope`.
- `customer-support/runbooks/troubleshooting-commands.adoc`, `troubleshooting-access-matrix.adoc` — OxQL CLI and operator access.
- `customer-support/toolbox/customer-status/issues_raw.json` — field use of the telemetry-gap technique (cs-914, cs-932).
