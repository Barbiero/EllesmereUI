if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EUI_CooldownManager_BarGlowConditions.lua
--  Bar Glows page rows for the per-glow conditions (runtime:
--  EllesmereUICdmBarGlowConditions.lua). A glow entry on the page reads:
--
--    When (icon) Fingers of Frost is [Active v]  | And [(icon) Brain Freeze v] is [Missing v]  [toggle]
--    At Stacks      (gear) [toggle]              | Glow Type       [Pixel Glow v]
--    Only In Combat [toggle]                     | Hero Talent     [Any v]
--    Glow Color     ...                          | (icon) [Duplicate] [Remove]
--
--  Left of row 1 is the glow's own Glow When (entry.mode). The And toggle is
--  entry.andMode = "and" | nil (its buff and state grey out while off); the
--  second buff and its state are entry.conditions[1]. Each glow starts with a
--  collapse bar (collapsed: buff icon + name only, entry.collapsed); Duplicate
--  inserts a full copy right below.
--  Frames are built with the page; nothing exists until it is opened.
-------------------------------------------------------------------------------
local ns = EllesmereUI._ModuleNS["EllesmereUICooldownManager"]
if not ns then return end

local function Cond(entry)
    if type(entry.conditions) ~= "table" then entry.conditions = {} end
    if type(entry.conditions[1]) ~= "table" then entry.conditions[1] = {} end
    return entry.conditions[1]
end

local function SpellLabel(sid)
    sid = tonumber(sid)
    if not sid or sid <= 0 then return EllesmereUI.L("Choose Buff"), nil end
    local info = C_Spell.GetSpellInfo(sid)
    return (info and info.name) or ("Spell " .. sid), info and info.iconID
end

