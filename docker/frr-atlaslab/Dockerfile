# AtlasLab - custom FRR image
#
# Layers lldpd onto the upstream frrouting/frr image so every lab node
# is LLDP-discoverable, in addition to running FRR's OSPF/BGP daemons.
# Everything else (daemons file, frr.conf, vtysh.conf) is bind-mounted
# by containerlab exactly as with the base image - this Dockerfile only
# adds the one missing piece.
FROM frrouting/frr:latest

RUN apk add --no-cache lldpd \
    && mkdir -p /var/log/frr \
    && chown frr:frr /var/log/frr

COPY entrypoint.sh /usr/local/bin/atlaslab-entrypoint.sh
RUN chmod +x /usr/local/bin/atlaslab-entrypoint.sh

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/atlaslab-entrypoint.sh"]
