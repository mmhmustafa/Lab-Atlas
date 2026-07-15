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

# Large multi-image topologies can hit a containerlab link-scheduling
# race: a node whose image starts much faster than its peers' (e.g.
# atlaslab/firewall/switch vs. atlaslab/frr) can reach its own
# create-links stage before a peer's container even exists yet,
# which containerlab reports as "Link not found" rather than waiting -
# confirmed by direct testing (labs/07-multi-city, see
# docs/troubleshooting.md). startup-delay on the fast-starting nodes
# mitigates this at the topology level; retrying here is the last-resort
# safety net for whatever variance startup-delay doesn't fully absorb -
# a destroy+redeploy cycle has been 100% effective on every occurrence
# seen so far, and it's a transient scheduling race, not a config error,
# so retrying is the correct response rather than failing outright.
MAX_DEPLOY_ATTEMPTS=3
attempt=1
deploy_ok=0
while [[ "$attempt" -le "$MAX_DEPLOY_ATTEMPTS" ]]; do
  if [[ "$attempt" -gt 1 ]]; then
    log_warn "Deploy attempt $((attempt - 1)) failed (likely a containerlab link-scheduling race) - destroying and retrying (attempt ${attempt}/${MAX_DEPLOY_ATTEMPTS})"
    "$CLAB" destroy -t lab.clab.yml --cleanup >>"${LOG_FILE}" 2>&1 || true
  fi
  if "$CLAB" deploy -t lab.clab.yml 2>&1 | tee -a "${LOG_FILE}"; then
    deploy_ok=1
    break
  fi
  attempt=$((attempt + 1))
done

if [[ "$deploy_ok" -ne 1 ]]; then
  log_error "containerlab deploy failed after ${MAX_DEPLOY_ATTEMPTS} attempts - see ${LOG_FILE}"
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

# Captured in full before slicing out the first line (rather than piping
# through `head -1`): under `set -o pipefail`, head closing the pipe
# early sends SIGPIPE back to the lab_mgmt_ips producer, which bash
# reports as an exit-141 pipeline failure and, under `set -e`, aborts
# the whole script right here - this actually happened during development.
MGMT_LIST="$(lab_mgmt_ips "$LAB" 2>/dev/null || true)"
FIRST_NODE_IP=""
if [[ -n "$MGMT_LIST" ]]; then
  FIRST_NODE_LINE="${MGMT_LIST%%$'\n'*}"
  FIRST_NODE_IP="${FIRST_NODE_LINE#* }"
fi
if [[ -n "$FIRST_NODE_IP" ]]; then
  echo
  echo "SSH management access (user: ${ATLASLAB_SSH_USER}, see docs/atlas-integration.md):"
  echo "  ssh ${ATLASLAB_SSH_USER}@<mgmt-ip>   # e.g. ssh ${ATLASLAB_SSH_USER}@${FIRST_NODE_IP}"
  echo "  scripts/inspect-lab.sh ${LAB} lists every node's management IP."
fi
exit "$EXIT_OK"
