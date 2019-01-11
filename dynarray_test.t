
local dynarray = require'dynarray'
setfenv(1, require'low'.C)

local C = cached(C)

local terra test_dynarray()
	var arr = dynarray(int)
	var arr2: dynarray(int) = {}
	var arr3 = new([dynarray(int)])
	arr:set(15, 1234)
	pr(arr.size, arr.len, arr:get(15))
	arr:set(19, 4321)
	check(arr:get(19) == 4321)
	for i,v in arr do
		v = -i
		pr(i, v)
	end
	arr:free()
end
for i,v in ipairs(C.__deps) do print(v) end
test_dynarray()
