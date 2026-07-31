local compiler = require("skk_lite.compiler")
local dictionary = require("skk_lite.dictionary")
local register = require("skk_lite.register")
local Session = require("skk_lite.session")
local store = require("skk_lite.store")
local ui = require("skk_lite.ui")

local M = {}

local default_dictionary_dir = vim.fs.joinpath(vim.fn.stdpath("data"), "skk-lite", "dictionary")

local config = {
  dictionary_dir = default_dictionary_dir,
  dictionary_path = vim.fs.joinpath(default_dictionary_dir, "dictionary.json"),
  dictionary_encoding = "auto",
  dictionary_files = nil,
  state_path = nil,
  mappings = true,
}

local sessions = {}
local commandline_session = nil
local suspended_buffers = {}
local commandline_suspended = false
local configured = false

local function buffer_session(buffer)
  buffer = buffer or vim.api.nvim_get_current_buf()
  if not sessions[buffer] then
    sessions[buffer] = Session.new(dictionary)
  end
  return sessions[buffer]
end

local function get_session(kind, buffer)
  if kind == "cmdline" then
    if not commandline_session then
      commandline_session = Session.new(dictionary)
    end
    return commandline_session
  end
  return buffer_session(buffer)
end

local function native_key(value)
  return vim.api.nvim_replace_termcodes(value, true, false, true)
end

local function insert_at_cursor(text)
  if text == "" then
    return
  end
  vim.api.nvim_put({ text }, "c", true, true)
end

local function render_later(session, kind, buffer)
  vim.schedule(function()
    if kind == "insert" and (not buffer or not vim.api.nvim_buf_is_valid(buffer)) then
      return
    end
    ui.render(session, kind, buffer)
  end)
end

local function splice_commandline(context, inserted_text)
  inserted_text = inserted_text or ""
  local before = context.line:sub(1, context.position - 1)
  local after = context.line:sub(context.position)
  return before .. inserted_text .. after, context.position + #inserted_text
end

local function restore_commandline(context, inserted_text)
  if not context then
    return
  end
  local line, position = splice_commandline(context, inserted_text)
  local opener = ({ [":"] = ":", ["/"] = "/", ["?"] = "?" })[context.type] or ":"
  vim.api.nvim_feedkeys(native_key(opener), "n", false)
  local attempts = 0
  local function apply()
    attempts = attempts + 1
    if vim.fn.getcmdtype() ~= "" then
      vim.fn.setcmdline(line)
      vim.fn.setcmdpos(position)
    elseif attempts < 20 then
      vim.defer_fn(apply, 10)
    end
  end
  vim.defer_fn(apply, 10)
end

local function open_registration(session, reading, kind, buffer, commandline_context)
  if kind == "insert" and buffer then
    suspended_buffers[buffer] = true
  elseif kind == "cmdline" then
    commandline_suspended = true
  end
  vim.schedule(function()
    if kind == "insert" and (not buffer or not vim.api.nvim_buf_is_valid(buffer)) then
      suspended_buffers[buffer] = nil
      return
    end
    local register_buffer = register.open({
      reading = reading,
      prepare = function(register_buffer)
        local nested = buffer_session(register_buffer)
        if nested.state.composing or nested.state.roman ~= "" then
          local result
          if nested.state.composing then
            result = nested:handle("Enter")
          else
            result = nested:handle("l")
          end
          insert_at_cursor(result.insert)
          ui.render(nested, "insert", register_buffer)
          return false
        end
        return true
      end,
      on_accept = function(text)
        if kind == "insert" then
          suspended_buffers[buffer] = nil
        else
          commandline_suspended = false
        end
        local result = session:register_word(text)
        if kind == "cmdline" then
          restore_commandline(commandline_context, result.insert)
        else
          insert_at_cursor(result.insert)
          if kind == "insert" then
            vim.cmd("startinsert")
          end
        end
        render_later(session, kind, buffer)
      end,
      on_cancel = function()
        if kind == "insert" then
          suspended_buffers[buffer] = nil
        else
          commandline_suspended = false
        end
        session:cancel_registration()
        if kind == "cmdline" then
          restore_commandline(commandline_context, "")
        end
        render_later(session, kind, buffer)
      end,
    })
    if register_buffer and vim.api.nvim_buf_is_valid(register_buffer) then
      local nested = buffer_session(register_buffer)
      nested:enable()
      ui.render(nested, "insert", register_buffer)
    end
  end)
end

function M._handle(kind, key, modifiers, fallback)
  local buffer = kind == "insert" and vim.api.nvim_get_current_buf() or nil
  local session = get_session(kind, buffer)
  local commandline_context = kind == "cmdline" and {
    type = vim.fn.getcmdtype(),
    line = vim.fn.getcmdline(),
    position = vim.fn.getcmdpos(),
  } or nil
  local result = session:handle(key, modifiers)
  render_later(session, kind, buffer)
  if result.register then
    if kind == "insert" and vim.bo[buffer].filetype == "skk-lite-register" then
      session:decline_nested_registration()
      vim.schedule(function()
        vim.notify("skk-lite: 登録欄内の変換候補がありません", vim.log.levels.WARN)
      end)
    else
      open_registration(session, result.register, kind, buffer, commandline_context)
      if kind == "cmdline" then
        return native_key("<C-c>")
      end
    end
  end

  local output = result.insert or ""
  if key == "Escape" then
    ui.clear(kind, buffer)
    return output .. native_key(fallback)
  end
  if not result.handled then
    return output .. native_key(fallback)
  end
  return output ~= "" and output or native_key("<Ignore>")
