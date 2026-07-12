# Testing

## `scripts/test-connectivity.sh`

```bash
make test LAB=06-atlas-demo
```

Three phases, generic across every lab (it reads node names from
`labs/<lab>/lab.clab.yml` and which daemons are enabled from
`configs/<lab>/<node>/daemons` - nothing is hardcoded to a specific
device list):

1. **OSPF adjacency check** - for every node with `ospfd=yes`, counts
   `Full` adjacencies from `show ip ospf neighbor` and compares against
   the number of `no passive-interface` lines in that node's `frr.conf`
   (i.e. the number of links OSPF should actually be adjacent over).
2. **BGP session check** - for every node with `bgpd=yes`, counts
   sessions whose `show bgp summary` Up/Down column shows an `h:mm:ss`
   uptime (established) rather than a state name (Idle/Active/Connect/...),
   and compares against the number of `neighbor ... remote-as` lines in
   that node's `frr.conf`.
3. **Full-mesh loopback reachability** - every node pings every other
   node's loopback, in parallel (`xargs -P 8`), **explicitly sourced
   from its own loopback** with `ping -I <loopback>`.

### Why pings are sourced from the loopback

Without `-I`, the kernel picks whatever address belongs to the chosen
egress interface as the packet's source - for a multi-hop route that's
often a transit `/30` link address, not the loopback. Those
point-to-point subnets are deliberately never advertised beyond the
OSPF domain (see [docs/routing.md](routing.md)) - only loopbacks and LAN
stubs are. A ping sourced from an unadvertised transit address silently
picks a source the far side has no route back to and times out, even
though the network is functioning correctly.

This is exactly the trap the test script fell into while validating
06-atlas-demo: every OSPF/BGP metric showed fully converged and healthy,
yet ~1/3 of loopback pings failed, all involving multi-hop paths across
the OSPF/BGP boundary. See
[docs/troubleshooting.md](troubleshooting.md) for the full diagnostic
trail; the fix was a one-line addition (`-I <src-loopback>`) once the
actual cause was found.

### Expected-unreachable pairs

Some loopback pairs are unreachable **by design**, not by bug - e.g. in
06-atlas-demo, `isp1` and `isp2` have no route to each other (Atlas
doesn't provide inter-ISP transit), and branch loopbacks/LANs are
intentionally excluded from what's advertised to the ISPs. A lab can
list such pairs in `labs/<lab>/expected-unreachable.txt`:

```
# <src-node> <dst-node>, one direction per line
isp1 isp2
isp1 branch1
...
```

Failures against a listed pair are reported as `[INFO]` (policy, not a
regression) and excluded from the pass/fail count; anything else that
fails is a real, unexpected failure and fails the run.

## Results (06-atlas-demo, current state)

Run twice - once, then again after a full `destroy` + `deploy` cycle to
confirm reproducibility - with identical results both times:

- OSPF: 14/14 campus routers, all adjacencies `Full` (9 on each core
  router, 3 on each edge/server-edge router, 5 on each dist router, 2 on
  each access router - see [docs/architecture.md](architecture.md)).
- BGP: 10/10 BGP-speaking routers, all sessions `Established` (9 on each
  edge router, 3 on each core router, 2 on each ISP/branch).
- Reachability: 362/380 loopback pairs reachable (100% of everything not
  excluded by `expected-unreachable.txt`'s 18 by-design-unreachable
  pairs).

## Other scripts

- `scripts/inspect-lab.sh <lab>` - point-in-time state: containerlab's
  inspect table plus a per-node interface up/down count.
- `scripts/collect-diagnostics.sh <lab>` - full diagnostics bundle per
  node (`show running-config`, `show ip ospf neighbor`, `show ip ospf
  database`, `show bgp summary`, `show ip route`, `ip -br addr`, and the
  container's stdout log), written to
  `logs/diagnostics-<lab>-<timestamp>/` and tarred alongside it. Use
  this to capture full state before filing an issue or reverting a
  config change.
