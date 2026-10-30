-- The synth patch: modules (oscillators, envelopes, LFOs, filters) and the
-- routes between them. Plain Lua tables only, no Renoise API, so it can be
-- tested offline and stored as JSON.
--
-- Route kinds:
--   audio: osc -> filter id or "direct", with a send level 0..1
--   mods:  env/lfo -> osc (volume|pan|pitch) or filter (cutoff|res|drive)
--          amount -1..1, except pitch which is in semitones (-48..48)

local Patch = {}

Patch.VERSION = 1

Patch.WAVES = { "sine", "triangle", "saw", "square", "pulse", "noise" }
Patch.WAVE_LABELS = { "Sine", "Triangle", "Saw", "Square", "Pulse", "Noise" }

Patch.LFO_SHAPES = { "sine", "saw", "pulse", "random" }
Patch.LFO_LABELS = { "Sine", "Saw", "Pulse", "Random" }

Patch.INTERP = { "none", "linear", "cubic", "sinc" }
Patch.INTERP_LABELS = { "None", "Linear", "Cubic", "Sinc" }

-- Renoise's filter list (filter_version 3). At runtime the list is read
-- from Renoise itself; this copy is the offline default.
Patch.FILTER_TYPES = {
  "None", "LP Clean", "LP K35", "LP Moog", "LP Diode",
  "HP Clean", "HP K35", "HP Moog", "BP Clean", "BP K35", "BP Moog",
  "BandPass", "BandStop", "Vowel", "Comb", "Decimator",
  "Dist Shape", "Dist Fold", "AM Sine", "AM Triangle", "AM Saw", "AM Pulse",
}

Patch.OSC_PARAMS = { "volume", "pan", "pitch" }
Patch.FILTER_PARAMS = { "cutoff", "res", "drive" }
Patch.PARAM_LABELS = {
  volume = "Vol", pan = "Pan", pitch = "Pitch",
  cutoff = "Cutoff", res = "Reso", drive = "Drive",
}

Patch.KINDS = { "osc", "env", "lfo", "flt" }
Patch.LIST_OF = { osc = "oscs", env = "envs", lfo = "lfos", flt = "filters" }
Patch.KIND_LABEL = { osc = "Osc", env = "Env", lfo = "LFO", flt = "Filter" }

Patch.LIMITS = {
  osc = { pw = { 0.01, 0.99 }, oct = { -4, 4 }, semi = { -12, 12 },
          cents = { -100, 100 }, level = { 0, 1 }, pan = { -1, 1 } },
  env = { a = { 0, 20000 }, h = { 0, 20000 }, d = { 0, 20000 },
          s = { 0, 1 }, r = { 0, 20000 } },
  lfo = { hz = { 0.01, 40 }, phase = { 0, 360 }, delay_ms = { 0, 10000 } },
  flt = { cutoff = { 0, 1 }, res = { 0, 1 }, drive = { 0, 1 } },
  global = { gate_release_ms = { 1, 10000 }, glide = { 0, 255 },
             zone_octaves = { 1, 3 } },
}
Patch.SEND_LIMITS = { 0, 1 }
Patch.AMOUNT_LIMITS = { -1, 1 }
Patch.PITCH_LIMITS = { -48, 48 }

local function clamp(v, lo, hi)
  if type(v) ~= "number" or v ~= v then
    return lo
  end
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end
Patch.clamp = clamp

local function contains(list, v)
  for _, x in ipairs(list) do
    if x == v then return true end
  end
  return false
end

function Patch.index_of(list, v)
  for i, x in ipairs(list) do
    if x == v then return i end
  end
  return nil
end

