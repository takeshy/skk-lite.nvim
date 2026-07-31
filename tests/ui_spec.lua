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
end

return M
