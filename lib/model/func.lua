--TODO: COALESCE(return first non-null value)
---聚合函数构造器。表形式支持修饰参数：
---  Count { 'id', distinct = true }            -> COUNT(DISTINCT T.id)
---  Count { 'id', filter = Q { rating__gt=3 } } -> COUNT(T.id) FILTER (WHERE ...)
---  Sum { 'price', filter = { pages__gt=100 } } -> filter 也接受 kwargs 条件表
local Func = { __IS_FUNCTION__ = true }
Func.__index = Func
Func.__call = function(self, column)
  if type(column) == 'string' then
    return self:new { column = column }
  else
    return self:new { column = column[1], filter = column.filter, distinct = column.distinct }
  end
end
function Func:class(args)
  args.__index = args
  return setmetatable(args, self)
end

---@class Func
---@field name string SQL 聚合函数名
---@field suffix string 数字索引 annotate 的自动命名后缀
---@field column string
---@field distinct? boolean COUNT(DISTINCT col)
---@field filter? table Q 对象或 kwargs 条件表 → FILTER (WHERE ...)
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
