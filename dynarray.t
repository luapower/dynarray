jit.off(true, true)
--[[

	Dynamic array type for Terra.
	Written by Cosmin Apreutesei. Public domain.

	local A = arr{T=, cmp=T.{methods|metamethods}.__cmp, size_t=int}
	var a = arr(T, ...) --preferred variant
	var a = arr(&buffer, len, cmp=...)
	var a: A = nil -- =nil is imortant!
	var a = A(nil) -- (nil) is important!
	a:free()
	a:clear()
	a:setcapacity(capacity) -> ok?
	a.capacity
	a.len

	a|view:range(i, j, truncate?) -> start, len
	a|view:view(i, j) -> view

	a|view:set(i, v) -> ok?
	a|view:at(i) -> &v|nil
	a|view(i[,default]) -> v
	for i,&v in a|view[:backwards()] do ... end

	a|view:resize(len) -> ok?
	a:push|add(v) -> i|-1
	a:push_junk|add_junk() -> &v|nil
	a:insert(i, v) -> ok?
	a:pop() -> v

	a:insert_junk(i, n) -> i|-1
	a:remove(i, [n])
	a:update(i, a|view|&v,len) -> ok?
	a:extend(a|view|&v,len) -> ok?
	a|view:copy([a|view|&v]) -> a|view|&v
	a:insert_array(i, a|view|&v,len) -> ok?
	a:move(i1, i2)

	a|view:sort([cmp: {&T, &T} -> int32])
	a|view:sort_desc()
	a|view:find(v) -> i
	a|view:count(v) -> n
	a|view:binsearch(v, cmp: {&T, &T} -> bool) -> i
	a|view:binsearch(v, a.lt|a.lte|a.gt|a.gte) -> i
	a|view:binsearch_macro(v, cmp(t, i, v) -> bool) -> i

	a|view:reverse()
	a|view:call(method, args...)

	a:index_at(&v) -> i|nil
	a:remove_at(&v) -> i|nil
	a:next(&v) -> &v|nil
	a:prev(&v) -> &v|nil

]]

if not ... then require'dynarray_test'; return end

setfenv(1, require'low')

