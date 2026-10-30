-- Turns a patch into an "instrument spec": a plain description of the
-- Renoise samples, modulation sets and modulation devices to create. The
-- applier (jsnp.rn.applier) then makes it real. Pure Lua, testable offline.
--
-- Mapping:
--   * every audio route (osc -> filter or Direct) is a "path": the
--     oscillator's zone samples plus a modulation set holding that filter
--     and all modulation for the path. Identical sets are shared.
--   * envelopes become native AHDSR devices, LFOs become LFO devices.
--     Amounts are realised with Operand devices and operators, because
--     Renoise devices have no per-device depth (see the domain recipes).
--
-- All values for inputs and Operands are normalised 0..1 over the Renoise
-- parameter's range. Times are ms, rates Hz, phases degrees.

local json = require "jsnp.util.json"
local Patch = require "jsnp.model.patch"
local Zones = require "jsnp.dsp.zones"
local Wavegen = require "jsnp.dsp.wavegen"

local Compiler = {}

Compiler.DEFAULT_CAPS = {
  operator_writable = true,
  fine_per_semi = 128,
  max_samples = 255,
  filter_types = Patch.FILTER_TYPES,
}

Compiler.DOMAINS = { "volume", "panning", "pitch", "cutoff", "resonance", "drive" }

local TARGET_OF = {
  volume = "volume", pan = "panning", pitch = "pitch",
  cutoff = "cutoff", res = "resonance", drive = "drive",
}

local FULL = 0.999

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function pct(a)
  return string.format("%d%%", math.floor(a * 100 + 0.5))
end

---------------------------------------------------------------------------
-- device specs

local function device(kind, target, op, bipolar, label, params)
  return { kind = kind, target = target, op = op, bipolar = bipolar,
           label = label, params = params }
end

local function env_device(target, env, op, label)
  return device("ahdsr", target, op, false, label or env.name,
    { attack = env.a, hold = env.h, decay = env.d, sustain = env.s, release = env.r })
end

local function operand(target, value, op, label)
  return device("operand", target, op, false, label, { value = clamp(value, 0, 1) })
end

-- LFO with depth `a` (-1..1, already in normalised domain units).
local function lfo_device(target, lfo, a, opw, warn, where)
  local amp = math.min(1, math.abs(a))
  local phase, op = lfo.phase, (opw and "add" or nil)
  if a < 0 then
    if lfo.shape == "sine" or lfo.shape == "pulse" then
      phase = (phase + 180) % 360
    elseif lfo.shape == "saw" then
      if opw then
        op = "sub"
      else
        warn(where .. ": negative amounts on a saw LFO aren't supported here; using positive")
      end
    end
  end
  return device("lfo", target, op, true, lfo.name, {
    shape = lfo.shape, hz = lfo.hz, phase = phase, delay = lfo.delay_ms, amplitude = amp,
  })
end

---------------------------------------------------------------------------
-- domain recipes. `envs`/`lfos` are lists of { src = module, a = amount }.

