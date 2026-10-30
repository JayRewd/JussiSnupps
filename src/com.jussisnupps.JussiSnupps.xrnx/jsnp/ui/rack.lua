-- The module rack: one tab per module type, one row per module, with
-- "+ Add" and "x" (remove) buttons. Rows edit the patch tables directly
-- and call ctx.changed(); adds/removes also call ctx.refresh().

local Patch = require "jsnp.model.patch"
local Widgets = require "jsnp.ui.widgets"

local Rack = {}

Rack.TABS = { "Oscillators", "Envelopes", "LFOs", "Filters", "Global" }
Rack.TAB_KIND = { "osc", "env", "lfo", "flt" }
Rack.PAGE_SIZE = 8

local W = Widgets.NAME_W

local function name_field(vb, m, ctx)
  return vb:textfield{
    text = m.name, width = W,
    notifier = function(t)
      if t == m.name then return end
      m.name = t
      ctx.changed()
      ctx.refresh("matrix")
    end,
  }
end

local function remove_button(vb, m, ctx)
  return vb:button{
    text = "x", width = 22, tooltip = "Remove " .. m.name .. " and its routes",
    notifier = function()
      Patch.remove(ctx.patch, m.id)
      ctx.changed()
      ctx.refresh("all")
    end,
  }
end

---------------------------------------------------------------------------
-- rows per module type

local function osc_header(vb)
  return vb:row{
    spacing = 2,
    Widgets.header(vb, "Oscillator", W, "left"), Widgets.header(vb, "Wave", 76),
    Widgets.header(vb, "Width", 52), Widgets.header(vb, "Octave", 52),
    Widgets.header(vb, "Note", 52), Widgets.header(vb, "Cent", 56),
    Widgets.header(vb, "Level", 52), Widgets.header(vb, "Pan", 52),
  }
end

local function osc_row(vb, o, ctx)
  local pw = Widgets.percent_field(vb, o.pw, 52, function(x)
    o.pw = x
    ctx.changed()
  end, 1, 99)
  pw.active = (o.wave == "pulse")
  pw.tooltip = "Pulse width (Pulse wave only)"
  return vb:row{
    spacing = 2,
    name_field(vb, o, ctx),
    vb:popup{
      items = Patch.WAVE_LABELS, width = 76,
      value = Patch.index_of(Patch.WAVES, o.wave) or 3,
      notifier = function(i)
        o.wave = Patch.WAVES[i]
        pw.active = (o.wave == "pulse")
        ctx.changed()
      end,
    },
    pw,
    vb:valuebox{ min = -4, max = 4, value = o.oct, width = 52,
                 tooltip = "Octave offset",
                 notifier = function(v) o.oct = v; ctx.changed() end },
    vb:valuebox{ min = -12, max = 12, value = o.semi, width = 52,
                 tooltip = "Note offset in semitones",
                 notifier = function(v) o.semi = v; ctx.changed() end },
    vb:valuebox{ min = -100, max = 100, value = o.cents, width = 56,
                 tooltip = "Fine tune in cents",
                 notifier = function(v) o.cents = v; ctx.changed() end },
    Widgets.percent_field(vb, o.level, 52, function(x) o.level = x; ctx.changed() end),
    Widgets.pan_field(vb, o.pan, 52, function(x) o.pan = x; ctx.changed() end),
    remove_button(vb, o, ctx),
  }
end

local function env_header(vb)
  return vb:row{
    spacing = 2,
    Widgets.header(vb, "Envelope", W, "left"), Widgets.header(vb, "Attack", 64),
    Widgets.header(vb, "Hold", 64), Widgets.header(vb, "Decay", 64),
    Widgets.header(vb, "Sustain", 56), Widgets.header(vb, "Release", 64),
  }
end

local function env_row(vb, e, ctx)
  local function time(key)
    return Widgets.time_field(vb, e[key], 64, function(ms) e[key] = ms; ctx.changed() end)
  end
  return vb:row{
    spacing = 2,
    name_field(vb, e, ctx),
    time("a"), time("h"), time("d"),
    Widgets.percent_field(vb, e.s, 56, function(x) e.s = x; ctx.changed() end),
    time("r"),
    remove_button(vb, e, ctx),
  }
end

local function lfo_header(vb)
  return vb:row{
    spacing = 2,
    Widgets.header(vb, "LFO", W, "left"), Widgets.header(vb, "Shape", 76),
    Widgets.header(vb, "Rate", 64), Widgets.header(vb, "Phase", 64),
    Widgets.header(vb, "Delay", 64),
  }
end

local function lfo_row(vb, l, ctx)
  return vb:row{
    spacing = 2,
    name_field(vb, l, ctx),
    vb:popup{
      items = Patch.LFO_LABELS, width = 76,
      value = Patch.index_of(Patch.LFO_SHAPES, l.shape) or 1,
      notifier = function(i) l.shape = Patch.LFO_SHAPES[i]; ctx.changed() end,
    },
    Widgets.hz_field(vb, l.hz, 64, function(hz) l.hz = hz; ctx.changed() end),
    Widgets.degree_field(vb, l.phase, 64, function(d) l.phase = d; ctx.changed() end),
    Widgets.time_field(vb, l.delay_ms, 64, function(ms) l.delay_ms = ms; ctx.changed() end),
    remove_button(vb, l, ctx),
  }
