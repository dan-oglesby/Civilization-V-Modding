-- ============================================================
-- Economy Overhaul - Commodity Market: CommodityMarketPanel.lua
--
-- Opens from the "Additional Information" dropdown (top-right).
-- Set how many units of each resource to SELL on the market with the
-- - / + steppers (increments of 1). Selling is a recurring export:
-- each turn the committed units are tied up and you earn their market
-- value. The logic (CommodityMarket.lua) does the per-turn work; this
-- panel only edits the per-resource sell quantity in MapModData.
-- ============================================================

include("InstanceManager")
include("EcoCurrency")   -- gold/silver/copper money layer: EcoFormatMoney, ECO_COPPER_PER_GOLD

local g_rowIM = InstanceManager:new("MarketRowInstance", "RowRoot", Controls.MarketRowStack)

local STRATEGIC        = ResourceUsageTypes.RESOURCEUSAGE_STRATEGIC
local LUXURY           = ResourceUsageTypes.RESOURCEUSAGE_LUXURY
local EXCHANGE_PREMIUM = 0.25
local IMPORT_CAP       = 10   -- #1: max units/turn a player may IMPORT per resource (must match CommodityMarket.lua)
local CORP_SHARE_PREFIX = "^RESOURCE_CORP_"

local RefreshPanel  -- forward declaration

-- ============================================================
-- Helpers
-- ============================================================

local function PlayerKnowsResource(pPlayer, resourceInfo)
    if resourceInfo.TechReveal == nil or resourceInfo.TechReveal == "" then return true end
    local iTech = GameInfoTypes[resourceInfo.TechReveal]
    if iTech == nil then return true end
    return Teams[pPlayer:GetTeam()]:GetTeamTechs():HasTech(iTech)
end

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

local function TrendStr(iRes)
    local cur  = (MapModData.EcoOverhaul_CmdPrices    or {})[iRes] or 0
    local prev = (MapModData.EcoOverhaul_CmdPrevPrices or {})[iRes] or 0
    if cur > prev + 1 then return "[COLOR_POSITIVE_TEXT]▲[ENDCOLOR]"
    elseif cur < prev - 1 then return "[COLOR_WARNING_TEXT]▼[ENDCOLOR]"
    else return "[COLOR:200:200:200:255]─[ENDCOLOR]" end
end

local function GetSelling(iPlayer, iRes)
    local t = MapModData.EcoOverhaul_CmdSelling and MapModData.EcoOverhaul_CmdSelling[iPlayer]
    return t and (t[iRes] or 0) or 0
end
local function SetSelling(iPlayer, iRes, qty)
    if MapModData.EcoOverhaul_CmdSelling == nil then MapModData.EcoOverhaul_CmdSelling = {} end
    if MapModData.EcoOverhaul_CmdSelling[iPlayer] == nil then MapModData.EcoOverhaul_CmdSelling[iPlayer] = {} end
    -- Signed: positive = export units/turn, negative = import units/turn (down to -IMPORT_CAP).
    MapModData.EcoOverhaul_CmdSelling[iPlayer][iRes] = math.max(-IMPORT_CAP, qty)
    -- Defensive write-back: reassign the sub-table so the change propagates to the
    -- logic (CommodityMarket.lua) context, which reads it each turn for income.
    MapModData.EcoOverhaul_CmdSelling[iPlayer] = MapModData.EcoOverhaul_CmdSelling[iPlayer]
    EcoSaveState()   -- persist now: a mid-turn save must not lose this order
end
local function GetTiedUp(iPlayer, iRes)
    local t = MapModData.EcoOverhaul_CmdTiedUp and MapModData.EcoOverhaul_CmdTiedUp[iPlayer]
    return t and (t[iRes] or 0) or 0
end
-- True own surplus (units you could sell), independent of what's already committed.
local function NaturalSurplus(pPlayer, iPlayer, iRes)
    return pPlayer:GetNumResourceAvailable(iRes, false) + GetTiedUp(iPlayer, iRes)
