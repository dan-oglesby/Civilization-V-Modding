-- ============================================================
-- Economy Overhaul: BusinessCycle.lua
--
-- A global "economic climate" that drifts through boom and
-- recession over the game, with occasional shocks. Published as
-- MapModData.EcoOverhaul_Climate (a multiplier, ~0.6–1.4) that the
-- other Economy Overhaul mods read to modulate their own formulas.
--
-- Standalone effect: in a boom every civ earns a small per-turn
-- gold bonus; in a recession, a small penalty (scaled to income).
--
-- NOTE: Uses Lua 5.1 syntax — required by Civ5.
-- ============================================================

include("EcoCurrency")   -- gold/silver/copper money layer: EcoChangeCopper, EcoGetTreasuryCopper, ECO_COPPER_PER_GOLD

-- ============================================================
-- Constants
-- ============================================================

local CLIMATE_MIN       = 0.60   -- worst-recession floor
local CLIMATE_MAX       = 1.40   -- strongest-boom ceiling
local CLIMATE_DRIFT     = 0.25   -- fraction of the gap to the phase target closed each turn; gradual drift
                                 -- means short phases stay mild and long phases fully develop (severe)
local PHASE_MIN_TURNS   = 1      -- each phase lasts a random PHASE_MIN..PHASE_MAX turns
local PHASE_MAX_TURNS   = 10
local GOLD_EFFECT_COEFF = 0.15   -- standalone gold delta = (climate-1) * grossIncome * coeff

-- Financial crises: discrete shocks that can strike only during a deep downturn.
local CRISIS_CLIMATE    = 0.78   -- climate must be at/below this (a real recession) for a crisis
local CRISIS_CHANCE     = 22     -- % chance per turn of a crisis while the climate is that deep
local CRISIS_COOLDOWN   = 12     -- minimum turns between crises
local CRASH_FACTOR_MIN  = 45     -- stock crash multiplies every share price by 0.45..0.65
local PANIC_HIT_MIN     = 6      -- banking panic writes down 6..14% of each civ's treasury

-- ============================================================
-- Persistent storage
-- ============================================================

MapModData.EcoOverhaul_Climate       = MapModData.EcoOverhaul_Climate       or 1.0
MapModData.EcoOverhaul_ClimateTarget    = MapModData.EcoOverhaul_ClimateTarget    or 1.0   -- current phase's target
MapModData.EcoOverhaul_ClimatePhaseLeft = MapModData.EcoOverhaul_ClimatePhaseLeft or 0     -- turns left in phase
MapModData.EcoOverhaul_ClimateShock  = MapModData.EcoOverhaul_ClimateShock  or 0.0
MapModData.EcoOverhaul_ClimateTurn   = MapModData.EcoOverhaul_ClimateTurn   or -1
MapModData.EcoOverhaul_ClimateLabel  = MapModData.EcoOverhaul_ClimateLabel  or "Stable"
MapModData.EcoOverhaul_ClimatePrevLabel = MapModData.EcoOverhaul_ClimatePrevLabel or "Stable"
MapModData.EcoOverhaul_CrisisCooldown   = MapModData.EcoOverhaul_CrisisCooldown   or 0

-- ============================================================
-- Helpers
-- ============================================================

local function GetGrossGoldIncome(pPlayer)
    local fromCities = pPlayer:GetGoldFromCitiesTimes100() / 100
    local fromTrade  = pPlayer:GetCityConnectionGoldTimes100() / 100
    local fromDiplo  = math.max(0, pPlayer:GetGoldPerTurnFromDiplomacy())
    return math.max(1, math.floor(fromCities + fromTrade + fromDiplo))
end

local function ClimateLabel(climate)
    if climate >= 1.15 then return "Boom"
    elseif climate >= 1.05 then return "Expansion"
    elseif climate >  0.95 then return "Stable"
    elseif climate >  0.85 then return "Slowdown"
    else return "Recession" end
end

