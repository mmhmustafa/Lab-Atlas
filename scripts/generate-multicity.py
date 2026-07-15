#!/usr/bin/env python3
"""AtlasLab multi-city generator.

Reads inventory/multi-city.yaml (the site list - name/idx/ASN) and
renders labs/07-multi-city from a fixed per-site node/link template,
since every site has the exact same internal shape by design:

    configs/07-multi-city/<node>/{daemons,frr.conf,vtysh.conf}  (FRR nodes)
    configs/07-multi-city/<node>/setup.sh                        (firewall nodes)
    labs/07-multi-city/lab.clab.yml
    labs/07-multi-city/expected-unreachable.txt

Reuses templates/frr/{daemons.j2,vtysh.conf.j2} (fully generic already)
but builds frr.conf via explicit Python string-building, same as
scripts/generate-configs.py and for the same reason: FRR's config is
strictly line-oriented and Jinja whitespace control has already caused
silent line-merging bugs once in this repo (see docs/troubleshooting.md).

Usage:
    python3 scripts/generate-multicity.py
"""
from __future__ import annotations

import ipaddress
import itertools
import sys
from pathlib import Path

import yaml
from jinja2 import Environment, FileSystemLoader, StrictUndefined

REPO_ROOT = Path(__file__).resolve().parent.parent
INVENTORY_FILE = REPO_ROOT / "inventory" / "multi-city.yaml"
TEMPLATES_DIR = REPO_ROOT / "templates" / "frr"
LAB = "07-multi-city"
OSPF_AREA = "0.0.0.0"

ROLES = ["edge", "fw", "core", "sw1", "sw2", "access1", "access2", "server"]
FRR_ROLES = {"edge", "core", "access1", "access2", "server"}


def load_inventory() -> dict:
    with open(INVENTORY_FILE, encoding="utf-8") as f:
        return yaml.safe_load(f)


def strip_mask(cidr: str) -> str:
    return cidr.split("/")[0]


def host_ip(subnet_cidr: str, index: int) -> str:
    net = ipaddress.ip_network(subnet_cidr, strict=True)
    return str(list(net.hosts())[index])


def site_plan(site: dict) -> dict:
    i = site["idx"]
    return {
        "name": site["name"],
        "idx": i,
        "asn": site["asn"],
        # edge's loopback is standalone (10.250.x.x) - always reachable,
        # no firewall in the way. Everything behind the firewall (core,
        # access1, access2, server) lives in a *separate* block
        # (10.251.x.x) specifically so it aggregates to one clean route
        # (10.251.<idx>.0/24) that edge can point at the firewall and
        # advertise into BGP - see build_node_context()'s edge case and
        # labs/07-multi-city/README.md. Routing reachability to this
        # block is deliberately NOT the security boundary here; the
        # firewall's iptables policy is (access1/access2 are routable
        # but firewalled - see render_firewall_setup()).
        "loopback": {
            "edge": f"10.250.{i}.1/32",
            "core": f"10.251.{i}.2/32",
            "access1": f"10.251.{i}.3/32",
            "access2": f"10.251.{i}.4/32",
            "server": f"10.251.{i}.5/32",
        },
        "internal_loopback_block": f"10.251.{i}.0/24",
        "segA": f"172.30.{i * 4 + 0}.0/24",
        "segB": f"172.30.{i * 4 + 1}.0/24",
        "aggregate": f"172.30.{i * 4}.0/22",
        "edge_fw": f"10.90.{i}.0/30",
        "fw_core": f"10.90.{i}.4/30",
    }


