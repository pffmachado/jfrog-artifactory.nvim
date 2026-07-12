local M = {}

local function normalize_path(path)
  if not path then
    return ""
  end
  return vim.trim(path):gsub('^"(.*)"[,]?$', "%1"):gsub("^/+", ""):gsub("/+$", "")
end

local function parse_full_to_item(full)
  local cleaned = normalize_path(vim.trim(full):gsub('^"(.*)"[,]?$', "%1"))
  if cleaned == "" then
    return { repo = "", path = "", name = "", full = "" }
  end

  local parts = vim.split(cleaned, "/", { plain = true, trimempty = true })
  local repo = parts[1] or ""
  local name = parts[#parts] or ""
  local path = ""
  if #parts > 2 then
    path = table.concat(parts, "/", 2, #parts - 1)
  end

  return {
    repo = repo,
    path = path,
    name = name,
    full = cleaned,
    sort_ts = "",
    branch = "",
  }
end

local function join_non_empty(parts)
  local out = {}
  for _, part in ipairs(parts) do
    local cleaned = normalize_path(part)
    if cleaned ~= "" and cleaned ~= "." then
      out[#out + 1] = cleaned
    end
  end
  return table.concat(out, "/")
end

local function normalize_results(decoded)
  local payload = decoded
  if type(payload) ~= "table" then
    return {}
  end

  if payload.results and type(payload.results) == "table" then
    payload = payload.results
  elseif payload.data and payload.data.results and type(payload.data.results) == "table" then
    payload = payload.data.results
  end

  local items = {}
  local function normalize_branch(value)
    if type(value) == "table" then
      if #value > 0 then
        return normalize_branch(value[1])
      end
      if value.value then
        return normalize_branch(value.value)
      end
      return ""
    end
    local branch = normalize_path(value or "")
    if branch:find(",") then
      branch = vim.split(branch, ",", { plain = true, trimempty = true })[1] or branch
    end
    return branch
  end

  local function extract_branch(entry)
    if type(entry) ~= "table" then
      return ""
    end

    if entry["vcs.branch"] then
      return normalize_branch(entry["vcs.branch"])
    end

    local props = entry.properties or entry.props
    if type(props) == "table" then
      if props["vcs.branch"] then
        return normalize_branch(props["vcs.branch"])
      end
      for _, prop in ipairs(props) do
        if type(prop) == "table" then
          local key = prop.key or prop.name
          if key == "vcs.branch" then
            return normalize_branch(prop.value or prop.values)
          end
        end
      end
    end

    return ""
  end

  for _, entry in ipairs(payload) do
    if type(entry) == "string" then
      table.insert(items, parse_full_to_item(entry))
    elseif type(entry) == "table" then
      local repo = entry.repo or entry.repoKey or ""
      local path = entry.path or ""
      local name = entry.name or ""
      local full = join_non_empty({ repo, path, name })
      local sort_ts = normalize_path(entry.created or entry.modified or "")
      local branch = extract_branch(entry)

      -- Some jfrog versions return only "path" as a full artifact path.
      if full == "" and path ~= "" then
        local from_path = parse_full_to_item(path)
        from_path.sort_ts = sort_ts
        from_path.created = entry.created or ""
        from_path.modified = entry.modified or ""
        from_path.size = entry.size or ""
        from_path.sha256 = entry.sha256 or ""
        from_path.sha1 = entry.sha1 or ""
        from_path.md5 = entry.md5 or ""
        from_path.type = entry.type or ""
        from_path.branch = branch
        table.insert(items, from_path)
      else
        table.insert(items, {
          repo = repo,
          path = path,
          name = name,
          full = full,
          sort_ts = sort_ts,
          created = entry.created or "",
          modified = entry.modified or "",
          size = entry.size or "",
          sha256 = entry.sha256 or "",
          sha1 = entry.sha1 or "",
          md5 = entry.md5 or "",
          type = entry.type or "",
          branch = branch,
        })
      end
    end
  end

  table.sort(items, function(a, b)
    return a.full < b.full
  end)

  return items
end

local function parse_plaintext(stdout)
  local items = {}
  local seen = {}
  for line in (stdout or ""):gmatch("[^\r\n]+") do
    local trimmed = vim.trim(line)
    if trimmed ~= "" and not seen[trimmed] then
      table.insert(items, parse_full_to_item(trimmed))
      seen[trimmed] = true
    end
  end
  table.sort(items, function(a, b)
    return a.full < b.full
  end)
  return items
end

local function run(cmd, on_done)
  vim.system(cmd, { text = true }, function(result)
    vim.schedule(function()
      on_done(result)
    end)
  end)
end

function M.ensure_authenticated(opts, callback)
  local cmd_show = { "jf", "c", "show", "--format=json" }
  run(cmd_show, function(result_show)
    if result_show.code ~= 0 then
      callback(false, "JFrog CLI is not configured")
      return
    end

    local ok, decoded = pcall(vim.json.decode, result_show.stdout or "[]")
    local has_config = false
    if ok and type(decoded) == "table" then
      if #decoded > 0 then
        has_config = true
      elseif decoded.configs and type(decoded.configs) == "table" and #decoded.configs > 0 then
        has_config = true
      end
    end
    if not has_config then
      callback(false, "No JFrog server configuration found")
      return
    end

    local cmd_ping = vim.deepcopy(opts.jfrog_ping_command or { "jf", "rt", "ping" })
    table.insert(cmd_ping, "--format=json")
    run(cmd_ping, function(result_ping)
      if result_ping.code ~= 0 then
        callback(false, "JFrog CLI is not authenticated")
        return
      end
      callback(true, nil)
    end)
  end)
end

function M.search(pattern, opts, callback)
  local cmd_json = vim.deepcopy(opts.jfrog_command)
  table.insert(cmd_json, pattern)
  table.insert(cmd_json, "--include=repo;path;name;created;modified;size;sha256;sha1;md5;type;properties")
  table.insert(cmd_json, "--sort-by=created")
  table.insert(cmd_json, "--sort-order=desc")
  table.insert(cmd_json, "--format=json")

  run(cmd_json, function(result_json)
    if result_json.code == 0 then
      local stdout = result_json.stdout or "[]"
      local ok, decoded = pcall(vim.json.decode, stdout)
      if ok then
        callback(normalize_results(decoded), nil)
        return
      end
    end

    local cmd_json_fallback = vim.deepcopy(opts.jfrog_command)
    table.insert(cmd_json_fallback, pattern)
    table.insert(cmd_json_fallback, "--format=json")
    run(cmd_json_fallback, function(result_json_fallback)
      if result_json_fallback.code == 0 then
        local stdout = result_json_fallback.stdout or "[]"
        local ok, decoded = pcall(vim.json.decode, stdout)
        if ok then
          callback(normalize_results(decoded), nil)
          return
        end
      end

      local cmd_plain = vim.deepcopy(opts.jfrog_command)
      table.insert(cmd_plain, pattern)
      run(cmd_plain, function(result_plain)
        if result_plain.code ~= 0 then
          local stderr = (result_plain.stderr or ""):gsub("%s+$", "")
          callback(nil, stderr ~= "" and stderr or "JFrog command failed")
          return
        end

        callback(parse_plaintext(result_plain.stdout or ""), nil)
        return
      end)
    end)
  end)
end

function M.download(pattern, target_dir, opts, callback)
  local cmd = vim.deepcopy(opts.jfrog_download_command or { "jf", "rt", "dl" })
  table.insert(cmd, pattern)
  table.insert(cmd, target_dir .. "/")
  table.insert(cmd, "--flat=false")

  vim.system(cmd, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        local stderr = (result.stderr or ""):gsub("%s+$", "")
        callback(false, stderr ~= "" and stderr or "JFrog download failed")
        return
      end
      callback(true, nil)
    end)
  end)
end

return M
