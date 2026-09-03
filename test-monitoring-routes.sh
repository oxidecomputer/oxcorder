#!/usr/bin/env bash
#
# test-monitoring-routes.sh
#
# Validation harness for the customer-consumable routes that replace the
# rkdeploy health check (see rkdeploy-monitoring-spec.md). It exercises every
# external-API endpoint and OxQL query the spec depends on and reports, per
# route, whether it is reachable, authorized, and returning data on THIS rack.
#
# Everything here is read-only. Nothing is created, modified, or deleted.
#
# Requires:
#   - oxide CLI, authenticated (`oxide auth login`); check with `oxide auth status`
#   - jq
#
# Permissions (see spec): all routes except the storage-I/O check need a
# fleet-scoped token (minimum role fleet.viewer). The storage-I/O check is
# project-scoped and needs only project viewer.
#
# Usage:
#   ./test-monitoring-routes.sh [-r RACK_UUID] [-p PROJECT] [-w WINDOW] [-v] [-n]
#
#   -r RACK_UUID   Rack to scope rack-wide queries to. Auto-discovered if omitted.
#   -p PROJECT     Project for the project-scoped storage-I/O check.
#                  Auto-discovered if omitted; that check is skipped if none.
#   -w WINDOW      OxQL lookback window (default 5m). Widen on a quiet rack.
#   -v             Verbose: print each command and the raw error on failure.
#   -n             Dry run: print the commands without executing them.
#   -h             This help.
#
# Exit status: 0 if no route FAILED (EMPTY and DENIED still return non-zero
# only for DENIED/FAIL). See the summary legend at the end of a run.

set -uo pipefail

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
RACK=""
PROJECT=""
WINDOW="5m"
VERBOSE=0
DRYRUN=0

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while getopts ":r:p:w:vnh" opt; do
  case "$opt" in
    r) RACK="$OPTARG" ;;
    p) PROJECT="$OPTARG" ;;
    w) WINDOW="$OPTARG" ;;
    v) VERBOSE=1 ;;
    n) DRYRUN=1 ;;
    h) usage 0 ;;
    *) echo "unknown option: -$OPTARG" >&2; usage 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_R=$'\033[0m'
else
  C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_R=""
fi

# Collected results: "ID|SCOPE|STATUS|DETAIL"
declare -a RESULTS=()
FAILED=0

record() { RESULTS+=("$1|$2|$3|$4"); }

paint() {
  case "$1" in
    OK)     printf '%s%-6s%s' "$C_OK" "$1" "$C_R" ;;
    EMPTY)  printf '%s%-6s%s' "$C_WARN" "$1" "$C_R" ;;
    DENIED) printf '%s%-6s%s' "$C_ERR" "$1" "$C_R" ;;
    FAIL)   printf '%s%-6s%s' "$C_ERR" "$1" "$C_R" ;;
    SKIP)   printf '%s%-6s%s' "$C_DIM" "$1" "$C_R" ;;
    *)      printf '%-6s' "$1" ;;
  esac
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || { echo "${C_ERR}missing dependency: $1${C_R}" >&2; exit 2; }; }

if [[ $DRYRUN -eq 0 ]]; then
  need oxide
  need jq
  if ! oxide auth status >/dev/null 2>&1; then
    echo "${C_ERR}not authenticated — run 'oxide auth login' first${C_R}" >&2
    exit 2
  fi
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Classify an oxide error body into DENIED (permission) vs FAIL (anything else).
classify_err() {
  if grep -qiE '403|forbidden|unauthorized|permission' "$1"; then echo DENIED; else echo FAIL; fi
}