def build_topology(sites: list[dict]):
    """Returns (plans, node_interfaces, link_records).

    node_interfaces: {node: [iface_dict, ...]} in eth1..ethN order.
    link_records: [{"a","ifname_a","b","ifname_b"}, ...] for lab.clab.yml.
    Switch nodes get no addressed "interface" entries (pure L2) but do
    get eth-numbered ports via the same counters, so their side of a
    link_record is consistent.
    """
    plans = {s["name"]: site_plan(s) for s in sites}
    node_interfaces: dict[str, list] = {}
    iface_counters: dict[str, int] = {}
    for name in plans:
        for role in ROLES:
            dev = f"{name}-{role}"
            node_interfaces[dev] = []
            iface_counters[dev] = 0

    link_records = []

    def new_ifname(dev: str) -> str:
        iface_counters[dev] += 1
        return f"eth{iface_counters[dev]}"

    def add_p2p(a: str, b: str, subnet: str, group: str, ospf: bool = False):
        net = ipaddress.ip_network(subnet, strict=True)
        prefixlen = net.prefixlen
        ip_a, ip_b = host_ip(subnet, 0), host_ip(subnet, 1)
        ifname_a, ifname_b = new_ifname(a), new_ifname(b)
        node_interfaces[a].append({
            "ifname": ifname_a, "ip": ip_a, "ip_cidr": f"{ip_a}/{prefixlen}",
            "peer": b, "peer_ip": ip_b,
            "description": f"LINK-TO-{b}-{group}".upper(), "group": group, "ospf": ospf,
        })
        node_interfaces[b].append({
            "ifname": ifname_b, "ip": ip_b, "ip_cidr": f"{ip_b}/{prefixlen}",
            "peer": a, "peer_ip": ip_a,
            "description": f"LINK-TO-{a}-{group}".upper(), "group": group, "ospf": ospf,
        })
        link_records.append({"a": a, "ifname_a": ifname_a, "b": b, "ifname_b": ifname_b})

    def add_switch_port(dev: str, switch: str, subnet: str, host_idx: int, group: str, ospf: bool = True):
        net = ipaddress.ip_network(subnet, strict=True)
        prefixlen = net.prefixlen
        ip = host_ip(subnet, host_idx)
        ifname_dev = new_ifname(dev)
        ifname_sw = new_ifname(switch)
        node_interfaces[dev].append({
            "ifname": ifname_dev, "ip": ip, "ip_cidr": f"{ip}/{prefixlen}",
            "peer": switch, "peer_ip": None,
            "description": f"LINK-TO-{switch}-{group}".upper(), "group": group, "ospf": ospf,
        })
        link_records.append({"a": dev, "ifname_a": ifname_dev, "b": switch, "ifname_b": ifname_sw})

    for name, plan in plans.items():
        edge, fw, core = f"{name}-edge", f"{name}-fw", f"{name}-core"
        sw1, sw2 = f"{name}-sw1", f"{name}-sw2"
        access1, access2, server = f"{name}-access1", f"{name}-access2", f"{name}-server"

        add_p2p(edge, fw, plan["edge_fw"], "edge-fw")
        add_p2p(fw, core, plan["fw_core"], "fw-core")

        add_switch_port(core, sw1, plan["segA"], 0, "core-sw1")
        add_switch_port(access1, sw1, plan["segA"], 1, "access1-sw1")
        add_switch_port(server, sw1, plan["segA"], 2, "server-sw1")

        add_switch_port(core, sw2, plan["segB"], 0, "core-sw2")
        add_switch_port(access2, sw2, plan["segB"], 1, "access2-sw2")
        add_switch_port(server, sw2, plan["segB"], 2, "server-sw2")

    # Inter-site WAN mesh: full mesh among edge routers, one /30 per pair.
    site_names = list(plans.keys())
    for k, (a, b) in enumerate(itertools.combinations(site_names, 2)):
        subnet = f"192.168.100.{k * 4}/30"
        add_p2p(f"{a}-edge", f"{b}-edge", subnet, "inter-site-wan")

    return plans, node_interfaces, link_records


