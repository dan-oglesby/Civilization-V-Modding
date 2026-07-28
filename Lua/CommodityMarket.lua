-- ============================================================
-- Economy Overhaul: CommodityMarket.lua
--
-- Global commodity market for strategic and luxury resources.
-- Available once Economics is researched.
--
-- RECURRING EXPORT MODEL: selling a resource is an ongoing export,
-- not a one-time sale. You set how many units of each resource to
-- sell (in increments of 1). Each turn those units are COMMITTED
-- (tied up — removed from your own use) and you receive their
-- current market value as gold. Stop selling and the units return.
-- An empire ALWAYS keeps 1 of each resource, so it never sells away a
-- luxury's happiness or its ability to build advanced units — only the
-- excess is sold, and the kept 1 frees a unit's worth each turn.
--
-- Prices float per-resource on global supply/demand.
-- Commodity Exchange national wonder (+Economics): +25% sale value.
-- AI civs (and the "Sell All Surplus" toggle) auto-export everything
-- beyond the kept 1, keeping production ability while monetizing excess.
--
-- NOTE: Uses Lua 5.1 syntax (no goto) — required by Civ5.
-- ============================================================

include("EcoCurrency")   -- gold/silver/copper money layer: EcoChangeCopper, ECO_COPPER_PER_GOLD

-- ============================================================
-- Constants
-- ============================================================

local CORP_SHARE_PREFIX  = "^RESOURCE_CORP_"   -- Corporations-mod equity shares: never tradeable here
local BASE_PRICE_ANCIENT = 10                  -- iron, horses, marble …
local BASE_PRICE_MODERN  = 15                  -- coal, oil, aluminum, uranium
local BASE_PRICE_LUXURY  = 20
local EXCHANGE_PREMIUM   = 0.25                -- +25% sale value with Commodity Exchange
local IMPORT_CAP         = 10                 -- #1: max units/turn a player may IMPORT per resource
local AI_IMPORT_BUDGET_FRAC = 0.15            -- AI civs commit at most this share of their treasury to buying commodities
local EXCHANGE_CUT          = 0.02            -- the Commodity Exchange world-wonder owner skims this cut of total trade volume
local COMMODITY_WONDER      = "BUILDING_COMMODITY_EXCHANGE"   -- world wonder that opens the commodity market
local PRICE_SMOOTH       = 0.34               -- fraction of the gap to the target price closed each turn
local SHOCK_PCT          = 12                 -- +/- random price shock (%) per resource per turn
local CLIMATE_BIAS       = 0.5                -- how strongly the economic climate skews shocks (boom up / bust down)

-- ============================================================
-- Persistent storage
-- ============================================================

MapModData.EcoOverhaul_CmdPrices      = MapModData.EcoOverhaul_CmdPrices      or {}
MapModData.EcoOverhaul_CmdPrevPrices  = MapModData.EcoOverhaul_CmdPrevPrices  or {}
MapModData.EcoOverhaul_CmdSupply      = MapModData.EcoOverhaul_CmdSupply      or {}
MapModData.EcoOverhaul_CmdDemand      = MapModData.EcoOverhaul_CmdDemand      or {}
MapModData.EcoOverhaul_CmdPricesTurn  = MapModData.EcoOverhaul_CmdPricesTurn  or -1
MapModData.EcoOverhaul_AutoSell       = MapModData.EcoOverhaul_AutoSell       or {}  -- [player] = sell ALL surplus
MapModData.EcoOverhaul_AutoBuy        = MapModData.EcoOverhaul_AutoBuy        or {}  -- [player] = auto-import up to 1 of each lacked resource
MapModData.EcoOverhaul_CmdMarketAvail = MapModData.EcoOverhaul_CmdMarketAvail or {}  -- [res] = units offered for sale this turn (importable supply)
MapModData.EcoOverhaul_CmdVolume        = MapModData.EcoOverhaul_CmdVolume        or 0   -- total trade value this turn (copper)
MapModData.EcoOverhaul_CmdExchangeOwner = MapModData.EcoOverhaul_CmdExchangeOwner or -1  -- player owning the Commodity Exchange world wonder (-1 = none)
MapModData.EcoOverhaul_CmdExchangeCut   = MapModData.EcoOverhaul_CmdExchangeCut   or 0   -- owner's cut last turn (copper, for display)
MapModData.EcoOverhaul_CmdSelling     = MapModData.EcoOverhaul_CmdSelling     or {}  -- [player][res] = signed: + sell, - import
MapModData.EcoOverhaul_CmdTiedUp      = MapModData.EcoOverhaul_CmdTiedUp      or {}  -- [player][res] = units currently committed
MapModData.EcoOverhaul_CmdSaleIncome  = MapModData.EcoOverhaul_CmdSaleIncome  or {}  -- [player] = last turn's export income