# run_api ID PATH COUNT_JQ
#   GET an API path, count rows with COUNT_JQ (applied to the JSON body).
run_api() {
  local id="$1" path="$2" cjq="$3"
  if [[ $DRYRUN -eq 1 ]]; then printf '  %-16s %sfleet%s  oxide api %s\n' "$id" "$C_DIM" "$C_R" "$path"; record "$id" fleet SKIP "dry-run"; return; fi
  [[ $VERBOSE -eq 1 ]] && echo "${C_DIM}+ oxide api $path${C_R}" >&2
  local out; out="$TMP/$id.out"
  if oxide api "$path" >"$out" 2>"$TMP/$id.err"; then
    local n; n="$(jq -r "$cjq" <"$out" 2>/dev/null || echo '?')"
    if [[ "$n" == "0" ]]; then record "$id" fleet EMPTY "0 rows"; else record "$id" fleet OK "${n} rows"; fi
  else
    local st; st="$(classify_err "$TMP/$id.err")"; [[ "$st" == FAIL ]] && FAILED=1
    [[ "$st" == DENIED ]] && FAILED=1
    record "$id" fleet "$st" "$(head -1 "$TMP/$id.err" | cut -c1-60)"
    [[ $VERBOSE -eq 1 ]] && sed 's/^/    /' "$TMP/$id.err" >&2
  fi
}

# run_oxql ID SCOPE QUERY
#   SCOPE is "fleet" or "project". Counts returned timeseries.
run_oxql() {
  local id="$1" scope="$2" q="$3"
  local -a cmd
  if [[ "$scope" == "project" ]]; then
    cmd=(oxide experimental timeseries query --project "$PROJECT" --query "$q")
  else
    cmd=(oxide experimental system timeseries query --query "$q")
  fi
  if [[ $DRYRUN -eq 1 ]]; then
    # Render copy-pasteable: single-quote the query argument.
    local shown
    if [[ "$scope" == "project" ]]; then
      shown="oxide experimental timeseries query --project $PROJECT --query '$q'"
    else
      shown="oxide experimental system timeseries query --query '$q'"
    fi
    printf '  %-16s %s%s%s  %s\n' "$id" "$C_DIM" "$scope" "$C_R" "$shown"
    record "$id" "$scope" SKIP "dry-run"; return
  fi
  [[ $VERBOSE -eq 1 ]] && echo "${C_DIM}+ ${cmd[*]}${C_R}" >&2
  local out; out="$TMP/$id.out"
  if "${cmd[@]}" >"$out" 2>"$TMP/$id.err"; then
    local n; n="$(jq -r '[.tables[].timeseries[]] | length' <"$out" 2>/dev/null || echo '?')"
    if [[ "$n" == "0" ]]; then record "$id" "$scope" EMPTY "0 series"; else record "$id" "$scope" OK "${n} series"; fi
  else
    local st; st="$(classify_err "$TMP/$id.err")"; FAILED=1
    record "$id" "$scope" "$st" "$(head -1 "$TMP/$id.err" | cut -c1-60)"
    [[ $VERBOSE -eq 1 ]] && sed 's/^/    /' "$TMP/$id.err" >&2
  fi
}

# ---------------------------------------------------------------------------
# Inventory display (informational; not part of pass/fail)
# ---------------------------------------------------------------------------

