# Example output

Real output captured from a healthy colo rack (with host, sled serials, and
UUIDs scrubbed). Use this as a reference for what each section looks like;
figure out what a failure run looks like from the annotated blocks at the end.

Runs shown:

- `./oxcorder.sh` — full report (default mode)
- `./oxcorder.sh -s` — short: summary + anomalies only
- `./oxcorder.sh -c` — coverage only

## Full report — `./oxcorder.sh`

```
Oxcorder — long-range sensors for the rack

  Parameters (what each one scopes):
    scope    fleet
             every route is read fleet-wide, across every rack and sled. Each
             timeseries carries its own rack_id/sled_id, so results can be
             grouped or aggregated per rack as needed.
    sled     SRL0000001 (<uuid>)
             one sample sled, only to confirm the two per-sled endpoints
             respond (sled_disks, sled_instances). Disk, instance, memory,
             zone and voltage data is gathered for EVERY sled in the sections below.
    window   5m
             lookback for every OxQL timeseries query (widen with -w on a quiet rack).

External API

OxQL — fleet scope (needs fleet.viewer)

Summary
  ROUTE              SCOPE    STATUS  DETAIL
  -----              -----    ------  ------
  ping               fleet    OK     1 rows
  rack_list          fleet    OK     1 rows
  sled_list          fleet    OK     26 rows
  switch_list        fleet    EMPTY  0 rows
  disk_list          fleet    OK     100 rows
  sled_disks         fleet    OK     10 rows
  sled_instances     fleet    OK     24 rows
  ts_schemas         fleet    OK     100 rows
  M-INST-check       fleet    OK     1150 series
  M-INST-incomplete  fleet    OK     3 series
  M-DDM-SLED         fleet    OK     104 series
  M-DDM-RACK-cov     fleet    OK     104 series
  M-DDM-RACK-flap    fleet    OK     26 series
  M-SLED-PRESENT     fleet    OK     1119 series
  M-MEM-voltage      fleet    OK     1999 series
  M-THERM-tctl       fleet    EMPTY  0 series
  M-THERM-senserr    fleet    OK     211 series
  M-ZONES            fleet    OK     1119 series
  M-SVC              fleet    OK     1589 series
  M-POOL             fleet    OK     311 series
  M-DATASET          fleet    OK     6199 series
  M-STORAGE-IO       fleet    EMPTY  0 series


Per-sled inventory  (THREADS/RAM_GiB/DISKS/ZONES should match across sleds; INSTANCES is workload-dependent)
  SERIAL       STATE   POLICY      THREADS  RAM_GiB  DISKS  ZONES  INSTANCES
  SRL0000001   active  in_service  128      1535     10     14     1
  SRL0000002   active  in_service  128      1011     11     22     8
  SRL0000003   active  in_service  128      1011     10     28     15
  SRL0000004   active  in_service  128      1011     10     26     13
  SRL0000005   active  in_service  128      1011     10     26     13
  SRL0000006   active  in_service  128      1011      9     34     21
  SRL0000007   active  in_service  128      895       9     28     15
  SRL0000008   active  in_service  128      1011     10     24     12
  SRL0000009   active  in_service  128      1011     10     24     12
  SRL0000010   active  in_service  128      1011     10     39     17
  SRL0000011   active  in_service  128      1011     10     27     14
  SRL0000012   active  in_service  128      1011      9     38     25
  SRL0000013   active  in_service  128      1011     10     27     15
  SRL0000014   active  in_service  128      1011     10     40     27
  SRL0000015   active  in_service  128      1011     10     43     30
  SRL0000016   active  in_service  128      1011     10     25     11
  SRL0000017   active  in_service  128      1011     10     36     24
  SRL0000018   active  in_service  128      1011     10     27     14
  SRL0000019   active  in_service  128      1011     10     40     27
  SRL0000020   active  in_service  128      1011     10     27     15
  SRL0000021   active  in_service  128      1011     10     24     12
  SRL0000022   active  in_service  128      1011     10     22     9
  SRL0000023   active  in_service  128      1011     10     20     8
  SRL0000024   active  in_service  128      1011     10     14     1
  SRL0000025   active  in_service  128      1011     10     22     9
  SRL0000026   active  in_service  128      1011     10     20     8
  26 sled(s); DISKS/ZONES blank as "?" mean the sled did not answer or had no telemetry

Zones per sled  (from sled_data_link telemetry, last 5m)
  SRL0000001  (14 zones, 5 types)
      crucible            10
      global              1
      nexus               1
      ntp                 1
      propolis-server     1
  SRL0000002  (22 zones, 6 types)
      crucible            10
      propolis-server     8
      global              1
      internal_dns        1
      ntp                 1
      switch              1
  SRL0000003  (28 zones, 5 types)
      propolis-server     15
      crucible            10
      cockroachdb         1
      global              1
      ntp                 1

  …(remaining sleds elided — same structure)…

Storage per sled  (zfs_pool; EXT=U.2 data pools, INT=M.2 boot; USED/TOTAL are external pools; disk IO not available sled-wide — see spec)
  SERIAL       EXT_POOLS  INT_POOLS  USED_TiB  TOTAL_TiB  PCT
  SRL0000004   10         3          8.85      29.06      30
  SRL0000005   10         3          8.25      29.06      28
  SRL0000018   10         3          8.19      29.06      28
  SRL0000001   10         3          16.1      58.13      28
  SRL0000016   10         3          7.93      29.06      27
  SRL0000009   10         3          7.43      29.06      26
  SRL0000010   10         3          7.35      29.06      25
  SRL0000007   10         3          7.23      29.06      25
  SRL0000014   10         3          6.74      29.06      23

  …(remaining sleds elided — same structure)…

Voltage anomaly scan  (rack-wide hardware_component:voltage, last 5m; flags rails < 0.5 V; ignores ["V12_MCIO_A0HP"])
  all rails nominal across 29 chassis (1999 sensors)
Legend: OK=data returned  EMPTY=ran, no rows (healthy for the M-THERM-tctl fault filter)
        DENIED=permission (check token role)  FAIL=error (see -v)  SKIP=not run

  All nominal — every sensor reading within expected parameters.
```

