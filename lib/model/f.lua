-- https://docs.djangoproject.com/en/dev/ref/models/expressions/#django.db.models.F
---@class FClass
---@field column string
---@field operator string
---@field left FClass
---@field right FClass
local F = setmetatable({ __IS_FIELD_BUILDER__ = true }, {
  __call = function(self, column)
    return setmetatable({ column = column }, self)
  end
})
F.__index = F
function F:new(args)
  return setmetatable(args or {}, F)
end

F.__tostring = function(self)
  if self.column then
    return self.column
  else
    return string.format("(%s %s %s)", self.left, self.operator, self.right)
  end
end
F.__add = function(self, other)
  return setmetatable({ left = self, right = other, operator = "+" }, F)
end
F.__sub = function(self, other)
  return setmetatable({ left = self, right = other, operator = "-" }, F)
end
F.__mul = function(self, other)
  return setmetatable({ left = self, right = other, operator = "*" }, F)
end
F.__div = function(self, other)
  return setmetatable({ left = self, right = other, operator = "/" }, F)
end
F.__mod = function(self, other)
  return setmetatable({ left = self, right = other, operator = "%" }, F)
end
F.__pow = function(self, other)
  return setmetatable({ left = self, right = other, operator = "^" }, F)
end
F.__concat = function(self, other)
  return setmetatable({ left = self, right = other, operator = "||" }, F)
end

return F
