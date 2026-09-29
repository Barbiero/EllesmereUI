if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EllesmereUICooldownManager_Options.lua
--  Registers CDM Effects module with EllesmereUI
--  Tab 1: CDM Bars  (Bar Glows + Tracking Bars disabled pending rewrite)
-------------------------------------------------------------------------------
local ADDON_NAME = "EllesmereUICooldownManager"
local ns = EllesmereUI._ModuleNS[ADDON_NAME]  -- module namespace (published by the module at its load)
if not ns then return end  -- module disabled: no options page

-- Controller cursor: a hand-built popup (named dimmer over its panel) joins the
-- controller cursor and answers controller Back from its first open with a
-- controller in use; until then nothing is registered or hooked. The panel
-- stays a blocker without being a cursor stop, closeBtn is what the
-- controller's cancel button presses, and onEscape (nil = hide the dimmer) is
-- what Back runs. Call it just before the dimmer's Show. On ns: shared with the
-- Talent Conditions popup, and no main-chunk local.
function ns.PadPopupOpen(dimmer, panel, closeBtn, onEscape)
    if dimmer._padReg or not EllesmereUI.PadInUse() then return end
    dimmer._padReg = true
    EllesmereUI.PadHint(panel, "nodepass")
    if closeBtn then panel.CloseButton = closeBtn end
    EllesmereUI.RegisterEscapeClose(dimmer, { padOnly = true, onEscape = onEscape })
end

-- Gates a row under Blizzard Style only: the classic kit draws chrome round
-- the user's own fill and background, so those settings stay live there.
local function GateBlizzardOnly(key, cfg)
    if EllesmereUI.BlizzStyle.Active(key) == "blizzard" then
        return EllesmereUI.BlizzStyle.Gate(key, cfg)
    end
    return cfg
end

local PAGE_BAR_GLOWS    = "Bar Glows"
local PAGE_BUFF_BARS    = "Tracking Bars"
local PAGE_CDM_BARS     = "CDM Bars"
local PAGE_ROTATION_ICON = "Rotation Assist Icon"

local PAGE_UNLOCK       = "Unlock Mode"

local SEC_MAPPINGS   = "GLOW MAPPINGS"
local SEC_LAYOUT     = "LAYOUT"
local SEC_APPEARANCE = "APPEARANCE"
local SEC_FILTER     = "FILTER"
local SEC_BEHAVIOR   = "BEHAVIOR"

local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_LOGIN")

    if not EllesmereUI or not EllesmereUI.RegisterModule then return end
    local PP = EllesmereUI.PanelPP

    local db
    C_Timer.After(0, function() db = _G._ECME_AceDB end)

    local function DB()
        if not db then db = _G._ECME_AceDB end
        return db and db.profile
    end

    local function Refresh()
        if _G._ECME_Apply then _G._ECME_Apply() end
    end

    -- Add/RemoveTrackedSpell already rebuild routes + queue reanchor; force an immediate
    -- CollectAndReanchor (not the throttled queue), then rebuild the page with
    -- _skipNextApplyRebuild to skip the redundant FullCDMRebuild.
    local function RefreshCDPreview()
        if ns.CollectAndReanchor then ns.CollectAndReanchor() end
        ns._skipNextApplyRebuild = true
        C_Timer.After(0.05, function()
            if ns.CDMApplyVisibility then ns.CDMApplyVisibility() end
            if ns.ApplyCachedKeybinds then ns.ApplyCachedKeybinds() end
            EllesmereUI:RefreshPage(true)
        end)
    end

    -- Inline text input helper (no W:InputBox exists)
    local FONT_PATH = (EllesmereUI.GetFontPath("cdm"))
        or "Interface\\AddOns\\EllesmereUI\\media\\fonts\\Expressway.TTF"

    local GetCDMOptOutline = EllesmereUI.GetFontOutlineFlag

    -- Auto-widens break-out menus (flyouts/Apply-to strip/item pickers) to the longest
    -- RENDERED caption so text doesn't overflow (option rows) or ellipsize (item rows):
    -- grow-only from nominal width, capped at MAX_W (tooltip/ellipsis fallback past cap).
    -- pad = text inset + right-edge furniture; hidden rows count too -- never resize mid-hover/typing.
    local function FitMenuWidth(labels, nominalW, pad)
        local MAX_W = 340
        local widest = 0
        for i = 1, #labels do
            local fs = labels[i]
            local w = fs and fs:GetStringWidth() or 0
            if w > widest then widest = w end
        end
        local fit = math.ceil(widest + (pad or 40))
        if fit < nominalW then fit = nominalW end
        if fit > MAX_W then fit = MAX_W end
        return fit
    end
    local SetPVFont = EllesmereUI.ApplyModuleFont

    ---------------------------------------------------------------------------
    --  Buff spell list from viewer pool (Bar Glows page glow assignments)
    ---------------------------------------------------------------------------
    local BAR_BUTTON_PREFIXES = {
        [1] = "ActionButton",
        [2] = "MultiBarBottomLeftButton",
        [3] = "MultiBarBottomRightButton",
        [4] = "MultiBarRightButton",
        [5] = "MultiBarLeftButton",
        [6] = "MultiBar5Button",
        [7] = "MultiBar6Button",
        [8] = "MultiBar7Button",
    }

    -- Action bar shape masks/borders (for preview rendering)
    local AB_SHAPE_MASKS = EllesmereUI.SHAPE_MASKS
    local AB_SHAPE_BORDERS = EllesmereUI.SHAPE_BORDERS

    -- Action bar entries (1-8) are stable; CDM bar entries are built dynamically via
    -- BuildBGTargetList since users can add extra cooldown/utility/buff bars beyond defaults.
    local BG_ACTION_BAR_LABELS = {
        [1] = "Action Bar 1 (Main)", [2] = "Action Bar 2", [3] = "Action Bar 3", [4] = "Action Bar 4",
        [5] = "Action Bar 5", [6] = "Action Bar 6", [7] = "Action Bar 7", [8] = "Action Bar 8",
    }

    -- Legacy installs saved selectedBar as 101/102 for the default cooldowns/
    -- utility CDM bars; normalize to the bar key string (new saves use the key).
    local function NormalizeSelectedBar(sel)
        if sel == 101 then return "cooldowns" end
        if sel == 102 then return "utility" end
        return sel
    end

    -- Live dropdown list: {value,label} in display order -- CDM bars from p.cdmBars.bars
    -- (skipping ghost/custom_buff) then action bars 1-8; value = bar key string or int 1-8.
    local function BuildBGTargetList()
        local list = {}
        local p = ns.ECME and ns.ECME.db and ns.ECME.db.profile
        if p and p.cdmBars and p.cdmBars.bars then
            for _, bd in ipairs(p.cdmBars.bars) do
                if bd.enabled and not bd.isGhostBar
                   and bd.barType ~= "custom_buff" then
                    list[#list + 1] = {
                        value = bd.key,
                        label = EllesmereUI.Lf("CDM Bar - %s", EllesmereUI.L(bd.name or bd.key)),
                    }
                end
            end
        end
        for i = 1, 8 do
            list[#list + 1] = { value = i, label = EllesmereUI.L(BG_ACTION_BAR_LABELS[i]) }
        end
        return list
    end

    local function GetBGTargetLabel(sel)
        sel = NormalizeSelectedBar(sel)
        if type(sel) == "number" then
            return EllesmereUI.L(BG_ACTION_BAR_LABELS[sel] or ("Action Bar " .. sel))
        end
        local p = ns.ECME and ns.ECME.db and ns.ECME.db.profile
        if p and p.cdmBars and p.cdmBars.bars then
            for _, bd in ipairs(p.cdmBars.bars) do
                if bd.key == sel then return EllesmereUI.Lf("CDM Bar - %s", EllesmereUI.L(bd.name or bd.key)) end
            end
        end
        return tostring(sel)
    end

    -- Presets/custom spell IDs/racials/trinkets/custom buffs are EllesmereUI-injected
    -- icons (no stable cooldownID), so they are NOT glow-assignable -- the Bar Glows preview leaves them inert.
    local function IsNonGlowableCDMIcon(frame)
        if not frame then return false end
        -- Overflow-diverted icons are session-only: their glow identity/slot-index
        -- fallback key belongs to the source bar, so they aren't listed while diverted
        -- (existing cdm_-keyed glows still RENDER -- the render pass is key-driven, not list-driven).
        if ns.CdmFrameOverflowBar and ns.CdmFrameOverflowBar(frame) then return true end
        return (frame._isRacialFrame or frame._isTrinketFrame
            or frame._isPresetFrame or frame._isItemPresetFrame
            or frame._isCustomSpellFrame or frame._isCustomBuffFrame) and true or false
    end

    -- True if any icon on a buff bar has per-icon "Always Show Buff" = on (or
    -- "missing" -- Show When Missing also injects inactive placeholders), so
    -- it's mutually exclusive with "Keep Buffs in Same Place".
    local function AnyIconAlwaysShowOn(barKey)
        -- Per-spell entries live in the spec FAMILY store; rawget skips bar-tier
        -- inheritance (checked separately below).
        local st = ns.GetSpellSettingsStore and ns.GetSpellSettingsStore(barKey)
        if st then
            for _, ss in pairs(st) do
                if type(ss) == "table" then
                    local as = rawget(ss, "alwaysShow")
                    if as == "on" or as == "missing" then return true end
                end
            end
        end
        local sd = ns.GetBarSpellData and ns.GetBarSpellData(barKey)
        local tier = ns.GetBarTierSettings and ns.GetBarTierSettings(sd, barKey)
        if tier and (tier.alwaysShow == "on" or tier.alwaysShow == "missing") then return true end
        return false
    end

    local BG_MODE_VALUES = { ACTIVE = "Buff Active", MISSING = "Buff Missing" }
    local BG_MODE_ORDER  = { "ACTIVE", "MISSING" }

    -- Build glow style dropdown values from ns.GLOW_STYLES
    local function GetGlowStyleValues()
        local labels, order = {}, {}
        if ns.GLOW_STYLES then
            for _, i in ipairs(ns.GLOW_VIEW.ordered) do local entry = ns.GLOW_STYLES[i]
                labels[i] = (entry.name and EllesmereUI.L(entry.name)) or ("Style " .. i)
                order[#order + 1] = i
            end
        end
        if #order == 0 then
            labels[1] = "Action Button Glow"
            order[1] = 1
        end
        return labels, order
    end

    ---------------------------------------------------------------------------
    --  Glow sites for Global Settings > Glows: per-bar Pandemic Glow, Buff Glow
    --  and Pixel Glow parameters, Tracked Buff Bars (active spec) and Rotation
    --  Assist, as shared glow descriptors over the bars' own keys.
    ---------------------------------------------------------------------------
    do
        local GO = EllesmereUI.GlowOptions
        local function CdmBars()
            local p = ns.ECME and ns.ECME.db and ns.ECME.db.profile
            return p and p.cdmBars
        end
        local function Rebuild() if ns.BuildAllCDMBars then ns.BuildAllCDMBars() end end
        -- Shared per-bar refreshes: the Glows page runs each distinct onChange once
        -- per Apply, so every bar's descriptor must hand out the same function.
        local function RebuildBuffGlows()
            Rebuild()
            if ns.RefreshBuffGlows then ns.RefreshBuffGlows() end
        end
        local function RebuildPixelGlows()
            Rebuild()
            if ns.RequestBarGlowUpdate then ns.RequestBarGlowUpdate() end
        end
        local function RebuildTBB() if ns.BuildTrackedBuffBars then ns.BuildTrackedBuffBars() end end
        local function ColorKeys(t, key)
            local c = t[key]
            if c then return c.r, c.g, c.b end
        end
        -- pandemicGlow* keys, shared by a bar's Pandemic Glow and the Tracked Buff
        -- Bars (style reads differ, see the descriptors).
        local function PandemicGet(bd, f)
            if f == "mode" then return bd.pandemicGlowMode or "default" end
            return EllesmereUI.GlowOptions.FlatGet(bd, "pandemicGlow", f)
        end
        local function PandemicSet(bd, f, a, b2, c2)
            if f == "style" then
                if a == 0 then bd.pandemicGlow = false else bd.pandemicGlow = true; bd.pandemicGlowStyle = a end
            elseif f == "mode" then
                bd.pandemicGlowMode = a
                -- Custom with no color stored draws the default look on the bar
                -- while the swatch and the preview show yellow: store it.
                if a == "custom" and not bd.pandemicGlowColor then
                    bd.pandemicGlowColor = { r = 1, g = 1, b = 0 }
                end
            else EllesmereUI.GlowOptions.FlatSet(bd, "pandemicGlow", f, a, b2, c2)
            end
        end

        -- Pandemic Glow of one CDM bar, shared by the Glows page and the CDM Bars
        -- page row. getBd resolves the bar at call time; onChange defaults to the
        -- shared rebuild (the bar page passes its own). nil pandemicGlow = never
        -- configured = Blizzard Default, not None: the built-in bars never seed the
        -- key (the templates that do ship true + -1) and Blizzard's PandemicIcon
        -- still draws for them, so only an explicit false reads as None.
        local function PandemicDesc(getBd, onChange)
            return {
                view = ns.GLOW_VIEW, host = "icon", excludes = { [4] = true },
                extras = { { value = -1, label = "Blizzard Default" } },
                caps = { mode = true, params = true, bg = true },
                defaultColor = { r = 1, g = 1, b = 0 },
                onChange = onChange or Rebuild,
                get = function(f)
                    local bd = getBd(); if not bd then return nil end
                    if f == "style" then
                        if bd.pandemicGlow == false then return 0 end
                        if bd.pandemicGlow == nil then return -1 end
                        return bd.pandemicGlowStyle or 1
                    end
                    return PandemicGet(bd, f)
                end,
                set = function(f, a, b2, c2)
                    local bd = getBd(); if bd then PandemicSet(bd, f, a, b2, c2) end
                end,
            }
        end
        ns._CDM_PandemicGlowDesc = PandemicDesc

        -- Buff Glow of one buff-family bar (flat buffGlow* keys); getBd and
        -- onChange as for PandemicDesc.
        local function BuffGlowDesc(getBd, onChange)
            return {
                view = ns.GLOW_VIEW, host = "icon", excludes = { [4] = true },
                caps = { mode = true, params = true, bg = true },
                defaultColor = { r = 1, g = 0.788, b = 0.137 },
                onChange = onChange or RebuildBuffGlows,
                get = function(f)
                    local bd = getBd(); if not bd then return nil end
                    if f == "style" then return bd.buffGlowType or 0
                    elseif f == "mode" then return bd.buffGlowMode or "default"
                    elseif f == "color" then
                        if bd.buffGlowR then return bd.buffGlowR, bd.buffGlowG, bd.buffGlowB end
                    -- Same fallbacks as the Buff Glow renderer (8/2/4), not the pixelGlow* keys.
                    elseif f == "lines" then return bd.buffGlowLines
                    elseif f == "thickness" then return bd.buffGlowThickness
                    elseif f == "speed" then return bd.buffGlowSpeed
                    elseif f == "bg" then return bd.buffGlowBackground == true
                    elseif f == "bgColor" then
                        if bd.buffGlowBackgroundR then return bd.buffGlowBackgroundR, bd.buffGlowBackgroundG, bd.buffGlowBackgroundB end
                    end
                end,
                set = function(f, a, b2, c2)
                    local bd = getBd(); if not bd then return end
                    if f == "style" then bd.buffGlowType = a
                    elseif f == "mode" then bd.buffGlowMode = a
                    elseif f == "color" then bd.buffGlowR, bd.buffGlowG, bd.buffGlowB = a, b2, c2
                    elseif f == "lines" then bd.buffGlowLines = a
                    elseif f == "thickness" then bd.buffGlowThickness = a
                    elseif f == "speed" then bd.buffGlowSpeed = a
                    elseif f == "bg" then bd.buffGlowBackground = a
                    elseif f == "bgColor" then bd.buffGlowBackgroundR, bd.buffGlowBackgroundG, bd.buffGlowBackgroundB = a, b2, c2
                    end
                end,
            }
        end
        ns._CDM_BuffGlowDesc = BuffGlowDesc

        -- Pixel Glow parameters of a cooldown bar: the per-spell glows assigned on
        -- its icons read these (no style or color of their own).
        local function PixelParamsDesc(bd)
            return {
                paramsOnly = true, host = "icon",
                caps = { params = true, bg = true },
                onChange = RebuildPixelGlows,
                get = function(f)
                    if f == "lines" then return bd.pixelGlowLines
                    elseif f == "thickness" then return bd.pixelGlowThickness
                    elseif f == "speed" then return bd.pixelGlowSpeed
                    elseif f == "bg" then return bd.pixelGlowBackground == true
                    elseif f == "bgColor" then
                        if bd.pixelGlowBackgroundR then return bd.pixelGlowBackgroundR, bd.pixelGlowBackgroundG, bd.pixelGlowBackgroundB end
                    elseif f == "mode" then return "default"
                    end
                end,
                set = function(f, a, b2, c2)
                    if f == "lines" then bd.pixelGlowLines = a
                    elseif f == "thickness" then bd.pixelGlowThickness = a
                    elseif f == "speed" then bd.pixelGlowSpeed = a
                    elseif f == "bg" then bd.pixelGlowBackground = a
                    elseif f == "bgColor" then bd.pixelGlowBackgroundR, bd.pixelGlowBackgroundG, bd.pixelGlowBackgroundB = a, b2, c2
                    end
                end,
            }
        end

        -- Pandemic Glow of one Tracked Buff Bar (rectangle: Pixel and Auto-Cast only;
        -- any other stored style or Blizzard Default shows and renders as Pixel, see
        -- ns.PG_TbbEffectiveStyle). getBd resolves the bar at call time, so the
        -- Tracking Bars page (selected bar) and the Glows page share this.
        local function TbbDesc(getBd, onChange)
            return {
                view = ns.GLOW_VIEW, host = "bar", excludes = EllesmereUI.Glows.RECT_EXCLUDES,
                caps = { mode = true, params = true, bg = true },
                defaultColor = { r = 1, g = 1, b = 0 },
                isOff = function() local bd = getBd(); return not bd or bd.pandemicGlow ~= true end,
                onChange = onChange,
                get = function(f)
                    local bd = getBd(); if not bd then return nil end
                    if f == "style" then return ns.PG_TbbEffectiveStyle(bd) end
                    return PandemicGet(bd, f)
                end,
                set = function(f, a, b2, c2)
                    local bd = getBd(); if bd then PandemicSet(bd, f, a, b2, c2) end
                end,
            }
        end
        ns._CDM_TbbGlowDesc = TbbDesc

        -- Rotation Assist (profile-wide): string-keyed styles; Blizzard Default and
        -- Solid Border are extras, never template targets.
        local ROT_TO_SHARED = { pixel = 1, button = 2, autocast = 3, shape = 4, gcd = 5, modern = 6, classic = 7 }
        local SHARED_TO_ROT = {}
        for k, v in pairs(ROT_TO_SHARED) do SHARED_TO_ROT[v] = k end
        -- Why the CDM highlight cannot show, nil while it can: Blizzard's
        -- Assisted Highlight off (always on Forever) or Show Rotation Helper off.
        local function RotationLockTip()
            if not ns.RotationAssistAvailable() then
                return "This option requires Blizzard's Assisted Highlight to be enabled"
            end
            local c = CdmBars()
            if c and c.hideRotationHelper then return "Show Rotation Helper" end
        end
        local function RotationHelperOff() return RotationLockTip() ~= nil end
        -- The CDM Bars page builds its Rotation Assist rows only while this is false.
        ns._CDM_RotationHelperOff = RotationHelperOff
        -- Blizzard's Assisted Highlight switched in its own options (fires only on
        -- a real change): those rows were built for the old state, and a cached
        -- page comes back without a rebuild. Drop the cached CDM pages and rebuild
        -- the one on screen (a closed panel rebuilds on its next show); the Glows
        -- page lists this site per build. Not on Forever.
        if not EllesmereUI.IS_FOREVER then
            EventRegistry:RegisterCallback("AssistedCombatManager.OnSetUseAssistedHighlight", function()
                EllesmereUI:InvalidateModulePageCache("EllesmereUICooldownManager")
                local m = EllesmereUI:GetActiveModule()
                if m == "EllesmereUICooldownManager"
                    or (m == EllesmereUI.GLOBAL_KEY and EllesmereUI:GetActivePage() == "Glows") then
                    EllesmereUI:RefreshPage(true)
                end
            end, "ECME_Options_AssistedHighlight")
        end
        local function RotationDesc()
            local desc = {
                host = "icon", noNone = true,
                toShared = function(v) return ROT_TO_SHARED[v] end,
                fromShared = function(i) return SHARED_TO_ROT[i] end,
                order = { "pixel", "shape", "button", "autocast", "gcd", "modern", "classic" },
                extras = { { value = "blizzard", label = "Blizzard Default" }, { value = "solid", label = "Solid Border", colored = true } },
                caps = { mode = true, params = true, bg = true }, thicknessMax = 8,
                defaultColor = { r = 1, g = 0, b = 0 },
                -- Off and locked while the highlight cannot show.
                isOff = RotationHelperOff, disabled = RotationHelperOff, disabledTooltip = RotationLockTip,
                onChange = function() if ns.UpdateRotationHighlights then ns.UpdateRotationHighlights() end end,
                get = function(f)
                    local c = CdmBars(); if not c then return nil end
                    if f == "style" then return c.rotationAssistStyle or "blizzard"
                    elseif f == "mode" then return c.rotationAssistColorMode or "default"
                    elseif f == "color" then
                        return c.rotationAssistColorR or 1, c.rotationAssistColorG or 0, c.rotationAssistColorB or 0
                    elseif f == "lines" then return c.rotationAssistLines
                    -- The renderer draws 3 when unset and allows up to 8 (thicknessMax).
                    elseif f == "thickness" then return c.rotationAssistThickness or 3
                    elseif f == "speed" then return c.rotationAssistSpeed
                    elseif f == "bg" then return c.rotationAssistBackground == true
                    elseif f == "bgColor" then return ColorKeys(c, "rotationAssistBackgroundColor")
                    end
                end,
                set = function(f, a, b2, c2)
                    local c = CdmBars(); if not c then return end
                    if f == "style" then c.rotationAssistStyle = a
                    elseif f == "mode" then c.rotationAssistColorMode = a
                    elseif f == "color" then c.rotationAssistColorR, c.rotationAssistColorG, c.rotationAssistColorB = a, b2, c2
                    elseif f == "lines" then c.rotationAssistLines = a
                    elseif f == "thickness" then c.rotationAssistThickness = a
                    elseif f == "speed" then c.rotationAssistSpeed = a
                    elseif f == "bg" then c.rotationAssistBackground = a
                    elseif f == "bgColor" then c.rotationAssistBackgroundColor = { r = a, g = b2, b = c2 }
                    end
                end,
            }
            return desc
        end
        -- The CDM Bars page's Rotation Assist cog reuses the shared rows.
        ns._CDM_RotationGlowDesc = RotationDesc
        -- Which glow rows a bar shows on the CDM Bars page; the Glows page lists
        -- exactly these. EXTRAS (Pandemic Glow): not custom aura bars or FocusKick.
        function ns.CDM_BarHasExtras(bd)
            return bd.barType ~= "custom_buff" and bd.key ~= "focuskick"
        end
        -- Pixel Glow Thickness row: cooldown and utility bars (buff bars use Buff Glow).
        function ns.CDM_BarHasPixelRow(bd)
            return not (ns.IsBarBuffFamily and ns.IsBarBuffFamily(bd))
                and (bd.barType == "cooldowns" or bd.barType == "utility")
        end

        do
            -- Open Settings targets: the CDM Bars page with the bar selected first.
            local function BarNav(key, section, highlight)
                return { page = PAGE_CDM_BARS, section = section, highlight = highlight,
                    preSelect = function() if EllesmereUI._setCDMBar then EllesmereUI._setCDMBar(key) end end }
            end
            -- Rotation Assist, listed per page build: while the highlight cannot
            -- show, the row reads None and Off, stays locked and opens Show
            -- Rotation Helper (the style has no None of its own, so only that
            -- listing offers one). Not on Forever: no Assisted Highlight there.
            if not EllesmereUI.IS_FOREVER then
                local rotOn = { { label = "Rotation Assist Style", desc = RotationDesc() } }
                local offDesc = RotationDesc()
                offDesc.noNone = nil
                -- Locked for good: a cached page keeps this listing until it rebuilds.
                offDesc.disabled = function() return true end
                local rotOff = { { label = "Rotation Assist Style", desc = offDesc,
                    nav = BarNav("cooldowns", "EXTRAS", "Show Rotation Helper") } }
                -- sub: the group heading on the Glows page card (General, one
                -- per bar, Tracking Bars); labels stay short beneath it.
                GO.RegisterSite({ id = "cdm_rotation", label = "Rotation Assist Style", group = "bar",
                    sub = EllesmereUI.L("General"),
                    module = "EllesmereUICooldownManager",
                    page = PAGE_CDM_BARS, section = "EXTRAS", highlight = "Rotation Assist Style",
                    preSelect = BarNav("cooldowns").preSelect,
                    list = function() return RotationHelperOff() and rotOff or rotOn end })
            end
            -- Per-icon glows and Bar Glows stay per entry (never template targets):
            -- hint entries counting the active spec's own settings. Read-only, raw
            -- entry values only (inherited bar tiers and explicit false don't count).
            -- Style keys only: a glow style is a number > 0 (0 = explicit None); a
            -- color alone draws nothing.
            local PER_ICON_GLOW_KEYS = { "procGlow", "activeGlow", "maxStacksGlow", "buffGlow" }
            local PER_ICON_FAMILIES = { "cooldowns", "buffs" }
            local function HasOwnGlow(e)
                if type(e) ~= "table" then return false end
                for i = 1, #PER_ICON_GLOW_KEYS do
                    local v = rawget(e, PER_ICON_GLOW_KEYS[i])
                    if type(v) == "number" and v > 0 then return true end
                end
                local cse = rawget(e, "cdStateEffect")
                return type(cse) == "string" and cse:find("GlowReady", 1, true) ~= nil
            end
            local function CountPerIconGlows()
                local n = 0
                for _, fam in ipairs(PER_ICON_FAMILIES) do
                    local st = ns.GetSpellSettingsStore and ns.GetSpellSettingsStore(fam)
                    for _, e in pairs(st or {}) do
                        if HasOwnGlow(e) then n = n + 1 end
                    end
                end
                -- Preset and custom spells keep theirs in the profile-level
                -- customActiveStates store (read directly: its getter creates it).
                local prof = ns.ECME and ns.ECME.db and ns.ECME.db.profile
                for _, e in pairs((prof and prof.customActiveStates) or {}) do
                    if HasOwnGlow(e) then n = n + 1 end
                end
                return n
            end
            GO.RegisterSite({ id = "cdm_per_icon", label = "Per-Icon Glows",
                module = "EllesmereUICooldownManager", page = PAGE_CDM_BARS,
                info = {
                    glyph = "icon",
                    tooltip = "Proc Glow, Active State Glow, Max Charges Glow, Buff Glow, CD Ready Glow and Glow Effect Color can be set per icon: right-click an icon in the CDM Bars preview. Counted for the current specialization; the template never changes them.",
                    text = function() return EllesmereUI.Lf("%d icon(s) with their own glow settings", CountPerIconGlows()) end,
                } })
            GO.RegisterSite({ id = "cdm_bar_glows", label = "Bar Glows",
                module = "EllesmereUICooldownManager", page = PAGE_BAR_GLOWS,
                info = {
                    glyph = "bar",
                    tooltip = "Glows on action bar and CDM buttons while a tracked buff is active (or missing), set per entry on the Bar Glows page. Counted for the current specialization; the template never changes them.",
                    text = function()
                        -- Read-only: ns.GetBarGlows would create the spec's table.
                        local specKey = ns.GetActiveSpecKey and ns.GetActiveSpecKey()
                        local sp = ns.GetActiveSpecProfiles and ns.GetActiveSpecProfiles()
                        local bg = specKey and sp and sp[specKey] and sp[specKey].barGlows
                        local n = 0
                        for _, list in pairs((bg and bg.assignments) or {}) do
                            if type(list) == "table" then n = n + #list end
                        end
                        if bg and bg.enabled == false then return EllesmereUI.Lf("%d bar glow(s), turned off", n) end
                        return EllesmereUI.Lf("%d bar glow(s)", n)
                    end,
                } })
            -- Per-bar sites are rebuilt on every page build (bars come and go).
            GO.RegisterSite({ id = "cdm_bars", label = "Cooldown Manager Bars", group = "bar",
                module = "EllesmereUICooldownManager",
                list = function()
                    local out = {}
                    local c = CdmBars()
                    for _, bd in ipairs((c and c.bars) or {}) do
                        -- Ghost and custom buff bars stay out, like the pandemic sync.
                        if not bd.isGhostBar and bd.barType ~= "custom_buff" then
                            local name = EllesmereUI.L(bd.name or bd.key or "?")
                            if ns.CDM_BarHasExtras(bd) then
                                out[#out + 1] = { label = "Pandemic Glow", sub = name, desc = PandemicDesc(function() return bd end),
                                    nav = BarNav(bd.key, "EXTRAS", "Pandemic Glow") }
                            end
                            if ns.IsBarBuffFamily and ns.IsBarBuffFamily(bd) then
                                out[#out + 1] = { label = "Buff Glow", sub = name, desc = BuffGlowDesc(function() return bd end),
                                    nav = BarNav(bd.key, "ICON DISPLAY", "Buff Glow") }
                            elseif ns.CDM_BarHasPixelRow(bd) then
                                out[#out + 1] = { label = "Pixel Glow", sub = name, desc = PixelParamsDesc(bd),
                                    nav = BarNav(bd.key, "ICON DISPLAY", "Pixel Glow Thickness") }
                            end
                        end
                    end
                    local tbb = ns.GetTrackedBuffBars and ns.GetTrackedBuffBars()
                    local tbbSub = EllesmereUI.L("Tracking Bars") .. " - " .. EllesmereUI.L("Pandemic Glow")
                    for i, bd in ipairs((tbb and tbb.bars) or {}) do
                        out[#out + 1] = { label = bd.name or "?", sub = tbbSub,
                            desc = TbbDesc(function() return bd end, RebuildTBB),
                            nav = { page = PAGE_BUFF_BARS, section = "EXTRAS", highlight = "Pandemic Glow",
                                preSelect = function() if ns._TBBSelectBar then ns._TBBSelectBar(i) end end } }
                    end
                    return out
                end })
        end
    end

    -- Cross-surface pandemic-glow sync (CDM bars + Nameplates) lives in CDM core as
    -- ApplyPandemicGlowToAll/IsPandemicGlowSyncedToAll (best-effort, name-based so styles
    -- never shift across surfaces); callers build a payload via PandemicPayloadFrom*.

    -- Check if a specific bar target uses a custom shape (not "none"/"cropped").
    -- barIdx can be a number 1-8 (action bar) or a string (CDM bar key).
    local function BarHasCustomShape(barIdx)
        barIdx = NormalizeSelectedBar(barIdx)
        if type(barIdx) == "string" then
            local cdmBd = ns.barDataByKey and ns.barDataByKey[barIdx]
            if cdmBd and cdmBd.iconShape and cdmBd.iconShape ~= "none" and cdmBd.iconShape ~= "cropped" then
                return true
            end
            return false
        end
        local barKeys = { "MainBar", "Bar2", "Bar3", "Bar4", "Bar5", "Bar6", "Bar7", "Bar8" }
        local barKey = barKeys[barIdx]
        if not barKey then return false end
        local ok, EAB = pcall(EllesmereUI.Lite.GetAddon, "EllesmereUIActionBars")
        if ok and EAB and EAB.db and EAB.db.profile and EAB.db.profile.bars then
            local s = EAB.db.profile.bars[barKey]
            if s and s.buttonShape and s.buttonShape ~= "none" and s.buttonShape ~= "cropped" then
                return true
            end
        end
        return false
    end

    -- Preview glow state tracking
    local _bgPreviewGlowActive = {}
    local _bgPreviewGlowOverlays = {}
    local _bgSpellPickerMenu

    EllesmereUI:RegisterOnHide(function()
        if _bgSpellPickerMenu then _bgSpellPickerMenu:Hide() end
    end)

    local function ShowBarGlowSpellPicker(anchorFrame, barIdx, btnIdx, onChanged, overrideAssignKey)
        if _bgSpellPickerMenu then _bgSpellPickerMenu:Hide() end

        local bg = ns.GetBarGlows()
        local assignKey = overrideAssignKey or (barIdx .. "_" .. btnIdx)
        local buffList = bg.assignments[assignKey] or {}

        local assignedSet = {}
        for _, entry in ipairs(buffList) do
            if entry.spellID then assignedSet[entry.spellID] = true end
        end

        -- Track whether any change was made so we can fire onChanged when menu closes
        local dirty = false
        -- Immediate update: save picker position, rebuild, re-anchor
        local function ImmediateUpdate()
            dirty = false  -- already handled
            if not onChanged then return end
            local menuRef = _bgSpellPickerMenu
            if not menuRef then onChanged(); return end
            -- Save absolute screen position before rebuild
            local cx, cy = menuRef:GetCenter()
            local mScale = menuRef:GetEffectiveScale()
            local mW, mH = menuRef:GetSize()
            onChanged()
            -- Re-anchor to saved absolute position so page rebuild doesn't shift us
            menuRef = _bgSpellPickerMenu
            if menuRef and menuRef:IsShown() then
                menuRef:ClearAllPoints()
                local uiScale = UIParent:GetEffectiveScale()
                menuRef:SetPoint("CENTER", UIParent, "BOTTOMLEFT", cx * mScale / uiScale, cy * mScale / uiScale)
            end
        end

        local tracked, untracked = ns.GetAllCDMBuffSpells()
        -- Tracked Bar spells are added later but checked here too, so the menu
        -- doesn't bail when only Tracked Bars exist.
        local hasTrackedBars = ns.GetTrackedBarSpells and #ns.GetTrackedBarSpells() > 0 or false
        if #tracked == 0 and #untracked == 0 and not hasTrackedBars then return end

        -- Standard dropdown colors
        local mBgR  = EllesmereUI.DD_BG_R  or 0.075
        local mBgG  = EllesmereUI.DD_BG_G  or 0.113
        local mBgB  = EllesmereUI.DD_BG_B  or 0.141
        local mBgA  = EllesmereUI.DD_BG_HA or 0.98
        local mBrdA = EllesmereUI.DD_BRD_A or 0.20
        local hlA   = EllesmereUI.DD_ITEM_HL_A or 0.08
        local tDimR = EllesmereUI.TEXT_DIM_R or 0.7
        local tDimG = EllesmereUI.TEXT_DIM_G or 0.7
        local tDimB = EllesmereUI.TEXT_DIM_B or 0.7
        local tDimA = EllesmereUI.TEXT_DIM_A or 0.85
        local ACCENT = EllesmereUI.ELLESMERE_GREEN or { r = 0.05, g = 0.82, b = 0.62 }

        local menuW = 240
        local ITEM_H = 26
        local MAX_H = 300

        local menu = CreateFrame("Frame", nil, UIParent)
        menu:SetFrameStrata("FULLSCREEN_DIALOG")
        menu:SetFrameLevel(300)
        menu:SetClampedToScreen(true)
        menu:SetSize(menuW, 10)

        local mbg = menu:CreateTexture(nil, "BACKGROUND")
        mbg:SetAllPoints(); mbg:SetColorTexture(mBgR, mBgG, mBgB, mBgA)
        EllesmereUI.MakeBorder(menu, 1, 1, 1, mBrdA, EllesmereUI.PP)

        local inner = CreateFrame("Frame", nil, menu)
        inner:SetWidth(menuW)
        inner:SetPoint("TOPLEFT")

        local mH = 4

        local function MakeCheckItem(sp)
            local item = CreateFrame("Button", nil, inner)
            item:SetHeight(ITEM_H)
            item:SetPoint("TOPLEFT", inner, "TOPLEFT", 1, -mH)
            item:SetPoint("TOPRIGHT", inner, "TOPRIGHT", -1, -mH)
            item:SetFrameLevel(menu:GetFrameLevel() + 2)

            -- Checkbox (AuraBuff style: Frame box + MakeBorder + inner fill)
            local cbSize = 14
            local cb = CreateFrame("Frame", nil, item)
            cb:SetSize(cbSize, cbSize)
            cb:SetPoint("LEFT", item, "LEFT", 8, 0)
            cb:SetFrameLevel(item:GetFrameLevel() + 1)
            local cbBg = cb:CreateTexture(nil, "BACKGROUND")
            cbBg:SetAllPoints(); cbBg:SetColorTexture(0.12, 0.12, 0.14, 1)
            local cbBrd = EllesmereUI.MakeBorder(cb, 0.25, 0.25, 0.28, 0.6, EllesmereUI.PanelPP)
            local cbFill = cb:CreateTexture(nil, "ARTWORK")
            if cbFill.SetSnapToPixelGrid then cbFill:SetSnapToPixelGrid(false); cbFill:SetTexelSnappingBias(0) end
            cbFill:SetPoint("TOPLEFT", cb, "TOPLEFT", 3, -3)
            cbFill:SetPoint("BOTTOMRIGHT", cb, "BOTTOMRIGHT", -3, 3)
            cbFill:SetColorTexture(ACCENT.r, ACCENT.g, ACCENT.b, 1)
            local function UpdateCB()
                if assignedSet[sp.spellID] then
                    cbFill:Show()
                    cbBrd:SetColor(ACCENT.r, ACCENT.g, ACCENT.b, 0.8)
                else
                    cbFill:Hide()
                    cbBrd:SetColor(0.25, 0.25, 0.28, 0.6)
                end
            end
            UpdateCB()

            local ico = item:CreateTexture(nil, "ARTWORK")
            local icoSz = ITEM_H - 4
            ico:SetSize(icoSz, icoSz)
            ico:SetPoint("RIGHT", item, "RIGHT", -6, 0)
            if sp.icon then ico:SetTexture(sp.icon) end
            ico:SetTexCoord(0.08, 0.92, 0.08, 0.92)

            local lbl = item:CreateFontString(nil, "OVERLAY")
            lbl:SetFont(FONT_PATH, 11, GetCDMOptOutline())
            lbl:SetPoint("LEFT", cb, "RIGHT", 6, 0)
            lbl:SetPoint("RIGHT", ico, "LEFT", -4, 0)
            lbl:SetJustifyH("LEFT")
            lbl:SetWordWrap(false); lbl:SetMaxLines(1)
            lbl:SetText(EllesmereUI.L(sp.name))
            lbl:SetTextColor(tDimR, tDimG, tDimB, tDimA)

            local hl = item:CreateTexture(nil, "ARTWORK", nil, -1)
            hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0)

            item:SetScript("OnEnter", function()
                lbl:SetTextColor(1, 1, 1, 1)
                hl:SetColorTexture(1, 1, 1, hlA)
            end)
            item:SetScript("OnLeave", function()
                lbl:SetTextColor(tDimR, tDimG, tDimB, tDimA)
                hl:SetColorTexture(1, 1, 1, 0)
            end)
            item:SetScript("OnClick", function()
                if assignedSet[sp.spellID] then
                    assignedSet[sp.spellID] = nil
                    for idx = #buffList, 1, -1 do
                        if buffList[idx].spellID == sp.spellID then
                            table.remove(buffList, idx)
                            break
                        end
                    end
                    UpdateCB()
                    bg.assignments[assignKey] = buffList
                    Refresh()
                    ImmediateUpdate()
                else
                    -- Add with defaults
                    assignedSet[sp.spellID] = true
                    local newEntry = {
                        spellID = sp.spellID,
                        glowStyle = 1,
                        mode = "ACTIVE",
                        onlyInCombat = false,
                    }
                    local prefix = BAR_BUTTON_PREFIXES[barIdx]
                    local realBtn = prefix and _G[prefix .. btnIdx]
                    if realBtn and realBtn.action then
                        local aType, aID = GetActionInfo(realBtn.action)
                        if aType == "spell" and aID then
                            newEntry.actionSpellID = aID
                        end
                    end
                    buffList[#buffList + 1] = newEntry
                    UpdateCB()
                    bg.assignments[assignKey] = buffList
                    Refresh()
                    ImmediateUpdate()
                end
            end)

            mH = mH + ITEM_H
        end

        -- Tracked buffs
        for _, sp in ipairs(tracked) do MakeCheckItem(sp) end

        -- Divider
        if #tracked > 0 and #untracked > 0 then
            local div = inner:CreateTexture(nil, "ARTWORK")
            div:SetHeight(1); div:SetColorTexture(1, 1, 1, 0.10)
            div:SetPoint("TOPLEFT", inner, "TOPLEFT", 1, -mH - 4)
            div:SetPoint("TOPRIGHT", inner, "TOPRIGHT", -1, -mH - 4)
            mH = mH + 9
        end

        -- Untracked buffs
        for _, sp in ipairs(untracked) do MakeCheckItem(sp) end

        -- Blizzard CDM "Tracked Bars" (BuffBarCooldownViewer). Blizzard CDM
        -- drag-and-drop puts a spell in either the Tracked Buffs icon strip OR
        -- Tracked Bars, never both -- no dedup needed.
        local trackedBars = ns.GetTrackedBarSpells and ns.GetTrackedBarSpells() or {}
        if #trackedBars > 0 then
            if #tracked > 0 or #untracked > 0 then
                local div = inner:CreateTexture(nil, "ARTWORK")
                div:SetHeight(1); div:SetColorTexture(1, 1, 1, 0.10)
                div:SetPoint("TOPLEFT", inner, "TOPLEFT", 1, -mH - 4)
                div:SetPoint("TOPRIGHT", inner, "TOPRIGHT", -1, -mH - 4)
                mH = mH + 9
            end
            for _, sp in ipairs(trackedBars) do MakeCheckItem(sp) end
        end

        local totalH = mH + 4
        inner:SetHeight(totalH)

        if totalH > MAX_H then
            menu:SetHeight(MAX_H)
            local sf = CreateFrame("ScrollFrame", nil, menu)
            sf:SetPoint("TOPLEFT"); sf:SetPoint("BOTTOMRIGHT")
            sf:SetFrameLevel(menu:GetFrameLevel() + 1)
            sf:EnableMouseWheel(true)
            sf:SetScrollChild(inner)
            inner:SetWidth(menuW)
            local scrollPos = 0
            local maxScroll = totalH - MAX_H
            sf:SetScript("OnMouseWheel", function(_, delta)
                scrollPos = math.max(0, math.min(maxScroll, scrollPos - delta * 30))
                sf:SetVerticalScroll(scrollPos)
            end)
        else
            menu:SetHeight(totalH)
            inner:SetParent(menu)
            inner:SetPoint("TOPLEFT")
        end

        menu:ClearAllPoints()
        menu:SetPoint("TOP", anchorFrame, "BOTTOM", 0, -2)

        menu:SetScript("OnUpdate", function(m)
            if not m:IsMouseOver() and not anchorFrame:IsMouseOver() and IsMouseButtonDown("LeftButton") then
                m:Hide()
            end
        end)
        menu:HookScript("OnHide", function(m)
            m:SetScript("OnUpdate", nil)
            if dirty and onChanged then onChanged() end
        end)

        menu:Show()
        menu._btnIdx = btnIdx
        _bgSpellPickerMenu = menu
    end

    ---------------------------------------------------------------------------
    --  Bar Glows: BuildBarGlowsPage
    ---------------------------------------------------------------------------
    local _glowHeaderBuilder  -- stored for cache restore via getHeaderBuilder
    local _glowSelectedButton = nil  -- UI-only selection state (not saved)
    local _glowBtnFrames = {}  -- button frames from last header build, indexed by button number

    local function BuildBarGlowsPage(pageName, parent, yOffset)
        local W = EllesmereUI.Widgets
        local y = yOffset
        local _, h

        local bg = ns.GetBarGlows()
        local curBar = NormalizeSelectedBar(bg.selectedBar or "cooldowns")
        local curBtn = _glowSelectedButton  -- nil = no selection

        local ACCENT = EllesmereUI.ELLESMERE_GREEN or { r = 0.05, g = 0.82, b = 0.62 }

        -------------------------------------------------------------------
        --  Content Header: Live Action Bar Preview (replica of BuildLivePreview)
        -------------------------------------------------------------------
        EllesmereUI:ClearContentHeader()

        -- Stop any lingering preview glows
        for idx, ov in pairs(_bgPreviewGlowOverlays) do
            ns.StopNativeGlow(ov)
        end
        wipe(_bgPreviewGlowOverlays)
        wipe(_bgPreviewGlowActive)

        _glowHeaderBuilder = function(headerFrame, width)
            -- Re-read current state each build
            local bgData = ns.GetBarGlows()
            local sel = NormalizeSelectedBar(bgData.selectedBar or 1)
            local isCDMBar = (type(sel) == "string")
            -- For CDM bars: cdmBarKey is the bar key string. For action bars:
            -- barIdx is the integer 1-8 used for prefix lookup.
            local cdmBarKey = isCDMBar and sel or nil
            local barIdx = isCDMBar and nil or sel
            local ok, EAB_ADDON = pcall(EllesmereUI.Lite.GetAddon, "EllesmereUIActionBars")
            if not ok then EAB_ADDON = nil end
            local barKeyList = { "MainBar", "Bar2", "Bar3", "Bar4", "Bar5", "Bar6", "Bar7", "Bar8" }
            local barKeyStr = (not isCDMBar) and (barKeyList[barIdx] or "MainBar") or nil
            local barSettings = nil
            if barKeyStr and EAB_ADDON and EAB_ADDON.db and EAB_ADDON.db.profile then
                barSettings = EAB_ADDON.db.profile.bars[barKeyStr]
            end

            -- CDM bars: count icons dynamically; action bars: always 12.
            -- Overflow-diverted icons are tail-appended to the target's array
            -- and excluded here, so every native icon keeps its slot index
            -- (stable glow-assignment fallback keys).
            local NUM_BUTTONS = 12
            if isCDMBar and ns.cdmBarIcons and ns.cdmBarIcons[cdmBarKey] then
                NUM_BUTTONS = 0
                for _, ic in ipairs(ns.cdmBarIcons[cdmBarKey]) do
                    if not (ns.CdmFrameOverflowBar and ns.CdmFrameOverflowBar(ic)) then
                        NUM_BUTTONS = NUM_BUTTONS + 1
                    end
                end
                if NUM_BUTTONS == 0 then NUM_BUTTONS = 1 end
            end
            local prefix = (not isCDMBar) and (BAR_BUTTON_PREFIXES[barIdx] or "ActionButton") or nil

            -- Dropdown at top
            local DD_H = 34
            local ddW  = 350
            local DDS    = EllesmereUI.DD_STYLE
            local mBgR   = DDS.BG_R;  local mBgG  = DDS.BG_G;  local mBgB  = DDS.BG_B
            local mBgA   = DDS.BG_A;  local mBgHA = DDS.BG_HA
            local mBrdA  = DDS.BRD_A; local mBrdHA = DDS.BRD_HA or 0.30
            local mTxtA  = DDS.TXT_A; local mTxtHA = DDS.TXT_HA or 1
            local hlA    = DDS.ITEM_HL_A; local selA = DDS.ITEM_SEL_A
            local tDimR  = EllesmereUI.TEXT_DIM_R or 0.7
            local tDimG  = EllesmereUI.TEXT_DIM_G or 0.7
            local tDimB  = EllesmereUI.TEXT_DIM_B or 0.7
            local tDimA  = EllesmereUI.TEXT_DIM_A or 0.85
            local ITEM_H = 26

            local ddBtn = CreateFrame("Button", nil, headerFrame)
            PP.Size(ddBtn, ddW, DD_H)
            ddBtn:SetFrameLevel(headerFrame:GetFrameLevel() + 5)
            local ddBg  = ddBtn:CreateTexture(nil, "BACKGROUND")
            ddBg:SetAllPoints(); ddBg:SetColorTexture(mBgR, mBgG, mBgB, mBgA)
            local ddBrd = EllesmereUI.MakeBorder(ddBtn, 1, 1, 1, mBrdA, EllesmereUI.PanelPP)
            local ddLbl = ddBtn:CreateFontString(nil, "OVERLAY")
            ddLbl:SetFont(FONT_PATH, 13, GetCDMOptOutline())
            ddLbl:SetAlpha(mTxtA); ddLbl:SetJustifyH("LEFT")
            ddLbl:SetWordWrap(false); ddLbl:SetMaxLines(1)
            ddLbl:SetPoint("LEFT", ddBtn, "LEFT", 12, 0)
            local ddArrow = EllesmereUI.MakeDropdownArrow(ddBtn, 12, EllesmereUI.PanelPP)
            ddLbl:SetPoint("RIGHT", ddArrow, "LEFT", -5, 0)
            ddLbl:SetText(GetBGTargetLabel(sel))

            local ddMenu
            local function BuildDDMenu()
                if ddMenu then ddMenu:Hide(); ddMenu = nil end
                local menu = CreateFrame("Frame", nil, UIParent)
                menu:SetFrameStrata("FULLSCREEN_DIALOG")
                menu:SetFrameLevel(300)
                menu:SetClampedToScreen(true)
                menu:SetPoint("TOPLEFT", ddBtn, "BOTTOMLEFT", 0, -2)
                menu:SetPoint("TOPRIGHT", ddBtn, "BOTTOMRIGHT", 0, -2)
                local bg2 = menu:CreateTexture(nil, "BACKGROUND")
                bg2:SetAllPoints(); bg2:SetColorTexture(mBgR, mBgG, mBgB, mBgHA)
                EllesmereUI.MakeBorder(menu, 1, 1, 1, mBrdA, EllesmereUI.PP)
                local mH = 4
                local targets = BuildBGTargetList()
                for _, t in ipairs(targets) do
                    local entryVal = t.value
                    local item = CreateFrame("Button", nil, menu)
                    item:SetHeight(ITEM_H)
                    item:SetPoint("TOPLEFT", menu, "TOPLEFT", 1, -mH)
                    item:SetPoint("TOPRIGHT", menu, "TOPRIGHT", -1, -mH)
                    item:SetFrameLevel(menu:GetFrameLevel() + 2)
                    local iLbl = item:CreateFontString(nil, "OVERLAY")
                    iLbl:SetFont(FONT_PATH, 11, GetCDMOptOutline())
                    iLbl:SetTextColor(tDimR, tDimG, tDimB, tDimA)
                    iLbl:SetJustifyH("LEFT"); iLbl:SetWordWrap(false); iLbl:SetMaxLines(1)
                    iLbl:SetPoint("LEFT", item, "LEFT", 10, 0)
                    iLbl:SetText(t.label)
                    local iHl = item:CreateTexture(nil, "ARTWORK")
                    iHl:SetAllPoints(); iHl:SetColorTexture(1, 1, 1, 1)
                    local isCurrent = (entryVal == sel)
                    iHl:SetAlpha(isCurrent and selA or 0)
                    item:SetScript("OnEnter", function() iLbl:SetTextColor(1,1,1,1); iHl:SetAlpha(hlA) end)
                    item:SetScript("OnLeave", function() iLbl:SetTextColor(tDimR,tDimG,tDimB,tDimA); iHl:SetAlpha(isCurrent and selA or 0) end)
                    item:SetScript("OnClick", function()
                        menu:Hide()
                        bgData.selectedBar = entryVal
                        bgData.selectedButton = nil
                        _glowSelectedButton = nil
                        EllesmereUI:RefreshPage(true)
                    end)
                    mH = mH + ITEM_H
                end
                menu:SetHeight(mH + 4)
                menu:SetScript("OnUpdate", function(m)
                    if not m:IsMouseOver() and not ddBtn:IsMouseOver() and IsMouseButtonDown("LeftButton") then m:Hide() end
                end)
                menu:HookScript("OnHide", function(m) m:SetScript("OnUpdate", nil) end)
                menu:Show()
                ddMenu = menu
            end

            ddBtn:SetScript("OnEnter", function() ddLbl:SetAlpha(mTxtHA); ddBrd:SetColor(1,1,1,mBrdHA); ddBg:SetColorTexture(mBgR,mBgG,mBgB,mBgHA) end)
            ddBtn:SetScript("OnLeave", function()
                if ddMenu and ddMenu:IsShown() then return end
                ddLbl:SetAlpha(mTxtA); ddBrd:SetColor(1,1,1,mBrdA); ddBg:SetColorTexture(mBgR,mBgG,mBgB,mBgA)
            end)
            ddBtn:SetScript("OnClick", function() if ddMenu and ddMenu:IsShown() then ddMenu:Hide() else BuildDDMenu() end end)
            ddBtn:HookScript("OnHide", function() if ddMenu then ddMenu:Hide() end end)
            PP.Point(ddBtn, "TOP", headerFrame, "TOP", 0, -20)

            -- Button grid below dropdown
            local gridTopY = -(20 + DD_H + 20)

            local realBtnW, realBtnH = 36, 36
            if isCDMBar then
                local cdmBd = ns.barDataByKey and ns.barDataByKey[cdmBarKey]
                if cdmBd then
                    realBtnW = cdmBd.iconSize or 36
                    realBtnH = realBtnW
                end
            else
                local btn1 = _G[prefix .. "1"]
                realBtnW = (btn1 and btn1:GetWidth() or 36)
                realBtnH = (btn1 and btn1:GetHeight() or 36)
            end
            if realBtnW < 1 then realBtnW = 36 end
            if realBtnH < 1 then realBtnH = 36 end

            -- Read bar size (no scale -- width/height based)
            local scaledBtnW = math.floor(realBtnW + 0.5)
            local scaledBtnH = math.floor(realBtnH + 0.5)

            -- CDM bar data reference (reused for shape, spacing, zoom, border)
            local cdmBd = isCDMBar and ns.barDataByKey and ns.barDataByKey[cdmBarKey] or nil

            -- Custom shape expansion
            local btnShape
            if isCDMBar then
                btnShape = (cdmBd and cdmBd.iconShape) or "none"
            else
                btnShape = (barSettings and barSettings.buttonShape) or "none"
            end
            if btnShape ~= "none" and btnShape ~= "cropped" then
                local shapeExp = 10
                scaledBtnW = scaledBtnW + shapeExp
                scaledBtnH = scaledBtnH + shapeExp
            end
            if btnShape == "cropped" then
                scaledBtnH = math.floor(scaledBtnH * (isCDMBar and ns.CdmCropFactor(cdmBd) or 0.80) + 0.5)
            end

            local spacing = isCDMBar and ((cdmBd and cdmBd.spacing) or 2) or ((barSettings and barSettings.buttonPadding) or 2)
            local scaledPad = spacing

            -- How many buttons visible
            local numVisible = NUM_BUTTONS
            if not isCDMBar and barSettings then
                local ov = barSettings.overrideNumIcons
                if ov and ov > 0 and ov < numVisible then numVisible = ov end
            end

            -- Read zoom
            local zoom = isCDMBar and ((cdmBd and cdmBd.iconZoom) or 0.08) or (((barSettings and barSettings.iconZoom) or 5.5) / 100)
            local square = (not isCDMBar) and EAB_ADDON and EAB_ADDON.db and EAB_ADDON.db.profile.squareIcons

            -- Read border settings
            local brdSize = 0
            local brdColor, brdClassColor
            if isCDMBar and cdmBd then
                brdSize = cdmBd.borderSize or 1
                -- This preview draws a solid border, so an exact size (borderSizePx)
                -- shows here only while the bar's style is Solid.
                local cdmTex = cdmBd.borderTexture or "solid"
                local cdmPx = EllesmereUI.BorderPx(cdmBd.borderSizePx, brdSize, cdmTex)
                if cdmPx and cdmTex == "solid" then brdSize = cdmPx end
                brdColor = { r = cdmBd.borderR or 0, g = cdmBd.borderG or 0, b = cdmBd.borderB or 0, a = cdmBd.borderA or 1 }
                brdClassColor = cdmBd.borderClassColor
            elseif not isCDMBar and barSettings then
                -- None..Strong are the steps 0-4; an unknown or numeric value renders as Thin, as the bar does.
                local thickness = barSettings.borderThickness or "thin"
                brdSize = EllesmereUI.BORDER_STEP_OF_LABEL[thickness] or 1
                local abTex = barSettings.borderTexture or "solid"
                local abPx = EllesmereUI.BorderPx(barSettings.borderThicknessPx, brdSize, abTex)
                if abPx and abTex == "solid" then brdSize = abPx end
                brdColor = barSettings.borderColor
                brdClassColor = barSettings.borderClassColor
            end
            if not brdColor then brdColor = { r = 0, g = 0, b = 0, a = 1 } end

            local gridW = numVisible * scaledBtnW + (numVisible - 1) * scaledPad
            local startX = math.max(0, math.floor((width - gridW) / 2))
            local startY = gridTopY

            local UnsnapTex = EllesmereUI.PP.DisablePixelSnap

            -- Clear button frame refs from previous build
            wipe(_glowBtnFrames)

            for i = 1, NUM_BUTTONS do
                if i > numVisible then break end

                local xOff = startX + (i - 1) * (scaledBtnW + scaledPad)
                local isSelected = (_glowSelectedButton == i)

                local bf = CreateFrame("Button", nil, headerFrame)
                bf:SetSize(scaledBtnW, scaledBtnH)
                bf:SetPoint("TOPLEFT", headerFrame, "TOPLEFT", xOff, startY)
                _glowBtnFrames[i] = bf
                bf:RegisterForClicks("LeftButtonUp", "RightButtonDown")

                local bgTex = bf:CreateTexture(nil, "BACKGROUND")
                bgTex:SetAllPoints()
                bgTex:SetColorTexture(0.06, 0.08, 0.10, 0.5)

                -- Icon from real action button or CDM bar icon
                local realBtn
                if isCDMBar then
                    local cdmIcons = ns.cdmBarIcons and ns.cdmBarIcons[cdmBarKey]
                    realBtn = cdmIcons and cdmIcons[i]
                    -- Native equipment frames are parked off the live bar (items
                    -- are preset-lane-only), but the icon registry can still hold
                    -- one from a prior pass -- never replicate it into the preview.
                    if realBtn and realBtn.cooldownID and C_CooldownViewer
                        and C_CooldownViewer.GetCooldownViewerCooldownInfo then
                        local rinfo = C_CooldownViewer.GetCooldownViewerCooldownInfo(realBtn.cooldownID)
                        if rinfo and rinfo.equipSlot then realBtn = nil end
                    end
                else
                    realBtn = prefix and _G[prefix .. i]
                end
                -- Non-glowable icons (see IsNonGlowableCDMIcon) are left inert -- no hover, clicks do nothing.
                local nonGlowable = isCDMBar and IsNonGlowableCDMIcon(realBtn)
                local _rbTex = realBtn and ((ns._hookFrameData[realBtn] and ns._hookFrameData[realBtn].tex) or realBtn._tex)
                local hasAction = realBtn and ((realBtn.icon and realBtn.icon:GetTexture()) or (_rbTex and _rbTex:GetTexture()))
                local iconTex = bf:CreateTexture(nil, "ARTWORK")
                iconTex:SetAllPoints()
                UnsnapTex(iconTex)
                if hasAction then
                    local srcTex = (realBtn.icon and realBtn.icon:GetTexture()) or (_rbTex and _rbTex:GetTexture())
                    iconTex:SetTexture(srcTex)
                    -- Desaturate (preview only) non-glowable icons so it's visually clear they're not assignable.
                    if nonGlowable then iconTex:SetDesaturated(true) end
                    local z = zoom
                    if btnShape == "cropped" then
                        local t = isCDMBar and ns.CdmCropTrim(cdmBd) or 0.10
                        iconTex:SetTexCoord(z, 1 - z, z + t, 1 - z - t)
                    elseif z > 0 or square then
                        iconTex:SetTexCoord(z, 1 - z, z, 1 - z)
                    else
                        iconTex:SetTexCoord(0, 1, 0, 1)
                    end
                else
                    iconTex:SetColorTexture(0, 0, 0, 0.5)
                end

                -- Shape mask
                local SHAPE_MASKS = isCDMBar and ns.CDM_SHAPE_MASKS or AB_SHAPE_MASKS
                local SHAPE_BORDERS = isCDMBar and ns.CDM_SHAPE_BORDERS or AB_SHAPE_BORDERS
                if btnShape ~= "none" and btnShape ~= "cropped" and SHAPE_MASKS and SHAPE_MASKS[btnShape] then
                    local mask = bf:CreateMaskTexture()
                    mask:SetAllPoints(bf)
                    mask:SetTexture(SHAPE_MASKS[btnShape], "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
                    iconTex:AddMaskTexture(mask)
                    bgTex:AddMaskTexture(mask)
                    -- Store shape metadata for glow preview (StartNativeGlow reads these)
                    bf._shapeApplied = true
                    bf._shapeName = btnShape
                    bf._shapeMask = mask
                    -- Shape border (always created for hover/accent tinting; invisible when brdSize == 0)
                    if SHAPE_BORDERS and SHAPE_BORDERS[btnShape] then
                        local sbt = bf:CreateTexture(nil, "OVERLAY", nil, 6)
                        sbt:SetAllPoints(bf)
                        sbt:SetTexture(SHAPE_BORDERS[btnShape])
                        -- Direct ref for accent/hover tinting below. Never locate via a GetRegions
                        -- scan -- a freshly tracked CD's icon region carries secret values, and
                        -- GetDrawLayer comparisons on it error out mid page-build.
                        bf._sbt = sbt
                        if brdSize > 0 then
                            local cr, cg, cb = brdColor.r, brdColor.g, brdColor.b
                            if brdClassColor then
                                local _, ct = UnitClass("player")
                                if ct then local cc = RAID_CLASS_COLORS[ct]; if cc then cr, cg, cb = cc.r, cc.g, cc.b end end
                            end
                            sbt:SetVertexColor(cr, cg, cb, brdColor.a or 1)
                        else
                            sbt:SetVertexColor(0, 0, 0, 0)
                        end
                    end
                elseif brdSize > 0 then
                    -- Square borders via unified PP system
                    local cr, cg, cb, ca = brdColor.r, brdColor.g, brdColor.b, brdColor.a or 1
                    if brdClassColor then
                        local _, ct = UnitClass("player")
                        if ct then local cc = RAID_CLASS_COLORS[ct]; if cc then cr, cg, cb = cc.r, cc.g, cc.b end end
                    end
                    local PP = EllesmereUI and EllesmereUI.PP
                    if PP then PP.CreateBorder(bf, cr, cg, cb, ca, brdSize, "OVERLAY", 7) end
                end

                -- Accent border for buttons that have assignments
                local assignKey
                if isCDMBar and realBtn and realBtn.cooldownID then
                    assignKey = "cdm_" .. realBtn.cooldownID
                else
                    assignKey = barIdx .. "_" .. i
                end
                bf._assignKey = assignKey
                local assigns = bgData.assignments[assignKey]
                local hasAssign = assigns and #assigns > 0

                -- Pre-create accent border on every button (hidden unless needed)
                local accentCont = CreateFrame("Frame", nil, bf)
                accentCont:SetAllPoints()
                accentCont:SetFrameLevel(bf:GetFrameLevel() + 2)
                local PP2 = EllesmereUI and EllesmereUI.PP

                -- Active button gets accent border; assigned (non-active) buttons get white border
                -- For custom shapes, tint the shape border instead of showing square PP borders
                local isCustomShape = btnShape ~= "none" and btnShape ~= "cropped" and btnShape ~= "square" and btnShape ~= "csquare"
                    and SHAPE_MASKS and SHAPE_MASKS[btnShape]
                local accentBrd
                if not isCustomShape then
                    if isSelected then
                        accentBrd = PP2 and PP2.CreateBorder(accentCont, ACCENT.r, ACCENT.g, ACCENT.b, 1, 2, "OVERLAY", 7)
                    else
                        accentBrd = PP2 and PP2.CreateBorder(accentCont, 1, 1, 1, 0.6, 2, "OVERLAY", 7)
                    end
                    if accentBrd then accentBrd:Hide() end
                end

                -- Show active state
                if isSelected then
                    if isCustomShape then
                        if bf._sbt then
                            bf._sbt:SetVertexColor(ACCENT.r, ACCENT.g, ACCENT.b, 1)
                        end
                    elseif accentBrd then
                        accentBrd:Show()
                    end
                end

                -- Show white border for assigned buttons (even if not active)
                if hasAssign and not isSelected then
                    if isCustomShape then
                        if bf._sbt then
                            bf._sbt:SetVertexColor(1, 1, 1, 0.6)
                        end
                    elseif accentBrd then
                        accentBrd:Show()
                    end
                end

                -- Store refs so click handler can activate inline
                bf._accentBrd = accentBrd
                bf._accentCont = accentCont

                -- Button alpha: unassigned = 50%, assigned/active = 100%
                if isSelected or hasAssign then
                    bf:SetAlpha(1)
                else
                    bf:SetAlpha(0.50)
                end

                -- Hover swaps border to accent; active button needs none (already accent)
                bf._shapeBorderTex = isCustomShape and bf._sbt or nil
                local origBrdR, origBrdG, origBrdB, origBrdA = brdColor.r, brdColor.g, brdColor.b, brdColor.a or 1
                if isCDMBar and cdmBd then
                    origBrdR = cdmBd.borderR or 0
                    origBrdG = cdmBd.borderG or 0
                    origBrdB = cdmBd.borderB or 0
                    origBrdA = (cdmBd.borderSize or 1) > 0 and (cdmBd.borderA or 1) or 0
                elseif brdSize == 0 then
                    origBrdA = 0
                end
                if not isSelected and not nonGlowable then
                    if hasAssign then
                        bf:SetScript("OnEnter", function()
                            if isCustomShape and bf._shapeBorderTex then
                                bf._shapeBorderTex:SetVertexColor(ACCENT.r, ACCENT.g, ACCENT.b, 1)
                            elseif PP2 and accentCont then
                                PP2.SetBorderColor(accentCont, ACCENT.r, ACCENT.g, ACCENT.b, 1)
                            end
                        end)
                        bf:SetScript("OnLeave", function()
                            if isCustomShape and bf._shapeBorderTex then
                                bf._shapeBorderTex:SetVertexColor(1, 1, 1, 0.6)
                            elseif PP2 and accentCont then
                                PP2.SetBorderColor(accentCont, 1, 1, 1, 0.6)
                            end
                        end)
                    else
                        bf:SetScript("OnEnter", function()
                            bf:SetAlpha(0.55)
                            if isCustomShape and bf._shapeBorderTex then
                                bf._shapeBorderTex:SetVertexColor(ACCENT.r, ACCENT.g, ACCENT.b, 1)
                            else
                                if PP2 and accentCont then PP2.SetBorderColor(accentCont, ACCENT.r, ACCENT.g, ACCENT.b, 1) end
                                if accentBrd then accentBrd:Show() end
                            end
                        end)
                        bf:SetScript("OnLeave", function()
                            bf:SetAlpha(0.50)
                            if isCustomShape and bf._shapeBorderTex then
                                bf._shapeBorderTex:SetVertexColor(origBrdR, origBrdG, origBrdB, origBrdA)
                            else
                                if accentBrd then accentBrd:Hide() end
                            end
                        end)
                    end
                end

                -- Helper: visually activate this button without a full rebuild
                local function ActivateInline()
                    local PP3 = EllesmereUI and EllesmereUI.PP
                    -- Clear previous active button visuals
                    if headerFrame._activeBtnRef and headerFrame._activeBtnRef ~= bf then
                        local prev = headerFrame._activeBtnRef
                        -- Revert border: if prev has assignments, switch to white; otherwise hide
                        local prevKey = prev._assignKey or (barIdx .. "_" .. (prev._btnIdx or 0))
                        local prevAssigns = bgData.assignments[prevKey]
                        local prevHasAssign = prevAssigns and #prevAssigns > 0
                        if prevHasAssign then
                            if PP3 and prev._accentCont then PP3.SetBorderColor(prev._accentCont, 1, 1, 1, 0.6) end
                        else
                            if prev._accentBrd then prev._accentBrd:Hide() end
                            prev:SetAlpha(0.50)
                            -- Restore hover scripts
                            prev:SetScript("OnEnter", function()
                                prev:SetAlpha(0.55)
                                if PP3 and prev._accentCont then PP3.SetBorderColor(prev._accentCont, ACCENT.r, ACCENT.g, ACCENT.b, 1) end
                                if prev._accentBrd then prev._accentBrd:Show() end
                            end)
                            prev:SetScript("OnLeave", function()
                                prev:SetAlpha(0.50)
                                if prev._accentBrd then prev._accentBrd:Hide() end
                            end)
                        end
                    end
                    -- Show this button as active with accent color + full alpha
                    bf:SetAlpha(1)
                    if PP3 and accentCont then PP3.SetBorderColor(accentCont, ACCENT.r, ACCENT.g, ACCENT.b, 1) end
                    if accentBrd then accentBrd:Show() end
                    -- Remove hover toggle since border is now permanent
                    bf:SetScript("OnEnter", nil)
                    bf:SetScript("OnLeave", nil)
                    headerFrame._activeBtnRef = bf
                end
                bf._btnIdx = i

                -- Track the initially active button
                if isSelected then headerFrame._activeBtnRef = bf end

                -- Left click: select this button. Right click: select + toggle spell picker.
                bf:SetScript("OnClick", function(self, button)
                    -- Non-glowable icons ignore both clicks so no glow can be added.
                    if nonGlowable then return end
                    local pickerOpen = _bgSpellPickerMenu and _bgSpellPickerMenu:IsShown()
                    local pickerOnThis = pickerOpen and _bgSpellPickerMenu._btnIdx == i

                    if button == "LeftButton" then
                        -- Close picker first if open (before rebuild destroys anchor)
                        if pickerOpen then _bgSpellPickerMenu:Hide() end
                        _glowSelectedButton = i
                        ActivateInline()
                        EllesmereUI:RefreshPage(true)
                    elseif button == "RightButton" then
                        if pickerOnThis then
                            _bgSpellPickerMenu:Hide()
                            return
                        end
                        if pickerOpen then _bgSpellPickerMenu:Hide() end
                        _glowSelectedButton = i
                        ActivateInline()
                        EllesmereUI:RefreshPage(true)
                        C_Timer.After(0, function()
                            local newBf = _glowBtnFrames[i]
                            if newBf then
                                ShowBarGlowSpellPicker(newBf, barIdx, i, function()
                                    _glowSelectedButton = i
                                    EllesmereUI:RefreshPage(true)
                                end, newBf._assignKey)
                            end
                        end)
                    end
                end)
            end

            -- Tip text below the button grid
            local tipFS = headerFrame:CreateFontString(nil, "OVERLAY")
            tipFS:SetFont(FONT_PATH, 11, GetCDMOptOutline())
            tipFS:SetTextColor(1, 1, 1, 0.70)
            tipFS:SetPoint("TOP", headerFrame, "TOP", 0, -(20 + DD_H + 20 + scaledBtnH + 20))
            tipFS:SetText(EllesmereUI.L("Left click a button to edit its glow, right click to add a new glow"))

            return 20 + DD_H + 20 + scaledBtnH + 20 + 14 + 15
        end

        EllesmereUI:SetContentHeader(_glowHeaderBuilder)

        -- Live-updates preview icons on action-bar paging (stance/mount/vehicle). Skipped
        -- during a hidden search pre-build: cleanup relies on parent's OnHide, which may
        -- never fire under an already-hidden pre-build wrapper -- the listener (and its
        -- RefreshPage(true)) would leak for the session, and there's nothing to preview during indexing anyway.
        if not EllesmereUI._prebuilding then
            local pageListener = CreateFrame("Frame")
            local pagePending = false
            pageListener:RegisterEvent("ACTIONBAR_PAGE_CHANGED")
            pageListener:RegisterEvent("UPDATE_BONUS_ACTIONBAR")
            pageListener:RegisterEvent("PLAYER_MOUNT_DISPLAY_CHANGED")
            pageListener:SetScript("OnEvent", function()
                if pagePending then return end
                pagePending = true
                C_Timer.After(0.15, function()
                    pagePending = false
                    EllesmereUI:RefreshPage(true)
                end)
            end)
            parent:HookScript("OnHide", function()
                pageListener:UnregisterAllEvents()
            end)
        end

        -------------------------------------------------------------------
        --  Scrollable content area
        -------------------------------------------------------------------

        _, h = W:Spacer(parent, y, 8);  y = y - h

        -- A selected slot that is (now) non-glowable falls back to the hint instead of glow settings.
        if curBtn and type(curBar) == "string" then
            local cdmIcons = ns.cdmBarIcons and ns.cdmBarIcons[curBar]
            if IsNonGlowableCDMIcon(cdmIcons and cdmIcons[curBtn]) then
                curBtn = nil
            end
        end

        if not curBtn then
            local hintFrame = CreateFrame("Frame", nil, parent)
            hintFrame:SetSize(parent:GetWidth(), 40)
            hintFrame:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, y)
            local hintText = hintFrame:CreateFontString(nil, "OVERLAY")
            hintText:SetFont(FONT_PATH, 12, GetCDMOptOutline())
            hintText:SetTextColor(0.5, 0.5, 0.5, 1)
            hintText:SetPoint("CENTER")
            hintText:SetText(EllesmereUI.L("Left click a button to edit its glow, right click to add a new glow"))
            y = y - 40
        else
            local assignKey
            local isCurCDM = (type(curBar) == "string")
            if isCurCDM then
                local cdmIcons = ns.cdmBarIcons and ns.cdmBarIcons[curBar]
                local icon = cdmIcons and cdmIcons[curBtn]
                if icon and icon.cooldownID then
                    assignKey = "cdm_" .. icon.cooldownID
                end
            end
            if not assignKey then assignKey = curBar .. "_" .. curBtn end
            local buffList = bg.assignments[assignKey] or {}
            parent._showRowDivider = true

            if #buffList == 0 then
                _, h = W:Spacer(parent, y, 8);  y = y - h
                local emptyFrame = CreateFrame("Frame", nil, parent)
                emptyFrame:SetSize(parent:GetWidth(), 30)
                emptyFrame:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, y)
                local emptyText = emptyFrame:CreateFontString(nil, "OVERLAY")
                emptyText:SetFont(FONT_PATH, 12, GetCDMOptOutline())
                emptyText:SetTextColor(0.5, 0.5, 0.5, 1)
                emptyText:SetPoint("LEFT", 22, 0)
                emptyText:SetText(EllesmereUI.L("No buffs assigned. Right click a button in the preview to assign buffs."))
                y = y - 30
            else
                local glowLabels, glowOrder = GetGlowStyleValues()

                for aIdx, entry in ipairs(buffList) do
                    local buffName = "Unknown"
                    if entry.spellID and entry.spellID > 0 then
                        buffName = C_Spell.GetSpellName(entry.spellID) or ("Spell " .. entry.spellID)
                    end

                    -- cooldownID is a cooldown-viewer id, NOT a spell id (GetSpellName on it
                    -- returns an unrelated spell); resolve via the same canonical resolver
                    -- CD/utility bars use, falling back to cooldown viewer info.
                    local btnSpellName = "Button " .. curBtn
                    if isCurCDM then
                        local cdmIcons = ns.cdmBarIcons and ns.cdmBarIcons[curBar]
                        local icon = cdmIcons and cdmIcons[curBtn]
                        if icon then
                            local sid = ns.GetCanonicalSpellIDForFrame and ns.GetCanonicalSpellIDForFrame(icon)
                            if (not sid) and icon.cooldownID and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo then
                                local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(icon.cooldownID)
                                if info and info.spellID and info.spellID > 0 then sid = info.spellID end
                            end
                            if sid then btnSpellName = C_Spell.GetSpellName(sid) or btnSpellName end
                        end
                    else
                        local prefix = BAR_BUTTON_PREFIXES[curBar]
                        local realBtn = prefix and _G[prefix .. curBtn]
                        if realBtn and realBtn.action then
                            local aType, aID = GetActionInfo(realBtn.action)
                            if aType == "spell" and aID then
                                btnSpellName = C_Spell.GetSpellName(aID) or btnSpellName
                            elseif aType == "macro" then
                                local mName = GetMacroInfo(aID)
                                if mName then btnSpellName = mName end
                            end
                        end
                    end

                    _, h = W:SectionHeader(parent, btnSpellName .. " x " .. buffName, y);  y = y - h

                    -- Row 1: Glow When | Only In Combat
                    local modeRow
                    local removeAIdx = aIdx
                    modeRow, h = W:DualRow(parent, y,
                        { type = "dropdown", text = "Glow When",
                          values = BG_MODE_VALUES, order = BG_MODE_ORDER,
                          getValue = function() return entry.mode or "ACTIVE" end,
                          setValue = function(v)
                              entry.mode = v
                              Refresh()
                              EllesmereUI:RefreshPage()
                          end,
                        },
                        { type = "toggle", text = "Only In Combat",
                          getValue = function() return entry.onlyInCombat == true end,
                          setValue = function(v)
                              entry.onlyInCombat = v or nil
                              Refresh()
                          end,
                        }
                    );  y = y - h

                    -- Helper: resolve current glow color and restart preview if active
                    local pvKey = assignKey .. "_" .. aIdx
                    local function RefreshPreviewGlow()
                        if not _bgPreviewGlowActive[pvKey] then return end
                        local ov = _bgPreviewGlowOverlays[pvKey]
                        if not ov then return end
                        local style = BarHasCustomShape(curBar) and 2 or (entry.glowStyle or 1)
                        local cr, cg, cb
                        if entry.colorMode == "class" then
                            local cc = EllesmereUI.GetClassColor(EllesmereUI._playerClass)
                            cr, cg, cb = cc.r, cc.g, cc.b
                        elseif entry.colorMode == "custom" and entry.glowColor then
                            cr, cg, cb = entry.glowColor.r, entry.glowColor.g, entry.glowColor.b
                        end
                        ns.StopNativeGlow(ov)
                        ns.StartNativeGlow(ov, style, cr, cg, cb, EllesmereUI.Glows.PANEL_EXTRA)
                    end

                    -- At Stacks (toggle) + gear (Comparison / Stack Count), paired with
                    -- Glow Type so every row stays filled. Same operator set and same
                    -- fail-open bias as the per-icon Glow at Stacks feature (Stack Text
                    -- and Glows cog): an unknown/secret application count never blocks
                    -- the glow.
                    local stackRow
                    stackRow, h = W:DualRow(parent, y,
                        { type = "toggle", text = "At Stacks",
                          tooltip = "Only glow once the buff's stack count matches the comparison set via the gear.",
                          disabled = function() return entry.mode == "MISSING" end,
                          disabledTooltip = "Not available in Buff Missing mode",
                          getValue = function() return entry.stackEnabled == true end,
                          setValue = function(v)
                              entry.stackEnabled = v or nil
                              Refresh()
                              EllesmereUI:RefreshPage()
                          end,
                        },
                        { type = "dropdown", text = "Glow Type",
                          values = glowLabels, order = glowOrder,
                          disabled = function() return BarHasCustomShape(curBar) end,
                          disabledTooltip = "This option is not available for custom shaped icons",
                          getValue = function()
                              if BarHasCustomShape(curBar) then return 2 end
                              return entry.glowStyle or 1
                          end,
                          setValue = function(v)
                              entry.glowStyle = tonumber(v) or 1
                              Refresh()
                              RefreshPreviewGlow()
                          end,
                        }
                    );  y = y - h
                    do
                        local rgn = stackRow._leftRegion
                        EllesmereUI.BuildInlineCog(rgn, {
                            title = "At Stacks",
                            disabled = function() return entry.mode == "MISSING" or not entry.stackEnabled end,
                            disabledTooltip = function()
                                return entry.mode == "MISSING" and "This option is not available in Buff Missing mode" or "At Stacks"
                            end,
                            frameStrata = "FULLSCREEN_DIALOG", frameLevel = 350,
                            rows = {
                                { type = "dropdown", label = "Comparison",
                                  values = { lt = "Below (<)", lte = "At Most (<=)", eq = "Exactly (=)", gte = "At Least (>=)", gt = "Above (>)" },
                                  order = { "lt", "lte", "eq", "gte", "gt" },
                                  get = function() return entry.stackOperator or "gte" end,
                                  set = function(v)
                                      entry.stackOperator = v ~= "gte" and v or nil
                                      Refresh()
                                  end },
                                { type = "input", label = "Stack Count", inputWidth = 42, commitOnBlur = true,
                                  get = function() return tostring(tonumber(entry.stackThreshold) or 2) end,
                                  set = function(v)
                                      local t = math.floor(tonumber(v) or 2)
                                      if t < 1 then t = 1 end
                                      if t > 99 then t = 99 end
                                      entry.stackThreshold = t
                                      Refresh()
                                  end },
                            },
                        })
                    end

                    -- Eyeball preview toggle (on right region of the At Stacks / Glow Type row)
                    if not EllesmereUI._prebuilding then
                        local EYE_VIS   = EllesmereUI.EYE_VISIBLE_ICON
                        local EYE_INVIS = EllesmereUI.EYE_INVISIBLE_ICON
                        local leftRgn = stackRow._rightRegion
                        if leftRgn and leftRgn._control then
                            local eyeBtn = CreateFrame("Button", nil, leftRgn)
                            eyeBtn:SetSize(26, 26)
                            eyeBtn:SetPoint("RIGHT", leftRgn._control, "LEFT", -8, 0)
                            eyeBtn:SetFrameLevel(leftRgn:GetFrameLevel() + 5)
                            eyeBtn:SetAlpha(0.4)
                            local eyeTex = eyeBtn:CreateTexture(nil, "OVERLAY")
                            eyeTex:SetAllPoints()
                            local function RefreshEye()
                                eyeTex:SetTexture(_bgPreviewGlowActive[pvKey] and EYE_INVIS or EYE_VIS)
                            end
                            RefreshEye()
                            eyeBtn:SetScript("OnClick", function()
                                local previewBtn = _glowBtnFrames[curBtn]
                                if not previewBtn then return end
                                if not _bgPreviewGlowOverlays[pvKey] then
                                    local ov = CreateFrame("Frame", nil, previewBtn)
                                    ov:SetAllPoints(previewBtn)
                                    ov:SetFrameLevel(previewBtn:GetFrameLevel() + 10)
                                    ov._euiGlowPreview = true  -- exempt from Show Glows Only in Combat
                                    _bgPreviewGlowOverlays[pvKey] = ov
                                end
                                local ov = _bgPreviewGlowOverlays[pvKey]
                                if _bgPreviewGlowActive[pvKey] then
                                    ns.StopNativeGlow(ov)
                                    _bgPreviewGlowActive[pvKey] = false
                                    -- Restore accent border
                                    if previewBtn._accentBrd then previewBtn._accentBrd:Show() end
                                else
                                    local style = BarHasCustomShape(curBar) and 2 or (entry.glowStyle or 1)
                                    local cr, cg, cb
                                    if entry.colorMode == "class" then
                                        local cc = EllesmereUI.GetClassColor(EllesmereUI._playerClass)
                                        cr, cg, cb = cc.r, cc.g, cc.b
                                    elseif entry.colorMode == "custom" and entry.glowColor then
                                        cr, cg, cb = entry.glowColor.r, entry.glowColor.g, entry.glowColor.b
                                    end
                                    ns.StartNativeGlow(ov, style, cr, cg, cb, EllesmereUI.Glows.PANEL_EXTRA)
                                    _bgPreviewGlowActive[pvKey] = true
                                    -- Hide accent border so glow is visible
                                    if previewBtn._accentBrd then previewBtn._accentBrd:Hide() end
                                end
                                RefreshEye()
                            end)
                            eyeBtn:SetScript("OnEnter", function(self) self:SetAlpha(0.7) end)
                            eyeBtn:SetScript("OnLeave", function(self) self:SetAlpha(0.4) end)
                        end
                    end

                    -- Row: Glow Color (swatches) | Remove Glow
                    local colorRow
                    colorRow, h = W:DualRow(parent, y,
                        { type = "label", text = "Glow Color" },
                        { type = "labeledButton", text = "Remove Glow", buttonText = "Remove", width = 150,
                          onClick = function()
                              table.remove(buffList, removeAIdx)
                              if #buffList == 0 then
                                  bg.assignments[assignKey] = nil
                              end
                              Refresh()
                              EllesmereUI:RefreshPage(true)
                          end,
                        }
                    );  y = y - h

                    -- Inline color swatch for glow color (on left region)
                    if not EllesmereUI._prebuilding then
                        local leftRgn = colorRow._leftRegion
                        if leftRgn and EllesmereUI.BuildTrioColorSwatch then
                            local glowSwatch, defaultSwatch, classSwatch = EllesmereUI.BuildTrioColorSwatch(
                                leftRgn, colorRow:GetFrameLevel() + 3,
                                {
                                    getMode = function() return entry.colorMode or "default" end,
                                    setMode = function(m) entry.colorMode = m end,
                                    getCustomRGB = function()
                                        local c = entry.glowColor or { r = 1.0, g = 0.788, b = 0.137 }
                                        return c.r, c.g, c.b
                                    end,
                                    setCustomRGB = function(r, g, b)
                                        entry.glowColor = { r = r, g = g, b = b }
                                    end,
                                    hasClassColor = true,
                                    onChange = function() Refresh(); RefreshPreviewGlow(); EllesmereUI:RefreshPage() end,
                                    overrideSize = 20,
                                })
                            PP.Point(classSwatch, "RIGHT", leftRgn, "RIGHT", -20, 0)
                            PP.Point(glowSwatch, "RIGHT", classSwatch, "LEFT", -8, 0)
                            PP.Point(defaultSwatch, "RIGHT", glowSwatch, "LEFT", -8, 0)
                        end
                    end

                    -- Buff icon to the LEFT of the Remove button
                    do
                        local rightRgn = colorRow._rightRegion
                        if rightRgn and rightRgn._control then
                            local btn = rightRgn._control
                            local btnH = btn:GetHeight()
                            local ico = rightRgn:CreateTexture(nil, "ARTWORK")
                            ico:SetSize(btnH, btnH)
                            PP.Point(ico, "RIGHT", btn, "LEFT", -8, 0)
                            ico:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                            if entry.spellID and entry.spellID > 0 then
                                local info = C_Spell.GetSpellInfo(entry.spellID)
                                if info and info.iconID then
                                    ico:SetTexture(info.iconID)
                                end
                            end
                        end
                    end
                end
            end
        end

        return math.abs(y)
    end

    ---------------------------------------------------------------------------
    --  Buff Bars page: per-bar tracked buff bars with individual settings
    ---------------------------------------------------------------------------
    local _tbbSelectedBar = 1
    local _tbbSelectedGroup      -- nil = editing a bar; gid = editing that group
    -- Deep-link helper (Global Settings > Glows): select a tracking bar by index.
    function ns._TBBSelectBar(idx)
        _tbbSelectedBar = idx
        _tbbSelectedGroup = nil
    end
    local _tbbDDBtn              -- live management-dropdown button (picker anchor)
    local _tbbNavigateFn         -- set per page build: click-to-scroll handler

    ---------------------------------------------------------------------------
    --  Popout preview docked to the options panel's left edge (raid-frame overlay
    --  preview pattern). Bars are built/skinned by the SAME runtime functions as live
    --  bars (CreateTBBBarFrame/ApplyTBBBarSettings), then dressed with sample fill/timer/
    --  stacks. Bar mode: selected bar with click-to-scroll overlays. Group mode: every
    --  bar of the group chained with its grow/spacing, each clickable to edit.
    ---------------------------------------------------------------------------
    local _tbbPopout
    local _tbbPopoutBars = {}     -- pooled preview wraps (runtime-built)

    local function GetTBBPopout()
        if _tbbPopout then return _tbbPopout end
        local oc = CreateFrame("Frame", nil, UIParent)
        oc:SetFrameStrata("FULLSCREEN_DIALOG")
        oc:SetFrameLevel(10)
        oc:SetClampedToScreen(true)
        oc:Hide()
        local bg = oc:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0, 0, 0, 0.9)
        local title = oc:CreateFontString(nil, "OVERLAY")
        title:SetFont(FONT_PATH, 13, GetCDMOptOutline())
        title:SetPoint("TOP", oc, "TOP", 0, -7)
        title:SetTextColor(1, 1, 1, 0.9)
        oc._title = title
        local hint = oc:CreateFontString(nil, "OVERLAY")
        hint:SetFont(FONT_PATH, 10, GetCDMOptOutline())
        hint:SetPoint("BOTTOM", oc, "BOTTOM", 0, 7)
        hint:SetTextColor(1, 1, 1, 0.4)
        oc._hint = hint
        _tbbPopout = oc
        return oc
    end

    local function HideTBBPopout()
        if _tbbPopout then _tbbPopout:Hide() end
    end

    -- Pooled hover/click overlay on a preview element (green border, like unit frame
    -- preview overlays); retargeted every refresh.
    local function TBBPvNavButton(wrap, key)
        wrap._pvNav = wrap._pvNav or {}
        local btn = wrap._pvNav[key]
        if not btn then
            btn = CreateFrame("Button", nil, wrap)
            local c = EllesmereUI.ELLESMERE_GREEN
            btn._brd = PP.CreateBorder(btn, c.r, c.g, c.b, 1, 2, "OVERLAY", 7)
            btn._brd:Hide()
            btn:SetScript("OnEnter", function(self)
                self._brd:Show()
                if self._tip then EllesmereUI.ShowWidgetTooltip(self, self._tip) end
            end)
            btn:SetScript("OnLeave", function(self)
                self._brd:Hide()
                EllesmereUI.HideWidgetTooltip()
            end)
            btn:SetScript("OnMouseDown", function(self)
                if self._onNav then self._onNav() end
            end)
            wrap._pvNav[key] = btn
        end
        return btn
    end

    local function HideTBBPvNav(wrap)
        if not wrap._pvNav then return end
        for _, b in pairs(wrap._pvNav) do b:Hide() end
    end

    -- Attach nav overlays for one preview bar. Bar mode: element overlays scroll to and
    -- flash their option rows; group mode: one whole-bar overlay selects the bar for editing.
    local function UpdateTBBPvNav(wrap, mode, barIdx)
        HideTBBPvNav(wrap)
        if mode == "group" then
            local btn = TBBPvNavButton(wrap, "select")
            btn:ClearAllPoints()
            btn:SetAllPoints(wrap)
            btn:SetFrameLevel(wrap:GetFrameLevel() + 30)
            btn._tip = EllesmereUI.L("Click to edit this bar")
            btn._onNav = function()
                _tbbSelectedBar = barIdx
                _tbbSelectedGroup = nil
                EllesmereUI:RefreshPage(true)
            end
            btn:Show()
            return
        end
        local sb = wrap._bar
        local function ElemBtn(key, elem, isText)
            if not elem or not elem.IsShown or not elem:IsShown() then return end
            if isText and (elem:GetText() or "") == "" then return end
            local btn = TBBPvNavButton(wrap, key)
            btn:ClearAllPoints()
            if isText then
                local tw = (elem:GetStringWidth() or 0) + 6
                local th = (elem:GetStringHeight() or 0) + 6
                if tw < 14 then tw = 14 end
                if th < 14 then th = 14 end
                btn:SetSize(tw, th)
                -- Anchor by justification: FontString width > string width, so CENTER isn't where glyphs render.
                local justify = elem.GetJustifyH and elem:GetJustifyH() or "LEFT"
                if justify == "RIGHT" then
                    btn:SetPoint("RIGHT", elem, "RIGHT", 2, 0)
                elseif justify == "CENTER" then
                    btn:SetPoint("CENTER", elem, "CENTER", 0, 0)
                else
                    btn:SetPoint("LEFT", elem, "LEFT", -2, 0)
                end
            else
                btn:SetAllPoints(elem)
            end
            btn:SetFrameLevel(wrap:GetFrameLevel() + (isText and 32 or 30))
            btn._tip = nil
            btn._onNav = function()
                if _tbbNavigateFn then _tbbNavigateFn(key) end
            end
            btn:Show()
        end
        ElemBtn("barFill", sb, false)
        ElemBtn("icon", wrap._icon, false)
        ElemBtn("nameText", wrap._nameText, true)
        ElemBtn("timerText", wrap._timerText, true)
        ElemBtn("stacksText", wrap._stacksText, true)
    end

    -- Preview-only dressing over live skinning: sample fill, sample timer/stacks text,
    -- resolved name/icon, and the unassigned overlay.
    local function DressTBBPopoutBar(wrap, cfg)
        local sb = wrap._bar
        sb:SetMinMaxValues(0, 1)
        sb:SetValue(0.65)
        if wrap._timerText and wrap._timerText:IsShown() then
            wrap._timerText:SetText("3.2")
        end
        -- Stacks visibility is tick-driven on live bars; drive it from cfg here
        if wrap._stacksText then
            if (cfg.stacksPosition or "center") ~= "none" then
                wrap._stacksText:SetText("3")
                wrap._stacksText:Show()
            else
                wrap._stacksText:Hide()
            end
        end
        local unassigned = (not cfg.spellID or cfg.spellID == 0) and not cfg.glowBased
        -- Name (same resolution as the live build)
        if wrap._nameText and wrap._nameText:IsShown() then
            local displayName = cfg.name
            if (not displayName or displayName == "" or displayName == "New Bar")
               and cfg.spellID and cfg.spellID > 0 then
                local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(cfg.spellID)
                displayName = (info and info.name) or displayName
            end
            if unassigned then displayName = "" end
            wrap._nameText:SetText(EllesmereUI.L(displayName or ""))
        end
        -- Icon texture (same resolution as the live build; question mark when no buff assigned yet)
        if wrap._icon and wrap._icon:IsShown() and wrap._icon._tex then
            local iconID
            if cfg.popularKey and ns.TBB_POPULAR_BUFFS then
                for _, pe in ipairs(ns.TBB_POPULAR_BUFFS) do
                    if pe.key == cfg.popularKey then iconID = pe.icon; break end
                end
            end
            if not iconID and cfg.spellID and cfg.spellID > 0 then
                local spInfo = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(cfg.spellID)
                iconID = spInfo and spInfo.iconID
            end
            wrap._icon._tex:SetTexture(iconID or 134400)
        end
        -- Unassigned: dim ALL bar content (fill/texts/icon/border) under a black overlay
        -- frame with a centered hint, above the bar's own layers so it draws over the fill/gradient stack.
        if not wrap._pvDarkFrame then
            local df = CreateFrame("Frame", nil, wrap)
            df:SetAllPoints(wrap)
            local tex = df:CreateTexture(nil, "ARTWORK")
            tex:SetAllPoints()
            tex:SetColorTexture(0, 0, 0, 0.6)
            local hintFS = df:CreateFontString(nil, "OVERLAY")
            hintFS:SetFont(FONT_PATH, 11, GetCDMOptOutline())
            hintFS:SetTextColor(1, 1, 1, 1)
            hintFS:SetJustifyH("CENTER")
            hintFS:SetText(EllesmereUI.L("Choose a buff from the bar menu"))
            wrap._pvDarkFrame = df
            wrap._pvHint = hintFS
        end
        -- Frame level: above text overlay (+6) and border (+5), below click overlays (+30).
        wrap._pvDarkFrame:SetFrameLevel(wrap:GetFrameLevel() + 20)
        wrap._pvHint:ClearAllPoints()
        wrap._pvHint:SetPoint("CENTER", sb, "CENTER", 0, 0)
        wrap._pvDarkFrame:SetShown(unassigned)
    end

    -- Vertical headroom for texts anchored above/below the bar (outside its bounds).
    local function TBBPvTextPad(cfg, side)
        local tp = cfg.timerPosition or (cfg.showTimer and "right" or "none")
        local sp = cfg.stacksPosition or "center"
        local np = cfg.verticalOrientation and "none"
            or (cfg.namePosition or ((cfg.showName ~= false) and "left" or "none"))
        local p = 0
        if tp == side then p = math.max(p, cfg.timerSize or 11) end
        if sp == side then p = math.max(p, cfg.stacksSize or 11) end
        if np == side then p = math.max(p, cfg.nameSize or 11) end
        return p > 0 and (p + 8) or 0
    end

    -- HARD gate for BOTH Tracking Bars preview systems (popout + unlock-style
    -- placeholders): never visible unless the panel is actually OPEN on the Tracking
    -- Bars page. activeModule/activePage alone is NOT enough -- both persist after close,
    -- and event-driven refreshes (saved positions, spec/instance events) rebuild this page with the panel hidden. Every show path funnels through this check.
    local function TBBPreviewAllowed()
        -- Folded to the mini window counts as closed (the page is off screen).
        if not (EllesmereUI:IsShown()) or EllesmereUI._panelCollapsed then return false end
        -- nil = mid-build (page state not stamped); builders only run for the page shown, so only a definite mismatch blocks.
        local am = EllesmereUI:GetActiveModule()
        local ap = EllesmereUI:GetActivePage()
        if am and ap and (am ~= "EllesmereUICooldownManager" or ap ~= PAGE_BUFF_BARS) then
            return false
        end
        return true
    end

    local function RefreshTBBPopout()
        if not TBBPreviewAllowed() then
            HideTBBPopout()
            return
        end
        local t = ns.GetTrackedBuffBars()
        local bars = t and t.bars or {}

        -- Configs to render: the selected group's members, or the selected bar
        local list = {}
        local mode = "bar"
        if _tbbSelectedGroup then
            mode = "group"
            for i, c in ipairs(bars) do
                if ns.TBBBarGroupID(c) == _tbbSelectedGroup then
                    list[#list + 1] = { idx = i, cfg = c }
                end
            end
        else
            local c = bars[_tbbSelectedBar]
            if c then list[1] = { idx = _tbbSelectedBar, cfg = c } end
        end
        if #list == 0 then HideTBBPopout(); return end

        local oc = GetTBBPopout()

        -- Build/refresh each preview bar with the LIVE bar code
        for n, e in ipairs(list) do
            local wrap = _tbbPopoutBars[n]
            if not wrap then
                wrap = ns.CreateTBBBarFrame(oc, "Pv" .. n)
                _tbbPopoutBars[n] = wrap
                -- Width-gated geometry (charge hash lines, threshold ticks) silently skips
                -- while a fresh pool bar's fill size is 0; live bars re-drive from the timer
                -- tick, previews have none, so re-drive when size resolves.
                if wrap._bar then
                    wrap._bar:SetScript("OnSizeChanged", function(sbSelf)
                        local cfg = wrap._pvCfg
                        if not cfg then return end
                        if ns.ApplyTBBChargeHashLines then
                            local mc = ns.GetTBBMaxCharges and ns.GetTBBMaxCharges(cfg)
                            ns.ApplyTBBChargeHashLines(wrap, cfg, mc)
                        end
                        if ns.ApplyTBBTickMarks then
                            ns.ApplyTBBTickMarks(sbSelf, cfg, wrap._threshTicks,
                                cfg.verticalOrientation, wrap._tickOverlay)
                            wrap._ticksDirty = nil
                        end
                    end)
                end
            end
            wrap._pvCfg = e.cfg
            ns.ApplyTBBBarSettings(wrap, e.cfg)
            -- The apply path pins the wrap to the bar's own strata (cfg.strata,
            -- MEDIUM default); lift into the popout's strata AFTER each apply
            -- and re-assert the constructor's child levels (a parent strata
            -- change resets child frame levels). Guarded so refreshes that
            -- didn't touch strata skip the re-stack; level checked too, else a
            -- bar whose OWN strata is the popout's would dodge the lift.
            local base = oc:GetFrameLevel() + 20
            if wrap:GetFrameStrata() ~= "FULLSCREEN_DIALOG" or wrap:GetFrameLevel() ~= base then
                wrap:SetFrameStrata("FULLSCREEN_DIALOG")
                wrap:SetFrameLevel(base)
                local sb = wrap._bar
                if sb then sb:SetFrameLevel(base + 1) end
                if wrap._gradClip and sb then wrap._gradClip:SetFrameLevel(sb:GetFrameLevel() + 1) end
                if wrap._chargeHashFillClip and sb then wrap._chargeHashFillClip:SetFrameLevel(sb:GetFrameLevel() + 1) end
                if wrap._threshOverlays and sb then
                    for i = 1, #wrap._threshOverlays do
                        local ov = wrap._threshOverlays[i]
                        if ov then ov:SetFrameLevel(sb:GetFrameLevel() + 2) end
                    end
                end
                if wrap._sparkOverlay and sb then wrap._sparkOverlay:SetFrameLevel(sb:GetFrameLevel() + 3) end
                -- Tick overlay reassert; matches the live-bar block.
                if wrap._tickOverlay and sb then wrap._tickOverlay:SetFrameLevel(sb:GetFrameLevel() + 4) end
                if wrap._chargeHashOverlay and sb then wrap._chargeHashOverlay:SetFrameLevel(sb:GetFrameLevel() + 5) end
                -- base+6 matches the live-bar reassert: keeps the border above
                -- the tick overlay (sb+4 = base+5), which wins ties via lazy
                -- creation.
                if wrap._barBorder then wrap._barBorder:SetFrameLevel(base + 6) end
                if wrap._pandemicGlowOverlay then wrap._pandemicGlowOverlay:SetFrameLevel(base + 7) end
                if wrap._textOverlay and sb then wrap._textOverlay:SetFrameLevel(sb:GetFrameLevel() + 7) end
            end
            DressTBBPopoutBar(wrap, e.cfg)
            -- Reused pool bars already have a resolved size, so OnSizeChanged may never
            -- fire here: consume the deferred tick-mark pass (apply path drew hash lines itself when sized).
            local psb = wrap._bar
            if wrap._ticksDirty and psb and psb:GetWidth() > 0 and ns.ApplyTBBTickMarks then
                ns.ApplyTBBTickMarks(psb, e.cfg, wrap._threshTicks,
                    e.cfg.verticalOrientation, wrap._tickOverlay)
                wrap._ticksDirty = nil
            end
            wrap:Show()
        end
        for n = #list + 1, #_tbbPopoutBars do
            if _tbbPopoutBars[n] then
                HideTBBPvNav(_tbbPopoutBars[n])
                _tbbPopoutBars[n]:Hide()
            end
        end

        -- Chain layout: single bar centered; group members chained with the
        -- group's grow/spacing, exactly like the live BuildTrackedBuffBars
        local PAD_IN, TITLE_H = 20, 25
        local growDir, spacing = "DOWN", 2
        if mode == "group" then
            growDir = (ns.TBBGroupGrow(_tbbSelectedGroup) or "DOWN"):upper()
            spacing = ns.TBBGroupSpacing(_tbbSelectedGroup) or 2
        end
        local horizontalChain = mode == "group" and (growDir == "LEFT" or growDir == "RIGHT")

        local totalW, totalH = 0, 0
        for n = 1, #list do
            local wrap = _tbbPopoutBars[n]
            local w2, h2 = wrap:GetWidth(), wrap:GetHeight()
            if mode ~= "group" then
                totalW, totalH = w2, h2
            elseif horizontalChain then
                totalW = totalW + w2 + (n > 1 and spacing or 0)
                if h2 > totalH then totalH = h2 end
            else
                totalH = totalH + h2 + (n > 1 and spacing or 0)
                if w2 > totalW then totalW = w2 end
            end
        end
        local topPad, botPad = 0, 0
        for _, e in ipairs(list) do
            topPad = math.max(topPad, TBBPvTextPad(e.cfg, "top"))
            botPad = math.max(botPad, TBBPvTextPad(e.cfg, "bottom"))
        end

        -- Footer hint
        local hintH = 0
        if mode == "bar" then
            if not (EllesmereUIDB and EllesmereUIDB.previewHintDismissed) then
                oc._hint:SetText(EllesmereUI.L("Click elements to scroll to and highlight their options"))
                oc._hint:Show()
                hintH = 18
            else
                oc._hint:Hide()
            end
        else
            oc._hint:SetText(EllesmereUI.L("Click a bar to edit it"))
            oc._hint:Show()
            hintH = 18
        end

        oc:SetSize(math.max(totalW + PAD_IN * 2, 240),
            totalH + topPad + botPad + PAD_IN * 2 + TITLE_H + hintH)

        local firstY = -(PAD_IN + TITLE_H + topPad)
        local prev
        for n = 1, #list do
            local wrap = _tbbPopoutBars[n]
            wrap:ClearAllPoints()
            if n == 1 then
                if mode == "group" and growDir == "UP" then
                    wrap:SetPoint("BOTTOM", oc, "BOTTOM", 0, PAD_IN + botPad + hintH)
                elseif mode == "group" and growDir == "RIGHT" then
                    wrap:SetPoint("TOPLEFT", oc, "TOPLEFT", PAD_IN, firstY)
                elseif mode == "group" and growDir == "LEFT" then
                    wrap:SetPoint("TOPRIGHT", oc, "TOPRIGHT", -PAD_IN, firstY)
                else
                    wrap:SetPoint("TOP", oc, "TOP", 0, firstY)
                end
            else
                -- Same relative chain the live bars use
                if growDir == "UP" then
                    wrap:SetPoint("BOTTOM", prev, "TOP", 0, spacing)
                elseif growDir == "RIGHT" then
                    wrap:SetPoint("LEFT", prev, "RIGHT", spacing, 0)
                elseif growDir == "LEFT" then
                    wrap:SetPoint("RIGHT", prev, "LEFT", -spacing, 0)
                else
                    wrap:SetPoint("TOP", prev, "BOTTOM", 0, -spacing)
                end
            end
            prev = wrap
            UpdateTBBPvNav(wrap, mode, list[n].idx)
        end

        if mode == "group" then
            local gname = (ns.TBBGroupName and ns.TBBGroupName(_tbbSelectedGroup))
                or (EllesmereUI.L("Group") .. " " .. _tbbSelectedGroup)
            oc._title:SetText(gname .. " " .. EllesmereUI.L("Preview"))
        else
            oc._title:SetText(EllesmereUI.L("Preview"))
        end

        -- Dock to the left edge of the options panel, vertically centered
        oc:ClearAllPoints()
        local sf = EllesmereUI._scrollFrame
        if sf then
            oc:SetPoint("RIGHT", sf, "LEFT", 0, 0)
        else
            oc:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        end
        oc:Show()
    end

    -- Pool of unlock placeholders, one per bar (module-scope for cross-page access)
    local _tbbPlaceholders = {}
    local function UpdateTBBPlaceholder()
        -- Same hard gate as the popout: never show (or set placeholder mode) with the
        -- panel closed or another page in front. HideTBBPlaceholder is declared below.
        if not TBBPreviewAllowed() then
            ns._tbbPlaceholderMode = false
            for _, ph in ipairs(_tbbPlaceholders) do
                if ph then ph:Hide() end
            end
            HideTBBPopout()
            return
        end
        ns._tbbPlaceholderMode = true
        -- The TBB tick may be idle-asleep; placeholders render from the tick.
        if ns.WakeTBBTick then ns.WakeTBBTick() end
        local tbb = ns.GetTrackedBuffBars()
        local bars = tbb and tbb.bars
        if not bars then return end
        for i, _ in ipairs(bars) do
            local liveBar = ns.GetTBBFrame and ns.GetTBBFrame(i)
            if liveBar then
                if not _tbbPlaceholders[i] then
                    _tbbPlaceholders[i] = EllesmereUI.BuildUnlockPlaceholder({
                        parent = liveBar,
                        onClick = function()
                            if EllesmereUI._openUnlockMode then
                                EllesmereUI._unlockReturnModule = EllesmereUI:GetActiveModule()
                                EllesmereUI._unlockReturnPage   = EllesmereUI:GetActivePage()
                                C_Timer.After(0, EllesmereUI._openUnlockMode)
                            end
                        end,
                    })
                else
                    local ph = _tbbPlaceholders[i]
                    ph:SetParent(liveBar)
                    ph:SetAllPoints(liveBar)
                    ph:SetFrameLevel(liveBar:GetFrameLevel() + 10)
                end
                _tbbPlaceholders[i]:Show()
                liveBar:Show()
            end
        end
        -- Hide any leftover placeholders from deleted bars
        for i = (#bars + 1), #_tbbPlaceholders do
            if _tbbPlaceholders[i] then _tbbPlaceholders[i]:Hide() end
        end
    end
    local function HideTBBPlaceholder()
        ns._tbbPlaceholderMode = false
        for _, ph in ipairs(_tbbPlaceholders) do
            if ph then ph:Hide() end
        end
        -- The popout preview lives and dies with the page, same as placeholders
        -- (runs on every page-leave/panel-close path).
        HideTBBPopout()
    end
    ns.HideTBBPlaceholders = HideTBBPlaceholder
    ns.ShowTBBPlaceholders = UpdateTBBPlaceholder
    EllesmereUI:RegisterOnHide(HideTBBPlaceholder)
    -- Re-show placeholders when the panel re-opens on Tracking Bars. Exiting unlock mode
    -- to the SAME page skips SelectPage (currentPage == restorePage), so the page-restore
    -- hook that calls ShowTBBPlaceholders never fires; this OnShow re-asserts them.
    local function ReassertTBBPreviews()
        local am = EllesmereUI:GetActiveModule()
        local ap = EllesmereUI:GetActivePage()
        if am == "EllesmereUICooldownManager" and ap == PAGE_BUFF_BARS then
            UpdateTBBPlaceholder()
            RefreshTBBPopout()
        end
    end
    EllesmereUI:RegisterOnShow(ReassertTBBPreviews)
    -- The popout sits on UIParent beside the panel: it folds away with the panel
    -- and comes back with it (the live-bar placeholders stay up as the preview).
    EllesmereUI:RegisterOnCollapse(function(on)
        if on then HideTBBPopout() else ReassertTBBPreviews() end
    end)

    -- Every CDM page + its selected-bar index are per-spec, but the options panel caches
    -- built pages, so after a swap the cache holds the PREVIOUS spec's wrappers. A shared-
    -- profile spec swap never runs RefreshAllAddons (the cache clear), so without explicit
    -- invalidation reopening serves stale content: drop the CDM page cache, RefreshPage in place if open.
    local _tbbRefreshFn
    local function HandleTBBSpecChange()
        _tbbSelectedBar = 1
        _tbbSelectedGroup = nil
        EllesmereUI:InvalidateModulePageCache("EllesmereUICooldownManager")
        if EllesmereUI:IsShown()
            and EllesmereUI:GetActiveModule() == "EllesmereUICooldownManager"
            and EllesmereUI.RefreshPage then
            -- Panel open on a CDM page: rebuild now (content-header dropdown + body).
            EllesmereUI:RefreshPage(true)
        else
            -- Panel closed (or another module): reopening takes the fast RefreshPage path
            -- (dropdown not rebuilt) and SelectPage early-returns on the same page, so the
            -- dropdown would keep the previous spec's bar. Flag a cold rebuild for next show.
            ns._cdmColdRebuildOnShow = true
        end
    end

    -- Authoritative trigger: CDM's ProcessSpecChange calls this AFTER swapping the
    -- spec-key cache (_cachedSpecKey), so the rebuild reads the NEW spec. The
    -- PLAYER_SPECIALIZATION_CHANGED watcher below is a backup (covers panel-closed cache
    -- drop too); it can fire early and read the old spec, but ProcessSpecChange corrects it after.
    ns.OnTBBSpecChanged = HandleTBBSpecChange

    local _tbbSpecWatcher = CreateFrame("Frame")
    _tbbSpecWatcher:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    _tbbSpecWatcher:SetScript("OnEvent", HandleTBBSpecChange)

    -- Bars auto-added while the panel sits on Tracking Bars (e.g. user drags a new spell
    -- into Blizzard's Tracked Bars and returns): rebuild the open page immediately.
    ns.OnTBBBarsAutoAdded = function()
        if EllesmereUI:IsShown()
            and EllesmereUI:GetActiveModule() == "EllesmereUICooldownManager"
            and EllesmereUI:GetActivePage() == PAGE_BUFF_BARS
            and EllesmereUI.RefreshPage then
            EllesmereUI:RefreshPage(true)
        end
    end

    -- A spec swap while the panel is CLOSED can't rebuild (nothing shown); honor the
    -- pending cold rebuild here so reopening directly onto a CDM page rebuilds fresh.
    EllesmereUI:RegisterOnShow(function()
        if not ns._cdmColdRebuildOnShow then return end
        if EllesmereUI:GetActiveModule() == "EllesmereUICooldownManager"
            and EllesmereUI.RefreshPage then
            ns._cdmColdRebuildOnShow = false
            EllesmereUI:RefreshPage(true)
        end
    end)

    -- Buff spell picker for tracked buff bars (reuses CDM buff spell list)
    local _tbbSpellPickerMenu

    EllesmereUI:RegisterOnHide(function()
        if _tbbSpellPickerMenu then _tbbSpellPickerMenu:Hide() end
    end)

    -- Show the "Custom Buff ID" popup with Spell ID + Duration fields
    local function ShowCustomBuffIDPopup(anchorFrame, barCfg, onChanged)
        local popupName = "EUI_TBB_CustomBuffPopup"
        local popup = _G[popupName]
        if not popup then
            local POPUP_W, POPUP_H = 320, 210
            local dimmer = CreateFrame("Frame", popupName .. "Dimmer", UIParent)
            dimmer:SetFrameStrata("FULLSCREEN_DIALOG")
            dimmer:SetAllPoints(UIParent)
            dimmer:EnableMouse(true)
            dimmer:Hide()
            local dimTex = dimmer:CreateTexture(nil, "BACKGROUND")
            dimTex:SetAllPoints(); dimTex:SetColorTexture(0, 0, 0, 0.25)

            popup = CreateFrame("Frame", popupName, dimmer)
            popup:SetSize(POPUP_W, POPUP_H)
            popup:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
            popup:SetFrameStrata("FULLSCREEN_DIALOG")
            popup:SetFrameLevel(dimmer:GetFrameLevel() + 10)
            popup:EnableMouse(true)
            local popBg = popup:CreateTexture(nil, "BACKGROUND")
            popBg:SetAllPoints(); popBg:SetColorTexture(0.06, 0.08, 0.10, 1)
            EllesmereUI.MakeBorder(popup, 1, 1, 1, 0.15, EllesmereUI.PP)

            local title = popup:CreateFontString(nil, "OVERLAY")
            title:SetFont(FONT_PATH, 14, GetCDMOptOutline())
            title:SetPoint("TOP", popup, "TOP", 0, -18)
            title:SetTextColor(1, 1, 1, 1)
            title:SetText(EllesmereUI.L("Custom Buff ID"))

            local sidLbl = popup:CreateFontString(nil, "OVERLAY")
            sidLbl:SetFont(FONT_PATH, 11, GetCDMOptOutline())
            sidLbl:SetPoint("TOPLEFT", popup, "TOPLEFT", 24, -52)
            sidLbl:SetTextColor(0.7, 0.7, 0.7, 1)
            sidLbl:SetText(EllesmereUI.L("Spell ID"))

            local sidBox = CreateFrame("EditBox", nil, popup)
            sidBox:SetSize(180, 28)
            sidBox:SetPoint("TOPLEFT", sidLbl, "BOTTOMLEFT", 0, -4)
            sidBox:SetAutoFocus(false)
            sidBox:SetNumeric(true)
            sidBox:SetMaxLetters(7)
            sidBox:SetFont(FONT_PATH, 13, GetCDMOptOutline())
            sidBox:SetTextColor(1, 1, 1, 0.9)
            sidBox:SetJustifyH("LEFT")
            local sidBg = sidBox:CreateTexture(nil, "BACKGROUND")
            sidBg:SetAllPoints(); sidBg:SetColorTexture(0.04, 0.06, 0.08, 1)
            EllesmereUI.MakeBorder(sidBox, 1, 1, 1, 0.12, EllesmereUI.PP)
            local sidPh = sidBox:CreateFontString(nil, "ARTWORK")
            sidPh:SetFont(FONT_PATH, 12, GetCDMOptOutline())
            sidPh:SetPoint("LEFT", sidBox, "LEFT", 4, 0)
            sidPh:SetTextColor(0.5, 0.5, 0.5, 0.5)
            sidPh:SetText(EllesmereUI.L("e.g. 12345"))
            sidBox:SetScript("OnTextChanged", function(self)
                if self:GetText() == "" then sidPh:Show() else sidPh:Hide() end
            end)
            popup._sidBox = sidBox

            local durLbl = popup:CreateFontString(nil, "OVERLAY")
            durLbl:SetFont(FONT_PATH, 11, GetCDMOptOutline())
            durLbl:SetPoint("TOPLEFT", sidBox, "BOTTOMLEFT", 0, -12)
            durLbl:SetTextColor(0.7, 0.7, 0.7, 1)
            durLbl:SetText(EllesmereUI.L("Duration (seconds)"))

            local durBox = CreateFrame("EditBox", nil, popup)
            durBox:SetSize(180, 28)
            durBox:SetPoint("TOPLEFT", durLbl, "BOTTOMLEFT", 0, -4)
            durBox:SetAutoFocus(false)
            durBox:SetNumeric(true)
            durBox:SetMaxLetters(5)
            durBox:SetFont(FONT_PATH, 13, GetCDMOptOutline())
            durBox:SetTextColor(1, 1, 1, 0.9)
            durBox:SetJustifyH("LEFT")
            local durBg = durBox:CreateTexture(nil, "BACKGROUND")
            durBg:SetAllPoints(); durBg:SetColorTexture(0.04, 0.06, 0.08, 1)
            EllesmereUI.MakeBorder(durBox, 1, 1, 1, 0.12, EllesmereUI.PP)
            local durPh = durBox:CreateFontString(nil, "ARTWORK")
            durPh:SetFont(FONT_PATH, 12, GetCDMOptOutline())
            durPh:SetPoint("LEFT", durBox, "LEFT", 4, 0)
            durPh:SetTextColor(0.5, 0.5, 0.5, 0.5)
            durPh:SetText(EllesmereUI.L("e.g. 30"))
            durBox:SetScript("OnTextChanged", function(self)
                if self:GetText() == "" then durPh:Show() else durPh:Hide() end
            end)
            popup._durBox = durBox

            local status = popup:CreateFontString(nil, "OVERLAY")
            status:SetFont(FONT_PATH, 11, GetCDMOptOutline())
            status:SetPoint("TOP", durBox, "BOTTOM", 0, -6)
            status:SetTextColor(1, 0.3, 0.3, 1)
            status:SetText("")
            popup._status = status
            popup._statusTimer = nil

            local ar, ag, ab = EllesmereUI.GetAccentColor()
            local addBtn = CreateFrame("Button", nil, popup)
            addBtn:SetSize(80, 28)
            addBtn:SetPoint("BOTTOMRIGHT", popup, "BOTTOM", -4, 16)
            local addBg = addBtn:CreateTexture(nil, "BACKGROUND")
            addBg:SetAllPoints(); addBg:SetColorTexture(ar, ag, ab, 0.15)
            EllesmereUI.MakeBorder(addBtn, ar, ag, ab, 0.3, EllesmereUI.PP)
            local addLbl = addBtn:CreateFontString(nil, "OVERLAY")
            addLbl:SetFont(FONT_PATH, 12, GetCDMOptOutline())
            addLbl:SetPoint("CENTER"); addLbl:SetText(EllesmereUI.L("Add"))
            addLbl:SetTextColor(ar, ag, ab, 0.9)
            addBtn:SetScript("OnEnter", function() addLbl:SetTextColor(1, 1, 1, 1) end)
            addBtn:SetScript("OnLeave", function() addLbl:SetTextColor(ar, ag, ab, 0.9) end)
            popup._addBtn = addBtn

            local cancelBtn = CreateFrame("Button", nil, popup)
            cancelBtn:SetSize(80, 28)
            cancelBtn:SetPoint("BOTTOMLEFT", popup, "BOTTOM", 4, 16)
            local cBg = cancelBtn:CreateTexture(nil, "BACKGROUND")
            cBg:SetAllPoints(); cBg:SetColorTexture(0.12, 0.12, 0.12, 0.5)
            EllesmereUI.MakeBorder(cancelBtn, 1, 1, 1, 0.10, EllesmereUI.PP)
            local cLbl = cancelBtn:CreateFontString(nil, "OVERLAY")
            cLbl:SetFont(FONT_PATH, 12, GetCDMOptOutline())
            cLbl:SetPoint("CENTER"); cLbl:SetText(EllesmereUI.L("Cancel"))
            cLbl:SetTextColor(0.7, 0.7, 0.7, 0.8)
            cancelBtn:SetScript("OnEnter", function() cLbl:SetTextColor(1, 1, 1, 1) end)
            cancelBtn:SetScript("OnLeave", function() cLbl:SetTextColor(0.7, 0.7, 0.7, 0.8) end)
            cancelBtn:SetScript("OnClick", function() dimmer:Hide() end)
            popup._cancelBtn = cancelBtn

            sidBox:SetScript("OnEscapePressed", function() dimmer:Hide() end)
            durBox:SetScript("OnEscapePressed", function() dimmer:Hide() end)

            popup._dimmer = dimmer
            _G[popupName] = popup
        end

        local curSID = (barCfg.spellID and barCfg.spellID > 0 and not barCfg.popularKey) and barCfg.spellID or nil
        local curDur = barCfg.customDuration or nil
        popup._sidBox:SetText(curSID and tostring(curSID) or "")
        popup._durBox:SetText(curDur and tostring(curDur) or "")
        popup._status:SetText("")

        local function SetStatus(text, r, g, b)
            popup._status:SetText(text)
            popup._status:SetTextColor(r or 1, g or 0.3, b or 0.3, 1)
            if popup._statusTimer then popup._statusTimer:Cancel() end
            if text ~= "" then
                popup._statusTimer = C_Timer.NewTimer(2.5, function()
                    popup._status:SetText("")
                end)
            end
        end

        popup._addBtn:SetScript("OnClick", function()
            local sid = tonumber(popup._sidBox:GetText())
            local dur = tonumber(popup._durBox:GetText())
            if not sid or sid <= 0 then SetStatus("Enter a valid spell ID"); return end
            sid = math.floor(sid)
            if not C_Spell.GetSpellName(sid) then SetStatus("Unknown spell ID"); return end
            if not dur or dur <= 0 then SetStatus("Enter a duration in seconds"); return end
            dur = math.floor(dur)
            popup._dimmer:Hide()
            barCfg.spellID        = sid
            barCfg.spellIDs       = nil
            barCfg.popularKey     = nil
            barCfg.glowBased      = nil
            barCfg.trackType      = nil
            barCfg.customDuration = dur
            -- Manually-entered id has no live frame to read the base from: clear stale
            -- base; MatchFrameToConfig self-heals it once talented.
            barCfg.baseSpellID    = nil
            barCfg.name           = C_Spell.GetSpellName(sid)
            Refresh()
            ns.BuildTrackedBuffBars()
            if onChanged then onChanged() end
        end)

        ns.PadPopupOpen(popup._dimmer, popup, popup._cancelBtn)  -- controller cursor
        popup._dimmer:Show()
        popup._sidBox:SetFocus()
    end

    local function ShowTBBSpellPicker(anchorFrame, barCfg, onChanged)
        if _tbbSpellPickerMenu then _tbbSpellPickerMenu:Hide() end

        local trackedBars = ns.GetTrackedBarSpells and ns.GetTrackedBarSpells(true) or {}
        local popular = ns.TBB_POPULAR_BUFFS or {}

        -- No early bail on empty trackedBars -- the picker still shows popular presets and the custom spell ID input.

        local mBgR  = EllesmereUI.DD_BG_R  or 0.075
        local mBgG  = EllesmereUI.DD_BG_G  or 0.113
        local mBgB  = EllesmereUI.DD_BG_B  or 0.141
        local mBgA  = EllesmereUI.DD_BG_HA or 0.98
        local mBrdA = EllesmereUI.DD_BRD_A or 0.20
        local hlA   = EllesmereUI.DD_ITEM_HL_A or 0.08
        local tDimR = EllesmereUI.TEXT_DIM_R or 0.7
        local tDimG = EllesmereUI.TEXT_DIM_G or 0.7
        local tDimB = EllesmereUI.TEXT_DIM_B or 0.7
        local tDimA = EllesmereUI.TEXT_DIM_A or 0.85
        local ACCENT = EllesmereUI.ELLESMERE_GREEN or { r = 0.05, g = 0.82, b = 0.62 }

        local menuW = 240
        local ITEM_H = 26
        local MAX_H = 340

        local menu = CreateFrame("Frame", nil, UIParent)
        menu:SetFrameStrata("FULLSCREEN_DIALOG")
        menu:SetFrameLevel(300)
        menu:SetClampedToScreen(true)
        menu:SetSize(menuW, 10)

        local mbg = menu:CreateTexture(nil, "BACKGROUND")
        mbg:SetAllPoints(); mbg:SetColorTexture(mBgR, mBgG, mBgB, mBgA)
        EllesmereUI.MakeBorder(menu, 1, 1, 1, mBrdA, EllesmereUI.PP)

        local inner = CreateFrame("Frame", nil, menu)
        inner:SetWidth(menuW)
        inner:SetPoint("TOPLEFT")

        local mH = 4

        -- "Custom Buff ID" entry at the top
        local isCustomSelected = barCfg.spellID and barCfg.spellID > 0 and not barCfg.popularKey and not barCfg.spellIDs and barCfg.trackType ~= "cooldown"
        local csItem = CreateFrame("Button", nil, inner)
        csItem:SetHeight(ITEM_H)
        csItem:SetPoint("TOPLEFT", inner, "TOPLEFT", 1, -mH)
        csItem:SetPoint("TOPRIGHT", inner, "TOPRIGHT", -1, -mH)
        csItem:SetFrameLevel(menu:GetFrameLevel() + 2)
        local csHl = csItem:CreateTexture(nil, "ARTWORK", nil, -1)
        csHl:SetAllPoints(); csHl:SetColorTexture(1, 1, 1, 0)
        local csLbl = csItem:CreateFontString(nil, "OVERLAY")
        csLbl:SetFont(FONT_PATH, 11, GetCDMOptOutline())
        csLbl:SetPoint("LEFT", 10, 0)
        csLbl:SetJustifyH("LEFT")
        csLbl:SetText(EllesmereUI.L("Custom Buff ID"))
        csLbl:SetTextColor(isCustomSelected and 1 or tDimR, isCustomSelected and 1 or tDimG, isCustomSelected and 1 or tDimB, isCustomSelected and 1 or tDimA)
        csItem:SetScript("OnEnter", function() csLbl:SetTextColor(1,1,1,1); csHl:SetColorTexture(1,1,1,hlA) end)
        csItem:SetScript("OnLeave", function()
            csLbl:SetTextColor(isCustomSelected and 1 or tDimR, isCustomSelected and 1 or tDimG, isCustomSelected and 1 or tDimB, isCustomSelected and 1 or tDimA)
            csHl:SetColorTexture(1,1,1,0)
        end)
        csItem:SetScript("OnClick", function()
            menu:Hide()
            ShowCustomBuffIDPopup(anchorFrame, barCfg, onChanged)
        end)
        mH = mH + ITEM_H

        local div1 = inner:CreateTexture(nil, "ARTWORK")
        div1:SetHeight(1); div1:SetColorTexture(1, 1, 1, 0.10)
        div1:SetPoint("TOPLEFT", inner, "TOPLEFT", 1, -mH - 4)
        div1:SetPoint("TOPRIGHT", inner, "TOPRIGHT", -1, -mH - 4)
        mH = mH + 9

        -- Popular buff entries
        local function MakePopularItem(entry)
            local isSelected = barCfg.popularKey == entry.key
            local item = CreateFrame("Button", nil, inner)
            item:SetHeight(ITEM_H)
            item:SetPoint("TOPLEFT", inner, "TOPLEFT", 1, -mH)
            item:SetPoint("TOPRIGHT", inner, "TOPRIGHT", -1, -mH)
            item:SetFrameLevel(menu:GetFrameLevel() + 2)

            local ico = item:CreateTexture(nil, "ARTWORK")
            local icoSz = ITEM_H - 4
            ico:SetSize(icoSz, icoSz)
            ico:SetPoint("RIGHT", item, "RIGHT", -6, 0)
            ico:SetTexture(entry.icon)
            ico:SetTexCoord(0.08, 0.92, 0.08, 0.92)

            local baseR = isSelected and 1 or tDimR
            local baseG = isSelected and 1 or tDimG
            local baseB = isSelected and 1 or tDimB
            local baseA = isSelected and 1 or tDimA

            local lbl = item:CreateFontString(nil, "OVERLAY")
            lbl:SetFont(FONT_PATH, 11, GetCDMOptOutline())
            lbl:SetPoint("LEFT", 8, 0)
            lbl:SetPoint("RIGHT", ico, "LEFT", -4, 0)
            lbl:SetJustifyH("LEFT")
            lbl:SetWordWrap(false); lbl:SetMaxLines(1)
            lbl:SetText(EllesmereUI.L(entry.name))
            lbl:SetTextColor(baseR, baseG, baseB, baseA)

            local hl = item:CreateTexture(nil, "ARTWORK", nil, -1)
            hl:SetAllPoints()
            hl:SetColorTexture(1, 1, 1, isSelected and 0.12 or 0)

            item:SetScript("OnEnter", function() lbl:SetTextColor(1,1,1,1); hl:SetColorTexture(1,1,1,hlA) end)
            item:SetScript("OnLeave", function()
                lbl:SetTextColor(baseR, baseG, baseB, baseA)
                hl:SetColorTexture(1, 1, 1, isSelected and 0.12 or 0)
            end)
            item:SetScript("OnClick", function()
                menu:Hide()
                barCfg.popularKey     = entry.key
                barCfg.spellIDs       = entry.spellIDs
                barCfg.glowBased      = entry.glowBased or nil
                barCfg.customDuration = entry.customDuration
                barCfg.spellID        = entry.spellIDs and entry.spellIDs[1] or 0
                barCfg.baseSpellID    = nil
                barCfg.trackType      = nil
                barCfg.name           = entry.name
                Refresh()
                ns.BuildTrackedBuffBars()
                if onChanged then onChanged() end
            end)
            mH = mH + ITEM_H
        end

        local _, _tbbPClass = UnitClass("player")
        local nPopular = 0
        for _, entry in ipairs(popular) do
            -- tbbOnly presets (e.g. debuff-driven Bloodlust) carry a sentinel class to hide
            -- from the cooldown/utility item picker; the TBB picker overrides that and always shows them.
            if entry.tbbOnly or not entry.class or entry.class == _tbbPClass then
                MakePopularItem(entry)
                nPopular = nPopular + 1
            end
        end

        -- "Buffs" section always renders (even with no tracked bars) so the Missing Spells prompt below stays visible.
        -- Its divider closes the preset rows, so it is skipped when none were built
        -- (WoW Forever has no presets): the one above already separates Custom Buff ID.
        do
            if nPopular > 0 then
                local div2 = inner:CreateTexture(nil, "ARTWORK")
                div2:SetHeight(1); div2:SetColorTexture(1, 1, 1, 0.10)
                div2:SetPoint("TOPLEFT", inner, "TOPLEFT", 1, -mH - 4)
                div2:SetPoint("TOPRIGHT", inner, "TOPRIGHT", -1, -mH - 4)
                mH = mH + 9
            end

            local buffHdr = inner:CreateFontString(nil, "OVERLAY")
            buffHdr:SetFont(FONT_PATH, 10, GetCDMOptOutline())
            buffHdr:SetTextColor(1, 1, 1, 0.5)
            buffHdr:SetPoint("TOPLEFT", inner, "TOPLEFT", 10, -mH - 5)
            buffHdr:SetText(EllesmereUI.L("Buffs"))
            mH = mH + 20
        end

        local function MakeSpellItem(sp)
            -- Every spell here came from BuffBarCooldownViewer enumeration, so it's by definition tracked -- no popup needed.
            local usedOnBar = ns.SpellUsedOnAnyOtherTBB and ns.SpellUsedOnAnyOtherTBB(sp.spellID, nil)
            -- A family bar (Roll the Bones) is selected by its base id OR any member,
            -- since the row resolves to the active outcome while one is up.
            local isSelected = not barCfg.popularKey
                             and barCfg.trackType ~= "cooldown"
                             and barCfg.spellID and barCfg.spellID > 0 and barCfg.spellID == sp.spellID
            if not isSelected and barCfg.spellIDs and not barCfg.popularKey
               and barCfg.trackType ~= "cooldown" then
                for _, sid in ipairs(barCfg.spellIDs) do
                    if sid == sp.spellID then isSelected = true; break end
                end
            end
            local item = CreateFrame("Button", nil, inner)
            item:SetHeight(ITEM_H)
            item:SetPoint("TOPLEFT", inner, "TOPLEFT", 1, -mH)
            item:SetPoint("TOPRIGHT", inner, "TOPRIGHT", -1, -mH)
            item:SetFrameLevel(menu:GetFrameLevel() + 2)

            local ico = item:CreateTexture(nil, "ARTWORK")
            local icoSz = ITEM_H - 4
            ico:SetSize(icoSz, icoSz)
            ico:SetPoint("RIGHT", item, "RIGHT", -6, 0)
            if sp.icon then ico:SetTexture(sp.icon) end
            ico:SetTexCoord(0.08, 0.92, 0.08, 0.92)

            local baseR = isSelected and 1 or tDimR
            local baseG = isSelected and 1 or tDimG
            local baseB = isSelected and 1 or tDimB
            local baseA = isSelected and 1 or tDimA

            local lbl = item:CreateFontString(nil, "OVERLAY")
            lbl:SetFont(FONT_PATH, 11, GetCDMOptOutline())
            lbl:SetPoint("LEFT", 8, 0)
            lbl:SetPoint("RIGHT", ico, "LEFT", -4, 0)
            lbl:SetJustifyH("LEFT")
            lbl:SetWordWrap(false); lbl:SetMaxLines(1)
            lbl:SetText(EllesmereUI.L(sp.name))
            lbl:SetTextColor(baseR, baseG, baseB, baseA)

            local hl = item:CreateTexture(nil, "ARTWORK", nil, -1)
            hl:SetAllPoints()
            hl:SetColorTexture(1, 1, 1, isSelected and 0.12 or 0)

            -- Gray out if already used on another bar
            if usedOnBar and not isSelected then
                lbl:SetTextColor(tDimR, tDimG, tDimB, tDimA * 0.4)
                ico:SetDesaturated(true); ico:SetAlpha(0.4)
                item:SetScript("OnEnter", function()
                    EllesmereUI.ShowWidgetTooltip(item, EllesmereUI.Lf("Already assigned to %s", EllesmereUI.L(usedOnBar)))
                    hl:SetColorTexture(1, 1, 1, hlA * 0.3); hl:SetAlpha(1)
                end)
                item:SetScript("OnLeave", function()
                    EllesmereUI.HideWidgetTooltip()
                    hl:SetAlpha(0)
                end)
                mH = mH + ITEM_H
                return
            end

            -- Tracked-but-untalented bar spells (no live BuffBar frame) stay clickable but
            -- render desaturated with a hint (matches CD/utility pickers), so bars can be set without swapping talents.
            local notLearned = (sp.isKnown == false)
            if notLearned then ico:SetDesaturated(true); ico:SetAlpha(0.5) end
            item:SetScript("OnEnter", function()
                lbl:SetTextColor(1,1,1,1); hl:SetColorTexture(1,1,1,hlA)
                if notLearned then EllesmereUI.ShowWidgetTooltip(item, EllesmereUI.L("Not currently talented")) end
            end)
            item:SetScript("OnLeave", function()
                lbl:SetTextColor(baseR, baseG, baseB, baseA)
                hl:SetColorTexture(1, 1, 1, isSelected and 0.12 or 0)
                if notLearned then EllesmereUI.HideWidgetTooltip() end
            end)
            item:SetScript("OnClick", function()
                if notLearned then EllesmereUI.HideWidgetTooltip() end
                menu:Hide()
                barCfg.spellID        = sp.spellID
                barCfg.spellIDs       = nil
                barCfg.popularKey     = nil
                barCfg.glowBased      = nil
                barCfg.customDuration = nil
                barCfg.trackType      = nil
                barCfg.name           = sp.name
                -- Capture the BASE spell id for hero-talent override spells so the bar keeps
                -- tracking after the talent is removed (active override's cooldownInfo
                -- reports base in info.spellID); store only when it differs from the picked id.
                barCfg.baseSpellID = nil
                if sp.cdID and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo then
                    local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(sp.cdID)
                    local RTB_BASE_SPELL_ID = 1214909
                    local isSec = issecretvalue
                    local baseSID = info and info.spellID
                    if baseSID and (isSec and isSec(baseSID)) then baseSID = nil end
                    if baseSID and baseSID > 0 and baseSID ~= sp.spellID then
                        barCfg.baseSpellID = baseSID
                    end
                    -- Roll the Bones: ONE tracked-bar slot cycles through mutually
                    -- exclusive outcome buffs, listed only in the raw linkedSpellIDs.
                    -- The row resolves to whichever outcome is up at pick time, so a
                    -- single id matches nothing else after a re-roll: store the whole
                    -- family as the want-set and key the config on the stable base.
                    if baseSID == RTB_BASE_SPELL_ID and type(info.linkedSpellIDs) == "table" then
                        local ids = {}
                        for i = 1, #info.linkedSpellIDs do
                            local lid = info.linkedSpellIDs[i]
                            if type(lid) == "number" and not (isSec and isSec(lid)) and lid > 0 then
                                ids[#ids + 1] = lid
                            end
                        end
                        if #ids >= 2 then
                            barCfg.spellIDs    = ids
                            barCfg.spellID     = baseSID
                            barCfg.baseSpellID = nil
                            local nm = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(baseSID)
                            if nm and nm ~= "" then barCfg.name = nm end
                        end
                    end
                end
                Refresh()
                ns.BuildTrackedBuffBars()
                if onChanged then onChanged() end
            end)
            mH = mH + ITEM_H
        end

        for _, sp in ipairs(trackedBars) do MakeSpellItem(sp) end

        -- "Missing Spells?" prompt (centered, accent-colored) closes EUI options and opens
        -- Blizzard's CDM; sits at the end of Buffs so it reads as the way to add more.
        do
            local FOOTER_H = 38
            local mbItem = CreateFrame("Button", nil, inner)
            mbItem:SetHeight(FOOTER_H)
            mbItem:SetPoint("TOPLEFT", inner, "TOPLEFT", 1, -mH)
            mbItem:SetPoint("TOPRIGHT", inner, "TOPRIGHT", -1, -mH)
            mbItem:SetFrameLevel(menu:GetFrameLevel() + 2)

            local mbFS = mbItem:CreateFontString(nil, "OVERLAY")
            mbFS:SetFont(FONT_PATH, 11, GetCDMOptOutline())
            mbFS:SetAllPoints()
            mbFS:SetJustifyH("CENTER")
            mbFS:SetJustifyV("MIDDLE")
            local ar, ag, ab = EllesmereUI.GetAccentColor()
            mbFS:SetTextColor(ar, ag, ab, 1)
            mbFS:SetText(EllesmereUI.L("Missing Spells? Add as") .. "\n" .. EllesmereUI.L("Tracking Bar in Blizz CDM"))

            mbItem:SetScript("OnEnter", function() mbFS:SetTextColor(1, 1, 1, 1) end)
            mbItem:SetScript("OnLeave", function()
                local r, g, b = EllesmereUI.GetAccentColor()
                mbFS:SetTextColor(r, g, b, 1)
            end)
            mbItem:SetScript("OnClick", function()
                menu:Hide()
                if ns.OpenBlizzardCDMTab then ns.OpenBlizzardCDMTab(true) end
            end)
            mH = mH + FOOTER_H
        end

        -- "Cooldowns" section: pick a spell COOLDOWN to track instead of a buff
        -- (cfg.trackType="cooldown"), sourced from Essential+Utility pools + settings catalog; skipped when empty.
        local cdSpells = ns.GetCDMSpellsForBar and ns.GetCDMSpellsForBar("cooldowns") or {}
        if #cdSpells > 0 then
            local cdDiv = inner:CreateTexture(nil, "ARTWORK")
            cdDiv:SetHeight(1); cdDiv:SetColorTexture(1, 1, 1, 0.10)
            cdDiv:SetPoint("TOPLEFT", inner, "TOPLEFT", 1, -mH - 4)
            cdDiv:SetPoint("TOPRIGHT", inner, "TOPRIGHT", -1, -mH - 4)
            mH = mH + 9

            local cdHdr = inner:CreateFontString(nil, "OVERLAY")
            cdHdr:SetFont(FONT_PATH, 10, GetCDMOptOutline())
            cdHdr:SetTextColor(1, 1, 1, 0.5)
            cdHdr:SetPoint("TOPLEFT", inner, "TOPLEFT", 10, -mH - 5)
            cdHdr:SetText(EllesmereUI.L("Cooldowns"))
            mH = mH + 20

            local function MakeCooldownItem(sp)
                -- Gray-out check is scoped to OTHER cooldown-tracking bars -- a buff bar for the same spell never blocks this pick.
                local usedOnBar = ns.SpellUsedOnAnyOtherTBB and ns.SpellUsedOnAnyOtherTBB(sp.spellID, nil, "cooldown")
                local isSelected = barCfg.trackType == "cooldown"
                                 and not barCfg.popularKey and not barCfg.spellIDs
                                 and barCfg.spellID and barCfg.spellID > 0 and barCfg.spellID == sp.spellID
                local item = CreateFrame("Button", nil, inner)
                item:SetHeight(ITEM_H)
                item:SetPoint("TOPLEFT", inner, "TOPLEFT", 1, -mH)
                item:SetPoint("TOPRIGHT", inner, "TOPRIGHT", -1, -mH)
                item:SetFrameLevel(menu:GetFrameLevel() + 2)

                local ico = item:CreateTexture(nil, "ARTWORK")
                local icoSz = ITEM_H - 4
                ico:SetSize(icoSz, icoSz)
                ico:SetPoint("RIGHT", item, "RIGHT", -6, 0)
                if sp.icon then ico:SetTexture(sp.icon) end
                ico:SetTexCoord(0.08, 0.92, 0.08, 0.92)

                local baseR = isSelected and 1 or tDimR
                local baseG = isSelected and 1 or tDimG
                local baseB = isSelected and 1 or tDimB
                local baseA = isSelected and 1 or tDimA

                local lbl = item:CreateFontString(nil, "OVERLAY")
                lbl:SetFont(FONT_PATH, 11, GetCDMOptOutline())
                lbl:SetPoint("LEFT", 8, 0)
                lbl:SetPoint("RIGHT", ico, "LEFT", -4, 0)
                lbl:SetJustifyH("LEFT")
                lbl:SetWordWrap(false); lbl:SetMaxLines(1)
                lbl:SetText(EllesmereUI.L(sp.name))
                lbl:SetTextColor(baseR, baseG, baseB, baseA)

                local hl = item:CreateTexture(nil, "ARTWORK", nil, -1)
                hl:SetAllPoints()
                hl:SetColorTexture(1, 1, 1, isSelected and 0.12 or 0)

                -- Gray out if already used on another cooldown-tracking bar
                if usedOnBar and not isSelected then
                    lbl:SetTextColor(tDimR, tDimG, tDimB, tDimA * 0.4)
                    ico:SetDesaturated(true); ico:SetAlpha(0.4)
                    item:SetScript("OnEnter", function()
                        EllesmereUI.ShowWidgetTooltip(item, EllesmereUI.Lf("Already assigned to %s", EllesmereUI.L(usedOnBar)))
                        hl:SetColorTexture(1, 1, 1, hlA * 0.3); hl:SetAlpha(1)
                    end)
                    item:SetScript("OnLeave", function()
                        EllesmereUI.HideWidgetTooltip()
                        hl:SetAlpha(0)
                    end)
                    mH = mH + ITEM_H
                    return
                end

                -- Untalented catalog spells stay clickable but render desaturated with a hint, matching the buff rows above.
                local notLearned = (sp.isKnown == false)
                if notLearned then ico:SetDesaturated(true); ico:SetAlpha(0.5) end
                item:SetScript("OnEnter", function()
                    lbl:SetTextColor(1,1,1,1); hl:SetColorTexture(1,1,1,hlA)
                    if notLearned then EllesmereUI.ShowWidgetTooltip(item, EllesmereUI.L("Not currently talented")) end
                end)
                item:SetScript("OnLeave", function()
                    lbl:SetTextColor(baseR, baseG, baseB, baseA)
                    hl:SetColorTexture(1, 1, 1, isSelected and 0.12 or 0)
                    if notLearned then EllesmereUI.HideWidgetTooltip() end
                end)
                item:SetScript("OnClick", function()
                    if notLearned then EllesmereUI.HideWidgetTooltip() end
                    menu:Hide()
                    barCfg.spellID        = sp.spellID
                    barCfg.spellIDs       = nil
                    barCfg.popularKey     = nil
                    barCfg.glowBased      = nil
                    barCfg.customDuration = nil
                    barCfg.trackType      = "cooldown"
                    barCfg.name           = sp.name
                    -- Capture the BASE spell id for hero-talent override spells so the bar keeps tracking after the talent is removed.
                    barCfg.baseSpellID = nil
                    if sp.cdID and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo then
                        local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(sp.cdID)
                        if info and info.spellID and info.spellID > 0 and info.spellID ~= sp.spellID then
                            barCfg.baseSpellID = info.spellID
                        end
                    end
                    Refresh()
                    ns.BuildTrackedBuffBars()
                    if onChanged then onChanged() end
                end)
                mH = mH + ITEM_H
            end

            for _, sp in ipairs(cdSpells) do MakeCooldownItem(sp) end
        end

        local totalH = mH + 4
        inner:SetHeight(totalH)
        if totalH > MAX_H then
            menu:SetHeight(MAX_H)
            local sf = CreateFrame("ScrollFrame", nil, menu)
            sf:SetPoint("TOPLEFT"); sf:SetPoint("BOTTOMRIGHT")
            sf:SetFrameLevel(menu:GetFrameLevel() + 1)
            sf:EnableMouseWheel(true)
            sf:SetScrollChild(inner)
            inner:SetWidth(menuW)
            local scrollPos = 0
            local maxScroll = totalH - MAX_H
            sf:SetScript("OnMouseWheel", function(_, delta)
                scrollPos = math.max(0, math.min(maxScroll, scrollPos - delta * 30))
                sf:SetVerticalScroll(scrollPos)
            end)
        else
            menu:SetHeight(totalH)
            inner:SetParent(menu)
            inner:SetPoint("TOPLEFT")
        end

        menu:ClearAllPoints()
        menu:SetPoint("TOP", anchorFrame, "BOTTOM", 0, -2)
        menu:SetScript("OnUpdate", function(m)
            if not m:IsMouseOver() and not anchorFrame:IsMouseOver() and IsMouseButtonDown("LeftButton") then
                m:Hide()
            end
        end)
        menu:HookScript("OnHide", function(m) m:SetScript("OnUpdate", nil) end)
        menu:Show()
        _tbbSpellPickerMenu = menu
    end

    -- Select a bar and open its buff picker anchored to the management dropdown (used by
    -- the dropdown's bar rows); page refresh runs first so the picker anchors to the fresh button.
    local function OpenBuffPickerForBar(idx)
        _tbbSelectedBar = idx
        _tbbSelectedGroup = nil
        EllesmereUI:RefreshPage(true)
        C_Timer.After(0, function()
            local t = ns.GetTrackedBuffBars()
            local cfg = t.bars and t.bars[idx]
            if cfg and _tbbDDBtn and _tbbDDBtn:IsShown() then
                ShowTBBSpellPicker(_tbbDDBtn, cfg, function()
                    EllesmereUI:RefreshPage(true)
                end)
            end
        end)
    end

    -- Smallest unused "Preset N" default name for the save popup.
    local function UniqueTBBPresetName()
        local presets = ns.GetTBBStylePresets and ns.GetTBBStylePresets() or {}
        local function taken(nm)
            for _, pr in ipairs(presets) do
                if pr.name == nm then return true end
            end
            return false
        end
        local n = 1
        while taken("Preset " .. n) do n = n + 1 end
        return "Preset " .. n
    end

    ---------------------------------------------------------------------------
    --  Stack threshold editor (opt-in) popup, opened from the cog on "Enable Stack
    --  Threshold"; edits cfg.stackThresholds -- an ordered list of {value=<stack count>,
    --  r,g,b,a} color stops capped at STACK_THRESH_MAX. Only drives rendering while
    --  cfg.stackThresholdMulti is on (else legacy single-threshold keys own the bar).
    --  ShowStackThreshEditor() rebinds per calling bar.
    ---------------------------------------------------------------------------
    local STACK_THRESH_MAX = 5
    local _stCloseIcon = "Interface\\AddOns\\EllesmereUI\\media\\icons\\eui-close.png"
    local stPopup
    local _stRows = {}
    local _stGetCfg, _stRefreshFn
    local _stMultiRow, _stMultiSnap, _stAddBtn, _stAddLbl
    local ST_POPUP_W = 260
    local ST_ROW_H = 26
    local ST_PAD = 14
    local ST_GAP = 10
    local ST_DEF_R, ST_DEF_G, ST_DEF_B, ST_DEF_A = 0.8, 0.1, 0.1, 1
    local RefreshStackThreshEditor  -- forward decl

    -- Shared explainers; literals live inside the L() calls so extract-locale-keys.sh can
    -- see them (it only reads string literals passed directly to L/Lf, never variables).
    local function StackThreshHelpTip()
        return EllesmereUI.L("Color the bar differently at several stack counts. The highest count you have reached wins.")
    end
    local function StackThreshReplacesTip()
        return EllesmereUI.L("The single stack threshold is off while Multiple Thresholds is on.")
    end
    local function StackThreshAtCapTip()
        return EllesmereUI.L("Maximum of 5 thresholds.")
    end

    local function CurrentStackThreshCfg()
        if not _stGetCfg then return nil end
        return _stGetCfg()
    end

    local function SortStackThresholds(list)
        table.sort(list, function(a, b) return (a.value or 0) < (b.value or 0) end)
    end

    local function BuildStackThreshPopup()
        stPopup = CreateFrame("Frame", nil, UIParent)
        stPopup:SetFrameStrata("FULLSCREEN_DIALOG")
        stPopup:SetFrameLevel(260)
        stPopup:SetClampedToScreen(true)
        stPopup:EnableMouse(true)
        stPopup:SetScale(0.9)
        stPopup:Hide()
        PP.Size(stPopup, ST_POPUP_W, 200)

        local bg = stPopup:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.06, 0.08, 0.10, 0.97)
        PP.CreateBorder(stPopup, 1, 1, 1, 0.18, 1, "BORDER", 7)

        local clickCatcher = CreateFrame("Button", nil, stPopup)
        clickCatcher:SetFrameStrata("FULLSCREEN_DIALOG")
        clickCatcher:SetFrameLevel(stPopup:GetFrameLevel() - 1)
        clickCatcher:SetAllPoints((EllesmereUI:GetMainFrame()) or UIParent)
        clickCatcher:SetScript("OnClick", function() stPopup:Hide() end)
        clickCatcher:Hide()
        -- Close on entering combat
        stPopup:SetScript("OnEvent", function(self, event)
            if event == "PLAYER_REGEN_DISABLED" then self:Hide() end
        end)
        stPopup:SetScript("OnShow", function(self)
            clickCatcher:Show()
            self:RegisterEvent("PLAYER_REGEN_DISABLED")
            self:SetScript("OnUpdate", function(p)
                if IsMouseButtonDown("LeftButton") then
                    local mf = EllesmereUI._mainFrame
                    local dm = EllesmereUI._openDropdownMenu
                    if not p:IsMouseOver() and not (mf and mf:IsMouseOver()) and not (dm and dm:IsShown() and dm:IsMouseOver()) then p:Hide() end
                end
            end)
        end)
        stPopup:SetScript("OnHide", function(self)
            clickCatcher:Hide()
            self:UnregisterEvent("PLAYER_REGEN_DISABLED")
            self:SetScript("OnUpdate", nil)
        end)

        local titleFS = EllesmereUI.MakeFont(stPopup, 13, nil, 1, 1, 1)
        titleFS:SetAlpha(0.6)
        titleFS:SetPoint("TOP", stPopup, "TOP", 0, -ST_PAD)
        titleFS:SetText(EllesmereUI.L("Stack Thresholds"))

        -- Row: multi opt-in (label left, toggle right) -- matches the band editor.
        _stMultiRow = CreateFrame("Frame", nil, stPopup)
        _stMultiRow:SetFrameLevel(stPopup:GetFrameLevel() + 3)
        PP.Height(_stMultiRow, ST_ROW_H)
        local mlbl = EllesmereUI.MakeFont(_stMultiRow, 12, nil, 1, 1, 1)
        mlbl:SetAlpha(0.6)
        mlbl:SetPoint("LEFT", _stMultiRow, "LEFT", 0, 0)
        mlbl:SetText(EllesmereUI.L("Use Multiple Thresholds"))
        local multiToggle
        multiToggle, _, _stMultiSnap = EllesmereUI.BuildToggleControl(
            _stMultiRow, _stMultiRow:GetFrameLevel() + 3,
            function()
                local cfg = CurrentStackThreshCfg()
                return cfg and cfg.stackThresholdMulti
            end,
            function(v)
                local cfg = CurrentStackThreshCfg(); if not cfg then return end
                cfg.stackThresholdMulti = v and true or false
                if _stRefreshFn then _stRefreshFn() end
                RefreshStackThreshEditor()
                EllesmereUI:RefreshPage()
            end,
            { sizeRatio = 0.95 })
        multiToggle:SetPoint("RIGHT", _stMultiRow, "RIGHT", 0, 0)
        local multiHit = CreateFrame("Frame", nil, _stMultiRow)
        multiHit:SetAllPoints(mlbl)
        multiHit:EnableMouse(true)
        multiHit:SetScript("OnEnter", function(self) EllesmereUI.ShowWidgetTooltip(self, StackThreshHelpTip()) end)
        multiHit:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)

        -- Add Threshold button
        _stAddBtn = CreateFrame("Button", nil, stPopup)
        PP.Size(_stAddBtn, ST_POPUP_W - ST_PAD * 2, 26)
        _stAddBtn:SetFrameLevel(stPopup:GetFrameLevel() + 3)
        local abg = EllesmereUI.SolidTex(_stAddBtn, "BACKGROUND", 0.05, 0.07, 0.09, 0.92)
        abg:SetAllPoints()
        _stAddBtn._border = EllesmereUI.MakeBorder(_stAddBtn, 1, 1, 1, 0.4, PP)
        _stAddLbl = EllesmereUI.MakeFont(_stAddBtn, 12, nil, 1, 1, 1)
        _stAddLbl:SetAlpha(0.5)
        _stAddLbl:SetPoint("CENTER")
        _stAddLbl:SetText(EllesmereUI.L("+ Add Threshold"))
        _stAddBtn:SetScript("OnEnter", function(self)
            local cfg = CurrentStackThreshCfg()
            local list = cfg and cfg.stackThresholds
            if list and #list >= STACK_THRESH_MAX then
                EllesmereUI.ShowWidgetTooltip(self, StackThreshAtCapTip())
                return
            end
            _stAddLbl:SetAlpha(0.7)
            if self._border and self._border.SetColor then self._border:SetColor(1, 1, 1, 0.6) end
        end)
        _stAddBtn:SetScript("OnLeave", function(self)
            EllesmereUI.HideWidgetTooltip()
            _stAddLbl:SetAlpha(0.5)
            if self._border and self._border.SetColor then self._border:SetColor(1, 1, 1, 0.4) end
        end)
        _stAddBtn:SetScript("OnClick", function()
            local cfg = CurrentStackThreshCfg(); if not cfg then return end
            if not cfg.stackThresholds then cfg.stackThresholds = {} end
            local list = cfg.stackThresholds
            if #list >= STACK_THRESH_MAX then return end
            local last = list[#list]
            local nextVal = last and math.min(100, (last.value or 0) + 1) or 5
            list[#list + 1] = { value = nextVal, r = ST_DEF_R, g = ST_DEF_G, b = ST_DEF_B, a = ST_DEF_A }
            SortStackThresholds(list)
            if _stRefreshFn then _stRefreshFn() end
            RefreshStackThreshEditor()
        end)
    end

    -- Lazily create the widgets for threshold row k; returns the row table.
    local function EnsureStackThreshRow(k)
        local row = _stRows[k]
        if row then return row end
        row = {}
        local rf = CreateFrame("Frame", nil, stPopup)
        rf:SetSize(ST_POPUP_W - ST_PAD * 2, ST_ROW_H)
        rf:SetFrameLevel(stPopup:GetFrameLevel() + 2)
        row.frame = rf

        local lbl = EllesmereUI.MakeFont(rf, 12, nil, 1, 1, 1)
        lbl:SetAlpha(0.6)
        lbl:SetPoint("LEFT", rf, "LEFT", 2, 0)
        lbl:SetText(EllesmereUI.L("At"))
        row.lbl = lbl

        local input = CreateFrame("EditBox", nil, rf)
        input:SetSize(54, 22)
        input:SetPoint("LEFT", lbl, "RIGHT", 6, 0)
        input:SetFrameLevel(rf:GetFrameLevel() + 2)
        input:SetAutoFocus(false)
        input:SetFontObject(GameFontHighlightSmall)
        local inFont = EllesmereUI.GetFontPath("main") or "Fonts\\FRIZQT__.TTF"
        input:SetFont(inFont, 12, "")
        input:SetTextColor(1, 1, 1, 0.75)
        input:SetJustifyH("CENTER")
        input:SetNumeric(true)
        local inBg = input:CreateTexture(nil, "BACKGROUND")
        inBg:SetAllPoints()
        inBg:SetColorTexture(0.12, 0.12, 0.12, 0.8)
        EllesmereUI.MakeBorder(input, 1, 1, 1, 0.08, PP)
        row.input = input

        -- Commit on focus loss (Enter clears focus -> triggers this; Escape sets
        -- _cancelCommit to discard the typed text).
        local function CommitInput(self)
            if self._cancelCommit then self._cancelCommit = nil; return end
            local cfg = CurrentStackThreshCfg()
            local list = cfg and cfg.stackThresholds
            local ent = list and list[row._idx]
            if not ent then return end
            local val = tonumber(self:GetText())
            if val then
                -- Same range as the single-threshold slider on the Extras row.
                ent.value = math.max(0, math.min(100, math.floor(val + 0.5)))
                SortStackThresholds(list)
                if _stRefreshFn then _stRefreshFn() end
            end
            RefreshStackThreshEditor()
        end
        input:SetScript("OnEditFocusLost", CommitInput)
        input:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
        input:SetScript("OnEscapePressed", function(self) self._cancelCommit = true; self:ClearFocus(); RefreshStackThreshEditor() end)

        local swatch, swatchSnap = EllesmereUI.BuildColorSwatch(rf, rf:GetFrameLevel() + 3,
            function()
                local cfg = CurrentStackThreshCfg()
                local list = cfg and cfg.stackThresholds
                local ent = list and list[row._idx]
                if not ent then return ST_DEF_R, ST_DEF_G, ST_DEF_B, ST_DEF_A end
                return ent.r or ST_DEF_R, ent.g or ST_DEF_G, ent.b or ST_DEF_B, ent.a or ST_DEF_A
            end,
            function(r, g, b, a)
                local cfg = CurrentStackThreshCfg()
                local list = cfg and cfg.stackThresholds
                local ent = list and list[row._idx]
                if ent then
                    ent.r, ent.g, ent.b, ent.a = r, g, b, a
                    if _stRefreshFn then _stRefreshFn() end
                end
            end, true, 19)
        swatch:SetPoint("LEFT", input, "RIGHT", 10, 0)
        row.swatch = swatch
        row.swatchSnap = swatchSnap

        local delBtn = CreateFrame("Button", nil, rf)
        delBtn:SetSize(14, 14)
        delBtn:SetPoint("RIGHT", rf, "RIGHT", -2, 0)
        delBtn:SetFrameLevel(rf:GetFrameLevel() + 3)
        local delIcon = delBtn:CreateTexture(nil, "OVERLAY")
        delIcon:SetAllPoints()
        delIcon:SetTexture(_stCloseIcon)
        delIcon:SetAlpha(0.4)
        delBtn:SetScript("OnEnter", function() delIcon:SetAlpha(0.9) end)
        delBtn:SetScript("OnLeave", function() delIcon:SetAlpha(0.4) end)
        delBtn:SetScript("OnClick", function()
            local cfg = CurrentStackThreshCfg()
            local list = cfg and cfg.stackThresholds
            if list and list[row._idx] then
                table.remove(list, row._idx)
                -- An empty list would silently fall back to the single threshold while the
                -- toggle still reads "on"; turn it off so the popup matches the bar.
                if #list == 0 and cfg.stackThresholdMulti then
                    cfg.stackThresholdMulti = false
                    EllesmereUI:RefreshPage()
                end
                if _stRefreshFn then _stRefreshFn() end
                RefreshStackThreshEditor()
            end
        end)
        row.delBtn = delBtn

        _stRows[k] = row
        return row
    end

    RefreshStackThreshEditor = function()
        if not stPopup then return end
        local cfg = CurrentStackThreshCfg()
        if not cfg then stPopup:Hide(); return end
        if not cfg.stackThresholds then cfg.stackThresholds = {} end
        local list = cfg.stackThresholds

        local curY = -(ST_PAD + 24)  -- below the title

        _stMultiRow:ClearAllPoints()
        PP.Point(_stMultiRow, "TOPLEFT", stPopup, "TOPLEFT", ST_PAD, curY)
        PP.Point(_stMultiRow, "TOPRIGHT", stPopup, "TOPRIGHT", -ST_PAD, curY)
        _stMultiRow:Show()
        if _stMultiSnap then _stMultiSnap() end
        curY = curY - ST_ROW_H - ST_GAP

        local n = #list
        for k = 1, n do
            local row = EnsureStackThreshRow(k)
            row._idx = k
            row.frame:ClearAllPoints()
            PP.Point(row.frame, "TOPLEFT", stPopup, "TOPLEFT", ST_PAD, curY)
            row.input:SetText(tostring(list[k].value or 5))
            if row.swatchSnap then row.swatchSnap() end
            row.frame:Show()
            curY = curY - ST_ROW_H - 4
        end
        for k = n + 1, #_stRows do
            if _stRows[k] then _stRows[k].frame:Hide() end
        end

        curY = curY - 4
        _stAddBtn:ClearAllPoints()
        PP.Point(_stAddBtn, "TOPLEFT", stPopup, "TOPLEFT", ST_PAD, curY)
        local atCap = (n >= STACK_THRESH_MAX)
        _stAddBtn:SetEnabled(not atCap)
        _stAddBtn:SetAlpha(atCap and 0.35 or 1)
        curY = curY - 26

        local totalH = math.abs(curY) + ST_PAD
        PP.Size(stPopup, ST_POPUP_W, totalH)
    end

    -- params = { getCfg, refreshFn, anchor }
    local function ShowStackThreshEditor(params)
        if not stPopup then BuildStackThreshPopup() end
        _stGetCfg   = params.getCfg
        _stRefreshFn = params.refreshFn
        local cfg = CurrentStackThreshCfg()
        if cfg then
            if not cfg.stackThresholds then cfg.stackThresholds = {} end
            -- Seed the first entry from the single threshold the first time; inert until
            -- stackThresholdMulti is on, so opening/closing this popup changes nothing on the bar.
            if #cfg.stackThresholds == 0 then
                cfg.stackThresholds[1] = {
                    value = cfg.stackThreshold or 5,
                    r = cfg.stackThresholdR or ST_DEF_R, g = cfg.stackThresholdG or ST_DEF_G,
                    b = cfg.stackThresholdB or ST_DEF_B, a = cfg.stackThresholdA or ST_DEF_A,
                }
            end
        end
        RefreshStackThreshEditor()
        stPopup:ClearAllPoints()
        stPopup:SetPoint("TOP", params.anchor, "BOTTOM", 0, -4)
        stPopup:Show()
    end

    local function BuildBuffBarsPage(pageName, parent, yOffset)
        local W = EllesmereUI.Widgets
        local y = yOffset
        local _, h

        -- If user chose Blizzard bars, show re-enable button and bail
        local usingBlizz = DB() and DB().cdmBars and DB().cdmBars.useBlizzardBuffBars
        if usingBlizz then
            _, h = W:WideDualButton(parent,
                "Enable Tracking Bars", "Open Blizzard CDM", y,
                function()
                    local p = DB()
                    if p and p.cdmBars then
                        p.cdmBars.useBlizzardBuffBars = false
                    end
                    EllesmereUI:ShowConfirmPopup({
                        title = "Reload Required",
                        message = "Switching to EllesmereUI Tracking Bars requires a reload.",
                        confirmText = "Reload Now",
                        cancelText = "Later",
                        reload    = true,
                    })
                end,
                function()
                    if ns.OpenBlizzardCDMTab then ns.OpenBlizzardCDMTab(true) end
                end, 310);  y = y - h
            return math.abs(y)
        end

        -- Pre-populate bars for spells newly added to Blizzard's Tracked Bars before
        -- reading the bar list, so the page always shows them.
        if ns.EnsureTBBAutoBars and ns.EnsureTBBAutoBars() > 0 then
            ns.BuildTrackedBuffBars()
        end

        local tbb = ns.GetTrackedBuffBars()
        -- Hold the per-group orientation invariant before any widget reads the configs
        -- (the page-tail rebuild runs after).
        if ns.EnforceTBBGroupOrientation then ns.EnforceTBBGroupOrientation(tbb) end
        local bars = tbb.bars
        if _tbbSelectedBar > #bars then _tbbSelectedBar = math.max(1, #bars) end

        local function SelectedTBB()
            local t = ns.GetTrackedBuffBars()
            if _tbbSelectedBar < 1 or _tbbSelectedBar > #t.bars then return nil end
            return t.bars[_tbbSelectedBar]
        end

        local function SelectedTBBSupportsChargeHash()
            local bd = SelectedTBB()
            return bd and ns.GetTBBMaxCharges
                and ns.GetTBBMaxCharges(bd) ~= nil
        end

        -- Validate the group selection against the live group list (groups dissolve when
        -- their last bar is deleted). Bar-less GLOBAL groups are legal selections: the
        -- Currently Editing menu lists them on every spec precisely so their shared
        -- settings stay editable, and their local gid persists through its globalKey
        -- link with no member bars (every GROUP MODE section is group-keyed and the
        -- previews hide/guard on an empty member list).
        if _tbbSelectedGroup then
            local ok = false
            for _, g in ipairs(ns.TBBGroupIDsInUse()) do
                if g == _tbbSelectedGroup then ok = true; break end
            end
            if not ok and ns.TBBGroupGlobalKey and ns.TBBGroupGlobalKey(_tbbSelectedGroup) then
                ok = true
            end
            if not ok then _tbbSelectedGroup = nil end
        end

        -- The preview mirrors whatever is being edited: the selected bar, or the selected
        -- group's style source (its anchor bar).
        local function PreviewCfg()
            if _tbbSelectedGroup then
                return ns.TBBGroupStyleSource(_tbbSelectedGroup)
            end
            return SelectedTBB()
        end

        local function GroupLabel(gid)
            return (ns.TBBGroupName and ns.TBBGroupName(gid))
                or (EllesmereUI.L("Group") .. " " .. gid)
        end

        -------------------------------------------------------------------
        --  CLICK NAVIGATION (preview elements -> option rows). Map lives on
        --  parent._tbbClickTargets (populated by the bar-mode section build below);
        --  overlays resolve it at click time so a header rebuild never holds stale refs.
        -------------------------------------------------------------------
        local PlaySettingGlow = EllesmereUI.MakeSettingGlow({ color = EllesmereUI.ELLESMERE_GREEN })

        local function NavigateToSetting(key)
            local targets = parent._tbbClickTargets
            if not targets then return end
            local m = targets[key]
            if not m or not m.section or not m.target then return end
            EllesmereUIDB = EllesmereUIDB or {}
            EllesmereUIDB.previewHintDismissed = true
            if _tbbPopout and _tbbPopout._hint then _tbbPopout._hint:Hide() end
            local _, _, _, _, headerY = m.section:GetPoint(1)
            if not headerY then return end
            EllesmereUI.SmoothScrollTo(math.max(0, math.abs(headerY) - 40))
            local glowTarget = m.target
            if m.slotSide then
                local region = (m.slotSide == "left") and m.target._leftRegion or m.target._rightRegion
                if region then glowTarget = region end
            end
            C_Timer.After(0.15, function() PlaySettingGlow(glowTarget) end)
        end

        local _tbbRefreshTimer

        local function RefreshTBB()
            if _tbbRefreshTimer then _tbbRefreshTimer:Cancel() end
            _tbbRefreshTimer = C_Timer.NewTimer(0.05, function()
                _tbbRefreshTimer = nil
                Refresh()
                ns.BuildTrackedBuffBars()
                RefreshTBBPopout()
                UpdateTBBPlaceholder()
            end)
        end
        -- Expose this build's RefreshTBB to the outer spec-change watcher so a spec swap
        -- while this page is open rebuilds the dropdown/preview.
        _tbbRefreshFn = RefreshTBB

        -- Drag-and-drop move: put a bar into another group (or make it independent).
        -- Joining a group adopts its current look, same as a freshly added bar; selects the moved bar.
        local function MoveBarToGroup(idx, gid)
            local t = ns.GetTrackedBuffBars()
            local cfg = t.bars and t.bars[idx]
            if not cfg then return end
            if ns.TBBBarGroupID(cfg) == gid then return end
            ns.TBBSetBarGroup(cfg, gid)
            if gid ~= 0 then
                local src = ns.TBBGroupStyleSource(gid)
                if src and src ~= cfg then ns.CopyTBBStyle(src, cfg) end
            end
            _tbbSelectedBar = idx
            _tbbSelectedGroup = nil
            ns.BuildTrackedBuffBars()
            EllesmereUI:RefreshPage(true)
        end

        -------------------------------------------------------------------
        --  MANAGEMENT DROPDOWN builder ("Currently Editing:"). Creates the bar/group
        --  selector inside `parentFrame` (Preset Style panel), returns the dropdown
        --  button; caller positions it.
        -------------------------------------------------------------------
        local function BuildManagementDropdown(parentFrame)
            local DD_H = 34
            local ddW = 350

            local DDS = EllesmereUI.DD_STYLE
            local mBgR  = DDS.BG_R
            local mBgG  = DDS.BG_G
            local mBgB  = DDS.BG_B
            local mBgA  = DDS.BG_A
            local mBgHA = DDS.BG_HA
            local mBrdA = DDS.BRD_A
            local mBrdHA = DDS.BRD_HA or 0.30
            local mTxtA = DDS.TXT_A
            local mTxtHA = DDS.TXT_HA or 1
            local hlA   = DDS.ITEM_HL_A
            local selA  = DDS.ITEM_SEL_A
            local tDimR = EllesmereUI.TEXT_DIM_R or 0.7
            local tDimG = EllesmereUI.TEXT_DIM_G or 0.7
            local tDimB = EllesmereUI.TEXT_DIM_B or 0.7
            local tDimA = EllesmereUI.TEXT_DIM_A or 0.85
            local ITEM_H = 26
            local MEDIA = "Interface\\AddOns\\EllesmereUI\\media\\"
            local ICON_SZ = 14

            local ddBtn = CreateFrame("Button", nil, parentFrame)
            PP.Size(ddBtn, ddW, DD_H)
            ddBtn:SetFrameLevel(parentFrame:GetFrameLevel() + 5)
            local ddBg = ddBtn:CreateTexture(nil, "BACKGROUND")
            ddBg:SetAllPoints(); ddBg:SetColorTexture(mBgR, mBgG, mBgB, mBgA)
            local ddBrd = EllesmereUI.MakeBorder(ddBtn, 1, 1, 1, mBrdA, EllesmereUI.PanelPP)
            local ddLbl = ddBtn:CreateFontString(nil, "OVERLAY")
            ddLbl:SetFont(FONT_PATH, 13, GetCDMOptOutline())
            ddLbl:SetAlpha(mTxtA)
            ddLbl:SetJustifyH("LEFT")
            ddLbl:SetWordWrap(false); ddLbl:SetMaxLines(1)
            ddLbl:SetPoint("LEFT", ddBtn, "LEFT", 12, 0)
            local arrow = EllesmereUI.MakeDropdownArrow(ddBtn, 12, EllesmereUI.PanelPP)
            ddLbl:SetPoint("RIGHT", arrow, "LEFT", -5, 0)

            local function UpdateDDLabel()
                if _tbbSelectedGroup then
                    local n = ns.TBBGroupedCount(_tbbSelectedGroup)
                    ddLbl:SetText(GroupLabel(_tbbSelectedGroup)
                        .. "  -  " .. n .. " " .. EllesmereUI.L(n == 1 and "Bar" or "Bars"))
                    return
                end
                local bd = SelectedTBB()
                if bd then
                    local label = (bd.name and EllesmereUI.L(bd.name)) or "Bar"
                    if not bd.popularKey and bd.spellID and bd.spellID > 0 then
                        local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(bd.spellID)
                        if info and info.name then label = info.name end
                    end
                    local gid = ns.TBBBarGroupID and ns.TBBBarGroupID(bd) or 0
                    if gid ~= 0 then
                        label = label .. "  (" .. GroupLabel(gid) .. ")"
                    end
                    ddLbl:SetText(label)
                else
                    -- Re-fetch the live (per-spec) bar count instead of the build-time `bars`
                    -- upvalue: this header builder is reused across SetContentHeader refreshes
                    -- (e.g. spec change) without a page rebuild, so captured `bars` can be stale.
                    local liveBars = ns.GetTrackedBuffBars().bars
                    if not liveBars or #liveBars == 0 then
                        ddLbl:SetText(EllesmereUI.L("No Bars - Click to Add"))
                    else
                        ddLbl:SetText(EllesmereUI.L("Select a bar"))
                    end
                end
            end
            UpdateDDLabel()

            -- Can this bar play Audio on Buff Gain / Loss? The one check behind the
            -- row right-click, the speaker mark and the menu hint. A sound follows a
            -- buff edge: the bar needs a buff assigned and tracked as a buff (never a
            -- cooldown-tracking bar), and the runtime needs an edge source for it (a
            -- Blizzard buff viewer frame, or a self-timed preset).
            local function BarTakesSound(b)
                if not b or b.trackType == "cooldown" then return false end
                if not ((b.spellID and b.spellID > 0) or b.glowBased) then return false end
                return ns.TBB_BarCanCue(b) and true or false
            end

            -- Right-click a bar row: Audio on Buff Gain / Loss for that bar, the
            -- tracking-bar twin of the CDM icon menu's two audio rows. Opens beside the
            -- clicked row; each row flies out the shared sound list (search, scroll,
            -- preview speaker) from BuildSoundDropdownValues. Same keys and sound
            -- catalogue as the icon menu; playback lives in EllesmereUICdmBuffBars.
            local function OpenBarSoundMenu(idx, anchorRow)
                local t = ns.GetTrackedBuffBars()
                local cfg = t.bars and t.bars[idx]
                if not cfg then return end
                if ddBtn._tbbSndMenu then ddBtn._tbbSndMenu:Hide() end
                local W = 240
                local sm = CreateFrame("Frame", nil, UIParent)
                sm:SetFrameStrata("FULLSCREEN_DIALOG")
                -- Above the bar menu it opens from (300), which stays open underneath.
                sm:SetFrameLevel(320)
                sm:SetClampedToScreen(true)
                sm:EnableMouse(true)
                sm:SetSize(W, 8 + ITEM_H * 2)
                local smBg = sm:CreateTexture(nil, "BACKGROUND")
                smBg:SetAllPoints(); smBg:SetColorTexture(mBgR, mBgG, mBgB, mBgHA)
                EllesmereUI.MakeBorder(sm, 1, 1, 1, mBrdA, EllesmereUI.PP)
                -- A fixed spot, as the CDM icon menu sits under its icon: beside the clicked
                -- row, just outside the bar menu, so it covers no other bar.
                sm:SetPoint("TOPLEFT", anchorRow, "TOPRIGHT", 4, 0)
                local ar, ag, ab = EllesmereUI.GetAccentColor()
                local names = ns.FOCUSKICK_SOUND_NAMES or {}
                local flyouts = {}

                local function MakeSoundRow(i, label, field)
                    local row = CreateFrame("Button", nil, sm)
                    row:SetHeight(ITEM_H)
                    row:SetPoint("TOPLEFT", sm, "TOPLEFT", 1, -4 - (i - 1) * ITEM_H)
                    row:SetPoint("TOPRIGHT", sm, "TOPRIGHT", -1, -4 - (i - 1) * ITEM_H)
                    row:SetFrameLevel(sm:GetFrameLevel() + 2)
                    local lbl = row:CreateFontString(nil, "OVERLAY")
                    lbl:SetFont(FONT_PATH, 11, GetCDMOptOutline())
                    lbl:SetPoint("LEFT", row, "LEFT", 10, 0)
                    lbl:SetText(EllesmereUI.L(label))
                    local arrow = row:CreateTexture(nil, "ARTWORK")
                    arrow:SetSize(10, 10)
                    arrow:SetPoint("RIGHT", row, "RIGHT", -8, 0)
                    arrow:SetTexture(MEDIA .. "icons\\right-arrow.png")
                    arrow:SetAlpha(0.7)
                    local val = row:CreateFontString(nil, "OVERLAY")
                    val:SetFont(FONT_PATH, 10, GetCDMOptOutline())
                    val:SetPoint("LEFT", lbl, "RIGHT", 8, 0)
                    val:SetPoint("RIGHT", arrow, "LEFT", -6, 0)
                    val:SetJustifyH("RIGHT")
                    val:SetWordWrap(false); val:SetMaxLines(1)
                    val:SetTextColor(tDimR, tDimG, tDimB, tDimA)
                    local hl = row:CreateTexture(nil, "ARTWORK")
                    hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 1); hl:SetAlpha(0)

                    local function Get() return cfg[field] or "none" end
                    -- Accent label while a sound is chosen, like the icon menu's rows.
                    local function Paint()
                        local k = cfg[field]
                        if k and k ~= "none" then
                            lbl:SetTextColor(ar, ag, ab, 1)
                        else
                            lbl:SetTextColor(tDimR, tDimG, tDimB, tDimA)
                        end
                        val:SetText(names[Get()] or Get())
                    end
                    Paint()
                    local function Set(v)
                        cfg[field] = (v ~= "none" and v) or nil
                        if cfg[field] then
                            -- Flip the 0-cost gate live and hook the bar frames already
                            -- out of the pool, so the next edge plays without a reload.
                            ns._cdmAnyBuffSound = true
                            if ns.EnsureTBBSoundHooks then ns.EnsureTBBSoundHooks() end
                        end
                        Paint()
                        -- The bar row's speaker button follows (dimmed with no sound).
                        if anchorRow._sndPaint then anchorRow._sndPaint() end
                    end
                    local function ShowFlyout()
                        hl:SetAlpha(hlA)
                        for f, fly in pairs(flyouts) do
                            if f ~= field then fly:Hide() end
                        end
                        local fly = flyouts[field]
                        if not fly then
                            local values, order = EllesmereUI.BuildSoundDropdownValues(
                                ns.FOCUSKICK_SOUND_PATHS, names, ns.FOCUSKICK_SOUND_ORDER)
                            values._menuOpts.anchor = "RIGHT"
                            -- Match the CDM icon menu's flyouts: the CDM options font at 11 and
                            -- the speaker atlas in its own colour.
                            values._menuOpts.labelFont = { FONT_PATH, 11, GetCDMOptOutline() }
                            values._menuOpts.iconNativeColor = true
                            local refresh
                            fly, _, refresh = EllesmereUI.BuildDropdownMenu(row, 200, order, values, Get, Set, val, "regular")
                            -- BuildDropdownMenu creates it at FULLSCREEN_DIALOG 200, under both menus.
                            fly:SetFrameStrata(sm:GetFrameStrata())
                            fly:SetFrameLevel(sm:GetFrameLevel() + 30)
                            fly._refresh = refresh
                            flyouts[field] = fly
                        end
                        if not fly:IsShown() then
                            if fly._refresh then fly._refresh() end
                            fly:Show()
                        end
                    end
                    row:SetScript("OnEnter", ShowFlyout)
                    row:SetScript("OnClick", ShowFlyout)
                    row:SetScript("OnLeave", function() hl:SetAlpha(0) end)
                end
                MakeSoundRow(1, "Audio on Buff Gain", "buffActiveSoundKey")
                MakeSoundRow(2, "Audio on Buff Loss", "buffLostSoundKey")

                local function OverAny()
                    if sm:IsMouseOver() then return true end
                    for _, fly in pairs(flyouts) do
                        if fly:IsShown() and fly:IsMouseOver() then return true end
                    end
                    return false
                end
                sm:SetScript("OnUpdate", function(m)
                    if (IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton"))
                       and not OverAny() then
                        m:Hide()
                    end
                end)
                sm:HookScript("OnHide", function(m)
                    m:SetScript("OnUpdate", nil)
                    for _, fly in pairs(flyouts) do fly:Hide() end
                end)
                -- The bar menu underneath asks this before dismissing itself on a click.
                sm._overAny = OverAny
                ddBtn._tbbSndMenu = sm
                sm:Show()
            end

            -- Custom dropdown menu: bars organized by group with quick-add actions inside
            -- each, an independent section, and new-group/independent-bar creation at the bottom.
            local ddMenu
            local function BuildDDMenu()
                if ddMenu then ddMenu:Hide(); ddMenu = nil end
                local t = ns.GetTrackedBuffBars()
                -- Screen-level overlay: created hidden, tracked once its scripts are set.
                local menu = CreateFrame("Frame", nil, EllesmereUI.OverlayParent())
                menu:Hide()
                menu:SetFrameStrata("FULLSCREEN_DIALOG")
                menu:SetFrameLevel(300)
                menu:SetClampedToScreen(true)
                menu:SetPoint("TOPLEFT", ddBtn, "BOTTOMLEFT", 0, -2)
                menu:SetPoint("TOPRIGHT", ddBtn, "BOTTOMRIGHT", 0, -2)
                local bg = menu:CreateTexture(nil, "BACKGROUND")
                bg:SetAllPoints(); bg:SetColorTexture(mBgR, mBgG, mBgB, mBgHA)
                EllesmereUI.MakeBorder(menu, 1, 1, 1, mBrdA, EllesmereUI.PP)

                -- Rows build on an inner frame so tall menus can scroll.
                local inner = CreateFrame("Frame", nil, menu)
                -- The options panel can run at a different effective scale than this
                -- screen-level menu; normalize button width into menu space so rows end exactly at the menu's edges.
                inner:SetWidth(ddBtn:GetWidth() * ddBtn:GetEffectiveScale() / menu:GetEffectiveScale())
                inner:SetPoint("TOPLEFT")
                local MENU_MAX_H = 420
                local ar, ag, ab = EllesmereUI.GetAccentColor()

                local mH = 4

                -- Drag-and-drop: bar rows can be dragged onto another group's section (or
                -- independent) to move them; zones collect every row of a group so the whole
                -- section is a drop target. Drag flag declared before any OnUpdate reads it.
                local dropZones = {}   -- { gid, label, frames = {rows...} }
                local dragState = { idx = nil, name = nil }
                menu._dragActive = false

                local function HoveredZone()
                    for _, z in ipairs(dropZones) do
                        for _, f in ipairs(z.frames) do
                            if f and f:IsMouseOver() then return z end
                        end
                    end
                    return nil
                end

                local dragGhost
                local function GhostUpdate()
                    local cx, cy = GetCursorPosition()
                    local sc = UIParent:GetEffectiveScale()
                    dragGhost:ClearAllPoints()
                    dragGhost:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", cx / sc + 14, cy / sc - 22)
                    local z = HoveredZone()
                    if z and dragState.idx then
                        local t2 = ns.GetTrackedBuffBars()
                        local c2 = t2.bars and t2.bars[dragState.idx]
                        if c2 and ns.TBBBarGroupID(c2) ~= z.gid then
                            dragGhost._lbl:SetText(dragState.name .. "  >  " .. z.label)
                            dragGhost._lbl:SetTextColor(ar, ag, ab, 1)
                            return
                        end
                    end
                    dragGhost._lbl:SetText(dragState.name or "")
                    dragGhost._lbl:SetTextColor(1, 1, 1, 0.8)
                end
                local function EnsureGhost()
                    if dragGhost then return dragGhost end
                    dragGhost = CreateFrame("Frame", nil, UIParent)
                    dragGhost:SetFrameStrata("TOOLTIP")
                    dragGhost:SetFrameLevel(500)
                    dragGhost:SetSize(10, 20)
                    local gl = dragGhost:CreateFontString(nil, "OVERLAY")
                    gl:SetFont(FONT_PATH, 11, GetCDMOptOutline())
                    gl:SetPoint("BOTTOMLEFT", dragGhost, "BOTTOMLEFT", 0, 0)
                    dragGhost._lbl = gl
                    dragGhost:Hide()
                    return dragGhost
                end
                local function StopDrag()
                    menu._dragActive = false
                    dragState.idx = nil
                    if dragGhost then
                        dragGhost:Hide()
                        dragGhost:SetScript("OnUpdate", nil)
                    end
                end
                menu:HookScript("OnHide", StopDrag)

                local function BarIconID(b)
                    if b.popularKey and ns.TBB_POPULAR_BUFFS then
                        for _, pe in ipairs(ns.TBB_POPULAR_BUFFS) do
                            if pe.key == b.popularKey then return pe.icon end
                        end
                    end
                    if b.spellID and b.spellID > 0 then
                        local tex = C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(b.spellID)
                        if tex then return tex end
                    end
                    return 134400
                end

                local function AddHeaderRow(text)
                    if mH > 4 then mH = mH + 4 end
                    local hLbl = inner:CreateFontString(nil, "OVERLAY")
                    hLbl:SetFont(FONT_PATH, 10, GetCDMOptOutline())
                    hLbl:SetTextColor(1, 1, 1, 0.9)
                    hLbl:SetPoint("TOPLEFT", inner, "TOPLEFT", 10, -mH - 5)
                    hLbl:SetText(text)
                    mH = mH + 20
                end

                -- Group header: clickable, selects the GROUP as editing context (group
                -- settings replace per-bar sections). gkey (optional) = group's globalKey,
                -- adds the GLOBAL tag + a delete button that removes it for every spec (with confirmation).
                local function AddGroupHeaderRow(gid, gkey)
                    if mH > 4 then mH = mH + 4 end
                    local item = CreateFrame("Button", nil, inner)
                    item:SetHeight(22)
                    item:SetPoint("TOPLEFT", inner, "TOPLEFT", 1, -mH)
                    item:SetPoint("TOPRIGHT", inner, "TOPRIGHT", -1, -mH)
                    item:SetFrameLevel(menu:GetFrameLevel() + 2)
                    local hLbl = item:CreateFontString(nil, "OVERLAY")
                    hLbl:SetFont(FONT_PATH, 10, GetCDMOptOutline())
                    hLbl:SetTextColor(1, 1, 1, 0.9)
                    hLbl:SetPoint("LEFT", item, "LEFT", 10, 0)
                    local groupDisplayName = (ns.TBBGroupName and ns.TBBGroupName(gid))
                        or (EllesmereUI.L("GROUP") .. " " .. gid)
                    hLbl:SetText(groupDisplayName)
                    if gkey then
                        local gTag = item:CreateFontString(nil, "OVERLAY")
                        gTag:SetFont(FONT_PATH, 9, GetCDMOptOutline())
                        gTag:SetTextColor(ar, ag, ab, 0.9)
                        gTag:SetPoint("LEFT", hLbl, "RIGHT", 6, 0)
                        gTag:SetText(EllesmereUI.L("GLOBAL"))
                    end
                    local eLbl = item:CreateFontString(nil, "OVERLAY")
                    eLbl:SetFont(FONT_PATH, 10, GetCDMOptOutline())
                    eLbl:SetTextColor(ar, ag, ab, 0.85)
                    eLbl:SetText(EllesmereUI.L("Edit Group"))
                    local delBtn
                    if gkey then
                        delBtn = CreateFrame("Button", nil, item)
                        delBtn:SetSize(ICON_SZ, ICON_SZ)
                        delBtn:SetPoint("RIGHT", item, "RIGHT", -8, 0)
                        delBtn:SetFrameLevel(item:GetFrameLevel() + 2)
                        local delIcon = delBtn:CreateTexture(nil, "OVERLAY")
                        delIcon:SetSize(ICON_SZ, ICON_SZ)
                        delIcon:SetPoint("CENTER")
                        if delIcon.SetSnapToPixelGrid then delIcon:SetSnapToPixelGrid(false); delIcon:SetTexelSnappingBias(0) end
                        delIcon:SetTexture(MEDIA .. "icons\\eui-close.png")
                        delBtn:SetAlpha(0.6)
                        delBtn:SetScript("OnEnter", function()
                            delBtn:SetAlpha(1)
                            EllesmereUI.ShowWidgetTooltip(delBtn, EllesmereUI.L("Delete this global group for all specs"))
                        end)
                        delBtn:SetScript("OnLeave", function()
                            delBtn:SetAlpha(0.6)
                            EllesmereUI.HideWidgetTooltip()
                        end)
                        delBtn:SetScript("OnClick", function()
                            menu:Hide()
                            EllesmereUI:ShowConfirmPopup({
                                title = "Delete Global Group",
                                message = EllesmereUI.Lf("Delete \"%1$s\" for ALL specs? Bars keep their current positions.", groupDisplayName),
                                confirmText = "Delete", cancelText = "Cancel",
                                onConfirm = function()
                                    if ns.TBBDeleteGlobalGroup then ns.TBBDeleteGlobalGroup(gkey) end
                                    if _tbbSelectedGroup == gid then _tbbSelectedGroup = nil end
                                    ns.BuildTrackedBuffBars()
                                    EllesmereUI:RefreshPage(true)
                                end,
                            })
                        end)
                        eLbl:SetPoint("RIGHT", delBtn, "LEFT", -8, 0)
                    else
                        eLbl:SetPoint("RIGHT", item, "RIGHT", -10, 0)
                    end
                    local hl = item:CreateTexture(nil, "ARTWORK")
                    hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 1)
                    local isSel = _tbbSelectedGroup == gid
                    hl:SetAlpha(isSel and selA or 0)
                    item:SetScript("OnEnter", function()
                        hLbl:SetTextColor(1, 1, 1, 1); eLbl:SetTextColor(1, 1, 1, 0.9); hl:SetAlpha(hlA)
                    end)
                    item:SetScript("OnLeave", function()
                        hLbl:SetTextColor(1, 1, 1, 0.9); eLbl:SetTextColor(ar, ag, ab, 0.85)
                        hl:SetAlpha(isSel and selA or 0)
                    end)
                    item:SetScript("OnClick", function()
                        menu:Hide()
                        _tbbSelectedGroup = gid
                        EllesmereUI:RefreshPage(true)
                    end)
                    mH = mH + 22
                    return item
                end

                local function AddBarItem(idx, b, indent)
                    local item = CreateFrame("Button", nil, inner)
                    item:SetHeight(ITEM_H)
                    item:SetPoint("TOPLEFT", inner, "TOPLEFT", 1, -mH)
                    item:SetPoint("TOPRIGHT", inner, "TOPRIGHT", -1, -mH)
                    item:SetFrameLevel(menu:GetFrameLevel() + 2)

                    local spIco = item:CreateTexture(nil, "OVERLAY")
                    spIco:SetSize(ITEM_H - 8, ITEM_H - 8)
                    spIco:SetPoint("LEFT", item, "LEFT", 10 + (indent or 0), 0)
                    spIco:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                    local unassigned = (not b.spellID or b.spellID == 0) and not b.glowBased
                    spIco:SetTexture(BarIconID(b))
                    if unassigned then spIco:SetDesaturated(true); spIco:SetAlpha(0.35) end

                    -- Icon = change this bar's buff (green border affordance)
                    local icoBtn = CreateFrame("Button", nil, item)
                    icoBtn:SetAllPoints(spIco)
                    icoBtn:SetFrameLevel(item:GetFrameLevel() + 3)
                    local egc = EllesmereUI.ELLESMERE_GREEN
                    local icoBrd = PP.CreateBorder(icoBtn, egc.r, egc.g, egc.b, 1, 1, "OVERLAY", 7)
                    if icoBrd then icoBrd:Hide() end
                    icoBtn:SetScript("OnEnter", function()
                        if icoBrd then icoBrd:Show() end
                        EllesmereUI.ShowWidgetTooltip(icoBtn, EllesmereUI.L("Change buff"))
                    end)
                    icoBtn:SetScript("OnLeave", function()
                        if icoBrd then icoBrd:Hide() end
                        EllesmereUI.HideWidgetTooltip()
                    end)
                    icoBtn:SetScript("OnClick", function()
                        menu:Hide()
                        OpenBuffPickerForBar(idx)
                    end)

                    local iLbl = item:CreateFontString(nil, "OVERLAY")
                    iLbl:SetFont(FONT_PATH, 11, GetCDMOptOutline())
                    iLbl:SetTextColor(tDimR, tDimG, tDimB, tDimA)
                    iLbl:SetJustifyH("LEFT")
                    iLbl:SetWordWrap(false); iLbl:SetMaxLines(1)
                    iLbl:SetPoint("LEFT", spIco, "RIGHT", 6, 0)
                    local displayName = (b.name and EllesmereUI.L(b.name)) or EllesmereUI.Lf("Bar %d", idx)
                    if not b.popularKey and b.spellID and b.spellID > 0 then
                        local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(b.spellID)
                        if info and info.name then displayName = info.name end
                    end
                    if unassigned then
                        displayName = displayName .. "  (" .. EllesmereUI.L("no buff assigned") .. ")"
                    end
                    iLbl:SetText(displayName)

                    local iHl = item:CreateTexture(nil, "ARTWORK")
                    iHl:SetAllPoints(); iHl:SetColorTexture(1, 1, 1, 1)
                    iHl:SetAlpha(idx == _tbbSelectedBar and selA or 0)

                    local delBtn = CreateFrame("Button", nil, item)
                    delBtn:SetSize(ICON_SZ, ICON_SZ)
                    delBtn:SetPoint("RIGHT", item, "RIGHT", -8, 0)
                    delBtn:SetFrameLevel(item:GetFrameLevel() + 2)
                    local delIcon = delBtn:CreateTexture(nil, "OVERLAY")
                    delIcon:SetSize(ICON_SZ, ICON_SZ)
                    delIcon:SetPoint("CENTER")
                    if delIcon.SetSnapToPixelGrid then delIcon:SetSnapToPixelGrid(false); delIcon:SetTexelSnappingBias(0) end
                    delIcon:SetTexture(MEDIA .. "icons\\eui-close.png")
                    delBtn:SetAlpha(0.75)
                    iLbl:SetPoint("RIGHT", delBtn, "LEFT", -4, 0)

                    -- Only a bar that can cue gets the sound menu: on a row right-click and
                    -- on the speaker button, dimmed ("Add Audio Effect") while the bar has
                    -- no Audio on Buff Gain/Loss sound and full ("Edit Audio Effect") once
                    -- it has one. The sound menu repaints it through item._sndPaint.
                    local soundable = BarTakesSound(b)
                    if soundable then
                        local sndBtn = CreateFrame("Button", nil, item)
                        sndBtn:SetSize(ICON_SZ, ICON_SZ)
                        sndBtn:SetPoint("RIGHT", delBtn, "LEFT", -6, 0)
                        sndBtn:SetFrameLevel(item:GetFrameLevel() + 2)
                        local sndIcon = sndBtn:CreateTexture(nil, "OVERLAY")
                        sndIcon:SetAllPoints()
                        sndIcon:SetAtlas(EllesmereUI.SOUND_ICON_ATLAS)
                        local function HasSound()
                            local g, l = b.buffActiveSoundKey, b.buffLostSoundKey
                            return (g and g ~= "none") or (l and l ~= "none")
                        end
                        local function RestAlpha() return HasSound() and 0.8 or 0.3 end
                        item._sndPaint = function()
                            if not sndBtn:IsMouseOver() then sndBtn:SetAlpha(RestAlpha()) end
                        end
                        sndBtn:SetAlpha(RestAlpha())
                        sndBtn:SetScript("OnEnter", function(self)
                            self:SetAlpha(1); iLbl:SetTextColor(1,1,1,1); iHl:SetAlpha(hlA)
                            EllesmereUI.ShowWidgetTooltip(self, HasSound() and EllesmereUI.L("Edit Audio Effect") or EllesmereUI.L("Add Audio Effect"))
                        end)
                        sndBtn:SetScript("OnLeave", function(self)
                            EllesmereUI.HideWidgetTooltip()
                            self:SetAlpha(RestAlpha())
                            if item:IsMouseOver() then return end
                            iLbl:SetTextColor(tDimR,tDimG,tDimB,tDimA); iHl:SetAlpha(idx == _tbbSelectedBar and selA or 0)
                        end)
                        -- The bar menu stays open underneath, as with the row right-click.
                        sndBtn:SetScript("OnClick", function() OpenBarSoundMenu(idx, item) end)
                        iLbl:SetPoint("RIGHT", sndBtn, "LEFT", -4, 0)
                    end

                    delBtn:SetScript("OnEnter", function() delBtn:SetAlpha(1); iLbl:SetTextColor(1,1,1,1); iHl:SetAlpha(hlA) end)
                    delBtn:SetScript("OnLeave", function()
                        if item:IsMouseOver() then return end
                        delBtn:SetAlpha(0.75); iLbl:SetTextColor(tDimR,tDimG,tDimB,tDimA); iHl:SetAlpha(idx == _tbbSelectedBar and selA or 0)
                    end)
                    delBtn:SetScript("OnClick", function()
                        menu:Hide()
                        EllesmereUI:ShowConfirmPopup({
                            title = "Delete Bar",
                            message = EllesmereUI.Lf("Delete \"%1$s\"?", displayName),
                            confirmText = "Delete", cancelText = "Cancel",
                            onConfirm = function()
                                ns.RemoveTrackedBuffBar(idx)
                                EllesmereUI:RefreshPage(true)
                            end,
                        })
                    end)

                    item:SetScript("OnEnter", function() iLbl:SetTextColor(1,1,1,1); iHl:SetAlpha(hlA); delBtn:SetAlpha(1) end)
                    item:SetScript("OnLeave", function() iLbl:SetTextColor(tDimR,tDimG,tDimB,tDimA); iHl:SetAlpha(idx == _tbbSelectedBar and selA or 0); delBtn:SetAlpha(0.75) end)
                    item:RegisterForClicks("LeftButtonUp", "RightButtonUp")
                    item:SetScript("OnClick", function(_, mouseButton)
                        if mouseButton == "RightButton" then
                            if not soundable then return end
                            -- The bar menu stays open underneath, like the CDM icon menu.
                            OpenBarSoundMenu(idx, item)
                            return
                        end
                        menu:Hide()
                        if unassigned then
                            -- No buff yet: go straight to the buff picker.
                            OpenBuffPickerForBar(idx)
                        else
                            _tbbSelectedBar = idx
                            _tbbSelectedGroup = nil
                            EllesmereUI:RefreshPage(true)
                        end
                    end)

                    -- Drag to move between groups (drop handled by zone under the cursor at release).
                    item:RegisterForDrag("LeftButton")
                    item:SetScript("OnDragStart", function()
                        menu._dragActive = true
                        dragState.idx = idx
                        dragState.name = displayName
                        local g = EnsureGhost()
                        g._lbl:SetText(displayName)
                        g._lbl:SetTextColor(1, 1, 1, 0.8)
                        g:Show()
                        g:SetScript("OnUpdate", GhostUpdate)
                    end)
                    item:SetScript("OnDragStop", function()
                        local moveIdx = dragState.idx
                        local z = HoveredZone()
                        StopDrag()
                        if moveIdx and z then
                            MoveBarToGroup(moveIdx, z.gid)
                        end
                    end)
                    mH = mH + ITEM_H
                    return item
                end

                local function AddActionItem(text, indent, onClick)
                    local item = CreateFrame("Button", nil, inner)
                    item:SetHeight(ITEM_H)
                    item:SetPoint("TOPLEFT", inner, "TOPLEFT", 1, -mH)
                    item:SetPoint("TOPRIGHT", inner, "TOPRIGHT", -1, -mH)
                    item:SetFrameLevel(menu:GetFrameLevel() + 2)
                    local lbl = item:CreateFontString(nil, "OVERLAY")
                    lbl:SetFont(FONT_PATH, 11, GetCDMOptOutline())
                    lbl:SetPoint("LEFT", item, "LEFT", 10 + (indent or 0), 0)
                    lbl:SetJustifyH("LEFT")
                    lbl:SetText(text)
                    lbl:SetTextColor(ar, ag, ab, 0.85)
                    local hl = item:CreateTexture(nil, "ARTWORK")
                    hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 1); hl:SetAlpha(0)
                    item:SetScript("OnEnter", function() lbl:SetTextColor(1,1,1,1); hl:SetAlpha(hlA) end)
                    item:SetScript("OnLeave", function() lbl:SetTextColor(ar, ag, ab, 0.85); hl:SetAlpha(0) end)
                    item:SetScript("OnClick", onClick)
                    mH = mH + ITEM_H
                    return item
                end

                -- A freshly created bar has no buff yet: select it and open the buff picker right away so add-and-assign is one flow.
                local function SelectNewBar(newIdx)
                    menu:Hide()
                    OpenBuffPickerForBar(newIdx)
                end

                -- Grouped bars, one section per group (each section doubles as a drop zone for bar drags).
                local gids = ns.TBBGroupIDsInUse and ns.TBBGroupIDsInUse() or {}
                local renderedGlobal = {}
                for _, gid in ipairs(gids) do
                    local gkey = ns.TBBGroupGlobalKey and ns.TBBGroupGlobalKey(gid) or nil
                    if gkey then renderedGlobal[gkey] = true end
                    local zone = {
                        gid = gid,
                        label = (ns.TBBGroupName and ns.TBBGroupName(gid))
                            or (EllesmereUI.L("Group") .. " " .. gid),
                        frames = {},
                    }
                    dropZones[#dropZones + 1] = zone
                    zone.frames[#zone.frames + 1] = AddGroupHeaderRow(gid, gkey)
                    for idx, b in ipairs(t.bars) do
                        if ns.TBBBarGroupID(b) == gid then
                            zone.frames[#zone.frames + 1] = AddBarItem(idx, b, 8)
                        end
                    end
                    zone.frames[#zone.frames + 1] = AddActionItem(EllesmereUI.L("+ Add Bar to Group"), 8, function()
                        SelectNewBar(ns.AddTrackedBuffBar(gid))
                    end)
                end

                -- Global groups with no bars on this spec are always listed so any spec can
                -- assign/drag bars into them; selecting one edits its shared settings (a normal drop zone).
                if ns.TBBGlobalGroupKeys then
                    for _, gkey in ipairs(ns.TBBGlobalGroupKeys()) do
                        if not renderedGlobal[gkey] then
                            local lgid = ns.TBBEnsureLocalGroupForGlobal(gkey)
                            if lgid then
                                local zone = {
                                    gid = lgid,
                                    label = (ns.TBBGroupName and ns.TBBGroupName(lgid))
                                        or (EllesmereUI.L("Group") .. " " .. lgid),
                                    frames = {},
                                }
                                dropZones[#dropZones + 1] = zone
                                zone.frames[#zone.frames + 1] = AddGroupHeaderRow(lgid, gkey)
                                zone.frames[#zone.frames + 1] = AddActionItem(EllesmereUI.L("+ Add Bar to Group"), 8, function()
                                    SelectNewBar(ns.AddTrackedBuffBar(lgid))
                                end)
                            end
                        end
                    end
                end

                -- Independent bars (the section is the "make independent" zone)
                local indepZone = { gid = 0, label = EllesmereUI.L("Independent"), frames = {} }
                dropZones[#dropZones + 1] = indepZone
                local anyIndependent = false
                for _, b in ipairs(t.bars) do
                    if ns.TBBBarGroupID(b) == 0 then anyIndependent = true; break end
                end
                if anyIndependent then
                    AddHeaderRow(EllesmereUI.L("INDEPENDENT BARS"))
                    for idx, b in ipairs(t.bars) do
                        if ns.TBBBarGroupID(b) == 0 then
                            indepZone.frames[#indepZone.frames + 1] = AddBarItem(idx, b, 8)
                        end
                    end
                end

                -- Divider + creation actions
                local div = inner:CreateTexture(nil, "ARTWORK")
                div:SetHeight(1); div:SetColorTexture(1, 1, 1, 0.10)
                div:SetPoint("TOPLEFT", inner, "TOPLEFT", 1, -mH - 4)
                div:SetPoint("TOPRIGHT", inner, "TOPRIGHT", -1, -mH - 4)
                mH = mH + 9

                AddActionItem(EllesmereUI.L("+ Add New Group"), 0, function()
                    local gid = ns.TBBNextGroupID()
                    if ns.TBBResetGroupSettings then ns.TBBResetGroupSettings(gid) end
                    SelectNewBar(ns.AddTrackedBuffBar(gid))
                end)
                indepZone.frames[#indepZone.frames + 1] = AddActionItem(EllesmereUI.L("+ Add Independent Bar"), 0, function()
                    SelectNewBar(ns.AddTrackedBuffBar(0))
                end)

                if #t.bars > 1 then
                    local dragHint = inner:CreateFontString(nil, "OVERLAY")
                    dragHint:SetFont(FONT_PATH, 10, GetCDMOptOutline())
                    dragHint:SetTextColor(1, 1, 1, 0.35)
                    dragHint:SetPoint("TOP", inner, "TOP", 0, -mH - 4)
                    dragHint:SetText(EllesmereUI.L("Drag a bar to move it into another group"))
                    mH = mH + 20
                end
                -- Discoverability for the row right-click (Audio on Buff Gain/Loss): shown
                -- while any bar can take a sound.
                local anySoundable = false
                for _, b in ipairs(t.bars) do
                    if BarTakesSound(b) then anySoundable = true; break end
                end
                if anySoundable then
                    local soundHint = inner:CreateFontString(nil, "OVERLAY")
                    soundHint:SetFont(FONT_PATH, 10, GetCDMOptOutline())
                    soundHint:SetTextColor(1, 1, 1, 0.35)
                    soundHint:SetPoint("TOP", inner, "TOP", 0, -mH - 4)
                    soundHint:SetText(EllesmereUI.L("Right-click a bar to set its sounds"))
                    mH = mH + 20
                end

                local totalH = mH + 4
                inner:SetHeight(totalH)
                if totalH > MENU_MAX_H then
                    menu:SetHeight(MENU_MAX_H)
                    local sf = CreateFrame("ScrollFrame", nil, menu)
                    sf:SetPoint("TOPLEFT"); sf:SetPoint("BOTTOMRIGHT")
                    sf:SetFrameLevel(menu:GetFrameLevel() + 1)
                    sf:EnableMouseWheel(true)
                    sf:SetScrollChild(inner)
                    local scrollPos = 0
                    local maxScroll = totalH - MENU_MAX_H
                    sf:SetScript("OnMouseWheel", function(_, delta)
                        scrollPos = math.max(0, math.min(maxScroll, scrollPos - delta * 30))
                        sf:SetVerticalScroll(scrollPos)
                    end)
                else
                    menu:SetHeight(totalH)
                end
                menu:SetScript("OnUpdate", function(m)
                    -- Never dismiss mid-drag: dragging naturally leaves the menu bounds with the button held down.
                    if m._dragActive then return end
                    -- A click in the row's sound menu or its flyouts is not a click outside.
                    local snd = ddBtn._tbbSndMenu
                    if snd and snd:IsShown() and snd._overAny and snd._overAny() then return end
                    if not m:IsMouseOver() and not ddBtn:IsMouseOver() and IsMouseButtonDown("LeftButton") then
                        m:Hide()
                    end
                end)
                menu:HookScript("OnHide", function(m)
                    m:SetScript("OnUpdate", nil)
                    if ddBtn._tbbSndMenu then ddBtn._tbbSndMenu:Hide() end
                end)
                -- A no-op unless the menu sits on the controller-cursor overlay layer.
                EllesmereUI.TrackOverlay(menu)
                menu:Show()
                ddMenu = menu
            end

            ddBtn:SetScript("OnEnter", function() ddLbl:SetAlpha(mTxtHA); ddBrd:SetColor(1,1,1,mBrdHA); ddBg:SetColorTexture(mBgR,mBgG,mBgB,mBgHA) end)
            ddBtn:SetScript("OnLeave", function()
                if ddMenu and ddMenu:IsShown() then return end
                ddLbl:SetAlpha(mTxtA); ddBrd:SetColor(1,1,1,mBrdA); ddBg:SetColorTexture(mBgR,mBgG,mBgB,mBgA)
            end)
            ddBtn:SetScript("OnClick", function()
                -- An open buff picker (e.g. from "+ Add Bar to Group") yields to the management menu.
                if _tbbSpellPickerMenu and _tbbSpellPickerMenu:IsShown() then
                    _tbbSpellPickerMenu:Hide()
                end
                if ddMenu and ddMenu:IsShown() then ddMenu:Hide() else BuildDDMenu() end
            end)
            ddBtn:HookScript("OnHide", function()
                if ddMenu then ddMenu:Hide() end
                if ddBtn._tbbSndMenu then ddBtn._tbbSndMenu:Hide() end
            end)

            -- Keep the label current when settings refresh in place (e.g. a group rename commits without a full page rebuild).
            EllesmereUI.RegisterWidgetRefresh(UpdateDDLabel)

            _tbbDDBtn = ddBtn
            return ddBtn
        end

        -- No content header: preview lives in the popout panel docked to the left of the
        -- options window (RefreshTBBPopout); wire its click-to-scroll overlays to this build's rows.
        EllesmereUI:ClearContentHeader()
        _tbbNavigateFn = NavigateToSetting

        -------------------------------------------------------------------
        --  ACTION CARDS + PRESET STYLE (top of scrollable settings; shown in both bar and group mode)
        -------------------------------------------------------------------
        do
            -- The third card broadcasts the selected bar to every other spec, then flips to
            -- "Remove Bar from All Specs" (the inverse); dimmed unless a preset/custom-buff bar is selected.
            local _selForBroadcast = (not _tbbSelectedGroup) and SelectedTBB() or nil
            local _canBroadcast = ns.IsTrackedBuffBarBroadcastable
                and ns.IsTrackedBuffBarBroadcastable(_selForBroadcast) or false
            -- WoW Forever: the class runs on one spec, so there is nowhere to copy to.
            if EllesmereUI.IS_FOREVER then _canBroadcast = false end
            local _isBroadcast = _canBroadcast
                and ns.IsTrackedBuffBarBroadcast
                and ns.IsTrackedBuffBarBroadcast(_selForBroadcast) or false
            local _broadcastLabel = _isBroadcast and "Remove Bar from All Specs"
                                                  or "Add Bar to All Specs"
            local EGc = EllesmereUI.ELLESMERE_GREEN
            local PADc = EllesmereUI.CONTENT_PAD or 10
            local CARD_H, CARD_GAP, CARD_ICON = 60, 12, 24
            local cardTotalW = parent:GetWidth() - PADc * 2
            local CARD_W = math.floor((cardTotalW - CARD_GAP * 2) / 3)
            y = y - 10
            local cardRow = CreateFrame("Frame", nil, parent)
            PP.Size(cardRow, cardTotalW, CARD_H)
            PP.Point(cardRow, "TOPLEFT", parent, "TOPLEFT", PADc, y)

            local function MakeActionCard(xOff, iconPath, cardTitle, cardDesc, onClick, disabledTip)
                local card = CreateFrame("Button", nil, cardRow)
                PP.Size(card, CARD_W, CARD_H)
                PP.Point(card, "TOPLEFT", cardRow, "TOPLEFT", xOff, 0)
                card:SetFrameLevel(cardRow:GetFrameLevel() + 2)

                local cbg = card:CreateTexture(nil, "BACKGROUND")
                cbg:SetAllPoints()
                cbg:SetColorTexture(0.06, 0.08, 0.10, 0.50)
                local cbrd = EllesmereUI.MakeBorder(card, 1, 1, 1, 0.12, PP)

                -- Accent top edge
                local accentLine = card:CreateTexture(nil, "ARTWORK", nil, 7)
                accentLine:SetColorTexture(EGc.r, EGc.g, EGc.b, 0.6)
                PP.Point(accentLine, "TOPLEFT", card, "TOPLEFT", 1, -1)
                PP.Point(accentLine, "TOPRIGHT", card, "TOPRIGHT", -1, -1)
                accentLine:SetHeight(2)
                if accentLine.SetSnapToPixelGrid then accentLine:SetSnapToPixelGrid(false); accentLine:SetTexelSnappingBias(0) end

                local cIcon = card:CreateTexture(nil, "ARTWORK")
                cIcon:SetSize(CARD_ICON, CARD_ICON)
                PP.Point(cIcon, "LEFT", card, "LEFT", 18, 0)
                cIcon:SetTexture(iconPath)
                cIcon:SetVertexColor(EGc.r, EGc.g, EGc.b)
                cIcon:SetAlpha(0.6)
                if cIcon.SetSnapToPixelGrid then cIcon:SetSnapToPixelGrid(false); cIcon:SetTexelSnappingBias(0) end

                local titleFs = EllesmereUI.MakeFont(card, 12, nil, 1, 1, 1, 0.9)
                PP.Point(titleFs, "TOPLEFT", cIcon, "TOPRIGHT", 14, 1)
                PP.Point(titleFs, "RIGHT", card, "RIGHT", -10, 0)
                titleFs:SetJustifyH("LEFT")
                titleFs:SetWordWrap(false)
                titleFs:SetText(EllesmereUI.L(cardTitle))

                local descFs = EllesmereUI.MakeFont(card, 10, nil, 1, 1, 1, 0.35)
                PP.Point(descFs, "TOPLEFT", titleFs, "BOTTOMLEFT", 0, -4)
                PP.Point(descFs, "RIGHT", card, "RIGHT", -10, 0)
                descFs:SetJustifyH("LEFT")
                descFs:SetWordWrap(false)
                descFs:SetText(EllesmereUI.L(cardDesc))

                if disabledTip then
                    card:SetAlpha(0.45)
                    card:SetScript("OnEnter", function()
                        EllesmereUI.ShowWidgetTooltip(card, disabledTip)
                    end)
                    card:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
                else
                    card:SetScript("OnEnter", function()
                        cbg:SetColorTexture(0.11, 0.13, 0.15, 0.50)
                        cbrd:SetColor(1, 1, 1, 0.22)
                        titleFs:SetAlpha(1)
                        cIcon:SetAlpha(0.85)
                    end)
                    card:SetScript("OnLeave", function()
                        cbg:SetColorTexture(0.06, 0.08, 0.10, 0.50)
                        cbrd:SetColor(1, 1, 1, 0.12)
                        titleFs:SetAlpha(0.9)
                        cIcon:SetAlpha(0.6)
                    end)
                    card:SetScript("OnClick", onClick)
                end
                return card
            end

            local MEDIA_ICONS = "Interface\\AddOns\\EllesmereUI\\media\\icons\\"
            MakeActionCard(0, MEDIA_ICONS .. "power.png",
                "Use Blizzard CDM Bars", "Switch back to Blizzard's bars.", function()
                    EllesmereUI:ShowConfirmPopup({
                        title = "Use Blizzard Bars",
                        message = "This will disable EllesmereUI Tracking Bars and show Blizzard's default Tracked Bars display instead.",
                        confirmText = "Switch & Reload",
                        cancelText = "Cancel",
                        reload = true,
                        onConfirm = function()
                            local p = DB()
                            if p and p.cdmBars then
                                p.cdmBars.useBlizzardBuffBars = true
                            end
                        end,
                    })
                end)
            MakeActionCard(CARD_W + CARD_GAP, MEDIA_ICONS .. "eui-open.png",
                "Open Blizzard CDM", "Manage your tracked bars.", function()
                    if ns.OpenBlizzardCDMTab then
                        ns.OpenBlizzardCDMTab(true)
                    end
                end)
            MakeActionCard((CARD_W + CARD_GAP) * 2, MEDIA_ICONS .. "sync.png",
                _broadcastLabel, "Copy this bar to every spec.", function()
                    local sel = SelectedTBB()
                    if _tbbSelectedGroup or not ns.IsTrackedBuffBarBroadcastable(sel) then return end
                    local nm = sel.name or "Bar"
                    if (not sel.popularKey or sel.popularKey == "") and sel.spellID and sel.spellID > 0 then
                        local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(sel.spellID)
                        if info and info.name then nm = info.name end
                    end
                    if ns.IsTrackedBuffBarBroadcast and ns.IsTrackedBuffBarBroadcast(sel) then
                        EllesmereUI:ShowConfirmPopup({
                            title = "Remove Bar from All Specs",
                            message = EllesmereUI.Lf("Remove \"%1$s\" from every other spec? The bar in this spec is kept.", nm),
                            confirmText = "Remove from All",
                            cancelText = "Cancel",
                            onConfirm = function()
                                if ns.RemoveBarFromAllSpecs then ns.RemoveBarFromAllSpecs(_tbbSelectedBar) end
                                EllesmereUI:RefreshPage(true)
                            end,
                        })
                    else
                        EllesmereUI:ShowConfirmPopup({
                            title = "Add Bar to All Specs",
                            message = EllesmereUI.Lf("Add \"%1$s\" to every spec? It will be copied to each of your specs that doesn't already have it.", nm),
                            confirmText = "Add to All Specs",
                            cancelText = "Cancel",
                            onConfirm = function()
                                if ns.AddBarToAllSpecs then ns.AddBarToAllSpecs(_tbbSelectedBar) end
                                EllesmereUI:RefreshPage(true)
                            end,
                        })
                    end
                end,
                (not _canBroadcast) and ((EllesmereUI.IS_FOREVER
                    and "WoW Forever has no other specs to copy this bar to")
                    or (_tbbSelectedGroup
                    and "Select a bar to broadcast it to other specs"
                    or "Only preset or custom buff bars can be added to all specs")) or nil)
            y = y - CARD_H - 12

            -- Preset Style panel (styled like Profiles & Presets "Active Profile"): pick a
            -- saved style preset and apply it to the selected bar/group, or save the current
            -- style as one. Presets are profile-wide; new bars resolve one by association at creation.
            local _wc = EllesmereUI.WB_COLOURS
            local PROF_BTN_COLOURS = {
                _wc[1],  _wc[2],  _wc[3],  _wc[4],   _wc[5],  _wc[6],  _wc[7],  _wc[8],
                1, 1, 1, EllesmereUI.DD_BRD_A,   1, 1, 1, EllesmereUI.DD_BRD_HA or 0.30,
                _wc[17], _wc[18], _wc[19], _wc[20],  _wc[21], _wc[22], _wc[23], _wc[24],
            }
            local LABEL_H  = 16
            local CTRL_H   = 30
            local PAD_X    = 24
            local PAD_Y    = 20
            local GAP_DD   = 30
            local GAP_BTN  = 14
            local PR_ROW_H = PAD_Y + LABEL_H + 4 + CTRL_H + PAD_Y

            local innerW = cardTotalW - PAD_X * 2
            local DD_W   = math.floor(innerW * 0.30)
            local BTN_W  = math.floor((innerW - DD_W - GAP_DD - GAP_BTN * 2) / 3)

            local prRow = CreateFrame("Frame", nil, parent)
            PP.Size(prRow, cardTotalW, PR_ROW_H)
            PP.Point(prRow, "TOPLEFT", parent, "TOPLEFT", PADc, y)

            local prBg = prRow:CreateTexture(nil, "BACKGROUND")
            prBg:SetAllPoints()
            prBg:SetColorTexture(0.06, 0.08, 0.10, 0.50)
            EllesmereUI.MakeBorder(prRow, 1, 1, 1, 0.10, PP)

            -- "Preset Style" label (accent, matching "Active Profile")
            local prLbl = EllesmereUI.MakeFont(prRow, 12, nil, EGc.r, EGc.g, EGc.b, 0.7)
            PP.Point(prLbl, "TOPLEFT", prRow, "TOPLEFT", PAD_X, -PAD_Y)
            prLbl:SetText(EllesmereUI.L("Preset Style"))
            prLbl:SetJustifyH("LEFT")

            -- Live reads: label/menu/apply buttons all pull from the current preset list so saves/renames/deletes never go stale.
            local function SelectedPresetName()
                local p = DB()
                local sel = p and p.tbbSelectedStylePreset
                if sel and ns.FindTBBStylePreset and ns.FindTBBStylePreset(sel) then
                    return sel
                end
                local presets = ns.GetTBBStylePresets and ns.GetTBBStylePresets()
                return presets and presets[1] and presets[1].name or nil
            end
            local function SelectedPreset()
                local nm = SelectedPresetName()
                if not nm then return nil end
                return ns.FindTBBStylePreset and ns.FindTBBStylePreset(nm)
            end

            -- Preset dropdown: bespoke button + menu (same look as the standard control) so
            -- each row carries inline rename/delete buttons, matching the "Active Profile" dropdown.
            local aS = EllesmereUI.RD_DD_COLOURS
            local prDD = CreateFrame("Button", nil, prRow)
            PP.Size(prDD, DD_W, CTRL_H)
            prDD:SetFrameLevel(prRow:GetFrameLevel() + 2)
            local prDDBg = prDD:CreateTexture(nil, "BACKGROUND")
            prDDBg:SetAllPoints()
            prDDBg:SetColorTexture(EllesmereUI.DD_BG_R, EllesmereUI.DD_BG_G, EllesmereUI.DD_BG_B, EllesmereUI.DD_BG_A)
            local prDDBrd = EllesmereUI.MakeBorder(prDD, 1, 1, 1, EllesmereUI.DD_BRD_A, PP)
            local prDDLbl = EllesmereUI.MakeFont(prDD, 13, nil, 1, 1, 1)
            prDDLbl:SetAlpha(EllesmereUI.DD_TXT_A)
            prDDLbl:SetJustifyH("LEFT")
            prDDLbl:SetWordWrap(false)
            prDDLbl:SetMaxLines(1)
            prDDLbl:SetPoint("LEFT", prDD, "LEFT", 12, 0)
            local prArrow = EllesmereUI.MakeDropdownArrow(prDD, 12, PP)
            prDDLbl:SetPoint("RIGHT", prArrow, "LEFT", -5, 0)
            PP.Point(prDD, "TOPLEFT", prLbl, "BOTTOMLEFT", 0, -6)
            local function UpdatePrDDLabel()
                prDDLbl:SetText(SelectedPresetName() or EllesmereUI.L("No Saved Presets"))
            end
            UpdatePrDDLabel()

            local prMenu = CreateFrame("Frame", nil, UIParent)
            prMenu:SetFrameStrata("FULLSCREEN_DIALOG")
            prMenu:SetFrameLevel(200)
            prMenu:SetClampedToScreen(true)
            prMenu:SetSize(DD_W, 4)
            prMenu:SetPoint("TOPLEFT", prDD, "BOTTOMLEFT", 0, -2)
            prMenu:Hide()
            local prMenuBg = prMenu:CreateTexture(nil, "BACKGROUND")
            prMenuBg:SetAllPoints()
            prMenuBg:SetColorTexture(EllesmereUI.DD_BG_R, EllesmereUI.DD_BG_G, EllesmereUI.DD_BG_B, 0.98)
            EllesmereUI.MakeBorder(prMenu, 1, 1, 1, EllesmereUI.DD_BRD_A, PP)
            prMenu:SetScript("OnShow", function(self)
                local sc = prDD:GetEffectiveScale() / UIParent:GetEffectiveScale()
                self:SetScale(sc)
                self:SetScript("OnUpdate", function(m)
                    if not prDD:IsMouseOver() and not m:IsMouseOver() then
                        if IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton") then m:Hide() end
                    end
                end)
            end)

            local X_SZ = 14
            local MEDIA_PR = "Interface\\AddOns\\EllesmereUI\\media\\icons\\"
            local prItems = {}

            local function RebuildPresetMenu()
                for _, itm in ipairs(prItems) do itm:Hide() end
                local presets = (ns.GetTBBStylePresets and ns.GetTBBStylePresets()) or {}
                local selName = SelectedPresetName()
                local mH = 4
                for i = 1, math.max(#presets, 1) do
                    local itm = prItems[i]
                    if not itm then
                        itm = CreateFrame("Button", nil, prMenu)
                        itm:SetHeight(26)
                        itm:SetFrameLevel(prMenu:GetFrameLevel() + 1)

                        local lbl = itm:CreateFontString(nil, "OVERLAY")
                        lbl:SetFont(FONT_PATH, 13, GetCDMOptOutline())
                        lbl:SetPoint("LEFT",  itm, "LEFT",  10, 0)
                        lbl:SetPoint("RIGHT", itm, "RIGHT", -(X_SZ * 2 + 26), 0)
                        lbl:SetJustifyH("LEFT")
                        lbl:SetWordWrap(false)
                        lbl:SetMaxLines(1)
                        lbl:SetTextColor(1, 1, 1, EllesmereUI.TEXT_DIM_A)
                        itm._lbl = lbl

                        local hl = itm:CreateTexture(nil, "ARTWORK")
                        hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 1); hl:SetAlpha(0)
                        itm._hl = hl

                        local xBtn = CreateFrame("Button", nil, itm)
                        xBtn:SetSize(X_SZ, X_SZ)
                        xBtn:SetPoint("RIGHT", itm, "RIGHT", -8, 0)
                        xBtn:SetFrameLevel(itm:GetFrameLevel() + 2)
                        local xIcon = xBtn:CreateTexture(nil, "OVERLAY")
                        xIcon:SetAllPoints()
                        if xIcon.SetSnapToPixelGrid then xIcon:SetSnapToPixelGrid(false); xIcon:SetTexelSnappingBias(0) end
                        xIcon:SetTexture(MEDIA_PR .. "eui-close.png")
                        xBtn:SetAlpha(0.4)
                        itm._xBtn = xBtn

                        local editBtn = CreateFrame("Button", nil, itm)
                        editBtn:SetSize(X_SZ, X_SZ)
                        editBtn:SetPoint("RIGHT", xBtn, "LEFT", -4, 0)
                        editBtn:SetFrameLevel(itm:GetFrameLevel() + 2)
                        local editIcon = editBtn:CreateTexture(nil, "OVERLAY")
                        editIcon:SetAllPoints()
                        if editIcon.SetSnapToPixelGrid then editIcon:SetSnapToPixelGrid(false); editIcon:SetTexelSnappingBias(0) end
                        editIcon:SetTexture(MEDIA_PR .. "eui-edit.png")
                        editBtn:SetAlpha(0.4)
                        itm._editBtn = editBtn

                        local function IsOverInlineBtn()
                            return xBtn:IsMouseOver() or editBtn:IsMouseOver()
                        end
                        local function SetAllInlineAlpha(a)
                            xBtn:SetAlpha(a); editBtn:SetAlpha(a)
                        end

                        itm:SetScript("OnEnter", function()
                            if itm._isEmpty then return end
                            lbl:SetTextColor(1, 1, 1, 1)
                            hl:SetAlpha(EllesmereUI.DD_ITEM_HL_A)
                            SetAllInlineAlpha(0.8)
                        end)
                        itm:SetScript("OnLeave", function()
                            if itm._isEmpty then return end
                            if IsOverInlineBtn() then return end
                            lbl:SetTextColor(1, 1, 1, EllesmereUI.TEXT_DIM_A)
                            hl:SetAlpha(itm._isSel and EllesmereUI.DD_ITEM_SEL_A or 0)
                            SetAllInlineAlpha(0.4)
                        end)

                        local function InlineBtnEnter(self)
                            lbl:SetTextColor(1, 1, 1, 1)
                            hl:SetAlpha(EllesmereUI.DD_ITEM_HL_A)
                            SetAllInlineAlpha(0.8)
                            self:SetAlpha(1)
                        end
                        local function InlineBtnLeave(hoveredSelf)
                            if itm:IsMouseOver() or IsOverInlineBtn() then
                                hoveredSelf:SetAlpha(0.8)
                                return
                            end
                            lbl:SetTextColor(1, 1, 1, EllesmereUI.TEXT_DIM_A)
                            hl:SetAlpha(itm._isSel and EllesmereUI.DD_ITEM_SEL_A or 0)
                            SetAllInlineAlpha(0.4)
                        end

                        xBtn:SetScript("OnEnter", function(self)
                            InlineBtnEnter(self)
                            EllesmereUI.ShowWidgetTooltip(self, EllesmereUI.L("Delete"))
                        end)
                        xBtn:SetScript("OnLeave", function(self)
                            InlineBtnLeave(self)
                            EllesmereUI.HideWidgetTooltip()
                        end)
                        editBtn:SetScript("OnEnter", function(self)
                            InlineBtnEnter(self)
                            EllesmereUI.ShowWidgetTooltip(self, EllesmereUI.L("Rename"))
                        end)
                        editBtn:SetScript("OnLeave", function(self)
                            InlineBtnLeave(self)
                            EllesmereUI.HideWidgetTooltip()
                        end)
                        prItems[i] = itm
                    end

                    itm:SetPoint("TOPLEFT",  prMenu, "TOPLEFT",  1, -mH)
                    itm:SetPoint("TOPRIGHT", prMenu, "TOPRIGHT", -1, -mH)

                    local pr = presets[i]
                    if not pr then
                        -- Empty state: a single dim, non-interactive row
                        itm._isEmpty = true
                        itm._isSel = false
                        itm._lbl:SetText(EllesmereUI.L("No Saved Presets"))
                        itm._lbl:SetTextColor(1, 1, 1, 0.35)
                        itm._hl:SetAlpha(0)
                        itm._xBtn:Hide()
                        itm._editBtn:Hide()
                        itm:SetScript("OnClick", function() prMenu:Hide() end)
                    else
                        local capName = pr.name
                        itm._isEmpty = false
                        itm._lbl:SetText(capName)
                        itm._lbl:SetTextColor(1, 1, 1, EllesmereUI.TEXT_DIM_A)
                        itm._isSel = (capName == selName)
                        itm._hl:SetAlpha(itm._isSel and EllesmereUI.DD_ITEM_SEL_A or 0)
                        itm._xBtn:Show()
                        itm._xBtn:SetAlpha(0.4)
                        itm._editBtn:Show()
                        itm._editBtn:SetAlpha(0.4)
                        itm:SetScript("OnClick", function()
                            prMenu:Hide()
                            local p = DB()
                            if p then p.tbbSelectedStylePreset = capName end
                            UpdatePrDDLabel()
                        end)
                        itm._xBtn:SetScript("OnClick", function()
                            prMenu:Hide()
                            EllesmereUI:ShowConfirmPopup({
                                title       = EllesmereUI.L("Delete Preset"),
                                message     = EllesmereUI.Lf("Delete \"%1$s\"?", capName),
                                confirmText = EllesmereUI.L("Delete"),
                                cancelText  = EllesmereUI.L("Cancel"),
                                onConfirm   = function()
                                    if ns.DeleteTBBStylePreset then ns.DeleteTBBStylePreset(capName) end
                                    EllesmereUI:RefreshPage(true)
                                end,
                            })
                        end)
                        itm._editBtn:SetScript("OnClick", function()
                            prMenu:Hide()
                            EllesmereUI:ShowInputPopup({
                                title       = EllesmereUI.L("Rename Preset"),
                                message     = EllesmereUI.Lf("Enter a new name for \"%1$s\":", capName),
                                placeholder = capName,
                                confirmText = EllesmereUI.L("Rename"),
                                cancelText  = EllesmereUI.L("Cancel"),
                                onConfirm   = function(newName)
                                    newName = newName and strtrim(newName) or ""
                                    if newName == "" or newName == capName then return end
                                    if ns.FindTBBStylePreset and ns.FindTBBStylePreset(newName) then
                                        print(EllesmereUI.Lf("|cffff6060[EllesmereUI]|r A preset named \"%1$s\" already exists.", newName))
                                        return
                                    end
                                    if ns.RenameTBBStylePreset then ns.RenameTBBStylePreset(capName, newName) end
                                    EllesmereUI:RefreshPage(true)
                                end,
                            })
                        end)
                    end

                    itm:Show()
                    mH = mH + 26
                end
                prMenu:SetHeight(mH + 4)
            end

            local function PrApplyNormal()
                prDDLbl:SetTextColor(aS[17], aS[18], aS[19], aS[20])
                prDDBrd:SetColor(aS[9], aS[10], aS[11], aS[12])
                prDDBg:SetColorTexture(aS[1], aS[2], aS[3], aS[4])
            end
            local function PrApplyHover()
                prDDLbl:SetTextColor(aS[21], aS[22], aS[23], aS[24])
                prDDBrd:SetColor(aS[13], aS[14], aS[15], aS[16])
                prDDBg:SetColorTexture(aS[5], aS[6], aS[7], aS[8])
            end
            prDD:SetScript("OnClick", function()
                if prMenu:IsShown() then prMenu:Hide()
                else RebuildPresetMenu(); prMenu:Show() end
            end)
            prDD:SetScript("OnEnter", function() PrApplyHover() end)
            prDD:SetScript("OnLeave", function()
                if not prMenu:IsShown() then PrApplyNormal() end
            end)
            prDD:HookScript("OnHide", function() prMenu:Hide() end)
            prMenu:HookScript("OnShow", function() PrApplyHover() end)
            prMenu:SetScript("OnHide", function(self)
                self:SetScript("OnUpdate", nil)
                if prDD:IsMouseOver() then PrApplyHover()
                else PrApplyNormal() end
            end)

            -- Buttons with dim labels above, matching the profile row's "Assign to Spec" / "New Profile" columns.
            local function PresetBtn(labelText, btnText, xOff, tooltip, onClick)
                local lab = EllesmereUI.MakeFont(prRow, 12, nil, 1, 1, 1, 0.45)
                PP.Point(lab, "LEFT", prLbl, "LEFT", xOff, 0)
                lab:SetText(EllesmereUI.L(labelText))
                lab:SetJustifyH("LEFT")
                local b = CreateFrame("Button", nil, prRow)
                PP.Size(b, BTN_W, CTRL_H)
                PP.Point(b, "TOPLEFT", lab, "BOTTOMLEFT", 0, -6)
                b:SetFrameLevel(prRow:GetFrameLevel() + 2)
                EllesmereUI.MakeStyledButton(b, btnText, 11, PROF_BTN_COLOURS, onClick)
                b:HookScript("OnEnter", function()
                    EllesmereUI.ShowWidgetTooltip(b, tooltip)
                end)
                b:HookScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
                return b
            end
            local bx = DD_W + GAP_DD
            PresetBtn("Apply to Bar", "Apply to Bar", bx,
                "Apply the selected preset's style to this bar.", function()
                    local pr = SelectedPreset(); if not pr then return end
                    local sel = (not _tbbSelectedGroup) and SelectedTBB() or nil
                    if not sel then return end
                    ns.ApplyTBBStylePresetToCfg(pr, sel)
                    RefreshTBB(); EllesmereUI:RefreshPage()
                end)
            PresetBtn("Apply to Group", "Apply to Group", bx + BTN_W + GAP_BTN,
                "Apply the selected preset's style to every bar in this group.", function()
                    local pr = SelectedPreset(); if not pr then return end
                    local gid = _tbbSelectedGroup
                    if not gid then
                        local sel = SelectedTBB()
                        gid = sel and ns.TBBBarGroupID(sel) or 0
                    end
                    if not gid or gid == 0 then return end
                    local t = ns.GetTrackedBuffBars()
                    for _, c in ipairs(t.bars or {}) do
                        if ns.TBBBarGroupID(c) == gid then
                            ns.ApplyTBBStylePresetToCfg(pr, c)
                        end
                    end
                    RefreshTBB(); EllesmereUI:RefreshPage()
                end)
            PresetBtn("New Preset", "Save New Preset", bx + (BTN_W + GAP_BTN) * 2,
                "Save this bar's current style as a new preset.", function()
                    local src = PreviewCfg()
                    if not src then return end
                    EllesmereUI:ShowInputPopup({
                        title       = EllesmereUI.L("Save Style Preset"),
                        message     = EllesmereUI.L("Enter a name for the new preset:"),
                        placeholder = UniqueTBBPresetName(),
                        confirmText = EllesmereUI.L("Save"),
                        cancelText  = EllesmereUI.L("Cancel"),
                        onConfirm   = function(nm)
                            if not nm or nm == "" then nm = UniqueTBBPresetName() end
                            if ns.SaveTBBStylePreset and ns.SaveTBBStylePreset(nm, src) then
                                local p = DB()
                                if p then p.tbbSelectedStylePreset = nm end
                            end
                            EllesmereUI:RefreshPage(true)
                        end,
                    })
                end)

            y = y - PR_ROW_H - 14

            -- Currently Editing: centered label + the bar/group management dropdown, between the preset panel and the settings sections.
            local ceLbl = EllesmereUI.MakeFont(parent, 12, nil, 1, 1, 1, 0.85)
            PP.Point(ceLbl, "TOP", parent, "TOP", 0, y)
            ceLbl:SetText(EllesmereUI.L("Currently Editing:"))
            ceLbl:SetJustifyH("CENTER")
            y = y - 16 - 6

            local mgmtDD = BuildManagementDropdown(parent)
            PP.Point(mgmtDD, "TOP", parent, "TOP", 0, y)
            y = y - 34 - 14
        end

        -------------------------------------------------------------------
        --  GROUP MODE: only this group's settings, no per-bar sections
        -------------------------------------------------------------------
        if _tbbSelectedGroup then
            local gid = _tbbSelectedGroup
            parent._showRowDivider = true
            parent._tbbClickTargets = nil

            _, h = W:SectionHeader(parent, "GROUP SETTINGS", y);  y = y - h

            -- Grow Direction | Bar Spacing
            _, h = W:DualRow(parent, y,
                { type = "dropdown", text = "Grow Direction",
                  values = { DOWN = "Down", UP = "Up", LEFT = "Left", RIGHT = "Right" },
                  order = { "DOWN", "UP", "LEFT", "RIGHT" },
                  getValue = function() return ns.TBBGroupGrow(gid) end,
                  setValue = function(v)
                      ns.TBBSetGroupGrow(gid, v)
                      ns.BuildTrackedBuffBars()
                      -- Preview popout: RefreshPage() takes the fast path, repaint it here.
                      RefreshTBBPopout()
                      EllesmereUI:RefreshPage()
                  end },
                { type = "slider", pixel = true, text = "Bar Spacing", min = -2, max = 20, step = 1,
                  getValue = function() return ns.TBBGroupSpacing(gid) end,
                  setValue = function(v)
                      ns.TBBSetGroupSpacing(gid, v)
                      ns.BuildTrackedBuffBars()
                      -- Preview popout: RefreshPage() takes the fast path, repaint it here.
                      RefreshTBBPopout()
                      EllesmereUI:RefreshPage()
                  end }
            );  y = y - h

            -- Group Name (blank = the default "Group N" label) | Auto-Add
            _, h = W:DualRow(parent, y,
                { type = "input", text = "Group Name", inputWidth = 160,
                  inputStyle = "popup",
                  placeholder = EllesmereUI.L("Group") .. " " .. gid,
                  tooltip = "Rename this group; leave blank for the default name.",
                  getValue = function()
                      return (ns.TBBGroupName and ns.TBBGroupName(gid)) or ""
                  end,
                  setValue = function(text)
                      if ns.TBBSetGroupName then ns.TBBSetGroupName(gid, text) end
                      RefreshTBB()
                      -- Soft refresh so the "Currently Editing:" dropdown label picks up the new name right away.
                      EllesmereUI:RefreshPage()
                  end },
                { type = "toggle", text = "Auto-Add New to This Group",
                  tooltip = "Automatically add a bar to this group for every spell in Blizzard's Tracked Bars section, now and whenever a new one appears.",
                  getValue = function() return ns.TBBGroupAutoAdd and ns.TBBGroupAutoAdd(gid) or false end,
                  setValue = function(v)
                      if not ns.TBBSetGroupAutoAdd then return end
                      ns.TBBSetGroupAutoAdd(gid, v)
                      if v and ns.PopulateTBBAutoAddGroup then
                          ns.PopulateTBBAutoAddGroup(gid)
                      end
                      ns.BuildTrackedBuffBars()
                      EllesmereUI:RefreshPage(true)
                  end }
            );  y = y - h

            -- Global Group | Shift Elements If No Bars
            local function GlobalEntry()
                local gk = ns.TBBGroupGlobalKey and ns.TBBGroupGlobalKey(gid)
                return gk and ns.TBBGlobalGroup and ns.TBBGlobalGroup(gk) or nil
            end
            local shiftRow
            shiftRow, h = W:DualRow(parent, y,
                { type = "toggle", text = "Global Group",
                  tooltip = "Share this group's name, layout, and position across all specs.",
                  getValue = function()
                      return (ns.TBBGroupGlobalKey and ns.TBBGroupGlobalKey(gid) ~= nil) or false
                  end,
                  setValue = function(v)
                      if not ns.TBBSetGroupGlobal then return end
                      ns.TBBSetGroupGlobal(gid, v)
                      ns.BuildTrackedBuffBars()
                      EllesmereUI:RefreshPage(true)
                  end },
                { type = "dropdown", text = "Shift Elements If No Bars",
                  tooltip = "When the current spec has no bars in this group, keeps elements anchored to the group in place and shifts them up or down by one bar height (tune with the cog's Extra Y Offset) to cover its empty slot.",
                  disabled = function() return GlobalEntry() == nil end,
                  disabledTooltip = "Global Group",
                  values = { None = "None", Up = "Up", Down = "Down" },
                  order = { "None", "Up", "Down" },
                  getValue = function()
                      local e = GlobalEntry()
                      return (e and e.shiftNoBar) or "None"
                  end,
                  setValue = function(v)
                      local e = GlobalEntry()
                      if not e then return end
                      if v == "Up" or v == "Down" then
                          e.shiftNoBar = v
                      else
                          e.shiftNoBar = nil
                      end
                      ns.BuildTrackedBuffBars()
                      EllesmereUI:RefreshPage()
                  end }
            );  y = y - h
            -- Inline reposition cog on the shift dropdown: Extra Y Offset
            -- (ResourceBars "Shift Elements if No Resource" parity).
            if not EllesmereUI._prebuilding then
                local rgn = shiftRow._rightRegion
                EllesmereUI.BuildInlineCog(rgn, {
                    title = "Shift Offset",
                    icon = EllesmereUI.DIRECTIONS_ICON,
                    rows = {
                        { type = "slider", pixel = true, label = "Extra Y Offset", min = -50, max = 50, step = 1,
                          get = function()
                              local e = GlobalEntry()
                              return (e and e.shiftNoBarExtraY) or 0
                          end,
                          set = function(v)
                              local e = GlobalEntry()
                              if not e then return end
                              e.shiftNoBarExtraY = (v ~= 0) and v or nil
                              ns.BuildTrackedBuffBars()
                              -- The build tail's cascade is EDGE-gated on the
                              -- shift direction, which a magnitude edit never
                              -- flips -- re-cascade explicitly so the slider
                              -- applies live (deferred batch coalesces drags).
                              local gk = ns.TBBGroupGlobalKey and ns.TBBGroupGlobalKey(gid)
                              if gk and EllesmereUI.PropagateAnchorChain then
                                  EllesmereUI.PropagateAnchorChain("TBBG_" .. gk)
                              end
                          end },
                    },
                })
            end

            -- Ensure bar frames exist before showing placeholders
            ns.BuildTrackedBuffBars()
            UpdateTBBPlaceholder()
            RefreshTBBPopout()
            return math.abs(y)
        end

        -------------------------------------------------------------------
        --  Scrollable settings (bar mode)
        -------------------------------------------------------------------
        if not SelectedTBB() then
            HideTBBPlaceholder()
            return math.abs(y)
        end

        -- Append SharedMedia textures to runtime ns tables (for bar rendering)
        EllesmereUI.AppendSharedMediaTextures(
            ns.TBB_TEXTURE_NAMES or {},
            ns.TBB_TEXTURE_ORDER or {},
            nil,
            ns.TBB_TEXTURES
        )

        -- Texture dropdown values (built from ns tables, now including SM entries)
        local texValues = {}
        local texOrder = {}
        do
            local names = ns.TBB_TEXTURE_NAMES or {}
            local order = ns.TBB_TEXTURE_ORDER or {}
            local lookup = ns.TBB_TEXTURES or {}
            for _, key in ipairs(order) do
                if key ~= "---" then
                    texValues[key] = names[key] or key
                end
                texOrder[#texOrder + 1] = key
            end
            texValues._menuOpts = {
                itemHeight = 28,
                background = function(key)
                    return lookup[key]
                end,
            }
        end

        parent._showRowDivider = true

        -------------------------------------------------------------------
        --  BAR LAYOUT
        -------------------------------------------------------------------
        local layoutHeader
        layoutHeader, h = W:SectionHeader(parent, "BAR LAYOUT", y);  y = y - h

        -- Height | Width. The whole group shares one width/height, so a grouped member
        -- inherits the group ANCHOR's match-lock: if size-matched, every member's slider
        -- is disabled (match wins) instead of silently fighting it.
        local tbbKey = "TBB_" .. _tbbSelectedBar
        do
            local selBd = SelectedTBB()
            local selGid = selBd and ns.TBBBarGroupID(selBd) or 0
            if selGid ~= 0 then
                local ai = ns.TBBGroupAnchorIndex(selGid)
                if ai then tbbKey = "TBB_" .. ai end
            end
        end
        local thDis, thTip, thRaw = EllesmereUI.MatchGuard(tbbKey, "Height")
        local twDis, twTip, twRaw = EllesmereUI.MatchGuard(tbbKey, "Width")
        -- Width is the THICKNESS of a vertical bar (toggle swaps stored dimensions), so its
        -- floor drops to 1 there -- a 50px floor would clamp a slim vertical bar the moment the slider is touched.
        local selIsVert
        do
            local sb0 = SelectedTBB()
            selIsVert = sb0 and sb0.verticalOrientation and true or false
        end
        local hwRow
        hwRow, h = W:DualRow(parent, y,
            { type = "slider", text = "Height",
              min = 1, max = 800, step = 1,
              disabled = thDis, disabledTooltip = thTip, rawTooltip = thRaw,
              getValue = function() local bd = SelectedTBB(); return bd and bd.height or 24 end,
              setValue = function(v)
                  local bd = SelectedTBB(); if not bd then return end
                  bd.height = v
                  -- Grouped bars share height: write the rest of the group too.
                  local gid = ns.TBBBarGroupID(bd)
                  if gid ~= 0 then
                      local t = ns.GetTrackedBuffBars()
                      for _, b in ipairs(t.bars or {}) do
                          if b ~= bd and ns.TBBBarGroupID(b) == gid then b.height = v end
                      end
                  end
                  ns.BuildTrackedBuffBars()
                  -- BuildTrackedBuffBars() only rebuilds the LIVE bar pool; the
                  -- preview wraps in the popout are separate frames. RefreshPage()
                  -- takes the fast widget-refresh path here, so the page builder
                  -- tail that repaints the popout never re-runs. Repaint it
                  -- directly or the preview keeps the old geometry.
                  RefreshTBBPopout()
                  EllesmereUI:RefreshPage()
              end },
            { type = "slider", text = "Width",
              min = 1, max = 800, step = 1,
              disabled = twDis, disabledTooltip = twTip, rawTooltip = twRaw,
              getValue = function() local bd = SelectedTBB(); return bd and bd.width or 270 end,
              setValue = function(v)
                  local bd = SelectedTBB(); if not bd then return end
                  bd.width = v
                  -- Grouped bars share width: write the rest of the group too.
                  local gid = ns.TBBBarGroupID(bd)
                  if gid ~= 0 then
                      local t = ns.GetTrackedBuffBars()
                      for _, b in ipairs(t.bars or {}) do
                          if b ~= bd and ns.TBBBarGroupID(b) == gid then b.width = v end
                      end
                  end
                  ns.BuildTrackedBuffBars()
                  -- Preview popout: RefreshPage() takes the fast path, repaint it here.
                  RefreshTBBPopout()
                  EllesmereUI:RefreshPage()
              end }
        );  y = y - h

        -- Sync icons: Apply Height/Width to all bars of the SAME orientation -- "height" is
        -- the short side of a horizontal bar but the LONG side of a vertical one, so cross-orientation copies would be nonsense.
        if EllesmereUI.BuildSyncIcon then
            local function SameOrientation(a, b)
                return (a.verticalOrientation and true or false) == (b.verticalOrientation and true or false)
            end
            local orientWord = selIsVert and "Vertical" or "Horizontal"
            EllesmereUI.BuildSyncIcon({
                region = hwRow._leftRegion,
                tooltip = "Apply Height to all " .. orientWord .. " Bars",
                isSynced = function()
                    local bd = SelectedTBB(); if not bd then return false end
                    local val = bd.height or 24
                    local t = ns.GetTrackedBuffBars()
                    for _, b in ipairs(t.bars or {}) do
                        if SameOrientation(bd, b) and (b.height or 24) ~= val then return false end
                    end
                    return true
                end,
                onClick = function()
                    local bd = SelectedTBB(); if not bd then return end
                    local val = bd.height or 24
                    local t = ns.GetTrackedBuffBars()
                    for _, b in ipairs(t.bars or {}) do
                        if SameOrientation(bd, b) then b.height = val end
                    end
                    RefreshTBB(); EllesmereUI:RefreshPage()
                end,
            })
            EllesmereUI.BuildSyncIcon({
                region = hwRow._rightRegion,
                tooltip = "Apply Width to all " .. orientWord .. " Bars",
                isSynced = function()
                    local bd = SelectedTBB(); if not bd then return false end
                    local val = bd.width or 270
                    local t = ns.GetTrackedBuffBars()
                    for _, b in ipairs(t.bars or {}) do
                        if SameOrientation(bd, b) and (b.width or 270) ~= val then return false end
                    end
                    return true
                end,
                onClick = function()
                    local bd = SelectedTBB(); if not bd then return end
                    local val = bd.width or 270
                    local t = ns.GetTrackedBuffBars()
                    for _, b in ipairs(t.bars or {}) do
                        if SameOrientation(bd, b) then b.width = val end
                    end
                    RefreshTBB(); EllesmereUI:RefreshPage()
                end,
            })
        end

        -- Vertical Orientation | Bar Texture
        _, h = W:DualRow(parent, y,
            { type = "toggle", text = "Vertical Orientation",
              tooltip = "Vertical bars fill upward; flipping a grouped bar flips its whole group.",
              getValue = function() local bd = SelectedTBB(); return bd and bd.verticalOrientation end,
              setValue = function(v)
                  local bd = SelectedTBB(); if not bd then return end
                  -- Swap width/height so visual dimensions stay correct
                  local function flip(c)
                      c.width, c.height = (c.height or 24), (c.width or 270)
                      c.verticalOrientation = v
                  end
                  flip(bd)
                  -- Groups stay orientation-uniform: shared width/height only makes sense
                  -- when every member reads dimensions the same way, so the whole group flips together.
                  local gid = ns.TBBBarGroupID(bd)
                  if gid ~= 0 then
                      local t = ns.GetTrackedBuffBars()
                      for _, b in ipairs(t.bars or {}) do
                          if b ~= bd and ns.TBBBarGroupID(b) == gid
                             and (b.verticalOrientation and true or false) ~= (v and true or false) then
                              flip(b)
                          end
                      end
                      -- Rotate the grow direction so side-by-side stays side-by-side across the flip (DOWN<->RIGHT, UP<->LEFT).
                      local rot = v and { DOWN = "RIGHT", UP = "LEFT" }
                                    or { RIGHT = "DOWN", LEFT = "UP" }
                      local grow = ns.TBBGroupGrow(gid)
                      if rot[grow] then ns.TBBSetGroupGrow(gid, rot[grow]) end
                  end
                  RefreshTBB()
                  -- Full rebuild: the Width slider's floor and sync tooltips are orientation-dependent.
                  EllesmereUI:RefreshPage(true)
              end },
            GateBlizzardOnly("cdmbars", { type = "dropdown", text = "Bar Texture",
              values = texValues, order = texOrder,
              getValue = function() local bd = SelectedTBB(); return bd and bd.texture or "none" end,
              setValue = function(v)
                  local bd = SelectedTBB(); if not bd then return end
                  bd.texture = v; RefreshTBB()
              end })
        );  y = y - h

        -- Name Text (dropdown + cog) | Duration Text (dropdown + cog)
        local TBB_POS_VALUES = { none = "None", center = "Center", top = "Top", bottom = "Bottom", left = "Left", right = "Right" }
        local TBB_POS_ORDER = { "none", "center", "top", "bottom", "left", "right" }

        -- When a text element claims a position, evict any other text already there so
        -- labels never overlap. Compares EFFECTIVE (rendered) positions: name text never
        -- renders on vertical bars, so its stored slot must not evict anything there.
        local function EvictTBBTextConflicts(bd, changedKey, newPos)
            if newPos == "none" then return end
            local function resolvePos(key)
                if key == "namePosition" and bd.verticalOrientation then return "none" end
                local v = bd[key]
                if v then return v end
                if key == "namePosition" then return (bd.showName ~= false) and "left" or "none" end
                if key == "timerPosition" then return bd.showTimer and "right" or "none" end
                if key == "stacksPosition" then return "center" end
                return "none"
            end
            local TEXT_KEYS = { "namePosition", "timerPosition", "stacksPosition" }
            for _, k in ipairs(TEXT_KEYS) do
                if k ~= changedKey and resolvePos(k) == newPos then
                    bd[k] = "none"
                    if k == "namePosition" then bd.showName = false
                    elseif k == "timerPosition" then bd.showTimer = false end
                end
            end
        end

        local function AddTBBTextSwatch(row, region, prefix)
            local ctrl = region._control
            local function GetColor()
                local bd = SelectedTBB()
                if not bd then return 1, 1, 1, 0.9 end
                local r = bd[prefix .. "TextR"]
                local g = bd[prefix .. "TextG"]
                local b = bd[prefix .. "TextB"]
                local a = bd[prefix .. "TextA"]
                if r == nil then r = 1 end
                if g == nil then g = 1 end
                if b == nil then b = 1 end
                if a == nil then a = 0.9 end
                return r, g, b, a
            end
            local swatch, updateSwatch = EllesmereUI.BuildColorSwatch(
                region, row:GetFrameLevel() + 3, GetColor,
                function(r, g, b, a)
                    local bd = SelectedTBB(); if not bd then return end
                    bd[prefix .. "TextR"] = r
                    bd[prefix .. "TextG"] = g
                    bd[prefix .. "TextB"] = b
                    bd[prefix .. "TextA"] = a
                    RefreshTBB()
                end,
                true, 20)
            PP.Point(swatch, "RIGHT", ctrl, "LEFT", -12, 0)
            region._lastInline = swatch

            local block = CreateFrame("Frame", nil, swatch)
            block:SetAllPoints()
            block:SetFrameLevel(swatch:GetFrameLevel() + 10)
            block:EnableMouse(true)
            block:SetScript("OnEnter", function()
                local bd = SelectedTBB()
                local tip
                if prefix == "name" and bd and bd.verticalOrientation then
                    tip = "Horizontal Orientation (name text is not shown on vertical bars)"
                else
                    local label = prefix == "timer" and "Duration Text"
                        or (prefix == "stacks" and "Stacks Text" or "Name Text")
                    tip = "This option requires a " .. label .. " position other than None"
                end
                EllesmereUI.ShowWidgetTooltip(swatch, EllesmereUI.DisabledTooltip(tip))
            end)
            block:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)

            local function UpdateSwatchState()
                local bd = SelectedTBB()
                local position
                if bd then
                    position = bd[prefix .. "Position"]
                    if not position then
                        if prefix == "name" then
                            position = (bd.showName ~= false) and "left" or "none"
                        elseif prefix == "timer" then
                            position = bd.showTimer and "right" or "none"
                        else
                            position = "center"
                        end
                    end
                end
                local enabled = position ~= nil and position ~= "none"
                if prefix == "name" and bd and bd.verticalOrientation then enabled = false end
                swatch:SetAlpha(enabled and 1 or 0.3)
                if enabled then block:Hide() else block:Show() end
            end

            EllesmereUI.RegisterWidgetRefresh(function()
                updateSwatch()
                UpdateSwatchState()
            end)
            UpdateSwatchState()
        end

        local nameRow
        nameRow, h = W:DualRow(parent, y,
            { type = "dropdown", text = "Name Text",
              values = TBB_POS_VALUES, order = TBB_POS_ORDER,
              disabled = function()
                  local bd = SelectedTBB()
                  return bd and bd.verticalOrientation and true or false
              end,
              disabledTooltip = "Horizontal Orientation (name text is not shown on vertical bars)",
              getValue = function()
                  local bd = SelectedTBB(); if not bd then return "left" end
                  if bd.namePosition then return bd.namePosition end
                  return (bd.showName ~= false) and "left" or "none"
              end,
              setValue = function(v)
                  local bd = SelectedTBB(); if not bd then return end
                  EvictTBBTextConflicts(bd, "namePosition", v)
                  bd.namePosition = v
                  bd.showName = (v ~= "none")
                  RefreshTBB(); EllesmereUI:RefreshPage()
              end },
            { type = "dropdown", text = "Duration Text",
              values = TBB_POS_VALUES, order = TBB_POS_ORDER,
              getValue = function()
                  local bd = SelectedTBB(); if not bd then return "right" end
                  if bd.timerPosition then return bd.timerPosition end
                  return bd.showTimer and "right" or "none"
              end,
              setValue = function(v)
                  local bd = SelectedTBB(); if not bd then return end
                  EvictTBBTextConflicts(bd, "timerPosition", v)
                  bd.timerPosition = v
                  bd.showTimer = (v ~= "none")
                  RefreshTBB(); EllesmereUI:RefreshPage()
              end }
        );  y = y - h
        AddTBBTextSwatch(nameRow, nameRow._leftRegion, "name")
        AddTBBTextSwatch(nameRow, nameRow._rightRegion, "timer")
        -- Cog on Name Text: text size + x/y
        do
            local rgn = nameRow._leftRegion
            EllesmereUI.BuildInlineCog(rgn, {
                title = "Name Text Settings",
                icon = EllesmereUI.DIRECTIONS_ICON,
                disabled = function()
                    local bd = SelectedTBB()
                    if bd and bd.verticalOrientation then return true end
                    local pos = bd and bd.namePosition
                    if not pos then pos = (bd and bd.showName ~= false) and "left" or "none" end
                    return pos == "none"
                end,
                disabledTooltip = function()
                    local bd = SelectedTBB()
                    if bd and bd.verticalOrientation then return "Horizontal Orientation (name text is not shown on vertical bars)" end
                    return "This option requires a Name Text position other than None"
                end,
                rows = {
                    { type = "slider", label = "Text Size", min = 8, max = 24, step = 1,
                      get = function() local bd = SelectedTBB(); return bd and bd.nameSize or 11 end,
                      set = function(v)
                          local bd = SelectedTBB(); if not bd then return end
                          bd.nameSize = v; RefreshTBB()
                      end },
                    { type = "toggle", label = "Text Wrap",
                      get = function() local bd = SelectedTBB(); return bd and bd.nameWrap == true end,
                      set = function(v)
                          local bd = SelectedTBB(); if not bd then return end
                          bd.nameWrap = v or nil; RefreshTBB()
                      end },
                    { type = "slider", label = "X Offset", min = -100, max = 100, step = 1,
                      get = function() local bd = SelectedTBB(); return bd and bd.nameX or 0 end,
                      set = function(v)
                          local bd = SelectedTBB(); if not bd then return end
                          bd.nameX = v; RefreshTBB()
                      end },
                    { type = "slider", label = "Y Offset", min = -100, max = 100, step = 1,
                      get = function() local bd = SelectedTBB(); return bd and bd.nameY or 0 end,
                      set = function(v)
                          local bd = SelectedTBB(); if not bd then return end
                          bd.nameY = v; RefreshTBB()
                      end },
                },
            })
        end
        -- Sync icon on Name Text
        do
            local rgn = nameRow._leftRegion
            EllesmereUI.BuildSyncIcon({
                region  = rgn,
                tooltip = "Apply Name Text to all Bars",
                isSynced = function()
                    local bd = SelectedTBB(); if not bd then return false end
                    local pos = bd.namePosition or ((bd.showName ~= false) and "left" or "none")
                    local tbb = ns.GetTrackedBuffBars()
                    for _, b in ipairs(tbb.bars or {}) do
                        local bp = b.namePosition or ((b.showName ~= false) and "left" or "none")
                        if bp ~= pos then return false end
                    end
                    return true
                end,
                onClick = function()
                    local bd = SelectedTBB(); if not bd then return end
                    local pos = bd.namePosition or ((bd.showName ~= false) and "left" or "none")
                    local tbb = ns.GetTrackedBuffBars()
                    for _, b in ipairs(tbb.bars or {}) do
                        b.namePosition = pos
                        b.showName = (pos ~= "none")
                    end
                    RefreshTBB(); EllesmereUI:RefreshPage()
                end,
            })
        end
        -- Cog on Duration Text: timer size + x/y
        do
            local rgn = nameRow._rightRegion
            local durationRows = {
                    { type = "slider", label = "Timer Size", min = 8, max = 24, step = 1,
                      get = function() local bd = SelectedTBB(); return bd and bd.timerSize or 11 end,
                      set = function(v)
                          local bd = SelectedTBB(); if not bd then return end
                          bd.timerSize = v; RefreshTBB()
                      end },
                    { type = "slider", label = "X Offset", min = -100, max = 100, step = 1,
                      get = function() local bd = SelectedTBB(); return bd and bd.timerX or 0 end,
                      set = function(v)
                          local bd = SelectedTBB(); if not bd then return end
                          bd.timerX = v; RefreshTBB()
                      end },
                    { type = "slider", label = "Y Offset", min = -100, max = 100, step = 1,
                      get = function() local bd = SelectedTBB(); return bd and bd.timerY or 0 end,
                      set = function(v)
                          local bd = SelectedTBB(); if not bd then return end
                          bd.timerY = v; RefreshTBB()
                      end },
            }
            -- Engine-rendered tenths below the threshold (see EllesmereUICdmTbbDecimals.lua).
                table.insert(durationRows, 2,
                    { type = "toggle", label = "Decimals",
                      tooltip = "Cannot work for pet/totem summon bars (Call Dreadstalkers, etc.) -- they expose no readable timer.",
                      get = function() local bd = SelectedTBB(); return bd and bd.timerDecimals == true end,
                      set = function(v)
                          local bd = SelectedTBB(); if not bd then return end
                          bd.timerDecimals = v or nil; RefreshTBB()
                      end })
                table.insert(durationRows, 3,
                    { type = "slider", label = "Decimal Threshold", min = 1, max = 120, step = 1,
                      disabled = function()
                          local bd = SelectedTBB()
                          return not (bd and bd.timerDecimals)
                      end,
                      disabledTooltip = "Decimals enabled",
                      get = function() local bd = SelectedTBB(); return bd and bd.timerDecimalThreshold or 5 end,
                      set = function(v)
                          local bd = SelectedTBB(); if not bd then return end
                          bd.timerDecimalThreshold = v; RefreshTBB()
                      end })
            EllesmereUI.BuildInlineCog(rgn, {
                title = "Duration Text Settings",
                rows = durationRows,
                icon = EllesmereUI.DIRECTIONS_ICON,
                disabled = function()
                    local bd = SelectedTBB()
                    local pos = bd and bd.timerPosition
                    if not pos then pos = (bd and bd.showTimer) and "right" or "none" end
                    return pos == "none"
                end,
                disabledTooltip = "This option requires a Duration Text position other than None",
            })
        end
        -- Sync icon on Duration Text
        do
            local rgn = nameRow._rightRegion
            EllesmereUI.BuildSyncIcon({
                region  = rgn,
                tooltip = "Apply Duration Text to all Bars",
                isSynced = function()
                    local bd = SelectedTBB(); if not bd then return false end
                    local pos = bd.timerPosition or (bd.showTimer and "right" or "none")
                    local tbb = ns.GetTrackedBuffBars()
                    for _, b in ipairs(tbb.bars or {}) do
                        local bp = b.timerPosition or (b.showTimer and "right" or "none")
                        if bp ~= pos then return false end
                    end
                    return true
                end,
                onClick = function()
                    local bd = SelectedTBB(); if not bd then return end
                    local pos = bd.timerPosition or (bd.showTimer and "right" or "none")
                    local tbb = ns.GetTrackedBuffBars()
                    for _, b in ipairs(tbb.bars or {}) do
                        b.timerPosition = pos
                        b.showTimer = (pos ~= "none")
                    end
                    RefreshTBB(); EllesmereUI:RefreshPage()
                end,
            })
        end

        -- Stacks Text (dropdown + resize cog: size, x, y) | Bar Strata
        local stacksRow
        stacksRow, h = W:DualRow(parent, y,
            { type = "dropdown", text = "Stacks Text",
              values = TBB_POS_VALUES, order = TBB_POS_ORDER,
              getValue = function() local bd = SelectedTBB(); return bd and bd.stacksPosition or "center" end,
              setValue = function(v)
                  local bd = SelectedTBB(); if not bd then return end
                  EvictTBBTextConflicts(bd, "stacksPosition", v)
                  bd.stacksPosition = v; RefreshTBB(); EllesmereUI:RefreshPage()
              end },
            { type = "dropdown", text = "Bar Strata",
              tooltip = "Screen layer the bar renders on; changing a grouped bar changes its whole group.",
              values = EllesmereUI.FRAME_STRATA_LABELS,
              order = EllesmereUI.FRAME_STRATA_ORDER_FULL,
              getValue = function() local bd = SelectedTBB(); return bd and bd.strata or "MEDIUM" end,
              setValue = function(v)
                  local bd = SelectedTBB(); if not bd then return end
                  bd.strata = v
                  -- Grouped bars share one strata: write the rest of the group too.
                  local gid = ns.TBBBarGroupID(bd)
                  if gid ~= 0 then
                      local t = ns.GetTrackedBuffBars()
                      for _, b in ipairs(t.bars or {}) do
                          if b ~= bd and ns.TBBBarGroupID(b) == gid then b.strata = v end
                      end
                  end
                  RefreshTBB()
              end }
        );  y = y - h
        AddTBBTextSwatch(stacksRow, stacksRow._leftRegion, "stacks")
        do
            local rgn = stacksRow._leftRegion
            EllesmereUI.BuildInlineCog(rgn, {
                title = "Stacks Text Settings",
                icon = EllesmereUI.DIRECTIONS_ICON,
                disabled = function()
                    local bd = SelectedTBB()
                    return bd and (bd.stacksPosition or "center") == "none"
                end,
                disabledTooltip = "This option requires a Stacks Text position other than None",
                rows = {
                    { type = "slider", label = "Size", min = 6, max = 24, step = 1,
                      get = function() local bd = SelectedTBB(); return bd and bd.stacksSize or 11 end,
                      set = function(v)
                          local bd = SelectedTBB(); if not bd then return end
                          bd.stacksSize = v; RefreshTBB()
                      end },
                    { type = "slider", label = "X Offset", min = -250, max = 250, step = 1,
                      get = function() local bd = SelectedTBB(); return bd and bd.stacksX or 0 end,
                      set = function(v)
                          local bd = SelectedTBB(); if not bd then return end
                          bd.stacksX = v; RefreshTBB()
                      end },
                    { type = "slider", label = "Y Offset", min = -250, max = 250, step = 1,
                      get = function() local bd = SelectedTBB(); return bd and bd.stacksY or 0 end,
                      set = function(v)
                          local bd = SelectedTBB(); if not bd then return end
                          bd.stacksY = v; RefreshTBB()
                      end },
                },
            })
        end
        -- Sync icon on Stacks Text
        do
            local rgn = stacksRow._leftRegion
            EllesmereUI.BuildSyncIcon({
                region  = rgn,
                tooltip = "Apply Stacks Text to all Bars",
                isSynced = function()
                    local bd = SelectedTBB(); if not bd then return false end
                    local pos = bd.stacksPosition or "center"
                    local tbb = ns.GetTrackedBuffBars()
                    for _, b in ipairs(tbb.bars or {}) do
                        if (b.stacksPosition or "center") ~= pos then return false end
                    end
                    return true
                end,
                onClick = function()
                    local bd = SelectedTBB(); if not bd then return end
                    local pos = bd.stacksPosition or "center"
                    local tbb = ns.GetTrackedBuffBars()
                    for _, b in ipairs(tbb.bars or {}) do b.stacksPosition = pos end
                    RefreshTBB(); EllesmereUI:RefreshPage()
                end,
            })
        end

        -- Reverse Fill | Fill Up. Deliberately paired on one row: they are the
        -- two options a user reaches for when the bar is not moving the way
        -- they expect, and they do different things. Reverse Fill mirrors the
        -- geometry, Fill Up flips the direction the value travels. Splitting
        -- them across the page is what makes people try the wrong one.
        -- Named distinctly: `fillRow` is already taken further down by the
        -- Fill Color row, which preview click-nav targets by reference.
        local fillDirRow
        fillDirRow, h = W:DualRow(parent, y,
            { type = "toggle", text = "Reverse Fill",
              tooltip = "Mirrors which end of the bar the fill is anchored to. It does not change the direction the bar travels: use Fill Up for that.",
              getValue = function() local bd = SelectedTBB(); return bd and bd.reverseFill end,
              setValue = function(v)
                  local bd = SelectedTBB(); if not bd then return end
                  bd.reverseFill = v; RefreshTBB()
              end },
            { type = "toggle", text = "Fill Up",
              tooltip = "Fills the bar as the cooldown recovers instead of draining it as the cooldown runs down.",
              disabled = function()
                  local bd = SelectedTBB()
                  -- Charge Hash Lines drives its own recovery bar, which
                  -- already fills upward, so fillUp cannot do anything there.
                  -- Leaving the toggle live would promise behaviour it has no
                  -- way to deliver. Test the same way the Charge Hash Lines
                  -- toggle does: the stored flag alone is not enough, because
                  -- chargeHashLines rides in TBB_STYLE_KEYS and a style copy
                  -- or preset can set it on a single-charge spell, where the
                  -- hash fill never actually runs.
                  return not bd or bd.trackType ~= "cooldown"
                      or (bd.chargeHashLines == true
                          and SelectedTBBSupportsChargeHash())
              end,
              -- rawTooltip: these are whole sentences. Without it they get
              -- wrapped into "This option requires <text> to be enabled".
              rawTooltip = true,
              disabledTooltip = function()
                  local bd = SelectedTBB()
                  if not bd or bd.trackType ~= "cooldown" then
                      return "This option requires a cooldown-tracking bar"
                  end
                  return "Charge Hash Lines already fills as charges recover"
              end,
              getValue = function()
                  local bd = SelectedTBB(); return bd and bd.fillUp == true
              end,
              setValue = function(v)
                  local bd = SelectedTBB(); if not bd then return end
                  bd.fillUp = v and true or nil
                  RefreshTBB()
              end }
        );  y = y - h

        -- Charge Hash Lines | Smooth Bars. Hash separator count/orientation resolve
        -- automatically from the spell's max charges; Smooth Bars is profile-wide, not per bar/spec.
        local SMOOTH_ITEMS = {
            { key = "buffs",     label = "Buffs" },
            { key = "cooldowns", label = "Cooldowns" },
        }
        local SMOOTH_DEFAULT = { buffs = true, cooldowns = false }
        local chargeHashRow
        chargeHashRow, h = W:DualRow(parent, y,
            { type = "toggle", text = "Charge Hash Lines",
              tooltip = "Divides a cooldown-tracking bar into one recovery section per ability charge. The timer shows the next charge's cooldown.",
              disabled = function()
                  local bd = SelectedTBB()
                  return not bd or bd.trackType ~= "cooldown"
                      or not SelectedTBBSupportsChargeHash()
              end,
              disabledTooltip = function()
                  local bd = SelectedTBB()
                  if not bd or bd.trackType ~= "cooldown" then
                      return "This option requires a cooldown-tracking bar"
                  end
                  return "This option is only available for abilities with multiple charges"
              end,
              getValue = function()
                  local bd = SelectedTBB()
                  return bd and bd.chargeHashLines == true
                      and SelectedTBBSupportsChargeHash()
              end,
              setValue = function(v)
                  local bd = SelectedTBB(); if not bd then return end
                  if v and not SelectedTBBSupportsChargeHash() then return end
                  bd.chargeHashLines = v and true or nil
                  RefreshTBB(); EllesmereUI:RefreshPage()
              end },
            { type = "dropdown", text = "Smooth Bars",
              tooltip = "Eases bar movement instead of snapping. Affects all Tracking Bars of that type, in every spec of this profile.",
              values = { __placeholder = "..." }, order = { "__placeholder" },
              getValue = function() return "__placeholder" end,
              setValue = function() end });  y = y - h
        do
            local rgn = chargeHashRow._leftRegion
            EllesmereUI.BuildInlineCog(rgn, {
                title = "Charge Hash Line Settings",
                disabled = function()
                    local bd = SelectedTBB()
                    return not bd or bd.trackType ~= "cooldown"
                        or not SelectedTBBSupportsChargeHash()
                        or bd.chargeHashLines ~= true
                end,
                disabledTooltip = function()
                    local bd = SelectedTBB()
                    if not bd or bd.trackType ~= "cooldown" then return "This option requires a cooldown-tracking bar" end
                    if not SelectedTBBSupportsChargeHash() then return "This option is only available for abilities with multiple charges" end
                    return "Enable Charge Hash Lines first"
                end,
                rawTooltip = true,
                rows = {
                    { type = "slider", label = "Line Width", min = 1, max = 10, step = 1,
                      get = function()
                          local bd = SelectedTBB()
                          return bd and bd.chargeHashLineWidth or 2
                      end,
                      set = function(v)
                          local bd = SelectedTBB(); if not bd then return end
                          bd.chargeHashLineWidth = v
                          RefreshTBB()
                      end },
                    { type = "colorpicker", label = "Line Color", hasAlpha = true,
                      get = function()
                          local bd = SelectedTBB()
                          if not bd then return 0, 0, 0, 1 end
                          local a = bd.chargeHashLineA
                          if a == nil then a = 1 end
                          return bd.chargeHashLineR or 0, bd.chargeHashLineG or 0,
                              bd.chargeHashLineB or 0, a
                      end,
                      set = function(r, g, b, a)
                          local bd = SelectedTBB(); if not bd then return end
                          bd.chargeHashLineR, bd.chargeHashLineG = r, g
                          bd.chargeHashLineB, bd.chargeHashLineA = b, a
                          RefreshTBB()
                      end },
                    { type = "toggle", label = "Partial Charge Shade",
                      tooltip = "Darkens the section of the bar that is still recharging the next charge.",
                      get = function()
                          local bd = SelectedTBB()
                          return bd and bd.chargeHashShade == true
                      end,
                      set = function(v)
                          local bd = SelectedTBB(); if not bd then return end
                          bd.chargeHashShade = v and true or nil
                          RefreshTBB()
                      end },
                    { type = "slider", label = "Shade Darkness", min = 5, max = 95, step = 5,
                      disabled = function()
                          local bd = SelectedTBB()
                          return not bd or bd.chargeHashShade ~= true
                      end,
                      get = function()
                          local bd = SelectedTBB()
                          return bd and math.floor(((bd.chargeHashShadeAlpha or 0.5) * 100) + 0.5) or 50
                      end,
                      set = function(v)
                          local bd = SelectedTBB(); if not bd then return end
                          bd.chargeHashShadeAlpha = (v or 50) / 100
                          RefreshTBB()
                      end },
                },
            })
        end

        do
            local rgn = chargeHashRow._rightRegion
            if rgn._control then rgn._control:Hide() end
            local cbDD, cbDDRefresh = EllesmereUI.BuildVisOptsCBDropdown(
                rgn, 210, rgn:GetFrameLevel() + 2,
                SMOOTH_ITEMS,
                function(k)
                    local s = ns.GetTBBSmoothSettings and ns.GetTBBSmoothSettings()
                    if not s or s[k] == nil then return SMOOTH_DEFAULT[k] end
                    return s[k] == true
                end,
                function(k, v)
                    local s = ns.GetTBBSmoothSettings and ns.GetTBBSmoothSettings()
                    if s then s[k] = v and true or false end
                end)
            PP.Point(cbDD, "RIGHT", rgn, "RIGHT", -20, 0)
            rgn._control = cbDD
            rgn._lastInline = nil
            EllesmereUI.RegisterWidgetRefresh(cbDDRefresh)
        end

        -------------------------------------------------------------------
        --  DISPLAY
        -------------------------------------------------------------------
        local displayHeader
        displayHeader, h = W:SectionHeader(parent, "Display", y);  y = y - h
        y = EllesmereUI.BlizzStyle.Note(parent, y, "cdmbars")

        -- Visibility: one control, the shared axis list plus the TBB-only Hide When
        -- Inactive row (single-lane, so it rides in as an extraItem). No mouseover for
        -- CDM-family bars; "Only In Combat" is the In Combat axis.
        local _, tbbVisH = EllesmereUI.BuildVisibilityRow(W, parent, y,
            { getStore = SelectedTBB, legacyKey = "barVisibility",
              caps = { partyIncludesRaid = false, noMouseover = true, luaDragonriding = true },
              onChanged = function() RefreshTBB() end,
              onOptionChanged = function() RefreshTBB() end,
              extraItems = {
                  { key = "hideWhenInactive", label = "Hide When Inactive",
                    tooltip = "Only show this bar while the tracked buff/cooldown is active. Unchecked keeps an empty bar on screen at all times.",
                    -- nil means ON everywhere this is read, so it cannot go through a
                    -- plain truthiness path.
                    get = function()
                        local bd = SelectedTBB()
                        return bd and bd.hideWhenInactive ~= false
                    end,
                    -- No refresh here: the row fires onOptionChanged after every write.
                    set = function(v)
                        local bd = SelectedTBB(); if not bd then return end
                        bd.hideWhenInactive = v
                    end },
              } },
            -- Show Icon moved up into the slot the Visibility Options dropdown left behind.
            { type = "dropdown", text = "Show Icon",
              values = { none = "None", left = "Left (Top)", right = "Right (Bottom)" },
              order = { "none", "left", "right" },
              getValue = function() local bd = SelectedTBB(); return bd and bd.iconDisplay or "none" end,
              setValue = function(v)
                  local bd = SelectedTBB(); if not bd then return end
                  bd.iconDisplay = v; RefreshTBB()
              end });  y = y - tbbVisH

        -- Opacity | Background Color (moved up from its old trailing half-row below)
        local iconRow
        iconRow, h = W:DualRow(parent, y,
            { type = "slider", text = "Opacity",
              min = 0, max = 100, step = 1,
              getValue = function()
                  local bd = SelectedTBB()
                  return bd and math.floor((bd.opacity or 1.0) * 100 + 0.5) or 100
              end,
              setValue = function(v)
                  local bd = SelectedTBB(); if not bd then return end
                  bd.opacity = v / 100; RefreshTBB()
              end },
            { type = "multiSwatch", text = "Background Color",
              swatches = {
                  GateBlizzardOnly("cdmbars", { tooltip = "Background Color", hasAlpha = true,
                    getValue = function()
                        local bd = SelectedTBB()
                        return (bd and bd.bgR or 0), (bd and bd.bgG or 0), (bd and bd.bgB or 0), (bd and bd.bgA or 0.4)
                    end,
                    setValue = function(r, g, b, a)
                        local bd = SelectedTBB(); if not bd then return end
                        bd.bgR, bd.bgG, bd.bgB, bd.bgA = r, g, b, a; RefreshTBB()
                    end }),
              } }
        );  y = y - h

        -- Fill Color (dropdown: auto/custom + gradient mode + 2 inline swatches) | Show Spark
        local fillRow
        fillRow, h = W:DualRow(parent, y,
            EllesmereUI.BlizzStyle.Gate("cdmbars", { type = "dropdown", text = "Fill Color",
              values = {
                  none = "Custom Color",
                  VERTICAL = "Vertical Gradient",
                  HORIZONTAL = "Horizontal Gradient",
              },
              order = { "none", "HORIZONTAL", "VERTICAL" },
              getValue = function()
                  local bd = SelectedTBB(); if not bd then return "none" end
                  -- Treat legacy "auto" as "custom" (no migration needed)
                  if not bd.gradientEnabled then return "none" end
                  return bd.gradientDir or "HORIZONTAL"
              end,
              setValue = function(v)
                  local bd = SelectedTBB(); if not bd then return end
                  bd.fillColorMode = "custom"
                  if v == "none" then
                      bd.gradientEnabled = false
                  else
                      bd.gradientEnabled = true
                      bd.gradientDir = v
                  end
                  RefreshTBB(); EllesmereUI:RefreshPage()
              end }),
            { type = "toggle", text = "Show Spark",
              getValue = function() local bd = SelectedTBB(); return bd and bd.showSpark end,
              setValue = function(v)
                  local bd = SelectedTBB(); if not bd then return end
                  bd.showSpark = v; RefreshTBB()
              end }
        );  y = y - h
        -- Inline swatches on Fill Color dropdown: fill color + gradient end color
        do
            local rgn = fillRow._leftRegion
            local ctrl = rgn._control

            -- Swatch 1 (rightmost, closer to dropdown): Fill Color
            local fillSwatch, updateFillSwatch = EllesmereUI.BuildColorSwatch(
                rgn, fillRow:GetFrameLevel() + 3,
                function()
                    local bd = SelectedTBB()
                    if not bd then
                        local _, cf = UnitClass("player")
                        local cc = RAID_CLASS_COLORS[cf]
                        return cc and cc.r or 1, cc and cc.g or 0.70, cc and cc.b or 0, 1
                    end
                    return bd.fillR, bd.fillG, bd.fillB, bd.fillA
                end,
                function(r, g, b, a)
                    local bd = SelectedTBB(); if not bd then return end
                    bd.fillColorMode = "custom"
                    bd.fillR, bd.fillG, bd.fillB, bd.fillA = r, g, b, a; RefreshTBB()
                end,
                true, 20)
            PP.Point(fillSwatch, "RIGHT", ctrl, "LEFT", -8, 0)

            -- Swatch 2 (left of swatch 1): Gradient End Color
            local gradSwatch, updateGradSwatch = EllesmereUI.BuildColorSwatch(
                rgn, fillRow:GetFrameLevel() + 3,
                function()
                    local bd = SelectedTBB()
                    if not bd then return 0.20, 0.20, 0.80, 1 end
                    return bd.gradientR, bd.gradientG, bd.gradientB, bd.gradientA
                end,
                function(r, g, b, a)
                    local bd = SelectedTBB(); if not bd then return end
                    bd.gradientR, bd.gradientG, bd.gradientB, bd.gradientA = r, g, b, a; RefreshTBB()
                end,
                true, 20)
            PP.Point(gradSwatch, "RIGHT", fillSwatch, "LEFT", -4, 0)

            -- Disable block on fill swatch when Auto mode
            local fillBlock = CreateFrame("Frame", nil, fillSwatch)
            fillBlock:SetAllPoints(); fillBlock:SetFrameLevel(fillSwatch:GetFrameLevel() + 10)
            fillBlock:EnableMouse(true)
            fillBlock:SetScript("OnEnter", function()
                EllesmereUI.ShowWidgetTooltip(fillSwatch, EllesmereUI.DisabledTooltip("This option requires Fill Color to be set to Custom"))
            end)
            fillBlock:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)

            -- Disable block on gradient swatch when gradient is off or auto mode
            local gradBlock = CreateFrame("Frame", nil, gradSwatch)
            gradBlock:SetAllPoints(); gradBlock:SetFrameLevel(gradSwatch:GetFrameLevel() + 10)
            gradBlock:EnableMouse(true)
            gradBlock:SetScript("OnEnter", function()
                local bd = SelectedTBB()
                local isAuto = false
                local msg = isAuto and "Set Fill Color to a Custom option" or "This option requires a gradient to be set"
                EllesmereUI.ShowWidgetTooltip(gradSwatch, EllesmereUI.DisabledTooltip(msg))
            end)
            gradBlock:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)

            local function UpdateSwatchStates()
                local bd = SelectedTBB()
                local isAuto = false
                -- Blizzard Style keeps the flat atlas fill, so the gradient end colour is inert there.
                local noGrad = not bd or not bd.gradientEnabled or EllesmereUI.BlizzStyle.Get("cdmbars")
                -- Fill swatch: disabled in auto mode
                if isAuto then fillSwatch:SetAlpha(0.3); fillBlock:Show()
                else fillSwatch:SetAlpha(1); fillBlock:Hide() end
                -- Grad swatch: disabled in auto mode OR when no gradient
                if isAuto or noGrad then gradSwatch:SetAlpha(0.3); gradBlock:Show()
                else gradSwatch:SetAlpha(1); gradBlock:Hide() end
            end
            EllesmereUI.RegisterWidgetRefresh(function() updateFillSwatch(); updateGradSwatch(); UpdateSwatchStates() end)
            UpdateSwatchStates()
        end

        -- Border Texture dropdown (+ inline offset cog) | empty
        do
            local texValues, texOrder = EllesmereUI.GetBorderTextureDropdown()
            local tbbBsRow
            tbbBsRow, h = W:DualRow(parent, y,
                EllesmereUI.BlizzStyle.Gate("cdmbars", { type="dropdown", text="Border Texture",
                  values=texValues, order=texOrder,
                  getValue=function() local bd = SelectedTBB(); return bd and bd.borderTexture or "solid" end,
                  setValue=function(v)
                      local bd = SelectedTBB(); if not bd then return end
                      bd.borderTexture = v; bd.borderTextureOffset = nil; bd.borderTextureOffsetY = nil; bd.borderTextureShiftX = nil; bd.borderTextureShiftY = nil
                      local _bcol, _bbehind = EllesmereUI.GetBorderStyleSelectDefaults(v)
                      bd.borderR = _bcol.r; bd.borderG = _bcol.g; bd.borderB = _bcol.b
                      bd.borderBehind = _bbehind
                      local defSz = EllesmereUI.GetBorderDefaultSize("resourcebars", v)
                      if defSz then bd.borderSize = defSz end
                      if bd.borderSizePx then bd.borderSizePx = false end
                      RefreshTBB(); EllesmereUI:RefreshPage(true)
                  end }),
                -- Classic WoW UI: the slot sizes the vanilla frame instead.
                (EllesmereUI.BlizzStyle.Active("cdmbars") == "classic") and EllesmereUI.BlizzStyle.ClassicBorderSizeCfg(
                    function() local bd = SelectedTBB(); return bd and bd.stockBorderScale end,
                    function(v)
                        local bd = SelectedTBB(); if not bd then return end
                        bd.stockBorderScale = v; RefreshTBB()
                    end) or
                EllesmereUI.BlizzStyle.Gate("cdmbars", EllesmereUI.BorderPxSliderCfg({ text = "Border Size",
                  getStep = function() local bd = SelectedTBB(); return bd and bd.borderSize or 0 end,
                  setStep = function(step) local bd = SelectedTBB(); if bd then bd.borderSize = step end end,
                  getTex = function() local bd = SelectedTBB(); return bd and bd.borderTexture or "solid" end,
                  getPx = function() local bd = SelectedTBB(); return bd and bd.borderSizePx end,
                  setPx = function(v) local bd = SelectedTBB(); if bd then bd.borderSizePx = v end end,
                  apply = function() RefreshTBB() end,
                })));  y = y - h
            -- Width Offset | Height Offset: the textured border's outward offsets,
            -- present only while a textured style is selected (built on the
            -- prebuild pass too, so the y advance is identical).
            do
                local bd0 = SelectedTBB()
                local tex0 = bd0 and bd0.borderTexture or "solid"
                if tex0 ~= "" and tex0 ~= "solid" then
                    local ocfgL, ocfgR = EllesmereUI.BorderOffsetRowCfgs({
                        addonKey = "resourcebars",
                        getTex = function() local bd = SelectedTBB(); return bd and bd.borderTexture or "solid" end,
                        getStep = function() local bd = SelectedTBB(); return bd and bd.borderSize or 0 end,
                        getSizeKey = function() local bd = SelectedTBB(); return bd and bd.borderSize or 0 end,
                        getPx = function() local bd = SelectedTBB(); return bd and bd.borderSizePx end,
                        getX = function() local bd = SelectedTBB(); return bd and bd.borderTextureOffset end,
                        setX = function(v) local bd = SelectedTBB(); if bd then bd.borderTextureOffset = v end end,
                        getY = function() local bd = SelectedTBB(); return bd and bd.borderTextureOffsetY end,
                        setY = function(v) local bd = SelectedTBB(); if bd then bd.borderTextureOffsetY = v end end,
                        apply = function() RefreshTBB() end,
                    })
                    _, h = W:DualRow(parent, y,
                        EllesmereUI.BlizzStyle.Gate("cdmbars", ocfgL),
                        EllesmereUI.BlizzStyle.Gate("cdmbars", ocfgR));  y = y - h
                end
            end
            -- Inline border color swatch on Border Size (right region); none
            -- under Classic WoW UI, whose slider sizes the vanilla frame.
            if EllesmereUI.BlizzStyle.Active("cdmbars") ~= "classic" then
                local rgn = tbbBsRow._rightRegion
                local ctrl = rgn._control
                local borderSwatch, updateBorderSwatch = EllesmereUI.BuildColorSwatch(
                    rgn, tbbBsRow:GetFrameLevel() + 3,
                    function()
                        local bd = SelectedTBB()
                        return (bd and bd.borderR or 0), (bd and bd.borderG or 0), (bd and bd.borderB or 0)
                    end,
                    function(r, g, b)
                        local bd = SelectedTBB(); if not bd then return end
                        bd.borderR, bd.borderG, bd.borderB = r, g, b; RefreshTBB()
                    end,
                    false, 20)
                PP.Point(borderSwatch, "RIGHT", ctrl, "LEFT", -8, 0)
                EllesmereUI.RegisterWidgetRefresh(function() updateBorderSwatch() end)
                EllesmereUI.BlizzStyle.BlockInline("cdmbars", borderSwatch)
            end
            do
                local rgn = tbbBsRow._leftRegion
                local cogBtn = EllesmereUI.BuildInlineCog(rgn, {
                    icon = EllesmereUI.DIRECTIONS_ICON,
                    title = "Border Options",
                    rows = {
                        { type = "slider", label = "Shift X", min = -10, max = 10, step = 1,
                          get = function()
                              local bd = SelectedTBB(); if not bd then return 0 end
                              local v = bd.borderTextureShiftX
                              if v then return v end
                              local _, _, dsx = EllesmereUI.GetBorderDefaults("resourcebars", bd.borderTexture or "solid", bd.borderSize or 0)
                              return dsx
                          end,
                          set = function(v)
                              local bd = SelectedTBB(); if not bd then return end
                              bd.borderTextureShiftX = v == 0 and nil or v; RefreshTBB()
                          end },
                        { type = "slider", label = "Shift Y", min = -10, max = 10, step = 1,
                          get = function()
                              local bd = SelectedTBB(); if not bd then return 0 end
                              local v = bd.borderTextureShiftY
                              if v then return v end
                              local _, _, _, dsy = EllesmereUI.GetBorderDefaults("resourcebars", bd.borderTexture or "solid", bd.borderSize or 0)
                              return dsy
                          end,
                          set = function(v)
                              local bd = SelectedTBB(); if not bd then return end
                              bd.borderTextureShiftY = v == 0 and nil or v; RefreshTBB()
                          end },
                        { type = "toggle", label = "Show Behind",
                          get = function()
                              local bd = SelectedTBB(); return bd and bd.borderBehind or false
                          end,
                          set = function(v)
                              local bd = SelectedTBB(); if not bd then return end
                              bd.borderBehind = v == false and nil or v; RefreshTBB()
                          end },
                    },
                })
                if cogBtn then
                    local function UpdateCogVis()
                        local bd = SelectedTBB()
                        local tex = bd and bd.borderTexture or "solid"
                        cogBtn:SetShown(tex ~= "solid" and not EllesmereUI.BlizzStyle.Get("cdmbars"))
                    end
                    EllesmereUI.RegisterWidgetRefresh(UpdateCogVis)
                    UpdateCogVis()
                end
            end
        end

        -----------------------------------------------------------------------
        --  EXTRAS
        -----------------------------------------------------------------------
        _, h = W:SectionHeader(parent, "EXTRAS", y);  y = y - h

        -- Row 1: Pandemic Glow (dropdown + swatch + cog + sync) | Stack Based
        -- Bar (buff bars only; page rebuilds on selection change, so cd/utility
        -- bars get a blank slot). Stack Based Bar is inert until Max Stacks is
        -- enabled below.
        do
            -- Shared glow controls over the bar's pandemic keys (the Glows page's
            -- Tracked Buff Bar descriptor, resolving the selected bar).
            local GO = EllesmereUI.GlowOptions
            local tbbDesc = ns._CDM_TbbGlowDesc(SelectedTBB, function() RefreshTBB() end)

            local bd0 = SelectedTBB()
            local rightSlot
            if bd0 and bd0.trackType ~= "cooldown" then
                rightSlot = { type = "toggle", text = "Stack Based Bar",
                    tooltip = "Fill this bar from current stacks out of Max Stacks instead of remaining time (requires Enable Max Stacks below).",
                    getValue = function() local bd = SelectedTBB(); return bd and bd.stackBasedBar end,
                    setValue = function(v)
                        local bd = SelectedTBB(); if not bd then return end
                        bd.stackBasedBar = v and true or false; RefreshTBB()
                    end }
            else
                rightSlot = { type = "label", text = "" }
            end

            local tbbPanRow
            tbbPanRow, h = W:DualRow(parent, y, GO.DropdownSpec(tbbDesc, "Pandemic Glow",
                "Show a glow on the bar when the remaining duration is in the pandemic window (last 30%)"), rightSlot);  y = y - h
            GO.AttachInline(tbbPanRow._leftRegion, tbbDesc)

            -- Apply All
            if EllesmereUI.BuildSyncIcon and EllesmereUI.ApplyPandemicGlowToAll then
                EllesmereUI.BuildSyncIcon({
                    region = tbbPanRow._leftRegion,
                    tooltip = "Apply this pandemic glow to Nameplates, all CDM bars, and other tracking bars. A surface that can't show a style uses its closest match.",
                    isSynced = function()
                        local src = SelectedTBB(); if not src then return true end
                        return EllesmereUI.IsPandemicGlowSyncedToAll(EllesmereUI.PandemicPayloadFromRectBar(src), { skipTbbBar = src })
                    end,
                    onClick = function()
                        local src = SelectedTBB(); if not src then return end
                        EllesmereUI.ApplyPandemicGlowToAll(EllesmereUI.PandemicPayloadFromRectBar(src), { skipTbbBar = src })
                        RefreshTBB()
                    end,
                })
            end
        end

        -- Row 2: Enable Max Stacks (toggle + inline slider) | Ticks at Stacks (label + inline input)
        local function maxStacksOff()
            local bd = SelectedTBB()
            return not bd or not bd.stackThresholdMaxEnabled
        end
        local maxStacksRow
        maxStacksRow, h = W:DualRow(parent, y,
            { type = "toggle", text = "Enable Max Stacks",
              getValue = function() local bd = SelectedTBB(); return bd and bd.stackThresholdMaxEnabled end,
              setValue = function(v)
                  local bd = SelectedTBB(); if not bd then return end
                  bd.stackThresholdMaxEnabled = v; RefreshTBB(); EllesmereUI:RefreshPage()
              end },
            { type = "label", text = "Ticks at Stacks",
              tooltip = "Comma separated stack counts to put a tick mark at. Type all to mark every stack." }
        );  y = y - h
        -- Inline slider on Enable Max Stacks toggle (same as inline swatch positioning)
        do
            local rgn = maxStacksRow._leftRegion
            local ctrl = rgn._control
            local SL = EllesmereUI.SL or {}
            local trackFrame, valBox, _, slThumb = EllesmereUI.BuildSliderCore(
                rgn, 90, 4, 14, 36, 26, 13, SL.INPUT_A or 0.6,
                1, 100, 1,
                function() local bd = SelectedTBB(); return bd and bd.stackThresholdMax or 10 end,
                function(v) local bd = SelectedTBB(); if bd then bd.stackThresholdMax = v; RefreshTBB() end end,
                true)
            PP.Point(valBox, "RIGHT", ctrl, "LEFT", -6, 0)
            PP.Point(trackFrame, "RIGHT", valBox, "LEFT", -8, 0)
            -- Disable block
            local block = CreateFrame("Frame", nil, trackFrame)
            block:SetPoint("TOPLEFT", trackFrame, "TOPLEFT", -4, 4)
            block:SetPoint("BOTTOMRIGHT", valBox, "BOTTOMRIGHT", 4, -4)
            block:SetFrameLevel(trackFrame:GetFrameLevel() + 10)
            block:EnableMouse(true)
            block:SetScript("OnEnter", function()
                EllesmereUI.ShowWidgetTooltip(trackFrame, EllesmereUI.DisabledTooltip("Max Stacks"))
            end)
            block:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
            local function UpdateMaxSliderState()
                local off = maxStacksOff()
                trackFrame:SetAlpha(off and 0.3 or 1)
                valBox:SetAlpha(off and 0.3 or 1)
                valBox:EnableMouse(not off)
                if slThumb then slThumb._sliderDisabled = off end
                if off then block:Show() else block:Hide() end
            end
            EllesmereUI.RegisterWidgetRefresh(UpdateMaxSliderState)
            UpdateMaxSliderState()
        end
        -- Add "(Ex: 1,5,8)" suffix in smaller, dimmer text
        do
            local ticksLabel = maxStacksRow._rightRegion and maxStacksRow._rightRegion._label
            if ticksLabel then
                local suffix = maxStacksRow._rightRegion:CreateFontString(nil, "OVERLAY")
                suffix:SetFont(EllesmereUI.EXPRESSWAY or "Fonts\\FRIZQT__.TTF", 11, "")
                suffix:SetTextColor(1, 1, 1, 0.35)
                suffix:SetPoint("LEFT", ticksLabel, "RIGHT", 5, 0)
                suffix:SetText(EllesmereUI.L("(Ex: 1,5,8)"))
            end
        end
        -- Inline input on Ticks at Stacks (matches slider value box style)
        do
            local rgn = maxStacksRow._rightRegion
            local SIDE_PAD = 20
            local FONT = EllesmereUI.EXPRESSWAY or "Fonts\\FRIZQT__.TTF"
            local INPUT_W = 70
            local INPUT_H = 26

            local box = CreateFrame("EditBox", nil, rgn)
            PP.Size(box, INPUT_W, INPUT_H)
            PP.Point(box, "RIGHT", rgn, "RIGHT", -SIDE_PAD, 0)
            box:SetFrameLevel(rgn:GetFrameLevel() + 2)
            box:SetAutoFocus(false)
            box:SetJustifyH("CENTER")
            box:SetFont(FONT, 13, "")
            box:SetTextColor(
                EllesmereUI.TEXT_DIM_R or 0.75,
                EllesmereUI.TEXT_DIM_G or 0.75,
                EllesmereUI.TEXT_DIM_B or 0.75,
                EllesmereUI.TEXT_DIM_A or 1)
            -- Background matching slider input box
            local bg = box:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetColorTexture(
                EllesmereUI.SL_INPUT_R or 0.08,
                EllesmereUI.SL_INPUT_G or 0.08,
                EllesmereUI.SL_INPUT_B or 0.08,
                (EllesmereUI.SL_INPUT_A or 0.5) + (EllesmereUI.MW_INPUT_ALPHA_BOOST or 0.15))
            -- Border matching slider input box
            if PP.CreateBorder then
                PP.CreateBorder(box,
                    EllesmereUI.BORDER_R or 0.15,
                    EllesmereUI.BORDER_G or 0.15,
                    EllesmereUI.BORDER_B or 0.15,
                    EllesmereUI.SL_INPUT_BRD_A or 0.4, 1)
            end

            box:SetScript("OnEnterPressed", function(self)
                self:ClearFocus()
                local bd = SelectedTBB(); if bd then
                    bd.stackThresholdTicks = self:GetText(); RefreshTBB()
                end
            end)
            box:SetScript("OnEscapePressed", function(self)
                self:ClearFocus()
                local bd = SelectedTBB()
                self:SetText(bd and bd.stackThresholdTicks or "")
            end)

            -- Inline swatch for tick mark color (left of the input box)
            local tickSwatch, updateTickSwatch = EllesmereUI.BuildColorSwatch(
                rgn, box:GetFrameLevel() + 1,
                function()
                    local bd = SelectedTBB()
                    if not bd then return 1, 1, 1, 1 end
                    local a = bd.stackThresholdTickA
                    if a == nil then a = 1 end
                    return bd.stackThresholdTickR or 1, bd.stackThresholdTickG or 1,
                           bd.stackThresholdTickB or 1, a
                end,
                function(r, g, b, a)
                    local bd = SelectedTBB(); if not bd then return end
                    bd.stackThresholdTickR, bd.stackThresholdTickG = r, g
                    bd.stackThresholdTickB, bd.stackThresholdTickA = b, a; RefreshTBB()
                end,
                true, 20)
            PP.Point(tickSwatch, "RIGHT", box, "LEFT", -8, 0)
            local tickBlock = CreateFrame("Frame", nil, tickSwatch)
            tickBlock:SetAllPoints(); tickBlock:SetFrameLevel(tickSwatch:GetFrameLevel() + 10)
            tickBlock:EnableMouse(true)
            tickBlock:SetScript("OnEnter", function()
                EllesmereUI.ShowWidgetTooltip(tickSwatch, EllesmereUI.DisabledTooltip("Max Stacks"))
            end)
            tickBlock:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)

            local function UpdateTicksInput()
                local bd = SelectedTBB()
                box:SetText(bd and bd.stackThresholdTicks or "")
                local off = maxStacksOff()
                box:SetAlpha(off and 0.3 or 1)
                box:EnableMouse(not off)
                if off then tickSwatch:SetAlpha(0.3); tickBlock:Show()
                else tickSwatch:SetAlpha(1); tickBlock:Hide() end
                if updateTickSwatch then updateTickSwatch() end
            end
            EllesmereUI.RegisterWidgetRefresh(UpdateTicksInput)
            UpdateTicksInput()
        end

        -- Row 3: Enable Stack Threshold (toggle + inline swatch) | Stack Threshold (slider)
        local threshRow
        threshRow, h = W:DualRow(parent, y,
            { type = "toggle", text = "Enable Stack Threshold",
              tooltip = "This will change the color of your bar if you have more than your chosen number of stacks",
              getValue = function() local bd = SelectedTBB(); return bd and bd.stackThresholdEnabled end,
              setValue = function(v)
                  local bd = SelectedTBB(); if not bd then return end
                  bd.stackThresholdEnabled = v; RefreshTBB(); EllesmereUI:RefreshPage()
              end },
            { type = "slider", text = "Stack Threshold",
              min = 0, max = 100, step = 1,
              disabled = function()
                  local bd = SelectedTBB()
                  if not bd or not bd.stackThresholdEnabled then return true end
                  return bd.stackThresholdMulti and true or false
              end,
              disabledTooltip = function()
                  local bd = SelectedTBB()
                  if bd and bd.stackThresholdEnabled and bd.stackThresholdMulti then
                      return StackThreshReplacesTip()
                  end
                  return EllesmereUI.DisabledTooltip("Stack Threshold")
              end,
              rawTooltip = true,
              getValue = function() local bd = SelectedTBB(); return bd and bd.stackThreshold or 5 end,
              setValue = function(v)
                  local bd = SelectedTBB(); if not bd then return end
                  bd.stackThreshold = v; RefreshTBB()
              end }
        );  y = y - h
        -- Inline swatch on Enable Stack Threshold toggle
        do
            local rgn = threshRow._leftRegion
            local ctrl = rgn._control
            local threshSwatch, updateThreshSwatch = EllesmereUI.BuildColorSwatch(
                rgn, threshRow:GetFrameLevel() + 3,
                function()
                    local bd = SelectedTBB()
                    if not bd then return 0.8, 0.1, 0.1, 1 end
                    return bd.stackThresholdR or 0.8, bd.stackThresholdG or 0.1, bd.stackThresholdB or 0.1, bd.stackThresholdA or 1
                end,
                function(r, g, b, a)
                    local bd = SelectedTBB(); if not bd then return end
                    bd.stackThresholdR, bd.stackThresholdG, bd.stackThresholdB, bd.stackThresholdA = r, g, b, a; RefreshTBB()
                end,
                true, 20)
            PP.Point(threshSwatch, "RIGHT", ctrl, "LEFT", -8, 0)
            local threshBlock = CreateFrame("Frame", nil, threshSwatch)
            threshBlock:SetAllPoints(); threshBlock:SetFrameLevel(threshSwatch:GetFrameLevel() + 10)
            threshBlock:EnableMouse(true)
            threshBlock:SetScript("OnEnter", function()
                local bd = SelectedTBB()
                if bd and bd.stackThresholdEnabled and bd.stackThresholdMulti then
                    EllesmereUI.ShowWidgetTooltip(threshSwatch, StackThreshReplacesTip())
                    return
                end
                EllesmereUI.ShowWidgetTooltip(threshSwatch, EllesmereUI.DisabledTooltip("Stack Threshold"))
            end)
            threshBlock:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)

            -- Cog: opens the multi-threshold editor. Stays usable while multi is
            -- on, since it is the only way back out of it.
            EllesmereUI.BuildInlineCog(rgn, {
                anchorTo = threshSwatch,
                show = function(self)
                    ShowStackThreshEditor({
                        getCfg    = SelectedTBB,
                        refreshFn = RefreshTBB,
                        anchor    = self,
                    })
                end,
                tip = StackThreshHelpTip(),
                disabled = function() local bd = SelectedTBB(); return not (bd and bd.stackThresholdEnabled) end,
                disabledTooltip = "Stack Threshold",
            })

            local function UpdateThreshSwatchState()
                local bd = SelectedTBB()
                local enabled = bd and bd.stackThresholdEnabled
                -- The swatch edits the single threshold color, so multi masks it
                -- the same way it masks the slider.
                local off = not enabled or (bd.stackThresholdMulti and true or false)
                if off then threshSwatch:SetAlpha(0.3); threshBlock:Show()
                else threshSwatch:SetAlpha(1); threshBlock:Hide() end
            end
            EllesmereUI.RegisterWidgetRefresh(function() updateThreshSwatch(); UpdateThreshSwatchState() end)
            UpdateThreshSwatchState()
        end

        -- Preview click-navigation map: preview element -> section + row.
        -- Resolved at click time by NavigateToSetting.
        parent._tbbClickTargets = {
            barFill    = { section = displayHeader, target = fillRow,   slotSide = "left" },
            icon       = { section = displayHeader, target = iconRow,   slotSide = "left" },
            nameText   = { section = layoutHeader,  target = nameRow,   slotSide = "left" },
            timerText  = { section = layoutHeader,  target = nameRow,   slotSide = "right" },
            stacksText = { section = layoutHeader,  target = stacksRow, slotSide = "left" },
        }

        -- Ensure bar frames exist before showing placeholders
        ns.BuildTrackedBuffBars()
        UpdateTBBPlaceholder()
        RefreshTBBPopout()
        return math.abs(y)
    end
    ---------------------------------------------------------------------------
    --  CDM Bars page
    ---------------------------------------------------------------------------
    -- Mutable state shared with the pickers and page builders under
    -- CooldownManager_Options\. A table instead of locals so every file reads
    -- and writes the live value.
    local optState = {}
    local growValues = EllesmereUI.GROW_DIR_VALUES_BASE
    local growOrder  = { "RIGHT", "LEFT", "DOWN", "UP" } -- this dropdown's own sequence (DOWN before UP)
    local durationPositionValues = {
        center = "Center",
        top = "Above Icon",
        bottom = "Below Icon",
        left = "Left of Icon",
        right = "Right of Icon",
    }
    local durationPositionOrder = { "center", "top", "bottom", "left", "right" }

    -- Track which bar is selected in the CDM Bars tab
    optState.selectedCDMBarIndex = 1

    -- Deep-link helper: select a CDM bar by key or barType (used by the What's
    -- New "Always Show Buffs" card preSelect -- that per-bar toggle only renders
    -- when a buff-family bar is selected). Sets the index immediately, like
    -- EllesmereUI._setUnitFrameUnit, so header and rebuilt page both reflect it.
    function EllesmereUI._setCDMBar(keyOrType)
        local p = DB()
        local bars = p and p.cdmBars and p.cdmBars.bars
        if not bars then return end
        for bi, bb in ipairs(bars) do
            if bb.key == keyOrType or bb.barType == keyOrType then
                optState.selectedCDMBarIndex = bi
                return
            end
        end
    end

    -- CDM Bars preview state, nil until built: optState._cdmPreview is the
    -- preview frame, optState._cdmHeaderBuilder the content header builder
    optState._cdmHeaderFixedH = 0

    local function UpdateCDMPreview()
        if not optState._cdmPreview and EllesmereUI._contentHeaderPreview then
            optState._cdmPreview = EllesmereUI._contentHeaderPreview
        end
        if optState._cdmPreview and optState._cdmPreview.Update then
            optState._cdmPreview:Update()
        end
    end

    local function UpdateCDMPreviewAndResize()
        UpdateCDMPreview()
        if optState._cdmPreview and optState._cdmHeaderFixedH > 0 then
            -- Wrapper height is already capped by the Update function's resize logic
            local wrapperH = optState._cdmPreview._wrapper and optState._cdmPreview._wrapper:GetHeight()
                             or math.min(optState._cdmPreview:GetHeight() * (optState._cdmPreview:GetScale() or 1), 200)
            EllesmereUI:UpdateContentHeaderHeight(optState._cdmHeaderFixedH + wrapperH)
        end
    end

    EllesmereUI:RegisterOnShow(UpdateCDMPreview)

    -- Refresh our preview when user closes Blizzard's CDM settings panel
    -- (they may have added/removed spells from the viewer)
    if CooldownViewerSettings then
        CooldownViewerSettings:HookScript("OnHide", function()
            C_Timer.After(0.3, function()
                if EllesmereUI._mainFrame and EllesmereUI._mainFrame:IsShown() then
                    EllesmereUI:RefreshPage(true)
                end
            end)
        end)
    end

    --- Get the currently selected CDM bar data
    local function SelectedCDMBar()
        local p = DB()
        if not p or not p.cdmBars or not p.cdmBars.bars then return nil end
        local bars = p.cdmBars.bars
        if optState.selectedCDMBarIndex < 1 then optState.selectedCDMBarIndex = 1 end
        if optState.selectedCDMBarIndex > #bars then optState.selectedCDMBarIndex = #bars end
        return bars[optState.selectedCDMBarIndex]
    end

    -- Active state preview on first icon
    local _cdmActivePreviewOn = false
    local _cdmActivePreviewOverlay = nil  -- glow overlay frame on first preview slot
    local _cdmActivePreviewToken = 0     -- incremented each start to invalidate stale timers

    local function StopActiveStatePreview()
        if _cdmActivePreviewOverlay then
            ns.StopNativeGlow(_cdmActivePreviewOverlay)
        end
        -- Stop fake cooldown on preview slot
        if optState._cdmPreview and optState._cdmPreview._previewSlots then
            local slot = optState._cdmPreview._previewSlots[1]
            if slot and slot._previewCD then
                slot._previewCD:Clear()
                slot._previewCD:Hide()
            end
        end
    end

    local function StartActiveStatePreview()
        if not _cdmActivePreviewOn then return end
        _cdmActivePreviewToken = _cdmActivePreviewToken + 1
        local myToken = _cdmActivePreviewToken
        local bd = SelectedCDMBar()
        if not bd then return end
        local anim = bd.activeStateAnim or "blizzard"
        if not optState._cdmPreview or not optState._cdmPreview._previewSlots then return end
        local slot = optState._cdmPreview._previewSlots[1]
        if not slot or not slot:IsShown() then return end

        -- Ensure cooldown widget exists on preview slot
        if not slot._previewCD then
            local cd = CreateFrame("Cooldown", nil, slot, "CooldownFrameTemplate")
            cd:SetAllPoints()
            cd:SetDrawEdge(false)
            cd:SetDrawSwipe(true)
            cd:SetDrawBling(false)
            cd:SetReverse(false)
            cd:SetHideCountdownNumbers(false)
            -- Blizzard Style: the viewer's rounded swipe, matching its mask
            -- (classic icons are square and keep the plain swipe).
            cd:SetSwipeTexture((EllesmereUI.BlizzStyle.Active("cdmicons") == "blizzard" and ns.CDM_BLIZZ_SWIPE)
                or "Interface\\Buttons\\WHITE8x8")
            if cd.SetSnapToPixelGrid then cd:SetSnapToPixelGrid(false); cd:SetTexelSnappingBias(0) end
            slot._previewCD = cd
        end

        -- Always refresh font (smaller than the bar's cooldown font size, shadow style)
        C_Timer.After(0, function()
            if not slot._previewCD then return end
            local fSize = (bd.cooldownFontSize or 12) - 2
            if fSize < 6 then fSize = 6 end
            local fontPath = (EllesmereUI.GetFontPath("cdm")) or STANDARD_TEXT_FONT
            for _, region in ipairs({ slot._previewCD:GetRegions() }) do
                if region:GetObjectType() == "FontString" then
                    SetPVFont(region, fontPath, fSize)
                    if ns.AnchorCooldownText then
                        ns.AnchorCooldownText(region, slot._previewCD,
                            bd.cooldownTextPosition or "center",
                            bd.cooldownTextX or 0, bd.cooldownTextY or 0)
                    end
                    break
                end
            end
        end)

        -- Ensure glow overlay exists
        if not slot._glowOverlay then
            local ov = CreateFrame("Frame", nil, slot)
            ov:SetAllPoints(slot)
            -- Above the Blizzard Style ring (+15) as on the live icons (+16).
            ov:SetFrameLevel(slot:GetFrameLevel() + (EllesmereUI.BlizzStyle.Get("cdmicons") and 16 or 3))
            ov:SetAlpha(0)
            ov._euiGlowPreview = true  -- exempt from Show Glows Only in Combat
            slot._glowOverlay = ov
        end
        _cdmActivePreviewOverlay = slot._glowOverlay

        -- Resolve active animation color
        local animR, animG, animB = 1.0, 0.85, 0.0
        if bd.activeAnimClassColor then
            local _, ct = UnitClass("player")
            if ct then local cc = RAID_CLASS_COLORS[ct]; if cc then animR, animG, animB = cc.r, cc.g, cc.b end end
        elseif bd.activeAnimR then
            animR = bd.activeAnimR; animG = bd.activeAnimG or 0.85; animB = bd.activeAnimB or 0.0
        end

        local swAlpha = bd.swipeAlpha or 0.7
        local PREVIEW_DURATION = 5  -- seconds

        if anim == "none" then
            slot._previewCD:SetSwipeColor(0, 0, 0, swAlpha)
            slot._previewCD:SetCooldown(GetTime(), PREVIEW_DURATION)
            slot._previewCD:Show()
            ns.StopNativeGlow(_cdmActivePreviewOverlay)
        else
            slot._previewCD:SetSwipeColor(animR, animG, animB, swAlpha)
            slot._previewCD:SetCooldown(GetTime(), PREVIEW_DURATION)
            slot._previewCD:Show()

            if anim ~= "blizzard" then
                local glowIdx = tonumber(anim)
                if glowIdx then
                    ns.StartNativeGlow(_cdmActivePreviewOverlay, glowIdx, animR, animG, animB, EllesmereUI.Glows.PANEL_EXTRA)
                end
            else
                ns.StopNativeGlow(_cdmActivePreviewOverlay)
            end
        end

        -- Auto-stop glow after preview duration ends
        C_Timer.After(PREVIEW_DURATION, function()
            if myToken ~= _cdmActivePreviewToken then return end
            if _cdmActivePreviewOverlay then
                ns.StopNativeGlow(_cdmActivePreviewOverlay)
            end
            if slot._previewCD then
                slot._previewCD:Clear()
                slot._previewCD:Hide()
            end
        end)
    end

    ---------------------------------------------------------------------------
    --  Spell picker dropdown (right-click on icon or click "+" button)
    ---------------------------------------------------------------------------
    -- Close the spell picker when the main EUI options panel closes
    EllesmereUI:RegisterOnHide(function()
        if optState._spellPickerMenu and optState._spellPickerMenu:IsShown() then optState._spellPickerMenu:Hide() end
    end)
    -- Normalize a spell ID to its base (undo talent overrides), and resolve
    -- a base id to its current live version (talent overrides) -- both
    -- delegate to the resident module (EllesmereUICdmSpellPicker.lua) so
    -- every consumer, including the resident keep/drop reconcile pass,
    -- shares one implementation instead of a second local copy drifting out of sync.
    local NormalizeToBase = ns.NormalizeToBase
    local ResolveToLive = ns.ResolveToLive

    -- Texture-only sibling: tracked-buff slots hold AURA ids, which carry no override
    -- when a talent replaces the spell, so the icon needs the shared resolver's spellbook
    -- bridge (+ the slot's cdID to reach linked replacement ids). Deliberately NOT folded
    -- into ResolveToLive, which also feeds learned-state/catalog membership tests (incl.
    -- the keep/drop pass) -- a bridged id there could drop a spell from a saved bar.
    -- Only the art moves; identity stays untouched.
    local function ResolveIconArt(sid, cdID)
        if not sid or sid <= 0 then return sid end
        if ns.LustPresetIconSpellID then sid = ns.LustPresetIconSpellID(sid) end
        if ns.ResolvePlaceholderIconSID then
            local live = ns.ResolvePlaceholderIconSID(sid, cdID)
            if type(live) == "number" and live > 0 then return live end
        end
        return ResolveToLive(sid)
    end

    -- Shared helpers for the pickers under CooldownManager_Options\ (loaded
    -- before this file, read when a picker opens).
    ns._CDMO_OptEnv = {
        durationPositionOrder = durationPositionOrder, durationPositionValues = durationPositionValues, FitMenuWidth = FitMenuWidth,
        FONT_PATH = FONT_PATH, GetCDMOptOutline = GetCDMOptOutline, NormalizeToBase = NormalizeToBase,
        optState = optState, RefreshCDPreview = RefreshCDPreview, ResolveToLive = ResolveToLive,
        SelectedCDMBar = SelectedCDMBar,
    }

    --- Build the live CDM bar preview in the content header (interactive)
    local function BuildCDMLivePreview(parent, yOff)
        local p = DB()
        if not p or not p.cdmBars then return 0 end

        local barData = SelectedCDMBar()
        if not barData then return 0 end

        local barKey = barData.key
        local PAD = EllesmereUI.CONTENT_PAD or 10

        -- Create preview container scale to match real in-game icon sizes
        local previewScale = UIParent:GetEffectiveScale() / parent:GetEffectiveScale()
        local localParentW = (parent:GetWidth() - PAD * 2) / previewScale
        local initH = (barData.iconSize or 36) + 10

        -- Max visible height for the preview area (in parent-space pixels)
        local PREVIEW_MAX_H = 200

        -- Wrapper frame at parent scale; holds the scroll frame and scrollbar
        local wrapper = CreateFrame("Frame", nil, parent)
        wrapper:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD, yOff)
        wrapper:SetSize(parent:GetWidth() - PAD * 2, PREVIEW_MAX_H)
        wrapper:SetClipsChildren(true)

        local pf = CreateFrame("Frame", nil, parent)
        pf:SetClipsChildren(false)
        pf:SetScale(previewScale)
        pf:SetSize(localParentW, initH)

        local sf = CreateFrame("ScrollFrame", nil, wrapper)
        sf:SetAllPoints()
        sf:SetScrollChild(pf)
        sf:EnableMouseWheel(true)

        local UpdatePVThumb = EllesmereUI.AttachSmoothScrollbar(sf, {
            step = 40, thumbMin = 20, trackParent = wrapper, topInset = 2, level = 5 })

        -- Store refs for height management after Update()
        pf._wrapper = wrapper
        pf._scrollFrame = sf
        pf._previewScale = previewScale
        pf._PREVIEW_MAX_H = PREVIEW_MAX_H
        pf._updatePVThumb = UpdatePVThumb

        -- Pixel-snap helper for the preview's effective scale
        local function Snap(val)
            local s = pf:GetEffectiveScale()
            return math.floor(val * s + 0.5) / s
        end

        -- Bar background texture (shown when barBgEnabled)
        local pvBarBg = pf:CreateTexture(nil, "BACKGROUND", nil, -8)
        pvBarBg:SetColorTexture(0, 0, 0, 0.4)  -- default; updated in refresh
        if pvBarBg.SetSnapToPixelGrid then pvBarBg:SetSnapToPixelGrid(false); pvBarBg:SetTexelSnappingBias(0) end
        pvBarBg:Hide()

        -- Interactive preview icon slots
        local MAX_PREVIEW_ICONS = 30
        local previewSlots = {}

        -- Display-only dedupe for buff bars. assignedSpells can hold a LEGACY  -- eui-style: allow comment-budget
        -- duplicate: the SAME tracked buff stored under two different spell ids (e.g.
        -- its spellID and one of its linkedSpellIDs). They are NOT base/override
        -- variants -- the link is that both ids resolve to the same Blizzard
        -- cooldownID. BOTH ids must stay in the data (routing depends on them), so
        -- collapse them in the PREVIEW only: one slot per cooldownID, remembering which
        -- assignedSpells index/indices each slot covers (for edit + remove). With no
        -- dupes this is the raw list 1:1. spellID -> cooldownID depends only on
        -- talents, so it is stable per spec: build ONCE per spec from the static
        -- category sets (spellID + overrideSpellID + linkedSpellIDs, covering buffs
        -- currently down) and reuse across refreshes. Private local fed ONLY into the
        -- dedupe -- nothing writes assignedSpells, the route map, or live frames, and
        -- the scan never runs during gameplay (pf.Update only runs with options open).
        local _buffIdToCd, _buffIdToCdSpec = nil, nil
        local function GetBuffIdToCdid()
            local specKey = (ns.GetActiveSpecKey and ns.GetActiveSpecKey()) or "?"
            if _buffIdToCdSpec == specKey then return _buffIdToCd end
            _buffIdToCdSpec = specKey
            local map
            local gcs = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet
            local gci = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo
            if gcs and gci then
                -- 0-8 covers every Midnight CooldownViewerCategory value; the
                -- Hidden pseudo-categories are negative and excluded by the range.
                for cat = 0, 8 do
                    local ids = gcs(cat, true)
                    if ids then
                        for _, cdID in ipairs(ids) do
                            local info = gci(cdID)
                            if info then
                                map = map or {}
                                if type(info.spellID) == "number" and info.spellID > 0 then map[info.spellID] = cdID end
                                if type(info.overrideSpellID) == "number" and info.overrideSpellID > 0 then map[info.overrideSpellID] = cdID end
                                if info.linkedSpellIDs then
                                    for _, l in ipairs(info.linkedSpellIDs) do
                                        if type(l) == "number" and l > 0 then map[l] = cdID end
                                    end
                                end
                            end
                        end
                    end
                end
            end
            _buffIdToCd = map
            return map
        end

        local function BuildBuffDisplayDedup(raw)
            local idToCd = GetBuffIdToCdid()
            local dispList, dispGroups, slotOf = {}, {}, {}
            for rawIdx = 1, #raw do
                local sid = raw[rawIdx]
                -- Group by cooldownID when the id maps to a tracked buff; otherwise the
                -- entry stands alone (its own slot, keyed by the spell id).
                local cd = idToCd and idToCd[sid]
                local key = cd or ("s" .. tostring(sid))
                local at = slotOf[key]
                if at then
                    local g = dispGroups[at]; g[#g + 1] = rawIdx
                else
                    dispList[#dispList + 1] = sid
                    dispGroups[#dispList] = { rawIdx }
                    slotOf[key] = #dispList
                end
            end
            return dispList, dispGroups
        end

        -- Preview display index -> underlying assignedSpells index for buff bars
        -- that collapsed a duplicate (identity when there are no dupes / not a buff bar).
        local function BuffDataIdx(displayIdx)
            local g = pf._buffDispGroups and pf._buffDispGroups[displayIdx]
            return (g and g[1]) or displayIdx
        end

        -- Drag state
        local dragSlot, dragIdx, dragGhost
        local insertIdx = nil
        local lastInsertIdx = nil
        local dragMode = nil      -- "swap" or "insert"
        local swapTargetIdx = nil -- index of icon being swapped with
        local dragEndTime = 0 -- GetTime() when drag finished, suppresses OnClick

        local function EnsureDragGhost()
            if dragGhost then return dragGhost end
            local g = CreateFrame("Frame", nil, UIParent)
            g:SetFrameStrata("TOOLTIP")
            g:SetSize(36, 36)
            g:SetAlpha(0.7)
            local tex = g:CreateTexture(nil, "ARTWORK")
            tex:SetAllPoints()
            g._icon = tex
            g:Hide()
            dragGhost = g
            return g
        end

        -- Insertion line indicator (vertical accent line between icons)
        local insertLine = pf:CreateTexture(nil, "OVERLAY", nil, 7)
        local eg = EllesmereUI.ELLESMERE_GREEN
        insertLine:SetColorTexture(eg.r, eg.g, eg.b, 0.9)
        insertLine:SetWidth(2)
        insertLine:Hide()

        -- Animation: each slot has _targetOffX, _currentOffX; lerped inside drag OnUpdate
        local ANIM_SPEED = 48
        local animRunning = false

        local function StopAnimTicker()
            animRunning = false
        end

        local function StartAnimTicker()
            animRunning = true
        end

        local function TickAnimation(dt)
            if not animRunning then return end
            local allDone = true
            for i = 1, MAX_PREVIEW_ICONS do
                local s = previewSlots[i]
                if s and s._targetOffX and s._currentOffX then
                    local diff = s._targetOffX - s._currentOffX
                    if math.abs(diff) < 0.3 then
                        s._currentOffX = s._targetOffX
                    else
                        s._currentOffX = s._currentOffX + diff * math.min(ANIM_SPEED * dt, 1)
                        allDone = false
                    end
                    if s._baseX then
                        s:ClearAllPoints()
                        PP.Point(s, "TOPLEFT", pf, "TOPLEFT", s._baseX + s._currentOffX, s._baseY)
                    end
                end
            end
            if allDone then animRunning = false end
        end

        local function ClearInsertIndicator()
            insertLine:Hide()
            insertIdx = nil
            lastInsertIdx = nil
            -- Clear swap highlight
            if swapTargetIdx then
                local s = previewSlots[swapTargetIdx]
                if s and s._hlBrd then
                    s._hlBrd:Hide()
                end
                swapTargetIdx = nil
            end
            dragMode = nil
            -- Reset all slot offsets (snap, no animation)
            StopAnimTicker()
            for i = 1, MAX_PREVIEW_ICONS do
                local s = previewSlots[i]
                if s and s._baseX then
                    s._targetOffX = 0
                    s._currentOffX = 0
                    s:ClearAllPoints()
                    PP.Point(s, "TOPLEFT", pf, "TOPLEFT", s._baseX, s._baseY)
                end
            end
        end

        --- Find drag target: swap (centered on icon) or insert (between icons)
        --- Returns mode ("swap"/"insert"), targetIdx
        --- cx, cy are in screen units (GetCursorPosition / UIParent:GetEffectiveScale)
        local function FindDragTarget(cx, cy, slotCount, fromIdx)
            local bd = SelectedCDMBar()
            if not bd then return nil, nil end
            local iconSz = bd.iconSize or 36
            -- Match the preview render: width-matched bars use a fixed icon size.
            if EllesmereUI.GetWidthMatchTarget and EllesmereUI.GetWidthMatchTarget("CDM_" .. bd.key) then iconSz = 36 end
            local spacing = bd.spacing or 2
            -- Preview always renders left-to-right regardless of bar growDirection,
            -- so drag logic must also use left-to-right ordering.
            local growLeft = false

            -- Convert cursor from screen units to pf-local units
            local pfES = pf:GetEffectiveScale()
            local uiES = UIParent:GetEffectiveScale()
            local rawCX = cx * uiES
            local rawCY = cy * uiES
            local rawPfL = pf:GetLeft() * pfES
            local rawPfT = pf:GetTop() * pfES
            local localX = (rawCX - rawPfL) / pfES
            local localY = -((rawPfT - rawCY) / pfES)

            -- Group slots into rows by _baseY
            local bestRowStart, bestRowEnd, bestRowDist = 1, slotCount, math.huge
            local rowsByY = {}
            for i = 1, slotCount do
                local s = previewSlots[i]
                if s and s:IsShown() and s._baseY then
                    local yKey = math.floor(s._baseY * 10 + 0.5)
                    if not rowsByY[yKey] then rowsByY[yKey] = { y = s._baseY, startIdx = i, endIdx = i }
                    else rowsByY[yKey].endIdx = i end
                end
            end
            for _, row in pairs(rowsByY) do
                local rowCenterY = row.y - iconSz / 2
                local d = math.abs(localY - rowCenterY)
                if d < bestRowDist then
                    bestRowDist = d; bestRowStart = row.startIdx; bestRowEnd = row.endIdx
                end
            end

            -- Check Y range
            local refSlot = previewSlots[bestRowStart]
            if not refSlot or not refSlot:IsShown() or not refSlot._baseY then return nil, nil end
            if localY > refSlot._baseY + iconSz * 0.5 or localY < refSlot._baseY - iconSz * 1.5 then return nil, nil end

            -- Build a list of slots in this row sorted by visual X (left to right on screen).
            -- With growLeft, slot indices are reversed relative to screen X order.
            local rowSlots = {}
            for i = bestRowStart, bestRowEnd do
                local s = previewSlots[i]
                if s and s:IsShown() and s._baseX then
                    rowSlots[#rowSlots + 1] = { slot = s, idx = i }
                end
            end
            -- Sort by _baseX ascending (left to right on screen)
            table.sort(rowSlots, function(a, b) return a.slot._baseX < b.slot._baseX end)

            local swapZone = iconSz * 0.2
            local blankSwapZone = iconSz * 0.45

            -- If cursor is before the leftmost slot on screen, insert at the logical start of that side
            local firstEntry = rowSlots[1]
            if firstEntry and localX < firstEntry.slot._baseX - spacing * 0.5 then
                if growLeft then
                    return "insert", firstEntry.idx + 1
                else
                    return "insert", firstEntry.idx
                end
            end

            for vi = 1, #rowSlots do
                local entry = rowSlots[vi]
                local s = entry.slot
                local i = entry.idx
                local slotL = s._baseX
                local slotR = slotL + iconSz
                local slotCX = slotL + iconSz / 2
                local isBlank = not s._icon or not s._icon:GetTexture()
                local zone = isBlank and blankSwapZone or swapZone
                if localX >= slotL - spacing * 0.5 and localX < slotR + spacing * 0.5 then
                    if i ~= fromIdx and math.abs(localX - slotCX) < zone then
                        return "swap", i
                    elseif localX < slotCX then
                        -- Cursor in the left half of this slot: insert before it logically
                        if growLeft then
                            return "insert", i + 1
                        else
                            return "insert", i
                        end
                    else
                        -- Cursor in the right half of this slot: insert after it logically
                        if growLeft then
                            return "insert", i
                        else
                            return "insert", i + 1
                        end
                    end
                end
            end

            -- Past the rightmost slot on screen: insert at the logical end of that side
            local lastEntry = rowSlots[#rowSlots]
            if lastEntry then
                if growLeft then
                    return "insert", lastEntry.idx
                else
                    return "insert", lastEntry.idx + 1
                end
            end
            return "insert", bestRowEnd + 1
        end

        --- Apply visual feedback for drag: shift icons for insert, highlight for swap
        local function ApplyDragFeedback(mode, targetIdx, fromIdx, slotCount)
            local bd = SelectedCDMBar()
            -- Preview always renders left-to-right; drag feedback must match.
            local growLeft = false

            if mode == "swap" then
                insertLine:Hide()
                if swapTargetIdx and swapTargetIdx ~= targetIdx then
                    local s = previewSlots[swapTargetIdx]
                    if s and s._hlBrd then s._hlBrd:Hide() end
                end
                if lastInsertIdx then
                    for i = 1, slotCount do
                        local s = previewSlots[i]
                        if s and s._baseX then
                            s._targetOffX = 0
                            if not s._currentOffX then s._currentOffX = 0 end
                            if i ~= fromIdx then s:SetAlpha(1) end
                        end
                    end
                    StartAnimTicker()
                    lastInsertIdx = nil
                end
                swapTargetIdx = targetIdx
                local s = previewSlots[targetIdx]
                if s and s._hlBrd then s._hlBrd:Show() end
                return
            end

            -- Insert mode: clear swap highlight first
            if swapTargetIdx then
                local s = previewSlots[swapTargetIdx]
                if s and s._hlBrd then s._hlBrd:Hide() end
                swapTargetIdx = nil
            end

            if targetIdx == lastInsertIdx then return end
            lastInsertIdx = targetIdx

            if not bd then return end
            local iconSz = bd.iconSize or 36
            -- Match the preview render: width-matched bars use a fixed icon size.
            if EllesmereUI.GetWidthMatchTarget and EllesmereUI.GetWidthMatchTarget("CDM_" .. bd.key) then iconSz = 36 end
            local spacing = bd.spacing or 2
            local nudge = math.floor((iconSz + spacing) * 0.15)

            -- With growLeft, higher index = further left on screen.
            -- Flip nudge direction so slots shift away from the gap correctly.
            local shiftTowardEnd   =  nudge
            local shiftTowardStart = -nudge
            if growLeft then
                shiftTowardEnd   = -nudge
                shiftTowardStart =  nudge
            end

            -- Determine which row the target belongs to (by _baseY).
            -- Only shift slots on that row; other rows stay still.
            local targetRowY = nil
            if targetIdx >= 1 and targetIdx <= slotCount then
                local ts = previewSlots[targetIdx]
                if ts and ts._baseY then targetRowY = ts._baseY end
            end
            -- Fallback: check the slot just before targetIdx (insert at end of row)
            if not targetRowY and targetIdx > 1 and targetIdx - 1 <= slotCount then
                local ts = previewSlots[targetIdx - 1]
                if ts and ts._baseY then targetRowY = ts._baseY end
            end

            for i = 1, slotCount do
                local s = previewSlots[i]
                if not s or not s._baseX then
                    if s then s:SetAlpha(i == fromIdx and 0.3 or 1) end
                elseif i == fromIdx then
                    s:SetAlpha(0.3)
                    s._targetOffX = 0
                    if not s._currentOffX then s._currentOffX = 0 end
                else
                    -- Only shift slots on the same row as the target
                    local onTargetRow = targetRowY and s._baseY and math.abs(s._baseY - targetRowY) < 1
                    if not onTargetRow then
                        s._targetOffX = 0
                        if not s._currentOffX then s._currentOffX = 0 end
                        s:SetAlpha(1)
                    else
                        local virtualPos = i
                        if i > fromIdx then virtualPos = i - 1 end
                        local virtualInsert = targetIdx
                        if targetIdx > fromIdx then virtualInsert = targetIdx - 1 end

                        local offX = 0
                        if virtualPos >= virtualInsert then
                            offX = shiftTowardEnd
                        else
                            offX = shiftTowardStart
                        end

                        s._targetOffX = offX
                        if not s._currentOffX then s._currentOffX = 0 end
                        s:SetAlpha(1)
                    end
                end
            end
            StartAnimTicker()

            -- Position the insertion line between the two logical neighbors
            if targetIdx and targetIdx >= 1 then
                local iconSz2 = iconSz
                local leftSlot, rightSlot  -- screen-left, screen-right
                if growLeft then
                    -- With growLeft, slot targetIdx is to the right on screen, slot targetIdx-1 is to the left
                    if targetIdx > 1 and targetIdx <= slotCount then
                        rightSlot = previewSlots[targetIdx]
                        leftSlot  = previewSlots[targetIdx - 1]
                        if targetIdx == fromIdx and targetIdx + 1 <= slotCount then
                            rightSlot = previewSlots[targetIdx + 1]
                        elseif targetIdx - 1 == fromIdx and targetIdx - 2 >= 1 then
                            leftSlot = previewSlots[targetIdx - 2]
                        end
                    elseif targetIdx <= 1 then
                        rightSlot = previewSlots[1]
                    elseif targetIdx > slotCount then
                        leftSlot = previewSlots[slotCount]
                    end
                else
                    if targetIdx > 1 and targetIdx <= slotCount then
                        leftSlot  = previewSlots[targetIdx - 1]
                        rightSlot = previewSlots[targetIdx]
                        if targetIdx - 1 == fromIdx and targetIdx - 2 >= 1 then
                            leftSlot = previewSlots[targetIdx - 2]
                        elseif targetIdx == fromIdx and targetIdx + 1 <= slotCount then
                            rightSlot = previewSlots[targetIdx + 1]
                        end
                    elseif targetIdx <= 1 then
                        rightSlot = previewSlots[1]
                    elseif targetIdx > slotCount and slotCount > 0 then
                        leftSlot = previewSlots[slotCount]
                    end
                end

                local lineX, lineY
                if leftSlot and leftSlot:IsShown() and leftSlot._baseX
                   and rightSlot and rightSlot:IsShown() and rightSlot._baseX then
                    local leftRight = leftSlot._baseX + iconSz2 - nudge
                    local rightLeft = rightSlot._baseX + nudge
                    lineX = (leftRight + rightLeft) / 2
                    lineY = rightSlot._baseY
                elseif rightSlot and rightSlot:IsShown() and rightSlot._baseX then
                    lineX = rightSlot._baseX + nudge - math.floor(spacing / 2) - 1
                    lineY = rightSlot._baseY
                elseif leftSlot and leftSlot:IsShown() and leftSlot._baseX then
                    lineX = leftSlot._baseX + iconSz2 - nudge + math.floor(spacing / 2) + 1
                    lineY = leftSlot._baseY
                end

                if lineX and lineY then
                    insertLine:ClearAllPoints()
                    PP.Point(insertLine, "TOP", pf, "TOPLEFT", lineX, lineY)
                    PP.Point(insertLine, "BOTTOM", pf, "TOPLEFT", lineX, lineY - iconSz2)
                    insertLine:Show()
                else
                    insertLine:Hide()
                end
            else
                insertLine:Hide()
            end
        end

        local function CreatePreviewSlot(idx)
            local slot = CreateFrame("Button", nil, pf)
            slot:SetSize(1, 1)
            slot:RegisterForClicks("LeftButtonUp", "RightButtonDown", "MiddleButtonDown")
            -- Expand hit area so small icons are easier to click/drag
            slot:SetHitRectInsets(-6, -6, -6, -6)
            slot:Hide()

            local sBg = slot:CreateTexture(nil, "BACKGROUND")
            sBg:SetAllPoints(); sBg:SetColorTexture(0.08, 0.08, 0.08, 0.6)
            if sBg.SetSnapToPixelGrid then sBg:SetSnapToPixelGrid(false); sBg:SetTexelSnappingBias(0) end
            slot._bg = sBg

            local sIcon = slot:CreateTexture(nil, "ARTWORK")
            sIcon:SetAllPoints()
            if sIcon.SetSnapToPixelGrid then sIcon:SetSnapToPixelGrid(false); sIcon:SetTexelSnappingBias(0) end
            slot._icon = sIcon
            slot._tex = sIcon  -- alias for shape system compatibility

            local sEdges = {}
            local PP = EllesmereUI and EllesmereUI.PP
            if PP then PP.CreateBorder(slot, 0, 0, 0, 1, 1, "OVERLAY", 7) end
            slot._edges = sEdges  -- empty; borders managed by PP

            -- Hosted-buff marker border: gold (same color as the buff "+" add button), same 2px
            -- geometry as the hover highlight, always ON for buff icons hosted on this CD/utility
            -- bar so they read apart from the cooldowns at a glance. Level +1 -- UNDER the hover highlight (+2), so hovering still shows the accent border on top.
            local slotPP = EllesmereUI and EllesmereUI.PP
            local slotHostCont = CreateFrame("Frame", nil, slot)
            slotHostCont:SetAllPoints()
            slotHostCont:SetFrameLevel(slot:GetFrameLevel() + 1)
            local hostBrd = slotPP and slotPP.CreateBorder(slotHostCont, 1, 0.82, 0.25, 1, 2, "OVERLAY", 7)
            if hostBrd then hostBrd:Hide() end
            slot._hostBrd = hostBrd
            -- Hover highlight (2px accent border, child container avoids conflict with existing PP border)
            local eg = EllesmereUI.ELLESMERE_GREEN
            local slotHlCont = CreateFrame("Frame", nil, slot)
            slotHlCont:SetAllPoints()
            slotHlCont:SetFrameLevel(slot:GetFrameLevel() + 2)
            local slotBrd = slotPP and slotPP.CreateBorder(slotHlCont, eg.r, eg.g, eg.b, 1, 2, "OVERLAY", 7)
            if slotBrd then slotBrd:Hide() end
            slot._hlBrd = slotBrd
            -- Text overlay (renders above border)
            local pvTextOvr = CreateFrame("Frame", nil, slot)
            pvTextOvr:SetAllPoints(slot)
            -- +5: the keybind badge sits two levels under this overlay (+3/+4),
            -- above the slot border (+1) and the hosted-buff marker (+2).
            pvTextOvr:SetFrameLevel(slot:GetFrameLevel() + 5)
            pvTextOvr:EnableMouse(false)
            slot._pvTextOverlay = pvTextOvr

            slot._stackText = pvTextOvr:CreateFontString(nil, "OVERLAY")
            SetPVFont(slot._stackText, FONT_PATH, 11)
            slot._stackText:SetPoint("BOTTOMRIGHT", pvTextOvr, "BOTTOMRIGHT", 0, 2)
            slot._stackText:SetJustifyH("RIGHT")
            slot._stackText:Hide()
            local stackTxt = slot._stackText

            -- Keybind text (mirrors _keybindText on real CDM icons)
            local kbTxt = pvTextOvr:CreateFontString(nil, "OVERLAY")
            SetPVFont(kbTxt, FONT_PATH, 9)
            kbTxt:SetPoint("TOPLEFT", pvTextOvr, "TOPLEFT", 2, -2)
            kbTxt:SetJustifyH("LEFT")
            kbTxt:Hide()
            slot._keybindText = kbTxt

            slot:SetScript("OnEnter", function()
                if dragSlot then return end
                local bdHov = SelectedCDMBar()
                -- Custom shapes: tint the shape border instead of square edges
                if slot._shapeBorder and slot._shapeBorder:IsShown() then
                    slot._shapeBorder:SetVertexColor(eg.r, eg.g, eg.b, 1)
                else
                    if slotBrd then slotBrd:Show() end
                end
            end)
            slot:SetScript("OnLeave", function()
                if dragSlot then return end
                local bdHov = SelectedCDMBar()
                if slot._shapeBorder and slot._shapeBorder:IsShown() then
                    if slot._previewHostedBuff then
                        -- Hosted buff: restore the persistent gold tint, not
                        -- the bar border color.
                        slot._shapeBorder:SetVertexColor(1, 0.82, 0.25, 1)
                    else
                        local bR, bG, bB = 0, 0, 0
                        if bdHov then
                            bR, bG, bB = bdHov.borderR or 0, bdHov.borderG or 0, bdHov.borderB or 0
                            if bdHov.borderClassColor then
                                local _, ct = UnitClass("player")
                                if ct then
                                    local cc = RAID_CLASS_COLORS[ct]
                                    if cc then bR, bG, bB = cc.r, cc.g, cc.b end
                                end
                            end
                        end
                        slot._shapeBorder:SetVertexColor(bR, bG, bB, 1)
                    end
                else
                    if slotBrd then slotBrd:Hide() end
                end
            end)

            slot._slotIdx = idx

            -- Right-click: spell picker to replace; Middle-click: remove
            -- Default buff bar: no interaction (Blizzard controls the list)
            slot:SetScript("OnClick", function(self, button)
                if GetTime() - dragEndTime < 0.2 then
                    return
                end
                -- Override editing sessions: per-spell settings and spell
                -- placement are never part of the override system -- refuse
                -- the interaction with an explanatory tooltip.
                if EllesmereUI.SpecOverrides_EditSessionActive() then
                    EllesmereUI.ShowWidgetTooltip(self,
                        "Per-spell settings are not part of the override system.")
                    return
                end
                local bd = SelectedCDMBar()
                if not bd then return end
                local isDefaultBuffs = (bd.key == "buffs")

                if button == "MiddleButton" then
                    local si = self._slotIdx
                    -- A per-icon settings dropdown may be open (anchored to this or
                    -- another slot). A remove reshuffles the preview slots, so any
                    -- open dropdown is about to point at the wrong spell -- close it.
                    if optState._spellPickerMenu and optState._spellPickerMenu:IsShown() then
                        optState._spellPickerMenu:Hide()
                    end
                    if isDefaultBuffs then
                        -- Custom item slot (negative -itemID marker): remove it
                        -- directly. slotIndex maps to the mixed preview list, so
                        -- key off the marker, not assignedSpells[si].
                        if self._previewItemID then
                            ns.RemoveSpellFromBar(bd.key, -self._previewItemID)
                            if ns.RebuildSpellRouteMap then ns.RebuildSpellRouteMap() end
                            if ns.QueueReanchor then ns.QueueReanchor() end
                            RefreshCDPreview()
                            return
                        end
                        -- Main buffs bar: only injected custom/preset buffs can be deleted
                        -- (Blizzard-tracked buffs are managed in Blizzard's CDM). Remove by spellID since slotIndex maps to the mixed preview list (Blizzard buffs + customs), not assignedSpells.
                        local sid = self._previewSpellID
                        if not sid then return end
                        local sdMid = ns.GetBarSpellData(bd.key)
                        local isInj = sdMid and (
                            (sdMid.spellDurations and (sdMid.spellDurations[sid] or 0) > 0)
                            or (sdMid.customSpellIDs and sdMid.customSpellIDs[sid]))
                        if not isInj then return end
                        ns.RemoveSpellFromBar(bd.key, sid)
                        if sdMid.spellDurations then sdMid.spellDurations[sid] = nil end
                        if ns.RebuildSpellRouteMap then ns.RebuildSpellRouteMap() end
                        if ns.QueueReanchor then ns.QueueReanchor() end
                        RefreshCDPreview()
                        return
                    end
                    local sdMid = ns.CDMO_EnsureAssignedSpells(bd.key)
                    if not sdMid or not sdMid.assignedSpells then return end
                    local t = sdMid.assignedSpells
                    -- Remove every assignedSpells entry collapsed into this preview slot. A legacy
                    -- duplicate buff maps >1 stored id to one slot; a normal slot maps exactly one (plain remove). Highest index first keeps the lower indices valid across removes.
                    local grp = (pf._buffDispGroups and pf._buffDispGroups[si]) or { si }
                    local order = {}
                    for _, v in ipairs(grp) do order[#order + 1] = v end
                    table.sort(order, function(a, b) return a > b end)
                    local removedAny = false
                    for _, idx in ipairs(order) do
                        if t[idx] and t[idx] ~= 0 then
                            ns.RemoveTrackedSpell(bd.key, idx)
                            removedAny = true
                        end
                    end
                    if not removedAny then return end
                    RefreshCDPreview()
                elseif button == "RightButton" or button == "LeftButton" then
                    local si = self._slotIdx
                    -- Custom item slots (default buffs bar) have no per-icon settings and don't
                    -- map to assignedSpells[si]; middle-click removes them. Ignore left/right-click to avoid a mis-indexed settings menu.
                    if isDefaultBuffs and self._previewItemID then return end
                    -- Translate the preview slot to its underlying assignedSpells index (identity
                    -- unless this buff slot collapsed a duplicate).
                    local dataIdx = BuffDataIdx(si)
                    -- A slot is configurable if it maps to an assignedSpells entry OR (default
                    -- buffs bar mirror) exposes a live spellID. The per-icon settings menu keys off whichever is present.
                    local sdClick = ns.GetBarSpellData(bd.key)
                    local hasAssigned = sdClick and sdClick.assignedSpells
                        and sdClick.assignedSpells[dataIdx] and sdClick.assignedSpells[dataIdx] ~= 0
                    if not hasAssigned and not self._previewSpellID then return end

                    -- Show remove-only dropdown (per-icon settings + Remove)
                    ns.CDMO_ShowSpellPicker(self, bd.key, dataIdx, {}, function()
                        -- onSelect unused -- remove is handled inside ShowSpellPicker
                    end, true)  -- removeOnly flag
                end
            end)

            -- Manual drag detection: bypasses WoW's large built-in drag threshold
            local DRAG_THRESHOLD = 3  -- pixels of mouse movement before drag starts
            local pendingDragSlot, pendingStartX, pendingStartY

            -- After a drag ends, refresh hover highlights based on current cursor position
            local function RefreshHoverHighlight()
                local bd = SelectedCDMBar()
                local bR, bG, bB = 0, 0, 0
                if bd then
                    bR, bG, bB = bd.borderR or 0, bd.borderG or 0, bd.borderB or 0
                    if bd.borderClassColor then
                        local _, ct = UnitClass("player")
                        if ct then
                            local cc = RAID_CLASS_COLORS[ct]
                            if cc then bR, bG, bB = cc.r, cc.g, cc.b end
                        end
                    end
                end
                for i = 1, MAX_PREVIEW_ICONS do
                    local s = previewSlots[i]
                    if s then
                        local hovered = s:IsShown() and s:IsMouseOver()
                        local hasShape = s._shapeBorder and s._shapeBorder:IsShown()
                        if hasShape then
                            if hovered then
                                s._shapeBorder:SetVertexColor(eg.r, eg.g, eg.b, 1)
                            else
                                s._shapeBorder:SetVertexColor(bR, bG, bB, 1)
                            end
                        elseif s._hlBrd then
                            if hovered then
                                s._hlBrd:Show()
                            else
                                s._hlBrd:Hide()
                            end
                        end
                    end
                end
            end

            -- Drop handler: called when mouse is released during a drag
            local function FinishDrag()
                if not dragSlot then return end
                local self = dragSlot
                local bd = SelectedCDMBar()
                if dragGhost then dragGhost:Hide() end
                self:SetAlpha(1)
                self:SetFrameLevel(pf:GetFrameLevel() + 1)
                local didChange = false
                if insertIdx and bd then
                    local oldPos = {}
                    for i = 1, MAX_PREVIEW_ICONS do
                        local s = previewSlots[i]
                        if s and s:IsShown() and s._baseX then
                            local tex = s._icon and s._icon:GetTexture()
                            if tex then oldPos[tex] = s._baseX + (s._currentOffX or 0) end
                        end
                    end

                    -- Default buffs bar reorders a dedicated display-order array (canon ids)
                    -- instead of assignedSpells, which it shares with routing/custom injection. Seed it from the rendered order on the first drag so index-based moves line up with the preview.
                    local isDefBuffs = (bd.key == "buffs")
                    if isDefBuffs then
                        local sdBuf = ns.GetBarSpellData("buffs")
                        if sdBuf and not (sdBuf.buffDisplayOrder and #sdBuf.buffDisplayOrder > 0) then
                            local snap = pf._buffTrackedOrder
                            if snap and #snap > 0 then
                                local copy = {}
                                for i = 1, #snap do copy[i] = snap[i] end
                                sdBuf.buffDisplayOrder = copy
                            end
                        end
                    end
                    -- Resolved index refuses the commit when out of range (drag snaps back, no
                    -- write). Cd-claimed collided-buff slots carry a real assignedSpells index (a cd-claim marker, see ns.CdClaimMarker) same as any other entry, so no special-casing needed here.
                    local function SafeDataIdx(dispIdx)
                        local di = BuffDataIdx(dispIdx)
                        local sdChk = ns.GetBarSpellData and ns.GetBarSpellData(bd.key)
                        local n = sdChk and sdChk.assignedSpells and #sdChk.assignedSpells or 0
                        if di < 1 or di > n then return nil end
                        return di
                    end
                    if dragMode == "swap" then
                        if insertIdx ~= dragIdx then
                            if isDefBuffs then
                                -- Slot -> stable-key translation: buffDisplayOrder
                                -- keeps absent (talent-gapped) keys in place, so
                                -- slot indices cannot address it directly.
                                local sk = pf._buffSlotKeys
                                if sk and ns.SwapBuffDisplayKeys
                                   and ns.SwapBuffDisplayKeys(sk[dragIdx], sk[insertIdx]) then
                                    didChange = true
                                end
                            else
                                local a, b = SafeDataIdx(dragIdx), SafeDataIdx(insertIdx)
                                if a and b then
                                    ns.SwapTrackedSpells(bd.key, a, b)
                                    didChange = true
                                end
                            end
                        end
                    else
                        local toIdx = insertIdx
                        if toIdx > dragIdx then toIdx = toIdx - 1 end
                        if toIdx ~= dragIdx then
                            if isDefBuffs then
                                local sk = pf._buffSlotKeys
                                if sk and ns.MoveBuffDisplayKey then
                                    -- Final rendered position toIdx = insert before
                                    -- the key at toIdx among the OTHER rendered keys
                                    -- (nil past the end = append after everything).
                                    local rk, n = {}, 0
                                    for i = 1, #sk do
                                        if i ~= dragIdx then n = n + 1; rk[n] = sk[i] end
                                    end
                                    if ns.MoveBuffDisplayKey(sk[dragIdx], rk[toIdx]) then
                                        didChange = true
                                    end
                                end
                            else
                                local a, b = SafeDataIdx(dragIdx), SafeDataIdx(toIdx)
                                if a and b then
                                    ns.MoveTrackedSpell(bd.key, a, b)
                                    didChange = true
                                end
                            end
                        end
                    end

                    if didChange then
                        local droppedIdx
                        if dragMode == "swap" then
                            droppedIdx = insertIdx
                        else
                            local toIdx = insertIdx
                            if toIdx > dragIdx then toIdx = toIdx - 1 end
                            droppedIdx = toIdx
                        end

                        insertLine:Hide()
                        if swapTargetIdx then
                            local sw = previewSlots[swapTargetIdx]
                            if sw and sw._hlBrd then sw._hlBrd:Hide() end
                            swapTargetIdx = nil
                        end

                        for i = 1, MAX_PREVIEW_ICONS do
                            local s = previewSlots[i]
                            if s then s._targetOffX = nil; s._currentOffX = nil end
                        end
                        animRunning = false

                        Refresh()
                        if pf.Update then pf:Update() end
                        UpdateCDMPreviewAndResize()

                        for i = 1, MAX_PREVIEW_ICONS do
                            local s = previewSlots[i]
                            if s and s:IsShown() and s._baseX then
                                if i == droppedIdx then
                                    s._currentOffX = 0
                                    s._targetOffX = 0
                                else
                                    local tex = s._icon and s._icon:GetTexture()
                                    if tex and oldPos[tex] then
                                        local diff = oldPos[tex] - s._baseX
                                        if math.abs(diff) > 0.5 then
                                            s._currentOffX = diff
                                            s._targetOffX = 0
                                        else
                                            s._currentOffX = 0
                                            s._targetOffX = 0
                                        end
                                    else
                                        s._currentOffX = 0
                                        s._targetOffX = 0
                                    end
                                end
                            end
                        end
                        animRunning = true
                        pf:SetScript("OnUpdate", function(_, dt)
                            TickAnimation(dt)
                            if not animRunning then
                                pf:SetScript("OnUpdate", nil)
                            end
                        end)
                        dragSlot = nil; dragIdx = nil; insertIdx = nil; dragMode = nil
                        dragEndTime = GetTime()
                        RefreshHoverHighlight()
                        return
                    end
                end
                ClearInsertIndicator()
                dragSlot = nil; dragIdx = nil; insertIdx = nil; dragMode = nil
                dragEndTime = GetTime()
                pf:SetScript("OnUpdate", nil)
                RefreshHoverHighlight()
            end

            local function BeginDrag(self)
                local bd = SelectedCDMBar()
                if not bd then return end
                local sdDrag = ns.GetBarSpellData(bd.key)
                local si = self._slotIdx
                if bd.key == "buffs" then
                    -- Default bar: a slot is draggable if it renders a buff
                    -- (_previewSpellID / a rendered stable key). buffDisplayOrder
                    -- is NOT indexed by slot -- it keeps absent keys in place.
                    if not self._previewSpellID
                       and not (pf._buffSlotKeys and pf._buffSlotKeys[si]) then return end
                else
                    local t = sdDrag and sdDrag.assignedSpells or {}
                    local di = BuffDataIdx(si)
                    if not t[di] or t[di] == 0 then return end
                end
                dragSlot = self; dragIdx = si
                -- Clear hover highlight on the dragged slot
                if self._shapeBorder and self._shapeBorder:IsShown() then
                    local bd2 = SelectedCDMBar()
                    local bR2, bG2, bB2 = 0, 0, 0
                    if bd2 then
                        bR2, bG2, bB2 = bd2.borderR or 0, bd2.borderG or 0, bd2.borderB or 0
                        if bd2.borderClassColor then
                            local _, ct = UnitClass("player")
                            if ct then
                                local cc = RAID_CLASS_COLORS[ct]
                                if cc then bR2, bG2, bB2 = cc.r, cc.g, cc.b end
                            end
                        end
                    end
                    self._shapeBorder:SetVertexColor(bR2, bG2, bB2, 1)
                elseif self._hlBrd then
                    self._hlBrd:Hide()
                end
                local ghost = EnsureDragGhost()
                local iSz = bd.iconSize or 36
                ghost:SetSize(iSz, iSz)
                ghost._icon:SetTexture(self._icon:GetTexture())
                local zm = bd.iconZoom or 0.08
                ghost._icon:SetTexCoord(zm, 1 - zm, zm, 1 - zm)
                ghost:SetScale(0.5)
                ghost:Show()
                self:SetAlpha(0.3)
                self:SetFrameLevel(pf:GetFrameLevel())
                -- Start cursor tracking + mouse-up detection
                pf:SetScript("OnUpdate", function(_, dt)
                    -- Detect mouse release
                    if not IsMouseButtonDown("LeftButton") then
                        pf:SetScript("OnUpdate", nil)
                        FinishDrag()
                        return
                    end
                    if not dragGhost or not dragGhost:IsShown() then return end
                    local cx, cy = GetCursorPosition()
                    local sc = UIParent:GetEffectiveScale()
                    cx, cy = cx / sc, cy / sc
                    local gs = dragGhost:GetScale() or 1
                    dragGhost:ClearAllPoints()
                    dragGhost:SetPoint("CENTER", UIParent, "BOTTOMLEFT", cx / gs, cy / gs)
                    TickAnimation(dt)
                    local tBd = SelectedCDMBar()
                    local tCount = 0
                    if tBd then
                        local sdT = ns.GetBarSpellData(tBd.key)
                        if tBd.key == "buffs" then
                            -- Rendered slot count, NOT #buffDisplayOrder: the stored
                            -- order keeps absent keys and can exceed what is shown.
                            if pf._buffSlotKeys then tCount = #pf._buffSlotKeys end
                        elseif sdT and sdT.assignedSpells then
                            tCount = #sdT.assignedSpells
                        end
                    end
                    local visCount = pf._gridSlots or tCount
                    local newMode, newTarget = FindDragTarget(cx, cy, visCount, dragIdx)
                    if newMode and newTarget then
                        local isNoop = false
                        if newMode == "insert" then
                            local effTo = newTarget
                            if effTo > dragIdx then effTo = effTo - 1 end
                            if effTo == dragIdx then isNoop = true end
                        elseif newMode == "swap" and newTarget == dragIdx then
                            isNoop = true
                        end
                        if isNoop then
                            ClearInsertIndicator()
                        else
                            dragMode = newMode
                            ApplyDragFeedback(newMode, newTarget, dragIdx, visCount)
                            insertIdx = newTarget
                        end
                    else
                        ClearInsertIndicator()
                    end
                end)
            end

            slot:SetScript("OnMouseDown", function(self, button)
                if button ~= "LeftButton" then return end
                -- Override editing sessions: spell placement never overrides.
                if EllesmereUI.SpecOverrides_EditSessionActive() then
                    EllesmereUI.ShowWidgetTooltip(self,
                        "Per-spell settings are not part of the override system.")
                    return
                end
                -- Buff-family drag-reorder: extra/custom buff bars reorder via
                -- assignedSpells (1:1 preview), the default buffs bar via its
                -- dedicated buffDisplayOrder (stable cooldownID-keyed, reconciled
                -- from the live viewer pool). Only FocusKick stays locked -- its
                -- icon order is driven by nameplate state, not user order.
                local bdDrag = SelectedCDMBar()
                if bdDrag and bdDrag.key == ns.FOCUSKICK_BAR_KEY then return end
                local cx, cy = GetCursorPosition()
                pendingDragSlot = self
                pendingStartX = cx
                pendingStartY = cy
                -- Use a lightweight OnUpdate to detect threshold
                self:SetScript("OnUpdate", function()
                    if not pendingDragSlot then self:SetScript("OnUpdate", nil); return end
                    local nx, ny = GetCursorPosition()
                    local dx = nx - pendingStartX
                    local dy = ny - pendingStartY
                    if dx * dx + dy * dy >= DRAG_THRESHOLD * DRAG_THRESHOLD then
                        local s = pendingDragSlot
                        pendingDragSlot = nil
                        self:SetScript("OnUpdate", nil)
                        BeginDrag(s)
                    end
                end)
            end)

            slot:SetScript("OnMouseUp", function(self, button)
                if button == "LeftButton" and pendingDragSlot then
                    -- Mouse released before threshold not a drag, let OnClick handle it
                    pendingDragSlot = nil
                    self:SetScript("OnUpdate", nil)
                end
            end)

            return slot
        end

        for i = 1, MAX_PREVIEW_ICONS do
            previewSlots[i] = CreatePreviewSlot(i)
        end

        -- "+" button to add new spells
        local addBtn = CreateFrame("Button", nil, pf)
        PP.Size(addBtn, 36, 36); addBtn:Hide()
        local addBg = addBtn:CreateTexture(nil, "BACKGROUND")
        addBg:SetAllPoints(); addBg:SetColorTexture(0.08, 0.08, 0.08, 0.6)
        if addBg.SetSnapToPixelGrid then addBg:SetSnapToPixelGrid(false); addBg:SetTexelSnappingBias(0) end
        if PP then PP.CreateBorder(addBtn, 0.3, 0.3, 0.3, 0.5, 1, "OVERLAY", 7) end
        local addLbl = addBtn:CreateFontString(nil, "OVERLAY")
        addLbl:SetFont(FONT_PATH, 22, GetCDMOptOutline())
        addLbl:SetPoint("CENTER", 0, 1)
        addLbl:SetText("+")

        -- Hover highlight for add button (2px accent border, same as slots)
        local eg = EllesmereUI.ELLESMERE_GREEN
        local addHlCont = CreateFrame("Frame", nil, addBtn)
        addHlCont:SetAllPoints()
        addHlCont:SetFrameLevel(addBtn:GetFrameLevel() + 1)
        local addPP = EllesmereUI and EllesmereUI.PP
        local addBrd = addPP and addPP.CreateBorder(addHlCont, eg.r, eg.g, eg.b, 1, 2, "OVERLAY", 7)
        if addBrd then addBrd:Hide() end

        addBtn:SetScript("OnEnter", function()
            local ar, ag, ab = EllesmereUI.GetAccentColor()
            addLbl:SetTextColor(ar, ag, ab, 1)
            if addBrd then addBrd:Show() end
            if EllesmereUI.ShowWidgetTooltip then
                -- This same button adds buffs on buff-family bars, so the tip
                -- follows the selected bar rather than hard-coding CD/Utility.
                local bdHov = SelectedCDMBar()
                local tip
                if bdHov and ns.IsBarBuffFamily(bdHov) then
                    tip = "Add a Buff Spell"
                else
                    tip = "Add a CD/Utility Spell"
                end
                EllesmereUI.ShowWidgetTooltip(addBtn, EllesmereUI.L(tip))
            end
        end)
        addBtn:SetScript("OnLeave", function()
            local ar, ag, ab = EllesmereUI.GetAccentColor()
            addLbl:SetTextColor(ar, ag, ab, 0.6)
            if addBrd then addBrd:Hide() end
            EllesmereUI.HideWidgetTooltip()
        end)
        addBtn:SetScript("OnClick", function(self)
            local bd = SelectedCDMBar()
            if not bd then return end

            -- Shared post-add finalization for ALL families (buff + CD/util). Forces an
            -- immediate reanchor so source bars (where the spell got auto-removed from) re-render without waiting for the throttled queue. Then schedules a +0.05s preview refresh.
            local function FinalizeAdd()
                if ns.CollectAndReanchor then ns.CollectAndReanchor() end
                C_Timer.After(0.05, function()
                    if ns.CDMApplyVisibility then ns.CDMApplyVisibility() end
                    if pf.Update then pf:Update() end
                    UpdateCDMPreviewAndResize()
                end)
            end

            if ns.IsBarBuffFamily(bd) then
                -- Buff bars use ShowBuffBarPicker (walks the BuffIcon viewer pool). Click routes
                -- AddTrackedSpell -- the family sweep removes the spell from every other buff-family bar (including the ghost hidden bar, the "unhide" step) before claiming it for bd.key.
                ns.CDMO_ShowBuffBarPicker(self, bd.key, function(newSpellID, newCdID)
                    if newSpellID then
                        -- Collided pair (two viewer slots, one shared spellID): claim by cooldownID
                        -- so each slot is addable on its own. Non-collided buffs keep the sid path -- spellID identity survives talent swaps, cooldownIDs drift.
                        if newCdID and ns.IsCollidedBuffSid
                           and ns.IsCollidedBuffSid(newSpellID)
                           and ns.AddTrackedBuffByCdID then
                            ns.AddTrackedBuffByCdID(bd.key, newCdID)
                        else
                            ns.AddTrackedSpell(bd.key, newSpellID)
                        end
                    end
                    FinalizeAdd()
                end)
            else
                -- CD/utility bars use ShowSpellPicker.
                local sdAdd = ns.CDMO_EnsureAssignedSpells(bd.key)
                local excl = {}
                local _FindOvr = C_SpellBook and C_SpellBook.FindSpellOverrideByID
                if sdAdd and sdAdd.assignedSpells then
                    for _, sid in ipairs(sdAdd.assignedSpells) do
                        excl[sid] = true
                        -- Also exclude override forms so transformed spells
                        -- (e.g. Lay on Hands 633 -> 471195) are recognized.
                        if _FindOvr and sid > 0 then
                            local ovr = _FindOvr(sid)
                            if ovr and ovr > 0 then excl[ovr] = true end
                        end
                    end
                end
                ns.CDMO_ShowSpellPicker(self, bd.key, nil, excl, function(newSpellID, isExtra)
                    ns.AddTrackedSpell(bd.key, newSpellID, isExtra)
                    FinalizeAdd()
                end)
            end
        end)

        -- Second "+" button: add a BUFF to this CD/utility bar (buff-family bars keep the single
        -- "+" above). A buff placed here renders as a regular CD/utility icon whose gold Active
        -- State is driven by its aura. Gold-tinted so it reads apart from the standard add button; shown for CD/util only.
        local BUFF_ADD_R, BUFF_ADD_G, BUFF_ADD_B = 1, 0.82, 0.25
        local buffAddBtn = CreateFrame("Button", nil, pf)
        PP.Size(buffAddBtn, 36, 36); buffAddBtn:Hide()
        local buffAddBg = buffAddBtn:CreateTexture(nil, "BACKGROUND")
        buffAddBg:SetAllPoints(); buffAddBg:SetColorTexture(0.08, 0.08, 0.08, 0.6)
        if buffAddBg.SetSnapToPixelGrid then buffAddBg:SetSnapToPixelGrid(false); buffAddBg:SetTexelSnappingBias(0) end
        -- Resting border matches the standard add button (neutral gray, not gold) -- the gold "+" glyph alone marks this as the buff-add button.
        if PP then PP.CreateBorder(buffAddBtn, 0.3, 0.3, 0.3, 0.5, 1, "OVERLAY", 7) end
        local buffAddLbl = buffAddBtn:CreateFontString(nil, "OVERLAY")
        buffAddLbl:SetFont(FONT_PATH, 22, GetCDMOptOutline())
        buffAddLbl:SetPoint("CENTER", 0, 1)
        buffAddLbl:SetText("+")
        buffAddLbl:SetTextColor(BUFF_ADD_R, BUFF_ADD_G, BUFF_ADD_B, 0.7)

        local buffAddHlCont = CreateFrame("Frame", nil, buffAddBtn)
        buffAddHlCont:SetAllPoints()
        buffAddHlCont:SetFrameLevel(buffAddBtn:GetFrameLevel() + 1)
        local buffAddBrd = EllesmereUI and EllesmereUI.PP
            and EllesmereUI.PP.CreateBorder(buffAddHlCont, BUFF_ADD_R, BUFF_ADD_G, BUFF_ADD_B, 1, 2, "OVERLAY", 7)
        if buffAddBrd then buffAddBrd:Hide() end

        buffAddBtn:SetScript("OnEnter", function()
            buffAddLbl:SetTextColor(BUFF_ADD_R, BUFF_ADD_G, BUFF_ADD_B, 1)
            if buffAddBrd then buffAddBrd:Show() end
            EllesmereUI.ShowWidgetTooltip(buffAddBtn, EllesmereUI.L("Add a Buff Spell"))
        end)
        buffAddBtn:SetScript("OnLeave", function()
            buffAddLbl:SetTextColor(BUFF_ADD_R, BUFF_ADD_G, BUFF_ADD_B, 0.7)
            if buffAddBrd then buffAddBrd:Hide() end
            EllesmereUI.HideWidgetTooltip()
        end)
        buffAddBtn:SetScript("OnClick", function(self)
            local bd = SelectedCDMBar()
            if not bd then return end
            -- CD/utility bars only (defensive: the button is hidden elsewhere).
            if ns.IsBarBuffFamily(bd) or bd.barType == "custom_buff" then return end
            ns.CDMO_ShowBuffToCDPicker(self, bd.key, function()
                if ns.CollectAndReanchor then ns.CollectAndReanchor() end
                -- The buff-mirror walk (10Hz) binds to the freshly-created icon on
                -- its own next tick; no re-arm needed.
                C_Timer.After(0.05, function()
                    if ns.CDMApplyVisibility then ns.CDMApplyVisibility() end
                    if pf.Update then pf:Update() end
                    UpdateCDMPreviewAndResize()
                end)
            end)
        end)

        -- Update: mirrors tracked spells with interactive slots
        pf.Update = function(self)
            local bd = SelectedCDMBar()
            if not bd then
                for i = 1, MAX_PREVIEW_ICONS do previewSlots[i]:Hide() end
                addBtn:Hide(); buffAddBtn:Hide(); self:SetHeight(1); return
            end

            local iconSize = bd.iconSize or 36
            -- Width-matched bars derive their real icon size from the matched target, so
            -- bd.iconSize (the disabled Icon Scale value) is ignored at runtime. Show a neutral fixed size in the preview rather than the stale scale value.
            if EllesmereUI.GetWidthMatchTarget and EllesmereUI.GetWidthMatchTarget("CDM_" .. bd.key) then iconSize = 36 end
            local iconH = iconSize
            local pvShape = bd.iconShape or "none"
            if pvShape == "cropped" then
                iconH = math.floor(iconSize * ns.CdmCropFactor(bd) + 0.5)
            end
            local spacing  = bd.spacing or 2
            local zoom     = bd.iconZoom or 0.08
            local grow     = bd.growDirection or "RIGHT"
            local numRows  = bd.numRows or 1
            if numRows < 1 then numRows = 1 end

            local isBuffBar = ns.IsBarBuffFamily(bd)
            local isCustomBuffBar = (bd.barType == "custom_buff")
            local isFocusKick = (bd.key == "focuskick")

            -- All bars read from assignedSpells (user intent). The DEFAULT buff bar enumerates
            -- the viewer pool directly so the preview shows every tracked buff regardless of active state, minus spells diverted to other buff-family bars.
            local tracked
            -- Parallel to `tracked` for the default buffs bar: the stable viewer cooldownID for
            -- each Blizzard-tracked buff (nil for custom/injected entries). Per-icon buff settings MUST key off the cooldownID-derived stable spellID, never the live aura GetSpellID (secret/variant-drift).
            local trackedCd
            pf._buffDispGroups = nil
            pf._buffSlotKeys = nil
            if bd.key == "buffs" then
                if ns.ReconcileBuffDisplayOrder then ns.ReconcileBuffDisplayOrder() end
                local entries = ns.CollectDefaultBuffTrackEntries
                    and ns.CollectDefaultBuffTrackEntries() or {}
                tracked = {}
                trackedCd = {}
                local sdBuf = ns.GetBarSpellData("buffs")
                local order = sdBuf and sdBuf.buffDisplayOrder
                local byKey = {}
                for _, e in ipairs(entries) do byKey[e.key] = e end
                local finalKeys = {}
                if order and #order > 0 then
                    for _, key in ipairs(order) do finalKeys[#finalKeys + 1] = key end
                else
                    for _, e in ipairs(entries) do finalKeys[#finalKeys + 1] = e.key end
                end
                -- Rendered slot i <-> stable key map for the drag/reorder code: absent
                -- (talent-gapped) keys stay in buffDisplayOrder but render no slot, so slot indices cannot address the array directly.
                local slotKeys = {}
                for _, key in ipairs(finalKeys) do
                    local e = byKey[key]
                    if e then
                        tracked[#tracked + 1] = e.sid
                        trackedCd[#tracked] = e.cdID
                        slotKeys[#tracked] = key
                    end
                end
                pf._buffSlotKeys = slotKeys
                local snap = {}
                for i = 1, #finalKeys do snap[i] = finalKeys[i] end
                pf._buffTrackedOrder = snap
            else
                local sdUpd = ns.CDMO_EnsureAssignedSpells(bd.key)
                local raw = sdUpd and sdUpd.assignedSpells or {}
                if isBuffBar then
                    -- Collapse legacy duplicate buff ids in the PREVIEW only (stored data is left
                    -- intact so routing is untouched).
                    tracked, pf._buffDispGroups = BuildBuffDisplayDedup(raw)
                    -- Resolve cooldownID-level claims (collided buffs tracked by slot, a cd-claim
                    -- marker embedded in assignedSpells -- see ns.CdClaimMarker) to their display
                    -- sid IN PLACE, at the marker's own position in `tracked`, so the claim's
                    -- preview slot -- and therefore its drag/reorder position -- falls directly out of its assignedSpells index, same as any other entry.
                    for i = 1, #tracked do
                        local cdID = ns.CdClaimMarkerToCdID(tracked[i])
                        if cdID then
                            local csid = ns._cdmCleanSidByCDID and ns._cdmCleanSidByCDID[cdID]
                            if not (type(csid) == "number" and csid > 0) then
                                -- Clean cache not primed yet (fresh login, buff
                                -- active since): fall back to cooldownInfo. Each
                                -- field is vetted on its own -- never `or`-chain
                                -- possibly-secret values (truthiness taints).
                                local gci = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo
                                local info = gci and gci(cdID)
                                local raw2 = info and info.overrideSpellID
                                if not (type(raw2) == "number"
                                        and not (issecretvalue and issecretvalue(raw2))
                                        and raw2 > 0) then
                                    raw2 = info and info.spellID
                                end
                                if type(raw2) == "number"
                                   and not (issecretvalue and issecretvalue(raw2))
                                   and raw2 > 0 then
                                    csid = raw2
                                end
                            end
                            if type(csid) == "number" and csid > 0 then
                                tracked[i] = csid
                                trackedCd = trackedCd or {}
                                trackedCd[i] = cdID
                            end
                        end
                    end
                else
                    tracked = raw
                end
            end
            -- Tracked-but-unlearned spells (assigned or materialized) render
            -- desaturated so it's obvious they aren't currently talented.
            -- CD/utility bars only: buff-family lists come from live pools
            -- (always learned), and custom-buff / focuskick ids are arbitrary
            -- spell ids IsPlayerSpell can't vouch for.
            local unlearnedSet
            -- Talent Conditions (same CD/utility gate): assigned id -> "on" (conditions
            -- hold) / "off" (not met: renders dimmed like an unlearned spell, so it can
            -- still be right-clicked). nil for non-users and on WoW Forever (no menu row there).
            local tcSet
            if bd.key ~= "buffs" and not isBuffBar and not isCustomBuffBar
               and not isFocusKick and IsPlayerSpell then
                if ns._cdmAnyTalentCond and not EllesmereUI.IS_FOREVER then
                    tcSet = ns.TalentCondPreviewSet(bd.key, tracked)
                end
                local sdUn = ns.GetBarSpellData(bd.key)
                local customUn  = sdUn and sdUn.customSpellIDs
                local cdursUn   = sdUn and sdUn.customSpellDurations
                local sdursUn   = sdUn and sdUn.spellDurations
                local groupsUn  = sdUn and sdUn.customSpellGroups
                local racialsUn = ns._myRacialsSet
                for _, id in ipairs(tracked) do
                    if type(id) == "number" and id > 0
                       and not (customUn and customUn[id])
                       and not (racialsUn and racialsUn[id])
                       and not (cdursUn and cdursUn[id])
                       and not (sdursUn and sdursUn[id])
                       and not (groupsUn and groupsUn[id])
                       and not (IsPlayerSpell(id)
                            or IsPlayerSpell(NormalizeToBase(id))
                            or IsPlayerSpell(ResolveToLive(id))) then
                        unlearnedSet = unlearnedSet or {}
                        unlearnedSet[id] = true
                    end
                end
            end
            -- WoW Forever: a stored spell this client cannot see (not known
            -- and not listed anywhere in its Cooldown Manager catalogue: a
            -- retail-only spell a retail layout carried in) keeps its place in
            -- the store but gets no preview slot. The display groups map every
            -- remaining slot back onto its assignedSpells index (drag, remove
            -- and the per-icon menu read them). Same exemptions as the
            -- unlearned test above; the catalogue set is built only once a
            -- candidate shows up.
            if EllesmereUI.IS_FOREVER and bd.key ~= "buffs" and not isBuffBar
               and not isCustomBuffBar and not isFocusKick then
                local sdFv = ns.GetBarSpellData(bd.key)
                local customFv  = sdFv and sdFv.customSpellIDs
                local cdursFv   = sdFv and sdFv.customSpellDurations
                local sdursFv   = sdFv and sdFv.spellDurations
                local groupsFv  = sdFv and sdFv.customSpellGroups
                local racialsFv = ns._myRacialsSet
                local known = C_SpellBook.IsSpellKnown
                local listedFv, keptFv, dispFv
                for i = 1, #tracked do
                    local id = tracked[i]
                    local unseen = false
                    if type(id) == "number" and id > 0
                       and not (customFv and customFv[id])
                       and not (racialsFv and racialsFv[id])
                       and not (cdursFv and cdursFv[id])
                       and not (sdursFv and sdursFv[id])
                       and not (groupsFv and groupsFv[id]) then
                        local base, live = NormalizeToBase(id), ResolveToLive(id)
                        if not (known(id) or known(base) or known(live)) then
                            if listedFv == nil then listedFv = ns.CDMForeverListedSet() or false end
                            unseen = listedFv and not (listedFv[id] or listedFv[base] or listedFv[live]) or false
                        end
                    end
                    if unseen then
                        if not keptFv then
                            -- First cut: the kept list starts with the slots before it.
                            keptFv, dispFv = {}, {}
                            for j = 1, i - 1 do keptFv[j] = tracked[j]; dispFv[j] = { j } end
                        end
                    elseif keptFv then
                        keptFv[#keptFv + 1] = id
                        dispFv[#keptFv] = { i }
                    end
                end
                if keptFv then tracked, pf._buffDispGroups = keptFv, dispFv end
            end
            local count = #tracked

            -- Use the same stride logic as the runtime (ComputeTopRowStride).
            -- Top and Bottom custom-row overrides are mutually exclusive; the
            -- Bottom override is the flip (pick the bottom count, top gets rest).
            local stride, topRowCount
            local customTop
            if numRows == 2 then
                if bd.customTopRowEnabled and bd.topRowCount and bd.topRowCount > 0 then
                    customTop = math.min(bd.topRowCount, count)
                elseif bd.customBottomRowEnabled and bd.bottomRowCount and bd.bottomRowCount > 0 then
                    customTop = count - math.min(bd.bottomRowCount, count)
                end
            end
            if customTop ~= nil then
                if customTop < 0 then customTop = 0 end
                topRowCount = customTop
                local bottomCount = count - topRowCount
                if bottomCount <= 0 or topRowCount <= 0 then
                    -- Match the runtime: collapse to one row until BOTH rows hold
                    -- an icon. This also keeps the "+" button on the single row.
                    numRows = 1
                    topRowCount = count
                    stride = math.max(count, 1)
                else
                    stride = math.max(topRowCount, bottomCount)
                end
            else
                stride = math.ceil(count / numRows)
                if stride < 1 then stride = 1 end
                topRowCount = count - (numRows - 1) * stride
                if topRowCount < 0 then topRowCount = 0 end
            end
            local gridSlots = (count > 0) and (stride * numRows) or 0
            self._stride = stride
            self._numRows = numRows
            self._gridSlots = gridSlots

            local bottomRowCount = count - topRowCount
            if bottomRowCount < 0 then bottomRowCount = 0 end

            -- Per-row icon count for centering
            local function RowIconCount(row)
                if row == 0 then return topRowCount end
                return bottomRowCount
            end

            -- Mirror the live bar's visual row order: with reversed row growth the base
            -- (first data) row renders on the bottom/right (see ns.CDMRowsReversed /
            -- LayoutCDMBar). Data-row logic (RowIconCount, slot indices, drag mapping)
            -- keeps data rows; only the perpendicular placement offset flips.
            local pvReversed = ns.CDMRowsReversed and ns.CDMRowsReversed(bd) or false

            -- Total dimensions: spell grid + 1 extra slot for the "+" button
            local isVert = (grow == "DOWN" or grow == "UP")
            local totalW, totalH
            if isVert then
                local totalCols = numRows + 1
                totalW = (totalCols * iconSize) + ((totalCols - 1) * spacing)
                totalH = (stride * iconH) + ((stride - 1) * spacing)
            else
                local totalCols = stride + 1
                totalW = (totalCols * iconSize) + ((totalCols - 1) * spacing)
                totalH = (numRows * iconH) + ((numRows - 1) * spacing)
            end

            -- CDM preview: no scale-to-fit -- SetClipsChildren on the content
            -- header clips any overflow so icon scale remains accurate.
            local curParentW = (parent:GetWidth() - PAD * 2) / previewScale
            if curParentW > 0 then
                self:SetWidth(curParentW)
            end
            local startX = math.floor((curParentW - totalW) / 2)
            local startY = -5

            -- Position helper: places frame at grid position (col, row).
            -- Center any row that has fewer icons than stride. `row` is the
            -- DATA row; the visual row flips when pvReversed.
            local function PosAtGrid(frame, col, row)
                PP.Size(frame, iconSize, iconH); frame:ClearAllPoints()
                local rowCount = RowIconCount(row)
                local rowHasLess = (rowCount > 0 and rowCount < stride)
                local vRow = pvReversed and (numRows - 1 - row) or row
                local rowOffset = 0
                if isVert then
                    if rowHasLess then
                        rowOffset = math.floor((stride - rowCount) * (iconH + spacing) / 2)
                    end
                    local px = startX + vRow * (iconSize + spacing)
                    local py = startY - col * (iconH + spacing) - rowOffset
                    PP.Point(frame, "TOPLEFT", self, "TOPLEFT", px, py)
                    frame._baseX = px
                    frame._baseY = py
                else
                    if rowHasLess then
                        rowOffset = math.floor((stride - rowCount) * (iconSize + spacing) / 2)
                    end
                    local px = startX + col * (iconSize + spacing) + rowOffset
                    local py = startY - vRow * (iconH + spacing)
                    PP.Point(frame, "TOPLEFT", self, "TOPLEFT", px, py)
                    frame._baseX = px
                    frame._baseY = py
                end
            end

            -- Border color
            local bR, bG, bB = bd.borderR or 0, bd.borderG or 0, bd.borderB or 0
            if bd.borderClassColor then
                local _, ct = UnitClass("player")
                if ct then
                    local cc = RAID_CLASS_COLORS[ct]
                    if cc then bR, bG, bB = cc.r, cc.g, cc.b end
                end
            end

            local shape = bd.iconShape or "none"

            -- Layout: fill bottom-up. Icons 1..topRowCount go to top row (row 0),
            -- remaining icons fill rows 1..numRows-1 (full bottom rows).
            for i = 1, math.min(gridSlots, MAX_PREVIEW_ICONS) do
                local slot = previewSlots[i]
                slot._slotIdx = i
                -- The assignedSpells indices this slot covers (a legacy-duplicate
                -- buff slot covers >1); nil when nothing was collapsed. Used by the
                -- settings popup's "Remove Spell" so it clears the whole duplicate.
                slot._dataGroup = pf._buffDispGroups and pf._buffDispGroups[i] or nil

                -- Map sequential index to bottom-up grid position
                local col, row
                if i <= topRowCount then
                    col = i - 1
                    row = 0
                else
                    local bottomIdx = i - topRowCount - 1
                    col = bottomIdx % stride
                    row = 1 + math.floor(bottomIdx / stride)
                end
                PosAtGrid(slot, col, row)

                if i <= count then
                    -- Spell slot
                    local id = tracked[i]
                    slot._previewSpellID = nil  -- reset each update
                    slot._previewCdID = trackedCd and trackedCd[i] or nil
                    slot._previewItemID = nil
                    slot._previewHostedBuff = nil
                    if id then
                        local tex
                        local cdClaim = ns.CdClaimMarkerToCdID and ns.CdClaimMarkerToCdID(id)
                        local hostedSid = (not cdClaim) and ns.HostedBuffMarkerToSpell
                            and ns.HostedBuffMarkerToSpell(id)
                        if cdClaim then
                            -- Cd-claimed collided-buff slot on a CD/util bar
                            -- (Diabolist Demonic Art vs Diabolic Ritual): here
                            -- `tracked` ALIASES sd.assignedSpells (the buff-bar
                            -- branch above builds a fresh dedup list), so resolve
                            -- the marker to a display sid IN THIS RENDER STEP
                            -- ONLY -- never write back into `id`/`tracked[i]`
                            -- (that corrupts the saved marker). Same clean-cache
                            -- + cooldownInfo fallback as the buff-bar preview.
                            local csid = ns._cdmCleanSidByCDID and ns._cdmCleanSidByCDID[cdClaim]
                            if not (type(csid) == "number" and csid > 0) then
                                local gci = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo
                                local info = gci and gci(cdClaim)
                                local raw2 = info and info.overrideSpellID
                                if not (type(raw2) == "number"
                                        and not (issecretvalue and issecretvalue(raw2))
                                        and raw2 > 0) then
                                    raw2 = info and info.spellID
                                end
                                if type(raw2) == "number"
                                   and not (issecretvalue and issecretvalue(raw2))
                                   and raw2 > 0 then
                                    csid = raw2
                                end
                            end
                            if type(csid) == "number" and csid > 0 then
                                local displayID = ResolveIconArt(csid, cdClaim)
                                tex = C_Spell.GetSpellTexture(displayID)
                                if not tex and displayID ~= csid then
                                    tex = C_Spell.GetSpellTexture(csid)
                                end
                                slot._previewSpellID = csid
                                slot._previewCdID = cdClaim
                                slot._previewHostedBuff = true
                            end
                        elseif hostedSid then
                            -- Hosted-buff marker: previews as its spell, flagged so
                            -- the per-icon menu takes the buff branch while the same
                            -- id's cooldown slot keeps the cd/util one.
                            local displayID = ResolveIconArt(hostedSid)
                            tex = C_Spell.GetSpellTexture(displayID)
                            if not tex and displayID ~= hostedSid then
                                tex = C_Spell.GetSpellTexture(hostedSid)
                            end
                            slot._previewSpellID = hostedSid
                            slot._previewHostedBuff = true
                        elseif id <= -100 then
                            -- On-use bag item: negated itemID
                            tex = C_Item.GetItemIconByID(-id)
                            slot._previewItemID = -id
                        elseif id < 0 then
                            -- Trinket slot: get icon from equipped item
                            local itemID = GetInventoryItemID("player", -id)
                            tex = itemID and C_Item.GetItemIconByID(itemID) or nil
                        else
                            -- Resolve to live override for texture lookup.
                            local displayID = ResolveIconArt(id, slot._previewCdID)
                            tex = C_Spell.GetSpellTexture(displayID)
                            if not tex and displayID ~= id then
                                tex = C_Spell.GetSpellTexture(id)
                            end
                            slot._previewSpellID = id
                        end
                        if tex then
                            slot._icon:SetTexture(tex)
                            slot._icon:SetTexCoord(zoom, 1 - zoom, zoom, 1 - zoom)
                            local pvUnlearned = (unlearnedSet and unlearnedSet[id])
                                or (tcSet and tcSet[id] == "off") or false
                            slot._icon:SetDesaturated(pvUnlearned)
                            slot._icon:SetAlpha(pvUnlearned and 0.55 or 1)
                        else slot._icon:SetTexture(nil) end
                    else slot._icon:SetTexture(nil) end
                else
                    -- Blank slot (empty grid filler)
                    slot._icon:SetTexture(nil)
                    slot._previewSpellID = nil
                    slot._previewCdID = nil
                    slot._previewItemID = nil
                    slot._previewHostedBuff = nil
                end

                local bSz = bd.borderSize or 1
                -- The art inset follows an exact Solid size (borderSizePx) so the border keeps sitting outside the art here.
                local bTex = bd.borderTexture or "solid"
                local bPx = EllesmereUI.BorderPx(bd.borderSizePx, bSz, bTex)
                if bPx and bTex == "solid" then bSz = bPx end
                slot._icon:ClearAllPoints()
                PP.Point(slot._icon, "TOPLEFT", slot, "TOPLEFT", bSz, -bSz)
                PP.Point(slot._icon, "BOTTOMRIGHT", slot, "BOTTOMRIGHT", -bSz, bSz)
                slot._icon:Show()

                if PP.GetBorders(slot) then
                    PP.SetBorderColor(slot, bR, bG, bB, 1)
                    PP.SetBorderSize(slot, bSz)
                end
                slot._bg:SetColorTexture(bd.bgR or 0.08, bd.bgG or 0.08, bd.bgB or 0.08, bd.bgA or 0.6)
                if slot._bg.SetSnapToPixelGrid then slot._bg:SetSnapToPixelGrid(false); slot._bg:SetTexelSnappingBias(0) end

                ns.ApplyShapeToCDMIcon(slot, shape, bd)
                -- Blizzard Style: no EUI border or background; the live art pass
                -- adds the viewer's rounded mask and ring to the slot exactly as
                -- it does to a bar's own icons. The preview's overlays (text,
                -- hover and hosted-buff borders, glow) move above the ring, at
                -- the levels their live counterparts use.
                if EllesmereUI.BlizzStyle.Get("cdmicons") and ns.CdmApplyBlizzIconArt then
                    if PP.GetBorders(slot) then PP.HideBorder(slot) end
                    slot._bg:Hide()
                    ns.CdmApplyBlizzIconArt(slot)
                    local lvl = slot:GetFrameLevel()
                    if slot._pvTextOverlay then slot._pvTextOverlay:SetFrameLevel(lvl + 23) end
                    if slot._hlBrd then slot._hlBrd:GetParent():SetFrameLevel(lvl + 17) end
                    if slot._hostBrd then slot._hostBrd:GetParent():SetFrameLevel(lvl + 16) end
                    if slot._glowOverlay then slot._glowOverlay:SetFrameLevel(lvl + 16) end
                end
                -- Talent Conditions corner mark (built on first use; slots are shared across bars, so always
                -- repainted once it exists). After the style pass: it sits just under the text overlay's level.
                if tcSet or slot._tcMark then
                    ns.PaintTalentCondMark(slot, tcSet and i <= count and tcSet[tracked[i]] or nil)
                end
                -- For custom shapes, ensure the square highlight border stays hidden
                -- (ApplyShapeToCDMIcon hides the slot's own PP border but not _hlBrd)
                -- (Blizzard Style forces shape none, whatever the profile carries.)
                if slot._hlBrd and shape ~= "square" and shape ~= "csquare" and shape ~= "none"
                   and not EllesmereUI.BlizzStyle.Get("cdmicons") then
                    slot._hlBrd:Hide()
                end
                -- Hosted-buff gold border: always on for a buff icon hosted on
                -- this CD/utility bar. Square-family shapes use the dedicated
                -- gold strips; masked shapes tint the shape border instead
                -- (their square strips are hidden, like the hover highlight).
                if slot._hostBrd then
                    if slot._previewHostedBuff
                       and not (slot._shapeBorder and slot._shapeBorder:IsShown()) then
                        slot._hostBrd:Show()
                    else
                        slot._hostBrd:Hide()
                    end
                end
                if slot._previewHostedBuff and slot._shapeBorder and slot._shapeBorder:IsShown() then
                    slot._shapeBorder:SetVertexColor(1, 0.82, 0.25, 1)
                end

                -- Stack count preview text
                if slot._stackText then
                    if i <= count then
                        -- Show charge count for charge-based spells (default: on)
                        -- Match real bar styling exactly (RefreshCDMIconAppearance)
                        local scFont = ns.GetCDMFont and ns.GetCDMFont() or FONT_PATH
                        local scSize = bd.stackCountSize or 11
                        local scR = bd.stackCountR or 1
                        local scG = bd.stackCountG or 1
                        local scB = bd.stackCountB or 1
                        local scX = bd.stackCountX or 0
                        local scY = bd.stackCountY or 0
                        local scPoint = bd.stackCountPosition or "bottomright"
                        if scPoint == "bottomleft" then scPoint = "BOTTOMLEFT"; scY = scY + 2
                        elseif scPoint == "bottom" then scPoint = "BOTTOM"; scY = scY + 2
                        elseif scPoint == "topright" then scPoint = "TOPRIGHT"
                        elseif scPoint == "top" then scPoint = "TOP"
                        elseif scPoint == "topleft" then scPoint = "TOPLEFT"
                        elseif scPoint == "center" then scPoint = "CENTER"
                        elseif scPoint == "left" then scPoint = "LEFT"
                        elseif scPoint == "right" then scPoint = "RIGHT"
                        else scPoint = "BOTTOMRIGHT"; scY = scY + 2 end
                        EllesmereUI.ApplyIconTextFont(slot._stackText, scFont, scSize, "cdm")
                        slot._stackText:SetTextColor(scR, scG, scB)
                        slot._stackText:ClearAllPoints()
                        slot._stackText:SetPoint(scPoint, slot, scPoint, scX, scY)
                        local sid = slot._previewSpellID
                        local chargeInfo = sid and C_Spell.GetSpellCharges and C_Spell.GetSpellCharges(sid)
                        local maxC = chargeInfo and chargeInfo.maxCharges
                        if (bd.showCharges ~= false) and maxC and maxC > 1 then
                            slot._stackText:SetText(tostring(maxC))
                            slot._stackText:Show()
                        elseif slot._previewItemID and (bd.showItemCount ~= false) then
                            -- Preset potions/healthstones: fake item count so users can
                            -- preview and style the count text (mirrors charge preview).
                            slot._stackText:SetText("5")
                            slot._stackText:Show()
                        else
                            slot._stackText:Hide()
                        end
                    else
                        slot._stackText:Hide()
                    end
                end

                -- Use the live renderer so font, anchors and badge alpha agree.
                if slot._keybindText then
                    ns.StyleCDMKeybind(slot._keybindText, bd, slot, 1, FONT_PATH)
                    local sid = slot._previewSpellID
                    if bd.showKeybind and sid then
                        -- The live icons' lookup: id, override, base, then name.
                        local key = ns.ResolveCDMKeybind(sid)
                        if key then
                            slot._keybindText:SetText(key)
                            slot._keybindText:Show()
                        else
                            slot._keybindText:Hide()
                        end
                    else
                        slot._keybindText:Hide()
                    end
                    -- StyleCDMKeybind above already styled the badge: visibility only.
                    ns.ShowCDMKeybindBadge(slot._keybindText, bd)
                end

                if i <= count then
                    slot:Show()
                else
                    slot:Hide()
                end
            end

            for i = gridSlots + 1, MAX_PREVIEW_ICONS do previewSlots[i]:Hide() end

            -- "+" button: placed right after the last icon on the bottom row (always full,
            -- or the only row). For empty bars (count=0), the "+" is the only visible element.
            local addPx, addPy
            if count == 0 then
                -- No spells: center the "+" button alone
                addPx = math.floor((curParentW - iconSize) / 2)
                addPy = startY
            elseif isVert then
                -- Vertical: "+" goes in the next column to the right, at the bottom
                addPx = startX + numRows * (iconSize + spacing)
                addPy = startY - (stride - 1) * (iconH + spacing)
            else
                -- Horizontal: "+" goes right after the last column on the bottom row
                local lastRow = numRows - 1
                addPx = startX + stride * (iconSize + spacing)
                addPy = startY - lastRow * (iconH + spacing)
            end
            PP.Size(addBtn, iconSize, iconH); addBtn:ClearAllPoints()
            PP.Point(addBtn, "TOPLEFT", self, "TOPLEFT", addPx, addPy)
            if PP.GetBorders(addBtn) then PP.SetBorderSize(addBtn, 1) end
            local ar, ag, ab = EllesmereUI.GetAccentColor()

            addLbl:SetTextColor(ar, ag, ab, 0.6)
            addBtn:Show()

            -- Second "+" (buff) button sits one slot right of the standard "+", on CD/utility bars only (buff-family/custom_buff/focuskick bars track buffs their own way).
            if not isBuffBar and not isCustomBuffBar and not isFocusKick then
                PP.Size(buffAddBtn, iconSize, iconH); buffAddBtn:ClearAllPoints()
                PP.Point(buffAddBtn, "TOPLEFT", self, "TOPLEFT", addPx + iconSize + spacing, addPy)
                if PP.GetBorders(buffAddBtn) then PP.SetBorderSize(buffAddBtn, 1) end
                buffAddBtn:Show()
            else
                buffAddBtn:Hide()
            end

            -- Bar background covers spell grid only (not the + column)
            local spellW, spellH
            if isVert then
                spellW = (numRows * iconSize) + ((numRows - 1) * spacing)
                spellH = (stride * iconH) + ((stride - 1) * spacing)
            else
                spellW = (stride * iconSize) + ((stride - 1) * spacing)
                spellH = totalH
            end
            if bd.barBgEnabled then
                pvBarBg:ClearAllPoints()
                pvBarBg:SetPoint("TOPLEFT", startX, startY)
                pvBarBg:SetPoint("BOTTOMRIGHT", pf, "TOPLEFT", startX + spellW, startY - spellH)
                pvBarBg:SetColorTexture(bd.barBgR or 0, bd.barBgG or 0, bd.barBgB or 0, bd.barBgA or 0.5)
                if pvBarBg.SetSnapToPixelGrid then pvBarBg:SetSnapToPixelGrid(false); pvBarBg:SetTexelSnappingBias(0) end
                pvBarBg:Show()
            else
                pvBarBg:Hide()
            end

            self:SetAlpha(1)

            -- Buff bar info text
            if not self._buffInfoText then
                local infoFS = self:CreateFontString(nil, "OVERLAY")
                infoFS:SetFont(FONT_PATH, 11, GetCDMOptOutline())
                infoFS:SetJustifyH("CENTER")
                infoFS:SetWordWrap(true)
                infoFS:SetTextColor(0.6, 0.6, 0.6, 0.9)
                self._buffInfoText = infoFS
            end
            -- Reorder/per-icon hint shown directly below the preview icons. Buff bars and
            -- CD/utility bars get different wording; FocusKick has its own info text instead and is not user-reorderable.
            if not self._reorderHintText then
                local rh = self:CreateFontString(nil, "OVERLAY")
                rh:SetFont(FONT_PATH, 11, GetCDMOptOutline())
                rh:SetJustifyH("CENTER")
                rh:SetWordWrap(true)
                rh:SetTextColor(0.62, 0.62, 0.62, 0.9)
                self._reorderHintText = rh
            end
            local function ShowReorderHint(text)
                local rh = self._reorderHintText
                rh:SetText(EllesmereUI.L(text))
                rh:ClearAllPoints()
                rh:SetPoint("TOP", self, "TOPLEFT", self:GetWidth() / 2, -(totalH + 14))
                rh:SetWidth(self:GetWidth() - 20)
                rh:Show()
                self:SetHeight(totalH + 10 + rh:GetStringHeight() + 20)
            end

            if isBuffBar then
                if self._buffInfoText then self._buffInfoText:Hide() end
                if self._buffInfoClick then self._buffInfoClick:Hide() end
                -- Hide any stale hidden rows
                if self._hiddenRows then
                    for _, hr in ipairs(self._hiddenRows) do hr:Hide() end
                end
                if self._hiddenHeader then self._hiddenHeader:Hide() end
                if self._focusKickInfoText then self._focusKickInfoText:Hide() end
                ShowReorderHint("Drag to Reorder. Click to override display settings and add custom effects per icon")
            elseif isFocusKick then
                if self._buffInfoText then self._buffInfoText:Hide() end
                if self._buffInfoClick then self._buffInfoClick:Hide() end
                if self._reorderHintText then self._reorderHintText:Hide() end
                if not self._focusKickInfoText then
                    local fkFS = self:CreateFontString(nil, "OVERLAY")
                    fkFS:SetFont(FONT_PATH, 11, GetCDMOptOutline())
                    fkFS:SetJustifyH("CENTER")
                    fkFS:SetWordWrap(true)
                    fkFS:SetTextColor(1, 1, 1, 1)
                    self._focusKickInfoText = fkFS
                end
                local fkFS = self._focusKickInfoText
                -- Wording must track the "Show on Target" toggle -- otherwise this text keeps promising focus-tracking even when the bar is configured to follow the current target instead.
                if bd.focusKickUseTarget then
                    fkFS:SetText(EllesmereUI.L("This bar will always be attached to your current target's nameplate"))
                else
                    fkFS:SetText(EllesmereUI.L("This bar will always be attached to your focus target's nameplate"))
                end
                fkFS:ClearAllPoints()
                fkFS:SetPoint("TOP", self, "TOPLEFT", self:GetWidth() / 2, -(totalH + 14))
                fkFS:SetWidth(self:GetWidth() - 20)
                fkFS:Show()
                self:SetHeight(totalH + 10 + fkFS:GetStringHeight() + 20)
            else
                if self._buffInfoText then self._buffInfoText:Hide() end
                if self._buffInfoClick then self._buffInfoClick:Hide() end
                if self._focusKickInfoText then self._focusKickInfoText:Hide() end
                ShowReorderHint("Drag to Reorder. Click to add custom glows, active/cooldown state effects and more.")
            end

            -- Resize wrapper to min(content, max) and toggle scrollbar
            local parentH = self:GetHeight() * (self._previewScale or 1)
            local maxH = self._PREVIEW_MAX_H or 200
            if parentH > maxH then
                -- Add bottom padding so info text is fully visible when scrolled down
                self:SetHeight(self:GetHeight() + 30)
                -- If the cap would slice into the icon grid itself, snap the viewport to
                -- a whole row instead -- cropping into the hint text below is harmless,
                -- cropping an icon row in half isn't.
                local stackRows = isVert and stride or numRows
                local topInset = 5
                local rowStep = iconH + spacing
                local gridBottomLocal = topInset + stackRows * iconH + (stackRows - 1) * spacing
                if gridBottomLocal * self._previewScale > maxH then
                    local visibleRows = math.max(1, math.floor((maxH / self._previewScale - topInset + spacing) / rowStep + 0.001))
                    visibleRows = math.min(visibleRows, stackRows)
                    local cappedLocalH = topInset + visibleRows * iconH + (visibleRows - 1) * spacing
                    self._wrapper:SetHeight(math.min(maxH, cappedLocalH * self._previewScale))
                else
                    self._wrapper:SetHeight(maxH)
                end
            else
                self._wrapper:SetHeight(parentH)
                if self._scrollFrame then self._scrollFrame:SetVerticalScroll(0) end
            end
            if self._updatePVThumb then self._updatePVThumb() end

            -- Restart active state preview on first icon if toggled on
            if _cdmActivePreviewOn then
                StopActiveStatePreview()
                StartActiveStatePreview()
            end
        end

        pf._previewSlots = previewSlots
        optState._cdmPreview = pf
        pf:Update()
        EllesmereUI._contentHeaderPreview = pf
        -- Start active state preview if toggled on
        if _cdmActivePreviewOn then
            StartActiveStatePreview()
        end
        -- Return wrapper height (already capped by Update's resize logic)
        return wrapper:GetHeight()
    end

    -- Keybind color swatch and text cog on a Show Keybind row. lockTip
    -- (optional): why the whole row is locked, nil while it is live; the
    -- swatch and cog give that reason first, then Show Keybind.
    local function BuildKeybindStyleControls(kbRow, BD, RefreshKeybindStyle, lockTip)
        if not EllesmereUI._prebuilding then
            local rgn = kbRow._rightRegion
            local kbFonts, kbFontOrder = EllesmereUI.BuildFontDropdownData()
            kbFonts.__global = { text = "CDM Font" }
            local function OffTip()
                local tip = lockTip and lockTip()
                if tip then return tip end
                if BD().showKeybind ~= true then return "Show Keybind" end
            end

            local kbSwatch, updateKbSwatch = EllesmereUI.BuildColorSwatch(
                rgn, kbRow:GetFrameLevel() + 3,
                function() return BD().keybindR or 1, BD().keybindG or 1, BD().keybindB or 1, BD().keybindA or 0.9 end,
                function(r, g, b, a)
                    BD().keybindR = r; BD().keybindG = g; BD().keybindB = b; BD().keybindA = a
                    RefreshKeybindStyle()
                end,
                true, 20)
            PP.Point(kbSwatch, "RIGHT", rgn._control, "LEFT", -8, 0)

            EllesmereUI.BuildInlineCog(rgn, { anchorTo = kbSwatch, icon = EllesmereUI.RESIZE_ICON,
                title = "Keybind Text Settings",
                disabled = function() return OffTip() ~= nil end,
                disabledTooltip = OffTip,
                rows = {
                    { type = "dropdown", label = "Font", values = kbFonts, order = kbFontOrder,
                      get = function() return BD().keybindFont or "__global" end,
                      set = function(v) BD().keybindFont = v; RefreshKeybindStyle() end },
                    { type = "dropdown", label = "Text Outline",
                      values = { inherit = "CDM Outline", NONE = "None", OUTLINE = "Outline", THICKOUTLINE = "Thick Outline" },
                      order = { "inherit", "NONE", "OUTLINE", "THICKOUTLINE" },
                      get = function() return BD().keybindOutline or "inherit" end,
                      set = function(v) BD().keybindOutline = v; RefreshKeybindStyle() end },
                    { type = "slider", label = "Text Size", min = 6, max = 20, step = 1,
                      get = function() return BD().keybindSize or 10 end,
                      set = function(v) BD().keybindSize = v; RefreshKeybindStyle() end },
                    { type = "dropdown", label = "Anchor",
                      values = { TOPLEFT = "Top Left", TOP = "Top", TOPRIGHT = "Top Right",
                          LEFT = "Left", CENTER = "Center", RIGHT = "Right",
                          BOTTOMLEFT = "Bottom Left", BOTTOM = "Bottom", BOTTOMRIGHT = "Bottom Right" },
                      order = { "TOPLEFT", "TOP", "TOPRIGHT", "LEFT", "CENTER", "RIGHT", "BOTTOMLEFT", "BOTTOM", "BOTTOMRIGHT" },
                      get = function() return BD().keybindAnchor or (BD().keybindAlign == "right" and "TOPRIGHT" or "TOPLEFT") end,
                      set = function(v) BD().keybindAnchor = v; RefreshKeybindStyle() end },
                    { type = "slider", label = "X Offset", min = -30, max = 30, step = 1,
                      get = function() return BD().keybindOffsetX or 2 end,
                      set = function(v) BD().keybindOffsetX = v; RefreshKeybindStyle() end },
                    { type = "slider", label = "Y Offset", min = -30, max = 30, step = 1,
                      get = function() return BD().keybindOffsetY or -2 end,
                      set = function(v) BD().keybindOffsetY = v; RefreshKeybindStyle() end },
                    { type = "colorpicker", label = "Background Color", hasAlpha = true,
                      tooltip = "Set opacity to 0% for text without a background.",
                      get = function() return BD().keybindBackgroundR or 0, BD().keybindBackgroundG or 0,
                          BD().keybindBackgroundB or 0, BD().keybindBackgroundA or 0 end,
                      set = function(r, g, b, a)
                          local d = BD(); d.keybindBackgroundR = r; d.keybindBackgroundG = g
                          d.keybindBackgroundB = b; d.keybindBackgroundA = a; RefreshKeybindStyle()
                      end },
                    { type = "colorpicker", label = "Border Color", hasAlpha = true,
                      tooltip = "Set opacity to 0% to hide the keybind badge border.",
                      get = function() return BD().keybindBorderR or 1, BD().keybindBorderG or 1,
                          BD().keybindBorderB or 1, BD().keybindBorderA or 0 end,
                      set = function(r, g, b, a)
                          local d = BD(); d.keybindBorderR = r; d.keybindBorderG = g
                          d.keybindBorderB = b; d.keybindBorderA = a; RefreshKeybindStyle()
                      end },
                    { type = "slider", label = "Border Size", min = 0, max = 4, step = 1,
                      get = function() return BD().keybindBorderSize or 1 end,
                      set = function(v) BD().keybindBorderSize = v; RefreshKeybindStyle() end },
                    { type = "slider", label = "Background Padding", min = 0, max = 8, step = 1,
                      get = function() return BD().keybindPadding or 2 end,
                      set = function(v) BD().keybindPadding = v; RefreshKeybindStyle() end },
                    -- Global, not per-bar: there is one shared keybind cache
                    -- for every CDM bar, so this toggle is labelled as such.
                    { type = "toggle", label = "Keep Keys on Bar Swap (global)",
                      tooltip = "Keep keybind text identical when your action bar swaps -- rogue stealth, druid forms, skyriding. Also covers conditional macros like \"/cast [bonusbar:1] Backstab; Shadow Dance\", where the key would otherwise jump to whichever branch is live.\n\nThe key then only changes when you actually move the ability or rebind it.\n\nOn by default. Applies to every CDM bar at once.",
                      get = function()
                          local p = DB()
                          return (p and p.cdmBars and p.cdmBars.stableKeybinds) == true
                      end,
                      set = function(v)
                          local p = DB()
                          if not p or not p.cdmBars then return end
                          p.cdmBars.stableKeybinds = v and true or false
                          -- Changes how the cache is built, not just how it is
                          -- drawn -- needs a full rebuild, not an apply pass.
                          if ns.UpdateCDMKeybinds then ns.UpdateCDMKeybinds() end
                          RefreshKeybindStyle()
                      end },
                },
            })

            local swatchBlock = CreateFrame("Frame", nil, kbSwatch)
            swatchBlock:SetAllPoints()
            swatchBlock:SetFrameLevel(kbSwatch:GetFrameLevel() + 10)
            swatchBlock:EnableMouse(true)
            swatchBlock:SetScript("OnEnter", function()
                local tip = OffTip()
                if tip then EllesmereUI.ShowWidgetTooltip(kbSwatch, EllesmereUI.DisabledTooltip(tip)) end
            end)
            swatchBlock:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
            local function SwatchState()
                updateKbSwatch()
                local on = OffTip() == nil
                kbSwatch:SetAlpha(on and 1 or 0.3)
                swatchBlock:SetShown(not on)
            end
            EllesmereUI.RegisterWidgetRefresh(SwatchState)
            SwatchState()
        end
    end

    local function BuildCDMBarsPage(pageName, parent, yOffset)
        local W = EllesmereUI.Widgets
        local y = yOffset
        local _, h

        local p = DB()
        if not p or not p.cdmBars then return math.abs(yOffset) end

        local bars = p.cdmBars.bars
        if not bars or #bars == 0 then return math.abs(yOffset) end


        -- Clamp selection
        if optState.selectedCDMBarIndex < 1 then optState.selectedCDMBarIndex = 1 end
        if optState.selectedCDMBarIndex > #bars then optState.selectedCDMBarIndex = #bars end

        local barData = bars[optState.selectedCDMBarIndex]
        if not barData then return math.abs(yOffset) end

        -- Tag every option registered by this build with the selected bar, so a global-search
        -- jump to a bar-specific setting (e.g. HoverCast/FocusKick-only rows) restores this exact
        -- bar first via EllesmereUI._setCDMBar -- otherwise the matched row wouldn't exist under whatever bar is selected when the player jumps there.
        EllesmereUI._buildingSelector = { setter = EllesmereUI._setCDMBar, key = barData.key }

        -- Capture the key so closures always look up the CURRENT bar data from the profile (no
        -- stale references across reorders/rebuilds). Searchable single-select "Sync From"
        -- source-spec dropdown; defaults to the current spec. Reuses one frame on ns so repeated opens don't leak.
        local function ShowRPTSourcePicker(defaultKey, onSelect)
            -- All-classes source list (current class always + other classes that have data), so the source isn't limited to the player's class.
            local info = ns.GetAllCDMSpecInfo and ns.GetAllCDMSpecInfo()
                or (ns.GetCDMSpecInfo and ns.GetCDMSpecInfo()) or {}
            local DDW = 280
            local ROW_H = 30
            local MAX_VISIBLE = 10               -- rows shown before the list scrolls
            local MAX_LIST_H = MAX_VISIBLE * ROW_H
            local P = ns._rptSrcPopup
            if not P then
                P = { rows = {} }
                ns._rptSrcPopup = P
                local scale = (EllesmereUI.GetPopupScale()) or 1
                local dimmer = CreateFrame("Frame", nil, UIParent)
                dimmer:SetFrameStrata("FULLSCREEN_DIALOG")
                dimmer:SetAllPoints(UIParent)
                dimmer:EnableMouse(true)
                dimmer:Hide()
                local dt = dimmer:CreateTexture(nil, "BACKGROUND"); dt:SetAllPoints(); dt:SetColorTexture(0, 0, 0, 0.25)
                local popup = CreateFrame("Frame", nil, dimmer)
                popup:SetScale(scale)
                popup:SetFrameStrata("FULLSCREEN_DIALOG")
                popup:SetFrameLevel(dimmer:GetFrameLevel() + 10)
                PP.Size(popup, DDW + 24, 320)
                popup:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
                popup:EnableMouse(true)
                local bg = popup:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); bg:SetColorTexture(0.06, 0.08, 0.10, 1)
                EllesmereUI.MakeBorder(popup, 1, 1, 1, 0.15, PP)
                local titleFs = EllesmereUI.MakeFont(popup, 15, nil, 1, 1, 1, 1)
                titleFs:SetPoint("TOP", popup, "TOP", 0, -14); titleFs:SetText("Sync From")
                local subFs = EllesmereUI.MakeFont(popup, 11, nil, 1, 1, 1, 0.45)
                subFs:SetPoint("TOP", titleFs, "BOTTOM", 0, -4)
                subFs:SetWidth(DDW); subFs:SetJustifyH("CENTER")
                subFs:SetText("Choose the spec to copy trinkets, pots, racials & buff presets from")
                local search = CreateFrame("EditBox", nil, popup)
                PP.Size(search, DDW, 26)
                search:SetPoint("TOP", subFs, "BOTTOM", 0, -10)
                search:SetFont(FONT_PATH, 12, "")
                search:SetTextColor(1, 1, 1, 0.9); search:SetJustifyH("LEFT")
                search:SetAutoFocus(false); search:SetMaxLetters(30); search:SetTextInsets(6, 6, 0, 0)
                local sbg = search:CreateTexture(nil, "BACKGROUND"); sbg:SetAllPoints(); sbg:SetColorTexture(0, 0, 0, 0.4)
                EllesmereUI.MakeBorder(search, 1, 1, 1, 0.10, PP)
                local ph = search:CreateFontString(nil, "OVERLAY"); ph:SetFont(FONT_PATH, 11, "")
                ph:SetTextColor(0.5, 0.5, 0.5, 0.6); ph:SetPoint("LEFT", search, "LEFT", 6, 0); ph:SetText("Search...")
                search:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
                -- Scrollable, capped list: a long cross-class spec list scrolls
                -- (mousewheel) inside a fixed max height instead of running off the
                -- screen. A thin thumb on the right shows when there is more to see.
                local scrollF = CreateFrame("ScrollFrame", nil, popup)
                scrollF:SetPoint("TOPLEFT", search, "BOTTOMLEFT", 0, -8)
                scrollF:SetPoint("RIGHT", popup, "RIGHT", -12, 0)
                scrollF:EnableMouseWheel(true)
                local listF = CreateFrame("Frame", nil, scrollF)
                listF:SetWidth(DDW)
                scrollF:SetScrollChild(listF)
                local track = scrollF:CreateTexture(nil, "ARTWORK")
                track:SetWidth(3); track:SetColorTexture(1, 1, 1, 0.06)
                track:SetPoint("TOPRIGHT", scrollF, "TOPRIGHT", -1, 0)
                track:SetPoint("BOTTOMRIGHT", scrollF, "BOTTOMRIGHT", -1, 0)
                track:Hide()
                local thumb = scrollF:CreateTexture(nil, "OVERLAY")
                thumb:SetWidth(3); thumb:SetColorTexture(1, 1, 1, 0.25); thumb:Hide()
                local function UpdateThumb()
                    local visH, fullH = scrollF:GetHeight(), listF:GetHeight()
                    local maxScroll = math.max(0, fullH - visH)
                    if maxScroll <= 0 then track:Hide(); thumb:Hide(); return end
                    track:Show(); thumb:Show()
                    local thumbH = math.max(20, visH * visH / fullH)
                    thumb:SetHeight(thumbH)
                    local frac = (scrollF:GetVerticalScroll() or 0) / maxScroll
                    thumb:ClearAllPoints()
                    thumb:SetPoint("TOPRIGHT", track, "TOPRIGHT", 0, -frac * (visH - thumbH))
                end
                scrollF:SetScript("OnMouseWheel", function(self, delta)
                    local maxScroll = math.max(0, listF:GetHeight() - self:GetHeight())
                    if maxScroll <= 0 then return end
                    local new = math.max(0, math.min(maxScroll, (self:GetVerticalScroll() or 0) - delta * ROW_H * 2))
                    self:SetVerticalScroll(new); UpdateThumb()
                end)
                dimmer:SetScript("OnMouseDown", function() dimmer:Hide() end)
                popup:SetScript("OnMouseDown", function() end)
                P.dimmer, P.popup, P.search, P.ph, P.list, P.DDW = dimmer, popup, search, ph, listF, DDW
                P.scroll, P.updateThumb = scrollF, UpdateThumb
            end

            local function Rebuild()
                local filter = (P.search:GetText() or ""):lower()
                local shown = 0
                for _, r in ipairs(P.rows) do r:Hide() end
                for _, s in ipairs(info) do
                    local nm = s.name or ""
                    if filter == "" or nm:lower():find(filter, 1, true) then
                        shown = shown + 1
                        local r = P.rows[shown]
                        if not r then
                            r = CreateFrame("Button", nil, P.list)
                            PP.Size(r, P.DDW, ROW_H)
                            r:SetFrameLevel(P.list:GetFrameLevel() + 1)
                            local hl = r:CreateTexture(nil, "ARTWORK"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.06); hl:Hide(); r._hl = hl
                            local ic = r:CreateTexture(nil, "ARTWORK"); ic:SetSize(20, 20); ic:SetPoint("LEFT", r, "LEFT", 8, 0); r._ic = ic
                            local tx = EllesmereUI.MakeFont(r, 13, nil, 1, 1, 1, 0.85); tx:SetPoint("LEFT", ic, "RIGHT", 8, 0); r._tx = tx
                            r:SetScript("OnEnter", function(self) self._hl:Show() end)
                            r:SetScript("OnLeave", function(self) if not self._isDefault then self._hl:Hide() end end)
                            P.rows[shown] = r
                        end
                        r:ClearAllPoints()
                        r:SetPoint("TOPLEFT", P.list, "TOPLEFT", 0, -((shown - 1) * ROW_H))
                        if s.icon then r._ic:SetTexture(s.icon); r._ic:Show() else r._ic:Hide() end
                        r._tx:SetText(nm)
                        r._isDefault = (s.key == defaultKey)
                        r._hl:SetShown(r._isDefault)
                        local key = s.key
                        r:SetScript("OnClick", function()
                            P.dimmer:Hide()
                            if onSelect then onSelect(key) end
                        end)
                        r:Show()
                    end
                end
                local listH = math.max(ROW_H, shown * ROW_H)
                P.list:SetHeight(listH)
                local visH = math.min(listH, MAX_LIST_H)
                P.scroll:SetHeight(visH)
                P.popup:SetHeight(110 + visH)
                P.scroll:SetVerticalScroll(0)
                if P.updateThumb then P.updateThumb() end
            end
            P.search:SetScript("OnTextChanged", function(self)
                P.ph:SetShown((self:GetText() or "") == "")
                Rebuild()
            end)
            P.search:SetText("")
            P.ph:Show()
            Rebuild()
            P.dimmer:Show()
            C_Timer.After(0.05, function() P.search:SetFocus() end)
        end

        -- Sync Generic CDs/Buffs across specs (per profile): trinkets, pots, racials
        -- and buff-bar presets (Bloodlust, etc.). First-time setup picks a SOURCE spec
        -- (searchable dropdown, default current spec), then a spec picker with the
        -- source locked ON (auto-checked, can't be deselected).
        local function DoRPTSyncSetup()
            local curKey = ns.GetActiveSpecKey and ns.GetActiveSpecKey()
            ShowRPTSourcePicker(curKey, function(sourceKey)
                local srcName = sourceKey
                local srcID = tonumber(sourceKey)
                if srcID then
                    -- WoW Forever has no by-ID spec global; its spec-ID name
                    -- lookups name the source there instead of the raw key.
                    local n
                    if GetSpecializationInfoByID then
                        n = select(2, GetSpecializationInfoByID(srcID))
                    elseif GetSpecializationNameForSpecID then
                        n = GetSpecializationNameForSpecID(srcID)
                    elseif GetSpecializationInfoForSpecID then
                        n = select(2, GetSpecializationInfoForSpecID(srcID))
                    end
                    if n and n ~= "" then srcName = n end
                end
                -- WoW Forever: a key names a whole class there.
                if EllesmereUI.IS_FOREVER then
                    local t = EllesmereUI.SpecClassOf(tonumber(sourceKey))
                    if t then srcName = EllesmereUI.ForeverClassName(t) end
                end
                local specs = ns.GetCDMSpecInfo and ns.GetCDMSpecInfo() or {}
                for _, s in ipairs(specs) do
                    s.checked = (s.key == sourceKey)
                end
                EllesmereUI:ShowCDMSpecPickerPopup({
                    title       = "Sync Generic CDs/Buffs",
                    -- The grid lists every class (a profile is shared across
                    -- characters), so an alt's specs are ticked from here; say
                    -- so, or it reads as "this character's specs" only. Keep the
                    -- subtitle to one line so it clears Check All / Uncheck All.
                    subtitle    = EllesmereUI.Lf("Choose which specs sync with %1$s, including your alts' specs (the source is always included)", srcName),
                    confirmText = "Sync",
                    specs       = specs,
                    lockedSpecs = { [sourceKey] = "This is the spec you're syncing from -- it's always included." },
                    foreverActiveKey = curKey,
                    onConfirm   = function(selectedSpecs)
                        selectedSpecs[sourceKey] = true
                        local cnt = 0
                        for _, v in pairs(selectedSpecs) do if v then cnt = cnt + 1 end end
                        if cnt <= 1 then
                            -- Only the source picked -> nothing to sync; clear any
                            -- existing sync and SAY so (one ticked spec is the
                            -- natural first guess at "sync FROM this spec").
                            if ns.ClearRPTSync then ns.ClearRPTSync() end
                            EllesmereUI.Print("|cff0cd29fEllesmereUI CDM:|r " .. EllesmereUI.L("Sync cleared -- only one spec was selected. Tick at least two specs (including other characters' specs) to sync between them."))
                            EllesmereUI:RefreshPage(true)
                            return
                        end
                        if ns.SetupRPTSync then ns.SetupRPTSync(selectedSpecs, sourceKey) end
                        if ns.FullCDMRebuild then ns.FullCDMRebuild("profile_import") end
                        -- Which bar each entry sits on is synced; its SLOT is not
                        -- (every spec keeps its own ordering) -- easily read as a
                        -- bug, so the print states it explicitly.
                        EllesmereUI.Print("|cff0cd29fEllesmereUI CDM:|r " .. EllesmereUI.Lf("Syncing generic CDs/buffs across %d specs. Icon order is not synced -- each spec keeps its own arrangement.", cnt))
                        EllesmereUI:RefreshPage(true)
                    end,
                })
            end)
        end

        -- Edit an existing sync: open the spec picker directly (no source step),
        -- with the currently-synced specs pre-checked. Unchecking a spec drops it
        -- from the sync (its trinkets/pots/racials/buff presets are left as-is);
        -- checking a new spec folds it in. Falling to one-or-zero specs clears it.
        local function EditRPTSync()
            -- Pre-check EVERY synced spec, not just the current class's: a sync
            -- can span other classes (one profile across characters), and the
            -- grid shows all classes -- seed from the STORED sync set, not from
            -- GetCDMSpecInfo (which only returns the current class's specs).
            local existing = ns.GetRPTSyncSpecs and ns.GetRPTSyncSpecs()
            local specs = {}
            if existing then
                for key in pairs(existing) do
                    specs[#specs + 1] = { key = key, checked = true }
                end
            end
            EllesmereUI:ShowCDMSpecPickerPopup({
                title       = "Sync Generic CDs/Buffs",
                subtitle    = "Uncheck a spec to remove it from the sync. Removed specs keep their current trinkets, pots, racials & buff presets.",
                confirmText = "Save",
                specs       = specs,
                foreverActiveKey = EllesmereUI.IS_FOREVER and ns.GetActiveSpecKey and ns.GetActiveSpecKey() or nil,
                onConfirm   = function(selectedSpecs)
                    local cnt = 0
                    for _, v in pairs(selectedSpecs) do if v then cnt = cnt + 1 end end
                    if cnt <= 1 then
                        -- One or zero specs left -> nothing to sync; clear it.
                        -- Announced for the same reason as the setup path: the
                        -- sync is discarded here, not merely left unchanged.
                        if ns.ClearRPTSync then ns.ClearRPTSync() end
                        EllesmereUI.Print("|cff0cd29fEllesmereUI CDM:|r " .. EllesmereUI.L("Sync cleared -- fewer than two specs remained selected."))
                        EllesmereUI:RefreshPage(true)
                        return
                    end
                    if ns.UpdateRPTSyncSpecs then ns.UpdateRPTSyncSpecs(selectedSpecs) end
                    if ns.FullCDMRebuild then ns.FullCDMRebuild("profile_import") end
                    EllesmereUI:RefreshPage(true)
                end,
            })
        end

        -- Route the third action button: edit the live sync, or set up a new one.
        local function DoRPTSync()
            if ns.HasRPTSync and ns.HasRPTSync() then
                EditRPTSync()
            else
                DoRPTSyncSetup()
            end
        end

        -- Action buttons: repopulate + open Blizzard CDM + sync generic CDs/buffs
        -- (trinkets, pots, racials & buff presets across specs).
        -- The third button keeps the same label whether or not a sync exists;
        -- DoRPTSync routes to setup vs edit based on ns.HasRPTSync().
        _, h = W:WideTripleButton(parent,
            "Repopulate from Blizzard CDM", "Open Blizzard CDM", "Sync Generic CDs/Buffs", y,
            function()
                EllesmereUI:ShowConfirmPopup({
                    title = "Repopulate Bars",
                    message = "This will reset all default bar spell assignments for the current spec to match Blizzard's CDM layout. Spells you added yourself (presets, custom IDs and racials) are kept. Continue?",
                    confirmText = "Repopulate",
                    cancelText = "Cancel",
                    onConfirm = function()
                        if ns.RepopulateFromBlizzard then
                            ns.RepopulateFromBlizzard()
                        end
                        C_Timer.After(0.15, function()
                            if optState._cdmPreview and optState._cdmPreview.Update then
                                optState._cdmPreview:Update()
                            end
                            UpdateCDMPreviewAndResize()
                        end)
                    end,
                })
            end,
            function()
                local bd = SelectedCDMBar()
                local barType = bd and (bd.barType or bd.key) or "cooldowns"
                local isBuff = (barType == "buffs")
                if ns.OpenBlizzardCDMTab then
                    ns.OpenBlizzardCDMTab(isBuff)
                end
            end,
            DoRPTSync, 225);  y = y - h

        local barKey = barData.key
        local function BD()
            local pp = DB()
            if not pp or not pp.cdmBars or not pp.cdmBars.bars then return barData end
            for _, b in ipairs(pp.cdmBars.bars) do
                if b.key == barKey then return b end
            end
            return barData
        end

        local isDefault = (barData.key == "cooldowns" or barData.key == "utility" or barData.key == "buffs")
        local isBuffBar = ns.IsBarBuffFamily(barData)
        -- FocusKick is the special nameplate-anchored bar. Most options panel
        -- sections are hidden for it; only Icon Display + a custom Nameplate
        -- Anchor row are shown.
        local isFocusKick = (barData.key == "focuskick")

        -------------------------------------------------------------------
        --  CONTENT HEADER  (dropdown + live preview)
        -------------------------------------------------------------------
        EllesmereUI:ClearContentHeader()
        optState._cdmPreview = nil

        optState._cdmHeaderBuilder = function(hdr, hdrW)
            local PAD = EllesmereUI.CONTENT_PAD or 10
            local PV_PAD = 10
            local fy = -20

            -- Bar selector dropdown (custom-built to support delete buttons)
            local DD_H = 34
            local ddW = 350

            local DDS = EllesmereUI.DD_STYLE
            local mBgR  = DDS.BG_R
            local mBgG  = DDS.BG_G
            local mBgB  = DDS.BG_B
            local mBgA  = DDS.BG_A
            local mBgHA = DDS.BG_HA
            local mBrdA = DDS.BRD_A
            local mBrdHA = DDS.BRD_HA or 0.30
            local mTxtA = DDS.TXT_A
            local mTxtHA = DDS.TXT_HA or 1
            local hlA   = DDS.ITEM_HL_A
            local selA  = DDS.ITEM_SEL_A
            local tDimR = EllesmereUI.TEXT_DIM_R or 0.7
            local tDimG = EllesmereUI.TEXT_DIM_G or 0.7
            local tDimB = EllesmereUI.TEXT_DIM_B or 0.7
            local tDimA = EllesmereUI.TEXT_DIM_A or 0.85
            local ITEM_H = 26
            local MEDIA = "Interface\\AddOns\\EllesmereUI\\media\\"
            local ICON_SZ = 14

            -- Dropdown button
            local ddBtn = CreateFrame("Button", nil, hdr)
            PP.Size(ddBtn, ddW, DD_H)
            ddBtn:SetFrameLevel(hdr:GetFrameLevel() + 5)
            local ddBg = ddBtn:CreateTexture(nil, "BACKGROUND")
            ddBg:SetAllPoints(); ddBg:SetColorTexture(mBgR, mBgG, mBgB, mBgA)
            local ddBrd = EllesmereUI.MakeBorder(ddBtn, 1, 1, 1, mBrdA, EllesmereUI.PanelPP)
            local ddLbl = ddBtn:CreateFontString(nil, "OVERLAY")
            ddLbl:SetFont(FONT_PATH, 13, GetCDMOptOutline())
            ddLbl:SetAlpha(mTxtA)
            ddLbl:SetJustifyH("LEFT")
            ddLbl:SetWordWrap(false); ddLbl:SetMaxLines(1)
            ddLbl:SetPoint("LEFT", ddBtn, "LEFT", 12, 0)
            -- Arrow (standard EllesmereUI dropdown arrow)
            local arrow = EllesmereUI.MakeDropdownArrow(ddBtn, 12, EllesmereUI.PanelPP)
            ddLbl:SetPoint("RIGHT", arrow, "LEFT", -5, 0)

            local function UpdateDDLabel()
                local bd = bars[optState.selectedCDMBarIndex]
                local label = bd and EllesmereUI.L(bd.name or bd.key) or ""
                ddLbl:SetText(label)
            end
            UpdateDDLabel()

            -- Custom-bar display order for THIS dropdown only: a pure VIEW over
            -- p.cdmBars.bars. The bars array is NEVER reordered -- stored
            -- numeric bar paths (unlock/override data) and selectedCDMBarIndex
            -- depend on array positions. Saved key list first (keys whose bar
            -- no longer exists are dropped), then any custom bars not yet
            -- listed, in array order (new bars append). Same self-healing
            -- contract as the RF party Class Order list. Built-ins (cooldowns/
            -- utility/buffs/focuskick) are never part of the order list.
            local function CustomBarDisplayOrder()
                local order, seen, byKey = {}, {}, {}
                for _, b in ipairs(bars) do
                    if b.key and not b.isGhostBar and b.key ~= "cooldowns"
                       and b.key ~= "utility" and b.key ~= "buffs" and b.key ~= "focuskick" then
                        byKey[b.key] = b
                    end
                end
                local saved = p.cdmBars.customBarMenuOrder
                if type(saved) == "table" then
                    for _, k in ipairs(saved) do
                        if byKey[k] and not seen[k] then order[#order + 1] = k; seen[k] = true end
                    end
                end
                for _, b in ipairs(bars) do
                    local k = b.key
                    if k and byKey[k] and not seen[k] then order[#order + 1] = k; seen[k] = true end
                end
                return order, byKey
            end

            -- Custom dropdown menu
            local ddMenu
            local function BuildDDMenu()
                if ddMenu then ddMenu:Hide(); ddMenu = nil end
                local menu = CreateFrame("Frame", nil, UIParent)
                menu:SetFrameStrata("FULLSCREEN_DIALOG")
                menu:SetFrameLevel(300)
                menu:SetClampedToScreen(true)
                menu:SetPoint("TOPLEFT", ddBtn, "BOTTOMLEFT", 0, -2)
                menu:SetPoint("TOPRIGHT", ddBtn, "BOTTOMRIGHT", 0, -2)
                local bg = menu:CreateTexture(nil, "BACKGROUND")
                bg:SetAllPoints(); bg:SetColorTexture(mBgR, mBgG, mBgB, mBgHA)
                EllesmereUI.MakeBorder(menu, 1, 1, 1, mBrdA, EllesmereUI.PP)

                local mH = 4
                local customCount = 0
                for _, b in ipairs(bars) do
                    if b.key ~= "cooldowns" and b.key ~= "utility" and b.key ~= "buffs" and not b.isGhostBar then
                        customCount = customCount + 1
                    end
                end

                -- Display list: array order, except CUSTOM bars render in the saved
                -- dropdown order (CustomBarDisplayOrder). All customs emit as one block
                -- at the first custom bar's array position, so an empty/absent saved
                -- order reproduces the old listing byte-identically. Every entry
                -- carries its REAL array index (realIdx) -- selection and all other
                -- consumers keep using array positions; only this listing is reordered.
                local ordKeys, ordByKey = CustomBarDisplayOrder()
                local reorderable = #ordKeys >= 2
                local displayList, realIdx = {}, {}
                do
                    local customsEmitted = false
                    for bIdx, b in ipairs(bars) do
                        realIdx[b] = bIdx
                        if not b.isGhostBar then
                            if ordByKey[b.key] then
                                if not customsEmitted then
                                    customsEmitted = true
                                    for _, k in ipairs(ordKeys) do
                                        displayList[#displayList + 1] = ordByKey[k]
                                    end
                                end
                            else
                                displayList[#displayList + 1] = b
                            end
                        end
                    end
                end

                -- In-menu drag-to-reorder for the custom-bar band: each custom
                -- row gets a grip ("=") that drags the row; a green insertion
                -- line previews the drop slot; releasing writes ONLY the display
                -- key list (p.cdmBars.customBarMenuOrder) and re-renders the
                -- menu in place. Same drag mechanics as the shared reorder
                -- widget (RF Class Order). Row clicks / delete / rename are
                -- untouched -- only the grip starts a drag.
                local dragState = {}
                local customRows = {}
                local hintShown = false
                local insLine
                if reorderable then
                    insLine = menu:CreateTexture(nil, "OVERLAY", nil, 7)
                    insLine:SetHeight(2)
                    local EG = EllesmereUI.ELLESMERE_GREEN or { r = 0.05, g = 0.82, b = 0.62 }
                    insLine:SetColorTexture(EG.r, EG.g, EG.b, 0.9)
                    insLine:Hide()
                end

                for _, b in ipairs(displayList) do
                    local idx = realIdx[b]
                    if b.isGhostBar then
                        -- skip ghost bar in dropdown
                    else
                    -- FocusKick is treated as a built-in: cannot be deleted
                    -- or renamed even though its barType is "cooldowns".
                    local isFocusKick = (b.key == "focuskick")
                    local isCustom = (b.key ~= "cooldowns" and b.key ~= "utility" and b.key ~= "buffs" and not isFocusKick)

                    -- Hint above the custom-bar band (only when reorderable).
                    if reorderable and not hintShown and ordByKey[b.key] then
                        hintShown = true
                        local ht = menu:CreateFontString(nil, "OVERLAY")
                        ht:SetFont(FONT_PATH, 10, GetCDMOptOutline())
                        ht:SetPoint("TOPLEFT", menu, "TOPLEFT", 10, -mH - 4)
                        ht:SetTextColor(1, 1, 1, 0.25)
                        ht:SetText(EllesmereUI.L("Drag to Reorder Bars"))
                        mH = mH + 18
                    end

                    local item = CreateFrame("Button", nil, menu)
                    item:SetHeight(ITEM_H)
                    item:SetPoint("TOPLEFT", menu, "TOPLEFT", 1, -mH)
                    item:SetPoint("TOPRIGHT", menu, "TOPRIGHT", -1, -mH)
                    item:SetFrameLevel(menu:GetFrameLevel() + 2)
                    if reorderable and ordByKey[b.key] then
                        customRows[#customRows + 1] = { item = item, key = b.key, topY = -mH }
                    end

                    local iLbl = item:CreateFontString(nil, "OVERLAY")
                    iLbl:SetFont(FONT_PATH, 11, GetCDMOptOutline())
                    iLbl:SetTextColor(tDimR, tDimG, tDimB, tDimA)
                    iLbl:SetJustifyH("LEFT")
                    iLbl:SetWordWrap(false); iLbl:SetMaxLines(1)
                    iLbl:SetPoint("LEFT", item, "LEFT", 10, 0)
                    local displayName = EllesmereUI.L(b.name or b.key)
                    iLbl:SetText(displayName)

                    local iHl = item:CreateTexture(nil, "ARTWORK")
                    iHl:SetAllPoints(); iHl:SetColorTexture(1, 1, 1, 1)
                    iHl:SetAlpha(idx == optState.selectedCDMBarIndex and selA or 0)

                    -- Delete + Rename buttons for custom bars
                    local delBtn, editBtn
                    if isCustom then
                        delBtn = CreateFrame("Button", nil, item)
                        delBtn:SetSize(ICON_SZ, ICON_SZ)
                        delBtn:SetPoint("RIGHT", item, "RIGHT", -8, 0)
                        delBtn:SetFrameLevel(item:GetFrameLevel() + 2)
                        local delIcon = delBtn:CreateTexture(nil, "OVERLAY")
                        delIcon:SetSize(ICON_SZ, ICON_SZ)
                        delIcon:SetPoint("CENTER", delBtn, "CENTER", 0, 0)
                        if delIcon.SetSnapToPixelGrid then delIcon:SetSnapToPixelGrid(false); delIcon:SetTexelSnappingBias(0) end
                        delIcon:SetTexture(MEDIA .. "icons\\eui-close.png")
                        delBtn:SetAlpha(0.75)

                        editBtn = CreateFrame("Button", nil, item)
                        editBtn:SetSize(ICON_SZ, ICON_SZ)
                        editBtn:SetPoint("RIGHT", delBtn, "LEFT", -4, 0)
                        editBtn:SetFrameLevel(item:GetFrameLevel() + 2)
                        local edIcon = editBtn:CreateTexture(nil, "OVERLAY")
                        edIcon:SetSize(ICON_SZ, ICON_SZ)
                        edIcon:SetPoint("CENTER", editBtn, "CENTER", 0, 0)
                        if edIcon.SetSnapToPixelGrid then edIcon:SetSnapToPixelGrid(false); edIcon:SetTexelSnappingBias(0) end
                        edIcon:SetTexture(MEDIA .. "icons\\eui-edit.png")
                        editBtn:SetAlpha(0.75)

                        iLbl:SetPoint("RIGHT", editBtn, "LEFT", -4, 0)

                        -- Drag grip: the ONLY drag affordance (row click still
                        -- selects, delete/rename untouched). Same grip glyph +
                        -- 3px threshold + insertion-line mechanics as the
                        -- shared reorder widget. Drop writes the display key
                        -- list and re-renders this menu in place.
                        if reorderable and ordByKey[b.key] then
                            iLbl:SetPoint("LEFT", item, "LEFT", 24, 0)
                            local gripBtn = CreateFrame("Button", nil, item)
                            gripBtn:SetSize(16, ITEM_H)
                            gripBtn:SetPoint("LEFT", item, "LEFT", 4, 0)
                            gripBtn:SetFrameLevel(item:GetFrameLevel() + 2)
                            local grip = gripBtn:CreateFontString(nil, "OVERLAY")
                            grip:SetFont(FONT_PATH, 10, GetCDMOptOutline())
                            grip:SetPoint("CENTER", gripBtn, "CENTER", 0, 0)
                            grip:SetText("=")
                            grip:SetTextColor(1, 1, 1, 0.2)
                            gripBtn:SetScript("OnEnter", function()
                                grip:SetTextColor(1, 1, 1, 0.6)
                            end)
                            gripBtn:SetScript("OnLeave", function()
                                if not (dragState.row == item and dragState.active) then
                                    grip:SetTextColor(1, 1, 1, 0.2)
                                end
                            end)
                            gripBtn:SetScript("OnMouseDown", function(_, mb)
                                if mb ~= "LeftButton" then return end
                                local _, cy = GetCursorPosition()
                                dragState.row = item
                                dragState.startY = cy
                                dragState.active = false
                                dragState.slot = nil
                            end)
                            gripBtn:SetScript("OnUpdate", function()
                                if dragState.row ~= item or not dragState.startY then return end
                                local _, cy = GetCursorPosition()
                                if not dragState.active then
                                    if math.abs(cy - dragState.startY) < 3 then return end
                                    dragState.active = true
                                    item:SetFrameLevel(menu:GetFrameLevel() + 10)
                                    item:SetAlpha(0.8)
                                    grip:SetTextColor(1, 1, 1, 0.6)
                                end
                                local sc = menu:GetEffectiveScale()
                                local cY = cy / sc
                                local mT = menu:GetTop() or 0
                                -- Insertion slot among the custom rows (skip self).
                                local iI = #customRows
                                for ri, r2 in ipairs(customRows) do
                                    if r2.item ~= item then
                                        local rm = mT + r2.topY - ITEM_H / 2
                                        if cY > rm then iI = ri; break end
                                        iI = ri + 1
                                    end
                                end
                                iI = math.max(1, math.min(iI, #customRows + 1))
                                dragState.slot = iI
                                local bandTop = customRows[1] and customRows[1].topY or 0
                                local lnY = (iI <= 1) and (bandTop + 1) or (bandTop - (iI - 1) * ITEM_H + 1)
                                insLine:ClearAllPoints()
                                insLine:SetPoint("TOPLEFT", menu, "TOPLEFT", 8, lnY)
                                insLine:SetPoint("TOPRIGHT", menu, "TOPRIGHT", -8, lnY)
                                insLine:Show()
                                item:ClearAllPoints()
                                item:SetPoint("TOPLEFT", menu, "TOPLEFT", 1, cY - mT)
                                item:SetPoint("TOPRIGHT", menu, "TOPRIGHT", -1, cY - mT)
                            end)
                            gripBtn:SetScript("OnMouseUp", function(_, mb)
                                if mb ~= "LeftButton" or dragState.row ~= item then return end
                                local wasActive = dragState.active
                                local slot = dragState.slot
                                dragState.row = nil
                                dragState.startY = nil
                                dragState.active = false
                                dragState.slot = nil
                                if insLine then insLine:Hide() end
                                if not wasActive then return end
                                local from
                                local keys = {}
                                for ri, r2 in ipairs(customRows) do
                                    keys[ri] = r2.key
                                    if r2.item == item then from = ri end
                                end
                                local to = slot or from
                                if from and to then
                                    if from < to then to = to - 1 end
                                    to = math.max(1, math.min(to, #keys))
                                    if from ~= to then
                                        local mv = table.remove(keys, from)
                                        table.insert(keys, to, mv)
                                        local pp = DB()
                                        if pp and pp.cdmBars then
                                            pp.cdmBars.customBarMenuOrder = keys
                                        end
                                    end
                                end
                                -- Re-render in the new order (also re-anchors the
                                -- dragged row); the rebuilt menu stays open.
                                BuildDDMenu()
                            end)
                        end

                        local function InlineBtnEnter(self)
                            self:SetAlpha(1)
                            iLbl:SetTextColor(1, 1, 1, 1)
                            iHl:SetAlpha(hlA)
                            delBtn:SetAlpha(0.85); editBtn:SetAlpha(0.85)
                        end
                        local function InlineBtnLeave(self)
                            if item:IsMouseOver() or delBtn:IsMouseOver() or editBtn:IsMouseOver() then
                                self:SetAlpha(0.85); return
                            end
                            delBtn:SetAlpha(0.75); editBtn:SetAlpha(0.75)
                            iLbl:SetTextColor(tDimR, tDimG, tDimB, tDimA)
                            iHl:SetAlpha(idx == optState.selectedCDMBarIndex and selA or 0)
                        end

                        delBtn:SetScript("OnEnter", function(self)
                            InlineBtnEnter(self)
                            EllesmereUI.ShowWidgetTooltip(self, "Delete")
                        end)
                        delBtn:SetScript("OnLeave", function(self)
                            InlineBtnLeave(self)
                            EllesmereUI.HideWidgetTooltip()
                        end)
                        editBtn:SetScript("OnEnter", function(self)
                            InlineBtnEnter(self)
                            EllesmereUI.ShowWidgetTooltip(self, "Rename")
                        end)
                        editBtn:SetScript("OnLeave", function(self)
                            InlineBtnLeave(self)
                            EllesmereUI.HideWidgetTooltip()
                        end)
                        delBtn:SetScript("OnClick", function()
                            menu:Hide()
                            local delName = b.name or b.key
                            local delKey = b.key
                            EllesmereUI:ShowConfirmPopup({
                                title = "Delete Bar",
                                message = EllesmereUI.Lf("Are you sure you want to delete \"%1$s\"?", delName),
                                confirmText = "Delete",
                                cancelText = "Cancel",
                                onConfirm = function()
                                    ns.RemoveCDMBar(delKey)
                                    -- Select the cooldowns bar after deletion
                                    optState.selectedCDMBarIndex = 1
                                    for bi, bb in ipairs(bars) do
                                        if bb.key == "cooldowns" then optState.selectedCDMBarIndex = bi; break end
                                    end
                                    Refresh()
                                    EllesmereUI:InvalidateContentHeaderCache()
                                    EllesmereUI:SetContentHeader(optState._cdmHeaderBuilder)
                                    EllesmereUI:RefreshPage(true)
                                end,
                            })
                        end)
                        editBtn:SetScript("OnClick", function()
                            menu:Hide()
                            local oldName = b.name or b.key
                            EllesmereUI:ShowInputPopup({
                                title = "Rename Bar",
                                message = EllesmereUI.Lf("Enter a new name for \"%1$s\":", oldName),
                                placeholder = oldName,
                                confirmText = "Rename",
                                cancelText = "Cancel",
                                onConfirm = function(newName)
                                    newName = newName and strtrim(newName) or ""
                                    if newName == "" or newName == oldName then return end
                                    b.name = newName
                                    EllesmereUI:InvalidateContentHeaderCache()
                                    EllesmereUI:SetContentHeader(optState._cdmHeaderBuilder)
                                    EllesmereUI:RefreshPage(true)
                                    if ns.RegisterCDMUnlockElements then
                                        ns.RegisterCDMUnlockElements()
                                    end
                                end,
                            })
                        end)
                    end

                    item:SetScript("OnEnter", function()
                        iLbl:SetTextColor(1, 1, 1, 1)
                        iHl:SetAlpha(hlA)
                        if delBtn then delBtn:SetAlpha(1) end
                        if editBtn then editBtn:SetAlpha(1) end
                    end)
                    item:SetScript("OnLeave", function()
                        if delBtn and delBtn:IsMouseOver() then return end
                        if editBtn and editBtn:IsMouseOver() then return end
                        iLbl:SetTextColor(tDimR, tDimG, tDimB, tDimA)
                        iHl:SetAlpha(idx == optState.selectedCDMBarIndex and selA or 0)
                        if delBtn then delBtn:SetAlpha(0.75) end
                        if editBtn then editBtn:SetAlpha(0.75) end
                    end)
                    item:SetScript("OnClick", function()
                        menu:Hide()
                        optState.selectedCDMBarIndex = idx
                        EllesmereUI:InvalidateContentHeaderCache()
                        EllesmereUI:SetContentHeader(optState._cdmHeaderBuilder)
                        EllesmereUI:RefreshPage(true)
                    end)

                    mH = mH + ITEM_H
                end -- else (not ghost bar)
                end -- for displayList

                -- Divider before add-bar options
                local div = menu:CreateTexture(nil, "ARTWORK")
                div:SetHeight(1)
                div:SetColorTexture(1, 1, 1, 0.10)
                div:SetPoint("TOPLEFT", menu, "TOPLEFT", 1, -mH - 4)
                div:SetPoint("TOPRIGHT", menu, "TOPRIGHT", -1, -mH - 4)
                mH = mH + 9

                -- "Add New ..." items (disabled if at cap)
                local atCap = customCount >= (ns.MAX_CUSTOM_BARS or 6)
                -- Custom Aura ("custom_buff") bars were merged into Buff bars: a
                -- Buff bar now hosts Blizzard-tracked buffs AND injected preset/
                -- custom buffs, so there's no separate Aura bar type to create.
                local addBarTypes = {
                    { type = "cooldowns",   label = EllesmereUI.L("+ Add New Cooldowns Bar") },
                    { type = "utility",     label = EllesmereUI.L("+ Add New Utility Bar") },
                    { type = "buffs",       label = EllesmereUI.L("+ Add New Buff Bar") },
                }
                for _, entry in ipairs(addBarTypes) do
                    local addItem = CreateFrame("Button", nil, menu)
                    addItem:SetHeight(ITEM_H)
                    addItem:SetPoint("TOPLEFT", menu, "TOPLEFT", 1, -mH)
                    addItem:SetPoint("TOPRIGHT", menu, "TOPRIGHT", -1, -mH)
                    addItem:SetFrameLevel(menu:GetFrameLevel() + 2)
                    local addLbl = addItem:CreateFontString(nil, "OVERLAY")
                    addLbl:SetFont(FONT_PATH, 11, GetCDMOptOutline())
                    addLbl:SetPoint("LEFT", addItem, "LEFT", 10, 0)
                    addLbl:SetJustifyH("LEFT")
                    if atCap then
                        addLbl:SetText(EllesmereUI.Lf("%1$s (max %2$s)", entry.label, ns.MAX_CUSTOM_BARS or 6))
                        addLbl:SetTextColor(tDimR, tDimG, tDimB, tDimA * 0.4)
                    else
                        addLbl:SetText(entry.label)
                        addLbl:SetTextColor(tDimR, tDimG, tDimB, tDimA)
                        local addHl = addItem:CreateTexture(nil, "ARTWORK")
                        addHl:SetAllPoints(); addHl:SetColorTexture(1, 1, 1, 1); addHl:SetAlpha(0)
                        local bType = entry.type
                        addItem:SetScript("OnEnter", function()
                            addLbl:SetTextColor(1, 1, 1, 1); addHl:SetAlpha(hlA)
                        end)
                        addItem:SetScript("OnLeave", function()
                            addLbl:SetTextColor(tDimR, tDimG, tDimB, tDimA); addHl:SetAlpha(0)
                        end)
                        addItem:SetScript("OnClick", function()
                            menu:Hide()
                            ns.AddCDMBar(bType)
                            optState.selectedCDMBarIndex = #p.cdmBars.bars
                            Refresh()
                            EllesmereUI:InvalidateContentHeaderCache()
                            EllesmereUI:SetContentHeader(optState._cdmHeaderBuilder)
                            EllesmereUI:RefreshPage(true)
                        end)
                    end
                    mH = mH + ITEM_H
                end

                menu:SetHeight(mH + 4)

                -- Close on left-click outside (non-blocking). Never dismiss while a custom-bar row is being dragged -- a fast drag can momentarily leave the menu bounds.
                menu:SetScript("OnUpdate", function(m)
                    if dragState.active then return end
                    if not m:IsMouseOver() and not ddBtn:IsMouseOver() and IsMouseButtonDown("LeftButton") then
                        m:Hide()
                    end
                end)
                menu:HookScript("OnHide", function(m) m:SetScript("OnUpdate", nil) end)

                menu:Show()
                ddMenu = menu
            end

            -- Dropdown button hover/click
            ddBtn:SetScript("OnEnter", function()
                ddLbl:SetAlpha(mTxtHA)
                ddBrd:SetColor(1, 1, 1, mBrdHA)
                ddBg:SetColorTexture(mBgR, mBgG, mBgB, mBgHA)
            end)
            ddBtn:SetScript("OnLeave", function()
                if ddMenu and ddMenu:IsShown() then return end
                ddLbl:SetAlpha(mTxtA)
                ddBrd:SetColor(1, 1, 1, mBrdA)
                ddBg:SetColorTexture(mBgR, mBgG, mBgB, mBgA)
            end)
            ddBtn:SetScript("OnClick", function()
                if ddMenu and ddMenu:IsShown() then ddMenu:Hide() else BuildDDMenu() end
            end)
            ddBtn:HookScript("OnHide", function() if ddMenu then ddMenu:Hide() end end)

            PP.Point(ddBtn, "TOP", hdr, "TOP", 0, fy)
            fy = fy - DD_H - PV_PAD

            -- Live CDM bar preview
            local previewH = BuildCDMLivePreview(hdr, fy)
            fy = fy - previewH - PV_PAD

            optState._cdmHeaderFixedH = 20 + DD_H + PV_PAD + PV_PAD

            return math.abs(fy)
        end
        EllesmereUI:SetContentHeader(optState._cdmHeaderBuilder)

        -- Refresh preview icons on mount/dismount (skyriding swaps action bar icons). Skipped
        -- during a hidden search pre-build for the same reason as the pageListener in BuildBarGlowsPage: OnHide cleanup may never fire for a never-visible wrapper, leaking the listener all session.
        if not EllesmereUI._prebuilding then
            local mountListener = CreateFrame("Frame")
            mountListener:RegisterEvent("PLAYER_MOUNT_DISPLAY_CHANGED")
            mountListener:SetScript("OnEvent", function()
                EllesmereUI:RefreshPage(true)
            end)
            parent:HookScript("OnHide", function()
                mountListener:UnregisterAllEvents()
            end)
        end

        -------------------------------------------------------------------
        --  Scrollable options
        -------------------------------------------------------------------

        -------------------------------------------------------------------
        --  BAR LAYOUT / ICON DISPLAY
        -------------------------------------------------------------------
        parent._showRowDivider = true

        if barData.key == "buffs" then
            -- ("Use Blizzard Buff Bar" toggle temporarily removed.)
        end

        -------------------------------------------------------------------
        --  BAR LAYOUT
        -------------------------------------------------------------------
        -- Sync helper: all bars except ghost/focuskick. FocusKick is a nameplate-anchored
        -- identity and never receives global syncs.
        local function ForEachSyncBar(fn)
            local pp = DB(); if not pp or not pp.cdmBars then return end
            for _, b in ipairs(pp.cdmBars.bars) do
                if not b.isGhostBar and b.key ~= "focuskick" then fn(b) end
            end
        end

        if not isFocusKick then
        _, h = W:SectionHeader(parent, "BAR LAYOUT", y);  y = y - h

        -- Row 1: (Sync) Visibility. Mouseover stays structurally absent for CDM bars
        -- (noMouseover), matching the old VIS_VALUES_CDM list.
        local visRow, visH = EllesmereUI.BuildVisibilityRow(W, parent, y,
            { getStore = BD, legacyKey = "barVisibility",
              caps = { partyIncludesRaid = false, noMouseover = true, luaDragonriding = true },
              -- The three built-in bars ship visHideHousing = true in DEFAULTS, so an
              -- explicit uncheck must persist false or DeepMergeDefaults re-fills it to
              -- true on next login. Harmless for other bars: they never go through that
              -- merge, so the checkbox reads store[k] == true either way.
              trueDefaultOpts = { visHideHousing = true },
              onChanged = function()
                  ns.CDMApplyVisibility()
              end,
              onOptionChanged = function()
                  ns.CDMApplyVisibility()
              end },
            -- Number of Rows moved up into the slot the Visibility Options dropdown
            -- left behind; its Row Icons cog moved with it.
            { type="slider", text="Number of Rows",
              min=1, max=6, step=1,
              getValue=function() return BD().numRows or 1 end,
              setValue=function(v)
                  local bd = BD()
                  bd.numRows = v
                  if v ~= 2 then
                      bd.topRowCount = nil; bd.customTopRowEnabled = nil
                      bd.bottomRowCount = nil; bd.customBottomRowEnabled = nil
                      bd.topRowSizeOffset = nil; bd.customTopRowSizeEnabled = nil
                      bd.bottomRowSizeOffset = nil; bd.customBottomRowSizeEnabled = nil
                      if bd.rowGrowDirection then
                          -- The row growth pin rides on the 2-row custom split (the
                          -- only layout whose row count changes at runtime). Clear it
                          -- with the rest of the split settings and re-store the
                          -- position in plain edge format from the bar's current spot.
                          bd.rowGrowDirection = nil
                          if ns.RecaptureBarAnchor then ns.RecaptureBarAnchor(bd.key) end
                      end
                  end
                  -- numRows change invalidates cached match dims (rows is one
                  -- of the inputs to the matched-axis dim calculation).
                  bd._matchIconPhys = nil
                  bd._matchExtraPixels = nil
                  bd._matchStride = nil
                  bd._matchExtraPixelsH = nil
                  bd._matchStrideH = nil
                  ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreviewAndResize()
                  EllesmereUI:RefreshPage()
              end });  y = y - visH

        -- ONE sync icon now that both halves share a control: VisFullCopy / VisFullEquals
        -- carry the mode selection and every option boolean together.
        if not EllesmereUI._prebuilding then
            local rgn = visRow._leftRegion
            EllesmereUI.BuildSyncIcon({
                region  = rgn,
                tooltip = "Apply Visibility to all Bars",
                isSynced = function()
                    local src = BD()
                    local synced = true
                    ForEachSyncBar(function(b)
                        if not EllesmereUI.VisFullEquals(src, "barVisibility", b, "barVisibility") then synced = false end
                    end)
                    return synced
                end,
                onClick = function()
                    local src = BD()
                    ForEachSyncBar(function(b)
                        if b ~= src then EllesmereUI.VisFullCopy(b, src, "barVisibility") end
                    end)
                    ns.CDMApplyVisibility(); EllesmereUI:RefreshPage()
                end,
            })
        end

        -- Row 2: Anchor to Cursor | Cursor Position (cog: X + Y)
        do
            local _, cursorH = EllesmereUI.BuildCursorAnchorRow({
                W = W, parent = parent, y = y,
                getData = BD,
                onApply = function()
                    ns.BuildAllCDMBars(); ns.RegisterCDMUnlockElements()
                    Refresh()
                end,
            })
            y = y - cursorH
        end

        -- Bar Opacity is offered for cooldown/utility/buff bars only (excl. focuskick);
        -- other bar types leave the slot blank, as before.
        local isCDOrUtilityRow3 = (barData.barType == "cooldowns" or barData.barType == "utility" or barData.barType == "buffs") and not isFocusKick
        local row3Right
        if isCDOrUtilityRow3 then
            row3Right = { type="slider", text="Bar Opacity",
                min=0, max=100, step=1,
                getValue=function() return math.floor((BD().barOpacity or 1) * 100 + 0.5) end,
                setValue=function(v)
                    BD().barOpacity = v / 100
                    if ns.ApplyBarOpacity then ns.ApplyBarOpacity(BD().key) end
                    UpdateCDMPreview()
                end }
        else
            row3Right = { type="label", text="" }
        end
        local opacityRow
        opacityRow, h = W:DualRow(parent, y,
            { type="toggle", text="Bar Background",
              getValue=function() return BD().barBgEnabled == true end,
              setValue=function(v)
                  BD().barBgEnabled = v
                  ns.BuildAllCDMBars(); Refresh()
                  UpdateCDMPreview(); EllesmereUI:RefreshPage()
              end },
            row3Right);  y = y - h

        -- Inline color swatch on Bar Background (left)
        if not EllesmereUI._prebuilding then
            local rgn = opacityRow._leftRegion
            local ctrl = rgn and rgn._control
            if ctrl and EllesmereUI.BuildColorSwatch then
                local bgSwatch, updateBgSwatch = EllesmereUI.BuildColorSwatch(
                    rgn, opacityRow:GetFrameLevel() + 3,
                    function() return BD().barBgR or 0, BD().barBgG or 0, BD().barBgB or 0, BD().barBgA or 0.5 end,
                    function(r, g, b, a)
                        BD().barBgR = r; BD().barBgG = g; BD().barBgB = b; BD().barBgA = a
                        ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreview()
                    end,
                    true, 20)
                PP.Point(bgSwatch, "RIGHT", ctrl, "LEFT", -8, 0)
                local block = CreateFrame("Frame", nil, bgSwatch)
                block:SetAllPoints(); block:SetFrameLevel(bgSwatch:GetFrameLevel() + 10); block:EnableMouse(true)
                block:SetScript("OnEnter", function()
                    EllesmereUI.ShowWidgetTooltip(bgSwatch, EllesmereUI.DisabledTooltip("Bar Background"))
                end)
                block:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
                EllesmereUI.RegisterWidgetRefresh(function()
                    if updateBgSwatch then updateBgSwatch() end
                    local on = BD().barBgEnabled == true
                    bgSwatch:SetAlpha(on and 1 or 0.3)
                    if on then block:Hide() else block:Show() end
                end)
                local on = BD().barBgEnabled == true
                bgSwatch:SetAlpha(on and 1 or 0.3)
                if on then block:Hide() else block:Show() end
            end
        end

        -- Inline cog on Number of Rows (now in the Visibility row's right slot):
        -- Row Icons settings (only relevant when numRows == 2)
        if not EllesmereUI._prebuilding then
            local leftRgn = visRow._rightRegion
            local ctrl = leftRgn._control
            local function customTopOff()
                local bd = BD()
                return not bd or not bd.customTopRowEnabled
            end
            local function rowsNotTwo()
                return (BD().numRows or 1) ~= 2
            end
            -- Row-size options are locked while the bar is width/height matched,
            -- exactly like Icon Scale (a per-row size offset can't honor a match).
            local rsMatchKey = "CDM_" .. BD().key
            local rsWDis, rsWTip = EllesmereUI.MatchGuard(rsMatchKey, "Width")
            local rsHDis, rsHTip = EllesmereUI.MatchGuard(rsMatchKey, "Height")
            local function rowSizeMatched() return rsWDis() or rsHDis() end
            local function rowSizeMatchTip()
                if rsWDis() then return rsWTip() end
                return rsHTip()
            end
            -- Row Growth dropdown: labels track the bar's orientation (rows
            -- stack vertically on horizontal bars, horizontally on vertical
            -- bars). The page rebuilds on orientation flips and bar switches,
            -- so build-time resolution is safe.
            local rowGrowValues, rowGrowOrder, rowGrowTip
            if BD().verticalOrientation then
                rowGrowValues = { CENTER = "Grow Centered", RIGHT = "Grow Right", LEFT = "Grow Left" }
                rowGrowOrder = { "CENTER", "RIGHT", "LEFT" }
                rowGrowTip = "How extra columns grow when the second column appears or disappears. Grow Right keeps the left column in place, Grow Left keeps the right column in place, Grow Centered keeps the bar centered."
            else
                rowGrowValues = { CENTER = "Grow Centered", DOWN = "Grow Down", UP = "Grow Up" }
                rowGrowOrder = { "CENTER", "DOWN", "UP" }
                rowGrowTip = "How extra rows grow when the second row appears or disappears. Grow Down keeps the top row in place, Grow Up keeps the bottom row in place, Grow Centered keeps the bar centered."
            end
            EllesmereUI.BuildInlineCog(leftRgn, { anchorTo = ctrl, icon = EllesmereUI.COGS_ICON,
                title = "Row Icons",
                rows = {
                    { type="dropdown", label="Row Growth",
                      values=rowGrowValues, order=rowGrowOrder,
                      tooltip=rowGrowTip,
                      -- Only meaningful with the 2-row custom split (the only
                      -- layout whose row count changes at runtime). Anchored
                      -- bars are positioned by their anchor system, which
                      -- ignores the pin entirely.
                      disabled=function()
                          if rowsNotTwo() then return true end
                          local b = BD()
                          if b.anchorTo and b.anchorTo ~= "none" then return true end
                          if EllesmereUI.IsUnlockAnchored and EllesmereUI.IsUnlockAnchored("CDM_" .. b.key) then return true end
                          return false
                      end,
                      disabledTooltip=function()
                          if rowsNotTwo() then return "This option requires exactly 2 rows" end
                          return "Not available while this bar is anchored to another element"
                      end,
                      rawTooltip=true,
                      get=function() return BD().rowGrowDirection or "CENTER" end,
                      set=function(v)
                          local bd = BD()
                          bd.rowGrowDirection = (v ~= "CENTER") and v or nil
                          -- Recapture the corner from the bar's current spot BEFORE
                          -- rebuilding, so the new anchor pins where the bar sits now.
                          if ns.RecaptureBarAnchor then ns.RecaptureBarAnchor(bd.key) end
                          ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreviewAndResize()
                      end },
                    { type="toggle", label="Custom Base Row Count",
                      -- The base row is the FIRST DATA row: it fills first and it is
                      -- the row Row Growth keeps in place (visual top normally, visual
                      -- bottom/right when reversed). Stored in the legacy topRowCount
                      -- keys; the legacy bottom-count fields are still honored at
                      -- runtime for old profiles but no longer have UI. Enabling this
                      -- clears the legacy bottom flag so the base count takes effect.
                      disabled=rowsNotTwo,
                      disabledTooltip="This option requires exactly 2 rows",
                      rawTooltip=true,
                      get=function() return BD().customTopRowEnabled end,
                      set=function(v)
                          BD().customTopRowEnabled = v
                          if v then BD().customBottomRowEnabled = nil end
                          ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreviewAndResize()
                      end },
                    { type="slider", label="Base Row Icons",
                      min=1, max=15, step=1,
                      tooltip="How many icons to show on the base row (the row that fills first and that Row Growth keeps in place). The rest go on the second row.",
                      disabled=function() return rowsNotTwo() or customTopOff() end,
                      disabledTooltip=function()
                          if rowsNotTwo() then return "This option requires exactly 2 rows" end
                          return "Custom Base Row Count"
                      end,
                      get=function()
                          local bd = BD()
                          if bd.topRowCount and bd.topRowCount > 0 then return bd.topRowCount end
                          local count = 0
                          local sdTR = ns.GetBarSpellData(bd.key)
                          if sdTR and sdTR.assignedSpells then
                              for _, sid in ipairs(sdTR.assignedSpells) do if sid and sid ~= 0 then count = count + 1 end end
                          end
                          if count == 0 then return 1 end
                          return math.ceil(count / 2)
                      end,
                      set=function(v)
                          if v == 0 then v = nil end
                          BD().topRowCount = v
                          ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreviewAndResize()
                      end },
                    { type="toggle", label="Custom Base Row Size",
                      -- Mutually exclusive with Custom Second Row Size (stored
                      -- in the legacy customBottomRowSize* keys); also locked
                      -- while the bar is width/height matched (same as Icon Scale).
                      disabled=function() return rowsNotTwo() or rowSizeMatched() or BD().customBottomRowSizeEnabled == true end,
                      disabledTooltip=function()
                          if rowsNotTwo() then return "This option requires exactly 2 rows" end
                          if rowSizeMatched() then return rowSizeMatchTip() end
                          return "Disabled while Custom Second Row Size is enabled"
                      end,
                      rawTooltip=true,
                      get=function() return BD().customTopRowSizeEnabled end,
                      set=function(v)
                          BD().customTopRowSizeEnabled = v
                          if v then BD().customBottomRowSizeEnabled = nil end
                          ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreviewAndResize()
                      end },
                    { type="slider", label="Base Icon Size",
                      min=-20, max=20, step=1,
                      tooltip="Offsets the base row's icon size in pixels from Icon Scale. The second row keeps the base size.",
                      disabled=function() return rowsNotTwo() or rowSizeMatched() or not BD().customTopRowSizeEnabled end,
                      disabledTooltip=function()
                          if rowsNotTwo() then return "This option requires exactly 2 rows" end
                          if rowSizeMatched() then return rowSizeMatchTip() end
                          return "Custom Base Row Size"
                      end,
                      rawTooltip=function() return rowSizeMatched() end,
                      get=function() return BD().topRowSizeOffset or 0 end,
                      set=function(v)
                          if v == 0 then v = nil end
                          BD().topRowSizeOffset = v
                          ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreviewAndResize()
                      end },
                    { type="toggle", label="Custom Second Row Size",
                      -- Flip of Custom Base Row Size; mutually exclusive with it.
                      disabled=function() return rowsNotTwo() or rowSizeMatched() or BD().customTopRowSizeEnabled == true end,
                      disabledTooltip=function()
                          if rowsNotTwo() then return "This option requires exactly 2 rows" end
                          if rowSizeMatched() then return rowSizeMatchTip() end
                          return "Disabled while Custom Base Row Size is enabled"
                      end,
                      rawTooltip=true,
                      get=function() return BD().customBottomRowSizeEnabled end,
                      set=function(v)
                          BD().customBottomRowSizeEnabled = v
                          if v then BD().customTopRowSizeEnabled = nil end
                          ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreviewAndResize()
                      end },
                    { type="slider", label="Second Row Icon Size",
                      min=-20, max=20, step=1,
                      tooltip="Offsets the second row's icon size in pixels from Icon Scale. The base row keeps the base size.",
                      disabled=function() return rowsNotTwo() or rowSizeMatched() or not BD().customBottomRowSizeEnabled end,
                      disabledTooltip=function()
                          if rowsNotTwo() then return "This option requires exactly 2 rows" end
                          if rowSizeMatched() then return rowSizeMatchTip() end
                          return "Custom Second Row Size"
                      end,
                      rawTooltip=function() return rowSizeMatched() end,
                      get=function() return BD().bottomRowSizeOffset or 0 end,
                      set=function(v)
                          if v == 0 then v = nil end
                          BD().bottomRowSizeOffset = v
                          ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreviewAndResize()
                      end },
                },
            })
            -- Cog stays clickable at any row count; the rows inside gate
            -- themselves on the 2-row requirement individually.
        end

        -- Inline cog on Bar Opacity (now in the Bar Background row): fade the bar to a
        -- chosen alpha while out of combat. Off by default.
        if isCDOrUtilityRow3 then
            local rgn = opacityRow._rightRegion
            local ctrl = rgn and rgn._control
            EllesmereUI.BuildInlineCog(rgn, {
                anchorTo = ctrl,
                title = "Out of Combat Alpha",
                rows = {
                    { type="toggle", label="Fade Out of Combat",
                      tooltip="Dims this bar while out of combat.",
                      rawTooltip=true,
                      get=function() return BD().oocFadeEnabled == true end,
                      set=function(v)
                          BD().oocFadeEnabled = v
                          if ns.CDMApplyVisibility then ns.CDMApplyVisibility() end
                          UpdateCDMPreview()
                      end },
                    { type="slider", label="Out of Combat Alpha",
                      min=0, max=100, step=1,
                      disabled=function() return not BD().oocFadeEnabled end,
                      disabledTooltip="Enable Fade Out of Combat first",
                      rawTooltip=true,
                      get=function() return math.floor((BD().oocFadeAlpha or 0.5) * 100 + 0.5) end,
                      set=function(v)
                          BD().oocFadeAlpha = v / 100
                          if ns.CDMApplyVisibility then ns.CDMApplyVisibility() end
                          UpdateCDMPreview()
                      end },
                },
            })
        end

        -- Max Icons + Overflow To: excess icons (beyond Max, the tail of this bar's order)
        -- render on the target bar for the session. Identity, per-spell settings and the options
        -- preview stay on this bar. Legacy profiles carry nil barType on default bars -- resolve the family via the shared helper, never the raw field.
        local ofBarType = ns.GetBarType and ns.GetBarType(barData) or barData.barType
        local isOverflowBar = (ofBarType == "cooldowns" or ofBarType == "utility")
            and not barData.isGhostBar
            and barData.key ~= (ns.FOCUSKICK_BAR_KEY or "focuskick")
        if isOverflowBar then
            local function OverflowShiftBlocked()
                return (ns.CdmBarHasShiftCdState and ns.CdmBarHasShiftCdState(BD().key)) or false
            end
            -- A bar may not BOTH receive overflow and have its own overflow config: incoming
            -- icons ignore the recipient's cap and never chain onward, so a cap on a recipient
            -- would promise behavior that does not exist. Recipient = ANY bar (enabled or not -- re-enabling must not create the forbidden state) with an active cap+target pair pointing here.
            local function BarIsOverflowRecipient(key)
                local pp = DB()
                if not (pp and pp.cdmBars) then return false end
                for _, b in ipairs(pp.cdmBars.bars) do
                    if b.key ~= key and b.maxIcons and b.maxIcons > 0
                       and b.overflowTarget == key then
                        return true
                    end
                end
                return false
            end
            local ofVals, ofOrder = { [""] = "None" }, { "" }
            do
                local pp = DB()
                if pp and pp.cdmBars then
                    for _, b in ipairs(pp.cdmBars.bars) do
                        local bt = ns.GetBarType and ns.GetBarType(b) or b.barType
                        -- Bars with their own active overflow config are not offered as targets (the recipient rule, other door).
                        local hasOwnOverflow = b.maxIcons and b.maxIcons > 0 and b.overflowTarget ~= nil
                        if b.key ~= barData.key and not b.isGhostBar
                           and b.key ~= (ns.FOCUSKICK_BAR_KEY or "focuskick")
                           and b.key ~= "buffs"
                           and bt ~= "buffs" and bt ~= "custom_buff"
                           and not hasOwnOverflow then
                            ofVals[b.key] = EllesmereUI.L(b.name or b.key)
                            ofOrder[#ofOrder + 1] = b.key
                        end
                    end
                    -- A stored target that the filter (or a bar delete) now excludes still
                    -- displays -- and can be cleared -- rather than masquerading as "None" while active at runtime (pre-rule configs keep working under no-chaining).
                    local cur = barData.overflowTarget
                    if cur and not ofVals[cur] then
                        local curName = cur
                        for _, b in ipairs(pp.cdmBars.bars) do
                            if b.key == cur then curName = b.name or cur; break end
                        end
                        ofVals[cur] = EllesmereUI.L(curName)
                        ofOrder[#ofOrder + 1] = cur
                    end
                end
            end
            _, h = W:DualRow(parent, y,
                { type="slider", text="Max Icons (0 = Off)",
                  min=0, max=20, step=1,
                  -- A blocked bar with a value already set can still lower/clear it -- a disabled control must never trap an existing value on.
                  disabled=function()
                      local b = BD()
                      return (OverflowShiftBlocked() or BarIsOverflowRecipient(b.key))
                          and not (b.maxIcons and b.maxIcons > 0)
                  end,
                  disabledTooltip=function()
                      if BarIsOverflowRecipient(BD().key) then
                          return "Not available while another bar overflows into this bar"
                      end
                      return "Not available while a spell on this bar uses a Cooldown State Shift Icons setting"
                  end,
                  rawTooltip=true,
                  getValue=function() return BD().maxIcons or 0 end,
                  setValue=function(v)
                      if v == 0 then v = nil end
                      BD().maxIcons = v
                      ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreviewAndResize()
                      C_Timer.After(0, function() EllesmereUI:RefreshPage() end)
                  end },
                { type="dropdown", text="Overflow To",
                  values=ofVals, order=ofOrder,
                  -- Recipient bars cannot pick a fresh target (third door); one with a stale target set stays enabled so it can be cleared back to None.
                  disabled=function()
                      local b = BD()
                      return OverflowShiftBlocked()
                          or (BarIsOverflowRecipient(b.key) and not b.overflowTarget)
                          or not (b.maxIcons and b.maxIcons > 0)
                  end,
                  -- Tooltip priority: recipient block, then the plain Max Icons requirement. The
                  -- Shift Icons message only shows when it is the ACTUAL blocker (Max Icons
                  -- already above 0 but a spell carries a shift cooldown-state setting) -- most users never touch that setting, so the default tooltip stays basic.
                  disabledTooltip=function()
                      local b = BD()
                      if BarIsOverflowRecipient(b.key) then
                          return "Not available while another bar overflows into this bar"
                      end
                      if not (b.maxIcons and b.maxIcons > 0) then
                          return "Requires Max Icons to be above 0"
                      end
                      return "Not available while a spell on this bar uses a Cooldown State Shift Icons setting"
                  end,
                  rawTooltip=true,
                  getValue=function()
                      local t = BD().overflowTarget
                      if t and ofVals[t] then return t end
                      return ""
                  end,
                  setValue=function(v)
                      if v == "" then v = nil end
                      BD().overflowTarget = v
                      ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreviewAndResize()
                  end });  y = y - h
        end

        -- Vertical Orientation shares a row with Keep Buffs in Same Place on buff bars
        -- (both apply there), and stands alone -- last row of the section -- otherwise.
        -- Moved down here, after Max Icons/Overflow To; shown for every non-focuskick bar
        -- regardless of overflow capability, same as before the move (this section's outer
        -- gate is `not isFocusKick`, not isOverflowBar).
        local vertOrientCfg = { type="toggle", text="Vertical Orientation",
            getValue=function() return BD().verticalOrientation end,
            setValue=function(v)
                local bd = BD()
                bd.verticalOrientation = v
                bd.growDirection = v and "DOWN" or "RIGHT"
                -- Orientation flip invalidates the row growth direction too (UP/DOWN are
                -- horizontal-bar values, LEFT/RIGHT vertical).
                bd.rowGrowDirection = nil
                -- Orientation flip swaps the meaning of width-axis vs height-axis, so width/height match caches no longer apply.
                bd._matchIconPhys = nil
                bd._matchExtraPixels = nil
                bd._matchStride = nil
                bd._matchExtraPixelsH = nil
                bd._matchStrideH = nil
                ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreviewAndResize()
            end }

        if ns.IsBarBuffFamily(barData) then
            local prof = ns.ECME and ns.ECME.db and ns.ECME.db.profile
            -- (Hide Buffs When Inactive toggle removed: always forced ON.)
        end

        -- Keep Buffs in Same Place (native buff bars): reserves every tracked buff's slot so
        -- active buffs never reposition; inactive slots are invisible. Reuses the Always-Show
        -- placeholder path internally (placeholders injected, then rendered alpha 0). Mutually exclusive with Always Show Buffs -- disabled while that is on.
        -- (Minimum Bar Size moved to the Icon Scale inline cog, user-directed.)
        if isBuffBar then
            _, h = W:DualRow(parent, y,
                { type="toggle", text="Keep Buffs in Same Place",
                  disabled=function()
                      local b = BD()
                      return b.showInactiveBuffIcons == true or AnyIconAlwaysShowOn(b.key)
                  end,
                  disabledTooltip="Disabled while Always Show Buffs is enabled (on the bar, or on any individual buff)", rawTooltip=true,
                  getValue=function() return BD().hidePlaceholderIcon == true end,
                  setValue=function(v)
                      BD().hidePlaceholderIcon = v
                      ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreviewAndResize()
                      EllesmereUI:RefreshPage()
                  end },
                vertOrientCfg); y = y - h
        else
            _, h = W:DualRow(parent, y, vertOrientCfg, { type="label", text="" });  y = y - h
        end

        end -- not isFocusKick (Bar Layout section)

        -------------------------------------------------------------------
        --  FOCUSKICK OPTIONS (FocusKick only)
        -------------------------------------------------------------------
        if isFocusKick then
            _, h = W:SectionHeader(parent, "FocusKick Options", y);  y = y - h

            local NP_SIDE_VALUES = { LEFT = "Left", RIGHT = "Right", TOP = "Top", BOTTOM = "Bottom" }
            local NP_SIDE_ORDER  = { "LEFT", "RIGHT", "TOP", "BOTTOM" }

            -- Row 1: Nameplate Anchor (left) | Focus Text Reminders (right)
            local npRow
            npRow, h = W:DualRow(parent, y,
                { type="dropdown", text="Nameplate Anchor",
                  values = NP_SIDE_VALUES, order = NP_SIDE_ORDER,
                  getValue = function() return BD().nameplateAnchorSide or "LEFT" end,
                  setValue = function(v)
                      BD().nameplateAnchorSide = v
                      if ns.ApplyFocusKickAnchor then ns.ApplyFocusKickAnchor() end
                      EllesmereUI:RefreshPage()
                  end },
                { type="toggle", text="Focus Text Reminders",
                  tooltip = "This will display the word \"FOCUS\" below caster/miniboss mobs in M+ if you have not set your focus. Disabled for specs with no kick.",
                  getValue = function()
                      local bd = BD()
                      return bd.focusReminderEnabled == true
                  end,
                  setValue = function(v)
                      BD().focusReminderEnabled = v
                      if ns.RefreshFocusReminders then ns.RefreshFocusReminders() end
                      EllesmereUI:RefreshPage()
                  end });  y = y - h

            -- Inline cog for Nameplate Offset (left)
            if not EllesmereUI._prebuilding then
                local rgn = npRow._leftRegion
                EllesmereUI.BuildInlineCog(rgn, {
                    icon = EllesmereUI.RESIZE_ICON, anchorTo = rgn._control,
                    title = "Nameplate Offset",
                    rows = {
                        { type = "slider", label = "X Offset", min = -100, max = 100, step = 1,
                          get = function() return BD().nameplateOffsetX or 0 end,
                          set = function(v)
                              BD().nameplateOffsetX = v
                              if ns.ApplyFocusKickAnchor then ns.ApplyFocusKickAnchor() end
                          end },
                        { type = "slider", label = "Y Offset", min = -100, max = 100, step = 1,
                          get = function() return BD().nameplateOffsetY or 0 end,
                          set = function(v)
                              BD().nameplateOffsetY = v
                              if ns.ApplyFocusKickAnchor then ns.ApplyFocusKickAnchor() end
                          end },
                    },
                })
            end

            -- Inline dual swatch + cog for Focus Reminders (right region). Layout right-to-left
            -- along the row's right region: [control] [accent swatch] [custom swatch] [cog].
            -- Accent swatch (closest to control) is the active mode by default; custom swatch dims and blocks while accent is on.
            if not EllesmereUI._prebuilding then
                local rgn = npRow._rightRegion
                local ctrl = rgn and rgn._control

                -- Right (accent) swatch: one-click activation, displays live ELLESMERE_GREEN
                local accentSwatch, updateAccentSwatch = EllesmereUI.BuildColorSwatch(
                    rgn, npRow:GetFrameLevel() + 3,
                    function()
                        local eg = EllesmereUI.ELLESMERE_GREEN
                        if eg then return eg.r, eg.g, eg.b end
                        return 0.047, 0.824, 0.624
                    end,
                    function() end,  -- read-only display, no picker
                    false, 20)
                PP.Point(accentSwatch, "RIGHT", ctrl, "LEFT", -8, 0)
                accentSwatch:SetScript("OnClick", function()
                    BD().focusReminderUseAccent = true
                    if ns.RefreshFocusReminders then ns.RefreshFocusReminders() end
                    EllesmereUI:RefreshPage()
                end)
                accentSwatch:SetScript("OnEnter", function()
                    EllesmereUI.ShowWidgetTooltip(accentSwatch, "Accent Color")
                end)
                accentSwatch:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)

                -- Left (custom) swatch: color picker when accent mode is off
                local customSwatch, updateCustomSwatch = EllesmereUI.BuildColorSwatch(
                    rgn, npRow:GetFrameLevel() + 3,
                    function()
                        local bd = BD()
                        return bd.focusReminderR or 1, bd.focusReminderG or 1, bd.focusReminderB or 1
                    end,
                    function(r, g, b)
                        BD().focusReminderR, BD().focusReminderG, BD().focusReminderB = r, g, b
                        BD().focusReminderUseAccent = false
                        if ns.RefreshFocusReminders then ns.RefreshFocusReminders() end
                    end,
                    false, 20)
                PP.Point(customSwatch, "RIGHT", accentSwatch, "LEFT", -8, 0)
                customSwatch:SetScript("OnEnter", function()
                    EllesmereUI.ShowWidgetTooltip(customSwatch, "Custom Color")
                end)
                customSwatch:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)

                -- Block overlay: while accent mode is active, clicking the custom swatch flips accent mode off instead of opening the color picker.
                local customBlock = CreateFrame("Button", nil, customSwatch)
                customBlock:SetAllPoints()
                customBlock:SetFrameLevel(customSwatch:GetFrameLevel() + 10)
                customBlock:EnableMouse(true)
                customBlock:SetScript("OnClick", function()
                    if BD().focusReminderUseAccent then
                        BD().focusReminderUseAccent = false
                        if ns.RefreshFocusReminders then ns.RefreshFocusReminders() end
                        EllesmereUI:RefreshPage()
                    end
                end)
                customBlock:SetScript("OnEnter", function()
                    EllesmereUI.ShowWidgetTooltip(customSwatch, "Custom Color")
                end)
                customBlock:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)

                EllesmereUI.BuildInlineCog(rgn, { anchorTo = customSwatch, icon = EllesmereUI.RESIZE_ICON,
                    title = "Focus Reminder Settings",
                    rows = {
                        { type = "slider", label = "Text Size", min = 8, max = 50, step = 1,
                          get = function() return BD().focusReminderSize or 26 end,
                          set = function(v)
                              BD().focusReminderSize = v
                              if ns.RefreshFocusReminders then ns.RefreshFocusReminders() end
                          end },
                        { type = "slider", label = "X Offset", min = -100, max = 100, step = 1,
                          get = function() return BD().focusReminderOffsetX or 0 end,
                          set = function(v)
                              BD().focusReminderOffsetX = v
                              if ns.RefreshFocusReminders then ns.RefreshFocusReminders() end
                          end },
                        { type = "slider", label = "Y Offset", min = -100, max = 100, step = 1,
                          get = function() return BD().focusReminderOffsetY or 0 end,
                          set = function(v)
                              BD().focusReminderOffsetY = v
                              if ns.RefreshFocusReminders then ns.RefreshFocusReminders() end
                          end },
                    },
                })

                -- Disable both swatches + cog when Focus Text Reminders toggle is off
                local enableBlock = CreateFrame("Frame", nil, customSwatch)
                enableBlock:SetAllPoints()
                enableBlock:SetFrameLevel(customSwatch:GetFrameLevel() + 20)
                enableBlock:EnableMouse(true)
                enableBlock:SetScript("OnEnter", function()
                    EllesmereUI.ShowWidgetTooltip(customSwatch, EllesmereUI.DisabledTooltip("Focus Text Reminders"))
                end)
                enableBlock:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)

                local function UpdateFRSwatchState()
                    local bd = BD()
                    local on = bd.focusReminderEnabled == true
                    if not on then
                        accentSwatch:SetAlpha(0.3); customSwatch:SetAlpha(0.3)
                        customBlock:Hide(); enableBlock:Show()
                    else
                        enableBlock:Hide()
                        local useAccent = bd.focusReminderUseAccent
                        if useAccent then
                            accentSwatch:SetAlpha(1)
                            customSwatch:SetAlpha(0.3); customBlock:Show()
                        else
                            accentSwatch:SetAlpha(0.3)
                            customSwatch:SetAlpha(1); customBlock:Hide()
                        end
                    end
                end
                EllesmereUI.RegisterWidgetRefresh(function()
                    updateAccentSwatch(); updateCustomSwatch(); UpdateFRSwatchState()
                end)
                UpdateFRSwatchState()
            end

            -- Row 2: Focus Cast Sound (left) | Interrupt Spell picker (right). Sound values come
            -- from the runtime sound table (built-in sounds + LSM appended at init); the spell
            -- picker rebuilds every render so it reflects the bar's current spell list. Shallow-copy the names table to attach per-row menu options (preview icon) without polluting the shared ns.FOCUSKICK_SOUND_NAMES other code reads.
            local soundValues = {}
            if ns.FOCUSKICK_SOUND_NAMES then
                for k, v in pairs(ns.FOCUSKICK_SOUND_NAMES) do soundValues[k] = v end
            else
                soundValues.none = "None"
            end
            local soundOrder = ns.FOCUSKICK_SOUND_ORDER or { "none" }
            soundValues._menuOpts = {
                itemHeight = 26,
                maxTextWidthPct = 0.8,
                searchable = true,
                iconAtlas = function(key)
                    if key == "none" then return nil end
                    local paths = ns.FOCUSKICK_SOUND_PATHS
                    if not paths or not paths[key] then return nil end
                    return EllesmereUI.SOUND_ICON_ATLAS
                end,
                iconPressedAtlas = function(key)
                    if key == "none" then return nil end
                    return EllesmereUI.SOUND_ICON_PRESSED_ATLAS
                end,
                iconOnClick = function(key)
                    local paths = ns.FOCUSKICK_SOUND_PATHS
                    local path = paths and paths[key]
                    if path then PlaySoundFile(path, "Master") end
                end,
                iconTooltip = function() return "Preview Sound" end,
            }

            -- Spell dropdown values/order -- rebuilt live on every dropdown
            -- click (see OnClick hook below) so the list always reflects what
            -- is currently on the focuskick bar, even if the user added or
            -- removed spells via the spell picker without closing options.
            local spellValues = {}
            local spellOrder  = {}
            local function RebuildSpellOptions()
                wipe(spellValues)
                for i = #spellOrder, 1, -1 do spellOrder[i] = nil end
                local sd = ns.GetBarSpellData and ns.GetBarSpellData("focuskick")
                local list = sd and sd.assignedSpells
                if list then
                    for _, sid in ipairs(list) do
                        -- Only positive spell IDs (Blizzard cooldownable spells).
                        -- Skip negative preset markers (trinkets / items).
                        if type(sid) == "number" and sid > 0 then
                            local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(sid)
                            local label = (info and info.name) or ("Spell " .. sid)
                            local key = tostring(sid)
                            if not spellValues[key] then
                                spellValues[key] = label
                                spellOrder[#spellOrder + 1] = key
                            end
                        end
                    end
                end
                if #spellOrder == 0 then
                    spellValues["__none"] = "(no spells on bar)"
                    spellOrder[#spellOrder + 1] = "__none"
                end
                -- The stored selection can outlive its spell (removing the kick empties
                -- assignedSpells, focusKickInterruptSpellID keeps pointing at it) and the
                -- dropdown would render the raw spell id. Give it a NAME but do NOT add it
                -- to spellOrder: it must not be selectable on a bar that no longer holds it.
                -- Label it ONLY when this character can cast it: the id is profile-level but
                -- the spellbook is per-spec, so a spec sharing the profile can inherit a pick
                -- it can never use; unlabelled makes getValue below fall back to the bar's
                -- own contents.
                local selSid = BD and BD() and BD().focusKickInterruptSpellID
                if selSid and (not ns.ResolveCastableInterrupt
                    or ns.ResolveCastableInterrupt(selSid)) then
                    local selKey = tostring(selSid)
                    if not spellValues[selKey] then
                        local selInfo = C_Spell and C_Spell.GetSpellInfo
                            and C_Spell.GetSpellInfo(selSid)
                        spellValues[selKey] = (selInfo and selInfo.name)
                            or ("Spell " .. selKey)
                    end
                end
            end
            RebuildSpellOptions()

            local focusKickRow
            focusKickRow, h = W:DualRow(parent, y,
                { type = "dropdown", text = "Focus Cast Sound",
                  values = soundValues, order = soundOrder,
                  getValue = function() return BD().focusCastSoundKey or "none" end,
                  setValue = function(v) BD().focusCastSoundKey = v end },
                { type = "dropdown", text = "Interrupt Spell",
                  values = spellValues, order = spellOrder,
                  getValue = function()
                      local sid = BD().focusKickInterruptSpellID
                      if not sid then return spellOrder[1] end
                      -- No label means RebuildSpellOptions rejected it: either
                      -- this character cannot cast it, or it is not on the bar
                      -- and not castable. Show what the bar actually holds
                      -- rather than a selection the player never made.
                      local key = tostring(sid)
                      if not spellValues[key] then return spellOrder[1] end
                      return key
                  end,
                  setValue = function(v)
                      if v == "__none" then
                          BD().focusKickInterruptSpellID = nil
                      else
                          BD().focusKickInterruptSpellID = tonumber(v)
                      end
                  end });  y = y - h

            -- Live refresh: every click on the Interrupt Spell dropdown
            -- rebuilds the option list from the bar's current spells and
            -- invalidates the cached menu so the new options appear.
            do
                local rightRgn = focusKickRow and focusKickRow._rightRegion
                local ddBtn = rightRgn and rightRgn._control
                if ddBtn then
                    local origOnClick = ddBtn:GetScript("OnClick")
                    ddBtn:SetScript("OnClick", function(self, ...)
                        RebuildSpellOptions()
                        if ddBtn._invalidateMenu then ddBtn._invalidateMenu() end
                        if origOnClick then origOnClick(self, ...) end
                    end)
                end
            end

            -- Row: Show on Target
            _, h = W:DualRow(parent, y,
                { type="toggle", text="Show on Target",
                  tooltip = "Show the FocusKick bar on your current target's nameplate instead of your focus target's nameplate.",
                  getValue = function() return BD().focusKickUseTarget == true end,
                  setValue = function(v)
                      BD().focusKickUseTarget = v
                      if ns.ApplyFocusKickAnchor then ns.ApplyFocusKickAnchor() end
                      if ns.RefreshFocusCastProxyUnit then ns.RefreshFocusCastProxyUnit() end
                      EllesmereUI:RefreshPage()
                  end },
                { type="label", text="" });  y = y - h

            _, h = W:Spacer(parent, y, 8);  y = y - h
        else
            _, h = W:Spacer(parent, y, 8);  y = y - h
        end

        -------------------------------------------------------------------
        --  ICON DISPLAY
        -------------------------------------------------------------------
        -- (The per-icon hint now lives directly below the preview icons -- see
        -- the reorder hint in BuildCDMLivePreview's pf.Update.)
        _, h = W:SectionHeader(parent, "ICON DISPLAY", y);  y = y - h
        y = EllesmereUI.BlizzStyle.Note(parent, y, "cdmicons")

        -- Active State Animation dropdown values
        local ACTIVE_ANIM_VALUES = {
            blizzard    = "Blizzard",
            ["1"]       = "Pixel Glow",
            ["3"]       = "Action Button Glow",
            ["4"]       = "Auto-Cast Shine",
            ["5"]       = "GCD",
            ["7"]       = "Classic WoW Glow",
            hideActive  = "Hide Active State",
        }
        local ACTIVE_ANIM_ORDER = { "blizzard", "hideActive", "1", "---", "3", "4", "5", "7" }

        local function IsCustomShape()
            local s = BD().iconShape or "none"
            return s ~= "none" and s ~= "cropped"
        end

        -- Adjust Crop cog on Custom Icon Shape (both shape rows below). Writes the per-bar
        -- iconCropPercent that ns.CdmCropFactor / ns.CdmCropTrim read; unset = 10 = the classic
        -- crop. Disabled unless the shape is Cropped. Under a stock style both shape rows are
        -- fully gated, so the row (and this cog with it) is hidden by the widget factory.
        local function AttachCropCog(rgn)
            EllesmereUI.BuildInlineCog(rgn, {
                disabled = function() return (BD().iconShape or "none") ~= "cropped" end,
                disabledTooltip = "This option requires Custom Icon Shape to be set to Cropped",
                title = "Custom Icon Shape",
                rows = {
                    { type="slider", label="Adjust Crop", min=5, max=25, step=1,
                      tooltip="How much is trimmed from the icon's top and bottom, as a percentage per side. 10% is the classic cropped look.",
                      get=function() return ns.CdmCropPercent(BD()) end,
                      set=function(v)
                          local bd = BD()
                          bd.iconCropPercent = v
                          -- Icon height changes: drop the same match caches the shape setter drops.
                          bd._matchIconPhys = nil
                          bd._matchExtraPixels = nil
                          bd._matchStride = nil
                          bd._matchExtraPixelsH = nil
                          bd._matchStrideH = nil
                          ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreviewAndResize()
                      end },
                },
            })
        end

        -- Shape dropdown values
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

        -- Border thickness dropdown
        local BORDER_LABELS = { none="None", thin="Thin", normal="Normal", heavy="Heavy", strong="Strong" }
        local BORDER_ORDER  = { "none", "thin", "normal", "heavy", "strong" }
        local BORDER_SIZES  = { none=0, thin=1, normal=2, heavy=3, strong=4 }

        local isBuffGlowBar = isBuffBar or (barData.barType == "custom_buff")
        local scaleAnimRow
        if isBuffGlowBar then
            -- Row 1: Always Show Buffs (native buff bars only) | Icon Scale.
            -- Per-bar now: shows a greyed placeholder icon for each inactive
            -- tracked buff. No edit-mode change, no reload. custom_buff bars
            -- draw their own always-on icons, so the toggle is hidden there.
            local row1Left
            if isBuffBar then
                row1Left = { type="toggle", text="Always Show Buffs",
                    -- Mutually exclusive with "Keep Buffs in Same Place" (Bar Layout).
                    -- Disabled while that is the active choice. The extra
                    -- "and showInactiveBuffIcons ~= true" keeps a legacy both-on profile
                    -- unlockable: this toggle stays enabled so it can be turned off.
                    disabled=function() local b=BD(); return b.hidePlaceholderIcon == true and b.showInactiveBuffIcons ~= true end,
                    disabledTooltip="Disabled while Keep Buffs in Same Place is enabled", rawTooltip=true,
                    getValue=function() return BD().showInactiveBuffIcons == true end,
                    setValue=function(v)
                        BD().showInactiveBuffIcons = v
                        ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreviewAndResize()
                        EllesmereUI:RefreshPage()
                    end }
            else
                row1Left = { type="label", text="" }
            end
            local icsWDis, icsWTip, icsWRaw = EllesmereUI.MatchGuard("CDM_" .. barKey, "Width")
            local icsHDis, icsHTip = EllesmereUI.MatchGuard("CDM_" .. barKey, "Height")
            local icsDis = function() return icsWDis() or icsHDis() end
            local icsTip = function() if icsWDis() then return icsWTip() end if icsHDis() then return icsHTip() end return false end
            scaleAnimRow, h = W:DualRow(parent, y,
                row1Left,
                { type="slider", text="Icon Scale",
                  min=16, max=100, step=1,
                  disabled=icsDis, disabledTooltip=icsTip, rawTooltip=true,
                  getValue=function() return BD().iconSize or 36 end,
                  setValue=function(v)
                      local bd = BD()
                      bd.iconSize = v
                      bd._matchPhysWidth = nil
                      bd._matchPhysHeight = nil
                      bd._matchIconPhys = nil
                      bd._matchExtraPixels = nil
                      bd._matchStride = nil
                      bd._matchExtraPixelsH = nil
                      bd._matchStrideH = nil
                      ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreviewAndResize()
                  end });  y = y - h

            -- Inline cog on Always Show Buffs toggle (per-bar; native buff bars)
            if isBuffBar then
                local leftRgn = scaleAnimRow._leftRegion
                EllesmereUI.BuildInlineCog(leftRgn, {
                    anchorTo = leftRgn._control,
                    disabled = function() return not BD().showInactiveBuffIcons end,
                    disabledTooltip = "Always Show Buffs",
                    title = "Always Show Buffs",
                    rows = {
                        { type="toggle", label="Desaturate Off CD",
                          get=function() return BD().desaturateInactiveBuffs ~= false end,
                          set=function(v)
                              BD().desaturateInactiveBuffs = v
                          end },
                    },
                })
            end

            -- Row 2: Buff Glow + swatches | Icon Spacing. The Glows page's Buff Glow
            -- descriptor over this bar: a custom icon shape locks it (shown as None),
            -- and its Pixel Glow parameters keep their own row below (per-icon Buff
            -- Glows read them too), so this row takes the swatches only.
            local GO = EllesmereUI.GlowOptions
            local buffGlowDesc = ns._CDM_BuffGlowDesc(BD, function() ns.BuildAllCDMBars(); Refresh() end)
            buffGlowDesc.caps = { mode = true }
            buffGlowDesc.isOff, buffGlowDesc.disabled = IsCustomShape, IsCustomShape
            buffGlowDesc.disabledTooltip = "This option requires a non-custom button shape"
            local buffGlowRow
            buffGlowRow, h = W:DualRow(parent, y,
                GO.DropdownSpec(buffGlowDesc, "Buff Glow"),
                { type="slider", pixel=true, text="Icon Spacing",
                  min=-10, max=20, step=1,
                  getValue=function() return BD().spacing or 2 end,
                  setValue=function(v)
                      local bd = BD()
                      bd.spacing = v
                      bd._matchIconPhys = nil
                      bd._matchExtraPixels = nil
                      bd._matchStride = nil
                      bd._matchExtraPixelsH = nil
                      bd._matchStrideH = nil
                      ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreviewAndResize()
                  end });  y = y - h
            GO.AttachInline(buffGlowRow._leftRegion, buffGlowDesc)

            -- (Pixel Glow Thickness / Lines / Speed moved to a dedicated row at the
            -- bottom of this section -- see "Pixel Glow Thickness (buff bars)" below.
            -- Same buffGlow* variables, so user settings are unchanged.)

            -- Row 3: Custom Icon Shape | Icon Zoom
            local buffShapeZoomRow
            buffShapeZoomRow, h = W:DualRow(parent, y,
                EllesmereUI.BlizzStyle.Gate("cdmicons", { type="dropdown", text="Custom Icon Shape",
                  values=SHAPE_VALUES, order=SHAPE_ORDER,
                  itemDisabled=function(val)
                      if val ~= "none" and val ~= "cropped" and (BD().borderTexture or "solid") ~= "solid" then return true end
                      return false
                  end,
                  itemDisabledTooltip=function(val)
                      if val ~= "none" and val ~= "cropped" and (BD().borderTexture or "solid") ~= "solid" then
                          return "This option requires the Border Style to be set to Solid"
                      end
                  end,
                  getValue=function() return BD().iconShape or "none" end,
                  setValue=function(v)
                      local bd = BD()
                      bd.iconShape = v
                      bd.iconZoom = ns.CDM_SHAPE_ZOOM_DEFAULTS[v] or 0.08
                      local isCS = (v ~= "none" and v ~= "cropped")
                      if isCS then
                          bd.borderThickness = "strong"; bd.borderSize = BORDER_SIZES["strong"]
                          bd.activeStateAnim = "blizzard"
                      else
                          bd.borderThickness = "thin"; bd.borderSize = BORDER_SIZES["thin"]
                      end
                      bd._matchIconPhys = nil
                      bd._matchExtraPixels = nil
                      bd._matchStride = nil
                      bd._matchExtraPixelsH = nil
                      bd._matchStrideH = nil
                      ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreviewAndResize()
                      -- The Border Size slot is a different control under a custom shape: rebuild the page.
                      EllesmereUI:RefreshPage(true)
                  end }),
                EllesmereUI.BlizzStyle.Gate("cdmicons", { type="slider", text="Icon Zoom",
                  min=0, max=0.20, step=0.01,
                  getValue=function() return BD().iconZoom or 0.08 end,
                  setValue=function(v)
                      BD().iconZoom = v
                      ns.RefreshCDMIconAppearance(BD().key); Refresh(); UpdateCDMPreview()
                  end }));  y = y - h

            AttachCropCog(buffShapeZoomRow._leftRegion)

            -- Sync icon on Custom Icon Shape (left of row 3)
            if not EllesmereUI._prebuilding then
            EllesmereUI.BuildSyncIcon({
                region  = buffShapeZoomRow._leftRegion,
                tooltip = "Apply Icon Shape to all Bars",
                isSynced = function()
                    local bd = BD()
                    local v = bd.iconShape or "none"
                    local zoom = bd.iconZoom or 0.08
                    local crop = ns.CdmCropPercent(bd)
                    local synced = true
                    ForEachSyncBar(function(b) if (b.iconShape or "none") ~= v or (b.iconZoom or 0.08) ~= zoom or ns.CdmCropPercent(b) ~= crop then synced = false end end)
                    return synced
                end,
                onClick = function()
                    local bd = BD()
                    local v = bd.iconShape or "none"
                    local zoom = bd.iconZoom or 0.08
                    local crop = bd.iconCropPercent
                    ForEachSyncBar(function(b)
                        b.iconShape = v; b.iconZoom = zoom; b.iconCropPercent = crop
                        local isCS = (v ~= "none" and v ~= "cropped")
                        if isCS then b.borderThickness = "strong"; b.borderSize = BORDER_SIZES["strong"]
                        else b.borderThickness = "thin"; b.borderSize = BORDER_SIZES["thin"] end
                        b._matchIconPhys = nil
                        b._matchExtraPixels = nil
                        b._matchStride = nil
                        b._matchExtraPixelsH = nil
                        b._matchStrideH = nil
                    end)
                    ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreviewAndResize(); EllesmereUI:RefreshPage()
                end,
            })
            end
            -- Sync icon on Icon Zoom (right of row 3)
            if not EllesmereUI._prebuilding then
            EllesmereUI.BuildSyncIcon({
                region  = buffShapeZoomRow._rightRegion,
                tooltip = "Apply Icon Zoom to all Bars",
                isSynced = function()
                    local v = BD().iconZoom or 0.08
                    local synced = true
                    ForEachSyncBar(function(b) if (b.iconZoom or 0.08) ~= v then synced = false end end)
                    return synced
                end,
                onClick = function()
                    local v = BD().iconZoom or 0.08
                    ForEachSyncBar(function(b) b.iconZoom = v end)
                    ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreview(); EllesmereUI:RefreshPage()
                end,
            })
            end

            -- Row 4: Border Size + swatches | Border Style dropdown + offset cog
            do
                local texValues, texOrder = EllesmereUI.GetBorderTextureDropdown()
                local buffBsRow
                -- Border Size: the exact-size slider, except under a custom shape, whose
                -- ring is on (Strong) or off (None): that keeps the None..Strong dropdown.
                local buffSizeCfg
                if IsCustomShape() then
                    buffSizeCfg = { type="dropdown", text="Border Size",
                      values=BORDER_LABELS, order=BORDER_ORDER,
                      itemDisabled=function(val)
                          if IsCustomShape() and (val == "thin" or val == "normal" or val == "heavy") then return true end
                          return false
                      end,
                      itemDisabledTooltip=function(val)
                          if IsCustomShape() and (val == "thin" or val == "normal" or val == "heavy") then
                              return "This option requires a non-custom shape to be selected"
                          end
                      end,
                      getValue=function() return BD().borderThickness or "thin" end,
                      setValue=function(v)
                          BD().borderThickness = v; BD().borderSize = BORDER_SIZES[v] or 1
                          ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreview()
                      end }
                else
                    buffSizeCfg = EllesmereUI.BorderPxSliderCfg({ text="Border Size",
                      getStep=function() return BD().borderSize or 1 end,
                      setStep=function(step)
                          local bd = BD()
                          bd.borderThickness = EllesmereUI.BORDER_LABEL_OF_STEP[step] or "thin"; bd.borderSize = step
                      end,
                      getTex=function() return BD().borderTexture or "solid" end,
                      getPx=function() return BD().borderSizePx end,
                      setPx=function(v) BD().borderSizePx = v end,
                      apply=function() ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreview() end,
                    })
                end
                buffBsRow, h = W:DualRow(parent, y,
                    EllesmereUI.BlizzStyle.Gate("cdmicons", buffSizeCfg),
                    EllesmereUI.BlizzStyle.Gate("cdmicons", { type="dropdown", text="Border Style",
                      disabled=function() return IsCustomShape() end,
                      disabledTooltip="This option requires a non-custom button shape",
                      values=texValues, order=texOrder,
                      getValue=function() return BD().borderTexture or "solid" end,
                      setValue=function(v)
                          local bd = BD()
                          bd.borderTexture = v; bd.borderTextureOffset = nil; bd.borderTextureOffsetY = nil; bd.borderTextureShiftX = nil; bd.borderTextureShiftY = nil
                          local _bcol, _bbehind = EllesmereUI.GetBorderStyleSelectDefaults(v)
                          bd.borderR = _bcol.r; bd.borderG = _bcol.g; bd.borderB = _bcol.b; bd.borderA = 1
                          bd.borderClassColor = false
                          bd.borderBehind = _bbehind
                          local defTh = EllesmereUI.GetBorderDefaultSize("cdm", v)
                          -- An unregistered SharedMedia border defaults to the NUMBER 1: store its label.
                          if type(defTh) == "number" then defTh = EllesmereUI.BORDER_LABEL_OF_STEP[defTh] or "thin" end
                          if defTh then
                              bd.borderThickness = defTh; bd.borderSize = BORDER_SIZES[defTh] or 1
                          end
                          if bd.borderSizePx then bd.borderSizePx = false end
                          ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreview()
                          EllesmereUI:RefreshPage(true)
                      end }));  y = y - h
                -- Width Offset | Height Offset: the textured border's outward offsets,
                -- present only while a textured style is selected (built on the
                -- prebuild pass too, so the y advance is identical). Disabled under a
                -- custom shape exactly like the Border Style dropdown it belongs to.
                do
                    local tex0 = BD().borderTexture or "solid"
                    if tex0 ~= "" and tex0 ~= "solid" then
                        local ocfgL, ocfgR = EllesmereUI.BorderOffsetRowCfgs({
                            addonKey = "cdm",
                            disabled = function() return IsCustomShape() end,
                            disabledTooltip = "This option requires a non-custom button shape",
                            getTex = function() return BD().borderTexture or "solid" end,
                            getStep = function() return BD().borderSize or 1 end,
                            getSizeKey = function() return BD().borderThickness or "thin" end,
                            getPx = function() return BD().borderSizePx end,
                            getX = function() return BD().borderTextureOffset end,
                            setX = function(v) BD().borderTextureOffset = v end,
                            getY = function() return BD().borderTextureOffsetY end,
                            setY = function(v) BD().borderTextureOffsetY = v end,
                            apply = function() ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreview() end,
                        })
                        _, h = W:DualRow(parent, y,
                            EllesmereUI.BlizzStyle.Gate("cdmicons", ocfgL),
                            EllesmereUI.BlizzStyle.Gate("cdmicons", ocfgR));  y = y - h
                    end
                end
                -- Inline cog for border offset
                if not EllesmereUI._prebuilding then
                    local rgn = buffBsRow._rightRegion
                    local cogBtn = EllesmereUI.BuildInlineCog(rgn, {
                        icon = EllesmereUI.DIRECTIONS_ICON,
                        title = "Border Options",
                        rows = {
                            { type = "slider", label = "Shift X", min = -10, max = 10, step = 1,
                              get = function()
                                  local v = BD().borderTextureShiftX
                                  if v then return v end
                                  local bd = BD()
                                  local tex = bd.borderTexture or "solid"
                                  local th = bd.borderThickness or "thin"
                                  local _, _, dsx = EllesmereUI.GetBorderDefaults("cdm", tex, th)
                                  return dsx
                              end,
                              set = function(v)
                                  BD().borderTextureShiftX = v == 0 and nil or v
                                  ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreview()
                              end },
                            { type = "slider", label = "Shift Y", min = -10, max = 10, step = 1,
                              get = function()
                                  local v = BD().borderTextureShiftY
                                  if v then return v end
                                  local bd = BD()
                                  local tex = bd.borderTexture or "solid"
                                  local th = bd.borderThickness or "thin"
                                  local _, _, _, dsy = EllesmereUI.GetBorderDefaults("cdm", tex, th)
                                  return dsy
                              end,
                              set = function(v)
                                  BD().borderTextureShiftY = v == 0 and nil or v
                                  ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreview()
                              end },
                            { type = "toggle", label = "Show Behind",
                              get = function() return BD().borderBehind or false end,
                              set = function(v)
                                  BD().borderBehind = v == false and nil or v
                                  ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreview(); EllesmereUI:RefreshPage()
                              end },
                        },
                    })
                    local function UpdateCogVis()
                        local tex = BD().borderTexture or "solid"
                        if tex == "solid" or EllesmereUI.BlizzStyle.Get("cdmicons") then cogBtn:Hide() else cogBtn:Show() end
                    end
                    EllesmereUI.RegisterWidgetRefresh(UpdateCogVis)
                    UpdateCogVis()
                end
                -- Inline border color swatches on Border Size (left region of row 4)
                if not EllesmereUI._prebuilding then
                    local leftRgn = buffBsRow._leftRegion
                    local ctrl = leftRgn._control

                    local classBorderSwatch, updateClassBorderSwatch = EllesmereUI.BuildColorSwatch(
                        leftRgn, buffBsRow:GetFrameLevel() + 3,
                        function()
                            local _, classFile = UnitClass("player")
                            local cc = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
                            if cc then return cc.r, cc.g, cc.b end
                            return 1, 1, 1
                        end,
                        function() end,
                        false, 20)
                    PP.Point(classBorderSwatch, "RIGHT", ctrl, "LEFT", -8, 0)
                    classBorderSwatch:SetScript("OnClick", function()
                        if EllesmereUI.BlizzStyle.Get("cdmicons") then return end
                        BD().borderClassColor = true
                        ns.RefreshCDMIconAppearance(BD().key); Refresh(); UpdateCDMPreview()
                        EllesmereUI:RefreshPage()
                    end)
                    classBorderSwatch:SetScript("OnEnter", function()
                        EllesmereUI.ShowWidgetTooltip(classBorderSwatch, "Class Colored")
                    end)
                    classBorderSwatch:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)

                    local UpdateBorderState
                    local swatch, updateSwatch = EllesmereUI.BuildColorSwatch(
                        leftRgn, buffBsRow:GetFrameLevel() + 3,
                        function() return BD().borderR or 0, BD().borderG or 0, BD().borderB or 0 end,
                        function(r, g, b)
                            -- Picking a color always switches off class color so the chosen custom color actually applies.
                            BD().borderClassColor = false
                            BD().borderR, BD().borderG, BD().borderB = r, g, b
                            ns.RefreshCDMIconAppearance(BD().key); Refresh(); UpdateCDMPreview()
                        end,
                        false, 20)
                    PP.Point(swatch, "RIGHT", classBorderSwatch, "LEFT", -8, 0)
                    swatch:SetScript("OnEnter", function()
                        EllesmereUI.ShowWidgetTooltip(swatch, "Custom Colored")
                    end)
                    swatch:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)

                    -- Clicking the custom swatch switches class color off AND opens
                    -- the color picker in the same click (a toggle-only first click
                    -- leaves the border black and the swatch looking stuck).
                    local origClick = swatch:GetScript("OnClick")
                    swatch:SetScript("OnClick", function(self, ...)
                        -- No border selected (or Blizzard Style): don't open the color picker
                        if (BD().borderThickness or "thin") == "none" or EllesmereUI.BlizzStyle.Get("cdmicons") then return end
                        if BD().borderClassColor then
                            BD().borderClassColor = false
                            ns.RefreshCDMIconAppearance(BD().key); Refresh(); UpdateCDMPreview()
                            updateSwatch(); UpdateBorderState()
                        end
                        if origClick then origClick(self, ...) end
                    end)

                    function UpdateBorderState()
                        local isClassColored = BD().borderClassColor
                        local isNone = (BD().borderThickness or "thin") == "none" or EllesmereUI.BlizzStyle.Get("cdmicons")
                        swatch:SetAlpha((isClassColored or isNone) and 0.3 or 1)
                        classBorderSwatch:SetAlpha((isClassColored and not isNone) and 1 or 0.3)
                    end
                    EllesmereUI.RegisterWidgetRefresh(function() updateSwatch(); updateClassBorderSwatch(); UpdateBorderState() end)
                    UpdateBorderState()
                end
                -- Sync icon: Border Size (left region)
                if not EllesmereUI._prebuilding then
                EllesmereUI.BuildSyncIcon({
                    region  = buffBsRow._leftRegion,
                    tooltip = "Apply Border Size to all Bars",
                    isSynced = function()
                        local bd = BD()
                        local v = bd.borderThickness or "thin"
                        local px = bd.borderSizePx or false
                        local cc = bd.borderClassColor
                        local synced = true
                        ForEachSyncBar(function(b) if (b.borderThickness or "thin") ~= v or (b.borderSizePx or false) ~= px or b.borderClassColor ~= cc then synced = false end end)
                        return synced
                    end,
                    onClick = function()
                        local bd = BD()
                        local v = bd.borderThickness or "thin"
                        local sz = bd.borderSize or 1
                        local px = bd.borderSizePx
                        local cc = bd.borderClassColor
                        ForEachSyncBar(function(b)
                            b.borderThickness = v; b.borderSize = sz
                            local pxv = px
                            if pxv == nil and b.borderSizePx ~= nil then pxv = false end
                            b.borderSizePx = pxv
                            b.borderClassColor = cc
                        end)
                        ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreview(); EllesmereUI:RefreshPage()
                    end,
                })
                end
                -- Sync icon: Border Style (right region)
                if not EllesmereUI._prebuilding then
                EllesmereUI.BuildSyncIcon({
                    region  = buffBsRow._rightRegion,
                    tooltip = "Apply Border Style to all Bars",
                    onClick = function()
                        local bd = BD()
                        local bt = bd.borderTexture or "solid"
                        local ox = bd.borderTextureOffset
                        local oy = bd.borderTextureOffsetY
                        local sx = bd.borderTextureShiftX
                        local sy = bd.borderTextureShiftY
                        local th = bd.borderThickness or "thin"
                        local sz = bd.borderSize or 1
                        local px = bd.borderSizePx
                        local bh = bd.borderBehind
                        local br, bg, bb, ba = bd.borderR, bd.borderG, bd.borderB, bd.borderA
                        local cc = bd.borderClassColor
                        ForEachSyncBar(function(b)
                            b.borderTexture = bt
                            b.borderTextureOffset = ox
                            b.borderTextureOffsetY = oy
                            b.borderTextureShiftX = sx
                            b.borderTextureShiftY = sy
                            b.borderThickness = th; b.borderSize = sz
                            local pxv = px
                            if pxv == nil and b.borderSizePx ~= nil then pxv = false end
                            b.borderSizePx = pxv
                            b.borderBehind = bh
                            b.borderR = br; b.borderG = bg; b.borderB = bb; b.borderA = ba
                            b.borderClassColor = cc
                        end)
                        ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreview(); EllesmereUI:RefreshPage()
                    end,
                    isSynced = function()
                        local bd = BD()
                        local bt = bd.borderTexture or "solid"
                        local ox = bd.borderTextureOffset
                        local oy = bd.borderTextureOffsetY
                        local sx = bd.borderTextureShiftX
                        local sy = bd.borderTextureShiftY
                        local bh = bd.borderBehind or false
                        local synced = true
                        ForEachSyncBar(function(b)
                            if (b.borderTexture or "solid") ~= bt then synced = false end
                            if b.borderTextureOffset ~= ox or b.borderTextureOffsetY ~= oy then synced = false end
                            if b.borderTextureShiftX ~= sx or b.borderTextureShiftY ~= sy then synced = false end
                            if (b.borderBehind or false) ~= bh then synced = false end
                        end)
                        return synced
                    end,
                })
                end
            end

        else
        local icsWDis2, icsWTip2 = EllesmereUI.MatchGuard("CDM_" .. barKey, "Width")
        local icsHDis2, icsHTip2 = EllesmereUI.MatchGuard("CDM_" .. barKey, "Height")
        local icsDis2 = function() return icsWDis2() or icsHDis2() end
        local icsTip2 = function() if icsWDis2() then return icsWTip2() end if icsHDis2() then return icsHTip2() end return false end
        scaleAnimRow, h = W:DualRow(parent, y,
            { type="slider", text="Icon Scale",
              min=16, max=100, step=1,
              disabled=icsDis2, disabledTooltip=icsTip2, rawTooltip=true,
              getValue=function() return BD().iconSize or 36 end,
              setValue=function(v)
                  local bd = BD()
                  bd.iconSize = v
                  -- Manual iconSize override -- clear ALL match cache so the
                  -- new value wins over any stored target width/height.
                  bd._matchPhysWidth = nil
                  bd._matchPhysHeight = nil
                  bd._matchIconPhys = nil
                  bd._matchExtraPixels = nil
                  bd._matchStride = nil
                  bd._matchExtraPixelsH = nil
                  bd._matchStrideH = nil
                  ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreviewAndResize()
              end },
            { type="slider", pixel=true, text="Icon Spacing",
              min=-10, max=20, step=1,
              getValue=function() return BD().spacing or 2 end,
              setValue=function(v)
                  local bd = BD()
                  bd.spacing = v
                  -- Spacing change invalidates the width/height match cache because the
                  -- cached _matchIconPhys was computed against the old spacing -- new
                  -- spacing means the icons no longer fit the matched bar dimension.
                  bd._matchIconPhys = nil
                  bd._matchExtraPixels = nil
                  bd._matchStride = nil
                  bd._matchExtraPixelsH = nil
                  bd._matchStrideH = nil
                  ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreviewAndResize()
              end });  y = y - h

        -- Sync icon on Icon Spacing (right of row 1)
        if not EllesmereUI._prebuilding then
        EllesmereUI.BuildSyncIcon({
            region  = scaleAnimRow._rightRegion,
            tooltip = "Apply Icon Spacing to all Bars",
            isSynced = function()
                local v = BD().spacing or 2
                local synced = true
                ForEachSyncBar(function(b) if (b.spacing or 2) ~= v then synced = false end end)
                return synced
            end,
            onClick = function()
                local v = BD().spacing or 2
                ForEachSyncBar(function(b)
                    b.spacing = v
                    -- Spacing change invalidates each bar's match cache.
                    b._matchIconPhys = nil
                    b._matchExtraPixels = nil
                    b._matchStride = nil
                    b._matchExtraPixelsH = nil
                    b._matchStrideH = nil
                end)
                ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreviewAndResize(); EllesmereUI:RefreshPage()
            end,
        })
        end
        end -- isBuffBar else

        -- Inline cog on Icon Scale: Minimum Bar Size (growth-axis icon-slot
        -- reservation, user-directed to live here, not as a Bar Layout row). Placed
        -- AFTER the isBuffGlowBar branch: each side builds its own scaleAnimRow with
        -- Icon Scale in a different slot (right on buff-family rows, left elsewhere).
        -- The slider stays editable: the runtime skips the reservation while the
        -- growth axis is width/height matched, so no MatchGuard lock is needed.
        -- Orientation resolves at build time; the page rebuilds on flips. FocusKick is
        -- excluded: it is nameplate-anchored, nothing matches or anchors to its edges.
        if not isFocusKick then
            local minVert = BD().verticalOrientation == true
            local rgn = isBuffGlowBar and scaleAnimRow._rightRegion or scaleAnimRow._leftRegion
            EllesmereUI.BuildInlineCog(rgn, {
                icon = EllesmereUI.RESIZE_ICON,
                title = minVert and "Minimum Height" or "Minimum Width",
                rows = {
                    { type="slider",
                      label=minVert and "Icon Slots Tall (0 = Off)" or "Icon Slots Wide (0 = Off)",
                      min=0, max=20, step=1,
                      get=function() return BD().minSizeIcons or 0 end,
                      set=function(v)
                          if v == 0 then v = nil end
                          local bd = BD()
                          bd.minSizeIcons = v
                          -- Growth-axis extent changed: cached match dims stale.
                          bd._matchIconPhys = nil
                          bd._matchExtraPixels = nil
                          bd._matchStride = nil
                          bd._matchExtraPixelsH = nil
                          bd._matchStrideH = nil
                          ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreviewAndResize()
                      end },
                },
            })
        end

        -- Border Style dropdown (CD/utility and non-buff bars only)
        if not isBuffGlowBar then
        do
            local texValues, texOrder = EllesmereUI.GetBorderTextureDropdown()
            local bsRow
            -- Border Size: the exact-size slider, except under a custom shape, whose
            -- ring is on (Strong) or off (None): that keeps the None..Strong dropdown.
            local sizeCfg
            if IsCustomShape() then
                sizeCfg = { type="dropdown", text="Border Size",
                  values=BORDER_LABELS, order=BORDER_ORDER,
                  itemDisabled=function(val)
                      if IsCustomShape() and (val == "thin" or val == "normal" or val == "heavy") then return true end
                      return false
                  end,
                  itemDisabledTooltip=function(val)
                      if IsCustomShape() and (val == "thin" or val == "normal" or val == "heavy") then
                          return "This option requires a non-custom shape to be selected"
                      end
                  end,
                  getValue=function() return BD().borderThickness or "thin" end,
                  setValue=function(v)
                      BD().borderThickness = v; BD().borderSize = BORDER_SIZES[v] or 1
                      ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreview()
                  end }
            else
                sizeCfg = EllesmereUI.BorderPxSliderCfg({ text="Border Size",
                  getStep=function() return BD().borderSize or 1 end,
                  setStep=function(step)
                      local bd = BD()
                      bd.borderThickness = EllesmereUI.BORDER_LABEL_OF_STEP[step] or "thin"; bd.borderSize = step
                  end,
                  getTex=function() return BD().borderTexture or "solid" end,
                  getPx=function() return BD().borderSizePx end,
                  setPx=function(v) BD().borderSizePx = v end,
                  apply=function() ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreview() end,
                })
            end
            bsRow, h = W:DualRow(parent, y,
                EllesmereUI.BlizzStyle.Gate("cdmicons", { type="dropdown", text="Border Style",
                  disabled=function() return IsCustomShape() end,
                  disabledTooltip="This option requires a non-custom button shape",
                  values=texValues, order=texOrder,
                  getValue=function() return BD().borderTexture or "solid" end,
                  setValue=function(v)
                      local bd = BD()
                      bd.borderTexture = v; bd.borderTextureOffset = nil; bd.borderTextureOffsetY = nil; bd.borderTextureShiftX = nil; bd.borderTextureShiftY = nil
                      local _bcol, _bbehind = EllesmereUI.GetBorderStyleSelectDefaults(v)
                      bd.borderR = _bcol.r; bd.borderG = _bcol.g; bd.borderB = _bcol.b; bd.borderA = 1
                      bd.borderClassColor = false
                      bd.borderBehind = _bbehind
                      local defTh = EllesmereUI.GetBorderDefaultSize("cdm", v)
                      -- An unregistered SharedMedia border defaults to the NUMBER 1: store its label.
                      if type(defTh) == "number" then defTh = EllesmereUI.BORDER_LABEL_OF_STEP[defTh] or "thin" end
                      if defTh then
                          bd.borderThickness = defTh; bd.borderSize = BORDER_SIZES[defTh] or 1
                      end
                      if bd.borderSizePx then bd.borderSizePx = false end
                      ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreview()
                      EllesmereUI:RefreshPage(true)
                  end }),
                EllesmereUI.BlizzStyle.Gate("cdmicons", sizeCfg));  y = y - h
            -- Width Offset | Height Offset: the textured border's outward offsets,
            -- present only while a textured style is selected (built on the
            -- prebuild pass too, so the y advance is identical). Disabled under a
            -- custom shape exactly like the Border Style dropdown it belongs to.
            do
                local tex0 = BD().borderTexture or "solid"
                if tex0 ~= "" and tex0 ~= "solid" then
                    local ocfgL, ocfgR = EllesmereUI.BorderOffsetRowCfgs({
                        addonKey = "cdm",
                        disabled = function() return IsCustomShape() end,
                        disabledTooltip = "This option requires a non-custom button shape",
                        getTex = function() return BD().borderTexture or "solid" end,
                        getStep = function() return BD().borderSize or 1 end,
                        getSizeKey = function() return BD().borderThickness or "thin" end,
                        getPx = function() return BD().borderSizePx end,
                        getX = function() return BD().borderTextureOffset end,
                        setX = function(v) BD().borderTextureOffset = v end,
                        getY = function() return BD().borderTextureOffsetY end,
                        setY = function(v) BD().borderTextureOffsetY = v end,
                        apply = function() ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreview() end,
                    })
                    _, h = W:DualRow(parent, y,
                        EllesmereUI.BlizzStyle.Gate("cdmicons", ocfgL),
                        EllesmereUI.BlizzStyle.Gate("cdmicons", ocfgR));  y = y - h
                end
            end
            -- Inline cog for border offset
            if not EllesmereUI._prebuilding then
                local rgn = bsRow._leftRegion
                local cogBtn = EllesmereUI.BuildInlineCog(rgn, {
                    icon = EllesmereUI.DIRECTIONS_ICON,
                    title = "Border Options",
                    rows = {
                        { type = "slider", label = "Shift X", min = -10, max = 10, step = 1,
                          get = function()
                              local v = BD().borderTextureShiftX
                              if v then return v end
                              local bd = BD()
                              local tex = bd.borderTexture or "solid"
                              local th = bd.borderThickness or "thin"
                              local _, _, dsx = EllesmereUI.GetBorderDefaults("cdm", tex, th)
                              return dsx
                          end,
                          set = function(v)
                              BD().borderTextureShiftX = v == 0 and nil or v
                              ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreview()
                          end },
                        { type = "slider", label = "Shift Y", min = -10, max = 10, step = 1,
                          get = function()
                              local v = BD().borderTextureShiftY
                              if v then return v end
                              local bd = BD()
                              local tex = bd.borderTexture or "solid"
                              local th = bd.borderThickness or "thin"
                              local _, _, _, dsy = EllesmereUI.GetBorderDefaults("cdm", tex, th)
                              return dsy
                          end,
                          set = function(v)
                              BD().borderTextureShiftY = v == 0 and nil or v
                              ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreview()
                          end },
                        { type = "toggle", label = "Show Behind",
                          get = function() return BD().borderBehind or false end,
                          set = function(v)
                              BD().borderBehind = v == false and nil or v
                              ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreview(); EllesmereUI:RefreshPage()
                          end },
                    },
                })
                local function UpdateCogVis()
                    local tex = BD().borderTexture or "solid"
                    if tex == "solid" or EllesmereUI.BlizzStyle.Get("cdmicons") then cogBtn:Hide() else cogBtn:Show() end
                end
                EllesmereUI.RegisterWidgetRefresh(UpdateCogVis)
                UpdateCogVis()
            end
            -- Sync icon: Border Style (left region of bsRow)
            if not EllesmereUI._prebuilding then
            EllesmereUI.BuildSyncIcon({
                region  = bsRow._leftRegion,
                tooltip = "Apply Border Style to all Bars",
                onClick = function()
                    local bd = BD()
                    local bt = bd.borderTexture or "solid"
                    local ox = bd.borderTextureOffset
                    local oy = bd.borderTextureOffsetY
                    local sx = bd.borderTextureShiftX
                    local sy = bd.borderTextureShiftY
                    local th = bd.borderThickness or "thin"
                    local sz = bd.borderSize or 1
                    local px = bd.borderSizePx
                    local bh = bd.borderBehind
                    local br, bg, bb, ba = bd.borderR, bd.borderG, bd.borderB, bd.borderA
                    local cc = bd.borderClassColor
                    ForEachSyncBar(function(b)
                        b.borderTexture = bt
                        b.borderTextureOffset = ox; b.borderTextureOffsetY = oy
                        b.borderTextureShiftX = sx; b.borderTextureShiftY = sy
                        b.borderThickness = th; b.borderSize = sz
                            local pxv = px
                            if pxv == nil and b.borderSizePx ~= nil then pxv = false end
                            b.borderSizePx = pxv
                        b.borderBehind = bh
                        b.borderR = br; b.borderG = bg; b.borderB = bb; b.borderA = ba
                        b.borderClassColor = cc
                    end)
                    ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreview(); EllesmereUI:RefreshPage()
                end,
                isSynced = function()
                    local bd = BD()
                    local bt = bd.borderTexture or "solid"
                    local ox = bd.borderTextureOffset
                    local oy = bd.borderTextureOffsetY
                    local sx = bd.borderTextureShiftX
                    local sy = bd.borderTextureShiftY
                    local bh = bd.borderBehind or false
                    local synced = true
                    ForEachSyncBar(function(b)
                        if (b.borderTexture or "solid") ~= bt then synced = false end
                        if b.borderTextureOffset ~= ox or b.borderTextureOffsetY ~= oy then synced = false end
                        if b.borderTextureShiftX ~= sx or b.borderTextureShiftY ~= sy then synced = false end
                        if (b.borderBehind or false) ~= bh then synced = false end
                    end)
                    return synced
                end,
            })
            end
            -- Inline color swatches on Border Size (right region)
            if not EllesmereUI._prebuilding then
                local rightRgn = bsRow._rightRegion
                local ctrl = rightRgn._control

                -- Class color swatch (rightmost)
                local classBorderSwatch, updateClassBorderSwatch = EllesmereUI.BuildColorSwatch(
                    rightRgn, bsRow:GetFrameLevel() + 3,
                    function()
                        local _, classFile = UnitClass("player")
                        local cc = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
                        if cc then return cc.r, cc.g, cc.b end
                        return 1, 1, 1
                    end,
                    function() end,
                    false, 20)
                PP.Point(classBorderSwatch, "RIGHT", ctrl, "LEFT", -8, 0)
                classBorderSwatch:SetScript("OnClick", function()
                    if EllesmereUI.BlizzStyle.Get("cdmicons") then return end
                    BD().borderClassColor = true
                    ns.RefreshCDMIconAppearance(BD().key); Refresh(); UpdateCDMPreview()
                    EllesmereUI:RefreshPage()
                end)
                classBorderSwatch:SetScript("OnEnter", function()
                    EllesmereUI.ShowWidgetTooltip(classBorderSwatch, "Class Colored")
                end)
                classBorderSwatch:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)

                -- Custom color swatch (left of class swatch)
                local swatch, updateSwatch = EllesmereUI.BuildColorSwatch(
                    rightRgn, bsRow:GetFrameLevel() + 3,
                    function() return BD().borderR or 0, BD().borderG or 0, BD().borderB or 0 end,
                    function(r, g, b)
                        BD().borderR, BD().borderG, BD().borderB = r, g, b
                        ns.RefreshCDMIconAppearance(BD().key); Refresh(); UpdateCDMPreview()
                    end,
                    false, 20)
                PP.Point(swatch, "RIGHT", classBorderSwatch, "LEFT", -8, 0)
                swatch:SetScript("OnEnter", function()
                    EllesmereUI.ShowWidgetTooltip(swatch, "Custom Color")
                end)
                swatch:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)

                -- Click the dimmed custom swatch to switch back from class color (no block overlay)
                local origClick = swatch:GetScript("OnClick")
                swatch:SetScript("OnClick", function(self, ...)
                    if EllesmereUI.BlizzStyle.Get("cdmicons") then return end
                    if BD().borderClassColor then
                        BD().borderClassColor = false
                        ns.RefreshCDMIconAppearance(BD().key); Refresh(); UpdateCDMPreview()
                        EllesmereUI:RefreshPage()
                        return
                    end
                    -- No border selected: allow swapping boxes but do not open the color picker
                    if (BD().borderThickness or "thin") == "none" then return end
                    if origClick then origClick(self, ...) end
                end)

                local function UpdateBorderSwatchState()
                    local isClassColored = BD().borderClassColor
                    local isNone = (BD().borderThickness or "thin") == "none" or EllesmereUI.BlizzStyle.Get("cdmicons")
                    swatch:SetAlpha((isClassColored or isNone) and 0.3 or 1)
                    classBorderSwatch:SetAlpha((isClassColored and not isNone) and 1 or 0.3)
                end
                EllesmereUI.RegisterWidgetRefresh(function() updateSwatch(); updateClassBorderSwatch(); UpdateBorderSwatchState() end)
                UpdateBorderSwatchState()
            end
            -- Sync icon on Border Size (right region)
            if not EllesmereUI._prebuilding then
            EllesmereUI.BuildSyncIcon({
                region  = bsRow._rightRegion,
                tooltip = "Apply Border Size to all Bars",
                isSynced = function()
                    local bd = BD()
                    local v = bd.borderThickness or "thin"
                    local px = bd.borderSizePx or false
                    local cc = bd.borderClassColor
                    local bt = bd.borderTexture or "solid"
                    local sx = bd.borderTextureShiftX
                    local sy = bd.borderTextureShiftY
                    local br, bg, bb, ba = bd.borderR or 0, bd.borderG or 0, bd.borderB or 0, bd.borderA or 1
                    local synced = true
                    ForEachSyncBar(function(b)
                        if (b.borderThickness or "thin") ~= v or (b.borderSizePx or false) ~= px or b.borderClassColor ~= cc or (b.borderTexture or "solid") ~= bt then synced = false end
                        if b.borderTextureShiftX ~= sx or b.borderTextureShiftY ~= sy then synced = false end
                        if (b.borderR or 0) ~= br or (b.borderG or 0) ~= bg or (b.borderB or 0) ~= bb or (b.borderA or 1) ~= ba then synced = false end
                    end)
                    return synced
                end,
                onClick = function()
                    local bd = BD()
                    local v = bd.borderThickness or "thin"
                    local sz = bd.borderSize or 1
                    local px = bd.borderSizePx
                    local cc = bd.borderClassColor
                    local bt = bd.borderTexture or "solid"
                    local sx = bd.borderTextureShiftX
                    local sy = bd.borderTextureShiftY
                    local br, bg, bb, ba = bd.borderR, bd.borderG, bd.borderB, bd.borderA
                    ForEachSyncBar(function(b)
                        b.borderThickness = v; b.borderSize = sz
                            local pxv = px
                            if pxv == nil and b.borderSizePx ~= nil then pxv = false end
                            b.borderSizePx = pxv
                        b.borderClassColor = cc; b.borderTexture = bt
                        b.borderTextureShiftX = sx; b.borderTextureShiftY = sy
                        b.borderR = br; b.borderG = bg; b.borderB = bb; b.borderA = ba
                    end)
                    ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreview(); EllesmereUI:RefreshPage()
                end,
            })
            end
        end
        end -- not isBuffGlowBar

        -- (Active Animation UI removed -- active state is now per-icon via spell picker dropdown)

        -- (Sync) Custom Icon Shape | (Sync) Icon Zoom (CD/utility bars only;
        -- buff bars have both in their own Row 3 above)
        if not isBuffGlowBar then
        local shapeRow
        shapeRow, h = W:DualRow(parent, y,
            EllesmereUI.BlizzStyle.Gate("cdmicons", { type="dropdown", text="Custom Icon Shape",
                values=SHAPE_VALUES, order=SHAPE_ORDER,
                itemDisabled=function(val)
                    if val ~= "none" and val ~= "cropped" and (BD().borderTexture or "solid") ~= "solid" then return true end
                    return false
                end,
                itemDisabledTooltip=function(val)
                    if val ~= "none" and val ~= "cropped" and (BD().borderTexture or "solid") ~= "solid" then
                        return "This option requires the Border Style to be set to Solid"
                    end
                end,
                getValue=function() return BD().iconShape or "none" end,
                setValue=function(v)
                    local bd = BD()
                    bd.iconShape = v
                    bd.iconZoom = ns.CDM_SHAPE_ZOOM_DEFAULTS[v] or 0.08
                    local isCS = (v ~= "none" and v ~= "cropped")
                    if isCS then
                        bd.borderThickness = "strong"; bd.borderSize = BORDER_SIZES["strong"]
                        bd.activeStateAnim = "blizzard"
                    else
                        bd.borderThickness = "thin"; bd.borderSize = BORDER_SIZES["thin"]
                    end
                    bd._matchIconPhys = nil
                    bd._matchExtraPixels = nil
                    bd._matchStride = nil
                    bd._matchExtraPixelsH = nil
                    bd._matchStrideH = nil
                    ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreviewAndResize()
                    -- The Border Size slot is a different control under a custom shape: rebuild the page.
                    EllesmereUI:RefreshPage(true)
                end }),
            EllesmereUI.BlizzStyle.Gate("cdmicons", { type="slider", text="Icon Zoom",
                min=0, max=0.20, step=0.01,
                getValue=function() return BD().iconZoom or 0.08 end,
                setValue=function(v)
                    BD().iconZoom = v
                    ns.RefreshCDMIconAppearance(BD().key); Refresh(); UpdateCDMPreview()
                end }));  y = y - h

        AttachCropCog(shapeRow._leftRegion)

        if not EllesmereUI._prebuilding then
        EllesmereUI.BuildSyncIcon({
            region  = shapeRow._leftRegion,
            tooltip = "Apply Icon Shape to all Bars",
            isSynced = function()
                local bd = BD()
                local v = bd.iconShape or "none"
                local zoom = bd.iconZoom or 0.08
                local crop = ns.CdmCropPercent(bd)
                local synced = true
                ForEachSyncBar(function(b) if (b.iconShape or "none") ~= v or (b.iconZoom or 0.08) ~= zoom or ns.CdmCropPercent(b) ~= crop then synced = false end end)
                return synced
            end,
            onClick = function()
                local bd = BD()
                local v = bd.iconShape or "none"
                local zoom = bd.iconZoom or 0.08
                local crop = bd.iconCropPercent
                ForEachSyncBar(function(b)
                    b.iconShape = v; b.iconZoom = zoom; b.iconCropPercent = crop
                    local isCS = (v ~= "none" and v ~= "cropped")
                    if isCS then b.borderThickness = "strong"; b.borderSize = BORDER_SIZES["strong"]
                    else b.borderThickness = "thin"; b.borderSize = BORDER_SIZES["thin"] end
                    b._matchIconPhys = nil
                    b._matchExtraPixels = nil
                    b._matchStride = nil
                    b._matchExtraPixelsH = nil
                    b._matchStrideH = nil
                end)
                ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreviewAndResize(); EllesmereUI:RefreshPage()
            end,
        })
        end
        if not EllesmereUI._prebuilding then
        EllesmereUI.BuildSyncIcon({
            region  = shapeRow._rightRegion,
            tooltip = "Apply Icon Zoom to all Bars",
            isSynced = function()
                local v = BD().iconZoom or 0.08
                local synced = true
                ForEachSyncBar(function(b) if (b.iconZoom or 0.08) ~= v then synced = false end end)
                return synced
            end,
            onClick = function()
                local v = BD().iconZoom or 0.08
                ForEachSyncBar(function(b) b.iconZoom = v end)
                ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreview(); EllesmereUI:RefreshPage()
            end,
        })
        end
        end -- not isBuffGlowBar

        -- Row 4: Duration Size (swatch + cog) | Stack Size (swatch + cog)
        local durationRow
        durationRow, h = W:DualRow(parent, y,
            { type="slider", text="Duration Size",
              min=6, max=30, step=1, trackWidth=120,
              getValue=function() return BD().cooldownFontSize or 12 end,
              setValue=function(v)
                  BD().cooldownFontSize = v
                  ns.RefreshCDMIconAppearance(BD().key); Refresh(); UpdateCDMPreview()
              end },
            { type="slider", text="Charge/Stack Size",
              min=6, max=30, step=1, trackWidth=120,
              getValue=function() return BD().stackCountSize or 11 end,
              setValue=function(v)
                  BD().stackCountSize = v
                  ns.RefreshCDMIconAppearance(BD().key); ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreview()
              end }
        );  y = y - h

        -- Duration Size: inline color swatch + cog
        if not EllesmereUI._prebuilding then
            local leftRgn = durationRow._leftRegion
            local ctrl = leftRgn._control
            local durSwatch, updateDurSwatch = EllesmereUI.BuildColorSwatch(
                leftRgn, durationRow:GetFrameLevel() + 3,
                function() return BD().cooldownTextR or 1, BD().cooldownTextG or 1, BD().cooldownTextB or 1 end,
                function(r, g, b)
                    BD().cooldownTextR = r; BD().cooldownTextG = g; BD().cooldownTextB = b
                    ns.RefreshCDMIconAppearance(BD().key); Refresh(); UpdateCDMPreview()
                end,
                false, 20)
            PP.Point(durSwatch, "RIGHT", ctrl, "LEFT", -12, 0)
            leftRgn._lastInline = durSwatch

            local durBlock = CreateFrame("Frame", nil, durSwatch)
            durBlock:SetAllPoints(); durBlock:SetFrameLevel(durSwatch:GetFrameLevel() + 10); durBlock:EnableMouse(true)
            durBlock:SetScript("OnEnter", function()
                EllesmereUI.ShowWidgetTooltip(durSwatch, EllesmereUI.DisabledTooltip("Duration Text"))
            end)
            durBlock:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
            EllesmereUI.RegisterWidgetRefresh(function()
                if updateDurSwatch then updateDurSwatch() end
                local on = BD().showCooldownText ~= false
                durSwatch:SetAlpha(on and 1 or 0.3)
                if on then durBlock:Hide() else durBlock:Show() end
            end)
            local on = BD().showCooldownText ~= false
            durSwatch:SetAlpha(on and 1 or 0.3)
            if on then durBlock:Hide() else durBlock:Show() end

            EllesmereUI.BuildInlineCog(leftRgn, { anchorTo = durSwatch, icon = EllesmereUI.DIRECTIONS_ICON,
                title = "Duration Text",
                rows = {
                    { type="toggle", label="Show Duration",
                      get=function() return BD().showCooldownText ~= false end,
                      set=function(v)
                          BD().showCooldownText = v
                          ns.RefreshCDMIconAppearance(BD().key); Refresh(); EllesmereUI:RefreshPage()
                      end },
                    { type="dropdown", label="Position",
                      values=durationPositionValues, order=durationPositionOrder,
                      get=function() return BD().cooldownTextPosition or "center" end,
                      set=function(v)
                          BD().cooldownTextPosition = v
                          ns.RefreshCDMIconAppearance(BD().key); Refresh(); UpdateCDMPreview()
                      end },
                    { type="slider", label="X Offset", min=-50, max=50, step=1,
                      get=function() return BD().cooldownTextX or 0 end,
                      set=function(v)
                          BD().cooldownTextX = v
                          ns.RefreshCDMIconAppearance(BD().key); Refresh()
                      end },
                    { type="slider", label="Y Offset", min=-50, max=50, step=1,
                      get=function() return BD().cooldownTextY or 0 end,
                      set=function(v)
                          BD().cooldownTextY = v
                          ns.RefreshCDMIconAppearance(BD().key); Refresh()
                      end },
                },
            })
        end

        -- Stack Size: inline color swatch + cog
        if not EllesmereUI._prebuilding then
            local rightRgn = durationRow._rightRegion
            local ctrl = rightRgn._control
            local scSwatch, updateScSwatch = EllesmereUI.BuildColorSwatch(
                rightRgn, durationRow:GetFrameLevel() + 3,
                function() return BD().stackCountR or 1, BD().stackCountG or 1, BD().stackCountB or 1 end,
                function(r, g, b)
                    BD().stackCountR = r; BD().stackCountG = g; BD().stackCountB = b
                    ns.RefreshCDMIconAppearance(BD().key); ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreview()
                end,
                false, 20)
            PP.Point(scSwatch, "RIGHT", ctrl, "LEFT", -12, 0)
            rightRgn._lastInline = scSwatch

            local scBlock = CreateFrame("Frame", nil, scSwatch)
            scBlock:SetAllPoints(); scBlock:SetFrameLevel(scSwatch:GetFrameLevel() + 10); scBlock:EnableMouse(true)
            scBlock:SetScript("OnEnter", function()
                EllesmereUI.ShowWidgetTooltip(scSwatch, EllesmereUI.DisabledTooltip("Item Count"))
            end)
            scBlock:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
            EllesmereUI.RegisterWidgetRefresh(function()
                if updateScSwatch then updateScSwatch() end
                local on = BD().showItemCount ~= false
                scSwatch:SetAlpha(on and 1 or 0.3)
                if on then scBlock:Hide() else scBlock:Show() end
            end)
            local on = BD().showItemCount ~= false
            scSwatch:SetAlpha(on and 1 or 0.3)
            if on then scBlock:Hide() else scBlock:Show() end

            local scPopupSpec = {
                title = "Charges/Stacks",
                rows = {
                    -- View over the legacy showItemCount boolean (Never = false,
                    -- Always = true/nil) plus the itemCountOOC flag for the new
                    -- Out of Combat mode. OOC keeps showItemCount = true so every
                    -- legacy reader treats it as "on"; the combat gate lives in
                    -- the icon restyle. Zero migration.
                    { type="dropdown", label="Show Item Count",
                      values={ never="Never", always="Always", ooc="Out of Combat" },
                      order={ "never", "always", "ooc" },
                      get=function()
                          if BD().itemCountOOC then return "ooc" end
                          return (BD().showItemCount ~= false) and "always" or "never"
                      end,
                      set=function(v)
                          local bd = BD()
                          bd.itemCountOOC = (v == "ooc") or nil
                          bd.showItemCount = (v ~= "never")
                          ns.RefreshCDMIconAppearance(bd.key); ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreview(); EllesmereUI:RefreshPage()
                      end },
                    -- Crafted-rank pip on tracked items (ranks share icon art, so
                    -- two ranks are otherwise indistinguishable). Off by default.
                    { type="toggle", label="Show Item Quality",
                      tooltip="Show the crafted quality rank on tracked items, matching the rank icon on the action bars. Items with no crafted quality are unaffected.",
                      get=function() return BD().showItemQuality == true end,
                      set=function(v)
                          BD().showItemQuality = v
                          if ns.FullCDMRebuild then ns.FullCDMRebuild("item_quality_toggle") end
                      end },
                    -- Buff-family only (stripped below for cd/utility): those
                    -- bars hide counters via the per-spell Hide Charge Text
                    -- lane, which owns their counter alpha channel.
                    { type="toggle", label="Show Charge/Stack Text",
                      tooltip="Show the charge and stack counters on this bar's icons.",
                      get=function() return BD().showChargeStackText ~= false end,
                      -- if/else, NOT `v and nil or false`: that expression is
                      -- ALWAYS false (the nil arm falls through the or).
                      set=function(v)
                          if v then BD().showChargeStackText = nil
                          else BD().showChargeStackText = false end
                          ns.RefreshCDMIconAppearance(BD().key); Refresh(); UpdateCDMPreview()
                      end },
                    { type="dropdown", label="Position",
                      values={ bottomright="Bottom Right", bottom="Bottom", bottomleft="Bottom Left", left="Left", topleft="Top Left", top="Top", topright="Top Right", right="Right", center="Center" },
                      order={ "bottomright", "bottom", "bottomleft", "left", "topleft", "top", "topright", "right", "center" },
                      get=function() return BD().stackCountPosition or "bottomright" end,
                      set=function(v)
                          BD().stackCountPosition = v
                          ns.RefreshCDMIconAppearance(BD().key); ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreview()
                      end },
                    { type="slider", label="X Offset", min=-150, max=150, step=1,
                      get=function() return BD().stackCountX or 0 end,
                      set=function(v)
                          BD().stackCountX = v
                          ns.RefreshCDMIconAppearance(BD().key); ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreview()
                      end },
                    { type="slider", label="Y Offset", min=-150, max=150, step=1,
                      get=function() return BD().stackCountY or 0 end,
                      set=function(v)
                          BD().stackCountY = v
                          ns.RefreshCDMIconAppearance(BD().key); ns.BuildAllCDMBars(); Refresh(); UpdateCDMPreview()
                      end },
                },
            }
            -- Show Charge/Stack Text (row 3) is buff-family only -- see its comment.
            if not isBuffGlowBar then table.remove(scPopupSpec.rows, 3) end
            scPopupSpec.icon, scPopupSpec.anchorTo = EllesmereUI.DIRECTIONS_ICON, scSwatch
            EllesmereUI.BuildInlineCog(rightRgn, scPopupSpec)
        end

        -- Suppress GCD (CD/utility bars only) | Pixel Glow Thickness (+ cog: Lines/Speed)
        if not isBuffGlowBar then
        if ns.CDM_BarHasPixelRow(barData) then
            local sgcdRow
            sgcdRow, h = W:DualRow(parent, y,
                { type="toggle", text="Suppress GCD",
                  tooltip="Hide the brief GCD swipe that flashes when you cast any spell. The actual ability cooldown swipe still shows.",
                  getValue=function() return BD().suppressGCD == true end,
                  setValue=function(v) BD().suppressGCD = v and true or false; Refresh() end },
                { type="slider", text="Pixel Glow Thickness", min=1, max=4, step=1, trackWidth=120,
                  tooltip="Thickness of any Pixel Glow assigned to this bar's buttons. Assign glows by right-clicking an icon in the preview.",
                  getValue=function() return BD().pixelGlowThickness or 2 end,
                  setValue=function(v)
                      BD().pixelGlowThickness = v
                      ns.BuildAllCDMBars(); if ns.RequestBarGlowUpdate then ns.RequestBarGlowUpdate() end; Refresh()
                  end });  y = y - h
            -- Inline cog on Pixel Glow Thickness: Lines + Speed
            if not EllesmereUI._prebuilding then
                local rightRgn = sgcdRow._rightRegion
                EllesmereUI.BuildInlineCog(rightRgn, { icon = EllesmereUI.RESIZE_ICON,
                    title = "Pixel Glow",
                    rows = {
                        { type="slider", label="Lines", min=2, max=16, step=1,
                          get=function() return BD().pixelGlowLines or 8 end,
                          set=function(v)
                              BD().pixelGlowLines = v
                              ns.BuildAllCDMBars(); if ns.RequestBarGlowUpdate then ns.RequestBarGlowUpdate() end
                          end },
                        { type="slider", label="Speed", min=1, max=8, step=1,
                          get=function() return 9 - (BD().pixelGlowSpeed or 4) end,
                          set=function(v)
                              BD().pixelGlowSpeed = 9 - v
                              ns.BuildAllCDMBars(); if ns.RequestBarGlowUpdate then ns.RequestBarGlowUpdate() end
                          end },
                        { type="toggle", label="Background",
                          get=function() return BD().pixelGlowBackground == true end,
                          set=function(v)
                              BD().pixelGlowBackground = v and true or nil
                              ns.BuildAllCDMBars(); if ns.RequestBarGlowUpdate then ns.RequestBarGlowUpdate() end
                          end },
                        { type="colorpicker", label="Background Color",
                          get=function() return BD().pixelGlowBackgroundR or 0, BD().pixelGlowBackgroundG or 0, BD().pixelGlowBackgroundB or 0 end,
                          set=function(r, g, b)
                              BD().pixelGlowBackgroundR = r; BD().pixelGlowBackgroundG = g; BD().pixelGlowBackgroundB = b
                              ns.BuildAllCDMBars(); if ns.RequestBarGlowUpdate then ns.RequestBarGlowUpdate() end
                          end,
                          disabled=function() return BD().pixelGlowBackground ~= true end,
                          disabledTooltip="Pixel Glow Background" },
                    },
                })
            end
        end
        end

        -- Pixel Glow Thickness (buff bars) -- mirrors the CD/utility row above.
        -- Reuses the same buffGlow* variables so user settings are unchanged.
        -- Always enabled (no disabled state).
        if isBuffGlowBar then
            local pgRow
            pgRow, h = W:DualRow(parent, y,
                { type="slider", text="Pixel Glow Thickness", min=1, max=4, step=1, trackWidth=120,
                  tooltip="Thickness of the Pixel Glow applied to this bar's buff icons.",
                  getValue=function() return BD().buffGlowThickness or 2 end,
                  setValue=function(v)
                      BD().buffGlowThickness = v
                      ns.BuildAllCDMBars(); if ns.RefreshBuffGlows then ns.RefreshBuffGlows() end; Refresh()
                  end },
                { type="toggle", text="Only Show Numbers",
                  tooltip="Hide this bar's icons and show only the duration text.",
                  getValue=function() return BD().onlyShowNumbers == true end,
                  setValue=function(v)
                      BD().onlyShowNumbers = v and true or nil
                      ns.BuildAllCDMBars(); Refresh()
                  end });  y = y - h
            -- Inline cog on Pixel Glow Thickness: Lines + Speed (buffGlow* vars)
            if not EllesmereUI._prebuilding then
                local leftRgn = pgRow._leftRegion
                EllesmereUI.BuildInlineCog(leftRgn, { icon = EllesmereUI.RESIZE_ICON,
                    title = "Pixel Glow",
                    rows = {
                        { type="slider", label="Lines", min=2, max=16, step=1,
                          get=function() return BD().buffGlowLines or 8 end,
                          set=function(v)
                              BD().buffGlowLines = v
                              ns.BuildAllCDMBars(); if ns.RefreshBuffGlows then ns.RefreshBuffGlows() end
                          end },
                        { type="slider", label="Speed", min=1, max=8, step=1,
                          get=function() return 9 - (BD().buffGlowSpeed or 4) end,
                          set=function(v)
                              BD().buffGlowSpeed = 9 - v
                              ns.BuildAllCDMBars(); if ns.RefreshBuffGlows then ns.RefreshBuffGlows() end
                          end },
                        { type="toggle", label="Background",
                          get=function() return BD().buffGlowBackground == true end,
                          set=function(v)
                              BD().buffGlowBackground = v and true or nil
                              ns.BuildAllCDMBars(); if ns.RefreshBuffGlows then ns.RefreshBuffGlows() end
                          end },
                        { type="colorpicker", label="Background Color",
                          get=function() return BD().buffGlowBackgroundR or 0, BD().buffGlowBackgroundG or 0, BD().buffGlowBackgroundB or 0 end,
                          set=function(r, g, b)
                              BD().buffGlowBackgroundR = r; BD().buffGlowBackgroundG = g; BD().buffGlowBackgroundB = b
                              ns.BuildAllCDMBars(); if ns.RefreshBuffGlows then ns.RefreshBuffGlows() end
                          end,
                          disabled=function() return BD().buffGlowBackground ~= true end,
                          disabledTooltip="Pixel Glow Background" },
                    },
                })
            end
        end

        -- Charges/Stacks Only (cd/utility bars) -- the counterpart to the buff
        -- bars' "Only Show Numbers" above. Strips the icon down to its charge /
        -- stack counter: art, swipe, recharge edge and cooldown text all go.
        if not isBuffGlowBar
           and (barData.barType == "cooldowns" or barData.barType == "utility") then
            _, h = W:DualRow(parent, y,
                { type="toggle", text="Charges/Stacks Only (No Icon)",
                  tooltip="Hide this bar's icon art, cooldown swipe, recharge edge and cooldown text, leaving only the charge or stack count.",
                  getValue=function() return BD().chargesOnly == true end,
                  setValue=function(v)
                      BD().chargesOnly = v and true or nil
                      ns.BuildAllCDMBars(); Refresh()
                  end },
                { type="toggle", text="Hide Charge Count at 0",
                  tooltip="Hide the charge number while a spell has no charges left, instead of showing a 0. The number returns as soon as a charge comes back.",
                  getValue=function() return BD().hideZeroChargeText == true end,
                  setValue=function(v)
                      BD().hideZeroChargeText = v and true or nil
                      ns.BuildAllCDMBars(); Refresh()
                  end });  y = y - h
        end

        _, h = W:Spacer(parent, y, 8);  y = y - h

        -------------------------------------------------------------------
        --  EXTRAS (not shown for custom aura bars or FocusKick)
        -------------------------------------------------------------------
        local isCustomBuffBar = (barData.barType == "custom_buff")
        local isAnyBuffBar = isBuffGlowBar  -- buffs or custom_buff
        if ns.CDM_BarHasExtras(barData) then
        _, h = W:SectionHeader(parent, "EXTRAS", y);  y = y - h

        -- Hide Items if Missing: one config, hosted in a different row per bar
        -- family. Buff bars carry it in the tooltip row's right slot; CD and
        -- utility bars keep it beside Mirror Key Presses further down.
        local hideMissingCfg = { type="toggle", text="Hide Items if Missing",
              tooltip = "Hide consumable items (potions, healthstone) from the bar when you have none in your bags, instead of showing them dimmed. They reappear automatically once you have the item again.",
              getValue=function() return BD().hideItemsIfMissing == true end,
              setValue=function(v)
                  BD().hideItemsIfMissing = v
                  if ns.FullCDMRebuild then ns.FullCDMRebuild("hide_missing_toggle") end
              end }
        -- Buffs get "Show Tooltip on Hover" only (auras aren't cast -> no keybind);
        -- cooldown/utility icon bars get the Tooltip | Keybind pair below.
        if isAnyBuffBar then
        local _, tth = W:DualRow(parent, y,
            { type="toggle", text="Show Tooltip on Hover",
              getValue=function() return BD().showTooltip == true end,
              setValue=function(v)
                  BD().showTooltip = v
                  ns.ApplyCDMTooltipState(BD().key)
                  Refresh()
              end },
            hideMissingCfg
        );  y = y - tth
        else
        local kbRow
        kbRow, h = W:DualRow(parent, y,
            { type="toggle", text="Show Tooltip on Hover",
              getValue=function() return BD().showTooltip == true end,
              setValue=function(v)
                  BD().showTooltip = v
                  ns.ApplyCDMTooltipState(BD().key)
                  Refresh()
              end },
            { type="toggle", text="Show Keybind",
              getValue=function() return BD().showKeybind == true end,
              setValue=function(v)
                  local b = BD()
                  b.showKeybind = v
                  ns.RefreshCDMIconAppearance(b.key); ns.ApplyCachedKeybinds(); UpdateCDMPreview(); EllesmereUI:RefreshPage()
              end }
        );  y = y - h

        BuildKeybindStyleControls(kbRow, BD, function()
            ns.RefreshCDMIconAppearance(BD().key); ns.ApplyCachedKeybinds()
            UpdateCDMPreview(); EllesmereUI:RefreshPage()
        end)
        end -- if isAnyBuffBar (tooltip only) / else (tooltip + keybind)

        -- Pandemic Glow: the Glows page's descriptor over this bar, with the
        -- preview and the Pixel Glow cog inline and the swatches in the right half.
        do
            local GO = EllesmereUI.GlowOptions
            local panDesc = ns._CDM_PandemicGlowDesc(BD, function() ns.BuildAllCDMBars(); Refresh() end)
            local panGlowRow
            panGlowRow, h = W:DualRow(parent, y,
                GO.DropdownSpec(panDesc, "Pandemic Glow",
                    "Show a glow on icons when the remaining duration is in the pandemic window (last 30%)"),
                { type="label", text="Pandemic Glow Color" });  y = y - h

            if not EllesmereUI._prebuilding then
                local leftRgn = panGlowRow._leftRegion
                leftRgn._lastInline = GO.BuildPreview(leftRgn, panDesc, { anchor = leftRgn._control, x = -8 })
                GO.AttachInline(leftRgn, panDesc, panGlowRow._rightRegion)

                if EllesmereUI.BuildSyncIcon and EllesmereUI.ApplyPandemicGlowToAll then
                    EllesmereUI.BuildSyncIcon({
                        region = panGlowRow._leftRegion,
                        tooltip = "Apply this pandemic glow to Nameplates, all CDM bars, and tracking bars. A surface that can't show a style uses its closest match.",
                        isSynced = function()
                            return EllesmereUI.IsPandemicGlowSyncedToAll(EllesmereUI.PandemicPayloadFromCdmBar(BD()), { skipCdmKey = barKey })
                        end,
                        onClick = function()
                            EllesmereUI.ApplyPandemicGlowToAll(EllesmereUI.PandemicPayloadFromCdmBar(BD()), { skipCdmKey = barKey })
                            Refresh()
                        end,
                    })
                end
            end
        end

        -- Show Non-On Use Trinkets | Show Rotation Helper. Forever has no
        -- Assisted Highlight: there the trinket toggle closes the section
        -- instead (beside Show Glows Only in Combat, or as the odd last slot).
        local trinketCfg = { type="toggle", text="Show Non-On Use Trinkets",
              tooltip = "Show equipped trinkets even if they don't have an on-use effect.",
              getValue=function() return BD().showPassiveTrinkets == true end,
              setValue=function(v)
                  BD().showPassiveTrinkets = v
                  if ns.FullCDMRebuild then ns.FullCDMRebuild("trinket_toggle") end
              end }
        if not EllesmereUI.IS_FOREVER then
        _, h = W:DualRow(parent, y,
            trinketCfg,
            { type="toggle", text="Show Rotation Helper",
              tooltip = "Highlight Blizzard's next recommended ability on all CDM bars. Requires Assisted Highlight to be enabled in Blizzard's options. Disabling this hides only the CDM highlight.\n\nPress the normal ability's keybind yourself. This does not cast spells or use the Single-Button Assistant, so it does not add that assistant's global cooldown penalty. Only abilities present on your CDM bars can be highlighted.",
              disabled=function() return not ns.RotationAssistAvailable() end,
              disabledTooltip="This option requires Blizzard's Assisted Highlight to be enabled",
              rawTooltip=true,
              getValue=function()
                  local p = DB()
                  return p and p.cdmBars and not p.cdmBars.hideRotationHelper and ns.RotationAssistAvailable()
              end,
              setValue=function(v)
                  local p = DB()
                  if p and p.cdmBars then
                      p.cdmBars.hideRotationHelper = not v
                      if ns.UpdateRotationHighlights then ns.UpdateRotationHighlights() end
                      -- The Style and Thickness rows below exist only while this
                      -- is on (the Glows page rebuilds its listing on every return).
                      EllesmereUI:RefreshPage(true)
                  end
              end });  y = y - h
        end -- not IS_FOREVER

        -- Rotation Assist styling is profile-wide (not tied to the selected
        -- bar). Keeping it on this override-eligible page lets the existing
        -- spec/conditional override system capture every scalar below.
        -- Read and write the runtime addon's authoritative profile. The options
        -- DB reference can lag behind a profile/override proxy swap, which made
        -- the swatches display Class while the renderer still read Custom.
        local function RotationBars()
            local runtime = ns.ECME and ns.ECME.db and ns.ECME.db.profile
            local fallback = DB()
            return (runtime and runtime.cdmBars) or (fallback and fallback.cdmBars)
        end
        -- Which of the Thickness / Outset rows the current style reads (the renderer
        -- uses thickness for Solid Border and Pixel Glow, outset for every style but
        -- Blizzard Default): 0 = neither, 1 = outset only, 3 = both. The rows below
        -- exist only for the styles that read them, so the Style dropdown forces a
        -- rebuild when this key flips.
        local function RotRowsKey()
            local c = RotationBars()
            local s = (c and c.rotationAssistStyle) or "blizzard"
            local key = 0
            if s ~= "blizzard" then key = 1 end
            if s == "solid" or s == "pixel" then key = key + 2 end
            return key
        end

        -- Style | Color and Thickness | Outset: built only while the CDM highlight
        -- can show (Show Rotation Helper on, Blizzard's Assisted Highlight on).
        if not ns._CDM_RotationHelperOff() then
        local rotStyleRow
        rotStyleRow, h = W:DualRow(parent, y,
            { type="dropdown", text="Rotation Assist Style",
              values={
                  blizzard="Blizzard Default", solid="Solid Border",
                  pixel="Pixel Glow", shape="Shape Glow",
                  button="Action Button Glow", autocast="Auto-Cast Shine",
                  gcd="GCD", modern="Modern WoW Glow", classic="Classic WoW Glow",
              },
              order={ "blizzard", "solid", "pixel", "shape", "button", "autocast", "gcd", "modern", "classic" },
              tooltip="Choose the profile-wide border or glow used for Blizzard's Assisted Combat suggestion.",
              getValue=function()
                  local c = RotationBars(); return (c and c.rotationAssistStyle) or "blizzard"
              end,
              setValue=function(v)
                  local c = RotationBars()
                  if c then
                      local before = RotRowsKey()
                      c.rotationAssistStyle = v
                      if ns.UpdateRotationHighlights then ns.UpdateRotationHighlights() end
                      -- Full rebuild only when the Thickness / Outset row set changes;
                      -- the in-place refresh otherwise.
                      EllesmereUI:RefreshPage(RotRowsKey() ~= before)
                  end
              end },
            { type="label", text="Rotation Assist Color" });  y = y - h

        do
            local colorRgn = rotStyleRow._rightRegion
            if colorRgn and EllesmereUI.BuildTrioColorSwatch then
                -- Same trio as the Pandemic Glow row above. The helper opens the
                -- picker only while custom mode is already active, so a picker
                -- cancel can never flip the mode. Dimmed while Blizzard Default
                -- owns the highlight; clicks are ignored there.
                local function rotColorOff()
                    local c = RotationBars()
                    return not c or c.rotationAssistStyle == "blizzard"
                end
                local swatch, defaultSwatch, classSwatch = EllesmereUI.BuildTrioColorSwatch(
                    colorRgn, rotStyleRow:GetFrameLevel() + 3,
                    {
                        getMode = function()
                            local c = RotationBars()
                            return (c and c.rotationAssistColorMode) or "default"
                        end,
                        setMode = function(mode)
                            local c = RotationBars()
                            if not c or c.rotationAssistStyle == "blizzard" then return end
                            c.rotationAssistColorMode = mode
                            if ns.UpdateRotationHighlights then ns.UpdateRotationHighlights() end
                            EllesmereUI._NotifySettingWrite(colorRgn)
                        end,
                        getCustomRGB = function()
                            local c = RotationBars()
                            return (c and c.rotationAssistColorR) or 1,
                                   (c and c.rotationAssistColorG) or 0,
                                   (c and c.rotationAssistColorB) or 0
                        end,
                        setCustomRGB = function(r, g, b)
                            local c = RotationBars()
                            if c then
                                c.rotationAssistColorR = r
                                c.rotationAssistColorG = g
                                c.rotationAssistColorB = b
                            end
                            if ns.UpdateRotationHighlights then ns.UpdateRotationHighlights() end
                        end,
                        hasClassColor = true,
                        onChange = function() EllesmereUI:RefreshPage() end,
                        disabled = rotColorOff,
                        disabledAlpha = 0.15,
                    })
                PP.Point(classSwatch, "RIGHT", colorRgn, "RIGHT", -20, 0)
                PP.Point(swatch, "RIGHT", classSwatch, "LEFT", -8, 0)
                PP.Point(defaultSwatch, "RIGHT", swatch, "LEFT", -8, 0)

                local function UpdateRotSwatchMouse()
                    local off = rotColorOff()
                    swatch:EnableMouse(not off)
                    defaultSwatch:EnableMouse(not off)
                    classSwatch:EnableMouse(not off)
                end
                EllesmereUI.RegisterWidgetRefresh(UpdateRotSwatchMouse)
                UpdateRotSwatchMouse()
                colorRgn._captureCfg = {
                    type = "multi", text = "Rotation Assist Color",
                    accessors = {
                        {
                            type = "dropdown", text = "Rotation Assist Color Mode",
                            values = { default = "Default", custom = "Custom", class = "Class Color" },
                            order = { "default", "custom", "class" },
                            getValue = function()
                                local c = RotationBars()
                                return (c and c.rotationAssistColorMode) or "default"
                            end,
                            setValue = function(mode)
                                local c = RotationBars()
                                if c then c.rotationAssistColorMode = mode end
                                if ns.UpdateRotationHighlights then ns.UpdateRotationHighlights() end
                            end,
                        },
                        {
                            type = "colorpicker", text = "Rotation Assist Custom Color",
                            getValue = function()
                                local c = RotationBars()
                                return (c and c.rotationAssistColorR) or 1,
                                       (c and c.rotationAssistColorG) or 0,
                                       (c and c.rotationAssistColorB) or 0, 1
                            end,
                            setValue = function(r, g, b)
                                local c = RotationBars()
                                if c then
                                    c.rotationAssistColorR = r
                                    c.rotationAssistColorG = g
                                    c.rotationAssistColorB = b
                                end
                                if ns.UpdateRotationHighlights then ns.UpdateRotationHighlights() end
                            end,
                        },
                    },
                }
            end
        end

        -- Thickness | Outset: built only for the styles that read them (see
        -- RotRowsKey). Outset alone takes the left slot with a blank right slot.
        local rotRows = RotRowsKey()
        if rotRows > 0 then
            local thicknessCfg = { type="slider", text="Rotation Assist Thickness", min=1, max=8, step=1, trackWidth=120,
              tooltip="Thickness in physical pixels for Solid Border and Pixel Glow.",
              getValue=function()
                  local c = RotationBars(); return (c and c.rotationAssistThickness) or 3
              end,
              setValue=function(v)
                  local c = RotationBars()
                  if c then c.rotationAssistThickness = v end
                  if ns.UpdateRotationHighlights then ns.UpdateRotationHighlights() end
              end }
            local outsetCfg = { type="slider", text="Rotation Assist Outset", min=0, max=12, step=1, trackWidth=120,
              tooltip="How many pixels the custom effect extends beyond the icon.",
              getValue=function()
                  local c = RotationBars(); return (c and c.rotationAssistOutset) or 1
              end,
              setValue=function(v)
                  local c = RotationBars()
                  if c then c.rotationAssistOutset = v end
                  if ns.UpdateRotationHighlights then ns.UpdateRotationHighlights() end
              end }
            if rotRows >= 2 then
                local rotThRow
                rotThRow, h = W:DualRow(parent, y, thicknessCfg, outsetCfg);  y = y - h
                -- Pixel Glow's remaining parameters (Solid Border reads thickness only).
                if not EllesmereUI._prebuilding then
                    local function notPixel()
                        local c = RotationBars(); return not c or c.rotationAssistStyle ~= "pixel"
                    end
                    -- The shared Pixel Glow rows over the rotationAssist* keys, minus
                    -- Thickness (it sits on this row itself).
                    local rotCogRows = {}
                    for _, r in ipairs(EllesmereUI.GlowOptions.CogRows(ns._CDM_RotationGlowDesc())) do
                        if r.label ~= "Thickness" then rotCogRows[#rotCogRows + 1] = r end
                    end
                    EllesmereUI.BuildInlineCog(rotThRow._leftRegion, {
                        title = "Pixel Glow Settings",
                        captureRegion = rotThRow._leftRegion,
                        disabled = notPixel,
                        disabledTooltip = "This option requires Pixel Glow to be the selected glow type",
                        rows = rotCogRows,
                    })
                end
            else
                _, h = W:DualRow(parent, y, outsetCfg, EllesmereUI.BlankRowCfg());  y = y - h
            end
        end
        end -- not RotationHelperOff

        -- Hide Items if Missing | Mirror Key Presses -- CD/utility bars only.
        -- Buff bars host Hide Items if Missing in the tooltip row above (their
        -- copy of this row would be empty), and Mirror Key Presses is not for
        -- buff-family bars (buffs are auto-tracked auras, not keybind-pressed
        -- abilities, so a "pressed" look has no meaning). (Per-spell threshold
        -- decimals/color moved to the per-icon dropdown: Threshold Text.)
        if not isAnyBuffBar then
        _, h = W:DualRow(parent, y,
            hideMissingCfg,
            { type="toggle", text="Mirror Key Presses",
              tooltip = "When you press an ability's keybind, show the action button's \"pushed down\" look on its icon on this bar -- even while the ability is on cooldown.",
              getValue=function() return BD().pressMirror == true end,
              setValue=function(v)
                  BD().pressMirror = v
                  if ns.ClearCdmPressPush then ns.ClearCdmPressPush() end
              end });  y = y - h
        end

        -- Bar Strata: per-bar screen render layer for the bar container and its
        -- icons (MEDIUM default = the engine's baseline, so unset bars are
        -- unchanged). Cursor-anchored bars keep their deliberate TOOLTIP raise
        -- while riding the cursor; this applies only when not cursor-anchored.
        -- Same values/labels as the Tracking Bars "Bar Strata" dropdown.
        local strataCfg = { type = "dropdown", text = "Bar Strata",
              tooltip = "Screen layer this bar and its icons render on.",
              values = EllesmereUI.FRAME_STRATA_LABELS,
              order = EllesmereUI.FRAME_STRATA_ORDER_FULL,
              getValue = function() return BD().barStrata or "MEDIUM" end,
              setValue = function(v)
                  BD().barStrata = v
                  ns.BuildAllCDMBars(); Refresh()
              end }
        -- WoW Forever has no combat potion presets, so the swap toggle is not
        -- built there and Bar Strata opens the glow rows below instead.
        if not EllesmereUI.IS_FOREVER then
        _, h = W:DualRow(parent, y,
            strataCfg,
            -- Profile-wide (one switch covers the Light's Potential, Recklessness
            -- and Liquid Luster presets on every CD/utility bar): a pot preset
            -- whose own family is fully out of bags swaps its icon/count/cooldown
            -- to the best pot of the partner families instead of sitting greyed
            -- (Liquid Luster is the final fallback for the other two).
            { type = "toggle", text = "Swap Combat Potions When Missing",
              tooltip = "When your bags have none of one combat potion type, its icon swaps to track the next type you own.",
              getValue = function()
                  local p = DB(); return p and p.cdmBars and p.cdmBars.swapPotionsWhenMissing == true
              end,
              setValue = function(v)
                  local p = DB()
                  if p and p.cdmBars then
                      p.cdmBars.swapPotionsWhenMissing = v
                      if ns._BumpPotResolveGen then ns._BumpPotResolveGen() end
                      if ns.FullCDMRebuild then ns.FullCDMRebuild("pot_swap_toggle") end
                  end
              end });  y = y - h
        end -- not IS_FOREVER

        -- Global, not per-bar: one gate for every glow the Cooldown Manager
        -- draws, hence the label. Same hosting trick as Hide Items if Missing
        -- above -- it takes the cooldown edge row's free slot where that row
        -- exists, and closes the section on its own for buff-family bars.
        local glowCombatCfg = { type="toggle", text="Show Glows Only in Combat (global)",
              tooltip = "Hide every Cooldown Manager glow out of combat and bring them all back the moment you enter combat.",
              getValue=function()
                  local p = DB()
                  return (p and p.cdmBars and p.cdmBars.glowsOnlyInCombat) == true
              end,
              setValue=function(v)
                  local p = DB()
                  if not p or not p.cdmBars then return end
                  p.cdmBars.glowsOnlyInCombat = v and true or false
                  -- Re-read the cached gate, then let the sweep take the running
                  -- glows down (or bring the suppressed ones back) right away
                  -- instead of waiting for the next combat edge.
                  local first = v and ns._cdmGlowGateEverOn ~= true
                  if ns.RefreshGlowCombatGate then ns.RefreshGlowCombatGate() end
                  if ns.CDMGlowCombatSync then ns.CDMGlowCombatSync() end
                  -- First enable of the session: glows lit before this point carry
                  -- no record (StartNativeGlow records only once the gate has been
                  -- on), so re-issue the bar and buff glows now -- they restart
                  -- suppressed. Proc, CD-ready and preset glows already lit follow
                  -- on their own next edge; every later login is exact from the start.
                  if first then
                      if ns.RequestBarGlowUpdate then ns.RequestBarGlowUpdate() end
                      if ns.RefreshBuffGlows then ns.RefreshBuffGlows() end
                  end
                  EllesmereUI:RefreshPage()
              end }

        -- Cooldown/utility bars only: buff bars have no cooldown edge.
        -- WoW Forever: Bar Strata takes the first slot here and every later
        -- toggle moves up one, closing with Show Non-On Use Trinkets.
        if barData.barType == "cooldowns" or barData.barType == "utility" then
        local edgeCfg = { type="toggle", text="Always Show Cooldown Edge",
              tooltip="Show the rotating cooldown edge on every cooldown in this bar, not just while a charge is recharging. Hide Recharge Edge still overrides this for individual charge spells.",
              getValue=function() return BD().showCooldownEdge == true end,
              setValue=function(v)
                  BD().showCooldownEdge = v and true or nil
                  ns.BuildAllCDMBars(); Refresh()
              end }
        if EllesmereUI.IS_FOREVER then
            _, h = W:DualRow(parent, y, strataCfg, edgeCfg);  y = y - h
            _, h = W:DualRow(parent, y, glowCombatCfg, trinketCfg);  y = y - h
        else
            _, h = W:DualRow(parent, y, edgeCfg, glowCombatCfg);  y = y - h
        end
        else
        if EllesmereUI.IS_FOREVER then
            _, h = W:DualRow(parent, y, strataCfg, glowCombatCfg);  y = y - h
            _, h = W:DualRow(parent, y, trinketCfg, EllesmereUI.BlankRowCfg());  y = y - h
        else
            _, h = W:DualRow(parent, y, glowCombatCfg, EllesmereUI.BlankRowCfg());  y = y - h
        end
        end

        end -- custom_buff extras guard

        -----------------------------------------------------------------
        --  ADDITIONAL BAR OFFSET -- render-only X/Y displacement stacked on
        --  top of the bar's normal position (saved, module-anchored, or
        --  unlock-anchored). Unlock mode always shows the BASE position (the
        --  bar's mover gets a distinct tint + tooltip while an offset is set);
        --  the offset re-applies on exit. 0/0 = the feature is fully inert.
        --  FocusKick is nameplate-pinned (no free position, no mover): dead controls there.
        -----------------------------------------------------------------
        if not isFocusKick then
        _, h = W:SectionHeader(parent, "ADDITIONAL BAR OFFSET", y);  y = y - h
        do
            local function SetAddOffset(axisKey, v)
                local b = BD(); if not b then return end
                b[axisKey] = (v ~= 0) and v or nil
                -- The anchor extra-offset registry getter (registered for every eligible bar
                -- by the unlock registration pass below) reads the live value, so no per-edit
                -- set/clear is needed. Re-register unlock elements so the mover's offset
                -- marker (tint + tooltip) reflects the new state at the next unlock entry,
                -- then re-apply positions: the build covers saved and module-anchored
                -- placement, the cascade covers an unlock-anchored bar (the build leaves
                -- those positions to the anchor system).
                if ns.RegisterCDMUnlockElements then ns.RegisterCDMUnlockElements() end
                ns.BuildAllCDMBars()
                if EllesmereUI.IsUnlockAnchored and EllesmereUI.IsUnlockAnchored("CDM_" .. b.key)
                    and EllesmereUI.PropagateAnchorChain then
                    EllesmereUI.PropagateAnchorChain("CDM_" .. b.key)
                end
                Refresh()
            end
            _, h = W:DualRow(parent, y,
                { type = "slider", pixel = true, text = "Offset X", min = -500, max = 500, step = 1, trackWidth = 120,
                  tooltip = "Extra horizontal shift stacked on top of this bar's normal position. Unlock mode shows the base position; the offset re-applies when you exit.",
                  getValue = function() local b = BD(); return (b and b.addOffsetX) or 0 end,
                  setValue = function(v) SetAddOffset("addOffsetX", v) end },
                { type = "slider", pixel = true, text = "Offset Y", min = -500, max = 500, step = 1, trackWidth = 120,
                  tooltip = "Extra vertical shift stacked on top of this bar's normal position. Unlock mode shows the base position; the offset re-applies when you exit.",
                  getValue = function() local b = BD(); return (b and b.addOffsetY) or 0 end,
                  setValue = function(v) SetAddOffset("addOffsetY", v) end }
            );  y = y - h
        end
        end -- not isFocusKick

        return math.abs(y)
    end


    ---------------------------------------------------------------------------
    --  Standalone Rotation Assist Icon (independent of the selected CDM bar)
    ---------------------------------------------------------------------------
    local function BuildRotationAssistIconPage(pageName, parent, yOffset)
        local W = EllesmereUI.Widgets
        local y = yOffset
        local _, h
        parent._showRowDivider = true
        local function Settings() return DB().rotationAssistIcon end
        local function Apply()
            ns.RefreshRotationAssistIcon()
            EllesmereUI:RefreshPage()
        end
        -- Why the icon's rows are locked, nil while they are live: Blizzard's
        -- Assisted Highlight off, or the icon itself off.
        local function IconLockTip()
            if not ns.RotationAssistAvailable() then
                return "This option requires Blizzard's Assisted Highlight to be enabled"
            end
            if Settings().enabled ~= true then return "Show Rotation Assist Icon" end
        end
        local function IconOff() return IconLockTip() ~= nil end
        -- The saved position, else the runtime's default (read only).
        local function Position()
            return Settings().position or ns.CDM_ROTATION_ICON_DEFAULT_POS
        end
        local function SetOffset(axis, value)
            local s = Settings()
            local pos = s.position or CopyTable(ns.CDM_ROTATION_ICON_DEFAULT_POS)
            pos[axis] = EllesmereUI.PP.FromPixels(value)
            s.position = pos
            ns.RefreshRotationAssistIcon()
        end

        _, h = W:SectionHeader(parent, "ROTATION ASSIST ICON", y);  y = y - h
        _, h = W:DualRow(parent, y,
            { type="toggle", text="Show Rotation Assist Icon",
              tooltip="Show Blizzard's current recommendation in a separate icon. Requires Assisted Highlight to be enabled in Blizzard's options. Press the spell's normal keybind; this display never casts spells. Blizzard supplies one recommendation, not a queue of future casts.",
              -- Locked only while off: an icon left on after the highlight was
              -- switched off can always be turned off here.
              disabled=function() return not ns.RotationAssistAvailable() and Settings().enabled ~= true end,
              disabledTooltip="This option requires Blizzard's Assisted Highlight to be enabled",
              rawTooltip=true,
              getValue=function() return Settings().enabled == true end,
              setValue=function(v)
                  Settings().enabled = v
                  Apply()
              end },
            { type="slider", text="Icon Size", min=16, max=128, step=1,
              disabled=IconOff, disabledTooltip=IconLockTip,
              getValue=function() return Settings().iconSize or 48 end,
              setValue=function(v) Settings().iconSize = v; ns.RefreshRotationAssistIcon() end }
        );  y = y - h
        local kbRow
        kbRow, h = W:DualRow(parent, y,
            { type="toggle", text="Only in Combat",
              tooltip="Hide outside combat. Unlock Mode shows a placeholder when no recommendation is available.",
              disabled=IconOff, disabledTooltip=IconLockTip,
              getValue=function() return Settings().onlyInCombat == true end,
              setValue=function(v) Settings().onlyInCombat = v; Apply() end },
            { type="toggle", text="Show Keybind",
              tooltip="Use the CDM keybind mapping. Configure the font, outline, position, background and border with the cog.",
              disabled=IconOff, disabledTooltip=IconLockTip,
              getValue=function() return Settings().showKeybind == true end,
              setValue=function(v) Settings().showKeybind = v; Apply() end }
        );  y = y - h
        BuildKeybindStyleControls(kbRow, Settings, Apply, IconLockTip)
        _, h = W:DualRow(parent, y,
            { type="slider", text="X Offset", min=-2000, max=2000, step=1,
              tooltip="Horizontal screen offset. You can also drag the Rotation Assist Icon in Unlock Mode.",
              disabled=IconOff, disabledTooltip=IconLockTip,
              getValue=function() return EllesmereUI.PP.ToPixels(Position().x or 0) end,
              setValue=function(v) SetOffset("x", v) end },
            { type="slider", text="Y Offset", min=-1200, max=1200, step=1,
              tooltip="Vertical screen offset. You can also drag the Rotation Assist Icon in Unlock Mode.",
              disabled=IconOff, disabledTooltip=IconLockTip,
              getValue=function() return EllesmereUI.PP.ToPixels(Position().y or 0) end,
              setValue=function(v) SetOffset("y", v) end }
        );  y = y - h
        _, h = W:DualRow(parent, y,
            { type="toggle", text="Show GCD",
              tooltip="Show the global cooldown as a swipe over the recommended ability. The swipe shows when the GCD ends; casting, channeling and ability requirements can still delay your next action.",
              disabled=IconOff, disabledTooltip=IconLockTip,
              getValue=function() return Settings().showGCD == true end,
              setValue=function(v) Settings().showGCD = v; Apply() end },
            EllesmereUI.BlankRowCfg()
        );  y = y - h
        return math.abs(y)
    end

    ---------------------------------------------------------------------------
    --  Unlock Mode page  (opens EllesmereUI Unlock Mode overlay)
    ---------------------------------------------------------------------------
    local function BuildUnlockPage(pageName, parent, yOffset)
        C_Timer.After(0, function()
            if EllesmereUI and EllesmereUI._openUnlockMode then
                EllesmereUI._openUnlockMode()
            end
        end)
        return 0
    end

    ---------------------------------------------------------------------------
    --  One-time CDM button settings tip (shown on first CDM Bars page open)
    ---------------------------------------------------------------------------
    local _cdmButtonTip
    local function ShowCDMButtonTip()
        if EllesmereUIDB and EllesmereUIDB.cdmButtonTipSeen then return end
        local preview = EllesmereUI._contentHeaderPreview
        if not preview then return end
        if _cdmButtonTip and _cdmButtonTip:IsShown() then return end

        if not _cdmButtonTip then
            local TIP_W, TIP_H = 360, 105
            local EG = EllesmereUI.ELLESMERE_GREEN or { r = 0.05, g = 0.82, b = 0.62 }
            local ar, ag, ab = EG.r, EG.g, EG.b
            local PP = EllesmereUI.PanelPP or EllesmereUI.PP

            local tip = CreateFrame("Frame", nil, EllesmereUI._panelBody)
            tip:SetFrameStrata("FULLSCREEN_DIALOG")
            tip:SetFrameLevel(200)
            if PP and PP.Size then PP.Size(tip, TIP_W, TIP_H) else tip:SetSize(TIP_W, TIP_H) end
            tip:EnableMouse(true)

            -- Background
            local bg = tip:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetColorTexture(0.06, 0.08, 0.10, 1)

            -- Border
            EllesmereUI.MakeBorder(tip, ar, ag, ab, 0.25, PP)

            -- Arrow pointing up
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
            arrowFill:SetColorTexture(0.06, 0.08, 0.10, 1)
            arrowFill:SetRotation(math.rad(45))
            if arrowFill.SetSnapToPixelGrid then arrowFill:SetSnapToPixelGrid(false); arrowFill:SetTexelSnappingBias(0) end

            -- Message
            local FONT_PATH2 = (EllesmereUI.GetFontPath("cdm"))
                or "Interface\\AddOns\\EllesmereUI\\media\\fonts\\Expressway.TTF"
            local msg = tip:CreateFontString(nil, "OVERLAY")
            msg:SetFont(FONT_PATH2, 12, "")
            msg:SetTextColor(1, 1, 1, 0.85)
            msg:SetPoint("TOP", tip, "TOP", 0, -15)
            msg:SetWidth(TIP_W - 30)
            msg:SetJustifyH("CENTER")
            msg:SetSpacing(4)
            msg:SetText(EllesmereUI.L("CDM buttons can have their glow and active states\nset per icon or synced to the bar. Click a button\nto show its settings."))

            -- Okay button
            local okBtn = CreateFrame("Button", nil, tip)
            okBtn:SetSize(86, 26)
            okBtn:SetPoint("BOTTOM", tip, "BOTTOM", 0, 11)
            EllesmereUI.MakeStyledButton(okBtn, "Okay", 11,
                EllesmereUI.RB_COLOURS, function()
                    tip:Hide()
                    if EllesmereUIDB then EllesmereUIDB.cdmButtonTipSeen = true end
                end)

            _cdmButtonTip = tip
        end

        -- The preview is rebuilt with its page, so anchor on every show.
        _cdmButtonTip:ClearAllPoints()
        _cdmButtonTip:SetPoint("TOP", preview, "BOTTOM", 0, -12)
        _cdmButtonTip:Show()
    end
    -- Hidden whenever the player leaves the CDM Bars page (page switch, module
    -- switch, panel close); it returns on that page until dismissed with Okay.
    local function HideCDMButtonTip()
        if _cdmButtonTip then _cdmButtonTip:Hide() end
    end
    -- Shown a beat after the Bars page renders; the player may already have
    -- moved on by then, so the timer re-checks the page before showing.
    local function QueueCDMButtonTip()
        C_Timer.After(0.1, function()
            if ns._cdmBarsPageOpen then ShowCDMButtonTip() end
        end)
    end

    ---------------------------------------------------------------------------
    --  Buff bar overlay: REMOVED (no locator ghost over the live buff bar
    --  while options are open). ShowBuffBarOverlay is a no-op stub so the
    --  existing call sites (page open/close) need no changes.
    ---------------------------------------------------------------------------
    local _buffBarOverlay
    local function ShowBuffBarOverlay()
    end

    local function HideBuffBarOverlay()
        if _buffBarOverlay then _buffBarOverlay:Hide() end
    end
    ns.ShowBuffBarOverlay = ShowBuffBarOverlay
    ns.HideBuffBarOverlay = HideBuffBarOverlay

    -- Hook: show tip when CDM Bars page first renders with a preview visible
    local _cdmButtonTipQueued = false
    EllesmereUI:RegisterOnHide(function()
        HideCDMButtonTip()
        -- Hide overlay and custom aura preview when panel closes
        HideBuffBarOverlay()
        ns._cdmBarsPageOpen = false
        if ns.UpdateCustomBuffBars then ns.UpdateCustomBuffBars() end
    end)


    ---------------------------------------------------------------------------
    --  Register the module
    ---------------------------------------------------------------------------
    EllesmereUI:RegisterModule("EllesmereUICooldownManager", {
        title       = "Cooldown Manager",
        description = "CDM bar customization, action bar glows, and buff bars.",
        -- Rotation Assist Icon: the far-right tab; none on Forever (no Assisted
        -- Highlight there).
        pages       = EllesmereUI.IS_FOREVER and { PAGE_CDM_BARS, PAGE_BAR_GLOWS, PAGE_BUFF_BARS }
                      or { PAGE_CDM_BARS, PAGE_BAR_GLOWS, PAGE_BUFF_BARS, PAGE_ROTATION_ICON },
        disabledPages = {},
        disabledPageTooltips = {},
        buildPage   = function(pageName, parent, yOffset)
            -- ns._tbbPlaceholderMode / ns._cdmBarsPageOpen reflect the page the player
            -- is REALLY on, not the pageName being built. A hidden search pre-build
            -- cycles pageName through all three pages, so the "switched away" cleanup
            -- below (buff-bar injection/removal, placeholder toggling, settings tip)
            -- would fire against what the player is actually seeing -- during
            -- pre-build, only build content. PAGE_BUFF_BARS is skipped entirely: its
            -- builder unconditionally calls UpdateTBBPlaceholder() at its tail, which
            -- grabs the REAL tracked-buff-bar frames via ns.GetTBBFrame(i) (not scoped
            -- to `parent`) and forces them :Show() with unlock placeholders -- building
            -- it here would pop the live buff bars onto the screen. It's indexed
            -- normally the first time the player visits it live.
            if EllesmereUI._prebuilding then
                if pageName == PAGE_CDM_BARS then
                    return BuildCDMBarsPage(pageName, parent, yOffset)
                elseif pageName == PAGE_ROTATION_ICON then
                    return BuildRotationAssistIconPage(pageName, parent, yOffset)
                elseif pageName == PAGE_BAR_GLOWS then
                    return BuildBarGlowsPage(pageName, parent, yOffset)
                end
                return
            end
            -- Clear TBB placeholders when switching to any non-Tracking Bars page
            if pageName ~= PAGE_BUFF_BARS and ns._tbbPlaceholderMode then
                ns._tbbPlaceholderMode = false
                if ns.HideTBBPlaceholders then ns.HideTBBPlaceholders() end
            end
            -- Manage custom aura bar preview: flag-based, not GetActivePage
            if pageName ~= PAGE_CDM_BARS and ns._cdmBarsPageOpen then
                ns._cdmBarsPageOpen = false
                if ns.UpdateCustomBuffBars then ns.UpdateCustomBuffBars() end
                -- Page closed: reanchor so buff-bar injected custom/preset buffs
                -- that were shown for configuration (cdmPageOpen) hide unless active.
                if ns.QueueReanchor then ns.QueueReanchor() end
                HideBuffBarOverlay()
                HideCDMButtonTip()
            end
            if pageName == PAGE_CDM_BARS then
                ns._cdmBarsPageOpen = true
                local h2 = BuildCDMBarsPage(pageName, parent, yOffset)
                if ns.UpdateCustomBuffBars then ns.UpdateCustomBuffBars() end
                ShowBuffBarOverlay()
                -- Show one-time button settings tip after preview renders
                QueueCDMButtonTip()
                return h2
            elseif pageName == PAGE_ROTATION_ICON then
                return BuildRotationAssistIconPage(pageName, parent, yOffset)
            elseif pageName == PAGE_BAR_GLOWS then
                return BuildBarGlowsPage(pageName, parent, yOffset)
            elseif pageName == PAGE_BUFF_BARS then
                return BuildBuffBarsPage(pageName, parent, yOffset)
            end
        end,
        getHeaderBuilder = function(pageName)
            if pageName == PAGE_CDM_BARS then
                return optState._cdmHeaderBuilder
            elseif pageName == PAGE_BAR_GLOWS then
                return _glowHeaderBuilder
            end
            -- Tracking Bars has no content header (popout preview instead)
            return nil
        end,
        -- CDM Bars content is gated on the selected bar (e.g. FocusKick-only
        -- rows render only while barData.key == "focuskick"), and the default
        -- selection is almost never FocusKick -- without this, a hidden pre-build only
        -- ever sees one bar's options and every other bar's unique settings stay
        -- unsearchable until the player visits them live. Build once per distinct bar
        -- SHAPE (cooldowns/utility/buffs/ custom_buff/focuskick), not per bar instance:
        -- several custom bars of one shape expose identical options, so indexing more
        -- than one of a shape would be a wasted rebuild.
        getPrebuildVariants = function(pageName)
            if pageName ~= PAGE_CDM_BARS then return nil end
            local p = DB()
            local bars = p and p.cdmBars and p.cdmBars.bars
            if not bars or #bars == 0 then return nil end
            local seenShapes = {}
            local keys = {}
            for _, b in ipairs(bars) do
                local shape = (b.key == "focuskick") and "focuskick" or b.barType
                if shape and not seenShapes[shape] then
                    seenShapes[shape] = true
                    keys[#keys + 1] = b.key
                end
            end
            if optState.selectedCDMBarIndex < 1 then optState.selectedCDMBarIndex = 1 end
            if optState.selectedCDMBarIndex > #bars then optState.selectedCDMBarIndex = #bars end
            local currentBar = bars[optState.selectedCDMBarIndex]
            return {
                setter = EllesmereUI._setCDMBar,
                keys = keys,
                currentKey = currentBar and currentBar.key,
            }
        end,
        onPageCacheRestore = function(pageName)
            -- Same flag management as buildPage
            if pageName ~= PAGE_BUFF_BARS and ns._tbbPlaceholderMode then
                ns._tbbPlaceholderMode = false
                if ns.HideTBBPlaceholders then ns.HideTBBPlaceholders() end
            end
            if pageName ~= PAGE_CDM_BARS and ns._cdmBarsPageOpen then
                ns._cdmBarsPageOpen = false
                if ns.UpdateCustomBuffBars then ns.UpdateCustomBuffBars() end
                -- Page closed: reanchor so buff-bar injected custom/preset buffs
                -- that were shown for configuration (cdmPageOpen) hide unless active.
                if ns.QueueReanchor then ns.QueueReanchor() end
                HideBuffBarOverlay()
                HideCDMButtonTip()
            end
            if pageName == PAGE_BUFF_BARS then
                if ns.ShowTBBPlaceholders then ns.ShowTBBPlaceholders() end
                RefreshTBBPopout()
            end
            if pageName == PAGE_CDM_BARS then
                ns._cdmBarsPageOpen = true
                if ns.UpdateCustomBuffBars then ns.UpdateCustomBuffBars() end
                ShowBuffBarOverlay()
                -- The undismissed tip returns with the Bars page
                QueueCDMButtonTip()
                -- Re-sync _cdmPreview after cache restore and refresh the preview
                if not optState._cdmPreview and EllesmereUI._contentHeaderPreview then
                    optState._cdmPreview = EllesmereUI._contentHeaderPreview
                end
                if optState._cdmPreview and optState._cdmPreview.Update then
                    optState._cdmPreview:Update()
                end
            end
        end,
        -- Leaving the module: the button settings tip is a child of the main
        -- frame, so nothing else would take it down with the page.
        onModuleLeave = function()
            HideCDMButtonTip()
        end,
        onReset = function()
            if _G._ECME_AceDB then
                _G._ECME_AceDB:ResetProfile()
                -- Clear the per-install capture flag so the snapshot re-runs
                -- after reload and picks up Blizzard's current CDM layout.
                if _G._ECME_AceDB.sv then
                    _G._ECME_AceDB.sv._capturedOnce_CDM = nil
                end
            end
            -- Learned variant->base pairs are game data rather than settings,
            -- but they sit on the SV root where StripDefaults and the profile
            -- system never reach, so a pair learned wrong would survive every
            -- other reset. This is the only path that clears them.
            if ns.ResetVariantBaseStore then ns.ResetVariantBaseStore() end
            -- Wipe spell assignments for the current spec so the init snapshot re-populates
            -- from Blizzard's CDM. Spell data lives in EllesmereUIDB (per-profile store), not the
            -- AceDB profile, so ResetProfile doesn't touch it. Only clear the ACTIVE profile's current spec to preserve other specs and other profiles.
            if ns and ns.GetActiveSpecProfiles then
                local sp = ns.GetActiveSpecProfiles()
                local specKey = ns.GetActiveSpecKey and ns.GetActiveSpecKey()
                if sp and specKey and specKey ~= "0" then
                    sp[specKey] = nil
                    -- WoW Forever: the class reads one of several keys (its
                    -- Forever spec key, then its retail specs); clear them all
                    -- so the reload starts the class fresh.
                    if EllesmereUI.IS_FOREVER then
                        local token = select(2, UnitClass("player"))
                        local ids = EllesmereUI.ForeverClassSpecIDs(token)
                        for i = 1, (ids and #ids or 0) do sp[tostring(ids[i])] = nil end
                        local lk = EllesmereUI.FOREVER_CLASS_SPEC[token]
                        if lk then sp[tostring(lk)] = nil end
                    end
                end
            end
            -- No reload here: the footer Reset popup (reload = true) reloads after this returns.
        end,
    })

    SLASH_ECMEOPT1 = "/ecmeopt"
    SlashCmdList.ECMEOPT = function()
        if InCombatLockdown and InCombatLockdown() then return end
        EllesmereUI:ShowModule("EllesmereUICooldownManager")
    end

end)
-- LoadOnDemand: this addon loads after PLAYER_LOGIN, so the event above will never fire; run the init now.
if IsLoggedIn() then initFrame:GetScript("OnEvent")(initFrame) end
