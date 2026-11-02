-- End-to-end: loads main.lua against the mock and drives the editor the
-- way a user would (menus, dialog controls, timers, undo, song changes).

local M = require "mock_renoise"
local json = require "jsnp.util.json"

local TOOL = "src/com.jussisnupps.JussiSnupps.xrnx/"

local function boot()
  M.config.operator_writable = true
  M.config.undo_redoing = false
  M.install()
  T.fresh()
  package.loaded["jsnp.rn.caps"] = nil
  dofile(TOOL .. "main.lua")
  return M.tool
end

local function settle()
  for _ = 1, 5 do
    if #M.tool.timers == 0 then return end
    M.run_timers()
  end
end

local function dialog_root()
  local d = M.dialogs[#M.dialogs]
  return d and d.view
end

local function find(pred)
  return M.find_all(dialog_root(), pred)
end

local function by_tooltip(text)
  return find(function(v) return v.tooltip == text end)
end

local function button(text)
  local b = find(function(v) return v.kind == "button" and v.text == text end)
  T.ok(b[1], "button '" .. text .. "' not found")
  return b[1]
end

local function stored_patch(instr)
  return require("jsnp.model.serialize").from_lines(instr.comments)
end

T.test("main.lua registers menus and a keybinding", function()
  local tool = boot()
  T.ok(tool.menu["Main Menu:Tools:JussiSnupps:Open Editor..."])
  T.ok(tool.menu["Main Menu:Tools:JussiSnupps:New Synth Instrument"])
  T.ok(tool.menu["Main Menu:Tools:JussiSnupps:Run API Probe (for the developer)"])
  T.ok(tool.menu["Instrument Box:JussiSnupps:Edit Synth..."])
  T.ok(tool.keys["Global:Tools:JussiSnupps Open Editor"])
  T.ok(tool.preferences and tool.preferences.calibration)
end)

T.test("New Synth Instrument builds the default patch in the empty instrument", function()
  local tool = boot()
  tool.menu["Main Menu:Tools:JussiSnupps:New Synth Instrument"].invoke()
  settle()
  local instr = M.song.instruments[1]
  T.eq(#M.song.instruments, 1, "the empty instrument was reused")
  T.eq(instr.name, "JussiSnupps")
  T.eq(#instr.samples, 30)
  T.eq(#instr.sample_modulation_sets, 1)
  local p = assert(stored_patch(instr))
  T.eq(#p.oscs, 3)
  T.ok(dialog_root(), "dialog open")
  T.eq(#by_tooltip("Octave offset"), 3)
  T.eq(#by_tooltip("Note offset in semitones"), 3)
  T.eq(#by_tooltip("Fine tune in cents"), 3)
  T.ok(M.undo_log[#M.undo_log]:find("rebuild"))
end)

T.test("a second synth goes into a new instrument slot", function()
  local tool = boot()
  tool.menu["Main Menu:Tools:JussiSnupps:New Synth Instrument"].invoke()
  tool.menu["Main Menu:Tools:JussiSnupps:New Synth Instrument"].invoke()
  settle()
  T.eq(#M.song.instruments, 2)
  T.eq(M.song.selected_instrument_index, 2)
  T.eq(#M.song.instruments[2].samples, 30)
end)

T.test("editing octave/note/cent updates the instrument in place", function()
  local tool = boot()
  tool.menu["Main Menu:Tools:JussiSnupps:New Synth Instrument"].invoke()
  settle()
  local instr = M.song.instruments[1]
  local function pitch(smp)
    -- Renoise: played - base_note + transpose + fine_tune / 128
    return -smp.sample_mapping.base_note + smp.transpose + smp.fine_tune / 128
  end
  local before = pitch(instr.samples[1])
  M.user_set(by_tooltip("Octave offset")[1], 1)
  M.user_set(by_tooltip("Note offset in semitones")[1], 3)
  M.user_set(by_tooltip("Fine tune in cents")[1], 50)
  settle()
  local after = pitch(instr.samples[1])
  T.near(after - before, 15.5, 0.01)
  T.eq(#instr.samples, 30)
  local p = stored_patch(instr)
  T.eq(p.oscs[1].oct, 1)
  T.eq(p.oscs[1].semi, 3)
  T.eq(p.oscs[1].cents, 50)
  T.ok(M.undo_log[#M.undo_log]:find("batch"))
end)

T.test("adding an oscillator adds samples, a matrix row and routes", function()
  local tool = boot()
  tool.menu["Main Menu:Tools:JussiSnupps:New Synth Instrument"].invoke()
  settle()
  M.press(button("+ Add Osc"))
  settle()
  local instr = M.song.instruments[1]
  T.eq(#instr.samples, 40)
  T.eq(#by_tooltip("Octave offset"), 4)
  T.eq(#by_tooltip("Osc 4 -> Filter 1"), 1)
  T.eq(#instr.sample_modulation_sets, 1, "new osc shares the set")
end)

T.test("modulation matrix: pitch envelope on one oscillator", function()
  local tool = boot()
  tool.menu["Main Menu:Tools:JussiSnupps:New Synth Instrument"].invoke()
  settle()
  local sw = find(function(v) return v.kind == "switch" and v.items[1] == "Audio routing" end)[1]
  M.user_set(sw, 2)
  settle()
  local cell = by_tooltip("Env 1 Filter -> Osc 1 Pitch")[1]
  T.ok(cell, "pitch cell")
  M.user_set(cell, 7)
  settle()
  local instr = M.song.instruments[1]
  T.eq(#instr.sample_modulation_sets, 2)
  T.eq(instr.sample_modulation_sets[1].pitch_range, 7)
  T.eq(#instr.samples, 30)
end)

T.test("removing the filter leaves oscillators unrouted, with a warning", function()
  local tool = boot()
  tool.menu["Main Menu:Tools:JussiSnupps:New Synth Instrument"].invoke()
  settle()
  local x = by_tooltip("Remove Filter 1 and its routes")
  T.eq(#x, 0, "filters tab isn't shown yet")
  local sw = find(function(v) return v.kind == "switch" and v.items[1] == "Oscillators" end)[1]
  M.user_set(sw, 4)
  settle()
  M.press(by_tooltip("Remove Filter 1 and its routes")[1])
  settle()
  local instr = M.song.instruments[1]
  T.eq(#instr.samples, 0)
  local warn = find(function(v) return v.kind == "multiline_text" end)[1]
  T.ok(warn.text:find("isn't routed"), warn.text)
  -- route osc 1 directly
  local cell = by_tooltip("Osc 1 -> Direct")[1]
  M.user_set(cell, 100)
  settle()
  T.eq(#instr.samples, 10)
  T.eq(instr.sample_modulation_sets[1].filter_type, "None")
end)

T.test("every rack tab and both matrix tabs build", function()
  local tool = boot()
  tool.menu["Main Menu:Tools:JussiSnupps:New Synth Instrument"].invoke()
  settle()
  local rack = find(function(v) return v.kind == "switch" and v.items[1] == "Oscillators" end)[1]
  local matrix = find(function(v) return v.kind == "switch" and v.items[1] == "Audio routing" end)[1]
  for i = 1, 5 do
    M.user_set(rack, i)
    settle()
    if i <= 4 then
      local add = find(function(v) return v.kind == "button" and v.text and v.text:find("^%+ Add") end)
      M.press(add[1])
      settle()
    end
  end
  M.user_set(matrix, 2)
  settle()
  -- an LFO now exists: route it to filter cutoff
  local cell = by_tooltip("LFO 1 -> Filter 1 Cutoff")[1]
  M.user_set(cell, -30)
  settle()
  local p = stored_patch(M.song.instruments[1])
  T.eq(#p.oscs, 4)
  T.eq(#p.envs, 3)
  T.eq(#p.lfos, 1)
  T.eq(#p.filters, 2)
  T.near(require("jsnp.model.patch").get_mod(p, "lfo1", "flt1", "cutoff"), -0.3, 1e-9)
  -- global tab controls
  M.user_set(rack, 5)
  settle()
  local mono = find(function(v) return v.kind == "checkbox" end)
  T.ok(#mono >= 3)
end)

T.test("undo restores the stored patch into the editor", function()
  local tool = boot()
  tool.menu["Main Menu:Tools:JussiSnupps:New Synth Instrument"].invoke()
  settle()
  local instr = M.song.instruments[1]
  local old_lines = instr.comments
  M.user_set(by_tooltip("Octave offset")[1], 2)
  settle()
  T.eq(stored_patch(instr).oscs[1].oct, 2)
  -- Renoise's undo puts the old comments back
  M.config.undo_redoing = true
  instr.comments = old_lines
  M.config.undo_redoing = false
  settle()
  local field = by_tooltip("Octave offset")[1]
  T.eq(field.value, 0)
end)

T.test("selecting another synth instrument switches the editor", function()
  local tool = boot()
  tool.menu["Main Menu:Tools:JussiSnupps:New Synth Instrument"].invoke()
  settle()
  M.user_set(by_tooltip("Octave offset")[1], -2)
  settle()
  tool.menu["Main Menu:Tools:JussiSnupps:New Synth Instrument"].invoke()
  settle()
  T.eq(by_tooltip("Octave offset")[1].value, 0)
  M.song.selected_instrument_index = 1
  settle()
  T.eq(by_tooltip("Octave offset")[1].value, -2)
end)

T.test("song close and new song don't break the editor", function()
  local tool = boot()
  tool.menu["Main Menu:Tools:JussiSnupps:New Synth Instrument"].invoke()
  settle()
  M.user_set(by_tooltip("Octave offset")[1], 1)
  tool.app_will_save_document_observable:fire()
  tool.app_release_document_observable:fire()
  T.eq(stored_patch(M.song.instruments[1]).oscs[1].oct, 1, "pending edit flushed")
  local old = M.song
  M.install()
  M.tool = tool
  M.dialogs = { { view = dialog_root and nil } }
  M.dialogs = {}
  tool.app_new_document_observable:fire()
  settle()
  T.ok(not rawequal(old, M.song))
end)

T.test("convert asks before replacing a used instrument", function()
  local tool = boot()
  local instr = M.song.instruments[1]
  instr:insert_sample_at(1)
  M.config.prompt_answer = "Cancel"
  tool.menu["Main Menu:Tools:JussiSnupps:Open Editor..."].invoke()
  M.press(button("Convert selected"))
  T.eq(#instr.samples, 1)
  M.config.prompt_answer = "Convert"
  M.press(button("Convert selected"))
  settle()
  M.config.prompt_answer = nil
  T.eq(#instr.samples, 30)
end)

T.test("the API probe runs and reports", function()
  boot()
  local Probe = require "jsnp.probe"
  local real_print = print
  print = function() end
  local ok, err = pcall(Probe.run)
  print = real_print
  T.ok(ok, tostring(err))
  T.ok(M.messages[#M.messages]:find("probe finished"))
  T.eq(#M.song.instruments, 1, "probe instrument removed")
end)

T.test("patch JSON stays small enough for comments", function()
  local Patch = require "jsnp.model.patch"
  local p = Patch.new_default()
  T.ok(#json.encode(p) < 4000)
end)
