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

## Getting started from scratch

The lab needs a **Linux environment** - native Linux, or Windows with
WSL2 + Ubuntu (which is what this repo was built and validated on).
macOS is untested.

**1. One-time prerequisites:**

```bash
# Docker Engine - https://docs.docker.com/engine/install/
# then make sure your user can run docker without sudo:
sudo usermod -aG docker $USER     # log out and back in afterwards

# containerlab (this repo was validated against 0.77):
bash -c "$(curl -sL https://get.containerlab.dev)"

# Python (for the config generators) and basics:
sudo apt install -y python3 python3-yaml python3-jinja2 git make openssh-client
```

**2. Clone and verify:**

```bash
git clone https://github.com/mmhmustafa/Lab-Atlas.git
cd Lab-Atlas
make verify
```

`make verify` (`scripts/verify-environment.sh`) does the heavy lifting:
it checks Docker/containerlab/Python/`ssh`/`setsid`, pulls
`frrouting/frr` if it's missing, and builds all three custom images -
`atlaslab/frr` (frrouting/frr + lldpd + sshd), `atlaslab/firewall`, and
`atlaslab/switch` - so there is nothing to build by hand. It rebuilds
them on every run (Docker's layer cache makes a no-op rebuild fast), so
it also picks up any Dockerfile change automatically.

**3. Deploy, test, use, tear down:**

```bash
make list-labs                      # the seven available labs
make deploy LAB=07-multi-city       # or LAB=06-atlas-demo, etc.
# allow 60-90s for OSPF/BGP convergence on the two big labs, then:
make test   LAB=07-multi-city       # OSPF/BGP/SSH/reachability suite
make inspect LAB=07-multi-city      # containers, interfaces, mgmt IPs
make diagnostics LAB=07-multi-city  # full show-command + log bundle
make destroy LAB=07-multi-city YES=1
```

Every `make` target is a thin wrapper around a script in `scripts/` - see
[docs/deployment.md](docs/deployment.md) for direct script usage, flags,
and exit codes.

Every node is also reachable over SSH for real router-style management
access - `ssh atlas@<mgmt-ip>` (password `AtlasLab123!`, IPs from
`make inspect`). Routers drop into `vtysh`, firewalls into `fwsh`, and
switches into `swsh` - all with `show` commands. See
[docs/deployment.md](docs/deployment.md#ssh-management-access). (The
credential is deliberately static and public: these labs live on a
local Docker bridge on your own machine and are torn down constantly -
don't expose the management network beyond the host.)

**4. Reaching the nodes from your host OS:**

- **Native Linux: nothing to do.** The management network
  (`172.20.20.0/24`) is a Docker bridge on the host itself, so every
  node's management IP is directly reachable the moment the lab is
  deployed - `ssh atlas@<mgmt-ip>` from any terminal on the machine.
- **Windows + WSL2:** from *inside WSL*, same story - it just works.
  But Windows itself has no route to that subnet (the bridge lives
  inside the WSL VM). To SSH from Windows (PuTTY, Windows Terminal, a
  GUI tool like Atlas running on the host), add the route:

```powershell
# from an elevated (Administrator) PowerShell:
.\scripts\configure-windows-route.ps1
```

Re-run it after every WSL restart - WSL gets a new IP each time, and
the route is deliberately non-persistent (a persistent route would go
stale for the same reason). The route only exists on your own machine;
it does not expose the lab to your LAN.

## Documentation

- [docs/architecture.md](docs/architecture.md) - topology design and redundancy model
- [docs/addressing.md](docs/addressing.md) - full IP addressing plan
- [docs/routing.md](docs/routing.md) - OSPF/BGP design, redistribution, ECMP
- [docs/deployment.md](docs/deployment.md) - deploying and destroying labs
- [docs/testing.md](docs/testing.md) - the regression test suite
- [docs/troubleshooting.md](docs/troubleshooting.md) - known gotchas and how they were diagnosed
- [docs/atlas-integration.md](docs/atlas-integration.md) - what Atlas can discover here
