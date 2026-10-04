if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
local GetSpecialization = (C_SpecializationInfo and C_SpecializationInfo.GetSpecialization) or GetSpecialization
local addonName, ns = ...
if not (EllesmereUI and EllesmereUI._ModuleNS and EllesmereUI.NewCombatQueue) then EUI_CLIENT_BLOCKED = true; return end -- stale-parent guard: a partially updated install (old parent, new child) goes dormant via the line-1 failsafe instead of erroring
EllesmereUI._ModuleNS[addonName] = ns  -- LOD options files read this module ns via the registry

local math_floor, math_ceil, math_max, math_min, math_abs =
    math.floor, math.ceil, math.max, math.min, math.abs
local string_format = string.format
local issecretvalue = issecretvalue
-- WoW Forever: no number under 10,000 abbreviates (EllesmereUI_NumberFormat.lua).
-- Also on ns for the options preview, whose builder is near its upvalue cap.
local AbbreviateNumbers = (EllesmereUI.IS_FOREVER and EllesmereUI.ForeverAbbreviateNumbers) or AbbreviateNumbers
ns.AbbreviateNumbers = AbbreviateNumbers

local PP = EllesmereUI.PP

-- "Run once after combat" for the combat-gated deferrals of this addon (all files).
-- The frame is created in the main chunk, so drained work bills UnitFrames. Keys are
-- per purpose; PlayerAuraBars prefixes its own with "PAB:".
ns.CombatQueue = EllesmereUI.NewCombatQueue(CreateFrame("Frame"))

