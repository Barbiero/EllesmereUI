"""Run from the repo root: python -m unittest discover -s .tools/tests.

Requires lupa (uses its Lua 5.1 runtime). Native reference: Blizzard's
Blizzard_UIPanels_Game/Mainline/GroupLootFrame.lua and GroupLootFrame.xml.
The harness models the native handlers and lifecycle, not rendering or taint.
"""
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parents[2]
RUNTIME = ROOT / "EllesmereUIQoL/EllesmereUIQoL.lua"
OPTIONS = ROOT / "EllesmereUIOptions/EUI_QoL_Options.lua"
SOURCE = RUNTIME.read_text(encoding="utf-8")
BLOCK = SOURCE.split("    -- Bonus roll confirmation.", 1)[1]
BLOCK = "do\n" + BLOCK.split("    do\n", 1)[1].split(
    "    ---------------------------------------------------------------------------", 1
)[0]

STUBS = r'''
frames, hooks, actions, shown = {}, {}, {}, 0
lootSpec, currentSpec, conflict = 65, 66, false
EllesmereUIDB = {}
EllesmereUI = {L = function(s) return s end, Lf = string.format}
ROLL, PASS, CANCEL, UNKNOWN = "Roll", "Pass", "Cancel", "Unknown"
C_AddOns = {IsAddOnLoaded = function() return conflict end}
C_SpecializationInfo = {
    GetSpecialization = function() return 1 end,
    GetSpecializationInfo = function() return currentSpec end,
}
function GetLootSpecialization() return lootSpec end
function GetSpecializationInfoByID(id) return id, "Spec " .. id end
function CreateFrame(kind, name, parent)
    local f = {scripts = {}, events = {}, visible = true, enabled = true}
    if parent then parent.overlay = f end
    function f:SetAllPoints() end
    function f:GetFrameLevel() return 1 end
    function f:SetFrameLevel() end
    function f:RegisterForClicks() end
    function f:SetShown(v) if v then self.visible=true else self:Hide() end end
    function f:Click(button,down) self.scripts.OnClick(self,button,down) end
    function f:RegisterEvent(e) self.events[e] = true end
    function f:UnregisterAllEvents() self.events = {} end
    function f:SetScript(e, fn) self.scripts[e] = fn end
    function f:GetScript(e) return self.scripts[e] end
    function f:HookScript(e, fn)
        local previous=self.scripts[e]
        self.scripts[e]=function(...)
            if previous then previous(...) end
            fn(...)
        end
    end
    function f:IsShown() return self.visible end
    function f:IsEnabled() return self.enabled end
    function f:IsProtected() return self.protected end
    function f:Hide()
        self.visible = false
        if self.scripts.OnHide then self.scripts.OnHide(self) end
    end
    frames[#frames + 1] = f
    return f
end
function hooksecurefunc(name, fn)
    hooks[name] = hooks[name] or {}
    table.insert(hooks[name], fn)
end
function fireHook(name)
    for _, fn in ipairs(hooks[name] or {}) do fn() end
end
function event(name, addonName)
    for _, f in ipairs(frames) do
        if f.events[name] then f.scripts.OnEvent(f, name, addonName) end
    end
end
BonusRollFrame = CreateFrame()
local f = BonusRollFrame
f.PromptFrame = {RollButton = CreateFrame(), PassButton = CreateFrame()}
roll, pass = f.PromptFrame.RollButton, f.PromptFrame.PassButton
nativeRoll = function(self, button, down)
    actions[#actions + 1] = {"roll", f.spellID, button, down}
    self.enabled = false
end
nativePass = function(self, button, down)
    actions[#actions + 1] = {"pass", f.spellID, button, down}
    f:Hide()
end
roll:SetScript("OnClick", nativeRoll)
pass:SetScript("OnClick", nativePass)
function start(id)
    f.visible, f.state, f.spellID, f.endTime, f.remaining = true, "prompt", id or 10, 160, 60
    roll.enabled = true
    fireHook("BonusRollFrame_StartBonusRoll")
end
function click(button)
    local target=button.overlay and button.overlay:IsShown() and button.overlay or button
    target:Click("LeftButton", false)
end
function EllesmereUI:ShowConfirmPopup(opts)
    shown = shown + 1
    dialog = opts
    EUIConfirmPopup = {_onCancel = opts.onCancel, _dimmer = CreateFrame()}
end
function enable(only)
    EllesmereUIDB.bonusRollConfirmation = true
    EllesmereUIDB.bonusRollOnly = only
    EllesmereUI._applyBonusRollConfirmation()
end
function accept()
    EUIConfirmPopup._dimmer:Hide()
    dialog.onConfirm()
end
start()
'''


class BonusRollTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime()
        self.lua.execute(STUBS)
        self.lua.execute(BLOCK)

    def run_lua(self, code):
        self.lua.execute(code)

    def test_full_files_parse_in_lua51(self):
        for path in (RUNTIME, OPTIONS, ROOT / "EllesmereUIOptions/EUI__General_Options.lua"):
            self.lua.execute("assert(loadstring(...))", path.read_text(encoding="utf-8"))

    def test_disabled_has_no_cost_or_behavior_change(self):
        self.run_lua('''
            assert(#frames == 3 and next(hooks) == nil)
            assert(roll:GetScript("OnClick") == nativeRoll)
            click(roll); assert(#actions == 1 and shown == 0)
        ''')

    def test_roll_requires_accept_and_preserves_arguments(self):
        self.run_lua('''
            enable(); click(roll)
            assert(#actions == 0 and shown == 1)
            assert(dialog.disclaimer == "Loot specialization: Spec 65")
            accept(); accept()
            assert(#actions == 1 and not roll.enabled)
            assert(actions[1][2] == 10 and actions[1][3] == "LeftButton" and actions[1][4] == false)
        ''')

    def test_pass_immediate_by_default_cancels_roll(self):
        self.run_lua('''
            enable(); click(roll); local stale = dialog.onConfirm
            click(pass); stale()
            assert(#actions == 1 and actions[1][1] == "pass" and shown == 1)
        ''')

    def test_both_mode_and_cancel(self):
        self.run_lua('''
            enable(false); click(pass)
            assert(#actions == 0 and dialog.confirmText == PASS and dialog.disclaimer == nil)
            dialog.onCancel(); accept(); assert(#actions == 0)
            click(pass); accept(); assert(#actions == 1 and actions[1][1] == "pass")
        ''')

    def test_expired_or_unavailable_rolls_never_accept(self):
        for mutation in ('BonusRollFrame.remaining = nil', 'BonusRollFrame.remaining = 0',
                         'BonusRollFrame.state = "rolling"', 'roll.enabled = false',
                         'BonusRollFrame.visible = false', 'BonusRollFrame.spellID = 11',
                         'BonusRollFrame.endTime = 180', 'lootSpec = 66',
                         'roll.visible = false'):
            with self.subTest(mutation=mutation):
                self.setUp()
                self.run_lua('enable(); click(roll); ' + mutation + '; accept(); assert(#actions == 0)')

    def test_lifecycle_invalidates_even_same_identity(self):
        for action in ('start()', 'BonusRollFrame:Hide()',
                       'fireHook("BonusRollFrame_CloseBonusRoll")',
                       'event("BONUS_ROLL_STARTED")', 'event("BONUS_ROLL_FAILED")',
                       'event("BONUS_ROLL_RESULT")', 'event("BONUS_ROLL_DEACTIVATE")',
                       'event("PLAYER_LOOT_SPEC_UPDATED")', 'event("PLAYER_SPECIALIZATION_CHANGED")'):
            with self.subTest(action=action):
                self.setUp()
                self.run_lua('enable(); click(roll); ' + action + '; accept(); assert(#actions == 0)')

    def test_setting_changes_invalidate_and_restore(self):
        self.run_lua('''
            enable(false); click(pass); enable(true); accept(); assert(#actions == 0)
            click(roll)
            EllesmereUIDB.bonusRollConfirmation = false
            EllesmereUI._applyBonusRollConfirmation()
            accept(); assert(#actions == 0)
            assert(roll:GetScript("OnClick") == nativeRoll and pass:GetScript("OnClick") == nativePass)
            for _, f in ipairs(frames) do assert(next(f.events) == nil) end
            enable(); enable(); click(roll); accept(); assert(#actions == 1)
            assert(#hooks.BonusRollFrame_StartBonusRoll == 1)
        ''')

    def test_repeated_click_replaces_request(self):
        self.run_lua('''
            enable(); click(roll); local old = dialog.onConfirm
            click(roll); old(); assert(#actions == 0)
            accept(); assert(#actions == 1)
        ''')

    def test_conflict_at_start_has_no_hooks(self):
        self.run_lua('''
            conflict = true; enable()
            assert(#frames == 3 and next(hooks) == nil)
            assert(roll:GetScript("OnClick") == nativeRoll)
        ''')

    def test_late_conflict_hides_overlays_and_preserves_native_handler(self):
        self.run_lua('''
            enable(); click(roll); local ours = roll:GetScript("OnClick")
            local other = function(...) return ours(...) end
            roll:SetScript("OnClick", other)
            conflict = true; event("ADDON_LOADED", "BonusRollConfirm"); accept()
            assert(#actions == 0 and roll:GetScript("OnClick") == other)
            assert(not roll.overlay:IsShown() and not pass.overlay:IsShown())
            click(roll); assert(#actions == 1 and shown == 1)
        ''')

    def test_never_hides_other_house_popup(self):
        self.run_lua('''
            enable(); click(roll)
            local stale = dialog.onConfirm
            EllesmereUI:ShowConfirmPopup({onCancel = function() end})
            stale(); assert(#actions == 0)
            event("BONUS_ROLL_STARTED")
            assert(EUIConfirmPopup._dimmer:IsShown())
        ''')

    def test_native_handlers_untouched_and_unrelated_addon_keeps_prompt(self):
        self.run_lua('''
            enable(false)
            assert(roll:GetScript("OnClick")==nativeRoll and pass:GetScript("OnClick")==nativePass)
            click(roll);event("ADDON_LOADED","UnrelatedAddon");accept()
            assert(#actions==1)
        ''')

    def test_overlay_visibility_and_native_hover_forwarding(self):
        self.run_lua('''
            enable(false)
            assert(roll.overlay:IsShown() and pass.overlay:IsShown())
            enable(true);assert(roll.overlay:IsShown() and not pass.overlay:IsShown())
            local entered,left=0,0
            roll:SetScript("OnEnter",function(self) assert(self==roll);entered=entered+1 end)
            roll:SetScript("OnLeave",function(self) assert(self==roll);left=left+1 end)
            roll.overlay:GetScript("OnEnter")();roll.overlay:GetScript("OnLeave")()
            assert(entered==1 and left==1)
            BonusRollFrame.state="rolling";event("BONUS_ROLL_RESULT")
            assert(not roll.overlay:IsShown() and not pass.overlay:IsShown())
            start();assert(roll.overlay:IsShown())
            BonusRollFrame.visible=false;fireHook("BonusRollFrame_CloseBonusRoll")
            assert(not roll.overlay:IsShown() and not pass.overlay:IsShown())
        ''')

    def test_current_specialization_fallback(self):
        self.run_lua('''
            lootSpec = 0; enable(); click(roll)
            assert(dialog.disclaimer == "Loot specialization: Spec 66")
            currentSpec = 70; accept(); assert(#actions == 0)
        ''')

    def test_delayed_native_frame(self):
        self.run_lua('''
            local frame = BonusRollFrame; BonusRollFrame = nil; enable()
            assert(next(hooks) == nil)
            BonusRollFrame = frame; event("ADDON_LOADED"); click(roll); accept()
            assert(#actions == 1)
        ''')

    def test_protected_and_third_party_buttons_are_untouched(self):
        for field in ('protected', '_brcHooked'):
            with self.subTest(field=field):
                self.setUp()
                self.run_lua('roll.' + field + ' = true; enable(); assert(roll:GetScript("OnClick") == nativeRoll)')

    def build_options(self, prebuild=False):
        self.run_lua('''
            y, W = 0, {}
            function W:DualRow(parent, y, left, right)
                toggle, emptySlot = left, right
                return {_leftRegion = {}}, 40
            end
            EllesmereUI.BuildInlineCog = function(region, cfg) cog = cfg end
            EllesmereUI.RefreshPage = function() end
        ''')
        if prebuild:
            self.run_lua('EllesmereUI._prebuilding = true')
        block = OPTIONS.read_text(encoding="utf-8").split("        local bonusRollRow\n", 1)[1]
        self.run_lua("local bonusRollRow\n" + block.split("        -- Keys, Logs & Brez", 1)[0])

    def test_options_defaults_cog_and_immediate_apply(self):
        self.build_options()
        self.run_lua('''
            assert(not toggle.getValue() and cog.rows[1].get() and cog.disabled())
            assert(emptySlot.type == "label" and emptySlot.text == "")
            toggle.setValue(true); assert(not cog.disabled())
            click(roll); cog.rows[1].set(false); accept(); assert(#actions == 0)
            click(pass); accept(); assert(#actions == 1)
            toggle.setValue(false); assert(cog.disabled())
            conflict = true; assert(toggle.disabled() and cog.disabled())
        ''')

    def test_search_prebuild_does_not_create_cog(self):
        self.build_options(prebuild=True)
        self.run_lua('assert(cog == nil and #frames == 3)')

    def test_qol_reset_cancels_and_restores_defaults(self):
        self.run_lua('''
            EllesmereUI._ModuleNS = {EllesmereUIQoL = {}}
            EllesmereUI.RegisterModule = function(self, name, module) registered = module end
            EllesmereUI._applyHideBlizzardPartyFrame = function() end
            EllesmereUI.InvalidatePageCache = function() end
            IsLoggedIn = function() return false end
            SlashCmdList = {}
        ''')
        self.lua.execute(OPTIONS.read_text(encoding="utf-8"))
        self.run_lua('''
            local init = frames[#frames]
            init.UnregisterEvent = function(self, e) self.events[e] = nil end
            init.scripts.OnEvent(init)
            enable(false); click(roll); registered.onReset(); accept()
            assert(#actions == 0 and not EllesmereUIDB.bonusRollConfirmation and EllesmereUIDB.bonusRollOnly)
            assert(roll:GetScript("OnClick") == nativeRoll)
        ''')


if __name__ == "__main__":
    unittest.main()
