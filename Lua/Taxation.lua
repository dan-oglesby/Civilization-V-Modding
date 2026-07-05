-- ============================================================
-- Economy Overhaul: Taxation.lua
--
-- A fiscal-policy lever: set a national tax rate that converts a
-- share of gross gold income into extra treasury gold each turn,
-- at the cost of accelerating unhappiness. The revenue/austerity
-- counterpart to the Banking mod's borrowing.
--
-- Unlocked by Currency. Rate is set by the human in the Taxation
-- panel; the AI picks a rate from its fiscal situation.
--
-- NOTE: Uses Lua 5.1 syntax — required by Civ5.
-- ============================================================

include("EcoCurrency")   -- gold/silver/copper money layer: EcoChangeCopper, ECO_COPPER_PER_GOLD

-- ============================================================
-- Constants
-- ============================================================

local TAX_STEP        = 0.05    -- rate adjusts in 5% steps
local TAX_MAX         = 0.30    -- 30% ceiling
local UNHAPPY_PER_STEP = 1      -- unhappiness per 5% of tax (so 30% -> 6)
local TAX_TECH        = "TECH_CURRENCY"

-- ============================================================
-- Persistent storage
-- ============================================================

MapModData.EcoOverhaul_TaxRate        = MapModData.EcoOverhaul_TaxRate        or {}
MapModData.EcoOverhaul_TaxRevenue     = MapModData.EcoOverhaul_TaxRevenue     or {}
MapModData.EcoOverhaul_TaxUnhappiness = MapModData.EcoOverhaul_TaxUnhappiness or {}

-- ============================================================
-- Helpers
-- ============================================================

local function HasCurrency(pPlayer)
    local pTeam = Teams[pPlayer:GetTeam()]
    if pTeam == nil then return false end
    local iTech = GameInfoTypes[TAX_TECH]
    return iTech ~= nil and pTeam:GetTeamTechs():HasTech(iTech)
end

local function GetGrossGoldIncome(pPlayer)
    local fromCities = pPlayer:GetGoldFromCitiesTimes100() / 100
    local fromTrade  = pPlayer:GetCityConnectionGoldTimes100() / 100
    local fromDiplo  = math.max(0, pPlayer:GetGoldPerTurnFromDiplomacy())
    return math.max(1, math.floor(fromCities + fromTrade + fromDiplo))
end

local function GetTaxRate(iPlayer)
    return MapModData.EcoOverhaul_TaxRate[iPlayer] or 0
end

-- Unhappiness owed for a given tax rate (whole number).
local function TaxUnhappinessFor(rate)
    return math.floor((rate / TAX_STEP) * UNHAPPY_PER_STEP + 0.0001)
end

-- Apply the tax unhappiness delta, tracking the previously applied value so
-- the engine's free-happiness counter stays consistent across saves.
-- (Mirrors the Banking mod's debt-burden approach.)
local function ApplyTaxUnhappiness(iPlayer, pPlayer, rate)
    local newPenalty  = TaxUnhappinessFor(rate)
    local prevPenalty = MapModData.EcoOverhaul_TaxUnhappiness[iPlayer] or 0
    if newPenalty ~= prevPenalty then
        pPlayer:ChangeHappiness(prevPenalty - newPenalty)
        MapModData.EcoOverhaul_TaxUnhappiness[iPlayer] = newPenalty
    end
end

-- ============================================================
-- AI tax policy — a simple heuristic
-- ============================================================

local function AIChooseTaxRate(pPlayer)
    local gpt = pPlayer:CalculateGoldRate()
    if pPlayer:GetGold() < 0 or gpt < 0 then
        return 0.20            -- bleeding gold: tax hard
    elseif gpt < 5 then
        return 0.10            -- tight: modest tax
    else
        return 0.05            -- comfortable: light tax
    end
end

-- ============================================================
-- Per-player turn processing
-- ============================================================

function OnPlayerDoTurn_Tax(iPlayer)
    local pPlayer = Players[iPlayer]
    if pPlayer == nil then return end
    if pPlayer:IsMinorCiv() or pPlayer:IsBarbarian() then return end

    if not HasCurrency(pPlayer) then
        -- Clear any lingering effect if the tech somehow goes away
        MapModData.EcoOverhaul_TaxRevenue[iPlayer] = 0
        local prev = MapModData.EcoOverhaul_TaxUnhappiness[iPlayer] or 0
        if prev > 0 then
            pPlayer:ChangeHappiness(prev)
            MapModData.EcoOverhaul_TaxUnhappiness[iPlayer] = 0
        end
        return
    end

    -- The AI manages its own rate; the human sets theirs in the panel.
    local rate
    if pPlayer:IsHuman() then
        rate = GetTaxRate(iPlayer)
    else
        rate = AIChooseTaxRate(pPlayer)
        MapModData.EcoOverhaul_TaxRate[iPlayer] = rate
    end

    -- Business Cycle complement (optional, nil-safe): a boom widens the tax
    -- base, a recession shrinks it. 1.0 = no effect.
    local climate = MapModData.EcoOverhaul_Climate or 1.0
    -- Revenue in COPPER so the fractional tax take (rate x base x climate) keeps its sub-gold part.
    local revenue = math.floor(GetGrossGoldIncome(pPlayer) * ECO_COPPER_PER_GOLD * rate * climate)   -- copper
    if revenue > 0 then
        EcoChangeCopper(pPlayer, revenue)
    end
    MapModData.EcoOverhaul_TaxRevenue[iPlayer] = revenue   -- copper

    ApplyTaxUnhappiness(iPlayer, pPlayer, rate)
end

GameEvents.PlayerDoTurn.Add(OnPlayerDoTurn_Tax)

print("Economy Overhaul: Taxation.lua loaded.")
