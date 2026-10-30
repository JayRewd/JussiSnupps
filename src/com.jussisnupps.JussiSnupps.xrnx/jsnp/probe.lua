-- API probe: answers the questions the Renoise API docs leave open
-- (parameter names, operator/filter writability, value ranges and units,
-- limits). Works on a temporary instrument that is deleted afterwards and
-- writes everything to probe_result.json in the tool's folder.
--
-- Menu: Tools > JussiSnupps > Run API Probe (for the developer)

local json = require "jsnp.util.json"

local Probe = {}

local function try(fn, ...)
  local ok, res = pcall(fn, ...)
  if ok then return res end
  return "ERROR: " .. tostring(res)
end

local function plain(v)
  local t = type(v)
  if t == "number" or t == "string" or t == "boolean" or t == "nil" then
    return v
  end
  return "<" .. t .. ">"
end

-- Which property names exist on an object.
local function props(obj, names)
  local out = {}
  for _, n in ipairs(names) do
    local ok, v = pcall(function() return obj[n] end)
    out[n] = ok and plain(v) or "MISSING"
  end
  return out
end

local function param_info(p, sweep)
  if p == nil then return "nil" end
  return try(function()
    local info = {
      name = p.name, min = p.value_min, max = p.value_max,
      default = p.value_default, value = p.value, value_string = p.value_string,
      quantum = try(function() return p.value_quantum end),
      polarity = try(function() return p.polarity end),
    }
    if sweep then
      local old = p.value
      info.strings = {}
      for _, f in ipairs({ 0, 0.05, 0.1, 0.25, 0.5, 0.75, 1 }) do
        p.value = p.value_min + f * (p.value_max - p.value_min)
        info.strings[#info.strings + 1] = { f = f, value = p.value, s = p.value_string }
      end
      p.value = old
    end
    return info
  end)
end

local function all_params(dev, sweep)
  return try(function()
    local out = {}
    for i, p in ipairs(dev.parameters) do
      out[i] = param_info(p, sweep)
    end
    return out
  end)
end

local DEVICE_PROPS = {
  "name", "short_name", "display_name", "is_active", "target", "operator",
  "bipolar", "tempo_synced", "tempo_sync_switching_allowed",
  -- AHDSR
  "attack", "hold", "decay", "duration", "sustain", "release",
  -- LFO
  "mode", "frequency", "amplitude", "amount", "phase", "dephase", "delay",
  -- Operand / Envelope / others
  "value", "length", "play_mode", "loop_mode", "sustain_enabled",
  "sustain_position", "fade_amount", "scaling", "from", "to", "min", "max",
}

local TARGETS = { "TARGET_VOLUME", "TARGET_PANNING", "TARGET_PITCH", "TARGET_CUTOFF" }
local OPS = { "OPERATOR_ADD", "OPERATOR_SUB", "OPERATOR_MUL", "OPERATOR_DIV" }

local function probe_devices(set, r)
  local SMD = renoise.SampleModulationDevice
  r.devices = {}
  for _, path in ipairs(set.available_devices) do
    local entry = { path = path, by_target = {} }
    for _, tname in ipairs(TARGETS) do
      entry.by_target[tname] = try(function()
        local before = #set.devices
        local ret = set:insert_device_at(path, SMD[tname], before + 1)
        local dev = set.devices[before + 1]
        local t = {
          returned_type = type(ret),
          count_after = #set.devices,
          default_operator = dev.operator,
          default_bipolar = dev.bipolar,
        }
        t.operator_writes = {}
        for _, op in ipairs(OPS) do
          local ok, err = pcall(function() dev.operator = SMD[op] end)
          t.operator_writes[op] = ok and (dev.operator == SMD[op]) or ("ERROR: " .. tostring(err))
        end
        local okb = pcall(function() dev.bipolar = not t.default_bipolar end)
        t.bipolar_writable = okb and (dev.bipolar ~= t.default_bipolar)
        if tname == "TARGET_CUTOFF" then
          t.props = props(dev, DEVICE_PROPS)
          t.parameters = all_params(dev, true)
          t.tempo_sync_write = try(function()
            dev.tempo_synced = false
            return dev.tempo_synced
          end)
        end
        set:delete_device_at(before + 1)
        return t
      end)
    end
    r.devices[#r.devices + 1] = entry
  end
end

local function find_path(set, word)
  for _, p in ipairs(set.available_devices) do
    if p:lower():find(word, 1, true) then return p end
  end
  return nil
end

local function probe_order(set, r)
  -- does the flat device list keep insertion order across targets?
  r.device_order = try(function()
    local SMD = renoise.SampleModulationDevice
    local ahdsr, lfo = find_path(set, "ahdsr"), find_path(set, "lfo")
    set:insert_device_at(ahdsr, SMD.TARGET_CUTOFF, #set.devices + 1)
    set:insert_device_at(lfo, SMD.TARGET_VOLUME, #set.devices + 1)
    set:insert_device_at(ahdsr, SMD.TARGET_PITCH, #set.devices + 1)
    local out = {}
    for i, d in ipairs(set.devices) do
      out[i] = { name = d.name, target = d.target }
    end
    for i = #set.devices, 1, -1 do set:delete_device_at(i) end
    return out
  end)
end

local function probe_value_string_write(set, r)
  r.value_string_write = try(function()
    local SMD = renoise.SampleModulationDevice
    local dev = set:insert_device_at(find_path(set, "ahdsr"), SMD.TARGET_VOLUME, #set.devices + 1)
      or set.devices[#set.devices]
    local p = dev.parameters[1]
    local before = { value = p.value, s = p.value_string }
    local ok, err = pcall(function() p.value_string = "250 ms" end)
    local out = { param = p.name, before = before, ok = ok, err = plain(err),
                  after = { value = p.value, s = p.value_string } }
    set:delete_device_at(#set.devices)
    return out
  end)
end

local function probe_envelope(set, r)
  r.envelope = try(function()
    local SMD = renoise.SampleModulationDevice
    local path = find_path(set, "envelope")
    if not path then return "no envelope device" end
    local dev = set:insert_device_at(path, SMD.TARGET_CUTOFF, #set.devices + 1)
      or set.devices[#set.devices]
    local out = { default_length = try(function() return dev.length end) }
    out.set_length_1000 = try(function() dev.length = 1000; return dev.length end)
    out.set_length_6000 = try(function() dev.length = 6000; return dev.length end)
    out.points_write = try(function()
      dev.length = 1000
      dev.points = { { time = 1, value = 0 }, { time = 500, value = 1 }, { time = 1000, value = 0.5 } }
      local pts = {}
      for i, pt in ipairs(dev.points) do pts[i] = { time = pt.time, value = pt.value } end
      return pts
    end)
    out.sustain = try(function()
      dev.sustain_enabled = true
      dev.sustain_position = 500
      return { enabled = dev.sustain_enabled, position = dev.sustain_position }
    end)
    out.parameters = all_params(dev, true)
    out.tempo_synced = try(function() return dev.tempo_synced end)
    set:delete_device_at(#set.devices)
    return out
  end)
end

local function probe_set(instr, r)
  local set = instr:insert_sample_modulation_set_at(#instr.sample_modulation_sets + 1)
  r.modset = {
    initial_devices = #set.devices,
    filter_version = set.filter_version,
    available_devices = set.available_devices,
    pitch_range_default = try(function() return set.pitch_range end),
  }
  r.modset.upgrade = try(function()
    if set.filter_version < 3 then set:upgrade_filter_version() end
    return set.filter_version
  end)
  r.modset.available_filter_types = set.available_filter_types
  r.modset.filter_write = try(function()
    set.filter_type = "lp mooG"
    return set.filter_type
  end)
  r.inputs = {}
  for _, n in ipairs({ "volume_input", "panning_input", "pitch_input",
                       "cutoff_input", "resonance_input", "drive_input" }) do
    r.inputs[n] = try(function() return param_info(set[n], true) end)
  end
  probe_devices(set, r)
  probe_order(set, r)
  probe_value_string_write(set, r)
  probe_envelope(set, r)
end

local function probe_samples(instr, r)
  r.sample = try(function()
    local s = instr:insert_sample_at(#instr.samples + 1)
    local buf = s.sample_buffer
    local out = {}
    out.create = buf:create_sample_data(44100, 32, 1, 2048)
    out.frames = buf.number_of_frames
    out.loop_defaults = { mode = s.loop_mode, start = s.loop_start, ["end"] = s.loop_end }
    out.loop_end_write = try(function() s.loop_end = 2048; return s.loop_end end)
    out.fine_tune_127 = try(function() s.fine_tune = 127; return s.fine_tune end)
    out.transpose_120 = try(function() s.transpose = 120; return s.transpose end)
    out.volume_4 = try(function() s.volume = 4; return s.volume end)
    out.modulation_set_index_default = s.modulation_set_index
    out.device_chain_index_default = s.device_chain_index
    out.autofade_default = s.autofade
    out.interpolation_default = s.interpolation_mode
    out.new_note_action_default = s.new_note_action
    local m = s.sample_mapping
    out.mapping_defaults = {
      base_note = m.base_note, note_range = m.note_range, velocity_range = m.velocity_range,
      map_key_to_pitch = m.map_key_to_pitch, map_velocity_to_volume = m.map_velocity_to_volume,
      layer = m.layer,
    }
    out.note_range_write = try(function() m.note_range = { 12, 23 }; return m.note_range end)
    out.copy_from = try(function()
      s.name = "probe-src"
      m.base_note = 30
      local s2 = instr:insert_sample_at(#instr.samples + 1)
      s2:copy_from(s)
      return {
        name = s2.name, frames = s2.sample_buffer.number_of_frames,
        base_note = s2.sample_mapping.base_note, note_range = s2.sample_mapping.note_range,
        fine_tune = s2.fine_tune,
      }
    end)
    out.overlap_mode = try(function()
      instr.sample_mapping_overlap_mode = renoise.Instrument.OVERLAP_MODE_ALL
      return instr.sample_mapping_overlap_mode
    end)
    return out
  end)

  r.max_samples = try(function()
    local n = #instr.samples
    for i = n + 1, 1000 do
      local ok = pcall(function() instr:insert_sample_at(i) end)
      if not ok then break end
    end
    local max = #instr.samples
    for i = #instr.samples, 1, -1 do instr:delete_sample_at(i) end
    return max
  end)

  r.max_mod_sets = try(function()
    for i = #instr.sample_modulation_sets + 1, 300 do
      local ok = pcall(function() instr:insert_sample_modulation_set_at(i) end)
      if not ok then break end
    end
    local max = #instr.sample_modulation_sets
    for i = #instr.sample_modulation_sets, 1, -1 do instr:delete_sample_modulation_set_at(i) end
    return max
  end)
end

local function probe_misc(song, instr, r)
  r.comments = try(function()
    local long = string.rep("x", 400)
    local special = '|{"a":[1,2]}| trailing   '
    instr.comments = { long, special }
    local back = instr.comments
    return { long_len = #back[1], special_back = back[2], special_same = back[2] == special }
  end)
  r.song_methods = {}
  for _, n in ipairs({ "describe_undo", "describe_batch_undo", "is_undo_redoing", "render",
                       "trigger_instrument_note_on" }) do
    r.song_methods[n] = try(function() return type(song[n]) end)
  end
  r.viewbuilder = try(function()
    local vb = renoise.ViewBuilder()
    local col = vb:column{}
    local out = {}
    out.add_view = pcall(function() col:add_view(vb:text{ text = "a" }) end)
    out.valuefield_tostring = pcall(function()
      return vb:valuefield{ min = 0, max = 1, value = 0.5,
        tostring = function(v) return tostring(v) end,
        tonumber = function(s) return tonumber(s) end }
    end)
    out.canvas = pcall(function() return vb:canvas{ width = 10, height = 10, render = function() end } end)
    out.background = pcall(function() return vb:column{ background = "group" } end)
    return out
  end)
end

function Probe.run()
  local song = renoise.song()
  local r = {
    renoise_version = renoise.RENOISE_VERSION,
    api_version = renoise.API_VERSION,
    lua = _VERSION,
    jit = (type(jit) == "table" and jit.version) or "none",
  }
  song:describe_undo("JussiSnupps: API probe")
  local index = #song.instruments + 1
  song:insert_instrument_at(index)
  local instr = song.instruments[index]
  instr.name = "JS-PROBE"

  r.modset_section = try(probe_set, instr, r)
  r.samples_section = try(probe_samples, instr, r)
  r.misc_section = try(probe_misc, song, instr, r)

  try(function() song:delete_instrument_at(index) end)

  local text = json.encode(r)
  local path = renoise.tool().bundle_path .. "probe_result.json"
  local f = io.open(path, "w")
  if f then
    f:write(text)
    f:close()
  end
  print("JussiSnupps probe result:")
  print(text)
  renoise.app():show_message("JussiSnupps API probe finished.\n\nThe result is saved in:\n"
    .. path .. "\n\nPlease send that file to the developer. (It is also printed in "
    .. "the scripting terminal.)")
end

return Probe
