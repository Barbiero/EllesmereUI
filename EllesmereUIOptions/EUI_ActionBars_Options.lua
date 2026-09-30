if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EUI_ActionBar_Options.lua
--  Registers the Action Bars module. All get/set calls go to EAB.db.profile.
-------------------------------------------------------------------------------
local ADDON_NAME = "EllesmereUIActionBars"
local ns = EllesmereUI._ModuleNS[ADDON_NAME]  -- module namespace (published by the module at its load)
if not ns then return end  -- module disabled: no options page
local EAB = ns.EAB
local VisibilityCompat = EAB and EAB.VisibilityCompat
-- Anchor dropdown for the three button texts (keybind / charges / macro name);
-- "default" = stock placement, stored as nil in the profile.
local TEXT_ANCHOR_LABELS = {
    default = "Default", TOPLEFT = "Top Left", TOP = "Top", TOPRIGHT = "Top Right",
    BOTTOMLEFT = "Bottom Left", BOTTOM = "Bottom", BOTTOMRIGHT = "Bottom Right",
}
local TEXT_ANCHOR_DROPDOWN_ORDER = { "default" }
for i, a in ipairs(EAB and EAB.TEXT_ANCHOR_ORDER or {}) do TEXT_ANCHOR_DROPDOWN_ORDER[i + 1] = a end


-- The registry offsets/shifts a border renders with when the user has set none
-- (the Border Options cog's shown Shift defaults; the Width/Height Offset row
-- resolves its own): its step's "actionbars" entry, scaled to an exact size
-- (EllesmereUI.BorderPx) the way ApplyBorderStyle scales it; px nil = the
-- step's own values, the legacy path.
local function ShownBorderDefaults(tex, sizeKey, step, px)
    local dox, doy, dsx, dsy = EllesmereUI.GetBorderDefaults("actionbars", tex, sizeKey)
    if px then
        local gamePP = EllesmereUI.PP
        local EDGE_MAP = EllesmereUI.BORDER_EDGE_MAP
        local f = (px * gamePP.mult) / (EDGE_MAP[step] or EDGE_MAP[1])
        dox, doy, dsx, dsy = gamePP.Snap(dox * f), gamePP.Snap(doy * f), gamePP.Snap(dsx * f), gamePP.Snap(dsy * f)
    end
    return dox, doy, dsx, dsy
end

-------------------------------------------------------------------------------
--  Section / page names  (edit here to rename everywhere)
-------------------------------------------------------------------------------
local PAGE_DISPLAY        = "Bar Display"
local PAGE_MENUBAGSXP     = "Menu, Bags & XP Bars"
local PAGE_ANIMATIONS     = "Bar Animations"
local SECTION_ICON_APPEARANCE = "ICONS"
local SECTION_LAYOUT      = "LAYOUT"
local SECTION_TEXT        = "TEXT"
local SECTION_VISIBILITY  = "VISIBILITY"