-- A spell icon that shows the spell's tooltip on hover.
function ns.BarGlowSpellIcon(parent, size, spellID)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(size, size)
    f:SetFrameLevel(parent:GetFrameLevel() + 3)
    f.tex = f:CreateTexture(nil, "ARTWORK")
    f.tex:SetAllPoints()
    f.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local sid = tonumber(spellID)
    local info = sid and sid > 0 and C_Spell.GetSpellInfo(sid)
    if info and info.iconID then f.tex:SetTexture(info.iconID) end
    f:EnableMouse(true)
    f:SetScript("OnEnter", function(self)
        if not (sid and sid > 0) then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetSpellByID(sid)
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return f
end

-------------------------------------------------------------------------------
--  Single-choice buff picker (the look of the Bar Glows add-glow menu):
--  tracked buffs, then untracked, then tracked bars.
-------------------------------------------------------------------------------
local picker

local function ShowPicker(anchor, currentSid, onPick)
    if picker then picker:Hide() end
    local tracked, untracked = {}, {}
    if ns.GetAllCDMBuffSpells then tracked, untracked = ns.GetAllCDMBuffSpells() end
    local bars = ns.GetTrackedBarSpells and ns.GetTrackedBarSpells() or {}

    local mBgR, mBgG, mBgB = EllesmereUI.DD_BG_R, EllesmereUI.DD_BG_G, EllesmereUI.DD_BG_B
    local mBgA, mBrdA = EllesmereUI.DD_BG_HA, EllesmereUI.DD_BRD_A
    local hlA = EllesmereUI.DD_ITEM_HL_A
    local tR, tG, tB, tA = EllesmereUI.TEXT_DIM_R, EllesmereUI.TEXT_DIM_G, EllesmereUI.TEXT_DIM_B, EllesmereUI.TEXT_DIM_A
    local ACCENT = EllesmereUI.ELLESMERE_GREEN
    local font = EllesmereUI.GetFontPath and EllesmereUI.GetFontPath() or STANDARD_TEXT_FONT
    local MENU_W, ITEM_H, MAX_H = 240, 26, 300

    local menu = CreateFrame("Frame", nil, UIParent)
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    menu:SetFrameLevel(300)
    menu:SetClampedToScreen(true)
    menu:SetSize(MENU_W, 10)
    local bg = menu:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(mBgR, mBgG, mBgB, mBgA)
    EllesmereUI.MakeBorder(menu, 1, 1, 1, mBrdA, EllesmereUI.PP)

    local inner = CreateFrame("Frame", nil, menu)
    inner:SetWidth(MENU_W)
    inner:SetPoint("TOPLEFT")
    local mH = 4

    local function Item(sp)
        local sid = tonumber(sp.spellID)
        if not sid or sid <= 0 then return end
        local item = CreateFrame("Button", nil, inner)
        item:SetHeight(ITEM_H)
        item:SetPoint("TOPLEFT", inner, "TOPLEFT", 1, -mH)
        item:SetPoint("TOPRIGHT", inner, "TOPRIGHT", -1, -mH)
        item:SetFrameLevel(menu:GetFrameLevel() + 2)

        -- Selected marker: the same box + accent fill as the add-glow menu.
        local cb = CreateFrame("Frame", nil, item)
        cb:SetSize(14, 14)
        cb:SetPoint("LEFT", item, "LEFT", 8, 0)
        local cbBg = cb:CreateTexture(nil, "BACKGROUND")
        cbBg:SetAllPoints()
        cbBg:SetColorTexture(0.12, 0.12, 0.14, 1)
        local selected = (sid == tonumber(currentSid))
        EllesmereUI.MakeBorder(cb, selected and ACCENT.r or 0.25, selected and ACCENT.g or 0.25, selected and ACCENT.b or 0.28, selected and 0.8 or 0.6, EllesmereUI.PanelPP)
        if selected then
            local fill = cb:CreateTexture(nil, "ARTWORK")
            fill:SetPoint("TOPLEFT", cb, "TOPLEFT", 3, -3)
            fill:SetPoint("BOTTOMRIGHT", cb, "BOTTOMRIGHT", -3, 3)
            fill:SetColorTexture(ACCENT.r, ACCENT.g, ACCENT.b, 1)
        end

        local ico = item:CreateTexture(nil, "ARTWORK")
        ico:SetSize(ITEM_H - 4, ITEM_H - 4)
        ico:SetPoint("RIGHT", item, "RIGHT", -6, 0)
        ico:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        local name, icon = SpellLabel(sid)
        if sp.icon then icon = sp.icon end
        if icon then ico:SetTexture(icon) end

        local lbl = item:CreateFontString(nil, "OVERLAY")
        lbl:SetFont(font, 11, "")
        lbl:SetPoint("LEFT", cb, "RIGHT", 6, 0)
        lbl:SetPoint("RIGHT", ico, "LEFT", -4, 0)
        lbl:SetJustifyH("LEFT")
        lbl:SetWordWrap(false)
        lbl:SetText(sp.name or name)
        lbl:SetTextColor(tR, tG, tB, tA)

        local hl = item:CreateTexture(nil, "ARTWORK", nil, -1)
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0)
        item:SetScript("OnEnter", function() lbl:SetTextColor(1, 1, 1, 1); hl:SetColorTexture(1, 1, 1, hlA) end)
        item:SetScript("OnLeave", function() lbl:SetTextColor(tR, tG, tB, tA); hl:SetColorTexture(1, 1, 1, 0) end)
        item:SetScript("OnClick", function()
            menu:Hide()
            onPick(sid)
        end)
        mH = mH + ITEM_H
    end

    local function Divider()
        local div = inner:CreateTexture(nil, "ARTWORK")
        div:SetHeight(1)
        div:SetColorTexture(1, 1, 1, 0.10)
        div:SetPoint("TOPLEFT", inner, "TOPLEFT", 1, -mH - 4)
        div:SetPoint("TOPRIGHT", inner, "TOPRIGHT", -1, -mH - 4)
        mH = mH + 9
    end

    for _, sp in ipairs(tracked or {}) do Item(sp) end
    if #(tracked or {}) > 0 and #(untracked or {}) > 0 then Divider() end
    for _, sp in ipairs(untracked or {}) do Item(sp) end
    if #bars > 0 then
        if #(tracked or {}) > 0 or #(untracked or {}) > 0 then Divider() end
        for _, sp in ipairs(bars) do Item(sp) end
    end
    if mH <= 4 then
        local none = inner:CreateFontString(nil, "OVERLAY")
        none:SetFont(font, 11, "")
        none:SetTextColor(tR, tG, tB, tA)
        none:SetPoint("TOPLEFT", inner, "TOPLEFT", 10, -8)
        none:SetText(EllesmereUI.L("No Cooldown Manager buffs to choose from."))
        mH = 30
    end

    local totalH = mH + 4
    inner:SetHeight(totalH)
    if totalH > MAX_H then
        menu:SetHeight(MAX_H)
        local sf = CreateFrame("ScrollFrame", nil, menu)
        sf:SetPoint("TOPLEFT")
        sf:SetPoint("BOTTOMRIGHT")
        sf:SetFrameLevel(menu:GetFrameLevel() + 1)
        sf:EnableMouseWheel(true)
        sf:SetScrollChild(inner)
        local pos, maxScroll = 0, totalH - MAX_H
        sf:SetScript("OnMouseWheel", function(_, delta)
            pos = math.max(0, math.min(maxScroll, pos - delta * 30))
            sf:SetVerticalScroll(pos)
        end)
    else
        menu:SetHeight(totalH)
    end

    menu:SetPoint("TOP", anchor, "BOTTOM", 0, -2)
    menu:SetScript("OnUpdate", function(m)
        if not m:IsMouseOver() and not anchor:IsMouseOver() and IsMouseButtonDown("LeftButton") then
            m:Hide()
        end
    end)
    menu:HookScript("OnHide", function(m) m:SetScript("OnUpdate", nil) end)
    menu:Show()
    picker = menu
