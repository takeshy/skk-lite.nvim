local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(source))
vim.opt.runtimepath:append(root)

local output = arg[1]
if not output or output == "" then
  error("Usage: nvim --headless -u NONE -l scripts/download_dictionary.lua <directory>")
end

local completed = false
local successful = false
require("skk_lite").download_dictionary(output, function()
  successful = true
  completed = true
end, function()
  completed = true
end)

vim.wait(300000, function()
  return completed
end, 50)

if not successful then
  vim.cmd("cquit 1")
end
