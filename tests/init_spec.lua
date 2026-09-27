local skk = require("skk_lite")

local M = {}

local function equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error((message or "values differ") .. ("\nexpected: %s\nactual:   %s"):format(vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run(test)
  test("statusline shows the mode of the window being rendered", function()
    local original_window = vim.api.nvim_get_current_win()
    local original_target = vim.g.statusline_winid
    vim.cmd("new")
    local window = vim.api.nvim_get_current_win()
    local buffer = vim.api.nvim_get_current_buf()
    local session = skk._buffer_session(buffer)
    session:enable()
    vim.api.nvim_set_current_win(original_window)
    vim.g.statusline_winid = window
    equal(skk.statusline(), "SKK かな")
    local rendered = vim.api.nvim_eval_statusline(
      '%{v:lua.require("skk_lite").statusline()}', { winid = window }
    )
    equal(rendered.str, "SKK かな")
    session:disable()
    equal(skk.statusline(), "SKK OFF")
    vim.g.statusline_winid = original_target
    vim.api.nvim_win_close(window, true)
    vim.api.nvim_buf_delete(buffer, { force = true })
  end)

  test("command-line registration splices at the cursor", function()
    local line, position = skk._splice_commandline({ line = "abc", position = 1 }, "X")
    equal({ line, position }, { "Xabc", 2 })

    line, position = skk._splice_commandline({ line = "abc", position = 2 }, "XY")
    equal({ line, position }, { "aXYbc", 4 })

    line, position = skk._splice_commandline({ line = "abc", position = 4 }, "Z")
    equal({ line, position }, { "abcZ", 5 })
  end)

  test("command-line registration keeps byte cursor positions", function()
    local japanese = string.char(0xe3, 0x81, 0x82)
    local line, position = skk._splice_commandline({ line = "a" .. japanese .. "b", position = 5 }, "X")
    equal(line, "a" .. japanese .. "Xb")
    equal(position, 6)
  end)
end

return M
