#!/usr/bin/env bash
# AtlasLab - scripts/inspect-lab.sh
#
# Shows the current state of a deployed lab: containerlab's own inspect
# table, per-node container health, and a link/interface summary pulled
# directly from each FRR node.
#
# Usage:
#   scripts/inspect-lab.sh <lab-name> [-h|--help]
#
# Exit codes:
#   0  inspected successfully (lab may or may not be running)
#   1  general error
#   2  usage error
#   3  missing dependency
#   4  lab not found
set -euo pipefail

SCRIPT_NAME="inspect-lab"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

usage() {
  print_help_header "inspect a deployed containerlab topology"
  cat <<EOF
Usage:
  $(basename "$0") <lab-name> [-h|--help]

Arguments:
  lab-name    Directory name under labs/, e.g. 06-atlas-demo

Prints:
  - containerlab inspect table (node state, image, IPs)
  - per-node interface up/down summary (from the container's own view)

Exit codes:
  0  success
  1  general error
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
CLAB="$(containerlab_bin)"
CNAME="$(clab_name "$LAB")"

log_step "containerlab inspect: ${LAB}"
pushd "$LAB_DIR" >/dev/null
"$CLAB" inspect -t lab.clab.yml 2>&1 | tee -a "${LOG_FILE}" || log_warn "containerlab inspect returned non-zero (lab may not be deployed)"
popd >/dev/null

echo
log_step "Per-node interface summary"
NODES="$(node_list "$LAB")"
if [[ -z "$NODES" ]]; then
  log_warn "No nodes found in topology"
  exit "$EXIT_OK"
fi

printf "%-16s %-8s %-8s %-8s\n" "NODE" "UP" "DOWN" "TOTAL"
while IFS= read -r node; do
  cname="clab-${CNAME}-${node}"
  if ! docker inspect "$cname" >/dev/null 2>&1; then
    printf "%-16s %-8s %-8s %-8s\n" "$node" "-" "-" "not deployed"
    continue
  fi
  # eth0 is the containerlab management interface; count eth1+ only.
  counts="$(docker exec "$cname" sh -c "ip -o link show up 2>/dev/null | grep -Ec 'eth[1-9]'" || echo 0)"
  total="$(docker exec "$cname" sh -c "ip -o link show 2>/dev/null | grep -Ec 'eth[1-9]'" || echo 0)"
  down=$((total - counts))
  printf "%-16s %-8s %-8s %-8s\n" "$node" "$counts" "$down" "$total"
done <<<"$NODES"

exit "$EXIT_OK"
