-- Unit conversions: UI control curves, parsing Renoise's value strings
-- ("250 ms", "1.20 s", "4.00 Hz"), and calibration tables that map a
-- device parameter's raw value to real units and back.

local Units = {}

Units.TIME_MAX_MS = 20000
Units.HZ_MIN = 0.01
Units.HZ_MAX = 40

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

---------------------------------------------------------------------------
-- UI curves (control position 0..1 <-> real value)

function Units.ui_to_ms(t)
  t = clamp(t, 0, 1)
  return Units.TIME_MAX_MS * t * t * t
end

function Units.ms_to_ui(ms)
  return clamp((math.max(0, ms) / Units.TIME_MAX_MS) ^ (1 / 3), 0, 1)
end

function Units.ui_to_hz(t)
  t = clamp(t, 0, 1)
  return Units.HZ_MIN * (Units.HZ_MAX / Units.HZ_MIN) ^ t
end

function Units.hz_to_ui(hz)
  hz = clamp(hz, Units.HZ_MIN, Units.HZ_MAX)
  return math.log(hz / Units.HZ_MIN) / math.log(Units.HZ_MAX / Units.HZ_MIN)
end

function Units.format_ms(ms)
  if ms < 10 then
    return string.format("%.1f ms", ms)
  elseif ms < 1000 then
    return string.format("%d ms", math.floor(ms + 0.5))
  end
  return string.format("%.2f s", ms / 1000)
end

function Units.format_hz(hz)
  if hz < 1 then
    return string.format("%.2f Hz", hz)
  elseif hz < 10 then
    return string.format("%.1f Hz", hz)
  end
  return string.format("%d Hz", math.floor(hz + 0.5))
end

---------------------------------------------------------------------------
-- parsing

-- Splits "1,5 s" / "250ms" / "-3.0 dB" into (number, lowercase unit).
function Units.split(s)
  if type(s) ~= "string" or s:find("/") then
    return nil
  end
  local num, rest = s:match("^%s*([-+]?%d*[%.,]?%d+)%s*(.-)%s*$")
  if not num then
    return nil
  end
  local n = tonumber((num:gsub(",", ".")))
  if not n then
    return nil
  end
  return n, rest:lower()
end

-- Time in ms. A bare number counts as ms only when `bare_is_ms` is set
-- (user input); Renoise strings always carry a unit.
function Units.parse_ms(s, bare_is_ms)
  local n, unit = Units.split(s)
  if not n then return nil end
  if unit == "ms" then return n end
  if unit == "s" or unit == "sec" or unit == "secs" then return n * 1000 end
  if unit == "min" then return n * 60000 end
  if unit == "" and bare_is_ms then return n end
  return nil
end

function Units.parse_hz(s, bare_is_hz)
  local n, unit = Units.split(s)
  if not n then return nil end
  if unit == "hz" then return n end
  if unit == "khz" then return n * 1000 end
  if unit == "" and bare_is_hz then return n end
  return nil
end

---------------------------------------------------------------------------
-- calibration tables: { {v = raw value, u = unit value}, ... } with u
-- non-decreasing.

-- Builds a table from sampled points (in raw-value order). Returns nil when
-- the points don't describe a usable rising curve.
function Units.make_table(points)
  local usable = {}
  for _, pt in ipairs(points) do
    if type(pt.u) == "number" and pt.u == pt.u then
      usable[#usable + 1] = { v = pt.v, u = pt.u }
    end
  end
  if #usable < 8 then return nil end
  table.sort(usable, function(a, b) return a.v < b.v end)
  local drops = 0
  for i = 2, #usable do
    if usable[i].u < usable[i - 1].u then drops = drops + 1 end
  end
  if drops > 0 or usable[#usable].u <= usable[1].u then
    return nil
  end
  return usable
end

local function lerp_u(a, b, u)
  -- interpolate in log space when both ends are positive (exponential
  -- curves are common for times and rates)
  if a.u > 0 and b.u > 0 and u > 0 then
    local la, lb, lu = math.log(a.u), math.log(b.u), math.log(u)
    if lb ~= la then
      return a.v + (b.v - a.v) * (lu - la) / (lb - la)
    end
  end
  if b.u == a.u then return a.v end
  return a.v + (b.v - a.v) * (u - a.u) / (b.u - a.u)
end

-- Raw value that gives unit value `u` (clamped to the table's range).
function Units.invert(tbl, u)
  if u <= tbl[1].u then return tbl[1].v end
  if u >= tbl[#tbl].u then return tbl[#tbl].v end
  for i = 2, #tbl do
    if tbl[i].u >= u then
      return lerp_u(tbl[i - 1], tbl[i], u)
    end
  end
  return tbl[#tbl].v
end

-- Unit value at raw value `v`.
function Units.lookup(tbl, v)
  if v <= tbl[1].v then return tbl[1].u end
  if v >= tbl[#tbl].v then return tbl[#tbl].u end
  for i = 2, #tbl do
    if tbl[i].v >= v then
      local a, b = tbl[i - 1], tbl[i]
      return a.u + (b.u - a.u) * (v - a.v) / (b.v - a.v)
    end
  end
  return tbl[#tbl].u
end

---------------------------------------------------------------------------
-- guesses used only when Renoise's value strings can't be parsed

function Units.fallback_time(ms)
  return clamp((math.max(0, ms) / 10000) ^ (1 / 3), 0, 1)
end

function Units.fallback_hz(hz)
  return clamp(math.log10(math.max(hz, 0.001) * 1000) / 4.2, 0, 1)
end

return Units
