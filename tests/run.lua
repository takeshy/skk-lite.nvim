local source = debug.getinfo(1, "S").source:sub(2)
package.path = vim.fs.dirname(source) .. "/?.lua;" .. package.path

local failures = 0
local total = 0

local function test(name, callback)
  total = total + 1
  local ok, error_message = pcall(callback)
  if ok then
    print("ok - " .. name)
    return
  end
  failures = failures + 1
  print("not ok - " .. name)
  print(error_message)
end

require("engine_spec").run(test)
require("dictionary_spec").run(test)
require("store_spec").run(test)
require("compiler_spec").run(test)
require("session_spec").run(test)
require("init_spec").run(test)
require("ui_spec").run(test)
require("controller_spec").run(test)

print(("%d tests, %d failures"):format(total, failures))
if failures > 0 then
  vim.cmd("cquit " .. failures)
end
