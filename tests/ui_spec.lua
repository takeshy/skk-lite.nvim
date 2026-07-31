local Session = require("skk_lite.session")
local ui = require("skk_lite.ui")

local M = {}

local function equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error((message or "values differ") .. ("\nexpected: %s\nactual:   %s"):format(vim.inspect(expected), vim.inspect(actual)))
  end
end

local function preedit_chunk(buffer)
  local namespace = vim.api.nvim_get_namespaces()["skk-lite"]
  local marks = vim.api.nvim_buf_get_extmarks(buffer, namespace, 0, -1, { details = true })
  assert(#marks == 1, "expected one preedit extmark")
  return marks[1][4].virt_text[1]
end

function M.run(test)
  test("plain pending consonants use normal text highlighting", function()
    local buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buffer)
    local session = Session.new({})
    session:enable()
    session:handle("k")
    ui.render(session, "insert", buffer)
    equal(preedit_chunk(buffer), { "k" })
    ui.clear("insert", buffer)
    vim.api.nvim_buf_delete(buffer, { force = true })
  end)

  test("conversion preedit keeps SKK highlighting", function()
    local buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buffer)
    local session = Session.new({})
    session:enable()
    session:handle("K")
    ui.render(session, "insert", buffer)
    equal(preedit_chunk(buffer), { "▽k", "SkkLitePreedit" })
    ui.clear("insert", buffer)
    vim.api.nvim_buf_delete(buffer, { force = true })
  end)

  test("command-line candidate pages open a floating window", function()
    local session = Session.new({})
    session:enable()
    session.state.composing = true
    session.state.showing_candidate = true
    session.state.candidates = { "一", "二", "三", "四", "五", "六" }
    session.state.candidate_index = 5
    local windows_before = #vim.api.nvim_list_wins()
    ui.render(session, "cmdline")
    equal(#vim.api.nvim_list_wins(), windows_before + 1)
    ui.clear("cmdline")
  end)

  test("command-line preedit follows external cmdline UI", function()
    local previous = vim.g.ui_cmdline_pos
    vim.g.ui_cmdline_pos = { 7, 24 }
    local position = ui._cmdline_float_position(1)
    equal(position, { row = 7, col = 24, zindex = 250 })
    vim.g.ui_cmdline_pos = previous
  end)
end

return M
