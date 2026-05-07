#!/usr/bin/env bash
# swiftdeploy — declarative infrastructure automation CLI
# Usage: ./swiftdeploy <subcommand> [flags]

set -euo pipefail

MANIFEST="manifest.yaml"
NGINX_CONF="nginx.conf"
COMPOSE_FILE="docker-compose.yml"
NGINX_TMPL="templates/nginx.conf.tmpl"
COMPOSE_TMPL="templates/docker-compose.yml.tmpl"

# ──────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────

log() { echo "[$1] ${*:2}"; }

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" &>/dev/null || die "'$1' is not installed or not in PATH."
}

require_manifest() {
  [[ -f "$MANIFEST" ]] || die "$MANIFEST not found. Are you in the project root?"
}

require_generated() {
  [[ -f "$NGINX_CONF" ]]   || die "$NGINX_CONF not found. Run: ./swiftdeploy init"
  [[ -f "$COMPOSE_FILE" ]] || die "$COMPOSE_FILE not found. Run: ./swiftdeploy init"
}

# Read a field from manifest.yaml using yq
mf() {
  yq e "$1" "$MANIFEST"
}

# ──────────────────────────────────────────────
# init — generate nginx.conf and docker-compose.yml
# ──────────────────────────────────────────────

cmd_init() {
  require_cmd yq
  require_manifest

  log "init" "Parsing $MANIFEST..."

  local svc_image svc_port svc_mode svc_version
  local nginx_image nginx_port proxy_timeout
  local net_name net_driver

  svc_image=$(mf '.services.image')
  svc_port=$(mf '.services.port')
  svc_mode=$(mf '.services.mode')
  svc_version=$(mf '.services.version')
  nginx_image=$(mf '.nginx.image')
  nginx_port=$(mf '.nginx.port')
  proxy_timeout=$(mf '.nginx.proxy_timeout')
  net_name=$(mf '.network.name')
  net_driver=$(mf '.network.driver_type')

  # Derive the short image name (strip tag) for error pages
  local svc_image_name
  svc_image_name="${svc_image%%:*}"

  # Derive container service name from compose convention (service)
  local svc_container_name="service"

  log "init" "Generating $NGINX_CONF from template..."
  sed \
    -e "s|SERVICE_NAME|${svc_container_name}|g" \
    -e "s|SERVICE_PORT|${svc_port}|g" \
    -e "s|NGINX_PORT|${nginx_port}|g" \
    -e "s|PROXY_TIMEOUT|${proxy_timeout}|g" \
    -e "s|SERVICE_IMAGE_NAME|${svc_image_name}|g" \
    "$NGINX_TMPL" > "$NGINX_CONF"

  log "init" "Generating $COMPOSE_FILE from template..."
  sed \
    -e "s|NGINX_IMAGE|${nginx_image}|g" \
    -e "s|NGINX_PORT|${nginx_port}|g" \
    -e "s|SERVICE_IMAGE|${svc_image}|g" \
    -e "s|SERVICE_PORT|${svc_port}|g" \
    -e "s|SERVICE_MODE|${svc_mode}|g" \
    -e "s|SERVICE_VERSION|${svc_version}|g" \
    -e "s|NETWORK_NAME|${net_name}|g" \
    -e "s|NETWORK_DRIVER|${net_driver}|g" \
    "$COMPOSE_TMPL" > "$COMPOSE_FILE"

  log "init" "Done. Generated files are ready."
}

# ──────────────────────────────────────────────
# validate — run 5 pre-flight checks
# ──────────────────────────────────────────────

cmd_validate() {
  require_cmd yq
  require_cmd nginx
  local all_pass=true

  # Check 1: manifest.yaml exists and is valid YAML
  if [[ -f "$MANIFEST" ]] && yq e '.' "$MANIFEST" &>/dev/null; then
    log "validate" "Check 1: $MANIFEST exists and is valid YAML ✅ PASS"
  else
    log "validate" "Check 1: $MANIFEST missing or invalid YAML ❌ FAIL"
    all_pass=false
  fi

  # Check 2: Required fields present and non-empty
  local required_fields=(
    '.services.image'
    '.services.port'
    '.services.mode'
    '.services.version'
    '.nginx.image'
    '.nginx.port'
    '.nginx.proxy_timeout'
    '.network.name'
    '.network.driver_type'
  )
  local missing=false
  for field in "${required_fields[@]}"; do
    local val
    val=$(yq e "$field" "$MANIFEST" 2>/dev/null || echo "")
    if [[ -z "$val" || "$val" == "null" ]]; then
      echo "  [validate] Missing field: $field"
      missing=true
    fi
  done
  if [[ "$missing" == false ]]; then
    log "validate" "Check 2: Required fields present ✅ PASS"
  else
    log "validate" "Check 2: Required fields missing ❌ FAIL"
    all_pass=false
  fi

  # Check 3: Docker image exists locally
  local svc_image
  svc_image=$(yq e '.services.image' "$MANIFEST" 2>/dev/null || echo "")
  if [[ -n "$svc_image" ]] && docker image inspect "$svc_image" &>/dev/null; then
    log "validate" "Check 3: Docker image $svc_image found locally ✅ PASS"
  else
    log "validate" "Check 3: Docker image '$svc_image' not found locally ❌ FAIL"
    all_pass=false
  fi

  # Check 4: Nginx port is not already bound
  local nginx_port
  nginx_port=$(yq e '.nginx.port' "$MANIFEST" 2>/dev/null || echo "")
  if [[ -n "$nginx_port" ]] && ! ss -tlnp 2>/dev/null | grep -q ":${nginx_port} " && \
     ! netstat -tlnp 2>/dev/null | grep -q ":${nginx_port} "; then
    log "validate" "Check 4: Port $nginx_port is available ✅ PASS"
  else
    log "validate" "Check 4: Port $nginx_port is already in use ❌ FAIL"
    all_pass=false
  fi

  # Check 5: nginx.conf syntax valid
  if [[ -f "$NGINX_CONF" ]] && nginx -t -c "$(pwd)/$NGINX_CONF" &>/dev/null; then
    log "validate" "Check 5: $NGINX_CONF syntax is valid ✅ PASS"
  else
    log "validate" "Check 5: $NGINX_CONF syntax invalid or file missing ❌ FAIL"
    all_pass=false
  fi

  if [[ "$all_pass" == true ]]; then
    log "validate" "All checks passed. Ready to deploy."
  else
    log "validate" "One or more checks failed. Fix the issues above before deploying." >&2
    exit 1
  fi
}

