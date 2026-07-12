# AtlasLab

AtlasLab is a reusable, containerlab-based network testing platform for
**Atlas**: a suite of FRRouting topologies, from a two-router smoke test up
to a 20-router redundant enterprise network, built to give Atlas real
OSPF, BGP, redistribution, ECMP, and LLDP behavior to discover and
regression-test against.

Everything is source-controlled and reproducible: topologies are declared
in `inventory/devices.yaml`, rendered into FRR configs and containerlab
topology files by `scripts/generate-configs.py`, deployed and torn down
with a small set of operational scripts, and validated by an automated
OSPF/BGP/reachability test suite.

## Repository layout

```
docs/         Architecture, addressing, routing, deployment, testing,
              troubleshooting, and Atlas-integration reference docs
scripts/      Operational scripts (deploy/destroy/inspect/test/diagnose)
              and the FRR config generator
inventory/    devices.yaml - single source of truth for the 06-atlas-demo
              20-router topology
templates/    Jinja2 templates used by the config generator
configs/      Rendered per-node FRR configs (daemons/frr.conf/vtysh.conf),
              one subdirectory per lab
docker/       Dockerfile for the atlaslab/frr image (frrouting/frr + lldpd)
labs/         Six containerlab topologies, 01-basic through 06-atlas-demo
captures/     Packet captures produced ad hoc during troubleshooting
logs/         Script logs and collect-diagnostics.sh bundles (gitignored)
```

## Labs

| Lab | Nodes | Protocols | Purpose |
|---|---|---|---|
| [01-basic](labs/01-basic) | 2 | OSPF | Smoke test: two routers, one link, one adjacency |
| [02-ospf](labs/02-ospf) | 4 | OSPF | Redundant ring + diagonal, OSPF fundamentals |
| [03-bgp](labs/03-bgp) | 3 | eBGP | Three-AS chain, AS-path propagation through a transit AS |
| [04-enterprise](labs/04-enterprise) | 9 | OSPF, iBGP, eBGP | Mid-size edge/core/dist/access pattern with one ISP |
| [05-multivendor](labs/05-multivendor) | 3 | eBGP | Interop-test scaffold (see honesty note in its README) |
| [06-atlas-demo](labs/06-atlas-demo) | 20 | OSPF, iBGP, eBGP, redistribution | Flagship redundant enterprise network |

06-atlas-demo is the primary target for Atlas development and regression
testing; see [docs/architecture.md](docs/architecture.md) for its design.

## Quick start

```bash
make verify                    # confirm docker/containerlab/images are ready
make deploy LAB=06-atlas-demo   # deploy a lab (defaults to 06-atlas-demo)
make test   LAB=06-atlas-demo   # OSPF/BGP/reachability regression suite
make inspect LAB=06-atlas-demo  # current state: containers, interfaces
make diagnostics LAB=06-atlas-demo  # full show-command + log bundle
make destroy LAB=06-atlas-demo YES=1
```

Every `make` target is a thin wrapper around a script in `scripts/` - see
[docs/deployment.md](docs/deployment.md) for direct script usage, flags,
and exit codes.

## Requirements

Already provided in this environment and not reinstalled by anything
here: WSL2 + Ubuntu, Docker Engine, Containerlab 0.77. `make verify`
(`scripts/verify-environment.sh`) checks all of this plus Python
(PyYAML + Jinja2, used by the config generator) and builds the
`atlaslab/frr` image on first run if it isn't present locally.

## Documentation

- [docs/architecture.md](docs/architecture.md) - topology design and redundancy model
- [docs/addressing.md](docs/addressing.md) - full IP addressing plan
- [docs/routing.md](docs/routing.md) - OSPF/BGP design, redistribution, ECMP
- [docs/deployment.md](docs/deployment.md) - deploying and destroying labs
- [docs/testing.md](docs/testing.md) - the regression test suite
- [docs/troubleshooting.md](docs/troubleshooting.md) - known gotchas and how they were diagnosed
- [docs/atlas-integration.md](docs/atlas-integration.md) - what Atlas can discover here
