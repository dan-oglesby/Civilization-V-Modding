-- ============================================================
-- Economy Overhaul: NetWorth.lua
--
-- Tracks each civilization's total economic standing:
--   net worth = gold + stock portfolio + foreign bonds
-- Each asset class is read nil-safe from the relevant Economy
-- Overhaul mod, so net worth is meaningful with this mod alone
-- (treasury gold) and richer as the others are added.
--
-- Also raises a soft "economic dominance" alert when one civ leads
-- by a wide margin for a sustained stretch. This is NOT a real
-- victory condition — just a notification and a scoreboard flag.
--
-- NOTE: Uses Lua 5.1 syntax — required by Civ5.
-- ============================================================

include("EcoCurrency")   -- gold/silver/copper money layer: EcoGetWealthCopper, ECO_COPPER_PER_GOLD

-- ============================================================
-- Constants
-- ============================================================

-- Economic Victory bar — deliberately a LATE-GAME, commanding-dominance condition, not early
-- relative noise. The leader must hold ALL of these at once, sustained, to win:
local DOMINANCE_MARGIN       = 1.5             -- net worth >= this multiple of 2nd place, AND
local VICTORY_SHARE          = 0.40            -- >= this share of all civs' combined net worth, AND
local VICTORY_FLOOR          = 2000000         -- >= this much net worth in COPPER (= 20,000 gold), AND
local VICTORY_ERA            = "ERA_INDUSTRIAL" -- the leader has reached at least this era, AND
local ECONOMIC_VICTORY_TURNS = 20              -- ...all sustained for this many turns.

-- ============================================================
-- Persistent storage
-- ============================================================

MapModData.EcoOverhaul_NetWorth        = MapModData.EcoOverhaul_NetWorth        or {}  -- [player] = net worth
MapModData.EcoOverhaul_NetWorthTurn    = MapModData.EcoOverhaul_NetWorthTurn    or -1
MapModData.EcoOverhaul_NWLeader        = MapModData.EcoOverhaul_NWLeader        or -1
MapModData.EcoOverhaul_NWLeaderStreak  = MapModData.EcoOverhaul_NWLeaderStreak  or 0
MapModData.EcoOverhaul_NWDominanceFlagged = MapModData.EcoOverhaul_NWDominanceFlagged or false
MapModData.EcoOverhaul_NWVictoryAwarded   = MapModData.EcoOverhaul_NWVictoryAwarded   or false

-- ============================================================
-- Component readers (all nil-safe)
-- ============================================================

-- Stock prices are denominated in COPPER, so this returns COPPER.
local function StockValue(iPlayer)
    local owned = MapModData.EcoOverhaul_StockOwned and MapModData.EcoOverhaul_StockOwned[iPlayer]
    local prices = MapModData.EcoOverhaul_StockPrices
    if owned == nil or prices == nil then return 0 end
    local v = 0
    for key, units in pairs(owned) do
        v = v + (units or 0) * (prices[key] or 0)
    end
    return v
end

local function BondValue(iPlayer)
    local held = MapModData.EcoOverhaul_BondHoldings and MapModData.EcoOverhaul_BondHoldings[iPlayer]
    local prices = MapModData.EcoOverhaul_BondPrice
    if held == nil or prices == nil then return 0 end
    local v = 0
    for iIssuer, units in pairs(held) do
        v = v + (units or 0) * (prices[iIssuer] or 0)
    end
    return v
end

-- Exposed so the panel can show a breakdown without recomputing.
-- All four values are returned in COPPER (1 gold = 100 copper) so the
-- gold/stocks/bonds mix is consistent (stock prices are copper).
function EcoOverhaul_NetWorthComponents(iPlayer)
    local pPlayer = Players[iPlayer]
    if pPlayer == nil then return 0, 0, 0, 0 end
    local gold   = EcoGetWealthCopper(pPlayer)                  -- copper (treasury + purse)
    local stocks = StockValue(iPlayer)                          -- copper (prices are copper)
    local bonds  = BondValue(iPlayer) * ECO_COPPER_PER_GOLD     -- bond prices are gold -> copper
    return gold, stocks, bonds, (gold + stocks + bonds)
end

-- ============================================================
-- Economic Victory
-- ============================================================

-- Award the Economic Victory to a player's team and end the game. Uses the custom
-- VICTORY_ECONOMIC type if it loaded, else falls back to an existing victory type so
-- the game still ends with a win. (Same Game.SetWinner + GAMESTATE_OVER pattern the
-- base-game DLC scenarios use to force a result.)
local function AwardEconomicVictory(iPlayer)
    if MapModData.EcoOverhaul_NWVictoryAwarded then return end
    local p = Players[iPlayer]
    if p == nil then return end
    MapModData.EcoOverhaul_NWVictoryAwarded = true

    local vicID = GameInfoTypes["VICTORY_ECONOMIC"]
    if vicID == nil then return end
    Game.SetWinner(p:GetTeam(), vicID)
    Game.SetGameState(GameplayGameStateTypes.GAMESTATE_OVER)
