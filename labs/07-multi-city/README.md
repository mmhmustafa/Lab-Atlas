# 07-multi-city

Four independently-administered "city" sites - Mumbai, Delhi, Hyderabad,
Chennai - each a compact enterprise network (router, firewall, core,
two L2 switches, two access routers, one server), connected by a
full-mesh inter-city WAN. Built to give Atlas a realistic multi-site
topology: real OSPF per site, real eBGP between sites, a real stateful
firewall enforcing a real (and discoverable) security policy, and real
L2 switching - not any of it faked or stubbed.

**This lab is generated, not hand-written.** `inventory/multi-city.yaml`
is the source of truth (just the four sites' names/index/ASN - every
site has the identical internal shape, so that shape lives once in
`scripts/generate-multicity.py`, not copy-pasted four times). To change
the topology or addressing, edit the inventory or the generator and
re-run:

```bash
python3 scripts/generate-multicity.py
# or: make generate-multicity
```

## Why one lab, not four

containerlab links only exist within a single deployed topology - there
is no supported way to veth-link nodes across two separately-deployed
labs. Since the whole point here is that the four cities **connect to
each other**, they have to be one containerlab deployment
(`atlas-07-multi-city`), not four independent ones. Every node name is
prefixed with its city (`mumbai-edge`, `delhi-core`, ...) so each site
still reads as its own network within that one deployment, and each
site's firewall enforces its own independent policy - administratively
they behave like four separate networks, they just happen to share one
`containerlab deploy`/`destroy` lifecycle.

## At a glance

- 32 nodes: 4 sites x 8 (edge, firewall, core, 2x L2 switch, 2x access,
  server).
- 38 links: 32 intra-site + 6 inter-site (full mesh among the 4 edge
  routers).
- Per-site OSPF area 0 (four *independent* IGP domains - Mumbai's OSPF
  never touches Delhi's).
- Full-mesh eBGP among the 4 edge routers (AS 65010/65020/65030/65040).
- A real iptables stateful firewall per site (`atlaslab/firewall`) at
  the WAN/LAN boundary - default-deny inbound, specific allow-listed
  exceptions (see "Firewall policy" below).
- Real L2 switching per site (`atlaslab/switch`) - a genuine Linux
  kernel bridge inside each switch's own container, not a
  containerlab-managed host bridge (that needs root - not available in
  this environment; see "Known limitations, honestly").
- SSH management on every node, all three images (`atlaslab/frr`,
  `atlaslab/firewall`, `atlaslab/switch`) - see
  [docs/atlas-integration.md](../../docs/atlas-integration.md).

## Topology, per site

```
                    (5 other cities' edge routers, full mesh)
                                    |
                                mumbai-edge
                                    |
                             mumbai-fw  (iptables, default-deny inbound)
                                    |
                               mumbai-core
                                /        \
                        mumbai-sw1      mumbai-sw2
                         /      \        /      \
              mumbai-access1  mumbai-server   mumbai-access2
                              (dual-homed to both switches)
```

`edge` is the only BGP speaker and the only node with a WAN-facing
interface. `fw` is a plain L3 firewall (not a routing-protocol speaker
at all - see "Routing across the firewall boundary" below). `core` is
the OSPF gateway for everything behind the firewall. `sw1`/`sw2` are
independent L2 segments (deliberately *not* linked to each other -
see "Known limitations, honestly") each serving one access router
plus one leg of the dual-homed server.

## Addressing

| Block | Purpose |
|---|---|
| `10.250.<idx>.1/32` | Each site's edge router loopback - standalone, always reachable, no firewall in the way |
| `10.251.<idx>.0/24` | Each site's *internal* loopback block (core/access1/access2/server) - behind the firewall |
| `172.30.<idx*4+0>.0/24` | Segment A (sw1: core, access1, server) |
| `172.30.<idx*4+1>.0/24` | Segment B (sw2: core, access2, server) |
| `172.30.<idx*4>.0/22` | Site's LAN aggregate, advertised into BGP |
| `10.90.<idx>.0/30` | edge&harr;fw link |
| `10.90.<idx>.4/30` | fw&harr;core link |
| `192.168.100.0/24` | Inter-city WAN mesh (six /30s, one per edge-router pair) |

`idx`: mumbai=0, delhi=1, hyderabad=2, chennai=3 (from
`inventory/multi-city.yaml`).

Edge's own loopback is deliberately in a *different* block
(`10.250.x.x`) from everything behind its firewall (`10.251.x.x`) -
see "Firewall policy" for why that separation matters.

## Routing across the firewall boundary

The firewall is **not** a routing-protocol speaker - no OSPF, no BGP.
Real enterprise firewalls very often aren't (routing protocols
multicast/broadcast hellos that a stateful firewall would need explicit
rules to even pass), so this is a deliberate design choice, not a
shortcut:

