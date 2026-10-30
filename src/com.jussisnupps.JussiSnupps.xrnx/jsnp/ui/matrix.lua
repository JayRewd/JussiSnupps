-- The routing matrix.
--   Audio:      rows = oscillators, columns = filters + Direct, cell = send
--   Modulation: rows = destinations (osc vol/pan/pitch, filter
--               cutoff/reso/drive), columns = envelopes + LFOs, cell = amount
-- Drag a cell up/down or double-click to type; "." means no route.

local Patch = require "jsnp.model.patch"
local Widgets = require "jsnp.ui.widgets"

local Matrix = {}

Matrix.TABS = { "Audio routing", "Modulation" }
Matrix.PAGE_SIZE = 18

local CW = Widgets.CELL_W
local NW = Widgets.NAME_W + 20

local function header_row(vb, first, columns)
  local row = vb:row{ spacing = 2, vb:text{ text = first, width = NW, font = "bold" } }
  for _, c in ipairs(columns) do
    Widgets.add(row, vb:text{
      text = Widgets.short(c.name, 9), width = CW, align = "center", font = "bold",
      tooltip = c.name,
    })
  end
  return row
end

local function audio_view(vb, ctx)
  local p = ctx.patch
  if #p.oscs == 0 then
    return vb:text{ text = "Add an oscillator to route audio.", style = "disabled" }
  end
  local columns = {}
  for _, f in ipairs(p.filters) do columns[#columns + 1] = { id = f.id, name = f.name } end
  columns[#columns + 1] = { id = "direct", name = "Direct" }

  local col = vb:column{ spacing = 2 }
  Widgets.add(col, header_row(vb, "Osc  \\  into", columns))
  for _, o in ipairs(p.oscs) do
    local row = vb:row{ spacing = 2, vb:text{ text = o.name, width = NW } }
    for _, c in ipairs(columns) do
      Widgets.add(row, Widgets.send_cell(vb, Patch.get_send(p, o.id, c.id),
        o.name .. " -> " .. c.name,
        function(send)
          Patch.set_send(p, o.id, c.id, send)
          ctx.changed()
        end))
    end
    Widgets.add(col, row)
  end
  Widgets.add(col, vb:text{
    text = "Each send is one voice layer. Filters run side by side, not in series.",
    style = "disabled",
  })
  return col
end

local function mod_view(vb, ctx)
  local p = ctx.patch
  local st = ctx.state
  local sources = Patch.mod_sources(p)
  local dests = Patch.mod_destinations(p)
  if #sources == 0 then
    return vb:text{ text = "Add an envelope or LFO to route modulation.", style = "disabled" }
  end
  if #dests == 0 then
    return vb:text{ text = "Add an oscillator or filter to modulate.", style = "disabled" }
  end

  local pages = math.max(1, math.ceil(#dests / Matrix.PAGE_SIZE))
  st.matrix_page = math.min(math.max(1, st.matrix_page or 1), pages)

  local col = vb:column{ spacing = 2 }
  Widgets.add(col, header_row(vb, "Destination  \\  from", sources))
  local first = (st.matrix_page - 1) * Matrix.PAGE_SIZE + 1
  local last_module = nil
  for i = first, math.min(#dests, first + Matrix.PAGE_SIZE - 1) do
    local d = dests[i]
    local label = Widgets.short(d.module.name, 11) .. " " .. Patch.PARAM_LABELS[d.param]
    if last_module and last_module ~= d.module then
      Widgets.add(col, vb:space{ height = 4 })
    end
    last_module = d.module
    local row = vb:row{ spacing = 2, vb:text{ text = label, width = NW,
                                              tooltip = d.module.name .. " " .. d.param } }
    for _, s in ipairs(sources) do
      Widgets.add(row, Widgets.amount_cell(vb, Patch.get_mod(p, s.id, d.dst, d.param),
        d.param == "pitch",
        s.name .. " -> " .. d.module.name .. " " .. Patch.PARAM_LABELS[d.param],
        function(amount)
          Patch.set_mod(p, s.id, d.dst, d.param, amount)
          ctx.changed()
        end))
    end
    Widgets.add(col, row)
  end
  local pager = Widgets.pager(vb, st.matrix_page, pages, function(page)
    st.matrix_page = page
    ctx.refresh("matrix")
  end)
  if pager then Widgets.add(col, pager) end
  Widgets.add(col, vb:text{
    text = "Amounts in %, pitch in semitones. Volume amounts below 100% keep a floor.",
    style = "disabled",
  })
  return col
end

-- ctx: patch, state {matrix_tab, matrix_page}, changed(), refresh(what)
function Matrix.build(vb, ctx)
  if ctx.state.matrix_tab == 2 then
    return mod_view(vb, ctx)
  end
  return audio_view(vb, ctx)
end

return Matrix
