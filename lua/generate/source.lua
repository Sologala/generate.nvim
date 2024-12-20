local api = vim.api
local uv = vim.loop
local ts = vim.treesitter
local fn = vim.fn

local ts_util = require('generate.treesitter')
local fs = require('generate.filesystem')

local M = {
  header_bufnr = -1,
  source_bufnr = -1,
}

local declaration_query = ts_util.parse_query_wrapper(
  'cpp',
  [[
    ((function_definition) @method)

    ((template_declaration) @template)
]]
)

local default_param_query = ts_util.parse_query_wrapper(
  'cpp',
  [[
    ((optional_parameter_declaration) @parameter)
]]
)

-- TODO: Delegate this to user config
local brace_pattern = '\n{\n\n}\n\n'

local function is_include_present(root, bufnr, include)
  local includes = ts_util.children_with_type('preproc_include', root)
  for i = 1, #includes do
    local text = ts.get_node_text(includes[i], bufnr, {})
    if string.match(text, include) then
      return true
    end
  end

  return false
end

local function declaration_to_implementation(declaration, namespace, bufnr)
  local prefix = namespace .. '::'
  local text = ts.get_node_text(declaration, bufnr, {})

  -- Remove keywords that shouldn't be present in method implementations
  local keywords = { 'virtual', 'override', 'final', 'static', 'explicit', 'friend' }
  for k = 1, #keywords do
    local pattern = keywords[k] .. '%s*'
    text = string.gsub(text, pattern, '')
  end

  -- Add prefix (i.e. ClassName::)
  local declarator = ts_util.first_child_with_type('function_declarator', declaration)
  if declarator == nil then
    local child = ts_util.first_child_with_type('declaration', declaration)
    declarator = ts_util.first_child_with_type('function_declarator', child)
  end
  local identifier = ts_util.declarator_identifier(declarator)
  local function_name = ts.get_node_text(identifier, bufnr, {})
  function_name = string.gsub(function_name, '%W', '%%%1')
  text = string.gsub(text, function_name, prefix .. function_name)

  -- Remove semicolon
  text = string.sub(text, 1, -2)

  -- Remove default value
  for _, node, _ in default_param_query:iter_captures(declaration, M.header_bufnr) do
    local dirty = ts.get_node_text(node, M.header_bufnr, {})
    local clean = string.gsub(dirty, '%s*=.*', '')
    dirty = string.gsub(dirty, '%W', '%%%1')
    text = string.gsub(text, dirty, clean)
  end

  return text
end

local function get_implemenations(root)
  local strings = {}

  for _, node, _ in declaration_query:iter_captures(root, 0) do
    local text = ts.get_node_text(node, 0, {})
    text = string.gsub(text, '%).*', '')
    text = text .. ')'
    table.insert(strings, text)
  end

  return strings
end

function M.implement_methods(namespaces)
  local path = api.nvim_buf_get_name(0)
  local root, _ = fs.open_file_in_buffer(path)

  local strings = {}
  local existing_implemenations = get_implemenations(root)
  for _, v in pairs(namespaces) do
    local name = v['name']
    for i = 1, #v['declarations'] do
      local declaration = v['declarations'][i]
      local implementation = declaration_to_implementation(declaration, name, M.header_bufnr)
      local implementation_title = string.gsub(implementation, '%).*', '')
      implementation_title = implementation_title .. ')'
      if not vim.tbl_contains(existing_implemenations, implementation_title) then
        table.insert(strings, implementation .. brace_pattern)
      end
    end
  end

  local fd = uv.fs_open(path, 'a', 438)
  uv.fs_write(fd, strings, 0)
  uv.fs_close(fd)

  -- It is neccessary to reload the buffer because
  -- in some cases Neovim doesn't render the newly
  -- added text.
  api.nvim_command(":edit")
end

function M.insert_header(header_path, source_path)
  local name = fn.fnamemodify(header_path, ':t')
  local header_text = '#include "' .. name .. '"'

  local header_bufnr = api.nvim_get_current_buf()
  M.header_bufnr = header_bufnr
  local root, source_bufnr = fs.open_file_in_buffer(source_path)
  M.source_bufnr = source_bufnr

  if not is_include_present(root, M.source_bufnr, name) then
    fs.append_to_file(source_path, header_text .. '\n\n')
  end
end

return M
