if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EUI_Nameplates_Options.lua: registers the Nameplates module with EllesmereUI.
--  All get/set calls go to ns.db.profile (centralized store); does NOT touch nameplate rendering logic.
-------------------------------------------------------------------------------
local ADDON_NAME = "EllesmereUINameplates"
local ns = EllesmereUI._ModuleNS[ADDON_NAME]  -- module namespace (published by the module at its load)
if not ns then return end  -- module disabled: no options page

-- Body-text preview flag, already slug-gated at the source (GetFontOutlineFlag).
local function GetNPOptOutline() return EllesmereUI.GetFontOutlineFlag("nameplates") end

-- Rows the Blizzard kit replaces but the classic plate leaves to the user
-- (bar background, cast bar texture, cast background and colours, the
-- border wrap): gated only while Blizzard Style renders, live under Classic
-- WoW UI. ns fields so the page builders gain no upvalue; the gate returns
-- cfg for inline use like BlizzStyle.Gate.
function ns.NP_BlizzOnly()
    return EllesmereUI.BlizzStyle.Active("nameplates") == "blizzard"
end
function ns.NP_BlizzOnlyGate(cfg)
    if ns.NP_BlizzOnly() then return EllesmereUI.BlizzStyle.Gate("nameplates", cfg) end
    return cfg
end

-------------------------------------------------------------------------------
--  Page / section names
-------------------------------------------------------------------------------
local PAGE_GENERAL   = "General"
local PAGE_DISPLAY   = "Display"
local PAGE_COLORS    = "Colors"

local SECTION_FRIENDLY  = "OTHER NAMEPLATES"
local SECTION_ENEMY_NP  = "NAMEPLATE SPACING"
local SECTION_MISC      = "EXTRAS"
local SECTION_AURA      = "EXTRA AURA OPTIONS"

local SECTION_ENEMY     = "ENEMY COLORS"
local SECTION_CASTBAR   = "CAST COLORS AND EFFECTS"
local SECTION_THREAT    = "THREAT COLORS"
local SECTION_OTHER     = "OTHER COLORS"

-- Threat % Position dropdown (WoW Forever only, so nil on retail).
local THREAT_PCT_POSITIONS, THREAT_PCT_POSITION_ORDER
if EllesmereUI.IS_FOREVER then
    THREAT_PCT_POSITIONS = { RIGHT = "Inside Right", LEFT = "Inside Left", CENTER = "Inside Center" }
    THREAT_PCT_POSITION_ORDER = { "RIGHT", "LEFT", "CENTER" }
end

