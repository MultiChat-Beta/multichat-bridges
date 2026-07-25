FROM dock.mau.dev/mautrix/telegram:v0.15.2

# We carry a patch to mautrix-telegram: entity rows are deduplicated before the bulk upsert
# in TelethonSessionDB._locked_process_entities. Without it a Telegram response containing
# the same entity twice aborts `!tg sync` with a Postgres cardinality violation, blocking all
# chat sync and backfill. Affects the whole 0.15.x line; fixed upstream only in the rewritten
# megabridge (v0.26xx), which is a much larger migration.
#
#   Fork:   https://github.com/HuddleChat/mautrix-telegram/tree/huddle (based on v0.15.2)
#   Source: AGPL-3.0, same as upstream. The fork's README records what we changed.
#
# The patched package is installed over the base image's copy rather than rewritten in place
# at build time, so what runs here is exactly the source published in the fork. Pinned by
# commit — bump deliberately.
ARG BRIDGE_REPO=https://github.com/HuddleChat/mautrix-telegram.git
ARG BRIDGE_COMMIT=3c53c57541cb71d1124828c00300ce30f8953f92

USER root
# Install docker CLI and gettext for envsubst
RUN apk add --no-cache docker-cli curl wget gettext || \
    (apt-get update && apt-get install -y docker.io curl wget gettext-base && rm -rf /var/lib/apt/lists/*) || \
    echo "Could not install docker CLI - automatic synapse restart will be disabled"

# Reinstall mautrix_telegram from the fork. --no-deps because the base image already has the
# dependency set pinned by upstream; we only replace the package's own code.
RUN apk add --no-cache --virtual .huddle-build git \
 && git clone "$BRIDGE_REPO" /tmp/mautrix-telegram-src \
 && git -C /tmp/mautrix-telegram-src checkout --detach "$BRIDGE_COMMIT" \
 && pip3 install --break-system-packages --no-cache-dir --no-deps --force-reinstall \
      /tmp/mautrix-telegram-src \
 && rm -rf /tmp/mautrix-telegram-src \
 && apk del .huddle-build

# Fail the build if the patched code is not what ends up installed.
RUN python3 -c "\
import inspect, sys; \
from mautrix_telegram.db.telethon_session import PgSession; \
src = inspect.getsource(PgSession._locked_process_entities); \
sys.exit(0) if 'row[1]: row for row in rows' in src else sys.exit('dedup patch missing from installed package')"

# Copy config and registration templates (secrets injected at runtime)
COPY config.yaml.template /config-template/config.yaml
COPY registration.yaml.template /config-template/registration.yaml

# Copy custom entrypoint script
COPY docker-entrypoint.sh /custom-entrypoint.sh
RUN chmod +x /custom-entrypoint.sh

ENTRYPOINT ["/custom-entrypoint.sh"]
