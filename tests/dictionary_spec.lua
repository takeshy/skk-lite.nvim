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
    ["おおk"] = { "多", "大" },
  }))
  file:close()

  local data = {
    user_dict = { ["かんじ"] = { "幹事" }, ["かんじる"] = { "感じる" } },
    history = { ["かんじ"] = { "漢字" }, ["おおk"] = { "大" } },
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

  test("okuri history ignores legacy ordering and separates cached endings", function()
    equal(dictionary.lookup("おおk", "く"), { "多", "大" })
    equal(dictionary.lookup("おおk", "き"), { "多", "大" })
    dictionary.remember("おおk", "大", "き")
    dictionary.remember("おおk", "多", "く")
    equal(dictionary.lookup_any({ { key = "おおk" } }, "き"), { "大", "多" })
    equal(dictionary.lookup_any({ { key = "おおk" } }, "く"), { "多", "大" })
    equal(data.history["おおk*き"], { "大" })
    equal(data.history["おおk*く"], { "多" })
    equal(data.history["おおk"], { "大" })
  end)

  test("registration invalidates cached candidates for every ending", function()
    dictionary.register("おおk", "仮;注釈")
    equal(dictionary.lookup("おおk", "き"), { "大", "仮;注釈", "多" })
    equal(dictionary.lookup("おおk", "く"), { "多", "仮;注釈", "大" })
    dictionary.remember("おおk", "仮;注釈", "き")
    dictionary.remember("おおk", "仮;注釈", "く")
  end)

  test("purge removes matching history and shared user entry only", function()
    dictionary.lookup("おおk", "き")
    dictionary.lookup("おおk", "く")
    dictionary.purge("おおk", "仮", "き")
    equal(data.user_dict["おおk"], nil)
    equal(data.history["おおk*き"], { "大" })
    equal(data.history["おおk*く"], { "仮;注釈", "多" })
    equal(data.history["おおk"], { "大" })
    equal(dictionary.lookup("おおk", "き"), { "大", "多" })
    equal(dictionary.lookup("おおk", "く"), { "仮;注釈", "多", "大" })
  end)

  test("session conversion learns and purges using actual okurigana", function()
    data.user_dict["おおk"] = nil
    data.history["おおk*き"] = nil
    data.history["おおk*く"] = nil
    dictionary.setup({ path = path, store = store })
    local session = require("skk_lite.session").new(dictionary)
    session:handle("j", { ctrl = true })
    local function type_text(text)
      for character in text:gmatch(".") do
        session:handle(character)
      end
    end
    type_text("OoKi")
    equal(session:candidate_text(), "多き")
    session:handle(" ")
    equal(session:candidate_text(), "大き")
    equal(session:handle("Enter").insert, "大き")
    type_text("OoKu")
    equal(session:candidate_text(), "多く")
    equal(session:handle("Enter").insert, "多く")
    equal(data.history["おおk*き"], { "大" })
    equal(data.history["おおk*く"], { "多" })
    type_text("OoKi")
    equal(session:candidate_text(), "大き")
    session:handle("X")
    equal(data.history["おおk*き"], nil)
    equal(data.history["おおk*く"], { "多" })
  end)

  os.remove(path)
end

return M
