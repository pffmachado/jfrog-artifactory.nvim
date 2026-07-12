local M = {}

function M.setup(api)
  vim.api.nvim_create_user_command("JfArtifactsBrowse", function(args)
    local project = args.args ~= "" and args.args or nil
    api.browse(project)
  end, {
    nargs = "?",
    desc = "Browse JFrog project with picker tree",
  })

  vim.api.nvim_create_user_command("JfArtifactsPicker", function(args)
    local project = args.args ~= "" and args.args or nil
    api.browse(project)
  end, {
    nargs = "?",
    desc = "Browse JFrog project with picker tree",
  })

  vim.api.nvim_create_user_command("JfArtifactsSearch", function(args)
    local project = args.args ~= "" and args.args or nil
    api.search(project)
  end, {
    nargs = "?",
    desc = "Browse JFrog project in vertical tree",
  })

  vim.api.nvim_create_user_command("JfArtifactsRefresh", function()
    api.refresh()
  end, {
    nargs = 0,
    desc = "Refresh last JFrog artifact search",
  })
end

return M
