# AtlasLab

AtlasLab is a reusable, containerlab-based network testing platform for
**Atlas**: a suite of FRRouting topologies, from a two-router smoke test
up to a 20-router redundant enterprise network and a 4-site,
firewall-and-switch-equipped multi-city WAN, built to give Atlas real
OSPF, BGP, redistribution, ECMP, LLDP, stateful firewalling, and L2
switching behavior to discover and regression-test against.

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
              and the config generators
inventory/    devices.yaml (06-atlas-demo) and multi-city.yaml
              (07-multi-city) - single sources of truth for their topologies
templates/    Jinja2 templates used by the config generators
configs/      Rendered per-node configs (FRR daemons/frr.conf/vtysh.conf,
              or firewall setup.sh), one subdirectory per lab
docker/       Dockerfiles for the atlaslab/frr, atlaslab/firewall, and
              atlaslab/switch images
labs/         Seven containerlab topologies, 01-basic through 07-multi-city
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
| [07-multi-city](labs/07-multi-city) | 32 | OSPF (x4, independent), eBGP full mesh | Four-site WAN (Mumbai/Delhi/Hyderabad/Chennai), each with a stateful firewall and L2 switching |

06-atlas-demo is the primary target for Atlas development and regression
testing; see [docs/architecture.md](docs/architecture.md) for its design.
07-multi-city is the primary target for multi-site/firewall/L2 scenarios;
see [labs/07-multi-city/README.md](labs/07-multi-city/README.md).

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

Every node is also reachable over SSH for real router-style management
access - `ssh atlas@<mgmt-ip>` (password `AtlasLab123!`, IPs from
`make inspect`) drops straight into the FRR CLI. See
[docs/deployment.md](docs/deployment.md#ssh-management-access).

## Requirements

Already provided in this environment and not reinstalled by anything
here: WSL2 + Ubuntu, Docker Engine, Containerlab 0.77. `make verify`
(`scripts/verify-environment.sh`) checks all of this plus Python
(PyYAML + Jinja2, used by the config generators), `ssh`/`setsid`, and
(re)builds the `atlaslab/frr` image (frrouting/frr + lldpd + sshd, see
[docs/atlas-integration.md](docs/atlas-integration.md)) every run.
`make verify` also builds `atlaslab/firewall` and `atlaslab/switch`
(used only by `07-multi-city`).

## Documentation

- [docs/architecture.md](docs/architecture.md) - topology design and redundancy model
- [docs/addressing.md](docs/addressing.md) - full IP addressing plan
- [docs/routing.md](docs/routing.md) - OSPF/BGP design, redistribution, ECMP
- [docs/deployment.md](docs/deployment.md) - deploying and destroying labs
- [docs/testing.md](docs/testing.md) - the regression test suite
- [docs/troubleshooting.md](docs/troubleshooting.md) - known gotchas and how they were diagnosed
- [docs/atlas-integration.md](docs/atlas-integration.md) - what Atlas can discover here
