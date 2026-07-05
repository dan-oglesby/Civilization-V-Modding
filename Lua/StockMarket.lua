-- ============================================================
-- Economy Overhaul: StockMarket.lua
--
-- Six industry-sector stocks, each with 10,000 shares (split from 100).
-- Prices float based on real in-game economic metrics, denominated in
-- COPPER (1 gold = 100 copper) so a single share is a sub-gold price.
-- Dividends distributed each turn to shareholders (in copper, via the
-- shared gold/silver/copper money layer).
-- AI civs buy undervalued and sell overvalued industries.
-- ============================================================

include("EcoCurrency")   -- gold/silver/copper money layer: EcoChangeCopper, EcoFormatMoney, EcoGetTreasuryCopper

-- ============================================================
-- Industry definitions
-- Keys must match exactly in FinancialMarketsPanel.lua
-- ============================================================

-- Display names are flavor "company" names (must keep the same keys); the panel
-- tooltip explains which sector each tracks. Names are cosmetic — only key joins.
local STOCK_INDUSTRIES = {
    { key = "commerce",   name = "Meridian Holdings", desc = "Commerce & finance sector"   },
    { key = "research",   name = "Apex Dynamics",     desc = "High-tech & research sector" },
    { key = "culture",    name = "Stellar Studios",   desc = "Entertainment & media sector" },
    { key = "population", name = "Heartland Farms",   desc = "Agriculture sector"          },
    { key = "resources",  name = "Titan Minerals",    desc = "Strategic-resources sector"  },
    { key = "luxury",     name = "Maison Luxe",       desc = "Luxury-trade sector"         },
}

-- ============================================================
-- Constants
-- ============================================================

local TOTAL_SHARES      = 10000  -- shares per industry (split 100 -> 10,000; same total company value)
local MAX_OWN_SHARES    = 10000  -- no ownership cap (40% cap removed); a civ may own up to 100% of an industry, float permitting
local BASE_PRICE        = 100    -- COPPER per share at fair value (health = 1.0). 100 copper = 1 gold, so a
                                 -- sector is worth 10,000 sh x 100c = 10,000 gold, unchanged by the split.
local DIVIDEND_RATE     = 0.002  -- 0.2% of (shares × price); yields COPPER, since price is copper
local PRICE_SMOOTHING   = 0.20   -- fraction of gap closed per turn toward fair value
local MIN_SHARE_PRICE   = 10     -- floor price (copper)

-- Health normalisation denominators (expected mid-game per banking civ)
local NORM_GOLD    = 80
local NORM_SCIENCE = 50
local NORM_CULTURE = 30
local NORM_POP     = 45          -- total city pop per civ
local NORM_STRAT   = 12          -- avg strategic commodity price
local NORM_LUX     = 20          -- avg luxury commodity price

-- AI behaviour
local AI_BUY_THRESHOLD   = 0.90  -- buy when price / fair_value <= this
local AI_SELL_THRESHOLD  = 1.15  -- sell when price / fair_value >= this
local AI_MAX_TOTAL_OWN   = 2000  -- AI won't hold more than 2,000 shares total across all industries (x100 of old 20)
local AI_SPEND_FRACTION  = 0.08  -- AI won't spend more than 8% of treasury on one purchase
local AI_MIN_GOLD        = 150   -- AI won't invest unless treasury exceeds this (gold)
local AI_LOT             = 500   -- AI trades 500 shares per action (old 5, scaled x100)

local STOCK_EXCHANGE_CUT = 0.02            -- the Global Stock Market world-wonder owner skims this cut of stock-market activity
local STOCK_WONDER       = "BUILDING_ECO_GLOBAL_STOCK_MARKET"  -- world wonder; once built anywhere, the stock market opens for all
local INDEX_MAX_PER_TURN = 100  -- cap on index units the owner's fee pool auto-buys per turn (1 unit = 1 share of each sector)

-- ============================================================
-- Persistent storage
-- ============================================================

