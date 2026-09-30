if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EUI_RaidFrames_Options.lua
--  Registers the Raid Frames module with EllesmereUI options panel.
--  Two tabs: Raid Frames (layout, health, power, text, border, absorbs,
--  indicators, debuffs, dispels, range/tooltip) and Buff Manager.
-------------------------------------------------------------------------------
local ADDON_NAME = "EllesmereUIRaidFrames"
local ns = EllesmereUI._ModuleNS[ADDON_NAME]  -- module namespace (published by the module at its load)
if not ns then return end  -- module disabled: no options page

-- WoW Forever: the preview's numbers follow the live frames (EllesmereUI_NumberFormat.lua).
local AbbreviateNumbers = (EllesmereUI.IS_FOREVER and EllesmereUI.ForeverAbbreviateNumbers) or AbbreviateNumbers

local PAGE_MAIN = "Frames"
local PAGE_PARTY = "Party"
local PAGE_BUFFS = "Buff Manager"
local PAGE_DM = "Debuff Manager"
local PAGE_CLICKCAST = "HoverCast"

-- Display-only tab labels. Page IDENTITY strings above are baked into nav
-- targets/unlock/overrides/saved state; tab bar renders these instead (see CreateTabButton in EllesmereUI.lua).
EllesmereUI.TAB_LABEL_OVERRIDES = EllesmereUI.TAB_LABEL_OVERRIDES or {}
EllesmereUI.TAB_LABEL_OVERRIDES[PAGE_BUFFS] = "Buffs"
EllesmereUI.TAB_LABEL_OVERRIDES[PAGE_DM] = "Debuffs"

-- Party page under "Frame Style: Party Frames" (the latched stock portrait
-- party frame): the rows its layout replaces are hidden on the Party page
-- only. The page being BUILT decides (BuildVisualSections builds the Frames
-- page too, and the search prebuild can leave the party context stale). ns
-- fields, so no page builder gains an upvalue.
function ns.RF_OptPartyKit()
    return EllesmereUI._buildingPage == PAGE_PARTY and ns.RF_PartyKit ~= nil
        and ns.RF_PartyKit() and true or false
end
function ns.RF_PartyKitGate(cfg)
    if not cfg or not ns.RF_OptPartyKit() then return cfg end
    cfg.disabled        = function() return true end
    cfg.disabledTooltip = "Frame Style: Party Frames"
    cfg.requireState    = "disabled"
    cfg.rawTooltip      = nil
    cfg._blizzGated     = true
    return cfg
end

-- Move Frames button of a Free Move group (Friendly Boss, Extra Frames, Pet Frames): toggles its
-- drag overlay, right-aligned in the DualRow half rgn. opts: isShown() and setShown(show), the
-- overlay; allowed(), whether it can open (Free Move chosen, out of combat); optional enabled()
-- with enabledTip, the group's own switch, which also dims rgn's plain label while off. Nothing is
-- built during the search prebuild; returns the button.
function ns.RF_OptMoveFramesButton(row, rgn, opts)
    if EllesmereUI._prebuilding then return end
    local btn = CreateFrame("Button", nil, row)
    btn:SetSize(140, 26)
    btn:SetPoint("RIGHT", rgn, "RIGHT", -20, 0)
    btn:SetFrameLevel(row:GetFrameLevel() + 5)
    local bbg = btn:CreateTexture(nil, "BACKGROUND")
    bbg:SetAllPoints()
    bbg:SetColorTexture(0.06, 0.08, 0.10, 0.92)
    EllesmereUI.MakeBorder(btn, 1, 1, 1, 0.25)
    local lbl = btn:CreateFontString(nil, "OVERLAY")
    EllesmereUI.ApplyModuleFont(lbl, nil, 13, "raidFrames")
    lbl:SetPoint("CENTER", btn, "CENTER", 0, 0)
    local enabled = opts.enabled
    local function Update()
        lbl:SetText(opts.isShown() and EllesmereUI.L("Stop Moving") or EllesmereUI.L("Move Frames"))
        btn:SetAlpha(opts.allowed() and 1 or 0.35)
        -- Plain-label slots have no native disabled handling.
        if enabled and rgn._label then rgn._label:SetAlpha(enabled() and 1 or 0.3) end
    end
    btn:SetScript("OnEnter", function(self)
        if enabled and not enabled() then
            EllesmereUI.ShowWidgetTooltip(self, opts.enabledTip)
        elseif not opts.allowed() then
            EllesmereUI.ShowWidgetTooltip(self,
                EllesmereUI.DisabledTooltip("This option requires Position to be set to Free Move"))
        else
            EllesmereUI.ShowWidgetTooltip(self,
                "Drag the overlay to position the frames, then click again to lock")
        end
    end)
    btn:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
    btn:SetScript("OnClick", function()
        if not opts.allowed() then return end
        opts.setShown(not opts.isShown())
        Update()
    end)
    EllesmereUI.RegisterWidgetRefresh(Update)
    Update()
    return btn
end

-- Party page PORTRAIT section (every style; EUI_RaidFrames_Portrait.lua):
-- Portrait Mode | Art Style, then Size | Position and (Detached) Shape |
-- Shape Border. Under "Frame Style: Party Frames" the stock socket takes
-- the Art Style alone (2D or class art). `PSSet` is the Party page's setter
-- (the full party pass, for the box-width changes); every other setting
-- takes the light path. Returns the new y.
function ns.RF_BuildPartyPortrait(parent, y, W, PSSet)
    local db = ns.db
    local kit = ns.RF_OptPartyKit()   -- build time only (the page rebuilds)
    local _, h
    local function PV(k, d)
        local v = db.profile[k]
        if v == nil then return d end
        return v
    end
    local function Refresh()
        if ns._RefreshProxyModes then ns._RefreshProxyModes() end
        if ns.RF_PtRefreshAll then ns.RF_PtRefreshAll() end
        if ns.partyPvActive and ns.partyPvActive() and ns.ShowPartyPreview then ns.ShowPartyPreview() end
    end
    local function PtSet(k, v)
        db.profile[k] = v
        Refresh()
    end
    local function RunWidgetRefresh()
        C_Timer.After(0, function()
            local rl = EllesmereUI._widgetRefreshList
            if rl then for i = 1, #rl do rl[i]() end end
        end)
    end
    local function IsInside(side)
        return side == "insideleft" or side == "insideright" or side == "insidecenter"
    end

    _, h = W:SectionHeader(parent, "PORTRAIT", y); y = y - h

    -- An Art Style pick, with the side effects of leaving and entering 3D
    -- (Inside positions and the None shape are 3D only).
    local function SetArt(v)
        local p = db.profile
        p.partyPortraitMode = v
        if v == "3d" and p.partyPortraitStyle == "detached" then p.partyPortraitShape = "none" end
        if v ~= "3d" then
            if p.partyPortraitShape == "none" then p.partyPortraitShape = "portrait" end
            if IsInside(p.partyPortraitSide) then p.partyPortraitSide = "left" end
        end
        Refresh()
    end

    -- Art Style: 2D, 3D, or class art in one of seven sets (the flyout).
    local classVals = { modern = "Modern", arcade = "Arcade", glyph = "Glyph", legend = "Legend",
        midnight = "Midnight", pixel = "Pixel", pixelsComic = "Pixels Comic", runic = "Runic" }
    local classOrder = { "modern", "arcade", "glyph", "legend", "midnight", "pixel", "pixelsComic", "runic" }
    local artValues = {
        ["3d"] = "3D Portrait",
        ["2d"] = "2D Portrait",
        class = { text = "Class", subnav = { order = classOrder, values = classVals, itemHeight = 32,
            onSelect = function(key)
                db.profile.partyPortraitClassStyle = key
                SetArt("class")
                RunWidgetRefresh()
            end,
            icon = function(key)
                local _, ct = UnitClass("player")
                local c = ct and EllesmereUI.CLASS_ICON_SPRITE_COORDS and EllesmereUI.CLASS_ICON_SPRITE_COORDS[ct]
                if not c then return nil end
                return "Interface\\AddOns\\EllesmereUI\\media\\icons\\class-full\\" .. key .. ".tga",
                    c[1], c[2], c[3], c[4]
            end } },
    }

    -- Row 1: Portrait Mode | Art Style. A mode change can widen the frame
    -- (the full party pass) and shows or hides the rows below (a rebuild).
    _, h = W:DualRow(parent, y,
        ns.RF_PartyKitGate({ type="dropdown", text="Portrait Mode",
          tooltip="Attached widens each frame by the portrait.",
          values={ none = "None", attached = "Attached", detached = "Detached" },
          order={ "none", "attached", "detached" },
          getValue=function()
              if kit then return "attached" end
              return PV("partyPortraitStyle", "none")
          end,
          setValue=function(v)
              local p = db.profile
              local prev = p.partyPortraitStyle or "none"
              if v == prev then return end
              if v == "detached" and (p.partyPortraitMode or "2d") == "3d" then p.partyPortraitShape = "none" end
              if v ~= "detached" then
                  p.partyPortraitSize = 0
                  local sd = p.partyPortraitSide
                  if sd == "top" or IsInside(sd) then p.partyPortraitSide = "left" end
              end
              PSSet("partyPortraitStyle", v)
              EllesmereUI:RefreshPage(true)
          end }),
        { type="dropdown", text="Art Style", values=artValues, order={ "3d", "2d", "class" },
          disabled=function() return not kit and PV("partyPortraitStyle", "none") == "none" end,
          disabledTooltip="Portrait Mode is set to None", rawTooltip=true,
          -- A model cannot take the stock socket's round mask.
          itemDisabled=function(v) return kit and v == "3d" end,
          itemDisabledTooltip=function(v) if v == "3d" then return "Frame Style: Party Frames" end end,
          itemRequireState="disabled",
          getValue=function()
              local m = PV("partyPortraitMode", "2d")
              if m == "class" then return PV("partyPortraitClassStyle", "modern") end
              if kit and m == "3d" then return "2d" end
              return m
          end,
          setValue=function(v)
              if v == "3d" and PV("partyPortraitMode", "2d") ~= "3d"
                  and not (EllesmereUIDB and EllesmereUIDB.dismissed3DWarning) then
                  EllesmereUI:ShowConfirmPopup({
                      title       = "3D Portraits",
                      message     = "3D portraits may cause a slight loss in performance efficiency. Do you want to enable them?",
                      confirmText = "Enable",
                      cancelText  = "Cancel",
                      onConfirm   = function()
                          if not EllesmereUIDB then EllesmereUIDB = {} end
                          EllesmereUIDB.dismissed3DWarning = true
                          SetArt("3d")
                          EllesmereUI:RefreshPage(true)
                      end,
                      onCancel    = function() EllesmereUI:RefreshPage() end,
                  })
                  return
              end
              SetArt(v)
              RunWidgetRefresh()
          end });  y = y - h

    if kit or PV("partyPortraitStyle", "none") == "none" then return y end

    -- Row 2: Size | Position.
    local sizePosRow
    sizePosRow, h = W:DualRow(parent, y,
        { type="slider", text="Size", min=-50, max=100, step=1,
          disabled=function()
              return PV("partyPortraitStyle", "none") ~= "detached" and not IsInside(PV("partyPortraitSide", "left"))
          end,
          disabledTooltip="Only available in Detached or Inside modes", rawTooltip=true,
          getValue=function() return PV("partyPortraitSize", 0) end,
          setValue=function(v) PtSet("partyPortraitSize", v) end },
        { type="dropdown", text="Position",
          values={ left = "Left", right = "Right", top = "Top",
              insideleft = "Inside Left", insideright = "Inside Right", insidecenter = "Inside Center" },
          order={ "left", "right", "top", "insideleft", "insideright", "insidecenter" },
          itemDisabled=function(v)
              local st = PV("partyPortraitStyle", "none")
              if v == "top" and st == "attached" then return true end
              if IsInside(v) then
                  if PV("partyPortraitMode", "2d") ~= "3d" then return true end
                  if st ~= "detached" then return true end
              end
              return false
          end,
          itemDisabledTooltip=function(v)
              if v == "top" then return "Top position is only available in Detached mode" end
              if IsInside(v) then
                  if PV("partyPortraitMode", "2d") ~= "3d" then return "Inside positions require 3D Art Style" end
                  return "Inside positions require Detached mode"
              end
          end,
          getValue=function() return PV("partyPortraitSide", "left") end,
          setValue=function(v)
              PtSet("partyPortraitSide", v)
              EllesmereUI:RefreshPage()
          end });  y = y - h
    EllesmereUI.BuildInlineCog(sizePosRow._leftRegion, { title = "Portrait Zoom", rows = {
        { type="slider", label="2D Zoom", min=50, max=100, step=1,
          get=function() return PV("partyPortraitArtScale", 100) end,
          set=function(v) PtSet("partyPortraitArtScale", v) end },
        { type="slider", label="3D Zoom", min=100, max=ns.RF_PT_ZOOM3D_MAX, step=1,
          tooltip="Above 300 the camera pulls back to show the whole character.",
          get=function() return PV("partyPortrait3dZoom", 100) end,
          set=function(v) PtSet("partyPortrait3dZoom", v) end },
        { type="slider", label="Character Size", min=50, max=200, step=1,
          tooltip="Scales the 3D character from the portrait's bottom edge, for use with the full-body 3D Zoom range above 300.",
          disabled=function()
              return PV("partyPortraitStyle", "none") ~= "detached" or not IsInside(PV("partyPortraitSide", "left"))
          end,
          disabledTooltip="This option requires an Inside position",
          get=function() return PV("partyPortraitCharScale", 100) end,
          set=function(v) PtSet("partyPortraitCharScale", v) end },
    } })
    EllesmereUI.BuildInlineCog(sizePosRow._rightRegion, { title = "Portrait Position Offsets", rows = {
        { type="slider", label="X Offset", min=-100, max=100, step=1,
          get=function() return PV("partyPortraitX", 0) end,
          set=function(v) PtSet("partyPortraitX", v) end },
        { type="slider", label="Y Offset", min=-100, max=100, step=1,
          get=function() return PV("partyPortraitY", 0) end,
          set=function(v) PtSet("partyPortraitY", v) end },
    }, icon = EllesmereUI.DIRECTIONS_ICON,
    disabled = function() return PV("partyPortraitStyle", "none") ~= "detached" end,
    disabledTooltip = "This option requires Portrait Mode to be set to Detached." })

    if PV("partyPortraitStyle", "none") ~= "detached" then return y end

    -- Row 3 (Detached): Shape | Shape Border (custom colour or class coloured).
    local shapeRow
    shapeRow, h = W:DualRow(parent, y,
        { type="dropdown", text="Shape",
          values={ none = "None", portrait = "Portrait", circle = "Circle", square = "Square",
              csquare = "Rounded Square", diamond = "Diamond", hexagon = "Hexagon", shield = "Shield" },
          order={ "none", "portrait", "circle", "square", "csquare", "diamond", "hexagon", "shield" },
          itemDisabled=function(v) return v == "none" and PV("partyPortraitMode", "2d") ~= "3d" end,
          itemDisabledTooltip=function(v) if v == "none" then return "None shape requires 3D Art Style" end end,
          getValue=function() return PV("partyPortraitShape", "portrait") end,
          setValue=function(v) PtSet("partyPortraitShape", v) end },
        { type="multiSwatch", text="Shape Border",
          swatches = {
            { tooltip = "Custom Color",
              hasAlpha = false,
              getValue = function()
                  local c = db.profile.partyPortraitBorderColor or { r = 0, g = 0, b = 0 }
                  return c.r, c.g, c.b
              end,
              setValue = function(r, g, b)
                  PtSet("partyPortraitBorderColor", { r = r, g = g, b = b })
              end,
              onClick = function(self)
                  if PV("partyPortraitBorderClassColor", true) then
                      PtSet("partyPortraitBorderClassColor", false)
                      EllesmereUI:RefreshPage()
                      return
                  end
                  if self._eabOrigClick then self._eabOrigClick(self) end
              end,
              refreshAlpha = function()
                  return PV("partyPortraitBorderClassColor", true) and 0.3 or 1
              end },
            { tooltip = "Class Colored",
              hasAlpha = false,
              getValue = function()
                  local _, ct = UnitClass("player")
                  local c = ct and RAID_CLASS_COLORS[ct]
                  if c then return c.r, c.g, c.b end
                  return 1, 1, 1
              end,
              setValue = function() end,
              onClick = function()
                  PtSet("partyPortraitBorderClassColor", true)
                  EllesmereUI:RefreshPage()
              end,
              refreshAlpha = function()
                  return PV("partyPortraitBorderClassColor", true) and 1 or 0.3
              end },
          } });  y = y - h
    EllesmereUI.BuildInlineCog(shapeRow._rightRegion, { title = "Shape Border Settings", rows = {
        { type="slider", label="Size", min=1, max=7, step=1,
          get=function() return PV("partyPortraitBorderSize", 7) end,
          set=function(v) PtSet("partyPortraitBorderSize", v) end },
        { type="slider", label="Opacity", min=0, max=100, step=1,
          get=function() return PV("partyPortraitBorderOpacity", 100) end,
          set=function(v) PtSet("partyPortraitBorderOpacity", v) end },
    } })
    return y
end

