local engine = require("skk_lite.engine")
local register = require("skk_lite.register")
local skk = require("skk_lite")

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

  test("command-line SKK resets after leaving the command line", function()
    local commandline = skk._commandline_session()
    equal(vim.fn.maparg("w", "c"), "")
    skk.enable("cmdline")
    commandline:handle("a")
    equal(commandline.state.enabled, true)
    equal(vim.fn.maparg("w", "c", false, true).lhs, "w")

    vim.api.nvim_exec_autocmds("CmdlineLeave", {})
    equal(commandline.state.enabled, false)
    equal(commandline.state.roman, "")
    equal(vim.fn.maparg("w", "c"), "")
    equal(vim.fn.maparg("<C-j>", "c", false, true).lhs, "<C-J>")
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
