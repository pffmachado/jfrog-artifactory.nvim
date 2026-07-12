local commands = require("jfrog_artifactory.commands")
local jfrog = require("jfrog_artifactory.jfrog")
local tree = require("jfrog_artifactory.tree")
local ui = require("jfrog_artifactory.ui")

local M = {
  opts = {
    default_project = nil,
    infer_project_from_git = true,
    jfrog_command = { "jf", "rt", "s" },
    jfrog_ping_command = { "jf", "rt", "ping" },
    jfrog_download_command = { "jf", "rt", "dl" },
    picker_backend = "telescope", -- telescope | snacks | vim_ui | auto
    download_root = ".jfrog",
    explorer = {
      width = 45,
    },
    on_select = nil,
  },
  state = {
    last_project = nil,
    last_items = nil,
  },
  _commands_setup = false,
}

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "jfrog-artifactory.nvim" })
end

local function select_item(item, opts)
  if opts.on_select then
    opts.on_select(item)
    return
  end

  vim.fn.setreg("+", item.full)
  notify("Copied: " .. item.full)
end

local function node_path(node)
  return tree.node_full_path(node)
end

local function ensure_authenticated(opts, callback)
  jfrog.ensure_authenticated(opts, function(ok, err)
    if ok then
      callback(true, nil)
      return
    end

    local message = (err or "JFrog CLI authentication required")
      .. ". Run `jf login` or configure with `jf c add`."
    notify(message, vim.log.levels.WARN)

    local answer = vim.fn.confirm("JFrog is not ready. Authenticate now?", "&Yes\n&No", 2)
    if answer == 1 then
      vim.cmd("botright 12split")
      vim.cmd("terminal jf login")
      vim.cmd("startinsert")
    end
    callback(false, message)
  end)
end

local function download_node(node, opts)
  local path = node_path(node)
  if path == "" then
    notify("Cannot download: empty artifact path", vim.log.levels.ERROR)
    return
  end

  local target_root = vim.fs.joinpath(vim.fn.getcwd(), opts.download_root or ".jfrog")
  vim.fn.mkdir(target_root, "p")

  local pattern = path
  if node.kind == "dir" then
    pattern = path .. "/**"
  end

  local function run_download()
    jfrog.download(pattern, target_root, opts, function(ok, err)
      if not ok then
        notify(err, vim.log.levels.ERROR)
        return
      end
      notify("Downloaded to " .. target_root .. ": " .. pattern)
    end)
  end

  ensure_authenticated(opts, function(ok, err)
    if not ok then
      return
    end
    run_download()
  end)
end

local function normalize_project(project)
  if not project then
    return nil
  end
  return project:gsub("^%s+", ""):gsub("%s+$", ""):gsub("/+$", "")
end

local function parse_owner_repo(value)
  if not value or value == "" then
    return nil
  end

  local cleaned = value:gsub("^%s+", ""):gsub("%s+$", "")
  cleaned = cleaned:gsub("%.git$", "")

  local owner, repo = cleaned:match("github%.com[:/]+([^/]+)/([^/]+)$")
  if owner and repo then
    return owner .. "/" .. repo
  end

  owner, repo = cleaned:match("([^/]+)/([^/]+)$")
  if owner and repo and owner ~= "" and repo ~= "" then
    return owner .. "/" .. repo
  end

  return nil
end

local function infer_project_from_cwd()
  local cwd = vim.fn.getcwd()

  local ok, result = pcall(function()
    return vim.system({ "git", "config", "--get", "remote.origin.url" }, { text = true }):wait()
  end)
  if ok and result and result.code == 0 then
    local inferred = parse_owner_repo(vim.trim(result.stdout or ""))
    if inferred then
      return inferred
    end
  end

  local parent = vim.fn.fnamemodify(cwd, ":h:t")
  local repo = vim.fn.fnamemodify(cwd, ":t")
  if parent ~= "" and repo ~= "" then
    return parent .. "/" .. repo
  end
  return nil
end

