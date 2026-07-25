# MultiChat Bridge Infrastructure

This repository contains the configuration files and Dockerfiles for the Matrix-based bridge infrastructure that powers MultiChat's messaging integrations.

## What's here

- Synapse homeserver configuration
- Bridge configurations for WhatsApp, Telegram, Messenger, and Google Messages

## What's NOT here

MultiChat's client app and backend are proprietary and not included in this repository.

## Upstream projects

### Modified

We run modified builds of these. Our changes, and the dates they were made, are recorded in
each fork's README; the `huddle` branch holds them and `main` tracks upstream unmodified.

- **[mautrix-whatsapp](https://github.com/mautrix/whatsapp)** (AGPLv3) — our fork:
  [HuddleChat/mautrix-whatsapp](https://github.com/HuddleChat/mautrix-whatsapp/tree/huddle),
  based on upstream `v0.2607.0`.
  - Added a `private_chat_name_template` option so DM rooms are named from the receiving
    account's own contact list. Ghost puppet displaynames are shared by everyone on the
    bridge, so address-book names in `displayname_template` exposed one user's private label
    for a contact to every other user who had that contact saved.
  - Re-render names on chats that already exist when the naming scheme changes, since
    upstream only refreshes a DM room when the user opens it.
- **[mautrix-telegram](https://github.com/mautrix/telegram)** (AGPLv3) — our fork:
  [HuddleChat/mautrix-telegram](https://github.com/HuddleChat/mautrix-telegram/tree/huddle),
  based on upstream `v0.15.2`.
  - Deduplicate entity rows before the bulk upsert, which otherwise fails with a Postgres
    cardinality violation and aborts `!tg sync`. Fixed upstream only in the v0.26xx rewrite.

### Unmodified

We run these as published; the Dockerfiles here only add config templates and an entrypoint.

- [Synapse](https://github.com/element-hq/synapse) (AGPLv3)
- [mautrix-meta](https://github.com/mautrix/meta) (AGPLv3)
- [mautrix-gmessages](https://github.com/mautrix/gmessages) (AGPLv3)

## License

The configuration files in this repository are provided under AGPLv3 to match the upstream projects.
