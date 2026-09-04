#!/usr/bin/env bash
#
# oxcorder.sh — Oxcorder: like a tricorder, but for the rack.
#
# Validation + inventory harness for the customer-consumable routes that replace
# the technician-port (techport) privileged-access health check (see
# techport-monitoring-spec.md). It:
#   1. exercises every external-API endpoint and OxQL query the spec depends on
#      and reports, per route, whether it is reachable, authorized, and returning
#      data on THIS rack (the Summary);
#   2. prints per-sled views for spotting outliers: a per-sled inventory
#      (threads, RAM, disks, zones, instances), zones-per-sled grouped by service
#      type, and per-sled storage capacity (U.2 vs M.2 pools); and
#   3. closes with a coverage table mapping each techport privileged-access check
#      to the API/OxQL that satisfies it here (direct, indirect, or not possible).
#
# Everything here is read-only. Nothing is created, modified, or deleted.
#
# Requires:
#   - oxide CLI, authenticated (`oxide auth login`); check with `oxide auth status`
#   - jq
#   - timeout or gtimeout (optional; macOS provides gtimeout via coreutils).
#     Without one, routes run with no per-call cap (a warning is printed).
#
# Permissions (see spec): every route needs a fleet-scoped token (minimum role
# fleet.viewer). All timeseries are queried fleet-wide, across every silo.
#
# Usage:
#   ./oxcorder.sh [-w WINDOW] [-s|-c] [-v] [-n]
#
#   -w WINDOW      OxQL lookback window (default 5m). Widen on a quiet rack.
#   -s             Short: Summary plus any anomalies only; exit non-zero on an
#                  issue. Runs every route but suppresses the detail sections.
#                  Meant to be called from a script.
#   -c             Coverage: show ONLY the techport-check coverage table and the
#                  per-check run result. Runs every route; suppresses all else.
#                  (-s and -c are mutually exclusive; the last one given wins.)
#   -v             Verbose: print each command and the raw error on failure.
#   -n             Dry run: print the commands without executing them.
#   -h             This help.
#
# Exit status: 0 when every executed route is reachable and no voltage anomaly
# was found; 1 if a route FAILED or was DENIED, or a rail read below 0.5 V.
# This holds in every mode, so -s is safe to gate a script on.

set -uo pipefail
# NOTE: no `-e` — failures are handled explicitly per command; an uncapped
# timeout or missing `set -e` here is deliberate, each route records its own
# result instead of aborting the whole run.

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
WINDOW="5m"
VERBOSE=0
DRYRUN=0
MODE="full"   # full | short | coverage
# Hard cap (seconds) on each oxide invocation so a hung backend can't stall the
# whole run. Only applied in non-dry-run mode.
TIMEOUT=30
# Resolved in preflight to "timeout", "gtimeout", or "" (run without a cap).
TIMEOUT_BIN=""
# Voltage rails that are legitimately unpopulated (read ~0 V) and must not be
# flagged as dropped. JSON array of exact sensor names; extend as needed.
VOLT_IGNORE='["V12_MCIO_A0HP"]'

usage() { awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit "${1:-0}"; }


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

