local engine = require("skk_lite.engine")

local Session = {}
Session.__index = Session

local Z_COMMANDS = {
  h = "←",
  j = "↓",
  k = "↑",
  l = "→",
  [" "] = "　",
  ["."] = "…",
  [","] = "‥",
  ["-"] = "～",
  ["/"] = "・",
  ["["] = "『",
  ["]"] = "』",
}

local LIST_LABELS = { a = 0, s = 1, d = 2, f = 3, j = 4, k = 5, l = 6 }
local INLINE_CANDIDATES = 4
local LIST_PAGE_SIZE = 7

local function new_state()
  return {
    enabled = false,
    mode = engine.STATE.SKK_KANA,
    wide_ascii = false,
    katakana_mode = nil,
    roman = "",
    abbrev = "",
    composing = false,
    kana = "",
    okuri_key = "",
    okuri_kana = "",
    sticky_okuri = false,
    candidates = {},
    candidate_index = 1,
    showing_candidate = false,
    completion_matches = nil,
    completion_index = 1,
  }
end

function Session.new(dictionary)
  return setmetatable({
    dictionary = dictionary,
    state = new_state(),
  }, Session)
end

function Session:clear_composition()
  local state = self.state
  state.mode = engine.STATE.SKK_KANA
  state.roman = ""
  state.abbrev = ""
  state.composing = false
  state.kana = ""
  state.okuri_key = ""
  state.okuri_kana = ""
  state.sticky_okuri = false
  state.candidates = {}
  state.candidate_index = 1
  state.showing_candidate = false
  state.completion_matches = nil
  state.completion_index = 1
end

function Session:reset()
  local enabled = self.state.enabled
  local katakana_mode = self.state.katakana_mode
  self.state = new_state()
  self.state.enabled = enabled
  self.state.katakana_mode = katakana_mode
end

function Session:enable()
  self.state.enabled = true
  self.state.wide_ascii = false
  self.state.katakana_mode = nil
  self:clear_composition()
end

function Session:disable()
  self.state = new_state()
end

function Session:start_composition()
  local state = self.state
  state.mode = engine.STATE.SKK_HENKAN
  state.composing = true
  state.roman = ""
  state.abbrev = ""
  state.kana = ""
  state.okuri_key = ""
  state.okuri_kana = ""
  state.sticky_okuri = false
  state.candidates = {}
  state.candidate_index = 1
  state.showing_candidate = false
  state.completion_matches = nil
end

function Session:start_okuri(key)
  local state = self.state
  if state.roman == "n" or state.roman == "nn" then
    engine.consume_pending_n(state)
  end
  state.okuri_key = key:lower()
  state.okuri_kana = ""
  state.sticky_okuri = false
  engine.invalidate_candidates(state)
end

function Session:is_abbrev()
  return self.state.mode == engine.STATE.ABBREV
end

function Session:candidate_text()
  local state = self.state
  local raw = state.candidates[state.candidate_index]
  local stem = raw and engine.candidate_word(raw) or state.kana
  return state.okuri_key ~= "" and (stem .. state.okuri_kana) or stem
end

function Session:preedit()
  local state = self.state
  local roman = state.roman == "nn" and "ん" or state.roman
  if self:is_abbrev() then
    return engine.abbrev_preedit(state)
  end
  if state.composing then
    if state.showing_candidate then
      return self:candidate_text()
    end
    return engine.composing_preedit(state) .. roman
  end
  return state.roman == "nn" and self:apply_katakana_mode("ん") or state.roman
end

