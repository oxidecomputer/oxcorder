#!/usr/bin/env bats
#
# Unit + smoke tests for oxcorder.sh.
#
# These exercise the pure jq transforms and verdict logic (where every bug in
# this tool has lived) without touching a real rack: functions read from a
# temp $TMP we pre-populate with fixtures, and a fake `oxide` on PATH feeds the
# few functions that shell out. Requires bats-core and jq.

setup() {
  OXC_ROOT="${BATS_TEST_DIRNAME}/.."
  FIX="${BATS_TEST_DIRNAME}/fixtures"
  # Sourceable via the main-guard: no run happens on source.
  source "${OXC_ROOT}/oxcorder.sh"
  # Deterministic, colour-free state for assertions.
  DRYRUN=0; MODE="full"; WINDOW="5m"; TIMEOUT_BIN=""
  C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_R=""
  VOLT_IGNORE='["V12_MCIO_A0HP"]'
  TMP="$(mktemp -d)"
}
teardown() { rm -rf "$TMP"; }

# put the fake oxide on PATH for a run and expose the fixtures dir to it
with_fake_oxide() {
  local bindir="$TMP/bin"; mkdir -p "$bindir"
  cp "${BATS_TEST_DIRNAME}/fake-oxide" "$bindir/oxide"; chmod +x "$bindir/oxide"
  export OXC_FIXTURES="$FIX"
  export PATH="$bindir:$PATH"
}

# --- sourceability (the main-guard) --------------------------------------
@test "script is sourceable without executing a run" {
  run bash -c "source '${OXC_ROOT}/oxcorder.sh'; echo SOURCED_OK"
  [ "$status" -eq 0 ]
  [[ "$output" =~ SOURCED_OK ]]                  # sourced cleanly (no negative index: bash 3.2 safe)
  [[ ! "$output" =~ "long-range sensors" ]]      # main did not run (no banner)
}

# --- classify_err --------------------------------------------------------
@test "classify_err: 403 -> DENIED" {
  echo "error: 403 Forbidden" > "$TMP/e"
  run classify_err "$TMP/e"; [ "$output" = "DENIED" ]
}
@test "classify_err: anything else -> FAIL" {
  echo "connection refused" > "$TMP/e"
  run classify_err "$TMP/e"; [ "$output" = "FAIL" ]
}

# --- ox timeout fallback -------------------------------------------------
@test "ox: runs the command directly when no timeout tool is set" {
  TIMEOUT_BIN=""
  run ox echo hello
  [ "$status" -eq 0 ] && [ "$output" = "hello" ]
}

# --- route_status --------------------------------------------------------
@test "route_status: hit, other-status, and miss" {
  RESULTS=("ping|fleet|OK|1 rows" "M-SVC|fleet|EMPTY|0 series")
  run route_status ping;  [ "$output" = "OK" ]
  run route_status M-SVC; [ "$output" = "EMPTY" ]
  run route_status nope;  [ "$output" = "MISSING" ]
}

# --- show_result verdicts ------------------------------------------------
@test "show_result: all routes reachable -> PASS, SMART is N/A" {
  RESULTS=(
    "ping|fleet|OK|" "rack_list|fleet|OK|" "sled_list|fleet|OK|"
    "sled_disks|fleet|OK|" "sled_instances|fleet|OK|"
    "M-INST-check|fleet|OK|" "M-INST-incomplete|fleet|EMPTY|"
    "M-DDM-RACK-cov|fleet|OK|" "M-DDM-RACK-flap|fleet|OK|" "M-DDM-SLED|fleet|OK|"
    "M-ZONES|fleet|OK|" "M-SLED-PRESENT|fleet|OK|" "M-MEM-voltage|fleet|OK|"
    "M-POOL|fleet|OK|" "M-SVC|fleet|OK|" "M-STORAGE-IO|fleet|EMPTY|"
  )
  run show_result
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Run PASSED" ]]
  [[ "$output" =~ 8b[[:space:]]+disks.*N/A ]]
}
@test "show_result: a DENIED route fails its check and the run" {
  RESULTS=("M-SVC|fleet|DENIED|")   # M-SVC covers check 10 (services)
  run show_result
  [[ "$output" =~ 10[[:space:]]+services.*FAIL ]]
  [[ "$output" =~ "Run FAILED" ]]
}

