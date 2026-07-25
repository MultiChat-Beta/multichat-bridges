#!/bin/sh
set -e

CONFIG_FILE="/data/config.yaml"
REGISTRATION_FILE="/data/registration.yaml"
TEMPLATE_DIR="/config-template"
SYNAPSE_APPSERVICES_DIR="/synapse-appservices"

# Telegram API credentials are required
if [ -z "$TELEGRAM_API_ID" ] || [ -z "$TELEGRAM_API_HASH" ]; then
    echo "ERROR: TELEGRAM_API_ID and TELEGRAM_API_HASH must be set. Get them from https://my.telegram.org/apps"
    exit 1
fi

# Ensure tokens are set (reuse from existing registration/config if present, else generate)
if [ -z "$TELEGRAM_AS_TOKEN" ] || [ -z "$TELEGRAM_HS_TOKEN" ]; then
    if [ -f "$REGISTRATION_FILE" ] && grep -q '^as_token:' "$REGISTRATION_FILE" 2>/dev/null; then
        echo "Reusing tokens from existing registration..."
        TELEGRAM_AS_TOKEN=$(grep '^as_token:' "$REGISTRATION_FILE" | sed 's/as_token: *["\x27]*\(.*\)["\x27]*/\1/' | head -1)
        TELEGRAM_HS_TOKEN=$(grep '^hs_token:' "$REGISTRATION_FILE" | sed 's/hs_token: *["\x27]*\(.*\)["\x27]*/\1/' | head -1)
        export TELEGRAM_AS_TOKEN TELEGRAM_HS_TOKEN
    elif [ -f "$CONFIG_FILE" ] && grep -q '^\s*as_token:' "$CONFIG_FILE" 2>/dev/null; then
        echo "Reusing tokens from existing config..."
        TELEGRAM_AS_TOKEN=$(grep '^\s*as_token:' "$CONFIG_FILE" | sed 's/.*: *//' | tr -d ' "\x27' | head -1)
        TELEGRAM_HS_TOKEN=$(grep '^\s*hs_token:' "$CONFIG_FILE" | sed 's/.*: *//' | tr -d ' "\x27' | head -1)
        export TELEGRAM_AS_TOKEN TELEGRAM_HS_TOKEN
    else
        echo "TELEGRAM_AS_TOKEN and/or TELEGRAM_HS_TOKEN not set. Generating..."
        export TELEGRAM_AS_TOKEN="${TELEGRAM_AS_TOKEN:-$(python3 -c 'import secrets; print(secrets.token_urlsafe(43))' 2>/dev/null || openssl rand -base64 43 | tr -d '\n' | head -c 64)}"
        export TELEGRAM_HS_TOKEN="${TELEGRAM_HS_TOKEN:-$(python3 -c 'import secrets; print(secrets.token_urlsafe(43))' 2>/dev/null || openssl rand -base64 43 | tr -d '\n' | head -c 64)}"
    fi
fi

# Provisioning shared secret: prefer the env var supplied by multichat.env,
# otherwise reuse a value persisted to the data volume so restarts do not
# rotate the secret. mautrix-python's default "generate" behaviour would
# otherwise rewrite the secret every boot because the entrypoint regenerates
# /data/config.yaml from the template each time.
PROVISIONING_SECRET_FILE="/data/.provisioning_secret"
gen_provisioning_secret() {
    s=""
    if command -v openssl >/dev/null 2>&1; then
        s=$(openssl rand -base64 48 2>/dev/null | tr -d '\n/+=' | head -c 64)
    fi
    if [ -z "$s" ] && command -v python3 >/dev/null 2>&1; then
        s=$(python3 -c 'import secrets; print(secrets.token_urlsafe(48))' 2>/dev/null | tr -d '\n' | head -c 64)
    fi
    if [ -z "$s" ]; then
        s=$(head -c 48 /dev/urandom 2>/dev/null | base64 2>/dev/null | tr -d '\n/+=' | head -c 64)
    fi
    echo "$s"
}
if [ -z "${TELEGRAM_PROVISIONING_TOKEN:-}" ]; then
    if [ -f "$PROVISIONING_SECRET_FILE" ]; then
        TELEGRAM_PROVISIONING_TOKEN=$(cat "$PROVISIONING_SECRET_FILE")
    else
        TELEGRAM_PROVISIONING_TOKEN=$(gen_provisioning_secret)
        echo "$TELEGRAM_PROVISIONING_TOKEN" > "$PROVISIONING_SECRET_FILE"
        chmod 600 "$PROVISIONING_SECRET_FILE"
    fi
