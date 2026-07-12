# Architecture

## 06-atlas-demo: layered enterprise design

```
                         isp1 (AS 64500)      isp2 (AS 64501)
                          |          \        /          |
                          |           \      /           |
                        edge1 ======== edge2              }  AS 65000, iBGP mesh
                        /  |  \        /  |  \            }  (edge1,edge2,core1,core2)
                       /   |   +------+   |   \
              branch1-4    \        /    /
           (eBGP, AS        core1 == core2
            65001-65004)    /  |        |  \
                          dist1 dist2  dist3 dist4
                          / \   / \     / \   / \
                    access1 access2  access3 access4
                          (OSPF-only, LAN stubs)

              core1,core2 == server-edge1 == server-edge2
                            (OSPF-only, LAN stubs)
```

(`==` / `/ \` denote redundant links - every non-leaf device is
dual-homed to the layer above it. See [docs/addressing.md](addressing.md)
for the full link inventory.)

### Layers

- **ISP** (`isp1`, `isp2`) - two independent upstream providers, each its
  own AS, each dual-homed to both edge routers. There is no link between
  the ISPs; Atlas does not provide transit between them.
- **Edge** (`edge1`, `edge2`) - the WAN boundary. Runs eBGP to both ISPs
  and to all four branches, iBGP to the core, and OSPF to the campus.
  The only ASBRs in the network (see [docs/routing.md](routing.md) for
  why that matters).
- **Core** (`core1`, `core2`) - campus backbone. iBGP mesh member, OSPF,
  no eBGP.
- **Distribution** (`dist1`-`dist4`) - OSPF only, dual-homed to both core
  routers, plus an intra-pod link between the two distribution routers
  serving the same access pair.
- **Access** (`access1`-`access4`) - OSPF only, dual-homed to a
  distribution pair, each owns a `/24` LAN stub.
- **Server Edge** (`server-edge1`, `server-edge2`) - the data-center
  edge, dual-homed to both core routers plus a direct link between the
  two, each owns a `/24` LAN stub.
- **Branch** (`branch1`-`branch4`) - simulated remote sites, each its own
  AS, dual-homed via eBGP to both edge routers, each owns a `/24` LAN
  stub.

### Why no single point of failure

Every layer boundary has two parallel links to two different upstream
devices:

- Edge routers are dual-homed to both ISPs *and* to each other.
- Core routers are dual-homed to both edge routers *and* to each other.
- Distribution routers are dual-homed to both core routers *and* to
  their sibling distribution router.
- Access routers are dual-homed to their distribution pair.
- Server-edge routers are dual-homed to both core routers *and* to each
  other.
- Branches are dual-homed to both edge routers.

Losing any single link or any single non-redundant-pair device still
leaves every node reachable. This was exercised implicitly by the
destroy/redeploy reproducibility check (see
[docs/testing.md](testing.md)) rather than as a separate link-failure
drill; re-running `make test` after manually shutting a link
(`docker exec <node> ip link set ethN down`) is the quickest way to
verify a specific failover path.

### Node and link count

20 nodes, 41 point-to-point links (see `inventory/devices.yaml` for the
exact list) - four campus layers plus ISP and branch edges, all
redundant.

## The other five labs

- **01-basic**: the minimum viable FRR-on-containerlab deployment - two
  routers, one OSPF adjacency. Used to validate the base bind-mount and
  capability recipe before anything else was built on top of it.
- **02-ospf**: a 4-router ring plus one diagonal, OSPF only. Demonstrates
  OSPF path selection with a redundant topology without any BGP
  complexity.
- **03-bgp**: three routers in a straight AS chain (r1&harr;r2&harr;r3),
  eBGP only. r2 is a transit AS; r1 and r3 only become reachable to each
  other through it, which is the cleanest way to exercise AS-path
  propagation in isolation.
- **04-enterprise**: a 9-router edge/core/dist/access pattern with one
  ISP attached - structurally the same pattern as 06-atlas-demo's
  campus, at a scale small enough to read in one sitting.
- **05-multivendor**: see its own README for the honesty note - only the
  `frrouting/frr` image is available in this environment, so this lab is
  a structural scaffold (three independently-AS'd nodes in a triangle)
  rather than a genuine multi-vendor interop test.