-- EllesmereUI is created by another addon in the suite; wait for it.
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_LOGIN")

    if not EllesmereUI or not EllesmereUI.RegisterModule then return end
    local PP = EllesmereUI.PanelPP
    if not EAB or not EAB.db then return end

    ---------------------------------------------------------------------------
    --  Local references from the addon namespace
    ---------------------------------------------------------------------------
    local BAR_DROPDOWN_VALUES = ns.BAR_DROPDOWN_VALUES
    local BAR_DROPDOWN_ORDER  = ns.BAR_DROPDOWN_ORDER
    local VISIBILITY_ONLY     = ns.VISIBILITY_ONLY
    local BAR_LOOKUP          = ns.BAR_LOOKUP
    local DATA_BAR            = ns.DATA_BAR or {}

    -- Filtered bar list for multi-edit: action bars only (no MicroBar/BagBar)
    local GROUP_BAR_ORDER = {}
    for _, key in ipairs(BAR_DROPDOWN_ORDER) do
        if not VISIBILITY_ONLY[key] then
            GROUP_BAR_ORDER[#GROUP_BAR_ORDER + 1] = key
        end
    end

    -- Bar enabled state; we control all bars, so default is true.
    local function IsBarEnabled(barKey)
        if not EAB or not EAB.db then return true end
        local s = EAB.db.profile.bars[barKey]
        if s and s.enabled ~= nil then return s.enabled end
        return true
    end

    local InCombatLockdown = InCombatLockdown
    local pcall = pcall
    local floor = math.floor
    local RANGE_INDICATOR = RANGE_INDICATOR or "\226\128\162"

    ---------------------------------------------------------------------------
    --  Helpers
    ---------------------------------------------------------------------------
    local _selectedBarKey = "MainBar"
    local function SelectedKey()
        return _selectedBarKey
    end

    local function SB()
        return EAB.db.profile.bars[SelectedKey()] or {}
    end

    local function IsVisOnly()
        return VISIBILITY_ONLY[SelectedKey()]
    end

    local function IsDataBar()
        return DATA_BAR[SelectedKey()]
    end

    -- First button of a bar (source of default size): our EABButton, else the
    -- native Blizzard button. nil for custom bars (Bar9/Bar10) which have no
    -- native button -- callers default the size; avoids concatenating a nil prefix.
    local function FirstBarButton(key)
        local eb = ns.barButtons and ns.barButtons[key]
        if eb and eb[1] then return eb[1] end
        local bi = BAR_LOOKUP[key]
        if bi and bi.buttonPrefix then return _G[bi.buttonPrefix .. "1"] end
        return nil
    end

    ---------------------------------------------------------------------------
    --  Ordered dropdown values for the bar selector
    ---------------------------------------------------------------------------
    local barLabels = {}
    local barOrder  = {}
    for _, key in ipairs(BAR_DROPDOWN_ORDER) do
        -- Micro/Bag/XP/Rep/Favor live on the "Menu, Bags & XP Bars" tab, not
        -- the Bar Display bar selector.
        if key ~= "MicroBar" and key ~= "BagBar" and key ~= "XPBar" and key ~= "RepBar" and key ~= "FavorBar" then
            barLabels[key] = BAR_DROPDOWN_VALUES[key]
            barOrder[#barOrder + 1] = key
        end
    end

    -- Unlock Mode "Element Options" pre-selects a bar before the Bar Display page
    -- builds (mirrors the unit-frame path): direct setter (already built) + pending
    -- value consumed at build time. Both ignore non-dropdown keys (Micro/Bag/XP/Rep)
    -- so the selector never blanks.
    EllesmereUI._setActionBarKey = function(key)
        if barLabels[key] then _selectedBarKey = key end
    end
    EllesmereUI._consumePendingActionBarSelect = function()
        local pending = EllesmereUI._pendingActionBarSelect
        EllesmereUI._pendingActionBarSelect = nil
        if pending and barLabels[pending] then _selectedBarKey = pending end
    end

    ---------------------------------------------------------------------------
    --  Edit Overlay System
    --  Non-draggable unlock-mode-style overlay at the real bar position during
    --  Single Bar Edit. XP/Rep: always when selected. BagBar/MicroBar: only
    --  when hidden or mouseover-fade.
    ---------------------------------------------------------------------------
    local EXTRA_BARS = ns.EXTRA_BARS or {}
    local editOverlayFrame = nil  -- reusable overlay frame

    local function GetEditOverlayTarget(barKey)
        -- Data bars: show overlay only if not using Blizzard data bars
        if DATA_BAR[barKey] then
            if EAB.db.profile.useBlizzardDataBars then return nil end
            local df = ns.dataBarFrames and ns.dataBarFrames[barKey]
            return df
        end
        -- BagBar / MicroBar: show only when hidden or mouseover
        if barKey == "BagBar" or barKey == "MicroBar" then
            local s = EAB.db.profile.bars[barKey]
            if s and (s.alwaysHidden or s.mouseoverEnabled) then
                for _, info in ipairs(EXTRA_BARS) do
                    if info.key == barKey and info.frameName then
                        return _G[info.frameName]
                    end
                end
            end
        end
        return nil
    end

    local function ShowEditOverlay(barKey)
        local target = GetEditOverlayTarget(barKey)
        if not target then
            if editOverlayFrame then editOverlayFrame:Hide() end
            return
        end

        if not editOverlayFrame then
            editOverlayFrame = CreateFrame("Frame", "EllesmereEAB_EditOverlay", UIParent)
            editOverlayFrame:SetFrameStrata("HIGH")
            editOverlayFrame:SetFrameLevel(100)
            editOverlayFrame:EnableMouse(false)  -- non-interactive, no dragging

            local bg = editOverlayFrame:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetColorTexture(0.075, 0.113, 0.141, 0.85)
            editOverlayFrame._bg = bg

            if EllesmereUI and EllesmereUI.MakeBorder then
                local eg = EllesmereUI.ELLESMERE_GREEN
                local ar, ag, ab = 1, 1, 1
                if eg then ar, ag, ab = eg.r, eg.g, eg.b end
                editOverlayFrame._border = EllesmereUI.MakeBorder(editOverlayFrame, ar, ag, ab, 0.6, EllesmereUI.PanelPP)
            end

            local label = editOverlayFrame:CreateFontString(nil, "OVERLAY")
            local fontPath = EllesmereUI and EllesmereUI.EXPRESSWAY or "Fonts\\FRIZQT__.TTF"
            label:SetFont(fontPath, 10, EllesmereUI.GetFontOutlineFlag())
            label:SetTextColor(1, 1, 1, 0.75)
            label:SetPoint("CENTER")
            label:SetWordWrap(false)
            editOverlayFrame._label = label
        end

        local s = target:GetEffectiveScale()
        local uiS = UIParent:GetEffectiveScale()
        local w = (target:GetWidth() or 50) * s / uiS
        local h = (target:GetHeight() or 50) * s / uiS
        editOverlayFrame:SetSize(w, h)

        local left, top = target:GetLeft(), target:GetTop()
        if left and top then
            local uiH = UIParent:GetHeight()
            local cx = left * s / uiS + w * 0.5
            local cy = top * s / uiS - h * 0.5
            editOverlayFrame:ClearAllPoints()
            editOverlayFrame:SetPoint("CENTER", UIParent, "TOPLEFT", cx, cy - uiH)
        end

        local labelText = BAR_DROPDOWN_VALUES[barKey] or barKey
        editOverlayFrame._label:SetText(labelText)
        editOverlayFrame:Show()
    end

    local function HideEditOverlay()
        if editOverlayFrame then editOverlayFrame:Hide() end
    end

    EllesmereUI:RegisterOnHide(HideEditOverlay)

    -- Sync Edit Mode icon counts on panel close (numIcons may have changed).
    EllesmereUI:RegisterOnHide(function() EAB:SyncEditModeIcons() end)

    ---------------------------------------------------------------------------
    --  Live Preview System
    --  Child frames are created ONCE; :Update() re-reads DB values and applies
    --  them to the existing objects. Widget callbacks call UpdatePreview(): no
    --  frame creation, no GC pressure, just SetPoint/SetSize/SetColorTexture/
    --  SetTexCoord on already-existing objects.
    ---------------------------------------------------------------------------
    -- Mutable state shared with the page builders under ActionBars_Options\.
    -- A table instead of locals so every file reads and writes the live value.
    -- activePreview: reference to the current preview frame (if any).
    local optState = {}
    local headerFixedH = 0 -- fixed height in content header (dropdown + label + padding), excluding preview
    local _barsHeaderBuilder  -- stored header builder for cache restore
    local _abPreviewHintFS                 -- hint FontString for Single Bar Edit
    local barsHeaderBaseH = 0              -- bars header height WITHOUT hint

    local function IsPreviewHintDismissed()
        return EllesmereUIDB and EllesmereUIDB.previewHintDismissed
    end

    -- Lightweight refresh: re-read settings, update visuals.
    local function UpdatePreview()
        -- Recover activePreview from content header if lost (e.g. page cache restore)
        if not optState.activePreview and EllesmereUI._contentHeaderPreview then
            optState.activePreview = EllesmereUI._contentHeaderPreview
        end
        if optState.activePreview and optState.activePreview.Update then
            optState.activePreview:Update()
        end
    end

    -- Full refresh also recalculates content header height (for bar scale changes)
    local function UpdatePreviewAndResize()
        if not optState.activePreview and EllesmereUI._contentHeaderPreview then
            optState.activePreview = EllesmereUI._contentHeaderPreview
        end
        if optState.activePreview and optState.activePreview.Update then
            optState.activePreview:Update()
            if headerFixedH > 0 then
                local hintH = (not IsPreviewHintDismissed()) and 29 or 0
                local wrapH = optState.activePreview._wrapper and optState.activePreview._wrapper:GetHeight() or (optState.activePreview:GetHeight() * optState.activePreview:GetScale())
                local newTotal = headerFixedH + wrapH + hintH
                EllesmereUI:UpdateContentHeaderHeight(newTotal)
            end
        end
    end

    EllesmereUI:RegisterOnShow(UpdatePreview)

    -- Rebuild the preview on spec change (new talent group).
    do
        local specChangeFrame = CreateFrame("Frame")
        specChangeFrame:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
        specChangeFrame:SetScript("OnEvent", function(self, event)
            if event == "ACTIVE_TALENT_GROUP_CHANGED" and _barsHeaderBuilder then
                optState.activePreview = nil
                if EllesmereUI:IsShown() and EllesmereUI:GetActiveModule() == "EllesmereUIActionBars" then
                    EllesmereUI:SetContentHeader(_barsHeaderBuilder)
                    UpdatePreviewAndResize()
                end
            end
        end)
    end




    ---------------------------------------------------------------------------
    --  Short labels for sync icon multi-apply
    ---------------------------------------------------------------------------
    local SHORT_LABELS = {
        MainBar  = "Bar 1",
        Bar2     = "Bar 2",
        Bar3     = "Bar 3",
        Bar4     = "Bar 4",
        Bar5     = "Bar 5",
        Bar6     = "Bar 6",
        Bar7     = "Bar 7",
        Bar8     = "Bar 8",
        StanceBar = "Stance",
        PetBar   = "Pet",
        MicroBar = "Micro",
        BagBar   = "Bags",
        XPBar    = "XP",
        RepBar   = "Rep",
        FavorBar = "Favor",
    }

    -- Spec Overrides capture: label captured entries with the selected bar's element (e.g. "Action Bars > Bar 1 > ...").
    EllesmereUI.RegisterCaptureContext("EllesmereUIActionBars", function()
        local key = SelectedKey()
        return SHORT_LABELS[key] or key
    end)

    -- Legacy boolean flags and the visibility-mode dropdown must stay in sync: the runtime reads both shapes.
    local function GetVisibilityKey(s)
        if not VisibilityCompat then
            return s.barVisibility or "always"
        end
        return VisibilityCompat.Normalize(s)
    end

    local function ApplyVisibilityKey(s, v)
        if VisibilityCompat then
            VisibilityCompat.ApplyMode(s, v)
            return
        end

        s.barVisibility = v
        s.alwaysHidden = (v == "never")

        local wasMouseover = s.mouseoverEnabled
        s.mouseoverEnabled = (v == "mouseover")
        if v == "mouseover" then
            if not wasMouseover then
                s._savedBarAlpha = s.mouseoverAlpha or 1
            end
            s.mouseoverAlpha = 0
        elseif wasMouseover and s._savedBarAlpha then
            s.mouseoverAlpha = s._savedBarAlpha
            s._savedBarAlpha = nil
        end

        s.combatHideEnabled = (v == "out_of_combat")
        s.combatShowEnabled = (v == "in_combat")
    end

    local function CopyVisibilitySettings(dst, src, dstKey)
        -- The merged Visibility control owns the option booleans too, so every copy
        -- carries them alongside the mode selection.
        local optKeys = EllesmereUI.VIS_OPT_KEYS
        if optKeys then
            for i = 1, #optKeys do dst[optKeys[i]] = src[optKeys[i]] or nil end
        end
        if VisibilityCompat then
            -- Pet Bar ignores group modes: strip them from a copied multi-selection.
            VisibilityCompat.Copy(dst, src, dstKey == "PetBar")
            return
        end

        local v = src.barVisibility or "always"
        dst.barVisibility = v
        dst.visibilityMatch = src.visibilityMatch or nil
        dst.alwaysHidden = src.alwaysHidden
        dst.mouseoverEnabled = src.mouseoverEnabled
        dst.mouseoverAlpha = src.mouseoverAlpha
        dst._savedBarAlpha = src._savedBarAlpha
        dst.combatHideEnabled = src.combatHideEnabled
        dst.combatShowEnabled = src.combatShowEnabled
        dst.dragShow = src.dragShow
    end




    -- An End Caps row: the End Caps checklist (Left Endcap / Right Endcap) and
    -- its cog (the EllesmereUI style's art, size, offsets), per bar through the
    -- runtime's own readers (ns.AB_CapsSides / AB_CapsVal: an unset Action Bar
    -- 1 key reads the profile-wide one, a bar carrying one of bar 1's caps reads
    -- bar 1's). Horizontal bars only: the art sits at the bar's two ends.
    --   o.key()          the bar
    --   o.store()        its settings table
    --   o.label          the row text
    --   o.vertical()     true greys the row
    --   o.write(k, v)    stores cog value v under k (k nil: the checklist has
    --                    already stored both sides) and repaints
    --   o.copyApply(key) repaints another bar after an Apply to All copy
    --   o.syncKeys, o.syncLabels  the Apply to All link's bars (nil = no link)
    local function EndCapsCtl(o)
        local C = {}
        C.stock = EllesmereUI.BlizzStyle.Get("actionbars") and true or false
        C.forever = C.stock and EllesmereUI.BlizzStyle.Forever("actionbars")
        C.Vertical = o.vertical
        -- True while the bar shows a cap at neither end.
        function C.Off()
            local l, r = ns.AB_CapsSides(o.key())
            return not (l or r)
        end
        -- The row slot C.Build swaps for the checklist; its label carries the
        -- tooltip and dims on a vertical bar.
        function C.Cfg()
            local classic = EllesmereUI.BlizzStyle.Active("actionbars") == "classic"
            return { type="dropdown", text=o.label,
              tooltip=(not C.stock) and "Which ends of the bar show end cap art; the cog picks the art."
                  or classic and "Which ends of the bar show the gryphons."
                  or "Which ends of the bar show the gryphons or wyverns.",
              values={ __placeholder = "..." }, order={ "__placeholder" },
              disabled=C.Vertical,
              disabledTooltip="Vertical Orientation", requireState="disabled",
              getValue=function() return "__placeholder" end,
              setValue=function() end }
        end
        -- A bar's whole end cap setting onto bar `dst`, as this bar resolves
        -- it (sides, the EllesmereUI style's art, size, offsets).
        function C.CopyTo(dst)
            local src = o.key()
            local d = EAB.db.profile.bars[dst]
            if dst == src or not d then return end
            d.endCapLeft, d.endCapRight = ns.AB_CapsSides(src)
            if not C.stock then d.endCapArt = ns.AB_CapsArt(src) end
            local _, dx, dy, sc = ns.AB_CapsTweak(src)
            d.endCapScale, d.endCapOffsetX, d.endCapOffsetY = sc, dx, dy
            o.copyApply(dst)
        end
        function C.Same(key)
            local src = o.key()
            local sl, sr = ns.AB_CapsSides(src)
            local kl, kr = ns.AB_CapsSides(key)
            if sl ~= kl or sr ~= kr then return false end
            if not (sl or sr) then return true end
            if not C.stock and ns.AB_CapsArt(src) ~= ns.AB_CapsArt(key) then return false end
            local _, sx, sy, ss = ns.AB_CapsTweak(src)
            local _, kx, ky, ks = ns.AB_CapsTweak(key)
            return ss == ks and sx == kx and sy == ky
        end
        -- The checklist in `rgn` (a DualRow half built from C.Cfg), its cog
        -- and its Apply to All link.
        function C.Build(rgn)
            if EllesmereUI._prebuilding then return end
            if rgn._control then rgn._control:Hide() end
            local cbDD, cbDDRefresh = EllesmereUI.BuildVisOptsCBDropdown(
                rgn, 170, rgn:GetFrameLevel() + 2,
                { { key = "L", label = "Left Endcap" }, { key = "R", label = "Right Endcap" } },
                function(k)
                    local l, r = ns.AB_CapsSides(o.key())
                    if k == "L" then return l end
                    return r
                end,
                function(k, v)
                    -- Both sides are written, the untouched one as the bar
                    -- shows it now: a written side never reads a default.
                    local s = o.store()
                    local l, r = ns.AB_CapsSides(o.key())
                    if k == "L" then l = v and true or false else r = v and true or false end
                    s.endCapLeft, s.endCapRight = l, r
                    o.write()
                end, nil, nil, nil, nil, nil,
                -- Spec Overrides see each click as it happens (the slot's capture).
                { notifyWrites = true })
            PP.Point(cbDD, "RIGHT", rgn, "RIGHT", -20, 0)
            rgn._control = cbDD
            rgn._lastInline = nil
            EllesmereUI.RegisterWidgetRefresh(cbDDRefresh)
            -- The checklist has no disabled state of its own: grey it and
            -- block clicks on a vertical bar (the row label explains).
            local function ApplyCapsDisabled()
                local off = C.Vertical()
                cbDD:SetAlpha(off and 0.3 or 1)
                cbDD:EnableMouse(not off)
            end
            ApplyCapsDisabled()
            EllesmereUI.RegisterWidgetRefresh(ApplyCapsDisabled)

            local rows = {}
            if not C.stock then
                -- WoW Forever's own art exists only on that client.
                local values = { blizzard="Modern", classic="Classic" }
                local order = { "blizzard", "classic" }
                if EllesmereUI.IS_FOREVER then
                    values.forever = "WoW Forever"
                    order[#order + 1] = "forever"
                end
                rows[#rows + 1] = { type="dropdown", label="Art", values=values, order=order,
                  tooltip=EllesmereUI.IS_FOREVER
                      and "Modern shows gryphons or wyverns by faction, Classic the vanilla gryphons, WoW Forever this client's own."
                      or "Modern shows gryphons or wyverns by faction, Classic the vanilla gryphons.",
                  get=function() return ns.AB_CapsArt(o.key()) end,
                  set=function(v) o.write("endCapArt", v) end }
            end
            rows[#rows + 1] = { type="slider", label="Size", min=50, max=200, step=5,
              tooltip="Percent of the end caps' normal size.",
              get=function() return ns.AB_CapsVal(o.key(), "endCapScale") or 100 end,
              set=function(v) o.write("endCapScale", v) end }
            rows[#rows + 1] = { type="slider", label="X Offset", min=-100, max=100, step=1,
              tooltip="Positive values move both end caps away from the bar.",
              get=function() return ns.AB_CapsVal(o.key(), "endCapOffsetX") or 0 end,
              set=function(v) o.write("endCapOffsetX", v) end }
            rows[#rows + 1] = { type="slider", label="Y Offset", min=-100, max=100, step=1,
              get=function() return ns.AB_CapsVal(o.key(), "endCapOffsetY") or 5 end,
              set=function(v) o.write("endCapOffsetY", v) end }
            EllesmereUI.BuildInlineCog(rgn, {
                title = "End Cap Settings",
                icon = C.stock and EllesmereUI.RESIZE_ICON or nil,
                disabled = function()
                    return C.Vertical() or C.Off()
                end,
                disabledTooltip = function()
                    if C.Vertical() then return EllesmereUI.DisabledTooltip("Vertical Orientation", "disabled") end
                    return EllesmereUI.DisabledTooltip("Left Endcap or Right Endcap")
                end,
                rawTooltip = true,
                rows = rows,
            })

            if o.syncKeys then
                EllesmereUI.BuildSyncIcon({
                    region  = rgn,
                    tooltip = "Apply End Caps to all Bars",
                    onClick = function()
                        for _, key in ipairs(o.syncKeys) do C.CopyTo(key) end
                        EllesmereUI:RefreshPage()
                    end,
                    isSynced = function()
                        for _, key in ipairs(o.syncKeys) do
                            if not C.Same(key) then return false end
                        end
                        return true
                    end,
                    flashTargets = function() return { rgn } end,
                    multiApply = {
                        elementKeys   = o.syncKeys,
                        elementLabels = o.syncLabels,
                        getCurrentKey = function() return o.key() end,
                        onApply       = function(checkedKeys)
                            for _, key in ipairs(checkedKeys) do C.CopyTo(key) end
                            EllesmereUI:RefreshPage()
                        end,
                    },
                })
            end
        end
        return C
    end

    local function BuildSharedBarSettings(parent, y)
        local W = EllesmereUI.Widgets
        local _, h

        ---------------------------------------------------------------
        --  Unified Get / Set / DB abstraction
        ---------------------------------------------------------------
        local function SGet(key)
            return SB()[key]
        end
        local function SSet(key, val, applyFn)
            SB()[key] = val
            if applyFn then applyFn(SelectedKey()) end
            EllesmereUI:RefreshPage()
        end
        local function SDB()
            return SB()
        end
        local function SVal(key, default)
            local v = SB()[key]
            return v ~= nil and v or default
        end
        local function SSetColor(key, r, g, b, a, applyFn)
            SB()[key] = { r=r, g=g, b=b, a=a }
            if applyFn then applyFn(SelectedKey()) end
            EllesmereUI:RefreshPage()
        end
        local function SUpdatePreview()
            UpdatePreview()
        end

        -- The stock spacing lives in the offset boxes, not in the placement. A
        -- position pick swaps the old placement's spacing for the new one's on each
        -- axis and keeps whatever the user added on top (Default carries none: its
        -- stock lines hold their own spacing). Opting in, moving between positions
        -- and going back to Default therefore never move the text by the spacing,
        -- whatever the boxes held (a Cropped shape's preset included).
        local function SSeedTextOffsets(kind, anchorKey, oxKey, oyKey, anchor)
            local prev = SVal(anchorKey, nil)
            if prev == anchor then return end
            local px, py, nx, ny = 0, 0, 0, 0
            if prev then px, py = EAB.StockTextOffsets(kind, prev) end
            if anchor then nx, ny = EAB.StockTextOffsets(kind, anchor) end
            SB()[oxKey] = SVal(oxKey, 0) - px + nx
            SB()[oyKey] = SVal(oyKey, 0) - py + ny
        end
        local function SUpdatePreviewAndResize()
            UpdatePreviewAndResize()
        end
        parent._showRowDivider = true

        local visOnly = IsVisOnly()
        local row
        -- Declared out here, not in the `do` block that builds it: the Toggle Action Bar
        -- keybind lives past that block's end and anchors into this row's right slot.
        local visRow1

        -- Row / section references for click-navigation
        local iconsSectionHeader, textSectionHeader
        local borderRow
        local keybindRow, chargesRow

        local function BgDisabled()
            return not SB().bgEnabled
        end

        -----------------------------------------------------------------------
        --  Bar 10 / Moonkin Form caution
        -----------------------------------------------------------------------
        -- Action page 10 (Bar 10's slots) is also the Druid Moonkin Form bonus bar, so editing either edits both. Shown for all classes; text self-qualifies.
        if SelectedKey() == "Bar10" then
            local PP = EllesmereUI.PanelPP
            local PAD = EllesmereUI.CONTENT_PAD
            local warnW = parent:GetWidth() - PAD * 2
            y = y - 5  -- 5px spacing above the caution
            local warnHost = CreateFrame("Frame", nil, parent)
            PP.Point(warnHost, "TOPLEFT", parent, "TOPLEFT", PAD, y)
            local warnFS = EllesmereUI.MakeFont(warnHost, 14, nil, 1, 0.82, 0)
            warnFS:SetWidth(warnW)
            warnFS:SetWordWrap(true)
            warnFS:SetJustifyH("CENTER")
            warnFS:SetPoint("TOPLEFT", warnHost, "TOPLEFT", 0, 0)
            warnFS:SetText(EllesmereUI.L("This Action Bar is also used as the Moonkin Form bar.\nChanging spells on a Druid for this bar will also change them on your Moonkin Form bar."))
            local warnH = math.ceil(warnFS:GetStringHeight()) + 4
            PP.Size(warnHost, warnW, warnH)
            y = y - (warnH + 12)
        end

        -----------------------------------------------------------------------
        --  VISIBILITY
        -----------------------------------------------------------------------
        _, h = W:SectionHeader(parent, SECTION_VISIBILITY, y);  y = y - h

        do
            local _visBlizzDis
            local _VIS_BLIZZ_TIP = "This option does not work with Blizzard Bars. Please use Blizzard Edit Mode."
            if IsDataBar() then
                _visBlizzDis = function() return EAB.db.profile.useBlizzardDataBars end
            end

            -- Pet Bar cannot express group modes: lock them with an explanation instead of offering silent no-ops.
            -- noOverrideMouseover: see the caps on the bar row above.
            local visCaps = { partyIncludesRaid = false, noOverrideMouseover = true }
            if SelectedKey() == "PetBar" then
                visCaps.noGroupModes = true
                visCaps.lockedTooltips = {
                    in_raid  = "The Pet Bar cannot use group-based visibility.",
                    in_party = "The Pet Bar cannot use group-based visibility.",
                    solo     = "The Pet Bar cannot use group-based visibility.",
                }
            end
            -- Data bars evaluate in Lua (non-secure), so dragonriding items depend on the gliding
            -- edge event; secure bars' drivers re-evaluate natively and never lock.
            if IsDataBar() then visCaps.luaDragonriding = true end

            visRow1, h = EllesmereUI.BuildVisibilityRow(W, parent, y,
                { getStore = function()
                      local s = SB()
                      GetVisibilityKey(s)
                      return s
                  end,
                  legacyKey = "barVisibility",
                  caps = visCaps,
                  applyScalarFn = function(s, mode) ApplyVisibilityKey(s, mode) end,
                  disabledFn = _visBlizzDis, disabledTooltip = _visBlizzDis and _VIS_BLIZZ_TIP or nil,
                  rawTooltip = true,
                  onChanged = function()
                      if EAB.ClearVisToggleOverride then EAB:ClearVisToggleOverride(SelectedKey()) end
                      if EAB.RebuildVisToggleBindings then EAB:RebuildVisToggleBindings() end
                      EAB:RefreshRuntimeVisibility()
                      EAB:RefreshMouseover()
                      EAB:ApplyCombatVisibility()
                  end,
                  -- Option axes recompile the secure driver through the same chain the
                  -- old Visibility Options dropdown used. The gate refresh first: a lane
                  -- click can be what just armed (or disarmed) the soft-target machinery,
                  -- and the two calls below must see the current flags, not last click's.
                  onOptionChanged = function()
                      EAB:_RefreshSoftTargetGate()
                      EAB:UpdateHousingVisibility()
                      EAB:ApplyCombatVisibility()
                  end },
                -- Toggle Action Bar moved up into the slot the Visibility Options dropdown
                -- left behind: the keybind flips this bar shown/hidden, the same question the
                -- Visibility control answers. It carries the `not visOnly` gate its old row
                -- had, so visibility-only bars still get no toggle keybind.
                (not visOnly) and { type="label", text="Toggle Action Bar" }
                    or { type="label", text="" });  y = y - h

            do
                local rgn = visRow1._leftRegion
                EllesmereUI.BuildSyncIcon({
                    region  = rgn,
                    tooltip = "Apply Visibility to all Bars",
                    onClick = function()
                        local src = SB()
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            local dst = EAB.db.profile.bars[key]
                            CopyVisibilitySettings(dst, src, key)
                        end
                        EAB:RefreshRuntimeVisibility()
                        EAB:RefreshMouseover()
                        EAB:ApplyCombatVisibility()
                        EllesmereUI:RefreshPage()
                    end,
                    isSynced = function()
                        local src = SB()
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            local dst = EAB.db.profile.bars[key]
                            if not EllesmereUI.VisFullEquals(src, "barVisibility", dst, "barVisibility") then return false end
                            if (src.dragShow or false) ~= (dst.dragShow or false) then return false end
                        end
                        return true
                    end,
                    flashTargets = function() return { rgn } end,
                    multiApply = {
                        elementKeys   = GROUP_BAR_ORDER,
                        elementLabels = SHORT_LABELS,
                        getCurrentKey = function() return SelectedKey() end,
                        onApply       = function(checkedKeys)
                            local src = SB()
                            for _, key in ipairs(checkedKeys) do
                                local dst = EAB.db.profile.bars[key]
                                CopyVisibilitySettings(dst, src, key)
                            end
                            EAB:RefreshRuntimeVisibility()
                            EAB:RefreshMouseover()
                            EAB:ApplyCombatVisibility()
                            EllesmereUI:RefreshPage()
                        end,
                    },
                })
            end
            do
                local rgn = visRow1._leftRegion
                local function MORow()
                    return { type="toggle", label="Show All on Mouseover",
                      tooltip="When hovering any action bar set to Mouseover, all Mouseover bars will appear.",
                      get=function() return EAB.db.profile.mouseoverShowAll or false end,
                      set=function(v)
                          EAB.db.profile.mouseoverShowAll = v
                      end }
                end
                -- Show During Drag applies only while THIS bar's visibility is Never
                -- (other modes already surface during a drag); the row is always
                -- present, disabled with a requirement tooltip in the other modes.
                local function NeverOnly()
                    local s = SB()
                    return not (s.barVisibility == "never" or s.alwaysHidden)
                end
                local function SpellbookRow()
                    -- Available in EVERY visibility mode (unlike Show During
                    -- Drag, whose behavior IS the default outside Never).
                    return { type="toggle", label="Show When Spellbook Is Open",
                      tooltip="While the spellbook or macro panel is open, this bar appears so you can drag abilities onto it.",
                      get=function() return SB().spellbookShow == true end,
                      set=function(v)
                          SB().spellbookShow = v or nil
                          -- Resync drops/replants the override live (covers
                          -- toggling while the spellbook is already open).
                          if EAB._UpdateSpellbookNeverBars then
                              EAB._UpdateSpellbookNeverBars(true)
                          end
                      end }
                end
                local function DragRow()
                    return { type="toggle", label="Show During Drag",
                      tooltip="While dragging a spell or item, this bar appears so you can drop onto it.",
                      disabled=NeverOnly,
                      disabledTooltip="Visibility set to Never",
                      get=function() return SB().dragShow == true end,
                      set=function(v)
                          SB().dragShow = v
                          -- The Apply Visibility link compares this toggle.
                          EllesmereUI:RefreshPage()
                      end }
                end
                EllesmereUI.BuildInlineCog(rgn, {
                    title = "Visibility",
                    rows = { MORow(), SpellbookRow(), DragRow() },
                    anchorTo = rgn._control,
                })
            end
        end

        -- Bar Opacity keeps this row (and its sync icon, now on the left region) with
        -- Always Show Buttons as its partner; Toggle Action Bar sits in the Visibility row.
        row, h = W:DualRow(parent, y,
            { type="slider", text="Bar Opacity", min=0, max=100, step=5,
              getValue=function()
                  local bs = SB()
                  if bs.mouseoverEnabled then
                      return floor((bs._savedBarAlpha or 1) * 100 + 0.5)
                  end
                  return floor((bs.mouseoverAlpha or 1) * 100 + 0.5)
              end,
              setValue=function(v)
                  local bs = SB()
                  if bs.mouseoverEnabled then
                      bs._savedBarAlpha = v / 100
                  else
                      SSet("mouseoverAlpha", v / 100, function(k) EAB:ApplyBarOpacity(k) end)
                  end
                  SUpdatePreview()
              end },
            { type="toggle", text="Always Show Buttons",
              getValue=function()
                  local v = SGet("alwaysShowButtons")
                  if v == nil then return true end
                  return v
              end,
              setValue=function(v)
                  SSet("alwaysShowButtons", v, function(k)
                      EAB:ApplyAlwaysShowButtons(k)
                      EAB:ApplyPaddingForBar(k)
                      EAB:ApplyBackgroundForBar(k)
                  end)
                  SUpdatePreview()
              end,
              tooltip="Show button backgrounds even if a spell is not assigned to that slot." });  y = y - h
        do
            local rgn = row._leftRegion
            EllesmereUI.BuildSyncIcon({
                region  = rgn,
                tooltip = "Apply Bar Opacity to all Bars",
                onClick = function()
                    local v = SB().mouseoverAlpha or 1
                    for _, key in ipairs(GROUP_BAR_ORDER) do
                        EAB.db.profile.bars[key].mouseoverAlpha = v
                        EAB:ApplyBarOpacity(key)
                    end
                    EllesmereUI:RefreshPage()
                end,
                isSynced = function()
                    local cur = SB()
                    local v = cur.mouseoverEnabled and 1 or (cur.mouseoverAlpha or 1)
                    for _, key in ipairs(GROUP_BAR_ORDER) do
                        local bs = EAB.db.profile.bars[key]
                        local bv = bs.mouseoverEnabled and 1 or (bs.mouseoverAlpha or 1)
                        if bv ~= v then return false end
                    end
                    return true
                end,
                flashTargets = function() return { rgn } end,
                multiApply = {
                    elementKeys   = GROUP_BAR_ORDER,
                    elementLabels = SHORT_LABELS,
                    getCurrentKey = function() return SelectedKey() end,
                    onApply       = function(checkedKeys)
                        local v = SB().mouseoverAlpha or 1
                        for _, key in ipairs(checkedKeys) do
                            EAB.db.profile.bars[key].mouseoverAlpha = v
                            EAB:ApplyBarOpacity(key)
                        end
                        EllesmereUI:RefreshPage()
                    end,
                },
            })
        end

        -- The bar's end caps (EndCapsCtl). Under WoW Forever it opens LAYOUT
        -- beside Show Bar Background; every other look puts it in the Click
        -- Through row's free slot. A change to Action Bar 1's caps also
        -- repaints a bar carrying one of them (the first-install span).
        local CAPS = (not visOnly) and EndCapsCtl({
            key = SelectedKey, store = SB, label = "End Caps",
            vertical = function() return not EAB:GetOrientationForBar(SelectedKey()) end,
            write = function(k, v)
                if k then
                    SSet(k, v, function(bk) EAB:ApplyPaddingForBar(bk) end)
                    SUpdatePreviewAndResize()
                else
                    EAB:ApplyPaddingForBar(SelectedKey())
                    SUpdatePreviewAndResize()
                    EllesmereUI:RefreshPage()
                end
                if SelectedKey() == "MainBar" then ns.AB_CapsSpanApply() end
            end,
            copyApply = function(key)
                EAB:ApplyPaddingForBar(key)
                if key == "MainBar" then ns.AB_CapsSpanApply() end
            end,
            syncKeys = GROUP_BAR_ORDER, syncLabels = SHORT_LABELS,
        }) or nil

        if not visOnly then
            local ctRow
            local capsInCt = CAPS and not CAPS.forever
            ctRow, h = W:DualRow(parent, y,
                { type="toggle", text="Click Through",
                  getValue=function()
                      return SGet("clickThrough")
                  end,
                  setValue=function(v)
                      SSet("clickThrough", v, function(k) EAB:ApplyClickThroughForBar(k) end)
                  end },
                capsInCt and CAPS.Cfg() or EllesmereUI.BlankRowCfg());  y = y - h
            if capsInCt then CAPS.Build(ctRow._rightRegion) end
            -- "Toggle Action Bar" keybind: bound key flips the bar shown/hidden at runtime
            -- without writing saved visibility. Enabled only for Always/Never; out of combat
            -- only. Its label sits in the Visibility row, so the button goes there too.
            do
                local rgn = visRow1._rightRegion
                local kbBtn, refresh = EllesmereUI.BuildKeybindButton(rgn, {
                    w = 126, h = 29, level = 4,
                    get = function() return SB().toggleVisKey end,
                    set = function(v)
                        SB().toggleVisKey = v
                        EAB:RebuildVisToggleBindings()
                        EllesmereUI._NotifySettingWrite(rgn)
                    end,
                    disabled = function()
                        local v = SB().barVisibility or "always"
                        return v ~= "always" and v ~= "never"
                    end,
                    disabledTip = "Visibility set to Always or Never",
                    tooltip = "Toggling an action bar is only available out of combat\n\nLeft-click to set a keybind.\nRight-click to unbind.",
                })
                PP.Point(kbBtn, "RIGHT", rgn, "RIGHT", -20, 0)
                EllesmereUI.RegisterWidgetRefresh(refresh)

                -- Spec Overrides capture: bespoke widget opts in with a synthetic accessor (left half is a plain label cfg, no get/set).
                EllesmereUI.AddCaptureAccessor(rgn, {
                    type = "keybind", text = "Toggle Action Bar",
                    getValue = function() return SB().toggleVisKey end,
                    setValue = function(v)
                        SB().toggleVisKey = v
                        EAB:RebuildVisToggleBindings()
                        refresh()
                    end,
                })
            end
            do
                local rgn = ctRow._leftRegion
                EllesmereUI.BuildSyncIcon({
                    region  = rgn,
                    tooltip = "Apply Click Through to all Bars",
                    onClick = function()
                        local v = SB().clickThrough or false
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            EAB.db.profile.bars[key].clickThrough = v
                            EAB:ApplyClickThroughForBar(key)
                        end
                        EllesmereUI:RefreshPage()
                    end,
                    isSynced = function()
                        local v = SB().clickThrough or false
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            if (EAB.db.profile.bars[key].clickThrough or false) ~= v then return false end
                        end
                        return true
                    end,
                    flashTargets = function() return { rgn } end,
                    multiApply = {
                        elementKeys   = GROUP_BAR_ORDER,
                        elementLabels = SHORT_LABELS,
                        getCurrentKey = function() return SelectedKey() end,
                        onApply       = function(checkedKeys)
                            local v = SB().clickThrough or false
                            for _, key in ipairs(checkedKeys) do
                                EAB.db.profile.bars[key].clickThrough = v
                                EAB:ApplyClickThroughForBar(key)
                            end
                            EllesmereUI:RefreshPage()
                        end,
                    },
                })
            end
        end

        -----------------------------------------------------------------------
        --  LAYOUT  (hidden when visibility-only)
        -----------------------------------------------------------------------
        if not visOnly then
            _, h = W:SectionHeader(parent, SECTION_LAYOUT, y);  y = y - h

            -- WoW Forever: the bar's end caps and the frame and dividers behind
            -- its buttons (both on by default on Action Bar 1 only) open the
            -- section.
            if CAPS and CAPS.forever then
                local capsRow
                capsRow, h = W:DualRow(parent, y,
                    CAPS.Cfg(),
                    { type="toggle", text="Show Bar Background",
                      tooltip="Show the frame and dividers behind the bar's buttons.",
                      getValue=function() return ns.AB_ForeverBg(SelectedKey()) end,
                      setValue=function(v)
                          SSet("foreverBarBg", v and true or false, function(k) EAB:ApplyPaddingForBar(k) end)
                          SUpdatePreviewAndResize()
                      end });  y = y - h
                CAPS.Build(capsRow._leftRegion)
                do
                    local rgn = capsRow._rightRegion
                    local function BgTo(key, v)
                        local d = EAB.db.profile.bars[key]
                        if d then
                            d.foreverBarBg = v
                            EAB:ApplyPaddingForBar(key)
                        end
                    end
                    EllesmereUI.BuildSyncIcon({
                        region  = rgn,
                        tooltip = "Apply Show Bar Background to all Bars",
                        onClick = function()
                            local v = ns.AB_ForeverBg(SelectedKey())
                            for _, key in ipairs(GROUP_BAR_ORDER) do BgTo(key, v) end
                            EllesmereUI:RefreshPage()
                        end,
                        isSynced = function()
                            local v = ns.AB_ForeverBg(SelectedKey())
                            for _, key in ipairs(GROUP_BAR_ORDER) do
                                if ns.AB_ForeverBg(key) ~= v then return false end
                            end
                            return true
                        end,
                        flashTargets = function() return { rgn } end,
                        multiApply = {
                            elementKeys   = GROUP_BAR_ORDER,
                            elementLabels = SHORT_LABELS,
                            getCurrentKey = function() return SelectedKey() end,
                            onApply       = function(checkedKeys)
                                local v = ns.AB_ForeverBg(SelectedKey())
                                for _, key in ipairs(checkedKeys) do BgTo(key, v) end
                                EllesmereUI:RefreshPage()
                            end,
                        },
                    })
                end
            end

            local iconSizeRow
            iconSizeRow, h = W:DualRow(parent, y,
                { type="slider", text="Icon Size", min=16, max=120, step=1,
                  -- Every style sizes from this slider (stock styles scale Blizzard's
                  -- native-size button to it); only a size match locks it.
                  disabled=function()
                      local k = SelectedKey()
                      if EllesmereUI.GetWidthMatchTarget and EllesmereUI.GetWidthMatchTarget(k) then return true end
                      if EllesmereUI.GetHeightMatchTarget and EllesmereUI.GetHeightMatchTarget(k) then return true end
                      return false
                  end,
                  disabledTooltip=function()
                      local k = SelectedKey()
                      local wt = EllesmereUI.GetWidthMatchTarget and EllesmereUI.GetWidthMatchTarget(k)
                      local ht = EllesmereUI.GetHeightMatchTarget and EllesmereUI.GetHeightMatchTarget(k)
                      local target = wt or ht
                      if target then
                          local name = (EllesmereUI.GetBarLabel and EllesmereUI.GetBarLabel(target)) or target
                          return EllesmereUI.Lf("Size matched to %1$s. Unmatch in Unlock Mode to edit.", name)
                      end
                      return nil
                  end,
                  rawTooltip=true,
                  getValue=function()
                      local s = SB()
                      if s.buttonWidth and s.buttonWidth > 0 then return s.buttonWidth end
                      local info = BAR_LOOKUP[SelectedKey()]
                      local btn1 = FirstBarButton(SelectedKey())
                      return btn1 and math.floor((btn1:GetWidth() or 36) + 0.5) or 36
                  end,
                  setValue=function(v)
                      SB().buttonWidth  = v
                      SB().buttonHeight = v
                      SB()._matchExtraPixels = nil
                      SB()._matchExtraPixelsH = nil
                      EAB:ApplyButtonSizeForBar(SelectedKey())
                      SUpdatePreviewAndResize()
                      EllesmereUI:RefreshPage()
                  end },
                { type="slider", pixel=true, text="Button Spacing", min=-10, max=20, step=1,
                  getValue=function() return SVal("buttonPadding", 2) end,
                  setValue=function(v)
                      SSet("buttonPadding", v, function(k) EAB:ApplyPaddingForBar(k) end)
                      SUpdatePreview()
                  end });  y = y - h
            do
                local rgn = iconSizeRow._leftRegion
                EllesmereUI.BuildSyncIcon({
                    region  = rgn,
                    tooltip = "Apply Icon Size to all Bars",
                    onClick = function()
                        local s = SB()
                        local info = BAR_LOOKUP[SelectedKey()]
                        local btn1 = FirstBarButton(SelectedKey())
                        local v = (s.buttonWidth and s.buttonWidth > 0) and s.buttonWidth
                            or (btn1 and math.floor((btn1:GetWidth() or 36) + 0.5)) or 36
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            EAB.db.profile.bars[key].buttonWidth  = v
                            EAB.db.profile.bars[key].buttonHeight = v
                            EAB:ApplyButtonSizeForBar(key)
                        end
                        EllesmereUI:RefreshPage()
                    end,
                    isSynced = function()
                        local s = SB()
                        local info = BAR_LOOKUP[SelectedKey()]
                        local btn1 = FirstBarButton(SelectedKey())
                        local v = (s.buttonWidth and s.buttonWidth > 0) and s.buttonWidth
                            or (btn1 and math.floor((btn1:GetWidth() or 36) + 0.5)) or 36
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            local ks = EAB.db.profile.bars[key]
                            local kv = (ks.buttonWidth and ks.buttonWidth > 0) and ks.buttonWidth or v
                            if kv ~= v then return false end
                        end
                        return true
                    end,
                    flashTargets = function() return { rgn } end,
                    multiApply = {
                        elementKeys   = GROUP_BAR_ORDER,
                        elementLabels = SHORT_LABELS,
                        getCurrentKey = function() return SelectedKey() end,
                        onApply       = function(checkedKeys)
                            local s = SB()
                            local info = BAR_LOOKUP[SelectedKey()]
                            local btn1 = FirstBarButton(SelectedKey())
                            local v = (s.buttonWidth and s.buttonWidth > 0) and s.buttonWidth
                                or (btn1 and math.floor((btn1:GetWidth() or 36) + 0.5)) or 36
                            for _, key in ipairs(checkedKeys) do
                                EAB.db.profile.bars[key].buttonWidth  = v
                                EAB.db.profile.bars[key].buttonHeight = v
                                EAB:ApplyButtonSizeForBar(key)
                            end
                            EllesmereUI:RefreshPage()
                        end,
                    },
                })
            end
            do
                local rgn = iconSizeRow._rightRegion
                EllesmereUI.BuildSyncIcon({
                    region  = rgn,
                    tooltip = "Apply Button Spacing to all Bars",
                    onClick = function()
                        local v = SB().buttonPadding or 2
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            EAB.db.profile.bars[key].buttonPadding = v
                            EAB:ApplyPaddingForBar(key)
                        end
                        EllesmereUI:RefreshPage()
                    end,
                    isSynced = function()
                        local v = SB().buttonPadding or 2
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            if (EAB.db.profile.bars[key].buttonPadding or 2) ~= v then return false end
                        end
                        return true
                    end,
                    flashTargets = function() return { rgn } end,
                    multiApply = {
                        elementKeys   = GROUP_BAR_ORDER,
                        elementLabels = SHORT_LABELS,
                        getCurrentKey = function() return SelectedKey() end,
                        onApply       = function(checkedKeys)
                            local v = SB().buttonPadding or 2
                            for _, key in ipairs(checkedKeys) do
                                EAB.db.profile.bars[key].buttonPadding = v
                                EAB:ApplyPaddingForBar(key)
                            end
                            EllesmereUI:RefreshPage()
                        end,
                    },
                })
            end

            row, h = W:DualRow(parent, y,
                { type="slider", text="Number of Icons", min=1, max=12, step=1,
                  disabled=function()
                      local info = BAR_LOOKUP[SelectedKey()]
                      return info and info.isStance
                  end,
                  getValue=function()
                      local v = SGet("overrideNumIcons")
                      if v and v > 0 then return v end
                      local s = SB()
                      if s and s.numIcons and s.numIcons > 0 then
                          return s.numIcons
                      end
                      return 12
                  end,
                  setValue=function(v)
                      SSet("overrideNumIcons", v, function(k) EAB:ApplyIconRowOverrides(k) end)
                      SUpdatePreviewAndResize()
                  end },
                { type="slider", text="Number of Rows", min=1, max=12, step=1,
                  getValue=function()
                      local v = SGet("overrideNumRows")
                      if v and v > 0 then return v end
                      local s = SB()
                      if s and s.numRows and s.numRows > 0 then
                          return s.numRows
                      end
                      return 1
                  end,
                  setValue=function(v)
                      SSet("overrideNumRows", v, function(k) EAB:ApplyIconRowOverrides(k) end)
                      SUpdatePreviewAndResize()
                  end });  y = y - h
            do
                local rgn = row._leftRegion
                EllesmereUI.BuildSyncIcon({
                    region  = rgn,
                    tooltip = "Apply Number of Icons to all Bars",
                    onClick = function()
                        local v = SB().overrideNumIcons or 12
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            EAB.db.profile.bars[key].overrideNumIcons = v
                            EAB:ApplyIconRowOverrides(key)
                        end
                        EllesmereUI:RefreshPage()
                    end,
                    isSynced = function()
                        local v = SB().overrideNumIcons or 12
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            if (EAB.db.profile.bars[key].overrideNumIcons or 12) ~= v then return false end
                        end
                        return true
                    end,
                    flashTargets = function() return { rgn } end,
                    multiApply = {
                        elementKeys   = GROUP_BAR_ORDER,
                        elementLabels = SHORT_LABELS,
                        getCurrentKey = function() return SelectedKey() end,
                        onApply       = function(checkedKeys)
                            local v = SB().overrideNumIcons or 12
                            for _, key in ipairs(checkedKeys) do
                                EAB.db.profile.bars[key].overrideNumIcons = v
                                EAB:ApplyIconRowOverrides(key)
                            end
                            EllesmereUI:RefreshPage()
                        end,
                    },
                })
            end
            do
                local rgn = row._rightRegion
                EllesmereUI.BuildSyncIcon({
                    region  = rgn,
                    tooltip = "Apply Number of Rows to all Bars",
                    onClick = function()
                        local v = SB().overrideNumRows or 1
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            EAB.db.profile.bars[key].overrideNumRows = v
                            EAB:ApplyIconRowOverrides(key)
                        end
                        EllesmereUI:RefreshPage()
                    end,
                    isSynced = function()
                        local v = SB().overrideNumRows or 1
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            if (EAB.db.profile.bars[key].overrideNumRows or 1) ~= v then return false end
                        end
                        return true
                    end,
                    flashTargets = function() return { rgn } end,
                    multiApply = {
                        elementKeys   = GROUP_BAR_ORDER,
                        elementLabels = SHORT_LABELS,
                        getCurrentKey = function() return SelectedKey() end,
                        onApply       = function(checkedKeys)
                            local v = SB().overrideNumRows or 1
                            for _, key in ipairs(checkedKeys) do
                                EAB.db.profile.bars[key].overrideNumRows = v
                                EAB:ApplyIconRowOverrides(key)
                            end
                            EllesmereUI:RefreshPage()
                        end,
                    },
                })
            end
            do
                local rightRgn = row._rightRegion
                local isVert = SVal("orientation", "horizontal") == "vertical"
                local growDirValues, growDirOrder
                if isVert then
                    growDirValues = { up = "Up", down = "Down", center = "Centered" }
                    growDirOrder  = { "up", "down", "center" }
                else
                    growDirValues = { left = "Left", right = "Right", center = "Centered" }
                    growDirOrder  = { "left", "right", "center" }
                end
                EllesmereUI.BuildInlineCog(rightRgn, {
                    title = "Row Settings",
                    anchorTo = rightRgn._control,
                    rows = {
                        { type="dropdown", label="Grow Direction",
                          values=growDirValues, order=growDirOrder,
                          get=function()
                              local val = SVal("growDirection", "up")
                              if not growDirValues[val] then return "center" end
                              return val
                          end,
                          set=function(v)
                              SSet("growDirection", v, function(k) EAB:ApplyIconRowOverrides(k) end)
                              SUpdatePreviewAndResize()
                          end },
                    },
                })
            end

            -- Icon Order "default"/"reversed" map onto the legacy reverseIconOrder boolean (kept in
            -- sync for older readers); corner values place button 1 in that corner of the grid.
            do
                local orientRow
                orientRow, h = W:DualRow(parent, y,
                    { type="toggle", text="Vertical Orientation",
                      disabled=function()
                          return not EAB:BarSupportsOrientation(SelectedKey())
                      end,
                      disabledTooltip="This option is not supported for this bar type",
                      rawTooltip=true,
                      labelOnlyTooltip=true,
                      getValue=function()
                          return not EAB:GetOrientationForBar(SelectedKey())
                      end,
                      setValue=function(v)
                          EAB:SetOrientationForBar(SelectedKey(), not v)
                          SUpdatePreviewAndResize()
                          EllesmereUI:RefreshPage()
                      end,
                      tooltip="Toggle between horizontal and vertical bar layout." },
                    { type="dropdown", text="Icon Order",
                      tooltip="Order of the buttons on this bar; corner options place the first button in that corner.",
                      values={ default="Default", reversed="Reversed", TOPLEFT="Top Left", TOPRIGHT="Top Right", BOTTOMLEFT="Bottom Left", BOTTOMRIGHT="Bottom Right" },
                      order={ "default", "reversed", "TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT" },
                      getValue=function()
                          local v = SVal("iconOrder", nil)
                          if v == nil then
                              v = SVal("reverseIconOrder", false) and "reversed" or "default"
                          end
                          return v
                      end,
                      setValue=function(v)
                          SDB().reverseIconOrder = (v == "reversed")
                          SSet("iconOrder", v, function(k) EAB:ApplyIconRowOverrides(k) end)
                          SUpdatePreviewAndResize()
                      end });  y = y - h
                do
                    local rgn = orientRow._leftRegion
                    EllesmereUI.BuildSyncIcon({
                        region  = rgn,
                        tooltip = "Apply Orientation to all Bars",
                        onClick = function()
                            local isHoriz = EAB:GetOrientationForBar(SelectedKey())
                            for _, key in ipairs(GROUP_BAR_ORDER) do
                                if EAB:BarSupportsOrientation(key) then
                                    EAB:SetOrientationForBar(key, isHoriz)
                                end
                            end
                            EllesmereUI:RefreshPage()
                        end,
                        isSynced = function()
                            local isHoriz = EAB:GetOrientationForBar(SelectedKey())
                            for _, key in ipairs(GROUP_BAR_ORDER) do
                                if EAB:BarSupportsOrientation(key) and EAB:GetOrientationForBar(key) ~= isHoriz then return false end
                            end
                            return true
                        end,
                        flashTargets = function() return { rgn } end,
                        multiApply = {
                            elementKeys   = GROUP_BAR_ORDER,
                            elementLabels = SHORT_LABELS,
                            getCurrentKey = function() return SelectedKey() end,
                            onApply       = function(checkedKeys)
                                local isHoriz = EAB:GetOrientationForBar(SelectedKey())
                                for _, key in ipairs(checkedKeys) do
                                    if EAB:BarSupportsOrientation(key) then
                                        EAB:SetOrientationForBar(key, isHoriz)
                                    end
                                end
                                EllesmereUI:RefreshPage()
                            end,
                        },
                    })
                end

                -- Disabled: the dedicated BAR BACKGROUND section below owns these.
                if false then
                do
                    local rgn = orientRow._rightRegion
                    EllesmereUI.BuildSyncIcon({
                        region  = rgn,
                        tooltip = "Apply Background Settings to all Bars",
                        onClick = function()
                            local s = SB()
                            local en = s.bgEnabled
                            local c = s.bgColor
                            local bc = s.bgBorderColor
                            local px = s.bgPadX or 0
                            local py = s.bgPadY or 0
                            for _, key in ipairs(GROUP_BAR_ORDER) do
                                local bs = EAB.db.profile.bars[key]
                                bs.bgEnabled = en
                                if c then bs.bgColor = { r=c.r, g=c.g, b=c.b, a=c.a } end
                                bs.bgPadX = px
                                bs.bgPadY = py
                                bs.bgBorderThickness = s.bgBorderThickness
                                bs.bgBorderTexture = s.bgBorderTexture
                                bs.bgBorderSize = s.bgBorderSize
                                if bc then bs.bgBorderColor = { r=bc.r, g=bc.g, b=bc.b, a=bc.a } end
                                EAB:ApplyBackgroundForBar(key)
                            end
                            EllesmereUI:RefreshPage()
                        end,
                        isSynced = function()
                            local s = SB()
                            local en = s.bgEnabled or false
                            local px = s.bgPadX or 0
                            local py = s.bgPadY or 0
                            for _, key in ipairs(GROUP_BAR_ORDER) do
                                local bs = EAB.db.profile.bars[key]
                                if (bs.bgEnabled or false) ~= en then return false end
                                if (bs.bgPadX or 0) ~= px then return false end
                                if (bs.bgPadY or 0) ~= py then return false end
                                if (bs.bgBorderThickness or "none") ~= (s.bgBorderThickness or "none") then return false end
                                if (bs.bgBorderTexture or "solid") ~= (s.bgBorderTexture or "solid") then return false end
                                if (bs.bgBorderSize or 1) ~= (s.bgBorderSize or 1) then return false end
                            end
                            return true
                        end,
                        flashTargets = function() return { rgn } end,
                        multiApply = {
                            elementKeys   = GROUP_BAR_ORDER,
                            elementLabels = SHORT_LABELS,
                            getCurrentKey = function() return SelectedKey() end,
                            onApply       = function(checkedKeys)
                                local s = SB()
                                local en = s.bgEnabled
                                local c = s.bgColor
                                local bc = s.bgBorderColor
                                local px = s.bgPadX or 0
                                local py = s.bgPadY or 0
                                for _, key in ipairs(checkedKeys) do
                                    local bs = EAB.db.profile.bars[key]
                                    bs.bgEnabled = en
                                    if c then bs.bgColor = { r=c.r, g=c.g, b=c.b, a=c.a } end
                                    bs.bgPadX = px
                                    bs.bgPadY = py
                                    bs.bgBorderThickness = s.bgBorderThickness
                                    bs.bgBorderTexture = s.bgBorderTexture
                                    bs.bgBorderBehind = s.bgBorderBehind
                                    bs.bgBorderSize = s.bgBorderSize
                                    if bc then bs.bgBorderColor = { r=bc.r, g=bc.g, b=bc.b, a=bc.a } end
                                    EAB:ApplyBackgroundForBar(key)
                                end
                                EllesmereUI:RefreshPage()
                            end,
                        },
                    })
                end
                do
                    local bgRgn = orientRow._rightRegion
                    local bgColorGet = function()
                        local c = SGet("bgColor")
                        if not c then return 0, 0, 0, 0.5 end
                        return c.r, c.g, c.b, c.a
                    end
                    local bgColorSet = function(r, g, b, a)
                        SSetColor("bgColor", r, g, b, a, function(k) EAB:ApplyBackgroundForBar(k) end)
                        SUpdatePreview()
                    end
                    local bgSwatch, bgUpdateSwatch = EllesmereUI.BuildColorSwatch(bgRgn, bgRgn:GetFrameLevel() + 5, bgColorGet, bgColorSet, true, 20)
                    PP.Point(bgSwatch, "RIGHT", bgRgn._control, "LEFT", -12, 0)
                    bgRgn._lastInline = bgSwatch
                    EllesmereUI.RegisterWidgetRefresh(function()
                        local off = BgDisabled()
                        bgSwatch:SetAlpha(off and 0.15 or 1)
                        bgUpdateSwatch()
                    end)
                    bgSwatch:SetAlpha(BgDisabled() and 0.15 or 1)
                    local bgSwatchOrigClick = bgSwatch:GetScript("OnClick")
                    bgSwatch:SetScript("OnClick", function(self, ...)
                        if BgDisabled() then return end
                        if bgSwatchOrigClick then bgSwatchOrigClick(self, ...) end
                    end)
                    bgSwatch:SetScript("OnEnter", function(self)
                        if BgDisabled() then
                            EllesmereUI.ShowWidgetTooltip(self, EllesmereUI.DisabledTooltip("Bar Background"))
                        end
                    end)
                    bgSwatch:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)

                    EllesmereUI.BuildInlineCog(bgRgn, {
                        title = "Bar Background Settings",
                        icon = EllesmereUI.RESIZE_ICON, gap = 9,
                        disabled = BgDisabled, disabledTooltip = "Bar Background",
                        rows = {
                            { type="slider", label="Width", min=0, max=40, step=1,
                              get=function() return SVal("bgPadX", 0) end,
                              set=function(v)
                                  SSet("bgPadX", v, function(k) EAB:ApplyBackgroundForBar(k) end)
                                  SUpdatePreview()
                              end },
                            { type="slider", label="Height", min=0, max=40, step=1,
                              get=function() return SVal("bgPadY", 0) end,
                              set=function(v)
                                  SSet("bgPadY", v, function(k) EAB:ApplyBackgroundForBar(k) end)
                                  SUpdatePreview()
                              end },
                        },
                    })
                end
                end
            end

            -- Called later, directly below ICON EFFECTS; defined here to share the layout helpers' callbacks instead of duplicating them.
            local function BuildBarBackgroundSection()
            -------------------------------------------------------------------
            --  BAR BACKGROUND
            -------------------------------------------------------------------
            _, h = W:SectionHeader(parent, "BAR BACKGROUND", y);  y = y - h

            local bgOptionsRow
            bgOptionsRow, h = W:DualRow(parent, y,
                { type="toggle", text="Enable Bar Background",
                  getValue=function() return SVal("bgEnabled", false) end,
                  -- Section gate: rows below are hidden (not grayed) while off; the wrapper forces the page rebuild.
                  setValue=EllesmereUI.SectionToggleSetValue(function(v)
                      SSet("bgEnabled", v, function(k) EAB:ApplyBackgroundForBar(k) end)
                      SUpdatePreview()
                  end) },
                { type="slider", text="Spacing", min=0, max=20, step=1,
                  disabled=BgDisabled,
                  disabledTooltip="Bar Background",
                  getValue=function()
                      local v = SGet("bgPadding")
                      if v ~= nil then return v end
                      return math.max(SVal("bgPadX", 0), SVal("bgPadY", 0))
                  end,
                  setValue=function(v)
                      SB().bgPadX, SB().bgPadY = nil, nil
                      SSet("bgPadding", v, function(k) EAB:ApplyBackgroundForBar(k) end)
                      SUpdatePreview()
                  end });  y = y - h

            do
                local region = bgOptionsRow._leftRegion
                EllesmereUI.BuildSyncIcon({
                    region=region,
                    tooltip="Apply Bar Background Enable to all Bars",
                    onClick=function()
                        local enabled = SVal("bgEnabled", false)
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            EAB.db.profile.bars[key].bgEnabled = enabled
                            EAB:ApplyBackgroundForBar(key)
                        end
                        EllesmereUI:RefreshPage()
                    end,
                    isSynced=function()
                        local enabled = SVal("bgEnabled", false)
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            if (EAB.db.profile.bars[key].bgEnabled or false) ~= enabled then return false end
                        end
                        return true
                    end,
                    flashTargets=function() return { region } end,
                    multiApply={
                        elementKeys=GROUP_BAR_ORDER,
                        elementLabels=SHORT_LABELS,
                        getCurrentKey=function() return SelectedKey() end,
                        onApply=function(checkedKeys)
                            local enabled = SVal("bgEnabled", false)
                            for _, key in ipairs(checkedKeys) do
                                EAB.db.profile.bars[key].bgEnabled = enabled
                                EAB:ApplyBackgroundForBar(key)
                            end
                            EllesmereUI:RefreshPage()
                        end,
                    },
                })
            end

            do
                local region = bgOptionsRow._rightRegion
                local function CurrentSpacing(settings)
                    if settings.bgPadding ~= nil then return settings.bgPadding end
                    return math.max(settings.bgPadX or 0, settings.bgPadY or 0)
                end
                local function ApplySpacingTo(key)
                    local target = EAB.db.profile.bars[key]
                    target.bgPadding = CurrentSpacing(SB())
                    target.bgPadX = nil
                    target.bgPadY = nil
                    EAB:ApplyBackgroundForBar(key)
                end
                EllesmereUI.BuildSyncIcon({
                    region=region,
                    tooltip="Apply Bar Background Spacing to all Bars",
                    onClick=function()
                        for _, key in ipairs(GROUP_BAR_ORDER) do ApplySpacingTo(key) end
                        EllesmereUI:RefreshPage()
                    end,
                    isSynced=function()
                        local spacing = CurrentSpacing(SB())
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            if CurrentSpacing(EAB.db.profile.bars[key]) ~= spacing then return false end
                        end
                        return true
                    end,
                    flashTargets=function() return { region } end,
                    multiApply={
                        elementKeys=GROUP_BAR_ORDER,
                        elementLabels=SHORT_LABELS,
                        getCurrentKey=function() return SelectedKey() end,
                        onApply=function(checkedKeys)
                            for _, key in ipairs(checkedKeys) do ApplySpacingTo(key) end
                            EllesmereUI:RefreshPage()
                        end,
                    },
                })
            end

            local function BackgroundOpacity(settings)
                if settings.bgOpacity ~= nil then return settings.bgOpacity end
                local color = settings.bgColor
                return ((color and color.a) or 0.5) * 100
            end

            -- Section gate: everything below the master row is built only while Bar Background is
            -- enabled for the selected bar (Enable toggle's SectionToggleSetValue rebuilds on flip).
            if SVal("bgEnabled", false) then

            local bgColorRow
            bgColorRow, h = W:DualRow(parent, y,
                { type="colorpicker", text="Background Color", hasAlpha=false,
                  disabled=BgDisabled,
                  disabledTooltip="Bar Background",
                  getValue=function()
                      local c = SGet("bgColor") or { r=0, g=0, b=0, a=0.5 }
                      return c.r, c.g, c.b, 1
                  end,
                  setValue=function(r, g, b)
                      local old = SGet("bgColor") or { a=0.5 }
                      SSetColor("bgColor", r, g, b, old.a or 0.5,
                          function(k) EAB:ApplyBackgroundForBar(k) end)
                      SUpdatePreview()
                  end },
                { type="slider", text="Background Opacity", min=0, max=100, step=1,
                  disabled=BgDisabled,
                  disabledTooltip="Bar Background",
                  getValue=function() return BackgroundOpacity(SB()) end,
                  setValue=function(v)
                      SSet("bgOpacity", v, function(k) EAB:ApplyBackgroundForBar(k) end)
                      SUpdatePreview()
                  end });  y = y - h

            do
                local region = bgColorRow._leftRegion
                local function ApplyColorTo(key)
                    local source = SGet("bgColor") or { r=0, g=0, b=0, a=0.5 }
                    local target = EAB.db.profile.bars[key]
                    local old = target.bgColor
                    target.bgColor = { r=source.r, g=source.g, b=source.b,
                        a=(old and old.a) or source.a or 0.5 }
                    EAB:ApplyBackgroundForBar(key)
                end
                EllesmereUI.BuildSyncIcon({
                    region=region,
                    tooltip="Apply Background Color to all Bars",
                    onClick=function()
                        for _, key in ipairs(GROUP_BAR_ORDER) do ApplyColorTo(key) end
                        EllesmereUI:RefreshPage()
                    end,
                    isSynced=function()
                        local color = SGet("bgColor") or { r=0, g=0, b=0 }
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            local target = EAB.db.profile.bars[key].bgColor or { r=0, g=0, b=0 }
                            if target.r ~= color.r or target.g ~= color.g or target.b ~= color.b then
                                return false
                            end
                        end
                        return true
                    end,
                    flashTargets=function() return { region } end,
                    multiApply={
                        elementKeys=GROUP_BAR_ORDER,
                        elementLabels=SHORT_LABELS,
                        getCurrentKey=function() return SelectedKey() end,
                        onApply=function(checkedKeys)
                            for _, key in ipairs(checkedKeys) do ApplyColorTo(key) end
                            EllesmereUI:RefreshPage()
                        end,
                    },
                })
            end

            do
                local region = bgColorRow._rightRegion
                local function ApplyOpacityTo(key)
                    local target = EAB.db.profile.bars[key]
                    target.bgOpacity = BackgroundOpacity(SB())
                    EAB:ApplyBackgroundForBar(key)
                end
                EllesmereUI.BuildSyncIcon({
                    region=region,
                    tooltip="Apply Background Opacity to all Bars",
                    onClick=function()
                        for _, key in ipairs(GROUP_BAR_ORDER) do ApplyOpacityTo(key) end
                        EllesmereUI:RefreshPage()
                    end,
                    isSynced=function()
                        local opacity = BackgroundOpacity(SB())
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            if BackgroundOpacity(EAB.db.profile.bars[key]) ~= opacity then return false end
                        end
                        return true
                    end,
                    flashTargets=function() return { region } end,
                    multiApply={
                        elementKeys=GROUP_BAR_ORDER,
                        elementLabels=SHORT_LABELS,
                        getCurrentKey=function() return SelectedKey() end,
                        onApply=function(checkedKeys)
                            for _, key in ipairs(checkedKeys) do ApplyOpacityTo(key) end
                            EllesmereUI:RefreshPage()
                        end,
                    },
                })
            end

            do
                local texValues, texOrder = EllesmereUI.GetBorderTextureDropdown()
                local bgBorderRow
                bgBorderRow, h = W:DualRow(parent, y,
                    { type="dropdown", text="Border Style",
                      disabled=BgDisabled,
                      disabledTooltip="Bar Background Border",
                      values=texValues, order=texOrder,
                      getValue=function() return SVal("bgBorderTexture", "solid") end,
                      setValue=function(v)
                          local color, behind = EllesmereUI.GetBorderStyleSelectDefaults(v)
                          SSet("bgBorderTexture", v, function(k)
                              local settings = EAB.db.profile.bars[k]
                              settings.bgBorderOffsetX = nil
                              settings.bgBorderOffsetY = nil
                              settings.bgBorderShiftX = nil
                              settings.bgBorderShiftY = nil
                              -- A style pick resets the border: a set exact size goes with it (false travels, nil would not).
                              if settings.bgBorderThicknessPx then settings.bgBorderThicknessPx = false end
                              settings.bgBorderBehind = behind
                              settings.bgBorderColor = { r=color.r, g=color.g, b=color.b, a=1 }
                              EAB:ApplyBackgroundForBar(k)
                          end)
                          SUpdatePreview()
                          -- Full rebuild: the Width/Height Offset row exists only for a textured style.
                          EllesmereUI:RefreshPage(true)
                      end },
                    EllesmereUI.BorderPxSliderCfg{ text="Border Size",
                      disabled=BgDisabled,
                      disabledTooltip="Bar Background Border",
                      -- The step ApplyBackgroundForBar renders with: a thickness with no
                      -- entry (unknown, or the number an old SharedMedia pick stored) is 0, hidden.
                      getStep=function()
                          local entry = ns.BORDER_THICKNESS[SVal("bgBorderThickness", "none")]
                          return entry and entry.regular or 0
                      end,
                      setStep=function(step) SB().bgBorderThickness = EllesmereUI.BORDER_LABEL_OF_STEP[step] end,
                      getTex=function() return SVal("bgBorderTexture", "solid") end,
                      getPx=function() return SGet("bgBorderThicknessPx") end,
                      setPx=function(v) SB().bgBorderThicknessPx = v end,
                      apply=function()
                          EAB:ApplyBackgroundForBar(SelectedKey())
                          EllesmereUI:RefreshPage()
                          SUpdatePreview()
                      end });  y = y - h

                -- Width Offset | Height Offset: the textured border's outward offsets, their
                -- own row while a textured style is selected (Solid has none; the style
                -- setter rebuilds the page). Shown = the override, else the "actionbars"
                -- registry default for the thickness key ApplyBackgroundForBar passes.
                do
                    local bgTex = SVal("bgBorderTexture", "solid")
                    if bgTex ~= "" and bgTex ~= "solid" then
                        local ocfgL, ocfgR = EllesmereUI.BorderOffsetRowCfgs{
                            addonKey="actionbars",
                            disabled=BgDisabled,
                            disabledTooltip="Bar Background Border",
                            getTex=function() return SVal("bgBorderTexture", "solid") end,
                            getStep=function()
                                local entry = ns.BORDER_THICKNESS[SVal("bgBorderThickness", "none")]
                                return entry and entry.regular or 0
                            end,
                            getSizeKey=function() return SVal("bgBorderThickness", "none") end,
                            getPx=function() return SGet("bgBorderThicknessPx") end,
                            getX=function() return SGet("bgBorderOffsetX") end,
                            setX=function(v) SB().bgBorderOffsetX = v end,
                            getY=function() return SGet("bgBorderOffsetY") end,
                            setY=function(v) SB().bgBorderOffsetY = v end,
                            apply=function()
                                EAB:ApplyBackgroundForBar(SelectedKey())
                                EllesmereUI:RefreshPage()
                                SUpdatePreview()
                            end }
                        _, h = W:DualRow(parent, y, ocfgL, ocfgR);  y = y - h
                    end
                end

                do
                    local region = bgBorderRow._rightRegion
                    local borderSwatch, refreshBorder = EllesmereUI.BuildColorSwatch(region, region:GetFrameLevel() + 5,
                        function()
                            local c = SGet("bgBorderColor") or { r=0, g=0, b=0, a=1 }
                            return c.r, c.g, c.b, c.a
                        end,
                        function(r, g, b, a)
                            SSetColor("bgBorderColor", r, g, b, a, function(k) EAB:ApplyBackgroundForBar(k) end)
                            SUpdatePreview()
                    end, true, 20)
                    PP.Point(borderSwatch, "RIGHT", region._control, "LEFT", -12, 0)
                    region._lastInline = borderSwatch
                    EllesmereUI.RegisterWidgetRefresh(function()
                        local disabled = BgDisabled() or SVal("bgBorderThickness", "none") == "none"
                        borderSwatch:SetAlpha(disabled and 0.15 or 1)
                        refreshBorder()
                    end)
                end

                do
                    local region = bgBorderRow._rightRegion
                    local function ApplySizeTo(key)
                        local source = SB()
                        local target = EAB.db.profile.bars[key]
                        target.bgBorderThickness = source.bgBorderThickness
                        do
                            local v = source.bgBorderThicknessPx
                            if v == nil and target.bgBorderThicknessPx ~= nil then v = false end
                            target.bgBorderThicknessPx = v
                        end
                        local color = source.bgBorderColor
                        if color then
                            target.bgBorderColor = { r=color.r, g=color.g, b=color.b, a=color.a }
                        end
                        EAB:ApplyBackgroundForBar(key)
                    end
                    EllesmereUI.BuildSyncIcon({
                        region=region,
                        tooltip="Apply Background Border Size and Color to all Bars",
                        onClick=function()
                            for _, key in ipairs(GROUP_BAR_ORDER) do ApplySizeTo(key) end
                            EllesmereUI:RefreshPage()
                        end,
                        isSynced=function()
                            local thickness = SVal("bgBorderThickness", "none")
                            local thicknessPx = SGet("bgBorderThicknessPx") or false   -- nil and false render alike
                            local color = SGet("bgBorderColor") or { r=0, g=0, b=0, a=1 }
                            for _, key in ipairs(GROUP_BAR_ORDER) do
                                local target = EAB.db.profile.bars[key]
                                if (target.bgBorderThickness or "none") ~= thickness then return false end
                                if (target.bgBorderThicknessPx or false) ~= thicknessPx then return false end
                                local targetColor = target.bgBorderColor or { r=0, g=0, b=0, a=1 }
                                if targetColor.r ~= color.r or targetColor.g ~= color.g
                                    or targetColor.b ~= color.b or targetColor.a ~= color.a then return false end
                            end
                            return true
                        end,
                        flashTargets=function() return { region } end,
                        multiApply={
                            elementKeys=GROUP_BAR_ORDER,
                            elementLabels=SHORT_LABELS,
                            getCurrentKey=function() return SelectedKey() end,
                            onApply=function(checkedKeys)
                                for _, key in ipairs(checkedKeys) do ApplySizeTo(key) end
                                EllesmereUI:RefreshPage()
                            end,
                        },
                    })
                end

                do
                    local region = bgBorderRow._leftRegion
                    -- The offsets/shifts the background border renders with when none is
                    -- set: its registry defaults (looked up as before), scaled to an exact
                    -- size when one is set, as ApplyBackgroundForBar draws them.
                    local function BgBorderDefaults()
                        local texture = SVal("bgBorderTexture", "solid")
                        local thickness = SVal("bgBorderThickness", "thin")
                        local entry = ns.BORDER_THICKNESS[SVal("bgBorderThickness", "none")]
                        local step = entry and entry.regular or 0
                        local px = EllesmereUI.BorderPx(SGet("bgBorderThicknessPx"), step, texture)
                        return ShownBorderDefaults(texture, thickness, step, px)
                    end
                    local offsetButton = EllesmereUI.BuildInlineCog(region, {
                        icon = EllesmereUI.DIRECTIONS_ICON, anchorTo = region._control,
                        title="Border Options",
                        captureRegion=region,
                        rows={
                            { type="slider", label="Shift X", min=-10, max=10, step=1,
                              get=function()
                                  local value = SGet("bgBorderShiftX")
                                  if value ~= nil then return value end
                                  local _, _, defaultX = BgBorderDefaults()
                                  return defaultX
                              end,
                              set=function(v)
                                  -- The shift shown by default stores nil (follow the style again).
                                  local _, _, defaultX = BgBorderDefaults()
                                  if v == math.floor(defaultX + 0.5) then v = nil end
                                  SSet("bgBorderShiftX", v, function(k) EAB:ApplyBackgroundForBar(k) end)
                                  SUpdatePreview()
                              end },
                            { type="slider", label="Shift Y", min=-10, max=10, step=1,
                              get=function()
                                  local value = SGet("bgBorderShiftY")
                                  if value ~= nil then return value end
                                  local _, _, _, defaultY = BgBorderDefaults()
                                  return defaultY
                              end,
                              set=function(v)
                                  local _, _, _, defaultY = BgBorderDefaults()
                                  if v == math.floor(defaultY + 0.5) then v = nil end
                                  SSet("bgBorderShiftY", v, function(k) EAB:ApplyBackgroundForBar(k) end)
                                  SUpdatePreview()
                              end },
                            { type="toggle", label="Show Behind",
                              get=function() return SVal("bgBorderBehind", false) end,
                              set=function(v)
                                  SSet("bgBorderBehind", v, function(k) EAB:ApplyBackgroundForBar(k) end)
                                  SUpdatePreview()
                              end },
                        },
                    })
                    if offsetButton then
                        local function UpdateOffsetButton()
                            offsetButton:SetShown(not BgDisabled())
                        end
                        EllesmereUI.RegisterWidgetRefresh(UpdateOffsetButton)
                        UpdateOffsetButton()
                    end
                end

                do
                    local region = bgBorderRow._leftRegion
                    local function ApplyStyleTo(key)
                        local source = SB()
                        local target = EAB.db.profile.bars[key]
                        target.bgBorderTexture = source.bgBorderTexture
                        target.bgBorderOffsetX = source.bgBorderOffsetX
                        target.bgBorderOffsetY = source.bgBorderOffsetY
                        target.bgBorderShiftX = source.bgBorderShiftX
                        target.bgBorderShiftY = source.bgBorderShiftY
                        target.bgBorderBehind = source.bgBorderBehind
                        EAB:ApplyBackgroundForBar(key)
                    end
                    EllesmereUI.BuildSyncIcon({
                        region=region,
                        tooltip="Apply Background Border Style to all Bars",
                        onClick=function()
                            for _, key in ipairs(GROUP_BAR_ORDER) do ApplyStyleTo(key) end
                            EllesmereUI:RefreshPage()
                        end,
                        isSynced=function()
                            local source = SB()
                            for _, key in ipairs(GROUP_BAR_ORDER) do
                                local target = EAB.db.profile.bars[key]
                                if (target.bgBorderTexture or "solid") ~= (source.bgBorderTexture or "solid") then return false end
                                if target.bgBorderOffsetX ~= source.bgBorderOffsetX then return false end
                                if target.bgBorderOffsetY ~= source.bgBorderOffsetY then return false end
                                if target.bgBorderShiftX ~= source.bgBorderShiftX then return false end
                                if target.bgBorderShiftY ~= source.bgBorderShiftY then return false end
                                if (target.bgBorderBehind or false) ~= (source.bgBorderBehind or false) then return false end
                            end
                            return true
                        end,
                        flashTargets=function() return { region } end,
                        multiApply={
                            elementKeys=GROUP_BAR_ORDER,
                            elementLabels=SHORT_LABELS,
                            getCurrentKey=function() return SelectedKey() end,
                            onApply=function(checkedKeys)
                                for _, key in ipairs(checkedKeys) do ApplyStyleTo(key) end
                                EllesmereUI:RefreshPage()
                            end,
                        },
                    })
                end
            end

            local bgMultiplierRow
            bgMultiplierRow, h = W:DualRow(parent, y,
                { type="slider", text="Multiplier X", min=1, max=4, step=1,
                  disabled=BgDisabled,
                  disabledTooltip="Bar Background",
                  getValue=function() return SVal("bgMultiplierX", 1) end,
                  setValue=function(v)
                      SSet("bgMultiplierX", v, function(k) EAB:ApplyBackgroundForBar(k) end)
                      SUpdatePreviewAndResize()
                  end },
                { type="slider", text="Multiplier Y", min=1, max=4, step=1,
                  disabled=BgDisabled,
                  disabledTooltip="Bar Background",
                  getValue=function() return SVal("bgMultiplierY", 1) end,
                  setValue=function(v)
                      SSet("bgMultiplierY", v, function(k) EAB:ApplyBackgroundForBar(k) end)
                      SUpdatePreviewAndResize()
                  end });  y = y - h

            do
                local region = bgMultiplierRow._leftRegion
                EllesmereUI.BuildInlineCog(region, { icon = EllesmereUI.DIRECTIONS_ICON, anchorTo = region._control,
                    title="Multiplier X Settings",
                    captureRegion=region,
                    rows={{ type="dropdown", label="Growth Direction",
                        values={ left="Left", right="Right" }, order={ "left", "right" },
                        get=function() return SVal("bgExpandDirectionX", "right") end,
                        set=function(v)
                            SSet("bgExpandDirectionX", v, function(k) EAB:ApplyBackgroundForBar(k) end)
                            SUpdatePreviewAndResize()
                        end }},
                })
            end

            do
                local region = bgMultiplierRow._rightRegion
                EllesmereUI.BuildInlineCog(region, { icon = EllesmereUI.DIRECTIONS_ICON, anchorTo = region._control,
                    title="Multiplier Y Settings",
                    captureRegion=region,
                    rows={{ type="dropdown", label="Growth Direction",
                        values={ up="Up", down="Down" }, order={ "up", "down" },
                        get=function() return SVal("bgExpandDirectionY", "up") end,
                        set=function(v)
                            SSet("bgExpandDirectionY", v, function(k) EAB:ApplyBackgroundForBar(k) end)
                            SUpdatePreviewAndResize()
                        end }},
                })
            end

            end -- bgEnabled section gate
            end

            -------------------------------------------------------------------
            --  ICON APPEARANCE
            -------------------------------------------------------------------
            iconsSectionHeader, h = W:SectionHeader(parent, SECTION_ICON_APPEARANCE, y);  y = y - h
            y = EllesmereUI.BlizzStyle.Note(parent, y, "actionbars")

            -- Stock mode (Blizzard Style or Classic WoW UI): the shared gate.
            local function BlizzStyleOn()
                return EllesmereUI.BlizzStyle.Get("actionbars")
            end

            -- "No custom shape" also covers "cropped" and unset.
            local function ShapeIsNone()
                local v = SGet("buttonShape")
                return v == "none" or v == "cropped" or v == nil
            end
            local function ShapeIsCustom()
                return not ShapeIsNone()
            end

            local SHAPE_VALUES = {
                none     = "None",
                cropped  = "Cropped",
                square   = "Square",
                circle   = "Circle",
                csquare  = "Curved Square",
                diamond  = "Diamond",
                hexagon  = "Hexagon",
                portrait = "Portrait",
                shield   = "Shield",
            }
            local SHAPE_ORDER = { "none", "cropped", "---", "square", "circle", "csquare", "diamond", "hexagon", "portrait", "shield" }

            local abBsRow
            do
                local texValues, texOrder = EllesmereUI.GetBorderTextureDropdown()
                -- Border Size: a custom shape's ring is on/off, so it keeps the None/Strong
                -- dropdown; every other shape gets the pixel slider over the same key and
                -- its borderThicknessPx companion. The shape setter rebuilds the page so the
                -- slot follows the shape; a bar switch already rebuilds.
                local sizeCfg
                if ShapeIsCustom() then
                    sizeCfg = { type="dropdown", text="Border Size",
                      disabled=BlizzStyleOn, disabledTooltip="Blizzard Style Action Bars", requireState="disabled",
                      values=ns.BORDER_THICKNESS_LABELS, order=ns.BORDER_THICKNESS_ORDER,
                      itemDisabled=function(val)
                          if ShapeIsCustom() and (val == "thin" or val == "normal" or val == "heavy") then return true end
                          return false
                      end,
                      itemDisabledTooltip=function(val)
                          if ShapeIsCustom() and (val == "thin" or val == "normal" or val == "heavy") then
                              return "This option requires a non-custom shape to be selected"
                          end
                      end,
                      getValue=function()
                          local v = SGet("borderThickness")
                          return v or "thin"
                      end,
                      setValue=function(v)
                          SSet("borderThickness", v, function(k)
                              local entry = ns.BORDER_THICKNESS[v]
                              if entry then
                                  local shape = EAB.db.profile.bars[k].buttonShape or "none"
                                  if shape ~= "none" and shape ~= "cropped" then
                                      EAB.db.profile.bars[k].shapeBorderSize = entry.shape
                                      EAB.db.profile.bars[k].shapeBorderEnabled = entry.shape > 0
                                  else
                                      EAB.db.profile.bars[k].borderSize = entry.regular
                                      EAB.db.profile.bars[k].borderEnabled = entry.regular > 0
                                  end
                              end
                              EAB:ApplyBordersForBar(k)
                              EAB:ApplyShapesForBar(k)
                          end)
                          SUpdatePreview()
                      end }
                else
                    sizeCfg = EllesmereUI.BorderPxSliderCfg{ text="Border Size",
                      disabled=BlizzStyleOn, disabledTooltip="Blizzard Style Action Bars", requireState="disabled",
                      -- The step the buttons render with (ResolveBorderThickness's regular
                      -- column): an unknown or numeric thickness is thin.
                      getStep=function()
                          local entry = ns.BORDER_THICKNESS[SGet("borderThickness") or "thin"] or ns.BORDER_THICKNESS.thin
                          return entry.regular
                      end,
                      -- Exactly what the dropdown wrote for a non-custom shape: the label and its mirrors.
                      setStep=function(step)
                          local s = SB()
                          local label = EllesmereUI.BORDER_LABEL_OF_STEP[step]
                          s.borderThickness = label
                          local entry = ns.BORDER_THICKNESS[label]
                          if entry then
                              s.borderSize = entry.regular
                              s.borderEnabled = entry.regular > 0
                          end
                      end,
                      getTex=function() return SGet("borderTexture") or "solid" end,
                      getPx=function() return SGet("borderThicknessPx") end,
                      setPx=function(v) SB().borderThicknessPx = v end,
                      apply=function()
                          local k = SelectedKey()
                          EAB:ApplyBordersForBar(k)
                          EAB:ApplyShapesForBar(k)
                          EllesmereUI:RefreshPage()
                          SUpdatePreview()
                      end }
                end
                abBsRow, h = W:DualRow(parent, y,
                    EllesmereUI.BlizzStyle.Gate("actionbars", { type="dropdown", text="Border Style",
                      disabled=function() return BlizzStyleOn() or ShapeIsCustom() end,
                      disabledTooltip=function() if ShapeIsCustom() then return "This option requires a non-custom button shape" end return EllesmereUI.DisabledTooltip(EllesmereUI.BlizzStyle.Label("actionbars"), "disabled") end,
                      rawTooltip=true,
                      values=texValues, order=texOrder,
                      getValue=function() return SGet("borderTexture") or "solid" end,
                      setValue=function(v)
                          local defTh = EllesmereUI.GetBorderDefaultSize("actionbars", v)
                          -- An unregistered SharedMedia border answers the NUMBER 1; this key stores labels.
                          if type(defTh) == "number" then defTh = EllesmereUI.BORDER_LABEL_OF_STEP[defTh] or "thin" end
                          SSet("borderTexture", v, function(k)
                              EAB.db.profile.bars[k].borderTextureOffset = nil
                              EAB.db.profile.bars[k].borderTextureOffsetY = nil
                              EAB.db.profile.bars[k].borderTextureShiftX = nil
                              EAB.db.profile.bars[k].borderTextureShiftY = nil
                              -- A style pick resets the size to the style's default: a set exact size goes with it (false travels, nil would not).
                              if EAB.db.profile.bars[k].borderThicknessPx then EAB.db.profile.bars[k].borderThicknessPx = false end
                              local _bcol, _bbehind = EllesmereUI.GetBorderStyleSelectDefaults(v)
                              EAB.db.profile.bars[k].borderColor = { r = _bcol.r, g = _bcol.g, b = _bcol.b, a = 1 }
                              EAB.db.profile.bars[k].borderClassColor = false
                              EAB.db.profile.bars[k].borderBehind = _bbehind
                              if defTh then
                                  EAB.db.profile.bars[k].borderThickness = defTh
                                  local entry = ns.BORDER_THICKNESS[defTh]
                                  if entry then
                                      local shape = EAB.db.profile.bars[k].buttonShape or "none"
                                      if shape ~= "none" and shape ~= "cropped" then
                                          EAB.db.profile.bars[k].shapeBorderSize = entry.shape
                                          EAB.db.profile.bars[k].shapeBorderEnabled = entry.shape > 0
                                      else
                                          EAB.db.profile.bars[k].borderSize = entry.regular
                                          EAB.db.profile.bars[k].borderEnabled = entry.regular > 0
                                      end
                                  end
                              end
                              EAB:ApplyBordersForBar(k)
                              EAB:ApplyShapesForBar(k)
                          end)
                          SUpdatePreview()
                          -- Full rebuild: the Width/Height Offset row exists only for a textured style.
                          EllesmereUI:RefreshPage(true)
                      end }),
                    EllesmereUI.BlizzStyle.Gate("actionbars", sizeCfg));  y = y - h
                -- Width Offset | Height Offset: the textured border's outward offsets, their
                -- own row while a textured style is selected (Solid has none; the style
                -- setter rebuilds the page). Shown = the override, else the "actionbars"
                -- registry default for the step and thickness key ApplyBordersForBar and the
                -- shape repaint pass (ResolveBorderThickness), scaled to an exact size as drawn.
                do
                    local btnTex = SGet("borderTexture") or "solid"
                    if btnTex ~= "" and btnTex ~= "solid" then
                        local ocfgL, ocfgR = EllesmereUI.BorderOffsetRowCfgs{
                            addonKey="actionbars",
                            disabled=BlizzStyleOn, disabledTooltip="Blizzard Style Action Bars", requireState="disabled",
                            getTex=function() return SGet("borderTexture") or "solid" end,
                            getStep=function() return (ns.ResolveBorderThickness(SB())) end,
                            getSizeKey=function() return SGet("borderThickness") or "thin" end,
                            getPx=function() return SGet("borderThicknessPx") end,
                            getX=function() return SGet("borderTextureOffset") end,
                            setX=function(v) SB().borderTextureOffset = v end,
                            getY=function() return SGet("borderTextureOffsetY") end,
                            setY=function(v) SB().borderTextureOffsetY = v end,
                            apply=function()
                                EAB:ApplyBordersForBar(SelectedKey())
                                EllesmereUI:RefreshPage()
                                SUpdatePreview()
                            end }
                        _, h = W:DualRow(parent, y,
                            EllesmereUI.BlizzStyle.Gate("actionbars", ocfgL),
                            EllesmereUI.BlizzStyle.Gate("actionbars", ocfgR));  y = y - h
                    end
                end
                do
                    local rgn = abBsRow._leftRegion
                    -- The offsets/shifts the buttons render with when none is set: the
                    -- step's registry defaults (looked up as before), scaled to an exact
                    -- size when one is set, as ApplyButtonBorders draws them.
                    local function ButtonBorderDefaults()
                        local tex = SGet("borderTexture") or "solid"
                        local th = SGet("borderThickness") or "thin"
                        local step, px = ns.ResolveBorderThickness(SB())
                        return ShownBorderDefaults(tex, th, step, px)
                    end
                    local cogBtn = EllesmereUI.BuildInlineCog(rgn, {
                        icon = EllesmereUI.DIRECTIONS_ICON, anchorTo = rgn._control,
                        title = "Border Options",
                        captureRegion = rgn,
                        rows = {
                            { type = "slider", label = "Shift X", min = -10, max = 10, step = 1,
                              get = function()
                                  local v = SGet("borderTextureShiftX")
                                  if v then return v end
                                  local _, _, dsx = ButtonBorderDefaults()
                                  return dsx
                              end,
                              set = function(v)
                                  -- The shift shown by default stores nil (follow the style again).
                                  local _, _, dsx = ButtonBorderDefaults()
                                  if v == math.floor(dsx + 0.5) then v = nil end
                                  SSet("borderTextureShiftX", v, function(k)
                                      EAB:ApplyBordersForBar(k)
                                  end)
                                  SUpdatePreview()
                              end },
                            { type = "slider", label = "Shift Y", min = -10, max = 10, step = 1,
                              get = function()
                                  local v = SGet("borderTextureShiftY")
                                  if v then return v end
                                  local _, _, _, dsy = ButtonBorderDefaults()
                                  return dsy
                              end,
                              set = function(v)
                                  local _, _, _, dsy = ButtonBorderDefaults()
                                  if v == math.floor(dsy + 0.5) then v = nil end
                                  SSet("borderTextureShiftY", v, function(k)
                                      EAB:ApplyBordersForBar(k)
                                  end)
                                  SUpdatePreview()
                              end },
                            { type = "toggle", label = "Show Behind",
                              get = function() return SGet("borderBehind") or false end,
                              set = function(v)
                                  SSet("borderBehind", v == false and nil or v, function(k)
                                      EAB:ApplyBordersForBar(k)
                                  end)
                                  SUpdatePreview(); EllesmereUI:RefreshPage()
                              end },
                            -- The inverse of Show Behind, which wins: the runtime
                            -- ignores this flag while Show Behind is on.
                            { type = "toggle", label = "Border Above Effects",
                              tooltip = "Draws this bar's button borders over proc glows, the assisted highlight and the cooldown swipe.",
                              disabled = function()
                                  return BlizzStyleOn() or ShapeIsCustom() or (SGet("borderBehind") and true or false)
                              end,
                              disabledTooltip = function()
                                  if BlizzStyleOn() then return EllesmereUI.DisabledTooltip(EllesmereUI.BlizzStyle.Label("actionbars"), "disabled") end
                                  if ShapeIsCustom() then return "This option requires a non-custom button shape" end
                                  return EllesmereUI.DisabledTooltip("Show Behind", "disabled")
                              end,
                              rawTooltip = true,
                              get = function() return SGet("borderAboveEffects") or false end,
                              set = function(v)
                                  SSet("borderAboveEffects", v and true or false, function(k)
                                      EAB:ApplyBordersForBar(k)
                                  end)
                                  SUpdatePreview()
                              end },
                        },
                    })
                    if cogBtn then
                        local function UpdateCogVis()
                            cogBtn:SetShown((SGet("borderTexture") or "solid") ~= "solid")
                        end
                        EllesmereUI.RegisterWidgetRefresh(UpdateCogVis)
                        UpdateCogVis()
                    end
                end
                local bsLeftRgn = abBsRow._leftRegion
                EllesmereUI.BuildSyncIcon({
                    region  = bsLeftRgn,
                    tooltip = "Apply Border Style to all Bars",
                    onClick = function()
                        local bt = SB().borderTexture or "solid"
                        local ox = SB().borderTextureOffset
                        local oy = SB().borderTextureOffsetY
                        local sx = SB().borderTextureShiftX
                        local sy = SB().borderTextureShiftY
                        local bh = SB().borderBehind
                        local ba = SB().borderAboveEffects
                        local bc = SB().borderColor
                        local bcc = SB().borderClassColor
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            EAB.db.profile.bars[key].borderTexture = bt
                            EAB.db.profile.bars[key].borderTextureOffset = ox
                            EAB.db.profile.bars[key].borderTextureOffsetY = oy
                            EAB.db.profile.bars[key].borderTextureShiftX = sx
                            EAB.db.profile.bars[key].borderTextureShiftY = sy
                            EAB.db.profile.bars[key].borderBehind = bh
                            EAB.db.profile.bars[key].borderAboveEffects = ba
                            if bc then EAB.db.profile.bars[key].borderColor = { r=bc.r, g=bc.g, b=bc.b, a=bc.a } end
                            EAB.db.profile.bars[key].borderClassColor = bcc
                            EAB:ApplyBordersForBar(key)
                        end
                        EllesmereUI:RefreshPage()
                    end,
                    isSynced = function()
                        local bt = SB().borderTexture or "solid"
                        local ox = SB().borderTextureOffset
                        local oy = SB().borderTextureOffsetY
                        local sx = SB().borderTextureShiftX
                        local sy = SB().borderTextureShiftY
                        local bh = SB().borderBehind or false
                        local ba = SB().borderAboveEffects or false
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            if (EAB.db.profile.bars[key].borderTexture or "solid") ~= bt then return false end
                            if EAB.db.profile.bars[key].borderTextureOffset ~= ox then return false end
                            if EAB.db.profile.bars[key].borderTextureOffsetY ~= oy then return false end
                            if EAB.db.profile.bars[key].borderTextureShiftX ~= sx then return false end
                            if EAB.db.profile.bars[key].borderTextureShiftY ~= sy then return false end
                            if (EAB.db.profile.bars[key].borderBehind or false) ~= bh then return false end
                            if (EAB.db.profile.bars[key].borderAboveEffects or false) ~= ba then return false end
                        end
                        return true
                    end,
                    flashTargets = function() return { bsLeftRgn } end,
                    multiApply = {
                        elementKeys   = GROUP_BAR_ORDER,
                        elementLabels = SHORT_LABELS,
                        getCurrentKey = function() return SelectedKey() end,
                        onApply       = function(checkedKeys)
                            local bt = SB().borderTexture or "solid"
                            local ox = SB().borderTextureOffset
                            local oy = SB().borderTextureOffsetY
                            local sx = SB().borderTextureShiftX
                            local sy = SB().borderTextureShiftY
                            local bh = SB().borderBehind
                            local ba = SB().borderAboveEffects
                            local bc = SB().borderColor
                            local bcc = SB().borderClassColor
                            for _, key in ipairs(checkedKeys) do
                                EAB.db.profile.bars[key].borderTexture = bt
                                EAB.db.profile.bars[key].borderTextureOffset = ox
                                EAB.db.profile.bars[key].borderTextureOffsetY = oy
                                EAB.db.profile.bars[key].borderTextureShiftX = sx
                                EAB.db.profile.bars[key].borderTextureShiftY = sy
                                EAB.db.profile.bars[key].borderBehind = bh
                                EAB.db.profile.bars[key].borderAboveEffects = ba
                                if bc then EAB.db.profile.bars[key].borderColor = { r=bc.r, g=bc.g, b=bc.b, a=bc.a } end
                                EAB.db.profile.bars[key].borderClassColor = bcc
                                EAB:ApplyBordersForBar(key)
                            end
                            EllesmereUI:RefreshPage()
                        end,
                    },
                })
            end

            do
                local rightRgn = abBsRow._rightRegion
                local ctrl = rightRgn._control

                local classBorderSwatch, updateClassBorderSwatch = EllesmereUI.BuildColorSwatch(
                    rightRgn, abBsRow:GetFrameLevel() + 3,
                    function()
                        local _, ct = UnitClass("player")
                        local cc = ct and RAID_CLASS_COLORS and RAID_CLASS_COLORS[ct]
                        if cc then return cc.r, cc.g, cc.b end
                        return 1, 1, 1
                    end,
                    function() end,
                    false, 20)
                PP.Point(classBorderSwatch, "RIGHT", ctrl, "LEFT", -8, 0)
                classBorderSwatch:SetScript("OnClick", function()
                    SSet("borderClassColor", true, function(k)
                        EAB:ApplyBordersForBar(k)
                        EAB:ApplyShapesForBar(k)
                    end)
                    SUpdatePreview()
                    EllesmereUI:RefreshPage()
                end)
                classBorderSwatch:SetScript("OnEnter", function()
                    EllesmereUI.ShowWidgetTooltip(classBorderSwatch, "Class Colored")
                end)
                classBorderSwatch:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)

                local customSwatch, updateCustomSwatch = EllesmereUI.BuildColorSwatch(
                    rightRgn, abBsRow:GetFrameLevel() + 3,
                    function()
                        local c = SGet("borderColor")
                        if not c then return 0, 0, 0 end
                        return c.r, c.g, c.b
                    end,
                    function(r, g, b)
                        SSetColor("borderColor", r, g, b, nil, function(k)
                            EAB:ApplyBordersForBar(k)
                            EAB:ApplyShapesForBar(k)
                        end)
                        SSetColor("shapeBorderColor", r, g, b, nil, function(k)
                            EAB:ApplyShapesForBar(k)
                        end)
                        SUpdatePreview()
                    end,
                    false, 20)
                PP.Point(customSwatch, "RIGHT", classBorderSwatch, "LEFT", -8, 0)
                customSwatch:SetScript("OnEnter", function()
                    EllesmereUI.ShowWidgetTooltip(customSwatch, "Custom Color")
                end)
                customSwatch:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)

                -- Click the dimmed custom swatch to switch back from class color (no block overlay)
                local origClick = customSwatch:GetScript("OnClick")
                customSwatch:SetScript("OnClick", function(self, ...)
                    if SGet("borderClassColor") then
                        SSet("borderClassColor", false, function(k)
                            EAB:ApplyBordersForBar(k)
                            EAB:ApplyShapesForBar(k)
                        end)
                        SUpdatePreview()
                        EllesmereUI:RefreshPage()
                        return
                    end
                    -- No border selected: allow swapping boxes but do not open the color picker
                    if (SGet("borderThickness") or "thin") == "none" then return end
                    if origClick then origClick(self, ...) end
                end)

                local function UpdateBorderSwatchState()
                    local isClassColored = SGet("borderClassColor")
                    local isNone = (SGet("borderThickness") or "thin") == "none"
                    customSwatch:SetAlpha((isClassColored or isNone) and 0.3 or 1)
                    classBorderSwatch:SetAlpha((isClassColored and not isNone) and 1 or 0.3)
                end
                EllesmereUI.RegisterWidgetRefresh(function() updateCustomSwatch(); updateClassBorderSwatch(); UpdateBorderSwatchState() end)
                UpdateBorderSwatchState()
            end

            do
                local rgn = abBsRow._rightRegion
                EllesmereUI.BuildSyncIcon({
                    region  = rgn,
                    tooltip = "Apply Border Size and Color to all Bars",
                    onClick = function()
                        local th = SB().borderThickness
                        local thPx = SB().borderThicknessPx   -- copied as is (string, false or nil)
                        local c = SB().borderColor
                        local cc = SB().borderClassColor
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            EAB.db.profile.bars[key].borderThickness = th
                            do
                                local t = EAB.db.profile.bars[key]
                                local v = thPx
                                if v == nil and t.borderThicknessPx ~= nil then v = false end
                                t.borderThicknessPx = v
                            end
                            local entry = ns.BORDER_THICKNESS[th]
                            if entry then
                                local shape = EAB.db.profile.bars[key].buttonShape or "none"
                                if shape ~= "none" and shape ~= "cropped" then
                                    EAB.db.profile.bars[key].shapeBorderSize = entry.shape
                                    EAB.db.profile.bars[key].shapeBorderEnabled = entry.shape > 0
                                else
                                    EAB.db.profile.bars[key].borderSize = entry.regular
                                    EAB.db.profile.bars[key].borderEnabled = entry.regular > 0
                                end
                            end
                            if c then
                                EAB.db.profile.bars[key].borderColor = { r=c.r, g=c.g, b=c.b, a=c.a }
                                EAB.db.profile.bars[key].shapeBorderColor = { r=c.r, g=c.g, b=c.b, a=c.a }
                            end
                            EAB.db.profile.bars[key].borderClassColor = cc
                            EAB:ApplyBordersForBar(key)
                            EAB:ApplyShapesForBar(key)
                        end
                        EllesmereUI:RefreshPage()
                    end,
                    isSynced = function()
                        local th = SB().borderThickness or "thin"
                        local thPx = SB().borderThicknessPx or false   -- nil and false render alike
                        local cc = SB().borderClassColor or false
                        local c = SB().borderColor
                        local cr, cg, cb, ca = c and c.r or 0, c and c.g or 0, c and c.b or 0, c and c.a or 1
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            if (EAB.db.profile.bars[key].borderThickness or "thin") ~= th then return false end
                            if (EAB.db.profile.bars[key].borderThicknessPx or false) ~= thPx then return false end
                            if (EAB.db.profile.bars[key].borderClassColor or false) ~= cc then return false end
                            local bc = EAB.db.profile.bars[key].borderColor
                            if (bc and bc.r or 0) ~= cr or (bc and bc.g or 0) ~= cg or (bc and bc.b or 0) ~= cb or (bc and bc.a or 1) ~= ca then return false end
                        end
                        return true
                    end,
                    flashTargets = function() return { rgn } end,
                    multiApply = {
                        elementKeys   = GROUP_BAR_ORDER,
                        elementLabels = SHORT_LABELS,
                        getCurrentKey = function() return SelectedKey() end,
                        onApply       = function(checkedKeys)
                            local th = SB().borderThickness
                            local thPx = SB().borderThicknessPx   -- copied as is (string, false or nil)
                            local c = SB().borderColor
                            local cc = SB().borderClassColor
                            for _, key in ipairs(checkedKeys) do
                                EAB.db.profile.bars[key].borderThickness = th
                                do
                                local t = EAB.db.profile.bars[key]
                                local v = thPx
                                if v == nil and t.borderThicknessPx ~= nil then v = false end
                                t.borderThicknessPx = v
                            end
                                local entry = ns.BORDER_THICKNESS[th]
                                if entry then
                                    local shape = EAB.db.profile.bars[key].buttonShape or "none"
                                    if shape ~= "none" and shape ~= "cropped" then
                                        EAB.db.profile.bars[key].shapeBorderSize = entry.shape
                                        EAB.db.profile.bars[key].shapeBorderEnabled = entry.shape > 0
                                    else
                                        EAB.db.profile.bars[key].borderSize = entry.regular
                                        EAB.db.profile.bars[key].borderEnabled = entry.regular > 0
                                    end
                                end
                                if c then
                                    EAB.db.profile.bars[key].borderColor = { r=c.r, g=c.g, b=c.b, a=c.a }
                                    EAB.db.profile.bars[key].shapeBorderColor = { r=c.r, g=c.g, b=c.b, a=c.a }
                                end
                                EAB.db.profile.bars[key].borderClassColor = cc
                                EAB:ApplyBordersForBar(key)
                                EAB:ApplyShapesForBar(key)
                            end
                            EllesmereUI:RefreshPage()
                        end,
                    },
                })
            end

            local classColorBorderRow
            classColorBorderRow, h = W:DualRow(parent, y,
                EllesmereUI.BlizzStyle.Gate("actionbars", { type="dropdown", text="Custom Button Shape",
                  disabled=BlizzStyleOn, disabledTooltip="Blizzard Style Action Bars", requireState="disabled",
                  values=SHAPE_VALUES, order=SHAPE_ORDER,
                  itemDisabled=function(val)
                      if val ~= "none" and val ~= "cropped" and (SGet("borderTexture") or "solid") ~= "solid" then return true end
                      return false
                  end,
                  itemDisabledTooltip=function(val)
                      if val ~= "none" and val ~= "cropped" and (SGet("borderTexture") or "solid") ~= "solid" then
                          return "This option requires the Border Style to be set to Solid"
                      end
                  end,
                  getValue=function()
                      local v = SGet("buttonShape")
                      return v or "none"
                  end,
                  setValue=function(v)
                      -- Set icon zoom BEFORE shapes: ApplyShapesForBar -> ApplyShapeToButton reads the new value.
                      SSet("iconZoom", ns.SHAPE_ZOOM_DEFAULTS[v] or 5.5)
                      SSet("buttonShape", v, function(k)
                          -- Reset border thickness to the default for the new shape mode
                          if v ~= "none" and v ~= "cropped" then
                              EAB.db.profile.bars[k].borderThickness = ns.BORDER_THICKNESS_DEFAULT_SHAPE
                              local entry = ns.BORDER_THICKNESS[ns.BORDER_THICKNESS_DEFAULT_SHAPE]
                              EAB.db.profile.bars[k].shapeBorderSize = entry.shape
                              EAB.db.profile.bars[k].shapeBorderEnabled = true
                          else
                              EAB.db.profile.bars[k].borderThickness = ns.BORDER_THICKNESS_DEFAULT_REGULAR
                              local entry = ns.BORDER_THICKNESS[ns.BORDER_THICKNESS_DEFAULT_REGULAR]
                              EAB.db.profile.bars[k].borderSize = entry.regular
                              EAB.db.profile.bars[k].borderEnabled = true
                          end
                          -- Default keybind/count text for cropped vs normal (offsets keep a
                          -- positioned text's corner spacing)
                          if v == "cropped" then
                              EAB.db.profile.bars[k].keybindFontSize = 11
                              EAB.db.profile.bars[k].countFontSize = 11
                              EAB.ApplyShapeTextOffsets(EAB.db.profile.bars[k], 0, 1, 0, -1)
                          else
                              EAB.db.profile.bars[k].keybindFontSize = 12
                              EAB.db.profile.bars[k].countFontSize = 12
                              EAB.ApplyShapeTextOffsets(EAB.db.profile.bars[k], 0, 0, 0, 0)
                          end
                          EAB:ApplyShapesForBar(k)
                          EAB:ApplyPaddingForBar(k)
                          EAB:ApplyBordersForBar(k)
                          EAB:ApplyFontsForBar(k)
                          EAB:ApplyIconBackgroundForBar(k)
                      end)
                      EAB:RefreshProcGlows()
                      SUpdatePreview()
                      -- Full rebuild: the Border Size slot is a dropdown for a custom shape
                      -- and the pixel slider otherwise, and only a rebuild swaps it.
                      EllesmereUI:RefreshPage(true)
                  end }),
                EllesmereUI.BlizzStyle.Gate("actionbars", { type="slider", text="Icon Zoom", min=0, max=10, step=0.5,
                  disabled=BlizzStyleOn, disabledTooltip="Blizzard Style Action Bars", requireState="disabled",
                  getValue=function() return SVal("iconZoom", EAB.db.profile.iconZoom or 5.5) end,
                  setValue=function(v)
                      SSet("iconZoom", v, function(k)
                          EAB:ApplyBordersForBar(k)
                          EAB:ApplyShapesForBar(k)
                      end)
                      SUpdatePreview()
                  end }));  y = y - h
            borderRow = classColorBorderRow
            do
                local rgn = classColorBorderRow._leftRegion
                EllesmereUI.BuildSyncIcon({
                    region  = rgn,
                    tooltip = "Apply Custom Button Shape to all Bars",
                    onClick = function()
                        local v = SGet("buttonShape") or "none"
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            local bs = EAB.db.profile.bars[key]
                            bs.iconZoom = ns.SHAPE_ZOOM_DEFAULTS[v] or 5.5
                            bs.buttonShape = v
                            if v ~= "none" and v ~= "cropped" then
                                bs.borderThickness = ns.BORDER_THICKNESS_DEFAULT_SHAPE
                                local entry = ns.BORDER_THICKNESS[ns.BORDER_THICKNESS_DEFAULT_SHAPE]
                                bs.shapeBorderSize = entry.shape
                                bs.shapeBorderEnabled = true
                            else
                                bs.borderThickness = ns.BORDER_THICKNESS_DEFAULT_REGULAR
                                local entry = ns.BORDER_THICKNESS[ns.BORDER_THICKNESS_DEFAULT_REGULAR]
                                bs.borderSize = entry.regular
                                bs.borderEnabled = true
                            end
                            if v == "cropped" then
                                bs.keybindFontSize = 11; bs.countFontSize = 11
                                EAB.ApplyShapeTextOffsets(bs, 0, 1, 0, -1)
                            else
                                bs.keybindFontSize = 12; bs.countFontSize = 12
                                EAB.ApplyShapeTextOffsets(bs, 0, 0, 0, 0)
                            end
                            EAB:ApplyShapesForBar(key)
                            EAB:ApplyPaddingForBar(key)
                            EAB:ApplyBordersForBar(key)
                            EAB:ApplyFontsForBar(key)
                        end
                        EAB:RefreshProcGlows()
                        SUpdatePreview()
                        EllesmereUI:RefreshPage()
                    end,
                    isSynced = function()
                        local v = SGet("buttonShape") or "none"
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            if (EAB.db.profile.bars[key].buttonShape or "none") ~= v then return false end
                        end
                        return true
                    end,
                    flashTargets = function() return { rgn } end,
                    multiApply = {
                        elementKeys   = GROUP_BAR_ORDER,
                        elementLabels = SHORT_LABELS,
                        getCurrentKey = function() return SelectedKey() end,
                        onApply       = function(checkedKeys)
                            local v = SGet("buttonShape") or "none"
                            for _, key in ipairs(checkedKeys) do
                                local bs = EAB.db.profile.bars[key]
                                bs.iconZoom = ns.SHAPE_ZOOM_DEFAULTS[v] or 5.5
                                bs.buttonShape = v
                                if v ~= "none" and v ~= "cropped" then
                                    bs.borderThickness = ns.BORDER_THICKNESS_DEFAULT_SHAPE
                                    local entry = ns.BORDER_THICKNESS[ns.BORDER_THICKNESS_DEFAULT_SHAPE]
                                    bs.shapeBorderSize = entry.shape
                                    bs.shapeBorderEnabled = true
                                else
                                    bs.borderThickness = ns.BORDER_THICKNESS_DEFAULT_REGULAR
                                    local entry = ns.BORDER_THICKNESS[ns.BORDER_THICKNESS_DEFAULT_REGULAR]
                                    bs.borderSize = entry.regular
                                    bs.borderEnabled = true
                                end
                                if v == "cropped" then
                                    bs.keybindFontSize = 11; bs.countFontSize = 11
                                    EAB.ApplyShapeTextOffsets(bs, 0, 1, 0, -1)
                                else
                                    bs.keybindFontSize = 12; bs.countFontSize = 12
                                    EAB.ApplyShapeTextOffsets(bs, 0, 0, 0, 0)
                                end
                                EAB:ApplyShapesForBar(key)
                                EAB:ApplyPaddingForBar(key)
                                EAB:ApplyBordersForBar(key)
                                EAB:ApplyFontsForBar(key)
                            end
                            EAB:RefreshProcGlows()
                            SUpdatePreview()
                            EllesmereUI:RefreshPage()
                        end,
                    },
                })
            end

            do
                local rgn = classColorBorderRow._rightRegion
                EllesmereUI.BuildSyncIcon({
                    region  = rgn,
                    tooltip = "Apply Icon Zoom to all Bars",
                    onClick = function()
                        local v = SB().iconZoom or EAB.db.profile.iconZoom or 5.5
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            EAB.db.profile.bars[key].iconZoom = v
                            EAB:ApplyBordersForBar(key)
                            EAB:ApplyShapesForBar(key)
                        end
                        EllesmereUI:RefreshPage()
                    end,
                    isSynced = function()
                        local v = SB().iconZoom or EAB.db.profile.iconZoom or 5.5
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            if (EAB.db.profile.bars[key].iconZoom or EAB.db.profile.iconZoom or 5.5) ~= v then return false end
                        end
                        return true
                    end,
                    flashTargets = function() return { rgn } end,
                    multiApply = {
                        elementKeys   = GROUP_BAR_ORDER,
                        elementLabels = SHORT_LABELS,
                        getCurrentKey = function() return SelectedKey() end,
                        onApply       = function(checkedKeys)
                            local v = SB().iconZoom or EAB.db.profile.iconZoom or 5.5
                            for _, key in ipairs(checkedKeys) do
                                EAB.db.profile.bars[key].iconZoom = v
                                EAB:ApplyBordersForBar(key)
                                EAB:ApplyShapesForBar(key)
                            end
                            EllesmereUI:RefreshPage()
                        end,
                    },
                })
            end

            -- "Show Cooldown Numbers" LIVE-toggles Blizzard's countdownForCooldowns CVar and is never
            -- stored in our DB; the CVar is written only on an actual user flip.
            local zoomIbgRow
            zoomIbgRow, h = W:DualRow(parent, y,
                { type="toggle", text="Show Blizzard Icon Background",
                  tooltip="Shows Blizzard's default icon slot background texture behind empty action bar slots.",
                  getValue=function() return EAB.db.profile.showBlizzIconBg or false end,
                  setValue=function(v)
                      EAB.db.profile.showBlizzIconBg = v
                      for _, info in ipairs(ns.BAR_CONFIG or {}) do
                          EAB:ApplyIconBackgroundForBar(info.key)
                      end
                      EllesmereUI:RefreshPage()
                  end },
                { type="toggle", text="Show Cooldown Numbers",
                  tooltip="Toggles Blizzard's Show Numbers for Cooldowns setting, which will show number text on any spells that are on cooldown on your action bars.",
                  getValue=function() return GetCVarBool("countdownForCooldowns") end,
                  setValue=function(v)
                      if InCombatLockdown() then return end
                      SetCVar("countdownForCooldowns", v and "1" or "0")
                      -- Refresh so the inline cog dims/undims with the CVar state.
                      EllesmereUI:RefreshPage()
                  end });  y = y - h
            do
                local rgn = zoomIbgRow._leftRegion
                EllesmereUI.BuildInlineCog(rgn, {
                    title = "Icon Background",
                    anchorTo = rgn._control,
                    disabled = function() return not (EAB.db.profile.showBlizzIconBg or false) end,
                    disabledTooltip = "Show Blizzard Icon Background",
                    rows = {
                        { type="slider", label="Opacity", min=0, max=100, step=1,
                          tooltip="Controls the opacity of the Blizzard icon slot background texture.",
                          get=function() return math.floor((EAB.db.profile.blizzIconBgAlpha or 1) * 100 + 0.5) end,
                          set=function(v)
                              EAB.db.profile.blizzIconBgAlpha = v / 100
                              for _, info in ipairs(ns.BAR_CONFIG or {}) do
                                  EAB:ApplyIconBackgroundForBar(info.key)
                              end
                          end },
                    },
                })
            end
            -- Inline cog: Show Cooldown Numbers (right). Holds the charge-spell recharge toggle
            -- (our feature, DB-saved); dimmed when the CVar is off, since no numbers show then.
            do
                local rgn = zoomIbgRow._rightRegion
                EllesmereUI.BuildInlineCog(rgn, {
                    title = "Cooldown Numbers",
                    anchorTo = rgn._control,
                    disabled = function() return not GetCVarBool("countdownForCooldowns") end,
                    disabledTooltip = "Show Cooldown Numbers",
                    rows = {
                        { type="toggle", label="Charge Recharge Numbers",
                          tooltip="Show the recharge countdown on charge spells while a charge is still banked. When off, the recharge timer only appears at 0 charges (Blizzard default).",
                          get=function() return EAB.db.profile.showChargeRechargeNumbers ~= false end,
                          set=function(v)
                              EAB.db.profile.showChargeRechargeNumbers = v
                              EAB:RefreshChargeRechargeNumbers()
                          end },
                    },
                })
            end

            local slotBgRow
            slotBgRow, h = W:DualRow(parent, y,
                EllesmereUI.BlizzStyle.Gate("actionbars", { type="slider", text="Icon Background", min=0, max=100, step=1,
                  tooltip="Controls the opacity of the flat color background behind action button icons.",
                  disabled=BlizzStyleOn, disabledTooltip="Blizzard Style Action Bars", requireState="disabled",
                  getValue=function()
                      local v = EAB.db.profile.slotBgOpacity
                      if v == nil then v = 50 end
                      return v
                  end,
                  setValue=function(v)
                      EAB.db.profile.slotBgOpacity = v
                      EAB:ApplySlotBackgroundColor()
                  end }),
                { type="toggle", text="One Button Assist Icon",
                  tooltip="Shows the rotation-helper ring on the button holding the One Button Assist action.",
                  getValue=function() return EAB.db.profile.obaIconEnabled ~= false end,
                  setValue=function(v)
                      EAB.db.profile.obaIconEnabled = v
                      if ns.RefreshAssistSpinners then ns.RefreshAssistSpinners() end
                  end });  y = y - h
            do
                local rgn = slotBgRow._rightRegion
                EllesmereUI.BuildInlineCog(rgn, { anchorTo = rgn._control,
                    title = "One Button Assist Icon",
                    rows = {
                        { type="slider", label="Icon Outset", min=0, max=30, step=1,
                          get=function() return EAB.db.profile.obaIconOutset or 9 end,
                          set=function(v)
                              EAB.db.profile.obaIconOutset = v
                              if ns.RefreshAssistSpinners then ns.RefreshAssistSpinners() end
                          end },
                    },
                })
            end
            -- Inline swatch: icon background color (left). Dimmed while a stock style is on (no slot background exists) or at 0 opacity.
            do
                local rgn = slotBgRow._leftRegion
                local function SbgOff()
                    if BlizzStyleOn() then return true end
                    local v = EAB.db.profile.slotBgOpacity
                    if v == nil then v = 50 end
                    return v == 0
                end
                local sbgSwatch, sbgUpdateSwatch = EllesmereUI.BuildColorSwatch(
                    rgn, slotBgRow:GetFrameLevel() + 3,
                    function()
                        local c = EAB.db.profile.slotBgColor or { r=0.15, g=0.15, b=0.15 }
                        return c.r, c.g, c.b, 1
                    end,
                    function(r, g, b)
                        EAB.db.profile.slotBgColor = { r = r, g = g, b = b }
                        EAB:ApplySlotBackgroundColor()
                    end,
                    false, 20)
                PP.Point(sbgSwatch, "RIGHT", rgn._control, "LEFT", -8, 0)
                rgn._lastInline = sbgSwatch
                sbgSwatch:SetAlpha(SbgOff() and 0.15 or 1)
                local sbgOrigClick = sbgSwatch:GetScript("OnClick")
                sbgSwatch:SetScript("OnClick", function(self, ...)
                    if SbgOff() then return end
                    if sbgOrigClick then sbgOrigClick(self, ...) end
                end)
                sbgSwatch:SetScript("OnEnter", function(self)
                    if SbgOff() then
                        if BlizzStyleOn() then
                            EllesmereUI.ShowWidgetTooltip(self, EllesmereUI.DisabledTooltip(EllesmereUI.BlizzStyle.Label("actionbars"), "disabled"))
                        else
                            EllesmereUI.ShowWidgetTooltip(self, EllesmereUI.DisabledTooltip("Set Icon Background above 0"))
                        end
                    end
                end)
                sbgSwatch:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
                EllesmereUI.RegisterWidgetRefresh(function()
                    sbgSwatch:SetAlpha(SbgOff() and 0.15 or 1)
                    sbgUpdateSwatch()
                end)
            end
            -------------------------------------------------------------------
            --  ICON EFFECTS
            -------------------------------------------------------------------
            _, h = W:SectionHeader(parent, "ICON EFFECTS", y);  y = y - h

            local dtRow
            dtRow, h = W:DualRow(parent, y,
                { type="toggle", text="Desaturate on Cooldown",
                  -- setValue runs a one-shot catch-up sweep: cooldown repaints happen on edges only, so an icon grey at uncheck time would stay grey.
                  tooltip="Desaturates (grays out) action button icons while the ability is on cooldown. GCD-only cooldowns are excluded.",
                  getValue=function() return EAB.db.profile.desaturateOnCooldown or false end,
                  setValue=function(v)
                      local p = EAB.db.profile
                      local was = p.desaturateOnCooldown or false
                      p.desaturateOnCooldown = v
                      if was ~= (v or false) and EAB._DesatSettingChanged then
                          EAB._DesatSettingChanged(v and true or false)
                      end
                  end },
                { type="toggle", text="Disable Tooltips",
                  getValue=function()
                      return SGet("disableTooltips") or false
                  end,
                  setValue=function(v)
                      SSet("disableTooltips", v)
                  end });  y = y - h
            do
                local rgn = dtRow._rightRegion
                EllesmereUI.BuildSyncIcon({
                    region  = rgn,
                    tooltip = "Apply Disable Tooltips to all Bars",
                    onClick = function()
                        local v = SB().disableTooltips or false
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            EAB.db.profile.bars[key].disableTooltips = v
                        end
                        EllesmereUI:RefreshPage()
                    end,
                    isSynced = function()
                        local v = SB().disableTooltips or false
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            if (EAB.db.profile.bars[key].disableTooltips or false) ~= v then return false end
                        end
                        return true
                    end,
                    flashTargets = function() return { rgn } end,
                    multiApply = {
                        elementKeys   = GROUP_BAR_ORDER,
                        elementLabels = SHORT_LABELS,
                        getCurrentKey = function() return SelectedKey() end,
                        onApply       = function(checkedKeys)
                            local v = SB().disableTooltips or false
                            for _, key in ipairs(checkedKeys) do
                                EAB.db.profile.bars[key].disableTooltips = v
                            end
                            EllesmereUI:RefreshPage()
                        end,
                    },
                })
            end

            local rangeRankRow
            rangeRankRow, h = W:DualRow(parent, y,
                { type="toggle", text="Out of Range Coloring",
                  getValue=function()
                      return SGet("outOfRangeColoring") or false
                  end,
                  setValue=function(v)
                      SSet("outOfRangeColoring", v, function() EAB:ApplyRangeColoring() end)
                      EllesmereUI:RefreshPage()
                  end },
                { type="toggle", text="Show Item Rank",
                  tooltip="Shows the consumable rank (quality) diamond icon on action buttons.",
                  getValue=function() return SGet("showRankIcon") or false end,
                  setValue=function(v)
                      SSet("showRankIcon", v)
                      if _G._EAB_Apply then _G._EAB_Apply() end
                  end });  y = y - h
            do
                local rgn = rangeRankRow._leftRegion
                EllesmereUI.BuildSyncIcon({
                    region  = rgn,
                    tooltip = "Apply Range Coloring to all Bars",
                    onClick = function()
                        local v = SB().outOfRangeColoring or false
                        local c = SB().outOfRangeColor
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            EAB.db.profile.bars[key].outOfRangeColoring = v
                            if c then EAB.db.profile.bars[key].outOfRangeColor = { r=c.r, g=c.g, b=c.b } end
                        end
                        EAB:ApplyRangeColoring(); EllesmereUI:RefreshPage()
                    end,
                    isSynced = function()
                        local v = SB().outOfRangeColoring or false
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            if (EAB.db.profile.bars[key].outOfRangeColoring or false) ~= v then return false end
                        end
                        return true
                    end,
                    flashTargets = function() return { rgn } end,
                    multiApply = {
                        elementKeys   = GROUP_BAR_ORDER,
                        elementLabels = SHORT_LABELS,
                        getCurrentKey = function() return SelectedKey() end,
                        onApply       = function(checkedKeys)
                            local v = SB().outOfRangeColoring or false
                            local c = SB().outOfRangeColor
                            for _, key in ipairs(checkedKeys) do
                                EAB.db.profile.bars[key].outOfRangeColoring = v
                                if c then EAB.db.profile.bars[key].outOfRangeColor = { r=c.r, g=c.g, b=c.b } end
                            end
                            EAB:ApplyRangeColoring(); EllesmereUI:RefreshPage()
                        end,
                    },
                })
            end
            do
                local leftRgn = rangeRankRow._leftRegion
                local rangeColorGet = function()
                    local c = SGet("outOfRangeColor")
                    if not c then return 0.7, 0.2, 0.2 end
                    return c.r, c.g, c.b
                end
                local rangeColorSet = function(r, g, b)
                    SSetColor("outOfRangeColor", r, g, b, nil, function() EAB:ApplyRangeColoring() end)
                end
                local rangeSwatch, rangeUpdateSwatch = EllesmereUI.BuildColorSwatch(leftRgn, leftRgn:GetFrameLevel() + 5, rangeColorGet, rangeColorSet, false, 20)
                PP.Point(rangeSwatch, "RIGHT", leftRgn._control, "LEFT", -12, 0)
                leftRgn._lastInline = rangeSwatch

                local function RangeDisabled()
                    return not SGet("outOfRangeColoring")
                end

                EllesmereUI.RegisterWidgetRefresh(function()
                    local off = RangeDisabled()
                    rangeSwatch:SetAlpha(off and 0.3 or 1)
                    rangeUpdateSwatch()
                end)
                rangeSwatch:SetAlpha(RangeDisabled() and 0.3 or 1)

                local rangeBlock = CreateFrame("Frame", nil, rangeSwatch)
                rangeBlock:SetAllPoints()
                rangeBlock:SetFrameLevel(rangeSwatch:GetFrameLevel() + 10)
                rangeBlock:EnableMouse(true)
                rangeBlock:SetScript("OnEnter", function()
                    EllesmereUI.ShowWidgetTooltip(rangeSwatch, EllesmereUI.DisabledTooltip("Out of Range Coloring"))
                end)
                rangeBlock:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
                EllesmereUI.RegisterWidgetRefresh(function()
                    rangeBlock:SetShown(RangeDisabled())
                end)
                rangeBlock:SetShown(RangeDisabled())
            end
            do
                local rgn = rangeRankRow._rightRegion
                EllesmereUI.BuildSyncIcon({
                    region  = rgn,
                    tooltip = "Apply Show Item Rank to all Bars",
                    onClick = function()
                        local v = SB().showRankIcon or false
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            EAB.db.profile.bars[key].showRankIcon = v
                        end
                        if _G._EAB_Apply then _G._EAB_Apply() end
                        EllesmereUI:RefreshPage()
                    end,
                    isSynced = function()
                        local v = SB().showRankIcon or false
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            if (EAB.db.profile.bars[key].showRankIcon or false) ~= v then return false end
                        end
                        return true
                    end,
                    flashTargets = function() return { rgn } end,
                    multiApply = {
                        elementKeys   = GROUP_BAR_ORDER,
                        elementLabels = SHORT_LABELS,
                        getCurrentKey = function() return SelectedKey() end,
                        onApply       = function(checkedKeys)
                            local v = SB().showRankIcon or false
                            for _, key in ipairs(checkedKeys) do
                                EAB.db.profile.bars[key].showRankIcon = v
                            end
                            if _G._EAB_Apply then _G._EAB_Apply() end
                            EllesmereUI:RefreshPage()
                        end,
                    },
                })
            end

            local cdEffectsRow
            cdEffectsRow, h = W:DualRow(parent, y,
                { type="slider", text="Alpha when on CD", min=0, max=100, step=5,
                  tooltip="Dims action button icons to this opacity while on cooldown (100 = off), using the same detection as Desaturate on Cooldown.",
                  getValue=function() return EAB.db.profile.alphaWhenOnCD or 100 end,
                  setValue=function(v)
                      EAB.db.profile.alphaWhenOnCD = v
                      if EAB.ApplyCDAlphaAll then EAB:ApplyCDAlphaAll() end
                  end },
                { type="slider", text="CD Swipe Opacity", min=0, max=100, step=5,
                  tooltip="Opacity of the cooldown swipe (the dark radial sweep); use the swatch to set its colour.",
                  getValue=function() return EAB.db.profile.cdSwipeAlpha or 80 end,
                  setValue=function(v)
                      EAB.db.profile.cdSwipeAlpha = v
                      if EAB.ApplyCooldownSwipeColor then EAB:ApplyCooldownSwipeColor() end
                  end });  y = y - h
            -- Inline swatch for CD Swipe Opacity (right): colour-only (hasAlpha=false), since alpha lives on the slider.
            do
                local rgn = cdEffectsRow._rightRegion
                local ctrl = rgn._control
                local swatch, updateSwatch = EllesmereUI.BuildColorSwatch(
                    rgn, cdEffectsRow:GetFrameLevel() + 5,
                    function()
                        local c = EAB.db.profile.cdSwipeColor or {}
                        return c.r or 0, c.g or 0, c.b or 0
                    end,
                    function(r, g, b)
                        EAB.db.profile.cdSwipeColor = { r = r, g = g, b = b }
                        if EAB.ApplyCooldownSwipeColor then EAB:ApplyCooldownSwipeColor() end
                    end,
                    false, 20)
                PP.Point(swatch, "RIGHT", ctrl, "LEFT", -8, 0)
                rgn._lastInline = swatch
                -- Canonical inline-swatch pattern: auto-disable at 0 opacity (invisible swipe has no visible colour).
                local function SwipeDisabled()
                    return (EAB.db.profile.cdSwipeAlpha or 80) == 0
                end
                local block = CreateFrame("Frame", nil, swatch)
                block:SetAllPoints(); block:SetFrameLevel(swatch:GetFrameLevel() + 10); block:EnableMouse(true)
                block:SetScript("OnEnter", function()
                    EllesmereUI.ShowWidgetTooltip(swatch, EllesmereUI.DisabledTooltip("Set CD Swipe Opacity above 0"))
                end)
                block:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
                EllesmereUI.RegisterWidgetRefresh(function()
                    updateSwatch()
                    local off = SwipeDisabled()
                    swatch:SetAlpha(off and 0.3 or 1)
                    block:SetShown(off)
                end)
                local off0 = SwipeDisabled()
                swatch:SetAlpha(off0 and 0.3 or 1)
                block:SetShown(off0)
            end

            -- Row: Hide Count at 0 (odd last slot -- blank right label)
            _, h = W:DualRow(parent, y,
                { type="toggle", text="Hide Charge Count at 0",
                  tooltip="Hide the charge number on action buttons when it reaches 0, instead of showing a 0. The number returns as soon as a charge or item comes back.",
                  getValue=function() return EAB.db.profile.hideZeroCount or false end,
                  setValue=function(v)
                      EAB.db.profile.hideZeroCount = v or nil
                      if EAB.RefreshAllCounts then EAB:RefreshAllCounts() end
                  end },
                { type="label", text="" });  y = y - h

            BuildBarBackgroundSection()

            -------------------------------------------------------------------
            --  PAGING (MainBar + Bars 2-8 only, not Stance/Pet/Micro/Bag)
            -------------------------------------------------------------------
            do
                local selKey = SelectedKey()
                local _bkp = ns.EAB_VTABLE and ns.EAB_VTABLE.BAR_KEY_TO_PAGE
                local showPaging = selKey and _bkp and _bkp[selKey]
                if showPaging then
                    _, h = W:SectionHeader(parent, "PAGING", y);  y = y - h

                    local _, playerClass = UnitClass("player")
                    local EAB_VT = ns.EAB_VTABLE or {}
                    local PG_STATES = EAB_VT.PAGING_STATES or {}
                    local BKP = EAB_VT.BAR_KEY_TO_PAGE or {}

                    local pagingValues = { none = "Default" }
                    local pagingOrder = { "none" }
                    local barList = {
                        { key = "MainBar", label = "Action Bar 1 (Main)" },
                        { key = "Bar2",    label = "Action Bar 2" },
                        { key = "Bar3",    label = "Action Bar 3" },
                        { key = "Bar4",    label = "Action Bar 4" },
                        { key = "Bar5",    label = "Action Bar 5" },
                        { key = "Bar6",    label = "Action Bar 6" },
                        { key = "Bar7",    label = "Action Bar 7" },
                        { key = "Bar8",    label = "Action Bar 8" },
                        { key = "Bar9",    label = "Action Bar 9" },
                        { key = "Bar10",   label = "Action Bar 10" },
                    }
                    for _, bl in ipairs(barList) do
                        -- Skip self (can't page a bar to itself)
                        if bl.key ~= selKey then
                            local pg = BKP[bl.key]
                            if pg then
                                pagingValues[tostring(pg)] = bl.label
                                pagingOrder[#pagingOrder + 1] = tostring(pg)
                            end
                        end
                    end

                    local function GetPagingVal(stateId)
                        local paging = SGet("paging")
                        if not paging then return "none" end
                        local v = paging[stateId]
                        if not v then return "none" end
                        return tostring(v)
                    end
                    local function SetPagingVal(stateId, val)
                        local bars = EAB.db.profile.bars[selKey]
                        if not bars.paging then bars.paging = {} end
                        if val == "none" then
                            -- nil, not false: the driver builder reads nil as "unconfigured -> native
                            -- form fallback", while false would suppress the form's bonusbar swap.
                            bars.paging[stateId] = nil
                        else
                            bars.paging[stateId] = tonumber(val)
                        end
                        -- Clean up: if all values are false (all disabled), reset
                        local anySet = false
                        for _, v in pairs(bars.paging) do
                            if v then anySet = true; break end
                        end
                        if not anySet then bars.paging = {} end
                        if ns.RebuildBarPaging then ns.RebuildBarPaging(selKey) end
                    end

                    -- Row 0: Auto-paging opt-outs (MainBar only -- the only bar the engine pages off
                    -- bonusbar). Suppresses implicit swaps only; an explicit page below still applies.
                    if selKey == "MainBar" then
                        local function SetAutoPageOptOut(key, v)
                            SSet(key, v, function(k)
                                if ns.RebuildBarPaging then ns.RebuildBarPaging(k) end
                            end)
                        end
                        _, h = W:DualRow(parent, y,
                            { type="toggle", text="Disable Form Paging",
                              getValue=function() return SGet("disableFormPaging") or false end,
                              setValue=function(v) SetAutoPageOptOut("disableFormPaging", v) end,
                              tooltip="Keep Action Bar 1 on its current page when you shapeshift, stealth, or change stance, instead of swapping to that form's bar.\n\nKeybinds follow what the bar shows, so the key always casts the icon you see. Press-and-hold repeat casting is turned off on Action Bar 1 while this is enabled." },
                            { type="toggle", text="Disable Skyriding Paging",
                              getValue=function() return SGet("disableSkyridingPaging") or false end,
                              setValue=function(v) SetAutoPageOptOut("disableSkyridingPaging", v) end,
                              tooltip="Keep Action Bar 1 on its current page while skyriding, instead of swapping to the skyriding bar.\n\nYour skyriding abilities live on that bar, so put them on another bar before enabling this. Press-and-hold repeat casting is turned off on Action Bar 1 while this is enabled." });  y = y - h
                    end

                    local pagingArrowsWidget
                    if selKey == "MainBar" then
                        pagingArrowsWidget = { type="toggle", text="Show Paging Arrows",
                          getValue=function() return SGet("showPagingArrows") or false end,
                          setValue=function(v)
                              SSet("showPagingArrows", v, function()
                                  if ns.LayoutPagingFrame then ns.LayoutPagingFrame() end
                              end)
                              EllesmereUI:RefreshPage()
                          end,
                          tooltip="Show page up/down arrows next to Action Bar 1 for cycling through action bar pages 1-6." }
                    else
                        pagingArrowsWidget = { type="label", text="" }
                    end
                    local pagingRow
                    pagingRow, h = W:DualRow(parent, y,
                        pagingArrowsWidget,
                        { type="dropdown", text="Shift Modifier",
                          values=pagingValues, order=pagingOrder,
                          getValue=function() return GetPagingVal("shift") end,
                          setValue=function(v) SetPagingVal("shift", v) end });  y = y - h

                    if selKey == "MainBar" then
                        local lRgn = pagingRow._leftRegion
                        local pagingOff = function() return not (SGet("showPagingArrows") or false) end
                        EllesmereUI.BuildInlineCog(lRgn, {
                            title = "Paging Arrow Settings",
                            anchorTo = lRgn._control,
                            disabled = pagingOff, disabledTooltip = "Show Paging Arrows",
                            rows = {
                                { type="toggle", label="Show Arrows on Right",
                                  get=function() return SGet("pagingArrowsRight") or false end,
                                  set=function(v)
                                      SSet("pagingArrowsRight", v, function()
                                          if ns.LayoutPagingFrame then ns.LayoutPagingFrame() end
                                      end)
                                  end },
                            },
                        })
                    end

                    _, h = W:DualRow(parent, y,
                        { type="dropdown", text="Ctrl Modifier",
                          values=pagingValues, order=pagingOrder,
                          getValue=function() return GetPagingVal("ctrl") end,
                          setValue=function(v) SetPagingVal("ctrl", v) end },
                        { type="dropdown", text="Alt Modifier",
                          values=pagingValues, order=pagingOrder,
                          getValue=function() return GetPagingVal("alt") end,
                          setValue=function(v) SetPagingVal("alt", v) end });  y = y - h

                    _, h = W:DualRow(parent, y,
                        { type="dropdown", text="Friendly Target",
                          values=pagingValues, order=pagingOrder,
                          getValue=function() return GetPagingVal("help") end,
                          setValue=function(v) SetPagingVal("help", v) end },
                        { type="dropdown", text="Hostile Target",
                          values=pagingValues, order=pagingOrder,
                          getValue=function() return GetPagingVal("harm") end,
                          setValue=function(v) SetPagingVal("harm", v) end });  y = y - h

                    -- Class form dropdowns (paired into DualRows)
                    local classStatesLocal = PG_STATES.class and PG_STATES.class[playerClass]
                    if classStatesLocal then
                        for i = 1, #classStatesLocal, 2 do
                            local left = classStatesLocal[i]
                            local right = classStatesLocal[i + 1]
                            local rightWidget
                            if right then
                                rightWidget = { type="dropdown", text=right.label,
                                  values=pagingValues, order=pagingOrder,
                                  getValue=function() return GetPagingVal(right.id) end,
                                  setValue=function(v) SetPagingVal(right.id, v) end }
                            else
                                rightWidget = { type="label", text="" }
                            end
                            _, h = W:DualRow(parent, y,
                                { type="dropdown", text=left.label,
                                  values=pagingValues, order=pagingOrder,
                                  getValue=function() return GetPagingVal(left.id) end,
                                  setValue=function(v) SetPagingVal(left.id, v) end },
                                rightWidget);  y = y - h
                        end
                    end
                end
            end

            _, h = W:Spacer(parent, y, 20);  y = y - h

            -------------------------------------------------------------------
            --  TEXT
            -------------------------------------------------------------------
            textSectionHeader, h = W:SectionHeader(parent, SECTION_TEXT, y);  y = y - h

            row, h = W:DualRow(parent, y,
                { type="toggle", text="Hide Keybind Text",
                  getValue=function()
                      return SGet("hideKeybind")
                  end,
                  setValue=function(v)
                      SSet("hideKeybind", v, function(k) EAB:ApplyFontsForBar(k) end)
                      SUpdatePreview()
                  end },
                { type="slider", text="Keybind Text Size", min=6, max=30, step=1, trackWidth=120,
                  getValue=function() return SVal("keybindFontSize", 12) end,
                  setValue=function(v)
                      SSet("keybindFontSize", v, function(k) EAB:ApplyFontsForBar(k) end)
                      SUpdatePreview()
                  end });  y = y - h
            keybindRow = row
            do
                local rgn = row._leftRegion
                EllesmereUI.BuildSyncIcon({
                    region  = rgn,
                    tooltip = "Apply Keybind Visibility to all Bars",
                    onClick = function()
                        local v = SB().hideKeybind
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            EAB.db.profile.bars[key].hideKeybind = v
                            EAB:ApplyFontsForBar(key)
                        end
                        EllesmereUI:RefreshPage()
                    end,
                    isSynced = function()
                        local v = SB().hideKeybind or false
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            if (EAB.db.profile.bars[key].hideKeybind or false) ~= v then return false end
                        end
                        return true
                    end,
                    flashTargets = function() return { rgn } end,
                    multiApply = {
                        elementKeys   = GROUP_BAR_ORDER,
                        elementLabels = SHORT_LABELS,
                        getCurrentKey = function() return SelectedKey() end,
                        onApply       = function(checkedKeys)
                            local v = SB().hideKeybind
                            for _, key in ipairs(checkedKeys) do
                                EAB.db.profile.bars[key].hideKeybind = v
                                EAB:ApplyFontsForBar(key)
                            end
                            EllesmereUI:RefreshPage()
                        end,
                    },
                })
            end
            do
                local rgn = keybindRow._rightRegion
                EllesmereUI.BuildSyncIcon({
                    region  = rgn,
                    tooltip = "Apply Keybind Text Settings to all Bars",
                    onClick = function()
                        local s = SB()
                        local c = s.keybindFontColor
                        local sz = s.keybindFontSize or 12
                        local ox = s.keybindOffsetX or 0
                        local oy = s.keybindOffsetY or 0
                        local an = s.keybindAnchor
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            if c then EAB.db.profile.bars[key].keybindFontColor = { r=c.r, g=c.g, b=c.b } end
                            EAB.db.profile.bars[key].keybindFontSize = sz
                            EAB.db.profile.bars[key].keybindOffsetX = ox
                            EAB.db.profile.bars[key].keybindOffsetY = oy
                            EAB.db.profile.bars[key].keybindAnchor = an or false
                            EAB:ApplyFontsForBar(key)
                        end
                        EllesmereUI:RefreshPage()
                    end,
                    isSynced = function()
                        local s = SB()
                        local sz = s.keybindFontSize or 12
                        local c = s.keybindFontColor
                        local ox = s.keybindOffsetX or 0
                        local oy = s.keybindOffsetY or 0
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            local b = EAB.db.profile.bars[key]
                            if (b.keybindFontSize or 12) ~= sz then return false end
                            if (b.keybindOffsetX or 0) ~= ox then return false end
                            if (b.keybindOffsetY or 0) ~= oy then return false end
                            if (b.keybindAnchor or nil) ~= (s.keybindAnchor or nil) then return false end
                            if c then
                                local bc = b.keybindFontColor
                                if not bc or bc.r ~= c.r or bc.g ~= c.g or bc.b ~= c.b then return false end
                            end
                        end
                        return true
                    end,
                    flashTargets = function() return { rgn } end,
                    multiApply = {
                        elementKeys   = GROUP_BAR_ORDER,
                        elementLabels = SHORT_LABELS,
                        getCurrentKey = function() return SelectedKey() end,
                        onApply       = function(checkedKeys)
                            local s = SB()
                            local c = s.keybindFontColor
                            local sz = s.keybindFontSize or 12
                            local ox = s.keybindOffsetX or 0
                            local oy = s.keybindOffsetY or 0
                            local an = s.keybindAnchor
                            for _, key in ipairs(checkedKeys) do
                                if c then EAB.db.profile.bars[key].keybindFontColor = { r=c.r, g=c.g, b=c.b } end
                                EAB.db.profile.bars[key].keybindFontSize = sz
                                EAB.db.profile.bars[key].keybindOffsetX = ox
                                EAB.db.profile.bars[key].keybindOffsetY = oy
                                EAB.db.profile.bars[key].keybindAnchor = an or false
                                EAB:ApplyFontsForBar(key)
                            end
                            EllesmereUI:RefreshPage()
                        end,
                    },
                })
            end

            do
                local rgn = keybindRow._rightRegion
                local ctrl = rgn._control
                local kbSwatch, kbUpdateSwatch = EllesmereUI.BuildColorSwatch(
                    rgn, keybindRow:GetFrameLevel() + 3,
                    function()
                        local c = SGet("keybindFontColor")
                        if not c then return 1, 1, 1 end
                        return c.r, c.g, c.b
                    end,
                    function(r, g, b)
                        SSetColor("keybindFontColor", r, g, b, nil, function(k) EAB:ApplyFontsForBar(k) end)
                        SUpdatePreview()
                    end,
                    false, 20)
                PP.Point(kbSwatch, "RIGHT", ctrl, "LEFT", -12, 0)
                rgn._lastInline = kbSwatch
                EllesmereUI.RegisterWidgetRefresh(function() kbUpdateSwatch() end)

                EllesmereUI.BuildInlineCog(rgn, { anchorTo = kbSwatch, icon = EllesmereUI.DIRECTIONS_ICON,
                    title = "Keybind Text Offsets",
                    rows = {
                        { type="dropdown", label="Position",
                          values=TEXT_ANCHOR_LABELS, order=TEXT_ANCHOR_DROPDOWN_ORDER,
                          get=function() return SVal("keybindAnchor", "default") end,
                          set=function(v)
                              local anchor = v ~= "default" and v or nil
                              SSeedTextOffsets("keybind", "keybindAnchor", "keybindOffsetX", "keybindOffsetY", anchor)
                              -- Default is stored false, not nil: profile sync copies only keys that exist.
                              SSet("keybindAnchor", anchor or false, function(k) EAB:ApplyFontsForBar(k) end)
                              SUpdatePreview()
                          end },
                        { type="slider", label="X Offset", min=-150, max=150, step=1,
                          get=function() return SVal("keybindOffsetX", 0) end,
                          set=function(v)
                              SSet("keybindOffsetX", v, function(k) EAB:ApplyFontsForBar(k) end)
                              SUpdatePreview()
                          end },
                        { type="slider", label="Y Offset", min=-150, max=150, step=1,
                          get=function() return SVal("keybindOffsetY", 0) end,
                          set=function(v)
                              SSet("keybindOffsetY", v, function(k) EAB:ApplyFontsForBar(k) end)
                              SUpdatePreview()
                          end },
                    },
                })
            end

            local macroRow
            macroRow, h = W:DualRow(parent, y,
                { type="toggle", text="Hide Macro Text",
                  getValue=function()
                      return SGet("hideMacroText")
                  end,
                  setValue=function(v)
                      SSet("hideMacroText", v, function(k) EAB:ApplyFontsForBar(k) end)
                      SUpdatePreview()
                  end },
                { type="slider", text="Macro Text Size", min=6, max=30, step=1, trackWidth=120,
                  getValue=function() return SVal("macroFontSize", 12) end,
                  setValue=function(v)
                      SSet("macroFontSize", v, function(k) EAB:ApplyFontsForBar(k) end)
                      SUpdatePreview()
                  end });  y = y - h
            do
                local rgn = macroRow._leftRegion
                EllesmereUI.BuildSyncIcon({
                    region  = rgn,
                    tooltip = "Apply Macro Text Visibility to all Bars",
                    onClick = function()
                        local v = SB().hideMacroText
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            EAB.db.profile.bars[key].hideMacroText = v
                            EAB:ApplyFontsForBar(key)
                        end
                        EllesmereUI:RefreshPage()
                    end,
                    isSynced = function()
                        local v = SB().hideMacroText or false
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            if (EAB.db.profile.bars[key].hideMacroText or false) ~= v then return false end
                        end
                        return true
                    end,
                    flashTargets = function() return { rgn } end,
                    multiApply = {
                        elementKeys   = GROUP_BAR_ORDER,
                        elementLabels = SHORT_LABELS,
                        getCurrentKey = function() return SelectedKey() end,
                        onApply       = function(checkedKeys)
                            local v = SB().hideMacroText
                            for _, key in ipairs(checkedKeys) do
                                EAB.db.profile.bars[key].hideMacroText = v
                                EAB:ApplyFontsForBar(key)
                            end
                            EllesmereUI:RefreshPage()
                        end,
                    },
                })
            end
            do
                local rgn = macroRow._rightRegion
                EllesmereUI.BuildSyncIcon({
                    region  = rgn,
                    tooltip = "Apply Macro Text Settings to all Bars",
                    onClick = function()
                        local s = SB()
                        local c = s.macroFontColor
                        local sz = s.macroFontSize or 12
                        local ox = s.macroOffsetX or 0
                        local oy = s.macroOffsetY or 0
                        local an = s.macroAnchor
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            if c then EAB.db.profile.bars[key].macroFontColor = { r=c.r, g=c.g, b=c.b } end
                            EAB.db.profile.bars[key].macroFontSize = sz
                            EAB.db.profile.bars[key].macroOffsetX = ox
                            EAB.db.profile.bars[key].macroOffsetY = oy
                            EAB.db.profile.bars[key].macroAnchor = an or false
                            EAB:ApplyFontsForBar(key)
                        end
                        EllesmereUI:RefreshPage()
                    end,
                    isSynced = function()
                        local s = SB()
                        local sz = s.macroFontSize or 12
                        local c = s.macroFontColor
                        local ox = s.macroOffsetX or 0
                        local oy = s.macroOffsetY or 0
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            local b = EAB.db.profile.bars[key]
                            if (b.macroFontSize or 12) ~= sz then return false end
                            if (b.macroOffsetX or 0) ~= ox then return false end
                            if (b.macroOffsetY or 0) ~= oy then return false end
                            if (b.macroAnchor or nil) ~= (s.macroAnchor or nil) then return false end
                            if c then
                                local bc = b.macroFontColor
                                if not bc or bc.r ~= c.r or bc.g ~= c.g or bc.b ~= c.b then return false end
                            end
                        end
                        return true
                    end,
                    flashTargets = function() return { rgn } end,
                    multiApply = {
                        elementKeys   = GROUP_BAR_ORDER,
                        elementLabels = SHORT_LABELS,
                        getCurrentKey = function() return SelectedKey() end,
                        onApply       = function(checkedKeys)
                            local s = SB()
                            local c = s.macroFontColor
                            local sz = s.macroFontSize or 12
                            local ox = s.macroOffsetX or 0
                            local oy = s.macroOffsetY or 0
                            local an = s.macroAnchor
                            for _, key in ipairs(checkedKeys) do
                                if c then EAB.db.profile.bars[key].macroFontColor = { r=c.r, g=c.g, b=c.b } end
                                EAB.db.profile.bars[key].macroFontSize = sz
                                EAB.db.profile.bars[key].macroOffsetX = ox
                                EAB.db.profile.bars[key].macroOffsetY = oy
                                EAB.db.profile.bars[key].macroAnchor = an or false
                                EAB:ApplyFontsForBar(key)
                            end
                            EllesmereUI:RefreshPage()
                        end,
                    },
                })
            end

            do
                local rgn = macroRow._rightRegion
                local ctrl = rgn._control
                local mcSwatch, mcUpdateSwatch = EllesmereUI.BuildColorSwatch(
                    rgn, macroRow:GetFrameLevel() + 3,
                    function()
                        local c = SGet("macroFontColor")
                        if not c then return 1, 1, 1 end
                        return c.r, c.g, c.b
                    end,
                    function(r, g, b)
                        SSetColor("macroFontColor", r, g, b, nil, function(k) EAB:ApplyFontsForBar(k) end)
                        SUpdatePreview()
                    end,
                    false, 20)
                PP.Point(mcSwatch, "RIGHT", ctrl, "LEFT", -12, 0)
                rgn._lastInline = mcSwatch
                EllesmereUI.RegisterWidgetRefresh(function() mcUpdateSwatch() end)

                EllesmereUI.BuildInlineCog(rgn, { anchorTo = mcSwatch, icon = EllesmereUI.DIRECTIONS_ICON,
                    title = "Macro Text Offsets",
                    rows = {
                        { type="dropdown", label="Position",
                          values=TEXT_ANCHOR_LABELS, order=TEXT_ANCHOR_DROPDOWN_ORDER,
                          get=function() return SVal("macroAnchor", "default") end,
                          set=function(v)
                              local anchor = v ~= "default" and v or nil
                              SSeedTextOffsets("macro", "macroAnchor", "macroOffsetX", "macroOffsetY", anchor)
                              SSet("macroAnchor", anchor or false, function(k) EAB:ApplyFontsForBar(k) end)
                              SUpdatePreview()
                          end },
                        { type="slider", label="X Offset", min=-150, max=150, step=1,
                          get=function() return SVal("macroOffsetX", 0) end,
                          set=function(v)
                              SSet("macroOffsetX", v, function(k) EAB:ApplyFontsForBar(k) end)
                              SUpdatePreview()
                          end },
                        { type="slider", label="Y Offset", min=-150, max=150, step=1,
                          get=function() return SVal("macroOffsetY", 0) end,
                          set=function(v)
                              SSet("macroOffsetY", v, function(k) EAB:ApplyFontsForBar(k) end)
                              SUpdatePreview()
                          end },
                    },
                })
            end

            chargesRow, h = W:DualRow(parent, y,
                { type="slider", text="Charges Text Size", min=6, max=30, step=1, trackWidth=120,
                  getValue=function() return SVal("countFontSize", 12) end,
                  setValue=function(v)
                      SSet("countFontSize", v, function(k) EAB:ApplyFontsForBar(k) end)
                      SUpdatePreview()
                  end },
                { type="slider", text="Cooldown Text Size", min=6, max=30, step=1, trackWidth=120,
                  getValue=function() return SVal("cooldownFontSize", 12) end,
                  setValue=function(v)
                      SSet("cooldownFontSize", v, function(k) EAB:ApplyCooldownFontsForBar(k) end)
                      SUpdatePreview()
                  end });  y = y - h
            do
                local rgn = chargesRow._leftRegion
                EllesmereUI.BuildSyncIcon({
                    region  = rgn,
                    tooltip = "Apply Charges Text Settings to all Bars",
                    onClick = function()
                        local s = SB()
                        local c = s.countFontColor
                        local sz = s.countFontSize or 12
                        local ox = s.countOffsetX or 0
                        local oy = s.countOffsetY or 0
                        local an = s.countAnchor
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            if c then EAB.db.profile.bars[key].countFontColor = { r=c.r, g=c.g, b=c.b } end
                            EAB.db.profile.bars[key].countFontSize = sz
                            EAB.db.profile.bars[key].countOffsetX = ox
                            EAB.db.profile.bars[key].countOffsetY = oy
                            EAB.db.profile.bars[key].countAnchor = an or false
                            EAB:ApplyFontsForBar(key)
                        end
                        EllesmereUI:RefreshPage()
                    end,
                    isSynced = function()
                        local s = SB()
                        local sz = s.countFontSize or 12
                        local c = s.countFontColor
                        local ox = s.countOffsetX or 0
                        local oy = s.countOffsetY or 0
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            local b = EAB.db.profile.bars[key]
                            if (b.countFontSize or 12) ~= sz then return false end
                            if (b.countOffsetX or 0) ~= ox then return false end
                            if (b.countOffsetY or 0) ~= oy then return false end
                            if (b.countAnchor or nil) ~= (s.countAnchor or nil) then return false end
                            if c then
                                local bc = b.countFontColor
                                if not bc or bc.r ~= c.r or bc.g ~= c.g or bc.b ~= c.b then return false end
                            end
                        end
                        return true
                    end,
                    flashTargets = function() return { rgn } end,
                    multiApply = {
                        elementKeys   = GROUP_BAR_ORDER,
                        elementLabels = SHORT_LABELS,
                        getCurrentKey = function() return SelectedKey() end,
                        onApply       = function(checkedKeys)
                            local s = SB()
                            local c = s.countFontColor
                            local sz = s.countFontSize or 12
                            local ox = s.countOffsetX or 0
                            local oy = s.countOffsetY or 0
                            local an = s.countAnchor
                            for _, key in ipairs(checkedKeys) do
                                if c then EAB.db.profile.bars[key].countFontColor = { r=c.r, g=c.g, b=c.b } end
                                EAB.db.profile.bars[key].countFontSize = sz
                                EAB.db.profile.bars[key].countOffsetX = ox
                                EAB.db.profile.bars[key].countOffsetY = oy
                                EAB.db.profile.bars[key].countAnchor = an or false
                                EAB:ApplyFontsForBar(key)
                            end
                            EllesmereUI:RefreshPage()
                        end,
                    },
                })
            end

            do
                local rgn = chargesRow._leftRegion
                local ctrl = rgn._control
                local ctSwatch, ctUpdateSwatch = EllesmereUI.BuildColorSwatch(
                    rgn, chargesRow:GetFrameLevel() + 3,
                    function()
                        local c = SGet("countFontColor")
                        if not c then return 1, 1, 1 end
                        return c.r, c.g, c.b
                    end,
                    function(r, g, b)
                        SSetColor("countFontColor", r, g, b, nil, function(k) EAB:ApplyFontsForBar(k) end)
                        SUpdatePreview()
                    end,
                    false, 20)
                PP.Point(ctSwatch, "RIGHT", ctrl, "LEFT", -12, 0)
                rgn._lastInline = ctSwatch
                EllesmereUI.RegisterWidgetRefresh(function() ctUpdateSwatch() end)

                EllesmereUI.BuildInlineCog(rgn, { anchorTo = ctSwatch, icon = EllesmereUI.DIRECTIONS_ICON,
                    title = "Charges Text Offsets",
                    rows = {
                        { type="dropdown", label="Position",
                          values=TEXT_ANCHOR_LABELS, order=TEXT_ANCHOR_DROPDOWN_ORDER,
                          get=function() return SVal("countAnchor", "default") end,
                          set=function(v)
                              local anchor = v ~= "default" and v or nil
                              SSeedTextOffsets("count", "countAnchor", "countOffsetX", "countOffsetY", anchor)
                              SSet("countAnchor", anchor or false, function(k) EAB:ApplyFontsForBar(k) end)
                              SUpdatePreview()
                          end },
                        { type="slider", label="X Offset", min=-150, max=150, step=1,
                          get=function() return SVal("countOffsetX", 0) end,
                          set=function(v)
                              SSet("countOffsetX", v, function(k) EAB:ApplyFontsForBar(k) end)
                              SUpdatePreview()
                          end },
                        { type="slider", label="Y Offset", min=-150, max=150, step=1,
                          get=function() return SVal("countOffsetY", 0) end,
                          set=function(v)
                              SSet("countOffsetY", v, function(k) EAB:ApplyFontsForBar(k) end)
                              SUpdatePreview()
                          end },
                    },
                })
            end

            do
                local rgn = chargesRow._rightRegion
                EllesmereUI.BuildSyncIcon({
                    region  = rgn,
                    tooltip = "Apply Cooldown Text Settings to all Bars",
                    onClick = function()
                        local s = SB()
                        local c = s.cooldownTextColor
                        local sz = s.cooldownFontSize or 12
                        local ox = s.cooldownTextXOffset or 0
                        local oy = s.cooldownTextYOffset or 0
                        local ft = s.cooldownFontFit or false
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            if c then EAB.db.profile.bars[key].cooldownTextColor = { r=c.r, g=c.g, b=c.b } end
                            EAB.db.profile.bars[key].cooldownFontSize = sz
                            EAB.db.profile.bars[key].cooldownTextXOffset = ox
                            EAB.db.profile.bars[key].cooldownTextYOffset = oy
                            EAB.db.profile.bars[key].cooldownFontFit = ft
                            EAB:ApplyCooldownFontsForBar(key)
                        end
                        EllesmereUI:RefreshPage()
                    end,
                    isSynced = function()
                        local s = SB()
                        local sz = s.cooldownFontSize or 12
                        local c = s.cooldownTextColor
                        local ox = s.cooldownTextXOffset or 0
                        local oy = s.cooldownTextYOffset or 0
                        local ft = s.cooldownFontFit or false
                        for _, key in ipairs(GROUP_BAR_ORDER) do
                            local b = EAB.db.profile.bars[key]
                            if (b.cooldownFontSize or 12) ~= sz then return false end
                            if (b.cooldownTextXOffset or 0) ~= ox then return false end
                            if (b.cooldownTextYOffset or 0) ~= oy then return false end
                            if (b.cooldownFontFit or false) ~= ft then return false end
                            if c then
                                local bc = b.cooldownTextColor
                                if not bc or bc.r ~= c.r or bc.g ~= c.g or bc.b ~= c.b then return false end
                            end
                        end
                        return true
                    end,
                    flashTargets = function() return { rgn } end,
                    multiApply = {
                        elementKeys   = GROUP_BAR_ORDER,
                        elementLabels = SHORT_LABELS,
                        getCurrentKey = function() return SelectedKey() end,
                        onApply       = function(checkedKeys)
                            local s = SB()
                            local c = s.cooldownTextColor
                            local sz = s.cooldownFontSize or 12
                            local ox = s.cooldownTextXOffset or 0
                            local oy = s.cooldownTextYOffset or 0
                            local ft = s.cooldownFontFit or false
                            for _, key in ipairs(checkedKeys) do
                                if c then EAB.db.profile.bars[key].cooldownTextColor = { r=c.r, g=c.g, b=c.b } end
                                EAB.db.profile.bars[key].cooldownFontSize = sz
                                EAB.db.profile.bars[key].cooldownTextXOffset = ox
                                EAB.db.profile.bars[key].cooldownTextYOffset = oy
                                EAB.db.profile.bars[key].cooldownFontFit = ft
                                EAB:ApplyCooldownFontsForBar(key)
                            end
                            EllesmereUI:RefreshPage()
                        end,
                    },
                })
            end

            do
                local rgn = chargesRow._rightRegion
                local ctrl = rgn._control
                local cdSwatch, cdUpdateSwatch = EllesmereUI.BuildColorSwatch(
                    rgn, chargesRow:GetFrameLevel() + 3,
                    function()
                        local c = SGet("cooldownTextColor")
                        if not c then return 1, 1, 1 end
                        return c.r, c.g, c.b
                    end,
                    function(r, g, b)
                        SSetColor("cooldownTextColor", r, g, b, nil, function(k) EAB:ApplyCooldownFontsForBar(k) end)
                        SUpdatePreview()
                    end,
                    false, 20)
                PP.Point(cdSwatch, "RIGHT", ctrl, "LEFT", -12, 0)
                rgn._lastInline = cdSwatch
                EllesmereUI.RegisterWidgetRefresh(function() cdUpdateSwatch() end)

                EllesmereUI.BuildInlineCog(rgn, { anchorTo = cdSwatch, icon = EllesmereUI.DIRECTIONS_ICON,
                    title = "Cooldown Text",
                    rows = {
                        { type="slider", label="X Offset", min=-150, max=150, step=1,
                          get=function() return SVal("cooldownTextXOffset", 0) end,
                          set=function(v)
                              SSet("cooldownTextXOffset", v, function(k) EAB:ApplyCooldownFontsForBar(k) end)
                              SUpdatePreview()
                          end },
                        { type="slider", label="Y Offset", min=-150, max=150, step=1,
                          get=function() return SVal("cooldownTextYOffset", 0) end,
                          set=function(v)
                              SSet("cooldownTextYOffset", v, function(k) EAB:ApplyCooldownFontsForBar(k) end)
                              SUpdatePreview()
                          end },
                        { type="toggle", label="Fit Size to Button",
                          tooltip="Caps the countdown size so it cannot spill outside small buttons.",
                          get=function() return SVal("cooldownFontFit", false) end,
                          set=function(v)
                              SSet("cooldownFontFit", v and true or false, function(k) EAB:ApplyCooldownFontsForBar(k) end)
                          end },
                    },
                })
            end

            _, h = W:Spacer(parent, y, 20);  y = y - h

            -------------------------------------------------------------------
            --  CLICK NAVIGATION
            -------------------------------------------------------------------
            local PlaySettingGlow = EllesmereUI.MakeSettingGlow({ color = EllesmereUI.ELLESMERE_GREEN, thickness = function() return PP.Scale(2) end, noSnap = true })

            local clickMappings = {
                icon       = { section = iconsSectionHeader, target = classColorBorderRow },
                keybind    = { section = textSectionHeader,  target = keybindRow, slotSide = "right" },
                charges    = { section = textSectionHeader,  target = chargesRow, slotSide = "left" },
            }

            local function NavigateToSetting(key)
                local m = clickMappings[key]
                if not m or not m.section or not m.target then return end

                EllesmereUI.DismissPreviewHint(_abPreviewHintFS, barsHeaderBaseH, 29, 17)

                local sf = EllesmereUI._scrollFrame
                if not sf then return end
                local _, _, _, _, headerY = m.section:GetPoint(1)
                if not headerY then return end
                local scrollPos = math.max(0, math.abs(headerY) - 40)
                EllesmereUI.SmoothScrollTo(scrollPos)
                local glowTarget = m.target
                if m.slotSide and m.target then
                    local region = (m.slotSide == "left") and m.target._leftRegion or m.target._rightRegion
                    if region then glowTarget = region end
                end
                C_Timer.After(0.15, function() PlaySettingGlow(glowTarget) end)
            end

            local hitStyle = { tightText = true }
            local function CreateHitOverlay(element, mappingKey, isText, frameLevelOverride, opts)
                return (EllesmereUI.CreatePreviewHitOverlay(element, NavigateToSetting, mappingKey, isText, frameLevelOverride, opts, hitStyle))
            end

            local textOverlays = {}
            if optState.activePreview then
                local pv = optState.activePreview
                local pvButtons = pv._buttons
                local iconLevel = (pvButtons[1] and pvButtons[1].frame and pvButtons[1].frame:GetFrameLevel() or 5) + 10
                local textOnIconLevel = iconLevel + 10
                local iconHlOpts = { hlBehindText = true }
                for i = 1, pv._barInfo.count do
                    local entry = pvButtons[i]
                    if entry and entry.frame then
                        CreateHitOverlay(entry.frame, "icon", false, iconLevel, iconHlOpts)
                        if entry.keybind then
                            textOverlays[#textOverlays + 1] = CreateHitOverlay(entry.keybind, "keybind", true, textOnIconLevel)
                        end
                        if entry.count then
                            textOverlays[#textOverlays + 1] = CreateHitOverlay(entry.count, "charges", true, textOnIconLevel)
                        end
                    end
                end
                pv._textOverlays = textOverlays
            end
        end  -- if not visOnly

        return y
    end

    local function BuildBarDisplayPage(pageName, parent, yOffset)
        local W = EllesmereUI.Widgets
        local y = yOffset
        local _, h

        optState.activePreview = nil

        -- Consume any pending bar selection from Element Options navigation.
        if EllesmereUI._consumePendingActionBarSelect then EllesmereUI._consumePendingActionBarSelect() end

        -- Tag every option registered while building this page with the selected bar, so a global-search
        -- jump to a bar-specific setting restores this exact selection first via _setActionBarKey
        -- (full reasoning: the matching _buildingSelector comment in EUI_CooldownManager_Options.lua).
        EllesmereUI._buildingSelector = { setter = EllesmereUI._setActionBarKey, key = SelectedKey() }

        ShowEditOverlay(SelectedKey())

        -------------------------------------------------------------------
        --  CONTENT HEADER  (dropdown + preview)
        -------------------------------------------------------------------
        _barsHeaderBuilder = function(hdr, hdrW)
            local PAD = EllesmereUI.CONTENT_PAD
            local PV_PAD = 10  -- internal padding inside BuildLivePreview
            local fy = -20

            -- Centered dropdown (same pattern as Multi Bar Edit)
            local DD_H = 34
            local availW = hdrW - PAD * 2
            local ddW = 350
            local ddBtn, ddLbl = EllesmereUI.BuildDropdownControl(
                hdr, ddW, hdr:GetFrameLevel() + 5,
                barLabels, barOrder,
                function() return SelectedKey() end,
                function(v)
                    _selectedBarKey = v
                    EllesmereUI:InvalidateContentHeaderCache()
                    EllesmereUI:SetContentHeader(_barsHeaderBuilder)
                    -- Always force a full rebuild: visibility-only bars and StanceBar share visOnly/dataBar flags, so a conditional misses transitions.
                    EllesmereUI:RefreshPage(true)
                    ShowEditOverlay(v)
                end,
                function(key)
                    -- Bar9/Bar10 default to Hidden visibility but must stay selectable so they can be configured -- never show the disabled effect.
                    if key == "Bar9" or key == "Bar10" then return nil end
                    if not IsBarEnabled(key) then return EllesmereUI.DisabledTooltip("this action bar") end
                end
            )
            PP.Point(ddBtn, "TOP", hdr, "TOP", 0, fy)
            ddBtn:SetHeight(DD_H)
            fy = fy - DD_H - PV_PAD

            local previewH = BuildLivePreview(hdr, fy)
            fy = fy - previewH - PV_PAD

            headerFixedH = 20 + DD_H + PV_PAD + PV_PAD

            if _abPreviewHintFS and not _abPreviewHintFS:GetParent() then
                _abPreviewHintFS = nil
            end
            local hintH = 0
            if not IsPreviewHintDismissed() then
                if not _abPreviewHintFS then
                    local hintHost = CreateFrame("Frame", nil, hdr)
                    hintHost:SetAllPoints(hdr)
                    _abPreviewHintFS = EllesmereUI.MakeFont(hintHost, 11, nil, 1, 1, 1)
                    _abPreviewHintFS:SetAlpha(0.45)
                    _abPreviewHintFS:SetText(EllesmereUI.L("Click elements to scroll to and highlight their options"))
                end
                _abPreviewHintFS:GetParent():SetParent(hdr)
                _abPreviewHintFS:GetParent():Show()
                _abPreviewHintFS:ClearAllPoints()
                _abPreviewHintFS:SetPoint("BOTTOM", hdr, "BOTTOM", 0, 17)
                _abPreviewHintFS:SetAlpha(0.45)
                _abPreviewHintFS:Show()
                hintH = 29
            elseif _abPreviewHintFS then
                _abPreviewHintFS:Hide()
            end

            barsHeaderBaseH = math.abs(fy)
            return barsHeaderBaseH + hintH
        end
        EllesmereUI:SetContentHeader(_barsHeaderBuilder)

        -------------------------------------------------------------------
        --  Top action buttons: Quick Keybind + Blizzard/EUI Style toggle
        -------------------------------------------------------------------
        do
            local BTN_W = 312
            local BTN_H = 38
            local GAP = 40
            local ROW_H = BTN_H + 20
            local rowFrame = CreateFrame("Frame", nil, parent)
            local totalW = parent:GetWidth() - EllesmereUI.CONTENT_PAD * 2
            PP.Size(rowFrame, totalW, ROW_H)
            PP.Point(rowFrame, "TOPLEFT", parent, "TOPLEFT", EllesmereUI.CONTENT_PAD, y)

            local qkbBtn = CreateFrame("Button", nil, rowFrame)
            PP.Size(qkbBtn, BTN_W, BTN_H)
            PP.Point(qkbBtn, "RIGHT", rowFrame, "CENTER", -(GAP / 2), 0)
            qkbBtn:SetFrameLevel(rowFrame:GetFrameLevel() + 1)
            EllesmereUI.MakeStyledButton(qkbBtn, "Quick Keybind Mode (/kb)", 14,
                EllesmereUI.WB_COLOURS, function()
                    if InCombatLockdown() then return end
                    if not C_AddOns.IsAddOnLoaded("Blizzard_QuickKeybind") then
                        C_AddOns.LoadAddOn("Blizzard_QuickKeybind")
                    end
                    if QuickKeybindFrame then
                        EllesmereUI:Toggle()
                        QuickKeybindFrame:Show()
                    end
                end)

            -- A stock style on (Blizzard, Classic or WoW Forever) offers the
            -- way back to the EUI look; off, the way to Blizzard Style. Classic
            -- WoW UI and WoW Forever are the Style page's; the write is the
            -- Style page's own switch, so leaving WoW Forever here brings the
            -- queue eye's spot back as a Style row does.
            local isStock = EllesmereUI.BlizzStyle.Get("actionbars")
            local styleBtn = CreateFrame("Button", nil, rowFrame)
            PP.Size(styleBtn, BTN_W, BTN_H)
            PP.Point(styleBtn, "LEFT", rowFrame, "CENTER", GAP / 2, 0)
            styleBtn:SetFrameLevel(rowFrame:GetFrameLevel() + 1)
            local _, _, styleLbl = EllesmereUI.MakeStyledButton(styleBtn,
                isStock and "EUI Style Action Bars" or "Blizzard Style Action Bars", 14,
                EllesmereUI.WB_COLOURS, function()
                    local toBlizz = not EllesmereUI.BlizzStyle.Get("actionbars")
                    EllesmereUI:ShowConfirmPopup({
                        title       = "Reload Required",
                        message     = "Changing icon style requires a UI reload to apply.",
                        confirmText = "Reload Now",
                        cancelText  = "Cancel",
                        reload      = true,
                        onConfirm   = function()
                            EllesmereUI.BlizzStyle.Switch("actionbars", toBlizz and "blizzard" or "eui")
                        end,
                    })
                end)

            y = y - ROW_H
        end

        -------------------------------------------------------------------
        --  Build shared settings (single mode)
        -------------------------------------------------------------------
        y = BuildSharedBarSettings(parent, y)

        return math.abs(y)
    end


    ---------------------------------------------------------------------------
    --  Unlock Mode page  (opens EllesmereUI Unlock Mode overlay)
    ---------------------------------------------------------------------------
    local function BuildUnlockPage(pageName, parent, yOffset)
        -- Defer to next frame so the page switch completes first
        C_Timer.After(0, function()
            if ns.OpenUnlockMode then
                ns.OpenUnlockMode()
            end
        end)
        return 0
    end

    ---------------------------------------------------------------------------
    --  Register the module
    ---------------------------------------------------------------------------
    EllesmereUI:RegisterModule("EllesmereUIActionBars", {
        title       = "Action Bars",
        description = "Configure visuals and behavior for your action bars.",
        pages       = { PAGE_DISPLAY, PAGE_MENUBAGSXP, PAGE_ANIMATIONS },
        buildPage   = function(pageName, parent, yOffset)
            -- BuildBarDisplayPage calls ShowEditOverlay() unconditionally at build time, showing a
            -- real UIParent-parented overlay over the live action bars. A hidden search pre-build
            -- would flash it onscreen, so skip PAGE_DISPLAY here; it indexes on first visit.
            if EllesmereUI._prebuilding then
                if pageName == PAGE_MENUBAGSXP then
                    return BuildMenuBagsXPPage(pageName, parent, yOffset)
                elseif pageName == PAGE_ANIMATIONS then
                    return BuildAnimationsPage(pageName, parent, yOffset)
                end
                return
            end
            if pageName ~= PAGE_DISPLAY then
                HideEditOverlay()
            end
            if pageName == PAGE_DISPLAY then
                return BuildBarDisplayPage(pageName, parent, yOffset)
            elseif pageName == PAGE_MENUBAGSXP then
                return BuildMenuBagsXPPage(pageName, parent, yOffset)
            elseif pageName == PAGE_ANIMATIONS then
                return BuildAnimationsPage(pageName, parent, yOffset)
            end
        end,
        getHeaderBuilder = function(pageName)
            if pageName == PAGE_DISPLAY then
                return _barsHeaderBuilder
            end
            return nil
        end,
        onPageCacheRestore = function(pageName)
            if pageName == PAGE_DISPLAY then
                UpdatePreview()
                ShowEditOverlay(SelectedKey())
                local dismissed = IsPreviewHintDismissed()
                if _abPreviewHintFS then
                    if dismissed then
                        _abPreviewHintFS:Hide()
                    else
                        _abPreviewHintFS:SetAlpha(0.45)
                        _abPreviewHintFS:Show()
                        if _abPreviewHintFS:GetParent() then _abPreviewHintFS:GetParent():Show() end
                    end
                end
                if barsHeaderBaseH > 0 then
                    EllesmereUI:SetContentHeaderHeightSilent(barsHeaderBaseH + (dismissed and 0 or 29))
                end
            else
                HideEditOverlay()
            end
        end,
        onReset     = function()
            EAB.db:ResetProfile()
            -- Clear the per-install capture flag: the snapshot re-runs post-reload and re-reads Blizzard's bar layout.
            if EAB.db and EAB.db.sv then
                EAB.db.sv._capturedOnce_EAB = nil
            end
            -- No reload here: the footer Reset popup (reload = true) reloads after this returns.
        end,
    })
end)
-- LoadOnDemand: this addon loads after PLAYER_LOGIN, so the event above will never fire; run the init now.
if IsLoggedIn() then initFrame:GetScript("OnEvent")(initFrame) end
