-- ============================================================
-- Economy Overhaul: Banking.lua
--
-- Features:
--   - A floating global savings rate, driven by how much of the
--     world's capital pool corporate borrowers are absorbing.
--   - Per-player savings interest on the treasury.
--   - Bond Exchange national wonder bonus (+0.5% savings rate).
--   - Optional routing of that interest into the stock index fund.
--   - Human notifications on rate shifts, plus a periodic report.
--
-- NOTE: national loans, sovereign debt, auto-repayment and the
-- debt-burden unhappiness penalty were REMOVED by design. The
-- treasury is a savings-side system only; nobody borrows but the
-- (abstract) corporate sector, which is what makes rates move.
-- ============================================================

include("EcoCurrency")   -- gold/silver/copper money layer: EcoChangeCopper, EcoGetTreasuryCopper

-- ============================================================
-- Constants
-- ============================================================

local MIN_SAVINGS_RATE   = 0.005   -- 0.5%  floor when capital is plentiful
local MAX_SAVINGS_RATE   = 0.060   -- 6.0%  ceiling when borrowing demand is heavy
local BOND_EXCHANGE_BONUS= 0.005   -- 0.5%  extra savings rate for Bond Exchange owners

-- Corporate borrowing band (fraction of world capital the private sector absorbs).
-- The economic climate slides demand across this band; the savings rate is mapped
-- from where in the band we currently sit.
local CORP_FRACTION_MIN  = 0.02
local CORP_FRACTION_MAX  = 0.45

-- Market report interval (turns between global notifications to human)
local REPORT_INTERVAL       = 10
-- Rate shift that triggers a mid-report notification
local NOTIFY_RATE_DELTA     = 0.010   -- 1.0%

-- ============================================================
-- Persistent storage (MapModData)
-- ============================================================

MapModData.EcoOverhaul_InterestEarned   = MapModData.EcoOverhaul_InterestEarned   or {}
MapModData.EcoOverhaul_IndexPool        = MapModData.EcoOverhaul_IndexPool        or {}  -- shared with StockMarket: [player] index pool (copper)
MapModData.EcoOverhaul_IndexAutoInvest  = MapModData.EcoOverhaul_IndexAutoInvest  or {}  -- shared with StockMarket: [player] auto-invest toggle
MapModData.EcoOverhaul_SavingsRate      = MapModData.EcoOverhaul_SavingsRate      or 0.020
MapModData.EcoOverhaul_TotalSavings     = MapModData.EcoOverhaul_TotalSavings     or 0
MapModData.EcoOverhaul_CorpDebt         = MapModData.EcoOverhaul_CorpDebt         or 0   -- cycle-driven corporate borrowing
MapModData.EcoOverhaul_BorrowedPct      = MapModData.EcoOverhaul_BorrowedPct      or 0   -- share of world capital that is borrowed (display)
MapModData.EcoOverhaul_LastRateTurn     = MapModData.EcoOverhaul_LastRateTurn     or -1
MapModData.EcoOverhaul_PrevSavingsRate  = MapModData.EcoOverhaul_PrevSavingsRate  or 0.020

-- ============================================================
-- Helpers
-- ============================================================

local function HasBanking(pPlayer)
    local pTeam = Teams[pPlayer:GetTeam()]
    if pTeam == nil then return false end
    local iTech = GameInfoTypes["TECH_BANKING"]
    if iTech == nil then return false end
    return pTeam:GetTeamTechs():HasTech(iTech)
end

local function HasBondExchange(pPlayer)
    local iBldg = GameInfoTypes["BUILDING_BOND_EXCHANGE"]
    if iBldg == nil then return false end
    for pCity in pPlayer:Cities() do
        if pCity:GetNumBuilding(iBldg) > 0 then return true end
    end
    return false
end

local function FormatRate(rate)
    return string.format("%.1f%%", rate * 100)
end

-- One-time migration for games saved before the debt system was removed.
-- The old debt-burden penalty was applied with pPlayer:ChangeHappiness(), which writes
-- a REAL engine value stored in the save — deleting the feature on its own would strand
-- that penalty on the player permanently. Hand it back once, then drop the record so
-- this never runs again.
local function ClearLegacyDebtUnhappiness(iPlayer, pPlayer)
    local legacy = MapModData.EcoOverhaul_DebtUnhappiness
    if legacy == nil then return end
    local applied = legacy[iPlayer] or 0
    if applied > 0 then pPlayer:ChangeHappiness(applied) end
    legacy[iPlayer] = nil
    if next(legacy) == nil then
        MapModData.EcoOverhaul_DebtUnhappiness = nil
        MapModData.EcoOverhaul_DebtRatio       = nil
    end
