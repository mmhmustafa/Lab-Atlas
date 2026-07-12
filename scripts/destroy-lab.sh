#!/usr/bin/env bash
# AtlasLab - scripts/destroy-lab.sh
#
# Destroys a deployed containerlab topology and cleans up its runtime
# artifacts (clab-<name>/ directory, .state.clab.yaml, etc).
#
# Usage:
#   scripts/destroy-lab.sh <lab-name> [-y|--yes] [-h|--help]
#
# Exit codes:
#   0  destroyed successfully (or nothing was deployed)
#   1  general error
#   2  usage error
#   3  missing dependency
#   4  lab not found
#   5  containerlab destroy failed
set -euo pipefail

SCRIPT_NAME="destroy-lab"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

usage() {
  print_help_header "destroy a deployed containerlab topology"
  cat <<EOF
Usage:
  $(basename "$0") <lab-name> [-y|--yes] [-h|--help]

Arguments:
  lab-name    Directory name under labs/, e.g. 06-atlas-demo

Options:
  -y, --yes   Skip the interactive confirmation prompt (destructive).

This removes all running containers for the lab and cleans up
containerlab's generated runtime directory (clab-<name>/) so the lab
directory returns to source-controlled state.

Exit codes:
  0  destroyed successfully
  1  general error
  2  usage error
  3  missing dependency
  4  lab not found
  5  containerlab destroy failed
EOF
}

AUTO_YES=0
LAB=""
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit "$EXIT_OK" ;;
    -y|--yes) AUTO_YES=1 ;;
    -*) log_error "Unknown option: $arg"; usage >&2; exit "$EXIT_USAGE" ;;
    *) LAB="$arg" ;;
  esac
done

if [[ -z "$LAB" ]]; then
  log_error "No lab name given"
  usage >&2
  exit "$EXIT_USAGE"
fi

LAB_DIR="$(resolve_lab "$LAB")"
CLAB="$(containerlab_bin)"
CNAME="$(clab_name "$LAB")"

RUNNING_COUNT="$(docker ps -a --filter "name=clab-${CNAME}-" --format '{{.Names}}' | wc -l | tr -d ' ')"
if [[ "$RUNNING_COUNT" -eq 0 ]]; then
  log_info "No containers found for lab '${LAB}' (clab-${CNAME}-*) - nothing to destroy"
  exit "$EXIT_OK"
fi

log_warn "This will destroy ${RUNNING_COUNT} container(s) belonging to lab '${LAB}' (prefix clab-${CNAME}-)."
if [[ "$AUTO_YES" -ne 1 ]]; then
  read -r -p "Continue? [y/N] " reply
  case "$reply" in
    y|Y|yes|YES) ;;
    *) log_info "Aborted by user"; exit "$EXIT_OK" ;;
  esac
fi

pushd "$LAB_DIR" >/dev/null
trap 'popd >/dev/null' EXIT

log_step "Destroying lab '${LAB}'"
if ! "$CLAB" destroy -t lab.clab.yml --cleanup 2>&1 | tee -a "${LOG_FILE}"; then
  log_error "containerlab destroy failed - see ${LOG_FILE}"
  exit "$EXIT_OP_FAILED"
fi

log_success "Lab '${LAB}' destroyed"
exit "$EXIT_OK"
