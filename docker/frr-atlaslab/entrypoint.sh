#!/bin/sh
# AtlasLab - custom entrypoint: start lldpd and sshd (both
# self-daemonizing) alongside the standard FRR startup sequence. tini
# (PID 1) reaps the orphaned children once this script execs into
# docker-start.
#
# -I restricts lldpd to the topology-facing links (eth1-eth9, the
# convention every AtlasLab node uses for its point-to-point links) and
# excludes eth0, containerlab's shared management-network interface.
# Without this, lldpd would also see every other node in the lab over
# eth0 (they're all on the same docker bridge subnet), which would make
# every node appear LLDP-adjacent to every other node - a false, fully
# meshed topology on top of the real one.
set -e

# Opt-in only (ATLASLAB_REMOVE_MGMT_DEFAULT_ROUTE=1, set per-node in a
# lab's lab.clab.yml) - every container gets a kernel-installed default
# route via eth0 (Docker's management-network gateway) at startup,
# which zebra imports as a "kernel"-sourced route with administrative
# distance 0. Any OSPF/BGP-originated 0.0.0.0/0 a node also learns
# (distance 110/20) can never win route selection against that, even
# though it shows up correctly in `show ip route` - the kernel route is
# what actually gets used for forwarding. This only matters for nodes
# that rely on a *learned* default route for real reachability
# (labs/07-multi-city's core/access/server tier); it must run before
# zebra starts, so zebra never imports the competing route at all.
# Every other lab leaves this unset and is entirely unaffected.
if [ "${ATLASLAB_REMOVE_MGMT_DEFAULT_ROUTE:-}" = "1" ]; then
  ip route del default dev eth0 2>/dev/null || true
fi

lldpd -I eth1,eth2,eth3,eth4,eth5,eth6,eth7,eth8,eth9

# Host keys are intentionally generated fresh on every container start
# rather than baked into the image: baking them in would mean every
# node in every lab (and every redeploy) shares the exact same SSH host
# key, which is a worse anti-pattern than a key that changes across
# redeploys. ssh-keygen -A is idempotent - it only creates keys that
# don't already exist - so this is a no-op if a volume ever persists
# /etc/ssh across restarts.
ssh-keygen -A >/var/log/frr/sshd-keygen.log 2>&1

# sshd daemonizes itself by default (no -D), same pattern as lldpd
# above; it listens on all of the container's interfaces including
# eth0 (containerlab's management network), which is the intended
# reachability path documented in docs/atlas-integration.md.
/usr/sbin/sshd

exec /usr/lib/frr/docker-start
