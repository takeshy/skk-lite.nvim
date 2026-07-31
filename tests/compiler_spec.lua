local compiler = require("skk_lite.compiler")

local M = {}

local function equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error((message or "values differ") .. ("\nexpected: %s\nactual:   %s"):format(vim.inspect(expected), vim.inspect(actual)))
  end
end

local function read_json(path)
  local file = assert(io.open(path, "rb"))
  local decoded = vim.json.decode(file:read("*a"))
  file:close()
  return decoded
end

function M.run(test)
  test("compiler merges SKK dictionaries and keeps annotations", function()
    local directory = vim.fn.tempname()
    vim.fn.mkdir(directory, "p")
    vim.fn.writefile({
      ";; okuri-ari entries.",
      "おくr /送/贈;annotation/",
      ";; okuri-nasi entries.",
      "かんじ /漢字/感じ/",
    }, directory .. "/SKK-JISYO.L")
    vim.fn.writefile({
      "かんじ /漢字;duplicate annotation/幹事/",
      "とうきょう /東京/",
    }, directory .. "/SKK-JISYO.extra")

    local result = compiler.compile({ directory = directory, encoding = "utf-8" })
    local dictionary = read_json(result.output_path)
    equal(result.keys, 3)
    equal(dictionary["かんじ"], { "漢字", "感じ", "幹事" })
    equal(dictionary["おくr"], { "送", "贈;annotation" })
    equal(dictionary["とうきょう"], { "東京" })
    vim.fn.delete(directory, "rf")
  end)

  test("compiler converts EUC-JP dictionaries", function()
    local directory = vim.fn.tempname()
    vim.fn.mkdir(directory, "p")
    local source = "かな /仮名/かな/\n"
    local encoded = vim.fn.iconv(source, "utf-8", "euc-jp")
    local file = assert(io.open(directory .. "/SKK-JISYO.euc", "wb"))
    file:write(encoded)
    file:close()

    local result = compiler.compile({ directory = directory, encoding = "auto" })
    equal(read_json(result.output_path)["かな"], { "仮名", "かな" })
    vim.fn.delete(directory, "rf")
  end)
end

return M
