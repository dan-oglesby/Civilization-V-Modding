-- ============================================================
-- Economy Overhaul: EcoCurrency.lua   (shared include library)
--
-- A gold / silver / copper money layer.
--     1 gold = 10 silver = 100 copper        (1 silver = 10 copper)
-- Civ5's Lua API only changes gold in whole units, but the engine
-- stores the treasury to 1/100 gold (GetGoldTimes100). So 1 copper
-- maps exactly onto 1 unit of GetGoldTimes100, and we treat all
-- money internally as an integer number of COPPER.
--
-- Because Lua cannot write fractional gold to the engine treasury,
-- each player keeps a sub-gold "copper purse" in MapModData. Mod
-- income/expense accrues there in copper; whole gold is banked to (or
-- drawn from) the engine treasury as the purse fills or empties, and
-- the leftover sub-gold remains in the purse. Total wealth shown to
-- the player = engine treasury (hundredths) + purse.
--
-- This file is a LIBRARY, not an entry point: every Economy Overhaul
-- file pulls it in with   include("EcoCurrency")   which defines the
-- Eco* globals in that file's context (each addin has its own _G, so
-- there is no cross-file collision).
--
-- NOTE: Lua 5.1 syntax (required by Civ5).
-- ============================================================

ECO_COPPER_PER_SILVER = 10
ECO_COPPER_PER_GOLD   = 100

-- Tag colors for silver / copper (gold uses the [ICON_GOLD] glyph).
local ECO_SILVER_COLOR = "[COLOR:205:214:224:255]"   -- pale steel
local ECO_COPPER_COLOR = "[COLOR:212:130:74:255]"    -- copper / bronze

-- Persistent per-player sub-gold purse, in copper.
MapModData.EcoOverhaul_Copper = MapModData.EcoOverhaul_Copper or {}

-- ------------------------------------------------------------
-- Empire currencies (#3): once a civ researches Economics, its money is shown in a
-- historic currency instead of gold/silver/copper. Conversion is UNIFORM — 1 gold =
-- 1 currency unit, 2 decimals (1 copper = 1 cent). Display is always in the ACTIVE
-- player's currency. Currencies are the historic money of each empire (or a plausible
-- stand-in where the civ had no coinage); covers base game + G&K + BNW + DLC civs.
-- ------------------------------------------------------------

local ECO_DEFAULT_CURRENCY = "Florin"   -- any civ without its own historic coin uses the Florin
local ECO_CURRENCIES = {
    -- Base game
    CIVILIZATION_AMERICA   = "Dollar",    CIVILIZATION_ARABIA    = "Dinar",
    CIVILIZATION_CHINA     = "Tael",      CIVILIZATION_EGYPT     = "Deben",
    CIVILIZATION_ENGLAND   = "Pound",     CIVILIZATION_FRANCE    = "Franc",
    CIVILIZATION_GERMANY   = "Mark",      CIVILIZATION_GREECE    = "Drachma",
    CIVILIZATION_INDIA     = "Rupee",     CIVILIZATION_JAPAN     = "Ryo",
    CIVILIZATION_OTTOMAN   = "Akce",      CIVILIZATION_PERSIA    = "Daric",
    CIVILIZATION_ROME      = "Denarius",  CIVILIZATION_RUSSIA    = "Ruble",
    CIVILIZATION_SIAM      = "Baht",      CIVILIZATION_SONGHAI   = "Cowrie",
    -- Gods & Kings
    CIVILIZATION_AUSTRIA   = "Thaler",    CIVILIZATION_BYZANTIUM = "Solidus",
    CIVILIZATION_CARTHAGE  = "Shekel",    CIVILIZATION_CELTS     = "Stater",
    CIVILIZATION_ETHIOPIA  = "Birr",      CIVILIZATION_NETHERLANDS = "Guilder",
    CIVILIZATION_SWEDEN    = "Daler",
    -- Brave New World
    CIVILIZATION_ASSYRIA   = "Talent",    CIVILIZATION_BRAZIL    = "Real",
    CIVILIZATION_INDONESIA = "Rupiah",    CIVILIZATION_MOROCCO   = "Dirham",
    CIVILIZATION_POLAND    = "Zloty",     CIVILIZATION_PORTUGAL  = "Escudo",
    CIVILIZATION_VENICE    = "Ducat",
    -- Standalone DLC
    CIVILIZATION_SPAIN     = "Doubloon",  CIVILIZATION_DENMARK   = "Krone",
    CIVILIZATION_KOREA     = "Mun",       CIVILIZATION_BABYLON   = "Mina",
    CIVILIZATION_MONGOL    = "Sukhe",
    -- Civilizations with no coinage of their own use the Florin — the dominant Renaissance
    -- trade coin (Economics, which unlocks the currency layer, lands mid-Renaissance in game).
    CIVILIZATION_AZTEC     = "Florin",    CIVILIZATION_MAYA      = "Florin",
    CIVILIZATION_INCA      = "Florin",    CIVILIZATION_IROQUOIS  = "Florin",
    CIVILIZATION_SHOSHONE  = "Florin",    CIVILIZATION_ZULU      = "Florin",
    CIVILIZATION_POLYNESIA = "Florin",    CIVILIZATION_HUNS      = "Florin",
}

