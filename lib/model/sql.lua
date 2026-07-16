local Utils = require "model.utils"
local Array = require "resty.array"
local encode = require("cjson").encode
local F = require "model.f"

local setmetatable = setmetatable
local ipairs = ipairs
local tostring = tostring
local type = type
local pairs = pairs
local assert = assert
local error = error
local insert = table.insert
local next = next
local format = string.format
local concat = table.concat
local clone = Utils.clone
local isempty = Utils.isempty
local is_empty_value = Utils.is_empty_value
local table_new = Utils.table_new
local table_clear = Utils.table_clear
local PG_OPERATORS = Utils.PG_OPERATORS
local PG_SET_MAP = Utils.PG_SET_MAP
local smart_quote = Utils.smart_quote
local DEFAULT = Utils.DEFAULT
local NULL = Utils.NULL
local list = Utils.list
local dict = Utils.dict
local map = Utils.map
local get_keys = Utils.get_keys
local get_foreign_object = Utils.get_foreign_object
local extract_column_names = Utils.extract_column_names
local as_literal = Utils.as_literal
local as_token = Utils.as_token
local as_literal_without_brackets = Utils.as_literal_without_brackets
local escape_like_value = Utils.escape_like_value
local get_list_tokens = Utils.get_list_tokens
local assemble_sql = Utils.assemble_sql
local json_operators = Utils.json_operators
local NON_OPERATOR_CONTEXTS = Utils.NON_OPERATOR_CONTEXTS
local _get_join_token = Utils._get_join_token
local _prefix_with_V = Utils._prefix_with_V
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
---@field for_update? boolean
---@field for_update_nowait? boolean
---@field for_update_skip_locked? boolean
---@field for_update_of? string
---@field for_update_no_key? boolean


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
---@field model Model
---@field table_name string
---@field as_token  fun(DBValue):string
---@field as_literal  fun(DBValue):string
---@field private _pcall? boolean
---@field private _as?  string
---@field private _with?  string
---@field private _with_recursive?  string
---@field private _join?  string
---@field private _distinct?  boolean
---@field private _distinct_on?  string
---@field private _returning?  string
---@field private _insert?  string
---@field private _update?  string
---@field private _delete?  boolean
---@field private _using?  string
---@field private _select?  string
---@field private _from?  string
---@field private _where?  string
---@field private _group?  string
---@field private _having?  string
---@field private _order?  string
---@field private _nulls_first?  boolean
---@field private _nulls_last?  boolean
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
---@field private _group_args? string[]
---@field private _join_proxy_models?  Model[]
---@field private _join_alias?  string[]
---@field private _prepend?  (Sql|string)[]
---@field private _append?  (Sql|string)[]
---@field private _join_keys? table
---@field private _select_related? table
---@field private _skip_validate? boolean
---@field private _commit? boolean
---@field private _compact? boolean
---@field private _return_all? boolean
---@field private _raw? boolean
---@field private _set_operation? boolean
---@field private _for_update? boolean
---@field private _for_update_nowait? boolean
---@field private _for_update_skip_locked? boolean
---@field private _for_update_of? string
---@field private _for_update_of_raw? string[]
---@field private _for_update_no_key? boolean
---@field private _annotate? table<string,string>
---@field private _where_recursive? boolean
local Sql = setmetatable({}, SqlMeta)
Sql.__index = Sql
Sql.__SQL_BUILDER__ = true
Sql.as_token = as_token
Sql.as_literal = as_literal
Sql.MAX_LIMIT = 10000
Sql.EXPR_OPERATORS = EXPR_OPERATORS

function Sql:__tostring()
  return self:statement()
end

---@private
---@param rows Sql|Record|Record[]
---@param columns? string[]
---@return self
function Sql:_base_insert(rows, columns)
  if rows.__SQL_BUILDER__ then
    ---@cast rows Sql
    if rows._returning then
      self:_set_cud_subquery_insert_token(rows, columns)
    elseif rows._select then
      self:_set_select_subquery_insert_token(rows, columns)
    else
      error("select or returning args should be provided when inserting from a sub query")
    end
  elseif rows[1] then
    ---@cast rows Record[]
    self._insert = self:_get_bulk_insert_token(rows, columns)
  else
    ---@cast rows Record
    self._insert = self:_get_insert_token(rows, columns)
  end
  return self
end

---@private
---@param row Record|string|Sql
---@param columns? string[]
---@return self
function Sql:_base_update(row, columns)
  if type(row) == "table" then
    -- if row.__SQL_BUILDER__ then
    --   ---@cast row Sql
    --   self._update = self:_base_get_update_query_token(row, columns)
    -- else
    --   self._update = self:_get_update_token(row, columns)
    -- end
    self._update = self:_get_update_token(row, columns)
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
  if not self._select then
    self._select = s
  else
    self._select = self._select .. ", " .. s
  end
  return self
end

-- {{a=1,b='foo'}, {a=3,b='bar'}} => {"(1, 'foo')", "(3, 'bar')"}
---@private
---@param rows Record[]
---@param columns string[]
---@param no_check? boolean
---@return string[]
function Sql:_get_cte_values_literal(rows, columns, no_check, is_update)
  rows = self:_rows_to_array(rows, columns, is_update)
  ---@type string[]
  local res = { self:_array_to_values(rows[1], columns, no_check, true) }
  for i = 2, #rows do
    res[i] = self:_array_to_values(rows[i], columns, no_check, false)
  end
  return res
end

