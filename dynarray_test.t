
local dynarray = require'dynarray'
setfenv(1, require'low'.C)
setfenv(dynarray.fromterra, getfenv())
setfenv(dynarray.fromlua, getfenv())

local C = cached(C)

local cmp = terra(a: &int, b: &int): int32
	return iif(@a < @b, -1, iif(@a > @b, 1, 0))
end

local terra test_dynarray()
	var arr: dynarray(int, nil, nil, nil, C) = {}
	var arr2 = dynarray(int)
	var arr3 = new([dynarray(int)])
	arr:set(15, 1234)
	pr(arr.size, arr.len, arr:get(15))
	arr:set(19, 4321)
	check(@arr:get(19) == 4321)
	var x = -1
	for i,_ in arr do
		arr:set(i, x)
		x = x * 2
	end
	arr:sort(cmp)
	for i,v in arr do
		pr(i, @v)
	end
	pr('binsearch -5000: ', arr:binsearch(-5000, arr.lt))
	pr('binsearch_macro -5000: ', arr:binsearch_macro(-5000))
	arr:free()
end
for i,v in ipairs(C.__deps) do print(v) end
--for k in pairs(C) do print(k) end
test_dynarray()


local S = dynarray(int8)
local terra test_arrayofstrings()
	var arr = dynarray(S)
	arr:add(S'Hello')
	arr:add(S'World!')
	pr(arr.len, @arr(0), @arr(1))
	arr:call'free'
	pr(arr(0).size, arr(0).len)
	arr:free()
	pr(arr.size, arr.len)
end
test_arrayofstrings()
