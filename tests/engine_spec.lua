local engine = require("skk_lite.engine")

local M = {}

local function equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error((message or "values differ") .. ("\nexpected: %s\nactual:   %s"):format(vim.inspect(expected), vim.inspect(actual)))
  end
end

local function state()
  return {
    roman = "",
    composing = true,
    kana = "",
    okuri_key = "",
    okuri_kana = "",
    candidates = {},
    candidate_index = 1,
  }
end

local function type_roman(current, text)
  for ch in text:gmatch(".") do
    current.roman = current.roman .. ch:lower()
    local guard = 0
    while current.roman ~= "" and guard < 8 do
      guard = guard + 1
      if engine.consume_roman_chunk(current) == "" then
        break
      end
    end
  end
end

function M.run(test)
  test("roman variants compose", function()
    local cases = {
      jixe = "じぇ",
      we = "うぇ",
      tye = "ちぇ",
      che = "ちぇ",
      xi = "ぃ",
      ["n'a"] = "んあ",
    }
    for roman, kana in pairs(cases) do
      local current = state()
      type_roman(current, roman)
      equal(current.kana, kana, roman)
      equal(current.roman, "", roman .. " pending")
    end
  end)

  test("invalid prefix is discarded", function()
    local current = state()
    type_roman(current, "wk")
    equal(current.kana, "")
    equal(current.roman, "k")
    type_roman(current, "a")
    equal(current.kana, "か")
  end)

  test("pending n is consumed", function()
    local current = state()
    type_roman(current, "n")
    equal(engine.consume_pending_n(current), "ん")
    equal(engine.composing_preedit(current), "▽ん")
  end)

  test("double n terminates n before a following vowel", function()
    local current = state()
    type_roman(current, "nna")
    equal(current.kana, "んあ")
    equal(current.roman, "")

    current = state()
    type_roman(current, "konnnichiha")
    equal(current.kana, "こんにちは")
  end)

  test("terminal double n commits as one n", function()
    local current = state()
    type_roman(current, "nn")
    equal(current.kana, "ん")
    equal(current.roman, "")
  end)

  test("okuri lookup excludes okuri kana", function()
    local current = state()
    current.kana = "とうと"
    current.okuri_key = "i"
    current.okuri_kana = "い"
    equal(engine.preedit_kana(current), "とうとい")
    equal(engine.lookup_key(current), "とうとi")
    equal(engine.composing_preedit(current), "▽とうと*い")
  end)

  test("uppercase cannot start okuri before stem kana exists", function()
    local current = state()
    current.roman = "k"
    equal(engine.should_start_okuri(current, "K"), false)
    current.kana = "か"
    equal(engine.should_start_okuri(current, "K"), true)
  end)

  test("abbrev preedit accepts ascii word characters", function()
    local current = state()
    current.mode = engine.STATE.ABBREV
    current.abbrev = "MCP-2"
    equal(engine.abbrev_preedit(current), "▽/MCP-2")
    for character in ("Az-09"):gmatch(".") do
      equal(engine.is_abbrev_char(character), true)
    end
    equal(engine.is_abbrev_char("_"), false)
    equal(engine.is_abbrev_char("+"), false)
  end)

  test("editing preedit uses character offsets", function()
    local current = state()
    current.kana = "もりた"
    equal(engine.delete_composing_char_before_offset(current, 3), true)
    equal(current.kana, "もた")
    equal(engine.composing_offset_after_backspace(3), 2)
  end)

  test("editing invalidates candidates", function()
    local current = state()
    current.kana = "てすと"
    current.candidates = { "テスト", "TEST" }
    current.candidate_index = 2
    engine.delete_composing_char_before_offset(current, 4)
    equal(current.kana, "てす")
    equal(current.candidates, {})
    equal(current.candidate_index, 1)
  end)

  test("appending kana invalidates candidates", function()
    local current = state()
    current.kana = "てす"
    current.candidates = { "テスト", "TEST" }
    current.candidate_index = 2
    engine.append_composing_kana(current, "ら")
    equal(current.kana, "てすら")
    equal(current.candidates, {})
    equal(current.candidate_index, 1)
  end)

  test("okuri marker folds into stem", function()
    local current = state()
    current.kana = "かんが"
    current.okuri_key = "e"
    current.okuri_kana = "え"
    equal(engine.delete_composing_char_before_offset(current, 5), true)
    equal(current.kana, "かんがえ")
    equal(current.okuri_key, "")
    equal(current.okuri_kana, "")
  end)

  test("okuri kana can be deleted without removing the marker", function()
    local current = state()
    current.kana = "かんが"
    current.okuri_key = "e"
    current.okuri_kana = "え"
    equal(engine.delete_composing_char_before_offset(current, 6), true)
    equal(current.kana, "かんが")
    equal(current.okuri_key, "e")
    equal(current.okuri_kana, "")
  end)

  test("folding okuri is a no-op without okuri", function()
    local current = state()
    current.kana = "ようきろく"
    equal(engine.fold_okuri_into_stem(current), false)
    equal(current.kana, "ようきろく")
  end)

  test("numeric candidates substitute all styles", function()
    equal(engine.apply_numeric_candidate("第#0回", { "5" }), "第5回")
    equal(engine.apply_numeric_candidate("第#1回", { "5" }), "第５回")
    equal(engine.apply_numeric_candidate("第#2回", { "25" }), "第二五回")
    equal(engine.apply_numeric_candidate("第#3回", { "25" }), "第二十五回")
    equal(engine.apply_numeric_candidate("#3円", { "1234" }), "千二百三十四円")
    equal(engine.apply_numeric_candidate("#3", { "10405" }), "一万四百五")
    equal(engine.apply_numeric_candidate("#3", { "0" }), "〇")
    equal(engine.apply_numeric_candidate("#0月#0日", { "3", "14" }), "3月14日")
  end)

  test("katakana conversions", function()
    equal(engine.to_katakana("がんだむ"), "ガンダム")
    equal(engine.to_half_width_katakana("ガンダム"), "ｶﾞﾝﾀﾞﾑ")
    equal(engine.to_half_width_katakana("パーティー"), "ﾊﾟｰﾃｨｰ")
  end)

  test("candidate annotation is not committed", function()
    equal(engine.candidate_word("注目;ちゅうもく注釈"), "注目")
    equal(engine.candidate_annotation("注目;ちゅうもく注釈"), "ちゅうもく注釈")
  end)
end

return M
