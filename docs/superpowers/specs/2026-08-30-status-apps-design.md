# Status Apps — design

Date: 2026-08-30

## Problem

Three Metro bundlers were left running for ten days without anyone noticing, holding
13.5 GB of footprint between them and pushing swap to 19 GB of 20 GB. Activity Monitor
showed three processes called `node` with no way to tell them apart: it exposes neither the
port they listen on nor the directory they were launched from.

The app solves identification: which development servers are alive, on which port, from which
project, and how much memory they actually hold.

## Scope

A menu bar app listing **development servers only**, with stop, clean and rerun actions on
each one.

Explicitly out of scope:

- Alerts, thresholds and notifications. The app is passive: it reports when the menu is opened.
- Non-development processes (Logitech, `adb`, `wineserver`, system agents).
- Historical charts or time series.

## Architecture

An AppKit app with `NSStatusItem`, bundled as an `.app` with `LSUIElement = true` so it stays
out of the Dock. Ad-hoc signed and unsandboxed: `libproc` needs to read other processes
belonging to the same user.

SwiftUI `MenuBarExtra` was ruled out because the per-server submenus are assembled dynamically
by kind, and `NSMenu` gives direct control over that.

The code is split into two targets so the logic can be tested without bringing up the interface:

- `StatusAppsCore` — library. Scanning, classification, actions, persistence.
- `StatusApps` — executable. Status item, menu, lifecycle.

### Modules

| Module | Responsibility | Depends on |
|---|---|---|
| `ProcessScanner` | Wraps `libproc`. Returns `[RunningProcess]` with no policy applied. | syscalls |
| `DevServerClassifier` | Pure function `[RunningProcess] -> [DevServer]`. All the curation and label building. | nothing |
| `SystemMemory` | Swap usage via `sysctl`. | syscalls |
| `ActivityMonitor` | Differences resource counters between scans to decide who is working. | nothing |
| `ServerActions` | stop, clean, rerun, attach. The only module that spawns subprocesses. | tmux, watchman |
| `KnownServersStore` | Persists the last seen state of each server. | disk |
| `Formatters` | Renders rows in aligned columns: port, memory, uptime, process. | nothing |
| `MenuBuilder` | `[DevServer]` + swap -> `NSMenu`. No system access. | `Formatters` |
| `AppDelegate` | Status item, timer, wiring. | everything |

Curation lives isolated in a pure module on purpose: it is the part that changes when a new
runtime shows up, so it can be adjusted without touching scanning or the interface.

### Scanning

No shelling out on the hot path. The same syscalls `lsof` uses internally:

- `proc_listpids` to enumerate processes.
- `proc_pidinfo(PROC_PIDTBSDINFO)` for uid, pgid and start time. Filters by uid before going on.
- `proc_pidinfo(PROC_PIDLISTFDS)` + `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)` for TCP sockets in
  `TSI_S_LISTEN` state.
- `proc_pid_rusage(RUSAGE_INFO_V4)` for `ri_phys_footprint`, the same figure Activity Monitor
  shows.
- `sysctl(KERN_PROCARGS2)` for the full argv.
- `proc_pidinfo(PROC_PIDVNODEPATHINFO)` for the cwd.

Validated against `lsof`: same processes and same ports, in milliseconds instead of two seconds.

## Curation rules

A process is a dev server if it has at least one TCP socket in LISTEN owned by the user **and**
its executable is in the allowlist (`node`, `bun`, `deno`, `python3`, `ruby`, `java`,
`postgres`, `redis-server`, `php`) **or** its argv mentions
`expo`, `metro`, `vite`, `next`, `webpack`, `rails`, `uvicorn` or `gunicorn`.

It is an allowlist, not a denylist: `adb`, `wineserver` and Logitech's agents stay out because
they are not on the list, not because they are excluded one by one. There is no need to chase
every new app that opens a port.

Postgres is in: it is a legitimate development dependency. Removing it is deleting one line.

### Labels

Derived from the cwd, in this order:

1. If the path contains `/.worktrees/<wt>`, the label is `<repo>/<wt>`.
2. Otherwise, the basename of the cwd.
3. If the cwd is `/`, empty or unreadable, the executable name.

## Actions

- **Stop** — `SIGTERM` to the process group, not the pid. A Metro is `yarn start` spawning
  `node`; killing only the child leaves the parent orphaned. After five seconds, if it is still
  alive, the menu offers `SIGKILL`.
- **Clean** — per kind. Metro removes `$TMPDIR/metro-*`, `haste-*` and `react-*`, plus the
  project's `.expo`, and runs `watchman watch-del <cwd>`. Other kinds have it disabled rather
  than a made-up recipe.
