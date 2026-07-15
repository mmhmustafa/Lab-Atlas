# AtlasLab - custom FRR image
#
# Layers lldpd + SSH management access onto the upstream frrouting/frr
# image, in addition to running FRR's OSPF/BGP daemons. Everything else
# (daemons file, frr.conf, vtysh.conf) is bind-mounted by containerlab
# exactly as with the base image - this Dockerfile only adds what the
# base image is missing.
FROM frrouting/frr:latest

# ATLASLAB_SSH_PASSWORD: the "documented password" for the "atlas" SSH
# management user - see docs/atlas-integration.md. Static and shared
# across every node deliberately: this is a local, ephemeral lab
# network (containerlab's own Docker bridge, not exposed beyond the
# host), not a production fleet, so per-node credential management
# would add operational weight with no real security benefit here.
# Overridable at build time (--build-arg) without editing this file.
ARG ATLASLAB_SSH_USER=atlas
ARG ATLASLAB_SSH_PASSWORD=AtlasLab123!

RUN apk add --no-cache lldpd openssh shadow \
    && mkdir -p /var/log/frr /var/run/sshd /run/sshd \
    && chown frr:frr /var/log/frr \
    && adduser -D -s /usr/bin/vtysh "${ATLASLAB_SSH_USER}" \
    && echo "${ATLASLAB_SSH_USER}:${ATLASLAB_SSH_PASSWORD}" | chpasswd \
    && addgroup "${ATLASLAB_SSH_USER}" frr \
    && addgroup "${ATLASLAB_SSH_USER}" frrvty

COPY sshd_config /etc/ssh/sshd_config

# Build-time config validation: `sshd -t` needs host keys present to
# fully parse the config, but this image deliberately does NOT ship
# baked-in host keys (see entrypoint.sh - they're generated fresh per
# container at startup, so every node gets its own). So: generate
# throwaway keys, validate, then delete them again - the image layer
# that ships still has no host keys in it. If sshd_config is invalid
# (e.g. a directive this sshd build doesn't support), `sshd -t` exits
# non-zero and the whole image build fails here, not at container
# runtime.
RUN ssh-keygen -A \
    && /usr/sbin/sshd -t \
    && rm -f /etc/ssh/ssh_host_*

COPY entrypoint.sh /usr/local/bin/atlaslab-entrypoint.sh
RUN chmod +x /usr/local/bin/atlaslab-entrypoint.sh

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/atlaslab-entrypoint.sh"]
