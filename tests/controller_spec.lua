local engine = require("skk_lite.engine")
local register = require("skk_lite.register")
local skk = require("skk_lite")
local ui = require("skk_lite.ui")

local M = {}

local function equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error((message or "values differ") .. ("\nexpected: %s\nactual:   %s"):format(vim.inspect(expected), vim.inspect(actual)))
  end
end

local function buffer_mapping(buffer, lhs)
  return vim.api.nvim_buf_call(buffer, function()
    local mapping = vim.fn.maparg(lhs, "i", false, true)
    assert(type(mapping.callback) == "function", "missing insert mapping for " .. lhs)
    return mapping.callback
  end)
end

local function commandline_input(keys)
  vim.fn.feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "t")
  return vim.fn.input(":")
end

local function open_missing_registration(session, reading)
  session:clear_composition()
  session:start_composition()
  session.state.kana = reading
  skk._handle("insert", " ", {}, "<Space>")
  assert(vim.wait(500, function()
    return register.active() ~= nil
  end), "registration window did not open")
  return register.active().buffer
end

local function candidate_float_exists()
  for _, window in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(window).relative == "cursor" then
      return true
    end
  end
  return false
end

function M.run(test)
  local dictionary_path = vim.fn.tempname() .. ".json"
  local state_path = vim.fn.tempname() .. ".json"
  vim.fn.writefile({ "{}" }, dictionary_path)
  skk.setup({ dictionary_path = dictionary_path, state_path = state_path })

  test("dictionary maintenance commands are installed", function()
    equal(vim.fn.exists(":SkkLiteDownloadDictionary"), 2)
    equal(vim.fn.exists(":SkkLiteCompileDictionary"), 2)
    equal(vim.fn.exists(":SkkLiteInstallDictionary"), 2)
  end)

  test("VeryLazy restores mappings overwritten by distributions", function()
    vim.keymap.set("i", ".", ".<C-g>u")
    vim.keymap.set("i", ",", ",<C-g>u")
    vim.keymap.set("i", ";", ";<C-g>u")

    vim.api.nvim_exec_autocmds("User", { pattern = "VeryLazy" })
    equal(vim.fn.maparg(".", "i", false, true).desc, "skk-lite: .")
    equal(vim.fn.maparg(",", "i", false, true).desc, "skk-lite: ,")
    equal(vim.fn.maparg(";", "i", false, true).desc, "skk-lite: ;")
  end)

  test("command-line SKK resets after leaving the command line", function()
    local commandline = skk._commandline_session()
    equal(vim.fn.maparg("w", "c"), "")
    skk.enable("cmdline")
    commandline:handle("a")
    equal(commandline.state.enabled, true)
    local commandline_mapping = vim.fn.maparg("w", "c", false, true)
    equal(commandline_mapping.lhs, "w")
    equal(commandline_mapping.expr, 0)

    vim.api.nvim_exec_autocmds("CmdlineLeave", {})
    equal(commandline.state.enabled, false)
    equal(commandline.state.roman, "")
    equal(vim.fn.maparg("w", "c"), "")
    equal(vim.fn.maparg("<C-j>", "c", false, true).lhs, "<C-J>")
    equal(vim.fn.maparg("<C-j>", "c", false, true).expr, 0)
  end)

  test("command-line mappings synchronously update Japanese text", function()
    equal(commandline_input('echo "<C-j>watasi<CR>'), 'echo "わたし')
    equal(commandline_input("<C-j>Watasi<BS><CR><CR>"), "わた")
  end)

  test("command-line Escape cancels preedit without leaving the command line", function()
    local commandline = skk._commandline_session()
    commandline:enable()
    skk._handle("cmdline", "K", {}, "K")
    skk._handle("cmdline", "a", {}, "a")
    assert(commandline:preedit() ~= "", "command-line preedit was not created")

    local result = skk._handle("cmdline", "Escape", {}, "<Esc>")
    equal(commandline:preedit(), "")
    assert(result:find(vim.api.nvim_replace_termcodes("<BS>", true, false, true), 1, true), "preedit was not erased")
  end)

  test("command-line preedit is rewritten in the real command line", function()
    vim.api.nvim_exec_autocmds("CmdlineLeave", {})
    local commandline = skk._commandline_session()
    commandline:enable()
    local first = skk._handle("cmdline", "K", {}, "K")
    equal(first, "▽k")
    local second = skk._handle("cmdline", "a", {}, "a")
    local backspace = vim.api.nvim_replace_termcodes("<BS>", true, false, true)
    equal(second, backspace .. backspace .. "▽か")
    vim.api.nvim_exec_autocmds("CmdlineLeave", {})
  end)

  test("registration opens with kana input enabled", function()
    vim.cmd("enew!")
    local origin = vim.api.nvim_get_current_buf()
    local session = skk._buffer_session(origin)
    session:enable()
    local register_buffer = open_missing_registration(session, "かな")
    local nested = skk._buffer_session(register_buffer)
    equal(nested.state.enabled, true)
    equal(buffer_mapping(register_buffer, "a")(), "あ")

    buffer_mapping(register_buffer, "<Esc>")()
    equal(register.active(), nil)
  end)

  test("registration can select an optional llm-rewrite candidate", function()
    local previous_module = package.loaded.llm_rewrite
    local previous_select = vim.ui.select
    package.loaded.llm_rewrite = {
      suggest = function(reading, callback)
        equal(reading, "こうせい")
        callback({ "校正", "構成" })
      end,
    }
    vim.ui.select = function(items, _, callback)
      callback(items[2])
    end
    local register_buffer = open_missing_registration(skk._buffer_session(), "こうせい")
    buffer_mapping(register_buffer, "<C-l>")()
    equal(vim.api.nvim_buf_get_lines(register_buffer, 0, -1, false), { "構成" })
    buffer_mapping(register_buffer, "<C-g>")()
    vim.ui.select = previous_select
    package.loaded.llm_rewrite = previous_module
  end)

  test("Ctrl-G cancels registration", function()
    vim.cmd("enew!")
    local origin = vim.api.nvim_get_current_buf()
    local session = skk._buffer_session(origin)
    session:enable()
    local register_buffer = open_missing_registration(session, "きゃんせる")

    buffer_mapping(register_buffer, "<C-g>")()
    equal(register.active(), nil)
    equal(session.state.composing, true)
    equal(session.state.kana, "きゃんせる")
  end)

  test("registration closes the exhausted candidate popup", function()
    vim.cmd("enew!")
    local origin = vim.api.nvim_get_current_buf()
    local session = skk._buffer_session(origin)
    session:enable()
    session:start_composition()
    session.state.kana = "こうほ"
    session.state.candidates = { "一", "二", "三", "四", "五" }
    session.state.candidate_index = 5
    session.state.showing_candidate = true

    skk._handle("insert", " ", {}, "<Space>")
    assert(vim.wait(500, function()
      return register.active() ~= nil
    end), "registration window did not open")
    equal(candidate_float_exists(), false)

    buffer_mapping(register.active().buffer, "<C-g>")()
  end)

  test("registration commits a pending n before accepting", function()
    vim.cmd("enew!")
    local origin = vim.api.nvim_get_current_buf()
    local session = skk._buffer_session(origin)
    session:enable()
    local register_buffer = open_missing_registration(session, "みてい")
    local nested = skk._buffer_session(register_buffer)
    nested:handle("n")

    local enter = buffer_mapping(register_buffer, "<CR>")
    enter()
    equal(register.active().buffer, register_buffer)
    equal(vim.api.nvim_buf_get_lines(register_buffer, 0, -1, false), { "ん" })

    enter()
    equal(register.active(), nil)
    equal(vim.api.nvim_buf_get_lines(origin, 0, -1, false), { "ん" })
  end)

  test("registration clears stale outer preedit immediately", function()
    vim.cmd("enew!")
    local origin = vim.api.nvim_get_current_buf()
    local session = skk._buffer_session(origin)
    session:enable()
    local register_buffer = open_missing_registration(session, "のこり")
    vim.api.nvim_buf_set_extmark(origin, ui._namespace, 0, 0, {
      virt_text = { { "▽のこり", "SkkLitePreedit" } },
      virt_text_pos = "inline",
    })
    vim.api.nvim_buf_set_lines(register_buffer, 0, -1, false, { "残り" })

    buffer_mapping(register_buffer, "<CR>")()
    equal(register.active(), nil)
    equal(vim.api.nvim_buf_get_extmarks(origin, -1, 0, -1, {}), {})
  end)

  test("nested missing conversion does not replace the registration window", function()
    vim.cmd("enew!")
    local origin = vim.api.nvim_get_current_buf()
    local session = skk._buffer_session(origin)
    session:enable()
    local register_buffer = open_missing_registration(session, "そと")
    local nested = skk._buffer_session(register_buffer)
    nested:start_composition()
    nested.state.kana = "うち"

    skk._handle("insert", " ", {}, "<Space>")
    equal(register.active().buffer, register_buffer)
    equal(nested.state.mode, engine.STATE.SKK_HENKAN)
    equal(nested.state.composing, true)

    local escape = buffer_mapping(register_buffer, "<Esc>")
    escape()
    equal(register.active(), nil)
  end)

  test("registration unicode escapes are inserted before accepting", function()
    vim.cmd("enew!")
    local origin = vim.api.nvim_get_current_buf()
    local session = skk._buffer_session(origin)
    session:enable()
    local register_buffer = open_missing_registration(session, "ゆにこーど")
    vim.api.nvim_buf_set_lines(register_buffer, 0, -1, false, { "\\u3042" })

    local enter = buffer_mapping(register_buffer, "<CR>")
    enter()
    equal(register.active().buffer, register_buffer)
    equal(vim.api.nvim_buf_get_lines(register_buffer, 0, -1, false), { "あ" })

    enter()
    equal(register.active(), nil)
    equal(vim.api.nvim_buf_get_lines(origin, 0, -1, false), { "あ" })
  end)

  test("registration unicode decoder supports yen prefixes and rejects invalid scalars", function()
    local text, replaced = register._replace_unicode_escape("前¥u3042")
    equal({ text, replaced }, { "前あ", true })
    text, replaced = register._replace_unicode_escape("￥u1f600")
    equal({ text, replaced }, { "😀", true })
    local _, _, decode_error = register._replace_unicode_escape("\\ud800")
    equal(type(decode_error), "string")
  end)

  vim.fn.delete(dictionary_path)
  vim.fn.delete(state_path)
end

return M
