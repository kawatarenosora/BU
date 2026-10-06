# BU [agent] - Manual backup and restore mod for Project Zomboid

A JavaAgent mod for Project Zomboid B42.21. Backs up the current save on a hotkey, and restores it from the title screen.

Project Zomboid autosaves on its own schedule, which means the newest save on disk is never necessarily the state you want. This mod adds an explicit, on-demand backup you trigger yourself, so there is a known-good copy you can roll back to.

> [!NOTE]
> The Java part of this mod (bu-agent) must be specified via `-javaagent`. Subscribing alone does not enable it.

- Supported: Build 42.21 / modversion 0.5.0
- Client-side only. No server installation needed
- Singleplayer and MP host supported. Disabled on MP clients (they have no local save)
- English only. UI text is hardcoded, not looked up through the game's translation system, so it reads the same in every language setting

## Controls

One key does both jobs. It is `F6` by default and can be rebound in Mod Options (`[BU]`).

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
> Opening the ESC menu before pressing the key is the safest way to back up: the game is already paused, so nothing can write to the save while it is being copied.

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

### jar location (once published to Workshop)

> [!IMPORTANT]
> The Workshop item is not published yet. Until it is, use the manual setup below. This section is a placeholder: replace `<WORKSHOP_ID>` with the real ID once the item is up.

```text
<SteamLibrary>\steamapps\workshop\content\108600\<WORKSHOP_ID>\mods\BU\42.21\agent\bu-agent.jar
```

Note: `<SteamLibrary>` varies by environment (default is `C:\Program Files (x86)\Steam`).
How to check: Steam "Settings -> Storage" library folder, or game Properties -> "Installed Files" -> "Browse".

### Windows (recommended): use the launcher

No manual JVM option editing or jar copying needed. Just point [PZ-JAM-Launcher](https://github.com/kawatarenosora/PZ-JAM-Launcher) to the jar above and launch.

### Windows (manual setup)

1. Open `C:\` in Explorer, create a new folder named `PZAgents` (result: `C:\PZAgents`).
2. Quit the game and copy the jar above into `C:\PZAgents`.
3. Back up `ProjectZomboid64.json` in the game folder, then add the following line inside the existing `vmArgs` array (mind the commas with neighboring entries. No need to replace the whole array).

```json
"-javaagent:C:/PZAgents/bu-agent.jar"
```

Note: if you want another folder, replace the path accordingly (for advanced users).

### macOS / Linux (manual setup)

1. Create a `PZAgents` folder in your home folder and copy the jar above into it.
2. In Project Zomboid Properties -> "Launch Options", add the following (don't forget the trailing `--`).

```text
-javaagent:"~/PZAgents/bu-agent.jar" --
```

Note: if you want another folder, replace the path accordingly (for advanced users).

## Verify / Update / Remove

- Check that the startup log contains `[BU-Agent] loaded rev=...` and `[BU] core loaded v...`. If the bridge is missing, `BU.Debug()` reports `bridge=false`, which means `-javaagent` was not picked up.
- jar updates are announced in the Workshop changelog. Manual-setup users should re-copy after the announcement (launcher users need no reconfiguration).
- To disable, disable the mod and remove only the argument above.
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
42.21/
  media/lua/shared/   Core: backup/restore flow, retry state machine
  media/lua/client/   Hotkey handling and the restore list window
  agent/bu-agent.jar  Distributable Java agent
agent/src/            bu-agent sources (ByteBuddy hooks)
```

## Building the agent

Requires a JDK 25 toolchain.

```powershell
gradle -p agent clean shadowJar -PbuRev=<tag>
```

`-PbuRev` is written into `bu/build-info.properties` and logged at startup as `[BU-Agent] loaded rev=<tag>`. Omitting it produces `unversioned`.

## Credits

- Uses [ByteBuddy](https://bytebuddy.net/) as the hook foundation for the Java agent.

## License

MIT License. See `LICENSE` for details.
