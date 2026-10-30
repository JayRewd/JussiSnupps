-- Reading and writing modulation-device parameters in real units.
--
-- Parameter names differ between Renoise versions and its docs (AHDSR
-- "decay" vs "duration", LFO "amplitude"/"dephase" vs "amount"/"phase"),
-- so each parameter is looked up by several property names, then by the
-- parameter's display name.
--
-- Times and rates are converted by calibration: the parameter is swept
-- once and its value strings ("250 ms", "4.00 Hz") are parsed into a
-- lookup table. Tables are cached per session and in tool preferences.

local Units = require "jsnp.compile.units"

local Devices = {}

Devices.approximate = false -- true when a guess had to be used
Devices.dirty = false       -- calibration changed since last export

local PROPS = {
  ahdsr = {
    attack = { "attack" }, hold = { "hold" }, decay = { "decay", "duration" },
    sustain = { "sustain" }, release = { "release" },
  },
  lfo = {
    frequency = { "frequency" }, amplitude = { "amplitude", "amount" },
    phase = { "dephase", "phase" }, delay = { "delay" },
  },
  operand = { value = { "value" } },
}

local NAME_HINTS = {
  attack = { "attack" }, hold = { "hold" }, decay = { "decay", "duration" },
  sustain = { "sustain" }, release = { "release" },
  frequency = { "freq", "rate" }, amplitude = { "ampl", "amount", "depth" },
  phase = { "phase" }, delay = { "delay" }, value = { "value", "operand" },
}

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function try_get(obj, key)
  local ok, v = pcall(function() return obj[key] end)
  if ok then return v end
  return nil
end

local function is_param(v)
  local t = type(v)
  return v ~= nil and t ~= "number" and t ~= "string" and t ~= "boolean" and t ~= "function"
end

-- The DeviceParameter for `key` on device `dev` of `kind`, or nil.
function Devices.param(dev, kind, key)
  for _, prop in ipairs((PROPS[kind] or {})[key] or {}) do
    local p = try_get(dev, prop)
    if is_param(p) then return p end
  end
  local params = try_get(dev, "parameters")
  if type(params) == "table" then
    for _, hint in ipairs(NAME_HINTS[key] or {}) do
      for _, p in ipairs(params) do
        local n = try_get(p, "name")
        if type(n) == "string" and n:lower():find(hint, 1, true) then
          return p
        end
      end
    end
  end
  return nil
end

---------------------------------------------------------------------------
-- calibration

local calib = {}

local function sweep(param, parser)
  local vmin, vmax = param.value_min, param.value_max
  local old = param.value
  local pts = {}
  for i = 0, 64 do
    local v = vmin + (vmax - vmin) * i / 64
    param.value = v
    pts[#pts + 1] = { v = v, u = parser(param.value_string) }
  end
  param.value = old
  return Units.make_table(pts)
end

function Devices.calibration(key, param, parser)
  local t = calib[key]
  if t == nil then
    local ok, res = pcall(sweep, param, parser)
    t = (ok and res) or false
    calib[key] = t
    Devices.dirty = true
  end
  return t or nil
end

function Devices.export()
  local out = {}
  for k, t in pairs(calib) do
    if t then out[k] = t end
  end
  return out
end

function Devices.import(tbl)
  if type(tbl) ~= "table" then return end
  for k, t in pairs(tbl) do
    if type(t) == "table" and #t >= 8 then calib[k] = t end
  end
end

function Devices.reset_calibration()
  calib = {}
end

---------------------------------------------------------------------------
-- setters; each returns true when the parameter was found

local function set_raw(p, v)
  p.value = clamp(v, p.value_min, p.value_max)
end

-- `x` is a plain 0..1 number (sustain, amplitude, operand value).
function Devices.set_unit(dev, kind, key, x)
  local p = Devices.param(dev, kind, key)
  if not p then return false end
  set_raw(p, x)
  return true
end

function Devices.set_ms(dev, kind, key, ms)
  local p = Devices.param(dev, kind, key)
  if not p then return false end
  local t = Devices.calibration(kind .. "." .. key, p, Units.parse_ms)
  if t then
    set_raw(p, Units.invert(t, ms))
  else
    Devices.approximate = true
    set_raw(p, p.value_min + Units.fallback_time(ms) * (p.value_max - p.value_min))
  end
  return true
end

function Devices.set_hz(dev, kind, key, hz)
  local p = Devices.param(dev, kind, key)
  if not p then return false end
  local t = Devices.calibration(kind .. "." .. key, p, Units.parse_hz)
  if t then
    set_raw(p, Units.invert(t, hz))
  else
    Devices.approximate = true
    set_raw(p, p.value_min + Units.fallback_hz(hz) * (p.value_max - p.value_min))
  end
  return true
end

function Devices.set_degrees(dev, kind, key, deg)
  local p = Devices.param(dev, kind, key)
  if not p then return false end
  if p.value_max >= 359 then
    set_raw(p, deg)
  else
    set_raw(p, p.value_min + (deg % 360) / 360 * (p.value_max - p.value_min))
  end
  return true
end

---------------------------------------------------------------------------
-- whole-device parameter writes from a device spec (see compiler)

local LFO_MODES = { sine = "MODE_SIN", saw = "MODE_SAW", pulse = "MODE_PULSE", random = "MODE_RANDOM" }

local function changed(new, old, key)
  return old == nil or old[key] ~= new[key]
end

-- Writes the spec's params; when `old_params` is given, only changes.
-- Returns a list of parameter keys that couldn't be found.
function Devices.apply_params(dev, kind, params, old_params)
  local missing = {}
  local function note(ok, key)
    if not ok then missing[#missing + 1] = kind .. "." .. key end
  end
  if kind == "ahdsr" then
    for _, key in ipairs({ "attack", "hold", "decay", "release" }) do
      if changed(params, old_params, key) then
        note(Devices.set_ms(dev, kind, key, params[key]), key)
      end
    end
    if changed(params, old_params, "sustain") then
      note(Devices.set_unit(dev, kind, "sustain", params.sustain), "sustain")
    end
  elseif kind == "lfo" then
    if changed(params, old_params, "shape") then
      local mode = renoise.SampleLfoModulationDevice[LFO_MODES[params.shape] or "MODE_SIN"]
      local ok = pcall(function() dev.mode = mode end)
      note(ok, "mode")
    end
    if changed(params, old_params, "hz") then
      note(Devices.set_hz(dev, kind, "frequency", params.hz), "frequency")
    end
    if changed(params, old_params, "amplitude") then
      note(Devices.set_unit(dev, kind, "amplitude", params.amplitude), "amplitude")
    end
    if changed(params, old_params, "phase") then
      note(Devices.set_degrees(dev, kind, "phase", params.phase), "phase")
    end
    if changed(params, old_params, "delay") then
      note(Devices.set_ms(dev, kind, "delay", params.delay), "delay")
    end
  elseif kind == "operand" then
    if changed(params, old_params, "value") then
      note(Devices.set_unit(dev, kind, "value", params.value), "value")
    end
  end
  return missing
end

return Devices
