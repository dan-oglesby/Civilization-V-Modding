-- ============================================================
-- Economy Overhaul - Taxation: TaxationPanel.lua
-- Set the national tax rate. Opens from the Additional Information
-- dropdown (top-right), Lord Mayors show/hide pattern.
-- Constants must stay in sync with Taxation.lua.
-- ============================================================

include("EcoCurrency")   -- gold/silver/copper money layer: EcoFormatMoney, ECO_COPPER_PER_GOLD

local TAX_STEP         = 0.05
local TAX_MAX          = 0.30
local UNHAPPY_PER_STEP = 1
local TAX_TECH         = "TECH_CURRENCY"

-- ============================================================
-- Helpers
-- ============================================================

local function HasCurrency(pPlayer)
    local pTeam = Teams[pPlayer:GetTeam()]
    if pTeam == nil then return false end
    local iTech = GameInfoTypes[TAX_TECH]
    return iTech ~= nil and pTeam:GetTeamTechs():HasTech(iTech)
end

local function GetGrossGoldIncome(pPlayer)
    local fromCities = pPlayer:GetGoldFromCitiesTimes100() / 100
    local fromTrade  = pPlayer:GetCityConnectionGoldTimes100() / 100
    local fromDiplo  = math.max(0, pPlayer:GetGoldPerTurnFromDiplomacy())
    return math.max(1, math.floor(fromCities + fromTrade + fromDiplo))
end

local function GetRate(iPlayer)
    return (MapModData.EcoOverhaul_TaxRate and MapModData.EcoOverhaul_TaxRate[iPlayer]) or 0
end

local function SetRate(iPlayer, rate)
    if MapModData.EcoOverhaul_TaxRate == nil then MapModData.EcoOverhaul_TaxRate = {} end
    MapModData.EcoOverhaul_TaxRate[iPlayer] = math.max(0, math.min(TAX_MAX, rate))
end

-- ============================================================
-- Refresh
-- ============================================================

local function RefreshPanel()
    local iPlayerID = Game.GetActivePlayer()
    local pPlayer   = Players[iPlayerID]
    if pPlayer == nil then return end

    local rate    = GetRate(iPlayerID)
    local hasTech = HasCurrency(pPlayer)

    Controls.IntroLabel:SetText("Set the share of your gross income collected as tax each turn. Higher taxes fund your treasury but breed [ICON_HAPPINESS_3] unhappiness.")
    Controls.RateLabel:SetText(string.format("%d%%", math.floor(rate * 100 + 0.5)))

    if not hasTech then
        Controls.RevenueLabel:SetText("[COLOR_WARNING_TEXT]Requires the Currency technology.[ENDCOLOR]")
        Controls.CostLabel:SetText("")
        Controls.RateDownBtn:SetDisabled(true)
        Controls.RateUpBtn:SetDisabled(true)
    else
        local climate = MapModData.EcoOverhaul_Climate or 1.0
        local revenue = math.floor(GetGrossGoldIncome(pPlayer) * ECO_COPPER_PER_GOLD * rate * climate)   -- copper (matches Taxation.lua)
        local unhappy = math.floor((rate / TAX_STEP) * UNHAPPY_PER_STEP + 0.0001)
        Controls.RevenueLabel:SetText(string.format("Projected revenue: [COLOR_POSITIVE_TEXT]+%s[ENDCOLOR]/turn", EcoFormatMoney(revenue)))
        if unhappy > 0 then
            Controls.CostLabel:SetText(string.format("Happiness cost: [COLOR_WARNING_TEXT]-%d [ICON_HAPPINESS_3][ENDCOLOR]", unhappy))
        else
            Controls.CostLabel:SetText("Happiness cost: none")
        end
        Controls.RateDownBtn:SetDisabled(rate <= 0)
        Controls.RateUpBtn:SetDisabled(rate >= TAX_MAX)
    end

    local climateNote = (MapModData.EcoOverhaul_Climate ~= nil)
        and "  The current economic climate is widening or narrowing your tax base." or ""
    Controls.NoteLabel:SetText("Changes take effect at the start of your next turn." .. climateNote)
end

-- ============================================================
-- Buttons
-- ============================================================

Controls.RateDownBtn:RegisterCallback(Mouse.eLClick, function()
    local iPlayer = Game.GetActivePlayer()
    SetRate(iPlayer, GetRate(iPlayer) - TAX_STEP); RefreshPanel()
end)
Controls.RateUpBtn:RegisterCallback(Mouse.eLClick, function()
    local iPlayer = Game.GetActivePlayer()
    SetRate(iPlayer, GetRate(iPlayer) + TAX_STEP); RefreshPanel()
end)

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

function EconOverhaul_Taxation_AddInfoEntry(additionalEntries)
    table.insert(additionalEntries, { text = "Fiscal Policy", call = ShowPanel })
end
LuaEvents.AdditionalInformationDropdownGatherEntries.Add(EconOverhaul_Taxation_AddInfoEntry)
LuaEvents.RequestRefreshAdditionalInformationDropdownEntries()

ContextPtr:SetHide(true)
print("Economy Overhaul - Taxation: TaxationPanel.lua loaded.")
