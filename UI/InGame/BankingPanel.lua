-- ============================================================
-- Economy Overhaul - Banking: BankingPanel.lua
--
-- Standalone "National Treasury" panel: take national loans, view
-- debt status, and read the debt-burden penalty. Opens from the
-- Additional Information dropdown (top-right), Lord Mayors pattern.
--
-- The debt engine (rate computation, interest accrual, auto-repay,
-- and debt-burden unhappiness) lives in Banking.lua; this panel is
-- purely its front-end and shares state through MapModData.
-- ============================================================

include("EcoCurrency")   -- gold/silver/copper + empire-currency money layer: EcoFormatGold

local MAX_DEBT = 2000

-- ============================================================
-- Helpers
-- ============================================================

local function GetDebt(iPlayer)
    return (MapModData.EcoOverhaul_Debt and MapModData.EcoOverhaul_Debt[iPlayer]) or 0
end

local function GetGrossIncome(pPlayer)
    local fromCities = pPlayer:GetGoldFromCitiesTimes100() / 100
    local fromTrade  = pPlayer:GetCityConnectionGoldTimes100() / 100
    local fromDiplo  = math.max(0, pPlayer:GetGoldPerTurnFromDiplomacy())
    return math.max(1, math.floor(fromCities + fromTrade + fromDiplo))
end

-- ============================================================
-- Loan execution
-- ============================================================

local function ExecuteLoan(iPlayerID, amount)
    local pPlayer = Players[iPlayerID]
    if pPlayer == nil then return false end
    if MapModData.EcoOverhaul_Debt == nil then MapModData.EcoOverhaul_Debt = {} end
    local iDebt = GetDebt(iPlayerID)
    if iDebt >= MAX_DEBT then return false end
    local actual = math.min(amount, MAX_DEBT - iDebt)
    pPlayer:ChangeGold(actual)
    MapModData.EcoOverhaul_Debt[iPlayerID] = iDebt + actual
    return true
end

-- ============================================================
-- Panel refresh
-- ============================================================

local function RefreshPanel()
    local iPlayerID = Game.GetActivePlayer()
    local pPlayer   = Players[iPlayerID]
    if pPlayer == nil then return end
    local savingsRate = MapModData.EcoOverhaul_SavingsRate or 0
    local debtRate    = MapModData.EcoOverhaul_DebtRate    or 0
    local iDebt       = GetDebt(iPlayerID)
    local grossIncome = GetGrossIncome(pPlayer)
    local iDebtRatio  = iDebt / grossIncome
    local penalty     = (MapModData.EcoOverhaul_DebtUnhappiness and MapModData.EcoOverhaul_DebtUnhappiness[iPlayerID]) or 0
    local iSpace      = MAX_DEBT - iDebt

    if savingsRate > 0 then
        Controls.RatesLabel:SetText(string.format(
            "Savings rate: [COLOR_POSITIVE_TEXT]%.1f%%/turn[ENDCOLOR]   Debt rate: [COLOR_WARNING_TEXT]%.1f%%/turn[ENDCOLOR][NEWLINE]World savings: %s   Sovereign debt: %s   Corporate borrowing: %s",
            savingsRate * 100, debtRate * 100, EcoFormatGold(MapModData.EcoOverhaul_TotalSavings or 0), EcoFormatGold(MapModData.EcoOverhaul_TotalDebt or 0), EcoFormatGold(MapModData.EcoOverhaul_CorpDebt or 0)))
    else
        Controls.RatesLabel:SetText("Discover Banking to unlock sovereign debt and interest rates.")
    end

    if iDebt > 0 then
        Controls.DebtLabel:SetText(string.format(
            "Current debt: [COLOR_WARNING_TEXT]%s[ENDCOLOR]   Gross income: %s/turn   Debt/income: [COLOR_WARNING_TEXT]%.1fx[ENDCOLOR][NEWLINE]Interest this turn: %s   Credit remaining: %s",
            EcoFormatGold(iDebt), EcoFormatGold(grossIncome), iDebtRatio, EcoFormatGold((MapModData.EcoOverhaul_DebtInterestOwed and MapModData.EcoOverhaul_DebtInterestOwed[iPlayerID]) or 0), EcoFormatGold(math.max(0, iSpace))))
    else
        Controls.DebtLabel:SetText("No outstanding debt.   Gross income: " .. EcoFormatGold(grossIncome) .. "/turn   Credit available: " .. EcoFormatGold(iSpace))
    end

    local debtRateStr = string.format("%.1f%%/turn", debtRate * 100)
    Controls.BorrowInfoLabel:SetText("Loans accrue interest at " .. debtRateStr .. ". Your treasury auto-repays each turn. Max debt: " .. EcoFormatGold(MAX_DEBT) .. ".")
    Controls.Borrow200Label:SetText("Borrow " .. EcoFormatGold(200) .. "  (" .. debtRateStr .. " interest)")
    Controls.Borrow500Label:SetText("Borrow " .. EcoFormatGold(500) .. "  (" .. debtRateStr .. " interest)")
    Controls.Borrow200Btn:SetDisabled(iSpace < 200)
    Controls.Borrow500Btn:SetDisabled(iSpace < 500)

    if penalty > 0 then
        Controls.DebtBurdenLabel:SetText(string.format(
            "[COLOR_WARNING_TEXT]Active penalty: -%d [ICON_HAPPINESS_4] unhappiness[ENDCOLOR][NEWLINE]Debt/income %.1fx — penalty accelerates above 1x. Repay or grow income to reduce.",
            penalty, iDebtRatio))
    elseif iDebt > 0 then
        Controls.DebtBurdenLabel:SetText(string.format("No unhappiness yet (debt/income %.1fx < 1x threshold).", iDebtRatio))
    else
        Controls.DebtBurdenLabel:SetText("No debt — no unhappiness burden.")
    end
end

-- ============================================================
-- Button callbacks
-- ============================================================

Controls.Borrow200Btn:RegisterCallback(Mouse.eLClick, function()
    ExecuteLoan(Game.GetActivePlayer(), 200); RefreshPanel()
end)
Controls.Borrow500Btn:RegisterCallback(Mouse.eLClick, function()
    ExecuteLoan(Game.GetActivePlayer(), 500); RefreshPanel()
end)

-- ============================================================
-- Show / Hide — via ContextPtr (Lord Mayors pattern)
-- ============================================================

local function ShowPanel()
    RefreshPanel()
    ContextPtr:SetHide(false)
end

local function HidePanel()
    ContextPtr:SetHide(true)
end

Controls.ClosePanelBtn:RegisterCallback(Mouse.eLClick, HidePanel)

Events.ActivePlayerTurnStart.Add(function()
    if not ContextPtr:IsHidden() then RefreshPanel() end
end)
Events.SerialEventGameDataDirty.Add(function()
    if not ContextPtr:IsHidden() then RefreshPanel() end
end)

-- ============================================================
-- Register with Additional Information dropdown (BNW standard)
-- ============================================================

function EconOverhaul_Banking_AddInfoEntry(additionalEntries)
    table.insert(additionalEntries, {
        text = "National Treasury",
        call = ShowPanel,
    })
end
LuaEvents.AdditionalInformationDropdownGatherEntries.Add(EconOverhaul_Banking_AddInfoEntry)
LuaEvents.RequestRefreshAdditionalInformationDropdownEntries()

-- ============================================================
-- Hide context at load (Lord Mayors style)
-- ============================================================
ContextPtr:SetHide(true)

print("Economy Overhaul - Banking: BankingPanel.lua loaded.")
