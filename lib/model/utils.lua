local Array = require "resty.array"
local ipairs = ipairs
local tostring = tostring
local type = type
local pairs = pairs
local error = error
local insert = table.insert
local format = string.format
local concat = table.concat

-- =========================================================================
-- Table & Core Utilities
-- =========================================================================

local clone, isempty, NULL, table_new, table_clear
if ngx then
  clone = require "table.clone"
  isempty = require "table.isempty"
  NULL = ngx.null
  table_new = table.new
  table_clear = require("table.clear")
else
  clone = function(t)
    local t2 = {}
    for k, v in pairs(t) do
      t2[k] = v
    end
    return t2
  end

  isempty = function(t)
    for k, v in pairs(t) do
      return false
    end
    return true
  end

  ---@param m? number
  ---@param n? number
  ---@return table
  table_new = function(m, n)
    return {}
  end
  table_clear = function(tab)
    for k, _ in pairs(tab) do
      tab[k] = nil
    end
  end
  NULL = newproxy(false)
end

---@param a table
---@param b? table
---@return Array
local function list(a, b)
  local t = clone(a)
  if b then
    for _, v in ipairs(b) do
      t[#t + 1] = v
    end
  end
  return Array(t)
end

---@param t1 table
---@param t2? table
---@return table
local function dict(t1, t2)
  local res = clone(t1 or {})
  if t2 then
    for key, value in pairs(t2) do
      res[key] = value
    end
  end
  return res
end

local function map(tbl, func)
  local res = {}
  for i = 1, #tbl do
    res[i] = func(tbl[i])
  end
  return res
end

---collect column names from a row or an array of rows, appending (deduped)
---to the optional seed `columns`
---@param rows Records
---@param columns? string[]
---@return string[]
local function get_keys(rows, columns)
  columns = columns or {}
  local seen = {}
  for _, col in ipairs(columns) do
    seen[col] = true
  end
  local function collect(row)
    for k, _ in pairs(row) do
      if not seen[k] then
        seen[k] = true
        columns[#columns + 1] = k
      end
    end
  end
  if rows[1] then
    for _, row in ipairs(rows) do
      collect(row)
    end
  else
    collect(rows)
  end
  return columns
end

local function is_empty_value(value)
  return value == nil or value == "" or value == NULL
end

-- =========================================================================
-- String Utilities
-- =========================================================================

---UTF-8 字符数（按非续字节计数）
---@param s string
---@return integer
local function utf8len(s)
  local _, cnt = s:gsub("[^\128-\193]", "")
  return cnt
end

local function capitalize(s)
  if s == "" then return s end
  return s:sub(1, 1):upper() .. s:sub(2):lower()
end

local function to_camel_case(str)
  local parts = {}
  for part in str:gmatch("([^_]+)") do
    if part ~= "" then
      table.insert(parts, part)
    end
  end

  local result = ""
  for _, part in ipairs(parts) do
    result = result .. capitalize(part)
  end

  return result
end

---@param s string
---@param pattern string plain-text separator (any length)
---@return string[]
local function split_string(s, pattern)
  -- 空 pattern 会让 find 返回 (i, i-1)，start 永不前进 → 死循环
  assert(pattern ~= nil and pattern ~= "", "split_string: pattern can't be nil or empty")
  local parts = {}
  local start = 1

  while true do
    local pos, pend = s:find(pattern, start, true)
    if not pos then
      insert(parts, s:sub(start))
      break
    end
    insert(parts, s:sub(start, pos - 1))
    start = pend + 1
  end

  return parts
end

-- =========================================================================
-- Constants (PostgreSQL/SQL)
-- =========================================================================

local PG_OPERATORS = {
  -- 比较运算符
  ["="] = true,
  ["<>"] = true,
  ["!="] = true,
  [">"] = true,
  ["<"] = true,
  [">="] = true,
  ["<="] = true,

  -- 逻辑运算符
  ["AND"] = true,
  ["OR"] = true,
  ["NOT"] = true,

  -- 模式匹配
  ["LIKE"] = true,
  ["ILIKE"] = true, -- 不区分大小写的 LIKE
  ["~"] = true,     -- 正则表达式匹配
  ["~*"] = true,    -- 不区分大小写的正则表达式匹配
  ["!~"] = true,    -- 正则表达式不匹配
  ["!~*"] = true,   -- 不区分大小写的正则表达式不匹配

  -- 范围运算符
  ["BETWEEN"] = true,
  ["NOT BETWEEN"] = true,
  ["IN"] = true,
  ["NOT IN"] = true,

  -- NULL 相关
  ["IS"] = true,
  ["IS NOT"] = true,

  -- 数学运算符
  ["+"] = true,
  ["-"] = true,
  ["*"] = true,
  ["/"] = true,
  ["%"] = true,
  ["^"] = true,

  -- 位运算符
  ["&"] = true,
  ["|"] = true,
  ["#"] = true,


  -- JSON 运算符
  ["->"] = true,
  ["->>"] = true,
  ["#>"] = true,
  ["#>>"] = true,
  ["?"] = true,  -- 键存在
  ["?|"] = true, -- 任一键存在
  ["?&"] = true, -- 所有键存在

  -- 数组运算符
  ["||"] = true, -- 连接

  -- 范围类型运算符
  ["@>"] = true,  -- 包含
  ["<@"] = true,  -- 被包含
  ["&&"] = true,  -- 重叠
  ["<<"] = true,  -- 严格左边
  [">>"] = true,  -- 严格右边
  ["&<"] = true,  -- 不延伸到右边
  ["&>"] = true,  -- 不延伸到左边
  ["-|-"] = true, -- 相邻
}

local IS_PG_KEYWORDS = {
  ALL = true,
  ANALYSE = true,
  ANALYZE = true,
  AND = true,
  ANY = true,
  ARRAY = true,
  AS = true,
  ASC = true,
  ASYMMETRIC = true,
  AUTHORIZATION = true,
  BINARY = true,
  BOTH = true,
  CASE = true,
  CAST = true,
  CHECK = true,
  COLLATE = true,
  COLLATION = true,
  COLUMN = true,
  CONCURRENTLY = true,
  CONSTRAINT = true,
  CREATE = true,
  CROSS = true,
  CURRENT_CATALOG = true,
  CURRENT_DATE = true,
  CURRENT_ROLE = true,
  CURRENT_SCHEMA = true,
  CURRENT_TIME = true,
  CURRENT_TIMESTAMP = true,
  CURRENT_USER = true,
  DEFAULT = true,
  DEFERRABLE = true,
  DESC = true,
  DISTINCT = true,
  DO = true,
  ELSE = true,
  END = true,
  EXCEPT = true,
  FALSE = true,
  FETCH = true,
  FOR = true,
  FOREIGN = true,
  FREEZE = true,
  FROM = true,
  FULL = true,
  GRANT = true,
  GROUP = true,
  HAVING = true,
  ILIKE = true,
  IN = true,
  INITIALLY = true,
  INNER = true,
  INTERSECT = true,
  INTO = true,
  IS = true,
  ISNULL = true,
  JOIN = true,
  LATERAL = true,
  LEADING = true,
  LEFT = true,
  LIKE = true,
  LIMIT = true,
  LOCALTIME = true,
  LOCALTIMESTAMP = true,
  NATURAL = true,
  NOT = true,
  NOTNULL = true,
  NULL = true,
  OFFSET = true,
  ON = true,
  ONLY = true,
  OR = true,
  ORDER = true,
  OUTER = true,
  OVERLAPS = true,
  PLACING = true,
  PRIMARY = true,
  REFERENCES = true,
  RETURNING = true,
  RIGHT = true,
  SELECT = true,
  SESSION_USER = true,
  SIMILAR = true,
  SOME = true,
  SYMMETRIC = true,
  TABLE = true,
  TABLESAMPLE = true,
  THEN = true,
  TO = true,
  TRAILING = true,
  TRUE = true,
  UNION = true,
  UNIQUE = true,
  USER = true,
  USING = true,
  VARIADIC = true,
  VERBOSE = true,
  WHEN = true,
  WHERE = true,
  WINDOW = true,
  WITH = true,
}

local PG_SET_MAP = {
  _union = 'UNION',
  _union_all = 'UNION ALL',
  _except = 'EXCEPT',
  _except_all = 'EXCEPT ALL',
  _intersect = 'INTERSECT',
  _intersect_all = 'INTERSECT ALL'
}

-- https://docs.djangoproject.com/en/5.1/topics/db/queries/#containment-and-key-lookups
local json_operators = {
  eq = true,
  has_key = true,
  has_keys = true,
  contains = true,
  contained_by = true,
  has_any_keys = true,
}

local NON_OPERATOR_CONTEXTS = {
  select = true,
  returning = true,
  aggregate = true,
  group_by = true,
  order_by = true,
  distinct = true,
}

-- =========================================================================
-- SQL Construction & ORM Helpers
-- =========================================================================

local function smart_quote(s)
  if IS_PG_KEYWORDS[s:upper()] then
    -- 防御性转义内部双引号（标识符正常不含引号，但引用时必须完整）
    return '"' .. (s:gsub('"', '""')) .. '"'
  else
    return s
  end
end

---@param s string
---@return fun():string
local function make_token(s)
  local function raw_token()
    return s
  end

  return raw_token
end

local function DEFAULT()
  return "DEFAULT"
end

local function get_foreign_object(attrs, prefix)
  -- when in : attrs = {id=1, buyer__name='tom', buyer__id=2}, prefix = 'buyer__'
  -- when out: attrs = {id=1}, fk_instance = {name='tom', id=2}
  local fk = {}
  local n = #prefix
  for k, v in pairs(attrs) do
    if k:sub(1, n) == prefix then
      fk[k:sub(n + 1)] = v
      attrs[k] = nil
    end
  end
  return fk
end

---@param sql_part string
---@return string?
local function extract_column_name(sql_part)
  -- 1. T.col, user.name
  local _, col = sql_part:match("^([%w_]+)%.([%w_]+)$")
  if col then
    return col
  end

  -- 2.  T.col AS alias, col AS alias
  local alias = sql_part:match("[Aa][Ss]%s+([%w_]+)%s*$")
  if alias then
    return alias
  end

  -- 3. ignore function call
  if sql_part:match("%b()") then
    return nil
  end

  return sql_part:match("^([%w_]+)$")
end

---@param sql_text string
---@return string[]
local function extract_column_names(sql_text)
  local columns = {}
  local parts = split_string(sql_text, ", ")
  for _, part in ipairs(parts) do
    local col = extract_column_name(part)
    if col then
      insert(columns, col)
    else
      -- 静默跳过会让推断列数 < 实际列数，最终在 DB 层报
      -- "INSERT has more expressions than target columns"，难定位；
      -- 在此提前报错并给出解法
      error(format(
        "can't infer a column name from select fragment '%s' (in %q); pass explicit columns instead",
        part, sql_text))
    end
  end
  return columns
end

---构造值转 SQL 文本的函数
---@param quote_string boolean 字符串是否加引号并转义（literal），否则原样当 token
---@param add_brackets boolean 数组值是否包一层括号
---@return fun(value: DBValue): string
local function _escape_factory(quote_string, add_brackets)
  local function escape(value)
    local value_type = type(value)
    if "string" == value_type then
      if quote_string then
        return "'" .. (value:gsub("'", "''")) .. "'"
      else
        return value
      end
    elseif "number" == value_type then
      return tostring(value)
    elseif "boolean" == value_type then
      return value and "TRUE" or "FALSE"
    elseif "function" == value_type then
      return value()
    elseif "table" == value_type then
      if value.__SQL_BUILDER__ then
        return "(" .. value:statement() .. ")"
      elseif value[1] ~= nil then
        local result = {}
        for i, v in ipairs(value) do
          result[i] = escape(v)
        end
        local token = concat(result, ", ")
        if add_brackets then
          return "(" .. token .. ")"
        else
          return token
        end
      else
        error("empty table is not allowed")
      end
    elseif NULL == value then
      return 'NULL'
    else
      error(format("don't know how to escape value: %s (%s)", value, value_type))
    end
  end

  return escape
end

local as_literal = _escape_factory(true, true)
local as_token = _escape_factory(false, false)
local as_literal_without_brackets = _escape_factory(true, false)

local function escape_like_value(val)
  val = tostring(val)
  val = val:gsub('([\\%%_])', '\\%1'):gsub("'", "''")
  return val
end

---sql.from util
---@param a DBValue
---@param b? DBValue
---@param ... DBValue
---@return string
local function get_list_tokens(a, b, ...)
  if b == nil then
    return as_token(a)
  else
    local res = {}
    for i, name in ipairs { a, b, ... } do
      res[#res + 1] = as_token(name)
    end
    return concat(res, ", ")
  end
end

-- prefix column with `V`: column => V.column
---@param column string
---@return string
local function _prefix_with_V(column)
  return "V." .. column
end


---@param key string
---@param op? string
---@param val? DBValue
---@return string
local function _get_join_expr(key, op, val)
  if op == nil then
    return key
  elseif val == nil then
    return format("%s = %s", key, op)
  else
    return format("%s %s %s", key, op, val)
  end
end

---@param join_type JOIN_TYPE
---@param right_table string
---@param key string
---@param op? string
---@param val? DBValue
---@return string
local function _get_join_token(join_type, right_table, key, op, val)
  if key ~= nil then
    return format("%s JOIN %s ON (%s)", join_type, right_table, _get_join_expr(key, op, val))
  else
    return format("%s JOIN %s", join_type, right_table)
  end
end

---@param opts table
---@param key string
---@return string?, string?
local function get_join_table_condition(opts, key)
  local from, where
  local froms
  if opts[key] and opts[key] ~= "" then
    froms = { opts[key] }
    -- join_args 首项与 froms 以空格拼接，与显式 from/using 混用会缺逗号
    -- 生成非法 SQL（FROM a b），提前拦截
    assert(not (opts.join_args and opts.join_args[1]),
      "can't mix explicit from/using with join-derived tables in UPDATE/DELETE")
  else
    froms = {}
  end
  local wheres
  if opts.where and opts.where ~= "" then
    wheres = { opts.where }
  else
    wheres = {}
  end
  if opts.join_args then
    for i, args in ipairs(opts.join_args) do
      --args: {"INNER", '"user"', "T1", "T.user_id = T1.id"}
      if i == 1 then
        froms[#froms + 1] = args[2] .. ' AS ' .. args[3]
        wheres[#wheres + 1] = args[4] -- string returned by join callback
      else
        froms[#froms + 1] = format('%s JOIN %s ON (%s)', args[1], args[2] .. ' ' .. args[3], args[4])
      end
    end
  end
  if #froms > 0 then
    from = concat(froms, " ")
  end
  if #wheres == 1 then
    where = wheres[1]
  elseif #wheres > 1 then
    where = "(" .. concat(wheres, ") AND (") .. ")"
  end
  return from, where
end

---@param opts table
---@return string
local function get_join_table_condition_select(opts, init_from)
  local froms = { init_from }
  if opts.join_args then
    for i, args in ipairs(opts.join_args) do
      froms[#froms + 1] = format('%s JOIN %s ON (%s)', args[1], args[2] .. ' ' .. args[3], args[4])
    end
  end
  return concat(froms, " ")
end

---base util: sql.assemble
---@param opts SqlOptions
---@return string
local function assemble_sql(opts)
  local statement
  if opts.update then
    local from, where = get_join_table_condition(opts, "from")
    local returning = opts.returning and " RETURNING " .. opts.returning or ""
    local table_name
    if opts.as then
      table_name = opts.table_name .. ' AS ' .. opts.as
    else
      table_name = opts.table_name
    end
    statement = format("UPDATE %s SET %s%s%s%s",
      table_name,
      opts.update,
      from and " FROM " .. from or "",
      where and " WHERE " .. where or "",
      returning)
  elseif opts.insert then
    local returning = opts.returning and " RETURNING " .. opts.returning or ""
    local table_name
    if opts.as then
      table_name = opts.table_name .. ' AS ' .. opts.as
    else
      table_name = opts.table_name
    end
    statement = format("INSERT INTO %s %s%s", table_name, opts.insert, returning)
  elseif opts.delete then
    local using, where = get_join_table_condition(opts, "using")
    local returning = opts.returning and " RETURNING " .. opts.returning or ""
    local table_name
    if opts.as then
      table_name = opts.table_name .. ' AS ' .. opts.as
    else
      table_name = opts.table_name
    end
    statement = format("DELETE FROM %s%s%s%s",
      table_name,
      using and " USING " .. using or "",
      where and " WHERE " .. where or "",
      returning)
  else
    local from
    if opts.from then
      from = opts.from
    elseif opts.as then
      from = opts.table_name .. ' ' .. opts.as
    else
      from = opts.table_name
    end
    from = get_join_table_condition_select(opts, from)
    local where = opts.where and " WHERE " .. opts.where or ""
    local group = opts.group and " GROUP BY " .. opts.group or ""
    local having = opts.having and " HAVING " .. opts.having or ""
    local order = opts.order and " ORDER BY " .. opts.order or ""
    local limit = opts.limit and " LIMIT " .. opts.limit or ""
    local offset = opts.offset and " OFFSET " .. opts.offset or ""
    local distinct = opts.distinct and "DISTINCT " or
        opts.distinct_on and format("DISTINCT ON(%s) ", opts.distinct_on) or ""
    local select = opts.select or "*"
    local for_update = ""
    if opts.for_update then
      for_update = opts.for_update_no_key and " FOR NO KEY UPDATE" or " FOR UPDATE"
      if opts.for_update_of then
        for_update = for_update .. " OF " .. opts.for_update_of
      end
      if opts.for_update_nowait then
        for_update = for_update .. " NOWAIT"
      elseif opts.for_update_skip_locked then
        for_update = for_update .. " SKIP LOCKED"
      end
    end
    statement = format("SELECT %s%s FROM %s%s%s%s%s%s%s%s",
      distinct, select, from, where, group, having, order, limit, offset, for_update)
  end
  if opts.with and opts.with_recursive then
    return format("WITH RECURSIVE %s, %s %s", opts.with_recursive, opts.with, statement)
  elseif opts.with then
    return format("WITH %s %s", opts.with, statement)
  elseif opts.with_recursive then
    return format("WITH RECURSIVE %s %s", opts.with_recursive, statement)
  else
    return statement
  end
end

return {
  -- Table & Core Utilities
  clone = clone,
  isempty = isempty,
  NULL = NULL,
  table_new = table_new,
  table_clear = table_clear,
  list = list,
  dict = dict,
  map = map,
  get_keys = get_keys,
  is_empty_value = is_empty_value,

  -- String Utilities
  utf8len = utf8len,
  capitalize = capitalize,
  to_camel_case = to_camel_case,
  split_string = split_string,

  -- Constants (PostgreSQL/SQL)
  PG_OPERATORS = PG_OPERATORS,
  IS_PG_KEYWORDS = IS_PG_KEYWORDS,
  PG_SET_MAP = PG_SET_MAP,
  json_operators = json_operators,
  NON_OPERATOR_CONTEXTS = NON_OPERATOR_CONTEXTS,

  -- SQL Construction & ORM Helpers
  smart_quote = smart_quote,
  make_token = make_token,
  DEFAULT = DEFAULT,
  get_foreign_object = get_foreign_object,
  extract_column_name = extract_column_name,
  extract_column_names = extract_column_names,
  as_literal = as_literal,
  as_token = as_token,
  as_literal_without_brackets = as_literal_without_brackets,
  escape_like_value = escape_like_value,
  get_list_tokens = get_list_tokens,
  _prefix_with_V = _prefix_with_V,
  _get_join_expr = _get_join_expr,
  _get_join_token = _get_join_token,
  get_join_table_condition = get_join_table_condition,
  get_join_table_condition_select = get_join_table_condition_select,
  assemble_sql = assemble_sql,
}
