# BU - Manual backup and restore mod for Project Zomboid

A Java mod for Project Zomboid B42 built on [ZombieBuddy](https://github.com/zed-0xff/ZombieBuddy). Backs up the current save on a hotkey, and restores it from the title screen.

Project Zomboid autosaves on its own schedule, which means the newest save on disk is never necessarily the state you want. This mod adds an explicit, on-demand backup you trigger yourself, so there is a known-good copy you can roll back to.

> [!NOTE]
> The Java part of this mod (bu-zb.jar) runs through the [ZombieBuddy](https://github.com/zed-0xff/ZombieBuddy) framework. Install ZombieBuddy first, then enable both mods. Subscribing alone does not enable it.

- Supported: Build 42.21 / 42.22 / modversion 0.6.0
- Runs on ZombieBuddy 2.x (stable) and 3.x (beta), no -javaagent line of its own
- Client-side only. No server installation needed
- Singleplayer and MP host supported. Disabled on MP clients (they have no local save)
- English only. UI text is hardcoded, not looked up through the game's translation system, so it reads the same in every language setting

## Controls

One key does both jobs. It is `F8` by default and can be rebound in Mod Options (`[BU]`). (`F6` was avoided because it is the vanilla fast-forward shortcut.)

| Screen | Action |
| --- | --- |
| In-game | Manual backup |
| Title screen | Toggle the restore list (open / close) |

Because backup is in-game-only and restore is title-only, the two never collide on the same keypress.

### Backup (in-game)

1. Press the key. The game is paused (`speed 0`) and autosave is suppressed on a best-effort basis.
2. The world is saved, then the save folder is copied to the backup location.
3. A halo notification reports the result.

> [!TIP]
> The safest way to back up is a 3-step sequence: 1) open the ESC menu (game paused), 2) press the key — the start notification confirms the backup has begun, 3) close the menu and return to the game. The backup does not progress while the ESC menu is open: it needs the game ticking, so it runs after you return, and the done/failed notification fires the moment it finishes (including a return to normal game state).

### Restore (title screen)

1. Press the key to open the list. Entries are sorted newest first, 8 per page.
2. Click a slot to select it (the button turns into a confirm prompt).
3. Click the same slot again within 8 seconds to confirm. Restore overwrites the live save folder.

Paging exists instead of scrolling so the window keeps a fixed height and never grows off-screen.

## Where backups are stored

```text
<user.home>/Zomboid/BU/<mode>__<saveName>\
```

| Platform | Resolved path |
| --- | --- |
| Windows | `C:\Users\<you>\Zomboid\BU\` |
| macOS | `/Users/<you>/Zomboid/BU/` |
| Linux | `/home/<you>/Zomboid/BU/` |

- The root comes from Java `user.home`, so it resolves to the same folder on every platform. macOS and Linux (native or Proton) are fine.
- **This is a folder inside the game's save root, not outside it.** It sits next to `Sandbox/`, `Multiplayer/` and `mods/`:

```text
~/Zomboid/
  Sandbox/     game saves
  Multiplayer/
  mods/
  BU/          <- this mod's backups
