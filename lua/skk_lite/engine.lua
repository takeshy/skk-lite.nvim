local M = {}

M.STATE = {
  ASCII = "ascii",
  SKK_KANA = "skk_kana",
  SKK_HENKAN = "skk_henkan",
  SKK_CANDIDATE = "skk_candidate",
  ABBREV = "abbrev",
  SKK_TOUROKU = "skk_touroku",
}

M.HENKAN_PREFIX = "▽"
M.ABBREV_PREFIX = "▽/"
M.OKURI_MARKER = "*"

M.KANA_TABLE = {
  ["-"] = "ー", [","] = "、", ["."] = "。", ["["] = "「", ["]"] = "」",
  a = "あ", i = "い", u = "う", e = "え", o = "お",
  xa = "ぁ", xi = "ぃ", xu = "ぅ", xe = "ぇ", xo = "ぉ",
  ka = "か", ki = "き", ku = "く", ke = "け", ko = "こ",
  sa = "さ", shi = "し", si = "し", su = "す", se = "せ", so = "そ",
  ta = "た", chi = "ち", ti = "ち", tsu = "つ", tu = "つ", te = "て", to = "と",
  na = "な", ni = "に", nu = "ぬ", ne = "ね", no = "の",
  ha = "は", hi = "ひ", fu = "ふ", hu = "ふ", he = "へ", ho = "ほ",
  ma = "ま", mi = "み", mu = "む", me = "め", mo = "も",
  ya = "や", yu = "ゆ", yo = "よ",
  xya = "ゃ", xyu = "ゅ", xyo = "ょ",
  ra = "ら", ri = "り", ru = "る", re = "れ", ro = "ろ",
  wa = "わ", wi = "うぃ", we = "うぇ", wo = "を", nn = "ん", xtu = "っ",
  ga = "が", gi = "ぎ", gu = "ぐ", ge = "げ", go = "ご",
  za = "ざ", ji = "じ", zi = "じ", zu = "ず", ze = "ぜ", zo = "ぞ",
  da = "だ", di = "ぢ", du = "づ", de = "で", ["do"] = "ど",
  ba = "ば", bi = "び", bu = "ぶ", be = "べ", bo = "ぼ",
  pa = "ぱ", pi = "ぴ", pu = "ぷ", pe = "ぺ", po = "ぽ",
  kya = "きゃ", kyu = "きゅ", kyo = "きょ",
  sha = "しゃ", shu = "しゅ", sho = "しょ",
  sya = "しゃ", syu = "しゅ", syo = "しょ",
  cha = "ちゃ", chu = "ちゅ", che = "ちぇ", cho = "ちょ",
  tya = "ちゃ", tyu = "ちゅ", tye = "ちぇ", tyo = "ちょ",
  nya = "にゃ", nyu = "にゅ", nyo = "にょ",
  hya = "ひゃ", hyu = "ひゅ", hyo = "ひょ",
  mya = "みゃ", myu = "みゅ", myo = "みょ",
  rya = "りゃ", ryu = "りゅ", ryo = "りょ",
  gya = "ぎゃ", gyu = "ぎゅ", gyo = "ぎょ",
  ja = "じゃ", ju = "じゅ", jo = "じょ", je = "じぇ",
  jya = "じゃ", jyu = "じゅ", jyo = "じょ",
  bya = "びゃ", byu = "びゅ", byo = "びょ",
  pya = "ぴゃ", pyu = "ぴゅ", pyo = "ぴょ",
  fa = "ふぁ", fi = "ふぃ", fe = "ふぇ", fo = "ふぉ",
  va = "ゔぁ", vi = "ゔぃ", vu = "ゔ", ve = "ゔぇ", vo = "ゔぉ",
}

local small_tsu_consonants = {}
for ch in ("bcdfghjklmpqrstvwxyz"):gmatch(".") do
  small_tsu_consonants[ch] = true
end

local n_followers = {}
for ch in ("aiueoyn"):gmatch(".") do
  n_followers[ch] = true
end

local roman_prefixes = {}
for key in pairs(M.KANA_TABLE) do
  for length = 1, #key - 1 do
    roman_prefixes[key:sub(1, length)] = true
  end
