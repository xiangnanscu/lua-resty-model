--TODO: support filter, COALESCE(return first non-null value)
local Func = { __IS_FUNCTION__ = true }
Func.__index = Func
Func.__call = function(self, column)
  if type(column) == 'string' then
    return self:new { column = column }
  else
    return self:new { column = column[1], filter = column.filter }
  end
end
function Func:class(args)
  args.__index = args
  return setmetatable(args, self)
end

function Func:new(args)
  return setmetatable(args or {}, self)
end

local Count = Func:class { name = "COUNT", suffix = "_count" }
local Sum = Func:class { name = "SUM", suffix = "_sum" }
local Avg = Func:class { name = "AVG", suffix = "_avg" }
local Max = Func:class { name = "MAX", suffix = "_max" }
local Min = Func:class { name = "MIN", suffix = "_min" }

return {
  Func = Func,
  Count = Count,
  Sum = Sum,
  Avg = Avg,
  Max = Max,
  Min = Min
}
