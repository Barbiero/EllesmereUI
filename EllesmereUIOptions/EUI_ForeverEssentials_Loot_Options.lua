if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
if not (EllesmereUI and EllesmereUI.IS_FOREVER) then return end -- Forever Essentials loads on WoW Forever only
-------------------------------------------------------------------------------
--  EUI_ForeverEssentials_Loot_Options.lua
--  Builds the "Loot" page inside the Forever Essentials module.
-------------------------------------------------------------------------------
if not EllesmereUI._ModuleNS["EllesmereUIForeverEssentials"] then return end  -- module disabled: no options page

_G._EUI_BuildLootFeedPage = function(pageName, parent, yOffset)
    local W = EllesmereUI.Widgets
    local LF = EllesmereUI._LootFeed
    local y = yOffset
    local _, h
    parent._showRowDivider = true

    local function off()
        return not LF.Get("enabled")
    end
    local function itemsOff()
        return off() or not LF.Get("items")
    end
    local function Set(key, v)
        LF.Cfg()[key] = v
        LF.ApplyStyle()
    end
    local function Source(key, text, tooltip)
        return { type = "toggle", text = text, tooltip = tooltip,
          disabled = off, disabledTooltip = "Loot Feed",
          getValue = function() return LF.Get(key) end,
          setValue = function(v)
              LF.Cfg()[key] = v
              LF.Apply()
              EllesmereUI:RefreshPage()
          end }
    end

    ---------------------------------------------------------------------------
    --  GENERAL
    ---------------------------------------------------------------------------
    _, h = W:SectionHeader(parent, "LOOT FEED", y);  y = y - h

    _, h = W:DualRow(parent, y,
        { type = "toggle", text = "Enable Loot Feed",
          tooltip = "Shows what you loot and gain as short-lived rows that fade out.",
          getValue = function() return not off() end,
          setValue = function(v)
              LF.Cfg().enabled = v
              LF.Apply()
              EllesmereUI:RefreshPage()
          end },
        { type = "labeledButton", text = "Preview", buttonText = "Show Samples",
          tooltip = "Shows a sample row for every enabled source.",
          disabled = off,
          disabledTooltip = "Loot Feed",
          onClick = function() LF.Preview() end }
    );  y = y - h

    _, h = W:Spacer(parent, y, 20);  y = y - h

    ---------------------------------------------------------------------------
    --  SOURCES
    ---------------------------------------------------------------------------
    _, h = W:SectionHeader(parent, "SOURCES", y);  y = y - h

    _, h = W:DualRow(parent, y,
        Source("items", "Items", "Items you loot or receive."),
        Source("money", "Money", "Money you loot.")
    );  y = y - h

    _, h = W:DualRow(parent, y,
        Source("reputation", "Reputation", "Reputation gains and losses, with your progress in the current standing."),
        Source("currency", "Currencies", "Honor, badges and other currencies, with your total.")
    );  y = y - h

    _, h = W:DualRow(parent, y,
        Source("skills", "Skill Ups", "Weapon and profession skill increases."),
        EllesmereUI.BlankRowCfg()
    );  y = y - h

    _, h = W:Spacer(parent, y, 20);  y = y - h

    ---------------------------------------------------------------------------
    --  ITEMS
    ---------------------------------------------------------------------------
    _, h = W:SectionHeader(parent, "ITEMS", y);  y = y - h

    local qualityValues, qualityOrder = {}, {}
    for q = 0, 5 do
        local key = tostring(q)
        local color = ITEM_QUALITY_COLORS[q]
        local label = _G["ITEM_QUALITY" .. q .. "_DESC"] or key
        qualityValues[key] = color and (color.hex .. label .. "|r") or label
        qualityOrder[#qualityOrder + 1] = key
    end

    _, h = W:DualRow(parent, y,
        { type = "dropdown", text = "Minimum Quality", values = qualityValues, order = qualityOrder,
          tooltip = "Items below this quality are not shown.",
          disabled = itemsOff, disabledTooltip = "Items",
          getValue = function() return tostring(LF.Get("minQuality")) end,
          setValue = function(v) LF.Cfg().minQuality = tonumber(v) end },
        { type = "toggle", text = "Show Item Level",
          tooltip = "Shows the item level of weapons and armor.",
          disabled = itemsOff, disabledTooltip = "Items",
          getValue = function() return LF.Get("showIlvl") end,
          setValue = function(v) LF.Cfg().showIlvl = v end }
    );  y = y - h

    _, h = W:DualRow(parent, y,
        { type = "toggle", text = "Show Vendor Price",
          tooltip = "Shows what the looted stack sells for at a vendor.",
          disabled = itemsOff, disabledTooltip = "Items",
          getValue = function() return LF.Get("showPrice") end,
          setValue = function(v) LF.Cfg().showPrice = v end },
        EllesmereUI.BlankRowCfg()
    );  y = y - h

    _, h = W:Spacer(parent, y, 20);  y = y - h

    ---------------------------------------------------------------------------
    --  LAYOUT
    ---------------------------------------------------------------------------
    _, h = W:SectionHeader(parent, "LAYOUT", y);  y = y - h

    _, h = W:DualRow(parent, y,
        { type = "slider", text = "Width", min = 150, max = 600, step = 1,
          disabled = off, disabledTooltip = "Loot Feed",
          getValue = function() return LF.Get("width") end,
          setValue = function(v) Set("width", v) end },
        { type = "slider", text = "Row Height", min = 20, max = 60, step = 1,
          disabled = off, disabledTooltip = "Loot Feed",
          getValue = function() return LF.Get("rowHeight") end,
          setValue = function(v) Set("rowHeight", v) end }
    );  y = y - h

    _, h = W:DualRow(parent, y,
        { type = "slider", text = "Max Rows", min = 1, max = 12, step = 1,
          disabled = off, disabledTooltip = "Loot Feed",
          getValue = function() return LF.Get("maxRows") end,
          setValue = function(v) Set("maxRows", v) end },
        { type = "slider", text = "Display Time", min = 1, max = 30, step = 1,
          tooltip = "Seconds a row stays before it fades out.",
          disabled = off, disabledTooltip = "Loot Feed",
          getValue = function() return LF.Get("duration") end,
          setValue = function(v) Set("duration", v) end }
    );  y = y - h

    _, h = W:DualRow(parent, y,
        { type = "dropdown", text = "Grow Direction",
          values = { UP = "Up", DOWN = "Down" }, order = { "UP", "DOWN" },
          disabled = off, disabledTooltip = "Loot Feed",
          getValue = function() return LF.Get("grow") end,
          setValue = function(v) Set("grow", v) end },
        { type = "slider", text = "Text Size", min = 8, max = 24, step = 1,
          disabled = off, disabledTooltip = "Loot Feed",
          getValue = function() return LF.Get("textSize") end,
          setValue = function(v) Set("textSize", v) end }
    );  y = y - h

    _, h = W:Spacer(parent, y, 20);  y = y - h

    ---------------------------------------------------------------------------
    --  DISPLAY
    ---------------------------------------------------------------------------
    _, h = W:SectionHeader(parent, "DISPLAY", y);  y = y - h

    local function ColorSwatch(row, prefix, tooltip, disabled, disabledTooltip)
        if EllesmereUI._prebuilding then return end
        EllesmereUI.BuildInlineSwatches(row._leftRegion, {
            { tooltip = tooltip,
              disabled = disabled, disabledTooltip = disabledTooltip,
              getValue = function() return LF.Get(prefix .. "R"), LF.Get(prefix .. "G"), LF.Get(prefix .. "B"), 1 end,
              setValue = function(r, g, b)
                  local c = LF.Cfg()
                  c[prefix .. "R"], c[prefix .. "G"], c[prefix .. "B"] = r, g, b
                  LF.ApplyStyle()
              end },
        }, { disabled = off, disabledTooltip = "Loot Feed" })
    end

    local bgRow
    bgRow, h = W:DualRow(parent, y,
        { type = "slider", text = "Background", min = 0, max = 100, step = 1,
          tooltip = "Opacity of the row background.",
          disabled = off, disabledTooltip = "Loot Feed",
          getValue = function() return math.floor(LF.Get("bgA") * 100 + 0.5) end,
          setValue = function(v) Set("bgA", v / 100) end },
        EllesmereUI.BlankRowCfg()
    );  y = y - h
    ColorSwatch(bgRow, "bg", "Background Color", off, "Loot Feed")

    local function noBorder()
        return off() or LF.Get("borderSize") == 0
    end
    local borderRow
    borderRow, h = W:DualRow(parent, y,
        { type = "slider", text = "Border Size", min = 0, max = 4, step = 1,
          tooltip = "0 hides the border.",
          disabled = off, disabledTooltip = "Loot Feed",
          getValue = function() return LF.Get("borderSize") end,
          setValue = function(v) Set("borderSize", v); EllesmereUI:RefreshPage() end },
        { type = "toggle", text = "Quality Borders",
          tooltip = "Colors the border of item rows by item quality.",
          disabled = function() return noBorder() or not LF.Get("items") end,
          disabledTooltip = "Border Size",
          getValue = function() return LF.Get("qualityBorder") end,
          setValue = function(v) Set("qualityBorder", v) end }
    );  y = y - h
    -- Nothing to colour at size 0 (the slider + inline swatch pattern).
    ColorSwatch(borderRow, "border", "Border Color", noBorder,
        function() return off() and "Loot Feed" or "Border Size" end)

    return math.abs(y)
end