record() {
  [[ $# -eq 4 ]] || { echo "${C_ERR}internal error: record called with $# args: $*${C_R}" >&2; return 1; }
  RESULTS+=("$1|$2|$3|$4")
}

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


# Classify an oxide error body into DENIED (permission) vs FAIL (anything else).
classify_err() {
  if grep -qiE '403|forbidden|unauthorized|permission' "$1"; then echo DENIED; else echo FAIL; fi
}

# ox — run a command under the detected timeout wrapper, or directly when
# neither timeout nor gtimeout is installed (see preflight).
ox() {
  if [[ -n "$TIMEOUT_BIN" ]]; then "$TIMEOUT_BIN" "$TIMEOUT" "$@"; else "$@"; fi
}

# run_api ID PATH COUNT_JQ
#   GET an API path, count rows with COUNT_JQ (applied to the JSON body).
run_api() {
  local id="$1" path="$2" cjq="$3"
  if [[ $DRYRUN -eq 1 ]]; then printf '  %-16s %sfleet%s  oxide api %s\n' "$id" "$C_DIM" "$C_R" "$path"; record "$id" fleet SKIP "dry-run"; return; fi
  [[ $VERBOSE -eq 1 ]] && echo "${C_DIM}scanning: timeout ${TIMEOUT} oxide api $path${C_R}" >&2
  local out; out="$TMP/$id.out"
  if ox oxide api "$path" >"$out" 2>"$TMP/$id.err"; then
    local n; n="$(jq -r "$cjq" <"$out" 2>/dev/null || echo '?')"
    if [[ "$n" == "0" ]]; then record "$id" fleet EMPTY "0 rows"; else record "$id" fleet OK "${n} rows"; fi
  else
    local st; st="$(classify_err "$TMP/$id.err")"; FAILED=1
    record "$id" fleet "$st" "$(head -1 "$TMP/$id.err" | cut -c1-60)"
    [[ $VERBOSE -eq 1 ]] && sed 's/^/    /' "$TMP/$id.err" >&2
  fi
}

# run_oxql ID SCOPE QUERY
#   SCOPE is "fleet" or "project". Counts returned timeseries.
run_oxql() {
  local id="$1" scope="$2" q="$3"
  local -a cmd
  cmd=(oxide experimental system timeseries query --query "$q")
  if [[ $DRYRUN -eq 1 ]]; then
    printf '  %-16s %s%s%s  oxide experimental system timeseries query --query %s\n' "$id" "$C_DIM" "$scope" "$C_R" "'$q'"
    record "$id" "$scope" SKIP "dry-run"; return
  fi
  [[ $VERBOSE -eq 1 ]] && echo "${C_DIM}scanning: timeout ${TIMEOUT} ${cmd[*]}${C_R}" >&2
  local out; out="$TMP/$id.out"
  if ox "${cmd[@]}" >"$out" 2>"$TMP/$id.err"; then
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
  if ! ox oxide api /v1/system/hardware/sleds >"$sl" 2>"$TMP/inv_sleds.err"; then
    echo "  ${C_ERR}could not list sleds:${C_R} $(head -1 "$TMP/inv_sleds.err")"
    return
  fi

  # NOTE — single-rack assumption: this loops EVERY sled from sled_list and makes
  # two serial API calls per sled. Cheap today because deployments are single-rack
  # (tens of sleds). If Oxcorder is ever pointed at a MULTI-RACK fleet, sled_list
  # returns every sled across every rack and this becomes hundreds-to-thousands of
  # serial calls. Before that day: scope it with an optional rack filter (re-add
  # -r and filter sled_list by rack_id), and/or run the per-sled calls with
  # bounded parallelism.
  # Per-sled disk and instance counts (per-sled endpoints; the fleet lists paginate).
  local pf="$TMP/persled.tsv"; : >"$pf"
  local sid dc ic
  while read -r sid; do
    dc=$(ox oxide api "/v1/system/hardware/sleds/${sid}/disks"     2>/dev/null | jq -r '.items|length' 2>/dev/null)
    ic=$(ox oxide api "/v1/system/hardware/sleds/${sid}/instances" 2>/dev/null | jq -r '.items|length' 2>/dev/null)
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
    if ! ox oxide experimental system timeseries query \
           --query "get sled_data_link:bytes_sent | filter timestamp > @now() - ${WINDOW}" \
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

# show_storage — per-sled zpool capacity from zfs_pool (fleet-scoped). Disk IO
# has no sled-scoped series (virtual_disk is project-scoped and carries no
# sled_id), so capacity is the sled-wide storage signal that exists. Rows are
# sorted by percent-used, so the fullest sled is on top.
show_storage() {
  [[ $DRYRUN -eq 1 ]] && return
  echo
  echo "Storage per sled  ${C_DIM}(zfs_pool; EXT=U.2 data pools, INT=M.2 boot; USED/TOTAL are external pools; disk IO not available sled-wide — see spec)${C_R}"
  local a="$TMP/pool_alloc.out" t="$TMP/pool_total.out"
  if ! ox oxide experimental system timeseries query \
         --query "get zfs_pool:bytes_allocated | filter timestamp > @now() - ${WINDOW}" \
         >"$a" 2>"$TMP/pool_a.err"; then
    echo "  ${C_ERR}zfs_pool query failed:${C_R} $(head -1 "$TMP/pool_a.err")"; return
  fi
  ox oxide experimental system timeseries query \
    --query "get zfs_pool:bytes_total | filter timestamp > @now() - ${WINDOW}" \
    >"$t" 2>/dev/null
  if [[ "$(jq -r '[.tables[].timeseries[]]|length' "$a" 2>/dev/null)" == "0" ]]; then
    echo "  ${C_WARN}no zfs_pool telemetry in the window (widen with -w)${C_R}"; return
  fi
  { printf 'SERIAL\tEXT_POOLS\tINT_POOLS\tUSED_TiB\tTOTAL_TiB\tPCT\n'
    jq -rn --slurpfile A "$a" --slurpfile T "$t" '
      def rows($x): [ $x[0].tables[].timeseries[]
        | { pid: .fields.pool_id.value,
            ser: (.fields.sled_serial.value // "?"),
            name: (.fields.pool_name.value // ""),
            v: (.points.values[0].values.values | map(select(. != null)) | (if length>0 then .[-1] else 0 end)) } ];
      (rows($T) | map({(.pid): .v}) | add) as $tot
      | [ rows($A)[] | { ser, a: .v, t: ($tot[.pid] // 0), isext: (.name|startswith("oxp_")) } ]
      | [ group_by(.ser)[]
          | { ser: .[0].ser,
              ext: ([.[]|select(.isext)]|length),
              int: ([.[]|select(.isext|not)]|length),
              a: ([.[]|select(.isext)|.a]|add // 0),
              t: ([.[]|select(.isext)|.t]|add // 0) }
          | . + { pct: (if .t>0 then (.a/.t*100) else -1 end) } ]
      | sort_by(-.pct)[]
      | [ .ser, (.ext|tostring), (.int|tostring),
          ((.a/1099511627776*100|round)/100|tostring),
          ((.t/1099511627776*100|round)/100|tostring),
          (if .pct>=0 then (.pct|round|tostring) else "?" end) ] | @tsv
    ' ; } | { column -t -s "$(printf '\t')" 2>/dev/null || cat; } | sed 's/^/  /'
}

# show_coverage — map each techport privileged-access check to the API/OxQL built
# here. Static reference (does not depend on this run's data): Direct = a metric
# maps 1:1; Indirect = reconstructed or a downstream proxy; Not possible = no
# customer-consumable telemetry exists.
show_coverage() {
  echo
  echo "Coverage vs techport privileged-access check  ${C_DIM}(each check -> the API/OxQL that satisfies it here)${C_R}"
  { printf 'TECHPORT CHECK\tHARNESS ROUTE(S)\tCOVERAGE\n'
    printf '%s\t%s\t%s\n' "1  rss_time"                "rack_list (time_created)"           "Indirect"
    printf '%s\t%s\t%s\n' "2  rss_state"               "ping, rack_list"                    "Indirect"
    printf '%s\t%s\t%s\n' "3  instances STATE!=INTENT" "M-INST-check, M-INST-incomplete"   "Indirect"
    printf '%s\t%s\t%s\n' "4  ddm_peers (rack)"        "M-DDM-RACK-cov, M-DDM-RACK-flap"   "Direct"
    printf '%s\t%s\t%s\n' "5  zones (rack)"            "M-ZONES"                           "Indirect"
    printf '%s\t%s\t%s\n' "6  sled presence"           "sled_list, M-SLED-PRESENT"         "Direct"
    printf '%s\t%s\t%s\n' "7  memory"                  "sled_list (RAM), M-MEM-voltage"    "Direct"
    printf '%s\t%s\t%s\n' "8a disks: count/presence"   "sled_disks, M-POOL"                "Direct"
    printf '%s\t%s\t%s\n' "8b disks: SMART/block-format" "(none)"                          "Not possible"
    printf '%s\t%s\t%s\n' "9  zpools"                  "M-STORAGE-IO"                      "Indirect"
    printf '%s\t%s\t%s\n' "10 services"                "M-SVC"                             "Indirect"
    printf '%s\t%s\t%s\n' "11 ddm_peers (sled)"        "M-DDM-SLED"                        "Direct"
    printf '%s\t%s\t%s\n' "12 zones (sled)"            "M-ZONES"                           "Indirect"
  } | { column -t -s "$(printf '\t')" 2>/dev/null || cat; } | sed 's/^/  /'
}

# route_status — look up a route's live STATUS from RESULTS by id.
route_status() {
  local id="$1" r
  for r in "${RESULTS[@]}"; do
    [[ "${r%%|*}" == "$id" ]] && { printf '%s' "$r" | cut -d'|' -f3; return; }
  done
  printf 'MISSING'
}

# show_result — per-techport-check pass/fail for THIS run, derived from the
# covering routes' live statuses. A check PASSES when all its routes came back
# OK or EMPTY (reachable); a DENIED/FAIL route FAILS it; a skipped route marks
# it SKIP; the SMART/block-format check has no route and is N/A.
show_result() {
  echo
  echo "Run result by check  ${C_DIM}(did this run's routes for each check come back clean?)${C_R}"
  local num name ids id st worst pass=0 fail=0 skip=0 na=0
  while IFS='|' read -r num name ids; do
    [[ -z "$num" ]] && continue
    if [[ "$ids" == "NONE" ]]; then
      printf '  %-3s %-28s %sN/A%s\n' "$num" "$name" "$C_DIM" "$C_R"; na=$((na+1)); continue
    fi
    worst="PASS"
    for id in $ids; do
      st="$(route_status "$id")"
      case "$st" in
        FAIL|DENIED) worst="FAIL"; break;;
        SKIP|MISSING) [[ "$worst" == "PASS" ]] && worst="SKIP";;
      esac
    done
    case "$worst" in
      PASS) printf '  %-3s %-28s %sPASS%s\n' "$num" "$name" "$C_OK"  "$C_R"; pass=$((pass+1));;
      SKIP) printf '  %-3s %-28s %sSKIP%s\n' "$num" "$name" "$C_DIM" "$C_R"; skip=$((skip+1));;
      FAIL) printf '  %-3s %-28s %sFAIL%s\n' "$num" "$name" "$C_ERR" "$C_R"; fail=$((fail+1));;
    esac
  done <<'EOF'
1|rss_time|rack_list
2|rss_state|ping rack_list
3|instances STATE!=INTENT|M-INST-check M-INST-incomplete sled_instances
4|ddm_peers (rack)|M-DDM-RACK-cov M-DDM-RACK-flap
5|zones (rack)|M-ZONES
6|sled presence|sled_list M-SLED-PRESENT
7|memory|sled_list M-MEM-voltage
8a|disks: count/presence|sled_disks M-POOL
8b|disks: SMART/block-format|NONE
9|zpools|M-STORAGE-IO
10|services|M-SVC
11|ddm_peers (sled)|M-DDM-SLED
12|zones (sled)|M-ZONES
EOF
  echo
  if [[ $fail -gt 0 ]]; then
    printf '  %sRun FAILED%s — %d failed, %d reachable, %d skipped, %d not possible.\n' "$C_ERR" "$C_R" "$fail" "$pass" "$skip" "$na"
  elif [[ $pass -eq 0 ]]; then
    printf '  %sNo routes executed%s (dry run?) — %d skipped, %d not possible.\n' "$C_DIM" "$C_R" "$skip" "$na"
  else
    printf '  %sRun PASSED%s — %d checks reachable, %d skipped, %d not possible.\n' "$C_OK" "$C_R" "$pass" "$skip" "$na"
  fi
}

# show_voltage — rack-wide voltage anomaly scan. A powered chassis should have
# no rail near zero, so any rail reading below 0.5 V is flagged as a likely
# dropped rail (the cs-914/cs-932 DDR-bank failure mode). Reuses the
# M-MEM-voltage query output; covers every chassis (sled, switch, power shelf).
show_voltage() {
  [[ $DRYRUN -eq 1 ]] && return
  echo
  echo "Voltage anomaly scan  ${C_DIM}(rack-wide hardware_component:voltage, last ${WINDOW}; flags rails < 0.5 V; ignores ${VOLT_IGNORE})${C_R}"
  local out="$TMP/M-MEM-voltage.out"
  if [[ ! -s "$out" ]] || [[ "$(jq -r '[.tables[].timeseries[]]|length' "$out" 2>/dev/null)" == "0" ]]; then
    echo "  ${C_WARN}no voltage telemetry captured (M-MEM-voltage was EMPTY or failed)${C_R}"; return
  fi
  local total sleds bad
  total=$(jq -r '[.tables[].timeseries[]]|length' "$out" 2>/dev/null)
  sleds=$(jq -r '[.tables[].timeseries[].fields.chassis_serial.value]|unique|length' "$out" 2>/dev/null)
  bad="$(jq -rn --slurpfile V "$out" --argjson ignore "$VOLT_IGNORE" '
    $V[0].tables[].timeseries[]
    | { ser: (.fields.chassis_serial.value // "?"),
        kind: (.fields.chassis_kind.value // "?"),
        sensor: (.fields.sensor.value // "?"),
        v: (.points.values[0].values.values | map(select(.!=null)) | (if length>0 then .[-1] else null end)) }
    | select(.v != null and .v < 0.5 and (.sensor as $s | ($ignore | index($s)) | not))
    | "\(.ser)\t\(.kind)\t\(.sensor)\t\(.v) V"
  ' 2>/dev/null)"
  if [[ -z "$bad" ]]; then
    printf '  %sall rails nominal%s across %s chassis (%s sensors)\n' "$C_OK" "$C_R" "${sleds:-?}" "${total:-?}"
  else
    { printf 'CHASSIS\tKIND\tSENSOR\tVOLTS\n'; printf '%s\n' "$bad"; } | { column -t -s "$(printf '\t')" 2>/dev/null || cat; } | sed 's/^/  /'
    printf '  %s%s rail(s) below 0.5 V — likely dropped; investigate%s\n' "$C_ERR" "$(printf '%s\n' "$bad" | grep -c .)" "$C_R"
  fi
}

# print_summary — the per-route status table.
print_summary() {
  echo
  echo "Summary"
  printf '  %-18s %-8s %-7s %s\n' "ROUTE" "SCOPE" "STATUS" "DETAIL"
  printf '  %-18s %-8s %-7s %s\n' "-----" "-----" "------" "------"
  local r id scope status detail
  for r in "${RESULTS[@]}"; do
    IFS='|' read -r id scope status detail <<<"$r"
    printf '  %-18s %-8s ' "$id" "$scope"; paint "$status"; printf ' %s\n' "$detail"
  done
}

# voltage_bad_count — number of voltage rails reading below 0.5 V (dropped),
# from the M-MEM-voltage output. Echoes 0 when there is no data.
voltage_bad_count() {
  local out="$TMP/M-MEM-voltage.out"
  [[ -s "$out" ]] || { echo 0; return; }
  jq -rn --slurpfile V "$out" --argjson ignore "$VOLT_IGNORE" '
    [ $V[0].tables[].timeseries[]
      | select((.fields.sensor.value // "") as $s | ($ignore | index($s)) | not)
      | (.points.values[0].values.values | map(select(.!=null)) | (if length>0 then .[-1] else null end)) ]
    | map(select(. != null and . < 0.5)) | length
  ' 2>/dev/null || echo 0
}

# ---------------------------------------------------------------------------
# main — arg parsing, preflight, discovery, routes, output, exit. Wrapped in a
# function guarded by BASH_SOURCE so the script can be sourced (e.g. by the bats
# tests) to reach the helpers without executing a run.
# ---------------------------------------------------------------------------
main() {
while getopts ":w:scvnh" opt; do
  case "$opt" in
    w) WINDOW="$OPTARG" ;;
    s) MODE="short" ;;
    c) MODE="coverage" ;;
    v) VERBOSE=1 ;;
    n) DRYRUN=1 ;;
    h) usage 0 ;;
    *) echo "unknown option: -$OPTARG" >&2; usage 1 ;;
  esac
done

if [[ $DRYRUN -eq 0 ]]; then
  need oxide
  need jq
  # macOS has no `timeout`; coreutils provides `gtimeout`. Detect one, or run
  # without a per-call cap (with a warning) rather than failing every route.
  if command -v timeout  >/dev/null 2>&1; then TIMEOUT_BIN="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN="gtimeout"
  else
    TIMEOUT_BIN=""
    echo "${C_WARN}note: no timeout/gtimeout found — running without a per-call cap${C_R}" >&2
    echo "${C_DIM}      (brew install coreutils to get one)${C_R}" >&2
  fi
  if ! oxide auth status >/dev/null 2>&1; then
    echo "${C_ERR}not authenticated — run 'oxide auth login' first${C_R}" >&2
    exit 2
  fi
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------
SLED="" ; SERIAL=""
if [[ $DRYRUN -eq 0 ]]; then
  sleds_json="$(ox oxide api /v1/system/hardware/sleds 2>/dev/null)"
  SLED="$(jq -r '.items[0].id // empty' <<<"$sleds_json")"
  SERIAL="$(jq -r '.items[0].baseboard.serial // empty' <<<"$sleds_json")"
  unset sleds_json
fi

if [[ "$MODE" == "full" ]]; then
echo
echo "Oxcorder — long-range sensors for the rack"
echo
echo "  Parameters (what each one scopes):"
echo "    scope    fleet"
echo "             ${C_DIM}every route is read fleet-wide, across every rack and sled. Each"
echo "             timeseries carries its own rack_id/sled_id, so results can be"
echo "             grouped or aggregated per rack as needed.${C_R}"
echo "    sled     ${SERIAL:-<none>} (${SLED:-<none>})"
echo "             ${C_DIM}one sample sled, only to confirm the two per-sled endpoints"
echo "             respond (sled_disks, sled_instances). Disk, instance, memory,"
echo "             zone and voltage data is gathered for EVERY sled in the sections below.${C_R}"
echo "    window   ${WINDOW}"
echo "             ${C_DIM}lookback for every OxQL timeseries query (widen with -w on a quiet rack).${C_R}"
echo
fi

# ---------------------------------------------------------------------------
# External API routes
# ---------------------------------------------------------------------------
[[ "$MODE" == "full" ]] && echo "External API"
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
[[ "$MODE" == "full" ]] && { echo; echo "OxQL — fleet scope (needs fleet.viewer)"; }
run_oxql M-INST-check       fleet "get virtual_machine:check | filter timestamp > @now() - ${WINDOW}"
run_oxql M-INST-incomplete  fleet "get virtual_machine:incomplete_check | filter timestamp > @now() - ${WINDOW}"
run_oxql M-DDM-SLED         fleet "get ddm_session:imported_underlay_prefixes | filter timestamp > @now() - ${WINDOW} && datum > 0"
run_oxql M-DDM-RACK-cov     fleet "get ddm_session:imported_underlay_prefixes | filter timestamp > @now() - ${WINDOW} && datum > 0"
run_oxql M-DDM-RACK-flap    fleet "get ddm_session:peer_expirations | filter timestamp > @now() - 1h | align mean_within(5m) | group_by [sled_id], sum"
run_oxql M-SLED-PRESENT     fleet "get sled_data_link:bytes_received | filter timestamp > @now() - ${WINDOW}"
run_oxql M-MEM-voltage    fleet "get hardware_component:voltage | filter timestamp > @now() - ${WINDOW}"
run_oxql M-THERM-tctl       fleet "get hardware_component:amd_cpu_tctl | filter timestamp > @now() - ${WINDOW} && datum >= 95.0"
run_oxql M-THERM-senserr    fleet "get hardware_component:sensor_error_count | filter timestamp > @now() - 15m && datum > 0"
run_oxql M-ZONES            fleet "get sled_data_link:bytes_sent | filter timestamp > @now() - ${WINDOW}"
run_oxql M-SVC              fleet "get http_service:request_latency_histogram | filter timestamp > @now() - 15m"
run_oxql M-POOL             fleet "get zfs_pool:bytes_total | filter timestamp > @now() - ${WINDOW}"
run_oxql M-DATASET          fleet "get zfs_dataset:bytes_used | filter timestamp > @now() - ${WINDOW}"
run_oxql M-STORAGE-IO       fleet "get virtual_disk:failed_reads | filter timestamp > @now() - 1h && datum > 0"

# Note: M-THERM-tctl filters on a fault condition (datum >= 95.0), so a healthy
# rack returns 0 series (EMPTY) — that is passing. The tctl literal MUST be a
# decimal: amd_cpu_tctl is a float metric, and OxQL rejects an integer literal
# against a float datum. M-THERM-senserr reads a CUMULATIVE counter, so a nonzero
# total is the rack's lifetime error count, not an active fault; OK with many
# series here means "route reachable", not "sensors erroring now". Alert on the
# per-window increase (see the spec), not the raw total.

# ---------------------------------------------------------------------------
# Output — routes have run; RESULTS and telemetry are populated. What prints
# depends on MODE; the exit status does not.
# ---------------------------------------------------------------------------
VOLT_BAD=0
[[ $DRYRUN -eq 0 ]] && VOLT_BAD="$(voltage_bad_count)"

case "$MODE" in
  coverage)
    show_coverage
    show_result
    ;;
  short)
    print_summary
    [[ "${VOLT_BAD:-0}" -gt 0 ]] && show_voltage
    ;;
  *)  # full
    print_summary
    echo
    show_sleds
    show_zones
    show_storage
    show_voltage
    echo "Legend: ${C_OK}OK${C_R}=data returned  ${C_WARN}EMPTY${C_R}=ran, no rows (healthy for the M-THERM-tctl fault filter)"
    echo "        ${C_ERR}DENIED${C_R}=permission (check token role)  ${C_ERR}FAIL${C_R}=error (see -v)  ${C_DIM}SKIP${C_R}=not run"
    ;;
esac

# ---------------------------------------------------------------------------
# Exit status (every mode): non-zero on a failed/denied route or a dropped rail
# ---------------------------------------------------------------------------
issue=0
[[ $FAILED -ne 0 ]] && issue=1
[[ "${VOLT_BAD:-0}" -gt 0 ]] && issue=1

if [[ "$MODE" != "coverage" ]]; then
  echo
  if [[ $issue -ne 0 ]]; then
    reasons=""
    [[ $FAILED -ne 0 ]] && reasons="one or more routes failed or were denied"
    if [[ "${VOLT_BAD:-0}" -gt 0 ]]; then
      [[ -n "$reasons" ]] && reasons="$reasons; "
      reasons="${reasons}${VOLT_BAD} voltage rail(s) below 0.5 V"
    fi
    printf '  %sAnomaly detected%s — %s. Re-run with -v for details.\n' "$C_ERR" "$C_R" "$reasons"
  else
    printf '  %sAll nominal%s — every sensor reading within expected parameters.\n' "$C_OK" "$C_R"
  fi
fi

[[ $issue -ne 0 ]] && exit 1
exit 0
}

# Run only when executed directly, not when sourced (tests source this file).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
