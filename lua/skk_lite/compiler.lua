local M = {}

local function normalize(path)
  return vim.fs.normalize(vim.fn.expand(path))
end

local function is_absolute(path)
  return path:match("^%a:[/\\]") ~= nil or path:match("^[/\\][/\\]") ~= nil or path:sub(1, 1) == "/"
end

local function read_binary(path)
  local file, error_message = io.open(path, "rb")
  if not file then
    error(("辞書を開けません: %s (%s)"):format(path, error_message or "unknown error"))
  end
  local content = file:read("*a")
  file:close()
  return content
end

local function is_valid_utf8(content)
  local index = 1
  local length = #content
  local function continuation(position)
    local byte = content:byte(position)
    return byte and byte >= 0x80 and byte <= 0xbf
  end
  while index <= length do
    local first = content:byte(index)
    if first <= 0x7f then
      index = index + 1
    elseif first >= 0xc2 and first <= 0xdf and continuation(index + 1) then
      index = index + 2
    elseif first == 0xe0 then
      local second = content:byte(index + 1)
      if not second or second < 0xa0 or second > 0xbf or not continuation(index + 2) then
        return false
      end
      index = index + 3
    elseif (first >= 0xe1 and first <= 0xec) or (first >= 0xee and first <= 0xef) then
      if not continuation(index + 1) or not continuation(index + 2) then
        return false
      end
      index = index + 3
    elseif first == 0xed then
      local second = content:byte(index + 1)
      if not second or second < 0x80 or second > 0x9f or not continuation(index + 2) then
        return false
      end
      index = index + 3
    elseif first == 0xf0 then
      local second = content:byte(index + 1)
      if not second or second < 0x90 or second > 0xbf
          or not continuation(index + 2) or not continuation(index + 3) then
        return false
      end
      index = index + 4
    elseif first >= 0xf1 and first <= 0xf3 then
      if not continuation(index + 1) or not continuation(index + 2) or not continuation(index + 3) then
        return false
      end
      index = index + 4
    elseif first == 0xf4 then
      local second = content:byte(index + 1)
      if not second or second < 0x80 or second > 0x8f
          or not continuation(index + 2) or not continuation(index + 3) then
        return false
      end
      index = index + 4
    else
      return false
    end
  end
  return true
end

local function decode(content, encoding, path)
  encoding = (encoding or "auto"):lower():gsub("_", "-")
  if encoding == "utf-8" or encoding == "utf8" or (encoding == "auto" and is_valid_utf8(content)) then
    return content
  end
  local source_encoding = encoding == "auto" and "euc-jp" or encoding
  local converted = vim.fn.iconv(content, source_encoding, "utf-8")
  if content ~= "" and converted == "" then
    error(("文字コードを変換できません: %s (%s -> utf-8)"):format(path, source_encoding))
  end
  return converted
end

local function candidate_word(candidate)
  return candidate:match("^([^;]*)") or candidate
end

local function parse_dictionary(content, dictionary, seen_words)
  local added_keys = 0
  local added_candidates = 0
  for line in (content .. "\n"):gmatch("(.-)\n") do
    line = line:gsub("\r$", "")
    if line ~= "" and not line:match("^;;") then
      local reading, body = line:match("^(%S+)%s+/(.*)/%s*$")
      if reading and body then
        local bucket = dictionary[reading]
        if not bucket then
          bucket = {}
          dictionary[reading] = bucket
          seen_words[reading] = {}
          added_keys = added_keys + 1
        end
        for candidate in (body .. "/"):gmatch("(.-)/") do
          local word = candidate_word(candidate)
          if candidate ~= "" and word ~= "" and not seen_words[reading][word] then
            seen_words[reading][word] = true
            table.insert(bucket, candidate)
            added_candidates = added_candidates + 1
          end
        end
      end
    end
  end
  return added_keys, added_candidates
end

local function discover_files(directory)
  local files = {}
  local iterator = vim.fs.dir(directory)
  if not iterator then
    return files
  end
  for name, kind in iterator do
    if kind == "file" and name:match("^SKK%-JISYO") and not name:match("%.gz$") then
      table.insert(files, name)
    end
  end
  table.sort(files)
  return files
end

local function write_json(path, dictionary)
  local encoded = vim.json.encode(dictionary)
  local file, error_message = io.open(path, "wb")
  if not file then
    error(("JSONを書き込めません: %s (%s)"):format(path, error_message or "unknown error"))
  end
  file:write(encoded)
  file:close()
  return #encoded
end

function M.compile(options)
  options = options or {}
  assert(type(options.directory) == "string" and options.directory ~= "", "dictionary directory is required")
  local directory = normalize(options.directory)
  if not vim.uv.fs_stat(directory) then
    error("辞書ディレクトリがありません: " .. directory)
  end
  local files = options.files and vim.deepcopy(options.files) or discover_files(directory)
  if #files == 0 then
    error("SKK-JISYO* が見つかりません: " .. directory)
  end

  local dictionary = {}
  local seen_words = {}
  local source_stats = {}
  local total_candidates = 0
  for _, name in ipairs(files) do
    local path = is_absolute(name) and normalize(name) or vim.fs.joinpath(directory, name)
    local content = decode(read_binary(path), options.encoding, path)
    local added_keys, added_candidates = parse_dictionary(content, dictionary, seen_words)
    total_candidates = total_candidates + added_candidates
    table.insert(source_stats, {
      path = path,
      added_keys = added_keys,
      added_candidates = added_candidates,
    })
  end

  local output_path = normalize(options.output_path or vim.fs.joinpath(directory, "dictionary.json"))
  local bytes = write_json(output_path, dictionary)
  return {
    directory = directory,
    output_path = output_path,
    source_files = source_stats,
    keys = vim.tbl_count(dictionary),
    candidates = total_candidates,
    bytes = bytes,
  }
end

M._decode = decode
M._discover_files = discover_files
M._parse_dictionary = parse_dictionary

return M
