-- Small ViewBuilder helpers: number fields that show and accept real
-- units (ms, Hz, %, degrees) while dragging on a sensible curve.

local Units = require "jsnp.compile.units"

local Widgets = {}

Widgets.CELL_W = 56
Widgets.NAME_W = 92

local function round(x, step)
  step = step or 1
  return math.floor(x / step + 0.5) * step
end

local function clean_number(s)
  if type(s) ~= "string" then return nil end
  local n = Units.split(s)
  return n
end

-- Child view helpers: API 6.2 names first, older names as fallback.
function Widgets.add(parent, child)
  local ok = pcall(function() parent:add_view(child) end)
  if not ok then parent:add_child(child) end
end

function Widgets.remove(parent, child)
  local ok = pcall(function() parent:remove_view(child) end)
  if not ok then parent:remove_child(child) end
end

-- A labelled column header.
function Widgets.header(vb, text, width, align)
  return vb:text{ text = text, width = width, align = align or "center", font = "bold" }
end

function Widgets.short(s, n)
  s = tostring(s or "")
  if #s <= n then return s end
  return s:sub(1, n - 1) .. "~"
end

-- Time in ms, dragged on a cubic curve (0 .. 20 s).
function Widgets.time_field(vb, ms, width, on_change)
  return vb:valuefield{
    width = width, min = 0, max = 1, value = Units.ms_to_ui(ms), align = "center",
    tostring = function(t) return Units.format_ms(Units.ui_to_ms(t)) end,
    tonumber = function(s)
      local v = Units.parse_ms(s, true)
      return v and Units.ms_to_ui(v) or nil
    end,
    notifier = function(t)
      local v = Units.ui_to_ms(t)
      on_change(round(v, v < 10 and 0.1 or 1))
    end,
  }
end

-- Rate in Hz, dragged on a log curve (0.01 .. 40 Hz).
function Widgets.hz_field(vb, hz, width, on_change)
  return vb:valuefield{
    width = width, min = 0, max = 1, value = Units.hz_to_ui(hz), align = "center",
    tostring = function(t) return Units.format_hz(Units.ui_to_hz(t)) end,
    tonumber = function(s)
      local v = Units.parse_hz(s, true)
      return v and Units.hz_to_ui(v) or nil
    end,
    notifier = function(t)
      local v = Units.ui_to_hz(t)
      on_change(round(v, v < 1 and 0.01 or 0.1))
    end,
  }
end

-- 0..1 value shown as 0..100 %.
function Widgets.percent_field(vb, x, width, on_change, lo, hi)
  lo, hi = lo or 0, hi or 100
  return vb:valuefield{
    width = width, min = lo, max = hi, value = x * 100, align = "center",
    tostring = function(v) return string.format("%d%%", round(v)) end,
    tonumber = function(s) return clean_number(s) end,
    notifier = function(v) on_change(round(v) / 100) end,
  }
end

-- -1..1 shown as L50 / C / R50.
function Widgets.pan_field(vb, x, width, on_change)
  return vb:valuefield{
    width = width, min = -100, max = 100, value = x * 100, align = "center",
    tostring = function(v)
      v = round(v)
      if v == 0 then return "C" end
      return (v < 0 and "L" or "R") .. math.abs(v)
    end,
    tonumber = function(s)
      local side, n = tostring(s):upper():match("^%s*([LRC]?)%s*(%d*)")
      if side == "C" then return 0 end
      n = tonumber(n)
      if not n then return clean_number(s) end
      return side == "L" and -n or n
    end,
    notifier = function(v) on_change(round(v) / 100) end,
  }
end

function Widgets.degree_field(vb, deg, width, on_change)
  return vb:valuefield{
    width = width, min = 0, max = 360, value = deg, align = "center",
    tostring = function(v) return string.format("%d deg", round(v)) end,
    tonumber = function(s) return clean_number(s) end,
    notifier = function(v) on_change(round(v)) end,
  }
end

-- Matrix cell for a send level (0..100 %). Empty cells show a dot.
function Widgets.send_cell(vb, send, tooltip, on_change)
  return vb:valuefield{
    width = Widgets.CELL_W, min = 0, max = 100, value = send * 100, align = "center",
    tooltip = tooltip,
    tostring = function(v)
      v = round(v)
      if v == 0 then return "." end
      return string.format("%d%%", v)
    end,
    tonumber = function(s)
      if s:match("^%s*%.?%s*$") then return 0 end
      return clean_number(s)
    end,
    notifier = function(v) on_change(round(v) / 100) end,
  }
end

-- Matrix cell for a modulation amount: -100..100 %, or semitones for pitch.
function Widgets.amount_cell(vb, amount, is_pitch, tooltip, on_change)
  local lo, hi, scale, fmt = -100, 100, 100, "%+d%%"
  if is_pitch then
    lo, hi, scale, fmt = -48, 48, 1, "%+dst"
  end
  return vb:valuefield{
    width = Widgets.CELL_W, min = lo, max = hi, value = amount * scale, align = "center",
    tooltip = tooltip,
    tostring = function(v)
      v = round(v)
      if v == 0 then return "." end
      return string.format(fmt, v)
    end,
    tonumber = function(s)
      if s:match("^%s*%.?%s*$") then return 0 end
      return clean_number(s)
    end,
    notifier = function(v) on_change(round(v) / scale) end,
  }
end

-- Prev/next page buttons, or nil when everything fits on one page.
function Widgets.pager(vb, page, pages, on_page)
  if pages <= 1 then return nil end
  return vb:row{
    spacing = 4,
    vb:button{ text = "<", width = 22, active = page > 1,
               notifier = function() on_page(page - 1) end },
    vb:text{ text = string.format("page %d / %d", page, pages), width = 70, align = "center" },
    vb:button{ text = ">", width = 22, active = page < pages,
               notifier = function() on_page(page + 1) end },
  }
end

return Widgets
