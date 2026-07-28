-- ============================================================
-- Economy Overhaul: Banking.lua
--
-- Features:
--   - Floating global savings and debt rates, driven by the
--     ratio of total sovereign debt to total savings across
--     all banking civilizations.
--   - Per-player savings interest and debt compounding/repayment.
--   - Bond Exchange national wonder bonus (+0.5% savings rate).
--   - AI borrow/repay decisions keyed to current market rates.
--   - Human player notifications on rate shifts and market reports.
--   - Debt-burden unhappiness scaling with debt-to-income ratio.
-- ============================================================

include("EcoCurrency")   -- gold/silver/copper money layer: EcoChangeCopper, EcoGetTreasuryCopper

-- ============================================================
-- Constants
-- ============================================================

local MIN_SAVINGS_RATE   = 0.005   -- 0.5%  floor when everyone saves
local MAX_SAVINGS_RATE   = 0.060   -- 6.0%  ceiling when everyone borrows
local DEBT_SPREAD        = 0.030   -- 3.0%  fixed spread: debt rate = savings + spread
local BOND_EXCHANGE_BONUS= 0.005   -- 0.5%  extra savings rate for Bond Exchange owners

local LOAN_SMALL_AMOUNT  = 200   -- amount the AI borrows per loan
local MAX_DEBT           = 2000

-- Dynamic repayment rates keyed to how punishing the debt rate is
local REPAY_RATE_LOW     = 0.05    -- debt rate < 4%: comfortable, repay slowly
local REPAY_RATE_MID     = 0.10    -- debt rate 4–7%: moderate pressure
local REPAY_RATE_HIGH    = 0.20    -- debt rate > 7%: expensive, repay aggressively

-- AI borrowing thresholds
local AI_BORROW_MAX_RATE = 0.06    -- AI won't borrow if debt rate exceeds this
local AI_BORROW_GPT_MAX  = 8       -- AI borrows when GPT is below this (broadened for market activity)
local AI_BORROW_DEBT_CAP = 0.50    -- AI won't borrow if already above 50% of debt cap

-- Market report interval (turns between global notifications to human)
local REPORT_INTERVAL       = 10
-- Rate shift that triggers a mid-report notification
local NOTIFY_RATE_DELTA     = 0.010   -- 1.0%

-- ============================================================
-- Persistent storage (MapModData survives saves)
-- ============================================================

MapModData.EcoOverhaul_Debt             = MapModData.EcoOverhaul_Debt             or {}
MapModData.EcoOverhaul_InterestEarned   = MapModData.EcoOverhaul_InterestEarned   or {}
MapModData.EcoOverhaul_IndexPool        = MapModData.EcoOverhaul_IndexPool        or {}  -- shared with StockMarket: [player] index pool (copper)
MapModData.EcoOverhaul_IndexAutoInvest  = MapModData.EcoOverhaul_IndexAutoInvest  or {}  -- shared with StockMarket: [player] auto-invest toggle
MapModData.EcoOverhaul_DebtInterestOwed = MapModData.EcoOverhaul_DebtInterestOwed or {}
MapModData.EcoOverhaul_SavingsRate      = MapModData.EcoOverhaul_SavingsRate      or 0.020
MapModData.EcoOverhaul_DebtRate         = MapModData.EcoOverhaul_DebtRate         or 0.050
MapModData.EcoOverhaul_TotalSavings     = MapModData.EcoOverhaul_TotalSavings     or 0
MapModData.EcoOverhaul_TotalDebt        = MapModData.EcoOverhaul_TotalDebt        or 0
MapModData.EcoOverhaul_CorpDebt         = MapModData.EcoOverhaul_CorpDebt         or 0   -- #10 cycle-driven corporate borrowing
MapModData.EcoOverhaul_LastRateTurn      = MapModData.EcoOverhaul_LastRateTurn      or -1
MapModData.EcoOverhaul_PrevSavingsRate   = MapModData.EcoOverhaul_PrevSavingsRate   or 0.020
-- Debt unhappiness: tracks the happiness delta we've applied so we can reverse it cleanly
MapModData.EcoOverhaul_DebtUnhappiness  = MapModData.EcoOverhaul_DebtUnhappiness  or {}
-- Debt-to-income ratio stored for tooltip display (no recomputation needed in UI code)
MapModData.EcoOverhaul_DebtRatio        = MapModData.EcoOverhaul_DebtRatio        or {}

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

