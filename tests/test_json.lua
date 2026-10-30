local json = require "jsnp.util.json"

T.test("round trip of nested data", function()
  local v = { a = 1, b = { 1, 2, 3 }, c = "x\"y\\z\n", d = true, e = { f = 0.45 } }
  local back = json.decode(json.encode(v))
  T.eq(back.a, 1)
  T.eq(#back.b, 3)
  T.eq(back.c, "x\"y\\z\n")
  T.eq(back.d, true)
  T.eq(back.e.f, 0.45)
end)

T.test("keys are sorted, so encoding is canonical", function()
  T.eq(json.encode({ b = 1, a = 2, c = { z = 1, y = 2 } }), '{"a":2,"b":1,"c":{"y":2,"z":1}}')
end)

T.test("numbers use the shortest exact form", function()
  T.eq(json.encode(0.45), "0.45")
  T.eq(json.encode(-3), "-3")
  T.eq(json.encode(1 / 3), string.format("%.17g", 1 / 3))
  T.eq(json.decode(json.encode(1 / 3)), 1 / 3)
end)

T.test("empty tables encode as arrays", function()
  T.eq(json.encode({ list = {} }), '{"list":[]}')
end)

T.test("unicode escapes decode to UTF-8", function()
  T.eq(json.decode('"\\u00e9"'), "\195\169")
end)

T.test("bad input raises errors", function()
  T.raises(function() json.decode('{"a":') end)
  T.raises(function() json.decode('[1,2') end)
  T.raises(function() json.decode('{"a":1} x') end, "trailing")
  T.raises(function() json.decode('"abc') end, "unterminated")
end)
