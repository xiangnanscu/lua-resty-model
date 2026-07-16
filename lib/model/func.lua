--TODO: support filter, COALESCE(return first non-null value)
local Func = { __IS_FUNCTION__ = true }
Func.__index = Func
Func.__call = function(self, column)
  if type(column) == 'string' then
    return self:new { column = column }
  else
    if column.filter ~= nil then
      -- 与其静默丢弃 filter 生成语义错误的 SQL，不如显式拒绝
      error("Func filter is not implemented yet (FILTER (WHERE ...) is never generated); remove it")
    end
    return self:new { column = column[1] }
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
local StdDev = Func:class { name = "STDDEV_SAMP", suffix = "_stddev" }
local Variance = Func:class { name = "VAR_SAMP", suffix = "_variance" }

return {
  Func = Func,
  Count = Count,
  Sum = Sum,
  Avg = Avg,
  Max = Max,
  Min = Min,
  StdDev = StdDev,
  Variance = Variance,
}
