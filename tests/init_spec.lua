local skk = require("skk_lite")

local M = {}

local function equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error((message or "values differ") .. ("\nexpected: %s\nactual:   %s"):format(vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run(test)
  test("command-line registration splices at the cursor", function()
    local line, position = skk._splice_commandline({ line = "abc", position = 1 }, "X")
    equal({ line, position }, { "Xabc", 2 })

    line, position = skk._splice_commandline({ line = "abc", position = 2 }, "XY")
    equal({ line, position }, { "aXYbc", 4 })

    line, position = skk._splice_commandline({ line = "abc", position = 4 }, "Z")
    equal({ line, position }, { "abcZ", 5 })
  end)

  test("command-line registration keeps byte cursor positions", function()
    local japanese = string.char(0xe3, 0x81, 0x82)
    local line, position = skk._splice_commandline({ line = "a" .. japanese .. "b", position = 5 }, "X")
    equal(line, "a" .. japanese .. "Xb")
    equal(position, 6)
  end)
end

return M
