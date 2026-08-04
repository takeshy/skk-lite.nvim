local decoder = require("skk_lite.encoding.euc_jp")

local M = {}

local function equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error((message or "values differ") .. ("\nexpected: %s\nactual:   %s"):format(vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run(test)
  test("Pure Lua EUC-JP decoder handles ASCII and JIS X 0208", function()
    local encoded = string.char(
      0x77, 0x61, 0x74, 0x61, 0x73, 0x69, 0x20,
      0xa4, 0xef, 0xa4, 0xbf, 0xa4, 0xb7, 0x20, 0x2f,
      0xbb, 0xe4, 0x2f, 0xc5, 0xcf, 0xa4, 0xb7, 0x2f, 0x0a
    )
    equal(decoder.decode(encoded), "watasi わたし /私/渡し/\n")
  end)

  test("Pure Lua EUC-JP decoder handles half-width katakana", function()
    equal(decoder.decode(string.char(0x8e, 0xb6, 0x8e, 0xc0)), "ｶﾀ")
  end)

  test("Pure Lua EUC-JP decoder handles JIS X 0212", function()
    equal(decoder.decode(string.char(0x8f, 0xa2, 0xaf)), "˘")
  end)

  test("Pure Lua EUC-JP decoder rejects malformed input", function()
    local ok, error_message = pcall(decoder.decode, string.char(0xa4))
    equal(ok, false)
    assert(tostring(error_message):find("invalid JIS X 0208 sequence", 1, true))
  end)
end

return M
