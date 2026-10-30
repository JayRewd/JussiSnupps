-- A strict stand-in for the parts of the Renoise Lua API (6.2) that
-- JussiSnupps uses. Unknown properties, read-only writes, wrong types and
-- out-of-range values raise errors, like Renoise does, so API mistakes
-- show up in offline tests. Behaviour that the real API leaves open is
-- configurable through M.config.

local M = {}

M.config = {
  operator_writable = true,
  max_samples = 255,
  undo_redoing = false,
  prompt_answer = nil, -- nil = first button
}

local DATA = setmetatable({}, { __mode = "k" })

local function fail(fmt, ...)
  error(string.format(fmt, ...), 3)
end

-- Makes a constructor for strict objects.
-- props: key -> { v = default | fn(), ro = bool, type = "number"|..., range = {lo,hi},
--                 int = bool, get = fn(obj, data), set = fn(obj, data, v) }
local function class(name, props, methods)
  methods = methods or {}
  return function(init)
    local data = {}
    for k, p in pairs(props) do
      if type(p.v) == "function" then data[k] = p.v() else data[k] = p.v end
    end
    for k, v in pairs(init or {}) do data[k] = v end
    local obj = {}
    DATA[obj] = data
    setmetatable(obj, {
      __index = function(t, k)
        local m = methods[k]
        if m then return m end
        local p = props[k]
        if not p then fail("%s has no property '%s'", name, tostring(k)) end
        if p.get then return p.get(t, data) end
        return data[k]
      end,
      __newindex = function(t, k, v)
        local p = props[k]
        if not p then fail("%s has no property '%s'", name, tostring(k)) end
        if p.ro then fail("%s.%s is read-only", name, k) end
        if p.type and type(v) ~= p.type then
          fail("%s.%s expects a %s, got %s", name, k, p.type, type(v))
        end
        if p.int and v ~= math.floor(v) then fail("%s.%s expects an integer, got %s", name, k, tostring(v)) end
        if p.range and (v < p.range[1] or v > p.range[2]) then
          fail("%s.%s = %s is outside %s..%s", name, k, tostring(v), p.range[1], p.range[2])
        end
        if p.set then p.set(t, data, v) else data[k] = v end
      end,
      __tostring = function() return name end,
    })
    return obj
  end
end
M.class = class

local function D(obj) return DATA[obj] end

local function copy_list(t)
  local out = {}
  for i, v in ipairs(t) do out[i] = v end
  return out
end

---------------------------------------------------------------------------
-- observables

