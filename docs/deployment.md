# Deployment

## Prerequisites

Already present in this environment (see the repo's setup notes) and
not touched by anything here: WSL2 + Ubuntu, Docker Engine, Containerlab
0.77. Run `make verify` (`scripts/verify-environment.sh`) before first
use - it checks all of the above plus Python 3 with PyYAML and Jinja2
(used by `scripts/generate-configs.py`), `ssh`/`setsid` (used by the SSH
verification helpers), and (re)builds the `atlaslab/frr` image
(frrouting/frr + lldpd + sshd + the documented `atlas` management user,
see [docs/atlas-integration.md](atlas-integration.md)) every run -
Docker's own layer cache makes a no-op rebuild fast, and always
rebuilding is what catches a stale image after a Dockerfile change
instead of silently reusing one built before it.

Containerlab needs to run as a user who can talk to the Docker socket
without `sudo` - this environment's WSL user is already in the `docker`
group, and `scripts/verify-environment.sh` checks for that. If
`containerlab deploy` is run under `sudo` in a **non-interactive**
shell, it hangs on a password prompt rather than failing cleanly; don't
use `sudo` for any of these scripts.

## Deploying a lab

```bash
make deploy LAB=06-atlas-demo
# or directly:
scripts/deploy-lab.sh 06-atlas-demo
```

This runs `containerlab deploy` against `labs/<lab>/lab.clab.yml`, then
polls `docker ps` until every container in the lab reports `running`
(up to 90s). Deployment itself finishes in a few seconds for any of
these labs; **protocol convergence takes longer** and isn't waited for
by `deploy-lab.sh` (see the convergence-timing note below).

## Waiting for convergence

OSPF neighbors on a point-to-point veth link (Linux's default interface
type is `broadcast`, which triggers a DR/BDR election even on a
2-router segment) can take up to the OSPF `RouterDeadInterval`
(40s default) to reach `Full` on first bring-up, if the wait timer
hasn't already been satisfied by an existing DR/BDR. In practice:

- Small labs (01-basic, 02-ospf, 03-bgp, 05-multivendor): full
  convergence in under ~20s.
- 04-enterprise (9 nodes): under ~45s.
- 06-atlas-demo (20 nodes, OSPF + iBGP + eBGP + redistribution): allow a
  full 60-90s before running `make test` - BGP sessions only establish
  after their OSPF-reachable loopback peers converge, and there's a
  second wave of convergence once redistributed routes propagate.

`scripts/test-connectivity.sh` doesn't hide this - if you run it too
early, you'll see real (temporary) OSPF/BGP failures, not a bug. Just
wait and re-run.

## SSH management access

Every node runs `sshd`, reachable over its containerlab management IP
(the same address `containerlab inspect` / `make inspect` shows):

```bash
make inspect LAB=04-enterprise           # lists every node's mgmt IP
ssh atlas@<mgmt-ip>                      # password: AtlasLab123!
```

The `atlas` account's login shell is `vtysh` itself, so this drops
straight into the FRR CLI - `ssh atlas@<mgmt-ip> "show ip ospf
neighbor"` works as a one-shot command too. Host keys are generated
fresh per container at startup (not baked into the image, so every
node gets its own), which means a new key every redeploy; connect with
`-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null` rather
than fighting `~/.ssh/known_hosts` churn on a lab that gets torn down
and rebuilt constantly. See
[docs/atlas-integration.md](atlas-integration.md#optional-services) for
the full credential/design rationale, and
[docs/troubleshooting.md](troubleshooting.md) for the bugs hit (and
fixed) building this.

`make verify` builds `atlaslab/frr` and checks it has `sshd` + the
`atlas` account; `make test` SSH-logs into every deployed node as part
of the regression suite.

## Inspecting a running lab

```bash
make inspect LAB=06-atlas-demo
```

Prints containerlab's own inspect table (container state, image, mgmt
IPs) plus a per-node interface up/down summary read directly from each
container.

## Destroying a lab

```bash
make destroy LAB=06-atlas-demo YES=1     # non-interactive
scripts/destroy-lab.sh 06-atlas-demo     # prompts for confirmation
```

This runs `containerlab destroy --cleanup`, which also removes the
generated `clab-<name>/` runtime directory so the lab folder returns to
exactly its source-controlled state (see `.gitignore`).

**Never use `docker restart` / `docker stop` / `docker kill` directly on
a containerlab-managed container.** Containerlab attaches the topology's
veth interfaces to the container's network namespace *outside* of
Docker's normal container lifecycle; a plain `docker restart` recreates
the namespace and permanently orphans those interfaces (the container
comes back up with only `lo` and the management `eth0` - every topology
link is gone). This was hit during development (see
[docs/troubleshooting.md](troubleshooting.md)) and the fix is always the
same: `containerlab destroy` + `containerlab deploy` (i.e.
`scripts/destroy-lab.sh` + `scripts/deploy-lab.sh`, or `make redeploy`),
never a container-level restart.

## Reproducibility

```bash
make redeploy LAB=06-atlas-demo
```

Destroys and redeploys in one step (always non-interactive - it's meant
for exactly this repeatability check). This was run against
06-atlas-demo as part of building this repository and produced identical
convergence and test results both times - see
[docs/testing.md](testing.md) for the numbers.

## Regenerating 06-atlas-demo's configs

06-atlas-demo's per-node configs and `lab.clab.yml` are generated, not
hand-written:

```bash
python3 scripts/generate-configs.py --lab 06-atlas-demo
# or: make generate
```

Edit `inventory/devices.yaml` (the topology/addressing source of truth)
and re-run the generator rather than hand-editing anything under
`configs/06-atlas-demo/` or `labs/06-atlas-demo/lab.clab.yml` directly -
those files carry a "generated, do not edit by hand" header for exactly
this reason. The other five labs are small enough to be hand-written
directly under `configs/<lab>/` and `labs/<lab>/lab.clab.yml`.
