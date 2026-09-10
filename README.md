# bot_army_para

The PARA knowledge base (Projects / Areas / Resources / Archive) as a
NATS service. All filesystem writes go through a safety layer: prefix
allow-list, size caps, and an atomic write contract — plus a
write-token auth path and leader election so exactly one node serves
writes at a time.

## Subjects

| Subject | Direction | Purpose |
| --- | --- | --- |
| `para.fs.write` | request | safe file write (prefix allow-list, 2MB cap, schema v1.0) |
| `para.fs.read` / `.list` / `.search` | request | filesystem reads |
| `para.capture.append` | request | append a capture to inbox |
| `para.note.route` | request | route a note to its PARA bucket |
| `para.digest.generate` | request | generate a digest |
| `para.auth.get_write_token` | request | obtain a write token |
| `para.system.config` | request | service configuration |

## Architecture

- `para_fs` — safe writes (atomic, prefix-gated, size-capped)
- `para_notes` — note routing
- `search_worker` — filesystem search
- `nats/consumer` — registrations + handlers; leader election via
  `PARA_NODE_ROLE` (standby→primary flip re-registers)
- `pulse_publisher` — `system.health` pulses
- `http_client` — outbound HTTP

## Development

```sh
mix deps.get
mix test
make publish-release
```

`config/runtime.exs` reads `NATS_HOST` / `NATS_PORT` at boot via
`ConfigLoader` so releases never bake in the dev broker.