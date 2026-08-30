# Status Apps

A macOS menu bar app that shows which development servers are listening, on which port, from
which project, and how much memory they actually hold.

## Why

Activity Monitor showed three processes called `node`, at 4.6 GB, 4.5 GB and 4.4 GB. Nothing in
it said which port each one served or which checkout it came from. They turned out to be three
Metro bundlers that had been running for ten days, together pushing swap to 19 GB of 20 GB.

The problem was never the memory. It was that three identical rows called `node` are impossible
to tell apart.

```
⇅3  13.5G
──────────────────────────────────────────────────────────
PUERTO  MEM    UP       PROCESO
:8082   4.6G   9d 22h   metro — humand-mobile/oli-barge-in
:8081   4.5G   10d      metro — humand-mobile/sqwh-378-pdf-workaround
:8083   4.4G   9d 21h   metro — humand-mobile
:3000   61M    48m      bun — api
──────────────────────────────────────────────────────────
▸ Recientes (2)
──────────────────────────────────────────────────────────
Swap 10.5G / 12.0G (87%)
```

The uptime column is what turns "three servers are running" into "three servers have been
running for nine days". A bundler up for forty minutes is work in progress; one up for a week
is something nobody remembered to stop.

Each row opens a submenu with **Stop**, **Clean cache**, **Rerun**, **Attach (tmux)** and the
project directory. Entries under **Recientes** show how long ago they were last seen.

## Install

```sh
make install
```

Builds the app, copies it to `/Applications` and launches it. Look for `⇅` in the menu bar.
`make uninstall` removes both the app and its stored state.

Requires macOS 13 or later. `tmux` is needed for Rerun and Attach; `watchman` is used by Clean
when present. Both are optional — the affected items disable themselves and explain why.

## How it works

The scan reads process state straight from `libproc`, the same source `lsof` and Activity
Monitor use, with no subprocesses on the hot path:

| What | Call |
|---|---|
| Listening TCP ports | `proc_pidinfo(PROC_PIDLISTFDS)` + `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)`, filtered to `TSI_S_LISTEN` |
| Memory | `proc_pid_rusage(RUSAGE_INFO_V4).ri_phys_footprint` — the figure Activity Monitor shows |
| Command | `sysctl(KERN_PROCARGS2)` |
| Directory | `proc_pidinfo(PROC_PIDVNODEPATHINFO)` |
| Swap | `sysctlbyname("vm.swapusage")` |

A full scan takes about 5 ms across 530 processes, against roughly 2 seconds for the equivalent
`lsof` pipeline. The app itself holds around 11 MB — it would be a poor tool for finding memory
hogs if it were one.

`ri_phys_footprint` matters here. An idle Metro bundler reports an RSS near 200 MB because most
of it has been compressed or swapped out, while its real footprint is 4.5 GB. Reading `rss`
would have understated these processes by a factor of twenty.

## What counts as a development server

An allowlist, not a denylist. A process qualifies if it is listening on TCP **and** its
executable is a known runtime (`node`, `bun`, `deno`, `python3`, `ruby`, `java`, `postgres`,
`redis-server`, `php`) **or** its arguments name a known tool (`expo`, `metro`, `vite`, `next`,
`webpack`, `rails`, `uvicorn`, `gunicorn`).

Markers match whole path components, so `/node_modules/.bin/expo` counts and a project called
`nextcloud` does not.

Everything else — `adb`, `wineserver`, Logitech's agents, `rapportd`, Control Center — stays out
because it was never on the list, so no exclusion list needs maintaining.

To add a runtime, edit `allowedExecutables` or `toolMarkers` in
[`DevServerClassifier.swift`](Sources/StatusAppsCore/DevServerClassifier.swift). That file is
pure and has no dependencies; nothing else needs to change.

## Actions

**Stop** signals the process group rather than the pid. A Metro bundler is `yarn start` spawning
`node`; the listener is the child, so signalling only its pid leaves the parent holding the port.

**Clean** applies only to Metro, where the cache layout is known: `$TMPDIR/metro-*`, `haste-map-*`
and `react-*`, the project's `.expo`, and `watchman watch-del`. Other runtimes have the item
disabled rather than a guessed recipe.

**Rerun** launches the recorded command in a detached tmux session named for the server and its
port, under a login shell so it picks up nvm and your `PATH`. The pane drops to an interactive
shell when the command exits, so a crash leaves its output there to read. Session names include
the port because one directory can host several servers.

**Recientes** lists servers seen before that are no longer running, so Rerun can bring back
something that has already died — the case where it is actually useful. This is the app's only
persistent state, kept in `~/Library/Application Support/StatusApps/known.json`.

## Development

```sh
make build
make test     # 46 tests
make run      # bundle and launch without installing
```

`StatusAppsCore` holds the logic and has no AppKit dependency, so it is tested directly. That
includes the row layout: `Formatters.serverRow` composes the aligned columns, so column drift is
caught by a test rather than noticed in the menu. `MenuBuilder` is left with nothing but `NSMenu`
assembly.

Classification and formatting are pure functions tested against fixtures captured from a real
machine; the scanner has integration tests that open a socket and assert it finds itself.

The design is written up in
[`docs/superpowers/specs`](docs/superpowers/specs/2026-08-30-status-apps-design.md).

## License

MIT
