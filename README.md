# BU - Manual backup and restore mod for Project Zomboid

A Java mod for Project Zomboid B42. Backs up the current save on a hotkey, and restores it from the title screen.

Project Zomboid autosaves on its own schedule, which means the newest save on disk is never necessarily the state you want. This mod adds an explicit, on-demand backup you trigger yourself, so there is a known-good copy you can roll back to.

> [!NOTE]
> The Java part ships in two forms — pick **one** install style:
> - **ZombieBuddy style (recommended)**: runs through the [ZombieBuddy](https://github.com/zed-0xff/ZombieBuddy) framework. No `-javaagent` line of BU's own.
> - **javaagent style**: the classic `-javaagent:bu-agent.jar` line, no ZombieBuddy needed.
>
> If both are present at once, the javaagent bridge wins and the ZombieBuddy side stays idle — no double bridge.

- Supported: Build 42.21 / 42.22 / modversion 0.6.0
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

Choose **one** of the two styles below. Both are equally supported; ZombieBuddy is easier if you already use it or run other Java mods.

### Style A — ZombieBuddy (recommended)

1. Install the [ZombieBuddy](https://github.com/zed-0xff/ZombieBuddy) framework (works with 2.x stable and 3.x beta):
   - **Windows**: run [ZombieBuddyInstaller.exe](https://github.com/zed-0xff/ZombieBuddy/releases/tag/windows_installer). It detects Steam and the game automatically, copies the framework files and sets the launch option. Being subscribed to the ZombieBuddy Workshop item is required for it to work.
   - **macOS / Linux (manual)**: copy `ZombieBuddy.jar` to the game folder and add the following to launch options (keep the trailing `--`):

     ```text
     -javaagent:ZombieBuddy.jar --
     ```
2. Subscribe to this Workshop item and enable **BU** (and **ZombieBuddy**) in the mod list. No jar copying, no launch-option editing of BU's own.
3. On the first launch, ZombieBuddy shows a one-time approval dialog for BU's Java jar (`42/media/java/bu-zb.jar` inside the mod — a plain, unsigned jar). Approve it, or approve permanently for this author/jar; the dialog does not reappear afterwards.
4. jar updates are picked up automatically on the next launch — nothing to re-copy.

### Style B — javaagent (no ZombieBuddy)

1. Point the launcher, or copy the jar manually, at the file below from the Workshop install:

   ```text
   <SteamLibrary>\steamapps\workshop\content\108600\3827082187\mods\BU\42\agent\<game-build>\bu-agent.jar
   ```

   `<game-build>` is `42.21` or `42.22` — match your Project Zomboid build. Note: `<SteamLibrary>` varies by environment (default is `C:\Program Files (x86)\Steam`); check via Steam "Settings -> Storage" or game Properties -> "Installed Files" -> "Browse".
   - **Windows (launcher)**: no manual JVM option editing needed. Point [PZ-JAM-Launcher](https://github.com/kawatarenosora/PZ-JAM-Launcher) to the jar above and launch.
   - **Windows (manual)**: quit the game, copy the jar into a folder (`C:\PZAgents` is a common choice), back up `ProjectZomboid64.json` in the game folder, and add the following inside the existing `vmArgs` array (mind the commas with neighboring entries):

     ```json
     "-javaagent:C:/PZAgents/bu-agent.jar"
     ```
   - **macOS / Linux (manual)**: copy the jar somewhere stable (e.g. `~/PZAgents/`) and add to Project Zomboid Properties -> "Launch Options" (keep the trailing `--`):

     ```text
     -javaagent:"~/PZAgents/bu-agent.jar" --
     ```
2. Subscribe to this Workshop item and enable **BU** in the mod list.
3. jar updates are announced in the Workshop changelog. Manual-setup users should re-copy after the announcement (launcher users need no reconfiguration).

## Verify / Remove

- Check that the startup log contains a `[BU]` line:
  - Style A: `[BU] mod jar loaded rev=...` then `[BU] bu.BUControl exposure requested`.
  - Style B: `[BU-Agent] loaded rev=... enabled=true`.
  - Both then log `[BU] core loaded v...`.
- If the bridge is missing, `BU.Debug()` reports `bridge=false`. For Style A, that means ZombieBuddy did not load the jar (launch option, mod enabled, jar approval). For Style B, it means `-javaagent` was not picked up.
- To disable, remove the mod (and for Style B, the `-javaagent` line; for Style A, ZombieBuddy only if you no longer use other Java mods).
- Note: no server installation needed (client-side only).

## Notes

- One of the two bridges publishes the backup bridge to Lua: the `-javaagent` hook (`bu.Agent` hooks `LuaManager$Exposer.exposeAll`) or the ZombieBuddy mod load (`bu.Main` reflectively calls `Exposer.exposeClass`). Exactly one is active at a time; the backup logic itself is plain `java.nio` file copying, so it is not tied to a specific game build.
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
  media/java/bu-zb.jar  Java bridge jar, loaded by ZombieBuddy (style A)
  agent/42.21/bu-agent.jar  Agent jar built for game rev 4a0e9546ec (style B)
  agent/42.22/bu-agent.jar  Agent jar built for game rev e013dbb529 (style B)
  mod.info              Single version folder for the whole B42 line
agent/src/              Sources for both jars (dual edition)
```

## Building the jars

Requires a JDK 25 toolchain. The ZombieBuddy jar for compile-only use is auto-resolved from the subscribed Workshop items (override with `-PzbJar=<path>`).

```powershell
# bu-agent.jar (agent edition) - then copy build/libs/bu-agent.jar into 42/agent/<game-build>/
gradle -p agent clean shadowJar -PbuRev=<game-git-rev>

# bu-zb.jar (ZombieBuddy edition) - written directly to 42/media/java/bu-zb.jar
gradle -p agent clean jar -PbuRev=<tag>
```

`-PbuRev` is written into `bu/build-info.properties` and logged at startup (`[BU-Agent] loaded rev=...` / `[BU] mod jar loaded rev=...`). Omitting it produces `unversioned`.

## Credits

- Uses [ByteBuddy](https://bytebuddy.net/) as the hook foundation for the javaagent style; the ZombieBuddy style is loaded by the [ZombieBuddy](https://github.com/zed-0xff/ZombieBuddy) framework (2.x / 3.x).

## License

MIT License. See `LICENSE` for details.