end

-- Compact inline dropdown for the Glow When row (the options dropdown look:
-- flat block, 1px border, pointing arrow, label left).
local function InlineDrop(parent, w, h, font, size)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, h)
    b:SetFrameLevel(parent:GetFrameLevel() + 3)
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(EllesmereUI.DD_BG_R, EllesmereUI.DD_BG_G, EllesmereUI.DD_BG_B, EllesmereUI.DD_BG_A or 0.9)
    EllesmereUI.MakeBorder(b, 1, 1, 1, EllesmereUI.DD_BRD_A, EllesmereUI.PanelPP)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.05)
    b.arrow = b:CreateTexture(nil, "OVERLAY")
    b.arrow:SetAtlas("Azerite-PointingArrow")
    b.arrow:SetSize(11, 8)
    b.arrow:SetPoint("RIGHT", b, "RIGHT", -7, 0)
    b.label = b:CreateFontString(nil, "OVERLAY")
    b.label:SetFont(font, size, "")
    b.label:SetPoint("LEFT", b, "LEFT", 8, 0)
    b.label:SetPoint("RIGHT", b.arrow, "LEFT", -4, 0)
    b.label:SetJustifyH("LEFT")
    b.label:SetWordWrap(false)
    return b
end

-- Row 1 of a glow, two columns:
--   left:  When (icon) Fingers of Frost is [Active v]
--   right: And [(icon) Brain Freeze v] is [Missing v]                [toggle]
-- The right column is a standard toggle row labelled "And"; while it is off
-- the buff picker and its state grey out. Returns the new y.
function ns.BuildBarGlowWhenRow(W, parent, y, entry, onChange)
    local c = Cond(entry)
    local Paint  -- forward: the toggle repaints the right column

    local row, h = W:DualRow(parent, y,
        { type = "label", text = "" },
        { type = "toggle", text = "And",
          tooltip = "Also require a second buff to be active (or missing) for this glow. For an \"or\", add another glow to the same button.",
          getValue = function() return entry.andMode == "and" end,
          setValue = function(v)
              entry.andMode = v and "and" or nil
              if Paint then Paint() end
              if onChange then onChange() end
          end })
    y = y - h
    if EllesmereUI._prebuilding then return y end

    local left, right = row._leftRegion, row._rightRegion
    local lRef = left and left._label
    local rRef = right and right._label
    local font, size = STANDARD_TEXT_FONT, 13
    if lRef and lRef.GetFont then
        local f, s = lRef:GetFont()
        if f then font, size = f, s or size end
    end
    local r, g, b = 1, 1, 1
    if lRef and lRef.GetTextColor then r, g, b = lRef:GetTextColor() end
    local CTL_H = 30   -- the options dropdown height (Glow Type)

    local function Menu(anchor, items)
        EllesmereUI.ShowContextMenu(anchor, items, { below = true, minWidth = anchor:GetWidth() })
    end

    -- Left column ------------------------------------------------------------
    local lx = CreateFrame("Frame", nil, left or row)
    lx:SetAllPoints()
    lx:SetFrameLevel((left or row):GetFrameLevel() + 2)
    local prev
    local function Place(w, gap)
        w:ClearAllPoints()
        if prev then
            w:SetPoint("LEFT", prev, "RIGHT", gap or 8, 0)
        elseif lRef then
            w:SetPoint("LEFT", lRef, "LEFT", 0, 0)
        else
            w:SetPoint("LEFT", lx, "LEFT", 22, 0)
        end
        prev = w
    end
    local function Word(host, text)
        local fs = host:CreateFontString(nil, "OVERLAY")
        fs:SetFont(font, size, "")
        fs:SetTextColor(r, g, b, 1)
        fs:SetText(text)
        return fs
    end

    local ownName, ownIcon = SpellLabel(entry.spellID)
    Place(Word(lx, EllesmereUI.L("When")))
    if ownIcon then
        Place(ns.BarGlowSpellIcon(lx, 32, entry.spellID), 8)
    end
    Place(Word(lx, ((tonumber(entry.spellID) or 0) > 0 and ownName or "buff") .. " " .. EllesmereUI.L("is")))
    local mainDrop = InlineDrop(lx, 96, CTL_H, font, size - 1)
    Place(mainDrop)

    -- Right column: after the "And" label, before the toggle -----------------
    local rx = CreateFrame("Frame", nil, right or row)
    rx:SetAllPoints()
    rx:SetFrameLevel((right or row):GetFrameLevel() + 2)
    local buffBtn = InlineDrop(rx, 170, CTL_H, font, size - 1)
    buffBtn.icon = buffBtn:CreateTexture(nil, "ARTWORK")
    buffBtn.icon:SetSize(CTL_H - 6, CTL_H - 6)
    buffBtn.icon:SetPoint("LEFT", buffBtn, "LEFT", 3, 0)
    buffBtn.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    if rRef then
        buffBtn:SetPoint("LEFT", rRef, "RIGHT", 10, 0)
    else
        buffBtn:SetPoint("LEFT", rx, "LEFT", 60, 0)
    end
    local isWord = Word(rx, EllesmereUI.L("is"))
    isWord:SetPoint("LEFT", buffBtn, "RIGHT", 8, 0)
    local stateDrop = InlineDrop(rx, 96, CTL_H, font, size - 1)
    stateDrop:SetPoint("LEFT", isWord, "RIGHT", 8, 0)

    local ACTIVE, MISSING = EllesmereUI.L("Active"), EllesmereUI.L("Missing")
    Paint = function()
        mainDrop.label:SetText((entry.mode == "MISSING") and MISSING or ACTIVE)
        local name, icon = SpellLabel(c.spellID)
        buffBtn.label:SetText(name)
        buffBtn.label:ClearAllPoints()
        if icon then
            buffBtn.icon:SetTexture(icon)
            buffBtn.icon:Show()
            buffBtn.label:SetPoint("LEFT", buffBtn.icon, "RIGHT", 6, 0)
        else
            buffBtn.icon:Hide()
            buffBtn.label:SetPoint("LEFT", buffBtn, "LEFT", 8, 0)
        end
        buffBtn.label:SetPoint("RIGHT", buffBtn.arrow, "LEFT", -4, 0)
        stateDrop.label:SetText(c.state == "missing" and MISSING or ACTIVE)
        local on = entry.andMode == "and"
        for _, part in ipairs({ buffBtn, isWord, stateDrop }) do
            part:SetAlpha(on and 1 or 0.3)
            if part.EnableMouse then part:EnableMouse(on) end
        end
        -- The "And" label greys with them (the switch itself stays live).
        if rRef then rRef:SetAlpha(on and 1 or 0.3) end
    end

    mainDrop:SetScript("OnClick", function(self)
        Menu(self, {
            { text = ACTIVE, isActive = entry.mode ~= "MISSING",
              onClick = function()
                  entry.mode = "ACTIVE"; Paint()
                  if onChange then onChange() end
                  EllesmereUI:RefreshPage()
              end },
            { text = MISSING, isActive = entry.mode == "MISSING",
              onClick = function()
                  entry.mode = "MISSING"; Paint()
                  if onChange then onChange() end
                  EllesmereUI:RefreshPage()
              end },
        })
    end)
    buffBtn:SetScript("OnClick", function(self)
        ShowPicker(self, c.spellID, function(sid)
            c.spellID = sid
            Paint()
            if onChange then onChange() end
        end)
    end)
    stateDrop:SetScript("OnClick", function(self)
        Menu(self, {
            { text = ACTIVE, isActive = c.state ~= "missing",
              onClick = function() c.state = nil; Paint(); if onChange then onChange() end end },
            { text = MISSING, isActive = c.state == "missing",
              onClick = function() c.state = "missing"; Paint(); if onChange then onChange() end end },
        })
    end)
    Paint()
    return y
