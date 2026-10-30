-- Makes an instrument spec (see jsnp.compile.compiler) real in Renoise.
--
--   rebuild: deletes the instrument's samples and modulation sets and
--            creates them from the spec
--   update:  same structure as last time, so only changed values are
--            written (fast, keeps the devices)
--   adopt:   finds the Renoise objects of an instrument that was built
--            earlier (after reopening a song), without changing anything
--
-- `built` holds references to the created objects:
--   { sets = { {set = ModSet, devices = {Device,...}}, ... }, samples = {Sample,...} }

local Devices = require "jsnp.rn.devices"

local Applier = {}

local TARGETS = {
  volume = "TARGET_VOLUME", panning = "TARGET_PANNING", pitch = "TARGET_PITCH",
  cutoff = "TARGET_CUTOFF", resonance = "TARGET_RESONANCE", drive = "TARGET_DRIVE",
}
local OPS = { add = "OPERATOR_ADD", sub = "OPERATOR_SUB", mul = "OPERATOR_MUL", div = "OPERATOR_DIV" }
local INPUTS = {
  volume = "volume_input", panning = "panning_input", pitch = "pitch_input",
  cutoff = "cutoff_input", resonance = "resonance_input", drive = "drive_input",
}
local INTERP = {
  none = "INTERPOLATE_NONE", linear = "INTERPOLATE_LINEAR",
  cubic = "INTERPOLATE_CUBIC", sinc = "INTERPOLATE_SINC",
}
local DOMAINS = { "volume", "panning", "pitch", "cutoff", "resonance", "drive" }

local SAMPLE_RATE = 44100

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function target_const(name)
  return renoise.SampleModulationDevice[TARGETS[name]]
end

