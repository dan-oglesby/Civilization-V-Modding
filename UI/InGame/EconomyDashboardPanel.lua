-- ============================================================
-- Economy Overhaul - Economy Overview dashboard
-- A read-only, at-a-glance summary of every Economy Overhaul
-- subsystem for the active player. Opens from the Additional
-- Information dropdown (top-right). Reads the shared MapModData the
-- other modules publish each turn — no game state is changed here.
-- ============================================================

include("EcoCurrency")   -- EcoFormatMoney, EcoFormatGold, EcoGetWealthCopper, ECO_COPPER_PER_GOLD

local function modPT(tbl, iPlayer) return (tbl ~= nil and tbl[iPlayer]) or 0 end

local function StockPortfolioCopper(iPlayer)
    local owned  = MapModData.EcoOverhaul_StockOwned and MapModData.EcoOverhaul_StockOwned[iPlayer]
    local prices = MapModData.EcoOverhaul_StockPrices
    if not owned or not prices then return 0 end
    local v = 0
    for k, u in pairs(owned) do v = v + (u or 0) * (prices[k] or 0) end
    return v
end

local function BondPortfolioCopper(iPlayer)
    local held   = MapModData.EcoOverhaul_BondHoldings and MapModData.EcoOverhaul_BondHoldings[iPlayer]
    local prices = MapModData.EcoOverhaul_BondPrice
    if not held or not prices then return 0 end
    local v = 0
    for iss, u in pairs(held) do v = v + (u or 0) * (prices[iss] or 0) end
    return v * ECO_COPPER_PER_GOLD   -- bond prices are whole gold
end

-- Compact, name-less "+G.cc" used only in the income breakdown line.
local function cf(copper)
    local n = math.floor((copper or 0) + 0.5)
    local sign = (n >= 0) and "+" or "-"
    n = math.abs(n)
    return sign .. string.format("%d.%02d", math.floor(n / 100), n % 100)
end

local function RefreshDashboard()
    local iPlayer = Game.GetActivePlayer()
    local pPlayer = Players[iPlayer]
    if pPlayer == nil then return end

    -- TREASURY & INCOME
    Controls.TreasuryLabel:SetText("Treasury:  [COLOR_POSITIVE_TEXT]" .. EcoFormatMoney(EcoGetWealthCopper(pPlayer)) .. "[ENDCOLOR]")

    local interest = modPT(MapModData.EcoOverhaul_InterestEarned, iPlayer)
    local commod   = modPT(MapModData.EcoOverhaul_CmdSaleIncome,  iPlayer)
    local divs     = modPT(MapModData.EcoOverhaul_StockDivEarned, iPlayer)
    local bondInc  = modPT(MapModData.EcoOverhaul_BondIncome,     iPlayer)
    local tax      = modPT(MapModData.EcoOverhaul_TaxRevenue,     iPlayer)
    local baseGold = pPlayer:CalculateGoldRate() * ECO_COPPER_PER_GOLD
    local total    = baseGold + interest + commod + divs + bondInc + tax
    Controls.IncomeLabel:SetText("Net income / turn:  [COLOR_POSITIVE_TEXT]" .. ((total >= 0) and "+" or "") .. EcoFormatMoney(total) .. "[ENDCOLOR]")
    Controls.IncomeBreakdownLabel:SetText("[COLOR:170:170:170:255]base " .. cf(baseGold)
        .. "   interest " .. cf(interest) .. "   trade " .. cf(commod) .. "   dividends " .. cf(divs)
        .. "   bonds " .. cf(bondInc) .. "   tax " .. cf(tax) .. "[ENDCOLOR]")

    -- BANKING
    local sr = MapModData.EcoOverhaul_SavingsRate or 0
    local dr = MapModData.EcoOverhaul_DebtRate    or 0
    Controls.RatesLabel:SetText(string.format("Savings rate: [COLOR_POSITIVE_TEXT]%.1f%%[ENDCOLOR]   Debt rate: [COLOR_WARNING_TEXT]%.1f%%[ENDCOLOR]/turn", sr * 100, dr * 100))
    local debt = (MapModData.EcoOverhaul_Debt or {})[iPlayer] or 0
    if debt > 0 then
        Controls.DebtLabel:SetText("Outstanding debt:  [COLOR_WARNING_TEXT]" .. EcoFormatGold(debt) .. "[ENDCOLOR]")
    else
        Controls.DebtLabel:SetText("Outstanding debt:  [COLOR:170:170:170:255]none[ENDCOLOR]")
    end

    -- MARKETS
    Controls.StockLabel:SetText("Stock portfolio:  " .. EcoFormatMoney(StockPortfolioCopper(iPlayer)))
    Controls.BondLabel:SetText("Foreign bonds held:  " .. EcoFormatMoney(BondPortfolioCopper(iPlayer)))
    Controls.IndexPoolLabel:SetText("Index pool:  " .. EcoFormatMoney((MapModData.EcoOverhaul_IndexPool or {})[iPlayer] or 0))
    local taxRate = (MapModData.EcoOverhaul_TaxRate or {})[iPlayer] or 0
    Controls.TaxLabel:SetText(string.format("Tax rate:  %d%%", math.floor(taxRate * 100 + 0.5)))

    -- ECONOMIC STANDING
    local nwTable = MapModData.EcoOverhaul_NetWorth or {}
    local myNW = nwTable[iPlayer] or 0
    Controls.NetWorthLabel:SetText("Net worth:  [COLOR_POSITIVE_TEXT]" .. EcoFormatMoney(myNW) .. "[ENDCOLOR]")
    local rank, count = 1, 0
    for iP, nw in pairs(nwTable) do
        count = count + 1
        if iP ~= iPlayer and nw > myNW then rank = rank + 1 end
    end
    Controls.RankLabel:SetText(string.format("Economic rank:  #%d of %d", rank, math.max(rank, count)))
    Controls.CycleLabel:SetText("Business cycle:  " .. (MapModData.EcoOverhaul_ClimateLabel or "Stable"))

    Controls.DashStack:CalculateSize()
    Controls.DashStack:ReprocessAnchoring()
    Controls.DashScroll:CalculateInternalSize()
end

local function ShowPanel()
    RefreshDashboard()
    ContextPtr:SetHide(false)
end
local function HidePanel()
    ContextPtr:SetHide(true)
end
Controls.ClosePanelBtn:RegisterCallback(Mouse.eLClick, HidePanel)

Events.ActivePlayerTurnStart.Add(function()
    if not ContextPtr:IsHidden() then RefreshDashboard() end
end)
Events.SerialEventGameDataDirty.Add(function()
    if not ContextPtr:IsHidden() then RefreshDashboard() end
end)

function EconOverhaul_Dashboard_AddInfoEntry(additionalEntries)
    table.insert(additionalEntries, { text = "Economy Overview", call = ShowPanel })
end
LuaEvents.AdditionalInformationDropdownGatherEntries.Add(EconOverhaul_Dashboard_AddInfoEntry)
LuaEvents.RequestRefreshAdditionalInformationDropdownEntries()

ContextPtr:SetHide(true)
print("Economy Overhaul - Economy Overview dashboard loaded.")
