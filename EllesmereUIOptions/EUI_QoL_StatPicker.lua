-- "Stats to Show" picker for the Forever OG secondary-stats HUD: a columnar, grouped
-- multi-select driven by the stat catalog EllesmereUIQoL exposes
-- (EllesmereUI._secondaryStatsCatalog). A non-modal floating panel (no screen dimmer),
-- anchored to its opener and closed on an outside click -- the same feel as EllesmereUI's
-- cog menus. Uses EllesmereUI's native checkbox (BuildCheckboxControl) + font. Forever only.
local addonName, ns = ...
if EUI_CLIENT_BLOCKED then return end
if not (EllesmereUI and EllesmereUI.IS_FOREVER) then return end

local EG   = EllesmereUI.ELLESMERE_GREEN or { r = 0.18, g = 0.80, b = 0.44 }
local function Font()
    return (EllesmereUI.GetFontPath and EllesmereUI.GetFontPath())
        or EllesmereUI._font or "Interface\\AddOns\\EllesmereUI\\media\\fonts\\Expressway.ttf"
end

--------------------------------------------------------------------------------
--  Shown/hidden state (mirrors the render + options logic in EllesmereUIQoL):
--    hidden[key] == true -> hidden; == false -> shown (explicit, default-off stats);
--    == nil -> default (shown unless the stat is default-off).
--------------------------------------------------------------------------------
local function GetHidden()
    local h = EllesmereUI.QoLExtrasGet("secondaryStatsHidden")
    return type(h) == "table" and h or nil
end
local defaultOffCache
local function DefaultOff()
    if not defaultOffCache and EllesmereUI._secondaryStatsMeta then
        local _, off = EllesmereUI._secondaryStatsMeta()
        defaultOffCache = off or {}
    end
    return defaultOffCache or {}
end
local function IsShown(key)
    local v = GetHidden() and GetHidden()[key]
    if v == true then return false end
    if v == false then return true end
    return not DefaultOff()[key]
end
local function SetShown(key, show)
    local old, hidden = GetHidden(), {}
    if old then for k, v in pairs(old) do hidden[k] = v end end
    if show then
        -- default-off stats need an explicit `false` (shown); default-on stats clear to nil.
        if DefaultOff()[key] then hidden[key] = false else hidden[key] = nil end
    else
        hidden[key] = true
    end
    EllesmereUI.QoLExtrasSet("secondaryStatsHidden", hidden)
    if EllesmereUI._applySecondaryStats then EllesmereUI._applySecondaryStats() end
end

--------------------------------------------------------------------------------
--  Layout (grouped columns)
--------------------------------------------------------------------------------
local NUM_COLS, COL_W, COL_GAP = 3, 200, 18
local PAD_L, PAD_R             = 24, 24
local CONTENT_TOP              = 92
local HEADER_H, ITEM_H         = 26, 24
local MAX_ITEMS                = 6
local GRP_BLOCK_H              = HEADER_H + MAX_ITEMS * ITEM_H
local GRP_GAP                  = 16
local BOTTOM_H                 = 66

-- Small text link (All / None / Check All): a label-only button with hover.
local function Link(parent, text, onClick)
    local b = CreateFrame("Button", nil, parent)
    local fs = b:CreateFontString(nil, "OVERLAY")
    fs:SetFont(Font(), 12, ""); fs:SetTextColor(1, 1, 1, 0.5); fs:SetText(text); fs:SetPoint("CENTER")
    b:SetSize(fs:GetStringWidth() + 6, 16)
    b:SetScript("OnEnter", function() fs:SetTextColor(1, 1, 1, 0.9) end)
    b:SetScript("OnLeave", function() fs:SetTextColor(1, 1, 1, 0.5) end)
    b:SetScript("OnClick", onClick)
    return b
end

--------------------------------------------------------------------------------
--  The floating panel (built once, then re-shown)
--------------------------------------------------------------------------------
local panel, RefreshAll
local checks = {}   -- stat key -> row (with ._apply)

local function MakeCheckRow(parent, key, label)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(COL_W, ITEM_H)
    local box, _, _, applyVisual = EllesmereUI.BuildCheckboxControl(row, row:GetFrameLevel() + 1)
    box:ClearAllPoints(); box:SetPoint("LEFT", row, "LEFT", 0, 0)
    local lbl = row:CreateFontString(nil, "OVERLAY")
    lbl:SetFont(Font(), 12, ""); lbl:SetTextColor(0.85, 0.85, 0.85, 1)
    lbl:SetPoint("LEFT", box, "RIGHT", 8, 0); lbl:SetText(label)
    row._apply = function() applyVisual(IsShown(key), row:IsMouseOver()) end
    row:SetScript("OnClick", function() SetShown(key, not IsShown(key)); RefreshAll() end)
    row:SetScript("OnEnter", function() lbl:SetTextColor(1, 1, 1, 1); row._apply() end)
    row:SetScript("OnLeave", function() lbl:SetTextColor(0.85, 0.85, 0.85, 1); row._apply() end)
    checks[key] = row
    return row
end

