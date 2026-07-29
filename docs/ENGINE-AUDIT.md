# Civ V Modding Surface — Audit of Economy Overhaul

A systematic map of every way a mod can interact with Civilization V, compared against
what **Economy Overhaul** actually does. Findings are verified against the local install
(`Steam/steamapps/common/Sid Meier's Civilization V/Assets`) and against other installed
mods, not from memory.

**Purpose:** confirm the architecture where it is right, and produce a concrete backlog
where it is not.

---

## Resume state

Work is chunked so it can stop and restart cleanly. Update the status column as chunks
complete; each chunk's findings land in its own section below, and anything actionable is
appended to the [Backlog](#backlog).

| # | Chunk | Scope | Status |
|---|-------|-------|--------|
| 1 | Database / XML layer | GameData tables, `UpdateDatabase` vs `UpdateUserSettings`, SQL vs XML, schema validation, `GlobalDefines` | ☐ not started |
| 2 | Lua entry points & contexts | `InGameUIAddin` and friends, VFS file replacement, `include()`, per-context `_G` | ☐ not started |
| 3 | Events & hooks | `GameEvents` vs `Events` vs `LuaEvents`, the useful catalog, return-value hooks, cost per turn | ☐ not started |
| 4 | State & persistence | `MapModData`, `OpenSaveData`, plot/unit/city `ScriptData` | ☐ not started |
| 5 | UI layer | Context XML, controls, `InstanceManager`, tooltips, notifications, dropdown integration | ☐ not started |
| 6 | Gameplay API coverage | Player/City/Unit/Plot/Team methods; what is exposed vs DLL-only; the money-write problem | ☐ not started |
| 7 | Performance & correctness | Per-turn cost, caching, `Game.Rand` determinism, floating-point drift | ☐ not started |
| 8 | Compatibility & packaging | Load order, VFS conflicts, `TopPanel` replacement risk, multiplayer, DLC deps | ☐ not started |
| 9 | Synthesis | Final verdict + prioritised backlog | ☐ not started |

**Legend:** ☐ not started · ◐ in progress · ☑ complete

---

## 1. Database / XML layer

_Not started._

## 2. Lua entry points & contexts

_Not started._

## 3. Events & hooks

_Not started._

## 4. State & persistence

_Not started._

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

Actionable items discovered during the audit. Severity: **H** = correctness/compat risk,
**M** = worth doing, **L** = polish.

| ID | Sev | Area | Item | Status |
|----|-----|------|------|--------|
| _(none yet)_ | | | | |

---

## Confirmed-good

Decisions the audit validated, recorded so they are not revisited.

| Area | Decision | Why it's right |
|------|----------|----------------|
| _(none yet)_ | | |
