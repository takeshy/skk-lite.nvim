local dictionary = require("skk_lite.dictionary")

local M = {}

local function equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error((message or "values differ") .. ("\nexpected: %s\nactual:   %s"):format(vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run(test)
  local path = vim.fn.tempname() .. ".json"
  local file = assert(io.open(path, "wb"))
  file:write(vim.json.encode({
    ["かんじ"] = { "感じ", "漢字", "注目;注釈" },
    ["だい#かい"] = { "第#1回", "第#3回" },
  }))
  file:close()

  local data = {
    user_dict = { ["かんじ"] = { "幹事" }, ["かんじる"] = { "感じる" } },
    history = { ["かんじ"] = { "漢字" } },
  }
  local saves = 0
  local store = {
    data = function()
      return data
    end,
    save = function()
      saves = saves + 1
      return true
    end,
  }

  dictionary.setup({ path = path, store = store })

  test("lookup merges history user and base without duplicate words", function()
    equal(dictionary.lookup("かんじ"), { "漢字", "幹事", "感じ", "注目;注釈" })
  end)

  test("mutating lookup results does not poison the cache", function()
    local candidates = dictionary.lookup("かんじ")
    candidates[1] = "破損"
    equal(dictionary.lookup("かんじ"), { "漢字", "幹事", "感じ", "注目;注釈" })
  end)

  test("numeric lookup applies dictionary placeholders", function()
    equal(dictionary.lookup_any({ { key = "だい#かい", numbers = { "5" } } }), { "第５回", "第五回" })
  end)

  test("remember changes candidate priority", function()
    dictionary.remember("かんじ", "感じ")
    equal(dictionary.lookup("かんじ")[1], "感じ")
    equal(saves, 1)
  end)

  test("register and purge update user dictionary", function()
    dictionary.register("かんじ", "完事")
    equal(data.user_dict["かんじ"][1], "完事")
    dictionary.purge("かんじ", "完事")
    equal(vim.tbl_contains(data.user_dict["かんじ"], "完事"), false)
  end)

  test("completion uses learned dictionary keys", function()
    equal(dictionary.completions("かんじ"), { "かんじる" })
  end)

  os.remove(path)
end

return M