def render_frr_conf(ctx: dict) -> str:
    """Explicit line-by-line FRR config build - see module docstring."""
    L: list[str] = []
    add = L.append

    add("! ============================================================================")
    add("! AtlasLab - generated by scripts/generate-multicity.py - DO NOT EDIT BY HAND")
    add(f"! lab={LAB}  node={ctx['node']}  site={ctx['site']}  role={ctx['role']}")
    add("! Regenerate with: python3 scripts/generate-multicity.py")
    add("! ============================================================================")
    add("frr version 10.0")
    add("frr defaults traditional")
    add(f"hostname {ctx['node']}")
    add("log file /var/log/frr/frr.log informational")
    add("log timestamp precision 3")
    add("service integrated-vtysh-config")
    add("!")

    add("interface lo")
    add(f" description LOOPBACK-{ctx['node']}")
    add(f" ip address {ctx['loopback_cidr']}")
    add("!")

    for ifc in ctx["interfaces"]:
        add(f"interface {ifc['ifname']}")
        add(f" description {ifc['description']}")
        add(f" ip address {ifc['ip_cidr']}")
        add("!")

    if ctx["ospf_enabled"]:
        add("router ospf")
        add(f" ospf router-id {ctx['router_id']}")
        add(" passive-interface default")
        for ifname in ctx["ospf_active_ifaces"]:
            add(f" no passive-interface {ifname}")
        for net in ctx["ospf_networks"]:
            add(f" network {net} area {OSPF_AREA}")
        if ctx["originate_default"]:
            add(" default-information originate always")
        add("exit")
        add("!")

    if ctx["static_routes"]:
        for r in ctx["static_routes"]:
            add(f"ip route {r['prefix']} {r['nexthop']}")
        add("!")

    if ctx["bgp_enabled"]:
        add(f"router bgp {ctx['bgp_asn']}")
        add(" no bgp ebgp-requires-policy")
        add(" no bgp network import-check")
        add(f" bgp router-id {ctx['router_id']}")
        for n in ctx["bgp_neighbors"]:
            add(f" neighbor {n['peer_ip']} remote-as {n['remote_as']}")
            add(f" neighbor {n['peer_ip']} description {n['description']}")
        add(" !")
        add(" address-family ipv4 unicast")
        for net in ctx["bgp_networks"]:
            add(f"  network {net}")
        add(" exit-address-family")
        add("exit")
        add("!")

    add("line vty")
    add("!")

    return "\n".join(L) + "\n"


def build_node_context(plan: dict, role: str, node_interfaces: dict, asn_by_site: dict) -> dict:
    name = plan["name"]
    node = f"{name}-{role}"
    interfaces = node_interfaces[node]
    router_id = strip_mask(plan["loopback"][role])

    ospf_enabled = role in ("core", "access1", "access2", "server")
    ospf_active_ifaces = [i["ifname"] for i in interfaces if i["ospf"]]
    ospf_networks: list[str] = []
    if ospf_enabled:
        ospf_networks.append(plan["loopback"][role])
        for i in interfaces:
            if i["ospf"]:
                net = ipaddress.ip_interface(i["ip_cidr"]).network
                ospf_networks.append(str(net))
        seen, deduped = set(), []
        for n in ospf_networks:
            if n not in seen:
                seen.add(n)
                deduped.append(n)
        ospf_networks = deduped

    static_routes = []
    if role == "core":
        # Everything not locally known heads for the firewall's inside
        # leg; default-information originate (below) fans this out to
        # the rest of the site's OSPF domain (access1/access2/server).
        static_routes.append({"prefix": "0.0.0.0/0", "nexthop": host_ip(plan["fw_core"], 0)})
    if role == "edge":
        # Everything behind the firewall (the LAN aggregate *and* the
        # separate internal-loopback block, see site_plan()) lives on
        # the other side of a boundary that OSPF/BGP never crosses (the
        # firewall isn't a routing-protocol speaker - see
        # labs/07-multi-city/README.md), so edge needs one static route
        # per block to originate them into BGP for the other cities.
        static_routes.append({"prefix": plan["aggregate"], "nexthop": host_ip(plan["edge_fw"], 1)})
        static_routes.append({"prefix": plan["internal_loopback_block"], "nexthop": host_ip(plan["edge_fw"], 1)})

    bgp_enabled = role == "edge"
    bgp_neighbors = []
    bgp_networks = []
    if bgp_enabled:
        bgp_networks = [plan["loopback"]["edge"], plan["aggregate"], plan["internal_loopback_block"]]
        for i in interfaces:
            if i["group"] == "inter-site-wan":
                peer_site = i["peer"].rsplit("-edge", 1)[0]
                bgp_neighbors.append({
                    "peer_ip": i["peer_ip"],
                    "remote_as": asn_by_site[peer_site],
                    "description": f"EBGP-{i['peer']}",
                    "peer_site": peer_site,
                })

    return {
        "lab": LAB,
        "node": node,
        "site": name,
        "role": role,
        "router_id": router_id,
        "loopback_cidr": plan["loopback"][role],
        "interfaces": interfaces,
        "ospf_enabled": ospf_enabled,
        "ospf_active_ifaces": ospf_active_ifaces,
        "ospf_networks": ospf_networks,
        "originate_default": role == "core",
        "static_routes": static_routes,
        "bgp_enabled": bgp_enabled,
        "bgp_asn": plan["asn"],
        "bgp_neighbors": bgp_neighbors,
        "bgp_networks": bgp_networks,
    }