-- ============================================================
-- Helpers
-- ============================================================

local function HasEconomics(pPlayer)
    local pTeam = Teams[pPlayer:GetTeam()]
    if pTeam == nil then return false end
    local iTech = GameInfoTypes["TECH_ECONOMICS"]
    return iTech ~= nil and pTeam:GetTeamTechs():HasTech(iTech)
end

local function HasCommodityExchange(pPlayer)
    local iBldg = GameInfoTypes["BUILDING_COMMODITY_EXCHANGE"]
    if iBldg == nil then return false end
    for pCity in pPlayer:Cities() do
        if pCity:GetNumBuilding(iBldg) > 0 then return true end
    end
    return false
end

local function IsTradeableResource(uType)
    return uType == ResourceUsageTypes.RESOURCEUSAGE_STRATEGIC
        or uType == ResourceUsageTypes.RESOURCEUSAGE_LUXURY
end

local function IsExempt(resource)
    return resource.Type ~= nil and resource.Type:find(CORP_SHARE_PREFIX) ~= nil
end

local function GetBasePrice(iResourceID)
    local uType = Game.GetResourceUsageType(iResourceID)
    if uType == ResourceUsageTypes.RESOURCEUSAGE_LUXURY then return BASE_PRICE_LUXURY end
    local info = GameInfo.Resources[iResourceID]
    if info and info.ResourceClassType == "RESOURCECLASS_MODERN" then return BASE_PRICE_MODERN end
    return BASE_PRICE_ANCIENT
end

local function PlayerKnowsResource(pPlayer, resourceInfo)
    if resourceInfo.TechReveal == nil or resourceInfo.TechReveal == "" then return true end
    local iTech = GameInfoTypes[resourceInfo.TechReveal]
    if iTech == nil then return true end
    return Teams[pPlayer:GetTeam()]:GetTeamTechs():HasTech(iTech)
end

-- ============================================================
-- Price Engine — runs once per game turn
-- ============================================================

