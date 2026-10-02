if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
if not (EllesmereUI and EllesmereUI.IS_FOREVER) then return end
-------------------------------------------------------------------------------
--  EllesmereUIForeverEssentials_LootFeed.lua  (WoW Forever only)
--  A stack of short-lived rows for what the player gains: looted items, money,
--  reputation, currencies and skill ups. Each row fades out after a while; a
--  repeat gain of the same thing adds to its row instead of opening another.
--  Chat lines are matched against the client's own localized format strings,
--  so this works in every client language.
-------------------------------------------------------------------------------
local GAP = 2
local FADE_IN = 0.35
local FADE_OUT = 0.8
local SLIDE = 24 -- px a new row glides in from the left
local MONEY_ICON = "Interface\\Icons\\INV_Misc_Coin_02"
local REP_ICON = "Interface\\Icons\\INV_Misc_Note_02"
local SKILL_ICON = "Interface\\Icons\\INV_Misc_Book_08"

-- Settings live in EllesmereUIDB.lootFeed; unset keys read these.
local DEFAULTS = {
    enabled = false,
    items = true, money = true, reputation = true, currency = true, skills = true,
    minQuality = 0, showIlvl = true, showPrice = true,
    width = 300, rowHeight = 36, maxRows = 6, duration = 5, grow = "UP",
    textSize = 13,
    bgR = 0.05, bgG = 0.05, bgB = 0.05, bgA = 0.3,
    borderSize = 1, borderR = 0, borderG = 0, borderB = 0, qualityBorder = true,
}

local anchor, events
local active = {} -- shown rows, newest first
local pool = {}

local function Cfg()
    if not EllesmereUIDB then return {} end
    EllesmereUIDB.lootFeed = EllesmereUIDB.lootFeed or {}
    return EllesmereUIDB.lootFeed
end

local _NOCFG = {}
local function Read()
    return EllesmereUIDB and EllesmereUIDB.lootFeed or _NOCFG
end

local function Get(key)
    local v = Read()[key]
    if v == nil then return DEFAULTS[key] end
    return v
end

local function Enabled()
    return Get("enabled") == true
end

local function IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v)
end

local function PlainString(v)
    if type(v) == "string" and not IsSecret(v) and v ~= "" then return v end
end

local function PlainNumber(v)
    if type(v) == "number" and not IsSecret(v) then return v end
end