# show_sleds — one row per sled with the counts that should be uniform across
# the rack, so outliers stand out. THREADS, RAM_GiB, DISKS and ZONES should
# match sled-to-sled (within a hardware generation); INSTANCES is workload-
# dependent and informational. DISKS and INSTANCES come from the per-sled
# endpoints because the fleet-wide lists paginate.
show_sleds() {
  [[ $DRYRUN -eq 1 ]] && return
  echo
  echo "Per-sled inventory  ${C_DIM}(THREADS/RAM_GiB/DISKS/ZONES should match across sleds; INSTANCES is workload-dependent)${C_R}"
  local sl="$TMP/inv_sleds.out"
  if ! oxide api /v1/system/hardware/sleds >"$sl" 2>"$TMP/inv_sleds.err"; then
    echo "  ${C_ERR}could not list sleds:${C_R} $(head -1 "$TMP/inv_sleds.err")"
    return
  fi

  # Per-sled disk and instance counts (per-sled endpoints; the fleet lists paginate).
  local pf="$TMP/persled.tsv"; : >"$pf"
  local sid dc ic
  while read -r sid; do
    dc=$(oxide api "/v1/system/hardware/sleds/${sid}/disks"     2>/dev/null | jq -r '.items|length' 2>/dev/null)
    ic=$(oxide api "/v1/system/hardware/sleds/${sid}/instances" 2>/dev/null | jq -r '.items|length' 2>/dev/null)
    printf '%s\t%s\t%s\n' "$sid" "${dc:-?}" "${ic:-?}" >>"$pf"
  done < <(jq -r '.items[].id' "$sl")
  local pj="$TMP/persled.json"
  jq -Rn '[inputs|split("\t")|{(.[0]):{d:((.[1]|tonumber?) // .[1]), i:((.[2]|tonumber?) // .[2])}}]|add // {}' "$pf" >"$pj"

  # Zone counts per serial from the M-ZONES telemetry, if the validation run captured it.
  local zj="$TMP/zonecounts.json"
  if [[ -s "$TMP/M-ZONES.out" ]]; then
    jq '[.tables[].timeseries[]|{s:.fields.sled_serial.value,z:.fields.zone_name.value}]
        | group_by(.s) | map({key:.[0].s, value:([.[].z]|unique|length)}) | from_entries' \
        "$TMP/M-ZONES.out" >"$zj" 2>/dev/null || echo '{}' >"$zj"
  else echo '{}' >"$zj"; fi

  { printf 'SERIAL\tSTATE\tPOLICY\tTHREADS\tRAM_GiB\tDISKS\tZONES\tINSTANCES\n'
    jq -r --slurpfile per "$pj" --slurpfile zc "$zj" '
      ($per[0]) as $p | ($zc[0]) as $z
      | .items | sort_by(.baseboard.serial)[]
      | [ .baseboard.serial, .state, .policy.kind,
          (.usable_hardware_threads|tostring),
          ((.usable_physical_ram/1073741824)|floor|tostring),
          (($p[.id].d) // "?" | tostring),
          (($z[.baseboard.serial]) // "?" | tostring),
          (($p[.id].i) // "?" | tostring) ] | @tsv' "$sl"
  } | { column -t -s "$(printf '\t')" 2>/dev/null || cat; } | sed 's/^/  /'
  printf '  %s%s sled(s); DISKS/ZONES blank as "?" mean the sled did not answer or had no telemetry%s\n' \
    "$C_DIM" "$(jq -r '.items|length' "$sl")" "$C_R"
}

# show_zones — zones per sled, from sled_data_link telemetry (the M-ZONES query).
# A zone appears only if it emitted a data link in the window; the global zone
# shows as "global". Keyed on sled serial (the API exposes no cubby number).
show_zones() {
  [[ $DRYRUN -eq 1 ]] && return
  echo
  echo "Zones per sled  ${C_DIM}(from sled_data_link telemetry, last ${WINDOW})${C_R}"
  local out="$TMP/M-ZONES.out"        # reuse the validation query's output if present
  if [[ ! -s "$out" ]]; then
    out="$TMP/inv_zones.out"
    local rf=""; [[ -n "$RACK" ]] && rf=" && rack_id == \"$RACK\""
    if ! oxide experimental system timeseries query \
           --query "get sled_data_link:bytes_sent | filter timestamp > @now() - ${WINDOW}${rf}" \
           >"$out" 2>"$TMP/inv_zones.err"; then
      echo "  ${C_ERR}zone query failed:${C_R} $(head -1 "$TMP/inv_zones.err")"
      return
    fi
  fi
  local rendered
  rendered="$(jq -r '
    # Reduce a full zone name to its service type: strip the oxz_ prefix and
    # the trailing per-zone UUID. "global" and "oxz_switch" have no UUID.
    def ztype:
      if . == "global" then "global"
      else ( sub("^oxz_";"") ) as $r
        | ( $r | split("_") ) as $p
        | if ($p[-1] | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))
          then ($p[:-1] | join("_")) else $r end
      end;
    [ .tables[].timeseries[]
      | { s: (.fields.sled_serial.value // "unknown"),
          z: (.fields.zone_name.value   // "unknown") } ]
    | group_by(.s)[]
    | ([.[].z] | unique) as $zones
    | (.[0].s) as $serial
    | ( $zones | map(ztype) | group_by(.) | map({t: .[0], n: length}) | sort_by(-.n, .t) ) as $g
    | ( "  \($serial)  (\($zones|length) zones, \($g|length) types)" ),
      ( $g[] | "      " + (.t + "                    ")[0:20] + (.n|tostring) )
  ' "$out" 2>/dev/null)"
  if [[ -n "$rendered" ]]; then echo "$rendered"; else echo "  ${C_WARN}no zone telemetry in the window${C_R}"; fi
}

# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------
SLED="" ; SERIAL=""
if [[ $DRYRUN -eq 0 ]]; then
  [[ -z "$RACK" ]]    && RACK="$(oxide api /v1/system/hardware/racks 2>/dev/null | jq -r '.items[0].id // empty')"
  SLED="$(oxide api /v1/system/hardware/sleds 2>/dev/null | jq -r '.items[0].id // empty')"
  SERIAL="$(oxide api /v1/system/hardware/sleds 2>/dev/null | jq -r '.items[0].baseboard.serial // empty')"
  [[ -z "$PROJECT" ]] && PROJECT="$(oxide api /v1/projects 2>/dev/null | jq -r '.items[0].name // empty')"
fi

echo
echo "rkdeploy monitoring-route validation"
echo
echo "  Parameters (what each one scopes):"
echo "    rack     ${RACK:-<none discovered>}"
echo "             ${C_DIM}rack-wide OxQL queries are filtered to this rack. The API exposes no rack"
echo "             serial number — the UUID is the rack's only identifier.${C_R}"
echo "    sled     ${SERIAL:-<none>} (${SLED:-<none>})"
echo "             ${C_DIM}a sample sled, used only for the per-sled API probes below"
echo "             (sled_disks, sled_instances, M-MEM-voltage).${C_R}"
echo "    project  ${PROJECT:-<none — storage-I/O check will be skipped>}"
echo "             ${C_DIM}the project the project-scoped storage-I/O check queries.${C_R}"
echo "    window   ${WINDOW}"
echo "             ${C_DIM}lookback for every OxQL timeseries query (widen with -w on a quiet rack).${C_R}"
echo

# ---------------------------------------------------------------------------
# External API routes
# ---------------------------------------------------------------------------
echo "External API"
run_api  ping              "/v1/ping"                                       '1'
run_api  rack_list         "/v1/system/hardware/racks"                      '.items | length'
run_api  sled_list         "/v1/system/hardware/sleds"                      '.items | length'
run_api  switch_list       "/v1/system/hardware/switches"                   '.items | length'
run_api  disk_list         "/v1/system/hardware/disks"                      '.items | length'
if [[ -n "$SLED" ]]; then
  run_api sled_disks       "/v1/system/hardware/sleds/${SLED}/disks"        '.items | length'
  run_api sled_instances   "/v1/system/hardware/sleds/${SLED}/instances"    '.items | length'
else
  record sled_disks fleet SKIP "no sled discovered"
  record sled_instances fleet SKIP "no sled discovered"
fi
run_api  ts_schemas        "/v1/system/timeseries/schemas"                  '.items | length'

# ---------------------------------------------------------------------------
# OxQL routes (fleet-scoped)   — mirror the monitors in the spec
# ---------------------------------------------------------------------------
RF=""; [[ -n "$RACK" ]] && RF=" && rack_id == \"$RACK\""

echo
echo "OxQL — fleet scope (needs fleet.viewer)"
run_oxql M-INST-check       fleet "get virtual_machine:check | filter timestamp > @now() - ${WINDOW}"
run_oxql M-INST-incomplete  fleet "get virtual_machine:incomplete_check | filter timestamp > @now() - ${WINDOW}"
run_oxql M-DDM-SLED         fleet "get ddm_session:imported_underlay_prefixes | filter timestamp > @now() - ${WINDOW} && datum > 0"
run_oxql M-DDM-RACK-cov     fleet "get ddm_session:imported_underlay_prefixes | filter timestamp > @now() - ${WINDOW}${RF} && datum > 0"
run_oxql M-DDM-RACK-flap    fleet "get ddm_session:peer_expirations | filter timestamp > @now() - 1h${RF} | align mean_within(5m) | group_by [sled_id], sum"
run_oxql M-SLED-PRESENT     fleet "get sled_data_link:bytes_received | filter timestamp > @now() - ${WINDOW}${RF}"
if [[ -n "$SERIAL" ]]; then
  run_oxql M-MEM-voltage    fleet "get hardware_component:voltage | filter timestamp > @now() - ${WINDOW} && chassis_serial == \"$SERIAL\""
else
  record M-MEM-voltage fleet SKIP "no serial discovered"
fi
run_oxql M-THERM-tctl       fleet "get hardware_component:amd_cpu_tctl | filter timestamp > @now() - ${WINDOW} && datum >= 95.0"
run_oxql M-THERM-senserr    fleet "get hardware_component:sensor_error_count | filter timestamp > @now() - 15m && datum > 0"
run_oxql M-ZONES            fleet "get sled_data_link:bytes_sent | filter timestamp > @now() - ${WINDOW}${RF}"
run_oxql M-SVC              fleet "get http_service:request_latency_histogram | filter timestamp > @now() - 15m"

# Note: M-THERM-tctl filters on a fault condition (datum >= 95.0), so a healthy
# rack returns 0 series (EMPTY) — that is passing. The tctl literal MUST be a
# decimal: amd_cpu_tctl is a float metric, and OxQL rejects an integer literal
# against a float datum. M-THERM-senserr reads a CUMULATIVE counter, so a nonzero
# total is the rack's lifetime error count, not an active fault; OK with many
# series here means "route reachable", not "sensors erroring now". Alert on the
# per-window increase (see the spec), not the raw total.

# ---------------------------------------------------------------------------
# OxQL route (project-scoped)
# ---------------------------------------------------------------------------
echo
echo "OxQL — project scope (needs project viewer)"
if [[ -n "$PROJECT" ]]; then
  run_oxql M-STORAGE-IO     project "get virtual_disk:failed_reads | filter timestamp > @now() - 1h && datum > 0"
else
  record M-STORAGE-IO project SKIP "no project (pass -p)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "Summary"
printf '  %-18s %-8s %-7s %s\n' "ROUTE" "SCOPE" "STATUS" "DETAIL"
printf '  %-18s %-8s %-7s %s\n' "-----" "-----" "------" "------"
for r in "${RESULTS[@]}"; do
  IFS='|' read -r id scope status detail <<<"$r"
  printf '  %-18s %-8s ' "$id" "$scope"; paint "$status"; printf ' %s\n' "$detail"
done

echo
show_sleds
show_zones

echo "Legend: ${C_OK}OK${C_R}=data returned  ${C_WARN}EMPTY${C_R}=ran, no rows (healthy for the M-THERM-tctl fault filter)"
echo "        ${C_ERR}DENIED${C_R}=permission (check token role)  ${C_ERR}FAIL${C_R}=error (see -v)  ${C_DIM}SKIP${C_R}=not run"
echo
if [[ $FAILED -ne 0 ]]; then
  echo "${C_ERR}One or more routes failed or were denied.${C_R} Re-run with -v for details."
  exit 1
fi
echo "${C_OK}All executed routes reachable.${C_R}"
exit 0