-- Industrialization modernizes the currency to its present-day name. Eurozone civilizations
-- adopt the Euro; North-American tribes and Hawaii use the Dollar; everyone else takes their
-- modern national coin. Same uniform conversion (1 gold = 1 unit). Civs with no clear modern
-- successor fall back to the Dollar (the global reserve currency).
local ECO_MODERN_DEFAULT = "Dollar"
local ECO_MODERN_CURRENCIES = {
    -- Eurozone
    CIVILIZATION_FRANCE    = "Euro",      CIVILIZATION_GERMANY   = "Euro",
    CIVILIZATION_GREECE    = "Euro",      CIVILIZATION_ROME      = "Euro",
    CIVILIZATION_AUSTRIA   = "Euro",      CIVILIZATION_NETHERLANDS = "Euro",
    CIVILIZATION_SPAIN     = "Euro",      CIVILIZATION_PORTUGAL  = "Euro",
    CIVILIZATION_VENICE    = "Euro",      CIVILIZATION_BYZANTIUM = "Euro",
    CIVILIZATION_CELTS     = "Euro",
    -- Modern national currencies
    CIVILIZATION_AMERICA   = "Dollar",    CIVILIZATION_ENGLAND   = "Pound",
    CIVILIZATION_RUSSIA    = "Ruble",     CIVILIZATION_CHINA     = "Yuan",
    CIVILIZATION_JAPAN     = "Yen",       CIVILIZATION_INDIA     = "Rupee",
    CIVILIZATION_KOREA     = "Won",       CIVILIZATION_OTTOMAN   = "Lira",
    CIVILIZATION_PERSIA    = "Rial",      CIVILIZATION_ARABIA    = "Riyal",
    CIVILIZATION_EGYPT     = "Pound",     CIVILIZATION_MOROCCO   = "Dirham",
    CIVILIZATION_CARTHAGE  = "Dinar",     CIVILIZATION_ASSYRIA   = "Dinar",
    CIVILIZATION_BABYLON   = "Dinar",     CIVILIZATION_SIAM      = "Baht",
    CIVILIZATION_INDONESIA = "Rupiah",    CIVILIZATION_BRAZIL    = "Real",
    CIVILIZATION_SWEDEN    = "Krona",     CIVILIZATION_DENMARK   = "Krone",
    CIVILIZATION_POLAND    = "Zloty",     CIVILIZATION_ETHIOPIA  = "Birr",
    CIVILIZATION_ZULU      = "Rand",      CIVILIZATION_MONGOL    = "Tugrik",
    CIVILIZATION_SONGHAI   = "CFA Franc", CIVILIZATION_HUNS      = "Forint",
    -- Mesoamerican / Andean
    CIVILIZATION_AZTEC     = "Peso",      CIVILIZATION_MAYA      = "Peso",
    CIVILIZATION_INCA      = "Sol",
    -- North-American tribes + Hawaii use the Dollar (per design)
    CIVILIZATION_IROQUOIS  = "Dollar",    CIVILIZATION_SHOSHONE  = "Dollar",
    CIVILIZATION_POLYNESIA = "Dollar",
}

