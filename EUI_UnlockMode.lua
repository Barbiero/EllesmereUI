if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EUI_UnlockMode.lua
--  Unlock Mode: animated transition, grid overlay, draggable movers, snap
--  guides, position memory, return-to-options flow. Elements from any addon
--  register via EllesmereUI:RegisterUnlockElements().
-------------------------------------------------------------------------------
local ADDON_NAME, ns = ...
local EAB = ns.EAB  -- may be nil if loaded by a non-ActionBars addon

-------------------------------------------------------------------------------
--  Registration API -- on the EllesmereUI global so ALL addons share one
--  table regardless of which copy of this file runs.
-------------------------------------------------------------------------------
if not EllesmereUI._unlockRegisteredElements then
    EllesmereUI._unlockRegisteredElements = {}
    EllesmereUI._unlockRegisteredOrder    = {}
    EllesmereUI._unlockRegistrationDirty  = true
end

if not EllesmereUI.RegisterUnlockElements then
    -- Normalize short field aliases (savePos) to the long names used
    -- throughout unlock mode (savePosition).
    local FIELD_ALIASES = {
        savePos      = "savePosition",
        loadPos      = "loadPosition",
        clearPos     = "clearPosition",
        applyPos     = "applyPosition",
    }
    function EllesmereUI:RegisterUnlockElements(elements, folder)
        for _, elem in ipairs(elements) do
            for short, long in pairs(FIELD_ALIASES) do
                if elem[short] and not elem[long] then
                    elem[long] = elem[short]
                end
            end
            -- Stamp the owning folder (per-element wins over call-site): export/import
            -- attributes the element and its anchor/match links to a module for per-module layout export.
            if folder and not elem.folder then elem.folder = folder end
            self._unlockRegisteredElements[elem.key] = elem
        end
        self._unlockRegistrationDirty = true
        -- Fresh registration flushes spec-override unlock layers' deferred writes
        -- for late/conditional registrants (party/raid containers, CDM bars).
        if EllesmereUI.SpecOverrides_UnlockPokeFlush then
            EllesmereUI.SpecOverrides_UnlockPokeFlush()
        end
    end
end

if not EllesmereUI.UnregisterUnlockElement then
    function EllesmereUI:UnregisterUnlockElement(key)
        self._unlockRegisteredElements[key] = nil
        self._unlockRegistrationDirty = true
    end
end

-- Cross-addon listeners fire on real session open/close only; close passes
-- "exit"/"save"/"discard" as arg 2. Combat suspension does not end the session.
if not EllesmereUI._unlockModeListeners then
    EllesmereUI._unlockModeListeners = {}
end

if not EllesmereUI.RegisterUnlockModeListener then
    function EllesmereUI:RegisterUnlockModeListener(owner, listener)
        self._unlockModeListeners[owner] = listener
        if self._unlockModeSessionActive then
            pcall(listener, true)
        end
    end

    function EllesmereUI:UnregisterUnlockModeListener(owner)
        self._unlockModeListeners[owner] = nil
    end

    function EllesmereUI:IsUnlockModeActive()
        return self._unlockModeSessionActive == true
    end

    function EllesmereUI:_NotifyUnlockModeListeners(active, closeAction)
        self._unlockModeSessionActive = active == true
        for _, listener in pairs(self._unlockModeListeners) do
            pcall(listener, self._unlockModeSessionActive, closeAction)
        end
    end
end

-- Already loaded by another addon: bail (registration API above is idempotent;
-- state/frames/animations below must exist only once).
if EllesmereUI._unlockModeLoaded then return end
EllesmereUI._unlockModeLoaded = true

-------------------------------------------------------------------------------
--  Anchor reapply stub (pre-EnsureLoaded): lets child addons (CDM) reposition
--  anchored elements at login before the full body loads; deferred block replaces it.
-------------------------------------------------------------------------------
if not EllesmereUI.ReapplyOwnAnchor then
    EllesmereUI.ReapplyOwnAnchor = function(key)
        if not EllesmereUIDB or not EllesmereUIDB.unlockAnchors then return end
        local info = EllesmereUIDB.unlockAnchors[key]
        if not info or not info.target then return end

        local elems = EllesmereUI._unlockRegisteredElements
        local childElem = elems and elems[key]
        local targetElem = elems and elems[info.target]
        local childBar = childElem and childElem.getFrame and childElem.getFrame(key)
        local targetBar = targetElem and targetElem.getFrame and targetElem.getFrame(info.target)
        if not childBar or not targetBar then return end
        if not targetBar:GetLeft() then return end

        local side = info.side
        local uiS = UIParent:GetEffectiveScale()
        local tS = targetBar:GetEffectiveScale()
        local cS = childBar:GetEffectiveScale()

        local tL = (targetBar:GetLeft() or 0) * tS / uiS
        local tR = (targetBar:GetRight() or 0) * tS / uiS
        local tT = (targetBar:GetTop() or 0) * tS / uiS
        local tB = (targetBar:GetBottom() or 0) * tS / uiS
        local tCX = (tL + tR) / 2
        local tCY = (tT + tB) / 2

        local cW = (childBar:GetWidth() or 50) * cS / uiS
        local cH = (childBar:GetHeight() or 50) * cS / uiS

        local cx, cy
        if info.offsetX and info.offsetY then
            if side == "LEFT" then
                cx = tL + info.offsetX - cW / 2
                cy = tCY + info.offsetY
            elseif side == "RIGHT" then
                cx = tR + info.offsetX + cW / 2
                cy = tCY + info.offsetY
            elseif side == "TOP" then
                cx = tCX + info.offsetX
                cy = tT + info.offsetY + cH / 2
            elseif side == "BOTTOM" then
                cx = tCX + info.offsetX
                cy = tB + info.offsetY - cH / 2
            else
                cx = tCX + info.offsetX
                cy = tCY + info.offsetY
            end
        else
            if side == "LEFT" then
                cx = tL - cW / 2; cy = tCY
            elseif side == "RIGHT" then
                cx = tR + cW / 2; cy = tCY
            elseif side == "TOP" then
                cx = tCX; cy = tT + cH / 2
            elseif side == "BOTTOM" then
                cx = tCX; cy = tB - cH / 2
            else
                cx = tCX; cy = tCY
            end
        end

        local uiW, uiH = UIParent:GetSize()
        local centerX = cx - uiW / 2
        local centerY = cy - uiH / 2

        -- No explicit snap: center came from pixel-aligned target edges/dims; snapping here adds 1px drift from float dust.
        pcall(function()
            childBar:ClearAllPoints()
            childBar:SetPoint("CENTER", UIParent, "CENTER", centerX, centerY)
        end)
    end
end

-------------------------------------------------------------------------------
--  Early stub: NotifyElementResized -- grow-direction-aware repositioning before
--  unlock mode fully loads; deferred block overwrites it.
-------------------------------------------------------------------------------
if not EllesmereUI.NotifyElementResized then
    EllesmereUI.NotifyElementResized = function(key)
        if not EllesmereUIDB then return end
        -- Skip if anchored (early ReapplyOwnAnchor handles those)
        local anchors = EllesmereUIDB.unlockAnchors
        if anchors and anchors[key] and anchors[key].target then return end

        local growDir
        if key == "EQT_Tracker" then growDir = "DOWN"
        elseif key:sub(1, 4) == "CDM_" then
            local rawKey = key:sub(5)
            local cdm = EllesmereUI.Lite and EllesmereUI.Lite.GetAddon and EllesmereUI.Lite.GetAddon("EllesmereUICooldownManager", true)
            local cdmBars = cdm and cdm.db and cdm.db.profile and cdm.db.profile.cdmBars
            if cdmBars and cdmBars.bars then
                for _, bar in ipairs(cdmBars.bars) do
                    if bar.key == rawKey then
                        local g = bar.growDirection
                        if g then growDir = g end
                        break
                    end
                end
            end
        else
            local eab = EllesmereUI.Lite and EllesmereUI.Lite.GetAddon and EllesmereUI.Lite.GetAddon("EllesmereUIActionBars", true)
            local s = eab and eab.db and eab.db.profile and eab.db.profile.bars and eab.db.profile.bars[key]
            if s then
                local g = (s.growDirection or "up"):upper()
                if g ~= "UP" then growDir = g end
            end
        end
        if not growDir or growDir == "CENTER" then return end

        local elems = EllesmereUI._unlockRegisteredElements
        local elem = elems and elems[key]
        local frame = elem and elem.getFrame and elem.getFrame(key)
        if not frame or not frame:GetCenter() then return end

        local pos
        if elem and elem.loadPosition then
            pos = elem.loadPosition(key)
        else
            local eab = EllesmereUI.Lite and EllesmereUI.Lite.GetAddon and EllesmereUI.Lite.GetAddon("EllesmereUIActionBars", true)
            local db = eab and eab.db and eab.db.profile and eab.db.profile.barPositions
            pos = db and db[key]
        end
        if not pos or pos.point ~= "CENTER" or pos.relPoint ~= "CENTER" then return end

        local cx, cy = pos.x or 0, pos.y or 0
        local fw = frame:GetWidth() or 0
        local fh = frame:GetHeight() or 0
        -- Raw fw/2, fh/2 (not floor): odd-dimension frames with integer+0.5 centers
        -- reverse to exact pixel edges; floor() loses the .5 (1px drift).
        local anchor, adjX, adjY
        if growDir == "RIGHT" then
            anchor = "LEFT"; adjX = cx - fw / 2; adjY = cy
        elseif growDir == "LEFT" then
            anchor = "RIGHT"; adjX = cx + fw / 2; adjY = cy
        elseif growDir == "DOWN" then
            anchor = "TOP"; adjX = cx; adjY = cy + fh / 2
        elseif growDir == "UP" then
            anchor = "BOTTOM"; adjX = cx; adjY = cy - fh / 2
        else
            return
        end

        -- No explicit snap: cx +/- dim/2 reproduces the pixel-aligned edge within float epsilon; snapping can round the wrong way (1px drift/reload).
        pcall(function()
            frame:ClearAllPoints()
            frame:SetPoint(anchor, UIParent, "CENTER", adjX, adjY)
        end)
    end
end

-- Early stub: IsUnlockAnchored -- true if the key has an anchor target in the DB; deferred block overwrites it.
if not EllesmereUI.IsUnlockAnchored then
    EllesmereUI.IsUnlockAnchored = function(unlockKey)
        if not EllesmereUIDB or not EllesmereUIDB.unlockAnchors then return false end
        local ai = EllesmereUIDB.unlockAnchors[unlockKey]
        return ai and ai.target and true or false
    end
end

-- Authoritative position pass fallback: CDM owns this pass when loaded (fires from
-- CollectAndReanchor once async icon population settles). Without CDM nobody
-- triggers EnsureUnlockCore or the final layout pass, so fire it from here.
do
    local f = CreateFrame("Frame")
    f:RegisterEvent("PLAYER_ENTERING_WORLD")
    f:SetScript("OnEvent", function(self)
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
        C_Timer.After(1.5, function()
            -- CDM already ran EnsureUnlockCore and fires the pass itself.
            if EllesmereUI._applySavedPositions then return end
            -- No CDM: run the deferred block and fire the same pass.
            EllesmereUI:EnsureUnlockCore()
            if EllesmereUI.ApplyAllWidthHeightMatches then
                EllesmereUI.ApplyAllWidthHeightMatches()
            end
            if EllesmereUI._applySavedPositions then
                EllesmereUI._applySavedPositions()
            end
            if EllesmereUI.ReapplyAllUnlockAnchorsForced then
                EllesmereUI.ReapplyAllUnlockAnchorsForced()
            end
        end)
    end)
end

-- Synchronous handler at PLAYER_LOGIN, never a timer: on a combat reload, lockdown
-- is not yet re-engaged during PLAYER_LOGIN dispatch, but a timer scheduled here
-- would fire after the loading screen with lockdown back on. Must live in this
-- non-deferred header -- the deferred body only runs via EnsureUnlockCore() during
-- this dispatch (CDM) or later (fallback above), so a handler inside it would miss
-- the in-flight event. Created after Lite's lifecycle frame so every module's
-- OnEnable already ran (bars positioned, frames spawned, elements registered),
-- letting protected children (oUF) anchor before lockdown re-engages; later
-- builders (CDM at PEW) fall through to the retry loop/regen park. The unlock-core
-- cost is paid at PEW anyway -- doing it here just hides it in the loading screen.
-- Deliberately NOT EnsureLoaded: that would pull the whole LoadOnDemand options
-- addon into every login.
do
    local f = CreateFrame("Frame")
    f:RegisterEvent("PLAYER_LOGIN")
    f:SetScript("OnEvent", function(self)
        self:UnregisterAllEvents()
        EllesmereUI:EnsureUnlockCore()
        if EllesmereUI._applySavedPositions then
            EllesmereUI._applySavedPositions()
        end
    end)
end

-- Screen-edge anchor targets: invisible 1-unit strips just outside each of the
-- four screen edges, so their inner edge IS the screen edge and a link's
-- edge-to-edge offset counts from it. Registered in this non-deferred header so the
-- early ReapplyOwnAnchor stub resolves them at login. isHidden = no mover (never
-- dragged or picked); the no-op savePosition keeps SaveBarPosition's action bar
-- fallback from ever writing these keys.
do
    -- anchor, relative point, anchor, relative point, label, thin axis
    local EDGES = {
        SCREEN_LEFT   = { "TOPRIGHT",   "TOPLEFT",    "BOTTOMRIGHT", "BOTTOMLEFT",  "Left Screen Edge",   "W" },
        SCREEN_RIGHT  = { "TOPLEFT",    "TOPRIGHT",   "BOTTOMLEFT",  "BOTTOMRIGHT", "Right Screen Edge",  "W" },
        SCREEN_TOP    = { "BOTTOMLEFT", "TOPLEFT",    "BOTTOMRIGHT", "TOPRIGHT",    "Top Screen Edge",    "H" },
        SCREEN_BOTTOM = { "TOPLEFT",    "BOTTOMLEFT", "TOPRIGHT",    "BOTTOMRIGHT", "Bottom Screen Edge", "H" },
    }
    function EllesmereUI.IsScreenEdgeKey(key)
        return EDGES[key] ~= nil
    end

    local strips = {}
    local function GetStrip(key) return strips[key] end
    local function IsHidden() return true end
    local function NoSave() end

    local elements = {}
    for key, def in pairs(EDGES) do
        local f = CreateFrame("Frame", nil, UIParent)
        if def[6] == "W" then f:SetWidth(1) else f:SetHeight(1) end
        f:SetPoint(def[1], UIParent, def[2], 0, 0)
        f:SetPoint(def[3], UIParent, def[4], 0, 0)
        strips[key] = f
        elements[#elements + 1] = {
            key = key, label = def[5],
            getFrame = GetStrip, savePosition = NoSave, isHidden = IsHidden,
            noAnchorTo = true, noResize = true, noSizeMatchTarget = true,
        }
    end
    EllesmereUI:RegisterUnlockElements(elements)

    -- Linked children sit at absolute offsets from UIParent's center, so any change
    -- of UIParent's size in units (aspect ratio, window size, UI scale) leaves them
    -- stale. This frame follows UIParent's size and re-runs every edge's chain
    -- (batched into one pass per frame).
    local watch = CreateFrame("Frame", nil, UIParent)
    watch:SetAllPoints(UIParent)
    watch:SetScript("OnSizeChanged", function()
        local propagate = EllesmereUI.PropagateAnchorChain
        if not propagate then return end
        for key in pairs(EDGES) do propagate(key) end
    end)
end

-- DEFERRED: heavy body (4900+ lines) runs on first EnsureUnlockCore() call
-- (PLAYER_LOGIN / CDM setup / unlock-mode open / EnsureLoaded). Own slot, not
-- _deferredInits: login must run this WITHOUT loading the options addon.
EllesmereUI._unlockCoreInit = function()
local UM = {}  -- unlock state and late-bound functions shared across the unlock files
local floor = math.floor
local abs   = math.abs
local min   = math.min
local max   = math.max
local sqrt  = math.sqrt
local sin   = math.sin

-- IEEE 754 branchless round-to-nearest-even (avoids -0 from half-pixel centers)
local function round(num)
    return num + (2^52 + 2^51) - (2^52 + 2^51)
end

-- Pixel-perfect snap: round a value to the nearest physical pixel boundary.
local PP = EllesmereUI and EllesmereUI.PP
local function pxSnap(x)
    if not PP then return round(x) end
    local m = PP.mult or 1
    if m == 1 then return round(x) end
    return round(x / m) * m
end

-- WaitForSize: defer callback one frame so the layout engine has flushed.
local function WaitForSize(frame, callback)
    C_Timer.After(0, callback)
end

-- Blank or restore a bar frame's alpha around a resize. Action Bars tracks the
-- alpha of the bars it fades instead of reading it back, so it is told.
function EllesmereUI._UnlockSetBarAlpha(frame, a)
    frame:SetAlpha(a)
    local note = EllesmereUI._EABNoteAlpha
    if note then note(frame, a) end
end

-- DeferMoverSync: sync now (no blink) and again next frame to catch layout-engine
-- flush moves; hides the bar frame meanwhile to prevent a visual jump.
local function DeferMoverSync(m, syncFn, barFrame)
    if not m then return end
    if barFrame then EllesmereUI._UnlockSetBarAlpha(barFrame, 0) end
    syncFn(m)
    C_Timer.After(0, function()
        if m then syncFn(m) end
        if barFrame then EllesmereUI._UnlockSetBarAlpha(barFrame, 1) end
    end)
end

-- After a setWidth/setHeight rebuild snaps the bar to its stored position mid-unlock,
-- re-place it at the mover's current screen position (else resizing makes it jump).
-- On EllesmereUI to avoid an upvalue in CreateMover (Lua 5.1 limit: 60).
function EllesmereUI.RepositionBarToMover(barKey)
    if not isUnlocked then return end
    local m = movers[barKey]
    if not m then return end
    local bar = GetBarFrame(barKey)
    if not bar then return end
    local mL, mT = m:GetLeft(), m:GetTop()
    if not mL or not mT then return end
    -- GetLeft/GetTop and SetPoint TOPLEFT vs UIParent TOPLEFT share one space;
    -- Y offset from UIParent TOPLEFT is negative (top of screen = 0).
    pcall(function()
        bar:ClearAllPoints()
        bar:SetPoint("TOPLEFT", UIParent, "TOPLEFT", mL, mT - UIParent:GetHeight())
    end)
end

-- RecenterBarAnchor is defined below, after its dependencies (isUnlocked, movers, registeredElements, GetBarFrame, GetBarGrowDirActual).

-------------------------------------------------------------------------------
--  Constants
-------------------------------------------------------------------------------
local FONT_PATH   = (EllesmereUI.GetFontPath("extras"))
    or "Interface\\AddOns\\EllesmereUI\\media\\fonts\\Expressway.TTF"

-- At very low UI scale the overlays/top bar are hard to read, so they're nudged up.
-- The `UIParent:GetEffectiveScale() < 0.6` test is inlined at each use site (not a
-- helper) because overlay builders are already at Lua 5.1's 60-upvalue limit.
local LOCK_INNER  = "Interface\\AddOns\\EllesmereUI\\media\\eui-unlocked-inner-2.png"
local LOCK_OUTER  = "Interface\\AddOns\\EllesmereUI\\media\\eui-unlocked-outer-2.png"
local LOCK_TOP    = "Interface\\AddOns\\EllesmereUI\\media\\eui-unlocked-top-2.png"
local GRID_SPACING = 32          -- pixels between grid lines
local SNAP_THRESH  = 6            -- px distance to trigger snap-to-element
local MOVER_ALPHA  = 0.55        -- resting alpha for mover overlays
local MOVER_HOVER  = 0.85        -- hover alpha
local MOVER_DRAG   = 0.95        -- dragging alpha
local TRANSITION_DUR = 0.35      -- seconds for the open/close fade-in
local GEAR_ROTATION  = math.pi / 4  -- 45 deg rotation for gear effect

-- Movable bar keys (action bars + stance + micro + bag); populated by EAB if loaded, else empty.
local BAR_LOOKUP    = ns.BAR_LOOKUP or {}
local ALL_BAR_ORDER = ns.BAR_DROPDOWN_ORDER or {}
local VISIBILITY_ONLY = ns.VISIBILITY_ONLY or {}

local function GetVisibilityOnly()
    -- Read lazily so child addons have time to populate ns.VISIBILITY_ONLY
    return ns.VISIBILITY_ONLY or VISIBILITY_ONLY
end

-- Local aliases for the shared registration tables
local registeredElements = EllesmereUI._unlockRegisteredElements
local registeredOrder    = EllesmereUI._unlockRegisteredOrder

local function RebuildRegisteredOrder()
    if not EllesmereUI._unlockRegistrationDirty then return end
    wipe(registeredOrder)
    for key, _ in pairs(registeredElements) do
        registeredOrder[#registeredOrder + 1] = key
    end
    -- Sort by order field (lower first), then alphabetically
    table.sort(registeredOrder, function(a, b)
        local oa = registeredElements[a].order or 1000
        local ob = registeredElements[b].order or 1000
        if oa ~= ob then return oa < ob end
        return a < b
    end)
    EllesmereUI._unlockRegistrationDirty = false
end

-------------------------------------------------------------------------------
--  State
-------------------------------------------------------------------------------
UM.unlockFrame = nil       -- the full-screen overlay
UM.gridFrame = nil         -- grid line container
local guidePool = {}       -- reusable alignment guide lines
local movers = {}          -- { [barKey] = moverFrame }
UM.isUnlocked = false
function EllesmereUI.IsUnlockModeActive() return UM.isUnlocked end
UM.gridMode = "dimmed"     -- "disabled", "dimmed", "bright"
UM.snapEnabled = true      -- magnet/snap state (runtime); must precede SnapPosition
local lockAnimFrame        -- lock assembly animation (close)
UM.openAnimFrame = nil     -- lock animation frame (open)
UM.logoFadeFrame = nil     -- the 2s logo+title fade-out timer frame
local pendingPositions = {}   -- { [barKey] = {point,relPoint,x,y} } -- unsaved changes
local snapshotPositions = {}  -- original positions captured when unlock mode opens
local snapshotAnchors = {}    -- original anchor data captured when unlock mode opens
local snapshotSizes = {}      -- original sizes captured when unlock mode opens
local snapshotWidthMatch = {} -- original width match DB captured when unlock mode opens
local snapshotHeightMatch = {} -- original height match DB captured when unlock mode opens
local snapshotGrowDirs = {}   -- original growth directions captured when unlock mode opens
-- Spec-override banner refresh = EllesmereUI._unlockRefreshSpecOvMarks (namespace
-- field, not local: deferred-init function is at Lua 5.1's 200-local cap). Layer
-- banking is a wholesale harvest at CommitPositions.
UM.hasChanges = false         -- true if user dragged anything this session
local combatSuspended = false  -- true if unlock mode was auto-closed by combat
UM.objTrackerWasVisible = false     -- track objective tracker state for restore

-- Grid mode helpers
local GRID_ALPHA_DIMMED = 0.15
local GRID_ALPHA_BRIGHT = 0.30
local GRID_CENTER_DIMMED = 0.25
local GRID_CENTER_BRIGHT = 0.50
local GRID_HUD_BRIGHT = 0.60   -- matches HUD_ON_ALPHA
local GRID_HUD_DIMMED = 0.45
local GRID_HUD_OFF    = 0.30   -- matches HUD_OFF_ALPHA

local function GridBaseAlpha()
    return UM.gridMode == "bright" and GRID_ALPHA_BRIGHT or GRID_ALPHA_DIMMED
end
local function GridCenterAlpha()
    return UM.gridMode == "bright" and GRID_CENTER_BRIGHT or GRID_CENTER_DIMMED
end
local function GridHudAlpha()
    if UM.gridMode == "bright" then return GRID_HUD_BRIGHT end
    if UM.gridMode == "dimmed" then return GRID_HUD_DIMMED end
    return GRID_HUD_OFF
end
local function GridLabelText()
    if UM.gridMode == "bright" then return "Grid Lines\nBright" end
    if UM.gridMode == "dimmed" then return "Grid Lines\nDimmed" end
    return "Grid Lines\nDisabled"
end
local function CycleGridMode()
    if UM.gridMode == "dimmed" then UM.gridMode = "bright"
    elseif UM.gridMode == "bright" then UM.gridMode = "disabled"
    else UM.gridMode = "dimmed" end
end
UM.flashlightEnabled = false     -- cursor flashlight toggle
UM.darkOverlaysEnabled = true     -- dark overlay backgrounds on movers
UM.coordsEnabled = false        -- show coordinates for all elements at all times
local _blizzOwnedOverlays = {}  -- info overlays for Blizzard-controlled elements
UM.unlockTipFrame = nil        -- one-time "how to use" tip frame
UM.selectedMover = nil         -- currently selected mover frame (for arrow key nudging)
UM.arrowKeyFrame = nil         -- invisible frame that captures arrow key input
UM.selectElementPicker = nil   -- mover currently in "Select Element" pick mode (nil = off)
local SELECT_ELEMENT_ALPHA = 0.50  -- overlay alpha during select-element pick mode
local SELECT_ELEMENT_FADE  = 0.50  -- seconds for the fade transition

-- Maps barKey -> settings location for "Element Options" nav: module =
-- RegisterModule folder; page = page tab (PAGE_* value); sectionName = string
-- passed to SectionHeader(); preSelectFn = optional dropdown-setter run before
-- the page builds. On EllesmereUI to dodge CreateMover's 60-upvalue cap.
local function SelectActionBar(key)
    return function()
        -- Direct setter (if options module already built) + pending flag consumed
        -- at Bar Display page build. Mirrors the unit-frame path.
        if EllesmereUI._setActionBarKey then EllesmereUI._setActionBarKey(key) end
        EllesmereUI._pendingActionBarSelect = key
    end
end
local function SelectUnitFrame(unit)
    return function()
        -- Direct setter (if init already ran) + pending flag (consumed at page build)
        if EllesmereUI._setUnitFrameUnit then EllesmereUI._setUnitFrameUnit(unit) end
        EllesmereUI._pendingUnitSelect = unit
    end
end
-- Mini-frame pre-select factory (ToT/FoT/Pet/Boss live on "Mini Frames" with
-- their own dropdown). On EllesmereUI, not file-local, to avoid a local in this limit-sensitive deferred function.
EllesmereUI._SelectMiniUnit = function(unit)
    return function()
        if EllesmereUI._setMiniUnit then EllesmereUI._setMiniUnit(unit) end
        EllesmereUI._pendingMiniSelect = unit
    end
end
-- Capture entries registered before this deferred body runs (DataBars writes
-- per-bar EDB_ keys at PLAYER_LOGIN, which fires first); merged back below so this
-- assignment never wipes them. Namespace-stashed: function is at its local/upvalue cap.
EllesmereUI._elemMapPre = EllesmereUI._ELEMENT_SETTINGS_MAP
EllesmereUI._ELEMENT_SETTINGS_MAP = {
    -- Main frames: "Main Frames" page; dropdown pre-selected to the unit.
    ["player"]       = { module = "EllesmereUIUnitFrames",       page = "Main Frames",   sectionName = "HEALTH BAR",       preSelectFn = SelectUnitFrame("player"),                   highlightText = "Bar Height" },
    ["target"]       = { module = "EllesmereUIUnitFrames",       page = "Main Frames",   sectionName = "HEALTH BAR",       preSelectFn = SelectUnitFrame("target"),                   highlightText = "Bar Height" },
    ["focus"]        = { module = "EllesmereUIUnitFrames",       page = "Main Frames",   sectionName = "HEALTH BAR",       preSelectFn = SelectUnitFrame("focus"),                    highlightText = "Bar Height" },
    -- Mini frames: "Mini Frames" page; mini dropdown pre-selected to the unit.
    ["pet"]          = { module = "EllesmereUIUnitFrames",       page = "Mini Frames",   sectionName = "HEALTH BAR",       preSelectFn = EllesmereUI._SelectMiniUnit("pet"),          highlightText = "Bar Height" },
    ["targettarget"] = { module = "EllesmereUIUnitFrames",       page = "Mini Frames",   sectionName = "HEALTH BAR",       preSelectFn = EllesmereUI._SelectMiniUnit("targettarget"), highlightText = "Bar Height" },
    ["focustarget"]  = { module = "EllesmereUIUnitFrames",       page = "Mini Frames",   sectionName = "HEALTH BAR",       preSelectFn = EllesmereUI._SelectMiniUnit("focustarget"),  highlightText = "Bar Height" },
    -- Boss frames live on their own "Boss Frames" page (no unit dropdown).
    ["boss"]         = { module = "EllesmereUIUnitFrames",       page = "Boss Frames",   sectionName = "HEALTH BAR",       highlightText = "Bar Height" },
    ["classPower"]   = { module = "EllesmereUIUnitFrames",       page = "Main Frames",   sectionName = "CLASS RESOURCE",   preSelectFn = SelectUnitFrame("player"),                   highlightText = "Enable Class Resource" },

    -- Unit-frame cast bars (configured on the Main Frames page, CAST BAR section, per selected unit)
    ["playerCastbar"] = { module = "EllesmereUIUnitFrames",      page = "Main Frames",   sectionName = "CAST BAR",         preSelectFn = SelectUnitFrame("player"),                   highlightText = "Show Cast Bar" },
    ["targetCastbar"] = { module = "EllesmereUIUnitFrames",      page = "Main Frames",   sectionName = "CAST BAR",         preSelectFn = SelectUnitFrame("target"),                   highlightText = "Show Cast Bar" },
    ["focusCastbar"]  = { module = "EllesmereUIUnitFrames",      page = "Main Frames",   sectionName = "CAST BAR",         preSelectFn = SelectUnitFrame("focus"),                    highlightText = "Show Cast Bar" },

    -- Resource Bars (no dropdown -- each bar has its own section)
    ["ERB_Health"]        = { module = "EllesmereUIResourceBars",       page = "Class, Power and Health Bars", sectionName = "HEALTH BAR",           highlightText = "Bar Height" },
    ["ERB_Power"]         = { module = "EllesmereUIResourceBars",       page = "Class, Power and Health Bars", sectionName = "POWER BAR",            highlightText = "Bar Height" },
    ["ERB_ClassResource"] = { module = "EllesmereUIResourceBars",       page = "Class, Power and Health Bars", sectionName = "CLASS RESOURCE BAR",   highlightText = "Bar Height" },
    ["ERB_CastBar"]       = { module = "EllesmereUIResourceBars",       page = "Cast Bar",                     sectionName = "BAR DISPLAY",          highlightText = "Bar Height" },

    -- Action Bars (all share "Bar Display" page; dropdown pre-selected to correct bar)
    ["MainBar"]   = { module = "EllesmereUIActionBars",          page = "Bar Display",                  sectionName = "LAYOUT",  preSelectFn = SelectActionBar("MainBar"),   highlightText = "Icon Size" },
    ["Bar2"]      = { module = "EllesmereUIActionBars",          page = "Bar Display",                  sectionName = "LAYOUT",  preSelectFn = SelectActionBar("Bar2"),      highlightText = "Icon Size" },
    ["Bar3"]      = { module = "EllesmereUIActionBars",          page = "Bar Display",                  sectionName = "LAYOUT",  preSelectFn = SelectActionBar("Bar3"),      highlightText = "Icon Size" },
    ["Bar4"]      = { module = "EllesmereUIActionBars",          page = "Bar Display",                  sectionName = "LAYOUT",  preSelectFn = SelectActionBar("Bar4"),      highlightText = "Icon Size" },
    ["Bar5"]      = { module = "EllesmereUIActionBars",          page = "Bar Display",                  sectionName = "LAYOUT",  preSelectFn = SelectActionBar("Bar5"),      highlightText = "Icon Size" },
    ["Bar6"]      = { module = "EllesmereUIActionBars",          page = "Bar Display",                  sectionName = "LAYOUT",  preSelectFn = SelectActionBar("Bar6"),      highlightText = "Icon Size" },
    ["Bar7"]      = { module = "EllesmereUIActionBars",          page = "Bar Display",                  sectionName = "LAYOUT",  preSelectFn = SelectActionBar("Bar7"),      highlightText = "Icon Size" },
    ["Bar8"]      = { module = "EllesmereUIActionBars",          page = "Bar Display",                  sectionName = "LAYOUT",  preSelectFn = SelectActionBar("Bar8"),      highlightText = "Icon Size" },
    ["Bar9"]      = { module = "EllesmereUIActionBars",          page = "Bar Display",                  sectionName = "LAYOUT",  preSelectFn = SelectActionBar("Bar9"),      highlightText = "Icon Size" },
    ["Bar10"]     = { module = "EllesmereUIActionBars",          page = "Bar Display",                  sectionName = "LAYOUT",  preSelectFn = SelectActionBar("Bar10"),     highlightText = "Icon Size" },
    ["StanceBar"] = { module = "EllesmereUIActionBars",          page = "Bar Display",                  sectionName = "LAYOUT",  preSelectFn = SelectActionBar("StanceBar"), highlightText = "Icon Size" },
    ["PetBar"]    = { module = "EllesmereUIActionBars",          page = "Bar Display",                  sectionName = "LAYOUT",  preSelectFn = SelectActionBar("PetBar"),    highlightText = "Icon Size" },
    ["XPBar"]     = { module = "EllesmereUIActionBars",          page = "Bar Display",                  sectionName = "LAYOUT",  preSelectFn = SelectActionBar("XPBar"),     highlightText = "Icon Size" },
    ["RepBar"]    = { module = "EllesmereUIActionBars",          page = "Bar Display",                  sectionName = "LAYOUT",  preSelectFn = SelectActionBar("RepBar"),    highlightText = "Icon Size" },

    -- Action Bars -- visibility-only (dropdown pre-selected, scroll to top)
    ["MicroBar"] = { module = "EllesmereUIActionBars",          page = "Bar Display",                  sectionName = "GENERAL", preSelectFn = SelectActionBar("MicroBagBars") },
    ["BagBar"]   = { module = "EllesmereUIActionBars",          page = "Bar Display",                  sectionName = "GENERAL", preSelectFn = SelectActionBar("MicroBagBars") },

    -- Aura Buff Reminders
    ["EABR_Reminders"] = { module = "EllesmereUIAuraBuffReminders", page = "Auras, Buffs & Consumables", sectionName = "DISPLAY" },

    -- Quality of Life (FPS + Secondary Stats live on the QoL page's EXTRAS section)
    ["EUI_FPS"]            = { module = "EllesmereUIQoL", page = "QoL", sectionName = "EXTRAS", highlightText = "Show FPS Counter" },
    ["EUI_SecondaryStats"] = { module = "EllesmereUIQoL", page = "QoL", sectionName = "EXTRAS", highlightText = "Secondary Stat Display" },

    -- Battle Res + Bloodlust (bottom of the Quality of Life page)
    ["EUI_BattleRes"]      = { module = "EllesmereUIQoL",             page = "QoL",   sectionName = "BATTLE RES",        highlightText = "Enable BattleRes Icon" },
    ["EUI_Bloodlust"]      = { module = "EllesmereUIQoL",             page = "QoL",   sectionName = "BLOODLUST TRACKER", highlightText = "Enable Bloodlust Icon" },

    -- Mythic+ Tools
    ["EMT_MythicTimer"]    = { module = "EllesmereUIMythicTimer",     page = "Mythic+ Timer",     sectionName = "DISPLAY",           highlightText = "Scale" },
    ["EMT_TargetedSpellBars"] = { module = "EllesmereUIMythicTimer",  page = "Targeted Spell Bars", sectionName = "TARGETED SPELL BARS", highlightText = "Enable Targeted Spell Bars" },
    ["EMT_TargetCastBar"]  = { module = "EllesmereUIMythicTimer",     page = "Target/Focus Bars", sectionName = "TARGET CAST BAR",   highlightText = "Enable Target Cast Bar" },
    ["EMT_FocusCastBar"]   = { module = "EllesmereUIMythicTimer",     page = "Target/Focus Bars", sectionName = "FOCUS CAST BAR",    highlightText = "Enable Focus Cast Bar" },

    -- Dragon Riding HUD (Blizz UI Enhanced > Dragon Riding page)
    ["EDR_Cluster"]        = { module = "EllesmereUIBlizzardSkin",    page = "Dragon Riding",     sectionName = "GENERAL",           highlightText = "Enable Dragon Riding Bar" },

    -- Fixed-position tooltip anchor (Blizz UI Enhanced > Tooltips, Menus & Popups)
    ["EUI_TooltipAnchor"]  = { module = "EllesmereUIBlizzardSkin",    page = "Tooltips, Menus & Popups", sectionName = "BLIZZARD TOOLTIP", highlightText = "Anchor to Cursor" },

    -- Minimap
    ["EBS_Minimap"]        = { module = "EllesmereUIMinimap",         page = "Minimap",           sectionName = "DISPLAY",           highlightText = "Size" },

    -- Damage Meters: windows use dynamic "EDM_Win<i>" keys and resolve to the shared
    -- "EDM_Win" entry via the cog lookup's prefix fallback (top of the tab, like CDM_).
    ["EDM_Win"]            = { module = "EllesmereUIDamageMeters",    page = "Damage Meters" },
    ["EDM_CombatTimer"]    = { module = "EllesmereUIDamageMeters",    page = "Damage Meters",     sectionName = "STANDALONE COMBAT TIMER", highlightText = "Standalone Combat Timer" },
    ["EDM_IconHistory"]    = { module = "EllesmereUIDamageMeters",    page = "Spell History",     sectionName = "ICON HISTORY",      highlightText = "Enable Icon History" },

    -- Raid + Party Frames (separate registered pages/tabs)
    ["RF_RaidFrames"]      = { module = "EllesmereUIRaidFrames",      page = "Raid",              sectionName = "FRAME SIZES",       highlightText = "20 Man Frame Width" },
    ["RF_PartyFrames"]     = { module = "EllesmereUIRaidFrames",      page = "Party",             sectionName = "FRAMES",            highlightText = "Frame Width" },

    -- CDM dynamic bars: "CDM_<key>"/"TBB_<idx>" resolve to these shared tab entries
    -- via the cog lookup's prefix fallback; no sectionName/preSelectFn so bars land
    -- at the top of the tab (deliberately undifferentiated).
    ["CDM_"]               = { module = "EllesmereUICooldownManager", page = "CDM Bars" },
    ["TBB_"]               = { module = "EllesmereUICooldownManager", page = "Tracking Bars" },
}
if EllesmereUI._elemMapPre then
    for k, v in pairs(EllesmereUI._elemMapPre) do
        if EllesmereUI._ELEMENT_SETTINGS_MAP[k] == nil then
            EllesmereUI._ELEMENT_SETTINGS_MAP[k] = v
        end
    end
    EllesmereUI._elemMapPre = nil
end

-- Width Match / Height Match / Anchor To pick modes: only one active at a time; picker mover stored here.
UM.pickMode = nil              -- nil, "widthMatch", "heightMatch", "anchorTo"
UM.pickModeMover = nil         -- the mover that initiated the pick mode
UM.hoveredMover = nil          -- the currently expanded mover (only one at a time)
UM.anchorDropdownFrame = nil    -- lazy-created dropdown for anchor direction selection
UM.anchorDropdownCatcher = nil    -- click-catcher behind anchor dropdown
UM.growDropdownFrame = nil    -- lazy-created dropdown for grow direction selection
UM.growDropdownCatcher = nil    -- click-catcher behind grow dropdown

-- Cursor speed tracking for hover intent detection (stored on EllesmereUI to avoid upvalue pressure)
EllesmereUI._unlockCursorX     = 0
EllesmereUI._unlockCursorY     = 0
EllesmereUI._unlockCursorSpeed = 0   -- pixels/sec at UIParent scale
EllesmereUI._unlockHoverSpeedThresh = 80 * 80 -- squared px/sec threshold (avoids sqrt each frame)
EllesmereUI._unlockHoverIntentDelay = 0.12 -- seconds to wait after settling before expanding

-------------------------------------------------------------------------------
--  Accent color helper (reads live from EllesmereUI)
-------------------------------------------------------------------------------
local function GetAccent()
    local eg = EllesmereUI and EllesmereUI.ELLESMERE_GREEN
    if eg then return eg.r, eg.g, eg.b end
    return 12/255, 210/255, 157/255
end

-------------------------------------------------------------------------------
--  Grid overlay
-------------------------------------------------------------------------------
local function CreateGrid(parent)
    if UM.gridFrame then return UM.gridFrame end
    -- Grid lives on its own BACKGROUND-strata frame so it renders BEHIND the
    -- real game UI elements (action bars, unit frames).
    UM.gridFrame = CreateFrame("Frame", nil, UIParent)
    UM.gridFrame:SetFrameStrata("BACKGROUND")
    UM.gridFrame:SetAllPoints(UIParent)
    UM.gridFrame:SetFrameLevel(1)
    UM.gridFrame._lines = {}

    function UM.gridFrame:Rebuild()
        for _, tex in ipairs(self._lines) do tex:Hide() end
        local idx = 0
        local w, h = UIParent:GetWidth(), UIParent:GetHeight()
        local ar, ag, ab = GetAccent()
        local baseA = GridBaseAlpha()
        local centerA = GridCenterAlpha()

        -- Pixel-perfect: use PP.mult so lines are exactly 1 physical pixel
        -- and spacing aligns to the physical pixel grid.
        local mult = PP and PP.mult or 1
        local lineW = mult
        local spacing = GRID_SPACING * mult

        -- Snap helper: round a UI coordinate to the nearest physical pixel
        local function snap(v) return floor(v / mult + 0.5) * mult end

        local centerX = snap(w / 2)
        local centerY = snap(h / 2)

        local function MakeLine(isVert, pos)
            idx = idx + 1
            local tex = self._lines[idx]
            if not tex then
                tex = self:CreateTexture(nil, "BACKGROUND", nil, -7)
                if tex.SetSnapToPixelGrid then
                    tex:SetSnapToPixelGrid(false)
                    tex:SetTexelSnappingBias(0)
                end
                self._lines[idx] = tex
            end
            tex:SetColorTexture(ar, ag, ab, baseA)
            tex._baseAlpha = baseA
            tex._isWhite = false
            tex._isVert = isVert
            tex._pos = pos
            tex:ClearAllPoints()
            if isVert then
                tex:SetSize(lineW, h)
                tex:SetPoint("TOPLEFT", UIParent, "TOPLEFT", pos, 0)
            else
                tex:SetSize(w, lineW)
                tex:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, -pos)
            end
            tex:Show()
        end

        -- Vertical lines extending outward from center
        local x = centerX - spacing
        while x > 0 do MakeLine(true, snap(x)); x = x - spacing end
        x = centerX + spacing
        while x < w do MakeLine(true, snap(x)); x = x + spacing end

        -- Horizontal lines extending outward from center
        local y = centerY - spacing
        while y > 0 do MakeLine(false, snap(y)); y = y - spacing end
        y = centerY + spacing
        while y < h do MakeLine(false, snap(y)); y = y + spacing end

        -- Center crosshair: full-length accent lines at screen center
        for _, axis in ipairs({"V", "H"}) do
            idx = idx + 1
            local tex = self._lines[idx]
            if not tex then
                tex = self:CreateTexture(nil, "BACKGROUND", nil, -6)
                if tex.SetSnapToPixelGrid then
                    tex:SetSnapToPixelGrid(false)
                    tex:SetTexelSnappingBias(0)
                end
                self._lines[idx] = tex
            end
            tex:SetColorTexture(ar, ag, ab, centerA)
            tex._baseAlpha = centerA
            tex._isWhite = false
            tex._isVert = (axis == "V")
            tex._pos = 0
            tex:ClearAllPoints()
            if axis == "V" then
                tex:SetSize(lineW, h)
                tex:SetPoint("TOPLEFT", UIParent, "TOPLEFT", centerX, 0)
            else
                tex:SetSize(w, lineW)
                tex:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, -centerY)
            end
            tex:Show()
        end

        -- White crosshair pip at dead center (short lines forming a +), always
        -- 50% alpha regardless of grid brightness mode
        local CROSS_ARM = 20
        local CROSS_ALPHA = 0.5
        for _, axis in ipairs({"V", "H"}) do
            idx = idx + 1
            local tex = self._lines[idx]
            if not tex then
                tex = self:CreateTexture(nil, "BACKGROUND", nil, -5)
                if tex.SetSnapToPixelGrid then
                    tex:SetSnapToPixelGrid(false)
                    tex:SetTexelSnappingBias(0)
                end
                self._lines[idx] = tex
            end
            tex:SetColorTexture(1, 1, 1, CROSS_ALPHA)
            tex._baseAlpha = CROSS_ALPHA
            tex._isWhite = true
            tex._isVert = (axis == "V")
            tex._pos = 0
            tex:ClearAllPoints()
            if axis == "V" then
                tex:SetSize(lineW, CROSS_ARM * 2)
                tex:SetPoint("TOPLEFT", UIParent, "TOPLEFT", centerX, -(centerY - CROSS_ARM))
            else
                tex:SetSize(CROSS_ARM * 2, lineW)
                tex:SetPoint("TOPLEFT", UIParent, "TOPLEFT", centerX - CROSS_ARM, -centerY)
            end
            tex:Show()
        end

        self._lineCount = idx
    end

    -- Cache accent color; refreshed when grid is rebuilt
    local cachedAR, cachedAG, cachedAB = GetAccent()

    local origRebuild = UM.gridFrame.Rebuild
    function UM.gridFrame:Rebuild()
        origRebuild(self)
        cachedAR, cachedAG, cachedAB = GetAccent()
    end

    -- Cursor flashlight: highlights grid lines near the cursor via a radial
    -- gradient texture (soft ambient glow) plus per-line segments with 2D
    -- distance-based alpha for crisp line highlights.
    local LIGHT_RADIUS   = 220
    local LIGHT_DIAMETER = LIGHT_RADIUS * 2
    local LIGHT_BOOST    = 0.55
    local NUM_SEGS       = 5
    local FLASH_PATH = "Interface\\AddOns\\EllesmereUI\\media\\unlock-flash.png"

    -- Ambient glow texture (soft circle behind lines)
    local flashTex = UM.gridFrame:CreateTexture(nil, "BACKGROUND", nil, -8)
    flashTex:SetTexture(FLASH_PATH)
    flashTex:SetSize(LIGHT_DIAMETER, LIGHT_DIAMETER)
    flashTex:SetBlendMode("ADD")
    flashTex:SetVertexColor(1, 1, 1, 0.03)
    flashTex:Hide()

    -- Line highlight segments
    UM.gridFrame._glows = {}
    local glowIdx = 0

    local function GetGlow(idx)
        local g = UM.gridFrame._glows[idx]
        if not g then
            g = UM.gridFrame:CreateTexture(nil, "BACKGROUND", nil, -6)
            UM.gridFrame._glows[idx] = g
        end
        return g
    end

    UM.gridFrame:SetScript("OnUpdate", function(self, dt)
        if not self:IsShown() then
            flashTex:Hide()
            return
        end

        if not UM.flashlightEnabled then
            flashTex:Hide()
            for j = 1, #self._glows do
                if self._glows[j] then self._glows[j]:Hide() end
            end
            return
        end

        local scale = UIParent:GetEffectiveScale()
        local cx, cy = GetCursorPosition()
        cx = cx / scale
        cy = cy / scale
        local screenH = UIParent:GetHeight()
        local screenW = UIParent:GetWidth()
        local cyFromTop = screenH - cy

        -- Position ambient glow
        flashTex:ClearAllPoints()
        flashTex:SetPoint("CENTER", UIParent, "BOTTOMLEFT", cx, cy)
        flashTex:Show()

        -- Highlight line segments
        glowIdx = 0
        local R2 = LIGHT_RADIUS * LIGHT_RADIUS
        local lineCount = self._lineCount or #self._lines

        for i = 1, lineCount do
            local tex = self._lines[i]
            if tex and tex:IsShown() and tex._baseAlpha then
                local perpDist
                if tex._isVert then
                    perpDist = abs(tex._pos - cx)
                else
                    perpDist = abs(tex._pos - cyFromTop)
                end

                if perpDist < LIGHT_RADIUS then
                    local halfSpan = sqrt(R2 - perpDist * perpDist)
                    local segSize = (halfSpan * 2) / NUM_SEGS
                    local isW = tex._isWhite

                    if tex._isVert then
                        local spanStart = max(0, cy - halfSpan)
                        local spanEnd = min(screenH, cy + halfSpan)
                        local segY = spanStart
                        while segY < spanEnd do
                            local segEnd = min(segY + segSize, spanEnd)
                            local midY = (segY + segEnd) * 0.5
                            local dy = midY - cy
                            local dx = tex._pos - cx
                            local d2 = dx * dx + dy * dy
                            if d2 < R2 then
                                local t = 1 - sqrt(d2) / LIGHT_RADIUS
                                local alpha = LIGHT_BOOST * t * t
                                if alpha > 0.003 then
                                    glowIdx = glowIdx + 1
                                    local g = GetGlow(glowIdx)
                                    if isW then
                                        g:SetColorTexture(1, 1, 1, alpha)
                                    else
                                        g:SetColorTexture(cachedAR, cachedAG, cachedAB, alpha)
                                    end
                                    g:ClearAllPoints()
                                    g:SetSize(1, segEnd - segY)
                                    g:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", tex._pos, segY)
                                    g:Show()
                                end
                            end
                            segY = segEnd
                        end
                    else
                        local spanStart = max(0, cx - halfSpan)
                        local spanEnd = min(screenW, cx + halfSpan)
                        local segX = spanStart
                        while segX < spanEnd do
                            local segEnd = min(segX + segSize, spanEnd)
                            local midX = (segX + segEnd) * 0.5
                            local dx = midX - cx
                            local dy = tex._pos - cyFromTop
                            local d2 = dx * dx + dy * dy
                            if d2 < R2 then
                                local t = 1 - sqrt(d2) / LIGHT_RADIUS
                                local alpha = LIGHT_BOOST * t * t
                                if alpha > 0.003 then
                                    glowIdx = glowIdx + 1
                                    local g = GetGlow(glowIdx)
                                    if isW then
                                        g:SetColorTexture(1, 1, 1, alpha)
                                    else
                                        g:SetColorTexture(cachedAR, cachedAG, cachedAB, alpha)
                                    end
                                    g:ClearAllPoints()
                                    g:SetSize(segEnd - segX, 1)
                                    g:SetPoint("TOPLEFT", UIParent, "TOPLEFT", segX, -tex._pos)
                                    g:Show()
                                end
                            end
                            segX = segEnd
                        end
                    end
                end
            end
        end

        for j = glowIdx + 1, #self._glows do
            if self._glows[j] then self._glows[j]:Hide() end
        end
    end)

    return UM.gridFrame
end

-------------------------------------------------------------------------------
--  Alignment guide lines (snap guides between bars)
-------------------------------------------------------------------------------
local activeGuides = {}

local function GetGuide(idx)
    if guidePool[idx] then return guidePool[idx] end
    local tex = UM.unlockFrame:CreateTexture(nil, "OVERLAY", nil, 6)
    tex:SetColorTexture(1, 1, 1, 1)
    guidePool[idx] = tex
    return tex
end

-- Snap highlight: a pulsing white border layered ON TOP of the green one. Each
-- mover gets a lazy _snapBrd (a second MakeBorder at a higher frame level) so the
-- green accent border stays visible underneath.
local snapHighlightKey = nil   -- barKey of mover currently showing snap highlight border
local snapHighlightAnim = nil  -- OnUpdate frame for the pulsing border
local snapHighlightElapsed = 0

local function GetOrCreateSnapBorder(m)
    if m._snapBrd then return m._snapBrd end
    local brd = EllesmereUI.MakeBorder(m, 1, 1, 1, 0)
    -- Raise above the accent border
    brd._frame:SetFrameLevel(m:GetFrameLevel() + 3)
    m._snapBrd = brd
    return brd
end

local function ClearSnapHighlight()
    if snapHighlightKey and movers[snapHighlightKey] then
        local m = movers[snapHighlightKey]
        if m._snapBrd then m._snapBrd:SetColor(1, 1, 1, 0) end
        -- Restore normal overlay brightness
        if UM.darkOverlaysEnabled and m._bg then
            m._bg:SetColorTexture(m._bgR or 0.075, m._bgG or 0.113, m._bgB or 0.141, 0.95)
        end
    end
    snapHighlightKey = nil
    snapHighlightElapsed = 0
    if snapHighlightAnim then
        snapHighlightAnim:SetScript("OnUpdate", nil)
        snapHighlightAnim:Hide()
    end
end

local function ShowSnapHighlight(targetKey)
    if targetKey == snapHighlightKey then return end
    -- Hide old highlight
    if snapHighlightKey and movers[snapHighlightKey] then
        local old = movers[snapHighlightKey]
        if old._snapBrd then old._snapBrd:SetColor(1, 1, 1, 0) end
        if UM.darkOverlaysEnabled and old._bg then
            old._bg:SetColorTexture(old._bgR or 0.075, old._bgG or 0.113, old._bgB or 0.141, 0.95)
        end
    end
    local m = movers[targetKey]
    if not m then
        ClearSnapHighlight()
        return
    end
    snapHighlightKey = targetKey
    snapHighlightElapsed = 0
    GetOrCreateSnapBorder(m)
    -- Brighten the mover's base color
    if UM.darkOverlaysEnabled and m._bg then
        m._bg:SetColorTexture((m._bgR or 0.075) * 1.4, (m._bgG or 0.113) * 1.4, (m._bgB or 0.141) * 1.4, 0.95)
    end
    if not snapHighlightAnim then
        snapHighlightAnim = CreateFrame("Frame")
    end
    snapHighlightAnim:SetScript("OnUpdate", function(self, dt)
        snapHighlightElapsed = snapHighlightElapsed + dt
        local target = movers[snapHighlightKey]
        if not target or not target._snapBrd then
            ClearSnapHighlight()
            return
        end
        local alpha = 0.45 + 0.45 * sin(snapHighlightElapsed * 9.42)
        target._snapBrd:SetColor(1, 1, 1, alpha * 0.9)
    end)
    snapHighlightAnim:Show()
end

local function HideAllGuides()
    for _, tex in ipairs(guidePool) do tex:Hide() end
    wipe(activeGuides)
end

-- Full cleanup including snap highlight (used when drag stops)
local function HideAllGuidesAndHighlight()
    HideAllGuides()
    ClearSnapHighlight()
end

-------------------------------------------------------------------------------
--  ShowAlignmentGuides: draws full-screen guide lines at snap positions.
--  Called from the drag OnUpdate; snapInfo is populated by SnapPosition.
-------------------------------------------------------------------------------
local lastSnapInfo = {}  -- written by SnapPosition, read by ShowAlignmentGuides
-- Expose whether each axis has an active edge snap so OnUpdate can skip
-- SnapForES on that axis (the unsnapped value already matches the target edge).
EllesmereUI._snapAxisLocked = function() return lastSnapInfo.lockX, lastSnapInfo.lockY end

local function ShowAlignmentGuides(dragKey)
    HideAllGuides()
    if not lastSnapInfo then return end

    local ar, ag, ab = GetAccent()
    local guideIdx = 0
    local screenW = UIParent:GetWidth()
    local screenH = UIParent:GetHeight()

    -- Edge/center snap guide lines (1 physical pixel wide)
    local PPg = EllesmereUI and EllesmereUI.PP
    local onePx = PPg and PPg.mult or 1
    if lastSnapInfo.snapXPos then
        guideIdx = guideIdx + 1
        local g = GetGuide(guideIdx)
        g:SetColorTexture(ar, ag, ab, 0.5)
        g:ClearAllPoints()
        g:SetSize(onePx, screenH)
        g:SetPoint("BOTTOM", UIParent, "BOTTOMLEFT", lastSnapInfo.snapXPos, 0)
        g:Show()
        activeGuides[guideIdx] = g
    end
    if lastSnapInfo.snapYPos then
        guideIdx = guideIdx + 1
        local g = GetGuide(guideIdx)
        g:SetColorTexture(ar, ag, ab, 0.5)
        g:ClearAllPoints()
        g:SetSize(screenW, onePx)
        g:SetPoint("LEFT", UIParent, "BOTTOMLEFT", 0, lastSnapInfo.snapYPos)
        g:Show()
        activeGuides[guideIdx] = g
    end

    -- Snap highlight: pulse the border of the element being snapped to
    local dragMover = movers[dragKey]
    local hasSpecificTarget = dragMover and dragMover._snapTarget
        and dragMover._snapTarget ~= "_disable_"
        and dragMover._snapTarget ~= "_select_"
    if hasSpecificTarget and movers[dragMover._snapTarget] then
        ShowSnapHighlight(dragMover._snapTarget)
    elseif lastSnapInfo.closestKey then
        ShowSnapHighlight(lastSnapInfo.closestKey)
    else
        ClearSnapHighlight()
    end
end

-------------------------------------------------------------------------------
--  Snap-to-element helper: 1) find the single closest mover (min edge-to-edge
--  distance, within SNAP_PROXIMITY px). 2) check 9 X-axis + 9 Y-axis pairs against
--  that one mover. Populates lastSnapInfo for ShowAlignmentGuides to read.
-------------------------------------------------------------------------------

local function SnapPosition(dragKey, cx, cy, halfW, halfH)
    wipe(lastSnapInfo)
    if not UM.snapEnabled then return cx, cy end

    local dL = cx - halfW
    local dR = cx + halfW
    local dT = cy + halfH
    local dB = cy - halfH

    -- Step 1: find snap target mover
    -- If this mover has a specific snap target, use it; otherwise find closest
    local closestKey = nil
    local dragMover = movers[dragKey]
    local perMoverTarget = dragMover and dragMover._snapTarget
    -- "_disable_" = snapping disabled for this specific mover
    if perMoverTarget == "_disable_" then return cx, cy end
    if perMoverTarget and perMoverTarget ~= dragKey and movers[perMoverTarget] and movers[perMoverTarget]:IsShown() then
        closestKey = perMoverTarget
    else
        -- Find closest by true 2D edge-to-edge distance (no limit)
        local closestMinDist = math.huge
        -- Exclude from snap: all descendants (children, grandchildren, etc.) and
        -- siblings (anchored to the same parent). The direct parent IS allowed.
        local dragExcluded = {}
        local anchorDB = GetAnchorDB()
        if anchorDB then
            -- Recursively exclude all descendants
            local function ExcludeDescendants(parentKey)
                for childKey, info in pairs(anchorDB) do
                    if info.target == parentKey and not dragExcluded[childKey] then
                        dragExcluded[childKey] = true
                        ExcludeDescendants(childKey)
                    end
                end
            end
            ExcludeDescendants(dragKey)
            -- Exclude siblings (share the same anchor parent)
            local myInfo = anchorDB[dragKey]
            if myInfo and myInfo.target then
                for sibKey, sibInfo in pairs(anchorDB) do
                    if sibKey ~= dragKey and sibInfo.target == myInfo.target then
                        dragExcluded[sibKey] = true
                    end
                end
            end
        end
        for key, mover in pairs(movers) do
            if key ~= dragKey and not dragExcluded[key] and mover:IsShown() then
                local oL = mover:GetLeft()   or 0
                local oR = mover:GetRight()  or 0
                local oT = mover:GetTop()    or 0
                local oB = mover:GetBottom() or 0
                -- Signed axis distances (negative = overlapping on that axis)
                local gapX = 0
                if dR < oL then gapX = oL - dR
                elseif dL > oR then gapX = dL - oR end
                local gapY = 0
                if dB > oT then gapY = dB - oT
                elseif dT < oB then gapY = oB - dT end
                -- 2D edge-to-edge distance (0 if overlapping)
                local edgeDist = sqrt(gapX * gapX + gapY * gapY)
                if edgeDist < closestMinDist then
                    closestMinDist = edgeDist
                    closestKey = key
                end
            end
        end
    end

    lastSnapInfo.closestKey = closestKey
    local bestDX, bestDistX = 0, SNAP_THRESH
    local bestDY, bestDistY = 0, SNAP_THRESH
    local snapXLinePos, snapYLinePos = nil, nil

    -- Step 2: 9+9 edge pairs against closest mover
    if closestKey then
        local m = movers[closestKey]
        local oL = m:GetLeft()   or 0
        local oR = m:GetRight()  or 0
        local oT = m:GetTop()    or 0
        local oB = m:GetBottom() or 0
        local oCX = (oL + oR) * 0.5
        local oCY = (oT + oB) * 0.5

        -- X-axis: dragged {left, center, right} vs target {left, center, right}
        local dragXEdges = { dL, cx, dR }
        local targXEdges = { oL, oCX, oR }
        local snapXEdgeIdx = nil
        for di, de in ipairs(dragXEdges) do
            for _, te in ipairs(targXEdges) do
                local dx = de - te
                local adx = abs(dx)
                if adx < bestDistX then
                    bestDistX = adx
                    bestDX = dx
                    snapXLinePos = te
                    snapXEdgeIdx = di
                end
            end
        end

        -- Y-axis: dragged {top, center, bottom} vs target {top, center, bottom}
        local dragYEdges = { dT, cy, dB }
        local targYEdges = { oT, oCY, oB }
        local snapYEdgeIdx = nil
        for di, de in ipairs(dragYEdges) do
            for _, te in ipairs(targYEdges) do
                local dy = de - te
                local ady = abs(dy)
                if ady < bestDistY then
                    bestDistY = ady
                    bestDY = dy
                    snapYLinePos = te
                    snapYEdgeIdx = di
                end
            end
        end
    end

    -- Apply edge/center snap
    local snapX = cx
    local snapY = cy
    if bestDistX < SNAP_THRESH then snapX = cx - bestDX end
    if bestDistY < SNAP_THRESH then snapY = cy - bestDY end

    -- Record guide line positions for ShowAlignmentGuides
    if bestDistX < SNAP_THRESH and snapXLinePos then
        lastSnapInfo.snapXPos = snapXLinePos
        lastSnapInfo.xEdge = snapXEdgeIdx
        lastSnapInfo.lockX = true  -- skip SnapForES on X axis
    end
    if bestDistY < SNAP_THRESH and snapYLinePos then
        lastSnapInfo.snapYPos = snapYLinePos
        lastSnapInfo.yEdge = snapYEdgeIdx
        lastSnapInfo.lockY = true  -- skip SnapForES on Y axis
    end

    return snapX, snapY
end

-------------------------------------------------------------------------------
--  Selection + Arrow Key Nudge System
-------------------------------------------------------------------------------
-- Selection highlight: a low-opacity white fill over the selected element's
-- overlay background, so the currently-selected element (the one arrow keys
-- move) is clearly marked, like the snap-target highlight shown during drag.
local function SetSelectionHighlight(m, on)
    if not m then return end
    if on then
        if not m._selHl then
            local hl = m:CreateTexture(nil, "ARTWORK")
            hl:SetAllPoints()
            hl:SetColorTexture(1, 1, 1, 1)
            m._selHl = hl
        end
        m._selHl:SetAlpha(0.10)
        m._selHl:Show()
    elseif m._selHl then
        m._selHl:Hide()
    end
end

local function SelectMover(m)
    local ar, ag, ab = GetAccent()
    -- Selecting a mover releases any selected fallback ghost (one arrow-key
    -- target at a time)
    if EllesmereUI._DeselectFallbackGhosts then EllesmereUI._DeselectFallbackGhosts() end
    if EllesmereUI._DeselectOverrideGhosts then EllesmereUI._DeselectOverrideGhosts() end
    -- Deselect previous
    if UM.selectedMover and UM.selectedMover ~= m then
        UM.selectedMover._selected = false
        SetSelectionHighlight(UM.selectedMover, false)
        if not UM.selectedMover._dragging and not UM.selectedMover:IsMouseOver() then
            UM.selectedMover:SetFrameLevel(UM.selectedMover._baseLevel)
            if not UM.darkOverlaysEnabled then UM.selectedMover:SetAlpha(MOVER_ALPHA) end
            UM.selectedMover._brd:SetColor(ar, ag, ab, 0.6)
            -- Collapse overlay on old selection
            if UM.selectedMover._hideOverlayText then UM.selectedMover._hideOverlayText() end
        end
        -- Hide action buttons on old selection
        if UM.selectedMover._hideCogAfterDelay then UM.selectedMover._hideCogAfterDelay() end
        -- Hide coordinates on old selection (keep if coords-always-on)
        if UM.selectedMover._coordFS and not UM.coordsEnabled then UM.selectedMover._coordFS:Hide() end
    end
    UM.selectedMover = m
    if m then
        m._selected = true
        SetSelectionHighlight(m, true)
        m:SetFrameLevel(m._raisedLevel)
        if not UM.darkOverlaysEnabled then m:SetAlpha(MOVER_HOVER) end
        m._brd:SetColor(1, 1, 1, 0.9)

        -- Update coordinates on selection (expansion is hover-only)
        if m.UpdateCoordText then m:UpdateCoordText() end

        -- Pulse the snap target if this mover has a specific one assigned
        local tgt = m._snapTarget
        if tgt and tgt ~= "_disable_" and tgt ~= "_select_" and movers[tgt] then
            ShowSnapHighlight(tgt)
        else
            ClearSnapHighlight()
        end
    end
end

local function DeselectMover()
    if UM.selectedMover then
        local ar, ag, ab = GetAccent()
        UM.selectedMover._selected = false
        SetSelectionHighlight(UM.selectedMover, false)
        if not UM.selectedMover._dragging then
            if not UM.selectedMover:IsMouseOver() then
                UM.selectedMover:SetFrameLevel(UM.selectedMover._baseLevel)
                if not UM.darkOverlaysEnabled then UM.selectedMover:SetAlpha(MOVER_ALPHA) end
                UM.selectedMover._brd:SetColor(ar, ag, ab, 0.6)
                if UM.selectedMover._hideOverlayText then UM.selectedMover._hideOverlayText() end
            end
        end
        -- Restore settings widgets to base level
        -- Hide coordinates (keep visible if coords-always-on mode is active)
        if UM.selectedMover._coordFS and not UM.coordsEnabled then UM.selectedMover._coordFS:Hide() end
        -- Clear snap highlight
        ClearSnapHighlight()
        -- Cancel select-element pick mode if this mover was the picker -- restore previous target
        if UM.selectElementPicker == UM.selectedMover then
            UM.selectedMover._snapTarget = UM.selectedMover._preSelectTarget
            UM.selectedMover._preSelectTarget = nil
            if UM.selectedMover._updateSnapLabel then UM.selectedMover._updateSnapLabel() end
            UM.selectElementPicker = nil
            FadeOverlayForSelectElement(false)
        end
        -- Cancel width/height/anchor pick mode if this mover was the picker
        if UM.pickModeMover == UM.selectedMover then
            CancelPickMode()
        end
    end
    UM.selectedMover = nil
    if EllesmereUI._DeselectFallbackGhosts then EllesmereUI._DeselectFallbackGhosts() end
    if EllesmereUI._DeselectOverrideGhosts then EllesmereUI._DeselectOverrideGhosts() end
end

-- Namespace bridge so the fallback ghost overlays (defined earlier in the
-- file) can release a selected mover when a ghost is clicked.
EllesmereUI._DeselectSelectedMover = DeselectMover

-- Apply dark overlay state to all movers
local function ApplyDarkOverlays()
    for _, m in pairs(movers) do
        if UM.darkOverlaysEnabled then
            m._bg:SetColorTexture(m._bgR or 0.075, m._bgG or 0.113, m._bgB or 0.141, 0.95)
            if m._label then m._label:SetAlpha(1); m._label:Show() end
            if m._subtitle then m._subtitle:SetAlpha(1); m._subtitle:Show() end
            if m._coordFS then m._coordFS:SetAlpha(1) end
            -- Action row is hover-only now, don't show it here
            if not m._dragging then m:SetAlpha(1) end
        else
            m._bg:SetColorTexture(0, 0, 0, 0)
            if m._label then m._label:Hide() end
            if m._subtitle then m._subtitle:Hide() end
            -- When coords-always-on is active, show coords for all movers; otherwise hide
            if m._coordFS then
                if UM.coordsEnabled then
                    if m.UpdateCoordText then m:UpdateCoordText() end
                else
                    m._coordFS:Hide()
                end
            end
            -- Hide action row text
            if m._hideOverlayText then m._hideOverlayText() end
            -- Restore normal alpha behavior
            if not m._dragging and not m._selected and not m:IsMouseOver() then
                m:SetAlpha(MOVER_ALPHA)
            end
        end
    end
end
-- Attach a mover to its bar's TOPLEFT, inset by il/-it (UIParent units). An
-- element whose frame carries a forbidden layout aspect (a Blizzard Style unit
-- cast bar riding its frame's aura stack, created with Blizzard's
-- DisableUntrustedLayoutScriptsTemplate) refuses dependents that lack the
-- aspect, so its mover takes the same screen spot by absolute anchor instead
-- (elem.detachedMover); every sync and apply path re-runs this, so it keeps
-- up outside of drags.
local function AttachMoverToBar(m, bar, key, il, it)
    m:ClearAllPoints()
    local elem = registeredElements[key]
    if elem and elem.detachedMover then
        local bL, bT = bar:GetLeft(), bar:GetTop()
        if not (issecretvalue and (issecretvalue(bL) or issecretvalue(bT))) and bL and bT then
            local r = bar:GetEffectiveScale() / UIParent:GetEffectiveScale()
            m:SetPoint("TOPLEFT", UIParent, "TOPLEFT", bL * r + (il or 0), bT * r - UIParent:GetHeight() - (it or 0))
        else
            -- No readable rect yet: park at the screen centre (the bar's own
            -- anchor is the one this element refuses) until the next sync.
            m:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        end
        return
    end
    m:SetPoint("TOPLEFT", bar, "TOPLEFT", il or 0, -(it or 0))
end
-- CreateMover is at Lua's 60-upvalue cap: its closures call this through the
-- namespace table (already an upvalue there), like NudgeMover below.
EllesmereUI._unlockAttachMover = AttachMoverToBar

local function NudgeMover(dx, dy, targetMover, skipCollapse)
    local m = targetMover or UM.selectedMover
    if not m or InCombatLockdown() then return end
    if ns.IsMoverPosLocked(m._barKey) then return end

    -- Read bar's current position, add dx/dy, reposition.
    local bar = UM.GetBarFrame(m._barKey)
    if not bar then return end

    local ai = GetAnchorInfo(m._barKey)
    if ai and ai.target then
        -- Anchored: adjust offset relative to target frame (not UIParent). Reading
        -- GetPoint(1) on an anchored element returns args relative to the target frame -- applying those to UIParent teleports the bar.
        ai.offsetX = (ai.offsetX or 0) + dx
        ai.offsetY = (ai.offsetY or 0) + dy
        -- The growth-edge pin rides the same nudge on its axis.
        if ai.edgeOffX ~= nil then ai.edgeOffX = ai.edgeOffX + dx end
        if ai.edgeOffY ~= nil then ai.edgeOffY = ai.edgeOffY + dy end
        -- An axis held by the cross-axis screen edge takes the nudge there, or the
        -- next apply overwrites it from the untouched edge offset.
        if ai.edge and ai.edge.key then
            local nAxis = EllesmereUI._ScreenEdgeAxis(ai.edge.key)
            if nAxis == "X" then ai.edge.offset = (ai.edge.offset or 0) + dx
            elseif nAxis == "Y" then ai.edge.offset = (ai.edge.offset or 0) + dy end
        end
        UM.ApplyAnchorPosition(m._barKey, ai.target, ai.side)
        -- Capture the bar's resulting position so CommitPositions saves the real
        -- (nudged) location. ApplyAnchorPosition always anchors the bar to UIParent,
        -- so GetPoint(1) is UIParent-relative and safe to store. A coordless
        -- {_anchored=true} marker would make CommitPositions fall back to the
        -- pre-edit snapshot, reverting bars that read their saved edge on exit/reload.
        local bpt, brelTo, brp, bx, by = bar:GetPoint(1)
        if bpt and brelTo == UIParent and bx ~= nil and by ~= nil then
            pendingPositions[m._barKey] = { point = bpt, relPoint = brp, x = bx, y = by }
        else
            pendingPositions[m._barKey] = { _anchored = true }
        end
    else
        -- Unanchored: read current position, add dx/dy
        local pt, _, relPt, offX, offY = bar:GetPoint(1)
        if not pt then return end
        pcall(function()
            bar:ClearAllPoints()
            bar:SetPoint(pt, UIParent, relPt, offX + dx, offY + dy)
        end)
        -- Keep the LOGICAL pending value exact for CENTER/CENTER elements: previous
        -- pending/stored value + the exact delta, never a live geometry read-back.
        -- Odd-pixel-dimension frames apply with a half-pixel physical center, so
        -- reading the frame back here would bake that half pixel (and its rounding) into the saved value -- "nudged to -368, saves back as -369".
        local prev = pendingPositions[m._barKey]
        if type(prev) ~= "table" or prev._anchored or not prev.point then
            local elemN = registeredElements[m._barKey]
            prev = elemN and elemN.loadPosition and elemN.loadPosition(m._barKey) or nil
            if not prev then prev = LoadBarPosition(m._barKey) end
        end
        if type(prev) == "table" and prev.point == "CENTER"
           and (prev.relPoint or "CENTER") == "CENTER"
           and prev.x and prev.y then
            pendingPositions[m._barKey] = {
                point = "CENTER", relPoint = "CENTER",
                x = prev.x + dx, y = prev.y + dy,
            }
        else
            pendingPositions[m._barKey] = {
                point = pt, relPoint = relPt,
                x = offX + dx, y = offY + dy,
            }
        end
    end
    -- Same element follow-up the drag gives after each placement (main chat
    -- restores its size corner), before the mover and the anchor chain read
    -- the frame's rect.
    local elem = registeredElements[m._barKey]
    if elem and elem.onLiveMove then
        pcall(elem.onLiveMove, m._barKey)
    end
    UM.hasChanges = true

    -- Reanchor mover to bar, inside the element's visual insets (see Sync).
    local nIL, nIR, nIT, nIB = 0, 0, 0, 0
    if elem and elem.getInsets then
        local l, r, t, bt = elem.getInsets(m._barKey)
        if l then
            local es = bar:GetEffectiveScale() / UIParent:GetEffectiveScale()
            nIL, nIR, nIT, nIB = l * es, (r or 0) * es, (t or 0) * es, (bt or 0) * es
        end
    end
    AttachMoverToBar(m, bar, m._barKey, nIL, nIT)

    -- Update stored mover center from bar's new position
    local bL, bR = bar:GetLeft(), bar:GetRight()
    local bT, bB = bar:GetTop(), bar:GetBottom()
    if bL and bR and bT and bB then
        local s = bar:GetEffectiveScale()
        local uiS = UIParent:GetEffectiveScale()
        local ratio = s / uiS
        local cx = (bL + bR) * 0.5 * ratio + (nIL - nIR) * 0.5
        local cy = (bT + bB) * 0.5 * ratio - UIParent:GetHeight() + (nIB - nIT) * 0.5
        if m._setCenterXY then m._setCenterXY(cx, cy) end
    end

    -- Propagate to anchored children
    UM.PropagateAnchorChain(m._barKey)

    -- Update coordinate readout
    if m.UpdateCoordText then m:UpdateCoordText() end

    -- Collapse the mover while nudging (arrow keys only). Typed cog edits pass
    -- skipCollapse so the open cog menu, which is anchored to the mover, does
    -- not jump or shrink while the user is typing in it.
    if not skipCollapse then
        if m._forceCollapse then m._forceCollapse() end
        m._nudgeCollapsed = true
    end
end

-- Exposed so the cog X/Y edit boxes can drive the SAME pixel-exact move the
-- arrow keys use. Calling through the namespace table (already an upvalue in
-- CreateMover) avoids adding NudgeMover as a new upvalue to that large closure.
EllesmereUI._unlockNudge = NudgeMover

-- Grow-direction change for a growth bar in unlock mode, the cog's Grow row in
-- one call: write the module's setting and relayout, put the bar's visual center
-- back where it was (a relayout can shift the frame around its new fixed edge),
-- re-anchor by the new growth edge and record the position for Save & Exit.
-- Shared with the anchor picker's corner rows, which set the direction AFTER
-- placing the bar flush so the growth-edge hold captures from where it sits.
-- On the namespace table like the nudge: CreateMover is at the upvalue cap.
EllesmereUI._unlockSetGrowDirection = function(barKey, val)
    UM.hasChanges = true

    -- Capture the bar's visual center before changing grow
    local barFrame = UM.GetBarFrame(barKey)
    local preCX, preCY
    if barFrame then
        preCX, preCY = barFrame:GetCenter()
    end

    -- Write to the bar's actual settings DB and rebuild layout
    if barKey:sub(1, 4) == "CDM_" then
        local rawKey = barKey:sub(5)
        local cdm = EllesmereUI.Lite.GetAddon("EllesmereUICooldownManager", true)
        local cdmBars = cdm and cdm.db and cdm.db.profile and cdm.db.profile.cdmBars
        if cdmBars and cdmBars.bars then
            for _, bar in ipairs(cdmBars.bars) do
                if bar.key == rawKey then
                    bar.growDirection = val
                    break
                end
            end
        end
        if EllesmereUI.LayoutCDMBar then
            EllesmereUI.LayoutCDMBar(rawKey)
        end
        EllesmereUI.RecenterBarAnchor(barKey)
    elseif barKey == "ERB_TotemBar" then
        local erb = EllesmereUI.Lite.GetAddon("EllesmereUIResourceBars", true)
        local tb = erb and erb.db and erb.db.profile and erb.db.profile.totemBar
        if tb then tb.growDirection = val end
        if EllesmereUI.LayoutTotemBar then EllesmereUI.LayoutTotemBar() end
        EllesmereUI.RecenterBarAnchor(barKey)
    elseif barKey == "EABR_Reminders" then
        if EllesmereUI.SetAuraBuffGrowDir then EllesmereUI.SetAuraBuffGrowDir(val) end
        EllesmereUI.RecenterBarAnchor(barKey)
    elseif barKey:sub(1, 4) == "PAB_" then
        local euf = EllesmereUI.Lite.GetAddon("EllesmereUIUnitFrames", true)
        if euf and euf.SetGrowDirectionForBar then
            euf:SetGrowDirectionForBar(barKey, val)
        end
    else
        local eab = EllesmereUI.Lite.GetAddon("EllesmereUIActionBars", true)
        if eab and eab.SetGrowDirectionForBar then
            eab:SetGrowDirectionForBar(barKey, val)
        end
    end

    -- Restore the bar's visual center so it doesn't jump,
    -- then re-anchor based on the new growth direction.
    if barFrame and preCX and preCY then
        local postCX, postCY = barFrame:GetCenter()
        if postCX and postCY then
            local dx = preCX - postCX
            local dy = preCY - postCY
            if math.abs(dx) > 0.5 or math.abs(dy) > 0.5 then
                local pt, relTo, relPt, offX, offY = barFrame:GetPoint(1)
                if pt then
                    barFrame:ClearAllPoints()
                    barFrame:SetPoint(pt, relTo, relPt, offX + dx, offY + dy)
                end
            end
        end
    end
    EllesmereUI.RecenterBarAnchor(barKey)
    -- Anchored bars: hold the new growth edge from where the bar sits NOW, the
    -- way the drag-stop path does after a drop. Left to the lazy capture, the
    -- next apply would read the rect BEFORE the move it was asked to make (a
    -- first nudge, a first drag of the target) and stamp that stale hold; and a
    -- hold left over from an earlier direction would be trusted again the day
    -- that direction comes back. Centered growth keeps no hold.
    local ai = GetAnchorInfo(barKey)
    if ai and ai.target then
        ai.refFor, ai.refX, ai.refY, ai.edgeOffX, ai.edgeOffY = nil, nil, nil, nil, nil
        if EllesmereUI._unlockCaptureGrowPin then
            EllesmereUI._unlockCaptureGrowPin(barKey, ai, ai.side)
        end
    end
    -- Store in pending (committed on Save & Exit)
    if barFrame then
        local pt2, relTo2, relPt2, offX2, offY2 = barFrame:GetPoint(1)
        if pt2 then
            pendingPositions[barKey] = {
                point = pt2, relPoint = relPt2, x = offX2, y = offY2,
            }
            UM.hasChanges = true
        end
    end

    -- Sync the mover to the bar's new position
    if movers[barKey] and movers[barKey].Sync then
        movers[barKey]:Sync()
    end
end

-- Arrow key nudge: single press only, no hold-to-repeat
local function SetupArrowKeyFrame()
    if UM.arrowKeyFrame then return end
    UM.arrowKeyFrame = CreateFrame("Frame", nil, UIParent)
    UM.arrowKeyFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    UM.arrowKeyFrame:SetFrameLevel(500)
    UM.arrowKeyFrame:EnableKeyboard(true)
    UM.arrowKeyFrame:SetPropagateKeyboardInput(true)
    UM.arrowKeyFrame:Hide()

    local ARROW_DIRS = {
        UP    = { 0,  1 },
        DOWN  = { 0, -1 },
        LEFT  = { -1, 0 },
        RIGHT = { 1,  0 },
    }

    UM.arrowKeyFrame:SetScript("OnKeyDown", function(self, key)
        if not UM.isUnlocked then return end
        local dir = ARROW_DIRS[key]
        if not dir then return end
        -- A selected fallback ghost answers the arrow keys with the exact
        -- same step math as movers (1 physical pixel; shift = 100).
        if not UM.selectedMover and EllesmereUI._NudgeSelectedFallbackGhost then
            local PPg = EllesmereUI and EllesmereUI.PP
            local gStep = PPg and PPg.mult or 1
            local gs = IsShiftKeyDown() and (100 * gStep) or gStep
            if EllesmereUI._NudgeSelectedFallbackGhost(dir[1] * gs, dir[2] * gs) then
                self:SetPropagateKeyboardInput(false)
                return
            end
        end
        -- A selected override-anchor ghost answers the same way.
        if not UM.selectedMover and EllesmereUI._NudgeSelectedOverrideGhost then
            local PPo = EllesmereUI and EllesmereUI.PP
            local oStep = PPo and PPo.mult or 1
            local os = IsShiftKeyDown() and (100 * oStep) or oStep
            if EllesmereUI._NudgeSelectedOverrideGhost(dir[1] * os, dir[2] * os) then
                self:SetPropagateKeyboardInput(false)
                return
            end
        end
        if not UM.selectedMover then return end
        self:SetPropagateKeyboardInput(false)
        -- Scale by physical pixel size so each press moves exactly 1px
        local PPn = EllesmereUI and EllesmereUI.PP
        local pxStep = PPn and PPn.mult or 1
        local step = IsShiftKeyDown() and (100 * pxStep) or pxStep
        -- When this element's cog/snap menu is open, keep the mover expanded
        -- (skipCollapse) so the open menu does not jump, then reanchor to the bar
        -- and refresh the cog X/Y boxes so they track the nudge.
        local m = UM.selectedMover
        local menuOpen = m._menuOpen
        NudgeMover(dir[1] * step, dir[2] * step, nil, menuOpen)
        if menuOpen then
            if m.ReanchorToBar then m:ReanchorToBar() end
            if m._syncCogPos then m._syncCogPos() end
        end
    end)

    UM.arrowKeyFrame:SetScript("OnKeyUp", function(self, key)
        self:SetPropagateKeyboardInput(true)
    end)
end

-------------------------------------------------------------------------------
--  Action bar visual size helper: computes the actual visual size of an action bar
--  accounting for overrideNumIcons, overrideNumRows, padding, and per-button scale.
--  Returns w, h in UIParent-relative pixels, or nil if not applicable.
-------------------------------------------------------------------------------
local function GetActionBarVisualSize(barKey)
    if not EAB or not EAB.db then return nil end
    local info = BAR_LOOKUP[barKey]
    if not info then return nil end
    local s = EAB.db.profile.bars[lookupKey]
    if not s then return nil end

    -- Use standard button size (45x45) -- our LayoutBar uses this for MainBar
    -- and reads from the button for others.
    local btnW, btnH = 45, 45
    local btn1 = _G[info.buttonPrefix .. "1"]
    if btn1 and lookupKey ~= "MainBar" then
        local bw = btn1:GetWidth()
        if bw and bw > 1 then btnW, btnH = bw, btn1:GetHeight() end
    end

    local numVisible = s.overrideNumIcons or s.numIcons or info.count
    if numVisible < 1 then numVisible = info.count end
    local numRows = s.overrideNumRows or s.numRows or 1
    if numRows < 1 then numRows = 1 end

    local pad = s.buttonPadding or 2

    -- Use explicit button dimensions if set
    local bwOverride = (s.buttonWidth and s.buttonWidth > 0) and s.buttonWidth or nil
    local bhOverride = (s.buttonHeight and s.buttonHeight > 0) and s.buttonHeight or nil
    if bwOverride then btnW = bwOverride end
    if bhOverride then btnH = bhOverride end

    local shape = s.buttonShape or "none"
    if shape ~= "none" and shape ~= "cropped" then
        btnW = btnW + (ns.SHAPE_BTN_EXPAND or 10)
        btnH = btnH + (ns.SHAPE_BTN_EXPAND or 10)
    end
    if shape == "cropped" then
        btnH = btnH * 0.80
    end

    local isVert = (s.orientation == "vertical")
    local stride = math.ceil(numVisible / numRows)

    local gridW, gridH
    if isVert then
        gridW = numRows * btnW + (numRows - 1) * pad
        gridH = stride * btnH + (stride - 1) * pad
    else
        gridW = stride * btnW + (stride - 1) * pad
        gridH = numRows * btnH + (numRows - 1) * pad
    end

    return gridW, gridH
end

-------------------------------------------------------------------------------
--  Mover overlay creation
-------------------------------------------------------------------------------

-- Sort movers by area so smaller elements render on top of larger ones.
-- Called after all movers are created and synced.
local function SortMoverFrameLevels()
    if not UM.unlockFrame then return end
    local BASE = UM.unlockFrame:GetFrameLevel() + 20
    local sorted = {}
    for key, m in pairs(movers) do
        local area = (m:GetWidth() or 100) * (m:GetHeight() or 100)
        sorted[#sorted + 1] = { key = key, mover = m, area = area }
    end
    -- Largest area first -> lowest frame level
    table.sort(sorted, function(a, b) return a.area > b.area end)
    for i, entry in ipairs(sorted) do
        local lvl = BASE + i
        entry.mover._baseLevel = lvl
        entry.mover._raisedLevel = lvl + #sorted + 5
        entry.mover:SetFrameLevel(lvl)
    end
end

-------------------------------------------------------------------------------
--  Blizzard-Owned Info Overlays: visual overlays shown during unlock mode on
--  elements whose position is controlled by Blizzard Edit Mode (chat, micro menu,
--  bags, encounter bar). Not draggable. Hover shows accent-colored "Move via Blizz
--  Edit Mode" text with the same animation as regular mover links; clicking closes unlock mode and opens Blizzard's Edit Mode.
-------------------------------------------------------------------------------
local BLIZZ_OWNED_OVERLAY_DEFS = {
    -- Chat is NOT here anymore: it is a REAL unlock element registered by
    -- EllesmereUIChat (position genesis-captured from Edit Mode's last spot,
    -- then enforced against Edit Mode via the chat module's anchor guard).
    { label = "Micro Menu",    frame = function() return _G.MicroMenuContainer end },
    { label = "Bags",          frame = function() return _G.BagsBar end },
    { label = "Encounter Bar", frame = function() return _G.PlayerPowerBarAlt end, showAlways = true, fallbackW = 240, fallbackH = 36, yOffset = 44 },
    { label = "Buffs",         frame = function() return _G.BuffFrame end },
    { label = "Debuffs",       frame = function() return _G.DebuffFrame end },
    -- Blizzard Edit Mode's default tooltip anchor. EUI permanently owns the default
    -- tooltip position (fixed anchor in EllesmereUIBlizzardSkin, a real draggable
    -- mover) and Anchor to Cursor pins it to the mouse -- either way this read-only
    -- overlay steps aside. Only shows with "Reskin Tooltip" off, where Blizzard's
    -- position genuinely applies. Container is small/idle when no tooltip is up, so use the showAlways fallback like the Encounter Bar.
    { label = "Tooltip",       frame = function()
          if not (EllesmereUIDB and EllesmereUIDB.customTooltips == false) then return nil end
          return _G.GameTooltipDefaultContainer
      end, showAlways = true, fallbackW = 280, fallbackH = 165 },
}

local function CreateBlizzOwnedOverlay(def, parent)
    local ar, ag, ab = GetAccent()
    local ov = CreateFrame("Frame", nil, parent)
    ov:EnableMouse(true)
    -- Background: same as regular movers
    local bg = ov:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.075, 0.113, 0.141, 0.95)
    -- Border: accent at idle, white on hover
    local brd = EllesmereUI.MakeBorder(ov, ar, ag, ab, 0.6)
    ov._brd = brd
    -- Label (always visible, same style as mover labels)
    local nameFs = ov:CreateFontString(nil, "OVERLAY")
    EllesmereUI.PrimeFontShadow(nameFs, true)
    nameFs:SetFont(FONT_PATH, 10 + (UIParent:GetEffectiveScale() < 0.6 and 1 or 0), "")
    nameFs:SetPoint("CENTER", ov, "CENTER", 0, 0)
    nameFs:SetTextColor(1, 1, 1, 0.75)
    nameFs:SetText(EllesmereUI.L(def.label))
    nameFs:SetWordWrap(false)
    ov._nameFs = nameFs
    -- Action text (hidden at idle, fades in on hover)
    local actionFs = ov:CreateFontString(nil, "OVERLAY")
    EllesmereUI.PrimeFontShadow(actionFs, true)
    actionFs:SetFont(FONT_PATH, 9 + (UIParent:GetEffectiveScale() < 0.6 and 1 or 0), "")
    actionFs:SetPoint("TOP", nameFs, "BOTTOM", 0, -2)
    actionFs:SetTextColor(ar, ag, ab, 0.9)
    actionFs:SetText(EllesmereUI.L("Move via Blizz Edit Mode"))
    actionFs:SetAlpha(0)
    ov._actionFs = actionFs
    -- Clickable button sized to the action text only
    local actionBtn = CreateFrame("Button", nil, ov)
    actionBtn:SetFrameLevel(ov:GetFrameLevel() + 2)
    actionBtn:SetPoint("TOPLEFT", actionFs, "TOPLEFT", -4, 2)
    actionBtn:SetPoint("BOTTOMRIGHT", actionFs, "BOTTOMRIGHT", 4, -2)
    actionBtn:Hide()
    -- Hover animation state
    local hoverT = 0
    local hoverTarget = 0
    local animFrame = CreateFrame("Frame")
    local function ApplyHover(t)
        actionFs:SetAlpha(t)
        if t > 0.01 then actionBtn:Show() else actionBtn:Hide() end
        -- Shift label up to make room for action text
        local yOff = t * 5
        nameFs:SetPoint("CENTER", ov, "CENTER", 0, yOff)
    end
    animFrame:SetScript("OnUpdate", function(self, dt)
        local dir = hoverTarget > hoverT and 1 or -1
        hoverT = hoverT + dir * (dt / 0.15)
        if (dir == 1 and hoverT >= hoverTarget) or (dir == -1 and hoverT <= hoverTarget) then
            hoverT = hoverTarget
            if hoverT == 0 then self:Hide() end
        end
        ApplyHover(hoverT)
    end)
    animFrame:Hide()
    -- Hover handlers on the overlay frame
    local function OnEnter()
        hoverTarget = 1
        ov._brd:SetColor(1, 1, 1, 0.9)
        animFrame:Show()
    end
    local function OnLeave()
        if actionBtn:IsShown() and actionBtn:IsMouseOver() then return end
        if ov:IsMouseOver() then return end
        hoverTarget = 0
        ov._brd:SetColor(ar, ag, ab, 0.6)
        animFrame:Show()
    end
    ov:SetScript("OnEnter", OnEnter)
    ov:SetScript("OnLeave", OnLeave)
    -- Action button hover: brighten text, keep overlay hovered
    actionBtn:SetScript("OnEnter", function()
        actionFs:SetTextColor(1, 1, 1, 1)
        OnEnter()
    end)
    actionBtn:SetScript("OnLeave", function()
        actionFs:SetTextColor(ar, ag, ab, 0.9)
        OnLeave()
    end)
    -- Click: close unlock mode, open Blizzard Edit Mode
    actionBtn:SetScript("OnClick", function()
        if InCombatLockdown() then return end
        if EditModeManagerFrame then
            ns.RequestClose(false, function()
                ShowUIPanel(EditModeManagerFrame)
            end)
        end
    end)
    ov._forceCollapse = function()
        hoverT = 0; hoverTarget = 0
        animFrame:Hide()
        ApplyHover(0)
        ov._brd:SetColor(ar, ag, ab, 0.6)
    end
    -- Shift+Right Click temporarily hides this overlay for the current unlock
    -- session (matches the regular mover behavior). The _tempHidden flag is
    -- cleared on the next unlock entry so the overlay reappears then. Purely a
    -- visual toggle on the info overlay -- it never touches the Blizzard frame.
    local function TempHide(_, button)
        if button == "RightButton" and IsShiftKeyDown() then
            ov._tempHidden = true
            ov._forceCollapse()
            ov:Hide()
        end
    end
    ov:SetScript("OnMouseUp", TempHide)
    -- The hover action strip (a child button) swallows mouse events over itself,
    -- so wire the same handler there to catch a Shift+Right Click landing on it.
    actionBtn:SetScript("OnMouseUp", TempHide)
    return ov
end

local function ShowBlizzOwnedOverlays(parent)
    for _, def in ipairs(BLIZZ_OWNED_OVERLAY_DEFS) do
        local anchorFrame = def.frame()
        if not anchorFrame then
            -- frame doesn't exist at all, skip
        elseif anchorFrame:IsShown() and anchorFrame:GetWidth() > 1 then
            -- Visible frame: anchor directly
            local ov = _blizzOwnedOverlays[def.label]
            if not ov then
                ov = CreateBlizzOwnedOverlay(def, parent)
                _blizzOwnedOverlays[def.label] = ov
            end
            -- Same strata as the regular movers (FULLSCREEN_DIALOG) but a lower level
            -- (movers sit at unlockFrame+20), so non-Blizzard overlays always render
            -- above these Blizzard Edit Mode overlays. Still above the dimmer (+1).
            ov:SetFrameStrata("FULLSCREEN_DIALOG")
            ov:SetFrameLevel(parent:GetFrameLevel() + 15)
            ov:ClearAllPoints()
            if def.anchor then
                def.anchor(ov, anchorFrame)
            else
                ov:SetAllPoints(anchorFrame)
            end
            ov._forceCollapse()
            ov:Show()
        elseif def.showAlways then
            -- Hidden frame but showAlways: position at frame's location with fallback size
            local ov = _blizzOwnedOverlays[def.label]
            if not ov then
                ov = CreateBlizzOwnedOverlay(def, parent)
                _blizzOwnedOverlays[def.label] = ov
            end
            -- FULLSCREEN_DIALOG (below movers at +20, above the dimmer at +1) so
            -- non-Blizzard overlays always render above Blizzard Edit Mode overlays.
            ov:SetFrameStrata("FULLSCREEN_DIALOG")
            ov:SetFrameLevel(parent:GetFrameLevel() + 15)
            ov:ClearAllPoints()
            ov:SetSize(def.fallbackW or 200, def.fallbackH or 40)
            -- Read the frame's current anchor or fall back to bottom center
            local pt, rel, rpt, ox, oy = anchorFrame:GetPoint(1)
            local yAdj = def.yOffset or 0
            if pt and rel then
                ov:SetPoint(pt, rel, rpt or pt, ox or 0, (oy or 0) + yAdj)
            else
                ov:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 200 + yAdj)
            end
            ov._forceCollapse()
            ov:Show()
        end
    end
end

local function HideBlizzOwnedOverlays()
    for _, ov in pairs(_blizzOwnedOverlays) do
        if ov._forceCollapse then ov._forceCollapse() end
        ov:Hide()
    end
end

local _mouseHeld = false       -- true while left mouse button is held down anywhere

local function CreateMover(barKey)
    local elem = registeredElements[barKey]
    local existing = movers[barKey]

    -- Skip elements that are intentionally hidden or currently anchored
    -- (keepMoverWhenAnchored elements keep a position-locked mover instead).
    if elem and ((elem.isHidden and elem.isHidden())
        or (elem.isAnchored and elem.isAnchored() and not elem.keepMoverWhenAnchored)) then
        if existing then existing:Hide() end
        return nil
    end

    if existing then return existing end

    local bar = UM.GetBarFrame(barKey)
    if not bar then return nil end

    local ar, ag, ab = GetAccent()
    local label = UM.GetBarLabel(barKey)
    local cogBtn  -- forward declaration; assigned later in CreateMover

    local mover = CreateFrame("Button", nil, UM.unlockFrame)
    -- Party Frames always render above Raid Frames in unlock mode
    local MOVER_LEVEL_BUMP = (barKey == "RF_PartyFrames") and 10 or 0
    local MOVER_BASE_LEVEL = UM.unlockFrame:GetFrameLevel() + 20 + MOVER_LEVEL_BUMP
    local MOVER_RAISED_LEVEL = MOVER_BASE_LEVEL + 5
    mover:SetFrameLevel(MOVER_BASE_LEVEL)
    mover._baseLevel = MOVER_BASE_LEVEL
    mover._raisedLevel = MOVER_RAISED_LEVEL
    mover:SetClampedToScreen(true)
    mover:SetMovable(true)
    mover:RegisterForDrag("LeftButton")
    mover:EnableMouse(true)
    mover:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then _mouseHeld = true end
    end)
    -- OnMouseUp is set later (after link buttons are created) to also handle link drag forwarding

    -- Background (matches cogwheel dark color at 75% opacity). Elements may
    -- override the base color via their moverBg definition field; the base is
    -- stored on the mover so snap-highlight and dark-overlay repaints keep it.
    local regElem = registeredElements[barKey]
    local bgTint = regElem and regElem.moverBg
    mover._bgR = bgTint and bgTint.r or 0.075
    mover._bgG = bgTint and bgTint.g or 0.113
    mover._bgB = bgTint and bgTint.b or 0.141
    local bg = mover:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    if UM.darkOverlaysEnabled then
        bg:SetColorTexture(mover._bgR, mover._bgG, mover._bgB, 0.95)
    else
        bg:SetColorTexture(0, 0, 0, 0)
    end
    mover._bg = bg

    -- Pixel-perfect border (accent colored, uses shared MakeBorder)
    local brd = EllesmereUI.MakeBorder(mover, ar, ag, ab, 0.6)
    mover._brd = brd

    -- Label -- on a higher-level frame so it renders above the border
    local labelFrame = CreateFrame("Frame", nil, mover)
    labelFrame:SetAllPoints()
    labelFrame:SetClipsChildren(true)
    labelFrame:SetFrameLevel(mover:GetFrameLevel() + 3)
    local nameFS = labelFrame:CreateFontString(nil, "OVERLAY")
    EllesmereUI.PrimeFontShadow(nameFS, true)
    nameFS:SetFont(FONT_PATH, 10 + (UIParent:GetEffectiveScale() < 0.6 and 1 or 0), "")
    nameFS:SetText(EllesmereUI.L(label))
    nameFS:SetTextColor(1, 1, 1, 0.75)
    nameFS:SetWordWrap(false)
    nameFS:SetNonSpaceWrap(false)
    nameFS:SetPoint("CENTER", mover, "CENTER")
    mover._label = nameFS
    if not UM.darkOverlaysEnabled then nameFS:Hide() end

    -- Optional dimmed subtitle under the label (element definition field)
    if regElem and regElem.subtitle then
        local subFS = labelFrame:CreateFontString(nil, "OVERLAY")
        EllesmereUI.PrimeFontShadow(subFS, true)
        subFS:SetFont(FONT_PATH, 8 + (UIParent:GetEffectiveScale() < 0.6 and 1 or 0), "")
        subFS:SetText(EllesmereUI.L(regElem.subtitle))
        subFS:SetTextColor(1, 1, 1, 0.40)
        subFS:SetJustifyH("CENTER")
        subFS:SetWordWrap(true)
        subFS:SetNonSpaceWrap(false)
        subFS:SetPoint("TOP", nameFS, "BOTTOM", 0, -3)
        subFS:SetPoint("LEFT", labelFrame, "LEFT", 8, 0)
        subFS:SetPoint("RIGHT", labelFrame, "RIGHT", -8, 0)
        mover._subtitle = subFS
        if not UM.darkOverlaysEnabled then subFS:Hide() end
    end

    -- Coordinate readout (shows during drag and selection, top-left of mover)
    local coordFS = labelFrame:CreateFontString(nil, "OVERLAY")
    EllesmereUI.PrimeFontShadow(coordFS, true)
    coordFS:SetFont(FONT_PATH, 9 + (UIParent:GetEffectiveScale() < 0.6 and 1 or 0), "")
    coordFS:SetTextColor(1, 1, 1, 0.7)
    coordFS:SetPoint("TOPLEFT", mover, "TOPLEFT", 3, -2)
    coordFS:Hide()
    mover._coordFS = coordFS

    ---------------------------------------------------------------------------
    --  W Match | H Match | Anchor | Grow  (centered below the name)
    --  Also: "Anchored" text and pick-mode instruction text
    ---------------------------------------------------------------------------
    -- Action link text labels
    local WM_TEXT = "W Match"
    local HM_TEXT = "H Match"
    local AT_TEXT = "Anchor"
    local GD_TEXT = "Grow"

    -- Clickable buttons for each action (parented to labelFrame for correct level)
    local wmBtn = CreateFrame("Button", nil, labelFrame)
    wmBtn:SetFrameLevel(labelFrame:GetFrameLevel() + 2)
    wmBtn:RegisterForClicks("LeftButtonUp")
    wmBtn:EnableMouse(true)
    wmBtn:Hide()

    local hmBtn = CreateFrame("Button", nil, labelFrame)
    hmBtn:SetFrameLevel(labelFrame:GetFrameLevel() + 2)
    hmBtn:RegisterForClicks("LeftButtonUp")
    hmBtn:EnableMouse(true)
    hmBtn:Hide()

    local atBtn = CreateFrame("Button", nil, labelFrame)
    atBtn:SetFrameLevel(labelFrame:GetFrameLevel() + 2)
    atBtn:RegisterForClicks("LeftButtonUp")
    atBtn:EnableMouse(true)
    atBtn:Hide()

    local gdBtn = CreateFrame("Button", nil, labelFrame)
    gdBtn:SetFrameLevel(labelFrame:GetFrameLevel() + 2)
    gdBtn:RegisterForClicks("LeftButtonUp")
    gdBtn:EnableMouse(true)
    gdBtn:Hide()

    -- Store link buttons on mover so OnLeave can check if any are hovered
    mover._linkBtns = { wmBtn, hmBtn, atBtn, gdBtn }

    -- Font strings inside each button (accent colored, drop shadow)
    local wmFS = wmBtn:CreateFontString(nil, "OVERLAY")
    EllesmereUI.PrimeFontShadow(wmFS, true)
    wmFS:SetFont(FONT_PATH, 9, "")
    wmFS:SetTextColor(ar, ag, ab, 0.85)
    wmFS:SetText(EllesmereUI.L(WM_TEXT))
    wmFS:SetPoint("CENTER")

    local hmFS = hmBtn:CreateFontString(nil, "OVERLAY")
    EllesmereUI.PrimeFontShadow(hmFS, true)
    hmFS:SetFont(FONT_PATH, 9, "")
    hmFS:SetTextColor(ar, ag, ab, 0.85)
    hmFS:SetText(EllesmereUI.L(HM_TEXT))
    hmFS:SetPoint("CENTER")

    local atFS = atBtn:CreateFontString(nil, "OVERLAY")
    EllesmereUI.PrimeFontShadow(atFS, true)
    atFS:SetFont(FONT_PATH, 9, "")
    atFS:SetTextColor(ar, ag, ab, 0.85)
    atFS:SetText(EllesmereUI.L(AT_TEXT))
    atFS:SetPoint("CENTER")

    local gdFS = gdBtn:CreateFontString(nil, "OVERLAY")
    EllesmereUI.PrimeFontShadow(gdFS, true)
    gdFS:SetFont(FONT_PATH, 9, "")
    gdFS:SetTextColor(ar, ag, ab, 0.85)
    gdFS:SetText(EllesmereUI.L(GD_TEXT))
    gdFS:SetPoint("CENTER")

    -- 1px pixel-perfect divider lines between action links
    local PP = EllesmereUI and EllesmereUI.PP
    local divPx = PP and PP.mult or 1

    local div1 = labelFrame:CreateTexture(nil, "OVERLAY")
    div1:SetColorTexture(1, 1, 1, 0.25)
    div1:SetWidth(divPx)
    div1:SetHeight(10)
    if div1.SetSnapToPixelGrid then div1:SetSnapToPixelGrid(false); div1:SetTexelSnappingBias(0) end
    div1:Hide()

    local div2 = labelFrame:CreateTexture(nil, "OVERLAY")
    div2:SetColorTexture(1, 1, 1, 0.25)
    div2:SetWidth(divPx)
    div2:SetHeight(10)
    if div2.SetSnapToPixelGrid then div2:SetSnapToPixelGrid(false); div2:SetTexelSnappingBias(0) end
    div2:Hide()

    local div3 = labelFrame:CreateTexture(nil, "OVERLAY")
    div3:SetColorTexture(1, 1, 1, 0.25)
    div3:SetWidth(divPx)
    div3:SetHeight(10)
    if div3.SetSnapToPixelGrid then div3:SetSnapToPixelGrid(false); div3:SetTexelSnappingBias(0) end
    div3:Hide()

    -- Determine if this element supports resizing
    local canResize = not (elem and elem.noResize)
    -- Determine if this element can be anchored to other elements
    local canAnchorTo = not (elem and elem.noAnchorTo)

    -- Grow direction: action bars 1-8 and CDM bars (both horizontal and vertical)
    local _GROW_KEYS = {
        MainBar = true, Bar2 = true, Bar3 = true, Bar4 = true,
        Bar5 = true, Bar6 = true, Bar7 = true, Bar8 = true,
        StanceBar = true, PetBar = true,
        ERB_TotemBar = true,   -- totem bar: align active icons left/right/center
        EABR_Reminders = true, -- aura buff reminders: align icons left/right/center
    }
    local canGrow = _GROW_KEYS[barKey] or barKey:sub(1, 4) == "CDM_" or barKey:sub(1, 4) == "PAB_"

    -- Match-source capability: width/height MATCH buttons may appear even when
    -- drag/manual resize is disabled (noResize), if the element opts in via
    -- allowMatchSource (e.g. tracking bars sized via their own sliders can still size-MATCH another element).
    local canMatchSource = canResize or (elem and elem.allowMatchSource) or false

    -- Single source of truth for which action-row link buttons are active, in
    -- left-to-right order. The layout, the hover show/hide, and the hover-box
    -- width calc all read this so they never drift apart. `fb` = fallback width.
    local function ActiveLinks()
        local t = {}
        if canMatchSource then
            t[#t + 1] = { btn = wmBtn, fs = wmFS, fb = 50 }
            t[#t + 1] = { btn = hmBtn, fs = hmFS, fb = 55 }
        end
        if canAnchorTo and not ns.IsMoverPosLocked(barKey) then
            t[#t + 1] = { btn = atBtn, fs = atFS, fb = 45 }
        end
        if canGrow then
            t[#t + 1] = { btn = gdBtn, fs = gdFS, fb = 30 }
        end
        return t
    end

    -- Layout: position action link buttons + dividers centered below name.
    -- Unified dynamic layout: lay out exactly the buttons ActiveLinks() reports,
    -- with one divider between each adjacent pair. This renders the existing
    -- cases pixel-identically and naturally handles match-buttons-without-resize.
    local function LayoutActionRow()
        local gap = 8
        local items = ActiveLinks()
        if #items == 0 then return end
        local divs = { div1, div2, div3 }
        local totalW = 0
        for i, it in ipairs(items) do
            it.w = it.fs:GetStringWidth() or it.fb
            totalW = totalW + it.w
            if i < #items then totalW = totalW + gap + 1 + gap end
        end
        local x = -totalW / 2
        for i, it in ipairs(items) do
            it.btn:SetSize(it.w + 4, 14); it.btn:ClearAllPoints()
            it.btn:SetPoint("TOP", nameFS, "BOTTOM", x + it.w / 2, -4)
            x = x + it.w
            if i < #items and divs[i] then
                divs[i]:ClearAllPoints()
                divs[i]:SetPoint("TOP", nameFS, "BOTTOM", x + gap + 0.5, -6)
                x = x + gap + 1 + gap
            end
        end
    end
    -- For MatchH.CommitMatchExtra (file scope): the matched label changes width.
    mover._layoutActionRow = LayoutActionRow

    -- Anchored indicator: name label turns orange when anchored
    -- No separate font string needed
    local anchoredFS = nil
    mover._anchoredFS = nil

    -- Pick mode instruction text (shown when in pick mode, replaces all other text)
    local pickFS = labelFrame:CreateFontString(nil, "OVERLAY")
    EllesmereUI.PrimeFontShadow(pickFS, true)
    pickFS:SetFont(FONT_PATH, 10 + (UIParent:GetEffectiveScale() < 0.6 and 1 or 0), "")
    pickFS:SetTextColor(1, 1, 1, 0.85)
    pickFS:SetPoint("CENTER", mover, "CENTER")
    pickFS:SetJustifyH("CENTER")
    pickFS:SetWordWrap(true)
    pickFS:Hide()
    mover._pickFS = pickFS

    ---------------------------------------------------------------------------
    --  Hover animation state
    --  0 = idle (name centered, action row hidden)
    --  1 = hovered (name shifted up, action row visible + faded in)
    ---------------------------------------------------------------------------
    local LABEL_Y_NORMAL  = 0
    local LABEL_Y_SHIFTED = 7
    local ANIM_DUR        = 0.15
    local hoverState      = 0
    local hoverTarget     = 0
    local isAnchored      = false
    local baseW, baseH    = 0, 0   -- real element size (set by Sync)
    local moverCX, moverCY = 0, 0  -- stored center in UIParent-TOPLEFT coords (set by Sync)
    mover._setCenterXY = function(cx, cy) moverCX = cx; moverCY = cy end
    mover._getCenterXY = function() return moverCX, moverCY end

    -- Re-anchor the mover directly to the bar frame so both share the exact same
    -- screen position with zero coordinate math (pixel-perfect). The bar's CENTER
    -- anchor is already applied synchronously by RecenterBarAnchor before this
    -- fires, so just update mover size and re-attach to bar TOPLEFT. Deferred one frame so the bar's layout has flushed after a move/resize.
    function mover:ReanchorToBar()
        local bk = self._barKey
        local self2 = self
        C_Timer.After(0, function()
            if self2._dragging then return end
            local b = UM.GetBarFrame(bk)
            if not b then return end
            -- A bar riding an engine aura container reports a secret rect
            -- outside unlock mode (the follow provider is inert inside it, so
            -- the bar rests plain there): nothing to attach to yet.
            local bl0 = b:GetLeft()
            if issecretvalue and issecretvalue(bl0) then return end
            local s = b:GetEffectiveScale()
            local uiS = UIParent:GetEffectiveScale()
            local elemScale = s / uiS
            -- Update size from bar (+ any below-frame extra, e.g. boss castbar).
            local elem = registeredElements[bk]
            local extra = (elem and elem.getBottomExtra and (elem.getBottomExtra(bk) or 0) or 0) * elemScale
            -- Visual insets (optional, e.g. a Blizzard Style unit frame whose stock
            -- box carries transparent padding round its art): the mover outlines
            -- the rect inside them. Left, right, top, bottom in the bar's units.
            local il, ir, it, ib = 0, 0, 0, 0
            if elem and elem.getInsets then
                local l, r, t, bt = elem.getInsets(bk)
                if l then il, ir, it, ib = l * elemScale, (r or 0) * elemScale, (t or 0) * elemScale, (bt or 0) * elemScale end
            end
            local w = (b:GetWidth() or 50) * elemScale - il - ir
            local h = (b:GetHeight() or 50) * elemScale + extra - it - ib
            if w > 10 then baseW = w end
            if h > 10 then baseH = h end
            self2:SetSize(baseW, baseH)
            -- Recompute moverCX/moverCY from bar's current center. Shift the
            -- stored center DOWN by half the extra so the box stays top-pinned
            -- to the frame and grows downward over the extra region; insets
            -- shift it by half their difference.
            local bcx, bcy = b:GetCenter()
            if bcx and bcy then
                moverCX = bcx * elemScale + (il - ir) * 0.5
                moverCY = bcy * elemScale - UIParent:GetHeight() - extra * 0.5 + (ib - it) * 0.5
            end
            -- Anchor mover to bar TOPLEFT for pixel-perfect overlay
            EllesmereUI._unlockAttachMover(self2, b, bk, il, it)
        end)
    end

    -- Refresh link button text/color based on active matches
    local function RefreshLinkStates()
        local wm = MatchH.GetWidthMatchInfo(barKey)
        local hm = MatchH.GetHeightMatchInfo(barKey)
        local ai = GetAnchorInfo(barKey)
        -- For linkedDimensions elements, one active match blocks the other
        local wmBlocked = elem and elem.linkedDimensions and hm ~= nil
        local hmBlocked = elem and elem.linkedDimensions and wm ~= nil
        if wm then
            wmFS:SetText(EllesmereUI.L("W Matched"))
            wmFS:SetTextColor(1, 0.7, 0.3, 0.85)
            -- A match's Extra Width rides the label: "W Matched +5".
            local wx = EllesmereUI.GetMatchExtra("w", barKey)
            if wx then wmFS:SetText(EllesmereUI.L("W Matched") .. (wx > 0 and " +" or " ") .. wx) end
        elseif wmBlocked then
            wmFS:SetText(EllesmereUI.L("W Match"))
            wmFS:SetTextColor(ar, ag, ab, 0.35)
        else
            wmFS:SetText(EllesmereUI.L("W Match"))
            wmFS:SetTextColor(ar, ag, ab, 0.85)
        end
        if hm then
            hmFS:SetText(EllesmereUI.L("H Matched"))
            hmFS:SetTextColor(1, 0.7, 0.3, 0.85)
            local hx = EllesmereUI.GetMatchExtra("h", barKey)
            if hx then hmFS:SetText(EllesmereUI.L("H Matched") .. (hx > 0 and " +" or " ") .. hx) end
        elseif hmBlocked then
            hmFS:SetText(EllesmereUI.L("H Match"))
            hmFS:SetTextColor(ar, ag, ab, 0.35)
        else
            hmFS:SetText(EllesmereUI.L("H Match"))
            hmFS:SetTextColor(ar, ag, ab, 0.85)
        end
        if ai then
            atFS:SetText(EllesmereUI.L("Anchored"))
            atFS:SetTextColor(1, 0.7, 0.3, 0.85)
        else
            atFS:SetText(EllesmereUI.L("Anchor"))
            atFS:SetTextColor(ar, ag, ab, 0.85)
        end
        gdFS:SetText(EllesmereUI.L("Grow"))
        gdFS:SetTextColor(1, 0.7, 0.3, 0.85)
    end

    -- Update the name label color based on anchor state
    local function RefreshAnchoredIdle()
        local ai = GetAnchorInfo(barKey)
        isAnchored = ai ~= nil or ns.IsMoverPosLocked(barKey)
        nameFS:SetText(EllesmereUI.L(label))
        if isAnchored then
            nameFS:SetTextColor(1, 0.7, 0.3, 0.85)
        else
            nameFS:SetTextColor(1, 1, 1, 0.75)
        end
    end

    local animFrame = CreateFrame("Frame", nil, labelFrame)

    local function ApplyHoverState(s)
        -- Name shifts up on hover to make room for action links below
        local labelShift = LABEL_Y_NORMAL + s * (LABEL_Y_SHIFTED - LABEL_Y_NORMAL)
        labelShift = labelShift + 2 - s
        -- Update the existing anchor offset instead of ClearAllPoints to avoid
        -- layout thrash that causes the label to jitter during animation.
        nameFS:SetPoint("CENTER", mover, "CENTER", 0, labelShift)
        -- Smoothly interpolate text width from constrained to unconstrained
        -- to avoid a hard snap when the animation starts.
        if baseW > 0 then
            local constrainedW = baseW
            local targetW = mover._cachedNameStrW or constrainedW
            local curTextW = constrainedW + (targetW - constrainedW) * s
            nameFS:SetWidth(curTextW)
        end

        -- Action links: show on hover. Visibility is built from the same
        -- ActiveLinks() list as the layout, so match buttons appear for
        -- allowMatchSource elements and the dividers always match the buttons.
        local links = ActiveLinks()
        local activeBtn = {}
        for _, it in ipairs(links) do activeBtn[it.btn] = true end
        local function _linkVis(btn)
            if activeBtn[btn] then
                btn:SetAlpha(s)
                if s > 0.01 then btn:Show() else btn:Hide() end
            else
                btn:Hide()
            end
        end
        _linkVis(wmBtn); _linkVis(hmBtn); _linkVis(atBtn); _linkVis(gdBtn)
        local nDivs = #links > 0 and (#links - 1) or 0
        local divsV = { div1, div2, div3 }
        for i = 1, 3 do
            if i <= nDivs then
                divsV[i]:SetAlpha(s)
                if s > 0.01 then divsV[i]:Show() else divsV[i]:Hide() end
            else
                divsV[i]:Hide()
            end
        end

        -- Cog: same show/hide as links
        if cogBtn then
            cogBtn:SetAlpha(s)
            if s > 0.01 then cogBtn:Show() else cogBtn:Hide() end
        end

        -- Animate-expand the mover only on hover (idle = raw element size)
        if baseW > 0 and baseH > 0 then
            local PAD = 5
            -- Use cached hover dimensions (computed once in ShowOverlayText)
            -- to avoid calling GetStringWidth every frame during animation.
            local hoverW = mover._cachedHoverW or baseW
            local hoverH = mover._cachedHoverH or baseH
            local curW = baseW + (hoverW - baseW) * s
            local curH = baseH + (hoverH - baseH) * s
            -- Expand symmetrically from the mover's stored center (set by Sync).
            -- This avoids reading GetLeft/GetTop from the bar frame, which can
            -- shift after a resize and cause the mover to teleport.
            local hasCenterXY = (moverCX ~= 0 or moverCY ~= 0)
            if hasCenterXY then
                local tx = moverCX - curW * 0.5
                local ty = moverCY + curH * 0.5
                mover:ClearAllPoints()
                mover:SetPoint("TOPLEFT", UIParent, "TOPLEFT", tx, ty)
            else
                -- Fallback: Sync hasn't run yet, read from bar frame
                local bk2 = mover._barKey
                local b2 = UM.GetBarFrame(bk2)
                if b2 then
                    local s2 = b2:GetEffectiveScale()
                    local uiS2 = UIParent:GetEffectiveScale()
                    local bL2 = b2:GetLeft()
                    local bT2 = b2:GetTop()
                    if bL2 and bT2 then
                        local tx = bL2 * s2 / uiS2 - (curW - baseW) * 0.5
                        local ty = bT2 * s2 / uiS2 - UIParent:GetHeight() + (curH - baseH) * 0.5
                        mover:ClearAllPoints()
                        mover:SetPoint("TOPLEFT", UIParent, "TOPLEFT", tx, ty)
                    end
                end
            end
            mover:SetSize(curW, curH)
        end
    end

    local function AnimateHoverTo(target)
        if target == hoverTarget and not animFrame:GetScript("OnUpdate")
           and math.abs(hoverState - target) < 0.01 then return end
        hoverTarget = target
        animFrame:SetScript("OnUpdate", function(self, dt)
            local dir = hoverTarget > hoverState and 1 or -1
            hoverState = hoverState + dir * (dt / ANIM_DUR)
            if (dir == 1 and hoverState >= hoverTarget) or (dir == -1 and hoverState <= hoverTarget) then
                hoverState = hoverTarget
                self:SetScript("OnUpdate", nil)
                -- Snap back to bar anchor when fully collapsed
                if hoverState == 0 and mover.ReanchorToBar then
                    mover:ReanchorToBar()
                end
                -- Show coordinates when fully expanded
                if hoverState == 1 and mover._coordFS then
                    if mover.UpdateCoordText then mover:UpdateCoordText() end
                end
            end
            ApplyHoverState(hoverState)
        end)
    end

    -- Show/hide overlay text helpers
    local function ShowOverlayText()
        mover._hoverConfirmed = true
        if UM.darkOverlaysEnabled then
            nameFS:SetAlpha(1); nameFS:Show()
        end
        RefreshAnchoredIdle()
        -- Cache hover dimensions once so ApplyHoverState avoids per-frame GetStringWidth
        if baseW > 0 and baseH > 0 then
            local PAD = 5
            local nameW = nameFS:GetStringWidth() or 0
            local nameH = nameFS:GetStringHeight() or 10
            local rowW = 0
            do
                local links = ActiveLinks()
                local gap = 8
                for i, it in ipairs(links) do
                    rowW = rowW + (it.fs:GetStringWidth() or it.fb)
                    if i < #links then rowW = rowW + gap + 1 + gap end
                end
            end
            local contentW = math.max(nameW, rowW)
            local contentH = nameH + 4 + 14
            mover._cachedHoverW = math.max(baseW, contentW + PAD * 2 + 6)
            mover._cachedHoverH = math.max(baseH, contentH + PAD * 2 + 2)
        end
        -- Cache unconstrained name width for smooth text width interpolation
        local nsw = nameFS:GetStringWidth() or baseW
        mover._cachedNameStrW = math.max(nsw + 4, baseW)
        -- Skip RefreshLinkStates if a link button is currently hovered (would reset its white color)
        local linkHovered = false
        if mover._linkBtns then
            for _, b in ipairs(mover._linkBtns) do
                if b:IsMouseOver() then linkHovered = true; break end
            end
        end
        if not linkHovered then RefreshLinkStates() end
        LayoutActionRow()
        AnimateHoverTo(1)
        pickFS:Hide()
    end

    local function HideOverlayText()
        mover._hoverConfirmed = false
        -- Hide coordinates when collapsing (unless coords-always-on)
        if mover._coordFS and not UM.coordsEnabled then mover._coordFS:Hide() end
        AnimateHoverTo(0)
    end

    local function ShowPickText(text)
        wmBtn:Hide(); hmBtn:Hide(); atBtn:Hide(); gdBtn:Hide()
        div1:Hide(); div2:Hide(); div3:Hide()
        hoverState = 0; hoverTarget = 0
        animFrame:SetScript("OnUpdate", nil)
        nameFS:ClearAllPoints()
        nameFS:SetPoint("CENTER", mover, "CENTER", 0, LABEL_Y_NORMAL)
        nameFS:SetAlpha(0)
        pickFS:SetText(EllesmereUI.L(text))
        pickFS:Show()
    end

    local function HidePickText()
        pickFS:Hide()
        if UM.darkOverlaysEnabled then
            nameFS:SetAlpha(1)
        end
    end

    mover._showOverlayText = ShowOverlayText
    mover._hideOverlayText = HideOverlayText
    mover._showPickText = ShowPickText
    mover._hidePickText = HidePickText

    -- Snap-collapse: instantly reset hover state without animation.
    -- Used by DoClose to guarantee no mover is stuck expanded on re-enter.
    mover._forceCollapse = function()
        hoverState = 0
        hoverTarget = 0
        mover._hoverConfirmed = false
        if mover._coordFS and not UM.coordsEnabled then mover._coordFS:Hide() end
        animFrame:SetScript("OnUpdate", nil)
        ApplyHoverState(0)
        if mover.ReanchorToBar then mover:ReanchorToBar() end
    end

    -- Refresh the anchored text (called after anchor changes)
    function mover:RefreshAnchoredText()
        RefreshAnchoredIdle()
        RefreshLinkStates()
        -- If not hovered, apply idle state to show/hide anchored text
        if not self:IsMouseOver() then
            ApplyHoverState(hoverState)
        end
    end

    -- Hover effects for action buttons (brighten to white on hover, keep mover highlighted)
    local function BtnEnter(btn, fs, matchType)
        EllesmereUI.HideWidgetTooltip()
        -- Check if this button is blocked by linkedDimensions
        local isBlocked = false
        if elem and elem.linkedDimensions then
            if matchType == "width" and MatchH.GetHeightMatchInfo(barKey) ~= nil and MatchH.GetWidthMatchInfo(barKey) == nil then
                isBlocked = true
            elseif matchType == "height" and MatchH.GetWidthMatchInfo(barKey) ~= nil and MatchH.GetHeightMatchInfo(barKey) == nil then
                isBlocked = true
            end
        end
        if isBlocked then
            EllesmereUI.ShowWidgetTooltip(btn, "This element doesn't support both Height and Width matching")
            return
        end
        fs:SetTextColor(1, 1, 1, 1)
        mover:SetFrameLevel(mover._raisedLevel + 100)
        mover._brd:SetColor(1, 1, 1, 0.9)
        -- Show tooltip for active matches
        local tipText
        if matchType == "width" then
            local target = MatchH.GetWidthMatchInfo(barKey)
            if target then
                tipText = UM.GetBarLabel(target) or target
            end
        elseif matchType == "height" then
            local target = MatchH.GetHeightMatchInfo(barKey)
            if target then
                tipText = UM.GetBarLabel(target) or target
            end
        elseif matchType == "anchor" then
            local info = GetAnchorInfo(barKey)
            if info then
                tipText = UM.GetBarLabel(info.target) or info.target
            end
        elseif matchType == "grow" then
            local gd = GetBarGrowDir(barKey)
            if gd then
                tipText = "Grow " .. gd:sub(1,1) .. gd:sub(2):lower()
            end
        end
        if tipText then
            EllesmereUI.ShowWidgetTooltip(btn, tipText)
        end
    end
    local function BtnLeave(btn, fs, matchType)
        EllesmereUI.HideWidgetTooltip()
        -- Restore correct color based on active/blocked state
        local isActive = false
        local isBlocked = false
        if matchType == "width" then
            isActive = MatchH.GetWidthMatchInfo(barKey) ~= nil
            isBlocked = elem and elem.linkedDimensions and not isActive and MatchH.GetHeightMatchInfo(barKey) ~= nil
        elseif matchType == "height" then
            isActive = MatchH.GetHeightMatchInfo(barKey) ~= nil
            isBlocked = elem and elem.linkedDimensions and not isActive and MatchH.GetWidthMatchInfo(barKey) ~= nil
        elseif matchType == "anchor" then
            isActive = GetAnchorInfo(barKey) ~= nil
        elseif matchType == "grow" then
            isActive = true
        end
        if isActive then
            fs:SetTextColor(1, 0.7, 0.3, 0.85)
        elseif isBlocked then
            fs:SetTextColor(ar, ag, ab, 0.35)
        else
            fs:SetTextColor(ar, ag, ab, 0.85)
        end
        -- Restore frame level/border only -- mover OnLeave owns the collapse
        C_Timer.After(0.05, function()
            if not mover:IsMouseOver() then
                local overChild = mover._cogBtn and mover._cogBtn:IsMouseOver()
                if not overChild and mover._linkBtns then
                    for _, b in ipairs(mover._linkBtns) do
                        if b:IsMouseOver() then overChild = true; break end
                    end
                end
                if not overChild then
                    mover:SetFrameLevel(mover._baseLevel)
                    if mover._cogBtn then mover._cogBtn:SetFrameLevel(mover._baseLevel + 10) end
                    mover._brd:SetColor(ar, ag, ab, 0.6)
                end
            end
        end)
    end
    wmBtn:SetScript("OnEnter", function(self) BtnEnter(self, wmFS, "width") end)
    wmBtn:SetScript("OnLeave", function(self) BtnLeave(self, wmFS, "width") end)
    hmBtn:SetScript("OnEnter", function(self) BtnEnter(self, hmFS, "height") end)
    hmBtn:SetScript("OnLeave", function(self) BtnLeave(self, hmFS, "height") end)
    atBtn:SetScript("OnEnter", function(self) BtnEnter(self, atFS, "anchor") end)
    atBtn:SetScript("OnLeave", function(self) BtnLeave(self, atFS, "anchor") end)

    -- Forward drag from link buttons to the mover using OnMouseDown/Up instead of
    -- WoW's drag system: RegisterForDrag fires OnDragStop as soon as the button
    -- moves (happens when the hover row collapses on drag start), breaking the drag
    -- immediately; OnMouseDown/Up bypass that. To avoid collapsing the action row on a plain click, defer drag start until the cursor moves 3px.
    local linkDragPending = false
    local linkDragStartX, linkDragStartY = 0, 0

    local function LinkMouseDown(btn, button)
        if button ~= "LeftButton" then return end
        local sc = UIParent:GetEffectiveScale()
        linkDragStartX, linkDragStartY = GetCursorPosition()
        linkDragStartX = linkDragStartX / sc
        linkDragStartY = linkDragStartY / sc
        linkDragPending = true
        -- Poll for movement threshold before committing to drag
        mover:SetScript("OnUpdate", function(s)
            if not linkDragPending then return end
            local sc2 = UIParent:GetEffectiveScale()
            local mx, my = GetCursorPosition()
            mx = mx / sc2; my = my / sc2
            if abs(mx - linkDragStartX) > 1 or abs(my - linkDragStartY) > 1 then
                linkDragPending = false
                -- Now fire the real drag start
                local script = mover:GetScript("OnDragStart")
                if script then script(mover) end
            end
        end)
    end
    local function LinkMouseUp(btn, button)
        if button ~= "LeftButton" then return end
        linkDragPending = false
        if mover._dragging then
            local script = mover:GetScript("OnDragStop")
            if script then script(mover) end
        else
            -- No drag committed -- clear the pending OnUpdate
            mover:SetScript("OnUpdate", nil)
        end
    end
    wmBtn:SetScript("OnMouseDown", LinkMouseDown)
    wmBtn:SetScript("OnMouseUp",   LinkMouseUp)
    hmBtn:SetScript("OnMouseDown", LinkMouseDown)
    hmBtn:SetScript("OnMouseUp",   LinkMouseUp)
    atBtn:SetScript("OnMouseDown", LinkMouseDown)
    atBtn:SetScript("OnMouseUp",   LinkMouseUp)
    -- Also catch mouse release on the mover itself during a link-initiated drag.
    -- When the user drags far from the link button, the release happens over the
    -- mover (or nowhere), so the link button's OnMouseUp never fires.
    mover:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" then
            _mouseHeld = false
            if linkDragPending or self._dragging then
                LinkMouseUp(self, button)
            end
        end
    end)

    -- Click handlers for Width Match / Height Match / Anchor To
    -- Toggle: if already matched, clear it; otherwise enter pick mode
    wmBtn:SetScript("OnClick", function()
        EllesmereUI.HideWidgetTooltip()
        -- Block if linkedDimensions and height match is already active
        if elem and elem.linkedDimensions and MatchH.GetHeightMatchInfo(barKey) ~= nil and MatchH.GetWidthMatchInfo(barKey) == nil then
            return
        end
        if MatchH.GetWidthMatchInfo(barKey) then
            MatchH.ClearWidthMatch(barKey)
            UM.hasChanges = true
            RefreshLinkStates()
            LayoutActionRow()
            return
        end
        -- Element-declared dynamic block on NEW matches (clearing above stays
        -- allowed): e.g. action bars in Blizzard Style, where EUI doesn't
        -- size the bars and a match would only write junk settings.
        if elem and elem.matchUnavailable then
            local why = elem.matchUnavailable(barKey)
            if why then
                EllesmereUI.ShowWidgetTooltip(wmBtn, why)
                return
            end
        end
        CancelPickMode()
        UM.pickMode = "widthMatch"
        UM.pickModeMover = mover
        ShowPickText("Click any element\nto match its width")
        FadeOverlayForSelectElement(true)
    end)

    hmBtn:SetScript("OnClick", function()
        EllesmereUI.HideWidgetTooltip()
        -- Block if linkedDimensions and width match is already active
        if elem and elem.linkedDimensions and MatchH.GetWidthMatchInfo(barKey) ~= nil and MatchH.GetHeightMatchInfo(barKey) == nil then
            return
        end
        if MatchH.GetHeightMatchInfo(barKey) then
            MatchH.ClearHeightMatch(barKey)
            UM.hasChanges = true
            RefreshLinkStates()
            LayoutActionRow()
            return
        end
        -- Element-declared dynamic block on NEW matches (see wmBtn above).
        if elem and elem.matchUnavailable then
            local why = elem.matchUnavailable(barKey)
            if why then
                EllesmereUI.ShowWidgetTooltip(hmBtn, why)
                return
            end
        end
        CancelPickMode()
        UM.pickMode = "heightMatch"
        UM.pickModeMover = mover
        ShowPickText("Click any element\nto match its height")
        FadeOverlayForSelectElement(true)
    end)

    atBtn:SetScript("OnClick", function()
        EllesmereUI.HideWidgetTooltip()
        if ns.IsMoverPosLocked(barKey) then return end
        if GetAnchorInfo(barKey) then
            ClearAnchorInfo(barKey)
            -- Capture current screen position so Save & Exit persists it.
            -- Without this, the old cdmBarPositions (from when anchored)
            -- would be used on /reload, snapping the bar to the wrong spot.
            local bar = UM.GetBarFrame(barKey)
            if bar then
                local pt, _, rpt, bx, by = bar:GetPoint(1)
                if pt then
                    pendingPositions[barKey] = {
                        point = pt, relPoint = rpt, x = bx, y = by,
                    }
                end
            end
            UM.hasChanges = true
            RefreshAnchoredIdle()
            RefreshLinkStates()
            LayoutActionRow()
            if movers[barKey] and movers[barKey].RefreshAnchoredText then
                movers[barKey]:RefreshAnchoredText()
            end
            return
        end
        CancelPickMode()
        UM.pickMode = "anchorTo"
        UM.pickModeMover = mover
        ShowPickText("Click any element\nto anchor to it")
        FadeOverlayForSelectElement(true)
    end)

    gdBtn:SetScript("OnClick", function()
        EllesmereUI.HideWidgetTooltip()
        -- Build and show the grow direction dropdown
        if not UM.growDropdownFrame then
            UM.growDropdownFrame = CreateFrame("Frame", nil, UM.unlockFrame)
            UM.growDropdownFrame:SetFrameStrata("FULLSCREEN_DIALOG")
            UM.growDropdownFrame:SetFrameLevel(260)
            UM.growDropdownFrame:SetClampedToScreen(true)
            UM.growDropdownFrame:EnableMouse(true)
        end
        if not UM.growDropdownCatcher then
            UM.growDropdownCatcher = CreateFrame("Button", nil, UM.unlockFrame)
            UM.growDropdownCatcher:SetFrameStrata("FULLSCREEN_DIALOG")
            UM.growDropdownCatcher:SetFrameLevel(259)
            UM.growDropdownCatcher:SetAllPoints(UIParent)
            UM.growDropdownCatcher:RegisterForClicks("AnyUp")
            UM.growDropdownCatcher:SetScript("OnClick", function()
                UM.growDropdownFrame:Hide()
                UM.growDropdownCatcher:Hide()
            end)
        end
        -- Rebuild dropdown content
        for _, child in ipairs({UM.growDropdownFrame:GetChildren()}) do child:Hide(); child:SetParent(nil) end
        for _, tex in ipairs({UM.growDropdownFrame:GetRegions()}) do if tex.Hide then tex:Hide() end end

        local DD_ITEM_H = 24
        local DD_WIDTH = 160
        UM.growDropdownFrame:SetSize(DD_WIDTH, 10)
        UM.growDropdownFrame:ClearAllPoints()
        local scale = UIParent:GetEffectiveScale()
        local curX, curY = GetCursorPosition()
        curX = curX / scale
        curY = curY / scale - UIParent:GetHeight()
        UM.growDropdownFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", curX, curY)

        local ddBg = UM.growDropdownFrame:CreateTexture(nil, "BACKGROUND")
        ddBg:SetAllPoints()
        ddBg:SetColorTexture(0.075, 0.113, 0.141, 0.95)
        EllesmereUI.MakeBorder(UM.growDropdownFrame, 1, 1, 1, 0.20)

        local ddY = -4
        local titleFS = UM.growDropdownFrame:CreateFontString(nil, "OVERLAY")
        EllesmereUI.PrimeFontShadow(titleFS, true)
        titleFS:SetFont(FONT_PATH, 10, "")
        titleFS:SetTextColor(1, 1, 1, 0.40)
        titleFS:SetJustifyH("LEFT")
        titleFS:SetPoint("TOPLEFT", UM.growDropdownFrame, "TOPLEFT", 10, ddY - 4)
        titleFS:SetText(EllesmereUI.L("Grow Direction"))
        ddY = ddY - 18
        local titleDiv = UM.growDropdownFrame:CreateTexture(nil, "ARTWORK")
        titleDiv:SetHeight(1)
        titleDiv:SetColorTexture(1, 1, 1, 0.10)
        titleDiv:SetPoint("TOPLEFT", UM.growDropdownFrame, "TOPLEFT", 1, ddY - 2)
        titleDiv:SetPoint("TOPRIGHT", UM.growDropdownFrame, "TOPRIGHT", -1, ddY - 2)
        ddY = ddY - 5

        -- Read orientation dynamically (not from closure) so the dropdown
        -- shows the correct options if orientation changed after mover creation.
        local isVert = false
        if barKey:sub(1, 4) == "CDM_" then
            local cdm3 = EllesmereUI.Lite.GetAddon("EllesmereUICooldownManager", true)
            local cb3 = cdm3 and cdm3.db and cdm3.db.profile and cdm3.db.profile.cdmBars
            if cb3 and cb3.bars then
                for _, b3 in ipairs(cb3.bars) do
                    if b3.key == barKey:sub(5) then isVert = b3.verticalOrientation == true; break end
                end
            end
        elseif barKey == "ERB_TotemBar" then
            if EllesmereUI.GetTotemGrowDir then
                local _, v3 = EllesmereUI.GetTotemGrowDir()
                isVert = v3
            end
        elseif barKey == "EABR_Reminders" then
            isVert = false   -- the reminder row is horizontal only
        elseif barKey:sub(1, 4) == "PAB_" then
            -- Player Aura Bars support vertical growth too -- read the bar's
            -- own current growDirection (same bridge the currentVal lookup below uses)
            -- to decide which pair of grow options this popup offers.
            local euf3 = EllesmereUI.Lite.GetAddon("EllesmereUIUnitFrames", true)
            local pabDir = (euf3 and euf3.GetGrowDirectionForBar and euf3:GetGrowDirectionForBar(barKey)) or "LEFT"
            isVert = (pabDir == "UP" or pabDir == "DOWN" or pabDir == "CENTER_VERTICAL")
        else
            local eab3 = EllesmereUI.Lite.GetAddon("EllesmereUIActionBars", true)
            local s3 = eab3 and eab3.db and eab3.db.profile and eab3.db.profile.bars and eab3.db.profile.bars[barKey]
            if s3 then isVert = (s3.orientation == "vertical") end
        end
        local growDirs = {}
        if barKey:sub(1, 4) == "PAB_" then
            growDirs[#growDirs + 1] = { label = "Grow Centered Horizontal", val = "CENTER_HORIZONTAL" }
            growDirs[#growDirs + 1] = { label = "Grow Centered Vertical", val = "CENTER_VERTICAL" }
        else
            growDirs[#growDirs + 1] = { label = "Grow Centered", val = "CENTER" }
        end
        if isVert then
            growDirs[#growDirs + 1] = { label = "Grow Up",   val = "UP"   }
            growDirs[#growDirs + 1] = { label = "Grow Down", val = "DOWN" }
        else
            growDirs[#growDirs + 1] = { label = "Grow Left",  val = "LEFT"  }
            growDirs[#growDirs + 1] = { label = "Grow Right", val = "RIGHT" }
        end
        -- Read actual grow direction directly (GetBarGrowDir filters defaults)
        local currentVal = "CENTER"
        if barKey:sub(1, 4) == "CDM_" then
            local cdm4 = EllesmereUI.Lite.GetAddon("EllesmereUICooldownManager", true)
            local cb4 = cdm4 and cdm4.db and cdm4.db.profile and cdm4.db.profile.cdmBars
            if cb4 and cb4.bars then
                for _, b4 in ipairs(cb4.bars) do
                    if b4.key == barKey:sub(5) then currentVal = b4.growDirection or "CENTER"; break end
                end
            end
        elseif barKey == "ERB_TotemBar" then
            -- Clamped read: a direction left over from the other orientation is
            -- never stored back, so the menu must resolve it the same way the
            -- layout does or it would highlight an option that is not offered.
            currentVal = EllesmereUI.GetTotemGrowDir and EllesmereUI.GetTotemGrowDir()
                or (isVert and "DOWN" or "RIGHT")
        elseif barKey == "EABR_Reminders" then
            if EllesmereUI.GetAuraBuffGrowDir then currentVal = EllesmereUI.GetAuraBuffGrowDir() end
        elseif barKey:sub(1, 4) == "PAB_" then
            local euf4 = EllesmereUI.Lite.GetAddon("EllesmereUIUnitFrames", true)
            currentVal = (euf4 and euf4.GetGrowDirectionForBar and euf4:GetGrowDirectionForBar(barKey)) or "LEFT"
        else
            local eab4 = EllesmereUI.Lite.GetAddon("EllesmereUIActionBars", true)
            local s4 = eab4 and eab4.db and eab4.db.profile and eab4.db.profile.bars
                       and eab4.db.profile.bars[barKey]
            if s4 then currentVal = (s4.growDirection or "up"):upper() end
        end

        for _, entry in ipairs(growDirs) do
            local isDisabled = false
            local isCurrent = (entry.val == currentVal)

            local item = CreateFrame("Button", nil, UM.growDropdownFrame)
            item:SetHeight(DD_ITEM_H)
            item:SetPoint("TOPLEFT", UM.growDropdownFrame, "TOPLEFT", 1, ddY)
            item:SetPoint("TOPRIGHT", UM.growDropdownFrame, "TOPRIGHT", -1, ddY)
            item:SetFrameLevel(UM.growDropdownFrame:GetFrameLevel() + 2)
            item:RegisterForClicks("AnyUp")
            local hl = item:CreateTexture(nil, "ARTWORK")
            hl:SetAllPoints()
            hl:SetColorTexture(1, 1, 1, 0)
            local lbl = item:CreateFontString(nil, "OVERLAY")
            EllesmereUI.PrimeFontShadow(lbl, true)
            lbl:SetFont(FONT_PATH, 11, "")
            lbl:SetJustifyH("LEFT")
            lbl:SetPoint("LEFT", item, "LEFT", 10, 0)
            lbl:SetText(EllesmereUI.L(entry.label))
            if isDisabled then
                lbl:SetTextColor(0.4, 0.4, 0.4, 0.5)
                local tipText = "Deselect a grow direction to return to centered"
                item:SetScript("OnEnter", function()
                    EllesmereUI.ShowWidgetTooltip(item, tipText)
                end)
                item:SetScript("OnLeave", function()
                    EllesmereUI.HideWidgetTooltip()
                end)
            else
                local baseR, baseG, baseB, baseA = isCurrent and 1 or 0.75, isCurrent and 0.7 or 0.75, isCurrent and 0.3 or 0.75, isCurrent and 0.9 or 0.9
                lbl:SetTextColor(baseR, baseG, baseB, baseA)
                item:SetScript("OnEnter", function()
                    hl:SetColorTexture(1, 1, 1, 0.08)
                    lbl:SetTextColor(1, 1, 1, 1)
                end)
                item:SetScript("OnLeave", function()
                    hl:SetColorTexture(1, 1, 1, 0)
                    lbl:SetTextColor(baseR, baseG, baseB, baseA)
                end)
                local sideVal = entry.val
                item:SetScript("OnClick", function()
                    UM.growDropdownFrame:Hide()
                    UM.growDropdownCatcher:Hide()

                    -- If already on this direction, just close the popup
                    if sideVal == currentVal then return end

                    EllesmereUI._unlockSetGrowDirection(barKey, sideVal)
                    RefreshLinkStates()
                end)
            end
            ddY = ddY - DD_ITEM_H
        end

        UM.growDropdownFrame:SetHeight(-ddY + 4)
        UM.growDropdownFrame:Show()
        UM.growDropdownCatcher:Show()
    end)
    gdBtn:SetScript("OnEnter", function(self) BtnEnter(self, gdFS, "grow") end)
    gdBtn:SetScript("OnLeave", function(self) BtnLeave(self, gdFS, "grow") end)

    -- Helper: update coordinate readout from mover's current position
    function mover:UpdateCoordText()
        local fs = self._coordFS
        if not fs then return end
        local bk = self._barKey
        local PPi = EllesmereUI and EllesmereUI.PP
        local toPx = (PPi and PPi.ToPixels) or round
        -- STORED value first for unanchored CENTER/CENTER elements when not
        -- mid-drag: an odd-pixel-dimension frame's physical center legitimately
        -- sits on a half pixel (whole-pixel edges force it), so a live-derived
        -- readout can never echo the user's own typed value back (-368 reads as
        -- -367/-369 depending on rounding). The stored value is what the appliers
        -- round-trip, so it's the truth to display. Live geometry is only authoritative while dragging (store not yet updated).
        if not self._dragging then
            local ai = GetAnchorInfo(bk)
            if not (ai and ai.target) then
                local pos = pendingPositions[bk]
                if type(pos) ~= "table" or pos._anchored or not pos.point then
                    local elem = registeredElements[bk]
                    pos = elem and elem.loadPosition and elem.loadPosition(bk) or nil
                    if not pos then pos = LoadBarPosition(bk) end
                end
                if type(pos) == "table" and pos.point == "CENTER"
                   and (pos.relPoint or "CENTER") == "CENTER"
                   and pos.x and pos.y then
                    -- Parity-aware like the live branch below (odd dims store a half-pixel center).
                    local sb = UM.GetBarFrame(bk)
                    local c2pS = PPi and PPi.CenterToPixels
                    local px, py
                    if c2pS and sb then
                        px = c2pS(pos.x, sb:GetWidth(), sb:GetEffectiveScale())
                        py = c2pS(pos.y, sb:GetHeight(), sb:GetEffectiveScale())
                    else
                        px, py = toPx(pos.x), toPx(pos.y)
                    end
                    fs:SetText(format("%.0f, %.0f", px, py))
                    fs:Show()
                    return
                end
            end
        end
        -- Derive from the bar's LIVE geometry using the exact same formula and
        -- physical-pixel units as the cog X/Y boxes, so the overlay always agrees
        -- with the cog and updates immediately (no waiting for a commit).
        -- Parity-aware (CenterToPixels): odd-pixel dims center on a half pixel,
        -- which plain ToPixels reads back one high on this live path.
        local b = UM.GetBarFrame(bk)
        if b then
            local bL, bR = b:GetLeft(), b:GetRight()
            local bT, bB = b:GetTop(), b:GetBottom()
            if bL and bR and bT and bB then
                local ratio = b:GetEffectiveScale() / UIParent:GetEffectiveScale()
                local sw = UIParent:GetWidth()
                local sh = UIParent:GetHeight()
                local liveCX = ((bL + bR) * 0.5 * ratio) - sw * 0.5
                local liveCY = ((bT + bB) * 0.5 * ratio) - sh * 0.5
                local c2p = PPi and PPi.CenterToPixels
                fs:SetText(format("%.0f, %.0f",
                    c2p and c2p(liveCX, b:GetWidth(), b:GetEffectiveScale()) or toPx(liveCX),
                    c2p and c2p(liveCY, b:GetHeight(), b:GetEffectiveScale()) or toPx(liveCY)))
                fs:Show()
                return
            end
        end
        -- Fallback (frameless elements): saved CENTER position, same pixel units.
        local elem = registeredElements[bk]
        local pos = elem and elem.loadPosition and elem.loadPosition(bk)
        if not pos then
            pos = LoadBarPosition(bk)
        end
        if pos and pos.x and pos.y then
            fs:SetText(format("%.0f, %.0f", toPx(pos.x), toPx(pos.y)))
            fs:Show()
            return
        end
        -- Last resort: derive from mover bounds.
        local l, r, t, b2 = self:GetLeft(), self:GetRight(), self:GetTop(), self:GetBottom()
        if not l or not t then fs:Hide(); return end
        local screenW = UIParent:GetWidth()
        local screenH = UIParent:GetHeight()
        fs:SetText(format("%.0f, %.0f",
            toPx(((l + r) * 0.5) - screenW * 0.5),
            toPx(((t + b2) * 0.5) - screenH * 0.5)))
        fs:Show()
    end

    mover._barKey = barKey
    mover:SetAlpha(UM.darkOverlaysEnabled and 1 or MOVER_ALPHA)

    -- Initialize anchored text and link states, then apply idle state
    RefreshAnchoredIdle()
    RefreshLinkStates()
    ApplyHoverState(0)

    -- Sync size/position to the real bar (or registered element)
    function mover:Sync()
        -- Temporarily hidden for this unlock session (Shift+Right Click). Stay
        -- hidden until unlock mode is re-entered, which clears the flag. Every
        -- re-sync path (retry ticker, combat resume, open fade-in loops) must
        -- honor this and keep the overlay hidden.
        if self._tempHidden then self:Hide(); return end
        local bk = self._barKey
        local b = UM.GetBarFrame(bk)
        local elem = registeredElements[bk]

        -- Re-read the element's moverBg tint: movers persist for the session
        -- while elements re-register with STATE-DEPENDENT tints (CDM's
        -- Additional Bar Offset marker), so a stale CreateMover-time color
        -- would stick until /reload. Change-guarded repaint.
        do
            local bgTint = elem and elem.moverBg
            local nr = bgTint and bgTint.r or 0.075
            local ng = bgTint and bgTint.g or 0.113
            local nb = bgTint and bgTint.b or 0.141
            if self._bgR ~= nr or self._bgG ~= ng or self._bgB ~= nb then
                self._bgR, self._bgG, self._bgB = nr, ng, nb
                if self._bg and UM.darkOverlaysEnabled then
                    self._bg:SetColorTexture(nr, ng, nb, 0.95)
                end
            end
        end

        -- Stale/intentionally-hidden registrations (e.g. a deleted CDM tracking bar
        -- whose TBB_<idx> element is never unregistered, or a grouped non-anchor
        -- bar) must NOT be shown. Mirrors the CreateMover guard so blanket
        -- `for _, m in pairs(movers) do m:Sync() end` loops can't re-show a mover
        -- CreateMover intentionally hid. Action bars resolve elem == nil (no-op); isHidden is read live, so an un-hidden element still syncs.
        if elem and ((elem.isHidden and elem.isHidden())
                  or (elem.isAnchored and elem.isAnchored() and not elem.keepMoverWhenAnchored)) then
            self:Hide()
            return
        end

        -- For registered elements without a live frame, use getSize + loadPosition
        if not b and elem then
            local w, h = 100, 30
            local centerYOff = 0
            if elem.getSize then
                local gw, gh, gyOff = elem.getSize(bk)
                w, h = gw, gh
                centerYOff = gyOff or 0
            end
            if w < 10 then w = 100 end
            if h < 10 then h = 30 end
            baseW, baseH = w, h
            self:SetSize(w, h)
            if self._label then self._label:SetWidth(w * 0.95) end
            local pos = elem.loadPosition and elem.loadPosition(bk)
            if pos then
                self:ClearAllPoints()
                self:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x, (pos.y or 0) + centerYOff)
            else
                self:ClearAllPoints()
                self:SetPoint("CENTER", UIParent, "CENTER", 0, centerYOff)
            end
            self:Show()
            ApplyHoverState(hoverState)
            return
        end

        if not b then self:Hide(); return end
        -- Show mover even for hidden bars (mouseover/alwaysHidden) so user can reposition
        -- Only skip if the bar frame truly doesn't exist.
        -- A bar still on a follow anchor from before the session (a Blizzard
        -- Style cast bar under its frame's aura stack) reports a secret rect:
        -- re-apply its anchor now -- the follow provider is inert in unlock
        -- mode, so that places it absolutely -- and sync from the plain rect.
        -- If the rect has not resolved yet, sync again next frame.
        if issecretvalue and issecretvalue(b:GetLeft()) then
            if EllesmereUI.ReapplyOwnAnchor then EllesmereUI.ReapplyOwnAnchor(bk) end
            if issecretvalue(b:GetLeft()) then
                self:Hide()
                local n = self._secretResync or 0
                if n < 2 then
                    self._secretResync = n + 1
                    C_Timer.After(0, function() self:Sync() end)
                end
                return
            end
        end
        self._secretResync = nil
        local s = b:GetEffectiveScale()
        local uiS = UIParent:GetEffectiveScale()
        local w, h
        local elemScale = s / uiS
        -- Visual insets (optional, e.g. a Blizzard Style unit frame whose stock
        -- box carries transparent padding round its art): the mover outlines
        -- the rect inside them. UIParent units.
        local il, ir, it, ib = 0, 0, 0, 0
        if elem and elem.getInsets then
            local l, r, t, bt = elem.getInsets(bk)
            if l then il, ir, it, ib = l * elemScale, (r or 0) * elemScale, (t or 0) * elemScale, (bt or 0) * elemScale end
        end
        -- Read size directly from the bar frame. Since the mover is anchored
        -- to the bar, we need the size in the mover's coordinate space.
        -- elemScale converts from bar space to UIParent (mover parent) space.
        w = (b:GetWidth() or 50) * elemScale - il - ir
        h = (b:GetHeight() or 50) * elemScale - it - ib
        -- For action bars, compute visual size from button grid (accounts for
        -- shape overrides, padding, and per-button scale)
        -- Only use this as a fallback when the frame has no size yet (first load).
        if w < 10 or h < 10 then
            local abW, abH = GetActionBarVisualSize(bk)
            if abW and abH then
                w, h = abW, abH
            end
        end
        local isTinyAnchor = (w < 10)
        local centerYOff = 0
        if isTinyAnchor then
            -- Frame exists but has no size yet -- use getSize fallback
            if elem and elem.getSize then
                local gw, gh, gyOff = elem.getSize(bk)
                w, h = gw, gh
                centerYOff = gyOff or 0
            end
        end
        -- Extend the overlay downward to wrap an element's below-frame extra
        -- (e.g. the boss castbar). Inflating h here flows into SetSize and the
        -- center math below, keeping the top pinned and growing the box down.
        if elem and elem.getBottomExtra then
            h = h + (elem.getBottomExtra(bk) or 0) * elemScale
        end
        baseW, baseH = w, h
        self:SetSize(w, h)
        if self._label then self._label:SetWidth(w * 0.95) end

        -- Position: convert bar's screen position to UIParent-relative
        -- Center the mover on the bar's visual center for pixel-perfect alignment.
        local bL = b:GetLeft()
        local bT = b:GetTop()
        if bL and bT then
            local PP = EllesmereUI and EllesmereUI.PP
            if isTinyAnchor and elem then
                -- Dynamic bar (1x1 when empty): anchor is CENTER-positioned.
                -- Compute TOPLEFT from GetCenter() to avoid layout-flush timing
                -- issues where GetLeft()/GetTop() still reflect the old 1x1 size.
                local cx, cy
                local bCX, bCY = b:GetCenter()
                if bCX and bCY then
                    cx = bCX * s / uiS + (il - ir) * 0.5 - w * 0.5
                    cy = bCY * s / uiS + (ib - it) * 0.5 - UIParent:GetHeight() + h * 0.5 + centerYOff
                elseif bL and bT then
                    cx = bL * s / uiS
                    cy = bT * s / uiS - UIParent:GetHeight()
                else
                    -- No screen position yet -- fall back to saved pos
                    local pos = elem.loadPosition and elem.loadPosition(bk)
                    if pos and pos.point == "CENTER" then
                        local uiW = UIParent:GetWidth()
                        local uiH = UIParent:GetHeight()
                        cx = uiW * 0.5 + (pos.x or 0) - w * 0.5
                        cy = -(uiH * 0.5) + (pos.y or 0) + h * 0.5
                    else
                        cx = 0; cy = -UIParent:GetHeight() * 0.5
                    end
                end
                if PP then cx = PP.Scale(cx); cy = PP.Scale(cy) end
                self:ClearAllPoints()
                self:SetPoint("TOPLEFT", UIParent, "TOPLEFT", cx, cy)
                moverCX, moverCY = cx + w * 0.5, cy - h * 0.5
            else
                -- Anchor mover directly to the bar frame so both share the
                -- exact same screen position with zero coordinate math.
                EllesmereUI._unlockAttachMover(self, b, bk, il, it)
                -- Compute moverCX/moverCY for snap/drag logic
                local cx = bL * elemScale + il
                local cy = bT * elemScale - UIParent:GetHeight() - it
                moverCX, moverCY = cx + w * 0.5, cy - h * 0.5
            end
        else
            -- Bar has no position yet (not shown), place at center
            self:ClearAllPoints()
            self:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
            moverCX, moverCY = 0, -UIParent:GetHeight() * 0.5
        end
        self:Show()
        -- Re-apply hover state so mover size reflects current animation state
        ApplyHoverState(hoverState)
    end

    -- Lightweight size-only sync: updates baseW/baseH and re-applies hover state
    -- without repositioning the mover. Used after width/height match changes.
    function mover:SyncSize()
        local bk = self._barKey
        local elem = registeredElements[bk]
        if elem and elem.getSize then
            local gw, gh = elem.getSize(bk)
            -- Use the raw value from getSize without rounding: the layout function
            -- (LayoutCDMBar, LayoutBar, etc.) already snapped dimensions to the
            -- physical pixel grid. Re-rounding to the nearest integer shifts values
            -- off the pixel grid when PP.mult != 1.0 (e.g. 214.4 -> 214 instead of staying 214.4, exactly 402 physical pixels at mult=0.533).
            if gw and gw > 0 then baseW = gw end
            if gh and gh > 0 then baseH = gh end
        else
            local b = UM.GetBarFrame(bk)
            if b then
                local s = b:GetEffectiveScale()
                local uiS = UIParent:GetEffectiveScale()
                baseW = (b:GetWidth() or baseW) * s / uiS
                baseH = (b:GetHeight() or baseH) * s / uiS
            end
        end
        -- moverCX/moverCY are already updated by RecenterBarAnchor (called before
        -- SyncSize). Do NOT recompute from GetLeft/GetTop here -- the mover may
        -- still be anchored to the bar's old TOPLEFT position at this point, which
        -- would produce a wrong center and cause a one-frame visual jump.
        ApplyHoverState(hoverState)
        -- Re-anchor to bar for pixel-perfect alignment after size change
        self:ReanchorToBar()
    end

    -- Drag handlers: manual cursor-based positioning for live snap + live bar movement
    mover:SetScript("OnDragStart", function(self)
        if InCombatLockdown() then return end
        -- Position-locked: the module's anchor option owns this bar's position
        if ns.IsMoverPosLocked(self._barKey) then SelectMover(self); return end
        -- Anchored bars can be dragged -- the offset from parent is updated on drop
        SelectMover(self)
        self:SetAlpha(UM.darkOverlaysEnabled and 1 or MOVER_DRAG)
        self._dragging = true
        self._hoverPending = false  -- cancel pending expand animation
        self._shiftAxis = nil  -- nil = not locked, "X" or "Y" once determined
        -- Cache centerYOff for tiny-anchor elements (used in OnUpdate and OnDragStop)
        local elem = registeredElements[self._barKey]
        if elem and elem.getSize then
            local _, _, gyOff = elem.getSize(self._barKey)
            self._dragCenterYOff = gyOff or 0
        else
            self._dragCenterYOff = 0
        end
        -- Visual insets (see Sync): the bar's box sits outside the mover by
        -- these, UIParent units. The bar is placed from the mover's rect plus
        -- them, and the mover re-attaches inside them.
        self._dragIL, self._dragIR, self._dragIT, self._dragIB = 0, 0, 0, 0
        if elem and elem.getInsets then
            local bIn = UM.GetBarFrame(self._barKey)
            local l, r, t, bt = elem.getInsets(self._barKey)
            if l and bIn then
                local es = bIn:GetEffectiveScale() / UIParent:GetEffectiveScale()
                self._dragIL, self._dragIR = l * es, (r or 0) * es
                self._dragIT, self._dragIB = (t or 0) * es, (bt or 0) * es
            end
        end
        -- Snap links away instantly during drag (no animation -- it fights with drag positioning)
        hoverState = 0
        hoverTarget = 0
        animFrame:SetScript("OnUpdate", nil)
        ApplyHoverState(0)

        -- Record offset from cursor to mover center at drag start
        -- Use stored moverCX/moverCY (base-size center) so expanding/collapsing
        -- hover state does not corrupt the offset when dragging from a link button
        local scale = UIParent:GetEffectiveScale()
        local curX, curY = GetCursorPosition()
        curX = curX / scale
        curY = curY / scale
        local cx = (moverCX ~= 0 or moverCY ~= 0) and moverCX or (self:GetLeft() + self:GetRight()) / 2
        local cy = (moverCX ~= 0 or moverCY ~= 0) and moverCY or (self:GetTop() + self:GetBottom()) / 2 - UIParent:GetHeight()
        cy = cy + UIParent:GetHeight()  -- convert back to screen-space Y for drag math
        self._dragOffX = cx - curX
        self._dragOffY = cy - curY
        self._dragStartCX = cx
        self._dragStartCY = cy

        -- Snap mover to cursor immediately so there's no one-frame lag
        local halfW0 = self:GetWidth() / 2
        local halfH0 = self:GetHeight() / 2
        self._dragHalfW = halfW0
        self._dragHalfH = halfH0
        local snap0X, snap0Y = SnapPosition(self._barKey, cx, cy, halfW0, halfH0)
        local bar0 = UM.GetBarFrame(self._barKey)
        if bar0 and not InCombatLockdown() then
            local uiS0 = UIParent:GetEffectiveScale()
            local bS0 = bar0:GetEffectiveScale()
            local ratio0 = uiS0 / bS0
            local barHW0 = (bar0:GetWidth() or 0) * 0.5
            local barHH0 = (bar0:GetHeight() or 0) * 0.5
            local barX0 = (snap0X + (self._dragIR - self._dragIL) * 0.5) * ratio0 - barHW0
            local barY0 = (snap0Y + (self._dragIT - self._dragIB) * 0.5 - UIParent:GetHeight() - (self._dragCenterYOff or 0)) * ratio0 + barHH0
            local PPd = EllesmereUI and EllesmereUI.PP
            if PPd and PPd.SnapForES then
                local lockX, lockY = EllesmereUI._snapAxisLocked()
                if not lockX then barX0 = PPd.SnapForES(barX0, bS0) end
                if not lockY then barY0 = PPd.SnapForES(barY0, bS0) end
            end
            pcall(function()
                bar0:ClearAllPoints()
                bar0:SetPoint("TOPLEFT", UIParent, "TOPLEFT", barX0, barY0)
            end)
            -- Element follow-up to the one-point placement above (an element
            -- whose rect needs a second anchor -- main chat's size corner --
            -- restores it here), before the collapsed rect ever renders.
            if elem and elem.onLiveMove then
                pcall(elem.onLiveMove, self._barKey)
            end
            self:ClearAllPoints()
            if elem and elem.detachedMover then
                -- The bar refuses dependents (see AttachMoverToBar): same spot, absolute.
                self:SetPoint("TOPLEFT", UIParent, "TOPLEFT", snap0X - halfW0, snap0Y + halfH0 - UIParent:GetHeight())
            else
                self:SetPoint("TOPLEFT", bar0, "TOPLEFT", self._dragIL, -self._dragIT)
            end
        else
            local f0X = snap0X - halfW0
            local f0Y = snap0Y + halfH0 - UIParent:GetHeight()
            self:ClearAllPoints()
            self:SetPoint("TOPLEFT", UIParent, "TOPLEFT", f0X, f0Y)
        end

        -- OnUpdate: move mover + real bar to cursor position with snap
        self:SetScript("OnUpdate", function(s)
            local sc = UIParent:GetEffectiveScale()
            local mx, my = GetCursorPosition()
            mx = mx / sc
            my = my / sc

            -- Raw center = cursor + offset
            local rawCX = mx + s._dragOffX
            local rawCY = my + s._dragOffY

            -- Shift-axis-lock: constrain to one axis based on initial drag direction
            if IsShiftKeyDown() then
                if not s._shiftAxis then
                    local adx = abs(rawCX - s._dragStartCX)
                    local ady = abs(rawCY - s._dragStartCY)
                    -- Determine axis once movement exceeds 3px threshold
                    if adx > 3 or ady > 3 then
                        s._shiftAxis = (adx >= ady) and "X" or "Y"
                    end
                end
                if s._shiftAxis == "X" then
                    rawCY = s._dragStartCY
                elseif s._shiftAxis == "Y" then
                    rawCX = s._dragStartCX
                end
            else
                s._shiftAxis = nil  -- release shift = unlock axis
            end

            local halfW = s._dragHalfW
            local halfH = s._dragHalfH

            -- Apply snap
            local snapCX, snapCY = SnapPosition(s._barKey, rawCX, rawCY, halfW, halfH)

            -- Clamp to screen edges
            local screenW = UIParent:GetWidth()
            local screenH = UIParent:GetHeight()
            snapCX = max(halfW, min(screenW - halfW, snapCX))
            snapCY = max(halfH, min(screenH - halfH, snapCY))

            -- Move the real bar live first, then anchor the mover to it so
            -- the overlay stays pixel-perfect regardless of scale differences.
            local bar = UM.GetBarFrame(s._barKey)
            if bar and not InCombatLockdown() then
                local uiS = UIParent:GetEffectiveScale()
                local bS = bar:GetEffectiveScale()
                local ratio = uiS / bS
                -- bar:GetWidth/Height are in the bar's local (unscaled) space.
                -- Convert snapCX/snapCY (UIParent screen coords) into the bar's
                -- local space first, then subtract the unscaled half-size to get TOPLEFT.
                local barHW = (bar:GetWidth() or 0) * 0.5
                local barHH = (bar:GetHeight() or 0) * 0.5
                local barX = (snapCX + (s._dragIR - s._dragIL) * 0.5) * ratio - barHW
                local barY = (snapCY + (s._dragIT - s._dragIB) * 0.5 - UIParent:GetHeight() - (s._dragCenterYOff or 0)) * ratio + barHH
                local PPd = EllesmereUI and EllesmereUI.PP
                if PPd and PPd.SnapForES then
                    -- When an edge snap is active, skip SnapForES on that axis.
                    -- The unsnapped barX/barY already matches the target's edge
                    -- exactly. Re-snapping would shift it to a different pixel.
                    local lockX, lockY = EllesmereUI._snapAxisLocked()
                    if not lockX then barX = PPd.SnapForES(barX, bS) end
                    if not lockY then barY = PPd.SnapForES(barY, bS) end
                end
                pcall(function()
                    bar:ClearAllPoints()
                    bar:SetPoint("TOPLEFT", UIParent, "TOPLEFT", barX, barY)
                end)
                -- Anchor mover directly to bar TOPLEFT for pixel-perfect overlay
                s:ClearAllPoints()
                local dElem = registeredElements[s._barKey]
                if dElem and dElem.detachedMover then
                    -- The bar refuses dependents (see AttachMoverToBar): same spot, absolute.
                    s:SetPoint("TOPLEFT", UIParent, "TOPLEFT", snapCX - halfW, snapCY + halfH - UIParent:GetHeight())
                else
                    s:SetPoint("TOPLEFT", bar, "TOPLEFT", s._dragIL, -s._dragIT)
                end
            else
                -- No live bar -- position mover in UIParent space
                local finalX = snapCX - halfW
                local finalY = snapCY + halfH - UIParent:GetHeight()
                s:ClearAllPoints()
                s:SetPoint("TOPLEFT", UIParent, "TOPLEFT", finalX, finalY)
            end

            -- Element follow-up to the placement above, BEFORE the anchor chain
            -- reads this frame's rect: an element whose rect needs a second
            -- anchor (main chat's size corner) restores it here, so dependents
            -- anchor against the true rect on the same tick.
            local elem = registeredElements[s._barKey]
            if elem and elem.onLiveMove then
                pcall(elem.onLiveMove, s._barKey)
            end

            -- Show live coordinates during drag (only on elements >= 20px tall).
            -- Physical-pixel counts, matching the cog X/Y boxes and the overlay.
            if s._coordFS and s:GetHeight() >= 12 then
                local PPc = EllesmereUI and EllesmereUI.PP
                local toPx = (PPc and PPc.ToPixels) or round
                s._coordFS:SetText(format("%.0f, %.0f", toPx(snapCX - screenW * 0.5), toPx(snapCY - screenH * 0.5)))
                s._coordFS:Show()
            end

            -- Anchor chain: propagate recursively down the chain
            local anchorDB = GetAnchorDB()
            if anchorDB then
                UM.PropagateAnchorChain(s._barKey)
            end

            ShowAlignmentGuides(s._barKey)

            -- Safety net: if mouse button was released outside any button frame
            -- (e.g. during a link-initiated drag), stop the drag now.
            if not IsMouseButtonDown("LeftButton") then
                local stopScript = s:GetScript("OnDragStop")
                if stopScript then stopScript(s) end
            end
        end)
    end)

    mover:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        self._dragging = false
        _mouseHeld = false
        self:SetAlpha(UM.darkOverlaysEnabled and 1 or MOVER_HOVER)
        -- Convert back to CENTER anchor so hover-expand stays symmetric
        local mL, mR = self:GetLeft(), self:GetRight()
        local mT, mB = self:GetTop(), self:GetBottom()
        if mL and mR and mT and mB then
            local cx = (mL + mR) * 0.5
            local cy = (mT + mB) * 0.5 - UIParent:GetHeight()
            self:ClearAllPoints()
            self:SetPoint("CENTER", UIParent, "TOPLEFT", cx, cy)
            moverCX, moverCY = cx, cy
        end
        -- Update coords to final position (stays visible if selected or coords-always-on)
        if self._selected and self.UpdateCoordText then
            self:UpdateCoordText()
        elseif UM.coordsEnabled and self.UpdateCoordText then
            self:UpdateCoordText()
        else
            self._coordFS:Hide()
        end
        HideAllGuidesAndHighlight()
        -- Re-show links after drag if still hovered
        if self:IsMouseOver() then
            if self._showOverlayText then self._showOverlayText() end
        end
        -- Re-anchor toolbar in case mover moved near/away from screen top
        if self._anchorToolbar then self._anchorToolbar() end

        -- Check if the mover actually moved (avoids false dirty flag from
        -- click-and-hold without movement)
        local cxL, cxR = self:GetLeft(), self:GetRight()
        local cyT, cyB = self:GetTop(), self:GetBottom()
        if not cxL or not cxR or not cyT or not cyB then return end
        local cx = (cxL + cxR) / 2
        local cy = (cyT + cyB) / 2
        local startCX = self._dragStartCX or cx
        local startCY = self._dragStartCY or cy
        local moved = (abs(cx - startCX) > 0.5) or (abs(cy - startCY) > 0.5)
        if not moved then return end

        -- Store position in pending table (NOT saved until user clicks Save & Exit)

        local bar = UM.GetBarFrame(self._barKey)
        if not InCombatLockdown() then
            local uiS = UIParent:GetEffectiveScale()

            -- If this bar is anchored, the offset was already updated live during drag.
            -- No need to recompute here -- using mover screen coords would introduce
            -- sub-pixel drift vs the cursor-based offset set in OnUpdate.

            local dragCYOff = self._dragCenterYOff or 0
            if bar then
                -- Read the bar's actual TOPLEFT from its current SetPoint rather
                -- than recomputing from the mover center. The OnUpdate already
                -- positioned the bar with exact edge alignment (no SnapForES drift).
                local _, _, _, barX, barY = bar:GetPoint(1)
                if not barX or not barY then
                    local bS = bar:GetEffectiveScale()
                    local ratio = uiS / bS
                    local barHW = (bar:GetWidth() or 0) * 0.5
                    local barHH = (bar:GetHeight() or 0) * 0.5
                    barX = cx * ratio - barHW
                    barY = (cy - UIParent:GetHeight() - dragCYOff) * ratio + barHH
                    local PPd = EllesmereUI and EllesmereUI.PP
                    if PPd and PPd.SnapForES then
                        barX = PPd.SnapForES(barX, bS)
                        barY = PPd.SnapForES(barY, bS)
                    end
                end
                pendingPositions[self._barKey] = {
                    point = "TOPLEFT", relPoint = "TOPLEFT",
                    x = barX, y = barY,
                }
            else
                -- No live frame (e.g. unit frame not spawned) -- store in UIParent coords
                local halfW = (baseW > 0 and baseW or self:GetWidth()) / 2
                local halfH = (baseH > 0 and baseH or self:GetHeight()) / 2
                pendingPositions[self._barKey] = {
                    point = "TOPLEFT", relPoint = "TOPLEFT",
                    x = cx - halfW, y = cy + halfH - UIParent:GetHeight() - dragCYOff,
                }
            end
            UM.hasChanges = true
        end

        -- If anchored to a parent, update the stored offset so the parent's future
        -- moves don't snap this child back. Read actual child edges directly
        -- instead of computing from center+half to avoid float dust from (top+bottom)/2 - height/2 != bottom.
        local ai = GetAnchorInfo(self._barKey)
        if ai then
            local targetBar = UM.GetBarFrame(ai.target)
            if targetBar then
                local tS = targetBar:GetEffectiveScale()
                local uiScale = UIParent:GetEffectiveScale()
                local tL = targetBar:GetLeft()
                local tR = targetBar:GetRight()
                local tT = targetBar:GetTop()
                local tB = targetBar:GetBottom()
                if tL and tR and tT and tB then
                    tL = tL * tS / uiScale
                    tR = tR * tS / uiScale
                    tT = tT * tS / uiScale
                    tB = tB * tS / uiScale
                    local tCX = (tL + tR) / 2
                    local tCY = (tT + tB) / 2
                    -- Growth-edge extent and followed edges: the same edges the
                    -- apply measures from. A follow frame's live bottom is plain
                    -- here (unlock mode never runs under aura restriction).
                    if EllesmereUI._GetAnchorTargetExtent then
                        local ext = EllesmereUI._GetAnchorTargetExtent(ai.target, ai.side)
                        if ext then
                            if ai.side == "TOP" then tT = ext
                            elseif ai.side == "BOTTOM" then tB = ext
                            elseif ai.side == "LEFT" then tL = ext
                            elseif ai.side == "RIGHT" then tR = ext
                            end
                        end
                    end
                    if ai.side == "BOTTOM" and EllesmereUI._GetAnchorFollowFrame then
                        local fol = EllesmereUI._GetAnchorFollowFrame(self._barKey, ai.target, ai.side)
                        local fB = fol and fol:GetBottom()
                        if not (issecretvalue and issecretvalue(fB)) and fB then
                            tB = fB * fol:GetEffectiveScale() / uiScale
                        end
                    end
                    -- Read child edges from the actual bar frame for accuracy
                    local childBar = UM.GetBarFrame(self._barKey)
                    local cL, cR, cT, cB
                    local cRatio = 1   -- mover coords are already UIParent units
                    if childBar and childBar:GetLeft() then
                        local cS = childBar:GetEffectiveScale()
                        cRatio = cS / uiScale
                        cL = childBar:GetLeft() * cS / uiScale
                        cR = childBar:GetRight() * cS / uiScale
                        cT = childBar:GetTop() * cS / uiScale
                        cB = childBar:GetBottom() * cS / uiScale
                    else
                        local halfW = baseW > 0 and baseW / 2 or (self:GetWidth() / 2)
                        local halfH = baseH > 0 and baseH / 2 or (self:GetHeight() / 2)
                        cL = cx - halfW; cR = cx + halfW
                        cT = cy + halfH; cB = cy - halfH
                    end
                    -- The live rect carries the element's own extra offset (the raid
                    -- container's per-tier offset), which every anchored apply folds in
                    -- again: rebase to the base rect before storing the offsets, like
                    -- the cog's screen-edge link does. The getter is in frame units.
                    local exX, exY = EllesmereUI._ExtraAnchorOffset(self._barKey)
                    exX, exY = exX * cRatio, exY * cRatio
                    cL, cR = cL - exX, cR - exX
                    cT, cB = cT - exY, cB - exY
                    local cCX = (cL + cR) / 2
                    local cCY = (cT + cB) / 2
                    local sd = ai.side
                    if sd == "LEFT" then
                        ai.offsetX = cR - tL
                        ai.offsetY = cCY - tCY
                    elseif sd == "RIGHT" then
                        ai.offsetX = cL - tR
                        ai.offsetY = cCY - tCY
                    elseif sd == "TOP" then
                        ai.offsetX = cCX - tCX
                        ai.offsetY = cB - tT
                    elseif sd == "BOTTOM" then
                        ai.offsetX = cCX - tCX
                        ai.offsetY = cT - tB
                    else
                        ai.offsetX = cCX - tCX
                        ai.offsetY = cCY - tCY
                    end
                end
            end
            -- The cross-axis screen edge rides the same recapture, else the next
            -- apply pulls that axis back to where the edge offset still points.
            if ai.edge and ai.edge.key then
                local eo = EllesmereUI._CaptureScreenEdgeOffset(self._barKey, ai.edge.key, ai.edge.side)
                if eo then ai.edge.offset = eo end
            end
            -- Growth bars: recapture the growth-edge pin from the dropped
            -- position (the user may have carried the bar to the other
            -- corner, which can change the reference edge).
            if EllesmereUI._unlockCaptureGrowPin then
                EllesmereUI._unlockCaptureGrowPin(self._barKey, ai, ai.side)
            end
        end

        -- Anchor chain: propagate recursively down the chain
        UM.PropagateAnchorChain(self._barKey)

        local elem = registeredElements[self._barKey]
        if elem and elem.onLiveMove then
            pcall(elem.onLiveMove, self._barKey)
        end

        -- Keep the mover selected after drag so arrow keys can nudge it.
        -- Drop frame level back to normal so it doesn't block other movers.
        if self._selected then
            self:SetFrameLevel(self._baseLevel or self:GetFrameLevel())
        end

        -- Re-anchor mover to bar for pixel-perfect alignment
        self:ReanchorToBar()
    end)

    -- Hover effects
    mover:SetScript("OnEnter", function(self)
        if not self._dragging then
            if _mouseHeld and not self._dragging then return end
            -- Collapse any other expanded mover before expanding this one
            if UM.hoveredMover and UM.hoveredMover ~= self and not UM.hoveredMover._dragging then
                if UM.hoveredMover._hideOverlayText then UM.hoveredMover._hideOverlayText() end
                UM.hoveredMover = nil
            end
            -- Collapse selected mover's overlay if hovering a different one
            if UM.selectedMover and UM.selectedMover ~= self and not UM.selectedMover._dragging then
                if UM.selectedMover._hideOverlayText then UM.selectedMover._hideOverlayText() end
            end
            UM.hoveredMover = self
            -- Raise above all other movers
            self:SetFrameLevel(self._raisedLevel + 100)
            if self._cogBtn then self._cogBtn:SetFrameLevel(self:GetFrameLevel() + 10) end
            -- Select Element mode: white border highlight on hover targets
            if UM.selectElementPicker and UM.selectElementPicker ~= self then
                self._brd:SetColor(1, 1, 1, 0.9)
                if not UM.darkOverlaysEnabled then self:SetAlpha(MOVER_HOVER) end
                return
            end
            -- Pick mode (width/height match, anchor to): white border on hover targets
            if UM.pickModeMover and UM.pickModeMover ~= self and UM.pickMode then
                self._brd:SetColor(1, 1, 1, 0.9)
                if not UM.darkOverlaysEnabled then self:SetAlpha(MOVER_HOVER) end
                return
            end
            if not UM.darkOverlaysEnabled then self:SetAlpha(MOVER_HOVER) end
            self._brd:SetColor(1, 1, 1, 0.9)
            -- Don't show links if this mover is the pick mode source
            if UM.pickModeMover == self and UM.pickMode then
                -- Already showing pick text, don't override
            else
                -- Wait the intent delay, then expand if still hovered and cursor has settled.
                -- If cursor is still fast at fire time, allow one retry after a short pause.
                self._hoverPending = true
                local m = self
                C_Timer.After(EllesmereUI._unlockHoverIntentDelay, function()
                    if not m._hoverPending then return end
                    if not m:IsMouseOver() and not (m._cogBtn and m._cogBtn:IsMouseOver()) then
                        local overLink = false
                        if m._linkBtns then for _, b in ipairs(m._linkBtns) do if b:IsMouseOver() then overLink = true; break end end end
                        if not overLink then m._hoverPending = false; return end
                    end
                    local function DoExpand()
                        if not m._hoverPending then return end
                        m._hoverPending = false
                        local stillOver = m:IsMouseOver() or (m._cogBtn and m._cogBtn:IsMouseOver())
                        if not stillOver and m._linkBtns then
                            for _, b in ipairs(m._linkBtns) do if b:IsMouseOver() then stillOver = true; break end end
                        end
                        if stillOver and m._showOverlayText then
                            -- Collapse any other mover still animating open
                            if UM.hoveredMover and UM.hoveredMover ~= m and not UM.hoveredMover._dragging then
                                if UM.hoveredMover._hideOverlayText then UM.hoveredMover._hideOverlayText() end
                                UM.hoveredMover = nil
                            end
                            UM.hoveredMover = m
                            m._showOverlayText()
                        end
                    end
                    if EllesmereUI._unlockCursorSpeed > EllesmereUI._unlockHoverSpeedThresh then
                        C_Timer.After(0.08, DoExpand)
                    else
                        DoExpand()
                    end
                end)
            end
        end
    end)
    mover:SetScript("OnLeave", function(self)
        if not self._dragging then
            -- Delay so hovering child buttons (cog, link buttons) doesn't flicker
            C_Timer.After(0.12, function()
                if self._dragging then return end
                if self:IsMouseOver() then
                    self:SetFrameLevel(self._raisedLevel + 100)
                    self._brd:SetColor(1, 1, 1, 0.9)
                    if not UM.darkOverlaysEnabled then self:SetAlpha(MOVER_HOVER) end
                    return
                end
                if self._cogBtn and self._cogBtn:IsMouseOver() then
                    self:SetFrameLevel(self._raisedLevel + 100)
                    self._brd:SetColor(1, 1, 1, 0.9)
                    if not UM.darkOverlaysEnabled then self:SetAlpha(MOVER_HOVER) end
                    return
                end
                if self._linkBtns then
                    for _, btn in ipairs(self._linkBtns) do
                        if btn:IsMouseOver() then
                            self:SetFrameLevel(self._raisedLevel + 100)
                            self._brd:SetColor(1, 1, 1, 0.9)
                            if not UM.darkOverlaysEnabled then self:SetAlpha(MOVER_HOVER) end
                            return
                        end
                    end
                end
                -- Truly left the element -- cancel any pending expand and collapse
                self._hoverPending = false
                if self._hideOverlayText then self._hideOverlayText() end
                if UM.hoveredMover == self then UM.hoveredMover = nil end
                -- Keep highlight border and raised level if selected (arrow keys)
                if not self._selected then
                    self:SetFrameLevel(self._baseLevel)
                    if not UM.darkOverlaysEnabled then self:SetAlpha(MOVER_ALPHA) end
                    self._brd:SetColor(ar, ag, ab, 0.6)
                end
            end)
        end
    end)

    -- Left-click to select
    mover:SetScript("OnClick", function(self, button)
        if button == "LeftButton" then
            -- Width Match / Height Match / Anchor To pick mode handling
            -- Clicking the source mover itself cancels the pick mode
            if UM.pickModeMover and UM.pickModeMover == self and UM.pickMode then
                CancelPickMode()
                return
            end
            if UM.pickModeMover and UM.pickModeMover ~= self and UM.pickMode then
                local sourceMover = UM.pickModeMover
                local sourceKey = sourceMover._barKey
                local targetKey = self._barKey

                if UM.pickMode == "widthMatch" then
                    local tEl = registeredElements[targetKey]
                    if tEl and tEl.noSizeMatchTarget then
                        CancelPickMode()
                        FlashRedBorder(self)
                        local tLabel = UM.GetBarLabel(targetKey) or targetKey
                        RejectH.ShowTooltip("Elements cannot size match to\n" .. tLabel)
                        return
                    end
                    if RejectH.IsActionBar(sourceKey) and not RejectH.IsActionBar(targetKey) then
                        CancelPickMode()
                        FlashRedBorder(self)
                        RejectH.ShowTooltip("Action Bars can only width match\nto other Action Bars")
                        return
                    end
                    local wdb = MatchH.GetWidthMatchDB()
                    if wdb and MatchH.WouldCreateCycle(wdb, sourceKey, targetKey) then
                        CancelPickMode()
                        FlashRedBorder(self)
                        RejectH.ShowTooltip("This would create a circular width match")
                        return
                    end
                    MatchH.SetWidthMatch(sourceKey, targetKey)
                    MatchH.ApplyWidthMatch(sourceKey, targetKey)
                    UM.hasChanges = true
                    CancelPickMode()
                    local sm = movers[sourceKey]
                    if sm then
                        sm:SyncSize()
                        if sm.RefreshAnchoredText then sm:RefreshAnchoredText() end
                    end
                    local ai = GetAnchorInfo(sourceKey)
                    if ai then UM.ApplyAnchorPosition(sourceKey, ai.target, ai.side, true) end
                    EllesmereUI.PropagateWidthMatch(sourceKey)
                    UM.PropagateAnchorChain(sourceKey)
                    return

                elseif UM.pickMode == "heightMatch" then
                    local tEl = registeredElements[targetKey]
                    if tEl and tEl.noSizeMatchTarget then
                        CancelPickMode()
                        FlashRedBorder(self)
                        local tLabel = UM.GetBarLabel(targetKey) or targetKey
                        RejectH.ShowTooltip("Elements cannot size match to\n" .. tLabel)
                        return
                    end
                    local hdb = MatchH.GetHeightMatchDB()
                    if hdb and MatchH.WouldCreateCycle(hdb, sourceKey, targetKey) then
                        CancelPickMode()
                        FlashRedBorder(self)
                        RejectH.ShowTooltip("This would create a circular height match")
                        return
                    end
                    MatchH.SetHeightMatch(sourceKey, targetKey)
                    MatchH.ApplyHeightMatch(sourceKey, targetKey)
                    UM.hasChanges = true
                    CancelPickMode()
                    local sm = movers[sourceKey]
                    if sm then
                        sm:SyncSize()
                        if sm.RefreshAnchoredText then sm:RefreshAnchoredText() end
                    end
                    local ai = GetAnchorInfo(sourceKey)
                    if ai then UM.ApplyAnchorPosition(sourceKey, ai.target, ai.side, true) end
                    EllesmereUI.PropagateHeightMatch(sourceKey)
                    UM.PropagateAnchorChain(sourceKey)
                    return

                elseif UM.pickMode == "anchorTo" or UM.pickMode == "fallbackAnchor"
                    or UM.pickMode == "overrideAnchor" then
                    -- Show anchor direction dropdown near the clicked target.
                    -- fallbackAnchor mode stores a fallback link on the
                    -- element's EXISTING anchor instead of re-anchoring it;
                    -- overrideAnchor mode stores a per-override-group link.
                    local fbPick = (UM.pickMode == "fallbackAnchor")
                    local ovPick = (UM.pickMode == "overrideAnchor")
                    local ovGid = ovPick and EllesmereUI._OverridePickGid
                        and EllesmereUI._OverridePickGid() or nil
                    local pm = UM.pickModeMover
                    local pmKey = pm._barKey

                    -- Reject elements marked as non-anchorable (e.g. buff bars
                    -- whose icon count changes dynamically with auras).
                    local targetEl = registeredElements[targetKey]
                    if targetEl and targetEl.noAnchorTarget then
                        CancelPickMode()
                        FlashRedBorder(self)
                        local targetLabel = UM.GetBarLabel(targetKey) or targetKey
                        RejectH.ShowTooltip("Elements cannot be anchored to\n" .. targetLabel)
                        return
                    end

                    if fbPick then
                        local curInfo = GetAnchorInfo(pmKey)
                        if not curInfo or not curInfo.target then
                            CancelPickMode()
                            FlashRedBorder(self)
                            RejectH.ShowTooltip("Anchor this element first")
                            return
                        end
                        if targetKey == curInfo.target then
                            CancelPickMode()
                            FlashRedBorder(self)
                            RejectH.ShowTooltip("The fallback must differ from\nthe main anchor target")
                            return
                        end
                    end

                    if ovPick then
                        if not ovGid then
                            CancelPickMode()
                            return
                        end
                        if targetKey == pmKey then
                            CancelPickMode()
                            FlashRedBorder(self)
                            RejectH.ShowTooltip("An element cannot anchor to itself")
                            return
                        end
                        -- Walk primary + fallback + override edges from the
                        -- target: reaching this element means an engaged loop
                        -- could chase itself across cascades forever.
                        local circular = false
                        local seen = {}
                        local stack = { targetKey }
                        while #stack > 0 do
                            local k = table.remove(stack)
                            if k == pmKey then circular = true break end
                            if not seen[k] then
                                seen[k] = true
                                local info = GetAnchorInfo(k)
                                if info and info.target then stack[#stack + 1] = info.target end
                                if info and info.fallback and info.fallback.target then
                                    stack[#stack + 1] = info.fallback.target
                                end
                                local ovT = EllesmereUI._OverrideAnchorTargets
                                    and EllesmereUI._OverrideAnchorTargets(k)
                                if ovT then
                                    for i = 1, #ovT do stack[#stack + 1] = ovT[i] end
                                end
                            end
                        end
                        if circular then
                            CancelPickMode()
                            FlashRedBorder(self)
                            RejectH.ShowTooltip("This would create a circular anchor")
                            return
                        end
                    end

                    -- Circular / ancestor checks guard PRIMARY anchor links;
                    -- a fallback/override is a one-level positional read, so
                    -- they use their own checks above instead.
                    if not fbPick and not ovPick then
                        local circular = false
                        local visited = { [pmKey] = true }
                        local walk = targetKey
                        while walk do
                            if visited[walk] then circular = true; break end
                            visited[walk] = true
                            local info = GetAnchorInfo(walk)
                            walk = info and info.target or nil
                        end
                        if circular then
                            CancelPickMode()
                            FlashRedBorder(self)
                            RejectH.ShowTooltip("This would create a circular anchor")
                            return
                        end

                        -- Ancestor depth check: prevent anchoring to a grandparent
                        -- or higher. Only direct parent (depth 1) or unrelated
                        -- elements are valid targets.
                        local ancestorDepth = 0
                        local aWalk = pmKey
                        while aWalk do
                            local aInfo = GetAnchorInfo(aWalk)
                            if not aInfo or not aInfo.target then break end
                            ancestorDepth = ancestorDepth + 1
                            if aInfo.target == targetKey and ancestorDepth >= 2 then
                                CancelPickMode()
                                FlashRedBorder(self)
                                RejectH.ShowTooltip("This would create a circular anchor")
                                return
                            end
                            aWalk = aInfo.target
                        end
                    end

                    CancelPickMode()
                    -- Build and show the anchor direction dropdown
                    if not UM.anchorDropdownFrame then
                        UM.anchorDropdownFrame = CreateFrame("Frame", nil, UM.unlockFrame)
                        UM.anchorDropdownFrame:SetFrameStrata("FULLSCREEN_DIALOG")
                        UM.anchorDropdownFrame:SetFrameLevel(260)
                        UM.anchorDropdownFrame:SetClampedToScreen(true)
                        UM.anchorDropdownFrame:EnableMouse(true)
                    end
                    -- Click catcher behind dropdown
                    if not UM.anchorDropdownCatcher then
                        UM.anchorDropdownCatcher = CreateFrame("Button", nil, UM.unlockFrame)
                        UM.anchorDropdownCatcher:SetFrameStrata("FULLSCREEN_DIALOG")
                        UM.anchorDropdownCatcher:SetFrameLevel(259)
                        UM.anchorDropdownCatcher:SetAllPoints(UIParent)
                        UM.anchorDropdownCatcher:RegisterForClicks("AnyUp")
                        UM.anchorDropdownCatcher:SetScript("OnClick", function()
                            UM.anchorDropdownFrame:Hide()
                            UM.anchorDropdownCatcher:Hide()
                        end)
                    end
                    -- Rebuild dropdown content
                    for _, child in ipairs({UM.anchorDropdownFrame:GetChildren()}) do child:Hide(); child:SetParent(nil) end
                    for _, tex in ipairs({UM.anchorDropdownFrame:GetRegions()}) do if tex.Hide then tex:Hide() end end

                    local DD_ITEM_H = 24
                    local DD_WIDTH = 160
                    UM.anchorDropdownFrame:SetSize(DD_WIDTH, 10)
                    UM.anchorDropdownFrame:ClearAllPoints()
                    local scale = UIParent:GetEffectiveScale()
                    local curX, curY = GetCursorPosition()
                    curX = curX / scale
                    curY = curY / scale - UIParent:GetHeight()
                    UM.anchorDropdownFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", curX, curY)

                    local ddBg = UM.anchorDropdownFrame:CreateTexture(nil, "BACKGROUND")
                    ddBg:SetAllPoints()
                    ddBg:SetColorTexture(0.075, 0.113, 0.141, 0.95)
                    EllesmereUI.MakeBorder(UM.anchorDropdownFrame, 1, 1, 1, 0.20)

                    local ddY = -4
                    -- Growth bars (CDM and action bars) get the corner rows below on a
                    -- primary anchor pick; the hint speaks to those rows when they exist.
                    local isGrowBar = not fbPick and not ovPick
                        and (pmKey:sub(1, 4) == "CDM_"
                             or (EllesmereUI._abBarKeys and EllesmereUI._abBarKeys[pmKey]) or false)
                    -- Title: the fallback picker keeps its short dimmed label;
                    -- the anchor picker shows a wrapped usage hint in the same
                    -- color as the option rows below.
                    local titleFS = UM.anchorDropdownFrame:CreateFontString(nil, "OVERLAY")
                    titleFS:SetFont(FONT_PATH, 10, "OUTLINE, SLUG")
                    titleFS:SetJustifyH("LEFT")
                    titleFS:SetPoint("TOPLEFT", UM.anchorDropdownFrame, "TOPLEFT", 10, ddY - 4)
                    if fbPick then
                        titleFS:SetTextColor(1, 1, 1, 0.40)
                        titleFS:SetText(EllesmereUI.L("Fallback Direction"))
                        ddY = ddY - 18
                    elseif ovPick then
                        titleFS:SetTextColor(1, 1, 1, 0.40)
                        titleFS:SetText(EllesmereUI.L("Override Anchor Direction"))
                        ddY = ddY - 18
                    else
                        titleFS:SetTextColor(0.75, 0.75, 0.75, 0.9)
                        titleFS:SetWidth(DD_WIDTH - 20)
                        titleFS:SetWordWrap(true)
                        if isGrowBar then
                            titleFS:SetText(EllesmereUI.L("Corner options place the bar flush with that corner of the target and set its grow direction to keep it there as bars change size."))
                        else
                            titleFS:SetText(EllesmereUI.L("After anchoring, drag to an edge and choose a grow direction to maintain its corner spot as bars change size."))
                        end
                        ddY = ddY - (titleFS:GetStringHeight() + 8)
                    end
                    local titleDiv = UM.anchorDropdownFrame:CreateTexture(nil, "ARTWORK")
                    titleDiv:SetHeight(1)
                    titleDiv:SetColorTexture(1, 1, 1, 0.10)
                    titleDiv:SetPoint("TOPLEFT", UM.anchorDropdownFrame, "TOPLEFT", 1, ddY - 2)
                    titleDiv:SetPoint("TOPRIGHT", UM.anchorDropdownFrame, "TOPRIGHT", -1, ddY - 2)
                    ddY = ddY - 5

                    local sides = { "Left", "Right", "Top", "Bottom" }
                    for _, sideName in ipairs(sides) do
                        local sideVal = string.upper(sideName)
                        local item = CreateFrame("Button", nil, UM.anchorDropdownFrame)
                        item:SetHeight(DD_ITEM_H)
                        item:SetPoint("TOPLEFT", UM.anchorDropdownFrame, "TOPLEFT", 1, ddY)
                        item:SetPoint("TOPRIGHT", UM.anchorDropdownFrame, "TOPRIGHT", -1, ddY)
                        item:SetFrameLevel(UM.anchorDropdownFrame:GetFrameLevel() + 2)
                        item:RegisterForClicks("AnyUp")
                        local hl = item:CreateTexture(nil, "ARTWORK")
                        hl:SetAllPoints()
                        hl:SetColorTexture(1, 1, 1, 0)
                        local lbl = item:CreateFontString(nil, "OVERLAY")
                        lbl:SetFont(FONT_PATH, 11, "OUTLINE, SLUG")
                        lbl:SetTextColor(0.75, 0.75, 0.75, 0.9)
                        lbl:SetJustifyH("LEFT")
                        lbl:SetPoint("LEFT", item, "LEFT", 10, 0)
                        lbl:SetText(EllesmereUI.Lf(fbPick and "Fallback to %1$s" or "Anchor to %1$s", EllesmereUI.L(sideName)))
                        item:SetScript("OnEnter", function()
                            hl:SetColorTexture(1, 1, 1, 0.08)
                            lbl:SetTextColor(1, 1, 1, 1)
                        end)
                        item:SetScript("OnLeave", function()
                            hl:SetColorTexture(1, 1, 1, 0)
                            lbl:SetTextColor(0.75, 0.75, 0.75, 0.9)
                        end)
                        item:SetScript("OnClick", function()
                            UM.anchorDropdownFrame:Hide()
                            UM.anchorDropdownCatcher:Hide()
                            if ovPick then
                                -- Store the override link; the element only
                                -- moves while that group's override is active.
                                if EllesmereUI._SetOverrideAnchor then
                                    EllesmereUI._SetOverrideAnchor(pmKey, ovGid, targetKey, sideVal)
                                end
                                UM.hasChanges = true
                                return
                            end
                            if fbPick then
                                -- Store the fallback link; the element only
                                -- moves when the main target is absent.
                                if EllesmereUI.SetAnchorFallback then
                                    EllesmereUI.SetAnchorFallback(pmKey, targetKey, sideVal)
                                end
                                UM.hasChanges = true
                                return
                            end
                            -- Default grow direction to match the anchor side
                            -- (orientation-aware: cross-axis sides map to CENTER)
                            local isVert = false
                            if pmKey:sub(1, 4) == "CDM_" then
                                local rawCdmKey = pmKey:sub(5)
                                local cdmAddon = EllesmereUI.Lite.GetAddon("EllesmereUICooldownManager", true)
                                local cdmBars = cdmAddon and cdmAddon.db and cdmAddon.db.profile and cdmAddon.db.profile.cdmBars
                                if cdmBars and cdmBars.bars then
                                    for _, bar in ipairs(cdmBars.bars) do
                                        if bar.key == rawCdmKey then
                                            isVert = bar.verticalOrientation == true
                                            local map = isVert
                                                and { TOP = "UP", BOTTOM = "DOWN", LEFT = "CENTER", RIGHT = "CENTER" }
                                                or  { LEFT = "LEFT", RIGHT = "RIGHT", TOP = "CENTER", BOTTOM = "CENTER" }
                                            bar.growDirection = map[sideVal] or "CENTER"
                                            break
                                        end
                                    end
                                end
                            else
                                local eab = EllesmereUI.Lite.GetAddon("EllesmereUIActionBars", true)
                                local abBars = eab and eab.db and eab.db.profile and eab.db.profile.bars
                                local abCfg = abBars and abBars[pmKey]
                                if abCfg then
                                    isVert = (abCfg.orientation == "vertical")
                                    local map = isVert
                                        and { TOP = "up", BOTTOM = "down", LEFT = "center", RIGHT = "center" }
                                        or  { LEFT = "left", RIGHT = "right", TOP = "center", BOTTOM = "center" }
                                    abCfg.growDirection = map[sideVal] or "center"
                                end
                            end
                            -- Set anchor relationship
                            SetAnchorInfo(pmKey, targetKey, sideVal)
                            -- Apply the anchor position
                            UM.ApplyAnchorPosition(pmKey, targetKey, sideVal)
                            -- Propagate to children after layout flushes so
                            -- they read the correct bounds from the newly-anchored parent
                            C_Timer.After(0, function() UM.PropagateAnchorChain(pmKey) end)
                            UM.hasChanges = true
                            -- Refresh the anchored mover's text
                            if movers[pmKey] and movers[pmKey].RefreshAnchoredText then
                                movers[pmKey]:RefreshAnchoredText()
                            end
                            -- Sync mover position to follow the element after anchor placement
                            DeferMoverSync(movers[pmKey], function(m) m:Sync() end, UM.GetBarFrame(pmKey))
                        end)
                        ddY = ddY - DD_ITEM_H
                    end

                    -- Corner rows (growth bars, primary anchor only): the bar sits flush
                    -- with that corner of the target and grows away from it. Nothing new
                    -- in the record -- it is the side pick above, the flush drag and the
                    -- cog's Grow row in one click. A corner reads by the bar's
                    -- orientation: a horizontal bar sits above or below the target
                    -- (Top/Bottom) with the named edges flush and grows away from them; a
                    -- vertical bar sits beside it (Left/Right) the same way. So the four
                    -- rows cover exactly the sides the picks above leave centered.
                    if isGrowBar then
                        local divC = UM.anchorDropdownFrame:CreateTexture(nil, "ARTWORK")
                        divC:SetHeight(1)
                        divC:SetColorTexture(1, 1, 1, 0.10)
                        divC:SetPoint("TOPLEFT", UM.anchorDropdownFrame, "TOPLEFT", 1, ddY - 4)
                        divC:SetPoint("TOPRIGHT", UM.anchorDropdownFrame, "TOPRIGHT", -1, ddY - 4)
                        ddY = ddY - 9
                        local corners = {
                            { label = EllesmereUI.L("Top Left"),     v = "TOP",    h = "LEFT"  },
                            { label = EllesmereUI.L("Top Right"),    v = "TOP",    h = "RIGHT" },
                            { label = EllesmereUI.L("Bottom Left"),  v = "BOTTOM", h = "LEFT"  },
                            { label = EllesmereUI.L("Bottom Right"), v = "BOTTOM", h = "RIGHT" },
                        }
                        for _, corner in ipairs(corners) do
                            local item = CreateFrame("Button", nil, UM.anchorDropdownFrame)
                            item:SetHeight(DD_ITEM_H)
                            item:SetPoint("TOPLEFT", UM.anchorDropdownFrame, "TOPLEFT", 1, ddY)
                            item:SetPoint("TOPRIGHT", UM.anchorDropdownFrame, "TOPRIGHT", -1, ddY)
                            item:SetFrameLevel(UM.anchorDropdownFrame:GetFrameLevel() + 2)
                            item:RegisterForClicks("AnyUp")
                            local hl = item:CreateTexture(nil, "ARTWORK")
                            hl:SetAllPoints()
                            hl:SetColorTexture(1, 1, 1, 0)
                            local lbl = item:CreateFontString(nil, "OVERLAY")
                            lbl:SetFont(FONT_PATH, 11, "OUTLINE, SLUG")
                            lbl:SetTextColor(0.75, 0.75, 0.75, 0.9)
                            lbl:SetJustifyH("LEFT")
                            lbl:SetPoint("LEFT", item, "LEFT", 10, 0)
                            lbl:SetText(EllesmereUI.Lf("Anchor to %1$s", corner.label))
                            item:SetScript("OnEnter", function()
                                hl:SetColorTexture(1, 1, 1, 0.08)
                                lbl:SetTextColor(1, 1, 1, 1)
                            end)
                            item:SetScript("OnLeave", function()
                                hl:SetColorTexture(1, 1, 1, 0)
                                lbl:SetTextColor(0.75, 0.75, 0.75, 0.9)
                            end)
                            item:SetScript("OnClick", function()
                                UM.anchorDropdownFrame:Hide()
                                UM.anchorDropdownCatcher:Hide()
                                -- Orientation, the same lookups as the side pick. The bar is
                                -- placed on centered growth first (the side pick's own default
                                -- for this side): a held growth edge would otherwise pin the
                                -- bar to where it stood before the anchor moved it.
                                local isVert = false
                                if pmKey:sub(1, 4) == "CDM_" then
                                    local rawCdmKey = pmKey:sub(5)
                                    local cdmAddon = EllesmereUI.Lite.GetAddon("EllesmereUICooldownManager", true)
                                    local cdmBars = cdmAddon and cdmAddon.db and cdmAddon.db.profile and cdmAddon.db.profile.cdmBars
                                    if cdmBars and cdmBars.bars then
                                        for _, bar in ipairs(cdmBars.bars) do
                                            if bar.key == rawCdmKey then
                                                isVert = bar.verticalOrientation == true
                                                bar.growDirection = "CENTER"
                                                break
                                            end
                                        end
                                    end
                                else
                                    local eab = EllesmereUI.Lite.GetAddon("EllesmereUIActionBars", true)
                                    local abBars = eab and eab.db and eab.db.profile and eab.db.profile.bars
                                    local abCfg = abBars and abBars[pmKey]
                                    if abCfg then
                                        isVert = (abCfg.orientation == "vertical")
                                        abCfg.growDirection = "center"
                                    end
                                end
                                -- The side the corner means, the edge held flush along it and
                                -- the direction that grows away from that edge.
                                local sideVal = isVert and corner.h or corner.v
                                local flush = isVert and corner.v or corner.h
                                local growVal
                                if isVert then
                                    growVal = (flush == "TOP") and "DOWN" or "UP"
                                else
                                    growVal = (flush == "RIGHT") and "LEFT" or "RIGHT"
                                end
                                -- Flush edges: the side pick centers the bar along the side, so
                                -- the shift is half the size difference (UIParent units,
                                -- pixel-snapped like the side pick's own offsets). Sizes, not
                                -- rects: the target's bounds are read before anything moves.
                                local offX, offY = 0, 0
                                local childF, targetF = UM.GetBarFrame(pmKey), UM.GetBarFrame(targetKey)
                                if childF and targetF then
                                    local uiS = UIParent:GetEffectiveScale()
                                    local cS, tS = childF:GetEffectiveScale() / uiS, targetF:GetEffectiveScale() / uiS
                                    local snap = (EllesmereUI.PP and EllesmereUI.PP.Snap) or function(v) return math.floor(v + 0.5) end
                                    if isVert then
                                        local half = ((targetF:GetHeight() or 0) * tS - (childF:GetHeight() or 0) * cS) / 2
                                        offY = snap((flush == "TOP") and half or -half)
                                    else
                                        local half = ((targetF:GetWidth() or 0) * tS - (childF:GetWidth() or 0) * cS) / 2
                                        offX = snap((flush == "RIGHT") and half or -half)
                                    end
                                end
                                -- Set anchor relationship, flush offsets included (the record a
                                -- side pick plus a drag to the edge leaves behind)
                                SetAnchorInfo(pmKey, targetKey, sideVal, offX, offY)
                                -- A screen edge the element holds on the flush axis would win
                                -- that axis on every apply and undo the alignment just asked
                                -- for: release it, the Relative-to-Screen clear path's way.
                                local aiC = GetAnchorInfo(pmKey)
                                if aiC and aiC.edge and aiC.edge.key and EllesmereUI._ScreenEdgeAxis
                                   and EllesmereUI._ScreenEdgeAxis(aiC.edge.key) == (isVert and "Y" or "X") then
                                    aiC.edge = nil
                                    EllesmereUI._anchorLinksStamp = (EllesmereUI._anchorLinksStamp or 0) + 1
                                end
                                -- Apply the anchor position
                                UM.ApplyAnchorPosition(pmKey, targetKey, sideVal)
                                -- Grow away from the flush edge, after the placement: the
                                -- growth-edge hold captures from where the bar now sits.
                                EllesmereUI._unlockSetGrowDirection(pmKey, growVal)
                                -- Propagate to children after layout flushes so
                                -- they read the correct bounds from the newly-anchored parent
                                C_Timer.After(0, function() UM.PropagateAnchorChain(pmKey) end)
                                UM.hasChanges = true
                                -- Refresh the anchored mover's text
                                if movers[pmKey] and movers[pmKey].RefreshAnchoredText then
                                    movers[pmKey]:RefreshAnchoredText()
                                end
                                -- Sync mover position to follow the element after anchor placement
                                DeferMoverSync(movers[pmKey], function(m) m:Sync() end, UM.GetBarFrame(pmKey))
                            end)
                            ddY = ddY - DD_ITEM_H
                        end
                    end

                    -- "Remove Anchor" option if already anchored
                    if not fbPick and IsAnchored(pmKey) then
                        local divR = UM.anchorDropdownFrame:CreateTexture(nil, "ARTWORK")
                        divR:SetHeight(1)
                        divR:SetColorTexture(1, 1, 1, 0.10)
                        divR:SetPoint("TOPLEFT", UM.anchorDropdownFrame, "TOPLEFT", 1, ddY - 4)
                        divR:SetPoint("TOPRIGHT", UM.anchorDropdownFrame, "TOPRIGHT", -1, ddY - 4)
                        ddY = ddY - 9

                        local removeItem = CreateFrame("Button", nil, UM.anchorDropdownFrame)
                        removeItem:SetHeight(DD_ITEM_H)
                        removeItem:SetPoint("TOPLEFT", UM.anchorDropdownFrame, "TOPLEFT", 1, ddY)
                        removeItem:SetPoint("TOPRIGHT", UM.anchorDropdownFrame, "TOPRIGHT", -1, ddY)
                        removeItem:SetFrameLevel(UM.anchorDropdownFrame:GetFrameLevel() + 2)
                        removeItem:RegisterForClicks("AnyUp")
                        local rHl = removeItem:CreateTexture(nil, "ARTWORK")
                        rHl:SetAllPoints()
                        rHl:SetColorTexture(1, 1, 1, 0)
                        local rLbl = removeItem:CreateFontString(nil, "OVERLAY")
                        rLbl:SetFont(FONT_PATH, 11, "OUTLINE, SLUG")
                        rLbl:SetTextColor(0.9, 0.3, 0.3, 0.9)
                        rLbl:SetJustifyH("LEFT")
                        rLbl:SetPoint("LEFT", removeItem, "LEFT", 10, 0)
                        rLbl:SetText(EllesmereUI.L("Remove Anchor"))
                        removeItem:SetScript("OnEnter", function()
                            rHl:SetColorTexture(1, 1, 1, 0.08)
                            rLbl:SetTextColor(1, 0.4, 0.4, 1)
                        end)
                        removeItem:SetScript("OnLeave", function()
                            rHl:SetColorTexture(1, 1, 1, 0)
                            rLbl:SetTextColor(0.9, 0.3, 0.3, 0.9)
                        end)
                        removeItem:SetScript("OnClick", function()
                            UM.anchorDropdownFrame:Hide()
                            UM.anchorDropdownCatcher:Hide()
                            ClearAnchorInfo(pmKey)
                            UM.hasChanges = true
                            if movers[pmKey] and movers[pmKey].RefreshAnchoredText then
                                movers[pmKey]:RefreshAnchoredText()
                            end
                        end)
                        ddY = ddY - DD_ITEM_H
                    end

                    UM.anchorDropdownFrame:SetHeight(-ddY + 4)
                    UM.anchorDropdownFrame:Show()
                    UM.anchorDropdownCatcher:Show()
                    return
                end
            end

            -- Select Element pick mode: clicking a different mover sets it as snap target
            if UM.selectElementPicker and UM.selectElementPicker ~= self then
                local picker = UM.selectElementPicker
                picker._snapTarget = self._barKey
                picker._preSelectTarget = nil
                UM.selectElementPicker = nil
                FadeOverlayForSelectElement(false)
                -- Restore this mover's normal colors
                self._brd:SetColor(ar, ag, ab, 0.6)
                if not UM.darkOverlaysEnabled then self:SetAlpha(MOVER_ALPHA) end
                -- Update the picker's dropdown label
                if picker._updateSnapLabel then picker._updateSnapLabel() end
                return
            end
            -- Toggle: clicking the already-selected mover deselects it
            if UM.selectedMover == self then
                DeselectMover()
            else
                SelectMover(self)
            end
        elseif button == "RightButton" then
            if UM.selectElementPicker then return end
            -- Shift+Right Click temporarily hides this element's overlay for the
            -- current unlock session. The _tempHidden flag is cleared when unlock
            -- mode is next entered, so the overlay reappears then. Purely a visual
            -- toggle on the overlay -- it never touches the underlying element.
            if IsShiftKeyDown() then
                self._tempHidden = true
                self._hoverPending = false
                if UM.selectedMover == self then DeselectMover() end
                if UM.hoveredMover == self then UM.hoveredMover = nil end
                if self._hideOverlayText then self._hideOverlayText() end
                -- Hide the cog too; its OnHide closes any open cog menu.
                if self._cogBtn then self._cogBtn:Hide() end
                self:Hide()
                return
            end
            SelectMover(self)
            if self._openCogMenu then self._openCogMenu() end
        end
    end)
    mover:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    ---------------------------------------------------------------------------
    --  Action toolbar: cog settings button only
    --  Cog is flush with mover's top-right corner.
    ---------------------------------------------------------------------------
    local ICON_PATH = "Interface\\AddOns\\EllesmereUI\\media\\icons\\"
    local ARROW_ICON  = ICON_PATH .. "eui-arrow.png"
    local ARROW_RIGHT_ICON = ICON_PATH .. "right-arrow.png"
    local COGS_ICON   = EllesmereUI.COGS_ICON or (ICON_PATH .. "cogs-3.png")
    local ACT_SZ = 22       -- cog button size
    local ACT_PAD = 3       -- gap between cog and dropdown
    local DD_W = 150        -- dropdown width

    -- Cog settings button (opens a dropdown with Reset / Center / Orientation)
    cogBtn = CreateFrame("Button", nil, UM.unlockFrame)
    cogBtn:SetFrameLevel(mover:GetFrameLevel() + 10)
    cogBtn:RegisterForClicks("AnyUp")
    cogBtn:EnableMouse(true)
    cogBtn:SetSize(ACT_SZ, ACT_SZ)
    do
        local bg = cogBtn:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.075, 0.113, 0.141, 0.9)
        cogBtn._bg = bg
        local brd = EllesmereUI.MakeBorder(cogBtn, 1, 1, 1, 0.20)
        cogBtn._brd = brd
        local icon = cogBtn:CreateTexture(nil, "ARTWORK")
        icon:SetSize(18, 18)
        icon:SetPoint("CENTER")
        icon:SetTexture(COGS_ICON)
        icon:SetAlpha(0.7)
        cogBtn._icon = icon
        cogBtn:SetScript("OnEnter", function(self)
            self._bg:SetColorTexture(0.075, 0.113, 0.141, 0.98)
            self._brd:SetColor(1, 1, 1, 0.30)
            self._icon:SetAlpha(1)
            mover:SetFrameLevel(mover._raisedLevel + 100)
            mover._brd:SetColor(1, 1, 1, 0.9)
            if not UM.darkOverlaysEnabled then mover:SetAlpha(MOVER_HOVER) end
        end)
        cogBtn:SetScript("OnLeave", function(self)
            self._bg:SetColorTexture(0.075, 0.113, 0.141, 0.9)
            self._brd:SetColor(1, 1, 1, 0.20)
            self._icon:SetAlpha(0.7)
        end)
    end
    cogBtn:Hide()

    -- Cog visibility is now tied to the hover animation.
    -- Show/hide helpers are simple wrappers.
    local function ShowCogForHover() end
    local function HideCogAfterDelay() end
    local function HideCogImmediate() end

    mover._showCogForHover = ShowCogForHover
    mover._hideCogAfterDelay = HideCogAfterDelay
    mover._hideCogImmediate = HideCogImmediate

    -- Re-set cogBtn hover scripts now that fade helpers are in scope
    cogBtn:SetScript("OnEnter", function(self)
        self._bg:SetColorTexture(0.075, 0.113, 0.141, 0.98)
        self._brd:SetColor(1, 1, 1, 0.30)
        self._icon:SetAlpha(1)
        -- Restore mover highlight immediately (mover:OnLeave resets it when mouse moves to cog)
        mover:SetFrameLevel(mover._raisedLevel + 100)
        mover._brd:SetColor(1, 1, 1, 0.9)
        if not UM.darkOverlaysEnabled then mover:SetAlpha(MOVER_HOVER) end
    end)
    cogBtn:SetScript("OnLeave", function(self)
        self._bg:SetColorTexture(0.075, 0.113, 0.141, 0.9)
        self._brd:SetColor(1, 1, 1, 0.20)
        self._icon:SetAlpha(0.7)
    end)

    ---------------------------------------------------------------------------
    --  Snap-to dropdown (custom styled, per-mover memory)
    ---------------------------------------------------------------------------
    local snapDD = CreateFrame("Button", nil, UM.unlockFrame)
    snapDD:SetFrameLevel(mover:GetFrameLevel() + 10)
    snapDD:RegisterForClicks("AnyUp")
    snapDD:EnableMouse(true)
    snapDD:SetSize(DD_W, 30)
    local snapDDBg = snapDD:CreateTexture(nil, "BACKGROUND")
    snapDDBg:SetAllPoints()
    snapDDBg:SetColorTexture(0.075, 0.113, 0.141, 0.9)
    snapDD._bg = snapDDBg
    local snapDDBrd = EllesmereUI.MakeBorder(snapDD, 1, 1, 1, 0.20)
    snapDD._brd = snapDDBrd
    local snapDDLbl = snapDD:CreateFontString(nil, "OVERLAY")
    snapDDLbl:SetFont(FONT_PATH, 12, "OUTLINE, SLUG")
    snapDDLbl:SetTextColor(1, 1, 1, 0.50)
    snapDDLbl:SetJustifyH("LEFT")
    snapDDLbl:SetWordWrap(false)
    snapDDLbl:SetMaxLines(1)
    snapDDLbl:SetPoint("LEFT", snapDD, "LEFT", 8, 0)
    snapDDLbl:SetText(EllesmereUI.L("Snap to: Auto"))
    local snapDDArrow = EllesmereUI.MakeDropdownArrow(snapDD, 12)
    snapDDLbl:SetPoint("RIGHT", snapDDArrow, "LEFT", -5, 0)
    snapDD:SetScript("OnEnter", function(self)
        if not UM.snapEnabled then
            -- Grayed out: show tooltip explaining why
            EllesmereUI.ShowWidgetTooltip(self, "This feature requires Snap Elements to be enabled")
            return
        end
        self._bg:SetColorTexture(0.075, 0.113, 0.141, 0.98)
        self._brd:SetColor(1, 1, 1, 0.30)
        snapDDLbl:SetTextColor(1, 1, 1, 0.60)
    end)
    snapDD:SetScript("OnLeave", function(self)
        EllesmereUI.HideWidgetTooltip()
        if not UM.snapEnabled then return end
        self._bg:SetColorTexture(0.075, 0.113, 0.141, 0.9)
        self._brd:SetColor(1, 1, 1, 0.20)
        snapDDLbl:SetTextColor(1, 1, 1, 0.50)
    end)
    snapDD:Hide()

    -- Helper: apply grayed-out or normal visual state to the dropdown
    local function RefreshSnapDDState()
        if not UM.snapEnabled then
            snapDDBg:SetColorTexture(0.075, 0.113, 0.141, 0.50)
            snapDDBrd:SetColor(1, 1, 1, 0.07)
            snapDDLbl:SetTextColor(1, 1, 1, 0.20)
            snapDDArrow:SetAlpha(0.10)
        else
            snapDDBg:SetColorTexture(0.075, 0.113, 0.141, 0.9)
            snapDDBrd:SetColor(1, 1, 1, 0.20)
            snapDDLbl:SetTextColor(1, 1, 1, 0.50)
            snapDDArrow:SetAlpha(1)
        end
    end
    mover._refreshSnapDD = RefreshSnapDDState

    -- Snap dropdown menu frame (lazy-created, shared across this mover)
    local snapMenu
    local regSubMenus = {}

    local function CloseSnapMenu()
        if snapMenu then snapMenu:Hide() end
        for _, rs in pairs(regSubMenus) do
            if rs and rs.Hide then rs:Hide() end
        end
    end

    local function UpdateSnapLabel()
        local tgt = mover._snapTarget
        if tgt == "_disable_" then
            snapDDLbl:SetText(EllesmereUI.L("Snap to: None"))
        elseif tgt == "_select_" then
            snapDDLbl:SetText(EllesmereUI.L("Snap to: Select Element"))
        elseif tgt then
            local lbl = UM.GetBarLabel(tgt)
            snapDDLbl:SetText(EllesmereUI.Lf("Snap to: %1$s", lbl or tgt))
        else
            snapDDLbl:SetText(EllesmereUI.L("Snap to: All Elements"))
        end
        -- Update snap highlight to match new target
        if mover._selected then
            if tgt and tgt ~= "_disable_" and tgt ~= "_select_" and movers[tgt] then
                ShowSnapHighlight(tgt)
            else
                ClearSnapHighlight()
            end
        end
    end

    local function BuildSnapMenu()
        if snapMenu then
            -- Rebuild items
            for _, child in ipairs({snapMenu:GetChildren()}) do child:Hide(); child:SetParent(nil) end
            for _, tex in ipairs({snapMenu:GetRegions()}) do if tex.Hide then tex:Hide() end end
        end
        snapMenu = snapMenu or CreateFrame("Frame", nil, UM.unlockFrame)
        snapMenu:SetFrameStrata("FULLSCREEN_DIALOG")
        snapMenu:SetFrameLevel(250)
        snapMenu:SetClampedToScreen(true)
        snapMenu:SetSize(DD_W, 10)
        snapMenu:SetPoint("TOPLEFT", mover, "TOPRIGHT", 4, 0)

        -- Background + border
        local menuBg = snapMenu:CreateTexture(nil, "BACKGROUND")
        menuBg:SetAllPoints()
        menuBg:SetColorTexture(0.075, 0.113, 0.141, 0.95)
        EllesmereUI.MakeBorder(snapMenu, 1, 1, 1, 0.20)

        local ITEM_H = 24
        local yOff = -4
        local items = {}

        -- Title: "Snap Target"
        local titleLbl = snapMenu:CreateFontString(nil, "OVERLAY")
        titleLbl:SetFont(FONT_PATH, 10, "OUTLINE, SLUG")
        titleLbl:SetTextColor(1, 1, 1, 0.40)
        titleLbl:SetJustifyH("LEFT")
        titleLbl:SetPoint("TOPLEFT", snapMenu, "TOPLEFT", 10, yOff - 4)
        titleLbl:SetText(EllesmereUI.L("Snap Target"))
        yOff = yOff - 18

        -- Title divider
        local titleDiv = snapMenu:CreateTexture(nil, "ARTWORK")
        titleDiv:SetHeight(1)
        titleDiv:SetColorTexture(1, 1, 1, 0.10)
        titleDiv:SetPoint("TOPLEFT", snapMenu, "TOPLEFT", 1, yOff - 2)
        titleDiv:SetPoint("TOPRIGHT", snapMenu, "TOPRIGHT", -1, yOff - 2)
        yOff = yOff - 5

        local function MakeItem(parent, text, onClick, isSelected)
            local item = CreateFrame("Button", nil, parent)
            item:SetHeight(ITEM_H)
            item:SetPoint("TOPLEFT", parent, "TOPLEFT", 1, yOff)
            item:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -1, yOff)
            item:SetFrameLevel(parent:GetFrameLevel() + 2)
            item:RegisterForClicks("AnyUp")
            local hl = item:CreateTexture(nil, "ARTWORK")
            hl:SetAllPoints()
            hl:SetColorTexture(1, 1, 1, 0)
            local lbl = item:CreateFontString(nil, "OVERLAY")
            lbl:SetFont(FONT_PATH, 11, "OUTLINE, SLUG")
            lbl:SetTextColor(0.75, 0.75, 0.75, 0.9)
            lbl:SetJustifyH("LEFT")
            lbl:SetPoint("LEFT", item, "LEFT", 10, 0)
            lbl:SetText(EllesmereUI.L(text))
            if isSelected then
                hl:SetColorTexture(1, 1, 1, 0.04)
                lbl:SetTextColor(1, 1, 1, 1)
            end
            item:SetScript("OnEnter", function()
                hl:SetColorTexture(1, 1, 1, 0.08)
                lbl:SetTextColor(1, 1, 1, 1)
            end)
            item:SetScript("OnLeave", function()
                if isSelected then
                    hl:SetColorTexture(1, 1, 1, 0.04)
                else
                    hl:SetColorTexture(1, 1, 1, 0)
                end
                lbl:SetTextColor(0.75, 0.75, 0.75, 0.9)
            end)
            item:SetScript("OnClick", function()
                onClick()
                CloseSnapMenu()
                UpdateSnapLabel()
            end)
            items[#items + 1] = item
            yOff = yOff - ITEM_H
            return item
        end

        local curTarget = mover._snapTarget

        MakeItem(snapMenu, "All Elements", function()
            mover._snapTarget = nil
        end, not curTarget)

        -- None (per-mover snap disable)
        MakeItem(snapMenu, "None", function()
            mover._snapTarget = "_disable_"
        end, curTarget == "_disable_")

        -- Divider before element groups
        local div = snapMenu:CreateTexture(nil, "ARTWORK")
        div:SetHeight(1)
        div:SetColorTexture(1, 1, 1, 0.10)
        div:SetPoint("TOPLEFT", snapMenu, "TOPLEFT", 1, yOff - 4)
        div:SetPoint("TOPRIGHT", snapMenu, "TOPRIGHT", -1, yOff - 4)
        yOff = yOff - 9

        -- Registered element groups (Unit Frames, Action Bars, Resource Bars, etc.)
        RebuildRegisteredOrder()
        local regGroups = {}   -- { groupName = { {key,label}, ... } }
        local regGroupOrder = {} -- preserve first-seen order
        for _, rk in ipairs(registeredOrder) do
            if rk ~= barKey and movers[rk] and movers[rk]:IsShown() then
                local elem = registeredElements[rk]
                local gName = elem.group or "Other"
                if not regGroups[gName] then
                    regGroups[gName] = {}
                    regGroupOrder[#regGroupOrder + 1] = gName
                end
                regGroups[gName][#regGroups[gName] + 1] = { key = rk, label = elem.label or rk }
            end
        end
        -- Add visibility-only bars (MicroBar, BagBar) to "Other" group
        for _, bk in ipairs(ALL_BAR_ORDER) do
            if GetVisibilityOnly()[bk] and bk ~= barKey and movers[bk] and movers[bk]:IsShown() then
                if not regGroups["Other"] then
                    regGroups["Other"] = {}
                    regGroupOrder[#regGroupOrder + 1] = "Other"
                end
                regGroups["Other"][#regGroups["Other"] + 1] = { key = bk, label = UM.GetBarLabel(bk) }
            end
        end
        wipe(regSubMenus)
        for _, gName in ipairs(regGroupOrder) do
            local gElems = regGroups[gName]
            local rgItem = CreateFrame("Button", nil, snapMenu)
            rgItem:SetHeight(ITEM_H)
            rgItem:SetPoint("TOPLEFT", snapMenu, "TOPLEFT", 1, yOff)
            rgItem:SetPoint("TOPRIGHT", snapMenu, "TOPRIGHT", -1, yOff)
            rgItem:SetFrameLevel(snapMenu:GetFrameLevel() + 2)
            rgItem:RegisterForClicks("AnyUp")
            local rgHl = rgItem:CreateTexture(nil, "ARTWORK")
            rgHl:SetAllPoints()
            rgHl:SetColorTexture(1, 1, 1, 0)
            local rgLbl = rgItem:CreateFontString(nil, "OVERLAY")
            rgLbl:SetFont(FONT_PATH, 11, "OUTLINE, SLUG")
            rgLbl:SetTextColor(0.75, 0.75, 0.75, 0.9)
            rgLbl:SetJustifyH("LEFT")
            rgLbl:SetPoint("LEFT", rgItem, "LEFT", 10, 0)
            rgLbl:SetText(EllesmereUI.L(gName))
            local rgArrow = rgItem:CreateTexture(nil, "ARTWORK")
            rgArrow:SetSize(10, 10)
            rgArrow:SetPoint("RIGHT", rgItem, "RIGHT", -8, 0)
            rgArrow:SetTexture(ARROW_RIGHT_ICON)
            rgArrow:SetAlpha(0.7)
            yOff = yOff - ITEM_H

            local regSub
            local function ShowRegSub()
                -- Close any other open leaf sub-menus first
                for otherName, rs in pairs(regSubMenus) do
                    if otherName ~= gName and rs and rs:IsShown() then rs:Hide() end
                end
                if regSub then
                    for _, child in ipairs({regSub:GetChildren()}) do child:Hide(); child:SetParent(nil) end
                    for _, tex in ipairs({regSub:GetRegions()}) do if tex.Hide then tex:Hide() end end
                end
                regSub = regSub or CreateFrame("Frame", nil, UM.unlockFrame)
                regSub:SetFrameStrata("FULLSCREEN_DIALOG")
                regSub:SetFrameLevel(260)
                regSub:SetClampedToScreen(true)
                regSub:SetSize(DD_W, 10)
                regSub:SetPoint("TOPLEFT", rgItem, "TOPRIGHT", 2, 0)
                local rsBg = regSub:CreateTexture(nil, "BACKGROUND")
                rsBg:SetAllPoints()
                rsBg:SetColorTexture(0.075, 0.113, 0.141, 0.95)
                EllesmereUI.MakeBorder(regSub, 1, 1, 1, 0.20)
                local rsYOff = -4
                for _, eInfo in ipairs(gElems) do
                    local ek, eLbl = eInfo.key, eInfo.label
                    local isSel = (curTarget == ek)
                    local si = CreateFrame("Button", nil, regSub)
                    si:SetHeight(ITEM_H)
                    si:SetPoint("TOPLEFT", regSub, "TOPLEFT", 1, rsYOff)
                    si:SetPoint("TOPRIGHT", regSub, "TOPRIGHT", -1, rsYOff)
                    si:SetFrameLevel(regSub:GetFrameLevel() + 2)
                    si:RegisterForClicks("AnyUp")
                    local sHl = si:CreateTexture(nil, "ARTWORK")
                    sHl:SetAllPoints()
                    sHl:SetColorTexture(1, 1, 1, isSel and 0.04 or 0)
                    local sLbl = si:CreateFontString(nil, "OVERLAY")
                    sLbl:SetFont(FONT_PATH, 11, "OUTLINE, SLUG")
                    sLbl:SetTextColor(0.75, 0.75, 0.75, 0.9)
                    sLbl:SetJustifyH("LEFT")
                    sLbl:SetPoint("LEFT", si, "LEFT", 10, 0)
                    sLbl:SetText(EllesmereUI.L(eLbl))
                    if isSel then sLbl:SetTextColor(1, 1, 1, 1) end
                    si:SetScript("OnEnter", function()
                        sHl:SetColorTexture(1, 1, 1, 0.08)
                        sLbl:SetTextColor(1, 1, 1, 1)
                    end)
                    si:SetScript("OnLeave", function()
                        sHl:SetColorTexture(1, 1, 1, isSel and 0.04 or 0)
                        sLbl:SetTextColor(0.75, 0.75, 0.75, 0.9)
                    end)
                    si:SetScript("OnClick", function()
                        mover._snapTarget = ek
                        CloseSnapMenu()
                        UpdateSnapLabel()
                    end)
                    rsYOff = rsYOff - ITEM_H
                end
                regSub:SetHeight(-rsYOff + 4)
                -- Width: fit the widest label + left padding (10) + right spacing (10) + border (2)
                local rsMaxW = DD_W
                for _, eInfo in ipairs(gElems) do
                    local tw = (EllesmereUI.MeasureText and EllesmereUI.MeasureText(eInfo.label, FONT_PATH, 11)) or 0
                    local needed = 10 + tw + 10 + 2
                    if needed > rsMaxW then rsMaxW = needed end
                end
                regSub:SetWidth(rsMaxW)
                regSub:EnableMouse(true)
                regSub:SetScript("OnLeave", function(self)
                    C_Timer.After(0.05, function()
                        if self:IsShown() and not self:IsMouseOver() and not rgItem:IsMouseOver() then
                            self:Hide()
                        end
                    end)
                end)
                regSub:Show()
                regSubMenus[gName] = regSub
            end

            rgItem:SetScript("OnEnter", function()
                rgHl:SetColorTexture(1, 1, 1, 0.08)
                rgLbl:SetTextColor(1, 1, 1, 1)
                rgArrow:SetAlpha(0.9)
                ShowRegSub()
            end)
            rgItem:SetScript("OnLeave", function()
                rgHl:SetColorTexture(1, 1, 1, 0)
                rgLbl:SetTextColor(0.75, 0.75, 0.75, 0.9)
                rgArrow:SetAlpha(0.5)
                C_Timer.After(0.05, function()
                    local rs = regSubMenus[gName]
                    if rs and rs:IsShown() and not rs:IsMouseOver() and not rgItem:IsMouseOver() then
                        rs:Hide()
                    end
                end)
            end)
        end

        snapMenu:SetHeight(-yOff + 4)
        snapMenu:Show()
    end

    -- Click-catcher: full-screen invisible frame that closes the menu when clicking elsewhere
    local snapClickCatcher
    local function ShowClickCatcher()
        if not snapClickCatcher then
            snapClickCatcher = CreateFrame("Button", nil, UM.unlockFrame)
            snapClickCatcher:SetFrameStrata("FULLSCREEN_DIALOG")
            snapClickCatcher:SetFrameLevel(249)  -- just below snapMenu (250)
            snapClickCatcher:SetAllPoints(UIParent)
            snapClickCatcher:RegisterForClicks("AnyUp")
            snapClickCatcher:SetScript("OnClick", function()
                CloseSnapMenu()
            end)
        end
        snapClickCatcher:Show()
    end
    local function HideClickCatcher()
        if snapClickCatcher then snapClickCatcher:Hide() end
    end

    local origCloseSnapMenu = CloseSnapMenu
    CloseSnapMenu = function()
        origCloseSnapMenu()
        HideClickCatcher()
        mover._menuOpen = false
    end

    snapDD:SetScript("OnClick", function()
        -- Block opening when global snap is disabled
        if not UM.snapEnabled then return end
        if snapMenu and snapMenu:IsShown() then
            CloseSnapMenu()
        else
            mover._menuOpen = true
            BuildSnapMenu()
            ShowClickCatcher()
        end
    end)

    -- Also close menu when dropdown hides (e.g. mover deselected)
    snapDD:SetScript("OnHide", CloseSnapMenu)

    ---------------------------------------------------------------------------
    --  Layout: cog flush with mover top-right (flips below if near screen top)
    ---------------------------------------------------------------------------
    local TOOLBAR_FLIP_THRESHOLD = 50  -- px from screen top to flip toolbar below

    local function IsNearScreenTop()
        local mTop = mover:GetTop()
        if not mTop then return false end
        local uiS = UIParent:GetEffectiveScale()
        local mS = mover:GetEffectiveScale()
        local screenTop = UIParent:GetHeight()
        local moverTopUI = mTop * mS / uiS
        return (screenTop - moverTopUI) < TOOLBAR_FLIP_THRESHOLD
    end
    mover._isNearScreenTop = IsNearScreenTop

    local function AnchorToolbarToMover()
        cogBtn:ClearAllPoints()
        cogBtn:SetPoint("TOPRIGHT", mover, "TOPRIGHT", -1, -1)
    end
    mover._anchorToolbar = AnchorToolbarToMover
    AnchorToolbarToMover()

    -- Hide orientation button for visibility-only bars or bars without layout support
    local isVisOnly = (GetVisibilityOnly()[barKey]) or not (BAR_LOOKUP and BAR_LOOKUP[barKey])

    mover._cogBtn = cogBtn
    mover._actionBtns = { cogBtn }

    -- Open snap menu helper (called from right-click handler)
    mover._openSnapMenu = function()
        mover._menuOpen = true
        BuildSnapMenu()
        ShowClickCatcher()
    end
    mover._isVisOnly = isVisOnly
    mover._snapTarget = nil  -- per-mover snap target (nil = auto)
    mover._updateSnapLabel = UpdateSnapLabel
    RefreshSnapDDState()  -- apply initial grayed-out state if snap is disabled

    ---------------------------------------------------------------------------
    --  Cog settings menu (Reset / Center / Orientation)
    ---------------------------------------------------------------------------
    local cogMenu
    local cogClickCatcher

    local function CloseCogMenu()
        if cogMenu then cogMenu:Hide() end
        if mover._cogEdgeSub then mover._cogEdgeSub:Hide() end
        if cogClickCatcher then cogClickCatcher:Hide() end
        mover._menuOpen = false
        mover._syncCogPos = nil
        mover._syncCogSize = nil
    end

    local function BuildCogMenu()
        if cogMenu then
            for _, child in ipairs({cogMenu:GetChildren()}) do child:Hide(); child:SetParent(nil) end
            for _, tex in ipairs({cogMenu:GetRegions()}) do if tex.Hide then tex:Hide() end end
        end
        if mover._cogEdgeSub then mover._cogEdgeSub:Hide() end
        cogMenu = cogMenu or CreateFrame("Frame", nil, UM.unlockFrame)
        cogMenu:SetFrameStrata("FULLSCREEN_DIALOG")
        cogMenu:SetFrameLevel(250)
        cogMenu:SetClampedToScreen(true)
        cogMenu:SetSize(DD_W + 60, 10)
        cogMenu:SetPoint("TOPLEFT", cogBtn, "BOTTOMLEFT", 0, -2)
        cogMenu:EnableMouse(true)

        local menuBg = cogMenu:CreateTexture(nil, "BACKGROUND")
        menuBg:SetAllPoints()
        menuBg:SetColorTexture(0.075, 0.113, 0.141, 0.95)
        EllesmereUI.MakeBorder(cogMenu, 1, 1, 1, 0.20)

        local ITEM_H = 24
        local yOff = -4

        -- Arrow-key hint at the very top (centered). Shown for every element since
        -- arrow keys nudge the selected element 1px in any direction.
        do
            local hintFS = cogMenu:CreateFontString(nil, "OVERLAY")
            EllesmereUI.PrimeFontShadow(hintFS, true)
            hintFS:SetFont(FONT_PATH, 10, "")
            hintFS:SetTextColor(0.7, 0.7, 0.7, 0.85)
            hintFS:SetJustifyH("CENTER")
            hintFS:SetWordWrap(true)
            hintFS:SetPoint("TOPLEFT", cogMenu, "TOPLEFT", 8, yOff - 4)
            hintFS:SetPoint("TOPRIGHT", cogMenu, "TOPRIGHT", -8, yOff - 4)
            hintFS:SetText(EllesmereUI.L("Use arrow keys to move selected element 1px any direction")
                .. ". " .. EllesmereUI.L("Shift+Right Click to temporarily hide overlay"))
            local hintH = hintFS:GetStringHeight()
            if not hintH or hintH < 1 then hintH = 28 end
            yOff = yOff - (hintH + 10)

            -- Divider below the hint
            local hintDiv = cogMenu:CreateTexture(nil, "ARTWORK")
            local hintDivPx = PP and PP.mult or 1
            hintDiv:SetHeight(hintDivPx)
            if hintDiv.SetSnapToPixelGrid then hintDiv:SetSnapToPixelGrid(false); hintDiv:SetTexelSnappingBias(0) end
            hintDiv:SetColorTexture(1, 1, 1, 0.10)
            hintDiv:SetPoint("TOPLEFT", cogMenu, "TOPLEFT", 1, yOff - 4)
            hintDiv:SetPoint("TOPRIGHT", cogMenu, "TOPRIGHT", -1, yOff - 4)
            yOff = yOff - 9
        end

        -- "Element Options" -- navigate to this element's settings page (top of menu)
        local settingsMapping = EllesmereUI._ELEMENT_SETTINGS_MAP[barKey]
        -- Cooldown Manager bars use dynamic per-bar keys ("CDM_<key>" / "TBB_<idx>"),
        -- so they miss the exact lookup; resolve them to their shared tab entry by prefix.
        if not settingsMapping then
            if barKey:sub(1, 4) == "CDM_" then
                settingsMapping = EllesmereUI._ELEMENT_SETTINGS_MAP["CDM_"]
            elseif barKey:sub(1, 4) == "TBB_" or barKey:sub(1, 5) == "TBBG_" then
                settingsMapping = EllesmereUI._ELEMENT_SETTINGS_MAP["TBB_"]
            elseif barKey:sub(1, 7) == "EDM_Win" then
                settingsMapping = EllesmereUI._ELEMENT_SETTINGS_MAP["EDM_Win"]
            end
        end
        -- Queue Status is a Blizzard-owned element with no EUI settings page; its
        -- "Element Options" opens Blizzard Edit Mode instead of navigating to a tab
        -- (the same action as clicking a Blizzard Edit Mode overlay in unlock mode).
        local opensEditMode = (barKey == "QueueStatus")
        if settingsMapping or opensEditMode then
            local optItem = CreateFrame("Button", nil, cogMenu)
            optItem:SetHeight(ITEM_H)
            optItem:SetPoint("TOPLEFT", cogMenu, "TOPLEFT", 1, yOff)
            optItem:SetPoint("TOPRIGHT", cogMenu, "TOPRIGHT", -1, yOff)
            optItem:SetFrameLevel(cogMenu:GetFrameLevel() + 2)
            optItem:RegisterForClicks("AnyUp")
            local optHl = optItem:CreateTexture(nil, "ARTWORK")
            optHl:SetAllPoints()
            optHl:SetColorTexture(1, 1, 1, 0)
            local optLbl = optItem:CreateFontString(nil, "OVERLAY")
            EllesmereUI.PrimeFontShadow(optLbl, true)
            optLbl:SetFont(FONT_PATH, 11, "")
            optLbl:SetTextColor(0.75, 0.75, 0.75, 0.9)
            optLbl:SetJustifyH("LEFT")
            optLbl:SetPoint("LEFT", optItem, "LEFT", 10, 0)
            optLbl:SetText(EllesmereUI.L("Element Options"))
            optItem:SetScript("OnEnter", function()
                optHl:SetColorTexture(1, 1, 1, 0.08)
                optLbl:SetTextColor(1, 1, 1, 1)
            end)
            optItem:SetScript("OnLeave", function()
                optHl:SetColorTexture(1, 1, 1, 0)
                optLbl:SetTextColor(0.75, 0.75, 0.75, 0.9)
            end)
            optItem:SetScript("OnClick", function()
                CloseCogMenu()
                if opensEditMode then
                    -- Open Blizzard Edit Mode, exactly as the Blizz-owned overlays do.
                    if InCombatLockdown() then return end
                    if EditModeManagerFrame then
                        ns.RequestClose(false, function()
                            ShowUIPanel(EditModeManagerFrame)
                        end)
                    end
                else
                    ns.RequestClose(true, function()
                        EllesmereUI:NavigateToElementSettings(
                            settingsMapping.module,
                            settingsMapping.page,
                            settingsMapping.sectionName,
                            settingsMapping.preSelectFn,
                            settingsMapping.highlightText
                        )
                    end)
                end
            end)
            yOff = yOff - ITEM_H

            -- Divider after Element Options
            local optDiv = cogMenu:CreateTexture(nil, "ARTWORK")
            local optDivPx = PP and PP.mult or 1
            optDiv:SetHeight(optDivPx)
            if optDiv.SetSnapToPixelGrid then optDiv:SetSnapToPixelGrid(false); optDiv:SetTexelSnappingBias(0) end
            optDiv:SetColorTexture(1, 1, 1, 0.10)
            optDiv:SetPoint("TOPLEFT", cogMenu, "TOPLEFT", 1, yOff - 4)
            optDiv:SetPoint("TOPRIGHT", cogMenu, "TOPRIGHT", -1, yOff - 4)
            yOff = yOff - 9
        end

        -- Width / Height input fields (only for resizable elements)
        -- CDM bars skip width/height here; size is driven by icon count/size in the options panel
        local isCDMBar = barKey:sub(1, 4) == "CDM_"
        if canResize and elem then
            local INPUT_W = 50
            local INPUT_H = 18
            local ROW_H = 22
            local curW, curH = 0, 0
            if elem.getSize then curW, curH = elem.getSize(barKey) end

            -- Create both boxes upfront so each OnEnterPressed can update the other
            local wBox, hBox

            local function MakeSizeRow(axis, initVal)
                local rowFrame = CreateFrame("Frame", nil, cogMenu)
                rowFrame:SetHeight(ROW_H)
                rowFrame:SetPoint("TOPLEFT", cogMenu, "TOPLEFT", 1, yOff)
                rowFrame:SetPoint("TOPRIGHT", cogMenu, "TOPRIGHT", -1, yOff)
                rowFrame:SetFrameLevel(cogMenu:GetFrameLevel() + 2)

                local lbl = rowFrame:CreateFontString(nil, "OVERLAY")
                EllesmereUI.PrimeFontShadow(lbl, true)
                lbl:SetFont(FONT_PATH, 11, "")
                lbl:SetTextColor(0.75, 0.75, 0.75, 0.9)
                lbl:SetJustifyH("LEFT")
                lbl:SetPoint("LEFT", rowFrame, "LEFT", 10, 0)
                lbl:SetText((EllesmereUI.L(axis)) or axis)

                local box = CreateFrame("EditBox", nil, rowFrame)
                box:SetSize(INPUT_W, INPUT_H)
                box:SetPoint("RIGHT", rowFrame, "RIGHT", -8, 0)
                box:SetFrameLevel(cogMenu:GetFrameLevel() + 3)
                box:SetFont(FONT_PATH, 10, "")
                box:SetTextColor(1, 1, 1, 0.9)
                box:SetJustifyH("CENTER")
                local boxBg = box:CreateTexture(nil, "BACKGROUND")
                boxBg:SetAllPoints()
                boxBg:SetColorTexture(0, 0, 0, 0.4)
                box:SetAutoFocus(false)
                box:SetNumeric(true)
                box:SetMaxLetters(5)
                -- Display the element's native size (UI coords), matching getSize/setWidth
                -- and the options sliders -- physical pixels (ToPixels) diverge from the actual setting at non-1.0 UI scales.
                box:SetNumber(floor((initVal or 0) + 0.5))

                -- Disable if this element is width/height matched
                local isWidth = (axis == "Width")
                local matchTarget = isWidth and EllesmereUI.GetWidthMatchTarget(barKey) or (not isWidth and EllesmereUI.GetHeightMatchTarget(barKey))
                if matchTarget then
                    box:Disable()
                    box:SetTextColor(0.4, 0.4, 0.4, 0.7)
                    local targetName = UM.GetBarLabel(matchTarget) or matchTarget
                    box:SetScript("OnEnter", function()
                        EllesmereUI.ShowWidgetTooltip(box,
                            axis .. " matched to " .. targetName .. ". Unmatch to edit.")
                    end)
                    box:SetScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
                end

                box:SetScript("OnEnterPressed", function(self)
                    -- Value is in the element's native UI coords (no physical-pixel conversion)
                    local val = math.max(1, math.floor(self:GetNumber() + 0.5))
                    local sb = UM.GetBarFrame(barKey)
                    local savedAlpha = sb and EllesmereUI._GetFFD(sb).restoreAlpha
                    if sb and not savedAlpha then EllesmereUI._UnlockSetBarAlpha(sb, 0) end
                    if axis == "Width" then
                        if elem.setWidth then elem.setWidth(barKey, val) end
                        for childKey, targetKey in pairs(MatchH.GetWidthMatchDB() or {}) do
                            if targetKey == barKey then MatchH.ApplyWidthMatch(childKey, barKey) end
                        end
                    else
                        if elem.setHeight then elem.setHeight(barKey, val) end
                        for childKey, targetKey in pairs(MatchH.GetHeightMatchDB() or {}) do
                            if targetKey == barKey then MatchH.ApplyHeightMatch(childKey, barKey) end
                        end
                    end
                    UM.hasChanges = true
                    self:ClearFocus()
                    EllesmereUI.RecenterBarAnchor(barKey)
                    if sb and not savedAlpha then
                        C_Timer.After(0, function() EllesmereUI._UnlockSetBarAlpha(sb, 1) end)
                    end
                    local bm = movers[barKey]
                    if bm then bm:SyncSize() end
                    for childKey, _ in pairs(movers) do
                        if movers[childKey] and movers[childKey].SyncSize then
                            local wm = MatchH.GetWidthMatchInfo(childKey)
                            local hm = MatchH.GetHeightMatchInfo(childKey)
                            if wm == barKey or hm == barKey then
                                movers[childKey]:SyncSize()
                            end
                        end
                    end
                    -- Refresh both input boxes to reflect actual post-resize dimensions
                    if elem.getSize then
                        local nw, nh = elem.getSize(barKey)
                        if wBox then wBox:SetNumber(floor((nw or 0) + 0.5)) end
                        if hBox then hBox:SetNumber(floor((nh or 0) + 0.5)) end
                    end
                    UM.PropagateAnchorChain(barKey)
                end)
                box:SetScript("OnEscapePressed", function(self)
                    self:ClearFocus()
                    if elem.getSize then
                        local w2, h2 = elem.getSize(barKey)
                        self:SetNumber(floor((axis == "Width" and (w2 or 0) or (h2 or 0)) + 0.5))
                    end
                end)
                yOff = yOff - ROW_H
                return box
            end

            -- Special override sessions never offer the direct size inputs: element
            -- size is not an override aspect (only the wm/hm size companions are),
            -- so a resize here would write the SHARED module setting mid-session
            -- while looking like a per-group edit. Users resize from the options panel instead.
            if not isCDMBar and not EllesmereUI._specialUnlockGroup then
                wBox = MakeSizeRow("Width",  curW)
                hBox = MakeSizeRow("Height", curH)
                -- Re-read both boxes after an Extra Width / Height commit.
                mover._syncCogSize = function()
                    if not elem.getSize then return end
                    local nw, nh = elem.getSize(barKey)
                    if wBox then wBox:SetNumber(floor((nw or 0) + 0.5)) end
                    if hBox then hBox:SetNumber(floor((nh or 0) + 0.5)) end
                end
            end

            -- X Position / Y Position rows (screen coords from center)
            do
                local sw = UIParent:GetWidth()
                local sh = UIParent:GetHeight()
                -- Current value of an axis as a physical-pixel COUNT, read from the
                -- bar's LIVE geometry. Displaying pixel counts (not raw UIParent
                -- units) makes +1 in the box equal exactly one physical pixel, i.e.
                -- one arrow-key nudge; PP.mult is only 1 at pixel-perfect UI scale.
                local function AxisToPx(ax)
                    local PPi = EllesmereUI and EllesmereUI.PP
                    if not PPi or not PPi.ToPixels then return nil end
                    -- STORED value first for unanchored CENTER/CENTER elements (same
                    -- reasoning as UpdateCoordText): the box must echo the user's own
                    -- typed value back; a live-derived center is off by half a pixel for odd-pixel-dimension frames.
                    local aiX = GetAnchorInfo(barKey)
                    if not (aiX and aiX.target) then
                        local pos = pendingPositions[barKey]
                        if type(pos) ~= "table" or pos._anchored or not pos.point then
                            local elemX = registeredElements[barKey]
                            pos = elemX and elemX.loadPosition and elemX.loadPosition(barKey) or nil
                            if not pos then pos = LoadBarPosition(barKey) end
                        end
                        if type(pos) == "table" and pos.point == "CENTER"
                           and (pos.relPoint or "CENTER") == "CENTER"
                           and pos.x and pos.y then
                            -- Parity-aware like the live conversion below (odd dims store a half-pixel center).
                            local sb = UM.GetBarFrame(barKey)
                            local c2pS = PPi.CenterToPixels
                            if ax == "X" then
                                if c2pS and sb then return c2pS(pos.x, sb:GetWidth(), sb:GetEffectiveScale()) end
                                return PPi.ToPixels(pos.x)
                            end
                            if c2pS and sb then return c2pS(pos.y, sb:GetHeight(), sb:GetEffectiveScale()) end
                            return PPi.ToPixels(pos.y)
                        end
                    end
                    local b = UM.GetBarFrame(barKey)
                    if not b then return nil end
                    local bL, bR = b:GetLeft(), b:GetRight()
                    local bT, bB = b:GetTop(), b:GetBottom()
                    if not (bL and bR and bT and bB) then return nil end
                    local ratio = b:GetEffectiveScale() / UIParent:GetEffectiveScale()
                    -- Parity-aware live conversion: odd-pixel dims rest their
                    -- center on a half pixel; plain ToPixels reads that back
                    -- one high, so deltas computed from it move the frame to
                    -- the -0.5 side (1px off the stored-value convention).
                    local c2p = PPi.CenterToPixels
                    if ax == "X" then
                        local liveCX = ((bL + bR) * 0.5 * ratio) - sw * 0.5
                        if c2p then return c2p(liveCX, b:GetWidth(), b:GetEffectiveScale()) end
                        return PPi.ToPixels(liveCX)
                    end
                    local liveCY = ((bT + bB) * 0.5 * ratio) - sh * 0.5
                    if c2p then return c2p(liveCY, b:GetHeight(), b:GetEffectiveScale()) end
                    return PPi.ToPixels(liveCY)
                end

                local function MakePosRow(axis, initVal)
                    local rowFrame = CreateFrame("Frame", nil, cogMenu)
                    rowFrame:SetHeight(ROW_H)
                    rowFrame:SetPoint("TOPLEFT", cogMenu, "TOPLEFT", 1, yOff)
                    rowFrame:SetPoint("TOPRIGHT", cogMenu, "TOPRIGHT", -1, yOff)
                    rowFrame:SetFrameLevel(cogMenu:GetFrameLevel() + 2)

                    local lbl = rowFrame:CreateFontString(nil, "OVERLAY")
                    EllesmereUI.PrimeFontShadow(lbl, true)
                    lbl:SetFont(FONT_PATH, 11, "")
                    lbl:SetTextColor(0.75, 0.75, 0.75, 0.9)
                    lbl:SetJustifyH("LEFT")
                    lbl:SetPoint("LEFT", rowFrame, "LEFT", 10, 0)
                    lbl:SetText(axis == "X" and EllesmereUI.L("X Position") or EllesmereUI.L("Y Position"))

                    local box = CreateFrame("EditBox", nil, rowFrame)
                    box:SetSize(INPUT_W, INPUT_H)
                    box:SetPoint("RIGHT", rowFrame, "RIGHT", -8, 0)
                    box:SetFrameLevel(cogMenu:GetFrameLevel() + 3)
                    box:SetFont(FONT_PATH, 10, "")
                    box:SetTextColor(1, 1, 1, 0.9)
                    box:SetJustifyH("CENTER")
                    local boxBg = box:CreateTexture(nil, "BACKGROUND")
                    boxBg:SetAllPoints()
                    boxBg:SetColorTexture(0, 0, 0, 0.4)
                    box:SetAutoFocus(false)
                    box:SetNumeric(false)
                    box:SetMaxLetters(6)
                    box:SetText(tostring(initVal))

                    box:SetScript("OnEnterPressed", function(self)
                        local val = tonumber(self:GetText())
                        self:ClearFocus()
                        if not val then return end
                        local PPi = EllesmereUI and EllesmereUI.PP
                        if InCombatLockdown() or not PPi then return end
                        -- Current value from LIVE geometry (never the stale moverCX).
                        local curPx = AxisToPx(axis)
                        if not curPx then return end
                        local deltaPx = val - curPx
                        if deltaPx ~= 0 then
                            -- One physical pixel == PP.mult UIParent units. Apply an
                            -- exact integer-pixel delta through the SAME primitive the
                            -- arrow keys use, so anchored/unanchored handling, the
                            -- pending-save capture, and the mover-center re-sync all
                            -- match the proven path: no second snap, no lost move.
                            local stepUnits = PPi.FromPixels(deltaPx)
                            if axis == "X" then
                                EllesmereUI._unlockNudge(stepUnits, 0, mover, true)
                            else
                                EllesmereUI._unlockNudge(0, stepUnits, mover, true)
                            end
                        end
                        if mover.ReanchorToBar then mover:ReanchorToBar() end
                        -- Re-sync the text to where the bar ACTUALLY landed so it can
                        -- never snap back to the old number.
                        local landed = AxisToPx(axis)
                        if landed then self:SetText(tostring(landed)) end
                    end)
                    box:SetScript("OnEscapePressed", function(self)
                        self:ClearFocus()
                        -- Discard typed text; show the bar's actual current value.
                        local cur = AxisToPx(axis)
                        self:SetText(tostring(cur or initVal))
                    end)
                    yOff = yOff - ROW_H
                    return box
                end

                local xBox = MakePosRow("X", AxisToPx("X") or 0)
                local yBox = MakePosRow("Y", AxisToPx("Y") or 0)
                -- Let arrow-key nudges (while the cog is open) refresh these boxes
                -- so they stay in lockstep with the element and the floating overlay.
                mover._syncCogPos = function()
                    if xBox then local px = AxisToPx("X"); if px then xBox:SetText(tostring(px)) end end
                    if yBox then local py = AxisToPx("Y"); if py then yBox:SetText(tostring(py)) end end
                end
            end

            -- Divider after size/position inputs
            local sizeDiv = cogMenu:CreateTexture(nil, "ARTWORK")
            local sizeDivPx = PP and PP.mult or 1
            sizeDiv:SetHeight(sizeDivPx)
            if sizeDiv.SetSnapToPixelGrid then sizeDiv:SetSnapToPixelGrid(false); sizeDiv:SetTexelSnappingBias(0) end
            sizeDiv:SetColorTexture(1, 1, 1, 0.10)
            sizeDiv:SetPoint("TOPLEFT", cogMenu, "TOPLEFT", 1, yOff - 4)
            sizeDiv:SetPoint("TOPRIGHT", cogMenu, "TOPRIGHT", -1, yOff - 4)
            yOff = yOff - 9
        end

        -- Extra Width / Extra Height (matched elements only): whole physical pixels
        -- added to the size the match gives, typed like the Offset X/Y rows below
        -- (Enter applies, Escape reverts). Not gated on canResize: CDM bars and
        -- tracking bars are sized by their matches too. Hidden while the look
        -- fixes the size or the element refuses matches right now.
        do
            local wT = MatchH.GetWidthMatchInfo(barKey)
            local hT = MatchH.GetHeightMatchInfo(barKey)
            if (wT or hT) and not InCombatLockdown()
               and not (elem and elem.sizeFixedByLook)
               and not (elem and elem.matchUnavailable and elem.matchUnavailable(barKey)) then
                local XROW_H, XINPUT_W, XINPUT_H = 22, 50, 18
                local function ExtraText(axis)
                    return tostring(EllesmereUI.GetMatchExtra(axis, barKey) or 0)
                end
                local function MakeExtraRow(text, axis)
                    local rowFrame = CreateFrame("Frame", nil, cogMenu)
                    rowFrame:SetHeight(XROW_H)
                    rowFrame:SetPoint("TOPLEFT", cogMenu, "TOPLEFT", 1, yOff)
                    rowFrame:SetPoint("TOPRIGHT", cogMenu, "TOPRIGHT", -1, yOff)
                    rowFrame:SetFrameLevel(cogMenu:GetFrameLevel() + 2)
                    local lbl = rowFrame:CreateFontString(nil, "OVERLAY")
                    EllesmereUI.PrimeFontShadow(lbl, true)
                    lbl:SetFont(FONT_PATH, 11, "")
                    lbl:SetTextColor(0.75, 0.75, 0.75, 0.9)
                    lbl:SetJustifyH("LEFT")
                    lbl:SetWordWrap(false)
                    lbl:SetPoint("LEFT", rowFrame, "LEFT", 10, 0)
                    lbl:SetText(text)
                    local box = CreateFrame("EditBox", nil, rowFrame)
                    box:SetSize(XINPUT_W, XINPUT_H)
                    box:SetPoint("RIGHT", rowFrame, "RIGHT", -8, 0)
                    box:SetFrameLevel(cogMenu:GetFrameLevel() + 3)
                    box:SetFont(FONT_PATH, 10, "")
                    box:SetTextColor(1, 1, 1, 0.9)
                    box:SetJustifyH("CENTER")
                    local boxBg = box:CreateTexture(nil, "BACKGROUND")
                    boxBg:SetAllPoints()
                    boxBg:SetColorTexture(0, 0, 0, 0.4)
                    box:SetAutoFocus(false)
                    box:SetNumeric(false)
                    box:SetMaxLetters(4)
                    box:SetText(ExtraText(axis))
                    -- Enter applies (clamped to -100..100 in the commit), Escape
                    -- reverts; the box then re-reads the store, so it only ever
                    -- shows a value that landed.
                    box:SetScript("OnEnterPressed", function(self)
                        self:ClearFocus()
                        local val = tonumber(self:GetText())
                        if val and not InCombatLockdown() then
                            MatchH.CommitMatchExtra(axis, barKey, val)
                            -- An anchored element may have moved with its new size.
                            if mover._syncCogPos then mover._syncCogPos() end
                            if mover._syncCogSize then mover._syncCogSize() end
                        end
                        self:SetText(ExtraText(axis))
                    end)
                    box:SetScript("OnEscapePressed", function(self)
                        self:SetText(ExtraText(axis))
                        self:ClearFocus()
                    end)
                    yOff = yOff - XROW_H
                end
                if wT then MakeExtraRow(EllesmereUI.L("Extra Width"), "w") end
                if hT then MakeExtraRow(EllesmereUI.L("Extra Height"), "h") end
                local xDiv = cogMenu:CreateTexture(nil, "ARTWORK")
                xDiv:SetHeight(PP and PP.mult or 1)
                if xDiv.SetSnapToPixelGrid then xDiv:SetSnapToPixelGrid(false); xDiv:SetTexelSnappingBias(0) end
                xDiv:SetColorTexture(1, 1, 1, 0.10)
                xDiv:SetPoint("TOPLEFT", cogMenu, "TOPLEFT", 1, yOff - 4)
                xDiv:SetPoint("TOPRIGHT", cogMenu, "TOPRIGHT", -1, yOff - 4)
                yOff = yOff - 9
            end
        end

        -- Anchor rows (anchored elements only): the target this element is linked
        -- to, and the offset a drag or a nudge left between the two, typed in
        -- place. Nothing here positions an element differently from a drag: a
        -- typed offset is a nudge by the difference. Rows share the size/position
        -- rows' shape above.
        do
            local aiM = GetAnchorInfo(barKey)
            if aiM and aiM.target and not InCombatLockdown() then
                local AROW_H, AINPUT_W, AINPUT_H = 22, 50, 18
                local tgtName = UM.GetBarLabel(aiM.target) or aiM.target
                local function MakeAnchorRow(text)
                    local rowFrame = CreateFrame("Frame", nil, cogMenu)
                    rowFrame:SetHeight(AROW_H)
                    rowFrame:SetPoint("TOPLEFT", cogMenu, "TOPLEFT", 1, yOff)
                    rowFrame:SetPoint("TOPRIGHT", cogMenu, "TOPRIGHT", -1, yOff)
                    rowFrame:SetFrameLevel(cogMenu:GetFrameLevel() + 2)
                    local lbl = rowFrame:CreateFontString(nil, "OVERLAY")
                    EllesmereUI.PrimeFontShadow(lbl, true)
                    lbl:SetFont(FONT_PATH, 11, "")
                    lbl:SetTextColor(0.75, 0.75, 0.75, 0.9)
                    lbl:SetJustifyH("LEFT")
                    lbl:SetWordWrap(false)
                    lbl:SetPoint("LEFT", rowFrame, "LEFT", 10, 0)
                    lbl:SetText(text)
                    yOff = yOff - AROW_H
                    return rowFrame, lbl
                end
                do
                    local _, lbl = MakeAnchorRow(EllesmereUI.Lf("Anchored to: %1$s", tgtName))
                    lbl:SetTextColor(0.55, 0.55, 0.55, 0.9)
                end
                -- Offset X / Offset Y: typed values, Enter applies, Escape reverts.
                -- Physical pixels in the box, units in the record, like the X/Y
                -- Position boxes (AxisToPx): +1 here is one pixel, one nudge. A typed
                -- value drives the SAME pixel-exact nudge the arrow keys and the X/Y
                -- boxes use, by the difference from the record, so the anchored move,
                -- the pending-save capture and the mover re-sync all follow the proven
                -- path (a position-locked mover refuses it there too); the box then
                -- re-reads the record, so it can never show a number that did not land.
                local PPo = EllesmereUI and EllesmereUI.PP
                local function OffsetPx(key)
                    local a = GetAnchorInfo(barKey)
                    local v = a and a[key] or 0
                    if PPo and PPo.ToPixels then v = PPo.ToPixels(v) end
                    return math.floor(v + 0.5)
                end
                local function OffsetText(key)
                    return tostring(OffsetPx(key))
                end
                local function MakeOffsetRow(text, key)
                    local rowFrame = MakeAnchorRow(text)
                    local box = CreateFrame("EditBox", nil, rowFrame)
                    box:SetSize(AINPUT_W, AINPUT_H)
                    box:SetPoint("RIGHT", rowFrame, "RIGHT", -8, 0)
                    box:SetFrameLevel(cogMenu:GetFrameLevel() + 3)
                    box:SetFont(FONT_PATH, 10, "")
                    box:SetTextColor(1, 1, 1, 0.9)
                    box:SetJustifyH("CENTER")
                    local boxBg = box:CreateTexture(nil, "BACKGROUND")
                    boxBg:SetAllPoints()
                    boxBg:SetColorTexture(0, 0, 0, 0.4)
                    box:SetAutoFocus(false)
                    box:SetNumeric(false)
                    box:SetMaxLetters(6)
                    box:SetText(OffsetText(key))
                    local function Commit(self)
                        local val = tonumber(self:GetText())
                        if val and not InCombatLockdown() and PPo and PPo.FromPixels then
                            local deltaPx = math.floor(val + 0.5) - OffsetPx(key)
                            if deltaPx ~= 0 then
                                local stepUnits = PPo.FromPixels(deltaPx)
                                if key == "offsetX" then
                                    EllesmereUI._unlockNudge(stepUnits, 0, mover, true)
                                else
                                    EllesmereUI._unlockNudge(0, stepUnits, mover, true)
                                end
                                -- The bar just moved: the X/Y Position boxes follow right away.
                                if mover._syncCogPos then mover._syncCogPos() end
                            end
                        end
                        self:SetText(OffsetText(key))
                    end
                    -- Enter applies, Escape reverts; losing focus does neither, like
                    -- the X/Y Position boxes above.
                    box:SetScript("OnEnterPressed", function(self)
                        self:ClearFocus()
                        Commit(self)
                    end)
                    box:SetScript("OnEscapePressed", function(self)
                        self:SetText(OffsetText(key))
                        self:ClearFocus()
                    end)
                    return box
                end
                local oxBox = MakeOffsetRow(EllesmereUI.L("Offset X"), "offsetX")
                local oyBox = MakeOffsetRow(EllesmereUI.L("Offset Y"), "offsetY")
                -- Arrow-key nudges move the offsets underneath: keep these boxes in
                -- lockstep, the same way the X/Y boxes are.
                local prevSync = mover._syncCogPos
                mover._syncCogPos = function()
                    if prevSync then prevSync() end
                    if not oxBox:HasFocus() then oxBox:SetText(OffsetText("offsetX")) end
                    if not oyBox:HasFocus() then oyBox:SetText(OffsetText("offsetY")) end
                end
                local aDiv = cogMenu:CreateTexture(nil, "ARTWORK")
                local aDivPx = PP and PP.mult or 1
                aDiv:SetHeight(aDivPx)
                if aDiv.SetSnapToPixelGrid then aDiv:SetSnapToPixelGrid(false); aDiv:SetTexelSnappingBias(0) end
                aDiv:SetColorTexture(1, 1, 1, 0.10)
                aDiv:SetPoint("TOPLEFT", cogMenu, "TOPLEFT", 1, yOff - 4)
                aDiv:SetPoint("TOPRIGHT", cogMenu, "TOPRIGHT", -1, yOff - 4)
                yOff = yOff - 9
            end
        end
        -- Snap Target: enter pick mode or clear existing target
        local selElemItem = CreateFrame("Button", nil, cogMenu)
        selElemItem:SetHeight(ITEM_H)
        selElemItem:SetPoint("TOPLEFT", cogMenu, "TOPLEFT", 1, yOff)
        selElemItem:SetPoint("TOPRIGHT", cogMenu, "TOPRIGHT", -1, yOff)
        selElemItem:SetFrameLevel(cogMenu:GetFrameLevel() + 2)
        selElemItem:RegisterForClicks("AnyUp")
        local selElemHl = selElemItem:CreateTexture(nil, "ARTWORK")
        selElemHl:SetAllPoints()
        selElemHl:SetColorTexture(1, 1, 1, 0)
        local selElemLbl = selElemItem:CreateFontString(nil, "OVERLAY")
        EllesmereUI.PrimeFontShadow(selElemLbl, true)
        selElemLbl:SetFont(FONT_PATH, 11, "")
        selElemLbl:SetJustifyH("LEFT")
        selElemLbl:SetPoint("LEFT", selElemItem, "LEFT", 10, 0)
        local curTgt = mover._snapTarget
        local hasTarget = curTgt and curTgt ~= "_disable_" and curTgt ~= "_select_"
        if hasTarget then
            local tgtName = UM.GetBarLabel(curTgt) or curTgt
            selElemLbl:SetText(EllesmereUI.Lf("Snap Target: %1$s", "|cFF0CD29D" .. tgtName .. "|r"))
            selElemLbl:SetTextColor(0.75, 0.75, 0.75, 0.9)
        else
            selElemLbl:SetText(EllesmereUI.L("Select Snap Target"))
            selElemLbl:SetTextColor(0.75, 0.75, 0.75, 0.9)
        end
        selElemItem:SetScript("OnEnter", function()
            selElemHl:SetColorTexture(1, 1, 1, 0.08)
            selElemLbl:SetTextColor(1, 1, 1, 1)
        end)
        selElemItem:SetScript("OnLeave", function()
            selElemHl:SetColorTexture(1, 1, 1, 0)
            selElemLbl:SetTextColor(0.75, 0.75, 0.75, 0.9)
        end)
        selElemItem:SetScript("OnClick", function()
            if hasTarget then
                mover._snapTarget = nil
                UpdateSnapLabel()
                CloseCogMenu()
            else
                mover._preSelectTarget = mover._snapTarget
                mover._snapTarget = "_select_"
                UM.selectElementPicker = mover
                FadeOverlayForSelectElement(true)
                UpdateSnapLabel()
                CloseCogMenu()
            end
        end)
        yOff = yOff - ITEM_H

        -- Helper: menu action item
        local function MakeActionItem(text, onClick, hoverFullText)
            local item = CreateFrame("Button", nil, cogMenu)
            item:SetHeight(ITEM_H)
            item:SetPoint("TOPLEFT", cogMenu, "TOPLEFT", 1, yOff)
            item:SetPoint("TOPRIGHT", cogMenu, "TOPRIGHT", -1, yOff)
            item:SetFrameLevel(cogMenu:GetFrameLevel() + 2)
            item:RegisterForClicks("AnyUp")
            local hl = item:CreateTexture(nil, "ARTWORK")
            hl:SetAllPoints()
            hl:SetColorTexture(1, 1, 1, 0)
            local lbl = item:CreateFontString(nil, "OVERLAY")
            EllesmereUI.PrimeFontShadow(lbl, true)
            lbl:SetFont(FONT_PATH, 11, "")
            lbl:SetTextColor(0.75, 0.75, 0.75, 0.9)
            lbl:SetJustifyH("LEFT")
            lbl:SetPoint("LEFT", item, "LEFT", 10, 0)
            -- Cap the label at the row width, ending 5px before the row edge,
            -- so long dynamic labels truncate instead of spilling past the menu.
            lbl:SetPoint("RIGHT", item, "RIGHT", -5, 0)
            lbl:SetWordWrap(false)
            lbl:SetText(EllesmereUI.L(text))
            item:SetScript("OnEnter", function()
                hl:SetColorTexture(1, 1, 1, 0.08)
                lbl:SetTextColor(1, 1, 1, 1)
                -- Rows that opted in surface their full text while truncated.
                if hoverFullText and EllesmereUI.ShowWidgetTooltip
                   and lbl:GetStringWidth() > lbl:GetWidth() + 0.5 then
                    EllesmereUI.ShowWidgetTooltip(item, hoverFullText)
                end
            end)
            item:SetScript("OnLeave", function()
                hl:SetColorTexture(1, 1, 1, 0)
                lbl:SetTextColor(0.75, 0.75, 0.75, 0.9)
                if hoverFullText and EllesmereUI.HideWidgetTooltip then
                    EllesmereUI.HideWidgetTooltip()
                end
            end)
            item:SetScript("OnClick", function()
                if hoverFullText and EllesmereUI.HideWidgetTooltip then
                    EllesmereUI.HideWidgetTooltip()
                end
                CloseCogMenu()
                onClick()
            end)
            yOff = yOff - ITEM_H
            return item, lbl
        end

        MakeActionItem("Center on Screen", function()
            if InCombatLockdown() then return end
            local bk = mover._barKey
            local PPc = EllesmereUI and EllesmereUI.PP
            local b = UM.GetBarFrame(bk)
            if not b or not PPc or not PPc.ToPixels or not PPc.FromPixels then return end
            -- Drive the move through the SAME stored-first delta path the cog X box
            -- uses when the user types 0: read current X from the pending/stored
            -- logical value for unanchored CENTER/CENTER elements (a live-derived
            -- center is off by half a pixel for odd-pixel-width frames), then
            -- NudgeMover accumulates prev + exact delta -- the stored X lands at
            -- exactly 0 and the readout echoes it (rewriting pendingPositions to a
            -- snapped TOPLEFT would bake the half pixel into the save).
            local curPx
            local aiC = GetAnchorInfo(bk)
            if not (aiC and aiC.target) then
                local pos = pendingPositions[bk]
                if type(pos) ~= "table" or pos._anchored or not pos.point then
                    local elemC = registeredElements[bk]
                    pos = elemC and elemC.loadPosition and elemC.loadPosition(bk) or nil
                    if not pos then pos = LoadBarPosition(bk) end
                end
                if type(pos) == "table" and pos.point == "CENTER"
                   and (pos.relPoint or "CENTER") == "CENTER"
                   and pos.x and pos.y then
                    -- Parity-aware like the cog X box and readout (odd dims store a half-pixel center).
                    local c2pC = PPc.CenterToPixels
                    curPx = (c2pC and c2pC(pos.x, b:GetWidth(), b:GetEffectiveScale())) or PPc.ToPixels(pos.x)
                end
            end
            if curPx == nil then
                -- Anchored/edge-stored/legacy formats: live-derived center, matching
                -- the coordinate readout. Parity-aware conversion (CenterToPixels):
                -- an odd-pixel-width frame's live center legitimately sits on a half
                -- pixel, and plain ToPixels' tie-up round overshoots it by one --
                -- the centering delta then lands the frame a full pixel left of an
                -- identical element centered from its stored value ("dragged first, then centered" 1px mismatch).
                local bL, bR = b:GetLeft(), b:GetRight()
                if not (bL and bR) then return end
                local ratio = b:GetEffectiveScale() / UIParent:GetEffectiveScale()
                local liveCX = ((bL + bR) * 0.5 * ratio) - UIParent:GetWidth() * 0.5
                if PPc.CenterToPixels then
                    curPx = PPc.CenterToPixels(liveCX, b:GetWidth(), b:GetEffectiveScale())
                else
                    curPx = PPc.ToPixels(liveCX)
                end
            end
            if curPx and curPx ~= 0 then
                EllesmereUI._unlockNudge(PPc.FromPixels(-curPx), 0, mover, true)
            end
            if mover.ReanchorToBar then mover:ReanchorToBar() end
            -- Collapse the mover if the mouse moved away during centering
            C_Timer.After(0.15, function()
                if not mover:IsMouseOver() and not (mover._cogBtn and mover._cogBtn:IsMouseOver()) then
                    if mover._hideOverlayText then mover._hideOverlayText() end
                    if UM.hoveredMover == mover then UM.hoveredMover = nil end
                    mover._hoverPending = false
                    if not mover._selected then
                        mover:SetFrameLevel(mover._baseLevel)
                    end
                end
            end)
        end)

        -- Screen-edge links: the element stays put and keeps its distance to that
        -- edge on any screen size. The grow direction is left alone.
        --
        -- Not gated on noAnchorTo, unlike the link button: that flag means "must not
        -- become a child of another element", which a screen edge never makes it.
        -- The minimap and kin carry it while EllesmereUI owns their position. Only a
        -- Blizzard-owned position must stay out, or the two fight over the frame.
        local NO_SCREEN_ANCHOR = { QueueStatus = true }   -- Blizzard Edit Mode owns it
        if not NO_SCREEN_ANCHOR[barKey] and not ns.IsMoverPosLocked(barKey) then
            -- Primary link to a screen edge. The capture comes first: on an
            -- offset-less link ApplyAnchorPosition's side-snap branch stores the FLUSH
            -- offsets (0/0) before its no-move capture runs, and the next apply would
            -- snap the element onto the edge.
            local function LinkToScreenEdge(edgeKey, side)
                if InCombatLockdown() then return end
                local offX, offY = EllesmereUI._CaptureAnchorOffsets(barKey, edgeKey, side)
                if offX == nil then return end
                SetAnchorInfo(barKey, edgeKey, side, offX, offY)
                UM.ApplyAnchorPosition(barKey, edgeKey, side, nil, true)
                if mover.RefreshAnchoredText then mover:RefreshAnchoredText() end
            end

            -- Which slot a picked edge lands in: with nothing anchored it becomes the
            -- primary; a primary screen edge on the SAME axis is replaced; when a
            -- cross-axis edge already holds the other axis the pick takes the primary
            -- slot (a plain element link there would govern nothing any more, and
            -- SetAnchorInfo keeps the other edge); otherwise it becomes the cross-axis
            -- edge and the primary keeps its own axis.
            local function SetScreenAnchor(edgeKey, side)
                if InCombatLockdown() then return end
                local ai = GetAnchorInfo(barKey)
                local axis = EllesmereUI._ScreenEdgeAxis(edgeKey)
                local hasCrossEdge = ai and ai.edge and ai.edge.key
                    and EllesmereUI._ScreenEdgeAxis(ai.edge.key) ~= axis
                if not (ai and ai.target)
                   or EllesmereUI._ScreenEdgeAxis(ai.target) == axis
                   or hasCrossEdge then
                    LinkToScreenEdge(edgeKey, side)
                    return
                end
                local off = EllesmereUI._CaptureScreenEdgeOffset(barKey, edgeKey, side)
                if off == nil then return end
                -- A link that never got offsets (module default, imported layout) would
                -- take the side-snap branch below and bank FLUSH offsets for the axis
                -- the primary keeps. Fill them from the live rect first.
                if ai.offsetX == nil or ai.offsetY == nil then
                    local pX, pY = EllesmereUI._CaptureAnchorOffsets(barKey, ai.target, ai.side)
                    if pX == nil then return end
                    ai.offsetX, ai.offsetY = pX, pY
                end
                ai.edge = { key = edgeKey, side = side, offset = off }
                EllesmereUI._anchorLinksStamp = (EllesmereUI._anchorLinksStamp or 0) + 1
                UM.ApplyAnchorPosition(barKey, ai.target, ai.side, nil, true)
                UM.hasChanges = true
                if mover.RefreshAnchoredText then mover:RefreshAnchoredText() end
            end
            -- The side says where the element sits relative to the strip, so it is
            -- the opposite of the edge it hugs. The last row carries no key: it
            -- clears the link, which is what centered means here -- the element
            -- follows the screen center again, like every unanchored element.
            local EDGE_ITEMS = {
                { key = "SCREEN_LEFT",   side = "RIGHT",  text = "Left" },
                { key = "SCREEN_RIGHT",  side = "LEFT",   text = "Right" },
                { key = "SCREEN_TOP",    side = "BOTTOM", text = "Top" },
                { key = "SCREEN_BOTTOM", side = "TOP",    text = "Bottom" },
                { text = "Center" },
            }

            -- Center: drop the SCREEN anchors only. A link to another element stays,
            -- that one belongs to the link button.
            local function ClearScreenAnchor()
                if InCombatLockdown() then return end
                local ai = GetAnchorInfo(barKey)
                if not ai then return end
                local primaryIsEdge = ai.target and EllesmereUI.IsScreenEdgeKey(ai.target)
                if not primaryIsEdge and not ai.edge then return end
                if primaryIsEdge then
                    -- Nothing holds the element afterwards: clear the record and
                    -- capture the live position so Save & Exit persists it, the same
                    -- way the link button unlink path does.
                    ClearAnchorInfo(barKey)
                    local bar = UM.GetBarFrame(barKey)
                    if bar then
                        local pt, _, rpt, bx, by = bar:GetPoint(1)
                        if pt then
                            pendingPositions[barKey] = { point = pt, relPoint = rpt, x = bx, y = by }
                        end
                    end
                else
                    -- The element link takes its axis back. Rebase its offsets from the
                    -- live rect first, or the element jumps to wherever that axis
                    -- pointed before the edge took over.
                    ai.edge = nil
                    EllesmereUI._anchorLinksStamp = (EllesmereUI._anchorLinksStamp or 0) + 1
                    local offX, offY = EllesmereUI._CaptureAnchorOffsets(barKey, ai.target, ai.side)
                    if offX ~= nil then ai.offsetX, ai.offsetY = offX, offY end
                    -- Growth bars: the pin outranks the offsets on its axis, so recapture
                    -- it from the current position too, the way the drag-stop path does.
                    if EllesmereUI._unlockCaptureGrowPin then
                        EllesmereUI._unlockCaptureGrowPin(barKey, ai, ai.side)
                    end
                    UM.ApplyAnchorPosition(barKey, ai.target, ai.side, nil, true)
                end
                UM.hasChanges = true
                if mover.RefreshAnchoredText then mover:RefreshAnchoredText() end
            end

            -- Divider: the screen anchor is a state, not another one-shot action.
            local seDiv = cogMenu:CreateTexture(nil, "ARTWORK")
            seDiv:SetHeight(PP and PP.mult or 1)
            if seDiv.SetSnapToPixelGrid then seDiv:SetSnapToPixelGrid(false); seDiv:SetTexelSnappingBias(0) end
            seDiv:SetColorTexture(1, 1, 1, 0.10)
            seDiv:SetPoint("TOPLEFT", cogMenu, "TOPLEFT", 1, yOff - 4)
            seDiv:SetPoint("TOPRIGHT", cogMenu, "TOPRIGHT", -1, yOff - 4)
            yOff = yOff - 9

            local seItem, seLbl = MakeActionItem("Relative to Screen", function() end)
            local seArrow = seItem:CreateTexture(nil, "ARTWORK")
            seArrow:SetSize(10, 10)
            seArrow:SetPoint("RIGHT", seItem, "RIGHT", -8, 0)
            seArrow:SetTexture(ARROW_RIGHT_ICON)
            seArrow:SetAlpha(0.7)
            -- Linked to an edge: the row wears the same orange as an anchored mover.
            local aiSE = GetAnchorInfo(barKey)
            local seLinked = aiSE and ((aiSE.target and EllesmereUI.IsScreenEdgeKey(aiSE.target))
                or (aiSE.edge and aiSE.edge.key ~= nil))
            if seLinked then seLbl:SetTextColor(1, 0.7, 0.3, 1) end

            local function ShowEdgeSub()
                local seSub = mover._cogEdgeSub
                if seSub then
                    for _, child in ipairs({seSub:GetChildren()}) do child:Hide(); child:SetParent(nil) end
                    for _, tex in ipairs({seSub:GetRegions()}) do if tex.Hide then tex:Hide() end end
                end
                -- Kept on the mover and parented to unlockFrame, NOT to cogMenu:
                -- BuildCogMenu reparents every cogMenu child to nil on each open, so a
                -- cogMenu-parented flyout would orphan a frame tree per menu open.
                seSub = seSub or CreateFrame("Frame", nil, UM.unlockFrame)
                mover._cogEdgeSub = seSub
                seSub:SetFrameStrata("FULLSCREEN_DIALOG")
                seSub:SetFrameLevel(cogMenu:GetFrameLevel() + 4)
                seSub:SetClampedToScreen(true)
                seSub:ClearAllPoints()
                seSub:SetPoint("TOPLEFT", seItem, "TOPRIGHT", 2, 0)
                local seBg = seSub:CreateTexture(nil, "BACKGROUND")
                seBg:SetAllPoints()
                seBg:SetColorTexture(0.075, 0.113, 0.141, 0.95)
                EllesmereUI.MakeBorder(seSub, 1, 1, 1, 0.20)
                -- Two rows can be active at once: a primary edge plus the cross-axis
                -- one. Center is active exactly while neither exists.
                local curAi = GetAnchorInfo(barKey)
                local curT = curAi and curAi.target
                curT = (curT and EllesmereUI.IsScreenEdgeKey(curT)) and curT or nil
                local curEdge = curAi and curAi.edge and curAi.edge.key or nil
                local seY = -4
                for i = 1, #EDGE_ITEMS do
                    local e = EDGE_ITEMS[i]
                    -- Center is the active row exactly while nothing is linked.
                    local isCur = (e.key ~= nil and (e.key == curT or e.key == curEdge))
                        or (e.key == nil and curAi == nil)
                    local r, g, b, a = 0.75, 0.75, 0.75, 0.9
                    if isCur then r, g, b, a = 1, 0.7, 0.3, 1 end
                    local si = CreateFrame("Button", nil, seSub)
                    si:SetHeight(ITEM_H)
                    si:SetPoint("TOPLEFT", seSub, "TOPLEFT", 1, seY)
                    si:SetPoint("TOPRIGHT", seSub, "TOPRIGHT", -1, seY)
                    si:SetFrameLevel(seSub:GetFrameLevel() + 2)
                    si:RegisterForClicks("AnyUp")
                    local sHl = si:CreateTexture(nil, "ARTWORK")
                    sHl:SetAllPoints()
                    sHl:SetColorTexture(1, 1, 1, isCur and 0.04 or 0)
                    local sLbl = si:CreateFontString(nil, "OVERLAY")
                    sLbl:SetFont(FONT_PATH, 11, "OUTLINE, SLUG")
                    sLbl:SetTextColor(r, g, b, a)
                    sLbl:SetJustifyH("LEFT")
                    sLbl:SetPoint("LEFT", si, "LEFT", 10, 0)
                    sLbl:SetPoint("RIGHT", si, "RIGHT", -8, 0)
                    sLbl:SetWordWrap(false)
                    sLbl:SetText(EllesmereUI.L(e.text))
                    si:SetScript("OnEnter", function()
                        sHl:SetColorTexture(1, 1, 1, 0.08)
                        if isCur then sLbl:SetTextColor(1, 0.8, 0.5, 1)
                        else sLbl:SetTextColor(1, 1, 1, 1) end
                        -- Preview: show the line the element would hold on to.
                        if e.key then EllesmereUI._ShowScreenEdgeMarker(e.key) end
                    end)
                    si:SetScript("OnLeave", function()
                        sHl:SetColorTexture(1, 1, 1, isCur and 0.04 or 0)
                        sLbl:SetTextColor(r, g, b, a)
                        if e.key then EllesmereUI._HideScreenEdgeMarker(e.key) end
                    end)
                    si:SetScript("OnClick", function()
                        CloseCogMenu()
                        if e.key then
                            SetScreenAnchor(e.key, e.side)
                            -- Confirmation: the menu is gone, so the line is the only
                            -- feedback that the pick landed on that edge.
                            EllesmereUI._ShowScreenEdgeMarker(e.key, true)
                        else
                            ClearScreenAnchor()
                        end
                    end)
                    seY = seY - ITEM_H
                end
                -- Fixed width: EllesmereUI.MeasureText does not exist (the other two
                -- call sites in this file are dead code for the same reason), so a
                -- measuring loop would always keep its minimum. The labels truncate
                -- instead, so a long translation cannot spill past the background.
                seSub:SetSize(DD_W, -seY + 4)
                seSub:EnableMouse(true)
                seSub:SetScript("OnLeave", function(self)
                    C_Timer.After(0.05, function()
                        if self:IsShown() and not self:IsMouseOver() and not seItem:IsMouseOver() then
                            self:Hide()
                        end
                    end)
                end)
                seSub:Show()
            end

            seItem:SetScript("OnClick", ShowEdgeSub)
            seItem:HookScript("OnEnter", function()
                seArrow:SetAlpha(0.9)
                ShowEdgeSub()
            end)
            seItem:HookScript("OnLeave", function()
                seArrow:SetAlpha(0.7)
                if seLinked then seLbl:SetTextColor(1, 0.7, 0.3, 1) end
                C_Timer.After(0.05, function()
                    local sub = mover._cogEdgeSub
                    if sub and sub:IsShown() and not sub:IsMouseOver() and not seItem:IsMouseOver() then
                        sub:Hide()
                    end
                end)
            end)
        end

        -- Toggle Orientation (hidden for vis-only bars)
        if not isVisOnly then
            MakeActionItem("Toggle Orientation", function()
                if InCombatLockdown() then return end
                if not EAB then return end
                EAB:ToggleOrientationForBar(mover._barKey)
                UM.hasChanges = true
                DeferMoverSync(movers[mover._barKey], function(m) m:Sync() end, UM.GetBarFrame(mover._barKey))
            end)
        end

        -- Fallback Anchor: only for elements anchored to a target that can
        -- be absent (tracking bars / global groups per spec, pet frame with
        -- no pet). Captures the element's CURRENT position as the spot it
        -- falls back to whenever that target is missing.
        do
            local aiF = GetAnchorInfo(barKey)
            local fbEligible = aiF and aiF.target
                and EllesmereUI.EligibleFallbackTarget
                and EllesmereUI.EligibleFallbackTarget(aiF.target)
            if fbEligible then
                local fbDiv = cogMenu:CreateTexture(nil, "ARTWORK")
                local fbDivPx = PP and PP.mult or 1
                fbDiv:SetHeight(fbDivPx)
                if fbDiv.SetSnapToPixelGrid then fbDiv:SetSnapToPixelGrid(false); fbDiv:SetTexelSnappingBias(0) end
                fbDiv:SetColorTexture(1, 1, 1, 0.10)
                fbDiv:SetPoint("TOPLEFT", cogMenu, "TOPLEFT", 1, yOff - 4)
                fbDiv:SetPoint("TOPRIGHT", cogMenu, "TOPRIGHT", -1, yOff - 4)
                yOff = yOff - 9
                -- fallback records need a target (a legacy record without
                -- one, from the retired position-capture flow, reads as unset)
                local hasFb = aiF.fallback ~= nil and aiF.fallback.target ~= nil
                MakeActionItem(hasFb and "Fallback Anchor: Change" or "Fallback Anchor: Select", function()
                    if EllesmereUI._BeginFallbackAnchorPick then
                        EllesmereUI._BeginFallbackAnchorPick(mover)
                    end
                end)
                if hasFb then
                    MakeActionItem("Fallback Anchor: Clear", function()
                        if EllesmereUI.ClearAnchorFallback then
                            EllesmereUI.ClearAnchorFallback(barKey)
                        end
                    end)
                end
            end
        end

        -- Override Anchor (Resource Bars): a per-spec-override-group alternate
        -- anchor, edited via a draggable gold ghost. Only offered for groups
        -- WITHOUT a custom unlock layout (a fork owns every position already).
        -- ONE "Override Anchor" row hover-opens an upward-building subnav of
        -- groups to add (the snap menu's regSub pattern); each existing entry
        -- gets an "Edit Override" row whose subnav offers Edit/Delete -- the
        -- menu stays a single line until overrides actually exist.
        do
            local ovGroups = EllesmereUI._OverrideAnchorEligible
                and EllesmereUI._OverrideAnchorEligible(barKey)
                and EllesmereUI._OverrideAnchorGroups
                and EllesmereUI._OverrideAnchorGroups() or nil
            if ovGroups then
                local OV_ARROW = "Interface\\AddOns\\EllesmereUI\\media\\icons\\right-arrow.png"
                local ovOpenSub  -- only one override subnav open at a time

                local function OvSubRow(sub, rsY, text, onClick)
                    local si = CreateFrame("Button", nil, sub)
                    si:SetHeight(ITEM_H)
                    si:SetPoint("TOPLEFT", sub, "TOPLEFT", 1, rsY)
                    si:SetPoint("TOPRIGHT", sub, "TOPRIGHT", -1, rsY)
                    si:SetFrameLevel(sub:GetFrameLevel() + 2)
                    si:RegisterForClicks("AnyUp")
                    local sHl = si:CreateTexture(nil, "ARTWORK")
                    sHl:SetAllPoints()
                    sHl:SetColorTexture(1, 1, 1, 0)
                    local sLbl = si:CreateFontString(nil, "OVERLAY")
                    sLbl:SetFont(FONT_PATH, 11, "OUTLINE, SLUG")
                    sLbl:SetTextColor(0.75, 0.75, 0.75, 0.9)
                    sLbl:SetJustifyH("LEFT")
                    sLbl:SetPoint("LEFT", si, "LEFT", 10, 0)
                    sLbl:SetText(text)
                    si:SetScript("OnEnter", function()
                        sHl:SetColorTexture(1, 1, 1, 0.08)
                        sLbl:SetTextColor(1, 1, 1, 1)
                    end)
                    si:SetScript("OnLeave", function()
                        sHl:SetColorTexture(1, 1, 1, 0)
                        sLbl:SetTextColor(0.75, 0.75, 0.75, 0.9)
                    end)
                    si:SetScript("OnClick", function()
                        CloseCogMenu()
                        onClick()
                    end)
                    return rsY - ITEM_H
                end

                -- Parent row with a right arrow; entries rebuilt on every
                -- hover ({ text, fn } rows, { text, title = true } headers).
                local function OvSubnavItem(text, buildEntries)
                    local item = CreateFrame("Button", nil, cogMenu)
                    item:SetHeight(ITEM_H)
                    item:SetPoint("TOPLEFT", cogMenu, "TOPLEFT", 1, yOff)
                    item:SetPoint("TOPRIGHT", cogMenu, "TOPRIGHT", -1, yOff)
                    item:SetFrameLevel(cogMenu:GetFrameLevel() + 2)
                    item:RegisterForClicks("AnyUp")
                    local hl = item:CreateTexture(nil, "ARTWORK")
                    hl:SetAllPoints()
                    hl:SetColorTexture(1, 1, 1, 0)
                    local lbl = item:CreateFontString(nil, "OVERLAY")
                    EllesmereUI.PrimeFontShadow(lbl, true)
                    lbl:SetFont(FONT_PATH, 11, "")
                    lbl:SetTextColor(0.75, 0.75, 0.75, 0.9)
                    lbl:SetJustifyH("LEFT")
                    lbl:SetPoint("LEFT", item, "LEFT", 10, 0)
                    lbl:SetPoint("RIGHT", item, "RIGHT", -20, 0)
                    lbl:SetWordWrap(false)
                    lbl:SetText(EllesmereUI.L(text))
                    local arrow = item:CreateTexture(nil, "ARTWORK")
                    arrow:SetSize(10, 10)
                    arrow:SetPoint("RIGHT", item, "RIGHT", -8, 0)
                    arrow:SetTexture(OV_ARROW)
                    arrow:SetAlpha(0.5)
                    local sub
                    local function ShowSub()
                        if ovOpenSub and ovOpenSub ~= sub and ovOpenSub:IsShown() then
                            ovOpenSub:Hide()
                        end
                        if sub then
                            for _, child in ipairs({sub:GetChildren()}) do child:Hide(); child:SetParent(nil) end
                            for _, tex in ipairs({sub:GetRegions()}) do if tex.Hide then tex:Hide() end end
                        end
                        -- Parented to the cog menu so closing/rebuilding the
                        -- menu tears the subnav down with it.
                        sub = sub or CreateFrame("Frame", nil, cogMenu)
                        sub:SetFrameStrata("FULLSCREEN_DIALOG")
                        sub:SetFrameLevel(cogMenu:GetFrameLevel() + 4)
                        sub:SetClampedToScreen(true)
                        -- Build UPWARD: the subnav's bottom is pinned level
                        -- with the row, so added rows extend toward the top.
                        sub:ClearAllPoints()
                        sub:SetPoint("BOTTOMLEFT", item, "BOTTOMRIGHT", 2, 0)
                        local sBg = sub:CreateTexture(nil, "BACKGROUND")
                        sBg:SetAllPoints()
                        sBg:SetColorTexture(0.075, 0.113, 0.141, 0.95)
                        EllesmereUI.MakeBorder(sub, 1, 1, 1, 0.20)
                        local entries = buildEntries()
                        local rsY = -4
                        local maxW = 140
                        for _, e in ipairs(entries) do
                            if e.title then
                                local t = sub:CreateFontString(nil, "OVERLAY")
                                t:SetFont(FONT_PATH, 10, "OUTLINE, SLUG")
                                t:SetTextColor(1, 1, 1, 0.40)
                                t:SetJustifyH("LEFT")
                                t:SetPoint("TOPLEFT", sub, "TOPLEFT", 10, rsY - 4)
                                t:SetText(e.text)
                                rsY = rsY - 18
                                local div = sub:CreateTexture(nil, "ARTWORK")
                                div:SetHeight(1)
                                div:SetColorTexture(1, 1, 1, 0.10)
                                div:SetPoint("TOPLEFT", sub, "TOPLEFT", 1, rsY - 2)
                                div:SetPoint("TOPRIGHT", sub, "TOPRIGHT", -1, rsY - 2)
                                rsY = rsY - 5
                            else
                                rsY = OvSubRow(sub, rsY, e.text, e.fn)
                            end
                            local tw = (EllesmereUI.MeasureText
                                and EllesmereUI.MeasureText(e.text, FONT_PATH, e.title and 10 or 11)) or 0
                            local needed = 10 + tw + 10 + 2
                            if needed > maxW then maxW = needed end
                        end
                        sub:SetSize(maxW, -rsY + 4)
                        sub:EnableMouse(true)
                        sub:SetScript("OnLeave", function(self)
                            C_Timer.After(0.05, function()
                                if self:IsShown() and not self:IsMouseOver() and not item:IsMouseOver() then
                                    self:Hide()
                                end
                            end)
                        end)
                        sub:Show()
                        ovOpenSub = sub
                    end
                    item:SetScript("OnEnter", function()
                        hl:SetColorTexture(1, 1, 1, 0.08)
                        lbl:SetTextColor(1, 1, 1, 1)
                        arrow:SetAlpha(0.9)
                        ShowSub()
                    end)
                    item:SetScript("OnLeave", function()
                        hl:SetColorTexture(1, 1, 1, 0)
                        lbl:SetTextColor(0.75, 0.75, 0.75, 0.9)
                        arrow:SetAlpha(0.5)
                        C_Timer.After(0.05, function()
                            if sub and sub:IsShown() and not sub:IsMouseOver() and not item:IsMouseOver() then
                                sub:Hide()
                            end
                        end)
                    end)
                    yOff = yOff - ITEM_H
                    return item
                end

                local ovDiv = cogMenu:CreateTexture(nil, "ARTWORK")
                local ovDivPx = PP and PP.mult or 1
                ovDiv:SetHeight(ovDivPx)
                if ovDiv.SetSnapToPixelGrid then ovDiv:SetSnapToPixelGrid(false); ovDiv:SetTexelSnappingBias(0) end
                ovDiv:SetColorTexture(1, 1, 1, 0.10)
                ovDiv:SetPoint("TOPLEFT", cogMenu, "TOPLEFT", 1, yOff - 4)
                ovDiv:SetPoint("TOPRIGHT", cogMenu, "TOPRIGHT", -1, yOff - 4)
                yOff = yOff - 9

                local addable = {}
                for _, og in ipairs(ovGroups) do
                    if not (EllesmereUI._HasOverrideAnchor and EllesmereUI._HasOverrideAnchor(barKey, og.id)) then
                        addable[#addable + 1] = og
                    end
                end
                if #addable > 0 then
                    OvSubnavItem("Override Anchor", function()
                        local entries = {}
                        for _, og in ipairs(addable) do
                            local gid = og.id
                            entries[#entries + 1] = {
                                text = og.name or ("Group " .. tostring(gid)),
                                fn = function()
                                    if EllesmereUI._BeginOverrideAnchorPick then
                                        EllesmereUI._BeginOverrideAnchorPick(mover, gid)
                                    end
                                end,
                            }
                        end
                        return entries
                    end)
                end
                for _, og in ipairs(ovGroups) do
                    if EllesmereUI._HasOverrideAnchor and EllesmereUI._HasOverrideAnchor(barKey, og.id) then
                        local gid = og.id
                        local gname = og.name or ("Group " .. tostring(gid))
                        OvSubnavItem("Edit Override: " .. gname, function()
                            return {
                                { text = gname, title = true },
                                { text = EllesmereUI.L("Edit Anchor"), fn = function()
                                    if EllesmereUI._BeginOverrideAnchorPick then
                                        EllesmereUI._BeginOverrideAnchorPick(mover, gid)
                                    end
                                end },
                                { text = EllesmereUI.L("Delete Override Anchor"), fn = function()
                                    if EllesmereUI._ClearOverrideAnchor then
                                        EllesmereUI._ClearOverrideAnchor(barKey, gid)
                                    end
                                end },
                            }
                        end)
                    end
                end
            end
        end

        cogMenu:SetHeight(-yOff + 4)
        cogMenu:Show()
    end

    -- Click-catcher for cog menu
    local function ShowCogClickCatcher()
        if not cogClickCatcher then
            cogClickCatcher = CreateFrame("Button", nil, UM.unlockFrame)
            cogClickCatcher:SetFrameStrata("FULLSCREEN_DIALOG")
            cogClickCatcher:SetFrameLevel(249)
            cogClickCatcher:SetAllPoints(UIParent)
            cogClickCatcher:RegisterForClicks("AnyUp")
            cogClickCatcher:SetScript("OnClick", function()
                CloseCogMenu()
            end)
        end
        cogClickCatcher:Show()
    end

    cogBtn:SetScript("OnClick", function()
        if cogMenu and cogMenu:IsShown() then
            CloseCogMenu()
        else
            SelectMover(mover)
            mover._menuOpen = true
            BuildCogMenu()
            ShowCogClickCatcher()
        end
    end)
    cogBtn:SetScript("OnHide", CloseCogMenu)

    -- Expose cog menu opener on the mover (used by right-click handler)
    mover._openCogMenu = function()
        if cogMenu and cogMenu:IsShown() then
            CloseCogMenu()
        else
            SelectMover(mover)
            mover._menuOpen = true
            BuildCogMenu()
            ShowCogClickCatcher()
        end
    end

    -- Re-read this mover's name from its registered element. `label` above is
    -- a plain local captured once at CreateMover time -- RefreshAnchoredIdle
    -- (fired on every hover and anchor-state change, see ShowOverlayText /
    -- RefreshAnchoredText) closes over that SAME local and keeps re-painting it
    -- verbatim, so a caller that only did nameFS:SetText(...) directly would see
    -- the very next hover silently revert the text. Reassigning the local here
    -- (a plain Lua upvalue write, legal from any function sharing this closure)
    -- is what makes the change stick.
    function mover:UpdateLabel()
        label = UM.GetBarLabel(barKey)
        RefreshAnchoredIdle()
    end

    -- Opt-in hover tooltip (element definition field `moverTooltip`, string or
    -- function): additive-only -- absent = the handlers no-op. Installed
    -- UNCONDITIONALLY and resolved LIVE from registeredElements, because movers
    -- persist for the whole session while elements re-register with
    -- state-dependent tooltips (CDM's Additional Bar Offset marker). Placed
    -- after every SetScript above so the HookScripts can never be replaced.
    -- Suppressed while dragging and in the pick/select modes (the base OnEnter
    -- early-returns there and a tooltip over the pickers would mislead).
    mover:HookScript("OnEnter", function()
        local el = registeredElements[barKey]
        local tip = el and el.moverTooltip
        if not tip then return end
        if _mouseHeld or UM.pickMode or UM.selectElementPicker then return end
        if type(tip) == "function" then tip = tip(barKey) end
        if tip and EllesmereUI.ShowWidgetTooltip then
            EllesmereUI.ShowWidgetTooltip(mover, tip)
        end
    end)
    mover:HookScript("OnLeave", function()
        EllesmereUI.HideWidgetTooltip()
    end)
    mover:HookScript("OnDragStart", function()
        EllesmereUI.HideWidgetTooltip()
    end)

    movers[barKey] = mover
    return mover
end

-- Override RegisterUnlockElements so that late-registering addons (e.g. CDM
-- registering after a 0.5s timer) get movers spawned immediately if unlock
-- mode is already open when they call in.
do
    local _origRegister = EllesmereUI.RegisterUnlockElements
    function EllesmereUI:RegisterUnlockElements(elements, folder)
        _origRegister(self, elements, folder)
        if not UM.isUnlocked then return end
        -- Unlock mode is open -- spawn movers for any newly registered keys,
        -- and hide existing movers whose element is now intentionally hidden.
        local spawned = false
        for _, elem in ipairs(elements) do
            local key = elem.key
            if movers[key] then
                -- Re-registration: hide mover if element is now hidden, and
                -- RE-SHOW one whose element came back (e.g. a PAB bar
                -- re-enabled mid-session -- the drop half always worked, the
                -- restore half never did). Session temp-hides
                -- (Shift+Right-Click) stay respected.
                if elem.isHidden and elem.isHidden() then
                    movers[key]:Hide()
                elseif not movers[key]:IsShown() and not movers[key]._tempHidden then
                    movers[key]:Sync()
                    movers[key]:SetAlpha(UM.darkOverlaysEnabled and 1 or MOVER_ALPHA)
                    movers[key]:Show()
                    spawned = true
                end
            else
                local m = CreateMover(key)
                if m then
                    m:Sync()
                    m:SetAlpha(UM.darkOverlaysEnabled and 1 or MOVER_ALPHA)
                    m:Show()
                    spawned = true
                end
            end
        end
        if spawned then
            SortMoverFrameLevels()
            ReapplyAllAnchors()
        end
    end
end

-------------------------------------------------------------------------------
--  Top Banner Bar: single pre-rendered banner image (1144x120), displayed
--  pixel-perfect at native resolution, flush with top of screen. Grid + magnet
--  toggle icons overlaid on top. Slides down during the SHACKLE animation phase.
-------------------------------------------------------------------------------
local GRID_ICON       = "Interface\\AddOns\\EllesmereUI\\media\\icons\\grid.png"
local MAGNET_ICON     = "Interface\\AddOns\\EllesmereUI\\media\\icons\\magnet.png"
local FLASHLIGHT_ICON = "Interface\\AddOns\\EllesmereUI\\media\\icons\\flashlight.png"
local HOVER_ICON      = "Interface\\AddOns\\EllesmereUI\\media\\icons\\hover.png"
local DARK_OVERLAY_ICON = "Interface\\AddOns\\EllesmereUI\\media\\icons\\dark-overlay.png"
local COORD_ICON      = "Interface\\AddOns\\EllesmereUI\\media\\icons\\coordinates.png"
local BANNER_TEX      = "Interface\\AddOns\\EllesmereUI\\media\\eui-unlocked-banner-2.png"

local HUD_ON_ALPHA  = 0.60
local HUD_OFF_ALPHA = 0.30
local HUD_ICON_SZ   = 20

-- Banner native pixel dimensions
local BANNER_PX_W = 1144
local BANNER_PX_H = 120

UM.hudFrame = nil

-- Stable visible-height anchor for other addons that stack controls below the banner.
function EllesmereUI:GetUnlockModeTopBarAnchor()
    return UM.hudFrame and UM.hudFrame._hoverZone
end

local hoverBarEnabled = false   -- show-bar-on-hover toggle

local function CreateHUD(parent)
    if UM.hudFrame then return UM.hudFrame end

    local ar, ag, ab = GetAccent()

    -- Load saved settings
    if EllesmereUIDB then
        if EllesmereUIDB.unlockGridMode == nil then EllesmereUIDB.unlockGridMode = "dimmed" end
        if EllesmereUIDB.unlockSnapEnabled == nil then EllesmereUIDB.unlockSnapEnabled = true end
    end
    UM.gridMode = (EllesmereUIDB and EllesmereUIDB.unlockGridMode) or "dimmed"
    UM.snapEnabled = (EllesmereUIDB and EllesmereUIDB.unlockSnapEnabled ~= false) or true

    -- Pixel-perfect scale: 1 frame unit = 1 physical screen pixel
    local physW = (GetPhysicalScreenSize())
    local uiScale = GetScreenWidth() / physW
    -- At very low UI scales the top bar gets too small to read; enlarge it 15%.
    -- Bumping the base here propagates through every downstream scale use
    -- (initial scale, user banner scale, slide-in offsets read GetScale()).
    if UIParent:GetEffectiveScale() < 0.6 then uiScale = uiScale * 1.08 end

    UM.hudFrame = CreateFrame("Frame", nil, parent)
    UM.hudFrame:SetFrameStrata("TOOLTIP")
    UM.hudFrame:SetFrameLevel(900)
    UM.hudFrame:SetSize(BANNER_PX_W, BANNER_PX_H)
    UM.hudFrame:SetScale(uiScale)
    UM.hudFrame:EnableMouse(false)  -- background only, clicks pass through
    -- Start off-screen above
    UM.hudFrame:SetPoint("TOP", UIParent, "TOP", 0, (BANNER_PX_H + 10) * uiScale)

    -- Banner image at native resolution
    local bannerTex = UM.hudFrame:CreateTexture(nil, "ARTWORK")
    bannerTex:SetTexture(BANNER_TEX)
    bannerTex:SetSize(BANNER_PX_W, BANNER_PX_H)
    bannerTex:SetPoint("TOPLEFT", UM.hudFrame, "TOPLEFT", 0, 0)
    if bannerTex.SetSnapToPixelGrid then bannerTex:SetSnapToPixelGrid(false); bannerTex:SetTexelSnappingBias(0) end
    UM.hudFrame._bannerTex = bannerTex

    -- Icons at native 28x28 resolution (banner frame is already pixel-perfect scaled)
    -- Vertically centered within the 58px visible banner area, shifted up 1px
    local iconSz = 28
    local BANNER_VIS_H = 58
    local iconCenterY = -(BANNER_VIS_H / 2) + 1  -- -28px from top (centered + 1px up)

    -- Helper: shared hover/click behavior for icon+label wrapper buttons
    local function SetupToggleBtn(wrapper, iconTex, labelFS, getState, setState)
        wrapper:SetScript("OnClick", function() setState() end)
        wrapper:SetScript("OnEnter", function()
            iconTex:SetAlpha(0.9)
            labelFS:SetTextColor(1, 1, 1, 0.9)
        end)
        wrapper:SetScript("OnLeave", function()
            local a = getState() and HUD_ON_ALPHA or HUD_OFF_ALPHA
            iconTex:SetAlpha(a)
            labelFS:SetTextColor(1, 1, 1, a)
        end)
    end

    ---------------------------------------------------------------
    --  Grid toggle (left of center): label LEFT of icon
    ---------------------------------------------------------------
    local gridBtn = CreateFrame("Button", nil, UM.hudFrame)
    -- Size will be set after label is created to encompass icon + gap + label
    gridBtn:SetPoint("RIGHT", UM.hudFrame, "TOP", -80 + iconSz / 2, iconCenterY)

    local gridTex = gridBtn:CreateTexture(nil, "OVERLAY")
    gridTex:SetSize(iconSz, iconSz)
    gridTex:SetPoint("RIGHT", gridBtn, "RIGHT", 0, 0)
    gridTex:SetTexture(GRID_ICON)
    gridTex:SetAlpha(GridHudAlpha())
    gridBtn._tex = gridTex

    local gridLabel = gridBtn:CreateFontString(nil, "OVERLAY")
    gridLabel:SetFont(FONT_PATH, 10, "OUTLINE, SLUG")
    gridLabel:SetJustifyH("RIGHT")
    gridLabel:SetPoint("RIGHT", gridTex, "LEFT", -5, 0)
    gridLabel:SetTextColor(1, 1, 1, GridHudAlpha())
    gridLabel:SetText(EllesmereUI.L(GridLabelText()))
    gridBtn._label = gridLabel

    -- Size wrapper to fit label + gap + icon
    local gridLabelW = gridLabel:GetStringWidth() or 80
    gridBtn:SetSize(gridLabelW + 5 + iconSz, max(iconSz, 24))

    -- Custom 3-state toggle (not using SetupToggleBtn)
    gridBtn:SetScript("OnClick", function()
        CycleGridMode()
        if EllesmereUIDB then EllesmereUIDB.unlockGridMode = UM.gridMode end
        local a = GridHudAlpha()
        gridTex:SetAlpha(a)
        gridLabel:SetTextColor(1, 1, 1, a)
        gridLabel:SetText(EllesmereUI.L(GridLabelText()))
        if UM.gridFrame then
            if UM.gridMode ~= "disabled" then
                UM.gridFrame:Rebuild()
                UM.gridFrame:Show()
            else
                UM.gridFrame:Hide()
            end
        end
    end)
    gridBtn:SetScript("OnEnter", function()
        gridTex:SetAlpha(0.9)
        gridLabel:SetTextColor(1, 1, 1, 0.9)
    end)
    gridBtn:SetScript("OnLeave", function()
        local a = GridHudAlpha()
        gridTex:SetAlpha(a)
        gridLabel:SetTextColor(1, 1, 1, a)
    end)
    UM.hudFrame._gridBtn = gridBtn

    ---------------------------------------------------------------
    --  Dark Overlays toggle (left of grid): label LEFT of icon
    ---------------------------------------------------------------
    local darkOverlayBtn = CreateFrame("Button", nil, UM.hudFrame)
    darkOverlayBtn:SetPoint("RIGHT", gridBtn, "LEFT", -20, 0)

    local darkOverlayTex = darkOverlayBtn:CreateTexture(nil, "OVERLAY")
    darkOverlayTex:SetSize(iconSz, iconSz)
    darkOverlayTex:SetPoint("RIGHT", darkOverlayBtn, "RIGHT", 0, 0)
    darkOverlayTex:SetTexture(DARK_OVERLAY_ICON)
    darkOverlayTex:SetAlpha(UM.darkOverlaysEnabled and HUD_ON_ALPHA or HUD_OFF_ALPHA)
    darkOverlayBtn._tex = darkOverlayTex

    local darkOverlayLabel = darkOverlayBtn:CreateFontString(nil, "OVERLAY")
    darkOverlayLabel:SetFont(FONT_PATH, 10, "OUTLINE, SLUG")
    darkOverlayLabel:SetJustifyH("RIGHT")
    darkOverlayLabel:SetPoint("RIGHT", darkOverlayTex, "LEFT", -5, 0)
    darkOverlayLabel:SetTextColor(1, 1, 1, UM.darkOverlaysEnabled and HUD_ON_ALPHA or HUD_OFF_ALPHA)
    darkOverlayLabel:SetText(UM.darkOverlaysEnabled and EllesmereUI.L("Dark Overlays\nEnabled") or EllesmereUI.L("Dark Overlays\nDisabled"))
    darkOverlayBtn._label = darkOverlayLabel

    local darkOverlayLabelW = darkOverlayLabel:GetStringWidth() or 80
    darkOverlayBtn:SetSize(darkOverlayLabelW + 5 + iconSz, max(iconSz, 24))

    SetupToggleBtn(darkOverlayBtn, darkOverlayTex, darkOverlayLabel,
        function() return UM.darkOverlaysEnabled end,
        function()
            UM.darkOverlaysEnabled = not UM.darkOverlaysEnabled
            darkOverlayTex:SetAlpha(UM.darkOverlaysEnabled and HUD_ON_ALPHA or HUD_OFF_ALPHA)
            darkOverlayLabel:SetTextColor(1, 1, 1, UM.darkOverlaysEnabled and HUD_ON_ALPHA or HUD_OFF_ALPHA)
            darkOverlayLabel:SetText(UM.darkOverlaysEnabled and EllesmereUI.L("Dark Overlays\nEnabled") or EllesmereUI.L("Dark Overlays\nDisabled"))
            ApplyDarkOverlays()
        end)
    UM.hudFrame._darkOverlayBtn = darkOverlayBtn

    ---------------------------------------------------------------
    --  Flashlight toggle (left of grid): label LEFT of icon
    ---------------------------------------------------------------
    local flashBtn = CreateFrame("Button", nil, UM.hudFrame)
    flashBtn:SetPoint("RIGHT", darkOverlayBtn, "LEFT", -20, 0)

    local flashTex = flashBtn:CreateTexture(nil, "OVERLAY")
    flashTex:SetSize(iconSz, iconSz)
    flashTex:SetPoint("RIGHT", flashBtn, "RIGHT", 0, 0)
    flashTex:SetTexture(FLASHLIGHT_ICON)
    flashTex:SetAlpha(UM.flashlightEnabled and HUD_ON_ALPHA or HUD_OFF_ALPHA)
    flashBtn._tex = flashTex

    local flashLabel = flashBtn:CreateFontString(nil, "OVERLAY")
    flashLabel:SetFont(FONT_PATH, 10, "OUTLINE, SLUG")
    flashLabel:SetJustifyH("RIGHT")
    flashLabel:SetPoint("RIGHT", flashTex, "LEFT", -5, 0)
    flashLabel:SetTextColor(1, 1, 1, UM.flashlightEnabled and HUD_ON_ALPHA or HUD_OFF_ALPHA)
    flashLabel:SetText(UM.flashlightEnabled and EllesmereUI.L("Cursor Light\nEnabled") or EllesmereUI.L("Cursor Light\nDisabled"))
    flashBtn._label = flashLabel

    local flashLabelW = flashLabel:GetStringWidth() or 80
    flashBtn:SetSize(flashLabelW + 5 + iconSz, max(iconSz, 24))

    SetupToggleBtn(flashBtn, flashTex, flashLabel,
        function() return UM.flashlightEnabled end,
        function()
            UM.flashlightEnabled = not UM.flashlightEnabled
            flashTex:SetAlpha(UM.flashlightEnabled and HUD_ON_ALPHA or HUD_OFF_ALPHA)
            flashLabel:SetTextColor(1, 1, 1, UM.flashlightEnabled and HUD_ON_ALPHA or HUD_OFF_ALPHA)
            flashLabel:SetText(UM.flashlightEnabled and EllesmereUI.L("Cursor Light\nEnabled") or EllesmereUI.L("Cursor Light\nDisabled"))
        end)
    UM.hudFrame._flashBtn = flashBtn

    ---------------------------------------------------------------
    --  Magnet/Snap toggle (right of center): label RIGHT of icon
    ---------------------------------------------------------------
    local magnetBtn = CreateFrame("Button", nil, UM.hudFrame)
    magnetBtn:SetPoint("LEFT", UM.hudFrame, "TOP", 76 - iconSz / 2, iconCenterY)

    local magnetTex = magnetBtn:CreateTexture(nil, "OVERLAY")
    magnetTex:SetSize(iconSz, iconSz)
    magnetTex:SetPoint("LEFT", magnetBtn, "LEFT", 0, 0)
    magnetTex:SetTexture(MAGNET_ICON)
    magnetTex:SetAlpha(UM.snapEnabled and HUD_ON_ALPHA or HUD_OFF_ALPHA)
    magnetBtn._tex = magnetTex

    local magnetLabel = magnetBtn:CreateFontString(nil, "OVERLAY")
    magnetLabel:SetFont(FONT_PATH, 10, "OUTLINE, SLUG")
    magnetLabel:SetJustifyH("LEFT")
    magnetLabel:SetPoint("LEFT", magnetTex, "RIGHT", 5, 0)
    magnetLabel:SetTextColor(1, 1, 1, UM.snapEnabled and HUD_ON_ALPHA or HUD_OFF_ALPHA)
    magnetLabel:SetText(UM.snapEnabled and EllesmereUI.L("Snap Elements\nEnabled") or EllesmereUI.L("Snap Elements\nDisabled"))
    magnetBtn._label = magnetLabel

    local magnetLabelW = magnetLabel:GetStringWidth() or 100
    magnetBtn:SetSize(iconSz + 5 + magnetLabelW, max(iconSz, 24))

    SetupToggleBtn(magnetBtn, magnetTex, magnetLabel,
        function() return UM.snapEnabled end,
        function()
            UM.snapEnabled = not UM.snapEnabled
            if EllesmereUIDB then EllesmereUIDB.unlockSnapEnabled = UM.snapEnabled end
            magnetTex:SetAlpha(UM.snapEnabled and HUD_ON_ALPHA or HUD_OFF_ALPHA)
            magnetLabel:SetTextColor(1, 1, 1, UM.snapEnabled and HUD_ON_ALPHA or HUD_OFF_ALPHA)
            magnetLabel:SetText(UM.snapEnabled and EllesmereUI.L("Snap Elements\nEnabled") or EllesmereUI.L("Snap Elements\nDisabled"))
            -- Refresh all movers' snap dropdown visual state
            for _, m in pairs(movers) do
                if m._refreshSnapDD then m._refreshSnapDD() end
            end
        end)
    UM.hudFrame._magnetBtn = magnetBtn

    ---------------------------------------------------------------
    --  Coordinates toggle (right of snap): label RIGHT of icon
    ---------------------------------------------------------------
    local coordBtn = CreateFrame("Button", nil, UM.hudFrame)
    coordBtn:SetPoint("LEFT", magnetBtn, "RIGHT", 7, 0)

    local coordTex = coordBtn:CreateTexture(nil, "OVERLAY")
    coordTex:SetSize(iconSz, iconSz)
    coordTex:SetPoint("LEFT", coordBtn, "LEFT", 0, 0)
    coordTex:SetTexture(COORD_ICON)
    coordTex:SetAlpha(UM.coordsEnabled and HUD_ON_ALPHA or HUD_OFF_ALPHA)
    coordBtn._tex = coordTex

    local coordLabel = coordBtn:CreateFontString(nil, "OVERLAY")
    coordLabel:SetFont(FONT_PATH, 10, "OUTLINE, SLUG")
    coordLabel:SetJustifyH("LEFT")
    coordLabel:SetPoint("LEFT", coordTex, "RIGHT", 1, 0)
    coordLabel:SetTextColor(1, 1, 1, UM.coordsEnabled and HUD_ON_ALPHA or HUD_OFF_ALPHA)
    coordLabel:SetText(UM.coordsEnabled and EllesmereUI.L("Coordinates\nEnabled") or EllesmereUI.L("Coordinates\nDisabled"))
    coordBtn._label = coordLabel

    local coordLabelW = coordLabel:GetStringWidth() or 110
    coordBtn:SetSize(iconSz + 5 + coordLabelW, max(iconSz, 24))

    SetupToggleBtn(coordBtn, coordTex, coordLabel,
        function() return UM.coordsEnabled end,
        function()
            UM.coordsEnabled = not UM.coordsEnabled
            coordTex:SetAlpha(UM.coordsEnabled and HUD_ON_ALPHA or HUD_OFF_ALPHA)
            coordLabel:SetTextColor(1, 1, 1, UM.coordsEnabled and HUD_ON_ALPHA or HUD_OFF_ALPHA)
            coordLabel:SetText(UM.coordsEnabled and EllesmereUI.L("Coordinates\nEnabled") or EllesmereUI.L("Coordinates\nDisabled"))
            -- Show or hide coords for all movers based on new state
            for _, m in pairs(movers) do
                if m._coordFS then
                    if UM.coordsEnabled then
                        if m.UpdateCoordText then m:UpdateCoordText() end
                    else
                        -- Only keep visible on the currently selected mover
                        if not m._selected then
                            m._coordFS:Hide()
                        end
                    end
                end
            end
        end)
    UM.hudFrame._coordBtn = coordBtn

    ---------------------------------------------------------------
    --  Hover toggle (right of coords): label RIGHT of icon
    ---------------------------------------------------------------
    local hoverBtn = CreateFrame("Button", nil, UM.hudFrame)
    hoverBtn:SetPoint("LEFT", coordBtn, "RIGHT", 2, 0)

    local hoverTex = hoverBtn:CreateTexture(nil, "OVERLAY")
    hoverTex:SetSize(iconSz, iconSz)
    hoverTex:SetPoint("LEFT", hoverBtn, "LEFT", 0, 0)
    hoverTex:SetTexture(HOVER_ICON)
    hoverTex:SetAlpha(hoverBarEnabled and HUD_ON_ALPHA or HUD_OFF_ALPHA)
    hoverBtn._tex = hoverTex

    local hoverLabel = hoverBtn:CreateFontString(nil, "OVERLAY")
    hoverLabel:SetFont(FONT_PATH, 10, "OUTLINE, SLUG")
    hoverLabel:SetJustifyH("LEFT")
    hoverLabel:SetPoint("LEFT", hoverTex, "RIGHT", 5, 0)
    hoverLabel:SetTextColor(1, 1, 1, hoverBarEnabled and HUD_ON_ALPHA or HUD_OFF_ALPHA)
    hoverLabel:SetText(hoverBarEnabled and EllesmereUI.L("Hover Top Bar\nEnabled") or EllesmereUI.L("Hover Top Bar\nDisabled"))
    hoverBtn._label = hoverLabel

    local hoverLabelW = hoverLabel:GetStringWidth() or 110
    hoverBtn:SetSize(iconSz + 5 + hoverLabelW, max(iconSz, 24))

    SetupToggleBtn(hoverBtn, hoverTex, hoverLabel,
        function() return hoverBarEnabled end,
        function()
            hoverBarEnabled = not hoverBarEnabled
            hoverTex:SetAlpha(hoverBarEnabled and HUD_ON_ALPHA or HUD_OFF_ALPHA)
            hoverLabel:SetTextColor(1, 1, 1, hoverBarEnabled and HUD_ON_ALPHA or HUD_OFF_ALPHA)
            hoverLabel:SetText(hoverBarEnabled and EllesmereUI.L("Hover Top Bar\nEnabled") or EllesmereUI.L("Hover Top Bar\nDisabled"))
        end)
    UM.hudFrame._hoverBtn = hoverBtn

    ---------------------------------------------------------------
    --  Exit (left) and Save & Exit (right) buttons
    --  Vertically centered in the 58px visible banner area.
    --  Positioned ~50px from left/right edges of the banner, but pulled in
    --  further when localized toggle labels run wide enough to reach them
    --  (German especially runs longer than English and used to overlap them).
    ---------------------------------------------------------------
    local BTN_H = 26
    local BTN_FONT = 10
    local btnCenterY = iconCenterY  -- same vertical center as icons
    local CHAIN_GAP = 15  -- minimum clearance from the icon-toggle chain

    -- Outer edges of the left (grid/darkOverlay/flash) and right
    -- (magnet/coord/hover) toggle chains, center-relative -- re-derives the
    -- same offsets used to anchor them above, so keep these in sync with
    -- those SetPoint calls if the chain spacing ever changes.
    local flashLeftEdge = (-80 + iconSz / 2) - gridBtn:GetWidth() - 20 - darkOverlayBtn:GetWidth() - 20 - flashBtn:GetWidth()
    local hoverRightEdge = (76 - iconSz / 2) + magnetBtn:GetWidth() + 7 + coordBtn:GetWidth() + 2 + hoverBtn:GetWidth()

    -- Exit button (left side, 85px from left edge by default)
    local exitBtn = CreateFrame("Button", nil, UM.hudFrame)
    local EXIT_BTN_W = 60
    exitBtn:SetSize(EXIT_BTN_W, BTN_H)
    local exitLeftEdge = min(-BANNER_PX_W / 2 + 85, flashLeftEdge - CHAIN_GAP - EXIT_BTN_W)
    exitBtn:SetPoint("LEFT", UM.hudFrame, "TOPLEFT", exitLeftEdge + BANNER_PX_W / 2, btnCenterY)
    EllesmereUI.MakeStyledButton(exitBtn, "Exit", BTN_FONT,
        EllesmereUI.RB_COLOURS, function() ns.RequestClose(false) end)
    UM.hudFrame._exitBtn = exitBtn

    -- Save & Exit button (right side, 50px from right edge, green "Done" style)
    do
        local btn = CreateFrame("Button", nil, UM.hudFrame)
        local SAVE_BTN_W = 90
        btn:SetSize(SAVE_BTN_W, BTN_H)
        local saveRightEdge = max(BANNER_PX_W / 2 - 85, hoverRightEdge + CHAIN_GAP + SAVE_BTN_W)
        btn:SetPoint("RIGHT", UM.hudFrame, "TOPRIGHT", saveRightEdge - BANNER_PX_W / 2, btnCenterY)
        btn:SetFrameLevel(UM.hudFrame:GetFrameLevel() + 2)

        local eg = EllesmereUI.ELLESMERE_GREEN or { r = 12/255, g = 210/255, b = 157/255 }
        EllesmereUI.MakeBorder(btn, eg.r, eg.g, eg.b, 0.7)
        local bg = btn:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.06, 0.08, 0.10, 0.92)

        local lbl = btn:CreateFontString(nil, "OVERLAY")
        lbl:SetFont(FONT_PATH, BTN_FONT, "OUTLINE, SLUG")
        lbl:SetPoint("CENTER")
        lbl:SetText(EllesmereUI.L("Save & Exit"))
        lbl:SetTextColor(eg.r, eg.g, eg.b, 0.7)

        local FADE_DUR = 0.1
        local progress, target = 0, 0
        local lerp = EllesmereUI.lerp
        local function Apply(t)
            local c = EllesmereUI.ELLESMERE_GREEN or eg
            lbl:SetTextColor(c.r, c.g, c.b, lerp(0.7, 1, t))
        end
        local function OnUpdate(self, elapsed)
            local dir = (target == 1) and 1 or -1
            progress = progress + dir * (elapsed / FADE_DUR)
            if (dir == 1 and progress >= 1) or (dir == -1 and progress <= 0) then
                progress = target; self:SetScript("OnUpdate", nil)
            end
            Apply(progress)
        end
        btn:SetScript("OnEnter", function(self) target = 1; self:SetScript("OnUpdate", OnUpdate) end)
        btn:SetScript("OnLeave", function(self) target = 0; self:SetScript("OnUpdate", OnUpdate) end)
        btn:SetScript("OnClick", function() ns.RequestClose(true) end)
        UM.hudFrame._saveBtn = btn
    end

    ---------------------------------------------------------------
    --  Banner Scale +/- Buttons: far left (-) and far right (+) of the banner.
    --  Scale range 100%-150% in 10% steps. Saved to EllesmereUIDB.unlockBannerScale.
    ---------------------------------------------------------------
    do
        local SCALE_MIN = 1.0
        local SCALE_MAX = 1.5
        local SCALE_STEP = 0.1
        local DISABLED_R, DISABLED_G, DISABLED_B = 0.35, 0.35, 0.35
        local NORMAL_R, NORMAL_G, NORMAL_B = 1, 1, 1
        local HOVER_R, HOVER_G, HOVER_B = 1, 1, 1
        local NORMAL_A = 0.50
        local HOVER_A  = 0.90
        local FONT_SZ  = 26

        -- Load saved banner scale
        local bannerUserScale = 1.0
        if EllesmereUIDB and EllesmereUIDB.unlockBannerScale then
            bannerUserScale = EllesmereUIDB.unlockBannerScale
            if bannerUserScale < SCALE_MIN then bannerUserScale = SCALE_MIN end
            if bannerUserScale > SCALE_MAX then bannerUserScale = SCALE_MAX end
        end

        -- Apply initial scale (uiScale * userScale)
        UM.hudFrame:SetScale(uiScale * bannerUserScale)

        local minusBtn, plusBtn  -- forward refs for cross-refresh

        local function RefreshScaleBtns()
            local atMin = bannerUserScale <= SCALE_MIN + 0.001
            local atMax = bannerUserScale >= SCALE_MAX - 0.001
            if atMin then
                minusBtn._shadow:SetTextColor(DISABLED_R, DISABLED_G, DISABLED_B, NORMAL_A * 0.6)
                minusBtn._label:SetTextColor(DISABLED_R, DISABLED_G, DISABLED_B, NORMAL_A)
                minusBtn:EnableMouse(true)  -- still catch hover for tooltip
                minusBtn._isDisabled = true
            else
                minusBtn._shadow:SetTextColor(0, 0, 0, NORMAL_A)
                minusBtn._label:SetTextColor(NORMAL_R, NORMAL_G, NORMAL_B, NORMAL_A)
                minusBtn._isDisabled = false
            end
            if atMax then
                plusBtn._shadow:SetTextColor(DISABLED_R, DISABLED_G, DISABLED_B, NORMAL_A * 0.6)
                plusBtn._label:SetTextColor(DISABLED_R, DISABLED_G, DISABLED_B, NORMAL_A)
                plusBtn:EnableMouse(true)
                plusBtn._isDisabled = true
            else
                plusBtn._shadow:SetTextColor(0, 0, 0, NORMAL_A)
                plusBtn._label:SetTextColor(NORMAL_R, NORMAL_G, NORMAL_B, NORMAL_A)
                plusBtn._isDisabled = false
            end
        end

        local function ApplyBannerScale(newScale)
            newScale = max(SCALE_MIN, min(SCALE_MAX, newScale))
            bannerUserScale = newScale
            if EllesmereUIDB then EllesmereUIDB.unlockBannerScale = newScale end
            UM.hudFrame:SetScale(uiScale * newScale)
            -- Keep flush with top of screen
            UM.hudFrame:ClearAllPoints()
            UM.hudFrame:SetPoint("TOP", UIParent, "TOP", 0, 0)
            -- Resize hover zone to match new scale
            if UM.hudFrame._hoverZone then
                UM.hudFrame._hoverZone:SetHeight(60 * uiScale * newScale)
            end
            RefreshScaleBtns()
        end

        -- Helper: create a text button with drop shadow
        local function MakeScaleBtn(text, anchorPoint, anchorTo, anchorRel, xOff, yOff)
            local btn = CreateFrame("Button", nil, UM.hudFrame)
            btn:SetSize(30, 30)
            btn:SetPoint(anchorPoint, anchorTo, anchorRel, xOff, yOff)
            btn:SetFrameLevel(UM.hudFrame:GetFrameLevel() + 3)

            -- Drop shadow (offset 1px down-right)
            local shadow = btn:CreateFontString(nil, "ARTWORK")
            shadow:SetFont(FONT_PATH, FONT_SZ, "")
            shadow:SetPoint("CENTER", btn, "CENTER", 1, -1)
            shadow:SetText(EllesmereUI.L(text))
            shadow:SetTextColor(0, 0, 0, NORMAL_A)
            btn._shadow = shadow

            -- Main text
            local label = btn:CreateFontString(nil, "OVERLAY")
            label:SetFont(FONT_PATH, FONT_SZ, "")
            label:SetPoint("CENTER", btn, "CENTER", 0, 0)
            label:SetText(EllesmereUI.L(text))
            label:SetTextColor(NORMAL_R, NORMAL_G, NORMAL_B, NORMAL_A)
            btn._label = label

            btn._isDisabled = false

            btn:SetScript("OnEnter", function(self)
                if self._isDisabled then return end
                self._shadow:SetTextColor(0, 0, 0, HOVER_A)
                self._label:SetTextColor(HOVER_R, HOVER_G, HOVER_B, HOVER_A)
            end)
            btn:SetScript("OnLeave", function(self)
                if self._isDisabled then return end
                self._shadow:SetTextColor(0, 0, 0, NORMAL_A)
                self._label:SetTextColor(NORMAL_R, NORMAL_G, NORMAL_B, NORMAL_A)
            end)

            return btn
        end

        -- Minus button (10px left of the Exit button, outer side)
        minusBtn = MakeScaleBtn("\226\128\147", "RIGHT", exitBtn, "LEFT", -10, 0)
        minusBtn:SetScript("OnClick", function(self)
            if self._isDisabled then return end
            ApplyBannerScale(bannerUserScale - SCALE_STEP)
        end)

        -- Plus button (10px right of the Save & Exit button, outer side)
        plusBtn = MakeScaleBtn("+", "LEFT", UM.hudFrame._saveBtn, "RIGHT", 10, 0)
        plusBtn:SetScript("OnClick", function(self)
            if self._isDisabled then return end
            ApplyBannerScale(bannerUserScale + SCALE_STEP)
        end)

        UM.hudFrame._minusBtn = minusBtn
        UM.hudFrame._plusBtn = plusBtn
        UM.hudFrame._applyBannerScale = ApplyBannerScale

        RefreshScaleBtns()
    end

    ---------------------------------------------------------------
    --  Hover-bar logic: when hoverBarEnabled, the banner + all children fade out
    --  unless the cursor is in a 1144x60 zone at the top of the screen. Fade = 0.5s.
    --  Holding Shift fades the bar out in ANY mode so elements beneath it can
    --  be seen and clicked; releasing Shift brings it straight back.
    ---------------------------------------------------------------
    local HOVER_ZONE_H = 60
    local HOVER_FADE = 0.5
    local SHIFT_FADE = 0.15
    local hoverAlpha = 1  -- current fade alpha (1 = fully visible)

    -- Invisible hover detection zone (parented to UIParent, not hudFrame,
    -- so it's always accessible even when hudFrame alpha is 0)
    local hoverZone = CreateFrame("Frame", nil, parent)
    hoverZone:SetFrameStrata("FULLSCREEN_DIALOG")
    hoverZone:SetFrameLevel(parent:GetFrameLevel() + 56)
    hoverZone:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
    hoverZone:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", 0, 0)
    hoverZone:SetHeight(HOVER_ZONE_H * (UM.hudFrame:GetScale() or uiScale))
    hoverZone:EnableMouse(false)  -- doesn't block clicks
    hoverZone:Hide()
    UM.hudFrame._hoverZone = hoverZone

    -- Every mouse-interactive banner child. Mouse is cut while Shift-hidden so
    -- the invisible buttons can't eat clicks meant for elements under the bar.
    local hudMouseKids = {
        UM.hudFrame._gridBtn, UM.hudFrame._darkOverlayBtn, UM.hudFrame._flashBtn,
        UM.hudFrame._magnetBtn, UM.hudFrame._coordBtn, UM.hudFrame._hoverBtn,
        UM.hudFrame._exitBtn, UM.hudFrame._saveBtn, UM.hudFrame._minusBtn, UM.hudFrame._plusBtn,
    }
    local shiftMouseCut = false

    UM.hudFrame:SetScript("OnUpdate", function(self, dt)
        -- Hold Shift: temporarily hide the top bar (works in both modes)
        local shiftHeld = IsShiftKeyDown()
        if shiftHeld ~= shiftMouseCut then
            shiftMouseCut = shiftHeld
            for i = 1, #hudMouseKids do
                local kid = hudMouseKids[i]
                if shiftHeld then
                    -- EnableMouse(false) does not fire OnLeave on a frame the
                    -- cursor is already over; reset hover visuals explicitly
                    -- so no button sticks in its highlighted state.
                    local leave = kid:GetScript("OnLeave")
                    if leave then leave(kid) end
                end
                kid:EnableMouse(not shiftHeld)
            end
        end
        if shiftHeld then
            -- Push-through, no change guard: unlock entry force-sets frame
            -- alpha to 1 while hoverAlpha can still be 0 from a close that
            -- happened with Shift held; a guarded write would strand the
            -- banner visible with its buttons mouse-dead.
            hoverAlpha = max(0, hoverAlpha - dt / SHIFT_FADE)
            self:SetAlpha(hoverAlpha)
            if not hoverBarEnabled then hoverZone:Hide() end
            return
        end

        if not hoverBarEnabled then
            -- Not in hover mode -- ensure full alpha
            if hoverAlpha < 1 then
                hoverAlpha = 1
                self:SetAlpha(1)
            end
            hoverZone:Hide()
            return
        end

        hoverZone:Show()

        -- Check if cursor is within the hover zone (top of screen)
        local scale = UIParent:GetEffectiveScale()
        local _, cy = GetCursorPosition()
        cy = cy / scale
        local screenH = UIParent:GetHeight()
        local zoneBot = screenH - (HOVER_ZONE_H * (UM.hudFrame:GetScale() or uiScale))
        local inZone = (cy >= zoneBot)

        if inZone then
            hoverAlpha = min(1, hoverAlpha + dt / HOVER_FADE)
        else
            hoverAlpha = max(0, hoverAlpha - dt / HOVER_FADE)
        end
        self:SetAlpha(hoverAlpha)
    end)

    UM.hudFrame:Hide()
    return UM.hudFrame
end

-------------------------------------------------------------------------------
--  Save / Revert / Close helpers
-------------------------------------------------------------------------------

-- Snapshot current bar positions when entering unlock mode
local function SnapshotPositions()
    wipe(snapshotPositions)
    -- Action bars: capture from barPositions DB
    local db = UM.GetPositionDB()
    if db then
        for barKey, pos in pairs(db) do
            snapshotPositions[barKey] = { point = pos.point, relPoint = pos.relPoint, x = pos.x, y = pos.y }
        end
    end
    -- Action bars: for any bar that has NO saved position, capture its live position
    for _, barKey in ipairs(ALL_BAR_ORDER) do
        if not snapshotPositions[barKey] then
            local bar = UM.GetBarFrame(barKey)
            if bar then
                local nPts = bar:GetNumPoints()
                if nPts and nPts > 0 then
                    local point, _, relPoint, x, y = bar:GetPoint(1)
                    if point then
                        snapshotPositions[barKey] = { point = point, relPoint = relPoint, x = x, y = y }
                    end
                end
            end
        end
    end
    -- Registered elements: snapshot via loadPosition or live frame position
    RebuildRegisteredOrder()
    for _, key in ipairs(registeredOrder) do
        if not snapshotPositions[key] then
            local elem = registeredElements[key]
            if elem then
                local pos = elem.loadPosition and elem.loadPosition(key)
                if pos then
                    snapshotPositions[key] = { point = pos.point, relPoint = pos.relPoint or pos.point, x = pos.x, y = pos.y }
                else
                    local fr = elem.getFrame and elem.getFrame(key)
                    if fr then
                        local nPts = fr:GetNumPoints()
                        if nPts and nPts > 0 then
                            local point, _, relPoint, x, y = fr:GetPoint(1)
                            if point then
                                -- relPoint may be a frame object here (not a string) if anchored to
                                -- a parent frame rather than UIParent; mark this snapshot so RevertPositions skips writing it to SavedVariables.
                                snapshotPositions[key] = { point = point, relPoint = relPoint, x = x, y = y, _fromLiveFrame = true }
                            end
                        end
                    end
                end
            end
        end
    end

    -- Snapshot anchor data so we can revert on discard (includes the
    -- growth-edge pin fields; losing them on cancel would force a lazy
    -- recapture from whatever position the session left the bar at)
    wipe(snapshotAnchors)
    local anchorDB = GetAnchorDB()
    if anchorDB then
        for childKey, info in pairs(anchorDB) do
            snapshotAnchors[childKey] = {
                target = info.target, side = info.side,
                offsetX = info.offsetX, offsetY = info.offsetY,
                refX = info.refX, refY = info.refY,
                edgeOffX = info.edgeOffX, edgeOffY = info.edgeOffY,
                refFor = info.refFor,
                -- COPY, not a reference: _NudgeSelectedFallbackGhost mutates
                -- fb.offsetX/offsetY in place, so a shared table would drag the
                -- snapshot along with the edit and make the revert a no-op. The
                -- cross-axis edge is nudged in place too, so it copies as well.
                fallback = info.fallback and CopyTable(info.fallback) or nil,
                edge = info.edge and CopyTable(info.edge) or nil,
            }
        end
    end

    -- Snapshot element sizes so we can revert width/height changes on discard
    wipe(snapshotSizes)
    for _, key in ipairs(registeredOrder) do
        local elem = registeredElements[key]
        if elem and elem.getSize then
            local w, h = elem.getSize(key)
            if w and h then
                snapshotSizes[key] = { w = w, h = h }
            end
        end
    end

    -- Snapshot width/height match DBs so we can revert on discard
    wipe(snapshotWidthMatch)
    wipe(snapshotHeightMatch)
    local wmDB = MatchH.GetWidthMatchDB()
    if wmDB then
        for k, v in pairs(wmDB) do snapshotWidthMatch[k] = v end
    end
    local hmDB = MatchH.GetHeightMatchDB()
    if hmDB then
        for k, v in pairs(hmDB) do snapshotHeightMatch[k] = v end
    end
    -- ...and each match's Extra Width / Height, reverted with its link.
    local sx = MatchH.snapExtra
    wipe(sx.w)
    wipe(sx.h)
    local wxDB = EllesmereUIDB and EllesmereUIDB.unlockWidthMatchExtra
    if wxDB then
        for k, v in pairs(wxDB) do sx.w[k] = v end
    end
    local hxDB = EllesmereUIDB and EllesmereUIDB.unlockHeightMatchExtra
    if hxDB then
        for k, v in pairs(hxDB) do sx.h[k] = v end
    end

    -- Snapshot growth directions so we can revert on discard
    wipe(snapshotGrowDirs)
    local cdm = EllesmereUI.Lite.GetAddon("EllesmereUICooldownManager", true)
    local cdmBars = cdm and cdm.db and cdm.db.profile and cdm.db.profile.cdmBars
    if cdmBars and cdmBars.bars then
        for _, bar in ipairs(cdmBars.bars) do
            -- bar.key guard: ghost bars (keyless skeletons from stale
            -- override writes) have nothing to snapshot.
            if bar.key then
                snapshotGrowDirs["CDM_" .. bar.key] = bar.growDirection or false
            end
        end
    end
    local eab = EllesmereUI.Lite.GetAddon("EllesmereUIActionBars", true)
    local abBars = eab and eab.db and eab.db.profile and eab.db.profile.bars
    if abBars then
        local abGrowKeys = { MainBar=1, Bar2=1, Bar3=1, Bar4=1, Bar5=1, Bar6=1, Bar7=1, Bar8=1 }
        for bk, cfg in pairs(abBars) do
            if abGrowKeys[bk] then
                snapshotGrowDirs[bk] = cfg.growDirection or false
            end
        end
    end

    -- Raw pre-session position entries for CDM/AB bars: verbatim saved edges
    -- including the tgt* follow baselines. The snapshotPositions entries above are
    -- center-converted and LOSSY for edge-preserving grow bars (a restored
    -- CENTER-format saved edge can't pin, so the bar stays wherever it currently
    -- sits). Spec-override baseline capture prefers these raw copies. Namespace
    -- table: this body is inside the deferred-init closure, at the 200-local cap.
    local rawSnap = {}
    EllesmereUI._unlockSnapRawPos = rawSnap
    local cdmPos = cdm and cdm.db and cdm.db.profile and cdm.db.profile.cdmBarPositions
    if cdmPos and cdmBars and cdmBars.bars then
        for _, bar in ipairs(cdmBars.bars) do
            local e = cdmPos[bar.key]
            if e then rawSnap["CDM_" .. bar.key] = CopyTable(e) end
        end
    end
    local abPos = UM.GetPositionDB()
    if abPos and EllesmereUI._abBarKeys then
        for bk in pairs(EllesmereUI._abBarKeys) do
            local e = abPos[bk]
            if e then rawSnap[bk] = CopyTable(e) end
        end
    end
end

-------------------------------------------------------------------------------
--  Unlock spec-overrides: session visuals + Save & Exit routing. Gold border =
--  this element carries an unlock override for the active edit context (the
--  special group's entry, or the current spec's owning group in a normal
--  session). Red lock = element can't be edited in the special session (owned by a spec-sharing group, or a blocked subsystem).
-------------------------------------------------------------------------------
do
    local specOvBanner
    local function UpdateSpecOvBanner()
        local g = EllesmereUI._specialUnlockGroup
        if not g or not UM.unlockFrame then
            if specOvBanner then specOvBanner:Hide() end
            return
        end
        if not specOvBanner then
            specOvBanner = CreateFrame("Frame", nil, UM.unlockFrame)
            specOvBanner:SetFrameLevel(UM.unlockFrame:GetFrameLevel() + 60)
            specOvBanner:SetHeight(28)
            specOvBanner:SetPoint("TOP", UM.unlockFrame, "TOP", 0, -64)
            local bg = specOvBanner:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetColorTexture(0.16, 0.12, 0.04, 0.92)
            EllesmereUI.MakeBorder(specOvBanner, 199/255, 166/255, 90/255, 0.7)
            local fs = specOvBanner:CreateFontString(nil, "OVERLAY")
            fs:SetFont(FONT_PATH, 12, "OUTLINE, SLUG")
            fs:SetPoint("CENTER")
            fs:SetTextColor(1, 0.88, 0.55, 1)
            specOvBanner._text = fs
        end
        specOvBanner._text:SetText(string.format(
            EllesmereUI.L("Customizing Unlock Mode: %s (changes apply only to this group's specs)"),
            g.name or "?"))
        specOvBanner:SetWidth((specOvBanner._text:GetStringWidth() or 200) + 28)
        specOvBanner:Show()
    end

    -- Layer model: a custom unlock mode is a whole-layout fork, so there are no
    -- per-element gold marks or conflict locks anymore -- the gold frame variant
    -- and this banner carry the state; this refresh keeps the banner current and hides stale per-element markers on pooled movers.
    EllesmereUI._unlockRefreshSpecOvMarks = function()
        UpdateSpecOvBanner()
        for _, m in pairs(movers) do
            if m._specOvBrd then m._specOvBrd:Hide() end
            if m._specOvLock then m._specOvLock:Hide() end
        end
    end
end

-- Commit pending positions to SavedVariables
local function CommitPositions()
    -- Suppress per-save rebuilds (e.g. CDM's BuildAllCDMBars) so that
    -- all positions are written first, then a single rebuild runs at the end.
    EllesmereUI._propagatingSave = true
    for barKey, pos in pairs(pendingPositions) do
        if pos == "RESET" then
            ClearBarPosition(barKey)
        else
            local elem = registeredElements[barKey]
            local pt, rpt, px, py = pos.point, pos.relPoint, pos.x, pos.y
            -- Anchor-cascade marker: ApplyAnchorPosition repositioned this bar during
            -- the session (e.g. its anchor target was dragged) but the entry carries no
            -- coords. The open-time snapshot below is STALE for it: saving that would
            -- pair a pre-move growth edge with the post-move target baselines savePos
            -- captures, and the bar snaps to the stale edge on save. Resolve from the
            -- bar's LIVE bounds instead -- ConvertToCenterPos prefers them and returns
            -- the exact CENTER/CENTER convention SaveBarPosition expects. Bars a cascade
            -- reapplied without actually moving resolve to the same snapshot position.
            if elem and not pt and pos._anchored then
                local liveBar = UM.GetBarFrame(barKey)
                if liveBar and liveBar:GetLeft() and liveBar:GetRight()
                   and liveBar:GetTop() and liveBar:GetBottom() then
                    pt, rpt, px, py = ConvertToCenterPos(barKey, "TOPLEFT", "TOPLEFT", 0, 0)
                end
            end
            -- If position wasn't dragged, fill from snapshot
            if elem and not pt then
                local snap = snapshotPositions[barKey]
                if snap then
                    pt, rpt, px, py = snap.point, snap.relPoint or snap.point, snap.x, snap.y
                else
                    -- Fallback: read from loadPosition
                    local lp = elem.loadPosition and elem.loadPosition(barKey)
                    if lp then
                        pt, rpt, px, py = lp.point, lp.relPoint or lp.point, lp.x, lp.y
                    end
                end
            end
            UM.SaveBarPosition(barKey, pt, rpt, px, py)
            -- Install anchor guard for action bar positions
            if not elem then
                local bar = UM.GetBarFrame(barKey)
                if bar then InstallAnchorGuard(bar, barKey) end
            end
        end
    end
    EllesmereUI._propagatingSave = false

    -- Force edge-preservation across the save rebuild + reapply below. These run
    -- while isUnlocked is still true (DoClose clears it only AFTER CommitPositions
    -- returns), so without this flag ApplyAnchorPosition skips its absolute
    -- saved-edge branch and places anchored custom-growth CDM bars from the anchor
    -- offset + live width instead -- if the rebuild changed a bar's width, the
    -- growth edge lands off the freshly-saved edge and the bar visibly snaps back
    -- until /reload. Setting the flag makes both passes read cdmBarPositions
    -- exactly like the login/reload apply. Mirrors OpenUnlockMode's entry reapply; pcall-wrapped and reset in all cases so it can never leak.
    EllesmereUI._reapplyForceEdgePreserve = true

    -- Single rebuild now that all positions are committed.
    -- CDM savePos normally calls BuildAllCDMBars per save, but we
    -- suppressed that above to avoid partial-state rebuilds.
    for barKey in pairs(pendingPositions) do
        if type(barKey) == "string" and barKey:sub(1, 4) == "CDM_" then
            local elem = registeredElements[barKey]
            if elem and elem.applyPosition then
                pcall(elem.applyPosition, barKey)
            end
            break  -- one rebuild is enough, it rebuilds all bars
        end
    end

    -- Reapply anchor positions for all anchored bars so they move from the stale CENTER
    -- coords (saved by CommitPositions) to their correct anchor-relative position
    -- immediately. Without this, anchored bars sit at stale coords until a deferred
    -- ScheduleAnchorBatch corrects them, causing a visible jump on the next resize.
    if EllesmereUI.ReapplyAllUnlockAnchorsForced then
        pcall(EllesmereUI.ReapplyAllUnlockAnchorsForced)
    end

    EllesmereUI._reapplyForceEdgePreserve = false

    -- Persist unlock layout into the active profile so it survives reloads
    -- without requiring a manual profile switch.
    if EllesmereUIDB and EllesmereUI.GetProfilesDB then
        local pdb = EllesmereUI.GetProfilesDB()
        local activeName = pdb.activeProfile or "Default"
        local profileData = pdb.profiles and pdb.profiles[activeName]
        if profileData then
            local snap = {
                anchors       = CopyTable(EllesmereUIDB.unlockAnchors     or {}),
                widthMatch    = CopyTable(EllesmereUIDB.unlockWidthMatch  or {}),
                heightMatch   = CopyTable(EllesmereUIDB.unlockHeightMatch or {}),
                widthMatchExtra  = CopyTable(EllesmereUIDB.unlockWidthMatchExtra  or {}),
                heightMatchExtra = CopyTable(EllesmereUIDB.unlockHeightMatchExtra or {}),
                phantomBounds = CopyTable(EllesmereUIDB.phantomBounds     or {}),
            }
            -- While a spec-override unlock LAYER is live, the profile
            -- snapshot must carry the shared BASELINE links, not the live
            -- (group-valued) globals; the stored baseline layout provides
            -- them. When the baseline itself is live, live is the source.
            if EllesmereUI.SpecOverrides_UnlockBaselineLinks then
                local ba, bw, bh = EllesmereUI.SpecOverrides_UnlockBaselineLinks()
                if ba then
                    snap.anchors     = CopyTable(ba)
                    snap.widthMatch  = CopyTable(bw)
                    snap.heightMatch = CopyTable(bh)
                    -- The baseline's match extras ride with its links (4th and
                    -- 5th returns); a baseline without extras carries none.
                    local _, _, _, bwx, bhx = EllesmereUI.SpecOverrides_UnlockBaselineLinks()
                    snap.widthMatchExtra  = CopyTable(bwx or {})
                    snap.heightMatchExtra = CopyTable(bhx or {})
                end
            end
            profileData.unlockLayout = snap
        end
    end
    -- The active spec's tracked buff bar links and extras into their spec bucket,
    -- so a profile restore before the next bar build cannot swap older ones in.
    if EllesmereUI._TBBBankUnlockLinks then EllesmereUI._TBBBankUnlockLinks() end

    -- Bank CAPTURED settings the session edited (cog size inputs) into
    -- values.default -- a normal unlock session edits the shared baseline, exactly
    -- like the panel's Default Editing Mode. Without this the next value apply
    -- reverts the user's unlock-mode resize (the sticky harvest deliberately never adopts foreign live diffs).
    if EllesmereUI.SpecOverrides_UnlockValueSnapCommit then
        pcall(EllesmereUI.SpecOverrides_UnlockValueSnapCommit)
    end

    -- Bank the freshly-saved live layout into its owning spec-override layer (the
    -- active group layer, else the stored baseline). Wholesale harvest -- no
    -- per-aspect routing exists. true = user commit: banks even inside the post-import suppression window (and closes it).
    if EllesmereUI.SpecOverrides_HarvestUnlockLayout then
        local okH, errH = pcall(EllesmereUI.SpecOverrides_HarvestUnlockLayout, true)
        if not okH then
            print("|cffff6060[EllesmereUI]|r Unlock layer harvest failed: "
                .. tostring(errH))
        end
    end
end

-- Revert bars to their snapshot positions (discard all pending changes)
local function RevertPositions()
    if InCombatLockdown() then return end

    -- Cancel: unlock-session value edits are discarded too (the module store may
    -- keep the cog-edited size until the next value apply restores the recorded default -- correct for a discard).
    if EllesmereUI.SpecOverrides_UnlockValueSnapDiscard then
        EllesmereUI.SpecOverrides_UnlockValueSnapDiscard()
    end

    -- 1) Restore all DB state from snapshots (suppress rebuilds)
    EllesmereUI._propagatingSave = true

    local db = UM.GetPositionDB()
    if db then
        for barKey, _ in pairs(pendingPositions) do
            if not registeredElements[barKey] then
                -- Prefer the verbatim pre-session entry (saved edge PLUS the tgt*
                -- follow baselines): the coordinate-only snapshot would strip the baselines from grow bars on every cancel, costing a bless cycle before target-follow works again.
                local rawSnap = EllesmereUI._unlockSnapRawPos
                    and EllesmereUI._unlockSnapRawPos[barKey]
                local snap = snapshotPositions[barKey]
                if rawSnap then
                    db[barKey] = CopyTable(rawSnap)
                elseif snap then
                    db[barKey] = { point = snap.point, relPoint = snap.relPoint, x = snap.x, y = snap.y }
                else
                    db[barKey] = nil
                end
            end
        end
    end

    for barKey, _ in pairs(pendingPositions) do
        local elem = registeredElements[barKey]
        if elem and elem.savePosition then
            local snap = snapshotPositions[barKey]
            if snap and not snap._fromLiveFrame then
                elem.savePosition(barKey, snap.point, snap.relPoint or snap.point, snap.x, snap.y)
            end
        end
    end

    EllesmereUI._propagatingSave = false

    -- 2) Restore anchor data before repositioning
    local anchorDB = GetAnchorDB()
    if anchorDB then
        -- fallback rides the snapshot (copied both ways), so pre-session
        -- fallbacks survive the revert and session edits discard with it.
        wipe(anchorDB)
        for childKey, info in pairs(snapshotAnchors) do
            anchorDB[childKey] = {
                target = info.target, side = info.side,
                offsetX = info.offsetX, offsetY = info.offsetY,
                refX = info.refX, refY = info.refY,
                edgeOffX = info.edgeOffX, edgeOffY = info.edgeOffY,
                refFor = info.refFor,
                edge = info.edge and CopyTable(info.edge) or nil,
                -- Restored from the snapshot, so a fallback MOVED this session
                -- reverts like every other position. Fresh copy so the next
                -- session's nudges cannot reach back into the snapshot.
                fallback = info.fallback and CopyTable(info.fallback) or nil,
            }
        end
    end

    -- 3) Restore element sizes
    for key, snap in pairs(snapshotSizes) do
        local elem = registeredElements[key]
        if elem then
            if elem.setWidth and snap.w then
                pcall(elem.setWidth, key, snap.w)
            end
            if elem.setHeight and snap.h then
                pcall(elem.setHeight, key, snap.h)
            end
        end
    end

    -- 4) Restore width/height match DBs
    local wmDB = MatchH.GetWidthMatchDB()
    if wmDB then
        wipe(wmDB)
        for k, v in pairs(snapshotWidthMatch) do wmDB[k] = v end
    end
    local hmDB = MatchH.GetHeightMatchDB()
    if hmDB then
        wipe(hmDB)
        for k, v in pairs(snapshotHeightMatch) do hmDB[k] = v end
    end
    -- Each match's Extra Width / Height, in the same step as its link. A CDM bar
    -- reads both live (its setWidth only re-lays it out) and step 6 rebuilds only
    -- bars that moved, so a bar whose extra the restore changes is re-laid out here.
    if EllesmereUIDB then
        local sx = MatchH.snapExtra
        local relayout
        local function Note(live, snap)
            if live then
                for k, v in pairs(live) do
                    if snap[k] ~= v and k:sub(1, 4) == "CDM_" then
                        relayout = relayout or {}; relayout[k] = true
                    end
                end
            end
            for k, v in pairs(snap) do
                if not (live and live[k] == v) and k:sub(1, 4) == "CDM_" then
                    relayout = relayout or {}; relayout[k] = true
                end
            end
        end
        Note(EllesmereUIDB.unlockWidthMatchExtra, sx.w)
        Note(EllesmereUIDB.unlockHeightMatchExtra, sx.h)
        if EllesmereUIDB.unlockWidthMatchExtra then wipe(EllesmereUIDB.unlockWidthMatchExtra) end
        for k, v in pairs(sx.w) do MatchH.SetMatchExtra("w", k, v) end
        if EllesmereUIDB.unlockHeightMatchExtra then wipe(EllesmereUIDB.unlockHeightMatchExtra) end
        for k, v in pairs(sx.h) do MatchH.SetMatchExtra("h", k, v) end
        if relayout then
            for k in pairs(relayout) do
                local e = registeredElements[k]
                if e and e.setWidth then pcall(e.setWidth, k) end
            end
        end
    end

    -- 5) Restore growth directions
    for key, snapGrow in pairs(snapshotGrowDirs) do
        local val = snapGrow == false and nil or snapGrow
        if key:sub(1, 4) == "CDM_" then
            local rawKey = key:sub(5)
            local cdmA = EllesmereUI.Lite.GetAddon("EllesmereUICooldownManager", true)
            local cdmB = cdmA and cdmA.db and cdmA.db.profile and cdmA.db.profile.cdmBars
            if cdmB and cdmB.bars then
                for _, bar in ipairs(cdmB.bars) do
                    if bar.key == rawKey then bar.growDirection = val; break end
                end
            end
        else
            local eabA = EllesmereUI.Lite.GetAddon("EllesmereUIActionBars", true)
            local abB = eabA and eabA.db and eabA.db.profile and eabA.db.profile.bars
            if abB and abB[key] then abB[key].growDirection = val end
        end
    end

    -- 6) Rebuild CDM bars so they read the restored DB and position correctly.
    -- Without this, CDM bars revert to wrong positions (CENTER vs edge mismatch).
    local didCDMRebuild = false
    for barKey in pairs(pendingPositions) do
        if not didCDMRebuild and type(barKey) == "string" and barKey:sub(1, 4) == "CDM_" then
            local elem = registeredElements[barKey]
            if elem and elem.applyPosition then
                pcall(elem.applyPosition, barKey)
            end
            didCDMRebuild = true
        end
    end

    -- 6) Reposition unanchored elements through normal path.
    -- Skip anchored elements -- step 7 handles them via ApplyAnchorPosition.
    for barKey, _ in pairs(pendingPositions) do
        local ai = anchorDB and anchorDB[barKey]
        if not (ai and ai.target) then
            local bar = UM.GetBarFrame(barKey)
            if bar then
                local snap = snapshotPositions[barKey]
                if snap and not snap._fromLiveFrame then
                    if not UM.ApplyCenterPosition(barKey, snap) then
                        pcall(function()
                            bar:ClearAllPoints()
                            bar:SetPoint(snap.point, UIParent, snap.relPoint, snap.x, snap.y)
                        end)
                    end
                elseif bar.UpdateGridLayout then
                    pcall(bar.UpdateGridLayout, bar)
                end
            end
        end
    end

    -- 7) Reapply anchor positions for anchored elements. Force edge preservation
    -- across the pass: this runs while isUnlocked is still true, and without the
    -- flag ApplyAnchorPosition skips its absolute saved-edge branch and places
    -- anchored custom-growth bars (StanceBar, CDM grow bars) from their center
    -- offsets + live width instead of the just-restored saved edge -- the bar
    -- visibly snaps off its reverted position. Mirrors the CommitPositions fix.
    if anchorDB then
        EllesmereUI._reapplyForceEdgePreserve = true
        for childKey, info in pairs(anchorDB) do
            if info.target and UM.GetBarFrame(childKey) and UM.GetBarFrame(info.target) then
                pcall(UM.ApplyAnchorPosition, childKey, info.target, info.side)
            end
        end
        EllesmereUI._reapplyForceEdgePreserve = false
    end
end

local pendingAfterClose        -- callback to run after DoClose completes
local cogHoveredMover = nil    -- the mover whose cog button is currently hovered

-- Internal close (actually hides everything and returns to options)
local function DoClose(closeAction)
    if not UM.isUnlocked then return end
    UM.isUnlocked = false
    EllesmereUI._unlockActive = false
    EllesmereUI._unlockModeActive = false
    EllesmereUI:_NotifyUnlockModeListeners(false, closeAction or "exit")
    if EllesmereUI._HideFallbackGhosts then EllesmereUI._HideFallbackGhosts() end
    if EllesmereUI._HideOverrideGhosts then EllesmereUI._HideOverrideGhosts() end
    -- Re-engage override anchors now that isUnlocked is false (the settle's
    -- position pass is the belt; this is deterministic and immediate).
    if EllesmereUI._ReapplyOverrideAnchors then EllesmereUI._ReapplyOverrideAnchors() end

    -- Notify action bars to restore Blizzard-owned frame anchors
    if _G._EAB_UnlockModeClose then pcall(_G._EAB_UnlockModeClose) end

    -- Recalculate action bar flyout directions after positions are finalized
    if _G._EAB_RecalcFlyouts then pcall(_G._EAB_RecalcFlyouts) end

    -- Notify beacon reminders to restore (if follow-mouse is active)
    if _G._EABR_BeaconRefresh then pcall(_G._EABR_BeaconRefresh) end

    -- Restore expandIfNoResource after unlock mode finishes
    if _G._ERB_RestoreExpand then pcall(_G._ERB_RestoreExpand) end
    -- Re-apply the anchor-target shifts after unlock mode finishes. Independent of
    -- expand restore (which early-returns when expand was never suppressed); runs
    -- after _unlockActive is cleared above so the providers return non-zero and
    -- PropagateAnchorChain is no longer a no-op. Each provider gates itself so
    -- None = no work.
    EllesmereUI.RestoreAnchorShifts()

    -- Restore unit frame buffs/debuffs
    local UF_FRAME_NAMES = {
        "EllesmereUIUnitFrames_Player", "EllesmereUIUnitFrames_Target",
        "EllesmereUIUnitFrames_Focus", "EllesmereUIUnitFrames_Pet",
        "EllesmereUIUnitFrames_TargetTarget", "EllesmereUIUnitFrames_FocusTarget",
    }
    for i = 1, 8 do UF_FRAME_NAMES[#UF_FRAME_NAMES + 1] = "EllesmereUIUnitFrames_Boss" .. i end
    for _, name in ipairs(UF_FRAME_NAMES) do
        local f = _G[name]
        if f then
            if f.Buffs and f.Buffs._unlockWasShown then
                f.Buffs:Show()
                f.Buffs._unlockWasShown = nil
            end
            if f.Debuffs and f.Debuffs._unlockWasShown then
                f.Debuffs:Show()
                f.Debuffs._unlockWasShown = nil
            end
        end
    end

    -- Restore objective tracker
    if UM.objTrackerWasVisible then
        local objTracker = _G.ObjectiveTrackerFrame
        if objTracker then
            objTracker:SetAlpha(1)
            local wasEnabled = objTracker._eabMouseWasEnabled
            if objTracker.EnableMouse then
                pcall(objTracker.EnableMouse, objTracker, wasEnabled and true or false)
            end
        end
        UM.objTrackerWasVisible = false
    end
    -- Restore EllesmereUI QT background
    local qtBg = _G.EllesmereUIQTBackground
    if qtBg then qtBg:SetAlpha(1) end
    -- Re-apply user visibility setting (handles "never" mode for both tracker + bg)
    if _G.EllesmereUIQuestTracker and _G.EllesmereUIQuestTracker.UpdateVisibility then
        _G.EllesmereUIQuestTracker.UpdateVisibility()
    end

    -- Re-check Dragon Riding's real visibility (it force-shows while unlocked
    -- so it can be edited off-mount; without this it stays stuck visible
    -- after exiting Unlock Mode if the player dismounted while unlocked).
    if _G._EDR_UpdateVisibility then pcall(_G._EDR_UpdateVisibility) end

    if not UM.unlockFrame then return end

    UM.unlockFrame:SetScript("OnUpdate", nil)
    if UM.logoFadeFrame then UM.logoFadeFrame:SetScript("OnUpdate", nil); UM.logoFadeFrame:Hide() end
    if UM.openAnimFrame then UM.openAnimFrame:Hide() end
    if lockAnimFrame then lockAnimFrame:Hide() end
    if UM.gridFrame then UM.gridFrame:SetScript("OnUpdate", nil); UM.gridFrame:Hide() end
    if UM.hudFrame then UM.hudFrame:Hide() end
    if UM.unlockTipFrame then UM.unlockTipFrame:SetScript("OnUpdate", nil); UM.unlockTipFrame:Hide() end
    if UM.unlockFrame._anchorLineDriver then UM.unlockFrame._anchorLineDriver:Hide() end
    if UM.unlockFrame._anchorLineFrame  then UM.unlockFrame._anchorLineFrame:Hide() end
    if UM.unlockFrame._clearAnchorLineAnim then UM.unlockFrame._clearAnchorLineAnim() end
    DeselectMover()
    -- Collapse any expanded mover so it doesn't stay stuck on re-enter
    UM.hoveredMover    = nil
    cogHoveredMover = nil
    EllesmereUI._unlockCursorSpeed = 0
    for _, m in pairs(movers) do
        m._snapTarget   = nil
        m._dragging     = false
        m._shiftAxis    = nil
        m._hoverPending = false
        -- Snap-collapse hover state so mover isn't stuck expanded on re-enter
        if m._forceCollapse then m._forceCollapse() end
        m:SetScript("OnUpdate", nil)
        m:Hide()
    end
    HideAllGuidesAndHighlight()
    HideBlizzOwnedOverlays()
    UM.unlockFrame:Hide()
    UM.unlockFrame:SetAlpha(1)

    -- Clean up arrow key nudge state
    UM.selectedMover = nil
    UM.selectElementPicker = nil
    if UM.arrowKeyFrame then UM.arrowKeyFrame:Hide() end

    -- Reset session state
    wipe(pendingPositions)
    wipe(snapshotPositions)
    wipe(snapshotAnchors)
    wipe(snapshotGrowDirs)
    UM.hasChanges = false

    -- End any special spec-override session and clear its mover marks (the
    -- banner is a child of unlockFrame, hidden with it above; the next
    -- session's mark refresh re-evaluates everything).
    EllesmereUI._specialUnlockGroup = nil
    for _, m in pairs(movers) do
        if m._specOvBrd then m._specOvBrd:Hide() end
        if m._specOvLock then m._specOvLock:Hide() end
    end

    -- Clean up pick mode / anchor dropdown state
    UM.pickMode = nil
    UM.pickModeMover = nil
    if UM.anchorDropdownFrame then UM.anchorDropdownFrame:Hide() end
    if UM.anchorDropdownCatcher then UM.anchorDropdownCatcher:Hide() end
    if UM.growDropdownFrame then UM.growDropdownFrame:Hide() end
    if UM.growDropdownCatcher then UM.growDropdownCatcher:Hide() end

    -- Restore action bar alpha from saved settings
    if EAB and EAB.RefreshMouseover and not InCombatLockdown() then
        EAB:RefreshMouseover()
    end

    -- Restore CDM bar visibility (unlock forced all bars visible)
    if _G._ECME_ApplyVisibility then _G._ECME_ApplyVisibility() end

    -- Restore panel scale and show options
    local panelRealScale
    do
        local physW = (GetPhysicalScreenSize())
        local baseScale = GetScreenWidth() / physW
        local userScale = (EllesmereUIDB and EllesmereUIDB.panelScale) or 1.0
        panelRealScale = baseScale * userScale
    end
    local panel = EllesmereUI and EllesmereUI._mainFrame
    if panel then panel:SetScale(panelRealScale); panel:SetAlpha(1) end
    -- If there's a pending after-close callback, skip the default panel restore
    -- (the callback will handle opening the panel to the right page)
    if not pendingAfterClose then
        if EllesmereUI then
            -- Restore the module + page active before unlock mode opened (captured
            -- by SelectPage("Unlock Mode") in EllesmereUI.lua). Do NOT show the panel
            -- yet -- SelectModule/SelectPage cause Hide->Show cycles on the page
            -- wrapper via HideAllChildren, and showing the panel first would add
            -- extra cycles that leave EditBox text blank. Set up the page while hidden, then show once at the end.
            local restoreModule = EllesmereUI._unlockReturnModule
            local restorePage   = EllesmereUI._unlockReturnPage
            EllesmereUI._unlockReturnPage = nil
            EllesmereUI._unlockReturnModule = nil
            if restoreModule then
                EllesmereUI:SelectModule(restoreModule)
                if restorePage and EllesmereUI.SelectPage then
                    local currentPage = EllesmereUI:GetActivePage()
                    if currentPage ~= restorePage then
                        EllesmereUI:SelectPage(restorePage)
                    end
                end
                -- NOW show the panel -- one clean Show, no prior cycling.
                EllesmereUI:Toggle()
            end
        end
    end

    -- Fire any pending after-close callback (e.g. from slash commands)
    if pendingAfterClose then
        EllesmereUI._unlockReturnPage = nil
        EllesmereUI._unlockReturnModule = nil
        local fn = pendingAfterClose
        pendingAfterClose = nil
        fn()
    end
end

-- Public close request: save=true commits, save=false may prompt
-- Optional afterFn runs after close completes (for slash command chaining)
function ns.RequestClose(save, afterFn)
    if afterFn then pendingAfterClose = afterFn end
    if save then
        CommitPositions()
        DoClose("save")
        return
    end
    -- No changes -> just exit
    if not UM.hasChanges then
        DoClose("exit")
        return
    end
    -- Has unsaved changes -> show confirm popup
    EllesmereUI:ShowConfirmPopup({
        title = "Unsaved Changes",
        message = "You have unsaved position changes.\nWhat would you like to do?",
        cancelText  = "Exit Without Saving",
        confirmText = "Save & Exit",
        onCancel = function()
            RevertPositions()
            DoClose("exit")
        end,
        onConfirm = function()
            CommitPositions()
            DoClose("save")
        end,
        -- Dismiss (ESC / click-off) does nothing -- user stays in unlock mode,
        -- and any pending close callback is cleared since the close was abandoned
        onDismiss = function()
            pendingAfterClose = nil
            -- Controller Back: stamp the dismiss so the same press's step skips
            if UM.unlockFrame and UM.unlockFrame._padEsc then UM.unlockFrame._padDismissAt = GetTime() end
        end,
    })
end

--- Force-closes unlock mode DISCARDING the session. Called by the profile system
--- on a spec transition: movers, snapshots, and pending edits all belong to the
--- OUTGOING spec's layout, so saving them against the incoming spec would corrupt both baseline and spec-override data.
function EllesmereUI.ForceCloseUnlockDiscard()
    if not UM.isUnlocked then return end
    print("|cffff6060[EllesmereUI]|r Spec changed: Unlock Mode closed, unsaved layout changes discarded.")
    pendingAfterClose = nil
    -- Unconditional: RevertPositions only runs below when positions changed,
    -- but the value-edit snapshot must never survive a discard-close.
    if EllesmereUI.SpecOverrides_UnlockValueSnapDiscard then
        EllesmereUI.SpecOverrides_UnlockValueSnapDiscard()
    end
    if UM.hasChanges then pcall(RevertPositions) end
    pcall(DoClose, "discard")
end

-------------------------------------------------------------------------------
--  Smooth easing function (ease-in-out cubic)
-------------------------------------------------------------------------------
local function EaseInOutCubic(t)
    if t < 0.5 then
        return 4 * t * t * t
    else
        local f = 2 * t - 2
        return 0.5 * f * f * f + 1
    end
end

-------------------------------------------------------------------------------
--  Open / Close Unlock Mode
-------------------------------------------------------------------------------
local function CreateUnlockFrame()
    if UM.unlockFrame then return UM.unlockFrame end

    UM.unlockFrame = CreateFrame("Frame", "EllesmereUnlockMode", UIParent)
    UM.unlockFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    UM.unlockFrame:SetAllPoints(UIParent)
    UM.unlockFrame:EnableMouse(false)  -- let clicks pass through to game world
    UM.unlockFrame:EnableKeyboard(true)

    -- Dark overlay background -- on a dedicated sub-frame so movers render ABOVE it
    local overlayFrame = CreateFrame("Frame", nil, UM.unlockFrame)
    overlayFrame:SetFrameLevel(UM.unlockFrame:GetFrameLevel() + 1)
    overlayFrame:SetAllPoints(UIParent)
    local overlay = overlayFrame:CreateTexture(nil, "BACKGROUND")
    overlay:SetAllPoints()
    overlay:SetColorTexture(0.02, 0.03, 0.04, 0.20)
    UM.unlockFrame._overlay = overlay
    UM.unlockFrame._overlayMaxAlpha = 0.20

    -- Anchor connector lines: accent-colored lines drawn center-to-center
    -- between each anchored child and its parent, rendered behind all elements.
    local anchorLinePool = {}
    local anchorPulsePool = {}
    local anchorLineFrame = CreateFrame("Frame", nil, UIParent)
    anchorLineFrame:SetFrameStrata("BACKGROUND")
    anchorLineFrame:SetFrameLevel(1)
    anchorLineFrame:SetAllPoints(UIParent)
    anchorLineFrame:EnableMouse(false)

    local function GetAnchorLine(idx)
        if anchorLinePool[idx] then return anchorLinePool[idx] end
        local line = anchorLineFrame:CreateLine(nil, "ARTWORK", nil, 1)
        line:SetThickness(3)
        line:SetSnapToPixelGrid(false)
        line:SetTexelSnappingBias(0)
        line:SetTexture("Interface\\AddOns\\EllesmereUI\\media\\textures\\soft-line")
        anchorLinePool[idx] = line
        return line
    end

    local function GetAnchorPulse(idx)
        if anchorPulsePool[idx] then return anchorPulsePool[idx] end
        local line = anchorLineFrame:CreateLine(nil, "ARTWORK", nil, 2)
        line:SetThickness(3)
        line:SetSnapToPixelGrid(false)
        line:SetTexelSnappingBias(0)
        line:SetTexture("Interface\\AnimaChannelingDevice\\AnimaChannelingDeviceLineVerticalMask")
        anchorPulsePool[idx] = line
        return line
    end

    -- Per-line animation state keyed by "childKey:targetKey"
    local anchorLineAnim = {}
    local ANCHOR_LINE_DUR = 0.5
    local PULSE_CYCLE = 2.5
    local PULSE_SWEEP = 0.56  -- fraction of cycle spent sweeping (rest is pause)

    local function UpdateAnchorLines()
        local db = GetAnchorDB()
        local idx = 0
        local now = GetTime()
        if db and UM.isUnlocked then
            for childKey, info in pairs(db) do
                local cm = movers[childKey]
                local tm = movers[info.target]
                if cm and tm and cm:IsShown() and tm:IsShown() then
                    -- Use _hoverConfirmed so lines wait for hover intent
                    local cmActive = cm._hoverConfirmed or cm._dragging
                    local tmActive = tm._hoverConfirmed or tm._dragging
                    local pairKey = childKey .. ":" .. info.target
                    if cmActive or tmActive then
                        -- Start or continue animation
                        if not anchorLineAnim[pairKey] then
                            anchorLineAnim[pairKey] = now
                        end
                        local elapsed = now - anchorLineAnim[pairKey]
                        local t = elapsed / ANCHOR_LINE_DUR
                        if t > 1 then t = 1 end
                        -- Ease-out for smooth deceleration
                        local ease = 1 - (1 - t) * (1 - t)

                        idx = idx + 1
                        local line = GetAnchorLine(idx)
                        -- Child center (line origin)
                        local x1 = ((cm:GetLeft() or 0) + (cm:GetRight()  or 0)) * 0.5
                        local y1 = ((cm:GetBottom() or 0) + (cm:GetTop()  or 0)) * 0.5
                        -- Parent center (line destination)
                        local x2 = ((tm:GetLeft() or 0) + (tm:GetRight()  or 0)) * 0.5
                        local y2 = ((tm:GetBottom() or 0) + (tm:GetTop()  or 0)) * 0.5
                        -- Partial endpoint based on animation progress
                        local ex = x1 + (x2 - x1) * ease
                        local ey = y1 + (y2 - y1) * ease
                        line:SetStartPoint("BOTTOMLEFT", UIParent, x1, y1)
                        line:SetEndPoint("BOTTOMLEFT", UIParent, ex, ey)
                        line:SetVertexColor(1, 0.7, 0.3, 0.75 * ease)
                        line:Show()

                        -- Pulse overlay: streak that sweeps child->parent, loops every 3s
                        local pulse = GetAnchorPulse(idx)
                        if ease >= 1 then
                            local pulseAge = now - anchorLineAnim[pairKey] - 0.3
                            local cycleT = (pulseAge % PULSE_CYCLE) / PULSE_CYCLE
                            local sweepEnd = PULSE_SWEEP
                            if cycleT <= sweepEnd then
                                local st = cycleT / sweepEnd
                                -- Smooth ease-in-out motion, overshooting to 3x line length
                                local smoothT = st * st * (3 - 2 * st)
                                local headT = smoothT * 2.0
                                local tailT = math.max(0, headT - 1.0)
                                -- Clamp endpoints to the actual line
                                local clampHead = math.min(1, headT)
                                local clampTail = math.min(1, tailT)
                                -- Fade in/out
                                local fadeA = 1
                                if smoothT < 0.1 then
                                    fadeA = smoothT / 0.1
                                elseif smoothT > 0.7 then
                                    fadeA = (1 - smoothT) / 0.3
                                end
                                if fadeA < 0 then fadeA = 0 end
                                if clampHead <= clampTail then
                                    pulse:Hide()
                                else
                                    local px1 = x1 + (x2 - x1) * clampTail
                                    local py1 = y1 + (y2 - y1) * clampTail
                                    local px2 = x1 + (x2 - x1) * clampHead
                                    local py2 = y1 + (y2 - y1) * clampHead
                                    pulse:SetStartPoint("BOTTOMLEFT", UIParent, px1, py1)
                                    pulse:SetEndPoint("BOTTOMLEFT", UIParent, px2, py2)
                                    pulse:SetVertexColor(1, 0.89, 0.625, 0.5 * fadeA)
                                    pulse:Show()
                                end
                            else
                                pulse:Hide()
                            end
                        else
                            pulse:Hide()
                        end
                    else
                        -- Not active, clear animation state
                        anchorLineAnim[pairKey] = nil
                    end
                end
            end
        end
        -- Hide unused lines and clean stale anim entries
        for i = idx + 1, #anchorLinePool do
            anchorLinePool[i]:Hide()
        end
        for i = idx + 1, #anchorPulsePool do
            anchorPulsePool[i]:Hide()
        end
    end

    -- Drive line updates every frame while unlock mode is open
    local anchorLineDriver = CreateFrame("Frame")
    anchorLineDriver:SetScript("OnUpdate", UpdateAnchorLines)
    anchorLineDriver:Hide()
    UM.unlockFrame._anchorLineDriver = anchorLineDriver
    UM.unlockFrame._anchorLineFrame  = anchorLineFrame
    UM.unlockFrame._clearAnchorLineAnim = function() wipe(anchorLineAnim) end

    -- Click-to-deselect is handled by toggle behavior on movers themselves
    -- (clicking the selected mover again deselects it), so no full-screen catcher is needed -- world interaction (targeting, camera) stays unblocked.

    -- One Escape step: the innermost open layer closes, else Unlock Mode does
    -- (which asks first when there are unsaved changes). padAll: a controller
    -- Back that closes every window at once (nil from the keyboard).
    local function EscapeStep(padAll)
        -- If anchor dropdown is open, close it instead of closing unlock mode
        if UM.anchorDropdownFrame and UM.anchorDropdownFrame:IsShown() then
            UM.anchorDropdownFrame:Hide()
            if UM.anchorDropdownCatcher then UM.anchorDropdownCatcher:Hide() end
            return
        end
        -- If in width/height/anchor pick mode, cancel it instead of closing
        if UM.pickModeMover and UM.pickMode then
            CancelPickMode()
            return
        end
        -- If in select-element pick mode, cancel it instead of closing
        if UM.selectElementPicker then
            local picker = UM.selectElementPicker
            picker._snapTarget = picker._preSelectTarget
            picker._preSelectTarget = nil
            if picker._updateSnapLabel then picker._updateSnapLabel() end
            UM.selectElementPicker = nil
            FadeOverlayForSelectElement(false)
            return
        end
        -- That Back exits to the world, as Blizzard's does: a panel reopened
        -- here loses the pointer as soon as the press ends. Unsaved changes
        -- keep the way back for the prompt's Save & Exit.
        if padAll and not UM.hasChanges then
            EllesmereUI._unlockReturnModule = nil
            EllesmereUI._unlockReturnPage = nil
        end
        ns.CloseUnlockMode()
    end

    -- ESC to close (skip if confirm popup is already showing)
    UM.unlockFrame:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            -- If the confirm popup is visible, let it handle ESC instead
            local dimmer = _G["EUIConfirmDimmer"]
            if dimmer and dimmer:IsShown() then
                self:SetPropagateKeyboardInput(true)
                return
            end
            self:SetPropagateKeyboardInput(false)
            EscapeStep()
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)

    -- Controller Back (the escape proxy runs it once Unlock Mode is registered
    -- there, see OpenUnlockMode): the same step as Escape. A shown confirm
    -- popup answers Back itself, and the Back that just dismissed the
    -- unsaved-changes prompt must not raise it again in the same pass.
    UM.unlockFrame._padBack = function()
        local dimmer = _G["EUIConfirmDimmer"]
        if dimmer and dimmer:IsShown() then return end
        if UM.unlockFrame._padDismissAt == GetTime() then return end
        -- The game also closes every window by itself (the UI hidden and shown
        -- again, a loading screen, death, loss of control): not a Back press,
        -- so Unlock Mode stays open through those, as it always has. Hiding
        -- the UI marks the frame, so the close when it returns is skipped too.
        if not UM.unlockFrame:IsVisible() then
            UM.unlockFrame._padUIHidden = true
            return
        end
        if UM.unlockFrame._padUIHidden then
            UM.unlockFrame._padUIHidden = nil
            return
        end
        if EllesmereUI._zoneTransitionActive or UnitIsDeadOrGhost("player")
           or (not HasFullControl() and not UnitOnTaxi("player")) then
            return
        end
        EscapeStep(EllesmereUI.PadNative() and CanAutoSetGamePadCursorControl(false))
    end

    UM.unlockFrame:Hide()
    return UM.unlockFrame
end

-------------------------------------------------------------------------------
--  Open lock animation frame (panel shrink -> gear rotate -> shackle unlock).
--  Uses a container frame + SetScale for guaranteed uniform aspect ratio; each
--  texture is set to its NATIVE pixel dimensions so proportions stay exact.
-------------------------------------------------------------------------------
-- Native pixel dimensions of each PNG (from Photoshop)
local INNER_W, INNER_H = 253, 253
local OUTER_W, OUTER_H = 368, 353
local TOP_W,   TOP_H   = 412, 412

-- Container size = largest piece so everything fits
local CONTAINER_SZ = 412
-- The "icon size" we want the logo to appear at on screen (in UI pixels)
local ICON_SZ = 100
-- Base scale to shrink native-res textures down to icon size
local BASE_SCALE = ICON_SZ / CONTAINER_SZ

local SHACKLE_LIFT = 62  -- how far the shackle lifts (in container-space pixels)
local OUTER_Y_OFFSET = -7  -- outer ring sits 7px lower than center

local function CreateOpenAnimFrame(parent)
    if UM.openAnimFrame then return UM.openAnimFrame end

    UM.openAnimFrame = CreateFrame("Frame", nil, parent)
    UM.openAnimFrame:SetFrameLevel(50)  -- above movers (~20), below confirm popup (100)
    UM.openAnimFrame:SetAllPoints(UIParent)

    -- Container frame: sized to hold the largest texture at native res.
    -- SetScale on this frame handles ALL sizing uniformly.
    local container = CreateFrame("Frame", nil, UM.openAnimFrame)
    container:SetSize(CONTAINER_SZ, CONTAINER_SZ)
    container:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    container:SetScale(BASE_SCALE)
    UM.openAnimFrame._container = container

    -- Each texture at its NATIVE pixel dimensions, centered in container
    -- Disable pixel snapping for smooth sub-pixel animation
    local outer = container:CreateTexture(nil, "ARTWORK", nil, 1)
    outer:SetTexture(LOCK_OUTER)
    outer:SetSize(OUTER_W, OUTER_H)
    outer:SetPoint("CENTER", container, "CENTER", 0, OUTER_Y_OFFSET)
    if outer.SetSnapToPixelGrid then outer:SetSnapToPixelGrid(false); outer:SetTexelSnappingBias(0) end
    UM.openAnimFrame._outer = outer

    local inner = container:CreateTexture(nil, "ARTWORK", nil, 2)
    inner:SetTexture(LOCK_INNER)
    inner:SetSize(INNER_W, INNER_H)
    inner:SetPoint("CENTER", container, "CENTER", 0, 0)
    if inner.SetSnapToPixelGrid then inner:SetSnapToPixelGrid(false); inner:SetTexelSnappingBias(0) end
    UM.openAnimFrame._inner = inner

    local top = container:CreateTexture(nil, "ARTWORK", nil, 3)
    top:SetTexture(LOCK_TOP)
    top:SetSize(TOP_W, TOP_H)
    top:SetPoint("CENTER", container, "CENTER", 0, 0)
    if top.SetSnapToPixelGrid then top:SetSnapToPixelGrid(false); top:SetTexelSnappingBias(0) end
    UM.openAnimFrame._top = top

    -- Sweep shine: tightly clipped to logo center (lives inside container)
    local sweepClip = CreateFrame("Frame", nil, container)
    sweepClip:SetSize(CONTAINER_SZ * 0.75, CONTAINER_SZ * 0.75)
    sweepClip:SetPoint("CENTER", container, "CENTER", 0, 0)
    sweepClip:SetFrameLevel(container:GetFrameLevel() + 5)
    sweepClip:SetClipsChildren(true)
    UM.openAnimFrame._sweepClip = sweepClip

    local sweep = sweepClip:CreateTexture(nil, "OVERLAY", nil, 7)
    sweep:SetColorTexture(1, 1, 1, 0.30)
    sweep:SetSize(12, 120)
    sweep:SetRotation(math.rad(20))
    sweep:ClearAllPoints()
    sweep:SetPoint("CENTER", sweepClip, "LEFT", -20, 0)
    sweep:Hide()
    UM.openAnimFrame._sweep = sweep

    UM.openAnimFrame:Hide()
    return UM.openAnimFrame
end

-------------------------------------------------------------------------------
--  One-time "How to use" tip -- shows below the banner on first ever open.
--  Saved to EllesmereUIDB.unlockTipSeen so it never shows again.
-------------------------------------------------------------------------------

function ns.ShowUnlockTip()
    if EllesmereUIDB and EllesmereUIDB.unlockTipSeen then return end
    if UM.unlockTipFrame and UM.unlockTipFrame:IsShown() then return end

    if not UM.unlockTipFrame then
        local TIP_W, TIP_H = 450, 175
        local ar, ag, ab = GetAccent()

        local tip = CreateFrame("Frame", nil, UIParent)
        tip:SetFrameStrata("TOOLTIP")
        tip:SetFrameLevel(900)
        tip:SetSize(TIP_W, TIP_H)
        tip:EnableMouse(true)

        -- Pixel-perfect scale (match banner)
        local physW = (GetPhysicalScreenSize())
        local ppScale = GetScreenWidth() / physW
        tip:SetScale(ppScale)

        -- Position 100px from the top of the screen
        tip:SetPoint("TOP", UIParent, "TOP", 0, -100 / ppScale)

        local bg = tip:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.06, 0.08, 0.10, 0.95)

        EllesmereUI.MakeBorder(tip, ar, ag, ab, 0.25)

        -- Smooth arrow pointing up: rotated squares for clean diagonal edges, using
        -- SetClipsChildren to show only the top half of the diamond. No mask needed.
        local ARROW_SZ = 16  -- diamond size
        -- Clip frame: sits above the popup top edge, clips to show only top half
        -- Shifted up 2px so the arrow appears 2px higher
        local arrowClip = CreateFrame("Frame", nil, tip)
        arrowClip:SetFrameStrata("TOOLTIP")
        arrowClip:SetFrameLevel(tip:GetFrameLevel() + 10)
        arrowClip:SetClipsChildren(true)
        -- Clip region: tall enough for the top half of the diamond
        local clipH = ARROW_SZ
        arrowClip:SetSize(ARROW_SZ * 2, clipH)
        arrowClip:SetPoint("BOTTOM", tip, "TOP", 0, -1)

        -- The actual diamond frame inside the clip, positioned so its center
        -- (widest point) is exactly at the clip's bottom edge
        local arrowFrame = CreateFrame("Frame", nil, arrowClip)
        arrowFrame:SetFrameLevel(arrowClip:GetFrameLevel() + 1)
        arrowFrame:SetSize(ARROW_SZ + 4, ARROW_SZ + 4)
        arrowFrame:SetPoint("CENTER", arrowClip, "BOTTOM", 0, 0)

        -- Border diamond (accent, slightly larger for 1px border effect)
        -- Alpha slightly lower than popup border (0.25) to compensate for
        -- anti-aliased rotated edges appearing brighter than crisp 1px lines
        local arrowBorder = arrowFrame:CreateTexture(nil, "ARTWORK", nil, 7)
        arrowBorder:SetSize(ARROW_SZ + 2, ARROW_SZ + 2)
        arrowBorder:SetPoint("CENTER")
        arrowBorder:SetColorTexture(ar, ag, ab, 0.18)
        arrowBorder:SetRotation(math.rad(45))
        if arrowBorder.SetSnapToPixelGrid then arrowBorder:SetSnapToPixelGrid(false); arrowBorder:SetTexelSnappingBias(0) end

        -- Fill diamond (same bg as popup: 0.06, 0.08, 0.10, 0.95)
        local arrowFill = arrowFrame:CreateTexture(nil, "OVERLAY", nil, 6)
        arrowFill:SetSize(ARROW_SZ, ARROW_SZ)
        arrowFill:SetPoint("CENTER")
        arrowFill:SetColorTexture(0.06, 0.08, 0.10, 0.95)
        arrowFill:SetRotation(math.rad(45))
        if arrowFill.SetSnapToPixelGrid then arrowFill:SetSnapToPixelGrid(false); arrowFill:SetTexelSnappingBias(0) end

        local msg = tip:CreateFontString(nil, "OVERLAY")
        msg:SetFont(FONT_PATH, 12, "OUTLINE, SLUG")
        msg:SetTextColor(1, 1, 1, 0.85)
        msg:SetPoint("TOP", tip, "TOP", 0, -17)
        msg:SetWidth(TIP_W - 30)
        msg:SetJustifyH("CENTER")
        msg:SetSpacing(6)
        msg:SetText(EllesmereUI.L("This is where you can control the settings of Unlock Mode.\n\nElements can be repositioned by dragging or arrow keys (+shift)\nAnchor, Height Match, or Width match any element.\nSnapping is based on closest element, but you can snap only to\n a specific element via right click or the settings icon."))

        local okBtn = CreateFrame("Button", nil, tip)
        okBtn:SetSize(80, 24)
        okBtn:SetPoint("BOTTOM", tip, "BOTTOM", 0, 15)
        EllesmereUI.MakeStyledButton(okBtn, "Okay", 10,
            EllesmereUI.RB_COLOURS, function()
                tip:Hide()
                if EllesmereUIDB then EllesmereUIDB.unlockTipSeen = true end
            end)

        UM.unlockTipFrame = tip
    end

    UM.unlockTipFrame:SetAlpha(0)
    UM.unlockTipFrame:Show()

    -- Fade in over 0.3s
    local fadeIn = 0
    UM.unlockTipFrame:SetScript("OnUpdate", function(self, dt)
        fadeIn = fadeIn + dt
        if fadeIn >= 0.3 then
            self:SetAlpha(1)
            self:SetScript("OnUpdate", nil)
            return
        end
        self:SetAlpha(fadeIn / 0.3)
    end)
end

function ns.OpenUnlockMode()
    if UM.isUnlocked then return end
    if InCombatLockdown() then
        print("|cffff6060[EllesmereUI]|r Cannot enter Unlock Mode during combat.")
        return
    end
    -- Standardized options-panel roundtrip: entering unlock mode by ANY means
    -- (minimap, /euiunlock, ...) while the options panel is open reopens it on exit,
    -- exactly like the sidebar Unlock Mode tab. Options-side entries capture their
    -- own return target BEFORE calling here, so only fill when unset. The game menu
    -- button never coexists with an open panel, so the IsShown gate is a natural no-op there.
    if not EllesmereUI._unlockReturnModule then
        local panel = EllesmereUI._mainFrame
        if panel and panel:IsShown() then
            EllesmereUI._unlockReturnModule = EllesmereUI:GetActiveModule() or nil
            EllesmereUI._unlockReturnPage = EllesmereUI:GetActivePage() or nil
        end
    end
    -- Permanent gold variant: when the current spec's owning group has a custom
    -- unlock layout (the ACTIVE layer), every unlock session on this spec edits
    -- that layer -- so every session shows the special visuals (gold frame/banner,
    -- size inputs hidden). Derived here, not at the card button, so opening unlock any way gets the right identity.
    do
        local activeGid = EllesmereUI.SpecOverrides_UnlockActive
            and EllesmereUI.SpecOverrides_UnlockActive() or nil
        local g
        if type(activeGid) == "string" then
            -- Conditional layer live ("cond:<gid>"): same gold identity, the
            -- banner shows the conditional group's name.
            local cid = tonumber(activeGid:match("^cond:(%d+)$"))
            g = cid and EllesmereUI.Conditions_GroupById
                and EllesmereUI.Conditions_GroupById(cid) or nil
        elseif activeGid then
            g = EllesmereUI.SpecOverrides_GroupById
                and EllesmereUI.SpecOverrides_GroupById(activeGid) or nil
        end
        EllesmereUI._specialUnlockGroup = g
    end
    -- Close any panel-side editing session/view BEFORE taking the value snapshot: the
    -- options panel doesn't hide until much later in this flow, so with the Default
    -- view (or an editing-as session) still holding SWAPPED values live, the snapshot
    -- would capture the view's values while the panel's eventual OnHide restored the
    -- SPEC's values -- Save & Exit would then diff spec-vs-default and bank every
    -- difference into values.default (defaults silently flipping to a group's
    -- values). Exiting the sessions here banks them properly and restores canonical
    -- spec values, so the snapshot below is clean. No-op when the panel is closed.
    if EllesmereUI.SpecOverrides_CloseEditSessions then
        EllesmereUI.SpecOverrides_CloseEditSessions()
    end
    -- Value-edit banking baseline: captured settings edited from unlock mode (cog
    -- size inputs) are Default-baseline edits; Save & Exit diffs against this
    -- snapshot and banks into values.default (special sessions skipped inside --
    -- their size inputs are hidden). Must run AFTER the special-group derivation above.
    if EllesmereUI.SpecOverrides_UnlockValueSnapBegin then
        EllesmereUI.SpecOverrides_UnlockValueSnapBegin()
    end
    -- Disable expandIfNoResource before _unlockActive is set so the
    -- Rebuild inside runs in normal gameplay state and the power bar
    -- is at its true stored height before movers capture positions.
    if _G._ERB_SuppressExpand then pcall(_G._ERB_SuppressExpand) end

    UM.isUnlocked = true
    EllesmereUI._unlockActive = true
    EllesmereUI._unlockModeActive = true

    -- Notify action bars to flip Blizzard-owned frame anchors for drag
    if _G._EAB_UnlockModeOpen then pcall(_G._EAB_UnlockModeOpen) end
    -- Notify raid frames to fade out overlay previews
    if _G._ERF_UnlockModeOpen then pcall(_G._ERF_UnlockModeOpen) end

    -- Remove any stale anchor/match relationships before entering unlock mode.
    -- By this point all elements are registered, so anything not in the registry
    -- is genuinely gone (e.g. a custom CDM bar that was deleted).
    ValidateStoredLinks()

    -- Notify beacon reminders to hide (if follow-mouse is active)
    if _G._EABR_BeaconRefresh then pcall(_G._EABR_BeaconRefresh) end

    -- Hide unit frame buffs/debuffs so they don't clutter the movers
    local UF_FRAME_NAMES = {
        "EllesmereUIUnitFrames_Player", "EllesmereUIUnitFrames_Target",
        "EllesmereUIUnitFrames_Focus", "EllesmereUIUnitFrames_Pet",
        "EllesmereUIUnitFrames_TargetTarget", "EllesmereUIUnitFrames_FocusTarget",
    }
    for i = 1, 8 do UF_FRAME_NAMES[#UF_FRAME_NAMES + 1] = "EllesmereUIUnitFrames_Boss" .. i end
    for _, name in ipairs(UF_FRAME_NAMES) do
        local f = _G[name]
        if f then
            if f.Buffs and f.Buffs:IsShown() then
                f.Buffs._unlockWasShown = true
                f.Buffs:Hide()
            end
            if f.Debuffs and f.Debuffs:IsShown() then
                f.Debuffs._unlockWasShown = true
                f.Debuffs:Hide()
            end
        end
    end

    -- Hide objective tracker (alpha only -- no :Hide() to avoid taint).
    -- Hook SetAlpha to suppress Blizzard re-showing it during unlock
    -- (mounting, quest updates, etc. call SetAlpha(1) on their own).
    local objTracker = _G.ObjectiveTrackerFrame
    if objTracker and objTracker:IsShown() then
        UM.objTrackerWasVisible = true
        objTracker._eabMouseWasEnabled = objTracker:IsMouseEnabled()
        objTracker:SetAlpha(0)
        if objTracker.EnableMouse then pcall(objTracker.EnableMouse, objTracker, false) end
        if not objTracker._eabUnlockAlphaHooked then
            objTracker._eabUnlockAlphaHooked = true
            hooksecurefunc(objTracker, "SetAlpha", function(self, a)
                if UM.isUnlocked and a > 0 then
                    self:SetAlpha(0)
                end
            end)
        end
    else
        UM.objTrackerWasVisible = false
    end
    -- Also hide EllesmereUI QT background (separate UIParent child)
    local qtBg = _G.EllesmereUIQTBackground
    if qtBg then
        qtBg:SetAlpha(0)
        if not qtBg._eabUnlockAlphaHooked then
            qtBg._eabUnlockAlphaHooked = true
            hooksecurefunc(qtBg, "SetAlpha", function(self, a)
                if UM.isUnlocked and a > 0 then
                    self:SetAlpha(0)
                end
            end)
        end
    end

    -- Reset session state and snapshot current positions
    wipe(pendingPositions)
    UM.hasChanges = false
    UM.selectedMover = nil
    -- Clear per-session temporary overlay hides (Shift+Right Click). Every unlock
    -- session starts with all overlays visible again. Cleared before the fade-in
    -- Sync / ShowBlizzOwnedOverlays calls so last session's hides don't persist.
    -- Fallback/override anchor ghosts carry the same flag (their tables are
    -- do-block locals, hence the namespaced helpers).
    for _, m in pairs(movers) do m._tempHidden = nil end
    for _, ov in pairs(_blizzOwnedOverlays) do ov._tempHidden = nil end
    if EllesmereUI._ClearFallbackGhostTempHides then EllesmereUI._ClearFallbackGhostTempHides() end
    if EllesmereUI._ClearOverrideGhostTempHides then EllesmereUI._ClearOverrideGhostTempHides() end
    -- Strip provider-owned visual adjustments that live OUTSIDE the anchor
    -- system (CDM's Additional Bar Offset on un-anchored bars): each enter hook
    -- self-gates, so this is near-free when nothing is active.
    EllesmereUI.RunAnchorShiftEnters()
    -- Strip any temporary anchor-target shift (e.g. "Shift Elements if No
    -- Resource"/"...if No Bars") so movers snapshot TRUE saved positions.
    -- _unlockActive is already true above, so the shift providers return 0 and
    -- this re-apply snaps shifted children back to their real positions. Gated so
    -- non-shift profiles do no extra work on unlock entry.
    if EllesmereUI.AnchorShiftWantsApply()
       and EllesmereUI.ReapplyAllUnlockAnchors then
        -- Force edge-preservation for this reapply so custom-growth anchored bars
        -- snap to their fixed growth edge (their true saved position), not the
        -- center-offset position. Reset in all cases (pcall) so the flag can't leak.
        EllesmereUI._reapplyForceEdgePreserve = true
        pcall(EllesmereUI.ReapplyAllUnlockAnchors)
        EllesmereUI._reapplyForceEdgePreserve = false
    end
    SnapshotPositions()

    -- Setup and show arrow key frame for nudge support
    SetupArrowKeyFrame()
    UM.arrowKeyFrame:Show()

    -- Play unlock sound
    PlaySound(201528, "Master")

    -- Create frames
    CreateUnlockFrame()
    CreateGrid(UM.unlockFrame)
    CreateHUD(UM.unlockFrame)
    EllesmereUI:_NotifyUnlockModeListeners(true)
    CreateOpenAnimFrame(UM.unlockFrame)

    -- Special (spec-override) sessions swap the unlock art for the override
    -- variants; normal sessions restore the standard art. Re-set every open:
    -- the frames are created once and reused across sessions.
    do
        local ov = EllesmereUI._specialUnlockGroup and "-override" or ""
        if UM.hudFrame and UM.hudFrame._bannerTex then
            UM.hudFrame._bannerTex:SetTexture(
                "Interface\\AddOns\\EllesmereUI\\media\\eui-unlocked-banner-2" .. ov .. ".png")
        end
        if UM.openAnimFrame then
            if UM.openAnimFrame._outer then
                UM.openAnimFrame._outer:SetTexture(
                    "Interface\\AddOns\\EllesmereUI\\media\\eui-unlocked-outer-2" .. ov .. ".png")
            end
            if UM.openAnimFrame._inner then
                UM.openAnimFrame._inner:SetTexture(
                    "Interface\\AddOns\\EllesmereUI\\media\\eui-unlocked-inner-2" .. ov .. ".png")
            end
            if UM.openAnimFrame._top then
                UM.openAnimFrame._top:SetTexture(
                    "Interface\\AddOns\\EllesmereUI\\media\\eui-unlocked-top-2" .. ov .. ".png")
            end
        end
    end

    -- Capture the options panel frame for the shrink animation
    local panel = EllesmereUI and EllesmereUI._mainFrame
    local panelStartW, panelStartH
    if panel and panel:IsShown() then
        panelStartW = panel:GetWidth()
        panelStartH = panel:GetHeight()
    end
    panelStartW = panelStartW or 600
    panelStartH = panelStartH or 400
    -- Use the larger dimension for the scale factor
    local panelStartSz = max(panelStartW, panelStartH)
    -- startScale: how big the container needs to be so it appears panel-sized
    -- BASE_SCALE makes the container appear as ICON_SZ on screen,
    -- so to appear as panelStartSz we need: BASE_SCALE * (panelStartSz / ICON_SZ)
    local startScale = BASE_SCALE * (panelStartSz / ICON_SZ) * 0.6

    -- Controller Back steps out like Escape: registered with the escape proxy
    -- on the first open with a controller in use (padOnly: it counts only then),
    -- and never a controller-cursor root (a pointer-drag UI).
    if not UM.unlockFrame._padEsc and EllesmereUI.PadInUse() then
        UM.unlockFrame._padEsc = true
        EllesmereUI.RegisterEscapeClose(UM.unlockFrame, {
            padOnly = true, notOwned = true, onEscape = UM.unlockFrame._padBack,
        })
    end

    -- Show overlay, hide grid/toolbar/movers
    UM.unlockFrame:Show()
    UM.unlockFrame:SetAlpha(1)
    if UM.gridFrame then UM.gridFrame:Hide() end
    if UM.hudFrame then UM.hudFrame:Hide() end
    for _, m in pairs(movers) do m:Hide() end

    local container = UM.openAnimFrame._container
    local outerTex  = UM.openAnimFrame._outer
    local innerTex  = UM.openAnimFrame._inner
    local topTex    = UM.openAnimFrame._top

    if UM.openAnimFrame._sweep then UM.openAnimFrame._sweep:Hide() end

    -- Container starts at panel-sized scale, textures stay at native dims always
    local TOTAL_GEAR_ROT = GEAR_ROTATION * 4

    -- Reset textures anchored to container center -- ONCE
    -- (sizes are already set to native dims at creation, never change them)
    outerTex:ClearAllPoints()
    outerTex:SetPoint("CENTER", container, "CENTER", 0, OUTER_Y_OFFSET)
    outerTex:SetAlpha(0)
    outerTex:SetRotation(TOTAL_GEAR_ROT)

    innerTex:ClearAllPoints()
    innerTex:SetPoint("CENTER", container, "CENTER", 0, 0)
    innerTex:SetAlpha(0)
    innerTex:SetRotation(-TOTAL_GEAR_ROT)

    topTex:ClearAllPoints()
    topTex:SetPoint("CENTER", container, "CENTER", 0, 0)
    topTex:SetAlpha(0)
    topTex:SetRotation(0)

    -- Container starts at panel scale
    container:SetScale(startScale)

    UM.openAnimFrame:Show()
    UM.openAnimFrame:SetAlpha(1)

    -- Start overlay at 0 alpha, will fade in during animation
    if UM.unlockFrame._overlay then
        UM.unlockFrame._overlay:SetColorTexture(0.02, 0.03, 0.04, 0)
    end

    -- Phase timings
    local MORPH     = 0.50  -- panel shrinks + lock appears simultaneously
    local IDLE_SPIN = 1.00  -- gears keep spinning at icon size
    local OVERLAP   = 0.75  -- shackle starts this much BEFORE idle spin ends
    local SHACKLE   = 0.75  -- shackle lifts + sweep duration (slowed)

    -- Gear rotation: one continuous motion across MORPH + IDLE_SPIN
    local SPIN_DUR = MORPH + IDLE_SPIN  -- total time gears rotate
    -- Shackle/HUD start time (0.75s before scaling/spinning stops)
    local SHACKLE_START = MORPH + IDLE_SPIN - OVERLAP

    local panelHidden = false
    local panelRealScale = panel and panel:GetScale() or 1
    local elapsed = 0
    local fadeInSynced = false

    -- Grid glitch starts immediately and lasts 0.75s
    local GLITCH_DUR = 0.75
    local GRID_START = 0  -- grid begins immediately
    local gridStarted = false

    -- Reset cursor speed so the first hover isn't blocked by a stale value
    EllesmereUI._unlockCursorSpeed = 0

    UM.unlockFrame:SetScript("OnUpdate", function(self, dt)
        -- Sample cursor position and compute speed for hover intent detection
        do
            local scale = UIParent:GetEffectiveScale()
            local nx, ny = GetCursorPosition()
            nx = nx / scale; ny = ny / scale
            if dt > 0 then
                local dx = nx - EllesmereUI._unlockCursorX
                local dy = ny - EllesmereUI._unlockCursorY
                -- Store squared speed to avoid sqrt; TryExpand compares against squared threshold
                EllesmereUI._unlockCursorSpeed = (dx * dx + dy * dy) / (dt * dt)

                -- After arrow-key nudge collapsed a mover, re-expand it
                -- once the cursor moves and is still hovering the mover.
                if UM.selectedMover and UM.selectedMover._nudgeCollapsed then
                    local moved = (dx ~= 0 or dy ~= 0)
                    if moved then
                        UM.selectedMover._nudgeCollapsed = nil
                        if UM.selectedMover:IsMouseOver() then
                            if UM.selectedMover._showOverlayText then
                                UM.selectedMover._showOverlayText()
                                UM.hoveredMover = UM.selectedMover
                            end
                        end
                    end
                end
            end
            EllesmereUI._unlockCursorX = nx; EllesmereUI._unlockCursorY = ny
        end

        -- Selected movers are NOT auto re-expanded: expansion is purely
        -- hover-driven. A selected element (e.g. one being width/height matched or
        -- anchored) keeps its border/level highlight via OnLeave regardless; the
        -- nudge block above re-expands only while the cursor is over the mover.

        elapsed = elapsed + dt

        ---------------------------------------------------------------
        --  Background overlay fade: 0 -> full alpha over 0.75 seconds
        --  (synced with grid glitch duration)
        ---------------------------------------------------------------
        local OVERLAY_FADE_DUR = 0.75
        if UM.unlockFrame._overlay then
            local oa = min(1, elapsed / OVERLAY_FADE_DUR) * (UM.unlockFrame._overlayMaxAlpha or 0.20)
            UM.unlockFrame._overlay:SetColorTexture(0.02, 0.03, 0.04, oa)
        end

        ---------------------------------------------------------------
        --  Grid glitch overlay -- runs independently of lock phases
        --  Starts at GRID_START (beginning of idle spin, 1s earlier)
        ---------------------------------------------------------------
        if elapsed >= GRID_START then
            if not gridStarted then
                gridStarted = true
                if UM.gridFrame then
                    UM.gridFrame:Rebuild()
                    if UM.gridMode ~= "disabled" then UM.gridFrame:Show() end
                    UM.gridFrame:SetAlpha(0)
                end
                if UM.hudFrame then
                    UM.hudFrame:Show()
                    UM.hudFrame:SetAlpha(1)
                    -- Position off-screen (will slide down during shackle)
                    UM.hudFrame:ClearAllPoints()
                    local ppS = UM.hudFrame:GetScale() or 1
                    UM.hudFrame:SetPoint("TOP", UIParent, "TOP", 0, (BANNER_PX_H + 10) * ppS)
                end
                for _, barKey in ipairs(ALL_BAR_ORDER) do
                    -- Skip bars that have a registered element (avoids duplicates)
                    if not registeredElements[barKey] then
                        local m = CreateMover(barKey)
                        if m then m:Sync(); m:SetAlpha(0) end
                    end
                end
                -- Registered elements (unit frames, etc.)
                RebuildRegisteredOrder()
                for _, key in ipairs(registeredOrder) do
                    local m = CreateMover(key)
                    if m then m:Sync(); m:SetAlpha(0) end
                end
                -- Sort frame levels: smaller movers render on top
                SortMoverFrameLevels()
                -- Re-apply saved anchor positions and refresh anchored mover text
                ReapplyAllAnchors()
                wipe(pendingPositions)
                for bk, _ in pairs(movers) do
                    if movers[bk].RefreshAnchoredText then
                        movers[bk]:RefreshAnchoredText()
                    end
                end
                -- Spec-override gold borders / special-session locks + banner
                if EllesmereUI._unlockRefreshSpecOvMarks then EllesmereUI._unlockRefreshSpecOvMarks() end

                -- Info overlays on Blizzard-owned elements (chat, micro, bags, encounter)
                -- Start at alpha 0; the mover fade-in loop below handles them.
                ShowBlizzOwnedOverlays(UM.unlockFrame)
                for _, bov in pairs(_blizzOwnedOverlays) do
                    bov:SetAlpha(0)
                end

                -- Fallback ghost overlays for elements with a fallback link
                -- (spawn at 0 alpha; the mover fade-in loop below ramps them)
                if EllesmereUI._RefreshFallbackGhosts then
                    EllesmereUI._RefreshFallbackGhosts()
                    if EllesmereUI._SetFallbackGhostsAlpha then
                        EllesmereUI._SetFallbackGhostsAlpha(0)
                    end
                end

                -- Override anchors release to baseline for the session (movers
                -- edit the baseline; the gold ghosts edit the overrides), then
                -- their ghosts spawn on the same fade curve.
                if EllesmereUI._ReapplyOverrideAnchors then EllesmereUI._ReapplyOverrideAnchors() end
                if EllesmereUI._RefreshOverrideGhosts then
                    EllesmereUI._RefreshOverrideGhosts()
                    if EllesmereUI._SetOverrideGhostsAlpha then
                        EllesmereUI._SetOverrideGhostsAlpha(0)
                    end
                end

                -- Retry ticker: some addons (CDM) may not have their bar
                -- frames ready yet. Poll briefly to catch late arrivals.
                local retryAttempts = 0
                local retryTicker
                retryTicker = C_Timer.NewTicker(0.5, function()
                    retryAttempts = retryAttempts + 1
                    if not UM.isUnlocked then retryTicker:Cancel(); return end
                    -- Ask addons to re-register elements they may not have
                    -- registered yet (CDM bars that were still building, etc.)
                    if EllesmereUI._unlockRegistrationDirty or retryAttempts <= 3 then
                        if _G._ECME_RegisterUnlock then _G._ECME_RegisterUnlock() end
                        if _G._ECME_RegisterTBBUnlock then _G._ECME_RegisterTBBUnlock() end
                        -- Late-registering frames may satisfy a fallback
                        -- ghost that could not resolve at open.
                        if EllesmereUI._RefreshFallbackGhosts then
                            EllesmereUI._RefreshFallbackGhosts()
                        end
                        if EllesmereUI._RefreshOverrideGhosts then
                            EllesmereUI._RefreshOverrideGhosts()
                        end
                    end
                    RebuildRegisteredOrder()
                    local spawned = false
                    local missing = false
                    for _, rk in ipairs(registeredOrder) do
                        if not movers[rk] then
                            local rm = CreateMover(rk)
                            if rm then
                                rm:Sync()
                                rm:SetAlpha(UM.darkOverlaysEnabled and 1 or MOVER_ALPHA)
                                rm:Show()
                                spawned = true
                            else
                                missing = true
                            end
                        elseif not movers[rk]:IsShown() then
                            -- Mover exists but bar frame was not ready on
                            -- first Sync -- re-sync now that it may be available
                            local re = registeredElements[rk]
                            if not (re and re.isHidden and re.isHidden()) then
                                local rm = movers[rk]
                                rm:Sync()
                                if rm:IsShown() then
                                    rm:SetAlpha(UM.darkOverlaysEnabled and 1 or MOVER_ALPHA)
                                    spawned = true
                                else
                                    missing = true
                                end
                            end
                        end
                    end
                    if spawned then
                        SortMoverFrameLevels()
                        ReapplyAllAnchors()
                        if EllesmereUI._unlockRefreshSpecOvMarks then EllesmereUI._unlockRefreshSpecOvMarks() end
                    end
                    -- Stop once every mover is visible, or after timeout
                    if not missing or retryAttempts >= 20 then
                        retryTicker:Cancel()
                    end
                end)
            end

            local glitchT = elapsed - GRID_START
            local glitchProgress = min(1, glitchT / GLITCH_DUR)

            -- (Banner slides down during shackle phase, not here)

            -- Movers fade in over 0.75s, delayed by 0.5s
            local MOVER_DELAY = 0.50
            local moverFadeT = glitchT - MOVER_DELAY
            for _, m in pairs(movers) do
                if m:IsShown() then
                    if moverFadeT > 0 then
                        -- Re-sync once right as movers begin fading in so any
                        -- frames that were nil at initial sync are now ready.
                        if not fadeInSynced then
                            fadeInSynced = true
                            for _, rm in pairs(movers) do rm:Sync() end
                        end
                        m:SetAlpha((UM.darkOverlaysEnabled and 1 or MOVER_ALPHA) * min(1, moverFadeT / GLITCH_DUR))
                    else
                        m:SetAlpha(0)
                    end
                end
            end
            -- Blizzard-owned overlays fade in on the same curve
            for _, bov in pairs(_blizzOwnedOverlays) do
                if bov:IsShown() then
                    if moverFadeT > 0 then
                        bov:SetAlpha(min(1, moverFadeT / GLITCH_DUR))
                    else
                        bov:SetAlpha(0)
                    end
                end
            end
            -- Fallback ghosts fade in on the same curve (75% resting alpha)
            if EllesmereUI._SetFallbackGhostsAlpha then
                if moverFadeT > 0 then
                    EllesmereUI._SetFallbackGhostsAlpha(min(1, moverFadeT / GLITCH_DUR))
                else
                    EllesmereUI._SetFallbackGhostsAlpha(0)
                end
            end
            -- Override anchor ghosts ride the same curve
            if EllesmereUI._SetOverrideGhostsAlpha then
                if moverFadeT > 0 then
                    EllesmereUI._SetOverrideGhostsAlpha(min(1, moverFadeT / GLITCH_DUR))
                else
                    EllesmereUI._SetOverrideGhostsAlpha(0)
                end
            end

            -- Grid glitch effect
            if UM.gridFrame and UM.gridFrame:IsShown() then
                local baseA = glitchProgress
                local flicker = 0
                if glitchProgress < 0.9 then
                    local intensity = (1 - glitchProgress) * 0.7
                    local t1 = glitchT * 37.3
                    local t2 = glitchT * 13.7
                    local t3 = glitchT * 71.1
                    flicker = (sin(t1) * 0.4 + sin(t2) * 0.35 + sin(t3) * 0.25) * intensity
                    if sin(glitchT * 5.3) > 0.85 and glitchProgress < 0.6 then
                        flicker = flicker - 0.5
                    end
                end
                UM.gridFrame:SetAlpha(max(0, min(1, baseA + flicker)))
            end
        end

        -------------------------------------------------------------------
        --  Continuous gear rotation: one smooth ease-out across MORPH +
        --  IDLE_SPIN combined. Rotation goes from TOTAL_GEAR_ROT -> 0.
        -------------------------------------------------------------------
        local gearRot = 0
        -- Extended taper with quintic ease-out for imperceptible final frames
        local SPIN_TAPER = SPIN_DUR + 0.5
        if elapsed < SPIN_TAPER then
            local spinT = elapsed / SPIN_TAPER
            -- Quintic ease-out: (1-t)^5 -- extremely gradual deceleration
            local inv = 1 - spinT
            local eased = 1 - inv * inv * inv * inv * inv
            gearRot = TOTAL_GEAR_ROT * (1 - eased)
        end
        outerTex:SetRotation(gearRot)
        innerTex:SetRotation(-gearRot)

        -------------------------------------------------------------------
        --  Phase 1: Panel shrinks + fades while lock container scales down
        --           from startScale -> BASE_SCALE over MORPH seconds.
        --           After MORPH, container stays at BASE_SCALE (no hard snap).
        -------------------------------------------------------------------
        if elapsed < MORPH then
            local t = EaseInOutCubic(elapsed / MORPH)
            local sc = startScale + (BASE_SCALE - startScale) * t

            -- Panel scales down, slides to center, and fades out
            -- Panel scales down + fades out (relative to its real scale)
            if panel and not panelHidden then
                local s = panelRealScale * max(0.01, 1 - t)
                panel:SetScale(s)
                -- Alpha fades to 0 in 0.25s (twice as fast as the scale)
                local alphaT = min(1, elapsed / 0.25)
                panel:SetAlpha(1 - alphaT)
                if t > 0.95 then
                    panelHidden = true
                    panel:SetScale(panelRealScale)
                    panel:SetAlpha(1)
                    EllesmereUI:Hide()
                end
            end

            -- Scale the container uniformly
            container:SetScale(sc)

            -- Fade textures in: delayed 0.25s, then 0->1 over remaining 0.25s
            -- Top stays hidden until shackle phase
            local LOGO_FADE_DELAY = 0.15
            local logoAlpha = 0
            if elapsed > LOGO_FADE_DELAY then
                logoAlpha = min(1, (elapsed - LOGO_FADE_DELAY) / (MORPH - LOGO_FADE_DELAY))
            end
            outerTex:SetAlpha(logoAlpha)
            innerTex:SetAlpha(logoAlpha)
            topTex:SetAlpha(0)
            return
        end

        -- Ensure panel is hidden (one-time cleanup, no visual snap)
        if not panelHidden then
            panelHidden = true
            if panel then panel:SetScale(panelRealScale); panel:SetAlpha(1) end
            EllesmereUI:Hide()
        end

        -- Post-morph: container at final scale, inner/outer fully visible
        -- (these are already at their final values from the last morph frame,
        --  but we set them once cleanly without causing a visual snap)
        container:SetScale(BASE_SCALE)

        -------------------------------------------------------------------
        --  Shackle + HUD: starts at SHACKLE_START (0.25s before spin ends)
        --  Overlaps the final gear deceleration.
        -------------------------------------------------------------------
        local shackleT = elapsed - SHACKLE_START
        if shackleT >= 0 and shackleT < SHACKLE then
            local t = EaseInOutCubic(shackleT / SHACKLE)
            -- Top piece fades from 0->100% over 0.5s, delayed 0.2s from shackle start
            -- (movement still starts immediately, only alpha is delayed)
            local TOP_FADE_IN = 0.25
            local TOP_FADE_DELAY = 0.20
            local topAlphaT = shackleT - TOP_FADE_DELAY
            if topAlphaT > 0 then
                topTex:SetAlpha(min(1, topAlphaT / TOP_FADE_IN))
            else
                topTex:SetAlpha(0)
            end
            topTex:ClearAllPoints()
            topTex:SetPoint("CENTER", container, "CENTER", 0, SHACKLE_LIFT * t)

            -- Banner slides down from off-screen, synced with shackle
            if UM.hudFrame and UM.hudFrame:IsShown() then
                local ppS = UM.hudFrame:GetScale() or 1
                local offScreen = (BANNER_PX_H + 10) * ppS
                local bannerY = offScreen * (1 - t)
                UM.hudFrame:ClearAllPoints()
                UM.hudFrame:SetPoint("TOP", UIParent, "TOP", 0, bannerY)
            end

            -- Sweep runs during shackle phase
            local sweepTex = UM.openAnimFrame._sweep
            if sweepTex then
                if not sweepTex:IsShown() then sweepTex:Show() end
                local st = min(1, shackleT / SHACKLE)
                local clipW = UM.openAnimFrame._sweepClip:GetWidth()
                local xPos = -20 + (clipW + 40) * st
                sweepTex:ClearAllPoints()
                sweepTex:SetPoint("CENTER", UM.openAnimFrame._sweepClip, "LEFT", xPos, 0)
                local sweepAlpha
                if st < 0.15 then sweepAlpha = st / 0.15
                elseif st > 0.85 then sweepAlpha = (1 - st) / 0.15
                else sweepAlpha = 1 end
                sweepTex:SetAlpha(0.30 * sweepAlpha)
            end
        end

        -- After shackle completes, settle top piece and hide sweep
        if shackleT >= SHACKLE then
            topTex:SetAlpha(1)
            topTex:ClearAllPoints()
            topTex:SetPoint("CENTER", container, "CENTER", 0, SHACKLE_LIFT)
            if UM.openAnimFrame._sweep then UM.openAnimFrame._sweep:Hide() end
        end

        -- Still in idle spin phase (before shackle or during overlap), keep waiting
        if elapsed < SPIN_DUR and shackleT < SHACKLE then
            return
        end

        -- If shackle hasn't finished yet, keep going
        if shackleT < SHACKLE then
            return
        end

        -------------------------------------------------------------------
        --  Done -- logo stays at full alpha, grid fully visible,
        --  banner is at final position (flush with top of screen)
        -------------------------------------------------------------------
        UM.openAnimFrame:SetAlpha(1)
        outerTex:SetRotation(0)
        innerTex:SetRotation(0)
        if UM.gridFrame then UM.gridFrame:SetAlpha(1) end
        if UM.hudFrame then
            UM.hudFrame:ClearAllPoints()
            UM.hudFrame:SetPoint("TOP", UIParent, "TOP", 0, 0)
        end
        self:SetScript("OnUpdate", nil)

        -- Start anchor connector line updates now that movers are visible
        if UM.unlockFrame._anchorLineDriver then
            UM.unlockFrame._anchorLineDriver:Show()
        end
        if UM.unlockFrame._anchorLineFrame then
            UM.unlockFrame._anchorLineFrame:Show()
        end

        -- ReapplyAllAnchors during open sets hasChanges; reset ONLY if
        -- the user hasn't already interacted (e.g. dragged during animation).
        if not next(pendingPositions) then
            UM.hasChanges = false
        end

        -- Auto-select a mover if requested (e.g. from cog popup link)
        if EllesmereUI._unlockAutoSelectKey then
            local autoKey = EllesmereUI._unlockAutoSelectKey
            EllesmereUI._unlockAutoSelectKey = nil
            C_Timer.After(0.6, function()
                if movers[autoKey] then
                    SelectMover(movers[autoKey])
                end
            end)
        end

        -- Fade ONLY the lock logo to 0% over 2 seconds, after 1s hold.
        -- Banner stays visible permanently (it has functional toggles).
        local LOGO_HOLD = 1.0
        local LOGO_FADE_DUR = 2.0
        local fadeElapsed = 0
        if not UM.logoFadeFrame then
            UM.logoFadeFrame = CreateFrame("Frame", nil, UIParent)
        end
        UM.logoFadeFrame:Show()
        UM.logoFadeFrame:SetScript("OnUpdate", function(ff, fdt)
            fadeElapsed = fadeElapsed + fdt
            if fadeElapsed < LOGO_HOLD then return end
            local ft = fadeElapsed - LOGO_HOLD
            if ft >= LOGO_FADE_DUR then
                if UM.openAnimFrame then UM.openAnimFrame:SetAlpha(0) end
                ff:SetScript("OnUpdate", nil)
                ff:Hide()
                return
            end
            local t = ft / LOGO_FADE_DUR
            if UM.openAnimFrame then
                UM.openAnimFrame:SetAlpha(1 - t)
            end
        end)

        -- Show one-time toolbar tip (after animation settles)
        ns.ShowUnlockTip()
    end)
end

-------------------------------------------------------------------------------
--  Close Unlock Mode — routes through save/discard logic
-------------------------------------------------------------------------------
function ns.CloseUnlockMode(afterFn)
    if not UM.isUnlocked then
        if afterFn then afterFn() end
        return
    end
    ns.RequestClose(false, afterFn)  -- triggers popup if there are unsaved changes
end

-- Expose for the options page BuildUnlockPage
-- ns.OpenUnlockMode and ns.CloseUnlockMode are already defined above as
-- function ns.OpenUnlockMode() and function ns.CloseUnlockMode()
ns.CloseUnlockMode = ns.CloseUnlockMode

-- Expose on the global EllesmereUI so SelectPage can intercept "Unlock Mode"
if EllesmereUI then
    EllesmereUI._openUnlockMode = ns.OpenUnlockMode
    function EllesmereUI:OpenUnlockMode()
        ns.OpenUnlockMode()
    end
end

-- Toggle helper + active flag alias used by options pages
if EllesmereUI and not EllesmereUI.ToggleUnlockMode then
    function EllesmereUI:ToggleUnlockMode()
        if UM.isUnlocked then
            ns.CloseUnlockMode()
        else
            ns.OpenUnlockMode()
        end
    end
    -- Options pages read _unlockActive (set by Open/Close above) since isUnlocked is local.
end

-- When the options panel tries to show while unlock mode is active,
-- close unlock mode first (with save flow), then re-show the panel after.
if EllesmereUI and EllesmereUI.RegisterOnShow then
    EllesmereUI:RegisterOnShow(function()
        if UM.isUnlocked then
            -- Hide the panel immediately — it shouldn't show during unlock mode
            local panel = EllesmereUI._mainFrame
            if panel then panel:Hide() end
            -- Close unlock mode, then re-open the panel after
            ns.CloseUnlockMode(function()
                EllesmereUI:Toggle()
            end)
        end
    end)
end


-------------------------------------------------------------------------------
--  Combat auto-suspend / resume: entering combat hides unlock mode UI but
--  preserves all pending changes; leaving combat re-opens with the same state.
-------------------------------------------------------------------------------
local function SuspendForCombat()
    if not UM.isUnlocked then return end
    combatSuspended = true
    if EllesmereUI._HideFallbackGhosts then EllesmereUI._HideFallbackGhosts() end
    if EllesmereUI._HideOverrideGhosts then EllesmereUI._HideOverrideGhosts() end

    -- Restore objective tracker
    if UM.objTrackerWasVisible then
        local objTracker = _G.ObjectiveTrackerFrame
        if objTracker then
            objTracker:SetAlpha(1)
            local wasEnabled = objTracker._eabMouseWasEnabled
            if objTracker.EnableMouse then
                pcall(objTracker.EnableMouse, objTracker, wasEnabled and true or false)
            end
        end
    end
    -- Re-apply user visibility setting (handles "never" mode for both tracker + bg)
    if _G.EllesmereUIQuestTracker and _G.EllesmereUIQuestTracker.UpdateVisibility then
        _G.EllesmereUIQuestTracker.UpdateVisibility()
    end

    -- Notify beacon reminders to restore
    if _G._EABR_BeaconRefresh then pcall(_G._EABR_BeaconRefresh) end

    -- Hide unlock UI without clearing state
    UM.isUnlocked = false
    EllesmereUI._unlockActive = false
    EllesmereUI._unlockModeActive = false

    -- Override anchors re-engage for the fight (isUnlocked is false now);
    -- ResumeAfterCombat's sweep releases them again for editing.
    if EllesmereUI._ReapplyOverrideAnchors then EllesmereUI._ReapplyOverrideAnchors() end

    -- Re-check Dragon Riding's real visibility (it force-shows while
    -- _unlockActive is true so it can be edited off-mount; must run AFTER
    -- _unlockActive is cleared above, or UpdateVisibility() still hits that
    -- force-show branch and this call is a no-op).
    if _G._EDR_UpdateVisibility then pcall(_G._EDR_UpdateVisibility) end

    if UM.unlockFrame then
        UM.unlockFrame:SetScript("OnUpdate", nil)
        UM.unlockFrame:Hide()
    end
    if UM.logoFadeFrame then UM.logoFadeFrame:SetScript("OnUpdate", nil); UM.logoFadeFrame:Hide() end
    if UM.openAnimFrame then UM.openAnimFrame:Hide() end
    if lockAnimFrame then lockAnimFrame:Hide() end
    if UM.gridFrame then UM.gridFrame:Hide() end
    if UM.hudFrame then UM.hudFrame:Hide() end
    if UM.unlockTipFrame then UM.unlockTipFrame:SetScript("OnUpdate", nil); UM.unlockTipFrame:Hide() end
    DeselectMover()
    for _, m in pairs(movers) do m:Hide() end
    HideAllGuidesAndHighlight()
    HideBlizzOwnedOverlays()
    if UM.arrowKeyFrame then UM.arrowKeyFrame:Hide() end
    UM.selectedMover = nil
    UM.selectElementPicker = nil

    -- Restore action bar alpha from saved settings (so bars are usable during combat)
    if EAB and EAB.RefreshMouseover then
        EAB:RefreshMouseover()
    end
end

local function ResumeAfterCombat()
    if not combatSuspended then return end
    combatSuspended = false
    if InCombatLockdown() then return end  -- safety check

    -- Re-enter unlock mode but skip snapshot/reset since we preserved state
    UM.isUnlocked = true
    EllesmereUI._unlockActive = true
    EllesmereUI._unlockModeActive = true
    if EllesmereUI._RefreshFallbackGhosts then EllesmereUI._RefreshFallbackGhosts() end
    -- Release override anchors back to baseline for editing (isUnlocked true).
    if EllesmereUI._ReapplyOverrideAnchors then EllesmereUI._ReapplyOverrideAnchors() end
    if EllesmereUI._RefreshOverrideGhosts then EllesmereUI._RefreshOverrideGhosts() end

    -- Re-check Dragon Riding's visibility now that _unlockActive is true again:
    -- SuspendForCombat's re-check hid the HUD for a dismounted player, and without
    -- this mirror call the force-show branch never re-evaluates on resume -- the
    -- element would stay invisible (and uneditable) until a mount/dismount re-runs UpdateVisibility.
    if _G._EDR_UpdateVisibility then pcall(_G._EDR_UpdateVisibility) end

    -- Re-hide objective tracker
    local objTracker = _G.ObjectiveTrackerFrame
    if objTracker and objTracker:IsShown() then
        UM.objTrackerWasVisible = true
        objTracker:SetAlpha(0)
        if objTracker.EnableMouse then pcall(objTracker.EnableMouse, objTracker, false) end
    end
    local qtBg = _G.EllesmereUIQTBackground
    if qtBg then qtBg:SetAlpha(0) end

    -- Notify beacon reminders to hide
    if _G._EABR_BeaconRefresh then pcall(_G._EABR_BeaconRefresh) end

    -- Re-show unlock UI
    if UM.arrowKeyFrame then UM.arrowKeyFrame:Show() end
    if UM.unlockFrame then UM.unlockFrame:Show(); UM.unlockFrame:SetAlpha(1) end
    if UM.gridFrame and UM.gridMode ~= "disabled" then UM.gridFrame:Show() end
    if UM.hudFrame then UM.hudFrame:Show() end

    -- Mirrors the OpenUnlockMode entry strip: provider enter hooks first (CDM's
    -- Additional Bar Offset may have re-applied to un-anchored bars during the
    -- combat-suspend window)...
    EllesmereUI.RunAnchorShiftEnters()
    -- ...then strip any temporary anchor-target shift (e.g. "Shift Elements if
    -- No Resource"/"...if No Bars") that may have re-applied while
    -- _unlockActive was false. _unlockActive is true again above, so the
    -- providers return 0 and this snaps shifted children back BEFORE the movers
    -- re-sync below capture their positions.
    if EllesmereUI.AnchorShiftWantsApply()
       and EllesmereUI.ReapplyAllUnlockAnchors then
        -- Force edge-preservation so custom-growth anchored bars snap to their fixed
        -- growth edge, not the center-offset position. Reset via pcall so it can't leak.
        EllesmereUI._reapplyForceEdgePreserve = true
        pcall(EllesmereUI.ReapplyAllUnlockAnchors)
        EllesmereUI._reapplyForceEdgePreserve = false
    end

    -- Re-sync all movers (Sync shows live ones and hides stale/hidden ones).
    for _, m in pairs(movers) do
        m:Sync()
        if m:IsShown() then
            m:SetAlpha(UM.darkOverlaysEnabled and 1 or MOVER_ALPHA)
        end
    end
    SortMoverFrameLevels()
    if UM.unlockFrame and UM.unlockFrame._anchorLineDriver then
        UM.unlockFrame._anchorLineDriver:Show()
    end
    if UM.unlockFrame and UM.unlockFrame._anchorLineFrame then
        UM.unlockFrame._anchorLineFrame:Show()
    end
    -- Deferred: re-apply CENTER anchor to all bar frames so resizes grow
    -- symmetrically from center rather than from whatever corner anchor
    -- was left by a previous drag or addon rebuild.
    C_Timer.After(0, function()
        for bk, m in pairs(movers) do
            if not m._dragging then
                EllesmereUI.RecenterBarAnchor(bk)
            end
        end
    end)
end

do
    local combatFrame = CreateFrame("Frame")
    combatFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    combatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    combatFrame:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_REGEN_DISABLED" then
            SuspendForCombat()
        elseif event == "PLAYER_REGEN_ENABLED" then
            -- Small delay to let combat lockdown fully clear
            C_Timer.After(0.5, ResumeAfterCombat)
        end
    end)
end

end  -- end deferred init
