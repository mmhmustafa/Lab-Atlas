#!/usr/bin/env bash
# AtlasLab - scripts/verify-environment.sh
#
# Checks that the local host is ready to deploy AtlasLab topologies:
# Docker daemon reachable, containerlab installed, the frrouting/frr
# image present, Python3 + PyYAML/Jinja2 for the config generator, and
# that the current user can run docker/containerlab without sudo.
#
# Usage:
#   scripts/verify-environment.sh [-h|--help]
#
# Exit codes:
#   0  all checks passed
#   1  one or more checks failed
#   2  usage error
set -euo pipefail

SCRIPT_NAME="verify-environment"
# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

usage() {
  print_help_header "verify the local environment is ready to deploy labs"
  cat <<EOF
Usage:
  $(basename "$0") [-h|--help]

Checks performed:
  - docker CLI present and daemon reachable
  - current user can run docker without sudo
  - containerlab CLI present, and its version
  - frrouting/frr:latest image present locally (pulls it if missing)
  - python3 present with pyyaml + jinja2 (used by scripts/generate-configs.py)
  - required core utilities: git, ping, sudo, tar
  - repository directory structure present

Exit codes:
  0  all checks passed
  1  one or more checks failed
  2  usage error
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit "$EXIT_OK"
elif [[ $# -gt 0 ]]; then
  log_error "Unknown argument: $1"
  usage >&2
  exit "$EXIT_USAGE"
fi

log_step "Verifying AtlasLab environment"

FAILURES=0
PASSES=0

check() {
  local description="$1"
  local status="$2"   # 0 = pass
  local detail="${3:-}"
  if [[ "$status" -eq 0 ]]; then
    log_success "${description}${detail:+ (${detail})}"
    PASSES=$((PASSES + 1))
  else
    log_error "${description}${detail:+ - ${detail}}"
    FAILURES=$((FAILURES + 1))
  fi
}

# --- docker -------------------------------------------------------------
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    ver="$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown)"
    check "Docker daemon reachable" 0 "server ${ver}"
  else
    check "Docker daemon reachable" 1 "docker info failed - is the daemon running / are you in the docker group?"
  fi
else
  check "Docker CLI installed" 1 "docker not found on PATH"
fi

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  if groups 2>/dev/null | grep -qw docker || [[ "$(id -u)" -eq 0 ]]; then
    check "Docker usable without sudo" 0
  else
    check "Docker usable without sudo" 1 "current user is not in the 'docker' group"
  fi
fi

# --- containerlab ---------------------------------------------------------
if command -v containerlab >/dev/null 2>&1; then
  clab_ver="$(containerlab version 2>/dev/null | grep -m1 'version:' | awk '{print $2}')"
  check "containerlab installed" 0 "${clab_ver:-unknown version}"
else
  check "containerlab installed" 1 "not found on PATH - install from https://containerlab.dev"
fi

# --- frrouting/frr image -------------------------------------------------
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  if docker image inspect frrouting/frr:latest >/dev/null 2>&1; then
    check "frrouting/frr:latest image present" 0
  else
    log_warn "frrouting/frr:latest not found locally, attempting to pull..."
    if docker pull frrouting/frr:latest >>"${LOG_FILE}" 2>&1; then
      check "frrouting/frr:latest image present" 0 "pulled"
    else
      check "frrouting/frr:latest image present" 1 "pull failed, check internet connectivity"
    fi
  fi

  if docker image inspect atlaslab/frr:latest >/dev/null 2>&1; then
    check "atlaslab/frr:latest image present" 0
  else
    log_warn "atlaslab/frr:latest not found locally, building it (adds lldpd to frrouting/frr)..."
    if docker build -t atlaslab/frr:latest "${ATLASLAB_ROOT}/docker/frr-atlaslab" >>"${LOG_FILE}" 2>&1; then
      check "atlaslab/frr:latest image present" 0 "built"
    else
      check "atlaslab/frr:latest image present" 1 "build failed - see ${LOG_FILE}"
    fi
  fi
fi

# --- python3 + generator deps --------------------------------------------
if command -v python3 >/dev/null 2>&1; then
  pyver="$(python3 --version 2>&1 | awk '{print $2}')"
  check "python3 installed" 0 "$pyver"
  if python3 -c "import yaml, jinja2" >/dev/null 2>&1; then
    check "python3 pyyaml + jinja2 available" 0
  else
    check "python3 pyyaml + jinja2 available" 1 "run: pip3 install pyyaml jinja2"
  fi
else
  check "python3 installed" 1 "required by scripts/generate-configs.py"
fi

# --- core utilities --------------------------------------------------------
for tool in git ping tar; do
  if command -v "$tool" >/dev/null 2>&1; then
    check "'${tool}' available" 0
  else
    check "'${tool}' available" 1 "not found on PATH"
  fi
done

# --- repo structure ---------------------------------------------------------
for dir in labs scripts inventory templates configs docs; do
  if [[ -d "${ATLASLAB_ROOT}/${dir}" ]]; then
    check "Repository directory '${dir}/' present" 0
  else
    check "Repository directory '${dir}/' present" 1 "expected ${ATLASLAB_ROOT}/${dir}"
  fi
done

echo
log_step "Summary: ${PASSES} passed, ${FAILURES} failed"
echo "Full log: ${LOG_FILE}"

if [[ "$FAILURES" -gt 0 ]]; then
  exit "$EXIT_GENERAL_ERROR"
fi
exit "$EXIT_OK"