-- The active player's currency NAME once they have Economics, else nil (nil = show
-- gold/silver/copper). pcall-guarded so any API hiccup falls back to g/s/c.
function EcoActiveCurrency()
    local ok, name = pcall(function()
        local iEcon = GameInfoTypes["TECH_ECONOMICS"]
        if iEcon == nil then return nil end
        local iP = Game.GetActivePlayer()
        if iP == nil or iP < 0 then return nil end
        local p = Players[iP]
        if p == nil then return nil end
        local teamTechs = Teams[p:GetTeam()]:GetTeamTechs()
        if not teamTechs:HasTech(iEcon) then return nil end
        local civInfo = GameInfo.Civilizations[p:GetCivilizationType()]
        local key = civInfo and civInfo.Type or nil
        -- Industrialization switches the empire to its modern present-day currency.
        local iInd = GameInfoTypes["TECH_INDUSTRIALIZATION"]
        if iInd ~= nil and teamTechs:HasTech(iInd) then
            return (key and ECO_MODERN_CURRENCIES[key]) or ECO_MODERN_DEFAULT
        end
        return (key and ECO_CURRENCIES[key]) or ECO_DEFAULT_CURRENCY
    end)
    if ok then return name end
    return nil
end

-- Thousands separators on an integer (pure Lua, no Locale dependency).
local function EcoComma(n)
    local s = tostring(math.floor(n))
    while true do
        local k
        s, k = s:gsub("^(%d+)(%d%d%d)", "%1,%2")
        if k == 0 then break end
    end
    return s
end

-- A COPPER amount as a "1,234.56" currency figure (1 gold = 1 unit, 1 copper = 1 cent).
local function EcoCurrencyAmount(copper)
    local neg = copper < 0
    copper = math.floor(math.abs(copper) + 0.5)
    return (neg and "-" or "") .. EcoComma(math.floor(copper / 100)) .. "." .. string.format("%02d", copper % 100)
end

-- ------------------------------------------------------------
-- Reads
-- ------------------------------------------------------------

-- The engine treasury to copper precision. GetGoldTimes100 is the same
-- API family the base TopPanel uses (GetCityConnectionGoldTimes100,
-- CalculateGrossGoldTimes100); pcall-guarded so a missing method
-- degrades to whole gold instead of erroring the whole context.
function EcoGetTreasuryCopper(pPlayer)
    if pPlayer == nil then return 0 end
    local ok, v = pcall(function() return pPlayer:GetGoldTimes100() end)
    if ok and v ~= nil then return math.floor(v) end
    return pPlayer:GetGold() * ECO_COPPER_PER_GOLD
end

-- The mod-owned sub-gold purse (copper not yet banked as whole gold).
function EcoGetPurse(iPlayer)
    local t = MapModData.EcoOverhaul_Copper
    return (t and t[iPlayer]) or 0
end

-- Total money the player holds, in copper = engine treasury + purse.
function EcoGetWealthCopper(pPlayer)
    if pPlayer == nil then return 0 end
    return EcoGetTreasuryCopper(pPlayer) + EcoGetPurse(pPlayer:GetID())
end

-- The player ID owning the given (world-wonder) building, or nil if no one has built it yet.
-- Used to gate the markets on the wonder existing and to pay its owner a cut of volume.
function EcoWonderOwner(buildingType)
    local iBldg = GameInfoTypes[buildingType]
    if iBldg == nil then return nil end
    for iP = 0, GameDefines.MAX_MAJOR_CIVS - 1 do
        local p = Players[iP]
        if p ~= nil and p:IsAlive() then
            for pCity in p:Cities() do
                if pCity:GetNumBuilding(iBldg) > 0 then return iP end
            end
        end
    end
    return nil
end

-- The player owning the MOST of a (non-unique) building, or nil if none — used for the Stock
-- Exchange (a normal building any civ can build): the busiest operator takes the exchange cut,
-- and "any owner exists" gates the market open.
function EcoTopBuildingOwner(buildingType)
    local iBldg = GameInfoTypes[buildingType]
    if iBldg == nil then return nil end
    local best, bestCount = nil, 0
    for iP = 0, GameDefines.MAX_MAJOR_CIVS - 1 do
        local p = Players[iP]
        if p ~= nil and p:IsAlive() then
            local n = 0
            for pCity in p:Cities() do
                if pCity:GetNumBuilding(iBldg) > 0 then n = n + 1 end
            end
            if n > bestCount then best, bestCount = iP, n end
        end
    end
    return best