local function GetDebt(iPlayer)
    return MapModData.EcoOverhaul_Debt[iPlayer] or 0
end

local function SetDebt(iPlayer, amount)
    MapModData.EcoOverhaul_Debt[iPlayer] = math.max(0, math.floor(amount))
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

-- Gross gold income per turn (before maintenance costs).
-- Used as the GDP proxy for the debt-burden ratio.
local function GetGrossGoldIncome(pPlayer)
    local fromCities = pPlayer:GetGoldFromCitiesTimes100() / 100
    local fromTrade  = pPlayer:GetCityConnectionGoldTimes100() / 100
    local fromDiplo  = math.max(0, pPlayer:GetGoldPerTurnFromDiplomacy())
    return math.max(1, math.floor(fromCities + fromTrade + fromDiplo))
end

-- Debt-burden unhappiness formula.
-- Penalty is zero until debt > 1x gross income, then rises with a
-- power-1.35 curve. Capped at 20 to remain a serious but survivable penalty.
--
-- Example (80g/turn gross income):
--   80g  debt  (ratio 1.0x) → 0  unhappiness
--   160g debt  (ratio 2.0x) → 1  unhappiness
--   400g debt  (ratio 5.0x) → 8  unhappiness
--   640g debt  (ratio 8.0x) → 14 unhappiness
--   960g debt  (ratio 12x)  → 20 unhappiness (cap)
local function ComputeDebtUnhappiness(iPlayer)
    local iDebt = GetDebt(iPlayer)
    if iDebt == 0 then return 0 end
    local pPlayer = Players[iPlayer]
    if pPlayer == nil then return 0 end

    local iGrossIncome = GetGrossGoldIncome(pPlayer)
    local ratio = iDebt / iGrossIncome
    MapModData.EcoOverhaul_DebtRatio[iPlayer] = ratio

    if ratio <= 1 then return 0 end
    return math.min(20, math.floor((ratio - 1) ^ 1.35))
end

-- Apply the debt-burden unhappiness delta for this player.
-- Tracks the previously applied value and only sends the difference
-- to pPlayer:ChangeHappiness(), keeping the free-happiness counter
-- consistent across saves and load/unload cycles.
local function ApplyDebtUnhappiness(iPlayer, pPlayer)
    local newPenalty  = ComputeDebtUnhappiness(iPlayer)
    local prevPenalty = MapModData.EcoOverhaul_DebtUnhappiness[iPlayer] or 0

    if newPenalty ~= prevPenalty then
        -- Positive delta when penalty shrinks (restores happiness),
        -- negative delta when penalty grows (removes happiness).
        pPlayer:ChangeHappiness(prevPenalty - newPenalty)
        MapModData.EcoOverhaul_DebtUnhappiness[iPlayer] = newPenalty
    end

    -- Always keep the ratio fresh even if penalty didn't change
    if GetDebt(iPlayer) == 0 then
        MapModData.EcoOverhaul_DebtRatio[iPlayer] = 0
    end
end

local function GetRepayRate(debtRate)
    if debtRate > 0.07 then return REPAY_RATE_HIGH
    elseif debtRate > 0.04 then return REPAY_RATE_MID
    else return REPAY_RATE_LOW end
end

-- ============================================================
-- Global Rate Computation
-- Runs once per game turn (guarded by turn number).
-- Sums gold and debt across all major civs that have Banking,
-- then derives a floating savings rate and debt rate.
-- ============================================================