local function ComputeAllPrices()
    local iTurn = Game.GetGameTurn()
    if iTurn == MapModData.EcoOverhaul_CmdPricesTurn then return end
    MapModData.EcoOverhaul_CmdPricesTurn = iTurn

    -- World-wonder cut: pay the Commodity Exchange owner a slice of LAST turn's total trade volume,
    -- then reset the accumulator. Cache the owner for this turn's market gate (the market is open to
    -- ALL civs once the wonder exists anywhere).
    local prevCmdOwner = MapModData.EcoOverhaul_CmdExchangeOwner or -1
    local cmdOwner = EcoWonderOwner(COMMODITY_WONDER)
    local newCmdOwner = (cmdOwner ~= nil) and cmdOwner or -1
    if prevCmdOwner < 0 and newCmdOwner >= 0 then
        local civ = (Players[cmdOwner] and Players[cmdOwner]:GetCivilizationShortDescription()) or "A civilization"
        EcoNotifyAll("Commodity Market Opened", civ .. " has built the Commodity Exchange — the commodity market is now live for all civilizations! Open the Commodity Market from the Additional Information menu.")
    end
    MapModData.EcoOverhaul_CmdExchangeOwner = newCmdOwner
    local cut = (cmdOwner ~= nil) and math.floor((MapModData.EcoOverhaul_CmdVolume or 0) * EXCHANGE_CUT) or 0
    if cut > 0 and Players[cmdOwner] ~= nil then EcoChangeCopper(Players[cmdOwner], cut) end
    MapModData.EcoOverhaul_CmdExchangeCut = cut
    MapModData.EcoOverhaul_CmdVolume = 0

    for k, v in pairs(MapModData.EcoOverhaul_CmdPrices) do
        MapModData.EcoOverhaul_CmdPrevPrices[k] = v
    end

    for resource in GameInfo.Resources() do
        local iRes  = resource.ID
        local uType = Game.GetResourceUsageType(iRes)

        -- IsExempt must match ReconcileExports: Corporations-mod equity shares are never
        -- tradeable, so they must not be priced or counted in supply/demand either.
        if IsTradeableResource(uType) and not IsExempt(resource) then
            local totalAvail, totalCommitted, civsWanting = 0, 0, 0
            local marketExports = 0   -- units offered for sale (positive committed) = importable supply
            local importDemand  = 0   -- units actively being imported (negative committed) = live buy orders
            for iP = 0, GameDefines.MAX_MAJOR_CIVS - 1 do
                local p = Players[iP]
                if p ~= nil and p:IsAlive() and not p:IsMinorCiv() and not p:IsBarbarian()
                and PlayerKnowsResource(p, resource) then
                    local committed = (MapModData.EcoOverhaul_CmdTiedUp[iP] and MapModData.EcoOverhaul_CmdTiedUp[iP][iRes]) or 0
                    local avail = p:GetNumResourceAvailable(iRes, true)
                    totalCommitted = totalCommitted + committed
                    if committed > 0 then marketExports = marketExports + committed
                    elseif committed < 0 then importDemand = importDemand - committed end
                    -- A civ that owns or is actively selling the resource is a supplier, not a "wanter".
                    if avail > 0 or committed > 0 then totalAvail = totalAvail + avail else civsWanting = civsWanting + 1 end
                end
            end
            -- City-states are market participants too: they SELL resources they hold and act as
            -- CONSUMERS (demand) for the ones they lack.
            local csWanting = 0
            for iCS = GameDefines.MAX_MAJOR_CIVS, GameDefines.MAX_CIV_PLAYERS - 1 do
                local p = Players[iCS]
                if p ~= nil and p:IsAlive() and p:IsMinorCiv() and not p:IsBarbarian() then
                    local csAvail = math.max(0, p:GetNumResourceAvailable(iRes, true))
                    if csAvail > 0 then totalAvail = totalAvail + csAvail else csWanting = csWanting + 1 end
                end
            end

            local climate = MapModData.EcoOverhaul_Climate or 1.0
            -- ORDER-BOOK PRICING (no floor): price is the balance of BUYERS — civs that lack the
            -- resource (latent demand) plus units actively being imported (live buy orders) — against
            -- SELLERS (available supply + committed exports + city-state supply), scaled by the
            -- climate. With NO buyers the price collapses toward 0 (worthless), exactly as on a real
            -- exchange: a seller only earns gold when someone is actually buying, and heavier buying
            -- lifts the price.
            local buyers  = (civsWanting * 2) + (csWanting * 1) + (importDemand * 3)
            local sellers = math.max(1, totalAvail + 2 * marketExports)
            local ratio   = math.min(4.0, (buyers * climate) / sellers)
            local fair    = GetBasePrice(iRes) * ratio
            -- Random shock, biased by the economic climate (boom skews up, recession down).
            local rnd     = (Game.Rand(2 * SHOCK_PCT + 1, "EcoCmdShock") - SHOCK_PCT) / 100
            local shock   = math.max(0.7, math.min(1.3, 1.0 + rnd + (climate - 1.0) * CLIMATE_BIAS))
            local target  = math.max(0, fair * shock)
            -- Drift toward the target rather than snapping, so prices move organically (and glide to 0).
            local oldP    = MapModData.EcoOverhaul_CmdPrices[iRes] or target
            MapModData.EcoOverhaul_CmdPrices[iRes] = math.max(0, math.floor(oldP + (target - oldP) * PRICE_SMOOTH))
            MapModData.EcoOverhaul_CmdSupply[iRes] = totalAvail + marketExports
            MapModData.EcoOverhaul_CmdDemand[iRes] = buyers
            MapModData.EcoOverhaul_CmdMarketAvail[iRes] = marketExports
        end
    end
