if not _G.lunatest then require 'lunatest' end
  -- to install lunatest, try "sudo luarocks intall lunatest"

if not _G.persistence then require 'persistence' end
  -- @todo we might change the name/way it is loaded

local _tmpfile

function setup_tmpfile()
	if not _tmpfile then -- create only one tmpfile each time u run tests (why? why not?)
		_tmpfile = os.tmpname()
	end
	return _tmpfile
end

-- this is an ad-hoc equality asserter for arbitrary deeply nested structures
--   composed of tables, number, strings, and nil.  depends on lunatest
--
function assert_equal_recursive(thing1, thing2, path)
	if not path then path = '' end
	local type1, type2 = type(thing1), type(thing2)
	if type1 ~= type2 then
		assert_equal(type1, type2, "elements not equal at path: "..path)
		return false
	end
	if 'number' == type1 or 'string' == type1 or 'nil' == type1 then
		assert_equal(thing1, thing2, "must be equal at path: "..path)
		return (thing1 == thing2)
	end
	local alltrue = true
	if 'table' == type1 then
		for i = 1, math.max(#thing1, #thing2) do
			if not assert_equal_recursive(thing1[i], thing2[i], path .. '/' .. i) then alltrue = false end
		end
		local allkeys = {}
		for _,t in pairs({thing1, thing2}) do
		  for k,_ in pairs(t) do
				if not ('number' == type(k) and 0 == (k % 1.0)) then
					allkeys[k] = true
				end
			end
		end
		for k,_ in pairs(allkeys) do
			if not assert_equal_recursive(thing1[k], thing2[k], path .. '/' .. k) then alltrue = false end
		end
	end
	return alltrue
end

function test_pure_arrays_must_maintain_order()
	local tmpfile = setup_tmpfile()
	local t_original = {'one','two','three','four', { 'five', 'six', 'seven'}, 'eight'}
	persistence.store(tmpfile, t_original)
	local t_restored = persistence.load(tmpfile)
	assert_equal_recursive(t_original, t_restored)
end

function test_mixed_tables_must_maintain_order()
	local tmpfile = setup_tmpfile()
	local in_data = {
		'positional 1',
		'positional 2',
		key1 = { key2 = 'value 2' },
		key3 = { 'positional 3' }
	}
	persistence.store(tmpfile, in_data)
	local out_data = persistence.load(tmpfile)
	assert_equal_recursive(in_data, out_data)
end

function test_from_blog()
	local tmpfile = setup_tmpfile()
	-- lifted directly from http://lua-users.org/wiki/TablePersistence ATTOTW
	local orig = {1, 2, ["a"] = "string", b = "test", {"subtable", [4] = 2}}
	persistence.store(tmpfile, orig)
	local restored = persistence.load(tmpfile)
	assert_equal_recursive(orig, restored)
end

function test_types()
	local test = {
		nothing = nil,
		int = 1,
		number = 123.456,
		bool = true,
		string = "test",
		table = {},
	}

	local tmpfile = setup_tmpfile()
	-- lifted directly from http://lua-users.org/wiki/TablePersistence ATTOTW
	persistence.store(tmpfile, test)
	local restored = persistence.load(tmpfile)
	assert_equal_recursive(test, restored)
end

function test_single_line_array()
	function is_single_line_array(file_content)
		return file_content:match("{[^\n]+}") and true or false
	end

	local test_case = {
		{1, 2, 3, 4, 5},
		{"test", "is", "passed", "yeah!"},
	}

	local fail_case = {
		{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12},
		{"test", "is", "passed", "but this string is to long to keep in a single line"},
	}

	for _, value in ipairs(test_case) do
		local tmpfile = setup_tmpfile()
		persistence.store(tmpfile, value)

		local f = io.open(tmpfile)
		local content = f:read("*a")
		assert(is_single_line_array(content))
		f:close()
	end
	
	for _, value in ipairs(fail_case) do
		local tmpfile = setup_tmpfile()
		persistence.store(tmpfile, value)

		local f = io.open(tmpfile)
		local content = f:read("*a")
		assert(not is_single_line_array(content))
		f:close()
	end
end

function test_key_seq()
	local test = {
		1,
		2,
		one = 1,
		two = 2,
		three = 3,
	}
	local key_seq = {"one", "two", "three"}
	setmetatable(test, {__key_seq = key_seq})

	local tmpfile = setup_tmpfile()
	persistence.store(tmpfile, test)

	local f = io.open(tmpfile)
	local content = f:read("*a")

	local pos_map = {}
	local seq = {}
	for _, key in ipairs(key_seq) do
		local pos = content:find(key)
		table.insert(seq, key)
		pos_map[key] = pos
	end

	table.sort(seq, function(a, b)
		return pos_map[a] < pos_map[b]
	end)

	assert_equal_recursive(key_seq, seq)

	f:close()
end

function test_format()
	local tmpfile = setup_tmpfile()
	local orig = {1, 2, ["a"] = "string", b = "test", {"subtable", [4] = 2}}
	persistence.store(tmpfile, orig)

	local f = io.open(tmpfile)
	print(f:read("*a"))
	f:close()
end

lunatest.run()
