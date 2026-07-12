local M = {}

local function ensure_child(parent, name, kind)
  parent.children = parent.children or {}
  parent.children_map = parent.children_map or {}
  if parent.children_map[name] then
    return parent.children_map[name]
  end

  local node = {
    name = name,
    kind = kind,
    expanded = false,
    sort_ts = "",
    children = {},
    children_map = {},
    parent = parent,
  }

  table.insert(parent.children, node)
  parent.children_map[name] = node
  return node
end

local function split_path(path)
  if not path or path == "" or path == "." then
    return {}
  end
  return vim.split(path, "/", { plain = true, trimempty = true })
end

local function starts_with_path(parts, prefix_parts)
  if #prefix_parts == 0 then
    return true
  end
  if #parts < #prefix_parts then
    return false
  end
  for i, part in ipairs(prefix_parts) do
    if parts[i] ~= part then
      return false
    end
  end
  return true
end

local function sort_tree(node)
  table.sort(node.children, function(a, b)
    if a.kind ~= b.kind then
      return a.kind == "dir"
    end
    if a.sort_ts ~= b.sort_ts then
      return a.sort_ts > b.sort_ts
    end
    return a.name < b.name
  end)

  for _, child in ipairs(node.children) do
    if child.kind == "dir" then
      sort_tree(child)
    end
  end
end

local function fold_sort_ts(node)
  if node.kind == "file" then
    return node.sort_ts or ""
  end

  local latest = node.sort_ts or ""
  for _, child in ipairs(node.children) do
    local child_ts = fold_sort_ts(child)
    if child_ts > latest then
      latest = child_ts
    end
  end
  node.sort_ts = latest
  return latest
end

function M.build(items, opts)
  opts = opts or {}
  local base = opts.base or ""
  local base_parts = split_path(base)

  local root = {
    name = base ~= "" and base or "/",
    kind = "dir",
    expanded = true,
    sort_ts = "",
    children = {},
    children_map = {},
    parent = nil,
  }

  for _, item in ipairs(items) do
    local full_parts = split_path(item.full)
    if starts_with_path(full_parts, base_parts) then
      local rel_parts = {}
      for i = #base_parts + 1, #full_parts do
        rel_parts[#rel_parts + 1] = full_parts[i]
      end

      local current = root
      for i = 1, #rel_parts - 1 do
        current = ensure_child(current, rel_parts[i], "dir")
      end

      if #rel_parts >= 1 then
        local leaf_name = rel_parts[#rel_parts]
        local leaf = ensure_child(current, leaf_name, "file")
        leaf.item = item
        leaf.sort_ts = item.sort_ts or ""
      end
    end
  end

  fold_sort_ts(root)
  sort_tree(root)
  return root
end

function M.toggle(node)
  if node and node.kind == "dir" then
    node.expanded = not node.expanded
  end
end

function M.flatten(root)
  local lines = {}
  local line_nodes = {}

  local function walk(node, depth)
    for _, child in ipairs(node.children) do
      local indent = string.rep("  ", depth)
      local icon = child.kind == "dir" and (child.expanded and "▾ " or "▸ ") or "  "
      table.insert(lines, indent .. icon .. child.name)
      table.insert(line_nodes, child)

      if child.kind == "dir" and child.expanded then
        walk(child, depth + 1)
      end
    end
  end

  walk(root, 0)
  return lines, line_nodes
end

function M.node_full_path(node)
  local parts = {}
  local cur = node
  while cur do
    if cur.name and cur.name ~= "/" then
      table.insert(parts, 1, cur.name)
    end
    cur = cur.parent
  end
  return table.concat(parts, "/")
end

return M
