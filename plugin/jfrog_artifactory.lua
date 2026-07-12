if vim.g.loaded_jfrog_artifactory == 1 then
  return
end
vim.g.loaded_jfrog_artifactory = 1

require("jfrog_artifactory").setup()
