# 05-multivendor

## Honesty note

This environment has exactly one container image available:
`frrouting/frr` (extended, in this repo, into `atlaslab/frr` with
`lldpd` - see [docs/atlas-integration.md](../../docs/atlas-integration.md)).
There is no Cisco, Juniper, Arista, or other vendor image installed, and
the task instructions were explicit not to reinstall/add things outside
what's already provisioned in this environment.

So this is **not** a real multi-vendor interop test. It's a structural
scaffold: three independently-AS'd FRR nodes in a triangle, named
`vendor-a`/`vendor-b`/`vendor-c` to make the *intent* legible, with
nothing vendor-specific about their actual configuration. Treat it as
"this is the shape a multi-vendor interop lab would take" rather than
"this proves interop."

### Extending this to real multi-vendor testing

Containerlab supports third-party NOS images (Cisco IOSv/IOS-XRv,
Juniper vMX/vEVO, Arista cEOS, etc.) via
[vrnetlab](https://containerlab.dev/manual/vrnetlab/) or, for Arista,
a direct `ceos` kind. None of those images are present in this
environment. To turn this lab into a genuine multi-vendor test:

1. Obtain the vendor image(s) (licensing/download requirements vary by
   vendor).
2. Build the vrnetlab container per containerlab's docs for that
   platform.
3. Change the relevant node's `kind`/`image` in `lab.clab.yml` from
   `linux`/`atlaslab/frr:latest` to the vendor kind/image.
4. Replace that node's FRR-specific bind-mounted config
   (`configs/05-multivendor/<node>/`) with the equivalent native config
   for that platform (Cisco IOS CLI, Junos, EOS, etc.) - the FRR
   config-generation pipeline in this repo doesn't apply to non-FRR
   nodes.

## Topology

```
        vendor-a (AS 65021)
         /            \
    vendor-b (AS 65022) -- vendor-c (AS 65023)
```

Full eBGP triangle, loopbacks advertised via `network`. Purely for
exercising three independent AS boundaries meeting at one node each.

## Deploy and test

```bash
make deploy LAB=05-multivendor
make test   LAB=05-multivendor
make destroy LAB=05-multivendor YES=1
```

Convergence: under ~20s.
