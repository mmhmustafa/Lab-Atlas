# Routing Design

This document covers the routing protocol design used across the labs,
focused on 06-atlas-demo (the others are simpler subsets of the same
patterns - see [docs/architecture.md](architecture.md)).

## OSPF

- Single area, `0.0.0.0`, spanning every campus router (edge, core,
  dist, access, server-edge) - 14 routers in 06-atlas-demo. ISPs and
  branches are **not** OSPF speakers.
- Router IDs are always the router's loopback address, set explicitly
  (`ospf router-id <loopback>`) rather than left to auto-selection - this
  keeps them deterministic and independent of interface bring-up order.
- `passive-interface default` plus an explicit `no passive-interface`
  per real link: every interface is passive unless it's a genuine
  point-to-point link to another OSPF speaker. The loopback (and its LAN
  stub secondary address) stay passive - the network is still advertised
  via a `network ... area 0.0.0.0` statement, but no hello is ever sent
  out `lo`.
- `network` statements (not per-interface `ip ospf area`) are used
  throughout, specifically because they pick up **all** addresses on an
  interface, including the LAN-stub secondary address on `lo` for
  access/server-edge/branch-adjacent routers. Per-interface `ip ospf
  area` only binds to the interface's primary address unless a specific
  address is named, which is more fragile for this design.
- Default OSPF cost (reference-bandwidth 100, cost 10 per veth link) is
  left untouched everywhere. Every redundant pair of links in the
  topology is genuinely equal-cost, so ECMP is a natural consequence of
  the topology rather than something that needed explicit tuning.

## BGP

### iBGP

- `edge1`, `edge2`, `core1`, `core2` form a full iBGP mesh (AS 65000),
  loopback-to-loopback, `update-source lo`, `next-hop-self` on every
  session, `maximum-paths ibgp 4` for ECMP across equal-cost iBGP paths.
- `dist*`, `access*`, `server-edge*` are **not** BGP speakers. They get
  reachability to branch/internet prefixes purely through OSPF
  redistribution at the edge (below) - a deliberate, realistic design
  choice (BGP confined to the WAN edge), not a limitation.

### eBGP

- `edge1`/`edge2` &harr; `isp1`/`isp2`: four sessions, directly connected,
  AS 65000 &harr; AS 64500/64501.
- `edge1`/`edge2` &harr; `branch1`-`branch4`: eight sessions, directly
  connected, AS 65000 &harr; AS 65001-65004.
- Every eBGP session sets `no bgp ebgp-requires-policy`. FRR 8+ silently
  filters all routes on an eBGP session with no attached route-map
  unless this is set - a well-known operational gotcha. The one place an
  outbound policy is genuinely needed (edge &rarr; ISP, below) still has an
  explicit route-map; this knob just stops FRR from *requiring* one on
  every other session in a lab whose purpose is protocol correctness
  testing, not internet-grade route hygiene.

### Redistribution, and the loop it caused

Both `edge1` and `edge2` redistribute in both directions:

- `redistribute bgp` under `router ospf` - so campus routers learn
  ISP/branch-originated prefixes as OSPF externals.
- `redistribute ospf route-map RM-OSPF-TO-BGP` under `router bgp` - so
  ISPs and branches learn campus loopbacks/LANs.

Doing this naively (unfiltered `redistribute ospf` into BGP) creates a
feedback loop: a prefix edge1 learns via genuine eBGP from isp1 gets
redistributed into OSPF as a Type-5 external, floods to edge2, and edge2
then redistributes *that OSPF route* back into its own BGP table - now
as a route with an empty AS-PATH, which looks more attractive to BGP
best-path selection than the genuine eBGP-learned route with a real
AS-PATH. The two routers then flap between "genuine eBGP route" and
"round-tripped-through-OSPF route" for the same prefix, and the OSPF
nexthop for it never stabilizes.

This is exactly what happened during initial validation of
06-atlas-demo (see [docs/troubleshooting.md](troubleshooting.md) for the
full diagnostic story) and is fixed with one route-map:

```
route-map RM-OSPF-TO-BGP permit 10
 match route-type internal
```

applied to `redistribute ospf` at edge1/edge2. `match route-type
internal` passes only genuine OSPF intra-area routes (campus loopbacks
and LANs) into BGP, and excludes OSPF externals - which is exactly what
breaks the loop, since a route that came from BGP-into-OSPF can never
be picked back up by this filter on the way out.

### Preventing Atlas from becoming a transit AS

A second, unrelated route-map, `RM-TO-ISP`, is applied outbound on the
edge&rarr;ISP eBGP sessions:

```
ip prefix-list PL-ATLAS-LOOPBACKS seq 5 permit 10.255.0.0/24 le 32
ip prefix-list PL-ATLAS-LANS seq 5 permit 172.16.0.0/20 le 24
route-map RM-TO-ISP permit 10
 match ip address prefix-list PL-ATLAS-LOOPBACKS
route-map RM-TO-ISP permit 20
 match ip address prefix-list PL-ATLAS-LANS
```

Only campus loopbacks and campus LAN stubs are ever advertised to an
ISP. Branch loopbacks/LANs and the *other* ISP's TEST-NET prefix are
implicitly denied - without this, Atlas would inadvertently offer
isp1&harr;isp2 transit (re-advertising isp2's routes to isp1) and leak
private branch-site addressing to the internet.

## Router IDs

Both OSPF and BGP router-id are always set explicitly to the device's
loopback address - never left to auto-select from the lowest/highest
interface IP. This is what makes the whole design deterministic: router
IDs don't change based on interface bring-up order or which link comes
up first during convergence.

## ECMP

- **OSPF**: automatic given equal-cost redundant links; no `maximum-paths`
  tuning needed for intra-area routes.
- **iBGP**: `maximum-paths ibgp 4` at edge1/edge2/core1/core2 - without
  this, FRR by default only installs one iBGP path even when multiple
  equal-cost ones exist.
- **eBGP**: not applicable in this design - branches and ISPs are each
  single-AS-path length from a given edge router, so there's no
  equal-length-different-AS-PATH scenario to multipath across.