end

-- Pop a notification to every human player (a global market event).
function EcoNotifyAll(title, msg)
    if NotificationTypes == nil then return end
    for iP = 0, GameDefines.MAX_MAJOR_CIVS - 1 do
        local p = Players[iP]
        if p ~= nil and p:IsAlive() and p:IsHuman() then
            p:AddNotification(NotificationTypes.NOTIFICATION_GENERIC, msg, title, -1, -1)
        end
    end
end

-- ------------------------------------------------------------
-- Writes
-- ------------------------------------------------------------

-- Add (copper > 0) or spend (copper < 0) an integer COPPER amount.
-- Whole gold is banked to / drawn from the engine treasury; the sub-
-- gold remainder stays in the purse. The mod never forces the treasury
-- below zero (no mod-induced bankruptcy): a shortfall is left as a
-- negative purse and collected once the player has gold again.
function EcoChangeCopper(pPlayer, copper)
    if pPlayer == nil then return end
    copper = math.floor(copper + 0.5)
    if copper == 0 then return end
    local iPlayer = pPlayer:GetID()
    if MapModData.EcoOverhaul_Copper == nil then MapModData.EcoOverhaul_Copper = {} end
    local purse = (MapModData.EcoOverhaul_Copper[iPlayer] or 0) + copper

    local whole = 0
    if purse >= ECO_COPPER_PER_GOLD then
        whole = math.floor(purse / ECO_COPPER_PER_GOLD)
    elseif purse < 0 then
        whole = -math.ceil(-purse / ECO_COPPER_PER_GOLD)
        whole = math.max(whole, -pPlayer:GetGold())   -- clamp: never bankrupt via the mod
    end
    if whole ~= 0 then
        pPlayer:ChangeGold(whole)
        purse = purse - whole * ECO_COPPER_PER_GOLD
    end
    MapModData.EcoOverhaul_Copper[iPlayer] = purse
    MapModData.EcoOverhaul_Copper = MapModData.EcoOverhaul_Copper   -- defensive cross-context write-back
end

-- ------------------------------------------------------------
-- Formatting
-- ------------------------------------------------------------

-- Render an integer COPPER amount as a compact g/s/c string, e.g.
-- 1234 -> "12[ICON_GOLD] 3s 4c". Silver/copper are hidden when both
-- are zero unless forceSubGold is true (steady table columns).
function EcoFormatMoney(copper, forceSubGold)
    local cur = EcoActiveCurrency()
    if cur ~= nil then return EcoCurrencyAmount(copper) .. " " .. cur end   -- post-Economics: empire currency
    copper = math.floor((copper or 0) + 0.5)
    local sign = ""
    if copper < 0 then sign = "-"; copper = -copper end
    local g = math.floor(copper / ECO_COPPER_PER_GOLD)
    local rem = copper - g * ECO_COPPER_PER_GOLD
    local s = math.floor(rem / ECO_COPPER_PER_SILVER)
    local c = rem - s * ECO_COPPER_PER_SILVER
    local str = sign .. g .. "[ICON_GOLD]"
    if forceSubGold or s > 0 or c > 0 then
        str = str .. " " .. ECO_SILVER_COLOR .. s .. "s[ENDCOLOR] " .. ECO_COPPER_COLOR .. c .. "c[ENDCOLOR]"
    end
    return str
end

-- Render a whole-GOLD value (may be fractional, e.g. a 12.34 price) as g/s/c, or the
-- empire currency WITH its name post-Economics ("200.00 Ruble"). For wide fields.
function EcoFormatGold(gold)
    return EcoFormatMoney(math.floor((gold or 0) * ECO_COPPER_PER_GOLD + 0.5))
end

-- Compact whole-GOLD value for tight columns: "13[ICON_GOLD]" pre-Economics, bare
-- "13.00" (no currency name) post-Economics. For narrow price/amount cells.
function EcoFormatGoldShort(gold)
    if EcoActiveCurrency() ~= nil then return EcoCurrencyAmount(math.floor((gold or 0) * ECO_COPPER_PER_GOLD + 0.5)) end
    return math.floor((gold or 0) + 0.5) .. "[ICON_GOLD]"
