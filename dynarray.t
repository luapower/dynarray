
--Dynamic array type for Terra.
--Written by Cosmin Apreutesei. Public domain.

--stdlib deps: realloc, memset, memmove, memcmp, qsort, strnlen.
--macro deps: iif, min, max, maxint, check, binsearch, addproperties.

--[[ API

a = dynarray(T=int32, size_t=int32, grow_factor=2)
a: dynarray(T=int32, size_t=int32, grow_factor=2, C=require'low'.C) = {}
a.len
a:isview() -> ?
a:free()
a:shrink()
a(i) -> &v
a:get(i) -> T
a:set(i, v) -> ok?
for i,v in a do ... end
a:push(v) -> ok?
a:add(v) -> ok?
a:pop() -> v
a:insert_junk(i, n) -> ok?
a:remove(i, [n])
a:clear()
a:range(i, j, truncate?) -> start, len
a:view(i, j) -> a
a:update(i, &a) -> ok?
a:extend(&a) -> ok?
a:copy() -> a
a:insert(i, v) -> ok?
a:insert_array(i, &a) -> ok?
a:sort([cmp: {&T, &T} -> int32])
a:sort_desc()
a:find(v) -> i
a:count(v) -> n
a:binsearch(v, cmp: {&T, &T} -> bool) -> i
a:binsearch(v, a.lt|a.lte|a.gt|a.gte) -> i
a:binsearch_macro(v, cmp(t, i, v) -> bool) -> i
a:compare(b) -> -1|0|1
a:equals(b) -> ?
a:reverse()
]]

if not ... then require'dynarray_test'; return end

