local store = require("skk_lite.store")

local M = {}

local function equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error((message or "values differ") .. ("\nexpected: %s\nactual:   %s"):format(vim.inspect(expected), vim.inspect(actual)))
  end
end

function M.run(test)
  local path = vim.fn.tempname() .. ".json"
  store.setup({ path = path, save_delay = 60000 })

  test("save is debounced until flush", function()
    store.data().history["かな"] = { "仮名" }
    equal(store.save(), true)
    equal(vim.uv.fs_stat(path), nil)
    equal(store.flush(), true)
    assert(vim.uv.fs_stat(path), "state file was not flushed")
    local decoded = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
    equal(decoded.history["かな"], { "仮名" })
  end)

  test("atomic save leaves no temporary file", function()
    store.data().history["かな"] = { "かな" }
    store.save()
    equal(store.flush(), true)
    equal(vim.fn.glob(path .. ".tmp.*"), "")
  end)

  vim.fn.delete(path)
end

return M