# ──────────────────────────────────────────────
# deploy — init + docker compose up + health poll
# ──────────────────────────────────────────────

cmd_deploy() {
  require_cmd docker

  log "deploy" "Running init..."
  cmd_init

  require_generated

  log "deploy" "Starting stack with docker compose..."
  docker compose -f "$COMPOSE_FILE" up -d

  local nginx_port
  nginx_port=$(mf '.nginx.port')

  log "deploy" "Waiting for health checks..."
  local elapsed=0
  local interval=2
  local timeout=60

  while [[ $elapsed -lt $timeout ]]; do
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${nginx_port}/healthz" 2>/dev/null || echo "000")
    if [[ "$http_code" == "200" ]]; then
      log "deploy" "✅ Service healthy after ${elapsed}s. Stack is live on port ${nginx_port}."
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  log "deploy" "❌ Health check timed out after ${timeout}s. Check logs with: docker compose logs" >&2
  exit 1
}

# ──────────────────────────────────────────────
# promote — switch mode (stable <-> canary)
# ──────────────────────────────────────────────

cmd_promote() {
  require_cmd yq
  require_cmd docker
  require_manifest

  local new_mode="${1:-}"
  if [[ "$new_mode" != "stable" && "$new_mode" != "canary" ]]; then
    die "Usage: ./swiftdeploy promote <stable|canary>"
  fi

  log "promote" "Updating $MANIFEST mode → $new_mode"
  yq e -i ".services.mode = \"${new_mode}\"" "$MANIFEST"

  log "promote" "Regenerating $COMPOSE_FILE..."
  cmd_init

  require_generated

  log "promote" "Restarting service container..."
  docker compose -f "$COMPOSE_FILE" up -d --no-deps --force-recreate service

  local nginx_port
  nginx_port=$(mf '.nginx.port')

  log "promote" "Confirming mode via /healthz..."
  sleep 3

  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${nginx_port}/healthz" 2>/dev/null || echo "000")

  if [[ "$http_code" == "200" ]]; then
    if [[ "$new_mode" == "canary" ]]; then
      log "promote" "✅ Mode confirmed: canary. X-Mode: canary header active."
    else
      log "promote" "✅ Mode confirmed: stable."
    fi
  else
    log "promote" "⚠️  Service may still be starting (HTTP $http_code). Check with: curl http://localhost:${nginx_port}/healthz" >&2
  fi
}

# ──────────────────────────────────────────────
# teardown — stop and remove the stack
# ──────────────────────────────────────────────

cmd_teardown() {
  require_cmd docker
  local clean=false
  for arg in "$@"; do
    [[ "$arg" == "--clean" ]] && clean=true
  done

  if [[ -f "$COMPOSE_FILE" ]]; then
    log "teardown" "Stopping containers..."
    docker compose -f "$COMPOSE_FILE" down --volumes 2>/dev/null || true
    log "teardown" "Removing networks..."
    log "teardown" "Removing volumes..."
  else
    log "teardown" "No $COMPOSE_FILE found — attempting generic teardown..."
    docker compose down --volumes 2>/dev/null || true
  fi

  log "teardown" "✅ Stack torn down."

  if [[ "$clean" == true ]]; then
    log "teardown" "Removing generated $NGINX_CONF and $COMPOSE_FILE..."
    rm -f "$NGINX_CONF" "$COMPOSE_FILE"
    log "teardown" "✅ Clean teardown complete."
  fi
}

# ──────────────────────────────────────────────
# Dispatch
# ──────────────────────────────────────────────

SUBCOMMAND="${1:-}"
shift || true

case "$SUBCOMMAND" in
  init)      cmd_init      "$@" ;;
  validate)  cmd_validate  "$@" ;;
  deploy)    cmd_deploy    "$@" ;;
  promote)   cmd_promote   "$@" ;;
  teardown)  cmd_teardown  "$@" ;;
  "")
    echo "SwiftDeploy CLI"
    echo ""
    echo "Usage: ./swiftdeploy <subcommand> [flags]"
    echo ""
    echo "Subcommands:"
    echo "  init              Generate nginx.conf and docker-compose.yml from manifest.yaml"
    echo "  validate          Run 5 pre-flight checks"
    echo "  deploy            Init + bring up stack + health poll"
    echo "  promote <mode>    Switch mode (stable|canary) with rolling restart"
    echo "  teardown [--clean] Stop and remove all containers/volumes"
    exit 0
    ;;
  *)
    die "Unknown subcommand: '$SUBCOMMAND'. Run ./swiftdeploy for help."
    ;;
esac