def render_firewall_setup(plan: dict) -> str:
    i = plan["idx"]
    name = plan["name"]
    fw_outside = host_ip(plan["edge_fw"], 1)
    fw_outside_len = ipaddress.ip_network(plan["edge_fw"]).prefixlen
    edge_ip = host_ip(plan["edge_fw"], 0)
    fw_inside = host_ip(plan["fw_core"], 0)
    fw_inside_len = ipaddress.ip_network(plan["fw_core"]).prefixlen
    core_ip = host_ip(plan["fw_core"], 1)
    core_lo = strip_mask(plan["loopback"]["core"])
    server_lo = strip_mask(plan["loopback"]["server"])
    aggregate = plan["aggregate"]
    internal_loopback_block = plan["internal_loopback_block"]

    return f"""#!/bin/sh
# AtlasLab - generated by scripts/generate-multicity.py - DO NOT EDIT BY HAND
# site={name}
#
# Perimeter firewall for {name}: eth1 is the "outside" leg toward
# {name}-edge (the inter-city WAN), eth2 is the "inside" leg toward
# {name}-core (this site's internal network). Not a routing protocol
# speaker - see labs/07-multi-city/README.md for why the boundary here
# is deliberately static routes, not OSPF/BGP crossing the firewall.

# "replace", not "add", throughout this file: containerlab sets
# restart:always on every node, and if this script is ever interrupted
# partway through (or the container restarts for any other reason)
# after some of it already applied, a plain `ip addr add`/`ip route add`
# fails with "RTNETLINK answers: File exists" on the second run - which,
# combined with `set -e` in entrypoint.sh, crashes the container, which
# restarts it, which fails at the same spot again: an infinite crash
# loop that silently strands this node with no topology links at all
# (confirmed by direct testing - see docs/troubleshooting.md). `replace`
# is idempotent - it succeeds identically whether this is the first run
# or the fifth.
ip addr replace {fw_outside}/{fw_outside_len} dev eth1
ip link set eth1 up
ip addr replace {fw_inside}/{fw_inside_len} dev eth2
ip link set eth2 up

ip route replace default via {edge_ip} dev eth1
ip route replace {aggregate} via {core_ip} dev eth2
ip route replace {internal_loopback_block} via {core_ip} dev eth2

sysctl -w net.ipv4.ip_forward=1 >/dev/null

# --- Stateful policy -------------------------------------------------
# Flush first, same idempotency rationale as above - otherwise a rerun
# appends duplicate rules (harmless for correctness, but messy, and it
# masks the real problem if setup.sh legitimately runs more than once).
# Default-deny inbound from the WAN; the site's own outbound traffic is
# unrestricted. Only {name}-core and {name}-server are reachable from
# other cities (infrastructure + the one "published" node); the access
# tier ({name}-access1/{name}-access2) is deliberately internal-only -
# see labs/07-multi-city/expected-unreachable.txt, generated to match
# this exact policy.
iptables -F FORWARD
iptables -P FORWARD DROP
iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -i eth2 -o eth1 -j ACCEPT
iptables -A FORWARD -i eth1 -o eth2 -p icmp -d {core_lo} -j ACCEPT
iptables -A FORWARD -i eth1 -o eth2 -p icmp -d {server_lo} -j ACCEPT
iptables -A FORWARD -i eth1 -o eth2 -p tcp --dport 22 -d {server_lo} -j ACCEPT
iptables -A FORWARD -i eth1 -o eth2 -j LOG --log-prefix "ATLASLAB-FW-{name.upper()}-DROP: " --log-level 4
"""