-- Wait for EllesmereUI to exist
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_LOGIN")

    if not EllesmereUI or not EllesmereUI.RegisterModule then return end
    local PP = EllesmereUI.PanelPP

    ---------------------------------------------------------------------------
    --  Local references from the addon namespace
    ---------------------------------------------------------------------------
    local defaults             = ns.defaults
    local SetFSFont            = ns.SetFSFont
    local GetEnemyNameTextSize = ns.GetEnemyNameTextSize
    local GetDebuffTextColor   = ns.GetDebuffTextColor
    local BAR_W                = ns.BAR_W
    local plates               = ns.plates
    local GetNPOutline         = ns.GetNPOutline or function() return "OUTLINE, SLUG" end
    local GetNPUseShadow       = ns.GetNPUseShadow or function() return false end

    local pcall = pcall
    local pairs = pairs

    -- Preview font setter: mirrors SetFSFont shadow logic for direct SetFont calls
    local function SetPVFont(fs, fontPath, size, flags)
        EllesmereUI.ApplyModuleFont(fs, fontPath, size, "nameplates", flags)
    end
    local floor = math.floor
    local NAME_RAID_MARKER_GAP = 3

    ---------------------------------------------------------------------------
    --  DB helper reads from the centralized profile via ns.db
    ---------------------------------------------------------------------------
    local function DB()
        return ns.db and ns.db.profile
    end

    local function DBVal(key)
        local db = DB()
        if db and db[key] ~= nil then return db[key] end
        return defaults[key]
    end

    local function DBColor(key)
        local db = DB()
        local c = (db and db[key]) or defaults[key]
        return c.r, c.g, c.b
    end

    local FOCUS_LETTER_ANCHORS = {
        CENTER = "Center",
        LEFT = "Left",
        RIGHT = "Right",
        TOP = "Top",
        BOTTOM = "Bottom",
        TOPLEFT = "Top Left",
        TOPRIGHT = "Top Right",
        BOTTOMLEFT = "Bottom Left",
        BOTTOMRIGHT = "Bottom Right",
    }
    local FOCUS_LETTER_ANCHOR_ORDER = {
        "CENTER", "LEFT", "RIGHT", "TOP", "BOTTOM",
        "TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT",
    }
    local function GetFocusLetterAnchor()
        local anchor = DBVal("focusLetterAnchor") or defaults.focusLetterAnchor
        return FOCUS_LETTER_ANCHORS[anchor] and anchor or defaults.focusLetterAnchor
    end

    ---------------------------------------------------------------------------
    --  Refresh helpers
    ---------------------------------------------------------------------------
    local function RefreshAllPlates()
        for _, plate in pairs(plates) do
            plate:UpdateHealth()
        end
    end

    local function RefreshAllAuras()
        if ns.NPC_ReloadAll then ns.NPC_ReloadAll() end
    end

    ---------------------------------------------------------------------------
    --  Health bar texture dropdown values (built from ns tables)
    ---------------------------------------------------------------------------
    -- Append SharedMedia textures to the runtime ns tables first so both the dropdown AND the live nameplate rendering can resolve SM keys.
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
        for _, key in ipairs(texOrder2) do
            if key ~= "---" then
                hbtValues[key] = texNames[key] or key
            end
            hbtOrder[#hbtOrder + 1] = key
        end
        local texLookup = ns.healthBarTextures or {}
        hbtValues._menuOpts = {
            itemHeight = 28,
            background = function(key)
                return texLookup[key]
            end,
        }
    end

    ---------------------------------------------------------------------------
    --  Live Preview System: cosmetic-only enemy nameplate preview built once
    --  and updated via :Update() (no rebuild/GC pressure), reading live DB settings for colors, sizes, font, etc.
    ---------------------------------------------------------------------------
    -- Mutable state shared with the page builders under Nameplates_Options\.
    -- A table instead of locals so every file reads and writes the live value.
    -- Nil until set: activePreview (preview frame), _previewHintFS (hint
    -- FontString), RefreshCoreEyes (Display page), _colorPreviewRefreshAll
    -- (Colors page, refreshes all color preview bars on cache restore).
    local optState = {}
    local _displayHeaderBuilder   -- stored for page cache re-use
    local _headerBaseH = 0               -- header height WITHOUT hint (for cache restore)

    local function IsPreviewHintDismissed()
        return EllesmereUIDB and EllesmereUIDB.previewHintDismissed
    end

    -- Raid marker hidden by default, toggled via eye icon; optState fields so both the preview and the Display page can access them.
    optState.showRaidMarkerPreview = false
    optState.showClassificationPreview = false
    optState.showTargetGlowPreview = false
    optState.showAbsorbPreview = false

    -- Transient flags: force-show indicators during slider drag
    optState._sliderDragShowRaidMarker = false
    optState._sliderDragShowClassification = false

    -- Random preview values regenerate only on tab switch, not on profile changes or setting tweaks (those trigger fast-path RefreshPage rebuilds).
    -- optState._previewHpPct, _previewCastFill, _previewCastIconIdx: set below.
    local displayCastIcons = { 136197, 236802, 135808, 136116, 135735, 136048, 135812, 136075 }
    local function RandomizePreviewValues()
        optState._previewHpPct = math.floor(60 + math.random() * 15)
        optState._previewCastFill = 0.40 + math.random() * 0.20
        optState._previewCastIconIdx = math.random(#displayCastIcons)
    end

    local function UpdatePreview()
        if optState.activePreview and optState.activePreview.Update then
            optState.activePreview:Update()
        end
    end

    -- Refresh the preview every time the panel is reopened
    EllesmereUI:RegisterOnShow(UpdatePreview)

    ---------------------------------------------------------------------------
    --  Glow sites: the Dispel and Important Cast glows as shared glow
    --  descriptors, used by the page rows and the Global Settings Glows page.
    ---------------------------------------------------------------------------
    local npDispelGlowDesc, npImpCastGlowDesc
    do
        local GO = EllesmereUI.GlowOptions
        local function RefreshDispel() RefreshAllAuras(); UpdatePreview() end
        -- Engine aura buttons (no Auto-Cast/Shape); an unset color is the
        -- suite default (gold).
        -- Blizzard Border: Blizzard's static stealable art, outside the view.
        local BLIZZ_BORDER = EllesmereUI.Glows.STEALABLE_BORDER
        npDispelGlowDesc = {
            view = ns.NP_GLOW_VIEW, host = "engine",
            extras = { { value = BLIZZ_BORDER, label = "Blizzard Border", style = BLIZZ_BORDER } },
            caps = { mode = true, params = true, bg = true },
            defaultColor = EllesmereUI.Glows.DEFAULT_COLOR,
            isOff = function() return DBVal("dispelGlow") ~= true end,
            -- Color by Type replaces the swatch color on every group.
            colorDisabled = function() return DBVal("dispelGlowUseTypeColor") == true end,
            colorDisabledTooltip = "Color by Type (Magic/Enrage)",
            onChange = RefreshDispel,
            get = function(f)
                local d = DB()
                if f == "style" then return ns.GetDispelGlowStyle and ns.GetDispelGlowStyle() or 2
                elseif f == "mode" then return d.dispelGlowColorMode or (d.dispelGlowColor and "custom" or "default")
                end
                return EllesmereUI.GlowOptions.FlatGet(d, "dispelGlow", f)
            end,
            set = function(f, a, b2, c2)
                local d = DB()
                if f == "style" then
                    if a == 0 then d.dispelGlow = false else d.dispelGlow = true; d.dispelGlowStyle = a end
                elseif f == "mode" then d.dispelGlowColorMode = a
                else EllesmereUI.GlowOptions.FlatSet(d, "dispelGlow", f, a, b2, c2)
                end
            end,
            -- off->on pays the per-plate aura-watcher cost -- prompt like other performance-priced enables; already-on style switches never prompt.
            confirm = function(v, commit)
                if v ~= 0 and DBVal("dispelGlow") ~= true then
                    EllesmereUI:ShowConfirmPopup({
                        title       = "Dispel Glow",
                        message     = "Dispel Glow may cause a slight loss in performance efficiency. Do you want to enable it?",
                        confirmText = "Enable",
                        cancelText  = "Cancel",
                        onConfirm   = commit,
                        onCancel    = function()
                            C_Timer.After(0, function() EllesmereUI:RefreshPage() end)
                        end,
                    })
                    return
                end
                commit()
            end,
            -- Magic buffs and enrages are separate groups in the buff row, so the
            -- color can follow the type; it overrides the color above per group.
            cogRows = {
                { type="toggle", label="Color by Type (Magic/Enrage)",
                  get=function() return DBVal("dispelGlowUseTypeColor") or false end,
                  set=function(v)
                      DB().dispelGlowUseTypeColor = v
                      RefreshDispel()
                      EllesmereUI:RefreshPage()
                  end },
            },
        }
        -- The cast bar is a bar host (no Shape).
        npImpCastGlowDesc = {
            view = ns.NP_GLOW_VIEW, host = "bar",
            caps = { mode = true, params = true, bg = true },
            defaultColor = { r = 1, g = 0.2, b = 0.2 },
            isOff = function()
                local d = DB()
                local on = d and d.importantCastGlow
                if on == nil then on = defaults.importantCastGlow end
                return not on
            end,
            onChange = RefreshAllPlates,
            get = function(f)
                local d = DB()
                if f == "style" then return d.importantCastGlowStyle or defaults.importantCastGlowStyle or 1
                elseif f == "mode" then return d.importantCastGlowColorMode or "custom"
                end
                return EllesmereUI.GlowOptions.FlatGet(d, "importantCastGlow", f, defaults)
            end,
            set = function(f, a, b2, c2)
                local d = DB()
                if f == "style" then
                    if a == 0 then d.importantCastGlow = false
                    else d.importantCastGlow = true; d.importantCastGlowStyle = a end
                elseif f == "mode" then d.importantCastGlowColorMode = a
                else EllesmereUI.GlowOptions.FlatSet(d, "importantCastGlow", f, a, b2, c2)
                end
            end,
        }
        GO.RegisterSite({ id = "np_dispel", label = "Dispel Glow", group = "module",
            module = "EllesmereUINameplates", page = PAGE_GENERAL, section = SECTION_AURA,
            highlight = "Dispel Glow Style", desc = npDispelGlowDesc })
        GO.RegisterSite({ id = "np_importantcast", label = "Important Cast Glow", group = "module",
            module = "EllesmereUINameplates", page = PAGE_DISPLAY, section = SECTION_CASTBAR,
            highlight = "Important Cast Glow", desc = npImpCastGlowDesc })
    end

    ---------------------------------------------------------------------------
    --  Display page  (preview in content header + settings in scroll area)
    ---------------------------------------------------------------------------
    local LazyColorPreviewBar -- forward declaration; defined after MakeColorPreviewBar

    local function BuildDisplayPage(pageName, parent, yOffset)
        local W = EllesmereUI.Widgets
        local y = yOffset
        local _, h

        -- Set content header with preview centered above nameplate preview
        _displayHeaderBuilder = function(headerParent, headerW)

            local PRESET_HEADER_H = 0
            local PREVIEW_TOP_PAD = 10
            local PREVIEW_BOTTOM_PAD = 5
            local previewH = BuildNameplatePreview(headerParent, headerW)
            -- Position the preview at the top of the header area. pf's SetScale matches the UIParent/panel ratio, so SetPoint offsets (in that scaled space) must divide by the same ratio for the correct visual offset.
            if optState.activePreview then
                optState.activePreview:ClearAllPoints()
                local correction = UIParent:GetEffectiveScale() / headerParent:GetEffectiveScale()
                optState.activePreview:SetPoint("TOP", headerParent, "TOP", 0, -(PRESET_HEADER_H + PREVIEW_TOP_PAD) / correction)
                optState.activePreview._headerExtra = PRESET_HEADER_H + PREVIEW_TOP_PAD + PREVIEW_BOTTOM_PAD
            end

            -- "Click elements" hint: parented to activePreview (not headerParent directly, which orphaned it via ClearContentHeaderInner on page switch) so the FontString travels through the content-header cache; if orphaned (parent gone), nil it to recreate.
            if optState._previewHintFS and not optState._previewHintFS:GetParent() then
                optState._previewHintFS = nil
            end
            local hintShown = not IsPreviewHintDismissed()
            if hintShown then
                if not optState._previewHintFS then
                    optState._previewHintFS = EllesmereUI.MakeFont(optState.activePreview or headerParent, 11, nil, 1, 1, 1)
                    optState._previewHintFS:SetAlpha(0.45)
                    optState._previewHintFS:SetText(EllesmereUI.L("Click elements to scroll to and highlight their options"))
                end
                optState._previewHintFS:SetParent(optState.activePreview or headerParent)
                optState._previewHintFS:ClearAllPoints()
                optState._previewHintFS:SetPoint("BOTTOM", headerParent, "BOTTOM", 0, 17)
                optState._previewHintFS:SetAlpha(0.45)
                optState._previewHintFS:Show()
            elseif optState._previewHintFS then
                optState._previewHintFS:Hide()
            end

            _headerBaseH = previewH + PRESET_HEADER_H + PREVIEW_TOP_PAD + PREVIEW_BOTTOM_PAD
            return _headerBaseH + (hintShown and 29 or 0)
        end
        EllesmereUI:SetContentHeader(_displayHeaderBuilder)

        -- Enable per-row center divider for the dual-column layout
        parent._showRowDivider = true

        -----------------------------------------------------------------------
        --  AURA POSITIONS
        -----------------------------------------------------------------------
        local slotKeys = { "debuffSlot", "buffSlot", "ccSlot", "raidMarkerPos", "classificationSlot", "factionSlot" }

        -- Inverted mapping: position element (for CORE POSITIONS dropdowns)
        local elementToKey = {
            debuffs        = "debuffSlot",
            buffs          = "buffSlot",
            ccs            = "ccSlot",
            raidmarker     = "raidMarkerPos",
            classification = "classificationSlot",
            faction        = "factionSlot",
        }
        local keyToElement = {}
        for elem, key in pairs(elementToKey) do keyToElement[key] = elem end

        local function GetElementAtPosition(pos)
            local db = DB()
            for _, key in ipairs(slotKeys) do
                -- A leftover Faction slot is ignored while Rare/Quest + Faction is on
                -- (the badge rides the classification slot), so it is not shown here either.
                local ignored = key == "factionSlot" and db.classificationIncludeFaction
                if not ignored and (db[key] or defaults[key]) == pos then
                    -- "Debuffs + CC" is a VIEW over the debuff slot: same position key + the debuffIncludeCC flag.
                    if key == "debuffSlot" and db.debuffIncludeCC then
                        return "debuffsccs"
                    end
                    -- "Rare/Quest + Faction" is a VIEW over the classification slot + classificationIncludeFaction.
                    if key == "classificationSlot" and db.classificationIncludeFaction then
                        return "classfaction"
                    end
                    return keyToElement[key]
                end
            end
            return "none"
        end

        local function SetElementAtPosition(pos, element)
            if element == "none" then
                -- Clear: find whatever element is at this position and move it to "none"
                local db = DB()
                for _, key in ipairs(slotKeys) do
                    if (db[key] or defaults[key]) == pos then
                        db[key] = "none"
                    end
                end
                return
            end
            -- "Debuffs + CC" rides the debuff slot key; the two entries differ only by debuffIncludeCC.
            if element == "debuffsccs" then
                DB().debuffIncludeCC = true
                element = "debuffs"
            elseif element == "debuffs" then
                DB().debuffIncludeCC = false
            end
            -- "Rare/Quest + Faction" rides the classification slot key and takes the
            -- faction badge with it (its own Faction slot is cleared); picking either
            -- one alone splits them again.
            if element == "classfaction" then
                DB().classificationIncludeFaction = true
                DB().factionSlot = "none"
                element = "classification"
            elseif element == "classification" or element == "faction" then
                DB().classificationIncludeFaction = false
            end
            local key = elementToKey[element]
            if not key then return end
            local db = DB()
            -- Clear old holder of this position (set to "none"), no swapping
            for _, otherKey in ipairs(slotKeys) do
                if otherKey ~= key and (db[otherKey] or defaults[otherKey]) == pos then
                    db[otherKey] = "none"
                end
            end
            db[key] = pos
        end

        local slotValues = {
            ["top"]      = "Top",
            ["left"]     = "Left",
            ["right"]    = "Right",
            ["topleft"]  = "Top Left",
            ["topright"] = "Top Right",
            ["bottom"]   = "Bottom",
            ["none"]     = "None",
        }
        local slotOrder = { "top", "left", "right", "topleft", "topright", "bottom", "none" }
        local function RefreshAllSlots()
            RefreshAllAuras()
            for _, plate in pairs(plates) do
                local ds, bs, cs = ns.GetAuraSlots()
                if bs ~= "none" then
                    local buffSz = ns.GetBuffIconSize()
                    local buffH = ns.GetAuraCropHeight(ns.GetAuraCrop("buffs"), buffSz)
                    local bxOff, byOff = ns.GetSlotOffsets(bs)
                    ns.PositionAuraSlot(plate.buffs, 4, bs, plate, buffSz, buffH, ns.GetAuraSpacing("buffs"), bxOff, byOff)
                else
                    for i = 1, 4 do plate.buffs[i]:Hide() end
                end
                if cs ~= "none" then
                    local ccSz = ns.GetCCIconSize()
                    local ccH = ns.GetAuraCropHeight(ns.GetAuraCrop("ccs"), ccSz)
                    local cxOff, cyOff = ns.GetSlotOffsets(cs)
                    ns.PositionAuraSlot(plate.cc, 2, cs, plate, ccSz, ccH, ns.GetAuraSpacing("ccs"), cxOff, cyOff)
                else
                    for i = 1, 2 do plate.cc[i]:Hide() end
                end
                if ds == "none" then
                    for i = 1, 4 do plate.debuffs[i]:Hide() end
                end
                plate:UpdateRaidIcon()
                plate:UpdateClassification()
                -- Rare/Quest + Faction: the classification pass already ran it.
                if not DBVal("classificationIncludeFaction") then plate:UpdateFaction() end
                if ns.ApplySlotStrata then ns.ApplySlotStrata(plate) end
            end
            ns.NP_RefreshFriendlyFaction()
            UpdatePreview()
            EllesmereUI:RefreshPage()
        end

        -----------------------------------------------------------------------
        --  Helpers for position-swapping dropdowns
        -----------------------------------------------------------------------

        -- Exclusive slot assignment for the new Core Text Positions system.
        local textSlotKeys = ns.textSlotKeys
        local function SetTextElementAtSlot(slotKey, element)
            local db = DB()
            if element ~= "none" then
                for _, key in ipairs(textSlotKeys) do
                    if key ~= slotKey then
                        local cur = db[key] or defaults[key]
                        -- Name-family variants (name and the level+name combos) all render through the plate's single name FontString, so slotting any of
                        -- them evicts whichever family member occupies another slot -- same rule as an exact match. STANDALONE level has its own FontString and only exact-match evicts, so name + level can coexist.
                        if cur == element
                           or (ns.IsNameElement(element) and ns.IsNameElement(cur)) then
                            db[key] = "none"
                        end
                    end
                end
            end
            db[slotKey] = element
        end

        local timerPosValues = {
            ["topleft"]  = "Top Left",
            ["center"]   = "Center",
            ["topright"]  = "Top Right",
            ["bottomleft"]  = "Bottom Left",
            ["bottomright"] = "Bottom Right",
            ["none"]      = "None",
        }
        local timerPosOrder = { "none", "topleft", "topright", "bottomleft", "bottomright", "center" }

        local function AuraDurationVal(kind, suffix)
            local db = DB()
            local key = kind .. "DurationText" .. suffix
            local oldKey = "auraDurationText" .. suffix
            if db and db[key] ~= nil then return db[key] end
            if db and db[oldKey] ~= nil then return db[oldKey] end
            return defaults[oldKey]
        end

        -- Shared helper: apply a timer position to live plates for one aura type
        local function LiveApplyTimerPos(auraFrames, count, v, kind)
            local durC = AuraDurationVal(kind, "Color")
            local durSz = AuraDurationVal(kind, "Size")
            local durX = AuraDurationVal(kind, "X")
            local durY = AuraDurationVal(kind, "Y")
            for _, plate in pairs(plates) do
                for i = 1, count do
                    local af = auraFrames(plate, i)
                    if af and af.cd then
                        if v == "none" then
                            if af.cd.SetHideCountdownNumbers then
                                af.cd:SetHideCountdownNumbers(true)
                            end
                        else
                            if af.cd.SetHideCountdownNumbers then
                                af.cd:SetHideCountdownNumbers(false)
                            end
                            if af.cd.text then
                                SetFSFont(af.cd.text, durSz, "OUTLINE, SLUG")
                                af.cd.text:SetTextColor(durC.r, durC.g, durC.b, 1)
                                af.cd.text:ClearAllPoints()
                                if v == "center" then
                                    af.cd.text:SetPoint("CENTER", af, "CENTER", durX, durY)
                                    af.cd.text:SetJustifyH("CENTER")
                                elseif v == "topright" then
                                    PP.Point(af.cd.text, "TOPRIGHT", af, "TOPRIGHT", 3 + durX, 4 + durY)
                                    af.cd.text:SetJustifyH("RIGHT")
                                elseif v == "bottomleft" then
                                    PP.Point(af.cd.text, "BOTTOMLEFT", af, "BOTTOMLEFT", -3 + durX, -4 + durY)
                                    af.cd.text:SetJustifyH("LEFT")
                                elseif v == "bottomright" then
                                    PP.Point(af.cd.text, "BOTTOMRIGHT", af, "BOTTOMRIGHT", 3 + durX, -4 + durY)
                                    af.cd.text:SetJustifyH("RIGHT")
                                else
                                    PP.Point(af.cd.text, "TOPLEFT", af, "TOPLEFT", -3 + durX, 4 + durY)
                                    af.cd.text:SetJustifyH("LEFT")
                                end
                            end
                        end
                    end
                end
            end
            -- 12.1 aura containers render the text through the style pass instead of the legacy frames above (fingerprint-guarded; nil on 12.0).
            if ns.NPC_ReloadAll then ns.NPC_ReloadAll() end
        end

        -- Shared helper: apply a stack-count position to live plates for one aura type
        local function LiveApplyStackPos(auraFrames, count, v)
            local stkC = (DB() and DB().auraStackTextColor) or defaults.auraStackTextColor
            local stkSz = DBVal("auraStackTextSize") or defaults.auraStackTextSize
            local stkX = DBVal("auraStackTextX") or defaults.auraStackTextX
            local stkY = DBVal("auraStackTextY") or defaults.auraStackTextY
            for _, plate in pairs(plates) do
                for i = 1, count do
                    local af = auraFrames(plate, i)
                    if af and af.count then
                        if v == "none" then
                            af.count:Hide()
                        else
                            af.count:Show()
                            SetFSFont(af.count, stkSz, "OUTLINE, SLUG")
                            af.count:SetTextColor(stkC.r, stkC.g, stkC.b, 1)
                            af.count:ClearAllPoints()
                            if v == "center" then
                                af.count:SetPoint("CENTER", af, "CENTER", stkX, stkY)
                                af.count:SetJustifyH("CENTER")
                            elseif v == "topright" then
                                PP.Point(af.count, "TOPRIGHT", af, "TOPRIGHT", 3 + stkX, 4 + stkY)
                                af.count:SetJustifyH("RIGHT")
                            elseif v == "bottomleft" then
                                PP.Point(af.count, "BOTTOMLEFT", af, "BOTTOMLEFT", -3 + stkX, -4 + stkY)
                                af.count:SetJustifyH("LEFT")
                            elseif v == "topleft" then
                                PP.Point(af.count, "TOPLEFT", af, "TOPLEFT", -3 + stkX, 4 + stkY)
                                af.count:SetJustifyH("LEFT")
                            else
                                PP.Point(af.count, "BOTTOMRIGHT", af, "BOTTOMRIGHT", 3 + stkX, -4 + stkY)
                                af.count:SetJustifyH("RIGHT")
                            end
                        end
                    end
                end
            end
            -- 12.1 aura containers: stacks render through the style pass (fingerprint-guarded; nil on 12.0).
            if ns.NPC_ReloadAll then ns.NPC_ReloadAll() end
        end

        local atFallback = DBVal("auraTextPosition") or defaults.auraTextPosition
        local asFallback = DBVal("auraStackTextPosition") or defaults.auraStackTextPosition

        -----------------------------------------------------------------------
        --  STYLE
        -----------------------------------------------------------------------
        local styleHeader
        styleHeader, h = W:SectionHeader(parent, "STYLE", y);  y = y - h
        y = EllesmereUI.BlizzStyle.Note(parent, y, "nameplates")

        local function RefreshAllTextures()
            ns.RefreshAllSettings()
            for _, plate in pairs(ns.friendlyPlates or {}) do
                if ns.ApplyHealthBarTexture then ns.ApplyHealthBarTexture(plate) end
                if ns.ApplyCastBarTexture then ns.ApplyCastBarTexture(plate) end
            end
        end

        -- Row 1: Border (None/Basic/Custom) | Border Size. Pure VIEW over showBorder + customBorderEnabled: None=off, Basic=standard border, Custom=custom border engine (reveals the Custom Border row below via page rebuild; None/Basic collapse it).
        -- Both stock styles gate both slots: they draw their own art (the stock background, the vanilla border sheets) and stand every EUI border down.
        local borderStyleRow
        borderStyleRow, h = W:DualRow(parent, y,
            EllesmereUI.BlizzStyle.Gate("nameplates", { type="dropdown", text="Border",
              values={ none = "None", basic = "Basic", custom = "Custom" },
              order={ "none", "basic", "custom" },
              getValue=function()
                if DBVal("customBorderEnabled") then return "custom" end
                local sb = DBVal("showBorder")
                if sb == nil then sb = defaults.showBorder end
                return sb and "basic" or "none"
              end,
              setValue=function(v)
                if v == "custom" then
                  DB().customBorderEnabled = true
                elseif v == "basic" then
                  DB().customBorderEnabled = false
                  DB().showBorder = true
                else
                  DB().customBorderEnabled = false
                  DB().showBorder = false
                end
                ns.RefreshBorder()
                ns.RefreshBorderColor()
                UpdatePreview()
                -- Force rebuild so the Custom Border row shows/hides and rows below reflow.
                EllesmereUI:RefreshPage(true)
              end }, EllesmereUI.BlizzStyle.Active("nameplates") == "classic"),
            EllesmereUI.BlizzStyle.Gate("nameplates", { type="slider", text="Border Size", min=1, max=4, step=1,
              -- Only Basic uses this size (None has no border; Custom uses its own Custom Border Size below).
              disabled=function()
                if DBVal("customBorderEnabled") then return true end
                local v = DBVal("showBorder")
                if v == nil then return not defaults.showBorder end
                return not v
              end,
              disabledTooltip="This option is only used by the Basic border.",
              rawTooltip=true,
              getValue=function() return DBVal("borderSize") or defaults.borderSize end,
              setValue=function(v)
                DB().borderSize = v
                ns.RefreshBorder()
                UpdatePreview()
              end }))
        y = y - h
        -- Inline swatch on the Border dropdown: standard (Basic) border color, dimmed unless mode is Basic.
        if not EllesmereUI._prebuilding then
            local leftRgn = borderStyleRow._leftRegion
            local function isBorderOff()
                -- Off for None and Custom (standard border/color is inert then) -- only Basic uses it.
                if EllesmereUI.BlizzStyle.Get("nameplates") then return true end
                if DBVal("customBorderEnabled") then return true end
                local v = DBVal("showBorder")
                if v == nil then return not defaults.showBorder end
                return not v
            end
            local borderColorGet = function()
                local c = (DB() and DB().borderColor) or defaults.borderColor
                return c.r, c.g, c.b
            end
            local borderColorSet = function(r, g, b)
                DB().borderColor = { r = r, g = g, b = b }
                ns.RefreshBorderColor()
                UpdatePreview()
            end
            local swatch, updateSwatch = EllesmereUI.BuildColorSwatch(leftRgn, leftRgn:GetFrameLevel() + 5, borderColorGet, borderColorSet, nil, 20)
            PP.Point(swatch, "RIGHT", leftRgn._control, "LEFT", -12, 0)
            leftRgn._lastInline = swatch
            EllesmereUI.RegisterWidgetRefresh(function()
                local off = isBorderOff()
                swatch:SetAlpha(off and 0.15 or 1)
                swatch:EnableMouse(not off)
                updateSwatch()
            end)
            local off = isBorderOff()
            swatch:SetAlpha(off and 0.15 or 1)
            swatch:EnableMouse(not off)
        end

        -- Inline cog on the Border region: opt-in "Wrap Around Castbar" (left of the colour swatch); dimmed only for "None" mode (wrap applies to both Basic and Custom).
        if not EllesmereUI._prebuilding then
            local leftRgn = borderStyleRow._leftRegion
            local function wrapCogOff()
                -- Only "None" disables it; Basic and Custom both support the wrap.
                -- Neither stock style has an EUI border to wrap: Blizzard Style
                -- draws the stock background art, Classic WoW UI the vanilla
                -- border sheets, and both stand the EUI borders down.
                if ns.NP_Blizz() then return true end
                if DBVal("customBorderEnabled") then return false end
                local v = DBVal("showBorder")
                if v == nil then v = defaults.showBorder end
                return not v
            end
            local wrapRows = {
                { type="toggle", label="Wrap Around Castbar",
                  -- Classic WoW UI draws the vanilla borders: nothing to wrap.
                  disabled=function() return EllesmereUI.BlizzStyle.Active("nameplates") == "classic" end,
                  disabledTooltip=function() return EllesmereUI.BlizzStyle.Label("nameplates") end,
                  requireState="disabled",
                  get=function()
                    local v = DBVal("wrapBorderCastbar")
                    if v == nil then return defaults.wrapBorderCastbar end
                    return v
                  end,
                  set=function(v)
                    DB().wrapBorderCastbar = v
                    -- Unconditional re-apply so toggling OFF also unwraps any plate mid-cast and wrapped.
                    ns.ApplyBorderWrapToAll()
                    UpdatePreview()
                    -- Show Seam Line's disabled state follows this toggle.
                    EllesmereUI:RefreshPage()
                  end },
            }
            -- Show Seam Line: the custom border's wrap only, so it is built only while
            -- Border = Custom (the Border setter rebuilds the page).
            if DBVal("customBorderEnabled") then
                wrapRows[#wrapRows + 1] = { type="toggle", label="Show Seam Line",
                  tooltip="Draws the border style's seam line between the health and cast bars.",
                  disabled=function()
                    return DBVal("wrapBorderCastbar") ~= true
                        or not ns.NP_CanShowWrapSeam(DBVal("customBorderTexture") or defaults.customBorderTexture)
                  end,
                  -- Wrap off: the standard requirement line; wrap on: the style is the lock.
                  disabledTooltip=function()
                    if DBVal("wrapBorderCastbar") ~= true then return "Wrap Around Castbar" end
                    return "This option requires the Pixels or Pixels Textured border style."
                  end,
                  rawTooltip=function() return DBVal("wrapBorderCastbar") == true end,
                  get=function() return DBVal("wrapBorderSeam") == true end,
                  set=function(v)
                    DB().wrapBorderSeam = v
                    ns.ApplyBorderWrapToAll()
                    UpdatePreview()
                  end }
            end
            EllesmereUI.BuildInlineCog(leftRgn, {
                disabled = wrapCogOff,
                disabledTooltip = "This option requires a Border to be selected",
                title = "Castbar Border",
                rows = wrapRows,
            })
        end

        -- Classic WoW UI only: the level, and the icon that replaces it on a
        -- boss, both seated in the health border's own plate. Each follows
        -- the bar's height until sized here, and each carries its X/Y nudges
        -- on an inline cog. Not built at all on the other styles, where there
        -- is no plate to fill; the if-body scopes its locals.
        if EllesmereUI.BlizzStyle.Active("nameplates") == "classic" then
            local classicPlateRow
            classicPlateRow, h = W:DualRow(parent, y,
                { type="slider", text="Level Size", min=0, max=40, step=1,
                  tooltip="Size of the level in the border's plate. 0 follows the bar height.",
                  getValue=function() return DBVal("classicLevelSize") or 0 end,
                  setValue=function(v)
                    DB().classicLevelSize = v
                    ns.RefreshAllSettings()
                    UpdatePreview()
                  end },
                { type="slider", text="Elite Icon Size", min=0, max=40, step=1,
                  tooltip="Size of the icon that replaces the level on a boss. 0 follows the bar height.",
                  getValue=function() return DBVal("classicSkullSize") or 0 end,
                  setValue=function(v)
                    DB().classicSkullSize = v
                    ns.RefreshAllSettings()
                    UpdatePreview()
                  end })
            y = y - h
            -- Reached by the preview's click navigation (the level in the
            -- border's plate scrolls here), which is built further down.
            parent._classicPlateRow = classicPlateRow
            if not EllesmereUI._prebuilding then
                local function PlateOffsetCog(rgn, title, xKey, yKey)
                    EllesmereUI.BuildInlineCog(rgn, {
                        title = title,
                        rows = {
                            { type="slider", label="X Offset", min=-50, max=50, step=1,
                              get=function() return DBVal(xKey) or 0 end,
                              set=function(v)
                                DB()[xKey] = v
                                ns.RefreshAllSettings()
                                UpdatePreview()
                              end },
                            { type="slider", label="Y Offset", min=-50, max=50, step=1,
                              get=function() return DBVal(yKey) or 0 end,
                              set=function(v)
                                DB()[yKey] = v
                                ns.RefreshAllSettings()
                                UpdatePreview()
                              end },
                        },
                    })
                end
                PlateOffsetCog(classicPlateRow._leftRegion, "Level Position", "classicLevelX", "classicLevelY")
                PlateOffsetCog(classicPlateRow._rightRegion, "Elite Icon Position", "classicSkullX", "classicSkullY")
            end
        end

        -- Custom Border row: only built when Border dropdown = "Custom" (selecting it triggers a page rebuild that reveals this row and reflows rows below;
        -- None/Basic collapse it). Uses the shared border engine (identical to Unit Frames, full SharedMedia support); the if-body scopes its locals to avoid growing this builder's local count.
        if DBVal("customBorderEnabled") then
            -- Custom Border Style dropdown (+ options cog) | Custom Border Size (+ color swatch)
            local cbTexValues, cbTexOrder = EllesmereUI.GetBorderTextureDropdown()
            local customBorderRow
            customBorderRow, h = W:DualRow(parent, y,
                EllesmereUI.BlizzStyle.Gate("nameplates", { type="dropdown", text="Custom Border Style",
                  values=cbTexValues, order=cbTexOrder,
                  getValue=function() return DBVal("customBorderTexture") or defaults.customBorderTexture end,
                  setValue=function(v)
                    DB().customBorderTexture = v
                    DB().customBorderOffset  = nil
                    DB().customBorderOffsetY = nil
                    DB().customBorderShiftX  = nil
                    DB().customBorderShiftY  = nil
                    local _bcol, _bbehind = EllesmereUI.GetBorderStyleSelectDefaults(v)
                    DB().customBorderColor  = _bcol
                    DB().customBorderAlpha  = 1
                    DB().customBorderBehind = _bbehind
                    local defSz = EllesmereUI.GetBorderDefaultSize("nameplates", v)
                    if defSz then DB().customBorderSize = defSz end
                    if DB().customBorderSizePx then DB().customBorderSizePx = false end
                    ns.RefreshBorder()
                    UpdatePreview()
                    -- Full rebuild: the Width/Height Offset row below exists only for a textured style.
                    EllesmereUI:RefreshPage(true)
                  end }),
                EllesmereUI.BlizzStyle.Gate("nameplates", EllesmereUI.BorderPxSliderCfg({
                  -- Narrower track: the slot also carries the colour swatch and the Icon Borders cog.
                  text="Custom Border Size", trackWidth=120,
                  getStep=function() return DBVal("customBorderSize") or defaults.customBorderSize end,
                  setStep=function(step) DB().customBorderSize = step end,
                  getTex=function() return DBVal("customBorderTexture") or defaults.customBorderTexture end,
                  getPx=function() return DB() and DB().customBorderSizePx end,
                  setPx=function(v) DB().customBorderSizePx = v end,
                  apply=function()
                    ns.RefreshBorder()
                    UpdatePreview()
                  end })))
            y = y - h

            -- Width Offset | Height Offset: the textured border's outward offsets, shown only while a
            -- textured style is selected (Solid has none). Built during prebuild too so the y advance matches.
            do
                local cbTexNow = DBVal("customBorderTexture") or defaults.customBorderTexture
                if cbTexNow and cbTexNow ~= "" and cbTexNow ~= "solid" then
                    local ocfgL, ocfgR = EllesmereUI.BorderOffsetRowCfgs({
                        addonKey   = "nameplates",
                        getTex     = function() return DBVal("customBorderTexture") or defaults.customBorderTexture end,
                        getStep    = function() return DBVal("customBorderSize") or defaults.customBorderSize end,
                        getSizeKey = function() return DBVal("customBorderSize") or defaults.customBorderSize end,
                        getPx      = function() return DB() and DB().customBorderSizePx end,
                        getX       = function() return DB() and DB().customBorderOffset end,
                        setX       = function(v) DB().customBorderOffset = v end,
                        getY       = function() return DB() and DB().customBorderOffsetY end,
                        setY       = function(v) DB().customBorderOffsetY = v end,
                        apply      = function() ns.RefreshBorder(); UpdatePreview() end,
                    })
                    _, h = W:DualRow(parent, y,
                        EllesmereUI.BlizzStyle.Gate("nameplates", ocfgL),
                        EllesmereUI.BlizzStyle.Gate("nameplates", ocfgR))
                    y = y - h
                end
            end

            -- Inline "Border Options" cog on the Custom Border Style region (shifts + Show Behind)
            if not EllesmereUI._prebuilding then
                local leftRgn = customBorderRow._leftRegion
                -- Shift offsets only apply to textured styles (row only exists when Custom is selected, so no enable gate needed).
                local function cbCogOff() return (DBVal("customBorderTexture") or defaults.customBorderTexture) == "solid" end
                EllesmereUI.BuildInlineCog(leftRgn, {
                    icon = EllesmereUI.DIRECTIONS_ICON or EllesmereUI.COGS_ICON,
                    disabled = cbCogOff,
                    disabledTooltip = "This option requires a textured border style",
                    title = "Border Options",
                    rows = {
                        { type="slider", label="Shift X", min=-10, max=10, step=1,
                          get=function()
                            local v = DB() and DB().customBorderShiftX
                            if v then return v end
                            local tex = DBVal("customBorderTexture") or defaults.customBorderTexture
                            local sz  = DBVal("customBorderSize") or defaults.customBorderSize
                            local _, _, dsx = EllesmereUI.GetBorderDefaults("nameplates", tex, sz)
                            return dsx
                          end,
                          set=function(v) DB().customBorderShiftX = (v == 0 and nil or v); ns.RefreshBorder(); UpdatePreview() end },
                        { type="slider", label="Shift Y", min=-10, max=10, step=1,
                          get=function()
                            local v = DB() and DB().customBorderShiftY
                            if v then return v end
                            local tex = DBVal("customBorderTexture") or defaults.customBorderTexture
                            local sz  = DBVal("customBorderSize") or defaults.customBorderSize
                            local _, _, _, dsy = EllesmereUI.GetBorderDefaults("nameplates", tex, sz)
                            return dsy
                          end,
                          set=function(v) DB().customBorderShiftY = (v == 0 and nil or v); ns.RefreshBorder(); UpdatePreview() end },
                        { type="toggle", label="Show Behind",
                          get=function()
                            local v = DBVal("customBorderBehind")
                            if v == nil then return defaults.customBorderBehind end
                            return v
                          end,
                          set=function(v) DB().customBorderBehind = v; ns.RefreshBorder(); UpdatePreview() end },
                    },
                })
            end

            -- Inline color swatch (with alpha) on the Custom Border Size region
            if not EllesmereUI._prebuilding then
                local rightRgn = customBorderRow._rightRegion
                local cbColGet = function()
                    local c = (DB() and DB().customBorderColor) or defaults.customBorderColor
                    return c.r, c.g, c.b, (DBVal("customBorderAlpha") or defaults.customBorderAlpha or 1)
                end
                local cbColSet = function(r, g, b, a)
                    DB().customBorderColor = { r = r, g = g, b = b }
                    if a ~= nil then DB().customBorderAlpha = a end
                    ns.RefreshBorderColor()
                    UpdatePreview()
                end
                local cbSwatch, cbUpdateSwatch = EllesmereUI.BuildColorSwatch(rightRgn, rightRgn:GetFrameLevel() + 5, cbColGet, cbColSet, true, 20)
                PP.Point(cbSwatch, "RIGHT", rightRgn._control, "LEFT", -12, 0)
                rightRgn._lastInline = cbSwatch
                EllesmereUI.RegisterWidgetRefresh(function() cbUpdateSwatch() end)
            end

            -- "Icon Borders" cog on the Custom Border Size region, chained left of the colour
            -- swatch above (built after it): the custom border on the aura icons and on the
            -- cast spell icon. A cog, not a row: both are niche, and the whole block exists
            -- only while Border = Custom. The if-body scopes its locals (builder budget).
            if not EllesmereUI._prebuilding then
                local rightRgn = customBorderRow._rightRegion
                EllesmereUI.BuildInlineCog(rightRgn, {
                    title = "Icon Borders",
                    captureRegion = rightRgn,
                    rows = {
                        { type="toggle", label="Custom Border on Aura Icons",
                          tooltip="Gives debuff, buff and crowd control icons the custom border instead of the 1-pixel border.",
                          disabled=function()
                            return DBVal("hideDebuffIconBorder") == true and DBVal("hideBuffIconBorder") == true
                                and DBVal("hideCCIconBorder") == true
                          end,
                          disabledTooltip="This option requires at least one aura type to show its border.",
                          rawTooltip=true,
                          get=function() return DBVal("auraIconCustomBorder") == true end,
                          set=function(v)
                            DB().auraIconCustomBorder = v
                            -- Fingerprint-gated aura restyle (the cast-lockout icon included).
                            ns.NPC_ReloadAll()
                            UpdatePreview()
                          end },
                        { type="toggle", label="Custom Border on Spell Icon",
                          tooltip="Gives the cast bar spell icon the custom border instead of its 1-pixel border.",
                          disabled=function()
                            return DBVal("showCastIcon") == false or DBVal("hideCastIconBorder") == true
                          end,
                          disabledTooltip="This option requires the spell icon and its border to be shown.",
                          rawTooltip=true,
                          get=function() return DBVal("castIconCustomBorder") == true end,
                          set=function(v)
                            DB().castIconCustomBorder = v
                            -- Re-applies every plate's appearance (pooled plates too), which
                            -- builds or turns off the icon border.
                            ns.RefreshAllSettings()
                            UpdatePreview()
                          end },
                    },
                })
            end
        end

        -- Row 2: Background (+swatch) | Absorb Style (+cog, preview eye) -- placed here so the section fills sequentially, no blank middle slot. Absorb Style options: Blizzard + the stripe overlay set (shared with Focus Texture) + Clean; stripe keys resolve via ns.ResolveOverlayTexPath.
        local absorbStyleValues = {
            ["blizzard"]="Blizzard",
            ["striped"]="Striped",
            ["striped-v2"]="Stripes",
            ["striped-wide-v2"]="Wide Stripes",
            ["stripes-medium"]="Medium Stripes",
            ["stripes-small-close"]="Small Dense Stripes",
            ["stripes-small-spread"]="Small Spread Stripes",
            ["striped-tiny"]="Tiny Stripes",
            ["clean"]="Clean (Flat)",
            ["pixelsShield"]="Pixels Shield",
            ["pixelsShieldEdge"]="Pixels Shield Edge",
            ["pixelsShieldFill"]="Pixels Shield Fill",
        }
        local absorbStyleOrder = {
            "blizzard", "striped",
            "striped-v2", "striped-wide-v2", "stripes-medium",
            "stripes-small-close", "stripes-small-spread", "striped-tiny",
            "clean", "pixelsShield", "pixelsShieldEdge", "pixelsShieldFill",
        }
        -- Append SharedMedia statusbar textures after a divider (mirrors Bar Texture). SM keys ("sm:") were added to the shared health-bar tables by AppendSharedMediaTextures; resolution flows via ns.ResolveOverlayTexPath -> health-bar lookup, so SM keys paint correctly here.
        do
            local sepAdded = false
            for _, k in ipairs(hbtOrder) do
                if k ~= "---" and k:find("^sm:") then
                    if not sepAdded then
                        absorbStyleOrder[#absorbStyleOrder + 1] = "---"
                        sepAdded = true
                    end
                    absorbStyleOrder[#absorbStyleOrder + 1] = k
                    absorbStyleValues[k] = hbtValues[k]
                end
            end
            -- Preview swatch behind each menu row resolves exactly like the render path: NP_ABSORB_STYLE_TEX for blizzard/striped/clean, then ns.ResolveOverlayTexPath for stripe overlays/SM keys.
            absorbStyleValues._menuOpts = {
                itemHeight = 28,
                background = function(key)
                    if not key or key == "---" then return nil end
                    return ns.NP_ABSORB_STYLE_TEX[key] or ns.ResolveOverlayTexPath(key)
                end,
            }
        end
        local bgHoverRow
        bgHoverRow, h = W:DualRow(parent, y,
            ns.NP_BlizzOnlyGate({ type="slider", text="Background", min=0, max=100, step=1,
              getValue=function()
                return math.floor(((DBVal("bgAlpha") or defaults.bgAlpha) * 100) + 0.5)
              end,
              setValue=function(v)
                DB().bgAlpha = v / 100
                local c = (DB() and DB().bgColor) or defaults.bgColor
                for _, plate in pairs(plates) do
                    plate.healthBG:SetColorTexture(c.r, c.g, c.b, v / 100)
                end
                UpdatePreview()
              end }),
            { type="dropdown", text="Absorb Style", values=absorbStyleValues, order=absorbStyleOrder,
              getValue=function() return DBVal("absorbStyle") or "blizzard" end,
              setValue=function(v)
                DB().absorbStyle = v
                -- Selecting a style sets opacity to that style's default (Blizzard/Stripes 80%, Clean 30%); slider tweaks from there.
                DB().absorbAlpha = math.floor(((ns.NP_ABSORB_STYLE_ALPHA[v] or 0.8) * 100) + 0.5)
                ns.ApplyAbsorbStyleAll()
                UpdatePreview()
                -- Refresh so the color swatch enables/disables (Blizzard = off).
                EllesmereUI:RefreshPage()
              end })
        y = y - h
        -- Inline color swatch on Background (left region)
        if not EllesmereUI._prebuilding then
            local leftRgn = bgHoverRow._leftRegion
            local cbColorGet = function()
                local c = (DB() and DB().bgColor) or defaults.bgColor
                return c.r, c.g, c.b
            end
            local cbColorSet = function(r, g, b)
                DB().bgColor = { r = r, g = g, b = b }
                local a = DBVal("bgAlpha") or defaults.bgAlpha
                for _, plate in pairs(plates) do
                    plate.healthBG:SetColorTexture(r, g, b, a)
                end
                UpdatePreview()
            end
            local cbSwatch, cbUpdateSwatch = EllesmereUI.BuildColorSwatch(leftRgn, leftRgn:GetFrameLevel() + 5, cbColorGet, cbColorSet, nil, 20)
            PP.Point(cbSwatch, "RIGHT", leftRgn._control, "LEFT", -12, 0)
            leftRgn._lastInline = cbSwatch
            EllesmereUI.RegisterWidgetRefresh(function() cbUpdateSwatch() end)
            if ns.NP_BlizzOnly() then EllesmereUI.BlizzStyle.BlockInline("nameplates", cbSwatch) end
        end

        -- Inline absorb color swatch (right of Row 2): white by default, tints every style except Blizzard (disabled there since Blizzard keeps its own coloring); mirrors the Focus Texture swatch's disabled pattern.
        if not EllesmereUI._prebuilding then
            local rgn = bgHoverRow._rightRegion
            local acColorGet = function()
                local c = (DB() and DB().absorbColor) or defaults.absorbColor or { r = 1, g = 1, b = 1 }
                return c.r, c.g, c.b
            end
            local acColorSet = function(r, g, b)
                DB().absorbColor = { r = r, g = g, b = b }
                ns.ApplyAbsorbStyleAll()
                UpdatePreview()
            end
            local acSwatch, acUpdateSwatch = EllesmereUI.BuildColorSwatch(rgn, rgn:GetFrameLevel() + 5, acColorGet, acColorSet, nil, 20)
            PP.Point(acSwatch, "RIGHT", rgn._lastInline or rgn._control, "LEFT", -8, 0)
            rgn._lastInline = acSwatch
            local function absorbColorOff() return (DBVal("absorbStyle") or "blizzard") == "blizzard" end
            EllesmereUI.RegisterWidgetRefresh(function()
                local off = absorbColorOff()
                acSwatch:SetAlpha(off and 0.15 or 1)
                acSwatch:EnableMouse(not off)
                acUpdateSwatch()
            end)
            local off0 = absorbColorOff()
            acSwatch:SetAlpha(off0 and 0.15 or 1)
            acSwatch:EnableMouse(not off0)
        end

        -- Inline "Absorb Settings" cog on the Absorb Style region (right of Row 2)
        if not EllesmereUI._prebuilding then
            local rgn = bgHoverRow._rightRegion
            EllesmereUI.BuildInlineCog(rgn, {
                title = "Absorb Settings",
                rows = {
                    { type = "slider", label = "Opacity", min = 5, max = 100, step = 1,
                      get = function()
                        local v = DBVal("absorbAlpha")
                        if v then return v end
                        -- Untouched profiles: show the active style's default.
                        local style = DBVal("absorbStyle") or "blizzard"
                        if style == "clean" then return DBVal("absorbCleanAlpha") or 30 end
                        return math.floor(((ns.NP_ABSORB_STYLE_ALPHA[style] or 0.8) * 100) + 0.5)
                      end,
                      set = function(v)
                        DB().absorbAlpha = v
                        ns.ApplyAbsorbStyleAll()
                        UpdatePreview()
                      end },
                },
            })
        end

        -- Eye icon: toggle absorb preview on the preview nameplate
        do
            local EYE_VISIBLE   = EllesmereUI.EYE_VISIBLE_ICON
            local EYE_INVISIBLE = EllesmereUI.EYE_INVISIBLE_ICON
            local rgn = bgHoverRow._rightRegion
            local eyeBtn = CreateFrame("Button", nil, rgn)
            eyeBtn:SetSize(26, 26)
            eyeBtn:SetPoint("RIGHT", rgn._lastInline or rgn._control, "LEFT", -8, 0)
            rgn._lastInline = eyeBtn
            eyeBtn:SetFrameLevel(rgn:GetFrameLevel() + 5)
            eyeBtn:SetAlpha(0.4)
            local eyeTex = eyeBtn:CreateTexture(nil, "OVERLAY")
            eyeTex:SetAllPoints()
            local function RefreshAbsorbEye()
                if optState.showAbsorbPreview then
                    eyeTex:SetTexture(EYE_INVISIBLE)
                else
                    eyeTex:SetTexture(EYE_VISIBLE)
                end
            end
            RefreshAbsorbEye()
            eyeBtn:SetScript("OnClick", function()
                optState.showAbsorbPreview = not optState.showAbsorbPreview
                RefreshAbsorbEye()
                UpdatePreview()
            end)
            eyeBtn:SetScript("OnEnter", function(self) self:SetAlpha(0.7) end)
            eyeBtn:SetScript("OnLeave", function(self) self:SetAlpha(0.4) end)
        end

        -- Row 3: Bar Texture | Cast Bar Texture -- share the same texture set (EUI built-ins + SharedMedia) and resolve identically; Bar Texture drives the health bar, Cast Bar Texture drives the cast bar.
        _, h = W:DualRow(parent, y,
            -- Bar Texture stays live under Blizzard Style: the health fill is the
            -- user's own texture under the stock background art.
            { type="dropdown", text="Bar Texture", values=hbtValues, order=hbtOrder,
              getValue=function() return DBVal("healthBarTexture") or "none" end,
              setValue=function(v)
                DB().healthBarTexture = v
                RefreshAllTextures()
                UpdatePreview()
              end },
            ns.NP_BlizzOnlyGate({ type="dropdown", text="Cast Bar Texture", values=hbtValues, order=hbtOrder,
              getValue=function() return DBVal("castBarTexture") or "none" end,
              setValue=function(v)
                DB().castBarTexture = v
                RefreshAllTextures()
                UpdatePreview()
              end }));  y = y - h

        -- WoW Forever variant only (the Forever client): Show Level Box, the
        -- opt-out for the level box right of the health bar (nil = shown),
        -- last in the section so its blank slot is the odd last one. Off, the
        -- plates lay out as plain Blizzard Style; Left Text stays the user's
        -- to set to Level. Not built on any other look.
        if EllesmereUI.BlizzStyle.Forever("nameplates") then
            local foreverBoxRow
            foreverBoxRow, h = W:DualRow(parent, y,
                { type="toggle", text="Show Level Box",
                  tooltip="Shows the level box right of the health bar; with it off, Left Text can show the level instead.",
                  getValue=function() return not DBVal("foreverHideLevelBox") end,
                  setValue=function(v)
                    DB().foreverHideLevelBox = (not v) or nil
                    ns.RefreshAllSettings()
                    UpdatePreview()
                  end },
                EllesmereUI.BlankRowCfg())
            y = y - h
            -- Reached by the preview's click navigation (the level box).
            parent._foreverBoxRow = foreverBoxRow
        end

        _, h = W:Spacer(parent, y, 20);  y = y - h

        -----------------------------------------------------------------------
        --  CORE POSITIONS
        -----------------------------------------------------------------------
        local coreHeader
        coreHeader, h = W:SectionHeader(parent, "CORE POSITIONS", y);  y = y - h

        -- Subtitle hint next to the section header
        do
            local regions = { coreHeader:GetRegions() }
            for _, rgn in ipairs(regions) do
                if rgn:IsObjectType("FontString") and EllesmereUI.EnKey(rgn:GetText()) == "CORE POSITIONS" then
                    local sub = coreHeader:CreateFontString(nil, "OVERLAY")
                    sub:SetFont(rgn:GetFont())
                    sub:SetTextColor(1, 1, 1, 0.25)
                    sub:SetText(EllesmereUI.L("(one per slot)"))
                    sub:SetPoint("LEFT", rgn, "RIGHT", 6, 0)
                    break
                end
            end
        end

        local coreElementValues = {
            debuffs        = "Debuffs",
            buffs          = "Buffs",
            ccs            = "Crowd Control",
            debuffsccs     = "Debuffs + CC",
            raidmarker     = "Raid Marker",
            classification = "Rare/Quest Indicator",
            faction        = "Faction",
            classfaction   = "Rare/Quest + Faction",
            none           = "None",
        }
        local coreElementOrder = { "debuffs", "buffs", "ccs", "debuffsccs", "raidmarker", "classification", "faction", "classfaction", "none" }

        local coreRow1, coreRow2, coreRow3
        local _refreshRaidMarkerEyePos
        local _refreshClassificationEyePos

        optState.RefreshCoreEyes = function()
            if _refreshRaidMarkerEyePos then _refreshRaidMarkerEyePos() end
            if _refreshClassificationEyePos then _refreshClassificationEyePos() end
        end

        -- Slot-based offsets: pos .. "SlotXOffset" / "SlotYOffset"

        local function CorePosXGet(pos)
            return DBVal(pos .. "SlotXOffset") or 0
        end
        local function CorePosYGet(pos)
            return DBVal(pos .. "SlotYOffset") or 0
        end
        local function CorePosXSet(pos, v)
            DB()[pos .. "SlotXOffset"] = v
            RefreshAllSlots()
        end
        local function CorePosYSet(pos, v)
            DB()[pos .. "SlotYOffset"] = v
            RefreshAllSlots()
        end
        local function CorePosOffDisabled(pos)
            return GetElementAtPosition(pos) == "none"
        end

        -------------------------------------------------------------------
        --  Combined Settings Popup  (singleton, slide-up, pos + optional size)
        -------------------------------------------------------------------
        local cogPopup          -- the popup frame (created once)
        local cogPopupOwner     -- which cog icon currently owns the popup

        local function CogPopupOpen(btn) return cogPopupOwner == btn and cogPopup:IsShown() end

        -- opts = {title, xGet, xSet, yGet, ySet, sizeGet, sizeSet, sizeMin, sizeMax, sizeStep, sizeLabel}; sizeGet nil = no size row.
        local function ShowCogPopup(anchorBtn, opts)
            if not cogPopup then
                local SolidTex = EllesmereUI.SolidTex
                local MakeBorder = EllesmereUI.MakeBorder
                local MakeFont = EllesmereUI.MakeFont
                local BuildSliderCore = EllesmereUI.BuildSliderCore
                local BORDER_COLOR = EllesmereUI.BORDER_COLOR
                local SL_INPUT_A = EllesmereUI.SL_INPUT_A

                local SIDE_PAD   = 14
                local INPUT_W    = 34; local SLIDER_INPUT_GAP = 8; local LABEL_SLIDER_GAP = 12
                local TOP_PAD    = 14
                local TITLE_H    = 11
                local TITLE_GAP  = 10
                local GAP        = 10
                local SLIDER_H   = 24

                -- Max height: title + X + Y + Size = 4 rows
                local MAX_H = TOP_PAD + TITLE_H + TITLE_GAP + GAP + SLIDER_H + GAP + SLIDER_H + GAP + SLIDER_H + TOP_PAD

                local pf = CreateFrame("Frame", nil, UIParent)
                pf:SetSize(260, MAX_H)
                pf:SetFrameStrata("DIALOG")
                pf:SetFrameLevel(200)
                pf:EnableMouse(true)
                pf:Hide()

                -- Match the panel/popup scale so this popup renders at the same size as the shared BuildCogPopup popups (else it stays scale 1.0 and looks oversized); registering it also tracks the panel scale slider.
                pf:SetScale((EllesmereUI.GetPopupScale()) or 1)
                if EllesmereUI._popupFrames then
                    EllesmereUI._popupFrames[#EllesmereUI._popupFrames + 1] = { popup = pf }
                end

                local bg = SolidTex(pf, "BACKGROUND", 0.06, 0.08, 0.10, 0.95)
                bg:SetAllPoints()
                MakeBorder(pf, BORDER_COLOR.r, BORDER_COLOR.g, BORDER_COLOR.b, 0.15)

                local titleFS = MakeFont(pf, 11, "", 1, 1, 1)
                titleFS:SetAlpha(0.7)
                titleFS:SetPoint("TOP", pf, "TOP", 0, -TOP_PAD)
                pf._titleFS = titleFS

                local tmpFS = pf:CreateFontString(nil, "OVERLAY")
                tmpFS:SetFont(EllesmereUI.EXPRESSWAY or "Fonts\\FRIZQT__.TTF", 12, GetNPOptOutline())
                local labelTexts = {"X Offset", "Y Offset", "Size", "Width %", "Spacing", "Opacity"}
                local maxLblW = 0
                for _, txt in ipairs(labelTexts) do
                    tmpFS:SetText(EllesmereUI.L(txt))
                    local w = tmpFS:GetStringWidth()
                    if w > maxLblW then maxLblW = w end
                end
                tmpFS:Hide()
                if maxLblW < 10 then maxLblW = 28 end

                local SLIDER_LEFT = SIDE_PAD + maxLblW + LABEL_SLIDER_GAP
                local SLIDER_W = math.max(80, 260 - SLIDER_LEFT - SLIDER_INPUT_GAP - INPUT_W - SIDE_PAD)
                local POPUP_W = SLIDER_LEFT + SLIDER_W + SLIDER_INPUT_GAP + INPUT_W + SIDE_PAD
                if POPUP_W < 180 then POPUP_W = 180 end
                pf:SetSize(POPUP_W, pf:GetHeight())

                -- X slider row
                local X_ROW_Y = -(TOP_PAD + TITLE_H + TITLE_GAP + GAP)
                local xLabel = MakeFont(pf, 12, nil, 1, 1, 1)
                xLabel:SetAlpha(0.6); xLabel:SetText(EllesmereUI.L("X Offset"))
                xLabel:SetPoint("LEFT", pf, "TOPLEFT", SIDE_PAD, X_ROW_Y - SLIDER_H / 2)
                local xTrack, xValBox = BuildSliderCore(pf, SLIDER_W, 4, 12, INPUT_W, SLIDER_H, 11, SL_INPUT_A,
                    -300, 300, 1,
                    function() return pf._xGet and pf._xGet() or 0 end,
                    function(v) if pf._xSet then pf._xSet(v) end end, true)
                xTrack:SetPoint("TOPLEFT", pf, "TOPLEFT", SLIDER_LEFT, X_ROW_Y - 2)
                xValBox:ClearAllPoints(); xValBox:SetPoint("TOPRIGHT", pf, "TOPRIGHT", -SIDE_PAD, X_ROW_Y)

                pf._xTrack = xTrack; pf._xValBox = xValBox; pf._xLabel = xLabel

                -- Y slider row
                local Y_ROW_Y = X_ROW_Y - SLIDER_H - GAP
                local yLabel = MakeFont(pf, 12, nil, 1, 1, 1)
                yLabel:SetAlpha(0.6); yLabel:SetText(EllesmereUI.L("Y Offset"))
                yLabel:SetPoint("LEFT", pf, "TOPLEFT", SIDE_PAD, Y_ROW_Y - SLIDER_H / 2)
                local yTrack, yValBox = BuildSliderCore(pf, SLIDER_W, 4, 12, INPUT_W, SLIDER_H, 11, SL_INPUT_A,
                    -300, 300, 1,
                    function() return pf._yGet and pf._yGet() or 0 end,
                    function(v) if pf._ySet then pf._ySet(v) end end, true)
                yTrack:SetPoint("TOPLEFT", pf, "TOPLEFT", SLIDER_LEFT, Y_ROW_Y - 2)
                yValBox:ClearAllPoints(); yValBox:SetPoint("TOPRIGHT", pf, "TOPRIGHT", -SIDE_PAD, Y_ROW_Y)

                pf._yTrack = yTrack; pf._yValBox = yValBox; pf._yLabel = yLabel

                -- Size slider row (hidden when not needed)
                local S_ROW_Y = Y_ROW_Y - SLIDER_H - GAP
                local sLabel = MakeFont(pf, 12, nil, 1, 1, 1)
                sLabel:SetAlpha(0.6); sLabel:SetText(EllesmereUI.L("Size"))
                sLabel:SetPoint("LEFT", pf, "TOPLEFT", SIDE_PAD, S_ROW_Y - SLIDER_H / 2)
                pf._sLabel = sLabel

                -- Spacing slider row (hidden unless the slot holds a multi-icon aura element: debuffs/buffs/CCs); fixed range, built once.
                local SP_ROW_Y = S_ROW_Y - SLIDER_H - GAP
                local spLabel = MakeFont(pf, 12, nil, 1, 1, 1)
                spLabel:SetAlpha(0.6); spLabel:SetText(EllesmereUI.L("Spacing"))
                spLabel:SetPoint("LEFT", pf, "TOPLEFT", SIDE_PAD, SP_ROW_Y - SLIDER_H / 2)
                spLabel:Hide()
                pf._spLabel = spLabel
                local spTrack, spValBox = BuildSliderCore(pf, SLIDER_W, 4, 12, INPUT_W, SLIDER_H, 11, SL_INPUT_A,
                    -5, 20, 1,
                    function() return pf._spGet and pf._spGet() or 0 end,
                    function(v) if pf._spSet then pf._spSet(v) end end, true)
                spTrack:SetPoint("TOPLEFT", pf, "TOPLEFT", SLIDER_LEFT, SP_ROW_Y - 2)
                spValBox:ClearAllPoints(); spValBox:SetPoint("TOPRIGHT", pf, "TOPRIGHT", -SIDE_PAD, SP_ROW_Y)
                spTrack:Hide(); spValBox:Hide()
                pf._spTrack = spTrack; pf._spValBox = spValBox

                -- Width % slider row (hidden unless a width-fit text element: enemy name, cast spell name, cast target); fixed range built once, reordered/repositioned per show via the seq block below.
                local W_ROW_Y = SP_ROW_Y - SLIDER_H - GAP
                local wLabel = MakeFont(pf, 12, nil, 1, 1, 1)
                wLabel:SetAlpha(0.6); wLabel:SetText(EllesmereUI.L("Width %"))
                wLabel:SetPoint("LEFT", pf, "TOPLEFT", SIDE_PAD, W_ROW_Y - SLIDER_H / 2)
                wLabel:Hide()
                pf._wLabel = wLabel
                -- Invisible hover region for the label's tooltip (FontStrings aren't mouse-interactive); SetAllPoints tracks the label through repositioning, shown/hidden with the row.
                local wHover = CreateFrame("Frame", nil, pf)
                wHover:SetFrameLevel(pf:GetFrameLevel() + 10)
                wHover:SetAllPoints(wLabel)
                wHover:EnableMouse(true)
                wHover:Hide()
                wHover:SetScript("OnEnter", function(self)
                    EllesmereUI.ShowWidgetTooltip(self, EllesmereUI.L("Maximum width the text can fill before it truncates, as a percentage of the bar."), { width = 230 })
                end)
                wHover:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
                pf._wHover = wHover
                local wTrack, wValBox = BuildSliderCore(pf, SLIDER_W, 4, 12, INPUT_W, SLIDER_H, 11, SL_INPUT_A,
                    10, 150, 1,
                    function() return pf._wGet and pf._wGet() or 0 end,
                    function(v) if pf._wSet then pf._wSet(v) end end, true)
                wTrack:SetPoint("TOPLEFT", pf, "TOPLEFT", SLIDER_LEFT, W_ROW_Y - 2)
                wValBox:ClearAllPoints(); wValBox:SetPoint("TOPRIGHT", pf, "TOPRIGHT", -SIDE_PAD, W_ROW_Y)
                wTrack:Hide(); wValBox:Hide()
                pf._wTrack = wTrack; pf._wValBox = wValBox

                -- Store layout values for dynamic size slider rebuild + reorder
                pf._SLIDER_LEFT = SLIDER_LEFT
                pf._SLIDER_W = SLIDER_W
                pf._X_ROW_Y = X_ROW_Y
                pf._Y_ROW_Y = Y_ROW_Y
                pf._S_ROW_Y = S_ROW_Y
                pf._SP_ROW_Y = SP_ROW_Y
                pf._ROW0 = X_ROW_Y
                pf._ROW_STEP = SLIDER_H + GAP

                -- Growth direction row (shown only for topleft/topright slots)
                local GROWTH_ROW_H = 22
                local G_ROW_Y = S_ROW_Y - SLIDER_H - GAP
                pf._G_ROW_Y = G_ROW_Y
                pf._GROWTH_ROW_H = GROWTH_ROW_H

                local gLabel = MakeFont(pf, 12, nil, 1, 1, 1)
                gLabel:SetAlpha(0.6); gLabel:SetText(EllesmereUI.L("Grow"))
                gLabel:SetPoint("LEFT", pf, "TOPLEFT", SIDE_PAD, G_ROW_Y - GROWTH_ROW_H / 2)
                pf._gLabel = gLabel

                -- Grow direction is a standard dropdown; option list + order vary per cog (topleft vs topright), filled into these mutable tables at show time (menu invalidated to rebuild); getValue/setValue delegate to the per-show growth getter/setter.
                pf._growthValues = {}   -- key -> label
                pf._growthOrder  = {}   -- ordered keys
                -- Standard cog-popup dropdown sizing (matches BuildCogPopup's dropdown rows): 130px wide, rendered 10% smaller, right-aligned at layout time.
                local GROW_DD_W = 130
                local GROW_DD_SCALE = 0.9
                pf._GROW_DD_SCALE = GROW_DD_SCALE
                local gDD = EllesmereUI.BuildDropdownControl(pf, GROW_DD_W, pf:GetFrameLevel() + 6,
                    pf._growthValues, pf._growthOrder,
                    function() return pf._growthGet and pf._growthGet() or "" end,
                    function(v) if pf._growthSet then pf._growthSet(v) end end)
                gDD:SetScale(GROW_DD_SCALE)
                -- Lazily-created menu parents to UIParent (scale 1); sync to the shrunk control the first time it opens.
                gDD:HookScript("OnClick", function(self)
                    if self._ddMenu and not self._ddMenu._npCogScaled then
                        self._ddMenu:SetScale(GROW_DD_SCALE)
                        self._ddMenu._npCogScaled = true
                    end
                end)
                gDD:Hide()
                pf._gDD = gDD

                -- Optional toggle row, anchored at layout time: takes the 4th-row slot (G_ROW_Y) with no Grow row, stacks BELOW Grow when both present (e.g. Rare/Quest Indicator on topleft/topright: Grow + Show In Instances). Wired via pf._toggleGet/Set.
                local tLabel = MakeFont(pf, 12, nil, 1, 1, 1)
                tLabel:SetAlpha(0.6)
                tLabel:SetPoint("LEFT", pf, "TOPLEFT", SIDE_PAD, G_ROW_Y - GROWTH_ROW_H / 2)
                tLabel:Hide()
                pf._tLabel = tLabel
                local tToggle, _, tToggleSnap = EllesmereUI.BuildToggleControl(pf, pf:GetFrameLevel() + 5,
                    function() return pf._toggleGet and pf._toggleGet() or false end,
                    function(v) if pf._toggleSet then pf._toggleSet(v) end end,
                    { sizeRatio = 0.8, noAnim = true })
                tToggle:SetPoint("RIGHT", pf, "TOPRIGHT", -SIDE_PAD, G_ROW_Y - GROWTH_ROW_H / 2)
                tToggle:Hide()
                pf._tToggle = tToggle
                pf._toggleSnap = tToggleSnap

                -- Optional "Raise Strata" toggle row (own row, below Grow/Cropped Icons/Wrap so it can coexist with any on a Core Position slot); wired via pf._rsGet/pf._rsSet.
                local rsLabel = MakeFont(pf, 12, nil, 1, 1, 1)
                rsLabel:SetAlpha(0.6)
                rsLabel:SetText(EllesmereUI.L("Raise Strata"))
                rsLabel:SetPoint("LEFT", pf, "TOPLEFT", SIDE_PAD, G_ROW_Y - GROWTH_ROW_H / 2)
                rsLabel:Hide()
                pf._rsLabel = rsLabel
                -- Invisible hover region over the label for its tooltip.
                local rsHover = CreateFrame("Frame", nil, pf)
                rsHover:SetFrameLevel(pf:GetFrameLevel() + 10)
                rsHover:SetAllPoints(rsLabel)
                rsHover:EnableMouse(true)
                rsHover:Hide()
                rsHover:SetScript("OnEnter", function(self)
                    EllesmereUI.ShowWidgetTooltip(self, EllesmereUI.L("Renders this slot's element above the rest of the nameplate."), { width = 230 })
                end)
                rsHover:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
                pf._rsHover = rsHover
                local rsToggle, _, rsToggleSnap = EllesmereUI.BuildToggleControl(pf, pf:GetFrameLevel() + 5,
                    function() return pf._rsGet and pf._rsGet() or false end,
                    function(v) if pf._rsSet then pf._rsSet(v) end end,
                    { sizeRatio = 0.8, noAnim = true })
                rsToggle:SetPoint("RIGHT", pf, "TOPRIGHT", -SIDE_PAD, G_ROW_Y - GROWTH_ROW_H / 2)
                rsToggle:Hide()
                pf._rsToggle = rsToggle
                pf._rsToggleSnap = rsToggleSnap

                -- Optional "Strata" dropdown row (Core Text slots): the standard
                -- strata dropdown, static option set, positioned in the Grow/
                -- toggle band at layout time; wired via pf._strataGetFn/SetFn.
                local stLabel = MakeFont(pf, 12, nil, 1, 1, 1)
                stLabel:SetAlpha(0.6)
                stLabel:SetText(EllesmereUI.L("Strata"))
                stLabel:SetPoint("LEFT", pf, "TOPLEFT", SIDE_PAD, G_ROW_Y - GROWTH_ROW_H / 2)
                stLabel:Hide()
                pf._stLabel = stLabel
                local stDD = EllesmereUI.BuildDropdownControl(pf, GROW_DD_W, pf:GetFrameLevel() + 6,
                    EllesmereUI.FRAME_STRATA_LABELS, EllesmereUI.FRAME_STRATA_ORDER_BASE,
                    function() return pf._strataGetFn and pf._strataGetFn() or "MEDIUM" end,
                    function(v) if pf._strataSetFn then pf._strataSetFn(v) end end)
                stDD:SetScale(GROW_DD_SCALE)
                stDD:HookScript("OnClick", function(self)
                    if self._ddMenu and not self._ddMenu._npCogScaled then
                        self._ddMenu:SetScale(GROW_DD_SCALE)
                        self._ddMenu._npCogScaled = true
                    end
                end)
                stDD:Hide()
                pf._stDD = stDD

                -- Optional "Cropped Icons" toggle row: gets its OWN row below data/grow rows (unlike the generic toggle) so it can coexist with Grow on aura slots; wired via pf._cropGet/Set, repositioned per show.
                local cropLabel = MakeFont(pf, 12, nil, 1, 1, 1)
                cropLabel:SetAlpha(0.6)
                cropLabel:SetText(EllesmereUI.L("Cropped Icons"))
                cropLabel:SetPoint("LEFT", pf, "TOPLEFT", SIDE_PAD, G_ROW_Y - GROWTH_ROW_H / 2)
                cropLabel:Hide()
                pf._cropLabel = cropLabel
                local cropToggle, _, cropToggleSnap = EllesmereUI.BuildToggleControl(pf, pf:GetFrameLevel() + 5,
                    function() return pf._cropGet and pf._cropGet() or false end,
                    function(v)
                        if pf._cropSet then pf._cropSet(v) end
                        -- The Adjust Crop slider (below) rides this toggle's state.
                        if pf._cropPctSyncDisabled then pf._cropPctSyncDisabled() end
                    end,
                    { sizeRatio = 0.8, noAnim = true })
                cropToggle:SetPoint("RIGHT", pf, "TOPRIGHT", -SIDE_PAD, G_ROW_Y - GROWTH_ROW_H / 2)
                cropToggle:Hide()
                pf._cropToggle = cropToggle
                pf._cropToggleSnap = cropToggleSnap

                -- Optional "Adjust Crop" slider row (own row, below Cropped Icons; wired via pf._cropPctGet/Set): per-side trim percentage, 10 = classic fixed crop. Blocked+dimmed while Cropped Icons is off (standard disabled-inline-control pattern).
                local cpLabel = MakeFont(pf, 12, nil, 1, 1, 1)
                cpLabel:SetAlpha(0.6); cpLabel:SetText(EllesmereUI.L("Adjust Crop"))
                cpLabel:Hide()
                pf._cropPctLabel = cpLabel
                local cpHover = CreateFrame("Frame", nil, pf)
                cpHover:SetFrameLevel(pf:GetFrameLevel() + 10)
                cpHover:SetAllPoints(cpLabel)
                cpHover:EnableMouse(true)
                cpHover:Hide()
                cpHover:SetScript("OnEnter", function(self)
                    EllesmereUI.ShowWidgetTooltip(self, EllesmereUI.L("How much is trimmed from the icon's top and bottom, as a percentage per side. 10% is the classic cropped look."), { width = 230 })
                end)
                cpHover:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
                pf._cropPctHover = cpHover
                -- Narrower track than standard rows: "Adjust Crop" label is wider than Size/Spacing and would run under a full-width track; right edge stays aligned (track start shifts right by the same amount).
                local cpTrack, cpValBox = BuildSliderCore(pf, SLIDER_W - 26, 4, 12, INPUT_W, SLIDER_H, 11, SL_INPUT_A,
                    5, 25, 1,
                    function() return pf._cropPctGet and pf._cropPctGet() or 10 end,
                    function(v) if pf._cropPctSet then pf._cropPctSet(v) end end, true)
                cpTrack:Hide(); cpValBox:Hide()
                pf._cropPctTrack = cpTrack; pf._cropPctValBox = cpValBox
                -- Blocking overlay for the disabled state (covers track + input).
                local cpBlock = CreateFrame("Frame", nil, pf)
                cpBlock:SetFrameLevel(pf:GetFrameLevel() + 20)
                cpBlock:EnableMouse(true)
                cpBlock:Hide()
                cpBlock:SetScript("OnEnter", function(self)
                    EllesmereUI.ShowWidgetTooltip(self, EllesmereUI.DisabledTooltip("Cropped Icons"))
                end)
                cpBlock:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
                pf._cropPctBlock = cpBlock
                -- Dim/undim + block per the crop toggle's current value; called on every popup show and whenever the toggle flips.
                pf._cropPctSyncDisabled = function()
                    if not cpTrack:IsShown() then
                        cpBlock:Hide()
                        return
                    end
                    local on = pf._cropGet and pf._cropGet() and true or false
                    local a = on and 1 or 0.3
                    cpTrack:SetAlpha(a); cpValBox:SetAlpha(a)
                    cpLabel:SetAlpha(on and 0.6 or 0.25)
                    cpBlock:ClearAllPoints()
                    cpBlock:SetPoint("TOPLEFT", cpTrack, "TOPLEFT", 0, 4)
                    cpBlock:SetPoint("BOTTOMRIGHT", cpValBox, "BOTTOMRIGHT", 0, -4)
                    cpBlock:SetShown(not on)
                end

                -- Optional "Wrap" toggle row (own row, like Cropped Icons), used by truncating text elements so it coexists with the generic toggle (e.g. health text keeps Decimal there, Wrap here); wired via pf._wrapGet/Set.
                local wrapLabel = MakeFont(pf, 12, nil, 1, 1, 1)
                wrapLabel:SetAlpha(0.6)
                wrapLabel:SetText(EllesmereUI.L("Wrap"))
                wrapLabel:SetPoint("LEFT", pf, "TOPLEFT", SIDE_PAD, G_ROW_Y - GROWTH_ROW_H / 2)
                wrapLabel:Hide()
                pf._wrapLabel = wrapLabel
                -- Invisible hover region over the Wrap label for its tooltip (see the Width % hover above); tracks the label, shown/hidden with the row.
                local wrapHover = CreateFrame("Frame", nil, pf)
                wrapHover:SetFrameLevel(pf:GetFrameLevel() + 10)
                wrapHover:SetAllPoints(wrapLabel)
                wrapHover:EnableMouse(true)
                wrapHover:Hide()
                wrapHover:SetScript("OnEnter", function(self)
                    EllesmereUI.ShowWidgetTooltip(self, pf._wrapTip and EllesmereUI.L(pf._wrapTip) or EllesmereUI.L("Lets long text wrap onto a second line instead of being cut off."), { width = 230 })
                end)
                wrapHover:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
                pf._wrapHover = wrapHover
                local wrapToggle, _, wrapToggleSnap = EllesmereUI.BuildToggleControl(pf, pf:GetFrameLevel() + 5,
                    function() return pf._wrapGet and pf._wrapGet() or false end,
                    function(v) if pf._wrapSet then pf._wrapSet(v) end end,
                    { sizeRatio = 0.8, noAnim = true })
                wrapToggle:SetPoint("RIGHT", pf, "TOPRIGHT", -SIDE_PAD, G_ROW_Y - GROWTH_ROW_H / 2)
                wrapToggle:Hide()
                pf._wrapToggle = wrapToggle
                pf._wrapToggleSnap = wrapToggleSnap

                -- Optional second generic toggle row (own row, below Wrap), for an
                -- element that needs one more switch than the toggle row gives it
                -- (e.g. Level Text: Include Friendly, Rare/Quest + Faction); wired via pf._toggle2Get/Set, label per show.
                local t2Label = MakeFont(pf, 12, nil, 1, 1, 1)
                t2Label:SetAlpha(0.6)
                t2Label:SetPoint("LEFT", pf, "TOPLEFT", SIDE_PAD, G_ROW_Y - GROWTH_ROW_H / 2)
                t2Label:Hide()
                pf._t2Label = t2Label
                local t2Toggle, _, t2ToggleSnap = EllesmereUI.BuildToggleControl(pf, pf:GetFrameLevel() + 5,
                    function() return pf._toggle2Get and pf._toggle2Get() or false end,
                    function(v) if pf._toggle2Set then pf._toggle2Set(v) end end,
                    { sizeRatio = 0.8, noAnim = true })
                t2Toggle:SetPoint("RIGHT", pf, "TOPRIGHT", -SIDE_PAD, G_ROW_Y - GROWTH_ROW_H / 2)
                t2Toggle:Hide()
                pf._t2Toggle = t2Toggle
                pf._t2ToggleSnap = t2ToggleSnap

                -- Optional second dropdown row (own row, below the second toggle),
                -- built like Grow; values/label per show, via pf._dd2Get/Set.
                local d2Label = MakeFont(pf, 12, nil, 1, 1, 1)
                d2Label:SetAlpha(0.6)
                d2Label:SetPoint("LEFT", pf, "TOPLEFT", SIDE_PAD, G_ROW_Y - GROWTH_ROW_H / 2)
                d2Label:Hide()
                pf._d2Label = d2Label
                pf._dd2Values = {}
                pf._dd2Order  = {}
                local d2DD = EllesmereUI.BuildDropdownControl(pf, GROW_DD_W, pf:GetFrameLevel() + 6,
                    pf._dd2Values, pf._dd2Order,
                    function() return pf._dd2Get and pf._dd2Get() or "" end,
                    function(v) if pf._dd2Set then pf._dd2Set(v) end end)
                d2DD:SetScale(GROW_DD_SCALE)
                d2DD:HookScript("OnClick", function(self)
                    if self._ddMenu and not self._ddMenu._npCogScaled then
                        self._ddMenu:SetScale(GROW_DD_SCALE)
                        self._ddMenu._npCogScaled = true
                    end
                end)
                d2DD:Hide()
                pf._d2DD = d2DD

                -- Layout constants stored for height calc
                pf._TOP_PAD = TOP_PAD; pf._TITLE_H = TITLE_H; pf._TITLE_GAP = TITLE_GAP
                pf._GAP = GAP; pf._SLIDER_H = SLIDER_H; pf._SIDE_PAD = SIDE_PAD
                pf._POPUP_W = POPUP_W

                -- Close on click outside
                local wasDown = false
                pf._clickOutside = function(self, dt)
                    local down = IsMouseButtonDown("LeftButton")
                    if down and not wasDown then
                        -- The Grow/Strata/second dropdown menus float outside this popup's rect; a click there must not count as click-outside.
                        local m = self._gDD and self._gDD._ddMenu
                        local m2 = self._stDD and self._stDD._ddMenu
                        local m3 = self._d2DD and self._d2DD._ddMenu
                        local overMenu = (m and m:IsShown() and m:IsMouseOver())
                            or (m2 and m2:IsShown() and m2:IsMouseOver())
                            or (m3 and m3:IsShown() and m3:IsMouseOver())
                        if not self:IsMouseOver() and not (cogPopupOwner and cogPopupOwner:IsMouseOver()) and not overMenu then
                            self:Hide()
                        end
                    end
                    wasDown = down
                end

                pf:SetScript("OnHide", function(self)
                    self:SetScript("OnUpdate", nil)
                    local owner = cogPopupOwner
                    cogPopupOwner = nil
                    -- MakeCogIcon/MakeTextCogIcon buttons have no _euiCogState.
                    if owner and owner._euiCogState then owner._euiCogState()
                    elseif owner then owner:SetAlpha(0.4) end
                end)

                if EllesmereUI._mainFrame then
                    EllesmereUI._mainFrame:HookScript("OnHide", function()
                        if pf:IsShown() then pf:Hide() end
                    end)
                end

                cogPopup = pf
            end

            -- Toggle off if same icon clicked again
            if cogPopupOwner == anchorBtn and cogPopup:IsShown() then
                cogPopup:Hide()
                return
            end

            -- Wire getters/setters
            cogPopup._xGet = opts.xGet; cogPopup._xSet = opts.xSet
            cogPopup._yGet = opts.yGet; cogPopup._ySet = opts.ySet
            cogPopup._titleFS:SetText(EllesmereUI.L(opts.title))
            local prevOwner = cogPopupOwner
            cogPopupOwner = anchorBtn
            if prevOwner and prevOwner._euiCogState then prevOwner._euiCogState() end

            -- Show/hide size row and adjust height
            local hasSize = opts.sizeGet ~= nil
            local hasWidth = opts.widthGet ~= nil
            local hasSpacing = opts.spacingGet ~= nil
            local hasGrowth = opts.growthGet ~= nil
            local hasToggle = opts.toggleGet ~= nil
            local hasCrop = opts.cropGet ~= nil
            local hasWrap = opts.wrapGet ~= nil
            local hasToggle2 = opts.toggle2Get ~= nil
            local hasDropdown2 = opts.dropdown2Get ~= nil
            local hasRaiseStrata = opts.raiseStrataGet ~= nil
            local hasStrata = opts.strataGet ~= nil
            local hasCropPct = opts.cropPctGet ~= nil
            if hasSize then
                -- Rebuild size slider if range changed
                local sStep = opts.sizeStep or 1
                if cogPopup._curMin ~= opts.sizeMin or cogPopup._curMax ~= opts.sizeMax or cogPopup._curStep ~= sStep then
                    if cogPopup._sTrack then cogPopup._sTrack:Hide(); cogPopup._sTrack:SetParent(nil) end
                    if cogPopup._sValBox then cogPopup._sValBox:Hide(); cogPopup._sValBox:SetParent(nil) end
                    local sTrack, sValBox = EllesmereUI.BuildSliderCore(cogPopup, cogPopup._SLIDER_W, 4, 12, 34, 24, 11, EllesmereUI.SL_INPUT_A,
                        opts.sizeMin, opts.sizeMax, sStep,
                        function() return cogPopup._sGet and cogPopup._sGet() or 0 end,
                        function(v) if cogPopup._sSet then cogPopup._sSet(v) end end, true)
                    sTrack:ClearAllPoints(); sTrack:SetPoint("TOPLEFT", cogPopup, "TOPLEFT", cogPopup._SLIDER_LEFT, cogPopup._S_ROW_Y - (cogPopup._SLIDER_H - 20) / 2)
                    sValBox:ClearAllPoints(); sValBox:SetPoint("TOPRIGHT", cogPopup, "TOPRIGHT", -cogPopup._SIDE_PAD, cogPopup._S_ROW_Y)
                    cogPopup._sTrack = sTrack; cogPopup._sValBox = sValBox
                    cogPopup._curMin = opts.sizeMin; cogPopup._curMax = opts.sizeMax; cogPopup._curStep = sStep
                end
                cogPopup._sGet = opts.sizeGet; cogPopup._sSet = opts.sizeSet
                cogPopup._sLabel:SetText(opts.sizeLabel or EllesmereUI.L("Size"))
                cogPopup._sLabel:Show()
                if cogPopup._sTrack then cogPopup._sTrack:Show() end
                if cogPopup._sValBox then cogPopup._sValBox:Show() end
            else
                cogPopup._sLabel:Hide()
                if cogPopup._sTrack then cogPopup._sTrack:Hide() end
                if cogPopup._sValBox then cogPopup._sValBox:Hide() end
            end

            -- Show/hide spacing row
            if hasSpacing then
                cogPopup._spGet = opts.spacingGet
                cogPopup._spSet = opts.spacingSet
                cogPopup._spLabel:Show()
                cogPopup._spTrack:Show()
                cogPopup._spValBox:Show()
            else
                cogPopup._spGet = nil
                cogPopup._spSet = nil
                cogPopup._spLabel:Hide()
                cogPopup._spTrack:Hide()
                cogPopup._spValBox:Hide()
            end

            -- Show/hide width % row
            if hasWidth then
                cogPopup._wGet = opts.widthGet
                cogPopup._wSet = opts.widthSet
                cogPopup._wLabel:SetText(EllesmereUI.L(opts.widthLabel or "Width %"))
                cogPopup._wLabel:Show()
                cogPopup._wTrack:Show()
                cogPopup._wValBox:Show()
                if cogPopup._wHover then cogPopup._wHover:Show() end
            else
                cogPopup._wGet = nil
                cogPopup._wSet = nil
                cogPopup._wLabel:Hide()
                cogPopup._wTrack:Hide()
                cogPopup._wValBox:Hide()
                if cogPopup._wHover then cogPopup._wHover:Hide() end
            end

            -- Show/hide growth row (a dropdown)
            if hasGrowth then
                cogPopup._growthGet = opts.growthGet
                cogPopup._growthSet = opts.growthSet
                -- Refill the dropdown's option map + order from this cog's values (mutated in place so captured tables stay current).
                local vals = opts.growthValues  -- { { value, label }, ... }
                wipe(cogPopup._growthValues)
                wipe(cogPopup._growthOrder)
                if vals then
                    for _, entry in ipairs(vals) do
                        cogPopup._growthValues[entry.value] = entry.label
                        cogPopup._growthOrder[#cogPopup._growthOrder + 1] = entry.value
                    end
                end
                if cogPopup._gDD then
                    -- Rebuild the menu from the refilled tables and refresh the label.
                    if cogPopup._gDD._invalidateMenu then cogPopup._gDD._invalidateMenu() end
                    cogPopup._gDD:Show()
                end
                -- growthLabel: an element can reuse this dropdown row for its own setting.
                cogPopup._gLabel:SetText(EllesmereUI.L(opts.growthLabel or "Grow"))
                cogPopup._gLabel:Show()
            else
                cogPopup._growthGet = nil
                cogPopup._growthSet = nil
                cogPopup._gLabel:Hide()
                if cogPopup._gDD then cogPopup._gDD:Hide() end
            end

            -- Show/hide toggle row (shares the G_ROW_Y slot with Grow)
            if hasToggle then
                cogPopup._toggleGet = opts.toggleGet
                cogPopup._toggleSet = opts.toggleSet
                cogPopup._tLabel:SetText(EllesmereUI.L(opts.toggleLabel or ""))
                cogPopup._tLabel:Show()
                cogPopup._tToggle:Show()
                if cogPopup._toggleSnap then cogPopup._toggleSnap() end
            else
                cogPopup._toggleGet = nil
                cogPopup._toggleSet = nil
                cogPopup._tLabel:Hide()
                cogPopup._tToggle:Hide()
            end

            -- Show/hide Cropped Icons row (its own row, below Grow when present)
            if hasCrop then
                cogPopup._cropGet = opts.cropGet
                cogPopup._cropSet = opts.cropSet
                cogPopup._cropLabel:Show()
                cogPopup._cropToggle:Show()
                if cogPopup._cropToggleSnap then cogPopup._cropToggleSnap() end
            else
                cogPopup._cropGet = nil
                cogPopup._cropSet = nil
                cogPopup._cropLabel:Hide()
                cogPopup._cropToggle:Hide()
            end

            -- Show/hide Adjust Crop row (slider, directly below Cropped Icons)
            if hasCropPct then
                cogPopup._cropPctGet = opts.cropPctGet
                cogPopup._cropPctSet = opts.cropPctSet
                cogPopup._cropPctLabel:Show()
                cogPopup._cropPctTrack:Show()
                cogPopup._cropPctValBox:Show()
                cogPopup._cropPctHover:Show()
            else
                cogPopup._cropPctGet = nil
                cogPopup._cropPctSet = nil
                cogPopup._cropPctLabel:Hide()
                cogPopup._cropPctTrack:Hide()
                cogPopup._cropPctValBox:Hide()
                cogPopup._cropPctHover:Hide()
                cogPopup._cropPctBlock:Hide()
            end

            -- Show/hide Wrap row (its own row, like Cropped Icons)
            if hasWrap then
                cogPopup._wrapGet = opts.wrapGet
                cogPopup._wrapSet = opts.wrapSet
                -- wrapLabel/wrapTooltip: an element can reuse this toggle row for its own setting.
                cogPopup._wrapLabel:SetText(EllesmereUI.L(opts.wrapLabel or "Wrap"))
                cogPopup._wrapTip = opts.wrapTooltip
                cogPopup._wrapLabel:Show()
                cogPopup._wrapToggle:Show()
                if cogPopup._wrapToggleSnap then cogPopup._wrapToggleSnap() end
                if cogPopup._wrapHover then cogPopup._wrapHover:Show() end
            else
                cogPopup._wrapGet = nil
                cogPopup._wrapSet = nil
                cogPopup._wrapLabel:Hide()
                cogPopup._wrapToggle:Hide()
                if cogPopup._wrapHover then cogPopup._wrapHover:Hide() end
            end

            -- Show/hide the second toggle row
            if hasToggle2 then
                cogPopup._toggle2Get = opts.toggle2Get
                cogPopup._toggle2Set = opts.toggle2Set
                cogPopup._t2Label:SetText(EllesmereUI.L(opts.toggle2Label or ""))
                cogPopup._t2Label:Show()
                cogPopup._t2Toggle:Show()
                if cogPopup._t2ToggleSnap then cogPopup._t2ToggleSnap() end
            else
                cogPopup._toggle2Get = nil
                cogPopup._toggle2Set = nil
                cogPopup._t2Label:Hide()
                cogPopup._t2Toggle:Hide()
            end

            -- Show/hide the second dropdown row ({ { value, label }, ... } like Grow)
            if hasDropdown2 then
                cogPopup._dd2Get = opts.dropdown2Get
                cogPopup._dd2Set = opts.dropdown2Set
                wipe(cogPopup._dd2Values)
                wipe(cogPopup._dd2Order)
                for _, entry in ipairs(opts.dropdown2Values or {}) do
                    cogPopup._dd2Values[entry.value] = entry.label
                    cogPopup._dd2Order[#cogPopup._dd2Order + 1] = entry.value
                end
                if cogPopup._d2DD._invalidateMenu then cogPopup._d2DD._invalidateMenu() end
                cogPopup._d2DD:Show()
                cogPopup._d2Label:SetText(EllesmereUI.L(opts.dropdown2Label or ""))
                cogPopup._d2Label:Show()
            else
                cogPopup._dd2Get = nil
                cogPopup._dd2Set = nil
                cogPopup._d2Label:Hide()
                cogPopup._d2DD:Hide()
            end

            -- Show/hide Raise Strata row (its own row, below all other toggles)
            if hasRaiseStrata then
                cogPopup._rsGet = opts.raiseStrataGet
                cogPopup._rsSet = opts.raiseStrataSet
                cogPopup._rsLabel:Show()
                cogPopup._rsToggle:Show()
                if cogPopup._rsToggleSnap then cogPopup._rsToggleSnap() end
                if cogPopup._rsHover then cogPopup._rsHover:Show() end
            else
                cogPopup._rsGet = nil
                cogPopup._rsSet = nil
                cogPopup._rsLabel:Hide()
                cogPopup._rsToggle:Hide()
                if cogPopup._rsHover then cogPopup._rsHover:Hide() end
            end

            -- Show/hide Strata row (standard strata dropdown, its own row)
            if hasStrata then
                cogPopup._strataGetFn = opts.strataGet
                cogPopup._strataSetFn = opts.strataSet
                if cogPopup._stDD then
                    -- Refresh the selected-value label for this cog's getter.
                    if cogPopup._stDD._invalidateMenu then cogPopup._stDD._invalidateMenu() end
                    cogPopup._stDD:Show()
                end
                cogPopup._stLabel:Show()
            else
                cogPopup._strataGetFn = nil
                cogPopup._strataSetFn = nil
                cogPopup._stLabel:Hide()
                if cogPopup._stDD then cogPopup._stDD:Hide() end
            end

            -- Row order: cogs passing sizeFirst (core position/core text) put Size at the top; others keep X, Y, Size, with Spacing (if present) following Size. Grow/toggle sit directly after the last data row, repositioned each show so they slide down when Spacing appears.
            do
                local p = cogPopup
                local SH, SLEFT, SPAD = p._SLIDER_H, p._SLIDER_LEFT, p._SIDE_PAD
                local GRH = p._GROWTH_ROW_H
                local function rowY(i) return p._ROW0 - (i - 1) * p._ROW_STEP end
                local function anchorRow(lbl, track, valBox, ry)
                    lbl:ClearAllPoints();  lbl:SetPoint("LEFT", p, "TOPLEFT", SPAD, ry - SH / 2)
                    if track  then track:ClearAllPoints();  track:SetPoint("TOPLEFT", p, "TOPLEFT", SLEFT, ry - 2) end
                    if valBox then valBox:ClearAllPoints(); valBox:SetPoint("TOPRIGHT", p, "TOPRIGHT", -SPAD, ry) end
                end
                -- Width % is intentionally NOT in this data-row sequence -- it's repositioned to the very bottom (below Wrap) further down, so it never sits between Size and X/Y.
                local seq = {}
                if hasSize and opts.sizeFirst then
                    seq[#seq + 1] = { p._sLabel, p._sTrack, p._sValBox }
                    if hasSpacing then seq[#seq + 1] = { p._spLabel, p._spTrack, p._spValBox } end
                    seq[#seq + 1] = { p._xLabel, p._xTrack, p._xValBox }
                    seq[#seq + 1] = { p._yLabel, p._yTrack, p._yValBox }
                else
                    seq[#seq + 1] = { p._xLabel, p._xTrack, p._xValBox }
                    seq[#seq + 1] = { p._yLabel, p._yTrack, p._yValBox }
                    if hasSize    then seq[#seq + 1] = { p._sLabel, p._sTrack, p._sValBox } end
                    if hasSpacing then seq[#seq + 1] = { p._spLabel, p._spTrack, p._spValBox } end
                end
                for i, r in ipairs(seq) do
                    anchorRow(r[1], r[2], r[3], rowY(i))
                end
                -- Growth/toggle rows sit directly after the data rows. A cog can pass BOTH (e.g. Rare/Quest Indicator on topleft/right: Grow + Show In Instances) -- the toggle then takes the row BELOW Grow.
                local nextY = rowY(#seq + 1)
                p._gLabel:ClearAllPoints()
                p._gLabel:SetPoint("LEFT", p, "TOPLEFT", SPAD, nextY - GRH / 2)
                if p._gDD then
                    -- Right-aligned like standard cog dropdowns; offsets divided by the control's scale so the scaled frame lands flush-right and vertically centered.
                    local ds = p._GROW_DD_SCALE or 1
                    p._gDD:ClearAllPoints()
                    p._gDD:SetPoint("RIGHT", p, "TOPRIGHT", -SPAD / ds, (nextY - GRH / 2) / ds)
                end
                local toggleY = hasGrowth and rowY(#seq + 2) or nextY
                p._tLabel:ClearAllPoints()
                p._tLabel:SetPoint("LEFT", p, "TOPLEFT", SPAD, toggleY - GRH / 2)
                p._tToggle:ClearAllPoints()
                p._tToggle:SetPoint("RIGHT", p, "TOPRIGHT", -SPAD, toggleY - GRH / 2)
                -- Second toggle: directly below the first, so related switches sit together.
                local t2Y = rowY(#seq + 1 + (hasGrowth and 1 or 0) + (hasToggle and 1 or 0))
                p._t2Label:ClearAllPoints()
                p._t2Label:SetPoint("LEFT", p, "TOPLEFT", SPAD, t2Y - GRH / 2)
                p._t2Toggle:ClearAllPoints()
                p._t2Toggle:SetPoint("RIGHT", p, "TOPRIGHT", -SPAD, t2Y - GRH / 2)
                -- Strata dropdown row: last row of the Grow/toggle band.
                local strataY = rowY(#seq + 1 + (hasGrowth and 1 or 0) + (hasToggle and 1 or 0) + (hasToggle2 and 1 or 0))
                p._stLabel:ClearAllPoints()
                p._stLabel:SetPoint("LEFT", p, "TOPLEFT", SPAD, strataY - GRH / 2)
                if p._stDD then
                    local sds = p._GROW_DD_SCALE or 1
                    p._stDD:ClearAllPoints()
                    p._stDD:SetPoint("RIGHT", p, "TOPRIGHT", -SPAD / sds, (strataY - GRH / 2) / sds)
                end
                -- Rows consumed by the Grow/toggle/second toggle/Strata band (0-4).
                local extraRows = (hasGrowth and 1 or 0) + (hasToggle and 1 or 0) + (hasToggle2 and 1 or 0) + (hasStrata and 1 or 0)
                -- Cropped Icons sits in its own row below the Grow/toggle band, else directly after the data rows.
                local cropY = rowY(#seq + 1 + extraRows)
                p._cropLabel:ClearAllPoints()
                p._cropLabel:SetPoint("LEFT", p, "TOPLEFT", SPAD, cropY - GRH / 2)
                p._cropToggle:ClearAllPoints()
                p._cropToggle:SetPoint("RIGHT", p, "TOPRIGHT", -SPAD, cropY - GRH / 2)
                -- Adjust Crop sits directly below Cropped Icons; anchorRow handles label+track+input box, then the disabled sync dims/blocks it per the toggle's state.
                if hasCropPct then
                    -- Manual anchoring instead of anchorRow: track starts 26px further right (built 26px narrower) so the wider "Adjust Crop" label never runs underneath, right edge stays aligned with other rows.
                    local cpy = rowY(#seq + 2 + extraRows)
                    p._cropPctLabel:ClearAllPoints()
                    p._cropPctLabel:SetPoint("LEFT", p, "TOPLEFT", SPAD, cpy - SH / 2)
                    p._cropPctTrack:ClearAllPoints()
                    p._cropPctTrack:SetPoint("TOPLEFT", p, "TOPLEFT", SLEFT + 26, cpy - 2)
                    p._cropPctValBox:ClearAllPoints()
                    p._cropPctValBox:SetPoint("TOPRIGHT", p, "TOPRIGHT", -SPAD, cpy)
                    if p._cropPctSyncDisabled then p._cropPctSyncDisabled() end
                end
                -- Wrap sits in its own row, like Cropped Icons: below the Grow/toggle band when present, else after the data rows (no cog uses both, so they never collide).
                local wrapY = rowY(#seq + 1 + extraRows)
                p._wrapLabel:ClearAllPoints()
                p._wrapLabel:SetPoint("LEFT", p, "TOPLEFT", SPAD, wrapY - GRH / 2)
                p._wrapToggle:ClearAllPoints()
                p._wrapToggle:SetPoint("RIGHT", p, "TOPRIGHT", -SPAD, wrapY - GRH / 2)
                -- Second dropdown: its own row below Cropped Icons/Adjust Crop/Wrap.
                local d2RowIndex = #seq + 1 + extraRows
                if hasCrop or hasWrap then d2RowIndex = d2RowIndex + 1 end
                if hasCropPct then d2RowIndex = d2RowIndex + 1 end
                local d2Y = rowY(d2RowIndex)
                p._d2Label:ClearAllPoints()
                p._d2Label:SetPoint("LEFT", p, "TOPLEFT", SPAD, d2Y - GRH / 2)
                local d2s = p._GROW_DD_SCALE or 1
                p._d2DD:ClearAllPoints()
                p._d2DD:SetPoint("RIGHT", p, "TOPRIGHT", -SPAD / d2s, (d2Y - GRH / 2) / d2s)
                -- Raise Strata sits in its own row, below the Grow/toggle band and Cropped Icons when present; Core Position cogs never use Wrap or Width %, so no collision there.
                if hasRaiseStrata then
                    local rsRowIndex = #seq + 1 + extraRows
                    if hasCrop or hasWrap then rsRowIndex = rsRowIndex + 1 end
                    if hasCropPct then rsRowIndex = rsRowIndex + 1 end
                    if hasDropdown2 then rsRowIndex = rsRowIndex + 1 end
                    local rsY = rowY(rsRowIndex)
                    p._rsLabel:ClearAllPoints()
                    p._rsLabel:SetPoint("LEFT", p, "TOPLEFT", SPAD, rsY - GRH / 2)
                    p._rsToggle:ClearAllPoints()
                    p._rsToggle:SetPoint("RIGHT", p, "TOPRIGHT", -SPAD, rsY - GRH / 2)
                end
                -- Width % is the very last row, below Wrap (and the Grow/toggle band/Cropped Icons when present); stays a slider row, so anchorRow handles label+track+box.
                if hasWidth then
                    local widthRowIndex = #seq + 1 + extraRows
                    if hasCrop or hasWrap then widthRowIndex = widthRowIndex + 1 end
                    if hasCropPct then widthRowIndex = widthRowIndex + 1 end
                    if hasDropdown2 then widthRowIndex = widthRowIndex + 1 end
                    anchorRow(p._wLabel, p._wTrack, p._wValBox, rowY(widthRowIndex))
                end
            end

            -- Compute height based on visible rows
            do
                local p = cogPopup
                local rowH = p._SLIDER_H
                local gap  = p._GAP
                local rows = 2  -- X + Y always present
                if hasSize   then rows = rows + 1 end
                if hasGrowth then rows = rows + 1 end
                local h = p._TOP_PAD + p._TITLE_H + p._TITLE_GAP
                for r = 1, rows do
                    h = h + gap + (r < rows and rowH or p._GROWTH_ROW_H)
                end
                -- Recalculated cleanly below (the loop above is approximate).
                h = p._TOP_PAD + p._TITLE_H + p._TITLE_GAP
                    + gap + rowH   -- X
                    + gap + rowH   -- Y
                if hasSize    then h = h + gap + rowH end
                if hasWidth   then h = h + gap + rowH end
                if hasSpacing then h = h + gap + rowH end
                if hasGrowth then h = h + gap + p._GROWTH_ROW_H end
                -- Toggle gets its own row (stacks below Grow when both present).
                if hasToggle then h = h + gap + p._GROWTH_ROW_H end
                -- Cropped Icons always occupies its own extra row.
                if hasCrop then h = h + gap + p._GROWTH_ROW_H end
                -- Adjust Crop (slider) occupies its own extra row below it.
                if hasCropPct then h = h + gap + rowH end
                -- Wrap occupies its own extra row.
                if hasWrap then h = h + gap + p._GROWTH_ROW_H end
                -- Second toggle gets its own row (below the first toggle).
                if hasToggle2 then h = h + gap + p._GROWTH_ROW_H end
                -- Second dropdown occupies its own extra row.
                if hasDropdown2 then h = h + gap + p._GROWTH_ROW_H end
                -- Raise Strata occupies its own extra row.
                if hasRaiseStrata then h = h + gap + p._GROWTH_ROW_H end
                -- Strata dropdown occupies its own extra row.
                if hasStrata then h = h + gap + p._GROWTH_ROW_H end
                h = h + p._TOP_PAD
                cogPopup:SetHeight(h)
            end

            -- Anchor above the icon
            cogPopup:ClearAllPoints()
            cogPopup:SetPoint("BOTTOM", anchorBtn, "TOP", 0, 6)

            -- Slide-up animation
            cogPopup:SetAlpha(0)
            cogPopup:Show()
            local elapsed = 0
            local ANIM_DUR = 0.15
            cogPopup:SetScript("OnUpdate", function(self, dt)
                elapsed = elapsed + dt
                local t = math.min(elapsed / ANIM_DUR, 1)
                self:SetAlpha(t)
                self:ClearAllPoints()
                self:SetPoint("BOTTOM", anchorBtn, "TOP", 0, 6 + (-8 * (1 - t)))
                if t >= 1 then
                    self:SetScript("OnUpdate", self._clickOutside)
                end
            end)

            EllesmereUI:RefreshPage()
        end

        local DISABLED_TIP = "This option requires an aura or indicator to be assigned"

        -- Per-kind slot Tracked Auras popup (12.1). Filter composition is INTERNAL (debuffs=Default, dcc=CC+Default, cc=CC; Default is Blizzard's
        -- nameplateShowPersonal curation): holds only Show All Debuffs (debuffs only) + INCLUDED/EXCLUDED lists (debuff side shared by debuffs/dcc; cc has its own pair). Storage/engine groups live in the containers file (ns.NPF_Root/Include/Exclude, NPC_ReloadAll).
        local NPF_KIND_TITLES = {
            debuffs = "Debuff Custom Spell IDs", cc = "CC Custom Spell IDs", dcc = "Debuffs + CC Custom Spell IDs",
        }
        local function ShowFilterPopup(kind)
            local root = ns.NPF_Root and ns.NPF_Root()
            if not root then return end
            -- List side + Show All availability: only debuffs has Show All; dcc is always CC+Default, cc is always CC.
            local side = (kind == "cc") and "cc" or "debuff"
            -- Any-caster OPT-OUTS for INCLUDED entries: default is Only My Casts (npincmine); flagged ids ride npinc.
            local function AnyMap()
                return ns.NPF_IncludeAny and ns.NPF_IncludeAny(side)
            end
            local function Reload()
                if ns.NPC_ReloadAll then ns.NPC_ReloadAll() end
            end
            EllesmereUI.ShowTrackedAurasPopup({
                eyebrow = EllesmereUI.L("NAMEPLATE AURA FILTERS"),
                title = NPF_KIND_TITLES[kind] or "Filters",
                fontPath = (EllesmereUI.GetFontPath("nameplates")) or DBVal("font"),
                includeGet = function() return ns.NPF_Include and ns.NPF_Include(side) end,
                excludeGet = function() return ns.NPF_Exclude and ns.NPF_Exclude(side) end,
                includePrompt = EllesmereUI.L("Enter the spell ID to always show on nameplates."),
                excludePrompt = EllesmereUI.L("Enter the spell ID to exclude from nameplates."),
                includeMine = { anyGet = AnyMap },
                -- Fresh adds default to Only My Casts; a spell migrating to the exclude list drops any stale flag.
                onAdd = function(id)
                    local am = AnyMap()
                    if am then am[id] = nil end
                end,
                onChanged = Reload,
                showAll = (kind == "debuffs") and {
                    label = EllesmereUI.L("Show All Debuffs"),
                    get = function() return root.debuffs and root.debuffs.all end,
                    set = function(v)
                        root.debuffs = root.debuffs or {}
                        root.debuffs.all = v
                        Reload()
                    end,
                } or nil,
            })
        end

        local function MakeCogIcon(row, regionKey, posKey, slotLabel)
            local rgn = row[regionKey]
            local btn = CreateFrame("Button", nil, rgn)
            btn:SetSize(26, 26)
            btn:SetPoint("RIGHT", rgn._control, "LEFT", -8, 0)
            rgn._lastInline = btn
            -- The core eyes anchor to THIS, not _lastInline: the tracked-auras
            -- link below becomes _lastInline but is HIDDEN for the raid marker
            -- and rare/quest slots (the only slots the eyes land on), and a
            -- hidden frame keeps its width -- anchoring left of it stranded
            -- the eye far from the cog.
            rgn._coreCogBtn = btn
            btn:SetFrameLevel(rgn:GetFrameLevel() + 5)
            btn:SetAlpha(0.4)
            local tex = btn:CreateTexture(nil, "OVERLAY")
            tex:SetAllPoints()
            tex:SetTexture(EllesmereUI.RESIZE_ICON)
            btn:SetScript("OnEnter", function(self)
                if CorePosOffDisabled(posKey) then
                    EllesmereUI.ShowWidgetTooltip(self, DISABLED_TIP)
                else
                    self:SetAlpha(0.7)
                end
            end)
            btn:SetScript("OnLeave", function(self)
                EllesmereUI.HideWidgetTooltip()
                if cogPopupOwner ~= self then self:SetAlpha(CorePosOffDisabled(posKey) and 0.15 or 0.4) end
            end)
            btn:SetScript("OnClick", function(self)
                if CorePosOffDisabled(posKey) then return end
                local sizeKey = posKey .. "SlotSize"
                local growthKey = posKey .. "SlotGrowth"
                local growthValues
                if posKey == "topleft" then
                    growthValues = {
                        { value = "left",  label = "Left"  },
                        { value = "right", label = "Right" },
                        { value = "up",    label = "Up"    },
                    }
                elseif posKey == "topright" then
                    growthValues = {
                        { value = "right", label = "Right" },
                        { value = "left",  label = "Left"  },
                        { value = "up",    label = "Up"    },
                    }
                end
                local opts = {
                    title = EllesmereUI.Lf("%1$s Slot Settings", EllesmereUI.L(slotLabel)),
                    xGet = function() return CorePosXGet(posKey) end,
                    xSet = function(v) CorePosXSet(posKey, v) end,
                    yGet = function() return CorePosYGet(posKey) end,
                    ySet = function(v) CorePosYSet(posKey, v) end,
                    sizeGet = function() return DBVal(sizeKey) or defaults[sizeKey] end,
                    sizeSet = function(v) DB()[sizeKey] = v; RefreshAllSlots(); UpdatePreview() end,
                    sizeMin = 10, sizeMax = 50,
                    sizeFirst = true,
                }
                if growthValues then
                    opts.growthGet    = function() return DBVal(growthKey) or defaults[growthKey] end
                    opts.growthSet    = function(v) DB()[growthKey] = v; RefreshAllSlots(); UpdatePreview() end
                    opts.growthValues = growthValues
                end
                -- Spacing + Cropped Icons: only for multi-icon aura elements (debuffs/buffs/CCs); both map the slot's assigned element to its per-element key.
                local element = GetElementAtPosition(posKey)
                local spacingKey, cropKey
                if element == "debuffs" then
                    spacingKey = "debuffSpacing"; cropKey = "debuffCropIcons"
                elseif element == "buffs" then
                    spacingKey = "buffSpacing"; cropKey = "buffCropIcons"
                elseif element == "ccs" then
                    spacingKey = "ccSpacing"; cropKey = "ccCropIcons"
                end
                if spacingKey then
                    opts.spacingGet = function() return DBVal(spacingKey) or defaults[spacingKey] end
                    opts.spacingSet = function(v) DB()[spacingKey] = v; RefreshAllSlots(); UpdatePreview() end
                end
                if cropKey then
                    opts.cropGet = function() return DBVal(cropKey) or defaults[cropKey] end
                    opts.cropSet = function(v) DB()[cropKey] = v; RefreshAllSlots(); UpdatePreview() end
                    -- Adjust Crop: per-side trim percentage for the cropped mode.
                    local cropPctKey = (element == "debuffs" and "debuffCropPercent")
                        or (element == "buffs" and "buffCropPercent")
                        or "ccCropPercent"
                    opts.cropPctGet = function() return DBVal(cropPctKey) or 10 end
                    opts.cropPctSet = function(v) DB()[cropPctKey] = v; RefreshAllSlots(); UpdatePreview() end
                end
                local borderKey
                if element == "debuffs" then
                    borderKey = "hideDebuffIconBorder"
                elseif element == "buffs" then
                    borderKey = "hideBuffIconBorder"
                elseif element == "ccs" then
                    borderKey = "hideCCIconBorder"
                end
                -- Blizzard Style: the stock aura ring replaces the 1px border,
                -- so the toggle has nothing to switch (the page banner says why).
                if borderKey and not EllesmereUI.BlizzStyle.Get("nameplates") then
                    opts.toggleLabel = "Hide Border"
                    opts.toggleGet = function()
                        local v = DBVal(borderKey)
                        if v == nil then return false end
                        return v and true or false
                    end
                    opts.toggleSet = function(v)
                        DB()[borderKey] = v and true or false
                        -- Full settings pass: RefreshAllSlots repositions but
                        -- never re-runs ApplyAppearance, so without this the
                        -- live slot borders only catch up on plate recycle
                        -- (and the container styles ride NPC_ReloadAll).
                        if ns.RefreshAllSettings then ns.RefreshAllSettings() end
                        RefreshAllSlots()
                        UpdatePreview()
                    end
                end
                -- Rare/Quest Indicator: "Show In Instances" lifts the open-world-only gates (UpdateClassification render gate + IsQuestMob's tooltip-scan gate); RefreshQuestObjective wipes quest-mob caches AND re-runs UpdateClassification everywhere.
                if element == "classification" or element == "classfaction" then
                    opts.toggleLabel = "Show In Instances"
                    opts.toggleGet = function() return DBVal("classificationShowInInstances") == true end
                    opts.toggleSet = function(v)
                        DB().classificationShowInInstances = v and true or false
                        if ns.RefreshQuestObjective then ns.RefreshQuestObjective() end
                        UpdatePreview()
                    end
                end
                -- Rare/Quest + Faction: Show In Instances (toggle row), Opposite Faction
                -- Only (second toggle row), Players Only (Wrap row), PvP Flag (Grow row).
                if element == "classfaction" then
                    local function refresh()
                        RefreshAllSlots()
                        UpdatePreview()
                    end
                    opts.dropdown2Label = "Icon Style"
                    opts.dropdown2Values = {}
                    for _, k in ipairs(EllesmereUI.FACTION_ART_ORDER) do
                        opts.dropdown2Values[#opts.dropdown2Values + 1] = { value = k, label = EllesmereUI.FACTION_ART_LABELS[k] }
                    end
                    opts.dropdown2Get = function() return DBVal("factionStyle") or defaults.factionStyle end
                    opts.dropdown2Set = function(v) DB().factionStyle = v; refresh() end
                    opts.toggle2Label = "Opposite Faction Only"
                    opts.toggle2Get = function() return DBVal("factionOppositeOnly") == true end
                    opts.toggle2Set = function(v) DB().factionOppositeOnly = v and true or false; refresh() end
                    opts.wrapLabel = "Players Only"
                    opts.wrapTooltip = "Hide the faction badge on faction NPCs such as guards."
                    opts.wrapGet = function() return DBVal("factionPlayersOnly") == true end
                    opts.wrapSet = function(v) DB().factionPlayersOnly = v and true or false; refresh() end
                    opts.growthLabel = "PvP Flag"
                    opts.growthValues = {
                        { value = "dim",    label = "Dim Unflagged" },
                        { value = "only",   label = "Flagged Only"  },
                        { value = "ignore", label = "Ignore"        },
                    }
                    opts.growthGet = function() return DBVal("factionPvP") or defaults.factionPvP end
                    opts.growthSet = function(v) DB().factionPvP = v; refresh() end
                end
                -- Faction: Opposite Faction Only (toggle row), Players Only (the Wrap row)
                -- and PvP Flag (the Grow dropdown; a single badge has nothing to grow).
                if element == "faction" then
                    local function refresh()
                        RefreshAllSlots()
                        UpdatePreview()
                    end
                    opts.dropdown2Label = "Icon Style"
                    opts.dropdown2Values = {}
                    for _, k in ipairs(EllesmereUI.FACTION_ART_ORDER) do
                        opts.dropdown2Values[#opts.dropdown2Values + 1] = { value = k, label = EllesmereUI.FACTION_ART_LABELS[k] }
                    end
                    opts.dropdown2Get = function() return DBVal("factionStyle") or defaults.factionStyle end
                    opts.dropdown2Set = function(v) DB().factionStyle = v; refresh() end
                    opts.toggleLabel = "Opposite Faction Only"
                    opts.toggleGet = function() return DBVal("factionOppositeOnly") == true end
                    opts.toggleSet = function(v) DB().factionOppositeOnly = v and true or false; refresh() end
                    opts.wrapLabel = "Players Only"
                    opts.wrapTooltip = "Hide the faction badge on faction NPCs such as guards."
                    opts.wrapGet = function() return DBVal("factionPlayersOnly") == true end
                    opts.wrapSet = function(v) DB().factionPlayersOnly = v and true or false; refresh() end
                    opts.growthLabel = "PvP Flag"
                    opts.growthValues = {
                        { value = "dim",    label = "Dim Unflagged" },
                        { value = "only",   label = "Flagged Only"  },
                        { value = "ignore", label = "Ignore"        },
                    }
                    opts.growthGet = function() return DBVal("factionPvP") or defaults.factionPvP end
                    opts.growthSet = function(v) DB().factionPvP = v; refresh() end
                end
                -- Raise Strata: bumps whatever element occupies this slot one strata level up so it renders above the rest of the plate.
                local rsKey = posKey .. "SlotRaiseStrata"
                opts.raiseStrataGet = function() return DBVal(rsKey) and true or false end
                opts.raiseStrataSet = function(v) DB()[rsKey] = v and true or false; RefreshAllSlots(); UpdatePreview() end
                ShowCogPopup(self, opts)
            end)
            EllesmereUI.RegisterWidgetRefresh(function()
                local off = CorePosOffDisabled(posKey)
                btn:SetAlpha(off and 0.15 or (cogPopupOwner == btn and 0.7 or 0.4))
            end)
            if CorePosOffDisabled(posKey) then btn:SetAlpha(0.15) end

            -- Edit Tracked Auras (slot filters): accent link left of the cog when this row holds a debuff-side aura element, opens the per-kind filter popup; refreshes on the same widget-refresh channel as the cog alpha.
                local link = CreateFrame("Button", nil, rgn)
                link:SetFrameLevel(rgn:GetFrameLevel() + 5)
                local lfp = (EllesmereUI.GetFontPath("nameplates")) or DBVal("font")
                local lfs = link:CreateFontString(nil, "OVERLAY")
                lfs:SetFont(lfp, 12, "")
                local ar, ag, ab = 1, 0.82, 0.30
                if EllesmereUI.GetAccentColor then ar, ag, ab = EllesmereUI.GetAccentColor() end
                lfs:SetTextColor(ar, ag, ab)
                lfs:SetAlpha(0.85)
                lfs:SetPoint("CENTER")
                lfs:SetText(EllesmereUI.L("Edit Tracked Auras"))
                link:SetSize(lfs:GetStringWidth() + 6, 16)
                link:SetPoint("RIGHT", btn, "LEFT", -6, 0)
                rgn._lastInline = link
                local function LinkKind()
                    local el = GetElementAtPosition(posKey)
                    if el == "debuffs" then return "debuffs"
                    elseif el == "ccs" then return "cc"
                    elseif el == "debuffsccs" then return "dcc" end
                end
                local function UpdLink()
                    local k = LinkKind()
                    link:SetShown(k ~= nil)
                    if k then
                        -- CC slots track only CC, so the link says so.
                        lfs:SetText(EllesmereUI.L(k == "cc" and "Edit Tracked CC" or "Edit Tracked Auras"))
                        link:SetSize(lfs:GetStringWidth() + 6, 16)
                    end
                end
                link:SetScript("OnEnter", function() lfs:SetAlpha(1) end)
                link:SetScript("OnLeave", function() lfs:SetAlpha(0.85) end)
                link:SetScript("OnClick", function()
                    local k = LinkKind()
                    if k then ShowFilterPopup(k) end
                end)
                EllesmereUI.RegisterWidgetRefresh(UpdLink)
                UpdLink()
            return btn
        end

        parent._showRowDivider = true

        -- Row 1: Top | Right
        coreRow1, h = W:DualRow(parent, y,
            { type="dropdown", text="Top",
              values = coreElementValues, order = coreElementOrder,
              getValue = function() return GetElementAtPosition("top") end,
              setValue = function(v) SetElementAtPosition("top", v); RefreshAllSlots(); optState.RefreshCoreEyes() end,
              disabled = function() return CorePosOffDisabled("top") end,
              disabledTooltip = "This option requires an aura or indicator to be assigned", rawTooltip = true,
              labelOnlyDisabled = true },
            { type="dropdown", text="Right",
              values = coreElementValues, order = coreElementOrder,
              getValue = function() return GetElementAtPosition("right") end,
              setValue = function(v) SetElementAtPosition("right", v); RefreshAllSlots(); optState.RefreshCoreEyes() end,
              disabled = function() return CorePosOffDisabled("right") end,
              disabledTooltip = "This option requires an aura or indicator to be assigned", rawTooltip = true,
              labelOnlyDisabled = true });  y = y - h
        if not EllesmereUI._prebuilding then
        MakeCogIcon(coreRow1, "_leftRegion",  "top",      "Top")
        MakeCogIcon(coreRow1, "_rightRegion", "right",    "Right")
        end

        -- Row 2: Left | Top Right
        coreRow2, h = W:DualRow(parent, y,
            { type="dropdown", text="Left",
              values = coreElementValues, order = coreElementOrder,
              getValue = function() return GetElementAtPosition("left") end,
              setValue = function(v) SetElementAtPosition("left", v); RefreshAllSlots(); optState.RefreshCoreEyes() end,
              disabled = function() return CorePosOffDisabled("left") end,
              disabledTooltip = "This option requires an aura or indicator to be assigned", rawTooltip = true,
              labelOnlyDisabled = true },
            { type="dropdown", text="Top Right",
              values = coreElementValues, order = coreElementOrder,
              getValue = function() return GetElementAtPosition("topright") end,
              setValue = function(v) SetElementAtPosition("topright", v); RefreshAllSlots(); optState.RefreshCoreEyes() end,
              disabled = function() return CorePosOffDisabled("topright") end,
              disabledTooltip = "This option requires an aura or indicator to be assigned", rawTooltip = true,
              labelOnlyDisabled = true });  y = y - h
        if not EllesmereUI._prebuilding then
        MakeCogIcon(coreRow2, "_leftRegion",  "left",     "Left")
        MakeCogIcon(coreRow2, "_rightRegion", "topright", "Top Right")
        end

        -- Row 3: Top Left | Bottom
        coreRow3, h = W:DualRow(parent, y,
            { type="dropdown", text="Top Left",
              values = coreElementValues, order = coreElementOrder,
              getValue = function() return GetElementAtPosition("topleft") end,
              setValue = function(v) SetElementAtPosition("topleft", v); RefreshAllSlots(); optState.RefreshCoreEyes() end,
              disabled = function() return CorePosOffDisabled("topleft") end,
              disabledTooltip = "This option requires an aura or indicator to be assigned", rawTooltip = true,
              labelOnlyDisabled = true },
            { type="dropdown", text="Bottom",
              values = coreElementValues, order = coreElementOrder,
              getValue = function() return GetElementAtPosition("bottom") end,
              setValue = function(v) SetElementAtPosition("bottom", v); RefreshAllSlots(); optState.RefreshCoreEyes() end,
              disabled = function() return CorePosOffDisabled("bottom") end,
              disabledTooltip = "This option requires an aura or indicator to be assigned", rawTooltip = true,
              labelOnlyDisabled = true });  y = y - h
        if not EllesmereUI._prebuilding then
        MakeCogIcon(coreRow3, "_leftRegion", "topleft", "Top Left")
        MakeCogIcon(coreRow3, "_rightRegion", "bottom", "Bottom")
        end

        -- Map each position to { row, regionKey } for eye icon anchoring
        local posToRegion = {
            top      = { coreRow1, "_leftRegion" },
            right    = { coreRow1, "_rightRegion" },
            left     = { coreRow2, "_leftRegion" },
            topright = { coreRow2, "_rightRegion" },
            topleft  = { coreRow3, "_leftRegion" },
            bottom   = { coreRow3, "_rightRegion" },
        }

        -- Eye icon that follows whichever Core Positions dropdown has "Raid Marker"
        do
            local EYE_VISIBLE   = EllesmereUI.EYE_VISIBLE_ICON
            local EYE_INVISIBLE = EllesmereUI.EYE_INVISIBLE_ICON
            local eyeBtn = CreateFrame("Button", nil, parent)
            eyeBtn:SetSize(26, 26)
            eyeBtn:SetFrameLevel(parent:GetFrameLevel() + 10)
            eyeBtn:SetAlpha(0.4)
            local eyeTex = eyeBtn:CreateTexture(nil, "OVERLAY")
            eyeTex:SetAllPoints()
            local function RefreshIcon()
                eyeTex:SetTexture(optState.showRaidMarkerPreview and EYE_INVISIBLE or EYE_VISIBLE)
            end
            RefreshIcon()
            eyeBtn:SetScript("OnClick", function()
                optState.showRaidMarkerPreview = not optState.showRaidMarkerPreview
                RefreshIcon()
                UpdatePreview()
            end)
            eyeBtn:SetScript("OnEnter", function(self)
                self:SetAlpha(0.7)
                EllesmereUI.ShowWidgetTooltip(self, "Show/Hide on Preview", { width = 155 })
            end)
            eyeBtn:SetScript("OnLeave", function(self)
                self:SetAlpha(0.4)
                EllesmereUI.HideWidgetTooltip()
            end)
            _refreshRaidMarkerEyePos = function()
                local rmPos = DBVal("raidMarkerPos") or defaults.raidMarkerPos
                local info = posToRegion[rmPos]
                if not info or rmPos == "none" then
                    eyeBtn:Hide()
                    return
                end
                local rgn = info[1][info[2]]
                eyeBtn:ClearAllPoints()
                eyeBtn:SetParent(rgn)
                -- Anchor next to the cog icon (_coreCogBtn), never _lastInline:
                -- that is the tracked-auras link, hidden-but-still-wide on the
                -- slots this eye lands on, which stranded the eye far left.
                eyeBtn:SetPoint("RIGHT", rgn._coreCogBtn or rgn._control, "LEFT", -8, 0)
                eyeBtn:SetFrameLevel(rgn:GetFrameLevel() + 5)
                eyeBtn:Show()
            end
            _refreshRaidMarkerEyePos()
        end

        -- Eye icon that follows whichever Core Positions dropdown has "Rare/Quest Indicator"
        do
            local EYE_VISIBLE   = EllesmereUI.EYE_VISIBLE_ICON
            local EYE_INVISIBLE = EllesmereUI.EYE_INVISIBLE_ICON
            local eyeBtn = CreateFrame("Button", nil, parent)
            eyeBtn:SetSize(26, 26)
            eyeBtn:SetFrameLevel(parent:GetFrameLevel() + 10)
            eyeBtn:SetAlpha(0.4)
            local eyeTex = eyeBtn:CreateTexture(nil, "OVERLAY")
            eyeTex:SetAllPoints()
            local function RefreshIcon()
                eyeTex:SetTexture(optState.showClassificationPreview and EYE_INVISIBLE or EYE_VISIBLE)
            end
            RefreshIcon()
            eyeBtn:SetScript("OnClick", function()
                optState.showClassificationPreview = not optState.showClassificationPreview
                RefreshIcon()
                UpdatePreview()
            end)
            eyeBtn:SetScript("OnEnter", function(self)
                self:SetAlpha(0.7)
                EllesmereUI.ShowWidgetTooltip(self, "Show/Hide on Preview", { width = 155 })
            end)
            eyeBtn:SetScript("OnLeave", function(self)
                self:SetAlpha(0.4)
                EllesmereUI.HideWidgetTooltip()
            end)
            _refreshClassificationEyePos = function()
                local clPos = DBVal("classificationSlot") or defaults.classificationSlot
                local info = posToRegion[clPos]
                if not info or clPos == "none" then
                    eyeBtn:Hide()
                    return
                end
                local rgn = info[1][info[2]]
                eyeBtn:ClearAllPoints()
                eyeBtn:SetParent(rgn)
                -- Anchor next to the cog icon (_coreCogBtn), never _lastInline:
                -- that is the tracked-auras link, hidden-but-still-wide on the
                -- slots this eye lands on, which stranded the eye far left.
                eyeBtn:SetPoint("RIGHT", rgn._coreCogBtn or rgn._control, "LEFT", -8, 0)
                eyeBtn:SetFrameLevel(rgn:GetFrameLevel() + 5)
                eyeBtn:Show()
            end
            _refreshClassificationEyePos()
        end

        _, h = W:Spacer(parent, y, 20);  y = y - h

        -----------------------------------------------------------------------
        --  CORE TEXT POSITIONS
        -----------------------------------------------------------------------
        local coreTextHeader
        coreTextHeader, h = W:SectionHeader(parent, "CORE TEXT POSITIONS", y);  y = y - h

        -- Subtitle hint next to the section header (same style as Core Positions)
        do
            local regions = { coreTextHeader:GetRegions() }
            for _, rgn in ipairs(regions) do
                if rgn:IsObjectType("FontString") and EllesmereUI.EnKey(rgn:GetText()) == "CORE TEXT POSITIONS" then
                    local sub = coreTextHeader:CreateFontString(nil, "OVERLAY")
                    sub:SetFont(rgn:GetFont())
                    sub:SetTextColor(1, 1, 1, 0.25)
                    sub:SetText(EllesmereUI.L("(one per slot)"))
                    sub:SetPoint("LEFT", rgn, "RIGHT", 6, 0)
                    break
                end
            end
        end

        local textElementValues = {
            enemyName            = "Enemy Name",
            levelName            = "Level | Name",
            nameLevel            = "Name | Level",
            level                = "Level",
            targetOfTarget       = "Target of Target",
            healthPercent        = "Health %",
            healthPercentNoSign  = "Health % (No Sign)",
            healthNumber         = "Health #",
            healthPctNum         = "Health % | #",
            healthNumPct         = "Health # | %",
            healthPctNumDash     = "Health % - #",
            healthNumPctDash     = "Health # - %",
            none                 = "None",
        }
        local textElementOrder = { "none", "---", "enemyName", "levelName", "nameLevel", "level", "targetOfTarget", "healthPercent", "healthPercentNoSign", "healthNumber", "healthPctNum", "healthNumPct", "healthPctNumDash", "healthNumPctDash" }

        local function TextSlotSetValue(slotKey, v)
            -- Target of Target starts in Class / Reaction colour whenever a slot newly
            -- takes it; the slot's custom swatch still switches it back.
            if v == "targetOfTarget" and DBVal(slotKey) ~= "targetOfTarget" then
                DB()[slotKey .. "ClassColor"] = true
            end
            SetTextElementAtSlot(slotKey, v)
            ns.RefreshAllSettings()
            UpdatePreview(); EllesmereUI:RefreshPage()
        end

        local function TextOffsetRefresh()
            ns.RefreshAllSettings()
            UpdatePreview()
        end

        -- Text slot X/Y offset helpers (parallel to CorePosXGet etc.)
        local function TextPosXGet(slotKey)
            return DBVal(slotKey .. "XOffset") or 0
        end
        local function TextPosYGet(slotKey)
            return DBVal(slotKey .. "YOffset") or 0
        end
        local function TextPosXSet(slotKey, v)
            DB()[slotKey .. "XOffset"] = v; TextOffsetRefresh()
        end
        local function TextPosYSet(slotKey, v)
            DB()[slotKey .. "YOffset"] = v; TextOffsetRefresh()
        end
        local function TextPosDisabled(slotKey)
            return DBVal(slotKey) == "none"
        end

        local TEXT_DISABLED_TIP = "This option requires a text to be assigned"

        local function MakeTextCogIcon(row, regionKey, slotKey, slotLabel)
            local rgn = row[regionKey]
            local btn = CreateFrame("Button", nil, rgn)
            btn:SetSize(26, 26)
            btn:SetPoint("RIGHT", rgn._lastInline or rgn._control, "LEFT", -9, 0)
            rgn._lastInline = btn
            btn:SetFrameLevel(rgn:GetFrameLevel() + 5)
            btn:SetAlpha(0.4)
            local tex = btn:CreateTexture(nil, "OVERLAY")
            tex:SetAllPoints()
            tex:SetTexture(EllesmereUI.RESIZE_ICON)
            btn:SetScript("OnEnter", function(self)
                if TextPosDisabled(slotKey) then
                    EllesmereUI.ShowWidgetTooltip(self, TEXT_DISABLED_TIP)
                else
                    self:SetAlpha(0.7)
                end
            end)
            btn:SetScript("OnLeave", function(self)
                EllesmereUI.HideWidgetTooltip()
                if cogPopupOwner ~= self then self:SetAlpha(TextPosDisabled(slotKey) and 0.15 or 0.4) end
            end)
            btn:SetScript("OnClick", function(self)
                if TextPosDisabled(slotKey) then return end
                local sizeKey = slotKey .. "Size"
                local cogOpts = {
                    title = EllesmereUI.Lf("%1$s Settings", EllesmereUI.L(slotLabel)),
                    xGet = function() return TextPosXGet(slotKey) end,
                    xSet = function(v) TextPosXSet(slotKey, v) end,
                    yGet = function() return TextPosYGet(slotKey) end,
                    ySet = function(v) TextPosYSet(slotKey, v) end,
                    sizeGet = function() return DBVal(sizeKey) or defaults[sizeKey] end,
                    sizeSet = function(v) DB()[sizeKey] = v; TextOffsetRefresh() end,
                    sizeMin = 6, sizeMax = 30,
                    sizeLabel = "Size",
                    sizeFirst = true,
                }
                -- Both name and health text here get Width % + Wrap (dedicated Wrap row). Name-family variants use the GLOBAL enemyName keys (one slot holds the name FontString at a time); health text uses PER-SLOT keys (100% = no clip) and keeps "Show % Decimal". The bottom slots never truncate, so they get neither.
                local bottomSlot = slotKey == "textSlotBottomLeft" or slotKey == "textSlotBottomRight"
                if ns.IsNameElement(DBVal(slotKey)) then
                    if not bottomSlot then
                        cogOpts.widthGet = function() return DBVal("enemyNameWidthPct") or defaults.enemyNameWidthPct end
                        cogOpts.widthSet = function(v) DB().enemyNameWidthPct = v; ns.RefreshAllSettings(); UpdatePreview() end
                        cogOpts.wrapGet = function() return DBVal("enemyNameWrap") == true end
                        cogOpts.wrapSet = function(v) DB().enemyNameWrap = v; ns.RefreshAllSettings(); UpdatePreview() end
                    end
                else
                    if not bottomSlot then
                        local widthKey = slotKey .. "WidthPct"
                        local wrapKey = slotKey .. "Wrap"
                        cogOpts.widthGet = function() return DBVal(widthKey) or 100 end
                        cogOpts.widthSet = function(v) DB()[widthKey] = v; ns.RefreshAllSettings(); UpdatePreview() end
                        cogOpts.wrapGet = function() return DBVal(wrapKey) == true end
                        cogOpts.wrapSet = function(v) DB()[wrapKey] = v; ns.RefreshAllSettings(); UpdatePreview() end
                    end
                    cogOpts.toggleLabel = "Show % Decimal"
                    cogOpts.toggleGet = function() return DBVal(slotKey .. "PctDecimal") == true end
                    cogOpts.toggleSet = function(v)
                        DB()[slotKey .. "PctDecimal"] = v
                        ns.RefreshAllSettings()
                        UpdatePreview()
                    end
                end
                -- Level text (alone or with the name): Level Difficulty Color takes the
                -- toggle row (the standalone level has no use for "Show % Decimal").
                local slotEl = DBVal(slotKey)
                if slotEl == "targetOfTarget" then
                    cogOpts.toggleLabel, cogOpts.toggleGet, cogOpts.toggleSet = nil, nil, nil
                elseif slotEl == "level" or slotEl == "levelName" or slotEl == "nameLevel" then
                    cogOpts.toggleLabel = "Level Text: Difficulty Color"
                    cogOpts.toggleGet = function() return DBVal("levelDifficultyColor") == true end
                    cogOpts.toggleSet = function(v)
                        DB().levelDifficultyColor = v and true or false
                        ns.RefreshAllSettings()
                        UpdatePreview()
                    end
                    cogOpts.toggle2Label = "Level Text: Include Friendly"
                    cogOpts.toggle2Get = function() return DBVal("levelDifficultyColorFriendly") == true end
                    cogOpts.toggle2Set = function(v)
                        DB().levelDifficultyColorFriendly = v and true or false
                        ns.RefreshAllSettings()
                        UpdatePreview()
                    end
                end
                -- WoW Forever: the name's format, while this slot shows a name or the
                -- Target of Target name. First and Last is stored as nil (the
                -- runtime's full-name path).
                if EllesmereUI.IS_FOREVER and (ns.IsNameElement(slotEl) or slotEl == "targetOfTarget") then
                    local nfKey = slotKey .. "NameFormat"
                    cogOpts.dropdown2Label = "Name Format"
                    cogOpts.dropdown2Values = {
                        { value = "first", label = "First Name" },
                        { value = "last",  label = "Last Name" },
                        { value = "full",  label = "First and Last" },
                    }
                    cogOpts.dropdown2Get = function() return DBVal(nfKey) or "full" end
                    cogOpts.dropdown2Set = function(v)
                        DB()[nfKey] = (v ~= "full") and v or nil
                        ns.RefreshAllSettings(); UpdatePreview()
                    end
                end
                -- Per-slot strata (partner request): standard strata dropdown,
                -- defaulting to the shared text tier's MEDIUM.
                cogOpts.strataGet = function() return DBVal(slotKey .. "Strata") or "MEDIUM" end
                cogOpts.strataSet = function(v)
                    DB()[slotKey .. "Strata"] = v
                    ns.RefreshAllSettings(); UpdatePreview()
                end
                ShowCogPopup(self, cogOpts)
            end)
            EllesmereUI.RegisterWidgetRefresh(function()
                local off = TextPosDisabled(slotKey)
                btn:SetAlpha(off and 0.15 or (cogPopupOwner == btn and 0.7 or 0.4))
            end)
            if TextPosDisabled(slotKey) then btn:SetAlpha(0.15) end
            return btn
        end

        parent._showRowDivider = true

        -- Custom colour swatch plus a Class / Reaction sample swatch to its left (the
        -- Target Arrows pair's order): the sample selects class mode (textSlot<X>ClassColor,
        -- the runtime paints enemy players by class and NPCs by the Hostile / Neutral name
        -- colours); clicking the inactive custom swatch only returns to custom mode, a
        -- second click opens the picker. The inactive swatch sits at 0.3; both drop to 0.15
        -- with the mouse off while the slot is None. The resize cog chains left of them.
        local function MakeTextColorSwatch(row, regionKey, slotKey, slotLabel)
            local rgn = row[regionKey]
            local colorKey = slotKey .. "Color"
            local modeKey = slotKey .. "ClassColor"
            local function getColor()
                local c = (DB() and DB()[colorKey]) or defaults[colorKey]
                return c.r, c.g, c.b
            end
            local function setColor(r, g, b)
                DB()[colorKey] = { r = r, g = g, b = b }
                ns.RefreshAllSettings()
                UpdatePreview()
            end
            local swatch, updateSwatch = EllesmereUI.BuildColorSwatch(rgn, rgn:GetFrameLevel() + 5, getColor, setColor, nil, 20)
            PP.Point(swatch, "RIGHT", rgn._control, "LEFT", -12, 0)
            -- The sample shows the player's own class colour; its self-registered colour
            -- accessor reads no setting (as with every class sample swatch).
            local classSwatch, updateClass = EllesmereUI.BuildColorSwatch(rgn, rgn:GetFrameLevel() + 5,
                function()
                    local _, ct = UnitClass("player")
                    local cc = ct and EllesmereUI.GetClassColor(ct)
                    if cc then return cc.r, cc.g, cc.b end
                    return 1, 1, 1
                end,
                function() end, nil, 20)
            PP.Point(classSwatch, "RIGHT", swatch, "LEFT", -8, 0)
            rgn._lastInline = classSwatch
            local function refreshSwatches()
                updateSwatch()
                updateClass()
                local off = TextPosDisabled(slotKey)
                local useClass = DBVal(modeKey) == true
                swatch:SetAlpha(off and 0.15 or (useClass and 0.3 or 1))
                classSwatch:SetAlpha(off and 0.15 or (useClass and 1 or 0.3))
                swatch:EnableMouse(not off)
                classSwatch:EnableMouse(not off)
            end
            local function setMode(v, src)
                DB()[modeKey] = v
                ns.RefreshAllSettings()
                -- Bespoke write: notify for Spec Overrides attribution before the rebuild.
                EllesmereUI._NotifySettingWrite(src)
                UpdatePreview(); EllesmereUI:RefreshPage()
            end
            local origClick = swatch:GetScript("OnClick")
            swatch:SetScript("OnClick", function(self, ...)
                if TextPosDisabled(slotKey) then return end
                if DBVal(modeKey) == true then setMode(false, self); return end
                if origClick then origClick(self, ...) end
            end)
            swatch:SetScript("OnEnter", function() EllesmereUI.ShowWidgetTooltip(swatch, EllesmereUI.L("Custom Color")) end)
            swatch:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
            classSwatch:SetScript("OnClick", function(self)
                if TextPosDisabled(slotKey) or DBVal(modeKey) == true then return end
                setMode(true, self)
            end)
            classSwatch:SetScript("OnEnter", function() EllesmereUI.ShowWidgetTooltip(classSwatch, EllesmereUI.L("Class / Reaction Color")) end)
            classSwatch:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
            -- The mode flag is written only by the bespoke clicks above, so the slot's
            -- Spec Overrides capture gets its own accessor for it.
            EllesmereUI.AddCaptureAccessor(rgn, {
                type = "toggle", text = slotLabel .. " Class / Reaction Color",
                getValue = function() return DBVal(modeKey) == true end,
                setValue = function(v)
                    DB()[modeKey] = v and true or false
                    ns.RefreshAllSettings()
                    UpdatePreview()
                end,
            })
            EllesmereUI.RegisterWidgetRefresh(refreshSwatches)
            refreshSwatches()
            return swatch
        end

        local textRow1, textRow2, textRow3

        -- Row 1: Top Text | Right Text
        textRow1, h = W:DualRow(parent, y,
            { type="dropdown", text="Top Text", values=textElementValues,
              getValue=function() return DBVal("textSlotTop") end,
              setValue=function(v) TextSlotSetValue("textSlotTop", v) end,
              order=textElementOrder,
              disabled=function() return DBVal("textSlotTop") == "none" end,
              disabledTooltip="This option requires a text to be assigned", rawTooltip=true,
              labelOnlyDisabled=true },
            { type="dropdown", text="Right Text", values=textElementValues,
              getValue=function() return DBVal("textSlotRight") end,
              setValue=function(v) TextSlotSetValue("textSlotRight", v) end,
              order=textElementOrder,
              disabled=function() return DBVal("textSlotRight") == "none" end,
              disabledTooltip="This option requires a text to be assigned", rawTooltip=true,
              labelOnlyDisabled=true,
              disabledValues=function(k) if ns.IsComboHealthText(k) and ns.IsNameElement(DBVal("textSlotCenter")) then return "Disabled when the Name/Level text is centered on the health bar due to overlapping text" end end });  y = y - h
        if not EllesmereUI._prebuilding then
        MakeTextColorSwatch(textRow1, "_leftRegion",  "textSlotTop",   "Top Text")
        MakeTextCogIcon(textRow1, "_leftRegion",  "textSlotTop",   "Top Text")
        MakeTextColorSwatch(textRow1, "_rightRegion", "textSlotRight", "Right Text")
        MakeTextCogIcon(textRow1, "_rightRegion", "textSlotRight", "Right Text")
        end

        -- Row 2: Left Text | Center Text
        textRow2, h = W:DualRow(parent, y,
            { type="dropdown", text="Left Text", values=textElementValues,
              getValue=function() return DBVal("textSlotLeft") end,
              setValue=function(v) TextSlotSetValue("textSlotLeft", v) end,
              order=textElementOrder,
              disabled=function() return DBVal("textSlotLeft") == "none" end,
              disabledTooltip="This option requires a text to be assigned", rawTooltip=true,
              labelOnlyDisabled=true,
              disabledValues=function(k) if ns.IsComboHealthText(k) and ns.IsNameElement(DBVal("textSlotCenter")) then return "Disabled when the Name/Level text is centered on the health bar due to overlapping text" end end },
            { type="dropdown", text="Center Text", values=textElementValues,
              getValue=function() return DBVal("textSlotCenter") end,
              setValue=function(v) TextSlotSetValue("textSlotCenter", v) end,
              order=textElementOrder,
              disabled=function() return DBVal("textSlotCenter") == "none" end,
              disabledTooltip="This option requires a text to be assigned", rawTooltip=true,
              labelOnlyDisabled=true });  y = y - h
        if not EllesmereUI._prebuilding then
        MakeTextColorSwatch(textRow2, "_leftRegion",  "textSlotLeft",   "Left Text")
        MakeTextCogIcon(textRow2, "_leftRegion",  "textSlotLeft",   "Left Text")
        MakeTextColorSwatch(textRow2, "_rightRegion", "textSlotCenter", "Center Text")
        MakeTextCogIcon(textRow2, "_rightRegion", "textSlotCenter", "Center Text")
        end

        -- Row 3: Bottom Left Text | Bottom Right Text (under the health bar's corners,
        -- below the cast bar while one shows)
        textRow3, h = W:DualRow(parent, y,
            { type="dropdown", text="Bottom Left Text", values=textElementValues,
              getValue=function() return DBVal("textSlotBottomLeft") end,
              setValue=function(v) TextSlotSetValue("textSlotBottomLeft", v) end,
              order=textElementOrder,
              disabled=function() return DBVal("textSlotBottomLeft") == "none" end,
              disabledTooltip="This option requires a text to be assigned", rawTooltip=true,
              labelOnlyDisabled=true },
            { type="dropdown", text="Bottom Right Text", values=textElementValues,
              getValue=function() return DBVal("textSlotBottomRight") end,
              setValue=function(v) TextSlotSetValue("textSlotBottomRight", v) end,
              order=textElementOrder,
              disabled=function() return DBVal("textSlotBottomRight") == "none" end,
              disabledTooltip="This option requires a text to be assigned", rawTooltip=true,
              labelOnlyDisabled=true });  y = y - h
        if not EllesmereUI._prebuilding then
        MakeTextColorSwatch(textRow3, "_leftRegion",  "textSlotBottomLeft",  "Bottom Left Text")
        MakeTextCogIcon(textRow3, "_leftRegion",  "textSlotBottomLeft",  "Bottom Left Text")
        MakeTextColorSwatch(textRow3, "_rightRegion", "textSlotBottomRight", "Bottom Right Text")
        MakeTextCogIcon(textRow3, "_rightRegion", "textSlotBottomRight", "Bottom Right Text")
        end

        _, h = W:Spacer(parent, y, 20);  y = y - h

        -----------------------------------------------------------------------
        --  HEALTH BAR
        -----------------------------------------------------------------------
        local healthBarHeader
        healthBarHeader, h = W:SectionHeader(parent, "HEALTH AND CAST BAR", y);  y = y - h

        local healthBarHeightRow
        healthBarHeightRow, h = W:DualRow(parent, y,
            { type="slider", text="Health Bar Width", min=100, max=BAR_W+100, step=1,
              getValue=function() return BAR_W + DBVal("healthBarWidth") end,
              setValue=function(v)
                local extra = v - BAR_W
                DB().healthBarWidth = extra
                -- Classic WoW UI: the cast bar's width and shift are derived
                -- from the footprint so the two borders stay edge to edge, so
                -- it re-lays out rather than taking the raw width.
                local classic = ns.NP_Classic and ns.NP_Classic()
                -- Pooled plates re-run their appearance pass at next spawn.
                ns._npAppearanceGen = (ns._npAppearanceGen or 0) + 1
                for _, plate in pairs(plates) do
                    PP.Width(plate.health, v)
                    PP.Width(plate.absorb, v)
                    if classic then
                        ns.LayoutCastBar(plate, v, ns.GetCastBarHeight())
                    else
                        PP.Width(plate.cast, v)
                    end
                    plate:UpdateNameWidth()
                end
                if ns.ApplyNamePlateClickArea then ns.ApplyNamePlateClickArea() end
                UpdatePreview()
              end },
            { type="slider", text="Health Bar Height", min=6, max=50, step=1,
              getValue=function() return DBVal("healthBarHeight") end,
              setValue=function(v)
                DB().healthBarHeight = v
                -- Classic WoW UI: the border scales with the bar, and the cast
                -- bar's drop and width are derived from the health bar's
                -- height, so both re-run here.
                local classic = ns.NP_Classic and ns.NP_Classic()
                local forever = ns.NP_Forever()
                -- Pooled plates re-run their appearance pass (and with it
                -- the border and level box) at next spawn.
                ns._npAppearanceGen = (ns._npAppearanceGen or 0) + 1
                for _, plate in pairs(plates) do
                    PP.Height(plate.health, v)
                    if classic then
                        ns.NP_ApplyClassicHealthArt(plate, v)
                        ns.LayoutCastBar(plate, ns.GetHealthBarWidth(), ns.GetCastBarHeight())
                    elseif forever then
                        -- WoW Forever: the level box follows the bar's height.
                        ns.NP_ApplyForeverLevelBox(plate, v)
                    end
                end
                if ns.ApplyNamePlateClickArea then ns.ApplyNamePlateClickArea() end
                UpdatePreview()
              end });  y = y - h

        local function castIconOff() return DB() and DB().showCastIcon == false end

        local castBarHeightRow
        castBarHeightRow, h = W:DualRow(parent, y,
            { type="slider", text="Cast Bar Height", min=10, max=40, step=1,
              getValue=function() return DBVal("castBarHeight") or defaults.castBarHeight end,
              setValue=function(v)
                DB().castBarHeight = v
                local barW = ns.GetHealthBarWidth()
                for _, plate in pairs(plates) do
                    ns.LayoutCastBar(plate, barW, v)
                    ns.LayoutCastIcon(plate, v)
                    plate.castSpark:SetHeight(v)
                end
                UpdatePreview()
              end },
            { type="toggle", text="Spell Icon",
              getValue=function()
                local db = DB()
                if db and db.showCastIcon ~= nil then return db.showCastIcon end
                return defaults.showCastIcon
              end,
              setValue=function(v)
                DB().showCastIcon = v
                ns.RefreshAllSettings()
                UpdatePreview()
                EllesmereUI:RefreshPage()
              end });  y = y - h
        local showCastIconRow = castBarHeightRow

        -- Inline cog on Spell Icon (right region) for Scale
        if not EllesmereUI._prebuilding then
            local rightRgn = castBarHeightRow._rightRegion
            EllesmereUI.BuildInlineCog(rightRgn, {
                anchorTo = rightRgn._control,
                icon = EllesmereUI.RESIZE_ICON,
                disabled = castIconOff,
                disabledTooltip = "Spell Icon",
                title = "Spell Icon Settings",
                rows = {
                    -- Classic WoW UI seats the icon in the vanilla border's own plate:
                    -- size, side, in-width and full-size are the art's (offsets stay).
                    { type="slider", label="Scale", min=0.5, max=2, step=0.1,
                      disabled=function() return EllesmereUI.BlizzStyle.Active("nameplates") == "classic" end,
                      disabledTooltip=function() return EllesmereUI.BlizzStyle.Label("nameplates") end,
                      requireState="disabled",
                      get=function() return DBVal("castIconScale") or defaults.castIconScale end,
                      set=function(v)
                        DB().castIconScale = v
                        if not (DB() and DB().castIconFullSize) then
                            for _, plate in pairs(plates) do
                                plate.castIconFrame:SetScale(v)
                            end
                        end
                        UpdatePreview()
                      end },
                    { type="slider", label="X Offset", min=-50, max=50, step=1,
                      get=function() return DBVal("castIconOffsetX") or defaults.castIconOffsetX or 0 end,
                      set=function(v)
                        DB().castIconOffsetX = v
                        ns.RefreshAllSettings()
                        UpdatePreview()
                      end },
                    { type="slider", label="Y Offset", min=-50, max=50, step=1,
                      get=function() return DBVal("castIconOffsetY") or defaults.castIconOffsetY or 0 end,
                      set=function(v)
                        DB().castIconOffsetY = v
                        ns.RefreshAllSettings()
                        UpdatePreview()
                      end },
                    { type="toggle", label="Make Icon Part of the Bar",
                      tooltip="This makes it so the width of the cast bar includes the icon, rather than placing it to the left of the cast bars width.",
                      disabled=function() return EllesmereUI.BlizzStyle.Active("nameplates") == "classic" end,
                      disabledTooltip=function() return EllesmereUI.BlizzStyle.Label("nameplates") end,
                      requireState="disabled",
                      get=function()
                        local db = DB()
                        if db and db.castbarIconInWidth ~= nil then return db.castbarIconInWidth end
                        return defaults.castbarIconInWidth
                      end,
                      set=function(v)
                        DB().castbarIconInWidth = v
                        ns.RefreshAllSettings()
                        UpdatePreview()
                      end },
                    { type="toggle", label="Icon on Right",
                      tooltip="Place the cast bar spell icon on the right side of the bars instead of the left.",
                      disabled=function() return EllesmereUI.BlizzStyle.Active("nameplates") == "classic" end,
                      disabledTooltip=function() return EllesmereUI.BlizzStyle.Label("nameplates") end,
                      requireState="disabled",
                      get=function()
                        local db = DB()
                        if db and db.castIconOnRight ~= nil then return db.castIconOnRight end
                        return defaults.castIconOnRight
                      end,
                      set=function(v)
                        DB().castIconOnRight = v
                        ns.RefreshAllSettings()
                        UpdatePreview()
                      end },
                    { type="toggle", label="Full Sized (Health + Cast Bar)",
                      tooltip="Make the spell icon a large square the combined height of the health bar plus the cast bar, flush with the top of the health bar and the bottom of the cast bar.",
                      disabled=function() return EllesmereUI.BlizzStyle.Active("nameplates") == "classic" end,
                      disabledTooltip=function() return EllesmereUI.BlizzStyle.Label("nameplates") end,
                      requireState="disabled",
                      get=function()
                        local db = DB()
                        if db and db.castIconFullSize ~= nil then return db.castIconFullSize end
                        return defaults.castIconFullSize
                      end,
                      set=function(v)
                        DB().castIconFullSize = v
                        ns.RefreshAllSettings()
                        UpdatePreview()
                      end },
                    { type="toggle", label="Hide Border",
                      tooltip="Hide the 1-pixel border around the cast bar spell icon.",
                      disabled=function() return EllesmereUI.BlizzStyle.Get("nameplates") end,
                      get=function()
                        local db = DB()
                        if db and db.hideCastIconBorder ~= nil then return db.hideCastIconBorder and true or false end
                        return false
                      end,
                      set=function(v)
                        DB().hideCastIconBorder = v and true or false
                        ns.RefreshAllSettings()
                        UpdatePreview()
                      end },
                    { type="toggle", label="Use Target Border Color",
                      tooltip="Colors your target's custom spell icon border, or a full-size wrapped 1-pixel one, with the target border color.",
                      get=function()
                        local db = DB()
                        if db and db.castIconTargetBorder ~= nil then return db.castIconTargetBorder end
                        return defaults.castIconTargetBorder
                      end,
                      set=function(v)
                        DB().castIconTargetBorder = v
                        ns.ApplyBorderWrapToAll()
                        -- The custom spell icon border (Icon Borders cog) takes the tint too.
                        if DBVal("castIconCustomBorder") == true then
                            for _, plate in pairs(plates) do ns.ApplyCastIconBorder(plate) end
                        end
                        UpdatePreview()
                      end },
                },
            })
        end

        -- Cast Background Opacity (+ swatch) | Cast Bar Border (+ swatch)
        local castBgRow
        castBgRow, h = W:DualRow(parent, y,
            ns.NP_BlizzOnlyGate({ type="slider", text="Cast Background", min=0, max=100, step=1,
              getValue=function()
                return math.floor(((DBVal("castBgAlpha") or defaults.castBgAlpha) * 100) + 0.5)
              end,
              setValue=function(v)
                DB().castBgAlpha = v / 100
                local c = (DB() and DB().castBgColor) or defaults.castBgColor
                for _, plate in pairs(plates) do
                    plate.castBG:SetColorTexture(c.r, c.g, c.b, v / 100)
                end
                UpdatePreview()
              end }),
            EllesmereUI.BlizzStyle.Gate("nameplates", { type="slider", text="Cast Bar Border", min=0, max=4, step=1,
              tooltip="Pixel-perfect border around the cast bar. Set to 0 for no border.",
              getValue=function() return DBVal("castBorderSize") or defaults.castBorderSize end,
              setValue=function(v)
                DB().castBorderSize = v
                ns.RefreshCastBorder()
                UpdatePreview()
              end }));  y = y - h
        if not EllesmereUI._prebuilding then
            local leftRgn = castBgRow._leftRegion
            local castBgColorGet = function()
                local c = (DB() and DB().castBgColor) or defaults.castBgColor
                return c.r, c.g, c.b
            end
            local castBgColorSet = function(r, g, b)
                DB().castBgColor = { r = r, g = g, b = b }
                local a = DBVal("castBgAlpha") or defaults.castBgAlpha
                for _, plate in pairs(plates) do
                    plate.castBG:SetColorTexture(r, g, b, a)
                end
                UpdatePreview()
            end
            local castBgSwatch, castBgUpdateSwatch = EllesmereUI.BuildColorSwatch(leftRgn, leftRgn:GetFrameLevel() + 5, castBgColorGet, castBgColorSet, nil, 20)
            PP.Point(castBgSwatch, "RIGHT", leftRgn._control, "LEFT", -12, 0)
            leftRgn._lastInline = castBgSwatch
            EllesmereUI.RegisterWidgetRefresh(function() castBgUpdateSwatch() end)
            if ns.NP_BlizzOnly() then EllesmereUI.BlizzStyle.BlockInline("nameplates", castBgSwatch) end
        end
        -- Inline color swatch on Cast Bar Border (right region)
        if not EllesmereUI._prebuilding then
            local rightRgn = castBgRow._rightRegion
            local castBorderColorGet = function()
                local c = (DB() and DB().castBorderColor) or defaults.castBorderColor
                return c.r, c.g, c.b
            end
            local castBorderColorSet = function(r, g, b)
                DB().castBorderColor = { r = r, g = g, b = b }
                ns.RefreshCastBorderColor()
                UpdatePreview()
            end
            local cbSwatch, cbUpdateSwatch = EllesmereUI.BuildColorSwatch(rightRgn, rightRgn:GetFrameLevel() + 5, castBorderColorGet, castBorderColorSet, nil, 20)
            PP.Point(cbSwatch, "RIGHT", rightRgn._control, "LEFT", -12, 0)
            rightRgn._lastInline = cbSwatch
            EllesmereUI.RegisterWidgetRefresh(function() cbUpdateSwatch() end)
            EllesmereUI.BlizzStyle.BlockInline("nameplates", cbSwatch)
        end

        -- Cast Timer: position dropdown (None/Right/Left), styled like the duration dropdowns. "None" hides it; Right/Left choose the side (reserving space, pushing shared-side cast text); Size/X/Y live in the inline cog.
        local castTimerRow
        castTimerRow, h = W:DualRow(parent, y,
            { type="dropdown", text="Cast Timer",
              values={ none = "None", right = "Right", left = "Left" },
              order={ "none", "right", "left" },
              getValue=function()
                local db = DB()
                local shown = defaults.showCastTimer
                if db and db.showCastTimer ~= nil then shown = db.showCastTimer end
                if not shown then return "none" end
                return (db and db.castTimerSide) or defaults.castTimerSide
              end,
              setValue=function(v)
                if v == "none" then
                    DB().showCastTimer = false
                else
                    DB().showCastTimer = true
                    DB().castTimerSide = v
                end
                ns.RefreshAllSettings()
                UpdatePreview()
                EllesmereUI:RefreshPage()
              end },
            { type="slider", text="Cast Bar Y Offset", min=-25, max=75, step=1,
              tooltip="Nudge the cast bar up or down from its default spot under the health bar.",
              getValue=function() return DBVal("castBarOffsetY") or defaults.castBarOffsetY end,
              setValue=function(v)
                DB().castBarOffsetY = v
                local barW = ns.GetHealthBarWidth()
                local castH = ns.GetCastBarHeight()
                for _, plate in pairs(plates) do
                    ns.LayoutCastBar(plate, barW, castH)
                end
                UpdatePreview()
              end });  y = y - h
        if not EllesmereUI._prebuilding then
            local leftRgn = castTimerRow._leftRegion
            local ctColorGet = function()
                local c = (DB() and DB().castTimerColor) or defaults.castTimerColor
                return c.r, c.g, c.b
            end
            local ctColorSet = function(r, g, b)
                DB().castTimerColor = { r = r, g = g, b = b }
                for _, plate in pairs(plates) do
                    if plate.castTimer then plate.castTimer:SetTextColor(r, g, b, 1) end
                end
                UpdatePreview()
            end
            local ctSwatch, ctUpdateSwatch = EllesmereUI.BuildColorSwatch(leftRgn, leftRgn:GetFrameLevel() + 5, ctColorGet, ctColorSet, nil, 20)
            PP.Point(ctSwatch, "RIGHT", leftRgn._control, "LEFT", -12, 0)
            leftRgn._lastInline = ctSwatch
            EllesmereUI.RegisterWidgetRefresh(function() ctUpdateSwatch() end)

            -- Inline cog for Cast Timer Size / X / Y
            EllesmereUI.BuildInlineCog(leftRgn, {
                anchorTo = ctSwatch, gap = 6,
                icon = EllesmereUI.RESIZE_ICON,
                isOpen = CogPopupOpen,
                show = function(self)
                    ShowCogPopup(self, {
                        title = EllesmereUI.L("Cast Timer Settings"),
                        xGet = function() return DBVal("castTimerOffsetX") or defaults.castTimerOffsetX end,
                        xSet = function(v) DB().castTimerOffsetX = v; ns.RefreshAllSettings(); UpdatePreview() end,
                        yGet = function() return DBVal("castTimerOffsetY") or defaults.castTimerOffsetY end,
                        ySet = function(v) DB().castTimerOffsetY = v; ns.RefreshAllSettings(); UpdatePreview() end,
                        sizeGet = function() return DBVal("castTimerSize") or defaults.castTimerSize end,
                        sizeSet = function(v) DB().castTimerSize = v; ns.RefreshAllSettings(); UpdatePreview() end,
                        sizeMin = 6, sizeMax = 20, sizeLabel = EllesmereUI.L("Size"),
                        sizeFirst = true,
                    })
                end,
            })
        end

        _, h = W:Spacer(parent, y, 20);  y = y - h

        -----------------------------------------------------------------------
        --  CAST COLORS AND EFFECTS
        -----------------------------------------------------------------------
        _, h = W:SectionHeader(parent, SECTION_CASTBAR, y);  y = y - h

        -- Cast Color ---- Kick Ready Mid-Cast Hint
        local kickHintValues = { none = "None", tick = "Tick", tickbar = "Tick + Bar" }
        local kickHintOrder = { "none", "tick", "tickbar" }
        local castColorRow
        castColorRow, h = W:DualRow(parent, y,
            { type="multiSwatch", text="Cast Color",
              swatches = {
                ns.NP_BlizzOnlyGate({ tooltip = "Interruptible Cast",
                  getValue = function() return DBColor("castBar") end,
                  setValue = function(r, g, b)
                    DB().castBar = { r = r, g = g, b = b }
                    RefreshAllPlates(); UpdatePreview()
                  end }),
                { tooltip = "Interrupt on CD",
                  getValue = function() return DBColor("interruptReady") end,
                  setValue = function(r, g, b)
                    DB().interruptReady = { r = r, g = g, b = b }
                    RefreshAllPlates()
                  end },
                ns.NP_BlizzOnlyGate({ tooltip = "Uninterruptible Cast",
                  getValue = function() return DBColor("castBarUninterruptible") end,
                  setValue = function(r, g, b)
                    DB().castBarUninterruptible = { r = r, g = g, b = b }
                    RefreshAllPlates()
                  end }),
                { tooltip = "Important Cast",
                  getValue = function() return DBColor("castBarImportant") end,
                  setValue = function(r, g, b)
                    DB().castBarImportant = { r = r, g = g, b = b }
                    RefreshAllPlates()
                  end,
                  disabled = function()
                    local db = DB()
                    local on = db and db.importantCastColorEnabled
                    if on == nil then on = defaults.importantCastColorEnabled end
                    return not on
                  end,
                  disabledTooltip = "Important Cast Color" },
              } },
            { type="dropdown", text="Kick Ready Mid-Cast Hint",
              values=kickHintValues, order=kickHintOrder,
              tooltip="Shows where your interrupt will be ready during an enemy cast. \"Tick\" marks the exact spot on the cast bar; \"Tick + Bar\" also colours the window during which your interrupt will be available.",
              getValue=function()
                -- View over two underlying toggles (kickTickEnabled + interruptMidCastEnabled) so nothing migrates: tick off -> None, tick on -> Tick, tick+bar on -> Tick + Bar. Tick defaults true, so a fresh user reads "Tick".
                local db = DB()
                local tick = true
                if db and db.kickTickEnabled ~= nil then tick = db.kickTickEnabled end
                local bar = defaults.interruptMidCastEnabled
                if db and db.interruptMidCastEnabled ~= nil then bar = db.interruptMidCastEnabled end
                if not tick then return "none" end
                if bar then return "tickbar" end
                return "tick"
              end,
              setValue=function(v)
                local db = DB()
                if v == "none" then
                    db.kickTickEnabled = false
                    db.interruptMidCastEnabled = false
                elseif v == "tickbar" then
                    db.kickTickEnabled = true
                    db.interruptMidCastEnabled = true
                else
                    db.kickTickEnabled = true
                    db.interruptMidCastEnabled = false
                end
                ns.RefreshAllSettings()
                -- Rebuild so the inline mid-cast colour swatch greys/ungreys.
                C_Timer.After(0, function() EllesmereUI:RefreshPage() end)
              end });  y = y - h

        -- Inline mid-cast colour swatch on the Hint dropdown; greys out unless "Tick + Bar" is selected, since the colour only applies to the bar.
        if not EllesmereUI._prebuilding then
            local rightRgn = castColorRow._rightRegion
            local ctrl = rightRgn and rightRgn._control
            if ctrl and EllesmereUI.BuildColorSwatch then
                local function midColorOff()
                    local db = DB()
                    local on = db and db.interruptMidCastEnabled
                    if on == nil then on = defaults.interruptMidCastEnabled end
                    return not on
                end
                local swatch, updateSwatch = EllesmereUI.BuildColorSwatch(
                    rightRgn, castColorRow:GetFrameLevel() + 3,
                    function()
                        local c = DB().interruptMidCastColor or defaults.interruptMidCastColor
                        return c.r, c.g, c.b
                    end,
                    function(r, g, b)
                        DB().interruptMidCastColor = { r = r, g = g, b = b }
                        ns.RefreshAllSettings()
                    end, nil, 20)
                PP.Point(swatch, "RIGHT", ctrl, "LEFT", -12, 0)
                rightRgn._lastInline = swatch
                swatch:SetScript("OnEnter", function(s) EllesmereUI.ShowWidgetTooltip(s, "Interrupt Ready Mid-Cast") end)
                swatch:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
                EllesmereUI.RegisterWidgetRefresh(function()
                    local off = midColorOff()
                    swatch:SetAlpha(off and 0.15 or 1)
                    swatch:EnableMouse(not off)
                    updateSwatch()
                end)
                swatch:SetAlpha(midColorOff() and 0.15 or 1)
                swatch:EnableMouse(not midColorOff())
            end
        end

        -- Inline cog beside the Cast Color swatches: Show Shield Icon
        if not EllesmereUI._prebuilding then
            local rgn = castColorRow._leftRegion
            EllesmereUI.BuildInlineCog(rgn, {
                tip = "Cast Color Settings",
                title = "Cast Color",
                rows = {
                    { type = "toggle", label = "Show Shield Icon",
                      tooltip = "Show a shield icon on the cast bar when an enemy's cast cannot be interrupted.",
                      get = function()
                        local db = DB()
                        if db and db.castBarShieldEnabled ~= nil then return db.castBarShieldEnabled end
                        return defaults.castBarShieldEnabled
                      end,
                      set = function(v)
                        DB().castBarShieldEnabled = v
                        RefreshAllPlates()
                      end },
                    { type = "toggle", label = "Show Spark",
                      tooltip = "Show the bright spark at the leading edge of the cast bar fill.",
                      get = function()
                        local db = DB()
                        if db and db.castBarSparkEnabled ~= nil then return db.castBarSparkEnabled end
                        return defaults.castBarSparkEnabled ~= false
                      end,
                      set = function(v)
                        DB().castBarSparkEnabled = v
                        for _, plate in pairs(plates) do
                            if plate.castSpark then plate.castSpark:SetShown(v ~= false) end
                        end
                        UpdatePreview()
                      end },
                    { type = "toggle", label = "Important Cast Color",
                      tooltip = "Tint the cast bar with the Important colour when the enemy casts a spell the game flags as important. Overrides the Interruptible Cast colour; your interrupt being on cooldown still takes priority.",
                      get = function()
                        local db = DB()
                        if db and db.importantCastColorEnabled ~= nil then return db.importantCastColorEnabled end
                        return defaults.importantCastColorEnabled
                      end,
                      set = function(v)
                        DB().importantCastColorEnabled = v
                        RefreshAllPlates()
                        EllesmereUI:RefreshPage()
                      end },
                },
            })
        end

        -- Important Cast Glow: shared glow controls (cast bar = bar host) + preview
        do
            local GO = EllesmereUI.GlowOptions
            local impDesc = npImpCastGlowDesc

            local impGlowRow
            impGlowRow, h = W:DualRow(parent, y,
                GO.DropdownSpec(impDesc, "Important Cast Glow",
                    "Show a glow on the cast bar when the enemy is casting a spell Blizzard marks as important."),
                { type="toggle", text="Casts In Front of Nameplates",
                  tooltip="Forces all casts to be shown in front of nameplates for visual clarity",
                  getValue=function() return DBVal("castOverlayEnabled") == true end,
                  setValue=function(v)
                    DB().castOverlayEnabled = v
                    ns.RefreshAllSettings()
                  end });  y = y - h

            if not EllesmereUI._prebuilding then
                local leftRgn = impGlowRow._leftRegion
                GO.AttachInline(leftRgn, impDesc)
                -- Icon-sized preview in the inline chain (the right half is a real
                -- setting); -12: the widest FlipBook styles overhang ~8px per side.
                local pv = GO.BuildPreview(leftRgn, impDesc, {
                    bar = false, width = 26, height = 26,
                    icon = function() return displayCastIcons[optState._previewCastIconIdx or 1] end,
                    anchor = leftRgn._lastInline, x = -12,
                })
                if pv then
                    pv:SetFrameLevel(leftRgn:GetFrameLevel() + 5)
                    leftRgn._lastInline = pv
                end
            end
        end

        -- Row 3: Focus Text Reminders (CDM only, left) | Show Interrupted Flash Effect (always present, a core cast bar setting): when CDM is loaded, Focus Text Reminders fills the left slot and flash takes the right; otherwise flash takes the left slot itself.
        do
            local function flashOff()
                local db = DB()
                local on = db and db.interruptedFlashEnabled
                if on == nil then on = defaults.interruptedFlashEnabled end
                return not on
            end
            local flashCfg = {
                type = "toggle", text = "Show Interrupted Flash Effect",
                tooltip = "Flash the enemy's cast bar and show \"Interrupted\" for a moment when their cast is interrupted. Use the swatch to change the flash colour.",
                getValue = function()
                    local db = DB()
                    if db and db.interruptedFlashEnabled ~= nil then return db.interruptedFlashEnabled end
                    return defaults.interruptedFlashEnabled
                end,
                setValue = function(v)
                    DB().interruptedFlashEnabled = v
                    RefreshAllPlates()
                    -- Rebuild so the inline flash colour swatch greys/ungreys.
                    C_Timer.After(0, function() EllesmereUI:RefreshPage() end)
                end,
            }

            local row3, swatchRegion
            if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("EllesmereUICooldownManager") then
                -- Access the FocusKick bar config in CDM's profile data
                local function GetFocusKickBar()
                    local cdmDb = _G._ECME_AceDB
                    local p = cdmDb and cdmDb.profile
                    local bars = p and p.cdmBars and p.cdmBars.bars
                    if not bars then return nil end
                    for _, b in ipairs(bars) do
                        if b.key == "focuskick" then return b end
                    end
                    return nil
                end
                row3, h = W:DualRow(parent, y,
                    { type="toggle", text="Focus Text Reminders",
                      tooltip = "Display the word \"FOCUS\" below caster/miniboss mobs in M+ if you have not set your focus. This is the same setting as in the FocusKick bar options. Disabled for specs with no kick.",
                      getValue = function()
                          local fk = GetFocusKickBar()
                          return fk and fk.focusReminderEnabled == true
                      end,
                      setValue = function(v)
                          local fk = GetFocusKickBar()
                          if fk then fk.focusReminderEnabled = v end
                          if _G._ECME_RefreshFocusReminders then
                              _G._ECME_RefreshFocusReminders()
                          end
                          EllesmereUI:RefreshPage()
                      end },
                    flashCfg
                );  y = y - h
                swatchRegion = row3._rightRegion
            else
                row3, h = W:DualRow(parent, y,
                    flashCfg,
                    { type = "label", text = "" }
                );  y = y - h
                swatchRegion = row3._leftRegion
            end

            -- Inline flash colour swatch on the Show Interrupted Flash Effect toggle; greys out when disabled.
            if not EllesmereUI._prebuilding then
                local rgn = swatchRegion
                local ctrl = rgn and rgn._control
                if ctrl and EllesmereUI.BuildColorSwatch then
                    local swatch, updateSwatch = EllesmereUI.BuildColorSwatch(
                        rgn, row3:GetFrameLevel() + 3,
                        function()
                            local c = DB().interruptedFlashColor or defaults.interruptedFlashColor
                            return c.r, c.g, c.b
                        end,
                        function(r, g, b)
                            DB().interruptedFlashColor = { r = r, g = g, b = b }
                            RefreshAllPlates()
                        end, nil, 20)
                    PP.Point(swatch, "RIGHT", rgn._lastInline or ctrl, "LEFT", -12, 0)
                    rgn._lastInline = swatch
                    swatch:SetScript("OnEnter", function(s) EllesmereUI.ShowWidgetTooltip(s, "Interrupted Flash Colour") end)
                    swatch:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
                    -- Blizzard Style uses the stock interrupted fill art, so the flash colour is inert there.
                    EllesmereUI.RegisterWidgetRefresh(function()
                        local off = flashOff() or ns.NP_BlizzOnly()
                        swatch:SetAlpha(off and 0.15 or 1)
                        swatch:EnableMouse(not off)
                        updateSwatch()
                    end)
                    swatch:SetAlpha(flashOff() and 0.15 or 1)
                    swatch:EnableMouse(not flashOff())
                end
            end
        end

        _, h = W:Spacer(parent, y, 20);  y = y - h

        -----------------------------------------------------------------------
        --  TARGET, FOCUS & HOVER EFFECTS
        -----------------------------------------------------------------------
        local tfxHeader
        tfxHeader, h = W:SectionHeader(parent, "TARGET, FOCUS & HOVER EFFECTS", y);  y = y - h

        local targetGlowRow
        -- Build the arrow-style dropdown options from the shared style table.
        local arrowVals = { none = "None" }
        local arrowOrd = { "none" }
        for _, k in ipairs(ns.TARGET_ARROW_ORDER) do
            arrowVals[k] = ns.TARGET_ARROW_STYLES[k].label
            arrowOrd[#arrowOrd + 1] = k
        end
        -- Preview the right-arrow texture on the right of each dropdown row.
        arrowVals._menuOpts = {
            itemHeight = 26,
            icon = function(key)
                local st = ns.TARGET_ARROW_STYLES[key]
                if not st then return nil end  -- "none" has no preview
                return ns.TARGET_ARROW_DIR .. st.l .. ".png"
            end,
            iconWidth = function(key)
                local st = ns.TARGET_ARROW_STYLES[key]
                if not st then return nil end
                -- Match in-game aspect: drawn width is st.w at height 16, icon slot is itemHeight(32)-8=24 tall, so scale width by 24/16.
                return math.floor(st.w * 24 / 16 + 0.5)
            end,
        }
        targetGlowRow, h = W:DualRow(parent, y,
            { type="dropdown", text="Target Effect",
              values={ __placeholder = "..." }, order={ "__placeholder" },
              getValue=function() return "__placeholder" end,
              setValue=function() end },
            { type="dropdown", text="Target Arrows",
              values=arrowVals,
              order=arrowOrd,
              getValue=function()
                if DBVal("showTargetArrows") ~= true then return "none" end
                return DBVal("targetArrowStyle") or (DBVal("targetArrowDouble") and "double") or "simple"
              end,
              setValue=function(v)
                if v == "none" then
                    DB().showTargetArrows = false
                else
                    DB().showTargetArrows = true
                    DB().targetArrowStyle = v
                end
                for _, plate in pairs(plates) do
                    plate:ApplyTarget()
                end
                UpdatePreview()
              end });  y = y - h

        -- Target Effect: multi-select checkbox dropdown (EUI Glow/Border Color/Highlight), independent toggles; data model live-converts from the legacy targetGlowStyle string (see ns.GetTargetGlow* in the core file).
        local refreshTargetBorderSwatch  -- fwd decl; assigned when the swatch builds
        local refreshTargetGlowSwatch    -- fwd decl; assigned when the glow swatch builds
        local refreshTargetHighlightCog  -- fwd decl; assigned when the cog builds
        if not EllesmereUI._prebuilding then
            local leftRgn = targetGlowRow._leftRegion
            if leftRgn._control then leftRgn._control:Hide() end
            local glowItems = {
                { key = "ellesmereui", label = "EUI Glow" },
                { key = "borderColor", label = "Border Color" },
                { key = "highlight",   label = "Highlight" },
                { key = "borderSize",  label = "Border Size",
                  tooltip = "Change Size in the Cogwheel" },
            }
            local cbDD, cbDDRefresh = EllesmereUI.BuildVisOptsCBDropdown(
                leftRgn, 170, leftRgn:GetFrameLevel() + 2,
                glowItems,
                function(k)
                    if k == "ellesmereui" then return ns.GetTargetGlowEllesmereUI() end
                    if k == "borderColor" then return ns.GetTargetGlowBorderColor() end
                    if k == "highlight"   then return ns.GetTargetGlowHighlight() end
                    if k == "borderSize"  then return ns.GetTargetGlowBorderSize() end
                    return false
                end,
                function(k, v)
                    if k == "ellesmereui" then DB().targetGlowEllesmereUI = v
                    elseif k == "borderColor" then DB().targetGlowBorderColor = v
                    elseif k == "highlight" then DB().targetGlowHighlight = v
                    elseif k == "borderSize" then
                        DB().targetGlowBorderSize = v
                        -- First-enable snapshot: seed the cog slider with the user's CURRENT border size, so enabling changes nothing until they move it (one-time, never re-snapshots later).
                        if v and DB().targetBorderSizeValue == nil then
                            if ns.IsCustomBorderEnabled() then
                                DB().targetBorderSizeValue = DBVal("customBorderSize") or defaults.customBorderSize
                            else
                                DB().targetBorderSizeValue = DBVal("borderSize") or defaults.borderSize
                            end
                        end
                    end
                    for _, plate in pairs(plates) do plate:ApplyTarget() end
                    for _, fp in pairs(ns.friendlyPlates) do fp:ApplyTarget() end
                    UpdatePreview()
                    if refreshTargetBorderSwatch then refreshTargetBorderSwatch() end
                    if refreshTargetGlowSwatch then refreshTargetGlowSwatch() end
                    if refreshTargetHighlightCog then refreshTargetHighlightCog() end
                end)
            PP.Point(cbDD, "RIGHT", leftRgn, "RIGHT", -20, 0)
            leftRgn._control = cbDD
            leftRgn._lastInline = nil
            EllesmereUI.RegisterWidgetRefresh(cbDDRefresh)

            -- Inline Border Color swatch: edits targetBorderColor (default white), tints the custom border; dimmed+non-interactive unless Border Color is checked.
            local swatch, updateSwatch = EllesmereUI.BuildColorSwatch(leftRgn, leftRgn:GetFrameLevel() + 5,
                function() local c = ns.GetTargetBorderColor(); return c.r, c.g, c.b end,
                function(r, g, b)
                    DB().targetBorderColor = { r = r, g = g, b = b }
                    for _, plate in pairs(plates) do plate:ApplyTarget() end
                    for _, fp in pairs(ns.friendlyPlates) do fp:ApplyTarget() end
                    UpdatePreview()
                end, nil, 20)
            PP.Point(swatch, "RIGHT", leftRgn._control, "LEFT", -8, 0)
            leftRgn._lastInline = swatch
            -- Tooltip so the swatch's purpose is clear (shown while interactive, i.e. Border Color on).
            swatch:SetScript("OnEnter", function() EllesmereUI.ShowWidgetTooltip(swatch, "Border Color") end)
            swatch:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
            refreshTargetBorderSwatch = function()
                local off = not ns.GetTargetGlowBorderColor()
                swatch:SetAlpha(off and 0.15 or 1)
                swatch:EnableMouse(not off)
                updateSwatch()
            end
            EllesmereUI.RegisterWidgetRefresh(refreshTargetBorderSwatch)
            refreshTargetBorderSwatch()

            -- Inline Glow Color swatch: edits targetGlowColor (default the signature blue), tints the EUI background glow; dimmed+non-interactive unless EUI Glow is checked.
            local glowSwatch, updateGlowSwatch = EllesmereUI.BuildColorSwatch(leftRgn, leftRgn:GetFrameLevel() + 5,
                function() local c = ns.GetTargetGlowColor(); return c.r, c.g, c.b end,
                function(r, g, b)
                    DB().targetGlowColor = { r = r, g = g, b = b }
                    for _, plate in pairs(plates) do plate:ApplyTarget() end
                    UpdatePreview()
                end, nil, 20)
            PP.Point(glowSwatch, "RIGHT", leftRgn._lastInline or leftRgn._control, "LEFT", -8, 0)
            leftRgn._lastInline = glowSwatch
            glowSwatch:SetScript("OnEnter", function() EllesmereUI.ShowWidgetTooltip(glowSwatch, "Glow Color") end)
            glowSwatch:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
            refreshTargetGlowSwatch = function()
                local off = not ns.GetTargetGlowEllesmereUI()
                glowSwatch:SetAlpha(off and 0.15 or 1)
                glowSwatch:EnableMouse(not off)
                updateGlowSwatch()
            end
            EllesmereUI.RegisterWidgetRefresh(refreshTargetGlowSwatch)
            refreshTargetGlowSwatch()

            -- Inline cog "More Effects": Highlight color/opacity + Glow opacity; enabled when Highlight OR EUI Glow is on (Glow Opacity reachable whenever the glow is active).
            do
                local function highlightCogOff()
                    return not (ns.GetTargetGlowHighlight() or ns.GetTargetGlowEllesmereUI()
                        or ns.GetTargetGlowBorderSize())
                end
                local highlightCogBtn = EllesmereUI.BuildInlineCog(leftRgn, {
                    disabled = highlightCogOff,
                    disabledTooltip = "a Target Effect",
                    title = "More Effects",
                    rows = {
                        { type="colorpicker", label="Highlight Color", hasAlpha=false,
                          get=function() local c = ns.GetTargetHighlightColor(); return c.r, c.g, c.b end,
                          set=function(r, g, b)
                            DB().targetHighlightColor = { r = r, g = g, b = b }
                            for _, plate in pairs(plates) do plate:ApplyTarget() end
                            UpdatePreview()
                          end },
                        { type="slider", label="Highlight Opacity", min=0, max=100, step=1,
                          get=function() return math.floor((ns.GetTargetHighlightAlpha() * 100) + 0.5) end,
                          set=function(v)
                            DB().targetHighlightAlpha = v / 100
                            for _, plate in pairs(plates) do plate:ApplyTarget() end
                            UpdatePreview()
                          end },
                        { type="slider", label="Glow Opacity", min=0, max=100, step=1,
                          get=function() return math.floor((ns.GetTargetGlowAlpha() * 100) + 0.5) end,
                          set=function(v)
                            DB().targetGlowAlpha = v / 100
                            for _, plate in pairs(plates) do plate:ApplyTarget() end
                            UpdatePreview()
                          end },
                        { type="slider", label="Border Size", min=0, max=4, step=1,
                          get=function()
                            local v = DBVal("targetBorderSizeValue")
                            if v ~= nil then return v end
                            -- Not snapshotted yet: show the current border size.
                            if ns.IsCustomBorderEnabled() then
                                return DBVal("customBorderSize") or defaults.customBorderSize
                            end
                            return DBVal("borderSize") or defaults.borderSize
                          end,
                          set=function(v)
                            DB().targetBorderSizeValue = v
                            for _, plate in pairs(plates) do plate:ApplyTarget() end
                            for _, fp in pairs(ns.friendlyPlates) do fp:ApplyTarget() end
                            UpdatePreview()
                          end,
                          disabled=function() return not ns.GetTargetGlowBorderSize() end,
                          disabledTooltip="Border Size Target Effect" },
                    },
                })
                refreshTargetHighlightCog = highlightCogBtn and highlightCogBtn._euiCogState
            end
        end

        -- Inline Custom + Class color swatches on Target Arrows (custom adjacent to the control, class to its left); click to switch, inactive swatch dims, both gray out when arrows off.
        do
            local rightRgn = targetGlowRow._rightRegion
            local arrowOff = function() return DBVal("showTargetArrows") ~= true end
            local customSwatch, updateCustom, classSwatch, updateClass
            local function refreshArrowSwatches()
                if updateCustom then updateCustom() end
                if updateClass then updateClass() end
                local off = arrowOff()
                local useClass = DBVal("targetArrowClassColor") == true
                customSwatch:SetAlpha(off and 0.15 or (useClass and 0.3 or 1))
                classSwatch:SetAlpha(off and 0.15 or (useClass and 1 or 0.3))
                customSwatch:SetMouseClickEnabled(not off)
                classSwatch:SetMouseClickEnabled(not off)
            end
            customSwatch, updateCustom = EllesmereUI.BuildColorSwatch(rightRgn, rightRgn:GetFrameLevel() + 5,
                function() local c = DBVal("targetArrowColor") or defaults.targetArrowColor; return c.r, c.g, c.b end,
                function(r, g, b)
                    DB().targetArrowColor = { r = r, g = g, b = b }
                    DB().targetArrowClassColor = false
                    for _, plate in pairs(plates) do plate:ApplyTarget() end
                    UpdatePreview(); refreshArrowSwatches()
                end, nil, 20)
            PP.Point(customSwatch, "RIGHT", rightRgn._control, "LEFT", -8, 0)
            local origCustomClick = customSwatch:GetScript("OnClick")
            customSwatch:SetScript("OnClick", function(self, ...)
                if arrowOff() then return end
                if DBVal("targetArrowClassColor") == true then
                    DB().targetArrowClassColor = false
                    for _, plate in pairs(plates) do plate:ApplyTarget() end
                    UpdatePreview(); refreshArrowSwatches()
                    return
                end
                if origCustomClick then origCustomClick(self, ...) end
            end)
            customSwatch:SetScript("OnEnter", function() EllesmereUI.ShowWidgetTooltip(customSwatch, "Custom Color") end)
            customSwatch:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
            classSwatch, updateClass = EllesmereUI.BuildColorSwatch(rightRgn, rightRgn:GetFrameLevel() + 5,
                function() local _, ct = UnitClass("player"); local cc = ct and C_ClassColor and C_ClassColor.GetClassColor(ct); if cc then return cc.r, cc.g, cc.b end return 1, 1, 1 end,
                function() end, nil, 20)
            PP.Point(classSwatch, "RIGHT", customSwatch, "LEFT", -8, 0)
            rightRgn._lastInline = classSwatch
            classSwatch:SetScript("OnClick", function()
                if arrowOff() then return end
                DB().targetArrowClassColor = true
                for _, plate in pairs(plates) do plate:ApplyTarget() end
                UpdatePreview(); refreshArrowSwatches()
            end)
            classSwatch:SetScript("OnEnter", function() EllesmereUI.ShowWidgetTooltip(classSwatch, "Class Color") end)
            classSwatch:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
            EllesmereUI.RegisterWidgetRefresh(refreshArrowSwatches)
            refreshArrowSwatches()
        end

        -- Inline cog (arrow scale), to the left of the swatches
        do
            local rightRgn = targetGlowRow._rightRegion
            local arrowOff = function() return DBVal("showTargetArrows") ~= true end
            EllesmereUI.BuildInlineCog(rightRgn, {
                icon = EllesmereUI.RESIZE_ICON,
                disabled = arrowOff,
                disabledTooltip = "Target Arrows",
                title = "Arrow Scale",
                rows = {
                    { type="slider", label="Scale", min=0.5, max=3.0, step=0.1,
                      get=function() return DBVal("targetArrowScale") or defaults.targetArrowScale or 1.0 end,
                      set=function(v)
                        DB().targetArrowScale = v
                        local _scKey = DBVal("targetArrowStyle") or (DBVal("targetArrowDouble") and "double") or "simple"
                        local _scW = (ns.TARGET_ARROW_STYLES[_scKey] or ns.TARGET_ARROW_STYLES.simple).w
                        for _, plate in pairs(plates) do
                            local sc = v
                            local aw = math.floor(_scW * sc + 0.5)
                            local ah = math.floor(16 * sc + 0.5)
                            if plate.leftArrow then PP.Size(plate.leftArrow, aw, ah) end
                            if plate.rightArrow then PP.Size(plate.rightArrow, aw, ah) end
                        end
                        UpdatePreview()
                      end },
                },
            })
        end

        -- Eye icon to the left of the Target Glow Style dropdown to toggle glow on preview
        do
            local EYE_VISIBLE   = EllesmereUI.EYE_VISIBLE_ICON
            local EYE_INVISIBLE = EllesmereUI.EYE_INVISIBLE_ICON
            local leftRgn = targetGlowRow._leftRegion
            local eyeBtn = CreateFrame("Button", nil, leftRgn)
            eyeBtn:SetSize(26, 26)
            eyeBtn:SetPoint("RIGHT", leftRgn._lastInline or leftRgn._control, "LEFT", -8, 0)
            eyeBtn:SetFrameLevel(leftRgn:GetFrameLevel() + 5)
            eyeBtn:SetAlpha(0.4)
            local eyeTex = eyeBtn:CreateTexture(nil, "OVERLAY")
            eyeTex:SetAllPoints()
            local function RefreshTargetGlowEye()
                if optState.showTargetGlowPreview then
                    eyeTex:SetTexture(EYE_INVISIBLE)
                else
                    eyeTex:SetTexture(EYE_VISIBLE)
                end
            end
            RefreshTargetGlowEye()
            eyeBtn:SetScript("OnClick", function()
                optState.showTargetGlowPreview = not optState.showTargetGlowPreview
                RefreshTargetGlowEye()
                UpdatePreview()
            end)
            eyeBtn:SetScript("OnEnter", function(self) self:SetAlpha(0.7) end)
            eyeBtn:SetScript("OnLeave", function(self) self:SetAlpha(0.4) end)
        end

        -- Enable Target Color ---- Target Texture
        local isTargetColorDisabled = function()
            local db = DB()
            if db and db.targetColorEnabled ~= nil then return not db.targetColorEnabled end
            return not defaults.targetColorEnabled
        end
        local isTargetTextureNone = function()
            return (DBVal("targetOverlayTexture") or defaults.targetOverlayTexture) == "none"
        end
        -- No Tint: the target texture pattern becomes the bar's own fill texture (SetStatusBarTexture) instead of a tinted overlay, so the color swatch/opacity below stop applying.
        local isTargetNoTint = function()
            local v = DBVal("targetOverlayNoTint")
            if v == nil then return defaults.targetOverlayNoTint end
            return v
        end
        local isFocusColorDisabled = function()
            local db = DB()
            if db and db.focusColorEnabled ~= nil then return not db.focusColorEnabled end
            return not defaults.focusColorEnabled
        end
        local isFocusTextureNone = function()
            return (DBVal("focusOverlayTexture") or defaults.focusOverlayTexture) == "none"
        end
        local isFocusNoTint = function()
            local v = DBVal("focusOverlayNoTint")
            if v == nil then return defaults.focusOverlayNoTint end
            return v
        end

        local targetPrev, focusPrev
        local function RefreshFocusPreview()
            RefreshAllPlates()
            if focusPrev and focusPrev.UpdateOverlay then focusPrev.UpdateOverlay() end
        end

        local targetColorRow
        targetColorRow, h = W:DualRow(parent, y,
            { type="toggle", text="Enable Target Color",
              getValue=function()
                local db = DB()
                if db and db.targetColorEnabled ~= nil then return db.targetColorEnabled end
                return defaults.targetColorEnabled
              end,
              setValue=function(v)
                DB().targetColorEnabled = v
                RefreshAllPlates()
                if targetPrev then
                    if v then
                        targetPrev.SetColorOverride(nil)
                    else
                        targetPrev.SetColorOverride(function() return DBColor("enemyInCombat") end)
                    end
                    targetPrev.UpdateColor()
                    targetPrev.SetDisabled(not v)
                end
                EllesmereUI:RefreshPage()
              end },
            { type="toggle", text="Enable Focus Color",
              getValue=function()
                local db = DB()
                if db and db.focusColorEnabled ~= nil then return db.focusColorEnabled end
                return defaults.focusColorEnabled
              end,
              setValue=function(v)
                DB().focusColorEnabled = v
                RefreshAllPlates()
                if focusPrev then
                    if v then
                        focusPrev.SetColorOverride(nil)
                    else
                        focusPrev.SetColorOverride(function() return DBColor("enemyInCombat") end)
                    end
                    focusPrev.UpdateColor()
                    focusPrev.SetDisabled(not v)
                end
                EllesmereUI:RefreshPage()
              end });  y = y - h

        -- Inline Target Color swatch
        if not EllesmereUI._prebuilding then
            local leftRgn = targetColorRow._leftRegion
            local targetColorGet = function() return DBColor("target") end
            local targetColorSet = function(r, g, b)
                DB().target = { r = r, g = g, b = b }
                RefreshAllPlates()
                if targetPrev then targetPrev.UpdateColor() end
            end
            local swatch, updateSwatch = EllesmereUI.BuildColorSwatch(leftRgn, leftRgn:GetFrameLevel() + 5, targetColorGet, targetColorSet, nil, 20)
            PP.Point(swatch, "RIGHT", leftRgn._control, "LEFT", -12, 0)
            EllesmereUI.RegisterWidgetRefresh(function()
                local off = isTargetColorDisabled()
                swatch:SetAlpha(off and 0.15 or 1)
                swatch:EnableMouse(not off)
                updateSwatch()
            end)
            local off = isTargetColorDisabled()
            swatch:SetAlpha(off and 0.15 or 1)
            swatch:EnableMouse(not off)
        end

        -- Inline Focus Color swatch
        if not EllesmereUI._prebuilding then
            local rightRgn = targetColorRow._rightRegion
            local focusColorGet = function() return DBColor("focus") end
            local focusColorSet = function(r, g, b)
                DB().focus = { r = r, g = g, b = b }
                RefreshAllPlates()
                if focusPrev then focusPrev.UpdateColor() end
            end
            local swatch, updateSwatch = EllesmereUI.BuildColorSwatch(rightRgn, rightRgn:GetFrameLevel() + 5, focusColorGet, focusColorSet, nil, 20)
            PP.Point(swatch, "RIGHT", rightRgn._control, "LEFT", -12, 0)
            EllesmereUI.RegisterWidgetRefresh(function()
                local off = isFocusColorDisabled()
                swatch:SetAlpha(off and 0.15 or 1)
                swatch:EnableMouse(not off)
                updateSwatch()
            end)
            local off = isFocusColorDisabled()
            swatch:SetAlpha(off and 0.15 or 1)
            swatch:EnableMouse(not off)
        end

        -- Target Texture ---- Focus Texture
        -- Both dropdowns list the special stripe overlays first, then the full bar texture set (EUI + SharedMedia) shared with the main Bar Texture dropdown; stripe keys resolve to nameplate Media, bar keys resolve through the health-bar lookup at render time (ns.ResolveOverlayTexPath).
        local ovtValues, ovtOrder = {}, {}
        do
            local STRIPE_ORDER = { "striped-v2", "striped-wide-v2", "stripes-medium", "stripes-small-close", "stripes-small-spread", "striped-tiny" }
            local STRIPE_NAMES = {
                ["striped-v2"] = "Stripes", ["striped-wide-v2"] = "Wide Stripes",
                ["stripes-medium"] = "Medium Stripes", ["stripes-small-close"] = "Small Dense Stripes",
                ["stripes-small-spread"] = "Small Spread Stripes", ["striped-tiny"] = "Tiny Stripes",
            }
            for _, k in ipairs(STRIPE_ORDER) do ovtValues[k] = STRIPE_NAMES[k]; ovtOrder[#ovtOrder + 1] = k end
            ovtOrder[#ovtOrder + 1] = "---"
            for _, k in ipairs(hbtOrder) do
                ovtOrder[#ovtOrder + 1] = k
                if k ~= "---" then ovtValues[k] = hbtValues[k] end
            end
            ovtValues._menuOpts = {
                itemHeight = 28,
                background = function(key)
                    if not key or key == "none" or key == "---" then return nil end
                    if ns.OVERLAY_STRIPE_KEYS and ns.OVERLAY_STRIPE_KEYS[key] then
                        return "Interface\\AddOns\\EllesmereUINameplates\\Media\\" .. key .. ".png"
                    end
                    return ns.healthBarTextures and ns.healthBarTextures[key]
                end,
            }
        end
        local textureDualRow
        textureDualRow, h = W:DualRow(parent, y,
            { type="dropdown", text="Target Texture",
              values=ovtValues,
              getValue=function() return DBVal("targetOverlayTexture") or defaults.targetOverlayTexture end,
              setValue=function(v)
                DB().targetOverlayTexture = v
                RefreshAllPlates()
                if targetPrev and targetPrev.UpdateOverlay then targetPrev.UpdateOverlay() end
                EllesmereUI:RefreshPage()
              end,
              order=ovtOrder },
            { type="dropdown", text="Focus Texture",
              values=ovtValues,
              getValue=function() return DBVal("focusOverlayTexture") or defaults.focusOverlayTexture end,
              setValue=function(v)
                DB().focusOverlayTexture = v
                RefreshAllPlates()
                if focusPrev and focusPrev.UpdateOverlay then focusPrev.UpdateOverlay() end
                EllesmereUI:RefreshPage()
              end,
              order=ovtOrder });  y = y - h

        -- Inline Target Texture color swatch
        if not EllesmereUI._prebuilding then
            local leftRgn = textureDualRow._leftRegion
            local targetTexColorGet = function()
                local c = (DB() and DB().targetOverlayColor) or defaults.targetOverlayColor
                return c.r, c.g, c.b
            end
            local targetTexColorSet = function(r, g, b)
                DB().targetOverlayColor = { r = r, g = g, b = b }
                RefreshAllPlates()
                if targetPrev and targetPrev.UpdateOverlay then targetPrev.UpdateOverlay() end
            end
            local swatch, updateSwatch = EllesmereUI.BuildColorSwatch(leftRgn, leftRgn:GetFrameLevel() + 5, targetTexColorGet, targetTexColorSet, nil, 20)
            PP.Point(swatch, "RIGHT", leftRgn._control, "LEFT", -12, 0)
            leftRgn._lastInline = swatch
            EllesmereUI.RegisterWidgetRefresh(function()
                local off = isTargetTextureNone() or isTargetNoTint()
                swatch:SetAlpha(off and 0.15 or 1)
                swatch:EnableMouse(not off)
                updateSwatch()
            end)
            local off = isTargetTextureNone() or isTargetNoTint()
            swatch:SetAlpha(off and 0.15 or 1)
            swatch:EnableMouse(not off)
        end

        -- Inline Target Texture cog (Opacity + No Tint), to the left of the swatch
        if not EllesmereUI._prebuilding then
            local leftRgn = textureDualRow._leftRegion
            EllesmereUI.BuildInlineCog(leftRgn, {
                disabled = isTargetTextureNone,
                disabledTooltip = "a Target Texture",
                title = "Target Texture",
                rows = {
                    { type="slider", label="Opacity", min=5, max=100, step=1,
                      get=function() return math.floor(((DBVal("targetOverlayAlpha") or defaults.targetOverlayAlpha) * 100) + 0.5) end,
                      set=function(v)
                        DB().targetOverlayAlpha = v / 100
                        RefreshAllPlates()
                        if targetPrev and targetPrev.UpdateOverlay then targetPrev.UpdateOverlay() end
                      end },
                    { type="toggle", label="Full alpha on empty part of bar",
                      get=function()
                        local v = DBVal("targetOverlayFullBgAlpha")
                        if v == nil then return defaults.targetOverlayFullBgAlpha end
                        return v
                      end,
                      set=function(v)
                        DB().targetOverlayFullBgAlpha = v
                        RefreshAllPlates()
                        if targetPrev and targetPrev.UpdateOverlay then targetPrev.UpdateOverlay() end
                      end },
                    { type="toggle", label="Don't tint (keep bar's own color)",
                      tooltip="Tints the pattern with the bar's current color instead of the custom overlay color.",
                      get=isTargetNoTint,
                      set=function(v)
                        DB().targetOverlayNoTint = v
                        RefreshAllTextures()
                        if targetPrev and targetPrev.UpdateOverlay then targetPrev.UpdateOverlay() end
                      end },
                },
            })
        end

        -- Inline Focus Texture color swatch
        if not EllesmereUI._prebuilding then
            local rightRgn = textureDualRow._rightRegion
            local focusTexColorGet = function()
                local c = (DB() and DB().focusOverlayColor) or defaults.focusOverlayColor
                return c.r, c.g, c.b
            end
            local focusTexColorSet = function(r, g, b)
                DB().focusOverlayColor = { r = r, g = g, b = b }
                RefreshAllPlates()
                if focusPrev and focusPrev.UpdateOverlay then focusPrev.UpdateOverlay() end
            end
            local swatch, updateSwatch = EllesmereUI.BuildColorSwatch(rightRgn, rightRgn:GetFrameLevel() + 5, focusTexColorGet, focusTexColorSet, nil, 20)
            PP.Point(swatch, "RIGHT", rightRgn._control, "LEFT", -12, 0)
            rightRgn._lastInline = swatch
            EllesmereUI.RegisterWidgetRefresh(function()
                local off = isFocusTextureNone() or isFocusNoTint()
                swatch:SetAlpha(off and 0.15 or 1)
                swatch:EnableMouse(not off)
                updateSwatch()
            end)
            local off = isFocusTextureNone() or isFocusNoTint()
            swatch:SetAlpha(off and 0.15 or 1)
            swatch:EnableMouse(not off)
        end

        -- Inline Focus Texture cog (Opacity + No Tint), to the left of the swatch
        if not EllesmereUI._prebuilding then
            local rightRgn = textureDualRow._rightRegion
            EllesmereUI.BuildInlineCog(rightRgn, {
                disabled = isFocusTextureNone,
                disabledTooltip = "a Focus Texture",
                title = "Focus Texture",
                rows = {
                    { type="slider", label="Opacity", min=5, max=100, step=1,
                      get=function() return math.floor(((DBVal("focusOverlayAlpha") or defaults.focusOverlayAlpha) * 100) + 0.5) end,
                      set=function(v)
                        DB().focusOverlayAlpha = v / 100
                        RefreshFocusPreview()
                      end },
                    { type="toggle", label="Full alpha on empty part of bar",
                      get=function()
                        local v = DBVal("focusOverlayFullBgAlpha")
                        if v == nil then return defaults.focusOverlayFullBgAlpha end
                        return v
                      end,
                      set=function(v)
                        DB().focusOverlayFullBgAlpha = v
                        RefreshFocusPreview()
                      end },
                    { type="toggle", label="Don't tint (keep bar's own color)",
                      tooltip="Tints the pattern with the bar's current color instead of the custom overlay color.",
                      get=isFocusNoTint,
                      set=function(v)
                        DB().focusOverlayNoTint = v
                        RefreshAllTextures()
                        RefreshFocusPreview()
                      end },
                },
            })
        end

        -- Target Preview ---- Focus Preview
        local previewDualRow
        previewDualRow, h = W:DualRow(parent, y,
            { type="label", text="Target Preview" },
            { type="label", text="Focus Preview" });  y = y - h

        if not EllesmereUI._prebuilding then
        targetPrev = LazyColorPreviewBar(previewDualRow, "health", "target", previewDualRow._leftRegion)
        do
            local function RepositionTargetBar()
                local rgn = previewDualRow._leftRegion
                for _, child in ipairs({ previewDualRow:GetChildren() }) do
                    if child.GetNumPoints and child:GetNumPoints() > 0 then
                        local _, rel = child:GetPoint(1)
                        if rel == rgn then
                            child:ClearAllPoints()
                            PP.Point(child, "RIGHT", rgn, "RIGHT", -20, 0)
                            return
                        end
                    end
                end
            end
            previewDualRow:HookScript("OnShow", RepositionTargetBar)
            C_Timer.After(0, RepositionTargetBar)
        end
        if isTargetColorDisabled() then
            targetPrev.SetColorOverride(function() return DBColor("enemyInCombat") end)
        end
        targetPrev.SetDisabled(isTargetColorDisabled())
        targetPrev.UpdateColor()
        end

        if not EllesmereUI._prebuilding then
        focusPrev = LazyColorPreviewBar(previewDualRow, "health", "focus", previewDualRow._rightRegion)
        do
            local function RepositionFocusBar()
                local rgn = previewDualRow._rightRegion
                for _, child in ipairs({ previewDualRow:GetChildren() }) do
                    if child.GetNumPoints and child:GetNumPoints() > 0 then
                        local _, rel = child:GetPoint(1)
                        if rel == rgn then
                            child:ClearAllPoints()
                            PP.Point(child, "RIGHT", rgn, "RIGHT", -20, 0)
                            return
                        end
                    end
                end
            end
            previewDualRow:HookScript("OnShow", RepositionFocusBar)
            C_Timer.After(0, RepositionFocusBar)
        end
        if isFocusColorDisabled() then
            focusPrev.SetColorOverride(function() return DBColor("enemyInCombat") end)
        end
        focusPrev.SetDisabled(isFocusColorDisabled())
        focusPrev.UpdateColor()
        end

        -- Hover Texture (+ Hover Effect opacity slider + color swatch): the mouseover highlight overlay and its opacity/color, at the bottom of this section.
        local hoverOverlayValues, hoverOverlayOrder = {}, {}
        do
            local STRIPE_ORDER = { "striped-v2", "striped-wide-v2", "stripes-medium", "stripes-small-close", "stripes-small-spread", "striped-tiny" }
            local STRIPE_NAMES = {
                ["striped-v2"] = "Stripes", ["striped-wide-v2"] = "Wide Stripes",
                ["stripes-medium"] = "Medium Stripes", ["stripes-small-close"] = "Small Dense Stripes",
                ["stripes-small-spread"] = "Small Spread Stripes", ["striped-tiny"] = "Tiny Stripes",
            }
            hoverOverlayValues.none = "None"
            hoverOverlayOrder[#hoverOverlayOrder + 1] = "none"
            hoverOverlayOrder[#hoverOverlayOrder + 1] = "---"
            for _, k in ipairs(STRIPE_ORDER) do hoverOverlayValues[k] = STRIPE_NAMES[k]; hoverOverlayOrder[#hoverOverlayOrder + 1] = k end
            hoverOverlayOrder[#hoverOverlayOrder + 1] = "---"
            for _, k in ipairs(hbtOrder) do
                -- "none" is already prepended above; skip the copy from hbtOrder (which starts with "none") so it shows only once.
                if k ~= "none" then
                    hoverOverlayOrder[#hoverOverlayOrder + 1] = k
                    if k ~= "---" then hoverOverlayValues[k] = hbtValues[k] end
                end
            end
            hoverOverlayValues._menuOpts = {
                itemHeight = 28,
                background = function(key)
                    if not key or key == "none" or key == "---" then return nil end
                    if ns.OVERLAY_STRIPE_KEYS and ns.OVERLAY_STRIPE_KEYS[key] then
                        return "Interface\\AddOns\\EllesmereUINameplates\\Media\\" .. key .. ".png"
                    end
                    return ns.healthBarTextures and ns.healthBarTextures[key]
                end,
            }
        end
        do
            local hoverRow
            hoverRow, h = W:DualRow(parent, y,
                { type="dropdown", text="Hover Texture",
                  tooltip="Uses the Hover Effect color and opacity. Set to None for the flat hover highlight.",
                  values=hoverOverlayValues, order=hoverOverlayOrder,
                  getValue=function() return DBVal("hoverOverlayTexture") or defaults.hoverOverlayTexture end,
                  setValue=function(v)
                    DB().hoverOverlayTexture = v
                    ns.RefreshHoverEffect()
                    UpdatePreview()
                    EllesmereUI:RefreshPage()
                  end },
                { type="dropdown", text="Hover Effect",
                  values={ __placeholder = "..." }, order={ "__placeholder" },
                  getValue=function() return "__placeholder" end,
                  setValue=function() end });  y = y - h
            if not EllesmereUI._prebuilding then
            -- Hover Effect: the Target Effect model copied onto mouseover
            -- (user-directed 2026-08-16, no preview integration). Highlight is
            -- the only default-on channel and rides the legacy
            -- hoverColor/hoverAlpha keys, so every profile keeps its exact
            -- pre-rework hover visuals until other channels are opted in.
            local rightRgn = hoverRow._rightRegion
            if rightRgn._control then rightRgn._control:Hide() end
            local refreshHoverBorderSwatch
            local refreshHoverGlowSwatch
            local refreshHoverCog
            local hoverItems = {
                { key = "ellesmereui", label = "EUI Glow" },
                { key = "borderColor", label = "Border Color" },
                { key = "highlight",   label = "Highlight" },
                { key = "borderSize",  label = "Border Size",
                  tooltip = "Change Size in the Cogwheel" },
            }
            local hvDD, hvDDRefresh = EllesmereUI.BuildVisOptsCBDropdown(
                rightRgn, 170, rightRgn:GetFrameLevel() + 2,
                hoverItems,
                function(k)
                    if k == "ellesmereui" then return ns.GetHoverGlowEllesmereUI() end
                    if k == "borderColor" then return ns.GetHoverGlowBorderColor() end
                    if k == "highlight"   then return ns.GetHoverGlowHighlight() end
                    if k == "borderSize"  then return ns.GetHoverGlowBorderSize() end
                    return false
                end,
                function(k, v)
                    if k == "ellesmereui" then DB().hoverGlowEllesmereUI = v
                    elseif k == "borderColor" then DB().hoverGlowBorderColor = v
                    elseif k == "highlight" then DB().hoverGlowHighlight = v
                    elseif k == "borderSize" then
                        DB().hoverGlowBorderSize = v
                        -- First-enable snapshot: seed the cog slider with the user's
                        -- CURRENT border size, so enabling changes nothing until they
                        -- move it (one-time, never re-snapshots later).
                        if v and DB().hoverBorderSizeValue == nil then
                            if ns.IsCustomBorderEnabled() then
                                DB().hoverBorderSizeValue = DBVal("customBorderSize") or defaults.customBorderSize
                            else
                                DB().hoverBorderSizeValue = DBVal("borderSize") or defaults.borderSize
                            end
                        end
                    end
                    ns.RefreshHoverEffect()
                    if refreshHoverBorderSwatch then refreshHoverBorderSwatch() end
                    if refreshHoverGlowSwatch then refreshHoverGlowSwatch() end
                    if refreshHoverCog then refreshHoverCog() end
                end)
            PP.Point(hvDD, "RIGHT", rightRgn, "RIGHT", -20, 0)
            rightRgn._control = hvDD
            rightRgn._lastInline = nil
            EllesmereUI.RegisterWidgetRefresh(hvDDRefresh)

            -- Inline Border Color swatch: dimmed unless Border Color is checked.
            local hvBSwatch, hvUpdateBSwatch = EllesmereUI.BuildColorSwatch(rightRgn, rightRgn:GetFrameLevel() + 5,
                function() local c = ns.GetHoverBorderColor(); return c.r, c.g, c.b end,
                function(r, g, b)
                    DB().hoverBorderColor = { r = r, g = g, b = b }
                    ns.RefreshHoverEffect()
                end, nil, 20)
            PP.Point(hvBSwatch, "RIGHT", rightRgn._control, "LEFT", -8, 0)
            rightRgn._lastInline = hvBSwatch
            hvBSwatch:SetScript("OnEnter", function() EllesmereUI.ShowWidgetTooltip(hvBSwatch, "Border Color") end)
            hvBSwatch:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
            refreshHoverBorderSwatch = function()
                local off = not ns.GetHoverGlowBorderColor()
                hvBSwatch:SetAlpha(off and 0.15 or 1)
                hvBSwatch:EnableMouse(not off)
                hvUpdateBSwatch()
            end
            EllesmereUI.RegisterWidgetRefresh(refreshHoverBorderSwatch)
            refreshHoverBorderSwatch()

            -- Inline Glow Color swatch: dimmed unless EUI Glow is checked.
            local hvGSwatch, hvUpdateGSwatch = EllesmereUI.BuildColorSwatch(rightRgn, rightRgn:GetFrameLevel() + 5,
                function() local c = ns.GetHoverGlowColor(); return c.r, c.g, c.b end,
                function(r, g, b)
                    DB().hoverGlowColor = { r = r, g = g, b = b }
                    ns.RefreshHoverEffect()
                end, nil, 20)
            PP.Point(hvGSwatch, "RIGHT", rightRgn._lastInline or rightRgn._control, "LEFT", -8, 0)
            rightRgn._lastInline = hvGSwatch
            hvGSwatch:SetScript("OnEnter", function() EllesmereUI.ShowWidgetTooltip(hvGSwatch, "Glow Color") end)
            hvGSwatch:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
            refreshHoverGlowSwatch = function()
                local off = not ns.GetHoverGlowEllesmereUI()
                hvGSwatch:SetAlpha(off and 0.15 or 1)
                hvGSwatch:EnableMouse(not off)
                hvUpdateGSwatch()
            end
            EllesmereUI.RegisterWidgetRefresh(refreshHoverGlowSwatch)
            refreshHoverGlowSwatch()

            -- Inline cog "More Effects": Highlight color/opacity (the legacy
            -- hoverColor/hoverAlpha keys) + Glow Opacity + Border Size.
            do
                local function hoverCogOff()
                    return not (ns.GetHoverGlowHighlight() or ns.GetHoverGlowEllesmereUI()
                        or ns.GetHoverGlowBorderSize())
                end
                local hoverCogBtn = EllesmereUI.BuildInlineCog(rightRgn, {
                    disabled = hoverCogOff,
                    disabledTooltip = "a Hover Effect",
                    title = "More Effects",
                    rows = {
                        { type="colorpicker", label="Highlight Color", hasAlpha=false,
                          get=function()
                            local c = (DB() and DB().hoverColor) or defaults.hoverColor
                            return c.r, c.g, c.b
                          end,
                          set=function(r, g, b)
                            DB().hoverColor = { r = r, g = g, b = b }
                            ns.RefreshHoverEffect()
                            UpdatePreview()
                          end },
                        { type="slider", label="Highlight Opacity", min=0, max=100, step=1,
                          get=function()
                            return math.floor(((DBVal("hoverAlpha") or defaults.hoverAlpha) * 100) + 0.5)
                          end,
                          set=function(v)
                            DB().hoverAlpha = v / 100
                            ns.RefreshHoverEffect()
                            UpdatePreview()
                          end },
                        { type="slider", label="Glow Opacity", min=0, max=100, step=1,
                          get=function() return math.floor((ns.GetHoverGlowAlpha() * 100) + 0.5) end,
                          set=function(v)
                            DB().hoverGlowAlpha = v / 100
                            ns.RefreshHoverEffect()
                          end },
                        { type="slider", label="Border Size", min=0, max=4, step=1,
                          get=function()
                            local v = DBVal("hoverBorderSizeValue")
                            if v ~= nil then return v end
                            if ns.IsCustomBorderEnabled() then
                                return DBVal("customBorderSize") or defaults.customBorderSize
                            end
                            return DBVal("borderSize") or defaults.borderSize
                          end,
                          set=function(v)
                            DB().hoverBorderSizeValue = v
                            ns.RefreshHoverEffect()
                          end,
                          disabled=function() return not ns.GetHoverGlowBorderSize() end,
                          disabledTooltip="Border Size Hover Effect" },
                    },
                })
                refreshHoverCog = hoverCogBtn and hoverCogBtn._euiCogState
            end

            -- Inline Hover Texture cog (Full alpha on empty part of bar), left of the dropdown; disabled while set to None.
            local leftRgn = hoverRow._leftRegion
            local isHoverTextureNone = function()
                return (DBVal("hoverOverlayTexture") or defaults.hoverOverlayTexture) == "none"
            end
            EllesmereUI.BuildInlineCog(leftRgn, {
                disabled = isHoverTextureNone,
                disabledTooltip = "a Hover Texture",
                title = "Hover Texture",
                rows = {
                    { type="toggle", label="Full alpha on empty part of bar",
                      get=function()
                        local v = DBVal("hoverOverlayFullBgAlpha")
                        if v == nil then return defaults.hoverOverlayFullBgAlpha end
                        return v
                      end,
                      set=function(v)
                        DB().hoverOverlayFullBgAlpha = v
                        ns.RefreshHoverEffect()
                        UpdatePreview()
                      end },
                },
            })
        end
            end

        -----------------------------------------------------------------------
        --  CLASS RESOURCE
        -----------------------------------------------------------------------
        local classResourceHeader
        classResourceHeader, h = W:SectionHeader(parent, "CLASS RESOURCE", y);  y = y - h

        local function classPowerDisabled() return DBVal("showClassPower") ~= true end

        local classResourceSectionTop = y  -- track top of content rows

        local classResourceToggleRow
        classResourceToggleRow, h = W:DualRow(parent, y,
            { type="toggle", text="Show Class Resource",
              getValue=function() return DBVal("showClassPower") == true end,
              -- DependentSetValue: Rows 2-4 below are hidden while class resource is off; the flip forces the full rebuild.
              setValue=EllesmereUI.DependentSetValue(
                  function() return DBVal("showClassPower") == true end,
                  function(v)
                    DB().showClassPower = v
                    ns.ApplyClassPowerSetting(); UpdatePreview()
                    EllesmereUI:RefreshPage()
                  end) },
            { type="multiSwatch", text="Fill Color",
              disabled=classPowerDisabled,
              disabledTooltip="Show Class Resource",
              swatches = {
                { tooltip = "Custom Color",
                  disabled = classPowerDisabled,
                  disabledTooltip = "Show Class Resource",
                  getValue = function()
                      local c = (DB() and DB().classPowerCustomColor) or defaults.classPowerCustomColor
                      return c.r, c.g, c.b
                  end,
                  setValue = function(r, g, b)
                      DB().classPowerCustomColor = { r = r, g = g, b = b }
                      ns.RefreshClassPower(); UpdatePreview()
                  end,
                  onClick = function(self)
                      local v = DBVal("classPowerClassColors")
                      if v == nil then v = defaults.classPowerClassColors end
                      if v then
                          DB().classPowerClassColors = false
                          ns.RefreshClassPower(); UpdatePreview()
                          EllesmereUI:RefreshPage()
                          return
                      end
                      if self._eabOrigClick then self._eabOrigClick(self) end
                  end,
                  refreshAlpha = function()
                      local v = DBVal("classPowerClassColors")
                      if v == nil then v = defaults.classPowerClassColors end
                      return v and 0.3 or 1
                  end },
                { tooltip = "Class Color",
                  disabled = classPowerDisabled,
                  disabledTooltip = "Show Class Resource",
                  getValue = function()
                      local _, ct = UnitClass("player")
                      if ct and RAID_CLASS_COLORS[ct] then
                          local cc = RAID_CLASS_COLORS[ct]
                          return cc.r, cc.g, cc.b, 1
                      end
                      return 1, 1, 1, 1
                  end,
                  setValue = function() end,
                  onClick = function()
                      DB().classPowerClassColors = true
                      ns.RefreshClassPower(); UpdatePreview()
                      EllesmereUI:RefreshPage()
                  end,
                  refreshAlpha = function()
                      local v = DBVal("classPowerClassColors")
                      if v == nil then v = defaults.classPowerClassColors end
                      return v and 1 or 0.3
                  end },
              } });  y = y - h

        -- Rows 2-4 are HIDDEN entirely while Show Class Resource is off (the toggle's DependentSetValue forces the rebuild on flips).
        if not classPowerDisabled() then
        -- Row 2: Position (with inline cog for X/Y) | Size
        local classResourceRow2
        classResourceRow2, h = W:DualRow(parent, y,
            { type="dropdown", text="Position",
              values={ top = "Top", bottom = "Bottom" },
              getValue=function() return DBVal("classPowerPos") or defaults.classPowerPos end,
              setValue=function(v)
                DB().classPowerPos = v
                ns.RefreshClassPower(); UpdatePreview()
              end, order={ "top", "bottom" } },
            { type="slider", text="Size", min=0.5, max=4.0, step=0.1,
              getValue=function() return DBVal("classPowerScale") or defaults.classPowerScale end,
              setValue=function(v)
                DB().classPowerScale = v
                ns.RefreshClassPower(); UpdatePreview()
              end });  y = y - h

        -- Inline cog on Position dropdown (X/Y offset settings)
        if not EllesmereUI._prebuilding then
            local leftRgn = classResourceRow2._leftRegion
            EllesmereUI.BuildInlineCog(leftRgn, {
                anchorTo = leftRgn._control,
                icon = EllesmereUI.DIRECTIONS_ICON,
                disabled = classPowerDisabled,
                disabledTooltip = "Show Class Resource",
                isOpen = CogPopupOpen,
                show = function(self)
                    ShowCogPopup(self, {
                        title = "Position Settings",
                        xGet = function() return DBVal("classPowerXOffset") or defaults.classPowerXOffset end,
                        xSet = function(v) DB().classPowerXOffset = v; ns.RefreshClassPower(); UpdatePreview() end,
                        yGet = function() return DBVal("classPowerYOffset") or defaults.classPowerYOffset end,
                        ySet = function(v) DB().classPowerYOffset = v; ns.RefreshClassPower(); UpdatePreview() end,
                    })
                end,
            })
        end

        -- Row 3: Bar Spacing + Background Color (with alpha)
        local classResourceRow3
        classResourceRow3, h = W:DualRow(parent, y,
            { type="slider", pixel=true, text="Bar Spacing", min=-5, max=10, step=1,
              getValue=function() return DBVal("classPowerGap") or defaults.classPowerGap end,
              setValue=function(v)
                DB().classPowerGap = v
                ns.RefreshClassPower(); UpdatePreview()
              end },
            { type="colorpicker", text="Background Color", hasAlpha=true,
              getValue=function()
                local c = (DB() and DB().classPowerBgColor) or defaults.classPowerBgColor
                return c.r, c.g, c.b, c.a
              end,
              setValue=function(r, g, b, a)
                DB().classPowerBgColor = { r=r, g=g, b=b, a=a }
                ns.RefreshClassPower(); UpdatePreview()
              end });  y = y - h

        -- Row 4: Shape | Border (inline color swatch + thickness cog on Border)
        local classResourceRow4
        classResourceRow4, h = W:DualRow(parent, y,
            { type="dropdown", text="Shape",
              values={ rectangle="Rectangle", square="Square", circle="Circle",
                       diamond="Diamond", hexagon="Hexagon", shield="Shield",
                       rune="Rune", holypower="Holy Power", shard="Soul Shard",
                       combo="Combo Points", chi="Chi", arcane="Arcane Charges",
                       essence="Essence" },
              order={ "rectangle", "square", "circle", "diamond", "hexagon", "shield",
                      "rune", "holypower", "shard", "combo", "chi", "arcane", "essence" },
              getValue=function() return DBVal("classPowerShape") or defaults.classPowerShape end,
              setValue=function(v)
                DB().classPowerShape = v
                ns.RefreshClassPower(); UpdatePreview()
              end },
            { type="toggle", text="Border",
              getValue=function() return DBVal("classPowerBorder") == true end,
              setValue=function(v)
                DB().classPowerBorder = v
                ns.RefreshClassPower(); UpdatePreview()
                EllesmereUI:RefreshPage()
              end });  y = y - h

        -- Inline border color swatch + thickness cog on the Border toggle
        if not EllesmereUI._prebuilding then
            local rgn = classResourceRow4._rightRegion
            local function borderOff()
                return classPowerDisabled() or DBVal("classPowerBorder") ~= true
            end
            local colorGet = function()
                local c = (DB() and DB().classPowerBorderColor) or defaults.classPowerBorderColor
                return c.r, c.g, c.b
            end
            local colorSet = function(r, g, b)
                DB().classPowerBorderColor = { r = r, g = g, b = b, a = 1 }
                ns.RefreshClassPower(); UpdatePreview()
            end
            local swatch, updateSwatch = EllesmereUI.BuildColorSwatch(rgn, rgn:GetFrameLevel() + 5, colorGet, colorSet, nil, 20)
            PP.Point(swatch, "RIGHT", rgn._control, "LEFT", -12, 0)
            rgn._lastInline = swatch
            EllesmereUI.RegisterWidgetRefresh(function()
                local off = borderOff()
                swatch:SetAlpha(off and 0.15 or 1)
                swatch:EnableMouse(not off)
                updateSwatch()
            end)
            local off = borderOff()
            swatch:SetAlpha(off and 0.15 or 1)
            swatch:EnableMouse(not off)

            EllesmereUI.BuildInlineCog(rgn, {
                icon = EllesmereUI.RESIZE_ICON, gap = 9,
                disabled = borderOff,
                disabledTooltip = "Border",
                title = "Border Settings",
                rows = {
                    { type="slider", label="Thickness", min=1, max=4, step=1,
                      get=function() return DBVal("classPowerBorderSize") or defaults.classPowerBorderSize end,
                      set=function(v) DB().classPowerBorderSize = v; ns.RefreshClassPower(); UpdatePreview() end },
                },
            })
        end
        end   -- close Class Resource hidden-while-disabled gate

        -- Invisible frame spanning the entire CLASS RESOURCE section for glow targeting
        local classResourceSection = CreateFrame("Frame", nil, parent)
        local crPad = EllesmereUI.CONTENT_PAD or 20
        classResourceSection:SetPoint("TOPLEFT", parent, "TOPLEFT", crPad, classResourceSectionTop)
        classResourceSection:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -crPad, classResourceSectionTop)
        classResourceSection:SetHeight(math.abs(classResourceSectionTop - y))
        classResourceSection._isSpacer = true  -- hide from search layout

        _, h = W:Spacer(parent, y, 20);  y = y - h

        -----------------------------------------------------------------------
        --  GENERAL TEXT
        -----------------------------------------------------------------------
        local generalTextHeader
        generalTextHeader, h = W:SectionHeader(parent, "GENERAL TEXT", y);  y = y - h

        -- Duration controls are per aura type. "None" is the show/hide switch.
        local auraDurPosRow
        local auraTimerStackRow
        do
            local durationTypes = {
                debuff = { text = "Debuff Duration", title = "Debuff Duration Settings", key = "debuffTimerPosition", count = 4, frames = function(p, i) return p.debuffs[i] end },
                buff = { text = "Buff Duration", title = "Buff Duration Settings", key = "buffTimerPosition", count = 4, frames = function(p, i) return p.buffs[i] end },
                cc = { text = "CC Duration", title = "CC Duration Settings", key = "ccTimerPosition", count = 2, frames = function(p, i) return p.cc[i] end },
            }
            local function DurationDropdown(kind)
                local cfg = durationTypes[kind]
                return { type="dropdown", text=cfg.text, values=timerPosValues,
                  getValue=function() return DBVal(cfg.key) or atFallback end,
                  setValue=function(v)
                    DB()[cfg.key] = v
                    LiveApplyTimerPos(cfg.frames, cfg.count, v, kind)
                    UpdatePreview()
                  end, order=timerPosOrder }
            end
            local function CurrentDurationPos(cfg)
                return DBVal(cfg.key) or atFallback
            end
            local function RefreshDuration(kind)
                local cfg = durationTypes[kind]
                LiveApplyTimerPos(cfg.frames, cfg.count, CurrentDurationPos(cfg), kind)
                UpdatePreview()
            end
            local function AttachDurationTools(region, kind)
                local cfg = durationTypes[kind]
                local colorGet = function()
                    local c = AuraDurationVal(kind, "Color")
                    return c.r, c.g, c.b
                end
                local colorSet = function(r, g, b)
                    DB()[kind .. "DurationTextColor"] = { r = r, g = g, b = b }
                    RefreshDuration(kind)
                end
                local swatch, updateSwatch = EllesmereUI.BuildColorSwatch(region, region:GetFrameLevel() + 5, colorGet, colorSet, nil, 20)
                PP.Point(swatch, "RIGHT", region._control, "LEFT", -12, 0)
                region._lastInline = swatch
                EllesmereUI.RegisterWidgetRefresh(function() updateSwatch() end)

                EllesmereUI.BuildInlineCog(region, {
                    icon = EllesmereUI.RESIZE_ICON, gap = 9,
                    title = cfg.title,
                    rows = {
                        { type="slider", label="Size", min=6, max=20, step=1,
                          get=function() return AuraDurationVal(kind, "Size") end,
                          set=function(v) DB()[kind .. "DurationTextSize"] = v; RefreshDuration(kind) end },
                        { type="slider", label="X", min=-50, max=50, step=1,
                          get=function() return AuraDurationVal(kind, "X") end,
                          set=function(v) DB()[kind .. "DurationTextX"] = v; RefreshDuration(kind) end },
                        { type="slider", label="Y", min=-50, max=50, step=1,
                          get=function() return AuraDurationVal(kind, "Y") end,
                          set=function(v) DB()[kind .. "DurationTextY"] = v; RefreshDuration(kind) end },
                    },
                })
            end

            local durationRow1
            durationRow1, h = W:DualRow(parent, y, DurationDropdown("debuff"), DurationDropdown("buff")); y = y - h
            auraDurPosRow = durationRow1
            if not EllesmereUI._prebuilding then
            AttachDurationTools(durationRow1._leftRegion, "debuff")
            AttachDurationTools(durationRow1._rightRegion, "buff")
            end

            local durationRow2
            durationRow2, h = W:DualRow(parent, y,
                DurationDropdown("cc"),
                { type="dropdown", text="Aura Stacks", values=timerPosValues,
                  getValue=function() return DBVal("auraStackTextPosition") or asFallback end,
                  setValue=function(v)
                    DB().auraStackTextPosition = v
                    LiveApplyStackPos(function(p, i) return p.debuffs[i] end, 4, v)
                    LiveApplyStackPos(function(p, i) return p.buffs[i] end, 4, v)
                    UpdatePreview()
                  end, order=timerPosOrder }); y = y - h
            auraTimerStackRow = durationRow2
            if not EllesmereUI._prebuilding then
            AttachDurationTools(durationRow2._leftRegion, "cc")
            end

            if not EllesmereUI._prebuilding then
            -- RIGHT: Aura Stacks inline color swatch
            local rightRgn = durationRow2._rightRegion
            local asColorGet = function()
                local c = (DB() and DB().auraStackTextColor) or defaults.auraStackTextColor
                return c.r, c.g, c.b
            end
            local asColorSet = function(r, g, b)
                DB().auraStackTextColor = { r = r, g = g, b = b }
                for _, plate in pairs(plates) do
                    for i = 1, 4 do
                        if plate.debuffs[i] and plate.debuffs[i].count then
                            plate.debuffs[i].count:SetTextColor(r, g, b, 1)
                        end
                        if plate.buffs[i] and plate.buffs[i].count then
                            plate.buffs[i].count:SetTextColor(r, g, b, 1)
                        end
                    end
                end
                if ns.NPC_ReloadAll then ns.NPC_ReloadAll() end -- 12.1 containers
                UpdatePreview()
            end
            local asSwatch, asUpdateSwatch = EllesmereUI.BuildColorSwatch(rightRgn, rightRgn:GetFrameLevel() + 5, asColorGet, asColorSet, nil, 20)
            PP.Point(asSwatch, "RIGHT", rightRgn._control, "LEFT", -12, 0)
            rightRgn._lastInline = asSwatch
            EllesmereUI.RegisterWidgetRefresh(function() asUpdateSwatch() end)

            -- RIGHT: Aura Stacks inline cog (Size / X / Y)
            EllesmereUI.BuildInlineCog(rightRgn, {
                icon = EllesmereUI.RESIZE_ICON, gap = 9,
                title = "Aura Stacks Settings",
                rows = {
                    { type="slider", label="Size", min=6, max=20, step=1,
                      get=function() return DBVal("auraStackTextSize") or defaults.auraStackTextSize end,
                      set=function(v)
                        DB().auraStackTextSize = v
                        for _, plate in pairs(plates) do
                            for i = 1, 4 do
                                if plate.debuffs[i] and plate.debuffs[i].count then
                                    SetFSFont(plate.debuffs[i].count, v, "OUTLINE, SLUG")
                                end
                                if plate.buffs[i] and plate.buffs[i].count then
                                    SetFSFont(plate.buffs[i].count, v, "OUTLINE, SLUG")
                                end
                            end
                        end
                        if ns.NPC_ReloadAll then ns.NPC_ReloadAll() end -- 12.1 containers
                        UpdatePreview()
                      end },
                    { type="slider", label="X", min=-50, max=50, step=1,
                      get=function() return DBVal("auraStackTextX") or defaults.auraStackTextX end,
                      set=function(v)
                        DB().auraStackTextX = v
                        LiveApplyStackPos(function(p, i) return p.debuffs[i] end, 4, DBVal("auraStackTextPosition") or asFallback)
                        LiveApplyStackPos(function(p, i) return p.buffs[i] end, 4, DBVal("auraStackTextPosition") or asFallback)
                        UpdatePreview()
                      end },
                    { type="slider", label="Y", min=-50, max=50, step=1,
                      get=function() return DBVal("auraStackTextY") or defaults.auraStackTextY end,
                      set=function(v)
                        DB().auraStackTextY = v
                        LiveApplyStackPos(function(p, i) return p.debuffs[i] end, 4, DBVal("auraStackTextPosition") or asFallback)
                        LiveApplyStackPos(function(p, i) return p.buffs[i] end, 4, DBVal("auraStackTextPosition") or asFallback)
                        UpdatePreview()
                      end },
                },
            })
            end
        end

        -- Spell Name | Spell Target: position dropdowns (None/Left/Right/Center), styled like the duration dropdowns. Name and target can't share a side (setting one onto the other's side bumps it to None); Size/X/Y live in each row's inline cog.
        local castTextPosValues = { none = "None", left = "Left", right = "Right", center = "Center" }
        local castTextPosOrder = { "none", "left", "right", "center" }
        local spellNameRow
        spellNameRow, h = W:DualRow(parent, y,
            { type="dropdown", text="Spell Name", values=castTextPosValues, order=castTextPosOrder,
              getValue=function() return (DB() and DB().castNameSide) or defaults.castNameSide end,
              setValue=function(v)
                DB().castNameSide = v
                if v ~= "none" then
                    local ts = (DB() and DB().castTargetSide) or defaults.castTargetSide
                    if ts == v then DB().castTargetSide = "none" end
                end
                ns.RefreshAllSettings()
                UpdatePreview()
                EllesmereUI:RefreshPage()
              end },
            { type="dropdown", text="Spell Target", values=castTextPosValues, order=castTextPosOrder,
              disabled=function() return DBVal("castCombineNameTarget") == true end,
              disabledTooltip="This option requires Combine Spell Name and Target to be disabled.",
              getValue=function() return (DB() and DB().castTargetSide) or defaults.castTargetSide end,
              setValue=function(v)
                DB().castTargetSide = v
                if v ~= "none" then
                    local nss = (DB() and DB().castNameSide) or defaults.castNameSide
                    if nss == v then DB().castNameSide = "none" end
                end
                ns.RefreshAllSettings()
                UpdatePreview()
                EllesmereUI:RefreshPage()
              end })
        if not EllesmereUI._prebuilding then
            -- LEFT: Spell Name inline color swatch
            local leftRgn = spellNameRow._leftRegion
            local snColorGet = function() return DBColor("castNameColor") end
            local snColorSet = function(r, g, b)
                DB().castNameColor = { r = r, g = g, b = b }
                for _, plate in pairs(plates) do
                    if plate.castName then plate.castName:SetTextColor(r, g, b, 1) end
                end
                UpdatePreview()
            end
            local snSwatch, snUpdateSwatch = EllesmereUI.BuildColorSwatch(leftRgn, leftRgn:GetFrameLevel() + 5, snColorGet, snColorSet, nil, 20)
            PP.Point(snSwatch, "RIGHT", leftRgn._control, "LEFT", -12, 0)
            EllesmereUI.RegisterWidgetRefresh(function() snUpdateSwatch() end)

            -- LEFT: Spell Name inline cog for X/Y offset
            EllesmereUI.BuildInlineCog(leftRgn, {
                chain = false, anchorTo = snSwatch, gap = 6,
                icon = EllesmereUI.RESIZE_ICON,
                isOpen = CogPopupOpen,
                show = function(self)
                    ShowCogPopup(self, {
                        title = EllesmereUI.L("Spell Name Settings"),
                        xGet = function() return DBVal("castNameOffsetX") or defaults.castNameOffsetX end,
                        xSet = function(v) DB().castNameOffsetX = v; ns.RefreshAllSettings(); UpdatePreview() end,
                        yGet = function() return DBVal("castNameOffsetY") or defaults.castNameOffsetY end,
                        ySet = function(v) DB().castNameOffsetY = v; ns.RefreshAllSettings(); UpdatePreview() end,
                        sizeGet = function() return DBVal("castNameSize") or defaults.castNameSize end,
                        sizeSet = function(v) DB().castNameSize = v; ns.RefreshAllSettings(); UpdatePreview() end,
                        sizeMin = 6, sizeMax = 20, sizeLabel = EllesmereUI.L("Size"),
                        sizeFirst = true,
                        widthGet = function() return DBVal("castNameWidthPct") or defaults.castNameWidthPct end,
                        widthSet = function(v) DB().castNameWidthPct = v; ns.RefreshAllSettings(); UpdatePreview() end,
                        wrapGet = function() return DBVal("castNameWrap") == true end,
                        wrapSet = function(v) DB().castNameWrap = v; ns.RefreshAllSettings(); UpdatePreview() end,
                        toggleLabel = "Combine Spell Name and Target",
                        toggleGet = function() return DBVal("castCombineNameTarget") == true end,
                        toggleSet = function(v)
                            DB().castCombineNameTarget = v
                            ns.RefreshAllSettings()
                            UpdatePreview()
                            EllesmereUI:RefreshPage()
                        end,
                    })
                end,
            })

            -- RIGHT: Spell Target inline double swatch (custom + class colored)
            local rightRgn = spellNameRow._rightRegion
            local ctrl = rightRgn._control

            -- Class colored swatch (rightmost)
            local ccGet = function()
                local _, ct = UnitClass("player")
                if ct and RAID_CLASS_COLORS[ct] then
                    local cc = RAID_CLASS_COLORS[ct]
                    return cc.r, cc.g, cc.b
                end
                return 1, 1, 1
            end
            local ccSwatch, ccUpdate = EllesmereUI.BuildColorSwatch(rightRgn, rightRgn:GetFrameLevel() + 5, ccGet, function() end, nil, 20)
            PP.Point(ccSwatch, "RIGHT", ctrl, "LEFT", -12, 0)
            ccSwatch:SetScript("OnClick", function()
                DB().castTargetClassColor = true
                for _, plate in pairs(plates) do plate:UpdateHealth() end
                UpdatePreview()
                EllesmereUI:RefreshPage()
            end)
            ccSwatch:SetScript("OnEnter", function() EllesmereUI.ShowWidgetTooltip(ccSwatch, "Class Color") end)
            ccSwatch:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)

            -- Custom color swatch (to the left of class swatch)
            local stColorGet = function() return DBColor("castTargetColor") end
            local stColorSet = function(r, g, b)
                DB().castTargetColor = { r = r, g = g, b = b }
                for _, plate in pairs(plates) do plate:UpdateHealth() end
                UpdatePreview()
            end
            local stSwatch, stUpdate = EllesmereUI.BuildColorSwatch(rightRgn, rightRgn:GetFrameLevel() + 5, stColorGet, stColorSet, nil, 20)
            PP.Point(stSwatch, "RIGHT", ccSwatch, "LEFT", -9, 0)
            stSwatch._eabOrigClick = stSwatch:GetScript("OnClick")
            stSwatch:SetScript("OnClick", function(self)
                local db = DB()
                local cc = db and db.castTargetClassColor
                if cc == nil then cc = defaults.castTargetClassColor end
                if cc then
                    DB().castTargetClassColor = false
                    for _, plate in pairs(plates) do plate:UpdateHealth() end
                    UpdatePreview()
                    EllesmereUI:RefreshPage()
                    return
                end
                if self._eabOrigClick then self._eabOrigClick(self) end
            end)
            stSwatch:SetScript("OnEnter", function() EllesmereUI.ShowWidgetTooltip(stSwatch, "Custom Color") end)
            stSwatch:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)

            EllesmereUI.RegisterWidgetRefresh(function()
                local db = DB()
                local isCC = db and db.castTargetClassColor
                if isCC == nil then isCC = defaults.castTargetClassColor end
                stSwatch:SetAlpha(isCC and 0.3 or 1)
                ccSwatch:SetAlpha(isCC and 1 or 0.3)
                stUpdate()
                ccUpdate()
            end)
            local isCC = (DB() and DB().castTargetClassColor)
            if isCC == nil then isCC = defaults.castTargetClassColor end
            stSwatch:SetAlpha(isCC and 0.3 or 1)
            ccSwatch:SetAlpha(isCC and 1 or 0.3)

            -- RIGHT: Spell Target inline cog for X/Y offset
            EllesmereUI.BuildInlineCog(rightRgn, {
                chain = false, anchorTo = stSwatch, gap = 6,
                icon = EllesmereUI.RESIZE_ICON,
                isOpen = CogPopupOpen,
                show = function(self)
                    ShowCogPopup(self, {
                        title = EllesmereUI.L("Spell Target Settings"),
                        xGet = function() return DBVal("castTargetOffsetX") or defaults.castTargetOffsetX end,
                        xSet = function(v) DB().castTargetOffsetX = v; ns.RefreshAllSettings(); UpdatePreview() end,
                        yGet = function() return DBVal("castTargetOffsetY") or defaults.castTargetOffsetY end,
                        ySet = function(v) DB().castTargetOffsetY = v; ns.RefreshAllSettings(); UpdatePreview() end,
                        sizeGet = function() return DBVal("castTargetSize") or defaults.castTargetSize end,
                        sizeSet = function(v) DB().castTargetSize = v; ns.RefreshAllSettings(); UpdatePreview() end,
                        sizeMin = 6, sizeMax = 20, sizeLabel = EllesmereUI.L("Size"),
                        sizeFirst = true,
                        widthGet = function() return DBVal("castTargetWidthPct") or defaults.castTargetWidthPct end,
                        widthSet = function(v) DB().castTargetWidthPct = v; ns.RefreshAllSettings(); UpdatePreview() end,
                        wrapGet = function() return DBVal("castTargetWrap") == true end,
                        wrapSet = function(v) DB().castTargetWrap = v; ns.RefreshAllSettings(); UpdatePreview() end,
                    })
                end,
            })
        end
        y = y - h

        -----------------------------------------------------------------------
        --  CLICK NAVIGATION: glow, scroll, mapping, hit overlays
        -----------------------------------------------------------------------
        local PlaySettingGlow = EllesmereUI.MakeSettingGlow({ color = EllesmereUI.ELLESMERE_GREEN, thickness = function() return PP.Scale(2) end, noSnap = true })

        -- Maps Core Position slot keys to their row/region
        local corePosToRow = {
            top      = { row = coreRow1, side = "_leftRegion" },
            right    = { row = coreRow1, side = "_rightRegion" },
            left     = { row = coreRow2, side = "_leftRegion" },
            topright = { row = coreRow2, side = "_rightRegion" },
            topleft  = { row = coreRow3, side = "_leftRegion" },
        }

        -- Maps Core Text Position slot keys to their row/region
        local textSlotToRow = {
            textSlotTop    = { row = textRow1, side = "_leftRegion" },
            textSlotRight  = { row = textRow1, side = "_rightRegion" },
            textSlotLeft   = { row = textRow2, side = "_leftRegion" },
            textSlotCenter = { row = textRow2, side = "_rightRegion" },
            textSlotBottomLeft  = { row = textRow3, side = "_leftRegion" },
            textSlotBottomRight = { row = textRow3, side = "_rightRegion" },
        }

        -- Reverse lookup: find which Core Position slot holds a given element
        local function FindCorePosForElement(element)
            local db = DB()
            local key = elementToKey[element]
            if not key then return nil end
            local pos = db[key] or defaults[key]
            if pos == "none" then return nil end
            return pos
        end

        -- Reverse lookup: find which text slot holds a given element
        local function FindTextSlotForElement(element)
            local db = DB()
            for _, key in ipairs(textSlotKeys) do
                if (db[key] or defaults[key]) == element then return key end
            end
            return nil
        end

        -- Resolve a dynamic click mapping for icon elements Core Positions row
        local function ResolveCoreMapping(element)
            local pos = FindCorePosForElement(element)
            if not pos then return { section = coreHeader, target = coreRow1 } end
            local info = corePosToRow[pos]
            if not info then return { section = coreHeader, target = coreRow1 } end
            return { section = coreHeader, target = info.row, slotSide = (info.side == "_leftRegion") and "left" or "right" }
        end

        local clickMappings = {
            debuffDuration = { section = generalTextHeader, target = auraDurPosRow,      slotSide = "left" },
            buffDuration = { section = generalTextHeader,   target = auraDurPosRow,      slotSide = "right" },
            ccDuration = { section = generalTextHeader,     target = auraTimerStackRow,  slotSide = "left" },
            auraStack    = { section = generalTextHeader,  target = auraTimerStackRow,   slotSide = "right" },
            castBar      = { section = healthBarHeader,  target = castBarHeightRow,    slotSide = "left" },
            castIcon     = { section = healthBarHeader,  target = showCastIconRow,     slotSide = "right" },
            castTimer    = { section = healthBarHeader,  target = castTimerRow,        slotSide = "left" },
            castName     = { section = generalTextHeader, target = spellNameRow,        slotSide = "left" },
            castTarget   = { section = generalTextHeader, target = spellNameRow,        slotSide = "right" },
            healthBar    = { section = healthBarHeader,  target = healthBarHeightRow },
            classResource = { section = classResourceHeader, target = classResourceSection },
            targetArrows = { section = tfxHeader,            target = targetGlowRow,       slotSide = "right" },
        }

        -- Dynamic resolvers for elements assigned to Core Positions / Core Text Positions
        local dynamicMappings = {
            -- Classic WoW UI: the level in the health border's plate. Its row
            -- exists only on that style, so this resolves to nothing elsewhere.
            classicLevel = function()
                local row = parent._classicPlateRow
                if not row then return nil end
                return { section = styleHeader, target = row, slotSide = "left" }
            end,
            -- WoW Forever: the level box, whose row exists only under that
            -- variant.
            foreverLevelBox = function()
                local row = parent._foreverBoxRow
                if not row then return nil end
                return { section = styleHeader, target = row, slotSide = "left" }
            end,
            debuffIcon   = function() return ResolveCoreMapping("debuffs") end,
            buffIcon     = function() return ResolveCoreMapping("buffs") end,
            ccIcon       = function() return ResolveCoreMapping("ccs") end,
            raidMarker   = function() return ResolveCoreMapping("raidmarker") end,
            classIcon    = function() return ResolveCoreMapping("classification") end,
            -- Combined with Rare/Quest, the badge's settings live on that row.
            factionIcon  = function()
                if DB().classificationIncludeFaction then return ResolveCoreMapping("classification") end
                return ResolveCoreMapping("faction")
            end,
            enemyName    = function()
                -- The name FontString renders whichever name-family variant is slotted; resolve the row for any of them.
                local slot = FindTextSlotForElement("enemyName") or FindTextSlotForElement("levelName") or FindTextSlotForElement("nameLevel")
                if not slot then return { section = coreTextHeader, target = textRow1 } end
                local info = textSlotToRow[slot]
                if not info then return { section = coreTextHeader, target = textRow1 } end
                return { section = coreTextHeader, target = info.row, slotSide = (info.side == "_leftRegion") and "left" or "right" }
            end,
            healthText   = function()
                local slot = FindTextSlotForElement("healthPercent") or FindTextSlotForElement("healthPercentNoSign") or FindTextSlotForElement("healthPctNum") or FindTextSlotForElement("healthNumPct") or FindTextSlotForElement("healthPctNumDash") or FindTextSlotForElement("healthNumPctDash")
                if not slot then return { section = coreTextHeader, target = textRow1 } end
                local info = textSlotToRow[slot]
                if not info then return { section = coreTextHeader, target = textRow1 } end
                return { section = coreTextHeader, target = info.row, slotSide = (info.side == "_leftRegion") and "left" or "right" }
            end,
        }
        -- The font strings a single element owns: the row of the slot showing it.
        for mapKey, element in pairs({ healthNumber = "healthNumber", levelText = "level", targetOfTarget = "targetOfTarget" }) do
            dynamicMappings[mapKey] = function()
                local info = textSlotToRow[FindTextSlotForElement(element) or ""]
                if not info then return { section = coreTextHeader, target = textRow1 } end
                return { section = coreTextHeader, target = info.row, slotSide = (info.side == "_leftRegion") and "left" or "right" }
            end
        end

        local function NavigateToSetting(key)
            local m = clickMappings[key]
            -- Check dynamic mappings (icon/text elements assigned to Core Positions)
            if not m then
                local resolver = dynamicMappings[key]
                if resolver then m = resolver() end
            end
            if not m or not m.section or not m.target then return end

            -- Header grows by 29 but shrinks by 39 (kept as shipped).
            EllesmereUI.DismissPreviewHint(optState._previewHintFS, _headerBaseH, 29, 17)

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

        -- Hit overlay factory for preview elements. opts (optional): hlAnchor = frame to draw the highlight around (instead of btn); hlBehindText = true draws it on a child frame at icon level+1 (text lives at icon level+2).
        local function SnapPreview(val)
            local s = optState.activePreview and optState.activePreview:GetEffectiveScale() or 1
            if s <= 0 then s = 1 end
            return math.floor(val * s + 0.5) / s
        end
        -- Destroy any stale hit overlays from a previous BuildDisplayPage call (RefreshPage can re-call buildPage without cleaning the preview).
        if optState.activePreview and optState.activePreview._hitOverlays then
            for i = 1, #optState.activePreview._hitOverlays do
                local ov = optState.activePreview._hitOverlays[i]
                ov:EnableMouse(false)
                ov:Hide()
                ov:SetParent(nil)
            end
            wipe(optState.activePreview._hitOverlays)
        end

        local allOverlays = {}

        local hitStyle = { container = true }
        local function CreateHitOverlay(element, mappingKey, isText, frameLevelOverride, opts)
            local btn, hlBase, hlCont = EllesmereUI.CreatePreviewHitOverlay(element, NavigateToSetting, mappingKey, isText, frameLevelOverride, opts, hitStyle)
            allOverlays[#allOverlays + 1] = btn
            if hlBase ~= btn then allOverlays[#allOverlays + 1] = hlBase end
            allOverlays[#allOverlays + 1] = hlCont
            return btn
        end

        -- Create hit overlays for all interactive preview elements
        local textOverlays = {}  -- collect text overlays for size refresh
        if optState.activePreview then
            local pv = optState.activePreview
            -- Icon overlays need to be above the icon frames (which are at health:GetFrameLevel() + 8)
            local iconLevel = (pv._health and pv._health:GetFrameLevel() or 20) + 15
            -- Text overlays on icons need to be above the icon overlays
            local textOnIconLevel = iconLevel + 10
            -- Aura icons (all debuffs, buffs, ccs)
            local iconHlOpts = { hlBehindText = true }
            if pv._ccs then
                for i = 1, #pv._ccs do
                    if pv._ccs[i] then
                        CreateHitOverlay(pv._ccs[i], "ccIcon", false, iconLevel, iconHlOpts)
                        if pv._ccs[i].durationText then
                            local ov = CreateHitOverlay(pv._ccs[i].durationText, "ccDuration", true, textOnIconLevel)
                            textOverlays[#textOverlays + 1] = ov
                        end
                    end
                end
            end
            if pv._buffs then
                for i = 1, #pv._buffs do
                    if pv._buffs[i] then
                        CreateHitOverlay(pv._buffs[i], "buffIcon", false, iconLevel, iconHlOpts)
                        if pv._buffs[i].durationText then
                            local ov = CreateHitOverlay(pv._buffs[i].durationText, "buffDuration", true, textOnIconLevel)
                            textOverlays[#textOverlays + 1] = ov
                        end
                    end
                end
            end
            if pv._debuffs then
                for i = 1, #pv._debuffs do
                    if pv._debuffs[i] then
                        CreateHitOverlay(pv._debuffs[i], "debuffIcon", false, iconLevel, iconHlOpts)
                        if pv._debuffs[i].durationText then
                            local ov = CreateHitOverlay(pv._debuffs[i].durationText, "debuffDuration", true, textOnIconLevel)
                            textOverlays[#textOverlays + 1] = ov
                        end
                        if pv._debuffs[i].stackText then
                            local ov = CreateHitOverlay(pv._debuffs[i].stackText, "auraStack", true, textOnIconLevel)
                            textOverlays[#textOverlays + 1] = ov
                        end
                    end
                end
            end
            -- Cast icon overlay (separate from cast bar navigates to Show Spell Icon row)
            local castOverlayLevel
            if pv._cast then
                castOverlayLevel = pv._cast:GetFrameLevel() + 20
                local cc = EllesmereUI.ELLESMERE_GREEN
                -- Cast icon overlay
                if pv._castIconFrame then
                    local iconOv = CreateFrame("Button", nil, pv._cast:GetParent())
                    iconOv:SetAllPoints(pv._castIconFrame)
                    iconOv:SetFrameLevel(castOverlayLevel)
                    iconOv:RegisterForClicks("LeftButtonDown")
                    local ioBrd = EllesmereUI.PP.CreateBorder(iconOv, cc.r, cc.g, cc.b, 1, 2, "OVERLAY", 7)
                    ioBrd:Hide()
                    iconOv:SetScript("OnEnter", function() ioBrd:Show() end)
                    iconOv:SetScript("OnLeave", function() ioBrd:Hide() end)
                    iconOv:SetScript("OnMouseDown", function() NavigateToSetting("castIcon") end)
                    allOverlays[#allOverlays + 1] = iconOv
                end
                -- Cast bar overlay (bar only, not icon)
                local castOverlay = CreateFrame("Button", nil, pv._cast:GetParent())
                castOverlay:SetAllPoints(pv._cast)
                castOverlay:SetFrameLevel(castOverlayLevel)
                castOverlay:RegisterForClicks("LeftButtonDown")
                local coBrd = EllesmereUI.PP.CreateBorder(castOverlay, cc.r, cc.g, cc.b, 1, 2, "OVERLAY", 7)
                coBrd:Hide()
                castOverlay:SetScript("OnEnter", function() coBrd:Show() end)
                castOverlay:SetScript("OnLeave", function() coBrd:Hide() end)
                castOverlay:SetScript("OnMouseDown", function() NavigateToSetting("castBar") end)
                allOverlays[#allOverlays + 1] = castOverlay
            end
            -- Cast spell name and target text (above the cast bar overlay)
            local castTextLevel = (castOverlayLevel or 30) + 5
            if pv._castNameFS and pv._castNameFS:IsShown() then
                local ov = CreateHitOverlay(pv._castNameFS, "castName", true, castTextLevel)
                textOverlays[#textOverlays + 1] = ov
            end
            if pv._castTargetFS and pv._castTargetFS:IsShown() then
                local ov = CreateHitOverlay(pv._castTargetFS, "castTarget", true, castTextLevel)
                textOverlays[#textOverlays + 1] = ov
            end
            if pv._castTimerFS and pv._castTimerFS:IsShown() then
                local ov = CreateHitOverlay(pv._castTimerFS, "castTimer", true, castTextLevel)
                textOverlays[#textOverlays + 1] = ov
            end
            -- Enemy name text
            if pv._nameFS then
                local ov = CreateHitOverlay(pv._nameFS, "enemyName", true)
                textOverlays[#textOverlays + 1] = ov
            end
            -- Health text
            if pv._hpText then
                local ov = CreateHitOverlay(pv._hpText, "healthText", true)
                textOverlays[#textOverlays + 1] = ov
            end
            -- Health #, standalone level and Target of Target: each on its own font
            -- string, shown only while a slot holds it, so the overlay follows the
            -- text's shown state (_syncFS, re-read on every preview update).
            for fsKey, mapKey in pairs({ _hpNumber = "healthNumber", _lvlText = "levelText", _totFS = "targetOfTarget" }) do
                local fs = pv[fsKey]
                if fs then
                    local ov = CreateHitOverlay(fs, mapKey, true)
                    ov._syncFS = fs
                    ov:SetShown(fs:IsShown())
                    textOverlays[#textOverlays + 1] = ov
                end
            end
            -- Classic WoW UI: the level in the health border's plate
            if pv._classicLevel then
                local ov = CreateHitOverlay(pv._classicLevel, "classicLevel", true)
                textOverlays[#textOverlays + 1] = ov
            end
            -- WoW Forever: the level box (its child, so it hides with it)
            if pv._fvLevelBox then
                CreateHitOverlay(pv._fvLevelBox, "foreverLevelBox")
            end
            -- Health bar
            if pv._health then
                CreateHitOverlay(pv._health, "healthBar")
            end
            -- Raid marker
            local raidOverlay
            if pv._raidFrame then
                raidOverlay = CreateHitOverlay(pv._raidFrame, "raidMarker")
                if not optState.showRaidMarkerPreview then raidOverlay:Hide() end
            end
            -- Rare/elite icon
            local classOverlay
            if pv._classIcon then
                classOverlay = CreateHitOverlay(pv._classIcon, "classIcon")
                if not optState.showClassificationPreview then classOverlay:Hide() end
            end
            -- Faction badge: shown and hidden with the badge by the preview update.
            if pv._factionIcon then
                pv._factionOverlay = CreateHitOverlay(pv._factionIcon, "factionIcon")
                pv._factionOverlay:SetShown(pv._factionIcon:IsShown())
            end
            -- Class resource pips wrapper button spanning all visible pips
            local cpOverlay
            if pv._cpPips then
                local firstVis, lastVis
                for i = 1, pv._cpMax do
                    if pv._cpPips[i] and pv._cpPips[i]:IsShown() then
                        if not firstVis then firstVis = pv._cpPips[i] end
                        lastVis = pv._cpPips[i]
                    end
                end
                -- Bar-type resource: use the bar frame as anchor
                local useBar = (not firstVis) and pv._cpBar and pv._cpBar:IsShown()
                local anchorFirst = firstVis or (useBar and pv._cpBar)
                local anchorLast  = lastVis  or (useBar and pv._cpBar)
                if anchorFirst and anchorLast then
                    local cpBtn = CreateFrame("Button", nil, pv)
                    cpBtn:SetPoint("TOPLEFT", anchorFirst, "TOPLEFT", -2, 2)
                    cpBtn:SetPoint("BOTTOMRIGHT", anchorLast, "BOTTOMRIGHT", 2, -2)
                    cpBtn:SetFrameLevel((pv._health and pv._health:GetFrameLevel() or 20) + 15)
                    cpBtn:RegisterForClicks("LeftButtonDown")
                    local cc = EllesmereUI.ELLESMERE_GREEN
                    local function MkCPHL()
                        local t = cpBtn:CreateTexture(nil, "OVERLAY", nil, 7)
                        t:SetColorTexture(cc.r, cc.g, cc.b, 1)
                        if t.SetSnapToPixelGrid then t:SetSnapToPixelGrid(false); t:SetTexelSnappingBias(0) end
                        return t
                    end
                    local cpPx = SnapPreview(2)
                    local cpt = MkCPHL(); cpt:SetHeight(cpPx); cpt:SetPoint("TOPLEFT"); cpt:SetPoint("TOPRIGHT")
                    local cpb = MkCPHL(); cpb:SetHeight(cpPx); cpb:SetPoint("BOTTOMLEFT"); cpb:SetPoint("BOTTOMRIGHT")
                    local cpl = MkCPHL(); cpl:SetWidth(cpPx); cpl:SetPoint("TOPLEFT", cpt, "BOTTOMLEFT"); cpl:SetPoint("BOTTOMLEFT", cpb, "TOPLEFT")
                    local cpr = MkCPHL(); cpr:SetWidth(cpPx); cpr:SetPoint("TOPRIGHT", cpt, "BOTTOMRIGHT"); cpr:SetPoint("BOTTOMRIGHT", cpb, "TOPRIGHT")
                    cpBtn._hlTextures = { cpt, cpb, cpl, cpr }
                    local function ShowCPHL() for _, t in ipairs(cpBtn._hlTextures) do t:Show() end end
                    local function HideCPHL() for _, t in ipairs(cpBtn._hlTextures) do t:Hide() end end
                    HideCPHL()
                    cpBtn:SetScript("OnEnter", function() ShowCPHL() end)
                    cpBtn:SetScript("OnLeave", function() HideCPHL() end)
                    cpBtn:SetScript("OnMouseDown", function() NavigateToSetting("classResource") end)
                    cpOverlay = cpBtn
                    allOverlays[#allOverlays + 1] = cpBtn
                    -- Disable hover/click when class resource setting is off
                    local function UpdateCPOverlay()
                        local off = DBVal("showClassPower") ~= true
                        cpBtn:EnableMouse(not off)
                        cpBtn:SetAlpha(off and 0 or 1)
                    end
                    EllesmereUI.RegisterWidgetRefresh(UpdateCPOverlay)
                    UpdateCPOverlay()
                end
            end
            -- Sync overlay visibility with preview toggles
            pv._raidOverlay = raidOverlay
            pv._classOverlay = classOverlay
            -- Target arrows wrapper button spanning both arrow textures
            local arrowOverlay
            if pv._arrows then
                local arrowBtn = CreateFrame("Button", nil, pv)
                arrowBtn:SetPoint("TOPLEFT", pv._arrows.left, "TOPLEFT", -2, 2)
                arrowBtn:SetPoint("BOTTOMRIGHT", pv._arrows.right, "BOTTOMRIGHT", 2, -2)
                arrowBtn:SetFrameLevel((pv._health and pv._health:GetFrameLevel() or 20) + 15)
                arrowBtn:RegisterForClicks("LeftButtonDown")
                local cc = EllesmereUI.ELLESMERE_GREEN
                local function MkAHL()
                    local t = arrowBtn:CreateTexture(nil, "OVERLAY", nil, 7)
                    t:SetColorTexture(cc.r, cc.g, cc.b, 1)
                    if t.SetSnapToPixelGrid then t:SetSnapToPixelGrid(false); t:SetTexelSnappingBias(0) end
                    return t
                end
                -- Highlight on left arrow
                local aPx = SnapPreview(2)
                local alt = MkAHL(); alt:SetHeight(aPx); alt:SetPoint("TOPLEFT", pv._arrows.left, -2, 2); alt:SetPoint("TOPRIGHT", pv._arrows.left, 2, 2)
                local alb = MkAHL(); alb:SetHeight(aPx); alb:SetPoint("BOTTOMLEFT", pv._arrows.left, -2, -2); alb:SetPoint("BOTTOMRIGHT", pv._arrows.left, 2, -2)
                local all = MkAHL(); all:SetWidth(aPx); all:SetPoint("TOPLEFT", alt, "BOTTOMLEFT"); all:SetPoint("BOTTOMLEFT", alb, "TOPLEFT")
                local alr = MkAHL(); alr:SetWidth(aPx); alr:SetPoint("TOPRIGHT", alt, "BOTTOMRIGHT"); alr:SetPoint("BOTTOMRIGHT", alb, "TOPRIGHT")
                -- Highlight on right arrow
                local art = MkAHL(); art:SetHeight(aPx); art:SetPoint("TOPLEFT", pv._arrows.right, -2, 2); art:SetPoint("TOPRIGHT", pv._arrows.right, 2, 2)
                local arb = MkAHL(); arb:SetHeight(aPx); arb:SetPoint("BOTTOMLEFT", pv._arrows.right, -2, -2); arb:SetPoint("BOTTOMRIGHT", pv._arrows.right, 2, -2)
                local arl = MkAHL(); arl:SetWidth(aPx); arl:SetPoint("TOPLEFT", art, "BOTTOMLEFT"); arl:SetPoint("BOTTOMLEFT", arb, "TOPLEFT")
                local arr = MkAHL(); arr:SetWidth(aPx); arr:SetPoint("TOPRIGHT", art, "BOTTOMRIGHT"); arr:SetPoint("BOTTOMRIGHT", arb, "TOPRIGHT")
                arrowBtn._hlTextures = { alt, alb, all, alr, art, arb, arl, arr }
                local function ShowAHL() for _, t in ipairs(arrowBtn._hlTextures) do t:Show() end end
                local function HideAHL() for _, t in ipairs(arrowBtn._hlTextures) do t:Hide() end end
                HideAHL()
                arrowBtn:SetScript("OnEnter", function() ShowAHL() end)
                arrowBtn:SetScript("OnLeave", function() HideAHL() end)
                arrowBtn:SetScript("OnMouseDown", function() NavigateToSetting("targetArrows") end)
                -- Only show when arrows are visible
                if not pv._arrows.left:IsShown() then arrowBtn:Hide() end
                arrowOverlay = arrowBtn
                allOverlays[#allOverlays + 1] = arrowBtn
            end
            pv._arrowOverlay = arrowOverlay
            -- Store text overlays for size refresh on preview update
            pv._textOverlays = textOverlays
            -- Store all overlays for cleanup on next rebuild
            pv._hitOverlays = allOverlays
        end

        return math.abs(y)
    end

    ---------------------------------------------------------------------------
    --  Colors page
    ---------------------------------------------------------------------------

    -- Spell icon pool for cast bar previews, cycled in order
    local castIconPool = { 136197, 236802, 135808, 136116, 135735, 136048, 135812, 136075 }
    local castIconIdx = 0
    local function NextCastIcon()
        castIconIdx = castIconIdx + 1
        if castIconIdx > #castIconPool then castIconIdx = 1 end
        return castIconPool[castIconIdx]
    end

    -- Cast fill values: each at least 5% apart, range 40 90%
    local castFillUsed = {}
    local function NextCastFill()
        for _ = 1, 50 do
            local v = 0.40 + math.random() * 0.20
            local ok = true
            for _, prev in ipairs(castFillUsed) do
                if math.abs(v - prev) < 0.05 then ok = false; break end
            end
            if ok then
                castFillUsed[#castFillUsed + 1] = v
                return v
            end
        end
        -- fallback if somehow can't find a valid value
        local v = 0.40 + math.random() * 0.20
        castFillUsed[#castFillUsed + 1] = v
        return v
    end

    -- Shared preview bar list and lazy builder (used by both Display and Colors pages)
    local _colorPagePreviews = {}

    LazyColorPreviewBar = function(parentRow, colorType, colorKey, anchorFrame)
        local real = nil
        local proxy = {}
        local _disabled = false
        local _colorOverrideFn = nil
        local function EnsureBuilt()
            if real then return real end
            real = MakeColorPreviewBar(parentRow, colorType, colorKey, anchorFrame)
            if _disabled and real._health then real._health:SetAlpha(0.3) end
            return real
        end
        proxy.UpdateColor = function()
            local r = EnsureBuilt()
            if r and r.UpdateColor then
                if _colorOverrideFn then
                    local cr, cg, cb = _colorOverrideFn()
                    if cr and r._health then
                        r._health:SetStatusBarColor(cr, cg, cb, 1)
                        return
                    end
                end
                r.UpdateColor()
            end
        end
        proxy.UpdateOverlay = function()
            local r = EnsureBuilt()
            if r and r.UpdateOverlay then r.UpdateOverlay() end
        end
        proxy.RefreshBorderStyle = function()
            if real and real.RefreshBorderStyle then real.RefreshBorderStyle() end
        end
        proxy.RefreshBorderColor = function()
            if real and real.RefreshBorderColor then real.RefreshBorderColor() end
        end
        proxy.Randomize = function()
            if real and real.Randomize then real.Randomize() end
        end
        proxy.RefreshHealthText = function()
            if real and real.RefreshHealthText then real.RefreshHealthText() end
        end
        proxy.SetDisabled = function(off)
            _disabled = off
            if real and real._health then
                real._health:SetAlpha(off and 0.3 or 1)
            end
        end
        proxy.SetColorOverride = function(fn)
            _colorOverrideFn = fn
        end
        parentRow:HookScript("OnShow", function()
            if not real then
                EnsureBuilt()
                _G._EUI_ColorPreviews[#_G._EUI_ColorPreviews + 1] = real
            end
            if real and real._health then
                real._health:SetAlpha(_disabled and 0.3 or 1)
            end
        end)
        if parentRow:IsVisible() then
            EnsureBuilt()
        end
        _colorPagePreviews[#_colorPagePreviews + 1] = proxy
        return proxy
    end

    ---------------------------------------------------------------------------
    --  Register the module
    ---------------------------------------------------------------------------
    -- Rebuild preview when spec changes (class resource pips may appear/disappear)
    local npOptSpecFrame = CreateFrame("Frame")
    npOptSpecFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    npOptSpecFrame:SetScript("OnEvent", function(_, _, unit)
        if unit ~= "player" then return end
        -- Only invalidate + rebuild when the panel is open; invalidating while closed destroys all cached pages, causing a blank panel on next open.
        if EllesmereUI._mainFrame and EllesmereUI._mainFrame:IsShown() then
            EllesmereUI:InvalidatePageCache()
            C_Timer.After(0.2, function()
                EllesmereUI:RefreshPage(true)
            end)
        end
    end)

    EllesmereUI:RegisterModule("EllesmereUINameplates", {
        title       = "Nameplates",
        description = "Custom nameplate design and behavior.",
        pages       = { PAGE_DISPLAY, PAGE_COLORS, PAGE_GENERAL },
        buildPage   = function(pageName, parent, yOffset)
            if pageName == PAGE_GENERAL then
                return BuildGeneralPage(pageName, parent, yOffset)
            elseif pageName == PAGE_DISPLAY then
                return BuildDisplayPage(pageName, parent, yOffset)
            elseif pageName == PAGE_COLORS then
                return BuildColorsPage(pageName, parent, yOffset)
            end
        end,
        getHeaderBuilder = function(pageName)
            if pageName == PAGE_DISPLAY then
                return _displayHeaderBuilder
            end
            return nil  -- General and Colors have no content header
        end,
        onPageCacheRestore = function(pageName)
            if pageName == PAGE_DISPLAY then
                -- Re-evaluate Set as Default button visibility (cache restore blanket-shows all children, which can ghost the button).
                local pState = EllesmereUI._presetState and EllesmereUI._presetState[""]
                if pState and pState.UpdateDefaultBtnState then pState.UpdateDefaultBtnState() end
                -- Randomize preview values when switching TO this tab
                RandomizePreviewValues()
                -- Refresh the preview after cache restore
                if optState.activePreview and optState.activePreview.Update then optState.activePreview:Update() end
                -- Refresh hint visibility only; never recreate here.
                local dismissed = IsPreviewHintDismissed()
                if optState._previewHintFS then
                    if dismissed then
                        optState._previewHintFS:Hide()
                    else
                        optState._previewHintFS:SetAlpha(0.45)
                        optState._previewHintFS:Show()
                    end
                end
                -- Set correct header height based on current hint state
                if _headerBaseH > 0 then
                    EllesmereUI:SetContentHeaderHeightSilent(_headerBaseH + (dismissed and 0 or 29))
                end
            elseif pageName == PAGE_COLORS then
                -- Refresh all color preview bars (colors from DB)
                if optState._colorPreviewRefreshAll then optState._colorPreviewRefreshAll() end
            end
        end,
        onReset     = function()
            -- Invalidate page cache so pages are rebuilt with fresh defaults
            EllesmereUI:InvalidatePageCache()
            -- Preserve user-saved presets (display + color), Custom presets, AND spec assignments across reset
            local old = DB()
            if old then
                local pD = old._presets
                local oD = old._presetOrder
                local pC = old._color_presets
                local oC = old._color_presetOrder
                local cD = old._customPreset
                local cC = old._color_customPreset
                local sA = old._specAssignments
                local sCA = old._color_specAssignments
                local sDP = old._specDefaultPreset
                for k in pairs(old) do old[k] = nil end
                if pD and next(pD) then old._presets = pD; old._presetOrder = oD end
                if pC and next(pC) then old._color_presets = pC; old._color_presetOrder = oC end
                if cD then old._customPreset = cD end
                if cC then old._color_customPreset = cC end
                if sA and next(sA) then old._specAssignments = sA end
                if sCA and next(sCA) then old._color_specAssignments = sCA end
                if sDP then old._specDefaultPreset = sDP end
                -- Explicitly activate EllesmereUI for both preset systems
                old._activePreset = "ellesmereui"
                old._color_activePreset = "ellesmereui"
            end
        end,
    })

    ---------------------------------------------------------------------------
    --  Slash command  /enp  opens EllesmereUI to the Nameplates module
    ---------------------------------------------------------------------------
    SLASH_ELLESMERENAMEPLATES1 = "/enp"
    SlashCmdList.ELLESMERENAMEPLATES = function(msg)
        if InCombatLockdown and InCombatLockdown() then
            print("Cannot open options in combat")
            return
        end

        if msg == "reset" then
            local _db = DB()
            if _db then
                local pD = _db._presets
                local oD = _db._presetOrder
                local pC = _db._color_presets
                local oC = _db._color_presetOrder
                local cD = _db._customPreset
                local cC = _db._color_customPreset
                local sA = _db._specAssignments
                local sCA = _db._color_specAssignments
                local sDP = _db._specDefaultPreset
                for k in pairs(_db) do _db[k] = nil end
                if pD and next(pD) then _db._presets = pD; _db._presetOrder = oD end
                if pC and next(pC) then _db._color_presets = pC; _db._color_presetOrder = oC end
                if cD then _db._customPreset = cD end
                if cC then _db._color_customPreset = cC end
                if sA and next(sA) then _db._specAssignments = sA end
                if sCA and next(sCA) then _db._color_specAssignments = sCA end
                if sDP then _db._specDefaultPreset = sDP end
                _db._activePreset = "ellesmereui"
                _db._color_activePreset = "ellesmereui"
            end
            EllesmereUI.RequestReload()
            return
        end

        EllesmereUI:ShowModule("EllesmereUINameplates")
    end
end)
-- LoadOnDemand: this addon loads after PLAYER_LOGIN, so the event above will never fire; run the init now.
if IsLoggedIn() then initFrame:GetScript("OnEvent")(initFrame) end
