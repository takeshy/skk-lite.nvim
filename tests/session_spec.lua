local Session = require("skk_lite.session")

local M = {}

local function equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error((message or "values differ") .. ("\nexpected: %s\nactual:   %s"):format(vim.inspect(expected), vim.inspect(actual)))
  end
end

local function fake_dictionary()
  local entries = {
    ["ちょう>"] = { "超" },
    [">てき"] = { "的" },
    ["はしr"] = { "走" },
    ["だい#かい"] = { "第#1回", "第#3回" },
    ["かんじ"] = { "感じ", "漢字" },
    ["おおい"] = { "多い", "多飯", "大井", "覆い", "オオイ", "凡い", "鸁い", "飫い", "都比", "邑伊", "于" },
    ["ちゅうもく"] = { "注目;ちゅうもく注釈" },
    MCP = { "Model Context Protocol" },
  }
  local history = {}
  local user = {}
  return {
    lookup_any = function(specs)
      local result = {}
      for _, spec in ipairs(specs) do
        for _, candidate in ipairs(entries[spec.key] or {}) do
          table.insert(result, spec.numbers and require("skk_lite.engine").apply_numeric_candidate(candidate, spec.numbers) or candidate)
        end
      end
      return result
    end,
    remember = function(key, candidate)
      history[key] = candidate
    end,
    register = function(key, candidate)
      user[key] = candidate
      entries[key] = { candidate }
      return true
    end,
    purge = function(key, candidate)
      local next_entries = {}
      for _, item in ipairs(entries[key] or {}) do
        if require("skk_lite.engine").candidate_word(item) ~= candidate then
          table.insert(next_entries, item)
        end
      end
      entries[key] = next_entries
      return true
    end,
    completions = function(prefix)
      if prefix == "かん" then
        return { "かんじ" }
      end
      return {}
    end,
    history = history,
    user = user,
  }
end

local function harness()
  local dictionary = fake_dictionary()
  local session = Session.new(dictionary)
  local output = ""
  local function press(key, modifiers)
    local result = session:handle(key, modifiers)
    output = output .. result.insert
    if not result.handled and #key == 1 and not (modifiers and (modifiers.ctrl or modifiers.alt or modifiers.meta)) then
      output = output .. key
    end
    return result
  end
  local function type_text(text)
    for character in text:gmatch(".") do
      press(character)
    end
  end
  press("j", { ctrl = true })
  return {
    session = session,
    dictionary = dictionary,
    press = press,
    type = type_text,
    output = function()
      return output
    end,
  }
end

