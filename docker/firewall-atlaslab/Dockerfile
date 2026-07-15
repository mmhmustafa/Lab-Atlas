# AtlasLab - custom firewall image
#
# A stateful iptables firewall node: two (or more) topology-facing
# interfaces, IP addressing/routes/filtering rules supplied entirely by
# a bind-mounted setup script (same pattern as atlaslab/frr's
# bind-mounted frr.conf - the image is generic, the topology-specific
# config lives in configs/<lab>/<node>/), plus SSH management access.
#
# No commercial/vendor firewall image is installed in this environment
# (only frrouting/frr existed at the start of this repo) - this is a
# genuine, functional iptables stateful firewall, honestly documented
# as that rather than presented as a specific vendor product. See
# docs/atlas-integration.md and labs/07-multi-city/README.md.
FROM alpine:latest

ARG ATLASLAB_SSH_USER=atlas
ARG ATLASLAB_SSH_PASSWORD=AtlasLab123!

RUN apk add --no-cache iproute2 iptables openssh shadow tini \
    && mkdir -p /var/run/sshd /run/sshd /var/log/atlaslab /etc/atlaslab-firewall \
    && adduser -D -s /bin/sh "${ATLASLAB_SSH_USER}" \
    && echo "${ATLASLAB_SSH_USER}:${ATLASLAB_SSH_PASSWORD}" | chpasswd

COPY sshd_config /etc/ssh/sshd_config

RUN ssh-keygen -A \
    && /usr/sbin/sshd -t \
    && rm -f /etc/ssh/ssh_host_*

COPY entrypoint.sh /usr/local/bin/atlaslab-firewall-entrypoint.sh
RUN chmod +x /usr/local/bin/atlaslab-firewall-entrypoint.sh

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/atlaslab-firewall-entrypoint.sh"]
