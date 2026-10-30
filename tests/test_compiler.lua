local Patch = require "jsnp.model.patch"
local C = require "jsnp.compile.compiler"

local function devices_for(set, target)
  local out = {}
  for _, d in ipairs(set.devices) do
    if d.target == target then out[#out + 1] = d end
  end
  return out
end

-- Evaluates one domain chain the way the recipes assume Renoise does:
-- start at the input, apply each device's output with its operator.
-- `values[label]` gives envelope outputs; LFOs output 0.
local function eval_chain(set, target, input, values)
  local v = input
  for _, d in ipairs(devices_for(set, target)) do
    local out
    if d.kind == "operand" then
      out = d.params.value
    elseif d.kind == "ahdsr" then
      out = values[d.label] or 0
    else
      out = 0
    end
    local op = d.op or "add"
    if op == "add" then v = v + out
    elseif op == "sub" then v = v - out
    elseif op == "mul" then v = v * out
    elseif op == "div" then v = v / out end
  end
  return v
end

T.test("default patch: 3 paths share one modulation set", function()
  local spec = C.compile(Patch.new_default())
  T.eq(spec.stats.paths, 3)
  T.eq(spec.stats.sets, 1)
  T.eq(spec.stats.samples, 30)
  T.eq(#spec.warnings, 0, table.concat(spec.warnings, "; "))
  local set = spec.sets[1]
  T.eq(set.filter_type, "LP Moog")
  local vol = devices_for(set, "volume")
  T.eq(#vol, 1)
  T.eq(vol[1].kind, "ahdsr")
  T.eq(vol[1].op, "mul")
  T.eq(vol[1].label, "Env 2 Amp")
  T.eq(vol[1].params.attack, 2)
  -- cutoff = 0.45 + 0.6 * env1
  for _, e in ipairs({ 0, 0.3, 1 }) do
    T.near(eval_chain(set, "cutoff", set.inputs.cutoff.norm, { ["Env 1 Filter"] = e }),
      0.45 + 0.6 * e, 1e-12)
  end
  T.near(set.inputs.resonance.norm, 0.25, 1e-12)
  for _, s in ipairs(spec.samples) do T.eq(s.set, 1) end
end)

T.test("oscillator tuning lands in the samples", function()
  local spec = C.compile(Patch.new_default())
  local s1, s2, s3 = spec.samples[1], spec.samples[11], spec.samples[21]
  T.eq(s1.render_key:match("^(%a+)"), "saw")
  T.eq(s3.render_key:match("^(%a+)"), "square")
  T.ok(s1.fine_tune ~= s2.fine_tune or s1.transpose ~= s2.transpose, "osc2 is detuned")
  T.ok(s3.harmonics > s1.harmonics, "an octave down allows more harmonics")
end)

T.test("one osc into two filters makes two paths", function()
  local p = Patch.new_default()
  local f2 = Patch.add(p, "flt")
  f2.type = "HP Clean"
  Patch.set_send(p, "osc1", f2.id, 0.5)
  local spec = C.compile(p)
  T.eq(spec.stats.paths, 4)
  T.eq(spec.stats.sets, 2)
  local hp = spec.sets[2]
  T.eq(hp.filter_type, "HP Clean")
  local in_hp = 0
  for _, smp in ipairs(spec.samples) do
    if smp.set == 2 then
      in_hp = in_hp + 1
      T.near(smp.volume, 0.6 * 0.5, 1e-12)
    end
  end
  T.eq(in_hp, 10)
end)

T.test("Direct uses filter None; unrouted oscs warn", function()
  local p = Patch.new_default()
  Patch.set_send(p, "osc1", "flt1", 0)
  Patch.set_send(p, "osc1", "direct", 1)
  Patch.set_send(p, "osc2", "flt1", 0)
  local spec = C.compile(p)
  T.eq(spec.stats.paths, 2)
  local direct
  for _, set in ipairs(spec.sets) do
    if set.filter_type == "None" then direct = set end
  end
  T.ok(direct, "direct set")
  T.eq(#devices_for(direct, "cutoff"), 0)
  T.ok(spec.warnings[1]:find("Osc 2"), spec.warnings[1])
end)

T.test("no volume envelope adds a gate", function()
  local p = Patch.new_default()
  for _, o in ipairs(p.oscs) do Patch.set_mod(p, "env2", o.id, "volume", 0) end
  local set = C.compile(p).sets[1]
  local vol = devices_for(set, "volume")
  T.eq(#vol, 1)
  T.eq(vol[1].label, "Gate")
  T.eq(vol[1].params.sustain, 1)
end)

T.test("partial volume envelope keeps a floor and still gates", function()
  local p = Patch.new_default()
  for _, o in ipairs(p.oscs) do Patch.set_mod(p, "env2", o.id, "volume", 0.4) end
  local set = C.compile(p).sets[1]
  local vol = devices_for(set, "volume")
  T.eq(vol[#vol].label, "Gate")
  -- before the gate: 0.6 + 0.4 * env
  local input = set.inputs.volume.gain
  local v = input
  for i = 1, #vol - 1 do
    local d = vol[i]
    local out = d.kind == "operand" and d.params.value or 0.5
    if d.op == "add" then v = v + out elseif d.op == "mul" then v = v * out
    elseif d.op == "sub" then v = v - out end
  end
  T.near(v, 0.6 + 0.4 * 0.5, 1e-12)
  T.eq(vol[#vol].params.release, 200)
end)

T.test("negative envelope amount on cutoff", function()
  local p = Patch.new_default()
  Patch.set_mod(p, "env1", "flt1", "cutoff", -0.3)
  local set = C.compile(p).sets[1]
  for _, e in ipairs({ 0, 0.5, 1 }) do
    T.near(eval_chain(set, "cutoff", set.inputs.cutoff.norm, { ["Env 1 Filter"] = e }),
      0.45 - 0.3 * e, 1e-12)
  end
end)

T.test("several envelopes on one destination add up", function()
  local p = Patch.new_default()
  local e3 = Patch.add(p, "env")
  Patch.set_mod(p, e3.id, "flt1", "cutoff", -0.25)
  Patch.set_mod(p, "env2", "flt1", "cutoff", 0.4)
  local set = C.compile(p).sets[1]
  for _, vals in ipairs({ { 0, 0, 0 }, { 1, 0.5, 0.2 }, { 0.3, 1, 1 } }) do
    local got = eval_chain(set, "cutoff", set.inputs.cutoff.norm, {
      ["Env 1 Filter"] = vals[1], ["Env 2 Amp"] = vals[2], [e3.name] = vals[3],
    })
    T.near(got, 0.45 + 0.6 * vals[1] + 0.4 * vals[2] - 0.25 * vals[3], 1e-12)
  end
end)

T.test("pitch: envelope sets the range, LFO depth is relative", function()
  local p = Patch.new_default()
  local l = Patch.add(p, "lfo")
  Patch.set_mod(p, "env1", "osc1", "pitch", 12)
  Patch.set_mod(p, l.id, "osc1", "pitch", 3)
  local spec = C.compile(p)
  T.eq(spec.stats.sets, 2)
  local set = spec.sets[1]
  T.eq(set.pitch_range, 12)
  local pitch = devices_for(set, "pitch")
  T.eq(#pitch, 2)
  T.eq(pitch[2].kind, "lfo")
  T.near(pitch[2].params.amplitude, 0.25, 1e-12)
  -- upward pitch modulation reduces harmonics of osc1's zones
  local plain = C.compile(Patch.new_default())
  T.ok(spec.samples[3].harmonics < plain.samples[3].harmonics)
end)

T.test("negative LFO amounts flip the phase", function()
  local p = Patch.new_default()
  local l = Patch.add(p, "lfo")
  l.phase = 90
  Patch.set_mod(p, l.id, "flt1", "cutoff", -0.2)
  local set = C.compile(p).sets[1]
  local lfo = devices_for(set, "cutoff")
  lfo = lfo[#lfo]
  T.eq(lfo.kind, "lfo")
  T.eq(lfo.params.phase, 270)
  T.near(lfo.params.amplitude, 0.2, 1e-12)
  T.eq(lfo.bipolar, true)
end)

T.test("without writable operators amounts fall back to 100% with a warning", function()
  local caps = { operator_writable = false, fine_per_semi = 128, max_samples = 255 }
  local spec = C.compile(Patch.new_default(), caps)
  for _, d in ipairs(spec.sets[1].devices) do
    T.eq(d.op, nil)
    T.ok(d.kind ~= "operand", "no operands without operators")
  end
  T.ok(#spec.warnings >= 1)
end)

T.test("too many samples switches to bigger zones", function()
  local p = Patch.new_default()
  for _ = 1, 8 do
    local o = Patch.add(p, "osc")
    Patch.autoroute_osc(p, o)
  end
  local spec = C.compile(p, { operator_writable = true, fine_per_semi = 128, max_samples = 60 })
  T.ok(spec.stats.samples <= 60, "samples " .. spec.stats.samples)
  T.ok(spec.warnings[1]:find("octave zones"), spec.warnings[1])
end)

T.test("noise oscillator is one unpitched sample", function()
  local p = Patch.new_default()
  p.oscs[1].wave = "noise"
  local spec = C.compile(p)
  T.eq(spec.stats.samples, 21)
  T.eq(spec.samples[1].key_to_pitch, false)
  T.eq(spec.samples[1].lo, 0)
  T.eq(spec.samples[1].hi, 119)
end)

T.test("signature: value edits keep it, routing edits change it", function()
  local p = Patch.new_default()
  local sig = C.signature(C.compile(p))
  p.filters[1].cutoff = 0.9
  p.oscs[1].oct = 2
  p.oscs[1].wave = "pulse"
  p.envs[1].a = 100
  T.eq(C.signature(C.compile(p)), sig)
  Patch.set_mod(p, "env1", "osc1", "pan", 0.5)
  T.ok(C.signature(C.compile(p)) ~= sig)
end)