```

- Deleting a save from inside the game only removes `~/Zomboid/Sandbox/<saveName>`, so your backups survive that. **Wiping the whole `Zomboid` folder does delete them** (PZ reinstall, "clean install" steps). Copy the `BU` folder elsewhere if that matters to you.
- **One fixed slot per save.** No timestamp generations. Backing up the same world repeatedly overwrites its own slot, so there is exactly one "last known good" copy per world and no old copies to sift through.
- Every write is `tmp` -> verify -> swap, so a failed or interrupted backup never destroys the previous good copy. The swap step is a same-volume rename.

## Options

Change them in Mod Options on the title screen.

| Option | Default | Description |
| --- | --- | --- |
| Show Notifications | On | Halo notification and log line for backup / restore progress |
| Enable Manual Key | On | Enables the manual key. In-game: backup. Title screen: toggle restore list |

## Requirements / Installation

### 1. Install ZombieBuddy (required)

BU's Java side runs through the [ZombieBuddy](https://github.com/zed-0xff/ZombieBuddy) framework. Once installed, it also loads the Java code of other mods (BU included) — no per-mod `-javaagent` line is needed.

- **Windows (recommended)**: run [ZombieBuddyInstaller.exe](https://github.com/zed-0xff/ZombieBuddy/releases/tag/windows_installer). It detects Steam and the game automatically, copies the framework files and sets the launch option. Being subscribed to the ZombieBuddy Workshop item is required for it to work.
- **macOS / Linux (manual)**: copy `ZombieBuddy.jar` to the game folder and add the following to launch options (don't forget the trailing `--`):

```text
-javaagent:ZombieBuddy.jar --
```

### 2. Enable BU

Subscribe to this Workshop item and enable **BU** (and **ZombieBuddy**) in the mod list. No jar copying, no launch-option editing.

On the first launch, ZombieBuddy shows a one-time approval dialog for BU's Java jar (`42/media/java/bu-zb.jar` inside the mod — a plain, unsigned jar). Approve it, or approve permanently for this author/jar; the dialog does not reappear afterwards.

## Verify / Update / Remove

- Check that the startup log contains `[BU] mod jar loaded rev=...` (ZombieBuddy) and `[BU] core loaded v...`. If the bridge is missing, `BU.Debug()` reports `bridge=false`, which means ZombieBuddy did not load the jar: is the ZombieBuddy launch option set, is the mod enabled, and was the jar approved?
- jar updates are announced in the Workshop changelog and are picked up automatically on the next launch — nothing to re-copy.
- To disable, disable the mod (and ZombieBuddy, if you no longer use other Java mods).
- Note: no server installation needed (client-side only).

## Notes

- The Java agent hooks exactly one game method (`LuaManager$Exposer.exposeAll`) to publish the backup bridge to Lua. The backup logic itself is plain `java.nio` file copying, so it is not tied to a specific game build.
- The pause and autosave suppression during a backup are best-effort. They reduce the chance of a write landing mid-copy but are not a hard lock on the save files.
- If a file is momentarily locked (common with a large `map_*.bin` while the game holds it), the copy returns a transient error and is retried every 3 seconds, up to 60 attempts (about 3 minutes). If it never succeeds, the run fails and the previous good backup is left untouched.
- Restoring runs synchronously because the title screen has no tick pump to drive a background copy. The UI freezes while the files are copied; this is intentional and is also what prevents a second operation from starting mid-copy.
- Restore replaces the live save folder. Do not restore while a client is connected to that world.
- Because there are no generations, a restore overwrites whatever is in the slot. Copy the slot aside first if you want to keep it.

## Verification (Lua console)

```lua
-- Bridge, backup root, slot list and current save
BU.Debug()

-- Trigger a backup manually (same path as the hotkey)
BU.doBackup(true)

-- Restore a slot by name ("<mode>__<saveName>")
BU.doRestore("Sandbox__MyWorld")

-- Reopen the restore list from the console
BU.Reopen()

-- Clear a stuck run without writing anything (e.g. after a kill)
BU.Abort()

-- Dump restore-list window state
BU.WinState()
```

## Repository layout

```text
42/
  media/lua/shared/     Core: backup/restore flow, retry state machine
  media/lua/client/     Hotkey handling and the restore list window
  media/java/bu-zb.jar  Java bridge jar, loaded by ZombieBuddy
  mod.info              Single version folder for the whole B42 line
agent/src/              bu-zb.jar sources (ZombieBuddy edition)
```

## Building the jar

Requires a JDK 25 toolchain and a ZombieBuddy jar for compile-only use (auto-resolved from the subscribed Workshop items; override with `-PzbJar=<path>`).

```powershell
gradle -p agent clean jar -PbuRev=<tag>
```

The plain `jar` task writes the artifact directly to `42/media/java/bu-zb.jar`. `-PbuRev` is written into `bu/build-info.properties` and logged at startup as `[BU] mod jar loaded rev=<tag>`. Omitting it produces `unversioned`.

## Credits

- Built on the [ZombieBuddy](https://github.com/zed-0xff/ZombieBuddy) modding framework (2.x / 3.x), which provides the Lua exposure this edition relies on.

## License

MIT License. See `LICENSE` for details.
