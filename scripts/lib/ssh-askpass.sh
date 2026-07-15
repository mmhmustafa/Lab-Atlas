#!/usr/bin/env bash
# AtlasLab - scripts/lib/ssh-askpass.sh
#
# SSH_ASKPASS helper used by ssh_atlas_run() in scripts/lib/common.sh.
# OpenSSH invokes this (instead of prompting on a tty) whenever
# SSH_ASKPASS_REQUIRE=force is set, which is how AtlasLab drives
# password auth non-interactively without depending on sshpass (not
# part of this environment's default toolset - see docs/deployment.md).
#
# Reads the password from ATLASLAB_SSH_PASSWORD (exported by common.sh)
# rather than taking it as an argument, since ssh invokes askpass helpers
# with the prompt text as $1 and process arguments are visible to any
# other local user via `ps` - an environment variable at least keeps it
# out of the process table.
echo "${ATLASLAB_SSH_PASSWORD}"
