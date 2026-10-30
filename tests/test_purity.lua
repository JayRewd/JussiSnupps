-- Pure modules must not touch `renoise` or create globals, so they run
-- (and are tested) outside Renoise.

local PURE = {
  "jsnp.util.json", "jsnp.model.patch", "jsnp.model.serialize",
  "jsnp.dsp.wavegen", "jsnp.dsp.zones", "jsnp.compile.units",
  "jsnp.compile.compiler",
}

T.test("pure modules use no unknown globals", function()
  T.fresh()
  local known = {}
  for k in pairs(_G) do known[k] = true end
  known.renoise = nil
  local bad = {}
  setmetatable(_G, {
    __index = function(_, k)
      bad[#bad + 1] = "read " .. tostring(k)
      return nil
    end,
    __newindex = function(t, k, v)
      bad[#bad + 1] = "write " .. tostring(k)
      rawset(t, k, v)
    end,
  })
  local ok, err = pcall(function()
    local mods = {}
    for _, name in ipairs(PURE) do mods[name] = require(name) end
    local Patch = mods["jsnp.model.patch"]
    local p = Patch.new_default()
    local spec = mods["jsnp.compile.compiler"].compile(p)
    mods["jsnp.model.serialize"].from_lines(mods["jsnp.model.serialize"].to_lines(p, {}))
    mods["jsnp.dsp.wavegen"].render(spec.samples[1])
  end)
  setmetatable(_G, nil)
  T.ok(ok, tostring(err))
  T.eq(#bad, 0, table.concat(bad, ", "))
end)
