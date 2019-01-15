
--Dynamic array type for Terra.
--Written by Cosmin Apreutesei. Public domain.

--stdlib deps: realloc, memset, memmove, memcmp, qsort, strnlen.
--macro deps: iif, min, max, maxint, check, binsearch, addproperties.

--[[ API

a = dynarray(T=int32, size_t=int32, grow_factor=2)
a: dynarray(T=int32, size_t=int32, grow_factor=2, C=require'low') = {}
a.len
a:free()
a:shrink()
a(i) -> &v
a:set(i, v) -> ok?
for i, &v in a do ... end
a:push(v) -> ok?
a:add(v) -> ok?
a:pop() -> v
a:insert_junk(i, n) -> ok?
a:remove(i, [n])
a:clear()
a:range(i, j, truncate?) -> start, len
a:view(i, j) -> view
a:update(i, a|view) -> ok?
a:extend(a|view) -> ok?
a:copy() -> a
a:insert(i, v) -> ok?
a:insert_array(i, a) -> ok?
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

	local struct P {
		size: size_t;
		len: size_t;
		first_element: T;
	}

	--opaque wrapper
	local arr = terralib.types.newstruct('dynarray('..tostring(T)..')')
	arr.entries = {{'p', &P}}

	local props = addproperties(arr)

	props.len = macro(function(self) return `self.p.len end)
	props.size = macro(function(self) return `self.p.size end)
	props.elements = macro(function(self) return `&self.p.first_element end)

	--storage

	function arr.metamethods.___cast(from, to, exp)
		if T == int8 and from:ispointer() and from.type == int8 then
			--initialize with a null-terminated string
			return quote
				var len = strnlen(exp, maxint(size_t)-1)+1
				var self: arr = {p = nil}
				self:realloc(len)
				if self.addr ~= nil then
					memmove(self.elements, exp, len)
					self.len = len
				end
				in self
			end
		elseif from == nil then
			return `[&arr](nil)
		else
			error'invalid cast'
		end
	end

	terra arr:realloc(size: size_t): bool
		assert(size >= 0)
		var len: size_t
		if self.p ~= nil then
			if size == self.size then return true end
			if size > self.size then --grow
				size = max(size, self.size * growth_factor)
			end
			len = self.len
		else
			len = 0
		end
		self.p = [&P](realloc(self.p, sizeof(P) + sizeof(T) * (size - 1)))
		if self.p == nil then return false end
		self.size = size
		self.len = min(size, len)
		return true
	end

	terra arr:free()
		free(self.p)
		self.p = nil
	end

	terra arr:shrink(): bool
		if self.size == self.len then return true end
		return self:realloc(self.len)
	end

	--random access with auto-growing

	arr.metamethods.__apply = terra(self: &arr, i: size_t): &T
		if i < 0 then i = self.len - i end
		assert(i >= 0 and i < self.len)
		return &self.elements[i]
	end

	terra arr:grow(i: size_t): bool
		assert(i >= 0)
		if self.p == nil or i >= self.size then --grow capacity
			if not self:realloc(i+1) then
				return false
			end
		end
		if i >= self.len then --enlarge
			if i >= self.len + 1 then --clear the gap
				memset(&self.elements[self.len], 0, sizeof(T) * (i - self.len))
			end
			self.len = i + 1
		end
		return true
	end

	terra arr:set(i: size_t, val: T): bool
		if i < 0 then i = self.len - i end
		if not self:grow(i) then return false end
		self.elements[i] = val
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

	--stack interface

	terra arr:push(val: T) return self:set(self.len, val) end
	terra arr:add (val: T) return self:set(self.len, val) end

	terra arr:pop()
		var v = self(-1)
		self.len = self.len - 1
		return v
	end

	--segment shifting

	terra arr:insert_junk(i: size_t, n: size_t)
		if i < 0 then i = self.len - i end
		assert(i >= 0 and n >= 0)
		var b = max(0, self.len-i) --how many bytes must be moved
		if not self:realloc(max(self.size, i+n+b)) then return false end
		if b <= 0 then return true end
		memmove(&self.elements[i+n], &self.elements[i], sizeof(T) * b)
		return true
	end

	arr.methods.remove = terralib.overloadedfunction('remove', {})

	arr.methods.remove:adddefinition(
		terra(self: &arr, i: size_t, n: size_t)
			if i < 0 then i = self.len - i end
			assert(i >= 0 and n >= 0)
			var b = self.len-i-n --how many elements must be moved
			if b > 0 then
				memmove(&self.elements[i], &self.elements[i+n], sizeof(T) * b)
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
		assert(i >= 0)
		j = max(i, j)
		if truncate then j = min(self.len, j) end
		return i, j-i
	end

	local struct view {
		array: &arr;
		start: size_t;
		len: size_t;
	}

	local viewprops = addproperties(view)

	terra arr:view(i: size_t, j: size_t)
		var start, len = self:range(i, j, true)
		return view {array = self, start = start, len = len}
	end

	viewprops.elements = macro(function(self)
		return `&self.array.elements[self.start]
	end)

	view.metamethods.__for = arr.metamethods.__for

	--array-to-view/array interface

	arr.methods.update = terralib.overloadedfunction('update', {})

	arr.methods.update:adddefinition(terra(self: &arr, i: size_t, v: view)
		if i < 0 then i = self.len - i end; assert(i >= 0)
		if v.len == 0 then return true end
		var newlen = max(self.len, i+v.len)
		if newlen > self.len then
			if not self:realloc(newlen) then return false end
			if i >= self.len + 1 then --clear the gap
				memset(&self.elements[self.len], 0, sizeof(T) * (i - self.len))
			end
			self.len = newlen
		end
		memmove(&self.elements[i], v.elements, sizeof(T) * v.len)
		return true
	end)
	arr.methods.update:adddefinition(terra(self: &arr, i: size_t, a: arr)
		return self:update(i, a:view(0, a.len))
	end)

	arr.methods.extend = terralib.overloadedfunction('extend', {})
	arr.methods.extend:adddefinition(terra(self: &arr, v: view)
		return self:update(self.len, v)
	end)
	arr.methods.extend:adddefinition(terra(self: &arr, a: arr)
		return self:update(self.len, a)
	end)

	terra arr:copy()
		var a = arr {p = nil}
		a:update(0, @self)
		return a
	end

	terra arr:insert(i: size_t, val: T)
		return self:insert_junk(i, 1) and self:set(i, val)
	end

	--NOTE: can't overload insert() because a could be T can be an &arr.
	arr.methods.insert_array = terralib.overloadedfunction('insert_array', {})
	terra arr:insert_array(i: size_t, a: arr)
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
			return memcmp(self.elements, a.elements, sizeof(T) * self.len)
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
			qsort(self.elements, self.len, sizeof(T),
				[{&opaque, &opaque} -> int32](cmp))
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

	local lt, gt, lte, gte
	if user_cmp_asc then
		lt  = terra(a: &T, b: &T) return cmp_asc(a, b) == -1 end
		gt  = terra(a: &T, b: &T) return cmp_asc(a, b) ==  1 end
		lte = terra(a: &T, b: &T) var r = cmp_asc(a, b) return r == -1 or r == 0 end
		gte = terra(a: &T, b: &T) var r = cmp_asc(a, b) return r ==  1 or r == 0 end
	elseif not T:isaggregate() then
		lt  = terra(a: &T, b: &T) return @a <  @b end
		gt  = terra(a: &T, b: &T) return @a >  @b end
		lte = terra(a: &T, b: &T) return @a <= @b end
		gte = terra(a: &T, b: &T) return @a >= @b end
	end
	props.lt  = macro(function() return lt  end)
	props.gt  = macro(function() return gt  end)
	props.lte = macro(function() return lte end)
	props.gte = macro(function() return gte end)

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
		end
	)

	local cmp_lt = macro(function(t, i, v) return `t[i] < v end)
	arr.methods.binsearch_macro = macro(function(self, v, cmp)
		cmp = cmp or cmp_lt
		return `binsearch(v, self.elements, 0, self.len-1, cmp)
	end)

	--reversing

	terra arr:reverse()
		var j = self.len-1
		for k = 0, (j+1)/2 do
			var tmp = self.elements[k]
			self.elements[k] = self.elements[j-k]
			self.elements[j-k] = tmp
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

	return arr
end

local dynarray_type = terralib.memoize(
	function(T, cmp_asc, size_t, growth_factor, C)
		T = T or int32
		size_t = size_t or int32
		growth_factor = growth_factor or 2
		C = C or require'low'
		return dynarray_type(T, cmp_asc, size_t, growth_factor, C)
	end)

local dynarray = macro(
	--calling it from Terra returns a new array.
	function(T, cmp_asc, size_t, growth_factor)
		T = T and T:astype()
		size_t = size_t and size_t:astype()
		local arr = dynarray_type(T, cmp_asc, size_t, growth_factor)
		return `[&arr](nil)
	end,
	--calling it from Lua or from an escape or in a type declaration returns
	--just the type, and you can also pass a custom C namespace.
	dynarray_type
)

return dynarray
