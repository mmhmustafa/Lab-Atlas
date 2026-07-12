# Troubleshooting

Known issues encountered while building and validating this repository,
kept here so they don't get rediscovered the hard way a second time.

## "Everything shows converged but pings still fail"

**Symptom:** OSPF adjacencies all `Full`, BGP sessions all
`Established`, but a chunk of loopback-to-loopback pings between
multi-hop nodes fail with 100% loss.

**Cause:** the ping wasn't sourced from the loopback. Without an
explicit source, the kernel picks the egress interface's own address -
often a point-to-point transit `/30` address, which is deliberately
never advertised beyond the OSPF domain. The far side has no route back
to it, so the reply is silently dropped (or, worse, sent out the
container's default route via the containerlab management network and
lost there).

**Fix:** always source connectivity tests from the loopback:
`ping -I <loopback-ip> <target>`, never bare `ping <target>` from a
router. `scripts/test-connectivity.sh` does this; if you're testing
manually with `docker exec <node> ping ...`, do the same.

**How this was actually diagnosed** (for the next time something looks
like this): the investigation initially suspected OSPF ECMP instability
across the two ASBRs (edge1/edge2 both redistributing the same BGP
routes), since `show ip route` and `ip route get` sometimes showed
different next-hops for the same prefix. That turned out to be a red
herring - forcing a single, unambiguous path (temporarily removing one
ASBR, shutting one interface) didn't fix the pings either. `tcpdump`
inside the containers (`apk add --no-cache tcpdump` - the image is
Alpine-based and has network access) confirmed requests were arriving
at the destination and `/proc/net/snmp`'s `OutEchoReps` confirmed a
reply was being generated - but the reply's *destination* was the
source router's transit-link address, which had no route back from the
far side. Sourcing the original ping from the loopback instead
(`ping -I <loopback> ...`) immediately fixed it.

## Mutual OSPF&harr;BGP redistribution loop

**Symptom:** BGP sessions flapping (repeatedly re-establishing), and/or
`show ip route <prefix>` and `ip route get <prefix>` disagreeing about
which next-hop is active for the same destination.

**Cause:** redistributing BGP into OSPF *and* OSPF into BGP on the same
router(s), unfiltered, creates a feedback loop - a route learned via
genuine eBGP gets redistributed into OSPF, floods to the other ASBR, and
gets redistributed *back* into BGP there with an empty AS-PATH, which
then out-competes the genuine eBGP route in path selection. See
[docs/routing.md](routing.md#redistribution-and-the-loop-it-caused) for
the full mechanics and the fix (`match route-type internal` on the
OSPF-into-BGP redistribution).

**Lesson for future topology changes:** any router that redistributes
in both directions between two protocols needs a loop-breaker (a route
tag or, as here, a route-type filter) before it's deployed, not after
something looks unstable.

## `docker restart` destroys a containerlab node's topology links

**Symptom:** after `docker restart <container>` (not
`containerlab destroy`/`deploy`), the node comes back up with only `lo`
and the management `eth0` interface - every topology-facing interface
(`eth1`+) is gone, and OSPF/BGP show zero neighbors.

**Cause:** containerlab attaches topology veth interfaces to a
container's network namespace *outside* Docker's normal lifecycle
management. `docker restart` recreates the namespace, orphaning those
interfaces permanently - they don't come back.

**Fix:** never use `docker restart`/`stop`/`kill` on a containerlab node.
Use `scripts/destroy-lab.sh` + `scripts/deploy-lab.sh` (or
`make redeploy`) to get a clean state instead.

## `sudo containerlab ...` hangs forever

**Symptom:** a `sudo containerlab deploy` (or similar) command in a
non-interactive script/session just hangs with no output.

**Cause:** `sudo` is prompting for a password on a TTY that isn't there
to answer it.

**Fix:** don't use `sudo` for containerlab/docker commands in this
environment - the WSL user is already in the `docker` group (and a
`clab_admins` group), so none of these commands need elevation.
`scripts/verify-environment.sh` checks for docker-group membership for
exactly this reason.

## OSPF adjacencies sit at `2-Way`/`Init` for up to ~40s after deploy

**Symptom:** right after `containerlab deploy`, `show ip ospf neighbor`
shows `2-Way/DROther` or `Init` on every link, not `Full`.

**Cause:** not a bug - a veth link between exactly two routers still
uses OSPF's default `broadcast` network type, which runs a DR/BDR
election with a wait timer equal to the `RouterDeadInterval` (40s
default) before the first election finalizes. This is purely a
convergence-timing artifact.

**Fix:** wait. See [docs/deployment.md](deployment.md#waiting-for-convergence)
for expected convergence times per lab size.

## `Configuration file[/etc/frr/frr.conf] processing failure: 13` (fixed)

**Symptom, when using the base `frrouting/frr` image directly:** visible
in `docker logs <container>` on every node, immediately after startup:
`can't open logfile /var/log/frr/frr.log` followed by a
processing-failure message.

**Cause:** the `log file /var/log/frr/frr.log informational` directive
in every generated `frr.conf` fails because `/var/log/frr/` doesn't
exist with the right ownership in the base image at the moment
`vtysh -b` first applies the integrated config.

**Impact when unfixed:** cosmetic only - `vtysh -b` continues past the
one failing line and applies the rest of the file (verified via `show
running-config` immediately after this message: every
interface/OSPF/BGP block present and correct). But FRR daemon logs
never get captured to a file, which is a real gap for
`collect-diagnostics.sh`-style investigation later.

**Fix:** the `atlaslab/frr` image (`docker/frr-atlaslab/Dockerfile`)
pre-creates `/var/log/frr` with `frr:frr` ownership at build time, which
is all the directive actually needed. Every lab uses this image, so
`/var/log/frr/frr.log` is populated on every node from first boot.
