if EUI_CLIENT_BLOCKED then return end
local _, ns = ...
local WHITE = "Interface\\Buttons\\WHITE8X8"
local ABSORB_STYLE_TEX = {
    striped         = "Interface\\AddOns\\EllesmereUI\\media\\textures\\shields\\striped3.tga",
    stripedReversed = "Interface\\AddOns\\EllesmereUI\\media\\textures\\shields\\striped-5-reversed.png",
    stripedThick    = "Interface\\AddOns\\EllesmereUI\\media\\textures\\shields\\striped-thick.png",
    stripedThickR   = "Interface\\AddOns\\EllesmereUI\\media\\textures\\shields\\striped-thick-r.png",
    clean           = "Interface\\Buttons\\WHITE8X8",
    blizzard        = "Interface\\AddOns\\EllesmereUI\\media\\textures\\shields\\blizzard.tga",
    largeOutlinedStripes  = "Interface\\AddOns\\EllesmereUI\\media\\textures\\shields\\large-habsorb-left.png",
    largeOutlinedStripesR = "Interface\\AddOns\\EllesmereUI\\media\\textures\\shields\\large-habsorb-right.png",
    largeStripes          = "Interface\\AddOns\\EllesmereUI\\media\\textures\\shields\\large-absorb-left.png",
    largeStripesR         = "Interface\\AddOns\\EllesmereUI\\media\\textures\\shields\\large-absorb-right.png",
    pixelsShield          = "Interface\\AddOns\\EllesmereUI\\media\\textures\\shields\\pixels-shield.tga",
    pixelsShieldEdge      = "Interface\\AddOns\\EllesmereUI\\media\\textures\\shields\\pixels-shield-edge.tga",
    pixelsShieldFill      = "Interface\\AddOns\\EllesmereUI\\media\\textures\\shields\\pixels-shield-fill.tga",
}
local ABSORB_TILED_STYLES = {
    stripedReversed = true, stripedThick = true, stripedThickR = true,
    largeStripes = true, largeStripesR = true,
    largeOutlinedStripes = true, largeOutlinedStripesR = true,
    pixelsShieldFill = true,
}
-- Absorb Style / Heal Absorb Style dropdown data, read by the Main Frames
-- rows and the Textures page tile so the lists cannot drift. Readers copy
-- them first: the SharedMedia tail is appended into the copies.
local ABSORB_STYLE_NAMES = {
    none            = "None",
    striped         = "Striped",
    stripedReversed = "Striped Reversed",
    stripedThick    = "Striped Thick",
    stripedThickR   = "Striped Thick Reversed",
    clean           = "Clean (Flat)",
    blizzard        = "Blizzard",
    largeOutlinedStripes  = "Large Outlined Stripes",    -- heal-absorb only
    largeOutlinedStripesR = "Large Outlined Stripes R",  -- heal-absorb only
    largeStripes          = "Large Stripes",
    largeStripesR         = "Large Stripes R",
    pixelsShield          = "Pixels Shield",
    pixelsShieldEdge      = "Pixels Shield Edge",        -- shield only
    pixelsShieldFill      = "Pixels Shield Fill",        -- shield only
}
local ABSORB_STYLE_ORDER = { "none", "striped", "stripedReversed", "stripedThick", "stripedThickR", "clean", "blizzard", "largeStripes", "largeStripesR", "pixelsShield", "pixelsShieldEdge", "pixelsShieldFill" }
local HEAL_ABSORB_STYLE_ORDER = { "none", "striped", "stripedReversed", "stripedThick", "stripedThickR", "clean", "blizzard", "largeOutlinedStripes", "largeOutlinedStripesR", "largeStripes", "largeStripesR", "pixelsShield" }


-- Prefer the live Unit Frames catalog; local copies keep Resource Bars standalone.
local function UnitFramesNS()
    return EllesmereUI._ModuleNS and EllesmereUI._ModuleNS["EllesmereUIUnitFrames"]
end
function ns.HealthIndicatorStyle(cfg, key)
    local style = cfg[key .. "Style"]
    if style then return style end
    local previous = cfg[key .. "Texture"]
    return previous and previous ~= "none" and previous or "striped"
