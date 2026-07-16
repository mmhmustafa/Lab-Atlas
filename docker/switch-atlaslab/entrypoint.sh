#!/bin/sh
# AtlasLab - atlaslab/switch entrypoint.
#
# Bridges every topology-facing interface (eth1..ethN - eth0 is
# containerlab's shared management interface and is deliberately never
# enslaved, for the same reason lldpd excludes it in atlaslab/frr: it's
# a shared Docker bridge network all nodes sit on, not a topology link)
# into a single kernel bridge, giving genuine L2 switching (MAC
# learning, flooding, etc.) entirely inside this container's own
# network namespace.
#
# containerlab attaches topology links to a node's netns *after* the
# container has already started (there's a several-second gap between
# "container created" and "link attached" - confirmed by direct testing
# during development, see docs/troubleshooting.md). A script that
# assumes eth1+ already exist at startup silently no-ops. This loop
# polls for newly-appeared interfaces instead of assuming a fixed port
# count or a fixed startup order - it runs for the life of the
# container, so a link added late (or a redeploy that changes the
# topology's port count on this node) still gets picked up.
set -e

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >>/var/log/atlaslab/switch.log; }

ip link add br0 type bridge
ip link set br0 up
log "br0 created"

# Same interface restriction as atlaslab/frr's lldpd (eth0 is the
# shared management bridge - see docker/frr-atlaslab/entrypoint.sh).
# lldpd works fine on bridge-enslaved ports (it uses per-port raw
# sockets), and a Linux bridge never *forwards* LLDP frames
# (01:80:c2:00:00:0e is link-local scope the kernel bridge won't
# flood), so this switch consumes LLDP itself and appears as the
# neighbor of everything plugged into it - exactly how a real managed
# L2 switch behaves, and exactly the physical wiring Atlas should
# discover.
lldpd -I eth1,eth2,eth3,eth4,eth5,eth6,eth7,eth8,eth9
log "lldpd started"

ssh-keygen -A >/var/log/atlaslab/sshd-keygen.log 2>&1
/usr/sbin/sshd
log "sshd started"

# Foreground loop: also the tini foreground anchor, so this never
# returns under normal operation.
while true; do
  for ifc in /sys/class/net/eth[1-9]*; do
    [ -e "$ifc" ] || continue
    name="$(basename "$ifc")"
    master="$( { cat "$ifc/master/uevent" 2>/dev/null | grep -m1 '^INTERFACE=' | cut -d= -f2; } || true)"
    if [ -z "$master" ]; then
      if ip link set "$name" master br0 2>>/var/log/atlaslab/switch.log \
        && ip link set "$name" up 2>>/var/log/atlaslab/switch.log; then
        log "enslaved ${name} into br0"
      fi
    fi
  done
  sleep 2
done