end

local commandline_mappings_installed = false
local install_commandline_mappings
local remove_commandline_mappings

local function each_mapping(callback)
  for byte = 32, 126 do
    local key = string.char(byte)
    local lhs = key
    local fallback = key
    if key == " " then
      lhs = "<Space>"
      fallback = "<Space>"
    elseif key == "<" then
      lhs = "<lt>"
    end
    callback(lhs, key, {}, fallback)
  end
  callback("<BS>", "Backspace", {}, "<BS>")
  callback("<CR>", "Enter", {}, "<CR>")
  callback("<Esc>", "Escape", {}, "<Esc>")
  callback("<Tab>", "Tab", {}, "<Tab>")
  callback("<C-j>", "j", { ctrl = true }, "<C-j>")
  callback("<C-g>", "g", { ctrl = true }, "<C-g>")
  callback("<C-q>", "q", { ctrl = true }, "<C-q>")
end

local function set_mapping(mode, lhs, key, modifiers, fallback)
  local kind = mode == "i" and "insert" or "cmdline"
  vim.keymap.set(mode, lhs, function()
    return M._handle(kind, key, modifiers, fallback or lhs)
  end, {
    expr = true,
    replace_keycodes = false,
    silent = true,
    desc = "skk-lite: " .. key,
  })
end

local function install_commandline_toggle()
  vim.keymap.set("c", "<C-j>", function()
    local output = M._handle("cmdline", "j", { ctrl = true }, "<C-j>")
    if get_session("cmdline").state.enabled then
      install_commandline_mappings()
    end
    return output
  end, {
    expr = true,
    replace_keycodes = false,
    silent = true,
    desc = "skk-lite: enable command-line SKK",
  })
end

install_commandline_mappings = function()
  if commandline_mappings_installed then
    return
  end
  each_mapping(function(lhs, key, modifiers, fallback)
    set_mapping("c", lhs, key, modifiers, fallback)
  end)
  commandline_mappings_installed = true
end

remove_commandline_mappings = function()
  if commandline_mappings_installed then
    each_mapping(function(lhs)
      pcall(vim.keymap.del, "c", lhs)
    end)
    commandline_mappings_installed = false
  end
  install_commandline_toggle()
end

local function install_mappings()
  each_mapping(function(lhs, key, modifiers, fallback)
    set_mapping("i", lhs, key, modifiers, fallback)
  end)
  install_commandline_toggle()
end

function M.enable(kind)
  kind = kind or (vim.fn.getcmdtype() ~= "" and "cmdline" or "insert")
  local buffer = kind == "insert" and vim.api.nvim_get_current_buf() or nil
  local session = get_session(kind, buffer)
  session:enable()
  if kind == "cmdline" and config.mappings then
    install_commandline_mappings()
  end
  ui.render(session, kind, buffer)
end

function M.disable(kind)
  kind = kind or (vim.fn.getcmdtype() ~= "" and "cmdline" or "insert")
  local buffer = kind == "insert" and vim.api.nvim_get_current_buf() or nil
  local session = get_session(kind, buffer)
  session:disable()
  if kind == "cmdline" and config.mappings then
    remove_commandline_mappings()
  end
  ui.clear(kind, buffer)
end

function M.toggle()
  local kind = vim.fn.getcmdtype() ~= "" and "cmdline" or "insert"
  local buffer = kind == "insert" and vim.api.nvim_get_current_buf() or nil
  local session = get_session(kind, buffer)
  if session.state.enabled then
    M.disable(kind)
  else
    M.enable(kind)
  end
end

function M.status()
  local kind = vim.fn.getcmdtype() ~= "" and "cmdline" or "insert"
  local buffer = kind == "insert" and vim.api.nvim_get_current_buf() or nil
  return get_session(kind, buffer):mode_text()
end

function M.health()
  local stats = dictionary.stats()
  local lines = {
    "skk-lite.nvim",
    "  dictionary_dir: " .. tostring(config.dictionary_dir),
    "  dictionary: " .. tostring(stats.path),
    "  exists: " .. tostring(vim.uv.fs_stat(stats.path) ~= nil),
    "  loaded: " .. tostring(stats.loaded),
    "  load_ms: " .. tostring(stats.load_ms or "-") ,
    "  state: " .. tostring(store.path()),
  }
  vim.notify(table.concat(lines, "\n"), stats.load_error and vim.log.levels.ERROR or vim.log.levels.INFO)
  return stats
end