--use `name` as key implicitly, because it's the only unique column
--```lua
-- Blog:merge {
--   { name = 'merge1', tagline = 'mergetest1' },
--   { name = 'merge2', tagline = 'mergetest2' }
-- }:exec()
--```
--yields:
-- ```sql
-- WITH
--   V (tagline, name) AS (
--     VALUES
--       ('mergetest1'::varchar, 'merge1'::varchar),
--       ('mergetest2', 'merge2')
--   ),
--   U AS (
--     UPDATE blog W
--     SET
--       tagline = V.tagline
--     FROM
--       V
--     WHERE
--       V.name = W.name
--     RETURNING
--       V.tagline,
--       V.name
--   )
-- INSERT INTO
--   blog AS T (tagline, name)
-- SELECT
--   V.tagline,
--   V.name
-- FROM
--   V
--   LEFT JOIN U AS W ON (V.name = W.name)
-- WHERE
--   W.name IS NULL
-- ```
--when data column is the same as the key, just insert if possible, no update
--```lua
-- Blog:merge({ { name = 'merge1' }, { name = 'merge2' } }, 'name'):exec()
--```
--yields:
--```sql
-- WITH
--   V (name) AS (
--     VALUES
--       ('merge1'::varchar),
--       ('merge2')
--   ),
--   U AS (
--     SELECT
--       V.name
--     FROM
--       V
--       INNER JOIN blog AS W ON (V.name = W.name)
--   )
-- INSERT INTO
--   blog AS T (name)
-- SELECT
--   V.name
-- FROM
--   V
--   LEFT JOIN U AS W ON (V.name = W.name)
-- WHERE
--   W.name IS NULL
--```
---@private
---@param rows Record[]|Sql
---@param key Keys
---@param columns string[]
---@return self
function Sql:_base_merge(rows, key, columns)
  local cte_name = format("V(%s)", concat(columns, ", "))
  -- V 既可来自 VALUES 字面量，也可来自子查询；后续 U、INSERT 只引用 V.col，与来源无关
  local cte_values
  if rows.__SQL_BUILDER__ then
    cte_values = rows
  else
    cte_values = format("(VALUES %s)", as_token(self:_get_cte_values_literal(rows, columns)))
  end
  local join_cond = self:_get_join_condition_from_key(key, "V", "W")
  local vals_columns = map(columns, _prefix_with_V)
  -- as _check_upsert_key_error requires all keys are non-empty,
  -- so here we use `key[1]` to determine whether a row should be inserted when key is a table
  local insert_subquery = Sql:new { table_name = "V", _where = format("W.%s IS NULL", key[1] or key) }
      :_base_select(vals_columns)
      :_base_join_raw("LEFT", "U AS W", join_cond) -- `U AS W` to reuse join_cond token
  local intersect_subquery
  if (type(key) == "table" and #key == #columns) or #columns == 1 then
    intersect_subquery = Sql:new { table_name = "V" }
        :_base_select(vals_columns)
        :_base_join_raw("INNER", self.table_name .. " AS W", join_cond)
  else
    intersect_subquery = Sql:new { table_name = self.table_name, _as = "W" }
        :_base_update(self:_get_update_token_with_prefix(columns, key, "V"))
        :_base_from("V")
        :_base_where(join_cond)
        :_base_returning(vals_columns)
  end
  self:with(cte_name, cte_values):with("U", intersect_subquery)
  return Sql._base_insert(self, insert_subquery, columns)
end

---@private
---@param rows Sql|Record[]|Record
---@param key Keys
---@param columns string[]
---@return self
function Sql:_base_upsert(rows, key, columns)
  assert(key, "you must provide key (string or table) for upsert")
  if rows.__SQL_BUILDER__ then
    ---@cast rows Sql
    if rows._returning then
      self:_set_cud_subquery_upsert_token(rows, key, columns)
    elseif rows._select then
      self:_set_select_subquery_upsert_token(rows, key, columns)
    else
      error("select or returning args should be provided when inserting from a sub query")
    end
  elseif rows[1] then
    self._insert = self:_get_bulk_upsert_token(rows, key, columns)
  else
    self._insert = self:_get_upsert_token(rows, key, columns)
  end
  return self
end

--```lua
-- Blog:updates({
--   { name = 'Third Blog', tagline = 'Updated by updates' },
--   { name = 'Fourth Blog', tagline = 'wont update' }
-- }):exec()
--```
-- yields:
--```sql
-- WITH
--   V (tagline, name) AS (
--     VALUES
--       ('Updated by updates'::text, 'Third Blog'::varchar),
--       ('wont update', 'Fourth Blog')
--   )
-- UPDATE blog T
-- SET
--   tagline = V.tagline
-- FROM
--   V
-- WHERE
--   V.name = T.name
--```
---@private
---@param rows Record[]|Sql
---@param key Keys
---@param columns string[]
---@return self
function Sql:_base_updates(rows, key, columns)
  if rows.__SQL_BUILDER__ then
    ---@cast rows Sql
    local cte_name = format("V(%s)", concat(columns, ", "))
    local join_cond = self:_get_join_condition_from_key(key, "V", self._as or self.table_name)
    self:with(cte_name, rows)
    return Sql._base_update(self, self:_get_update_token_with_prefix(columns, key, "V"))
        :_base_from("V"):_base_where(join_cond)
  elseif #rows == 0 then
    error("empty rows passed to updates")
  else
    ---@cast rows Record[]
    rows = self:_get_cte_values_literal(rows, columns, nil, true)
    local cte_name = format("V(%s)", concat(columns, ", "))
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
  if not self._returning then
    self._returning = s
  else
    self._returning = self._returning .. ", " .. s
  end
  return self
end

---@private
---@param ... string
---@return self
function Sql:_base_from(...)
  local s = get_list_tokens(...)
  if not self._from then
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
  if not self._using then
    self._using = s
  else
    self._using = self._using .. ", " .. s
  end
  return self
end

---@private
---@param model Model
---@param alias string
---@return table
function Sql:_create_join_proxy(model, alias)
  local function __index(_, key)
    local field = model.fields[key]
    if field then
      return alias .. '.' .. key
    end
  end
  local proxy = setmetatable({ model.table_name }, { __index = __index })
  return proxy
end

---@private
function Sql:_ensure_context()
  if not self._join_proxy_models then
    local alias = self._as or self.table_name
    local main_proxy = self:_create_join_proxy(self.model, smart_quote(alias))
    self._join_proxy_models = { main_proxy }
    self._join_alias = { alias }
  end
end

---@private
---Materialize a JOIN. The new proxy is appended to `_join_proxy_models` and
---registered under `join_key` (and the auto alias `T<n>`) BEFORE `callback`
---runs, so callers can index `ctx[join_key]` / `ctx[#ctx]` from inside the
---callback.
---
---IMPORTANT contract: `callback` is invoked **synchronously and exactly once**
---before this function returns. _parse_column relies on this — its closures
---capture loop-local upvalues (`last_token`, `join_key`, `last_field`, ...)
---that get overwritten on the next iteration. Do NOT change this to lazy /
---deferred invocation without revisiting every caller.
---@param join_type string
---@param fk_model Model
---@param callback fun(ctx:table):string
---@param join_key? string
---@return string
function Sql:_handle_manual_join(join_type, fk_model, callback, join_key)
  self:_ensure_context()
  if not self._join_args then
    self._join_args = {}
  end
  if not self._join_keys then
    self._join_keys = {}
  end
  local right_alias = 'T' .. #self._join_proxy_models
  local proxy = self:_create_join_proxy(fk_model, right_alias)
  self._join_proxy_models[#self._join_proxy_models + 1] = proxy
  self._join_proxy_models[join_key or right_alias] = proxy
  self._join_alias[#self._join_alias + 1] = right_alias
  self._join_keys[join_key or right_alias] = right_alias
  local join_conds = callback(self._join_proxy_models)
  self._join_args[#self._join_args + 1] = { join_type, fk_model._table_name_token, right_alias, join_conds }
  return self._join_alias[#self._join_alias]
end

---@private
---@param join_type string
---@param join_args string|Model
---@param key string|fun(ctx:table):string
---@param op? string
---@param val? DBValue
---@return self
function Sql:_base_join(join_type, join_args, key, op, val)
  if type(join_args) == 'table' then
    ---@cast join_args Model
    ---@cast key fun(ctx:table):string
    self:_handle_manual_join(join_type, join_args, key)
    return self
  else
    ---@cast join_args string
    ---@cast key string
    local fk = self.model.foreignkey_fields[join_args]
    if fk then
      return self:_base_join("INNER", fk.reference, function(ctx)
        return format("%s = %s",
          ctx[self.model.table_name][join_args],
          ctx[fk.reference.table_name][fk.reference_column])
      end)
    else
      return self:_base_join_raw(join_type, join_args, key, op, val)
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
---@param cols Keys
---@param op "IN"|"NOT IN"
---@param range Sql|table
---@return string
function Sql:_get_in_token(cols, op, range)
  if range.__SQL_BUILDER__ then
    return format("(%s) %s (%s)", as_token(cols), op, range:statement())
  else
    return format("(%s) %s %s", as_token(cols), op, as_literal(range))
  end
end

---@private
---@param cols string|string[]
---@param range Sql|table
---@return self
function Sql:_base_where_in(cols, range)
  local in_token = self:_get_in_token(cols, "IN", range)
  if self._where then
    self._where = format("(%s) AND %s", self._where, in_token)
  else
    self._where = in_token
  end
  return self
end

---@private
---@param caller string function name used in error messages (e.g. "where_in")
---@param sql_op string SQL op name used in error messages (e.g. "IN")
---@param cols string|string[]
---@return string|string[] parsed_cols
function Sql:_parse_in_cols(caller, sql_op, cols)
  local function parse(raw, idx)
    local col, op = self:_parse_column(raw)
    assert(op == 'eq', format(
      "%s: column%s=%q carries op '__%s' that conflicts with %s; "
      .. "use where{['%s']=...} for non-%s comparisons",
      caller, idx and ('[' .. idx .. ']') or '', raw, op, sql_op, raw, sql_op))
    return col
  end
  if type(cols) == "string" then
    return parse(cols)
  end
  local res = {}
  for i = 1, #cols do
    res[i] = parse(cols[i], i)
  end
  return res
end

---@param cols string|string[]
---@param range Sql|table
---@return self
function Sql:where_in(cols, range)
  return Sql._base_where_in(self, self:_parse_in_cols("where_in", "IN", cols), range)
end

---@private
---@param cols string|string[]
---@param range Sql|table
---@return self
function Sql:_base_where_not_in(cols, range)
  local not_in_token = self:_get_in_token(cols, "NOT IN", range)
  if self._where then
    self._where = format("(%s) AND %s", self._where, not_in_token)
  else
    self._where = not_in_token
  end
  return self
end

---@param cols string|string[]
---@param range Sql|table
---@return self
function Sql:where_not_in(cols, range)
  return Sql._base_where_not_in(self, self:_parse_in_cols("where_not_in", "NOT IN", cols), range)
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
      return cond(self._join_proxy_models)
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
---@param kwargs {[string]:any}
---@param logic? "AND"|"OR"
---@return string
function Sql:_base_get_condition_token_from_table(kwargs, logic)
  local tokens = {}
  for k, value in pairs(kwargs) do
    tokens[#tokens + 1] = format("%s = %s", k, as_literal(value))
  end
  if logic == nil then
    return concat(tokens, " AND ")
  else
    return concat(tokens, " " .. logic .. " ")
  end
end

-- {{a=1,b=2}, {a=3,b=4}}, {'a','b'} => {{1,2},{3,4}}
---@private
---@param rows Record[]
---@param columns string[]
---@return DBValue[][]
function Sql:_rows_to_array(rows, columns, is_update)
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
      if not is_empty_value(v) then
        res[j][i] = v
      elseif is_update then
        -- 批量更新：保留校验后的空值（'' 或 NULL），不回填模型默认值，避免覆盖已存在行
        res[j][i] = v == nil and NULL or v
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
      insert(columns, k)
      insert(value_list, v)
    end
  else
    for _, col in pairs(columns) do
      local v = row[col]
      if v ~= nil then
        insert(value_list, v)
      else
        insert(value_list, DEFAULT)
      end
    end
  end
  return value_list, columns
end

---make bulk insert VALUES token:
---```lua
---{{a=1,b=2}, {a=3,b=4}} => {'(1,2)', '(3,4)'}, {'a','b'}
---```
---@private
---@param rows Record[]
---@param columns? string[]
---@return string[], string[]
function Sql:_get_bulk_insert_values_token(rows, columns)
  columns = columns or get_keys(rows)
  rows = self:_rows_to_array(rows, columns)
  return map(rows, as_literal), columns
end

---take `key` away from update `columns`, return set token for update
---```lua
---{'a','b', 'c'}, {'b'}, 'V' => 'a = V.a, c = V.c'
---```
---@private
---@param columns string[] columns that need to update
---@param key Keys name or names that need to be taken away from columns
---@param prefix string table name as prefix
---@return string
function Sql:_get_update_token_with_prefix(columns, key, prefix)
  local tokens = {}
  local auto_now = self.model.auto_now_name
  local key_set = {}
  if type(key) == "string" then
    key_set[key] = true
  else
    for _, k in ipairs(key) do
      key_set[k] = true
    end
  end
  for _, col in ipairs(columns) do
    -- key 列不更新；auto_now 列统一在下方置 CURRENT_TIMESTAMP，跳过避免重复赋值
    if not key_set[col] and col ~= auto_now then
      insert(tokens, format("%s = %s.%s", col, prefix, col))
    end
  end
  -- 与单行 update 对齐：批量更新也刷新 auto_now 时间戳
  if auto_now then
    insert(tokens, format("%s = CURRENT_TIMESTAMP", auto_now))
  end
  return concat(tokens, ", ")
end

---get select token
---@private
---@param context ColumnContext
---@param a DBValue|fun(ctx:table):string
---@param b? DBValue
---@param ... DBValue
---@return string
function Sql:_get_column_tokens(context, a, b, ...)
  if b == nil then
    if type(a) == "table" then
      local tokens = {}
      for i = 1, #a do
        tokens[i] = self:_get_column_token(a[i], context)
      end
      return as_token(tokens)
    elseif type(a) == "string" then
      return self:_get_column_token(a, context) --[[@as string]]
    elseif type(a) == 'function' then
      ---@cast a -DBValue
      local select_callback_args = a(self._join_proxy_models)
      if type(select_callback_args) == 'string' then
        return select_callback_args
      elseif type(select_callback_args) == 'table' then
        return concat(select_callback_args, ', ')
      else
        error("wrong type:" .. type(select_callback_args))
      end
    else
      -- select TRUE, 1
      return as_token(a)
    end
  else
    local res = {}
    for i, name in ipairs { a, b, ... } do
      res[#res + 1] = as_token(self:_get_column_token(name, context))
    end
    return concat(res, ", ")
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
    return concat(res, ", ")
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
      insert(kv, format("%s = %s", k, as_literal(v)))
    end
  else
    for _, k in ipairs(columns) do
      local v = row[k]
      -- insert(kv, format("%s = %s", k, v ~= nil and as_literal(v) or 'DEFAULT'))
      if v ~= nil then
        insert(kv, format("%s = %s", k, as_literal(v)))
      end
    end
  end
  local auto_now = self.model.auto_now_name
  if auto_now then
    insert(kv, format("%s = CURRENT_TIMESTAMP", auto_now))
  end
  return concat(kv, ", ")
end

---@private
---@param name string
---@param token string|Sql
---@return string
function Sql:_get_with_token(name, token)
  if type(token) == 'string' then
    return format("%s AS %s", name, token)
  else
    return format("%s AS (%s)", name, token:statement())
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
  local insert_columns = columns
  if not insert_columns then
    if not subsql._select then
      error("subquery must have select clause")
    end
    insert_columns = extract_column_names(subsql._select)
  end
  local columns_token = as_token(insert_columns)
  self._insert = format("(%s) %s", columns_token, subsql:statement())
end

---@private
---@param subsql Sql
---@param columns? string[]
function Sql:_set_cud_subquery_insert_token(subsql, columns)
  -- WITH D(a,b,c) AS (UPDATE T2 SET a=1,b=2,c=3 RETURNING a,b,c) INSERT INTO T1(a,b,c) SELECT a,b,c from D
  local returning_columns = columns
  if not returning_columns then
    if not subsql._returning then
      error("subquery must have returning clause")
    end
    returning_columns = extract_column_names(subsql._returning)
  end
  local columns_token = as_token(returning_columns)
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
    as_token(key))
  if (type(key) == "table" and #key == #insert_columns) or #insert_columns == 1 then
    return format("%s DO NOTHING", insert_token)
  else
    return format("%s DO UPDATE SET %s", insert_token,
      self:_get_update_token_with_prefix(insert_columns, key, "EXCLUDED"))
  end
end

--```lua
-- Blog:upsert {
--   { name = 'My First Blog', tagline = 'updated by upsert' },
--   { name = 'Blog added by upsert', tagline = 'inserted by upsert' },
-- }:exec()
--```
--sql:
--```sql
-- INSERT INTO
--   blog AS T (name, tagline)
-- VALUES
--   ('My First Blog', 'updated by upsert'),
--   ('Blog added by upsert', 'inserted by upsert')
-- ON CONFLICT (name)
-- DO UPDATE
-- SET
--   tagline = EXCLUDED.tagline
--```
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
    as_token(key))
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
function Sql:_set_select_subquery_upsert_token(rows, key, columns)
  local insert_token = format("(%s) %s ON CONFLICT (%s)",
    as_token(columns),
    rows:statement(),
    as_token(key))
  if (type(key) == "table" and #key == #columns) or #columns == 1 then
    self._insert = format("%s DO NOTHING", insert_token)
  else
    self._insert = format("%s DO UPDATE SET %s", insert_token,
      self:_get_update_token_with_prefix(columns, key, "EXCLUDED"))
  end
end

-- ```lua
-- Blog:upsert(
--   BlogBin
--     :update { tagline = 'updated by upsert returning' }
--     :returning {'name', 'tagline'}
-- ):returning{'id','name', 'tagline'}:exec()
-- ```
--yields:
--```sql
-- WITH
--   V (name, tagline) AS (
--     UPDATE blog_bin T
--     SET
--       tagline = 'updated by upsert returning'
--     RETURNING
--       T.name,
--       T.tagline
--   )
-- INSERT INTO
--   blog AS T (name, tagline)
-- SELECT
--   name,
--   tagline
-- FROM
--   V ON CONFLICT (name)
-- DO
-- UPDATE
-- SET
--   tagline = EXCLUDED.tagline
-- RETURNING
--   T.id,
--   T.name,
--   T.tagline
--`
---@private
---@param rows Sql
---@param key Keys
---@param columns string[]
function Sql:_set_cud_subquery_upsert_token(rows, key, columns)
  local cte_name = format("V(%s)", concat(columns, ", "))
  self:with(cte_name, rows)
  local insert_token = format("(%s) %s ON CONFLICT (%s)",
    as_token(columns),
    Sql:new { table_name = 'V', _select = as_token(columns) }:statement(),
    as_token(key))
  if (type(key) == "table" and #key == #columns) or #columns == 1 then
    self._insert = format("%s DO NOTHING", insert_token)
  else
    self._insert = format("%s DO UPDATE SET %s", insert_token,
      self:_get_update_token_with_prefix(columns, key, "EXCLUDED"))
  end
end

--TODO: seems not necessary, remove it later
---@private
---@param subquery Sql
---@param columns? string[]
---@return string
function Sql:_base_get_update_query_token(subquery, columns)
  -- UPDATE T1 SET (a, b) = (SELECT a1, b1 FROM T2 WHERE T1.tid = T2.id);
  local columns_token = as_token(columns or extract_column_names(subquery._select))
  return format("(%s) = (%s)", columns_token, subquery:statement())
end

-- get join condition from key:
-- `A.k = B.k` or `A.k1 = B.k1 AND A.k2 = B.k2`
---@private
---@param key Keys
---@param A string left table name
---@param B string right table name
---@return string join condition
function Sql:_get_join_condition_from_key(key, A, B)
  if type(key) == "string" then
    -- A.k = B.k
    return format("%s.%s = %s.%s", A, key, B, key)
  end
  -- A.k1 = B.k1 AND A.k2 = B.k2
  local res = {}
  for _, k in ipairs(key) do
    res[#res + 1] = format("%s.%s = %s.%s", A, k, B, k)
  end
  return concat(res, " AND ")
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

--TODO: expand * to all columns
---@private
---@param key DBValue
---@param context ColumnContext
---@return DBValue
function Sql:_get_column_token(key, context)
  local field = self.model.fields[key]
  if field then
    local column_token = field._column_token or smart_quote(key)
    if self._as then
      return self._as .. '.' .. column_token
    else
      return self.model._table_name_token .. '.' .. column_token
    end
  elseif type(key) ~= 'string' or key == '*' then
    return key
  else
    local column = self:_parse_column(key, context)
    if context == 'select' or context == 'returning' then
      return column .. ' AS ' .. smart_quote(key)
    else
      return column
    end
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
---@param kwargs {[string]:any}
---@param logic? string
---@return string
function Sql:_get_condition_token_from_table(kwargs, logic)
  local tokens = {}
  for k, value in pairs(kwargs) do
    tokens[#tokens + 1] = self:_get_expr_token(value, self:_parse_column(k))
  end
  if logic == nil then
    return concat(tokens, " AND ")
  else
    return concat(tokens, " " .. logic .. " ")
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
    -- 2-arg form: where('col', value). Operator is explicit (=), so we pass a
    -- non-where context to suppress _parse_column's `__op` operator detection;
    -- 'select' is used because it lives in NON_OPERATOR_CONTEXTS.
    ---@cast cond string
    return format("%s = %s", self:_parse_column(cond, "select"), as_literal(op))
  else
    -- 3-arg form: where('col', op, value). Same reason as above for 'select'.
    ---@cast cond string
    ---@cast op string
    assert(PG_OPERATORS[op:upper()], "invalid PostgreSQL operator: " .. op)
    return format("%s %s %s", self:_parse_column(cond, "select"), op, as_literal(dval))
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
---@param cond {[string]: DBValue}|QClass
---@return string
function Sql:_get_having_condition_token(cond)
  if cond.__IS_LOGICAL_BUILDER__ then
    return self:_resolve_Q(cond, "having")
  end
  local tokens = {}
  for key, value in pairs(cond) do
    tokens[#tokens + 1] = self:_get_expr_token(value, self:_parse_having_column(key))
  end
  return concat(tokens, " AND ")
end

---@private
---@param other_sql Sql
---@param set_operation_attr SqlSet
---@return self
function Sql:_handle_set_operation(other_sql, set_operation_attr)
  if not self[set_operation_attr] then
    self[set_operation_attr] = other_sql:statement();
  else
    self[set_operation_attr] = format("(%s) %s (%s)",
      self[set_operation_attr],
      PG_SET_MAP[set_operation_attr],
      other_sql:statement());
  end
  self._set_operation = true
  return self;
end

---@private
function Sql:_resolve_F(value)
  if type(value) == 'table' and value.__IS_FIELD_BUILDER__ then
    local exp_token = self:_resolve_field_builder(value)
    return function()
      return exp_token
    end
  end
  return value
end

---@private
---@param columns? string[]
---@return Keys
function Sql:_get_bulk_key(columns, is_update)
  -- 批量更新优先用主键：唯一字段在 payload 里是新值，拿它当匹配键会匹配不到旧行
  if is_update and self.model.primary_key then
    return self.model.primary_key
  end
  if self.model.unique_together and self.model.unique_together[1] then
    return clone(self.model.unique_together[1])
  end
  for _, name in ipairs(columns or self.model.names) do
    local f = self.model.fields[name]
    if f and f.unique then
      return name
    end
  end
  local pk = self.model.primary_key
  return pk
end

---@private
---@param rows Record|Record[]
---@param key? string|string[]
---@param columns? string[]
---@param is_update? boolean whether used in update clause
---@return Record[], string|string[], string[]
function Sql:_clean_bulk_params(rows, key, columns, is_update)
  if isempty(rows) then
    error("empty rows passed to merge")
  end
  if not rows[1] then
    rows = { rows }
  end
  if columns == nil then
    -- auto_now 列无须掺入 columns：_get_update_token_with_prefix 总会
    -- 追加 `utime = CURRENT_TIMESTAMP`，掺入只会给 CTE 添一列 NULL
    columns = get_keys(rows)
    if #columns == 0 then
      error("no columns provided for bulk")
    end
  end
  if key == nil then
    -- is_update is true when updates, means searching key among columns extracted from rows
    -- so to ensure primary key is the fallback key (not unique field)
    key = self:_get_bulk_key(is_update and columns or nil, is_update)
  end
  if type(key) == 'string' then
    assert(self.model.fields[key], "invalid key for bulk operation: " .. key)
    if not Array.includes(columns, key) then
      columns = { key, unpack(columns) }
    end
  elseif type(key) == 'table' then
    for _, k in ipairs(key) do
      assert(self.model.fields[k], "invalid key for bulk operation: " .. k)
      if not Array.includes(columns, k) then
        columns = { k, unpack(columns) }
      end
    end
  else
    error("invalid key type for bulk:" .. type(key))
  end
  return rows, key, columns
end

---@private
---@param value DBValue
---@param key string
---@param op string
---@return string
function Sql:_get_expr_token(value, key, op)
  -- https://docs.djangoproject.com/en/5.1/ref/models/querysets/#field-lookups
  value = self:_resolve_F(value)
  local handler = EXPR_OPERATORS[op]
  if not handler then
    error("invalid sql op: " .. tostring(op))
  end
  return handler(key, value)
end

--TODO: need to support F?
---@private
---@param key DBValue
---@return DBValue
function Sql:_get_order_column(key)
  if type(key) ~= 'string' then
    return key
  else
    -- local matched = match(key, '^([-+])?([\\w_.]+)$', 'josui')
    local a, b = key:match("^([-+]?)([%w_]+)$")
    if a or b then
      local column = self:_parse_column(b, "order_by")
      local direction = a == '-' and 'DESC' or 'ASC'
      local nulls_clause = ""

      if self._nulls_first then
        nulls_clause = " NULLS FIRST"
      elseif self._nulls_last then
        nulls_clause = " NULLS LAST"
      end

      return format("%s %s%s", column, direction, nulls_clause)
    else
      error(format("invalid order arg format: %s", key))
    end
  end
end

---@private
---@param a string|table|fun(ctx:table):string
---@param b? string|FClass
---@param ...? string|FClass
---@return string
function Sql:_get_order_columns(a, b, ...)
  if b == nil then
    if type(a) == "table" then
      local tokens = {}
      for i = 1, #a do
        tokens[i] = self:_get_order_column(a[i])
      end
      return as_token(tokens)
    elseif type(a) == "string" then
      return self:_get_order_column(a) --[[@as string]]
    elseif type(a) == 'function' then
      ---@cast a -DBValue
      local select_callback_args = a(self._join_proxy_models)
      if type(select_callback_args) == 'string' then
        return select_callback_args
      elseif type(select_callback_args) == 'table' then
        return concat(select_callback_args, ', ')
      else
        error("wrong type:" .. type(select_callback_args))
      end
    else
      return as_token(a)
    end
  else
    local res = {}
    for i, name in ipairs { a, b, ... } do
      res[#res + 1] = as_token(self:_get_order_column(name))
    end
    return concat(res, ", ")
  end
end

---@private
---@param q QClass
---@param context? "where"|"having"
---@return string
function Sql:_resolve_Q(q, context)
  -- 递归必须透传 context：having(Q{...}*Q{...}) 的复合分支若掉回 where 解析，
  -- FK 遍历会额外造 JOIN，与 having 别名解析路径产生分歧
  if q.logic == "NOT" then
    return format("NOT (%s)", self:_resolve_Q(q.left, context))
  elseif q.left and q.right then
    local left_token = self:_resolve_Q(q.left, context)
    local right_token = self:_resolve_Q(q.right, context)
    return format("(%s) %s (%s)", left_token, q.logic, right_token)
  elseif context == nil or context == "where" then
    return self:_get_condition_token_from_table(q.cond, q.logic)
  elseif context == "having" then
    return self:_get_having_condition_token(q.cond)
  else
    error("invalid context: " .. tostring(context))
  end
end

---@private
---@param keys Record[]
---@param columns? string[]
---@return self
function Sql:_base_gets(keys, columns)
  columns = columns or get_keys(keys)
  keys = self.model:_prepare_db_rows(keys, columns)
  keys = self:_get_cte_values_literal(keys, columns)
  local join_cond = self:_get_join_condition_from_key(columns, "V", self._as or self.table_name)
  local cte_name = format("V(%s)", concat(columns, ", "))
  local cte_values = format("(VALUES %s)", as_token(keys))
  return self:with(cte_name, cte_values):_base_join("RIGHT", "V", join_cond)
end

function Sql:_array_to_values(row, columns, no_check, type_suffix)
  for i, col in ipairs(columns) do
    local field = self.model.fields[col]
    if field then
      if type_suffix then
        row[i] = format("%s::%s", as_literal(row[i]), field.db_type)
      else
        row[i] = as_literal(row[i])
      end
    elseif no_check then
      row[i] = as_literal(row[i])
    else
      error("error constructing cte values literal, invalid field name: " .. col)
    end
  end
  return '(' .. as_token(row) .. ')'
end

---@private
---@param key string column name
---@param context? ColumnContext
---@return string resolved_column
---@return string operator
function Sql:_parse_column(key, context)
  local model = self.model
  local fast_field = model.fields[key]
  if fast_field then
    local prefix = self._as or model._table_name_token
    return prefix .. '.' .. (fast_field._column_token or smart_quote(key)), 'eq'
  end
  local i = 1
  local op = 'eq'
  local a, b, token, join_key, prefix, column, final_column, last_field, last_token, last_model, json_keys
  while true do
    a, b = key:find("__", i, true)
    if not a then
      token = key:sub(i)
    else
      token = key:sub(i, a - 1)
    end
    -- print('token', token, self.model.table_name)
    -- column might be changed in the loop
    local field = model.fields[token]
    if field then
      -- 1. fields from model itself, highest priority
      if not last_field then
        -- 1.1 first column, the most case
        -- print('1.1', model.class_name, token)
        column = token
        prefix = self._as or model._table_name_token
      elseif json_keys then
        -- 1.2 json field search: token happens to be a model field name but we
        -- are already inside a jsonb path, so treat it as a json path segment.
        -- https://docs.djangoproject.com/en/4.2/topics/db/queries/#querying-jsonfield
        -- print('1.2', model.class_name, token)
        if json_operators[token] or EXPR_OPERATORS[token] then
          -- terminal op: stop traversing, post-loop will build the json path
          op = token
          break
        else
          json_keys[#json_keys + 1] = token
        end
      elseif last_model.reversed_fields[last_token] then
        -- 1.3 field on the reversed-model side: Blog:where{entry__rating}
        -- The reverse join was created by branch 4 in the previous iter; here
        -- we just point `column` at the current segment (prefix already alias).
        -- print('1.3', model.class_name, token)
        column = token
      elseif last_field.reference then
        -- 1.4 foreignkey model's field, may need a join
        if token == last_field.reference_column then
          -- 1.4.1 blog_id__id => redundant FK suffix, rollback to the FK column.
          -- Preserve `field = last_field` so the loop bottom's
          -- `last_field = field` keeps the FK context — otherwise a trailing
          -- segment like blog_id__id__notop would report errors against the
          -- PK field and lose the originating FK chain (BUG B4).
          -- print('1.4.1', model.class_name, token)
          column = last_token
          token = last_token -- in case of blog_id__id__gt
          field = last_field
        else
          -- 1.4.2 blog_id__name => need a join
          -- print('1.4.2', model.class_name, last_token or '/', token)
          column = token
          local parent_join_key -- left side of the new join (nil = main table)
          if not join_key then
            -- prefix with foreignkey name because a model can be referenced multiple times by the same model
            -- such as: Entry:where{blog_id__name='Tom', reposted_blog_id__name='Kate'}
            join_key = last_token
          else
            parent_join_key = join_key
            join_key = join_key .. "__" .. last_token
          end
          if not self._join_keys then
            self._join_keys = {}
          end
          prefix = self._join_keys[join_key]
          if not prefix then
            local function join_cond_cb(ctx)
              local left_proxy = ctx[parent_join_key or 1]
              local left_column = left_proxy[last_token]
              if not left_column then
                error(last_token .. " is a invalid column for " .. left_proxy[1])
              end
              local right_column = ctx[join_key][last_field.reference_column]
              return format("%s = %s", left_column, right_column)
            end
            local join_type
            if context == 'aggregate' then
              join_type = "LEFT"
            else
              join_type = self._join_type or "INNER"
            end
            prefix = self:_handle_manual_join(join_type, model, join_cond_cb, join_key)
          end
        end
      else
        -- print('1.5: token IS a valid field on `model`, but the previous segment')
        -- (`last_token`) is not a foreignkey / jsonb / reverse-fk, so the
        -- traversal is malformed.
        error(format(
          "cannot traverse to '%s' through '%s' on model '%s' (previous segment is not a foreignkey, jsonb, or reverse-fk)",
          token, last_token, last_model.class_name))
      end
      last_model = model
      if field.reference then
        model = field.reference
      end
      if not json_keys and (field.model or field.db_type == 'jsonb') then
        json_keys = {}
      end
    elseif self._annotate and self._annotate[token] then
      -- 2. name that's registered in annotate:
      -- Blog:annotate{cnt=Count('entry')}:where{cnt__lt=2}:group_by{'name'}
      -- The annotation expands to a full SQL expression (Count(...), F('price')
      -- * 10), not a column — so the only valid continuation is a single
      -- trailing operator (cnt__gte=1). Traversal *into* the annotation makes
      -- no sense and used to be silently dropped (BUG B2), reject it here.
      -- print('2', model.class_name, token)
      final_column = self._annotate[token]
      if a then
        local rest = key:sub(b + 1)
        if EXPR_OPERATORS[rest] then
          op = rest
        else
          error(format(
            "cannot traverse into annotation '%s' on model '%s': "
            .. "only a single trailing operator is allowed, got '%s' (full key: '%s')",
            token, model.class_name, rest, key))
        end
      end
      break
    elseif json_keys then
      -- 3. attributes from a json field
      -- Blog.where{data__a='x'}         => WHERE (... "data" -> 'a')        = '"x"'
      -- Blog.where{data__a__contains=...} => WHERE (... "data" -> 'a')      @> '...'
      -- Blog.where{data__a__gt=5}       => WHERE (... "data" -> 'a')        > '5'
      -- Blog.where{data__a__startswith='x'} => WHERE (... "data" ->> 'a') LIKE 'x%'
      -- print('3', model.class_name, token)
      if json_operators[token] or EXPR_OPERATORS[token] then
        -- terminal op: stop traversing, post-loop builds the json LHS
        op = token
        break
      else
        json_keys[#json_keys + 1] = token
      end
    else
      -- Blog:where{entry__rating=1}
      local reversed_field = model.reversed_fields[token] -- Entry.blog_id, Blog:where{entry=1}
      if reversed_field then
        -- 4. reversed foreignkey, join from current loop
        -- token = entry, reversed_name = blog_id
        -- print('4', model.class_name, token)
        -- Fix: if the previous segment was a forward FK whose target wasn't
        -- materialized yet (1.3 path skipped the join because at that point we
        -- only needed the FK column itself), we MUST add the forward join now,
        -- otherwise the reverse join below would anchor on the wrong table.
        -- Example: Blog:where{entry__blog_id__entry__rating=5} requires a
        -- Blog T2 join between entry T1 and the second entry T3 (Django parity:
        -- 3 joins total).
        if last_field and last_field.reference == model then
          local fk_join_key = (join_key and (join_key .. "__" .. last_token)) or last_token
          if not self._join_keys or not self._join_keys[fk_join_key] then
            local left_anchor = join_key
            local function fk_join_cb(ctx)
              return format("%s = %s",
                ctx[left_anchor or 1][last_token],
                ctx[fk_join_key][last_field.reference_column])
            end
            local fix_join_type
            if context == 'aggregate' then
              fix_join_type = "LEFT"
            else
              fix_join_type = self._join_type or "INNER"
            end
            self:_handle_manual_join(fix_join_type, model, fk_join_cb, fk_join_key)
          end
          join_key = fk_join_key
        end
        local reversed_model = reversed_field:get_model() -- Entry
        -- loger(token, model.table_name, reversed_model.table_name, reversed_field.name)
        if not join_key then
          join_key = token
        else
          join_key = join_key .. "__" .. token
        end
        if not self._join_keys then
          self._join_keys = {}
        end
        prefix = self._join_keys[join_key]
        if not prefix then
          local function join_cond_cb(ctx)
            local left_model_index
            if token == join_key then
              left_model_index = 1
            else
              left_model_index = #ctx - 1
            end
            return format("%s = %s",
              ctx[left_model_index][reversed_field.reference_column],
              ctx[#ctx][reversed_field.name])
          end
          local join_type
          if context == 'aggregate' then
            join_type = "LEFT"
          else
            join_type = self._join_type or "INNER"
          end
          prefix = self:_handle_manual_join(join_type, reversed_model, join_cond_cb, join_key)
        end
        column = reversed_model.primary_key
        field = reversed_field
        last_model = model
        model = reversed_model
      elseif last_token then
        -- 5. operator, write back
        -- print('5', model.class_name, token)
        if context == nil or not NON_OPERATOR_CONTEXTS[context] then -- where or having or Q
          -- 5.1 should be operator, check it
          if not EXPR_OPERATORS[token] then
            error(format(
              "invalid operator '%s' after column '%s' on model '%s' (full key: '%s')",
              token, last_token, model.class_name, key))
          end
        else
          -- 5.2 select/returning etc context, shouldn't reach here
          error(format(
            "invalid column segment '%s' after '%s' on model '%s' (full key: '%s') in %s context",
            token, last_token, model.class_name, key, context))
        end
        op = token
        column = last_token
        break
      else
        error(format("invalid column name '%s' for model '%s'", token, model.class_name))
      end
    end
    if not a then
      break
    end
    last_token = token
    last_field = field
    i = b + 1
  end
  if json_keys then
    -- Text ops (LIKE, regex, date extraction) need text extraction (->> / #>>)
    -- so PG operators that require text can apply directly. Other ops keep the
    -- jsonb extract (-> / #>) and route through json_* variants that encode the
    -- RHS as JSON literal, so PG can do jsonb-vs-jsonb comparison.
    local arrow_one, arrow_many
    if JSON_TEXT_OPS[op] then
      arrow_one, arrow_many = "->>", "#>>"
    else
      arrow_one, arrow_many = "->", "#>"
    end
    local quoted_col = prefix .. '.' .. smart_quote(column)
    if #json_keys == 1 then
      local k = json_keys[1]
      -- Django 对齐：单段整数样式按数组下标（-> 0 / ->> 0），字符串键才用
      -- 文本（-> 'k'）；对象的 "0" 这类数字字符串键与 Django 一样不支持直查。
      -- 多段路径无须处理：#> 的 text[] 在数组语境自动把数字串当下标。
      if k:match("^%-?%d+$") then
        final_column = format("%s %s %s", quoted_col, arrow_one, k)
      else
        final_column = format("%s %s %s", quoted_col, arrow_one, as_literal(k))
      end
    elseif #json_keys > 1 then
      final_column = format("%s %s ARRAY[%s]", quoted_col, arrow_many,
        as_literal_without_brackets(json_keys))
    end
    if JSON_OP_MAP[op] then
      op = JSON_OP_MAP[op]
    end
  end
  return final_column or (prefix .. '.' .. smart_quote(column)), op
end

---@private
---@param key string column
---@return string, string
function Sql:_parse_having_column(key)
  local a, b = key:find("__", 1, true)
  if not a then
    return self:_get_having_column(key), "eq"
  end
  local token = key:sub(1, a - 1)
  local op = key:sub(b + 1)
  -- HAVING references a group-by column or an aggregate alias; nested traversal
  -- (cnt__nope__gte) makes no sense here and used to slip through as op =
  -- "nope__gte" → "invalid sql op" downstream (BUG B1). Reject it up front.
  if op:find("__", 1, true) then
    error(format(
      "invalid having key '%s': nested traversal is not supported, "
      .. "use 'alias__op' (e.g. 'cnt__gte') only", key))
  end
  if not EXPR_OPERATORS[op] then
    error(format("invalid having operator '%s' in key '%s'", op, key))
  end
  return self:_get_having_column(token), op
end

---@private
---@param key string
---@return string
function Sql:_get_having_column(key)
  if self._annotate then
    local res = self._annotate[key]
    if res ~= nil then
      return res
    end
  end
  -- fall back to a regular model column reference, so usages like
  --   :group_by{'name'}:having{name__startswith='a'}
  -- or HAVING expressions over plain columns (Postgres allows this when
  -- the column appears in GROUP BY) work without going through annotate.
  local field = self.model.fields[key]
  if field then
    local prefix = self._as or self.model._table_name_token
    return prefix .. '.' .. (field._column_token or smart_quote(key))
  end
  error(format("invalid alias or column for having: '%s'", key))
end

---@private
---@param f FClass|DBValue
---@return string
function Sql:_resolve_field_builder(f)
  if type(f) ~= 'table' then
    return as_literal(f)
  elseif f.column then
    return (self:_parse_column(f.column))
  else
    return format("(%s %s %s)",
      self:_resolve_field_builder(f.left),
      f.operator,
      self:_resolve_field_builder(f.right))
  end
end

-- =========================================================================
-- Public APIs
-- =========================================================================

---@param attrs? table
---@return self
function Sql:new(attrs)
  return setmetatable(attrs or {}, self)
end

---@param ... Sql|string
---@return self
function Sql:prepend(...)
  if not self._prepend then
    self._prepend = {}
  end
  local n = select("#", ...)
  for i = n, 1, -1 do
    local e = select(i, ...)
    insert(self._prepend, 1, e)
  end
  return self
end

---@param ... Sql|string
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
    offset = self._offset,
    for_update = self._for_update,
    for_update_nowait = self._for_update_nowait,
    for_update_skip_locked = self._for_update_skip_locked,
    for_update_of = self._for_update_of_raw and self:_resolve_for_update_of() or nil,
    for_update_no_key = self._for_update_no_key,
  }
  if self._set_operation then
    if self._intersect then
      statement = format("(%s) INTERSECT (%s)", statement, self._intersect)
    elseif self._intersect_all then
      statement = format("(%s) INTERSECT ALL (%s)", statement, self._intersect_all)
    elseif self._union then
      statement = format("(%s) UNION (%s)", statement, self._union)
    elseif self._union_all then
      -- 这种情况必须加上括号，否则报错
      -- (SELECT id FROM t1 ORDER BY id LIMIT 2)
      -- UNION ALL
      -- SELECT id FROM t2;
      -- 又不能加,因为statement包含with的时候with又必须在括号外面. 先照顾with, 以后再想办法.
      statement = format("%s UNION ALL (%s)", statement, self._union_all)
    elseif self._except then
      statement = format("(%s) EXCEPT (%s)", statement, self._except)
    elseif self._except_all then
      statement = format("(%s) EXCEPT ALL (%s)", statement, self._except_all)
    end
  end
  if self._prepend then
    local res = {}
    for _, sql in ipairs(self._prepend) do
      if type(sql) == 'string' then
        res[#res + 1] = sql
      else
        res[#res + 1] = sql:statement()
      end
    end
    statement = concat(res, ';') .. ';' .. statement
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
    statement = statement .. ';' .. concat(res, ';')
  end
  return statement
end

---@param name string
---@param token string|Sql
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
---@param token string|Sql
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
  return self:_handle_set_operation(other_sql, "_union");
end

---@param other_sql Sql
---@return self
function Sql:union_all(other_sql)
  return self:_handle_set_operation(other_sql, "_union_all");
end

---@param other_sql Sql
---@return self
function Sql:except(other_sql)
  return self:_handle_set_operation(other_sql, "_except");
end

---@param other_sql Sql
---@return self
function Sql:except_all(other_sql)
  return self:_handle_set_operation(other_sql, "_except_all");
end

---@param other_sql Sql
---@return self
function Sql:intersect(other_sql)
  return self:_handle_set_operation(other_sql, "_intersect");
end

---@param other_sql Sql
---@return self
function Sql:intersect_all(other_sql)
  return self:_handle_set_operation(other_sql, "_intersect_all");
end

---@param table_alias string
---@return self
function Sql:as(table_alias)
  if table_alias then
    self._as = smart_quote(table_alias)
  else
    self._as = nil
  end
  return self
end

---@param name string
---@param rows Record[]
---@return self
function Sql:with_values(name, rows)
  local columns = get_keys(rows)
  -- create_sql_as is not suitable for this case, because it will treat non-existed columns as error
  -- rows = self.model:_prepare_db_rows(rows, columns)
  local cte_rows = self:_get_cte_values_literal(rows, columns, true)
  local cte_name = format("%s(%s)", name, concat(columns, ", "))
  local cte_values = format("(VALUES %s)", as_token(cte_rows))
  return self:with(cte_name, cte_values)
end

--```lua
-- Blog:select("name"):merge_gets({ { id = 1, name = 'aa' }, { id = 2, name = 'bb' }, }, 'id')
--```
-- yield:
--```sql
-- WITH
--   V (id, name) AS (
--     VALUES
--       (1::integer, 'aa'::varchar),
--       (2, 'bb')
--   )
-- SELECT
--   T.name,
--   V.*
-- FROM
--   blog T
--   RIGHT JOIN V ON (V.id = T.id)
--```
---@param rows Record[]
---@param key Keys
---@param columns? string[]
---@return self|Record[]
function Sql:merge_gets(rows, key, columns)
  columns = columns or get_keys(rows)
  rows = self.model:_prepare_db_rows(rows, columns)
  local cte_rows = self:_get_cte_values_literal(rows, columns, true)
  local join_cond = self:_get_join_condition_from_key(key, "V", self._as or self.table_name)
  local cte_name = format("V(%s)", concat(columns, ", "))
  local cte_values = format("(VALUES %s)", as_token(cte_rows))
  self:_base_select("V.*"):with(cte_name, cte_values):_base_join("RIGHT", "V", join_cond)
  return self
end

---@return self
function Sql:copy()
  local copy_sql = {}
  for key, value in pairs(self) do
    if key == 'model' then
      -- model 是共享的类引用：clone 会丢元表和身份，
      -- 破坏 fk.reference == self.model 这类比较（如 where_recursive）
      copy_sql[key] = value
    elseif type(value) == 'table' then
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

---@param a DBValue|fun(ctx:table):string
---@param b? DBValue
---@param ...? DBValue
---@return self
function Sql:select(a, b, ...)
  local s = self:_get_column_tokens("select", a, b, ...)
  if not self._select then
    self._select = s
  else
    self._select = self._select .. ", " .. s
  end
  return self
end

---@param kwargs {[string]: string}|string
---@param as? string
---@return self
function Sql:select_as(kwargs, as)
  if type(kwargs) == 'string' then
    ---@cast as string
    kwargs = { [kwargs] = as }
  end
  local cols = {}
  for key, alias in pairs(kwargs) do
    local col = self:_parse_column(key) .. ' AS ' .. smart_quote(alias)
    cols[#cols + 1] = col
  end
  if #cols > 0 then
    if not self._select then
      self._select = concat(cols, ", ")
    else
      self._select = self._select .. ", " .. concat(cols, ", ")
    end
  end
  return self
end

---@param a DBValue
---@param b? DBValue
---@param ...? DBValue
---@return self
function Sql:select_literal(a, b, ...)
  local s = self:_get_select_literal(a, b, ...)
  if not self._select then
    self._select = s
  else
    self._select = self._select .. ", " .. s
  end
  return self
end

---@param kwargs {string: string}
---@return self
function Sql:select_literal_as(kwargs)
  local cols = {}
  for key, alias in pairs(kwargs) do
    local col = as_literal(key) .. ' AS ' .. smart_quote(alias)
    cols[#cols + 1] = col
  end
  if #cols > 0 then
    if not self._select then
      self._select = concat(cols, ", ")
    else
      self._select = self._select .. ", " .. concat(cols, ", ")
    end
  end
  return self
end

---@param a DBValue|fun(ctx:table):string
---@param b? DBValue
---@param ...? DBValue
---@return self
function Sql:returning(a, b, ...)
  local s = self:_get_column_tokens("returning", a, b, ...)
  if not self._returning then
    self._returning = s
  else
    self._returning = self._returning .. ", " .. s
  end
  return self
end

---@param a DBValue
---@param b? DBValue
---@param ...? DBValue
---@return self
function Sql:returning_literal(a, b, ...)
  local s = self:_get_select_literal(a, b, ...)
  if not self._returning then
    self._returning = s
  else
    self._returning = self._returning .. ", " .. s
  end
  return self
end

---@param a string
---@param ... string
function Sql:group(a, ...)
  local s = self:_get_column_tokens("group_by", a, ...)
  if not self._group then
    self._group = s
  else
    self._group = self._group .. ", " .. s
  end
  --** by default, group by columns are selected (dedup against existing select)
  if not self._select then
    self:select(a, ...)
  else
    -- 用 select 语境重新生成 token（保留 AS 别名），只追加尚未选择的列
    local select_token = self:_get_column_tokens("select", a, ...)
    local haystack = ", " .. self._select .. ","
    for _, token in ipairs(Utils.split_string(select_token, ", ")) do
      local needle = ", " .. token .. ","
      if not haystack:find(needle, 1, true) then
        self._select = self._select .. ", " .. token
        haystack = haystack .. " " .. token .. ","
      end
    end
  end
  return self
end

function Sql:group_by(...) return self:group(...) end

---@return self
function Sql:nulls_first()
  self._nulls_first = true
  self._nulls_last = nil -- Clear the opposite setting
  return self
end

---@return self
function Sql:nulls_last()
  self._nulls_last = true
  self._nulls_first = nil -- Clear the opposite setting
  return self
end

---@param a string|table|fun(ctx:table):string
---@param ...? string|FClass
---@return self
function Sql:order(a, ...)
  local s = self:_get_order_columns(a, ...)
  if not self._order then
    self._order = s
  else
    self._order = self._order .. ", " .. s
  end
  return self
end

function Sql:order_by(...) return self:order(...) end

---@private
---@param order_str string
---@return string
function Sql:_reverse_order_token(order_str)
  local parts = {}
  for part in order_str:gmatch("[^,]+") do
    part = part:match("^%s*(.-)%s*$")
    local nulls = ""
    if part:match("NULLS FIRST") then
      part = part:gsub("%s*NULLS FIRST", "")
      nulls = " NULLS LAST"
    elseif part:match("NULLS LAST") then
      part = part:gsub("%s*NULLS LAST", "")
      nulls = " NULLS FIRST"
    end
    if part:match("DESC$") then
      part = part:gsub("DESC$", "ASC")
    elseif part:match("ASC$") then
      part = part:gsub("ASC$", "DESC")
    else
      part = part .. " DESC"
    end
    parts[#parts + 1] = part .. nulls
  end
  return concat(parts, ", ")
end

---@return self
function Sql:reverse()
  if self._order then
    self._order = self:_reverse_order_token(self._order)
  end
  return self
end

---@param ... string
function Sql:using(...)
  return self:_base_using(...)
end

---@param ... string
---@return self
function Sql:from(...)
  local s = get_list_tokens(...)
  if not self._from then
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

---@param n integer|string
---@return self
function Sql:limit(n)
  if type(n) == "string" then
    n = assert(tonumber(n), "invalid limit value: not a valid number")
  end

  if type(n) ~= "number" or n ~= math.floor(n) or n <= 0 or n > self.MAX_LIMIT then
    error("invalid limit value: " .. tostring(n))
  end
  self._limit = n
  return self
end

---@param n integer|string
---@return self
function Sql:offset(n)
  -- 如果是字符串类型，尝试转换为数字
  if type(n) == "string" then
    n = assert(tonumber(n), "invalid offset value: not a valid number")
  end

  if type(n) ~= "number" or n ~= math.floor(n) or n < 0 then
    error("invalid offset value: " .. tostring(n))
  end
  self._offset = n
  return self
end

---@param cond table|string|fun(ctx:table):string
---@param op? string
---@param dval? DBValue
---@return self
function Sql:exclude(cond, op, dval)
  local where_token
  if type(cond) == 'table' then
    if not cond.__IS_LOGICAL_BUILDER__ then
      where_token = Sql._get_condition_token_from_table(self, cond)
    else
      ---@cast cond QClass
      where_token = self:_resolve_Q(cond)
    end
  else
    where_token = self:_get_condition_token(cond, op, dval)
  end
  if where_token ~= "" then
    where_token = format("NOT (%s)", where_token)
  end
  return self:_handle_where_token(where_token, "(%s) AND (%s)")
end

---@param cond table|string|fun(ctx:table):string
---@param op? string
---@param dval? DBValue
---@return self
function Sql:where(cond, op, dval)
  if type(cond) == 'table' then
    if not cond.__IS_LOGICAL_BUILDER__ then
      local where_token = Sql._get_condition_token_from_table(self, cond)
      return self:_handle_where_token(where_token, "(%s) AND (%s)")
    else
      ---@cast cond QClass
      local where_token = self:_resolve_Q(cond)
      return self:_handle_where_token(where_token, "(%s) AND (%s)")
    end
  else
    local where_token = self:_get_condition_token(cond, op, dval)
    return self:_handle_where_token(where_token, "(%s) AND (%s)")
  end
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
function Sql:or_where(cond, op, dval)
  local where_token = self:_get_condition_token(cond, op, dval)
  return self:_handle_where_token(where_token, "%s OR %s")
end

---@param cond {[string]: DBValue}|QClass
function Sql:having(cond)
  if self._having then
    self._having = format("(%s) AND (%s)", self._having, self:_get_having_condition_token(cond))
  else
    self._having = self:_get_having_condition_token(cond)
  end
  return self
end

---@param ... string distinct or distinct on specific columns
---@return self
function Sql:distinct(...)
  -- PG requires: SELECT DISTINCT ON expressions must match initial ORDER BY expressions
  -- so you'd better use order_by first
  if select('#', ...) == 0 then
    self._distinct = true
  else
    local distinct_token = self:_get_column_tokens("distinct", ...)
    self._distinct_on = distinct_token
  end
  return self
end

---@param ... DBValue
---@return self
function Sql:distinct_on(...)
  local s = self:_get_column_tokens("distinct", ...)
  self._distinct_on = s
  if self._order then
    self._order = s .. ", " .. self._order
  else
    self._order = s
  end
  return self
end

---@return self
function Sql:none()
  self._where = "FALSE"
  return self
end

---@param opts? {nowait?: boolean, skip_locked?: boolean, of?: string|string[], no_key?: boolean}
---@return self
function Sql:select_for_update(opts)
  opts = opts or {}
  self._for_update = true
  self._for_update_nowait = opts.nowait
  self._for_update_skip_locked = opts.skip_locked
  self._for_update_no_key = opts.no_key
  local of = opts.of
  if of then
    if type(of) == 'string' then
      self._for_update_of_raw = { of }
    else
      ---@cast of string[]
      self._for_update_of_raw = of
    end
  end
  return self
end

---@private
---@return string
function Sql:_resolve_for_update_of()
  local raw = self._for_update_of_raw
  if not raw then
    return ""
  end
  local resolved = {}
  for i, name in ipairs(raw) do
    if name == 'self' then
      resolved[i] = smart_quote(self._as or self.table_name)
    elseif self._join_keys and self._join_keys[name] then
      resolved[i] = self._join_keys[name]
    else
      if type(name) ~= 'string' or not name:match("^[%w_]+$") then
        error("invalid select_for_update `of` target: " .. tostring(name))
      end
      resolved[i] = name
    end
  end
  return concat(resolved, ", ")
end

---Returns a *copy* of the current Sql builder, mirroring Django's `QuerySet.all()`:
---useful when you want to fork a base query and apply different filters on each
---branch without mutating the original.
---@return self
function Sql:all()
  return self:copy()
end

---@param name string|table
---@param amount? number
---@return self
function Sql:increase(name, amount)
  if type(name) == 'table' then
    local update_pairs = {}
    for k, v in pairs(name) do
      update_pairs[k] = F(k) + (v or 1)
    end
    return self:update(update_pairs)
  end
  return self:update { [name] = F(name) + (amount or 1) }
end

---@param name string|table
---@param amount? number
---@return self
function Sql:decrease(name, amount)
  if type(name) == 'table' then
    local update_pairs = {}
    for k, v in pairs(name) do
      update_pairs[k] = F(k) - (v or 1)
    end
    return self:update(update_pairs)
  end
  return self:update { [name] = F(name) - (amount or 1) }
end

---@param kwargs {[string]:table}
function Sql:annotate(kwargs)
  if not self._annotate then
    self._annotate = {}
  end
  for alias, func in pairs(kwargs) do
    if type(alias) == 'number' then
      alias = func.column .. func.suffix
    end
    if self.model.fields[alias] then
      error(format("annotate name '%s' is conflict with model field", alias))
    elseif func.__IS_FUNCTION__ then
      local prefixed_column = self:_parse_column(func.column, "aggregate")
      local func_token = format("%s(%s)", func.name, prefixed_column)
      -- self._annotate[alias] = { func_token = func_token, func = func, reversed = reversed }
      self._annotate[alias] = func_token
      self:_base_select(format("%s AS %s", func_token, smart_quote(alias)))
    elseif func.__IS_FIELD_BUILDER__ then
      local exp_token = self:_resolve_field_builder(func)
      self._annotate[alias] = exp_token
      -- if not self._computed_columns then
      --   self._computed_columns = {}
      -- end
      -- self._computed_columns[alias] = exp_token
      self:_base_select(format("%s AS %s", exp_token, smart_quote(alias)))
    end
  end
  return self
end

---@param kwargs {[string]:table}
---@return self
function Sql:alias(kwargs)
  if not self._annotate then
    self._annotate = {}
  end
  for alias, func in pairs(kwargs) do
    if type(alias) == 'number' then
      alias = func.column .. func.suffix
    end
    if self.model.fields[alias] then
      error(format("alias name '%s' is conflict with model field", alias))
    elseif func.__IS_FUNCTION__ then
      local prefixed_column = self:_parse_column(func.column, "aggregate")
      self._annotate[alias] = format("%s(%s)", func.name, prefixed_column)
    elseif func.__IS_FIELD_BUILDER__ then
      self._annotate[alias] = self:_resolve_field_builder(func)
    end
  end
  return self
end

---@param kwargs {[string]:table}
---@return table
function Sql:aggregate(kwargs)
  local select_parts = {}
  for alias, func in pairs(kwargs) do
    if type(alias) == 'number' then
      alias = func.column .. func.suffix
    end
    if func.__IS_FUNCTION__ then
      local prefixed_column = self:_parse_column(func.column, "aggregate")
      select_parts[#select_parts + 1] = format("%s(%s) AS %s", func.name, prefixed_column, smart_quote(alias))
    elseif func.__IS_FIELD_BUILDER__ then
      local exp_token = self:_resolve_field_builder(func)
      select_parts[#select_parts + 1] = format("%s AS %s", exp_token, smart_quote(alias))
    else
      error("aggregate values must be Func or F instances")
    end
  end
  self._select = concat(select_parts, ", ")
  local records = self:raw():exec()
  if records and records[1] then
    return records[1]
  end
  return {}
end

---@param rows Record|Record[]|Sql
---@param columns? string[]
---@return self
function Sql:insert(rows, columns)
  if not rows.__SQL_BUILDER__ then
    ---@cast rows Record|Record[]
    if not columns then
      columns = self.model.names -- get_keys(rows)
    end
    if not self._skip_validate then
      rows = self.model:_validate_create_data(rows, columns)
    end
    rows = self.model:_prepare_db_rows(rows, columns)
    return Sql._base_insert(self, rows, columns)
  else
    ---@cast rows Sql
    return Sql._base_insert(self, rows, columns)
  end
end

-- WITH
--   U AS (
--     INSERT INTO
--       inst_config AS T (name, inst_id, seq, status, position)
--     VALUES
--       ('tom', 1, 1, 'ok', 'ceo'),
--       ('kate', 2, 2, 'ok', 'cto') ON CONFLICT (inst_id, name)
--     DO
--     UPDATE
--     SET
--       seq = EXCLUDED.seq,
--       status = EXCLUDED.status,
--       position = EXCLUDED.position
--     RETURNING
--       T.inst_id,
--       T.name
--   )
-- DELETE FROM inst_config T
-- WHERE
--   (T.inst_id, T.name) NOT IN (
--     SELECT
--       inst_id,
--       name
--     FROM
--       U
--   )
-- RETURNING
--   *;
---@param rows Record[]
---@param key? Keys
---@param columns? string[]
function Sql:align(rows, key, columns)
  rows, key, columns = self:_clean_bulk_params(rows, key, columns)
  local upsert_query = self.model:create_sql()
  if not self._skip_validate then
    rows = self.model:_validate_create_rows(rows, key, columns)
  end
  rows = self.model:_prepare_db_rows(rows, columns)
  upsert_query:returning(key)
  Sql._base_upsert(upsert_query, rows, key, columns)
  self:with("U", upsert_query):where_not_in(key, Sql:new { table_name = 'U' }:_base_select(key)):delete()
  return self
end

---@param row Record
---@param columns? string[]
---@return self
function Sql:update(row, columns)
  if not columns then
    columns = self.model.names -- get_keys(row, { self.model.auto_now_name })
  end
  local safe_row = {}
  for k, v in pairs(row) do
    safe_row[k] = self:_resolve_F(v)
  end
  row = safe_row
  if not self._skip_validate then
    row = self.model:validate_update(row, columns)
  end
  row = self.model:_prepare_db_rows(row, columns)
  self._update = self:_get_update_token(row, columns)
  return self
end

---@param rows Record[]|Sql rows or SELECT subquery to be merged into the table
---@param key? Keys key(s) to determine whether the row exists, when key is a column table, every column can't be empty
---@param columns? string[] columns to be inserted or updated, if not provided, attributes of the first row will be used
---@return self
function Sql:merge(rows, key, columns)
  if rows.__SQL_BUILDER__ then
    if columns == nil then
      local select_text = rows._select or rows._returning
      if select_text then
        columns = extract_column_names(select_text)
      else
        error("subquery must have select or returning clause")
      end
    end
    if key == nil then
      key = self:_get_bulk_key(columns)
    end
    return Sql._base_merge(self, rows, key, columns)
  else
    rows, key, columns = self:_clean_bulk_params(rows, key, columns)
    if not self._skip_validate then
      rows = self.model:_validate_create_rows(rows, key, columns)
    end
    rows = self.model:_prepare_db_rows(rows, columns)
    return Sql._base_merge(self, rows, key, columns)
  end
end

--PostgreSQL: INSERT ON CONFLICT DO UPDATE
---@param rows Record[]|Sql rows or SELECT subquery to be inserted into the table
---@param key? Keys unique key(s) to determine whether the row exists, when key is a column table, every column can't be empty
---@param columns? string[] columns to be inserted or updated, if not provided, attributes of the first row will be used
---@return self
function Sql:upsert(rows, key, columns)
  if rows.__SQL_BUILDER__ then
    if columns == nil then
      local select_text = rows._select or rows._returning
      if select_text then
        columns = extract_column_names(select_text)
      else
        error("subquery must have select or returning clause")
      end
    end
    if key == nil then
      key = self:_get_bulk_key()
    end
    return Sql._base_upsert(self, rows, key, columns)
  else
    rows, key, columns = self:_clean_bulk_params(rows, key, columns)
    if not self._skip_validate then
      rows = self.model:_validate_create_rows(rows, key, columns)
    end
    rows = self.model:_prepare_db_rows(rows, columns)
    return Sql._base_upsert(self, rows, key, columns)
  end
end

---@param rows Record[]|Sql
---@param key? Keys
---@param columns? string[]
---@return self
function Sql:updates(rows, key, columns)
  if rows.__SQL_BUILDER__ then
    if columns == nil then
      local select_text = rows._select or rows._returning
      if select_text then
        columns = extract_column_names(select_text)
      else
        error("subquery must have select or returning clause")
      end
    end
    if key == nil then
      key = self:_get_bulk_key(columns, true)
    end
    return Sql._base_updates(self, rows, key, columns)
  else
    rows, key, columns = self:_clean_bulk_params(rows, key, columns, true)
    if not self._skip_validate then
      rows = self.model:_validate_update_rows(rows, key, columns)
    end
    rows = self.model:_prepare_db_rows(rows, columns)
    return Sql._base_updates(self, rows, key, columns)
  end
end

--- ```lua
-- Resume:gets({
--   { start_date = '2025-01-01', end_date = '2025-01-02', company = 'company1' },
--   { start_date = '2025-01-03', end_date = '2025-02-02', company = 'company2' } }):exec()
--```
-- yields:
---```sql
-- WITH
--   V (start_date, end_date, company) AS (
--     VALUES
--       (
--         '2025-01-01'::date,
--         '2025-01-02'::date,
--         'company1'::varchar
--       ),
--       ('2025-01-03', '2025-02-02', 'company2')
--   )
-- SELECT
--   *
-- FROM
--   resume T
--   RIGHT JOIN V ON (
--     V.start_date = T.start_date
--     AND V.end_date = T.end_date
--     AND V.company = T.company
--   )
---```
---@param keys Record[]
---@param columns? string[]
---@return self
function Sql:gets(keys, columns)
  if #keys == 0 then
    error("empty keys passed to gets")
  end
  return Sql._base_gets(self, keys, columns)
end

---注意：默认（_raw 未显式置 false）返回裸 Record（无 RecordClass 元表、
---不做 field:load）；只有 raw(false) 才走 model:load / create_record，
---返回真正的 ModelInstance
---@param statement string
---@return Array<Record>|Array<Record>[]
---@return number num_queries
function Sql:exec_statement(statement)
  -- https://github.com/leafo/pgmoon/blob/cd42b4a12ceae969db3f38bb2757ae738e4b0e32/pgmoon/init.moon#L872
  local records, num_queries = self.model.query(statement, self._compact)
  local all_results
  if self._prepend then
    all_results = records
    records = records[#self._prepend + 1]
  elseif self._append then
    all_results = records
    records = records[1]
  end
  local is_cud = self._update or self._insert or self._delete
  if (self._raw == nil or self._raw) or self._compact or is_cud then
    if is_cud and self._returning then
      records.affected_rows = nil
    end
    if self._return_all then
      return all_results or setmetatable(records, Array), num_queries
    else
      ---@cast records Array<Record>
      return setmetatable(records, Array), num_queries
    end
  else
    ---@type Model
    local model = self.model
    if not self._select_related then
      for i, record in ipairs(records) do
        records[i] = model:load(record)
      end
    else
      ---@type {[string]:AnyField}
      local fields = model.fields
      local field_names = model.field_names
      for i, record in ipairs(records) do
        for _, name in ipairs(field_names) do
          local field = fields[name]
          local value = record[name]
          if value ~= nil then
            local fk_model = self._select_related[name]
            if not fk_model then
              if not field.load then
                record[name] = value
              else
                ---@cast field ForeignkeyField|AliossField|TableField
                record[name] = field:load(value)
              end
            else
              -- _select_related means reading attributes of a foreignkey,
              -- so the on-demand reading mode of foreignkey_db_to_lua_validator is not proper here
              record[name] = fk_model:load(get_foreign_object(record, name .. "__"))
            end
          end
        end
        records[i] = model:create_record(record)
      end
    end
    if self._return_all then
      return all_results or setmetatable(records, Array), num_queries
    else
      ---@cast records Array<ModelInstance>
      return setmetatable(records, Array), num_queries
    end
  end
end

---默认返回裸 Record；raw(false) 时返回 ModelInstance（见 exec_statement）
---@return Array<Record>
---@return number num_queries
function Sql:exec()
  return self:exec_statement(self:statement())
end

---@param cond? table|string|fun(ctx:table):string
---@param op? string
---@param dval? DBValue
---@return integer
function Sql:count(cond, op, dval)
  if cond ~= nil then
    self:where(cond, op, dval)
  end
  local res
  if self._group or self._having or self._distinct or self._distinct_on or self._limit or self._offset then
    -- 分组/去重/分页后的行数 = 包一层子查询再 COUNT（Django 同款处理）
    local statement = format("SELECT count(*) FROM (%s) __count__", self:statement())
    res = self.model.query(statement, true)
  else
    -- 直接覆盖 select/order：COUNT 与已有普通列或 ORDER BY 共存会报
    -- "column must appear in the GROUP BY clause"
    self._select = "count(*)"
    self._order = nil
    res = self:compact():exec()
  end
  if res and res[1] then
    return res[1][1]
  else
    return 0
  end
end

--TODO:
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
function Sql:return_all()
  self._return_all = true
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

---@param col? string|fun(ctx:table):string
---@return Array<Record>
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

---@param ... string field names to include
---@return Array<Record>
---@return number num_queries
function Sql:values(...)
  if select('#', ...) > 0 then
    self._select = nil
    self:select(...)
  end
  return self:raw():exec()
end

---@param fields string|string[] field names
---@param opts? {flat?: boolean}
---@return Array
function Sql:values_list(fields, opts)
  if type(fields) == 'string' then
    fields = { fields }
  end
  if fields and #fields > 0 then
    self._select = nil
    self:select(unpack(fields))
  end
  local records = self:compact():execr()
  if opts and opts.flat then
    return records:flat()
  end
  return records
end

---@param ... string field names to load
---@return self
function Sql:only(...)
  self._select = nil
  return self:select(...)
end

---@param ... string field names to exclude
---@return self
function Sql:defer(...)
  local excluded = {}
  for i = 1, select('#', ...) do
    excluded[select(i, ...)] = true
  end
  local fields = {}
  for _, name in ipairs(self.model.field_names) do
    if not excluded[name] then
      fields[#fields + 1] = name
    end
  end
  self._select = nil
  return self:select(unpack(fields))
end

---@param field string
---@param kind "year"|"month"|"week"|"day"
---@param order? "ASC"|"DESC"
---@return Array
function Sql:dates(field, kind, order)
  local trunc_map = {
    year = "DATE_TRUNC('year', %s)::date",
    month = "DATE_TRUNC('month', %s)::date",
    week = "DATE_TRUNC('week', %s)::date",
    day = "%s::date",
  }
  local tpl = trunc_map[kind]
  if not tpl then
    error("invalid kind for dates(): " .. tostring(kind))
  end
  local col = self:_parse_column(field, "select")
  local expr = format(tpl, col)
  self._select = format("DISTINCT %s AS dateval", expr)
  self._order = format("dateval %s", order == "DESC" and "DESC" or "ASC")
  return self:compact():execr():flat()
end

---@param field string
---@param kind "year"|"month"|"week"|"day"|"hour"|"minute"|"second"
---@param order? "ASC"|"DESC"
---@return Array
function Sql:datetimes(field, kind, order)
  local trunc_map = {
    year = "DATE_TRUNC('year', %s)",
    month = "DATE_TRUNC('month', %s)",
    week = "DATE_TRUNC('week', %s)",
    day = "DATE_TRUNC('day', %s)",
    hour = "DATE_TRUNC('hour', %s)",
    minute = "DATE_TRUNC('minute', %s)",
    second = "DATE_TRUNC('second', %s)",
  }
  local tpl = trunc_map[kind]
  if not tpl then
    error("invalid kind for datetimes(): " .. tostring(kind))
  end
  local col = self:_parse_column(field, "select")
  local expr = format(tpl, col)
  self._select = format("DISTINCT %s AS datetimeval", expr)
  self._order = format("datetimeval %s", order == "DESC" and "DESC" or "ASC")
  return self:compact():execr():flat()
end

---@param cond? table|string|fun(ctx:table):string
---@param op? string
---@param dval? DBValue
---@return Record|false
function Sql:try_get(cond, op, dval)
  return self:get(cond, op, dval)
end

---@param cond? table|string|fun(ctx:table):string
---@param op? string
---@param dval? DBValue
---@return Record|false
function Sql:get(cond, op, dval)
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
    return false
  end
end

---@return Record|nil
function Sql:first()
  if not self._order then
    self:order(self.model.primary_key)
  end
  local records = self:limit(1):exec()
  return records[1]
end

---@return Record|nil
function Sql:last()
  if not self._order then
    self:order('-' .. self.model.primary_key)
  else
    self._order = self:_reverse_order_token(self._order)
  end
  local records = self:limit(1):exec()
  return records[1]
end

---@param ... string
---@return Record|nil
function Sql:latest(...)
  local n = select('#', ...)
  if n == 0 then
    error("latest() requires at least one field argument")
  end
  local order_fields = {}
  for i = 1, n do
    local field = select(i, ...)
    order_fields[i] = '-' .. field
  end
  self._order = nil
  return self:order(order_fields):first()
end

---@param ... string
---@return Record|nil
function Sql:earliest(...)
  local n = select('#', ...)
  if n == 0 then
    error("earliest() requires at least one field argument")
  end
  local order_fields = { ... }
  self._order = nil
  return self:order(order_fields):first()
end

---@param obj table
---@return boolean
function Sql:contains(obj)
  local pk = self.model.primary_key
  local pk_value = obj[pk]
  if pk_value == nil then
    error("contains() requires an object with a primary key value")
  end
  return self:where({ [pk] = pk_value }):exists()
end

---@param opts? table {analyze?=boolean, verbose?=boolean, format?=string}
---@return any
function Sql:explain(opts)
  opts = opts or {}
  local explain_options = {}
  if opts.analyze then
    explain_options[#explain_options + 1] = "ANALYZE"
  end
  if opts.verbose then
    explain_options[#explain_options + 1] = "VERBOSE"
  end
  if opts.format then
    local fmt = tostring(opts.format):upper()
    local allowed = { TEXT = true, XML = true, JSON = true, YAML = true }
    if not allowed[fmt] then
      error("invalid EXPLAIN format: " .. tostring(opts.format))
    end
    explain_options[#explain_options + 1] = "FORMAT " .. fmt
  end
  local options_str = ""
  if #explain_options > 0 then
    options_str = " (" .. concat(explain_options, ", ") .. ")"
  end
  local statement = format("EXPLAIN%s %s", options_str, self:statement())
  local res, err = self.model.query(statement, false)
  if res == nil then
    error(err)
  end
  return res
end

---@param ids? table
---@param field_name? string
---@return table<any, Record>
function Sql:in_bulk(ids, field_name)
  field_name = field_name or self.model.primary_key
  if ids and #ids > 0 then
    self:where({ [field_name .. '__in'] = ids })
  end
  local records = self:exec()
  local result = {}
  for _, record in ipairs(records) do
    result[record[field_name]] = record
  end
  return result
end

---@return Set
function Sql:as_set()
  return self:compact():execr():flat():as_set()
end

---@return table|Array<Record>
---@return number num_queries
function Sql:execr()
  return self:raw():exec()
end

---@param names? string[] select names for select_related_labels
---@return self
function Sql:select_related_labels(names)
  self:join_type("LEFT")
  for _, name in ipairs(names or self.model.names) do
    local field = self.model.fields[name]
    if field and field.type == 'foreignkey' and field.reference_label_column ~= field.reference_column then
      self:select_related(field.name, field.reference_label_column)
    end
  end
  return self
end

---@param fk_name string|ForeignkeyField
---@param select_names string[]|string
---@param more_name? string
---@param ... string
---@return self
function Sql:select_related(fk_name, select_names, more_name, ...)
  -- psr:select_related('parent_id', '*')
  -- psr:select_related('parent_id', 'user_id')
  -- psr:select_related('parent_id', {'user_id'})
  -- psr:select_related('parent_id', 'user_id__full_name')
  ---@type ForeignkeyField
  local foreignfield
  if type(fk_name) == 'string' then
    foreignfield = self.model.foreignkey_fields[fk_name]
  else
    foreignfield = fk_name
    fk_name = foreignfield.name
  end
  if foreignfield == nil then
    error(fk_name .. " is not a valid foreign key name for " .. self.table_name)
  end
  local fk_model = foreignfield.reference
  if not self._select_related then
    self._select_related = {}
  end
  self._select_related[fk_name] = fk_model
  self:select(fk_name)
  if not select_names then
    return self
  end
  local fks = {}
  if not more_name then
    if type(select_names) == 'table' then
      for _, fkn in ipairs(select_names) do
        fks[#fks + 1] = format("%s__%s", fk_name, fkn)
      end
    elseif select_names == '*' then
      for i, fkn in ipairs(fk_model.field_names) do
        fks[#fks + 1] = format("%s__%s", fk_name, fkn)
      end
    else
      fks[#fks + 1] = format("%s__%s", fk_name, select_names)
    end
  else
    for i, fkn in ipairs({ select_names, more_name, ... }) do
      fks[#fks + 1] = format("%s__%s", fk_name, fkn)
    end
  end
  return self:select(fks)
end

--TODO:
--```sql
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
--```
---@param name string
---@param value any
---@param select_names? string[]
---@return self
function Sql:where_recursive(name, value, select_names)
  if self._where_recursive then
    error("where_recursive can only be called once on the same Sql")
  end
  local fk = self.model.foreignkey_fields[name]
  if fk == nil then
    error(name .. " is not a valid foreign key name for " .. self.table_name)
  end
  if fk.reference ~= self.model then
    error(name .. " is not a self-referencing foreign key on " .. self.table_name)
  end
  if self._from then
    error("where_recursive must be called before from()/join() on the same Sql")
  end
  local fkc = fk.reference_column
  local table_name = self.model.table_name
  local t_alias = smart_quote(table_name .. '_recursive')
  local seed_sql = self.model:create_sql():select(fkc, name):where(name, value)
  local recursive_sql = self.model:create_sql():select(fkc, name)
  local join_cond = format("%s.%s = %s.%s",
    recursive_sql._as or smart_quote(table_name),
    smart_quote(name),
    t_alias,
    smart_quote(fkc))
  recursive_sql:_base_join('INNER', t_alias, join_cond)
  if select_names then
    seed_sql:select(select_names)
    recursive_sql:select(select_names)
  end
  self:with_recursive(t_alias, seed_sql:union_all(recursive_sql))
  self._from = t_alias .. ' AS ' .. (self._as or smart_quote(table_name))
  self._where_recursive = true
  return self
end

---原子版 get-or-create：单条 `INSERT ... ON CONFLICT (params列) DO UPDATE
---SET k = EXCLUDED.k RETURNING ..., (xmax = 0) AS __is_inserted__`。
---并发调用恰好一个拿到 created=true，其余拿到现有行（xmax=0 仅插入路径成立）。
---要求 params 的列集合命中唯一约束（unique 字段或 unique_together），
---否则 PG 报 "no unique or exclusion constraint matching the ON CONFLICT specification"。
---已存在时的 no-op 更新只回写冲突键自身：不触碰其它列、不刷新 auto_now，
---但会产生一次行版本写入——高频只读探测场景请直接用 get()。
---@param params table 查找条件（必须命中唯一约束）
---@param defaults? table 仅创建时使用的值
---@param columns? string[]|'*' 返回列，默认主键 + 插入列
---@return Record, boolean created
function Sql:get_or_create(params, defaults, columns)
  assert(next(params) ~= nil, "params can't be empty for get_or_create")
  local values_list, insert_columns = Sql:_get_insert_values_token(dict(params, defaults))
  local key_columns = get_keys(params)
  local all_columns_token
  if columns == '*' then
    all_columns_token = '*'
  else
    all_columns_token = as_token(list(columns or { self.model.primary_key }, insert_columns):unique())
  end
  local k1 = key_columns[1]
  self._insert = format("(%s) VALUES %s ON CONFLICT (%s) DO UPDATE SET %s = EXCLUDED.%s",
    as_token(insert_columns),
    as_literal(values_list),
    as_token(key_columns),
    k1, k1)
  self:_base_returning(all_columns_token):_base_returning("(xmax = 0) AS __is_inserted__")
  local records = self:execr()
  if #records ~= 1 then
    error("get_or_create expected 1 record, got " .. #records)
  end
  local ins = records[1]
  ---@diagnostic disable-next-line: invisible
  local created = ins.__is_inserted__
  ---@diagnostic disable-next-line: invisible
  ins.__is_inserted__ = nil
  return ins, created
end

---原子版 update-or-create：单条 `INSERT ... ON CONFLICT (params列) DO UPDATE
---SET defaults列 = EXCLUDED.defaults列 RETURNING ..., (xmax = 0)`。
---存在则用 defaults 更新（并刷新 auto_now），不存在则用 params+defaults 创建。
---与 get_or_create 相同的唯一约束要求；defaults 为空时退化为 get_or_create。
---校验走 validate_update 语义（只校验提供的值，不回填默认、不查 required），
---与旧实现「已存在只验 defaults」的行为对齐；skip_validate() 可跳过。
---@param params table 查找条件（必须命中唯一约束）
---@param defaults? table 更新/创建的值
---@param columns? string[] 返回列，默认 '*'
---@return Record, boolean created
function Sql:update_or_create(params, defaults, columns)
  assert(next(params) ~= nil, "params can't be empty for update_or_create")
  defaults = defaults or {}
  if next(defaults) == nil then
    -- 与主路径的默认返回列（'*'）保持一致
    return self:get_or_create(params, nil, columns or '*')
  end
  local row = dict(params, defaults)
  local row_columns = get_keys(row)
  local key_columns = get_keys(params)
  if not self._skip_validate then
    row = self.model:validate_update(row, row_columns)
  end
  row = self.model:_prepare_db_rows(row, row_columns)
  Sql._base_upsert(self, row, key_columns, row_columns)
  self:returning(columns or '*')
  self:_base_returning("(xmax = 0) AS __is_inserted__")
  local records = self:execr()
  if #records ~= 1 then
    error("update_or_create expected 1 record, got " .. #records)
  end
  local ins = records[1]
  ---@diagnostic disable-next-line: invisible
  local created = ins.__is_inserted__
  ---@diagnostic disable-next-line: invisible
  ins.__is_inserted__ = nil
  return ins, created
end

---@return self
function Sql:compact()
  self._compact = true
  return self
end

---@param kwargs table
---@return Array<Record>
---@return number num_queries
function Sql:filter(kwargs)
  return self:where(kwargs):exec()
end

local select_args = {
  'select', 'select_related', 'select_related_labels', 'where',
  'order', 'group', 'having', 'limit', 'offset', 'distinct', 'raw', 'compact',
  'flat', 'get', 'try_get', 'exists' }

---@class selectArgs
---@field select? table|string[] 要查询的字段
---@field select_related? string 要加载的外键
---@field select_related_labels? string[] 要加载的外键标签
---@field where? table 查询条件
---@field order? table|string[] 排序条件
---@field group? table|string[] 分组条件
---@field having? table 分组过滤条件
---@field limit? integer 限制返回数量
---@field offset? integer 跳过的数量
---@field distinct? boolean 是否去重
---@field get? table|string[] 获取单条记录的条件
---@field try_get? table|string[] 尝试获取单条记录的条件
---@field flat? string 扁平化返回的字段
---@field raw? boolean 是否返回原始数据
---@field exists? boolean 是否只检查存在性
---@field compact? boolean 是否返回紧凑格式

local function ensure_array(o)
  if type(o) ~= 'table' or o[1] == nil then
    return { o }
  end
  return o
end

---@param data selectArgs
---@return table
---@return number? num_queries
local terminal_args = { flat = true, get = true, try_get = true, exists = true }

function Sql:meta_query(data)
  for i, arg_name in ipairs(select_args) do
    if data[arg_name] ~= nil then
      self = self[arg_name](self, unpack(ensure_array(data[arg_name])))
      if terminal_args[arg_name] then
        -- terminal 方法已执行并返回结果（非 builder），不能再链式调用
        break
      end
    end
  end
  if data.get or data.try_get or data.flat or data.exists then
    return self
  else
    return self:exec()
  end
end

return Sql
