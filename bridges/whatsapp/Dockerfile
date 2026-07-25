# Built from the Huddle fork of mautrix-whatsapp rather than dock.mau.dev/mautrix/whatsapp,
# because we carry a patch: `private_chat_name_template`, which names DM portal rooms from
# the receiving login's own contact store. Ghost puppets are global (one per phone number
# for the whole bridge), so address-book names in `displayname_template` leak one user's
# private label for a contact to everyone else who has that contact saved.
#
#   Fork:   https://github.com/HuddleChat/mautrix-whatsapp/tree/huddle
#   Source: AGPL-3.0, same as upstream. The fork's README records what we changed.
#
# Pinned by commit so image builds are reproducible — bump this deliberately when picking up
# upstream releases (the fork's `huddle` branch rebases onto upstream tags).
ARG BRIDGE_REPO=https://github.com/HuddleChat/mautrix-whatsapp.git
ARG BRIDGE_COMMIT=e8f372032ffb3be534e9e0573d628e536e437205

# Mirrors the upstream build stage (mautrix-whatsapp's own Dockerfile).
FROM golang:1-alpine3.24 AS builder

ARG BRIDGE_REPO
ARG BRIDGE_COMMIT

RUN apk add --no-cache git ca-certificates build-base su-exec olm-dev

RUN git clone "$BRIDGE_REPO" /build \
    && git -C /build checkout --detach "$BRIDGE_COMMIT"

WORKDIR /build
RUN ./build.sh

FROM alpine:3.24

ENV UID=1337 \
    GID=1337

# Runtime deps from upstream, plus gettext (envsubst for config templating), openssl (token
# generation), docker-cli (the entrypoint restarts synapse after writing registrations) and
# sqlite (the bridge DB is sqlite3-fk-wal; the CLI is how we inspect it in prod).
RUN apk add --no-cache \
    ffmpeg su-exec ca-certificates olm bash jq curl yq-go lottieconverter \
    gettext openssl docker-cli sqlite

COPY --from=builder /build/mautrix-whatsapp /usr/bin/mautrix-whatsapp
VOLUME /data

# Copy config and registration templates (secrets injected at runtime)
COPY config.yaml.template /config-template/config.yaml
COPY registration.yaml.template /config-template/registration.yaml

# Copy custom entrypoint and docker-run wrapper
COPY docker-entrypoint.sh /custom-entrypoint.sh
COPY custom-docker-run.sh /custom-docker-run.sh
RUN chmod +x /custom-entrypoint.sh /custom-docker-run.sh

ENTRYPOINT ["/custom-entrypoint.sh"]
