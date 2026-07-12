#!/usr/bin/env bash
# AtlasLab - scripts/test-connectivity.sh
#
# Regression smoke test for a deployed lab:
#   1. OSPF adjacencies are Full on every node running ospfd
#   2. BGP sessions are Established on every node running bgpd
#   3. Full-mesh loopback-to-loopback ping across all nodes
#
# Works for any lab under labs/ - it discovers nodes from the topology
# file and which daemons are enabled from configs/<lab>/<node>/daemons,
# rather than hardcoding device names.
#
# Usage:
#   scripts/test-connectivity.sh <lab-name> [-h|--help]
#
# Exit codes:
#   0  all tests passed
#   1  one or more tests failed
#   2  usage error
#   3  missing dependency
#   4  lab not found
set -uo pipefail

SCRIPT_NAME="test-connectivity"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

usage() {
  print_help_header "run OSPF/BGP/reachability regression tests against a deployed lab"
  cat <<EOF
Usage:
  $(basename "$0") <lab-name> [-h|--help]

Exit codes:
  0  all tests passed
  1  one or more tests failed
  2  usage error
  3  missing dependency
  4  lab not found
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -eq 0 ]]; then
  usage
  [[ $# -eq 0 ]] && exit "$EXIT_USAGE"
  exit "$EXIT_OK"
fi

LAB="$1"
LAB_DIR="$(resolve_lab "$LAB")"
CNAME="$(clab_name "$LAB")"
CONFIGS_DIR="${ATLASLAB_ROOT}/configs/${LAB}"

FAIL=0
TOTAL_CHECKS=0

pass() { log_success "$1"; TOTAL_CHECKS=$((TOTAL_CHECKS + 1)); }
fail() { log_error "$1"; FAIL=$((FAIL + 1)); TOTAL_CHECKS=$((TOTAL_CHECKS + 1)); }

NODES="$(node_list "$LAB")"
if [[ -z "$NODES" ]]; then
  die "No nodes found in labs/${LAB}/lab.clab.yml" "$EXIT_GENERAL_ERROR"
fi

# --- 1. OSPF adjacency check ------------------------------------------------
log_step "OSPF adjacency check"
while IFS= read -r node; do
  daemons_file="${CONFIGS_DIR}/${node}/daemons"
  [[ -f "$daemons_file" ]] || continue
  grep -q '^ospfd=yes' "$daemons_file" || continue

  cname="clab-${CNAME}-${node}"
  if ! docker inspect "$cname" >/dev/null 2>&1; then
    fail "OSPF ${node}: container not running"
    continue
  fi

  output="$(docker exec "$cname" vtysh -c 'show ip ospf neighbor' 2>/dev/null || true)"
  expected="$(grep -c '^ *no passive-interface' "${CONFIGS_DIR}/${node}/frr.conf" 2>/dev/null || echo 0)"
  full_count="$(grep -cE 'Full/' <<<"$output" || true)"

  if [[ "$expected" -eq 0 ]]; then
    pass "OSPF ${node}: no active OSPF links expected, none found"
  elif [[ "$full_count" -ge "$expected" ]]; then
    pass "OSPF ${node}: ${full_count}/${expected} adjacencies Full"
  else
    fail "OSPF ${node}: only ${full_count}/${expected} adjacencies Full"
  fi
done <<<"$NODES"

# --- 2. BGP session check ---------------------------------------------------
log_step "BGP session check"
while IFS= read -r node; do
  daemons_file="${CONFIGS_DIR}/${node}/daemons"
  [[ -f "$daemons_file" ]] || continue
  grep -q '^bgpd=yes' "$daemons_file" || continue

  cname="clab-${CNAME}-${node}"
  if ! docker inspect "$cname" >/dev/null 2>&1; then
    fail "BGP ${node}: container not running"
    continue
  fi

  expected="$(grep -c '^ *neighbor .* remote-as' "${CONFIGS_DIR}/${node}/frr.conf" 2>/dev/null || echo 0)"
  output="$(docker exec "$cname" vtysh -c 'show bgp summary' 2>/dev/null || true)"
  # Each neighbor row's Up/Down column shows an h:mm:ss (or d:hh:mm)
  # uptime once Established; non-established sessions show a state name
  # (Idle/Active/Connect/OpenSent/...) there instead. PfxRcd/PfxSnt/Desc
  # columns follow, so the match must not be end-of-line anchored.
  established="$(grep -cE '^[^[:space:]]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+.*[[:space:]][0-9]+:[0-9]{2}:[0-9]{2}[[:space:]]' <<<"$output" || true)"

  if [[ "$expected" -eq 0 ]]; then
    pass "BGP ${node}: no BGP neighbors expected, none configured"
  elif [[ "$established" -ge "$expected" ]]; then
    pass "BGP ${node}: ${established}/${expected} sessions Established"
  else
    fail "BGP ${node}: only ${established}/${expected} sessions Established"
  fi
done <<<"$NODES"

# --- 3. Full-mesh loopback reachability -------------------------------------
log_step "Loopback-to-loopback reachability (full mesh)"

declare -A LOOPBACK
while IFS= read -r node; do
  frr_conf="${CONFIGS_DIR}/${node}/frr.conf"
  [[ -f "$frr_conf" ]] || continue
  lo_ip="$(awk '/^interface lo$/{f=1;next} /^interface /{f=0} f && /ip address/{print $3; exit}' "$frr_conf" | cut -d/ -f1)"
  [[ -n "$lo_ip" ]] && LOOPBACK["$node"]="$lo_ip"
done <<<"$NODES"

PING_LOG="$(mktemp)"
trap 'rm -f "$PING_LOG"' EXIT

for src in "${!LOOPBACK[@]}"; do
  for dst in "${!LOOPBACK[@]}"; do
    [[ "$src" == "$dst" ]] && continue
    echo "${src} ${LOOPBACK[$src]} ${dst} ${LOOPBACK[$dst]}"
  done
done | xargs -P 8 -L 1 bash -c '
  src="$0"; src_ip="$1"; dst="$2"; ip="$3"
  cname="clab-'"${CNAME}"'-${src}"
  # Source explicitly from the loopback: without -I, the kernel picks
  # whatever address belongs to the chosen egress interface (often a
  # transit /30 link address), and those point-to-point subnets are
  # deliberately never advertised beyond the OSPF domain - only
  # loopbacks and LANs are. Pinging with an unbound source silently
  # picks an unroutable-from-the-far-side address and fails even though
  # the network is functioning correctly, which is exactly the trap
  # this script fell into during development. See docs/troubleshooting.md.
  if docker exec "$cname" ping -c1 -W2 -I "$src_ip" "$ip" >/dev/null 2>&1; then
    echo "OK ${src} -> ${dst}"
  else
    echo "FAIL ${src} -> ${dst} (${ip})"
  fi
' >>"$PING_LOG" 2>&1

# A lab may document pairs that are unreachable BY DESIGN (e.g. two
# upstream ISPs that Atlas deliberately does not provide transit
# between). Failures against such a pair are policy, not a regression.
EXPECTED_UNREACHABLE="${LAB_DIR}/expected-unreachable.txt"
UNEXPECTED_FAIL_LOG="$(mktemp)"
EXPECTED_FAIL_COUNT=0
if [[ -f "$EXPECTED_UNREACHABLE" ]]; then
  while IFS= read -r line; do
    [[ "$line" =~ ^FAIL\ ([^ ]+)\ -\>\ ([^ ]+) ]] || continue
    pair="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
    if grep -qxF "$pair" <(grep -v '^#' "$EXPECTED_UNREACHABLE" | grep -v '^[[:space:]]*$'); then
      EXPECTED_FAIL_COUNT=$((EXPECTED_FAIL_COUNT + 1))
    else
      echo "$line" >>"$UNEXPECTED_FAIL_LOG"
    fi
  done <"$PING_LOG"
else
  grep '^FAIL' "$PING_LOG" >"$UNEXPECTED_FAIL_LOG" || true
fi

ping_total="$(wc -l <"$PING_LOG" | tr -d ' ')"
ping_ok="$(grep -c '^OK' "$PING_LOG" || true)"
unexpected_fail="$(wc -l <"$UNEXPECTED_FAIL_LOG" | tr -d ' ')"

if [[ "$EXPECTED_FAIL_COUNT" -gt 0 ]]; then
  log_info "Reachability: ${EXPECTED_FAIL_COUNT} pair(s) unreachable by design (see ${EXPECTED_UNREACHABLE#$ATLASLAB_ROOT/})"
fi
if [[ "$unexpected_fail" -eq 0 && "$ping_total" -gt 0 ]]; then
  pass "Reachability: ${ping_ok}/${ping_total} loopback pairs reachable (${EXPECTED_FAIL_COUNT} expected-unreachable excluded)"
else
  fail "Reachability: ${unexpected_fail}/${ping_total} loopback pairs unexpectedly FAILED"
  sed 's/^/    /' "$UNEXPECTED_FAIL_LOG" | tee -a "${LOG_FILE}"
fi
rm -f "$UNEXPECTED_FAIL_LOG"

echo
log_step "Summary: $((TOTAL_CHECKS - FAIL))/${TOTAL_CHECKS} checks passed"
echo "Full log: ${LOG_FILE}"

if [[ "$FAIL" -gt 0 ]]; then
  exit "$EXIT_GENERAL_ERROR"
fi
exit "$EXIT_OK"
