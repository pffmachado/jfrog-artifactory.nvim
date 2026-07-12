local tree = require("jfrog_artifactory.tree")

local M = {}

local function branch_from_node(node, project)
  if node.item and node.item.branch and node.item.branch ~= "" then
    return node.item.branch
  end

  if node.kind == "dir" then
    local branches = {}
    local function add_branch(branch)
      if branch and branch ~= "" then
        branches[branch] = true
      end
    end

    local function walk(cur)
      for _, child in ipairs(cur.children or {}) do
        add_branch(child.item and child.item.branch or nil)
        if child.kind == "dir" then
          walk(child)
        end
      end
    end

    walk(node)
    local branch_names = vim.tbl_keys(branches)
    if #branch_names == 1 then
      return branch_names[1]
    end
    return nil
  end

  return nil
end

local function is_telescope_backend(backend)
  return backend == "telescope" or backend == "auto"
end

local function telescope_select(items, opts, on_choice)
  local ok_pickers, pickers = pcall(require, "telescope.pickers")
  local ok_finders, finders = pcall(require, "telescope.finders")
  local ok_conf, conf = pcall(require, "telescope.config")
  local ok_actions, actions = pcall(require, "telescope.actions")
  local ok_state, action_state = pcall(require, "telescope.actions.state")
  if not (ok_pickers and ok_finders and ok_conf and ok_actions and ok_state) then
    return false
  end

  local entries = {}
  for idx, item in ipairs(items) do
    entries[#entries + 1] = {
      value = item,
      idx = idx,
      display = tostring(item),
      ordinal = tostring(item),
    }
  end

  pickers
    .new({}, {
      prompt_title = opts.prompt or "Select",
      finder = finders.new_table({
        results = entries,
        entry_maker = function(entry)
          return entry
        end,
      }),
      sorter = conf.values.generic_sorter({}),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if selection then
            on_choice(selection.value, selection.idx)
          else
            on_choice(nil, nil)
          end
        end)
        return true
      end,
    })
    :find()

  return true
end

local function telescope_tree_select(entries, opts, on_choice, preview_lines_for)
  local ok_pickers, pickers = pcall(require, "telescope.pickers")
  local ok_finders, finders = pcall(require, "telescope.finders")
  local ok_conf, conf = pcall(require, "telescope.config")
  local ok_actions, actions = pcall(require, "telescope.actions")
  local ok_state, action_state = pcall(require, "telescope.actions.state")
  local ok_previewers, previewers = pcall(require, "telescope.previewers")
  if not (ok_pickers and ok_finders and ok_conf and ok_actions and ok_state and ok_previewers) then
    return false
  end

  local results = {}
  for idx, entry in ipairs(entries) do
    results[#results + 1] = {
      idx = idx,
      value = entry,
      display = entry.label,
      ordinal = entry.label,
    }
  end

  local previewer = previewers.new_buffer_previewer({
    define_preview = function(self, entry)
      local lines = preview_lines_for(entry and entry.value or nil)
      vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
    end,
  })

  pickers
    .new({}, {
      prompt_title = opts.prompt or "JFrog",
      finder = finders.new_table({
        results = results,
        entry_maker = function(entry)
          return entry
        end,
      }),
      sorter = conf.values.generic_sorter({}),
      previewer = previewer,
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if selection then
            on_choice(selection.value, selection.idx)
          else
            on_choice(nil, nil)
          end
        end)
        return true
      end,
    })
    :find()

  return true
end

local function select_items(items, opts, on_choice)
  opts = opts or {}
  local backend = opts.backend or "auto"

  if backend == "telescope" or backend == "auto" then
    if telescope_select(items, opts, on_choice) then
      return
    end
  end

  if backend == "snacks" or backend == "auto" then
    local ok, snacks = pcall(require, "snacks")
    if ok and snacks and snacks.picker and type(snacks.picker.select) == "function" then
      snacks.picker.select(items, opts, on_choice)
      return
    end
  end

  vim.ui.select(items, opts, on_choice)
