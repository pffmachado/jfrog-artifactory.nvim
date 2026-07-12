# jfrog-artifactory.nvim

Neovim plugin to browse JFrog Artifactory artifacts from a **project root** (for example `org/repo`) using:

- a **tree picker** (Telescope by default, with right-side preview; can use Snacks or `vim.ui.select`)
- an optional **vertical tree explorer**

It uses `jf rt s "<project>/**" --format=json` under the hood.

Results are sorted by **most recent first** when created/modified metadata is available.
Before search/download, the plugin checks that JFrog CLI is configured and reachable; if not, it prompts to run `jf login`.

## Requirements

- Neovim >= 0.10
- [`jf` CLI](https://jfrog.com/getcli/) installed and authenticated

## Install (lazy.nvim)

```lua
{
  "YOUR_GITHUB_USERNAME/jfrog-artifactory.nvim",
  config = function()
    require("jfrog_artifactory").setup()
  end,
}
```

## Usage

```vim
" Recommended: browse by project with a picker tree
:JfArtifactsBrowse org/repo

" Or rely on inferred project from current git repo/cwd
:JfArtifactsBrowse

" Alias for browse
:JfArtifactsPicker org/repo

" Optional: open vertical tree explorer for same project
:JfArtifactsSearch org/repo

" Re-run last browse/search
:JfArtifactsRefresh
```

Selecting a directory in the picker opens a buffer with its contents (Octo-like flow).
Browse list entries now append branch as `(<branch>)` using artifact property `vcs.branch` when available.

## Content buffer keys

- `<CR>` on folder: expand/collapse
- `<CR>` on file: expand/collapse artifact metadata
- `d`: download selected file or folder subtree
- `y`: copy selected artifact path
- `q`: close buffer

The content buffer includes a **Build Info** header (project, branch, path, file count, fetch time).

## Explorer keys

- `<CR>`: expand/collapse folder
- `<CR>` on file: trigger `on_select` callback (default: yank artifact path)
- `y`: yank artifact path
- `p`: open picker with current results
- `r`: refresh current search
- `q`: close explorer

## Configuration

```lua
require("jfrog_artifactory").setup({
  default_project = nil, -- e.g. "org/repo"
  infer_project_from_git = true, -- infer owner/repo from git remote or cwd path
  jfrog_command = { "jf", "rt", "s" },
  jfrog_ping_command = { "jf", "rt", "ping" },
  jfrog_download_command = { "jf", "rt", "dl" },
  picker_backend = "telescope", -- telescope | snacks | vim_ui | auto
  download_root = ".jfrog", -- created under current working directory
  explorer = {
    width = 45,
  },
  on_select = function(item)
    -- item = { repo, path, name, full }
    vim.fn.setreg("+", item.full)
    vim.notify("Copied: " .. item.full)
  end,
})
```

## Repo structure

```
jfrog-artifactory.nvim/
├── LICENSE
├── README.md
├── plugin/
│   └── jfrog_artifactory.lua
└── lua/
    └── jfrog_artifactory/
        ├── commands.lua
        ├── init.lua
        ├── jfrog.lua
        ├── tree.lua
        └── ui.lua
```
