local M = {}

local log = require("code-preview.log")

-- Active previews keyed by absolute file path. Each entry owns immutable
-- original/proposed line snapshots plus the metadata and UI resources needed to
-- re-render that one preview without consulting its source tempfiles.
local active_diffs = {}

-- Per-buffer inline diff state (line numbers, types) for statuscolumn.
-- Keyed by buffer handle.
local buf_inline_data = {}

-- Namespaces created at module load, but colors applied inside show_diff()
-- after setup() has merged the user config.
local current_ns  = vim.api.nvim_create_namespace("claude_diff_current_hl")
local proposed_ns = vim.api.nvim_create_namespace("claude_diff_proposed_hl")
local inline_ns   = vim.api.nvim_create_namespace("claude_diff_inline_hl")

local function apply_highlights(config)
  local cur = config.highlights.current
  local pro = config.highlights.proposed
  for name, hl in pairs(cur) do
    vim.api.nvim_set_hl(current_ns, name, hl)
  end
  for name, hl in pairs(pro) do
    vim.api.nvim_set_hl(proposed_ns, name, hl)
  end
end

-- Update neo-tree indicator + reveal for a file that's about to be previewed.
-- `action` is an optional hint from callers that know the operation type
-- (e.g. ApplyPatch passes "delete" for `*** Delete File:` directives). We
-- only emit "deleted" when explicitly told — inferring it from an empty
-- proposed file would misclassify legitimate truncations to zero bytes.
local function mark_change_and_reveal(abs_file_path, action)
  if not abs_file_path or abs_file_path == "" then
    return
  end

  local status
  if action == "delete" then
    status = "deleted"
  elseif vim.uv.fs_stat(abs_file_path) then
    status = "modified"
  else
    status = "created"
  end
  log.debug(log.fmt("mark_change_and_reveal: %s → %s", abs_file_path, status))
  pcall(function() require("code-preview.changes").set(abs_file_path, status) end)
  pcall(function() require("code-preview.neo_tree").refresh() end)

  local cfg = require("code-preview").config
  if not (cfg and cfg.neo_tree and cfg.neo_tree.reveal ~= false) then
    return
  end

  local reveal_dir = nil
  if cfg.neo_tree.reveal_root == "git" then
    local parent = vim.fn.fnamemodify(abs_file_path, ":h")
    -- List-form (no shell): avoids the POSIX-only `2>/dev/null` redirect, which
    -- misbehaves under Windows cmd. `shell_error` still gates the result, so a
    -- non-repo parent (git's stderr + non-zero exit) simply leaves reveal_dir nil.
    local git_out = vim.fn.systemlist({ "git", "-C", parent, "rev-parse", "--show-toplevel" })
    if vim.v.shell_error == 0 and git_out[1] and git_out[1] ~= "" then
      reveal_dir = git_out[1]
    end
  end

  local reveal_target = abs_file_path
  if status == "created" then
    local parent = vim.fn.fnamemodify(abs_file_path, ":h")
    while parent ~= "/" and vim.fn.isdirectory(parent) == 0 do
      parent = vim.fn.fnamemodify(parent, ":h")
    end
    local siblings = vim.fn.glob(parent .. "/*", false, true)
    reveal_target = siblings[1] or parent
  end

  vim.defer_fn(function()
    pcall(function()
      require("code-preview.neo_tree").reveal(reveal_target, reveal_dir)
    end)
  end, 300)
end

local function read_file_lines(path)
  local lines = {}
  local f = io.open(path, "r")
  if f then
    for line in f:lines() do
      table.insert(lines, line)
    end
    f:close()
  end
  return lines
end

-- Force the terminal to repaint after an RPC-driven tab/window change.
--
-- show_diff runs inside a `nvim --remote-expr` call from the hook shim, so the
-- new diff tab exists in Neovim's state immediately but the TUI isn't repainted
-- until the event loop next wakes. A deferred `redraw!` covers most hosts.
--
-- The Windows legacy console (cmd.exe / conhost) is the exception: it does NOT
-- flush a timer-driven `redraw!` issued from an idle --remote-expr, so the diff
-- only paints on the next event (the user's next edit) — neo-tree, which forces
-- its own redraw, updates meanwhile, producing the "marking shows but diff
-- doesn't" symptom. nvim__redraw({flush=true}) pushes the grid to the UI on the
-- spot, and the <Ignore> feedkeys nudge wakes the input loop so conhost delivers
-- it. Both are pcall'd: __redraw is 0.10+ and semi-private. The win32 guard keeps
-- every other platform on the exact prior behaviour.
local function force_redraw()
  vim.fn.timer_start(10, function()
    vim.cmd("redraw!")
    if vim.fn.has("win32") == 1 then
      pcall(vim.api.nvim__redraw, { flush = true })
      pcall(vim.api.nvim_feedkeys,
        vim.api.nvim_replace_termcodes("<Ignore>", true, false, true), "n", false)
    end
  end)
end

--- Count how many active diffs are currently open.
local function active_count()
  local n = 0
  for _ in pairs(active_diffs) do n = n + 1 end
  return n
end

local VALID_LAYOUTS = { tab = true, vsplit = true, inline = true }

-- Values we've already warned about, so a misconfigured layout warns once
-- rather than on every diff (log.warn surfaces via vim.notify).
local warned_layouts = {}

-- Validate a resolved layout. An unknown value (a typo like "vspllit", or a
-- layout removed in a future version) otherwise falls through to the "tabnew"
-- branch silently, making the config look ignored. Warn once and fall back to
-- the supported default.
local function valid_layout(layout)
  if VALID_LAYOUTS[layout] then return layout end
  if layout and not warned_layouts[layout] then
    warned_layouts[layout] = true
    log.warn(log.fmt(
      'unknown diff layout %q; falling back to "tab" (valid: tab, vsplit, inline)', layout))
  end
  return "tab"
end

local function layout_for_backend(cfg, backend)
  local diff_cfg = (cfg and cfg.diff) or {}
  local layouts = diff_cfg.layouts or {}

  if backend and layouts[backend] then
    return valid_layout(layouts[backend])
  end

  return valid_layout(diff_cfg.layout or "tab")
end

function M.is_open(file_path)
  if file_path and file_path ~= "" then
    local entry = active_diffs[file_path]
    if entry and entry.tab and vim.api.nvim_tabpage_is_valid(entry.tab) then
      return true
    end
    return false
  end
  -- No file_path: return true if ANY diff is open
  return active_count() > 0
end

-- Statuscolumn function for inline diff: shows old|new line numbers + sign.
-- Reads per-buffer state from buf_inline_data so multiple inline diffs coexist.
function M.inline_statuscolumn(col_width)
  local win = vim.g.statusline_winid
  local buf = vim.api.nvim_win_get_buf(win)
  local data = buf_inline_data[buf]
  if not data then
    return ""
  end
  local lnum = vim.v.lnum
  local line_numbers = data.line_numbers
  local line_types = data.line_types
  if not line_numbers[lnum] then
    return string.rep(" ", col_width * 2 + 3)
  end
  local old_num = line_numbers[lnum][1]
  local new_num = line_numbers[lnum][2]
  local old_str = old_num and string.format("%" .. col_width .. "d", old_num) or string.rep(" ", col_width)
  local new_str = new_num and string.format("%" .. col_width .. "d", new_num) or string.rep(" ", col_width)

  local line_type = line_types[lnum]
  local sign = " "
  if line_type == "added" then
    sign = "%#ClaudeDiffInlineAddedSign#+%*"
  elseif line_type == "removed" then
    sign = "%#ClaudeDiffInlineRemovedSign#-%*"
  end

  return old_str .. "│" .. new_str .. " " .. sign
end

local function apply_inline_highlights(config)
  local hl = config.highlights.inline or {}
  vim.api.nvim_set_hl(0, "ClaudeDiffInlineAdded", hl.added or { bg = "#2e4c2e" })
  vim.api.nvim_set_hl(0, "ClaudeDiffInlineRemoved", hl.removed or { bg = "#4c2e2e" })
  vim.api.nvim_set_hl(0, "ClaudeDiffInlineAddedText", hl.added_text or { bg = "#3a6e3a" })
  vim.api.nvim_set_hl(0, "ClaudeDiffInlineRemovedText", hl.removed_text or { bg = "#6e3a3a" })
  vim.api.nvim_set_hl(0, "ClaudeDiffInlineAddedSign", { fg = "#73e896", bold = true })
  vim.api.nvim_set_hl(0, "ClaudeDiffInlineRemovedSign", { fg = "#f47070", bold = true })
end

-- Compute character-level diff between two lines, returns list of {start, end} changed ranges
local function char_diff_ranges(old_line, new_line)
  local prefix = 0
  local min_len = math.min(#old_line, #new_line)
  while prefix < min_len and old_line:byte(prefix + 1) == new_line:byte(prefix + 1) do
    prefix = prefix + 1
  end
  local suffix = 0
  while suffix < (min_len - prefix)
    and old_line:byte(#old_line - suffix) == new_line:byte(#new_line - suffix) do
    suffix = suffix + 1
  end
  return prefix, #old_line - suffix, #new_line - suffix
end

local function build_inline_diff(orig_lines, prop_lines)
  local orig_text = #orig_lines > 0 and (table.concat(orig_lines, "\n") .. "\n") or ""
  local prop_text = #prop_lines > 0 and (table.concat(prop_lines, "\n") .. "\n") or ""

  local diff_str = vim.diff(orig_text, prop_text, {
    result_type = "unified",
    ctxlen = 999999,
  })

  if not diff_str or diff_str == "" then
    local line_numbers = {}
    for lnum = 1, #prop_lines do
      line_numbers[lnum] = { lnum, lnum }
    end
    return vim.deepcopy(prop_lines), {}, {}, line_numbers, {}
  end

  local display_lines = {}
  local line_highlights = {}
  local char_highlights = {}
  local line_numbers = {}
  local line_types = {}

  local entries = {}
  for line in diff_str:gmatch("([^\n]*)\n?") do
    -- vim.diff unified output starts with hunk headers and has no ---/+++
    -- file headers. A record beginning --- or +++ is therefore real changed
    -- content whose source text begins -- or ++.
    if line:sub(1, 2) == "@@" then
      -- skip hunk headers
    elseif line:sub(1, 1) == "-" then
      table.insert(entries, { type = "removed", text = line:sub(2) })
    elseif line:sub(1, 1) == "+" then
      table.insert(entries, { type = "added", text = line:sub(2) })
    elseif line ~= "" or #entries > 0 then
      local content = line:sub(1, 1) == " " and line:sub(2) or line
      table.insert(entries, { type = "context", text = content })
    end
  end

  local old_num = 0
  local new_num = 0
  local i = 1
  while i <= #entries do
    local e = entries[i]
    if e.type == "removed" then
      local removed_start = i
      while i <= #entries and entries[i].type == "removed" do
        i = i + 1
      end
      local removed_end = i - 1
      local added_start = i
      while i <= #entries and entries[i].type == "added" do
        i = i + 1
      end
      local added_end = i - 1

      for j = removed_start, removed_end do
        table.insert(display_lines, entries[j].text)
        local line_idx = #display_lines - 1
        old_num = old_num + 1
        table.insert(line_numbers, { old_num, nil })
        table.insert(line_highlights, { line_idx, "ClaudeDiffInlineRemoved" })
        line_types[line_idx + 1] = "removed"
        local pair_idx = added_start + (j - removed_start)
        if pair_idx <= added_end then
          local old_content = entries[j].text
          local new_content = entries[pair_idx].text
          local pfx, old_end, _ = char_diff_ranges(old_content, new_content)
          if old_end > pfx then
            table.insert(char_highlights, { line_idx, "ClaudeDiffInlineRemovedText", pfx, old_end })
          end
        end
      end
      for j = added_start, added_end do
        table.insert(display_lines, entries[j].text)
        local line_idx = #display_lines - 1
        new_num = new_num + 1
        table.insert(line_numbers, { nil, new_num })
        table.insert(line_highlights, { line_idx, "ClaudeDiffInlineAdded" })
        line_types[line_idx + 1] = "added"
        local pair_idx = removed_start + (j - added_start)
        if pair_idx <= removed_end then
          local old_content = entries[pair_idx].text
          local new_content = entries[j].text
          local pfx, _, new_end = char_diff_ranges(old_content, new_content)
          if new_end > pfx then
            table.insert(char_highlights, { line_idx, "ClaudeDiffInlineAddedText", pfx, new_end })
          end
        end
      end
    else
      table.insert(display_lines, e.text)
      local line_idx = #display_lines - 1
      if e.type == "context" then
        old_num = old_num + 1
        new_num = new_num + 1
        table.insert(line_numbers, { old_num, new_num })
      elseif e.type == "added" then
        new_num = new_num + 1
        table.insert(line_numbers, { nil, new_num })
        table.insert(line_highlights, { line_idx, "ClaudeDiffInlineAdded" })
        line_types[line_idx + 1] = "added"
      elseif e.type == "removed" then
        old_num = old_num + 1
        table.insert(line_numbers, { old_num, nil })
        table.insert(line_highlights, { line_idx, "ClaudeDiffInlineRemoved" })
        line_types[line_idx + 1] = "removed"
      end
      i = i + 1
    end
  end

  return display_lines, line_highlights, char_highlights, line_numbers, line_types
end

local function set_toggle_keymap(buf, cfg)
  local keys_cfg = cfg and cfg.keys
  if keys_cfg ~= false and keys_cfg and keys_cfg.toggle_layout then
    vim.keymap.set("n", keys_cfg.toggle_layout, "<Plug>(CodePreviewToggleLayout)", {
      buffer = buf,
      desc = "Toggle code-preview layout",
    })
  end
end

--- Create an inline diff tab and return its UI resources.
local function show_inline_diff(entry, cfg)
  apply_inline_highlights(cfg)

  local display_name = entry.display_path or "unknown"
  local ft = vim.filetype.match({ filename = entry.file_path or entry.display_path }) or ""
  local display_lines, line_highlights, char_highlights, line_numbers, line_types =
    build_inline_diff(entry.original_lines, entry.proposed_lines)

  vim.cmd("tabnew")
  local tab = vim.api.nvim_get_current_tabpage()
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, display_lines)

  vim.bo[buf].buftype    = "nofile"
  vim.bo[buf].bufhidden  = "wipe"
  vim.bo[buf].swapfile   = false
  vim.bo[buf].modifiable = false
  if ft ~= "" then vim.bo[buf].filetype = ft end

  -- Apply full-line highlights
  for _, hl in ipairs(line_highlights) do
    local line_len = #(display_lines[hl[1] + 1] or "")
    vim.api.nvim_buf_set_extmark(buf, inline_ns, hl[1], 0, {
      end_col = line_len,
      hl_group = hl[2],
      hl_eol = true,
      priority = 150,
    })
  end
  -- Apply character-level highlights on top
  for _, hl in ipairs(char_highlights) do
    vim.api.nvim_buf_set_extmark(buf, inline_ns, hl[1], hl[3], {
      end_col = hl[4],
      hl_group = hl[2],
      priority = 200,
    })
  end

  local win = vim.api.nvim_get_current_win()

  -- Store per-buffer inline data for statuscolumn
  buf_inline_data[buf] = {
    line_numbers = line_numbers,
    line_types = line_types,
  }

  local max_num = 0
  for _, nums in ipairs(line_numbers) do
    if nums[1] and nums[1] > max_num then max_num = nums[1] end
    if nums[2] and nums[2] > max_num then max_num = nums[2] end
  end
  local col_width = math.max(#tostring(max_num), 1)

  local n = active_count()
  local winbar_prefix = n > 1
    and string.format("%%#DiagnosticInfo# DIFF [%d pending] %%* ", n)
    or "%#DiagnosticInfo# INLINE DIFF %* "
  vim.wo[win].winbar = winbar_prefix .. display_name
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.wo[win].signcolumn = "no"
  vim.wo[win].statuscolumn = "%!v:lua.require('code-preview.diff').inline_statuscolumn(" .. col_width .. ")"

  -- Find first changed line for navigation
  local first_change_line = nil
  for lnum, _ in pairs(line_types) do
    if not first_change_line or lnum < first_change_line then
      first_change_line = lnum
    end
  end

  local keys_cfg = (cfg and cfg.keys) or {}
  if keys_cfg ~= false then
    if keys_cfg.next_change then
      vim.keymap.set("n", keys_cfg.next_change, function()
        local cur = vim.api.nvim_win_get_cursor(0)[1]
        for lnum = cur + 1, vim.api.nvim_buf_line_count(buf) do
          if line_types[lnum] then
            vim.api.nvim_win_set_cursor(0, { lnum, 0 })
            return
          end
        end
      end, { buffer = buf, desc = "Next change" })
    end

    if keys_cfg.prev_change then
      vim.keymap.set("n", keys_cfg.prev_change, function()
        local cur = vim.api.nvim_win_get_cursor(0)[1]
        for lnum = cur - 1, 1, -1 do
          if line_types[lnum] then
            vim.api.nvim_win_set_cursor(0, { lnum, 0 })
            return
          end
        end
      end, { buffer = buf, desc = "Previous change" })
    end
  end

  set_toggle_keymap(buf, cfg)

  if first_change_line then
    vim.api.nvim_win_set_cursor(win, { first_change_line, 0 })
  end

  return {
    tab = tab,
    bufs = { buf },
    wins = { win },
    inline_win = win,
    inline_line_numbers = line_numbers,
    inline_line_types = line_types,
  }
end

local function show_side_diff(entry, cfg, layout)
  apply_highlights(cfg)

  local display_name = entry.display_path or "unknown"
  local labels = cfg.diff.labels or { current = "CURRENT", proposed = "PROPOSED" }
  local ft = vim.filetype.match({ filename = entry.file_path or entry.display_path }) or ""

  local orig_buf
  if layout == "vsplit" then
    if entry.host_win and vim.api.nvim_win_is_valid(entry.host_win) then
      vim.api.nvim_set_current_win(entry.host_win)
    end
    vim.cmd("vsplit")
    -- A split initially shares its source buffer. Replace it with a scratch
    -- buffer so preview teardown never wipes or mutates the user's host buffer.
    orig_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, orig_buf)
  else
    vim.cmd("tabnew")
    orig_buf = vim.api.nvim_get_current_buf()
  end
  local tab = vim.api.nvim_get_current_tabpage()

  vim.api.nvim_buf_set_lines(orig_buf, 0, -1, false, entry.original_lines)
  vim.bo[orig_buf].buftype = "nofile"
  vim.bo[orig_buf].bufhidden = "wipe"
  vim.bo[orig_buf].swapfile = false
  vim.bo[orig_buf].modifiable = false
  if ft ~= "" then vim.bo[orig_buf].filetype = ft end

  local orig_win = vim.api.nvim_get_current_win()
  local n = active_count()
  local winbar_prefix = n > 1
    and string.format("%%#DiagnosticError# %s [%d pending] %%* ", labels.current, n)
    or "%#DiagnosticError# " .. labels.current .. " %* "
  vim.wo[orig_win].winbar = winbar_prefix .. display_name
  vim.api.nvim_win_set_hl_ns(orig_win, current_ns)
  vim.cmd("diffthis")

  vim.cmd("rightbelow vsplit")
  local prop_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, prop_buf)
  vim.api.nvim_buf_set_lines(prop_buf, 0, -1, false, entry.proposed_lines)
  vim.bo[prop_buf].buftype = "nofile"
  vim.bo[prop_buf].bufhidden = "wipe"
  vim.bo[prop_buf].swapfile = false
  vim.bo[prop_buf].modifiable = false
  if ft ~= "" then vim.bo[prop_buf].filetype = ft end

  local prop_win = vim.api.nvim_get_current_win()
  vim.wo[prop_win].winbar = "%#DiagnosticWarn# " .. labels.proposed .. " %* " .. display_name
  vim.api.nvim_win_set_hl_ns(prop_win, proposed_ns)
  vim.cmd("diffthis")

  for _, buf in ipairs({ orig_buf, prop_buf }) do
    set_toggle_keymap(buf, cfg)
  end

  if cfg.diff.full_file then
    for _, win in ipairs({ orig_win, prop_win }) do
      vim.wo[win].foldenable = true
      vim.wo[win].foldmethod = "diff"
      vim.wo[win].foldlevel = 999
      vim.wo[win].foldcolumn = "0"
    end
  end

  if cfg.diff.equalize then vim.cmd("wincmd =") end

  local augroup = vim.api.nvim_create_augroup("CodePreviewDiffResize_" .. entry.file_path, { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = augroup,
    callback = function()
      if cfg.diff.equalize
        and vim.api.nvim_tabpage_is_valid(tab)
        and vim.api.nvim_get_current_tabpage() == tab
      then
        vim.cmd("wincmd =")
      end
    end,
  })

  vim.cmd("normal! ]c")
  return {
    tab = tab,
    bufs = { orig_buf, prop_buf },
    wins = { orig_win, prop_win },
    orig_buf = orig_buf,
    prop_buf = prop_buf,
    orig_win = orig_win,
    prop_win = prop_win,
    augroup = augroup,
  }
end

local RESOURCE_KEYS = {
  "tab", "bufs", "wins", "inline_win", "inline_line_numbers", "inline_line_types",
  "orig_buf", "prop_buf", "orig_win", "prop_win", "augroup",
}

local function destroy_render(entry)
  for _, win in ipairs(entry.wins or {}) do
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_call, win, function() vim.cmd("diffoff") end)
    end
  end
  for _, win in ipairs(entry.wins or {}) do
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  for _, buf in ipairs(entry.bufs or {}) do
    buf_inline_data[buf] = nil
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  if entry.augroup then pcall(vim.api.nvim_del_augroup_by_id, entry.augroup) end
  for _, key in ipairs(RESOURCE_KEYS) do entry[key] = nil end
end

local function render_entry(entry, layout)
  local cfg = require("code-preview").config
  local resources
  if layout == "inline" then
    resources = show_inline_diff(entry, cfg)
  else
    resources = show_side_diff(entry, cfg, layout)
  end
  for key, value in pairs(resources) do entry[key] = value end
  entry.layout = layout
end

local function entry_for_buffer(bufnr)
  for file_path, entry in pairs(active_diffs) do
    for _, buf in ipairs(entry.bufs or {}) do
      if buf == bufnr and vim.api.nvim_buf_is_valid(buf) then
        local side = "inline"
        if buf == entry.orig_buf then side = "original" end
        if buf == entry.prop_buf then side = "proposed" end
        return file_path, entry, side
      end
    end
  end
end

local function line_pair(entry, side, lnum)
  if side == "inline" then
    local pair = entry.inline_line_numbers and entry.inline_line_numbers[lnum]
    return pair and pair[1] or nil, pair and pair[2] or nil
  end

  local wanted_index = side == "original" and 1 or 2
  local snapshot_length = side == "original" and #entry.original_lines or #entry.proposed_lines
  if lnum > snapshot_length then return nil, nil end

  local wanted = lnum
  for _, pair in ipairs(entry.line_numbers or {}) do
    if pair[wanted_index] == wanted then return pair[1], pair[2] end
  end
  if side == "original" then return lnum, nil end
  if side == "proposed" then return nil, lnum end
  return nil, nil
end

local function window_for_buffer(bufnr)
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
        return win
      end
    end
  end
end

--- Return structured information for a preview buffer, or nil outside a preview.
--- opts accepts bufnr, start_line, and end_line.
function M.get_context(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then return nil end

  local _, entry, side = entry_for_buffer(bufnr)
  if not entry then return nil end

  local cursor_line, cursor_col = 1, 0
  local win = window_for_buffer(bufnr)
  if win then
    local cursor = vim.api.nvim_win_get_cursor(win)
    cursor_line, cursor_col = cursor[1], cursor[2]
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local start_line = math.max(1, math.min(opts.start_line or cursor_line, line_count))
  local end_line = math.max(1, math.min(opts.end_line or start_line, line_count))
  if start_line > end_line then start_line, end_line = end_line, start_line end

  local selected_lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  local mappings = {}
  for lnum = start_line, end_line do
    local old_line, new_line = line_pair(entry, side, lnum)
    mappings[#mappings + 1] = {
      buffer_line = lnum,
      old_line = old_line,
      new_line = new_line,
    }
  end
  local cursor_old_line, cursor_new_line = line_pair(entry, side, cursor_line)

  return {
    file_path = entry.file_path,
    display_path = entry.display_path,
    layout = entry.layout,
    side = side,
    bufnr = bufnr,
    cursor = {
      line = cursor_line,
      column = cursor_col,
      old_line = cursor_old_line,
      new_line = cursor_new_line,
    },
    range = { start_line = start_line, end_line = end_line },
    selected_lines = selected_lines,
    selected_text = table.concat(selected_lines, "\n"),
    line_mappings = mappings,
  }
end

local function capture_position(entry)
  local win = vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_win_get_buf(win)
  local _, current_entry, side = entry_for_buffer(bufnr)
  if current_entry ~= entry then
    win = entry.prop_win or entry.orig_win or entry.inline_win
    if not win or not vim.api.nvim_win_is_valid(win) then return nil end
    bufnr = vim.api.nvim_win_get_buf(win)
    _, _, side = entry_for_buffer(bufnr)
  end
  local cursor = vim.api.nvim_win_get_cursor(win)
  local old_line, new_line = line_pair(entry, side, cursor[1])
  return { side = side, old_line = old_line, new_line = new_line, column = cursor[2] }
end

local function restore_position(entry, position)
  if not position then return end
  local target_side = position.side
  if entry.layout ~= "inline" and target_side == "inline" then
    if position.old_line and not position.new_line then
      target_side = "original"
    elseif position.new_line and not position.old_line then
      target_side = "proposed"
    else
      target_side = entry.preferred_side or "proposed"
    end
  end

  local target_win = entry.inline_win
  local target_line = 1
  if entry.layout == "inline" then
    local wanted_index = position.side == "original" and 1 or 2
    local wanted = wanted_index == 1 and position.old_line or position.new_line
    if position.side == "inline" then
      wanted_index = position.old_line and 1 or 2
      wanted = position.old_line or position.new_line
    end
    for lnum, pair in ipairs(entry.inline_line_numbers or {}) do
      if pair[wanted_index] == wanted then target_line = lnum break end
    end
  else
    if target_side == "original" then
      target_win = entry.orig_win
      target_line = position.old_line or position.new_line or 1
    else
      target_win = entry.prop_win
      target_line = position.new_line or position.old_line or 1
    end
    entry.preferred_side = target_side
  end

  if target_win and vim.api.nvim_win_is_valid(target_win) then
    local max_line = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(target_win))
    local line = math.max(1, math.min(target_line, max_line))
    local text = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(target_win), line - 1, line, false)[1] or ""
    vim.api.nvim_set_current_win(target_win)
    vim.api.nvim_win_set_cursor(target_win, { line, math.min(position.column or 0, #text) })
  end
end

--- Toggle one active preview between inline and its original side-by-side layout.
--- When file_path is omitted, the preview containing the current buffer is used.
function M.toggle_layout(file_path)
  local inferred_path, inferred_entry = entry_for_buffer(vim.api.nvim_get_current_buf())
  local entry = file_path and active_diffs[file_path] or inferred_entry
  if not entry then return false end

  local current_was_target = inferred_entry == entry
  local saved_win = vim.api.nvim_get_current_win()
  local position = capture_position(entry)
  if position and position.side ~= "inline" then entry.preferred_side = position.side end

  local target_layout = entry.layout == "inline" and entry.side_layout or "inline"
  destroy_render(entry)
  render_entry(entry, target_layout)
  restore_position(entry, position)

  if not current_was_target and vim.api.nvim_win_is_valid(saved_win) then
    vim.api.nvim_set_current_win(saved_win)
  end
  force_redraw()
  return true
end

function M.show_diff(original_path, proposed_path, real_file_path, abs_file_path, action, backend)
  local file_key = abs_file_path or real_file_path
  if not file_key or file_key == "" then return end
  local cfg = require("code-preview").config
  local layout = layout_for_backend(cfg, backend)
  log.info(log.fmt("show_diff: file=%s layout=%s backend=%s active=%d",
    file_key, layout, backend or "nil", active_count()))

  if active_diffs[file_key] then
    log.debug(log.fmt("show_diff: re-edit detected, closing existing diff for %s", file_key))
    M.close_for_file(file_key)
  end

  mark_change_and_reveal(abs_file_path, action)

  local entry = {
    file_path = file_key,
    display_path = real_file_path or file_key,
    backend = backend,
    action = action,
    original_layout = layout,
    side_layout = layout == "inline" and "tab" or layout,
    original_source_path = original_path,
    proposed_source_path = proposed_path,
    original_lines = vim.deepcopy(read_file_lines(original_path)),
    proposed_lines = vim.deepcopy(read_file_lines(proposed_path)),
    host_tab = vim.api.nvim_get_current_tabpage(),
    host_win = vim.api.nvim_get_current_win(),
    preferred_side = "proposed",
  }
  local _, _, _, line_numbers = build_inline_diff(entry.original_lines, entry.proposed_lines)
  entry.line_numbers = line_numbers
  active_diffs[file_key] = entry
  render_entry(entry, layout)
  force_redraw()
end

--- Close the diff for a specific file and clean up its resources.
function M.close_for_file(file_path)
  local entry = active_diffs[file_path]
  if not entry then
    log.debug(log.fmt("close_for_file: no active diff for %s, skipping", file_path))
    return
  end

  log.info(log.fmt("close_for_file: closing diff for %s (remaining=%d)", file_path, active_count() - 1))

  -- Clear neo-tree indicator (refresh is deferred until after the tab is closed
  -- to avoid neo-tree walking a stale tabpage id)
  pcall(function() require("code-preview.changes").clear(file_path) end)

  -- Tear down only this preview's windows and buffers. This matters for the
  -- vsplit layout, whose tab may also contain normal windows or other previews.
  destroy_render(entry)
  active_diffs[file_path] = nil

  -- Refresh neo-tree after the tab is fully gone so it doesn't walk a stale tabpage.
  -- The second delayed refresh picks up the real file after the backend writes it to disk.
  vim.schedule(function()
    pcall(function() require("code-preview.neo_tree").refresh() end)
  end)
  vim.defer_fn(function()
    pcall(function() require("code-preview.neo_tree").refresh() end)
  end, 500)
end

--- Legacy close_diff — closes the most recently focused diff tab.
--- Used by backends that don't pass a file path.
function M.close_diff()
  -- Find which active diff is on the current tab
  local current_tab = vim.api.nvim_get_current_tabpage()
  for file_path, entry in pairs(active_diffs) do
    if entry.tab == current_tab then
      M.close_for_file(file_path)
      return
    end
  end
  -- Fallback: close the first one found
  for file_path, _ in pairs(active_diffs) do
    M.close_for_file(file_path)
    return
  end
end

-- Close ALL diffs and clear neo-tree indicators (for manual close via <leader>dq)
function M.close_diff_and_clear()
  log.info(log.fmt("close_diff_and_clear: closing all diffs (count=%d)", active_count()))
  -- Collect keys first to avoid modifying table during iteration
  local files = {}
  for file_path, _ in pairs(active_diffs) do
    files[#files + 1] = file_path
  end
  for _, file_path in ipairs(files) do
    M.close_for_file(file_path)
  end
  pcall(function() require("code-preview.changes").clear_all() end)
  pcall(function() require("code-preview.neo_tree").refresh() end)
end

--- Expose active_diffs for testing (read-only copy).
function M._active_diffs()
  return vim.deepcopy(active_diffs)
end

return M
