# Atlas Integration

What Atlas can discover in this lab, how, and - honestly - what isn't
configured and why.

## Discovery surface

| Capability | How | Notes |
|---|---|---|
| Devices | `containerlab inspect`, or `docker ps --filter name=clab-<lab>-` | Hostnames match the topology node names throughout |
| Interfaces | `ip -br addr` / `show interface` per node | Every interface has a description (see below) |
| Meaningful interface descriptions | `frr.conf` `description` line | Convention: `LINK-TO-<peer>-<link-group>`, e.g. `LINK-TO-CORE1-EDGE-CORE` |
| LLDP neighbors | `lldpcli show neighbors`, or LLDP TLVs over the wire | See "LLDP" below |
| OSPF neighbors/LSDB | `show ip ospf neighbor`, `show ip ospf database` | Single area 0.0.0.0, 14 campus routers in 06-atlas-demo |
| BGP sessions/routes | `show bgp summary`, `show ip bgp` | iBGP mesh + eBGP to ISPs/branches, see [docs/routing.md](routing.md) |
| Routes (incl. redistributed) | `show ip route` | OSPF externals (type-2) visible wherever BGP routes were redistributed in |
| Loopbacks | `show ip route` / interface list | Router ID always equals the loopback - see [docs/routing.md](routing.md#router-ids) |
| Redundant paths | `show ip route` (ECMP `*` markers), `show bgp` (`maximum-paths ibgp`) | Every layer boundary is dual-homed - see [docs/architecture.md](architecture.md) |

## LLDP

Every lab node runs `lldpd`, layered onto the base `frrouting/frr` image
by `docker/frr-atlaslab/Dockerfile` (the base image has no LLDP daemon
at all). `lldpd` is deliberately restricted to the topology-facing
interfaces (`-I eth1,eth2,...,eth9`) and excludes `eth0`, containerlab's
shared management-network interface - without that restriction, every
node in a lab would appear LLDP-adjacent to every other node (they're
all on the same Docker bridge subnet via `eth0`), producing a false,
fully-meshed topology on top of the real point-to-point one. With the
restriction in place, `lldpcli show neighbors` on any node reports
exactly its genuine topology neighbors, matching `inventory/devices.yaml`
/ `labs/<lab>/lab.clab.yml` one-for-one.

Verified in 06-atlas-demo and every other lab as part of validating this
repository.

## Optional services

The task brief asked for SSH, SNMP, syslog, NTP, and DNS "where
practical," with instructions to document rather than fake what isn't
reasonably supportable. Here's the assessment for each, done honestly:

- **SSH**: not configured. `openssh-server` is installable via `apk` in
  the same way `lldpd` was, and would need `sshd_config` plus a
  decision on credentials/host-key management across 20+ nodes. This is
  a reasonable, contained follow-up (see "Recommended PR-003" in the
  final report) but wasn't done here to keep the credential-management
  surface out of a first pass. `docker exec <node> vtysh` is the
  in-repo equivalent for now.
- **SNMP**: **not reasonably supportable** without rebuilding FRR
  itself. FRR's SNMP support (the `snmpd`/AgentX integration for
  OSPF-MIB/BGP4-MIB) is a compile-time option (`--enable-snmp`) that the
  published `frrouting/frr` image is not built with; installing
  `net-snmp` via `apk` (available, and pulled in transitively as an
  `lldpd` dependency) only provides a generic SNMP agent with no
  FRR/routing MIB behind it, which would be actively misleading to wire
  up. This genuinely needs a custom FRR build, not just a container
  layer.
- **Syslog**: partially addressed differently. FRR supports a native
  `log syslog` directive, but no lab node runs a syslog daemon to
  receive it, and standing one up cluster-wide was judged lower value
  than just fixing local file logging - which is what was done instead:
  `docker/frr-atlaslab/Dockerfile` pre-creates `/var/log/frr` with the
  right ownership, so the `log file /var/log/frr/frr.log informational`
  line already in every generated config actually works (this was
  previously failing silently - see
  [docs/troubleshooting.md](troubleshooting.md)). `frr.log` is included
  in every `collect-diagnostics.sh` bundle.
- **NTP**: not configured, deliberately. Every container shares the WSL2
  host's kernel clock - there is no per-container hardware clock drift
  for NTP to correct in a Docker/containerlab lab (unlike a fleet of
  real devices or VMs), so a lab-internal NTP hierarchy would be
  cosmetic rather than functional.
- **DNS**: containerlab itself already populates `/etc/hosts` on the
  Docker host for every deployed node (`clab-<lab>-<node>` &rarr; its
  management IP) - visible in the `deploy-lab.sh` output ("Adding host
  entries"). There is no DNS server *inside* the topology for routers to
  resolve each other by name, which wasn't added because FRR's routing
  behavior never depends on it; a `dnsmasq` node would be a
  straightforward addition if a future test specifically needs
  in-topology name resolution.

## Suggested Atlas polling pattern

For OSPF/BGP/route/LLDP state, `docker exec clab-<lab>-<node> vtysh -c
'<show command>'` is the most direct integration point today (no SSH
daemon needed - Atlas would need Docker socket or `docker exec`
access to the host, which is how every script in `scripts/` already
operates). If Atlas is meant to poll purely over the network the way it
would a real device, SSH (see above) is the natural next step.
