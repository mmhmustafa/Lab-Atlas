#!/usr/bin/env python3
"""AtlasLab FRR config + containerlab topology generator.

Reads inventory/devices.yaml (the single source of truth for the
06-atlas-demo topology) and renders, from templates/frr/*.j2:

    configs/<lab>/<node>/{daemons,frr.conf,vtysh.conf}
    labs/<lab>/lab.clab.yml

Regenerating is idempotent - run this any time inventory/devices.yaml
changes instead of hand-editing per-node FRR configs.

Usage:
    python3 scripts/generate-configs.py [--lab 06-atlas-demo]
"""
from __future__ import annotations

import argparse
import ipaddress
import sys
from pathlib import Path

import yaml
from jinja2 import Environment, FileSystemLoader, StrictUndefined

REPO_ROOT = Path(__file__).resolve().parent.parent
INVENTORY_FILE = REPO_ROOT / "inventory" / "devices.yaml"
TEMPLATES_DIR = REPO_ROOT / "templates" / "frr"


def load_inventory() -> dict:
    with open(INVENTORY_FILE, encoding="utf-8") as f:
        return yaml.safe_load(f)


def strip_mask(cidr: str) -> str:
    return cidr.split("/")[0]


def host_ip(subnet_cidr: str, index: int) -> str:
    net = ipaddress.ip_network(subnet_cidr, strict=True)
    hosts = list(net.hosts())
    return str(hosts[index])


def build_topology(inv: dict):
    """Walk inv['links'] once, assigning eth interfaces + addressing.

    Returns (node_interfaces, link_records):
      node_interfaces: {device_name: [iface_dict, ...]} in eth1..ethN order
      link_records:    [{"a", "ifname_a", "b", "ifname_b"}, ...] for the
                        containerlab topology's `links` section.
    """
    devices = inv["devices"]
    iface_counters = {name: 0 for name in devices}
    node_interfaces: dict[str, list] = {name: [] for name in devices}
    link_records = []

    for link in inv["links"]:
        a, b = link["a"], link["b"]
        subnet = link["subnet"]
        group = link["group"]
        ospf = bool(link.get("ospf", False))

        net = ipaddress.ip_network(subnet, strict=True)
        ip_a = host_ip(subnet, 0)
        ip_b = host_ip(subnet, 1)
        prefixlen = net.prefixlen

        iface_counters[a] += 1
        iface_counters[b] += 1
        ifname_a = f"eth{iface_counters[a]}"
        ifname_b = f"eth{iface_counters[b]}"

        node_interfaces[a].append({
            "ifname": ifname_a,
            "peer": b,
            "peer_ifname": ifname_b,
            "ip": ip_a,
            "ip_cidr": f"{ip_a}/{prefixlen}",
            "peer_ip": ip_b,
            "description": f"LINK-TO-{b}-{group}".upper(),
            "group": group,
            "ospf": ospf,
        })
        node_interfaces[b].append({
            "ifname": ifname_b,
            "peer": a,
            "peer_ifname": ifname_a,
            "ip": ip_b,
            "ip_cidr": f"{ip_b}/{prefixlen}",
            "peer_ip": ip_a,
            "description": f"LINK-TO-{a}-{group}".upper(),
            "group": group,
            "ospf": ospf,
        })

        link_records.append({"a": a, "ifname_a": ifname_a, "b": b, "ifname_b": ifname_b})

    return node_interfaces, link_records