-------------------------------------------------------------------------------
--  Chat line matching
-------------------------------------------------------------------------------
-- A Blizzard format string as a Lua pattern with one capture per %s / %d.
-- order maps each capture to its argument number, so positional formats
-- (%2$s before %1$d) come out in argument order.
local function Compile(fmt, anchored)
    local parts, order, seq, i = {}, {}, 0, 1
    while true do
        local s, e, pos, kind = fmt:find("%%(%d?)%$?([sd])", i)
        local chunk = s and fmt:sub(i, s - 1) or fmt:sub(i)
        parts[#parts + 1] = (chunk:gsub("[%^%$%(%)%.%[%]%*%+%-%?%%]", "%%%0"))
        if not s then break end
        seq = seq + 1
        order[#order + 1] = tonumber(pos) or seq
        parts[#parts + 1] = kind == "d" and "(%d+)" or "(.-)"
        i = e + 1
    end
    local p = table.concat(parts)
    if anchored then p = "^" .. p .. "$" end
    return { pat = p, order = order }
end

-- Compiled lazily per global string key; a key the client lacks is skipped.
local compiled = {}
local function Matcher(key, anchored)
    local c = compiled[key]
    if c == nil then
        local fmt = _G[key]
        c = type(fmt) == "string" and fmt ~= "" and Compile(fmt, anchored) or false
        compiled[key] = c
    end
    return c
end

local _caps = {}
local function Match(key, text)
    local c = Matcher(key, true)
    if not c then return end
    local a, b, d = text:match(c.pat)
    if not a then return end
    _caps[1], _caps[2], _caps[3] = nil, nil, nil
    _caps[c.order[1] or 1], _caps[c.order[2] or 2], _caps[c.order[3] or 3] = a, b, d
    return _caps[1], _caps[2], _caps[3]
end

-------------------------------------------------------------------------------
--  Rows
-------------------------------------------------------------------------------
local function StyleFont(fs, size)
    EllesmereUI.ApplyModuleFont(fs, nil, size, "essentials")
end

local function AnchorHeight()
    return Get("maxRows") * (Get("rowHeight") + GAP) - GAP
end

local function FormatMoney(copper)
    local g = math.floor(copper / 10000)
    local s = math.floor(copper / 100) % 100
    local c = copper % 100
    local G = "|cffffd700" .. GOLD_AMOUNT_SYMBOL .. "|r"
    local S = "|cffc7c7cf" .. SILVER_AMOUNT_SYMBOL .. "|r"
    local C = "|cffeda55f" .. COPPER_AMOUNT_SYMBOL .. "|r"
    if g > 0 then return string.format("%s%s %d%s %d%s", BreakUpLargeNumbers(g), G, s, S, c, C) end
    if s > 0 then return string.format("%d%s %d%s", s, S, c, C) end
    return c .. C
end

local function StyleRow(r)
    local h = Get("rowHeight")
    r:SetSize(Get("width"), h)
    r.icon:SetSize(h, h)
    r.bg:SetColorTexture(Get("bgR"), Get("bgG"), Get("bgB"), Get("bgA"))
    StyleFont(r.name, Get("textSize"))
    StyleFont(r.value, Get("textSize"))
    StyleFont(r.sub, Get("textSize") - 2)
    r.fade.alpha:SetStartDelay(Get("duration"))
end

local function Layout()
    local up = Get("grow") == "UP"
    local step = Get("rowHeight") + GAP
    for i, r in ipairs(active) do
        r:ClearAllPoints()
        if up then
            r:SetPoint("BOTTOMLEFT", anchor, "BOTTOMLEFT", 0, (i - 1) * step)
        else
            r:SetPoint("TOPLEFT", anchor, "TOPLEFT", 0, -(i - 1) * step)
        end
    end
end

local function Release(r)
    for i = #active, 1, -1 do
        if active[i] == r then table.remove(active, i) end
    end
    r.show:Stop()
    r.fade:Stop()
    r:Hide()
    r.key, r.data = nil, nil
    pool[#pool + 1] = r
    Layout()
end

-- Starts the wait-then-fade-out, unless the row is still fading in (its
-- end starts it) or hovered (leaving starts it).
local function ArmFade(r)
    if r.show:IsPlaying() then return end
    r.fade:Stop()
    r:SetAlpha(1)
    if not r:IsMouseOver() then r.fade:Play() end
end

local function RowEnter(r)
    if not r.show:IsPlaying() then
        r.fade:Stop()
        r:SetAlpha(1)
    end
    local link = r.data and r.data.link
    if link then
        GameTooltip:SetOwner(r, "ANCHOR_LEFT")
        GameTooltip:SetHyperlink(link)
        GameTooltip:Show()
    end
end

local function RowLeave(r)
    if GameTooltip:IsOwned(r) then GameTooltip:Hide() end
    ArmFade(r)
end

local function NewRow()
    local r = CreateFrame("Frame", nil, anchor)
    r.bg = r:CreateTexture(nil, "BACKGROUND")
    r.bg:SetAllPoints()
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetPoint("LEFT")
    r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) -- trim the icon frame
    r.value = r:CreateFontString(nil, "OVERLAY")
    r.value:SetPoint("RIGHT", r, "RIGHT", -6, 0)
    r.value:SetJustifyH("RIGHT")
    r.name = r:CreateFontString(nil, "OVERLAY")
    r.name:SetJustifyH("LEFT")
    r.name:SetWordWrap(false)
    r.sub = r:CreateFontString(nil, "OVERLAY")
    r.sub:SetJustifyH("LEFT")
    r.sub:SetWordWrap(false)
    EllesmereUI.PP.CreateBorder(r, 0, 0, 0, 1, 1, "OVERLAY", 2)
    -- Hover shows the item tooltip and holds the fade; clicks pass through.
    r:EnableMouseMotion(true)
    r:SetScript("OnEnter", RowEnter)
    r:SetScript("OnLeave", RowLeave)
    -- Fade in while gliding in: a zero-length jump left, then the way back.
    local show = r:CreateAnimationGroup()
    local jump = show:CreateAnimation("Translation")
    jump:SetOffset(-SLIDE, 0)
    jump:SetDuration(0)
    jump:SetOrder(1)
    local glide = show:CreateAnimation("Translation")
    glide:SetOffset(SLIDE, 0)
    glide:SetDuration(FADE_IN)
    glide:SetSmoothing("OUT")
    glide:SetOrder(2)
    local appear = show:CreateAnimation("Alpha")
    appear:SetFromAlpha(0)
    appear:SetToAlpha(1)
    appear:SetDuration(FADE_IN)
    appear:SetSmoothing("OUT")
    appear:SetOrder(2)
    show:SetScript("OnFinished", function() ArmFade(r) end)
    r.show = show
    local g = r:CreateAnimationGroup()
    g.alpha = g:CreateAnimation("Alpha")
    g.alpha:SetFromAlpha(1)
    g.alpha:SetToAlpha(0)
    g.alpha:SetDuration(FADE_OUT)
    g.alpha:SetSmoothing("IN_OUT")
    g:SetScript("OnFinished", function() Release(r) end)
    r.fade = g
    return r
end

-- Fills a row from its data table: icon, text (first line), sub (second
-- line, optional), value (right side, optional), border colour.
local function Fill(r)
    local d = r.data
    r.icon:SetTexture(d.icon)
    r.name:SetText(d.text)
    r.sub:SetText(d.sub or "")
    r.value:SetText(d.value or "")
    r.name:ClearAllPoints()
    r.name:SetPoint("RIGHT", r.value, "LEFT", -8, 0)
    if d.sub then
        r.name:SetPoint("BOTTOMLEFT", r.icon, "RIGHT", 6, 1)
        r.sub:ClearAllPoints()
        r.sub:SetPoint("TOPLEFT", r.icon, "RIGHT", 6, -1)
        r.sub:SetPoint("RIGHT", r.value, "LEFT", -8, 0)
        r.sub:Show()
    else
        r.name:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
        r.sub:Hide()
    end
    local PP = EllesmereUI.PP
    local size = Get("borderSize")
    if size > 0 then
        local br, bg, bb = Get("borderR"), Get("borderG"), Get("borderB")
        if d.border and Get("qualityBorder") then br, bg, bb = d.border.r, d.border.g, d.border.b end
        PP.UpdateBorder(r, size, br, bg, bb, 1)
        PP.ShowBorder(r)
    else
        PP.HideBorder(r)
    end
end

local function FindRow(key)
    for _, r in ipairs(active) do
        if r.key == key then return r end
    end
end

-- Shows data under key: an existing row with that key is refilled, moved to
-- the front and its fade restarted; otherwise a row is taken (the oldest one
-- when all maxRows are in use).
local function Push(key, data)
    local r = FindRow(key)
    local fresh = not r
    if r then
        for i, a in ipairs(active) do
            if a == r then table.remove(active, i); break end
        end
    else
        while #active >= Get("maxRows") do Release(active[#active]) end
        r = table.remove(pool) or NewRow()
        StyleRow(r)
    end
    table.insert(active, 1, r)
    r.key, r.data = key, data
    Fill(r)
    Layout()
    if fresh then
        r.fade:Stop()
        r:SetAlpha(0)
        r:Show()
        r.show:Play()
    else
        ArmFade(r)
    end
end

-------------------------------------------------------------------------------
--  Sources
-------------------------------------------------------------------------------
local function Previous(key)
    local r = FindRow(key)
    return r and r.data
end

local ShowItem
ShowItem = function(link, count)
    local name, _, quality, itemLevel, _, _, _, _, _, icon, sellPrice, classID = C_Item.GetItemInfo(link)
    if not name then
        -- Not cached yet: try again once the client has it.
        Item:CreateFromItemLink(link):ContinueOnItemLoad(function() ShowItem(link, count) end)
        return
    end
    if (quality or 0) < Get("minQuality") then return end
    local key = "item:" .. link
    local prev = Previous(key)
    count = count + (prev and prev.count or 0)
    local color = ITEM_QUALITY_COLORS[quality or 1] or ITEM_QUALITY_COLORS[1]
    local text = color.hex .. name .. "|r"
    if count > 1 then text = count .. "x " .. text end
    local sub
    if Get("showIlvl") and (classID == Enum.ItemClass.Weapon or classID == Enum.ItemClass.Armor) then
        local ilvl = C_Item.GetDetailedItemLevelInfo(link) or itemLevel
        if ilvl and ilvl > 0 then sub = EllesmereUI.Lf("ilvl: %d", ilvl) end
    end
    local value
    if Get("showPrice") and sellPrice and sellPrice > 0 then value = FormatMoney(sellPrice * count) end
    Push(key, { icon = icon, text = text, sub = sub, value = value, border = color, link = link, count = count })
end

local function ShowMoney(copper)
    local prev = Previous("money")
    copper = copper + (prev and prev.copper or 0)
    Push("money", { icon = MONEY_ICON, text = EllesmereUI.L("Money"), value = FormatMoney(copper), copper = copper })
end

local LegacyGetNumFactions = rawget(_G, "GetNumFactions")
local LegacyGetFactionInfo = rawget(_G, "GetFactionInfo")

-- Progress within the current standing for a faction by name, or nil when it
-- is not in the (expanded) reputation list.
local function FactionProgress(name)
    local C_Rep = C_Reputation
    if C_Rep and C_Rep.GetNumFactions and C_Rep.GetFactionDataByIndex then
        for i = 1, C_Rep.GetNumFactions() do
            local d = C_Rep.GetFactionDataByIndex(i)
            if d and d.name == name and d.nextReactionThreshold then
                return d.currentStanding - d.currentReactionThreshold, d.nextReactionThreshold - d.currentReactionThreshold
            end
        end
    elseif LegacyGetNumFactions and LegacyGetFactionInfo then
        for i = 1, LegacyGetNumFactions() do
            local n, _, _, barMin, barMax, barValue = LegacyGetFactionInfo(i)
            if n == name and barMax then return barValue - barMin, barMax - barMin end
        end
    end
end

local function ShowReputation(faction, delta)
    local key = "rep:" .. faction
    local prev = Previous(key)
    delta = delta + (prev and prev.delta or 0)
    local text = (delta >= 0 and "|cff00ff00+" or "|cffff4040") .. delta .. "|r " .. faction
    local cur, max = FactionProgress(faction)
    if cur then text = text .. string.format(" (%s / %s)", BreakUpLargeNumbers(cur), BreakUpLargeNumbers(max)) end
    Push(key, { icon = REP_ICON, text = text, delta = delta })
end

local function ShowCurrency(id, change)
    local info = C_CurrencyInfo.GetCurrencyInfo(id)
    if not (info and info.name) then return end
    local key = "currency:" .. id
    local prev = Previous(key)
    change = change + (prev and prev.change or 0)
    local text = change .. "x " .. info.name
    local quantity = info.quantity or 0
    local total = BreakUpLargeNumbers(quantity)
    if info.maxQuantity and info.maxQuantity > 0 then
        local capped = quantity >= info.maxQuantity
        total = (capped and "|cffff4040" or "") .. total .. " / " .. BreakUpLargeNumbers(info.maxQuantity) .. (capped and "|r" or "")
    end
    Push(key, { icon = info.iconFileID, text = text .. " (" .. total .. ")", change = change })
end

local LegacyGetNumSkillLines = rawget(_G, "GetNumSkillLines")
local LegacyGetSkillLineInfo = rawget(_G, "GetSkillLineInfo")

local function SkillMax(name)
    if not (LegacyGetNumSkillLines and LegacyGetSkillLineInfo) then return end
    for i = 1, LegacyGetNumSkillLines() do
        local n, isHeader, _, _, _, _, maxRank = LegacyGetSkillLineInfo(i)
        if n == name and not isHeader then return maxRank end
    end
end

local function ShowSkill(skill, rank)
    local max = SkillMax(skill)
    local text = skill .. " |cffffffff" .. rank .. (max and max > 0 and (" / " .. max) or "") .. "|r"
    Push("skill:" .. skill, { icon = SKILL_ICON, text = text })
end

-- Own loot only: the *_SELF lines. Single-item formats first take the link,
-- multiple-item formats the link and the count.
local ITEM_KEYS = {
    "LOOT_ITEM_SELF_MULTIPLE", "LOOT_ITEM_SELF",
    "LOOT_ITEM_PUSHED_SELF_MULTIPLE", "LOOT_ITEM_PUSHED_SELF",
    "LOOT_ITEM_BONUS_ROLL_SELF_MULTIPLE", "LOOT_ITEM_BONUS_ROLL_SELF",
}

local function OnLoot(text)
    for _, key in ipairs(ITEM_KEYS) do
        local link, count = Match(key, text)
        if link then
            if link:find("|Hitem:", 1, true) then ShowItem(link, tonumber(count) or 1) end
            return
        end
    end
end

-- Money lines spell out each coin with the client's own "%d Gold" etc.
local COIN_KEYS = { GOLD_AMOUNT = 10000, SILVER_AMOUNT = 100, COPPER_AMOUNT = 1 }
local function OnMoney(text)
    local copper = 0
    for key, mult in pairs(COIN_KEYS) do
        local c = Matcher(key, false)
        local n = c and text:match(c.pat)
        if n then copper = copper + tonumber(n) * mult end
    end
    if copper > 0 then ShowMoney(copper) end
end

local function OnFaction(text)
    local faction, amount = Match("FACTION_STANDING_INCREASED", text)
    if faction then return ShowReputation(faction, tonumber(amount)) end
    faction, amount = Match("FACTION_STANDING_DECREASED", text)
    if faction then return ShowReputation(faction, -tonumber(amount)) end
end

local function OnSkill(text)
    local skill, rank = Match("SKILL_RANK_UP", text)
    if skill then ShowSkill(skill, tonumber(rank)) end
end

local CHAT_EVENTS = {
    CHAT_MSG_LOOT = { setting = "items", handler = OnLoot },
    CHAT_MSG_MONEY = { setting = "money", handler = OnMoney },
    CHAT_MSG_COMBAT_FACTION_CHANGE = { setting = "reputation", handler = OnFaction },
    CHAT_MSG_SKILL = { setting = "skills", handler = OnSkill },
}

local function OnEvent(_, event, ...)
    local chat = CHAT_EVENTS[event]
    if chat then
        local text = PlainString((...))
        if text then chat.handler(text) end
    elseif event == "CURRENCY_DISPLAY_UPDATE" then
        local id, _, change = ...
        id, change = PlainNumber(id), PlainNumber(change)
        if id and change and change > 0 then ShowCurrency(id, change) end
    end
end

-------------------------------------------------------------------------------
--  Setup
-------------------------------------------------------------------------------
local DEFAULT_POS = { point = "BOTTOMRIGHT", relPoint = "BOTTOMRIGHT", x = -320, y = 260 }
local function ApplyPosition()
    local pos = Read().pos
    if not (pos and pos.point) then pos = DEFAULT_POS end
    anchor:ClearAllPoints()
    anchor:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
end

local function ApplyStyle()
    if not anchor then return end
    anchor:SetSize(Get("width"), AnchorHeight())
    for _, r in ipairs(pool) do StyleRow(r) end
    for _, r in ipairs(active) do
        StyleRow(r)
        Fill(r)
    end
    while #active > Get("maxRows") do Release(active[#active]) end
    Layout()
end

local function CreateAnchor()
    if anchor then return end
    anchor = CreateFrame("Frame", nil, UIParent)
    anchor:SetFrameStrata("MEDIUM")
    ApplyStyle()
    ApplyPosition()
end

local function ClearRows()
    while active[1] do Release(active[1]) end
end

local function Apply()
    if events then events:UnregisterAllEvents() end
    if not Enabled() then
        if anchor then ClearRows() end
        return
    end
    CreateAnchor()
    if not events then
        events = CreateFrame("Frame")
        events:SetScript("OnEvent", OnEvent)
    end
    for event, chat in pairs(CHAT_EVENTS) do
        if Get(chat.setting) then events:RegisterEvent(event) end
    end
    if Get("currency") then events:RegisterEvent("CURRENCY_DISPLAY_UPDATE") end
end

-- A sample of every enabled source; the items are classic ones of three
-- qualities. The rows fade like real ones.
local PREVIEW_ITEMS = { { 19019, 1 }, { 4306, 5 }, { 14047, 12 } }
local function Preview()
    if not Enabled() then return end
    CreateAnchor()
    ClearRows()
    if Get("skills") then ShowSkill(EllesmereUI.L("Swords"), 42) end
    if Get("reputation") then
        local faction = UnitFactionGroup("player") == "Horde" and "Orgrimmar" or "Stormwind"
        ShowReputation(faction, 250)
    end
    if Get("money") then ShowMoney(12345) end
    if Get("items") then
        for _, it in ipairs(PREVIEW_ITEMS) do
            local _, link = C_Item.GetItemInfo(it[1])
            if link then
                ShowItem(link, it[2])
            else
                Item:CreateFromItemID(it[1]):ContinueOnItemLoad(function()
                    local _, l = C_Item.GetItemInfo(it[1])
                    if l then ShowItem(l, it[2]) end
                end)
            end
        end
    end
end

-- Options-page entry points.
EllesmereUI._LootFeed = {
    Get = Get,
    Cfg = Cfg,
    Apply = Apply,
    ApplyStyle = ApplyStyle,
    ApplyPosition = function() if anchor then ApplyPosition() end end,
    Preview = Preview,
}

local function Resized()
    ApplyStyle()
    if EllesmereUI._unlockActive and EllesmereUI.RepositionBarToMover then
        EllesmereUI.RepositionBarToMover("EUI_LootFeed")
    end
end

local function RegisterUnlock()
    local MK = EllesmereUI.MakeUnlockElement
    local PPs = EllesmereUI.PP
    EllesmereUI:RegisterUnlockElements({
        MK({
            key      = "EUI_LootFeed",
            label    = "Loot Feed",
            group    = "Forever Essentials",
            order    = 732,
            isHidden = function() return not Enabled() end,
            -- Nothing is built while the feature is off.
            getFrame = function()
                if not Enabled() then return nil end
                CreateAnchor()
                return anchor
            end,
            -- Height follows Max Rows and Row Height: width only.
            getSize = function() return Get("width"), AnchorHeight() end,
            setWidth = function(_, w)
                Cfg().width = math.max(150, PPs.Snap(w))
                Resized()
            end,
            savePos = function(_, point, relPoint, x, y)
                if not point then return end
                Cfg().pos = { point = point, relPoint = relPoint, x = x, y = y }
                if anchor and not EllesmereUI._unlockActive then ApplyPosition() end
            end,
            loadPos = function()
                local pos = Read().pos
                return pos and pos.point and pos or DEFAULT_POS
            end,
            clearPos = function()
                Cfg().pos = nil
                if anchor then ApplyPosition() end
            end,
            applyPos = function()
                if not Enabled() then return end
                CreateAnchor()
                ApplyPosition()
            end,
        }),
    }, "EllesmereUIForeverEssentials")
end

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()
    Apply()
    RegisterUnlock()
end)
