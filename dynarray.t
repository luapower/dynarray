
--Dynamic arrays for Terra.
--Written by Cosmin Apreutesei. Public domain.

--stdlib deps: realloc, memset, memmove, qsort.
--macro deps: iif, min, max, check, binsearch, addproperties.

if not ... then require'dynarray_test'; return end

local function dynarray_type(T, size_t, growth_factor, C)

	setfenv(1, C)

	local arr = struct {
		data: &T;
		size: size_t;
		len: size_t;
	}

	local props = addproperties(arr)

	--storage

	function arr.metamethods.__cast(from, to, exp)
		if from == (`{}):gettype() then --initalize with empty tuple
			return `arr {nil, 0, 0}
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

	--random access

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
				[ body(`i, `self.data[i]) ]
			end
		end
	end

	--stack interface

	terra arr:push(val: T)
		return self:set(self.len, val)
	end

	terra arr:pop()
		var v = self:get(-1)
		self.len = self.len - 1
		return v
	end

	--segment shifting

	arr.methods.insert = terralib.overloadedfunction('insert', {})

	arr.methods.insert:adddefinition(
		terra(self: &arr, i: size_t, n: size_t)
			if i < 0 then i = self.len - i end
			check(i >= 0 and n >= 0)
			var b = max(0, self.len-i) --how many bytes must be moved
			if not self:realloc(max(self.size, i+n+b)) then return false end
			if b <= 0 then return true end
			memmove(self.data+i+n, self.data+i, b)
			return true
		end
	)

	terra arr:remove(i: size_t, n: size_t)
		if i < 0 then i = self.len - i end
		check(i >= 0 and n >= 0)
		if n >= self.len-i-1 then return end
		memmove(self.data+i, self.data+i+n, self.len-i-n)
		self.len = self.len - n
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
		return arr {self.data+i, -i, len}
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
		memmove(self.data+i, a.data, a.len)
		return true
	end

	terra arr:copy()
		var a: arr = {}
		a:update(0, self)
		return a
	end

	terra arr:append(a: &arr)
		return self:update(self.len, a)
	end

	arr.methods.insert:adddefinition(
		terra(self: &arr, i: size_t, a: &arr)
			return self:insert(i, a.len) and self:update(i, a)
		end
	)

	--sorting

	local cmp_normal = terra(a: &int, b: &int): int32
		return iif(@a < @b, -1, iif(@a > @b, 1, 0))
	end
	local cmp_reverse = terra(a: &int, b: &int): int32
		return iif(@a < @b, -1, iif(@a > @b, 1, 0))
	end

	arr.methods.sort = terralib.overloadedfunction('sort', {})

	arr.methods.sort:adddefinition(
		terra(self: &arr, cmp: {&T, &T} -> int32)
			qsort(self.data, self.len, sizeof(T), [{&opaque, &opaque} -> int32](cmp))
			return self
		end
	)

	arr.methods.sort:adddefinition(
		terra(self: &arr)
			return self:sort(cmp_normal)
		end
	)

	terra arr:sort_reverse()
		return self:sort(cmp_reverse)
	end

	--searching

	terra arr:find(val: T)
		for i,v in self do
			if v == val then
				return i
			end
		end
		return -1
	end

	props.lt  = terra(a: &T, b: &T) return @a <  @b end
	props.lte = terra(a: &T, b: &T) return @a <= @b end
	props.gt  = terra(a: &T, b: &T) return @a >  @b end
	props.gte = terra(a: &T, b: &T) return @a >= @b end

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

	return arr
end

local dynarray_type = terralib.memoize(
	function(T, size_t, growth_factor, C)
		T = T or int32
		size_t = size_t or int32
		growth_factor = growth_factor or 2
		C = C or require'low'.C
		return dynarray_type(T, size_t, growth_factor, C)
	end)

local dynarray = macro(
	--calling it from Terra returns a new array.
	function(T, size_t, growth_factor)
		T = T and T:astype()
		size_t = size_t and size_t:astype()
		local arr = dynarray_type(T, size_t, growth_factor)
		return quote var a: arr = {} in a end
	end,
	--calling it from Lua or from an escape or in a type declaration returns
	--just the type, and you can also pass a custom C namespace.
	function(T, size_t, growth_factor, C)
		return dynarray_type(T, size_t, growth_factor, C)
	end
)

return dynarray