end

-- ============================================================
-- Global Rate Computation
-- Runs once per game turn (guarded by turn number). Sums every major
-- civ's treasury into a world capital pool, then derives the floating
-- savings rate from how heavily the corporate sector is borrowing.
-- ============================================================

local function ComputeGlobalRates()
    local iCurrentTurn = Game.GetGameTurn()
    if iCurrentTurn == MapModData.EcoOverhaul_LastRateTurn then return end
    MapModData.EcoOverhaul_LastRateTurn = iCurrentTurn

    local totalSavings = 0

    for iP = 0, GameDefines.MAX_MAJOR_CIVS - 1 do
        local p = Players[iP]
        if p ~= nil and p:IsAlive() and not p:IsMinorCiv() and not p:IsBarbarian() then
            -- Count EVERY major civ's treasury as part of the world capital pool, so the
            -- global rate reflects ALL civilizations' economics — not just the few that have
            -- researched Banking. (Banking still gates who EARNS interest, per-player below.)
            local gold = p:GetGold()
            if gold > 0 then totalSavings = totalSavings + gold end
        end
    end

    -- Corporate borrowing: the stock-market sectors structurally issue private debt, and how
    -- much they borrow tracks the economic cycle — heavy in a boom (expansion), light in a
    -- downturn. With sovereign lending gone this is the ONLY borrowing left, so it alone is
    -- what makes the savings rate float: a boom bids rates up, a slump lets them fall.
    local climate      = MapModData.EcoOverhaul_Climate or 1.0
    local corpFraction = math.max(CORP_FRACTION_MIN, math.min(CORP_FRACTION_MAX, 0.15 + (climate - 1.0) * 0.5))
    local corpDebt     = math.floor(totalSavings * corpFraction)

    -- Map the rate across the corporate borrowing band. (Using the raw borrowed-share of
    -- capital would compress the rate into a narrow 0.6-2.2% strip now that sovereign debt
    -- no longer adds to demand, so normalise across the band to keep the full 0.5-6% swing.)
    local demand = (corpFraction - CORP_FRACTION_MIN) / (CORP_FRACTION_MAX - CORP_FRACTION_MIN)
    local savingsRate = math.max(MIN_SAVINGS_RATE, math.min(MAX_SAVINGS_RATE,
        MIN_SAVINGS_RATE + (MAX_SAVINGS_RATE - MIN_SAVINGS_RATE) * demand))

    -- True borrowed share of the pool, kept honest for the tooltips/report.
    local totalCapital = totalSavings + corpDebt
    local borrowedPct  = (totalCapital > 0) and math.floor(corpDebt / totalCapital * 100) or 0

    MapModData.EcoOverhaul_PrevSavingsRate = MapModData.EcoOverhaul_SavingsRate
    MapModData.EcoOverhaul_SavingsRate     = savingsRate
    MapModData.EcoOverhaul_TotalSavings    = totalSavings
    MapModData.EcoOverhaul_CorpDebt        = corpDebt
    MapModData.EcoOverhaul_BorrowedPct     = borrowedPct
end

-- ============================================================
-- Per-player turn processing
-- ============================================================

