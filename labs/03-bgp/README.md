# 03-bgp

Three routers in a straight AS chain, eBGP only, no OSPF. r2 sits
between r1 and r3 as a transit AS - r1 and r3 only become reachable to
each other *through* r2's eBGP re-advertisement, which is the cleanest
way to exercise AS-PATH propagation in isolation from anything else.

## Topology

```
r1 (AS 65011) ---- r2 (AS 65012) ---- r3 (AS 65013)
```

| Node | AS | Loopback |
|---|---|---|
| r1 | 65011 | 10.3.255.1/32 |
| r2 | 65012 | 10.3.255.2/32 |
| r3 | 65013 | 10.3.255.3/32 |

Links: `10.3.12.0/30` (r1&harr;r2), `10.3.23.0/30` (r2&harr;r3).

Each router advertises only its own loopback via `network`; r2
re-advertises what it learns from each side to the other automatically
(standard eBGP behavior - no explicit redistribution needed). On r3,
`show ip bgp 10.3.255.1/32` shows an AS-PATH of `65012 65011`.

## Deploy and test

```bash
make deploy LAB=03-bgp
make test   LAB=03-bgp
make destroy LAB=03-bgp YES=1
```

Convergence: under ~20s.