def build_node_context(inv: dict, node: str, node_interfaces: dict, lab: str) -> dict:
    dev = inv["devices"][node]
    role = dev["role"]
    router_id = strip_mask(dev["loopback"])
    ospf_area = inv["ospf"]["area"]
    interfaces = node_interfaces[node]
    atlas_asn = inv["asn"]["atlas"]

    # ---- OSPF ----
    ospf_enabled = bool(dev.get("ospf", False))
    ospf_active_ifaces = [i["ifname"] for i in interfaces if i["ospf"]]
    ospf_networks: list[str] = []
    if ospf_enabled:
        ospf_networks.append(dev["loopback"])
        if dev.get("lan"):
            ospf_networks.append(dev["lan"])
        for i in interfaces:
            if i["ospf"]:
                net = ipaddress.ip_interface(i["ip_cidr"]).network
                ospf_networks.append(str(net))
        seen = set()
        deduped = []
        for n in ospf_networks:
            if n not in seen:
                seen.add(n)
                deduped.append(n)
        ospf_networks = deduped

    redistribute_bgp_into_ospf = role == "edge"

    # ---- BGP ----
    bgp_enabled = dev.get("asn") is not None
    bgp_asn = dev.get("asn")
    bgp_neighbors: list[dict] = []
    bgp_networks: list[str] = []
    maximum_paths_ibgp = None
    redistribute_ospf_into_bgp = False
    redistribute_static_into_bgp = False
    isp_filter = False
    static_routes = []

    if role == "isp":
        static_routes.append({"prefix": dev["test_prefix"], "nexthop": "Null0"})
        redistribute_static_into_bgp = True
        bgp_networks.append(dev["loopback"])
        for i in interfaces:
            if i["group"] == "isp-edge":
                bgp_neighbors.append({
                    "peer_ip": i["peer_ip"],
                    "remote_as": atlas_asn,
                    "description": f"EBGP-{i['peer']}",
                    "update_source": None,
                    "next_hop_self": False,
                    "route_map_out": None,
                })

    elif role == "branch":
        bgp_networks.append(dev["loopback"])
        if dev.get("lan"):
            bgp_networks.append(dev["lan"])
        for i in interfaces:
            if i["group"] == "edge-branch":
                bgp_neighbors.append({
                    "peer_ip": i["peer_ip"],
                    "remote_as": atlas_asn,
                    "description": f"EBGP-{i['peer']}",
                    "update_source": None,
                    "next_hop_self": False,
                    "route_map_out": None,
                })

    elif role in ("edge", "core"):
        maximum_paths_ibgp = 4
        for pair in inv["ibgp_mesh"]:
            if node not in pair:
                continue
            peer = pair[0] if pair[1] == node else pair[1]
            peer_dev = inv["devices"][peer]
            bgp_neighbors.append({
                "peer_ip": strip_mask(peer_dev["loopback"]),
                "remote_as": atlas_asn,
                "description": f"IBGP-{peer}",
                "update_source": "lo",
                "next_hop_self": True,
                "route_map_out": None,
            })
        if role == "edge":
            redistribute_ospf_into_bgp = True
            isp_filter = True
            for i in interfaces:
                if i["group"] == "isp-edge":
                    peer_dev = inv["devices"][i["peer"]]
                    bgp_neighbors.append({
                        "peer_ip": i["peer_ip"],
                        "remote_as": peer_dev["asn"],
                        "description": f"EBGP-{i['peer']}",
                        "update_source": None,
                        "next_hop_self": False,
                        "route_map_out": "RM-TO-ISP",
                    })
                elif i["group"] == "edge-branch":
                    peer_dev = inv["devices"][i["peer"]]
                    bgp_neighbors.append({
                        "peer_ip": i["peer_ip"],
                        "remote_as": peer_dev["asn"],
                        "description": f"EBGP-{i['peer']}",
                        "update_source": None,
                        "next_hop_self": False,
                        "route_map_out": None,
                    })

    lan_cidr = None
    if dev.get("lan"):
        prefixlen = ipaddress.ip_network(dev["lan"], strict=True).prefixlen
        lan_cidr = f"{host_ip(dev['lan'], 0)}/{prefixlen}"

    return {
        "lab": lab,
        "node": node,
        "role": role,
        "router_id": router_id,
        "loopback_cidr": dev["loopback"],
        "lan_cidr": lan_cidr,
        "interfaces": interfaces,
        "ospf_enabled": ospf_enabled,
        "ospf_area": ospf_area,
        "ospf_active_ifaces": ospf_active_ifaces,
        "ospf_networks": ospf_networks,
        "redistribute_bgp_into_ospf": redistribute_bgp_into_ospf,
        "bgp_enabled": bgp_enabled,
        "bgp_asn": bgp_asn,
        "bgp_neighbors": bgp_neighbors,
        "bgp_networks": bgp_networks,
        "maximum_paths_ibgp": maximum_paths_ibgp,
        "redistribute_ospf_into_bgp": redistribute_ospf_into_bgp,
        "redistribute_static_into_bgp": redistribute_static_into_bgp,
        "isp_filter": isp_filter,
        "static_routes": static_routes,
    }