end

-- Only In Combat | Hero Talent (the current spec's hero trees; glows are
-- saved per spec). Returns the new y.
function ns.BuildBarGlowCombatRow(W, parent, y, entry, onChange)
    local heroValues, heroOrder = { any = EllesmereUI.L("Any") }, { "any" }
    for _, t in ipairs(ns.BarGlowHeroTrees and ns.BarGlowHeroTrees() or {}) do
        local key = tostring(t.id)
        heroValues[key] = t.name
        heroOrder[#heroOrder + 1] = key
    end
    local cur = tonumber(entry.heroTree)
    if cur and not heroValues[tostring(cur)] then
        heroValues[tostring(cur)] = "Hero Tree " .. cur
        heroOrder[#heroOrder + 1] = tostring(cur)
    end
    local _, h = W:DualRow(parent, y,
        { type = "toggle", text = "Only In Combat",
          getValue = function() return entry.onlyInCombat == true end,
          setValue = function(v)
              entry.onlyInCombat = v or nil
              if onChange then onChange() end
          end },
        { type = "dropdown", text = "Hero Talent",
          tooltip = "Only use this glow while the chosen hero talent tree is active. Any: always.",
          values = heroValues, order = heroOrder,
          getValue = function()
              local t = tonumber(entry.heroTree)
              return t and tostring(t) or "any"
          end,
          setValue = function(v)
              entry.heroTree = (v ~= "any") and tonumber(v) or nil
              if onChange then onChange() end
          end })
    return y - h
end

-- "Duplicate" left of a glow's Remove button: inserts a full copy of the glow
-- (buff, style, colour, stacks, And condition, hero talent) right below it, so
-- variants of the same buff (e.g. one per hero tree) start from the original.
-- Returns the button so the buff icon can sit to its left.
function ns.BarGlowDuplicateButton(region, removeBtn, buffList, index, onDone)
    if EllesmereUI._prebuilding or not (region and removeBtn and buffList) then return nil end
    local PP = EllesmereUI.PanelPP or EllesmereUI.PP
    local b = CreateFrame("Button", nil, region)
    PP.Size(b, 110, removeBtn:GetHeight())
    b:SetFrameLevel(removeBtn:GetFrameLevel())
    b:SetPoint("RIGHT", removeBtn, "LEFT", -8, 0)
    EllesmereUI.MakeStyledButton(b, EllesmereUI.L("Duplicate"), 13, EllesmereUI.RB_COLOURS, function()
        local src = buffList[index]
        if type(src) ~= "table" then return end
        local copy = CopyTable(src)
        copy.collapsed = nil   -- the copy opens expanded
        table.insert(buffList, index + 1, copy)
        if onDone then onDone() end
    end)
    return b
end

-- Bar Glows button preview: the CDM bar's live icon width as it appears on
-- screen (covers width/height match and the UI scale), converted into the
-- preview panel's scale. nil when no icon is laid out yet (the page then uses
-- the stored iconSize).
function ns.BarGlowPreviewIconSize(icons, previewParent)
    if type(icons) ~= "table" then return nil end
    local ps = previewParent and previewParent.GetEffectiveScale and previewParent:GetEffectiveScale()
    for i = 1, #icons do
        local f = icons[i]
        if f and f.GetWidth then
            local w = f:GetWidth()
            if w and not (issecretvalue and issecretvalue(w)) and w > 1 then
                local es = f:GetEffectiveScale()
                if es and ps and ps > 0 then w = w * es / ps end
                return math.floor(w + 0.5)
            end
        end
    end
    return nil
end

-- Collapse bar across the top of each glow, the same height either way.
-- Expanded: a down arrow above the glow's rows. Collapsed (entry.collapsed =
-- true, saved): a right arrow, the buff icon and its name, and the rows are
-- skipped. A click flips it and rebuilds the page. The hidden search pre-build
-- and an active search always build every row. Returns the new y and whether
-- the caller should build the rows.
local ARROW_DOWN  = "Interface\\AddOns\\EllesmereUI\\media\\icons\\eui-arrow-down3.png"
local ARROW_RIGHT = "Interface\\AddOns\\EllesmereUI\\media\\icons\\eui-arrow-right.png"

