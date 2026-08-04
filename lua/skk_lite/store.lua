local M = {}

local state = {
  path = nil,
  data = { user_dict = {}, history = {} },
  dirty = false,
  timer = nil,
  save_delay = 200,
  temporary_index = 0,
}

local function default_path()
  return vim.fs.joinpath(vim.fn.stdpath("data"), "skk-lite", "state.json")
end

local function normalize_map(value)
  if type(value) ~= "table" then
    return {}
  end
  local result = {}
  for key, candidates in pairs(value) do
    if type(key) == "string" and type(candidates) == "table" then
      result[key] = {}
      for _, candidate in ipairs(candidates) do
        if type(candidate) == "string" and candidate ~= "" then
          table.insert(result[key], candidate)
        end
      end
      if #result[key] == 0 then
        result[key] = nil
      end
    end
  end
  return result
end

function M.setup(options)
  options = options or {}
  if state.dirty then
    M.flush()
  end
  state.path = vim.fs.normalize(vim.fn.expand(options.path or default_path()))
  state.data = { user_dict = {}, history = {} }
  state.save_delay = options.save_delay or 200
  M.load()

  local group = vim.api.nvim_create_augroup("skk_lite_store", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      M.flush()
    end,
  })
end

function M.load()
  if not state.path then
    state.path = default_path()
  end
  local file = io.open(state.path, "rb")
  if not file then
    return state.data
  end
  local content = file:read("*a")
  file:close()
  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= "table" then
    vim.notify("skk-lite: 学習データを読み込めません: " .. state.path, vim.log.levels.WARN)
    return state.data
  end
  state.data.user_dict = normalize_map(decoded.user_dict)
  state.data.history = normalize_map(decoded.history)
  return state.data
end

local function stop_timer()
  if state.timer then
    state.timer:stop()
    if not state.timer:is_closing() then
      state.timer:close()
    end
    state.timer = nil
  end
end

local function write_atomic()
  if not state.path then
    state.path = default_path()
  end
  vim.fn.mkdir(vim.fs.dirname(state.path), "p")
  local encoded = vim.json.encode(state.data)
  state.temporary_index = state.temporary_index + 1
  local temporary_path = ("%s.tmp.%d.%d"):format(state.path, vim.fn.getpid(), state.temporary_index)
  local file, error_message = io.open(temporary_path, "wb")
  if not file then
    vim.notify("skk-lite: 学習データを保存できません: " .. tostring(error_message), vim.log.levels.ERROR)
    return false
  end
  local wrote, write_error = file:write(encoded)
  local closed, close_error = file:close()
  if not wrote or not closed then
    os.remove(temporary_path)
    vim.notify(
      "skk-lite: 学習データを保存できません: " .. tostring(write_error or close_error),
      vim.log.levels.ERROR
    )
    return false
  end
  local renamed, rename_error = vim.uv.fs_rename(temporary_path, state.path)
  if not renamed then
    os.remove(temporary_path)
    vim.notify("skk-lite: 学習データを保存できません: " .. tostring(rename_error), vim.log.levels.ERROR)
    return false
  end
  return true
end

function M.flush()
  stop_timer()
  if not state.dirty then
    return true
  end
  local saved = write_atomic()
  if saved then
    state.dirty = false
  end
  return saved
end

function M.save()
  state.dirty = true
  stop_timer()
  state.timer = vim.defer_fn(function()
    state.timer = nil
    M.flush()
  end, state.save_delay)
  return true
end

function M.data()
  return state.data
end

function M.path()
  return state.path
end

return M
