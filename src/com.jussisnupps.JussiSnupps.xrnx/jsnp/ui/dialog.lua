-- The editor window. A fixed frame (toolbar, tab switches, status) with
-- two holders whose content is rebuilt with a fresh ViewBuilder whenever
-- the patch's structure changes. Value edits never rebuild views.
-- Rebuilds are deferred to a timer so a button never removes itself
-- while its own notifier runs.

local Rack = require "jsnp.ui.rack"
local Matrix = require "jsnp.ui.matrix"
local Widgets = require "jsnp.ui.widgets"

local Dialog = {}
Dialog.__index = Dialog

local WIDTH = 660

function Dialog.new(ctrl)
  local self = setmetatable({}, Dialog)
  self.ctrl = ctrl
  self.dialog = nil
  self.frame = nil
  self.state = { rack_tab = 1, rack_page = 1, matrix_tab = 1, matrix_page = 1 }
  self.want = {}
  self._on_refresh_timer = function() self:run_refresh() end
  return self
end

function Dialog:visible()
  return self.dialog ~= nil and self.dialog.visible
end

local function song()
  local ok, s = pcall(renoise.song)
  if ok then return s end
  return nil
end

---------------------------------------------------------------------------

function Dialog:build_frame()
  local vb = renoise.ViewBuilder()
  local ctrl = self.ctrl
  self.header = vb:text{ text = "", font = "bold", width = 300 }
  self.status = vb:text{ text = "", width = WIDTH, style = "disabled" }
  self.warnings = vb:multiline_text{ text = "", width = WIDTH, height = 58 }
  self.body = vb:column{ spacing = 6 }

  self.rack_switch = vb:switch{
    items = Rack.TABS, width = WIDTH, value = self.state.rack_tab,
    notifier = function(i)
      self.state.rack_tab = i
      self:refresh("rack")
    end,
  }
  self.matrix_switch = vb:switch{
    items = Matrix.TABS, width = WIDTH, value = self.state.matrix_tab,
    notifier = function(i)
      self.state.matrix_tab = i
      self:refresh("matrix")
    end,
  }
  self.rack_holder = vb:column{}
  self.matrix_holder = vb:column{}
  self.editor = vb:column{
    spacing = 4,
    self.rack_switch,
    vb:column{ background = "group", margin = 6, width = WIDTH, self.rack_holder },
    vb:space{ height = 4 },
    self.matrix_switch,
    vb:column{ background = "group", margin = 6, width = WIDTH, self.matrix_holder },
  }
  self.empty = vb:column{
    spacing = 6,
    vb:text{ text = "The selected instrument isn't a JussiSnupps synth.", font = "bold" },
    vb:text{ text = "Create a new synth instrument, or convert the selected one "
      .. "(this replaces its samples).", width = WIDTH },
  }
  self.body_mode = nil
  self.rack_child = nil
  self.matrix_child = nil

  local toolbar = vb:row{
    spacing = 4,
    self.header,
    vb:button{ text = "New synth", width = 80,
               tooltip = "Create a new JussiSnupps instrument with the default patch",
               notifier = function() ctrl:new_instrument() end },
    vb:button{ text = "Convert selected", width = 110,
               tooltip = "Turn the selected instrument into a JussiSnupps synth",
               notifier = function() ctrl:convert_selected() end },
    vb:button{ text = "Rebuild", width = 64,
               tooltip = "Recreate the instrument from the patch",
               notifier = function() ctrl:rebuild() end },
  }
  self.frame = vb:column{
    margin = 8, spacing = 6,
    toolbar, self.body, self.warnings, self.status,
  }
end

function Dialog:show()
  if self:visible() then
    self.dialog:show()
    return
  end
  self:build_frame()
  self:rebuild_body()
  self:refresh_status()
  self.dialog = renoise.app():show_custom_dialog("JussiSnupps", self.frame,
    function(_, key) return key end) -- pass keys on, so notes can be played
  self.ctrl:attach_song()
end

---------------------------------------------------------------------------
-- deferred refreshes: what = "rack" | "matrix" | "all"

function Dialog:refresh(what)
  if not self.frame then return end
  if what == "all" then
    self.want.rack, self.want.matrix = true, true
  else
    self.want[what] = true
  end
  local tool = renoise.tool()
  if not tool:has_timer(self._on_refresh_timer) then
    tool:add_timer(self._on_refresh_timer, 10)
  end
end

function Dialog:run_refresh()
  local tool = renoise.tool()
  if tool:has_timer(self._on_refresh_timer) then
    tool:remove_timer(self._on_refresh_timer)
  end
  local want = self.want
  self.want = {}
  if not self.frame or not self.ctrl.patch then return end
  if want.rack then self:rebuild_rack() end
  if want.matrix then self:rebuild_matrix() end
end

function Dialog:context()
  local ctrl = self.ctrl
  return {
    patch = ctrl.patch,
    filter_types = ctrl:filter_types(),
    state = self.state,
    changed = function() ctrl:edited() end,
    refresh = function(what) self:refresh(what) end,
  }
end

function Dialog:rebuild_rack()
  if self.rack_child then Widgets.remove(self.rack_holder, self.rack_child) end
  self.rack_child = Rack.build(renoise.ViewBuilder(), self:context())
  Widgets.add(self.rack_holder, self.rack_child)
end

function Dialog:rebuild_matrix()
  if self.matrix_child then Widgets.remove(self.matrix_holder, self.matrix_child) end
  self.matrix_child = Matrix.build(renoise.ViewBuilder(), self:context())
  Widgets.add(self.matrix_holder, self.matrix_child)
end

function Dialog:rebuild_body()
  if not self.frame then return end
  -- Renoise views can't be compared with == or ~=, so remember which
  -- page is shown by name.
  local mode = self.ctrl.patch and "editor" or "empty"
  if self.body_mode ~= mode then
    if self.body_mode then Widgets.remove(self.body, self[self.body_mode]) end
    Widgets.add(self.body, self[mode])
    self.body_mode = mode
  end
  if self.ctrl.patch then
    self.rack_switch.value = self.state.rack_tab
    self.matrix_switch.value = self.state.matrix_tab
    self:rebuild_rack()
    self:rebuild_matrix()
  end
end

-- Called by the controller after binding, undo or song changes.
function Dialog:refresh_all()
  if not self.frame then return end
  self:rebuild_body()
  self:refresh_status()
end

function Dialog:refresh_header()
  if not self.frame then return end
  local ctrl = self.ctrl
  local text = "No synth selected"
  local index = ctrl:instrument_index()
  if ctrl.patch and index then
    local s = song()
    local name = s and s.instruments[index].name or ""
    text = string.format("Editing %02X: %s", index - 1, name)
    if s and s.selected_instrument_index ~= index then
      text = text .. "  (not the selected instrument)"
    end
  end
  self.header.text = text
end

function Dialog:refresh_status()
  if not self.frame then return end
  self:refresh_header()
  self.status.text = self.ctrl.status or ""
  local w = self.ctrl:warnings()
  self.warnings.text = (#w > 0) and table.concat(w, "\n") or "No warnings."
end

return Dialog