end

local function char_len(text)
  return vim.fn.strchars(text or "")
end

local function char_slice(text, start_index, length)
  if length == nil then
    return vim.fn.strcharpart(text, start_index)
  end
  return vim.fn.strcharpart(text, start_index, length)
end

M.char_len = char_len
M.char_slice = char_slice

function M.preedit_kana(state)
  return (state.kana or "") .. (state.okuri_kana or "")
end

function M.lookup_key(state)
  if state.okuri_key and state.okuri_key ~= "" then
    return (state.kana or "") .. state.okuri_key
  end
  return state.kana or ""
end

function M.lookup_keys(state)
  local primary = M.lookup_key(state)
  local keys = { { key = primary } }
  if primary:find("%d") then
    local numbers = {}
    for number in primary:gmatch("%d+") do
      table.insert(numbers, number)
    end
    table.insert(keys, { key = primary:gsub("%d+", "#"), numbers = numbers })
  end
  return keys
end

function M.abbrev_preedit(state)
  return M.ABBREV_PREFIX .. (state.abbrev or "")
end

function M.composing_preedit(state)
  if state.okuri_key and state.okuri_key ~= "" then
    return M.HENKAN_PREFIX .. (state.kana or "") .. M.OKURI_MARKER .. (state.okuri_kana or "")
  end
  return M.HENKAN_PREFIX .. M.preedit_kana(state)
end

function M.invalidate_candidates(state)
  state.candidates = {}
  state.candidate_index = 1
  state.showing_candidate = false
end

function M.append_composing_kana(state, kana)
  if not state.composing then
    return
  end
  if state.okuri_key and state.okuri_key ~= "" then
    state.okuri_kana = (state.okuri_kana or "") .. kana
  else
    state.kana = (state.kana or "") .. kana
  end
  M.invalidate_candidates(state)
end

function M.fold_okuri_into_stem(state)
  if (not state.okuri_key or state.okuri_key == "") and (not state.okuri_kana or state.okuri_kana == "") then
    return false
  end
  state.kana = (state.kana or "") .. (state.okuri_kana or "")
  state.okuri_key = ""
  state.okuri_kana = ""
  return true
end

function M.should_start_okuri(state, key)
  return #key == 1
    and key:match("^[A-Z]$") ~= nil
    and state.composing == true
    and (not state.okuri_key or state.okuri_key == "")
    and state.kana ~= nil
    and state.kana ~= ""
end

function M.is_abbrev_char(key)
  return #key == 1 and key:match("^[A-Za-z0-9-]$") ~= nil
end

function M.delete_composing_char_before_offset(state, offset)
  local prefix_length = char_len(M.HENKAN_PREFIX)
  local stem_length = char_len(state.kana or "")
  local has_okuri = state.okuri_key and state.okuri_key ~= ""
  local okuri_length = char_len(state.okuri_kana or "")
  local total_length = stem_length + (has_okuri and char_len(M.OKURI_MARKER) or 0) + okuri_length
  if not state.composing or offset <= prefix_length or offset > prefix_length + total_length then
    return false
  end

  local kana_index = offset - prefix_length - 1
  if kana_index < stem_length then
    state.kana = char_slice(state.kana, 0, kana_index) .. char_slice(state.kana, kana_index + 1)
  elseif has_okuri and kana_index == stem_length then
    M.fold_okuri_into_stem(state)
  else
    local okuri_index = kana_index - stem_length - (has_okuri and char_len(M.OKURI_MARKER) or 0)
    state.okuri_kana = char_slice(state.okuri_kana, 0, okuri_index) .. char_slice(state.okuri_kana, okuri_index + 1)
  end
  M.invalidate_candidates(state)
  return true
end

function M.composing_offset_after_backspace(offset)
  return math.max(char_len(M.HENKAN_PREFIX), offset - 1)
end