local function ComputeGlobalRates()
    local iCurrentTurn = Game.GetGameTurn()
    if iCurrentTurn == MapModData.EcoOverhaul_LastRateTurn then return end
    MapModData.EcoOverhaul_LastRateTurn = iCurrentTurn

    local totalSavings = 0
    local totalDebt    = 0

    for iP = 0, GameDefines.MAX_MAJOR_CIVS - 1 do
        local p = Players[iP]
        if p ~= nil and p:IsAlive() and not p:IsMinorCiv() and not p:IsBarbarian() then
            -- Count EVERY major civ's treasury as part of the world capital pool (and its
            -- debt), so the global rate reflects ALL civilizations' economics — not just the
            -- few that have researched Banking. (Banking still gates who can earn interest /
            -- borrow, handled per-player in OnPlayerDoTurn.)
            local gold = p:GetGold()
            if gold > 0 then totalSavings = totalSavings + gold end
            totalDebt = totalDebt + GetDebt(iP)
        end
    end

    -- #10 Corporate borrowing: the stock-market sectors structurally issue bonds, and how much
    -- they borrow tracks the economic cycle — heavy in a boom (expansion), light in a downturn.
    -- This private debt demand joins the world capital pool and pushes rates up (and vice versa),
    -- so the climate now drives rates THROUGH borrowing demand rather than a flat multiplier.
    local climate      = MapModData.EcoOverhaul_Climate or 1.0
    local corpFraction = math.max(0.02, math.min(0.45, 0.15 + (climate - 1.0) * 0.5))
    local corpDebt     = math.floor(totalSavings * corpFraction)

    -- debt ratio: fraction of the world capital pool that is borrowed (sovereign + corporate)
    local totalDebtAll = totalDebt + corpDebt
    local totalCapital = totalSavings + totalDebtAll
    local debtRatio    = (totalCapital > 0) and (totalDebtAll / totalCapital) or 0

    -- Savings rate rises linearly with the borrowed fraction of capital.
    local savingsRate  = math.max(MIN_SAVINGS_RATE, math.min(MAX_SAVINGS_RATE,
        MIN_SAVINGS_RATE + (MAX_SAVINGS_RATE - MIN_SAVINGS_RATE) * debtRatio))
    local debtRate     = savingsRate + DEBT_SPREAD

    MapModData.EcoOverhaul_PrevSavingsRate = MapModData.EcoOverhaul_SavingsRate
    MapModData.EcoOverhaul_SavingsRate     = savingsRate
    MapModData.EcoOverhaul_DebtRate        = debtRate
    MapModData.EcoOverhaul_TotalSavings    = totalSavings
    MapModData.EcoOverhaul_TotalDebt       = totalDebt
    MapModData.EcoOverhaul_CorpDebt        = corpDebt
end

-- ============================================================
-- Loan issuance (shared by human notifications and AI)
-- ============================================================

local function IssueLoan(iPlayerID, loanAmount, silent)
    local pPlayer = Players[iPlayerID]
    if pPlayer == nil then return end

    local iDebt = GetDebt(iPlayerID)
    if iDebt >= MAX_DEBT then
        if not silent then
            pPlayer:AddNotification(NotificationTypes.NOTIFICATION_GENERIC,
                "Your national debt has reached its limit of "
                    .. EcoFormatGold(MAX_DEBT) .. ". Repay before borrowing more.",
                "Loan Denied - Debt Limit Reached", -1, -1)
        end
        return
    end

    local iActual = math.min(loanAmount, MAX_DEBT - iDebt)
    pPlayer:ChangeGold(iActual)
    SetDebt(iPlayerID, iDebt + iActual)

    if not silent then
        local debtRate = MapModData.EcoOverhaul_DebtRate or 0.05
        pPlayer:AddNotification(NotificationTypes.NOTIFICATION_GENERIC,
            "Your treasury borrowed " .. EcoFormatGold(iActual) .. ". "
                .. "National debt: " .. EcoFormatGold(GetDebt(iPlayerID)) .. ". "
                .. "Current debt rate: " .. FormatRate(debtRate) .. "/turn.",
            "National Loan: +" .. EcoFormatGold(iActual), -1, -1)
    end
