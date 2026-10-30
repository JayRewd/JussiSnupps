-- Glue between the editor UI, the patch and the Renoise instrument.
--
-- Every edit marks the patch dirty; a short timer then compiles it and
-- either updates the instrument in place (same structure) or rebuilds it.
-- The patch is written into the instrument's comments in the same undo
-- step, so Ctrl+Z restores patch and sound together.

local json = require "jsnp.util.json"
local Patch = require "jsnp.model.patch"
local Compiler = require "jsnp.compile.compiler"
local Wavegen = require "jsnp.dsp.wavegen"
local Caps = require "jsnp.rn.caps"
local Applier = require "jsnp.rn.applier"
local Ownership = require "jsnp.rn.ownership"
local Devices = require "jsnp.rn.devices"
local Dialog = require "jsnp.ui.dialog"

local Controller = {}
Controller.__index = Controller

local APPLY_DELAY_MS = 60

local function song()
  local ok, s = pcall(renoise.song)
  if ok then return s end
  return nil
end

local function log(...)
  print("JussiSnupps:", ...)
end

function Controller.new(prefs)
  local self = setmetatable({}, Controller)
  self.prefs = prefs
  self.patch = nil       -- patch being edited
  self.uid = nil         -- uid of the bound instrument's patch
  self.instr = nil       -- cached instrument object
  self.spec = nil        -- last applied spec
  self.built = nil       -- Renoise objects of the last build
  self.caps = nil
  self.pending = false
  self.force_rebuild = false
  self.writing = false
  self.status = ""
  self.problems = {}
  self.song_notifiers = {}
  self.instr_notifier = nil
  self.dialog = Dialog.new(self)
  self._on_timer = function() self:on_timer() end
  self._on_comments = function() self:on_comments_changed() end
  self._on_selected = function() self:on_selected_instrument() end
  self:load_calibration()
  return self
end

---------------------------------------------------------------------------
-- preferences (calibration cache)

function Controller:load_calibration()
  if not self.prefs then return end
  local ok = pcall(function()
    if self.prefs.calibration_version.value == renoise.RENOISE_VERSION
        and self.prefs.calibration.value ~= "" then
      Devices.import(json.decode(self.prefs.calibration.value))
    end
  end)
  if not ok then log("ignoring unreadable calibration cache") end
end

function Controller:save_calibration()
  if not (self.prefs and Devices.dirty) then return end
  pcall(function()
    self.prefs.calibration.value = json.encode(Devices.export())
    self.prefs.calibration_version.value = renoise.RENOISE_VERSION
  end)
  Devices.dirty = false
end

---------------------------------------------------------------------------
-- binding to an instrument

function Controller:filter_types()
  return (self.caps and self.caps.filter_types) or Patch.FILTER_TYPES
end

function Controller:get_caps(instr)
  if not self.caps then
    self.caps = Caps.detect(instr)
  end
  return self.caps
end

function Controller:detach_instrument()
  if self.instr_notifier then
    local obs, fn = self.instr_notifier[1], self.instr_notifier[2]
    pcall(function()
      if obs:has_notifier(fn) then obs:remove_notifier(fn) end
    end)
    self.instr_notifier = nil
  end
end

function Controller:attach_instrument(instr)
  self:detach_instrument()
  local ok, obs = pcall(function() return instr.comments_observable end)
  if ok and obs then
    pcall(function() obs:add_notifier(self._on_comments) end)
    self.instr_notifier = { obs, self._on_comments }
  end
end

-- The bound instrument (re-found by uid if it moved), or nil.
function Controller:instrument()
  if not self.uid then return nil end
  if self.instr and Ownership.uid_of(self.instr) == self.uid then
    return self.instr
  end
  local s = song()
  if not s then return nil end
  local _, instr = Ownership.find(s, self.uid)
  self.instr = instr
  if instr then
    self:attach_instrument(instr)
  else
    self:detach_instrument()
  end
  return instr
end

function Controller:instrument_index()
  local s = song()
  if not (s and self.uid) then return nil end
  return (Ownership.find(s, self.uid))
end

function Controller:unbind(reason)
  self:detach_instrument()
  self.patch, self.uid, self.instr = nil, nil, nil
  self.spec, self.built = nil, nil
  self.pending = false
  if reason then self.status = reason end
  self.dialog:refresh_all()
end

