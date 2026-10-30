-- Minimal JSON encoder/decoder.
-- The encoder is canonical: object keys are sorted and numbers use the
-- shortest exact form, so equal tables always encode to equal strings
-- (the compiler relies on this to compare and dedupe specs).

local json = {}

local ESCAPES = {
  ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
  ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function encode_string(s)
  local out = s:gsub('[%c"\\]', function(c)
    return ESCAPES[c] or string.format("\\u%04x", c:byte())
  end)
  return '"' .. out .. '"'
end

local function encode_number(n)
  if n ~= n or n == math.huge or n == -math.huge then
    return "null"
  end
  if n == math.floor(n) and math.abs(n) < 2 ^ 53 then
    return string.format("%d", n)
  end
  local s = string.format("%.15g", n)
  if tonumber(s) ~= n then
    s = string.format("%.17g", n)
  end
  return s
end

-- A table is an array when its keys are exactly 1..#t. Empty tables encode
-- as arrays, because every possibly-empty table in a patch is a list.
local function is_array(t)
  local n = #t
  local count = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or k > n or k ~= math.floor(k) then
      return false
    end
    count = count + 1
  end
  return count == n
end

local encode_value

local function encode_table(t, stack)
  if stack[t] then
    error("json: cannot encode a table that contains itself")
  end
  stack[t] = true
  local parts = {}
  local out
  if is_array(t) then
    for i = 1, #t do
      parts[i] = encode_value(t[i], stack)
    end
    out = "[" .. table.concat(parts, ",") .. "]"
  else
    local keys = {}
    for k in pairs(t) do
      if type(k) ~= "string" then
        error("json: object keys must be strings, got " .. type(k))
      end
      keys[#keys + 1] = k
    end
    table.sort(keys)
    for i, k in ipairs(keys) do
      parts[i] = encode_string(k) .. ":" .. encode_value(t[k], stack)
    end
    out = "{" .. table.concat(parts, ",") .. "}"
  end
  stack[t] = nil
  return out
end

encode_value = function(v, stack)
  local tv = type(v)
  if tv == "nil" then
    return "null"
  elseif tv == "boolean" then
    return v and "true" or "false"
  elseif tv == "number" then
    return encode_number(v)
  elseif tv == "string" then
    return encode_string(v)
  elseif tv == "table" then
    return encode_table(v, stack)
  end
  error("json: cannot encode a " .. tv)
end

function json.encode(v)
  return encode_value(v, {})
end

local function utf8_char(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
  end
  return string.char(0xE0 + math.floor(cp / 4096),
    0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

local UNESCAPE = {
  ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f',
  n = '\n', r = '\r', t = '\t',
}

function json.decode(str)
  if type(str) ~= "string" then
    error("json: expected a string")
  end
  local pos = 1

  local function fail(msg)
    error(string.format("json: %s at position %d", msg, pos), 0)
  end

  local function skip_ws()
    pos = str:find("[^ \t\r\n]", pos) or (#str + 1)
  end

  local parse_value

  local function parse_string()
    local buf = {}
    local i = pos + 1
    while true do
      local c = str:sub(i, i)
      if c == "" then
        pos = i
        fail("unterminated string")
      elseif c == '"' then
        pos = i + 1
        return table.concat(buf)
      elseif c == "\\" then
        local e = str:sub(i + 1, i + 1)
        if UNESCAPE[e] then
          buf[#buf + 1] = UNESCAPE[e]
          i = i + 2
        elseif e == "u" then
          local cp = tonumber(str:sub(i + 2, i + 5), 16)
          if not cp then
            pos = i
            fail("bad \\u escape")
          end
          buf[#buf + 1] = utf8_char(cp)
          i = i + 6
        else
          pos = i
          fail("bad escape")
        end
      else
        local j = str:find('["\\]', i) or (#str + 1)
        buf[#buf + 1] = str:sub(i, j - 1)
        i = j
      end
    end
  end

  local function parse_number()
    local s, e = str:find("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
    if not s then
      fail("bad number")
    end
    local n = tonumber(str:sub(s, e))
    if not n then
      fail("bad number")
    end
    pos = e + 1
    return n
  end

  local function parse_array()
    local arr = {}
    pos = pos + 1
    skip_ws()
    if str:sub(pos, pos) == "]" then
      pos = pos + 1
      return arr
    end
    while true do
      arr[#arr + 1] = parse_value()
      skip_ws()
      local c = str:sub(pos, pos)
      pos = pos + 1
      if c == "]" then
        return arr
      elseif c ~= "," then
        pos = pos - 1
        fail("expected ',' or ']'")
      end
    end
  end

  local function parse_object()
    local obj = {}
    pos = pos + 1
    skip_ws()
    if str:sub(pos, pos) == "}" then
      pos = pos + 1
      return obj
    end
    while true do
      skip_ws()
      if str:sub(pos, pos) ~= '"' then
        fail("expected a string key")
      end
      local key = parse_string()
      skip_ws()
      if str:sub(pos, pos) ~= ":" then
        fail("expected ':'")
      end
      pos = pos + 1
      obj[key] = parse_value()
      skip_ws()
      local c = str:sub(pos, pos)
      pos = pos + 1
      if c == "}" then
        return obj
      elseif c ~= "," then
        pos = pos - 1
        fail("expected ',' or '}'")
      end
    end
  end

  parse_value = function()
    skip_ws()
    local c = str:sub(pos, pos)
    if c == "{" then
      return parse_object()
    elseif c == "[" then
      return parse_array()
    elseif c == '"' then
      return parse_string()
    elseif c == "-" or c:match("%d") then
      return parse_number()
    elseif str:sub(pos, pos + 3) == "true" then
      pos = pos + 4
      return true
    elseif str:sub(pos, pos + 4) == "false" then
      pos = pos + 5
      return false
    elseif str:sub(pos, pos + 3) == "null" then
      pos = pos + 4
      return nil
    end
    fail("unexpected character '" .. c .. "'")
  end

  local value = parse_value()
  skip_ws()
  if pos <= #str then
    fail("trailing characters")
  end
  return value
end

return json
