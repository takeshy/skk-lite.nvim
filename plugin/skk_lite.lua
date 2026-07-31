if vim.g.loaded_skk_lite == 1 then
  return
end
vim.g.loaded_skk_lite = 1

require("skk_lite").setup()
