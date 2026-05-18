# Reaper v2.2

Farms a user-selected set of bosses using **Lair Keys** / **Greater Lair Keys** (shared pool for all non-Belial bosses) and **Betrayer's Husks** (Belial). Each successful chest open consumes one item from the appropriate pool. When every selected boss is out of resources the script returns to town and disables itself.

## Requirements

- An active combat / orbwalker script — Reaper handles navigation and interaction only.
- Optionally **BatmobilePlugin** for autonomous A\* navigation (auto-engages as a fallback when path files fail).
- Optionally **Alfred** for inventory management between runs. Detected fork-aware — works with both `AlfredTheButler-main` and `SteroidAlfredButler`.
- Optionally **LooteerPlugin** (LooterV3) for live loot-pacing. When loaded, post-chest pauses end as soon as Looter reports nothing left to pick up; otherwise the **Chest Loot Delay** slider is used as a fallback.

## Setup

1. Drop the `Reaper` folder into your scripts directory.
2. Open the in-game menu → **Reaper**.
3. Under **Bosses to Farm**, pick a **Rotation Mode**:
   - **Manual** — farm one specific boss (pick from the dropdown).
   - **Round Robin** — cycle through ticked bosses, one run each.
   - **Random** — pick a random ticked boss for every run.
4. Under **Settings**, pick your home town and toggle Alfred / Batmobile / Looter / Orbwalker management as desired.
5. Make sure your combat script is running.
6. Click **Enable**.

On enable, Reaper dumps every dungeon-key and consumable item in the console (with SNO IDs and stack counts) so you can verify the constants in `core/materials.lua` if a future patch reshuffles the SNOs.

## Item / Inventory Model

Each boss requires a specific key tier — pools are tracked separately, not pooled:

| Item | SNO | Used by |
|---|---|---|
| **Lair Key** | `2556388` / `2558178` | Varshan, Grigoire, Lord Zir, Beast in Ice, Urivar |
| **Greater Lair Key** | `2558255` | Duriel, Andariel, Bloody Butcher, Harbinger of Hatred |
| **Betrayer's Husk** | `2194099` | Belial — `HUSK_COST_BELIAL` (default 2) per run |

The two Lair Key SNOs (regular + Initiate) are functionally the same item and both feed the Lair Key pool.

Each boss's required key is set by its `key_tier` field in `data/enums.lua`. Edit that file to change which tier a boss expects. A boss is removed from the rotation when its required tier hits zero, regardless of whether other tiers still have stock.

## Run Flow

For every run Reaper:

1. **Teleports** to the boss dungeon via `teleport_to_boss_dungeon(sno)`.
2. **Navigates** to the summoning altar (path file → Batmobile fallback).
3. **Interacts** with the altar to summon the boss (consumes one key / husks).
4. **Holds the player** within ~15 units of the altar while the combat script kills the boss.
5. **Opens the main chest** that spawns on the boss's death.
6. **Sweeps for additional `EGB_Chest_*` actors** — on lucky runs two or three chests pop together; Reaper opens each of them (de-duped by position so it never re-clicks a despawning chest).
7. **Scans for `Warplans_Portal_NemesisPortal`** for ~12 s. If the random Nemesis portal spawned, walks in, hands off to `nemesis_fight`, and clears the random-boss lair until the 30 s no-kill timer expires. Then teleports home. If no portal spawned, runs the standard post-chest pause and moves on.
8. **Counts the run** (decrements the appropriate pool) and starts the next boss in the rotation.

## Loot Pacing

Two ways to gate the post-chest pause:

- **Use Looter Integration** (default **on**) — Reaper polls `LooteerPlugin.is_actively_looting()` every tick. After a 2 s settle window for drops to spawn into the actor list, the pause ends the instant Looter reports nothing left to loot. The altar gate, chest-complete pause, and Nemesis-lair teleport-out all use the same helper. No more guessing how long to wait.
- **Chest Loot Delay (s)** — fixed-duration fallback used when Looter integration is off or LooteerPlugin isn't loaded. Slider range 0–60 s, default 20 s.

LooterV3 must be at v3 release with the `is_actively_looting()` global; without it, Reaper silently falls back to the slider value.

## Navigation

From the dungeon entrance:

1. **Path-file walk (default).** A pre-recorded waypoint file under `paths/<boss>_<variant>.lua` drives the player to the altar. Multiple variants are supported; Reaper picks the closest one to the player on entry.
2. **Batmobile fallback (automatic).** If no path file exists, or a path-file walk completes without the altar in sight, Reaper auto-engages **BatmobilePlugin**'s `navigate_long_path` (uncapped A\*) the rest of the way. No toggle needed — it just works when Batmobile is loaded.
3. **Use Batmobile Navigation toggle (optional).** Tick this in **Settings** to make Batmobile the primary nav everywhere, skipping path files. Useful when Blizzard reshuffles dungeon layouts and the recorded paths drift.

## Belial Chest Automation

After Belial dies a "Ritual of Lies – Choose Reward" chest UI appears. This section automates clicking through it.

| Setting | Description |
|---|---|
| **Enable** | Turn on automated chest clicking |
| **Mode** | Manual / Round Robin / Random |
| **Target Boss** *(Manual)* | Fixed boss to always select |
| **Boss Pool** *(RR / Random)* | Which bosses to include in the pool |
| **Party Delay** | Extra ms before clicking Open (helps sync with party members) |