fi
export TELEGRAM_PROVISIONING_TOKEN

echo "Generating config from template..."
envsubst '${TELEGRAM_AS_TOKEN} ${TELEGRAM_HS_TOKEN} ${TELEGRAM_POSTGRES_USER} ${TELEGRAM_POSTGRES_PASSWORD} ${TELEGRAM_POSTGRES_DB} ${TELEGRAM_API_ID} ${TELEGRAM_API_HASH} ${TELEGRAM_PROVISIONING_TOKEN} ${MULTICHAT_BRIDGE_STATUS_ENDPOINT} ${SYNAPSE_SERVER_NAME}' \
    < "$TEMPLATE_DIR/config.yaml" > "$CONFIG_FILE"

echo "Generating registration from template..."
envsubst '${TELEGRAM_AS_TOKEN} ${TELEGRAM_HS_TOKEN} ${SYNAPSE_SERVER_NAME}' \
    < "$TEMPLATE_DIR/registration.yaml" > "$REGISTRATION_FILE"

# Update double_puppet secrets to use actual token
sed -i "s/${SYNAPSE_SERVER_NAME}: as_token/${SYNAPSE_SERVER_NAME}: \"$TELEGRAM_AS_TOKEN\"/" "$CONFIG_FILE"

chown 1337:1337 "$CONFIG_FILE" "$REGISTRATION_FILE"
chmod 600 "$CONFIG_FILE" "$REGISTRATION_FILE"

# Sync registration to Synapse appservices and optionally restart Synapse
TOKENS_JUST_GENERATED=false
if [ -f "$SYNAPSE_APPSERVICES_DIR/telegram.yaml" ]; then
    CURRENT_AS_TOKEN=$(grep '^as_token:' "$REGISTRATION_FILE" | sed 's/as_token: *["'"'"']\(.*\)["'"'"']/\1/' | head -1)
    SYNAPSE_AS_TOKEN=$(grep '^as_token:' "$SYNAPSE_APPSERVICES_DIR/telegram.yaml" 2>/dev/null | sed 's/as_token: *["'"'"']\(.*\)["'"'"']/\1/' | head -1)
    if [ -z "$SYNAPSE_AS_TOKEN" ] || [ "$CURRENT_AS_TOKEN" != "$SYNAPSE_AS_TOKEN" ]; then
        TOKENS_JUST_GENERATED=true
    fi
else
    TOKENS_JUST_GENERATED=true
fi

if [ -d "$SYNAPSE_APPSERVICES_DIR" ]; then
    echo "Copying registration to Synapse appservices..."
    cp "$REGISTRATION_FILE" "$SYNAPSE_APPSERVICES_DIR/telegram.yaml"
    chown 991:991 "$SYNAPSE_APPSERVICES_DIR/telegram.yaml" 2>/dev/null || true
    chmod 644 "$SYNAPSE_APPSERVICES_DIR/telegram.yaml" 2>/dev/null || true

    if [ "$TOKENS_JUST_GENERATED" = true ]; then
        echo "New tokens generated. Attempting to restart Synapse..."
        for name in mc_local-synapse-1 mc_develop-synapse-1 mc_staging-synapse-1 mc_prod-synapse-1 synapse synapse-synapse-1 synapse-1; do
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${name}$"; then
                docker restart "$name" 2>/dev/null && echo "Synapse restarted." && break
            fi
        done
        # Wait for Synapse to come back up before mautrix-telegram starts hammering it.
        # Without this, mautrix-python can race Synapse's appservice cache warmup and
        # persist an access_token that Synapse later rejects.
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

cd /data
chown -R 1337:1337 /data

echo "Starting mautrix-telegram bridge..."
exec su-exec 1337:1337 python3 -m mautrix_telegram -c "$CONFIG_FILE"
