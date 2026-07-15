#!/usr/bin/env bash
# AtlasLab - scripts/lib/common.sh
#
# Shared helpers sourced by every script in scripts/*.sh: colored logging,
# standardized exit codes, lab-path resolution, and small dependency/tool
# checks. Keeping this in one place avoids duplicating the same 40 lines
# of bash boilerplate across six operational scripts.
#
# Not meant to be executed directly.

# --- exit codes (consistent across all AtlasLab scripts) --------------------
readonly EXIT_OK=0
readonly EXIT_GENERAL_ERROR=1
readonly EXIT_USAGE=2
readonly EXIT_MISSING_DEP=3
readonly EXIT_LAB_NOT_FOUND=4
readonly EXIT_OP_FAILED=5

# --- colors (disabled automatically when not a tty / NO_COLOR is set) -------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  readonly C_RED=$'\033[0;31m'
  readonly C_GREEN=$'\033[0;32m'
  readonly C_YELLOW=$'\033[0;33m'
  readonly C_BLUE=$'\033[0;34m'
  readonly C_BOLD=$'\033[1m'
  readonly C_RESET=$'\033[0m'
else
  readonly C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_BOLD='' C_RESET=''
fi

# --- repo/paths ---------------------------------------------------------
ATLASLAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ATLASLAB_ROOT
readonly ATLASLAB_LOG_DIR="${ATLASLAB_ROOT}/logs"
mkdir -p "${ATLASLAB_LOG_DIR}"

# Each calling script sets SCRIPT_NAME before sourcing this file's logging
# functions; fall back to the invoked filename otherwise.
SCRIPT_NAME="${SCRIPT_NAME:-$(basename "${0}")}"
LOG_FILE="${ATLASLAB_LOG_DIR}/${SCRIPT_NAME%.sh}-$(date +%Y%m%d-%H%M%S).log"
readonly LOG_FILE

_log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[${ts}] [${level}] ${msg}" >>"${LOG_FILE}"
}

log_info()    { echo "${C_BLUE}[INFO]${C_RESET}  $*"; _log INFO "$*"; }
log_warn()    { echo "${C_YELLOW}[WARN]${C_RESET}  $*" >&2; _log WARN "$*"; }
log_error()   { echo "${C_RED}[ERROR]${C_RESET} $*" >&2; _log ERROR "$*"; }
log_success() { echo "${C_GREEN}[ OK ]${C_RESET}  $*"; _log OK "$*"; }
log_step()    { echo "${C_BOLD}==>${C_RESET} $*"; _log STEP "$*"; }

die() {
  local code="${2:-$EXIT_GENERAL_ERROR}"
  log_error "$1"
  exit "$code"
}

require_cmd() {
  local cmd="$1"
  local hint="${2:-}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_error "Required command not found: ${cmd}${hint:+ (${hint})}"
    return 1
  fi
  return 0
}

# resolve_lab <lab-name> -> echoes absolute path to labs/<lab-name>,
# verifies lab.clab.yml exists. Dies with EXIT_LAB_NOT_FOUND on failure.
resolve_lab() {
  local lab="$1"
  if [[ -z "$lab" ]]; then
    die "No lab name given. Available labs: $(list_labs | tr '\n' ' ')" "$EXIT_USAGE"
  fi
  local lab_dir="${ATLASLAB_ROOT}/labs/${lab}"
  local topo_file="${lab_dir}/lab.clab.yml"
  if [[ ! -f "$topo_file" ]]; then
    die "Lab '${lab}' not found (expected ${topo_file}). Available labs: $(list_labs | tr '\n' ' ')" "$EXIT_LAB_NOT_FOUND"
  fi
  echo "$lab_dir"
}

list_labs() {
  find "${ATLASLAB_ROOT}/labs" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort
}

# clab_name <lab-name> -> the containerlab "name:" field, i.e. the prefix
# used for container names (clab-<name>-<node>). AtlasLab always names
# labs atlas-<lab-dir>, matching what generate-configs.py / hand-written
# lab.clab.yml files use.
clab_name() {
  local lab="$1"
  local topo_file="${ATLASLAB_ROOT}/labs/${lab}/lab.clab.yml"
  grep -m1 '^name:' "$topo_file" | sed -E 's/^name:[[:space:]]*//'
}

