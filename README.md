# Economy Overhaul — Sid Meier's Civilization V (Brave New World)

A complete economic layer for Civ V: **Brave New World**, built as seven interlocking
systems that share one living economy. All panels open from the **Additional Information**
menu at the top-right of the in-game screen.

> Single-player. Requires the **Brave New World** expansion. Stability: Beta.

## Systems

- **Banking** — your treasury earns floating interest (0.5–6%/turn), set by how heavily the
  corporate sector is borrowing, which rises in a boom and falls in a downturn. Build the
  **Bond Exchange** national wonder (+0.5%). *National Treasury* panel.
- **Commodity Market** — export strategic and luxury resources for recurring per-turn gold
  at supply/demand-driven prices; import what you lack. An empire always keeps 1 of each
  resource. Gated by the **Commodity Exchange** world wonder.
- **Financial Markets** — a stock market of six industry sectors with per-turn dividends,
  reinvestment, and AI traders. Gated by the **Global Stock Market** world wonder.
- **Taxation** — a national tax-rate lever (gold now, unhappiness later); unlocked by Currency.
- **Business Cycle** — a global boom/bust climate that moves interest rates, commodity demand,
  stock values, and tax takes together.
- **Sovereign Bonds** — buy and sell other civilizations' debt for coupon income, with
  discounts, yields, and default risk tied to each nation's finances.
- **Net Worth** — an *Economic Standing* scoreboard ranking every civilization you have met
  by total wealth (gold + stocks + bonds), with a soft "economic dominance" notice when one
  civilization takes a commanding lead. Informational only — it is not a victory condition.

Money is tracked internally in fractional currency (1 gold = 10 silver = 100 copper) and,
after researching Economics, displayed in each empire's historic currency.

## Installation

Copy the whole repository into a folder named `Economy Overhaul (v 2)` under:

```
Documents\My Games\Sid Meier's Civilization 5\MODS\
```

Then enable **Economy Overhaul** from the in-game Mods menu.

> **Note on cloud sync:** the `My Games\Sid Meier's Civilization 5` folder should be
> **excluded from any file-sync service** (Dropbox/OneDrive/Sync.com/pCloud). Sync
> conflict copies (`(# Edit conflict … #)`) of mod files and the compiled `cache\*.db`
> have repeatedly caused silent edit reverts, missing content, and crashes.

## Layout

```
Economy Overhaul.modinfo   # mod manifest (id a1b2c3d4-…-ef1234567900, version 2)
Lua/                       # per-subsystem logic (InGameUIAddin contexts) + EcoCurrency.lua include
UI/InGame/                 # panels (one per subsystem) + TopPanel.lua (BNW top-bar replacement)
XML/Buildings/             # Bond Exchange, Commodity Exchange, Global Stock Market wonders
```

## Saved-game persistence

`MapModData` does **not** survive save/load in Civ V — it is an in-memory table shared
between Lua contexts for the current session only. Anything kept solely there (treasury
purses, share and bond holdings, trade positions, tax rates) is silently lost on reload.

`Lua/EcoCurrency.lua` therefore writes the mod's state through to `Modding.OpenSaveData()`,
the engine's real per-save store. Since `SetValue`/`GetValue` accept scalars only, each
nested table is serialised to a single compact string; scalars are stored directly. State
is written on every turn *and* immediately after any panel action that changes it (so a
mid-turn save can't lose a trade), and restored once when the first mod context loads.

The whole layer is `pcall`-guarded: if persistence ever fails, the mod falls back to
fresh state rather than erroring.

## Design notes

Two features were built and then deliberately removed; both are preserved in git history.

- **National loans / sovereign debt**, including the debt-burden unhappiness penalty. It did
  not earn its complexity in play. Interest rates still float, now driven purely by corporate
  borrowing demand.
- **A custom Economic Victory** (`VICTORY_ECONOMIC`). The custom victory type itself worked —
  it was wrongly blamed for a crash that turned out to be a file-sync client renaming the mod
  manifest — but awarding it required tracking a sustained multi-turn streak in `MapModData`,
  whose survival across save/load this mod cannot rely on. The *Economic Standing* scoreboard
  and its dominance notice remain.
