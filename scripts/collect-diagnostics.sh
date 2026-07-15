#!/usr/bin/env bash
# AtlasLab - scripts/collect-diagnostics.sh
#
# Bundles a full diagnostics snapshot of a deployed lab into
# logs/diagnostics-<lab>-<timestamp>/ (and a matching .tar.gz): running
# FRR config, OSPF/BGP/route tables, interface state, and container logs
# for every node, plus the containerlab inspect output.
#
# Usage:
#   scripts/collect-diagnostics.sh <lab-name> [-h|--help]
#
# Exit codes:
#   0  diagnostics collected
#   1  general error
#   2  usage error
#   3  missing dependency
#   4  lab not found
set -uo pipefail

SCRIPT_NAME="collect-diagnostics"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

usage() {
  print_help_header "collect a full diagnostics bundle for a deployed lab"
  cat <<EOF
Usage:
  $(basename "$0") <lab-name> [-h|--help]

Writes:
  logs/diagnostics-<lab>-<timestamp>/
    containerlab-inspect.txt
    <node>/running-config.txt
    <node>/ospf-neighbor.txt
    <node>/bgp-summary.txt
    <node>/ip-route.txt
    <node>/interfaces.txt
    <node>/lldp-neighbors.txt
    <node>/frr.log
    <node>/ssh-status.txt
    <node>/docker-logs.txt
  logs/diagnostics-<lab>-<timestamp>.tar.gz

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

STAMP="$(date +%Y%m%d-%H%M%S)"
BUNDLE_DIR="${ATLASLAB_LOG_DIR}/diagnostics-${LAB}-${STAMP}"
mkdir -p "$BUNDLE_DIR"

log_step "Collecting diagnostics for lab '${LAB}' into ${BUNDLE_DIR}"

pushd "$LAB_DIR" >/dev/null
"$CLAB" inspect -t lab.clab.yml >"${BUNDLE_DIR}/containerlab-inspect.txt" 2>&1 || true
popd >/dev/null

NODES="$(node_list "$LAB")"

declare -A MGMT_IP
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  set -- $line
  MGMT_IP["$1"]="$2"
done < <(lab_mgmt_ips "$LAB")

NODE_COUNT=0
while IFS= read -r node; do
  [[ -z "$node" ]] && continue
  cname="clab-${CNAME}-${node}"
  node_dir="${BUNDLE_DIR}/${node}"
  mkdir -p "$node_dir"

  if docker inspect "$cname" >/dev/null 2>&1; then
    docker exec "$cname" vtysh -c 'show running-config' >"${node_dir}/running-config.txt" 2>&1 || true
    docker exec "$cname" vtysh -c 'show ip ospf neighbor' >"${node_dir}/ospf-neighbor.txt" 2>&1 || true
    docker exec "$cname" vtysh -c 'show ip ospf database' >"${node_dir}/ospf-database.txt" 2>&1 || true
    docker exec "$cname" vtysh -c 'show bgp summary' >"${node_dir}/bgp-summary.txt" 2>&1 || true
    docker exec "$cname" vtysh -c 'show ip route' >"${node_dir}/ip-route.txt" 2>&1 || true
    docker exec "$cname" ip -br addr show >"${node_dir}/interfaces.txt" 2>&1 || true
    docker exec "$cname" sh -c 'lldpcli show neighbors 2>/dev/null' >"${node_dir}/lldp-neighbors.txt" 2>&1 || true
    docker exec "$cname" cat /var/log/frr/frr.log >"${node_dir}/frr.log" 2>&1 || true
    docker logs "$cname" >"${node_dir}/docker-logs.txt" 2>&1 || true

    {
      echo "sshd process (inside container):"
      docker exec "$cname" pgrep -a sshd 2>&1 || echo "  not running"
      echo
      ip="${MGMT_IP[$node]:-}"
      if [[ -n "$ip" ]]; then
        echo "SSH login test: ${ATLASLAB_SSH_USER}@${ip}"
        ssh_atlas_run "$ip" "show version" 2>&1 | head -5
      else
        echo "SSH login test: skipped, no management IP found for '${node}'"
      fi
    } >"${node_dir}/ssh-status.txt" 2>&1 || true
  else
    echo "container ${cname} not running" >"${node_dir}/NOT_RUNNING.txt"
  fi
  NODE_COUNT=$((NODE_COUNT + 1))
done <<<"$NODES"

TARBALL="${BUNDLE_DIR}.tar.gz"
tar -czf "$TARBALL" -C "${ATLASLAB_LOG_DIR}" "$(basename "$BUNDLE_DIR")"

log_success "Collected diagnostics for ${NODE_COUNT} nodes"
echo "Directory: ${BUNDLE_DIR}"
echo "Tarball:   ${TARBALL}"
exit "$EXIT_OK"
