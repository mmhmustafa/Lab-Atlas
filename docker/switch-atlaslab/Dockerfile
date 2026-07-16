# AtlasLab - custom L2 switch image
#
# A pure layer-2 switch node: bridges every topology-facing interface
# (eth1..ethN) together inside its own network namespace using a real
# Linux kernel bridge (genuine MAC learning/forwarding), plus SSH
# management access for consistency with atlaslab/frr - the atlas
# account's login shell is swsh, a small router-style "show command"
# CLI (see ./swsh), the same idea as vtysh/fwsh scoped to this image's
# role.
#
# containerlab's own "bridge" kind was considered and rejected: it
# requires a Linux bridge to already exist on the *host*, which needs
# root - not available in this environment (WSL user has docker-group
# access, not host CAP_NET_ADMIN). Building the bridge *inside* a
# container instead needs only the NET_ADMIN capability every AtlasLab
# node already gets via cap-add, so it works with the same permissions
# everything else in this repo already uses.
FROM alpine:latest

ARG ATLASLAB_SSH_USER=atlas
ARG ATLASLAB_SSH_PASSWORD=AtlasLab123!

RUN apk add --no-cache iproute2 bridge openssh shadow tini lldpd \
    && mkdir -p /var/run/sshd /run/sshd /var/log/atlaslab \
    && adduser -D -s /usr/local/bin/swsh "${ATLASLAB_SSH_USER}" \
    && echo "${ATLASLAB_SSH_USER}:${ATLASLAB_SSH_PASSWORD}" | chpasswd \
    # lldpd's control socket is group-accessible (lldpd:lldpd, mode 770),
    # so group membership is all swsh's "show lldp neighbors" needs.
    && addgroup "${ATLASLAB_SSH_USER}" lldpd

COPY sshd_config /etc/ssh/sshd_config

COPY swsh /usr/local/bin/swsh
RUN chmod +x /usr/local/bin/swsh

# Same build-time validation as atlaslab/frr: generate throwaway host
# keys, validate the config, delete the keys again so the image itself
# ships without any - see docker/frr-atlaslab/Dockerfile for the full
# rationale (unique host key per container, generated at startup).
RUN ssh-keygen -A \
    && /usr/sbin/sshd -t \
    && rm -f /etc/ssh/ssh_host_*

COPY entrypoint.sh /usr/local/bin/atlaslab-switch-entrypoint.sh
RUN chmod +x /usr/local/bin/atlaslab-switch-entrypoint.sh

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/atlaslab-switch-entrypoint.sh"]