end

-- ============================================================
-- Stepper callbacks — Civ5 passes void1 (resource id) directly.
-- ============================================================

-- "+" raises the position: import one fewer, or (at/above 0) sell one more, up to maxSell.
function OnSellMore(iVoid1)
    local iP = Game.GetActivePlayer()
    local pPlayer = Players[iP]; if pPlayer == nil then return end
    local cap = math.max(0, NaturalSurplus(pPlayer, iP, iVoid1) - 1)   -- always keep 1 (export side)
    SetSelling(iP, iVoid1, math.min(GetSelling(iP, iVoid1) + 1, cap))
    RefreshPanel()
end
-- "-" lowers the position: sell one fewer, or (at/below 0) import one more, down to -IMPORT_CAP.
function OnSellLess(iVoid1)
    local iP = Game.GetActivePlayer()
    SetSelling(iP, iVoid1, math.max(GetSelling(iP, iVoid1) - 1, -IMPORT_CAP))
    RefreshPanel()
end

-- ============================================================
-- Panel refresh
-- ============================================================

RefreshPanel = function()
    g_rowIM:ResetInstances()
    local iPlayerID = Game.GetActivePlayer()
    local pPlayer   = Players[iPlayerID]
    if pPlayer == nil then return end
    local autoSell  = (MapModData.EcoOverhaul_AutoSell ~= nil) and (MapModData.EcoOverhaul_AutoSell[iPlayerID] == true)
    local autoBuy   = (MapModData.EcoOverhaul_AutoBuy  ~= nil) and (MapModData.EcoOverhaul_AutoBuy[iPlayerID]  == true)
    local hasCE     = HasCommodityExchange(pPlayer)

    -- Exchange owner line (who founded the market + skims the cut), then the optional rate line.
    local cmdOwner = MapModData.EcoOverhaul_CmdExchangeOwner or -1
    local ownerLine = ""
    if cmdOwner >= 0 then
        local who = (cmdOwner == iPlayerID) and "[COLOR_POSITIVE_TEXT]You[ENDCOLOR]"
            or (Players[cmdOwner] and Players[cmdOwner]:GetCivilizationShortDescription() or "?")
        ownerLine = "Exchange: " .. who .. " (skims 2% of volume"
        if cmdOwner == iPlayerID then ownerLine = ownerLine .. " — +" .. EcoFormatMoney(MapModData.EcoOverhaul_CmdExchangeCut or 0) .. " last turn" end
        ownerLine = ownerLine .. ").   "
    end
    if MapModData.EcoOverhaul_SavingsRate ~= nil then
        Controls.RateSummaryLabel:SetText(string.format(
            "%sSavings rate: [COLOR_POSITIVE_TEXT]%.1f%%[ENDCOLOR]/turn",
            ownerLine, (MapModData.EcoOverhaul_SavingsRate or 0) * 100))
    else
        Controls.RateSummaryLabel:SetText(ownerLine .. "Sell surplus [ICON_PRODUCTION] strategic / [ICON_HAPPINESS_1] luxury resources for recurring income, or import what you lack.")
    end

    if EcoWonderOwner("BUILDING_COMMODITY_EXCHANGE") == nil then
        local row = g_rowIM:GetInstance()
        row.ResName:SetText("[COLOR:180:180:180:255]No Commodity Exchange has been built yet.[/COLOR]")
        row.ResPrice:SetText("") row.ResTrend:SetText("") row.ResHave:SetText("") row.ResSelling:SetText("") row.ResIncome:SetText("")
        row.MinusBtn:SetHide(true) row.PlusBtn:SetHide(true)
        Controls.FooterLabel:SetText("The commodity market opens once any civilization builds the [COLOR_POSITIVE_TEXT]Commodity Exchange[ENDCOLOR] world wonder (requires Economics).")
        Controls.MarketRowStack:CalculateSize(); Controls.MarketRowStack:ReprocessAnchoring(); Controls.MarketScroll:CalculateInternalSize()
        return
    end

    -- Gather tradeable, known, priced resources (skip Corp shares).
    local strategics, luxuries = {}, {}
    for resource in GameInfo.Resources() do
        local iRes  = resource.ID
        local uType = Game.GetResourceUsageType(iRes)
        local exempt = resource.Type ~= nil and resource.Type:find(CORP_SHARE_PREFIX) ~= nil
        if (uType == STRATEGIC or uType == LUXURY) and not exempt and PlayerKnowsResource(pPlayer, resource)
        and (MapModData.EcoOverhaul_CmdPrices or {})[iRes] ~= nil then
            local entry = {
                id = iRes, name = Locale.ConvertTextKey(resource.Description), uType = uType,
                price   = (MapModData.EcoOverhaul_CmdPrices  or {})[iRes] or 0,
                supply  = (MapModData.EcoOverhaul_CmdSupply  or {})[iRes] or 0,
                demand  = (MapModData.EcoOverhaul_CmdDemand  or {})[iRes] or 0,
                natural = NaturalSurplus(pPlayer, iPlayerID, iRes),
            }
            if uType == STRATEGIC then table.insert(strategics, entry) else table.insert(luxuries, entry) end
        end
    end
    table.sort(strategics, function(a, b) return a.price > b.price end)
    table.sort(luxuries,   function(a, b) return a.price > b.price end)

    local totalIncome = 0

    local function AddHeader(text)
        local row = g_rowIM:GetInstance()
        row.ResName:SetText("[COLOR:150:200:255:255]" .. text .. "[/COLOR]")
        row.ResPrice:SetText("") row.ResTrend:SetText("") row.ResHave:SetText("") row.ResSelling:SetText("") row.ResIncome:SetText("")
        row.MinusBtn:SetHide(true) row.PlusBtn:SetHide(true)
    end

    local function AddRow(e)
        local row = g_rowIM:GetInstance()
        local isLuxury = (e.uType == LUXURY)
        -- Always keep 1 of each resource on the export side (production / happiness).
        local maxSell  = math.max(0, e.natural - 1)
        -- Signed position: + export, - import. Auto-sell exports surplus; Auto-Buy tops up
        -- lacked resources to 1 (manual buys can still go deeper).
        local q
        if autoSell and maxSell > 0 then
            q = maxSell
        else
            q = math.max(-IMPORT_CAP, math.min(GetSelling(iPlayerID, e.id), maxSell))
            if autoBuy and maxSell <= 0 then
                local target = e.natural - 1
                if target < 0 then q = math.max(-IMPORT_CAP, math.min(q, target)) end
            end
        end

        -- Per-unit prices in COPPER: exports earn the Exchange +25%; imports pay base market.
        local baseCopper   = e.price * ECO_COPPER_PER_GOLD
        local exportCopper = hasCE and math.floor(baseCopper * (1 + EXCHANGE_PREMIUM)) or baseCopper
        local cash = (q >= 0) and (exportCopper * q) or (baseCopper * q)   -- signed copper
        totalIncome = totalIncome + cash

        local nameStr
        if q > 0 then nameStr = "[COLOR_POSITIVE_TEXT]" .. e.name .. "[ENDCOLOR]"
        elseif q < 0 then nameStr = "[COLOR:120:200:255:255]" .. e.name .. "[ENDCOLOR]"
        else nameStr = e.name end
        row.ResName:SetText(nameStr)
        row.ResName:SetToolTipString(e.name .. "  Supply: " .. e.supply .. "  Demand: " .. e.demand
            .. "  Market price: " .. EcoFormatGold(e.price) .. "/unit")
        row.ResPrice:SetText(EcoFormatGoldShort(e.price))
        row.ResPrice:SetToolTipString(hasCE and "Exports earn +25% (Commodity Exchange); imports pay the base price." or "Market price per unit, per turn.")
        row.ResTrend:SetText(TrendStr(e.id))
        row.ResHave:SetText(tostring(e.natural))

        local qStr
        if q > 0 then qStr = "[COLOR_POSITIVE_TEXT]+" .. q .. "[ENDCOLOR]"
        elseif q < 0 then qStr = "[COLOR:120:200:255:255]" .. q .. "[ENDCOLOR]"
        else qStr = "0" end
        row.ResSelling:SetText(qStr)

        if q > 0 then
            row.ResIncome:SetText("[COLOR_POSITIVE_TEXT]+" .. EcoFormatMoney(cash) .. "[ENDCOLOR]")
        elseif q < 0 then
            row.ResIncome:SetText("[COLOR_WARNING_TEXT]" .. EcoFormatMoney(cash) .. "[ENDCOLOR]")
        else
            row.ResIncome:SetText("[COLOR:160:160:160:255]—[ENDCOLOR]")
        end

        row.MinusBtn:SetHide(false); row.PlusBtn:SetHide(false)
        row.MinusBtn:SetVoids(e.id, 0); row.MinusBtn:RegisterCallback(Mouse.eLClick, OnSellLess)
        row.PlusBtn:SetVoids(e.id, 0);  row.PlusBtn:RegisterCallback(Mouse.eLClick, OnSellMore)
        if autoSell then
            row.MinusBtn:SetDisabled(true); row.PlusBtn:SetDisabled(true)
            row.MinusBtn:SetToolTipString("Turn off Sell All Surplus to set amounts manually.")
            row.PlusBtn:SetToolTipString("Turn off Sell All Surplus to set amounts manually.")
        else
            local E = math.max(-IMPORT_CAP, math.min(GetSelling(iPlayerID, e.id), maxSell))
            row.MinusBtn:SetDisabled(E <= -IMPORT_CAP)
            row.PlusBtn:SetDisabled(E >= maxSell)
            row.MinusBtn:SetToolTipString("Lower " .. e.name .. ": sell one fewer, or import one more (pay gold/turn to receive it, down to " .. IMPORT_CAP .. "/turn).")
            row.PlusBtn:SetToolTipString("Raise " .. e.name .. ": import one fewer, or sell one more. You always keep 1"
                .. (isLuxury and " for its happiness." or " so you can still build units."))
        end
    end

    if #strategics > 0 then AddHeader("Strategic Resources"); for _, e in ipairs(strategics) do AddRow(e) end end
    if #luxuries   > 0 then AddHeader("Luxury Resources");    for _, e in ipairs(luxuries)   do AddRow(e) end end
    if #strategics == 0 and #luxuries == 0 then
        local row = g_rowIM:GetInstance()
        row.ResName:SetText("[COLOR:180:180:180:255]No resources with market prices yet.[/COLOR]")
        row.ResPrice:SetText("") row.ResTrend:SetText("") row.ResHave:SetText("") row.ResSelling:SetText("") row.ResIncome:SetText("")
        row.MinusBtn:SetHide(true) row.PlusBtn:SetHide(true)
    end

    local ceStr = hasCE and "  (exports incl. +25%)" or ""
    if autoSell then
        Controls.FooterLabel:SetText("[COLOR_POSITIVE_TEXT]Sell All Surplus ON[ENDCOLOR] — exporting every surplus each turn for [COLOR_POSITIVE_TEXT]+" .. EcoFormatMoney(totalIncome) .. "[ENDCOLOR]/turn" .. ceStr .. ".")
    else
        local netStr = (totalIncome >= 0)
            and ("[COLOR_POSITIVE_TEXT]+" .. EcoFormatMoney(totalIncome) .. "[ENDCOLOR]")
            or  ("[COLOR_WARNING_TEXT]" .. EcoFormatMoney(totalIncome) .. "[ENDCOLOR]")
        Controls.FooterLabel:SetText("Net commodity flow: " .. netStr .. "/turn" .. ceStr
            .. ".  [COLOR_POSITIVE_TEXT]+[ENDCOLOR] sells surplus, [COLOR:120:200:255:255]-[ENDCOLOR] imports what you lack; positions hold until you change them.")
    end

    Controls.MarketRowStack:CalculateSize()
    Controls.MarketRowStack:ReprocessAnchoring()
    Controls.MarketScroll:CalculateInternalSize()
