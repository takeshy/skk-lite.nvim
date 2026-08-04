local engine = require("skk_lite.engine")

local M = {}

local state = {
  path = nil,
  base = nil,
  load_error = nil,
  load_ms = nil,
  store = nil,
  cache = {},
}

local function default_path()
  return vim.fs.joinpath(vim.fn.stdpath("data"), "skk-lite", "dictionary", "dictionary.json")
end

local function word(candidate)
  return engine.candidate_word(candidate)
end

local function merge(lists)
  local result = {}
  local seen = {}
  for _, list in ipairs(lists) do
    for _, candidate in ipairs(list or {}) do
      local candidate_word = word(candidate)
      if candidate_word ~= "" and not seen[candidate_word] then
        seen[candidate_word] = true
        table.insert(result, candidate)
      end
    end
  end
  return result
end

local function load_base()
  if state.base then
    return true
  end
  if state.load_error then
    return false
  end
  local started = vim.uv.hrtime()
  local file, error_message = io.open(state.path, "rb")
  if not file then
    state.load_error = error_message or "file not found"
    return false
  end
  local content = file:read("*a")
  file:close()
  local ok, decoded = pcall(vim.json.decode, content)
  content = nil
  if not ok or type(decoded) ~= "table" then
    state.load_error = ok and "dictionary root is not an object" or decoded
    return false
  end
  state.base = decoded
  state.load_ms = (vim.uv.hrtime() - started) / 1e6
  return true
end

local function persistent_data()
  return state.store and state.store.data() or { user_dict = {}, history = {} }
end

local function clear_key(key)
  state.cache[key] = nil
end

local function lookup_cached(key)
  if state.cache[key] then
    return state.cache[key]
  end
  load_base()
  local data = persistent_data()
  local candidates = merge({
    data.history[key] or {},
    data.user_dict[key] or {},
    state.base and state.base[key] or {},
  })
  state.cache[key] = candidates
  return candidates
end

function M.setup(options)
  options = options or {}
  state.path = vim.fs.normalize(vim.fn.expand(options.path or default_path()))
  state.base = nil
  state.load_error = nil
  state.load_ms = nil
  state.cache = {}
  state.store = options.store
end

function M.load()
  local ok = load_base()
  if not ok then
    vim.notify(("skk-lite: 辞書を読み込めません: %s (%s)"):format(state.path, state.load_error), vim.log.levels.ERROR)
  end
  return ok
end

function M.lookup(key)
  -- Candidates are strings, so a shallow copy protects the cache without the
  -- recursive cost of vim.deepcopy() on every conversion.
  return vim.list_slice(lookup_cached(key))
end

function M.lookup_any(key_specs)
  local result = {}
  local seen = {}
  for _, spec in ipairs(key_specs) do
    for _, candidate in ipairs(lookup_cached(spec.key)) do
      local converted = spec.numbers and engine.apply_numeric_candidate(candidate, spec.numbers) or candidate
      local candidate_word = word(converted)
      if candidate_word ~= "" and not seen[candidate_word] then
        seen[candidate_word] = true
        table.insert(result, converted)
      end
    end
  end
  return result
end

function M.remember(key, candidate)
  if key == "" or candidate == "" or not state.store then
    return
  end
  local data = persistent_data()
  local next_candidates = { candidate }
  for _, existing in ipairs(data.history[key] or {}) do
    if existing ~= candidate and #next_candidates < 8 then
      table.insert(next_candidates, existing)
    end
  end
  data.history[key] = next_candidates
  clear_key(key)
  state.store.save()
end

function M.register(key, candidate)
  if key == "" or candidate == "" or not state.store then
    return false
  end
  local data = persistent_data()
  local next_candidates = { candidate }
  for _, existing in ipairs(data.user_dict[key] or {}) do
    if existing ~= candidate then
      table.insert(next_candidates, existing)
    end
  end
  data.user_dict[key] = next_candidates
  clear_key(key)
  return state.store.save()
end

function M.purge(key, candidate)
  if key == "" or candidate == "" or not state.store then
    return false
  end
  local data = persistent_data()
  for _, field in ipairs({ "history", "user_dict" }) do
    local next_candidates = {}
    for _, existing in ipairs(data[field][key] or {}) do
      if word(existing) ~= candidate then
        table.insert(next_candidates, existing)
      end
    end
    data[field][key] = #next_candidates > 0 and next_candidates or nil
  end
  clear_key(key)
  return state.store.save()
end

function M.completions(prefix)
  local data = persistent_data()
  local result = {}
  local seen = {}
  for _, field in ipairs({ data.history, data.user_dict }) do
    for key in pairs(field) do
      if key ~= prefix and key:sub(1, #prefix) == prefix and not key:find("[a-z>#]") and not seen[key] then
        seen[key] = true
        table.insert(result, key)
      end
    end
  end
  table.sort(result)
  return result
end

function M.stats()
  return {
    path = state.path,
    loaded = state.base ~= nil,
    load_error = state.load_error,
    load_ms = state.load_ms,
  }
end

M.merge = merge

return M