function M.run(test)
  test("plain kana input works", function()
    local h = harness()
    h.type("aiu")
    equal(h.output(), "あいう")
  end)

  test("pending consonant is exposed as preedit", function()
    local h = harness()
    local result = h.press("k")
    equal(result.preedit, "k")
    result = h.press("a")
    equal(result.insert, "か")
    equal(result.preedit, "")
  end)

  test("backspace and escape remove pending roman", function()
    local backspace = harness()
    backspace.press("k")
    equal(backspace.press("Backspace").preedit, "")
    equal(backspace.output(), "")

    local escape = harness()
    escape.press("k")
    equal(escape.press("Escape").preedit, "")
    equal(escape.output(), "")
  end)

  test("pending n is flushed before ascii mode", function()
    local h = harness()
    local pending = h.press("n")
    equal(pending.insert, "")
    equal(pending.preedit, "n")
    h.press("l")
    equal(h.output(), "ん")
    equal(h.session.state.enabled, false)
  end)

  test("double n works before vowels and at end of input", function()
    local overlap = harness()
    overlap.type("nna")
    equal(overlap.output(), "んな")

    local terminal = harness()
    terminal.type("nn")
    equal(terminal.press("l").insert, "ん")
    equal(terminal.output(), "ん")
  end)

  test("konnichiha composes naturally", function()
    local h = harness()
    h.type("Konnichiha")
    h.press("Enter")
    equal(h.output(), "こんにちは")
  end)

  test("pending n is committed at native-key boundaries", function()
    local space = harness()
    space.press("n")
    local result = space.press(" ")
    equal(result.insert, "ん")
    equal(result.handled, false)
    equal(space.output(), "ん ")

    local digit = harness()
    digit.press("n")
    result = digit.press("1")
    equal(result.insert, "ん")
    equal(result.handled, false)
    equal(digit.output(), "ん1")
  end)

  test("pending n is committed before mode and composition keys", function()
    local katakana = harness()
    katakana.press("n")
    equal(katakana.press("q").insert, "ん")
    equal(katakana.session.state.katakana_mode, "zen")

    local sticky = harness()
    sticky.press("n")
    equal(sticky.press(";").insert, "ん")
    equal(sticky.session.state.composing, true)
    equal(sticky.session.state.roman, "")

    local abbrev = harness()
    abbrev.press("n")
    equal(abbrev.press("/").insert, "ん")
    equal(abbrev.session:is_abbrev(), true)
  end)

  test("composition commits a terminal n", function()
    local enter = harness()
    enter.type("Kan")
    equal(enter.press("Enter").insert, "かん")

    local ctrl_j = harness()
    ctrl_j.type("Kan")
    equal(ctrl_j.press("j", { ctrl = true }).insert, "かん")
  end)

  test("conversion commits and learns", function()
    local h = harness()
    h.type("Kanji")
    local result = h.press(" ")
    equal(result.preedit, "感じ")
    h.press("Enter")
    equal(h.output(), "感じ")
    equal(h.dictionary.history["かんじ"], "感じ")
  end)

  test("Ctrl-J commits a candidate and keeps SKK enabled", function()
    local h = harness()
    h.type("Kanji")
    h.press(" ")
    h.press("j", { ctrl = true })
    equal(h.output(), "感じ")
    equal(h.session.state.enabled, true)
  end)

  test("prefix and suffix conversions work", function()
    local prefix = harness()
    prefix.type("Chou")
    prefix.press(">")
    prefix.press("Enter")
    equal(prefix.output(), "超")

    local suffix = harness()
    suffix.type("Kanji")
    suffix.press(" ")
    suffix.press(">")
    suffix.type("teki")
    suffix.press(" ")
    suffix.press("Enter")
    equal(suffix.output(), "感じ的")
  end)

  test("suffix starts directly from kana mode", function()
    local h = harness()
    h.press(">")
    h.type("teki")
    h.press(" ")
    h.press("Enter")
    equal(h.output(), "的")
  end)

  test("okuri conversion appends okuri kana", function()
    local h = harness()
    h.type("HashiRu")
    equal(h.session.state.showing_candidate, true)
    h.press("Enter")
    equal(h.output(), "走る")
  end)

  test("sticky shift starts okuri", function()
    local h = harness()
    h.press(";")
    h.type("hashi")
    h.press(";")
    h.type("ru")
    h.press("Enter")
    equal(h.output(), "走る")
  end)

  test("numeric conversion preserves candidate styles", function()
    local h = harness()
    h.type("Dai5kai")
    h.press(" ")
    equal(h.session:candidate_text(), "第５回")
    h.press(" ")
    equal(h.session:candidate_text(), "第五回")
  end)

  test("candidate annotation is displayed separately", function()
    local h = harness()
    h.type("Chuumoku")
    h.press(" ")
    local page = h.press(" ").candidate_page
    equal(h.session:candidate_text(), "注目")
    equal(page, nil)
  end)

  test("candidate purge removes the current word", function()
    local h = harness()
    h.type("Kanji")
    h.press(" ")
    h.press("X")
    equal(h.session:candidate_text(), "漢字")
  end)

  test("typing after a candidate commits it first", function()
    local h = harness()
    h.type("Kanji")
    h.press(" ")
    h.type("a")
    equal(h.output(), "感じあ")
  end)

  test("candidate paging and direct selection", function()
    local h = harness()
    h.type("Ooi")
    for _ = 1, 5 do
      h.press(" ")
    end
    local page = h.press("j").candidate_page
    equal(page, nil)
    equal(h.output(), "都比")
  end)

  test("previous candidate and cancel candidate", function()
    local h = harness()
    h.type("Kanji")
    h.press(" ")
    h.press(" ")
    equal(h.session:candidate_text(), "漢字")
    h.press("x")
    equal(h.session:candidate_text(), "感じ")
    h.press("g", { ctrl = true })
    equal(h.session.state.showing_candidate, false)
    equal(h.session:preedit(), "▽かんじ")
  end)

  test("Ctrl-G cancels reading after candidates are dismissed", function()
    local h = harness({ ["かんじ"] = { "漢字" } })
    h.press("K")
    h.type("anji")
    h.press(" ")
    h.press("g", { ctrl = true })
    equal(h.session.state.composing, true)
    equal(h.session.state.showing_candidate, false)
    h.press("g", { ctrl = true })
    equal(h.session.state.composing, false)
    equal(h.session:preedit(), "")
  end)

  test("abbrev conversion", function()
    local h = harness()
    h.press("/")
    h.type("MCP")
    equal(h.session:preedit(), "▽/MCP")
    h.press(" ")
    h.press("Enter")
    equal(h.output(), "Model Context Protocol")
  end)

  test("double slash in abbrev commits a literal slash", function()
    local h = harness()
    h.press("/")
    h.press("/")
    equal(h.output(), "/")
  end)

  test("katakana and half katakana", function()
    local zen = harness()
    zen.type("Puro")
    zen.press("q")
    equal(zen.output(), "プロ")

    local han = harness()
    han.type("Gandamu")
    han.press("q", { ctrl = true })
    equal(han.output(), "ｶﾞﾝﾀﾞﾑ")
  end)

  test("new composition starts cleanly after katakana commit", function()
    local h = harness()
    h.type("Kana")
    h.press("q")
    h.type("Kanji")
    h.press("Enter")
    equal(h.output(), "カナかんじ")
    equal(h.session.state.roman, "")
    equal(h.session.state.okuri_key, "")
  end)

  test("q and Ctrl-Q toggle persistent kana modes", function()
    local zen = harness()
    zen.press("q")
    zen.type("ai")
    equal(zen.output(), "アイ")
    zen.press("q")
    zen.type("u")
    equal(zen.output(), "アイう")

    local han = harness()
    han.press("q", { ctrl = true })
    han.type("ga")
    equal(han.output(), "ｶﾞ")
  end)

  test("wide ascii mode", function()
    local h = harness()
    h.press("L")
    h.type("Ab 1")
    equal(h.output(), "Ａｂ　１")
  end)

  test("wide ascii handles punctuation and digits remain literal in kana mode", function()
    local wide = harness()
    wide.press("L")
    wide.type("!@_+")
    equal(wide.output(), "！＠＿＋")

    local kana = harness()
    kana.type("123")
    equal(kana.output(), "123")

    kana.type(".,")
    equal(kana.output(), "123。、")
  end)

  test("z commands", function()
    local h = harness()
    h.type("zhzjzkzl")
    h.type("z.")
    h.type("z ")
    equal(h.output(), "←↓↑→…　")
  end)

  test("missing candidate requests registration", function()
    local h = harness()
    h.type("Mitei")
    local result = h.press(" ")
    equal(result.register, "みてい")
    result = h.session:register_word("未定")
    equal(result.insert, "未定")
    equal(h.dictionary.user["みてい"], "未定")
  end)

  test("registered words are available on the next conversion", function()
    local h = harness()
    h.type("Mitei")
    h.press(" ")
    h.session:register_word("未定")

    h.type("Mitei")
    h.press(" ")
    h.press("Enter")
    equal(h.output(), "未定")
  end)

  test("exhausting candidates requests registration", function()
    local h = harness()
    h.type("Kanji")
    h.press(" ")
    h.press(" ")
    local result = h.press(" ")
    equal(result.register, "かんじ")
  end)

  test("cancelling registration returns to the last candidate", function()
    local h = harness()
    h.type("Kanji")
    h.press(" ")
    h.press(" ")
    h.press(" ")
    h.session:cancel_registration()
    equal(h.session.state.showing_candidate, true)
    equal(h.session:candidate_text(), "漢字")
  end)

  test("declining nested registration keeps the nested preedit", function()
    local h = harness()
    h.type("Mitei")
    h.press(" ")
    h.session:decline_nested_registration()
    equal(h.session.state.showing_candidate, false)
    equal(h.session.state.composing, true)
    equal(h.session:preedit(), "▽みてい")
  end)

  test("tab completes learned readings", function()
    local h = harness()
    h.type("Kan")
    h.press("Tab")
    equal(h.session.state.kana, "かんじ")
  end)
end

return M