function M.consume_roman_chunk(state)
  local roman = (state.roman or ""):lower()
  if roman:sub(1, 2) == "n'" then
    state.roman = roman:sub(3)
    M.append_composing_kana(state, "ん")
    return "ん"
  end

  -- Keep an exact "nn" pending until the following key is known.  This
  -- allows the second n to start the next syllable ("nna" -> "んな") while
  -- still committing a terminal "nn" as a single "ん".
  if roman == "nn" then
    return ""
  end
  if #roman >= 3 and roman:sub(1, 2) == "nn" then
    local next_character = roman:sub(3, 3)
    local carry_second_n = next_character:match("^[aiueoy]$") ~= nil
    state.roman = carry_second_n and roman:sub(2) or roman:sub(3)
    M.append_composing_kana(state, "ん")
    return "ん"
  end

  if #roman >= 2 and roman:sub(1, 1) == roman:sub(2, 2) and small_tsu_consonants[roman:sub(1, 1)] then
    state.roman = roman:sub(2)
    M.append_composing_kana(state, "っ")
    return "っ"
  end

  if #roman == 2 and roman:sub(1, 1) == "n" and not n_followers[roman:sub(2, 2)] then
    state.roman = roman:sub(2)
    M.append_composing_kana(state, "ん")
    return "ん"
  end

  for length = math.min(3, #roman), 1, -1 do
    local key = roman:sub(1, length)
    local kana = M.KANA_TABLE[key]
    if kana then
      state.roman = roman:sub(length + 1)
      M.append_composing_kana(state, kana)
      return kana
    end
  end

  if not roman_prefixes[roman] then
    state.roman = roman:sub(2)
  end
  return ""
end

function M.consume_pending_n(state)
  if state.roman ~= "n" and state.roman ~= "nn" then
    return ""
  end
  state.roman = ""
  M.append_composing_kana(state, "ん")
  return "ん"
end

local kanji_digits = { "〇", "一", "二", "三", "四", "五", "六", "七", "八", "九" }

local function to_full_width_digits(text)
  return (text:gsub("%d", function(ch)
    return vim.fn.nr2char(ch:byte() + 0xfee0)
  end))
end

local function to_kanji_digits(text)
  return (text:gsub("%d", function(ch)
    return kanji_digits[tonumber(ch) + 1]
  end))
end

local function to_kanji_numeral(text)
  if not text:match("^%d+$") then
    return text
  end
  local digits = text:gsub("^0+(%d)", "%1")
  if digits == "0" then
    return "〇"
  end
  local groups = {}
  local finish = #digits
  while finish > 0 do
    local start = math.max(1, finish - 3)
    table.insert(groups, 1, digits:sub(start, finish))
    finish = start - 1
  end
  local group_units = { "", "万", "億", "兆", "京" }
  if #groups > #group_units then
    return to_kanji_digits(digits)
  end
  local small_units = { "", "十", "百", "千" }
  local result = ""
  for group_index, group in ipairs(groups) do
    local part = ""
    for index = 1, #group do
      local digit = tonumber(group:sub(index, index))
      if digit ~= 0 then
        local unit = small_units[#group - index + 1]
        part = part .. ((digit == 1 and unit ~= "") and unit or (kanji_digits[digit + 1] .. unit))
      end
    end
    if part ~= "" then
      part = part .. group_units[#groups - group_index + 1]
    end
    result = result .. part
  end
  return result ~= "" and result or "〇"
end

function M.apply_numeric_candidate(candidate, numbers)
  local index = 0
  return (candidate:gsub("#([0-9])", function(kind)
    index = index + 1
    local number = numbers[index] or ""
    if kind == "1" then
      return to_full_width_digits(number)
    elseif kind == "2" then
      return to_kanji_digits(number)
    elseif kind == "3" then
      return to_kanji_numeral(number)
    end
    return number
  end))
end

local half_katakana = {
  ["ア"] = "ｱ", ["イ"] = "ｲ", ["ウ"] = "ｳ", ["エ"] = "ｴ", ["オ"] = "ｵ",
  ["カ"] = "ｶ", ["キ"] = "ｷ", ["ク"] = "ｸ", ["ケ"] = "ｹ", ["コ"] = "ｺ",
  ["サ"] = "ｻ", ["シ"] = "ｼ", ["ス"] = "ｽ", ["セ"] = "ｾ", ["ソ"] = "ｿ",
  ["タ"] = "ﾀ", ["チ"] = "ﾁ", ["ツ"] = "ﾂ", ["テ"] = "ﾃ", ["ト"] = "ﾄ",
  ["ナ"] = "ﾅ", ["ニ"] = "ﾆ", ["ヌ"] = "ﾇ", ["ネ"] = "ﾈ", ["ノ"] = "ﾉ",
  ["ハ"] = "ﾊ", ["ヒ"] = "ﾋ", ["フ"] = "ﾌ", ["ヘ"] = "ﾍ", ["ホ"] = "ﾎ",
  ["マ"] = "ﾏ", ["ミ"] = "ﾐ", ["ム"] = "ﾑ", ["メ"] = "ﾒ", ["モ"] = "ﾓ",
  ["ヤ"] = "ﾔ", ["ユ"] = "ﾕ", ["ヨ"] = "ﾖ",
  ["ラ"] = "ﾗ", ["リ"] = "ﾘ", ["ル"] = "ﾙ", ["レ"] = "ﾚ", ["ロ"] = "ﾛ",
  ["ワ"] = "ﾜ", ["ヲ"] = "ｦ", ["ン"] = "ﾝ",
  ["ァ"] = "ｧ", ["ィ"] = "ｨ", ["ゥ"] = "ｩ", ["ェ"] = "ｪ", ["ォ"] = "ｫ",
  ["ッ"] = "ｯ", ["ャ"] = "ｬ", ["ュ"] = "ｭ", ["ョ"] = "ｮ",
  ["ガ"] = "ｶﾞ", ["ギ"] = "ｷﾞ", ["グ"] = "ｸﾞ", ["ゲ"] = "ｹﾞ", ["ゴ"] = "ｺﾞ",
  ["ザ"] = "ｻﾞ", ["ジ"] = "ｼﾞ", ["ズ"] = "ｽﾞ", ["ゼ"] = "ｾﾞ", ["ゾ"] = "ｿﾞ",
  ["ダ"] = "ﾀﾞ", ["ヂ"] = "ﾁﾞ", ["ヅ"] = "ﾂﾞ", ["デ"] = "ﾃﾞ", ["ド"] = "ﾄﾞ",
  ["バ"] = "ﾊﾞ", ["ビ"] = "ﾋﾞ", ["ブ"] = "ﾌﾞ", ["ベ"] = "ﾍﾞ", ["ボ"] = "ﾎﾞ",
  ["パ"] = "ﾊﾟ", ["ピ"] = "ﾋﾟ", ["プ"] = "ﾌﾟ", ["ペ"] = "ﾍﾟ", ["ポ"] = "ﾎﾟ",
  ["ヴ"] = "ｳﾞ", ["ー"] = "ｰ", ["。"] = "｡", ["、"] = "､", ["「"] = "｢", ["」"] = "｣", ["・"] = "･",
}

function M.to_katakana(text)
  local result = {}
  for index = 0, char_len(text) - 1 do
    local ch = char_slice(text, index, 1)
    local code = vim.fn.char2nr(ch)
    table.insert(result, code >= 0x3041 and code <= 0x3096 and vim.fn.nr2char(code + 0x60) or ch)
  end
  return table.concat(result)
end

function M.to_half_width_katakana(text)
  local result = {}
  for index = 0, char_len(text) - 1 do
    local ch = char_slice(text, index, 1)
    table.insert(result, half_katakana[ch] or ch)
  end
  return table.concat(result)
end

function M.to_full_width_ascii(text)
  local result = {}
  for index = 1, #text do
    local byte = text:byte(index)
    if byte == 32 then
      table.insert(result, "　")
    elseif byte >= 33 and byte <= 126 then
      table.insert(result, vim.fn.nr2char(byte + 0xfee0))
    else
      table.insert(result, text:sub(index, index))
    end
  end
  return table.concat(result)
end

function M.candidate_word(candidate)
  return candidate:match("^([^;]*)") or candidate
end

function M.candidate_annotation(candidate)
  return candidate:match("^[^;]*;(.*)$") or ""
end

return M
