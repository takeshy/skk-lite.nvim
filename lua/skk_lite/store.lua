local M = {}

local state = {
  path = nil,
  data = { user_dict = {}, history = {} },
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
  state.path = vim.fs.normalize(vim.fn.expand(options.path or default_path()))
  state.data = { user_dict = {}, history = {} }
  M.load()
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

function M.save()
  if not state.path then
    state.path = default_path()
  end
  vim.fn.mkdir(vim.fs.dirname(state.path), "p")
  local encoded = vim.json.encode(state.data)
  local file, error_message = io.open(state.path, "wb")
  if not file then
    vim.notify("skk-lite: 学習データを保存できません: " .. tostring(error_message), vim.log.levels.ERROR)
    return false
  end
  file:write(encoded)
  file:close()
  return true
end

function M.data()
  return state.data
end

function M.path()
  return state.path
end

return M
