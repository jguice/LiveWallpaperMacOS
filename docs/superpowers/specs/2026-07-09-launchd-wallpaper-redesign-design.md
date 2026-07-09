# Live Wallpaper: launchd-supervised renderer redesign

**Date:** 2026-07-09
**Status:** Approved (architecture), pending spec review
**Branch:** SwiftUI (Josh's fork, `jguice`)

## Goal

Deliver the four things reliably: **pick** live wallpapers, **preview** them, **set**
them, and have that setting **persist** — surviving display sleep, system sleep,
crashes, logout/login, and reboot.

## Why the current design fails

The GUI app `posix_spawn`s a `wallpaperdaemon` child per display and tries to
babysit it. That is fragile and has failed repeatedly:

- macOS kills the daemon across display/system sleep; the app doesn't reliably
  bring it back (App Nap suspends the app; wake notifications don't always fire).
- The app never reaps children, so dead daemons become zombies that fool
  `kill(pid,0)` liveness checks.
- If the app itself isn't running, nothing renders and nothing recovers.

Root problem: the app is reinventing process supervision. macOS already provides
it — `launchd`.

## Approach (chosen): launchd LaunchAgent + KeepAlive

Hand the renderer's lifecycle to `launchd`. Research confirms this is the
platform-native mechanism and that it is viable here:

- A **LaunchAgent** runs in the user's Aqua GUI session and has full
  window-server access, so it can render the desktop wallpaper (a LaunchDaemon
  cannot — it's pre-login, no GUI).
- **`KeepAlive=true`** restarts the process whenever it exits, for any reason
  (sleep-death, crash, etc.), subject to launchd's ~10s throttle.
- **`RunAtLoad=true`** starts it at login, so it persists across reboot.

The app stops supervising anything. It becomes a pure configuration UI.

### Component 1 — Renderer (`wallpaperdaemon`), lifecycle owned by launchd

Rendering code is unchanged. It keeps its current argv contract
(`<video> <frame> <volume> <scaleMode> [displayUUID]`). The only change to its
world is *who starts it*: launchd, not the app.

Keep the existing daemon-side sleep pause/resume handling so the daemon survives
a plain display-off (pauses instead of exiting), which avoids a KeepAlive
restart-storm while the screen is off. If it turns out the daemon is being
*killed* on display-off rather than exiting cleanly, that is investigated during
implementation; KeepAlive is the safety net either way.

### Component 2 — LaunchAgent plist (generated artifact)

One plist per active display, written to `~/Library/LaunchAgents/`:

- Label: `com.thusvill.wallpaperdaemon.<displayUUID>`
- `ProgramArguments`: `[<daemon path>, <video>, <frame>, <volume>, <scaleMode>, <displayUUID>]`
- `KeepAlive`: true · `RunAtLoad`: true · `ProcessType`: Interactive
- `LimitLoadToSessionType`: Aqua (GUI access)

The plist is a **generated artifact**, not a second source of truth. It is
regenerated from the app's saved selection every time the user sets a wallpaper.

### Component 3 — App as configuration UI

The app keeps the existing browse / crisp-thumbnail preview / pick UI. What
changes is the "set" action and startup:

- **On "set" (or volume/scale change):** write the selection to
  `~/Library/Preferences/LiveWallpaper.yaml` (unchanged source of truth), then
  regenerate the per-display plist(s) and reload the agent(s) via
  `launchctl bootout` + `launchctl bootstrap` (or `launchctl kickstart -k
  gui/$UID/<label>` when already installed). A kickstart restart re-runs the
  daemon with the new arguments.
- **On launch:** the app no longer spawns anything. If plists exist, launchd is
  already rendering; the app just reflects current state.
- **Removed:** `posix_spawn` daemon spawning, `killall wallpaperdaemon`,
  `anyDaemonAlive`/`waitpid` logic, the wake-notification respawn, and any
  watchdog. This deletes the fragile code rather than adding to it.

### Source of truth

`LiveWallpaper.yaml` + `NSUserDefaults` remain the single source of truth for
the selection and settings. The plist(s) are deterministically generated from
it. No knowledge is duplicated.

## Data flow

```
pick video ──▶ app writes LiveWallpaper.yaml ──▶ app regenerates plist(s)
   ──▶ launchctl (re)load / kickstart ──▶ launchd runs wallpaperdaemon (KeepAlive)
   ──▶ desktop renders

persist:
  reboot/login ──▶ RunAtLoad starts daemon from installed plist
  crash / sleep-death ──▶ KeepAlive restarts daemon
  quit the app ──▶ wallpaper keeps rendering (launchd owns it)
```

## Dev/test build vs. proper install

- **Dev build (this multi-day test):** write the plist directly to
  `~/Library/LaunchAgents` and load with `launchctl` — no code-signing friction.
  `ProgramArguments[0]` points at the daemon inside the DerivedData app bundle.
- **Proper installed version (later):** register via `SMAppService.agent(plistName:)`
  with the plist bundled in the app. Same runtime behavior.

## Cleanup

Disable the stale conflicting login item for the OLD installed app
(`~/Library/LaunchAgents/com.biosthusvill.LiveWallpaper.plist` →
`/Applications/LiveWallpaper.app`), which fights the dev build (both spawn
processes named `wallpaperdaemon` and both `killall` them).

## Known risks / follow-ups

- **KeepAlive restart-storm** if the daemon dies on every display-off. Mitigate
  by keeping the daemon alive across display-off (pause, don't exit) and/or a
  `ThrottleInterval`. Investigate the daemon's display-off exit path during impl.
- **Multi-display** produces one plist/agent per display; the app must add/remove
  plists as the display set changes. Single-display (the test machine) is the
  primary path and is implemented first.
- **Unsigned dev build:** `launchctl bootstrap` of an agent whose binary lives in
  DerivedData works, but Gatekeeper/TCC prompts may appear on first run.

## Testing / acceptance

1. Set a wallpaper → it renders.
2. `kill -9` the daemon → launchd auto-restarts it within the throttle window.
3. Quit the app → wallpaper keeps animating.
4. Display sleep/wake → still animating after wake (survives or auto-restarts).
5. Reboot / logout+login → wallpaper comes back automatically.
6. Multi-day: still animating after days of normal sleep/wake cycles.

## Review findings & resolutions (2026-07-09)

Empirical linchpin test PASSED: the unsigned DerivedData daemon loaded under a
`KeepAlive` LaunchAgent, rendered (Aqua/window-server access, attached to the
display), and auto-restarted within 12s after `kill -9`. `bootstrap` of the
unsigned binary was not blocked. Core mechanism proven.

Subagent review resolutions (supersede conflicting text above):

- **C1 — the app must stop fighting launchd (the real multi-day-test killer).**
  Delete `killAllDaemons` (WallpaperEngine.mm:1130), which is called from `init`,
  the wake-respawn, and `terminateApplication`. It `killall`s the launchd-managed
  daemon (KeepAlive resurrects it) and posts `com.live.wallpaper.terminate`, whose
  daemon observer calls `exit(0)` (daemon.mm:452) — a clean exit KeepAlive undoes.
  Under launchd, "stop" = `launchctl bootout gui/$UID/<label>` (removes the job so
  KeepAlive does not respawn). Remove the terminate→`exit(0)` Darwin path; bootout's
  SIGTERM terminates the daemon (default disposition).
- **C2 — delete the entire spawn/babysit stack**, not half of it: `posix_spawn`
  in `launchDaemonOnScreen`, `anyDaemonAlive`/`waitpid`, `restartWallpapersIfDaemonsDied`
  and its `awakeHandle`/`screensDidWakeHandle` callers, and `SetWallpaperDisplay(pid,…)`.
  launchd owns liveness; `_daemonPIDs` is retired. (This removes the earlier
  waitpid/wake-respawn fix — it is superseded, not regressed.)
- **C3 — reload is `bootout`+`bootstrap`, never `kickstart -k`.** kickstart restarts
  from launchd's in-memory definition and will NOT pick up the new video path.
  Every "set" = write YAML → regenerate plist → `bootout` (ignore not-loaded) →
  `bootstrap`. Use `bootstrap`/`bootout`, not deprecated `load`/`unload`.
- **I1 — static desktop image must be self-sufficient.** Today the still image on
  inactive Spaces is refreshed only when the app posts `spaceChanged`; the daemon's
  own `activeSpaceChanged:` (daemon.mm:790) only touches playback. Move the
  `setStaticWallpaper` trigger into the daemon's own space-change handler so it works
  with the app closed.
- **I2 — per-display plist + reconcile.** Generate each plist from
  `displays[i].videoPath` (NOT a shared `_currentVideoPath`; the old `screensDidChange`
  used the shared path — a pre-existing bug not to inherit). On display connect/
  disconnect (`screensDidChange`), bootout+delete plists for vanished displays and
  bootstrap new ones — otherwise a disconnected display's agent falls back to
  `mainScreen` and hijacks the primary display.
- **I3 — app no longer auto-starts at login.** launchd renders wallpaper without the
  app. Drop the app-autostart LaunchAgent (`com.thusvill.LiveWallpaper`, written by
  the duplicated `enableAppAsLoginItem` using deprecated `load`); the user launches
  the app only to change wallpapers. Do not ship three overlapping agent labels.
- **I4 — one-shot migration.** On first run of the new build: `bootout` + delete the
  stale `com.biosthusvill.LiveWallpaper` and old `com.thusvill.LiveWallpaper` agents,
  `pkill wallpaperdaemon` ONCE, then install the new per-display agents. No recurring
  `killall`.
- **I5 — restart-storm insurance.** The daemon pauses (not exits) on display-off, so
  normal sleep does not storm. The real storm risk is a malformed plist (daemon exits
  nonzero, KeepAlive respawns every ~10s). Use `KeepAlive = {Crashed:true,
  SuccessfulExit:false}` (kill -9 = crash → restart; deliberate nonzero exit → stays
  down) plus `ThrottleInterval`.
- **M1** — write the NUMERIC scale mode into `ProgramArguments[4]` (daemon parses it
  with `strtol`), not the `"fill"` string.
- **M4** — drop the now-meaningless `daemon` pid field from the YAML schema; keep
  `uuid`/`video`/`frame`/`screen`.
- **M5** — regenerate the plist on volume/scale changes too (baked argv is authoritative
  at RunAtLoad/reboot), so a single clean path keeps YAML and plist in sync.