- `edge` has two static routes (the LAN aggregate and the internal
  loopback block), each pointed at the firewall's outside address, and
  originates both into BGP so every other city can reach in.
- `fw` has a plain default route out (`eth1`, toward edge) and a static
  route back to the internal blocks (`eth2`, toward core) - see
  `configs/07-multi-city/<site>-fw/setup.sh`.
- `core` originates a default route into OSPF
  (`default-information originate always`) so every internal OSPF
  speaker (access1/access2/server) can reach anything outside the site
  without core needing to know every remote prefix individually.

That last point interacts with something easy to miss: every
container also gets a **kernel** default route via `eth0` (Docker's
management-network gateway), which zebra imports at administrative
distance 0 - lower than *any* routing protocol, so it silently wins
over the OSPF-originated default even though the OSPF route shows up
correctly in `show ip route`. `core`/`access1`/`access2`/`server` set
`ATLASLAB_REMOVE_MGMT_DEFAULT_ROUTE=1` (a node `env:` var in
`lab.clab.yml`, handled in `docker/frr-atlaslab/entrypoint.sh`) to
delete that competing route before zebra ever starts. `edge` doesn't
need this - it never relies on a *learned* default, only specific
eBGP-learned routes. See
[docs/troubleshooting.md](../../docs/troubleshooting.md) for how this
was actually found (it looked like 200 unrelated reachability failures
before the pattern became obvious).

## Firewall policy

Every site's firewall (`configs/07-multi-city/<site>-fw/setup.sh`) is
default-deny inbound, with these exceptions:

- Established/related connections (stateful).
- Anything the site itself initiates outbound (`eth2`&rarr;`eth1`,
  inside to WAN) - unrestricted.
- ICMP inbound to that site's **core** and **server** loopbacks only.
- TCP/22 inbound to that site's **server** loopback only (a
  "published service" stand-in).
- Everything else inbound is logged (`ATLASLAB-FW-<CITY>-DROP:`) and
  dropped by the default policy.

The practical effect: `access1`/`access2` in every site are internal-
only - unreachable from anywhere outside that site's own firewall,
including that **same site's own edge router** (edge sits on the WAN
side of its own firewall too, so it's just as "outside" as a different
city). `core` and `server` are reachable cross-site; the access tier
never is. This is exactly the segmentation a real branch/site firewall
enforces (published services and management-plane infrastructure
reachable, end-user/workstation subnets not), not an arbitrary
lab restriction - and it's genuinely enforced by iptables, not by a
routing gap: `access1`/`access2`'s loopbacks *are* inside the routable
internal block, so a lab that only checked "is there a route" would
wrongly conclude they're reachable. The firewall's `FORWARD` chain is
what actually blocks them.

