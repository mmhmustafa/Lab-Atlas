# 06-atlas-demo

The flagship lab: 20 FRRouting routers in a fully redundant enterprise
network, purpose-built for Atlas discovery and regression testing. See
[docs/architecture.md](../../docs/architecture.md) for the full topology
diagram and design rationale, [docs/addressing.md](../../docs/addressing.md)
for every subnet, and [docs/routing.md](../../docs/routing.md) for the
OSPF/BGP design (including the redistribution-loop fix that shaped it).

**This lab is generated, not hand-written.** `inventory/devices.yaml` is
the source of truth; `configs/06-atlas-demo/` and this directory's
`lab.clab.yml` carry a "generated, do not edit by hand" header. To
change the topology or addressing, edit the inventory and re-run:

```bash
python3 scripts/generate-configs.py --lab 06-atlas-demo
# or: make generate
```

## At a glance

- 20 nodes: 2 ISPs, 2 edge, 2 core, 4 distribution, 4 access, 2
  server-edge, 4 branch.
- 41 point-to-point links, every layer boundary dual-homed.
- OSPF area 0 across the 14 campus routers.
- iBGP full mesh (AS 65000) among edge1/edge2/core1/core2.
- eBGP to 2 ISPs (AS 64500/64501) and 4 branches (AS 65001-65004).
- Bidirectional, loop-safe OSPF&harr;BGP redistribution at the edge.
- LLDP on every topology-facing interface.

## Deploy and test

```bash
make deploy LAB=06-atlas-demo
# allow 60-90s for full OSPF + iBGP + eBGP + redistribution convergence
make test   LAB=06-atlas-demo
make inspect LAB=06-atlas-demo
make diagnostics LAB=06-atlas-demo
make destroy LAB=06-atlas-demo YES=1
```

## Expected test results

- OSPF: 14/14 campus routers, all adjacencies `Full`.
- BGP: 10/10 BGP-speaking routers, all sessions `Established`.
- Reachability: 362/380 loopback pairs (100% of everything not listed
  in `expected-unreachable.txt`, which documents the 18 pairs that are
  unreachable **by design** - isp1&harr;isp2, and isp&harr;branch, per the
  route-map policy in [docs/routing.md](../../docs/routing.md)).

These numbers were confirmed identical across a full
destroy-then-redeploy cycle (see [docs/testing.md](../../docs/testing.md)).
