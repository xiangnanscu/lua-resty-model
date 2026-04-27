-- https://docs.djangoproject.com/en/dev/ref/models/querysets/#django.db.models.Q
---@class QClass
---@field cond table
---@field logic string
---@field left? QClass
---@field right? QClass
local Q = setmetatable({ __IS_LOGICAL_BUILDER__ = true }, {
  __call = function(self, cond_table)
    return setmetatable({ cond = cond_table, logic = "AND" }, self)
  end
})
Q.__index = Q
Q.__mul = function(self, other)
  return setmetatable({ left = self, right = other, logic = "AND" }, Q)
end
Q.__div = function(self, other)
  return setmetatable({ left = self, right = other, logic = "OR" }, Q)
end
Q.__unm = function(self)
  return setmetatable({ left = self, logic = "NOT" }, Q)
end

return Q
