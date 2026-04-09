# status-tool design

## Goal

Replace the current `ss_status.sh` + `ss_status_main.sh` shell pipeline with a native Zig implementation that:

- avoids `curl` process fan-out
- avoids repeated `source ss_base.sh`
- avoids page-refresh-triggered overlapping probes
- supports both one-shot and daemon-driven status collection

## Modes

### `once`

- run one or more probes immediately
- print result and exit
- suitable for manual trigger, debug, and compatibility wrappers

### `daemon`

- load a probe set from config
- run probes at a fixed interval
- write the latest result to a cache file
- optionally print each cycle to stdout

## Probe model

Each probe describes:

- `name`
- `url`
- `family`: `auto | ipv4 | ipv6`
- `mode`: `direct | socks5`
- `proxy` when `mode=socks5`
- `warmup`
- `attempts`
- `timeout_ms`

The implementation currently performs:

- native TCP connect
- optional SOCKS5 handshake
- native HTTP/1.1 `HEAD`
- response line parse for status code
- elapsed time measurement

## Integration direction for fancyss

Recommended future wiring:

1. `status-tool daemon` becomes the only periodic status worker.
2. front-end status panel reads daemon cache by default.
3. fault-failover logic reads daemon cache instead of spawning new probes.
4. shell stays only as a thin compatibility launcher, or is removed later.

## Why this is better than shell optimization alone

Even if the shell version is micro-optimized, the current model still suffers from:

- shell startup cost
- many child processes
- repeated parsing of dbus / env / helpers
- overlapping requests from UI refresh

`status-tool` is intended to remove the entire class of overhead, not just shave a few milliseconds off it.

