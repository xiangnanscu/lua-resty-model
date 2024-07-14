---@diagnostic disable: invisible
-- https://www.postgreSql.org/docs/current/sql-select.html
-- https://www.postgreSql.org/docs/current/sql-insert.html
-- https://www.postgreSql.org/docs/current/sql-update.html
-- https://www.postgreSql.org/docs/current/sql-delete.html
local encode = require("cjson").encode
local Fields = require "resty.fields"
local Query = require "resty.query"
local Object = require "resty.object"
local Array = require "resty.array"
local getenv = require "resty.dotenv".getenv
local ngx = ngx
local nkeys, clone, isempty, NULL, table_new, table_clear
if ngx then
  nkeys = require "table.nkeys"
  clone = require "table.clone"
  isempty = require "table.isempty"
  NULL = ngx.null
  table_new = table.new
  table_clear = require("table.clear")
else
  nkeys = function(t)
    local count = 0
    for k, v in pairs(t) do
      count = count + 1
    end
    return count
  end

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
local setmetatable = setmetatable
local ipairs = ipairs
local tostring = tostring
local type = type
local pairs = pairs
local assert = assert
local error = error
local string_format = string.format
local table_insert = table.insert
local ngx_localtime = ngx.localtime
local next = next
local format = string.format
local table_concat = table.concat

---@alias Keys string|string[]
---@alias SqlSet "_union"|"_union_all"| "_except"| "_except_all"|"_intersect"|"_intersect_all"
---@alias Token fun(): string
---@alias DBLoadValue string|number|integer|boolean|table
---@alias DBValue DBLoadValue|Token
---@alias Record {[string]:DBValue}
---@alias Records Record|Record[]
---@alias ValidateErrorObject {[string]: any}
---@alias ValidateError string|ValidateErrorObject
---@alias JOIN_TYPE "INNER"|"LEFT"|"RIGHT"|"FULL"

---@class SqlOptions
---@field table_name string
---@field as? string
---@field with? string
---@field with_recursive? string
---@field delete? boolean
---@field distinct? boolean
---@field distinct_on? string
---@field from? string
---@field group? string
---@field having? string
---@field insert? string
---@field limit? number
---@field offset? number
---@field order? string
---@field select? string
---@field update? string
---@field using? string
---@field where? string
---@field returning?  string
---@field join_args? string[][]

local default_query = Query {
  HOST = getenv "PGHOST" or "127.0.0.1",
  PORT = getenv "PGPORT" or 5432,
  DATABASE = getenv "PGDATABASE" or "postgres",
  USER = getenv "PGUSER" or "postgres",
  PASSWORD = getenv "PGPASSWORD" or "",
}
local normalize_field_shortcuts = Fields.basefield.normalize_field_shortcuts

local PG_SET_MAP = {
  _union = 'UNION',
  _union_all = 'UNION ALL',
  _except = 'EXCEPT',
  _except_all = 'EXCEPT ALL',
  _intersect = 'INTERSECT',
  _intersect_all = 'INTERSECT ALL'
}
local COMPARE_OPERATORS = { lt = "<", lte = "<=", gt = ">", gte = ">=", ne = "<>", eq = "=" }