- **Rerun** — `tmux new-session -d -s <kind>-<label> -c <cwd>` running the original argv under a
  login shell, so it picks up nvm and the user's PATH. If the session already exists, it is torn
  down first.
- **Attach** — opens Terminal.app with `tmux attach -t <session>`.

## Detecting use

`uptime` answers how long a server has been running, which is the wrong question. The three
bundlers that prompted this app had been up for ten days *and* untouched for six; the gap between
those numbers is the signal.

`proc_pid_rusage` was already being called for memory, and the same struct carries
`ri_user_time`, `ri_system_time` and `ri_diskio_bytesread`. The activity column therefore costs
no extra syscalls. Those counters are cumulative since launch, so a single reading is meaningless
and only the difference between two scans is a rate — which is why `ActivityMonitor` holds state
while the rest of the curation stays pure.

A server counts as working above 0.2% of one core over the window, or 512 KB read from disk.
Measured against the real machine: every idle server sat at 0.00–0.01% of a core reading nothing,
while the one bundler rebuilding hit 1.79% and read 55 MB in five seconds. The gap is wide enough
that the exact thresholds barely matter. CPU is the primary signal and disk the second chance,
because a bundler rebuilding reads its sources but a server answering from an in-memory cache
does not.

Counting established TCP connections was the first candidate — free, from the descriptor walk
`listeningPorts` already does — and it was rejected on measurement. An idle bundler held six
established sockets at 0.01% CPU: simulators and browser tabs keep connections open indefinitely.
The count measures whether something is attached, not whether anything is happening.

### What the number does not claim

It is the last use *observed by the app*. A rate needs two samples, so a server is reported as
unknown (`—`) rather than idle until it has been watched across a window, and time while the app
is not running is invisible. Launch at login is what makes the column continuous.

Three cases produce no reading rather than a wrong one: the first sight of a server, a recycled
pid (detected by comparing `startedAt`, since the new process restarts its counters), and two
scans landing closer together than a second, which would divide by nearly zero and read as a
burst of work. That last one is not hypothetical — `AppDelegate` refreshes on a timer *and* when
the menu opens.

The threshold leans towards over-reporting activity: calling a busy server idle invites killing
something in use, while calling an idle one busy costs one extra window in the list.

## Persistence

A JSON file at `~/Library/Application Support/StatusApps/known.json` stores the last seen state
of each server: label, kind, cwd, argv, port and the last time it was seen working. That last
field is optional, because `load` discards a file it cannot decode: a required field would have
silently wiped every remembered server on upgrade, taking Rerun with it. The ones no longer running show up in a
"Recent" section with a single action, Rerun.

It is the app's only persistence, and it exists because without it "rerun" would be little more
than restarting something that is already alive. The value is in relaunching what died.

### Server identity

Identity is `kind + cwd + argv`, not `kind + cwd + label`. One directory can run several
servers: the reference machine had two `bun` processes in `toto/apps/api`, on ports 3000 and
3999, plus two more called `scratchpad`. With the label as the key they collapsed into a single
entry.

For the same reason the tmux session name carries the port (`bun-api-3000`, `bun-api-3999`), or
a short hash of the cwd when there is no port: if they collided, a Rerun on one would tear down
the other's session.

## Error handling

- Any per-pid call returning `EPERM` — processes owned by other users — is skipped silently. The
  scanner never propagates errors to the interface: it degrades to fewer rows.
- Without `tmux`, Rerun and Attach are disabled with a tooltip explaining why.
- Without `watchman`, that step of Clean is skipped and the rest runs anyway.

## Tests

`DevServerClassifier` and label building are tested with fixtures captured from a real machine
and transcribed into Swift literals: they are pure functions, they do not touch the system and
they run in milliseconds. The cases that matter are worktree paths, an empty cwd, a cwd of `/`
and the processes that must fall outside the allowlist.

`ProcessScanner` has an integration test that opens a listening socket and verifies the test
process finds itself, with that port and with a footprint greater than zero.

`ServerActions` is not tested automatically because it mutates the system. It is validated by
hand.


## Outcome

Implemented and verified against the real system: same processes and same ports as `lsof`, with
a scan of about 5 ms across 530 processes. The app itself holds around 11 MB. 79 tests green.

Activity detection was verified end to end with two processes identical but for their behaviour:
a `python3` listening on a port while spinning the CPU was stamped as used, and one listening on
a port while sleeping was never stamped.

Each row shows port, memory, uptime and process. Row assembly lives in `Formatters`, inside the
library, so column alignment is covered by a test rather than discovered by looking at the menu.
