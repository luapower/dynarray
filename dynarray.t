
--Dynamic array type for Terra.
--Written by Cosmin Apreutesei. Public domain.

--stdlib deps: realloc, memset, memmove, memcmp, qsort, strnlen.
--macro deps: iif, min, max, assert, noop, binsearch, addproperties.

--[[  API

	local A = arr{T=, cmp=T.__cmp|default, size_t=int32, grow_factor=2,
		C=require'low'}
	var a = arr(T, ...) --preferred variant
	var a = arr(&buffer, len, cmp=...)
	var a: A = nil -- =nil is imortant!
	var a = A(nil) -- (nil) is important!
	a:free()
	a:clear()
	a:shrink() -> ok?
	a:preallocate(size) -> ok?
	a:resize(size) -> ok?
	a.size
	a.len

	a|view:range(i, j, truncate?) -> start, len
	a|view:view(i, j) -> view

	a:ensure(i) -> ok?
	a|view:set(i, v) -> ok?
	a|view:at(i) -> &v|nil
	a|view[:get](i[,default]) -> v
	for i,&v in a|view[:backwards()] do ... end
	a:push|add(v) -> i|-1
	a:push_junk() -> &v|nil
	a:insert(i, v) -> ok?
	a:pop() -> v

	a:insert_junk(i, n) -> ok?
	a:remove(i, [n])
	a:update(i, a|view|&v,len) -> ok?
	a:extend(a|view|&v,len) -> ok?
	a|view:copy([a|view|&v]) -> a|view|&v
	a:insert_array(i, a|view|&v,len) -> ok?

	a|view:sort([cmp: {&T, &T} -> int32])
	a|view:sort_desc()
	a|view:find(v) -> i
	a|view:count(v) -> n
	a|view:binsearch(v, cmp: {&T, &T} -> bool) -> i
	a|view:binsearch(v, a.lt|a.lte|a.gt|a.gte) -> i
	a|view:binsearch_macro(v, cmp(t, i, v) -> bool) -> i

	a|view:reverse()
	a|view:call(method, args...)

]]

if not ... then require'dynarray_test'; return end

local overload = terralib.overloadedfunction