end

-- ============================================================
-- Per-turn computation + dominance check (turn-guarded)
-- ============================================================

local function ComputeNetWorth()
    local iTurn = Game.GetGameTurn()
    if iTurn == MapModData.EcoOverhaul_NetWorthTurn then return end
    MapModData.EcoOverhaul_NetWorthTurn = iTurn

    local best, second, bestPlayer = -1e18, -1e18, -1
    local total = 0
    for iP = 0, GameDefines.MAX_MAJOR_CIVS - 1 do
        local p = Players[iP]
        if p ~= nil and p:IsAlive() and not p:IsMinorCiv() and not p:IsBarbarian() then
            local _, _, _, nw = EcoOverhaul_NetWorthComponents(iP)
            MapModData.EcoOverhaul_NetWorth[iP] = nw
            if nw > 0 then total = total + nw end
            if nw > best then
                second = best; best = nw; bestPlayer = iP
            elseif nw > second then
                second = nw
            end
        else
            MapModData.EcoOverhaul_NetWorth[iP] = nil
        end
    end

    -- Economic Victory is tracked ONLY when it is enabled for this game (the setup-screen
    -- victory toggle) and the victory type loaded. Otherwise no race, no warning, no award.
    local ecoVicID = GameInfoTypes["VICTORY_ECONOMIC"]
    if ecoVicID == nil or not PreGame.IsVictory(ecoVicID) then
        MapModData.EcoOverhaul_NWLeader = -1
        MapModData.EcoOverhaul_NWLeaderStreak = 0
        MapModData.EcoOverhaul_NWDominanceFlagged = false
        return
    end

    -- The late-game bar: a COMMANDING, sustained grip on the world economy — high absolute
    -- net worth, a majority-sized share of all civs' wealth, a clear margin over 2nd place,
    -- AND the leader has reached the industrial age. Early relative noise can't satisfy this.
    local eraGate   = GameInfoTypes[VICTORY_ERA]
    local leaderEra = (bestPlayer >= 0 and Players[bestPlayer] ~= nil) and Players[bestPlayer]:GetCurrentEra() or 0
    local dominant  = (bestPlayer >= 0)
        and (best >= VICTORY_FLOOR)
        and (total > 0 and best >= total * VICTORY_SHARE)
        and (second <= 0 or best >= second * DOMINANCE_MARGIN)
        and (eraGate == nil or leaderEra >= eraGate)

    if dominant and bestPlayer == MapModData.EcoOverhaul_NWLeader then
        MapModData.EcoOverhaul_NWLeaderStreak = (MapModData.EcoOverhaul_NWLeaderStreak or 0) + 1
    elseif dominant then
        MapModData.EcoOverhaul_NWLeader = bestPlayer
        MapModData.EcoOverhaul_NWLeaderStreak = 1
        MapModData.EcoOverhaul_NWDominanceFlagged = false
    else
        MapModData.EcoOverhaul_NWLeader = -1
        MapModData.EcoOverhaul_NWLeaderStreak = 0
        MapModData.EcoOverhaul_NWDominanceFlagged = false
    end

    local streak = MapModData.EcoOverhaul_NWLeaderStreak or 0

    -- Activation: announce the race the first turn the bar is crossed.
    if dominant and not MapModData.EcoOverhaul_NWDominanceFlagged then
        MapModData.EcoOverhaul_NWDominanceFlagged = true
        local pLeader = Players[bestPlayer]
        if pLeader ~= nil then
            local who = (bestPlayer == Game.GetActivePlayer())
                and "Your civilization has"
                or  (pLeader:GetCivilizationShortDescription() .. " has")
            EcoNotifyAll("Economic Victory Race Begun",
                who .. " seized a commanding share of the world economy. Holding this dominance for "
                .. ECONOMIC_VICTORY_TURNS .. " turns wins an [COLOR_POSITIVE_TEXT]Economic Victory[ENDCOLOR].")
        end
    end

    -- Win once the lead is sustained for the full duration.
    if dominant and streak >= ECONOMIC_VICTORY_TURNS then
        AwardEconomicVictory(bestPlayer)
    end
end

function OnPlayerDoTurn_NetWorth(iPlayer)
    local pPlayer = Players[iPlayer]
    if pPlayer == nil then return end
    if pPlayer:IsMinorCiv() or pPlayer:IsBarbarian() then return end
    ComputeNetWorth()  -- first caller each turn does the work
end

GameEvents.PlayerDoTurn.Add(OnPlayerDoTurn_NetWorth)

print("Economy Overhaul: NetWorth.lua loaded.")
