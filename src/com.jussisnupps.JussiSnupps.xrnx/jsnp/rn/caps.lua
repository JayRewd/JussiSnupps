-- Finds out, once per session, what this Renoise version allows: device
-- paths, filter types, and whether device operators can be set (the API
-- docs mark `operator` read-only, which the amount recipes depend on).
-- Works on a temporary modulation set that is removed again.

local Patch = require "jsnp.model.patch"

local Caps = {}

local cached = nil

-- substring of the lower-case device path -> device kind
local MATCH = {
  { "ahdsr", "ahdsr" }, { "lfo", "lfo" }, { "operand", "operand" },
  { "envelope", "envelope" }, { "velocity", "velocity" }, { "key", "keytracking" },
  { "fader", "fader" }, { "stepper", "stepper" },
}

function Caps.detect(instr)
  if cached then return cached end
  local caps = {
    operator_writable = false,
    filter_writable = false,
    fine_per_semi = 128,
    max_samples = 255,
    device_paths = {},
    filter_types = nil,
  }
  local index = #instr.sample_modulation_sets + 1
  local inserted = false
  local ok, err = pcall(function()
    local set = instr:insert_sample_modulation_set_at(index)
    inserted = true
    pcall(function()
      if set.filter_version < 3 then set:upgrade_filter_version() end
    end)
    local types = {}
    for i, t in ipairs(set.available_filter_types) do types[i] = t end
    caps.filter_types = types

    for _, path in ipairs(set.available_devices) do
      local l = path:lower()
      for _, m in ipairs(MATCH) do
        if l:find(m[1], 1, true) then
          caps.device_paths[m[2]] = caps.device_paths[m[2]] or path
          break
        end
      end
    end

    caps.filter_writable = pcall(function() set.filter_type = "LP Moog" end)
      and set.filter_type == "LP Moog"

    if caps.device_paths.ahdsr then
      local SMD = renoise.SampleModulationDevice
      local dev = set:insert_device_at(caps.device_paths.ahdsr, SMD.TARGET_CUTOFF, 1)
        or set.devices[1]
      local want = (dev.operator == SMD.OPERATOR_MUL) and SMD.OPERATOR_ADD or SMD.OPERATOR_MUL
      pcall(function() dev.operator = want end)
      caps.operator_writable = (dev.operator == want)
    end
  end)
  if inserted then
    pcall(function() instr:delete_sample_modulation_set_at(index) end)
  end
  if not ok then
    caps.error = tostring(err)
  end
  if not caps.filter_types or #caps.filter_types == 0 then
    caps.filter_types = Patch.FILTER_TYPES
  end
  cached = caps
  return caps
end

function Caps.reset()
  cached = nil
end

-- Problems worth showing the user.
function Caps.notes(caps)
  local out = {}
  if caps.error then
    out[#out + 1] = "Capability check failed: " .. caps.error
  end
  if not caps.device_paths.ahdsr then
    out[#out + 1] = "Renoise offers no AHDSR modulation device; envelopes won't work"
  end
  if not caps.device_paths.lfo then
    out[#out + 1] = "Renoise offers no LFO modulation device; LFOs won't work"
  end
  if not caps.operator_writable then
    out[#out + 1] = "This Renoise doesn't let tools set device operators, so "
      .. "modulation amounts other than 100% are approximated"
  end
  if not caps.filter_writable then
    out[#out + 1] = "Couldn't set a filter type in a test; filters may stay at None"
  end
  return out
end

return Caps
