
setfenv(1, require'low')

local cmp = terra(a: &int, b: &int): int32
	return iif(@a < @b, -1, iif(@a > @b, 1, 0))
end

local terra test_dynarray()
	var a: arr(int, nil, nil, nil, getfenv()) = nil
	var a2 = arr(int)
	var a3 = new([arr(int)])
	a:set(15, 1234)
	print(a.size, a.len, a(15))
	a:set(19, 4321)
	assert(a(19) == 4321)
	var x = -1
	for i,v in a:view(5, 12) do
		@v = x
		x = x * 2
	end
	a:sort(cmp)
	for i,v in a do
		print(i, @v)
	end
	print('binsearch -5000: ', a:binsearch(-5000, a.lt))
	print('binsearch_macro -5000: ', a:binsearch_macro(-5000))
	a:free()
end

local S = arr(int8)
local terra test_arrayofstrings()
	var a = arr(S)
	a:add(S'Hello')
	a:add(S'World!')
	print(a.len, a(0), a(1))
	a:call'free'
	assert(a(0).size == 0)
	assert(a(0).len == 0)
	a:free()
	assert(a.size == 0)
	assert(a.len == 0)
end

local terra test_wrap()
	var len = 10
	var buf = new(int8, len)
	buf[5] = 123
	var a = arr(buf, len)
	assert(a(5) == 123)
	var s = tostring('hello')
	print(s.len, s.elements)
	s:free()
	a:free()
end

test_dynarray()
test_arrayofstrings()
test_wrap()
