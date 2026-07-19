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
| SSH management access | `ssh atlas@<mgmt-ip>` | Password `AtlasLab123!`, login shell is `vtysh` itself - see "SSH" below |
| Firewall policy enforcement | Cross-site pings in `labs/07-multi-city` | Real iptables `FORWARD` chain, default-deny inbound - see [labs/07-multi-city/README.md](../labs/07-multi-city/README.md#firewall-policy) |
| Firewall status over HTTP | `http://<fw-mgmt-ip>/` (07-multi-city) | Read-only web UI: interfaces, routes, live rule counters, LLDP, log - see [labs/07-multi-city/README.md](../labs/07-multi-city/README.md#firewall-web-ui) |
| L2 switching | `ssh atlas@<switch-ip> "show mac-address-table"`, or `lldpcli show neighbors` on its peers | Real kernel bridge per switch, see [labs/07-multi-city/README.md](../labs/07-multi-city/README.md) |

## LLDP

Every lab node - all three images - runs `lldpd`: layered onto the base
`frrouting/frr` image by `docker/frr-atlaslab/Dockerfile` (the base
image has no LLDP daemon at all), and equally into `atlaslab/firewall`
and `atlaslab/switch`, so routers, firewalls, and switches are all
LLDP-discoverable devices. `lldpd` is deliberately restricted to the
topology-facing interfaces (`-I eth1,eth2,...,eth9`) and excludes
`eth0`, containerlab's shared management-network interface - without
that restriction, every node in a lab would appear LLDP-adjacent to
every other node (they're all on the same Docker bridge subnet via
`eth0`), producing a false, fully-meshed topology on top of the real
point-to-point one. With the restriction in place, `lldpcli show
neighbors` on any node reports exactly its genuine topology neighbors,
matching the inventory / `labs/<lab>/lab.clab.yml` one-for-one.

The switches participate in LLDP the way a real managed L2 switch does:
a Linux kernel bridge never floods `01:80:c2:00:00:0e` (link-local
scope) frames, so each switch *consumes* LLDP on its ports and appears
as the neighbor of everything plugged into it, rather than letting the
routers behind it see each other as fake direct neighbors. Verified
live in 07-multi-city: `mumbai-core` reports `mumbai-fw`/`mumbai-sw1`/
`mumbai-sw2` on eth1-3 (not the access routers or server behind the
switches), `mumbai-sw1` reports `mumbai-core`/`mumbai-access1`/
`mumbai-server` on its three ports, and `mumbai-fw` reports
`mumbai-edge` outside / `mumbai-core` inside - the discovered topology
is the physical wiring, edge to edge.

On firewalls and switches, `show lldp neighbors` is part of
`fwsh`/`swsh` (no privilege needed - the `atlas` account is in the
`lldpd` group, and lldpd's control socket is group-accessible).
Verified in every lab as part of validating this repository.

## Optional services

The task brief asked for SSH, SNMP, syslog, NTP, and DNS "where
practical," with instructions to document rather than fake what isn't
reasonably supportable. Here's the assessment for each, done honestly:

- **SSH**: configured. Every `atlaslab/frr` node runs `sshd` (Alpine's
  `openssh` package, layered on in `docker/frr-atlaslab/Dockerfile`
  alongside `lldpd`) reachable over containerlab's management network
  (`eth0`). Login is `ssh atlas@<mgmt-ip>` with the password
  `AtlasLab123!` - a single, static, documented credential shared
  across every node deliberately (this is a local, ephemeral lab
  network, not a production fleet; see the Dockerfile for the full
  rationale). The `atlas` account's login shell is `/usr/bin/vtysh`
  itself, so both interactive (`ssh atlas@<ip>`) and one-shot
  (`ssh atlas@<ip> "show ip ospf neighbor"`) sessions drop straight into
  the FRR CLI - the same experience as a real router, and no different
  syntax for Atlas to special-case versus `docker exec <node> vtysh -c
  '...'`. SSH host keys are generated fresh per container at startup
  (`entrypoint.sh`, `ssh-keygen -A`) rather than baked into the image,
  so every node - and every redeploy - gets its own unique key; connect
  with `-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null` for
  exactly that reason (there is nothing long-lived here for host-key
  pinning to protect). `make verify` builds/validates the image has
  `sshd` + the `atlas` account; `make test` SSH-logs into every
  deployed node and runs a real vtysh command as part of the regression
  suite (`scripts/test-connectivity.sh`) - see
  [docs/testing.md](testing.md).

  `labs/07-multi-city` adds two more images - `atlaslab/firewall` and
  `atlaslab/switch` - with the same SSH access and credential.
  `atlaslab/firewall`'s login shell is `fwsh`
  (`docker/firewall-atlaslab/fwsh`), a small router-style "show command"
  CLI in the same spirit as `vtysh` rather than a raw shell: `show
  version`, `show interfaces`, `show route`, `show firewall rules` (the
  live iptables `FORWARD` chain, with packet/byte counters), `show
  running-config` (the generated `setup.sh` the node actually booted
  with), and `show log`. It's read-only by design - unrecognized input
  is rejected outright by `fwsh` itself (confirmed: `doas /usr/sbin/
  iptables -F FORWARD` typed at the prompt gets "% Unknown command",
  never reaches a shell or `doas`), and the one privileged operation it
  does need (root is required to even *list* live netfilter rules) is
  scoped to a single exact command via `/etc/doas.conf` - `doas.conf`'s
  `args` clause requires an exact argument match, so this is nowhere
  near a general sudo grant.

  `atlaslab/switch`'s login shell is `swsh`
  (`docker/switch-atlaslab/swsh`), the same idea again: `show version`,
  `show interfaces` (`bridge link show` - port/forwarding state), `show
  mac-address-table` (`bridge fdb show` - genuine learned-MAC data,
  useful for Atlas to confirm L2 discovery), `show ip interface`
  (`br0`/`eth0` addressing - the switch has no data-plane IP of its
  own, only its bridge and management interfaces), and `show log`.
  Unlike `fwsh`, none of this needs a `doas` rule at all - `bridge`/`ip`
  link and fdb queries are unprivileged reads, confirmed directly (no
  "Permission denied" the way `iptables -L` needs root even just to
  list rules).

  `scripts/test-connectivity.sh`'s SSH check is role-aware: it runs
  `show version` against nodes with an FRR `daemons` file (which both
  `fwsh` and `swsh` also happen to implement, but the check doesn't
  rely on that) and a trivial `echo` against everything else, so every
  node type gets a real, verified login+command check, not just a
  TCP-connect probe.
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

Two supported integration points, pick whichever matches how Atlas is
deployed relative to this lab:

- **Over the network, like a real device:** `ssh atlas@<mgmt-ip>
  '<show command>'` (see "SSH" above for the credential and the
  `StrictHostKeyChecking=no` note). This is the realistic path if Atlas
  runs anywhere other than the lab host itself, since it only needs
  network reachability to each node's management IP, not Docker access.
- **From the lab host directly:** `docker exec clab-<lab>-<node> vtysh
  -c '<show command>'` - what every script under `scripts/` already
  uses internally. Requires Docker socket / `docker exec` access to the
  host running containerlab, but has zero SSH-session overhead if Atlas
  already runs there.

Both land in the same place: a single `vtysh -c '<command>'` call
against the node's real FRR state, since the `atlas` SSH account's
login shell *is* `vtysh` (see above) - there's no behavioral difference
between the two paths beyond transport.