MapModData.EcoOverhaul_StockPrices    = MapModData.EcoOverhaul_StockPrices    or {}
MapModData.EcoOverhaul_StockPrevPrices= MapModData.EcoOverhaul_StockPrevPrices or {}
MapModData.EcoOverhaul_StockFairVals  = MapModData.EcoOverhaul_StockFairVals  or {}
MapModData.EcoOverhaul_StockFloat     = MapModData.EcoOverhaul_StockFloat     or {}
MapModData.EcoOverhaul_StockOwned     = MapModData.EcoOverhaul_StockOwned     or {}
MapModData.EcoOverhaul_StockDivEarned = MapModData.EcoOverhaul_StockDivEarned or {}
MapModData.EcoOverhaul_StockTurn      = MapModData.EcoOverhaul_StockTurn      or -1
-- Reinvestment: per-player toggle and per-player/industry dividend accumulation pool
MapModData.EcoOverhaul_ReinvestOn     = MapModData.EcoOverhaul_ReinvestOn     or {}
MapModData.EcoOverhaul_DividendPool   = MapModData.EcoOverhaul_DividendPool   or {}
-- World-wonder (Global Stock Market) ownership + the stock-market activity it skims a cut from
MapModData.EcoOverhaul_StockVolume        = MapModData.EcoOverhaul_StockVolume        or 0   -- total stock activity this turn (copper)
MapModData.EcoOverhaul_StockExchangeOwner = MapModData.EcoOverhaul_StockExchangeOwner or -1  -- player owning the Global Stock Market (-1 = none)
MapModData.EcoOverhaul_StockExchangeCut   = MapModData.EcoOverhaul_StockExchangeCut   or 0   -- fees added to the index pool last turn (copper, display)
MapModData.EcoOverhaul_IndexPool          = MapModData.EcoOverhaul_IndexPool          or {}  -- [player] = accrued fees/interest auto-invested into the index (copper)
MapModData.EcoOverhaul_IndexAutoInvest    = MapModData.EcoOverhaul_IndexAutoInvest    or {}  -- [player] = bool; nil/true = auto-invest wonder income into the index, false = take as gold

-- Initialise default values for any industries not yet in MapModData
local function InitStockDefaults()
    for _, ind in ipairs(STOCK_INDUSTRIES) do
        if MapModData.EcoOverhaul_StockPrices[ind.key] == nil then
            MapModData.EcoOverhaul_StockPrices[ind.key]     = BASE_PRICE
            MapModData.EcoOverhaul_StockPrevPrices[ind.key] = BASE_PRICE
            MapModData.EcoOverhaul_StockFairVals[ind.key]   = BASE_PRICE
            MapModData.EcoOverhaul_StockFloat[ind.key]      = TOTAL_SHARES
        end
    end
end
InitStockDefaults()

-- ============================================================
-- Helpers
-- ============================================================

local function HasBanking(pPlayer)
    local pTeam = Teams[pPlayer:GetTeam()]
    if pTeam == nil then return false end
    local iTech = GameInfoTypes["TECH_BANKING"]
    return iTech ~= nil and pTeam:GetTeamTechs():HasTech(iTech)
end

local function GetOwnedShares(iPlayer, key)
    local tbl = MapModData.EcoOverhaul_StockOwned[iPlayer]
    return tbl and (tbl[key] or 0) or 0
end

local function SetOwnedShares(iPlayer, key, qty)
    if MapModData.EcoOverhaul_StockOwned[iPlayer] == nil then
        MapModData.EcoOverhaul_StockOwned[iPlayer] = {}
    end
    local tbl = MapModData.EcoOverhaul_StockOwned[iPlayer]
    tbl[key] = math.max(0, qty)
    MapModData.EcoOverhaul_StockOwned[iPlayer] = tbl  -- defensive write-back
end

local function GetFloat(key)
    return MapModData.EcoOverhaul_StockFloat[key] or TOTAL_SHARES
end

local function SetFloat(key, qty)
    MapModData.EcoOverhaul_StockFloat[key] = math.max(0, math.min(TOTAL_SHARES, qty))
end

