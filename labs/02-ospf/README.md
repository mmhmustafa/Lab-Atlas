# 02-ospf

Four routers in a redundant ring plus one diagonal, OSPF only. No BGP -
this lab isolates OSPF fundamentals (area design, passive interfaces,
router-id, path selection over redundant links) from the added
complexity of redistribution.

## Topology

```
   r1 ---- r2
   |  \      |
   |   \     |
   |    \    |
   r4 ---- r3
```

r1&harr;r3 is a direct diagonal link in addition to the ring, giving OSPF
a choice between a 1-hop and a 2-hop path to the same destination (the
1-hop path wins on cost, demonstrating basic SPF path selection over a
redundant topology).

| Node | Loopback |
|---|---|
| r1 | 10.2.255.1/32 |
| r2 | 10.2.255.2/32 |
| r3 | 10.2.255.3/32 |
| r4 | 10.2.255.4/32 |

## Deploy and test

```bash
make deploy LAB=02-ospf
make test   LAB=02-ospf
make destroy LAB=02-ospf YES=1
```

Convergence: under ~20s. Expect 3 `Full` adjacencies on r1 and r3 (ring
+ diagonal), 2 on r2 and r4 (ring only).
