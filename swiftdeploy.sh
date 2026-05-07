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
  local policy_image policy_port policy_dir

  svc_image=$(mf '.services.image')
  svc_port=$(mf '.services.port')
  svc_mode=$(mf '.services.mode')
  svc_version=$(mf '.services.version')
  nginx_image=$(mf '.nginx.image')
  nginx_port=$(mf '.nginx.port')
  proxy_timeout=$(mf '.nginx.proxy_timeout')
  net_name=$(mf '.network.name')
  net_driver=$(mf '.network.driver_type')
  policy_image=$(mf '.policy_engine.image')
  policy_port=$(mf '.policy_engine.port')
  policy_dir=$(mf '.policy_engine.policy_dir')

  # Derive the short image name (strip tag) for error pages
  local svc_image_name
  svc_image_name="${svc_image%%:*}"

  # Derive container service name from compose convention (service)
  local svc_container_name="service_backend"

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
    -e "s|POLICY_IMAGE|${policy_image}|g" \
    -e "s|POLICY_PORT|${policy_port}|g" \
    -e "s|POLICY_DIR|${policy_dir}|g" \
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
    '.policy_engine.image'
    '.policy_engine.port'
    '.policy_engine.policy_dir'
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
  # Check 5: nginx.conf syntax valid
  if [[ -f "$NGINX_CONF" ]]; then
      nginx_err=$(nginx -t -c "$(pwd)/$NGINX_CONF" 2>&1)
      if echo "$nginx_err" | grep -q "syntax is ok"; then
          log "validate" "Check 5: $NGINX_CONF syntax is valid ✅ PASS"
      else
          log "validate" "Check 5: $NGINX_CONF syntax invalid ❌ FAIL"
          echo "$nginx_err"   # <-- shows you the exact error
          all_pass=false
      fi
  else
      log "validate" "Check 5: $NGINX_CONF missing ❌ FAIL"
      all_pass=false
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

  log "deploy" "Starting OPA to evaluate pre-deploy policies..."
  docker compose -f "$COMPOSE_FILE" up -d policy_engine
  sleep 2

  log "deploy" "Running pre-deploy infrastructure check..."
  if ! cmd_check_infrastructure; then
      docker compose -f "$COMPOSE_FILE" down 2>/dev/null
      die "Pre-deploy infrastructure check failed."
  fi

  log "deploy" "Starting remaining stack with docker compose..."
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

  if [[ "$new_mode" == "stable" ]]; then
      log "promote" "Running pre-promote canary health check..."
      cmd_check_canary || die "Pre-promote check failed. Canary is unhealthy."
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

# Pre-deploy check
cmd_check_infrastructure() {
    local disk_free cpu_load mem_free
    disk_free=$(df -BG / | awk 'NR==2{gsub("G","",$4); print $4}')
    cpu_load=$(awk '{print $1}' /proc/loadavg)
    mem_free=$(free -g | awk '/^Mem/{print $4}')

    local input
    input=$(cat <<EOF
{
  "input": {
    "disk_free_gb": $disk_free,
    "cpu_load": $cpu_load,
    "mem_free_gb": $mem_free,
    "check_type": "pre-deploy"
  }
}
EOF
)
    local opa_port
    opa_port=$(mf '.policy_engine.port')

    local result
    result=$(curl -sf -X POST \
        -H "Content-Type: application/json" \
        -d "$input" \
        "http://localhost:${opa_port}/v1/data/infrastructure" 2>/dev/null) || {
        log "policy" "⚠️  OPA unavailable — cannot enforce infrastructure policy" >&2
        return 1
    }

    local allowed reasons
    allowed=$(echo "$result" | jq -r '.result.allow // false')
    reasons=$(echo "$result" | jq -r '.result.deny_reasons[]? // empty')

    if [[ "$allowed" == "true" ]]; then
        log "policy" "✅ Infrastructure policy: PASS"
    else
        log "policy" "❌ Infrastructure policy: BLOCKED"
        echo "$reasons" | while read -r r; do
            log "policy" "   → $r"
        done
        return 1
    fi
}