function Controller:bind(instr, patch)
  self:detach_instrument()
  self.patch = patch
  self.uid = patch.uid
  self.instr = instr
  self.spec, self.built = nil, nil
  self.pending = false
  self:attach_instrument(instr)
end

-- Binds to `instr` if it holds a patch. Returns true on success.
function Controller:bind_existing(instr)
  local uid = Ownership.uid_of(instr)
  if not uid then return false end
  if uid == self.uid then return true end
  self:flush()
  local caps = self:get_caps(instr)
  local patch, info = Ownership.read(instr, caps.filter_types)
  if not patch then
    self.status = "Can't read patch: " .. tostring(info)
    self.dialog:refresh_all()
    return false
  end
  self:bind(instr, patch)
  local spec = Compiler.compile(patch, caps)
  self.spec = spec
  self.built = Applier.adopt(instr, spec)
  if self.built then
    self.status = "Loaded " .. instr.name
  else
    self.force_rebuild = true
    self.status = "Loaded " .. instr.name .. " (it was changed outside the editor; "
      .. "the next edit or Rebuild recreates it)"
  end
  self.problems = {}
  self.dialog:refresh_all()
  return true
end

---------------------------------------------------------------------------
-- commands (menus and dialog buttons)

function Controller:open()
  local s = song()
  if s then
    -- edit the selected instrument if it's a synth; otherwise keep the
    -- current one (or show the "new / convert" page)
    self:bind_existing(s.selected_instrument)
  end
  self.dialog:show()
end

function Controller:new_instrument()
  local s = song()
  if not s then return end
  self:flush()
  local index = s.selected_instrument_index
  local instr = s.selected_instrument
  if not Ownership.is_empty(instr) then
    index = index + 1
    instr = s:insert_instrument_at(index)
  end
  s.selected_instrument_index = index
  local patch = Patch.new_default()
  instr.name = "JussiSnupps"
  self:bind(instr, patch)
  self:write_comments(instr) -- claims the instrument before building it
  self:apply(true)
  self.dialog:refresh_all()
  self.dialog:show()
end

function Controller:convert_selected()
  local s = song()
  if not s then return end
  local instr = s.selected_instrument
  if Ownership.uid_of(instr) then
    self:bind_existing(instr)
    return
  end
  if not Ownership.is_empty(instr) then
    local answer = renoise.app():show_prompt("JussiSnupps",
      string.format("Turn instrument %02X \"%s\" into a JussiSnupps synth?\n\n"
        .. "This deletes its samples and modulation sets (Ctrl+Z undoes it).",
        s.selected_instrument_index - 1, instr.name),
      { "Convert", "Cancel" })
    if answer ~= "Convert" then return end
  end
  self:flush()
  local patch = Patch.new_default()
  if instr.name == "" then instr.name = "JussiSnupps" end
  self:bind(instr, patch)
  self:write_comments(instr)
  self:apply(true)
  self.dialog:refresh_all()
  self.dialog:show()
end

function Controller:rebuild()
  if not self.patch then return end
  self:apply(true)
end

-- Called by the UI after every change to the patch.
function Controller:edited()
  if not self.patch then return end
  self.pending = true
  local tool = renoise.tool()
  if not tool:has_timer(self._on_timer) then
    tool:add_timer(self._on_timer, APPLY_DELAY_MS)
  end
end

function Controller:on_timer()
  local tool = renoise.tool()
  if tool:has_timer(self._on_timer) then
    tool:remove_timer(self._on_timer)
  end
  if self.pending then
    self:apply(false)
  end
end

-- Applies a pending edit right away (before switching instruments, saving).
function Controller:flush()
  if self.pending and self.patch then
    self:apply(false)
  end
end

---------------------------------------------------------------------------
-- compile and apply

