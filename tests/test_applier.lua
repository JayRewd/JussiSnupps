local M = require "mock_renoise"
M.config.operator_writable = true
M.config.max_samples = 255
M.install()

local Patch = require "jsnp.model.patch"
local C = require "jsnp.compile.compiler"
local W = require "jsnp.dsp.wavegen"
local Caps = require "jsnp.rn.caps"
local A = require "jsnp.rn.applier"
local Devices = require "jsnp.rn.devices"
local Units = require "jsnp.compile.units"

local SMD = renoise.SampleModulationDevice

local function setup(patch)
  M.install()
  Caps.reset()
  Devices.reset_calibration()
  local instr = M.song.instruments[1]
  local caps = Caps.detect(instr)
  local spec = C.compile(patch or Patch.new_default(), caps)
  local built, problems = A.rebuild(instr, spec, caps, W.render)
  return instr, caps, spec, built, problems
end

T.test("caps: finds devices, filters and operators; leaves no trace", function()
  M.install()
  Caps.reset()
  local instr = M.song.instruments[1]
  local caps = Caps.detect(instr)
  T.eq(caps.device_paths.ahdsr, "Modulation/AHDSR")
  T.eq(caps.device_paths.lfo, "Modulation/LFO")
  T.eq(caps.device_paths.operand, "Modulation/Operand")
  T.eq(caps.device_paths.keytracking, "Modulation/Key Tracking")
  T.eq(caps.device_paths.velocity, "Modulation/Velocity Tracking")
  T.eq(caps.operator_writable, true)
  T.eq(caps.filter_writable, true)
  T.eq(#caps.filter_types, 22)
  T.eq(#instr.sample_modulation_sets, 0)
  T.eq(caps.error, nil)
end)

T.test("caps: read-only operators are detected", function()
  M.install()
  Caps.reset()
  M.config.operator_writable = false
  local caps = Caps.detect(M.song.instruments[1])
  M.config.operator_writable = true
  Caps.reset()
  T.eq(caps.operator_writable, false)
  T.ok(#Caps.notes(caps) >= 1)
end)

T.test("rebuild creates the default instrument", function()
  local instr, _, spec, _, problems = setup()
  T.eq(#problems, 0, table.concat(problems, "; "))
  T.eq(#instr.samples, 30)
  T.eq(#instr.sample_modulation_sets, 1)
  local set = instr.sample_modulation_sets[1]
  T.eq(set.filter_type, "LP Moog")
  T.eq(#set.devices, #spec.sets[1].devices)
  local devs = set.devices
  T.eq(devs[1].name, "AHDSR")
  T.eq(devs[1].target, SMD.TARGET_VOLUME)
  T.eq(devs[1].operator, SMD.OPERATOR_MUL)
  T.eq(devs[1].display_name, "Env 2 Amp")
  T.eq(devs[2].target, SMD.TARGET_CUTOFF)
  T.eq(devs[2].operator, SMD.OPERATOR_ADD)
  T.eq(devs[3].name, "Operand")
  T.near(devs[3].value.value, 0.6, 1e-12)
  T.eq(devs[3].operator, SMD.OPERATOR_MUL)
  T.near(devs[4].value.value, 0.45, 1e-12)
  T.near(set.cutoff_input.value, 0, 1e-12)
  T.near(set.resonance_input.value, 0.25, 1e-12)

  -- AHDSR times went through calibration: the mock shows them as strings
  T.near(Units.parse_ms(devs[1].attack.value_string), 2, 0.3)
  T.near(Units.parse_ms(devs[1].decay.value_string), 300, 10)
  T.near(devs[1].sustain.value, 0.8, 1e-12)

  local s = instr.samples[1]
  T.eq(s.loop_mode, renoise.Sample.LOOP_MODE_FORWARD)
  T.eq(s.loop_end, 2048)
  T.eq(s.modulation_set_index, 1)
  T.eq(s.sample_buffer.number_of_frames, 2048)
  T.eq(s.sample_mapping.note_range[1], 0)
  T.eq(s.sample_mapping.note_range[2], 11)
  T.eq(s.new_note_action, renoise.Sample.NEW_NOTE_ACTION_NOTE_OFF)
  T.eq(s.interpolation_mode, renoise.Sample.INTERPOLATE_SINC)
  T.eq(instr.sample_mapping_overlap_mode, renoise.Instrument.OVERLAP_MODE_ALL)
end)

T.test("rebuild twice leaves no leftovers", function()
  local instr, caps, spec = setup()
  A.rebuild(instr, spec, caps, W.render)
  T.eq(#instr.samples, 30)
  T.eq(#instr.sample_modulation_sets, 1)
  T.eq(#instr.sample_modulation_sets[1].devices, #spec.sets[1].devices)
end)

T.test("update writes changed values only", function()
  local p = Patch.new_default()
  local instr, caps, spec, built = setup(p)
  local buf = M.data(instr.samples[15].sample_buffer)
  local writes = buf.writes
  p.filters[1].cutoff = 0.7
  p.envs[2].s = 0.5
  p.oscs[1].oct = 1
  local spec2 = C.compile(p, caps)
  T.eq(C.signature(spec2), C.signature(spec))
  local ok, problems = A.update(instr, spec, spec2, built, caps, W.render)
  T.ok(ok)
  T.eq(#problems, 0)
  local devs = instr.sample_modulation_sets[1].devices
  T.near(devs[4].value.value, 0.7, 1e-12)
  T.near(devs[1].sustain.value, 0.5, 1e-12)
  T.eq(instr.samples[1].transpose, spec2.samples[1].transpose)
  -- osc 2's samples weren't touched
  T.eq(M.data(instr.samples[15].sample_buffer).writes, writes)
end)

T.test("update re-renders samples when the waveform changes", function()
  local p = Patch.new_default()
  local instr, caps, spec, built = setup(p)
  local before = instr.samples[1].sample_buffer:sample_data(1, 100)
  p.oscs[1].wave = "triangle"
  local spec2 = C.compile(p, caps)
  T.ok(A.update(instr, spec, spec2, built, caps, W.render))
  T.ok(instr.samples[1].sample_buffer:sample_data(1, 100) ~= before)
end)

T.test("LFO devices get mode, rate, depth and phase", function()
  local p = Patch.new_default()
  local l = Patch.add(p, "lfo")
  l.shape, l.hz, l.phase = "pulse", 2.5, 45
  Patch.set_mod(p, l.id, "flt1", "res", -0.5)
  local instr = setup(p)
  local lfo
  for _, d in ipairs(instr.sample_modulation_sets[1].devices) do
    if d.name == "LFO" then lfo = d end
  end
  T.ok(lfo, "lfo inserted")
  T.eq(lfo.target, SMD.TARGET_RESONANCE)
  T.eq(lfo.mode, renoise.SampleLfoModulationDevice.MODE_PULSE)
  T.near(Units.parse_hz(lfo.frequency.value_string), 2.5, 0.1)
  T.near(lfo.amplitude.value, 0.5, 1e-12)
  T.near(lfo.dephase.value, 225, 1e-9)
  T.eq(lfo.bipolar, true)
end)

T.test("adopt finds an existing build, and notices changes", function()
  local instr, _, spec = setup()
  local built = A.adopt(instr, spec)
  T.ok(built, "adopted")
  T.eq(#built.samples, 30)
  instr:delete_sample_at(30)
  T.eq(A.adopt(instr, spec), nil)
end)

T.test("update refuses when the instrument changed underneath", function()
  local p = Patch.new_default()
  local instr, caps, spec, built = setup(p)
  instr:delete_sample_at(1)
  local ok = A.update(instr, spec, C.compile(p, caps), built, caps, W.render)
  T.eq(ok, false)
end)