# containerlab_bin -> "containerlab", after confirming it's on PATH.
containerlab_bin() {
  require_cmd containerlab "install from https://containerlab.dev" || return "$EXIT_MISSING_DEP"
  echo "containerlab"
}

# node_list <lab-name> -> newline-separated container node names (short,
# without the clab-<lab>- prefix), read from the rendered topology file.
node_list() {
  local lab="$1"
  local topo_file="${ATLASLAB_ROOT}/labs/${lab}/lab.clab.yml"
  python3 - "$topo_file" <<'PYEOF'
import sys, yaml
with open(sys.argv[1]) as f:
    topo = yaml.safe_load(f)
for n in sorted(topo["topology"]["nodes"]):
    print(n)
PYEOF
}

print_help_header() {
  echo "${C_BOLD}AtlasLab${C_RESET} - $1"
  echo
}

# --- SSH management access ---------------------------------------------
# Credentials for the "atlas" SSH management account baked into every
# atlaslab/frr node - see docker/frr-atlaslab/Dockerfile and
# docs/atlas-integration.md. Static and documented deliberately: this is
# a local, ephemeral lab network (containerlab's own Docker bridge, not
# exposed beyond the host), not a production fleet.
ATLASLAB_SSH_USER="atlas"
ATLASLAB_SSH_PASSWORD="AtlasLab123!"
export ATLASLAB_SSH_USER ATLASLAB_SSH_PASSWORD
readonly ATLASLAB_SSH_USER ATLASLAB_SSH_PASSWORD
readonly ATLASLAB_SSH_ASKPASS="${ATLASLAB_ROOT}/scripts/lib/ssh-askpass.sh"

# lab_mgmt_ips <lab-name> -> "node ip" lines, one per currently deployed
# node, read from containerlab's own inspect JSON (never re-implements
# Docker network introspection). Empty output if the lab isn't deployed.
#
# Delegates to scripts/lib/lab_mgmt_ips.py (a real file, not an inline
# heredoc): this needs the piped JSON on stdin *and* an argv prefix, and
# `python3 - <<PYEOF ... PYEOF` can't do both at once - the heredoc
# redirect wins control of stdin over the pipe, so the piped JSON never
# reaches the script (json.load(sys.stdin) sees EOF immediately). This
# silently broke every caller until caught by direct testing.
lab_mgmt_ips() {
  local lab="$1"
  local cname prefix
  cname="$(clab_name "$lab")"
  prefix="clab-${cname}-"
  ( cd "${ATLASLAB_ROOT}/labs/${lab}" && containerlab inspect -t lab.clab.yml -f json 2>/dev/null ) \
    | python3 "${ATLASLAB_ROOT}/scripts/lib/lab_mgmt_ips.py" "$prefix"
}

# ssh_atlas_run <mgmt-ip> <remote-command...> - runs a command on a node
# over SSH as the atlas management user, using password auth driven via
# SSH_ASKPASS (see scripts/lib/ssh-askpass.sh) rather than sshpass, which
# isn't part of this environment's default toolset. setsid detaches from
# any controlling tty so ssh has no fallback but to use the askpass
# helper; SSH_ASKPASS_REQUIRE=force is the belt-and-braces version of the
# same thing on OpenSSH >= 8.4.
ssh_atlas_run() {
  local host="$1"; shift
  SSH_ASKPASS="$ATLASLAB_SSH_ASKPASS" SSH_ASKPASS_REQUIRE=force \
    setsid ssh -o StrictHostKeyChecking=no \
               -o UserKnownHostsFile=/dev/null \
               -o LogLevel=ERROR \
               -o PreferredAuthentications=password \
               -o PubkeyAuthentication=no \
               -o ConnectTimeout=5 \
               -o BatchMode=no \
               "${ATLASLAB_SSH_USER}@${host}" "$@" </dev/null
}
