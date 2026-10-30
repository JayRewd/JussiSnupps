local Z = require "jsnp.dsp.zones"

T.test("A-4 is 440 Hz and C-4 is middle C", function()
  T.near(Z.note_freq(57), 440, 1e-9)
  T.near(Z.note_freq(48), 261.6256, 1e-3)
end)

T.test("tuning hits every shift within half a cent", function()
  local n0 = Z.natural_note(2048, 44100)
  for semis = -60, 60 do
    for _, cents in ipairs({ -100, -51, -7, 0, 7, 49, 100 }) do
      local shift = semis + cents / 100
      local base, tr, fine = Z.tuning(n0, shift)
      T.ok(base >= 0 and base <= 119, "base_note range")
      T.ok(tr >= -120 and tr <= 120, "transpose range")
      T.ok(fine >= -127 and fine <= 127, "fine range")
      local got = Z.sounding_shift(n0, base, tr, fine)
      T.near(got, shift, 0.005, string.format("shift %.2f", shift))
    end
  end
end)

T.test("zones cover every key exactly once", function()
  for _, octaves in ipairs({ 1, 2, 3 }) do
    local zones = Z.plan(0, 0, octaves)
    local covered = {}
    for _, z in ipairs(zones) do
      for n = z.lo, z.hi do
        T.eq(covered[n], nil, "overlap at " .. n)
        covered[n] = true
      end
    end
    for n = 0, 119 do T.ok(covered[n], "gap at " .. n) end
  end
end)

T.test("zone count doesn't depend on the oscillator offset", function()
  local count = #Z.plan(0, 0, 1)
  for shift = -48, 48, 7 do
    T.eq(#Z.plan(shift, 0, 1), count)
  end
end)

T.test("harmonics stay below the limit at the top of each zone", function()
  for _, shift in ipairs({ -24, 0, 7.5, 24 }) do
    for _, z in ipairs(Z.plan(shift, 2, 1, 2048)) do
      local top = Z.note_freq(z.hi + shift + 2)
      T.ok(z.harmonics == 1 or z.harmonics * top < Z.MAX_FREQ, "aliasing risk")
      T.ok(z.harmonics >= 1 and z.harmonics <= 1023)
    end
  end
end)

T.test("pitch headroom reduces harmonics", function()
  local a = Z.plan(0, 0, 1)[3].harmonics
  local b = Z.plan(0, 12, 1)[3].harmonics
  T.ok(b < a)
end)
