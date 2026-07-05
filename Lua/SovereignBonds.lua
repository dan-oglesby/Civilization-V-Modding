-- ============================================================
-- Economy Overhaul: SovereignBonds.lua
--
-- A market in OTHER civilizations' sovereign debt. Buy a civ's
-- bonds to earn a coupon every turn; sell them back at the going
-- price. Distressed civs pay higher yields but trade at a discount
-- and can default — and if the issuer is wiped off the map, their
-- bonds become worthless.
--
-- Self-contained: it derives each civ's creditworthiness on its own.
-- If the Banking mod is present, it uses that mod's per-civ debt as a
-- richer creditworthiness signal.
--
-- A civ's bonds become available to trade once you have met them.
-- Buying/selling is done from the Sovereign Bonds panel; this file
-- runs the market, coupons, and defaults.
--
-- NOTE: Uses Lua 5.1 syntax — required by Civ5.
-- ============================================================

include("EcoCurrency")   -- gold/silver/copper money layer: EcoChangeCopper, ECO_COPPER_PER_GOLD

-- ============================================================
-- Constants
-- ============================================================

local FACE_VALUE     = 100      -- nominal value of one bond unit
local BASE_YIELD     = 0.03     -- coupon yield floor (per turn)
local RISK_SPREAD    = 0.06     -- extra yield at maximum distress
local PRICE_MIN      = 35
local PRICE_MAX      = 130
local DEBT_RATIO_FULL = 8.0     -- debt = 8x income counts as maximum distress
local HAIRCUT_DISTRESS = 0.85   -- above this, a default (haircut) can occur
local HAIRCUT_CHANCE = 8        -- % chance per turn of a haircut when very distressed
local HAIRCUT_FRACTION = 0.30   -- fraction of units wiped in a haircut

-- ============================================================
-- Persistent storage
-- ============================================================

MapModData.EcoOverhaul_BondHoldings = MapModData.EcoOverhaul_BondHoldings or {}  -- [holder][issuer] = units
MapModData.EcoOverhaul_BondYield    = MapModData.EcoOverhaul_BondYield    or {}  -- [issuer] = yield
MapModData.EcoOverhaul_BondPrice    = MapModData.EcoOverhaul_BondPrice    or {}  -- [issuer] = price
MapModData.EcoOverhaul_BondDistress = MapModData.EcoOverhaul_BondDistress or {}  -- [issuer] = 0..1
MapModData.EcoOverhaul_BondIncome   = MapModData.EcoOverhaul_BondIncome   or {}  -- [holder] = last coupon total
MapModData.EcoOverhaul_BondTurn     = MapModData.EcoOverhaul_BondTurn     or -1

-- ============================================================
-- Helpers
-- ============================================================

local function GetGrossGoldIncome(pPlayer)
    local fromCities = pPlayer:GetGoldFromCitiesTimes100() / 100
    local fromTrade  = pPlayer:GetCityConnectionGoldTimes100() / 100
    local fromDiplo  = math.max(0, pPlayer:GetGoldPerTurnFromDiplomacy())
    return math.max(1, math.floor(fromCities + fromTrade + fromDiplo))
end

local function GetHoldings(iHolder, iIssuer)
    local tbl = MapModData.EcoOverhaul_BondHoldings[iHolder]
    return tbl and (tbl[iIssuer] or 0) or 0
end

local function SetHoldings(iHolder, iIssuer, units)
    if MapModData.EcoOverhaul_BondHoldings[iHolder] == nil then
        MapModData.EcoOverhaul_BondHoldings[iHolder] = {}
    end
    MapModData.EcoOverhaul_BondHoldings[iHolder][iIssuer] = math.max(0, units)
    MapModData.EcoOverhaul_BondHoldings[iHolder] = MapModData.EcoOverhaul_BondHoldings[iHolder]
end

-- Distress in [0,1]. Uses Banking's per-civ debt when present, else a
-- proxy from gold-per-turn and treasury size.
local function ComputeDistress(pIssuer, iIssuer)
    local bankingDebt = MapModData.EcoOverhaul_Debt and MapModData.EcoOverhaul_Debt[iIssuer]
    if bankingDebt ~= nil and bankingDebt > 0 then
        local ratio = bankingDebt / GetGrossGoldIncome(pIssuer)
        return math.max(0, math.min(1, ratio / DEBT_RATIO_FULL))
    end
    -- Standalone proxy
    local distress = 0
    local gpt = pIssuer:CalculateGoldRate()
    if gpt < 0 then distress = distress + math.min(0.5, (-gpt) / 40) end
    if pIssuer:GetGold() < 100 then distress = distress + 0.2 end
    return math.max(0, math.min(1, distress))
