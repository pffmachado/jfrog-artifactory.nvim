if vim.g.loaded_jfrog_artifacts == 1 then
  return
end
vim.g.loaded_jfrog_artifacts = 1

require("jfrog_artifacts").setup()