def render_frr_conf(ctx: dict) -> str:
    """Build frr.conf as explicit lines.

    FRR's integrated config is strictly line-oriented (one command per
    line, blank lines and bare `!`/`exit` are structurally meaningful),
    so this is built directly in Python rather than via Jinja: template
    whitespace-control (trim_blocks/`{%- %}`) reliably merged adjacent
    commands onto one line, which vtysh silently mis-parses. Explicit
    string building removes that failure mode entirely.
    """
    L: list[str] = []
    add = L.append

    add("! ============================================================================")
    add(f"! AtlasLab - generated by scripts/generate-configs.py - DO NOT EDIT BY HAND")
    add(f"! lab={ctx['lab']}  node={ctx['node']}  role={ctx['role']}")
    add("! Regenerate with: python3 scripts/generate-configs.py")
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
    if ctx["lan_cidr"]:
        add(f" ip address {ctx['lan_cidr']}")
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
            add(f" network {net} area {ctx['ospf_area']}")
        if ctx["redistribute_bgp_into_ospf"]:
            add(" redistribute bgp")
        add("exit")
        add("!")

    if ctx["bgp_enabled"]:
        if ctx["redistribute_ospf_into_bgp"]:
            # Only genuine OSPF-internal (intra-area) routes are ever
            # redistributed into BGP - never OSPF externals. Without this,
            # a prefix learned via eBGP (e.g. an ISP loopback) that this
            # router itself redistributed BGP->OSPF would come back around
            # as an OSPF external and get redistributed OSPF->BGP again,
            # re-entering BGP with an empty AS-PATH that out-competes the
            # genuine eBGP-learned route. That mutual-redistribution
            # feedback loop causes continuous BGP best-path flapping and,
            # downstream, an unstable OSPF nexthop for the prefix.
            add("route-map RM-OSPF-TO-BGP permit 10")
            add(" match route-type internal")
            add("exit")
            add("!")
        if ctx["isp_filter"]:
            add("ip prefix-list PL-ATLAS-LOOPBACKS seq 5 permit 10.255.0.0/24 le 32")
            add("ip prefix-list PL-ATLAS-LANS seq 5 permit 172.16.0.0/20 le 24")
            add("!")
            add("route-map RM-TO-ISP permit 10")
            add(" match ip address prefix-list PL-ATLAS-LOOPBACKS")
            add("exit")
            add("!")
            add("route-map RM-TO-ISP permit 20")
            add(" match ip address prefix-list PL-ATLAS-LANS")
            add("exit")
            add("!")

        add(f"router bgp {ctx['bgp_asn']}")
        add(" no bgp ebgp-requires-policy")
        add(" no bgp network import-check")
        add(f" bgp router-id {ctx['router_id']}")
        for n in ctx["bgp_neighbors"]:
            add(f" neighbor {n['peer_ip']} remote-as {n['remote_as']}")
            add(f" neighbor {n['peer_ip']} description {n['description']}")
            if n["update_source"]:
                add(f" neighbor {n['peer_ip']} update-source {n['update_source']}")
        add(" !")
        add(" address-family ipv4 unicast")
        for net in ctx["bgp_networks"]:
            add(f"  network {net}")
        for n in ctx["bgp_neighbors"]:
            if n["next_hop_self"]:
                add(f"  neighbor {n['peer_ip']} next-hop-self")
        if ctx["maximum_paths_ibgp"]:
            add(f"  maximum-paths ibgp {ctx['maximum_paths_ibgp']}")
        if ctx["redistribute_ospf_into_bgp"]:
            add("  redistribute ospf route-map RM-OSPF-TO-BGP")
        if ctx["redistribute_static_into_bgp"]:
            add("  redistribute static")
        for n in ctx["bgp_neighbors"]:
            if n["route_map_out"]:
                add(f"  neighbor {n['peer_ip']} route-map {n['route_map_out']} out")
        add(" exit-address-family")
        add("exit")
        add("!")

    if ctx["static_routes"]:
        for r in ctx["static_routes"]:
            add(f"ip route {r['prefix']} {r['nexthop']}")
        add("!")

    add("line vty")
    add("!")

    return "\n".join(L) + "\n"


