local U = require "jsnp.compile.units"

T.test("parse Renoise value strings", function()
  T.eq(U.parse_ms("250 ms"), 250)
  T.eq(U.parse_ms("1.50 s"), 1500)
  T.eq(U.parse_ms("1,5 s"), 1500)
  T.eq(U.parse_ms("250"), nil)
  T.eq(U.parse_ms("250", true), 250)
  T.eq(U.parse_ms("1/4"), nil)
  T.eq(U.parse_hz("4.00 Hz"), 4)
  T.eq(U.parse_hz("1.2 kHz"), 1200)
  T.eq(U.parse_hz("abc"), nil)
end)

T.test("UI curves invert", function()
  for _, ms in ipairs({ 0, 1, 5, 250, 1000, 20000 }) do
    T.near(U.ui_to_ms(U.ms_to_ui(ms)), ms, 1e-6)
  end
  for _, hz in ipairs({ 0.01, 0.5, 4, 40 }) do
    T.near(U.ui_to_hz(U.hz_to_ui(hz)), hz, 1e-9)
  end
end)

T.test("calibration tables invert monotonic curves", function()
  local pts = {}
  for i = 0, 64 do
    local v = i / 64
    pts[#pts + 1] = { v = v, u = 1 + 9999 * v ^ 2.5 }
  end
  local t = assert(U.make_table(pts))
  for _, ms in ipairs({ 1, 10, 250, 1000, 5000, 10000 }) do
    local v = U.invert(t, ms)
    T.near(1 + 9999 * v ^ 2.5, ms, ms * 0.02 + 0.5, "ms " .. ms)
  end
  T.eq(U.invert(t, 0), 0)
  T.eq(U.invert(t, 1e9), 1)
end)

T.test("unusable calibration data is rejected", function()
  T.eq(U.make_table({ { v = 0, u = 1 }, { v = 1, u = 2 } }), nil)
  local falling = {}
  for i = 0, 10 do falling[#falling + 1] = { v = i, u = 10 - i } end
  T.eq(U.make_table(falling), nil)
  local unparsed = {}
  for i = 0, 10 do unparsed[#unparsed + 1] = { v = i, u = nil } end
  T.eq(U.make_table(unparsed), nil)
end)