end

-- Compact copper-only render, e.g. 127 -> "127c". For tight table columns where
-- the full g/s/c breakdown is too wide (share prices, small per-turn dividends).
function EcoFormatCopper(copper)
    if EcoActiveCurrency() ~= nil then return EcoCurrencyAmount(copper) end   -- post-Economics: "1.27" in-currency
    return math.floor((copper or 0) + 0.5) .. "c"
end

-- ============================================================
-- Persistence  (Modding.OpenSaveData)
--
-- MapModData does NOT survive save/load in Civ5. It is an in-memory table
-- shared between Lua contexts for the CURRENT SESSION only -- which is why
-- InfoAddict and Corporations both keep their working state in MapModData
-- but write it through to Modding.OpenSaveData(), the engine's real per-save
-- store. Without this layer, a reload wipes every treasury purse, share,
-- bond and trade position the player owns.
--
-- OpenSaveData's SetValue/GetValue take SCALARS only (that is exactly how the
-- base game's own scenarios use it), so each nested table here is serialised
-- to one compact string under a single key, and scalars are stored directly.
--
-- Civ5 gives Lua no "game is being saved" event, so state is written through
-- once per turn -- the store is therefore always current whenever the player
-- saves -- and restored once when the first mod context loads.
--
-- EVERYTHING here is pcall-guarded. If persistence fails for any reason the
-- mod degrades to its previous behaviour (fresh state) rather than erroring.
-- ============================================================

local ECO_ENTRY_SEP = "~"
local ECO_FIELD_SEP = "^"

-- Keys must round-trip with their type intact: owned[3] and owned["3"] are
-- different slots, and the stock table is keyed by strings while the player
-- tables are keyed by integer IDs.
local function EcoEncKey(k)
    if type(k) == "number" then return "n" .. k end
    return "s" .. tostring(k)
end

local function EcoDecKey(s)
    if s == nil or s == "" then return nil end
    local tag = s:sub(1, 1)
    if tag == "n" then return tonumber(s:sub(2)) end
    return s:sub(2)
end

local function EcoEncVal(v)
    if type(v) == "boolean" then return v and "b1" or "b0" end
    return "#" .. tostring(v)
end

local function EcoDecVal(s)
    if s == nil or s == "" then return nil end
    if s:sub(1, 1) == "b" then return s:sub(2) == "1" end
    return tonumber(s:sub(2))
end

