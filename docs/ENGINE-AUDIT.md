# Civ V Modding Surface — Audit of Economy Overhaul

A systematic map of every way a mod can interact with Civilization V, compared against
what **Economy Overhaul** actually does. Findings are verified against the local install
(`Steam/steamapps/common/Sid Meier's Civilization V/Assets`) and against the 40 other
installed mods — not from memory.

**Purpose:** confirm the architecture where it is right, and produce a concrete backlog
where it is not.

---

## Resume state

Work is chunked so it can stop and restart cleanly. Each chunk's findings land in its own
section; anything actionable is appended to the [Backlog](#backlog).

| # | Chunk | Scope | Status |
|---|-------|-------|--------|
| 1 | Database / XML layer | GameData tables, actions, SQL vs XML, custom tables, `Defines` | ☑ complete |
| 2 | Lua entry points & contexts | Entry-point types, VFS replacement, `include()`, per-context `_G` | ☑ complete |
| 3 | Events & hooks | `GameEvents` vs `Events` vs `LuaEvents`, catalog, cost per turn | ☑ complete |
| 4 | State & persistence | `MapModData`, `OpenSaveData`, `ScriptData` | ☑ complete |
| 5 | UI layer | Context XML, controls, `InstanceManager`, tooltips, notifications | ☐ not started |
| 6 | Gameplay API coverage | Player/City/Unit/Plot methods; exposed vs DLL-only; the money-write problem | ☐ not started |
| 7 | Performance & correctness | Per-turn cost, caching, `Game.Rand` determinism | ☐ not started |
| 8 | Compatibility & packaging | Load order, VFS conflicts, `TopPanel` risk, multiplayer, DLC deps | ☐ not started |
| 9 | Synthesis | Final verdict + prioritised backlog | ☐ not started |

**Legend:** ☐ not started · ◐ in progress · ☑ complete

**Method note:** counts below come from grepping the local install and
`Documents/My Games/Sid Meier's Civilization 5/MODS` (40 mods). "Across mods" = usage in
installed third-party mods, which is the best available evidence of what actually works.

---

## 1. Database / XML layer

### The full surface

| Mechanism | What it does | Usage across mods |
|-----------|--------------|-------------------|
| `<UpdateDatabase>` | Applies an `.xml` **or** `.sql` file to the game DB | **258** — the only action type in use |
| `<UpdateUserSettings>` | Writes to the user-settings DB | 0 |
| `<UpdateArtDefines>` / `<UpdateAudio>` / `<SetColorSet>` | Art/audio/colour registration | 0 (superseded — art now goes through `UpdateDatabase`) |
| `<OnModActivated>` | The action container | **38** — the only container in use |
| `<Table name=…><Column …/></Table>` | **Declares a custom DB table** | 3 (Corporations ×2, Civ Advanced ×1) |
| `Defines` table | Retunes **449** engine constants | 1 (Barbarians - Unlimited Exp) |
| `<Row>` / `<Update>` / `<Delete>` | Insert / modify / remove rows | widespread |

### What we do

3 `<UpdateDatabase>` XML files (Bond Exchange, Commodity Exchange, Global Stock Market)
inside one `<OnModActivated>`. No SQL, no custom tables, no `Defines` changes.

### Verdict — correct and idiomatic

`UpdateDatabase` + XML is the mainstream path and matches every other mod. Two hard-won
rules already encoded in our files and worth restating:

- Column names must match the base schema exactly (`GoldMaintenance`, **not** `Maintenance`)
  — an invalid column silently drops the entire row.
- Re-inserting an existing `TXT_KEY` with `<Row>` violates the unique constraint and rolls
  back **the whole file**, silently taking its buildings with it. Use `<Update><Set/><Where/></Update>`.

Both bugs bit this mod historically; both are fixed and the current XML is clean.

### Opportunities

- **SQL is available and we don't need it.** `.sql` via `UpdateDatabase` is confirmed
  working (4 mods use it). It wins for bulk/conditional edits (`UPDATE … WHERE cost > 200`).
  We only insert three new rows, so XML is the better fit. **No action.**
- **Custom GameData table for tuning constants** — see backlog `DB-1`. Our ~40 balance
  constants are Lua locals duplicated across logic and panel contexts (e.g. `TOTAL_SHARES`
  and `MAX_DEBT` were defined in two files each). A custom table read via `GameInfo` would
  give one source of truth and make the mod tunable without editing Lua.

---

## 2. Lua entry points & contexts

### The full surface

| Type | Purpose | Usage across mods |
|------|---------|-------------------|
| `InGameUIAddin` | Loads a Lua+XML context into the in-game UI. The workhorse. | **31** |
| `Map` | Map scripts | 4 |
| VFS file replacement | Ship a file with the same path as a base-game file to override it | used by us for `TopPanel.lua` |
| `<File import="1">` | An **include library**, not an entry point — pulled in with `include()` | our `EcoCurrency.lua`; Corporations' `Corp_Utils`/`TableSaverLoader` |

The game's own DLC packages (`.Civ5Pkg`) declare **no** entry points — they are pure content.
`InGameUIAddin` is effectively the only way to run gameplay Lua in a mod.

### What we do

**15** `InGameUIAddin` entry points (7 logic + 8 panels), 1 VFS file replacement
(`TopPanel.lua`), and 1 shared include (`EcoCurrency.lua`).

### Verdict — correct, but heavier than it needs to be

The structure is right: `InGameUIAddin` is the only real option, and `import="1"` for the
shared library is exactly how Corporations does it. Each addin gets its own `_G`, which is
why our distinctly-named globals never collide.

The cost is that **15 contexts each load their own full copy of `EcoCurrency.lua`** (~500
lines, now including the persistence layer) and each registers its own event handlers. The
7 logic files register **7 separate `GameEvents.PlayerDoTurn` handlers** that the engine
calls for every player every turn, where 1 would do.

### Opportunities

- **Consolidate the 7 logic addins into 1** — backlog `CTX-1`. Biggest single structural
  win available: 15 contexts → 9, 7 per-turn handlers → 1, 7 copies of the include → 1.
  The subsystems already communicate through `MapModData` and would simply become function
  calls in a defined order — which also removes the cross-context write-back dance.

---

## 3. Events & hooks

### The three families

- **`GameEvents.*`** — gameplay-side, invoked by the DLL. Some are *hooks* that consume a
  return value (`CityCanConstruct`, `PlayerCanConstruct`, `CanHaveAnyUpgrade`) and can veto.
- **`Events.*`** — UI-side engine events (turn start, data dirty, popups).
- **`LuaEvents.*`** — mod-to-mod / context-to-context messaging, freely definable.

### Catalog (by real usage across installed mods)

| Event | Uses | Note |
|-------|-----:|------|
| `GameEvents.PlayerDoTurn` | 48 | The dominant gameplay hook. |
| `GameEvents.CityCanConstruct` / `PlayerCanConstruct` | 11 | Veto hooks for build eligibility. |
| `GameEvents.TeamTechResearched` | 2 | Fires on tech completion. |
| `GameEvents.CityConstructed` / `BuildFinished` / `CityTrained` | 4 | Construction completion. |
| `Events.SerialEventGameMessagePopup` | 25 | Popups. |
| `Events.ActivePlayerTurnStart` | 19 | Human turn start. |
| `Events.SerialEventGameDataDirty` | 17 | "Refresh your UI" signal. |
| `Events.LoadScreenClose` | 8 | Fires once the game is fully loaded and UI contexts exist. |

### What we do

`GameEvents.PlayerDoTurn` ×7, `Events.ActivePlayerTurnStart` ×11,
`Events.SerialEventGameDataDirty` ×9, plus the standard BNW
`LuaEvents.AdditionalInformationDropdownGatherEntries` ×8 for menu integration.

### Verdict — right events, too many registrations

Every event we use is the correct one for its job, and the dropdown integration is the
sanctioned BNW pattern (no UI file conflicts). The registration *count* is the issue, and
it collapses naturally if `CTX-1` is done.

### Opportunities

- **Tech polling** — backlog `EVT-1`. Banking, Taxation and Commodity each call
  `HasTech()` for every player every turn. `GameEvents.TeamTechResearched` fires once when
  a tech completes and could maintain a cached flag instead.
- **Wonder-owner scans** — backlog `PERF-1` (see Chunk 7). `EcoWonderOwner` walks every
  player × every city; `GameEvents.CityConstructed` could maintain the owner incrementally.

---

## 4. State & persistence

### The full surface

| Store | Survives save/load? | Shape | Notes |
|-------|---------------------|-------|-------|
| Lua locals / `_G` | ✗ | anything | Per-context, per-session. |
| `MapModData` | **✗** | tables | Shared across contexts, **in-memory only**. |
| `Modding.OpenSaveData()` | **✓** | `SetValue`/`GetValue`, **scalars only** | The real per-save store. `.Query` gives raw SQLite. |
| `pPlot/pUnit/pCity:SetScriptData()` | ✓ | one string per object | Good for per-object state; we have none. |

**Evidence that `MapModData` does not persist:** zero uses anywhere in the base game's
`Assets`, while every DLC scenario needing persistence uses `OpenSaveData` (298 `SetValue`
+ 260 `GetValue` calls). InfoAddict and Corporations both keep working state in
`MapModData` *and* write it through to `OpenSaveData` — a layer that would be pointless if
`MapModData` survived. (Grepping a `.Civ5Save` proves nothing; saves are compressed.)

### What we do

`MapModData` as the working store, written through to `OpenSaveData` by a serialisation
layer in `EcoCurrency.lua`: nested tables → one compact string each, scalars stored
directly, key type tags so `owned[3]` and `owned["3"]` stay distinct. Restore runs once at
first include, guarded by a `MapModData` flag. Saves fire on `ActivePlayerTurnStart` **and**
after each of the 9 panel mutation sites.

### Verdict — validated against the reference implementation

`Corp_Bootstrap.lua` loads its persisted state **at script-load time inside an include**,
guarded by a `MapModData` flag, commented *"only do this once regardless of how many times
this file gets included"*. That is exactly our restore design, independently arrived at.

Where we differ, we are ahead: Corporations saves only on `PlayerDoTurn`, so a trade made
mid-turn is lost if the player saves before ending the turn. Our extra per-mutation saves
close that hole.

Persisting the turn guards is also deliberate and correct — without them a reload re-runs
the loaded turn's income and pays it twice.

### Opportunities

- **Restore timing is unverified at runtime** — backlog `PST-1`. Corporations proves
  load-time `OpenSaveData` access works, so this is low risk, but it has not been observed
  in *our* mod yet. A one-line `print()` of the restored share count would confirm it.
- **Save cost** — backlog `PST-2`. Each `EcoSaveState()` writes ~45 values. Buying shares
  calls it twice (`SetOwnedShares` + `SetFloat`). Harmless but trivially dedupable.

---

## 5. UI layer

_Not started._

## 6. Gameplay API coverage

_Not started._

## 7. Performance & correctness

_Not started._

## 8. Compatibility & packaging

_Not started._

## 9. Synthesis

_Not started._

---

## Backlog

Severity: **H** = correctness/compat risk · **M** = worth doing · **L** = polish.

| ID | Sev | Area | Item | Status |
|----|-----|------|------|--------|
| `CTX-1` | M | Contexts | Consolidate the 7 logic addins into 1 entry point. 15 contexts → 9, 7 `PlayerDoTurn` handlers → 1, 7 copies of the shared include → 1. Also removes the cross-context write-back workarounds. | open |
| `EVT-1` | L | Events | Replace per-turn `HasTech()` polling in Banking/Taxation/Commodity with a cache maintained by `GameEvents.TeamTechResearched`. | open |
| `PST-1` | M | Persistence | Confirm at runtime that the restore actually fires — print restored share/bond counts once on load. Cheap insurance on the one unobserved path. | open |
| `PST-2` | L | Persistence | `EcoSaveState()` runs twice per share trade (`SetOwnedShares` + `SetFloat`). Move the call up to the click handler. | open |
| `DB-1` | L | Database | Move the ~40 balance constants into a custom GameData table so they have one source of truth and are tunable without editing Lua. | open |

---

## Confirmed-good

Decisions the audit validated, recorded so they are not revisited.

| Area | Decision | Why it's right |
|------|----------|----------------|
| Database | `<UpdateDatabase>` + XML in `<OnModActivated>` | The only action type used across all 40 installed mods; SQL exists but suits bulk edits we don't have. |
| Text overrides | `<Update><Set/><Where/></Update>` for existing `TXT_KEY`s | A duplicate `<Row>` insert rolls back the entire file, silently dropping its buildings. |
| Schema | Column names checked against the base schema | An invalid column silently drops the whole row. |
| Entry points | `InGameUIAddin` + `import="1"` include | The only practical way to run mod Lua; matches Corporations exactly. |
| Menu integration | `LuaEvents.AdditionalInformationDropdownGatherEntries` | Sanctioned BNW extension point; no UI file conflicts with other mods. |
| Persistence store | `MapModData` working set + `OpenSaveData` write-through | Independently matches InfoAddict and Corporations; `MapModData` alone loses everything on reload. |
| Restore point | At first `include()`, guarded by a `MapModData` flag | Byte-for-byte the `Corp_Bootstrap.lua` pattern, and it beats each subsystem's `X = X or {}` defaults. |
| Save triggers | Per-turn **and** per-mutation | Strictly better than Corporations' per-turn-only, which loses mid-turn trades. |
| Turn guards persisted | Deliberate | Prevents a reload re-paying the loaded turn's income. |
