local M = {}

local active = nil

local function replace_unicode_escape(text)
  local before, code = text:match("^(.-)\\u([0-9a-fA-F]+)$")
  if not code then
    before, code = text:match("^(.-)¥u([0-9a-fA-F]+)$")
  end
  if not code then
    before, code = text:match("^(.-)￥u([0-9a-fA-F]+)$")
  end
  if not code then
    return text, false
  end
  local number = tonumber(code, 16)
  if #code > 6 or not number or number > 0x10ffff or (number >= 0xd800 and number <= 0xdfff) then
    return text, false, "Unicode の符号位置が不正です"
  end
  local ok, character = pcall(vim.fn.nr2char, number)
  if not ok then
    return text, false, "Unicode の符号位置が不正です"
  end
  return before .. character, true
end

local function close()
  if not active then
    return
  end
  local current = active
  active = nil
  if current.window and vim.api.nvim_win_is_valid(current.window) then
    vim.api.nvim_win_close(current.window, true)
  end
  if current.buffer and vim.api.nvim_buf_is_valid(current.buffer) then
    vim.api.nvim_buf_delete(current.buffer, { force = true })
  end
  if current.origin_window and vim.api.nvim_win_is_valid(current.origin_window) then
    vim.api.nvim_set_current_win(current.origin_window)
    pcall(vim.api.nvim_win_set_cursor, current.origin_window, current.origin_cursor)
  end
end

function M.open(options)
  if active then
    close()
  end
  local origin_window = vim.api.nvim_get_current_win()
  local origin_cursor = vim.api.nvim_win_get_cursor(origin_window)
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].filetype = "skk-lite-register"
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "" })
  local title = ("単語登録: %s"):format(options.reading)
  local width = math.min(math.max(40, vim.fn.strdisplaywidth(title) + 8), math.max(20, vim.o.columns - 6))
  local window = vim.api.nvim_open_win(buffer, true, {
    relative = "editor",
    row = math.max(1, math.floor((vim.o.lines - 3) / 2)),
    col = math.max(1, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = 1,
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "center",
  })
  active = {
    window = window,
    buffer = buffer,
    origin_window = origin_window,
    origin_cursor = origin_cursor,
  }

  local llm_ok, llm_rewrite = pcall(require, "llm_rewrite")

  local function suggest_with_llm()
    if not llm_ok or type(llm_rewrite.suggest) ~= "function" then
      return
    end
    local current = active
    vim.api.nvim_win_set_config(window, { title = " ⠋ LLM候補を取得中… ", title_pos = "center" })
    llm_rewrite.suggest(options.reading, function(candidates, err)
      if active ~= current or not vim.api.nvim_buf_is_valid(buffer) then
        return
      end
      vim.api.nvim_win_set_config(window, { title = " " .. title .. " ", title_pos = "center" })
      if err then
        vim.notify("skk-lite: LLM候補の取得に失敗しました: " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      vim.ui.select(candidates, { prompt = "単語登録: " .. options.reading }, function(choice)
        if choice and active == current and vim.api.nvim_buf_is_valid(buffer) then
          vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { choice })
          if vim.api.nvim_win_is_valid(window) then
            vim.api.nvim_set_current_win(window)
            vim.api.nvim_win_set_cursor(window, { 1, #choice })
            vim.cmd("startinsert")
          end
        end
      end)
    end)
  end

  local function cancel()
    close()
    if options.on_cancel then
      options.on_cancel()
    end
  end

  local function accept()
    if options.prepare and not options.prepare(buffer) then
      return
    end
    local text = table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
    local decoded, replaced, decode_error = replace_unicode_escape(text)
    if decode_error then
      vim.notify("skk-lite: " .. decode_error, vim.log.levels.WARN)
      return
    end
    if replaced then
      vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { decoded })
      vim.api.nvim_win_set_cursor(0, { 1, #decoded })
      return
    end
    text = vim.trim(text)
    if text == "" then
      vim.notify("skk-lite: 登録する文字を入力してください", vim.log.levels.WARN)
      return
    end
    close()
    options.on_accept(text)
  end

  vim.keymap.set("i", "<CR>", accept, { buffer = buffer, silent = true })
  vim.keymap.set("i", "<Esc>", cancel, { buffer = buffer, silent = true })
  vim.keymap.set("i", "<C-g>", cancel, { buffer = buffer, silent = true })
  if llm_ok and type(llm_rewrite.suggest) == "function" then
    vim.keymap.set({ "i", "n" }, "<C-l>", suggest_with_llm, {
      buffer = buffer,
      silent = true,
      desc = "skk-lite: get registration candidates from llm-rewrite",
    })
  end
  vim.keymap.set("n", "<CR>", accept, { buffer = buffer, silent = true })
  vim.keymap.set("n", "q", cancel, { buffer = buffer, silent = true })
  vim.keymap.set("n", "<C-g>", cancel, { buffer = buffer, silent = true })
  vim.cmd("startinsert")
  return buffer
end

function M.close()
  close()
end

function M.active()
  return active
end

M._replace_unicode_escape = replace_unicode_escape

return M
