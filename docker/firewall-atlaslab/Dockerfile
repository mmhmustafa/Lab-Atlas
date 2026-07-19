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

# busybox-extras: provides the busybox httpd applet (not in Alpine's
# base busybox) for the read-only web UI - see webui.cgi.
RUN apk add --no-cache iproute2 iptables openssh shadow tini doas lldpd busybox-extras \
    && mkdir -p /var/run/sshd /run/sshd /var/log/atlaslab /etc/atlaslab-firewall \
    && adduser -D -s /usr/local/bin/fwsh "${ATLASLAB_SSH_USER}" \
    && echo "${ATLASLAB_SSH_USER}:${ATLASLAB_SSH_PASSWORD}" | chpasswd \
    # lldpd's control socket is group-accessible (lldpd:lldpd, mode 770 -
    # verified on this exact package), so group membership is all fwsh's
    # "show lldp neighbors" needs - no doas rule required for it.
    && addgroup "${ATLASLAB_SSH_USER}" lldpd

COPY sshd_config /etc/ssh/sshd_config

# doas.conf must be owned by root and not group/other-writable, or doas
# refuses to run at all - see doas.conf's own comment for why this is
# one exact, narrowly-scoped rule rather than a general privilege grant.
COPY doas.conf /etc/doas.conf
RUN chown root:root /etc/doas.conf && chmod 0644 /etc/doas.conf

COPY fwsh /usr/local/bin/fwsh
RUN chmod +x /usr/local/bin/fwsh

COPY index.html /var/www/index.html
COPY webui.cgi /var/www/cgi-bin/status
RUN chmod +x /var/www/cgi-bin/status

RUN ssh-keygen -A \
    && /usr/sbin/sshd -t \
    && rm -f /etc/ssh/ssh_host_*

COPY entrypoint.sh /usr/local/bin/atlaslab-firewall-entrypoint.sh
RUN chmod +x /usr/local/bin/atlaslab-firewall-entrypoint.sh

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/atlaslab-firewall-entrypoint.sh"]