def render_lab_topology(plans: dict, link_records: list) -> None:
    lab_dir = REPO_ROOT / "labs" / LAB
    lab_dir.mkdir(parents=True, exist_ok=True)

    nodes_yaml = {}
    for name in plans:
        for role in ROLES:
            node = f"{name}-{role}"
            if role in FRR_ROLES:
                nodes_yaml[node] = {
                    "image": "atlaslab/frr:latest",
                    "binds": [
                        f"../../configs/{LAB}/{node}/daemons:/etc/frr/daemons",
                        f"../../configs/{LAB}/{node}/frr.conf:/etc/frr/frr.conf",
                        f"../../configs/{LAB}/{node}/vtysh.conf:/etc/frr/vtysh.conf",
                    ],
                }
                if role in ("core", "access1", "access2", "server"):
                    # See docker/frr-atlaslab/entrypoint.sh: these roles
                    # forward based on an OSPF-originated default route
                    # (core originates it, access1/access2/server learn
                    # it), which a container's own kernel default route
                    # via eth0 would otherwise always out-rank. edge is
                    # excluded - it never relies on a *learned* default,
                    # only specific eBGP-learned routes.
                    nodes_yaml[node]["env"] = {"ATLASLAB_REMOVE_MGMT_DEFAULT_ROUTE": "1"}
            elif role == "fw":
                nodes_yaml[node] = {
                    "image": "atlaslab/firewall:latest",
                    # See labs/07-multi-city/README.md's "known limitation"
                    # section: this image is much smaller/faster to start
                    # than atlaslab/frr, and containerlab schedules each
                    # node's link-creation independently of its peers'
                    # readiness. Without a deliberate delay, a firewall
                    # node reliably reaches its create-links stage before
                    # its FRR-image edge/core neighbors even exist as
                    # containers yet, which containerlab handles by
                    # failing that link ("Link not found") rather than
                    # waiting - confirmed by direct testing (timestamps in
                    # `containerlab deploy --log-level debug` output).
                    "startup-delay": 35,
                    "binds": [
                        f"../../configs/{LAB}/{node}/setup.sh:/etc/atlaslab-firewall/setup.sh",
                    ],
                }
            else:  # sw1, sw2 - same rationale as the firewall case above.
                nodes_yaml[node] = {"image": "atlaslab/switch:latest", "startup-delay": 35}

    links_yaml = [
        {"endpoints": [f"{rec['a']}:{rec['ifname_a']}", f"{rec['b']}:{rec['ifname_b']}"]}
        for rec in link_records
    ]

    topo = {
        "name": f"atlas-{LAB}",
        "topology": {
            "defaults": {
                "kind": "linux",
                "cap-add": ["NET_ADMIN", "NET_RAW", "SYS_ADMIN"],
                "sysctls": {
                    "net.ipv4.ip_forward": 1,
                    "net.ipv4.conf.all.rp_filter": 0,
                    "net.ipv4.conf.default.rp_filter": 0,
                },
            },
            "nodes": nodes_yaml,
            "links": links_yaml,
        },
    }

    out_file = lab_dir / "lab.clab.yml"
    with open(out_file, "w", newline="\n", encoding="utf-8") as f:
        f.write("# AtlasLab - generated by scripts/generate-multicity.py - DO NOT EDIT BY HAND\n")
        f.write("# Regenerate with: python3 scripts/generate-multicity.py\n")
        yaml.safe_dump(topo, f, sort_keys=False, default_flow_style=False)