function Session:candidate_page()
  local state = self.state
  if not state.showing_candidate or state.candidate_index <= INLINE_CANDIDATES then
    return nil
  end
  local items = {}
  local labels = { "A", "S", "D", "F", "J", "K", "L" }
  local finish = math.min(state.candidate_index + LIST_PAGE_SIZE - 1, #state.candidates)
  for index = state.candidate_index, finish do
    local raw = state.candidates[index]
    table.insert(items, {
      label = labels[index - state.candidate_index + 1],
      word = engine.candidate_word(raw),
      annotation = engine.candidate_annotation(raw),
      index = index,
    })
  end
  return {
    items = items,
    first = state.candidate_index,
    last = finish,
    total = #state.candidates,
  }
end

function Session:mode_text()
  local state = self.state
  if not state.enabled then
    return "SKK OFF"
  elseif state.wide_ascii then
    return "SKK 全英"
  elseif self:is_abbrev() then
    return "SKK 略語"
  elseif state.showing_candidate then
    return "SKK 候補"
  elseif state.composing then
    return "SKK 変換"
  elseif state.katakana_mode == "zen" then
    return "SKK カナ"
  elseif state.katakana_mode == "han" then
    return "SKK 半ｶﾅ"
  end
  return "SKK かな"
end

function Session:result(fields)
  local result = fields or {}
  result.handled = result.handled ~= false
  result.insert = result.insert or ""
  result.preedit = self:preedit()
  result.mode = self:mode_text()
  result.candidate_page = self:candidate_page()
  result.state = self.state
  return result
end

function Session:apply_katakana_mode(text)
  local state = self.state
  if not state.katakana_mode or state.composing or self:is_abbrev() then
    return text
  end
  local katakana = engine.to_katakana(text)
  return state.katakana_mode == "han" and engine.to_half_width_katakana(katakana) or katakana
end

function Session:flush_roman(force)
  if force == nil then
    force = true
  end
  local state = self.state
  local output = ""
  local guard = 0
  while state.roman ~= "" and guard < 8 do
    guard = guard + 1
    local before = state.roman
    local kana = engine.consume_roman_chunk(state)
    if kana ~= "" then
      if not state.composing then
        output = output .. self:apply_katakana_mode(kana)
      end
    elseif state.roman ~= before then
      -- An invalid prefix was discarded; continue with what remains.
    elseif force and (state.roman == "n" or state.roman == "nn") then
      kana = engine.consume_pending_n(state)
      if not state.composing then
        output = output .. self:apply_katakana_mode(kana)
      end
      break
    else
      break
    end
  end
  return output, state.roman == ""
end

function Session:type_printable(key)
  local state = self.state
  local output = ""

  if key:match("^[A-Z]$") then
    if not state.composing then
      self:start_composition()
      state = self.state
    elseif engine.should_start_okuri(state, key) then
      self:start_okuri(key)
    end
  elseif state.sticky_okuri and state.composing and state.okuri_key == "" and state.kana ~= "" and key:match("^[a-z]$") then
    self:start_okuri(key)
  end

  if state.showing_candidate then
    output = self:commit_candidate()
    state = self.state
  end

  state.roman = state.roman .. key:lower()
  local converted = self:flush_roman(false)
  output = output .. converted

  if state.composing and state.okuri_key ~= "" and state.okuri_kana ~= "" and state.roman == "" and #state.candidates == 0 then
    self:auto_convert_okuri()
  end
  return output
end

function Session:lookup_candidates()
  local state = self.state
  return self.dictionary.lookup_any(engine.lookup_keys(state))
end

function Session:auto_convert_okuri()
  local state = self.state
  local candidates = self:lookup_candidates()
  if #candidates == 0 then
    engine.fold_okuri_into_stem(state)
    return false
  end
  state.candidates = candidates
  state.candidate_index = 1
  state.showing_candidate = true
  state.mode = engine.STATE.SKK_CANDIDATE
  return true
end

function Session:show_next_candidate()
  local state = self.state
  local _, complete = self:flush_roman()
  if not complete then
    return nil
  end
  if #state.candidates == 0 then
    state.candidates = self:lookup_candidates()
    state.candidate_index = 1
    if #state.candidates == 0 then
      if engine.fold_okuri_into_stem(state) then
        return self:show_next_candidate()
      end
      state.mode = engine.STATE.SKK_TOUROKU
      return engine.lookup_key(state)
    end
    state.showing_candidate = true
    state.mode = engine.STATE.SKK_CANDIDATE
    return nil
  end
  if not state.showing_candidate then
    state.candidate_index = 1
    state.showing_candidate = true
    return nil
  end
  local increment = state.candidate_index > INLINE_CANDIDATES and LIST_PAGE_SIZE or 1
  local next_index = state.candidate_index + increment
  if next_index > #state.candidates then
    state.mode = engine.STATE.SKK_TOUROKU
    return engine.lookup_key(state)
  end
  state.candidate_index = next_index
  return nil
end

function Session:show_previous_candidate()
  local state = self.state
  if not state.composing or not state.showing_candidate or #state.candidates == 0 then
    return false
  end
  if state.candidate_index <= 1 then
    state.showing_candidate = false
    return true
  end
  if state.candidate_index > INLINE_CANDIDATES then
    state.candidate_index = state.candidate_index - LIST_PAGE_SIZE >= INLINE_CANDIDATES + 1
        and state.candidate_index - LIST_PAGE_SIZE
      or INLINE_CANDIDATES
  else
    state.candidate_index = state.candidate_index - 1
  end
  return true
end

function Session:commit_candidate()
  local state = self.state
  if not state.composing then
    return ""
  end
  self:flush_roman(true)
  local key = engine.lookup_key(state)
  local raw = state.showing_candidate and state.candidates[state.candidate_index] or nil
  local selected = raw and engine.candidate_word(raw) or ""
  local text = state.showing_candidate and self:candidate_text() or engine.preedit_kana(state)
  if selected ~= "" then
    self.dictionary.remember(key, selected)
  end
  self:clear_composition()
  return text
end

function Session:commit_katakana(half)
  if not self.state.composing or engine.preedit_kana(self.state) == "" then
    return ""
  end
  self:flush_roman()
  local text = engine.to_katakana(engine.preedit_kana(self.state))
  if half then
    text = engine.to_half_width_katakana(text)
  end
  self:clear_composition()
  return text
end

function Session:cancel_candidates()
  if not self.state.composing then
    return false
  end
  if not self.state.showing_candidate then
    self:clear_composition()
    return true
  end
  engine.invalidate_candidates(self.state)
  self.state.mode = engine.STATE.SKK_HENKAN
  return true
end

function Session:purge_candidate()
  local state = self.state
  if not state.showing_candidate or #state.candidates == 0 then
    return false
  end
  local key = engine.lookup_key(state)
  local candidate = engine.candidate_word(state.candidates[state.candidate_index])
  self.dictionary.purge(key, candidate)
  local remaining = {}
  for _, item in ipairs(state.candidates) do
    if engine.candidate_word(item) ~= candidate then
      table.insert(remaining, item)
    end
  end
  state.candidates = remaining
  if #remaining == 0 then
    state.candidate_index = 1
    state.showing_candidate = false
  elseif state.candidate_index > #remaining then
    state.candidate_index = #remaining
  end
  return true
end

function Session:complete_reading()
  local state = self.state
  local current = state.kana
  if not state.completion_matches or not vim.tbl_contains(state.completion_matches, current) then
    local matches = self.dictionary.completions(current)
    if #matches == 0 then
      return false
    end
    state.completion_matches = { current }
    vim.list_extend(state.completion_matches, matches)
    state.completion_index = 1
  end
  state.completion_index = state.completion_index % #state.completion_matches + 1
  state.kana = state.completion_matches[state.completion_index]
  engine.invalidate_candidates(state)
  return true
end

function Session:register_word(word)
  local key = engine.lookup_key(self.state)
  if key == "" or word == "" then
    return self:result({ handled = true })
  end
  self.dictionary.register(key, word)
  self:clear_composition()
  return self:result({ insert = word })
end

function Session:cancel_registration()
  local state = self.state
  if #state.candidates > 0 then
    state.candidate_index = math.min(math.max(state.candidate_index, 1), #state.candidates)
    state.showing_candidate = true
    state.mode = engine.STATE.SKK_CANDIDATE
  else
    state.showing_candidate = false
    state.mode = engine.STATE.SKK_HENKAN
  end
end

function Session:decline_nested_registration()
  local state = self.state
  state.mode = engine.STATE.SKK_HENKAN
  state.showing_candidate = false
end

function Session:select_list_candidate(key)
  local state = self.state
  if state.candidate_index <= INLINE_CANDIDATES then
    return nil
  end
  local offset = LIST_LABELS[key:lower()]
  if not offset then
    return nil
  end
  local index = state.candidate_index + offset
  if index > #state.candidates then
    return ""
  end
  state.candidate_index = index
  return self:commit_candidate()
end

function Session:handle(key, modifiers)
  modifiers = modifiers or {}
  local state = self.state

  if modifiers.ctrl and key:lower() == "j" then
    if state.enabled then
      if state.composing then
        return self:result({ insert = self:commit_candidate() })
      end
      local output = self:flush_roman(true)
      self:enable()
      return self:result({ insert = output })
    end
    self:enable()
    return self:result()
  end
  if not state.enabled then
    return self:result({ handled = false })
  end
  if modifiers.ctrl and key:lower() == "g" then
    -- Before candidates are shown, Ctrl+G on an okuri-ari reading folds the
    -- okurigana back into the stem so it converts as one okuri-nasi heading
    -- (mirrors omarchy foldOkuriIntoReading), instead of discarding the
    -- whole composition.
    if state.composing and not state.showing_candidate
        and (state.okuri_key ~= "" or state.okuri_kana ~= "") then
      engine.fold_okuri_into_stem(state)
      state.mode = engine.STATE.SKK_HENKAN
      return self:result({ handled = true })
    end
    return self:result({ handled = self:cancel_candidates() })
  end
  if modifiers.ctrl and key:lower() == "q" then
    if state.composing then
      return self:result({ insert = self:commit_katakana(true) })
    end
    local output = self:flush_roman(true)
    if state.katakana_mode == "han" then
      state.katakana_mode = nil
    else
      state.katakana_mode = "han"
    end
    return self:result({ insert = output })
  end
  if modifiers.ctrl or modifiers.alt or modifiers.meta then
    return self:result({ handled = false })
  end

  if self:is_abbrev() then
    if key == "Backspace" then
      if state.abbrev ~= "" then
        state.abbrev = engine.char_slice(state.abbrev, 0, engine.char_len(state.abbrev) - 1)
      else
        self:clear_composition()
      end
      return self:result()
    elseif key == "Escape" then
      self:clear_composition()
      return self:result()
    elseif key == " " then
      if state.abbrev == "" then
        return self:result()
      end
      local key_for_lookup = state.abbrev
      state.kana = key_for_lookup
      state.abbrev = ""
      state.composing = true
      state.mode = engine.STATE.SKK_HENKAN
      local registration = self:show_next_candidate()
      return self:result({ register = registration })
    elseif key == "/" then
      self:clear_composition()
      return self:result({ insert = "/" })
    elseif engine.is_abbrev_char(key) then
      state.abbrev = state.abbrev .. key
      return self:result()
    end
    return self:result()
  end

  local selected = state.showing_candidate and self:select_list_candidate(key) or nil
  if selected ~= nil then
    return self:result({ insert = selected })
  end

  if key == "Escape" then
    if state.wide_ascii then
      state.wide_ascii = false
    elseif state.composing then
      local text = engine.preedit_kana(state)
      self:clear_composition()
      return self:result({ insert = text })
    elseif state.roman ~= "" then
      state.roman = ""
    else
      return self:result({ handled = false })
    end
    return self:result()
  elseif key == "Backspace" then
    if state.wide_ascii then
      return self:result({ handled = false })
    elseif state.roman ~= "" then
      state.roman = state.roman:sub(1, -2)
      return self:result()
    elseif state.composing then
      if state.showing_candidate then
        state.showing_candidate = false
      elseif state.okuri_kana ~= "" then
        state.okuri_kana = engine.char_slice(state.okuri_kana, 0, engine.char_len(state.okuri_kana) - 1)
      elseif state.okuri_key ~= "" then
        state.okuri_key = ""
      elseif state.kana ~= "" then
        state.kana = engine.char_slice(state.kana, 0, engine.char_len(state.kana) - 1)
      end
      engine.invalidate_candidates(state)
      if engine.preedit_kana(state) == "" then
        self:clear_composition()
      end
      return self:result()
    end
    return self:result({ handled = false })
  elseif key == "Tab" and state.composing and not state.showing_candidate and state.okuri_key == "" then
    self:flush_roman(true)
    return self:result({ handled = self:complete_reading() })
  end

  if key == "/" and not state.composing and not state.wide_ascii
      and (state.roman == "" or state.roman == "n" or state.roman == "nn") then
    local output = self:flush_roman(true)
    self:clear_composition()
    state.mode = engine.STATE.ABBREV
    state.abbrev = ""
    return self:result({ insert = output })
  end

  if state.roman == "z" and Z_COMMANDS[key] then
    state.roman = ""
    local text = Z_COMMANDS[key]
    if state.composing then
      engine.append_composing_kana(state, text)
      return self:result()
    end
    return self:result({ insert = text })
  end

  if state.showing_candidate and key == "X" then
    self:purge_candidate()
    return self:result()
  elseif state.showing_candidate and key:lower() == "x" then
    self:show_previous_candidate()
    return self:result()
  end

  if key == ";" and not state.wide_ascii then
    local output = not state.composing and self:flush_roman(true) or ""
    if state.showing_candidate then
      output = self:commit_candidate()
      self:start_composition()
    elseif state.composing then
      if state.okuri_key == "" and engine.preedit_kana(state) ~= "" then
        state.sticky_okuri = true
      end
    else
      self:start_composition()
    end
    return self:result({ insert = output })
  elseif key == "l" then
    local output = ""
    if state.showing_candidate then
      output = self:commit_candidate()
    elseif state.composing then
      self:flush_roman()
      output = engine.preedit_kana(state)
    else
      output = self:flush_roman()
    end
    self:disable()
    return self:result({ insert = output })
  elseif key == "L" and not state.wide_ascii then
    local output = state.composing and self:commit_candidate() or self:flush_roman()
    self:clear_composition()
    state.enabled = true
    state.wide_ascii = true
    return self:result({ insert = output })
  elseif state.wide_ascii and #key == 1 and key:byte() >= 32 and key:byte() <= 126 then
    return self:result({ insert = engine.to_full_width_ascii(key) })
  elseif key:lower() == "q" and state.composing then
    return self:result({ insert = self:commit_katakana(false) })
  elseif key == "q" and not state.composing then
    local output = self:flush_roman(true)
    if state.katakana_mode == "zen" then
      state.katakana_mode = nil
    else
      state.katakana_mode = "zen"
    end
    return self:result({ insert = output })
  end

  if state.composing and not state.showing_candidate and key:match("^%d$") then
    self:flush_roman()
    engine.append_composing_kana(state, key)
    return self:result()
  elseif key == ">" then
    local output = ""
    if state.showing_candidate then
      output = self:commit_candidate()
      self:start_composition()
      engine.append_composing_kana(self.state, ">")
    elseif state.composing then
      self:flush_roman()
      engine.append_composing_kana(state, ">")
      local registration = self:show_next_candidate()
      return self:result({ register = registration })
    else
      self:flush_roman()
      self:start_composition()
      engine.append_composing_kana(self.state, ">")
    end
    return self:result({ insert = output })
  elseif key == "Enter" then
    if state.composing then
      return self:result({ insert = self:commit_candidate() })
    end
    return self:result({ insert = self:flush_roman(true), handled = false })
  elseif key == " " then
    if state.composing then
      local registration = self:show_next_candidate()
      return self:result({ register = registration })
    end
    return self:result({ insert = self:flush_roman(true), handled = false })
  end

  if state.showing_candidate then
    local committed = self:commit_candidate()
    if key == "/" then
      self.state.mode = engine.STATE.ABBREV
      self.state.abbrev = ""
      return self:result({ insert = committed })
    end
    if #key == 1 and key:match("^[A-Za-z,.'%-%[%]]$") then
      return self:result({ insert = committed .. self:type_printable(key) })
    end
    return self:result({ insert = committed, handled = false })
  end

  if #key == 1 and key:match("^[A-Za-z,.'%-%[%]]$") then
    return self:result({ insert = self:type_printable(key) })
  end
  return self:result({ insert = self:flush_roman(true), handled = false })
end

return Session
