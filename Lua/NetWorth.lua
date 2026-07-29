-- ============================================================
-- Economy Overhaul: NetWorth.lua
--
-- Tracks each civilization's total economic standing:
--   net worth = gold + stock portfolio + foreign bonds
-- Each asset class is read nil-safe from the relevant Economy
-- Overhaul module, so net worth is meaningful with treasury gold
-- alone and richer as the markets come online.
--
-- Also raises a soft "economic dominance" alert when one civ leads by
-- a wide margin. This is purely informational — it is NOT a victory
-- condition and does not affect how the game ends. (A custom Economic
-- Victory type was tried and removed; the sustained-streak tracking it
-- needed depends on MapModData surviving save/load, which is not
-- something this mod can rely on.)
--
-- NOTE: Uses Lua 5.1 syntax — required by Civ5.
-- ============================================================

include("EcoCurrency")   -- gold/silver/copper money layer: EcoGetWealthCopper, ECO_COPPER_PER_GOLD

-- ============================================================
-- Constants
-- ============================================================

-- The bar for the informational "commanding lead" notice. Set high enough that
-- ordinary early-game noise can't trip it: the leader must clear ALL three.
local DOMINANCE_MARGIN = 1.5        -- net worth >= this multiple of 2nd place, AND
local DOMINANCE_SHARE  = 0.40       -- >= this share of all civs' combined net worth, AND
local DOMINANCE_FLOOR  = 2000000    -- >= this much net worth in COPPER (= 20,000 gold)

-- ============================================================
-- Persistent storage
-- ============================================================

MapModData.EcoOverhaul_NetWorth           = MapModData.EcoOverhaul_NetWorth           or {}  -- [player] = net worth
MapModData.EcoOverhaul_NetWorthTurn       = MapModData.EcoOverhaul_NetWorthTurn       or -1
MapModData.EcoOverhaul_NWLeader           = MapModData.EcoOverhaul_NWLeader           or -1
MapModData.EcoOverhaul_NWDominanceFlagged = MapModData.EcoOverhaul_NWDominanceFlagged or false

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
-- Per-turn computation + dominance notice (turn-guarded)
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

    -- A commanding, unmistakable grip on the world economy: high absolute net worth,
    -- a large share of all civs' wealth, and a clear margin over second place.
    local dominant = (bestPlayer >= 0)
        and (best >= DOMINANCE_FLOOR)
        and (total > 0 and best >= total * DOMINANCE_SHARE)
        and (second <= 0 or best >= second * DOMINANCE_MARGIN)

    if dominant and bestPlayer ~= MapModData.EcoOverhaul_NWLeader then
        -- A new civ has taken the lead: re-arm so the notice can fire for them.
        MapModData.EcoOverhaul_NWLeader = bestPlayer
        MapModData.EcoOverhaul_NWDominanceFlagged = false
    elseif not dominant then
        MapModData.EcoOverhaul_NWLeader = -1
        MapModData.EcoOverhaul_NWDominanceFlagged = false
    end

    -- Announce once per leader, purely as flavour/intel. No victory is implied or awarded.
    if dominant and not MapModData.EcoOverhaul_NWDominanceFlagged then
        MapModData.EcoOverhaul_NWDominanceFlagged = true
        local pLeader = Players[bestPlayer]
        if pLeader ~= nil then
            local who = (bestPlayer == Game.GetActivePlayer())
                and "Your civilization has"
                or  (pLeader:GetCivilizationShortDescription() .. " has")
            EcoNotifyAll("Economic Dominance",
                who .. " taken a commanding share of the world economy. "
                .. "Check [COLOR_POSITIVE_TEXT]Economic Standing[ENDCOLOR] in the Additional Information menu to see the full ranking.")
        end
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
