
setfenv(1, require'low')

local terra test_autogrow()
	var a = arr()
	for i = 0,10000 do
		a:set(i, i)
	end
	assert(a.len == 10000)
	assert(a.size == 16384)
end
test_autogrow()

local terra test_stack()
	var a = arr()
	for i = 0, 10000 do
		assert(a:push(i) == i)
	end
	for i, v in a:backwards() do
		assert(a:pop() == i)
	end
	assert(a.len == 0)
	assert(a.size > 0)
	a:shrink()
	assert(a.size == 0)
end
test_stack()

--local terra test_

local cmp = terra(a: &int, b: &int): int32
	return iif(@a < @b, -1, iif(@a > @b, 1, 0))
end

local terra test_dynarray()
	var a: arr{item_type = int, C = getfenv()} = nil
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

local terra test_hashmap()
	var s1 = S'Hello'
	var s2 = S'World!'
	var h = map(S, int)
	h:put(s1, 5)
	h:put(s2, 7)
	h:put(s2, 8)
	h:put(s1, 3)
	print(@h:at(s2), @h:at(s1), h.count)
	s1:free()
	s2:free()
	h:free()
end


test_dynarray()
test_arrayofstrings()
test_wrap()
test_hashmap()