local DEFAULT_PRIMARY_KEY = 'id'
local DEFAULT_STRING_MAXLENGTH = 256
local IS_PG_KEYWORDS = {
  -- operator reserve because _parse_column logic
  EQ = true,
  -- IN = true,
  NOTIN = true,
  CONTAINS = true,
  STARTSWITH = true,
  ENDSWITH = true,
  -- NULL = true,
  LT = true,
  LTE = true,
  GT = true,
  GTE = true,
  NE = true,
  -- operator reserve because _parse_column logic
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
local MODEL_MERGE_NAMES = {
  admin = true,
  table_name = true,
  class_name = true,
  label = true,
  db_options = true,
  abstract = true,
  auto_primary_key = true,
  primary_key = true,
  unique_together = true,
  referenced_label_column = true,
  preload = true,
}

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

local function map(tbl, func)
  local res = {}
  for i = 1, #tbl do
    res[i] = func(tbl[i])
  end
  return res
end

local function flat(tbl)
  local res = {}
  for i = 1, #tbl do
    local t = tbl[i]
    if type(t) ~= "table" then
      res[#res + 1] = t
    else
      for _, e in ipairs(flat(t)) do
        res[#res + 1] = e
      end
    end
  end
  return res
end

local function get_keys(rows)
  local columns = {}
  if rows[1] then
    local d = {}
    for _, row in ipairs(rows) do
      for k, _ in pairs(row) do
        if not d[k] then
          d[k] = true
          table_insert(columns, k)
        end
      end
    end
  else
    for k, _ in pairs(rows) do
      table_insert(columns, k)
    end
  end
  return columns
end

local function get_keys_head(rows)
  local columns = {}
  for k, _ in pairs(rows[1] or rows) do
    table_insert(columns, k)
  end
  return columns
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

local function _prefix_with_V(column)
  return "V." .. column
end

---@param value DBValue
---@return string
local function as_literal(value)
  local value_type = type(value)
  if "string" == value_type then
    return "'" .. (value:gsub("'", "''")) .. "'"
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
      return "(" .. table_concat(map(value, as_literal), ", ") .. ")"
    else
      error("empty table is not allowed")
    end
  elseif NULL == value then
    return 'NULL'
  else
    error(format("don't know how to escape value: %s (%s)", value, value_type))
  end
end

---@param value DBValue
---@return string
local function as_token(value)
  local value_type = type(value)
  if "string" == value_type then
    return value
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
      return table_concat(map(value, as_token), ", ")
    else
      error("empty table is not allowed")
    end
  elseif NULL == value then
    return 'NULL'
  else
    error(format("don't know how to escape value: %s (%s)", value, value_type))
  end
end

-- local as_literal_without_brackets = _escape_factory(true, false)
---@param value DBValue
---@return string
local function as_literal_without_brackets(value)
  local value_type = type(value)
  if "string" == value_type then
    return "'" .. (value:gsub("'", "''")) .. "'"
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
      return table_concat(map(value, as_literal_without_brackets), ", ")
    else
      error("empty table is not allowed")
    end
  elseif NULL == value then
    return 'NULL'
  else
    error(format("don't know how to escape value: %s (%s)", value, value_type))
  end
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
    return table_concat(res, ", ")
  end
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
  local froms = {}
  if opts[key] and opts[key] ~= "" then
    froms = { opts[key] }
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
      --args: {"INNER", "usr T1", "T.usr_id = T1.id"}
      if i == 1 then
        froms[#froms + 1] = args[2]
        wheres[#wheres + 1] = args[3] -- string returned by join callback
      else
        froms[#froms + 1] = format('%s JOIN %s ON (%s)', args[1], args[2], args[3])
      end
    end
  end
  if #froms > 0 then
    from = table_concat(froms, " ")
  end
  if #wheres > 0 then
    where = "(" .. table_concat(wheres, ") AND (") .. ")"
  end
  return from, where
end

---@param opts table
---@return string
local function get_join_table_condition_select(opts, init_from)
  local froms = { init_from }
  if opts.join_args then
    for i, args in ipairs(opts.join_args) do
      froms[#froms + 1] = format('%s JOIN %s ON (%s)', args[1], args[2], args[3])
    end
  end
  return table_concat(froms, " ")
end

---base util: sql.assemble
---@param opts SqlOptions
---@return string
local function assemble_sql(opts)
  local statement
  if opts.update then
    local from, where = get_join_table_condition(opts, "from")
    local returning = opts.returning and " RETURNING " .. opts.returning or ""
    local table_name = opts.as and (opts.table_name .. ' ' .. opts.as) or opts.table_name
    statement = format("UPDATE %s SET %s%s%s%s",
      table_name,
      opts.update,
      from and " FROM " .. from or "",
      where and " WHERE " .. where or "",
      returning)
  elseif opts.insert then
    local returning = opts.returning and " RETURNING " .. opts.returning or ""
    local table_name = opts.as and opts.table_name .. ' AS ' .. opts.as or opts.table_name
    statement = format("INSERT INTO %s %s%s", table_name, opts.insert, returning)
  elseif opts.delete then
    local using, where = get_join_table_condition(opts, "using")
    local returning = opts.returning and " RETURNING " .. opts.returning or ""
    local table_name = opts.as and opts.table_name .. ' ' .. opts.as or opts.table_name
    statement = format("DELETE FROM %s%s%s%s",
      table_name,
      using and " USING " .. using or "",
      where and " WHERE " .. where or "",
      returning)
  else
    local from = opts.from or (opts.as and (opts.table_name .. ' ' .. opts.as) or opts.table_name)
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
    statement = format("SELECT %s%s FROM %s%s%s%s%s%s%s",
      distinct, select, from, where, group, having, order, limit, offset)
  end
  if opts.with then
    return format("WITH %s %s", opts.with, statement)
  elseif opts.with_recursive then
    return format("WITH RECURSIVE %s %s", opts.with_recursive, statement)
  else
    return statement
  end
end

local SqlMeta = {}

---@param self Sql
---@param args string|table
function SqlMeta.__call(self, args)
  if type(args) == 'string' then
    return self:new { table_name = args }
  else
    return self:new(args)
  end
end

---@class Sql
---@field model Xodel
---@field table_name string
---@field private _pcall? boolean
---@field private _as?  string
---@field private _with?  string
---@field private _with_recursive?  string
---@field private _join?  string
---@field private _distinct?  boolean
---@field private _distinct_on?  string
---@field private _returning?  string
---@field private _returning_args?  DBValue[]
---@field private _returning_literal_args?  DBValue[]
---@field private _insert?  string
---@field private _update?  string
---@field private _delete?  boolean
---@field private _using?  string
---@field private _select?  string
---@field private _select_args?  DBValue[]
---@field private _select_literal_args?  DBValue[]
---@field private _from?  string
---@field private _where?  string
---@field private _group?  string
---@field private _having?  string
---@field private _order?  string
---@field private _limit?  number
---@field private _offset?  number
---@field private _union?  Sql | string
---@field private _union_all?  Sql | string
---@field private _except?  Sql | string
---@field private _except_all?  Sql | string
---@field private _intersect?  Sql | string
---@field private _intersect_all?  Sql | string
---@field private _join_type?  string
---@field private _join_args?  table[]
---@field private _join_models?  Xodel[]
---@field private _join_alias?  string[]
---@field private _prepend?  (Sql|string)[]
---@field private _append?  (Sql|string)[]
---@field private _join_keys? table
---@field private _load_fk? table
---@field private _skip_validate? boolean
---@field private _commit? boolean
---@field private _compact? boolean
---@field private _raw? boolean
local Sql = setmetatable({}, SqlMeta)
Sql.__index = Sql
Sql.__SQL_BUILDER__ = true
Sql.NULL = NULL
Sql.DEFAULT = DEFAULT
Sql.token = make_token
Sql.as_token = as_token
Sql.as_literal = as_literal
Sql.as_literal_without_brackets = as_literal_without_brackets

function Sql:__tostring()
  return self:statement()
end

---@param attrs? table
---@return self
function Sql:new(attrs)
  return setmetatable(attrs or {}, self)
end

---keeping args passed to Sql
---@param method_name string
---@param ... any
function Sql:_keep_args(method_name, ...)
  if self[method_name] then
    self[method_name] = { self[method_name], ... }
  else
    self[method_name] = { ... }
  end
  return self
end

---@private
---@param rows Sql|Records|string
---@param columns? string[]
---@return self
function Sql:_base_insert(rows, columns)
  if type(rows) == "table" then
    if rows.__SQL_BUILDER__ then
      ---@cast rows Sql
      if rows._returning_args then
        self:_set_cud_subquery_insert_token(rows, columns)
      elseif rows._select_args then
        self:_set_select_subquery_insert_token(rows, columns)
      else
        error("select or returning args should be provided when inserting from a sub query")
      end
    elseif rows[1] then
      ---@cast rows Record[]
      self._insert = self:_get_bulk_insert_token(rows, columns)
    elseif next(rows) ~= nil then
      ---@cast rows Record
      self._insert = self:_get_insert_token(rows, columns)
    else
      error("empty table can't used as insert data")
    end
  elseif type(rows) == 'string' then
    self._insert = rows
  else
    error("invalid rows type:" .. type(rows))
  end
  return self
end

---@private
---@param row Record|string|Sql
---@param columns? string[]
---@return self
function Sql:_base_update(row, columns)
  if type(row) == "table" then
    if row.__SQL_BUILDER__ then
      ---@cast row Sql
      self._update = self:_base_get_update_query_token(row, columns)
    else
      self._update = self:_get_update_token(row, columns)
    end
  else
    ---@cast row string
    self._update = row
  end
  return self
end

---@private
---@param join_type string
---@param right_table string
---@param key string
---@param op? string
---@param val? DBValue
---@return self
function Sql:_base_join_raw(join_type, right_table, key, op, val)
  local join_token = _get_join_token(join_type, right_table, key, op, val)
  self._from = format("%s %s", self._from or self:get_table(), join_token)
  return self
end

---@private
---@param ... DBValue
---@return self
function Sql:_base_select(...)
  local s = get_list_tokens(...)
  if s == "" then
  elseif not self._select then
    self._select = s
  else
    self._select = self._select .. ", " .. s
  end
  return self
end

---@private
---@param rows Record[]
---@param key Keys
---@param columns? string[]
---@return self
function Sql:_base_merge(rows, key, columns)
  rows, columns = self:_get_cte_values_literal(rows, columns, false)
  local cte_name = format("V(%s)", table_concat(columns, ", "))
  local cte_values = format("(VALUES %s)", as_token(rows))
  local join_cond = self:_get_join_condition_from_key(key, "V", "W")
  local vals_columns = map(columns, _prefix_with_V)
  local insert_subquery = Sql:new { table_name = "V" }
      :_base_select(vals_columns)
      :_keep_args("_select_args", vals_columns)
      :_base_join_raw("LEFT", "U AS W", join_cond)
      :_base_where_null("W." .. (key[1] or key))
  local updated_subquery
  if (type(key) == "table" and #key == #columns) or #columns == 1 then
    -- https://github.com/xiangnanscu/lua-resty-model?tab=readme-ov-file#merge-multiple-rows-returning-inserted-rows-with-array-key-and-specific-columns
    updated_subquery = Sql:new { table_name = "V" }
        :_base_select(vals_columns)
        :_base_join_raw("INNER", self.table_name .. " AS W", join_cond)
        :_base_returning(vals_columns)
  else
    -- https://github.com/xiangnanscu/lua-resty-model?tab=readme-ov-file#merge-multiple-rows-returning-inserted-rows-with-array-key
    updated_subquery = Sql:new { table_name = self.table_name, _as = "W" }
        :_base_update(self:_get_update_token_with_prefix(columns, key, "V"))
        :_base_from("V"):_base_where(join_cond)
        :_base_returning(vals_columns)
  end
  self:with(cte_name, cte_values):with("U", updated_subquery)
  return Sql._base_insert(self, insert_subquery, columns)
end

---@private
---@param rows Sql|Record[]
---@param key Keys
---@param columns? string[]
---@return self
function Sql:_base_upsert(rows, key, columns)
  assert(key, "you must provide key (string or table) for upsert")
  if rows.__SQL_BUILDER__ then
    assert(columns ~= nil, "you must specify columns when use subquery as values of upsert")
    self._insert = self:_get_upsert_query_token(rows, key, columns)
  elseif rows[1] then
    self._insert = self:_get_bulk_upsert_token(rows, key, columns)
  else
    self._insert = self:_get_upsert_token(rows, key, columns)
  end
  return self
end

---@private
---@param rows Record[]|Sql
---@param key Keys
---@param columns? string[]
---@return self
function Sql:_base_updates(rows, key, columns)
  if rows.__SQL_BUILDER__ then
    ---@cast rows Sql
    columns = columns or flat(rows._returning_args)
    local cte_name = format("V(%s)", table_concat(columns, ", "))
    local join_cond = self:_get_join_condition_from_key(key, "V", self._as or self.table_name)
    self:with(cte_name, rows)
    return Sql._base_update(self, self:_get_update_token_with_prefix(columns, key, "V"))
        :_base_from("V"):_base_where(join_cond)
  elseif #rows == 0 then
    error("empty rows passed to updates")
  else
    ---@cast rows Record[]
    rows, columns = self:_get_cte_values_literal(rows, columns, false)
    local cte_name = format("V(%s)", table_concat(columns, ", "))
    local cte_values = format("(VALUES %s)", as_token(rows))
    local join_cond = self:_get_join_condition_from_key(key, "V", self._as or self.table_name)
    self:with(cte_name, cte_values)
    return Sql._base_update(self, self:_get_update_token_with_prefix(columns, key, "V"))
        :_base_from("V"):_base_where(join_cond)
  end
end

---@private
---@param ... DBValue
---@return self
function Sql:_base_returning(...)
  local s = get_list_tokens(...)
  if s == "" then
  elseif not self._returning then
    self._returning = s
  else
    self._returning = self._returning .. ", " .. s
  end
  self:_keep_args("_returning_args", ...)
  return self
end

---@private
---@param ... string
---@return self
function Sql:_base_from(...)
  local s = get_list_tokens(...)
  if s == "" then
  elseif not self._from then
    self._from = s
  else
    self._from = self._from .. ", " .. s
  end
  return self
end

---@private
---@param ... string
---@return self
function Sql:_base_using(...)
  local s = get_list_tokens(...)
  if s == "" then
  elseif not self._using then
    self._using = s
  else
    self._using = self._using .. ", " .. s
  end
  return self
end

---@param model Xodel
---@param alias string
---@return table
function Sql:_create_join_proxy(model, alias)
  local function __index(_, key)
    local field = model.fields[key]
    if field then
      -- return setmetatable({ table_name = alias, name = key }, getmetatable(field))
      return alias .. '.' .. key
    end
  end
  local proxy = setmetatable({}, { __index = __index })
  return proxy
end

function Sql:_ensure_context()
  if not self._join_proxy_models then
    local alias = self._as or self.table_name
    local main_proxy = self:_create_join_proxy(self.model, alias)
    self._join_proxy_models = { main_proxy }
    self._join_alias = { alias }
    self._join_models = { self.model }
  end
end

function Sql:_create_context()
  self:_ensure_context()
  local context = { unpack(self._join_proxy_models) }
  for i, proxy in ipairs(self._join_proxy_models) do
    context[self._join_models[i].table_name] = proxy
    context[self._join_models[i].class_name or ""] = proxy
  end
  return context
end

---@param self Sql
---@param join_type string
---@param fk_models Xodel[]
---@param callback function
---@param join_key? string
---@return string
function Sql:_handle_manual_join(join_type, fk_models, callback, join_key)
  self:_ensure_context()
  if not self._join_args then
    self._join_args = {}
  end
  if not self._join_keys then
    self._join_keys = {}
  end
  local offset = #self._join_proxy_models
  for i, fk_model in ipairs(fk_models) do
    local right_alias = 'T' .. #self._join_models
    local proxy = self:_create_join_proxy(fk_model, right_alias)
    self._join_proxy_models[#self._join_proxy_models + 1] = proxy
    self._join_alias[#self._join_alias + 1] = right_alias
    self._join_models[#self._join_models + 1] = fk_model
    self._join_keys[join_key or right_alias] = right_alias
    -- res[#res + 1] = { proxy = proxy, alias = right_alias, model = fk_model }
  end
  local join_conds = callback(self:_create_context())
  if type(join_conds) == 'string' then
    join_conds = { join_conds }
  end
  for i, fk_model in ipairs(fk_models) do
    local right_alias_declare = fk_model.table_name .. ' ' .. self._join_alias[offset + i]
    self._join_args[#self._join_args + 1] = { join_type, right_alias_declare, join_conds[i] }
  end
  return self._join_alias[#self._join_alias]
end

---@private
---@param join_type string
---@param join_args table|string
---@param ... any
---@return self
function Sql:_base_join(join_type, join_args, ...)
  if type(join_args) == 'table' then
    if join_args.__is_model_class__ then
      local fk_models = {}
      local res = { join_args, ... }
      local callback
      for i, a in ipairs(res) do
        if i == #res then
          callback = a
        else
          fk_models[#fk_models + 1] = a
        end
      end
      ---@diagnostic disable-next-line: param-type-mismatch
      self:_handle_manual_join(join_type, fk_models, callback)
      return self
    else
      error("invalid argument, it must be a pair: { model_class, condition_callback }")
    end
  else
    local fk = self.model.foreign_keys[join_args]
    if fk then
      return self:_base_join("INNER", fk.reference, function(ctx)
        return format("%s = %s",
          ctx[self.model.table_name][join_args],
          ctx[fk.reference.table_name][fk.reference_column])
      end)
    else
      return self:_base_join_raw(join_type, join_args, ...)
    end
  end
end

---@private
---@param cond table|string|fun(ctx:table):string
---@param op? string
---@param dval? DBValue
---@return self
function Sql:_base_where(cond, op, dval)
  local where_token = self:_base_get_condition_token(cond, op, dval)
  return self:_handle_where_token(where_token, "(%s) AND (%s)")
end

---@private
---@param cond table|string|fun(ctx:table):string
---@param op? DBValue
---@param dval? DBValue
---@return string
function Sql:_base_get_condition_token(cond, op, dval)
  if op == nil then
    local argtype = type(cond)
    if argtype == "table" then
      return Sql._base_get_condition_token_from_table(self, cond)
    elseif argtype == "string" then
      return cond
    elseif argtype == "function" then
      return cond(self:_create_context())
    else
      error("invalid condition type: " .. argtype)
    end
  elseif dval == nil then
    return format("%s = %s", cond, as_literal(op))
  else
    return format("%s %s %s", cond, op, as_literal(dval))
  end
end

---@private
---@param kwargs {[string|number]:any}
---@param logic? "AND"|"OR"
---@return string
function Sql:_base_get_condition_token_from_table(kwargs, logic)
  local tokens = {}
  for k, value in pairs(kwargs) do
    tokens[#tokens + 1] = format("%s = %s", k, as_literal(value))
    -- if type(k) == "string" then
    --   tokens[#tokens + 1] = format("%s = %s", k, as_literal(value))
    -- else
    --   local token = self:_base_get_condition_token(value)
    --   if token ~= nil and token ~= "" then
    --     tokens[#tokens + 1] = '(' .. token .. ')'
    --   end
    -- end
  end
  if logic == nil then
    return table_concat(tokens, " AND ")
  else
    return table_concat(tokens, " " .. logic .. " ")
  end
end

---@private
---@param cols string|string[]
---@param range Sql|table|string
---@return self
function Sql:_base_where_in(cols, range)
  local in_token = self:_get_in_token(cols, range)
  if self._where then
    self._where = format("(%s) AND %s", self._where, in_token)
  else
    self._where = in_token
  end
  return self
end

---@private
---@param cols string|string[]
---@param range Sql|table|string
---@return self
function Sql:_base_where_not_in(cols, range)
  local not_in_token = self:_get_in_token(cols, range, "NOT IN")
  if self._where then
    self._where = format("(%s) AND %s", self._where, not_in_token)
  else
    self._where = not_in_token
  end
  return self
end

---@private
---@param col string
---@return self
function Sql:_base_where_null(col)
  if self._where then
    self._where = format("(%s) AND %s IS NULL", self._where, col)
  else
    self._where = col .. " IS NULL"
  end
  return self
end

---@private
---@param col string
---@return self
function Sql:_base_where_not_null(col)
  if self._where then
    self._where = format("(%s) AND %s IS NOT NULL", self._where, col)
  else
    self._where = col .. " IS NOT NULL"
  end
  return self
end

---@private
---@param col string
---@param low number
---@param high number
---@return self
function Sql:_base_where_between(col, low, high)
  if self._where then
    self._where = format("(%s) AND (%s BETWEEN %s AND %s)", self._where, col, low, high)
  else
    self._where = format("%s BETWEEN %s AND %s", col, low, high)
  end
  return self
end

---@private
---@param col string
---@param low number
---@param high number
---@return self
function Sql:_base_where_not_between(col, low, high)
  if self._where then
    self._where = format("(%s) AND (%s NOT BETWEEN %s AND %s)", self._where, col, low, high)
  else
    self._where = format("%s NOT BETWEEN %s AND %s", col, low, high)
  end
  return self
end

---@private
---@param cols string|string[]
---@param range Sql|table|string
---@return self
function Sql:_base_or_where_in(cols, range)
  local in_token = self:_get_in_token(cols, range)
  if self._where then
    self._where = format("%s OR %s", self._where, in_token)
  else
    self._where = in_token
  end
  return self
end

---@private
---@param cols string|string[]
---@param range Sql|table|string
---@return self
function Sql:_base_or_where_not_in(cols, range)
  local not_in_token = self:_get_in_token(cols, range, "NOT IN")
  if self._where then
    self._where = format("%s OR %s", self._where, not_in_token)
  else
    self._where = not_in_token
  end
  return self
end

---@private
---@param col string
---@return self
function Sql:_base_or_where_null(col)
  if self._where then
    self._where = format("%s OR %s IS NULL", self._where, col)
  else
    self._where = col .. " IS NULL"
  end
  return self
end

---@private
---@param col string
---@return self
function Sql:_base_or_where_not_null(col)
  if self._where then
    self._where = format("%s OR %s IS NOT NULL", self._where, col)
  else
    self._where = col .. " IS NOT NULL"
  end
  return self
end

---@private
---@param col string
---@param low number
---@param high number
---@return self
function Sql:_base_or_where_between(col, low, high)
  if self._where then
    self._where = format("%s OR (%s BETWEEN %s AND %s)", self._where, col, low, high)
  else
    self._where = format("%s BETWEEN %s AND %s", col, low, high)
  end
  return self
end

---@private
---@param col string
---@param low number
---@param high number
---@return self
function Sql:_base_or_where_not_between(col, low, high)
  if self._where then
    self._where = format("%s OR (%s NOT BETWEEN %s AND %s)", self._where, col, low, high)
  else
    self._where = format("%s NOT BETWEEN %s AND %s", col, low, high)
  end
  return self
end

---@private
---@return self
function Sql:pcall()
  self._pcall = true
  return self
end

---@private
---@param err ValidateError
---@param level? integer
---@return nil, ValidateError?
function Sql:error(err, level)
  if self._pcall then
    return nil, err
  else
    error(err, level)
  end
end

---@private
---@param rows Record[]
---@param columns string[]
---@return DBValue[][]
function Sql:_rows_to_array(rows, columns)
  local c = #columns
  local n = #rows
  local res = table_new(n, 0)
  local fields = self.model.fields
  for i = 1, n do
    res[i] = table_new(c, 0)
  end
  for i, col in ipairs(columns) do
    for j = 1, n do
      local v = rows[j][col]
      if v ~= nil and v ~= '' then
        res[j][i] = v
      elseif fields[col] then
        local default = fields[col].default
        if default ~= nil then
          res[j][i] = fields[col]:get_default()
        else
          res[j][i] = NULL
        end
      else
        res[j][i] = NULL
      end
    end
  end
  return res
end

---make single insert token
---@private
---@param row Record
---@param columns? string[]
---@return string[], string[]
function Sql:_get_insert_values_token(row, columns)
  local value_list = {}
  if not columns then
    columns = {}
    for k, v in pairs(row) do
      table_insert(columns, k)
      table_insert(value_list, v)
    end
  else
    for _, col in pairs(columns) do
      local v = row[col]
      if v ~= nil then
        table_insert(value_list, v)
      else
        table_insert(value_list, DEFAULT)
      end
    end
  end
  return value_list, columns
end

---make bulk insert token
---@private
---@param rows Record[]
---@param columns? string[]
---@return string[], string[]
function Sql:_get_bulk_insert_values_token(rows, columns)
  columns = columns or get_keys_head(rows)
  rows = self:_rows_to_array(rows, columns)
  return map(rows, as_literal), columns
end

---take `key` away from update `columns`, return set token for update
---@private
---@param columns string[] columns that need to update
---@param key Keys name or names that need to be taken away from columns
---@param prefix string table name as prefix
---@return string
function Sql:_get_update_token_with_prefix(columns, key, prefix)
  local tokens = {}
  if type(key) == "string" then
    for i, col in ipairs(columns) do
      if col ~= key then
        table_insert(tokens, format("%s = %s.%s", col, prefix, col))
      end
    end
  else
    local sets = {}
    for i, k in ipairs(key) do
      sets[k] = true
    end
    for i, col in ipairs(columns) do
      if not sets[col] then
        table_insert(tokens, format("%s = %s.%s", col, prefix, col))
      end
    end
  end
  return table_concat(tokens, ", ")
end

---get select token
---@private
---@param a (fun(ctx:table):string)|DBValue
---@param b? DBValue
---@param ...? DBValue
---@return string
function Sql:_get_select_token(a, b, ...)
  if b == nil then
    if type(a) == "table" then
      local tokens = {}
      for i = 1, #a do
        tokens[i] = self:_get_select_column(a[i])
      end
      return as_token(tokens)
    elseif type(a) == "string" then
      return self:_get_select_column(a) --[[@as string]]
    elseif type(a) == 'function' then
      ---@cast a -DBValue
      local select_args = a(self:_create_context())
      if type(select_args) == 'string' then
        return select_args
      elseif type(select_args) == 'table' then
        return table_concat(select_args, ', ')
      else
        error("wrong type:" .. type(select_args))
      end
    else
      return as_token(a)
    end
  else
    local res = {}
    for i, name in ipairs { a, b, ... } do
      res[#res + 1] = as_token(self:_get_select_column(name))
    end
    return table_concat(res, ", ")
  end
end

---@private
---@param a DBValue
---@param b? DBValue
---@param ...? DBValue
---@return string
function Sql:_get_select_literal(a, b, ...)
  if b == nil then
    if type(a) == "table" then
      local tokens = {}
      for i = 1, #a do
        tokens[i] = as_literal(a[i])
      end
      return as_token(tokens)
    else
      return as_literal(a)
    end
  else
    local res = {}
    for i, name in ipairs { a, b, ... } do
      res[#res + 1] = as_literal(name)
    end
    return table_concat(res, ", ")
  end
end

---get update token
---@private
---@param row Record
---@param columns? string[]
---@return string
function Sql:_get_update_token(row, columns)
  local kv = {}
  if not columns then
    for k, v in pairs(row) do
      table_insert(kv, format("%s = %s", k, as_literal(v)))
    end
  else
    for _, k in ipairs(columns) do
      local v = row[k]
      table_insert(kv, format("%s = %s", k, v ~= nil and as_literal(v) or 'DEFAULT'))
    end
  end
  return table_concat(kv, ", ")
end

---@private
---@param name string
---@param token? Sql|DBValue
---@return string
function Sql:_get_with_token(name, token)
  if token == nil then
    return name
  elseif getmetatable(token) and token.__SQL_BUILDER__ then
    ---@cast token Sql
    return format("%s AS (%s)", name, token:statement())
  else
    return format("%s AS %s", name, token)
  end
end

---@private
---@param row Record
---@param columns? string[]
---@return string
function Sql:_get_insert_token(row, columns)
  local values_list, insert_columns = self:_get_insert_values_token(row, columns)
  return format("(%s) VALUES %s", as_token(insert_columns), as_literal(values_list))
end

---@private
---@param rows Record[]
---@param columns? string[]
---@return string
function Sql:_get_bulk_insert_token(rows, columns)
  rows, columns = self:_get_bulk_insert_values_token(rows, columns)
  return format("(%s) VALUES %s", as_token(columns), as_token(rows))
end

---@private
---@param subsql Sql
---@param columns? string[]
function Sql:_set_select_subquery_insert_token(subsql, columns)
  -- INSERT INTO T1(a,b,c) SELECT a,b,c FROM T2
  local columns_token = as_token(columns or flat(subsql._select_args))
  self._insert = format("(%s) %s", columns_token, subsql:statement())
end

---@private
---@param subsql Sql
---@param columns? string[]
function Sql:_set_cud_subquery_insert_token(subsql, columns)
  -- WITH D(a,b,c) AS (UPDATE T2 SET a=1,b=2,c=3 RETURNING a,b,c) INSERT INTO T1(a,b,c) SELECT a,b,c from D
  local columns_token = as_token(columns or flat(subsql._returning_args))
  local cudsql = Sql:new { table_name = "D", _select = columns_token }
  self:with(format("D(%s)", columns_token), subsql)
  self._insert = format("(%s) %s", columns_token, cudsql:statement())
end

---@private
---@param row Record
---@param key Keys
---@param columns? string[]
---@return string
function Sql:_get_upsert_token(row, key, columns)
  local values_list, insert_columns = self:_get_insert_values_token(row, columns)
  local insert_token = format("(%s) VALUES %s ON CONFLICT (%s)",
    as_token(insert_columns),
    as_literal(values_list),
    get_list_tokens(key)) -- self:_get_select_token
  if (type(key) == "table" and #key == #insert_columns) or #insert_columns == 1 then
    return format("%s DO NOTHING", insert_token)
  else
    return format("%s DO UPDATE SET %s", insert_token,
      self:_get_update_token_with_prefix(insert_columns, key, "EXCLUDED"))
  end
end

---@private
---@param rows Record[]
---@param key Keys
---@param columns? string[]
---@return string
function Sql:_get_bulk_upsert_token(rows, key, columns)
  rows, columns = self:_get_bulk_insert_values_token(rows, columns)
  local insert_token = format("(%s) VALUES %s ON CONFLICT (%s)",
    as_token(columns),
    as_token(rows),
    get_list_tokens(key))
  if (type(key) == "table" and #key == #columns) or #columns == 1 then
    return format("%s DO NOTHING", insert_token)
  else
    return format("%s DO UPDATE SET %s", insert_token,
      self:_get_update_token_with_prefix(columns, key, "EXCLUDED"))
  end
end

---@private
---@param rows Sql
---@param key Keys
---@param columns string[]
---@return string
function Sql:_get_upsert_query_token(rows, key, columns)
  local columns_token = self:_get_select_token(columns)
  local insert_token = format("(%s) %s ON CONFLICT (%s)",
    columns_token,
    rows:statement(),
    self:_get_select_token(key))
  if (type(key) == "table" and #key == #columns) or #columns == 1 then
    return format("%s DO NOTHING", insert_token)
  else
    return format("%s DO UPDATE SET %s", insert_token,
      self:_get_update_token_with_prefix(columns, key, "EXCLUDED"))
  end
end

---@private
---@param cols Keys
---@param range Sql|table|string
---@param op? string
---@return string
function Sql:_get_in_token(cols, range, op)
  cols = as_token(cols)
  op = op or "IN"
  if type(range) == 'table' then
    if range.__SQL_BUILDER__ then
      return format("(%s) %s (%s)", cols, op, range:statement())
    else
      return format("(%s) %s %s", cols, op, as_literal(range))
    end
  else
    return format("(%s) %s %s", cols, op, range)
  end
end

---@private
---@param subquery Sql
---@param columns? string[]
---@return string
function Sql:_base_get_update_query_token(subquery, columns)
  -- UPDATE T1 SET (a, b) = (SELECT a1, b1 FROM T2 WHERE T1.tid = T2.id);
  local columns_token = get_list_tokens(columns or flat(subquery._select_args))
  return format("(%s) = (%s)", columns_token, subquery:statement())
end

---@private
---@param key Keys
---@param left_table string
---@param right_table string
---@return string
function Sql:_get_join_condition_from_key(key, left_table, right_table)
  if type(key) == "string" then
    -- A.k = B.k
    return format("%s.%s = %s.%s", left_table, key, right_table, key)
  end
  -- A.k1 = B.k1 AND A.k2 = B.k2
  local res = {}
  for _, k in ipairs(key) do
    res[#res + 1] = format("%s.%s = %s.%s", left_table, k, right_table, k)
  end
  return table_concat(res, " AND ")
end

---@private
---@param join_type JOIN_TYPE
---@param join_table string
---@param join_cond string
function Sql:_set_join_token(join_type, join_table, join_cond)
  if self._update then
    self:_base_from(join_table)
    self:_base_where(join_cond)
  elseif self._delete then
    self:_base_using(join_table)
    self:_base_where(join_cond)
  else
    self:_base_join_raw(join_type or "INNER", join_table, join_cond)
  end
end

---@private
---@param key DBValue
---@return DBValue
function Sql:_get_select_column(key)
  if type(key) ~= 'string' then
    return key
  else
    return (self:_parse_column(key, true))
  end
end

---@private
---@param where_token string
---@param tpl string
---@return self
function Sql:_handle_where_token(where_token, tpl)
  if where_token == "" then
    return self
  elseif self._where == nil then
    self._where = where_token
  else
    self._where = format(tpl, self._where, where_token)
  end
  return self
end

---@private
---@param kwargs {[string|number]:any}
---@param logic? string
---@return string
function Sql:_get_condition_token_from_table(kwargs, logic)
  local tokens = {}
  for k, value in pairs(kwargs) do
    if type(k) == "string" then
      tokens[#tokens + 1] = self:_get_expr_token(value, self:_parse_column(k))
    else
      local token = self:_get_condition_token(value)
      if token ~= nil and token ~= "" then
        tokens[#tokens + 1] = '(' .. token .. ')'
      end
    end
  end
  if logic == nil then
    return table_concat(tokens, " AND ")
  else
    return table_concat(tokens, " " .. logic .. " ")
  end
end

---@private
---@param cond table|string|fun(ctx:table):string
---@param op? DBValue
---@param dval? DBValue
---@return string
function Sql:_get_condition_token(cond, op, dval)
  if op == nil then
    if type(cond) == 'table' then
      return Sql._get_condition_token_from_table(self, cond)
    else
      return Sql._base_get_condition_token(self, cond)
    end
  elseif dval == nil then
    ---@cast cond string
    return format("%s = %s", self:_get_column(cond), as_literal(op))
  else
    ---@cast cond string
    return format("%s %s %s", self:_get_column(cond), op, as_literal(dval))
  end
end

---@private
---@param cond table|string|fun(ctx:table):string
---@param op? DBValue
---@param dval? DBValue
---@return string
function Sql:_get_condition_token_or(cond, op, dval)
  if type(cond) == "table" then
    return self:_get_condition_token_from_table(cond, "OR")
  else
    return self:_get_condition_token(cond, op, dval)
  end
end

---@private
---@param cond table|string|fun(ctx:table):string
---@param op? DBValue
---@param dval? DBValue
---@return string
function Sql:_get_condition_token_not(cond, op, dval)
  local token
  if type(cond) == "table" then
    token = self:_get_condition_token_from_table(cond, "OR")
  else
    token = self:_get_condition_token(cond, op, dval)
  end
  return token ~= "" and format("NOT (%s)", token) or ""
end

---@private
---@param other_sql Sql
---@param set_operation_attr SqlSet
---@return self
function Sql:_handle_set_option(other_sql, set_operation_attr)
  if not self[set_operation_attr] then
    self[set_operation_attr] = other_sql:statement();
  else
    self[set_operation_attr] = format("(%s) %s (%s)", self[set_operation_attr], PG_SET_MAP[set_operation_attr],
      other_sql:statement());
  end
  if self ~= Sql then
    self.statement = self._statement_for_set
  else
    error("don't call _handle_set_option directly on Sql class")
  end
  return self;
end

---@private
---@return string
function Sql:_statement_for_set()
  local statement = Sql.statement(self)
  if self._intersect then
    statement = format("(%s) INTERSECT (%s)", statement, self._intersect)
  elseif self._intersect_all then
    statement = format("(%s) INTERSECT ALL (%s)", statement, self._intersect_all)
  elseif self._union then
    statement = format("(%s) UNION (%s)", statement, self._union)
  elseif self._union_all then
    statement = format("%s UNION ALL (%s)", statement, self._union_all)
  elseif self._except then
    statement = format("(%s) EXCEPT (%s)", statement, self._except)
  elseif self._except_all then
    statement = format("(%s) EXCEPT ALL (%s)", statement, self._except_all)
  end
  return statement
end

---@param ... Sql[]|string[]
---@return self
function Sql:prepend(...)
  if not self._prepend then
    self._prepend = {}
  end
  local n = select("#", ...)
  for i = n, 1, -1 do
    local e = select(i, ...)
    table_insert(self._prepend, 1, e)
  end
  return self
end

---@param ... Sql[]|string[]
---@return self
function Sql:append(...)
  if not self._append then
    self._append = {}
  end
  for _, statement in ipairs({ ... }) do
    self._append[#self._append + 1] = statement
  end
  return self
end

---@return string
function Sql:statement()
  local statement = assemble_sql {
    table_name = self.table_name,
    as = self._as,
    with = self._with,
    with_recursive = self._with_recursive,
    distinct = self._distinct,
    distinct_on = self._distinct_on,
    returning = self._returning,
    insert = self._insert,
    update = self._update,
    delete = self._delete,
    using = self._using,
    select = self._select,
    from = self._from,
    join_args = self._join_args,
    where = self._where,
    group = self._group,
    having = self._having,
    order = self._order,
    limit = self._limit,
    offset = self._offset
  }
  if self._prepend then
    local res = {}
    for _, sql in ipairs(self._prepend) do
      if type(sql) == 'string' then
        res[#res + 1] = sql
      else
        res[#res + 1] = sql:statement()
      end
    end
    statement = table_concat(res, ';') .. ';' .. statement
  end
  if self._append then
    local res = {}
    for _, sql in ipairs(self._append) do
      if type(sql) == 'string' then
        res[#res + 1] = sql
      else
        res[#res + 1] = sql:statement()
      end
    end
    statement = statement .. ';' .. table_concat(res, ';')
  end
  return statement
end

---@param name string
---@param token? DBValue
---@return self
function Sql:with(name, token)
  local with_token = self:_get_with_token(name, token)
  if self._with then
    self._with = format("%s, %s", self._with, with_token)
  else
    self._with = with_token
  end
  return self
end

---@param name string
---@param token? DBValue
---@return self
function Sql:with_recursive(name, token)
  local with_token = self:_get_with_token(name, token)
  if self._with_recursive then
    self._with_recursive = format("%s, %s", self._with_recursive, with_token)
  else
    self._with_recursive = with_token
  end
  return self
end

---@param other_sql Sql
---@return self
function Sql:union(other_sql)
  return self:_handle_set_option(other_sql, "_union");
end

---@param other_sql Sql
---@return self
function Sql:union_all(other_sql)
  return self:_handle_set_option(other_sql, "_union_all");
end

---@param other_sql Sql
---@return self
function Sql:except(other_sql)
  return self:_handle_set_option(other_sql, "_except");
end

---@param other_sql Sql
---@return self
function Sql:except_all(other_sql)
  return self:_handle_set_option(other_sql, "_except_all");
end

---@param other_sql Sql
---@return self
function Sql:intersect(other_sql)
  return self:_handle_set_option(other_sql, "_intersect");
end

---@param other_sql Sql
---@return self
function Sql:intersect_all(other_sql)
  return self:_handle_set_option(other_sql, "_intersect_all");
end

---@param table_alias string
---@return self
function Sql:as(table_alias)
  self._as = table_alias
  return self
end

---@param name string
---@param rows Record[]
---@return self
function Sql:with_values(name, rows)
  local columns = get_keys_head(rows)
  rows, columns = self:_get_cte_values_literal(rows, columns, true)
  local cte_name = format("%s(%s)", name, table_concat(columns, ", "))
  local cte_values = format("(VALUES %s)", as_token(rows))
  return self:with(cte_name, cte_values)
end

---@param rows Record[]
---@param key Keys
---@return self|XodelInstance[]
function Sql:get_merge(rows, key)
  local columns = get_keys_head(rows)
  rows, columns = self:_get_cte_values_literal(rows, columns, true)
  local join_cond = self:_get_join_condition_from_key(key, "V", self._as or self.table_name)
  local cte_name = format("V(%s)", table_concat(columns, ", "))
  local cte_values = format("(VALUES %s)", as_token(rows))
  self:_base_select("V.*"):with(cte_name, cte_values):_base_join("RIGHT", "V", join_cond)
  return self
end

---@return self
function Sql:copy()
  local copy_sql = {}
  for key, value in pairs(self) do
    if type(value) == 'table' then
      copy_sql[key] = clone(value)
    else
      copy_sql[key] = value
    end
  end
  return setmetatable(copy_sql, getmetatable(self))
end

---@return self
function Sql:clear()
  local model = self.model
  local table_name = self.table_name
  local as = self._as
  table_clear(self)
  self.model = model
  self.table_name = table_name
  self._as = as
  return self
end

---@param cond? table|string|fun(ctx:table):string
---@param op? string
---@param dval? DBValue
---@return self
function Sql:delete(cond, op, dval)
  self._delete = true
  if cond ~= nil then
    self:where(cond, op, dval)
  end
  return self
end

---@return self
function Sql:distinct()
  self._distinct = true
  return self
end

---@param a (fun(ctx:table):string)|DBValue
---@param b? DBValue
---@param ...? DBValue
---@return self
function Sql:select(a, b, ...)
  local s = self:_get_select_token(a, b, ...)
  if s == "" then
  elseif not self._select then
    self._select = s
  else
    self._select = self._select .. ", " .. s
  end
  self:_keep_args("_select_args", a, b, ...)
  return self
end

---@param key string
---@param alias string
---@return self
function Sql:select_as(key, alias)
  local col = self:_parse_column(key, true, true) .. ' AS ' .. alias
  if not self._select then
    self._select = col
  else
    self._select = self._select .. ", " .. col
  end
  return self
end

---@param a DBValue
---@param b? DBValue
---@param ...? DBValue
---@return self
function Sql:select_literal(a, b, ...)
  local s = self:_get_select_literal(a, b, ...)
  if s == "" then
  elseif not self._select then
    self._select = s
  else
    self._select = self._select .. ", " .. s
  end
  self:_keep_args("_select_literal_args", a, b, ...)
  return self
end

---@param a (fun(ctx:table):string)|DBValue
---@param b? DBValue
---@param ...? DBValue
---@return self
function Sql:returning(a, b, ...)
  local s = self:_get_select_token(a, b, ...)
  if s == "" then
  elseif not self._returning then
    self._returning = s
  else
    self._returning = self._returning .. ", " .. s
  end
  self:_keep_args("_returning_args", a, b, ...)
  return self
end

---@param a DBValue
---@param b? DBValue
---@param ...? DBValue
---@return self
function Sql:returning_literal(a, b, ...)
  local s = self:_get_select_literal(a, b, ...)
  if s == "" then
  elseif not self._returning then
    self._returning = s
  else
    self._returning = self._returning .. ", " .. s
  end
  self:_keep_args("_returning_literal_args", a, b, ...)
  return self
end

---@param a (fun(ctx:table):string)|DBValue
---@param ... DBValue
function Sql:group(a, ...)
  local s = self:_get_select_token(a, ...)
  if s == "" then
  elseif not self._group then
    self._group = s
  else
    self._group = self._group .. ", " .. s
  end
  return self
end

function Sql:group_by(...) return self:group(...) end

---@param key DBValue
---@return DBValue
function Sql:_get_order_column(key)
  if type(key) ~= 'string' then
    return key
  else
    -- local matched = match(key, '^([-+])?([\\w_.]+)$', 'josui')
    local a, b = key:match("^([-+]?)([%w_]+)$")
    if a or b then
      return format("%s %s", self:_parse_column(b), a == '-' and 'DESC' or 'ASC')
    else
      error(format("invalid order arg format: %s", key))
    end
  end
end

---@param a DBValue
---@param b? DBValue
---@param ...? DBValue
---@return string
function Sql:_get_order_token(a, b, ...)
  if b == nil then
    if type(a) == "table" then
      local tokens = {}
      for i = 1, #a do
        tokens[i] = self:_get_order_column(a[i])
      end
      return as_token(tokens)
    elseif type(a) == "string" then
      return self:_get_order_column(a) --[[@as string]]
    else
      return as_token(a)
    end
  else
    local res = {}
    for i, name in ipairs { a, b, ... } do
      res[#res + 1] = as_token(self:_get_order_column(name))
    end
    return table_concat(res, ", ")
  end
end

---@param ...? DBValue
---@return self
function Sql:order(...)
  local s = self:_get_order_token(...)
  if s == "" then
  elseif not self._order then
    self._order = s
  else
    self._order = self._order .. ", " .. s
  end
  return self
end

function Sql:order_by(...) return self:order(...) end

---@param ... string
function Sql:using(...)
  return self:_base_using(...)
end

---@param ... string
---@return self
function Sql:from(...)
  local s = get_list_tokens(...)
  if s == "" then
  elseif not self._from then
    self._from = s
  else
    self._from = self._from .. ", " .. s
  end
  return self
end

---@return string
function Sql:get_table()
  if self._as then
    return self.table_name .. ' ' .. self._as
  else
    return self.table_name
  end
end

---@param join_args string|table
---@param key string
---@param op? string
---@param val? DBValue
---@return self
function Sql:join(join_args, key, op, val)
  return self:_base_join("INNER", join_args, key, op, val)
end

---@param join_args string|table
---@param key string
---@param op? string
---@param val? DBValue
---@return self
function Sql:inner_join(join_args, key, op, val)
  return self:_base_join("INNER", join_args, key, op, val)
end

---@param join_args string|table
---@param key string
---@param op? string
---@param val? DBValue
---@return self
function Sql:left_join(join_args, key, op, val)
  return self:_base_join("LEFT", join_args, key, op, val)
end

---@param join_args string|table
---@param key string
---@param op? string
---@param val? DBValue
---@return self
function Sql:right_join(join_args, key, op, val)
  return self:_base_join("RIGHT", join_args, key, op, val)
end

---@param join_args string|table
---@param key string
---@param op string
---@param val DBValue
---@return self
function Sql:full_join(join_args, key, op, val)
  return self:_base_join("FULL", join_args, key, op, val)
end

---@param join_args string|table
---@param key string
---@param op string
---@param val DBValue
---@return self
function Sql:cross_join(join_args, key, op, val)
  return self:_base_join("CROSS", join_args, key, op, val)
end

---@param n integer
---@return self
function Sql:limit(n)
  self._limit = n
  return self
end

---@param n integer
---@return self
function Sql:offset(n)
  self._offset = n
  return self
end

---@param cond table|string|fun(ctx:table):string
---@param op? string
---@param dval? DBValue
---@return self
function Sql:where(cond, op, dval)
  local where_token = self:_get_condition_token(cond, op, dval)
  return self:_handle_where_token(where_token, "(%s) AND (%s)")
end

local logic_priority = { ['init'] = 0, ['or'] = 1, ['and'] = 2, ['not'] = 3, ['OR'] = 1, ['AND'] = 2, ['NOT'] = 3 }

---@private
---@param cond table
---@param father_op string
---@return string
function Sql:_parse_where_exp(cond, father_op)
  local logic_op = cond[1]
  local tokens = {}
  for i = 2, #cond do
    local value = cond[i]
    if value[1] then
      tokens[#tokens + 1] = self:_parse_where_exp(value, logic_op)
    else
      for k, v in pairs(value) do
        tokens[#tokens + 1] = self:_get_expr_token(v, self:_parse_column(k))
      end
    end
  end
  local where_token
  if logic_op == 'not' or logic_op == 'NOT' then
    where_token = 'NOT ' .. table_concat(tokens, " AND NOT ")
  else
    where_token = table_concat(tokens, format(" %s ", logic_op))
  end

  if logic_priority[logic_op] < logic_priority[father_op] then
    return "(" .. where_token .. ")"
  else
    return where_token
  end
end

---@param cond table
---@return self
function Sql:where_exp(cond)
  local where_token = self:_parse_where_exp(cond, 'init')
  return self:_handle_where_token(where_token, "(%s) AND (%s)")
end

---@param cond table|string|fun(ctx:table):string
---@param op? string
---@param dval? DBValue
---@return self
function Sql:where_or(cond, op, dval)
  local where_token = self:_get_condition_token_or(cond, op, dval)
  return self:_handle_where_token(where_token, "(%s) AND (%s)")
end

---@param cond table|string|fun(ctx:table):string
---@param op? string
---@param dval? DBValue
---@return self
function Sql:or_where_or(cond, op, dval)
  local where_token = self:_get_condition_token_or(cond, op, dval)
  return self:_handle_where_token(where_token, "%s OR %s")
end

---@param cond table|string|fun(ctx:table):string
---@param op? string
---@param dval? DBValue
---@return self
function Sql:where_not(cond, op, dval)
  local where_token = self:_get_condition_token_not(cond, op, dval)
  return self:_handle_where_token(where_token, "(%s) AND (%s)")
end

---@param cond table|string|fun(ctx:table):string
---@param op? string
---@param dval? DBValue
---@return self
function Sql:or_where(cond, op, dval)
  local where_token = self:_get_condition_token(cond, op, dval)
  return self:_handle_where_token(where_token, "%s OR %s")
end

---@param cond table|string|fun(ctx:table):string
---@param op? string
---@param dval? DBValue
---@return self
function Sql:or_where_not(cond, op, dval)
  local where_token = self:_get_condition_token_not(cond, op, dval)
  return self:_handle_where_token(where_token, "%s OR %s")
end

---@param builder Sql|string
---@return self
function Sql:where_exists(builder)
  if self._where then
    self._where = format("(%s) AND EXISTS (%s)", self._where, builder)
  else
    self._where = format("EXISTS (%s)", builder)
  end
  return self
end

---@param builder Sql|string
---@return self
function Sql:where_not_exists(builder)
  if self._where then
    self._where = format("(%s) AND NOT EXISTS (%s)", self._where, builder)
  else
    self._where = format("NOT EXISTS (%s)", builder)
  end
  return self
end

---@param cols string|string[]
---@param range Sql|table|string
---@return self
function Sql:where_in(cols, range)
  if type(cols) == "string" then
    return Sql._base_where_in(self, self:_get_column(cols), range)
  else
    local res = {}
    for i = 1, #cols do
      res[i] = self:_get_column(cols[i])
    end
    return Sql._base_where_in(self, res, range)
  end
end

---@param cols string|string[]
---@param range Sql|table|string
---@return self
function Sql:where_not_in(cols, range)
  if type(cols) == "string" then
    cols = self:_get_column(cols)
  else
    for i = 1, #cols do
      cols[i] = self:_get_column(cols[i])
    end
  end
  return Sql._base_where_not_in(self, cols, range)
end

---@param col string
---@return self
function Sql:where_null(col)
  return Sql._base_where_null(self, self:_get_column(col))
end

---@param col string
---@return self
function Sql:where_not_null(col)
  return Sql._base_where_not_null(self, self:_get_column(col))
end

---@param col string
---@param low number
---@param high number
---@return self
function Sql:where_between(col, low, high)
  return Sql._base_where_between(self, self:_get_column(col), low, high)
end

---@param col string
---@param low number
---@param high number
---@return self
function Sql:where_not_between(col, low, high)
  return Sql._base_where_not_between(self, self:_get_column(col), low, high)
end

---@param cols string|string[]
---@param range Sql|table|string
---@return self
function Sql:or_where_in(cols, range)
  if type(cols) == "string" then
    cols = self:_get_column(cols)
    return Sql._base_or_where_in(self, cols, range)
  else
    local res = {}
    for i = 1, #cols do
      res[i] = self:_get_column(cols[i])
    end
    return Sql._base_or_where_in(self, res, range)
  end
end

---@param cols string|string[]
---@param range Sql|table|string
---@return self
function Sql:or_where_not_in(cols, range)
  if type(cols) == "string" then
    cols = self:_get_column(cols)
  else
    for i = 1, #cols do
      cols[i] = self:_get_column(cols[i])
    end
  end
  return Sql._base_or_where_not_in(self, cols, range)
end

---@param col string
---@return self
function Sql:or_where_null(col)
  return Sql._base_or_where_null(self, self:_get_column(col))
end

---@param col string
---@return self
function Sql:or_where_not_null(col)
  return Sql._base_or_where_not_null(self, self:_get_column(col))
end

---@param col string
---@param low number
---@param high number
---@return self
function Sql:or_where_between(col, low, high)
  return Sql._base_or_where_between(self, self:_get_column(col), low, high)
end

---@param col string
---@param low number
---@param high number
---@return self
function Sql:or_where_not_between(col, low, high)
  return Sql._base_or_where_not_between(self, self:_get_column(col), low, high)
end

---@param builder Sql
---@return self
function Sql:or_where_exists(builder)
  if self._where then
    self._where = format("%s OR EXISTS (%s)", self._where, builder)
  else
    self._where = format("EXISTS (%s)", builder)
  end
  return self
end

---@param builder Sql
---@return self
function Sql:or_where_not_exists(builder)
  if self._where then
    self._where = format("%s OR NOT EXISTS (%s)", self._where, builder)
  else
    self._where = format("NOT EXISTS (%s)", builder)
  end
  return self
end

---@param cond table|string|fun(ctx:table):string
---@param op? DBValue
---@param dval? DBValue
function Sql:having(cond, op, dval)
  if self._having then
    self._having = format("(%s) AND (%s)", self._having, self:_get_condition_token(cond, op, dval))
  else
    self._having = self:_get_condition_token(cond, op, dval)
  end
  return self
end

---@param cond table|string|fun(ctx:table):string
---@param op? DBValue
---@param dval? DBValue
function Sql:having_not(cond, op, dval)
  if self._having then
    self._having = format("(%s) AND (%s)", self._having, self:_get_condition_token_not(cond, op, dval))
  else
    self._having = self:_get_condition_token_not(cond, op, dval)
  end
  return self
end

---@param builder Sql
---@return self
function Sql:having_exists(builder)
  if self._having then
    self._having = format("(%s) AND EXISTS (%s)", self._having, builder)
  else
    self._having = format("EXISTS (%s)", builder)
  end
  return self
end

---@param builder Sql
---@return self
function Sql:having_not_exists(builder)
  if self._having then
    self._having = format("(%s) AND NOT EXISTS (%s)", self._having, builder)
  else
    self._having = format("NOT EXISTS (%s)", builder)
  end
  return self
end

---@param cols string|string[]
---@param range Sql|table|string
---@return self
function Sql:having_in(cols, range)
  local in_token = self:_get_in_token(cols, range)
  if self._having then
    self._having = format("(%s) AND %s", self._having, in_token)
  else
    self._having = in_token
  end
  return self
end

---@param cols string|string[]
---@param range Sql|table|string
---@return self
function Sql:having_not_in(cols, range)
  local not_in_token = self:_get_in_token(cols, range, "NOT IN")
  if self._having then
    self._having = format("(%s) AND %s", self._having, not_in_token)
  else
    self._having = not_in_token
  end
  return self
end

---@param col string
---@return self
function Sql:having_null(col)
  if self._having then
    self._having = format("(%s) AND %s IS NULL", self._having, col)
  else
    self._having = col .. " IS NULL"
  end
  return self
end

---@param col string
---@return self
function Sql:having_not_null(col)
  if self._having then
    self._having = format("(%s) AND %s IS NOT NULL", self._having, col)
  else
    self._having = col .. " IS NOT NULL"
  end
  return self
end

---@param col string
---@param low number
---@param high number
---@return self
function Sql:having_between(col, low, high)
  if self._having then
    self._having = format("(%s) AND (%s BETWEEN %s AND %s)", self._having, col, low, high)
  else
    self._having = format("%s BETWEEN %s AND %s", col, low, high)
  end
  return self
end

---@param col string
---@param low number
---@param high number
---@return self
function Sql:having_not_between(col, low, high)
  if self._having then
    self._having = format("(%s) AND (%s NOT BETWEEN %s AND %s)", self._having, col, low, high)
  else
    self._having = format("%s NOT BETWEEN %s AND %s", col, low, high)
  end
  return self
end

---@param cond table|string|fun(ctx:table):string
---@param op? DBValue
---@param dval? DBValue
function Sql:or_having(cond, op, dval)
  if self._having then
    self._having = format("%s OR %s", self._having, self:_get_condition_token(cond, op, dval))
  else
    self._having = self:_get_condition_token(cond, op, dval)
  end
  return self
end

---@param cond table|string|fun(ctx:table):string
---@param op? DBValue
---@param dval? DBValue
function Sql:or_having_not(cond, op, dval)
  if self._having then
    self._having = format("%s OR %s", self._having, self:_get_condition_token_not(cond, op, dval))
  else
    self._having = self:_get_condition_token_not(cond, op, dval)
  end
  return self
end

---@param builder Sql
---@return self
function Sql:or_having_exists(builder)
  if self._having then
    self._having = format("%s OR EXISTS (%s)", self._having, builder)
  else
    self._having = format("EXISTS (%s)", builder)
  end
  return self
end

---@param builder Sql
---@return self
function Sql:or_having_not_exists(builder)
  if self._having then
    self._having = format("%s OR NOT EXISTS (%s)", self._having, builder)
  else
    self._having = format("NOT EXISTS (%s)", builder)
  end
  return self
end

---@param cols string|string[]
---@param range Sql|table|string
---@return self
function Sql:or_having_in(cols, range)
  local in_token = self:_get_in_token(cols, range)
  if self._having then
    self._having = format("%s OR %s", self._having, in_token)
  else
    self._having = in_token
  end
  return self
end

---@param cols string|string[]
---@param range Sql|table|string
---@return self
function Sql:or_having_not_in(cols, range)
  local not_in_token = self:_get_in_token(cols, range, "NOT IN")
  if self._having then
    self._having = format("%s OR %s", self._having, not_in_token)
  else
    self._having = not_in_token
  end
  return self
end

---@param col string
---@return self
function Sql:or_having_null(col)
  if self._having then
    self._having = format("%s OR %s IS NULL", self._having, col)
  else
    self._having = col .. " IS NULL"
  end
  return self
end

---@param col string
---@return self
function Sql:or_having_not_null(col)
  if self._having then
    self._having = format("%s OR %s IS NOT NULL", self._having, col)
  else
    self._having = col .. " IS NOT NULL"
  end
  return self
end

---@param col string
---@param low number
---@param high number
---@return self
function Sql:or_having_between(col, low, high)
  if self._having then
    self._having = format("%s OR (%s BETWEEN %s AND %s)", self._having, col, low, high)
  else
    self._having = format("%s BETWEEN %s AND %s", col, low, high)
  end
  return self
end

---@param col string
---@param low number
---@param high number
---@return self
function Sql:or_having_not_between(col, low, high)
  if self._having then
    self._having = format("%s OR (%s NOT BETWEEN %s AND %s)", self._having, col, low, high)
  else
    self._having = format("%s NOT BETWEEN %s AND %s", col, low, high)
  end
  return self
end

---@param a (fun(ctx:table):string)|DBValue
---@param b? DBValue
---@param ...? DBValue
---@return self
function Sql:distinct_on(a, b, ...)
  local s = self:_get_select_token(a, b, ...)
  self._distinct_on = s
  self._order = s
  return self
end

---@param name string
---@param amount? number
---@return self
function Sql:increase(name, amount)
  return self:update { [name] = self.token(format("%s + %s", name, amount or 1)) }
end

---@param name string
---@param amount? number
---@return self
function Sql:decrease(name, amount)
  return self:update { [name] = self.token(format("%s - %s", name, amount or 1)) }
end

--- {{id=1}, {id=2}, {id=3}} => columns: {'id'}  keys: {{1},{2},{3}}
--- each row of keys must be the same struct, so get columns from first row

---@param keys Record[]
---@param columns? string[]
---@return self
function Sql:_base_get_multiple(keys, columns)
  if #keys == 0 then
    error("empty keys passed to get_multiple")
  end
  columns = columns or get_keys(keys[1])
  keys, columns = self:_get_cte_values_literal(keys, columns, false)
  local join_cond = self:_get_join_condition_from_key(columns, "V", self._as or self.table_name)
  local cte_name = format("V(%s)", table_concat(columns, ", "))
  local cte_values = format("(VALUES %s)", as_token(keys))
  return self:with(cte_name, cte_values):right_join("V", join_cond)
end

---@param rows Record[]
---@param columns? string[]
---@param no_check? boolean
---@return string[], string[]
function Sql:_get_cte_values_literal(rows, columns, no_check)
  -- {{a=1,b=2}, {a=3,b=4}} => {"(1, 2)", "(3, 4)"}, {'a','b'}
  columns = columns or get_keys_head(rows)
  rows = self:_rows_to_array(rows, columns)
  local first_row = rows[1]
  for i, col in ipairs(columns) do
    local field = self:_find_field_model(col)
    if field then
      first_row[i] = format("%s::%s", as_literal(first_row[i]), field.db_type)
    elseif no_check then
      first_row[i] = as_literal(first_row[i])
    else
      error("invalid field name: " .. col)
    end
  end
  ---@type string[]
  local res = {}
  res[1] = '(' .. as_token(first_row) .. ')'
  for i = 2, #rows, 1 do
    res[i] = as_literal(rows[i])
  end
  return res, columns
end

---@param col string
---@return AnyField?, Xodel?,string?
function Sql:_find_field_model(col)
  local field = self.model.fields[col]
  if field then
    return field, self.model, self._as or self.table_name
  end
end

---@param key string user input
---@param as_select? boolean return one string (column with prefix) if true, otherwise return column, operator and
---@param disable_alias? boolean whether disable alias token
---@return string, string?, string?, Xodel?
---@overload fun(self, key: string, as_select?: boolean, disable_alias?: boolean): string, string, string, Xodel
function Sql:_parse_column(key, as_select, disable_alias)
  --TODO: support json field searching like django:
  -- https://docs.djangoproject.com/en/4.2/topics/db/queries/#querying-jsonfield
  -- https://www.postgresql.org/docs/current/functions-json.html
  local a, b = key:find("__", 1, true)
  if not a then
    if as_select then
      return self:_get_column(key)
    else
      return self:_get_column(key), "eq", key, self.model
    end
  end
  local token = key:sub(1, a - 1)
  local field, model, prefix = self:_find_field_model(token)
  if not field then
    error(format("%s is not a valid field name for %s", token, self.table_name))
  end
  ---@cast model Xodel
  local i, fk_model, join_key, op
  local field_name = token
  while true do
    -- get next token seprated by __
    i = b + 1
    a, b = key:find("__", i, true)
    if not a then
      token = key:sub(i)
    else
      token = key:sub(i, a - 1)
    end
    if field.reference then
      fk_model = field.reference
      local fk_model_field = fk_model.fields[token]
      if not fk_model_field then
        -- fk__eq, compare on fk value directly
        op = token
        break
      elseif token == field.reference_column then
        -- fk__id, unnecessary suffix, ignore
        break
      else
        -- fk__name, need inner join
        if not join_key then
          -- prefix with field_name because fk_model can be referenced multiple times
          join_key = field_name
        else
          join_key = join_key .. "__" .. field_name
        end
        if not self._join_keys then
          self._join_keys = {}
        end
        local alias = self._join_keys[join_key]
        if not alias then
          prefix = self:_handle_manual_join(
            "INNER",
            { field.reference },
            function(ctx)
              return format("%s = %s",
                ctx[model.table_name][field_name],
                ctx[field.reference.table_name][field.reference_column])
            end,
            join_key)
        else
          prefix = alias
        end
        field = fk_model_field
        model = fk_model --[[@as Xodel]]
        field_name = token
      end
    elseif field.model then
      -- jsonb field: persons__sfzh='xxx' => persons @> '[{"sfzh":"xxx"}]'
      local table_field = field.model.fields[token]
      if not table_field then
        error(format("invalid table field name %s of %s", token, field.name))
      end
      op = function(value)
        if type(value) == 'string' and value:find("'", 1, true) then
          value = value:gsub("'", "''")
        end
        return format([[@> '[{"%s":%s}]']], token, encode(value))
      end
      break
    else
      -- non_fk__lt, non_fk__gt, etc
      op = token
      break
    end
    if not a then
      break
    end
  end
  local final_key = prefix .. "." .. field_name
  if as_select and not disable_alias then
    -- ensure select("fk__name") will return { fk__name= 'foo'}
    -- in case of error like Profile:select('usr_id__eq')
    assert(fk_model, format("should contains foreignkey field name: %s", key))
    assert(op == nil, format("invalid field name: %s", op))
    return final_key .. ' AS ' .. key
  else
    return final_key, op or 'eq', field_name, model
  end
end

---@param key string
---@return string
function Sql:_get_column(key)
  if self.model.fields[key] then
    if self._as then
      return self._as .. '.' .. key
    else
      return self.model.name_cache[key]
    end
  end
  if key == '*' then
    return '*'
  end
  -- local matched = match(key, '^([\\w_]+)[.]([\\w_]+)$', 'josui')
  local table_name = key:match('^([%w_]+)[.][%w_]+$')
  if table_name then
    return key
  end
  error(format("invalid field name: '%s'", key))
end

local string_db_types = {
  varchar = true,
  text = true,
  char = true,
  bpchar = true
}
local string_operators = {
  contains = true,
  startswith = true,
  endswith = true,
  regex = true,
  regex_insensitive = true,
  regex_sensitive = true,
}

---@param value DBValue
---@param key string
---@param op string
---@param raw_key string
---@param model? Xodel
---@return string
function Sql:_get_expr_token(value, key, op, raw_key, model)
  local field = (model or self.model).fields[raw_key]
  if field and not string_db_types[field.db_type] and string_operators[op] then
    key = key .. '::varchar'
  end
  if op == "eq" then
    return format("%s = %s", key, as_literal(value))
  elseif op == "in" then
    return format("%s IN %s", key, as_literal(value))
  elseif op == "notin" then
    return format("%s NOT IN %s", key, as_literal(value))
  elseif COMPARE_OPERATORS[op] then
    return format("%s %s %s", key, COMPARE_OPERATORS[op], as_literal(value))
  elseif op == "contains" then
    ---@cast value string
    return format("%s LIKE '%%%s%%'", key, value:gsub("'", "''"))
  elseif op == "startswith" then
    ---@cast value string
    return format("%s LIKE '%s%%'", key, value:gsub("'", "''"))
  elseif op == "endswith" then
    ---@cast value string
    return format("%s LIKE '%%%s'", key, value:gsub("'", "''"))
  elseif op == "regex" or op == "regex_sensitive" then
    ---@cast value string
    return format("%s ~ '%%%s'", key, value:gsub("'", "''"))
  elseif op == "regex_insensitive" then
    ---@cast value string
    return format("%s ~* '%%%s'", key, value:gsub("'", "''"))
  elseif op == "null" then
    if value then
      return format("%s IS NULL", key)
    else
      return format("%s IS NOT NULL", key)
    end
  elseif type(op) == 'function' then
    return format("%s %s", key, op(value))
  else
    error("invalid sql op: " .. tostring(op))
  end
end

---@param rows Records|Sql
---@param columns? string[]
---@return self
function Sql:insert(rows, columns)
  if not rows.__SQL_BUILDER__ then
    ---@cast rows Records
    if not self._skip_validate then
      ---@diagnostic disable-next-line: cast-local-type
      rows, columns = self.model:validate_create_data(rows, columns)
      if rows == nil then
        error(columns)
      end
    end
    ---@diagnostic disable-next-line: cast-local-type, param-type-mismatch
    rows, columns = self.model:prepare_db_rows(rows, columns)
    if rows == nil then
      error(columns)
    end
    ---@diagnostic disable-next-line: param-type-mismatch
    return Sql._base_insert(self, rows, columns)
  else
    ---@cast rows Sql
    return Sql._base_insert(self, rows, columns)
  end
end

---@param row Record|Sql|string
---@param columns? string[]
---@return self
function Sql:update(row, columns)
  if type(row) == 'string' then
    return Sql._base_update(self, row)
  elseif not row.__SQL_BUILDER__ then
    local err
    ---@cast row Record
    if not self._skip_validate then
      ---@diagnostic disable-next-line: cast-local-type
      row, err = self.model:validate_update(row, columns)
      if row == nil then
        error(err)
      end
    end
    ---@diagnostic disable-next-line: cast-local-type
    row, columns = self.model:prepare_db_rows(row, columns, true)
    if row == nil then
      error(columns)
    end
    ---@diagnostic disable-next-line: param-type-mismatch
    return Sql._base_update(self, row, columns)
  else
    ---@cast row Sql
    return Sql._base_update(self, row, columns)
  end
end

function Sql:_get_bulk_key(columns)
  if self.model.unique_together and self.model.unique_together[1] then
    return self.model.unique_together[1]
  end
  for index, name in ipairs(columns) do
    local f = self.model.fields[name]
    if f and f.unique then
      return name
    end
  end
  local pk = self.model.primary_key
  if pk and Array.includes(columns, pk) then
    return pk
  end
  return pk
end

function Sql:_clean_bulk_params(rows, key, columns)
  if isempty(rows) then
    error("empty rows passed to merge")
  end
  if not rows[1] then
    rows = { rows }
  end
  if columns == nil then
    columns = {}
    for k, _ in pairs(rows[1]) do
      if self.model.fields[k] then
        columns[#columns + 1] = k
      end
    end
    if #columns == 0 then
      error("no columns provided for bulk")
    end
  end
  if key == nil then
    key = self:_get_bulk_key(columns)
  end
  if type(key) == 'string' then
    if not Array.includes(columns, key) then
      columns = { key, unpack(columns) }
    end
  elseif type(key) == 'table' then
    for _, k in ipairs(key) do
      if not Array.includes(columns, k) then
        columns = { k, unpack(columns) }
      end
    end
  else
    error("invalid key type for bulk:" .. type(key))
  end
  return rows, key, columns
end

---@param rows Record[]
---@param key? Keys
---@param columns? string[]
---@return self
function Sql:merge(rows, key, columns)
  rows, key, columns = self:_clean_bulk_params(rows, key, columns)
  if not self._skip_validate then
    ---@diagnostic disable-next-line: cast-local-type
    rows, key, columns = self.model:validate_create_rows(rows, key, columns)
    if rows == nil then
      error(key)
    end
  end
  ---@diagnostic disable-next-line: cast-local-type, param-type-mismatch
  rows, columns = self.model:prepare_db_rows(rows, columns, false)
  if rows == nil then
    error(columns)
  end
  ---@diagnostic disable-next-line: param-type-mismatch
  return Sql._base_merge(self, rows, key, columns)
end

---@param rows Record[]
---@param key? Keys
---@param columns? string[]
---@return self
function Sql:upsert(rows, key, columns)
  rows, key, columns = self:_clean_bulk_params(rows, key, columns)
  if not self._skip_validate then
    ---@diagnostic disable-next-line: cast-local-type
    rows, key, columns = self.model:validate_create_rows(rows, key, columns)
    if rows == nil then
      error(key)
    end
  end
  ---@diagnostic disable-next-line: cast-local-type, param-type-mismatch
  rows, columns = self.model:prepare_db_rows(rows, columns, false)
  if rows == nil then
    error(columns)
  end
  ---@diagnostic disable-next-line: param-type-mismatch
  return Sql._base_upsert(self, rows, key, columns)
end

---@param rows Record[]
---@param key? Keys
---@param columns? string[]
---@return self
function Sql:updates(rows, key, columns)
  rows, key, columns = self:_clean_bulk_params(rows, key, columns)
  if not self._skip_validate then
    ---@diagnostic disable-next-line: cast-local-type
    rows, key, columns = self.model:validate_update_rows(rows, key, columns)
    if rows == nil then
      error(columns)
    end
  end
  ---@diagnostic disable-next-line: cast-local-type, param-type-mismatch
  rows, columns = self.model:prepare_db_rows(rows, columns, true)
  if rows == nil then
    error(columns)
  end
  ---@diagnostic disable-next-line: param-type-mismatch
  return Sql._base_updates(self, rows, key, columns)
end

---@param keys Record[]
---@param columns string[]
---@return self
function Sql:get_multiple(keys, columns)
  return Sql._base_get_multiple(self, keys, columns)
end

---@param statement string
---@return Array<XodelInstance>, table?
function Sql:exec_statement(statement)
  local records = assert(self.model.query(statement, self._compact))
  local multiple_records
  if self._prepend then
    multiple_records = records
    records = records[#self._prepend + 1]
  elseif self._append then
    multiple_records = records
    records = records[1]
  end
  if (self._raw or self._raw == nil) or self._compact or self._update or self._insert or self._delete then
    if (self._update or self._insert or self._delete) and self._returning then
      records.affected_rows = nil
    end
    ---@cast records Array<Record>
    return setmetatable(records, Array), multiple_records
  else
    ---@type Xodel
    local cls = self.model
    if not self._load_fk then
      for i, record in ipairs(records) do
        records[i] = cls:load(record)
      end
    else
      ---@type {[string]:AnyField}
      local fields = cls.fields
      local field_names = cls.field_names
      for i, record in ipairs(records) do
        for _, name in ipairs(field_names) do
          local field = fields[name]
          local value = record[name]
          if value ~= nil then
            local fk_model = self._load_fk[name]
            if not fk_model then
              if not field.load then
                record[name] = value
              else
                ---@cast field ForeignkeyField|AliossField|TableField
                record[name] = field:load(value)
              end
            else
              -- _load_fk means reading attributes of a foreignkey,
              -- so the on-demand reading mode of foreignkey_db_to_lua_validator is not proper here
              record[name] = fk_model:load(get_foreign_object(record, name .. "__"))
            end
          end
        end
        records[i] = cls:create_record(record)
      end
    end
    ---@cast records Array<XodelInstance>
    return setmetatable(records, Array), multiple_records
  end
end

---@return Array<XodelInstance>, table?
function Sql:exec()
  return self:exec_statement(self:statement())
end

---@param cond? table|string|fun(ctx:table):string
---@param op? string
---@param dval? DBValue
---@return integer
function Sql:count(cond, op, dval)
  local res, err
  if cond ~= nil then
    res = self:_base_select("count(*)"):where(cond, op, dval):compact():exec()
  else
    res = self:_base_select("count(*)"):compact():exec()
  end
  if res and res[1] then
    return res[1][1]
  else
    return 0
  end
end

---@param rows Records|Sql
---@param columns? string[]
---@return self
function Sql:create(rows, columns)
  return self:insert(rows, columns):execr()
end

---@return boolean
function Sql:exists()
  local statement = format("SELECT EXISTS (%s)", self:select(1):limit(1):compact():statement())
  local res, err = self.model.query(statement, self._compact)
  if res == nil then
    error(err)
  else
    return res[1][1]
  end
end

---@return self
function Sql:compact()
  self._compact = true
  return self
end

---@param is_raw? boolean
---@return self
function Sql:raw(is_raw)
  if is_raw == nil or is_raw then
    self._raw = true
  else
    self._raw = false
  end
  return self
end

---deprecated
---@param bool boolean
---@return self
function Sql:commit(bool)
  if bool == nil then
    bool = true
  end
  self._commit = bool
  return self
end

---deprecated
---@param jtype string
---@return self
function Sql:join_type(jtype)
  self._join_type = jtype
  return self
end

---@param bool? boolean
---@return self
function Sql:skip_validate(bool)
  if bool == nil then
    bool = true
  end
  self._skip_validate = bool
  return self
end

---@param col? (fun(ctx:table):string)|string
---@return Record[]
function Sql:flat(col)
  if col then
    if self._update or self._delete or self._insert then
      return self:returning(col):compact():execr():flat()
    else
      return self:select(col):compact():execr():flat()
    end
  else
    return self:compact():execr():flat()
  end
end

---@param cond? table|string|fun(ctx:table):string
---@param op? string
---@param dval? DBValue
---@return XodelInstance?, number?
function Sql:try_get(cond, op, dval)
  if self._raw == nil then
    self._raw = false
  end
  local records
  if cond ~= nil then
    if type(cond) == 'table' and next(cond) == nil then
      error("empty condition table is not allowed")
    end
    records = self:where(cond, op, dval):limit(2):exec()
  else
    records = self:limit(2):exec()
  end
  if #records == 1 then
    return records[1]
  else
    return nil, #records
  end
end

---@param cond? table|string|fun(ctx:table):string
---@param op? string
---@param dval? DBValue
---@return XodelInstance
function Sql:get(cond, op, dval)
  local record, record_number = self:try_get(cond, op, dval)
  if not record then
    if record_number == 0 then
      error("record not found")
    else
      error("multiple records returned: " .. record_number)
    end
  else
    return record
  end
end

---@return Set
function Sql:as_set()
  return self:compact():execr():flat():as_set()
end

---@return table|Array<Record>
function Sql:execr()
  return self:raw():exec()
end

---@param names? string[] select names for load_fk_labels
---@return self
function Sql:load_fk_labels(names)
  for i, name in ipairs(names or self.model.names) do
    local field = self.model.fields[name]
    if field and field.type == 'foreignkey' and field.reference_label_column ~= field.reference_column then
      self:load_fk(field.name, field.reference_label_column)
    end
  end
  return self
end

---@param fk_name string
---@param select_names string[]|string
---@param ... string
---@return self
function Sql:load_fk(fk_name, select_names, ...)
  -- psr:load_fk('parent_id', '*')
  -- psr:load_fk('parent_id', 'usr_id')
  -- psr:load_fk('parent_id', {'usr_id'})
  -- psr:load_fk('parent_id', 'usr_id__xm')
  local fk = self.model.foreign_keys[fk_name]
  if fk == nil then
    error(fk_name .. " is not a valid forein key name for " .. self.table_name)
  end
  local fk_model = fk.reference
  if not self._load_fk then
    self._load_fk = {}
  end
  self._load_fk[fk_name] = fk_model
  self:select(fk_name)
  if not select_names then
    return self
  end
  local fks = {}
  if type(select_names) == 'table' then
    for _, fkn in ipairs(select_names) do
      fks[#fks + 1] = format("%s__%s", fk_name, fkn)
    end
  elseif select_names == '*' then
    for i, fkn in ipairs(fk_model.field_names) do
      fks[#fks + 1] = format("%s__%s", fk_name, fkn)
    end
  elseif type(select_names) == 'string' then
    for i, fkn in ipairs({ select_names, ... }) do
      fks[#fks + 1] = format("%s__%s", fk_name, fkn)
    end
  else
    error(format("invalid argument type %s for load_fk", type(select_names)))
  end
  return self:select(fks)
end

-- WITH RECURSIVE
--   branch_recursive AS (
--     SELECT
--       branch.id,
--       branch.name,
--       branch.pid
--     FROM
--       branch
--     WHERE
--       branch.pid = 1
--     UNION ALL
--     (
--       SELECT
--         branch.id,
--         branch.name,
--         branch.pid
--       FROM
--         branch
--         INNER JOIN branch_recursive ON (branch.pid = branch_recursive.id)
--     )
--   )
-- SELECT
--   branch.id,
--   branch.name,
--   branch.pid
-- FROM
--   branch_recursive AS branch;


---@param name string
---@param value any
---@param select_names? string[]
---@return self
function Sql:where_recursive(name, value, select_names)
  local fk = self.model.foreign_keys[name]
  if fk == nil then
    error(name .. " is not a valid forein key name for " .. self.table_name)
  end
  local fkc = fk.reference_column
  local table_name = self.model.table_name
  local t_alias = table_name .. '_recursive'
  local seed_sql = self.model:create_sql():select(fkc, name):where(name, value)
  local join_cond = format("%s.%s = %s.%s", table_name, name, t_alias, fkc)
  local recursive_sql = self.model:create_sql():select(fkc, name):_base_join('INNER', t_alias, join_cond)
  if select_names then
    seed_sql:select(select_names)
    recursive_sql:select(select_names)
  end
  self:with_recursive(t_alias, seed_sql:union_all(recursive_sql))
  return self:from(t_alias .. ' AS ' .. table_name)
end

-- Model defination
local base_model = {
  abstract = true,
  field_names = Array { DEFAULT_PRIMARY_KEY, "ctime", "utime" },
  fields = {
    [DEFAULT_PRIMARY_KEY] = { type = "integer", primary_key = true, serial = true },
    ctime = { label = "创建时间", type = "datetime", auto_now_add = true },
    utime = { label = "更新时间", type = "datetime", auto_now = true }
  }
}

local function disable_setting_model_attrs(cls, key, value)
  error(string_format("modify model class '%s' is not allowed (key: %s, value: %s)", cls.table_name, key, value))
end

local function list(a, b)
  local t = clone(a)
  if b then
    for _, v in ipairs(b) do
      t[#t + 1] = v
    end
  end
  return t
end

local function dict(t1, t2)
  local res = clone(t1)
  if t2 then
    for key, value in pairs(t2) do
      res[key] = value
    end
  end
  return res
end

local API_TABLE_NAMES = {
  T = true,
  D = true,
  U = true,
  V = true,
}
local function check_reserved(name)
  assert(type(name) == "string", string_format("name must be string, not %s (%s)", type(name), name))
  assert(not name:find("__", 1, true), "don't use __ in a table or column name")
  assert(not IS_PG_KEYWORDS[name:upper()],
    string_format("%s is a postgresql reserved word, can't be used as a table or column name", name))
  assert(not API_TABLE_NAMES[name], "don't use " .. name .. " as a table or column name")
end

local function is_field_class(t)
  return type(t) == 'table' and getmetatable(t) and getmetatable(t).__is_field_class__
end

local function ensure_field_as_options(field, name)
  if is_field_class(field) then
    field = field:get_options()
  else
    field = normalize_field_shortcuts(field)
  end
  if name then
    field.name = name
  end
  assert(field.name, "you must define a name for a field")
  return field
end

local function normalize_field_names(field_names)
  assert(type(field_names) == "table", "you must provide field_names for a model")
  for _, name in ipairs(field_names) do
    assert(type(name) == 'string', string_format("field_names must be string, not %s", type(name)))
  end
  return Array(field_names)
end

---@param row any
---@return boolean
local function is_sql_instance(row)
  local meta = getmetatable(row)
  return meta and meta.__SQL_BUILDER__
end

---@param ModelClass Xodel
local function make_record_meta(ModelClass)
  local RecordClass = dict(Object, {})

  RecordClass.__index = RecordClass

  function RecordClass.__call(self, data)
    for k, v in pairs(data) do
      self[k] = v
    end
    return self
  end

  function RecordClass.delete(self, key)
    key = ModelClass:check_unique_key(key or ModelClass.primary_key)
    if self[key] == nil then
      error("empty value for delete key:" .. key)
    end
    return ModelClass:create_sql():delete { [key] = self[key] }:returning(key):exec()
  end

  function RecordClass.save(self, names, key)
    return ModelClass:save(self, names, key)
  end

  function RecordClass.save_create(self, names, key)
    return ModelClass:save_create(self, names, key)
  end

  function RecordClass.save_update(self, names, key)
    return ModelClass:save_update(self, names, key)
  end

  function RecordClass.validate(self, names, key)
    return ModelClass:validate(self, names, key)
  end

  function RecordClass.validate_update(self, names)
    return ModelClass:validate_update(self, names)
  end

  function RecordClass.validate_create(self, names)
    return ModelClass:validate_create(self, names)
  end

  return RecordClass -- setmetatable(RecordClass, model)
end

local function create_model_proxy(ModelClass)
  local proxy = {}
  local function __index(_, k)
    local sql_k = Sql[k]
    if sql_k ~= nil then
      if type(sql_k) == 'function' then
        return function(_, ...)
          return sql_k(ModelClass:create_sql(), ...)
        end
      else
        return sql_k
      end
    end
    local model_k = ModelClass[k]
    if model_k ~= nil then
      if type(model_k) == 'function' then
        return function(cls, ...)
          if cls == proxy then
            return model_k(ModelClass, ...)
          elseif k == 'query' then
            -- ModelClass.query(statement, compact?), cls is statement in this case
            return model_k(cls, ...)
          else
            error(string_format("calling model proxy method `%s` with first argument not being itself is not allowed", k))
          end
        end
      else
        return model_k
      end
    else
      return nil
    end
  end
  local function __newindex(t, k, v)
    ModelClass[k] = v
  end

  return setmetatable(proxy, {
    __call = ModelClass.create_record,
    __index = __index,
    __newindex = __newindex
  })
end

---@class Xodel:Sql
---@operator call:Xodel
---@field private __index Xodel
---@field private __normalized__? boolean
---@field __is_model_class__? boolean
---@field private __SQL_BUILDER__? boolean
---@field DEFAULT  fun():'DEFAULT'
---@field NULL  userdata
---@field db_options? QueryOpts
---@field as_token  fun(DBValue):string
---@field as_literal  fun(DBValue):string
---@field RecordClass table
---@field extends? table
---@field admin? table
---@field table_name string
---@field class_name string
---@field referenced_label_column? string
---@field preload? boolean
---@field label string
---@field fields {[string]:AnyField}
---@field field_names Array
---@field mixins? table[]
---@field abstract? boolean
---@field auto_primary_key? boolean
---@field primary_key string
---@field unique_together? string[]|string[][]
---@field names Array
---@field auto_now_name string
---@field auto_now_add_name string
---@field foreign_keys table
---@field name_cache {[string]:string}
---@field clean? function
---@field name_to_label {[string]:string}
---@field label_to_name {[string]:string}
local Xodel = {
  __SQL_BUILDER__ = true,
  query = default_query,
  DEFAULT_PRIMARY_KEY = DEFAULT_PRIMARY_KEY,
  NULL = NULL,
  token = Sql.token,
  DEFAULT = Sql.DEFAULT,
  as_token = Sql.as_token,
  as_literal = Sql.as_literal,
}
setmetatable(Xodel, {
  __call = function(t, ...)
    return t:mix_with_base(...)
  end
})

Xodel.__index = Xodel

---@param cls Xodel
---@param attrs? table
---@return Xodel
function Xodel.new(cls, attrs)
  return setmetatable(attrs or {}, cls)
end

---@class ModelOpts
---@field private __normalized__? boolean
---@field extends? table
---@field mixins? table[]
---@field abstract? boolean
---@field admin? table
---@field table_name? string
---@field class_name? string
---@field label? string
---@field fields? {[string]:table}
---@field field_names? Array
---@field auto_primary_key? boolean
---@field primary_key? string
---@field unique_together? string[]|string[][]
---@field db_options? QueryOpts
---@field referenced_label_column? string
---@field preload? boolean

---@param cls Xodel
---@param options ModelOpts
---@return Xodel
function Xodel.create_model(cls, options)
  return cls:_make_model_class(cls:normalize(options))
end

---@param cls Xodel
---@param options {[string]:any}
---@return AnyField
function Xodel.make_field_from_json(cls, options)
  assert(not options[1])
  assert(options.name, "no name provided")
  if not options.type then
    if options.reference then
      options.type = "foreignkey"
    elseif options.model then
      options.type = "table"
    else
      options.type = "string"
    end
  end
  if (options.type == "string" or options.type == "alioss") and not options.maxlength then
    options.maxlength = DEFAULT_STRING_MAXLENGTH
  end
  ---@type AnyField
  local fcls = Fields[options.type]
  if not fcls then
    error("invalid field type:" .. tostring(options.type))
  end
  local res = fcls:create_field(options)
  res.get_model = function() return cls end
  return res
end

---@param cls Xodel
---@return Sql
function Xodel.create_sql(cls)
  return Sql:new { model = cls, table_name = cls.table_name }:as('T')
end

---@param cls Xodel
---@param rows? table[]
---@return Sql
function Xodel.create_sql_as(cls, table_name, rows)
  local alias_sql = Sql:new { model = cls, table_name = table_name }:as(table_name)
  if rows then
    return alias_sql:with_values(table_name, rows)
  else
    return alias_sql
  end
end

---@param cls Xodel
---@param model any
---@return boolean
function Xodel.is_model_class(cls, model)
  return type(model) == 'table' and model.__is_model_class__
end

---@param cls Xodel
---@param name string
function Xodel.check_field_name(cls, name)
  check_reserved(name);
  if (cls[name] ~= nil) then
    error(string_format("field name '%s' conflicts with model class attributes", name))
  end
end

---@private
---@param cls Xodel
---@param opts ModelOpts
---@return Xodel
function Xodel._make_model_class(cls, opts)
  local ModelClass = dict(cls, {
    table_name = opts.table_name,
    class_name = opts.class_name,
    admin = opts.admin or {},
    label = opts.label or opts.table_name,
    fields = opts.fields,
    field_names = opts.field_names,
    mixins = opts.mixins,
    extends = opts.extends,
    abstract = opts.abstract,
    primary_key = opts.primary_key,
    unique_together = opts.unique_together,
    referenced_label_column = opts.referenced_label_column,
    preload = opts.preload,
  })
  if ModelClass.preload == nil then
    ModelClass.preload = true
  end
  if opts.db_options then
    ModelClass.query = Query(opts.db_options)
  elseif cls.db_options then
    ModelClass.query = Query(cls.db_options)
  else
    ModelClass.query = default_query
  end
  ModelClass.__index = ModelClass
  local pk_defined = false
  ModelClass.foreign_keys = {}
  ModelClass.names = Array {}
  for _, name in ipairs(ModelClass.field_names) do
    local field = ModelClass.fields[name]
    if field.primary_key then
      local pk_name = field.name
      assert(not pk_defined, string_format('duplicated primary key: "%s" and "%s"', pk_name, pk_defined))
      pk_defined = pk_name
      ModelClass.primary_key = pk_name
      if not field.serial then
        ModelClass.names:push(pk_name)
      end
    elseif field.auto_now then
      ModelClass.auto_now_name = field.name
    elseif field.auto_now_add then
      ModelClass.auto_now_add_name = field.name
    else
      ModelClass.names:push(name)
    end
  end
  -- move to resolve_self_foreignkey
  -- for _, field in pairs(model.fields) do
  --   if field.db_type == field.FK_TYPE_NOT_DEFIEND then
  --     local fk = model.fields[field.reference_column]
  --     field.db_type = fk.db_type or fk.type
  --   end
  -- end
  local uniques = Array {}
  for _, unique_group in ipairs(ModelClass.unique_together or {}) do
    for i, name in ipairs(unique_group) do
      if not ModelClass.fields[name] then
        error(string_format("invalid unique_together name %s for model %s", name, ModelClass.table_name))
      end
    end
    uniques:push(Array(clone(unique_group)))
  end
  ModelClass.unique_together = uniques
  ModelClass.__is_model_class__ = true
  if ModelClass.table_name then
    ModelClass:materialize_with_table_name { table_name = ModelClass.table_name }
  end
  ModelClass:set_label_name_dict()
  ModelClass:ensure_admin_list_names();
  if ModelClass.auto_now_add_name then
    ModelClass:ensure_ctime_list_names(ModelClass.auto_now_add_name);
  end
  if ModelClass.table_name then
    setmetatable(ModelClass, {
      __call = ModelClass.create_record,
      -- __newindex = disable_setting_model_attrs
    })
  end
  local proxy = create_model_proxy(ModelClass)
  Xodel.resolve_self_foreignkey(proxy)
  return proxy
end

local EXTEND_ATTRS = { 'table_name', 'label', 'referenced_label_column', 'preload' }
---@param cls Xodel
---@param options ModelOpts
---@return ModelOpts
function Xodel.normalize(cls, options)
  local extends = options.extends
  local model = {
    admin = clone(options.admin or {}),
  }
  for _, extend_attr in ipairs(EXTEND_ATTRS) do
    if options[extend_attr] == nil then
      if options.extends then
        model[extend_attr] = options.extends[extend_attr]
      end
    else
      model[extend_attr] = options[extend_attr]
    end
  end
  local opts_fields = {}
  local opts_field_names = Array {}
  -- first check top level Array field
  for i, field in ipairs(options) do
    field = ensure_field_as_options(field)
    opts_field_names:push(field.name)
    opts_fields[field.name] = field
  end
  -- then check fields
  for key, field in pairs(options.fields or {}) do
    if type(key) == 'string' then
      field = ensure_field_as_options(field, key)
      opts_field_names:push(key)
      opts_fields[key] = field
    else
      field = ensure_field_as_options(field)
      opts_field_names:push(field.name)
      opts_fields[field.name] = field
    end
  end
  local opts_names = options.field_names
  if not opts_names then
    if extends then
      opts_names = Array.concat(extends.field_names, opts_field_names):uniq()
    else
      opts_names = opts_field_names:uniq()
    end
  end
  model.field_names = normalize_field_names(clone(opts_names))
  model.fields = {}
  for _, name in ipairs(model.field_names) do
    cls.check_field_name(model, name)
    local field = opts_fields[name]
    if not field then
      local tname = model.table_name or '[abstract model]'
      if extends then
        field = extends.fields[name]
        if not field then
          error(string_format("'%s' field name '%s' is not in fields and parent fields", tname, name))
        else
          field = ensure_field_as_options(field, name)
        end
      else
        error(string_format("Model class '%s's field name '%s' is not in fields", tname, name))
      end
    elseif extends and extends.fields[name] then
      local pfield = extends.fields[name]
      field = dict(pfield:get_options(), field)
      if pfield.model and field.model then
        field.model = cls:create_model {
          abstract = true,
          extends = pfield.model,
          fields = field.model.fields,
          field_names = field.model.field_names
        }
      end
    end
    model.fields[name] = cls:make_field_from_json(dict(field, { name = name }))
  end
  for key, value in pairs(options) do
    if model[key] == nil and MODEL_MERGE_NAMES[key] then
      model[key] = value
    end
  end
  local unique_together = options.unique_together or {}
  if type(unique_together[1]) == 'string' then
    unique_together = { unique_together }
  end
  model.unique_together = unique_together
  local abstract
  if options.abstract ~= nil then
    abstract = not not options.abstract
  else
    abstract = model.table_name == nil
  end
  model.abstract = abstract
  model.__normalized__ = true
  if options.mixins then
    local models = list(options.mixins, { model })
    local merge_model = cls:merge_models(models)
    return merge_model
  else
    return model
  end
end

---@param cls Xodel
function Xodel.set_label_name_dict(cls)
  cls.label_to_name = {}
  cls.name_to_label = {}
  for name, field in pairs(cls.fields) do
    cls.label_to_name[field.label] = name
    cls.name_to_label[name] = field.label
  end
end

local compound_types = {
  array = true,
  json = true,
  table = true,
  password = true,
  text = true,
  alioss_list = true,
  alioss_image_list = true,
}

local function get_admin_list_names(model)
  local names = Array()
  for i, name in ipairs(model.names) do
    local field = model.fields[name]
    if not compound_types[field.type] then
      names:push(name)
    end
  end
  return names
end

---@param cls Xodel
function Xodel.ensure_admin_list_names(cls)
  cls.admin.list_names = Array(clone(cls.admin.list_names or {}));
  if #cls.admin.list_names == 0 then
    cls.admin.list_names = get_admin_list_names(cls)
  end
end

---@param cls Xodel
function Xodel.ensure_ctime_list_names(cls, ctime_name)
  local admin = assert(cls.admin)
  if not admin.list_names:includes(ctime_name) then
    admin.list_names = list(admin.list_names, { ctime_name })
  end
end

---@param cls Xodel
function Xodel.resolve_self_foreignkey(cls)
  for _, name in ipairs(cls.field_names) do
    local field = cls.fields[name]
    local fk_model = field.reference
    if fk_model == "self" then
      ---@cast field ForeignkeyField
      fk_model = cls
      field.reference = cls
      field:setup_with_fk_model(cls)
    end
    if fk_model then
      cls.foreign_keys[name] = field
    end
  end
end

---@param cls Xodel
---@param opts {table_name:string, label?:string}
---@return Xodel
function Xodel.materialize_with_table_name(cls, opts)
  local table_name = opts.table_name
  local label = opts.label
  if not table_name then
    local names_hint = cls.field_names and cls.field_names:join(",") or "no field_names"
    error(string_format("you must define table_name for a non-abstract model (%s)", names_hint))
  end
  check_reserved(table_name)
  cls.table_name = table_name
  cls.label = cls.label or label or table_name
  cls.abstract = false
  if not cls.primary_key and cls.auto_primary_key then
    local pk_name = DEFAULT_PRIMARY_KEY
    cls.primary_key = pk_name
    cls.fields[pk_name] = Fields.integer:create_field { name = pk_name, primary_key = true, serial = true }
    table_insert(cls.field_names, 1, pk_name)
  end
  cls.name_cache = {}
  for name, field in pairs(cls.fields) do
    cls.name_cache[name] = cls.table_name .. "." .. name
    if field.reference then
      field.table_name = table_name
    end
  end
  cls.RecordClass = make_record_meta(cls)
  return cls
end

---@param cls Xodel
---@param ... ModelOpts
---@return Xodel
function Xodel.mix_with_base(cls, ...)
  return cls:mix(base_model, ...)
end

---@param cls Xodel
---@param ... ModelOpts
---@return Xodel
function Xodel.mix(cls, ...)
  return cls:_make_model_class(cls:merge_models { ... })
end

---@param cls Xodel
---@param models ModelOpts[]
---@return ModelOpts
function Xodel.merge_models(cls, models)
  if #models < 2 then
    error("provide at least two models to merge")
  elseif #models == 2 then
    return cls:merge_model(unpack(models))
  else
    local merged = models[1]
    for i = 2, #models do
      merged = cls:merge_model(merged, models[i])
    end
    return merged
  end
end

---@param cls Xodel
---@param a ModelOpts
---@param b ModelOpts
---@return ModelOpts
function Xodel.merge_model(cls, a, b)
  local A = a.__normalized__ and a or cls:normalize(a)
  local B = b.__normalized__ and b or cls:normalize(b)
  local C = {}
  local field_names = (A.field_names + B.field_names):uniq()
  local fields = {}
  for i, name in ipairs(field_names) do
    local af = A.fields[name]
    local bf = B.fields[name]
    if af and bf then
      fields[name] = Xodel:merge_field(af, bf)
    elseif af then
      fields[name] = af
    elseif bf then
      fields[name] = bf
    else
      error(
        string_format("can't find field %s for model %s and %s", name, A.table_name, B.table_name))
    end
  end
  -- merge的时候abstract应该当做可合并的属性
  for i, M in ipairs { A, B } do
    for key, value in pairs(M) do
      if MODEL_MERGE_NAMES[key] then
        C[key] = value
      end
    end
  end
  C.field_names = field_names
  C.fields = fields
  return cls:normalize(C)
end

---@param cls Xodel
---@param a AnyField
---@param b AnyField
---@return AnyField
function Xodel.merge_field(cls, a, b)
  local aopts = is_field_class(a) and a:get_options() or clone(a)
  local bopts = is_field_class(b) and b:get_options() or clone(b)
  local options = dict(aopts, bopts)
  if aopts.model and bopts.model then
    options.model = cls:merge_model(aopts.model, bopts.model)
  end
  return cls:make_field_from_json(options)
end

---@param cls Xodel
---@param names? string[]|string
function Xodel.to_json(cls, names)
  if not names then
    return {
      table_name = cls.table_name,
      class_name = cls.class_name,
      primary_key = cls.primary_key,
      admin = clone(cls.admin),
      unique_together = clone(cls.unique_together),
      label = cls.label or cls.table_name,
      names = clone(cls.names),
      field_names = clone(cls.field_names),
      label_to_name = clone(cls.label_to_name),
      name_to_label = clone(cls.name_to_label),
      fields = Object.from_entries(cls.field_names:map(function(name)
        return { name, cls.fields[name]:json() }
      end))
    }
  else
    if type(names) ~= 'table' then
      names = { names }
    end
    local label_to_name = {}
    local name_to_label = {}
    local fields = {}
    for i, name in ipairs(names) do
      local field = cls.fields[name]
      label_to_name[field.label] = name
      name_to_label[field.name] = field.label
      fields[name] = field:json()
    end
    return {
      table_name = cls.table_name,
      class_name = cls.class_name,
      primary_key = cls.primary_key,
      label = cls.label or cls.table_name,
      names = names,
      field_names = names,
      label_to_name = label_to_name,
      name_to_label = name_to_label,
      fields = fields,
    }
  end
end

---@param cls Xodel
---@return Record[]
function Xodel.all(cls)
  local records = assert(cls.query("SELECT * FROM " .. cls.table_name))
  for i = 1, #records do
    records[i] = cls:load(records[i])
  end
  return setmetatable(records, Array)
end

---@param cls Xodel
---@param params table
---@param defaults? table
---@param columns? string[]
---@return XodelInstance, boolean
function Xodel.get_or_create(cls, params, defaults, columns)
  local values_list, insert_columns = Sql:_get_insert_values_token(dict(params, defaults))
  local insert_columns_token = as_token(insert_columns)
  local all_columns_token = as_token(Array.unique(list(columns or { cls.primary_key }, insert_columns)))
  local insert_sql = string_format("(INSERT INTO %s(%s) SELECT %s WHERE NOT EXISTS (%s) RETURNING %s)",
    cls.table_name,
    insert_columns_token,
    as_literal_without_brackets(values_list),
    cls:create_sql():select(1):where(params),
    all_columns_token
  )
  local inserted_set = cls:create_sql_as("new_records")
      :with(string_format("new_records(%s)", all_columns_token), insert_sql)
      :_base_select(all_columns_token):_base_select("TRUE AS __is_inserted__")
  local selected_set = cls:create_sql():where(params):_base_select(all_columns_token):_base_select(
    "FALSE AS __is_inserted__")
  local records = inserted_set:union_all(selected_set):exec()
  if #records > 1 then
    error("multiple records returned")
  end
  local ins = records[1]
  ---@diagnostic disable-next-line: undefined-field
  local created = ins.__is_inserted__
  ins.__is_inserted__ = nil
  return ins, created
end

---@param cls Xodel
---@param input Record
---@param names? string[]
---@param key?  string
---@return XodelInstance?, ValidateError?
function Xodel.save(cls, input, names, key)
  local uk = key or cls.primary_key
  if rawget(input, uk) ~= nil then
    return cls:save_update(input, names, uk)
  else
    return cls:save_create(input, names, key)
  end
end

---@param cls Xodel
---@param key  string
---@return string
function Xodel.check_unique_key(cls, key)
  local pkf = cls.fields[key]
  if not pkf then
    error("invalid field name: " .. key)
  end
  if not (pkf.primary_key or pkf.unique) then
    error(string_format("field '%s' is not primary_key or not unique", key))
  end
  return key
end

---@param cls Xodel
---@param input Record
---@param names? string[]
---@param key?  string
---@return XodelInstance
function Xodel.save_create(cls, input, names, key)
  local data = assert(cls:validate_create(input, names))
  local prepared = assert(cls:prepare_for_db(data, names))
  local created = cls:create_sql():_base_insert(prepared):_base_returning(key or '*'):execr()
  for k, v in pairs(created[1]) do
    data[k] = v
  end
  return cls:create_record(data)
end

---@param cls Xodel
---@param input Record
---@param names? string[]
---@param key?  string
---@return XodelInstance
function Xodel.save_update(cls, input, names, key)
  local data = assert(cls:validate_update(input, names))
  if not key then
    key = cls.primary_key
  else
    key = cls:check_unique_key(key)
  end
  local look_value = input[key]
  if look_value == nil then
    error("no primary or unique key value for save_update")
  end
  local prepared = assert(cls:prepare_for_db(data, names, true))
  local updated = cls:create_sql():_base_update(prepared):where { [key] = look_value }
      :_base_returning(key):execr()
  ---@cast updated Record
  if #updated == 1 then
    data[key] = updated[1][key]
    return cls:create_record(data)
  elseif #updated == 0 then
    error(string_format("update failed, record does not exist(model:%s, key:%s, value:%s)", cls.table_name,
      key, look_value))
  else
    error(string_format("expect 1 but %s records are updated(model:%s, key:%s, value:%s)",
      #updated,
      cls.table_name,
      key,
      look_value))
  end
end

---@param cls Xodel
---@param data Record
---@param columns? string[]
---@param is_update? boolean
---@return Record
---@overload fun(cls:Xodel, data:Record, columns?:string[],is_update?:boolean):nil, ValidateError
function Xodel.prepare_for_db(cls, data, columns, is_update)
  local prepared = {}
  for _, name in ipairs(columns or cls.names) do
    local field = cls.fields[name]
    if not field then
      error(string_format("invalid field name '%s' for model '%s'", name, cls.table_name))
    end
    local value = data[name]
    if field.prepare_for_db and value ~= nil then
      local val, err = field:prepare_for_db(value)
      if val == nil and err then
        return nil, cls:make_field_error(name, err)
      else
        prepared[name] = val
      end
    else
      prepared[name] = value
    end
  end
  if is_update and cls.auto_now_name then
    prepared[cls.auto_now_name] = ngx_localtime()
  end
  return prepared
end

---@param cls Xodel
---@param input Record
---@param names? string[]
---@param key? string
---@return Record?, ValidateError?
function Xodel.validate(cls, input, names, key)
  if rawget(input, key or cls.primary_key) ~= nil then
    return cls:validate_update(input, names)
  else
    return cls:validate_create(input, names)
  end
end

---@param cls Xodel
---@param input Record
---@param names? string[]
---@return Record?, ValidateError?
function Xodel.validate_create(cls, input, names)
  local data = {}
  for _, name in ipairs(names or cls.names) do
    local field = cls.fields[name]
    if not field then
      error(string_format("invalid field name '%s' for model '%s'", name, cls.table_name))
    end
    local value, err, index = field:validate(rawget(input, name))
    if err ~= nil then
      return nil, cls:make_field_error(name, err, index)
    elseif field.default and (value == nil or value == "") then
      if type(field.default) ~= "function" then
        value = field.default
      else
        value, err = field.default()
        if value == nil then
          return nil, cls:make_field_error(name, err, index)
        end
      end
    end
    data[name] = value
  end
  if not cls.clean then
    return data
  else
    local res, clean_err = cls:clean(data)
    if res == nil then
      return nil, clean_err
    else
      return res
    end
  end
end

---@param cls Xodel
---@param input Record
---@param names? string[]
---@return Record
---@overload fun(cls:Xodel, input:Record, names?:string[]):nil, ValidateError
function Xodel.validate_update(cls, input, names)
  local data = {}
  for _, name in ipairs(names or cls.names) do
    local field = cls.fields[name]
    if not field then
      error(string_format("invalid field name '%s' for model '%s'", name, cls.table_name))
    end
    local err, index
    local value = rawget(input, name)
    if value ~= nil then
      value, err, index = field:validate(value)
      if err ~= nil then
        return nil, cls:make_field_error(name, err, index)
      elseif value == nil then
        -- value is nil again after validate,its a non-required field whose value is empty string.
        -- data[name] = field.get_empty_value_to_update(input)
        -- 这里统一用空白字符串占位,以便prepare_for_db处pairs能处理该name
        data[name] = ""
      else
        data[name] = value
      end
    end
  end
  if not cls.clean then
    return data
  else
    local res, clean_err = cls:clean(data)
    if res == nil then
      return nil, clean_err
    else
      return res
    end
  end
end

---@param cls Xodel
---@param rows Records
---@param key Keys
---@return Records, Keys
---@overload fun(rows:Records, key:Keys):nil, ValidateError
function Xodel.check_upsert_key(cls, rows, key)
  assert(key, "no key for upsert")
  if rows[1] then
    ---@cast rows Record[]
    if type(key) == "string" then
      for i, row in ipairs(rows) do
        if row[key] == nil or row[key] == '' then
          local err = cls:make_field_error(key, key .. "不能为空")
          err.batch_index = i
          return nil, err
        end
      end
    else
      for i, row in ipairs(rows) do
        for _, k in ipairs(key) do
          if row[k] == nil or row[k] == '' then
            local err = cls:make_field_error(k, k .. "不能为空")
            err.batch_index = i
            return nil, err
          end
        end
      end
    end
  elseif type(key) == "string" then
    ---@cast rows Record
    if rows[key] == nil or rows[key] == '' then
      return nil, cls:make_field_error(key, key .. "不能为空")
    end
  else
    ---@cast rows Record
    for _, k in ipairs(key) do
      if rows[k] == nil or rows[k] == '' then
        return nil, cls:make_field_error(k, k .. "不能为空")
      end
    end
  end
  return rows, key
end

function Xodel.make_field_error(cls, name, err, index)
  local field = assert(cls.fields[name], "invalid feild name: " .. name)
  return {
    type = 'field_error',
    message = err,
    index = index,
    name = field.name,
    label = field.label,
  }
end

---@param cls Xodel
---@param data Record
---@return XodelInstance
function Xodel.load(cls, data)
  for _, name in ipairs(cls.names) do
    local field = cls.fields[name]
    local value = data[name]
    if value ~= nil then
      if not field.load then
        data[name] = value
      else
        data[name] = field:load(value)
      end
    end
  end
  return cls:create_record(data)
end

---used in merge and upsert
---@param cls Xodel
---@param rows Record|Record[]
---@param columns? string[]
---@return Records?, string[]|ValidateError
function Xodel.validate_create_data(cls, rows, columns)
  local err_obj, cleaned
  -- TODO: columns没有提供值时从rows里面获取, 以便和merge的逻辑一致. 但是要考虑排除列id的情况
  columns = columns or cls.names
  if rows[1] then
    ---@cast rows Record[]
    cleaned = {}
    for index, row in ipairs(rows) do
      ---@diagnostic disable-next-line: cast-local-type
      row, err_obj = cls:validate_create(row, columns)
      if row == nil then
        err_obj.batch_index = index
        ---@cast err_obj ValidateError
        return nil, err_obj
      end
      cleaned[index] = row
    end
  else
    ---@cast rows Record
    cleaned, err_obj = cls:validate_create(rows, columns)
    if err_obj then
      return nil, err_obj
    end
  end
  return cleaned, columns
end

---@param cls Xodel
---@param rows Record|Record[]
---@param columns? string[]
---@return Records?, string[]|ValidateError
function Xodel.validate_update_data(cls, rows, columns)
  local err_obj, cleaned
  columns = columns or cls.names
  if rows[1] then
    cleaned = {}
    for index, row in ipairs(rows) do
      ---@diagnostic disable-next-line: cast-local-type
      row, err_obj = cls:validate_update(row, columns)
      if row == nil then
        err_obj.batch_index = index
        ---@cast err_obj ValidateError
        return nil, err_obj
      end
      cleaned[index] = row
    end
  else
    cleaned, err_obj = cls:validate_update(rows, columns)
    if err_obj then
      return nil, err_obj
    end
  end
  return cleaned, columns
end

---used in merge and upsert
---@param cls Xodel
---@param rows Records
---@param key Keys
---@param columns? string[]
---@return Records, Keys, Keys
---@overload fun(cls:Xodel, rows:Records, key:Keys, columns?: string[]):nil, ValidateError
function Xodel.validate_create_rows(cls, rows, key, columns)
  local checked_rows, checked_key = cls:check_upsert_key(rows, key)
  if checked_rows == nil then
    return nil, checked_key
  end
  local cleaned_rows, cleaned_columns = cls:validate_create_data(checked_rows, columns)
  if cleaned_rows == nil then
    return nil, cleaned_columns
  end
  return cleaned_rows, checked_key, cleaned_columns
end

---@param cls Xodel
---@param rows Records
---@param key Keys
---@param columns? string[]
---@return Records, Keys, Keys
---@overload fun(cls:Xodel, rows:Records, key:Keys, columns?: string[]):nil, ValidateError
function Xodel.validate_update_rows(cls, rows, key, columns)
  local checked_rows, checked_key = cls:check_upsert_key(rows, key)
  if checked_rows == nil then
    return nil, checked_key
  end
  local cleaned_rows, cleaned_columns = cls:validate_update_data(checked_rows, columns)
  if cleaned_rows == nil then
    return nil, cleaned_columns
  end
  return cleaned_rows, checked_key, cleaned_columns
end

---@param cls Xodel
---@param rows Records
---@param columns? string[]
---@param is_update? boolean
---@return Records?, string[]|ValidateError
function Xodel.prepare_db_rows(cls, rows, columns, is_update)
  local err, cleaned
  columns = columns or get_keys(rows)
  if rows[1] then
    ---@cast rows Record[]
    cleaned = {}
    for i, row in ipairs(rows) do
      ---@diagnostic disable-next-line: cast-local-type
      row, err = cls:prepare_for_db(row, columns, is_update)
      if err ~= nil then
        err.batch_index = i
        return nil, err
      end
      cleaned[i] = row
    end
  else
    ---@cast rows Record
    cleaned, err = cls:prepare_for_db(rows, columns, is_update)
    if err ~= nil then
      return nil, err
    end
  end
  if is_update then
    local utime = cls.auto_now_name
    if utime and not Array(columns):includes(utime) then
      columns[#columns + 1] = utime
    end
    return cleaned, columns
  else
    return cleaned, columns
  end
end

---@param cls Xodel
---@param row any
---@return boolean
function Xodel.is_instance(cls, row)
  return is_sql_instance(row)
end

---@param cls Xodel
---@param kwargs table
---@return Array<XodelInstance>
function Xodel.filter(cls, kwargs)
  return cls:create_sql():where(kwargs):exec()
end

---@param cls Xodel
---@param kwargs table
---@return Array<XodelInstance>
function Xodel.filter_with_fk_labels(cls, kwargs)
  local records = cls:create_sql():load_fk_labels():where(kwargs)
  return records:exec()
end

---@param cls Xodel
---@param data table
---@return XodelInstance
function Xodel.create_record(cls, data)
  return setmetatable(data, cls.RecordClass)
end

local update_args = { 'where', 'where_or', 'or_where', 'or_where_or', 'returning', 'raw' }
local insert_args = { 'returning', 'raw' }
local select_args = { 'select', 'load_fk', 'load_fk_labels', 'where', 'where_or', 'or_where', 'or_where_or',
  'order', 'group', 'having', 'limit', 'offset', 'distinct', 'raw', 'flat', 'compact', 'get', 'exists' }

---@alias updateArgs {update:table, where?:table, where_or?:table, returning?:table|string[], raw?:boolean}
---@alias insertArgs {insert:table, returning?:table|string[], raw?:boolean}
---@alias selectArgs {select?:table|string[], load_fk?:string,load_fk_labels?:string[], where?:table, where_or?:table,or_where?:table, order?:table|string[], group?:table|string[], limit?:integer, offset?:integer, distinct?:boolean, get?:table|string[],flat?:string, raw?:boolean, exists?:boolean}

---@param cls Xodel
---@param data updateArgs|insertArgs|selectArgs
---@return table
function Xodel.meta_query(cls, data)
  if data.update then
    local records = cls:create_sql():update(data.update)
    for i, arg_name in ipairs(update_args) do
      if data[arg_name] ~= nil then
        records = records[arg_name](records, data[arg_name])
      end
    end
    return records:exec()
  elseif data.insert then
    local records = cls:create_sql():insert(data.insert)
    for i, arg_name in ipairs(insert_args) do
      if data[arg_name] ~= nil then
        records = records[arg_name](records, data[arg_name])
      end
    end
    return records:exec()
  else
    local records = cls:create_sql()
    for i, arg_name in ipairs(select_args) do
      if data[arg_name] ~= nil then
        records = records[arg_name](records, data[arg_name])
      end
    end
    if data.get or data.flat or data.exists then
      return records
    else
      return records:exec()
    end
  end
end

local whitelist = { DEFAULT = true, as_token = true, as_literal = true, __call = true, new = true, token = true }
for k, v in pairs(Sql) do
  if type(v) == 'function' and not whitelist[k] then
    assert(Xodel[k] == nil, "same function name appears:" .. k)
  end
end
return Xodel
