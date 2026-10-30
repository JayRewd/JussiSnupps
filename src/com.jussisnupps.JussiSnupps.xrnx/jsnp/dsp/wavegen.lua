-- Band-limited single-cycle waveforms, built by adding sine harmonics, plus
-- white noise. Each oscillator zone gets only the harmonics that stay below
-- ~19 kHz at the top of its key range, so high notes don't alias.

local Wavegen = {}

Wavegen.FRAMES = 2048
Wavegen.SAMPLE_RATE = 44100
Wavegen.NOISE_FRAMES = 44100 * 3
Wavegen.PEAK = 0.9

local PI = math.pi

local sin_tables = {}

local function sin_table(n)
  local t = sin_tables[n]
  if not t then
    t = {}
    for j = 0, n - 1 do
      t[j] = math.sin(2 * PI * j / n)
    end
    sin_tables[n] = t
  end
  return t
end

-- Fourier coefficients of harmonic k: returns (sin_coeff, cos_coeff).
local function coeffs(wave, pw, k)
  if wave == "sine" then
    return (k == 1) and 1 or 0, 0
  elseif wave == "saw" then
    return 2 / (PI * k), 0
  elseif wave == "triangle" then
    if k % 2 == 0 then return 0, 0 end
    local sign = (((k - 1) / 2) % 2 == 0) and 1 or -1
    return sign * 8 / (PI * PI * k * k), 0
  elseif wave == "square" or wave == "pulse" then
    -- bipolar pulse, high for the first `d` of the cycle, DC removed
    local d = (wave == "square") and 0.5 or pw
    local x = 2 * PI * k * d
    return 2 / (PI * k) * (1 - math.cos(x)), 2 / (PI * k) * math.sin(x)
  end
  error("unknown waveform " .. tostring(wave))
end

-- Renders one cycle of `n` frames with harmonics 1..H. Not normalised.
function Wavegen.render_cycle(wave, pw, harmonics, n)
  n = n or Wavegen.FRAMES
  local out = {}
  for i = 1, n do out[i] = 0 end
  local H = math.max(1, math.min(harmonics, n / 2 - 1))
  if wave == "sine" then H = 1 end
  local st = sin_table(n)
  local quarter = n / 4
  for k = 1, H do
    local a, b = coeffs(wave, pw, k)
    if math.abs(a) > 1e-12 or math.abs(b) > 1e-12 then
      local idx = 0
      for i = 1, n do
        out[i] = out[i] + a * st[idx] + b * st[(idx + quarter) % n]
        idx = idx + k
        if idx >= n then idx = idx % n end
      end
    end
  end
  return out
end

local function peak_of(data)
  local p = 0
  for i = 1, #data do
    local a = math.abs(data[i])
    if a > p then p = a end
  end
  return p
end
Wavegen.peak_of = peak_of

-- One gain per (wave, pulse width), measured on a rich version of the
-- wave, so loudness stays the same across all zones of an oscillator.
local gain_cache = {}

function Wavegen.gain(wave, pw)
  local key = wave .. "|" .. string.format("%.3f", pw or 0.5)
  local g = gain_cache[key]
  if not g then
    local ref = Wavegen.render_cycle(wave, pw, 256, Wavegen.FRAMES)
    local p = peak_of(ref)
    g = (p > 0) and (Wavegen.PEAK / p) or 1
    gain_cache[key] = g
  end
  return g
end

-- Park-Miller generator: deterministic noise without the `bit` library.
function Wavegen.render_noise(n, seed)
  n = n or Wavegen.NOISE_FRAMES
  local x = seed or 22222
  local out = {}
  for i = 1, n do
    x = (16807 * x) % 2147483647
    out[i] = ((x / 2147483647) * 2 - 1) * 0.7
  end
  return out
end

-- Rendered sample data, cached by render key (see compiler).
local cache = {}
local cache_count = 0

function Wavegen.render(spec)
  local key = spec.render_key
  local data = cache[key]
  if data then return data end
  if spec.wave == "noise" then
    data = Wavegen.render_noise(spec.frames)
  else
    data = Wavegen.render_cycle(spec.wave, spec.pw, spec.harmonics, spec.frames)
    local g = Wavegen.gain(spec.wave, spec.pw)
    for i = 1, #data do data[i] = data[i] * g end
  end
  if cache_count > 400 then
    cache, cache_count = {}, 0
  end
  cache[key] = data
  cache_count = cache_count + 1
  return data
end

function Wavegen.clear_cache()
  cache, cache_count = {}, 0
end

return Wavegen
