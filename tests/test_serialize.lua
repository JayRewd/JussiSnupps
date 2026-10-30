local json = require "jsnp.util.json"
local Patch = require "jsnp.model.patch"
local S = require "jsnp.model.serialize"

T.test("patch round trip through comment lines", function()
  local p = Patch.new_default()
  p.oscs[1].name = "Big | Saw \"one\""
  local lines = S.to_lines(p, {})
  for _, l in ipairs(lines) do T.ok(#l <= 200, "line too long") end
  local q = assert(S.from_lines(lines))
  T.eq(json.encode(q), json.encode(p))
end)

T.test("user comment lines are kept", function()
  local p = Patch.new_default()
  local lines = S.to_lines(p, { "my notes", "second line" })
  T.eq(lines[1], "my notes")
  T.eq(lines[2], "second line")
  local again = S.to_lines(p, lines)
  T.eq(#again, #lines)
  T.eq(again[1], "my notes")
end)

T.test("header gives the uid", function()
  local p = Patch.new_default()
  local h = S.read_header(S.to_lines(p, {}))
  T.eq(h.uid, p.uid)
  T.eq(h.v, 1)
end)

T.test("damaged blocks are reported, not crashed on", function()
  local p = Patch.new_default()
  local lines = S.to_lines(p, {})
  local cut = { lines[1], lines[2] }
  local q, err = S.from_lines(cut)
  T.eq(q, nil)
  T.ok(err:find("incomplete"))
  local broken = { lines[1], "|{\"v\":1,|", S.END }
  q, err = S.from_lines(broken)
  T.eq(q, nil)
  T.ok(err:find("corrupt"))
  q, err = S.from_lines({ "hello" })
  T.eq(q, nil)
end)

T.test("patches from newer versions are refused", function()
  local lines = { S.BEGIN .. " v=99 uid=abc", '|{"v":99}|', S.END }
  local q, err = S.from_lines(lines)
  T.eq(q, nil)
  T.ok(err:find("newer"))
end)