-- ============================================================
-- Financial crises — discrete shocks during a deep downturn. Self-contained:
-- a market crash slashes share prices directly (they recover via the stock
-- market's normal smoothing toward fair value); a banking panic writes down
-- every civ's treasury. Both notify all players.
-- ============================================================

local function TriggerMarketCrash()
    -- Gate on the market actually being OPEN (the Global Stock Market world wonder exists).
    -- The price table itself is initialised to defaults when StockMarket.lua loads, so it is
    -- never nil and cannot serve as the gate — without this check a "Stock Market Crash"
    -- could fire in the Ancient era, before any exchange had been founded.
    if (MapModData.EcoOverhaul_StockExchangeOwner or -1) < 0 then return false end
    local prices = MapModData.EcoOverhaul_StockPrices
    if prices == nil then return false end   -- stock market not open yet
    local factor = (CRASH_FACTOR_MIN + Game.Rand(21, "EcoCrashFactor")) / 100   -- 0.45..0.65
    local prev = MapModData.EcoOverhaul_StockPrevPrices or {}
    for k, v in pairs(prices) do
        prev[k]   = v
        prices[k] = math.max(10, math.floor(v * factor))
    end
    MapModData.EcoOverhaul_StockPrevPrices = prev
    MapModData.EcoOverhaul_StockPrices     = prices
    EcoNotifyAll("Stock Market Crash",
        "[COLOR_WARNING_TEXT]Panic has gripped the markets and share prices have collapsed.[ENDCOLOR] The Financial Markets are in free-fall \226\128\148 but bold investors may find bargains as values claw back over the coming turns.")
    return true
end

local function TriggerBankingPanic()
    local pct = (PANIC_HIT_MIN + Game.Rand(9, "EcoPanicPct")) / 100   -- 0.06..0.14
    for iP = 0, GameDefines.MAX_MAJOR_CIVS - 1 do
        local p = Players[iP]
        if p ~= nil and p:IsAlive() and not p:IsMinorCiv() and not p:IsBarbarian() then
            local hit = math.floor(EcoGetTreasuryCopper(p) * pct)
            if hit > 0 then EcoChangeCopper(p, -hit) end
        end
    end
    EcoNotifyAll("Banking Panic",
        "[COLOR_WARNING_TEXT]A wave of bank failures has swept the world.[ENDCOLOR] Treasuries everywhere have been written down as credit freezes and depositors flee.")
    return true
end

-- Maybe fire a crisis this turn, gated on a deep climate, a cooldown, and a dice roll.
local function MaybeTriggerCrisis(climate)
    local cd = (MapModData.EcoOverhaul_CrisisCooldown or 0) - 1
    if cd < 0 then cd = 0 end
    if climate <= CRISIS_CLIMATE and cd == 0 and Game.Rand(100, "EcoCrisisRoll") < CRISIS_CHANCE then
        local fired = false
        if Game.Rand(2, "EcoCrisisKind") == 0 then fired = TriggerMarketCrash() end
        if not fired then fired = TriggerBankingPanic() end   -- crash needs an open market; else panic
        if fired then cd = CRISIS_COOLDOWN end
    end
    MapModData.EcoOverhaul_CrisisCooldown = cd
end

-- ============================================================
-- Climate computation — once per game turn (turn-guarded)
-- ============================================================

local function ComputeClimate()
    local iTurn = Game.GetGameTurn()
    if iTurn == MapModData.EcoOverhaul_ClimateTurn then return end
    MapModData.EcoOverhaul_ClimateTurn = iTurn

    -- Regime model: the economy holds a "phase" (a target climate) for a random number
    -- of turns, then a fresh phase is drawn. The actual climate DRIFTS toward the phase
    -- target each turn, so a short phase only nudges it (mild) while a long phase fully
    -- develops (severe) — the duration itself sets how good/bad the swing becomes.
    local left = (MapModData.EcoOverhaul_ClimatePhaseLeft or 0) - 1
    if left <= 0 then
        -- Draw a new phase target. Stable/mild phases are common; strong booms/busts rare.
        local r = Game.Rand(100, "EcoClimatePhase")
        local target
        if r < 50 then     target = 1.0  + (Game.Rand(11, "EcoClimStable") - 5) / 100   -- ~stable   0.95–1.05
        elseif r < 73 then target = 1.05 +  Game.Rand(11, "EcoClimUp")        / 100      -- expansion 1.05–1.15
        elseif r < 92 then target = 0.95 -  Game.Rand(11, "EcoClimDown")      / 100      -- downturn  0.85–0.95
        elseif r < 97 then target = 1.15 +  Game.Rand(26, "EcoClimBoom")      / 100      -- boom      1.15–1.40
        else               target = 0.85 -  Game.Rand(26, "EcoClimBust")      / 100      -- recession 0.60–0.85
        end
        MapModData.EcoOverhaul_ClimateTarget = math.max(CLIMATE_MIN, math.min(CLIMATE_MAX, target))
        left = PHASE_MIN_TURNS + Game.Rand(PHASE_MAX_TURNS - PHASE_MIN_TURNS + 1, "EcoClimateDur")  -- 1..10 turns
    end
    MapModData.EcoOverhaul_ClimatePhaseLeft = left

    -- Gradual drift toward the phase target (this is what "slows down" the cycle).
    local target  = MapModData.EcoOverhaul_ClimateTarget or 1.0
    local cur     = MapModData.EcoOverhaul_Climate or 1.0
    local climate = math.max(CLIMATE_MIN, math.min(CLIMATE_MAX, cur + (target - cur) * CLIMATE_DRIFT))
    MapModData.EcoOverhaul_Climate = climate

    local label = ClimateLabel(climate)
    MapModData.EcoOverhaul_ClimatePrevLabel = MapModData.EcoOverhaul_ClimateLabel
    MapModData.EcoOverhaul_ClimateLabel = label

    MaybeTriggerCrisis(climate)
end

-- ============================================================
-- Per-player turn processing
-- ============================================================

function OnPlayerDoTurn_Climate(iPlayer)
    local pPlayer = Players[iPlayer]
    if pPlayer == nil then return end
    if pPlayer:IsMinorCiv() or pPlayer:IsBarbarian() then return end

    ComputeClimate()  -- first caller each turn does the work

    -- Standalone effect: a small gold bonus/penalty proportional to how far
    -- the climate is from neutral, scaled to the civ's gross income.
    local climate = MapModData.EcoOverhaul_Climate or 1.0
    -- In COPPER: a small bonus/penalty proportional to the climate's distance from neutral.
    local delta = math.floor((climate - 1.0) * GetGrossGoldIncome(pPlayer) * GOLD_EFFECT_COEFF * ECO_COPPER_PER_GOLD)   -- copper
    if delta < 0 then
        -- Don't let a recession alone push a treasury below zero (which would
        -- trigger Civ5's forced building sell-off and can spiral the AI).
        delta = math.max(delta, -EcoGetTreasuryCopper(pPlayer))
    end
    if delta ~= 0 then
        EcoChangeCopper(pPlayer, delta)
    end
end

-- ============================================================
-- Human notification on phase transitions
-- ============================================================

function OnActivePlayerTurnStart_Climate()
    local iPlayer = Game.GetActivePlayer()
    local pPlayer = Players[iPlayer]
    if pPlayer == nil or not pPlayer:IsHuman() then return end

    local label = MapModData.EcoOverhaul_ClimateLabel or "Stable"
    local prev  = MapModData.EcoOverhaul_ClimatePrevLabel or "Stable"
    if label == prev then return end

    local rising = (label == "Boom" or label == "Expansion")
    local summary = "Economic Climate: " .. label
    local body
    if label == "Boom" then
        body = "[COLOR_POSITIVE_TEXT]A global economic boom has begun.[ENDCOLOR] Incomes swell, demand for goods runs hot, and capital is in high demand. Make the most of it while it lasts."
    elseif label == "Recession" then
        body = "[COLOR_WARNING_TEXT]A global recession has set in.[ENDCOLOR] Incomes contract, demand for goods slumps, and confidence is low. Tighten your belt until conditions improve."
    else
        body = "The global economic climate has shifted to [COLOR" .. (rising and "_POSITIVE" or "_WARNING") .. "_TEXT]" .. label .. "[ENDCOLOR]."
    end
    pPlayer:AddNotification(NotificationTypes.NOTIFICATION_GENERIC, body, summary, -1, -1)
end

-- ============================================================
-- Event registration
-- ============================================================

GameEvents.PlayerDoTurn.Add(OnPlayerDoTurn_Climate)
Events.ActivePlayerTurnStart.Add(OnActivePlayerTurnStart_Climate)

print("Economy Overhaul: BusinessCycle.lua loaded.")