function OnPlayerDoTurn(iPlayer)
    local pPlayer = Players[iPlayer]
    if pPlayer == nil then return end
    if pPlayer:IsMinorCiv() or pPlayer:IsBarbarian() then return end

    -- Compute global rates once per turn (first call each turn does the work)
    ComputeGlobalRates()

    -- Give back any happiness the removed debt-burden penalty still has applied.
    ClearLegacyDebtUnhappiness(iPlayer, pPlayer)

    if not HasBanking(pPlayer) then
        MapModData.EcoOverhaul_InterestEarned[iPlayer] = 0
        return
    end

    -- Bond Exchange bonus: owner earns a slightly better savings rate
    local effectiveSavingsRate = MapModData.EcoOverhaul_SavingsRate
    if HasBondExchange(pPlayer) then
        effectiveSavingsRate = effectiveSavingsRate + BOND_EXCHANGE_BONUS
    end

    local iGoldCopper = EcoGetTreasuryCopper(pPlayer)   -- treasury to copper precision (hundredths of gold)

    -- Savings interest on a positive gold balance, computed and paid in COPPER so
    -- small balances earn their fractional gold instead of flooring away to 0.
    local iInterest = 0   -- copper
    if iGoldCopper > 0 then
        iInterest = math.max(1, math.floor(iGoldCopper * effectiveSavingsRate))
        -- A Bond Exchange owner may auto-invest their interest into the stock index (once the
        -- Global Stock Market exists) instead of banking it — the same option the stock-wonder
        -- owner has for their fees. Toggled per-player in the Financial Markets panel; default ON.
        local autoInvest = (MapModData.EcoOverhaul_IndexAutoInvest == nil)
                        or (MapModData.EcoOverhaul_IndexAutoInvest[iPlayer] ~= false)
        if autoInvest and HasBondExchange(pPlayer) and (EcoWonderOwner("BUILDING_ECO_GLOBAL_STOCK_MARKET") ~= nil) then
            if MapModData.EcoOverhaul_IndexPool == nil then MapModData.EcoOverhaul_IndexPool = {} end
            MapModData.EcoOverhaul_IndexPool[iPlayer] = (MapModData.EcoOverhaul_IndexPool[iPlayer] or 0) + iInterest
            iInterest = 0   -- routed to the index fund, not the treasury
        else
            EcoChangeCopper(pPlayer, iInterest)
        end
    end
    MapModData.EcoOverhaul_InterestEarned[iPlayer] = iInterest   -- copper (0 when routed to the index)
end

-- ============================================================
-- Human player turn start:
--   - Rate-shift alert (when the rate moves significantly)
--   - Periodic capital market report
-- ============================================================

function OnActivePlayerTurnStart()
    local iPlayer = Game.GetActivePlayer()
    local pPlayer = Players[iPlayer]
    if pPlayer == nil or not pPlayer:IsHuman() then return end
    if not HasBanking(pPlayer) then return end

    local savingsRate = MapModData.EcoOverhaul_SavingsRate
    local prevRate    = MapModData.EcoOverhaul_PrevSavingsRate
    local iCurrentTurn= Game.GetGameTurn()

    -- Rate-shift alert
    local rateDelta = math.abs(savingsRate - prevRate)
    if rateDelta >= NOTIFY_RATE_DELTA and prevRate > 0 then
        local rising    = (savingsRate > prevRate)
        local direction = rising and "risen" or "fallen"
        local reason    = rising
            and "corporate borrowing has picked up and is competing for capital."
            or  "borrowing has eased, leaving capital plentiful."
        pPlayer:AddNotification(
            NotificationTypes.NOTIFICATION_GENERIC,
            "Global interest rates have " .. direction
                .. " to " .. FormatRate(savingsRate) .. "/turn for savers. "
                .. "This is because " .. reason,
            "Capital Market: Rates " .. (rising and "Rising" or "Falling"),
            -1, -1)
    end

    -- Periodic capital market report
    if iCurrentTurn > 0 and (iCurrentTurn % REPORT_INTERVAL == 0) then
        local totalSavings = MapModData.EcoOverhaul_TotalSavings or 0
        local corpDebt     = MapModData.EcoOverhaul_CorpDebt     or 0
        local borrowedPct  = MapModData.EcoOverhaul_BorrowedPct  or 0
        local bondExtraStr = HasBondExchange(pPlayer)
            and (" Your Bond Exchange earns you an extra "
                .. FormatRate(BOND_EXCHANGE_BONUS) .. ".") or ""

        pPlayer:AddNotification(
            NotificationTypes.NOTIFICATION_GENERIC,
            "Global savings rate: [COLOR_POSITIVE_TEXT]"
                .. FormatRate(savingsRate) .. "/turn[ENDCOLOR]"
                .. "[NEWLINE]World capital: " .. EcoFormatGold(totalSavings)
                .. "   Corporate borrowing: " .. EcoFormatGold(corpDebt)
                .. " (" .. borrowedPct .. "% of all capital is borrowed)"
                .. bondExtraStr,
            "Capital Market Report (Turn " .. iCurrentTurn .. ")",
            -1, -1)
    end
end

-- ============================================================
-- Event registration
-- ============================================================

GameEvents.PlayerDoTurn.Add(OnPlayerDoTurn)
Events.ActivePlayerTurnStart.Add(OnActivePlayerTurnStart)

print("Economy Overhaul: Banking.lua loaded.")