end

-- ============================================================
-- "Sell All Surplus" toggle
-- ============================================================

local function IsAutoSellOn()
    return (MapModData.EcoOverhaul_AutoSell ~= nil) and (MapModData.EcoOverhaul_AutoSell[Game.GetActivePlayer()] == true)
end
local function UpdateAutoSellButton()
    if IsAutoSellOn() then Controls.AutoSellBtnLabel:SetText("[COLOR_POSITIVE_TEXT]Sell All Surplus: ON[ENDCOLOR]")
    else Controls.AutoSellBtnLabel:SetText("[COLOR:180:180:180:255]Sell All Surplus: OFF[/COLOR]") end
end
Controls.AutoSellToggleBtn:RegisterCallback(Mouse.eLClick, function()
    local iPlayer = Game.GetActivePlayer()
    MapModData.EcoOverhaul_AutoSell = MapModData.EcoOverhaul_AutoSell or {}
    MapModData.EcoOverhaul_AutoSell[iPlayer] = not (MapModData.EcoOverhaul_AutoSell[iPlayer] == true)
    EcoSaveState()
    UpdateAutoSellButton(); RefreshPanel()
end)

local function IsAutoBuyOn()
    return (MapModData.EcoOverhaul_AutoBuy ~= nil) and (MapModData.EcoOverhaul_AutoBuy[Game.GetActivePlayer()] == true)
