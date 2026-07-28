-- ============================================================
-- Economy Overhaul - Banking: BankingPanel.lua
--
-- Standalone "National Treasury" panel: read the floating savings
-- rate, your treasury's interest, and the state of the world capital
-- market. Opens from the Additional Information dropdown (top-right),
-- Lord Mayors pattern.
--
-- The rate engine and interest accrual live in Banking.lua; this panel
-- is purely its front-end and shares state through MapModData.
--
-- NOTE: national loans / sovereign debt were removed from the mod, so
-- this panel is savings-side only — there is nothing to borrow here.
-- ============================================================

include("EcoCurrency")   -- gold/silver/copper + empire-currency money layer: EcoFormatGold, EcoFormatMoney

local BOND_EXCHANGE_BONUS = 0.005   -- mirrors Banking.lua (display only)

-- ============================================================
-- Helpers
-- ============================================================

local function HasBondExchange(pPlayer)
    local iBldg = GameInfoTypes["BUILDING_BOND_EXCHANGE"]
    if iBldg == nil then return false end
    for pCity in pPlayer:Cities() do
        if pCity:GetNumBuilding(iBldg) > 0 then return true end
    end
    return false
end

-- ============================================================
-- Panel refresh
-- ============================================================

local function RefreshPanel()
    local iPlayerID = Game.GetActivePlayer()
    local pPlayer   = Players[iPlayerID]
    if pPlayer == nil then return end

    local savingsRate  = MapModData.EcoOverhaul_SavingsRate or 0
    local totalSavings = MapModData.EcoOverhaul_TotalSavings or 0
    local corpDebt     = MapModData.EcoOverhaul_CorpDebt     or 0
    local borrowedPct  = MapModData.EcoOverhaul_BorrowedPct  or 0
    local hasExchange  = HasBondExchange(pPlayer)
    local effRate      = savingsRate + (hasExchange and BOND_EXCHANGE_BONUS or 0)

    -- CAPITAL MARKET
    if savingsRate > 0 then
        Controls.RatesLabel:SetText(string.format(
            "Global savings rate: [COLOR_POSITIVE_TEXT]%.1f%%/turn[ENDCOLOR]%s[NEWLINE]World capital: %s   Corporate borrowing: %s (%d%% of all capital)",
            savingsRate * 100,
            hasExchange and string.format("   Your rate: [COLOR_POSITIVE_TEXT]%.1f%%/turn[ENDCOLOR] (Bond Exchange)", effRate * 100) or "",
            EcoFormatGold(totalSavings), EcoFormatGold(corpDebt), borrowedPct))
    else
        Controls.RatesLabel:SetText("Discover Banking to start earning treasury interest.")
    end

    -- YOUR TREASURY
    local interest = (MapModData.EcoOverhaul_InterestEarned and MapModData.EcoOverhaul_InterestEarned[iPlayerID]) or 0
    local pooled   = (MapModData.EcoOverhaul_IndexPool and MapModData.EcoOverhaul_IndexPool[iPlayerID]) or 0
    local treasury = EcoGetWealthCopper(pPlayer)

    local interestLine
    if interest > 0 then
        interestLine = "Interest this turn: [COLOR_POSITIVE_TEXT]+" .. EcoFormatMoney(interest) .. "[ENDCOLOR]"
    elseif pooled > 0 then
        interestLine = "Interest this turn: [COLOR:170:170:170:255]routed to your index fund[ENDCOLOR]"
    else
        interestLine = "Interest this turn: none yet"
    end
    Controls.TreasuryLabel:SetText("Treasury: [COLOR_POSITIVE_TEXT]" .. EcoFormatMoney(treasury) .. "[ENDCOLOR]   "
        .. interestLine
        .. ((pooled > 0) and ("[NEWLINE]Index fund pool: " .. EcoFormatMoney(pooled)) or ""))

    -- HOW RATES MOVE
    Controls.RateInfoLabel:SetText(
        "Your treasury earns interest automatically every turn. The rate floats between "
        .. "[COLOR_POSITIVE_TEXT]0.5%[ENDCOLOR] and [COLOR_POSITIVE_TEXT]6%[ENDCOLOR] with corporate "
        .. "borrowing demand, which rises in a boom and falls in a downturn — so a hot economy pays "
        .. "savers more. Build the [COLOR_POSITIVE_TEXT]Bond Exchange[ENDCOLOR] national wonder for an "
        .. "extra [COLOR_POSITIVE_TEXT]0.5%[ENDCOLOR] on top.")
end

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
