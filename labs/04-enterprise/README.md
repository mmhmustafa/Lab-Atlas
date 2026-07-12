# 04-enterprise

A 9-router edge/core/dist/access pattern with one ISP attached -
structurally the same layered, redundant design as 06-atlas-demo's
campus, at a scale small enough to read end to end in one sitting.
Exercises OSPF + iBGP + eBGP + bidirectional redistribution together,
which 02-ospf and 03-bgp deliberately don't.

## Topology

```
                 isp1 (AS 64600)
                  /          \
              edge1 ======== edge2      } AS 65100, iBGP mesh
              /   \          /   \      } (edge1,edge2,core1,core2)
             /     +--------+     \
          core1 ================ core2
           /  \                  /  \
       dist1 -- (core-dual-homed) -- dist2
        /  \                        /  \
   access1  access2 ============ access1 access2
```

(dist1 and dist2 are each dual-homed to both core1 and core2; access1
and access2 are each dual-homed to both dist1 and dist2 - see
`labs/04-enterprise/lab.clab.yml` for the exact link list.)

| Node | Role | AS |
|---|---|---|
| isp1 | eBGP only | 64600 |
| edge1, edge2 | OSPF + iBGP + eBGP (ASBR) | 65100 |
| core1, core2 | OSPF + iBGP | 65100 |
| dist1, dist2 | OSPF only | - |
| access1, access2 | OSPF only, LAN stub | - |

Same redistribution design as 06-atlas-demo: `redistribute bgp` into
OSPF at edge1/edge2 gives dist/access reachability to isp1; `redistribute
ospf route-map RM-OSPF-TO-BGP` (route-type internal only) back into BGP
gives isp1 reachability to campus loopbacks/LANs, without looping - see
[docs/routing.md](../../docs/routing.md).

## Deploy and test

```bash
make deploy LAB=04-enterprise
make test   LAB=04-enterprise
make destroy LAB=04-enterprise YES=1
```

Convergence: allow ~45s before testing.