## Short — `./oxcorder.sh -s`

Same Summary table as above, then nothing but the final status line. Good for
gating a script on (non-zero exit on a failed/denied route or a dropped rail):

```
Summary
  ROUTE              SCOPE    STATUS  DETAIL
  …(same table as above)…

  All nominal — every sensor reading within expected parameters.
```

## Coverage only — `./oxcorder.sh -c`

Static reference table plus this run's per-check result:

```
Coverage vs techport privileged-access check  (each check -> the API/OxQL that satisfies it here)
  TECHPORT CHECK                HARNESS ROUTE(S)                 COVERAGE
  1  rss_time                   rack_list (time_created)         Indirect
  2  rss_state                  ping, rack_list                  Indirect
  3  instances STATE!=INTENT    M-INST-check, M-INST-incomplete  Indirect
  4  ddm_peers (rack)           M-DDM-RACK-cov, M-DDM-RACK-flap  Direct
  5  zones (rack)               M-ZONES                          Indirect
  6  sled presence              sled_list, M-SLED-PRESENT        Direct
  7  memory                     sled_list (RAM), M-MEM-voltage   Direct
  8a disks: count/presence      sled_disks, M-POOL               Direct
  8b disks: SMART/block-format  (none)                           Not possible
  9  zpools                     M-STORAGE-IO                     Indirect
  10 services                   M-SVC                            Indirect
  11 ddm_peers (sled)           M-DDM-SLED                       Direct
  12 zones (sled)               M-ZONES                          Indirect

Run result by check  (did this run's routes for each check come back clean?)
  1   rss_time                     PASS
  2   rss_state                    PASS
  3   instances STATE!=INTENT      PASS
  4   ddm_peers (rack)             PASS
  5   zones (rack)                 PASS
  6   sled presence                PASS
  7   memory                       PASS
  8a  disks: count/presence       PASS
  8b  disks: SMART/block-format   N/A
  9   zpools                       PASS
  10  services                     PASS
  11  ddm_peers (sled)             PASS
  12  zones (sled)                 PASS

  Run PASSED — 11 checks reachable, 0 skipped, 1 not possible.
```

## Dry run — `./oxcorder.sh -n`

Prints the commands that would run without executing anything. `-v -n` shows
the same lines with the `scanning:` prefix (this is what `-v` echoes during a
real run too):

```
  ping             fleet  oxide api /v1/ping
  rack_list        fleet  oxide api /v1/system/hardware/racks
  sled_list        fleet  oxide api /v1/system/hardware/sleds
  …
  M-THERM-tctl     fleet  oxide experimental system timeseries query --query 'get hardware_component:amd_cpu_tctl | filter timestamp > @now() - 5m && datum >= 95.0'
  …
```

## Failure state (illustrative, not a live capture)

Live runs against a healthy rack always end `All nominal`. To see the anomaly
path you need a failing or denied route or a dropped rail; the output looks
like:

```
Summary
  ROUTE              SCOPE    STATUS  DETAIL
  -----              -----    ------  ------
  ping               fleet    OK     1 rows
  rack_list          fleet    OK     1 rows
  M-MEM-voltage      fleet    DENIED 403 forbidden: insufficient role

  Anomaly detected — one or more routes failed or were denied. Re-run with -v for details.
```

and a dropped rail turns the voltage section red:

```
Voltage anomaly scan  (rack-wide hardware_component:voltage, last 5m; flags rails < 0.5 V; ignores ["V12_MCIO_A0HP"])
  CHASSIS   KIND       SENSOR      VOLTS
  SRL00002  sled       V12_CPU    0.42 V
  1 rail(s) below 0.5 V — likely dropped; investigate
```