end
local function ResolveStyle(style)
    local uf = UnitFramesNS()
    if uf and uf.ResolveAbsorbStyleTex then return uf.ResolveAbsorbStyleTex(style, WHITE) end
    return ABSORB_STYLE_TEX[style] or EllesmereUI.ResolveTexturePath(_G._ERB_BarTextures, style, WHITE)
end
function ns.HealthIndicatorStyleDropdown(key, cfg)
    local uf = UnitFramesNS()
    local names = uf and uf.ABSORB_STYLE_NAMES or ABSORB_STYLE_NAMES
    local sourceOrder = key == "healAbsorb" and
        (uf and uf.HEAL_ABSORB_STYLE_ORDER or HEAL_ABSORB_STYLE_ORDER) or
        (uf and uf.ABSORB_STYLE_ORDER or ABSORB_STYLE_ORDER)
    local values, order = {}, {}
    for _, k in ipairs(sourceOrder) do values[k] = names[k]; order[#order + 1] = k end
    local smNames = uf and uf.healthBarTextureNames or _G._ERB_BarTextureNames or {}
    local smOrder = uf and uf.healthBarTextureOrder or _G._ERB_BarTextureOrder or {}
    local smTextures = uf and uf.healthBarTextures or _G._ERB_BarTextures
    EllesmereUI.AppendSharedMediaTextures(smNames, smOrder, nil, smTextures)
    local addedDivider
    for _, k in ipairs(smOrder) do
        if type(k) == "string" and k:find("^sm:") and not values[k] then
            if not addedDivider then order[#order + 1] = "---"; addedDivider = true end
            values[k] = smNames[k] or k; order[#order + 1] = k
        end
    end
    -- Preserve a previously selected general-bar texture without resetting it.
    local selected = ns.HealthIndicatorStyle(cfg, key)
    if not values[selected] then
        values[selected] = (_G._ERB_BarTextureNames or {})[selected] or selected
        order[#order + 1] = selected
    end
    values._menuOpts = { itemHeight = 28, background = function(k)
        if k and k ~= "---" and k ~= "none" then return ResolveStyle(k) end
    end }
    return values, order
end
local colors = {
    absorb = { r = 0.3, g = 0.75, b = 1, a = 0.65 },
    healAbsorb = { r = 0.85, g = 0.15, b = 0.2, a = 0.75 },
    maxHealthLoss = { r = 0.35, g = 0.25, b = 0.4, a = 0.9 },
}

local function NewBar(parent, level)
    local frame = CreateFrame("StatusBar", nil, parent)
    frame:SetStatusBarTexture(WHITE)
    frame:SetFrameLevel(level)
    frame:EnableMouse(false)
    return frame
end

local function Layout(bar)
    local state, sb = bar._healthIndicators, bar._sb
    local cfg = state.cfg
    local ori = cfg.orientation or "HORIZONTAL"
    local vertical, down = ori ~= "HORIZONTAL", ori == "VERTICAL_DOWN"
    local inset = EllesmereUI.PP.mult * 0.25
    local width = math.max(0, bar:GetWidth() - 2 * inset)
    local height = math.max(0, bar:GetHeight() - 2 * inset)
    local loss = state.loss

    -- Reserve the unavailable part of the bar using Blizzard's public loss
    -- fraction. Health and absorb AMOUNTS never enter Lua arithmetic.
    sb:ClearAllPoints()
    sb:SetPoint("TOPLEFT", bar, "TOPLEFT", inset, -inset - (down and height * loss or 0))
    sb:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT",
        -inset - (not vertical and width * loss or 0),
        inset + (vertical and not down and height * loss or 0))

    local lossBar = state.maxHealthLoss
    lossBar:SetOrientation(vertical and "VERTICAL" or "HORIZONTAL")
    lossBar:SetReverseFill(not down)
    lossBar:SetRotatesTexture(vertical and not ((UnitFramesNS() or {}).ABSORB_TILED_STYLES or ABSORB_TILED_STYLES)[ns.HealthIndicatorStyle(cfg, "maxHealthLoss")])
    lossBar:SetPoint("TOPLEFT", bar, "TOPLEFT", inset, -inset)
    lossBar:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", -inset, inset)

    local fill = sb:GetStatusBarTexture()
    for _, key in ipairs({ "absorb", "healAbsorb" }) do
        local overlay = state[key]
        overlay:ClearAllPoints()
        overlay:SetOrientation(vertical and "VERTICAL" or "HORIZONTAL")
        overlay:SetReverseFill(not down)
        overlay:SetRotatesTexture(vertical and not ((UnitFramesNS() or {}).ABSORB_TILED_STYLES or ABSORB_TILED_STYLES)[ns.HealthIndicatorStyle(cfg, key)])
        -- Anchor to the native health texture: the engine moves this edge even
        -- when health is secret or interpolating. Parent clips excess to the bar.
        if vertical then
            local edge = down and "BOTTOM" or "TOP"
            local anchor = edge
            overlay:SetPoint(anchor .. "LEFT", fill, edge .. "LEFT", 0, 0)
            overlay:SetPoint(anchor .. "RIGHT", fill, edge .. "RIGHT", 0, 0)
            overlay:SetHeight(height * (1 - loss))
        else
            local anchor = "RIGHT"
            overlay:SetPoint("TOP" .. anchor, fill, "TOPRIGHT", 0, 0)
            overlay:SetPoint("BOTTOM" .. anchor, fill, "BOTTOMRIGHT", 0, 0)
            overlay:SetWidth(width * (1 - loss))
        end
    end
end

function ns.UpdateHealthIndicators(bar, cfg, maximum)
    local state = bar._healthIndicators
    if not state then
        state = {}
        bar._healthIndicators = state
        -- Children stay below the existing health text, inside its clipped fill.
        state.absorb = NewBar(bar._sb, bar._sb:GetFrameLevel() + 1)
        state.healAbsorb = NewBar(bar._sb, bar._sb:GetFrameLevel() + 2)
        state.maxHealthLoss = NewBar(bar, bar._sb:GetFrameLevel() + 1)
        state.maxHealthLoss:SetMinMaxValues(0, 1)
        bar:HookScript("OnSizeChanged", function() Layout(bar) end)
    end
    state.cfg = cfg
    local loss = 0
    if cfg.showMaxHealthLoss ~= false and ns.HealthIndicatorStyle(cfg, "maxHealthLoss") ~= "none" and GetUnitTotalModifiedMaxHealthPercent then
        local value = GetUnitTotalModifiedMaxHealthPercent("player")
        if not (issecretvalue and issecretvalue(value)) and type(value) == "number" then
            loss = math.max(0, math.min(1, value))
        end
    end
    state.loss = loss
    Layout(bar)
    for _, key in ipairs({ "absorb", "healAbsorb", "maxHealthLoss" }) do
        local style = ns.HealthIndicatorStyle(cfg, key)
        local path = ResolveStyle(style)
        if state[key]._indicatorTexture ~= path then
            state[key]:SetStatusBarTexture(path)
            state[key]._indicatorTexture = path
        end
        local uf = UnitFramesNS()
        local tiled = (uf and uf.ABSORB_TILED_STYLES or ABSORB_TILED_STYLES)[style] == true
        local fill = state[key]:GetStatusBarTexture()
        fill:SetHorizTile(tiled)
        fill:SetVertTile(tiled)
        state[key]:SetRotatesTexture((cfg.orientation or "HORIZONTAL") ~= "HORIZONTAL" and not tiled)
        local color = cfg[key .. "Color"] or colors[key]
        if style == "largeOutlinedStripes" or style == "largeOutlinedStripesR" then
            state[key]:SetStatusBarColor(1, 1, 1, color.a)
        else
            state[key]:SetStatusBarColor(color.r, color.g, color.b, color.a)
        end
    end
    state.absorb:SetMinMaxValues(0, maximum)
    state.healAbsorb:SetMinMaxValues(0, maximum)
    -- Do not compare, clamp, add or subtract these potentially secret values.
    state.absorb:SetValue(UnitGetTotalAbsorbs and UnitGetTotalAbsorbs("player") or 0)
    state.healAbsorb:SetValue(UnitGetTotalHealAbsorbs and UnitGetTotalHealAbsorbs("player") or 0)
    state.maxHealthLoss:SetValue(loss)
    state.absorb:SetShown(cfg.showAbsorbs ~= false and ns.HealthIndicatorStyle(cfg, "absorb") ~= "none")
    state.healAbsorb:SetShown(cfg.showHealAbsorbs ~= false and ns.HealthIndicatorStyle(cfg, "healAbsorb") ~= "none")
    state.maxHealthLoss:SetShown(loss > 0)
end
