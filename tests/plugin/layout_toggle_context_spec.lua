-- layout_toggle_context_spec.lua — Runtime preview layout and context API tests.

local diff = require("code-preview.diff")
local changes = require("code-preview.changes")
local plugin = require("code-preview")

local function tmp_file(name, content)
  local path = vim.fn.tempname() .. "_" .. name
  local file = assert(io.open(path, "w"))
  file:write(content)
  file:close()
  return path
end

local function show(layout, key, original, proposed)
  plugin.config.diff.layout = layout
  local orig = tmp_file("toggle_orig.txt", original)
  local prop = tmp_file("toggle_prop.txt", proposed)
  diff.show_diff(orig, prop, key:match("[^/]+$"), key)
  return orig, prop
end

local function local_mapping(buf, lhs)
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if mapping.lhs == lhs then return mapping end
  end
end

describe("runtime preview layout", function()
  local saved_layout
  local saved_keys

  before_each(function()
    diff.close_diff_and_clear()
    changes.clear_all()
    saved_layout = plugin.config.diff.layout
    saved_keys = vim.deepcopy(plugin.config.keys)
  end)

  after_each(function()
    diff.close_diff_and_clear()
    plugin.config.diff.layout = saved_layout
    plugin.config.keys = saved_keys
  end)

  it("round-trips tab to inline and back while preserving the proposed cursor line", function()
    local key = "/abs/round-trip.lua"
    local orig, prop = show("tab", key, "one\nold\nthree\n", "one\nnew\nthree\n")

    vim.api.nvim_win_set_cursor(0, { 2, 1 })
    assert.equals("proposed", diff.get_context().side)

    assert.is_true(diff.toggle_layout())
    local inline = diff.get_context()
    assert.equals("inline", inline.layout)
    assert.equals(2, inline.cursor.new_line)

    assert.is_true(diff.toggle_layout())
    local side = diff.get_context()
    assert.equals("tab", side.layout)
    assert.equals("proposed", side.side)
    assert.equals(2, side.cursor.line)

    os.remove(orig)
    os.remove(prop)
  end)

  it("returns to an original vsplit layout without replacing its host window", function()
    local key = "/abs/vsplit-round-trip.lua"
    local host_buf = vim.api.nvim_get_current_buf()
    local tabs_before = #vim.api.nvim_list_tabpages()
    local wins_before = #vim.api.nvim_tabpage_list_wins(0)
    local orig, prop = show("vsplit", key, "old\n", "new\n")

    assert.equals(tabs_before, #vim.api.nvim_list_tabpages())
    assert.is_true(diff.toggle_layout())
    assert.equals("inline", diff._active_diffs()[key].layout)
    assert.is_true(diff.toggle_layout())
    assert.equals("vsplit", diff._active_diffs()[key].layout)
    assert.equals(tabs_before, #vim.api.nvim_list_tabpages())
    assert.equals(wins_before + 2, #vim.api.nvim_tabpage_list_wins(0))
    assert.is_true(vim.api.nvim_buf_is_valid(host_buf))

    os.remove(orig)
    os.remove(prop)
  end)

  it("infers the target preview from a supplied preview buffer", function()
    local key = "/abs/inferred.lua"
    local orig, prop = show("tab", key, "before\n", "after\n")
    local entry = diff._active_diffs()[key]

    vim.api.nvim_set_current_buf(entry.orig_buf)
    assert.is_true(diff.toggle_layout())
    assert.equals("inline", diff._active_diffs()[key].layout)

    os.remove(orig)
    os.remove(prop)
  end)

  it("uses stored snapshots after the source tempfiles are deleted", function()
    local key = "/abs/deleted-sources.lua"
    local orig, prop = show("tab", key, "original snapshot\n", "proposed snapshot\n")
    os.remove(orig)
    os.remove(prop)
    local status = changes.get(key)

    -- The testing accessor is a deep copy: external mutation cannot alter the
    -- private snapshots subsequently used to render.
    local exposed = diff._active_diffs()[key]
    exposed.original_lines[1] = "tampered"

    assert.is_true(diff.toggle_layout(key))
    local inline_lines = vim.api.nvim_buf_get_lines(diff._active_diffs()[key].bufs[1], 0, -1, false)
    assert.equals("original snapshot", inline_lines[1])
    assert.equals("proposed snapshot", inline_lines[2])
    assert.equals(status, changes.get(key))
    assert.is_true(diff.toggle_layout(key))
    assert.equals(status, changes.get(key))

    local entry = diff._active_diffs()[key]
    assert.same({ "original snapshot" }, vim.api.nvim_buf_get_lines(entry.orig_buf, 0, -1, false))
    assert.same({ "proposed snapshot" }, vim.api.nvim_buf_get_lines(entry.prop_buf, 0, -1, false))
  end)

  it("toggles only the requested preview when another preview is active", function()
    local a = "/abs/first.lua"
    local b = "/abs/second.lua"
    local a_orig, a_prop = show("tab", a, "a old\n", "a new\n")
    local b_orig, b_prop = show("tab", b, "b old\n", "b new\n")
    local before = diff._active_diffs()[b]
    local current_win = vim.api.nvim_get_current_win()

    assert.is_true(diff.toggle_layout(a))
    local after = diff._active_diffs()[b]
    assert.equals("tab", after.layout)
    assert.equals(before.tab, after.tab)
    assert.same(before.bufs, after.bufs)
    assert.equals(current_win, vim.api.nvim_get_current_win())
    assert.is_true(diff.is_open(a))
    assert.is_true(diff.is_open(b))

    os.remove(a_orig)
    os.remove(a_prop)
    os.remove(b_orig)
    os.remove(b_prop)
  end)

  it("keeps the toggle key buffer-local and honors keys=false/per-key=false", function()
    local key = "/abs/keymap.lua"
    local orig, prop = show("tab", key, "old\n", "new\n")
    local buf = diff._active_diffs()[key].prop_buf
    assert.is_not_nil(local_mapping(buf, "\\dt"))
    diff.close_for_file(key)

    plugin.config.keys = false
    diff.show_diff(orig, prop, "keymap.lua", key)
    assert.is_nil(local_mapping(diff._active_diffs()[key].prop_buf, "\\dt"))
    diff.close_for_file(key)

    plugin.config.keys = vim.deepcopy(saved_keys)
    plugin.config.keys.toggle_layout = false
    diff.show_diff(orig, prop, "keymap.lua", key)
    assert.is_nil(local_mapping(diff._active_diffs()[key].prop_buf, "\\dt"))
    assert.equals(2, vim.fn.exists(":CodePreviewToggleLayout"))
    assert.is_not_nil(vim.fn.maparg("<Plug>(CodePreviewToggleLayout)", "n"))

    os.remove(orig)
    os.remove(prop)
  end)
end)

describe("preview context API", function()
  local saved_layout

  before_each(function()
    diff.close_diff_and_clear()
    saved_layout = plugin.config.diff.layout
  end)

  after_each(function()
    diff.close_diff_and_clear()
    plugin.config.diff.layout = saved_layout
  end)

  it("returns side-by-side selection context and nil outside preview buffers", function()
    local key = "/workspace/context.lua"
    local orig, prop = show("tab", key, "same\nold\ntail\n", "same\nnew\ntail\n")
    local entry = diff._active_diffs()[key]
    local context = diff.get_context({ bufnr = entry.orig_buf, start_line = 1, end_line = 2 })

    assert.equals(key, context.file_path)
    assert.equals("context.lua", context.display_path)
    assert.equals("tab", context.layout)
    assert.equals("original", context.side)
    assert.same({ "same", "old" }, context.selected_lines)
    assert.equals("same\nold", context.selected_text)
    assert.same({ start_line = 1, end_line = 2 }, context.range)
    assert.same({ buffer_line = 1, old_line = 1, new_line = 1 }, context.line_mappings[1])
    assert.same({ buffer_line = 2, old_line = 2 }, context.line_mappings[2])

    vim.cmd("tabfirst")
    assert.is_nil(diff.get_context())

    os.remove(orig)
    os.remove(prop)
  end)

  it("resolves a requested preview buffer window across tabs", function()
    local first_key = "/workspace/first-context.lua"
    local second_key = "/workspace/second-context.lua"
    local first_orig, first_prop = show(
      "tab", first_key, "one\ntwo\nthree\n", "one\nTWO\nthree\n")
    local first = diff._active_diffs()[first_key]
    vim.api.nvim_win_set_cursor(first.prop_win, { 3, 2 })

    local second_orig, second_prop = show("tab", second_key, "left\n", "right\n")
    assert.equals(second_key, diff.get_context().file_path)

    local context = diff.get_context({ bufnr = first.prop_buf, start_line = 2, end_line = 3 })
    assert.equals(first_key, context.file_path)
    assert.equals("proposed", context.side)
    assert.same({ line = 3, column = 2, old_line = 3, new_line = 3 }, context.cursor)
    assert.same({ start_line = 2, end_line = 3 }, context.range)
    assert.same({ "TWO", "three" }, context.selected_lines)

    os.remove(first_orig)
    os.remove(first_prop)
    os.remove(second_orig)
    os.remove(second_prop)
  end)

  it("keeps changed content beginning with diff marker characters", function()
    local key = "/workspace/marker-content.lua"
    local orig, prop = show("inline", key, "-- removed\n", "++ added\n")
    local entry = diff._active_diffs()[key]
    local context = diff.get_context({ bufnr = entry.bufs[1], start_line = 1, end_line = 2 })

    assert.same({ "-- removed", "++ added" }, context.selected_lines)
    assert.same({ buffer_line = 1, old_line = 1 }, context.line_mappings[1])
    assert.same({ buffer_line = 2, new_line = 1 }, context.line_mappings[2])

    os.remove(orig)
    os.remove(prop)
  end)

  it("does not map empty-side placeholder lines to nonexistent snapshot lines", function()
    local created_key = "/workspace/created.lua"
    local created_orig, created_prop = show("tab", created_key, "", "created\n")
    local created = diff._active_diffs()[created_key]
    local original_context = diff.get_context({ bufnr = created.orig_buf })
    local proposed_context = diff.get_context({ bufnr = created.prop_buf })

    assert.same({ buffer_line = 1 }, original_context.line_mappings[1])
    assert.is_nil(original_context.cursor.old_line)
    assert.is_nil(original_context.cursor.new_line)
    assert.same({ buffer_line = 1, new_line = 1 }, proposed_context.line_mappings[1])
    diff.close_for_file(created_key)

    local deleted_key = "/workspace/deleted.lua"
    local deleted_orig, deleted_prop = show("tab", deleted_key, "deleted\n", "")
    local deleted = diff._active_diffs()[deleted_key]
    local deleted_original_context = diff.get_context({ bufnr = deleted.orig_buf })
    local deleted_proposed_context = diff.get_context({ bufnr = deleted.prop_buf })

    assert.same({ buffer_line = 1, old_line = 1 }, deleted_original_context.line_mappings[1])
    assert.same({ buffer_line = 1 }, deleted_proposed_context.line_mappings[1])
    assert.is_nil(deleted_proposed_context.cursor.old_line)
    assert.is_nil(deleted_proposed_context.cursor.new_line)

    os.remove(created_orig)
    os.remove(created_prop)
    os.remove(deleted_orig)
    os.remove(deleted_prop)
  end)

  it("returns inline old/new mappings for removed and added lines", function()
    local key = "/workspace/inline.lua"
    local orig, prop = show("inline", key, "same\nold\ntail\n", "same\nnew\ntail\n")
    local entry = diff._active_diffs()[key]
    local context = diff.get_context({ bufnr = entry.bufs[1], start_line = 1, end_line = 4 })

    assert.equals("inline", context.layout)
    assert.equals("inline", context.side)
    assert.same({ buffer_line = 1, old_line = 1, new_line = 1 }, context.line_mappings[1])
    assert.same({ buffer_line = 2, old_line = 2 }, context.line_mappings[2])
    assert.same({ buffer_line = 3, new_line = 2 }, context.line_mappings[3])
    assert.same({ buffer_line = 4, old_line = 3, new_line = 3 }, context.line_mappings[4])

    os.remove(orig)
    os.remove(prop)
  end)
end)