end
local function UpdateAutoBuyButton()
    if IsAutoBuyOn() then Controls.AutoBuyBtnLabel:SetText("[COLOR_POSITIVE_TEXT]Auto-Buy to 1: ON[ENDCOLOR]")
    else Controls.AutoBuyBtnLabel:SetText("[COLOR:180:180:180:255]Auto-Buy to 1: OFF[/COLOR]") end
end
Controls.AutoBuyToggleBtn:RegisterCallback(Mouse.eLClick, function()
    local iPlayer = Game.GetActivePlayer()
    MapModData.EcoOverhaul_AutoBuy = MapModData.EcoOverhaul_AutoBuy or {}
    MapModData.EcoOverhaul_AutoBuy[iPlayer] = not (MapModData.EcoOverhaul_AutoBuy[iPlayer] == true)
    EcoSaveState()
    UpdateAutoBuyButton(); RefreshPanel()
end)

-- ============================================================
-- Show / Hide — via ContextPtr (Lord Mayors pattern)
-- ============================================================

local function ShowPanel()
    if Players[Game.GetActivePlayer()] == nil then return end
    UpdateAutoSellButton()
    UpdateAutoBuyButton()
    RefreshPanel()
    ContextPtr:SetHide(false)
end
local function HidePanel()
    ContextPtr:SetHide(true)
end
Controls.CloseMarketBtn:RegisterCallback(Mouse.eLClick, HidePanel)

Events.ActivePlayerTurnStart.Add(function()
    if not ContextPtr:IsHidden() then UpdateAutoSellButton(); UpdateAutoBuyButton(); RefreshPanel() end
end)
Events.SerialEventGameDataDirty.Add(function()
    if not ContextPtr:IsHidden() then RefreshPanel() end
end)

-- ============================================================
-- Register with Additional Information dropdown (BNW standard)
-- ============================================================

function EconOverhaul_CommodityMarket_AddInfoEntry(additionalEntries)
    table.insert(additionalEntries, { text = "Commodity Market", call = ShowPanel })
end
LuaEvents.AdditionalInformationDropdownGatherEntries.Add(EconOverhaul_CommodityMarket_AddInfoEntry)
LuaEvents.RequestRefreshAdditionalInformationDropdownEntries()

ContextPtr:SetHide(true)
print("Economy Overhaul - Commodity Market: CommodityMarketPanel.lua loaded.")