def render_configs(inv: dict, lab: str, env: Environment) -> list[Path]:
    node_interfaces, link_records = build_topology(inv)
    configs_dir = REPO_ROOT / "configs" / lab
    written: list[Path] = []

    daemons_tpl = env.get_template("daemons.j2")
    vtysh_tpl = env.get_template("vtysh.conf.j2")

    for node in sorted(inv["devices"]):
        ctx = build_node_context(inv, node, node_interfaces, lab)
        node_dir = configs_dir / node
        node_dir.mkdir(parents=True, exist_ok=True)

        (node_dir / "daemons").write_text(
            daemons_tpl.render(
                lab=lab, node=node, role=ctx["role"],
                ospf_enabled=ctx["ospf_enabled"], bgp_enabled=ctx["bgp_enabled"],
            ),
            newline="\n",
        )
        (node_dir / "vtysh.conf").write_text(vtysh_tpl.render(node=node), newline="\n")
        (node_dir / "frr.conf").write_text(render_frr_conf(ctx), newline="\n")

        written.extend([node_dir / "daemons", node_dir / "vtysh.conf", node_dir / "frr.conf"])

    render_lab_topology(inv, lab, link_records)
    return written


def render_lab_topology(inv: dict, lab: str, link_records: list) -> Path:
    lab_dir = REPO_ROOT / "labs" / lab
    lab_dir.mkdir(parents=True, exist_ok=True)

    nodes_yaml = {}
    for node in sorted(inv["devices"]):
        nodes_yaml[node] = {
            "binds": [
                f"../../configs/{lab}/{node}/daemons:/etc/frr/daemons",
                f"../../configs/{lab}/{node}/frr.conf:/etc/frr/frr.conf",
                f"../../configs/{lab}/{node}/vtysh.conf:/etc/frr/vtysh.conf",
            ]
        }

    links_yaml = [
        {"endpoints": [f"{rec['a']}:{rec['ifname_a']}", f"{rec['b']}:{rec['ifname_b']}"]}
        for rec in link_records
    ]

    topo = {
        "name": f"atlas-{lab}",
        "topology": {
            "defaults": {
                "kind": "linux",
                "image": "atlaslab/frr:latest",
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
        f.write("# AtlasLab - generated by scripts/generate-configs.py - DO NOT EDIT BY HAND\n")
        f.write(f"# Regenerate with: python3 scripts/generate-configs.py --lab {lab}\n")
        yaml.safe_dump(topo, f, sort_keys=False, default_flow_style=False)
    return out_file


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lab", default="06-atlas-demo", help="Lab directory name under labs/")
    args = parser.parse_args()

    inv = load_inventory()
    env = Environment(
        loader=FileSystemLoader(str(TEMPLATES_DIR)),
        trim_blocks=True,
        lstrip_blocks=True,
        undefined=StrictUndefined,
        keep_trailing_newline=True,
    )

    written = render_configs(inv, args.lab, env)
    print(f"Rendered {len(written)} config files under configs/{args.lab}/")
    print(f"Rendered labs/{args.lab}/lab.clab.yml")
    print(f"Devices: {len(inv['devices'])}  Links: {len(inv['links'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