cmd_check_canary() {
    local nginx_port
    nginx_port=$(mf '.nginx.port')
    
    local metrics
    metrics=$(curl -sf "http://localhost:${nginx_port}/metrics" 2>/dev/null) || {
        log "policy" "⚠️  Could not scrape metrics for pre-promote check."
        return 0
    }
    
    local input
    input=$(python3 -c '
import sys, json

lines = sys.stdin.read().split("\n")
total = 0.0
errors = 0.0
buckets = []
count = 0

for line in lines:
    if line.startswith("http_requests_total{"):
        try:
            val = float(line.split(" ")[-1])
            total += val
            if "status_code=\"5" in line:
                errors += val
        except: pass
    elif line.startswith("http_request_duration_seconds_bucket{"):
        try:
            le_str = line.split("le=\"")[1].split("\"")[0]
            val = float(line.split(" ")[-1])
            if le_str != "+Inf":
                buckets.append((float(le_str), val))
            else:
                count = val
        except: pass

buckets.sort()
error_rate = errors / total if total > 0 else 0.0

p99_latency_ms = 0
if count > 0:
    target = count * 0.99
    for le, bval in buckets:
        if bval >= target:
            p99_latency_ms = int(le * 1000)
            break
    if p99_latency_ms == 0 and buckets:
        p99_latency_ms = int(buckets[-1][0] * 1000)

print(json.dumps({
    "input": {
        "error_rate": error_rate,
        "p99_latency_ms": p99_latency_ms,
        "check_type": "pre-promote"
    }
}))
' <<< "$metrics")

    local opa_port
    opa_port=$(mf '.policy_engine.port')

    local result
    result=$(curl -sf -X POST \
        -H "Content-Type: application/json" \
        -d "$input" \
        "http://localhost:${opa_port}/v1/data/canary" 2>/dev/null) || {
        log "policy" "⚠️  OPA unavailable — cannot enforce canary policy" >&2
        return 1
    }

    local allowed reasons
    allowed=$(echo "$result" | jq -r '.result.allow // false')
    reasons=$(echo "$result" | jq -r '.result.deny_reasons[]? // empty')

    if [[ "$allowed" == "true" ]]; then
        log "policy" "✅ Canary policy: PASS"
    else
        log "policy" "❌ Canary policy: BLOCKED"
        echo "$reasons" | while read -r r; do
            log "policy" "   → $r"
        done
        return 1
    fi
}

cmd_status() {
    local nginx_port opa_port
    nginx_port=$(mf '.nginx.port')
    opa_port=$(mf '.policy_engine.port')
    
    echo "Starting status dashboard. Press Ctrl+C to stop."
    
    local prev_reqs=0
    local prev_time=$(date +%s)
    
    while true; do
        clear
        echo "═══════════════════════════════════════"
        echo "  SwiftDeploy Status — $(date)"
        echo "═══════════════════════════════════════"
        
        local metrics
        metrics=$(curl -sf "http://localhost:${nginx_port}/metrics" 2>/dev/null || echo "")
        
        if [[ -z "$metrics" ]]; then
            echo "Service unreachable."
            sleep 5
            continue
        fi
        
        local parsed
        parsed=$(python3 -c '
import sys, json

lines = sys.stdin.read().split("\n")
total = 0.0
errors = 0.0
uptime = 0.0
mode = 0.0
chaos = 0.0
buckets = []
count = 0

for line in lines:
    if line.startswith("http_requests_total{"):
        try:
            val = float(line.split(" ")[-1])
            total += val
            if "status_code=\"5" in line:
                errors += val
        except: pass
    elif line.startswith("http_request_duration_seconds_bucket{"):
        try:
            le_str = line.split("le=\"")[1].split("\"")[0]
            val = float(line.split(" ")[-1])
            if le_str != "+Inf":
                buckets.append((float(le_str), val))
            else:
                count = val
        except: pass
    elif line.startswith("app_uptime_seconds "):
        try: uptime = float(line.split(" ")[-1])
        except: pass
    elif line.startswith("app_mode "):
        try: mode = float(line.split(" ")[-1])
        except: pass
    elif line.startswith("chaos_active "):
        try: chaos = float(line.split(" ")[-1])
        except: pass

buckets.sort()
error_rate = errors / total if total > 0 else 0.0

p99_latency_ms = 0
if count > 0:
    target = count * 0.99
    for le, bval in buckets:
        if bval >= target:
            p99_latency_ms = int(le * 1000)
            break
    if p99_latency_ms == 0 and buckets:
        p99_latency_ms = int(buckets[-1][0] * 1000)

print(json.dumps({
    "total_reqs": total,
    "error_rate": error_rate,
    "p99_latency_ms": p99_latency_ms,
    "uptime": uptime,
    "mode": mode,
    "chaos": chaos
}))
' <<< "$metrics")

        local total_reqs=$(echo "$parsed" | jq -r '.total_reqs')
        local error_rate=$(echo "$parsed" | jq -r '.error_rate')
        local p99=$(echo "$parsed" | jq -r '.p99_latency_ms')
        local uptime=$(echo "$parsed" | jq -r '.uptime')
        local mode_val=$(echo "$parsed" | jq -r '.mode')
        local chaos_val=$(echo "$parsed" | jq -r '.chaos')
        
        local mode_str="stable"
        [[ "$mode_val" == "1.0" ]] && mode_str="canary"
        local chaos_str="none"
        [[ "$chaos_val" == "1.0" ]] && chaos_str="slow"
        [[ "$chaos_val" == "2.0" ]] && chaos_str="error"
        
        local cur_time=$(date +%s)
        local time_diff=$((cur_time - prev_time))
        [[ $time_diff -eq 0 ]] && time_diff=1
        
        local reqs_diff=$(echo "$total_reqs - $prev_reqs" | bc -l)
        local rps=$(echo "scale=2; $reqs_diff / $time_diff" | bc -l)
        
        prev_reqs=$total_reqs
        prev_time=$cur_time
        
        echo "Uptime:   ${uptime}s"
        echo "Mode:     ${mode_str}"
        echo "Chaos:    ${chaos_str}"
        echo "Req/s:    ${rps}"
        echo "P99 Lat:  ${p99}ms"
        echo "Errors:   $(echo "scale=2; $error_rate * 100" | bc -l)%"
        echo ""
        echo "--- Policy Compliance ---"
        
        local disk_free=$(df -BG / | awk 'NR==2{gsub("G","",$4); print $4}')
        local cpu_load=$(awk '{print $1}' /proc/loadavg)
        local mem_free=$(free -g | awk '/^Mem/{print $4}')
        
        local infra_res=$(curl -sf -X POST -H "Content-Type: application/json" \
            -d "{\"input\": {\"disk_free_gb\": $disk_free, \"cpu_load\": $cpu_load, \"mem_free_gb\": $mem_free}}" \
            "http://localhost:${opa_port}/v1/data/infrastructure" 2>/dev/null)
        
        if [[ -n "$infra_res" ]]; then
            local infra_allow=$(echo "$infra_res" | jq -r '.result.allow // false')
            if [[ "$infra_allow" == "true" ]]; then
                echo "✅ Infrastructure Policy: PASS"
            else
                echo "❌ Infrastructure Policy: FAIL"
            fi
        else
            echo "⚠️  Infrastructure Policy: OPA UNREACHABLE"
        fi
        
        local canary_res=$(curl -sf -X POST -H "Content-Type: application/json" \
            -d "{\"input\": {\"error_rate\": $error_rate, \"p99_latency_ms\": $p99}}" \
            "http://localhost:${opa_port}/v1/data/canary" 2>/dev/null)
            
        if [[ -n "$canary_res" ]]; then
            local canary_allow=$(echo "$canary_res" | jq -r '.result.allow // false')
            if [[ "$canary_allow" == "true" ]]; then
                echo "✅ Canary Policy: PASS"
            else
                echo "❌ Canary Policy: FAIL"
            fi
        else
            echo "⚠️  Canary Policy: OPA UNREACHABLE"
        fi
        
        local timestamp=$(date -u +%FT%TZ)
        local entry="{\"timestamp\":\"$timestamp\",\"mode\":\"$mode_str\",\"chaos\":\"$chaos_str\",\"rps\":$rps,\"p99_ms\":$p99,\"error_rate\":$error_rate}"
        echo "$entry" >> history.jsonl
        
        sleep 5
    done
}

cmd_audit() {
    log "audit" "Generating audit_report.md..."
    
    if [[ ! -f "history.jsonl" ]]; then
        die "No history.jsonl found. Run 'swiftdeploy status' first."
    fi
    
    cat > audit_report.md << 'EOF'
# SwiftDeploy Audit Report

## Timeline

| Timestamp | Mode | Chaos Active | Req/s | P99 (ms) | Error Rate |
|-----------|------|--------------|-------|----------|------------|
EOF

    jq -r '"| \(.timestamp) | \(.mode) | \(.chaos) | \(.rps) | \(.p99_ms) | \((.error_rate * 100 * 100 | round) / 100)% |"' history.jsonl >> audit_report.md
    
    cat >> audit_report.md << 'EOF'

## Violations

*Note: In this basic implementation, violations are recorded if error rate exceeds 1% or P99 exceeds 500ms based on historical records.*

EOF

    jq -r 'if .error_rate > 0.01 or .p99_ms > 500 then "- \(.timestamp): Violation detected! Error rate: \((.error_rate * 100 * 100 | round) / 100)%, P99: \(.p99_ms)ms (Mode: \(.mode), Chaos: \(.chaos))" else empty end' history.jsonl >> audit_report.md
    
    log "audit" "✅ audit_report.md generated successfully."
}

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
  status)    cmd_status    "$@" ;;
  audit)     cmd_audit     "$@" ;;
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
    echo "  status            Live dashboard of metrics and policy compliance"
    echo "  audit             Generate audit_report.md from history.jsonl"
    echo "  teardown [--clean] Stop and remove all containers/volumes"
    exit 0
    ;;
  *)
    die "Unknown subcommand: '$SUBCOMMAND'. Run ./swiftdeploy for help."
    ;;
esac
