#!/bin/sh
set -e

CONFIG_FILE="/data/config.yaml"
REGISTRATION_FILE="/data/registration.yaml"
TEMPLATE_DIR="/config-template"
SYNAPSE_APPSERVICES_DIR="/synapse-appservices"

# Ensure tokens are set (reuse from existing config if present, else generate). Multiple fallbacks for robustness.
gen_token() {
  t=""
  if command -v openssl >/dev/null 2>&1; then
    t=$(openssl rand -base64 43 2>/dev/null | tr -d '\n/+=' | head -c 64)
  fi
  if [ -z "$t" ] && command -v python3 >/dev/null 2>&1; then
    t=$(python3 -c 'import secrets; print(secrets.token_urlsafe(43))' 2>/dev/null | tr -d '\n' | head -c 64)
  fi
  if [ -z "$t" ]; then
    t=$(head -c 48 /dev/urandom 2>/dev/null | base64 2>/dev/null | tr -d '\n/+=' | head -c 64)
  fi
  echo "$t"
}
if [ -z "$WHATSAPP_AS_TOKEN" ] || [ -z "$WHATSAPP_HS_TOKEN" ]; then
    if [ -f "$CONFIG_FILE" ] && grep -qE 'as_token:\s*[A-Za-z0-9_-]{20,}' "$CONFIG_FILE" 2>/dev/null; then
        echo "Reusing tokens from existing config..."
        WHATSAPP_AS_TOKEN=$(grep '^  as_token:' "$CONFIG_FILE" | sed 's/.*: *//' | tr -d ' "\047')
        WHATSAPP_HS_TOKEN=$(grep '^  hs_token:' "$CONFIG_FILE" | sed 's/.*: *//' | tr -d ' "\047')
        export WHATSAPP_AS_TOKEN WHATSAPP_HS_TOKEN
    else
        echo "WHATSAPP_AS_TOKEN and/or WHATSAPP_HS_TOKEN not set. Generating..."
        WHATSAPP_AS_TOKEN="${WHATSAPP_AS_TOKEN:-$(gen_token)}"
        WHATSAPP_HS_TOKEN="${WHATSAPP_HS_TOKEN:-$(gen_token)}"
        if [ -z "$WHATSAPP_AS_TOKEN" ] || [ -z "$WHATSAPP_HS_TOKEN" ]; then
            echo "FATAL: Could not generate tokens. Install openssl or ensure /dev/urandom is available."
            exit 1
        fi
        export WHATSAPP_AS_TOKEN WHATSAPP_HS_TOKEN
    fi
fi

# Provisioning secret: persist once so restarts don't rotate it.
PROVISIONING_SECRET_FILE="/data/.provisioning_secret"
if [ -z "${WHATSAPP_PROVISIONING_SECRET:-}" ]; then
    if [ -f "$PROVISIONING_SECRET_FILE" ]; then
        WHATSAPP_PROVISIONING_SECRET=$(cat "$PROVISIONING_SECRET_FILE")
    else
        WHATSAPP_PROVISIONING_SECRET=$(gen_token)
        echo "$WHATSAPP_PROVISIONING_SECRET" > "$PROVISIONING_SECRET_FILE"
        chmod 600 "$PROVISIONING_SECRET_FILE"
    fi
fi
export WHATSAPP_PROVISIONING_SECRET

echo "Generating config from template..."
envsubst '${WHATSAPP_AS_TOKEN} ${WHATSAPP_HS_TOKEN} ${WHATSAPP_PROVISIONING_SECRET} ${MULTICHAT_BRIDGE_STATUS_ENDPOINT} ${SYNAPSE_SERVER_NAME}' \
    < "$TEMPLATE_DIR/config.yaml" > "$CONFIG_FILE"

echo "Generating registration from template..."
envsubst '${WHATSAPP_AS_TOKEN} ${WHATSAPP_HS_TOKEN} ${SYNAPSE_SERVER_NAME}' \
    < "$TEMPLATE_DIR/registration.yaml" > "$REGISTRATION_FILE"

chown 1337:1337 "$CONFIG_FILE" "$REGISTRATION_FILE" 2>/dev/null || true
chmod 600 "$CONFIG_FILE" "$REGISTRATION_FILE"

if [ -d "$SYNAPSE_APPSERVICES_DIR" ]; then
    NEED_SYNAPSE_RESTART=false
    TARGET_REGISTRATION="$SYNAPSE_APPSERVICES_DIR/whatsapp.yaml"
    # Compare tokens rather than full file contents. The Synapse placeholder
    # template and bridge template can differ in whitespace/quoting yet render
    # identical tokens -- byte-comparing would cause a spurious Synapse restart.
    extract_as_token() {
        [ -f "$1" ] || return 0
        grep '^as_token:' "$1" 2>/dev/null | head -1 | sed -e 's/^as_token:[[:space:]]*//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
    }
    CURRENT_AS_TOKEN=$(extract_as_token "$REGISTRATION_FILE")
    TARGET_AS_TOKEN=$(extract_as_token "$TARGET_REGISTRATION")
    if [ ! -f "$TARGET_REGISTRATION" ] || [ -z "$TARGET_AS_TOKEN" ] || [ "$CURRENT_AS_TOKEN" != "$TARGET_AS_TOKEN" ]; then
        echo "Syncing registration to Synapse appservices..."
        cp "$REGISTRATION_FILE" "$TARGET_REGISTRATION"
        chown 991:991 "$TARGET_REGISTRATION" 2>/dev/null || true
        chmod 644 "$TARGET_REGISTRATION" 2>/dev/null || true
        NEED_SYNAPSE_RESTART=true
    fi
    if [ "$NEED_SYNAPSE_RESTART" = true ]; then
        for name in mc_local-synapse-1 mc_develop-synapse-1 mc_staging-synapse-1 mc_prod-synapse-1 synapse-synapse-1 synapse synapse-1; do
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${name}$"; then
                echo "Restarting Synapse to pick up registration..."
                docker restart "$name" 2>/dev/null && break
            fi
        done
        echo "Waiting for Synapse to be ready..."
        for i in $(seq 1 30); do
            sleep 2
            if wget -q -O /dev/null --timeout=2 http://synapse:8008/health 2>/dev/null || curl -sf --max-time 2 http://synapse:8008/health >/dev/null 2>&1; then
                echo "Synapse is ready."
                break
            fi
            echo "  Waiting... ($i/30)"
        done
    fi
fi

echo "Starting mautrix-whatsapp bridge..."
exec /custom-docker-run.sh "$@"
