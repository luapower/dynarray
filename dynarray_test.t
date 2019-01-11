
local dynarray = require'dynarray'
setfenv(1, require'low'.C)
--setfenv(dynarray, getfenv())

local C = cached(C)

local cmp = terra(a: &int, b: &int): int32
	return iif(@a < @b, -1, iif(@a > @b, 1, 0))
end

local terra test_dynarray()
	var arr: dynarray(int, nil, nil, C) = {}
	var arr2 = dynarray(int)
	var arr3 = new([dynarray(int)])
	arr:set(15, 1234)
	pr(arr.size, arr.len, arr:get(15))
	arr:set(19, 4321)
	check(arr:get(19) == 4321)
	var x = -1
	for i,v in arr do
		arr:set(i, x)
		x = x * 2
	end
	arr:sort(cmp)
	for i,v in arr do
		pr(i, v)
	end
	arr:free()
end
for i,v in ipairs(C.__deps) do print(v) end
--for k in pairs(C) do print(k) end
test_dynarray()
