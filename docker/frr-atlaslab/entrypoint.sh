#!/bin/sh
# AtlasLab - custom entrypoint: start lldpd (self-daemonizing) alongside
# the standard FRR startup sequence. tini (PID 1) reaps the orphaned
# lldpd child once this script execs into docker-start.
#
# -I restricts lldpd to the topology-facing links (eth1-eth9, the
# convention every AtlasLab node uses for its point-to-point links) and
# excludes eth0, containerlab's shared management-network interface.
# Without this, lldpd would also see every other node in the lab over
# eth0 (they're all on the same docker bridge subnet), which would make
# every node appear LLDP-adjacent to every other node - a false, fully
# meshed topology on top of the real one.
set -e

lldpd -I eth1,eth2,eth3,eth4,eth5,eth6,eth7,eth8,eth9

exec /usr/lib/frr/docker-start
