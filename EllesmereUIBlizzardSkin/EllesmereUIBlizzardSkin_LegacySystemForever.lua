if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
--------------------------------------------------------------------------------
--  Progress Legacy panel on WoW Forever
--
--  Forever's "Progress Legacy" window is LegacySystemFrame (the load-on-demand
--  Blizzard_LegacySystem addon) -- an ornate PortraitMetal window with a portrait,
--  three left side tabs (Reward Track / Challenge / Tree) and a reward-track page.
--  No other pack touches it. This gives it the standard house treatment: the metal
--  frame + tile streaks + file backdrop faded under the house shell and border, the
--  corner portrait removed, the house close button, the title in the house font,
--  the common-sidetab tabs flattened to three clean states (black / gold hover /
--  soft-white active), and the content page's text re-fonted. Nothing here runs on
--  retail (IS_FOREVER is false).
--------------------------------------------------------------------------------
local ADDON_NAME, ns = ...
local EllesmereUI = _G.EllesmereUI
if not (EllesmereUI and EllesmereUI.IS_FOREVER) then return end
local WSkin = ns.WSkin
if not (WSkin and WSkin.RegisterWindow and WSkin.Shell) then return end

local FFD = setmetatable({}, { __mode = "k" })
local function GetFFD(frame)
    local d = FFD[frame]
    if not d then d = {}; FFD[frame] = d end
    return d
end

do
-- Ornate metal + backdrop atlases covering the house shell; faded recursively.
local FADE = {
    "ui-frame-metal", "ui-frame-portraitmetal", "toptilestreaks",
    "gamepad-uiframemetal", "legacy-rewards-tracker-background",
}
local function FadeArt(fr, depth)
    if depth > 5 or not fr or (fr.IsForbidden and fr:IsForbidden()) or not fr.GetNumRegions then return end
    for i = 1, fr:GetNumRegions() do
        local r = select(i, fr:GetRegions())
        local a = r and r.GetAtlas and r:GetAtlas()
        if a then
            local la = a:lower()
            for _, w in ipairs(FADE) do if la:find(w, 1, true) then r:SetAlpha(0); break end end
        end
    end
    for i = 1, fr:GetNumChildren() do FadeArt(select(i, fr:GetChildren()), depth + 1) end
end

-- A common-sidetab tab: fade the gold tab frame + glow, keep the icon, give three
-- clean states (black inactive / gold hover / soft-white active) -- same treatment
-- the Group Finder side tabs use.
local function SkinSideTab(tab)
    if not tab then return end
    if tab.Background and tab.Background.SetAlpha then tab.Background:SetAlpha(0) end
    if tab.TabGlow and tab.TabGlow.SetAlpha then tab.TabGlow:SetAlpha(0) end
    local d = GetFFD(tab)
    if not d.tabBorder and tab.SelectedTexture then
        local b = tab:CreateTexture(nil, "OVERLAY", nil, -1)
        b:SetAtlas("common-sidetab-hover")
        b:SetAllPoints(tab.SelectedTexture)
        b:SetVertexColor(0, 0, 0)
        d.tabBorder = b
    end
    if tab.SelectedTexture and tab.SelectedTexture.SetVertexColor then
        tab.SelectedTexture:SetVertexColor(0.90, 0.90, 0.92)
    end
end

-- Re-font every FontString under a frame (the reward-track points/labels/progress).
local function FontKids(fr, depth)
    if depth > 4 or not fr or not fr.GetNumRegions then return end
    for i = 1, fr:GetNumRegions() do
        local r = select(i, fr:GetRegions())
        if r and r.GetObjectType and r:GetObjectType() == "FontString" and WSkin.Font then pcall(WSkin.Font, r) end
    end
    for i = 1, fr:GetNumChildren() do FontKids(select(i, fr:GetChildren()), depth + 1) end
end

local function Skin_LegacySystem()
    local f = _G.LegacySystemFrame
    if not f then return end
    WSkin.Shell("legacysystem", f)
    WSkin.RemovePortrait(f)
    if WSkin.CommonChrome then WSkin.CommonChrome(f, "LegacySystemFrame") end
    -- The window's own file-texture backdrop + tile streaks the shell does not catch.
    if _G.LegacySystemFrameBg and _G.LegacySystemFrameBg.SetAlpha then _G.LegacySystemFrameBg:SetAlpha(0) end
    FadeArt(f, 0)
    WSkin.CloseButton(f.CloseButton or _G.LegacySystemFrameCloseButton)
    local title = (f.TitleContainer and f.TitleContainer.TitleText) or _G.LegacySystemFrameTitleText
    if title then WSkin.Font(title); if WSkin.White then WSkin.White(title) end end
    for _, tn in ipairs({ "LegacyRewardTrackTab", "LegacyChallengeTab", "LegacyTreeTab" }) do
        SkinSideTab(f[tn])
    end
    if f.RewardTrackPage then FontKids(f.RewardTrackPage, 0) end
    if f.ChallengesPage then FontKids(f.ChallengesPage, 0) end
end

-- Re-skin on show + when a content page swaps in (the pages the tabs switch between).
local function InstallHooks()
    local f = _G.LegacySystemFrame
    if not f then return end
    local d = GetFFD(f)
    if d.hooked then return end
    d.hooked = true
    local repaint = (WSkin.Debounce and WSkin.Debounce(function() pcall(Skin_LegacySystem) end))
        or function() pcall(Skin_LegacySystem) end
    if WSkin.HookShow then
        WSkin.HookShow(f, repaint)
        for _, pn in ipairs({ "RewardTrackPage", "ChallengesPage" }) do
            if f[pn] then WSkin.HookShow(f[pn], repaint) end
        end
    end
end

WSkin.RegisterWindow({
    key = "legacysystem",
    apply = function()
        pcall(Skin_LegacySystem)
        InstallHooks()
    end,
    addons = { Blizzard_LegacySystem = true },
})
end  -- Legacy System pack do-block