-- Party page PARTY TARGETS section (every style, not kit-gated): Enable |
-- Include Own Target, then, only while enabled, Fill Color | Background,
-- Width | Height and Position (offsets cog). Party-only keys on db.profile;
-- each setter takes the runtime's own light path (restyle, layout or the
-- include edge), never a party reload. Returns the new y.
function ns.RF_BuildPartyTargets(parent, y, W)
    local db = ns.db
    local BLANK = EllesmereUI.BlankRowCfg
    local _, h, row
    local function PV(k, d)
        local v = db.profile[k]
        if v == nil then return d end
        return v
    end
    -- The party preview draws its own target frames (the real ones are dimmed under it).
    local function Preview()
        if ns.partyPvActive() then ns.ShowPartyPreview() end
    end
    -- Colour and background: the fingerprint-gated restyle and repaint.
    local function PtSet(k, v)
        db.profile[k] = v
        ns.PT_Refresh()
        Preview()
    end
    -- Size, side and offsets: the delta-gated layout (combat-deferred).
    local function LaySet(k, v)
        db.profile[k] = v
        ns._PT_Layout()
        Preview()
    end
    local DARK_TIP = "Not available in Dark Mode. Dark Mode colors can be adjusted in Global Settings -> Fonts & Colors."

    _, h = W:SectionHeader(parent, "PARTY TARGETS", y); y = y - h

    -- Row 1: Enable | Include Own Target. The rows below are HIDDEN while
    -- off, so the flip rebuilds the page.
    local on = db.profile.partyShowTargets == true   -- build time (the page rebuilds)
    _, h = W:DualRow(parent, y,
        { type="toggle", text="Enable Party Targets",
          tooltip="Show a smaller secure target button beside each party frame. Left-click a button to target that party member's current target.",
          getValue=function() return db.profile.partyShowTargets or false end,
          setValue=EllesmereUI.SectionToggleSetValue(function(v)
              db.profile.partyShowTargets = v
              ns.PT_SetEnabled(v)
              Preview()
          end) },
        on and { type="toggle", text="Include Own Target",
          tooltip="Also show your own target beside your frame.",
          -- Hide Self leaves no frame of yours to attach to.
          disabled=function() return db.profile.partyHideSelf == true end,
          disabledTooltip="Hide Self", requireState="disabled",
          getValue=function() return db.profile.partyTargetIncludeSelf or false end,
          setValue=function(v)
              db.profile.partyTargetIncludeSelf = v
              ns.PT_SetIncludeSelf(v)
              Preview()
          end }
        or BLANK());  y = y - h

    if not on then return y end

    -- Row 2: Fill Color | Background (the Health Bar row's controls on the
    -- target frames' own keys).
    row, h = W:DualRow(parent, y,
        { type="dropdown", text="Fill Color",
          values={ class = "Class Color", dark = "Dark Mode", classic = "Classic", custom = "Custom Color" },
          order={ "class", "dark", "classic", "custom" },
          tooltip="Class Color uses the class color for players and the reaction color for NPCs.",
          getValue=function() return PV("partyTargetHealthColorMode", "class") end,
          setValue=function(v)
              PtSet("partyTargetHealthColorMode", v)
              EllesmereUI:RefreshPage()
          end },
        { type="slider", text="Background", min=0, max=100, step=1,
          disabled=function() return PV("partyTargetHealthColorMode", "class") == "dark" end,
          disabledTooltip=DARK_TIP, rawTooltip=true,
          getValue=function() return PV("partyTargetBgDarkness", 50) end,
          setValue=function(v) PtSet("partyTargetBgDarkness", v) end });  y = y - h
    -- Custom fill swatch: live only in Custom mode, dimmed and blocked otherwise.
    if not EllesmereUI._prebuilding then
        local rgn = row._leftRegion
        local swatch = EllesmereUI.BuildColorSwatch(
            rgn, row:GetFrameLevel() + 3,
            function()
                local c = db.profile.partyTargetCustomFillColor
                if c then return c.r, c.g, c.b, 1 end
                return 37/255, 193/255, 29/255, 1
            end,
            function(r, g, b)
                PtSet("partyTargetCustomFillColor", { r=r, g=g, b=b })
            end, false, 20)
        swatch:SetPoint("RIGHT", rgn._lastInline or rgn._control, "LEFT", -8, 0)
        rgn._lastInline = swatch
        -- Blocking overlay: non-clickable + tooltip unless Fill Color is Custom.
        local block = CreateFrame("Frame", nil, swatch)
        block:SetAllPoints()
        block:SetFrameLevel(swatch:GetFrameLevel() + 10)
        block:EnableMouse(true)
        block:SetScript("OnEnter", function() EllesmereUI.ShowWidgetTooltip(swatch, "Only available with Custom fill color") end)
        block:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
        local function UpdateSwatchVis()
            if PV("partyTargetHealthColorMode", "class") == "custom" then
                swatch:SetAlpha(1); block:Hide()
            else
                swatch:SetAlpha(0.3); block:Show()
            end
        end
        EllesmereUI.RegisterWidgetRefresh(UpdateSwatchVis)
        UpdateSwatchVis()
    end
    -- Background Custom + Class swatch pair: clicking either toggles partyTargetBgClassColored, the inactive one dims (mirrors the fill picker).
    if not EllesmereUI._prebuilding then
        local rgn = row._rightRegion
        -- Class swatch shows the player's class color and is not editable.
        local bgClassSwatch = EllesmereUI.BuildColorSwatch(
            rgn, row:GetFrameLevel() + 3,
            function()
                local _, ct = UnitClass("player")
                local cc = ct and EllesmereUI.GetClassColor(ct)
                if cc then return cc.r, cc.g, cc.b, 1 end
                return 1, 1, 1, 1
            end,
            function() end, false, 20)
        bgClassSwatch:SetScript("OnClick", function()
            PtSet("partyTargetBgClassColored", true)
            EllesmereUI:RefreshPage()
        end)
        bgClassSwatch:HookScript("OnEnter", function() EllesmereUI.ShowWidgetTooltip(bgClassSwatch, "Class Colored Background") end)
        bgClassSwatch:HookScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
        bgClassSwatch:SetPoint("RIGHT", rgn._lastInline or rgn._control, "LEFT", -8, 0)
        rgn._lastInline = bgClassSwatch

        local bgSwatch = EllesmereUI.BuildColorSwatch(
            rgn, row:GetFrameLevel() + 3,
            function()
                local c = db.profile.partyTargetCustomBgColor
                if c then return c.r, c.g, c.b, 1 end
                return 17/255, 17/255, 17/255, 1
            end,
            function(r, g, b)
                PtSet("partyTargetCustomBgColor", { r=r, g=g, b=b })
            end, false, 20)
        bgSwatch._eabOrigClick = bgSwatch:GetScript("OnClick")
        bgSwatch:SetScript("OnClick", function(self)
            if PV("partyTargetBgClassColored", false) then
                PtSet("partyTargetBgClassColored", false)
                EllesmereUI:RefreshPage()
                return
            end
            if self._eabOrigClick then self._eabOrigClick(self) end
        end)
        bgSwatch:HookScript("OnEnter", function() EllesmereUI.ShowWidgetTooltip(bgSwatch, "Custom Background Color") end)
        bgSwatch:HookScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
        bgSwatch:SetPoint("RIGHT", rgn._lastInline or rgn._control, "LEFT", -8, 0)
        rgn._lastInline = bgSwatch
        -- Blocking overlay spans BOTH swatches: Dark Mode has no background.
        local bgBlock = CreateFrame("Frame", nil, rgn)
        bgBlock:SetPoint("TOPLEFT", bgSwatch, "TOPLEFT", 0, 0)
        bgBlock:SetPoint("BOTTOMRIGHT", bgClassSwatch, "BOTTOMRIGHT", 0, 0)
        bgBlock:SetFrameLevel(bgClassSwatch:GetFrameLevel() + 10)
        bgBlock:EnableMouse(true)
        bgBlock:SetScript("OnEnter", function() EllesmereUI.ShowWidgetTooltip(bgSwatch, DARK_TIP) end)
        bgBlock:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
        local function UpdateBgSwatchVis()
            if PV("partyTargetHealthColorMode", "class") == "dark" then
                bgSwatch:SetAlpha(0.3); bgClassSwatch:SetAlpha(0.3); bgBlock:Show()
            else
                bgBlock:Hide()
                local classOn = PV("partyTargetBgClassColored", false)
                bgSwatch:SetAlpha(classOn and 0.3 or 1)
                bgClassSwatch:SetAlpha(classOn and 1 or 0.3)
            end
        end
        EllesmereUI.RegisterWidgetRefresh(UpdateBgSwatchVis)
        UpdateBgSwatchVis()
    end

    -- Row 3: Width | Height (absolute, not scaled with the party frames).
    _, h = W:DualRow(parent, y,
        { type="slider", text="Width", min=20, max=300, step=1,
          getValue=function() return PV("partyTargetWidth", 70) end,
          setValue=function(v) LaySet("partyTargetWidth", v) end },
        { type="slider", text="Height", min=10, max=150, step=1,
          getValue=function() return PV("partyTargetHeight", 33) end,
          setValue=function(v) LaySet("partyTargetHeight", v) end });  y = y - h

    -- Row 4: Position (+ offsets cog). Shows the side the frames actually
    -- take (the Horizontal Frames setter's refresh re-reads it); a pick of
    -- the side an unset Position shows (the kit's move included) is stored
    -- as unset, so it keeps following the layout and the frame style.
    -- Under the Party Frames kit the stacked frames' buff side is taken.
    row, h = W:DualRow(parent, y,
        { type="dropdown", text="Position",
          tooltip="Right by default, or Bottom with Horizontal Frames. With Frame Style: Party Frames, the side holding the buffs is not available.",
          values={ top = "Top", bottom = "Bottom", left = "Left", right = "Right" },
          order={ "top", "bottom", "left", "right" },
          itemDisabled=function(v)
              local p = db.profile
              if p.partyHorizontal or not ns.RF_PartyKit() then return false end
              local m = ns.RF_KitBuffMode(p)
              return (m == "RIGHT" and v == "right") or (m == "LEFT" and v == "left")
          end,
          itemDisabledTooltip=function(v)
              if v == "left" or v == "right" then return "Frame Style: Party Frames" end
          end,
          itemRequireState="disabled",
          getValue=function() return ns.PT_ShownSide() end,
          setValue=function(v)
              LaySet("partyTargetPosition", (v ~= ns.PT_ShownSide(true)) and v or nil)
          end },
        BLANK());  y = y - h
    EllesmereUI.BuildInlineCog(row._leftRegion, { title = "Target Position Offsets", rows = {
        { type="slider", label="X Offset", min=-100, max=100, step=1,
          get=function() return PV("partyTargetOffsetX", 0) end,
          set=function(v) LaySet("partyTargetOffsetX", v) end },
        { type="slider", label="Y Offset", min=-100, max=100, step=1,
          get=function() return PV("partyTargetOffsetY", 0) end,
          set=function(v) LaySet("partyTargetOffsetY", v) end },
    }, icon = EllesmereUI.DIRECTIONS_ICON })
    return y
end

local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_LOGIN")

    ns._InitEUIModule = function()
    if not EllesmereUI or not EllesmereUI.RegisterModule then return end
    if not ns.db then return end

    local PP = EllesmereUI.PanelPP
    local db = ns.db
    local ReloadFrames = ns.ReloadFrames
    local floor = math.floor


    ---------------------------------------------------------------------------
    --  Shared helpers
    ---------------------------------------------------------------------------
    local GetFFD = ns.GetFFD

    local function ReloadAndUpdate()
        if ReloadFrames then ReloadFrames() end
        -- Preview refresh keeps health values, updates layout/colors.
        if ns.previewActive and ns.previewActive() and ns.ShowPreview then
            ns.ShowPreview()
        end
        if ns._sizePreviewTier and ns._ShowSizePreview then
            ns._ShowSizePreview(ns._sizePreviewTier)
        end
        if ns.RefreshPvAuraVisuals then ns.RefreshPvAuraVisuals() end
        -- Party frames share all settings except width/height.
        if ns.ReloadPartyFrames then ns.ReloadPartyFrames() end
        if ns.partyPvActive and ns.partyPvActive() and ns.ShowPartyPreview then
            ns.ShowPartyPreview()
        end
    end

    ---------------------------------------------------------------------------
    --  Context-aware settings helpers
    --  With _partyCtx true (party tab), reads/writes go to "party_<key>" with
    --  fallthrough to raid values, so ONE set of page builders serves both tabs.
    ---------------------------------------------------------------------------
    -- Mutable state shared with the page builders under RaidFrames_Options\.
    -- A table instead of locals so every file reads and writes the live value.
    -- _partyCtx: true while building/interacting on the party tab.
    local optState = { _partyCtx = false }
    local PARTY_KEY_SECTION = ns._PARTY_KEY_SECTION or {}
    local IsPartySectionCustom = ns._IsPartySectionCustom

    local function SGet(key)
        if optState._partyCtx and PARTY_KEY_SECTION[key] and IsPartySectionCustom(PARTY_KEY_SECTION[key]) then
            local pv = db.profile["party_" .. key]
            if pv ~= nil then return pv end
        end
        return db.profile[key]
    end
    local function SSet(key, val)
        if optState._partyCtx and PARTY_KEY_SECTION[key] and IsPartySectionCustom(PARTY_KEY_SECTION[key]) then
            db.profile["party_" .. key] = val
        else
            db.profile[key] = val
        end
        if ns._BumpAbsorbGen then ns._BumpAbsorbGen() end
        ReloadAndUpdate()
    end
    local function SVal(key, default)
        if optState._partyCtx and PARTY_KEY_SECTION[key] and IsPartySectionCustom(PARTY_KEY_SECTION[key]) then
            local pv = db.profile["party_" .. key]
            if pv ~= nil then return pv end
        end
        local v = db.profile[key]
        if v ~= nil then return v end
        return default
    end
    -- Context-aware direct write, for color swatches that bypass SSet.
    local function SWrite(key, val)
        if optState._partyCtx and PARTY_KEY_SECTION[key] and IsPartySectionCustom(PARTY_KEY_SECTION[key]) then
            db.profile["party_" .. key] = val
        else
            db.profile[key] = val
        end
        if ns._BumpAbsorbGen then ns._BumpAbsorbGen() end
    end
    -- A border's exact-size companion (<sib>Px) is ONE setting with its legacy
    -- sibling, the party proxy's rule: on the party tab a stored party sibling
    -- carries only the party companion (nil included), never the raid one.
    local function SGetPx(key, sib)
        if optState._partyCtx and PARTY_KEY_SECTION[key] and IsPartySectionCustom(PARTY_KEY_SECTION[key])
           and db.profile["party_" .. sib] ~= nil then
            return db.profile["party_" .. key]
        end
        return SGet(key)
    end

    -- WoW Forever: the Missing Buffs icons' glow (prefix keys missingBuffsGlow*)
    -- as a shared glow descriptor over a read/write pair -- the page's context-
    -- aware SVal/SWrite in the indicator's cog, the raid keys on Global
    -- Settings > Glows (built outside any tab, so never through the tab context).
    local MissingGlowDesc
    if EllesmereUI.IS_FOREVER then
        local GK = EllesmereUI.Glows.PrefixKeys("missingBuffsGlow")
        function MissingGlowDesc(read, write)
            return {
                host = "icon", excludes = { [4] = true },
                caps = { mode = true, params = true, bg = true },
                defaultColor = EllesmereUI.Glows.DEFAULT_COLOR,
                onChange = ReloadAndUpdate,
                disabled = function() return read("showMissingBuffs", true) == false end,
                disabledTooltip = "Missing Buffs",
                get = function(f)
                    if f == "style" then return read(GK.type, 2)
                    elseif f == "mode" then return read(GK.mode, "default")
                    elseif f == "color" then return read(GK.r), read(GK.g), read(GK.b)
                    elseif f == "lines" then return read(GK.lines)
                    elseif f == "thickness" then return read(GK.th)
                    elseif f == "speed" then return read(GK.speed)
                    elseif f == "bg" then return read(GK.bg) == true
                    elseif f == "bgColor" then return read(GK.bgR), read(GK.bgG), read(GK.bgB)
                    end
                end,
                set = function(f, a, b, c)
                    if f == "style" then write(GK.type, a)
                    elseif f == "mode" then write(GK.mode, a)
                    elseif f == "color" then write(GK.r, a); write(GK.g, b); write(GK.b, c)
                    elseif f == "lines" then write(GK.lines, a)
                    elseif f == "thickness" then write(GK.th, a)
                    elseif f == "speed" then write(GK.speed, a)
                    elseif f == "bg" then write(GK.bg, a and true or nil)
                    elseif f == "bgColor" then write(GK.bgR, a); write(GK.bgG, b); write(GK.bgB, c)
                    end
                end,
            }
        end
        EllesmereUI.GlowOptions.RegisterSite({ id = "rf_missing_buffs", label = "Missing Buffs Glow",
            group = "module", module = "EllesmereUIRaidFrames", page = PAGE_MAIN,
            section = "INDICATORS", highlight = "Missing Buffs",
            desc = MissingGlowDesc(
                function(key, default)
                    local v = db.profile[key]
                    if v == nil then return default end
                    return v
                end,
                function(key, v) db.profile[key] = v end) })
    end

    ---------------------------------------------------------------------------
    --  Health bar texture dropdown
    ---------------------------------------------------------------------------
    -- Re-append post-login: the OnInitialize append runs too early to catch most
    -- SM texture providers, which register after our ADDON_LOADED.
    EllesmereUI.AppendSharedMediaTextures(
        ns.healthBarTextureNames or {},
        ns.healthBarTextureOrder or {},
        nil,
        ns.healthBarTextures
    )

    local hbtValues = {}
    local hbtOrder = {}
    do
        local texNames = ns.healthBarTextureNames or {}
        local texOrder2 = ns.healthBarTextureOrder or {}
        local texLookup = ns.healthBarTextures or {}
        for _, key in ipairs(texOrder2) do
            if key ~= "---" then
                hbtValues[key] = texNames[key] or key
            end
            hbtOrder[#hbtOrder + 1] = key
        end
        hbtValues._menuOpts = {
            itemHeight = 28,
            background = function(key) return texLookup[key] end,
        }
    end

    ---------------------------------------------------------------------------
    --  Value tables for dropdowns
    ---------------------------------------------------------------------------
    local healthColorValues = {
        ["class"]         = "Class Color",
        ["classReactive"] = "Class Color Reactive",
        ["dark"]          = "Dark Mode",
        ["classic"]       = "Classic",
        ["custom"]        = "Custom Color",
        ["customDynamic"] = "Custom Dynamic Colors",
    }
    local healthColorOrder = { "class", "classReactive", "dark", "classic", "custom", "customDynamic" }

    local namePositionValues = EllesmereUI.POSITION_GRID_VALUES
    local namePositionOrder = EllesmereUI.POSITION_GRID_ORDER

    -- Name Position adds "None" (hides the name); Health Text Position reuses these base tables, so keep "None" out of the shared set.
    local namePositionValuesName = EllesmereUI.POSITION_GRID_VALUES_NONE
    local namePositionOrderName = { "topleft", "top", "topright", "left", "center", "right", "bottomleft", "bottom", "bottomright", "none" }

    local healthTextValues = {
        ["none"]          = "None",
        ["percent"]       = "Percent",
        ["percentNoSign"] = "Percent (No Sign)",
        ["number"]        = "Number",
        ["numberPercent"] = "Number | Percent",
        ["percentNumber"] = "Percent | Number",
        ["missing"]       = "Missing Number",
    }
    local healthTextOrder = { "none", "percent", "percentNoSign", "number", "numberPercent", "percentNumber", "missing" }

    local absorbStyleValues = {
        ["none"]            = "None",
        ["striped"]         = "Striped",
        ["stripedReversed"] = "Striped Reversed",
        ["stripedThick"]    = "Striped Thick",           -- striped-thick.png
        ["stripedThickR"]   = "Striped Thick Reversed",  -- striped-thick-r.png
        ["clean"]           = "Clean (Flat)",
        ["blizzard"]        = "Classic WoW",          -- DB key stays "blizzard"; label only
        ["blizzardModern"]  = "Default Blizz Frames", -- compound: solid base + tiled stripes (shield only)
        ["healBlizzModern"] = "Default Blizz Frames", -- heal-absorb only: louis-absorb.png texture
        ["largeOutlinedStripes"]  = "Large Outlined Stripes",  -- heal-absorb only: large-habsorb-left.png
        ["largeOutlinedStripesR"] = "Large Outlined Stripes R", -- heal-absorb only: large-habsorb-right.png
        ["largeStripes"]          = "Large Stripes",            -- large-absorb-left.png
        ["largeStripesR"]         = "Large Stripes R",          -- large-absorb-right.png
        ["maxHealthStripes"]      = "Max Health Stripes",       -- reduced max-health overlay
        -- The native raid fill (the shared-media copy dedupes against it).
        ["blizzardRaid"]          = "Blizzard Raid Bar",
        ["pixelsShield"]          = "Pixels Shield",            -- pixels-shield.tga
        ["pixelsShieldEdge"]      = "Pixels Shield Edge",       -- shield-only: pixels-shield-edge.tga
        ["pixelsShieldFill"]      = "Pixels Shield Fill",       -- shield-only: pixels-shield-fill.tga (tiled)
    }
    -- Shield absorb shows every style including Blizzard (Modern).
    local absorbStyleOrder = { "none", "blizzardModern", "striped", "stripedReversed", "stripedThick", "stripedThickR", "clean", "blizzard", "largeStripes", "largeStripesR", "blizzardRaid", "pixelsShield", "pixelsShieldEdge", "pixelsShieldFill" }
    -- Heal absorb shares the values table but EXCLUDES Blizzard (Modern).
    local healAbsorbStyleOrder = { "none", "healBlizzModern", "striped", "stripedReversed", "stripedThick", "stripedThickR", "clean", "blizzard", "largeOutlinedStripes", "largeOutlinedStripesR", "largeStripes", "largeStripesR", "blizzardRaid", "pixelsShield" }
    -- Max Health mirrors Heal Absorb plus "Max Health Stripes" first.
    local maxHealthStyleOrder = { "none", "maxHealthStripes", "striped", "stripedReversed", "stripedThick", "stripedThickR", "clean", "blizzard", "healBlizzModern", "largeOutlinedStripes", "largeOutlinedStripesR", "largeStripes", "largeStripesR", "blizzardRaid", "pixelsShield" }
    -- Appends SharedMedia statusbar textures after a divider (mirrors Bar Texture dropdown). "sm:" keys land in the shared health-bar tables via AppendSharedMediaTextures; resolution flows through ns.ResolveAbsorbStyleTex -> health-bar lookup.
    -- All three dropdowns share absorbStyleValues, so each gains the SM entries and preview swatch.
    do
        EllesmereUI.AppendSharedMediaTextures(
            ns.healthBarTextureNames or {}, ns.healthBarTextureOrder or {}, nil, ns.healthBarTextures)
        local smNames = ns.healthBarTextureNames or {}
        local smKeys = {}
        for _, k in ipairs(ns.healthBarTextureOrder or {}) do
            if type(k) == "string" and k:find("^sm:") then
                smKeys[#smKeys + 1] = k
                absorbStyleValues[k] = smNames[k] or k
            end
        end
        if #smKeys > 0 then
            for _, ord in ipairs({ absorbStyleOrder, healAbsorbStyleOrder, maxHealthStyleOrder }) do
                ord[#ord + 1] = "---"
                for _, k in ipairs(smKeys) do ord[#ord + 1] = k end
            end
        end
        -- Preview swatch behind each row via ns.ResolveAbsorbStyleTex. Default Blizz
        -- Frames draws its in-game compound: tinted tiled stripes over the solid base
        -- (ns.ApplyModernAbsorbBar / the _modernBase colour).
        local modernSwatch = { base = { 0.776, 0.784, 1.0 }, tint = { 0.569, 0.588, 1.0 }, tile = true }
        absorbStyleValues._menuOpts = {
            itemHeight = 28,
            background = function(key)
                if not key or key == "---" or key == "none" then return nil end
                if key == "blizzardModern" then return ns.ResolveAbsorbStyleTex("striped"), modernSwatch end
                if key == "maxHealthStripes" then return "Interface\\AddOns\\EllesmereUIRaidFrames\\Media\\striped-maxhp.png" end
                return ns.ResolveAbsorbStyleTex and ns.ResolveAbsorbStyleTex(key) or nil
            end,
        }
    end

    local growthValues = {
        DOWN  = "Down",
        UP    = "Up",
        RIGHT = "Right",
        LEFT  = "Left",
    }
    local allGrowthOrder        = { "DOWN", "UP", "RIGHT", "LEFT" }

    -- ns._RFGrowthIsVertical is the runtime module's single source of truth for
    -- this check (EllesmereUIRaidFrames.lua); reuse it here rather than a second copy.
    local GrowthIsVertical = ns._RFGrowthIsVertical

    -- Merge Groups renders through Blizzard's flat SecureGroupHeader, whose column
    -- axis (columnAnchorPoint) is always perpendicular to Unit Growth -- a same-axis
    -- Group Growth has no valid column direction, so the runtime silently substitutes
    -- an unrelated one instead of honoring it. Bump the OTHER axis to a perpendicular
    -- value instead of letting an unrenderable pair through, mirroring the Spell
    -- Name/Spell Target side-conflict rule used elsewhere in these options.
    local function KeepGrowthPerpendicular(newVal, getOther, setOther)
        local other = getOther()
        if GrowthIsVertical(newVal) == GrowthIsVertical(other) then
            setOther(GrowthIsVertical(newVal) and "RIGHT" or "DOWN")
        end
    end

    -- Every preview mode dropdown across tabs; all refresh when one changes.
    local pvModeDropdowns = {}

    -- Preview Mode controls carrying override-preview chrome (gold border host
    -- + tooltip), one entry per built row across tabs/rebuilds.
    local pvModeCtrls = {}

    -- Gold border + tooltip on every Preview Mode control while the REAL preview renders an override's effective values (spec group or applied conditional). State comes from the runtime resolvers, NEVER the panel's view flags, so it always matches what the real preview shows.
    -- Recomputed at row build time and from ns._RebuildPvOverlay (view/spec/conditional changes).
    function ns._UpdatePvModeChrome()
        if #pvModeCtrls == 0 then return end
        local text
        if (db.profile.previewMode or "overlay") == "real" then
            -- Editing-as session: preview shows THAT session's values (effective overlay off there by design), so name it.
            local sessName = EllesmereUI.SpecOverrides_EditSessionName()
            if sessName then
                text = EllesmereUI.Lf("Previewing Override: %1$s", sessName)
            elseif EllesmereUI.SpecOverrides_PeekEffectiveValues then
                local _, specSrc, condSrc =
                    EllesmereUI.SpecOverrides_PeekEffectiveValues("EllesmereUIRaidFrames")
                if specSrc and condSrc then
                    text = EllesmereUI.Lf("Previewing Overrides: %1$s, %2$s", specSrc, condSrc)
                elseif specSrc or condSrc then
                    text = EllesmereUI.Lf("Previewing Override: %1$s", specSrc or condSrc)
                end
            end
        end
        for _, e in ipairs(pvModeCtrls) do
            if e.gold then e.gold:SetShown(text ~= nil) end
            if e.ctrl then
                e.ctrl._ttText = text
                e.ctrl._ttOpts = nil
            end
        end
    end

    -- True when preview is disabled; eyeball toggles gray out.
    local function IsPreviewOff()
        return (db.profile.previewMode or "overlay") == "none"
    end

    -- Builds the "Preview Mode" row at the top of a page; returns the new y.
    local function BuildPreviewModeRow(parent, y)
        local ROW_H = 50
        local fontPath = (EllesmereUI.GetFontPath("raidFrames")) or "Fonts\\FRIZQT__.TTF"
        local contentPad = EllesmereUI.CONTENT_PAD or 45

        y = y - 10
        local modeRow = CreateFrame("Frame", nil, parent)
        PP.Size(modeRow, parent:GetWidth() - contentPad * 2, ROW_H)
        PP.Point(modeRow, "TOPLEFT", parent, "TOPLEFT", contentPad, y)
        y = y - ROW_H

        local modeLabel = modeRow:CreateFontString(nil, "OVERLAY")
        EllesmereUI.ApplyModuleFont(modeLabel, fontPath, 14, "raidFrames")
        modeLabel:SetPoint("TOP", modeRow, "TOP", 0, 0)
        modeLabel:SetText(EllesmereUI.L("Preview Mode"))
        modeLabel:SetTextColor(1, 1, 1, 0.6)

        local previewModeValues = {
            real    = "Real Preview",
            overlay = "Overlay Preview",
            none    = "No Preview",
        }
        local previewModeOrder = { "real", "overlay", "none" }
        local ddCtrl, ddLbl = EllesmereUI.BuildDropdownControl(
            modeRow, 180, modeRow:GetFrameLevel() + 2,
            previewModeValues, previewModeOrder,
            function() return db.profile.previewMode or "overlay" end,
            function(v)
                db.profile.previewMode = v
                -- Apply to whichever preview the current tab owns.
                local page = EllesmereUI:GetActivePage()
                if page == PAGE_PARTY then
                    if v == "none" then
                        if ns.HidePartyPreview then ns.HidePartyPreview() end
                    else
                        if ns.HidePreview then ns.HidePreview() end
                        if ns.ShowPartyPreview then ns.ShowPartyPreview() end
                    end
                else
                    if ns.ApplyPreviewMode then ns.ApplyPreviewMode() end
                    if ns.HidePartyPreview then ns.HidePartyPreview() end
                end
                for _, syncLbl in ipairs(pvModeDropdowns) do
                    syncLbl:SetText(previewModeValues[v] or v)
                end
                EllesmereUI:RefreshPage()
            end)
        ddCtrl:SetPoint("TOP", modeLabel, "BOTTOM", 0, -9)

        pvModeDropdowns[#pvModeDropdowns + 1] = ddLbl

        -- Override-preview chrome lives on a SEPARATE gold border host: the control's own border is re-asserted by its hover scripts, so never recolor it directly (same pattern as the overrides UI slot marks).
        do
            local gold = EllesmereUI._SPECOV_GOLD or { 199 / 255, 166 / 255, 90 / 255 }
            local host = CreateFrame("Frame", nil, ddCtrl)
            host:SetAllPoints(ddCtrl)
            host:SetFrameLevel(ddCtrl:GetFrameLevel() + 30)
            EllesmereUI.PP.CreateBorder(host, gold[1], gold[2], gold[3], 0.9, 1, "OVERLAY", 7)
            host:Hide()
            pvModeCtrls[#pvModeCtrls + 1] = { ctrl = ddCtrl, gold = host }
        end
        if ns._UpdatePvModeChrome then ns._UpdatePvModeChrome() end

        ns._previewMode = db.profile.previewMode or "overlay"
        return y
    end


    ---------------------------------------------------------------------------
    --  Visual settings sections (shared by raid + party pages)
    ---------------------------------------------------------------------------
    local function BuildVisualSections(parent, y, W, onSection)
        local _, h
        local row
        local _secY  -- section start tracker
        -- Eyeball handles are per-context (raid vs party) so the two page builds don't clobber each other's eye-icon refreshers. Animation start/stop stay on ns: one shared ticker resolves the active preview at call time via ns.PvActiveFrames.
        local _eyeCtx = optState._partyCtx and "party" or "raid"
        ns._eye = ns._eye or {}
        ns._eye[_eyeCtx] = ns._eye[_eyeCtx] or {}
        local EYE = ns._eye[_eyeCtx]
        -------------------------------------------------------------------
        --  HEALTH BAR
        -------------------------------------------------------------------
        _secY = y
        local healthHeader
        healthHeader, h = W:SectionHeader(parent, "HEALTH BAR", y); y = y - h

        -- Eyeball: animate health bars (damage/healing simulation); built on raid + party pages, reads the active frame set via ns.PvActiveFrames().
        do
            local EYE_VISIBLE   = EllesmereUI.EYE_VISIBLE_ICON
            local EYE_INVISIBLE = EllesmereUI.EYE_INVISIBLE_ICON
            -- State lives on ns (single shared ticker) so raid and party eyeball builds drive one animation and start/stop works across both. ns._healthAnimActive is the truth the renderer reads.
            ns._healthAnimState = ns._healthAnimState or {}

            local function StopHealthAnim()
                if ns._healthAnimTicker then
                    ns._healthAnimTicker:Cancel()
                    ns._healthAnimTicker = nil
                end
                ns._healthAnimActive = false
                -- Pause: persist animated values so they stay on screen.
                local phv = ns.PvHealthValues()
                if phv then
                    for i, st in ipairs(ns._healthAnimState) do
                        phv[i] = st.current
                    end
                end
            end
            -- Exposed for onModuleLeave below.
            ns.StopHealthAnim = StopHealthAnim

            local function StartHealthAnim()
                if ns._healthAnimTicker then return end
                ns._healthAnimActive = true
                wipe(ns._healthAnimState)

                local frames = ns.PvActiveFrames()
                for i = 1, 20 do
                    local f = frames[i]
                    if f and f._health then
                        ns._healthAnimState[i] = {
                            frame = f,
                            current = f._healthPct or (40 + math.random(60)),
                            target = 20 + math.random(80),
                            snapTimer = math.random() * 2,
                            nextSnap = 1.2 + math.random() * 1.6,
                        }
                    end
                end

                local smoothInterp = Enum and Enum.StatusBarInterpolation
                    and Enum.StatusBarInterpolation.ExponentialEaseOut
                ns._healthAnimTicker = C_Timer.NewTicker(0.1, function()
                    if not ns._healthAnimActive then return end
                    -- Real preview contract: ticks must render effective-overlay values only, never the panel view's swapped values.
                    local s = ns.PvSettings()
                    local smooth = s.smoothBars
                    local invert = ns.RF_IsInvertedFill(s)

                    for i, st in ipairs(ns._healthAnimState) do
                        local f = st.frame
                        if f and f._health and not f._pvHideHealthText then
                            -- Per-unit staggered timer, same cadence smooth or not.
                            st.snapTimer = st.snapTimer + 0.1
                            if st.snapTimer < st.nextSnap then
                            else
                                st.snapTimer = 0
                                st.nextSnap = 1.2 + math.random() * 1.6
                                st.current = st.target
                                st.target = 15 + math.random(85)

                                local barPct = invert and (100 - st.current) or st.current
                                if smooth and smoothInterp then
                                    f._health:SetValue(barPct, smoothInterp)
                                else
                                    f._health:SetValue(barPct)
                                end

                                if f._healthText then
                                    local mode = s.healthTextMode or "none"
                                    if mode == "percent" then
                                        f._healthText:SetFormattedText("%d%%", st.current)
                                    elseif mode == "percentNoSign" then
                                        f._healthText:SetFormattedText("%d", st.current)
                                    elseif mode == "number" then
                                        local fakeHP = st.current * 12000
                                        if AbbreviateNumbers then
                                            f._healthText:SetText(AbbreviateNumbers(fakeHP))
                                        end
                                    elseif mode == "numberPercent" then
                                        local fakeHP = st.current * 12000
                                        local numStr = AbbreviateNumbers and AbbreviateNumbers(fakeHP) or tostring(fakeHP)
                                        f._healthText:SetFormattedText("%s | %d%%", numStr, st.current)
                                    elseif mode == "percentNumber" then
                                        local fakeHP = st.current * 12000
                                        local numStr = AbbreviateNumbers and AbbreviateNumbers(fakeHP) or tostring(fakeHP)
                                        f._healthText:SetFormattedText("%d%% | %s", st.current, numStr)
                                    elseif mode == "missing" then
                                        local fakeHP = (100 - st.current) * 12000
                                        f._healthText:SetText(C_StringUtil.TruncateWhenZero(fakeHP))
                                        if f._healthText:GetText() then
                                            if AbbreviateNumbers then
                                                f._healthText:SetText(AbbreviateNumbers(fakeHP))
                                            end
                                        end
                                    end
                                end

                                -- Fill color only moves in gradient modes.
                                if s.healthColorMode == "classic" then
                                    local pct = st.current / 100
                                    local r = pct < 0.5 and 1 or (1 - (pct - 0.5) * 2)
                                    local g = pct > 0.5 and 1 or (pct * 2)
                                    f._health:SetStatusBarColor(r, g, 0, (s.healthBarOpacity or 100) / 100)
                                elseif s.healthColorMode == "customDynamic" then
                                    local r, g, b = ns.ResolveDynamicColor(s, st.current / 100)
                                    f._health:SetStatusBarColor(r, g, b, (s.healthBarOpacity or 100) / 100)
                                elseif s.healthColorMode == "classReactive" then
                                    local r, g, b = ns.ResolveClassReactiveColor(s, f._classToken, st.current / 100)
                                    f._health:SetStatusBarColor(r, g, b, (s.healthBarOpacity or 100) / 100)
                                end
                            end -- snapTimer ready
                        end
                    end
                end)
            end

            -- Eye button anchors to the section header's label FontString.
            local headerLabel
            for _, rgn in ipairs({ healthHeader:GetRegions() }) do
                if rgn.GetText and EllesmereUI.EnKey(rgn:GetText()) == "HEALTH BAR" then
                    headerLabel = rgn; break
                end
            end
            local eyeBtn = CreateFrame("Button", nil, healthHeader)
            eyeBtn:SetSize(24, 24)
            if headerLabel then
                eyeBtn:SetPoint("LEFT", headerLabel, "RIGHT", 5, 0)
            else
                eyeBtn:SetPoint("LEFT", healthHeader, "BOTTOMLEFT", 85, 8)
            end
            eyeBtn:SetFrameLevel(healthHeader:GetFrameLevel() + 5)
            eyeBtn:SetAlpha(0.4)
            local eyeTex = eyeBtn:CreateTexture(nil, "OVERLAY")
            eyeTex:SetAllPoints()
            local function RefreshHealthEye()
                if IsPreviewOff() then
                    eyeTex:SetTexture(EYE_VISIBLE)
                    eyeBtn:SetAlpha(0.15)
                    return
                end
                eyeTex:SetTexture(ns._healthAnimActive and EYE_INVISIBLE or EYE_VISIBLE)
                eyeBtn:SetAlpha(0.4)
            end
            RefreshHealthEye()
            EYE.refreshHealthEye = RefreshHealthEye
            ns._stopHealthAnim = StopHealthAnim
            ns._startHealthAnim = StartHealthAnim
            eyeBtn:SetScript("OnClick", function()
                if IsPreviewOff() then return end
                if ns._healthAnimActive then
                    StopHealthAnim()
                else
                    if ns._indicatorsVisible then
                        ns._indicatorsVisible = false
                        if EYE.refreshIndicatorEye then EYE.refreshIndicatorEye() end
                    end
                    StartHealthAnim()
                end
                RefreshHealthEye()
                if ns.PvRefresh then ns.PvRefresh() end
            end)
            eyeBtn:SetScript("OnEnter", function(self)
                if IsPreviewOff() then
                    EllesmereUI.ShowWidgetTooltip(self, "Enable preview to use")
                    return
                end
                self:SetAlpha(0.7)
                EllesmereUI.ShowWidgetTooltip(self, ns._healthAnimActive and "Stop health bar effects" or "Preview health bar effects")
            end)
            eyeBtn:SetScript("OnLeave", function(self)
                if not IsPreviewOff() then self:SetAlpha(0.4) end
                EllesmereUI.HideWidgetTooltip()
            end)

            EllesmereUI:RegisterOnHide(function()
                if ns._healthAnimActive then StopHealthAnim(); RefreshHealthEye() end
            end)

            -- One-time eyeball hint, raid/main page only.
            if not optState._partyCtx and not (EllesmereUIDB and EllesmereUIDB.rfEyeHintSeen) then
                local TIP_W, TIP_H = 310, 82
                local EG = EllesmereUI.ELLESMERE_GREEN or { r = 0.05, g = 0.83, b = 0.62 }
                local ar, ag, ab = EG.r, EG.g, EG.b

                -- On the panel body like the other panel tips: it hides with the
                -- window when it collapses and rides the panel scale.
                local tip = CreateFrame("Frame", nil, EllesmereUI._panelBody)
                tip:SetFrameStrata("FULLSCREEN_DIALOG")
                tip:SetFrameLevel(200)
                if PP then PP.Size(tip, TIP_W, TIP_H) end
                tip:SetSize(TIP_W, TIP_H)
                tip:EnableMouse(true)
                tip:SetPoint("TOP", eyeBtn, "BOTTOM", 0, -14)

                local tipBg = tip:CreateTexture(nil, "BACKGROUND")
                tipBg:SetAllPoints()
                tipBg:SetColorTexture(0.06, 0.08, 0.10, 0.95)

                EllesmereUI.MakeBorder(tip, ar, ag, ab, 0.25, PP)

                -- Arrow pointing up (clipped diamond)
                local ARROW_SZ = 16
                local arrowClip = CreateFrame("Frame", nil, tip)
                arrowClip:SetFrameStrata("FULLSCREEN_DIALOG")
                arrowClip:SetFrameLevel(tip:GetFrameLevel() + 10)
                arrowClip:SetClipsChildren(true)
                arrowClip:SetSize(ARROW_SZ * 2, ARROW_SZ)
                arrowClip:SetPoint("BOTTOM", tip, "TOP", 0, -1)

                local arrowFrame = CreateFrame("Frame", nil, arrowClip)
                arrowFrame:SetFrameLevel(arrowClip:GetFrameLevel() + 1)
                arrowFrame:SetSize(ARROW_SZ + 4, ARROW_SZ + 4)
                arrowFrame:SetPoint("CENTER", arrowClip, "BOTTOM", 0, 0)

                local arrowBorder = arrowFrame:CreateTexture(nil, "ARTWORK", nil, 7)
                arrowBorder:SetSize(ARROW_SZ + 2, ARROW_SZ + 2)
                arrowBorder:SetPoint("CENTER")
                arrowBorder:SetColorTexture(ar, ag, ab, 0.18)
                arrowBorder:SetRotation(math.rad(45))
                if arrowBorder.SetSnapToPixelGrid then arrowBorder:SetSnapToPixelGrid(false); arrowBorder:SetTexelSnappingBias(0) end

                local arrowFill = arrowFrame:CreateTexture(nil, "OVERLAY", nil, 6)
                arrowFill:SetSize(ARROW_SZ, ARROW_SZ)
                arrowFill:SetPoint("CENTER")
                arrowFill:SetColorTexture(0.06, 0.08, 0.10, 0.95)
                arrowFill:SetRotation(math.rad(45))
                if arrowFill.SetSnapToPixelGrid then arrowFill:SetSnapToPixelGrid(false); arrowFill:SetTexelSnappingBias(0) end

                local msg = EllesmereUI.MakeFont(tip, 10, nil, 1, 1, 1, 0.85)
                msg:SetPoint("TOP", tip, "TOP", 0, -12)
                msg:SetWidth(TIP_W - 24)
                msg:SetJustifyH("CENTER")
                msg:SetSpacing(4)
                msg:SetText(EllesmereUI.L("Click this eye icon to preview live\nhealth bar effects like absorbs and healing."))

                local okBtn = CreateFrame("Button", nil, tip)
                okBtn:SetSize(70, 22)
                okBtn:SetPoint("BOTTOM", tip, "BOTTOM", 0, 10)
                EllesmereUI.MakeStyledButton(okBtn, "Okay", 10,
                    EllesmereUI.RB_COLOURS, function()
                        tip:Hide()
                        ns._rfEyeHintTip = nil
                        EllesmereUIDB = EllesmereUIDB or {}
                        EllesmereUIDB.rfEyeHintSeen = true
                    end)

                ns._rfEyeHintTip = tip

                tip:SetAlpha(0)
                tip:Show()
                local fadeIn = 0
                tip:SetScript("OnUpdate", function(self, dt)
                    fadeIn = fadeIn + dt
                    if fadeIn >= 0.3 then
                        self:SetAlpha(1)
                        self:SetScript("OnUpdate", nil)
                        return
                    end
                    self:SetAlpha(fadeIn / 0.3)
                end)
            end
        end  -- close do (health eyeball)

        local texRow
        texRow, h = W:DualRow(parent, y,
            { type="dropdown", text="Health Bar Texture", values=hbtValues, order=hbtOrder,
              getValue=function() return SVal("healthBarTexture", "atrocity") end,
              setValue=function(v) SSet("healthBarTexture", v) end },
            { type="slider", text="Fill Opacity", min=0, max=100, step=1,
              disabled=function() return SVal("healthColorMode", "class") == "dark" end,
              disabledTooltip="Not available in Dark Mode", rawTooltip=true,
              getValue=function() return SVal("healthBarOpacity", 100) end,
              setValue=function(v) SSet("healthBarOpacity", v) end });
        -- Vertical Fill cog lives in the Health Bar party-sync section, so an unsynced party tab keeps its own value.
        if not EllesmereUI._prebuilding then
            local lrgn = texRow._leftRegion
            EllesmereUI.BuildInlineCog(lrgn, {
                title = "Health Bar Fill",
                rows = {
                    ns.RF_PartyKitGate({ type="toggle", label="Vertical Fill",
                      tooltip="Fill the health bar bottom-to-top instead of left-to-right. Absorbs, heal prediction and the bar background follow the same axis.",
                      get=function() return SVal("healthVerticalFill", false) end,
                      -- RefreshPage re-labels Absorbs Placement for the new axis; cog popups bake labels in on first build.
                      set=function(v) SSet("healthVerticalFill", v); EllesmereUI:RefreshPage() end }),
                    ns.RF_PartyKitGate({ type="toggle", label="Fill Missing Health",
                      tooltip="The bar fills with missing health, growing as the unit takes damage.",
                      get=function() return SVal("healthInvertFill", false) end,
                      set=function(v) SSet("healthInvertFill", v) end }),
                },
            })
        end
        y = y - h

        row, h = W:DualRow(parent, y,
            { type="dropdown", text="Fill Color", values=healthColorValues, order=healthColorOrder,
              tooltip="Custom Dynamic Colors: the health bar smoothly blends between three colors you pick -- one for full health (100%), one for half (50%), and one for empty (0%) -- shifting through them as the unit takes damage or is healed.",
              getValue=function() return SVal("healthColorMode", "class") end,
              setValue=function(v)
                  SSet("healthColorMode", v)
                  -- "dark" feeds the Dark Mode conditional-override condition.
                  EllesmereUI.Conditions_Recheck()
                  EllesmereUI:RefreshPage()
              end },
            { type="slider", text="Background", min=0, max=100, step=1,
              disabled=function() return SVal("healthColorMode", "class") == "dark" end,
              disabledTooltip="Not available in Dark Mode. Dark Mode colors can be adjusted in Global Settings -> Fonts & Colors.", rawTooltip=true,
              getValue=function() return SVal("bgDarkness", 50) end,
              setValue=function(v) SSet("bgDarkness", v) end });  y = y - h
        -- Fill Color's "dark" choice IS the Dark Mode condition's input, so lock the dropdown while a Dark Mode conditional is being edited -- else the override could capture a mode change that flips its own condition.
        if EllesmereUI.SpecOverrides_AttachEditLock and not EllesmereUI._prebuilding then
            EllesmereUI.SpecOverrides_AttachEditLock(row._leftRegion,
                "Fill Color's Dark Mode choice drives a Dark Mode override condition, so it can't be changed while editing an override",
                EllesmereUI.SpecOverrides_DarkCondEditActive)
        end
        -- Custom fill swatch plus the three Custom Dynamic stop swatches (100/50/0%) share one inline slot; the Fill Color mode decides which set is interactive.
        if not EllesmereUI._prebuilding then
            local rgn = row._leftRegion

            local swatch = EllesmereUI.BuildColorSwatch(
                rgn, row:GetFrameLevel() + 3,
                function()
                    local c = SGet("customFillColor")
                    if c then return c.r, c.g, c.b, 1 end
                    return 37/255, 193/255, 29/255, 1
                end,
                function(r, g, b)
                    SWrite("customFillColor", { r=r, g=g, b=b })
                    ReloadAndUpdate()
                end, false, 20)
            swatch:SetPoint("RIGHT", rgn._lastInline or rgn._control, "LEFT", -8, 0)
            rgn._lastInline = swatch
            -- Blocking overlay: non-clickable + tooltip unless Fill Color is Custom.
            local block = CreateFrame("Frame", nil, swatch)
            block:SetAllPoints()
            block:SetFrameLevel(swatch:GetFrameLevel() + 10)
            block:EnableMouse(true)
            block:SetScript("OnEnter", function() EllesmereUI.ShowWidgetTooltip(swatch, "Only available with Custom fill color") end)
            block:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)

            -- Three gradient-stop swatches, built right-to-left so the visual order reads 100% | 50% | 0%; tooltips carry the pct.
            local dynDefs = {
                { key = "dynamicColor100", def = { r = 0, g = 1, b = 0 }, label = "100%", tip = "Health bar color at full (100%) health" },
                { key = "dynamicColor50",  def = { r = 0xEC/255, g = 0xEC/255, b = 0x32/255 }, label = "50%",  tip = "Health bar color at half (50%) health" },
                { key = "dynamicColor0",   def = { r = 0xE3/255, g = 0x30/255, b = 0x30/255 }, label = "0%",   tip = "Health bar color at empty (0%) health" },
            }
            local dynSwatches = {}
            local prevAnchor = rgn._control
            for i = #dynDefs, 1, -1 do
                local dd = dynDefs[i]
                local sw = EllesmereUI.BuildColorSwatch(
                    rgn, row:GetFrameLevel() + 3,
                    function()
                        local c = SGet(dd.key) or dd.def
                        return c.r, c.g, c.b, 1
                    end,
                    function(r, g, b)
                        SWrite(dd.key, { r=r, g=g, b=b })
                        ReloadAndUpdate()
                    end, false, 18)
                sw:SetPoint("RIGHT", prevAnchor, "LEFT", (prevAnchor == rgn._control) and -8 or -6, 0)
                sw:HookScript("OnEnter", function() EllesmereUI.ShowWidgetTooltip(sw, dd.tip) end)
                sw:HookScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
                dynSwatches[i] = sw
                prevAnchor = sw
            end

            local function UpdateSwatchVis()
                local mode = SVal("healthColorMode", "class")
                local isDynamic = mode == "customDynamic"
                -- Class Reactive shares the dynamic stops but its 100% color IS
                -- the class color: only the 0%/50% swatches apply there.
                local isClassReactive = mode == "classReactive"
                -- Single custom swatch: live only in Custom mode, dimmed+blocked in other modes, fully HIDDEN in Dynamic/Class Reactive modes so it doesn't sit behind the dynamic swatches.
                if isDynamic or isClassReactive then
                    swatch:Hide(); block:Hide()
                else
                    swatch:Show()
                    if mode == "custom" then swatch:SetAlpha(1); block:Hide()
                    else swatch:SetAlpha(0.3); block:Show() end
                end
                for i, sw in ipairs(dynSwatches) do
                    -- dynSwatches[1] = the 100% stop (class-driven in Class Reactive).
                    if isDynamic or (isClassReactive and i > 1) then sw:Show() else sw:Hide() end
                end
            end
            EllesmereUI.RegisterWidgetRefresh(UpdateSwatchVis)
            UpdateSwatchVis()
        end
        -- Background Custom + Class swatch pair: clicking either toggles bgClassColored, the inactive one dims (mirrors the fill picker).
        do
            local rgn = row._rightRegion
            -- Class swatch shows the player's class color and is not editable.
            local bgClassSwatch = EllesmereUI.BuildColorSwatch(
                rgn, row:GetFrameLevel() + 3,
                function()
                    local _, ct = UnitClass("player")
                    local cc = ct and EllesmereUI.GetClassColor(ct)
                    if cc then return cc.r, cc.g, cc.b, 1 end
                    return 1, 1, 1, 1
                end,
                function() end, false, 20)
            bgClassSwatch:SetScript("OnClick", function()
                SSet("bgClassColored", true)
                ReloadAndUpdate(); EllesmereUI:RefreshPage()
            end)
            bgClassSwatch:HookScript("OnEnter", function() EllesmereUI.ShowWidgetTooltip(bgClassSwatch, "Class Colored Background") end)
            bgClassSwatch:HookScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
            bgClassSwatch:SetPoint("RIGHT", rgn._lastInline or rgn._control, "LEFT", -8, 0)
            rgn._lastInline = bgClassSwatch

            local bgSwatch = EllesmereUI.BuildColorSwatch(
                rgn, row:GetFrameLevel() + 3,
                function()
                    local c = SGet("customBgColor")
                    if c then return c.r, c.g, c.b, 1 end
                    return 17/255, 17/255, 17/255, 1
                end,
                function(r, g, b)
                    SWrite("customBgColor", { r=r, g=g, b=b })
                    ReloadAndUpdate()
                end, false, 20)
            bgSwatch._eabOrigClick = bgSwatch:GetScript("OnClick")
            bgSwatch:SetScript("OnClick", function(self)
                if SVal("bgClassColored", false) then
                    SSet("bgClassColored", false)
                    ReloadAndUpdate(); EllesmereUI:RefreshPage()
                    return
                end
                if self._eabOrigClick then self._eabOrigClick(self) end
            end)
            bgSwatch:HookScript("OnEnter", function() EllesmereUI.ShowWidgetTooltip(bgSwatch, "Custom Background Color") end)
            bgSwatch:HookScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
            bgSwatch:SetPoint("RIGHT", rgn._lastInline or rgn._control, "LEFT", -8, 0)
            rgn._lastInline = bgSwatch
            -- Blocking overlay spans BOTH swatches: Dark Mode has no background.
            local bgBlock = CreateFrame("Frame", nil, rgn)
            bgBlock:SetPoint("TOPLEFT", bgSwatch, "TOPLEFT", 0, 0)
            bgBlock:SetPoint("BOTTOMRIGHT", bgClassSwatch, "BOTTOMRIGHT", 0, 0)
            bgBlock:SetFrameLevel(bgClassSwatch:GetFrameLevel() + 10)
            bgBlock:EnableMouse(true)
            bgBlock:SetScript("OnEnter", function() EllesmereUI.ShowWidgetTooltip(bgSwatch, "Not available in Dark Mode. Dark Mode colors can be adjusted in Global Settings -> Fonts & Colors.") end)
            bgBlock:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
            local function UpdateBgSwatchVis()
                if SVal("healthColorMode", "class") == "dark" then
                    bgSwatch:SetAlpha(0.3); bgClassSwatch:SetAlpha(0.3); bgBlock:Show()
                else
                    bgBlock:Hide()
                    local classOn = SVal("bgClassColored", false)
                    bgSwatch:SetAlpha(classOn and 0.3 or 1)
                    bgClassSwatch:SetAlpha(classOn and 1 or 0.3)
                end
            end
            EllesmereUI.RegisterWidgetRefresh(UpdateBgSwatchVis)
            UpdateBgSwatchVis()
        end

        ns._editTargets = ns._editTargets or {}

        local healPredRow
        healPredRow, h = W:DualRow(parent, y,
            { type="toggle", text="Heal Prediction",
              getValue=function() return SVal("healPrediction", false) end,
              setValue=function(v) SSet("healPrediction", v); EllesmereUI:RefreshPage() end },
            { type="slider", text="Prediction Opacity", min=5, max=100, step=1,
              disabled=function() return not SVal("healPrediction", false) end,
              disabledTooltip="Heal Prediction",
              getValue=function() return SVal("healPredOpacity", 75) end,
              setValue=function(v) SSet("healPredOpacity", v) end });  y = y - h
        ns._editTargets.healPrediction = healPredRow
        if not EllesmereUI._prebuilding then
            local rgn = healPredRow._leftRegion
            local swatch = EllesmereUI.BuildColorSwatch(
                rgn, healPredRow:GetFrameLevel() + 3,
                function()
                    local c = SGet("healPredColor")
                    if c then return c.r, c.g, c.b, 1 end
                    return 102/255, 243/255, 102/255, 1
                end,
                function(r, g, b)
                    SWrite("healPredColor", { r=r, g=g, b=b })
                    ReloadAndUpdate()
                end, false, 20)
            swatch:SetPoint("RIGHT", rgn._lastInline or rgn._control, "LEFT", -8, 0)
            rgn._lastInline = swatch
            local function UpdateHealPredSwatchVis()
                swatch:SetAlpha(SVal("healPrediction", false) and 1 or 0.3)
            end
            EllesmereUI.RegisterWidgetRefresh(UpdateHealPredSwatchVis)
            UpdateHealPredSwatchVis()
        end

        -- Color Custom Borders (the Threat Borders and Dispel Border cogs) recolors the
        -- frame's own border, so it needs one to recolor: the EllesmereUI style, a Border
        -- Style other than Solid and a Border Size above 0 (runtime twin:
        -- ns.RF_CustomBorderOn). Cog rows re-check this on every open.
        local function CustomBorderOff()
            if ns.RF_Stock and ns.RF_Stock() then return true end
            local tex = SGet("borderTexture")
            return tex == nil or tex == "" or tex == "solid" or SVal("borderSize", 1) <= 0
        end
        local function CustomBorderOffTip()
            if ns.RF_Stock and ns.RF_Stock() then
                return EllesmereUI.BlizzStyle and EllesmereUI.BlizzStyle.Label("raidframes")
            end
            local tex = SGet("borderTexture")
            if tex == nil or tex == "" or tex == "solid" then
                return "This option requires a Border Style other than Solid."
            end
            return "This option requires a Border Size above 0."
        end

        local smoothThreatRow
        smoothThreatRow, h = W:DualRow(parent, y,
            { type="toggle", text="Smooth Health Bars",
              getValue=function() return SVal("smoothBars", true) end,
              setValue=function(v) SSet("smoothBars", v) end },
            { type="slider", text="Threat Borders", min=0, max=4, step=1,
              getValue=function() return SVal("threatBorderSize", 2) end,
              setValue=function(v) SSet("threatBorderSize", v) end });  y = y - h
        ns._editTargets.threat = smoothThreatRow
        ns._editTargets.animateBars = smoothThreatRow
        -- Cog on Threat Borders: Color Custom Borders recolors the frame's own border in
        -- the threat color on aggro, drawn instead of the inner border (the slider's
        -- size still applies whenever the recolor cannot).
        if not EllesmereUI._prebuilding then
            local rgn = smoothThreatRow._rightRegion
            -- Its only row needs a custom border: dimmed, with the reason, until there is one.
            EllesmereUI.BuildInlineCog(rgn, {
                disabled = CustomBorderOff, disabledTooltip = CustomBorderOffTip, requireState = "disabled",
                title = "Threat Borders",
                rows = {
                    { type="toggle", label="Color Custom Borders",
                      tooltip="Recolors the frame border in the threat color while the unit has aggro instead of drawing a separate border.",
                      disabled=CustomBorderOff,
                      disabledTooltip=CustomBorderOffTip,
                      requireState="disabled",
                      get=function() return SVal("threatCustomBorder", false) end,
                      set=function(v) SSet("threatCustomBorder", v) end },
                },
            })
        end

        -------------------------------------------------------------------
        --  ABSORBS
        --  Own party-sync section ("absorbs"); pre-split profiles inherit the
        --  Health Bar sync state via ns._NormalizePartySyncSections.
        -------------------------------------------------------------------
        local absorbsHeader
        if onSection then onSection("healthBar", _secY, y) end; _secY = y
        absorbsHeader, h = W:SectionHeader(parent, "ABSORBS", y); y = y - h

        -- Eyeball: toggle shield/heal-absorb effects on the preview frames.
        do
            local EYE_VISIBLE   = EllesmereUI.EYE_VISIBLE_ICON
            local EYE_INVISIBLE = EllesmereUI.EYE_INVISIBLE_ICON

            local abLabel
            for _, rgn in ipairs({ absorbsHeader:GetRegions() }) do
                if rgn.GetText and EllesmereUI.EnKey(rgn:GetText()) == "ABSORBS" then
                    abLabel = rgn; break
                end
            end
            local eyeBtn = CreateFrame("Button", nil, absorbsHeader)
            eyeBtn:SetSize(24, 24)
            if abLabel then
                eyeBtn:SetPoint("LEFT", abLabel, "RIGHT", 5, 0)
            else
                eyeBtn:SetPoint("LEFT", absorbsHeader, "BOTTOMLEFT", 85, 8)
            end
            eyeBtn:SetFrameLevel(absorbsHeader:GetFrameLevel() + 5)
            eyeBtn:SetAlpha(0.4)
            local eyeTex = eyeBtn:CreateTexture(nil, "OVERLAY")
            eyeTex:SetAllPoints()

            -- On ns so the preview renderer can read it.
            if ns._absorbsPreviewVisible == nil then ns._absorbsPreviewVisible = false end

            local function RefreshAbsorbEye()
                if IsPreviewOff() then
                    eyeTex:SetTexture(EYE_VISIBLE)
                    eyeBtn:SetAlpha(0.15)
                    return
                end
                eyeTex:SetTexture(ns._absorbsPreviewVisible and EYE_INVISIBLE or EYE_VISIBLE)
                eyeBtn:SetAlpha(0.4)
            end
            EYE.refreshAbsorbEye = RefreshAbsorbEye
            RefreshAbsorbEye()
            eyeBtn:SetScript("OnClick", function()
                if IsPreviewOff() then return end
                ns._absorbsPreviewVisible = not ns._absorbsPreviewVisible
                -- Indicators suppress bar effects, so clear them.
                if ns._absorbsPreviewVisible and ns._indicatorsVisible then
                    ns._indicatorsVisible = false
                    if EYE.refreshIndicatorEye then EYE.refreshIndicatorEye() end
                end
                RefreshAbsorbEye()
                if ns.PvRefresh then ns.PvRefresh() end
            end)
            eyeBtn:SetScript("OnEnter", function(self)
                if IsPreviewOff() then
                    EllesmereUI.ShowWidgetTooltip(self, "Enable preview to use")
                    return
                end
                self:SetAlpha(0.7)
                EllesmereUI.ShowWidgetTooltip(self, ns._absorbsPreviewVisible and "Hide shield effects on preview" or "Show shield effects on preview")
            end)
            eyeBtn:SetScript("OnLeave", function(self)
                if not IsPreviewOff() then self:SetAlpha(0.4) end
                EllesmereUI.HideWidgetTooltip()
            end)
        end  -- close do (absorbs eyeball)

        local absorbRow
        absorbRow, h = W:DualRow(parent, y,
            { type="dropdown", text="Absorb Style", values=absorbStyleValues, order=absorbStyleOrder,
              getValue=function() return SVal("absorbStyle", "none") end,
              setValue=function(v)
                  -- Blizzard Glow Line follows the pick: on with Default Blizz Frames, off when
                  -- leaving it, else kept. A set value is stored explicitly, so a party that
                  -- starts keeping its own style here keeps the line it showed; an unset one
                  -- stays unset and keeps following the style.
                  local was = SVal("absorbStyle", "none")
                  local glow = SGetPx("absorbGlowLine", "absorbStyle")
                  if v == "blizzardModern" then
                      glow = true
                  elseif was == "blizzardModern" then
                      glow = false
                  end
                  if glow ~= nil then SWrite("absorbGlowLine", glow == true) end
                  SSet("absorbStyle", v)
                  if v == "clean" then
                      SSet("absorbOpacity", 30)
                  elseif v ~= "blizzardModern" then
                      -- Blizzard (Modern) hardcodes color+opacity in the renderer; leave saved opacity untouched.
                      SSet("absorbOpacity", 90)
                  end
                  EllesmereUI:RefreshPage()
              end },
            { type="slider", text="Absorb Opacity", min=5, max=100, step=1,
              disabled=function()
                  local st = SVal("absorbStyle", "none")
                  return st == "none" or st == "blizzardModern"
              end,
              disabledTooltip="Absorb Style",
              getValue=function() return SVal("absorbOpacity", 90) end,
              setValue=function(v) SSet("absorbOpacity", v) end });  y = y - h
        ns._editTargets.absorbs = absorbRow
        if not EllesmereUI._prebuilding then
            local rgn = absorbRow._leftRegion
            local swatch = EllesmereUI.BuildColorSwatch(
                rgn, absorbRow:GetFrameLevel() + 3,
                function()
                    local c = SGet("absorbColor")
                    if c then return c.r, c.g, c.b, 1 end
                    return 1, 1, 1, 1
                end,
                function(r, g, b)
                    SWrite("absorbColor", { r=r, g=g, b=b })
                    ReloadAndUpdate()
                end, false, 20)
            swatch:SetPoint("RIGHT", rgn._lastInline or rgn._control, "LEFT", -8, 0)
            rgn._lastInline = swatch
            -- BuildColorSwatch has no disabled state, so a mouse-enabled frame on top eats clicks when the color isn't user-editable (no absorb, or hardcoded-color "Blizzard (Modern)").
            local swatchBlock = CreateFrame("Frame", nil, swatch)
            swatchBlock:SetAllPoints()
            swatchBlock:SetFrameLevel(swatch:GetFrameLevel() + 10)
            swatchBlock:EnableMouse(true)
            swatchBlock:Hide()
            local function UpdateAbsorbSwatchVis()
                local st = SVal("absorbStyle", "none")
                local off = (st == "none" or st == "blizzardModern")
                swatch:SetAlpha(off and 0.3 or 1)
                if off then swatchBlock:Show() else swatchBlock:Hide() end
            end
            EllesmereUI.RegisterWidgetRefresh(UpdateAbsorbSwatchVis)
            UpdateAbsorbSwatchVis()
        end
        -- Inline cog: absorb placement (overlay / right edge / left edge)
        do
            local rgn = absorbRow._leftRegion
            -- Placement labels follow the FILL AXIS: saved values stay right/left (meaning the FAR/NEAR end of the fill), worded top/bottom on a vertical bar.
            -- MUTATE IN PLACE, never rebuild this table: RefreshPage's fast path skips a full rebuild and the cog popup is built once then cached, so a fresh table would never reach the widget. The popup re-reads values[get()] every show; _invalidateMenu makes an already-built menu re-read entries from this same table on next click.
            local absorbEdgeLabels = { overlay = "Overlay", overlayReverse = "Overlay Reverse" }
            local absorbEdgeLabelsVert  -- last applied axis; nil until first sync
            -- (The Party Frames kit's bar always fills horizontally; decided at build.)
            local kitPage = ns.RF_OptPartyKit()
            -- Returns true ONLY when the axis flipped, so callers skip _invalidateMenu on unrelated refreshes -- it nils the cached menu and would break an open menu's wired click.
            local function SyncAbsorbEdgeLabels()
                local vert = (not kitPage) and SVal("healthVerticalFill", false) and true or false
                if absorbEdgeLabelsVert == vert then return false end
                absorbEdgeLabelsVert = vert
                absorbEdgeLabels.right = vert and "From Top Edge"    or "From Right Edge"
                absorbEdgeLabels.left  = vert and "From Bottom Edge" or "From Left Edge"
                return true
            end
            SyncAbsorbEdgeLabels()
            local _, cogShow = EllesmereUI.BuildInlineCog(rgn, {
                title = "Absorb Rendering",
                rows = {
                    { type="dropdown", label="Placement",
                      values = absorbEdgeLabels,
                      order = { "overlay", "overlayReverse", "right", "left" },
                      disabled = function() return SVal("absorbStyle", "none") == "blizzardModern" end,
                      disabledTooltip = "Default Blizz Frames uses a fixed placement",
                      rawTooltip = true,
                      get=function() SyncAbsorbEdgeLabels(); return SVal("absorbEdgeMode", "overlay") end,
                      set=function(v) SSet("absorbEdgeMode", v) end },
                    { type="dropdown", label="Show Overshield",
                      tooltip="Overshield is the part of an absorb exceeding your empty health. Always backfills it over current health from the shield's edge; From Left grows it from the opposite end of the bar; Never hides it.",
                      values = { never = "Never", always = "Always", fromleft = "From Left" },
                      order = { "never", "always", "fromleft" },
                      -- From Left only exists in the plain Overlay placement:
                      -- edge modes have no overshield and Overlay Reverse
                      -- already clamps the whole absorb inside the fill.
                      itemDisabled=function(v)
                          return v == "fromleft" and SVal("absorbEdgeMode", "overlay") ~= "overlay"
                      end,
                      get=function()
                          -- Legacy boolean fallback: profiles saved before the
                          -- dropdown keep their toggle's meaning.
                          local m = SVal("overshieldMode", nil)
                          if m == nil then m = (SVal("showOvershield", true) == false) and "never" or "always" end
                          return m
                      end,
                      set=function(v)
                          -- Mirror the legacy boolean so pre-dropdown readers
                          -- (incl. the live-client profile) track Never/Always.
                          SSet("showOvershield", v ~= "never")
                          SSet("overshieldMode", v)
                      end },
                    { type="toggle", label="Blizzard Glow Line",
                      tooltip="Adds the Default Blizz Frames glow line where the shield meets current health.",
                      disabled = function()
                          if (not kitPage) and SVal("healthVerticalFill", false) == true then return true end
                          return SVal("absorbEdgeMode", "overlay") == "left" and SVal("absorbStyle", "none") ~= "blizzardModern"
                      end,
                      disabledTooltip = "The glow line is not shown on a vertical fill or with the From Left Edge placement",
                      rawTooltip = true,
                      get=function()
                          -- Unset follows the style: on for Default Blizz Frames only.
                          local g = SGetPx("absorbGlowLine", "absorbStyle")
                          if g == nil then return SVal("absorbStyle", "none") == "blizzardModern" end
                          return g == true
                      end,
                      set=function(v) SSet("absorbGlowLine", v and true or false) end },
                },
            })
            -- Re-label on page refresh (Vertical Fill fires one) and drop any built menu so its entries rebuild with the new wording.
            EllesmereUI.RegisterWidgetRefresh(function()
                if not SyncAbsorbEdgeLabels() then return end
                local pf = cogShow and cogShow._popupFrame
                if pf and pf.GetChildren then
                    for _, child in ipairs({ pf:GetChildren() }) do
                        if child._invalidateMenu then child._invalidateMenu() end
                    end
                end
            end)
        end

        local function CurAbsorbBarPos()
            local p = SGet("absorbBarPosition")
            if p then return p end
            return SVal("absorbBarEnabled", false) and "aboveRight" or "none"
        end
        local absorbBarRow
        absorbBarRow, h = W:DualRow(parent, y,
            { type="dropdown", text="Absorb Bar",
              values={ none="None", aboveRight="Above Frame Right", aboveLeft="Above Frame Left", topRight="Top Right", topLeft="Top Left", rightVertical="Right Edge (Vertical)", leftVertical="Left Edge (Vertical)" },
              order={ "none", "aboveRight", "aboveLeft", "topRight", "topLeft", "rightVertical", "leftVertical" },
              getValue=function() return CurAbsorbBarPos() end,
              setValue=function(v)
                  SWrite("absorbBarEnabled", v ~= "none")  -- keep legacy flag in sync
                  SSet("absorbBarPosition", v)
                  EllesmereUI:RefreshPage()
              end },
            { type="slider", text="Bar Height", min=1, max=20, step=1,
              disabled=function() return CurAbsorbBarPos() == "none" end,
              disabledTooltip="Absorb Bar",
              getValue=function() return SVal("absorbBarHeight", 4) end,
              setValue=function(v) SSet("absorbBarHeight", v) end });  y = y - h
        if not EllesmereUI._prebuilding then
            local rgn = absorbBarRow._leftRegion
            EllesmereUI.BuildInlineCog(rgn, {
                -- Vertical Grow, its only setting, has no effect off the vertical positions.
                disabled = function()
                    local p = CurAbsorbBarPos()
                    return p ~= "rightVertical" and p ~= "leftVertical"
                end,
                disabledTooltip = "Only affects the vertical (Right/Left Edge) positions",
                rawTooltip = true,
                title = "Absorb Bar Rendering",
                rows = {
                    { type="dropdown", label="Vertical Grow",
                      values = { up = "Up", down = "Down" },
                      order = { "up", "down" },
                      disabled = function()
                          local p = CurAbsorbBarPos()
                          return p ~= "rightVertical" and p ~= "leftVertical"
                      end,
                      disabledTooltip = "Only affects the vertical (Right/Left Edge) positions",
                      rawTooltip = true,
                      get=function() return SVal("absorbBarGrowDir", "up") end,
                      set=function(v) SSet("absorbBarGrowDir", v) end },
                },
            })
        end
        -- The size slider reads as width for the vertical positions; retitle live.
        do
            local lbl = absorbBarRow._rightRegion._label
            local function UpdateAbsorbBarSizeLabel()
                local p = CurAbsorbBarPos()
                local vertical = p == "rightVertical" or p == "leftVertical"
                lbl:SetText(EllesmereUI.L(vertical and "Bar Width" or "Bar Height"))
            end
            EllesmereUI.RegisterWidgetRefresh(UpdateAbsorbBarSizeLabel)
            UpdateAbsorbBarSizeLabel()
        end
        if not EllesmereUI._prebuilding then
            local rgn = absorbBarRow._rightRegion
            local swatch = EllesmereUI.BuildColorSwatch(
                rgn, absorbBarRow:GetFrameLevel() + 3,
                function()
                    local c = SGet("absorbBarColor")
                    if c then return c.r, c.g, c.b, c.a or 1 end
                    return 1, 1, 1, 1
                end,
                function(r, g, b, a)
                    SWrite("absorbBarColor", { r=r, g=g, b=b, a=a })
                    ReloadAndUpdate()
                end, true, 20)
            swatch:SetPoint("RIGHT", rgn._lastInline or rgn._control, "LEFT", -8, 0)
            rgn._lastInline = swatch
            local function UpdateAbsorbBarSwatchVis()
                swatch:SetAlpha(CurAbsorbBarPos() ~= "none" and 1 or 0.3)
            end
            EllesmereUI.RegisterWidgetRefresh(UpdateAbsorbBarSwatchVis)
            UpdateAbsorbBarSwatchVis()
        end

        local healAbsorbRow
        healAbsorbRow, h = W:DualRow(parent, y,
            { type="dropdown", text="Heal Absorb Style", values=absorbStyleValues, order=healAbsorbStyleOrder,
              getValue=function() return SVal("healAbsorbStyle", "clean") end,
              setValue=function(v)
                  SSet("healAbsorbStyle", v)
                  if v == "clean" then
                      SSet("healAbsorbOpacity", 50)
                  else
                      SSet("healAbsorbOpacity", 75)
                  end
                  EllesmereUI:RefreshPage()
              end },
            { type="slider", text="Heal Absorb Opacity", min=5, max=100, step=1,
              disabled=function() return SVal("healAbsorbStyle", "clean") == "none" end,
              disabledTooltip="Heal Absorb Style",
              getValue=function() return SVal("healAbsorbOpacity", 75) end,
              setValue=function(v) SSet("healAbsorbOpacity", v) end });  y = y - h
        ns._editTargets.healAbsorbs = healAbsorbRow
        if not EllesmereUI._prebuilding then
            local rgn = healAbsorbRow._leftRegion
            local swatch = EllesmereUI.BuildColorSwatch(
                rgn, healAbsorbRow:GetFrameLevel() + 3,
                function()
                    local c = SGet("healAbsorbColor")
                    if c then return c.r or 0.8, c.g or 0.15, c.b or 0.15, 1 end
                    return 0.8, 0.15, 0.15, 1
                end,
                function(r, g, b)
                    SWrite("healAbsorbColor", { r=r, g=g, b=b })
                    ReloadAndUpdate()
                end, false, 20)
            swatch:SetPoint("RIGHT", rgn._lastInline or rgn._control, "LEFT", -8, 0)
            rgn._lastInline = swatch
            -- Blocked for "none" and the pre-colored heal styles (healBlizzModern is hardcoded white).
            local swatchBlock = CreateFrame("Frame", nil, swatch)
            swatchBlock:SetAllPoints()
            swatchBlock:SetFrameLevel(swatch:GetFrameLevel() + 10)
            swatchBlock:EnableMouse(true)
            swatchBlock:Hide()
            local function UpdateHealAbsorbSwatchVis()
                local st = SVal("healAbsorbStyle", "clean")
                local off = (st == "none" or st == "healBlizzModern" or st == "largeOutlinedStripes" or st == "largeOutlinedStripesR")
                swatch:SetAlpha(off and 0.3 or 1)
                if off then swatchBlock:Show() else swatchBlock:Hide() end
            end
            EllesmereUI.RegisterWidgetRefresh(UpdateHealAbsorbSwatchVis)
            UpdateHealAbsorbSwatchVis()
        end
        -- Inline cog: heal absorb placement (independent of shield absorb)
        do
            local rgn = healAbsorbRow._leftRegion
            -- Same axis-labelling contract as the shield absorb cog above (MUTATE IN PLACE; return true only on a real axis flip).
            local healAbsorbEdgeLabels = { overlay = "Overlay" }
            local healAbsorbEdgeLabelsVert  -- last applied axis; nil until first sync
            local kitPage = ns.RF_OptPartyKit()
            local function SyncHealAbsorbEdgeLabels()
                local vert = (not kitPage) and SVal("healthVerticalFill", false) and true or false
                if healAbsorbEdgeLabelsVert == vert then return false end
                healAbsorbEdgeLabelsVert = vert
                healAbsorbEdgeLabels.right = vert and "From Top Edge"    or "From Right Edge"
                healAbsorbEdgeLabels.left  = vert and "From Bottom Edge" or "From Left Edge"
                return true
            end
            SyncHealAbsorbEdgeLabels()
            local _, cogShow = EllesmereUI.BuildInlineCog(rgn, {
                title = "Heal Absorb Rendering",
                rows = {
                    { type="dropdown", label="Placement",
                      values = healAbsorbEdgeLabels,
                      order = { "overlay", "right", "left" },
                      get=function() SyncHealAbsorbEdgeLabels(); return SVal("healAbsorbEdgeMode", "overlay") end,
                      set=function(v) SSet("healAbsorbEdgeMode", v) end },
                    { type="slider", label="Backing Opacity", min=0, max=100, step=1,
                      get=function() return SVal("healAbsorbBgOpacity", 25) end,
                      set=function(v) SSet("healAbsorbBgOpacity", v) end },
                    { type="toggle", label="Show Over Dispels",
                      get=function() return SVal("healAbsorbOverDispel", false) == true end,
                      set=function(v) SSet("healAbsorbOverDispel", v) end },
                },
            })
            EllesmereUI.RegisterWidgetRefresh(function()
                if not SyncHealAbsorbEdgeLabels() then return end
                local pf = cogShow and cogShow._popupFrame
                if pf and pf.GetChildren then
                    for _, child in ipairs({ pf:GetChildren() }) do
                        if child._invalidateMenu then child._invalidateMenu() end
                    end
                end
            end)
        end

        do
            local function CurHealAbsorbBarPos()
                return SGet("healAbsorbBarPosition") or "none"
            end
            local healAbsorbBarRow
            healAbsorbBarRow, h = W:DualRow(parent, y,
                { type="dropdown", text="Heal Absorb Bar",
                  values={ none="None", belowAbsorb="Below Absorb Bar", aboveRight="Above Frame Right", aboveLeft="Above Frame Left", topRight="Top Right", topLeft="Top Left", rightVertical="Right Edge (Vertical)", leftVertical="Left Edge (Vertical)" },
                  order={ "none", "belowAbsorb", "aboveRight", "aboveLeft", "topRight", "topLeft", "rightVertical", "leftVertical" },
                  getValue=function() return CurHealAbsorbBarPos() end,
                  setValue=function(v) SSet("healAbsorbBarPosition", v); EllesmereUI:RefreshPage() end },
                { type="slider", text="Bar Height", min=1, max=20, step=1,
                  disabled=function() return CurHealAbsorbBarPos() == "none" end,
                  disabledTooltip="Heal Absorb Bar",
                  getValue=function() return SVal("healAbsorbBarHeight", 4) end,
                  setValue=function(v) SSet("healAbsorbBarHeight", v) end });  y = y - h
            if not EllesmereUI._prebuilding then
                local rgn = healAbsorbBarRow._rightRegion
                local swatch = EllesmereUI.BuildColorSwatch(
                    rgn, healAbsorbBarRow:GetFrameLevel() + 3,
                    function()
                        local c = SGet("healAbsorbBarColor")
                        if c then return c.r, c.g, c.b, c.a or 1 end
                        return 200/255, 29/255, 29/255, 1
                    end,
                    function(r, g, b, a)
                        SWrite("healAbsorbBarColor", { r=r, g=g, b=b, a=a })
                        ReloadAndUpdate()
                    end, true, 20)
                swatch:SetPoint("RIGHT", rgn._lastInline or rgn._control, "LEFT", -8, 0)
                rgn._lastInline = swatch
                local function UpdateHealAbsorbBarSwatchVis()
                    swatch:SetAlpha(CurHealAbsorbBarPos() ~= "none" and 1 or 0.3)
                end
                EllesmereUI.RegisterWidgetRefresh(UpdateHealAbsorbBarSwatchVis)
                UpdateHealAbsorbBarSwatchVis()
            end
            if not EllesmereUI._prebuilding then
                local rgn = healAbsorbBarRow._leftRegion
                EllesmereUI.BuildInlineCog(rgn, {
                    -- Vertical Grow is inert off the vertical positions.
                    disabled = function()
                        local p = CurHealAbsorbBarPos()
                        return p ~= "rightVertical" and p ~= "leftVertical"
                    end,
                    disabledTooltip = "Only affects the vertical (Right/Left Edge) positions",
                    rawTooltip = true,
                    title = "Heal Absorb Bar Rendering",
                    rows = {
                        { type="dropdown", label="Vertical Grow",
                          values = { up = "Up", down = "Down" },
                          order = { "up", "down" },
                          disabled = function()
                              local p = CurHealAbsorbBarPos()
                              return p ~= "rightVertical" and p ~= "leftVertical"
                          end,
                          disabledTooltip = "Only affects the vertical (Right/Left Edge) positions",
                          rawTooltip = true,
                          get=function() return SVal("healAbsorbBarGrowDir", "up") end,
                          set=function(v) SSet("healAbsorbBarGrowDir", v) end },
                    },
                })
            end
            -- The size slider reads as width for the vertical positions; retitle live.
            do
                local lbl = healAbsorbBarRow._rightRegion._label
                local function UpdateHealAbsorbBarSizeLabel()
                    local p = CurHealAbsorbBarPos()
                    local vertical = p == "rightVertical" or p == "leftVertical"
                    lbl:SetText(EllesmereUI.L(vertical and "Bar Width" or "Bar Height"))
                end
                EllesmereUI.RegisterWidgetRefresh(UpdateHealAbsorbBarSizeLabel)
                UpdateHealAbsorbBarSizeLabel()
            end
        end

        -- Max Health Texture (+swatch+cog) | Max Health Opacity. Styles mirror Heal Absorb plus "Max Health Stripes" first; no placement control, overlay is always right-anchored.
        do
            local maxHealthRow
            maxHealthRow, h = W:DualRow(parent, y,
                { type="dropdown", text="Max Health Style", values=absorbStyleValues,
                  order=maxHealthStyleOrder,
                  getValue=function() return SVal("maxHealthStyle", "maxHealthStripes") end,
                  setValue=function(v) SSet("maxHealthStyle", v); EllesmereUI:RefreshPage() end },
                { type="slider", text="Max Health Opacity", min=5, max=100, step=1,
                  disabled=function() return SVal("maxHealthStyle", "maxHealthStripes") == "none" end,
                  disabledTooltip="Max Health Style",
                  getValue=function() return SVal("maxHealthOpacity", 100) end,
                  setValue=function(v) SSet("maxHealthOpacity", v) end });  y = y - h
            -- Swatch tints the max health texture.
            if not EllesmereUI._prebuilding then
                local rgn = maxHealthRow._leftRegion
                local swatch = EllesmereUI.BuildColorSwatch(
                    rgn, maxHealthRow:GetFrameLevel() + 3,
                    function()
                        local c = SGet("maxHealthColor")
                        if c then return c.r or 0.7, c.g or 0.1, c.b or 0.1, 1 end
                        return 0.7, 0.1, 0.1, 1
                    end,
                    function(r, g, b)
                        SWrite("maxHealthColor", { r=r, g=g, b=b })
                        ReloadAndUpdate()
                    end, false, 20)
                swatch:SetPoint("RIGHT", rgn._lastInline or rgn._control, "LEFT", -8, 0)
                rgn._lastInline = swatch
                -- Blocked for "none" and the pre-colored styles.
                local swatchBlock = CreateFrame("Frame", nil, swatch)
                swatchBlock:SetAllPoints()
                swatchBlock:SetFrameLevel(swatch:GetFrameLevel() + 10)
                swatchBlock:EnableMouse(true)
                swatchBlock:Hide()
                local function UpdateMaxHealthSwatchVis()
                    local st = SVal("maxHealthStyle", "maxHealthStripes")
                    local off = (st == "none" or st == "healBlizzModern" or st == "largeOutlinedStripes" or st == "largeOutlinedStripesR")
                    swatch:SetAlpha(off and 0.3 or 1)
                    if off then swatchBlock:Show() else swatchBlock:Hide() end
                end
                EllesmereUI.RegisterWidgetRefresh(UpdateMaxHealthSwatchVis)
                UpdateMaxHealthSwatchVis()
            end
            -- Cog carries backing opacity only; placement is fixed right-side.
            if not EllesmereUI._prebuilding then
                local rgn = maxHealthRow._leftRegion
                EllesmereUI.BuildInlineCog(rgn, {
                    title = "Max Health Rendering",
                    rows = {
                        { type="slider", label="Backing Opacity", min=0, max=100, step=1,
                          get=function() return SVal("maxHealthBgOpacity", 100) end,
                          set=function(v) SSet("maxHealthBgOpacity", v) end },
                    },
                })
            end
        end

        -------------------------------------------------------------------
        --  POWER BAR
        -------------------------------------------------------------------
        local powerHeader
        if onSection then onSection("absorbs", _secY, y) end; _secY = y
        powerHeader, h = W:SectionHeader(parent, "POWER BAR", y); y = y - h

        -- Power bar animation: same pattern as health, serves raid + party.
        do
            local EYE_VISIBLE   = EllesmereUI.EYE_VISIBLE_ICON
            local EYE_INVISIBLE = EllesmereUI.EYE_INVISIBLE_ICON
            -- On ns: single ticker, resolves the active preview at call time.
            ns._powerAnimState = ns._powerAnimState or {}

            local function StopPowerAnim()
                if ns._powerAnimTicker then
                    ns._powerAnimTicker:Cancel()
                    ns._powerAnimTicker = nil
                end
                ns._powerAnimActive = false
                local ppv = ns.PvPowerValues()
                if ppv then
                    for i, st in ipairs(ns._powerAnimState) do
                        ppv[i] = st.current
                    end
                end
            end
            -- Exposed for onModuleLeave below.
            ns.StopPowerAnim = StopPowerAnim

            local function StartPowerAnim()
                if ns._powerAnimTicker then return end
                ns._powerAnimActive = true
                wipe(ns._powerAnimState)

                local frames = ns.PvActiveFrames()
                for i = 1, 20 do
                    local f = frames[i]
                    if f and f._power and f._power:IsShown() then
                        local cur = f._powerPct or (50 + math.random(50))
                        ns._powerAnimState[i] = {
                            frame = f,
                            current = cur,
                            target = math.max(10, math.min(100, cur + math.random(-8, 8))),
                            snapTimer = math.random() * 3,
                            nextSnap = 1.8 + math.random() * 2.3,
                        }
                    end
                end

                local pwSmoothInterp = Enum and Enum.StatusBarInterpolation
                    and Enum.StatusBarInterpolation.ExponentialEaseOut
                ns._powerAnimTicker = C_Timer.NewTicker(0.1, function()
                    if not ns._powerAnimActive then return end
                    -- Effective overlay; see the health ticker note above.
                    local smooth = ((ns.PvEffectiveProfile and ns.PvEffectiveProfile())
                        or db.profile).smoothPowerBars

                    for i, st in pairs(ns._powerAnimState) do
                        local f = st.frame
                        if f and f._power then
                            st.snapTimer = st.snapTimer + 0.1
                            if st.snapTimer < st.nextSnap then
                            else
                                st.snapTimer = 0
                                st.nextSnap = 2.5 + math.random() * 3
                                st.current = st.target
                                st.target = math.max(10, math.min(100, st.current + math.random(-8, 8)))

                                if smooth and pwSmoothInterp then
                                    f._power:SetValue(st.current, pwSmoothInterp)
                                else
                                    f._power:SetValue(st.current)
                                end
                                -- Power Text follows the animated value (ApplyPreviewData sets f._pwtMode; nil = hidden).
                                if f._pwtMode then ns.RF_PowerTextInto(f._powerText, f._pwtMode, st.current, nil, nil, f._pwtPer) end
                            end
                        end
                    end
                end)
            end

            local pwLabel
            for _, rgn in ipairs({ powerHeader:GetRegions() }) do
                if rgn.GetText and EllesmereUI.EnKey(rgn:GetText()) == "POWER BAR" then
                    pwLabel = rgn; break
                end
            end
            local eyeBtn = CreateFrame("Button", nil, powerHeader)
            eyeBtn:SetSize(24, 24)
            if pwLabel then
                eyeBtn:SetPoint("LEFT", pwLabel, "RIGHT", 5, 0)
            else
                eyeBtn:SetPoint("LEFT", powerHeader, "BOTTOMLEFT", 85, 8)
            end
            eyeBtn:SetFrameLevel(powerHeader:GetFrameLevel() + 5)
            eyeBtn:SetAlpha(0.4)
            local eyeTex = eyeBtn:CreateTexture(nil, "OVERLAY")
            eyeTex:SetAllPoints()
            local function RefreshPowerEye()
                if IsPreviewOff() then
                    eyeTex:SetTexture(EYE_VISIBLE)
                    eyeBtn:SetAlpha(0.15)
                    return
                end
                eyeTex:SetTexture(ns._powerAnimActive and EYE_INVISIBLE or EYE_VISIBLE)
                eyeBtn:SetAlpha(0.4)
            end
            EYE.refreshPowerEye = RefreshPowerEye
            ns._stopPowerAnim = StopPowerAnim
            RefreshPowerEye()
            eyeBtn:SetScript("OnClick", function()
                if IsPreviewOff() then return end
                if ns._powerAnimActive then
                    StopPowerAnim()
                else
                    if ns._indicatorsVisible then
                        ns._indicatorsVisible = false
                        if EYE.refreshIndicatorEye then EYE.refreshIndicatorEye() end
                    end
                    StartPowerAnim()
                end
                RefreshPowerEye()
            end)
            eyeBtn:SetScript("OnEnter", function(self)
                if IsPreviewOff() then
                    EllesmereUI.ShowWidgetTooltip(self, "Enable preview to use")
                    return
                end
                self:SetAlpha(0.7)
                EllesmereUI.ShowWidgetTooltip(self, ns._powerAnimActive and "Stop power animation" or "Animate power bars")
            end)
            eyeBtn:SetScript("OnLeave", function(self)
                if not IsPreviewOff() then self:SetAlpha(0.4) end
                EllesmereUI.HideWidgetTooltip()
            end)

            EllesmereUI:RegisterOnHide(function()
                if ns._powerAnimActive then StopPowerAnim(); RefreshPowerEye() end
            end)
        end  -- close do (power eyeball)

        -- Power bar is off when no role is selected.
        -- The Party Frames kit's mana bar always shows. Decided at build time:
        -- the page being built is only known then, and this runs on refreshes.
        local IsPowerOff = ns.RF_OptPartyKit() and function() return false end or function()
            return not SVal("powerShowForHealer", true) and not SVal("powerShowForTank", true) and not SVal("powerShowForDPS", false)
        end

        do
            local showForItems = {
                { key = "healer", label = "Healers" },
                { key = "tank",   label = "Tanks" },
                { key = "dps",    label = "DPS" },
            }
            local showForKeyMap = { healer = "powerShowForHealer", tank = "powerShowForTank", dps = "powerShowForDPS" }
            -- Party Frames kit: the stock mana bar always shows at the stock
            -- size, so this row (and its cog) hides on the Party page.
            row, h = W:DualRow(parent, y,
                ns.RF_PartyKitGate({ type="dropdown", text="Show Power Bar For",
                  values={ __placeholder = "Healers, Tanks" }, order={ "__placeholder" },
                  getValue=function() return "__placeholder" end,
                  setValue=function() end }),
                ns.RF_PartyKitGate({ type="slider", text="Power Height", min=1, max=20, step=1,
                  disabled=function() return IsPowerOff() end,
                  disabledTooltip="Show Power Bar For",
                  getValue=function() return SVal("powerHeight", 4) end,
                  setValue=function(v) SSet("powerHeight", v) end }));  y = y - h
            -- Cog: uniform icon anchoring. Greyed + blocked while no role shows a power bar (nothing to ignore then).
            do
                local rgn = row._rightRegion
                EllesmereUI.BuildInlineCog(rgn, {
                    disabled = IsPowerOff, disabledTooltip = "Show Power Bar For",
                    title = "Power Height",
                    rows = {
                        { type="toggle", label="Icons Ignore Power Bar",
                          tooltip="Anchor icons and text as if no power bar existed, so frames with and without one line up identically.",
                          get=function() return SVal("powerUniformAnchors", false) end,
                          set=function(v) SSet("powerUniformAnchors", v) end },
                        { type="toggle", label="Extend Health Bar Behind Power",
                          tooltip="Health bar spans the full frame height and the power bar draws on top of it.",
                          get=function() return SVal("extendHealthBehindPower", false) end,
                          set=function(v) SSet("extendHealthBehindPower", v) end },
                    },
                })
            end
            if not EllesmereUI._prebuilding then
                local rgn = row._leftRegion
                if rgn._control then rgn._control:Hide() end
                local cbDD = EllesmereUI.BuildVisOptsCBDropdown(
                    rgn, 170, rgn:GetFrameLevel() + 2,
                    showForItems,
                    function(k) return SVal(showForKeyMap[k], true) end,
                    function(k, v)
                        SSet(showForKeyMap[k], v)
                        if ns.UpdatePowerEventRegistration then ns.UpdatePowerEventRegistration() end
                        EllesmereUI:RefreshPage()
                    end)
                PP.Point(cbDD, "RIGHT", rgn, "RIGHT", -20, 0)
                rgn._control = cbDD
                rgn._lastInline = nil
            end
        end

        local pwBorderStyleValues = {
            eui     = "EllesmereUI",
            divider = "Divider",
            border  = "Border",
        }
        local pwBorderStyleOrder = { "eui", "divider", "border" }
        -- Classic WoW UI draws the stock health/power divider in place of the
        -- power border (Blizzard Style has none, so the row stays there).
        local function PwClassicGate(cfg)
            if EllesmereUI.BlizzStyle and EllesmereUI.BlizzStyle.Active("raidframes") == "classic" then
                return EllesmereUI.BlizzStyle.Gate("raidframes", cfg)
            end
            return cfg
        end
        local pwBdrRow
        pwBdrRow, h = W:DualRow(parent, y,
            ns.RF_PartyKitGate(PwClassicGate({ type="dropdown", text="Border Style", values=pwBorderStyleValues, order=pwBorderStyleOrder,
              disabled=function() return IsPowerOff() end,
              disabledTooltip="Show Power Bar For",
              getValue=function() return SVal("powerBorderStyle", "divider") end,
              setValue=function(v) SSet("powerBorderStyle", v); EllesmereUI:RefreshPage() end })),
            ns.RF_PartyKitGate(PwClassicGate({ type="slider", text="Border Size", min=0, max=4, step=1,
              disabled=function() return IsPowerOff() or SVal("powerBorderStyle", "eui") == "eui" end,
              disabledTooltip="Show Power Bar For",
              getValue=function() return SVal("powerBorderSize", 1) end,
              setValue=function(v) SSet("powerBorderSize", v) end })));  y = y - h
        if not EllesmereUI._prebuilding then
            local rgn = pwBdrRow._rightRegion
            local swatch, updateSwatch = EllesmereUI.BuildColorSwatch(
                rgn, pwBdrRow:GetFrameLevel() + 3,
                function()
                    local c = SGet("powerBorderColor")
                    if c then return c.r, c.g, c.b, SVal("powerBorderAlpha", 1) end
                    return 0, 0, 0, 1
                end,
                function(r, g, b, a)
                    SWrite("powerBorderColor", { r=r, g=g, b=b })
                    SWrite("powerBorderAlpha", a)
                    ReloadAndUpdate()
                end, true, 20)
            swatch:SetPoint("RIGHT", rgn._lastInline or rgn._control, "LEFT", -8, 0)
            rgn._lastInline = swatch
            local block = CreateFrame("Frame", nil, swatch)
            block:SetAllPoints(); block:SetFrameLevel(swatch:GetFrameLevel() + 10); block:EnableMouse(true)
            block:SetScript("OnEnter", function() EllesmereUI.ShowWidgetTooltip(swatch, EllesmereUI.DisabledTooltip("Border Style")) end)
            block:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
            local function UpdatePwBdrSwatchState()
                local off = IsPowerOff() or SVal("powerBorderSize", 1) == 0 or SVal("powerBorderStyle", "eui") == "eui"
                if off then swatch:SetAlpha(0.3); block:Show() else swatch:SetAlpha(1); block:Hide() end
            end
            EllesmereUI.RegisterWidgetRefresh(function() if updateSwatch then updateSwatch() end; UpdatePwBdrSwatchState() end)
            UpdatePwBdrSwatchState()
        end

        local pwBgRow
        pwBgRow, h = W:DualRow(parent, y,
            { type="toggle", text="Smooth Power Bars",
              disabled=function() return IsPowerOff() end,
              disabledTooltip="Show Power Bar For",
              getValue=function() return SVal("smoothPowerBars", true) end,
              setValue=function(v) SSet("smoothPowerBars", v) end },
            { type="slider", text="Background", min=0, max=100, step=1,
              disabled=function() return IsPowerOff() end,
              disabledTooltip="Show Power Bar For",
              getValue=function() return SVal("powerBgDarkness", 70) end,
              setValue=function(v) SSet("powerBgDarkness", v) end });  y = y - h
        -- Power bg Custom + Power Colored swatch pair: clicking either toggles powerBgPowerColored, the inactive one dims (mirrors the health bg).
        do
            local rgn = pwBgRow._rightRegion
            -- Power swatch shows the player's power color and is not editable.
            local bgPwrSwatch = EllesmereUI.BuildColorSwatch(
                rgn, pwBgRow:GetFrameLevel() + 3,
                function()
                    local _, pToken = UnitPowerType("player")
                    local info = EllesmereUI.GetPowerColor(pToken or "MANA")
                    local f = EllesmereUI.GetPowerBgDarkenFactor()
                    if info then return info.r * f, info.g * f, info.b * f, 1 end
                    return 0, 0.5 * f, f, 1
                end,
                function() end, false, 20)
            bgPwrSwatch:SetScript("OnClick", function()
                SSet("powerBgPowerColored", true)
                EllesmereUI:RefreshPage()
            end)
            bgPwrSwatch:HookScript("OnEnter", function() EllesmereUI.ShowWidgetTooltip(bgPwrSwatch, "Power Colored Background. Power colors can be adjusted in Global Settings -> Fonts & Colors.") end)
            bgPwrSwatch:HookScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
            bgPwrSwatch:SetPoint("RIGHT", rgn._lastInline or rgn._control, "LEFT", -8, 0)
            rgn._lastInline = bgPwrSwatch

            local bgSwatch = EllesmereUI.BuildColorSwatch(
                rgn, pwBgRow:GetFrameLevel() + 3,
                function()
                    local c = SGet("powerBgColor")
                    if c then return c.r, c.g, c.b, 1 end
                    return 0, 0, 0, 1
                end,
                function(r, g, b)
                    SWrite("powerBgColor", { r=r, g=g, b=b })
                    ReloadAndUpdate()
                end, false, 20)
            bgSwatch._eabOrigClick = bgSwatch:GetScript("OnClick")
            bgSwatch:SetScript("OnClick", function(self)
                if SVal("powerBgPowerColored", false) then
                    SSet("powerBgPowerColored", false)
                    EllesmereUI:RefreshPage()
                    return
                end
                if self._eabOrigClick then self._eabOrigClick(self) end
            end)
            bgSwatch:HookScript("OnEnter", function() EllesmereUI.ShowWidgetTooltip(bgSwatch, "Custom Colored Background") end)
            bgSwatch:HookScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
            bgSwatch:SetPoint("RIGHT", rgn._lastInline or rgn._control, "LEFT", -8, 0)
            rgn._lastInline = bgSwatch

            local function UpdatePwBgSwatchVis()
                local pwrOn = SVal("powerBgPowerColored", false)
                bgSwatch:SetAlpha(pwrOn and 0.3 or 1)
                bgPwrSwatch:SetAlpha(pwrOn and 1 or 0.3)
            end
            EllesmereUI.RegisterWidgetRefresh(UpdatePwBgSwatchVis)
            UpdatePwBgSwatchVis()
        end

        -------------------------------------------------------------------
        --  TEXT DISPLAY
        -------------------------------------------------------------------
        if onSection then onSection("powerBar", _secY, y) end; _secY = y
        _, h = W:SectionHeader(parent, "TEXT DISPLAY", y); y = y - h

        row, h = W:DualRow(parent, y,
            { type="slider", text="Name Size", min=6, max=26, step=1,
              getValue=function() return SVal("nameSize", 10) end,
              setValue=function(v) SSet("nameSize", v) end },
            { type="multiSwatch", text="Name Color",
              swatches = {
                { tooltip = "Custom Color",
                  hasAlpha = false,
                  getValue = function()
                      local c = SGet("nameCustomColor")
                      if c then return c.r, c.g, c.b end
                      return 1, 1, 1
                  end,
                  setValue = function(r, g, b)
                      SWrite("nameCustomColor", { r=r, g=g, b=b })
                      ReloadAndUpdate()
                  end,
                  onClick = function(self)
                      if SVal("nameColorMode", "class") ~= "custom" then
                          SSet("nameColorMode", "custom")
                          EllesmereUI:RefreshPage()
                          return
                      end
                      if self._eabOrigClick then self._eabOrigClick(self) end
                  end,
                  refreshAlpha = function()
                      return SVal("nameColorMode", "class") == "custom" and 1 or 0.3
                  end },
                { tooltip = "Class Color",
                  hasAlpha = false,
                  getValue = function()
                      local _, ct = UnitClass("player")
                      if ct and RAID_CLASS_COLORS[ct] then
                          local cc = RAID_CLASS_COLORS[ct]
                          return cc.r, cc.g, cc.b
                      end
                      return 1, 1, 1
                  end,
                  setValue = function() end,
                  onClick = function()
                      SSet("nameColorMode", "class")
                      EllesmereUI:RefreshPage()
                  end,
                  refreshAlpha = function()
                      return SVal("nameColorMode", "class") == "class" and 1 or 0.3
                  end },
                { tooltip = "Accent Color",
                  hasAlpha = false,
                  getValue = function()
                      return EllesmereUI.ResolveActiveAccent()
                  end,
                  setValue = function() end,
                  onClick = function()
                      SSet("nameColorMode", "accent")
                      EllesmereUI:RefreshPage()
                  end,
                  refreshAlpha = function()
                      return SVal("nameColorMode", "class") == "accent" and 1 or 0.3
                  end },
              } });  y = y - h
        -- Name char cap + text stacking cog, on the Name Size slider. WoW Forever
        -- heads it with Name Format (the character name's first or last word; First
        -- and Last is the default). "full" is stored, not nil: a party section's nil
        -- would fall through to the raid value.
        do
            local rgn = row._leftRegion
            local nameRows = {
                { type="slider", label="Max Characters (0=off)", min=0, max=30, step=1,
                  get=function() return SVal("nameMaxLength", 15) end,
                  set=function(v) SSet("nameMaxLength", v) end },
                { type="toggle", label="Show Above Icons",
                  tooltip="Render the name and health text above buff and debuff icons.",
                  get=function() return SVal("nameTextAboveIcons", false) end,
                  set=function(v) SSet("nameTextAboveIcons", v) end },
            }
            if EllesmereUI.IS_FOREVER then
                table.insert(nameRows, 1, { type="dropdown", label="Name Format",
                    values={ first = "First Name", last = "Last Name", full = "First and Last" },
                    order={ "first", "last", "full" },
                    get=function() return SVal("nameFormat", "full") end,
                    set=function(v) SSet("nameFormat", v) end })
            end
            EllesmereUI.BuildInlineCog(rgn, {
                title = "Name Text",
                rows = nameRows,
            })
        end

        -- Party Frames kit: the name has the stock spot (its offsets stay on
        -- the cog), so the dropdown only chooses shown or None.
        row, h = W:DualRow(parent, y,
            ns.RF_OptPartyKit() and { type="dropdown", text="Name Position",
              values={ kit = "Party Frame", none = "None" }, order={ "kit", "none" },
              getValue=function() return (SVal("namePosition", "center") == "none") and "none" or "kit" end,
              setValue=function(v)
                  if v == "none" then SSet("namePosition", "none")
                  elseif SVal("namePosition", "center") == "none" then SSet("namePosition", "topleft") end
              end }
            or { type="dropdown", text="Name Position", values=namePositionValuesName, order=namePositionOrderName,
              getValue=function() return SVal("namePosition", "center") end,
              setValue=function(v) SSet("namePosition", v) end },
            { type="dropdown", text="Health Text", values=healthTextValues, order=healthTextOrder,
              getValue=function() return SVal("healthTextMode", "none") end,
              -- Rebuilds the page on the None <-> not-None flip so the Position/Size row below appears/vanishes.
              setValue=EllesmereUI.DependentSetValue(
                  function() return SVal("healthTextMode", "none") ~= "none" end,
                  function(v) SSet("healthTextMode", v) end) });  y = y - h
        do
            local rgn = row._leftRegion
            EllesmereUI.BuildInlineCog(rgn, {
                icon = EllesmereUI.DIRECTIONS_ICON,
                title = "Name Offset",
                rows = {
                    { type="slider", label="Offset X", min=-500, max=500, step=1,
                      get=function() return SVal("nameOffsetX", 0) end,
                      set=function(v) SSet("nameOffsetX", v) end },
                    { type="slider", label="Offset Y", min=-500, max=500, step=1,
                      get=function() return SVal("nameOffsetY", 0) end,
                      set=function(v) SSet("nameOffsetY", v) end },
                },
            })
        end
        -- Health Text color swatches (custom/class/accent), mirroring the Name Color triple. Custom is added FIRST so the _lastInline chain places it next to the dropdown, matching Name Color.
        if not EllesmereUI._prebuilding then
            local rgn = row._rightRegion
            local function AddHTSwatch(getColor, setColor, mode, opensPicker, tooltip)
                local sw = EllesmereUI.BuildColorSwatch(
                    rgn, row:GetFrameLevel() + 3, getColor, setColor, false, 20)
                sw:SetPoint("RIGHT", rgn._lastInline or rgn._control, "LEFT", -8, 0)
                rgn._lastInline = sw
                -- Preserve the picker-opening click, then switch mode on click (same technique multiSwatch uses for Name Color).
                sw._eabOrigClick = sw:GetScript("OnClick")
                sw:SetScript("OnClick", function(self)
                    if SVal("healthTextColorMode", "custom") ~= mode then
                        SSet("healthTextColorMode", mode)
                        EllesmereUI:RefreshPage()
                        return
                    end
                    if opensPicker and self._eabOrigClick then self._eabOrigClick(self) end
                end)
                -- HookScript so BuildColorSwatch's own hover stays intact.
                if tooltip then
                    sw:HookScript("OnEnter", function() EllesmereUI.ShowWidgetTooltip(sw, tooltip) end)
                    sw:HookScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
                end
                local function vis()
                    sw:SetAlpha(SVal("healthTextColorMode", "custom") == mode and 1 or 0.3)
                end
                EllesmereUI.RegisterWidgetRefresh(vis)
                vis()
            end
            -- Custom (rightmost): editable, opens the picker when active.
            AddHTSwatch(
                function()
                    local c = SGet("healthTextCustomColor")
                    if c then return c.r, c.g, c.b, 1 end
                    return 1, 1, 1, 1
                end,
                function(r, g, b)
                    SWrite("healthTextCustomColor", { r=r, g=g, b=b })
                    ReloadAndUpdate()
                end, "custom", true, "Custom Color")
            AddHTSwatch(
                function()
                    local _, ct = UnitClass("player")
                    if ct and RAID_CLASS_COLORS[ct] then
                        local cc = RAID_CLASS_COLORS[ct]
                        return cc.r, cc.g, cc.b, 1
                    end
                    return 1, 1, 1, 1
                end,
                function() end, "class", false, "Class Color")
            -- Accent (leftmost).
            AddHTSwatch(
                function()
                    local r, g, b = EllesmereUI.ResolveActiveAccent()
                    return r or 1, g or 1, b or 1, 1
                end,
                function() end, "accent", false, "Accent Color")
        end

        -- Health Text Position (+ cog for X/Y) | Health Text Size. Hidden entirely while Health Text is None.
        if SVal("healthTextMode", "none") ~= "none" then
        row, h = W:DualRow(parent, y,
            { type="dropdown", text="Health Text Position", values=namePositionValues, order=namePositionOrder,
              getValue=function() return SVal("healthTextPosition", "center") end,
              setValue=function(v) SSet("healthTextPosition", v) end },
            { type="slider", text="Health Text Size", min=6, max=26, step=1,
              getValue=function() return SVal("healthTextSize", 9) end,
              setValue=function(v) SSet("healthTextSize", v) end });  y = y - h
        do
            local rgn = row._leftRegion
            EllesmereUI.BuildInlineCog(rgn, {
                icon = EllesmereUI.DIRECTIONS_ICON,
                title = "Health Text Offset",
                rows = {
                    { type="slider", label="Offset X", min=-150, max=150, step=1,
                      get=function() return SVal("healthTextOffsetX", 0) end,
                      set=function(v) SSet("healthTextOffsetX", v) end },
                    { type="slider", label="Offset Y", min=-75, max=75, step=1,
                      get=function() return SVal("healthTextOffsetY", 0) end,
                      set=function(v) SSet("healthTextOffsetY", v) end },
                },
            })
        end
        end   -- close Health Text dependent-row gate

        -- Level Position (+ offset cog) | Level Size: the unit's level in front of the name inside
        -- the name text ("Attach to Name", the WoW Forever default, None on retail: "60 Name"; "(Divider)": "60 | Name"; both
        -- follow the Name Size), or in the name's colour on its own spot. None = off.
        do
            local levelPosValues = { name = "Attach to Name", nameDiv = "Attach to Name (Divider)" }
            for k, v in pairs(namePositionValuesName) do levelPosValues[k] = v end
            local levelPosOrder = { "name", "nameDiv", "topleft", "top", "topright", "left", "center",
                "right", "bottomleft", "bottom", "bottomright", "none" }
            local function LvlPos() return SVal("levelTextPosition", ns.RF_LEVEL_DEFAULT) end
            local function LvlAttached() return ns.RF_LEVEL_ATTACH[LvlPos()] ~= nil end
            local function LvlSpotOff() return LvlPos() == "none" or LvlAttached() end
            local function LvlReq()
                return LvlAttached() and "Attached to the name, the level uses the Name Size." or "Level Position"
            end
            local function LvlCogReq()
                return LvlAttached() and "Attached to the name, the level follows the name's position." or "Level Position"
            end
            row, h = W:DualRow(parent, y,
                { type="dropdown", text="Level Position", values=levelPosValues, order=levelPosOrder,
                  getValue=LvlPos,
                  setValue=function(v) SSet("levelTextPosition", v); EllesmereUI:RefreshPage() end },
                { type="slider", text="Level Size", min=6, max=26, step=1,
                  disabled=LvlSpotOff, disabledTooltip=LvlReq, rawTooltip=LvlAttached,
                  getValue=function() return SVal("levelTextSize", 10) end,
                  setValue=function(v) SSet("levelTextSize", v) end });  y = y - h
            EllesmereUI.BuildInlineCog(row._leftRegion, {
                icon = EllesmereUI.DIRECTIONS_ICON,
                disabled = LvlSpotOff, disabledTooltip = LvlCogReq, rawTooltip = LvlAttached,
                title = "Level Offset",
                rows = {
                    { type="slider", label="Offset X", min=-500, max=500, step=1,
                      get=function() return SVal("levelTextOffsetX", 0) end,
                      set=function(v) SSet("levelTextOffsetX", v) end },
                    { type="slider", label="Offset Y", min=-500, max=500, step=1,
                      get=function() return SVal("levelTextOffsetY", 0) end,
                      set=function(v) SSet("levelTextOffsetY", v) end },
                },
            })
        end

        -- Power Text (+ Custom/Class/Accent/Power swatches) | Power Text Size (+ position cog). Shows only on frames whose power bar shows, so everything greys while no role shows one.
        do
            local function PTOff() return IsPowerOff() or SVal("powerTextMode", "none") == "none" end
            local function PTReq() return IsPowerOff() and "Show Power Bar For" or "Power Text" end
            row, h = W:DualRow(parent, y,
                { type="dropdown", text="Power Text",
                  values={ ["none"]="None", ["percent"]="Percent", ["percentNoSign"]="Percent (No Sign)",
                           ["number"]="Number", ["numberPercent"]="Number | Percent", ["percentNumber"]="Percent | Number" },
                  order={ "none", "percent", "percentNoSign", "number", "numberPercent", "percentNumber" },
                  disabled=IsPowerOff,
                  disabledTooltip="Show Power Bar For",
                  getValue=function() return SVal("powerTextMode", "none") end,
                  setValue=function(v) SSet("powerTextMode", v); EllesmereUI:RefreshPage() end },
                { type="slider", text="Power Text Size", min=6, max=26, step=1,
                  disabled=PTOff,
                  disabledTooltip=PTReq,
                  getValue=function() return SVal("powerTextSize", 8) end,
                  setValue=function(v) SSet("powerTextSize", v) end });  y = y - h
            -- Swatches: Custom is added FIRST so the _lastInline chain places it next to the dropdown; Power (leftmost) shows the player's power color and is not editable. Each dims and blocks while Power Text is None or power is off.
            if not EllesmereUI._prebuilding then
                local rgn = row._leftRegion
                local function AddPTSwatch(getColor, setColor, mode, opensPicker, tooltip)
                    local sw, updateSw = EllesmereUI.BuildColorSwatch(
                        rgn, row:GetFrameLevel() + 3, getColor, setColor, false, 20)
                    sw:SetPoint("RIGHT", rgn._lastInline or rgn._control, "LEFT", -8, 0)
                    rgn._lastInline = sw
                    -- Preserve the picker-opening click, then switch mode on click (same technique as the Health Text swatches).
                    sw._eabOrigClick = sw:GetScript("OnClick")
                    sw:SetScript("OnClick", function(self)
                        if SVal("powerTextColorMode", "custom") ~= mode then
                            SSet("powerTextColorMode", mode)
                            EllesmereUI:RefreshPage()
                            return
                        end
                        if opensPicker and self._eabOrigClick then self._eabOrigClick(self) end
                    end)
                    sw:HookScript("OnEnter", function() EllesmereUI.ShowWidgetTooltip(sw, tooltip) end)
                    sw:HookScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
                    local block = CreateFrame("Frame", nil, sw)
                    block:SetAllPoints(); block:SetFrameLevel(sw:GetFrameLevel() + 10); block:EnableMouse(true)
                    block:SetScript("OnEnter", function() EllesmereUI.ShowWidgetTooltip(sw, EllesmereUI.DisabledTooltip(PTReq())) end)
                    block:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
                    local function vis()
                        updateSw()
                        if PTOff() then
                            sw:SetAlpha(0.3); block:Show()
                        else
                            sw:SetAlpha(SVal("powerTextColorMode", "custom") == mode and 1 or 0.3); block:Hide()
                        end
                    end
                    EllesmereUI.RegisterWidgetRefresh(vis)
                    vis()
                end
                -- Custom (rightmost): editable, opens the picker when active.
                AddPTSwatch(
                    function()
                        local c = SGet("powerTextCustomColor")
                        if c then return c.r, c.g, c.b, 1 end
                        return 1, 1, 1, 1
                    end,
                    function(r, g, b)
                        SWrite("powerTextCustomColor", { r=r, g=g, b=b })
                        ReloadAndUpdate()
                    end, "custom", true, "Custom Color")
                AddPTSwatch(
                    function()
                        local _, ct = UnitClass("player")
                        if ct and RAID_CLASS_COLORS[ct] then
                            local cc = RAID_CLASS_COLORS[ct]
                            return cc.r, cc.g, cc.b, 1
                        end
                        return 1, 1, 1, 1
                    end,
                    function() end, "class", false, "Class Color")
                AddPTSwatch(
                    function()
                        local r, g, b = EllesmereUI.ResolveActiveAccent()
                        return r or 1, g or 1, b or 1, 1
                    end,
                    function() end, "accent", false, "Accent Color")
                -- Power (leftmost): each frame's own power-type color at runtime.
                AddPTSwatch(
                    function()
                        local _, pToken = UnitPowerType("player")
                        local info = EllesmereUI.GetPowerColor(pToken or "MANA")
                        if info then return info.r, info.g, info.b, 1 end
                        return 0, 0.5, 1, 1
                    end,
                    function() end, "power", false, "Power Colored Text")
            end
            -- Position + offset cog on the Power Text Size slider.
            EllesmereUI.BuildInlineCog(row._rightRegion, {
                icon = EllesmereUI.DIRECTIONS_ICON,
                disabled = PTOff,
                disabledTooltip = PTReq,
                title = "Power Text Position",
                rows = {
                    { type="dropdown", label="Position", values=namePositionValues, order=namePositionOrder,
                      get=function() return SVal("powerTextPosition", "bottom") end,
                      set=function(v) SSet("powerTextPosition", v) end },
                    { type="slider", label="Offset X", min=-150, max=150, step=1,
                      get=function() return SVal("powerTextOffsetX", 0) end,
                      set=function(v) SSet("powerTextOffsetX", v) end },
                    { type="slider", label="Offset Y", min=-75, max=75, step=1,
                      get=function() return SVal("powerTextOffsetY", 0) end,
                      set=function(v) SSet("powerTextOffsetY", v) end },
                },
            })
        end

        -- Heal Absorb Text (+swatches) | Heal Absorb Text Position (+offset cog); Heal Absorb Text Size row is 1:1 with Health Text. Shows the heal-absorb shield amount (short/full), hidden at zero.
        row, h = W:DualRow(parent, y,
            { type="dropdown", text="Heal Absorb Text",
              values={ ["none"]="None", ["short"]="Short (240k)", ["amount"]="Amount" },
              order={ "none", "short", "amount" },
              getValue=function() return SVal("healAbsorbTextMode", "none") end,
              -- Rebuilds the page on the None <-> not-None flip so the Text Size row below appears/vanishes.
              setValue=EllesmereUI.DependentSetValue(
                  function() return SVal("healAbsorbTextMode", "none") ~= "none" end,
                  function(v) SSet("healAbsorbTextMode", v); EllesmereUI:RefreshPage() end) },
            { type="dropdown", text="Heal Absorb Text Position", values=namePositionValues, order=namePositionOrder,
              disabled=function() return SVal("healAbsorbTextMode", "none") == "none" end,
              disabledTooltip="Heal Absorb Text",
              getValue=function() return SVal("healAbsorbTextPosition", "center") end,
              setValue=function(v) SSet("healAbsorbTextPosition", v) end });  y = y - h
        -- Heal Absorb Text swatches (custom/class/accent), same pattern as the Health Text triple above.
        if not EllesmereUI._prebuilding then
            local rgn = row._leftRegion
            local function AddHASwatch(getColor, setColor, mode, opensPicker, tooltip)
                local sw = EllesmereUI.BuildColorSwatch(
                    rgn, row:GetFrameLevel() + 3, getColor, setColor, false, 20)
                sw:SetPoint("RIGHT", rgn._lastInline or rgn._control, "LEFT", -8, 0)
                rgn._lastInline = sw
                sw._eabOrigClick = sw:GetScript("OnClick")
                sw:SetScript("OnClick", function(self)
                    if SVal("healAbsorbTextColorMode", "custom") ~= mode then
                        SSet("healAbsorbTextColorMode", mode)
                        EllesmereUI:RefreshPage()
                        return
                    end
                    if opensPicker and self._eabOrigClick then self._eabOrigClick(self) end
                end)
                if tooltip then
                    sw:HookScript("OnEnter", function() EllesmereUI.ShowWidgetTooltip(sw, tooltip) end)
                    sw:HookScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
                end
                local function vis()
                    sw:SetAlpha(SVal("healAbsorbTextColorMode", "custom") == mode and 1 or 0.3)
                end
                EllesmereUI.RegisterWidgetRefresh(vis)
                vis()
            end
            -- Custom (rightmost): editable, opens the picker when active.
            AddHASwatch(
                function()
                    local c = SGet("healAbsorbTextCustomColor")
                    if c then return c.r, c.g, c.b, 1 end
                    return 1, 0.3, 0.3, 1
                end,
                function(r, g, b)
                    SWrite("healAbsorbTextCustomColor", { r=r, g=g, b=b })
                    ReloadAndUpdate()
                end, "custom", true, "Custom Color")
            AddHASwatch(
                function()
                    local _, ct = UnitClass("player")
                    if ct and RAID_CLASS_COLORS[ct] then
                        local cc = RAID_CLASS_COLORS[ct]
                        return cc.r, cc.g, cc.b, 1
                    end
                    return 1, 1, 1, 1
                end,
                function() end, "class", false, "Class Color")
            -- Accent (leftmost).
            AddHASwatch(
                function()
                    local r, g, b = EllesmereUI.ResolveActiveAccent()
                    return r or 1, g or 1, b or 1, 1
                end,
                function() end, "accent", false, "Accent Color")
        end
        -- Offset cog on the Heal Absorb Text Position region.
        do
            local rgn = row._rightRegion
            EllesmereUI.BuildInlineCog(rgn, {
                icon = EllesmereUI.DIRECTIONS_ICON,
                disabled = function() return SVal("healAbsorbTextMode", "none") == "none" end,
                disabledTooltip = "Heal Absorb Text",
                title = "Heal Absorb Text Offset",
                rows = {
                    { type="slider", label="Offset X", min=-150, max=150, step=1,
                      get=function() return SVal("healAbsorbTextOffsetX", 0) end,
                      set=function(v) SSet("healAbsorbTextOffsetX", v) end },
                    { type="slider", label="Offset Y", min=-75, max=75, step=1,
                      get=function() return SVal("healAbsorbTextOffsetY", 0) end,
                      set=function(v) SSet("healAbsorbTextOffsetY", v) end },
                },
            })
        end
        -- Row 5: Heal Absorb Text Size | (blank odd last slot). Hidden entirely
        -- while Heal Absorb Text is None.
        if SVal("healAbsorbTextMode", "none") ~= "none" then
            row, h = W:DualRow(parent, y,
                { type="slider", text="Heal Absorb Text Size", min=6, max=26, step=1,
                  getValue=function() return SVal("healAbsorbTextSize", 9) end,
                  setValue=function(v) SSet("healAbsorbTextSize", v) end },
                { type="label", text="" });  y = y - h
        end
        if onSection then onSection("textDisplay", _secY, y) end; _secY = y

        -------------------------------------------------------------------
        --  INDICATORS
        -------------------------------------------------------------------
        local indicatorHeader
        indicatorHeader, h = W:SectionHeader(parent, "INDICATORS", y); y = y - h

        -- Eyeball: toggle indicator visibility on preview (raid + party)
        do
            local EYE_VISIBLE   = EllesmereUI.EYE_VISIBLE_ICON
            local EYE_INVISIBLE = EllesmereUI.EYE_INVISIBLE_ICON

            local indLabel
            for _, rgn in ipairs({ indicatorHeader:GetRegions() }) do
                if rgn.GetText and EllesmereUI.EnKey(rgn:GetText()) == "INDICATORS" then
                    indLabel = rgn; break
                end
            end
            local eyeBtn = CreateFrame("Button", nil, indicatorHeader)
            eyeBtn:SetSize(24, 24)
            if indLabel then
                eyeBtn:SetPoint("LEFT", indLabel, "RIGHT", 5, 0)
            else
                eyeBtn:SetPoint("LEFT", indicatorHeader, "BOTTOMLEFT", 85, 8)
            end
            eyeBtn:SetFrameLevel(indicatorHeader:GetFrameLevel() + 5)
            eyeBtn:SetAlpha(0.4)
            local eyeTex = eyeBtn:CreateTexture(nil, "OVERLAY")
            eyeTex:SetAllPoints()

            -- On ns so the preview can read it.
            if ns._indicatorsVisible == nil then ns._indicatorsVisible = false end

            local function RefreshIndicatorEye()
                if IsPreviewOff() then
                    eyeTex:SetTexture(EYE_VISIBLE)
                    eyeBtn:SetAlpha(0.15)
                    return
                end
                eyeTex:SetTexture(ns._indicatorsVisible and EYE_INVISIBLE or EYE_VISIBLE)
                eyeBtn:SetAlpha(0.4)
            end
            EYE.refreshIndicatorEye = RefreshIndicatorEye
            RefreshIndicatorEye()
            eyeBtn:SetScript("OnClick", function()
                if IsPreviewOff() then return end
                ns._indicatorsVisible = not ns._indicatorsVisible
                -- Indicators are exclusive with health/power/dispel effects.
                if ns._indicatorsVisible then
                    if ns._healthAnimActive then
                        if ns._stopHealthAnim then ns._stopHealthAnim() end
                        if EYE.refreshHealthEye then EYE.refreshHealthEye() end
                    end
                    if ns._powerAnimActive then
                        if ns._stopPowerAnim then ns._stopPowerAnim() end
                        if EYE.refreshPowerEye then EYE.refreshPowerEye() end
                    end
                    if ns._dispelsVisible then
                        ns._dispelsVisible = false
                        if EYE.refreshDispelEye then EYE.refreshDispelEye() end
                    end
                end
                RefreshIndicatorEye()
                if ns.PvRefresh then ns.PvRefresh() end
            end)
            eyeBtn:SetScript("OnEnter", function(self)
                if IsPreviewOff() then
                    EllesmereUI.ShowWidgetTooltip(self, "Enable preview to use")
                    return
                end
                self:SetAlpha(0.7)
                EllesmereUI.ShowWidgetTooltip(self, ns._indicatorsVisible and "Hide indicators on preview" or "Show indicators on preview")
            end)
            eyeBtn:SetScript("OnLeave", function(self)
                if not IsPreviewOff() then self:SetAlpha(0.4) end
                EllesmereUI.HideWidgetTooltip()
            end)
        end  -- close do (indicators eyeball)

        -- WoW Forever: Missing Buffs, first in the section (runtime in
        -- EUI_RaidFrames_ForeverMissingBuffs.lua). The raid marker row's
        -- shape: Position (None turns it off) | Size, offsets in the cog.
        if EllesmereUI.IS_FOREVER then
            local mbPositionValues = {
                none        = "None",
                topleft     = "Top Left",
                top         = "Top",
                topright    = "Top Right",
                left        = "Left",
                center      = "Center",
                right       = "Right",
                bottomleft  = "Bottom Left",
                bottom      = "Bottom",
                bottomright = "Bottom Right",
            }
            local mbPositionOrder = { "none", "topleft", "top", "topright", "left", "center", "right", "bottomleft", "bottom", "bottomright" }
            local mbRow
            mbRow, h = W:DualRow(parent, y,
                { type="dropdown", text="Missing Buffs", values=mbPositionValues, order=mbPositionOrder,
                  tooltip="Shows Fortitude, Mark of the Wild, Spirit or Thorns on a member who is missing it, for the buffs you can cast yourself (choose which in the cog).",
                  getValue=function()
                      if not SVal("showMissingBuffs", true) then return "none" end
                      return SVal("missingBuffsPosition", "top")
                  end,
                  setValue=function(v)
                      if v == "none" then
                          SSet("showMissingBuffs", false)
                      else
                          SWrite("showMissingBuffs", true)
                          SSet("missingBuffsPosition", v)
                      end
                      EllesmereUI:RefreshPage()
                  end },
                { type="slider", text="Missing Buffs Size", min=8, max=40, step=1,
                  disabled=function() return not SVal("showMissingBuffs", true) end,
                  disabledTooltip="Missing Buffs",
                  getValue=function() return SVal("missingBuffsSize", 22) end,
                  setValue=function(v) SSet("missingBuffsSize", v) end });  y = y - h
            do
                local rgn = mbRow._leftRegion
                local rows = {
                    -- One switch per buff (all on by default). The list is the
                    -- profile's, shared across classes, so every buff is listed;
                    -- only the ones this character can cast ever show.
                    { type="reordercheck", label="Buffs", ddWidth=170,  -- the Glow dropdown's width
                      hint="Only buffs you can cast show",
                      items={
                          { key="missingBuffsFort",   label="Fortitude",        fixed=true },
                          { key="missingBuffsMark",   label="Mark of the Wild", fixed=true },
                          { key="missingBuffsSpirit", label="Spirit",           fixed=true },
                          { key="missingBuffsThorns", label="Thorns",           fixed=true },
                          { key="missingBuffsBlessing", label="Paladin Blessings", fixed=true },
                      },
                      get=function(key) return SVal(key, true) end,
                      set=function(key, on) SSet(key, on) end },
                    { type="slider", label="Offset X", min=-50, max=50, step=1,
                      get=function() return SVal("missingBuffsOffsetX", 0) end,
                      set=function(v) SSet("missingBuffsOffsetX", v) end },
                    { type="slider", label="Offset Y", min=-50, max=50, step=1,
                      get=function() return SVal("missingBuffsOffsetY", 0) end,
                      set=function(v) SSet("missingBuffsOffsetY", v) end },
                }
                -- The icons' glow: the shared glow controls (also listed on
                -- Global Settings > Glows); the Pixel Glow rows show only
                -- while Pixel Glow is picked.
                for _, r in ipairs(EllesmereUI.GlowOptions.PopupRows(MissingGlowDesc(SVal, SWrite), "Glow", true)) do
                    rows[#rows + 1] = r
                end
                EllesmereUI.BuildInlineCog(rgn, {
                    title = "Missing Buffs",
                    rows = rows,
                    disabled = function() return not SVal("showMissingBuffs", true) end,
                    disabledTooltip = "Missing Buffs",
                })
            end
        end

        local RI_STYLES = ns.ROLE_ICON_STYLES
        -- Effective role: the player's spec wins over a stale assigned role
        local playerRole = EllesmereUI.UnitEffectiveRole("player")
        local roleStyleValues = {
            none          = "None",
            modern        = "Modern",
            modernCircle  = "Modern Circle",
            styled        = "Styled",
            classicCircle = "Classic Circle",
            classic       = "Classic",
            blizzDefault  = "Blizz Default",
            -- Key stays "blizzLight" so saved roleIconStyle values resolve; only the display label reads "Modern Light".
            blizzLight    = "Modern Light",
            pixels        = "Pixels",
            _menuOpts = {
                icon = function(key)
                    local map = RI_STYLES[key]
                    if not map or not playerRole or map[playerRole] == nil then return nil end
                    if map._isTexture then return map[playerRole] end
                    return nil
                end,
                iconAtlas = function(key)
                    local map = RI_STYLES[key]
                    if not map or not playerRole or map[playerRole] == nil then return nil end
                    if not map._isTexture then return map[playerRole] end
                    return nil
                end,
            },
        }
        local roleStyleOrder = { "none", "modern", "blizzLight", "pixels", "modernCircle", "styled", "classicCircle", "classic", "blizzDefault" }
        row, h = W:DualRow(parent, y,
            { type="dropdown", text="Role Icons", values=roleStyleValues, order=roleStyleOrder,
              getValue=function() return SVal("roleIconStyle", "modern") end,
              setValue=function(v) SSet("roleIconStyle", v); EllesmereUI:RefreshPage() end },
            { type="dropdown", text="Show Role",
              disabled=function() return SVal("roleIconStyle", "modern") == "none" end,
              disabledTooltip="Role Icons",
              values={ __placeholder = "All Roles" }, order={ "__placeholder" },
              getValue=function() return "__placeholder" end,
              setValue=function() end });  y = y - h
        -- Right side placeholder dropdown is swapped for a checkbox dropdown.
        if not EllesmereUI._prebuilding then
            local rightRgn = row._rightRegion
            if rightRgn._control then rightRgn._control:Hide() end
            local showRoleItems = {
                { key = "tank",   label = "Tank" },
                { key = "healer", label = "Healer" },
                { key = "dps",    label = "DPS" },
            }
            local roleKeyMap = { tank = "showRoleForTank", healer = "showRoleForHealer", dps = "showRoleForDPS" }
            local cbDD = EllesmereUI.BuildVisOptsCBDropdown(
                rightRgn, 170, rightRgn:GetFrameLevel() + 2,
                showRoleItems,
                function(k) return SVal(roleKeyMap[k], true) end,
                function(k, v)
                    SSet(roleKeyMap[k], v)
                end)
            PP.Point(cbDD, "RIGHT", rightRgn, "RIGHT", -20, 0)
            rightRgn._control = cbDD
            rightRgn._lastInline = nil
        end
        do
            local rgn = row._leftRegion
            EllesmereUI.BuildInlineCog(rgn, {
                title = "Role Icons",
                rows = {
                    { type="toggle", label="Hide In Combat",
                      tooltip="Hide role icons while you are in combat.",
                      get=function() return SVal("roleIconHideInCombat", false) end,
                      set=function(v) SSet("roleIconHideInCombat", v); if ns._UpdateRoleIcons then ns._UpdateRoleIcons() end end },
                    { type="toggle", label="Show Behind Border",
                      tooltip="Draw role icons behind the frame border, including the hover and target highlight.",
                      get=function() return SVal("roleIconBehindBorder", false) end,
                      set=function(v) SSet("roleIconBehindBorder", v) end },
                },
            })
        end
        local rolePositionValues = {
            topleft     = "Top Left",
            top         = "Top",
            topright    = "Top Right",
            left        = "Left",
            center      = "Center",
            right       = "Right",
            bottomleft  = "Bottom Left",
            bottom      = "Bottom",
            bottomright = "Bottom Right",
        }
        local rolePositionOrder = EllesmereUI.POSITION_GRID_ORDER
        local roleRow2
        -- Party Frames kit: role, ready check and leader take the stock spots
        -- (their offset cogs stay live).
        roleRow2, h = W:DualRow(parent, y,
            ns.RF_PartyKitGate({ type="dropdown", text="Role Position", values=rolePositionValues, order=rolePositionOrder,
              disabled=function() return SVal("roleIconStyle", "modern") == "none" end,
              disabledTooltip="Role Icons",
              getValue=function() return SVal("roleIconPosition", "bottomleft") end,
              setValue=function(v) SSet("roleIconPosition", v) end }),
            { type="slider", text="Role Icon Size", min=8, max=30, step=1,
              disabled=function() return SVal("roleIconStyle", "modern") == "none" end,
              disabledTooltip="Role Icons",
              getValue=function() return SVal("roleIconSize", 14) end,
              setValue=function(v) SSet("roleIconSize", v) end });  y = y - h
        if not EllesmereUI._prebuilding then
            local rgn = roleRow2._leftRegion
            EllesmereUI.BuildInlineCog(rgn, {
                icon = EllesmereUI.DIRECTIONS_ICON,
                title = "Role Icon Offset",
                rows = {
                    { type="slider", label="Offset X", min=-50, max=50, step=1,
                      get=function() return SVal("roleIconOffsetX", 0) end,
                      set=function(v) SSet("roleIconOffsetX", v) end },
                    { type="slider", label="Offset Y", min=-50, max=50, step=1,
                      get=function() return SVal("roleIconOffsetY", 0) end,
                      set=function(v) SSet("roleIconOffsetY", v) end },
                },
            })
        end

        local markerPositionValues = {
            none        = "None",
            topleft     = "Top Left",
            top         = "Top",
            topright    = "Top Right",
            left        = "Left",
            center      = "Center",
            right       = "Right",
            bottomleft  = "Bottom Left",
            bottom      = "Bottom",
            bottomright = "Bottom Right",
        }
        local markerPositionOrder = { "none", "topleft", "top", "topright", "left", "center", "right", "bottomleft", "bottom", "bottomright" }
        row, h = W:DualRow(parent, y,
            { type="dropdown", text="Marker Position", values=markerPositionValues, order=markerPositionOrder,
              getValue=function()
                  if not SVal("showRaidMarker", true) then return "none" end
                  return SVal("raidMarkerPosition", "center")
              end,
              setValue=function(v)
                  if v == "none" then
                      SSet("showRaidMarker", false)
                  else
                      SWrite("showRaidMarker", true)
                      SSet("raidMarkerPosition", v)
                  end
                  EllesmereUI:RefreshPage()
              end },
            { type="slider", text="Marker Size", min=8, max=40, step=1,
              disabled=function() return not SVal("showRaidMarker", true) end,
              disabledTooltip="Marker Position",
              getValue=function() return SVal("raidMarkerSize", 16) end,
              setValue=function(v) SSet("raidMarkerSize", v) end });  y = y - h

        do
            local rgn = row._leftRegion
            EllesmereUI.BuildInlineCog(rgn, {
                icon = EllesmereUI.DIRECTIONS_ICON,
                title = "Marker Offset",
                rows = {
                    { type="slider", label="Offset X", min=-50, max=50, step=1,
                      get=function() return SVal("raidMarkerOffsetX", 0) end,
                      set=function(v) SSet("raidMarkerOffsetX", v) end },
                    { type="slider", label="Offset Y", min=-50, max=50, step=1,
                      get=function() return SVal("raidMarkerOffsetY", 0) end,
                      set=function(v) SSet("raidMarkerOffsetY", v) end },
                },
            })
        end

        -- Rows below Marker Position are the less-common indicators. The RAID tab collapses them behind the shared session expander (BuildLessCommonExpander in EllesmereUI_Widgets.lua, honors the global Auto Expand Less Common Settings toggle); the party tab always shows them.
        local lessCommonOpen = true
        if not optState._partyCtx then
            lessCommonOpen, y = EllesmereUI.BuildLessCommonExpander(parent, y,
                "rfIndicators", "Show Less Common Indicator Options")
        end
        if lessCommonOpen then

        -- The three indicators share a single texture, so one position + size control set drives all of them.
        local readyCheckPositionValues = {
            topleft     = "Top Left",
            top         = "Top",
            topright    = "Top Right",
            left        = "Left",
            center      = "Center",
            right       = "Right",
            bottomleft  = "Bottom Left",
            bottom      = "Bottom",
            bottomright = "Bottom Right",
        }
        local readyCheckPositionOrder = EllesmereUI.POSITION_GRID_ORDER
        local rcRow
        rcRow, h = W:DualRow(parent, y,
            ns.RF_PartyKitGate({ type="dropdown", text="Ready Check / Summon / Rez", values=readyCheckPositionValues, order=readyCheckPositionOrder,
              getValue=function() return SVal("readyCheckPosition", "center") end,
              setValue=function(v) SSet("readyCheckPosition", v) end }),
            { type="slider", text="Icon Size", min=8, max=40, step=1,
              getValue=function() return SVal("readyCheckSize", 20) end,
              setValue=function(v) SSet("readyCheckSize", v) end });  y = y - h
        if not EllesmereUI._prebuilding then
            local rgn = rcRow._leftRegion
            EllesmereUI.BuildInlineCog(rgn, {
                icon = EllesmereUI.DIRECTIONS_ICON,
                title = "Ready Check / Summon / Rez",
                rows = {
                    { type="toggle", label="Show Ready Check",
                      get=function() return SVal("showReadyCheck", true) end,
                      set=function(v) SSet("showReadyCheck", v) end },
                    { type="toggle", label="Show Incoming Summon",
                      get=function() return SVal("showSummonPending", true) end,
                      set=function(v) SSet("showSummonPending", v) end },
                    { type="toggle", label="Show Incoming Resurrection",
                      get=function() return SVal("showIncomingRez", true) end,
                      set=function(v) SSet("showIncomingRez", v) end },
                    { type="slider", label="Offset X", min=-50, max=50, step=1,
                      get=function() return SVal("readyCheckOffsetX", 0) end,
                      set=function(v) SSet("readyCheckOffsetX", v) end },
                    { type="slider", label="Offset Y", min=-50, max=50, step=1,
                      get=function() return SVal("readyCheckOffsetY", 0) end,
                      set=function(v) SSet("readyCheckOffsetY", v) end },
                },
            })
        end

        local statusTextPositionValues = {
            none        = "None",
            topleft     = "Top Left",
            top         = "Top",
            topright    = "Top Right",
            left        = "Left",
            center      = "Center",
            right       = "Right",
            bottomleft  = "Bottom Left",
            bottom      = "Bottom",
            bottomright = "Bottom Right",
        }
        local statusTextPositionOrder = { "none", "topleft", "top", "topright", "left", "center", "right", "bottomleft", "bottom", "bottomright" }
        local stRow
        stRow, h = W:DualRow(parent, y,
            { type="dropdown", text="Status Text", values=statusTextPositionValues, order=statusTextPositionOrder,
              getValue=function() return SVal("statusTextPosition", "center") end,
              setValue=function(v) SSet("statusTextPosition", v) end },
            { type="slider", text="Text Size", min=6, max=30, step=1,
              getValue=function() return SVal("statusTextSize", 14) end,
              setValue=function(v) SSet("statusTextSize", v) end });  y = y - h
        if not EllesmereUI._prebuilding then
            local rgn = stRow._leftRegion
            EllesmereUI.BuildInlineCog(rgn, {
                title = "Status Text",
                rows = {
                    { type="toggle", label="Show AFK",
                      get=function() return SVal("statusShowAFK", false) end,
                      set=function(v) SSet("statusShowAFK", v); ReloadAndUpdate() end },
                    { type="slider", label="Offset X", min=-50, max=50, step=1,
                      get=function() return SVal("statusTextOffsetX", 0) end,
                      set=function(v) SSet("statusTextOffsetX", v) end },
                    { type="slider", label="Offset Y", min=-50, max=50, step=1,
                      get=function() return SVal("statusTextOffsetY", 0) end,
                      set=function(v) SSet("statusTextOffsetY", v) end },
                },
            })
        end
        if not EllesmereUI._prebuilding then
            local rgn = stRow._rightRegion
            local swatch = EllesmereUI.BuildColorSwatch(
                rgn, stRow:GetFrameLevel() + 3,
                function()
                    local c = SGet("statusTextColor")
                    if c then return c.r, c.g, c.b, 1 end
                    return 1, 1, 1, 1
                end,
                function(r, g, b)
                    SWrite("statusTextColor", { r=r, g=g, b=b })
                    ReloadAndUpdate()
                end, false, 20)
            swatch:SetPoint("RIGHT", rgn._lastInline or rgn._control, "LEFT", -8, 0)
            rgn._lastInline = swatch
        end

        local leaderPositionValues = {
            none        = "None",
            topleft     = "Top Left",
            top         = "Top",
            topright    = "Top Right",
            left        = "Left",
            center      = "Center",
            right       = "Right",
            bottomleft  = "Bottom Left",
            bottom      = "Bottom",
            bottomright = "Bottom Right",
        }
        local leaderPositionOrder = { "none", "topleft", "top", "topright", "left", "center", "right", "bottomleft", "bottom", "bottomright" }
        -- (The dropdown is also the leader icon's on/off switch, so under the
        -- kit it keeps that job: shown at the stock spot, or None.)
        row, h = W:DualRow(parent, y,
            ns.RF_OptPartyKit() and { type="dropdown", text="Leader Icon",
              values={ kit = "Party Frame", none = "None" }, order={ "kit", "none" },
              getValue=function() return SVal("showLeaderIcon", false) and "kit" or "none" end,
              setValue=function(v)
                  SSet("showLeaderIcon", v ~= "none")
                  EllesmereUI:RefreshPage()
              end }
            or { type="dropdown", text="Leader Icon", values=leaderPositionValues, order=leaderPositionOrder,
              getValue=function()
                  if not SVal("showLeaderIcon", false) then return "none" end
                  return SVal("leaderIconPosition", "top")
              end,
              setValue=function(v)
                  if v == "none" then
                      SSet("showLeaderIcon", false)
                  else
                      SWrite("showLeaderIcon", true)
                      SSet("leaderIconPosition", v)
                  end
                  EllesmereUI:RefreshPage()
              end },
            { type="slider", text="Leader Icon Size", min=8, max=30, step=1,
              disabled=function() return not SVal("showLeaderIcon", false) end,
              disabledTooltip="Leader Icon",
              getValue=function() return SVal("leaderIconSize", 14) end,
              setValue=function(v) SSet("leaderIconSize", v) end });  y = y - h
        do
            local rgn = row._leftRegion
            EllesmereUI.BuildInlineCog(rgn, {
                icon = EllesmereUI.DIRECTIONS_ICON,
                title = "Leader Icon",
                rows = {
                    { type="toggle", label="Show In Combat",
                      tooltip="Show the leader/assistant icon while you are in combat. Disable to hide it during combat.",
                      get=function() return SVal("showLeaderIconInCombat", true) end,
                      set=function(v) SSet("showLeaderIconInCombat", v); if ns._UpdateLeaderIcons then ns._UpdateLeaderIcons() end end },
                    { type="slider", label="Offset X", min=-50, max=50, step=1,
                      get=function() return SVal("leaderIconOffsetX", 0) end,
                      set=function(v) SSet("leaderIconOffsetX", v) end },
                    { type="slider", label="Offset Y", min=-50, max=50, step=1,
                      get=function() return SVal("leaderIconOffsetY", 0) end,
                      set=function(v) SSet("leaderIconOffsetY", v) end },
                },
            })
        end

        -- Combat Icon Position ("None" disables) | Combat Icon Size; shows on members currently in combat. Style/color/offset live in the inline cog.
        local combatPositionValues = {
            none        = "None",
            topleft     = "Top Left",
            top         = "Top",
            topright    = "Top Right",
            left        = "Left",
            center      = "Center",
            right       = "Right",
            bottomleft  = "Bottom Left",
            bottom      = "Bottom",
            bottomright = "Bottom Right",
        }
        local combatPositionOrder = { "none", "topleft", "top", "topright", "left", "center", "right", "bottomleft", "bottom", "bottomright" }
        local combatStyleValues = {
            standard = "Standard",
            class    = "Class Theme",
            combat0  = "Arcade",
            combat1  = "Dungeoneer",
            combat2  = "Classic",
            combat3  = "Cross",
            combat4  = "Circle",
            combat5  = "Square",
        }
        local combatStyleOrder = { "standard", "class", "combat0", "combat1", "combat2", "combat3", "combat4", "combat5" }
        local ciRow
        ciRow, h = W:DualRow(parent, y,
            { type="dropdown", text="Combat Icon", values=combatPositionValues, order=combatPositionOrder,
              getValue=function()
                  if not SVal("showCombatIndicator", false) then return "none" end
                  return SVal("combatIndicatorPosition", "right")
              end,
              setValue=function(v)
                  if v == "none" then
                      SSet("showCombatIndicator", false)
                  else
                      SWrite("showCombatIndicator", true)
                      SSet("combatIndicatorPosition", v)
                  end
                  if ns._UpdateCombatIcons then ns._UpdateCombatIcons() end
                  EllesmereUI:RefreshPage()
              end },
            { type="slider", text="Combat Icon Size", min=8, max=40, step=1,
              disabled=function() return not SVal("showCombatIndicator", false) end,
              disabledTooltip="Combat Icon",
              getValue=function() return SVal("combatIndicatorSize", 16) end,
              setValue=function(v) SSet("combatIndicatorSize", v) end });  y = y - h
        if not EllesmereUI._prebuilding then
            local rgn = ciRow._leftRegion
            EllesmereUI.BuildInlineCog(rgn, {
                title = "Combat Icon",
                rows = {
                    { type="dropdown", label="Style", values=combatStyleValues, order=combatStyleOrder,
                      get=function() return SVal("combatIndicatorStyle", "standard") end,
                      set=function(v) SSet("combatIndicatorStyle", v); if ns._UpdateCombatIcons then ns._UpdateCombatIcons() end end },
                    { type="toggle", label="Class Colored",
                      tooltip="Tint the combat icon by the member's class color. Not available for the Arcade/Dungeoneer/Classic/Cross/Circle/Square styles.",
                      disabled=function()
                          local st = SVal("combatIndicatorStyle", "standard")
                          return st:find("^combat%d") and true or false
                      end,
                      disabledTooltip="Not available for this combat icon style.", rawTooltip=true,
                      get=function() return SVal("combatIndicatorColor", "custom") == "classcolor" end,
                      set=function(v) SSet("combatIndicatorColor", v and "classcolor" or "custom"); if ns._UpdateCombatIcons then ns._UpdateCombatIcons() end end },
                    { type="slider", label="Offset X", min=-50, max=50, step=1,
                      get=function() return SVal("combatIndicatorOffsetX", 0) end,
                      set=function(v) SSet("combatIndicatorOffsetX", v) end },
                    { type="slider", label="Offset Y", min=-50, max=50, step=1,
                      get=function() return SVal("combatIndicatorOffsetY", 0) end,
                      set=function(v) SSet("combatIndicatorOffsetY", v) end },
                },
            })
        end
        if not EllesmereUI._prebuilding then
            local rgn = ciRow._rightRegion
            local swatch = EllesmereUI.BuildColorSwatch(
                rgn, ciRow:GetFrameLevel() + 3,
                function()
                    local c = SGet("combatIndicatorCustomColor")
                    if c then return c.r, c.g, c.b, 1 end
                    return 1, 0.2, 0.2, 1
                end,
                function(r, g, b)
                    SWrite("combatIndicatorCustomColor", { r=r, g=g, b=b })
                    if ns._UpdateCombatIcons then ns._UpdateCombatIcons() end
                end, false, 20)
            swatch:SetPoint("RIGHT", rgn._lastInline or rgn._control, "LEFT", -8, 0)
            rgn._lastInline = swatch
        end

        -- Show Group Numbers | Number Size (+ alpha swatch). Raid only: party has no groups. Size + color also drive the always-on preview group labels; the toggle gates only the real frames.
        if not optState._partyCtx then
            local gnRow
            gnRow, h = W:DualRow(parent, y,
                { type="toggle", text="Show Group Numbers",
                  getValue=function() return SVal("showGroupNumbers", false) end,
                  setValue=function(v) SSet("showGroupNumbers", v) end },
                { type="slider", text="Number Size", min=6, max=30, step=1,
                  getValue=function() return SVal("groupNumberSize", 10) end,
                  setValue=function(v) SSet("groupNumberSize", v) end });  y = y - h
            if not EllesmereUI._prebuilding then
                local rgn = gnRow._rightRegion
                local swatch = EllesmereUI.BuildColorSwatch(
                    rgn, gnRow:GetFrameLevel() + 3,
                    function()
                        local c = SGet("groupNumberColor")
                        if c then return c.r, c.g, c.b, c.a or 0.75 end
                        return 1, 1, 1, 0.75
                    end,
                    function(r, g, b, a)
                        SWrite("groupNumberColor", { r=r, g=g, b=b, a=a })
                        ReloadAndUpdate()
                    end, true, 20)
                swatch:SetPoint("RIGHT", rgn._lastInline or rgn._control, "LEFT", -8, 0)
                rgn._lastInline = swatch
            end
            if not EllesmereUI._prebuilding then
                local rgn = gnRow._leftRegion
                EllesmereUI.BuildInlineCog(rgn, {
                    icon = EllesmereUI.DIRECTIONS_ICON,
                    title = "Group Number Offset",
                    rows = {
                        { type="slider", label="Offset X", min=-50, max=50, step=1,
                          get=function() return SVal("groupNumberOffsetX", 0) end,
                          set=function(v) SSet("groupNumberOffsetX", v) end },
                        { type="slider", label="Offset Y", min=-50, max=50, step=1,
                          get=function() return SVal("groupNumberOffsetY", 0) end,
                          set=function(v) SSet("groupNumberOffsetY", v) end },
                    },
                })
            end
        end

        -- Ping Marker | Ping Marker Size (+ offset cog). The mark a group member's ping
        -- puts on the pinged unit's frame, Blizzard's own art. Also needs Blizzard's
        -- "Show Pings on Raid Frames" setting on (same gate as the default frames).
        local pingPositionValues = {
            none        = "None",
            topleft     = "Top Left",
            top         = "Top",
            topright    = "Top Right",
            left        = "Left",
            center      = "Center",
            right       = "Right",
            bottomleft  = "Bottom Left",
            bottom      = "Bottom",
            bottomright = "Bottom Right",
        }
        local pingPositionOrder = { "none", "topleft", "top", "topright", "left", "center", "right", "bottomleft", "bottom", "bottomright" }
        local pingRow
        pingRow, h = W:DualRow(parent, y,
            { type="dropdown", text="Ping Marker", values=pingPositionValues, order=pingPositionOrder,
              tooltip="Shows the ping mark on a member's frame when someone pings them (needs Blizzard's Show Pings on Raid Frames setting on).",
              getValue=function()
                  if not SVal("showPingMarker", true) then return "none" end
                  return SVal("pingMarkerPosition", "center")
              end,
              setValue=function(v)
                  if v == "none" then
                      SSet("showPingMarker", false)
                  else
                      SWrite("showPingMarker", true)
                      SSet("pingMarkerPosition", v)
                  end
                  EllesmereUI:RefreshPage()
              end },
            { type="slider", text="Ping Marker Size", min=10, max=60, step=1,
              disabled=function() return not SVal("showPingMarker", true) end,
              disabledTooltip="Ping Marker",
              getValue=function() return SVal("pingMarkerSize", 30) end,
              setValue=function(v) SSet("pingMarkerSize", v) end });  y = y - h
        if not EllesmereUI._prebuilding then
            local rgn = pingRow._leftRegion
            EllesmereUI.BuildInlineCog(rgn, {
                icon = EllesmereUI.DIRECTIONS_ICON,
                title = "Ping Marker Offset",
                rows = {
                    { type="slider", label="Offset X", min=-50, max=50, step=1,
                      get=function() return SVal("pingMarkerOffsetX", 0) end,
                      set=function(v) SSet("pingMarkerOffsetX", v) end },
                    { type="slider", label="Offset Y", min=-50, max=50, step=1,
                      get=function() return SVal("pingMarkerOffsetY", 0) end,
                      set=function(v) SSet("pingMarkerOffsetY", v) end },
                },
            })
        end
        end   -- close the less-common-indicators collapse wrapper
        -- While expanded the shared link re-renders here in its "Hide ..." form; no-op while collapsed or in party ctx.
        if not optState._partyCtx then
            y = EllesmereUI.FinishLessCommonExpander(parent, y,
                "rfIndicators", "Show Less Common Indicator Options")
        end

        -------------------------------------------------------------------
        --  DISPELS
        -------------------------------------------------------------------
        local dispelHeader
        if onSection then onSection("indicators", _secY, y) end; _secY = y
        dispelHeader, h = W:SectionHeader(parent, "DISPELS", y); y = y - h

        -- Eyeball: toggle dispel visibility on preview (raid + party)
        do
            local EYE_VISIBLE   = EllesmereUI.EYE_VISIBLE_ICON
            local EYE_INVISIBLE = EllesmereUI.EYE_INVISIBLE_ICON

            local dispLabel
            for _, rgn in ipairs({ dispelHeader:GetRegions() }) do
                if rgn.GetText and EllesmereUI.EnKey(rgn:GetText()) == "DISPELS" then
                    dispLabel = rgn; break
                end
            end
            local eyeBtn = CreateFrame("Button", nil, dispelHeader)
            eyeBtn:SetSize(24, 24)
            if dispLabel then
                eyeBtn:SetPoint("LEFT", dispLabel, "RIGHT", 5, 0)
            else
                eyeBtn:SetPoint("LEFT", dispelHeader, "BOTTOMLEFT", 85, 8)
            end
            eyeBtn:SetFrameLevel(dispelHeader:GetFrameLevel() + 5)
            eyeBtn:SetAlpha(0.4)
            local eyeTex = eyeBtn:CreateTexture(nil, "OVERLAY")
            eyeTex:SetAllPoints()

            if ns._dispelsVisible == nil then ns._dispelsVisible = false end

            local function RefreshDispelEye()
                if IsPreviewOff() then
                    eyeTex:SetTexture(EYE_VISIBLE)
                    eyeBtn:SetAlpha(0.15)
                    return
                end
                eyeTex:SetTexture(ns._dispelsVisible and EYE_INVISIBLE or EYE_VISIBLE)
                eyeBtn:SetAlpha(0.4)
            end
            EYE.refreshDispelEye = RefreshDispelEye
            RefreshDispelEye()
            eyeBtn:SetScript("OnClick", function()
                if IsPreviewOff() then return end
                ns._dispelsVisible = not ns._dispelsVisible
                -- Dispels and indicators are mutually exclusive.
                if ns._dispelsVisible then
                    if ns._indicatorsVisible then
                        ns._indicatorsVisible = false
                        if EYE.refreshIndicatorEye then EYE.refreshIndicatorEye() end
                    end
                end
                RefreshDispelEye()
                if ns.PvRefresh then ns.PvRefresh() end
            end)
            eyeBtn:SetScript("OnEnter", function(self)
                if IsPreviewOff() then
                    EllesmereUI.ShowWidgetTooltip(self, "Enable preview to use")
                    return
                end
                self:SetAlpha(0.7)
                EllesmereUI.ShowWidgetTooltip(self, ns._dispelsVisible and "Hide dispels on preview" or "Show dispels on preview")
            end)
            eyeBtn:SetScript("OnLeave", function(self)
                if not IsPreviewOff() then self:SetAlpha(0.4) end
                EllesmereUI.HideWidgetTooltip()
            end)
        end  -- close do (dispels eyeball)

        local dispelOverlayValues = {
            none     = "None",
            fill     = "Fill Overlay",
            full     = "Full Overlay",
            gradient = "Gradient Overlay",
            gradient_sharp = "Gradient Sharp",
        }
        local dispelOverlayOrder = { "none", "fill", "full", "gradient", "gradient_sharp" }

        _, h = W:DualRow(parent, y,
            { type="dropdown", text="Dispel Overlay", values=dispelOverlayValues, order=dispelOverlayOrder,
              getValue=function() return SVal("dispelOverlay", "fill") end,
              setValue=function(v) SSet("dispelOverlay", v); EllesmereUI:RefreshPage() end },
            { type="slider", text="Overlay Opacity", min=5, max=100, step=1,
              disabled=function() return SVal("dispelOverlay", "fill") == "none" end,
              disabledTooltip="Dispel Overlay",
              getValue=function() return SVal("dispelOverlayOpacity", 100) end,
              setValue=function(v) SSet("dispelOverlayOpacity", v) end });  y = y - h


        local dispelIconPositionValues = {
            none        = "None",
            topleft     = "Top Left",
            top         = "Top",
            topright    = "Top Right",
            left        = "Left",
            center      = "Center",
            right       = "Right",
            bottomleft  = "Bottom Left",
            bottom      = "Bottom",
            bottomright = "Bottom Right",
        }
        local dispelIconPositionOrder = { "none", "topleft", "top", "topright", "left", "center", "right", "bottomleft", "bottom", "bottomright" }
        row, h = W:DualRow(parent, y,
            { type="slider", text="Frame Border", min=0, max=4, step=1,
              getValue=function() return SVal("dispelBorderSize", 2) end,
              setValue=function(v) SSet("dispelBorderSize", v) end },
            { type="dropdown", text="Type Icon Position", values=dispelIconPositionValues, order=dispelIconPositionOrder,
              getValue=function()
                  if not SVal("showDispelIcons", false) then return "none" end
                  return SVal("dispelIconPosition", "center")
              end,
              setValue=function(v)
                  if v == "none" then
                      SSet("showDispelIcons", false)
                  else
                      SSet("showDispelIcons", true)
                      SSet("dispelIconPosition", v)
                  end
                  EllesmereUI:RefreshPage()
              end });  y = y - h
        do
            local rgn = row._rightRegion
            EllesmereUI.BuildInlineCog(rgn, {
                icon = EllesmereUI.RESIZE_ICON,
                disabled = function() return not SVal("showDispelIcons", false) end,
                disabledTooltip = "This option requires a Type Icon Position other than None",
                title = "Dispel Icon",
                rows = {
                    { type="slider", label="Icon Size", min=8, max=48, step=1,
                      get=function() return SVal("dispelIconSize", 16) end,
                      set=function(v) SSet("dispelIconSize", v) end },
                    { type="slider", label="Offset X", min=-50, max=50, step=1,
                      get=function() return SVal("dispelIconOffsetX", 0) end,
                      set=function(v) SSet("dispelIconOffsetX", v) end },
                    { type="slider", label="Offset Y", min=-50, max=50, step=1,
                      get=function() return SVal("dispelIconOffsetY", 0) end,
                      set=function(v) SSet("dispelIconOffsetY", v) end },
                },
            })
        end
        -- Cog on the Dispel Border slider: thickness in physical pixels of the engine-tinted dispel ring on dispellable debuff ICONS,
        -- and Color Custom Borders (the frame's own border copied in the dispel type color).
        if not EllesmereUI._prebuilding then
            local rgn = row._leftRegion
            EllesmereUI.BuildInlineCog(rgn, {
                title = "Dispel Border",
                rows = {
                    { type="slider", label="Debuff Icon Border", min=-1, max=4, step=1,
                      tooltip="Thickness in physical pixels. -1 follows the Debuff Manager's Border setting, 0 hides the dispel color border.",
                      get=function() return SVal("dispelIconBorderSize", 2) end,
                      set=function(v) SSet("dispelIconBorderSize", v) end },
                    { type="toggle", label="Color Custom Borders",
                      tooltip="Recolors the frame border in the dispel type color while a debuff of that type is shown.",
                      -- Copies the frame's own border: only over a custom border (CustomBorderOff).
                      disabled=CustomBorderOff,
                      disabledTooltip=CustomBorderOffTip,
                      requireState="disabled",
                      get=function() return SVal("dispelCustomBorder", false) end,
                      set=function(v) SSet("dispelCustomBorder", v) end },
                },
            })
        end

        -- Dispel Colors: five always-active swatches, one per type. Unlike Name Color (a mode picker) each is independently editable, so no onClick/refreshAlpha -- the default click opens the picker.
        _, h = W:DualRow(parent, y,
            { type="multiSwatch", text="Dispel Colors",
              -- Per-type alpha 0 hides that type's border/overlay entirely.
              swatches = {
                { tooltip = "Magic", hasAlpha = true,
                  getValue = function() local c = SGet("dispelColorMagic"); if c then return c.r, c.g, c.b, c.a or 1 end return 0.354, 0.396, 0.74, 1 end,
                  setValue = function(r, g, b, a) SWrite("dispelColorMagic", { r=r, g=g, b=b, a=a or 1 }); ReloadAndUpdate() end },
                { tooltip = "Curse", hasAlpha = true,
                  getValue = function() local c = SGet("dispelColorCurse"); if c then return c.r, c.g, c.b, c.a or 1 end return 0.636, 0.0, 0.64, 1 end,
                  setValue = function(r, g, b, a) SWrite("dispelColorCurse", { r=r, g=g, b=b, a=a or 1 }); ReloadAndUpdate() end },
                { tooltip = "Disease", hasAlpha = true,
                  getValue = function() local c = SGet("dispelColorDisease"); if c then return c.r, c.g, c.b, c.a or 1 end return 0.71, 0.379, 0.0, 1 end,
                  setValue = function(r, g, b, a) SWrite("dispelColorDisease", { r=r, g=g, b=b, a=a or 1 }); ReloadAndUpdate() end },
                { tooltip = "Poison", hasAlpha = true,
                  getValue = function() local c = SGet("dispelColorPoison"); if c then return c.r, c.g, c.b, c.a or 1 end return 0.052, 0.586, 0.62, 1 end,
                  setValue = function(r, g, b, a) SWrite("dispelColorPoison", { r=r, g=g, b=b, a=a or 1 }); ReloadAndUpdate() end },
                { tooltip = "Bleed", hasAlpha = true,
                  getValue = function() local c = SGet("dispelColorBleed"); if c then return c.r, c.g, c.b, c.a or 1 end return 0.75, 0.15, 0.15, 1 end,
                  setValue = function(r, g, b, a) SWrite("dispelColorBleed", { r=r, g=g, b=b, a=a or 1 }); ReloadAndUpdate() end },
              } },
            { type="toggle", text="Only Show Dispellable",
              -- Inverse of dispelShowAll: ON = only-mine (dispelShowAll=false).
              getValue=function() return not SVal("dispelShowAll", true) end,
              setValue=function(v) SSet("dispelShowAll", not v) end });  y = y - h

        if onSection then onSection("dispels", _secY, y) end; _secY = y

        -- Party Frames kit: the stock frame has no Top Name Bar (the whole
        -- section, its sync overlay included, is skipped on the Party page).
        if not ns.RF_OptPartyKit() then
        -------------------------------------------------------------------
        --  TOP NAME BAR
        -------------------------------------------------------------------
        _, h = W:SectionHeader(parent, "TOP NAME BAR", y); y = y - h

        local function TNBOff() return not SVal("topNameBarEnabled", false) end

        -- Enable Top Name Bar | Height. The master toggle HIDES the dependent rows while off; SectionToggleSetValue forces that rebuild.
        row, h = W:DualRow(parent, y,
            { type="toggle", text="Enable Top Name Bar",
              getValue=function() return SVal("topNameBarEnabled", false) end,
              setValue=EllesmereUI.SectionToggleSetValue(function(v)
                  SSet("topNameBarEnabled", v)
              end) },
            TNBOff() and { type="label", text="" } or
            { type="slider", text="Height", min=8, max=40, step=1,
              getValue=function() return SVal("topNameBarHeight", 20) end,
              setValue=function(v) SSet("topNameBarHeight", v) end });  y = y - h

        if not TNBOff() then
        local tnbRow2
        tnbRow2, h = W:DualRow(parent, y,
            { type="slider", text="Background", min=0, max=100, step=1,
              getValue=function() return SVal("topNameBarBgOpacity", 80) end,
              setValue=function(v) SSet("topNameBarBgOpacity", v) end },
            { type="slider", text="Text Size", min=6, max=30, step=1,
              getValue=function() return SVal("topNameBarTextSize", 11) end,
              setValue=function(v) SSet("topNameBarTextSize", v) end });  y = y - h
        if not EllesmereUI._prebuilding then
            local rgn = tnbRow2._leftRegion
            local bgSwatch = EllesmereUI.BuildColorSwatch(
                rgn, tnbRow2:GetFrameLevel() + 3,
                function()
                    local c = SGet("topNameBarBgColor")
                    if c then return c.r, c.g, c.b, 1 end
                    return 17/255, 17/255, 17/255, 1
                end,
                function(r, g, b)
                    SWrite("topNameBarBgColor", { r=r, g=g, b=b })
                    ReloadAndUpdate()
                end, false, 20)
            bgSwatch:SetPoint("RIGHT", rgn._lastInline or rgn._control, "LEFT", -8, 0)
            rgn._lastInline = bgSwatch
        end
        do
            local rgn = tnbRow2._rightRegion
            EllesmereUI.BuildInlineCog(rgn, {
                icon = EllesmereUI.DIRECTIONS_ICON,
                title = "Text Offset",
                rows = {
                    { type="slider", label="Offset X", min=-50, max=50, step=1,
                      get=function() return SVal("topNameBarTextOffsetX", 0) end,
                      set=function(v) SSet("topNameBarTextOffsetX", v) end },
                    { type="slider", label="Offset Y", min=-50, max=50, step=1,
                      get=function() return SVal("topNameBarTextOffsetY", 0) end,
                      set=function(v) SSet("topNameBarTextOffsetY", v) end },
                },
            })
        end

        -- Align dropdown plus a custom/class swatch pair that doubles as the color-mode selector (as with Health Text). Defaults to class.
        local tnbRow3
        tnbRow3, h = W:DualRow(parent, y,
            { type="dropdown", text="Alignment & Color",
              values={ center="Center", left="Left", right="Right" },
              order={ "center", "left", "right" },
              getValue=function() return SVal("topNameBarTextAlign", "center") end,
              setValue=function(v) SSet("topNameBarTextAlign", v) end },
            { type="toggle", text="Show on Bottom",
              tooltip="Places the bar at the bottom of the frame instead of the top.",
              getValue=function() return SVal("topNameBarBottom", false) end,
              setValue=function(v) SSet("topNameBarBottom", v) end });  y = y - h
        -- Custom rightmost (opens picker), class leftmost. Clicking switches topNameBarTextColorMode; the inactive one dims. Custom is added FIRST so it sits next to the dropdown.
        if not EllesmereUI._prebuilding then
            local rgn = tnbRow3._leftRegion
            local function AddTNBSwatch(getColor, setColor, mode, opensPicker, tooltip)
                local sw = EllesmereUI.BuildColorSwatch(
                    rgn, tnbRow3:GetFrameLevel() + 3, getColor, setColor, false, 20)
                sw:SetPoint("RIGHT", rgn._lastInline or rgn._control, "LEFT", -8, 0)
                rgn._lastInline = sw
                sw._eabOrigClick = sw:GetScript("OnClick")
                sw:SetScript("OnClick", function(self)
                    if SVal("topNameBarTextColorMode", "class") ~= mode then
                        SSet("topNameBarTextColorMode", mode)
                        EllesmereUI:RefreshPage()
                        return
                    end
                    if opensPicker and self._eabOrigClick then self._eabOrigClick(self) end
                end)
                if tooltip then
                    sw:HookScript("OnEnter", function() EllesmereUI.ShowWidgetTooltip(sw, tooltip) end)
                    sw:HookScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
                end
                local function vis()
                    sw:SetAlpha(SVal("topNameBarTextColorMode", "class") == mode and 1 or 0.3)
                end
                EllesmereUI.RegisterWidgetRefresh(vis); vis()
            end
            -- Custom (rightmost): editable, opens the picker when active.
            AddTNBSwatch(
                function()
                    local c = SGet("topNameBarTextColor")
                    if c then return c.r, c.g, c.b, 1 end
                    return 1, 1, 1, 1
                end,
                function(r, g, b)
                    SWrite("topNameBarTextColor", { r=r, g=g, b=b })
                    ReloadAndUpdate()
                end, "custom", true, "Custom Color")
            AddTNBSwatch(
                function()
                    local _, ct = UnitClass("player")
                    if ct and RAID_CLASS_COLORS[ct] then
                        local cc = RAID_CLASS_COLORS[ct]
                        return cc.r, cc.g, cc.b, 1
                    end
                    return 1, 1, 1, 1
                end,
                function() end, "class", false, "Class Color")
        end
        end   -- close Top Name Bar hidden-while-disabled gate

        if onSection then onSection("topNameBar", _secY, y) end
        end   -- not Party Frames kit
        _secY = y

        -------------------------------------------------------------------
        --  FRIENDLY BOSS FRAMES (raid tab only)
        -------------------------------------------------------------------
        if not optState._partyCtx then
            _, h = W:SectionHeader(parent, "FRIENDLY BOSS FRAMES", y); y = y - h

            local function FBSet()
                local p = db.profile
                if not p.friendlyBoss then
                    p.friendlyBoss = { display = "never", position = "right" }
                end
                return p.friendlyBoss
            end
            -- Everything below the display dropdown is inert while "Never".
            local function FBEnabled()
                return (FBSet().display or "never") ~= "never"
            end
            local FB_DISABLED_TIP = "This option requires Add Friendly Boss Group to be set to Healers or Always."

            row, h = W:DualRow(parent, y,
                { type="dropdown", text="Add Friendly Boss Group",
                  values = { never="Never", healers="Healers", always="Always" },
                  order  = { "never", "healers", "always" },
                  getValue = function() return FBSet().display or "never" end,
                  -- Rows below are HIDDEN while Never; only the Never <-> enabled flip forces the full rebuild.
                  setValue = EllesmereUI.DependentSetValue(FBEnabled, function(v)
                      FBSet().display = v
                      ns.FB_Apply()
                      EllesmereUI:RefreshPage()
                  end) },
                (not FBEnabled()) and { type="label", text="" } or
                { type="dropdown", text="Position",
                  values = { left="Before First Group", right="After Last Group", free="Free Move" },
                  order  = { "left", "right", "free" },
                  getValue = function() return FBSet().position or "right" end,
                  setValue = function(v)
                      FBSet().position = v
                      if v ~= "free" then ns.FB_SetMoverShown(false) end
                      ns.FB_Apply()
                      EllesmereUI:RefreshPage()
                  end }); y = y - h
            -- Inline cog on the display dropdown: Show in Dungeons (opt-in;
            -- the group gate is raid-only without it). Dimmed while Never,
            -- like every row below the dropdown.
            if not EllesmereUI._prebuilding then
                local rgn = row._leftRegion
                EllesmereUI.BuildInlineCog(rgn, {
                    disabled = function() return not FBEnabled() end, disabledTooltip = FB_DISABLED_TIP,
                    title = "Friendly Boss Group",
                    rows = {
                        { type="toggle", label="Show in Dungeons",
                          get=function() return FBSet().showInDungeons == true end,
                          set=function(v)
                              -- Absent = off (additive key); FB_Apply re-registers
                              -- the secure group driver, so the flip is live.
                              FBSet().showInDungeons = v and true or nil
                              ns.FB_Apply()
                          end },
                    },
                })
            end
            if FBEnabled() then
            -- Free Move Position: label left, Move Frames button right (Free Move only). Right slot: Boss Health Color.
            row, h = W:DualRow(parent, y,
                { type="label", text="Free Move Position" },
                { type="label", text="Boss Health Color" }); y = y - h
            do
                local btn = ns.RF_OptMoveFramesButton(row, row._leftRegion, {
                    isShown = ns.FB_IsMoverShown, setShown = ns.FB_SetMoverShown,
                    allowed = function()
                        return FBEnabled() and (FBSet().position == "free") and not InCombatLockdown()
                    end,
                    enabled = FBEnabled, enabledTip = FB_DISABLED_TIP,
                })
                EllesmereUI.BuildInlineCog(row, {
                    anchorTo = btn, chain = false,
                    disabled = function() return not (FBEnabled() and FBSet().position == "free") end,
                    disabledTooltip = "This option requires Position to be set to Free Move",
                    title = "Free Move Options",
                    rows = {
                        { type="toggle", label="Horizontal Frames",
                          get=function() return FBSet().freeHorizontal == true end,
                          set=function(v)
                              FBSet().freeHorizontal = v
                              ns.FB_Apply()
                              -- Resize/reposition the drag overlay if it is up.
                              if ns.FB_IsMoverShown() then ns.FB_SetMoverShown(true) end
                          end },
                    },
                })
            end
            if not EllesmereUI._prebuilding then
                local rgn = row._rightRegion
                local swatch = EllesmereUI.BuildColorSwatch(
                    rgn, row:GetFrameLevel() + 3,
                    function()
                        local c = FBSet().healthColor
                        if c then return c.r, c.g, c.b, 1 end
                        return 23/255, 172/255, 49/255, 1
                    end,
                    function(r, g, b)
                        FBSet().healthColor = { r=r, g=g, b=b }
                        ns.FB_Apply()
                    end, false, 20)
                swatch:SetPoint("RIGHT", rgn, "RIGHT", -20, 0)
                rgn._lastInline = swatch
                -- Dimming alone leaves the swatch clickable; this blocks it.
                local swatchBlock = CreateFrame("Frame", nil, swatch)
                swatchBlock:SetAllPoints()
                swatchBlock:SetFrameLevel(swatch:GetFrameLevel() + 10)
                swatchBlock:EnableMouse(true)
                swatchBlock:SetScript("OnEnter", function()
                    EllesmereUI.ShowWidgetTooltip(swatch, FB_DISABLED_TIP)
                end)
                swatchBlock:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
                local function UpdateFBSwatch()
                    local on = FBEnabled()
                    swatch:SetAlpha(on and 1 or 0.3)
                    swatchBlock:SetShown(not on)
                    if rgn._label then rgn._label:SetAlpha(on and 1 or 0.3) end
                end
                EllesmereUI.RegisterWidgetRefresh(UpdateFBSwatch)
                UpdateFBSwatch()
            end

            -- Row 3: size offset on top of the shared raid frame size
            row, h = W:DualRow(parent, y,
                { type="slider", text="Extra Width", min=-50, max=100, step=1,
                  tooltip="Widens or narrows the boss frames relative to the raid frame size.",
                  getValue = function() return FBSet().extraWidth or 0 end,
                  setValue = function(v)
                      FBSet().extraWidth = v
                      ns.FB_Apply()
                      if ns.FB_IsMoverShown() then ns.FB_SetMoverShown(true) end
                  end },
                { type="slider", text="Extra Height", min=-50, max=100, step=1,
                  tooltip="Makes the boss frames taller or shorter relative to the raid frame size.",
                  getValue = function() return FBSet().extraHeight or 0 end,
                  setValue = function(v)
                      FBSet().extraHeight = v
                      ns.FB_Apply()
                      if ns.FB_IsMoverShown() then ns.FB_SetMoverShown(true) end
                  end }); y = y - h
            end   -- close Friendly Boss Frames hidden-while-disabled gate

            if onSection then onSection("friendlyBossFrames", _secY, y) end; _secY = y

            -------------------------------------------------------------------
            --  EXTRA FRAMES (raid tab only)
            -------------------------------------------------------------------
            _, h = W:SectionHeader(parent, "EXTRA FRAMES", y); y = y - h

            local function XFSet()
                local p = db.profile
                if not p.extraFrames then
                    p.extraFrames = { showTanks = false, position = "right", players = {} }
                end
                return p.extraFrames
            end
            -- Position settings only matter once something can feed the group: the tanks toggle or a bound hotkey.
            local function XFConfigured()
                return XFSet().showTanks == true
                    or (EllesmereUIDB and EllesmereUIDB.extraFramesKey) ~= nil
            end
            -- Row 1: Add to Extra Group Hotkey (capture) | Show Tanks toggle
            row, h = W:DualRow(parent, y,
                { type="label", text="Add to Extra Group Hotkey" },
                { type="toggle", text="Show Tanks in Extra Group",
                  tooltip="Automatically duplicates the raid's tanks into the Extra Frames group. Shares the frame cap with hotkey picks.",
                  getValue = function() return XFSet().showTanks == true end,
                  -- Rows below are HIDDEN while unconfigured (no tanks toggle AND no hotkey); only a configured-state flip forces the rebuild.
                  setValue = EllesmereUI.DependentSetValue(XFConfigured, function(v)
                      XFSet().showTanks = v
                      ns.XF_Apply()
                      -- Feature may have just gone dark; the mover can't stay up.
                      if not XFConfigured() then ns.XF_SetMoverShown(false) end
                      EllesmereUI:RefreshPage()
                  end) }); y = y - h
            -- Inline cog on Show Tanks: tank auto-include options.
            if not EllesmereUI._prebuilding then
                local rgn = row._rightRegion
                EllesmereUI.BuildInlineCog(rgn, {
                    title = "Show Tanks Options",
                    rows = {
                        { type="toggle", label="Exclude Myself",
                          tooltip="Skips your own frame when Show Tanks duplicates the raid's tanks. Hotkey picks can still add you.",
                          get=function() return XFSet().excludeSelfTank == true end,
                          set=function(v)
                              XFSet().excludeSelfTank = v or nil
                              ns.XF_Apply()
                          end },
                    },
                })
            end
            if not EllesmereUI._prebuilding then
                local rgn = row._leftRegion
                local kbBtn, refresh = EllesmereUI.BuildKeybindButton(row, {
                    w = 140, h = 26, font = 13, level = 5,
                    tooltip = "Left-click to set a keybind. Right-click to unbind.\nPress the key while hovering a raid frame to add or remove that player from the Extra Frames group.",
                    get = function() return EllesmereUIDB and EllesmereUIDB.extraFramesKey end,
                    set = function(key)
                        if not EllesmereUIDB then EllesmereUIDB = {} end
                        local bindBtn = _G["ERFExtraFramesBindBtn"]
                        if bindBtn then
                            -- Override bindings cannot change in combat: keep the old key.
                            if InCombatLockdown() then return end
                            if key or EllesmereUIDB.extraFramesKey then ClearOverrideBindings(bindBtn) end
                            if key then SetOverrideBindingClick(bindBtn, true, key, "ERFExtraFramesBindBtn") end
                        end
                        local wasConfigured = XFConfigured()
                        EllesmereUIDB.extraFramesKey = key
                        -- The mover can't stay up once the feature goes dark.
                        if not XFConfigured() then ns.XF_SetMoverShown(false) end
                        -- Hidden rows below: a configured-state flip needs the full rebuild, not the fast refresh.
                        if XFConfigured() ~= wasConfigured then
                            EllesmereUI:RefreshPage(true)
                        else
                            EllesmereUI:RefreshPage()
                        end
                    end,
                })
                EllesmereUI.PanelPP.Point(kbBtn, "RIGHT", rgn, "RIGHT", -20, 0)
                EllesmereUI.RegisterWidgetRefresh(refresh)
            end

            -- Rows 2-4 are HIDDEN while unconfigured (no tanks toggle AND no hotkey); the triggers above rebuild when that state flips.
            if XFConfigured() then
            -- Row 2: Position | Free Move Position (Move Frames)
            row, h = W:DualRow(parent, y,
                { type="dropdown", text="Position",
                  values = { left="Before First Group", right="After Last Group", free="Free Move" },
                  order  = { "left", "right", "free" },
                  getValue = function() return XFSet().position or "right" end,
                  setValue = function(v)
                      XFSet().position = v
                      if v ~= "free" then ns.XF_SetMoverShown(false) end
                      ns.XF_Apply()
                      -- Full rebuild: the Grow/Wrap Direction row only exists while the position is Free Move.
                      EllesmereUI:RefreshPage(true)
                  end },
                { type="label", text="Free Move Position" }); y = y - h
            ns.RF_OptMoveFramesButton(row, row._rightRegion, {
                isShown = ns.XF_IsMoverShown, setShown = ns.XF_SetMoverShown,
                allowed = function()
                    return XFConfigured() and (XFSet().position == "free") and not InCombatLockdown()
                end,
            })

            -- Free Move ONLY (hidden otherwise; Position's setValue forces a rebuild): growth axes of the free-floating grid, with Wrap After in an inline cog on Wrap Direction.
            -- Attached positions need none of this -- they stack group-sized runs of 5 along the raid's own growth settings, like extra raid groups.
            -- Grow Direction defaults from the legacy freeHorizontal key, so existing layouts read back unchanged.
            if XFSet().position == "free" then
            local function XFGrowDir()
                local set = XFSet()
                return set.growDirection or (set.freeHorizontal and "RIGHT" or "DOWN")
            end
            local function XFReapply()
                ns.XF_Apply()
                if ns.XF_IsMoverShown() then ns.XF_SetMoverShown(true) end
            end

            -- The wrap dropdown only offers the two directions perpendicular to the primary run, so a grow change forces a full rebuild to swap its value set.
            local xfHoriz = (XFGrowDir() == "RIGHT" or XFGrowDir() == "LEFT")
            row, h = W:DualRow(parent, y,
                { type="dropdown", text="Grow Direction",
                  tooltip="Direction the frames are laid out.",
                  values = { DOWN="Down", UP="Up", RIGHT="Right", LEFT="Left" },
                  order  = { "DOWN", "UP", "RIGHT", "LEFT" },
                  getValue = XFGrowDir,
                  setValue = function(v)
                      local set = XFSet()
                      set.growDirection = v
                      -- Keep the legacy key coherent for exports/older reads.
                      set.freeHorizontal = (v == "RIGHT" or v == "LEFT")
                      XFReapply()
                      EllesmereUI:RefreshPage(true)
                  end },
                { type="dropdown", text="Wrap Direction",
                  tooltip="Direction each new row or column stacks. Set Wrap After in the cog to enable wrapping.",
                  values = xfHoriz and { DOWN="Down", UP="Up" } or { RIGHT="Right", LEFT="Left" },
                  order  = xfHoriz and { "DOWN", "UP" } or { "RIGHT", "LEFT" },
                  getValue = function()
                      local wd = XFSet().wrapDirection
                      if XFGrowDir() == "RIGHT" or XFGrowDir() == "LEFT" then
                          return (wd == "UP" or wd == "DOWN") and wd or "DOWN"
                      end
                      return (wd == "LEFT" or wd == "RIGHT") and wd or "RIGHT"
                  end,
                  setValue = function(v)
                      XFSet().wrapDirection = v
                      XFReapply()
                  end }); y = y - h
            do
                local rgn = row._rightRegion
                EllesmereUI.BuildInlineCog(rgn, {
                    title = "Row Wrapping",
                    rows = {
                        { type="slider", label="Wrap After", min=0, max=20, step=1,
                          get=function() return XFSet().wrapAfter or 0 end,
                          set=function(v)
                              XFSet().wrapAfter = v
                              XFReapply()
                          end },
                    },
                })
            end
            end -- Free Move only row

            -- Row 4: size offset on top of the shared raid frame size
            row, h = W:DualRow(parent, y,
                { type="slider", text="Extra Width", min=-50, max=100, step=1,
                  tooltip="Widens or narrows the extra frames relative to the raid frame size.",
                  getValue = function() return XFSet().extraWidth or 0 end,
                  setValue = function(v)
                      XFSet().extraWidth = v
                      ns.XF_Apply()
                      if ns.XF_IsMoverShown() then ns.XF_SetMoverShown(true) end
                  end },
                { type="slider", text="Extra Height", min=-50, max=100, step=1,
                  tooltip="Makes the extra frames taller or shorter relative to the raid frame size.",
                  getValue = function() return XFSet().extraHeight or 0 end,
                  setValue = function(v)
                      XFSet().extraHeight = v
                      ns.XF_Apply()
                      if ns.XF_IsMoverShown() then ns.XF_SetMoverShown(true) end
                  end }); y = y - h
            -- Inline cog on Extra Width: Auto Resize Indicators (default on;
            -- off keeps indicators/auras at the real frames' base scale
            -- regardless of the extra frames' custom size).
            do
                local rgn = row._leftRegion
                EllesmereUI.BuildInlineCog(rgn, {
                    title = "Extra Frame Size",
                    rows = {
                        { type="toggle", label="Auto Resize Indicators",
                          get=function() return XFSet().autoResizeIndicators ~= false end,
                          set=function(v)
                              -- nil = on (additive key, zero migration); false = off.
                              if v then XFSet().autoResizeIndicators = nil else XFSet().autoResizeIndicators = false end
                              ns.XF_Apply()
                          end },
                    },
                })
            end
            end   -- close Extra Frames hidden-while-unconfigured gate

            if onSection then onSection("extraFrames", _secY, y) end; _secY = y
        end

        -------------------------------------------------------------------
        --  PET FRAMES (party and raid tabs, each with its own switch)
        -------------------------------------------------------------------
        -- Not a synced section: no onSection call, so the party tab never overlays it.
        do
            _, h = W:SectionHeader(parent, "PET FRAMES", y); y = y - h

            local function PFSet()
                local p = db.profile
                if not p.petFrames then
                    p.petFrames = { position = "right" }
                end
                return p.petFrames
            end
            local tabKey = optState._partyCtx and "party" or "raid"
            local onParty = tabKey == "party"
            -- This tab's Position, Extra Width/Height and Free Move spot (it reads the shared ones
            -- until it sets its own).
            local function PFTab()
                PFSet()
                return ns.PF_View(tabKey)
            end
            local function PFEnabled()
                return PFSet()[tabKey] == true
            end
            -- Only a preview already on screen: starting one here would show the raid preview on the
            -- party tab, or a preview with Preview Mode set to None.
            local function PFRefreshPreview()
                if ns.previewActive() then ns.ShowPreview() end
                if ns.partyPvActive() then ns.ShowPartyPreview() end
            end
            -- The last row holds what the chosen position needs: the Move Frames button (Free Move)
            -- or Pet Side (Beside Owner). The other positions have none.
            local function PFPlacement()
                local p = PFTab().position
                if p == "free" or (p == "owner" and onParty) then return p end
            end
            local BLANK = EllesmereUI.BlankRowCfg

            row, h = W:DualRow(parent, y,
                { type="toggle", text="Show Pets",
                  tooltip="Adds your group's pets beside these frames, with their health, name, range and click-casting.",
                  getValue = function() return PFEnabled() end,
                  -- Rows below are HIDDEN while off; only the on/off flip forces the rebuild.
                  setValue = EllesmereUI.DependentSetValue(PFEnabled, function(v)
                      PFSet()[tabKey] = v and true or false
                      ns.PF_Apply()
                      -- The Move Frames button goes with the page rebuild; the overlay can't stay up.
                      if not v and ns.PF_IsMoverShown(tabKey) then ns.PF_SetMoverShown(false) end
                      PFRefreshPreview()
                      EllesmereUI:RefreshPage()
                  end) },
                (not PFEnabled()) and BLANK() or
                { type="dropdown", text="Position",
                  -- Beside Owner (a pet beside each party frame) is party only.
                  values = onParty
                      and { left="Before First Group", right="After Last Group", free="Free Move", owner="Beside Owner" }
                      or { left="Before First Group", right="After Last Group", free="Free Move" },
                  order  = onParty and { "left", "right", "free", "owner" } or { "left", "right", "free" },
                  getValue = function() return PFTab().position or "right" end,
                  setValue = function(v)
                      local before = PFPlacement()
                      PFTab().position = v
                      if v ~= "free" and ns.PF_IsMoverShown(tabKey) then ns.PF_SetMoverShown(false) end
                      ns.PF_Apply()
                      PFRefreshPreview()
                      -- A new last row needs the full rebuild.
                      EllesmereUI:RefreshPage(PFPlacement() ~= before)
                  end }); y = y - h

            if PFEnabled() then
            row, h = W:DualRow(parent, y,
                { type="slider", text="Extra Width", min=-50, max=100, step=1,
                  tooltip="Widens or narrows the pet frames relative to the frame size.",
                  getValue = function() return PFTab().extraWidth or 0 end,
                  setValue = function(v)
                      PFTab().extraWidth = v
                      ns.PF_Apply()
                      ns.PF_PlaceMover(tabKey)
                      PFRefreshPreview()
                  end },
                { type="slider", text="Extra Height", min=-50, max=100, step=1,
                  tooltip="Makes the pet frames taller or shorter relative to the frame size.",
                  getValue = function() return PFTab().extraHeight or 0 end,
                  setValue = function(v)
                      PFTab().extraHeight = v
                      ns.PF_Apply()
                      ns.PF_PlaceMover(tabKey)
                      PFRefreshPreview()
                  end }); y = y - h

            local placement = PFPlacement()
            if placement == "free" then
                row, h = W:DualRow(parent, y, { type="label", text="Free Move Position" }, BLANK()); y = y - h
                ns.RF_OptMoveFramesButton(row, row._leftRegion, {
                    isShown = function() return ns.PF_IsMoverShown(tabKey) end,
                    setShown = function(show) ns.PF_SetMoverShown(show, tabKey) end,
                    allowed = function() return PFTab().position == "free" and not InCombatLockdown() end,
                })
            elseif placement == "owner" then
                -- Across the party frames' stack only: beside stacked frames, above or below
                -- horizontal ones (the other sides hold the next frame).
                row, h = W:DualRow(parent, y,
                    { type="dropdown", text="Pet Side",
                      values = { right="Right", left="Left", above="Above", below="Below" },
                      order  = { "right", "left", "above", "below" },
                      itemDisabled = function(v)
                          local across = (v == "above" or v == "below")
                          return across ~= (db.profile.partyHorizontal and true or false)
                      end,
                      itemDisabledTooltip = function(v)
                          if v == "above" or v == "below" then return "Horizontal Frames" end
                          return "This option requires Horizontal Frames to be disabled"
                      end,
                      getValue = function() return ns.PF_OwnerSide() end,
                      setValue = function(v)
                          PFSet().ownerSide = v
                          ns.PF_Apply()
                          PFRefreshPreview()
                      end },
                    BLANK()); y = y - h
            end
            end
            _secY = y
        end

        -------------------------------------------------------------------
        --  RANGE & TOOLTIP
        -------------------------------------------------------------------
        _, h = W:SectionHeader(parent, "EXTRAS", y); y = y - h

        -- OOR Alpha | Show Raid Frames Tooltip (dropdown + cog). The dropdown is a pure VIEW over the legacy keys: with tooltipMode unset it derives the shown option from the showTooltip toggle plus the global "show in combat" flag, so behavior only changes once the user picks.
        -- Same derive as the runtime ns._ResolveTooltipMode.
        local function CurTooltipMode()
            local m = SVal("tooltipMode", nil)
            if m ~= nil then return m end
            if SVal("showTooltip", true) == false then return "never" end
            if EllesmereUIDB and EllesmereUIDB.showUnitTooltipsInCombat then return "always" end
            return "outOfCombat"
        end
        row, h = W:DualRow(parent, y,
            { type="slider", text="Out of Range Alpha", min=10, max=100, step=1,
              getValue=function() return floor((SVal("oorAlpha", 0.4)) * 100) end,
              setValue=function(v)
                  SSet("oorAlpha", v / 100)
                  -- SetAlphaFromBoolean bakes the value in at call time, so already-OOR units keep the old alpha until a range re-eval.
                  -- Seed all buttons so the slider takes effect now.
                  if ns._RangeSeedAll then ns._RangeSeedAll() end
              end },
            { type="dropdown", text="Show Raid Frames Tooltip",
              tooltip="Controls when the tooltip appears as you hover a raid or party frame",
              values={ always="Always", outOfCombat="Out of Combat", outOfBossCombat="Out of Boss Combat", never="Never" },
              order={ "always", "outOfCombat", "outOfBossCombat", "never" },
              getValue=function() return CurTooltipMode() end,
              setValue=function(v) SSet("tooltipMode", v) end });  y = y - h
        -- Cog: buff/HoT aura-icon tooltips (Buff Manager), hidden by default and opt-in here. This is the ONLY gate on the aura tip: the dropdown's tooltip mode governs the UNIT tooltip and must NOT veto an aura tip enabled here (see ns.RaidFrameTooltipAllowed).
        if not EllesmereUI._prebuilding then
            local rgn = row._rightRegion
            local tipRows
                -- 4-state on the same key: true/nil=hidden, false=shown, "cursor"=shown at cursor, "combat"=hidden during combat.
                tipRows = {
                    { type="dropdown", label="Buff Tooltips",
                      tooltip="Tooltip behavior when hovering a buff/HoT icon on a raid or party frame.",
                      values={ hidden="Hidden", shown="Shown", cursor="Shown At Cursor", combat="Hidden In Combat" },
                      order={ "hidden", "shown", "cursor", "combat" },
                      get=function()
                          local v = SVal("buffHideTooltips", true)
                          if v == false then return "shown" end
                          if v == "cursor" or v == "combat" then return v end
                          return "hidden"
                      end,
                      set=function(k)
                          local v = k
                          if k == "shown" then v = false elseif k == "hidden" then v = true end
                          SSet("buffHideTooltips", v); if ns.ReloadFrames then ns.ReloadFrames() end
                      end },
                }
            EllesmereUI.BuildInlineCog(rgn, {
                title = "Tooltip Settings",
                rows = tipRows,
            })
        end

        -- Healer Mana Display: one mana-percent text row per group healer,
        -- riding the existing power-event plumbing (see ns.HM_Rebuild).
        local function HMS()
            local p = db.profile
            if not p.healerMana then p.healerMana = { mode = "none" } end
            return p.healerMana
        end
        local function HMRefresh()
            if ns.HM_Rebuild then ns.HM_Rebuild() end
        end
        local hmRow
        hmRow, h = W:DualRow(parent, y,
            { type="dropdown", text="Healer Mana Display",
              tooltip="Shows a mana percentage row for every healer in your group as its own movable text display. Position it in Unlock Mode.",
              values={ none="None", party="In Party", raid="In Raid", both="In Party & Raid" },
              order={ "none", "party", "raid", "both" },
              getValue=function()
                  local m = HMS().mode
                  return (m == "party" or m == "raid" or m == "both") and m or "none"
              end,
              setValue=function(v)
                  HMS().mode = v
                  -- Re-syncs healer power-event registrations and rebuilds.
                  if ns.UpdatePowerEventRegistration then ns.UpdatePowerEventRegistration() end
                  -- Re-register unlock elements: the mover's isHidden verdict
                  -- just changed, and re-registration applies it live to an
                  -- open unlock session (both directions).
                  if ns._RFRegisterUnlock then ns._RFRegisterUnlock() end
              end },
            { type="multiSwatch", text="Healer Mana Text Color",
              swatches = {
                { tooltip = "Custom Colored",
                  getValue = function()
                      local c = HMS().color
                      return (c and c.r) or 1, (c and c.g) or 1, (c and c.b) or 1, 1
                  end,
                  setValue = function(r, g, b)
                      local hm = HMS()
                      hm.color = { r = r, g = g, b = b }
                      hm.colorMode = "custom"
                      HMRefresh()
                  end,
                  onClick = function(self)
                      local hm = HMS()
                      if hm.colorMode == "power" then
                          hm.colorMode = "custom"
                          HMRefresh()
                          EllesmereUI:RefreshPage()
                          return
                      end
                      if self._eabOrigClick then self._eabOrigClick(self) end
                  end,
                  refreshAlpha = function()
                      return (HMS().colorMode == "power") and 0.3 or 1
                  end },
                { tooltip = "Power Colored",
                  getValue = function()
                      -- Same resolver chain as the runtime rows: the global
                      -- custom power color first, stock mana color after.
                      local info = EllesmereUI.GetPowerColor("MANA")
                      if info then return info.r, info.g, info.b, 1 end
                      local mc = PowerBarColor and PowerBarColor.MANA
                      if mc then return mc.r, mc.g, mc.b, 1 end
                      return 0.3, 0.5, 0.85, 1
                  end,
                  setValue = function() end,
                  onClick = function()
                      local hm = HMS()
                      hm.colorMode = "power"
                      HMRefresh()
                      EllesmereUI:RefreshPage()
                  end,
                  refreshAlpha = function()
                      return (HMS().colorMode == "power") and 1 or 0.3
                  end },
              } }
        );  y = y - h
        -- Inline cog (text settings) + preview eyeball on the toggle
        if not EllesmereUI._prebuilding then
            local rgn = hmRow._leftRegion
            EllesmereUI.BuildInlineCog(rgn, {
                title = "Healer Mana Display",
                rows = {
                    { type="slider", label="Text Size", min=8, max=24, step=1,
                      get=function() return HMS().textSize or 12 end,
                      set=function(v) HMS().textSize = v; HMRefresh() end },
                    { type="slider", label="Spacing", min=0, max=12, step=1,
                      tooltip="Vertical space between rows.",
                      get=function() return HMS().spacing or 2 end,
                      set=function(v) HMS().spacing = v; HMRefresh() end },
                    { type="dropdown", label="Text Align",
                      values={ LEFT="Left", CENTER="Center", RIGHT="Right" },
                      order={ "LEFT", "CENTER", "RIGHT" },
                      get=function()
                          local a = HMS().align
                          return (a == "RIGHT" or a == "CENTER") and a or "LEFT"
                      end,
                      set=function(k) HMS().align = k; HMRefresh() end },
                    { type="dropdown", label="Text Growth",
                      tooltip="Which way the rows stack as healers are added.",
                      values={ DOWN="Down", UP="Up" }, order={ "DOWN", "UP" },
                      get=function() return HMS().growth == "UP" and "UP" or "DOWN" end,
                      set=function(k) HMS().growth = k; HMRefresh() end },
                    { type="toggle", label="Show Names in Raid",
                      tooltip="Shows each healer's name before the number while in a raid. In a party the display always shows numbers only.",
                      get=function() return HMS().showNames ~= false end,
                      -- if/else, NOT `v and nil or false`: that expression is
                      -- ALWAYS false (the nil arm falls through the or).
                      set=function(v)
                          if v then HMS().showNames = nil
                          else HMS().showNames = false end
                          HMRefresh()
                      end },
                    { type="toggle", label="Class Colored Names",
                      get=function() return HMS().classNames ~= false end,
                      set=function(v)
                          if v then HMS().classNames = nil
                          else HMS().classNames = false end
                          HMRefresh()
                      end },
                },
            })

            local EYE_VISIBLE   = EllesmereUI.EYE_VISIBLE_ICON
            local EYE_INVISIBLE = EllesmereUI.EYE_INVISIBLE_ICON
            local eyeBtn = CreateFrame("Button", nil, rgn)
            eyeBtn:SetSize(26, 26)
            eyeBtn:SetPoint("RIGHT", rgn._lastInline, "LEFT", -4, 0)
            rgn._lastInline = eyeBtn
            eyeBtn:SetFrameLevel(rgn:GetFrameLevel() + 5)
            eyeBtn:SetAlpha(0.4)
            local eyeTex = eyeBtn:CreateTexture(nil, "OVERLAY")
            eyeTex:SetAllPoints(); eyeTex:SetTexture(EYE_VISIBLE)
            local function RefreshHMEye()
                eyeTex:SetTexture(ns._hmPreview and EYE_INVISIBLE or EYE_VISIBLE)
            end
            eyeBtn:SetScript("OnClick", function()
                if ns.HM_SetPreview then ns.HM_SetPreview(not ns._hmPreview) end
                RefreshHMEye()
            end)
            eyeBtn:SetScript("OnEnter", function(s)
                s:SetAlpha(0.7)
                EllesmereUI.ShowWidgetTooltip(s, ns._hmPreview and "Hide the preview" or "Preview the display at its position")
            end)
            eyeBtn:SetScript("OnLeave", function(s)
                s:SetAlpha(0.4)
                EllesmereUI.HideWidgetTooltip()
            end)
            EllesmereUI:RegisterOnHide(function()
                if ns._hmPreview and ns.HM_SetPreview then
                    ns.HM_SetPreview(false)
                    RefreshHMEye()
                end
            end)
        end

        -- Hide Blizzard Party Panel shares the exact global setting and apply function as the QoL toggle (EllesmereUIDB.hideBlizzardPartyFrame -> EllesmereUI._applyHideBlizzardPartyFrame); the QoL toggle is disabled while Raid Frames is loaded. Off when unset.
        _, h = W:DualRow(parent, y,
            { type="toggle", text="Hide Blizzard Party Panel",
              tooltip="Hides the collapsed Blizzard party/raid sidebar panel on the side of the screen.",
              getValue=function() return EllesmereUIDB and EllesmereUIDB.hideBlizzardPartyFrame or false end,
              setValue=function(v)
                  if not EllesmereUIDB then EllesmereUIDB = {} end
                  EllesmereUIDB.hideBlizzardPartyFrame = v
                  EllesmereUI._applyHideBlizzardPartyFrame()
              end },
            { type="multiSwatch", text="Status Colors",
              swatches = {
                { tooltip = "Offline", hasAlpha = false,
                  getValue = function() local c = SGet("statusColorOffline"); if c then return c.r, c.g, c.b end return 0x66/255, 0x66/255, 0x66/255 end,
                  setValue = function(r, g, b) SWrite("statusColorOffline", { r=r, g=g, b=b }); ReloadAndUpdate() end },
                { tooltip = "Dead", hasAlpha = false,
                  getValue = function() local c = SGet("statusColorDead"); if c then return c.r, c.g, c.b end return 0x24/255, 0x17/255, 0x17/255 end,
                  setValue = function(r, g, b) SWrite("statusColorDead", { r=r, g=g, b=b }); ReloadAndUpdate() end },
              } });  y = y - h

        -- Right-click + drag over a raid/party frame turns the camera (mouselook).
        _, h = W:DualRow(parent, y,
            { type="toggle", text="Right Mouse Camera Unlock",
              tooltip="Allows free camera movement while holding and dragging right mouse button over raid frames. Right-click tap still opens the unit menu.",
              getValue=function() return SVal("freeRightClickCamera", false) end,
              setValue=function(v) SSet("freeRightClickCamera", v); if ns.FRCM_Refresh then ns.FRCM_Refresh() end end },
            { type="dropdown", text="Frame Strata",
              tooltip="Controls the display order of raid and party frames. Set higher to show above other elements.",
              values=EllesmereUI.FRAME_STRATA_LABELS,
              order=EllesmereUI.FRAME_STRATA_ORDER_BASE,
              getValue=function() return SVal("frameStrata", "LOW") end,
              setValue=function(v)
                  -- Reload after changing strata to restore child frame levels.
                  SWrite("frameStrata", v)
                  if ns.ApplyFrameStrata then ns.ApplyFrameStrata() end
                  ReloadAndUpdate()
              end });  y = y - h

        if onSection then onSection("rangeTooltip", _secY, y) end
        return y
    end

    ---------------------------------------------------------------------------
    --  Buff Manager page (placeholder)
    ---------------------------------------------------------------------------
    local function BuildBuffManagerPage(pageName, parent, yOffset)
        -- Buff Manager v2 runs INSIDE the legacy page shell.
        -- The from-scratch replacement page was rejected in field review and is not routed to; do not wire it up.
        if ns.BM_BuildPage then
            return ns.BM_BuildPage(pageName, parent, yOffset)
        end
        return math.abs(yOffset)
    end

    ---------------------------------------------------------------------------
    --  Test Mode (global preview with all toggleable elements)
    ---------------------------------------------------------------------------
    local testModeFrame = nil
    local testModeActive = false

    local function CloseTestMode()
        testModeActive = false
        ns._testMode = false
        if testModeFrame then
            testModeFrame:SetAlpha(1)
            local fadeOutAG = testModeFrame:CreateAnimationGroup()
            local fadeOutA = fadeOutAG:CreateAnimation("Alpha")
            fadeOutA:SetFromAlpha(1); fadeOutA:SetToAlpha(0); fadeOutA:SetDuration(0.3)
            testModeFrame:SetAlpha(0)
            fadeOutAG:SetScript("OnFinished", function() testModeFrame:Hide() end)
            fadeOutAG:Play()
        end
        ns._indicatorsVisible = false
        ns._dispelsVisible = false
        ns._defensivesPreviewVisible = false
        ns._debuffsPreviewVisible = false
        if ns._stopHealthAnim and ns._healthAnimActive then ns._stopHealthAnim() end
        ns._healthAnimActive = false
        ns._bmFrameEffectsVisible = false
        ns._testReducedMaxHealth = false
        ns._testAbsorbs = nil
        ns._testHealAbsorbs = nil
        ns._testHealPrediction = nil
        ns._testThreat = nil
        ns._testBuffsVisible = false
        if ns.StopPvBuffTicker then ns.StopPvBuffTicker() end
        -- Hide the container immediately; the dimmer fade masks it.
        if ns._overlayContainer then ns._overlayContainer:Hide() end
        if ns.HidePreview then ns.HidePreview() end
        local activePage = EllesmereUI:GetActivePage()
        if activePage == PAGE_MAIN then
            local mode = db.profile.previewMode or "overlay"
            if mode ~= "none" and ns.ShowPreview then
                C_Timer.After(0, function() if ns.ShowPreview then ns.ShowPreview() end end)
            end
        end
    end

    local function OpenTestMode()
        if testModeActive then CloseTestMode(); return end
        testModeActive = true
        ns._testMode = true

        local PP = EllesmereUI.PanelPP or EllesmereUI.PP
        local fontPath = (EllesmereUI.GetFontPath("raidFrames")) or "Fonts\\FRIZQT__.TTF"
        local accentColor = EllesmereUI.ELLESMERE_GREEN or { r = 0.05, g = 0.82, b = 0.62 }
        local s = db.profile

        if not testModeFrame then
            testModeFrame = CreateFrame("Frame", nil, UIParent)
            testModeFrame:SetFrameStrata("FULLSCREEN_DIALOG")
            testModeFrame:SetAllPoints()
            testModeFrame:EnableMouse(true)
            local dimBg = testModeFrame:CreateTexture(nil, "BACKGROUND")
            dimBg:SetAllPoints(); dimBg:SetColorTexture(0, 0, 0, 0.75)
        end
        testModeFrame:SetFrameLevel(50)
        testModeFrame:SetAlpha(0)
        testModeFrame:Show()

        for _, c in ipairs({testModeFrame:GetChildren()}) do c:Hide(); c:SetParent(nil) end

        -- Preview flags are set by ns._applyTestState() below.
        local fadeInAG = testModeFrame:CreateAnimationGroup()
        local fadeInA = fadeInAG:CreateAnimation("Alpha")
        fadeInA:SetFromAlpha(0); fadeInA:SetToAlpha(1); fadeInA:SetDuration(0.3)
        testModeFrame:SetAlpha(1)
        fadeInAG:Play()

        -- Force the preview up; ns._testMode forces overlay mode.
        if ns.HidePreview then ns.HidePreview() end
        C_Timer.After(0, function()
            if ns.ShowPreview and ns._testMode then
                ns.ShowPreview()
                -- Re-apply now that preview frames exist and previewActive is true.
                if ns._applyTestState then ns._applyTestState() end
                -- Reanchor + fade in the sidebar once the container is placed.
                C_Timer.After(0, function()
                    if not ns._testMode then return end
                    local oc = ns._overlayContainer
                    if oc and oc:IsShown() and ns._testPanel then
                        ns._testPanel:ClearAllPoints()
                        ns._testPanel:SetPoint("RIGHT", oc, "LEFT", -20, 0)
                        ns._testPanel:SetAlpha(0)
                        ns._testPanel:Show()
                        local panelFadeAG = ns._testPanel:CreateAnimationGroup()
                        local panelFadeA = panelFadeAG:CreateAnimation("Alpha")
                        panelFadeA:SetFromAlpha(0); panelFadeA:SetToAlpha(1); panelFadeA:SetDuration(0.3)
                        ns._testPanel:SetAlpha(1)
                        panelFadeAG:Play()
                    end
                end)
            end
        end)

        local PANEL_W = 260
        local ROW_H = 32
        local PAD = 16
        local panel = CreateFrame("Frame", nil, testModeFrame)
        ns._testPanel = panel
        panel:SetSize(PANEL_W, 600)
        panel:SetPoint("LEFT", testModeFrame, "LEFT", 40, 0)
        panel:Hide()  -- shown once the overlay container is positioned
        panel:SetFrameLevel(testModeFrame:GetFrameLevel() + 5)
        local panelBg = panel:CreateTexture(nil, "BACKGROUND")
        panelBg:SetAllPoints(); panelBg:SetColorTexture(15/255, 17/255, 22/255, 0.9)
        EllesmereUI.MakeBorder(panel, 1, 1, 1, 0.1, PP)

        local function MakeFont(p, size, r, g, b, a)
            local fs = p:CreateFontString(nil, "OVERLAY")
            EllesmereUI.PrimeFontShadow(fs, true)
            fs:SetFont(fontPath, size, "")
            fs:SetTextColor(r or 1, g or 1, b or 1, a or 1)
            return fs
        end

        local cy = -PAD

        local function SectionHeader(text)
            cy = cy - 10
            local lbl = MakeFont(panel, 11, 1, 1, 1, 0.75)
            lbl:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, cy)
            lbl:SetText(EllesmereUI.L(text))
            local line = panel:CreateTexture(nil, "ARTWORK")
            line:SetHeight(1)
            line:SetPoint("LEFT", lbl, "RIGHT", 8, 0)
            line:SetPoint("RIGHT", panel, "RIGHT", -PAD, 0)
            line:SetColorTexture(1, 1, 1, 0.06)
            cy = cy - 15
        end

        -- Every checkbox refresher, re-run together for mutual exclusion.
        local allRefreshFns = {}
        local editGlow   -- shared edit-target glow, made on first use

        local function CheckboxRow(label, getVal, setVal, editTarget)
            local row = CreateFrame("Frame", nil, panel)
            row:SetSize(PANEL_W - PAD * 2, ROW_H)
            row:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, cy)
            row:SetFrameLevel(panel:GetFrameLevel() + 1)

            local cb = CreateFrame("CheckButton", nil, row)
            cb:SetSize(18, 18)
            cb:SetPoint("LEFT", row, "LEFT", 0, 0)

            local cbBg = cb:CreateTexture(nil, "BACKGROUND")
            cbBg:SetAllPoints(); cbBg:SetColorTexture(0.15, 0.15, 0.15, 1)
            EllesmereUI.MakeBorder(cb, 1, 1, 1, 0.2, PP)

            local checkMark = cb:CreateTexture(nil, "OVERLAY")
            checkMark:SetSize(12, 12)
            checkMark:SetPoint("CENTER")
            checkMark:SetColorTexture(accentColor.r, accentColor.g, accentColor.b, 1)

            local function Refresh()
                local v = getVal()
                checkMark:SetShown(v)
            end
            Refresh()

            local function DoToggle()
                setVal(not getVal())
                for _, fn in ipairs(allRefreshFns) do fn() end
                if ns._applyTestState then ns._applyTestState() end
                if ns.ShowPreview then ns.ShowPreview() end
            end

            cb:SetScript("OnClick", DoToggle)

            -- Label is clickable and toggles the checkbox.
            local lblBtn = CreateFrame("Button", nil, row)
            lblBtn:SetPoint("LEFT", cb, "RIGHT", 8, 0)
            lblBtn:SetPoint("RIGHT", row, "RIGHT", -50, 0)
            lblBtn:SetHeight(ROW_H)
            lblBtn:SetScript("OnClick", DoToggle)
            local lbl = MakeFont(lblBtn, 11, 1, 1, 1, 0.85)
            lbl:SetPoint("LEFT")
            lbl:SetText(EllesmereUI.L(label))

            if editTarget then
                local editBtn = CreateFrame("Button", nil, row)
                editBtn:SetSize(43, 22)
                editBtn:SetPoint("RIGHT", row, "RIGHT", 0, 0)
                editBtn:SetFrameLevel(row:GetFrameLevel() + 1)
                local eBg = editBtn:CreateTexture(nil, "BACKGROUND")
                eBg:SetAllPoints(); eBg:SetColorTexture(1, 1, 1, 0.05)
                local eLbl = MakeFont(editBtn, 10, 1, 1, 1, 0.4)
                eLbl:SetPoint("CENTER"); eLbl:SetText(EllesmereUI.L("Edit"))
                editBtn:SetScript("OnEnter", function()
                    eBg:SetColorTexture(1, 1, 1, 0.1); eLbl:SetAlpha(0.7)
                end)
                editBtn:SetScript("OnLeave", function()
                    eBg:SetColorTexture(1, 1, 1, 0.05); eLbl:SetAlpha(0.4)
                end)
                editBtn:SetScript("OnClick", function()
                    CloseTestMode()
                    if editTarget.page then
                        EllesmereUI:SelectPage(editTarget.page)
                        -- Scroll to + highlight the target row once the page builds.
                        if editTarget.key then
                            C_Timer.After(0.1, function()
                                local target = ns._editTargets and ns._editTargets[editTarget.key]
                                if not target then return end
                                local sf = EllesmereUI._scrollFrame
                                if sf then
                                    local _, _, _, _, rowY = target:GetPoint(1)
                                    if rowY then
                                        local scrollPos = math.max(0, math.abs(rowY) - 40)
                                        if EllesmereUI.SmoothScrollTo then EllesmereUI.SmoothScrollTo(scrollPos) end
                                    end
                                end
                                C_Timer.After(0.15, function()
                                    if not target:IsShown() then return end
                                    editGlow = editGlow or EllesmereUI.MakeSettingGlow({ color = EllesmereUI.ELLESMERE_GREEN })
                                    editGlow(target)
                                end)
                            end)
                        end
                    end
                end)
            end

            cy = cy - ROW_H
            allRefreshFns[#allRefreshFns + 1] = Refresh
            return cb, Refresh, row
        end

        local nonIndicatorRows = {}

        -- Test mode toggle state persists across open/close within a session.
        if not ns._testState then
            local specIdx = GetSpecialization and GetSpecialization()
            local specRole = specIdx and GetSpecializationRole and GetSpecializationRole(specIdx)
            ns._testState = {
                animateBars = false,
                absorbs = s.absorbStyle ~= "none",
                healAbsorbs = (s.healAbsorbStyle or "clean") ~= "none",
                healPrediction = s.healPrediction == true,
                threat = (s.threatBorderSize or 0) > 0 or (s.threatCustomBorder == true and ns.RF_CustomBorderOn(s)),
                reducedMaxHealth = false,
                dispels = false,
                debuffs = s.debuffFilter ~= "none",
                defensives = s.showDefensives or s.showExternals or false,
                buffs = true,
                indicators = false,
            }
        end
        local testState = ns._testState

        ns._applyTestState = function()
            local indOn = testState.indicators
            ns._indicatorsVisible = indOn
            -- Indicators suppress every other preview WITHOUT altering testState.
            ns._dispelsVisible = not indOn and testState.dispels
            ns._debuffsPreviewVisible = not indOn and testState.debuffs
            ns._defensivesPreviewVisible = not indOn and testState.defensives
            ns._testReducedMaxHealth = not indOn and testState.reducedMaxHealth
            ns._testAbsorbs = not indOn and testState.absorbs
            ns._testHealAbsorbs = not indOn and testState.healAbsorbs
            ns._testHealPrediction = not indOn and testState.healPrediction
            ns._testThreat = not indOn and testState.threat
            ns._testBuffsVisible = not indOn and testState.buffs
            local wantAnim = not indOn and testState.animateBars
            if wantAnim then
                if ns._startHealthAnim and not ns._healthAnimActive then ns._startHealthAnim() end
            else
                if ns._stopHealthAnim and ns._healthAnimActive then ns._stopHealthAnim() end
            end
            -- Restart so debuff/defensive icons hide/show immediately.
            if ns.RestartPvAuraTicker then ns.RestartPvAuraTicker() end
            -- Always stop first so re-init picks up new preview frames.
            if ns.StopPvBuffTicker then ns.StopPvBuffTicker() end
            local wantBuffs = not indOn and testState.buffs
            if wantBuffs and ns.StartPvBuffTicker then
                ns.StartPvBuffTicker()
            end
        end
        ns._applyTestState()

        ---------------------------------------------------------------
        --  HEALTH & POWER BARS
        ---------------------------------------------------------------
        SectionHeader("HEALTH & POWER BARS")

        do local _, _, r = CheckboxRow("Animate Bars", function() return testState.animateBars end,
            function(v) testState.animateBars = v end,
            { page = PAGE_MAIN, key = "animateBars" })
            nonIndicatorRows[#nonIndicatorRows + 1] = r end

        do local _, _, r = CheckboxRow("Absorbs", function() return testState.absorbs end,
            function(v) testState.absorbs = v end,
            { page = PAGE_MAIN, key = "absorbs" })
            nonIndicatorRows[#nonIndicatorRows + 1] = r end

        do local _, _, r = CheckboxRow("Healing Absorbs", function() return testState.healAbsorbs end,
            function(v) testState.healAbsorbs = v end,
            { page = PAGE_MAIN, key = "healAbsorbs" })
            nonIndicatorRows[#nonIndicatorRows + 1] = r end

        do local _, _, r = CheckboxRow("Heal Prediction", function() return testState.healPrediction end,
            function(v) testState.healPrediction = v end,
            { page = PAGE_MAIN, key = "healPrediction" })
            nonIndicatorRows[#nonIndicatorRows + 1] = r end

        do local _, _, r = CheckboxRow("Threat Indicator", function() return testState.threat end,
            function(v) testState.threat = v end,
            { page = PAGE_MAIN, key = "threat" })
            nonIndicatorRows[#nonIndicatorRows + 1] = r end

        do local _, _, r = CheckboxRow("Reduced Max Health", function() return testState.reducedMaxHealth end,
            function(v) testState.reducedMaxHealth = v end,
            { page = PAGE_MAIN, key = "absorbs" })
            nonIndicatorRows[#nonIndicatorRows + 1] = r end

        ---------------------------------------------------------------
        --  AURAS
        ---------------------------------------------------------------
        SectionHeader("AURAS")

        do local _, _, r = CheckboxRow("Dispels", function() return testState.dispels end,
            function(v) testState.dispels = v; ns._applyTestState() end,
            { page = PAGE_MAIN })
            nonIndicatorRows[#nonIndicatorRows + 1] = r end

        do local _, _, r = CheckboxRow("Debuffs", function() return testState.debuffs end,
            function(v) testState.debuffs = v; ns._applyTestState() end,
            { page = PAGE_DM })
            nonIndicatorRows[#nonIndicatorRows + 1] = r end

        do local _, _, r = CheckboxRow("Defensives & Externals", function() return testState.defensives end,
            function(v) testState.defensives = v; ns._applyTestState() end,
            { page = PAGE_BUFFS })
            nonIndicatorRows[#nonIndicatorRows + 1] = r end

        do local _, _, r = CheckboxRow("Configured Buffs", function() return testState.buffs end,
            function(v) testState.buffs = v; ns._applyTestState() end,
            { page = PAGE_BUFFS })
            nonIndicatorRows[#nonIndicatorRows + 1] = r end

        ---------------------------------------------------------------
        --  INDICATORS
        ---------------------------------------------------------------
        SectionHeader("INDICATORS")

        local function SetNonIndicatorRowsEnabled(enabled)
            for _, row2 in ipairs(nonIndicatorRows) do
                row2:SetAlpha(enabled and 1 or 0.35)
                row2:EnableMouse(enabled)
            end
        end

        CheckboxRow("Show All", function() return testState.indicators end,
            function(v)
                testState.indicators = v
                SetNonIndicatorRowsEnabled(not v)
                ns._applyTestState()
            end,
            { page = PAGE_MAIN })

        -- Indicators may already be on from a previous session.
        if testState.indicators then SetNonIndicatorRowsEnabled(false) end

        -- Content height plus room for the close button.
        panel:SetHeight(math.abs(cy) + 32 + PAD * 3)

        local closeBtn = CreateFrame("Button", nil, panel)
        closeBtn:SetSize(PANEL_W - PAD * 2, 32)
        closeBtn:SetPoint("BOTTOM", panel, "BOTTOM", 0, PAD)
        closeBtn:SetFrameLevel(panel:GetFrameLevel() + 1)
        local clBg = closeBtn:CreateTexture(nil, "BACKGROUND")
        clBg:SetAllPoints(); clBg:SetColorTexture(0.25, 0.25, 0.25, 0.6)
        local clLbl = MakeFont(closeBtn, 12, 1, 1, 1, 0.7)
        clLbl:SetPoint("CENTER"); clLbl:SetText(EllesmereUI.L("Close"))
        closeBtn:SetScript("OnEnter", function() clBg:SetColorTexture(0.35, 0.35, 0.35, 0.8); clLbl:SetAlpha(1) end)
        closeBtn:SetScript("OnLeave", function() clBg:SetColorTexture(0.25, 0.25, 0.25, 0.6); clLbl:SetAlpha(0.7) end)
        closeBtn:SetScript("OnClick", CloseTestMode)

        -- Dead space closes.
        testModeFrame:SetScript("OnMouseDown", function()
            local oc = ns._overlayContainer
            if (panel and panel:IsMouseOver()) or (oc and oc:IsMouseOver()) then return end
            CloseTestMode()
        end)

        testModeFrame:SetScript("OnKeyDown", function(self, key)
            if key == "ESCAPE" then
                self:SetPropagateKeyboardInput(false)
                CloseTestMode()
            else
                self:SetPropagateKeyboardInput(true)
            end
        end)
        testModeFrame:EnableKeyboard(true)
    end

    ns.OpenTestMode = OpenTestMode
    ns.CloseTestMode = CloseTestMode

    -- Test button appears on the tab bar while the RF module is selected.
    local testTabBtn = nil
    if EllesmereUI.SelectModule then
        hooksecurefunc(EllesmereUI, "SelectModule", function(_, folderName)
            if folderName == "EllesmereUIRaidFrames" then
                local tb = EllesmereUI._tabBar
                if not tb or not tb._tabButtons then return end
                local lastBtn = tb._tabButtons[#tb._tabButtons]
                if not lastBtn then return end

                if testTabBtn then
                    -- The tab bar rebuilds on module switch, so re-anchor.
                    testTabBtn:SetParent(tb)
                    testTabBtn:ClearAllPoints()
                    testTabBtn:SetPoint("BOTTOMLEFT", lastBtn, "BOTTOMRIGHT", 6, 0)
                    testTabBtn:Show()
                    return
                end

                testTabBtn = CreateFrame("Button", nil, tb)
                testTabBtn:SetHeight(40)
                testTabBtn:SetFrameLevel(tb:GetFrameLevel() + 1)

                local PP2 = EllesmereUI.PanelPP or EllesmereUI.PP
                local label = EllesmereUI.MakeFont(testTabBtn, 16, nil,
                    EllesmereUI.TEXT_DIM_R or 0.65, EllesmereUI.TEXT_DIM_G or 0.65,
                    EllesmereUI.TEXT_DIM_B or 0.65, EllesmereUI.TEXT_DIM_A or 0.65)
                label:SetPoint("CENTER", 0, 0)
                label:SetText(EllesmereUI.L("Full Preview"))
                testTabBtn._label = label

                local textW = label:GetStringWidth() or 30
                testTabBtn:SetWidth(textW + 30)
                testTabBtn:SetPoint("BOTTOMLEFT", lastBtn, "BOTTOMRIGHT", 6, 0)

                testTabBtn:SetScript("OnEnter", function(self) self._label:SetTextColor(1, 1, 1, 0.86) end)
                testTabBtn:SetScript("OnLeave", function(self)
                    self._label:SetTextColor(
                        EllesmereUI.TEXT_DIM_R or 0.65, EllesmereUI.TEXT_DIM_G or 0.65,
                        EllesmereUI.TEXT_DIM_B or 0.65, EllesmereUI.TEXT_DIM_A or 0.65)
                end)
                testTabBtn:SetScript("OnClick", function() OpenTestMode() end)
            else
                if testTabBtn then testTabBtn:Hide() end
            end
        end)
    end

    ---------------------------------------------------------------------------
    --  Register module
    ---------------------------------------------------------------------------
    local rfSearchTerms = {
        "raid", "frames", "group", "health", "power", "absorb", "shield",
        "debuff", "dispel", "threat", "role", "marker", "ready", "check",
        "border", "range", "tooltip", "layout", "spacing", "buff", "manager",
        "strata", "layer", "overlap",
        "click", "cast", "binding", "keybind", "spell", "macro", "mouseover",
    }

    -- Drops the BM / DM / CC roots (built on the shared scroll frame, not a
    -- page wrapper) except keepPage's. popups: true = also hide the Add New,
    -- DM add and BM2 editor/menu popups; "dm" = those DM/BM2 popups only when
    -- the DM root drops. stripAlways: clear the CC spell strip (parented to
    -- the panel, not the CC root) even with no CC root.
    local function DropManagerRoots(keepPage, popups, stripAlways)
        if popups == true and ns._addNewPopup then ns._addNewPopup:Hide() end
        if keepPage ~= PAGE_BUFFS and ns._bmRoot then
            ns._bmRoot:Hide(); ns._bmRoot:SetParent(nil); ns._bmRoot = nil
        end
        local dropDm = keepPage ~= PAGE_DM and ns._dmRoot
        if popups == true or (popups == "dm" and dropDm) then
            if ns._dmAddPopup then ns._dmAddPopup:Hide() end
            if ns._bm2FilterEditor then ns._bm2FilterEditor:Hide(); ns._bm2FilterEditor = nil end
            if ns._bm2Menu then ns._bm2Menu:Hide(); ns._bm2Menu = nil end
        end
        if dropDm then
            ns._dmRoot:Hide(); ns._dmRoot:SetParent(nil); ns._dmRoot = nil
        end
        local dropCc = keepPage ~= PAGE_CLICKCAST and ns._ccRoot
        if dropCc then
            if ns._ccGridPopup then ns._ccGridPopup:Hide(); ns._ccGridPopup = nil end
            if ns._ccSpecPopup then ns._ccSpecPopup:Hide(); ns._ccSpecPopup = nil end
            if ns._ccQBPopup then ns._ccQBPopup:Hide(); ns._ccQBPopup = nil end
            ns._ccRoot:Hide(); ns._ccRoot:SetParent(nil); ns._ccRoot = nil
        end
        if (dropCc or stripAlways) and ns._ccSpellStrip then
            ns._ccSpellStrip:Hide(); ns._ccSpellStrip:SetParent(nil); ns._ccSpellStrip = nil
        end
    end

    EllesmereUI:RegisterModule("EllesmereUIRaidFrames", {
        title       = "Raid Frames",
        description = "Configure raid frame appearance and behavior.",
        -- No Auras page: debuffs and defensives/externals live in the managers.
        pages       = { PAGE_MAIN, PAGE_PARTY, PAGE_BUFFS, PAGE_DM, PAGE_CLICKCAST },
        searchTerms = rfSearchTerms,
        buildPage   = function(pageName, parent, yOffset)
            -- The cleanup/preview logic below acts on live state (BM/CC roots, raid/party preview overlays over the player's real frames) keyed only on the pageName being built, not what the player is actually looking at. An off-screen search pre-build cycles pageName through every page in `pages`, so NONE of it may run here.
            -- PAGE_BUFFS / PAGE_CLICKCAST go further: their builders (BuildBuffManagerPage -> ns.BM_BuildPage, ns.CC_BuildPage) bypass `parent` and build directly onto the live shared EllesmereUI._scrollFrame, so building them here would inject visible UI over whatever is on screen. Skip them; they index normally on the player's first live visit.
            --
            -- _partyCtx (read by SGet/SSet/SVal in the value closures) is left
            -- untouched: this hidden pass's widgets and closures are discarded
            -- with the wrapper and never invoked, so only the live path needs it.
            if EllesmereUI._prebuilding then
                if pageName == PAGE_MAIN then
                    return BuildMainPage(pageName, parent, yOffset)
                elseif pageName == PAGE_PARTY then
                    return BuildPartyPage(pageName, parent, yOffset)
                end
                return
            end
            -- Drop the BM / DM / CC roots when switching away.
            DropManagerRoots(pageName)
            if pageName == PAGE_MAIN then
                local mode = db.profile.previewMode or "overlay"
                -- Skip-restore keeps real party frames hidden under the preview so they don't flash on return to the party tab; restore only for "none", where real frames are meant to be visible.
                if ns.HidePartyPreview then ns.HidePartyPreview(mode ~= "none") end
                if mode ~= "none" and ns.ShowPreview then
                    C_Timer.After(0, function() if ns.ShowPreview then ns.ShowPreview() end end)
                elseif mode == "none" and ns.HidePreview then
                    ns.HidePreview()
                end
            elseif pageName == PAGE_PARTY then
                local mode = db.profile.previewMode or "overlay"
                -- Skip-restore avoids a one-frame flash of the real frames before the deferred ShowPartyPreview.
                if ns.HidePreview then ns.HidePreview(mode ~= "none") end
                if mode ~= "none" and ns.ShowPartyPreview then
                    C_Timer.After(0, function() if ns.ShowPartyPreview then ns.ShowPartyPreview() end end)
                elseif mode == "none" and ns.HidePartyPreview then
                    ns.HidePartyPreview()
                end
            else
                -- BUFFS / CLICKCAST show no preview, so FULL restore both real containers: a skip-restore here would strand the party container under the hidden preview parent with nothing to reparent it back.
                if ns.HidePreview then ns.HidePreview() end
                if ns.HidePartyPreview then ns.HidePartyPreview() end
            end
            -- Set party context BEFORE building any page so SGet/SSet/SVal read the correct keys during widget construction.
            optState._partyCtx = (pageName == PAGE_PARTY)

            if pageName == PAGE_MAIN then
                return BuildMainPage(pageName, parent, yOffset)
            elseif pageName == PAGE_PARTY then
                return BuildPartyPage(pageName, parent, yOffset)
            elseif pageName == PAGE_DM then
                if ns.DMP_BuildPage then
                    return ns.DMP_BuildPage(pageName, parent, yOffset)
                end
                return math.abs(yOffset)
            elseif pageName == PAGE_BUFFS then
                return BuildBuffManagerPage(pageName, parent, yOffset)
            elseif pageName == PAGE_CLICKCAST then
                if ns.CC_BuildPage then
                    return ns.CC_BuildPage(pageName, parent, yOffset)
                end
                return math.abs(yOffset)
            end
        end,
        onPageCacheRestore = function(pageName)
            -- Mirrors buildPage's root cleanup: fires INSTEAD of buildPage when the target page is already cached.
            -- Without it, switching from Buffs/HoverCast to a cached page never hides ns._bmRoot/ns._ccRoot, which are built onto the shared live scroll frame (not a per-page wrapper) and would stay stuck over the restored page.
            DropManagerRoots(pageName)
            if pageName == PAGE_MAIN then
                local mode = db.profile.previewMode or "overlay"
                -- Skip-restore; see buildPage.
                if ns.HidePartyPreview then ns.HidePartyPreview(mode ~= "none") end
                if mode ~= "none" and ns.ShowPreview then
                    C_Timer.After(0, function() if ns.ShowPreview then ns.ShowPreview() end end)
                elseif mode == "none" and ns.HidePreview then
                    ns.HidePreview()
                end
            elseif pageName == PAGE_PARTY then
                local mode = db.profile.previewMode or "overlay"
                -- Skip-restore avoids a one-frame flash of the real frames before the deferred ShowPartyPreview.
                if ns.HidePreview then ns.HidePreview(mode ~= "none") end
                if mode ~= "none" and ns.ShowPartyPreview then
                    C_Timer.After(0, function() if ns.ShowPartyPreview then ns.ShowPartyPreview() end end)
                elseif mode == "none" and ns.HidePartyPreview then
                    ns.HidePartyPreview()
                end
            elseif pageName == PAGE_BUFFS then
                if ns.HidePreview then ns.HidePreview() end
                if ns.HidePartyPreview then ns.HidePartyPreview() end
                if not ns._bmRoot then
                    C_Timer.After(0, function()
                        if EllesmereUI:GetActiveModule() == "EllesmereUIRaidFrames" then
                            BuildBuffManagerPage(pageName, nil, -6)
                        end
                    end)
                end
            elseif pageName == PAGE_DM then
                if ns.HidePreview then ns.HidePreview() end
                if ns.HidePartyPreview then ns.HidePartyPreview() end
                if not ns._dmRoot then
                    C_Timer.After(0, function()
                        if EllesmereUI:GetActiveModule() == "EllesmereUIRaidFrames" and ns.DMP_BuildPage then
                            ns.DMP_BuildPage(PAGE_DM, nil, -6)
                        end
                    end)
                end
            elseif pageName == PAGE_CLICKCAST then
                if ns.HidePreview then ns.HidePreview() end
                if not ns._ccRoot then
                    C_Timer.After(0, function()
                        if EllesmereUI:GetActiveModule() == "EllesmereUIRaidFrames" and ns.CC_BuildPage then
                            ns.CC_BuildPage(PAGE_CLICKCAST, nil, -6)
                        end
                    end)
                end
            end
        end,
        onReset = function()
            -- Clearing the first-install flag re-captures position on reload.
            if db.sv then db.sv._capturedOnce_RF = nil end
            db:ResetProfile()
            -- No reload here: the footer Reset popup (reload = true) reloads after this returns.
        end,
        -- Tears down all 6 Raid Frames preview mechanisms on cross-module
        -- switch (Real/Party/Size/HealthAnim/PowerAnim/HM previews).
        onModuleLeave = function()
            if ns.HidePreview then ns.HidePreview() end
            if ns.HidePartyPreview then ns.HidePartyPreview() end
            ns._sizePreviewTier = nil
            if ns._HideSizePreview then ns._HideSizePreview() end
            if ns._healthAnimActive and ns.StopHealthAnim then ns.StopHealthAnim() end
            if ns._powerAnimActive and ns.StopPowerAnim then ns.StopPowerAnim() end
            if ns._hmPreview and ns.HM_SetPreview then ns.HM_SetPreview(false) end
        end,
    })

    -- Re-open on an RF page: show preview / rebuild BM.
    EllesmereUI:RegisterOnShow(function()
        if EllesmereUI:GetActiveModule() == "EllesmereUIRaidFrames" then
            local page = EllesmereUI:GetActivePage()
            if page == PAGE_MAIN then
                local mode = db.profile.previewMode or "overlay"
                if mode ~= "none" and ns.ShowPreview then ns.ShowPreview() end
            elseif page == PAGE_PARTY then
                local mode = db.profile.previewMode or "overlay"
                if mode ~= "none" and ns.ShowPartyPreview then ns.ShowPartyPreview() end
            elseif page == PAGE_BUFFS then
                -- Panel opening on Buffs counts as entering it (WoW Forever: All Specs).
                ns.BM_EnterAllSpecs()
                if not ns._bmRoot then
                    C_Timer.After(0, function()
                        if EllesmereUI:GetActiveModule() == "EllesmereUIRaidFrames" then
                            BuildBuffManagerPage(PAGE_BUFFS, nil, -6)
                        end
                    end)
                end
            elseif page == PAGE_DM then
                if not ns._dmRoot then
                    C_Timer.After(0, function()
                        if EllesmereUI:GetActiveModule() == "EllesmereUIRaidFrames" and ns.DMP_BuildPage then
                            ns.DMP_BuildPage(PAGE_DM, nil, -6)
                        end
                    end)
                end
            elseif page == PAGE_CLICKCAST then
                if not ns._ccRoot then
                    C_Timer.After(0, function()
                        if EllesmereUI:GetActiveModule() == "EllesmereUIRaidFrames" and ns.CC_BuildPage then
                            ns.CC_BuildPage(PAGE_CLICKCAST, nil, -6)
                        end
                    end)
                end
            end
        end
    end)
    -- Panel close: hide preview and clean up BM/CC.
    if EllesmereUI.RegisterOnHide then
        EllesmereUI:RegisterOnHide(function()
            if ns._rfEyeHintTip then ns._rfEyeHintTip:Hide() end
            -- HARD INVARIANT against "frames vanish after closing options": both real containers get reparented to UIParent and their visibility recomputed even if a skip-restore tab swap or a post-close deferred ShowPreview orphaned one under the hidden preview parent.
            -- Self-defers to PLAYER_REGEN_ENABLED in combat.
            if ns.EnsureRealFramesRestored then ns.EnsureRealFramesRestored() end
            if ns._sizePreviewTier then
                ns._sizePreviewTier = nil
                if ns._HideSizePreview then ns._HideSizePreview() end
            end
            -- BM root + Add New popup: the popup is DIALOG strata and otherwise persists after close.
            DropManagerRoots(nil, true, true)
        end)
    end

    -- HideAllChildren callback: BM/CC intentionally bypass the scroll child, so their scrollFrame-parented roots need explicit cleanup.
    EllesmereUI._hideScrollFrameRoots = function()
        DropManagerRoots(nil, true, true)
    end

    -- Module switch: drop the BM/CC roots and hide the preview.
    if EllesmereUI.SelectModule then
        hooksecurefunc(EllesmereUI, "SelectModule", function(_, folderName)
            if folderName ~= "EllesmereUIRaidFrames" then
                if ns._rfEyeHintTip then ns._rfEyeHintTip:Hide() end
                -- Tear down previews and guarantee the real containers return to UIParent, including the orphaned-flag-false cases.
                if ns.EnsureRealFramesRestored then ns.EnsureRealFramesRestored() end
                DropManagerRoots(nil, true)
            end
        end)
    end

    -- Party Frames search excludes raid-synced sections (their controls live on the Raid tabs). Maps section HEADER TEXT to sync key:
    -- KEEP IN SYNC with the SectionHeader names in the builders and ns._PARTY_SECTION_ORDER.
    ns._PARTY_SEARCH_SECTION_KEY = {
        ["HEALTH BAR"]             = "healthBar",
        ["ABSORBS"]                = "absorbs",
        ["POWER BAR"]              = "powerBar",
        ["TEXT DISPLAY"]           = "textDisplay",
        ["INDICATORS"]             = "indicators",
        ["DISPELS"]                = "dispels",
        ["TOP NAME BAR"]           = "topNameBar",
        ["EXTRAS"]                 = "rangeTooltip",
    }
    ns._PartySearchExclude = function(sectionName)
        local key = ns._PARTY_SEARCH_SECTION_KEY[sectionName]
        if not key then return false end
        if not db or not db.profile then return false end
        local ss = db.profile.partySyncSections
        return (not ss) or ss[key] ~= false  -- synced (default = all synced)
    end

    -- Party sync overlays track the inline search: hidden while a search is active (those sections are excluded), restored to their per-section sync state when empty. Overlays carry _searchIgnore so the generic search never re-anchors them.
    ns._PartySearchOverlaySync = function(query)
        if not ns._syncOverlays then return end
        local searching = query and query ~= ""
        local ss = db and db.profile and db.profile.partySyncSections
        for key, ov in pairs(ns._syncOverlays) do
            if searching then
                ov:Hide()
            elseif (not ss) or ss[key] ~= false then
                ov:Show()
            else
                ov:Hide()
            end
        end
    end

    -- Page switch cleanup within RF. PRE-hook (wrap, not hooksecurefunc): _partyCtx must be set BEFORE SelectPage refreshes widget values.
    if EllesmereUI.SelectPage then
        local origSelectPage = EllesmereUI.SelectPage
        EllesmereUI.SelectPage = function(self, pageName, ...)
            optState._partyCtx = (pageName == PAGE_PARTY)
            -- Entering Buffs from another page (not a rebuild while on it): WoW Forever opens it on All Specs.
            if pageName == PAGE_BUFFS and EllesmereUI:GetActivePage() ~= PAGE_BUFFS then ns.BM_EnterAllSpecs() end
            -- Party tab excludes synced sections from inline search; cleared on every other page (any module) so the hook can never leak.
            EllesmereUI._searchExcludeSection = (pageName == PAGE_PARTY) and ns._PartySearchExclude or nil
            EllesmereUI._onInlineSearch = (pageName == PAGE_PARTY) and ns._PartySearchOverlaySync or nil
            local result = origSelectPage(self, pageName, ...)
            -- Re-sync overlays on entering the party tab: a prior search may have hidden them, and the search box clears on page change.
            if pageName == PAGE_PARTY and ns._PartySearchOverlaySync then
                ns._PartySearchOverlaySync("")
            end
            if ns._rfEyeHintTip then
                if pageName == PAGE_MAIN then ns._rfEyeHintTip:Show()
                else ns._rfEyeHintTip:Hide() end
            end
            -- Every eyeball toggle resets on tab change.
            ns._indicatorsVisible = false
            ns._dispelsVisible = false
            ns._defensivesPreviewVisible = false
            ns._debuffsPreviewVisible = false
            ns._absorbsPreviewVisible = false
            -- The health/power tickers live on ns, so one cancel covers whichever preview built them.
            ns._healthAnimActive = false
            ns._powerAnimActive = false
            if ns._healthAnimTicker then ns._healthAnimTicker:Cancel(); ns._healthAnimTicker = nil end
            if ns._powerAnimTicker then ns._powerAnimTicker:Cancel(); ns._powerAnimTicker = nil end
            ns._bmFrameEffectsVisible = false
            if ns.RestartPvAuraTicker then ns.RestartPvAuraTicker() end
            if ns.ResetPreviewRandomization then ns.ResetPreviewRandomization() end

            -- Manager/HoverCast tabs show no raid frame preview.
            if pageName == PAGE_BUFFS or pageName == PAGE_DM or pageName == PAGE_CLICKCAST then
                if ns.HidePreview then ns.HidePreview() end
            end
            if pageName == PAGE_MAIN then
                local mode = db.profile.previewMode or "overlay"
                if mode ~= "none" and ns.ShowPreview then
                    C_Timer.After(0, function() if ns.ShowPreview then ns.ShowPreview() end end)
                end
            end
            -- Drop the BM / DM / CC roots when switching away.
            DropManagerRoots(pageName, "dm")
            return result
        end
    end

    ---------------------------------------------------------------------------
    --  Slash command
    ---------------------------------------------------------------------------
    SLASH_ELLESMERERAIDFRAMES1 = "/erf"
    SlashCmdList.ELLESMERERAIDFRAMES = function(msg)
        if InCombatLockdown and InCombatLockdown() then
            print("Cannot open options in combat")
            return
        end
        if msg == "reset" then
            db:ResetProfile()
            EllesmereUI.RequestReload()
            return
        end
        EllesmereUI:ShowModule("EllesmereUIRaidFrames")
    end
    end -- ns._InitEUIModule

    -- SetupOptionsPanel may already have run before PLAYER_LOGIN.
    if ns.db then
        ns._InitEUIModule()
    end
end)
-- LoadOnDemand: this addon loads after PLAYER_LOGIN, so the event above will never fire; run the init now.
if IsLoggedIn() then initFrame:GetScript("OnEvent")(initFrame) end