local function Observable()
  local o = { fns = {} }
  function o:add_notifier(fn)
    for _, f in ipairs(self.fns) do
      if f == fn then error("notifier already added", 2) end
    end
    self.fns[#self.fns + 1] = fn
  end
  function o:remove_notifier(fn)
    for i, f in ipairs(self.fns) do
      if f == fn then table.remove(self.fns, i) return end
    end
    error("notifier not found", 2)
  end
  function o:has_notifier(fn)
    for _, f in ipairs(self.fns) do
      if f == fn then return true end
    end
    return false
  end
  function o:fire()
    for _, f in ipairs(copy_list(self.fns)) do f() end
  end
  return o
end
M.Observable = Observable

---------------------------------------------------------------------------
-- device parameters with value strings in real units

local function fmt_ms(ms)
  if ms < 1000 then return string.format("%.1f ms", ms) end
  return string.format("%.2f s", ms / 1000)
end

M.curves = {
  time = function(v) return fmt_ms(1 + 9999 * v ^ 2.5) end,
  hz = function(v) return string.format("%.3f Hz", 0.01 * 2000 ^ v) end,
  pct = function(v) return string.format("%d %%", math.floor(v * 100 + 0.5)) end,
  deg = function(v) return string.format("%d deg", math.floor(v + 0.5)) end,
  plain = function(v) return string.format("%.3f", v) end,
}

local Param = class("DeviceParameter", {
  name = { ro = true },
  value_min = { ro = true }, value_max = { ro = true }, value_default = { ro = true },
  value_quantum = { ro = true, v = 0 }, polarity = { ro = true, v = 1 },
  value = {
    type = "number",
    set = function(_, d, v)
      if v < d.value_min - 1e-9 or v > d.value_max + 1e-9 then
        error(string.format("DeviceParameter %s value %s outside %s..%s",
          d.name, tostring(v), d.value_min, d.value_max), 3)
      end
      d.value = v
    end,
  },
  value_string = {
    get = function(_, d)
      return d.fmt((d.value - d.value_min) / (d.value_max - d.value_min) *
        (d.raw_span or 1) + (d.raw_min or 0))
    end,
    ro = true,
  },
  fmt = { ro = true }, raw_span = { ro = true }, raw_min = { ro = true },
})

local function param(name, min, max, default, fmt, raw_min, raw_span)
  return Param{ name = name, value_min = min, value_max = max, value_default = default,
                value = default, fmt = fmt or M.curves.plain,
                raw_min = raw_min or min, raw_span = raw_span or (max - min) }
end
M.param = param

---------------------------------------------------------------------------
-- modulation devices

local DEVICE_PATHS = {
  "Modulation/AHDSR", "Modulation/Envelope", "Modulation/Fader",
  "Modulation/Key Tracking", "Modulation/LFO", "Modulation/Operand",
  "Modulation/Stepper", "Modulation/Velocity Tracking",
}
M.DEVICE_PATHS = DEVICE_PATHS

local FILTER_TYPES = {
  "None", "LP Clean", "LP K35", "LP Moog", "LP Diode", "HP Clean", "HP K35",
  "HP Moog", "BP Clean", "BP K35", "BP Moog", "BandPass", "BandStop", "Vowel",
  "Comb", "Decimator", "Dist Shape", "Dist Fold", "AM Sine", "AM Triangle",
  "AM Saw", "AM Pulse",
}
M.FILTER_TYPES = FILTER_TYPES

local function base_props(extra)
  local p = {
    name = { ro = true }, short_name = { ro = true },
    display_name = { type = "string" },
    is_active = { type = "boolean", v = true },
    target = { ro = true },
    operator = {
      type = "number", range = { 1, 4 },
      set = function(_, d, v)
        if not M.config.operator_writable then
          error("SampleModulationDevice.operator is read-only", 3)
        end
        d.operator = v
      end,
    },
    bipolar = { type = "boolean", v = false },
    tempo_synced = { type = "boolean", v = false },
    tempo_sync_switching_allowed = { ro = true, v = true },
    parameters = { ro = true, get = function(_, d) return copy_list(d.params) end },
    is_maximized = { type = "boolean", v = true },
  }
  for k, v in pairs(extra) do p[k] = v end
  return p
end

local function param_prop(key)
  return { ro = true, get = function(_, d) return d.named[key] end }
end

local Ahdsr = class("SampleAhdsrModulationDevice", base_props{
  attack = param_prop("attack"), hold = param_prop("hold"), decay = param_prop("decay"),
  sustain = param_prop("sustain"), release = param_prop("release"),
})
local Lfo = class("SampleLfoModulationDevice", base_props{
  mode = { type = "number", range = { 1, 4 }, int = true, v = 1 },
  frequency = param_prop("frequency"), amplitude = param_prop("amplitude"),
  dephase = param_prop("dephase"), delay = param_prop("delay"),
})
local Operand = class("SampleOperandModulationDevice", base_props{
  value = param_prop("value"),
})
local Generic = class("SampleModulationDevice", base_props{})

local function make_device(path, target)
  local default_op = (target == 1) and 3 or 1
  local c = M.curves
  local short = path:match("/(.*)$")
  local init = { name = short, short_name = short, display_name = short,
                 target = target, operator = default_op, path = path }
  if short == "AHDSR" then
    init.named = {
      attack = param("Attack", 0, 1, 0, c.time), hold = param("Hold", 0, 1, 0, c.time),
      decay = param("Decay", 0, 1, 0.5, c.time), sustain = param("Sustain", 0, 1, 1, c.pct),
      release = param("Release", 0, 1, 0.2, c.time),
    }
    init.params = { init.named.attack, init.named.hold, init.named.decay,
                    init.named.sustain, init.named.release }
    return Ahdsr(init)
  elseif short == "LFO" then
    init.named = {
      frequency = param("Frequency", 0, 1, 0.5, c.hz),
      amplitude = param("Amplitude", 0, 1, 1, c.pct),
      dephase = param("Phase", 0, 360, 0, c.deg),
      delay = param("Delay", 0, 1, 0, c.time),
    }
    init.params = { init.named.frequency, init.named.amplitude, init.named.dephase,
                    init.named.delay }
    init.bipolar = true
    return Lfo(init)
  elseif short == "Operand" then
    init.named = { value = param("Value", 0, 1, 1, c.plain) }
    init.params = { init.named.value }
    return Operand(init)
  end
  init.named, init.params = {}, {}
  return Generic(init)
end

---------------------------------------------------------------------------
-- modulation sets

local function input_param(name, default)
  return param(name, 0, 1, default, M.curves.plain)
end

local ModSet = class("SampleModulationSet", {
  name = { type = "string", v = "Modulation" },
  filter_version = { ro = true, v = 3 },
  available_filter_types = { ro = true, get = function() return copy_list(FILTER_TYPES) end },
  filter_type = {
    type = "string", v = "None",
    set = function(_, d, v)
      for _, t in ipairs(FILTER_TYPES) do
        if t:lower() == v:lower() then d.filter_type = t return end
      end
      error("unknown filter type '" .. v .. "'", 3)
    end,
  },
  available_devices = { ro = true, get = function() return copy_list(DEVICE_PATHS) end },
  devices = { ro = true, get = function(_, d) return copy_list(d.devs) end },
  pitch_range = { type = "number", int = true, range = { 1, 96 }, v = 12 },
  volume_input = { ro = true, v = function() return input_param("Volume", 1) end },
  panning_input = { ro = true, v = function() return input_param("Panning", 0.5) end },
  pitch_input = { ro = true, v = function() return input_param("Pitch", 0.5) end },
  cutoff_input = { ro = true, v = function() return input_param("Cutoff", 1) end },
  resonance_input = { ro = true, v = function() return input_param("Resonance", 0) end },
  drive_input = { ro = true, v = function() return input_param("Drive", 0) end },
}, {
  insert_device_at = function(self, path, target, index)
    local d = D(self)
    local found = false
    for _, p in ipairs(DEVICE_PATHS) do
      if p == path then found = true end
    end
    if not found then error("unknown device path '" .. tostring(path) .. "'", 2) end
    if type(target) ~= "number" or target < 1 or target > 6 then
      error("bad target " .. tostring(target), 2)
    end
    if index < 1 or index > #d.devs + 1 then error("bad device index " .. index, 2) end
    local dev = make_device(path, target)
    table.insert(d.devs, index, dev)
    return dev
  end,
  delete_device_at = function(self, index)
    local d = D(self)
    if index < 1 or index > #d.devs then error("bad device index " .. index, 2) end
    table.remove(d.devs, index)
  end,
  device = function(self, index) return D(self).devs[index] end,
  upgrade_filter_version = function() end,
  init = function(self) D(self).devs = {} end,
})

---------------------------------------------------------------------------
-- samples

local Buffer = class("SampleBuffer", {
  has_sample_data = { ro = true, get = function(_, d) return d.frames ~= nil end },
  number_of_frames = { ro = true, get = function(_, d) return d.frames and #d.frames or 0 end },
  number_of_channels = { ro = true, get = function(_, d) return d.channels or 0 end },
  sample_rate = { ro = true, get = function(_, d) return d.rate or 44100 end },
  bit_depth = { ro = true, get = function(_, d) return d.bits or 16 end },
}, {
  create_sample_data = function(self, rate, bits, channels, frames)
    local d = D(self)
    assert(rate >= 1 and bits == 32 or bits == 16 or bits == 24 or bits == 8, "bad bit depth")
    assert(channels == 1 or channels == 2, "bad channel count")
    assert(frames >= 1, "bad frame count")
    d.rate, d.bits, d.channels = rate, bits, channels
    d.frames = {}
    for i = 1, frames do d.frames[i] = 0 end
    return true
  end,
  delete_sample_data = function(self) D(self).frames = nil end,
  prepare_sample_data_changes = function(self) D(self).preparing = true end,
  finalize_sample_data_changes = function(self)
    local d = D(self)
    if not d.preparing then error("finalize without prepare", 2) end
    d.preparing = false
    d.writes = (d.writes or 0) + 1
  end,
  set_sample_data = function(self, ch, frame, v)
    local d = D(self)
    if not d.frames then error("no sample data", 2) end
    if ch < 1 or ch > d.channels then error("bad channel", 2) end
    if frame < 1 or frame > #d.frames then error("bad frame " .. frame, 2) end
    if type(v) ~= "number" or v ~= v then error("bad sample value", 2) end
    d.frames[frame] = math.max(-1, math.min(1, v))
  end,
  sample_data = function(self, ch, frame) return D(self).frames[frame] end,
})

local function range_pair(lo, hi)
  return function(_, d, v, key)
    assert(type(v) == "table" and #v == 2, "expected {lo, hi}")
    assert(v[1] >= lo and v[2] <= hi and v[1] <= v[2], "range out of bounds")
  end
end

local Mapping = class("SampleMapping", {
  base_note = { type = "number", int = true, range = { 0, 119 }, v = 48 },
  note_range = {
    get = function(_, d) return { d.note_range[1], d.note_range[2] } end,
    set = function(t, d, v) range_pair(0, 119)(t, d, v); d.note_range = { v[1], v[2] } end,
    v = function() return { 0, 119 } end,
  },
  velocity_range = {
    get = function(_, d) return { d.velocity_range[1], d.velocity_range[2] } end,
    set = function(t, d, v) range_pair(0, 127)(t, d, v); d.velocity_range = { v[1], v[2] } end,
    v = function() return { 0, 127 } end,
  },
  map_key_to_pitch = { type = "boolean", v = true },
  map_velocity_to_volume = { type = "boolean", v = true },
  layer = { ro = true, v = 1 },
  read_only = { ro = true, v = false },
})

local function loop_check(t, d, v, key)
  local frames = d.sample_buffer.number_of_frames
  if v < 1 or v > math.max(1, frames) then
    error(string.format("Sample.%s = %s outside 1..%d", key, tostring(v), frames), 4)
  end
  d[key] = v
end

local Sample = class("Sample", {
  name = { type = "string", v = "" },
  volume = { type = "number", range = { 0, 4 }, v = 1 },
  panning = { type = "number", range = { 0, 1 }, v = 0.5 },
  transpose = { type = "number", int = true, range = { -120, 120 }, v = 0 },
  fine_tune = { type = "number", int = true, range = { -127, 127 }, v = 0 },
  interpolation_mode = { type = "number", int = true, range = { 1, 4 }, v = 3 },
  oversample_enabled = { type = "boolean", v = false },
  new_note_action = { type = "number", int = true, range = { 1, 3 }, v = 1 },
  autofade = { type = "boolean", v = false },
  oneshot = { type = "boolean", v = false },
  loop_mode = { type = "number", int = true, range = { 1, 4 }, v = 1 },
  loop_start = { type = "number", int = true, set = function(t, d, v) loop_check(t, d, v, "loop_start") end, v = 1 },
  loop_end = { type = "number", int = true, set = function(t, d, v) loop_check(t, d, v, "loop_end") end, v = 1 },
  modulation_set_index = {
    type = "number", int = true,
    set = function(_, d, v)
      local n = #D(d.instrument).sets
      if v < 0 or v > n then
        error(string.format("modulation_set_index %d outside 0..%d", v, n), 3)
      end
      d.modulation_set_index = v
    end,
    v = 0,
  },
  device_chain_index = { type = "number", int = true, v = 0 },
  sample_buffer = { ro = true },
  sample_mapping = { ro = true },
  instrument = { ro = true },
}, {
  copy_from = function(self, other)
    local d, o = D(self), D(other)
    for k, v in pairs(o) do
      if k ~= "sample_buffer" and k ~= "sample_mapping" and k ~= "instrument" then d[k] = v end
    end
  end,
  clear = function() end,
})

local function new_sample(instr)
  return Sample{ sample_buffer = Buffer(), sample_mapping = Mapping(), instrument = instr }
end

---------------------------------------------------------------------------
-- instruments and song

local Strict = class -- alias

local TriggerOptions = Strict("InstrumentTriggerOptions", {
  monophonic = { type = "boolean", v = false },
  monophonic_glide = { type = "number", int = true, range = { 0, 255 }, v = 0 },
})
local PluginProps = Strict("InstrumentPluginProperties", {
  plugin_loaded = { ro = true, v = false },
})

local Instrument = class("Instrument", {
  name = { type = "string", v = "" },
  comments = {
    get = function(_, d) return copy_list(d.comments) end,
    set = function(t, d, v)
      assert(type(v) == "table", "comments must be a table")
      for _, line in ipairs(v) do assert(type(line) == "string", "comment lines must be strings") end
      d.comments = copy_list(v)
      d.comments_observable:fire()
    end,
    v = function() return {} end,
  },
  comments_observable = { ro = true, v = Observable },
  samples = { ro = true, get = function(_, d) return copy_list(d.samples) end },
  sample_modulation_sets = { ro = true, get = function(_, d) return copy_list(d.sets) end },
  phrases = { ro = true, v = function() return {} end },
  plugin_properties = { ro = true, v = function() return PluginProps() end },
  trigger_options = { ro = true, v = function() return TriggerOptions() end },
  sample_mapping_overlap_mode = { type = "number", int = true, range = { 0, 2 }, v = 0 },
}, {
  insert_sample_at = function(self, index)
    local d = D(self)
    if index < 1 or index > #d.samples + 1 then error("bad sample index " .. index, 2) end
    if #d.samples >= M.config.max_samples then error("too many samples", 2) end
    local s = new_sample(self)
    table.insert(d.samples, index, s)
    return s
  end,
  delete_sample_at = function(self, index)
    local d = D(self)
    if index < 1 or index > #d.samples then error("bad sample index " .. index, 2) end
    table.remove(d.samples, index)
  end,
  sample = function(self, i) return D(self).samples[i] end,
  insert_sample_modulation_set_at = function(self, index)
    local d = D(self)
    if index < 1 or index > #d.sets + 1 then error("bad modulation set index " .. index, 2) end
    local set = ModSet{ devs = {} }
    table.insert(d.sets, index, set)
    for _, s in ipairs(d.samples) do
      local sd = D(s)
      if sd.modulation_set_index >= index then sd.modulation_set_index = sd.modulation_set_index + 1 end
    end
    return set
  end,
  delete_sample_modulation_set_at = function(self, index)
    local d = D(self)
    if index < 1 or index > #d.sets then error("bad modulation set index " .. index, 2) end
    table.remove(d.sets, index)
    for _, s in ipairs(d.samples) do
      local sd = D(s)
      if sd.modulation_set_index == index then
        sd.modulation_set_index = 0
      elseif sd.modulation_set_index > index then
        sd.modulation_set_index = sd.modulation_set_index - 1
      end
    end
  end,
  sample_modulation_set = function(self, i) return D(self).sets[i] end,
})

local function new_instrument()
  return Instrument{ samples = {}, sets = {} }
end
M.new_instrument = new_instrument

local Song = class("Song", {
  instruments = { ro = true, get = function(_, d) return copy_list(d.instruments) end },
  selected_instrument = { ro = true, get = function(_, d) return d.instruments[d.selected_instrument_index] end },
  selected_instrument_index = {
    type = "number", int = true,
    set = function(_, d, v)
      if v < 1 or v > #d.instruments then error("bad instrument index " .. v, 3) end
      d.selected_instrument_index = v
      d.selected_instrument_observable:fire()
    end,
    v = 1,
  },
  selected_instrument_observable = { ro = true, v = Observable },
  tool_data = { v = nil },
}, {
  instrument = function(self, i) return D(self).instruments[i] end,
  insert_instrument_at = function(self, index)
    local d = D(self)
    if index < 1 or index > #d.instruments + 1 then error("bad instrument index", 2) end
    local instr = new_instrument()
    table.insert(d.instruments, index, instr)
    return instr
  end,
  delete_instrument_at = function(self, index)
    local d = D(self)
    table.remove(d.instruments, index)
    if d.selected_instrument_index > #d.instruments then
      d.selected_instrument_index = math.max(1, #d.instruments)
    end
  end,
  describe_undo = function(self, desc) M.undo_log[#M.undo_log + 1] = desc end,
  describe_batch_undo = function(self, desc) M.undo_log[#M.undo_log + 1] = "batch:" .. desc end,
  is_undo_redoing = function() return M.config.undo_redoing end,
})

---------------------------------------------------------------------------
-- ViewBuilder

local COMMON = {
  "id", "visible", "width", "height", "size", "tooltip", "origin", "cursor",
  "active", "midi_mapping",
}
local VIEW_PROPS = {
  column = { "margin", "spacing", "background", "style", "uniform", "mouse_handler", "mouse_events" },
  row = { "margin", "spacing", "background", "style", "uniform", "mouse_handler", "mouse_events" },
  space = {},
  text = { "text", "font", "style", "color", "orientation", "align" },
  multiline_text = { "text", "font", "style", "paragraphs" },
  textfield = { "text", "value", "notifier", "align", "edit_mode", "bind" },
  button = { "text", "bitmap", "align", "font", "color", "secondary_color", "style",
             "notifier", "pressed", "released" },
  checkbox = { "value", "notifier", "bind" },
  switch = { "items", "value", "notifier", "bind" },
  popup = { "items", "value", "notifier", "bind" },
  valuebox = { "min", "max", "value", "steps", "notifier", "bind", "tostring", "tonumber" },
  valuefield = { "min", "max", "value", "align", "notifier", "bind", "tostring", "tonumber" },
  canvas = { "mode", "render", "mouse_handler", "mouse_events" },
}

M.views = {}

local function make_view(kind, props)
  local allowed = {}
  for _, k in ipairs(COMMON) do allowed[k] = true end
  for _, k in ipairs(VIEW_PROPS[kind]) do allowed[k] = true end
  local data = { kind = kind, children = {} }
  for k, v in pairs(props or {}) do
    if type(k) == "number" then
      data.children[#data.children + 1] = v
    elseif not allowed[k] then
      error(string.format("vb:%s has no property '%s'", kind, k), 3)
    else
      data[k] = v
    end
  end
  if kind == "valuebox" or kind == "valuefield" then
    local v, lo, hi = data.value or 0, data.min or 0, data.max or 100
    if v < lo or v > hi then
      error(string.format("vb:%s value %s outside %s..%s", kind, tostring(v), lo, hi), 3)
    end
    if (data.tostring ~= nil) ~= (data.tonumber ~= nil) then
      error("vb:" .. kind .. " needs both tostring and tonumber", 3)
    end
  end
  if (kind == "popup" or kind == "switch") and data.value then
    local n = #(data.items or {})
    if data.value < 1 or data.value > n then
      error(string.format("vb:%s value %s outside 1..%d", kind, tostring(data.value), n), 3)
    end
  end
  local view = {}
  local methods = {}
  function methods.add_view(_, child)
    for _, c in ipairs(data.children) do
      if c == child then error("view already added", 2) end
    end
    data.children[#data.children + 1] = child
  end
  function methods.remove_view(_, child)
    for i, c in ipairs(data.children) do
      if c == child then table.remove(data.children, i) return end
    end
    error("view is not a child", 2)
  end
  setmetatable(view, {
    __index = function(_, k)
      if methods[k] then return methods[k] end
      if k == "views" then return copy_list(data.children) end
      if k == "kind" or k == "children" then return data[k] end
      if not allowed[k] then error(string.format("vb:%s has no property '%s'", kind, k), 2) end
      return data[k]
    end,
    __newindex = function(_, k, v)
      if not allowed[k] then error(string.format("vb:%s has no property '%s'", kind, k), 2) end
      data[k] = v
    end,
  })
  M.views[#M.views + 1] = view
  return view
end

local function ViewBuilder()
  local vb = {}
  for kind in pairs(VIEW_PROPS) do
    vb[kind] = function(_, props) return make_view(kind, props) end
  end
  vb.views = {}
  return vb
end

-- Walks a view tree depth-first.
function M.walk(view, fn)
  fn(view)
  for _, c in ipairs(view.children) do M.walk(c, fn) end
end

-- All views in the tree under `root` matching `pred`.
function M.find_all(root, pred)
  local out = {}
  M.walk(root, function(v) if pred(v) then out[#out + 1] = v end end)
  return out
end

-- Simulates a user changing a control: sets the value, calls the notifier.
function M.user_set(view, value)
  if view.kind == "textfield" then
    view.text = value
  else
    view.value = value
  end
  if view.notifier then view.notifier(value) end
end

function M.press(view)
  assert(view.kind == "button", "not a button")
  if view.active == false then error("button is inactive", 2) end
  view.notifier()
end

---------------------------------------------------------------------------
-- app and tool

local function make_tool()
  local tool = {
    menu = {}, keys = {}, timers = {}, bundle_path = "/tmp/jsnp-test/",
    preferences = nil,
    app_new_document_observable = Observable(),
    app_release_document_observable = Observable(),
    app_will_save_document_observable = Observable(),
    app_idle_observable = Observable(),
  }
  function tool:add_menu_entry(e)
    assert(type(e.name) == "string" and type(e.invoke) == "function", "bad menu entry")
    local clean = e.name:gsub("^%-+%s*", "")
    if self.menu[clean] then error("menu entry already exists: " .. clean, 2) end
    self.menu[clean] = e
  end
  function tool:add_keybinding(e)
    if self.keys[e.name] then error("keybinding exists", 2) end
    self.keys[e.name] = e
  end
  function tool:has_timer(fn)
    for _, t in ipairs(self.timers) do if t.fn == fn then return true end end
    return false
  end
  function tool:add_timer(fn, ms)
    if self:has_timer(fn) then error("timer already added", 2) end
    self.timers[#self.timers + 1] = { fn = fn, ms = ms }
  end
  function tool:remove_timer(fn)
    for i, t in ipairs(self.timers) do
      if t.fn == fn then table.remove(self.timers, i) return end
    end
    error("timer not found", 2)
  end
  return tool
end

function M.install()
  M.undo_log = {}
  M.views = {}
  M.messages = {}
  M.dialogs = {}
  local song = Song{ instruments = { new_instrument() } }
  M.song = song
  local tool = make_tool()
  M.tool = tool
  local app = {}
  function app:show_custom_dialog(title, view, key_handler)
    local dlg = { title = title, view = view, key_handler = key_handler, visible = true }
    function dlg:show() end
    function dlg:close() self.visible = false end
    M.dialogs[#M.dialogs + 1] = dlg
    return dlg
  end
  function app:show_prompt(_, _, buttons)
    return M.config.prompt_answer or buttons[1]
  end
  function app:show_message(msg) M.messages[#M.messages + 1] = msg end
  function app:show_status(msg) M.messages[#M.messages + 1] = msg end
  function app:show_warning(msg) M.messages[#M.messages + 1] = msg end
  function app:show_error(msg) M.messages[#M.messages + 1] = msg end

  _G.renoise = {
    API_VERSION = 6.2,
    RENOISE_VERSION = "3.5.4",
    song = function() return M.song end,
    app = function() return app end,
    tool = function() return tool end,
    ViewBuilder = ViewBuilder,
    Document = {
      create = function()
        return function(t)
          local doc = {}
          for k, v in pairs(t) do doc[k] = { value = v } end
          return doc
        end
      end,
    },
    Sample = {
      INTERPOLATE_NONE = 1, INTERPOLATE_LINEAR = 2, INTERPOLATE_CUBIC = 3, INTERPOLATE_SINC = 4,
      LOOP_MODE_OFF = 1, LOOP_MODE_FORWARD = 2, LOOP_MODE_REVERSE = 3, LOOP_MODE_PING_PONG = 4,
      NEW_NOTE_ACTION_NOTE_CUT = 1, NEW_NOTE_ACTION_NOTE_OFF = 2, NEW_NOTE_ACTION_SUSTAIN = 3,
    },
    Instrument = {
      LAYER_NOTE_DISABLED = 0, LAYER_NOTE_ON = 1, LAYER_NOTE_OFF = 2,
      OVERLAP_MODE_ALL = 0, OVERLAP_MODE_CYCLED = 1, OVERLAP_MODE_RANDOM = 2,
      NUMBER_OF_MACROS = 8,
    },
    SampleModulationDevice = {
      TARGET_VOLUME = 1, TARGET_PANNING = 2, TARGET_PITCH = 3,
      TARGET_CUTOFF = 4, TARGET_RESONANCE = 5, TARGET_DRIVE = 6,
      OPERATOR_ADD = 1, OPERATOR_SUB = 2, OPERATOR_MUL = 3, OPERATOR_DIV = 4,
    },
    SampleLfoModulationDevice = { MODE_SIN = 1, MODE_SAW = 2, MODE_PULSE = 3, MODE_RANDOM = 4 },
  }
  return M
end

-- Runs every pending timer once (timers usually remove themselves).
function M.run_timers()
  for _, t in ipairs(copy_list(M.tool.timers)) do
    if M.tool:has_timer(t.fn) then t.fn() end
  end
end

function M.data(obj) return DATA[obj] end

return M