function Controller:write_comments(instr)
  self.writing = true
  local ok, err = pcall(Ownership.write, instr, self.patch)
  self.writing = false
  if not ok then
    self.problems[#self.problems + 1] = "Couldn't save the patch in the instrument: " .. tostring(err)
  end
end

function Controller:apply(force)
  self.pending = false
  if not self.patch then return end
  local instr = self:instrument()
  if not instr then
    self:unbind("The synth instrument was deleted")
    return
  end
  local s = song()
  local caps = self:get_caps(instr)
  local spec = Compiler.compile(self.patch, caps)
  local rebuild = force or self.force_rebuild or not self.built or not self.spec
    or Compiler.signature(self.spec) ~= Compiler.signature(spec)

  Devices.approximate = false
  local t0 = os.clock()
  local mode, problems = nil, {}
  local ok, err = pcall(function()
    if not rebuild then
      pcall(function() s:describe_batch_undo("JussiSnupps: edit", 1500) end)
      local ok2, res, probs = pcall(Applier.update, instr, self.spec, spec, self.built,
        caps, Wavegen.render)
      if ok2 and res then
        mode, problems = "updated", probs
      else
        if not ok2 then log("in-place update failed, rebuilding:", res) end
        rebuild = true
      end
    end
    if rebuild then
      pcall(function() s:describe_undo("JussiSnupps: rebuild") end)
      self.built, problems = Applier.rebuild(instr, spec, caps, Wavegen.render)
      mode = "rebuilt"
    end
    self.problems = problems or {}
    self:write_comments(instr)
  end)

  local ms = math.floor((os.clock() - t0) * 1000 + 0.5)
  if ok then
    self.spec = spec
    self.force_rebuild = false
    self.status = string.format("%s in %d ms · %d paths · %d mod sets · %d samples",
      mode, ms, spec.stats.paths, spec.stats.sets, spec.stats.samples)
  else
    self.spec, self.built = nil, nil
    self.force_rebuild = true
    self.status = "Error: " .. tostring(err)
    log(err)
  end
  self:save_calibration()
  self.dialog:refresh_status()
end

-- Everything worth telling the user about the current patch.
function Controller:warnings()
  local out = {}
  if self.caps then
    for _, n in ipairs(Caps.notes(self.caps)) do out[#out + 1] = n end
  end
  if Devices.approximate then
    out[#out + 1] = "Some times/rates are approximate (couldn't read Renoise's units)"
  end
  for _, p in ipairs(self.problems or {}) do out[#out + 1] = p end
  if self.spec then
    for _, w in ipairs(self.spec.warnings) do out[#out + 1] = w end
  end
  return out
end

---------------------------------------------------------------------------
-- notifications from Renoise

function Controller:on_comments_changed()
  if self.writing or not self.patch then return end
  local s = song()
  if not (s and s:is_undo_redoing()) then return end
  -- undo/redo changed the instrument and its stored patch together:
  -- reload the patch and pick up the objects as they are now
  local instr = self:instrument()
  if not instr then
    self:unbind("The synth instrument is gone (undo)")
    return
  end
  local patch = Ownership.read(instr, self:filter_types())
  if not patch then return end
  self.patch = patch
  self.uid = patch.uid
  self.pending = false
  local spec = Compiler.compile(patch, self:get_caps(instr))
  self.spec = spec
  self.built = Applier.adopt(instr, spec)
  self.force_rebuild = self.built == nil
  self.status = "Undo/redo: patch reloaded"
  self.dialog:refresh_all()
end

function Controller:on_selected_instrument()
  if not self.dialog:visible() then return end
  local s = song()
  if not s then return end
  local instr = s.selected_instrument
  local uid = Ownership.uid_of(instr)
  if uid and uid ~= self.uid then
    self:bind_existing(instr)
  else
    self.dialog:refresh_header()
  end
end

function Controller:attach_song()
  self:detach_song()
  local s = song()
  if not s then return end
  local obs = s.selected_instrument_observable
  obs:add_notifier(self._on_selected)
  self.song_notifiers = { { obs, self._on_selected } }
end

function Controller:detach_song()
  for _, pair in ipairs(self.song_notifiers) do
    pcall(function()
      if pair[1]:has_notifier(pair[2]) then pair[1]:remove_notifier(pair[2]) end
    end)
  end
  self.song_notifiers = {}
end

function Controller:on_new_document()
  self:attach_song()
  self.status = ""
  if self.dialog:visible() then
    local s = song()
    if s then self:bind_existing(s.selected_instrument) end
  end
  self.dialog:refresh_all()
end

function Controller:on_release_document()
  self:flush()
  local tool = renoise.tool()
  if tool:has_timer(self._on_timer) then tool:remove_timer(self._on_timer) end
  self:detach_song()
  self:detach_instrument()
  self.patch, self.uid, self.instr = nil, nil, nil
  self.spec, self.built = nil, nil
  self.pending = false
end

function Controller:on_will_save()
  self:flush()
end

return Controller