end

-- ============================================================
-- AI Banking Decisions
-- Called per AI player turn. The AI weighs the current debt
-- rate against its fiscal situation to decide whether to borrow,
-- and uses the rate level to set its repayment aggressiveness.
-- ============================================================

local function AIBankingDecision(iPlayer)
    local pPlayer = Players[iPlayer]
    if pPlayer:IsHuman() then return end

    local debtRate   = MapModData.EcoOverhaul_DebtRate or 0.05
    local iDebt      = GetDebt(iPlayer)
    local iGold      = pPlayer:GetGold()
    local iGPT       = pPlayer:CalculateGoldRate()

    -- Borrow only when rates are low, the civ is under fiscal pressure,
    -- and there is room under the debt cap.
    local rateIsAffordable = debtRate < AI_BORROW_MAX_RATE
    local hasFiscalPressure = iGPT < AI_BORROW_GPT_MAX
    local hasDebtRoom       = iDebt < MAX_DEBT * AI_BORROW_DEBT_CAP

    if rateIsAffordable and hasFiscalPressure and hasDebtRoom then
        -- Borrow probability scales with how far below the threshold the rate is
        local willingness = (AI_BORROW_MAX_RATE - debtRate) / AI_BORROW_MAX_RATE
        -- Use gold amount as a pseudo-random seed to avoid synchronized AI behavior
        local pseudoRand  = (iGold % 7) / 7.0
        if pseudoRand < willingness * 0.4 then
            IssueLoan(iPlayer, LOAN_SMALL_AMOUNT, true)
        end
    end
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

    if not HasBanking(pPlayer) then
        MapModData.EcoOverhaul_InterestEarned[iPlayer]   = 0
        MapModData.EcoOverhaul_DebtInterestOwed[iPlayer] = 0
        -- Ensure any lingering unhappiness penalty is cleared
        local prevPenalty = MapModData.EcoOverhaul_DebtUnhappiness[iPlayer] or 0
        if prevPenalty > 0 then
            pPlayer:ChangeHappiness(prevPenalty)
            MapModData.EcoOverhaul_DebtUnhappiness[iPlayer] = 0
        end
        return
    end

    local savingsRate = MapModData.EcoOverhaul_SavingsRate
    local debtRate    = MapModData.EcoOverhaul_DebtRate

    -- Bond Exchange bonus: owner earns slightly better savings rate
    local effectiveSavingsRate = savingsRate
    if HasBondExchange(pPlayer) then
        effectiveSavingsRate = effectiveSavingsRate + BOND_EXCHANGE_BONUS
    end

    local iGoldCopper = EcoGetTreasuryCopper(pPlayer)   -- treasury to copper precision (hundredths of gold)
    local iDebt = GetDebt(iPlayer)

    -- 1. Savings interest on positive gold balance, computed and paid in COPPER so
    --    small balances earn their fractional gold instead of flooring away to 0.
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

    -- 2. Compound debt interest, then auto-repay from updated balance
    local iDebtInterest = 0
    if iDebt > 0 then
        iDebtInterest = math.max(1, math.ceil(iDebt * debtRate))
        SetDebt(iPlayer, iDebt + iDebtInterest)

        local iGoldNow   = pPlayer:GetGold()
        local repayRate  = GetRepayRate(debtRate)
        if iGoldNow > 0 then
            local iRepayment = math.min(
                GetDebt(iPlayer),
                math.max(1, math.floor(iGoldNow * repayRate))
            )
            pPlayer:ChangeGold(-iRepayment)
            SetDebt(iPlayer, GetDebt(iPlayer) - iRepayment)
        end
    end
    MapModData.EcoOverhaul_DebtInterestOwed[iPlayer] = iDebtInterest

    -- 3. Debt-burden unhappiness (applies to all civs equally)
    ApplyDebtUnhappiness(iPlayer, pPlayer)

    -- 4. AI borrowing decision
    if not pPlayer:IsHuman() then
        AIBankingDecision(iPlayer)
    end