function Patch.copy(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k, v in pairs(t) do
    out[k] = Patch.copy(v)
  end
  return out
end

function Patch.new_uid()
  return string.format("%06x%06x", math.random(0, 0xFFFFFF), math.random(0, 0xFFFFFF))
end

---------------------------------------------------------------------------
-- module constructors

local DEFAULTS = {
  osc = function(id, n)
    return { id = id, name = "Osc " .. n, wave = "saw", pw = 0.5, oct = 0,
             semi = 0, cents = 0, level = 0.6, pan = 0 }
  end,
  env = function(id, n)
    return { id = id, name = "Env " .. n, a = 5, h = 0, d = 400, s = 0.6, r = 250 }
  end,
  lfo = function(id, n)
    return { id = id, name = "LFO " .. n, shape = "sine", hz = 4, phase = 0,
             delay_ms = 0 }
  end,
  flt = function(id, n)
    return { id = id, name = "Filter " .. n, type = "LP Moog", cutoff = 0.5,
             res = 0.25, drive = 0 }
  end,
}

function Patch.new_empty()
  return {
    v = Patch.VERSION,
    uid = Patch.new_uid(),
    name = "JussiSnupps",
    global = {
      interp = "sinc", oversample = false, gate_release_ms = 8,
      mono = false, glide = 0, vel_to_vol = true, zone_octaves = 1,
    },
    oscs = {}, envs = {}, lfos = {}, filters = {},
    audio = {}, mods = {},
    next = { osc = 1, env = 1, lfo = 1, flt = 1 },
  }
end

-- Adds a module of `kind` ("osc", "env", "lfo", "flt") and returns it.
function Patch.add(p, kind)
  local n = p.next[kind]
  p.next[kind] = n + 1
  local m = DEFAULTS[kind](kind .. n, n)
  local list = p[Patch.LIST_OF[kind]]
  list[#list + 1] = m
  return m
end

-- The patch every new instrument starts with: 3 oscillators into one
-- low-pass filter, env 1 on the filter cutoff, env 2 on the volume.
function Patch.new_default()
  local p = Patch.new_empty()
  local o1 = Patch.add(p, "osc")
  o1.wave = "saw"
  local o2 = Patch.add(p, "osc")
  o2.wave = "saw"
  o2.cents = 7
  local o3 = Patch.add(p, "osc")
  o3.wave = "square"
  o3.oct = -1

  local f = Patch.add(p, "flt")
  f.type = "LP Moog"
  f.cutoff = 0.45
  f.res = 0.25
  f.drive = 0

  local e1 = Patch.add(p, "env")
  e1.name = "Env 1 Filter"
  e1.a, e1.h, e1.d, e1.s, e1.r = 5, 0, 600, 0.3, 300
  local e2 = Patch.add(p, "env")
  e2.name = "Env 2 Amp"
  e2.a, e2.h, e2.d, e2.s, e2.r = 2, 0, 300, 0.8, 200

  for _, o in ipairs(p.oscs) do
    Patch.set_send(p, o.id, f.id, 1)
    Patch.set_mod(p, e2.id, o.id, "volume", 1)
  end
  Patch.set_mod(p, e1.id, f.id, "cutoff", 0.6)
  return p
end

-- Gives a freshly added oscillator sensible routes: into the first filter
-- (or Direct), with the same volume envelopes as the first oscillator.
function Patch.autoroute_osc(p, osc)
  local dst = p.filters[1] and p.filters[1].id or "direct"
  Patch.set_send(p, osc.id, dst, 1)
  local first = p.oscs[1]
  if first and first ~= osc then
    for _, r in ipairs(Patch.copy(p.mods)) do
      if r.dst == first.id and r.param == "volume" then
        Patch.set_mod(p, r.src, osc.id, "volume", r.amount)
      end
    end
  end
end

---------------------------------------------------------------------------
-- lookup and removal

function Patch.find(p, id)
  for _, kind in ipairs(Patch.KINDS) do
    for i, m in ipairs(p[Patch.LIST_OF[kind]]) do
      if m.id == id then
        return m, kind, i
      end
    end
  end
  return nil
end

function Patch.kind_of(id)
  return type(id) == "string" and id:match("^(%a+)%d+$") or nil
end

function Patch.remove(p, id)
  local _, kind, index = Patch.find(p, id)
  if not kind then return false end
  table.remove(p[Patch.LIST_OF[kind]], index)
  for i = #p.audio, 1, -1 do
    local r = p.audio[i]
    if r.src == id or r.dst == id then table.remove(p.audio, i) end
  end
  for i = #p.mods, 1, -1 do
    local r = p.mods[i]
    if r.src == id or r.dst == id then table.remove(p.mods, i) end
  end
  return true
end

---------------------------------------------------------------------------
-- routes

function Patch.get_send(p, src, dst)
  for _, r in ipairs(p.audio) do
    if r.src == src and r.dst == dst then return r.send end
  end
  return 0
end

function Patch.set_send(p, src, dst, send)
  send = clamp(send, Patch.SEND_LIMITS[1], Patch.SEND_LIMITS[2])
  for i, r in ipairs(p.audio) do
    if r.src == src and r.dst == dst then
      if send <= 0 then
        table.remove(p.audio, i)
      else
        r.send = send
      end
      return
    end
  end
  if send > 0 then
    p.audio[#p.audio + 1] = { src = src, dst = dst, send = send }
  end
end

function Patch.get_mod(p, src, dst, param)
  for _, r in ipairs(p.mods) do
    if r.src == src and r.dst == dst and r.param == param then
      return r.amount
    end
  end
  return 0
end

function Patch.amount_limits(param)
  if param == "pitch" then return Patch.PITCH_LIMITS end
  return Patch.AMOUNT_LIMITS
end

function Patch.set_mod(p, src, dst, param, amount)
  local lim = Patch.amount_limits(param)
  amount = clamp(amount, lim[1], lim[2])
  for i, r in ipairs(p.mods) do
    if r.src == src and r.dst == dst and r.param == param then
      if amount == 0 then
        table.remove(p.mods, i)
      else
        r.amount = amount
      end
      return
    end
  end
  if amount ~= 0 then
    p.mods[#p.mods + 1] = { src = src, dst = dst, param = param, amount = amount }
  end
end

-- Rows and columns for the routing matrices.
function Patch.mod_sources(p)
  local out = {}
  for _, e in ipairs(p.envs) do out[#out + 1] = e end
  for _, l in ipairs(p.lfos) do out[#out + 1] = l end
  return out
end

function Patch.mod_destinations(p)
  local out = {}
  for _, o in ipairs(p.oscs) do
    for _, param in ipairs(Patch.OSC_PARAMS) do
      out[#out + 1] = { module = o, dst = o.id, param = param }
    end
  end
  for _, f in ipairs(p.filters) do
    for _, param in ipairs(Patch.FILTER_PARAMS) do
      out[#out + 1] = { module = f, dst = f.id, param = param }
    end
  end
  return out
end

---------------------------------------------------------------------------
-- validation: clamps values, drops broken routes, returns warnings

local function valid_param(kind, param)
  if kind == "osc" then return contains(Patch.OSC_PARAMS, param) end
  if kind == "flt" then return contains(Patch.FILTER_PARAMS, param) end
  return false
end

function Patch.validate(p, filter_types)
  local warnings = {}
  local function warn(msg) warnings[#warnings + 1] = msg end
  filter_types = filter_types or Patch.FILTER_TYPES

  if type(p) ~= "table" then
    return nil, { "patch is not a table" }
  end
  p.v = Patch.VERSION
  p.uid = (type(p.uid) == "string" and p.uid:match("^[%w]+$")) and p.uid or Patch.new_uid()
  p.name = type(p.name) == "string" and p.name or "JussiSnupps"

  local g = type(p.global) == "table" and p.global or {}
  local dg = Patch.new_empty().global
  for k, v in pairs(dg) do
    if type(g[k]) ~= type(v) then g[k] = v end
  end
  if not contains(Patch.INTERP, g.interp) then g.interp = "sinc" end
  for k, lim in pairs(Patch.LIMITS.global) do
    g[k] = clamp(g[k], lim[1], lim[2])
  end
  g.zone_octaves = math.floor(g.zone_octaves)
  p.global = g

  p.next = type(p.next) == "table" and p.next or {}
  local seen = {}
  for _, kind in ipairs(Patch.KINDS) do
    local key = Patch.LIST_OF[kind]
    local list = type(p[key]) == "table" and p[key] or {}
    local clean = {}
    local max_n = 0
    for _, m in ipairs(list) do
      local n = type(m) == "table" and type(m.id) == "string"
        and tonumber(m.id:match("^" .. kind .. "(%d+)$"))
      if not n or seen[m.id] then
        warn("dropped a broken " .. Patch.KIND_LABEL[kind] .. " module")
      else
        seen[m.id] = true
        max_n = math.max(max_n, n)
        local d = DEFAULTS[kind](m.id, n)
        for k, v in pairs(d) do
          if type(m[k]) ~= type(v) then m[k] = v end
        end
        for k, lim in pairs(Patch.LIMITS[kind]) do
          m[k] = clamp(m[k], lim[1], lim[2])
        end
        if kind == "osc" then
          m.oct = math.floor(m.oct + 0.5)
          m.semi = math.floor(m.semi + 0.5)
          if not contains(Patch.WAVES, m.wave) then m.wave = "saw" end
        elseif kind == "lfo" then
          if not contains(Patch.LFO_SHAPES, m.shape) then m.shape = "sine" end
        elseif kind == "flt" then
          if not contains(filter_types, m.type) then
            warn(m.name .. ": unknown filter type '" .. tostring(m.type) .. "', using None")
            m.type = "None"
          end
        end
        clean[#clean + 1] = m
      end
    end
    p[key] = clean
    p.next[kind] = math.max(tonumber(p.next[kind]) or 1, max_n + 1)
  end

  local audio, akeys = {}, {}
  for _, r in ipairs(type(p.audio) == "table" and p.audio or {}) do
    local ok = type(r) == "table" and Patch.kind_of(r.src) == "osc" and seen[r.src]
      and (r.dst == "direct" or (Patch.kind_of(r.dst) == "flt" and seen[r.dst]))
      and type(r.send) == "number"
    if ok then
      r.send = clamp(r.send, 0, 1)
      local k = r.src .. ">" .. r.dst
      if r.send > 0 and not akeys[k] then
        akeys[k] = true
        audio[#audio + 1] = { src = r.src, dst = r.dst, send = r.send }
      end
    end
  end
  p.audio = audio

  local mods, mkeys = {}, {}
  for _, r in ipairs(type(p.mods) == "table" and p.mods or {}) do
    local sk = type(r) == "table" and Patch.kind_of(r.src)
    local dk = type(r) == "table" and Patch.kind_of(r.dst)
    local ok = (sk == "env" or sk == "lfo") and seen[r.src] and seen[r.dst]
      and valid_param(dk, r.param) and type(r.amount) == "number"
    if ok then
      local lim = Patch.amount_limits(r.param)
      r.amount = clamp(r.amount, lim[1], lim[2])
      local k = r.src .. ">" .. r.dst .. "." .. r.param
      if r.amount ~= 0 and not mkeys[k] then
        mkeys[k] = true
        mods[#mods + 1] = { src = r.src, dst = r.dst, param = r.param, amount = r.amount }
      end
    end
  end
  p.mods = mods

  return p, warnings
end

return Patch
