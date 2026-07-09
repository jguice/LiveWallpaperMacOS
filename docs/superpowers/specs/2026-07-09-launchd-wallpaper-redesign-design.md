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
