# Reaper v1.4

Farms a user-selected set of bosses using **Lair Keys** / **Greater Lair Keys** (shared pool for all non-Belial bosses) and **Betrayer's Husks** (Belial). Each successful chest open consumes one item from the appropriate pool. When every selected boss is out of resources the script returns to town and disables itself.

## Requirements

- An active combat / orbwalker script — Reaper handles navigation and interaction only.
- **D4Assistant** (recommended) or the built-in map-click navigation (see below).
- Optionally **Alfred** for inventory management between runs.

## Setup

1. Drop the `Reaper` folder into your scripts directory.
2. Open the in-game menu → **Reaper**.
3. Under **Bosses to Farm**, tick the bosses you want to run.
4. Under **Settings**, pick your home town and toggle Alfred / Batmobile as desired.
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

## Navigation Modes

### D4Assistant (default)
Reaper writes a teleport command to `command.txt` and waits for D4Assistant to move you to the boss zone. No calibration needed.

### Built-in Map Navigation (D4Assistant disabled)
Reaper navigates to the boss using the in-game waypoint map. Calibrate click positions under **Boss Icon Alignment** before use.

### Batmobile Fallback
Whether or not the **Use Batmobile Navigation** toggle is on, BatmobilePlugin is automatically engaged as a fallback whenever a boss has no path file or a path-file walk completes without the altar in sight. Toggle the setting on to use Batmobile as the primary navigation everywhere.

## Belial Chest Automation

After Belial dies a "Ritual of Lies – Choose Reward" chest UI appears. This section automates clicking through it.

| Setting | Description |
|---|---|
| **Enable** | Turn on automated chest clicking |
| **Mode** | Manual / Round Robin / Random |
| **Target Boss** *(Manual)* | Fixed boss to always select |
| **Boss Pool** *(RR / Random)* | Which bosses to include in the pool |
| **Party Delay** | Extra ms before clicking Open (helps sync with party members) |

## Dungeon Reset

Resets all dungeons after every N completed runs (configurable). Useful for keeping dungeon layouts fresh.

## Combat Behaviour

During boss fights Reaper keeps the player within **15 units of the altar/anchor position**. If the player drifts further away (e.g. chasing a stray enemy), it walks back before re-engaging. Suppressor orbs are always chased regardless of distance.

## Settings Reference

| Setting | Default | Description |
|---|---|---|
| Use D4Assistant | On | Delegate teleports to D4Assistant via `command.txt` |
| Use Alfred | On | Hand off inventory/repair/restock to Alfred |
| Bosses to Farm | All off | Per-boss checkboxes — tick the ones you want to run |
| Dungeon Reset | Off | Reset dungeons every N runs |
| Dungeon Reset Interval | 10 | Runs between dungeon resets |

## Notes

- Inventory is scanned once at enable time. Re-enable to refresh.
- If the EGB / boss chest fails to despawn after several interact attempts, Reaper re-scans inventory: if stock remains the run retries; otherwise the boss is skipped.
- If the built-in map navigation fails to reach the boss zone after 3 retries it gives up and the outer task manager attempts again on the next cycle.
- Paths from your zone entrance to the altar are stored in `paths/<boss>_<variant>.lua`. Multiple variants are supported and the closest one is picked at runtime.
