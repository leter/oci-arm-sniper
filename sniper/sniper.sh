#!/usr/bin/env bash
# OCI A1.Flex sniper. One attempt, or --loop until a VM is PROVISIONING.
set -euo pipefail

INTERVAL="${SNIPER_INTERVAL_SEC:-60}"
LOG_DIR="${SNIPER_LOG_DIR:-/var/log/sniper}"
OCI_CONFIG_DIR="${OCI_CONFIG_DIR:-/root/.oci}"
KEY_FILE="${OCI_API_KEY_FILE:-/run/oci/oci_api_key.pem}"
SSH_PUB_FILE="${SSH_PUB_FILE:-/run/oci/ssh.pub}"
SHAPE="${OCI_SHAPE:-VM.Standard.A1.Flex}"
OCPUS="${OCI_OCPUS:-2}"
MEMORY_GBS="${OCI_MEMORY_GBS:-12}"
BOOT_GBS="${OCI_BOOT_GBS:-50}"
DISPLAY_NAME="${OCI_DISPLAY_NAME:-oci-a1-max}"
UNEXPECTED_COOLDOWN_SEC="${UNEXPECTED_COOLDOWN_SEC:-21600}"
COOLDOWN_FILE="${LOG_DIR}/last-unexpected-notify"

mkdir -p "$LOG_DIR" "$OCI_CONFIG_DIR"

log() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG_DIR/sniper.log"
}

die() {
  log "FATAL: $*"
  exit 1
}

require_env() {
  local name
  for name in "$@"; do
    [[ -n "${!name:-}" ]] || die "missing environment variable $name"
  done
}

notify_discord() {
  local title="$1"
  local desc="$2"
  local color="${3:-3066993}"
  [[ -n "${DISCORD_WEBHOOK_URL:-}" ]] || return 0
  python3 - "$title" "$desc" "$color" "$DISCORD_WEBHOOK_URL" <<'PY' || log "WARN: Discord notify failed"
import json, sys, urllib.request, urllib.error
title, desc, color, url = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
payload = {
    "username": "OCI ARM Sniper",
    "embeds": [{
        "title": title,
        "description": desc[:1800],
        "color": color,
    }],
}
req = urllib.request.Request(
    url,
    data=json.dumps(payload).encode(),
    headers={"Content-Type": "application/json", "User-Agent": "OCI-Sniper/1.0"},
    method="POST",
)
with urllib.request.urlopen(req, timeout=20) as resp:
    resp.read()
PY
}

setup_oci() {
  require_env OCI_CLI_USER OCI_CLI_TENANCY OCI_CLI_FINGERPRINT OCI_CLI_REGION \
    OCI_COMPARTMENT_ID OCI_SUBNET_ID IMAGE_ID AD_NAME
  [[ -f "$KEY_FILE" ]] || die "API key not found at $KEY_FILE"
  [[ -f "$SSH_PUB_FILE" ]] || die "SSH public key not found at $SSH_PUB_FILE"

  cp "$KEY_FILE" "$OCI_CONFIG_DIR/oci_api_key.pem"
  chmod 600 "$OCI_CONFIG_DIR/oci_api_key.pem"
  cp "$SSH_PUB_FILE" "$OCI_CONFIG_DIR/ssh.pub"
  chmod 600 "$OCI_CONFIG_DIR/ssh.pub"

  cat > "$OCI_CONFIG_DIR/config" <<EOF
[DEFAULT]
user=${OCI_CLI_USER}
tenancy=${OCI_CLI_TENANCY}
fingerprint=${OCI_CLI_FINGERPRINT}
key_file=${OCI_CONFIG_DIR}/oci_api_key.pem
region=${OCI_CLI_REGION}
EOF
  chmod 600 "$OCI_CONFIG_DIR/config"
}

attempt() {
  local ad="${1:-$AD_NAME}"
  local output rc
  set +e
  output=$(oci compute instance launch \
    --compartment-id "$OCI_COMPARTMENT_ID" \
    --availability-domain "$ad" \
    --shape "$SHAPE" \
    --shape-config "{\"ocpus\":${OCPUS},\"memoryInGBs\":${MEMORY_GBS}}" \
    --subnet-id "$OCI_SUBNET_ID" \
    --image-id "$IMAGE_ID" \
    --ssh-authorized-keys-file "$OCI_CONFIG_DIR/ssh.pub" \
    --assign-public-ip true \
    --display-name "$DISPLAY_NAME" \
    --boot-volume-size-in-gbs "$BOOT_GBS" 2>&1)
  rc=$?

  printf '%s\n' "$output" > "$LOG_DIR/last-output.log"

  if printf '%s\n' "$output" | grep -q '"lifecycle-state": "PROVISIONING"'; then
    log "SUCCESS: instance $DISPLAY_NAME is PROVISIONING in $ad"
    notify_discord "OCI VM grabbed: $DISPLAY_NAME ($ad)" \
      "Shape ${SHAPE} ${OCPUS} OCPU / ${MEMORY_GBS} GB is PROVISIONING in ${ad}." 3066993
    return 0
  fi

  if printf '%s\n' "$output" | grep -Eqi '"code": "LimitExceeded"'; then
    local snippet
    snippet=$(printf '%s\n' "$output" | tr '\n' ' ' | head -c 400)
    log "FATAL: quota exceeded (LimitExceeded): $snippet"
    notify_discord "OCI Sniper Quota Error" "$snippet" 15158332
    return 4
  fi

  if printf '%s\n' "$output" | grep -Eqi 'Out of host capacity'; then
    log "retry [$ad]: capacity unavailable (Out of host capacity) (oci exit $rc)"
    return 2
  fi

  local snippet
  snippet=$(printf '%s\n' "$output" | tr '\n' ' ' | head -c 400)
  log "retry [$ad]: unexpected error (oci exit $rc): $snippet"
  maybe_notify_unexpected "$snippet"
  return 3
}

maybe_notify_unexpected() {
  local snippet="$1"
  local now last=0
  now=$(date +%s)
  if [[ -f "$COOLDOWN_FILE" ]]; then
    last=$(cat "$COOLDOWN_FILE" 2>/dev/null || echo 0)
  fi
  if (( now - last >= UNEXPECTED_COOLDOWN_SEC )); then
    echo "$now" > "$COOLDOWN_FILE"
    notify_discord "OCI sniper unexpected error" "$snippet" 15158332
  fi
}

run_loop() {
  local n=0 status
  IFS=', ' read -r -a ad_list <<< "$AD_NAME"
  log "starting loop interval=${INTERVAL}s shape=${SHAPE} ocpus=${OCPUS} memory=${MEMORY_GBS} name=${DISPLAY_NAME} ADs=${ad_list[*]}"
  while true; do
    for ad in "${ad_list[@]}"; do
      n=$((n + 1))
      log "attempt #$n targeting $ad"
      status=0
      attempt "$ad" || status=$?
      if [[ "$status" -eq 0 ]]; then
        log "stopping after successful launch"
        return 0
      elif [[ "$status" -eq 4 ]]; then
        log "halting loop: quota limit exceeded. Resolve in Oracle Cloud Console before resuming."
        return 1
      fi
      sleep "$INTERVAL"
    done
  done
}

usage() {
  echo "Usage: $0 [--once|--loop]" >&2
  exit 2
}

setup_oci

mode="${1:---loop}"
case "$mode" in
  --once)
    attempt
    ;;
  --loop)
    run_loop
    ;;
  *)
    usage
    ;;
esac
