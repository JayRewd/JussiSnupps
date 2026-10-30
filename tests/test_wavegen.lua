local W = require "jsnp.dsp.wavegen"

-- magnitude of harmonic k in one cycle (plain DFT)
local function harmonic(data, k)
  local n = #data
  local re, im = 0, 0
  for i = 1, n do
    local ph = 2 * math.pi * k * (i - 1) / n
    re = re + data[i] * math.cos(ph)
    im = im + data[i] * math.sin(ph)
  end
  return 2 * math.sqrt(re * re + im * im) / n
end

local function mean(data)
  local s = 0
  for i = 1, #data do s = s + data[i] end
  return s / #data
end

for _, wave in ipairs({ "sine", "triangle", "saw", "square", "pulse" }) do
  T.test(wave .. ": no energy above the harmonic limit, no DC, peak <= 1", function()
    local spec = { wave = wave, pw = 0.25, harmonics = 20, frames = 2048,
                   render_key = wave .. "|test20" }
    local data = W.render(spec)
    T.eq(#data, 2048)
    T.near(mean(data), 0, 1e-9, "DC")
    T.ok(W.peak_of(data) <= 1.0001, "peak")
    for _, k in ipairs({ 21, 22, 40, 100 }) do
      T.near(harmonic(data, k), 0, 1e-9, "harmonic " .. k)
    end
    T.ok(harmonic(data, 1) > 0.1, "fundamental present")
  end)
end

T.test("square has only odd harmonics", function()
  local data = W.render_cycle("square", 0.5, 10, 512)
  T.near(harmonic(data, 2), 0, 1e-9)
  T.near(harmonic(data, 4), 0, 1e-9)
  T.near(harmonic(data, 3) / harmonic(data, 1), 1 / 3, 1e-6)
end)

T.test("pulse width changes the harmonic pattern", function()
  -- a 25% pulse has no 4th harmonic
  local data = W.render_cycle("pulse", 0.25, 10, 512)
  T.near(harmonic(data, 4), 0, 1e-9)
  T.ok(harmonic(data, 2) > 0.1)
end)

T.test("sine ignores the harmonic count", function()
  local data = W.render_cycle("sine", 0.5, 100, 256)
  T.near(harmonic(data, 1), 1, 1e-9)
  T.near(harmonic(data, 3), 0, 1e-9)
end)

T.test("the same gain is used for every zone of a wave", function()
  local rich = W.render({ wave = "saw", pw = 0.5, harmonics = 500, frames = 2048, render_key = "s500" })
  local thin = W.render({ wave = "saw", pw = 0.5, harmonics = 2, frames = 2048, render_key = "s2" })
  T.near(harmonic(rich, 1), harmonic(thin, 1), 1e-9)
end)

T.test("noise is deterministic and bounded", function()
  local a = W.render_noise(1000)
  local b = W.render_noise(1000)
  for i = 1, 1000 do
    T.eq(a[i], b[i])
    T.ok(math.abs(a[i]) <= 0.7)
  end
  T.near(mean(a), 0, 0.05)
end)