-- Flattens a 1- or 2-level table into "key^subkey^value" entries; depth-1
-- entries simply leave the middle field empty.
local function EcoSerialize(tbl)
    if type(tbl) ~= "table" then return "" end
    local out = {}
    for k, v in pairs(tbl) do
        if type(v) == "table" then
            for k2, v2 in pairs(v) do
                if type(v2) ~= "table" then
                    out[#out + 1] = EcoEncKey(k) .. ECO_FIELD_SEP .. EcoEncKey(k2) .. ECO_FIELD_SEP .. EcoEncVal(v2)
                end
            end
        else
            out[#out + 1] = EcoEncKey(k) .. ECO_FIELD_SEP .. ECO_FIELD_SEP .. EcoEncVal(v)
        end
    end
    return table.concat(out, ECO_ENTRY_SEP)
end

local function EcoDeserialize(str)
    local t = {}
    if type(str) ~= "string" or str == "" then return t end
    for entry in string.gmatch(str, "[^" .. ECO_ENTRY_SEP .. "]+") do
        local f1, f2, f3 = string.match(entry, "^([^%^]*)%^([^%^]*)%^(.*)$")
        local k1  = EcoDecKey(f1)
        local val = EcoDecVal(f3)
        if k1 ~= nil and val ~= nil then
            if f2 == "" then
                t[k1] = val
            else
                local k2 = EcoDecKey(f2)
                if k2 ~= nil then
                    if type(t[k1]) ~= "table" then t[k1] = {} end
                    t[k1][k2] = val
                end
            end
        end
    end
    return t
end

-- Scalars, stored directly. (Turn guards are included on purpose: without them a
-- reload would re-run the loaded turn's income and pay it twice.)
local ECO_SCALARS = {
    "SavingsRate", "PrevSavingsRate", "TotalSavings", "CorpDebt", "BorrowedPct", "LastRateTurn",
    "Climate", "ClimateTarget", "ClimatePhaseLeft", "ClimateTurn", "CrisisCooldown",
    "ClimateLabel", "ClimatePrevLabel",
    "StockTurn", "StockVolume", "StockExchangeOwner", "StockExchangeCut",
    "CmdPricesTurn", "CmdVolume", "CmdExchangeOwner", "CmdExchangeCut",
    "BondTurn", "NetWorthTurn", "NWLeader", "NWDominanceFlagged",
}

-- SetValue has no boolean type, so these ride as 1/0 and are restored as booleans.
local ECO_BOOL_SCALARS = { NWDominanceFlagged = true }

-- Nested tables, one serialised string each. Pure display values (this turn's
-- interest/dividends/revenue) are deliberately omitted -- they are recomputed
-- on the next turn and are not worth the bytes.
local ECO_TABLES = {
    "Copper", "IndexPool", "IndexAutoInvest",
    "StockPrices", "StockPrevPrices", "StockFairVals", "StockFloat",
    "StockOwned", "DividendPool", "ReinvestOn",
    "CmdPrices", "CmdPrevPrices", "CmdMarketAvail",
    "CmdSelling", "CmdTiedUp", "AutoSell", "AutoBuy",
    "BondHoldings",
    "TaxRate", "TaxUnhappiness",
    "NetWorth",
}

-- Write the whole mod state through to the save store.
function EcoSaveState()
    pcall(function()
        local db = Modding.OpenSaveData()
        if db == nil then return end
        for _, k in ipairs(ECO_SCALARS) do
            local v = MapModData["EcoOverhaul_" .. k]
            if v ~= nil then
                if type(v) == "boolean" then v = v and 1 or 0 end
                db.SetValue("EcoOverhaul_" .. k, v)
            end
        end
        for _, k in ipairs(ECO_TABLES) do
            db.SetValue("EcoOverhaulT_" .. k, EcoSerialize(MapModData["EcoOverhaul_" .. k]))
        end
        db.SetValue("EcoOverhaul_Saved", 1)   -- marker: distinguishes a loaded game from a new one
    end)
end

-- Restore state saved by a previous session. No-op on a brand-new game.
function EcoLoadState()
    local ok = pcall(function()
        local db = Modding.OpenSaveData()
        if db == nil then return end
        if db.GetValue("EcoOverhaul_Saved") == nil then return end   -- new game: nothing to restore
        for _, k in ipairs(ECO_SCALARS) do
            local v = db.GetValue("EcoOverhaul_" .. k)
            if v ~= nil then
                if ECO_BOOL_SCALARS[k] then v = (v == 1) or (v == true) end
                MapModData["EcoOverhaul_" .. k] = v
            end
        end
        for _, k in ipairs(ECO_TABLES) do
            local s = db.GetValue("EcoOverhaulT_" .. k)
            if type(s) == "string" and s ~= "" then
                MapModData["EcoOverhaul_" .. k] = EcoDeserialize(s)
            end
        end
    end)
    if not ok then print("Economy Overhaul: state restore failed; continuing with fresh state.") end
    return ok
end

-- Bootstrap. EcoCurrency is include()d at the TOP of every Economy Overhaul file,
-- so the first context to load restores state BEFORE any subsystem runs its
-- `MapModData.X = MapModData.X or {}` defaults -- those then keep the restored
-- tables instead of overwriting them. The guards make both steps idempotent
-- across the 15 contexts that include this file.
if not MapModData.EcoOverhaul_StateRestored then
    MapModData.EcoOverhaul_StateRestored = true
    EcoLoadState()
end

if not MapModData.EcoOverhaul_PersistHooked then
    MapModData.EcoOverhaul_PersistHooked = true
    -- Fires once per game turn, after every civ's PlayerDoTurn work is done and
    -- immediately before the player can reach the save menu.
    Events.ActivePlayerTurnStart.Add(EcoSaveState)
end

print("Economy Overhaul: EcoCurrency.lua loaded.")
