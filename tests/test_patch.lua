local Patch = require "jsnp.model.patch"

T.test("default patch: 3 oscs into one LP filter, 2 envelopes", function()
  local p = Patch.new_default()
  T.eq(#p.oscs, 3)
  T.eq(#p.filters, 1)
  T.eq(#p.envs, 2)
  T.eq(#p.lfos, 0)
  T.eq(p.filters[1].type, "LP Moog")
  for _, o in ipairs(p.oscs) do
    T.eq(Patch.get_send(p, o.id, "flt1"), 1, o.id .. " send")
    T.eq(Patch.get_mod(p, "env2", o.id, "volume"), 1, o.id .. " amp env")
    T.eq(Patch.get_mod(p, "env1", o.id, "volume"), 0)
  end
  T.eq(Patch.get_mod(p, "env1", "flt1", "cutoff"), 0.6)
  T.eq(p.oscs[2].cents, 7)
  T.eq(p.oscs[3].oct, -1)
  T.eq(p.oscs[3].wave, "square")
end)

T.test("ids are never reused", function()
  local p = Patch.new_empty()
  local a = Patch.add(p, "osc")
  local b = Patch.add(p, "osc")
  Patch.remove(p, b.id)
  local c = Patch.add(p, "osc")
  T.eq(a.id, "osc1")
  T.eq(c.id, "osc3")
end)

T.test("removing a module removes its routes", function()
  local p = Patch.new_default()
  Patch.remove(p, "flt1")
  T.eq(#p.audio, 0)
  T.eq(Patch.get_mod(p, "env1", "flt1", "cutoff"), 0)
  T.eq(#p.mods, 3)
  Patch.remove(p, "env2")
  T.eq(#p.mods, 0)
end)

T.test("routes: zero removes, values clamp", function()
  local p = Patch.new_default()
  Patch.set_send(p, "osc1", "flt1", 0)
  T.eq(Patch.get_send(p, "osc1", "flt1"), 0)
  T.eq(#p.audio, 2)
  Patch.set_mod(p, "env1", "osc1", "pitch", 99)
  T.eq(Patch.get_mod(p, "env1", "osc1", "pitch"), 48)
  Patch.set_mod(p, "env1", "flt1", "res", -5)
  T.eq(Patch.get_mod(p, "env1", "flt1", "res"), -1)
end)

T.test("new oscillators get routed like the first one", function()
  local p = Patch.new_default()
  local o = Patch.add(p, "osc")
  Patch.autoroute_osc(p, o)
  T.eq(Patch.get_send(p, o.id, "flt1"), 1)
  T.eq(Patch.get_mod(p, "env2", o.id, "volume"), 1)
end)

T.test("validate repairs broken data", function()
  local p = Patch.new_default()
  p.oscs[1].oct = 9
  p.oscs[1].wave = "banana"
  p.filters[1].type = "Nope"
  p.audio[#p.audio + 1] = { src = "osc1", dst = "flt9", send = 1 }
  p.mods[#p.mods + 1] = { src = "osc1", dst = "flt1", param = "cutoff", amount = 1 }
  p.mods[#p.mods + 1] = { src = "env1", dst = "flt1", param = "volume", amount = 1 }
  local q, warnings = Patch.validate(p)
  T.eq(q.oscs[1].oct, 4)
  T.eq(q.oscs[1].wave, "saw")
  T.eq(q.filters[1].type, "None")
  T.eq(#q.audio, 3)
  T.eq(#q.mods, 4)
  T.ok(#warnings >= 1)
end)

T.test("mod destinations: 3 per osc, 3 per filter", function()
  local p = Patch.new_default()
  T.eq(#Patch.mod_destinations(p), 3 * 3 + 3)
  T.eq(#Patch.mod_sources(p), 2)
end)