`labs/07-multi-city/expected-unreachable.txt` is generated to match
this policy exactly (every non-same-site source, plus each site's own
edge, listed against that site's access1/access2) -
`scripts/test-connectivity.sh` reads it directly, the same mechanism
`06-atlas-demo` uses for its own by-design-unreachable pairs.

## Firewall show-command CLI

`ssh atlas@<fw-mgmt-ip>` drops into `fwsh`
(`docker/firewall-atlaslab/fwsh`) - a small router-style "show command"
shell, the same idea as `vtysh` on the FRR nodes but scoped to what a
firewall admin actually wants to inspect, not a general-purpose shell:

```
show version           - image/OS identity (includes hostname)
show hostname           - this node's hostname
show interfaces        - interface addressing
show route              - routing table
show firewall rules    - live iptables FORWARD chain, packet/byte counters
show lldp neighbors    - LLDP-discovered neighbors on topology links
show running-config    - the generated setup.sh this node booted with
show log                - startup / config-apply log
```

Works both interactively (`ssh atlas@<ip>`) and as a one-shot command
(`ssh atlas@<ip> "show firewall rules"`), same as `vtysh`. It's
read-only by design: anything that isn't one of the commands above is
rejected by `fwsh` itself before it ever reaches a shell - confirmed
directly, `doas /usr/sbin/iptables -F FORWARD` typed at the prompt just
gets `% Unknown command`. The one command that does need root (viewing
live netfilter counters requires it, even just to *list* them) is
scoped to a single exact invocation via `/etc/doas.conf`'s `args`
clause, not a general privilege grant - there's no `sudo`, no root
password, and no way to reach an unrestricted shell from this account.

## Switch show-command CLI

`ssh atlas@<sw-mgmt-ip>` drops into `swsh`
(`docker/switch-atlaslab/swsh`) - the same idea, scoped to a pure L2
bridge:

```
show version            - image/OS identity (includes hostname)
show hostname            - this node's hostname
show interfaces         - bridge port status (bridge link show)
show mac-address-table  - learned MAC addresses (bridge fdb show)
show lldp neighbors     - LLDP-discovered devices on this switch's ports
show ip interface       - br0/eth0 addressing (management only - the
                           switch has no data-plane IP of its own)
show log                 - port-enslavement / startup log
```

Unlike `fwsh`, none of this needs a `doas` rule at all - `bridge`/`ip`
link and fdb queries are unprivileged reads on this image (confirmed
directly: no "Permission denied" the way `iptables -L` needs root even
just to list rules), so `swsh` is pure convenience wrapping, not a
privilege boundary.

## LLDP on every device

All three images run `lldpd` (restricted to `eth1-9`, same rationale as
on the FRR nodes - see [docs/atlas-integration.md](../../docs/atlas-integration.md#lldp)),
so every device in this lab - router, firewall, switch - is
LLDP-discoverable. The switch consumes LLDP on its ports the way a real
managed switch does (a kernel bridge never floods link-local
`01:80:c2:00:00:0e` frames), so discovered adjacency matches physical
wiring exactly - verified live: `mumbai-sw1` reports `mumbai-core`/
`mumbai-access1`/`mumbai-server` on its three ports, and those devices
see *the switch* as their neighbor, not each other; `mumbai-fw` reports
`mumbai-edge` on its outside leg and `mumbai-core` on its inside leg.

## Deploy and test

```bash
make deploy LAB=07-multi-city
# allow 60-90s for per-site OSPF + inter-city eBGP convergence
make test   LAB=07-multi-city
make inspect LAB=07-multi-city
make diagnostics LAB=07-multi-city
make destroy LAB=07-multi-city YES=1
```

`scripts/deploy-lab.sh` retries automatically (destroy + redeploy, up
to 3 attempts) if containerlab reports a deploy failure - see "Known
limitations, honestly" for why that's built in for this lab
specifically.

## Known limitations, honestly

- **L2 switches don't use containerlab's `bridge` kind.** That kind
  needs a Linux bridge to already exist on the *host*, which needs
  root - not available in this environment (the WSL user has
  docker-group access, not host `CAP_NET_ADMIN`; confirmed by direct
  testing: `ip link add ... type bridge` on the host fails with
  "Operation not permitted"). `atlaslab/switch` instead builds a real
  kernel bridge *inside its own container*, using the same `NET_ADMIN`
  capability every AtlasLab node already gets - genuine MAC
  learning/forwarding, just implemented one layer down from where
  containerlab's built-in kind would put it.
- **sw1 and sw2 are not linked to each other.** Each is an independent
  L2 segment with its own uplink to `core`. Linking them together
  *and* dual-homing `server` to both (as the topology does) would
  create an actual L2 loop with no STP running to break it. Two
  independent segments still give `core` two physically distinct paths
  into the access layer without that risk.
- **containerlab link-creation race with fast-starting images.**
  `atlaslab/firewall` and `atlaslab/switch` are much smaller/faster to
  start than `atlaslab/frr`. containerlab schedules each node's
  link-creation independently of its peers' readiness, so a firewall
  node can reach its own link-creation stage before its FRR-image
  edge/core neighbor even exists as a container yet - which
  containerlab handles by failing that link ("Link not found") rather
  than waiting, confirmed via `containerlab deploy --log-level debug`
  timestamps. `startup-delay: 35` on every firewall/switch node
  mitigates this considerably; `scripts/deploy-lab.sh`'s automatic
  retry (destroy + redeploy, up to 3 attempts) is the safety net for
  whatever variance the delay doesn't fully absorb. See
  [docs/troubleshooting.md](../../docs/troubleshooting.md) for the full
  diagnostic trail.
- **`docker logs` shows nothing for firewall/switch containers.**
  Both entrypoints log to a file inside the container
  (`/var/log/atlaslab/*.log`) instead of stdout - `docker exec <node>
  cat /var/log/atlaslab/*.log` (or `make diagnostics`, which collects
  it) is the way to see their startup/config-apply history.
- **No SNMP, still.** Same reasoning as `06-atlas-demo` - FRR's SNMP
  support is a compile-time option the published image isn't built
  with. Unchanged by this lab.
