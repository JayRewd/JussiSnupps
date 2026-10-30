-- Offline test runner: luajit tests/run.lua [name-filter]
package.path = "src/com.jussisnupps.JussiSnupps.xrnx/?.lua;tests/?.lua;" .. package.path

local T = { passed = 0, failed = 0, failures = {} }

local current_file = ""

function T.test(name, fn)
  local filter = arg and arg[1]
  local full = current_file .. ": " .. name
  if filter and not full:find(filter, 1, true) then return end
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    T.passed = T.passed + 1
  else
    T.failed = T.failed + 1
    T.failures[#T.failures + 1] = full .. "\n" .. tostring(err)
  end
end

function T.eq(a, b, msg)
  if a ~= b then
    error((msg and (msg .. ": ") or "") .. "expected " .. tostring(b) .. ", got " .. tostring(a), 2)
  end
end

function T.near(a, b, tol, msg)
  if type(a) ~= "number" or math.abs(a - b) > tol then
    error((msg and (msg .. ": ") or "") .. string.format("expected %s +- %s, got %s",
      tostring(b), tostring(tol), tostring(a)), 2)
  end
end

function T.ok(v, msg)
  if not v then error(msg or "expected a true value", 2) end
  return v
end

function T.raises(fn, pattern)
  local ok, err = pcall(fn)
  if ok then error("expected an error", 2) end
  if pattern and not tostring(err):find(pattern) then
    error("error '" .. tostring(err) .. "' doesn't match '" .. pattern .. "'", 2)
  end
end

-- Forget loaded tool modules so each file starts clean.
function T.fresh()
  for k in pairs(package.loaded) do
    if k:match("^jsnp") or k == "main" then package.loaded[k] = nil end
  end
end

_G.T = T

local FILES = {
  "test_json", "test_patch", "test_serialize", "test_wavegen", "test_zones",
  "test_units", "test_compiler", "test_purity", "test_applier", "test_tool",
}

for _, f in ipairs(FILES) do
  current_file = f
  T.fresh()
  _G.renoise = nil
  local ok, err = xpcall(function() dofile("tests/" .. f .. ".lua") end, debug.traceback)
  if not ok then
    T.failed = T.failed + 1
    T.failures[#T.failures + 1] = f .. " (loading)\n" .. tostring(err)
  end
end

for _, msg in ipairs(T.failures) do
  print("FAIL " .. msg)
  print()
end
print(string.format("%d passed, %d failed", T.passed, T.failed))
os.exit(T.failed == 0 and 0 or 1)