local function arr_type(T, cmp, size_t)

	local view = arrview(T, cmp, size_t)

	local struct arr (gettersandsetters) {
		_capacity: size_t;
		view: view;
	}

	arr.view = view
	arr.empty = `arr{_capacity = 0; view = view(nil)}

	function arr.metamethods.__typename(self)
		return 'arr('..tostring(T)..')'
	end
	function arr.metamethods.__typename_ffi(self)
		return 'arr_'..tostring(T)
	end

	function arr.metamethods.__cast(from, to, exp)
		if T == int8 and from == rawstring then
			--initialize with a null-terminated string
			return quote
				var len = strnlen(exp, [size_t:max()]-1)+1
				var self = arr(nil)
				self:extend(exp, len)
				in self
			end
		elseif from == niltype then --makes [arr(T)](nil) work in a constant()
			return arr.empty
		else
			assert(false, 'invalid cast from ', from, ' to ', to, ': ', exp)
		end
	end

	function arr.metamethods.__tostring(self, format_arg, fmt, args, freelist, indent)
		add(fmt, '%s[%d]<%llx>')
		add(args, tostring(T))
		add(args, `self.len)
		add(args, `self.elements)
	end

	arr.methods.get_len      = macro(function(self) return `self.view.len end)
	arr.methods.get_capacity = macro(function(self) return `self._capacity end)
	arr.methods.get_elements = macro(function(self) return `self.view.elements end)

	arr.metamethods.__apply = view.metamethods.__apply
	arr.metamethods.__for = view.metamethods.__for

	addmethods(arr, function()

		--create a method that forwards the call to the array view.
		local function forwardmethod(name)
			return macro(function(self, ...)
				local args = {...}
				return `self.view:[name]([args])
			end)
		end

		terra arr:init()
			@self = [arr.empty]
		end

		terra arr:free()
			free(self.elements)
			@self = [arr.empty]
		end

		arr.methods.setcapacity = overload'setcapacity'
		arr.methods.setcapacity:adddefinition(terra(
			self: &arr, capacity: size_t, growth_factor: int
		): bool
			assert(capacity >= 0)
			if capacity == self.capacity then return true end
			if capacity == 0 then self:free(); return true end
			var len = self.len
			if capacity > self.capacity then --grow
				capacity = max(capacity, self.capacity * growth_factor)
			end
			var elements = [&T](alloc(T, capacity, self.elements))
			if elements == nil then return false end
			self.view.elements = elements
			self._capacity = capacity
			self.view.len = min(capacity, len)
			return true
		end)
		arr.methods.setcapacity:adddefinition(terra(
			self: &arr, capacity: size_t
		): bool
			return self:setcapacity(capacity, 2)
		end)

		terra arr:set_capacity(capacity: size_t)
			assert(self:setcapacity(capacity))
		end

		terra arr:set_min_capacity(capacity: size_t)
			assert(self:setcapacity(max(capacity, self.capacity)))
		end

		terra arr:setlen(len: size_t)
			assert(len >= 0)
			if self:setcapacity(max(len, self.capacity)) then
				self.view.len = len
				return true
			else
				return false
			end
		end

		--setting, pushing and popping elements

		terra arr:set_len(len: size_t)
			assert(len >= 0)
			self.min_capacity = len
			self.view.len = len
		end

		terra arr:set_min_len(len: size_t)
			self.len = max(len, self.len)
		end

		--unlike view:set(), arr:set() grows the array automatically, possibly
		--creating a hole of uninitialized elements.
		arr.methods.set = overload'set'
		arr.methods.set:adddefinition(terra(self: &arr, i: size_t, val: T)
			if i < 0 then i = self.len + i end; assert(i >= 0)
			self.min_len = i+1
			self.elements[i] = val
			return i
		end)
		arr.methods.set:adddefinition(terra(self: &arr, i: size_t)
			if i < 0 then i = self.len + i end; assert(i >= 0)
			self.min_len = i+1
			return self.elements+i
		end)

		arr.methods.push = overload'push'
		arr.methods.push:adddefinition(terra(self: &arr, val: T)
			return self:set(self.len, val)
		end)
		arr.methods.push:adddefinition(terra(self: &arr)
			return self:set(self.len)
		end)
		arr.methods.add = arr.methods.push --TODO: doesn't work with saveobj()

		terra arr:pop()
			self.len = self.len-1
			return self.len
		end

		--shifting segments to the left or to the right

		--returns the absolute i because if i was negative, it is now invalid.
		terra arr:insertn(i: size_t, n: size_t)
			if i < 0 then i = self.len + i end; assert(i >= 0)
			assert(n >= 0)
			var b = max(0, self.len-i) --how many elements must be moved
			self.min_capacity = i+n+b
			if b > 0 then
				copy(self.elements+i+n, self.elements+i, b)
			end
			return i
		end

		--returns the absolute i because if i was negative, it is now invalid.
		arr.methods.remove = overload'remove'
		arr.methods.remove:adddefinition(terra(self: &arr, i: size_t, n: size_t)
			if i < 0 then i = self.len + i end; assert(i >= 0)
			assert(n >= 0)
			var b = self.len-i-n --how many elements must be moved
			if b > 0 then
				copy(self.elements+i, self.elements+i+n, b)
			end
			self.view.len = self.len - min(n, self.len-i)
			return i
		end)
		arr.methods.remove:adddefinition(terra(self: &arr, i: size_t)
			return self:remove(i, 1)
		end)

		arr.methods.insert = overload'insert'
		arr.methods.insert:adddefinition(terra(self: &arr, i: size_t)
			return self.elements + self:insertn(i, 1)
		end)
		arr.methods.insert:adddefinition(terra(self: &arr, i: size_t, val: T)
			return self:set(self:insertn(i, 1), val)
		end)

		arr.methods.update = overload'update'
		arr.methods.update:adddefinition(terra(self: &arr, i: size_t, p: &T, len: size_t)
			if i < 0 then i = self.len + i end; assert(i >= 0)
			assert(len >= 0)
			self.min_len = i + len
			copy(self.elements+i, p, len)
			return i
		end)
		arr.methods.update:adddefinition(terra(self: &arr, i: size_t, v: &view)
			return self:update(i, v.elements, v.len)
		end)
		arr.methods.update:adddefinition(terra(self: &arr, i: size_t, a: &arr)
			return self:update(i, a.elements, a.len)
		end)

		arr.methods.insert:adddefinition(terra(self: &arr, i: size_t, p: &T, len: size_t)
			return self:update(self:insertn(i, len), p, len)
		end)

		arr.methods.extend = overload'extend'
		arr.methods.extend:adddefinition(terra(self: &arr, p: &T, len: size_t)
			return self:update(self.len, p, len)
		end)
		arr.methods.extend:adddefinition(terra(self: &arr, v: &view)
			return self:update(self.len, v)
		end)
		arr.methods.extend:adddefinition(terra(self: &arr, a: &arr)
			return self:update(self.len, a)
		end)

		arr.methods.copy = overload'copy'
		arr.methods.copy:adddefinition(terra(self: &arr)
			var a = arr(nil)
			a:update(0, self)
			return a
		end)
		arr.methods.copy:adddefinition(terra(self: &arr, dst: &T)
			copy(self.elements, dst, self.len)
			return dst
		end)

		--[=[

		terra arr:move(i1: size_t, i2: size_t)
			if i1 < 0 then i1 = self.len + i1 end; assert(i1 >= 0 and i1 < self.len)
			if i2 < 0 then i2 = self.len + i2 end; assert(i2 >= 0)
			i2 = min(i2, self.len-1)
			if i2 == i1 then return end
			var tmp = self(i1)
			self:remove(i1)
			assert(self:insert(i2, tmp))
		end

		terra arr:remove_at(e: &T)
			self:remove(self:index_at(e))
		end

		]=]

		--methods that can't be forwarded to the view directly,
		--or that need additional overloaded definitions.

		arr.methods.copy = overload'copy'
		arr.methods.copy:adddefinition(terra(self: &arr, dst: &arr)
			dst.len = self.len
			return self.view:copy(&dst.view)
		end)
		arr.methods.copy:adddefinition(terra(self: &arr, dst: &T)
			return self.view:copy(dst)
		end)
		arr.methods.copy:adddefinition(terra(self: &arr, dst: &view)
			return self.view:copy(dst)
		end)

		if view:getmethod'__cmp' then
			terra arr:__cmp(a: &arr)
				return self.view:__cmp(&a.view)
			end
			local vmm = view.metamethods
			arr.metamethods.__lt = terra(self: &arr, a: &arr) return vmm.__lt(&self.view, &a.view) end
			arr.metamethods.__gt = terra(self: &arr, a: &arr) return vmm.__gt(&self.view, &a.view) end
			arr.metamethods.__le = terra(self: &arr, a: &arr) return vmm.__le(&self.view, &a.view) end
			arr.metamethods.__ge = terra(self: &arr, a: &arr) return vmm.__ge(&self.view, &a.view) end
		end

		if view:getmethod'__eq' then
			terra arr:__eq(a: &arr)
				return self.view:__eq(&a.view)
			end
			arr.metamethods.__eq = arr.methods.__eq
			arr.metamethods.__ne = macro(function(self, other)
				return not (self == other)
			end)
		end

		--memsize for caches and debugging

		terra arr:__memsize(): size_t
			return sizeof(arr) + sizeof(T) * self.len
		end

		--forward all other methods to the view on-demand.
		after_getmethod(arr, function(arr, name)
			if view:getmethod(name) then
				return forwardmethod(name)
			end --fall through to own methods
		end)

	end) --addmethods()

	return arr
end
arr_type = memoize(arr_type)

local arr_type = function(T, cmp, size_t)
	if terralib.type(T) == 'table' then
		T, cmp, size_t = T.T, T.cmp, T.size_t
	end
	assert(T)
	cmp = cmp or (T:isaggregate() and (T.metamethods.__cmp or T:getmethod'__cmp'))
	size_t = size_t or int
	return arr_type(T, cmp, size_t)
end

arr = macro(
	--calling it from Terra returns a new array.
	function(arg1, ...)
		local T, lval, len, cmp, size_t
		if arg1 and arg1:islvalue() then --wrap raw pointer: arr(&v, len, ...)
			lval, len, cmp, size_t = arg1, ...
			T = lval:gettype()
			assert(T:ispointer())
			T = T.type
		else --create new array: arr(T, ...)
			T, cmp, size_t = arg1, ...
			T = T and T:astype()
		end
		size_t = size_t and size_t:astype()
		local arr = arr_type(T, cmp, size_t)
		if lval then
			return quote var a = arr(nil); a:extend(lval, len) in a end
		else
			return `arr(nil)
		end
	end,
	--calling it from Lua or from an escape or in a type declaration returns
	--just the type, and you can also pass a custom C namespace.
	arr_type
)
