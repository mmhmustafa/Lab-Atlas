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

## `sshd: Unsupported option UsePAM` (fixed)

**Symptom:** every node crash-loops (or never comes up cleanly) after
SSH support was added to the image; `docker logs <container>` shows
`/etc/ssh/sshd_config line N: Unsupported option UsePAM`, and because
`entrypoint.sh` runs under `set -e`, sshd failing to start there kills
the *entire* entrypoint before it ever reaches `exec docker-start` -
this doesn't just break SSH, it takes the whole router down.

**Cause:** Alpine's `openssh` package in this image is built without
PAM integration compiled in. The `UsePAM` directive isn't a boolean
you can turn off to work around a missing PAM stack - it's a keyword
the config parser doesn't recognize *at all* on a PAM-less sshd build,
so it's a hard parse error regardless of whether the value is `yes` or
`no`.

**Fix:** don't set `UsePAM` in `docker/frr-atlaslab/sshd_config` at
all - omit the directive entirely. Plain password auth against
`/etc/shadow` works without it. Caught now at build time, not
discovered at runtime: the Dockerfile runs `ssh-keygen -A && sshd -t`
(then deletes the throwaway keys again - see the next entry) as a `RUN`
step, so an unsupported/invalid `sshd_config` fails `docker build`
itself instead of shipping broken.

## `sshd -t` needs host keys that this image deliberately doesn't ship

**Symptom:** `docker run --rm --entrypoint sh atlaslab/frr:latest -c
"sshd -t"` fails with `sshd: no hostkeys available -- exiting`, even
though the same check passes fine during `docker build`.

**Cause:** not a bug - this image intentionally does *not* bake SSH
host keys into a layer (`entrypoint.sh` generates fresh, per-container
keys via `ssh-keygen -A` at container *startup*). Baking keys in would
mean every node in every lab, across every redeploy, shares the exact
same host key, which is worse than a key that legitimately changes
each redeploy. Bypassing the entrypoint (`--entrypoint sh`, needed to
run a one-off check instead of booting the full router) also skips
that key-generation step, so of course no keys exist yet. The
Dockerfile's own build-time validation works around this correctly:
it generates throwaway keys, runs `sshd -t`, then deletes them again
before the layer is committed.

**To validate image readiness manually anyway:** run `ssh-keygen -A`
first, in the same `docker run`, mirroring what `entrypoint.sh` does
for real - not a workaround, just simulating the actual startup order:
```bash
docker run --rm --entrypoint sh atlaslab/frr:latest -c \
  'ssh-keygen -A >/dev/null 2>&1 && sshd -t && echo OK'
```

## `docker run --rm <image> sh -c '...'` never returns

