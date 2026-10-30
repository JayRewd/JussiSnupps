-- JussiSnupps: a modular synth editor that builds native Renoise
-- instruments. Oscillators, AHDSR envelopes, LFOs and filters, connected
-- through a routing matrix.
--
-- While developing, uncomment to reload the tool whenever a file changes:
-- _AUTO_RELOAD_DEBUG = true

local Controller = require "jsnp.controller"
local Probe = require "jsnp.probe"

math.randomseed(os.time() + math.floor((os.clock() * 1000000) % 1000000))

local prefs = renoise.Document.create("JussiSnuppsPreferences") {
  calibration = "",
  calibration_version = "",
}
renoise.tool().preferences = prefs

local controller = Controller.new(prefs)
local tool = renoise.tool()

tool:add_menu_entry{
  name = "Main Menu:Tools:JussiSnupps:Open Editor...",
  invoke = function() controller:open() end,
}
tool:add_menu_entry{
  name = "Main Menu:Tools:JussiSnupps:New Synth Instrument",
  invoke = function() controller:new_instrument() end,
}
tool:add_menu_entry{
  name = "--- Main Menu:Tools:JussiSnupps:Run API Probe (for the developer)",
  invoke = function() Probe.run() end,
}
tool:add_menu_entry{
  name = "Instrument Box:JussiSnupps:Edit Synth...",
  invoke = function() controller:open() end,
}
tool:add_menu_entry{
  name = "Instrument Box:JussiSnupps:New Synth Instrument",
  invoke = function() controller:new_instrument() end,
}
tool:add_keybinding{
  name = "Global:Tools:JussiSnupps Open Editor",
  invoke = function(repeated)
    if not repeated then controller:open() end
  end,
}

tool.app_new_document_observable:add_notifier(function()
  controller:on_new_document()
end)
tool.app_release_document_observable:add_notifier(function()
  controller:on_release_document()
end)
pcall(function()
  tool.app_will_save_document_observable:add_notifier(function()
    controller:on_will_save()
  end)
end)
