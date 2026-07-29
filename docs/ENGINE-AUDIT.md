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
| 5 | UI layer | Context XML, controls, `InstanceManager`, tooltips, notifications | ☑ complete |
| 6 | Gameplay API coverage | Player/City/Unit/Plot methods; exposed vs DLL-only; the money-write problem | ☑ complete |
| 7 | Performance & correctness | Per-turn cost, caching, `Game.Rand` determinism | ☑ complete |
| 8 | Compatibility & packaging | Load order, VFS conflicts, `TopPanel` risk, multiplayer, DLC deps | ☑ complete |
| 9 | Synthesis | Final verdict + prioritised backlog | ☑ complete |

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

### The full surface

| Mechanism | What it gives you | Conflict risk |
|-----------|-------------------|---------------|
| `InGameUIAddin` context (Lua + XML) | Your own panel, fully isolated | **None** |
| `LuaEvents.AdditionalInformationDropdownGatherEntries` | An entry in the top-right menu | **None** — designed for this |
| **VFS file replacement** | Override a base-game UI file wholesale | **Total** — last mod loaded wins |
| `AddNotification` | Engine notification | None (no click event exists) |
| `InstanceManager` | Repeated rows from an XML template | None |

### What we do

8 addin panels + dropdown registration (zero-conflict), plus **one VFS replacement of
`UI/InGame/TopPanel.lua`**.

### Verdict — panels are exemplary, `TopPanel` is a landmine

The panels are the right pattern: isolated contexts, dropdown integration, no base files
touched. Hard-won rules already encoded — `include("InstanceManager")` is not automatic;
rows need `CalculateSize`/`ReprocessAnchoring`/`CalculateInternalSize` after populating or
the table renders empty; `TwCenMT` sizes must be even and ≥14; `<ScrollPanelContent>` is not
a real element; button callbacks receive `(void1, void2)` directly.

The `TopPanel.lua` replacement is the single biggest compatibility risk in the mod — see
`COMPAT-1`. It is also, unavoidably, the *only* way to modify the existing gold display and
its tooltip: there is no hook into the base top bar.

## 6. Gameplay API coverage

### The money-write problem — design validated

Every `*Times100` method the base game exposes is a **getter**: `GetGoldFromCitiesTimes100`,
`CalculateGrossGoldTimes100`, `CalculateGoldRateTimes100`, and six more. The only *writers*
are `ChangeGold` (24 uses) and `SetGold` (28) — both **whole gold only**. There is no
`SetGoldTimes100` or `ChangeGoldTimes100`.

**Conclusion: the copper-purse design is not merely reasonable, it is the only option.**
Fractional mod income cannot be written to the engine treasury; holding sub-gold in
`MapModData` and banking whole gold as it accumulates is the correct workaround.

Note the base game never calls a bare `GetGoldTimes100()` either, so our `pcall`-guarded
read very likely falls back to `GetGold() * 100`. That is harmless — the purse holds the
fraction, so the total stays exact — and it vindicates guarding the call.

### Other writers we depend on

| API | Base-game uses | Note |
|-----|---------------:|------|
| `ChangeGold` / `SetGold` | 24 / 28 | Well-trodden. |
| `ChangeNumResourceTotal` | 2 | The only resource writer. Ours is delta-based, which is right. |
| `ChangeHappiness` | **0** | **No base-game reference implementation** — see `API-1`. |

`ChangeHappiness` having zero base-game usage is worth respecting: it writes a real engine
value that persists in the save, which is exactly why the removed debt penalty needed an
unwind migration and why `TaxUnhappiness` must stay persisted.

### Determinism

Base game uses `Game.Rand` (29) alongside `math.random` (25). `Game.Rand` is seeded and
replay/multiplayer-safe. **We use `Game.Rand` exclusively — correct.**

## 7. Performance & correctness

Per-turn cost is dominated by repeated scans that are cheap individually but run per player:

- **`HasBondExchange(pPlayer)` is called twice per player per turn** in `Banking.lua`
  (lines 168 and 184), each walking that player's whole city list. One call, cached, would
  do — `PERF-2`.
- **`EcoWonderOwner` walks every player × every city.** Called once per turn by the stock
  and commodity engines (fine), plus per-player in Banking behind a short-circuit, plus on
  every panel refresh — `PERF-1`.
- **`EcoActiveCurrency()` runs on every money format call** — a `pcall`, a tech lookup and a
  `GameInfo.Civilizations` join. There are **65** `EcoFormat*` call sites, and table panels
  invoke them per row per redraw — `PERF-3`.

None of these will be visible on a small map; all are trivially fixable with a per-turn
cache. Correctness-wise the turn guards (`if turn == LastTurn then return end`) are the
right pattern and are now persisted, closing the double-pay-on-reload hole.

