-- Django 风格 lookup 操作符 → SQL 片段的映射，以及 jsonb 路径查询的
-- 操作符分流表。从 sql.lua 拆出：本模块只做「(列, 值) → 条件文本」，
-- 不持有任何 builder 状态。
local Utils = require "model.utils"
local encode = require("cjson").encode

local type = type
local error = error
local tostring = tostring
local format = string.format
local as_literal = Utils.as_literal
local as_literal_without_brackets = Utils.as_literal_without_brackets
local escape_like_value = Utils.escape_like_value

---@type {[string]: fun(key:string, value:DBValue):string}
local EXPR_OPERATORS = {
  eq = function(key, value)
    return format("%s = %s", key, as_literal(value))
  end,
  iexact = function(key, value)
    return format("%s ILIKE %s", key, as_literal(value))
  end,
  lt = function(key, value)
    return format("%s < %s", key, as_literal(value))
  end,
  lte = function(key, value)
    return format("%s <= %s", key, as_literal(value))
  end,
  gt = function(key, value)
    return format("%s > %s", key, as_literal(value))
  end,
  gte = function(key, value)
    return format("%s >= %s", key, as_literal(value))
  end,
  ne = function(key, value)
    return format("%s <> %s", key, as_literal(value))
  end,
  ['in'] = function(key, value)
    if type(value) == 'table' and value[1] == nil and not value.__SQL_BUILDER__ then
      error(format("empty table passed to __in lookup for column: %s", key))
    end
    return format("%s IN %s", key, as_literal(value))
  end,
  notin = function(key, value)
    if type(value) == 'table' and value[1] == nil and not value.__SQL_BUILDER__ then
      error(format("empty table passed to __notin lookup for column: %s", key))
    end
    return format("%s NOT IN %s", key, as_literal(value))
  end,
  contains = function(key, value)
    local esc = escape_like_value(value)
    return format("%s LIKE '%%%s%%' ESCAPE '\\'", key, esc)
  end,
  icontains = function(key, value)
    local esc = escape_like_value(value)
    return format("%s ILIKE '%%%s%%' ESCAPE '\\'", key, esc)
  end,
  startswith = function(key, value)
    local esc = escape_like_value(value)
    return format("%s LIKE '%s%%' ESCAPE '\\'", key, esc)
  end,
  istartswith = function(key, value)
    local esc = escape_like_value(value)
    return format("%s ILIKE '%s%%' ESCAPE '\\'", key, esc)
  end,
  endswith = function(key, value)
    local esc = escape_like_value(value)
    return format("%s LIKE '%%%s' ESCAPE '\\'", key, esc)
  end,
  iendswith = function(key, value)
    local esc = escape_like_value(value)
    return format("%s ILIKE '%%%s' ESCAPE '\\'", key, esc)
  end,
  range = function(key, value)
    return format("%s BETWEEN %s AND %s", key, as_literal(value[1]), as_literal(value[2]))
  end,
  date = function(key, value)
    return format("%s::date = %s", key, as_literal(value))
  end,
  year = function(key, value)
    -- 半开区间 [y-01-01, y+1-01-01)：BETWEEN '..-12-31' 对 timestamp 列
    -- 会漏掉 12-31 当天 00:00 之后的数据（Django 同款处理）
    local y = assert(tonumber(value), "year lookup requires an integer year, got: " .. tostring(value))
    return format("(%s >= '%d-01-01' AND %s < '%d-01-01')", key, y, key, y + 1)
  end,
  month = function(key, value)
    return format("EXTRACT('month' FROM %s) = %s", key, as_literal(value))
  end,
  day = function(key, value)
    return format("EXTRACT('day' FROM %s) = %s", key, as_literal(value))
  end,
  hour = function(key, value)
    return format("EXTRACT('hour' FROM %s) = %s", key, as_literal(value))
  end,
  minute = function(key, value)
    return format("EXTRACT('minute' FROM %s) = %s", key, as_literal(value))
  end,
  second = function(key, value)
    return format("EXTRACT('second' FROM %s) = %s", key, as_literal(value))
  end,
  week = function(key, value)
    return format("EXTRACT('week' FROM %s) = %s", key, as_literal(value))
  end,
  week_day = function(key, value)
    return format("EXTRACT('dow' FROM %s) + 1 = %s", key, as_literal(value))
  end,
  iso_week_day = function(key, value)
    return format("EXTRACT('isodow' FROM %s) = %s", key, as_literal(value))
  end,
  iso_year = function(key, value)
    return format("EXTRACT('isoyear' FROM %s) = %s", key, as_literal(value))
  end,
  quarter = function(key, value)
    return format("EXTRACT('quarter' FROM %s) = %s", key, as_literal(value))
  end,
  time = function(key, value)
    return format("%s::time = %s", key, as_literal(value))
  end,
  regex = function(key, value)
    return format("%s ~ '%s'", key, (tostring(value):gsub("'", "''")))
  end,
  iregex = function(key, value)
    return format("%s ~* '%s'", key, (tostring(value):gsub("'", "''")))
  end,
  null = function(key, value)
    if value then
      return format("%s IS NULL", key)
    else
      return format("%s IS NOT NULL", key)
    end
  end,
  isnull = function(key, value)
    if value then
      return format("%s IS NULL", key)
    else
      return format("%s IS NOT NULL", key)
    end
  end,
  has_key = function(key, value)
    return format("(%s) ? %s", key, as_literal(value))
  end,
  has_keys = function(key, value)
    return format("(%s) ?& ARRAY[%s]", key, as_literal_without_brackets(value))
  end,
  has_any_keys = function(key, value)
    return format("(%s) ?| ARRAY[%s]", key, as_literal_without_brackets(value))
  end,
  json_contains = function(key, value)
    return format("(%s) @> '%s'", key, encode(value))
  end,
  json_eq = function(key, value)
    return format("(%s) = '%s'", key, encode(value))
  end,
  json_ne = function(key, value)
    return format("(%s) <> '%s'", key, encode(value))
  end,
  json_gt = function(key, value)
    return format("(%s) > '%s'", key, encode(value))
  end,
  json_gte = function(key, value)
    return format("(%s) >= '%s'", key, encode(value))
  end,
  json_lt = function(key, value)
    return format("(%s) < '%s'", key, encode(value))
  end,
  json_lte = function(key, value)
    return format("(%s) <= '%s'", key, encode(value))
  end,
  contained_by = function(key, value)
    return format("(%s) <@ '%s'", key, encode(value))
  end,
}

-- Rename normal comparison ops to their json_* variants when LHS is a jsonb path
-- so RHS gets JSON-encoded and PG performs jsonb-vs-jsonb comparison.
local JSON_OP_MAP = {
  eq = 'json_eq',
  ne = 'json_ne',
  gt = 'json_gt',
  gte = 'json_gte',
  lt = 'json_lt',
  lte = 'json_lte',
  contains = 'json_contains',
}

-- Ops that operate on TEXT (LIKE family, regex, date extraction). When the LHS
-- is a jsonb path, extract the last segment as text (->> / #>>) instead of
-- jsonb (-> / #>), so PG operators that require text work directly without
-- explicit cast.
local JSON_TEXT_OPS = {
  iexact = true,
  icontains = true,
  startswith = true, istartswith = true,
  endswith = true, iendswith = true,
  regex = true, iregex = true,
  date = true, time = true,
  year = true, month = true, day = true,
  hour = true, minute = true, second = true,
  week = true, week_day = true,
  iso_week_day = true, iso_year = true,
  quarter = true,
}

return {
  EXPR_OPERATORS = EXPR_OPERATORS,
  JSON_OP_MAP = JSON_OP_MAP,
  JSON_TEXT_OPS = JSON_TEXT_OPS,
}