-- ============================================================
-- Index fund: the Global Stock Market owner's trading-fee pool is
-- automatically invested into a diversified position — buying 1 share
-- of every sector (an "index unit") whenever the pool can afford a full
-- set, up to INDEX_MAX_PER_TURN units per turn.
-- ============================================================

local function AutoInvestIndexFund(iOwner)
    if iOwner == nil or iOwner < 0 or Players[iOwner] == nil then return end
    local pools = MapModData.EcoOverhaul_IndexPool
    local pool  = (pools and pools[iOwner]) or 0

    local unitCost = 0
    for _, ind in ipairs(STOCK_INDUSTRIES) do
        unitCost = unitCost + ((MapModData.EcoOverhaul_StockPrices[ind.key]) or BASE_PRICE)
    end
    if unitCost <= 0 then return end

    local bought = 0
    while pool >= unitCost and bought < INDEX_MAX_PER_TURN do
        -- need at least 1 share of float in every sector to buy a full index unit
        local canBuy = true
        for _, ind in ipairs(STOCK_INDUSTRIES) do
            if GetFloat(ind.key) < 1 then canBuy = false break end
        end
        if not canBuy then break end
        for _, ind in ipairs(STOCK_INDUSTRIES) do
            SetOwnedShares(iOwner, ind.key, GetOwnedShares(iOwner, ind.key) + 1)
            SetFloat(ind.key, GetFloat(ind.key) - 1)
        end
        pool   = pool - unitCost
        bought = bought + 1
    end

    if MapModData.EcoOverhaul_IndexPool == nil then MapModData.EcoOverhaul_IndexPool = {} end
    MapModData.EcoOverhaul_IndexPool[iOwner] = pool
end

-- Invest every player's pool once per turn. The Global Stock Market owner's fees and any
-- Bond Exchange owner's routed interest both accumulate per-player in EcoOverhaul_IndexPool.
local function AutoInvestAllPools()
    local pools = MapModData.EcoOverhaul_IndexPool
    if pools == nil then return end
    for iP = 0, GameDefines.MAX_MAJOR_CIVS - 1 do
        if (pools[iP] or 0) > 0 then AutoInvestIndexFund(iP) end
    end
end

-- ============================================================
-- Health index computation
-- Returns a table keyed by industry key, values clamped [0.25, 4.0].
-- A value of 1.0 corresponds to BASE_PRICE fair value.
-- ============================================================

local function ComputeHealthIndices()
    local totalGold, totalSci, totalCult, totalPop = 0, 0, 0, 0
    local civCount = 0

    for iP = 0, GameDefines.MAX_MAJOR_CIVS - 1 do
        local p = Players[iP]
        if p ~= nil and p:IsAlive()
        and not p:IsMinorCiv() and not p:IsBarbarian()
        then
            local gross = math.max(0,
                p:GetGoldFromCitiesTimes100()     / 100
              + p:GetCityConnectionGoldTimes100() / 100
              + math.max(0, p:GetGoldPerTurnFromDiplomacy()))
            totalGold = totalGold + gross
            totalSci  = totalSci  + math.max(0, p:GetScience())
            totalCult = totalCult + math.max(0, p:GetTotalJONSCulturePerTurn())
            for pCity in p:Cities() do
                totalPop = totalPop + pCity:GetPopulation()
            end
            civCount = civCount + 1
        end
    end

    civCount = math.max(1, civCount)

    local avgGold = totalGold / civCount
    local avgSci  = totalSci  / civCount
    local avgCult = totalCult / civCount
    local avgPop  = totalPop  / civCount

    -- Resource averages: read CommodityMarket prices from MapModData if computed,
    -- else fall back to normalisation values (safe on first turn).
    local avgStrat, avgLux = NORM_STRAT, NORM_LUX
    local prices = MapModData.EcoOverhaul_CmdPrices
    if prices ~= nil then
        local sTotal, sCount, lTotal, lCount = 0, 0, 0, 0
        for resource in GameInfo.Resources() do
            local uType = Game.GetResourceUsageType(resource.ID)
            local p = prices[resource.ID]
            if p ~= nil then
                if uType == ResourceUsageTypes.RESOURCEUSAGE_STRATEGIC then
                    sTotal = sTotal + p; sCount = sCount + 1
                elseif uType == ResourceUsageTypes.RESOURCEUSAGE_LUXURY then
                    lTotal = lTotal + p; lCount = lCount + 1
                end
            end
        end
        if sCount > 0 then avgStrat = sTotal / sCount end
        if lCount > 0 then avgLux   = lTotal / lCount end
    end

    local clamp = function(v)
        return math.min(4.0, math.max(0.25, v))
    end

    return {
        commerce   = clamp(avgGold / NORM_GOLD),
        research   = clamp(avgSci  / NORM_SCIENCE),
        culture    = clamp(avgCult / NORM_CULTURE),
        population = clamp(avgPop  / NORM_POP),
        resources  = clamp(avgStrat / NORM_STRAT),
        luxury     = clamp(avgLux   / NORM_LUX),
    }