## 8. Compatibility & packaging

- **`TopPanel.lua` collision — `COMPAT-1`, the headline finding.** Corporations (BNW),
  which is installed, ships its own `UI/InGame/TopPanel.lua`: 1343 lines, 17 corp-specific
  references, `include("Corp_UI.lua")`, and corporate revenue folded into the gold-per-turn
  display. Ours is 860 lines with the g/s/c treasury, mod income and capital-market tooltip.
  VFS replacement is last-one-wins, so **enabling both silently guts one of them**. No error,
  no warning — just missing UI.
- Only 7 base-game UI filenames are overridden by *any* installed mod, and `TopPanel.lua` is
  the only one claimed twice. Our 8 panels collide with nothing.
- **Packaging is correct:** BNW DLC dependency declared, `SupportsMultiplayer=0` (honest —
  the mod is not MP-safe: `Game.Rand` is fine but per-context state and OOS risk are not
  audited), `AffectsSavedGames=1`, stable GUID.

## 9. Synthesis

**The architecture is sound.** Every foundational choice the mod makes is the one the
engine and the mature mod ecosystem support:

- `UpdateDatabase` + XML for content
- `InGameUIAddin` + an `import="1"` shared include for code
- the Additional Information dropdown for menu integration
- `MapModData` working set with `OpenSaveData` write-through for state
- `Game.Rand` for anything random
- the copper purse — provably the only way to represent fractional gold

Three of these were previously *assumptions*; this audit turned them into verified facts
(persistence, the gold-write limitation, the restore-at-include pattern).

**One real problem was found:** the `TopPanel.lua` replacement is mutually exclusive with
Corporations, which the user has installed. Everything else is efficiency polish.

Recommended order: `COMPAT-1` (real user-visible breakage) → `PST-1` (cheap insurance on
the one unobserved code path) → `CTX-1` (biggest structural cleanup) → the `PERF-*` items
(nice, not urgent) → `DB-1`/`EVT-1` (optional).

---

## Backlog

Severity: **H** = correctness/compat risk · **M** = worth doing · **L** = polish.

| ID | Sev | Area | Item | Status |
|----|-----|------|------|--------|
| `COMPAT-1` | **H** | Compatibility | **`UI/InGame/TopPanel.lua` collides with Corporations (BNW), which is installed.** VFS replacement is last-one-wins, so enabling both silently guts one mod's top bar — no error shown. Options: (a) drop the replacement and surface our figures in the Economy Dashboard / a small own-context overlay — zero conflict, slightly less integrated; (b) keep it and document the incompatibility; (c) detect Corporations at load and warn. | open |
| `PST-1` | M | Persistence | Confirm at runtime that the restore actually fires — print restored share/bond counts once on load. Cheap insurance on the one unobserved path. | open |
| `CTX-1` | M | Contexts | Consolidate the 7 logic addins into 1 entry point. 15 contexts → 9, 7 `PlayerDoTurn` handlers → 1, 7 copies of the shared include → 1. Also removes the cross-context write-back workarounds. | open |
| `PERF-1` | M | Performance | `EcoWonderOwner` walks every player × every city; called per panel refresh and per-player in Banking. Cache the owner once per turn (the wonder can only change on construction). | open |
| `PERF-2` | L | Performance | `HasBondExchange(pPlayer)` called twice per player per turn (`Banking.lua:168` and `:184`), each scanning all that player's cities. Call once, reuse. | open |
| `PERF-3` | L | Performance | `EcoActiveCurrency()` does a `pcall` + tech lookup + `GameInfo.Civilizations` join on **every** money format call; 65 call sites, invoked per row per redraw. Cache per turn. | open |
| `API-1` | L | Risk | `ChangeHappiness` has **zero** base-game usage — no reference implementation. Keep `TaxUnhappiness` persisted and treat any future happiness feature as needing an unwind path. | open |
| `EVT-1` | L | Events | Replace per-turn `HasTech()` polling in Banking/Taxation/Commodity with a cache maintained by `GameEvents.TeamTechResearched`. | open |
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
| Fractional money | Copper purse in `MapModData`, whole gold banked to the engine | **Provably the only option** — every `*Times100` API is a getter; `ChangeGold`/`SetGold` are whole-gold only. |
| Randomness | `Game.Rand` everywhere, never `math.random` | Seeded, replay- and multiplayer-safe. |
| Resource trading | Delta-based `ChangeNumResourceTotal` | The only resource writer the engine exposes. |
| Panels | Own `InGameUIAddin` contexts + dropdown entry | Zero file conflicts; our 8 panels collide with nothing across 40 installed mods. |
