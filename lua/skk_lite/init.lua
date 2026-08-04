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
  state_save_delay = 200,
  mappings = true,
}

local sessions = {}
local commandline_session = nil
local commandline_preedit = ""
local suspended_buffers = {}
local commandline_suspended = false
local configured = false
local sync_insert_mappings

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

local function commandline_delta(previous, committed, current)
  return native_key(("<BS>"):rep(vim.fn.strchars(previous))) .. committed .. current
end

local function commandline_context_without_preedit(context, preedit)
  if preedit == "" then
    return context
  end
  local before = context.line:sub(1, context.position - 1)
  if before:sub(-#preedit) ~= preedit then
    return context
  end
  context.line = before:sub(1, #before - #preedit) .. context.line:sub(context.position)
  context.position = context.position - #preedit
  return context
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
  -- Registration is accepted from an insert-mode mapping. Force Normal mode
  -- before reopening the original command line, otherwise the opener can be
  -- inserted into the buffer instead of starting :, /, or ? input.
  vim.api.nvim_feedkeys(native_key("<C-\\><C-n>" .. opener), "n", false)
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
    -- The candidate list that led to registration belongs to the suspended
    -- outer session.  Remove it before opening the registration window so it
    -- cannot remain behind the window or reappear on the next input.
    ui.clear(kind, buffer)
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
        -- Registration clears the outer composition.  Clear its extmark
        -- synchronously as well; waiting for the scheduled render can leave
        -- the old ▽ preedit visible after the registered word was inserted.
        ui.clear(kind, buffer)
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
      sync_insert_mappings(register_buffer, true)
      ui.render(nested, "insert", register_buffer)
    end
  end)
end

function M._handle(kind, key, modifiers, fallback)
  local buffer = kind == "insert" and vim.api.nvim_get_current_buf() or nil
  local session = get_session(kind, buffer)
  local previous_commandline_preedit = kind == "cmdline" and commandline_preedit or ""
  if kind == "cmdline" and key == "Escape" and previous_commandline_preedit ~= "" then
    session:clear_composition()
    commandline_preedit = ""
    ui.clear(kind, buffer)
    return commandline_delta(previous_commandline_preedit, "", "")
  end
  local commandline_context = kind == "cmdline" and {
    type = vim.fn.getcmdtype(),
    line = vim.fn.getcmdline(),
    position = vim.fn.getcmdpos(),
  } or nil
  if commandline_context then
    commandline_context = commandline_context_without_preedit(commandline_context, previous_commandline_preedit)
  end
  local result = session:handle(key, modifiers)
  if kind == "insert" and sync_insert_mappings then
    sync_insert_mappings(buffer, session.state.enabled)
  end
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
        commandline_preedit = ""
        return native_key("<C-c>")
      end
    end
  end

  local output = result.insert or ""
  if kind == "cmdline" then
    commandline_preedit = session:preedit()
    output = commandline_delta(previous_commandline_preedit, output, commandline_preedit)
  end
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
local commandline_saved_mappings = {}
local insert_mapping_states = {}
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

local function set_mapping(mode, lhs, key, modifiers, fallback, buffer)
  local kind = mode == "i" and "insert" or "cmdline"
  if kind == "cmdline" then
    vim.keymap.set(mode, lhs, function()
      local output = M._handle(kind, key, modifiers, fallback or lhs)
      if output ~= "" then
        -- Match skkeleton's command-line strategy: feed the rewritten
        -- preedit as typed input so external cmdline UIs receive updates.
        vim.fn.feedkeys(output, "nit")
      end
    end, {
      silent = true,
      desc = "skk-lite: " .. key,
    })
    return
  end
  vim.keymap.set(mode, lhs, function()
    return M._handle(kind, key, modifiers, fallback or lhs)
  end, {
    buffer = buffer,
    expr = true,
    replace_keycodes = false,
    silent = true,
    desc = "skk-lite: " .. key,
  })
end

local function mapping_for(mode, lhs, buffer)
  local mapping
  local function read()
    mapping = vim.fn.maparg(lhs, mode, false, true)
  end
  if buffer then
    vim.api.nvim_buf_call(buffer, read)
    if type(mapping) ~= "table" or mapping.buffer ~= 1 then
      return false
    end
  else
    read()
    if type(mapping) ~= "table" or mapping.buffer == 1 then
      return false
    end
  end
  return mapping.lhs and mapping.lhs ~= "" and vim.deepcopy(mapping) or false
end

local function restore_mapping(mode, lhs, saved, buffer)
  pcall(vim.keymap.del, mode, lhs, buffer and { buffer = buffer } or {})
  if saved then
    local function restore()
      vim.fn.mapset(mode, 0, saved)
    end
    if buffer and vim.api.nvim_buf_is_valid(buffer) then
      vim.api.nvim_buf_call(buffer, restore)
    elseif not buffer then
      restore()
    end
  end
end

local function take_commandline_mapping(lhs)
  if commandline_saved_mappings[lhs] == nil then
    commandline_saved_mappings[lhs] = mapping_for("c", lhs)
  end
end

local function restore_commandline_mapping(lhs)
  local saved = commandline_saved_mappings[lhs]
  if saved ~= nil then
    restore_mapping("c", lhs, saved)
    commandline_saved_mappings[lhs] = nil
  end
end

local function insert_mapping_state(buffer)
  local current = insert_mapping_states[buffer]
  if not current then
    current = { active = false, saved = {} }
    insert_mapping_states[buffer] = current
  end
  return current
end

local function take_insert_mapping(buffer, lhs)
  local current = insert_mapping_state(buffer)
  if current.saved[lhs] == nil then
    current.saved[lhs] = mapping_for("i", lhs, buffer)
  end
end

local function restore_insert_mapping(buffer, lhs)
  local current = insert_mapping_states[buffer]
  if not current or current.saved[lhs] == nil then
    return
  end
  restore_mapping("i", lhs, current.saved[lhs], buffer)
  current.saved[lhs] = nil
end

local function install_insert_toggle(buffer)
  if not vim.api.nvim_buf_is_valid(buffer) then
    return
  end
  take_insert_mapping(buffer, "<C-j>")
  set_mapping("i", "<C-j>", "j", { ctrl = true }, "<C-j>", buffer)
end

local function install_insert_mappings(buffer)
  local current = insert_mapping_state(buffer)
  if current.active then
    return
  end
  local registration_buffer = vim.bo[buffer].filetype == "skk-lite-register"
  each_mapping(function(lhs, key, modifiers, fallback)
    -- The registration UI owns Enter/Escape/Ctrl-G so it can first commit
    -- pending composition and then accept or cancel the registered word.
    if not registration_buffer or (lhs ~= "<CR>" and lhs ~= "<Esc>" and lhs ~= "<C-g>") then
      take_insert_mapping(buffer, lhs)
      set_mapping("i", lhs, key, modifiers, fallback, buffer)
    end
  end)
  current.active = true
end

local function remove_insert_mappings(buffer, keep_toggle)
  local current = insert_mapping_states[buffer]
  if not current then
    return
  end
  each_mapping(function(lhs)
    restore_insert_mapping(buffer, lhs)
  end)
  current.active = false
  if keep_toggle and vim.api.nvim_buf_is_valid(buffer) then
    install_insert_toggle(buffer)
  elseif not next(current.saved) then
    insert_mapping_states[buffer] = nil
  end
end

sync_insert_mappings = function(buffer, enabled)
  if not config.mappings or not buffer then
    return
  end
  if enabled then
    install_insert_mappings(buffer)
  else
    remove_insert_mappings(buffer, true)
  end
end

local function install_commandline_toggle()
  take_commandline_mapping("<C-j>")
  vim.keymap.set("c", "<C-j>", function()
    local output = M._handle("cmdline", "j", { ctrl = true }, "<C-j>")
    if get_session("cmdline").state.enabled then
      install_commandline_mappings()
    end
    if output ~= "" then
      vim.fn.feedkeys(output, "nit")
    end
  end, {
    silent = true,
    desc = "skk-lite: enable command-line SKK",
  })
end

install_commandline_mappings = function()
  if commandline_mappings_installed then
    return
  end
  each_mapping(function(lhs, key, modifiers, fallback)
    take_commandline_mapping(lhs)
    set_mapping("c", lhs, key, modifiers, fallback)
  end)
  commandline_mappings_installed = true
end

remove_commandline_mappings = function()
  if commandline_mappings_installed then
    each_mapping(function(lhs)
      restore_commandline_mapping(lhs)
    end)
    commandline_mappings_installed = false
  end
  install_commandline_toggle()
end

local function install_mappings(buffer)
  buffer = buffer or vim.api.nvim_get_current_buf()
  local session = sessions[buffer]
  if session and session.state.enabled then
    install_insert_mappings(buffer)
  else
    install_insert_toggle(buffer)
  end
  if commandline_session and commandline_session.state.enabled then
    install_commandline_mappings()
  else
    install_commandline_toggle()
  end
end

local function remove_all_mappings()
  local buffers = vim.tbl_keys(insert_mapping_states)
  for _, buffer in ipairs(buffers) do
    if vim.api.nvim_buf_is_valid(buffer) then
      remove_insert_mappings(buffer, false)
    else
      insert_mapping_states[buffer] = nil
    end
  end
  if commandline_mappings_installed then
    each_mapping(function(lhs)
      restore_commandline_mapping(lhs)
    end)
    commandline_mappings_installed = false
  else
    restore_commandline_mapping("<C-j>")
  end
end

function M.enable(kind)
  kind = kind or (vim.fn.getcmdtype() ~= "" and "cmdline" or "insert")
  local buffer = kind == "insert" and vim.api.nvim_get_current_buf() or nil
  local session = get_session(kind, buffer)
  session:enable()
  if kind == "insert" and config.mappings then
    install_insert_mappings(buffer)
  end
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
  if kind == "insert" and config.mappings then
    remove_insert_mappings(buffer, true)
  end
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

local function dictionary_sources()
  local paths = vim.api.nvim_get_runtime_file("dictionary_sources.json", false)
  if #paths == 0 then
    return nil, "dictionary_sources.json が見つかりません"
  end
  local file, open_error = io.open(paths[1], "rb")
  if not file then
    return nil, open_error
  end
  local content = file:read("*a")
  file:close()
  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= "table" or type(decoded.sourceBaseUrl) ~= "string"
      or type(decoded.dictionaries) ~= "table" then
    return nil, "dictionary_sources.json が不正です"
  end
  for _, name in ipairs(decoded.dictionaries) do
    if type(name) ~= "string" or name == "" or vim.fs.basename(name) ~= name then
      return nil, "辞書名が不正です: " .. tostring(name)
    end
  end
  return decoded
end

function M.download_dictionary(directory, on_complete, on_error)
  use_dictionary_directory(directory)
  local curl = vim.fn.exepath("curl")
  if curl == "" then
    vim.notify("skk-lite: curl が見つかりません", vim.log.levels.ERROR)
    if on_error then
      on_error()
    end
    return nil
  end
  local sources, sources_error = dictionary_sources()
  if not sources then
    vim.notify("skk-lite: " .. tostring(sources_error), vim.log.levels.ERROR)
    if on_error then
      on_error()
    end
    return nil
  end
  vim.fn.mkdir(config.dictionary_dir, "p")
  vim.notify("skk-lite: 辞書をダウンロードしています: " .. config.dictionary_dir, vim.log.levels.INFO)
  local index = 0
  local current_job
  local function fail(message)
    vim.notify("skk-lite: 辞書のダウンロードに失敗しました: " .. message, vim.log.levels.ERROR)
    if on_error then
      on_error()
    end
  end
  local function download_next()
    index = index + 1
    local name = sources.dictionaries[index]
    if not name then
      if on_complete then
        on_complete()
      else
        vim.notify("skk-lite: 辞書をダウンロードしました。:SkkLiteCompileDictionary を実行してください", vim.log.levels.INFO)
      end
      return
    end
    local output_path = vim.fs.joinpath(config.dictionary_dir, name)
    local temporary_path = output_path .. ".tmp"
    local url = sources.sourceBaseUrl:gsub("/+$", "") .. "/" .. name
    current_job = vim.system({ curl, "--fail", "--location", "--silent", "--show-error", "--output", temporary_path, url }, {
      text = true,
    }, vim.schedule_wrap(function(download_result)
      if download_result.code ~= 0 then
        os.remove(temporary_path)
        fail(vim.trim(download_result.stderr or "curl failed"))
        return
      end
      local renamed, rename_error = vim.uv.fs_rename(temporary_path, output_path)
      if not renamed then
        os.remove(temporary_path)
        fail(tostring(rename_error))
        return
      end
      download_next()
    end))
  end
  download_next()
  return current_job
end

function M.install_dictionary(directory)
  return M.download_dictionary(directory, function()
    local ok, result = pcall(M.compile_dictionary)
    if not ok then
      vim.notify("skk-lite: 辞書を生成できません: " .. tostring(result), vim.log.levels.ERROR)
    end
  end)
end

function M.setup(options)
  local was_configured = configured
  if configured and config.mappings then
    remove_all_mappings()
  end
  configured = true
  options = options or {}
  config = vim.tbl_deep_extend("force", config, options)
  config.dictionary_dir = vim.fs.normalize(vim.fn.expand(config.dictionary_dir))
  if options.dictionary_dir ~= nil and options.dictionary_path == nil then
    config.dictionary_path = vim.fs.joinpath(config.dictionary_dir, "dictionary.json")
  elseif options.dictionary_path ~= nil then
    config.dictionary_path = vim.fs.normalize(vim.fn.expand(config.dictionary_path))
  else
    config.dictionary_path = vim.fs.normalize(vim.fn.expand(config.dictionary_path))
  end
  store.setup({ path = config.state_path, save_delay = config.state_save_delay })
  dictionary.setup({ path = config.dictionary_path, store = store })
  ui.setup()
  if config.mappings then
    install_mappings()
  end
  if was_configured then
    return
  end

  vim.api.nvim_create_user_command("SkkLiteEnable", function()
    M.enable()
  end, { force = true })
  vim.api.nvim_create_user_command("SkkLiteDisable", function()
    M.disable()
  end, { force = true })
  vim.api.nvim_create_user_command("SkkLiteToggle", function()
    M.toggle()
  end, { force = true })
  vim.api.nvim_create_user_command("SkkLiteHealth", function()
    M.health()
  end, { force = true })
  vim.api.nvim_create_user_command("SkkLiteDownloadDictionary", function(command)
    M.download_dictionary(command.args ~= "" and command.args or nil)
  end, { nargs = "?", complete = "dir", force = true })
  vim.api.nvim_create_user_command("SkkLiteInstallDictionary", function(command)
    M.install_dictionary(command.args ~= "" and command.args or nil)
  end, { nargs = "?", complete = "dir", force = true })
  vim.api.nvim_create_user_command("SkkLiteCompileDictionary", function(command)
    local ok, result = pcall(M.compile_dictionary, command.args ~= "" and command.args or nil)
    if not ok then
      vim.notify("skk-lite: 辞書を生成できません: " .. tostring(result), vim.log.levels.ERROR)
    end
  end, { nargs = "?", complete = "dir", force = true })

  local group = vim.api.nvim_create_augroup("skk_lite", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "VeryLazy",
    callback = function()
      if config.mappings then
        install_mappings()
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(event)
      sessions[event.buf] = nil
      insert_mapping_states[event.buf] = nil
      ui.clear("insert", event.buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(event)
      if config.mappings then
        local session = sessions[event.buf]
        if session and session.state.enabled then
          install_insert_mappings(event.buf)
        else
          install_insert_toggle(event.buf)
        end
      end
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
      commandline_preedit = ""
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