end

-- ============================================================
-- Price update — runs once per game turn
-- ============================================================

local function UpdatePrices()
    local iTurn = Game.GetGameTurn()
    if iTurn == MapModData.EcoOverhaul_StockTurn then return end
    MapModData.EcoOverhaul_StockTurn = iTurn

    -- Exchange cut: pay the Global Stock Market owner a slice of LAST turn's stock activity,
    -- reset the accumulator, and cache the owner. The market is open to ALL once the Global Stock
    -- Market is built; notify everyone the first time it opens.
    local prevStockOwner = MapModData.EcoOverhaul_StockExchangeOwner or -1
    local stockOwner = EcoWonderOwner(STOCK_WONDER)
    local newStockOwner = (stockOwner ~= nil) and stockOwner or -1
    if prevStockOwner < 0 and newStockOwner >= 0 then
        local civ = (Players[stockOwner] and Players[stockOwner]:GetCivilizationShortDescription()) or "A civilization"
        EcoNotifyAll("Stock Market Opened", civ .. " has built the Global Stock Market — the stock market is now live for all civilizations! Open Financial Markets from the Additional Information menu.")
    end
    MapModData.EcoOverhaul_StockExchangeOwner = newStockOwner
    local scut = (stockOwner ~= nil) and math.floor((MapModData.EcoOverhaul_StockVolume or 0) * STOCK_EXCHANGE_CUT) or 0
    -- The owner's fees fund their index pool when auto-invest is ON (default), else pay out as gold.
    if scut > 0 and stockOwner ~= nil then
        if MapModData.EcoOverhaul_IndexAutoInvest[stockOwner] ~= false then
            if MapModData.EcoOverhaul_IndexPool == nil then MapModData.EcoOverhaul_IndexPool = {} end
            MapModData.EcoOverhaul_IndexPool[stockOwner] = (MapModData.EcoOverhaul_IndexPool[stockOwner] or 0) + scut
        elseif Players[stockOwner] ~= nil then
            EcoChangeCopper(Players[stockOwner], scut)
        end
    end
    MapModData.EcoOverhaul_StockExchangeCut = scut
    MapModData.EcoOverhaul_StockVolume = 0
    AutoInvestAllPools()

    local health = ComputeHealthIndices()
    -- Business Cycle complement (optional, nil-safe): a boom lifts fair value,
    -- a recession lowers it. 1.0 = no effect when that mod isn't running.
    local climate = MapModData.EcoOverhaul_Climate or 1.0

    for _, ind in ipairs(STOCK_INDUSTRIES) do
        -- Stable fundamental (the "fair value" shown in the panel) from sector health + climate.
        local fairVal  = math.max(MIN_SHARE_PRICE, math.floor(BASE_PRICE * health[ind.key] * climate))
        -- Random per-turn shock (+/-10%) gives the PRICE volatility around that fair value, so
        -- shares fluctuate instead of sitting still. Climate supplies the economic correlation.
        local rnd      = (Game.Rand(21, "EcoStockShock") - 10) / 100
        local target   = fairVal * (1 + rnd)
        local oldPrice = MapModData.EcoOverhaul_StockPrices[ind.key] or BASE_PRICE

        MapModData.EcoOverhaul_StockPrevPrices[ind.key] = oldPrice

        -- Smooth convergence: move PRICE_SMOOTHING of the gap to the shocked target each turn.
        local newPrice = math.max(MIN_SHARE_PRICE,
            math.floor(oldPrice * (1 - PRICE_SMOOTHING) + target * PRICE_SMOOTHING))

        MapModData.EcoOverhaul_StockPrices[ind.key]   = newPrice
        MapModData.EcoOverhaul_StockFairVals[ind.key] = fairVal
    end
