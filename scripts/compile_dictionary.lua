local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(source))
vim.opt.runtimepath:append(root)
package.path = vim.fs.joinpath(root, "lua", "?.lua") .. ";" .. vim.fs.joinpath(root, "lua", "?", "init.lua") .. ";" .. package.path

local directory = arg and arg[1] or nil
if not directory or directory == "" then
  directory = vim.env.SKK_LITE_DICTIONARY_DIR
end
if not directory or directory == "" then
  error("Usage: nvim --headless -u NONE -l scripts/compile_dictionary.lua <dictionary-directory>")
end

local result = require("skk_lite.compiler").compile({ directory = directory, encoding = "auto" })
print(("Wrote %s"):format(result.output_path))
print(("Sources: %d, keys: %d, candidates: %d, bytes: %d"):format(
  #result.source_files,
  result.keys,
  result.candidates,
  result.bytes
))
