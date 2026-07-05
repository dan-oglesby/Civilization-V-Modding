-- ============================================================
-- Economy Overhaul - Financial Markets: FinancialMarketsPanel.lua
-- InGameUIAddin Stock Market panel, opened from the Additional
-- Information dropdown (top-right). Fully standalone.
--
-- (Sovereign debt / loans live in the separate "Economy Overhaul -
-- Banking" mod's National Treasury panel — not here.)
-- ============================================================

include("InstanceManager")   -- required before InstanceManager:new(); its
                             -- absence aborts the whole script at load, leaving
                             -- this panel stuck open with a dead close button.
include("EcoCurrency")       -- gold/silver/copper money layer (EcoFormatMoney, EcoChangeCopper, EcoGetTreasuryCopper)

-- Display names are flavor "company" names; the tooltip desc names the sector it tracks.
local INDUSTRIES = {
    { key = "commerce",   name = "Meridian Holdings", desc = "Commerce & finance sector — driven by global gold income per civ"                  },
    { key = "research",   name = "Apex Dynamics",     desc = "High-tech & research sector — driven by global science and technology output per civ" },
    { key = "culture",    name = "Stellar Studios",   desc = "Entertainment & media sector — driven by global cultural output per civ"           },
    { key = "population", name = "Heartland Farms",   desc = "Agriculture sector — driven by total city population (food & rural output)"        },
    { key = "resources",  name = "Titan Minerals",    desc = "Strategic-resources sector — driven by average strategic resource prices"          },
    { key = "luxury",     name = "Maison Luxe",       desc = "Luxury-trade sector — driven by average luxury resource prices"                    },
}

local TOTAL_SHARES   = 10000   -- split from 100 (must match StockMarket.lua)
local MAX_OWN_SHARES = 10000   -- no ownership cap: a civ may own up to 100% of an industry (float-limited)
local DIVIDEND_RATE  = 0.002
local BASE_PRICE     = 100     -- COPPER per share at fair value (100 copper = 1 gold)
local SHARE_LOT      = 100     -- shares bought / sold per Buy/Sell click (#8)
local INDEX_LOT      = 100     -- max index units (1 share of each sector) bought per "Buy Index" click

local g_rowIM = InstanceManager:new("StockRowInstance", "RowRoot", Controls.StockRowStack)
local RefreshStocks  -- forward declaration

-- ============================================================
-- Reinvest toggle
-- ============================================================

local function IsReinvestOn()
    return (MapModData.EcoOverhaul_ReinvestOn ~= nil) and (MapModData.EcoOverhaul_ReinvestOn[Game.GetActivePlayer()] == true)
end
local function UpdateReinvestButton()
    if IsReinvestOn() then Controls.ReinvestBtnLabel:SetText("[COLOR_POSITIVE_TEXT]Reinvest Dividends: ON[ENDCOLOR]")
    else Controls.ReinvestBtnLabel:SetText("[COLOR:180:180:180:255]Reinvest Dividends: OFF[/COLOR]") end
end
Controls.ReinvestToggleBtn:RegisterCallback(Mouse.eLClick, function()
    local iPlayer = Game.GetActivePlayer()
    local pPlayer = Players[iPlayer]
    if pPlayer == nil then return end
    if MapModData.EcoOverhaul_ReinvestOn == nil then MapModData.EcoOverhaul_ReinvestOn = {} end
    local turningOff = (MapModData.EcoOverhaul_ReinvestOn[iPlayer] == true)
    MapModData.EcoOverhaul_ReinvestOn[iPlayer] = not turningOff
    if turningOff then
        local pool = MapModData.EcoOverhaul_DividendPool and MapModData.EcoOverhaul_DividendPool[iPlayer]
        if pool ~= nil then
            local payout = 0
            for _, ind in ipairs(INDUSTRIES) do
                local amt = pool[ind.key] or 0
                if amt > 0 then payout = payout + amt; pool[ind.key] = 0 end
            end
            if payout > 0 then EcoChangeCopper(pPlayer, payout); MapModData.EcoOverhaul_DividendPool[iPlayer] = pool end   -- pool is copper
        end
    end
    UpdateReinvestButton(); RefreshStocks()
end)

-- Does this player own at least one of the given building? (wonder-owner checks)
local function PlayerOwnsBuilding(iPlayer, buildingType)
    local pPlayer = Players[iPlayer]
    local iBldg   = GameInfoTypes[buildingType]
    if pPlayer == nil or iBldg == nil then return false end
    for pCity in pPlayer:Cities() do
        if pCity:GetNumBuilding(iBldg) > 0 then return true end
    end
    return false
end

-- Toggle whether this player's wonder income auto-invests into the index (default ON).
Controls.AutoInvestToggleBtn:RegisterCallback(Mouse.eLClick, function()
    local iPlayer = Game.GetActivePlayer()
    if MapModData.EcoOverhaul_IndexAutoInvest == nil then MapModData.EcoOverhaul_IndexAutoInvest = {} end
    local on = (MapModData.EcoOverhaul_IndexAutoInvest[iPlayer] ~= false)
    MapModData.EcoOverhaul_IndexAutoInvest[iPlayer] = (not on)
    MapModData.EcoOverhaul_IndexAutoInvest = MapModData.EcoOverhaul_IndexAutoInvest  -- defensive cross-context write-back
    RefreshStocks()
end)

-- ============================================================
-- Helpers
-- ============================================================

local function GetOwnedShares(iPlayer, key)
    local tbl = MapModData.EcoOverhaul_StockOwned and MapModData.EcoOverhaul_StockOwned[iPlayer]
    return tbl and (tbl[key] or 0) or 0
end
local function SetOwnedShares(iPlayer, key, qty)
    if MapModData.EcoOverhaul_StockOwned == nil then MapModData.EcoOverhaul_StockOwned = {} end
    if MapModData.EcoOverhaul_StockOwned[iPlayer] == nil then MapModData.EcoOverhaul_StockOwned[iPlayer] = {} end
    MapModData.EcoOverhaul_StockOwned[iPlayer][key] = math.max(0, qty)
    MapModData.EcoOverhaul_StockOwned[iPlayer] = MapModData.EcoOverhaul_StockOwned[iPlayer]
end
local function GetFloat(key)
    return (MapModData.EcoOverhaul_StockFloat and MapModData.EcoOverhaul_StockFloat[key]) or TOTAL_SHARES
end
local function SetFloat(key, qty)
    if MapModData.EcoOverhaul_StockFloat == nil then MapModData.EcoOverhaul_StockFloat = {} end
    MapModData.EcoOverhaul_StockFloat[key] = math.max(0, math.min(TOTAL_SHARES, qty))
end
local function TrendStr(key)
    local cur  = (MapModData.EcoOverhaul_StockPrices     and MapModData.EcoOverhaul_StockPrices[key])     or BASE_PRICE
    local prev = (MapModData.EcoOverhaul_StockPrevPrices  and MapModData.EcoOverhaul_StockPrevPrices[key]) or BASE_PRICE
    if cur > prev + 1 then return "[COLOR_POSITIVE_TEXT]▲[ENDCOLOR]"
    elseif cur < prev - 1 then return "[COLOR_WARNING_TEXT]▼[ENDCOLOR]"
    else return "[COLOR:200:200:200:255]─[/COLOR]" end
end

-- ============================================================
-- Stock trade execution
-- ============================================================

-- Prices are in COPPER. Trades move a lot of SHARE_LOT (100) shares, clamped
-- by float, the ownership cap, and what the player can afford — so near a
-- limit you still buy/sell the remainder rather than nothing.
local function ExecuteBuy(iPlayerID, key)
    local pPlayer = Players[iPlayerID]
    if pPlayer == nil then return false end
    local price = (MapModData.EcoOverhaul_StockPrices and MapModData.EcoOverhaul_StockPrices[key]) or BASE_PRICE
    local float = GetFloat(key); local owned = GetOwnedShares(iPlayerID, key)
    local affordable = math.floor(EcoGetTreasuryCopper(pPlayer) / math.max(1, price))
    local qty = math.min(SHARE_LOT, float, MAX_OWN_SHARES - owned, affordable)
    if qty < 1 then return false end
    local cost = price * qty   -- copper
    EcoChangeCopper(pPlayer, -cost); SetOwnedShares(iPlayerID, key, owned + qty); SetFloat(key, float - qty)
    return true
end
local function ExecuteSell(iPlayerID, key)
    local pPlayer = Players[iPlayerID]
    if pPlayer == nil then return false end
    local price = (MapModData.EcoOverhaul_StockPrices and MapModData.EcoOverhaul_StockPrices[key]) or BASE_PRICE
    local owned = GetOwnedShares(iPlayerID, key); local float = GetFloat(key)
    local qty = math.min(SHARE_LOT, owned)
    if qty < 1 then return false end
    EcoChangeCopper(pPlayer, price * qty); SetOwnedShares(iPlayerID, key, owned - qty); SetFloat(key, float + qty)
    return true
end

-- Index fund: buy an equal number of shares of EVERY sector at once. One "index unit" is one
-- share of each; its cost is the sum of all sector prices. Buys up to INDEX_LOT units, clamped
-- by treasury and by the smallest sector float/headroom so holdings stay equal.
local function ExecuteBuyIndex(iPlayerID)
    local pPlayer = Players[iPlayerID]
    if pPlayer == nil then return false end
    local unitCost, minRoom = 0, math.huge
    for _, ind in ipairs(INDUSTRIES) do
        local price = (MapModData.EcoOverhaul_StockPrices and MapModData.EcoOverhaul_StockPrices[ind.key]) or BASE_PRICE
        unitCost = unitCost + price
        minRoom  = math.min(minRoom, GetFloat(ind.key), MAX_OWN_SHARES - GetOwnedShares(iPlayerID, ind.key))
    end
    if unitCost <= 0 then return false end
    local affordable = math.floor(EcoGetTreasuryCopper(pPlayer) / unitCost)
    local units = math.min(INDEX_LOT, affordable, minRoom)
    if units < 1 then return false end
    EcoChangeCopper(pPlayer, -(units * unitCost))
    for _, ind in ipairs(INDUSTRIES) do
        SetOwnedShares(iPlayerID, ind.key, GetOwnedShares(iPlayerID, ind.key) + units)
        SetFloat(ind.key, GetFloat(ind.key) - units)
    end
    return true
end
Controls.BuyIndexBtn:RegisterCallback(Mouse.eLClick, function()
    if ExecuteBuyIndex(Game.GetActivePlayer()) then RefreshStocks() end
end)

-- ============================================================
-- Stocks tab refresh
-- ============================================================

RefreshStocks = function()
    g_rowIM:ResetInstances(); UpdateReinvestButton()
    local iPlayerID = Game.GetActivePlayer()
    local pPlayer   = Players[iPlayerID]
    if pPlayer == nil then return end
    local reinvestOn = IsReinvestOn()

    -- The stock market opens only once the Global Stock Market world wonder exists (anywhere).
    local stockOwner = EcoWonderOwner("BUILDING_ECO_GLOBAL_STOCK_MARKET")
    if stockOwner == nil then
        Controls.PortfolioSummary:SetText("Opens once any civilization builds the [COLOR_POSITIVE_TEXT]Global Stock Market[ENDCOLOR] world wonder (requires Banking).")
        local row = g_rowIM:GetInstance()
        row.IndName:SetText("[COLOR:180:180:180:255]Market closed.[/COLOR]")
        row.IndPrice:SetText(""); row.IndOwned:SetText(""); row.IndFloat:SetText(""); row.IndDiv:SetText("")
        row.BuyBtn:SetHide(true); row.SellBtn:SetHide(true)
        Controls.BuyIndexBtn:SetDisabled(true)
        Controls.AutoInvestToggleBtn:SetHide(true)
        Controls.StockRowStack:CalculateSize(); Controls.StockRowStack:ReprocessAnchoring(); Controls.StockRowScroll:CalculateInternalSize()
        return
    end

    local totalValue, totalDiv = 0, 0
    for _, ind in ipairs(INDUSTRIES) do
        local owned = GetOwnedShares(iPlayerID, ind.key)
        if owned > 0 then
            local price = (MapModData.EcoOverhaul_StockPrices and MapModData.EcoOverhaul_StockPrices[ind.key]) or BASE_PRICE
            totalValue = totalValue + owned * price
            totalDiv   = totalDiv   + math.floor(owned * price * DIVIDEND_RATE)
        end
    end
    local totalPooled = 0
    if reinvestOn then
        local poolTbl = MapModData.EcoOverhaul_DividendPool and MapModData.EcoOverhaul_DividendPool[iPlayerID]
        if poolTbl then for _, ind in ipairs(INDUSTRIES) do totalPooled = totalPooled + (poolTbl[ind.key] or 0) end end
    end
    local poolStr = (reinvestOn and totalPooled > 0) and ("   [COLOR_POSITIVE_TEXT]Pool: " .. EcoFormatMoney(totalPooled) .. "[ENDCOLOR]") or ""
    local ownsBondEx    = PlayerOwnsBuilding(iPlayerID, "BUILDING_BOND_EXCHANGE")
    local isWonderOwner = (stockOwner == iPlayerID) or ownsBondEx
    local myPool        = (MapModData.EcoOverhaul_IndexPool or {})[iPlayerID] or 0
    local exchStr = "   [COLOR:170:170:170:255]" .. SHARE_LOT .. "/trade[ENDCOLOR]"
    if isWonderOwner then
        exchStr = "   [COLOR_POSITIVE_TEXT]Index pool: " .. EcoFormatMoney(myPool) .. "[ENDCOLOR]"
    end

    -- Auto-invest toggle: shown only to Global Stock Market / Bond Exchange owners.
    if isWonderOwner then
        Controls.AutoInvestToggleBtn:SetHide(false)
        local on = (MapModData.EcoOverhaul_IndexAutoInvest == nil) or (MapModData.EcoOverhaul_IndexAutoInvest[iPlayerID] ~= false)
        Controls.AutoInvestToggleLabel:SetText(on
            and "Auto-Invest Wonder Income: [COLOR_POSITIVE_TEXT]ON[ENDCOLOR]"
            or  "Auto-Invest Wonder Income: [COLOR:200:200:200:255]OFF[/COLOR]")
    else
        Controls.AutoInvestToggleBtn:SetHide(true)
    end
    Controls.PortfolioSummary:SetText(
        "Value: [COLOR_POSITIVE_TEXT]" .. EcoFormatMoney(totalValue) .. "[ENDCOLOR]   Div: [COLOR_POSITIVE_TEXT]+" .. EcoFormatMoney(totalDiv) .. "/turn[ENDCOLOR]" .. poolStr .. exchStr)

    -- Index fund buy button: one index unit = one share of each sector.
    local indexUnitCost = 0
    for _, ind in ipairs(INDUSTRIES) do
        indexUnitCost = indexUnitCost + ((MapModData.EcoOverhaul_StockPrices and MapModData.EcoOverhaul_StockPrices[ind.key]) or BASE_PRICE)
    end
    Controls.BuyIndexBtnLabel:SetText("Buy Index x" .. INDEX_LOT .. " (" .. EcoFormatMoney(indexUnitCost) .. ")")
    Controls.BuyIndexBtn:SetDisabled(EcoGetTreasuryCopper(pPlayer) < indexUnitCost)
    Controls.BuyIndexBtn:SetToolTipString("Buys up to " .. INDEX_LOT .. " of every sector at once, keeping your holdings equal. One index unit (one share of each) costs " .. EcoFormatMoney(indexUnitCost) .. ".")

    for i, ind in ipairs(INDUSTRIES) do
        local row     = g_rowIM:GetInstance()
        local price   = (MapModData.EcoOverhaul_StockPrices   and MapModData.EcoOverhaul_StockPrices[ind.key])   or BASE_PRICE
        local fairVal = (MapModData.EcoOverhaul_StockFairVals  and MapModData.EcoOverhaul_StockFairVals[ind.key]) or BASE_PRICE
        local owned   = GetOwnedShares(iPlayerID, ind.key)
        local float   = GetFloat(ind.key)
        local divPT   = math.floor(owned * price * DIVIDEND_RATE)
        local ratio   = price / math.max(1, fairVal)
        local nameColor = (ratio <= 0.90 and ("[COLOR_POSITIVE_TEXT]" .. ind.name .. "[ENDCOLOR]"))
                       or (ratio >= 1.15 and ("[COLOR_WARNING_TEXT]"  .. ind.name .. "[ENDCOLOR]"))
                       or ind.name
        -- Prices are sub-gold (10,000 shares), so show a compact copper count (100c = 1[ICON_GOLD]);
        -- the fair value moves to the tooltip to keep the column narrow.
        local priceStr = EcoFormatCopper(price)

        row.IndName:SetText(nameColor)
        row.IndName:SetToolTipString(ind.desc .. "  Fair value: " .. EcoFormatCopper(fairVal) .. "/share")
        row.IndPrice:SetText(priceStr)
        row.IndPrice:SetToolTipString("Price " .. EcoFormatCopper(price) .. "   Fair value " .. EcoFormatCopper(fairVal) .. "   " .. TrendStr(ind.key))
        row.IndOwned:SetText(tostring(owned)); row.IndFloat:SetText(tostring(float))

        local poolAmt = 0
        if reinvestOn then
            local poolTbl = MapModData.EcoOverhaul_DividendPool and MapModData.EcoOverhaul_DividendPool[iPlayerID]
            poolAmt = poolTbl and (poolTbl[ind.key] or 0) or 0
        end
        local canReinv = reinvestOn and (float > 0) and (owned < MAX_OWN_SHARES)
        local divText, divTip
        if reinvestOn and poolAmt > 0 then
            -- Pooled gold persists even on a turn the dividend rounds to 0; always show it.
            divText = "[COLOR_POSITIVE_TEXT]Pool:" .. EcoFormatCopper(poolAmt) .. "[ENDCOLOR]"
            divTip  = string.format("Reinvesting into %s.[NEWLINE]Pool: %s / %s per share.%s",
                ind.name, EcoFormatCopper(poolAmt), EcoFormatCopper(price), (divPT > 0 and ("[NEWLINE]+" .. EcoFormatCopper(divPT) .. " added this turn.") or ""))
        elseif reinvestOn and canReinv and divPT > 0 then
            divText = "+" .. EcoFormatCopper(divPT)
            divTip  = string.format("Reinvesting +%s/turn into %s (building toward a whole share).", EcoFormatCopper(divPT), ind.name)
        elseif reinvestOn and divPT > 0 then
            divText = "+" .. EcoFormatCopper(divPT)
            divTip  = string.format("+%s/turn to treasury (reinvestment unavailable — float: %d, owned: %d/%d).", EcoFormatCopper(divPT), float, owned, MAX_OWN_SHARES)
        else
            divText = divPT > 0 and ("+" .. EcoFormatCopper(divPT)) or "—"
            divTip  = divPT > 0 and (string.format("+%s/turn to treasury.", EcoFormatCopper(divPT))) or "No dividend this turn."
        end
        row.IndDiv:SetText(divText); row.IndDiv:SetToolTipString(divTip)

        row.BuyBtn:SetHide(false); row.BuyBtn:SetVoids(i, 0); row.BuyBtn:RegisterCallback(Mouse.eLClick, OnBuyClicked)
        local canBuy = (float >= 1) and (owned < MAX_OWN_SHARES) and (EcoGetTreasuryCopper(pPlayer) >= price)
        row.BuyBtn:SetDisabled(not canBuy)
        row.BuyBtn:SetToolTipString(canBuy and ("Buy up to " .. SHARE_LOT .. " shares (" .. EcoFormatMoney(price) .. " each)") or "Cannot buy: check gold, float, or ownership cap")

        row.SellBtn:SetHide(false); row.SellBtn:SetVoids(i, 0); row.SellBtn:RegisterCallback(Mouse.eLClick, OnSellClicked)
        local canSell = owned >= 1
        row.SellBtn:SetDisabled(not canSell)
        row.SellBtn:SetToolTipString(canSell and ("Sell up to " .. SHARE_LOT .. " shares (" .. EcoFormatMoney(price) .. " each)") or "You own no shares of this industry")
    end

    -- Required for InstanceManager rows to lay out and become visible/scrollable.
    Controls.StockRowStack:CalculateSize()
    Controls.StockRowStack:ReprocessAnchoring()
    Controls.StockRowScroll:CalculateInternalSize()
end

-- ============================================================
-- Button callbacks
-- ============================================================

-- Civ5 passes button-click callbacks the control's (void1, void2) values
-- directly — NOT the control. void1 is the industry index set via SetVoids(i,0).
function OnBuyClicked(iVoid1)
    local ind = INDUSTRIES[iVoid1]; if ind == nil then return end
    ExecuteBuy(Game.GetActivePlayer(), ind.key); RefreshStocks()
end
function OnSellClicked(iVoid1)
    local ind = INDUSTRIES[iVoid1]; if ind == nil then return end
    ExecuteSell(Game.GetActivePlayer(), ind.key); RefreshStocks()
end

-- ============================================================
-- Show / Hide — via ContextPtr (Lord Mayors pattern)
-- ============================================================

local function ShowPanel()
    UpdateReinvestButton()
    RefreshStocks()
    ContextPtr:SetHide(false)
end

local function HidePanel()
    ContextPtr:SetHide(true)
end

Controls.ClosePanelBtn:RegisterCallback(Mouse.eLClick, HidePanel)

Events.ActivePlayerTurnStart.Add(function()
    if not ContextPtr:IsHidden() then RefreshStocks() end
end)
Events.SerialEventGameDataDirty.Add(function()
    if not ContextPtr:IsHidden() then RefreshStocks() end
end)

-- ============================================================
-- Register with Additional Information dropdown (BNW standard)
-- ============================================================

function EconOverhaul_FinancialMarkets_AddInfoEntry(additionalEntries)
    table.insert(additionalEntries, {
        text = "Financial Markets",
        call = ShowPanel,
    })
end
LuaEvents.AdditionalInformationDropdownGatherEntries.Add(EconOverhaul_FinancialMarkets_AddInfoEntry)
LuaEvents.RequestRefreshAdditionalInformationDropdownEntries()

-- ============================================================
-- Initialize: hide context at load (Lord Mayors style)
-- ============================================================
ContextPtr:SetHide(true)

print("Economy Overhaul - Financial Markets: FinancialMarketsPanel.lua loaded.")