end

-- ============================================================
-- Dividend distribution — called each turn for each banking civ.
--
-- When reinvestment is OFF (default):
--   All dividends are added directly to the treasury.
--
-- When reinvestment is ON:
--   Dividends accumulate per-industry in a pool.
--   Whenever the pool reaches the current share price, a whole
--   share is purchased automatically (up to ownership/float caps).
--   If reinvestment is impossible (no float, at ownership cap),
--   the dividend falls back to treasury instead of pooling.
-- ============================================================

local function DistributeDividends(iPlayer)
    local pPlayer = Players[iPlayer]
    if pPlayer == nil then return end

    local reinvestOn = (MapModData.EcoOverhaul_ReinvestOn[iPlayer] == true)

    -- Ensure pool sub-table exists for this player
    if MapModData.EcoOverhaul_DividendPool[iPlayer] == nil then
        MapModData.EcoOverhaul_DividendPool[iPlayer] = {}
    end
    local pool = MapModData.EcoOverhaul_DividendPool[iPlayer]

    local totalCash = 0  -- gold actually paid to treasury this turn

    for _, ind in ipairs(STOCK_INDUSTRIES) do
        local shares = GetOwnedShares(iPlayer, ind.key)
        if shares > 0 then
            local price = MapModData.EcoOverhaul_StockPrices[ind.key] or BASE_PRICE   -- copper/share
            local div   = math.floor(shares * price * DIVIDEND_RATE)                  -- copper
            if div > 0 then
                MapModData.EcoOverhaul_StockVolume = (MapModData.EcoOverhaul_StockVolume or 0) + div   -- market activity for the exchange cut

                if reinvestOn then
                    local float = GetFloat(ind.key)
                    local owned = GetOwnedShares(iPlayer, ind.key)
                    local canReinvest = (float > 0) and (owned < MAX_OWN_SHARES)

                    if canReinvest then
                        -- Accumulate in pool
                        pool[ind.key] = (pool[ind.key] or 0) + div

                        -- Buy as many whole shares as the pool allows
                        local accumulated = pool[ind.key]
                        if accumulated >= price then
                            local buyQty = math.min(
                                math.floor(accumulated / price),
                                float,
                                MAX_OWN_SHARES - owned
                            )
                            if buyQty > 0 then
                                SetOwnedShares(iPlayer, ind.key, owned + buyQty)
                                SetFloat(ind.key, float - buyQty)
                                pool[ind.key] = accumulated - buyQty * price
                            end
                        end
                        -- Remainder stays pooled; no gold goes to treasury
                    else
                        -- Reinvestment impossible for this industry right now
                        -- (float exhausted or at ownership cap) — pay to treasury
                        EcoChangeCopper(pPlayer, div)
                        totalCash = totalCash + div
                    end
                else
                    -- Reinvestment off — standard treasury payment
                    EcoChangeCopper(pPlayer, div)
                    totalCash = totalCash + div
                end
            end
        end
    end

    -- Write pool back (defensive — ensures nested table is persisted)
    MapModData.EcoOverhaul_DividendPool[iPlayer] = pool

    -- Store cash dividends paid this turn for UI display (COPPER)
    MapModData.EcoOverhaul_StockDivEarned[iPlayer] = totalCash
end

-- ============================================================
-- AI buy/sell decisions
-- AI buys industries trading below 90% of fair value and
-- sells when above 115% of fair value.
-- ============================================================