local function arr_type(T, cmp, size_t, growth_factor, C)

	setfenv(1, C)

	local struct P {
		size: size_t; --capacity (as number of elements)
		len: size_t;  --number of valid elements
	}

	local empty = constant(`P{size=0, len=0}) --static park space when empty

	local struct arr { p: &P } --opaque wrapper

	function arr.metamethods.__typename(self)
		return 'arr('..tostring(T)..')'
	end

	function arr.metamethods.__tostring(self, format_arg, fmt, args, freelist)
		add(fmt, '%s[%d]')
		add(args, tostring(T))
		add(args, `self.len)
	end

	local props = addproperties(arr)

	props.len = macro(function(self) return `self.p.len end)
	props.size = macro(function(self) return `self.p.size end)
	props.elements = macro(function(self) return `[&T](self.p+1) end)

	--storage

	function arr.metamethods.__cast(from, to, exp)
		if T == int8 and from == rawstring then
			--initialize with a null-terminated string
			return quote
				var len = strnlen(exp, [size_t:max()]-1)+1
				var self = arr(nil)
				if self:resize(len) then
					memmove(self.elements, exp, len)
					self.len = len
				end
				in self
			end
		elseif from == niltype or from:isunit() then
			return `arr {p = &empty}
		else
			error'invalid cast'
		end
	end

	terra arr:resize(size: size_t): bool
		assert(size >= 0)
		if size == self.size then return true end
		if size == 0 then self:free(); return true end
		var len = self.len
		if size > self.size then --grow
			size = max(size, self.size * growth_factor)
		end
		var p0 = iif(self.p ~= &empty, self.p, nil)
		var p1 = [&P](realloc(p0, sizeof(P) + sizeof(T) * size))
		if p1 == nil then return false end
		self.p = p1
		self.size = size
		self.len = min(size, len)
		return true
	end

	terra arr:preallocate(size: size_t): bool
		return iif(size > self.size, self:resize(size), true)
	end

	terra arr:free()
		if self.p == &empty then return end
		free(self.p)
		self.p = &empty
	end

	terra arr:shrink(): bool
		if self.size == self.len then return true end
		return self:resize(self.len)
	end

	terra arr:__memsize(): size_t
		return sizeof(arr) + sizeof(P) + sizeof(T) * self.size
	end

	--random access with auto-growing

	terra arr:at(i: size_t): &T
		if i < 0 then i = self.len + i end
		return iif(i >= 0 and i < self.len, &self.elements[i], nil)
	end

	arr.methods.get = overload('get', {})
	arr.methods.get:adddefinition(terra(self: &arr, i: size_t): T
		if i < 0 then i = self.len + i end
		assert(i >= 0 and i < self.len)
		return self.elements[i]
	end)
	arr.methods.get:adddefinition(terra(self: &arr, i: size_t, default: T): T
		if i < 0 then i = self.len + i end
		return iif(i >= 0 and i < self.len, self.elements[i], default)
	end)
	arr.metamethods.__apply = arr.methods.get

	terra arr:ensure(i: size_t): &T
		assert(i >= 0)
		if i >= self.size then --grow size
			if not self:resize(i+1) then
				return nil
			end
		end
		if i >= self.len then --enlarge
			if i >= self.len + 1 then --clear the gap
				memset(&self.elements[self.len], 0, sizeof(T) * (i - self.len))
			end
			self.len = i + 1
		end
		return &self.elements[i]
	end

	terra arr:set(i: size_t, val: T): bool
		if i < 0 then i = self.len + i end
		var p = self:ensure(i)
		if p == nil then return false end
		@p = val
		return true
	end

	--ordered access

	arr.metamethods.__for = function(self, body)
		return quote
			for i = 0, self.len do
				[ body(`i, `&self.elements[i]) ]
			end
		end
	end

	local struct reverse_iter { array: arr; }
	reverse_iter.metamethods.__for = function(self, body)
		return quote
			for i = self.array.len-1, -1, -1 do
				[ body(`i, `&self.array.elements[i]) ]
			end
		end
	end
	terra arr:backwards()
		return reverse_iter {@self}
	end

	--stack interface

	arr.methods.push = overload('push', {})
	arr.methods.push:adddefinition(terra(self: &arr, val: T)
		var i = self.len
		return iif(self:set(i, val), i, -1)
	end)
	arr.methods.push:adddefinition(terra(self: &arr): &T
		return self:ensure(self.len)
	end)
	arr.methods.add = arr.methods.push

	terra arr:push_junk()
		var newlen = self.len + 1
		if self.size < newlen then
			if not self:resize(newlen) then return nil end
		end
		self.len = newlen
		return &self.elements[newlen-1]
	end

	terra arr:pop()
		var v = self(-1)
		self.len = self.len - 1
		return v
	end

	--segment shifting

	terra arr:insert_junk(i: size_t, n: size_t)
		if i < 0 then i = self.len + i end
		assert(i >= 0 and n >= 0)
		var b = max(0, self.len-i) --how many bytes must be moved
		if not self:resize(max(self.size, i+n+b)) then return false end
		if b <= 0 then return true end
		memmove(&self.elements[i+n], &self.elements[i], sizeof(T) * b)
		return true
	end

	arr.methods.remove = overload('remove', {})

	arr.methods.remove:adddefinition(terra(self: &arr, i: size_t, n: size_t)
		if i < 0 then i = self.len + i end
		assert(i >= 0 and n >= 0)
		var b = self.len-i-n --how many elements must be moved
		if b > 0 then
			memmove(&self.elements[i], &self.elements[i+n], sizeof(T) * b)
		end
		self.len = self.len - min(n, self.len-i)
	end)

	arr.methods.remove:adddefinition(terra(self: &arr, i: size_t)
		self:remove(i, 1)
	end)

	terra arr:clear()
		self.len = 0
	end

	--view interface

	local struct view {
		array: &arr;
		start: size_t;
		len: size_t;
	}

	local viewprops = addproperties(view)

	--NOTE: j is not the last position, but one position after that!
	terra view:range(i: size_t, j: size_t, truncate: bool)
		if i < 0 then i = self.len + i end
		if j < 0 then j = self.len + j end
		assert(i >= 0)
		j = max(i, j)
		if truncate then j = min(self.len, j) end
		return i, j-i
	end

	terra view:view(i: size_t, j: size_t)
		var start, len = self:range(i, j, true)
		return view {array = self.array, start = self.start + start, len = len}
	end

	terra arr:range(i: size_t, j: size_t, truncate: bool)
		return view {array = nil, start = 0, len = self.len}:range(i, j, truncate)
	end

	terra arr:view(i: size_t, j: size_t)
		var start, len = self:range(i, j, true)
		return view {array = self, start = start, len = len}
	end

	viewprops.elements = macro(function(self)
		return `&self.array.elements[self.start]
	end)

	terra view:at(i: size_t): &T
		return self.array:at(self.start + i)
	end

	terra view:get(i: size_t): T
		return self.array:get(self.start + i)
	end
	view.metamethods.__apply = view.methods.get

	terra view:set(i: size_t, val: T): bool
		if i < 0 then i = self.len + i end
		assert(i >= 0 and i < self.len)
		return self.array:set(self.start + i, val)
	end

	view.metamethods.__for = function(self, body)
		return quote
			for i = 0, self.len do
				[ body(`i, `&self.elements[i]) ]
			end
		end
	end

	local struct reverse_iter { view: view; }
	reverse_iter.metamethods.__for = function(self, body)
		return quote
			for i = self.view.len-1, -1, -1 do
				[ body(`i, `&self.view.elements[i]) ]
			end
		end
	end
	terra view:backwards()
		return reverse_iter {@self}
	end

	view.methods.copy = overload('copy', {})
	view.methods.copy:adddefinition(terra(self: &view, dst: &T)
		memmove(dst, self.elements, self.len)
		return dst
	end)
	view.methods.copy:adddefinition(terra(self: &view, dst: view)
		memmove(dst.elements, self.elements, min(dst.len, self.len))
		return dst
	end)
	view.methods.copy:adddefinition(terra(self: &view, dst: arr)
		memmove(dst.elements, self.elements, min(dst.len, self.len))
		return dst
	end)

	--array-to-view/array interface

	arr.methods.update = overload('update', {})
	arr.methods.update:adddefinition(terra(self: &arr, i: size_t, p: &T, len: size_t)
		if i < 0 then i = self.len + i end; assert(i >= 0)
		if len == 0 then return true end
		var newlen = max(self.len, i+len)
		if newlen > self.len then
			if not self:resize(newlen) then return false end
			if i >= self.len + 1 then --clear the gap
				memset(&self.elements[self.len], 0, sizeof(T) * (i - self.len))
			end
			self.len = newlen
		end
		memmove(&self.elements[i], p, sizeof(T) * len)
		return true
	end)
	arr.methods.update:adddefinition(terra(self: &arr, i: size_t, v: view)
		return self:update(i, v.elements, v.len)
	end)
	arr.methods.update:adddefinition(terra(self: &arr, i: size_t, a: arr)
		return self:update(i, a:view(0, a.len))
	end)

	arr.methods.extend = overload('extend', {})
	arr.methods.extend:adddefinition(terra(self: &arr, p: &T, len: size_t)
		return self:update(self.len, p, len)
	end)
	arr.methods.extend:adddefinition(terra(self: &arr, v: view)
		return self:update(self.len, v)
	end)
	arr.methods.extend:adddefinition(terra(self: &arr, a: arr)
		return self:update(self.len, a)
	end)

	arr.methods.copy = overload('copy', {})
	arr.methods.copy:adddefinition(terra(self: &arr)
		var a = arr(nil)
		a:update(0, @self)
		return a
	end)
	arr.methods.copy:adddefinition(terra(self: &arr, dst: &T)
		memmove(self.elements, dst, self.len)
		return dst
	end)

	terra arr:insert(i: size_t, val: T)
		return self:insert_junk(i, 1) and self:set(i, val)
	end

	--NOTE: can't overload insert() because T can be an arr.
	arr.methods.insert_array = overload('insert_array', {})
	arr.methods.insert_array:adddefinition(terra(self: &arr, i: size_t, p: &T, len: size_t)
		return self:insert_junk(i, len) and self:update(i, p, len)
	end)
	arr.methods.insert_array:adddefinition(terra(self: &arr, i: size_t, a: arr)
		return self:insert_junk(i, a.len) and self:update(i, a)
	end)
	arr.methods.insert_array:adddefinition(terra(self: &arr, i: size_t, v: view)
		return self:insert_junk(i, v.len) and self:update(i, v)
	end)

	--comparing values and arrays

	local equal

	--1. using custom comparison function
	cmp = cmp or T:isaggregate() and T.methods.__cmp

	--2. elements are comparable
	local custom_op = not cmp and T:isaggregate()
		and T.metamethods.__eq and T.metamethods.__lt

	if not cmp and (custom_op or not T:isaggregate()) then

		cmp = terra(a: &T, b: &T): int32 --for sorting this view
			return iif(@a == @b, 0, iif(@a < @b, -1, 1))
		end

		equal = macro(function(a, b) return `@a == @b end)

		if not custom_op then --can be mem-compared directly
			terra view:__cmp(v: &view) --for sorting views like this
				if v.len ~= self.len then
					return iif(self.len < v.len, -1, 1)
				end
				return memcmp(self.elements, v.elements, sizeof(T) * self.len)
			end
		end
	end

	if cmp and not view.methods.__cmp then
		--slower comparison based on cmp.
		terra view:__cmp(v: &view)
			if v.len ~= self.len then
				return iif(self.len < v.len, -1, 1)
			end
			for i,val in self do
				var r = cmp(val, v:at(i))
				if r ~= 0 then
					return r
				end
			end
			return 0
		end
	end

	if not equal and cmp then
		equal = macro(function(a, b) return `cmp(a, b) == 0 end)
	end

	if cmp then
		terra view:__equal(v: &view)
			return self:__cmp(v) == 0
		end
		terra arr:__cmp(a: &arr)
			var v = a:view(0, a.len)
			return self:view(0, self.len):__cmp(&v)
		end
		terra arr:__equal(a: &arr)
			var v = a:view(0, a.len)
			return self:view(0, self.len):__equal(&v)
		end
	end

	if C.hash then
		terra view:__hash32(): uint32 return C.hash(uint32, self, sizeof(T)) end
		terra view:__hash64(): uint64 return C.hash(uint64, self, sizeof(T)) end
		terra arr:__hash32(): uint32 return self:view(0, self.len):__hash32() end
		terra arr:__hash64(): uint32 return self:view(0, self.len):__hash64() end
	end

	--sorting

	view.methods.sort = overload('sort', {})
	arr .methods.sort = overload('sort', {})
	view.methods.sort:adddefinition(terra(self: &view, cmp: {&T, &T} -> int32)
		qsort(self.elements, self.len, sizeof(T),
			[{&opaque, &opaque} -> int32](cmp))
		return self
	end)
	arr.methods.sort:adddefinition(terra(self: &arr, cmp: {&T, &T} -> int32)
		return self:view(0, self.len):sort(cmp)
	end)

	if cmp then
		view.methods.sort:adddefinition(terra(self: &view) return self:sort(cmp) end)
		arr .methods.sort:adddefinition(terra(self: &arr ) return self:sort(cmp) end)

		local terra cmp_desc(a: &T, b: &T): int32
			return -cmp(a, b)
		end
		terra view:sort_desc() return self:sort(cmp_desc) end
		terra arr :sort_desc() return self:sort(cmp_desc) end
	end

	--searching

	if equal then
		terra view:find(val: T)
			for i,v in self do
				if equal(v, &val) then
					return i
				end
			end
			return -1
		end
		terra arr:find(val: T)
			return self:view(0, self.len):find(val)
		end

		terra view:count(val: T)
			var n: size_t = 0
			for i,v in self do
				if equal(v, &val) then
					n = n + 1
				end
			end
			return n
		end
		terra arr:count(val: T)
			return self:view(0, self.len):count(val)
		end
	end

	--binary search for an insert position that keeps the array sorted.

	local lt, gt, lte, gte
	if user_cmp then
		lt  = terra(a: &T, b: &T) return cmp(a, b) == -1 end
		gt  = terra(a: &T, b: &T) return cmp(a, b) ==  1 end
		lte = terra(a: &T, b: &T) var r = cmp(a, b) return r == -1 or r == 0 end
		gte = terra(a: &T, b: &T) var r = cmp(a, b) return r ==  1 or r == 0 end
	elseif not T:isaggregate() then
		lt  = terra(a: &T, b: &T) return @a <  @b end
		gt  = terra(a: &T, b: &T) return @a >  @b end
		lte = terra(a: &T, b: &T) return @a <= @b end
		gte = terra(a: &T, b: &T) return @a >= @b end
	end
	if lt then
		props.lt  = macro(function() return lt  end)
		props.gt  = macro(function() return gt  end)
		props.lte = macro(function() return lte end)
		props.gte = macro(function() return gte end)
	end

	view.methods.binsearch = overload('binsearch', {})
	arr .methods.binsearch = overload('binsearch', {})
	view.methods.binsearch:adddefinition(
	terra(self: &view, v: T, cmp: {&T, &T} -> bool): size_t
		var lo = [size_t](0)
		var hi = self.len-1
		var i = hi + 1
		while true do
			if lo < hi then
				var mid: int = lo + (hi - lo) / 2
				if cmp(&self.elements[mid], &v) then
					lo = mid + 1
				else
					hi = mid
				end
			elseif lo == hi and not cmp(&self.elements[lo], &v) then
				return lo
			else
				return i
			end
		end
	end)
	arr.methods.binsearch:adddefinition(
	terra(self: &arr, v: T, cmp: {&T, &T} -> bool): size_t
		return self:view(0, self.len):binsearch(v, cmp)
	end)
	if lt then
		view.methods.binsearch:adddefinition(terra(self: &view, v: T): size_t
			return self:binsearch(v, lt)
		end)
		arr.methods.binsearch:adddefinition(terra(self: &arr, v: T): size_t
			return self:view(0, self.len):binsearch(v, lt)
		end)
	end

	local cmp_lt = macro(function(t, i, v) return `t[i] < v end)
	view.methods.binsearch_macro = macro(function(self, v, cmp)
		cmp = cmp or cmp_lt
		return `binsearch(v, self.elements, 0, self.len-1, cmp)
	end)
	arr.methods.binsearch_macro = view.methods.binsearch_macro

	--reversing

	terra view:reverse()
		var j = self.len-1
		for k = 0, (j+1)/2 do
			var tmp = self.elements[k]
			self.elements[k] = self.elements[j-k]
			self.elements[j-k] = tmp
		end
		return self
	end
	terra arr:reverse()
		return self:view(0, self.len):reverse()
	end

	--calling methods on the elements

	view.methods.call = macro(function(self, method_name, ...)
		local method = T.methods[method_name:asvalue()]
		local args = {...}
		return quote
			for i,v in self do
				method(v, [args])
			end
		end
	end)
	arr.methods.call = view.methods.call

	return arr
end
arr_type = terralib.memoize(arr_type)

local arr_type = function(T, cmp, size_t, growth_factor, C)
	if terralib.type(T) == 'table' then
		T, cmp, size_t, growth_factor, C =
			T.T, T.cmp, T.size_t, T.growth_factor, T.C
	end
	assert(T)
	cmp = cmp or (T:isstruct() and T.methods.__cmp)
	size_t = size_t or int32
	growth_factor = growth_factor or 2
	C = C or require'low'
	return arr_type(T, cmp, size_t, growth_factor, C)
end

local arr = macro(
	--calling it from Terra returns a new array.
	function(arg1, ...)
		local T, lval, len, cmp, size_t, growth_factor
		if arg1 and arg1:islvalue() then --wrap raw pointer: arr(&v, len, ...)
			lval, len, cmp, size_t, growth_factor = arg1, ...
			T = lval:gettype()
			assert(T:ispointer())
			T = T.type
		else --create new array: arr(T, ...)
			T, cmp, size_t, growth_factor = arg1, ...
			T = T and T:astype()
		end
		size_t = size_t and size_t:astype()
		growth_factor = growth_factor and growth_factor:asvalue()
		local arr = arr_type(T, cmp, size_t, growth_factor)
		if lval then
			return quote
				var a = arr(nil)
				a:update(0, lval, len)
				in a
			end
		else
			return `arr(nil)
		end
	end,
	--calling it from Lua or from an escape or in a type declaration returns
	--just the type, and you can also pass a custom C namespace.
	arr_type
)

return arr
