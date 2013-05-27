-- Internal persistence library

--[[ Provides ]]
-- persistence.store(path, ...): Stores arbitrary items to the file at the given path
-- persistence.load(path): Loads files that were previously stored with store and returns them

--[[ Limitations ]]
-- Does not export userdata, threads or most function values
-- Function export is not portable

--[[ License: MIT (see bottom) ]]

-- Private methods
local write, writeIndent, writers, refCount

local SINGLE_LINE_ARRAY_THRESHOLD = 10
local SINGLE_LINE_ARRAY_STRING_THRESHOLD = 20

persistence =
{
	store = function (path, ...)
		local file, e
		if type(path) == "string" then
			-- Path, open a file
			file, e = io.open(path, "w")
			if not file then
				return error(e)
			end
		else
			-- Just treat it as file
			file = path
		end
		local n = select("#", ...)
		-- Count references
		local objRefCount = {} -- Stores reference that will be exported
		for i = 1, n do
			refCount(objRefCount, (select(i,...)))
		end
		-- Export Objects with more than one ref and assign name
		-- First, create empty tables for each
		local objRefNames = {}
		local objRefIdx = 0
		file:write("-- Persistent Data\n")

		for obj, count in pairs(objRefCount) do
			if count > 1 then
				if objRefIdx <= 0 then
					file:write("local multiRefObjects = {\n")
				end
				objRefIdx = objRefIdx + 1
				objRefNames[obj] = objRefIdx
				file:write("{},") -- table objRefIdx
			end
		end
		if objRefIdx > 0 then
			file:write("\n} -- multiRefObjects\n")
		end

		-- Then fill them (this requires all empty multiRefObjects to exist)
		for obj, idx in pairs(objRefNames) do
			for k, v in pairs(obj) do
				file:write("multiRefObjects["..idx.."][")
				write(file, k, 0, objRefNames)
				file:write("] = ")
				write(file, v, 0, objRefNames)
				file:write("\n")
			end
		end

		-- Create the remaining objects
		if n <= 0 then
			file:write("return")
		elseif n == 1 then
			file:write("return ")
			write(file, (select(1,...)), 0, objRefNames)
		else
			for i = 1, n do
				file:write("local ".."obj"..i.." = ")
				write(file, (select(i,...)), 0, objRefNames)
				file:write("\n")
			end
			file:write("return obj1")
			for i = 2, n do
				file:write(" ,obj"..i)
			end
		end
		file:write("\n")
		file:close()
	end,

	load = function (path)
		local f, e = loadfile(path)
		if f then
			return f()
		else
			return nil, e
		end
	end
}

-- Private methods

local function append(t, ...)
	local args = {...}
	for _, v in ipairs(args) do
		table.insert(t, v)
	end
end

local function append_indent(buf, level)
	local indent = string.rep("\t", level)
	append(buf, indent)
end

local function append_value(buf, value, level, objRefNames)
	writers[type(value)](buf, value, level, objRefNames)
end

-- write thing (dispatcher)
write = function (file, item, level, objRefNames)
	local buf = {}
	writers[type(item)](buf, item, level, objRefNames)
	file:write(table.concat(buf))
end

-- write indent
writeIndent = function (file, level)
	file:write(string.rep("\t", level))
end

-- recursively count references
refCount = function (objRefCount, item)
	-- only count reference types (tables)
	if type(item) == "table" then
		-- Increase ref count
		if objRefCount[item] then
			objRefCount[item] = objRefCount[item] + 1
		else
			objRefCount[item] = 1
			-- If first encounter, traverse
			for k, v in pairs(item) do
				refCount(objRefCount, k)
				refCount(objRefCount, v)
			end
		end
	end
end

local key_words = {
	"and", "break",	"do", "else", "elseif", "end", "false", "for", "function", "if", "in",
	"local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
}
for _, v in ipairs(key_words) do
	key_words[v] = true
end

local function is_key_word(str)
	if type(str) ~= "string" then return false end
	return key_words[str] and true or false
end

local function is_iden(str)
	return not is_key_word(str) and str:match("^[%a_][%w_]*$")
end

