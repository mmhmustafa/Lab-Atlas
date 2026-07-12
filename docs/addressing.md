# Addressing Plan

This is the canonical addressing reference. `inventory/devices.yaml` is
the machine-readable source of truth for 06-atlas-demo; this document is
the human-readable explanation of the same plan, plus the (smaller,
independent) ranges used by the other five labs.

## 06-atlas-demo (20 routers)

### Allocation summary

| Range | Purpose |
|---|---|
| `10.255.0.0/24` | Campus router loopbacks (edge, core, dist, access, server-edge) |
| `10.255.1.0/24` | Branch site loopbacks |
| `10.10.0.0/16` | Internal Atlas point-to-point links, one `/30` per link |
| `172.16.0.0/20` | Campus site/server LAN stubs (access1-4, server-edge1-2) |
| `172.16.100.0/22` | Branch site LAN stubs (branch1-4) - deliberately **not** advertised to the ISPs |
| `192.0.2.0/24` | ISP loopbacks and ISP&harr;edge transit links (TEST-NET-1) |

`172.16.0.0/20` and `172.16.100.0/22` are deliberately non-overlapping
and independently summarizable, which is what lets `RM-TO-ISP` (see
[docs/routing.md](routing.md)) permit one and implicitly deny the other
with a single prefix-list entry each.

### Loopbacks

| Node | Loopback | LAN stub |
|---|---|---|
| isp1 | 192.0.2.1/32 | - |
| isp2 | 192.0.2.2/32 | - |
| edge1 | 10.255.0.1/32 | - |
| edge2 | 10.255.0.2/32 | - |
| core1 | 10.255.0.11/32 | - |
| core2 | 10.255.0.12/32 | - |
| dist1 | 10.255.0.21/32 | - |
| dist2 | 10.255.0.22/32 | - |
| dist3 | 10.255.0.23/32 | - |
| dist4 | 10.255.0.24/32 | - |
| access1 | 10.255.0.31/32 | 172.16.10.0/24 |
| access2 | 10.255.0.32/32 | 172.16.11.0/24 |
| access3 | 10.255.0.33/32 | 172.16.12.0/24 |
| access4 | 10.255.0.34/32 | 172.16.13.0/24 |
| server-edge1 | 10.255.0.41/32 | 172.16.14.0/24 |
| server-edge2 | 10.255.0.42/32 | 172.16.15.0/24 |
| branch1 | 10.255.1.1/32 | 172.16.100.0/24 |
| branch2 | 10.255.1.2/32 | 172.16.101.0/24 |
| branch3 | 10.255.1.3/32 | 172.16.102.0/24 |
| branch4 | 10.255.1.4/32 | 172.16.103.0/24 |

LAN stubs are a second address on each router's `lo` interface (e.g.
access1 has both `10.255.0.31/32` and `172.16.10.1/24` on `lo`) rather
than a separate device - there are no end hosts in this lab, so the
router itself stands in for "the LAN," giving OSPF/BGP a stub network to
advertise without adding container count.

### Point-to-point links (`10.10.0.0/16`)

Each link group gets its own `/27`-ish band, with `/30` subnets assigned
in link-declaration order (see `inventory/devices.yaml`):

| Band | Link type |
|---|---|
| `10.10.1.0/30` | edge&harr;edge |
| `10.10.2.0/29` | edge&harr;core (4 links) |
| `10.10.3.0/30` | core&harr;core |
| `10.10.4.0/27` | core&harr;dist (8 links) |
| `10.10.5.0/29` | dist&harr;dist (2 links) |
| `10.10.6.0/27` | dist&harr;access (8 links) |
| `10.10.7.0/28` | core&harr;server-edge (4 links) |
| `10.10.8.0/30` | server-edge&harr;server-edge |
| `10.10.9.0/27` | edge&harr;branch (8 links) |

### ISP space (`192.0.2.0/24`)

| Subnet | Link |
|---|---|
| `192.0.2.0/29` | isp1 (`.1`) / isp2 (`.2`) loopbacks |
| `192.0.2.8/30` | isp1 &harr; edge1 |
| `192.0.2.12/30` | isp1 &harr; edge2 |
| `192.0.2.16/30` | isp2 &harr; edge1 |
| `192.0.2.20/30` | isp2 &harr; edge2 |

ISPs also originate a TEST-NET static route each, redistributed into
BGP, to simulate "the internet" without needing real external
connectivity: isp1 &rarr; `198.51.100.0/24` (TEST-NET-2), isp2 &rarr;
`203.0.113.0/24` (TEST-NET-3).

### AS numbers

| ASN | Assignment |
|---|---|
| 65000 | Atlas campus (edge1, edge2, core1, core2 - iBGP mesh) |
| 64500 | isp1 |
| 64501 | isp2 |
| 65001-65004 | branch1-4 (one ASN per site) |

## Other labs

Each lab uses an independent, non-overlapping range so multiple labs'
configs can be read side by side without confusion (labs are never
deployed simultaneously against the same containerlab management
network, but the addressing is kept distinct regardless):

| Lab | Loopbacks | Point-to-point |
|---|---|---|
| 01-basic | `10.1.255.0/24` | `10.1.12.0/30` |
| 02-ospf | `10.2.255.0/24` | `10.2.0.0/16`, banded per link |
| 03-bgp | `10.3.255.0/24` | `10.3.12.0/30`, `10.3.23.0/30` |
| 04-enterprise | `10.4.255.0/24` (+ isp1 `192.0.2.50/32`) | `10.4.0.0/16`, banded per link |
| 05-multivendor | `10.5.255.0/24` | `10.5.12.0/30`, `10.5.23.0/30`, `10.5.13.0/30` |

See each lab's `configs/<lab>/*/frr.conf` for the exact per-interface
assignments.
