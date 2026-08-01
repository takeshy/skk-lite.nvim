local engine = require("skk_lite.engine")

local M = {}

local namespace = vim.api.nvim_create_namespace("skk-lite")
local floats = {}
local last_modes = {}

local function valid_window(window)
  return window and vim.api.nvim_win_is_valid(window)
end

local function close_float(key)
  local current = floats[key]
  if not current then
    return
  end
  if valid_window(current.window) then
    vim.api.nvim_win_close(current.window, true)
  end
  if current.buffer and vim.api.nvim_buf_is_valid(current.buffer) then
    vim.api.nvim_buf_delete(current.buffer, { force = true })
  end
  floats[key] = nil
end

local function candidate_lines(session)
  local page = session:candidate_page()
  if page then
    local lines = {}
    for _, item in ipairs(page.items) do
      local annotation = item.annotation ~= "" and ("  ※" .. item.annotation) or ""
      table.insert(lines, ("%s: %s%s"):format(item.label, item.word, annotation))
    end
    table.insert(lines, ("[%d-%d/%d]"):format(page.first, page.last, page.total))
    return lines
  end
  local state = session.state
  if state.showing_candidate and state.candidates[state.candidate_index] then
    local annotation = engine.candidate_annotation(state.candidates[state.candidate_index])
    if annotation ~= "" then
      return { session:candidate_text() .. "  ※" .. annotation }
    end
  end
  return nil
end

local function show_float(key, lines, kind)
  if not lines or #lines == 0 then
    close_float(key)
    return
  end
  close_float(key)
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].modifiable = true
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].modifiable = false
  local width = 1
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  local config
  if kind == "cmdline" then
    config = {
      relative = "editor",
      row = math.max(0, vim.o.lines - #lines - 3),
      col = 1,
      width = math.min(width, math.max(20, vim.o.columns - 4)),
      height = #lines,
      style = "minimal",
      border = "rounded",
      focusable = false,
      zindex = 150,
    }
  else
    config = {
      relative = "cursor",
      row = 1,
      col = 0,
      width = math.min(width, math.max(20, vim.o.columns - 4)),
      height = #lines,
      style = "minimal",
      border = "rounded",
      focusable = false,
      zindex = 150,
    }
  end
  local window = vim.api.nvim_open_win(buffer, false, config)
  vim.wo[window].winhl = "Normal:SkkLiteCandidate,FloatBorder:SkkLiteBorder"
  floats[key] = { window = window, buffer = buffer }
end

function M.setup()
  vim.api.nvim_set_hl(0, "SkkLitePreedit", { link = "IncSearch", default = true })
  vim.api.nvim_set_hl(0, "SkkLiteCandidate", { link = "Pmenu", default = true })
  vim.api.nvim_set_hl(0, "SkkLiteBorder", { link = "PmenuSbar", default = true })
end

function M.render(session, kind, buffer)
  local key = kind == "cmdline" and "cmdline" or tostring(buffer)
  if kind == "insert" and buffer and vim.api.nvim_buf_is_valid(buffer) then
    vim.api.nvim_buf_clear_namespace(buffer, namespace, 0, -1)
    local preedit = session:preedit()
    if preedit ~= "" and vim.api.nvim_get_current_buf() == buffer then
      local cursor = vim.api.nvim_win_get_cursor(0)
      local chunk = { preedit }
      if session.state.composing or session:is_abbrev() then
        chunk[2] = "SkkLitePreedit"
      end
      pcall(vim.api.nvim_buf_set_extmark, buffer, namespace, cursor[1] - 1, cursor[2], {
        virt_text = { chunk },
        virt_text_pos = "inline",
        hl_mode = "combine",
        right_gravity = false,
      })
    end
  end
  local lines = candidate_lines(session)
  if kind == "cmdline" and not lines and session:preedit() ~= "" then
    lines = { session:preedit() }
  end
  show_float(key, lines, kind)
  if kind == "cmdline" then
    -- Command-line mappings render synchronously: the widget owns preedit,
    -- while only committed text is copied into the native command line.
    -- setcmdline() updates the internal text during a command-line mapping,
    -- but some TUI clients do not flush that grid until the next native key.
    -- render() is scheduled after the mapping, so force the updated grid out
    -- once the mapping callback has returned.
    vim.cmd("redraw!")
  end
  local mode = session:mode_text()
  vim.g.skk_lite_mode = mode
  if session.state.enabled and kind ~= "cmdline" and last_modes[key] ~= mode then
    pcall(vim.api.nvim_echo, { { mode, "ModeMsg" } }, false, {})
  end
  last_modes[key] = mode
end

function M.clear(kind, buffer)
  local key = kind == "cmdline" and "cmdline" or tostring(buffer)
  close_float(key)
  last_modes[key] = nil
  if buffer and vim.api.nvim_buf_is_valid(buffer) then
    vim.api.nvim_buf_clear_namespace(buffer, namespace, 0, -1)
  end
end

function M.clear_all()
  for key in pairs(floats) do
    close_float(key)
  end
end

return M