**Symptom:** a one-off sanity-check command against `atlaslab/frr` (no
`-d`) just hangs. `docker ps` shows a container with a random name
(Docker's auto-generated one, since no `--name` was given) sitting in
`Up` state indefinitely - it hung this repository's own
`verify-environment.sh` for over an hour during development.

**Cause:** `docker run <image> sh -c '...'` does **not** override the
image's `ENTRYPOINT`. `atlaslab/frr`'s entrypoint is
`tini -- atlaslab-entrypoint.sh`; the `sh -c '...'` becomes trailing
`CMD` arguments appended to *that*, which `entrypoint.sh` ignores
entirely (it never references `$1`/`$@`) and unconditionally runs the
full startup sequence anyway - lldpd, sshd, then `exec
/usr/lib/frr/docker-start`, which runs forever. The one-off check never
executes; a full, permanent router container starts instead, and
`docker run` (attached, no `-d`) blocks waiting for a process that
never exits.

**Fix:** always pass `--entrypoint sh` (or whatever you actually want
to run) when using `docker run` against this image for anything other
than deploying it as a real lab node:
```bash
docker run --rm --entrypoint sh atlaslab/frr:latest -c '...'
```
`scripts/verify-environment.sh`'s image sanity check does this, wrapped
in `timeout` as a second, independent guard against this exact mistake
recurring.

## A pipeline into `head -1` kills a script under `set -o pipefail`

**Symptom:** `scripts/deploy-lab.sh` printed a fully successful deploy
(all containers running) and then exited with code 141 instead of 0.

**Cause:** `$(some_pipeline | head -1 | awk ...)` under `set -o
pipefail`: `head -1` reads one line and closes its end of the pipe,
which sends `SIGPIPE` back to whatever is still writing upstream (here,
`scripts/lib/common.sh`'s `lab_mgmt_ips`, which was still producing
more lines). `pipefail` turns that `SIGPIPE`-killed process's exit
status (141) into the whole pipeline's exit status, and `set -e`
(active in every AtlasLab script) then aborts the script right there -
after all the real work had already finished successfully.

**Fix:** capture the producer's *full* output into a variable first
(a plain `$(...)` always reads to EOF, so nothing gets truncated
mid-write), then slice out just the first line with pure bash string
ops - no second pipe, so nothing can SIGPIPE the producer:
```bash
MGMT_LIST="$(lab_mgmt_ips "$LAB" 2>/dev/null || true)"
FIRST_NODE_LINE="${MGMT_LIST%%$'\n'*}"
```

## Piping data into `python3 - <<PYEOF ... PYEOF` silently returns nothing

**Symptom:** `scripts/lib/common.sh`'s `lab_mgmt_ips()` (`containerlab
inspect -f json | python3 - "$prefix" <<'PYEOF' ... PYEOF`) always
returned empty output, even though the same JSON parsed correctly when
tested with `python3 -c "..."` directly.

**Cause:** a heredoc redirect (`<<PYEOF`) and a pipe (`cmd | python3`)
both target the same file descriptor - stdin - and the heredoc always
wins. `python3 -` reads *the script itself* from stdin because of the
bare `-`; with a heredoc present, that's what stdin actually is (the
Python source between the `PYEOF` markers), and it's fully consumed
just to load the script. By the time the script's own `json.load
(sys.stdin)` runs, stdin is already at EOF - the piped JSON was never
readable from inside the script at all, silently, with no error beyond
`json.JSONDecodeError: Expecting value: line 1 column 1 (char 0)`.

**Fix:** don't use `python3 - <<PYEOF` when the script also needs
piped stdin data. Put the script in a real file instead
(`scripts/lib/lab_mgmt_ips.py`) and invoke it as
`producer | python3 scripts/lib/lab_mgmt_ips.py "$prefix"` - stdin is
then free for the pipe, and the script source comes from the
filesystem, not stdin. (`scripts/lib/common.sh`'s `node_list()` uses a
heredoc safely because it never needs piped stdin - it takes a file
*path* as an argv and opens it directly instead.)

## containerlab's `bridge` kind needs a bridge that already exists on the *host*

**Symptom:** `containerlab deploy` on a topology with a `kind: bridge`
node fails immediately: `Bridge "sw1" referenced in topology but does
not exist`.

**Cause:** unlike every other containerlab kind, `bridge` doesn't
create anything - it expects a Linux bridge with that exact name to
already exist on the Docker host, and just attaches veth pairs to it.
Creating that bridge (`ip link add sw1 type bridge`) needs root/host
`CAP_NET_ADMIN`; this environment's WSL user has docker-group access,
not host-level networking privileges (confirmed directly: the `ip
link add` command itself fails with "Operation not permitted" when run
as this user).

**Fix (`labs/07-multi-city`'s L2 switches):** don't use `kind: bridge`
at all - build the bridge *inside* a normal container instead
(`atlaslab/switch`, `kind: linux`), using the same `NET_ADMIN`
capability every AtlasLab node already gets via `cap-add`. A Linux
bridge created inside a container's own network namespace behaves
identically (real MAC learning/forwarding) and needs no host
privileges beyond what's already granted. See
`docker/switch-atlaslab/entrypoint.sh`.

## containerlab link-creation race between fast- and slow-starting images

**Symptom:** in a topology mixing a large image (`atlaslab/frr`, ~250MB)
with much smaller ones (`atlaslab/firewall`/`atlaslab/switch`, both
under 20MB), `containerlab deploy` intermittently fails with `Link not
found` for a node connected to the small image - a different node each
run, seemingly at random. `--max-workers 1` (fully serialized node
creation) does **not** fix it.

**Cause:** confirmed via `containerlab deploy --log-level debug` and
correlating timestamps: containerlab creates each node's container and
then independently proceeds to that *specific node's* link-creation
stage, without waiting for the peer node in each link to exist yet. A
small image reaches "container created, begin creating links" in a
couple of seconds; a ~250MB image can take 10-25s longer to pull/start.
If the fast node's link-creation stage runs before the slow peer's
container exists at all, that link fails - and since links are declared
once but processed independently by *each* of their two endpoint
nodes, this can strand either side depending on which one processes
first. This is a containerlab scheduling behavior, not something a
topology file can directly control, and it reproduces with a fully
serialized `--max-workers 1` just as often as with the default
concurrency - it isn't really about *parallelism*, it's about the
*absolute* time gap between when a fast node and a slow node each
become ready.

**Fix:** `startup-delay: <seconds>` (a per-node containerlab topology
property) on every fast-starting node gives the slower image's
containers time to exist first before the fast node even begins being
created, which resolved the vast majority of occurrences in direct
testing (35s in `labs/07-multi-city`, set by `scripts/generate-
multicity.py`). It doesn't guarantee zero failures under all host load
conditions, so `scripts/deploy-lab.sh` also retries automatically
(destroy + redeploy, up to 3 attempts) if `containerlab deploy` reports
failure - a transient scheduling race, not a config error, so retrying
is the right response. Both mitigations exist for the same underlying
platform behavior; neither alone was 100% sufficient in testing, the
combination was.

## A non-idempotent startup script + `restart: always` = a silent, permanent link loss

**Symptom:** `containerlab deploy` reports success (exit 0, "All N
containers running"), but a specific node - consistently the same
*type* of node across every site in `labs/07-multi-city` - has *zero*
of its topology-facing interfaces (`ip -o link show` on it shows only
`lo` and `eth0`), even though `containerlab deploy`'s own log showed
that node's links being created successfully earlier in the run.

**Cause:** containerlab sets `restart: always` on every node by
default. `atlaslab/firewall`'s entrypoint ran a bind-mounted
`setup.sh` doing plain `ip addr add`/`ip route add` under `set -e`. The
very first run legitimately succeeded (interfaces existed, addresses
got applied) - but *something* (in this investigation, a leftover
address from an earlier deploy attempt in the same debugging session)
caused a second invocation of the identical `ip addr add` to fail with
`RTNETLINK answers: File exists`. Under `set -e`, that crashed the
entrypoint immediately; Docker's `restart: always` then restarted the
container - which, critically, creates a **brand new network
namespace** (the same mechanism documented above for `docker restart`
destroying topology links, just triggered automatically by a crash
instead of manually). The freshly-restarted container has no eth1/eth2
at all (containerlab isn't re-invoked to re-attach them), so `setup.sh`
fails again on `Cannot find device "eth1"`, crashing again - an
infinite, silent restart loop (`docker inspect --format
'{{.RestartCount}}'` climbed to 7+ before this was caught) that leaves
the node permanently stranded with no data-plane connectivity, while
the overall `containerlab deploy` command had already reported success
long before the loop started.

**Fix:** make the startup script idempotent, so a second (or fifth) run
succeeds identically to the first instead of crashing: `ip addr
replace` instead of `ip addr add`, `ip route replace` instead of `ip
route add`, `iptables -F FORWARD` before re-adding rules. None of these
substitutions change behavior on a first run; all of them make a rerun
safe. Given `restart: always` is containerlab's default and out of this
repo's control, treating "this script may run more than once in the
same container" as a real, expected scenario - not an edge case - is
the correct baseline for any script that configures network state
imperatively (`docker/frr-atlaslab` doesn't have this problem: FRR's
own config application via `vtysh -b` is idempotent by design).

## A container's own kernel default route silently beats an OSPF/BGP-originated one

**Symptom:** OSPF shows `Full` everywhere, the OSPF-originated default
route (`default-information originate always`) is correctly present in
`show ip route 0.0.0.0/0` with the right next-hops - but pings relying
on that default route fail anyway, for far more pairs than any
firewall policy would explain (200+ unexpected failures in
`labs/07-multi-city`, cutting across sites and roles with no obvious
pattern at first).

**Cause:** every AtlasLab container gets a **kernel**-installed default
route via `eth0` (Docker's management-network gateway, for the
container's own image-pull/DNS/troubleshooting internet access).
`show ip route 0.0.0.0/0` on an affected node showed exactly this:
two competing entries for the identical prefix, `Known via "kernel",
distance 0` and `Known via "ospf", distance 110` - and zebra always
installs the lower-distance route for forwarding, kernel routes being
distance 0 by convention specifically so FRR never clobbers a route it
doesn't own. The OSPF-originated default was real, correctly
originated, and completely inert. This only bites when a *blanket*
`0.0.0.0/0` is originated into a routing protocol - `06-atlas-demo`
never hit this because it only ever redistributes *specific* prefixes,
which don't compete with the kernel's catch-all route at all (longest-
prefix-match means the specific route always wins regardless of the
kernel default existing).

**Fix:** delete the competing kernel route, but only on nodes that
actually rely on a learned default for real forwarding decisions -
`ATLASLAB_REMOVE_MGMT_DEFAULT_ROUTE=1` (a node `env:` var, set only on
`labs/07-multi-city`'s core/access1/access2/server roles) makes
`docker/frr-atlaslab/entrypoint.sh` run `ip route del default dev eth0`
*before* zebra starts, so zebra never imports the competing route in
the first place. Deliberately opt-in and off by default: removing
internet access from every node in every lab would break ad hoc
in-container troubleshooting (e.g. `apk add --no-cache tcpdump`, used
repeatedly earlier in this repo's own development) for no benefit in
labs that never originate a competing default route.