function ns.BuildBarGlowHeader(parent, y, entry, aIdx)
    if EllesmereUI._prebuilding or EllesmereUI._lessCommonSearchActive then return y, true end
    local collapsed = entry.collapsed == true
    if aIdx > 1 then y = y - 8 end
    local H = 38
    local pad = EllesmereUI.CONTENT_PAD or 20
    local bar = CreateFrame("Button", nil, parent)
    bar:SetPoint("TOPLEFT", parent, "TOPLEFT", pad, y)
    bar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -pad, y)
    bar:SetHeight(H)
    bar:SetFrameLevel(parent:GetFrameLevel() + 5)
    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(1, 1, 1, 0.04)

    -- The arrow drawn three times, 1px apart, for a bolder stroke than the icon art.
    local arrows = {}
    for i, off in ipairs({ { 0, 0 }, { 1, 0 }, { 0, -1 } }) do
        local t = bar:CreateTexture(nil, "OVERLAY")
        t:SetSize(16, 16)
        t:SetTexture(collapsed and ARROW_RIGHT or ARROW_DOWN)
        t:SetPoint("LEFT", bar, "LEFT", 10 + off[1], off[2])
        arrows[i] = t
    end
    local arrow = arrows[1]
    local function PaintArrow(r, g, b, a)
        for _, t in ipairs(arrows) do t:SetVertexColor(r, g, b); t:SetAlpha(a) end
    end
    PaintArrow(1, 1, 1, 0.7)

    local title
    if collapsed then
        local ico = ns.BarGlowSpellIcon(bar, 26, entry.spellID)
        ico:SetPoint("LEFT", arrow, "RIGHT", 11, 0)
        local name = SpellLabel(entry.spellID)
        title = EllesmereUI.MakeFont(bar, 13, nil, 1, 1, 1)
        title:SetPoint("LEFT", ico, "RIGHT", 10, 0)
        title:SetText(name)
    end

    local EG = EllesmereUI.ELLESMERE_GREEN
    bar:SetScript("OnEnter", function()
        bg:SetColorTexture(1, 1, 1, 0.08)
        PaintArrow(EG.r, EG.g, EG.b, 1)
        if title then title:SetTextColor(EG.r, EG.g, EG.b) end
    end)
    bar:SetScript("OnLeave", function()
        bg:SetColorTexture(1, 1, 1, 0.04)
        PaintArrow(1, 1, 1, 0.7)
        if title then title:SetTextColor(1, 1, 1) end
    end)
    bar:SetScript("OnClick", function()
        entry.collapsed = (not collapsed) and true or nil
        EllesmereUI:RefreshPage(true)
    end)
    return y - H - (collapsed and 0 or 4), not collapsed
end