end

-- ============================================================
-- Human player turn start:
--   - Rate-shift alert (when rate moves significantly)
--   - Periodic bond market report
-- (Loans are taken from the National Treasury panel, not here.)
-- ============================================================

function OnActivePlayerTurnStart()
    local iPlayer = Game.GetActivePlayer()
    local pPlayer = Players[iPlayer]
    if pPlayer == nil or not pPlayer:IsHuman() then return end
    if not HasBanking(pPlayer) then return end

    local savingsRate = MapModData.EcoOverhaul_SavingsRate
    local debtRate    = MapModData.EcoOverhaul_DebtRate
    local prevRate    = MapModData.EcoOverhaul_PrevSavingsRate
    local iCurrentTurn= Game.GetGameTurn()

    -- Loan offers are now handled in the National Treasury panel.
    -- No notifications needed here; the panel provides a clean interface.

    -- Rate-shift alert
    local rateDelta = math.abs(savingsRate - prevRate)
    if rateDelta >= NOTIFY_RATE_DELTA and prevRate > 0 then
        local direction = (savingsRate > prevRate) and "risen" or "fallen"
        local reason    = (savingsRate > prevRate)
            and "increased borrowing across civilizations is crowding out savings."
            or  "civilizations are paying down debt, freeing up capital."
        pPlayer:AddNotification(
            NotificationTypes.NOTIFICATION_GENERIC,
            "Global interest rates have " .. direction
                .. " to " .. FormatRate(savingsRate) .. "/turn for savers ("
                .. FormatRate(debtRate) .. "/turn for borrowers). "
                .. "This is because " .. reason,
            "Bond Market: Rates " .. (savingsRate > prevRate and "Rising" or "Falling"),
            -1, -1)
    end

    -- Periodic bond market report
    if iCurrentTurn > 0 and (iCurrentTurn % REPORT_INTERVAL == 0) then
        local totalSavings = MapModData.EcoOverhaul_TotalSavings or 0
        local totalDebt    = MapModData.EcoOverhaul_TotalDebt    or 0
        local totalCapital = totalSavings + totalDebt
        local debtRatioPct = (totalCapital > 0)
            and math.floor(totalDebt / totalCapital * 100) or 0
        local bondExtraStr = HasBondExchange(pPlayer)
            and (" Your Bond Exchange earns you an extra "
                .. FormatRate(BOND_EXCHANGE_BONUS) .. ".") or ""

        pPlayer:AddNotification(
            NotificationTypes.NOTIFICATION_GENERIC,
            "Global savings rate: [COLOR_POSITIVE_TEXT]"
                .. FormatRate(savingsRate) .. "/turn[ENDCOLOR]   "
                .. "Borrowing rate: [COLOR_WARNING_TEXT]"
                .. FormatRate(debtRate) .. "/turn[ENDCOLOR]"
                .. "[NEWLINE]Total sovereign savings: " .. EcoFormatGold(totalSavings)
                .. "   Total sovereign debt: " .. EcoFormatGold(totalDebt)
                .. " (" .. debtRatioPct .. "% of all capital is borrowed)"
                .. bondExtraStr,
            "Bond Market Report (Turn " .. iCurrentTurn .. ")",
            -1, -1)
    end
end

-- ============================================================
-- Event registration
--
-- Loans are issued from the National Treasury panel (a panel
-- button), not from clickable notifications: Civ5 has no Lua event for
-- generic notification clicks (Events.NotificationActivated does not exist).
-- The rate-shift alerts and bond-market report below are purely
-- informational notifications, which work fine.
-- ============================================================

GameEvents.PlayerDoTurn.Add(OnPlayerDoTurn)
Events.ActivePlayerTurnStart.Add(OnActivePlayerTurnStart)

print("Economy Overhaul: Banking.lua loaded.")
