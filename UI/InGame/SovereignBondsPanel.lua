-- ============================================================
-- Economy Overhaul - Sovereign Bonds: SovereignBondsPanel.lua
-- Buy/sell other civilizations' bonds. Opens from the Additional
-- Information dropdown (top-right), Lord Mayors show/hide pattern.
-- Market pricing, coupons, and defaults live in SovereignBonds.lua;
-- this panel shares state through MapModData.
-- ============================================================

include("InstanceManager")
include("EcoCurrency")   -- gold/silver/copper money layer: EcoFormatMoney

local FACE_VALUE          = 100
local BOND_LOT            = 1     -- units per Buy/Sell click
local MAX_UNITS_PER_ISSUER = 20
local MAX_TOTAL_UNITS     = 60

local g_rowIM = InstanceManager:new("BondRowInstance", "RowRoot", Controls.BondRowStack)
local RefreshPanel  -- forward declaration

-- ============================================================
-- Helpers
-- ============================================================

local function GetHoldings(iHolder, iIssuer)
    local tbl = MapModData.EcoOverhaul_BondHoldings and MapModData.EcoOverhaul_BondHoldings[iHolder]
    return tbl and (tbl[iIssuer] or 0) or 0
end
local function SetHoldings(iHolder, iIssuer, units)
    if MapModData.EcoOverhaul_BondHoldings == nil then MapModData.EcoOverhaul_BondHoldings = {} end
    if MapModData.EcoOverhaul_BondHoldings[iHolder] == nil then MapModData.EcoOverhaul_BondHoldings[iHolder] = {} end
    MapModData.EcoOverhaul_BondHoldings[iHolder][iIssuer] = math.max(0, units)
    MapModData.EcoOverhaul_BondHoldings[iHolder] = MapModData.EcoOverhaul_BondHoldings[iHolder]
    EcoSaveState()   -- persist now: a mid-turn save must not lose this trade
end
local function GetPrice(iIssuer)
    return (MapModData.EcoOverhaul_BondPrice and MapModData.EcoOverhaul_BondPrice[iIssuer]) or FACE_VALUE
end
local function TotalUnits(iHolder)
    local tbl = MapModData.EcoOverhaul_BondHoldings and MapModData.EcoOverhaul_BondHoldings[iHolder]
    local n = 0
    if tbl then for _, u in pairs(tbl) do n = n + u end end
    return n
end

local function HasEconomics(pPlayer)
    local pTeam = Teams[pPlayer:GetTeam()]
    if pTeam == nil then return false end
    local iTech = GameInfoTypes["TECH_ECONOMICS"]
    return iTech ~= nil and pTeam:GetTeamTechs():HasTech(iTech)
end

local function RiskStr(distress)
    if distress < 0.25 then return "[COLOR_POSITIVE_TEXT]Low[ENDCOLOR]"
    elseif distress < 0.50 then return "[COLOR:230:230:120:255]Moderate[/COLOR]"
    elseif distress < 0.75 then return "[COLOR_WARNING_TEXT]High[ENDCOLOR]"
    else return "[COLOR_WARNING_TEXT]Severe[ENDCOLOR]" end
end

-- ============================================================
-- Buy / sell
-- ============================================================

local function BuyBond(iIssuer)
    local iPlayer = Game.GetActivePlayer()
    local pPlayer = Players[iPlayer]
    if pPlayer == nil then return end
    if not HasEconomics(pPlayer) then return end
    if GetHoldings(iPlayer, iIssuer) + BOND_LOT > MAX_UNITS_PER_ISSUER then return end
    if TotalUnits(iPlayer) + BOND_LOT > MAX_TOTAL_UNITS then return end
    local cost = GetPrice(iIssuer) * BOND_LOT
    if pPlayer:GetGold() < cost then return end
    pPlayer:ChangeGold(-cost)
    SetHoldings(iPlayer, iIssuer, GetHoldings(iPlayer, iIssuer) + BOND_LOT)
    RefreshPanel()
end

local function SellBond(iIssuer)
    local iPlayer = Game.GetActivePlayer()
    local pPlayer = Players[iPlayer]
    if pPlayer == nil then return end
    if GetHoldings(iPlayer, iIssuer) < BOND_LOT then return end
    pPlayer:ChangeGold(GetPrice(iIssuer) * BOND_LOT)
    SetHoldings(iPlayer, iIssuer, GetHoldings(iPlayer, iIssuer) - BOND_LOT)
    RefreshPanel()
end

-- Globals so RegisterCallback can resolve them at show time.
-- Civ5 passes the control's void1 (issuer player id, set via SetVoids) directly.
function OnBondBuyClicked(iVoid1)  BuyBond(iVoid1)  end
function OnBondSellClicked(iVoid1) SellBond(iVoid1) end

-- ============================================================
-- Refresh
-- ============================================================