### Chest Dialog Alignment

The "Choose Reward" dialog can't be inspected through any plugin API — Reaper interacts with it by injecting mouse clicks at known positions. Coordinates are stored as **pixels at a 1920x1080 reference resolution** and converted at click time using **center-aware scaling** (`screen_w/2 + (ref_x − 960) × screen_h/1080`), so 21:9 / 32:9 ultrawide displays don't drift. Tune the positions under **Belial Chest Automation → Chest Dialog Alignment**:

1. Tick **Show crosshairs on screen**. Coloured `+` marks appear at every stored position even when the farmer is disabled.
2. Kill Belial (or trigger the dialog any way you like) so the Ritual of Lies UI is on screen.
3. Adjust the `Slot Y1`–`Slot Y7` sliders so the white crosshairs land on each boss row in the list.
4. Adjust **Slot X (column)** so the crosshairs sit on the boss button, not next to it.
5. Adjust **Modify Reward**, **Scroll**, and **Open** X/Y so each coloured crosshair sits on the matching button.
6. Untick **Show crosshairs** when done.

Defaults match the values that were hard-coded in earlier versions; you only need to recalibrate if a game patch reshuffles the dialog layout, or if you run an unusual aspect ratio where the `screen_h/1080` scaling alone is insufficient.

## Dungeon Reset

Resets all dungeons after every N completed runs (configurable). Useful for keeping dungeon layouts fresh.

## Combat Behaviour

During boss fights Reaper keeps the player within **15 units of the altar/anchor position**. The anchor is the live altar actor if visible, otherwise the **cached altar position** stored at interact-time (so the tether stays correct after the altar despawns — fixes the previous "Butcher walks to the corner" bug). Suppressor orbs are always chased regardless of distance.

If **Manage Orbwalker** is enabled, Reaper toggles `clear`-mode and `block-movement` on for combat phases and off during navigation. Leave it **off** if your combat script owns the orbwalker.

## Orchestrator API

Reaper exposes a `ReaperPlugin` global for orchestrator scripts (e.g. WarMachine, WarPigs).

```lua
-- Enable / disable
ReaperPlugin.enable()
ReaperPlugin.disable()

-- Force a single-boss rotation (no checkbox UI needed).
-- run_type: "lair" | "greater" | "husk" — nil to infer from the enum.
ReaperPlugin.run_boss("duriel", nil)

-- One-shot run: kill once, return to town, halt. Optional callback fires
-- after Reaper reaches town and before it disables itself.
ReaperPlugin.run_once("duriel", nil, function()
    console.print("Reaper done — handing back control")
end)

-- Sigil dungeons go through the same one-shot API by passing "sigil" as the
-- run_type. Reaper teleports to the boss zone, watches for enemies to clear
-- (5 s no-enemy timeout), returns to town, and fires the callback. The
-- altar / chest steps are skipped for sigil runs.
ReaperPlugin.run_once("duriel", "sigil", function() end)

-- Drop the external one-shot lock without disabling, so inventory-driven
-- rotation can resume.
ReaperPlugin.clear_external()

-- Snapshot of current state.
local s = ReaperPlugin.status()
-- => { enabled, busy, boss, external, total_runs, task }
```

`run_once` rotations are explicit one-shots: Reaper never extends the run from inventory even if the chest misbehaves or the altar appears reusable. The orchestrator owns "when to stop."

## Settings Reference

| Setting | Default | Description |
|---|---|---|
| Home town | Temis | Town to return to between runs (matches Alfred / Arkham). |
| Use Alfred | On | Hand off inventory/repair/restock to Alfred between runs. Auto-detects `AlfredTheButler` vs `SteroidAlfredButler` fork. |
| Use Batmobile Navigation | Off | Force Batmobile as the primary navigation. When off, path files run first and Batmobile auto-engages on failure. |
| Manage Orbwalker | Off | When on, Reaper toggles orbwalker `clear` + `block-movement` for combat phases. Leave off if your combat script owns the orbwalker. |
| Use Looter Integration | On | Poll `LooteerPlugin.is_actively_looting()` to end post-chest pauses as soon as Looter idles. Falls back to **Chest Loot Delay** if LooterV3 isn't loaded. |
| Chest Loot Delay (s) | 20 | Fallback duration for the post-chest pause when Looter integration is off or unavailable (0–60 s). |
| Bosses to Farm | All off | Per-boss checkboxes (Round Robin / Random) or single boss dropdown (Manual). |
| Rotation Mode | Round Robin | Manual / Round Robin / Random — how the script cycles through ticked bosses. |
| Dungeon Reset | Off | Reset dungeons every N runs. |
| Dungeon Reset Interval | 10 | Runs between dungeon resets. |

## Notes

- Inventory is scanned once at enable time. Re-enable to refresh.
- If the EGB / boss chest fails to despawn after several interact attempts, Reaper re-scans inventory: if stock remains the run retries; otherwise the boss is skipped.
- If the boss-dungeon teleport fails to reach the target zone after 3 retries it gives up and the outer task manager attempts again on the next cycle.
- Paths from your zone entrance to the altar are stored in `paths/<boss>_<variant>.lua`. Multiple variants are supported and the closest one is picked at runtime.
- The Nemesis bonus encounter uses `tracker.nemesis_entered` as a global handoff flag — `kill_monsters` and `navigate_to_boss` both yield to `nemesis_fight` whenever it's set, so the lair clear never has to fight task-manager priority.