-- Cutoff, resonance, drive and panning: value = base + sum(a * source).
-- One envelope:      input 0 -> +env -> *depth(Operand) -> +base(Operand)
-- Several envelopes: Horner scheme, smallest |amount| first:
--   ((±e1 * a1/a2 ± e2) * a2/a3 ± e3) * a3 + base
-- LFOs are added at the end with their amplitude as depth.
local function additive_domain(target, base, envs, lfos, opw, warn, where)
  local devices = {}
  local input = base

  if #envs > 0 and not opw then
    for _, m in ipairs(envs) do
      if math.abs(m.a - 1) > 0.001 then
        warn(string.format("%s: %s at %s needs device operators, which this "
          .. "Renoise doesn't allow; using +100%%", where, m.src.name, pct(m.a)))
      end
      devices[#devices + 1] = env_device(target, m.src, nil)
    end
  elseif #envs == 1 then
    local m = envs[1]
    local a = m.a
    if a >= FULL then
      devices[#devices + 1] = env_device(target, m.src, "add")
    elseif a > 0 then
      input = 0
      devices[#devices + 1] = env_device(target, m.src, "add")
      devices[#devices + 1] = operand(target, a, "mul", "Depth " .. pct(a))
      devices[#devices + 1] = operand(target, base, "add", "Base")
    else
      -- base - |a|*env = (base - |a|) + |a| * (1 - env)
      local d = -a
      input = 1
      devices[#devices + 1] = env_device(target, m.src, "sub")
      devices[#devices + 1] = operand(target, d, "mul", "Depth -" .. pct(d))
      local offset = base - d
      if offset >= 0 then
        devices[#devices + 1] = operand(target, offset, "add", "Base")
      else
        devices[#devices + 1] = operand(target, -offset, "sub", "Base")
      end
    end
  elseif #envs > 1 then
    local sorted = {}
    for i, m in ipairs(envs) do sorted[i] = { src = m.src, a = m.a, order = i } end
    table.sort(sorted, function(x, y)
      if math.abs(x.a) ~= math.abs(y.a) then return math.abs(x.a) < math.abs(y.a) end
      return x.order < y.order
    end)
    input = 0
    for k, m in ipairs(sorted) do
      devices[#devices + 1] = env_device(target, m.src, m.a >= 0 and "add" or "sub")
      local scale
      if k < #sorted then
        scale = math.abs(m.a) / math.abs(sorted[k + 1].a)
      else
        scale = math.abs(m.a)
      end
      if scale < FULL then
        devices[#devices + 1] = operand(target, scale, "mul", "Scale")
      end
    end
    if base > 0 then
      devices[#devices + 1] = operand(target, base, "add", "Base")
    end
  end

  for _, m in ipairs(lfos) do
    devices[#devices + 1] = lfo_device(target, m.src, m.a, opw, warn, where)
  end
  return input, devices
end

-- Pitch: Renoise scales the whole pitch chain by the set's pitch_range
-- (semitones). Envelopes run at full range; LFO depth uses amplitude.
local function pitch_domain(envs, lfos, opw, warn, where)
  local devices = {}
  if #envs == 0 and #lfos == 0 then
    return nil, devices, nil, 0
  end
  local range = 0
  if #envs > 0 then
    for _, m in ipairs(envs) do range = math.max(range, math.abs(m.a)) end
  else
    for _, m in ipairs(lfos) do range = math.max(range, math.abs(m.a)) end
  end
  range = clamp(math.ceil(range - 1e-9), 1, 96)

  local up = 0
  for _, m in ipairs(envs) do
    if math.abs(math.abs(m.a) - range) > 1e-6 then
      warn(string.format("%s: %s uses %+d st, because all pitch envelopes on one "
        .. "oscillator share one range", where, m.src.name, m.a >= 0 and range or -range))
    end
    local op = opw and (m.a >= 0 and "add" or "sub") or nil
    if m.a < 0 and not opw then
      warn(where .. ": negative pitch envelope amounts aren't supported here; using positive")
    end
    devices[#devices + 1] = env_device("pitch", m.src, op)
    if m.a > 0 or not opw then up = up + range end
  end
  for _, m in ipairs(lfos) do
    local a = m.a / range
    if math.abs(a) > 1 then
      warn(string.format("%s: %s limited to %d st (envelope range)", where, m.src.name, range))
    end
    devices[#devices + 1] = lfo_device("pitch", m.src, a, opw, warn, where)
    up = up + math.min(1, math.abs(a)) * range
  end
  return nil, devices, range, up
end

-- Volume is multiplicative: value = gain * env * env ...
-- One partial-depth envelope is exact: (1 - a) + a * env. LFOs add a
-- tremolo before the full-depth envelopes multiply. A "Gate" AHDSR is
-- added when no full-depth envelope would end the note on note-off.
local function volume_domain(envs, lfos, opw, warn, where, gate_ms)
  local devices = {}
  local input = nil
  local full, partial = {}, {}
  for _, m in ipairs(envs) do
    local a = m.a
    if a < 0 then
      warn(where .. ": negative volume amounts are used as positive")
      a = -a
    end
    if a >= FULL then
      full[#full + 1] = m
    elseif not opw then
      warn(string.format("%s: %s at %s needs device operators, which this "
        .. "Renoise doesn't allow; using 100%%", where, m.src.name, pct(a)))
      full[#full + 1] = m
    elseif #partial == 0 then
      partial[1] = { src = m.src, a = a }
    else
      warn(string.format("%s: only one volume envelope per oscillator can be "
        .. "below 100%%; %s uses 100%%", where, m.src.name))
      full[#full + 1] = m
    end
  end

  local depth = 0
  for _, m in ipairs(lfos) do depth = depth + math.min(1, math.abs(m.a)) end
  depth = math.min(1, depth)

  local release = 0
  if partial[1] then
    local m = partial[1]
    input = { gain = 0 }
    devices[#devices + 1] = env_device("volume", m.src, "add")
    devices[#devices + 1] = operand("volume", m.a, "mul", "Depth " .. pct(m.a))
    devices[#devices + 1] = operand("volume", 1 - m.a, "add", "Floor")
    release = m.src.r
    if depth > 0 then
      for _, l in ipairs(lfos) do
        devices[#devices + 1] = lfo_device("volume", l.src, l.a / 2, opw, warn, where)
      end
      devices[#devices + 1] = operand("volume", depth / 2, "sub", "Tremolo")
    end
  elseif depth > 0 then
    if opw then
      input = { gain = 1 - depth / 2 }
      for _, l in ipairs(lfos) do
        devices[#devices + 1] = lfo_device("volume", l.src, l.a / 2, opw, warn, where)
      end
    else
      for _, l in ipairs(lfos) do
        devices[#devices + 1] = lfo_device("volume", l.src, l.a, opw, warn, where)
      end
    end
  end

  for _, m in ipairs(full) do
    devices[#devices + 1] = env_device("volume", m.src, opw and "mul" or nil)
  end

  if #full == 0 then
    devices[#devices + 1] = device("ahdsr", "volume", opw and "mul" or nil, false, "Gate", {
      attack = 1, hold = 0, decay = 0, sustain = 1,
      release = math.max(gate_ms or 8, release),
    })
  end
  return input, devices
end

---------------------------------------------------------------------------
-- one modulation set per path

local function order_index(p)
  local idx = {}
  for i, e in ipairs(p.envs) do idx[e.id] = i end
  for i, l in ipairs(p.lfos) do idx[l.id] = 1000 + i end
  return idx
end

local function build_set(p, path, opw, warn, order)
  local osc, flt = path.osc, path.flt
  local doms = {}
  for _, d in ipairs(Compiler.DOMAINS) do doms[d] = { envs = {}, lfos = {} } end

  for _, r in ipairs(p.mods) do
    local on_osc = r.dst == osc.id
    local on_flt = flt and r.dst == flt.id
    if on_osc or on_flt then
      local src, kind = Patch.find(p, r.src)
      local dom = doms[TARGET_OF[r.param]]
      if src and dom then
        local list = (kind == "env") and dom.envs or dom.lfos
        list[#list + 1] = { src = src, a = r.amount }
      end
    end
  end
  for _, d in ipairs(Compiler.DOMAINS) do
    local function by_order(x, y) return order[x.src.id] < order[y.src.id] end
    table.sort(doms[d].envs, by_order)
    table.sort(doms[d].lfos, by_order)
  end

  local where_osc = osc.name
  local where_flt = flt and flt.name or "Direct"
  local set = {
    filter_type = flt and flt.type or "None",
    inputs = {},
    devices = {},
  }
  local function append(devs)
    for _, dv in ipairs(devs) do set.devices[#set.devices + 1] = dv end
  end

  -- volume
  local vin, vdevs = volume_domain(doms.volume.envs, doms.volume.lfos, opw, warn,
    where_osc .. " volume", p.global.gate_release_ms)
  set.inputs.volume = vin
  append(vdevs)

  -- panning: centre 0.5, +-100% = full swing, i.e. half the range
  local pd = doms.panning
  if #pd.envs + #pd.lfos > 0 then
    local function half(list)
      local out = {}
      for i, m in ipairs(list) do out[i] = { src = m.src, a = m.a * 0.5 } end
      return out
    end
    local pin, pdevs = additive_domain("panning", 0.5, half(pd.envs), half(pd.lfos),
      opw, warn, where_osc .. " pan")
    if #pd.envs > 0 then set.inputs.panning = { norm = pin } end
    append(pdevs)
  end

  -- pitch
  local _, idevs, range, up = pitch_domain(doms.pitch.envs, doms.pitch.lfos, opw, warn,
    where_osc .. " pitch")
  set.pitch_range = range
  append(idevs)

  -- filter
  if flt then
    for _, pair in ipairs({ { "cutoff", "cutoff" }, { "resonance", "res" }, { "drive", "drive" } }) do
      local target, field = pair[1], pair[2]
      local d = doms[target]
      local input, devs = additive_domain(target, flt[field], d.envs, d.lfos, opw, warn,
        where_flt .. " " .. Patch.PARAM_LABELS[field]:lower())
      set.inputs[target] = { norm = input }
      append(devs)
    end
  end

  return set, up
end

---------------------------------------------------------------------------

local function collect_paths(p, warn)
  local paths = {}
  for _, o in ipairs(p.oscs) do
    local n = 0
    for _, f in ipairs(p.filters) do
      local s = Patch.get_send(p, o.id, f.id)
      if s > 0 then
        paths[#paths + 1] = { osc = o, flt = f, send = s }
        n = n + 1
      end
    end
    local s = Patch.get_send(p, o.id, "direct")
    if s > 0 then
      paths[#paths + 1] = { osc = o, flt = nil, send = s }
      n = n + 1
    end
    if n == 0 then
      warn(o.name .. " isn't routed anywhere: give it a send in the Audio matrix")
    end
  end
  return paths
end

local function short(s, n)
  if #s <= n then return s end
  return s:sub(1, n - 2) .. ".."
end

local function compile_with(p, caps, zone_octaves)
  local warnings, seen = {}, {}
  local function warn(msg)
    if not seen[msg] then
      seen[msg] = true
      warnings[#warnings + 1] = msg
    end
  end
  local opw = caps.operator_writable ~= false
  local fps = caps.fine_per_semi or Zones.FINE_PER_SEMI
  local order = order_index(p)
  local frames = Wavegen.FRAMES
  local n0 = Zones.natural_note(frames, Wavegen.SAMPLE_RATE)

  local paths = collect_paths(p, warn)
  local sets, set_users, by_key = {}, {}, {}
  local samples = {}

  for _, path in ipairs(paths) do
    local set, headroom = build_set(p, path, opw, warn, order)
    local key = json.encode(set)
    local si = by_key[key]
    if not si then
      sets[#sets + 1] = set
      si = #sets
      by_key[key] = si
      set_users[si] = {}
    end
    local users = set_users[si]
    users[#users + 1] = path

    local o = path.osc
    local volume = o.level * path.send
    local panning = clamp((o.pan + 1) / 2, 0, 1)
    local route = o.name .. ">" .. (path.flt and path.flt.name or "Direct")
    if o.wave == "noise" then
      samples[#samples + 1] = {
        name = short(route, 40) .. " noise", set = si, wave = "noise", pw = 0.5,
        harmonics = 0, frames = Wavegen.NOISE_FRAMES, render_key = "noise",
        lo = 0, hi = 119, base_note = 48, transpose = 0, fine_tune = 0,
        key_to_pitch = false, volume = volume, panning = panning,
      }
    else
      local shift = 12 * o.oct + o.semi + o.cents / 100
      local base, transpose, fine = Zones.tuning(n0, shift, fps)
      local pw = (o.wave == "pulse") and o.pw or 0.5
      for zi, z in ipairs(Zones.plan(shift, headroom, zone_octaves, frames)) do
        local h = (o.wave == "sine") and 1 or z.harmonics
        samples[#samples + 1] = {
          name = string.format("%s z%d", short(route, 40), zi),
          set = si, wave = o.wave, pw = pw, harmonics = h, frames = frames,
          render_key = string.format("%s|%.3f|%d|%d", o.wave, pw, h, frames),
          lo = z.lo, hi = z.hi, base_note = base, transpose = transpose,
          fine_tune = fine, key_to_pitch = true, volume = volume, panning = panning,
        }
      end
    end
  end

  for si, set in ipairs(sets) do
    local users = set_users[si]
    local names = {}
    for i, path in ipairs(users) do names[i] = path.osc.name end
    local fname = users[1].flt and users[1].flt.name or "Direct"
    set.name = short(fname .. ": " .. table.concat(names, "+"), 60)
  end

  local g = p.global
  return {
    sets = sets,
    samples = samples,
    warnings = warnings,
    global = {
      interp = g.interp, oversample = g.oversample, mono = g.mono,
      glide = g.glide, vel_to_vol = g.vel_to_vol,
    },
    stats = { paths = #paths, sets = #sets, samples = #samples },
  }
end

-- Compiles a validated patch. `caps` describes what this Renoise allows
-- (see jsnp.rn.caps); defaults assume everything works.
function Compiler.compile(p, caps)
  caps = caps or Compiler.DEFAULT_CAPS
  local octaves = p.global.zone_octaves or 1
  local spec = compile_with(p, caps, octaves)
  local max = caps.max_samples or 255
  while spec.stats.samples > max and octaves < 3 do
    octaves = octaves + 1
    spec = compile_with(p, caps, octaves)
    table.insert(spec.warnings, 1, string.format(
      "Too many samples: using %d-octave zones (Global tab)", octaves))
  end
  if spec.stats.samples > max then
    table.insert(spec.warnings, 1, string.format(
      "This patch needs %d samples, more than Renoise allows (%d). "
      .. "Remove some routes.", spec.stats.samples, max))
  end
  return spec
end

-- Two specs with the same signature have the same Renoise objects (sample
-- and set counts, device kinds and order), so they can be updated in place
-- instead of rebuilt.
function Compiler.signature(spec)
  local s = { sets = {}, samples = {} }
  for i, set in ipairs(spec.sets) do
    local d = {}
    for k, dv in ipairs(set.devices) do
      d[k] = string.format("%s:%s:%s:%s", dv.kind, dv.target, tostring(dv.op), tostring(dv.bipolar))
    end
    s.sets[i] = d
  end
  for i, smp in ipairs(spec.samples) do
    s.samples[i] = string.format("%d:%d:%s", smp.set, smp.frames, tostring(smp.key_to_pitch))
  end
  return json.encode(s)
end

return Compiler