-- use __key_seq metainfo to sort the keys
local function get_table_key_seq(t)
	local mt = getmetatable(t)
	if not mt then return {} end

	return mt.__key_seq or {}
end

-- Format items for the purpose of restoring
writers = {
	["nil"] = function (buf, item)
			append(buf, "nil")
		end,
	["number"] = function (buf, item)
			append(buf, tostring(item))
		end,
	["string"] = function (buf, item)
			append(buf, string.format("%q", item))
		end,
	["boolean"] = function (buf, item)
			append(buf, item and "true" or "false")
		end,
	["table"] = function (buf, item, level, objRefNames)
			local refIdx = objRefNames[item]
			if refIdx then
				-- Table with multiple references
				append(buf, "multiRefObjects["..refIdx.."]")
			else
				-- Single use table
				if not next(item) then
					append(buf, "{}")
					return
				end

				local function is_single_line_array(value)
					if type(value) ~= "table" then return false end
					local keys_count = 0
					for k, v in pairs(value) do
						keys_count = keys_count + 1
						if keys_count > SINGLE_LINE_ARRAY_THRESHOLD or keys_count > #value then 
							return false
						end
						if type(v) == "table" then
							return false
						elseif type(v) == "string" and #v > SINGLE_LINE_ARRAY_STRING_THRESHOLD then
							return false
						end
					end
					return true
				end

				local function append_pair(buf, level, k, v)
					append_indent(buf, level)
					if type(k) == "string" and is_iden(k) then
						append(buf, k .. " = ")
					else
						append(buf, "[")
						append_value(buf, k, level, objRefNames)
						append(buf, "] = ")
					end
					append_value(buf, v, level, objRefNames)
					append(buf, ",\n")
				end

				local function append_array_part(buf, level, item, key_collector)
					for i, v in ipairs(item) do
						key_collector[i] = true
						append_indent(buf, level)
						append_value(buf, v, level, objRefNames)
						append(buf, ",\n")
					end
				end

				local function append_map_part(buf, level, item, array_keys)
					local key_seq = get_table_key_seq(item)
					local used_keys = {}
					for _, k in ipairs(key_seq) do
						if not array_keys[k] then
							local v = item[k]
							append_pair(buf, level, k, v)
							used_keys[k] = true
						end
					end
					for k, v in pairs(item) do
						if not array_keys[k] and not used_keys[k] then
							append_pair(buf, level, k, v)
						end
					end
				end

				append(buf, "{")
				if is_single_line_array(item) then
					for i, v in ipairs(item) do
						append_value(buf, v, level, objRefNames)
						append(buf, ", ")
					end
				else
					append(buf, "\n")

					local array_keys = {}
					append_array_part(buf, level + 1, item, array_keys)
					append_map_part(buf, level + 1, item, array_keys)
				end
				append_indent(buf, level)
				append(buf, "}")
			end
		end,
	["function"] = function (buf, item)
			-- Does only work for "normal" functions, not those
			-- with upvalues or c functions
			local dInfo = debug.getinfo(item, "uS")
			if dInfo.nups > 0 then
				append(buf, "nil --[[functions with upvalue not supported]]")
			elseif dInfo.what ~= "Lua" then
				append(buf, "nil --[[non-lua function not supported]]")
			else
				local r, s = pcall(string.dump,item)
				if r then
					append(buf, string.format("loadstring(%q)", s))
				else
					append(buf, "nil --[[function could not be dumped]]")
				end
			end
		end,
	["thread"] = function (buf, item)
			append(buf, "nil --[[thread]]\n")
		end,
	["userdata"] = function (buf, item)
			append(buf, "nil --[[userdata]]\n")
		end,
}

return persistence

--[[
 Copyright (c) 2010 Gerhard Roethlin

 Permission is hereby granted, free of charge, to any person
 obtaining a copy of this software and associated documentation
 files (the "Software"), to deal in the Software without
 restriction, including without limitation the rights to use,
 copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the
 Software is furnished to do so, subject to the following
 conditions:

 The above copyright notice and this permission notice shall be
 included in all copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
 OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
 WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 OTHER DEALINGS IN THE SOFTWARE.
]]