end

local function flt_header(vb)
  return vb:row{
    spacing = 2,
    Widgets.header(vb, "Filter", W, "left"), Widgets.header(vb, "Type", 104),
    Widgets.header(vb, "Cutoff", 56), Widgets.header(vb, "Reso", 56),
    Widgets.header(vb, "Drive", 56),
  }
end

local function flt_row(vb, f, ctx)
  local types = ctx.filter_types
  local index = Patch.index_of(types, f.type)
  if not index then
    types = { f.type }
    for _, t in ipairs(ctx.filter_types) do types[#types + 1] = t end
    index = 1
  end
  return vb:row{
    spacing = 2,
    name_field(vb, f, ctx),
    vb:popup{
      items = types, width = 104, value = index,
      notifier = function(i) f.type = types[i]; ctx.changed() end,
    },
    Widgets.percent_field(vb, f.cutoff, 56, function(x) f.cutoff = x; ctx.changed() end),
    Widgets.percent_field(vb, f.res, 56, function(x) f.res = x; ctx.changed() end),
    Widgets.percent_field(vb, f.drive, 56, function(x) f.drive = x; ctx.changed() end),
    remove_button(vb, f, ctx),
  }
end

local ROWS = {
  osc = { header = osc_header, row = osc_row },
  env = { header = env_header, row = env_row },
  lfo = { header = lfo_header, row = lfo_row },
  flt = { header = flt_header, row = flt_row },
}

---------------------------------------------------------------------------

local function global_view(vb, ctx)
  local g = ctx.patch.global
  local function line(label, view, tip)
    return vb:row{ spacing = 4, vb:text{ text = label, width = 140, tooltip = tip }, view }
  end
  return vb:column{
    spacing = 2,
    line("Interpolation", vb:popup{
      items = Patch.INTERP_LABELS, width = 100,
      value = Patch.index_of(Patch.INTERP, g.interp) or 4,
      notifier = function(i) g.interp = Patch.INTERP[i]; ctx.changed() end,
    }),
    line("Oversampling", vb:checkbox{
      value = g.oversample,
      notifier = function(v) g.oversample = v; ctx.changed() end,
    }, "Better quality for high notes, twice the CPU"),
    line("Velocity -> volume", vb:checkbox{
      value = g.vel_to_vol,
      notifier = function(v) g.vel_to_vol = v; ctx.changed() end,
    }),
    line("Monophonic", vb:checkbox{
      value = g.mono,
      notifier = function(v) g.mono = v; ctx.changed() end,
    }),
    line("Glide", vb:valuebox{
      min = 0, max = 255, value = g.glide, width = 60,
      notifier = function(v) g.glide = v; ctx.changed() end,
    }, "Glide speed in monophonic mode (0 = off)"),
    line("Zone size", vb:popup{
      items = { "1 octave", "2 octaves", "3 octaves" }, width = 100,
      value = g.zone_octaves,
      notifier = function(i) g.zone_octaves = i; ctx.changed() end,
    }, "Larger zones = fewer samples, slightly duller high notes"),
    line("Gate release", Widgets.time_field(vb, g.gate_release_ms, 64, function(ms)
      g.gate_release_ms = math.max(1, ms)
      ctx.changed()
    end), "Release used when no envelope controls an oscillator's volume"),
  }
end

-- ctx: patch, filter_types, state {rack_tab, rack_page}, changed(), refresh(what)
function Rack.build(vb, ctx)
  local st = ctx.state
  if st.rack_tab == 5 then
    return global_view(vb, ctx)
  end
  local kind = Rack.TAB_KIND[st.rack_tab]
  local list = ctx.patch[Patch.LIST_OF[kind]]
  local rows = ROWS[kind]
  local pages = math.max(1, math.ceil(#list / Rack.PAGE_SIZE))
  st.rack_page = math.min(math.max(1, st.rack_page or 1), pages)

  local col = vb:column{ spacing = 2 }
  if #list == 0 then
    Widgets.add(col, vb:text{ text = "No " .. Rack.TABS[st.rack_tab]:lower() .. " yet.",
                          style = "disabled" })
  else
    Widgets.add(col, rows.header(vb))
    local first = (st.rack_page - 1) * Rack.PAGE_SIZE + 1
    for i = first, math.min(#list, first + Rack.PAGE_SIZE - 1) do
      Widgets.add(col, rows.row(vb, list[i], ctx))
    end
  end

  local footer = vb:row{
    spacing = 6,
    vb:button{
      text = "+ Add " .. Patch.KIND_LABEL[kind], width = 110,
      notifier = function()
        local m = Patch.add(ctx.patch, kind)
        if kind == "osc" then Patch.autoroute_osc(ctx.patch, m) end
        st.rack_page = math.ceil(#list / Rack.PAGE_SIZE)
        ctx.changed()
        ctx.refresh("all")
      end,
    },
  }
  local pager = Widgets.pager(vb, st.rack_page, pages, function(page)
    st.rack_page = page
    ctx.refresh("rack")
  end)
  if pager then Widgets.add(footer, pager) end
  Widgets.add(col, footer)
  return col
end

return Rack