local function same(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return a == b end
  for k, v in pairs(a) do
    if not same(v, b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

---------------------------------------------------------------------------
-- modulation sets

local function apply_filter(set, ftype, report)
  pcall(function()
    if set.filter_version < 3 then set:upgrade_filter_version() end
  end)
  local ok = pcall(function() set.filter_type = ftype end)
  if not ok then
    report("Couldn't set filter type '" .. tostring(ftype) .. "'")
  end
end

local function apply_input(set, domain, spec)
  local p = set[INPUTS[domain]]
  if spec == nil then
    p.value = p.value_default
  elseif spec.norm then
    p.value = p.value_min + clamp(spec.norm, 0, 1) * (p.value_max - p.value_min)
  elseif spec.gain then
    p.value = clamp(spec.gain * p.value_default, p.value_min, p.value_max)
  end
end

local function apply_device_header(dev, dspec, report)
  pcall(function() dev.display_name = dspec.label end)
  if dspec.op then
    local want = renoise.SampleModulationDevice[OPS[dspec.op]]
    local ok = pcall(function() dev.operator = want end)
    if not ok or dev.operator ~= want then
      report("Couldn't set a device operator (" .. dspec.op .. ")")
    end
  end
  pcall(function() dev.bipolar = dspec.bipolar and true or false end)
end

local function insert_device(set, dspec, caps, report)
  local path = caps.device_paths[dspec.kind]
  if not path then
    error("Renoise has no '" .. dspec.kind .. "' modulation device")
  end
  local index = #set.devices + 1
  local dev = set:insert_device_at(path, target_const(dspec.target), index)
  if dev == nil then
    dev = set.devices[index]
  end
  -- times in ms, not beats
  pcall(function() dev.tempo_synced = false end)
  apply_device_header(dev, dspec, report)
  for _, miss in ipairs(Devices.apply_params(dev, dspec.kind, dspec.params, nil)) do
    report("Parameter not found: " .. miss)
  end
  return dev
end

local function fill_set(set, sspec, caps, report)
  set.name = sspec.name
  apply_filter(set, sspec.filter_type, report)
  for _, d in ipairs(DOMAINS) do
    if sspec.inputs[d] ~= nil then
      apply_input(set, d, sspec.inputs[d])
    end
  end
  if sspec.pitch_range then
    set.pitch_range = sspec.pitch_range
  end
  local devs = {}
  for k, dspec in ipairs(sspec.devices) do
    devs[k] = insert_device(set, dspec, caps, report)
  end
  return devs
end

---------------------------------------------------------------------------
-- samples

local function write_buffer(sample, data)
  local buf = sample.sample_buffer
  local n = #data
  if not (buf.has_sample_data and buf.number_of_frames == n
          and buf.number_of_channels == 1) then
    if not buf:create_sample_data(SAMPLE_RATE, 32, 1, n) then
      error("Renoise couldn't create sample data")
    end
  end
  buf:prepare_sample_data_changes()
  for i = 1, n do
    buf:set_sample_data(1, i, data[i])
  end
  buf:finalize_sample_data_changes()
end

local function apply_sample(sample, s, g, old, old_g)
  local function ch(key)
    return old == nil or old[key] ~= s[key]
  end
  local function gch(key)
    return old_g == nil or old_g[key] ~= g[key]
  end
  if ch("name") then sample.name = s.name end
  if ch("volume") then sample.volume = clamp(s.volume, 0, 4) end
  if ch("panning") then sample.panning = clamp(s.panning, 0, 1) end
  if ch("transpose") then sample.transpose = s.transpose end
  if ch("fine_tune") then sample.fine_tune = s.fine_tune end
  if ch("set") then sample.modulation_set_index = s.set end
  if gch("interp") then
    sample.interpolation_mode = renoise.Sample[INTERP[g.interp] or "INTERPOLATE_SINC"]
  end
  if gch("oversample") then sample.oversample_enabled = g.oversample and true or false end
  if old == nil then
    sample.new_note_action = renoise.Sample.NEW_NOTE_ACTION_NOTE_OFF
    sample.autofade = true
  end
  if old == nil or ch("render_key") then
    sample.loop_mode = renoise.Sample.LOOP_MODE_FORWARD
    sample.loop_start = 1
    sample.loop_end = s.frames
  end
  local m = sample.sample_mapping
  if ch("base_note") then m.base_note = s.base_note end
  if ch("lo") or ch("hi") then m.note_range = { s.lo, s.hi } end
  if old == nil then m.velocity_range = { 0, 127 } end
  if ch("key_to_pitch") then m.map_key_to_pitch = s.key_to_pitch end
  if gch("vel_to_vol") then m.map_velocity_to_volume = g.vel_to_vol and true or false end
end

local function apply_instrument(instr, g, old_g)
  local function gch(key)
    return old_g == nil or old_g[key] ~= g[key]
  end
  if old_g == nil then
    pcall(function()
      instr.sample_mapping_overlap_mode = renoise.Instrument.OVERLAP_MODE_ALL
    end)
  end
  if gch("mono") then
    pcall(function() instr.trigger_options.monophonic = g.mono and true or false end)
  end
  if gch("glide") then
    pcall(function() instr.trigger_options.monophonic_glide = math.floor(g.glide) end)
  end
end

---------------------------------------------------------------------------

function Applier.clear(instr)
  for i = #instr.samples, 1, -1 do
    instr:delete_sample_at(i)
  end
  for i = #instr.sample_modulation_sets, 1, -1 do
    instr:delete_sample_modulation_set_at(i)
  end
end

-- Full rebuild. `render(sample_spec)` returns the sample frames.
-- Returns built, problems (list of strings).
function Applier.rebuild(instr, spec, caps, render)
  local problems, seen = {}, {}
  local function report(msg)
    if not seen[msg] then
      seen[msg] = true
      problems[#problems + 1] = msg
    end
  end

  Applier.clear(instr)
  local built = { sets = {}, samples = {} }
  for j, sspec in ipairs(spec.sets) do
    local set = instr:insert_sample_modulation_set_at(j)
    for d = #set.devices, 1, -1 do
      set:delete_device_at(d)
    end
    built.sets[j] = { set = set, devices = fill_set(set, sspec, caps, report) }
  end
  for i, s in ipairs(spec.samples) do
    local sample = instr:insert_sample_at(i)
    write_buffer(sample, render(s))
    apply_sample(sample, s, spec.global, nil, nil)
    built.samples[i] = sample
  end
  apply_instrument(instr, spec.global, nil)
  return built, problems
end

-- In-place update between two specs with equal signatures. Returns true,
-- problems; or false when the instrument no longer matches `built`.
function Applier.update(instr, old, new, built, caps, render)
  local problems, seen = {}, {}
  local function report(msg)
    if not seen[msg] then
      seen[msg] = true
      problems[#problems + 1] = msg
    end
  end
  if #instr.samples ~= #new.samples
      or #instr.sample_modulation_sets ~= #new.sets then
    return false, problems
  end

  for j, ns in ipairs(new.sets) do
    local os, b = old.sets[j], built.sets[j]
    local set = b.set
    if ns.name ~= os.name then set.name = ns.name end
    if ns.filter_type ~= os.filter_type then apply_filter(set, ns.filter_type, report) end
    for _, d in ipairs(DOMAINS) do
      if not same(ns.inputs[d], os.inputs[d]) then
        apply_input(set, d, ns.inputs[d])
      end
    end
    if ns.pitch_range ~= os.pitch_range and ns.pitch_range then
      set.pitch_range = ns.pitch_range
    end
    for k, nd in ipairs(ns.devices) do
      local od, dev = os.devices[k], b.devices[k]
      if nd.label ~= od.label then
        pcall(function() dev.display_name = nd.label end)
      end
      for _, miss in ipairs(Devices.apply_params(dev, nd.kind, nd.params, od.params)) do
        report("Parameter not found: " .. miss)
      end
    end
  end

  for i, s in ipairs(new.samples) do
    local o, sample = old.samples[i], built.samples[i]
    if s.render_key ~= o.render_key then
      write_buffer(sample, render(s))
    end
    apply_sample(sample, s, new.global, o, old.global)
  end
  apply_instrument(instr, new.global, old.global)
  return true, problems
end

-- References to an existing instrument's objects if it matches `spec`'s
-- structure, else nil (then the next change rebuilds it).
function Applier.adopt(instr, spec)
  local ok, built = pcall(function()
    if #instr.samples ~= #spec.samples
        or #instr.sample_modulation_sets ~= #spec.sets then
      return nil
    end
    local out = { sets = {}, samples = {} }
    for j, sspec in ipairs(spec.sets) do
      local set = instr.sample_modulation_sets[j]
      local devs = set.devices
      if #devs ~= #sspec.devices then return nil end
      for k, d in ipairs(sspec.devices) do
        local dev = devs[k]
        if not tostring(dev.name):lower():find(d.kind, 1, true)
            or dev.target ~= target_const(d.target) then
          return nil
        end
      end
      out.sets[j] = { set = set, devices = devs }
    end
    for i, s in ipairs(spec.samples) do
      local sample = instr.samples[i]
      if sample.modulation_set_index ~= s.set
          or sample.sample_buffer.number_of_frames ~= s.frames then
        return nil
      end
      out.samples[i] = sample
    end
    return out
  end)
  if ok then return built end
  return nil
end

return Applier