def render_expected_unreachable(plans: dict) -> None:
    """access1/access2 are behind each site's firewall policy - see
    render_firewall_setup(). Any source *outside* that site's firewall
    is blocked from reaching them, which is every other site's nodes
    AND, easy to miss, this same site's own edge router - edge sits on
    the WAN side of its own site's firewall too, so it's just as
    "outside" as a different city is. core/access1/access2/server never
    cross their own firewall to reach each other, so they're the only
    same-site sources excluded here. Confirmed against a live deploy:
    the first version of this function only excluded same-site sources
    across the board and produced 8 false "unexpected failures" - one
    edge-to-own-access pair per site - before this fix."""
    lab_dir = REPO_ROOT / "labs" / LAB
    lines = [
        "# AtlasLab - generated by scripts/generate-multicity.py - DO NOT EDIT BY HAND",
        "# <src-node> <dst-node>, one direction per line.",
        "# access1/access2 are internal-only by firewall policy in every site",
        "# (see configs/07-multi-city/<site>-fw/setup.sh) - unreachable from any",
        "# node outside that site's firewall, by design, not a bug. That includes",
        "# the site's OWN edge router (it sits on the WAN side of its own",
        "# firewall too) - only same-site core/access1/access2/server are exempt.",
    ]
    site_names = list(plans.keys())
    all_nodes = [f"{name}-{role}" for name in site_names for role in ROLES if role in FRR_ROLES]
    for name in site_names:
        for blocked_role in ("access1", "access2"):
            dst = f"{name}-{blocked_role}"
            for src in all_nodes:
                src_site, src_role = src.rsplit("-", 1)
                if src_site == name and src_role != "edge":
                    continue  # same-site, inside the firewall - unaffected
                lines.append(f"{src} {dst}")
    (lab_dir / "expected-unreachable.txt").write_text("\n".join(lines) + "\n", newline="\n")


def main() -> int:
    inv = load_inventory()
    sites = inv["sites"]
    plans, node_interfaces, link_records = build_topology(sites)

    asn_by_site = {name: plan["asn"] for name, plan in plans.items()}

    env = Environment(
        loader=FileSystemLoader(str(TEMPLATES_DIR)),
        trim_blocks=True, lstrip_blocks=True,
        undefined=StrictUndefined, keep_trailing_newline=True,
    )
    daemons_tpl = env.get_template("daemons.j2")
    vtysh_tpl = env.get_template("vtysh.conf.j2")

    configs_dir = REPO_ROOT / "configs" / LAB
    written = 0
    for name, plan in plans.items():
        for role in ROLES:
            node = f"{name}-{role}"
            node_dir = configs_dir / node
            node_dir.mkdir(parents=True, exist_ok=True)

            if role in FRR_ROLES:
                ctx = build_node_context(plan, role, node_interfaces, asn_by_site)
                (node_dir / "daemons").write_text(
                    daemons_tpl.render(lab=LAB, node=node, role=role,
                                        ospf_enabled=ctx["ospf_enabled"], bgp_enabled=ctx["bgp_enabled"]),
                    newline="\n",
                )
                (node_dir / "vtysh.conf").write_text(vtysh_tpl.render(node=node), newline="\n")
                (node_dir / "frr.conf").write_text(render_frr_conf(ctx), newline="\n")
                written += 3
            elif role == "fw":
                (node_dir / "setup.sh").write_text(render_firewall_setup(plan), newline="\n")
                written += 1
            # switches: no config to render

    render_lab_topology(plans, link_records)
    render_expected_unreachable(plans)

    print(f"Rendered {written} config files under configs/{LAB}/")
    print(f"Rendered labs/{LAB}/lab.clab.yml and expected-unreachable.txt")
    print(f"Sites: {len(plans)}  Nodes: {len(plans) * len(ROLES)}  Links: {len(link_records)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