end

local function configure_buffer(bufnr)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].filetype = "jfrog-artifactory"
end

local function set_scratch_name(bufnr, title)
  local clean = (title or "jfrog-artifactory")
    :gsub("[/\\]", " > ")
    :gsub("[%c]", " ")
    :gsub("%s+", " ")
    :gsub("^%s+", "")
    :gsub("%s+$", "")
  local unique = tostring(vim.loop.hrtime())
  local name = "jfrog-artifactory://" .. clean .. "#" .. unique
  pcall(vim.api.nvim_buf_set_name, bufnr, name)
end

local function set_lines(bufnr, lines)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
end

function M.pick(items, on_pick, opts)
  opts = opts or {}
  if #items == 0 then
    vim.notify("No artifacts found", vim.log.levels.INFO)
    return
  end

  local labels = {}
  for _, item in ipairs(items) do
    table.insert(labels, item.full)
  end

  select_items(labels, { prompt = "JFrog artifacts", backend = opts.backend }, function(_, idx)
    if idx and items[idx] then
      on_pick(items[idx])
    end
  end)
end

local function node_display_path(node)
  local parts = {}
  local cur = node
  while cur and cur.parent do
    table.insert(parts, 1, cur.name)
    cur = cur.parent
  end
  return cur and cur.name ~= "/" and (cur.name .. (#parts > 0 and "/" or "") .. table.concat(parts, "/")) or table.concat(parts, "/")
end

function M.pick_tree(root, opts)
  opts = opts or {}

  local function preview_for_entry(entry)
    if not entry then
      return { "No selection" }
    end
    if entry.kind == "up" then
      return { "Go to parent directory" }
    end
    if entry.kind == "dir" then
      local lines = {
        "Directory: " .. entry.node.name .. "/",
        "",
        "Contents:",
      }
      local children = entry.node.children or {}
      if #children == 0 then
        lines[#lines + 1] = "  (empty)"
      else
        for _, child in ipairs(children) do
          local icon = child.kind == "dir" and "[D]" or "[F]"
          lines[#lines + 1] = "  " .. icon .. " " .. child.name
        end
      end
      return lines
    end
    if entry.node and entry.node.item then
      local item = entry.node.item
      return {
        "Artifact",
        "",
        "Path: " .. (item.full or ""),
        "Repo: " .. (item.repo or ""),
        "Dir : " .. (item.path or ""),
        "Name: " .. (item.name or ""),
      }
    end
    return { "No preview available" }
  end

  local function open_node(node)
    local entries = {}
    if node.parent then
      entries[#entries + 1] = {
        kind = "up",
        label = "󰁍 ..",
      }
    end

    for _, child in ipairs(node.children or {}) do
      local branch = branch_from_node(child, opts.project)
      local suffix = branch and (" (" .. branch .. ")") or ""
      if child.kind == "dir" then
        entries[#entries + 1] = {
          kind = "dir",
          node = child,
          label = "󰉋 " .. child.name .. suffix,
        }
      else
        entries[#entries + 1] = {
          kind = "file",
          node = child,
          label = "󰈔 " .. child.name .. suffix,
        }
      end
    end

    if #entries == 0 then
      vim.notify("No artifacts found", vim.log.levels.INFO)
      return
    end

    local labels = {}
    for _, entry in ipairs(entries) do
      labels[#labels + 1] = entry.label
    end

    local function handle_selection(selected)
      if not selected then
        return
      end
      if selected.kind == "up" then
        open_node(node.parent)
        return
      end
      if selected.kind == "dir" then
        if opts.on_open_node then
          opts.on_open_node(selected.node)
          return
        end
        open_node(selected.node)
        return
      end
      if selected.node then
        if opts.on_open_node then
          opts.on_open_node(selected.node.parent or selected.node, selected.node)
          return
        end
      end
      if selected.node and selected.node.item and opts.on_select then
        opts.on_select(selected.node.item)
      end
    end

    if is_telescope_backend(opts.backend) then
      local used_telescope = telescope_tree_select(
        entries,
        { prompt = "JFrog: " .. node_display_path(node) },
        function(selected)
          handle_selection(selected)
        end,
        preview_for_entry
      )
      if used_telescope then
        return
      end
    end

    select_items(labels, { prompt = "JFrog: " .. node_display_path(node), backend = opts.backend }, function(_, idx)
      if not idx then
        return
      end
      handle_selection(entries[idx])
    end)
  end

  open_node(root)
end

function M.open_node_buffer(root_node, opts)
  opts = opts or {}
  vim.cmd("enew")
  local bufnr = vim.api.nvim_get_current_buf()
  configure_buffer(bufnr)
  set_scratch_name(bufnr, opts.title or ("JFrog: " .. (opts.path or root_node.name)))

  local ns = vim.api.nvim_create_namespace("jfrog_artifactory_buffer")
  local expanded_meta = {}
  local line_entries = {}

  local function setup_highlights()
    local diff = vim.api.nvim_get_hl(0, { name = "DiffAdded", link = false })
    vim.api.nvim_set_hl(0, "JfrogArtifactItem", {
      fg = diff and diff.fg or nil,
      bg = "NONE",
      bold = true,
    })
    vim.api.nvim_set_hl(0, "JfrogArtifactsHeader", {
      link = "Title",
    })
  end

  local function count_files(node)
    local total = 0
    local function walk(cur)
      for _, child in ipairs(cur.children or {}) do
        if child.kind == "file" then
          total = total + 1
        else
          walk(child)
        end
      end
    end
    walk(node)
    return total
  end

  local function item_meta_lines(item)
    local meta = {
      { "full", item.full },
      { "repo", item.repo },
      { "path", item.path },
      { "name", item.name },
      { "created", item.created },
      { "modified", item.modified },
      { "size", item.size },
      { "sha256", item.sha256 },
      { "sha1", item.sha1 },
      { "md5", item.md5 },
      { "type", item.type },
    }
    local lines = {}
    for _, kv in ipairs(meta) do
      if kv[2] and tostring(kv[2]) ~= "" then
        lines[#lines + 1] = kv[1] .. ": " .. tostring(kv[2])
      end
    end
    if #lines == 0 then
      return { "No metadata available" }
    end
    return lines
  end

  local function flatten_with_meta(node)
    local branch = branch_from_node(node, opts.project) or "-"
    local lines = {
      "Build Info",
      "Project : " .. (opts.project or "-"),
      "Branch  : " .. branch,
      "Path    : " .. (opts.path or tree.node_full_path(node)),
      "Files   : " .. tostring(count_files(node)),
      "Fetched : " .. os.date("%Y-%m-%d %H:%M:%S"),
      "",
      "Actions: <CR> expand/metadata | d download | y copy path | q close",
      "",
    }
    local entries = {}
    for _ = 1, #lines do
      entries[#entries + 1] = { kind = "header" }
    end

    local function walk(cur, depth)
      for _, child in ipairs(cur.children or {}) do
        local indent = string.rep("  ", depth)
        if child.kind == "dir" then
          local icon = child.expanded and "▾ " or "▸ "
          lines[#lines + 1] = indent .. icon .. child.name .. "/"
          entries[#entries + 1] = { node = child, kind = "node" }
          if child.expanded then
            walk(child, depth + 1)
          end
        else
          local opened = expanded_meta[child] and "▾ " or "▸ "
          lines[#lines + 1] = indent .. opened .. "● " .. child.name
          entries[#entries + 1] = { node = child, kind = "node" }

          if expanded_meta[child] then
            for _, meta_line in ipairs(item_meta_lines(child.item or {})) do
              lines[#lines + 1] = indent .. "    " .. meta_line
              entries[#entries + 1] = { node = child, kind = "meta" }
            end
          end
        end
      end
    end

    walk(node, 0)
    return lines, entries
  end

  local function render()
    local lines
    lines, line_entries = flatten_with_meta(root_node)
    if #lines == 0 then
      lines = { "(no artifacts in this node)" }
      line_entries = {}
    end
    set_lines(bufnr, lines)
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    for idx, entry in ipairs(line_entries) do
      if entry.kind == "header" then
        vim.api.nvim_buf_add_highlight(bufnr, ns, "JfrogArtifactsHeader", idx - 1, 0, -1)
      elseif entry.kind == "meta" then
        vim.api.nvim_buf_add_highlight(bufnr, ns, "Comment", idx - 1, 0, -1)
      elseif entry.node and entry.node.kind == "file" then
        vim.api.nvim_buf_add_highlight(bufnr, ns, "JfrogArtifactItem", idx - 1, 0, -1)
      end
    end
  end

  local function node_at_cursor()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local entry = line_entries[line]
    return entry and entry.node or nil
  end

  local function toggle_meta()
    local node = node_at_cursor()
    if not node or node.kind ~= "file" then
      return
    end
    expanded_meta[node] = not expanded_meta[node]
    render()
  end

  local function activate()
    local node = node_at_cursor()
    if not node then
      return
    end

    if node.kind == "dir" then
      tree.toggle(node)
      render()
      return
    end

    toggle_meta()
  end

  vim.keymap.set("n", "<CR>", activate, { buffer = bufnr, silent = true, nowait = true })
  vim.keymap.set("n", "d", function()
    local node = node_at_cursor()
    if node and opts.on_download then
      opts.on_download(node)
    end
  end, { buffer = bufnr, silent = true })
  vim.keymap.set("n", "y", function()
    local node = node_at_cursor()
    if node and opts.on_copy then
      opts.on_copy(node)
    end
  end, { buffer = bufnr, silent = true })
  vim.keymap.set("n", "q", function()
    vim.cmd("bd!")
  end, { buffer = bufnr, silent = true })

  setup_highlights()
  render()
  if opts.focus_node then
    for i, entry in ipairs(line_entries) do
      if entry.node == opts.focus_node then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        break
      end
    end
  end
end

function M.open(root, opts)
  vim.cmd("rightbelow vsplit")
  local win = vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, bufnr)
  vim.api.nvim_win_set_width(win, opts.width or 45)
  set_scratch_name(bufnr, opts.title or "JFrog Artifacts")
  configure_buffer(bufnr)

  local line_nodes = {}
  local function render()
    local lines
    lines, line_nodes = tree.flatten(root)
    if #lines == 0 then
      lines = { "(no artifacts)" }
    end
    set_lines(bufnr, lines)
  end

  local function node_at_cursor()
    local line = vim.api.nvim_win_get_cursor(win)[1]
    return line_nodes[line]
  end

  local function activate()
    local node = node_at_cursor()
    if not node then
      return
    end

    if node.kind == "dir" then
      tree.toggle(node)
      render()
      return
    end

    if node.item and opts.on_select then
      opts.on_select(node.item)
    end
  end

  vim.keymap.set("n", "<CR>", activate, { buffer = bufnr, silent = true, nowait = true })
  vim.keymap.set("n", "q", function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end, { buffer = bufnr, silent = true })
  vim.keymap.set("n", "r", function()
    if opts.on_refresh then
      opts.on_refresh()
    end
  end, { buffer = bufnr, silent = true })
  vim.keymap.set("n", "p", function()
    if opts.on_picker then
      opts.on_picker()
    end
  end, { buffer = bufnr, silent = true })
  vim.keymap.set("n", "y", function()
    local node = node_at_cursor()
    if node and node.item then
      vim.fn.setreg("+", node.item.full)
      vim.notify("Copied: " .. node.item.full)
    end
  end, { buffer = bufnr, silent = true })

  render()
  return { bufnr = bufnr, win = win }
end

return M