local function resolve_project(project, opts, state)
  return normalize_project(project)
    or state.last_project
    or normalize_project(opts.default_project)
    or (opts.infer_project_from_git and infer_project_from_cwd() or nil)
end

local function to_search_pattern(project)
  return project .. "/**"
end

local function normalize_item_full(full)
  return (full or ""):gsub('^"(.*)"[,]?$', "%1"):gsub("^/+", ""):gsub("/+$", "")
end

local function has_project_prefix(full, project)
  if full == project then
    return true
  end
  return vim.startswith(full, project .. "/")
end

local function build_tree_with_fallback(items, project)
  local root = tree.build(items, { base = project })
  if root and root.children and #root.children > 0 then
    return root
  end
  if #items > 0 then
    return tree.build(items, { base = "" })
  end
  return root
end

local function fetch_items(project, opts, state, callback)
  local resolved = resolve_project(project, opts, state)
  if not resolved or resolved == "" then
    callback(nil, "Provide a project like org/repo or set default_project in setup()")
    return
  end

  if state.last_project == resolved and state.last_items then
    callback(state.last_items, nil, resolved)
    return
  end

  ensure_authenticated(opts, function(auth_ok, auth_err)
    if not auth_ok then
      callback(nil, auth_err)
      return
    end

    jfrog.search(to_search_pattern(resolved), opts, function(items, err)
      if err then
        callback(nil, err)
        return
      end

      local filtered = {}
      for _, item in ipairs(items) do
        local full = normalize_item_full(item.full)
        item.full = full
        if has_project_prefix(full, resolved) then
          table.insert(filtered, item)
        end
      end

      if #filtered == 0 and #items > 0 then
        -- Keep data visible even when server output shape is unusual.
        filtered = items
      end

      state.last_project = resolved
      state.last_items = filtered
      callback(filtered, nil, resolved)
    end)
  end)
end

function M.search(project)
  fetch_items(project, M.opts, M.state, function(items, err, resolved)
    if err then
      notify(err, vim.log.levels.ERROR)
      return
    end

    local root = build_tree_with_fallback(items, resolved)
    ui.open(root, {
      width = M.opts.explorer.width,
      title = "JFrog: " .. resolved,
      on_select = function(item)
        select_item(item, M.opts)
      end,
      on_refresh = function()
        M.state.last_items = nil
        M.search(M.state.last_project)
      end,
      on_picker = function()
        M.browse(M.state.last_project)
      end,
    })
  end)
end

function M.browse(project)
  fetch_items(project, M.opts, M.state, function(items, err, resolved)
    if err then
      notify(err, vim.log.levels.ERROR)
      return
    end

    local root = build_tree_with_fallback(items, resolved)
    ui.pick_tree(root, {
      backend = M.opts.picker_backend,
      project = resolved,
      on_open_node = function(node, focus_node)
        ui.open_node_buffer(node, {
          project = resolved,
          path = node_path(node),
          title = "JFrog: " .. node_path(node),
          focus_node = focus_node,
          on_download = function(target_node)
            download_node(target_node, M.opts)
          end,
          on_copy = function(target_node)
            local path = node_path(target_node)
            vim.fn.setreg("+", path)
            notify("Copied: " .. path)
          end,
        })
      end,
      on_select = function(item)
        select_item(item, M.opts)
      end,
    })
  end)
end

function M.pick(project)
  fetch_items(project, M.opts, M.state, function(items, err)
    if err then
      notify(err, vim.log.levels.ERROR)
      return
    end

    ui.pick(
      items,
      function(item)
        select_item(item, M.opts)
      end,
      { backend = M.opts.picker_backend }
    )
  end)
end

function M.refresh()
  if not M.state.last_project then
    notify("No previous search. Run :JfArtifactsBrowse <project> first.", vim.log.levels.WARN)
    return
  end

  M.state.last_items = nil
  M.browse(M.state.last_project)
end

function M.setup(opts)
  M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})
  if not M._commands_setup then
    commands.setup(M)
    M._commands_setup = true
  end
end

return M
