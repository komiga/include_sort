
require "lfs"
require "bit32"

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
	return string.match(path, "^(%.?%.?[^%.]*)%.?([^%.\\/]*)$")
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

function make_order_tree(extensions, root, path_value_override)
	local order_tree = {
		root = root,
		by_path = {},
		extension_value = {},
		path_value_override = path_value_override
	}

	for i, extension in ipairs(extensions) do
		order_tree.extension_value[extension] = i
	end

	local stride = 10000
	local value = 100000
	local function build_paths(path, node)
		path = (path and (path .. "/") or "") .. node.name
		-- print("cp: " .. pad(tostring(value), 6) .. " => " .. path)
		node.value = value
		node.path = path
		order_tree.by_path[path] = node
		value = value + 1
		for _, child in pairs(node.children) do
			build_paths(path, child)
		end
		node.max_value = value
	end

	for _, root_node in pairs(order_tree.root) do
		build_paths(nil, root_node)
		value = value + stride
	end

	return order_tree
end

function node_value(order_tree, path)
	local node = order_tree.by_path[path]
	return node and node.value or nil
end

function calc_path_value(order_tree, path)
	local computed_value = order_tree.path_value_override[path]
	if not computed_value then
		computed_value = node_value(order_tree, path)
	end
	if not computed_value then
		local node
		for i = string.len(path), 1, -1 do
			if string.sub(path, i, i) == '/' then
				node = order_tree.by_path[string.sub(path, 1, i - 1)]
				if node ~= nil then
					computed_value = node.max_value
					break
				end
			end
		end
	end
	-- Relative to maximum
	if computed_value ~= nil and computed_value < 0 then
		computed_value = bit32.bnot(0) + computed_value
	end
	return computed_value
end

function extension_value(order_tree, extension)
	if extension == nil then
		return 0
	end
	local value = order_tree.extension_value[extension]
	return value or 999
end

function parse(order_tree, stream, threshold)
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
	local path_value
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
			path_value = calc_path_value(order_tree, path)
			table.insert(includes, {
				position = line_position,
				line = line,
				path = path,
				extension = extension,
				path_value = path_value,
				extension_value = extension_value(order_tree, extension),
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

function sort(order_tree, data)
	local function less_func(x, y)
		return include_less(order_tree, x, y)
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

function process_file(order_tree, path)
	local stream, err = io.open(path, "r")
	if stream == nil then
		error("failed to read '" .. path .. "': " .. err)
	end
	local data = parse(order_tree, stream, 150)
	stream:close()
	if sort(order_tree, data) then
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

function process_dir(order_tree, dir, exclusions, extension_filter)
	dir = trim_trailing_slash(dir)
	local full_path
	for path, _ in iterate_dir(dir, "file") do
		local full_path = dir .. '/' .. path
		local _, extension = split_path(path)
		if
			extension_filter == nil or extension_filter[extension] ~= nil or
			exclusions == nil or exclusions[path] ~= nil
		then
			local modified = process_file(order_tree, full_path)
			print(pad(modified and "reordered" or "OK", 10, true) .. ": " .. path)
		end
	end
end

function N(name, children)
	children = children or {}
	return {name = name, children = children}
end

function main(arguments)
	if #arguments == 0 then
		print("usage: include_sort <config_file> [directory [...]]")
		return 0
	end

	config = {}
	dofile(arguments[1])

	if config.exec ~= nil then
		return config.exec(arguments)
	else
		local paths = config.paths
		if #arguments > 1 then
			paths = {}
			for i = 2, #arguments do
				table.insert(paths, arguments[i])
			end
		end
		for _, path in pairs(paths) do
			print("processing directory: '" .. path .. "'")
			process_dir(
				config.order_tree,
				path,
				config.exclusions,
				config.extension_filter
			)
			print()
		end
	end
	return 0
end

os.exit(main(arg))