end

-- ============================================================
-- Per-player export reconciliation (runs every turn)
--
-- Delta-based so we only call ChangeNumResourceTotal when the
-- committed amount actually changes (no per-turn churn). Income is
-- paid every turn for whatever is currently committed.
-- ============================================================

local function ReconcileExports(iPlayer)
    local pPlayer = Players[iPlayer]
    if pPlayer == nil then return end

    MapModData.EcoOverhaul_CmdTiedUp[iPlayer] = MapModData.EcoOverhaul_CmdTiedUp[iPlayer] or {}
    -- tiedUp[res] is the SIGNED position currently applied: + = units exported (removed
    -- from your stockpile), - = units imported (added to it). Reconciled by deltas.
    local tiedUp = MapModData.EcoOverhaul_CmdTiedUp[iPlayer]

    -- The commodity market opens only once the Commodity Exchange world wonder exists (anywhere) —
    -- then it is open to ALL civs. Until then, unwind every position (return exports, drop imports).
    if (MapModData.EcoOverhaul_CmdExchangeOwner or -1) < 0 then
        for iRes, q in pairs(tiedUp) do
            if q ~= 0 then pPlayer:ChangeNumResourceTotal(iRes, q); tiedUp[iRes] = 0 end  -- delta back to 0 is q
        end
        MapModData.EcoOverhaul_CmdSaleIncome[iPlayer] = 0
        return
    end

    local autoSell    = (MapModData.EcoOverhaul_AutoSell[iPlayer] == true)
    local autoBuy     = (MapModData.EcoOverhaul_AutoBuy[iPlayer] == true)
    local isAI        = not pPlayer:IsHuman()
    local hasExchange = HasCommodityExchange(pPlayer)
    local selling     = MapModData.EcoOverhaul_CmdSelling[iPlayer] or {}
    local cash        = 0                                 -- copper, signed: + export income, - import cost
    local volume      = 0                                 -- copper, gross value traded (feeds the exchange owner's cut)
    local budget      = EcoGetTreasuryCopper(pPlayer)     -- copper available to fund imports this turn
    if isAI then budget = math.floor(budget * AI_IMPORT_BUDGET_FRAC) end   -- AI commits only a slice of its treasury to buying

    for resource in GameInfo.Resources() do
        local iRes  = resource.ID
        local uType = Game.GetResourceUsageType(iRes)
        if IsTradeableResource(uType) and not IsExempt(resource) and PlayerKnowsResource(pPlayer, resource) then
            local current  = tiedUp[iRes] or 0
            -- True surplus if nothing were committed/imported (current is folded back in).
            local naturalSurplus = pPlayer:GetNumResourceAvailable(iRes, false) + current
            -- ALWAYS keep 1 available of every resource on the EXPORT side, so an empire never
            -- sells away its ability to build advanced units (or a luxury's happiness).
            local maxSell  = math.max(0, naturalSurplus - 1)

            -- Desired SIGNED quantity: + exports, - imports.
            local desired
            if autoSell then
                desired = maxSell                              -- human "Sell All Surplus": export everything
            elseif isAI then
                if maxSell > 0 then
                    -- #7 AI reads the price signal: export all surplus when the price is at/above its
                    -- base value, but hold back proportionally when it's depressed (so it recovers).
                    local base  = GetBasePrice(iRes)
                    local ratio = (MapModData.EcoOverhaul_CmdPrices[iRes] or base) / math.max(1, base)
                    desired = math.floor(maxSell * math.max(0.0, math.min(1.0, ratio)))
                elseif naturalSurplus < 1 then
                    -- AI as CONSUMER: import up to 1 of a resource it lacks (gated below by the market
                    -- supply pool + the AI's import budget), paying gold into the market like a real buyer.
                    desired = naturalSurplus - 1
                else
                    desired = 0
                end
            else
                desired = selling[iRes] or 0                   -- human manual (signed)
                -- #6 Auto-Buy: top up to 1 of each resource the player lacks. Manual buys can
                -- go deeper (min keeps the more-negative of the two); never reduces a sale.
                if autoBuy and maxSell <= 0 then
                    local target = naturalSurplus - 1          -- negative when the player has < 1
                    if target < 0 then desired = math.min(desired, target) end
                end
            end
            local q = math.max(-IMPORT_CAP, math.min(desired, maxSell))

            local priceCopper = (MapModData.EcoOverhaul_CmdPrices[iRes] or GetBasePrice(iRes)) * ECO_COPPER_PER_GOLD

            -- Imports draw from the market supply pool (only buy what other civs are selling) and
            -- are funded from available treasury this turn; reduced if either is short.
            if q < 0 then
                local affordable = math.floor(budget / math.max(1, priceCopper))
                local avail      = math.floor(MapModData.EcoOverhaul_CmdMarketAvail[iRes] or 0)
                local buy        = math.min(-q, math.max(0, affordable), math.max(0, avail))
                q = -buy
                budget = budget - priceCopper * buy
                MapModData.EcoOverhaul_CmdMarketAvail[iRes] = avail - buy   -- consume from the pool
            end

            if q ~= current then
                pPlayer:ChangeNumResourceTotal(iRes, current - q)   -- + returns/import-adds, - export-commits
                tiedUp[iRes] = q
            end
            if q ~= 0 then
                -- Copper precision so the Exchange's +25% premium keeps its fractional gold.
                -- The premium rewards EXPORTS only; imports pay the base market price.
                local unitCopper = priceCopper
                if hasExchange and q > 0 then unitCopper = math.floor(priceCopper * (1 + EXCHANGE_PREMIUM)) end
                cash = cash + unitCopper * q          -- q > 0 earns, q < 0 costs
                volume = volume + math.abs(unitCopper * q)
            end
        end
    end

    if cash ~= 0 then EcoChangeCopper(pPlayer, cash) end
    MapModData.EcoOverhaul_CmdVolume = (MapModData.EcoOverhaul_CmdVolume or 0) + volume   -- feeds the exchange owner's cut
    MapModData.EcoOverhaul_CmdTiedUp[iPlayer]     = tiedUp    -- persist signed positions
    MapModData.EcoOverhaul_CmdSaleIncome[iPlayer] = cash      -- copper, signed (net export income / import cost)
end

-- ============================================================
-- Per-player turn hook
-- ============================================================

function OnPlayerDoTurn_Commodity(iPlayer)
    local pPlayer = Players[iPlayer]
    if pPlayer == nil then return end
    if pPlayer:IsMinorCiv() or pPlayer:IsBarbarian() then return end

    ComputeAllPrices()        -- once per game turn (turn-guarded)
    ReconcileExports(iPlayer) -- commit/return units and pay income for this player
end

GameEvents.PlayerDoTurn.Add(OnPlayerDoTurn_Commodity)

print("Economy Overhaul: CommodityMarket.lua loaded.")
