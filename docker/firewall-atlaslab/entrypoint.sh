#!/bin/sh
# AtlasLab - atlaslab/firewall entrypoint.
#
# All topology-specific behavior (interface addressing, static routes,
# iptables rules) lives in a bind-mounted /etc/atlaslab-firewall/setup.sh
# - this image itself is generic, the same way atlaslab/frr's image is
# generic and every node's actual behavior comes from its bind-mounted
# frr.conf.
#
# containerlab attaches topology links to a node's netns *after* the
# container has already started (a several-second gap, confirmed by
# direct testing - see docs/troubleshooting.md), so this waits for the
# expected interfaces to actually exist and settle before running
# setup.sh - running `ip addr add ... dev eth1` before eth1 exists
# fails silently and the firewall would come up unaddressed.
set -e

LOG=/var/log/atlaslab/firewall.log
touch "$LOG"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >>"$LOG"; }

log "waiting for topology interfaces to settle"
prev_count=-1
stable_checks=0
elapsed=0
while [ "$elapsed" -lt 30 ]; do
  count=$(ls /sys/class/net/ 2>/dev/null | grep -cE '^eth[1-9]' || true)
  if [ "$count" -gt 0 ] && [ "$count" -eq "$prev_count" ]; then
    stable_checks=$((stable_checks + 1))
    [ "$stable_checks" -ge 2 ] && break
  else
    stable_checks=0
  fi
  prev_count="$count"
  sleep 1
  elapsed=$((elapsed + 1))
done
log "interfaces settled: $(ls /sys/class/net/ 2>/dev/null | grep -E '^eth[1-9]' | tr '\n' ' ')"

if [ -f /etc/atlaslab-firewall/setup.sh ]; then
  log "applying /etc/atlaslab-firewall/setup.sh"
  # shellcheck disable=SC1091
  . /etc/atlaslab-firewall/setup.sh >>"$LOG" 2>&1
  log "setup.sh applied"
else
  log "WARNING: no /etc/atlaslab-firewall/setup.sh bind-mounted - firewall has no addressing or rules"
fi

# Same interface restriction as atlaslab/frr's lldpd (see
# docker/frr-atlaslab/entrypoint.sh): eth0 is containerlab's shared
# management bridge that every node in every deployed lab sits on -
# without -I, all of them would appear LLDP-adjacent to this firewall,
# a false full mesh on top of the real topology.
lldpd -I eth1,eth2,eth3,eth4,eth5,eth6,eth7,eth8,eth9
log "lldpd started"

ssh-keygen -A >>"$LOG" 2>&1
/usr/sbin/sshd
log "sshd started"

exec tail -F "$LOG"