local function AIStockDecisions(iPlayer)
    local pPlayer = Players[iPlayer]
    if pPlayer:IsHuman() then return end
    if (MapModData.EcoOverhaul_StockExchangeOwner or -1) < 0 then return end   -- no stock market until the Global Stock Market exists

    -- Work in copper throughout (prices are copper); GetTreasuryCopper gives hundredths.
    local iGoldCopper = EcoGetTreasuryCopper(pPlayer)
    if iGoldCopper < AI_MIN_GOLD * ECO_COPPER_PER_GOLD then return end

    -- Count total shares this AI holds
    local totalOwned = 0
    for _, ind in ipairs(STOCK_INDUSTRIES) do
        totalOwned = totalOwned + GetOwnedShares(iPlayer, ind.key)
    end

    for iInd, ind in ipairs(STOCK_INDUSTRIES) do
        local price    = MapModData.EcoOverhaul_StockPrices[ind.key]   or BASE_PRICE   -- copper
        local fairVal  = MapModData.EcoOverhaul_StockFairVals[ind.key] or BASE_PRICE
        local owned    = GetOwnedShares(iPlayer, ind.key)
        local float    = GetFloat(ind.key)
        local ratio    = price / math.max(1, fairVal)

        -- Buy when undervalued, has room in portfolio, and market has supply
        if ratio <= AI_BUY_THRESHOLD
        and totalOwned < AI_MAX_TOTAL_OWN
        and owned < MAX_OWN_SHARES
        and float >= AI_LOT
        then
            local canAffordQty = math.floor((iGoldCopper * AI_SPEND_FRACTION) / price)
            local buyQty = math.min(AI_LOT, canAffordQty, float, MAX_OWN_SHARES - owned,
                                    AI_MAX_TOTAL_OWN - totalOwned)
            if buyQty > 0 then
                local cost = buyQty * price   -- copper
                if iGoldCopper >= cost then
                    EcoChangeCopper(pPlayer, -cost)
                    SetOwnedShares(iPlayer, ind.key, owned + buyQty)
                    SetFloat(ind.key, float - buyQty)
                    iGoldCopper = iGoldCopper - cost
                    totalOwned  = totalOwned + buyQty
                end
            end
        end

        -- Sell when overvalued — pseudo-random gate prevents all AIs selling same turn.
        -- Uses loop index iInd (1–6, guaranteed unique) instead of key length to avoid
        -- collisions between same-length keys like "commerce" and "research".
        local gpt = pPlayer:CalculateGoldRate()
        local pseudoRand = (owned + math.floor(math.abs(gpt)) + iInd) % 3
        if ratio >= AI_SELL_THRESHOLD and owned >= AI_LOT and pseudoRand == 0 then
            local sellQty = AI_LOT
            local revenue = sellQty * price   -- copper
            EcoChangeCopper(pPlayer, revenue)
            SetOwnedShares(iPlayer, ind.key, owned - sellQty)
            SetFloat(ind.key, float + sellQty)
            iGoldCopper = iGoldCopper + revenue
            totalOwned  = totalOwned - sellQty
        end
    end
end

-- ============================================================
-- Per-player turn hook
-- ============================================================

function OnPlayerDoTurn_Stock(iPlayer)
    local pPlayer = Players[iPlayer]
    if pPlayer == nil then return end
    if pPlayer:IsMinorCiv() or pPlayer:IsBarbarian() then return end

    -- Update prices once per turn (first call per turn does the work)
    UpdatePrices()

    if (MapModData.EcoOverhaul_StockExchangeOwner or -1) < 0 then return end   -- stock market opens only once the Global Stock Market world wonder exists

    -- Distribute dividends for this player's holdings
    DistributeDividends(iPlayer)

    -- AI trading decisions
    if not pPlayer:IsHuman() then
        AIStockDecisions(iPlayer)
    end
end

GameEvents.PlayerDoTurn.Add(OnPlayerDoTurn_Stock)

print("Economy Overhaul: StockMarket.lua loaded.")