local function Build()
    local catalog = EllesmereUI._secondaryStatsCatalog and EllesmereUI._secondaryStatsCatalog()
    if not catalog then return false end

    local grpRows = math.ceil(#catalog / NUM_COLS)
    local W = PAD_L + PAD_R + NUM_COLS * COL_W + (NUM_COLS - 1) * COL_GAP
    local H = CONTENT_TOP + grpRows * GRP_BLOCK_H + (grpRows - 1) * GRP_GAP + BOTTOM_H

    panel = CreateFrame("Frame", "EUIStatPickerPanel", UIParent)
    panel:SetFrameStrata("FULLSCREEN_DIALOG")   -- above the options window (DIALOG)
    panel:SetSize(W, H)
    panel:EnableMouse(true)
    panel:SetClampedToScreen(true)
    panel:Hide()

    local bg = panel:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); bg:SetColorTexture(0.06, 0.08, 0.10, 1)
    local function Edge()
        local t = panel:CreateTexture(nil, "BORDER"); t:SetColorTexture(1, 1, 1, 0.15)
        if t.SetSnapToPixelGrid then t:SetSnapToPixelGrid(false); t:SetTexelSnappingBias(0) end
        return t
    end
    local eT = Edge(); eT:SetPoint("TOPLEFT"); eT:SetPoint("TOPRIGHT"); eT:SetHeight(1)
    local eB = Edge(); eB:SetPoint("BOTTOMLEFT"); eB:SetPoint("BOTTOMRIGHT"); eB:SetHeight(1)
    local eL = Edge(); eL:SetPoint("TOPLEFT"); eL:SetPoint("BOTTOMLEFT"); eL:SetWidth(1)
    local eR = Edge(); eR:SetPoint("TOPRIGHT"); eR:SetPoint("BOTTOMRIGHT"); eR:SetWidth(1)

    local title = panel:CreateFontString(nil, "OVERLAY")
    title:SetFont(Font(), 18, ""); title:SetTextColor(1, 1, 1, 1)
    title:SetPoint("TOP", panel, "TOP", 0, -20)
    title:SetText(EllesmereUI.L and EllesmereUI.L("Stats to Show") or "Stats to Show")
    local sub = panel:CreateFontString(nil, "OVERLAY")
    sub:SetFont(Font(), 12, ""); sub:SetTextColor(1, 1, 1, 0.45)
    sub:SetPoint("TOP", title, "BOTTOM", 0, -6)
    sub:SetText("Pick which stats the on-screen block shows, grouped by type.")

    local function AllInCatalog(show)
        for _, g in ipairs(catalog) do for _, s in ipairs(g.stats) do SetShown(s.key, show) end end
        RefreshAll()
    end
    local checkAll = Link(panel, "Check All", function() AllInCatalog(true) end)
    checkAll:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD_L, -62)
    local sep = panel:CreateTexture(nil, "OVERLAY"); sep:SetColorTexture(1, 1, 1, 0.18); sep:SetSize(1, 12)
    sep:SetPoint("LEFT", checkAll, "RIGHT", 10, 0)
    local uncheckAll = Link(panel, "Uncheck All", function() AllInCatalog(false) end)
    uncheckAll:SetPoint("LEFT", checkAll, "RIGHT", 20, 0)

    for gi, g in ipairs(catalog) do
        local col    = (gi - 1) % NUM_COLS
        local grpRow = math.floor((gi - 1) / NUM_COLS)
        local colX   = PAD_L + col * (COL_W + COL_GAP)
        local grpY   = -CONTENT_TOP - grpRow * (GRP_BLOCK_H + GRP_GAP)

        local hdr = panel:CreateFontString(nil, "OVERLAY")
        hdr:SetFont(Font(), 13, ""); hdr:SetTextColor(EG.r, EG.g, EG.b, 1)
        hdr:SetPoint("TOPLEFT", panel, "TOPLEFT", colX, grpY); hdr:SetText(g.title)

        local gStats = g.stats
        local none = Link(panel, "None", function()
            for _, s in ipairs(gStats) do SetShown(s.key, false) end; RefreshAll()
        end)
        none:SetPoint("TOPRIGHT", panel, "TOPLEFT", colX + COL_W, grpY - 2)
        local all = Link(panel, "All", function()
            for _, s in ipairs(gStats) do SetShown(s.key, true) end; RefreshAll()
        end)
        all:SetPoint("RIGHT", none, "LEFT", -8, 0)

        local underline = panel:CreateTexture(nil, "ARTWORK")
        underline:SetColorTexture(EG.r, EG.g, EG.b, 0.35)
        underline:SetPoint("TOPLEFT", panel, "TOPLEFT", colX, grpY - HEADER_H + 8); underline:SetSize(COL_W, 1)

        for j, s in ipairs(gStats) do
            local row = MakeCheckRow(panel, s.key, s.label)
            row:SetPoint("TOPLEFT", panel, "TOPLEFT", colX, grpY - HEADER_H - (j - 1) * ITEM_H)
        end
    end

    local done = EllesmereUI.MakeActionButton(panel, Font(),
        EllesmereUI.L and EllesmereUI.L("Done") or "Done", EG.r, EG.g, EG.b, { w = 200 })
    done:SetPoint("BOTTOM", panel, "BOTTOM", 0, 16)
    done:SetScript("OnClick", function() panel:Hide() end)

    -- Non-modal close: poll for an outside left-click (CogPopup's technique -- no dimmer,
    -- the game stays interactive behind it).
    local wasDown = false
    panel:SetScript("OnUpdate", function(self)
        local down = IsMouseButtonDown("LeftButton")
        if down and not wasDown and not self:IsMouseOver() then self:Hide() end
        wasDown = down
    end)
    panel:EnableKeyboard(true)
    panel:SetScript("OnKeyDown", function(self, key)
        self:SetPropagateKeyboardInput(key ~= "ESCAPE")
        if key == "ESCAPE" then self:Hide() end
    end)

    RefreshAll = function()
        for _, row in pairs(checks) do row._apply() end
    end
    return true
end

function EllesmereUI._ShowStatPicker(anchor)
    defaultOffCache = nil   -- re-read in case the profile changed
    if not panel then
        if not Build() then return end
    end
    panel:ClearAllPoints()
    if anchor and anchor.GetBottom then
        panel:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -6)
    else
        panel:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
    RefreshAll()
    panel:Show()
    panel:Raise()
end
