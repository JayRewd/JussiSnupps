# JussiSnupps

A modular synth editor for Renoise 3.5 (Lua API 6.2). Add any number of
oscillators, AHDSR envelopes, LFOs and filters, connect them in a routing
matrix, and the tool builds a **native Renoise instrument**. The instrument
plays live and polyphonically, follows note-off, and uses Renoise's own
filters.

## [DOWNLOAD HERE](https://github.com/JayRewd/JussiSnupps/raw/main/dist/com.jussisnupps.JussiSnupps.xrnx)

## Install

Download the `.xrnx` file above and drag it onto the Renoise window.
Installing a newer version the same way replaces the old one.

To build it yourself, run `./scripts/build.sh`; it writes
`dist/com.jussisnupps.JussiSnupps.xrnx`. To develop on a machine with Renoise
installed, `./scripts/link.sh` symlinks the source folder into Renoise's Tools
folder instead (then use *Tools > Reload All Tools*).

## First run: API probe (please do this once)

The Renoise API docs leave a few points open, such as parameter names,
whether device operators can be set, and value units. The tool detects most
of this on its own. The probe records everything, so any mismatch can be
fixed:

1. Open a new, empty song.
2. Run *Tools > JussiSnupps > Run API Probe (for the developer)*.
3. Send the file it names: `probe_result.json` in the tool's folder.

The probe works on a temporary instrument and deletes it afterwards.

## Use

- *Tools > JussiSnupps > New Synth Instrument* (also in the Instrument Box
  right-click menu) creates the default patch. If the selected instrument is
  empty it is used, otherwise a new instrument is added after it.
- *Tools > JussiSnupps > Open Editor...* edits the selected synth instrument.
  Selecting another JussiSnupps instrument switches the editor to it.
- **Convert selected** turns any instrument into a synth. It asks first,
  because it replaces that instrument's samples and modulation sets.

The editor has two parts.

**Rack**, one tab per module type:

- **Oscillators:** wave (sine, triangle, saw, square, pulse, noise), pulse
  width, octave (-4..+4), note (-12..+12), cent (-100..+100), level, pan.
- **Envelopes (AHDSR):** attack, hold, decay, sustain, release.
- **LFOs:** shape (sine, saw, pulse, random), rate, phase, delay.
- **Filters:** all 22 Renoise filter types, plus cutoff, resonance, drive.
- **Global:** interpolation, oversampling, velocity to volume, mono/glide,
  zone size, gate release.

**Routing matrix:**

- **Audio routing:** oscillators × (filters + Direct). Each cell is a send
  level.
- **Modulation:** destinations (oscillator volume/pan/pitch, filter
  cutoff/reso/drive) × (envelopes + LFOs). Cells hold an amount in %, or
  semitones for pitch.

Drag a field up or down, or double-click it to type. `.` means no route.
Every change applies right away; a dragged change is one undo step.

### Default patch

- Three oscillators into one LP Moog filter: saw, saw +7 cents, and square
  one octave down.
- Env 1 moves the filter cutoff (+60 %).
- Env 2 controls the volume of all three oscillators.

## How it works

Each audio route (an oscillator into a filter, or Direct) becomes:

- **Samples:** band-limited single-cycle waveforms, one per octave zone, so
  high notes don't alias. Each is looped and tuned with base note, transpose
  and fine tune.
- **A modulation set:** holds that filter and every envelope and LFO that
  targets the route. Envelopes become AHDSR devices and LFOs become LFO
  devices. Amounts use Operand devices, because Renoise devices have no depth
  setting of their own. Identical sets are shared.

The patch is stored as JSON in the instrument's comments, between
`#JSNP-BEGIN` and `#JSNP-END`. It is saved with the song and with exported
`.xrni` instruments, so they stay editable. Comment lines outside that block
are yours and are kept.

## Limits

- Filters run side by side, never in series; each audio route goes through
  one filter.
- A filter shared by several oscillators runs as one copy per oscillator.
  Clean filters sound the same; drive, distortion, decimator and AM types
  differ a little from a single shared filter.
- No PWM: pulse width is baked into the samples. No FM or sync between
  oscillators, and no LFO-modulates-LFO.
- LFOs restart with every note.
- One partial-depth (below 100 %) volume envelope per oscillator. All pitch
  envelopes on an oscillator share one range.
- Each audio route plays one voice per note, so CPU and sample count grow with
  oscillators × routes.
- Rebuilds replace the generated samples and modulation sets. Hand edits to
  them, and macro mappings to their devices, are lost. The Renoise API can't
  create macro mappings.
- Amounts below 100 % assume Renoise applies device operators in order without
  clipping between devices. The probe and the checks below confirm this.

## Manual test checklist (in Renoise)

1. Install, then *Tools > Reload All Tools*. The menus appear and the
   scripting terminal shows no errors.
2. Run the API probe.
3. *New Synth Instrument*: the default patch plays, with filter sweep and amp
   envelope.
4. Change each oscillator's octave, note and cent, and check the pitch with a
   tuner.
5. Play C-0 to B-9 with a spectrum analyser on the master track. Look for
   aliasing and for jumps between zones.
6. Hold a note and turn every control. The sound changes, and the sample and
   modulation-set counts stay the same.
7. Add and remove oscillators, filters and routes, including Direct.
8. Modulation:
   - Env -> cutoff at +50 % and -50 %.
   - LFO -> pitch at 2 st.
   - LFO -> pan with a negative amount.
   - Compare each with the Modulation tab.
9. Note-off: no click without a volume envelope (gate); a long release keeps
   its tail.
10. Save, close and reopen the song: still editable. Export the `.xrni` and
    load it into a new song: still editable.
11. Ctrl+Z after a rebuild and after a drag: the editor follows.
12. Stress test with 8 oscillators × 4 filters: warnings appear, and the
    status line shows the build time.

## Development

```bash
./scripts/test.sh          # offline tests (LuaJIT, mocked Renoise API)
./scripts/test.sh compiler # only tests whose name contains "compiler"
./scripts/build.sh         # syntax check + zip into dist/
```

The download link serves the `.xrnx` committed in `dist/`, so run
`./scripts/build.sh` and commit the rebuilt file with every release.

`vendor/renoise-definitions` (a git clone of
https://github.com/renoise/definitions) gives lua-language-server the
Renoise API types; `.luarc.json` points at it.

```
src/com.jussisnupps.JussiSnupps.xrnx/
  main.lua                  menus, keybinding, song events
  jsnp/util/json.lua        canonical JSON
  jsnp/model/patch.lua      modules, routes, defaults, validation   (pure)
  jsnp/model/serialize.lua  patch <-> instrument comment lines       (pure)
  jsnp/dsp/wavegen.lua      band-limited waveforms, noise            (pure)
  jsnp/dsp/zones.lua        key zones and tuning                     (pure)
  jsnp/compile/units.lua    ms/Hz parsing, calibration tables        (pure)
  jsnp/compile/compiler.lua patch -> instrument spec                 (pure)
  jsnp/rn/caps.lua          what this Renoise allows
  jsnp/rn/devices.lua       device parameters in real units
  jsnp/rn/applier.lua       spec -> Renoise (rebuild / update / adopt)
  jsnp/rn/ownership.lua     find synth instruments by patch uid
  jsnp/controller.lua       edits -> compile -> apply, undo, song events
  jsnp/ui/*.lua             editor window, rack, routing matrix
  jsnp/probe.lua            API probe
tests/                      mock_renoise.lua + test_*.lua
```