end

-- ============================================================
-- Market computation + defaults — once per game turn (turn-guarded)
-- ============================================================

local function ComputeBondMarket()
    local iTurn = Game.GetGameTurn()
    if iTurn == MapModData.EcoOverhaul_BondTurn then return end
    MapModData.EcoOverhaul_BondTurn = iTurn

    for iP = 0, GameDefines.MAX_MAJOR_CIVS - 1 do
        local p = Players[iP]
        if p ~= nil and p:IsAlive() and not p:IsMinorCiv() and not p:IsBarbarian() then
            local distress = ComputeDistress(p, iP)
            MapModData.EcoOverhaul_BondDistress[iP] = distress
            MapModData.EcoOverhaul_BondYield[iP] = BASE_YIELD + RISK_SPREAD * distress
            MapModData.EcoOverhaul_BondPrice[iP] =
                math.floor(math.max(PRICE_MIN, math.min(PRICE_MAX, FACE_VALUE * (1.2 - 0.5 * distress))))
        end
    end

    -- Defaults: wipe positions in eliminated issuers; apply random haircuts
    -- to severely distressed issuers. Notify a human holder either way.
    for iHolder, byIssuer in pairs(MapModData.EcoOverhaul_BondHoldings) do
        local pHolder = Players[iHolder]
        for iIssuer, units in pairs(byIssuer) do
            if units > 0 then
                local pIssuer = Players[iIssuer]
                local issuerName = (pIssuer ~= nil) and pIssuer:GetCivilizationShortDescription() or "A nation"
                if pIssuer == nil or not pIssuer:IsAlive() then
                    byIssuer[iIssuer] = 0
                    if pHolder ~= nil and pHolder:IsHuman() then
                        pHolder:AddNotification(NotificationTypes.NOTIFICATION_GENERIC,
                            issuerName .. " has fallen. Its sovereign bonds are now worthless — your holdings have been wiped out.",
                            "Sovereign Default: " .. issuerName, -1, -1)
                    end
                elseif (MapModData.EcoOverhaul_BondDistress[iIssuer] or 0) >= HAIRCUT_DISTRESS
                   and Game.Rand(100, "EcoBondHaircut") < HAIRCUT_CHANCE then
                    local lost = math.max(1, math.floor(units * HAIRCUT_FRACTION))
                    byIssuer[iIssuer] = units - lost
                    if pHolder ~= nil and pHolder:IsHuman() then
                        pHolder:AddNotification(NotificationTypes.NOTIFICATION_GENERIC,
                            issuerName .. " has restructured its debt. You lost " .. lost
                                .. " of your " .. units .. " bond units in the haircut.",
                            "Debt Restructuring: " .. issuerName, -1, -1)
                    end
                end
            end
        end
        MapModData.EcoOverhaul_BondHoldings[iHolder] = byIssuer
    end
end

-- ============================================================
-- Per-player turn: pay coupons on this player's holdings
-- ============================================================

function OnPlayerDoTurn_Bonds(iPlayer)
    local pPlayer = Players[iPlayer]
    if pPlayer == nil then return end
    if pPlayer:IsMinorCiv() or pPlayer:IsBarbarian() then return end

    ComputeBondMarket()  -- first caller each turn does the work

    local byIssuer = MapModData.EcoOverhaul_BondHoldings[iPlayer]
    if byIssuer == nil then
        MapModData.EcoOverhaul_BondIncome[iPlayer] = 0
        return
    end

    -- Coupons computed and paid in COPPER so fractional yields (e.g. 4.5%) keep
    -- their sub-gold part instead of flooring. Bond prices stay whole gold.
    local coupon = 0   -- copper
    for iIssuer, units in pairs(byIssuer) do
        if units > 0 then
            local yield = MapModData.EcoOverhaul_BondYield[iIssuer] or BASE_YIELD
            coupon = coupon + math.floor(units * FACE_VALUE * ECO_COPPER_PER_GOLD * yield)
        end
    end
    if coupon > 0 then
        EcoChangeCopper(pPlayer, coupon)
    end
    MapModData.EcoOverhaul_BondIncome[iPlayer] = coupon   -- copper
end

GameEvents.PlayerDoTurn.Add(OnPlayerDoTurn_Bonds)

print("Economy Overhaul: SovereignBonds.lua loaded.")