RefreshPanel = function()
    g_rowIM:ResetInstances()
    local iPlayer = Game.GetActivePlayer()
    local pPlayer = Players[iPlayer]
    if pPlayer == nil then return end
    local myTeam = pPlayer:GetTeam()

    -- #4 Bond trading is gated on the Economics technology.
    if not HasEconomics(pPlayer) then
        Controls.SummaryLabel:SetText("[COLOR:180:180:180:255]Sovereign bond trading requires the Economics technology.[/COLOR]")
        Controls.FooterLabel:SetText("Research [COLOR_POSITIVE_TEXT]Economics[ENDCOLOR] to buy and sell other nations' bonds.")
        local row = g_rowIM:GetInstance()
        row.CivName:SetText("[COLOR:180:180:180:255]Economics not yet discovered.[/COLOR]")
        row.BondYield:SetText("") row.BondPrice:SetText("") row.BondRisk:SetText("") row.BondOwned:SetText("")
        row.BuyBtn:SetHide(true) row.SellBtn:SetHide(true)
        Controls.BondRowStack:CalculateSize()
        Controls.BondRowStack:ReprocessAnchoring()
        Controls.BondScroll:CalculateInternalSize()
        return
    end

    local income = (MapModData.EcoOverhaul_BondIncome and MapModData.EcoOverhaul_BondIncome[iPlayer]) or 0
    local total  = TotalUnits(iPlayer)
    Controls.SummaryLabel:SetText(string.format(
        "Foreign bond income last turn: [COLOR_POSITIVE_TEXT]+%s[ENDCOLOR]   Units held: %d / %d   (lots of %d, max %d per nation)",
        EcoFormatMoney(income), total, MAX_TOTAL_UNITS, BOND_LOT, MAX_UNITS_PER_ISSUER))

    Controls.FooterLabel:SetText("Distressed nations pay more but can default; yields and prices track each nation's sovereign debt and fiscal health.")

    local any = false
    for iIssuer = 0, GameDefines.MAX_MAJOR_CIVS - 1 do
        local pIssuer = Players[iIssuer]
        if pIssuer ~= nil and iIssuer ~= iPlayer and pIssuer:IsAlive()
        and not pIssuer:IsMinorCiv() and not pIssuer:IsBarbarian()
        and Teams[myTeam]:IsHasMet(pIssuer:GetTeam())
        and (MapModData.EcoOverhaul_BondPrice and MapModData.EcoOverhaul_BondPrice[iIssuer] ~= nil) then
            any = true
            local row      = g_rowIM:GetInstance()
            local yield    = (MapModData.EcoOverhaul_BondYield    or {})[iIssuer] or 0
            local price    = GetPrice(iIssuer)
            local distress = (MapModData.EcoOverhaul_BondDistress or {})[iIssuer] or 0
            local owned    = GetHoldings(iPlayer, iIssuer)

            row.CivName:SetText(pIssuer:GetCivilizationShortDescription())
            row.BondYield:SetText(string.format("%.1f%%", yield * 100))
            row.BondPrice:SetText(EcoFormatGoldShort(price))
            row.BondRisk:SetText(RiskStr(distress))
            row.BondOwned:SetText(tostring(owned))
            row.BuyBtn:SetHide(false) row.SellBtn:SetHide(false)

            local canBuy = (owned + BOND_LOT <= MAX_UNITS_PER_ISSUER)
                and (total + BOND_LOT <= MAX_TOTAL_UNITS)
                and (pPlayer:GetGold() >= price * BOND_LOT)
            row.BuyBtn:SetVoids(iIssuer, 0)
            row.BuyBtn:RegisterCallback(Mouse.eLClick, OnBondBuyClicked)
            row.BuyBtn:SetDisabled(not canBuy)
            row.BuyBtn:SetToolTipString(canBuy
                and ("Buy " .. BOND_LOT .. " unit(s) for " .. EcoFormatGold(price * BOND_LOT))
                or "Cannot buy: check gold or ownership caps")

            row.SellBtn:SetVoids(iIssuer, 0)
            row.SellBtn:RegisterCallback(Mouse.eLClick, OnBondSellClicked)
            row.SellBtn:SetDisabled(owned < BOND_LOT)
            row.SellBtn:SetToolTipString(owned >= BOND_LOT
                and ("Sell " .. BOND_LOT .. " unit(s) for " .. EcoFormatGold(price * BOND_LOT))
                or "You hold none of these bonds")
        end
    end

    if not any then
        local row = g_rowIM:GetInstance()
        row.CivName:SetText("[COLOR:180:180:180:255]No other civilizations met yet.[/COLOR]")
        row.BondYield:SetText("") row.BondPrice:SetText("") row.BondRisk:SetText("") row.BondOwned:SetText("")
        row.BuyBtn:SetHide(true) row.SellBtn:SetHide(true)
    end

    -- Required for InstanceManager rows to lay out and become visible/scrollable.
    Controls.BondRowStack:CalculateSize()
    Controls.BondRowStack:ReprocessAnchoring()
    Controls.BondScroll:CalculateInternalSize()
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

function EconOverhaul_SovereignBonds_AddInfoEntry(additionalEntries)
    table.insert(additionalEntries, { text = "Sovereign Bonds", call = ShowPanel })
end
LuaEvents.AdditionalInformationDropdownGatherEntries.Add(EconOverhaul_SovereignBonds_AddInfoEntry)
LuaEvents.RequestRefreshAdditionalInformationDropdownEntries()

ContextPtr:SetHide(true)
print("Economy Overhaul - Sovereign Bonds: SovereignBondsPanel.lua loaded.")