# --- zone grouping (ztype) ----------------------------------------------
@test "show_zones: groups by service type; pantry/switch/global stay distinct" {
  cp "$FIX/M-ZONES.out" "$TMP/M-ZONES.out"
  run show_zones
  [ "$status" -eq 0 ]
  [[ "$output" =~ BRM0001.*"6 zones, 5 types" ]]
  [[ "$output" =~ crucible[[:space:]]+2 ]]          # two distinct crucible zones
  [[ "$output" =~ crucible_pantry[[:space:]]+1 ]]   # not folded into crucible
  [[ "$output" =~ switch[[:space:]]+1 ]]            # bare oxz_switch
  [[ "$output" =~ internal_dns[[:space:]]+1 ]]      # multi-underscore service (BRM0002)
}

# --- storage EXT/INT split + capacity -----------------------------------
@test "show_storage: U.2/M.2 split, external-only capacity, fullest first" {
  cp "$FIX/pool_alloc.out" "$TMP/pool_alloc.out"   # harmless; show_storage refetches
  with_fake_oxide
  run show_storage
  [ "$status" -eq 0 ]
  [[ "$output" =~ BRM0002[[:space:]]+1[[:space:]]+0 ]]   # ext=1 int=0
  [[ "$output" =~ BRM0001[[:space:]]+2[[:space:]]+1 ]]   # ext=2 int=1
  [[ "$output" =~ 94 ]]                                  # BRM0002 ~94% used
  local b2 b1
  b2=$(printf '%s\n' "$output" | grep -n BRM0002 | cut -d: -f1)
  b1=$(printf '%s\n' "$output" | grep -n BRM0001 | cut -d: -f1)
  [ "$b2" -lt "$b1" ]                                    # fullest sled sorted first
}

# --- voltage anomaly + ignore list --------------------------------------
@test "voltage_bad_count: flags the dropped DDR rail, ignores MCIO and nominal" {
  cp "$FIX/M-MEM-voltage.out" "$TMP/M-MEM-voltage.out"
  run voltage_bad_count
  [ "$output" -eq 1 ]
}
@test "show_voltage: names the dropped rail, never the ignored one" {
  cp "$FIX/M-MEM-voltage.out" "$TMP/M-MEM-voltage.out"
  run show_voltage
  [[ "$output" =~ V12_DDR5_GHIJKL_A0[[:space:]]+0 ]]     # dropped DDR rail is a flagged row
  [[ ! "$output" =~ V12_MCIO_A0HP[[:space:]]+[0-9] ]]    # MCIO is not flagged (only named in the "ignores" header)
  [[ "$output" =~ "1 rail(s) below 0.5 V" ]]             # exactly one flagged -> MCIO excluded from the count
}
@test "voltage_bad_count: a wider ignore list suppresses the flag" {
  cp "$FIX/M-MEM-voltage.out" "$TMP/M-MEM-voltage.out"
  VOLT_IGNORE='["V12_MCIO_A0HP","V12_DDR5_GHIJKL_A0"]'
  run voltage_bad_count
  [ "$output" -eq 0 ]
}

# --- end-to-end smoke (fresh run via fake oxide) ------------------------
@test "e2e: 'main -s' exits non-zero and flags the dropped rail" {
  with_fake_oxide
  run bash "${OXC_ROOT}/oxcorder.sh" -s
  [ "$status" -eq 1 ]
  [[ "$output" =~ "Anomaly detected" ]]
  [[ "$output" =~ "voltage rail" ]]
}
