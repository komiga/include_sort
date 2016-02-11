
require "lfs"

DEBUG_MODE = false

function min(x, y)
	return (x < y) and x or y
end

function max(x, y)
	return (x > y) and x or y
end

function pad(str, length, append)
	if #str < length then
		while #str < length do
			if append then
				str = str .. ' '
			else
				str = ' ' .. str
			end
		end
	end
	return str
end

function make_inverse_table(t, value)
	local it = {}
	for k, v in pairs(t) do
		it[v] = value or k
	end
	return it
end

function table_last(t)
	return t[#t]
end

function trim_trailing_slash(path)
	if string.sub(path, -1) == "/" then
		path = string.sub(path, 1, -2)
	end
	return path
end

--[[assert(trim_trailing_slash("a") == "a")
assert(trim_trailing_slash("a/") == "a")--]]

function split_string(s, sep, plain)
	assert(sep ~= nil)
	if sep == "" then
		return {s}
	end

	local start = 1
	local done = false
	local function pass(i, j, ...)
		if i then
			local seg = s:sub(start, i - 1)
			start = j + 1
			return seg, ...
		else
			done = true
			return s:sub(start)
		end
	end

	local t = {}
	while not done do
		table.insert(t, pass(s:find(sep, start, plain)))
	end
	return t
end

function split_path(path)
	local name, extension = string.match(path, "^(%.?%.?.*)%.([^%.\\/]*)$")
	return (name or path), extension
end

--[[local function test_split_path(path, name, extension)
	local t_name, t_extension = split_path(path)
	assert(t_name == name)
	assert(t_extension == extension)
end

test_split_path("", "", nil)
test_split_path("a", "a", nil)
test_split_path("a/b", "a/b", nil)
test_split_path("a/b.c", "a/b", "c")
test_split_path("a.b/c", "a.b/c", nil)
test_split_path("a.b/c.d", "a.b/c", "d")
test_split_path("luajit-2.0/lua.h", "luajit-2.0/lua", "h")--]]

local BYTE_SLASH = string.byte('/', 1)
local BYTE_DOT = string.byte('.', 1)

function dirname(s)
	s = trim_trailing_slash(s)
	for i = #s, 1, -1 do
		if string.byte(s, i) == BYTE_SLASH then
			return string.sub(s, 1, i - 1)
		end
	end
	return s
end

--[[assert(dirname("") == "")
assert(dirname("a") == "a")
assert(dirname("a/b") == "a")
assert(dirname("a/b/c/") == "a/b")--]]

function basename(s)
	s = trim_trailing_slash(s)
	local d = 0
	for i = #s, 1, -1 do
		if string.byte(s, i) == BYTE_DOT then
			d = i
			break
		end
	end
	for i = #s, 1, -1 do
		if string.byte(s, i) == BYTE_SLASH and i ~= #s then
			if i < d then
				return string.sub(s, i + 1, d - 1)
			else
				return string.sub(s, i + 1, #s)
			end
		end
	end
	return s
end

--[[assert(basename("") == "")
assert(basename("a") == "a")
assert(basename("a/b") == "b")
assert(basename("a/b/c/") == "c")--]]

function scoped_call(path, f, ...)
	local pd = lfs.currentdir()
	lfs.chdir(path)
	local r = f(...)
	lfs.chdir(pd)
	return r
end

function insertion_sort(less_func, t, first, last)
	assert(less_func ~= nil)
	assert(t ~= nil)

	first = first or 1
	last = last or #t

	local modified = false
	local ivalue, j
	for i = first + 1, last, 1 do
		local ivalue = t[i]

		-- Shift elements behind ivalue down until ivalue would
		-- be in its sub-sorted position
		j = i
		while j > first and less_func(ivalue, t[j - 1]) do
			t[j] = t[j - 1]
			j = j - 1
		end

		-- Place ivalue in its position if it moved
		if j ~= i then
			t[j] = ivalue
			modified = true
		end
	end
	return modified
end

--[[function test_insertion_sort(values)
	local function less_func(x, y)
		return x < y
	end
	local copy = {}
	for _, v in pairs(values) do
		table.insert(copy, v)
	end
	local modified = insertion_sort(less_func, values)
	table.sort(copy)
	for i = 1, #values do
		assert(values[i] == copy[i])
	end
	return modified
end

assert(
	not test_insertion_sort({}) and
	not test_insertion_sort({1, 2}) and
	not test_insertion_sort({1, 2, 3}) and
	test_insertion_sort({2, 1}) and
	test_insertion_sort({2, 3, 1}) and
	test_insertion_sort({39, 13, 4}) and
	true
)--]]

function iterate_dir(dir, select_only)
	assert(dir and dir ~= "", "directory parameter is missing or empty")
	dir = trim_trailing_slash(dir)

	local function yield_tree(base, path)
		for entry in lfs.dir(base .. path) do
			if entry ~= "." and entry ~= ".." then
				entry = path .. "/" .. entry
				local attr = lfs.attributes(base .. entry)
				if select_only == nil or attr.mode == select_only then
					coroutine.yield(string.sub(entry, 2), attr)
				end
				if attr.mode == "directory" then
					yield_tree(base, entry)
				end
			end
		end
	end

	return coroutine.wrap(
		function()
			yield_tree(dir, "")
		end
	)
end

function include_tostring(include)
	return (
		pad(tostring(include.position), 4) .. " " ..
		pad(tostring(include.path_value or "--------"), 8) .. " " ..
		pad(tostring(include.extension_value or "---"), 3) .. " " ..
		pad(include.extension or "", 3, true) .. " " ..
		(include.path or "")
	)
end

function make_order_tree(tree, extension_order, path_value, value_filter)
	path_value = path_value or {}
	extension_order = extension_order or {}
	local order_tree = {
		root = tree,
		by_path = {},
		path_value = path_value,
		extension_value = {},
		value_filter = value_filter,
	}
	local last_extension_value = 0
	for i, extension in ipairs(extension_order) do
		order_tree.extension_value[extension] = i
		last_extension_value = i
	end

	local stride = 10000
	local value = 100000
	local function build_paths(path, root, node)
		path = (path and (path .. "/") or "") .. node.name
		-- print("cp: " .. pad(tostring(value), 6) .. " => " .. path)
		node.root = root
		node.path = path
		order_tree.by_path[path] = node
		if not node.value_post then
			node.value = value
			value = value + 1
		end
		for _, child in pairs(node.children) do
			build_paths(path, root, child)
		end
		if node.value_post then
			node.value = value
			value = value + 1
		end
		node.max_value = value
	end

	for _, root in pairs(order_tree.root) do
		assert(root._is_root)
		root.extension_value = {}
		for i, extension in ipairs(root.extension_order) do
			root.extension_value[extension] = last_extension_value + i
		end
		build_paths(nil, root, root)
		value = value + stride
	end

	return order_tree
end

function calc_path_value(config, path, extension)
	local node = nil
	local value_filter = nil
	local value = {
		path_value = config.order_tree.path_value[path],
		extension_value = config.order_tree.extension_value[extension],
	}
	local function update(from_node, max)
		if not from_node then
			return
		end
		node = node or from_node
		if value.path == nil then
			value.path = node.root.path_value[path] or (max and node.max_value or node.value)
		end
		if value.extension == nil then
			value.extension = node.root.extension_value[extension]
		end
		if value_filter == nil then
			value_filter = node.root.value_filter
		end
	end
	update(config.order_tree.by_path[path])
	if not node then
		for i = string.len(path), 1, -1 do
			if string.sub(path, i, i) == '/' then
				update(config.order_tree.by_path[string.sub(path, 1, i - 1)], true)
				if node then
					break
				end
			end
		end
	end
	value_filter = value_filter or config.order_tree.value_filter
	if value_filter then
		value_filter(config, path, extension, value)
	end
	if value.path == nil then
		value.extension = nil
	else
		-- Relative to maximum
		if value.path < 0 then
			value.path = 0xFFFFFFFF + value.path
		end
		if value.extension == nil then
			value.extension = extension == "" and 0 or 999
		end
	end
	return value.path, value.extension
end

function parse(config, stream, threshold)
	assert(threshold > 0)
	local data = {
		source = {},
		include_blocks = {},
		terminated = false,
	}
	local line = ""
	local accum = ""
	local line_position = 1
	local start_position = nil
	local path, extension
	local path_value, extension_value
	local includes = {}
	while true do
		line = stream:read("*l")
		if line == nil or threshold < line_position then
			break
		end
		path = string.match(line, "#include.+[<\"](.+)[>\"]")
		if path ~= nil then
			if accum ~= "" then
				table.insert(data.source, accum)
				accum = ""
			end
			if start_position == nil then
				start_position = line_position
			end
			path, extension = split_path(path)
			path_value, extension_value = calc_path_value(config, path, extension)
			table.insert(includes, {
				position = line_position,
				line = line,
				path = path,
				extension = extension,
				path_value = path_value,
				extension_value = extension_value,
			})
		else
			if start_position ~= nil then
				table.insert(data.include_blocks, {
					position = start_position,
					includes = includes
				})
				table.insert(data.source, table_last(data.include_blocks))
				start_position = nil
				includes = {}
			end
			accum = accum .. line .. '\n'
		end
		line_position = line_position + 1
	end
	if start_position ~= nil then
		table.insert(data.include_blocks, {
			position = start_position,
			includes = includes
		})
		table.insert(data.source, table_last(data.include_blocks))
	end
	if line ~= nil then
		data.terminated = true
		accum = accum .. line .. '\n'
	end
	if accum ~= "" then
		table.insert(data.source, accum)
	end
	if line ~= nil then
		table.insert(data.source, stream:read("*a"))
	end
	return data
end

function include_less(order_tree, x, y)
	if x.path_value == nil and y.path_value == nil then
		-- Don't touch blocks that have no value through the order tree
		return false
		-- return x.extension_value < y.extension_value
	elseif x.path_value == nil then
		return false
	elseif y.path_value == nil then
		return true
	else
		local d = x.path_value - y.path_value
		if d < 0 then
			return true
		elseif d == 0 then
			return x.extension_value < y.extension_value
		else
			return false
		end
	end
end

function sort(config, data)
	local function less_func(x, y)
		return include_less(config.order_tree, x, y)
	end

	local modified = false
	for _, include_block in pairs(data.include_blocks) do
		modified = insertion_sort(less_func, include_block.includes) or modified
	end

	if DEBUG_MODE then
		for _, include_block in pairs(data.include_blocks) do
			print(pad(tostring(include_block.position), 3, true) .. ":")
			for _, include in pairs(include_block.includes) do
				print("    " .. include_tostring(include))
			end
		end
		if modified then
			print("modified")
		end
	end
	return modified
end

function process_file(config, path)
	local stream, err = io.open(path, "r")
	if stream == nil then
		error("failed to read '" .. path .. "': " .. err)
	end
	local data = parse(config, stream, 150)
	stream:close()
	if sort(config, data) then
		stream = io.open(path, "w+")
		for _, s in pairs(data.source) do
			if type(s) == "table" then
				for _, include in pairs(s.includes) do
					stream:write(include.line .. '\n')
				end
			else
				stream:write(s)
			end
		end
		stream:close()
		return true
	end
	return false
end

function process_dir(config, dir)
	dir = trim_trailing_slash(dir)
	local full_path
	for path, _ in iterate_dir(dir, "file") do
		local full_path = dir .. '/' .. path
		local _, extension = split_path(path)
		if
			(config.extension_filter == nil or config.extension_filter[extension] ~= nil) and
			(config.exclusions == nil or config.exclusions[path] == nil)
		then
			local modified = process_file(config, full_path)
			local status = modified and "reordered" or "OK"
			if modified or config.print_ok then
				print(pad(status, 10, true) .. ": " .. path)
			end
		end
	end
end

function node_value_post(node)
	node.value_post = true
	return node
end

function N(name, children)
	return {
		name = name,
		children = children or {}
	}
end

function R(name, children, extension_order, path_value, value_filter)
	return {
		_is_root = true,
		name = name,
		children = children or {},
		extension_order = extension_order or {},
		path_value = path_value or {},
		value_filter = value_filter
	}
end

function new_config()
	return {
		print_ok = true,
		append_arg_paths = false,
		exclusions = {},
		extension_filter = nil,
		order_tree = nil,
		paths = {},
		exec = nil,
	}
end

function validate_config(config)
	assert(config.order_tree, "config is missing order tree")
end

function main(arguments)
	if #arguments == 0 then
		print("usage: include_sort <config_file> [directory [...]]")
		return 0
	end

	local config = dofile(arguments[1])
	validate_config(config)
	if config.exec ~= nil then
		return config.exec(arguments)
	else
		local paths = config.paths
		if #arguments > 1 then
			paths = config.append_arg_paths and paths or {}
			for i = 2, #arguments do
				table.insert(paths, arguments[i])
			end
		end
		if #paths == 0 then
			print("include_sort: no paths")
		else
			for _, path in pairs(paths) do
				print("processing directory: '" .. path .. "'")
				process_dir(config, path)
				print()
			end
		end
	end
	return 0
end

os.exit(main(arg))
