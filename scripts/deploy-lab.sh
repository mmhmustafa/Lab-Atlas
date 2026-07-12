#!/usr/bin/env bash
# AtlasLab - scripts/deploy-lab.sh
#
# Deploys a containerlab topology under labs/<lab-name>/lab.clab.yml and
# waits for all nodes to report "running" before returning.
#
# Usage:
#   scripts/deploy-lab.sh <lab-name> [-h|--help]
#
# Exit codes:
#   0  deployed successfully
#   1  general error
#   2  usage error
#   3  missing dependency (docker/containerlab)
#   4  lab not found
#   5  containerlab deploy failed
set -euo pipefail

SCRIPT_NAME="deploy-lab"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

usage() {
  print_help_header "deploy a containerlab topology"
  cat <<EOF
Usage:
  $(basename "$0") <lab-name> [-h|--help]

Arguments:
  lab-name    Directory name under labs/, e.g. 06-atlas-demo

Available labs:
$(list_labs | sed 's/^/  - /')

Exit codes:
  0  deployed successfully
  1  general error
  2  usage error
  3  missing dependency
  4  lab not found
  5  containerlab deploy failed
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

log_step "Deploying lab '${LAB}'"
log_info "Topology: ${LAB_DIR}/lab.clab.yml"

if ! docker info >/dev/null 2>&1; then
  die "Docker daemon is not reachable. Run scripts/verify-environment.sh" "$EXIT_MISSING_DEP"
fi

pushd "$LAB_DIR" >/dev/null
trap 'popd >/dev/null' EXIT

if ! "$CLAB" deploy -t lab.clab.yml 2>&1 | tee -a "${LOG_FILE}"; then
  log_error "containerlab deploy failed - see ${LOG_FILE}"
  exit "$EXIT_OP_FAILED"
fi

CNAME="$(clab_name "$LAB")"
log_step "Waiting for all containers to report 'running'"

MAX_WAIT=90
elapsed=0
while true; do
  total=0
  running=0
  while IFS= read -r line; do
    total=$((total + 1))
    [[ "$line" == "running" ]] && running=$((running + 1))
  done < <(docker ps -a --filter "name=clab-${CNAME}-" --format '{{.Status}}' | awk '{print ($1=="Up")?"running":"other"}')

  if [[ "$total" -gt 0 && "$running" -eq "$total" ]]; then
    log_success "All ${total} containers running"
    break
  fi

  elapsed=$((elapsed + 3))
  if [[ "$elapsed" -ge "$MAX_WAIT" ]]; then
    log_warn "Timed out after ${MAX_WAIT}s waiting for containers (last: ${running}/${total} running)"
    break
  fi
  sleep 3
done

echo
log_step "Lab '${LAB}' deployed"
echo "Inspect it with:   scripts/inspect-lab.sh ${LAB}"
echo "Test connectivity: scripts/test-connectivity.sh ${LAB}"
echo "Full log:          ${LOG_FILE}"
exit "$EXIT_OK"