local function dynarray_type(T, cmp_asc, size_t, growth_factor, C)

	setfenv(1, C)

	local arr = terralib.types.newstruct('dynarray('..tostring(T)..')')
	arr.entries = {
		{'data', &T};
		{'size', size_t};
		{'len', size_t};
	}

	local props = addproperties(arr)

	--storage

	function arr.metamethods.__cast(from, to, exp)
		if from:isunit() then --initalize with the empty tuple
			return `arr {data = nil, size = 0, len = 0}
		elseif T == int8 and from:ispointer() and from.type == int8 then
			--initialize with a null-terminated string
			return quote
				var arr: arr = {}
				var len = strnlen(exp, maxint(size_t)-1)+1
				if arr:realloc(len) then
					memmove(arr.data, exp, len)
					arr.len = len
				end
				in arr
			end
		end
	end

	arr.methods.isview = macro(function(self) return `self.size < 0 end)

	terra arr:realloc(size: size_t): bool
		check(size >= 0)
		if self:isview() then
			return size <= self.len
		end
		if size == self.size then return true end
		if size > self.size then --grow
			size = max(size, self.size * growth_factor)
		end
		var new_data = [&T](realloc(self.data, sizeof(T) * size))
		if size > 0 and new_data == nil then return false end
		self.data = new_data
		self.size = size
		self.len = min(size, self.len)
		return true
	end

	terra arr:free()
		self:realloc(0)
	end

	terra arr:shrink()
		if self.size == self.len then return true end
		return self:realloc(self.len)
	end

	--random access with auto-growing

	arr.metamethods.__apply = terra(self: &arr, i: size_t): &T
		if i < 0 then i = self.len - i end
		check(i >= 0 and i < self.len)
		return &self.data[i]
	end

	terra arr:get(i: size_t): T
		if i < 0 then i = self.len - i end
		check(i >= 0 and i < self.len)
		return self.data[i]
	end

	terra arr:grow(i: size_t): bool
		check(i >= 0)
		if i >= self.size then --grow capacity
			if not self:realloc(i+1) then
				return false
			end
		end
		if i >= self.len then --enlarge
			if i >= self.len + 1 then --clear the gap
				memset(self.data + self.len, 0, sizeof(T) * (i - self.len))
			end
			self.len = i + 1
		end
		return true
	end

	terra arr:set(i: size_t, val: T): bool
		if i < 0 then i = self.len - i end
		if self:isview() then check(i < self.len) end
		if not self:grow(i) then return false end
		self.data[i] = val
		return true
	end

	--ordered access

	arr.metamethods.__for = function(self, body)
		return quote
			for i = 0, self.len do
				[ body(`i, `&self.data[i]) ]
			end
		end
	end

	--stack interface

	terra arr:push(val: T) return self:set(self.len, val) end
	terra arr:add (val: T) return self:set(self.len, val) end

	terra arr:pop()
		var v = self:get(-1)
		self.len = self.len - 1
		return v
	end

	--segment shifting

	terra arr:insert_junk(i: size_t, n: size_t)
		if i < 0 then i = self.len - i end
		check(i >= 0 and n >= 0)
		var b = max(0, self.len-i) --how many bytes must be moved
		if not self:realloc(max(self.size, i+n+b)) then return false end
		if b <= 0 then return true end
		memmove(self.data+i+n, self.data+i, sizeof(T) * b)
		return true
	end

	arr.methods.remove = terralib.overloadedfunction('remove', {})

	arr.methods.remove:adddefinition(
		terra(self: &arr, i: size_t, n: size_t)
			if i < 0 then i = self.len - i end
			check(i >= 0 and n >= 0)
			var b = self.len-i-n --how many elements must be moved
			if b > 0 then
				memmove(self.data+i, self.data+i+n, sizeof(T) * b)
			end
			self.len = self.len - min(n, self.len-i)
		end
	)

	arr.methods.remove:adddefinition(
		terra(self: &arr, i: size_t)
			self:remove(i, 1)
		end
	)

	terra arr:clear()
		self.len = 0
	end

	--view interface

	--NOTE: j is not the last position, but one position after that!
	terra arr:range(i: size_t, j: size_t, truncate: bool)
		if i < 0 then i = self.len - i end
		if j < 0 then j = self.len - j end
		check(i >= 0)
		j = max(i, j)
		if truncate then j = min(self.len, j) end
		return i, j-i
	end

	terra arr:view(i: size_t, j: size_t) --NOTE: aliasing!
		var start, len = self:range(i, j, true)
		return arr {data = self.data+i, size = -i, len = len}
	end

	--array-to-array interface

	terra arr:update(i: size_t, a: &arr)
		if i < 0 then i = self.len - i end; check(i >= 0)
		if a.len == 0 then return true end
		var newlen = max(self.len, i+a.len)
		if newlen > self.len then
			if not self:realloc(newlen) then return false end
			if i >= self.len + 1 then --clear the gap
				memset(self.data + self.len, 0, sizeof(T) * (i - self.len))
			end
			self.len = newlen
		end
		memmove(self.data+i, a.data, sizeof(T) * a.len)
		return true
	end

	terra arr:extend(a: &arr)
		return self:update(self.len, a)
	end

	terra arr:copy()
		var a: arr = {}
		a:update(0, self)
		return a
	end

	terra arr:insert(i: size_t, val: T)
		return self:insert_junk(i, 1) and self:set(i, val)
	end

	--NOTE: can't overload insert() because a could be T can be an &arr.
	terra arr:insert_array(i: size_t, a: &arr)
		return self:insert_junk(i, a.len) and self:update(i, a)
	end

	--comparing values and arrays

	local user_cmp_asc = cmp_asc
	if not user_cmp_asc then
		if not T:isaggregate() then
			cmp_asc = terra(a: &T, b: &T): int32
				return iif(@a < @b, -1, iif(@a > @b, 1, 0))
			end
		elseif T.methods.compare then
			local cmp_asc = terra(a: &T, b: &T)
				return a:compare(b)
			end
		end
		terra arr:compare(a: &arr) --NOTE: assuming normalized representation!
			if a.len ~= self.len then
				return iif(self.len < a.len, -1, 1)
			end
			return memcmp(self.data, a.data, sizeof(T) * self.len)
		end
	else
		terra arr:compare(a: &arr)
			if a.len ~= self.len then
				return iif(self.len < a.len, -1, 1)
			end
			for i,v in self do
				var r = cmp_asc(&v, a(i))
				if r ~= 0 then
					return r
				end
			end
			return 0
		end
	end
	local cmp_desc = cmp_asc and terra(a: &T, b: &T): int32
		return -cmp_asc(a, b)
	end

	terra arr:equals(a: &arr)
		return self:compare(a) == 0
	end

	--sorting

	arr.methods.sort = terralib.overloadedfunction('sort', {})

	arr.methods.sort:adddefinition(
		terra(self: &arr, cmp: {&T, &T} -> int32)
			qsort(self.data, self.len, sizeof(T), [{&opaque, &opaque} -> int32](cmp))
			return self
		end
	)

	if cmp_asc then
		arr.methods.sort:adddefinition(
			terra(self: &arr)
				return self:sort(cmp_asc)
			end
		)
		terra arr:sort_desc()
			return self:sort(cmp_desc)
		end
	end

	--searching

	local equal =
		user_cmp_asc
			and macro(function(a, b) return `cmp_asc(&a, &b) == 0 end)
		or not T:isaggregate()
			and macro(function(a, b) return `a == b end)

	if equal then
		terra arr:find(val: T)
			for i,v in self do
				if equal(@v, val) then
					return i
				end
			end
			return -1
		end

		terra arr:count(val: T)
			var n: size_t = 0
			for i,v in self do
				if equal(@v, val) then
					n = n + 1
				end
			end
			return n
		end
	end

	if user_cmp_asc then
		props.lt  = terra(a: &T, b: &T) return cmp_asc(a, b) == -1 end
		props.gt  = terra(a: &T, b: &T) return cmp_asc(a, b) ==  1 end
		props.lte = terra(a: &T, b: &T) var r = cmp_asc(a, b) return r == -1 or r == 0 end
		props.gte = terra(a: &T, b: &T) var r = cmp_asc(a, b) return r ==  1 or r == 0 end
	elseif not T:isaggregate() then
		props.lt  = terra(a: &T, b: &T) return @a <  @b end
		props.gt  = terra(a: &T, b: &T) return @a >  @b end
		props.lte = terra(a: &T, b: &T) return @a <= @b end
		props.gte = terra(a: &T, b: &T) return @a >= @b end
	end

	arr.methods.binsearch = terralib.overloadedfunction('binsearch', {})

	--binary search for an insert position that keeps the array sorted.
	arr.methods.binsearch:adddefinition(
		terra(self: &arr, v: T, cmp: {&T, &T} -> bool): size_t
			var lo = [size_t](0)
			var hi = self.len-1
			var i = hi + 1
			while true do
				if lo < hi then
					var mid: int = lo + (hi - lo) / 2
					if cmp(&self.data[mid], &v) then
						lo = mid + 1
					else
						hi = mid
					end
				elseif lo == hi and not cmp(&self.data[lo], &v) then
					return lo
				else
					return i
				end
			end
		end
	)

	local cmp_lt = macro(function(t, i, v) return `t[i] < v end)
	arr.methods.binsearch_macro = macro(function(self, v, cmp)
		cmp = cmp or cmp_lt
		return `binsearch(v, self.data, 0, self.len-1, cmp)
	end)

	--reversing

	terra arr:reverse()
		var j = self.len-1
		for k = 0, (j+1)/2 do
			var tmp = self.data[k]
			self.data[k] = self.data[j-k]
			self.data[j-k] = tmp
		end
		return self
	end

	--calling methods on the children

	arr.methods.call = macro(function(self, method_name, ...)
		local method = T.methods[method_name:asvalue()]
		local args = {...}
		return quote
			for i,v in self do
				method(v, [args])
			end
		end
	end)

	--string interface

	if T == uint8 then

		--TODO

	end

	return arr
end

local dynarray_type = terralib.memoize(
	function(T, cmp_asc, size_t, growth_factor, C)
		T = T or int32
		size_t = size_t or int32
		growth_factor = growth_factor or 2
		C = C or require'low'.C
		return dynarray_type(T, cmp_asc, size_t, growth_factor, C)
	end)

local dynarray = macro(
	--calling it from Terra returns a new array.
	function(T, cmp_asc, size_t, growth_factor)
		T = T and T:astype()
		size_t = size_t and size_t:astype()
		local arr = dynarray_type(T, cmp_asc, size_t, growth_factor)
		return quote var a: arr = {} in a end
	end,
	--calling it from Lua or from an escape or in a type declaration returns
	--just the type, and you can also pass a custom C namespace.
	dynarray_type
)

return dynarray
