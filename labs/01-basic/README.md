# 01-basic

Two routers, one link, one OSPF adjacency. The minimum viable
containerlab + FRR deployment - used to validate the base bind-mount and
container-capability recipe (`cap-add: NET_ADMIN, NET_RAW, SYS_ADMIN` +
`net.ipv4.ip_forward=1`) that every other lab in this repo builds on.

## Topology

```
r1 ---- r2
```

| Node | Loopback | Role |
|---|---|---|
| r1 | 10.1.255.1/32 | OSPF |
| r2 | 10.1.255.2/32 | OSPF |

Link: `10.1.12.0/30` (r1=.1, r2=.2).

## Deploy and test

```bash
make deploy LAB=01-basic
make test   LAB=01-basic
make destroy LAB=01-basic YES=1
```

Convergence: under ~20s. Expect `show ip ospf neighbor` to reach
`Full/DR` and `Full/Backup` on r1 and r2 respectively.
