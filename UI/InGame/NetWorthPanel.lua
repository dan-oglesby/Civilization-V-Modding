-- ============================================================
-- Economy Overhaul - Net Worth: NetWorthPanel.lua
-- Ranked economic scoreboard. Opens from the Additional Information
-- dropdown (top-right), Lord Mayors show/hide pattern.
--
-- Computes net worth live from shared MapModData (each addin runs in
-- its own Lua context, so the panel can't call NetWorth.lua's
-- functions — it reads the same state instead). All reads nil-safe.
-- ============================================================

include("InstanceManager")
include("EcoCurrency")   -- gold/silver/copper money layer: EcoFormatMoney, EcoGetWealthCopper, ECO_COPPER_PER_GOLD

local g_rowIM = InstanceManager:new("RankRowInstance", "RowRoot", Controls.RankRowStack)

-- ============================================================
-- Component readers (nil-safe; mirror NetWorth.lua)
-- ============================================================

local function StockValue(iPlayer)
    local owned  = MapModData.EcoOverhaul_StockOwned and MapModData.EcoOverhaul_StockOwned[iPlayer]
    local prices = MapModData.EcoOverhaul_StockPrices
    if owned == nil or prices == nil then return 0 end
    local v = 0
    for key, units in pairs(owned) do v = v + (units or 0) * (prices[key] or 0) end
    return v
end

local function BondValue(iPlayer)
    local held   = MapModData.EcoOverhaul_BondHoldings and MapModData.EcoOverhaul_BondHoldings[iPlayer]
    local prices = MapModData.EcoOverhaul_BondPrice
    if held == nil or prices == nil then return 0 end
    local v = 0
    for iIssuer, units in pairs(held) do v = v + (units or 0) * (prices[iIssuer] or 0) end
    return v
end

local function DebtValue(iPlayer)
    return (MapModData.EcoOverhaul_Debt and MapModData.EcoOverhaul_Debt[iPlayer]) or 0
end

-- All five returned in COPPER (mirrors NetWorth.lua) — stock prices are copper.
local function Components(iPlayer)
    local pPlayer = Players[iPlayer]
    if pPlayer == nil then return 0, 0, 0, 0, 0 end
    local gold   = EcoGetWealthCopper(pPlayer)                  -- copper (treasury + purse)
    local stocks = StockValue(iPlayer)                          -- copper (prices are copper)
    local bonds  = BondValue(iPlayer) * ECO_COPPER_PER_GOLD     -- bond prices are gold -> copper
    local debt   = DebtValue(iPlayer) * ECO_COPPER_PER_GOLD     -- debt is gold -> copper
    return gold, stocks, bonds, debt, (gold + stocks + bonds - debt)
end

-- ============================================================
-- Refresh
-- ============================================================

local function RefreshPanel()
    g_rowIM:ResetInstances()
    local iPlayer = Game.GetActivePlayer()
    local pPlayer = Players[iPlayer]
    if pPlayer == nil then return end
    local myTeam = pPlayer:GetTeam()

    -- Self breakdown (all values copper -> formatted g/s/c)
    local gold, stocks, bonds, debt, nw = Components(iPlayer)
    Controls.BreakdownLabel:SetText(
        "Your net worth: [COLOR_POSITIVE_TEXT]" .. EcoFormatMoney(nw) .. "[ENDCOLOR][NEWLINE]"
        .. "Gold " .. EcoFormatMoney(gold) .. "  +  Stocks " .. EcoFormatMoney(stocks)
        .. "  +  Bonds " .. EcoFormatMoney(bonds) .. "  -  Debt " .. EcoFormatMoney(debt))

    -- Collect self + met majors
    local list = {}
    for iP = 0, GameDefines.MAX_MAJOR_CIVS - 1 do
        local p = Players[iP]
        if p ~= nil and p:IsAlive() and not p:IsMinorCiv() and not p:IsBarbarian() then
            if iP == iPlayer or Teams[myTeam]:IsHasMet(p:GetTeam()) then
                local _, _, _, _, pnw = Components(iP)
                table.insert(list, { id = iP, nw = pnw, name = p:GetCivilizationShortDescription() })
            end
        end
    end
    table.sort(list, function(a, b) return a.nw > b.nw end)

    for rank, e in ipairs(list) do
        local row = g_rowIM:GetInstance()
        row.RankNum:SetText(tostring(rank))
        local nameStr = (e.id == iPlayer) and ("[COLOR_POSITIVE_TEXT]" .. e.name .. " (you)[ENDCOLOR]") or e.name
        row.RankCiv:SetText(nameStr)
        local nwStr = (e.nw >= 0)
            and EcoFormatMoney(e.nw)
            or ("[COLOR_WARNING_TEXT]" .. EcoFormatMoney(e.nw) .. "[ENDCOLOR]")
        row.RankNW:SetText(nwStr)
    end

    -- Required for InstanceManager rows to lay out and become visible/scrollable.
    Controls.RankRowStack:CalculateSize()
    Controls.RankRowStack:ReprocessAnchoring()
    Controls.RankScroll:CalculateInternalSize()
end

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

function EconOverhaul_NetWorth_AddInfoEntry(additionalEntries)
    table.insert(additionalEntries, { text = "Economic Standing", call = ShowPanel })
end
LuaEvents.AdditionalInformationDropdownGatherEntries.Add(EconOverhaul_NetWorth_AddInfoEntry)
LuaEvents.RequestRefreshAdditionalInformationDropdownEntries()

ContextPtr:SetHide(true)
print("Economy Overhaul - Net Worth: NetWorthPanel.lua loaded.")