-- Taint-safe DisableBlizzard override. Stock lib reparents inline via a SetParent
-- hooksecurefunc; Edit Mode's layout pass calls SetParent on managed containers
-- (BossTargetFrameContainer->UIParent) every enter/exit, so that inline reparent runs
-- in Blizzard's secure execution and taints secret-value reads (CompactUnitFrame
-- compares, encounter warnings, SecureUtil arithmetic), poisoning party frames for the
-- session. Fix: defer reparent to a timer and postpone while Edit Mode is open (SetParent
-- runs synchronous layout handlers in the caller's context). Unlisted units use stock.
do
    local hiddenParent = CreateFrame("Frame", nil, UIParent)
    hiddenParent:Hide()
    local pendingParent, looseFrames, hookedFrames = {}, {}, {}
    local bossHandled = false

    -- Combat fallback: protected frames can't reparent in lockdown; park here, sweep at regen (mirrors stock lib).
    local SweepLooseFrames
    SweepLooseFrames = function()
        if InCombatLockdown() then
            ns.CombatQueue.Defer("HiddenParentSweep", SweepLooseFrames)
            return
        end
        for f in pairs(looseFrames) do f:SetParent(hiddenParent) end
        wipe(looseFrames)
    end

    local function ApplyHiddenParent(frame)
        pendingParent[frame] = nil
        if frame:GetParent() == hiddenParent then return end
        if EditModeManagerFrame and EditModeManagerFrame:IsShown() then
            pendingParent[frame] = true
            C_Timer.After(0.25, function() ApplyHiddenParent(frame) end)
        elseif InCombatLockdown() and frame:IsProtected() then
            looseFrames[frame] = true
            ns.CombatQueue.Defer("HiddenParentSweep", SweepLooseFrames)
        else
            frame:SetParent(hiddenParent)
        end
    end

    local function Unreg(child)
        if child then child:UnregisterAllEvents() end
    end

    local function HandleFrame(frame, doNotReparent)
        if type(frame) == "string" then frame = _G[frame] end
        if not frame then return end
        frame:UnregisterAllEvents()
        frame:Hide()
        if not doNotReparent then
            frame:SetParent(hiddenParent)
            if not hookedFrames[frame] then
                hookedFrames[frame] = true
                hooksecurefunc(frame, "SetParent", function(self, parent)
                    if parent ~= hiddenParent and not pendingParent[self] then
                        pendingParent[self] = true
                        C_Timer.After(0, function() ApplyHiddenParent(self) end)
                    end
                end)
            end
        end
        Unreg(frame.healthBar or frame.healthbar or frame.HealthBar
            or (frame.HealthBarsContainer and frame.HealthBarsContainer.healthBar))
        Unreg(frame.manabar or frame.ManaBar)
        Unreg(frame.castBar or frame.spellbar or frame.CastingBarFrame)
        Unreg(frame.powerBarAlt or frame.PowerBarAlt)
        Unreg(frame.BuffFrame or frame.AurasFrame)
        Unreg(frame.petFrame or frame.PetFrame)
        Unreg(frame.totFrame)
        Unreg(frame.CcRemoverFrame)
        Unreg(frame.DebuffFrame)
    end

    -- Standalone Midnight player alt-power bars live under PlayerFrameAlternatePowerBarArea
    -- (a PlayerFrame child), so reparenting PlayerFrame makes them descendants of an
    -- insecure frame. 12.1 build 68824 made aura access a hard-error API (RequiresUnitAuraAccess): these bars
    -- self-register power/spec/PEW events (independent of PlayerFrame's now-dead ones) and
    -- drive AttachBarToUnitUI -> PlayerFrame_OnAlternatePowerBarEnabled -> PlayerFrame_ToPlayerArt
    -- -> BuffFrame:Update() -> GetAuraSlots, throwing "Auras cannot be accessed when secret
    -- while tainted". Fix: unregister events only (taint-clean, combat-legal) -- do NOT
    -- reparent (Edit-Mode-managed; risks the same taint the timers avoid). Globals may be
    -- absent on some clients; Unreg nil-guards each.
    local ALT_POWER_BARS = {
        "AlternatePowerBar", "MonkStaggerBar",
        "EvokerEbonMightBar", "DemonHunterSoulFragmentsBar",
    }
    local function DisableAltPowerBars()
        for i = 1, #ALT_POWER_BARS do
            Unreg(_G[ALT_POWER_BARS[i]])
        end
    end

    -- One Blizzard frame on its own, the same treatment (Forever's classic
    -- ComboFrame, see InitializeFrames).
    ns.UF_HideBlizzardFrame = HandleFrame

    function ns.UF_HideBlizzard(unit)
        if not unit then return end
        if unit == "player" then
            HandleFrame(PlayerFrame)
            DisableAltPowerBars()
        elseif unit == "pet" then
            HandleFrame(PetFrame)
        elseif unit == "target" then
            HandleFrame(TargetFrame)
        elseif unit == "focus" then
            HandleFrame(FocusFrame)
        elseif unit:match("boss%d?$") then
            if not bossHandled then
                bossHandled = true
                -- Container is reparented (Edit Mode can revive it); individual boss frames are
                -- container-managed and must NOT be reparented or layout code breaks their sizes.
                HandleFrame(BossTargetFrameContainer)
                for i = 1, (_G.MAX_BOSS_FRAMES or 5) do
                    HandleFrame("Boss" .. i .. "TargetFrame", true)
                end
            end
        end
        -- Unmapped units (tot/fot ride their parents' children) are no-ops.
    end
end

-- Per-addon border texture defaults (size key = borderSize 0-4)
EllesmereUI.RegisterBorderDefaults("unitframes", EllesmereUI.BORDER_DEFAULTS_FRAMES)


-- Portrait UNIT_MODEL_CHANGED on eventless frames (TargetTarget) triggers UnitIsUnit,
-- which returns secret booleans in protected instances; we unregister that event after
-- oUF sets up eventless frames instead of patching the global. See PostCreateTargetTarget.

-- External lookup for portrait side per frame (writing custom props onto oUF frames would taint their secure execution chain).
EllesmereUI._ufPortraitSide = EllesmereUI._ufPortraitSide or setmetatable({}, { __mode = "k" })

local db
local defaults = {
    profile = {
        playerAuraBars = {
            -- Stock styles (Global Settings > Style): the stock aura borders
            -- on every bar. Reload-gated; read once per session (ns.PAB_Style).
            useBlizzardStyle = false,
            useClassicStyle = false,
            iconSize = 32,
            showText = true,
            durationPosition = "CENTER",
            durationTextSize = 11,
            durationOffsetX = 0,
            durationOffsetY = 0,
            stackPosition = "BOTTOMRIGHT",
            stackTextSize = 11,
            stackOffsetX = 0,
            stackOffsetY = 0,
            buffIconZoom = 0.055,
            debuffIconZoom = 0.055,
            buffBorderSize = 1,
            debuffBorderSize = 1,
            buffBorderR = 0, buffBorderG = 0, buffBorderB = 0, buffBorderA = 1,
            debuffBorderR = 0, debuffBorderG = 0, debuffBorderB = 0, debuffBorderA = 1,
            dispelColorMagic = { r = 0.349, g = 0.475, b = 1.0 },
            dispelColorCurse = { r = 0.636, g = 0.0, b = 0.64 },
            dispelColorDisease = { r = 0.671, g = 0.384, b = 0.098 },
            dispelColorPoison = { r = 0.0, g = 0.706, b = 0.286 },
            dispelColorBleed = { r = 0.75, g = 0.15, b = 0.15 },
            paddingBuffs = 5,
            paddingDebuffs = 5,
            iconsPerRowBuffs = 11,
            iconsPerRowDebuffs = 8,
            maxRowsBuffs = 3,
            maxRowsDebuffs = 2,
            maxBuffs = 32,
            maxDebuffs = 16,
        },
        -- No playerAuras/externalDefensives defaults: those keys are one-time migration
        -- SOURCES read from a saved profile (EllesmereUIUnitFrames_PlayerAuraBars.lua
        -- MigratePlayerAuraStyle/MigrateExternalDefensives), independent of this table --
        -- a new profile has nothing to migrate and starts at PAB's fallbacks.
        castbarOpacity = 1.0,
        castbarColor = { r = 0.114, g = 0.655, b = 0.514 },
        portraitMode = "2d",
        portraitStyle = "attached",
        healthBarTexture = "none",
        -- Cast bars follow the health bar texture ("inherit") unless this
        -- names one of their own ("blizzard" = the vanilla cast fill).
        castBarTexture = "inherit",
        darkTheme = false,
        -- One decimal on abbreviated values (240.5k) and percents (77.3%); global, read by text tags via _G flags.
        showDecimalOnText = false,
        -- With decimals on, boss frames use two (240.55k / 77.30%); inline cog on "Show Decimal on Health Text".
        showDecimalBoss2 = true,
        -- With decimals on, "Only Show for % Health" keeps the decimal on PERCENT (77.3%) but leaves VALUES whole (240k); same inline cog.
        showDecimalPercentOnly = false,
        -- With decimals on, "Hide Trailing Zeros" drops a zero decimal from the PERCENT (100.0% -> 100%, 99.5% unchanged); same inline cog.
        showDecimalTrimZeros = false,
        -- Player Threat (Non-Tank): additive "Shadow" border on the PLAYER frame while
        -- pulling/holding aggro, instanced content only; global, default off (zero cost
        -- until enabled). Colors mirror the nameplate non-tank threat defaults (has/near aggro).
        playerThreatBorderEnabled  = false,
        playerThreatHasAggroColor  = { r = 1.00, g = 0.50, b = 0.00 },
        playerThreatNearAggroColor = { r = 0.81, g = 0.72, b = 0.19 },
        -- Threat % text on the target and focus frames (WoW Forever only).
        threatPctEnabled  = false,
        threatPctFocus    = false,
        threatPctPosition = "CENTER",
        threatPctColorByThreat = true,
        threatPctSize     = 12,
        threatPctXOffset  = 0,
        threatPctYOffset  = 0,
        -- Custom enemy reaction colors (empty = use Blizzard FACTION_BAR_COLORS).
        -- Keys: hostile (reactions 1-3), neutral (4), friendly (5-8), tapped.
        enemyColors = {},
        player = {
            frameWidth = 181,
            healthHeight = 46,
            powerHeight = 6,
            powerPosition = "below",
            powerWidth = 0,
            powerX = 0,
            powerY = -4,
            powerPercentText = "none",
            powerTextFormat = "perpp",
            powerShowPercent = true,
            powerPercentSize = 9,
            powerPercentX = 0,
            powerPercentY = 0,
            powerPercentPowerColor = true,
            powerBgPowerColored = false,
            powerPercentTextPowerColor = false,
            manaRegenSpark = false,  -- WoW Forever: mana regen spark while the bar shows mana; manaRegenSparkMode "ticks" = Regen Ticks, nil = 5-Second Rule
            healthClassColored = true,
            customBgColor = { r = 0.067, g = 0.067, b = 0.067 },
            bgClassColored = false,
            healthDisplay = "both",
            showBuffs = false,
            maxBuffs = 4,
            buffAnchor = "topleft",
            buffGrowth = "auto",
            buffSize = 22,
            buffOffsetX = 0,
            buffOffsetY = 0,
            auraBorderTexture = "solid",
            auraBorderSize = 1,
            auraBorderR = 0, auraBorderG = 0, auraBorderB = 0, auraBorderA = 1,
            auraBorderBehind = false,
            auraBorderBehindUnitFrame = false,
            -- Textured Dispel Ring: the dispel ring drawn in the aura border's art.
            auraBorderDispelTextured = false,
            buffShowCooldownText = false,
            buffCooldownTextSize = 10,
            debuffAnchor = "none",
            debuffGrowth = "auto",
            maxDebuffs = 10,
            debuffSize = 22,
            debuffOffsetX = 0,
            debuffOffsetY = 0,
            -- Use Dispel Colors: Dispel Type Borders tinted from the Dispel Colors palette.
            debuffDispelUsePalette = false,
            debuffShowCooldownText = false,
            debuffCooldownTextSize = 10,
            namePosition = "left",
            healthTextPosition = "right",
            leftTextContent = "name",
            rightTextContent = (EllesmereUI.IS_FOREVER == true) and "perhp" or "both",  -- WoW Forever: Health % (retail: Health # | %)
            leftTextSize = 12,
            leftTextX = 0,
            leftTextY = 0,
            rightTextSize = 12,
            rightTextX = 0,
            rightTextY = 0,
            leftTextClassColor = false,
            rightTextClassColor = false,
            centerTextContent = "none",
            centerTextSize = 12,
            centerTextX = 0,
            centerTextY = 0,
            centerTextClassColor = false,
            extraTextContent = "none",
            extraTextSize = 12,
            extraTextX = 0,
            extraTextY = 0,
            extraTextClassColor = false,
            extraTextAlign = "left",
            bottomTextBar = false,
            bottomTextBarHeight = 16,
            btbPosition = "bottom",
            btbWidth = 0,
            btbX = 0,
            btbY = 0,
            btbBgColor = { r = 0.2, g = 0.2, b = 0.2 },
            btbBgOpacity = 1.0,
            btbLeftContent = "none",
            btbLeftSize = 11,
            btbLeftX = 0,
            btbLeftY = 0,
            btbLeftClassColor = false,
            btbLeftPowerColor = false,
            btbRightContent = "none",
            btbRightSize = 11,
            btbRightX = 0,
            btbRightY = 0,
            btbRightClassColor = false,
            btbRightPowerColor = false,
            btbCenterContent = "none",
            btbCenterSize = 11,
            btbCenterX = 0,
            btbCenterY = 0,
            btbCenterClassColor = false,
            btbCenterPowerColor = false,
            btbClassIcon = "none",
            btbClassIconSize = 14,
            btbClassIconLocation = "left",
            btbClassIconX = 0,
            btbClassIconY = 0,
            showPortrait = true,
            portraitStyle = "attached",
            portraitMode = "2d",
            portraitNonPlayer = "2d",
            classThemeStyle = "modern",
            portraitSide = "left",
            portraitSize = 0,
            portraitX = 0,
            portraitY = 0,
            portraitMirror = false,
            detachedPortraitShape = "portrait",
            detachedPortraitBorderColor = { r = 0, g = 0, b = 0 },
            detachedPortraitClassColor = true,
            detachedPortraitBorder = true,
            detachedPortraitBorderOpacity = 100,
            detachedPortraitBorderSize = 7,
            detachedPortraitUnitColorDark = false,
            detachedPortraitOuterRing = "none",
            detachedPortraitInnerShadow = false,
            -- Portrait Dragon (Player Frame Dragon): read through ns.UF_DragonSettings.
            detachedPortraitWinglessDragon = false,
            detachedPortraitWinglessDragonClassColor = false,
            detachedPortraitWinglessDragonScale = 100,
            detachedPortraitWinglessDragonX = 0,
            detachedPortraitWinglessDragonY = 0,
            detachedPortraitWinglessDragonFlip = false,
            detachedPortraitWinglessDragonStrata = "inherit",
            detachedPortraitWinglessDragonLevel = 2,
            healthBarOpacity = 90,
            powerBarOpacity = 100,
            showPlayerAbsorb = "none",
            absorbCleanAlpha = 30,
            -- Absorb Bar / Heal Absorb Bar: separate strips (see Raid Frames)
            absorbBarPosition     = "none",
            absorbBarHeight       = 4,
            absorbBarColor        = { r = 1, g = 1, b = 1 },
            healAbsorbBarPosition = "none",
            healAbsorbBarHeight   = 4,
            healAbsorbBarColor    = { r = 200/255, g = 29/255, b = 29/255 },
            -- Blizzard Glow Line (opt-in) and its art: "blizzard" | "pixelsGlow" | "pixelsOvershield".
            absorbGlowLine = false,
            absorbGlowLineTexture = "blizzard",
            showPlayerCastbar = false,
            -- Global Settings > Gamepad: stand this cast bar down while a
            -- controller is connected (ns.UF_ApplyGamepadCastbar).
            castbarGamepadHide = false,
            showPlayerCastIcon = true,
            playerCastbarIconInWidth = true,
            castReverseFill = false,
            castFillOpacity = 100,  -- 0-100; below 100 the world shows through the fill
            castbarHideWhenInactive = true,
            lockCastbarToFrame = true,
            playerCastbarX = 0,
            playerCastbarY = 0,
            playerCastbarWidth = 181,
            playerCastbarHeight = 14,
            castSpellNameSize = 11,
            castSpellNameColor = { r = 1, g = 1, b = 1 },
            castDurationSize = 10,
            castDurationColor = { r = 1, g = 1, b = 1 },
            castSpellNameX = 0,
            castSpellNameY = 0,
            castSpellTargetSize = 11,
            castSpellTargetColor = { r = 1, g = 1, b = 1 },
            castSpellTargetX = 0,
            castSpellTargetY = 0,
            castDurationX = 0,
            castDurationY = 0,
            showCastDuration = true,
            -- Player-only: the spell target never rendered here before the
            -- display fix, so it defaults OFF to keep the frame unchanged;
            -- users opt in via the Spell Target side dropdown. Existing
            -- profiles are pinned to None by uf_player_cast_target_none_v1.
            showCastTarget = false,
            castbarFillColor = { r = 0.863, g = 0.820, b = 0.639 },
            castbarClassColored = false,
            -- Cast Icon cog "Show Icon on Portrait" (opt-in).
            playerCastbarIconOnPortrait = false,
            -- Cast Bar cog "Custom Border Style" (opt-in). The border keys are
            -- read only while it is on; castBorderOffsetX/Y and
            -- castBorderShiftX/Y (nil = the style's default) and the exact
            -- size castBorderSizePx are never seeded.
            castBorderCustom = false,
            castBorderStyle = "solid",
            castBorderSize = 1,
            castBorderColor = { r = 0, g = 0, b = 0 },
            castBorderAlpha = 1,
            castBorderBehind = false,
            -- WoW Forever: the class resource is ON (modern pips above the health
            -- bar, 16) because the client's own combo point art is stood down
            -- there (Forever combo points belong to the target and Blizzard's
            -- classic ComboFrame cannot follow our target frame); the 8 default
            -- lands at a 3px sliver. Per-client defaults, never seeded.
            showClassPowerBar = (EllesmereUI.IS_FOREVER == true) and true or false,
            lockClassPowerToFrame = true,
            classPowerStyle = (EllesmereUI.IS_FOREVER == true) and "modern" or "none",
            classPowerPosition = (EllesmereUI.IS_FOREVER == true) and "above" or "top",
            classPowerBarX = 0,
            classPowerBarY = 0,
            classPowerSize = (EllesmereUI.IS_FOREVER == true) and 16 or 8,
            classPowerSpacing = 2,
            classPowerClassColor = true,
            classPowerCustomColor = { r = 1, g = 0.82, b = 0 },
            classPowerBgColor = { r = 0.082, g = 0.082, b = 0.082, a = 1.0 },
            classPowerEmptyColor = { r = 0.2, g = 0.2, b = 0.2, a = 1.0 },
            borderSize = 1,
            borderColor = { r = 0, g = 0, b = 0 },
            borderTexture = "solid",
            borderPowerSeam = false,  -- Border Options cog "Power Bar Seam" (opt-in)
            highlightColor = { r = 1, g = 1, b = 1 },
            textSize = 12,
            combatIndicatorStyle = "class",
            combatIndicatorColor = "custom",
            combatIndicatorCustomColor = { r = 1, g = 1, b = 1 },
            combatIndicatorPosition = "healthbar",
            combatIndicatorSize = 22,
            combatIndicatorX = 0,
            combatIndicatorY = 0,
            showInRaid = true,
            showInParty = true,
            showSolo = true,
            barVisibility = "always",
            showWhenHealthMissing = false,
            oocFadeEnabled = false,  -- "Fade Out of Combat" toggle (off by default)
            oocAlpha       = 0.5,    -- whole-frame alpha while out of combat
            visHideHousing = false,
            visOnlyInstances = false,
            visHideMounted = false,
            visHideNoTarget = false,
            visHideNoEnemy = false,
            raidMarkerEnabled = false,
            raidMarkerSize = 28,
            raidMarkerAlign = "right",
            raidMarkerX = 0,
            raidMarkerY = 0,
            leaderIndicatorEnabled = true,
            leaderIndicatorSize = 16,
            leaderIndicatorPosition = "topleft",
            leaderIndicatorX = 0,
            leaderIndicatorY = 0,
            leaderIndicatorStyle = "blizzard",  -- "blizzard" | "pixels"
            factionIndicatorMode = "off",
            factionIndicatorStyle = "pvp",
            factionIndicatorPvP = "only",
            factionIndicatorSize = 18,
            factionIndicatorPosition = "topright",
            factionIndicatorX = 0,
            factionIndicatorY = 0,
            healthReverseFill = false,
            healthVerticalFill = false,
            smoothBars = false,
            powerReverseFill = false,
        },
        target = {
            frameWidth = 181,
            -- Combat indicator: same option set as the player frame but opt-in
            -- ("none" until the user picks a style).
            combatIndicatorStyle = "none",
            combatIndicatorColor = "custom",
            combatIndicatorCustomColor = { r = 1, g = 1, b = 1 },
            combatIndicatorPosition = "healthbar",
            combatIndicatorSize = 22,
            combatIndicatorX = 0,
            combatIndicatorY = 0,
            healthHeight = 46,
            powerHeight = 6,
            powerPosition = "below",
            powerWidth = 0,
            powerX = 0,
            powerY = -4,
            powerPercentText = "none",
            powerTextFormat = "perpp",
            powerShowPercent = true,
            powerPercentSize = 9,
            powerPercentX = 0,
            powerPercentY = 0,
            powerPercentPowerColor = true,
            powerBgPowerColored = false,
            powerPercentTextPowerColor = false,
            healthClassColored = true,
            customBgColor = { r = 0.067, g = 0.067, b = 0.067 },
            bgClassColored = false,
            castbarHeight = 14,
            castbarWidth = 181,
            showCastbar = true,
            showCastIcon = true,
            castbarIconInWidth = true,
            castCombineNameTarget = false,  -- render "Spell Name - Target" as one string in the target slot
            castReverseFill = false,
            castFillOpacity = 100,  -- 0-100; below 100 the world shows through the fill
            castbarHideWhenInactive = true,
            castSpellNameSize = 11,
            castSpellNameColor = { r = 1, g = 1, b = 1 },
            castDurationSize = 10,
            castDurationColor = { r = 1, g = 1, b = 1 },
            castSpellNameX = 0,
            castSpellNameY = 0,
            castSpellTargetSize = 11,
            castSpellTargetColor = { r = 1, g = 1, b = 1 },
            castSpellTargetX = 0,
            castSpellTargetY = 0,
            castDurationX = 0,
            castDurationY = 0,
            showCastDuration = true,
            showCastTarget = true,
            castbarFillColor = { r = 0.863, g = 0.820, b = 0.639 },
            castbarInterruptReadyColor = { r = 0.92, g = 0.35, b = 0.20 },
            castbarKickTickEnabled = true,
            castbarInterruptMidCastEnabled = false,
            castbarInterruptMidCastColor = { r = 0.318, g = 0.820, b = 0.357 },
            castbarUninterruptibleColor = { r = 0.5, g = 0.5, b = 0.5 },
            castbarImportantGlow = false,
            castbarImportantGlowStyle = 1,
            castbarImportantGlowColor = { r = 1, g = 0.2, b = 0.2 },
            castbarImportantGlowLines = 8,
            castbarImportantGlowThickness = 2,
            castbarImportantGlowSpeed = 4,
            castbarClassColored = false,
            -- Cast Icon cog "Show Icon on Portrait" (opt-in).
            castbarIconOnPortrait = false,
            -- Cast Bar cog "Custom Border Style" (opt-in); see the player block.
            castBorderCustom = false,
            castBorderStyle = "solid",
            castBorderSize = 1,
            castBorderColor = { r = 0, g = 0, b = 0 },
            castBorderAlpha = 1,
            castBorderBehind = false,
            healthDisplay = "both",
            showBuffs = true,
            onlyPlayerDebuffs = false,
            buffAnchor = "topleft",
            buffGrowth = "auto",
            debuffAnchor = "bottomleft",
            debuffGrowth = "auto",
            maxBuffs = 4,
            maxDebuffs = 20,
            buffSize = 22,
            buffOffsetX = 0,
            buffOffsetY = 0,
            auraBorderTexture = "solid",
            auraBorderSize = 1,
            auraBorderR = 0, auraBorderG = 0, auraBorderB = 0, auraBorderA = 1,
            auraBorderBehind = false,
            auraBorderBehindUnitFrame = false,
            -- Textured Dispel Ring: the dispel ring drawn in the aura border's art.
            auraBorderDispelTextured = false,
            buffShowCooldownText = false,
            buffCooldownTextSize = 10,
            debuffSize = 22,
            debuffOffsetX = 0,
            debuffOffsetY = 0,
            debuffShowCooldownText = false,
            debuffCooldownTextSize = 10,
            namePosition = "left",
            healthTextPosition = "right",
            -- WoW Forever shows level and name on the left (retail: name only).
            leftTextContent = (EllesmereUI.IS_FOREVER == true) and "levelname" or "name",
            rightTextContent = (EllesmereUI.IS_FOREVER == true) and "perhp" or "both",  -- WoW Forever: Health % (retail: Health # | %)
            leftTextSize = 12,
            leftTextX = 0,
            leftTextY = 0,
            rightTextSize = 12,
            rightTextX = 0,
            rightTextY = 0,
            leftTextClassColor = false,
            rightTextClassColor = false,
            centerTextContent = "none",
            centerTextSize = 12,
            centerTextX = 0,
            centerTextY = 0,
            centerTextClassColor = false,
            extraTextContent = "none",
            extraTextSize = 12,
            extraTextX = 0,
            extraTextY = 0,
            extraTextClassColor = false,
            extraTextAlign = "left",
            bottomTextBar = false,
            bottomTextBarHeight = 16,
            btbPosition = "bottom",
            btbWidth = 0,
            btbX = 0,
            btbY = 0,
            btbBgColor = { r = 0.2, g = 0.2, b = 0.2 },
            btbBgOpacity = 1.0,
            btbLeftContent = "none",
            btbLeftSize = 11,
            btbLeftX = 0,
            btbLeftY = 0,
            btbLeftClassColor = false,
            btbLeftPowerColor = false,
            btbRightContent = "none",
            btbRightSize = 11,
            btbRightX = 0,
            btbRightY = 0,
            btbRightClassColor = false,
            btbRightPowerColor = false,
            btbCenterContent = "none",
            btbCenterSize = 11,
            btbCenterX = 0,
            btbCenterY = 0,
            btbCenterClassColor = false,
            btbCenterPowerColor = false,
            btbClassIcon = "none",
            btbClassIconSize = 14,
            btbClassIconLocation = "left",
            btbClassIconX = 0,
            btbClassIconY = 0,
            showPortrait = true,
            portraitStyle = "attached",
            portraitMode = "2d",
            portraitNonPlayer = "2d",
            classThemeStyle = "modern",
            portraitSide = "right",
            portraitSize = 0,
            portraitX = 0,
            portraitY = 0,
            portraitMirror = false,
            detachedPortraitShape = "portrait",
            detachedPortraitBorderColor = { r = 0, g = 0, b = 0 },
            detachedPortraitClassColor = true,
            detachedPortraitBorder = true,
            detachedPortraitBorderOpacity = 100,
            detachedPortraitBorderSize = 7,
            detachedPortraitUnitColorDark = false,
            detachedPortraitOuterRing = "none",
            detachedPortraitInnerShadow = false,
            -- Portrait Dragon (Elite Enemy Dragon): read through ns.UF_DragonSettings.
            detachedPortraitWinglessDragon = false,
            detachedPortraitWinglessDragonClassColor = false,
            detachedPortraitWinglessDragonScale = 100,
            detachedPortraitWinglessDragonX = 0,
            detachedPortraitWinglessDragonY = 0,
            detachedPortraitWinglessDragonFlip = false,
            detachedPortraitWinglessDragonStrata = "inherit",
            detachedPortraitWinglessDragonLevel = 2,
            detachedPortraitWinglessDragonInstances = false,
            healthBarOpacity = 90,
            powerBarOpacity = 100,
            borderSize = 1,
            borderColor = { r = 0, g = 0, b = 0 },
            borderTexture = "solid",
            borderPowerSeam = false,  -- Border Options cog "Power Bar Seam" (opt-in)
            highlightColor = { r = 1, g = 1, b = 1 },
            textSize = 12,
            showInRaid = true,
            showInParty = true,
            showSolo = true,
            barVisibility = "always",
            showWhenHealthMissing = false,
            oocFadeEnabled = false,  -- "Fade Out of Combat" toggle (off by default)
            oocAlpha       = 0.5,    -- whole-frame alpha while out of combat
            visHideHousing = false,
            visOnlyInstances = false,
            visHideMounted = false,
            visHideNoTarget = false,
            visHideNoEnemy = false,
            raidMarkerEnabled = false,
            raidMarkerSize = 28,
            raidMarkerAlign = "right",
            raidMarkerX = 0,
            raidMarkerY = 0,
            leaderIndicatorEnabled = true,
            leaderIndicatorSize = 16,
            leaderIndicatorPosition = "topleft",
            leaderIndicatorX = 0,
            leaderIndicatorY = 0,
            leaderIndicatorStyle = "blizzard",  -- "blizzard" | "pixels"
            eliteIndicatorEnabled = false,
            eliteIndicatorSize = 16,
            eliteIndicatorPosition = "topleft",
            eliteIndicatorX = 0,
            eliteIndicatorY = 0,
            eliteIndicatorShowInInstances = false,
            eliteIndicatorStyle = "badge",  -- "badge" | "pixelsDragon"
            -- A saved "wingless" style and these five keys read as the Portrait
            -- Dragon (ns.UF_DragonSettings) until a setter pins them over.
            eliteIndicatorWinglessClassColor = false,
            eliteIndicatorWinglessScale = 100,
            eliteIndicatorWinglessFlip = false,
            eliteIndicatorWinglessStrata = "inherit",
            eliteIndicatorWinglessLevel = 1,
            factionIndicatorMode = "off",
            factionIndicatorStyle = "pvp",
            factionIndicatorPlayersOnly = false,
            factionIndicatorPvP = "dim",
            factionIndicatorSize = 18,
            factionIndicatorPosition = "topright",
            factionIndicatorX = 0,
            factionIndicatorY = 0,
            healthReverseFill = false,
            healthVerticalFill = false,
            smoothBars = false,
            powerReverseFill = false,
        },
        playerTarget = {
            frameWidth = 181,
            healthHeight = 46,
            powerHeight = 6,
            powerY = -4,
            powerPercentText = "none",
            powerTextFormat = "perpp",
            powerShowPercent = true,
            powerPercentSize = 9,
            powerPercentX = 0,
            powerPercentY = 0,
            powerPercentPowerColor = true,
            powerBgPowerColored = false,
            powerPercentTextPowerColor = false,
            healthClassColored = true,
            castbarHeight = 14,
            maxBuffs = 4,
            maxDebuffs = 20,
            buffSize = 22,
            buffOffsetX = 0,
            buffOffsetY = 0,
            buffShowCooldownText = false,
            buffCooldownTextSize = 10,
            debuffSize = 22,
            debuffOffsetX = 0,
            debuffOffsetY = 0,
            debuffShowCooldownText = false,
            debuffCooldownTextSize = 10,
            healthDisplay = "both",
            showBuffs = true,
            onlyPlayerDebuffs = false,
            showPlayerAbsorb = "none",
            absorbCleanAlpha = 30,
            -- Absorb Bar / Heal Absorb Bar: separate strips (see Raid Frames)
            absorbBarPosition     = "none",
            absorbBarHeight       = 4,
            absorbBarColor        = { r = 1, g = 1, b = 1 },
            healAbsorbBarPosition = "none",
            healAbsorbBarHeight   = 4,
            healAbsorbBarColor    = { r = 200/255, g = 29/255, b = 29/255 },
            -- Blizzard Glow Line (opt-in) and its art: "blizzard" | "pixelsGlow" | "pixelsOvershield".
            absorbGlowLine = false,
            absorbGlowLineTexture = "blizzard",
            showPlayerCastbar = false,
            showClassPowerBar = false,
            classPowerBarX = 0,
            classPowerBarY = 0,
            playerCastbarX = 0,
            playerCastbarY = 0,
            playerCastbarWidth = 181,
            playerCastbarHeight = 14,
            healthReverseFill = false,
            healthVerticalFill = false,
            smoothBars = false,
            powerReverseFill = false,
        },
        targettarget = {
            frameWidth = 101,
            healthHeight = 25,
            healthClassColored = false,
            customBgColor = { r = 0.067, g = 0.067, b = 0.067 },
            bgClassColored = false,
            showPortrait = false,
            portraitSide = "left",
            portraitMode = "2d",
            portraitNonPlayer = "2d",
            healthBarOpacity = 90,
            textSize = 12,
            leftTextContent = "name",
            leftTextClassColor = false,
            leftTextColorR = 1, leftTextColorG = 1, leftTextColorB = 1,
            leftTextX = 0, leftTextY = 0,
            rightTextContent = "none",
            rightTextClassColor = false,
            rightTextColorR = 1, rightTextColorG = 1, rightTextColorB = 1,
            rightTextX = 0, rightTextY = 0,
            centerTextContent = "none",
            centerTextClassColor = false,
            centerTextColorR = 1, centerTextColorG = 1, centerTextColorB = 1,
            centerTextX = 0, centerTextY = 0,
            borderSize = 1,
            borderColor = { r = 0, g = 0, b = 0 },
            borderTexture = "solid",
            highlightColor = { r = 1, g = 1, b = 1 },
            powerPosition = "none",
            healthReverseFill = false,
            healthVerticalFill = false,
            smoothBars = false,
        },
        -- Focus Target: independent clone of Target of Target defaults. MUST stay
        -- byte-identical to the targettarget block above (old shared totPet migrates
        -- into BOTH tables); StripDefaults/DeepMergeDefaults rely on the match.
        focustarget = {
            frameWidth = 101,
            healthHeight = 25,
            healthClassColored = false,
            customBgColor = { r = 0.067, g = 0.067, b = 0.067 },
            bgClassColored = false,
            showPortrait = false,
            portraitSide = "left",
            portraitMode = "2d",
            portraitNonPlayer = "2d",
            healthBarOpacity = 90,
            textSize = 12,
            leftTextContent = "name",
            leftTextClassColor = false,
            leftTextColorR = 1, leftTextColorG = 1, leftTextColorB = 1,
            leftTextX = 0, leftTextY = 0,
            rightTextContent = "none",
            rightTextClassColor = false,
            rightTextColorR = 1, rightTextColorG = 1, rightTextColorB = 1,
            rightTextX = 0, rightTextY = 0,
            centerTextContent = "none",
            centerTextClassColor = false,
            centerTextColorR = 1, centerTextColorG = 1, centerTextColorB = 1,
            centerTextX = 0, centerTextY = 0,
            borderSize = 1,
            borderColor = { r = 0, g = 0, b = 0 },
            borderTexture = "solid",
            highlightColor = { r = 1, g = 1, b = 1 },
            powerPosition = "none",
            healthReverseFill = false,
            healthVerticalFill = false,
            smoothBars = false,
        },
        pet = {
            frameWidth = 101,
            healthHeight = 25,
            healthClassColored = false,
            customBgColor = { r = 0.067, g = 0.067, b = 0.067 },
            bgClassColored = false,
            showPortrait = false,
            portraitSide = "left",
            portraitMode = "2d",
            portraitNonPlayer = "2d",
            healthBarOpacity = 90,
            textSize = 12,
            leftTextContent = "name",
            leftTextClassColor = false,
            leftTextColorR = 1, leftTextColorG = 1, leftTextColorB = 1,
            leftTextX = 0, leftTextY = 0,
            rightTextContent = "none",
            rightTextClassColor = false,
            rightTextColorR = 1, rightTextColorG = 1, rightTextColorB = 1,
            rightTextX = 0, rightTextY = 0,
            centerTextContent = "none",
            centerTextClassColor = false,
            centerTextColorR = 1, centerTextColorG = 1, centerTextColorB = 1,
            centerTextX = 0, centerTextY = 0,
            borderSize = 1,
            borderColor = { r = 0, g = 0, b = 0 },
            borderTexture = "solid",
            highlightColor = { r = 1, g = 1, b = 1 },
            -- WoW Forever pets have power (hunter pet focus, warlock pet mana), so
            -- the pet frame carries a power bar there (retail: none).
            powerPosition = (EllesmereUI.IS_FOREVER == true) and "below" or "none",
            powerHeight = 6,
            powerWidth = 0,
            powerX = 0,
            powerY = -4,
            powerPercentText = "none",
            powerTextFormat = "perpp",
            powerShowPercent = true,
            powerPercentSize = 9,
            powerPercentX = 0,
            powerPercentY = 0,
            powerPercentPowerColor = true,
            powerBgPowerColored = false,
            powerPercentTextPowerColor = false,
            powerBarOpacity = 100,
            powerReverseFill = false,
            -- Pet happiness icon (WoW Forever hunter pets).
            happinessEnabled = true,
            happinessSize = 20,
            happinessAlign = "right",
            happinessX = 0,
            happinessY = 0,
            healthReverseFill = false,
            healthVerticalFill = false,
            smoothBars = false,
        },
        focus = {
            frameWidth = 160,
            healthHeight = 34,
            powerHeight = 6,
            powerPosition = "below",
            powerWidth = 0,
            powerX = 0,
            powerY = -4,
            powerPercentText = "none",
            powerTextFormat = "perpp",
            powerShowPercent = true,
            powerPercentSize = 9,
            powerPercentX = 0,
            powerPercentY = 0,
            powerPercentPowerColor = true,
            powerBgPowerColored = false,
            powerPercentTextPowerColor = false,
            healthClassColored = true,
            customBgColor = { r = 0.067, g = 0.067, b = 0.067 },
            bgClassColored = false,
            castbarHeight = 14,
            castbarWidth = 160,
            showCastbar = true,
            showCastIcon = true,
            castbarIconInWidth = true,
            castCombineNameTarget = false,  -- render "Spell Name - Target" as one string in the target slot
            castReverseFill = false,
            castFillOpacity = 100,  -- 0-100; below 100 the world shows through the fill
            castbarHideWhenInactive = true,
            castSpellNameSize = 11,
            castSpellNameColor = { r = 1, g = 1, b = 1 },
            castDurationSize = 10,
            castDurationColor = { r = 1, g = 1, b = 1 },
            castSpellNameX = 0,
            castSpellNameY = 0,
            castSpellTargetSize = 11,
            castSpellTargetColor = { r = 1, g = 1, b = 1 },
            castSpellTargetX = 0,
            castSpellTargetY = 0,
            castDurationX = 0,
            castDurationY = 0,
            showCastDuration = true,
            showCastTarget = true,
            castbarFillColor = { r = 0.863, g = 0.820, b = 0.639 },
            castbarInterruptReadyColor = { r = 0.92, g = 0.35, b = 0.20 },
            castbarKickTickEnabled = true,
            castbarInterruptMidCastEnabled = false,
            castbarInterruptMidCastColor = { r = 0.318, g = 0.820, b = 0.357 },
            castbarUninterruptibleColor = { r = 0.5, g = 0.5, b = 0.5 },
            castbarImportantGlow = false,
            castbarImportantGlowStyle = 1,
            castbarImportantGlowColor = { r = 1, g = 0.2, b = 0.2 },
            castbarImportantGlowLines = 8,
            castbarImportantGlowThickness = 2,
            castbarImportantGlowSpeed = 4,
            castbarClassColored = false,
            -- Cast Icon cog "Show Icon on Portrait" (opt-in).
            castbarIconOnPortrait = false,
            -- Cast Bar cog "Custom Border Style" (opt-in); see the player block.
            castBorderCustom = false,
            castBorderStyle = "solid",
            castBorderSize = 1,
            castBorderColor = { r = 0, g = 0, b = 0 },
            castBorderAlpha = 1,
            castBorderBehind = false,
            healthDisplay = "perhp",
            -- WoW Forever shows level and name on the left (retail: name only).
            leftTextContent = (EllesmereUI.IS_FOREVER == true) and "levelname" or "name",
            rightTextContent = "perhp",
            leftTextSize = 12,
            leftTextX = 0,
            leftTextY = 0,
            rightTextSize = 12,
            rightTextX = 0,
            rightTextY = 0,
            leftTextClassColor = false,
            rightTextClassColor = false,
            centerTextContent = "none",
            centerTextSize = 12,
            centerTextX = 0,
            centerTextY = 0,
            centerTextClassColor = false,
            extraTextContent = "none",
            extraTextSize = 12,
            extraTextX = 0,
            extraTextY = 0,
            extraTextClassColor = false,
            extraTextAlign = "left",
            bottomTextBar = false,
            bottomTextBarHeight = 16,
            btbPosition = "bottom",
            btbWidth = 0,
            btbX = 0,
            btbY = 0,
            btbLeftContent = "none",
            btbLeftSize = 11,
            btbLeftX = 0,
            btbLeftY = 0,
            btbLeftClassColor = false,
            btbLeftPowerColor = false,
            btbRightContent = "none",
            btbRightSize = 11,
            btbRightX = 0,
            btbRightY = 0,
            btbRightClassColor = false,
            btbRightPowerColor = false,
            btbCenterContent = "none",
            btbCenterSize = 11,
            btbCenterX = 0,
            btbCenterY = 0,
            btbCenterClassColor = false,
            btbCenterPowerColor = false,
            btbClassIcon = "none",
            btbClassIconSize = 14,
            btbClassIconLocation = "left",
            btbClassIconX = 0,
            btbClassIconY = 0,
            showPortrait = true,
            portraitStyle = "attached",
            portraitMode = "2d",
            portraitNonPlayer = "2d",
            classThemeStyle = "modern",
            portraitSide = "right",
            portraitSize = 0,
            portraitX = 0,
            portraitY = 0,
            portraitMirror = false,
            detachedPortraitShape = "portrait",
            detachedPortraitBorderColor = { r = 0, g = 0, b = 0 },
            detachedPortraitClassColor = true,
            detachedPortraitBorder = true,
            detachedPortraitBorderOpacity = 100,
            detachedPortraitBorderSize = 7,
            detachedPortraitUnitColorDark = false,
            detachedPortraitOuterRing = "none",
            detachedPortraitInnerShadow = false,
            -- Portrait Dragon (Elite Enemy Dragon): read through ns.UF_DragonSettings.
            detachedPortraitWinglessDragon = false,
            detachedPortraitWinglessDragonClassColor = false,
            detachedPortraitWinglessDragonScale = 100,
            detachedPortraitWinglessDragonX = 0,
            detachedPortraitWinglessDragonY = 0,
            detachedPortraitWinglessDragonFlip = false,
            detachedPortraitWinglessDragonStrata = "inherit",
            detachedPortraitWinglessDragonLevel = 2,
            detachedPortraitWinglessDragonInstances = false,
            btbBgColor = { r = 0.2, g = 0.2, b = 0.2 },
            btbBgOpacity = 1.0,
            healthBarOpacity = 90,
            powerBarOpacity = 100,
            showPlayerAbsorb = "none",
            absorbCleanAlpha = 30,
            -- Absorb Bar / Heal Absorb Bar: separate strips (see Raid Frames)
            absorbBarPosition     = "none",
            absorbBarHeight       = 4,
            absorbBarColor        = { r = 1, g = 1, b = 1 },
            healAbsorbBarPosition = "none",
            healAbsorbBarHeight   = 4,
            healAbsorbBarColor    = { r = 200/255, g = 29/255, b = 29/255 },
            -- Blizzard Glow Line (opt-in) and its art: "blizzard" | "pixelsGlow" | "pixelsOvershield".
            absorbGlowLine = false,
            absorbGlowLineTexture = "blizzard",
            onlyPlayerDebuffs = true,
            debuffAnchor = "bottomleft",
            debuffGrowth = "auto",
            maxDebuffs = 10,
            showBuffs = false,
            buffAnchor = "topleft",
            buffGrowth = "auto",
            maxBuffs = 4,
            buffSize = 22,
            buffOffsetX = 0,
            buffOffsetY = 0,
            auraBorderTexture = "solid",
            auraBorderSize = 1,
            auraBorderR = 0, auraBorderG = 0, auraBorderB = 0, auraBorderA = 1,
            auraBorderBehind = false,
            auraBorderBehindUnitFrame = false,
            auraBorderDispelTextured = false,
            debuffSize = 22,
            debuffOffsetX = 0,
            debuffOffsetY = 0,
            textSize = 12,
            borderSize = 1,
            borderColor = { r = 0, g = 0, b = 0 },
            borderTexture = "solid",
            borderPowerSeam = false,  -- Border Options cog "Power Bar Seam" (opt-in)
            highlightColor = { r = 1, g = 1, b = 1 },
            showInRaid = true,
            showInParty = true,
            showSolo = true,
            barVisibility = "always",
            showWhenHealthMissing = false,
            oocFadeEnabled = false,  -- "Fade Out of Combat" toggle (off by default)
            oocAlpha       = 0.5,    -- whole-frame alpha while out of combat
            visHideHousing = false,
            visOnlyInstances = false,
            visHideMounted = false,
            visHideNoTarget = false,
            visHideNoEnemy = false,
            raidMarkerEnabled = false,
            raidMarkerSize = 28,
            raidMarkerAlign = "right",
            raidMarkerX = 0,
            raidMarkerY = 0,
            healthReverseFill = false,
            healthVerticalFill = false,
            smoothBars = false,
            powerReverseFill = false,
        },
        boss = {
            frameWidth = 160,
            healthHeight = 34,
            oorAlpha = 0.4,
            powerHeight = 6,
            powerPosition = "below",
            powerWidth = 0,
            powerX = 0,
            powerY = -4,
            powerPercentText = "none",
            powerTextFormat = "perpp",
            powerShowPercent = true,
            powerPercentSize = 9,
            powerPercentX = 0,
            powerPercentY = 0,
            powerPercentPowerColor = true,
            powerBgPowerColored = false,
            powerPercentTextPowerColor = false,
            healthClassColored = true,
            customBgColor = { r = 0.067, g = 0.067, b = 0.067 },
            bgClassColored = false,
            castbarHeight = 14,
            castbarWidth = 0,
            castbarOffsetX = 0,
            castbarOffsetY = 0,
            showCastbar = true,
            showCastIcon = true,
            castbarIconInWidth = true,
            castReverseFill = false,
            castFillOpacity = 100,
            castbarHideWhenInactive = true,
            castSpellNameSize = 11,
            castSpellNameColor = { r = 1, g = 1, b = 1 },
            castDurationSize = 10,
            castDurationColor = { r = 1, g = 1, b = 1 },
            castSpellNameX = 0,
            castSpellNameY = 0,
            castSpellTargetSize = 11,
            castSpellTargetColor = { r = 1, g = 1, b = 1 },
            castSpellTargetX = 0,
            castSpellTargetY = 0,
            castDurationX = 0,
            castDurationY = 0,
            showCastDuration = true,
            showCastTarget = false,
            castbarFillColor = { r = 0.863, g = 0.820, b = 0.639 },
            castbarInterruptReadyColor = { r = 0.92, g = 0.35, b = 0.20 },
            castbarKickTickEnabled = true,
            castbarInterruptMidCastEnabled = false,
            castbarInterruptMidCastColor = { r = 0.318, g = 0.820, b = 0.357 },
            castbarUninterruptibleColor = { r = 0.5, g = 0.5, b = 0.5 },
            castbarClassColored = false,
            -- Cast Bar cog "Custom Border Style" (opt-in; boss1-5 share it);
            -- see the player block.
            castBorderCustom = false,
            castBorderStyle = "solid",
            castBorderSize = 1,
            castBorderColor = { r = 0, g = 0, b = 0 },
            castBorderAlpha = 1,
            castBorderBehind = false,
            healthDisplay = "perhp",
            showPortrait = false,
            portraitSide = "right",
            portraitMode = "2d",
            healthBarOpacity = 90,
            powerBarOpacity = 100,
            onlyPlayerDebuffs = true,
            debuffAnchor = "bottomleft",
            debuffGrowth = "auto",
            maxDebuffs = 10,
            showBuffs = false,
            buffAnchor = "topleft",
            buffGrowth = "auto",
            maxBuffs = 4,
            buffSize = 22,
            buffOffsetX = 0,
            buffOffsetY = 0,
            debuffSize = 22,
            debuffOffsetX = 0,
            debuffOffsetY = 0,
            buffShowCooldownText = false,
            buffCooldownTextSize = 10,
            buffCooldownTextColor = {r=1, g=1, b=1},
            buffStackTextColor = {r=1, g=1, b=1},
            debuffShowCooldownText = false,
            debuffCooldownTextSize = 10,
            debuffCooldownTextColor = {r=1, g=1, b=1},
            debuffStackTextColor = {r=1, g=1, b=1},
            simpleDebuffShowCooldownText = false,
            simpleDebuffCooldownTextSize = 14,
            simpleDebuffs = "left",  -- "none"/"left"/"right": simple display forces that-side anchor + frame-height-matched debuff size (legacy boolean true=left / false=none honored at read time)
            simpleBuffs = "none",  -- "none"/"left"/"right": simple BUFF display (mirrors simpleDebuffs but defaults off)
            auraBorderTexture = "solid",
            auraBorderSize = 1,
            auraBorderR = 0, auraBorderG = 0, auraBorderB = 0, auraBorderA = 1,
            auraBorderBehind = false,
            auraBorderBehindUnitFrame = false,
            simpleBuffShowCooldownText = false,
            simpleBuffCooldownTextSize = 14,
            buffSpacing = 1,
            debuffSpacing = 1,
            simpleBuffSpacing = 1,
            simpleDebuffSpacing = 1,
            textSize = 12,
            extraTextContent = "none",
            extraTextSize = 12,
            extraTextClassColor = false,
            extraTextColorR = 1, extraTextColorG = 1, extraTextColorB = 1,
            extraTextX = 0, extraTextY = 0,
            extraTextAlign = "left",
            leftTextContent = "name",
            leftTextClassColor = false,
            leftTextColorR = 1, leftTextColorG = 1, leftTextColorB = 1,
            leftTextX = 0, leftTextY = 0,
            rightTextContent = "perhp",
            rightTextClassColor = false,
            rightTextColorR = 1, rightTextColorG = 1, rightTextColorB = 1,
            rightTextX = 0, rightTextY = 0,
            centerTextContent = "none",
            centerTextClassColor = false,
            centerTextColorR = 1, centerTextColorG = 1, centerTextColorB = 1,
            centerTextX = 0, centerTextY = 0,
            -- Boss Frames DISPLAY "Border Style": "Inherit (Main Frames)" (false)
            -- wears the mini frame donor's border, as always; any other pick sets
            -- true and the border keys below paint every boss frame
            -- (ns.UF_BossBorderSettings).
            borderCustom = false,
            borderSize = 1,
            borderColor = { r = 0, g = 0, b = 0 },
            borderTexture = "solid",
            highlightColor = { r = 1, g = 1, b = 1 },
            -- Boss Hover / Target border recolor (mirrors Raid Frames "Hover
            -- Borders"): recolors the existing border; hover beats target.
            bossHoverBorderEnabled = false,
            bossHoverBorderColor = { r = 1, g = 1, b = 1 },
            bossHoverBorderAlpha = 1,
            bossTargetBorderEnabled = false,
            bossTargetBorderColor = { r = 1, g = 1, b = 1 },
            bossTargetBorderAlpha = 1,
            raidMarkerEnabled = true,
            raidMarkerSize = 28,
            raidMarkerAlign = "left",
            raidMarkerX = 0,
            raidMarkerY = 0,
            bossStackDirection = "down",
            healthReverseFill = false,
            healthVerticalFill = false,
            smoothBars = false,
        },
        enabledFrames = {
            player = true,
            target = true,
            focus = true,
            pet = true,
            targettarget = true,
            focustarget = false,
            boss = true,
        },
        -- Per-unit frame source: "eui" (skinned), "blizzard" (leave Blizzard's frame), or
        -- "hidden". Resolved via ns.GetUnitFrameSource, which also honors legacy enabledFrames=false => "hidden".
        frameSource = {},
        -- Stock styles (Global Settings > Style): Blizzard's current unit
        -- frame art or the classic frames, portrait masks and bar placement on
        -- our own frames with every EUI feature intact. Default OFF;
        -- reload-gated; the Classic flag wins when both are set.
        useBlizzardStyle = false,
        useClassicStyle = false,
        positions = {
            player = { point = "CENTER", relPoint = "CENTER", x = -317, y = -193.5 },
            target = { point = "CENTER", relPoint = "CENTER", x = 317, y = -201 },
            focus = { point = "CENTER", relPoint = "CENTER", x = 0, y = -285 },
            pet = { point = "CENTER", relPoint = "CENTER", x = -300, y = -260 },
            targettarget = { point = "CENTER", relPoint = "CENTER", x = 383, y = -152.5 },
            focustarget = { point = "CENTER", relPoint = "CENTER", x = 50, y = -261 },
            boss = { point = "CENTER", relPoint = "CENTER", x = 661, y = 251 },
            classPower = { point = "CENTER", relPoint = "CENTER", x = 0, y = -220 },
        },
        bossSpacing = 80,

        -- Player dispel overlay (player frame only; keys mirror Raid Frames)
        dispelOverlay        = "none",   -- "none", "fill", "full", "gradient", "gradient_sharp"
        dispelOverlayOpacity = 100,
        dispelOverlayByMe    = false,    -- only debuffs the player can dispel (engine filter token)
        dispelCustomBorder   = false,    -- Color Custom Borders: the frame border copied in the dispel type color
        dispelColorMagic   = { r = 0.349, g = 0.475, b = 1.0 },
        dispelColorCurse   = { r = 0.636, g = 0.0,   b = 0.64 },
        dispelColorDisease = { r = 0.671, g = 0.384, b = 0.098 },
        dispelColorPoison  = { r = 0.0,   g = 0.706, b = 0.286 },
        dispelColorBleed   = { r = 0.75,  g = 0.15,  b = 0.15 },
    }
}
local frames = {}
local SpecHasClassPower  -- forward declaration; defined after CLASS_POWER_TYPES

local CASTBAR_COLOR = { r = 0.114, g = 0.655, b = 0.514 }
local function GetCastbarColor()
    if db and db.profile and db.profile.castbarColor then
        return db.profile.castbarColor
    end
    return CASTBAR_COLOR
end

-- Bar gradients reuse two shared color objects to avoid per-call allocation (CreateColor
-- would allocate two tables each time). oUF re-flattens bar color every health/power
-- event so PostUpdateColor must repaint the gradient each time; SetGradient copies
-- values at call time, so one shared pair is safe across all frames.
local _gradColorA = CreateColor(1, 1, 1, 1)
local _gradColorB = CreateColor(1, 1, 1, 1)

local function ApplyBarGradient(ft, dir, br, bg, bb, ba, er, eg, eb, ea)
    ft:SetVertexColor(1, 1, 1, 1)
    _gradColorA:SetRGBA(br, bg, bb, ba)
    _gradColorB:SetRGBA(er, eg, eb, ea)
    ft:SetGradient(dir, _gradColorA, _gradColorB)
end

local SOLID_BACKDROP = { bgFile = "Interface\\Buttons\\WHITE8X8" }

-- Routes through shared EllesmereUI.GetFontPath("unitFrames"), which already handles
-- glyph-restricted locales (CJK/Cyrillic): keeps a SharedMedia font if it can render the
-- locale's glyphs, else falls back to the system font. Do NOT re-decide locale fallback
-- locally or locale clients could never use a custom font here.
local cachedFontPath = (EllesmereUI.GetFontPath("unitFrames"))
    or "Interface\\AddOns\\EllesmereUI\\media\\fonts\\Expressway.TTF"
local cachedFontPaths = {}  -- per-unit font cache
local function ResolveFontPath(unitKey)
    local gPath = EllesmereUI.GetFontPath("unitFrames")
        or "Interface\\AddOns\\EllesmereUI\\media\\fonts\\Expressway.TTF"
    cachedFontPath = gPath
    for _, uKey in ipairs({"player", "target", "focus", "boss", "pet", "targettarget", "focustarget"}) do
        cachedFontPaths[uKey] = gPath
    end
end

local function GetSelectedFont(unitKey)
    if unitKey and cachedFontPaths[unitKey] then
        return cachedFontPaths[unitKey]
    end
    return cachedFontPath
end

local function SetFSFont(fs, size, flags)
  EllesmereUI.ApplyModuleFont(fs, GetSelectedFont(), size or 12, "unitFrames", flags)
end

-- Shared cast-bar text anchoring (mirrors the nameplate cast text system). Three
-- elements (spell name, spell target, duration), each on a side. The duration
-- reserves a fixed width slot on its side; a non-center element sharing that side
-- shifts inward by it. Center elements anchor to bar center and never shift.
--   side    : "left" | "right" | "center"
--   pushed  : true when the duration occupies this same side and this element moves inward
--   reserve : duration reserved width (only consumed when pushed)
--   isTimer : the duration uses slightly tighter base insets than text
-- Returns: point (anchor), xOff (base, before the user X offset), justify
function ns.GetCastTextAnchor(side, pushed, reserve, isTimer)
    if side == "center" then
        return "CENTER", 0, "CENTER"
    elseif side == "left" then
        local base = isTimer and 3 or 5
        if pushed then base = base + reserve end
        return "LEFT", base, "LEFT"
    else -- "right"
        local base = -3
        if pushed then base = base - reserve end
        return "RIGHT", base, "RIGHT"
    end
end

-- WoW does not re-layout a FontString when only SetJustifyH changes; clearing then
-- re-setting the text forces it (must be a real change -- identical text is deduped).
-- GetText may return a secret (cast name/target); SetText accepts secrets untouched.
function ns.ReflowFontString(fs)
    if not fs then return end
    local t = fs:GetText()
    fs:SetText("")
    fs:SetText(t or "")
end

-- Disable WoW's automatic pixel snapping on a texture (prevents sub-pixel jitter)
local function UnsnapTex(tex)
    local PP = EllesmereUI and EllesmereUI.PP
    if PP then PP.DisablePixelSnap(tex)
    elseif tex.SetSnapToPixelGrid then tex:SetSnapToPixelGrid(false); tex:SetTexelSnappingBias(0) end
end

-- Health bar texture overlay lookup
local healthBarTextures, healthBarTextureNames, healthBarTextureOrder =
    EllesmereUI.BuildBarTextureTables(true)
ns.healthBarTextures = healthBarTextures
ns.healthBarTextureOrder = healthBarTextureOrder
ns.healthBarTextureNames = healthBarTextureNames

-- Map a unit ID ("player", "boss1", "targettarget", ...) to its db.profile key.
local function UnitToSettingsKey(unit)
    if not unit then return nil end
    if unit:match("^boss%d$") then return "boss" end
    if unit == "pet" then return "pet" end
    if db.profile[unit] then return unit end
    return nil
end

local function ApplyHealthBarTexture(health, unitKey, texKeyOverride)
    if not health then return end
    local texKey = texKeyOverride
    if not texKey then
        local s = unitKey and db.profile[unitKey]
        texKey = (s and s.healthBarTexture) or db.profile.healthBarTexture or "none"
    end
    local path   = EllesmereUI.ResolveTexturePath(healthBarTextures, texKey, "Interface\\Buttons\\WHITE8x8")
    health:SetStatusBarTexture(path)
    local hFill = health:GetStatusBarTexture()
    if hFill then UnsnapTex(hFill) end
    -- The swap replaced the fill object; re-derive rotation for the bar's axis.
    ns.ApplyFillRotation(health)

    -- Power bar: same texture. Walk up from health to find the oUF frame
    -- (health may be parented to a clip container, not the oUF frame directly).
    local frame = health:GetParent()
    if frame and not frame.Power and frame:GetParent() then
        frame = frame:GetParent()
    end
    local power = frame and frame.Power
    if power then
        if path then
            power:SetStatusBarTexture(path)
        else
            power:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
        end
        local pFill = power:GetStatusBarTexture()
        if pFill then UnsnapTex(pFill) end
    end
    -- Blizzard Style: the swaps above replaced the fill objects, so the stock
    -- masks are seated again on the new fills. The textures themselves stay
    -- the user's choice, so every colour renders exactly as picked.
    if frame and frame.Health == health and ns.UF_Blizz() then ns.UF_ApplyBlizzBarArt(frame) end
end

-- Resolve a unit's effective health bar texture KEY. Main frames use their own key
-- (falling back to the global default); mini frames (pet, ToT, focus target, boss)
-- inherit their donor frame's texture (ns.GetMiniDonorSettings) unless their own key is
-- non-nil/non-"inherit". Shared by the live frames and the options preview to match.
ns.ResolveHealthBarTextureKey = function(ownSettings, donorSettings)
    local own = ownSettings and ownSettings.healthBarTexture
    if own and own ~= "inherit" then return own end
    if donorSettings then
        local d = donorSettings.healthBarTexture
        if d and d ~= "inherit" then return d end
    end
    return db.profile.healthBarTexture or "none"
end

-- Cast bars reuse the unit's health bar texture. The cast bar stacks three textures
-- over the fill bounds (base fill + cast tint + shielded tint, all WHITE8X8 by
-- default), so apply to each. On ns to avoid the Lua 200-local cap.
ns.ApplyCastBarTexture = function(castbar, texKey)
    if not castbar then return end
    -- Blizzard Style: the stock cast fill art stays (set by the post-pass).
    if castbar._blizzCast then
        ns.UF_SetBlizzCastFill(castbar, castbar.channeling and "channel" or "cast")
        return
    end
    -- A cast bar texture of its own (the Textures page row) overrides the
    -- health bar's; "inherit" follows the health bar as before.
    local own = db.profile.castBarTexture
    if own and own ~= "inherit" then texKey = own end
    if texKey == "blizzard" then
        -- The "Blizzard" fill: the vanilla cast bar's own texture (the same
        -- entry the Resource Bars cast bar offers), tinted by the bar's
        -- colours like any file; the cast tint rides the same art.
        castbar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
        local fill = castbar:GetStatusBarTexture()
        if fill then
            fill:SetAtlas("UI-CastingBar-Fill", true)
            fill:SetHorizTile(false)
            UnsnapTex(fill)
        end
        if castbar.castTintLayer then castbar.castTintLayer:SetAtlas("UI-CastingBar-Fill", true) end
        return
    end
    local path = EllesmereUI.ResolveTexturePath(healthBarTextures, texKey or "none", "Interface\\Buttons\\WHITE8X8")
    castbar:SetStatusBarTexture(path)
    local fill = castbar:GetStatusBarTexture()
    if fill then
        fill:SetHorizTile(false)
        UnsnapTex(fill)
    end
    if castbar.castTintLayer then castbar.castTintLayer:SetTexture(path) end
    -- The shield tint keeps its creation WHITE8X8: 12.1 renders the loose
    -- statusbar art BLANK on plain overlay textures (negative synthetic
    -- fileID, healthy alpha/rect/shown readbacks -- measured in-game
    -- 2026-08-12, the invisible-interrupt-shield report), so re-pointing it
    -- at the art killed the shield entirely. A flat wash tints the textured
    -- fill below it; SetAlphaFromBoolean keeps driving it secret-safe.
end

-- Cast bar Fill Opacity (player/target/focus). Below 100 the active-cast tint layer
-- turns translucent via castbar._fillOp (consumed by PostCastStart and the shielded-tint
-- toggle), and the bg texture re-anchors to cover ONLY the empty portion (reverse-fill
-- aware) so the world shows through the fill instead of the bg. The base StatusBar fill
-- under the tint goes to alpha 0 at the SetStatusBarColor call sites so it can't bleed
-- through. Inert at 100 unless previously applied (_fillOpApplied). Value-blind
-- (relational anchors + plain alphas only), so secret cast states render identically.
-- castbar._castTintOn mirrors "the last alpha we wrote to castTintLayer was
-- above zero". It exists because castTintLayer:GetAlpha() cannot be trusted to
-- return a plain number: this castbar also drives _shieldedTint's alpha from
-- the SECRET notInterruptible flag (SetAlphaFromBoolean), and once secrecy is
-- in a castbar's render state an alpha read comes back secret. Comparing that
-- inside our own (tainted) execution throws "attempt to compare a secret number
-- value", which aborts the whole styling pass mid-way and leaves the cast bar
-- unanchored at screen centre. We write every one of these alphas ourselves, so
-- owning the state costs one boolean and removes the comparison entirely.
ns.ApplyCastFillOpacity = function(castbar, settings)
    local op = (settings and settings.castFillOpacity) or 100
    local bgHost = castbar:GetParent()
    local bgTex = bgHost and bgHost._bgTex
    if op >= 100 then
        if castbar._fillOpApplied then
            castbar._fillOpApplied = nil
            castbar._fillOp = nil
            if bgTex then
                bgTex:ClearAllPoints()
                bgTex:SetAllPoints(bgHost)
            end
            -- Mid-cast restore: the tint's active/idle state comes from our own
            -- flag, never from reading the widget back (see _castTintOn).
            if castbar.castTintLayer and castbar._castTintOn then
                castbar.castTintLayer:SetAlpha(1)
            end
        end
        return
    end
    castbar._fillOpApplied = true
    castbar._fillOp = op / 100
    local tex = castbar:GetStatusBarTexture()
    if bgTex and tex then
        bgTex:ClearAllPoints()
        if castbar.GetReverseFill and castbar:GetReverseFill() then
            bgTex:SetPoint("TOPLEFT", bgHost, "TOPLEFT", 0, 0)
            bgTex:SetPoint("BOTTOMRIGHT", tex, "BOTTOMLEFT", 0, 0)
        else
            bgTex:SetPoint("TOPLEFT", tex, "TOPRIGHT", 0, 0)
            bgTex:SetPoint("BOTTOMRIGHT", bgHost, "BOTTOMRIGHT", 0, 0)
        end
    end
    -- Mid-cast application: retune the tint if it is currently active.
    if castbar.castTintLayer and castbar._castTintOn then
        castbar.castTintLayer:SetAlpha(op / 100)
    end
end

-------------------------------------------------------------------------------
--  Health Bar Opacity -- controls the overall alpha of the health bar fill
-------------------------------------------------------------------------------
local function ApplyHealthBarAlpha(health, unitKey)
    if not health then return end
    local s = unitKey and db.profile[unitKey]
    local opacity = s and (s.healthBarOpacity or 90) or 90
    -- Old profiles stored opacity as a 0-1 float instead of a 0-100 int.
    if opacity <= 1.0 then opacity = opacity * 100 end
    local fillA = opacity / 100
    local fillTex = health:GetStatusBarTexture()
    -- With a gradient active the opacity is baked into the gradient endpoints,
    -- so region alpha must stay 1 to avoid double-dimming.
    if fillTex then fillTex:SetAlpha((s and s.gradientEnabled) and 1 or fillA) end
    if health.bg then health.bg:SetAlpha((s and (s.customBgAlpha or 100) or 100) / 100) end
end

-------------------------------------------------------------------------------
--  Power Bar Opacity -- controls the overall alpha of the power bar
-------------------------------------------------------------------------------
-- Power bar analog of AnchorHealthBg, gated on Fill Opacity: below 100 the bg covers
-- ONLY the empty portion (reverse-fill aware) so the translucent fill shows the world.
-- At 100 it returns to full-size only if previously re-anchored (_bgOpAnchored), so
-- untouched profiles never see an anchor write.
ns.AnchorPowerBg = function(power, opacity)
    local bg = power and power.bg
    local tex = power and power.GetStatusBarTexture and power:GetStatusBarTexture()
    if not bg or not tex then return end
    if (opacity or 100) >= 100 then
        if power._bgOpAnchored then
            power._bgOpAnchored = nil
            bg:ClearAllPoints()
            PP.Point(bg, "TOPLEFT", power, "TOPLEFT", 0, 0)
            PP.Point(bg, "BOTTOMRIGHT", power, "BOTTOMRIGHT", 0, 0)
        end
        return
    end
    power._bgOpAnchored = true
    bg:ClearAllPoints()
    if power.GetReverseFill and power:GetReverseFill() then
        bg:SetPoint("TOPLEFT", power, "TOPLEFT", 0, 0)
        bg:SetPoint("BOTTOMRIGHT", tex, "BOTTOMLEFT", 0, 0)
    else
        bg:SetPoint("TOPLEFT", tex, "TOPRIGHT", 0, 0)
        bg:SetPoint("BOTTOMRIGHT", power, "BOTTOMRIGHT", 0, 0)
    end
end

local function ApplyPowerBarAlpha(power, unitKey)
    if not power then return end
    local s = unitKey and db.profile[unitKey]
    local opacity = s and (s.powerBarOpacity or 100) or 100
    -- Old profiles stored opacity as a 0-1 float instead of a 0-100 int.
    if opacity <= 1.0 then opacity = opacity * 100 end
    local fillA = opacity / 100
    local fillTex = power:GetStatusBarTexture()
    -- Gradient bakes opacity into its endpoints, so keep region alpha at 1 then.
    if fillTex then fillTex:SetAlpha((s and s.powerGradientEnabled) and 1 or fillA) end
    if power.bg then power.bg:SetAlpha((s and (s.customPowerBgAlpha or 100) or 100) / 100) end
    -- Below 100 the bg retreats to the empty portion so the translucent fill
    -- shows the world (matches the health/cast bar Fill Opacity model).
    ns.AnchorPowerBg(power, opacity)
end

-------------------------------------------------------------------------------
--  Dark Mode -- flat dark health bar with gray background
-------------------------------------------------------------------------------
-- Fallback bg colour (#111) when no class/custom colour source exists. Dark Mode
-- fill/bg come from the global per-profile palette via GetDarkModeFill()/GetDarkModeBg().
local DARK_HEALTH_R, DARK_HEALTH_G, DARK_HEALTH_B = 0x11/255, 0x11/255, 0x11/255  -- #111111

-- Anchor the health bg to cover ONLY the empty (missing-health) portion so reduced
-- fill opacity never reveals the bg behind the filled section. The empty side flips
-- with reverse fill (normal empties RIGHT, reverse empties LEFT) -- anchoring the
-- wrong side collapses the bg to zero width whenever the bar isn't full. Relational
-- anchor, so the edge tracks the fill as health changes.
local function AnchorHealthBg(health)
    local bg = health and health.bg
    local tex = health and health.GetStatusBarTexture and health:GetStatusBarTexture()
    if not bg or not tex then return end
    local reversed = health.GetReverseFill and health:GetReverseFill()
    -- Vertical fill empties at the TOP (BOTTOM when reversed); read the axis off
    -- the bar itself so this needs no settings lookup.
    local vert = health.GetOrientation and health:GetOrientation() == "VERTICAL"
    -- The anchors bind to the fill texture's EDGE, which the engine moves with
    -- every SetValue -- they are live and never need re-pushing per paint
    -- (this ran per health event). Re-anchor only when an actual input moved:
    -- the texture OBJECT (retexture replaces it) or the axis/direction.
    local aKey = (vert and "V" or "H") .. (reversed and "R" or "N")
    if health._bgAnchorTex == tex and health._bgAnchorKey == aKey then
        return
    end
    health._bgAnchorTex = tex
    health._bgAnchorKey = aKey
    bg:ClearAllPoints()
    if vert then
        if reversed then
            bg:SetPoint("TOPLEFT", tex, "BOTTOMLEFT", 0, 0)
            bg:SetPoint("BOTTOMRIGHT", health, "BOTTOMRIGHT", 0, 0)
        else
            bg:SetPoint("TOPLEFT", health, "TOPLEFT", 0, 0)
            bg:SetPoint("BOTTOMRIGHT", tex, "TOPRIGHT", 0, 0)
        end
    elseif reversed then
        bg:SetPoint("TOPLEFT", health, "TOPLEFT", 0, 0)
        bg:SetPoint("BOTTOMRIGHT", tex, "BOTTOMLEFT", 0, 0)
    else
        bg:SetPoint("TOPLEFT", tex, "TOPRIGHT", 0, 0)
        bg:SetPoint("BOTTOMRIGHT", health, "BOTTOMRIGHT", 0, 0)
    end
end

local function ClassColorSourceUnit(unitKey, unit)
    if unitKey == "pet" then return "player" end
    return unit or unitKey
end

-------------------------------------------------------------------------------
--  Health-percent fill colors ("Dynamic Health Color")
--
--  The fill color follows how wounded the unit is: full health reads as one
--  color and bleeds toward another as health drops. Deliberately a PORT of the
--  Raid Frames implementation (GetClassicHealthCurve / GetCustomDynamicCurve /
--  GetClassReactiveCurve there) rather than a fresh model, so a unit frame and
--  a party frame set to the same mode paint the same color at the same health.
--  Keep the two in step if either side's stops or curve shape ever change.
--
--  Secret-value safe by construction: the curve is handed to UnitHealthPercent
--  and evaluated ENGINE-side, so a restricted unit's health never reaches Lua.
--  The returned ColorMixin's channels may themselves be secret -- they are only
--  ever passed to a setter, never inspected or arithmetic'd.
--
--  Per-unit settings (all nil-defaulted, so an untouched profile keeps the
--  existing flat class/custom fill):
--    healthColorMode  "none" | "classic" | "customDynamic" | "classReactive"
--    dynamicColor100 / dynamicColor50 / dynamicColor0   gradient stops
--
--  Wrapped in do/end: the caches are state these functions own, and the block
--  releases its registers at the close so the main chunk pays nothing.
-------------------------------------------------------------------------------
do
    -- Stop defaults, shared with the options page's swatch fallbacks. Same
    -- values the Raid Frames module uses.
    local DEF100 = { r = 0, g = 1, b = 0 }
    local DEF50  = { r = 0xEC/255, g = 0xEC/255, b = 0x32/255 }
    local DEF0   = { r = 0xE3/255, g = 0x30/255, b = 0x30/255 }
    ns.UF_DYN_DEF100, ns.UF_DYN_DEF50, ns.UF_DYN_DEF0 = DEF100, DEF50, DEF0

    -- Classic: red (dead) -> yellow (mid) -> green (full). One curve, forever.
    local classicCurve
    local function GetClassicCurve()
        if classicCurve then return classicCurve end
        local curve = C_CurveUtil.CreateColorCurve()
        curve:SetType(Enum.LuaCurveType.Linear)
        curve:AddPoint(0, CreateColor(1, 0, 0, 1))
        curve:AddPoint(0.5, CreateColor(1, 1, 0, 1))
        curve:AddPoint(1, CreateColor(0, 1, 0, 1))
        classicCurve = curve
        return curve
    end

    -- Custom Dynamic: the Classic path with the unit's three chosen stops.
    -- ONE cached curve keyed by the stop colors, not by unit: unit frames are
    -- repainted one at a time, and a rebuild is only the cost of three AddPoint
    -- calls. Frames configured differently therefore rebuild as they alternate;
    -- that is bounded by the number of DISTINCT palettes in use (nearly always
    -- one), not by the paint rate.
    local dynCurve
    local d0r, d0g, d0b, d50r, d50g, d50b, d100r, d100g, d100b
    local function GetDynamicCurve(s)
        local c0   = s.dynamicColor0   or DEF0
        local c50  = s.dynamicColor50  or DEF50
        local c100 = s.dynamicColor100 or DEF100
        if not (dynCurve
            and d0r   == c0.r   and d0g   == c0.g   and d0b   == c0.b
            and d50r  == c50.r  and d50g  == c50.g  and d50b  == c50.b
            and d100r == c100.r and d100g == c100.g and d100b == c100.b) then
            dynCurve = C_CurveUtil.CreateColorCurve()
            dynCurve:SetType(Enum.LuaCurveType.Linear)
            dynCurve:AddPoint(0,   CreateColor(c0.r,   c0.g,   c0.b,   1))
            dynCurve:AddPoint(0.5, CreateColor(c50.r,  c50.g,  c50.b,  1))
            dynCurve:AddPoint(1,   CreateColor(c100.r, c100.g, c100.b, 1))
            d0r, d0g, d0b       = c0.r, c0.g, c0.b
            d50r, d50g, d50b    = c50.r, c50.g, c50.b
            d100r, d100g, d100b = c100.r, c100.g, c100.b
        end
        return dynCurve
    end

    -- Class Color Reactive: the same gradient whose 100% stop is the unit's
    -- CLASS color, so full health reads as class identity and wounds bleed into
    -- the reactive palette (fully reactive by 40%). Cached per class token; the
    -- fingerprint names every input, so a Custom Class Colors edit rebuilds too.
    local GRAY = { r = 0.5, g = 0.5, b = 0.5 }
    local reactiveCurves = {}   -- classToken -> { curve, r, g, b } (class color used)
    local r0r, r0g, r0b, r50r, r50g, r50b
    local function GetClassReactiveCurve(s, classToken)
        local c0  = s.dynamicColor0  or DEF0
        local c50 = s.dynamicColor50 or DEF50
        if not (r0r == c0.r and r0g == c0.g and r0b == c0.b
            and r50r == c50.r and r50g == c50.g and r50b == c50.b) then
            wipe(reactiveCurves)
            r0r, r0g, r0b    = c0.r, c0.g, c0.b
            r50r, r50g, r50b = c50.r, c50.g, c50.b
        end
        local cc = EllesmereUI.GetClassColor(classToken) or GRAY
        local e = reactiveCurves[classToken]
        if not (e and e.r == cc.r and e.g == cc.g and e.b == cc.b) then
            local curve = C_CurveUtil.CreateColorCurve()
            curve:SetType(Enum.LuaCurveType.Linear)
            -- Front-loaded class return: fully reactive at 40% health, and the
            -- 0.75 stop already carries 75% class weight so identity snaps back
            -- quickly (40->75% climbs 0->75% class, 75->100% eases in the rest).
            curve:AddPoint(0,    CreateColor(c0.r,  c0.g,  c0.b,  1))
            curve:AddPoint(0.4,  CreateColor(c50.r, c50.g, c50.b, 1))
            curve:AddPoint(0.75, CreateColor(
                c50.r + (cc.r - c50.r) * 0.75,
                c50.g + (cc.g - c50.g) * 0.75,
                c50.b + (cc.b - c50.b) * 0.75, 1))
            curve:AddPoint(1,    CreateColor(cc.r,  cc.g,  cc.b,  1))
            e = { curve = curve, r = cc.r, g = cc.g, b = cc.b }
            reactiveCurves[classToken] = e
        end
        return e.curve
    end

    -- Resolved fill color for a unit under the settings table `s`.
    -- Returns  ok, r, g, b, secret  -- ok false means "not on a dynamic mode"
    -- (or the mode could not resolve) and the caller keeps whatever it had.
    --
    -- `ok` and `secret` are PLAIN booleans on purpose: on an identity-restricted
    -- unit r/g/b are SECRET numbers, and both truthiness-testing and comparing
    -- one throw. They may only ever be handed to a setter -- and `secret` marks
    -- exactly that case, because SetGradient refuses secrets where
    -- SetStatusBarColor accepts them.
    --
    -- classReactive needs a readable class token; a restricted unit has none, so
    -- it declines and the flat class/reaction fill already on the bar stands.
    -- (The Raid Frames twin greys out instead; keeping the real color is
    -- strictly better here, and only differs on focus/ToT-style units.)
    function ns.UF_DynamicHealthColor(unit, s)
        local mode = s and s.healthColorMode
        if not mode or mode == "none" or not unit then return false end
        if not (C_CurveUtil and UnitHealthPercent) then return false end
        local curve
        if mode == "classic" then
            curve = GetClassicCurve()
        elseif mode == "customDynamic" then
            curve = GetDynamicCurve(s)
        elseif mode == "classReactive" then
            local _, classToken = UnitClass(unit)
            if not classToken or issecretvalue(classToken) then return false end
            curve = GetClassReactiveCurve(s, classToken)
        else
            return false
        end
        local color = UnitHealthPercent(unit, true, curve)
        if not (color and color.GetRGB) then return false end
        local r, g, b = color:GetRGB()
        return true, r, g, b, issecretvalue(r)
    end

    -- Clean-number twins for the options previews, where the health percent is a
    -- known fake (0-1) rather than a secret. These MUST match the curves above
    -- or the designer teaches a color the live bar never shows.
    function ns.UF_ResolveDynamicColor(s, pct01)
        local c0   = s.dynamicColor0   or DEF0
        local c50  = s.dynamicColor50  or DEF50
        local c100 = s.dynamicColor100 or DEF100
        if pct01 >= 0.5 then
            local t = (pct01 - 0.5) * 2
            return c50.r + (c100.r - c50.r) * t,
                   c50.g + (c100.g - c50.g) * t,
                   c50.b + (c100.b - c50.b) * t
        end
        local t = pct01 * 2
        return c0.r + (c50.r - c0.r) * t,
               c0.g + (c50.g - c0.g) * t,
               c0.b + (c50.b - c0.b) * t
    end

    function ns.UF_ResolveClassicColor(pct01)
        if pct01 >= 0.5 then
            local t = (pct01 - 0.5) * 2
            return 1 - t, 1, 0
        end
        return 1, pct01 * 2, 0
    end

    function ns.UF_ResolveClassReactiveColor(s, classToken, pct01)
        local cc = (classToken and EllesmereUI.GetClassColor(classToken)) or GRAY
        local c0  = s.dynamicColor0  or DEF0
        local c50 = s.dynamicColor50 or DEF50
        if pct01 >= 0.4 then
            local w
            if pct01 >= 0.75 then
                w = 0.75 + (pct01 - 0.75)
            else
                w = (pct01 - 0.4) / 0.35 * 0.75
            end
            return c50.r + (cc.r - c50.r) * w,
                   c50.g + (cc.g - c50.g) * w,
                   c50.b + (cc.b - c50.b) * w
        end
        local t = pct01 / 0.4
        return c0.r + (c50.r - c0.r) * t,
               c0.g + (c50.g - c0.g) * t,
               c0.b + (c50.b - c0.b) * t
    end

    -- One entry point for every preview surface: resolves whichever dynamic mode
    -- `s` is on at a FAKE percent, or nil when the unit is on a flat fill.
    function ns.UF_PreviewDynamicColor(s, pct01)
        local mode = s and s.healthColorMode
        if not mode or mode == "none" then return nil end
        if mode == "classic" then
            return ns.UF_ResolveClassicColor(pct01)
        elseif mode == "customDynamic" then
            return ns.UF_ResolveDynamicColor(s, pct01)
        elseif mode == "classReactive" then
            local _, ct = UnitClass("player")
            return ns.UF_ResolveClassReactiveColor(s, ct, pct01)
        end
        return nil
    end
end

-- Carrier for a resolved-but-secret class color. Reused: it is written and consumed inside one
-- UpdateColor pass (SetStatusBarColor, then PostUpdateColor), and nothing stores it.
local SECRET_CLASS_COLOR = CreateColor(1, 1, 1, 1)

-- TEMPORARY oUF SHIM -- remove when upstream oUF ships secret-safe class coloring
-- (check during the standing per-bump lib re-diff). 12.1 build 68914 made UnitClass return a SECRET token
-- for identity-restricted units; the vendored health element's UpdateColor indexes
-- colors.class with it and secret table keys error (storms on ToT frames). Vendored-lib
-- edits aren't an option (packager re-pulls oUF tag:latest at release), so this rides
-- the documented Health.UpdateColor override hook: a faithful copy of the lib function
-- with ONLY the class tier guarded (unreadable class degrades to reaction/health tiers).
-- Installed via ApplyDarkTheme, the one chokepoint every health element passes at
-- creation. colorSelection is not carried over (needs oUF-private unitSelectionType;
-- no EUI health element enables it).
local function UF_SecretSafeHealthColor(self, event, unit)
    if not unit or self._euiUnit ~= unit then return end
    local element = self.Health

    local color
    if element.colorDisconnected and not UnitIsConnected(unit) then
        color = self.colors.disconnected
    elseif element.colorTapped and not UnitPlayerControlled(unit) and UnitIsTapDenied(unit) then
        color = self.colors.tapped
    elseif element.colorThreat and not UnitPlayerControlled(unit) and UnitThreatSituation("player", unit) then
        color = self.colors.threat[UnitThreatSituation("player", unit)]
    elseif (element.colorClass and (UnitIsPlayer(unit) or UnitInPartyIsAI(unit)))
        or (element.colorClassNPC and not (UnitIsPlayer(unit) or UnitInPartyIsAI(unit)))
        or (element.colorClassPet and UnitPlayerControlled(unit) and not UnitIsPlayer(unit)) then
        local _, class = UnitClass(unit)
        if issecretvalue(class) then
            -- 12.1 (68914): UnitClass is SecretWhenUnitIdentityRestricted (focus/focus-target/ToT):
            -- token can't be read or used as a table key. C_ClassColor.GetClassColor and
            -- SetStatusBarColor are both SecretArguments="AllowedWhenTainted", so the real
            -- color still reaches the bar without Lua inspecting it -- but only ever in
            -- Blizzard's shade. GetClassColorForRestrictedUnit recovers the user's custom
            -- class color for group members with the compare done in C; its r/g/b are secret,
            -- so they go into a scratch ColorMixin (plain field writes) and are never read.
            local ok, r, g, b = EllesmereUI.GetClassColorForRestrictedUnit(unit, class)
            if ok then
                SECRET_CLASS_COLOR:SetRGB(r, g, b)
                color = SECRET_CLASS_COLOR
            elseif C_ClassColor and C_ClassColor.GetClassColor then
                color = C_ClassColor.GetClassColor(class)
            end
        else
            color = class and self.colors.class[class]
        end
        if not color then
            -- Unreadable class: fall to the tiers the lib chain would have hit
            -- had the class branch not matched.
            if element.colorReaction and UnitReaction(unit, "player") then
                color = self.colors.reaction[UnitReaction(unit, "player")]
            elseif element.colorHealth then
                color = self.colors.health
            end
        end
    elseif element.colorReaction and UnitReaction(unit, "player") then
        color = self.colors.reaction[UnitReaction(unit, "player")]
    elseif element.colorSmooth and element.values and self.colors.health:GetCurve() then
        color = element.values:EvaluateCurrentHealthPercent(self.colors.health:GetCurve())
    elseif element.colorHealth then
        color = self.colors.health
    end

    if color then
        element:SetStatusBarColor(color:GetRGB())
    end

    if element.PostUpdateColor then
        element:PostUpdateColor(unit, color)
    end
end

-- `unit` is optional and used only to converge the setup paint with the repaint
-- paint (see the PostUpdateColor call at the tail of the non-dark branch). It is
-- passed by every caller that has it; Health elements never get `__owner`
-- (only aura elements do), so there is no fallback to recover it from.
local function ApplyDarkTheme(health, unit)
    if not health then return end
    -- TEMPORARY (see UF_SecretSafeHealthColor). Idempotent: this function
    -- re-runs on settings changes and re-assigning is harmless.
        health.UpdateColor = UF_SecretSafeHealthColor
    local isDark = db and db.profile and db.profile.darkTheme
    if isDark then
        health.colorClass = false
        health.colorClassPet = false
        health.colorReaction = false
        health.colorTapped = false
        health.colorDisconnected = false
        -- Fill/background from the global per-profile Dark Mode palette.
        local dfr, dfg, dfb, dfa = EllesmereUI.GetDarkModeFill()
        local dbr, dbg, dbb, dba = EllesmereUI.GetDarkModeBg()
        health:SetStatusBarColor(dfr, dfg, dfb)
        local darkFillTex = health:GetStatusBarTexture()
        if darkFillTex then darkFillTex:SetAlpha(dfa) end
        if health.bg then
            AnchorHealthBg(health)
            -- Background opacity rides the texture alpha; region alpha stays 1 so
            -- the two never multiply into a double-darkened background.
            health.bg:SetColorTexture(dbr, dbg, dbb, dba)
            health.bg:SetAlpha(1)
        end
        -- Re-apply dark color after oUF's class-color attempt and re-anchor bg to the
        -- fill edge. Alpha is NOT re-applied: SetStatusBarColor(r,g,b) with 3 args
        -- preserves texture alpha, so ApplyHealthBarAlpha's value survives oUF recolors.
        health.PostUpdateColor = function(self)
            local fr, fg, fb = EllesmereUI.GetDarkModeFill()
            self:SetStatusBarColor(fr, fg, fb)
            if self.bg then
                AnchorHealthBg(self)
            end
        end
    else
        health.colorClass = true
        health.colorReaction = true
        health.colorTapped = true
        health.colorDisconnected = true
        local unitKey = health._euiUnitKey
        local unitSettings = unitKey and db.profile[unitKey]
        health.colorClassPet = false
        if unitKey == "pet" then
            health.colorClass = false
            if unitSettings and unitSettings.healthClassColored then
                health.colorReaction = false
                health.colorTapped = false
                health.colorDisconnected = false
                local _, ct = UnitClass("player")
                local cc = ct and not issecretvalue(ct) and EllesmereUI.GetClassColor(ct)
                if cc then health:SetStatusBarColor(cc.r, cc.g, cc.b) end
            end
        end
        local customFill = unitSettings and unitSettings.customFillColor
        local customBg   = unitSettings and unitSettings.customBgColor
        if customFill then
            -- Custom fill overrides class coloring; skipped when class color is on.
            if not (unitSettings and unitSettings.healthClassColored) then
                health.colorClass = false
                health.colorReaction = false
                health.colorTapped = false
                health.colorDisconnected = false
                health:SetStatusBarColor(customFill.r, customFill.g, customFill.b)
            end
        end
        -- Tint bg to 20% of the class/reaction color, or use the custom bg color.
        -- Alpha is NOT re-applied: SetStatusBarColor(r,g,b) preserves texture
        -- alpha through oUF recolors.
        health.PostUpdateColor = function(self, unit, color)
            local uKey = self._euiUnitKey
            local uSettings = uKey and db.profile[uKey]
            local cFill = uSettings and uSettings.customFillColor
            local cBg   = uSettings and uSettings.customBgColor
            local classColored = uSettings and uSettings.healthClassColored
            local bgClassColored = uSettings and uSettings.bgClassColored
            -- Base fill color (custom, or oUF's class/reaction color); gradient
            -- applies additively when enabled, otherwise flat.
            -- haveBase/baseSecret are PLAIN booleans standing in for bR: on an
            -- identity-restricted unit bR is a secret number, and truthiness-testing one
            -- errors, so it may only ever be handed to a setter.
            local bR, bG, bB
            local haveBase, baseSecret = false, false
            -- Dynamic Health Color outranks every FLAT source (custom fill, class,
            -- reaction): the whole point is that the fill tracks damage taken. It
            -- does not displace the spatial Gradient below -- it becomes that
            -- gradient's start color, so the two compose.
            local haveDyn, dR, dG, dB, dSecret = ns.UF_DynamicHealthColor(unit, uSettings)
            if haveDyn then
                bR, bG, bB = dR, dG, dB
                haveBase, baseSecret = true, dSecret
            elseif cFill and not classColored then
                bR, bG, bB = cFill.r, cFill.g, cFill.b
                haveBase = true
            elseif classColored and uKey == "pet" then
                local _, ct = UnitClass("player")
                local cc = ct and not issecretvalue(ct) and EllesmereUI.GetClassColor(ct)
                if cc then bR, bG, bB = cc.r, cc.g, cc.b; haveBase = true end
            elseif color and color.GetRGB then
                bR, bG, bB = color:GetRGB()
                haveBase = true
                baseSecret = issecretvalue(bR)
            end
            -- Texture:SetGradient is SecretArguments="AllowedWhenUntainted", so a secret
            -- color cannot go through it from here at all. The flat color the health
            -- element already applied is correct, so a restricted unit keeps a flat bar.
            if uSettings and uSettings.gradientEnabled and haveBase and not baseSecret then
                local gc = uSettings.gradientColor
                -- A gradient overrides region alpha, so Bar Opacity is baked into
                -- the gradient endpoint alphas instead of SetAlpha.
                local ga = uSettings.healthBarOpacity or 90
                if ga > 1.0 then ga = ga / 100 end
                ApplyBarGradient(self:GetStatusBarTexture(), uSettings.gradientDir or "HORIZONTAL",
                    bR, bG, bB, ga,
                    gc and gc.r or 0.20, gc and gc.g or 0.20, gc and gc.b or 0.80, ga)
            elseif haveDyn then
                -- Must be written explicitly: the health element painted the flat
                -- class/reaction color a moment ago, and unlike the pet/custom
                -- branches below there is no earlier setup pass that pre-applied
                -- this one. SetStatusBarColor takes secrets, so a restricted unit
                -- still gets its real curve color here.
                self:SetStatusBarColor(bR, bG, bB)
            elseif classColored and uKey == "pet" and haveBase then
                self:SetStatusBarColor(bR, bG, bB)
            elseif cFill and not classColored then
                self:SetStatusBarColor(cFill.r, cFill.g, cFill.b)
            end
            if self.bg then
                AnchorHealthBg(self)
                local bgClassOk, bgClassR, bgClassG, bgClassB
                if bgClassColored then
                    local classUnit = ClassColorSourceUnit(uKey, unit or self._euiUnit or uKey)
                    bgClassOk, bgClassR, bgClassG, bgClassB = ns.ResolveBgClassColor(classUnit)
                end
                if bgClassOk then
                    -- Full class color; opacity comes from customBgAlpha (SetAlpha).
                    self.bg:SetColorTexture(bgClassR, bgClassG, bgClassB, 1)
                elseif cBg then
                    self.bg:SetColorTexture(cBg.r, cBg.g, cBg.b, 1)
                elseif cFill and not classColored then
                    self.bg:SetColorTexture(cFill.r * 0.2, cFill.g * 0.2, cFill.b * 0.2, 1)
                elseif color and color.GetRGB then
                    local r, g, b = color:GetRGB()
                    -- SetColorTexture takes secrets; the multiply does not, and there is no
                    -- C-side blend to darken one with. So a restricted unit's background
                    -- degrades to the default dark rather than throwing on the tint.
                    if issecretvalue(r) then
                        self.bg:SetColorTexture(DARK_HEALTH_R, DARK_HEALTH_G, DARK_HEALTH_B, 1)
                    else
                        self.bg:SetColorTexture(r * 0.2, g * 0.2, b * 0.2, 1)
                    end
                else
                    -- No color source (e.g. no target): default bg.
                    self.bg:SetColorTexture(DARK_HEALTH_R, DARK_HEALTH_G, DARK_HEALTH_B, 1)
                end
            end
        end
        if health.bg then
            -- PostUpdateColor re-applies this so it survives texture swaps.
            AnchorHealthBg(health)
            local bgClassColored = unitSettings and unitSettings.bgClassColored
            local bgClassOk, bgClassR, bgClassG, bgClassB
            if bgClassColored then
                local classUnit = ClassColorSourceUnit(unitKey, unitKey or (health.__owner and health.__owner._euiUnit))
                bgClassOk, bgClassR, bgClassG, bgClassB = ns.ResolveBgClassColor(classUnit)
            end
            if bgClassOk then
                -- Full class color; PostUpdateColor keeps it correct on updates.
                health.bg:SetColorTexture(bgClassR, bgClassG, bgClassB, 1)
            elseif customBg then
                health.bg:SetColorTexture(customBg.r, customBg.g, customBg.b, 1)
            elseif customFill then
                health.bg:SetColorTexture(customFill.r * 0.2, customFill.g * 0.2, customFill.b * 0.2, 1)
            else
                -- No custom colors: default dark bg (#111).
                health.bg:SetColorTexture(DARK_HEALTH_R, DARK_HEALTH_G, DARK_HEALTH_B, 1)
            end
        end
        -- Converge the SETUP paint with the REPAINT paint. Everything above only
        -- writes the flat class/custom color and then INSTALLS PostUpdateColor
        -- without ever running it, so any color that PostUpdateColor owns was
        -- lost until the next health event. That is invisible for a flat fill
        -- (setup already painted it) but not for Dynamic Health Color, which is
        -- resolved from the health percent and lives only in PostUpdateColor:
        -- the bar sat on the class/custom color until the unit was damaged.
        -- ReloadFrames makes this reachable on every settings change too -- it
        -- repaints via Engine.ForceAll FIRST and re-runs ApplyDarkTheme after,
        -- so the setup pass clobbered the correct color a moment after it landed.
        -- Idempotent by construction: PostUpdateColor is built to run on every
        -- health event, so one extra call here is free. A nil `color` just means
        -- the class/reaction tier contributes nothing, which is right at setup --
        -- the element has not resolved one yet.
        if health.PostUpdateColor then health:PostUpdateColor(unit, nil) end
    end
end
ns.ApplyDarkTheme = ApplyDarkTheme

-- Re-apply dark theme to every frame when the global Dark Mode palette changes
-- (fill/bg colour + opacity). Class/power darken propagates via ApplyColorsToOUF,
-- which RefreshDarkMode() calls right after these refreshers.
if EllesmereUI.RegisterDarkModeRefresh then
    EllesmereUI.RegisterDarkModeRefresh(function()
        for _, obj in pairs(frames) do
            if type(obj) == "table" and obj.Health then ApplyDarkTheme(obj.Health, obj._euiUnit) end
        end
        -- Boss "Activate Preview" fake frames need their red class-color
        -- substitute re-applied after the dark repaint above.
        if ns._bossPreviewActive and ns._ReapplyBossPreviewColor then
            ns._ReapplyBossPreviewColor()
        end
    end)
end

-------------------------------------------------------------------------------
--  Engine painters (oUF extraction). ns.Colors carries the exact color table
--  the shared color chains read through frame.colors: same value sources and
--  shapes as before, so every existing color decision lands on identical
--  numbers. Class entries are overwritten by the suite palette sync (the same
--  flow that used to write the library's table); reaction entries by the
--  module's own reaction sync. Published as EllesmereUI._UFColors so the
--  parent's color chokepoint can reach it.
-------------------------------------------------------------------------------
do
    local CreateColor = _G.CreateColor
    local colors = {
        health       = CreateColor(49 / 255, 207 / 255, 37 / 255),
        disconnected = CreateColor(0.6, 0.6, 0.6),
        tapped       = CreateColor(0.6, 0.6, 0.6),
        class    = {},
        reaction = {},
        threat   = {},
        power    = {},
    }
    for token, c in pairs(RAID_CLASS_COLORS) do
        colors.class[token] = CreateColor(c.r, c.g, c.b)
    end
    for idx, c in pairs(FACTION_BAR_COLORS) do
        colors.reaction[idx] = CreateColor(c.r, c.g, c.b)
    end
    for i = 0, 3 do
        colors.threat[i] = CreateColor(GetThreatStatusColor(i))
    end
    -- Both key forms land: Blizzard's table carries string tokens plus numeric
    -- aliases, and the painter looks up number-first, token-second.
    for key, c in pairs(PowerBarColor) do
        if type(c) == "table" and c.r then
            colors.power[key] = CreateColor(c.r, c.g, c.b)
        end
    end
    -- Dispel colors keyed by the game's dispel-type indices (the aura rows'
    -- type overlay reads these through a step curve). Blizzard's shared color
    -- objects are referenced directly; Enrage has no stock color.
    colors.dispel = {
        [0]  = _G.DEBUFF_TYPE_NONE_COLOR,
        [1]  = _G.DEBUFF_TYPE_MAGIC_COLOR,
        [2]  = _G.DEBUFF_TYPE_CURSE_COLOR,
        [3]  = _G.DEBUFF_TYPE_DISEASE_COLOR,
        [4]  = _G.DEBUFF_TYPE_POISON_COLOR,
        [9]  = CreateColor(243 / 255, 95 / 255, 245 / 255),
        [11] = _G.DEBUFF_TYPE_BLEED_COLOR,
    }
    ns.Colors = colors
    EllesmereUI._UFColors = colors

    -- Health value pass: min/max plus current (offline paints a full bar, the
    -- behavior users already see), native interpolation via the bar's own
    -- .smoothing, then the shared secret-safe color chain.
    local function PaintHealth(frame, unit, event)
        local element = frame.Health
        if not element or not unit then return end
        -- A UNIT_HEALTH delivery for this token proves the unit exists (the
        -- tracker only routes real unit events under that name); the identity
        -- and forced paths still pay the probe.
        if event ~= "UNIT_HEALTH" and not UnitExists(unit) then return end
        if not ns.Engine.ElementOn(frame, "Health") then return end
        -- Bar bounds ride the max-health/identity events (Blizzard's own
        -- contract); a pure UNIT_HEALTH value tick pushes only the value.
        if event ~= "UNIT_HEALTH" or not element._maxSet then
            element._maxSet = true
            element:SetMinMaxValues(0, UnitHealthMax(unit))
        end
        -- A corpse fires no further UNIT_HEALTH, so the death tick's paint is the
        -- last one the bar gets: zero it from the dead flag (a plain boolean in
        -- restricted content, where the value is secret) instead of the value,
        -- and without the interpolation, which otherwise eases toward zero and
        -- leaves a sliver standing on a bar that gets no further ticks.
        -- UnitIsDead, not UnitIsDeadOrGhost: a ghost is at full health, and
        -- Blizzard's own bar reads it the same way (CompactUnitFrame_UpdateHealthColor).
        if not UnitIsConnected(unit) then
            element:SetValue(UnitHealthMax(unit), element.smoothing)
        elseif UnitIsDead(unit) then
            element:SetValue(0)
        else
            element:SetValue(UnitHealth(unit), element.smoothing)
        end
        -- Color inputs (class/reaction/dark/disconnect/tap) change via their
        -- own events or identity repaints -- a pure health tick re-runs the
        -- color chain only for modes whose color follows health/combat state
        -- per tick (dynamic curve, threat). The color* flags are
        -- never set by this engine; the dynamic modes live in PostUpdateColor
        -- (ns.UF_DynamicHealthColor) behind the unit's healthColorMode, so that
        -- setting is the gate that keeps a dynamic bar tracking every tick.
        local unitKey = element._euiUnitKey
        local unitColorMode = unitKey and db.profile[unitKey]
        unitColorMode = unitColorMode and unitColorMode.healthColorMode
        if event ~= "UNIT_HEALTH" or element.colorSmooth or element.colorThreat
           or (unitColorMode and unitColorMode ~= "none") then
            UF_SecretSafeHealthColor(frame, event, unit)
        end
    end
    ns.Engine.SetPainter("health", PaintHealth)

    -- Power value pass: display-power resolution first (the player bar's
    -- spec-override hook publishes the resolved type for the text formatters),
    -- then min/max/value with offline painting full, then the base power-type
    -- color with the bar's own PostUpdateColor/PostUpdate layered on top in
    -- the same order as before.
    local function PaintPower(frame, unit, event)
        local element = frame.Power
        if not element or not unit or not UnitExists(unit) then return end
        if not ns.Engine.ElementOn(frame, "Power") then return end
        local ptype
        if element.displayAltPower and element.GetDisplayPower then
            ptype = element:GetDisplayPower(unit)
        end
        element.displayType = ptype
        local pnum, ptoken
        if ptype then pnum = ptype else pnum, ptoken = UnitPowerType(unit) end
        -- The resolved type for the value pass below, and its token in the
        -- power events' payload form for the engine's event filter. A secret
        -- type stashes nothing (no filter; the value pass paints in full).
        if issecretvalue(pnum) then
            element._euiPNum, element._euiPTok = nil, nil
        else
            element._euiPNum = pnum
            element._euiPTok = (not issecretvalue(ptoken) and ptoken)
                or EllesmereUI.POWER_ENUM_TO_KEY[pnum]
        end
        if element._manaRegenSpark then
            EllesmereUI.ManaRegenSpark.SetMana("uf", not issecretvalue(pnum) and pnum == Enum.PowerType.Mana)
        end
        local max = UnitPowerMax(unit, pnum)
        element:SetMinMaxValues(0, max)
        local cur
        if UnitIsConnected(unit) then
            cur = UnitPower(unit, pnum)
            element:SetValue(cur, element.smoothing)
        else
            cur = max
            element:SetValue(max, element.smoothing)
        end
        if element.colorPower then
            local color = ns.Colors.power[pnum] or (ptoken and ns.Colors.power[ptoken])
            if color then element:SetStatusBarColor(color:GetRGB()) end
        end
        if element.PostUpdateColor then element:PostUpdateColor(unit) end
        if element.PostUpdate then element:PostUpdate(unit, cur, 0, max) end
    end
    ns.Engine.SetPainter("power", PaintPower)

    -- Power value pass (the player's powerval channel, UNIT_POWER_FREQUENT):
    -- the bar value and the text zones that read power, nothing else. Bounds,
    -- colours, the gray-out, the display-type override and the regen spark's
    -- mana flag follow the power type, the unit or the settings, never the
    -- value, and stay on the full pass (UNIT_POWER_UPDATE, UNIT_MAXPOWER,
    -- UNIT_DISPLAYPOWER and every identity repaint), which also refreshes the
    -- stashed type. The cost prediction segment is anchored to the fill edge
    -- and moves with SetValue. With no readable stashed type the full pass
    -- runs instead.
    ns.Engine.SetValuePainter(function(frame, unit)
        local element = frame.Power
        if not element or not unit or not UnitExists(unit) then return end
        if not ns.Engine.ElementOn(frame, "Power") then return end
        local pnum = element._euiPNum
        if pnum == nil then
            PaintPower(frame, unit, "UNIT_POWER_FREQUENT")
        elseif UnitIsConnected(unit) then
            element:SetValue(UnitPower(unit, pnum), element.smoothing)
        end
        ns.UF_PaintPowerText(frame, unit)
    end)

    -- Absorbs: the HealthPrediction Override was always our own complete
    -- painter (bars, clips, text gates); the engine simply becomes its event
    -- source. Identity repaints arrive as pseudo-events, which the Override
    -- already treats as gate-refresh triggers.
    local function PaintAbsorb(frame, unit, event)
        if not ns.Engine.ElementOn(frame, "HealthPrediction") then return end
        local hp = frame.HealthPrediction
        if hp and hp.Override then hp.Override(frame, event or "ForceUpdate", unit) end
    end
    ns.Engine.SetPainter("absorb", PaintAbsorb)
end

-- Global Dark Mode master: exposes darkTheme so the parent addon's master toggle can
-- flip it with other modules. setOn mirrors the individual toggle (write flag + reload).
EllesmereUI.RegisterDarkModeToggle({
    id = "unitFrames",
    isOn = function()
        return (db and db.profile and db.profile.darkTheme) or false
    end,
    setOn = function(on)
        if not (db and db.profile) then return end
        db.profile.darkTheme = on
        if ns.ReloadFrames then ns.ReloadFrames() end
    end,
})

-- Smart power text: percent for healers/prot pally/arcane mage, numeric for the rest.
-- Shared by the oUF tag and the resource bars renderer. `displayedPowerType` (optional
-- Enum.PowerType) is the power the caller's bar actually shows; for form/spec-shifting
-- classes (Druid, Monk) the decision MUST follow the displayed power, not UnitPowerType --
-- a Balance druid's UnitPowerType is Astral Power even while the bar shows Mana, so the
-- mana number would render raw instead of percent otherwise.
local function EUI_IsSmartPowerPercent(displayedPowerType)
    local _, cls = UnitClass("player")
    if not cls then return false end
    -- Druid/Monk shift displayed power with form/spec: percent only while the bar shows
    -- Mana (Druid caster/Tree/travel + Mistweaver); raw otherwise (Cat=Energy, Bear=Rage,
    -- Moonkin=Astral, WW/BRM=Energy, incl. Restoration weaving Cat/Bear). Prefer the
    -- caller-supplied displayed power, else the live primary power type.
    if cls == "DRUID" or cls == "MONK" then
        local pt = displayedPowerType or UnitPowerType("player")
        return pt == Enum.PowerType.Mana
    end
    if cls == "PRIEST" or cls == "SHAMAN" then
        return true
    end
    -- Paladin: Holy and Protection (mana-based specs).
    if cls == "PALADIN" then
        local spec = GetSpecialization()
        return spec == 1 or spec == 2  -- Holy, Protection
    end
    -- Mage: only Arcane
    if cls == "MAGE" then
        local spec = GetSpecialization()
        return spec == 1  -- Arcane
    end
    -- Evoker: only Preservation
    if cls == "EVOKER" then
        local spec = GetSpecialization()
        return spec == 2  -- Preservation
    end
    return false
end
ns.EUI_IsSmartPowerPercent = EUI_IsSmartPowerPercent
EllesmereUI.IsSmartPowerPercent = EUI_IsSmartPowerPercent

-- Show Decimal on Text (global): AbbreviateNumbers config emitting one decimal per
-- magnitude band (240500 -> "240.5k", 2405000 -> "2.4m"). AbbreviateNumbers runs in
-- Blizzard's secure context, so a secret value plus this config stays secret-safe
-- (like the no-config call on secret health/power). Tags read these _G flags:
--   _G._EUI_AbbrevDecimalCfg = this table when on, nil when off
--   _G._EUI_TextDecimals     = true/false, selects "%.1f" vs "%d" for percents
--   _G._EUI_PctTrim          = { curve, cfg } trimming the percent, nil when off
-- Per band: significandDivisor = breakpoint / d, fractionDivisor = d (d = 10 for
-- one decimal, 100 for two). Ten-thousand-grouping locales (koKR/zhCN/zhTW) take
-- the shared number engine's thousand/wan/yi units instead of k/m/b, so these
-- frames read the same as Damage Meters and the gold bar on those clients.
local function DecimalAbbrevConfig(d)
    local g = EllesmereUI.NumberAbbrevGlyphs()
    if g then
        return { breakpointData = {
            { breakpoint = 1e8, abbreviation = g[3], significandDivisor = 1e8 / d, fractionDivisor = d, abbreviationIsGlobal = false },
            { breakpoint = 1e4, abbreviation = g[2], significandDivisor = 1e4 / d, fractionDivisor = d, abbreviationIsGlobal = false },
            { breakpoint = 1e3, abbreviation = g[1], significandDivisor = 1e3 / d, fractionDivisor = d, abbreviationIsGlobal = false },
        } }
    end
    return { breakpointData = {
        { breakpoint = 1e9, abbreviation = "b", significandDivisor = 1e9 / d, fractionDivisor = d, abbreviationIsGlobal = false },
        { breakpoint = 1e6, abbreviation = "m", significandDivisor = 1e6 / d, fractionDivisor = d, abbreviationIsGlobal = false },
        { breakpoint = 1e3, abbreviation = "k", significandDivisor = 1e3 / d, fractionDivisor = d, abbreviationIsGlobal = false },
    } }
end
-- WoW Forever: nothing under 10,000 abbreviates, so the k band starts there and
-- the thousand band goes (the shared engine's trim, EllesmereUI_NumberFormat.lua).
if EllesmereUI.IS_FOREVER then
    local bands = DecimalAbbrevConfig
    DecimalAbbrevConfig = function(d)
        local cfg = bands(d)
        cfg.breakpointData = EllesmereUI.ForeverAbbrevTiers(cfg.breakpointData)
        return cfg
    end
end
-- "Hide Trailing Zeros": AbbreviateNumbers drops a zero fraction ("100") but keeps a
-- real one ("99.5"), which "%.1f" cannot do and a SECRET percent forbids doing with
-- Lua string ops. It TRUNCATES though, so a fractional significandDivisor reads a tenth
-- low (0.1 renders 33.3 as "33.2"); the curve scales instead, handing over whole
-- tenths/hundredths, +0.5 so truncation lands where "%.1f" would have rounded.
local function MakePctTrim(scale, fractionDivisor)
    local curve = C_CurveUtil.CreateCurve()
    curve:SetType(Enum.LuaCurveType.Linear)
    curve:AddPoint(0.0, 0.5)
    curve:AddPoint(1.0, scale + 0.5)
    return {
        curve = curve,
        cfg = { breakpointData = {
            { breakpoint = 0, abbreviation = "", significandDivisor = 1, fractionDivisor = fractionDivisor, abbreviationIsGlobal = false },
        } },
    }
end
ns._pctTrim  = MakePctTrim(1000, 10)
ns._pctTrim2 = MakePctTrim(10000, 100)
function ns.ApplyTextDecimalGlobals()
    if db and db.profile and db.profile.showDecimalOnText then
        -- Built on first use, not at file load: a standalone build reads the Language
        -- override at its own ADDON_LOADED, after this file. The locale is fixed per session.
        if not ns._decimalAbbrevConfig then
            ns._decimalAbbrevConfig = DecimalAbbrevConfig(10)
            -- Two-decimal variant for boss frames ("Show 2 for Boss"): 240.55k / 2.45m.
            ns._decimalAbbrevConfig2 = DecimalAbbrevConfig(100)
        end
        _G._EUI_TextDecimals = true
        -- "Only Show for % Health": decimal on PERCENT, health/absorb VALUES whole --
        -- withhold the abbreviate configs (values fall back to plain AbbreviateNumbers)
        -- while _EUI_TextDecimals stays true for percents.
        local percentOnly = db.profile.showDecimalPercentOnly
        _G._EUI_AbbrevDecimalCfg = ns._decimalAbbrevConfig
        if percentOnly then _G._EUI_AbbrevDecimalCfg = nil end
        -- Percent-only, so "Only Show for % Health" never withholds these.
        local trimZeros = db.profile.showDecimalTrimZeros
        _G._EUI_PctTrim = trimZeros and ns._pctTrim or nil
        -- Boss frames get a second decimal place. Tags use the 1-decimal path
        -- for non-boss units when the flag is set, and ignore it when nil.
        if db.profile.showDecimalBoss2 ~= false then
            _G._EUI_BossExtraDecimal = true
            _G._EUI_AbbrevDecimalCfg2 = ns._decimalAbbrevConfig2
            if percentOnly then _G._EUI_AbbrevDecimalCfg2 = nil end
            _G._EUI_PctTrim2 = trimZeros and ns._pctTrim2 or nil
        else
            _G._EUI_BossExtraDecimal = false
            _G._EUI_AbbrevDecimalCfg2 = nil
            _G._EUI_PctTrim2 = nil
        end
    else
        _G._EUI_TextDecimals = false
        _G._EUI_AbbrevDecimalCfg = nil
        _G._EUI_BossExtraDecimal = false
        _G._EUI_AbbrevDecimalCfg2 = nil
        _G._EUI_PctTrim = nil
        _G._EUI_PctTrim2 = nil
    end
end

-- Shared text-piece functions consumed by the zone formatter table below.
local TagFns = {}

do
  local function AbbrevHP(unit)
    if not unit or not UnitExists(unit) then return "" end
    if not UnitIsConnected(unit) then return "OFFLINE" end
    if UnitIsDeadOrGhost(unit) then return "DEAD" end
    local hp = UnitHealth(unit) or 0
    local cfg = _G._EUI_AbbrevDecimalCfg
    -- Boss frames use the 2-decimal config when "Show 2 for Boss" is on.
    if _G._EUI_BossExtraDecimal and string.sub(unit, 1, 4) == "boss" then
      cfg = _G._EUI_AbbrevDecimalCfg2
    end
    return cfg and AbbreviateNumbers(hp, cfg) or AbbreviateNumbers(hp)
  end

  TagFns.curhpshort = AbbrevHP
end

do
  -- Health percent under the decimal options. "Hide Trailing Zeros" reads the percent
  -- through a scaling curve so AbbreviateNumbers can drop the zero "%.1f" would pad.
  local function PercentHP(unit)
    -- Predicted percent (incoming heals) can outlive the unit: a corpse fires no
    -- further UNIT_HEALTH and the text channel never hears UNIT_HEAL_PREDICTION.
    -- Corpses only, like Blizzard's health paths: a ghost is at full health, and
    -- the neighbouring DEAD zone is the piece that speaks for dead-or-ghost.
    if UnitIsDead(unit) then return "0" end
    local boss = _G._EUI_BossExtraDecimal and string.sub(unit, 1, 4) == "boss"
    local trim = _G._EUI_PctTrim
    if boss then trim = _G._EUI_PctTrim2 end
    if trim then
      local scaled = UnitHealthPercent(unit, true, trim.curve)
      if not scaled then return "0" end
      return AbbreviateNumbers(scaled, trim.cfg)
    end
    local pct = UnitHealthPercent(unit, true, CurveConstants.ScaleTo100)
    if not pct then return "0" end
    if boss then return string_format("%.2f", pct) end
    return string_format(_G._EUI_TextDecimals and "%.1f" or "%d", pct)
  end

  TagFns.perhp = PercentHP
  TagFns.perhpnosign = function(unit)
    if not unit or not UnitExists(unit) then return "" end
    if not UnitIsConnected(unit) then return "OFFLINE" end
    if UnitIsDeadOrGhost(unit) then return "DEAD" end
    return PercentHP(unit)
  end
end

-- Resolved power type per unit. Updated by the GetDisplayPower override so the
-- power text matches the power bar when powerTypeOverride is active (e.g.
-- Balance Druid showing Mana instead of Astral Power).
_G._EUI_ResolvedPowerType = _G._EUI_ResolvedPowerType or {}

local PLAYER_POWER_DEFAULT = {
    PRIEST = { [3] = 0 },   -- Shadow: default to Mana
    MONK   = { [2] = 0 },   -- Mistweaver: default to Mana
}
local PLAYER_POWER_ALT = {
    DRUID  = { [1] = 0, [2] = 0, [3] = 0 },  -- Balance/Feral/Guardian -> Mana
    PRIEST = { [3] = nil },                     -- Shadow alt -> Insanity (UnitPowerType)
    SHAMAN = { [1] = 0 },                       -- Elemental -> Mana
}

-- Forced display power type for the player (number = Enum.PowerType, nil =
-- UnitPowerType decides). Shared by the bar's GetDisplayPower, the color
-- resolver and the options preview so all three agree.
function EllesmereUI.GetPlayerPowerOverride()
    if not (db and db.profile) then return nil end
    local _, classFile = UnitClass("player")
    -- WoW Forever has no retail specs, so the spec tables below never apply
    -- there: only the druid "Power Type: Mana" choice, under its own string key.
    if EllesmereUI.IS_FOREVER then
        if classFile ~= "DRUID" then return nil end
        local ov = db.profile.player and db.profile.player.powerTypeOverride
        return (ov and ov.foreverDruid) and 0 or nil
    end
    local classDef = PLAYER_POWER_DEFAULT[classFile]
    local classAlt = PLAYER_POWER_ALT[classFile]
    if not (classDef or classAlt) then return nil end
    local spec = GetSpecialization and GetSpecialization()
    if not spec then return nil end
    -- powerTypeOverride is keyed by SPEC ID, never the GetSpecialization() index:
    -- the set is profile-wide, so an index key collides across classes (slot 3 is
    -- Guardian, Shadow AND Augmentation). classAlt/classDef stay index-keyed --
    -- they are nested per class already, so they cannot collide. Resource Bars may
    -- be disabled, hence the direct fallback.
    local sid = (_G._ERB_ResolveSpecIDCached and _G._ERB_ResolveSpecIDCached())
        or (C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfo(spec))
        or nil
    local ov = db.profile.player and db.profile.player.powerTypeOverride
    if sid and ov and ov[sid] and classAlt then
        return classAlt[spec]
    elseif classDef and classDef[spec] ~= nil then
        return classDef[spec]
    end
    return nil
end

-- (The perpp/curpp/absorb piece functions live in the zone-formatter block
-- below; they read the _EUI_ globals above.)

-- Effective level (scaling-aware), "??" when unknowable (skull bosses). A
-- SECRET level is returned RAW -- display-safe as a %s arg through
-- SetFormattedText, never compared/formatted in Lua (same rule as the secret
-- name in the target-name piece).
TagFns.level = function(u)
    if not u or not UnitExists(u) then return "" end
    local l = UnitEffectiveLevel(u)
    if UnitIsWildBattlePet(u) or UnitIsBattlePetCompanion(u) then
        l = UnitBattlePetLevel(u)
    end
    if l and issecretvalue and issecretvalue(l) then return l end
    if not l or l <= 0 then return "??" end
    return l
end

-- Class/reaction color for a unit's NAME, enemy-aware: players (and AI party members)
-- get class color; NPCs use reaction color (hostile red, neutral yellow, friendly
-- green, tap-denied gray). Custom Enemy Colors override is honored via oUF.colors.reaction.
-- Returns r,g,b (0-1) or nil (caller's own default); secret-safe for uninspectable units.
-- On ns for the local cap; shared by ApplyClassColor and eui-tgtname so "Name > Target"
-- colors like the unit frame name.
ns.ResolveUnitNameColor = function(unit)
    if not unit then return nil end
    if UnitIsPlayer(unit) or (UnitInPartyIsAI and UnitInPartyIsAI(unit)) then
        local _, class = UnitClass(unit)
        if not issecretvalue(class) and class then
            local c = (CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS)[class]
            if c then return c.r, c.g, c.b end
        end
        return nil
    end
    if UnitExists(unit) then
        if UnitIsTapDenied and UnitIsTapDenied(unit) then
            return 0.6, 0.6, 0.6
        end
        local reaction = UnitReaction(unit, "player")
        if reaction and not issecretvalue(reaction) then
            local c = (ns.Colors and ns.Colors.reaction and ns.Colors.reaction[reaction])
                or FACTION_BAR_COLORS[reaction]
            if c then return c.r, c.g, c.b end
        end
    end
    return nil
end

-- Shared secret-class-color recovery for identity-restricted units (ToT, focus-target):
-- the user's custom color for a matching group member, else Blizzard's shade. Used by
-- ResolveBgClassColor and ApplyClassColor; ResolveUnitNameColor does NOT use this, since
-- its result also feeds the [eui-tgtcol] hex-escape tag, which cannot format secret
-- channels itself (that tag takes a secret hex from GenerateHexColor on its own and
-- hands it to SetFormattedText untouched).
-- Returns ok, r, g, b -- ok is a PLAIN boolean, r/g/b may be SECRET, only safe as setter args.
local function ResolveRestrictedClassColor(unit, class)
    local ok, r, g, b = EllesmereUI.GetClassColorForRestrictedUnit(unit, class)
    if ok then return true, r, g, b end
    if C_ClassColor and C_ClassColor.GetClassColor then
        local c = C_ClassColor.GetClassColor(class)
        if c then return true, c.r, c.g, c.b end
    end
    return false
end

-- Background class-color source, enemy-aware. UnitClass() reports WARRIOR for NPCs
-- rather than nil, so a bare lookup paints every mob Warrior tan. Players (and AI
-- party members) keep EllesmereUI.GetClassColor (custom colors + Class Color Darken
-- baked in); NPCs fall through to the reaction color, matching the unit name, the
-- border and the custom Enemy Colors override. On ns for the local cap.
-- Returns ok, r, g, b -- ok is a PLAIN boolean, r/g/b may be SECRET numbers on an
-- identity-restricted unit (ToT/focus-target): callers must branch on ok, never on
-- the truthiness of r, and may only ever hand r/g/b to a setter like SetColorTexture.
ns.ResolveBgClassColor = function(classUnit)
    if not classUnit then return false end
    if UnitIsPlayer(classUnit) or (UnitInPartyIsAI and UnitInPartyIsAI(classUnit)) then
        local _, ct = UnitClass(classUnit)
        if issecretvalue(ct) then
            return ResolveRestrictedClassColor(classUnit, ct)
        end
        local cc = ct and EllesmereUI.GetClassColor(ct)
        if cc then return true, cc.r, cc.g, cc.b end
        return false
    end
    local r, g, b = ns.ResolveUnitNameColor(classUnit)
    return r ~= nil, r, g, b
end

-- External nickname providers key us by this addon name. Suite = "EllesmereUI" (the
-- registered brand) so one provider checkbox controls every EUI module; standalone =
-- our renamed folder name, which always contains "Standalone" (rename-immune token).
-- On ns for the Lua 5.1 200-local ceiling.
ns.NICK_ADDON = addonName:find("Standalone") and addonName or "EllesmereUI"

-- Resolve a unit's display name through MethodInternal's authoritative surface
-- choice for known Method players, then the normal provider order: NSAPI ->
-- TimelineReminders -> LiquidAPI, then the raw unit name. Each
-- external call is pcall-wrapped so a misbehaving API can never break names.
--
-- SECRET-SAFE: an enemy unit's UnitName is secret in protected content and any Lua op
-- on it (==, .., format) throws. Nicknames only apply to your own group, so: non-players
-- short-circuit to the raw name; name-keyed providers (NSAPI, LiquidAPI) are skipped
-- when the name is secret; TimelineReminders is UNIT-keyed (GetNickname(unit)), safe to
-- consult regardless (result still re-validated as a clean string). The final return
-- may be the raw (possibly secret) name -- display-safe since oUF feeds tag returns to
-- SetFormattedText as a %s arg without inspecting them.
function ns.ResolveUnitNickname(unit)
    local name, surname = UnitName(unit)
    if not name then return "" end
    -- Nicknames are player-only; NPCs (bosses, etc.) keep their name.
    if not UnitIsPlayer(unit) then return name end
    local nameSecret = issecretvalue and issecretvalue(name)
    local display
    -- MethodInternal's surface choice is authoritative for known Method players,
    -- including Character Name (which deliberately equals the raw name). It sits
    -- ahead of the EUI master toggle so the MethodInternal-owned setting works on
    -- its selected surface; unknown players continue through EUI's normal chain.
    if EasyNicknameAPI and EasyNicknameAPI.GetNicknameForUnitForSurface then
        local ok, dn, handled = pcall(
            EasyNicknameAPI.GetNicknameForUnitForSurface, unit, "unitFrames")
        if ok and handled == true then
            if type(dn) == "string"
               and not (issecretvalue and issecretvalue(dn)) and dn ~= "" then
                return dn
            end
            return EllesmereUI.WithSurname(name, surname)
        end
    end
    -- Master toggle (Unit Frames > main frames > Display, default OFF): when off,
    -- skip the remaining provider lookups and show the raw unit name (display-safe;
    -- with the surname on WoW Forever).
    if not (db and db.profile and db.profile.showNicknames) then return EllesmereUI.WithSurname(name, surname) end
    if not nameSecret and NSAPI and NSAPI.GetName then
        local ok, dn = pcall(NSAPI.GetName, NSAPI, name, "EUI")
        if ok and type(dn) == "string"
           and not (issecretvalue and issecretvalue(dn)) and dn ~= "" and dn ~= name then
            display = dn
        end
    end
    if not display then
        local TR = TimelineReminders
        if TR and TR.GetNickname and TR.HasNickname and TR.NicknamesEnabledForAddOn then
            local okGate, enabled = pcall(TR.NicknamesEnabledForAddOn, TR, ns.NICK_ADDON)
            if okGate and enabled then
                local okHas, has = pcall(TR.HasNickname, TR, unit)
                if okHas and has then
                    local ok, dn = pcall(TR.GetNickname, TR, unit)
                    if ok and type(dn) == "string"
                       and not (issecretvalue and issecretvalue(dn)) and dn ~= "" then
                        display = dn
                    end
                end
            end
        end
    end
    if not display and not nameSecret and LiquidAPI and LiquidAPI.GetNicknameForEllesmereUI then
        local ok, dn = pcall(LiquidAPI.GetNicknameForEllesmereUI, name)
        if ok and type(dn) == "string"
           and not (issecretvalue and issecretvalue(dn)) and dn ~= "" then
            display = dn
        end
    end
    if display then return display end
    return EllesmereUI.WithSurname(name, surname)
end

-- Nickname-aware replacement for the stock [name] tag (see ContentToTag). Returns
-- the nickname when one applies, else the raw unit name.
TagFns.name = function(unit)
    -- Truncation is width-based (per-slot Width % clamp), never character-based:
    -- FontString width boxes ellipsize in the renderer, which also works on SECRET
    -- enemy names Lua cannot measure or substring.
    return ns.ResolveUnitNickname(unit)
end

-- Live name refresh: repaint every frame's text zones so added/removed
-- nicknames (or a flipped provider checkbox) apply without a /reload. Fired by
-- the provider callbacks below; cheap (a handful of frames).
function ns.RefreshAllUnitNames()
    for _, f in pairs(frames) do
        if type(f) == "table" and f._euiTextZones then
            ns.UF_PaintText(f, f._euiUnit)
        end
    end
end
-- Name text only re-renders on name events or via the refresh above, so a raw
-- db restore (Spec Overrides apply, profile swap) needs this exported.
_G._EUF_RefreshUnitNames = ns.RefreshAllUnitNames

-- Cold-login text repaint: on a first (uncached) login a fontstring can hold the
-- correct string yet render blank until /reload, since it only repaints on a text
-- CHANGE and repainting sets the same string (a no-op). Force a "" -> value
-- transition on every zone fontstring shortly after login, repeated since timing
-- varies; the zone repaint restores the real strings synchronously, no flicker.
do
    local function ForceTextRepaint()
        for _, f in pairs(frames) do
            -- The painter refuses an empty token, so a frame between units must
            -- not be blanked here either -- it would never get the value back.
            if type(f) == "table" and f._euiTextZones
               and f._euiUnit and UnitExists(f._euiUnit) then
                local zones = f._euiTextZones
                for i = 1, #zones do
                    local fs = zones[i].fs
                    if fs and fs.SetText then fs:SetText("") end
                end
                if #zones > 0 then ns.UF_PaintText(f, f._euiUnit) end
            end
        end
    end

    local ev = CreateFrame("Frame")
    ev:RegisterEvent("PLAYER_ENTERING_WORLD")
    ev:SetScript("OnEvent", function(self)
        self:UnregisterAllEvents()
        for _, delay in ipairs({ 0.25, 1, 3 }) do
            C_Timer.After(delay, ForceTextRepaint)
        end
    end)
end

-- Provider callbacks. MethodInternal uses the addon-loaded callback; NSAPI and
-- TimelineReminders retry on PLAYER_LOGIN/PLAYER_ENTERING_WORLD. Registrant key MUST
-- be "EllesmereUIUnitFrames", not "EllesmereUI": Raid Frames owns that key and
-- CallbackHandler keys registrations by it, so reuse would clobber one module. The
-- provider CHECKBOX key stays shared (ns.NICK_ADDON/"EUI") so one toggle drives raid AND unit frames.
do
    local function RefreshNames() if ns.RefreshAllUnitNames then ns.RefreshAllUnitNames() end end
    local function RegisterMethodInternal()
        if ns._methodInternalSurfaceNickHooked then return end
        if EasyNicknameAPI and EasyNicknameAPI.RegisterCallback then
            EasyNicknameAPI.RegisterCallback(
                "SurfaceNicknamesChanged", RefreshNames, "EllesmereUIUnitFrames")
            ns._methodInternalSurfaceNickHooked = true
        end
    end
    local function RegisterNSRT()
        if ns._nsrtNickHooked then return true end
        if NSAPI and NSAPI.RegisterCallback then
            NSAPI.RegisterCallback("EllesmereUIUnitFrames", "NSRT_NICKNAME_UPDATED", RefreshNames)
            NSAPI.RegisterCallback("EllesmereUIUnitFrames", "EUI_NICKNAME_TOGGLE", RefreshNames)
            ns._nsrtNickHooked = true
            return true
        end
        return false
    end
    local function RegisterTR()
        if ns._trNickHooked then return true end
        local TR = TimelineReminders
        if TR and TR.RegisterCallback then
            TR.RegisterCallback("EllesmereUIUnitFrames", "TimelineReminders_NicknameToggle", function(_, _, addOnName)
                if addOnName == ns.NICK_ADDON then RefreshNames() end
            end)
            TR.RegisterCallback("EllesmereUIUnitFrames", "TimelineReminders_NicknameUpdate", function()
                RefreshNames()
            end)
            ns._trNickHooked = true
            return true
        end
        return false
    end
    if not (RegisterNSRT() and RegisterTR()) then
        local nf = CreateFrame("Frame")
        nf:RegisterEvent("PLAYER_LOGIN")
        nf:RegisterEvent("PLAYER_ENTERING_WORLD")
        nf:SetScript("OnEvent", function(self, event)
            local a = RegisterNSRT()
            local b = RegisterTR()
            if (a and b) or event == "PLAYER_ENTERING_WORLD" then self:UnregisterAllEvents() end
        end)
    end
    EventUtil.ContinueOnAddOnLoaded("MethodInternal", RegisterMethodInternal)
end

-- "Name > Target" is built from FOUR tags so the (possibly SECRET) target name is never
-- compared/concatenated/formatted in Lua -- oUF joins tag returns via SetFormattedText,
-- where the name is only a %s display arg. ContentToTag maps "nametotarget" to
-- "[name][eui-tgtsep(...)][eui-tgtcol][eui-tgtname]": [name] = unit's own name (stock
-- oUF tag); [eui-tgtsep] = indicator shown only when the unit has a target (per-slot
-- separator/color ride in tag ARGS, see BuildTgtSepTag; no args = " > "); [eui-tgtcol] =
-- target's class/reaction COLOR escape (no name involved); [eui-tgtname] = target's name,
-- returned RAW. The colour escape precedes the raw name and runs to end of string, so
-- the target name colours IDENTICALLY to the ToT frame name (both via
-- ns.ResolveUnitNameColor) -- works for a SECRET name only because colour and name are
-- SEPARATE tags joined by SetFormattedText, never touched together in Lua.
--
-- PLAYER_TARGET_CHANGED is unitless in oUF (refreshes every frame), covering the player
-- frame's target; UNIT_TARGET covers target/focus frames' own target.

-- Separator/indicator between the names, shown only when the unit has a target. Plain
-- literal plus color escapes; no secret is touched. Args: sepHex = separator string,
-- hex-encoded per byte (safe inside tag brackets), rendered space-padded like " > ";
-- colorSpec = "class" for the TARGET's class/reaction color (same resolver as the
-- target name), else a fixed "rrggbb" hex, closed with |r so a missing [eui-tgtcol]
-- can't inherit it. Decoded separators/escapes are cached: fires on every target
-- change, must not allocate after warmup.
-- (The separator between "Name > Target" is built per-zone by
-- ns.MakeTgtSepPiece in the formatter block below; it closes over the decoded
-- separator and color mode from settings and recolors class-mode per call.)

-- The target's class/reaction colour escape (e.g. "|cffc41f3b"), or "". Uses
-- ns.ResolveUnitNameColor, the SAME resolver ApplyClassColor uses for the Target
-- of Target name. No unit NAME is touched, so it is fully secret-safe.
TagFns.tgtcol = function(unit)
    local tunit = unit and (unit .. "target")
    if not tunit or not UnitExists(tunit) then return "" end
    local r, g, b = ns.ResolveUnitNameColor(tunit)
    if not r then
        -- Secret class token (identity-restricted target, e.g. a boss's own
        -- target): GenerateHexColor's result may itself be secret, but still
        -- renders correctly through SetFormattedText's arg lane -- don't reject it.
        if UnitIsPlayer(tunit) and C_ClassColor and C_ClassColor.GetClassColor then
            local _, class = UnitClass(tunit)
            if issecretvalue(class) then
                local cc = C_ClassColor.GetClassColor(class)
                if cc and cc.GenerateHexColor then
                    local ok, hex = pcall(cc.GenerateHexColor, cc)
                    if ok and type(hex) == "string" then
                        return "|c" .. hex
                    end
                end
            end
        end
        -- Still nothing usable: the plain reaction colour instead of "".
        local reaction = UnitReaction(tunit, "player")
        if reaction and not issecretvalue(reaction) then
            local c = (ns.Colors and ns.Colors.reaction and ns.Colors.reaction[reaction])
                or FACTION_BAR_COLORS[reaction]
            if c then r, g, b = c.r, c.g, c.b end
        end
    end
    if not r then return "" end
    return string.format("|cff%02x%02x%02x", math.floor(r * 255 + 0.5),
        math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

-- The unit's target NAME (nickname-aware via ResolveUnitNickname; otherwise the
-- raw, possibly secret name -- display-safe via SetFormattedText, never
-- inspected). Colour comes from [eui-tgtcol] in front of it.
TagFns.tgtname = function(unit)
    local tunit = unit and (unit .. "target")
    if not tunit or not UnitExists(tunit) then return "" end
    return ns.ResolveUnitNickname(tunit)
end

-------------------------------------------------------------------------------
--  Text pieces + zone formatters (oUF extraction). Each options content key
--  maps to a format string plus piece functions; the engine's text painter
--  renders a zone with SetFormattedText(fmt, piece1(u), piece2(u), ...).
--  Secret rule: name/level/target-name pieces may return RAW secret values by
--  design; they are never concatenated or inspected in Lua -- the format-arg
--  lane is the only thing that touches them, exactly as the tag engine did,
--  so restricted-content rendering is unchanged.
-------------------------------------------------------------------------------
do
    local sf = string.format
    local P = {}
    ns.TextPieces = P

    -- Function-registered tag methods are shared directly: one body, no drift.
    P.curhpshort  = TagFns.curhpshort
    P.perhp       = TagFns.perhp
    P.perhpnosign = TagFns.perhpnosign
    P.level       = TagFns.level
    -- Level in Blizzard's difficulty colors (Level Difficulty Color). A secret
    -- level passes through raw and uncolored, same rule as P.level.
    P.levelcol    = function(u)
        local l = TagFns.level(u)
        if issecretvalue(l) or l == "" then return l end
        local r, g, b = EllesmereUI.GetLevelColor(u, (l == "??") and -1 or l)
        return EllesmereUI.ColorText(l, r, g, b)
    end
    -- Same, with friendly units in their difficulty color too (Include Friendly).
    P.levelcolall = function(u)
        local l = TagFns.level(u)
        if issecretvalue(l) or l == "" then return l end
        local r, g, b = EllesmereUI.GetLevelColor(u, (l == "??") and -1 or l, true)
        return EllesmereUI.ColorText(l, r, g, b)
    end
    P.name        = TagFns.name
    P.tgtcol      = TagFns.tgtcol
    P.tgtname     = TagFns.tgtname

    -- String-compiled tag methods get real equivalents (same logic, same
    -- _EUI_ globals; the compiled strings stay registered only while the tag
    -- engine still runs).
    P.perpp = function(u)
        local pType = _G._EUI_ResolvedPowerType[u] or UnitPowerType(u)
        return sf("%d", UnitPowerPercent(u, pType, true, CurveConstants.ScaleTo100))
    end
    P.curpp = function(u)
        local pType = _G._EUI_ResolvedPowerType[u] or UnitPowerType(u)
        return AbbreviateNumbers(UnitPower(u, pType))
    end
    P.absorb = function(u)
        if not u or not UnitExists(u) then return "" end
        return sf("%s", C_StringUtil.TruncateWhenZero(UnitGetTotalAbsorbs(u) or 0))
    end
    P.absorbshort = function(u)
        if not u or not UnitExists(u) then return "" end
        local cfg = _G._EUI_AbbrevDecimalCfg
        return cfg and AbbreviateNumbers(UnitGetTotalAbsorbs(u) or 0, cfg)
            or AbbreviateNumbers(UnitGetTotalAbsorbs(u) or 0)
    end
    P.healabsorb = function(u)
        if not u or not UnitExists(u) then return "" end
        return sf("%s", C_StringUtil.TruncateWhenZero(UnitGetTotalHealAbsorbs(u) or 0))
    end
    P.healabsorbshort = function(u)
        if not u or not UnitExists(u) then return "" end
        local cfg = _G._EUI_AbbrevDecimalCfg
        return cfg and AbbreviateNumbers(UnitGetTotalHealAbsorbs(u) or 0, cfg)
            or AbbreviateNumbers(UnitGetTotalHealAbsorbs(u) or 0)
    end
    P.group = function(u)
        if not IsInRaid() then return "" end
        local idx = UnitInRaid(u)
        if idx then
            local _, _, subgroup = GetRaidRosterInfo(idx)
            return subgroup or ""
        end
        return ""
    end

    -- Separator piece for "Name > Target": resolved from settings at apply
    -- time (re-applied whenever settings change, like everything else on the
    -- page), closing over the decoded separator and its color mode. Class
    -- mode recolors per call so the indicator tracks the target's reaction.
    -- literal (optional): an already padded string drawn in place of the
    -- separator in the same Indicator Color (the Target content's prefix).
    function ns.MakeTgtSepPiece(prefix, settings, literal)
        local sep = literal
        if not sep then
            sep = settings[prefix .. "TargetSep"]
            if type(sep) ~= "string" or sep == "" then sep = ">" end
            sep = " " .. sep .. " "
        end
        if settings[prefix .. "TargetSepClassColor"] then
            return function(u)
                if not (u and UnitExists(u .. "target")) then return "" end
                local r, g, b = ns.ResolveUnitNameColor(u .. "target")
                if r then
                    return sf("|cff%02x%02x%02x%s|r",
                        math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5),
                        math.floor(b * 255 + 0.5), sep)
                end
                return sep
            end
        end
        local c = settings[prefix .. "TargetSepColor"]
        local esc
        if type(c) == "table" then
            esc = EllesmereUI.HexColor(c.r or 1, c.g or 1, c.b or 1)
        else
            esc = EllesmereUI.COLOR_CODES.WHITE
        end
        local colored = esc .. sep .. "|r"
        return function(u)
            if not (u and UnitExists(u .. "target")) then return "" end
            return colored
        end
    end

    -- Content key -> zone definition. Mirrors ContentToTag's output shapes
    -- one-for-one so rendered text is byte-identical.
    local ZONE_STATIC = {
        name         = { "%s", "name" },
        levelname    = { "%s | %s", "level", "name" },
        namelevel    = { "%s | %s", "name", "level" },
        level        = { "%s", "level" },
        both         = { "%s | %s%%", "curhpshort", "perhp" },
        bothdash     = { "%s - %s%%", "curhpshort", "perhp" },
        perhpnum     = { "%s%% | %s", "perhp", "curhpshort" },
        perhpnumdash = { "%s%% - %s", "perhp", "curhpshort" },
        curhpshort   = { "%s", "curhpshort" },
        perhp        = { "%s%%", "perhp" },
        perhpnosign  = { "%s", "perhpnosign" },
        perpp        = { "%s%%", "perpp" },
        curpp        = { "%s", "curpp" },
        curhp_curpp  = { "%s | %s", "curhpshort", "curpp" },
        perhp_perpp  = { "%s%% | %s%%", "perhp", "perpp" },
        absorb       = { "%s", "absorb" },
        absorbshort  = { "%s", "absorbshort" },
        healabsorb   = { "%s", "healabsorb" },
        healabsorbshort = { "%s", "healabsorbshort" },
        group        = { "%s", "group" },
    }
    -- Identity-only zones: their pieces read name/level, which change only on
    -- identity edges (UNIT_NAME_UPDATE, UNIT_LEVEL, repoints, provider
    -- callbacks) -- Blizzard paints names on UNIT_NAME_UPDATE alone. Not
    -- listed: nametotarget (target names churn) and group (roster-driven,
    -- repainted by the value ticks it always rode).
    local ZONE_IDENTITY = { name = true, levelname = true, namelevel = true, level = true }
    -- Value-class events: a static zone skips these and repaints on anything
    -- else (identity events, ForceUpdate, UnitChanged, PEW, nil = repaint all).
    -- UNIT_TARGET is here too: only the Name > Target zone (never static)
    -- reads the unit's target, so the name and level zones sit it out.
    local VALUE_EVENTS = {
        UNIT_HEALTH = true, UNIT_MAXHEALTH = true, UNIT_MAX_HEALTH_MODIFIERS_CHANGED = true,
        UNIT_POWER_UPDATE = true, UNIT_MAXPOWER = true, UNIT_DISPLAYPOWER = true,
        UNIT_ABSORB_AMOUNT_CHANGED = true, UNIT_HEAL_ABSORB_AMOUNT_CHANGED = true,
        UNIT_TARGET = true,
        Resettle = true, EUI_AbsorbEnd = true, EUI_AbsorbBelt = true,
    }

    --- Resolves a content key to (fmt, piecesArray, static) for a zone, or nil
    --- for "none"/unknown. nametotarget builds its settings-closure separator.
    function ns.ContentToZone(content, prefix, settings)
        if content == "nametotarget" then
            return "%s%s%s%s", { P.name, ns.MakeTgtSepPiece(prefix, settings), P.tgtcol, P.tgtname }
        end
        -- Target: the unit's target name alone, after the slot's Prefix
        -- (nil = "T:", "" = none) in the Indicator Color. The target's colour
        -- escape rides only while the slot is Class Colored; otherwise the
        -- name keeps the slot colour. Every piece is "" without a target.
        if content == "targetname" then
            local pieces = {}
            local pre = settings[prefix .. "TargetPrefix"]
            if type(pre) ~= "string" then pre = "T:" end
            if pre ~= "" then pieces[1] = ns.MakeTgtSepPiece(prefix, settings, pre .. " ") end
            if settings[prefix .. "ClassColor"] then pieces[#pieces + 1] = P.tgtcol end
            pieces[#pieces + 1] = P.tgtname
            return string.rep("%s", #pieces), pieces
        end
        local def = ZONE_STATIC[content]
        if not def then return nil end
        local pieces = { }
        local lvlCol = settings and settings.levelDifficultyColor
        for i = 2, #def do
            local key = def[i]
            if key == "level" and lvlCol then
                key = settings.levelDifficultyColorFriendly and "levelcolall" or "levelcol"
            end
            pieces[#pieces + 1] = P[key]
        end
        return def[1], pieces, ZONE_IDENTITY[content] or nil
    end

    -- Name Format (WoW Forever only): a slot set to First Name or Last Name
    -- (<prefix>NameFormat) gets short-name twins of its name pieces when the
    -- zone is applied, so the painter and every unset slot run as before.
    -- Level, separator and colour pieces stay; Name > Target shortens both
    -- names. ForeverShortName passes a secret name through whole and caches
    -- the short forms, so a zone repainted on every health tick builds no
    -- strings.
    if EllesmereUI.IS_FOREVER == true then
        local short, nameFn, tgtFn = EllesmereUI.ForeverShortName, P.name, P.tgtname
        local function Twins(mode)
            return {
                [nameFn] = function(u) return short(nameFn(u), mode) end,
                [tgtFn]  = function(u) return short(tgtFn(u), mode) end,
            }
        end
        local twinsByMode = { first = Twins("first"), last = Twins("last") }
        local base = ns.ContentToZone
        function ns.ContentToZone(content, prefix, settings)
            local fmt, pieces, static = base(content, prefix, settings)
            local twins = fmt and settings and twinsByMode[settings[prefix .. "NameFormat"]]
            if twins then
                for i = 1, #pieces do pieces[i] = twins[pieces[i]] or pieces[i] end
            end
            return fmt, pieces, static
        end
    end

    -- The text painter: renders every registered zone on the frame. Piece
    -- returns route through a scratch table + unpack (tables carry secrets
    -- fine; nothing inspects them). Identity-only zones (name/level) are
    -- skipped on value-class events: the nickname provider chain behind the
    -- name piece was running on every health tick.
    local scratch = {}
    local function PaintText(frame, unit, event)
        local zones = frame._euiTextZones
        if not zones then return end
        -- An empty token renders every zone blank, and a boss frame outlives the
        -- gap: the unit watch is a 0.2s poll, so the frame is still shown while
        -- its slot sits between units. Same probe the health painter pays.
        if not (unit and UnitExists(unit)) then return end
        -- Faction flip: slot colour is set by ApplyClassColor, never by the
        -- pieces below, so recolour first (the health bar recolours on this
        -- same event); the render then refreshes any target-colour piece.
        if event == "UNIT_FACTION" and ns.UF_RecolorTexts then
            ns.UF_RecolorTexts(frame, unit)
        end
        local valueOnly = event ~= nil and VALUE_EVENTS[event]
        for i = 1, #zones do
            local z = zones[i]
            if not (valueOnly and z.static) then
                local pieces = z.pieces
                local n = #pieces
                for k = 1, n do scratch[k] = pieces[k](unit) end
                z.fs:SetFormattedText(z.fmt, unpack(scratch, 1, n))
            end
        end
    end
    ns.UF_PaintText = PaintText
    ns.Engine.SetPainter("text", PaintText)

    -- Power-only text repaint for the power value pass: renders just the
    -- zones whose pieces read the unit's power (flagged when the zone is set).
    function ns.UF_PaintPowerText(frame, unit)
        local zones = frame._euiTextZones
        if not zones then return end
        for i = 1, #zones do
            local z = zones[i]
            if z.power then
                local pieces = z.pieces
                local n = #pieces
                for k = 1, n do scratch[k] = pieces[k](unit) end
                z.fs:SetFormattedText(z.fmt, unpack(scratch, 1, n))
            end
        end
    end

    -- True when a zone's pieces read power (the power text pieces), so the
    -- power value pass repaints it.
    local function ReadsPower(pieces)
        for i = 1, #pieces do
            local p = pieces[i]
            if p == P.perpp or p == P.curpp then return true end
        end
        return nil
    end

    --- Registers/updates one text zone on a frame: resolves the content key
    --- and stores the def the text painter renders. nil/none content removes
    --- the zone (the position code hides the fontstring separately, as
    --- before). Zones are keyed by fontstring; re-apply replaces in place.
    function ns.SetTextZone(frame, fs, content, prefix, settings)
        local zones = frame._euiTextZones
        if not zones then zones = {}; frame._euiTextZones = zones end
        local fmt, pieces, static
        if content then fmt, pieces, static = ns.ContentToZone(content, prefix, settings) end
        for i = #zones, 1, -1 do
            if zones[i].fs == fs then table.remove(zones, i) end
        end
        if fmt then
            zones[#zones + 1] = { fs = fs, fmt = fmt, pieces = pieces, static = static,
                                  power = ReadsPower(pieces) }
        else
            fs:SetText("")
        end
        -- A power text zone added or removed can switch the player's power
        -- value channel.
        if frame._euiBaseUnit == "player" then ns.UF_PowerValSync(frame) end
    end

    --- Raw-zone variant for callers that assemble their own format (the power
    --- percent text's curpp/perpp/smart combinations). nil fmt removes.
    function ns.SetTextZoneRaw(frame, fs, fmt, pieces)
        local zones = frame._euiTextZones
        if not zones then zones = {}; frame._euiTextZones = zones end
        for i = #zones, 1, -1 do
            if zones[i].fs == fs then table.remove(zones, i) end
        end
        if fmt then
            zones[#zones + 1] = { fs = fs, fmt = fmt, pieces = pieces, power = ReadsPower(pieces) }
        else
            fs:SetText("")
        end
        if frame._euiBaseUnit == "player" then ns.UF_PowerValSync(frame) end
    end
end

local optionsFrame
local optionsCategoryID

-- Unit token -> its settings key in the profile. The settings table itself is
-- read live on every call: a profile switch, import or reset (or a layer
-- paint) can replace db.profile or its unit tables between frame reloads.
local unitSettingsKey = {
    player = "player", target = "target", targettarget = "targettarget",
    pet = "pet", focus = "focus", focustarget = "focustarget",
    boss1 = "boss", boss2 = "boss", boss3 = "boss", boss4 = "boss", boss5 = "boss",
}
local function GetSettingsForUnit(unit)
    local p = db.profile
    local k = unitSettingsKey[unit]
    return (k and p[k]) or p.player
end

-- Per-unit frame source resolver. Returns "eui" (spawn skinned frame, default),
-- "blizzard" (don't spawn, leave Blizzard's default in place), or "hidden" (don't
-- spawn, actively disable Blizzard's too). "hidden" has highest precedence so a
-- disabled frame (enabledFrames[unit]==false, the "Enable X Frame" toggles) keeps
-- meaning "no frame at all". Visibility "never" is NOT one of these: it hides our
-- frame at runtime and the frame stays built, so a Spec Override can lift it again
-- without a /reload.

--- The Visibility mode actually in force for a settings table. An applied override
--- REPLACES the whole shared setting, "never" included, so every reader that acts on
--- "never" alone resolves it here instead of off the stored scalar. On ns for the
--- 200-locals cap.
function ns.VisEffective(s)
    if not s then return nil end
    return (EllesmereUI.VisOverrideValue(s)) or s.barVisibility
end

--- True when the unit has no EllesmereUI frame at all -- the enabledFrames flag, which
--- only the "Enable X Frame" toggles write now that Visibility no longer touches it.
--- On ns for the 200-locals cap.
function ns.VisUnitDisabled(profile, unitKey)
    local ef = profile and profile.enabledFrames
    return (ef and ef[unitKey] == false) or false
end

function ns.GetUnitFrameSource(unit)
    if not db or not db.profile then return "eui" end
    if ns.VisUnitDisabled(db.profile, unit) then return "hidden" end
    local fs = db.profile.frameSource and db.profile.frameSource[unit]
    if fs == "blizzard" then
        -- Visibility "never" over Blizzard's frame: we spawn nothing of our own to
        -- hide, so suppressing Blizzard's is the only way to honor it.
        if ns.VisEffective(db.profile[unit]) == "never" then return "hidden" end
        -- ToT/focus-target have no standalone Blizzard frame (native one is a child
        -- of TargetFrame/FocusFrame, lives only while that parent does), so
        -- "blizzard" is honored for them ONLY when the parent is itself on
        -- Blizzard's frame; else fall back to the EllesmereUI frame.
        if unit == "targettarget" then
            return ns.GetUnitFrameSource("target") == "blizzard" and "blizzard" or "eui"
        elseif unit == "focustarget" then
            return ns.GetUnitFrameSource("focus") == "blizzard" and "blizzard" or "eui"
        end
        return "blizzard"
    end
    return "eui"
end

--- True when this profile has Unit Frames re-host Blizzard's class resource frame
--- (the "Blizzard" class resource style on the EllesmereUI player frame). Resource
--- Bars' Blizzard Class Resource Art reads it through the module registry and never
--- claims that frame while it holds: one owner, and Unit Frames wins a tie from an
--- import or spec override. Config plus the runtime mirror (ns._ufBlizzCPHeld), so
--- it answers before InitializeFrames and while a change waits to apply.
--- On ns for the 200-locals cap.
function ns.UF_OwnsBlizzClassPower()
    if EllesmereUI.IS_FOREVER == true then return false end
    -- Held right now (runtime), even while the config says otherwise: a style or
    -- source change not applied yet (combat, a pending reload) keeps it ours.
    if ns._ufBlizzCPHeld then return true end
    local p = db and db.profile
    if not (p and p.player and p.player.classPowerStyle == "blizzard") then return false end
    return ns.GetUnitFrameSource("player") == "eui"
end

-- Write a unit's frame source, keeping the legacy enabledFrames flag in sync so
-- existing readers stay correct (and so the cog is the way back for a frame an old
-- profile left disabled). Only takes full effect after a UI reload -- the spawn
-- permanently disables the Blizzard frame, and secure frames can't be created or
-- torn down in combat -- so callers should also prompt a reload.
function ns.SetUnitFrameSource(unit, source)
    if not db or not db.profile then return end
    db.profile.frameSource = db.profile.frameSource or {}
    db.profile.frameSource[unit] = source
    db.profile.enabledFrames[unit] = (source ~= "hidden")
end

-- Cast-bar icon "part of the bar" resolver. True = icon counts inside the cast bar's
-- width (icon inside footprint, fill inset to its right, like Resource Bars). False =
-- icon outside the width. Requires the icon shown; a hidden icon is never "in width".
local function CastIconInWidth(unit, s)
    s = s or GetSettingsForUnit(unit)
    if not s then return true end
    -- The stock styles count a shown icon as part of the bar whatever the
    -- toggle says: their frame art wraps bar and icon together, and a width
    -- match lines up with that footprint.
    if ns.UF_Blizz() then
        if unit == "player" then return s.showPlayerCastIcon ~= false end
        return s.showCastIcon ~= false
    end
    -- An icon moved onto the portrait (Show Icon on Portrait) is never in width.
    if ns.UF_CastIconOnPortrait(unit, s) then return false end
    if unit == "player" then
        return s.showPlayerCastIcon ~= false and s.playerCastbarIconInWidth ~= false
    end
    return s.showCastIcon ~= false and s.castbarIconInWidth ~= false
end
-- Shared with the options preview, so it lays the icon out the same way.
ns.UF_CastIconInWidth = CastIconInWidth

-- Whether the cast spell icon is shown at all. Independent of "part of the
-- bar" (CastIconInWidth folds this in already for its own purposes, but
-- ns.UF_ApplyCastIconBorder needs the shown state on its own: a hidden icon
-- shares no edge with the bar).
local function CastIconShown(unit, s)
    s = s or GetSettingsForUnit(unit)
    if not s then return true end
    if unit == "player" then
        return s.showPlayerCastIcon ~= false
    end
    return s.showCastIcon ~= false
end

-- Show Icon on Portrait (player / target / focus, opt-in): true while the
-- cast icon sits over the unit's portrait instead of beside the bar. Needs
-- the icon shown and a visible portrait (Portrait Mode and Art Style not
-- None); the stock styles own the icon. Settings only, so the options preview
-- and the cast bar's size-match pad read the same answer. On ns (local cap).
function ns.UF_CastIconOnPortrait(unit, s)
    if not s then return false end
    local key = (unit == "player") and "playerCastbarIconOnPortrait" or "castbarIconOnPortrait"
    if s[key] ~= true or ns.UF_Blizz() or not CastIconShown(unit, s) then return false end
    local p = db.profile
    if (s.portraitStyle or p.portraitStyle or "attached") == "none" or s.showPortrait == false then return false end
    return (s.portraitMode or p.portraitMode or "2d") ~= "none"
end

-- Whether the cast spell icon sits on the RIGHT of the bar instead of the
-- default left. Independent of "part of the bar"; defaults off (left).
local function CastIconOnRight(unit, s)
    s = s or GetSettingsForUnit(unit)
    if not s then return false end
    if unit == "player" then
        return s.playerCastbarIconRight == true
    end
    return s.castbarIconRight == true
end

-- Additive X/Y nudge for the cast spell icon. Applies to the icon frame's anchors
-- only -- the bar fill and footprint never move.
local function CastIconOffsets(unit, s)
    s = s or GetSettingsForUnit(unit)
    if not s then return 0, 0 end
    if unit == "player" then
        return s.playerCastIconOffsetX or 0, s.playerCastIconOffsetY or 0
    end
    return s.castIconOffsetX or 0, s.castIconOffsetY or 0
end

-- Border Wraps Icon (s.castBorderWrapIcon, opt-in): the Custom Border Style
-- takes in an integrated icon, only while it sits flush (no offset); else
-- the border wraps the bar alone. Settings only, so the border, the shared
-- edge pass and the size-match pad read one answer. On ns (local cap).
function ns.UF_CastBorderWrapsIcon(unit, s)
    if not (s and s.castBorderCustom == true and s.castBorderWrapIcon == true) then return false end
    if not CastIconInWidth(unit, s) then return false end
    local offX, offY = CastIconOffsets(unit, s)
    return offX == 0 and offY == 0
end

-- Vertical Separator: the divider draws as Solid's flat line (also with
-- Custom Border Style off) or in a style's own divider art; a textured style
-- without that art, or a Border Size of 0, draws none. Shared with the
-- options row's disabled state. On ns (local cap).
function ns.UF_CastIconSeamOK(s)
    if not (s and s.castBorderCustom == true) then return true end
    if (s.castBorderSize or 1) <= 0 then return false end
    local tex = s.castBorderStyle or "solid"
    return tex == "solid" or tex == "" or EllesmereUI.GetBorderCompanion(tex, "sepV") ~= nil
end

-- Classic WoW UI: the settings key holding a cast bar's frame size (its
-- Border Size percentage; player keys carry the player prefix). On ns for
-- the local cap.
function ns.UF_CastClassicKey(unit)
    return unit == "player" and "playerCastbarStockBorderScale" or "castbarStockBorderScale"
end

-- Anchor the cast spell icon and inset the fill based on whether the icon is part of
-- the bar width. inWidth=true -> icon at the bar's edge, fill inset by icon width
-- (castbarBg becomes the full footprint, so unlock mode/width matching count the icon
-- for free). inWidth=false -> icon hangs outside the bar width.
--
-- Icon HEIGHT anchors to the bar bg's top AND bottom so it always equals the bar
-- height: a live bg:GetHeight() read is unreliable during creation/login (bg not yet
-- at final height/scale). iconH is the configured cast bar height (castbarHeight/
-- playerCastbarHeight), used only for the square WIDTH and matching fill inset so
-- those stay deterministic; falls back to bg:GetHeight().
--
-- portraitBd: the portrait backdrop the icon sits on (Show Icon on Portrait,
-- laid out by ns.UF_CastIconPortrait, which the callers run as this argument),
-- else nil. With it the bar takes the whole holder and no seam is shared.
local function LayoutCastbarIcon(castbar, inWidth, iconH, onRight, offX, offY, iconShown, framePct, portraitBd)
    if not castbar then return end
    local bg = castbar:GetParent()
    if not bg then return end
    -- Classic WoW UI frame size, read by the style's cast pass.
    castbar._classicPct = framePct
    -- Callers pass the configured height: a holder on the Blizzard Style
    -- aura block reads back a secret rect, size included.
    local side = iconH or bg:GetHeight()
    if issecretvalue(side) then return end
    local iconFrame = castbar._iconFrame
    offX, offY = offX or 0, offY or 0
    -- The style's own icon pass (ns.UF_BlizzCastIcon) re-lays the icon from
    -- these after the stock chrome is on.
    castbar._icoInWidth, castbar._icoOnRight, castbar._icoSide = inWidth, onRight, side
    castbar._icoOffX, castbar._icoOffY, castbar._icoShown = offX, offY, iconShown
    if iconFrame and not portraitBd then
        iconFrame:ClearAllPoints()
        if inWidth then
            -- Icon inside the footprint, flush with the chosen edge.
            if onRight then
                PP.Point(iconFrame, "TOPRIGHT", bg, "TOPRIGHT", offX, offY)
                PP.Point(iconFrame, "BOTTOMRIGHT", bg, "BOTTOMRIGHT", offX, offY)
            else
                PP.Point(iconFrame, "TOPLEFT", bg, "TOPLEFT", offX, offY)
                PP.Point(iconFrame, "BOTTOMLEFT", bg, "BOTTOMLEFT", offX, offY)
            end
        else
            -- Icon hangs outside the bar, off the chosen edge.
            if onRight then
                PP.Point(iconFrame, "TOPLEFT", bg, "TOPRIGHT", offX, offY)
                PP.Point(iconFrame, "BOTTOMLEFT", bg, "BOTTOMRIGHT", offX, offY)
            else
                PP.Point(iconFrame, "TOPRIGHT", bg, "TOPLEFT", offX, offY)
                PP.Point(iconFrame, "BOTTOMRIGHT", bg, "BOTTOMLEFT", offX, offY)
            end
        end
        iconFrame:SetWidth(side)
    end
    castbar:ClearAllPoints()
    if portraitBd then
        -- The icon sits on the portrait: the bar takes the whole footprint.
        PP.Point(castbar, "TOPLEFT", bg, "TOPLEFT", 0, 0)
        PP.Point(castbar, "BOTTOMRIGHT", bg, "BOTTOMRIGHT", 0, 0)
    elseif inWidth and onRight then
        -- Bar occupies the left of the footprint; icon takes the right edge.
        PP.Point(castbar, "TOPLEFT", bg, "TOPLEFT", 0, 0)
        PP.Point(castbar, "BOTTOMRIGHT", bg, "BOTTOMRIGHT", -side, 0)
    else
        PP.Point(castbar, "TOPLEFT", bg, "TOPLEFT", inWidth and side or 0, 0)
        PP.Point(castbar, "BOTTOMRIGHT", bg, "BOTTOMRIGHT", 0, 0)
    end
end

-- Cast bar Custom Border Style (s.castBorderCustom, opt-in per unit; boss1-5
-- share one table). Off: the 1px black border CreateCastBar drew on the bar
-- stays as it is; only the icon decoration pass runs and nothing is built
-- unless one of its options is enabled.
-- On: that border hides and the chosen style draws on castbar._cbBorder, our
-- own child frame of the bar built on first enable, so it shows and hides with
-- the bar as the old border did. It wraps the bar alone, or icon and bar
-- together under Border Wraps Icon (ns.UF_CastBorderWrapsIcon). It sits under
-- the cast text overlay; Show Behind drops it under the bar's holder.
-- Settings passes only (creation and ReloadFrames, after LayoutCastbarIcon).
-- An exact size re-applies on a UI scale change through ApplyBorderStyle's
-- own edgePx registration. Stands down under a stock style: stock = nil reads
-- the session's latched style; the options preview (which shares this)
-- passes its own and preview = true. On ns: the local cap.
function ns.UF_ApplyCastBorder(castbar, s, stock, unit, icon, preview)
    if not castbar then return end
    if stock == nil then stock = ns.UF_Blizz() end
    local host = castbar._cbBorder
    if stock or not (s and s.castBorderCustom == true) then
        if castbar._cbHost then
            castbar._cbHost = nil
            EllesmereUI.HideBorderStyle(host)
            host:Hide()
            -- The bar's own border back (the stock chrome keeps it hidden).
            if not stock then PP.ShowBorder(castbar) end
        end
        ns.UF_ApplyCastIconBorder(castbar, s, stock, unit, icon, preview)
        return
    end
    if not host then
        host = CreateFrame("Frame", nil, castbar)
        castbar._cbBorder = host
    end
    host:ClearAllPoints()
    if ns.UF_CastBorderWrapsIcon(unit, s) then
        -- The fill gives up the icon's width (the configured cast bar height,
        -- as LayoutCastbarIcon insets it): reach past the fill by that much on
        -- the icon's side. Anchored to the fill so the options preview uses
        -- the same rule.
        local side = (unit == "player") and (s.playerCastbarHeight or 14) or (s.castbarHeight or 14)
        local onRight = CastIconOnRight(unit, s)
        PP.Point(host, "TOPLEFT", castbar, "TOPLEFT", onRight and 0 or -side, 0)
        PP.Point(host, "BOTTOMRIGHT", castbar, "BOTTOMRIGHT", onRight and side or 0, 0)
    else
        host:SetAllPoints(castbar)
    end
    castbar._cbHost = host
    PP.HideBorder(castbar)
    -- Levelled before the apply: a textured style's backdrop takes the host's.
    if s.castBorderBehind then
        host:SetFrameLevel(math.max(0, (castbar:GetParent() or castbar):GetFrameLevel() - 1))
    else
        -- Over the fill, shield and kick marker (bar +2), under the text overlay.
        local lvl = castbar:GetFrameLevel() + 3
        local ovr = castbar.Text and castbar.Text:GetParent()
        if ovr and ovr ~= castbar then lvl = math.min(lvl, ovr:GetFrameLevel() - 1) end
        host:SetFrameLevel(lvl)
    end
    local tex = s.castBorderStyle or "solid"
    local size = s.castBorderSize or 1
    local c = s.castBorderColor
    local px = EllesmereUI.BorderPx(s.castBorderSizePx, size, tex)
    EllesmereUI.ApplyBorderStyle(host, size, c and c.r or 0, c and c.g or 0, c and c.b or 0,
        s.castBorderAlpha or 1, tex, s.castBorderOffsetX, s.castBorderOffsetY,
        s.castBorderShiftX, s.castBorderShiftY, "unitframes", size, nil, px)
    castbar._cbSolid = (tex == "solid" or tex == "") and size > 0
    castbar._cbSize = px or size
    ns.UF_ApplyCastIconBorder(castbar, s, stock, unit, icon, preview)
end

-- Cast icon decoration, shared by live frames and the options preview. New
-- resources are built only on opt-in, during the existing settings pass.
-- preview = the options preview's bar: its divider is never registered for
-- the UI-scale re-layout (the preview re-lays it on every update).
function ns.UF_ApplyCastIconBorder(castbar, s, stock, unit, icon, preview)
    icon = icon or castbar._iconFrame
    if not icon then return end
    local shown = CastIconShown(unit, s)
    local portrait = ns.UF_CastIconOnPortrait(unit, s)
    local inWidth = CastIconInWidth(unit, s)
    local onRight = CastIconOnRight(unit, s)
    local offX, offY = CastIconOffsets(unit, s)
    local custom = s and s.castBorderCustom == true
    local styled = not stock and shown and not portrait and s and s.castIconBorder == true
    local host = icon._castBorder
    local tex = custom and (s.castBorderStyle or "solid") or "solid"
    local size = custom and (s.castBorderSize or 1) or 1
    local c = custom and s.castBorderColor
    local alpha = custom and (s.castBorderAlpha or 1) or 1
    local px = custom and EllesmereUI.BorderPx(s.castBorderSizePx, size, tex) or nil
    if styled then
        if not host then
            host = CreateFrame("Frame", nil, icon)
            host:SetAllPoints(icon)
            icon._castBorder = host
        end
        host:SetFrameLevel(custom and s.castBorderBehind and math.max(0, icon:GetFrameLevel() - 1) or icon:GetFrameLevel() + 1)
        PP.HideBorder(icon)
        EllesmereUI.ApplyBorderStyle(host, size, c and c.r or 0, c and c.g or 0, c and c.b or 0,
            alpha, tex, custom and s.castBorderOffsetX or nil, custom and s.castBorderOffsetY or nil,
            custom and s.castBorderShiftX or nil, custom and s.castBorderShiftY or nil, "unitframes", size, nil, px)
    elseif host then
        EllesmereUI.HideBorderStyle(host)
        host:Hide()
        if not stock and not portrait then PP.ShowBorder(icon) end
    end

    -- Icon and bar each draw a full border (the bar's own 1px one, or a custom
    -- Solid one at its size): flush, both would draw the shared edge, so each
    -- drops its facing side. Only while the icon is shown beside the bar with
    -- no offset and no Icon Border of its own; a textured or hidden custom
    -- border shares none. Under Border Wraps Icon the custom border is the
    -- outside edge of both: it keeps every side and the icon drops its facing
    -- one.
    if not stock then
        local iconEdges = PP.GetBorders(icon)
        local barFrame = castbar._cbHost or castbar
        local barEdges = PP.GetBorders(barFrame)
        local barDrawn = barEdges and (barFrame == castbar or castbar._cbSolid)
        local share = shown and not portrait and offX == 0 and offY == 0 and not styled
        local outer = castbar._cbHost and ns.UF_CastBorderWrapsIcon(unit, s)
        if iconEdges then
            local hide = share and (barDrawn or outer)
            iconEdges._hideLeft = hide and onRight or nil
            iconEdges._hideRight = hide and not onRight or nil
            PP.SetBorderSize(icon, 1)
        end
        if barEdges then
            local hide = share and barDrawn and not outer
            barEdges._hideLeft = hide and not onRight or nil
            barEdges._hideRight = hide and onRight or nil
            if barDrawn then PP.SetBorderSize(barFrame, barFrame == castbar and 1 or castbar._cbSize) end
        end
    end

    local seam = castbar._iconSeam
    if not (s and s.castIconSeparator == true and not stock and shown and inWidth and not portrait
            and ns.UF_CastIconSeamOK(s)) then
        if seam then
            seam:Hide()
            EllesmereUI.RegisterPxReapply(seam, nil)
        end
        return
    end
    if not seam then
        seam = CreateFrame("Frame", nil, castbar)
        seam:SetAllPoints(castbar)
        seam._tex = seam:CreateTexture(nil, "OVERLAY")
        castbar._iconSeam = seam
    end
    -- Above the cast border, including Solid's child at border level +1.
    local borderFrame = castbar._cbHost or castbar
    seam:SetFrameLevel(math.max(castbar:GetFrameLevel(), borderFrame:GetFrameLevel()) + 2)
    seam._key, seam._size, seam._px, seam._right = tex, size, px, onRight
    seam._path = EllesmereUI.GetBorderCompanion(tex, "sepV")
    seam._tex:SetVertexColor(c and c.r or 0, c and c.g or 0, c and c.b or 0, alpha)
    ns.UF_LayoutCastIconSeam(seam)
    seam:Show()
    EllesmereUI.RegisterPxReapply(seam, (not preview) and ns.UF_LayoutCastIconSeam or nil)
end

-- Lays the divider from the values the pass above stamped (also the UI-scale
-- re-layout). A style's divider art goes through the shared placement, its
-- lead hanging past the bar's edge over the icon; Solid draws a flat line on
-- the bar's edge at the border's exact size.
function ns.UF_LayoutCastIconSeam(seam)
    local t = seam._tex
    local es = seam:GetEffectiveScale()
    if seam._path then
        EllesmereUI.PlaceBorderDividerV(t, seam, seam._right, false, seam._key, seam._size, seam._px, es)
        return
    end
    local onePixel = es > 0 and PP.perfect / es or PP.mult
    t:SetColorTexture(1, 1, 1, 1)
    t:SetTexCoord(0, 1, 0, 1)
    t:ClearAllPoints()
    if seam._right then
        t:SetPoint("TOPRIGHT", seam, "TOPRIGHT", 0, 0)
        t:SetPoint("BOTTOMRIGHT", seam, "BOTTOMRIGHT", 0, 0)
    else
        t:SetPoint("TOPLEFT", seam, "TOPLEFT", 0, 0)
        t:SetPoint("BOTTOMLEFT", seam, "BOTTOMLEFT", 0, 0)
    end
    t:SetWidth(math.max(1, math.floor((seam._px or seam._size) + 0.5)) * onePixel)
    t:Show()
end

-- Size matching: the width and height a Custom Border Style cast border
-- draws OUTSIDE the cast bar holder (the unlock element's frame), from the
-- same arguments ns.UF_ApplyCastBorder passes; nil while the opt-in is off,
-- for Solid and under the stock styles, so the pad stays exactly as before.
-- The border wraps the bar, which an in-width icon insets inside the holder
-- by the icon's width (the configured cast bar height): that side's reach
-- shrinks by it. Under Border Wraps Icon (ns.UF_CastBorderWrapsIcon) it
-- wraps the whole holder instead. Each side clamps at 0 before the sum.
-- Settings only.
function ns.UF_CastBorderPad(unit, s)
    if not (s and s.castBorderCustom == true) or ns.UF_Blizz() then return nil end
    local tex = s.castBorderStyle or "solid"
    local size = s.castBorderSize or 1
    local l, r, t, b = EllesmereUI.BorderReach(size, tex, s.castBorderOffsetX, s.castBorderOffsetY,
        s.castBorderShiftX, s.castBorderShiftY, "unitframes", size,
        EllesmereUI.BorderPx(s.castBorderSizePx, size, tex), nil, s.castBorderAlpha or 1)
    if not l then return nil end
    if CastIconInWidth(unit, s) and not ns.UF_CastBorderWrapsIcon(unit, s) then
        local iw = (unit == "player") and (s.playerCastbarHeight or 14) or (s.castbarHeight or 14)
        if CastIconOnRight(unit, s) then r = r - iw else l = l - iw end
    end
    local w = (l > 0 and l or 0) + (r > 0 and r or 0)
    local h = (t > 0 and t or 0) + (b > 0 and b or 0)
    if w <= 0 and h <= 0 then return nil end
    return w, h
end

-- Show Icon on Portrait: lays the cast icon over the portrait backdrop bd, or
-- (bd nil) hands it back to the bar layout. ico = the cast icon frame, tex =
-- its texture, s = the unit's settings. Our own frames only (the options
-- preview shares this with its own icon and portrait). The icon's 1px border
-- and black plate hide and its texture fills the frame; on a shaped detached
-- portrait it is clipped by the icon frame's OWN mask (built on first use)
-- carrying the portrait's shape art, since a mask owned by the portrait's
-- frame tree is not relied on across trees. That mask sits inset so its
-- opening stops at the shape border's inner edge, which keeps the ring in
-- view round the icon. Levelled over the backdrop and its 3D model.
-- ico._pbd = the backdrop it sits on.
function ns.UF_CastIconPortraitLayout(ico, tex, bd, s)
    if not bd then
        if not ico._pbd then return end
        ico._pbd = nil
        PP.ShowBorder(ico)
        if ico._bg then ico._bg:Show() end
        if tex then
            if ico._pMaskOn then tex:RemoveMaskTexture(ico._pMask); ico._pMaskOn = nil end
            tex:ClearAllPoints()
            tex:SetPoint("TOPLEFT", ico, "TOPLEFT", 1, -1)
            tex:SetPoint("BOTTOMRIGHT", ico, "BOTTOMRIGHT", -1, 1)
        end
        local holder = ico:GetParent()
        if holder then
            ico:SetFrameStrata(holder:GetFrameStrata())
            ico:SetFrameLevel(holder:GetFrameLevel() + 1)
        end
        return
    end
    ico._pbd = bd
    PP.HideBorder(ico)
    if ico._bg then ico._bg:Hide() end
    ico:ClearAllPoints()
    ico:SetAllPoints(bd)
    -- The portrait's strata, not the raised cast bar's: the frame border
    -- (frame +10) still closes an attached portrait's edges over the icon.
    ico:SetFrameStrata(bd:GetFrameStrata())
    ico:SetFrameLevel(bd:GetFrameLevel() + 2)
    if not tex then return end
    tex:ClearAllPoints()
    tex:SetAllPoints(ico)
    -- A detached portrait's shape; attached and shape-less ones are square.
    local shape = ((s.portraitStyle or db.profile.portraitStyle or "attached") == "detached")
        and (s.detachedPortraitShape or "portrait") or "none"
    local maskPath = shape ~= "none" and ns.PORTRAIT_MASKS[shape]
    if maskPath then
        local m = ico._pMask
        if not m then
            m = ico:CreateMaskTexture()
            ico._pMask = m
        end
        -- The backdrop mask's own inset, widened until the icon's opening meets
        -- the shape border's inner edge (all in backdrop px, W wide): the ring
        -- art's solid band ends at MASK_INSETS texels of its 128 (an unmasked
        -- ring, ns.UF_UNMASKED_RING: 9 texels into its inset rect), the ring
        -- rect grows by 7 - Size per side, and the mask's opening lies about
        -- 12 of its 128 texels in.
        local band = s.detachedPortraitBorderSize or 7
        local inset = (band >= 1) and 1 or 0
        if band >= 1 and ns.PORTRAIT_BORDERS[shape] then
            local W = bd:GetWidth()
            if W < 1 then W = 46 end
            local exp = 7 - band
            local unmasked = ns.UF_UNMASKED_RING[shape]
            local inner
            if unmasked then
                local ri = unmasked - exp
                inner = ri + 9 / 128 * (W - 2 * ri)
            else
                inner = -exp + (ns.MASK_INSETS[shape] or 17) / 128 * (W + 2 * exp)
            end
            local need = (inner - 12 / 128 * W) * 128 / 104
            if need > inset then inset = need end
        end
        m:ClearAllPoints()
        m:SetPoint("TOPLEFT", bd, "TOPLEFT", inset, -inset)
        m:SetPoint("BOTTOMRIGHT", bd, "BOTTOMRIGHT", -inset, inset)
        if m._path ~= maskPath then
            m:SetTexture(maskPath, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
            m._path = maskPath
        end
        m:Show()
        if not ico._pMaskOn then
            tex:AddMaskTexture(m)
            ico._pMaskOn = true
        end
    elseif ico._pMaskOn then
        tex:RemoveMaskTexture(ico._pMask)
        ico._pMaskOn = nil
    end
end

-- The live cast bar's side of Show Icon on Portrait, run as LayoutCastbarIcon's
-- portraitBd argument: returns the backdrop the icon now sits on, or nil. One
-- settings test while off; the layout runs only while on or on the pass that
-- turns it off.
function ns.UF_CastIconPortrait(castbar, frame, s, unit)
    local ico = castbar and castbar._iconFrame
    if not ico then return nil end
    local pt = frame and frame.Portrait
    local bd = pt and ns.UF_CastIconOnPortrait(unit, s) and pt.backdrop or nil
    if bd or ico._pbd then ns.UF_CastIconPortraitLayout(ico, castbar.Icon, bd, s) end
    return bd
end

local UF_ICONS_PATH = "Interface\\AddOns\\EllesmereUI\\media\\icons\\"
local CLASS_FULL_SPRITE_BASE = UF_ICONS_PATH .. "class-full\\"
local CLASS_FULL_COORDS = EllesmereUI.CLASS_ICON_SPRITE_COORDS

-- Apply a class icon from the sprite sheet. mirror = true swaps the cell's
-- left/right coords (Mirror Portrait); the coords are written on every paint.
local function ApplyClassIconTexture(tex, classToken, style, mirror)
    local coords = CLASS_FULL_COORDS[classToken]
    if not coords then return false end
    tex:SetTexture(CLASS_FULL_SPRITE_BASE .. style .. ".tga")
    if mirror then
        tex:SetTexCoord(coords[2], coords[1], coords[3], coords[4])
    else
        tex:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
    end
    return true
end

-- Class art for a player unit. A readable token paints the pack's sprite cell.
-- A secret one (identity-restricted players, e.g. enemies in instanced PvP)
-- cannot key the sprite table, so the stock class atlas carries it: a secret
-- string concatenates to a secret string and SetAtlas takes secrets from addon
-- code, so the class is never read in Lua. SetAtlas keeps the texture's
-- coords (a sprite cell or the question-mark crop from an earlier paint) and
-- applies them inside the atlas, so they reset first; the next readable paint
-- re-asserts file and coords. Returns false when there is no class to paint.
-- mirror = true (Mirror Portrait) flips both lanes: the reset before SetAtlas
-- is the flipped one, and the sprite cell's left/right coords swap.
function ns.UF_PaintClassIcon(tex, unit, style, mirror)
    local _, ct = UnitClass(unit)
    if issecretvalue(ct) then
        if mirror then
            tex:SetTexCoord(1, 0, 0, 1)
        else
            tex:SetTexCoord(0, 1, 0, 1)
        end
        tex:SetAtlas("classicon-" .. ct)
        return true
    end
    if not ct then return false end
    return ApplyClassIconTexture(tex, ct, style, mirror)
end


-- What a non-player shows on a Class art frame: "2d", "none" or "3d". s = the
-- frame's own settings (its base unit's table). "2d" unless the frame opted in
-- (portraitNonPlayerOn), and under a stock style (it owns the portrait). "3d"
-- (a real mode swap, SwapPortraitMode) also falls back to "2d" while the
-- portrait is hidden (no model built), has a masked Detached shape (a model
-- cannot be masked) or sits on a mini frame (its fade never reaches a model).
function ns.UF_ClassFallback(s)
    if not (s and s.portraitNonPlayerOn) or ns.UF_Blizz() then return "2d" end
    local v = s.portraitNonPlayer or "2d"
    if v == "3d" then
        local style = s.portraitStyle
        local p = db.profile
        if s.showPortrait == false or style == "none"
            or (style == "detached" and (s.detachedPortraitShape or "portrait") ~= "none")
            or s == p.targettarget or s == p.focustarget or s == p.pet then
            return "2d"
        end
    end
    return v
end

-- Class art frames only (the class object, or a model shown as the fallback):
-- true when the live unit needs the other object, plus the resolved fallback
-- for a non-player. A model on a frame not set to Class is a genuine 3D
-- portrait. No unit, no swap.
function ns.UF_ClassFallbackNeedsSwap(frame, unit)
    local p = frame.Portrait
    if not (unit and p and (p.isClass or p.is2D == false)) then return false end
    local uKey = UnitToSettingsKey(frame._euiBaseUnit or unit)
    local s = uKey and db.profile[uKey]
    if p.isClass then
        -- Not opted in: the fallback is "2d" and the class object stays.
        if not (s and s.portraitNonPlayerOn) then return false, "2d" end
    elseif ((s and s.portraitMode) or db.profile.portraitMode or "2d") ~= "class" then
        return false
    end
    if not UnitExists(unit) then return false end
    local fb = not UnitIsPlayer(unit) and ns.UF_ClassFallback(s) or nil
    if p.isClass then return fb == "3d", fb end
    return fb ~= "3d", fb
end

-- Mirror angles (degrees) for playable-race models, whether used by a player or NPC.
-- Non-playable NPC models are excluded.
-- Unlisted/missing/restricted IDs stay normal; never infer facing from unit type.
do
    local mirrorAngles -- Built only when portrait mirroring first needs a model ID.
    local function GetMirrorAngle(id)
        if issecretvalue(id) or type(id) ~= "number" or id <= 0 then return end
        if not mirrorAngles then
            mirrorAngles = {
                -- Playable-race model IDs.
                [118355] = 291, [118135] = 291, [1838560] = 291, [1838562] = 291, [878772] = 291,
                [950080] = 291, [116921] = 291, [1100258] = 291, [1839709] = 291, [117170] = 291,
                [1100087] = 291, [1853408] = 291, [1890763] = 291, [1892825] = 291, [1890765] = 291,
                [1892543] = 291, [117437] = 291, [1022598] = 291, [1822372] = 291, [117721] = 291,
                [1005887] = 291, [1839253] = 291, [119063] = 291, [940356] = 291, [1838564] = 291,
                [119159] = 291, [900914] = 291, [1838566] = 291, [119369] = 291, [1838568] = 291,
                [119376] = 291, [1838570] = 291, [1630402] = 291, [1859379] = 291, [1630218] = 291,
                [1858265] = 291, [119563] = 291, [1000764] = 291, [1838572] = 291, [1842700] = 291,
                [119940] = 291, [1011653] = 291, [1838385] = 291, [1886724] = 291, [1721003] = 291,
                [1593999] = 291, [1825438] = 291, [1620605] = 291, [1839042] = 291, [2564806] = 291,
                [2622502] = 291, [1810676] = 291, [1858099] = 291, [1814471] = 291, [1857801] = 291,
                [120590] = 291, [921844] = 291, [1838574] = 291, [120791] = 291, [974343] = 291,
                [1838576] = 291, [121087] = 291, [949470] = 291, [1838580] = 291, [121287] = 291,
                [917116] = 291, [1838578] = 291, [1968587] = 291, [1968838] = 291, [1087591] = 291,
                [1088030] = 291, [589715] = 291, [1853610] = 291, [535052] = 291, [1853956] = 291,
                [121608] = 291, [997378] = 291, [1838582] = 291, [121768] = 291, [959310] = 291,
                [1838584] = 291, [121961] = 291, [986648] = 291, [1839008] = 291, [122055] = 291,
                [968705] = 291, [1838586] = 291, [122414] = 291, [1018060] = 291, [1838588] = 291,
                [122560] = 291, [1022938] = 291, [1838590] = 291, [1733758] = 291, [1859345] = 291,
                [1734034] = 291, [1858367] = 291, [1890759] = 291, [1890761] = 291, [307453] = 291,
                [1838201] = 291, [307454] = 291, [1838592] = 291, [1662187] = 291, [1894572] = 291,
                [1630447] = 291, [1900779] = 291, [4395382] = 291, [4207724] = 291, [4220448] = 291,
                [7478494] = 291, [7478487] = 291,
            }
        end
        return mirrorAngles[id]
    end

    -- 2D textures have no model ID: the portrait's hidden, lazy 3D frame loads
    -- the unit once per GUID and the answer is cached (ns.UF_ForgetPortraitMirror
    -- drops it on UNIT_MODEL_CHANGED, so forms and transforms check again). A
    -- model whose file is not resolved yet stays loaded until OnModelLoaded, then
    -- onReady(guid) lets the portrait repaint its flip. Secret GUIDs are not
    -- cached. The model is our own frame, so its fields are ours to use.
    local verdict, verdictCount = {}, 0
    local function Release(model)
        model._mirPending, model._mirReady = nil, nil
        -- Shown = a 3D portrait now owns the model: leave it loaded.
        if not model:IsShown() then model:ClearModel() end
        model:SetKeepModelOnHide(false)
    end
    local function Store(key, v)
        if verdict[key] == nil then
            if verdictCount >= 500 then wipe(verdict); verdictCount = 0 end
            verdictCount = verdictCount + 1
        end
        verdict[key] = v
    end
    local function Resolve(model, key)
        local v = GetMirrorAngle(model:GetModelFileID()) ~= nil
        local ready = model._mirReady
        Release(model)
        Store(key, v)
        if ready then ready(key) end
        return v
    end
    local function OnModelLoaded(model)
        local key = model._mirPending
        if not key then return end
        if model:IsShown() then Release(model); return end
        Resolve(model, key)
    end
    function ns.UF_CanMirrorPortrait2D(model, unit, onReady)
        -- IDs may be secret: only type() and issecretvalue() ever test them.
        local guid = UnitGUID(unit)
        local key = (not issecretvalue(guid)) and guid or nil
        if key then
            local v = verdict[key]
            if v ~= nil then return v end
            -- This unit's load is still in flight: take the answer if it is in.
            if model._mirPending == key then
                if type(model:GetModelFileID()) == "nil" then return false end
                model._mirReady = nil
                return Resolve(model, key)
            end
        end
        if model._mirPending then Release(model) end
        model:SetKeepModelOnHide(true)
        model:ClearModel()
        model:SetUnit(unit)
        local id = model:GetModelFileID()
        if type(id) == "nil" and key and onReady then
            model._mirPending, model._mirReady = key, onReady
            if not model._mirHooked then
                model._mirHooked = true
                model:HookScript("OnModelLoaded", OnModelLoaded)
            end
            return false
        end
        local v = GetMirrorAngle(id) ~= nil
        Release(model)
        if key and type(id) ~= "nil" then Store(key, v) end
        return v
    end
    function ns.UF_ForgetPortraitMirror(unit)
        local guid = UnitGUID(unit)
        if not issecretvalue(guid) and guid and verdict[guid] ~= nil then
            verdict[guid] = nil
            verdictCount = verdictCount - 1
        end
    end

    function ns.UF_ApplyPortraitRotation(model, mirror)
        local angle = mirror and GetMirrorAngle(model:GetModelFileID())
        if not angle then
            -- Clear the previous target's transform when switching to a creature,
            -- losing the model ID, showing a question mark, or disabling mirroring.
            if model._portraitMirrored then
                model:SetViewTranslation(0, 0)
                model:SetRotation(0, false)
                model._portraitMirrored = nil
            end
            return
        end
        -- Reapply after every model reload, even when the angle has not changed.
        model:SetViewTranslation(15, 0)
        model:SetRotation(math.rad(angle), false)
        model._portraitMirrored = true
    end
end

-- Shared portrait element Override (2D texture and 3D model objects; class texture
-- keeps its own). The vendored oUF Update only guid-gates the eventless OnUpdate poll,
-- so every other trigger (onShow, target-changed sweeps, any unit event) repaints
-- unconditionally, re-running SetPortraitTexture + the re-anchor PostUpdate for the
-- SAME unit in heavy combat. This Override repaints only when identity/availability
-- changed, on real appearance events (same-guid model/portrait-file changes), or on an
-- explicit ForceUpdate (mode swaps). Secret guids (instanced-PvP identities) can't be
-- compared, so they fail open to repainting. No unitIsUnit head-check (secret booleans
-- on eventless frames; the gate keeps repaint-on-any-event dispatch cheap). PostUpdate
-- runs only after a real repaint: 2D heals what SetPortraitTexture resets, 3D
-- re-applies zoom after SetUnit -- nothing to heal without a repaint.
-- fallback: the class lane's resolved non-player fallback, when the painter has it.
local PortraitOverride  -- forward declaration; painter registrations below the definition
local SwapPortraitMode  -- forward declaration; the portrait painter swaps through it
function PortraitOverride(self, event, evtUnit, fallback)
    local element = self.Portrait
    if not element then return end
    local u = self._euiUnit
    if not u then return end
    if element.PreUpdate then element:PreUpdate(u) end
    local isAvailable = UnitIsConnected(u) and UnitIsVisible(u)
    local guid = UnitGUID(u)
    local changed
    if issecretvalue(guid) or issecretvalue(element.guid) then
        changed = true
    else
        changed = element.guid ~= guid
    end
    local isModel = element:IsObjectType("PlayerModel")
    local hasStateChanged = changed
        or element.state ~= isAvailable
        or event == "UNIT_PORTRAIT_UPDATE"
        -- 3D portraits must reload on model changes. The opted-in 2D mirror
        -- eligibility check below also uses this event; ordinary 2D art uses
        -- UNIT_PORTRAIT_UPDATE / PORTRAITS_UPDATED.
        or (event == "UNIT_MODEL_CHANGED" and isModel)
        or event == "ForceUpdate"
        -- Unit swaps (vehicle enter/exit) always repaint: the swap moment can
        -- paint before the new unit's art/model streams in, and nothing with
        -- a changed guid follows.
        or event == "UnitChanged"
        -- World transitions can reset PlayerModel widget state at the same guid;
        -- repaint once per zone so 3D portraits never come back blank.
        or event == "PLAYER_ENTERING_WORLD"
        -- The repaint above runs mid-loading-screen, where SetPortraitTexture
        -- has no portrait art to hand back yet and paints a blank one. The
        -- client fires PORTRAITS_UPDATED once that art is ready, and it is the
        -- only trigger that follows: the guid and the availability state both
        -- come back unchanged, so without this the blank is what the gate
        -- caches until the next reload. Blizzard's own player portrait (the
        -- character micro button) re-runs SetPortraitTexture on the same event
        -- for the same reason. 2D only: the event says portrait ART is ready,
        -- which the model path does not read, and repainting it would mean a
        -- ClearModel + SetUnit reload every time the client streams a batch.
        or (event == "PORTRAITS_UPDATED" and not isModel)
        -- Frame re-show: PlayerModel widgets DROP their model while hidden
        -- (loading screens hide the unit frames; the PEW fan-out skips hidden
        -- frames, so the re-show is the one trigger that reliably follows --
        -- with guid and availability both reading unchanged, field-traced).
        -- Models only: 2D textures survive Hide/Show.
        or (event == "Show" and isModel)
    -- A changed model can also change 2D mirror eligibility, including class
    -- mode's NPC fallback: drop the cached answer and repaint, only when opted in.
    if event == "UNIT_MODEL_CHANGED" and not isModel then
        local uk = UnitToSettingsKey(self._euiBaseUnit or u)
        local us = uk and db.profile[uk]
        if us and us.portraitMirror and not ns.UF_Blizz() then
            ns.UF_ForgetPortraitMirror(u)
            hasStateChanged = true
        end
    end
    -- Blank-model recovery is only needed when no other change requires a paint.
    -- Show can run before assets stream in; PORTRAITS_UPDATED retries a still-
    -- blank model without reloading one that is already populated.
    if not hasStateChanged and event == "PORTRAITS_UPDATED" and isModel and element.GetModelFileID then
        local modelFileID = element:GetModelFileID()
        hasStateChanged = not issecretvalue(modelFileID) and modelFileID == nil
    end
    if hasStateChanged then
        if isModel then
            if not isAvailable then
                element:SetCamDistanceScale(0.25)
                element:SetPortraitZoom(0)
                element:SetPosition(0, 0, 0.25)
                element:ClearModel()
                element:SetModel([[Interface\Buttons\TalkToMeQuestionMark.m2]])
            else
                local uKey3d = UnitToSettingsKey(self._euiBaseUnit or u)
                local uS3d = uKey3d and db.profile[uKey3d]
                local camScale = ((uS3d and uS3d.portrait3dZoom) or 100) / 100
                element:ClearModel()
                element:SetUnit(u)
                element:SetPortraitZoom(1)
                element:SetPosition(0, 0, 0)
                element:SetCamDistanceScale(camScale)
            end
        elseif element.isClass then
            -- Class sprite lane: the engine painter is the single portrait
            -- dispatch, so class mode paints here too. SetPortraitTexture on
            -- this element would stamp portrait art through the sprite
            -- cell's texcoords (the field-reported weird-colored square);
            -- ApplyClassIconTexture instead re-asserts file + coords, and
            -- re-reading the style here lets art-style changes ride any
            -- repaint. Unit swaps (target changes) land through the same
            -- guid gate as every other portrait mode.
            -- Only players take class art (UnitClass reports most NPCs as
            -- warriors); anyone else shows its 2D portrait on the backdrop's
            -- 2D texture, as Blizzard's own class portraits do. UnitIsPlayer
            -- is never secret. The frame's fallback (ns.UF_ClassFallback) can
            -- be nothing at all, available or not ("3d" swaps before the paint).
            local npcTex = element.backdrop and element.backdrop._2d
            local fb
            if npcTex and not UnitIsPlayer(u) then
                fb = fallback
                if not fb then
                    local uKeyF = UnitToSettingsKey(self._euiBaseUnit or u)
                    fb = ns.UF_ClassFallback(uKeyF and db.profile[uKeyF])
                end
            end
            if fb and (isAvailable or fb == "none") then
                element:Hide()
                if fb == "none" then
                    -- Hidden here: a previous unit's 2D art would stay visible.
                    npcTex:Hide()
                else
                    SetPortraitTexture(npcTex, u, npcTex._blizzNoMask)
                    if npcTex.PostUpdate then npcTex:PostUpdate(u) end
                    npcTex:Show()
                end
            else
                if npcTex then npcTex:Hide() end
                element:Show()
                local uKeyC = UnitToSettingsKey(self._euiBaseUnit or u)
                local uSC = uKeyC and db.profile[uKeyC]
                -- Mirror Portrait flips the class art (never under a stock
                -- style); the question-mark fallback always reads unflipped.
                if not (isAvailable and ns.UF_PaintClassIcon(element, u,
                        (uSC and uSC.classThemeStyle) or "modern",
                        uSC and uSC.portraitMirror and not ns.UF_Blizz())) then
                    element:SetTexCoord(0.15, 0.85, 0.15, 0.85)
                    element:SetTexture([[Interface\Icons\INV_Misc_QuestionMark]])
                end
            end
        else
            if isAvailable then
                -- Third argument: skip the client's own round crop (nil off
                -- the Blizzard Style; set by the style's portrait pass on the
                -- player frame, whose stock mask is not a circle).
                SetPortraitTexture(element, u, element._blizzNoMask)
            else
                element:SetTexture([[Interface\Icons\INV_Misc_QuestionMark]])
            end
        end
        -- Recovery-preserving stamp: an UNAVAILABLE paint (fallback art --
        -- transition windows, streaming models) must not cache its guid, or
        -- the gate skips every later same-guid trigger and the fallback is
        -- what sticks (vehicle swaps lost the portrait this way). Leaving
        -- the guid unstamped makes the next trigger a guid-change repaint.
        element.guid = isAvailable and guid or nil
        element.state = isAvailable
    end
    if hasStateChanged and element.PostUpdate then
        return element:PostUpdate(u, hasStateChanged)
    end
end

-- Portraits: PortraitOverride was already the complete painter (GUID/state
-- gated 2D/3D handling); the engine becomes its event source. Raid target
-- icon: index lookup straight onto the icon texture.
ns.Engine.SetPainter("portrait", function(frame, unit, event)
    if frame.Portrait and ns.Engine.ElementOn(frame, "Portrait") then
        -- Class art frames: a 3D non-player fallback is a real mode swap, made
        -- before the paint so both read the same unit (no 2D flash between).
        local swap, fb = ns.UF_ClassFallbackNeedsSwap(frame, unit)
        if swap then SwapPortraitMode(frame, true) end
        PortraitOverride(frame, event or "ForceUpdate", unit, fb)
    end
end)
-- Element ForceUpdate stamp: the settings code refreshes portraits through
-- frame.Portrait:ForceUpdate(), and mode swaps replace the Portrait object,
-- so the stamp is re-applied wherever the field is reassigned.
function ns.UF_StampPortraitForceUpdate(frame)
    local p = frame.Portrait
    if not p or p.ForceUpdate then return end
    p.ForceUpdate = function()
        if ns.Engine.ElementOn(frame, "Portrait") then
            PortraitOverride(frame, "ForceUpdate", frame._euiUnit)
        end
    end
end

-- Mirror-only edits reuse loaded models; 2D/class art keeps its normal repaint.
function ns.UF_RefreshPortraitMirror(unitKey)
    for _, frame in pairs(frames) do
        if type(frame) == "table" and frame.Portrait
            and UnitToSettingsKey(frame._euiBaseUnit or frame._euiUnit) == unitKey
            and ns.Engine.ElementOn(frame, "Portrait") then
            local p = frame.Portrait
            if p:IsObjectType("PlayerModel") then
                ns.UF_ApplyPortraitRotation(p, p.state and db.profile[unitKey].portraitMirror and not ns.UF_Blizz())
            elseif p.ForceUpdate then
                p:ForceUpdate()
            end
        end
    end
end
ns.Engine.SetPainter("raidicon", function(frame, unit)
    if not ns.Engine.ElementOn(frame, "RaidTargetIndicator") then return end
    local element = frame.RaidTargetIndicator
    if not element then return end
    -- The styles create the icon as a bare texture; the marker SHEET must be
    -- assigned before SetRaidTargetIconTexture's texcoords can render (the
    -- old element wiring auto-assigned it on enable -- same file the
    -- nameplate markers use).
    if not element:GetTexture() then
        element:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
    end
    local index = UnitExists(unit) and GetRaidTargetIndex(unit) or nil
    if index then
        SetRaidTargetIconTexture(element, index)
        element:Show()
    else
        element:Hide()
    end
end)

-- One-stop engine wiring for a freshly spawned frame: the shared colors
-- table, the castbar owner backref, the channel set derived from the widgets
-- the style actually built, the matching Blizzard-frame suppression, and the
-- first full paint.
function ns.UF_AttachEngineFrame(frame, unit, polled)
    frame.colors = ns.Colors
    -- Smoothing defaults the old element wiring seeded on enable: painters
    -- pass element.smoothing into every SetValue/SetTimerDuration, and the
    -- old build guaranteed Immediate until settings stamped otherwise
    -- (ReloadFrames overrides Health's; Power and Castbar keep this).
    local IMMEDIATE = Enum and Enum.StatusBarInterpolation
        and Enum.StatusBarInterpolation.Immediate
    if frame.Health and not frame.Health.smoothing then
        frame.Health.smoothing = IMMEDIATE
    end
    if frame.Power and not frame.Power.smoothing then
        frame.Power.smoothing = IMMEDIATE
    end
    if frame.Castbar and not frame.Castbar.smoothing then
        frame.Castbar.smoothing = IMMEDIATE
    end
    local channels = {}
    if frame.Health then channels[#channels + 1] = "health" end
    if frame.Power then channels[#channels + 1] = "power" end
    channels[#channels + 1] = "text"
    if frame.HealthPrediction then channels[#channels + 1] = "absorb" end
    if frame.Portrait then
        channels[#channels + 1] = "portrait"
        ns.UF_StampPortraitForceUpdate(frame)
    end
    if frame.Castbar then
        frame.Castbar.__owner = frame
        channels[#channels + 1] = "castbar"
    end
    if frame.RaidTargetIndicator then channels[#channels + 1] = "raidicon" end
    if polled then
        ns.Engine.AttachPolled(frame, unit, channels)
    else
        ns.Engine.Attach(frame, unit, channels)
    end
    -- Opt-in heal prediction joins its channel here when the unit has it on.
    if frame.HealthPrediction and ns.UF_HEAL_PRED_UNITS[unit] then
        ns.UF_HealPredApply(frame, unit, GetSettingsForUnit(unit))
    end
    -- Opt-in Blizzard Glow Line: built and joined only when on.
    if frame.HealthPrediction then ns.UF_AbsorbGlowApply(frame, unit) end
    -- The player's power value channel: joined while the frame is visible and
    -- shows the value, so it also follows the frame's show and hide.
    if unit == "player" and frame.Power then
        frame:HookScript("OnShow", ns.UF_PowerValSync)
        frame:HookScript("OnHide", ns.UF_PowerValSync)
        ns.UF_PowerValSync(frame)
    end
    ns.Engine.HideBlizzardUnitFrame(unit)
    ns.Engine.RepaintAll(frame, "Spawn")
end

-- Mask and border paths for detached portrait shapes.
local PORTRAIT_MASKS = EllesmereUI.SHAPE_MASKS
local PORTRAIT_BORDERS = EllesmereUI.SHAPE_BORDERS

-- Top pixel inset for each mask shape (px from edge to visible portrait area in 128px mask)
local MASK_INSETS = EllesmereUI.SHAPE_INSETS

-- Shared with EllesmereUIUnitFrames_PlayerAuraBars.lua (same addon/ns), which reuses
-- this shape media set for Player Aura Bars' iconShape feature.
ns.PORTRAIT_MASKS   = PORTRAIT_MASKS
ns.PORTRAIT_BORDERS = PORTRAIT_BORDERS
ns.MASK_INSETS      = MASK_INSETS

-- Detached portrait shapes whose ring art draws OUTSIDE the mask (never
-- clipped by it), with the ring's inset from the backdrop edge in px. Kept
-- here, not in the shared catalogue, so no other module's shape path changes.
ns.UF_UNMASKED_RING = { pixelsCircle = 4 }
-- Round shapes: the only ones that take the Outer Ring and the Inner Shadow.
ns.UF_ROUND_SHAPES = { circle = true, pixelsCircle = true }
ns.UF_PORTRAIT_INNER_SHADOW = "Interface\\AddOns\\EllesmereUI\\media\\portraits\\pixels_inner_shadow.tga"
ns.UF_THIN_BORDER_RING = "Interface\\AddOns\\EllesmereUI\\media\\portraits\\pixels_ring_thin_border.tga"

-- Stock target-frame dragon art, placed as on the stock 58px portrait (top-right corner 15px right, 11px up).
ns.UF_WINGLESS_GOLD   = "UI-HUD-UnitFrame-Target-PortraitOn-Boss-Gold"
ns.UF_WINGLESS_SILVER = "ui-hud-unitframe-target-portraiton-boss-rare-silver"
-- The Elite Enemy Dragon's art per unit classification (none for the rest).
ns.UF_WINGLESS_ATLAS = {
    elite = ns.UF_WINGLESS_GOLD, worldboss = ns.UF_WINGLESS_GOLD,
    rare = ns.UF_WINGLESS_SILVER, rareelite = ns.UF_WINGLESS_SILVER,
}
-- Atlas info per name, read once (false: not in this client).
ns.UF_WinglessInfoCache = {}
function ns.UF_WinglessInfo(atlas)
    local info = ns.UF_WinglessInfoCache[atlas]
    if info == nil then
        info = C_Texture.GetAtlasInfo(atlas) or false
        ns.UF_WinglessInfoCache[atlas] = info
    end
    return info or nil
end

-- Paints the dragon art unless the texture already shows this atlas and
-- mirror (the memo; UF_PlaceWinglessDragon clears it). False when missing.
function ns.UF_WinglessArt(tex, atlas, mirrored)
    if tex._wAtlas == atlas and tex._wFlip == mirrored then return true end
    local info = ns.UF_WinglessInfo(atlas)
    if not info then return false end
    -- The atlas's file with its coordinates, not SetAtlas: after SetAtlas,
    -- SetTexCoord crops within the atlas region instead of the file.
    tex:SetTexture(info.file or info.filename)
    local l, r = info.leftTexCoord, info.rightTexCoord
    if mirrored then l, r = r, l end
    tex:SetTexCoord(l, r, info.topTexCoord, info.bottomTexCoord)
    tex._wAtlas, tex._wFlip = atlas, mirrored
    return true
end

-- Lays the dragon out on host (size from its height, scale percent around its
-- centre, x/y shift, class tint) and repaints its art; the caller shows it.
-- False, hidden, when the atlas is missing.
function ns.UF_PlaceWinglessDragon(tex, host, atlas, mirrored, classColor, scale, x, y)
    tex._wAtlas = nil
    if not ns.UF_WinglessArt(tex, atlas, mirrored) then tex:Hide(); return false end
    local info = ns.UF_WinglessInfo(atlas)
    local h = host:GetHeight()
    if not PP.IsNum(h) or h < 1 then h = 46 end
    local k = h / 58
    local w, th = info.width * k, info.height * k
    local cx, cy = 44 * k - w / 2, 40 * k - th / 2
    if mirrored then cx = -cx end
    local s = (PP.IsNum(scale) and scale or 100) / 100
    tex:SetSize(w * s, th * s)
    tex:ClearAllPoints()
    tex:SetPoint("CENTER", host, "CENTER", cx * s + (x or 0), cy * s + (y or 0))
    local cc
    if classColor then
        local _, tok = UnitClass("player")
        cc = tok and EllesmereUI.GetClassColor(tok)
    end
    tex:SetDesaturated(cc and true or false)
    if cc then tex:SetVertexColor(cc.r, cc.g, cc.b) else tex:SetVertexColor(1, 1, 1) end
    return true
end

-- Raises a dragon holder over its portrait backdrop: strata nil, false or
-- "inherit" follows the backdrop; level is added to the backdrop's, at least 1.
function ns.UF_LiftDragonHolder(holder, host, strata, level)
    holder:SetFrameStrata((not strata or strata == "inherit") and host:GetFrameStrata() or strata)
    holder:SetFrameLevel(host:GetFrameLevel() + math_max(1, level or 1))
end

-- Portrait Dragon: the boss dragon curled round the player, target and focus
-- portraits (Player Frame Dragon, Elite Enemy Dragon), attached or detached,
-- any shape. One key set per unit (detachedPortraitWinglessDragon and its
-- suffixed keys). A target table whose Elite/Rare Indicator style is
-- "wingless" is read as a view: its dragon comes from that style's keys and
-- the indicator itself reads as off, with nothing rewritten until an options
-- setter calls ns.UF_PinLegacyDragon.
function ns.UF_DragonLegacy(s)
    return s ~= nil and s.eliteIndicatorStyle == "wingless"
end

-- The effective dragon settings of unitKey's settings table s: on, scale, x,
-- y, flip, classColor, strata, level, instances. The table is kept per unit
-- and rewritten by every call, so callers read it at once.
ns._ufDragonEff = {}
function ns.UF_DragonSettings(unitKey, s)
    local e = ns._ufDragonEff[unitKey]
    if not e then
        e = {}
        ns._ufDragonEff[unitKey] = e
    end
    if not s then
        e.on = false
    elseif ns.UF_DragonLegacy(s) then
        e.on = s.eliteIndicatorEnabled == true
        e.scale = s.eliteIndicatorWinglessScale or 100
        e.x, e.y = s.eliteIndicatorX or 0, s.eliteIndicatorY or 0
        e.flip = s.eliteIndicatorWinglessFlip == true
        e.classColor = s.eliteIndicatorWinglessClassColor == true
        e.strata = s.eliteIndicatorWinglessStrata or "inherit"
        e.level = s.eliteIndicatorWinglessLevel or 1
        e.instances = s.eliteIndicatorShowInInstances == true
    else
        e.on = s.detachedPortraitWinglessDragon == true
        e.scale = s.detachedPortraitWinglessDragonScale or 100
        e.x, e.y = s.detachedPortraitWinglessDragonX or 0, s.detachedPortraitWinglessDragonY or 0
        e.flip = s.detachedPortraitWinglessDragonFlip == true
        e.classColor = s.detachedPortraitWinglessDragonClassColor == true
        e.strata = s.detachedPortraitWinglessDragonStrata or "inherit"
        e.level = s.detachedPortraitWinglessDragonLevel or 2
        e.instances = s.detachedPortraitWinglessDragonInstances == true
    end
    return e
end

-- Writes a legacy view's effective dragon values into the dragon's own keys
-- and retires the old style (Elite/Rare Indicator off, Badge style), so the
-- frame looks the same. Every options setter of the dragon row and of the
-- Elite/Rare Indicator calls it first; nothing calls it at load.
function ns.UF_PinLegacyDragon(s)
    if not ns.UF_DragonLegacy(s) then return end
    local e = ns.UF_DragonSettings("target", s)
    s.detachedPortraitWinglessDragon = e.on
    s.detachedPortraitWinglessDragonScale = e.scale
    s.detachedPortraitWinglessDragonX = e.x
    s.detachedPortraitWinglessDragonY = e.y
    s.detachedPortraitWinglessDragonFlip = e.flip
    s.detachedPortraitWinglessDragonClassColor = e.classColor
    s.detachedPortraitWinglessDragonStrata = e.strata
    s.detachedPortraitWinglessDragonLevel = e.level
    s.detachedPortraitWinglessDragonInstances = e.instances
    s.eliteIndicatorEnabled = false
    s.eliteIndicatorStyle = "badge"
end

-- Lays the dragon out on host (a portrait backdrop, or the options preview
-- frame) from effective settings e, facing mirrored, over the gold art (gold
-- and silver share one box); nil e hides it. Its holder frame and texture
-- exist from the first draw. The dragon reaches past the host, so any clip
-- on a live backdrop lifts while it shows (an Inside portrait is a 3D
-- model, which ignores the clip anyway). Returns the texture for the
-- caller to paint and show, or nil (hidden, or no art).
function ns.UF_PortraitDragon(host, e, mirrored)
    local holder = host._winglessHolder
    if not e then
        if holder then
            holder:Hide()
            if holder._unclipped then
                holder._unclipped = nil
                if host._isInside then host:SetClipsChildren(true) end
            end
        end
        return nil
    end
    if not holder then
        holder = CreateFrame("Frame", nil, host)
        holder:SetAllPoints(host)
        host._winglessHolder = holder
        host._winglessDragon = holder:CreateTexture(nil, "OVERLAY")
    end
    -- The options preview sits in a DIALOG window, so a lower strata would hide it.
    ns.UF_LiftDragonHolder(holder, host, not host._isPreview and e.strata, e.level)
    holder:Show()
    local tex = host._winglessDragon
    if not ns.UF_PlaceWinglessDragon(tex, host, ns.UF_WINGLESS_GOLD, mirrored,
        e.classColor, e.scale, e.x, e.y) then
        return nil
    end
    -- Lift the clip on every live show: Inside clips on purpose, and a
    -- backdrop that left Inside this session keeps that clip (the reload
    -- pass resets it only for attached portraits).
    if not host._isPreview then
        host:SetClipsChildren(false)
        holder._unclipped = true
    end
    return tex
end

-- The dragon's art on a live frame: gold on the player (as laid out), and on
-- target or focus the unit's classification art (gold for elite and boss,
-- silver for rare and rare elite, none for the rest, players included), nor
-- in instances unless Show in Instances is on.
function ns.UF_PaintPortraitDragon(holder)
    local tex = holder._tex
    if not holder._enemy then
        tex:Show()
        return
    end
    local atlas
    if holder._inst or not IsInInstance() then
        -- Secrecy check before any use of the classification.
        local c = UnitClassification(holder._unitKey)
        atlas = not issecretvalue(c) and ns.UF_WINGLESS_ATLAS[c]
    end
    if atlas and ns.UF_WinglessArt(tex, atlas, holder._mirrored) then
        tex:Show()
    else
        tex:Hide()
    end
end

-- One live frame's dragon (uf = the player, target or focus frame, unitKey
-- its settings key): drawn while it is on, the portrait shows and no stock
-- style draws the frame, hidden otherwise; nothing is built before the first
-- enable. The holder keeps what the paint and the strata pass read. Player
-- faces mirrored unless flipped, target and focus the art's own way.
function ns.UF_ApplyPortraitDragon(uf, unitKey)
    local bd = uf and uf.Portrait and uf.Portrait.backdrop
    if not bd then return end
    local e = ns.UF_DragonSettings(unitKey, db.profile[unitKey])
    local mirrored = (unitKey == "player") ~= e.flip
    local tex = e.on and bd:IsShown() and not ns.UF_Blizz()
        and ns.UF_PortraitDragon(bd, e, mirrored)
    local holder = bd._winglessHolder
    if not tex then
        if holder then
            holder._on = false
            ns.UF_PortraitDragon(bd, nil)
        end
        return
    end
    if not holder._unitKey then
        holder._unitKey, holder._uf, holder._tex = unitKey, uf, tex
        -- A portrait resized outside a settings pass (class power, UI
        -- scale) lays its dragon out again.
        holder:SetScript("OnSizeChanged", ns.UF_PortraitDragonResized)
    end
    holder._on = true
    holder._enemy = unitKey ~= "player"
    holder._mirrored = mirrored
    holder._inst = e.instances
    holder._strata, holder._level = e.strata, e.level
    ns.UF_PaintPortraitDragon(holder)
end

function ns.UF_PortraitDragonResized(holder)
    if holder._on then ns.UF_ApplyPortraitDragon(holder._uf, holder._unitKey) end
end

-- Repaints unitKey's dragon when it is up (classification events).
function ns.UF_PaintPortraitDragonFor(unitKey)
    local uf = frames[unitKey]
    local bd = uf and uf.Portrait and uf.Portrait.backdrop
    local holder = bd and bd._winglessHolder
    if holder and holder._on then ns.UF_PaintPortraitDragon(holder) end
end

function ns.UF_PortraitDragonEvent(_, event, unit)
    if event == "PLAYER_TARGET_CHANGED" then
        ns.UF_PaintPortraitDragonFor("target")
    elseif event == "PLAYER_FOCUS_CHANGED" then
        ns.UF_PaintPortraitDragonFor("focus")
    elseif event == "UNIT_CLASSIFICATION_CHANGED" then
        ns.UF_PaintPortraitDragonFor(unit)
    else
        ns.UF_PaintPortraitDragonFor("target")
        ns.UF_PaintPortraitDragonFor("focus")
    end
end

-- The Elite Enemy Dragons' events (unit changes, classification changes,
-- zoning for the instance check): registered only for the frames whose
-- dragon is up, none at all while neither is (zero cost off).
function ns.UF_ArmPortraitDragonEvents()
    local tf, ff = frames.target, frames.focus
    local tb = tf and tf.Portrait and tf.Portrait.backdrop
    local fb = ff and ff.Portrait and ff.Portrait.backdrop
    local t = tb and tb._winglessHolder and tb._winglessHolder._on
    local f = fb and fb._winglessHolder and fb._winglessHolder._on
    local ev = ns._ufDragonEvents
    if ev then ev:UnregisterAllEvents() end
    if not (t or f) then return end
    if not ev then
        ev = CreateFrame("Frame")
        ev:SetScript("OnEvent", ns.UF_PortraitDragonEvent)
        ns._ufDragonEvents = ev
    end
    ev:RegisterEvent("PLAYER_ENTERING_WORLD")
    if t then ev:RegisterEvent("PLAYER_TARGET_CHANGED") end
    if f then ev:RegisterEvent("PLAYER_FOCUS_CHANGED") end
    if t and f then
        ev:RegisterUnitEvent("UNIT_CLASSIFICATION_CHANGED", "target", "focus")
    else
        ev:RegisterUnitEvent("UNIT_CLASSIFICATION_CHANGED", t and "target" or "focus")
    end
end

-- Every frame's dragon, then the events: each settings pass and login.
function ns.UF_ApplyPortraitDragons()
    ns.UF_ApplyPortraitDragon(frames.player, "player")
    ns.UF_ApplyPortraitDragon(frames.target, "target")
    ns.UF_ApplyPortraitDragon(frames.focus, "focus")
    ns.UF_ArmPortraitDragonEvents()
end

-- Outer Ring art for a detachedPortraitOuterRing value, or nil (nothing to
-- draw). "border" follows the frame's Border Style (frameTex): its ring
-- companion, nil for a style without one.
function ns.UF_OuterRingPath(ringKey, frameTex)
    local GBC = EllesmereUI.GetBorderCompanion
    if ringKey == "border" then return GBC(frameTex, "ring") end
    if ringKey == "pixels" or ringKey == "pixels-textured" then return GBC(ringKey, "ring") end
    if ringKey == "pixels-shadow" then return GBC("pixels", "ringShadow") end
    if ringKey == "pixels-textured-shadow" then return GBC("pixels-textured", "ringShadow") end
    if ringKey == "thin-border" then return ns.UF_THIN_BORDER_RING end
    return nil
end

-- Outer Ring and Inner Shadow on a round detached portrait. host = the
-- portrait backdrop (or the options preview frame, same field names), s = the
-- unit's settings, shape = its resolved shape; s == nil hides both. Nothing
-- exists until a first non-default value. The ring is laid out from the host
-- size (Outer Ring Size percent, minus a 4px inset, edges snapped by PP.Point)
-- and tinted with the frame border colour, which the hover path recolours in
-- place. The ring's geometry is memoized on the texture (ring key, frame
-- Border Style, ring size, host width and height, pixel grid) and its tint on
-- the colour (border r, g, b, alpha), so the per-target class-colour re-run
-- only compares. The Portrait Dragon is its own pass (ns.UF_PortraitDragon).
function ns.UF_PortraitExtras(host, s, shape)
    local round = s and ns.UF_ROUND_SHAPES[shape]
    local ringKey = (round and s.detachedPortraitOuterRing) or "none"
    local ring = host._outerRing
    if ringKey ~= "none" then
        local texKey = s.borderTexture or "solid"
        local scale = s.detachedPortraitOuterRingScale or 118
        local w, h = host:GetWidth(), host:GetHeight()
        if w < 1 then w = 46 end
        if h < 1 then h = 46 end
        local mult = PP.mult
        if not ring then
            ring = host:CreateTexture(nil, "OVERLAY", nil, 1)
            host._outerRing = ring
        end
        if ring._key ~= ringKey or ring._tex ~= texKey or ring._scale ~= scale
            or ring._w ~= w or ring._h ~= h or ring._mult ~= mult then
            ring._key, ring._tex, ring._scale = ringKey, texKey, scale
            ring._w, ring._h, ring._mult = w, h, mult
            local path = ns.UF_OuterRingPath(ringKey, texKey)
            ring._path = path
            if path then
                ring:SetTexture(path)
                local ext = (scale - 100) / 200
                local ox, oy = w * ext - 4, h * ext - 4
                ring:ClearAllPoints()
                PP.Point(ring, "TOPLEFT", host, "TOPLEFT", -ox, oy)
                PP.Point(ring, "BOTTOMRIGHT", host, "BOTTOMRIGHT", ox, -oy)
            end
        end
        if ring._path then
            local bc = s.borderColor
            local r, g, b = 0, 0, 0
            if bc then r, g, b = bc.r, bc.g, bc.b end
            local a = s.borderAlpha or 1
            if ring._r ~= r or ring._g ~= g or ring._b ~= b or ring._a ~= a then
                ring._r, ring._g, ring._b, ring._a = r, g, b, a
                ring:SetVertexColor(r, g, b, a)
            end
            ring:Show()
        else
            ring:Hide()
        end
    elseif ring then
        ring:Hide()
    end

    local shadow = host._innerShadow
    if round and s.detachedPortraitInnerShadow then
        if not shadow then
            -- Over the masked portrait art (ARTWORK), under the shape ring.
            shadow = host:CreateTexture(nil, "ARTWORK", nil, 7)
            shadow:SetTexture(ns.UF_PORTRAIT_INNER_SHADOW)
            shadow:SetAllPoints(host)
            host._innerShadow = shadow
        end
        local mask = host._shapeMask
        if mask and shadow._mask ~= mask then
            shadow:AddMaskTexture(mask)
            shadow._mask = mask
        end
        shadow:Show()
    elseif shadow then
        shadow:Hide()
    end
end

-- Scale class art around its center, retaining the existing inset and mask fill
-- at 100%. Shared with the preview; sprite coordinates and borders stay intact.
function ns.UF_SetClassPortraitPoints(tex, host, zoom, insetX, insetY)
    local clip = false
    if zoom and zoom ~= 100 and not ns.UF_Blizz() then
        local scale = zoom / 100
        local w, h = host:GetWidth(), host:GetHeight()
        if w < 1 then w = 46 end
        if h < 1 then h = 46 end
        local halfW, halfH = w * 0.5, h * 0.5
        insetX = halfW - (halfW - insetX) * scale
        insetY = halfH - (halfH - insetY) * scale
        clip = zoom > 100
    end
    -- Clip only the enlarged class texture, never the portrait's decorations.
    -- Nothing is created for the default zoom or for zooming out.
    local mask = tex._classZoomMask
    if clip then
        if not mask then
            mask = host:CreateMaskTexture()
            mask:SetAllPoints(host)
            -- NEAREST: a bilinear 8x8 mask fades the outer 1/16 into a dark band.
            mask:SetTexture("Interface\\Buttons\\WHITE8X8", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE", "NEAREST")
            tex._classZoomMask = mask
        end
        if not tex._classZoomMasked then
            tex:AddMaskTexture(mask)
            mask:Show()
            tex._classZoomMasked = true
        end
    elseif tex._classZoomMasked then
        tex:RemoveMaskTexture(mask)
        mask:Hide()
        tex._classZoomMasked = nil
    end
    tex:ClearAllPoints()
    PP.Point(tex, "TOPLEFT", host, "TOPLEFT", insetX, -insetY)
    PP.Point(tex, "BOTTOMRIGHT", host, "BOTTOMRIGHT", -insetX, insetY)
end

-- Apply a detached portrait shape (mask + border overlay) to a portrait backdrop;
-- creates the mask/border textures on first call, then updates them.
--   backdrop  : the portrait backdrop frame
--   uSettings : per-unit DB table
--   unitToken : the unit this portrait belongs to ("player", "target", ...)
local function ApplyDetachedPortraitShape(backdrop, uSettings, unitToken)
    -- Mini frames never use detached portraits.
    local isMini = unitToken and (unitToken == "pet" or unitToken == "targettarget" or unitToken == "focustarget" or unitToken:match("^boss%d$"))
    local isDetached = not isMini and ((uSettings and uSettings.portraitStyle) or db.profile.portraitStyle or "attached") == "detached"
    -- Blizzard Style: the portrait sits in the stock art's ring, never detached.
    if isDetached and ns.UF_Blizz() then isDetached = false end
    local shape = (uSettings and uSettings.detachedPortraitShape) or "portrait"
    local showBorder = true
    local borderOpacity = ((uSettings and uSettings.detachedPortraitBorderOpacity) or 100) / 100
    local borderColor = (uSettings and uSettings.detachedPortraitBorderColor) or { r = 0, g = 0, b = 0 }
    local useClassColor = (uSettings and uSettings.detachedPortraitClassColor) or false
    local rawBorderSize = (uSettings and uSettings.detachedPortraitBorderSize) or 7
    -- Border art is natively 7px. Scale UP by (7 - rawBorderSize) so the mask
    -- clips the inner portion, leaving rawBorderSize px visible.
    local bExp = 7 - rawBorderSize

    -- Border color; class color overrides the manual color.
    local bR, bG, bB = borderColor.r, borderColor.g, borderColor.b
    if useClassColor then
        -- Unit Color in Dark Mode keeps the unit path below under Dark Mode.
        local isDark = db and db.profile and db.profile.darkTheme
            and not (uSettings and uSettings.detachedPortraitUnitColorDark)
        if isDark then
            -- Dark mode: always the player's own class color.
            local _, classToken = UnitClass("player")
            if classToken then
                local c = (CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS)[classToken]
                if c then bR, bG, bB = c.r, c.g, c.b end
            end
        elseif unitToken and UnitExists(unitToken) then
            -- Non-dark: the unit's health bar color (class for players, reaction
            -- for NPCs, tapped grey).
            local _, classToken = UnitClass(unitToken)
            if UnitIsPlayer(unitToken) and not issecretvalue(classToken) and classToken then
                local c = (CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS)[classToken]
                if c then bR, bG, bB = c.r, c.g, c.b end
            elseif UnitIsTapDenied and UnitIsTapDenied(unitToken) then
                bR, bG, bB = 0.6, 0.6, 0.6
            else
                local reaction = UnitReaction(unitToken, "player")
                if reaction then
                    -- Prefer oUF's reaction table (carries the custom Enemy Colors
                    -- override) so the border matches the health bar.
                    local c = (ns.Colors and ns.Colors.reaction and ns.Colors.reaction[reaction])
                        or FACTION_BAR_COLORS[reaction]
                    if c then bR, bG, bB = c.r, c.g, c.b end
                end
            end
        else
            -- Fallback: player class color.
            local _, classToken = UnitClass("player")
            if classToken then
                local c = (CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS)[classToken]
                if c then bR, bG, bB = c.r, c.g, c.b end
            end
        end
    end

    -- Not detached: drop the mask and reset texture positions.
    if not isDetached then
        if backdrop._shapeMask then
            if backdrop._2d then backdrop._2d:RemoveMaskTexture(backdrop._shapeMask) end
            if backdrop._class then backdrop._class:RemoveMaskTexture(backdrop._shapeMask) end
            if backdrop._bg then backdrop._bg:RemoveMaskTexture(backdrop._shapeMask) end
            backdrop._shapeMask:Hide()
        end
        if backdrop._shapeBorderTex then backdrop._shapeBorderTex:Hide() end
        if backdrop._sqBorderTexs then
            for _, t in ipairs(backdrop._sqBorderTexs) do t:Hide() end
        end
        -- Detached mode expands these for mask fill; reset to default.
        if backdrop._2d then
            backdrop._2d:ClearAllPoints()
            PP.Point(backdrop._2d, "TOPLEFT", backdrop, "TOPLEFT", 0, 0)
            PP.Point(backdrop._2d, "BOTTOMRIGHT", backdrop, "BOTTOMRIGHT", 0, 0)
        end
        if backdrop._class then
            local bh2 = backdrop:GetHeight()
            if bh2 < 1 then bh2 = 46 end
            local classInset = math.floor(bh2 * 0.08)
            ns.UF_SetClassPortraitPoints(backdrop._class, backdrop,
                uSettings and uSettings.portraitClassZoom, classInset, classInset)
        end
        if backdrop._3d then
            backdrop._3d:ClearAllPoints()
            PP.Point(backdrop._3d, "TOPLEFT", backdrop, "TOPLEFT", 0, 0)
            PP.Point(backdrop._3d, "BOTTOMRIGHT", backdrop, "BOTTOMRIGHT", 0, 0)
        end
        if backdrop._outerRing or backdrop._innerShadow then ns.UF_PortraitExtras(backdrop, nil) end
        return
    end

    -- === MASK ===
    local maskPath = shape ~= "none" and PORTRAIT_MASKS[shape] or nil
    if shape == "none" then
        -- Drop mask, border and background.
        if backdrop._bg then backdrop._bg:Hide() end
        if backdrop._shapeMask then
            if backdrop._2d then pcall(backdrop._2d.RemoveMaskTexture, backdrop._2d, backdrop._shapeMask) end
            if backdrop._class then pcall(backdrop._class.RemoveMaskTexture, backdrop._class, backdrop._shapeMask) end
            if backdrop._bg then pcall(backdrop._bg.RemoveMaskTexture, backdrop._bg, backdrop._shapeMask) end
            backdrop._shapeMask:Hide()
        end
        if backdrop._shapeBorderTex then backdrop._shapeBorderTex:Hide() end
        if backdrop._sqBorderTexs then
            for _, t in ipairs(backdrop._sqBorderTexs) do t:Hide() end
        end
        -- Reset content to fill the backdrop.
        if backdrop._2d then
            backdrop._2d:ClearAllPoints()
            PP.Point(backdrop._2d, "TOPLEFT", backdrop, "TOPLEFT", 0, 0)
            PP.Point(backdrop._2d, "BOTTOMRIGHT", backdrop, "BOTTOMRIGHT", 0, 0)
        end
        if backdrop._class then
            local bh2 = backdrop:GetHeight()
            if bh2 < 1 then bh2 = 46 end
            local classInset = math.floor(bh2 * 0.08)
            ns.UF_SetClassPortraitPoints(backdrop._class, backdrop,
                uSettings and uSettings.portraitClassZoom, classInset, classInset)
        end
        if backdrop._3d then
            backdrop._3d:ClearAllPoints()
            PP.Point(backdrop._3d, "TOPLEFT", backdrop, "TOPLEFT", 0, 0)
            PP.Point(backdrop._3d, "BOTTOMRIGHT", backdrop, "BOTTOMRIGHT", 0, 0)
        end
        if backdrop._outerRing or backdrop._innerShadow then ns.UF_PortraitExtras(backdrop, nil) end
        return
    end
    if backdrop._bg then backdrop._bg:Show() end
    if maskPath then
        if not backdrop._shapeMask then
            backdrop._shapeMask = backdrop:CreateMaskTexture()
        end
        -- Inset the mask 1px when the border is visible so scaling cannot make
        -- the mask edge poke out from behind the border art.
        backdrop._shapeMask:ClearAllPoints()
        if rawBorderSize >= 1 then
            PP.Point(backdrop._shapeMask, "TOPLEFT", backdrop, "TOPLEFT", 1, -1)
            PP.Point(backdrop._shapeMask, "BOTTOMRIGHT", backdrop, "BOTTOMRIGHT", -1, 1)
        else
            backdrop._shapeMask:SetAllPoints(backdrop)
        end
        backdrop._shapeMask:SetTexture(maskPath, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        backdrop._shapeMask:Show()
        if backdrop._2d then backdrop._2d:AddMaskTexture(backdrop._shapeMask) end
        if backdrop._class then backdrop._class:AddMaskTexture(backdrop._shapeMask) end
        if backdrop._bg then backdrop._bg:AddMaskTexture(backdrop._shapeMask) end
    end

    -- Hide legacy square border textures if this frame has them.
    if backdrop._sqBorderTexs then
        for _, t in ipairs(backdrop._sqBorderTexs) do t:Hide() end
    end

    -- === TGA BORDER OVERLAY ===
    -- Geometry (anchors, mask attach, art) re-applies only when one of its
    -- inputs changes -- shape, border size step, pixel grid, mask object -- so
    -- the per-target class-colour re-run only recolours. A shape listed in
    -- ns.UF_UNMASKED_RING (Pixels Circle) keeps its ring art outside the mask,
    -- inset from the backdrop by that many px at Size 7; each step below 7
    -- moves it 1px outward, as the size step expands every other shape's art.
    local sbt = backdrop._shapeBorderTex
    if not sbt then
        sbt = backdrop:CreateTexture(nil, "OVERLAY")
        backdrop._shapeBorderTex = sbt
    end
    local sbtMask, sbtMult = backdrop._shapeMask, PP.mult
    if sbt._gShape ~= shape or sbt._gExp ~= bExp or sbt._gMult ~= sbtMult or sbt._gMask ~= sbtMask then
        sbt._gShape, sbt._gExp, sbt._gMult, sbt._gMask = shape, bExp, sbtMult, sbtMask
        local ringInset = ns.UF_UNMASKED_RING[shape]
        local off = bExp - (ringInset or 0)
        sbt:ClearAllPoints()
        PP.Point(sbt, "TOPLEFT", backdrop, "TOPLEFT", -off, off)
        PP.Point(sbt, "BOTTOMRIGHT", backdrop, "BOTTOMRIGHT", off, -off)
        if sbtMask then
            pcall(sbt.RemoveMaskTexture, sbt, sbtMask)
            -- Mask the border too so its inner edge is clipped.
            if not ringInset then sbt:AddMaskTexture(sbtMask) end
        end
        local borderPath = PORTRAIT_BORDERS[shape]
        if borderPath then sbt:SetTexture(borderPath) end
    end
    if showBorder and PORTRAIT_BORDERS[shape] then
        sbt:SetVertexColor(bR, bG, bB, borderOpacity)
        sbt:Show()
    else
        sbt:Hide()
    end

    -- === Content positioning within mask ===
    -- Scale the portrait so its visible area fills the mask opening.
    -- MASK_INSETS[shape] = px from mask edge to visible area in the 128px mask.
    -- Content expands to fill the mask; border size does not affect content.
    local insetPx = MASK_INSETS[shape] or 17
    local bw = backdrop:GetWidth()
    local bh2 = backdrop:GetHeight()
    if bw < 1 then bw = 46 end
    if bh2 < 1 then bh2 = 46 end
    local visRatio = (128 - 2 * insetPx) / 128
    local cScale = 1 / visRatio
    -- User art scale, stored as a percentage (100 = default).
    local artScale = ((uSettings and uSettings.portraitArtScale) or 100) / 100
    cScale = cScale * artScale
    local expand = (cScale - 1) * 0.5
    local oL = -(expand * bw)
    local oR =  (expand * bw)
    local oT =  (expand * bh2)
    local oB = -(expand * bh2)
    if backdrop._2d then
        backdrop._2d:ClearAllPoints()
        PP.Point(backdrop._2d, "TOPLEFT", backdrop, "TOPLEFT", oL, oT)
        PP.Point(backdrop._2d, "BOTTOMRIGHT", backdrop, "BOTTOMRIGHT", oR, oB)
    end
    if backdrop._class then
        local classInset = math.floor(bh2 * 0.08)
        ns.UF_SetClassPortraitPoints(backdrop._class, backdrop,
            uSettings and uSettings.portraitClassZoom, classInset + oL, classInset - oT)
    end
    if backdrop._3d then
        -- 3D models ignore SetClipsChildren, so keep them inside the backdrop
        -- bounds. Art scale is not applied to 3D (camera zoom is fixed).
        backdrop._3d:ClearAllPoints()
        PP.Point(backdrop._3d, "TOPLEFT", backdrop, "TOPLEFT", 0, 0)
        PP.Point(backdrop._3d, "BOTTOMRIGHT", backdrop, "BOTTOMRIGHT", 0, 0)
    end

    -- Outer Ring / Inner Shadow (round shapes); nothing built while off.
    ns.UF_PortraitExtras(backdrop, uSettings, shape)
end
local function CreatePortrait(frame, side, frameHeight, unit)
    local portraitHeight = frameHeight or 46
    local uKey = UnitToSettingsKey(unit)
    local uSettings = uKey and db.profile[uKey]
    local portraitStyle = (uSettings and uSettings.portraitStyle) or db.profile.portraitStyle or "attached"
    -- Mini frames never use detached portraits.
    local isMiniP = unit and (unit == "pet" or unit == "targettarget" or unit == "focustarget" or unit:match("^boss%d$"))
    if isMiniP and portraitStyle == "detached" then portraitStyle = "attached" end
    -- Blizzard Style: the portrait sits in the stock art's ring, never detached
    -- and never off (the stock frames always carry one).
    if (portraitStyle == "detached" or portraitStyle == "none") and ns.UF_Blizz() then portraitStyle = "attached" end
    local isAttached = (portraitStyle == "attached")

    -- Per-unit size/offset adjustments.
    local pSizeAdj = (uSettings and uSettings.portraitSize) or 0
    local pXOff = (uSettings and uSettings.portraitX) or 0
    local pYOff = (uSettings and uSettings.portraitY) or 0
    local baseHeight = portraitHeight
    if not isAttached and not isInside and portraitStyle ~= "none" then pSizeAdj = pSizeAdj + 10; pYOff = pYOff + 5 end
    local adjustedHeight = baseHeight + pSizeAdj
    if adjustedHeight < 8 then adjustedHeight = 8 end

    -- Attached: "top" and "inside*" fall back to the default side.
    local effectiveSide = side
    local isInside = (side == "insideleft" or side == "insideright" or side == "insidecenter")
    if isAttached and (side == "top" or isInside) then
        effectiveSide = (unit == "player") and "left" or "right"
        isInside = false
    end

    local backdrop = CreateFrame("Frame", nil, frame)
    backdrop:SetFrameStrata(frame:GetFrameStrata())
    backdrop:SetFrameLevel(frame:GetFrameLevel() + 1)
    if isInside then
        -- Inside: portrait fills frame height, width = adjusted portrait size.
        PP.Size(backdrop, adjustedHeight, portraitHeight)
    else
        PP.Size(backdrop, adjustedHeight, adjustedHeight)
    end
    backdrop:SetClipsChildren(false)

    local bgTex = backdrop:CreateTexture(nil, "BACKGROUND")
    PP.Point(bgTex, "TOPLEFT", backdrop, "TOPLEFT", 0, 0)
    PP.Point(bgTex, "BOTTOMRIGHT", backdrop, "BOTTOMRIGHT", 0, 0)
    bgTex:SetColorTexture(0.1, 0.1, 0.1, 1)
    if isInside then bgTex:Hide() end
    backdrop._bg = bgTex

    if portraitStyle == "none" then
        -- Disabled: anchor the (hidden) backdrop to the frame corner, avoiding any
        -- dependency on frame.Health which may not exist yet.
        PP.Point(backdrop, "TOPLEFT", frame, "TOPLEFT", 0, 0)
    elseif isInside then
        -- Inside: overlays the health bar. Anchored to the frame initially;
        -- ReloadFrames re-anchors to frame.Health once layout resolves.
        backdrop._isInside = true
        backdrop:SetFrameLevel(frame:GetFrameLevel() + 3)
        PP.Point(backdrop, "TOPLEFT", frame, "TOPLEFT", pXOff, pYOff)
    elseif isAttached then
        if effectiveSide == "left" then
            PP.Point(backdrop, "TOPLEFT", frame, "TOPLEFT", 0, 0)
        else
            PP.Point(backdrop, "TOPRIGHT", frame, "TOPRIGHT", 0, 0)
        end
    else
        -- Detached: float outside the health bar edge.
        if effectiveSide == "top" then
            backdrop:SetPoint("BOTTOM", frame.Health or frame, "TOP", pXOff, 15 + pYOff)
        elseif effectiveSide == "left" then
            backdrop:SetPoint("TOPRIGHT", frame.Health or frame, "TOPLEFT", -15 + pXOff, pYOff)
        else
            backdrop:SetPoint("TOPLEFT", frame.Health or frame, "TOPRIGHT", 15 + pXOff, pYOff)
        end
        -- Raise a detached portrait above border/text/power.
        backdrop:SetFrameLevel(frame:GetFrameLevel() + 15)
    end

    -- 2D and class theme textures are eager; the 3D PlayerModel is deferred until
    -- 3D display or an enabled 2D mirror lookup needs it.
    local model3D = nil

    local function EnsureModel3D()
        if model3D then return model3D end
        model3D = CreateFrame("PlayerModel", nil, backdrop)
        PP.Point(model3D, "TOPLEFT", backdrop, "TOPLEFT", 0, 0)
        PP.Point(model3D, "BOTTOMRIGHT", backdrop, "BOTTOMRIGHT", 0, 0)
        model3D:SetCamera(0)
        local camScale = ((uSettings and uSettings.portrait3dZoom) or 100) / 100
        model3D:SetCamDistanceScale(camScale)
        -- Re-apply zoom and orientation after SetUnit resets the camera.
        model3D.PostUpdate = function(self)
            -- The frame engine does not assign an __owner to portraits.
            local u = frame._euiBaseUnit or frame._euiUnit
            if not u then return end
            local uk = UnitToSettingsKey(u)
            local us = uk and db.profile[uk]
            local cs = ((us and us.portrait3dZoom) or 100) / 100
            self:SetCamDistanceScale(cs)
            ns.UF_ApplyPortraitRotation(self, self.state and us and us.portraitMirror and not ns.UF_Blizz())
        end
        model3D:Hide()
        backdrop._3d = model3D
        return model3D
    end
    backdrop._ensureModel3D = EnsureModel3D

    local tex2D = backdrop:CreateTexture(nil, "ARTWORK")
    PP.Point(tex2D, "TOPLEFT", backdrop, "TOPLEFT", 0, 0)
    PP.Point(tex2D, "BOTTOMRIGHT", backdrop, "BOTTOMRIGHT", 0, 0)
    tex2D:SetTexCoord(0.15, 0.85, 0.15, 0.85)
    tex2D:Hide()
    -- A 2D mirror lookup that finished loading after the paint: repaint the flip
    -- when the frame still shows that unit.
    local function MirrorReady(guid)
        local u = frame._euiUnit
        if not (u and UnitIsConnected(u) and UnitIsVisible(u)) then return end
        local g = UnitGUID(u)
        if issecretvalue(g) or g ~= guid then return end
        tex2D:PostUpdate(u)
    end

    -- Class theme icon: painted by the engine portrait painter's class lane
    -- (element.isClass); this creation-time paint only seeds art before the
    -- first dispatch.
    local texClass = backdrop:CreateTexture(nil, "ARTWORK")
    local classInset = math.floor(portraitHeight * 0.08)
    ns.UF_SetClassPortraitPoints(texClass, backdrop,
        uSettings and uSettings.portraitClassZoom, classInset, classInset)
    texClass:SetAlpha(0.8)
    if unit and UnitIsPlayer(unit) then
        ns.UF_PaintClassIcon(texClass, unit, (uSettings and uSettings.classThemeStyle) or "modern",
            uSettings and uSettings.portraitMirror and not ns.UF_Blizz())
    end
    texClass:Hide()

    backdrop._3d = model3D
    backdrop._2d = tex2D
    backdrop._class = texClass

    local mode
    do
        mode = (uSettings and uSettings.portraitMode) or db.profile.portraitMode or "2d"
        -- Blizzard Style masks the 2D art: a 3D model cannot be masked, and
        -- the portrait is never off.
        if (mode == "3d" or mode == "none") and ns.UF_Blizz() then mode = "2d" end
    end
    -- portraitStyle/portraitMode "none" hides the backdrop but keeps the structure
    -- alive so ReloadFrames can show it again without a /reload.
    if portraitStyle == "none" or mode == "none" then
        backdrop:Hide()
        -- tex2D is a minimal placeholder so frame.Portrait is non-nil and carries a
        -- backdrop reference; it stays hidden with the backdrop.
        tex2D.backdrop = backdrop
        tex2D.is2D = true
        return tex2D
    end
    local active
    if mode == "class" then
        texClass:Show()
        tex2D:Hide()
        active = texClass
        active.isClass = true
    elseif mode == "2d" then
        tex2D:Show()
        active = tex2D
        active.is2D = true
    else
        local m3d = EnsureModel3D()
        m3d:Show()
        active = m3d
        active.is2D = false
    end
    active.backdrop = backdrop

    -- SetPortraitTexture resets snapping and anchor points, so re-disable pixel
    -- snap and re-anchor after every portrait repaint (PortraitOverride). hasStateChanged
    -- is set only by the 2D lane's call (the class lane's NPC paint passes none).
    tex2D.PostUpdate = function(self, u, hasStateChanged)
        UnsnapTex(self)
        self:ClearAllPoints()
        -- When detached, ApplyDetachedPortraitShape uses expanded offsets for mask
        -- fill; re-apply those instead of resetting to default.
        local uKey2 = UnitToSettingsKey(frame._euiBaseUnit or u)
        local uS2 = uKey2 and db.profile[uKey2]
        local isDetNow = ((uS2 and uS2.portraitStyle) or db.profile.portraitStyle or "attached") == "detached"
        if isDetNow and backdrop then
            local shape2 = (uS2 and uS2.detachedPortraitShape) or "portrait"
            local insetPx2 = MASK_INSETS[shape2] or 17
            local bw2 = backdrop:GetWidth()
            local bh3 = backdrop:GetHeight()
            if bw2 < 1 then bw2 = 46 end
            if bh3 < 1 then bh3 = 46 end
            local visR2 = (128 - 2 * insetPx2) / 128
            local cS2 = 1 / visR2
            local artS2 = ((uS2 and uS2.portraitArtScale) or 100) / 100
            cS2 = cS2 * artS2
            local exp2 = (cS2 - 1) * 0.5
            PP.Point(self, "TOPLEFT", backdrop, "TOPLEFT", -(exp2 * bw2), exp2 * bh3)
            PP.Point(self, "BOTTOMRIGHT", backdrop, "BOTTOMRIGHT", exp2 * bw2, -(exp2 * bh3))
        else
            PP.Point(self, "TOPLEFT", backdrop, "TOPLEFT", 0, 0)
            PP.Point(self, "BOTTOMRIGHT", backdrop, "BOTTOMRIGHT", 0, 0)
        end
        -- Mirror Portrait: the crop survives repaints, so it is written only
        -- when the flip state changes (the first on-to-off pass restores the
        -- creation crop). Never under a stock style (its full-art coords
        -- stand), and the unavailable question mark always reads unflipped.
        local mir = (uS2 and uS2.portraitMirror and not ns.UF_Blizz()
            and not (hasStateChanged and self.state == false)
            and ns.UF_CanMirrorPortrait2D(EnsureModel3D(), u, MirrorReady)) and true or false
        if mir ~= (self._mirrored or false) then
            self._mirrored = mir
            if mir then
                self:SetTexCoord(0.85, 0.15, 0.15, 0.85)
            else
                self:SetTexCoord(0.15, 0.85, 0.15, 0.85)
            end
        end
    end

    ApplyDetachedPortraitShape(backdrop, uSettings, unit)

    return active
end

-- Unlock position key for a unit's castbar, or nil.
local function CastbarUnlockKey(unit)
    if unit == "player" then return "playerCastbar"
    elseif unit == "target" then return "targetCastbar"
    elseif unit == "focus" then return "focusCastbar"
    end
end

-- Cast bar positioning is owned by the centralized unlock/anchor system
-- (ApplySavedPositions).

local function GetActiveKickSpell()
    return EllesmereUI.GetActiveKickSpell()
end
local function ComputeCastBarTint(readyTint, baseTint)
    if EllesmereUI and EllesmereUI.ComputeCastBarTint then
        return EllesmereUI.ComputeCastBarTint(readyTint, baseTint)
    end
    return baseTint.r, baseTint.g, baseTint.b
end
local function IsKickCastbarUnit(unit)
    return unit == "target" or unit == "focus" or (unit and unit:match("^boss") ~= nil)
end
local function GetCastbarKickTickEnabled(settings)
    if not settings then return true end
    if settings.castbarKickTickEnabled ~= nil then return settings.castbarKickTickEnabled end
    return true
end
local function GetCastbarInterruptMidCastEnabled(settings)
    if not settings then return false end
    if settings.castbarInterruptMidCastEnabled ~= nil then return settings.castbarInterruptMidCastEnabled end
    return false
end
local function GetCastbarUninterruptible(castbar)
    local v = castbar and castbar.notInterruptible
    if type(v) == "nil" then return false end
    return v
end
local function HideUnitFrameKickTick(castbar)
    if not castbar or not castbar.kickPositioner then return end
    castbar.kickPositioner:Hide()
    castbar.kickMarker:Hide()
    castbar.kickReadyFill:Hide()
    if castbar._kickTicker then
        castbar._kickTicker:Cancel()
        castbar._kickTicker = nil
    end
end
-- Hoisted defaults for the zero-alloc paint below: as inline literals these would
-- allocate on EVERY call when the setting was absent (the common case).
local UF_KICK_READY_TINT = { r = 0.92, g = 0.35, b = 0.20 }
local UF_UNINTERRUPT_GREY = { r = 0.5, g = 0.5, b = 0.5 }
local function ApplyUnitFrameCastColor(castbar)
    if not castbar or not castbar.castTintLayer then return end
    local settings = castbar._eufSettings
    local ownerUnit = castbar.__owner and castbar.__owner._euiUnit
    -- Zero-alloc: values flow as scalars instead of building up to three throwaway
    -- color tables per call (two default literals + the blended kick tint).
    local r, g, b
    if settings and settings.castbarClassColored and ownerUnit == "player" then
        local _, classToken = UnitClass(ownerUnit)
        if issecretvalue(classToken) then classToken = nil end
        if classToken and EllesmereUI.GetClassColor then
            local cc = EllesmereUI.GetClassColor(classToken)
            if cc then r, g, b = cc.r, cc.g, cc.b end
        end
    end
    if not r then
        local baseTint = (settings and settings.castbarFillColor) or GetCastbarColor()
        if IsKickCastbarUnit(ownerUnit) then
            local readyTint = (settings and settings.castbarInterruptReadyColor) or UF_KICK_READY_TINT
            r, g, b = ComputeCastBarTint(readyTint, baseTint)
        else
            r, g, b = baseTint.r, baseTint.g, baseTint.b
        end
    end
    castbar.castTintLayer:SetVertexColor(r, g, b)
    if castbar._shieldedTint then
        -- Uninterruptible overlay colour (defaults to grey). Its alpha is toggled
        -- from the secret "not interruptible" flag, so the colour is always set and
        -- only becomes visible on uninterruptible casts.
        local uc = (settings and settings.castbarUninterruptibleColor) or UF_UNINTERRUPT_GREY
        -- Explicit vertex alpha: Midnight's 3-arg SetVertexColor leaves the
        -- vertex alpha at an unexpected value (measured 0.5 with the gray
        -- default -- GetVertexColor returned a=r), and the composite with the
        -- region alpha rendered the shield faint-to-invisible. Visibility
        -- stays owned by SetAlphaFromBoolean below on the region slot.
        castbar._shieldedTint:SetVertexColor(uc.r, uc.g, uc.b, 1)
        local uninterruptible = GetCastbarUninterruptible(castbar)
        -- Visible alpha honors Fill Opacity (castbar._fillOp, nil at 100); both
        -- branches pass it as a plain number, never touching the secret. The
        -- boolean alpha drives the HOST FRAME -- texture SetAlphaFromBoolean
        -- renders 0 on Midnight despite healthy readbacks (see creation).
        local shieldTarget = castbar._shieldHost or castbar._shieldedTint
        if shieldTarget.SetAlphaFromBoolean then
            shieldTarget:SetAlphaFromBoolean(uninterruptible, castbar._fillOp or 1, 0)
        else
            shieldTarget:SetAlpha(uninterruptible and (castbar._fillOp or 1) or 0)
        end
    end
end
local function UpdateUnitFrameKickTick(castbar)
    if not castbar or not castbar.kickPositioner then return end
    local settings = castbar._eufSettings
    local ownerUnit = castbar.__owner and castbar.__owner._euiUnit
    if not IsKickCastbarUnit(ownerUnit) then
        HideUnitFrameKickTick(castbar)
        return
    end
    local tickOn = GetCastbarKickTickEnabled(settings)
    local midOn = GetCastbarInterruptMidCastEnabled(settings)
    if (not (tickOn or midOn)) or not GetActiveKickSpell() then
        HideUnitFrameKickTick(castbar)
        return
    end
    if not (C_Spell and C_Spell.GetSpellCooldownDuration) then
        HideUnitFrameKickTick(castbar)
        return
    end
    local kickProtected = GetCastbarUninterruptible(castbar)
    castbar._kickProtected = kickProtected
    local isChannel = castbar.channeling and true or false
    local isEmpowered = false
    if not (UnitCastingDuration and ownerUnit) then
        HideUnitFrameKickTick(castbar)
        return
    end
    local castDuration
    if isChannel then
        if UnitEmpoweredChannelDuration then
            castDuration = UnitEmpoweredChannelDuration(ownerUnit, true)
            if castDuration then isEmpowered = true end
        end
        if not castDuration and UnitChannelDuration then
            castDuration = UnitChannelDuration(ownerUnit)
        end
    else
        castDuration = UnitCastingDuration(ownerUnit)
    end
    if not castDuration then
        -- Transient read miss during an ongoing cast: skip, do NOT hide (a Hide/re-Show
        -- cycle on every SPELL_UPDATE_COOLDOWN would blink the tick during rotation).
        -- Cast end is handled by the cast-stop path.
        return
    end
    -- Cache cast identity so the light per-event refresh re-pins bar values from it
    -- without re-deriving channel/empower or re-minting fill geometry.
    castbar._kickIsChannel = isChannel
    castbar._kickIsEmpowered = isEmpowered
    local totalDur = castDuration:GetTotalDuration()
    local interruptCD = C_Spell.GetSpellCooldownDuration(GetActiveKickSpell())
    if not interruptCD then
        -- Transient read miss (see above): skip, do not hide.
        return
    end
    local barW = castbar:GetWidth()
    local barH = castbar:GetHeight()
    -- Blizzard Style: a bar hanging off its frame's aura block resolves its
    -- rect through the engine aura container, a secret value under aura
    -- restriction. The tick keeps the size it took out of combat (the bar
    -- never resizes in combat), so nothing here may compare a secret.
    if issecretvalue(barW) or issecretvalue(barH) then return end
    if not barW or barW <= 0 then
        -- Transient zero-width during resize: skip, do not hide.
        return
    end
    castbar.kickPositioner:SetSize(barW, barH)
    castbar.kickPositioner:SetMinMaxValues(0, totalDur)
    castbar.kickMarker:SetMinMaxValues(0, totalDur)
    castbar.kickMarker:SetSize(barW, barH)
    castbar.kickPositioner:SetValue(castDuration:GetElapsedDuration())
    castbar.kickMarker:SetValue(interruptCD:GetRemainingDuration())
    castbar.kickTick:SetColorTexture(1, 1, 1, 1)
    if isChannel and not isEmpowered then
        castbar.kickPositioner:SetFillStyle(Enum.StatusBarFillStyle.Reverse)
        castbar.kickMarker:SetFillStyle(Enum.StatusBarFillStyle.Reverse)
        -- LOAD-BEARING: SetFillStyle resets the inner fill to snap-ON and the global
        -- hook does not re-fire on a cached bar. Re-disable snap so the summed
        -- elapsed+remaining edge stays an exact float.
        local pt = castbar.kickPositioner:GetStatusBarTexture()
        if pt and pt.SetSnapToPixelGrid then pt:SetSnapToPixelGrid(false); pt:SetTexelSnappingBias(0) end
        local mt = castbar.kickMarker:GetStatusBarTexture()
        if mt and mt.SetSnapToPixelGrid then mt:SetSnapToPixelGrid(false); mt:SetTexelSnappingBias(0) end
        castbar.kickMarker:ClearAllPoints()
        castbar.kickTick:ClearAllPoints()
        castbar.kickMarker:SetPoint("RIGHT", castbar.kickPositioner:GetStatusBarTexture(), "LEFT")
        castbar.kickTick:SetPoint("TOP", castbar.kickMarker, "TOP", 0, 0)
        castbar.kickTick:SetPoint("BOTTOM", castbar.kickMarker, "BOTTOM", 0, 0)
        castbar.kickTick:SetPoint("RIGHT", castbar.kickMarker:GetStatusBarTexture(), "LEFT")
        -- Reverse fill (draining channel): kick-ready point is the marker texture LEFT
        -- edge; the available window runs from the channel end (bar left) to it.
        -- Not-in-time pushes that edge past the left edge, crossing anchors to zero width.
        castbar.kickReadyFill:ClearAllPoints()
        castbar.kickReadyFill:SetPoint("TOP", castbar, "TOP", 0, 0)
        castbar.kickReadyFill:SetPoint("BOTTOM", castbar, "BOTTOM", 0, 0)
        castbar.kickReadyFill:SetPoint("LEFT", castbar, "LEFT", 0, 0)
        castbar.kickReadyFill:SetPoint("RIGHT", castbar.kickMarker:GetStatusBarTexture(), "LEFT")
    else
        castbar.kickPositioner:SetFillStyle(Enum.StatusBarFillStyle.Standard)
        castbar.kickMarker:SetFillStyle(Enum.StatusBarFillStyle.Standard)
        -- LOAD-BEARING: re-disable snap on the re-minted fill textures (see the
        -- reverse branch) so the tick stays stationary across every re-pin.
        local pt = castbar.kickPositioner:GetStatusBarTexture()
        if pt and pt.SetSnapToPixelGrid then pt:SetSnapToPixelGrid(false); pt:SetTexelSnappingBias(0) end
        local mt = castbar.kickMarker:GetStatusBarTexture()
        if mt and mt.SetSnapToPixelGrid then mt:SetSnapToPixelGrid(false); mt:SetTexelSnappingBias(0) end
        castbar.kickMarker:ClearAllPoints()
        castbar.kickTick:ClearAllPoints()
        castbar.kickMarker:SetPoint("LEFT", castbar.kickPositioner:GetStatusBarTexture(), "RIGHT")
        castbar.kickTick:SetPoint("TOP", castbar.kickMarker, "TOP", 0, 0)
        castbar.kickTick:SetPoint("BOTTOM", castbar.kickMarker, "BOTTOM", 0, 0)
        castbar.kickTick:SetPoint("LEFT", castbar.kickMarker:GetStatusBarTexture(), "RIGHT")
        -- Standard fill (cast/empowered channel): kick-ready point is the marker
        -- texture RIGHT edge; the window runs from it to the cast end (bar right).
        -- Not-in-time pushes that edge past the right edge, crossing anchors to zero width.
        castbar.kickReadyFill:ClearAllPoints()
        castbar.kickReadyFill:SetPoint("TOP", castbar, "TOP", 0, 0)
        castbar.kickReadyFill:SetPoint("BOTTOM", castbar, "BOTTOM", 0, 0)
        castbar.kickReadyFill:SetPoint("LEFT", castbar.kickMarker:GetStatusBarTexture(), "RIGHT")
        castbar.kickReadyFill:SetPoint("RIGHT", castbar, "RIGHT", 0, 0)
    end
    castbar.kickPositioner:Show()
    castbar.kickMarker:Show()
    -- Mid-cast fill: CLEAN DB color tint + CLEAN per-toggle visibility; its alpha (the
    -- SECRET on-CD x interruptible gate) is applied with the tick alpha below. Geometry
    -- above runs whenever the tick OR fill is enabled; SetShown gates each element to
    -- its own toggle so one never forces the other.
    local mc = (settings and settings.castbarInterruptMidCastColor) or { r = 0.318, g = 0.820, b = 0.357 }
    castbar.kickReadyFill:SetVertexColor(mc.r, mc.g, mc.b, 1)
    castbar.kickTick:SetShown(tickOn)
    castbar.kickReadyFill:SetShown(midOn)
    if interruptCD.IsZero and C_CurveUtil and C_CurveUtil.EvaluateColorValueFromBoolean then
        local interruptible = C_CurveUtil.EvaluateColorValueFromBoolean(kickProtected, 0, 1)
        local kickReady = interruptCD:IsZero()
        local alpha = C_CurveUtil.EvaluateColorValueFromBoolean(kickReady, 0, interruptible)
        castbar.kickTick:SetAlpha(alpha)
        castbar.kickReadyFill:SetAlpha(alpha)
    else
        castbar.kickTick:SetAlpha(0)
        castbar.kickReadyFill:SetAlpha(0)
    end
    if castbar._kickTicker then castbar._kickTicker:Cancel() end
    castbar._kickTicker = C_Timer.NewTicker(0.1, function()
        if not castbar:IsShown() or not ownerUnit then
            HideUnitFrameKickTick(castbar)
            return
        end
        if not GetActiveKickSpell() then
            HideUnitFrameKickTick(castbar)
            return
        end
        local icd = C_Spell.GetSpellCooldownDuration(GetActiveKickSpell())
        if icd and icd.IsZero and C_CurveUtil and C_CurveUtil.EvaluateColorValueFromBoolean then
            local interruptible = C_CurveUtil.EvaluateColorValueFromBoolean(castbar._kickProtected, 0, 1)
            local kickReady = icd:IsZero()
            local alpha = C_CurveUtil.EvaluateColorValueFromBoolean(kickReady, 0, interruptible)
            castbar.kickTick:SetAlpha(alpha)
            castbar.kickReadyFill:SetAlpha(alpha)
        end
    end)
end

-- Light per-cooldown-event refresh: bar values + tick alpha only. Geometry (SetSize,
-- anchors, SetFillStyle, color) is cast-identity work done once by
-- UpdateUnitFrameKickTick. Re-pin positioner(elapsed) and marker(remaining) together to
-- keep the tick stationary; NEVER re-pin one without the other.
local function RefreshUnitFrameKickTick(castbar)
    if not castbar or not castbar.kickPositioner then return end
    if not GetActiveKickSpell() or not (C_Spell and C_Spell.GetSpellCooldownDuration) then
        HideUnitFrameKickTick(castbar)
        return
    end
    local interruptCD = C_Spell.GetSpellCooldownDuration(GetActiveKickSpell())
    if not interruptCD then
        -- Transient read miss during an ongoing cast: skip, do not hide.
        return
    end
    local ownerUnit = castbar.__owner and castbar.__owner._euiUnit
    if not (UnitCastingDuration and ownerUnit) then return end
    local castDuration
    if castbar._kickIsChannel then
        if castbar._kickIsEmpowered and UnitEmpoweredChannelDuration then
            castDuration = UnitEmpoweredChannelDuration(ownerUnit, true)
        end
        if not castDuration and UnitChannelDuration then
            castDuration = UnitChannelDuration(ownerUnit)
        end
    else
        castDuration = UnitCastingDuration(ownerUnit)
    end
    if not castDuration then
        -- Transient read miss (see above): skip, do not hide.
        return
    end
    castbar.kickPositioner:SetValue(castDuration:GetElapsedDuration())
    castbar.kickMarker:SetValue(interruptCD:GetRemainingDuration())
    if interruptCD.IsZero and C_CurveUtil and C_CurveUtil.EvaluateColorValueFromBoolean then
        local interruptible = C_CurveUtil.EvaluateColorValueFromBoolean(castbar._kickProtected, 0, 1)
        local alpha = C_CurveUtil.EvaluateColorValueFromBoolean(interruptCD:IsZero(), 0, interruptible)
        castbar.kickTick:SetAlpha(alpha)
        castbar.kickReadyFill:SetAlpha(alpha)
    end
end

ns._castingCastbars = {}
local activeCastbarCount = 0
local _ufCastColorTicker
local ufKickWatcher = CreateFrame("Frame")
ufKickWatcher:SetScript("OnEvent", function(_, event)
    if event == "SPELL_UPDATE_COOLDOWN" or event == "SPELL_UPDATE_USABLE" then
        for cb in pairs(ns._castingCastbars) do
            if cb:IsShown() and cb.__owner and cb.__owner._euiUnit then
                ApplyUnitFrameCastColor(cb)
                -- Light refresh once the kick bars are set up; re-run the full geometry/
                -- fill setup only when not shown (kick learned mid-cast, CD info late,
                -- toggle flipped on). Stops SetFillStyle from re-minting the inner fill
                -- textures every cooldown event, which re-snapped them to the pixel grid.
                if cb.kickPositioner and not cb.kickPositioner:IsShown() then
                    UpdateUnitFrameKickTick(cb)
                else
                    RefreshUnitFrameKickTick(cb)
                end
            end
        end
    end
end)
local function NotifyCastbarStarted(castbar)
    if not castbar or not castbar.__owner then return end
    if not IsKickCastbarUnit(castbar.__owner._euiUnit) then return end
    if ns._castingCastbars[castbar] then return end
    ns._castingCastbars[castbar] = true
    activeCastbarCount = activeCastbarCount + 1
    if activeCastbarCount == 1 then
        ufKickWatcher:RegisterEvent("SPELL_UPDATE_COOLDOWN")
        ufKickWatcher:RegisterEvent("SPELL_UPDATE_USABLE")
        if GetActiveKickSpell() and not _ufCastColorTicker then
            _ufCastColorTicker = C_Timer.NewTicker(0.2, function()
                for cb in pairs(ns._castingCastbars) do
                    if cb:IsShown() then
                        ApplyUnitFrameCastColor(cb)
                    end
                end
            end)
        end
    end
end
local function NotifyCastbarEnded(castbar)
    if not castbar or not ns._castingCastbars[castbar] then return end
    ns._castingCastbars[castbar] = nil
    activeCastbarCount = activeCastbarCount - 1
    if activeCastbarCount <= 0 then
        activeCastbarCount = 0
        wipe(ns._castingCastbars)
        ufKickWatcher:UnregisterEvent("SPELL_UPDATE_COOLDOWN")
        ufKickWatcher:UnregisterEvent("SPELL_UPDATE_USABLE")
        if _ufCastColorTicker then
            _ufCastColorTicker:Cancel()
            _ufCastColorTicker = nil
        end
    end
end

local function CreateCastBar(frame, unit, settings)
    local settings = GetSettingsForUnit(unit)
    
    -- Standalone element parented to the oUF frame for compatibility, but sized
    -- and positioned independently. Blizzard Style: created with the layout
    -- aspect so it can hang off the frame's aura block (see ns.UF_LayoutAspectOK);
    -- its pieces below are all children and inherit it.
    local aspectTemplate = ns.UF_CastbarAspectTemplate(unit)
    local castbarBg = CreateFrame("Frame", nil, frame, aspectTemplate)
    if aspectTemplate then castbarBg._blizzAspect = true end

    -- Width/height always come from settings; nothing is auto-derived.
    local cbWidth, cbHeight
    if unit == "player" then
        cbWidth = db.profile.player.playerCastbarWidth or 181
        cbHeight = db.profile.player.playerCastbarHeight or 14
    else
        -- castbarWidth 0 = auto (boss frames match frame width; the boss update
        -- pass re-sizes to the live frame width right after creation).
        local cbw = settings.castbarWidth or 0
        cbWidth = cbw > 0 and cbw or 181
        cbHeight = settings.castbarHeight or 14
    end
    PP.Size(castbarBg, cbWidth, cbHeight)

    -- Position is owned by the centralized unlock system; this temporary anchor
    -- just gives the frame valid bounds until ApplySavedPositions runs at login
    -- (unlock default: BOTTOM of the parent unit frame).
    castbarBg:SetPoint("TOP", frame, "BOTTOM", 0, 0)

    local bgTex = castbarBg:CreateTexture(nil, "BACKGROUND")
    PP.Point(bgTex, "TOPLEFT", castbarBg, "TOPLEFT", 0, 0)
    PP.Point(bgTex, "BOTTOMRIGHT", castbarBg, "BOTTOMRIGHT", 0, 0)
    -- Background color/alpha default to black 0.5 unless castBgColor/castBgAlpha
    -- are set.
    local _cbgC = settings.castBgColor
    bgTex:SetColorTexture(_cbgC and _cbgC.r or 0, _cbgC and _cbgC.g or 0, _cbgC and _cbgC.b or 0, settings.castBgAlpha or 0.5)
    castbarBg._bgTex = bgTex

    local castbar = CreateFrame("StatusBar", nil, castbarBg)
    PP.Point(castbar, "TOPLEFT", castbarBg, "TOPLEFT", 0, 0)
    PP.Point(castbar, "BOTTOMRIGHT", castbarBg, "BOTTOMRIGHT", 0, 0)
    castbar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    castbar:GetStatusBarTexture():SetHorizTile(false)
    castbar:SetReverseFill(settings.castReverseFill and true or false)

    -- Borders draw on the castbar itself (same frame level as the fill texture) so
    -- the OVERLAY border sits above the ARTWORK fill. On castbarBg they would land
    -- BEHIND the fill, since castbar is its child and draws above it.
    PP.CreateBorder(castbar, 0, 0, 0, 1, 1, "OVERLAY", 0)


    -- Three-zone cast bar text layout matching nameplates: [spell name LEFT 42%]
    -- [target RIGHT-of-center 42%] [timer RIGHT]. All zones ellipsize (WordWrap off,
    -- MaxLines 1); text overlay sits above the unified border (frame +10).
    local textOverlay = CreateFrame("Frame", nil, castbar)
    textOverlay:SetAllPoints(castbar)
    textOverlay:SetFrameLevel(frame:GetFrameLevel() + 11)

    local text = textOverlay:CreateFontString(nil, "OVERLAY")
    SetFSFont(text, settings.castSpellNameSize or 11)
    text:SetJustifyH("LEFT")
    text:SetWordWrap(false)
    text:SetMaxLines(1)
    text:SetTextColor(1, 1, 1)
    castbar.Text = text

    local time = textOverlay:CreateFontString(nil, "OVERLAY")
    SetFSFont(time, settings.castDurationSize or 10)
    time:SetJustifyH("RIGHT")
    time:SetWordWrap(false)
    time:SetMaxLines(1)
    time:SetTextColor(1, 1, 1)
    castbar.Time = time

    local target = textOverlay:CreateFontString(nil, "OVERLAY")
    SetFSFont(target, settings.castSpellTargetSize or 11)
    target:SetJustifyH("RIGHT")
    target:SetWordWrap(false)
    target:SetMaxLines(1)
    target:SetTextColor(1, 1, 1)
    target:Hide()
    castbar.Target = target

    -- Side-aware three-zone layout (mirrors the nameplate cast text system). Each
    -- element has a side; duration reserves its slot and pushes whichever non-center
    -- element shares that side (center is never pushed). Spell name hides on side
    -- "none"; target/duration visibility rides _showTarget/_showDuration (their
    -- dropdown "None" clears those flags).
    local function LayoutCastTextZones(cb)
        local barW = cb:GetWidth()
        -- Secret under aura restriction when the bar rides the aura block
        -- (Blizzard Style): keep the out-of-combat layout, the width is fixed.
        if issecretvalue(barW) then return end
        if not barW or barW <= 0 then return end
        -- +5px so the timer text has a little extra room before it truncates.
        local timerW = (cb._durationSize or 10) * 2.2 + 5
        local showDur = cb._showDuration ~= false
        local nameSide = cb._nameSide or "left"
        local tgtSide  = cb._tgtSide or "right"
        local durSide  = cb._durSide or "right"
        local textW = barW * 0.42
        -- The 42% reserves the opposite half for the cast target. When this unit never
        -- shows a target (boss frames: showCastTarget false with no UI to enable it)
        -- the name owns the row and gets 80% before truncating.
        local nameW = (cb._showTarget == false) and (barW * 0.80) or textW
        -- Combine Spell Name and Target suppresses the target element, so the combined
        -- name owns the row and gets the wide budget.
        cb.Text:ClearAllPoints()
        if nameSide == "none" then
            cb.Text:Hide()
        else
            local pt, xb, jh = ns.GetCastTextAnchor(nameSide, showDur and durSide == nameSide, timerW, false)
            cb.Text:SetWidth(cb._combineNT and (barW * 0.80) or nameW)
            cb.Text:SetJustifyH(jh)
            cb.Text:SetPoint(pt, cb, pt, xb + (cb._nameOX or 0), 1 + (cb._nameOY or 0))
            cb.Text:Show()
        end
        -- Spell target; visibility is handled by _showTarget / hasTarget elsewhere.
        do
            local pt, xb, jh = ns.GetCastTextAnchor(tgtSide, showDur and durSide == tgtSide, timerW, false)
            cb.Target:ClearAllPoints()
            cb.Target:SetWidth(textW)
            cb.Target:SetJustifyH(jh)
            cb.Target:SetPoint(pt, cb, pt, xb + (cb._tgtOX or 0), (cb._tgtOY or 0))
        end
        -- Duration/timer: side is only "left"/"right"; visibility via _showDuration.
        do
            local pt, xb, jh = ns.GetCastTextAnchor(durSide, false, timerW, true)
            cb.Time:ClearAllPoints()
            cb.Time:SetWidth(timerW)
            cb.Time:SetJustifyH(jh)
            cb.Time:SetPoint(pt, cb, pt, xb + (cb._durOX or 0), (cb._durOY or 0))
        end
        -- Re-flow so a live JustifyH change takes effect on already-rendered text.
        ns.ReflowFontString(cb.Text)
        ns.ReflowFontString(cb.Target)
        ns.ReflowFontString(cb.Time)
    end
    castbar._durationSize = settings.castDurationSize or 10
    castbar._nameOX = settings.castSpellNameX or 0
    castbar._nameOY = settings.castSpellNameY or 0
    castbar._durOX = settings.castDurationX or 0
    castbar._durOY = settings.castDurationY or 0
    castbar._tgtOX = settings.castSpellTargetX or 0
    castbar._tgtOY = settings.castSpellTargetY or 0
    castbar._nameSide = settings.castSpellNameSide or "left"
    castbar._tgtSide  = settings.castSpellTargetSide or "right"
    castbar._durSide  = settings.castDurationSide or "right"
    castbar._showDuration = settings.showCastDuration ~= false
    castbar._showTarget = settings.showCastTarget ~= false
    castbar._layoutTextZones = LayoutCastTextZones
    LayoutCastTextZones(castbar)

    -- Helper: sync all offset/size/side cache values from settings onto
    -- the castbar, then re-layout. Called from live refresh paths.
    castbar._syncOffsetsAndLayout = function(self, s)
        self._durationSize = s.castDurationSize or 10
        self._nameOX = s.castSpellNameX or 0
        self._nameOY = s.castSpellNameY or 0
        self._durOX  = s.castDurationX or 0
        self._durOY  = s.castDurationY or 0
        self._tgtOX  = s.castSpellTargetX or 0
        self._tgtOY  = s.castSpellTargetY or 0
        self._nameSide = s.castSpellNameSide or "left"
        self._tgtSide  = s.castSpellTargetSide or "right"
        self._durSide  = s.castDurationSide or "right"
        self._showDuration = s.showCastDuration ~= false
        if self._layoutTextZones then self:_layoutTextZones() end
    end

    local castTintLayer = castbar:CreateTexture(nil, "ARTWORK", nil, 1)
    castTintLayer:SetPoint("TOPLEFT", castbar:GetStatusBarTexture(), "TOPLEFT")
    castTintLayer:SetPoint("BOTTOMRIGHT", castbar:GetStatusBarTexture(), "BOTTOMRIGHT")
    castTintLayer:SetTexture("Interface\\Buttons\\WHITE8X8")
    local c = GetCastbarColor()
    castTintLayer:SetVertexColor(c.r, c.g, c.b)
    castTintLayer:SetAlpha(0)
    castbar.castTintLayer = castTintLayer
    castbar._castTintOn = nil

    -- The shield tint lives on its own child FRAME: the secret-safe show/hide
    -- rides SetAlphaFromBoolean, and on Midnight that API renders 0 on
    -- TEXTURES while GetAlpha reads back the true-branch value (measured
    -- 2026-08-12 -- perfect state readbacks, nothing painted). Frame alpha is
    -- the proven boolean lane (range fading uses it suite-wide).
    local shieldHost = CreateFrame("Frame", nil, castbar)
    shieldHost:SetAllPoints(castbar)
    shieldHost:SetAlpha(0)
    local shieldedTint = shieldHost:CreateTexture(nil, "ARTWORK", nil, 2)
    shieldedTint:SetPoint("TOPLEFT", castbar:GetStatusBarTexture(), "TOPLEFT")
    shieldedTint:SetPoint("BOTTOMRIGHT", castbar:GetStatusBarTexture(), "BOTTOMRIGHT")
    shieldedTint:SetTexture("Interface\\Buttons\\WHITE8X8")
    shieldedTint:SetVertexColor(0.5, 0.5, 0.5, 1)
    castbar._shieldedTint = shieldedTint
    castbar._shieldHost = shieldHost

    -- Cast bar reuses the unit's health bar texture (overridden donor-aware in ReloadFrames).
    ns.ApplyCastBarTexture(castbar, (settings and settings.healthBarTexture) or db.profile.healthBarTexture or "none")
    ns.ApplyCastFillOpacity(castbar, settings)

    local function OnCastbarCastActive(self)
        if self.castTintLayer then
            -- _fillOp is nil unless Fill Opacity is below 100 (see
            -- ns.ApplyCastFillOpacity), so the default path is unchanged.
            self.castTintLayer:SetAlpha(self._fillOp or 1)
            self._castTintOn = true
            ApplyUnitFrameCastColor(self)
            -- Blizzard Style: the fill art is its own colour, per cast kind.
            if self._blizzCast then
                self.castTintLayer:SetAlpha(0)
                self._castTintOn = nil
                ns.UF_SetBlizzCastFill(self, self.channeling and "channel" or "cast")
            end
        end
    end
    castbar.PostCastStart = OnCastbarCastActive
    castbar.PostChannelStart = OnCastbarCastActive

    castbar.PostCastInterruptible = function(self)
        ApplyUnitFrameCastColor(self)
        UpdateUnitFrameKickTick(self)
    end

    if IsKickCastbarUnit(unit) then
        local kickClip = CreateFrame("Frame", nil, castbar)
        kickClip:SetAllPoints(castbar)
        kickClip:SetClipsChildren(true)
        castbar.kickClip = kickClip
        local kickPositioner = CreateFrame("StatusBar", nil, kickClip)
        kickPositioner:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
        kickPositioner:GetStatusBarTexture():SetAlpha(0)
        -- Pixel-snap OFF on the fill texture (mirrors Nameplates). The tick sits
        -- at positioner_width + marker_width; independent per-fill snapping makes
        -- round(a) + round(b) wobble 1px even though the summed fraction is
        -- invariant. Load-bearing unsnap is after each SetFillStyle below.
        if kickPositioner:GetStatusBarTexture().SetSnapToPixelGrid then
            kickPositioner:GetStatusBarTexture():SetSnapToPixelGrid(false)
            kickPositioner:GetStatusBarTexture():SetTexelSnappingBias(0)
        end
        kickPositioner:SetPoint("CENTER", castbar)
        kickPositioner:SetFrameLevel(castbar:GetFrameLevel() + 1)
        kickPositioner:Hide()
        castbar.kickPositioner = kickPositioner
        local kickMarker = CreateFrame("StatusBar", nil, kickClip)
        kickMarker:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
        kickMarker:GetStatusBarTexture():SetAlpha(0)
        if kickMarker:GetStatusBarTexture().SetSnapToPixelGrid then
            kickMarker:GetStatusBarTexture():SetSnapToPixelGrid(false)
            kickMarker:GetStatusBarTexture():SetTexelSnappingBias(0)
        end
        kickMarker:SetPoint("LEFT", kickPositioner:GetStatusBarTexture(), "RIGHT")
        kickMarker:SetSize(1, 1)
        kickMarker:SetFrameLevel(castbar:GetFrameLevel() + 2)
        kickMarker:Hide()
        castbar.kickMarker = kickMarker
        local kickTick = kickMarker:CreateTexture(nil, "OVERLAY", nil, 3)
        kickTick:SetColorTexture(1, 1, 1, 1)
        kickTick:SetWidth(2)
        kickTick:SetPoint("TOP", kickMarker, "TOP", 0, 0)
        kickTick:SetPoint("BOTTOM", kickMarker, "BOTTOM", 0, 0)
        kickTick:SetPoint("LEFT", kickMarker:GetStatusBarTexture(), "RIGHT")
        castbar.kickTick = kickTick
        -- Interrupt-ready mid-cast fill: colors the cast-bar segment from the "kick
        -- ready here" point to the cast end (the window during which the interrupt will
        -- be available) when the kick is on cooldown now but comes off before the cast
        -- finishes. Rides the SAME kickMarker geometry as the tick; the "ready in time"
        -- two-secret test resolves by where the marker texture edge lands -- when the
        -- kick will NOT be ready in time the fill anchors cross to zero width and it
        -- self-hides with no Lua branch on a secret. ARTWORK sublevel 1 (created after
        -- castTintLayer so it draws above the fill colour) sits below the cast text
        -- (OVERLAY) and the uninterruptible grey (sublevel 2). Anchors are (re)applied
        -- per cast in UpdateUnitFrameKickTick.
        local kickReadyFill = castbar:CreateTexture(nil, "ARTWORK", nil, 1)
        kickReadyFill:SetColorTexture(1, 1, 1, 1)
        kickReadyFill:SetAlpha(0)
        kickReadyFill:Hide()
        castbar.kickReadyFill = kickReadyFill
    end

    castbar.CustomTimeText = function(self, durationObject)
        if self._showDuration == false then
            self.Time:SetText("")
            self.Time:Hide()
            self._timeBucket = nil
            return
        end
        self.Time:Show()
        if durationObject then
            -- oUF calls this per RENDER FRAME, but the displayed value has %.1f
            -- precision -- format + SetText only when the displayed tenth actually
            -- changes (~6x fewer at 60fps, more uncapped). Secret durations (other
            -- units' casts in combat) can't be floored: fail open to formatting every
            -- call (SetFormattedText accepts secrets). The delay branch is rare
            -- (pushback) and stays unmemoized.
            local duration = durationObject:GetRemainingDuration()
            if self.delay and self.delay ~= 0 then
                self._timeBucket = nil
                self.Time:SetFormattedText('%.1f|cffff0000%s%.2f|r', duration, self.channeling and '-' or '+', self.delay)
            elseif issecretvalue and issecretvalue(duration) then
                self._timeBucket = nil
                self.Time:SetFormattedText('%.1f', duration)
            else
                local bucket = math.floor(duration * 10)
                if bucket ~= self._timeBucket then
                    self._timeBucket = bucket
                    self.Time:SetFormattedText('%.1f', duration)
                end
            end
        end
    end
    castbar.CustomDelayText = castbar.CustomTimeText

    -- Cast spell icon (oUF sets castbar.Icon texture automatically). Size from the
    -- CONFIGURED height (cbHeight), not a live castbarBg:GetHeight() which is
    -- unreliable this early; LayoutCastbarIcon anchors height to the bar regardless,
    -- this is just the initial square.
    local iconSize = cbHeight
    local iconFrame = CreateFrame("Frame", nil, castbarBg)
    iconFrame:SetSize(iconSize, iconSize)
    PP.Point(iconFrame, "TOPRIGHT", castbarBg, "TOPLEFT", 0, 0)
    local iconBg = iconFrame:CreateTexture(nil, "BACKGROUND")
    iconBg:SetAllPoints()
    iconBg:SetColorTexture(0, 0, 0, 1)
    iconFrame._bg = iconBg
    -- 1px black border via unified PP system
    PP.CreateBorder(iconFrame, 0, 0, 0, 1)
    local iconTex = iconFrame:CreateTexture(nil, "ARTWORK")
    iconTex:SetPoint("TOPLEFT", iconFrame, "TOPLEFT", 1, -1)
    iconTex:SetPoint("BOTTOMRIGHT", iconFrame, "BOTTOMRIGHT", -1, 1)
    iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    castbar.Icon = iconTex
    castbar._iconFrame = iconFrame

    -- Initial icon/fill layout (re-applied on every reload by the per-unit
    -- update paths and whenever the cast-bar height changes).
    do
        local offX, offY = CastIconOffsets(unit, settings)
        LayoutCastbarIcon(castbar, CastIconInWidth(unit, settings), cbHeight, CastIconOnRight(unit, settings), offX, offY, CastIconShown(unit, settings), settings and settings[ns.UF_CastClassicKey(unit)],
            ns.UF_CastIconPortrait(castbar, frame, settings, unit))
        ns.UF_ApplyCastBorder(castbar, settings, nil, unit)
    end

    return castbar
end

-- Important Cast Glow (target/focus), mirrors Nameplates.
-- The secret IsSpellImportant flag only drives overlay alpha.
do
    local IMP_GLOW_COLOR = { r = 1, g = 0.2, b = 0.2 }
    local IMP_GLOW_BG_COLOR = { r = 0, g = 0, b = 0 }
    -- One scratch spec for both cast bars: StartSpecGlow reads it synchronously.
    local impSpec = {}

    ns.ClearUnitFrameImportantGlow = function(castbar)
        local ov = castbar and castbar._importantOverlay
        if not ov or not castbar._impGlowActive then return end
        EllesmereUI.Glows.StopAllGlows(ov)
        ov:SetAlpha(0)
        ov:Hide()
        castbar._impGlowActive = nil
    end

    -- Called from PostCastStart; the engine has already set castbar.spellID.
    ns.UpdateUnitFrameImportantGlow = function(castbar)
        local s = castbar and castbar._eufSettings
        local Glows = EllesmereUI.Glows
        if not (s and s.castbarImportantGlow and C_Spell and C_Spell.IsSpellImportant) then
            ns.ClearUnitFrameImportantGlow(castbar)
            return
        end
        -- Probe first: a readable "not important" never starts a glow. A secret
        -- answer (combat restriction) still takes the alpha path below.
        local ok, isImportant = pcall(C_Spell.IsSpellImportant, castbar.spellID or 0)
        if not ok or (not issecretvalue(isImportant) and not isImportant) then
            ns.ClearUnitFrameImportantGlow(castbar)
            return
        end

        local ov = castbar._importantOverlay
        if not ov then
            ov = CreateFrame("Frame", nil, castbar)
            ov:SetAllPoints(castbar)
            ov:EnableMouse(false)
            castbar._importantOverlay = ov
        end
        ov:SetFrameLevel(castbar:GetFrameLevel() + 5)

        local c = s.castbarImportantGlowColor or IMP_GLOW_COLOR
        local bgc = s.castbarImportantGlowBackgroundColor or IMP_GLOW_BG_COLOR
        local spec = impSpec
        spec.style = s.castbarImportantGlowStyle or 1
        spec.r, spec.g, spec.b = Glows.ResolveColor(s.castbarImportantGlowColorMode or "custom", c.r, c.g, c.b)
        spec.lines = s.castbarImportantGlowLines or 8
        spec.thickness = s.castbarImportantGlowThickness or 2
        spec.speed = s.castbarImportantGlowSpeed or 4
        spec.bg = (s.castbarImportantGlowBackground == true) or nil
        spec.bgR, spec.bgG, spec.bgB = bgc.r, bgc.g, bgc.b
        local pW, pH = castbar:GetWidth(), castbar:GetHeight()
        -- Secret while the bar rides the stock-style aura block: use the last plain read
        -- (the bar never resizes in combat), else the configured holder size.
        if issecretvalue(pW) or issecretvalue(pH) then
            pW, pH = castbar._impPlainW, castbar._impPlainH
            if not pW then
                local cbw = s.castbarWidth or 0
                pW = cbw > 0 and cbw or 181
                pH = s.castbarHeight or 14
            end
        else
            castbar._impPlainW, castbar._impPlainH = pW, pH
        end
        if pW < 5 then pW = 100 end
        if pH < 5 then pH = 14 end
        -- Restarts only when the look or the bar size changed, so back-to-back
        -- casts keep the animation running.
        Glows.StartSpecGlow(ov, spec, pW, pH, "bar")
        castbar._impGlowActive = true

        ov:Show()
        ov:SetAlphaFromBoolean(isImportant)
    end
end

local function SetupShowOnCastBar(frame, unit)
    local castbar = frame.Castbar
    local castbarBg = castbar:GetParent()
    local iconFrame = castbar._iconFrame
    local impGlowUnit = IsKickCastbarUnit(unit)

    -- Read the hide-when-inactive flag dynamically so closures always reflect the
    -- current setting rather than a value captured at frame-creation time.
    local function shouldHideWhenInactive()
        local s = GetSettingsForUnit(unit)
        if not s then return true end
        local v = s.castbarHideWhenInactive
        if v == nil then return true end
        return v
    end

    castbar:Hide()
    if iconFrame then iconFrame:Hide() end
    if castbarBg then
        if shouldHideWhenInactive() then
            castbarBg:Hide()
        else
            castbarBg:Show()
        end
    end

    local savedCastHook = castbar.PostCastStart
    local savedInterruptHook = castbar.PostCastInterruptible

    castbar.PostCastStart = function(self, ...)
        local bg = self:GetParent()
        if bg then
            -- Boss: re-assert the configured width (castbarWidth>0=custom, 0=match
            -- frame width) at cast start, so a live cast always shows the right width
            -- even if no settings pass ran since the frame was resized.
            if unit and unit:match("^boss") then
                local s = db and db.profile and GetSettingsForUnit(unit)
                local cw = (s and s.castbarWidth) or 0
                if cw > 0 and cw < 30 then cw = 30 end
                if s then PP.Width(bg, cw > 0 and cw or frame:GetWidth()) end
            end
            bg:Show()
        end
        self:Show()
        if self._iconFrame then
            local s = db and db.profile and GetSettingsForUnit(unit)
            local showIcon
            if unit == "player" then
                showIcon = (s and s.showPlayerCastIcon ~= false)
            else
                showIcon = (not s or s.showCastIcon ~= false)
            end
            if showIcon then
                self._iconFrame:Show()
            else
                self._iconFrame:Hide()
            end
        end
        -- Spell target text (who the unit is casting on)
        if self.Target then
            local spellTarget, spellTargetClass
            local ownerUnit = self.__owner and self.__owner._euiUnit
            -- Channels are excluded: UnitSpellTargetName tracks the last CAST
            -- and keeps returning the previous hard-cast's target for the
            -- whole channel (field-verified stale), and no channel-target API
            -- exists -- so channels show no target name rather than a wrong
            -- one. Empowered casts read correctly and keep theirs.
            if ownerUnit and not self.channeling
               and UnitShouldDisplaySpellTargetName and UnitShouldDisplaySpellTargetName(ownerUnit) then
                local rawTarget = UnitSpellTargetName and UnitSpellTargetName(ownerUnit)
                if rawTarget then
                    spellTarget = rawTarget
                    spellTargetClass = UnitSpellTargetClass and UnitSpellTargetClass(ownerUnit)
                end
            end
            local hasTarget = spellTarget and true or false
            local sOwn = ownerUnit and db and db.profile and GetSettingsForUnit(ownerUnit)
            -- Combine Spell Name and Target (target/focus): one string in the TARGET
            -- slot ("Spell Name - Target", target class colored); the separate Spell
            -- Name element is suppressed via _combineNT in LayoutCastTextZones. Color
            -- code lives in the clean FORMAT string; (possibly secret) names ride
            -- through SetFormattedText -- never Lua-concatenated.
            local combine = sOwn and sOwn.castCombineNameTarget == true
                and (ownerUnit == "target" or ownerUnit == "focus")
            self._combineNT = combine or nil
            if combine then
                -- The separate target element is fully suppressed; the target
                -- rides appended to the spell NAME element instead.
                self.Target:SetText("")
                self.Target:Hide()
                if self.Text and hasTarget then
                    local spellName = UnitCastingInfo(ownerUnit)
                    if not spellName then spellName = UnitChannelInfo(ownerUnit) end
                    local hex
                    if spellTargetClass and C_ClassColor then
                        local c = C_ClassColor.GetClassColor(spellTargetClass)
                        if c and c.GenerateHexColor then hex = c:GenerateHexColor() end
                    end
                    if spellName then
                        if hex then
                            self.Text:SetFormattedText("%s - |c" .. hex .. "%s|r", spellName, spellTarget)
                        else
                            self.Text:SetFormattedText("%s - %s", spellName, spellTarget)
                        end
                    end
                end
                -- No cast target: oUF's plain spell name in the Text element
                -- stands untouched.
            else
                self.Target:SetText(spellTarget or "")
                self.Target:SetShown(hasTarget and self._showTarget ~= false)
                -- Class color the target name
                if hasTarget and spellTargetClass and C_ClassColor then
                    local c = C_ClassColor.GetClassColor(spellTargetClass)
                    if c then
                        self.Target:SetTextColor(c:GetRGB())
                    else
                        local tc = (sOwn and sOwn.castSpellTargetColor) or { r=1, g=1, b=1 }
                        self.Target:SetTextColor(tc.r, tc.g, tc.b)
                    end
                elseif hasTarget then
                    local tc = (sOwn and sOwn.castSpellTargetColor) or { r=1, g=1, b=1 }
                    self.Target:SetTextColor(tc.r, tc.g, tc.b)
                end
            end
            if self._layoutTextZones then self:_layoutTextZones() end
        end
        if savedCastHook then savedCastHook(self, ...) end
        UpdateUnitFrameKickTick(self)
        if impGlowUnit then ns.UpdateUnitFrameImportantGlow(self) end
        NotifyCastbarStarted(self)
    end
    castbar.PostChannelStart = castbar.PostCastStart
    castbar.PostCastInterruptible = function(self, ...)
        if savedInterruptHook then savedInterruptHook(self) end
    end

    local function dismissCastBar(self)
        HideUnitFrameKickTick(self)
        NotifyCastbarEnded(self)
        self:Hide()
        if self._iconFrame then self._iconFrame:Hide() end
        -- Read setting dynamically so changes take effect without a reload.
        if shouldHideWhenInactive() then
            local bg = self:GetParent()
            if bg then bg:Hide() end
        end
    end
    castbar.PostCastStop = dismissCastBar
    castbar.PostChannelStop = dismissCastBar
    castbar.PostCastFail = dismissCastBar

    -- Guard against nil stages from UnitEmpoweredStagePercentages during
    -- empower casts where stage data isn't available yet.
    castbar.UpdatePips = function(element, stages)
        if not stages then return end
        local isHoriz = element:GetOrientation() == "HORIZONTAL"
        local elementSize = isHoriz and element:GetWidth() or element:GetHeight()
        local lastOffset = 0
        for stage, stageSection in next, stages do
            local offset = lastOffset + (elementSize * stageSection)
            lastOffset = offset
            local pip = element.Pips[stage]
            if not pip then
                pip = (element.CreatePip or function(e)
                    return CreateFrame("Frame", nil, e, "CastingBarFrameStagePipTemplate")
                end)(element, stage)
                element.Pips[stage] = pip
            end
            pip:ClearAllPoints()
            if isHoriz then
                pip:SetPoint("CENTER", element, "LEFT", offset, 0)
            else
                pip:SetPoint("CENTER", element, "BOTTOM", 0, offset)
            end
            pip:Show()
        end
        for i = #stages + 1, #element.Pips do
            element.Pips[i]:Hide()
        end
    end

    -- Catch-all: hide the icon AND background whenever the castbar hides for any
    -- reason (oUF holdTime expiry, target/focus switch, etc.) so neither gets stuck.
    -- Key case: target/focus switching mid-cast -- oUF's CastStart hides the castbar
    -- but never fires PostCastStop, so dismissCastBar never runs and the background
    -- frame would otherwise remain visible as a black rectangle.
    castbar:HookScript("OnHide", function(self)
        HideUnitFrameKickTick(self)
        if impGlowUnit then ns.ClearUnitFrameImportantGlow(self) end
        NotifyCastbarEnded(self)
        if self._iconFrame then self._iconFrame:Hide() end
        if shouldHideWhenInactive() then
            local bg = self:GetParent()
            if bg then bg:Hide() end
        end
    end)
end


-- Swap portrait mode (3D/2D/class theme) without recreating frames: 2D and class
-- textures already exist on the backdrop, 3D PlayerModel is lazy-created on first use;
-- this just shows/hides and reassigns frame.Portrait. painting = the portrait
-- painter is the caller and paints the new object itself.
function SwapPortraitMode(frame, painting)
    local portrait = frame.Portrait
    if not portrait or not portrait.backdrop then return end
    local bd = portrait.backdrop
    if not bd._2d then return end

    local wantMode
    do
        local unit = frame._euiUnit or frame:GetAttribute("unit")
        -- The frame's own settings: a vehicle's live token has none.
        local uKey = UnitToSettingsKey(frame._euiBaseUnit or unit)
        local s = uKey and db.profile[uKey]
        wantMode = (s and s.portraitMode) or db.profile.portraitMode or "2d"
        -- A non-player on Class art takes the model when its fallback is 3D
        -- ("none" stays on the class object: the class lane draws nothing).
        if wantMode == "class" and unit and UnitExists(unit) and not UnitIsPlayer(unit)
            and ns.UF_ClassFallback(s) == "3d" then
            wantMode = "3d"
        end
        -- Blizzard Style masks the 2D art: a 3D model cannot be masked, and
        -- the portrait is never off.
        if (wantMode == "3d" or wantMode == "none") and ns.UF_Blizz() then wantMode = "2d" end
    end

    local curMode
    if portrait.isClass then curMode = "class"
    elseif portrait.is2D then curMode = "2d"
    else curMode = "3d" end

    if wantMode == curMode then return end

    -- (No event surgery needed on a mode swap: the engine's portrait painter
    -- targets whatever frame.Portrait currently is.)

    -- Hide all
    if bd._3d then bd._3d:ClearModel(); bd._3d:Hide() end
    bd._2d:Hide()
    if bd._class then bd._class:Hide() end

    if wantMode == "class" and bd._class then
        -- The art comes from the engine painter's class lane on the
        -- repaint below (players: class art, anyone else: the frame's
        -- non-player fallback).
        bd._class:Show()
        bd._2d:Hide()
        bd._class.backdrop = bd
        bd._class.isClass = true
        frame.Portrait = bd._class
    elseif wantMode == "3d" then
        -- Lazily create the PlayerModel on first switch to 3D
        if bd._ensureModel3D then bd._ensureModel3D() end
        if not bd._3d then return end
        -- A model ignores parent alpha: take the body's current fade until
        -- the visibility pass mirrors it.
        bd._3d:SetAlpha((frame._visWrap or frame):GetAlpha())
        bd._3d:Show()
        bd._3d.backdrop = bd
        bd._3d.is2D = false
        bd._3d.isClass = nil
        frame.Portrait = bd._3d
    else
        bd._2d:Show()
        bd._2d.backdrop = bd
        bd._2d.is2D = true
        bd._2d.isClass = nil
        frame.Portrait = bd._2d
    end
    -- The new object's guid memo dates from its last paint (a model was also
    -- cleared above): drop it so the next paint repaints even the same unit.
    frame.Portrait.guid = nil

    -- Repaint through the new object immediately.
    if not painting and frame.EnableElement then frame:EnableElement("Portrait") end
    ns.UF_StampPortraitForceUpdate(frame)
end

-------------------------------------------------------------------------------
--  Custom Class Power Display (Bars / Circles styles)
-------------------------------------------------------------------------------
local CLASS_POWER_TYPES = {
    ROGUE       = Enum.PowerType.ComboPoints,
    DRUID       = { [103] = Enum.PowerType.ComboPoints,     -- Feral
                    [104] = Enum.PowerType.ComboPoints,     -- Guardian (cat form)
                    [105] = Enum.PowerType.ComboPoints },   -- Restoration (cat form)
    MAGE        = {
        [62] = { Enum.PowerType.ArcaneCharges, 4 }, -- Arcane
        [64] = { "ICICLES", 5 },                    -- Frost: aura-based pip stacks
    },
    WARLOCK     = Enum.PowerType.SoulShards,
    PALADIN     = Enum.PowerType.HolyPower,
    MONK        = {
        [269] = { Enum.PowerType.Chi, 5 },        -- Windwalker
        [268] = { "BREWMASTER_STAGGER", 1, "bar" },  -- Brewmaster: single bar
    },
    EVOKER      = Enum.PowerType.Essence,
    DEATHKNIGHT = Enum.PowerType.Runes,
    -- Spec-specific custom resources (resolved at creation time)
    DEMONHUNTER = { [581] = { "SOUL_FRAGMENTS_VENGEANCE", 6 },
                    [1480] = { "SOUL_FRAGMENTS_DEVOURER", 50, "bar" } },
    SHAMAN      = { [263] = { "MAELSTROM_WEAPON", 10 } },
    HUNTER      = { [255] = { "TIP_OF_THE_SPEAR", 3 } },
    WARRIOR     = { [72]  = { "WHIRLWIND_STACKS", 4 },
                    [71]  = { "SWEEPING_STRIKES", 18 } },  -- 12.1 cap: 12 + 6 Broad Strokes
}

-- Vanilla content has no specializations, so every spec-keyed entry above fails to
-- resolve on Forever, and the flat ones name resources that client does not have --
-- a paladin there would draw five Holy Power pips that can never fill. This is the
-- whole set that exists on Forever; a class missing from it has no class resource.
local FOREVER_CLASS_POWER = {
    ROGUE = Enum.PowerType.ComboPoints,
    DRUID = Enum.PowerType.ComboPoints,
}

local function ClassPowerEntry(playerClass)
    if EllesmereUI.IS_FOREVER == true then return FOREVER_CLASS_POWER[playerClass] end
    return CLASS_POWER_TYPES[playerClass]
end

-- Combo points exist only in cat form for Guardian and Resto on retail, and for
-- every druid on Forever, where there are no specs to tell them apart.
local function DruidNeedsCatForm(playerClass, powerType)
    if playerClass ~= "DRUID" or powerType ~= Enum.PowerType.ComboPoints then
        return false
    end
    if EllesmereUI.IS_FOREVER == true then return true end
    local spec = C_SpecializationInfo and C_SpecializationInfo.GetSpecialization()
    local specID = spec and C_SpecializationInfo.GetSpecializationInfo(spec)
    return specID == 104 or specID == 105
end

-- Blizzard defines DRUID_CAT_FORM on every flavour; the literal is the fallback.
local function InCatForm()
    local form = GetShapeshiftFormID and GetShapeshiftFormID() or 0
    return form == (DRUID_CAT_FORM or 1)
end

-- Returns true if the player's current spec has a class resource in CLASS_POWER_TYPES
SpecHasClassPower = function()
    local _, playerClass = UnitClass("player")
    local entry = ClassPowerEntry(playerClass)
    if not entry then return false end
    if type(entry) ~= "table" then return true end
    if entry[1] ~= nil then return true end
    local spec = C_SpecializationInfo and C_SpecializationInfo.GetSpecialization()
    local specID = spec and C_SpecializationInfo.GetSpecializationInfo(spec)
    return specID and entry[specID] ~= nil
end

-- Toggle a frame's oUF Castbar element without rewriting Blizzard's cast bar event
-- registration. oUF silences PlayerCastingBarFrame/PetCastingBarFrame when the element
-- enables on the player frame and re-arms them when it disables; the shared helpers
-- keep whatever a standalone cast bar addon set. On ns for the 200-locals cap.
function ns.SetCastbarElement(frame, enable)
    if not frame or not frame.Castbar then return end
    if (frame:IsElementEnabled("Castbar") and true or false) == (enable and true or false) then return end
    EllesmereUI.CaptureBlizzCastBarEvents()
    if enable then
        frame:EnableElement("Castbar")
    else
        frame:DisableElement("Castbar")
    end
    EllesmereUI.RestoreBlizzCastBarEvents()
end

-- Manage Blizzard's player cast bar ownership based on whether UnitFrames renders its
-- own player cast bar. oUF already handles event plumbing for its own castbar element;
-- this helper only coordinates suppression with other EUI modules and releases control
-- cleanly for external addons.
local function ApplyBlizzCastbarState()
    if EllesmereUI and EllesmereUI.SetPlayerCastBarSuppressed and db and db.profile and db.profile.player then
        -- Only suppress Blizzard's player cast bar when EUI actually provides a
        -- replacement. If the player is on the Blizzard (or hidden) frame source,
        -- there is no EUI cast bar, so leave Blizzard's alone. Visibility "never"
        -- counts as no replacement too: our cast bar is built now but hides with the
        -- frame, and taking Blizzard's away would leave no player cast bar at all.
        local suppress = (db.profile.player.showPlayerCastbar
            and ns.VisEffective(db.profile.player) ~= "never"
            and ns.GetUnitFrameSource("player") == "eui") or false
        EllesmereUI.SetPlayerCastBarSuppressed("UnitFrames", suppress)
    end
end

-- Hide While Using Gamepad (Global Settings > Gamepad): Blizzard's gamepad UI
-- draws its own player cast bar, so ours stands down while a controller is
-- connected. It rides the same element switch "Show Player Cast Bar" off uses,
-- keyed on a runtime flag the reload and visibility passes also read
-- (ns._ufCastPadHidden); the saved toggle is never written and Blizzard's bar
-- stays suppressed. The pad edges are watched only while the option is on and
-- our player cast bar is on screen. padOn is the watcher's verdict; the login,
-- reload and options callers pass nothing and it is read live.
function ns.UF_ApplyGamepadCastbar(padOn)
    local s = db and db.profile and db.profile.player
    local frame = frames.player
    local cb = frame and frame.Castbar
    local want = (cb and s and s.showPlayerCastbar and s.castbarGamepadHide == true
        and ns.VisEffective(s) ~= "never"
        and ns.GetUnitFrameSource("player") == "eui") and true or false
    if want ~= (ns._ufCastPadWatched == true) then
        ns._ufCastPadWatched = want
        if want then
            EllesmereUI.WatchPad("UF_PlayerCastbar", ns.UF_ApplyGamepadCastbar)
        else
            EllesmereUI.UnwatchPad("UF_PlayerCastbar")
        end
    end
    local hide = false
    if want then
        if padOn == nil then padOn = EllesmereUI.PadConnected() end
        hide = padOn and true or false
    end
    if hide == (ns._ufCastPadHidden == true) then return end
    ns._ufCastPadHidden = hide
    if not cb then return end
    local castbarBg = cb:GetParent()
    if hide then
        ns.SetCastbarElement(frame, false)
        cb:Hide()
        if castbarBg then castbarBg:Hide() end
        return
    end
    -- Back on, mid-cast included: the enable re-derives the live cast; an idle
    -- holder follows the reload pass's hide-while-not-casting rule. A setting
    -- that turned the bar off is left to the reload pass that hides it.
    if not (s and s.showPlayerCastbar) then return end
    -- Enabled whether or not the frame is shown, as the reload pass does: a
    -- frame hidden by its visibility driver gets no element re-enable when the
    -- driver shows it again, so skipping it here would leave the bar dead. The
    -- holder is a child of the frame, so a hidden frame draws nothing.
    ns.SetCastbarElement(frame, true)
    if castbarBg then
        if s.castbarHideWhenInactive and not cb:IsShown() then
            castbarBg:Hide()
        else
            castbarBg:Show()
        end
    end
end

-- Main-chunk locals the other EUI_UnitFrames_*.lua files re-import by name.
-- dbSetters: a file that reads db keeps its own local and adds a setter here,
-- this file first; EllesmereUF:OnInitialize (EUI_UnitFrames_Lifecycle.lua)
-- assigns its own db, then runs the list.
ns._internals = {
    frames = frames, GetSettingsForUnit = GetSettingsForUnit, UnsnapTex = UnsnapTex,
    CastbarUnlockKey = CastbarUnlockKey, unitSettingsKey = unitSettingsKey,
    ResolveFontPath = ResolveFontPath, ApplyDarkTheme = ApplyDarkTheme,
    ApplyBlizzCastbarState = ApplyBlizzCastbarState, ApplyUnitFrameCastColor = ApplyUnitFrameCastColor,
    defaults = defaults, healthBarTextures = healthBarTextures,
    healthBarTextureNames = healthBarTextureNames, healthBarTextureOrder = healthBarTextureOrder,
    GetSelectedFont = GetSelectedFont, SetFSFont = SetFSFont,
    ApplyDetachedPortraitShape = ApplyDetachedPortraitShape, IsKickCastbarUnit = IsKickCastbarUnit,
    UnitToSettingsKey = UnitToSettingsKey, AbbreviateNumbers = AbbreviateNumbers,
    CreatePortrait = CreatePortrait, CreateCastBar = CreateCastBar,
    SetupShowOnCastBar = SetupShowOnCastBar, ApplyClassIconTexture = ApplyClassIconTexture,
    ClassPowerEntry = ClassPowerEntry, DruidNeedsCatForm = DruidNeedsCatForm, InCatForm = InCatForm,
    ApplyBarGradient = ApplyBarGradient, ApplyHealthBarTexture = ApplyHealthBarTexture,
    ApplyHealthBarAlpha = ApplyHealthBarAlpha, ApplyPowerBarAlpha = ApplyPowerBarAlpha,
    ResolveRestrictedClassColor = ResolveRestrictedClassColor,
    EUI_IsSmartPowerPercent = EUI_IsSmartPowerPercent,
    PLAYER_POWER_DEFAULT = PLAYER_POWER_DEFAULT, PLAYER_POWER_ALT = PLAYER_POWER_ALT,
    SwapPortraitMode = SwapPortraitMode, SpecHasClassPower = SpecHasClassPower,
    CastIconInWidth = CastIconInWidth, CastIconOffsets = CastIconOffsets,
    CastIconOnRight = CastIconOnRight, CastIconShown = CastIconShown,
    LayoutCastbarIcon = LayoutCastbarIcon, GetCastbarColor = GetCastbarColor,
    UpdateUnitFrameKickTick = UpdateUnitFrameKickTick,
    dbSetters = { function(v) db = v end },
}
-- A re-import of a name this table lacks fails where the part file loads,
-- not later as a nil upvalue inside one of its functions.
setmetatable(ns._internals, { __index = function(_, k)
    error("ns._internals has no entry " .. tostring(k), 2)
end })