local function use_dictionary_directory(directory)
  if directory and directory ~= "" then
    config.dictionary_dir = vim.fs.normalize(vim.fn.expand(directory))
    config.dictionary_path = vim.fs.joinpath(config.dictionary_dir, "dictionary.json")
  else
    config.dictionary_dir = vim.fs.normalize(vim.fn.expand(config.dictionary_dir))
  end
end

function M.compile_dictionary(directory)
  use_dictionary_directory(directory)
  local result = compiler.compile({
    directory = config.dictionary_dir,
    output_path = config.dictionary_path,
    encoding = config.dictionary_encoding,
    files = config.dictionary_files,
  })
  dictionary.setup({ path = config.dictionary_path, store = store })
  vim.notify(
    ("skk-lite: 辞書を生成しました\n%s\n%d sources / %d keys / %d candidates"):format(
      result.output_path,
      #result.source_files,
      result.keys,
      result.candidates
    ),
    vim.log.levels.INFO
  )
  return result
end

function M.download_dictionary(directory)
  use_dictionary_directory(directory)
  local node = vim.fn.exepath("node")
  if node == "" then
    vim.notify("skk-lite: node が見つかりません", vim.log.levels.ERROR)
    return nil
  end
  local scripts = vim.api.nvim_get_runtime_file("scripts/download_dictionary.js", false)
  if #scripts == 0 then
    vim.notify("skk-lite: download_dictionary.js が見つかりません", vim.log.levels.ERROR)
    return nil
  end
  vim.fn.mkdir(config.dictionary_dir, "p")
  vim.notify("skk-lite: 辞書をダウンロードしています: " .. config.dictionary_dir, vim.log.levels.INFO)
  return vim.system({ node, scripts[1], "--output", config.dictionary_dir }, { text = true }, vim.schedule_wrap(function(result)
    if result.code == 0 then
      vim.notify("skk-lite: 辞書をダウンロードしました。:SkkLiteCompileDictionary を実行してください", vim.log.levels.INFO)
    else
      local message = vim.trim(result.stderr or result.stdout or "download failed")
      vim.notify("skk-lite: 辞書のダウンロードに失敗しました: " .. message, vim.log.levels.ERROR)
    end
  end))
end

function M.setup(options)
  if configured then
    return
  end
  configured = true
  options = options or {}
  config = vim.tbl_deep_extend("force", config, options)
  config.dictionary_dir = vim.fs.normalize(vim.fn.expand(config.dictionary_dir))
  if options.dictionary_path == nil then
    config.dictionary_path = vim.fs.joinpath(config.dictionary_dir, "dictionary.json")
  else
    config.dictionary_path = vim.fs.normalize(vim.fn.expand(config.dictionary_path))
  end
  store.setup({ path = config.state_path })
  dictionary.setup({ path = config.dictionary_path, store = store })
  ui.setup()
  if config.mappings then
    install_mappings()
  end

  vim.api.nvim_create_user_command("SkkLiteEnable", function()
    M.enable()
  end, {})
  vim.api.nvim_create_user_command("SkkLiteDisable", function()
    M.disable()
  end, {})
  vim.api.nvim_create_user_command("SkkLiteToggle", function()
    M.toggle()
  end, {})
  vim.api.nvim_create_user_command("SkkLiteHealth", function()
    M.health()
  end, {})
  vim.api.nvim_create_user_command("SkkLiteDownloadDictionary", function(command)
    M.download_dictionary(command.args ~= "" and command.args or nil)
  end, { nargs = "?", complete = "dir" })
  vim.api.nvim_create_user_command("SkkLiteCompileDictionary", function(command)
    local ok, result = pcall(M.compile_dictionary, command.args ~= "" and command.args or nil)
    if not ok then
      vim.notify("skk-lite: 辞書を生成できません: " .. tostring(result), vim.log.levels.ERROR)
    end
  end, { nargs = "?", complete = "dir" })

  local group = vim.api.nvim_create_augroup("skk_lite", { clear = true })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(event)
      sessions[event.buf] = nil
      ui.clear("insert", event.buf)
    end,
  })
  vim.api.nvim_create_autocmd("InsertLeave", {
    group = group,
    callback = function(event)
      local session = sessions[event.buf]
      if session and not suspended_buffers[event.buf] then
        session:clear_composition()
      end
      if not suspended_buffers[event.buf] then
        ui.clear("insert", event.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd("CmdlineLeave", {
    group = group,
    callback = function()
      if commandline_session and not commandline_suspended then
        -- Each new command line starts in native ASCII mode.  Keeping the
        -- previous kana mode makes commands such as :write look like SKK
        -- input after Japanese search/command-line entry.
        commandline_session:disable()
        if config.mappings then
          remove_commandline_mappings()
        end
      end
      if not commandline_suspended then
        ui.clear("cmdline")
      end
    end,
  })
end

M._buffer_session = buffer_session
M._commandline_session = function()
  return get_session("cmdline")
end
M._splice_commandline = splice_commandline
M.dictionary_dir = function()
  return config.dictionary_dir
end

return M
