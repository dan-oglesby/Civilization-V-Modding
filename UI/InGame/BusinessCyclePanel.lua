-- ============================================================
-- Economy Overhaul - Business Cycle: BusinessCyclePanel.lua
-- Read-only "Economic Climate" readout. Opens from the Additional
-- Information dropdown (top-right), Lord Mayors show/hide pattern.
-- ============================================================

local function ColoredPhase(label)
    if label == "Boom" or label == "Expansion" then
        return "[COLOR_POSITIVE_TEXT]" .. label .. "[ENDCOLOR]"
    elseif label == "Recession" or label == "Slowdown" then
        return "[COLOR_WARNING_TEXT]" .. label .. "[ENDCOLOR]"
    end
    return label
end

local function RefreshPanel()
    local climate = MapModData.EcoOverhaul_Climate or 1.0
    local label   = MapModData.EcoOverhaul_ClimateLabel or "Stable"
    local prev    = MapModData.EcoOverhaul_ClimatePrevLabel or label

    Controls.PhaseLabel:SetText(ColoredPhase(label))

    local pct = math.floor((climate - 1.0) * 100 + 0.5)
    local arrow = ""
    if label ~= prev then
        arrow = (climate >= 1.0) and "  [COLOR_POSITIVE_TEXT]▲[ENDCOLOR]" or "  [COLOR_WARNING_TEXT]▼[ENDCOLOR]"
    end
    local sign = (pct >= 0) and "+" or ""
    Controls.IndexLabel:SetText(string.format("Activity index: %s%d%% vs. normal%s", sign, pct, arrow))

    local effect = string.format(
        "Every civilization's gold income is currently [COLOR%s_TEXT]%s%d%%[ENDCOLOR] of normal.[NEWLINE][NEWLINE]"
            .. "The climate drifts through boom and recession over time, with occasional shocks. "
            .. "It also raises and lowers interest rates, commodity demand, stock values, and tax revenue across the economy.",
        (pct >= 0) and "_POSITIVE" or "_WARNING", sign, pct)
    Controls.EffectLabel:SetText(effect)
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

function EconOverhaul_BusinessCycle_AddInfoEntry(additionalEntries)
    table.insert(additionalEntries, { text = "Economic Climate", call = ShowPanel })
end
LuaEvents.AdditionalInformationDropdownGatherEntries.Add(EconOverhaul_BusinessCycle_AddInfoEntry)
LuaEvents.RequestRefreshAdditionalInformationDropdownEntries()

ContextPtr:SetHide(true)
print("Economy Overhaul - Business Cycle: BusinessCyclePanel.lua loaded.")
