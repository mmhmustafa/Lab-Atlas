#!/bin/sh
# AtlasLab - atlaslab/firewall web UI (busybox httpd CGI).
#
# Read-only status page - the web equivalent of fwsh's "show" commands,
# nothing more: no forms, no state changes, no auth surface beyond
# what the page displays. Runs as root (busybox httpd inherits the
# entrypoint's uid and doesn't drop privileges unless told to), which
# is what lets it read live iptables counters directly - same data
# fwsh needs a scoped doas rule for, because SSH sessions run as the
# unprivileged atlas user while this server was started by root.

HOSTNAME="$(cat /etc/hostname 2>/dev/null || hostname)"

# CRLF line endings in the header block, not echo's bare LF: HTTP
# requires CRLF between headers, and while browsers and curl tolerate
# LF-only, strict parsers (e.g. .NET's, behind PowerShell's
# Invoke-WebRequest) reject the whole response as a protocol violation
# - caught by direct testing from the Windows host.
printf "Content-Type: text/html; charset=utf-8\r\n\r\n"

esc() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

cat <<HDR
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta http-equiv="refresh" content="10">
<title>${HOSTNAME} - AtlasLab firewall</title>
<style>
  body { font-family: ui-monospace, Consolas, monospace; background:#111827;
         color:#e5e7eb; margin:0; padding:1.5rem; }
  h1 { font-size:1.3rem; color:#f9fafb; margin:0 0 .25rem; }
  .sub { color:#9ca3af; font-size:.8rem; margin-bottom:1.25rem; }
  h2 { font-size:.95rem; color:#93c5fd; border-bottom:1px solid #374151;
       padding-bottom:.25rem; margin:1.25rem 0 .5rem; }
  pre { background:#1f2937; border:1px solid #374151; border-radius:6px;
        padding:.75rem; overflow-x:auto; font-size:.78rem; line-height:1.45;
        margin:0; }
</style>
</head>
<body>
<h1>${HOSTNAME}</h1>
<div class="sub">AtlasLab firewall (atlaslab/firewall) &middot; read-only status
 &middot; auto-refreshes every 10s &middot; generated $(date "+%Y-%m-%d %H:%M:%S")</div>
HDR

echo "<h2>Interfaces</h2><pre>$(ip -br addr show 2>&1 | esc)</pre>"
echo "<h2>Routing table</h2><pre>$(ip route 2>&1 | esc)</pre>"
echo "<h2>Firewall rules (FORWARD chain, live counters)</h2><pre>$(iptables -L FORWARD -n -v --line-numbers 2>&1 | esc)</pre>"
echo "<h2>LLDP neighbors</h2><pre>$(lldpcli show neighbors summary 2>&1 | esc)</pre>"
echo "<h2>Startup / config-apply log (last 15 lines)</h2><pre>$(tail -n 15 /var/log/atlaslab/firewall.log 2>&1 | esc)</pre>"

echo "</body></html>"
