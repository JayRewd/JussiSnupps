-- Which instruments belong to JussiSnupps: the ones whose comments hold a
-- patch block. Instruments have no stable id in Renoise, so the patch's
-- uid is used to find the bound instrument again after inserts/deletes.

local Serialize = require "jsnp.model.serialize"

local Ownership = {}

function Ownership.uid_of(instr)
  local ok, lines = pcall(function() return instr.comments end)
  if not ok then return nil end
  local h = Serialize.read_header(lines)
  return h and h.uid or nil
end

-- index, instrument of the instrument holding patch `uid`
function Ownership.find(song, uid)
  if not uid then return nil end
  for i, instr in ipairs(song.instruments) do
    if Ownership.uid_of(instr) == uid then
      return i, instr
    end
  end
  return nil
end

function Ownership.read(instr, filter_types)
  return Serialize.from_lines(instr.comments, filter_types)
end

function Ownership.write(instr, patch)
  instr.comments = Serialize.to_lines(patch, instr.comments)
end

-- An instrument nobody has used yet (safe to take over without asking).
function Ownership.is_empty(instr)
  local ok, empty = pcall(function()
    if #instr.samples > 0 then return false end
    if #instr.phrases > 0 then return false end
    if instr.plugin_properties.plugin_loaded then return false end
    for _, line in ipairs(instr.comments) do
      if line:match("%S") then return false end
    end
    return true
  end)
  return ok and empty
end

return Ownership
