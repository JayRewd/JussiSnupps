-- Key zones and tuning for oscillator samples.
--
-- Note numbers follow Renoise: 0 = C-0, 48 = C-4, 57 = A-4 (440 Hz).
-- Zones are fixed ranges of *played* notes (one octave each by default),
-- so changing an oscillator's octave/note/cent never changes the number of
-- samples, only their tuning and harmonic content.

local Zones = {}

Zones.A4 = 57
Zones.MAX_NOTE = 119
Zones.MAX_FREQ = 19000
Zones.FINE_PER_SEMI = 128

local LOG2 = math.log(2)

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function round(x)
  return math.floor(x + 0.5)
end

function Zones.note_freq(n)
  return 440 * 2 ^ ((n - Zones.A4) / 12)
end

-- The note a sample plays at its original speed: one cycle of `frames`
-- frames at `rate` Hz.
function Zones.natural_note(frames, rate)
  return Zones.A4 + 12 * math.log(rate / frames / 440) / LOG2
end

-- Renoise plays a sample at:
--   played_note - base_note + transpose + fine_tune / FINE_PER_SEMI
-- semitones above its natural pitch n0. To sound `shift` semitones above
-- the played note we need transpose + fine/FPS = shift + base - n0.
function Zones.tuning(n0, shift, fine_per_semi)
  local fps = fine_per_semi or Zones.FINE_PER_SEMI
  local base = clamp(round(n0 - shift), 0, Zones.MAX_NOTE)
  local x = shift + base - n0
  local transpose = clamp(round(x), -120, 120)
  local fine = clamp(round((x - transpose) * fps), -127, 127)
  return base, transpose, fine
end

-- Resulting pitch offset (semitones above the played note) of a tuning.
function Zones.sounding_shift(n0, base, transpose, fine, fine_per_semi)
  local fps = fine_per_semi or Zones.FINE_PER_SEMI
  return n0 - base + transpose + fine / fps
end

-- Zone plan for one oscillator.
--   shift:     octave/note/cent offset in semitones
--   headroom:  extra semitones of upward pitch modulation to allow for
--   octaves:   zone width in octaves (1..3)
-- Returns { {lo, hi, harmonics}, ... } covering notes 0..119.
function Zones.plan(shift, headroom, octaves, frames, max_freq)
  frames = frames or 2048
  max_freq = max_freq or Zones.MAX_FREQ
  local width = 12 * (octaves or 1)
  local max_h = frames / 2 - 1
  local zones = {}
  local lo = 0
  while lo <= Zones.MAX_NOTE do
    local hi = math.min(Zones.MAX_NOTE, lo + width - 1)
    -- one semitone of margin above the zone's top note
    local top = hi + 1 + shift + (headroom or 0)
    local h = math.floor(max_freq / Zones.note_freq(top))
    zones[#zones + 1] = { lo = lo, hi = hi, harmonics = clamp(h, 1, max_h) }
    lo = hi + 1
  end
  return zones
end

return Zones
