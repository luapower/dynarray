
setfenv(1, require'low')
local dynarray = require'dynarray'
setfenv(dynarray.fromterra, getfenv())
setfenv(dynarray.fromlua, getfenv())

local cmp = terra(a: &int, b: &int): int32
	return iif(@a < @b, -1, iif(@a > @b, 1, 0))
end

local terra test_dynarray()
	var arr: dynarray(int, nil, nil, nil, getfenv())
	var arr2 = dynarray(int)
	var arr3 = new([dynarray(int)])
	arr:set(15, 1234)
	print(arr.size, arr.len, @arr(15))
	arr:set(19, 4321)
	assert(@arr(19) == 4321)
	var x = -1
	for i,v in arr:view(5, 12) do
		@v = x
		x = x * 2
	end
	arr:sort(cmp)
	for i,v in arr do
		print(i, @v)
	end
	print('binsearch -5000: ', arr:binsearch(-5000, arr.lt))
	print('binsearch_macro -5000: ', arr:binsearch_macro(-5000))
	arr:free()
end
--for k in pairs(C) do print(k) end
test_dynarray()

--[[
local S = dynarray(int8)
local terra test_arrayofstrings()
	var arr = dynarray(S)
	arr:add(S'Hello')
	arr:add(S'World!')
	print(arr.len, @arr(0), @arr(1))
	arr:call'free'
	print(arr(0).size, arr(0).len)
	arr:free()
	print(arr.size, arr.len)
end
test_arrayofstrings()
]]

