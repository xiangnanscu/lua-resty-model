local Utils = require "xodel.utils"
local Array = require "resty.array"
local encode = require("cjson").encode
local F = require "xodel.f"

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
local NULL = Utils.NULL
local table_new = Utils.table_new
local table_clear = Utils.table_clear
local PG_OPERATORS = Utils.PG_OPERATORS
local PG_SET_MAP = Utils.PG_SET_MAP
local smart_quote = Utils.smart_quote
local DEFAULT = Utils.DEFAULT
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
---@field private _join_proxy_models?  Xodel[]
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
local Sql = setmetatable({}, SqlMeta)
Sql.__index = Sql
Sql.__SQL_BUILDER__ = true
Sql.as_token = as_token
Sql.as_literal = as_literal

function Sql:__tostring()
  return self:statement()
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
function Sql:_get_cte_values_literal(rows, columns, no_check)
  rows = self:_rows_to_array(rows, columns)
  ---@type string[]
  local res = { self:_array_to_values(rows[1], columns, no_check, true) }
  for i = 2, #rows do
    res[i] = self:_array_to_values(rows[i], columns, no_check, false)
  end
  return res
end

local _debug = 0
local function debug(...)
  if _debug == 1 then
    print(...)
  end
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
---@param rows Record[]
---@param key Keys
---@param columns string[]
---@return self
function Sql:_base_merge(rows, key, columns)
  local cte_name = format("V(%s)", concat(columns, ", "))
  local cte_values = format("(VALUES %s)", as_token(self:_get_cte_values_literal(rows, columns)))
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
    rows = self:_get_cte_values_literal(rows, columns)
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
---@param model Xodel
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
    local main_proxy = self:_create_join_proxy(self.model, alias)
    self._join_proxy_models = { main_proxy }
    self._join_alias = { alias }
  end
end

---@private
---@param join_type string
---@param fk_model Xodel
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
---@param join_args string|Xodel
---@param key string|fun(ctx:table):string
---@param op? string
---@param val? DBValue
---@return self
function Sql:_base_join(join_type, join_args, key, op, val)
  if type(join_args) == 'table' then
    ---@cast join_args Xodel
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

---@param cols string|string[]
---@param range Sql|table
---@return self
function Sql:where_in(cols, range)
  if type(cols) == "string" then
    return Sql._base_where_in(self, self:_parse_column(cols), range)
  else
    local res = {}
    for i = 1, #cols do
      res[i] = self:_parse_column(cols[i])
    end
    return Sql._base_where_in(self, res, range)
  end
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
  if type(cols) == "string" then
    return Sql._base_where_not_in(self, self:_parse_column(cols), range)
  else
    local res = {}
    for i = 1, #cols do
      res[i] = self:_parse_column(cols[i])
    end
    return Sql._base_where_not_in(self, res, range)
  end
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
  if type(key) == "string" then
    for i, col in ipairs(columns) do
      if col ~= key then
        insert(tokens, format("%s = %s.%s", col, prefix, col))
      end
    end
  else
    local sets = {}
    for i, k in ipairs(key) do
      sets[k] = true
    end
    for i, col in ipairs(columns) do
      if not sets[col] then
        insert(tokens, format("%s = %s.%s", col, prefix, col))
      end
    end
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
    -- use select context because it's a column name, the operator is =
    ---@cast cond string
    return format("%s = %s", self:_parse_column(cond, "select"), as_literal(op))
  else
    -- use select context because it's a column name, the operator is op
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
function Sql:_get_bulk_key(columns)
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
    columns = get_keys(rows, is_update and { self.model.auto_now_name } or {})
    if #columns == 0 then
      error("no columns provided for bulk")
    end
  end
  if key == nil then
    -- is_update is true when updates, means searching key among columns extracted from rows
    -- so to ensure primary key is the fallback key (not unique field)
    key = self:_get_bulk_key(is_update and columns or nil)
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

local EXPR_OPERATORS = {
  eq = function(key, value)
    return format("%s = %s", key, as_literal(value))
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
    return format("%s IN %s", key, as_literal(value))
  end,
  notin = function(key, value)
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
  year = function(key, value)
    return format("%s BETWEEN '%s-01-01' AND '%s-12-31'", key, value, value)
  end,
  month = function(key, value)
    return format("EXTRACT('month' FROM %s) = '%s'", key, value)
  end,
  day = function(key, value)
    return format("EXTRACT('day' FROM %s) = '%s'", key, value)
  end,
  regex = function(key, value)
    return format("%s ~ '%s'", key, value:gsub("'", "''"))
  end,
  iregex = function(key, value)
    return format("%s ~* '%s'", key, value:gsub("'", "''"))
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
    return format("(%s) ? %s", key, value)
  end,
  has_keys = function(key, value)
    return format("(%s) ?& [%s]", key, as_literal_without_brackets(value))
  end,
  has_any_keys = function(key, value)
    return format("(%s) ?| [%s]", key, as_literal_without_brackets(value))
  end,
  json_contains = function(key, value)
    return format("(%s) @> '%s'", key, encode(value))
  end,
  json_eq = function(key, value)
    return format("(%s) = '%s'", key, encode(value))
  end,
  contained_by = function(key, value)
    return format("(%s) <@ '%s'", key, encode(value))
  end,
}

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
  if q.logic == "NOT" then
    return format("NOT (%s)", self:_resolve_Q(q.left))
  elseif q.left and q.right then
    local left_token = self:_resolve_Q(q.left)
    local right_token = self:_resolve_Q(q.right)
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
  return self:with(cte_name, cte_values):right_join("V", join_cond)
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
  local i = 1
  local model = self.model
  local op = 'eq'
  local a, b, token, join_key, prefix, column, final_column, last_field, last_token, last_model, last_join_key, json_keys
  while true do
    a, b = key:find("__", i, true)
    if not a then
      token = key:sub(i)
    else
      token = key:sub(i, a - 1)
    end
    debug('token', token, self.model.table_name)
    -- column might be changed in the loop
    local field = model.fields[token]
    if field then
      -- 1. fields from model itself, highest priority
      if not last_field then
        -- 1.1 first column, the most case
        debug('1.1', model.class_name, token)
        column = token
        prefix = self._as or model._table_name_token
      elseif json_keys then
        -- 1.2 json field searh
        -- https://docs.djangoproject.com/en/4.2/topics/db/queries/#querying-jsonfield
        -- the json attribute happens to be included in fields, but we treat it as a json attribute
        debug('1.2', model.class_name, token)
        if json_operators[token] then
          op = token
        else
          json_keys[#json_keys + 1] = token
        end
      elseif last_model.reversed_fields[last_token] then
        -- 1.3 field in a reversed model: Blog:where{entry__rating}
        -- already join in previous loop, do nothing
        debug('1.3', model.class_name, token)
        column = token
      elseif last_field.reference then
        -- 1.4 foreignkey model's field, may need a join
        if token == last_field.reference_column then
          -- 1.4.1 blog_id__id => redundant foreignkey suffix , rollback to last_token
          debug('1.4.1', model.class_name, token)
          column = last_token
          token = last_token -- in case of blog_id__id__gt
        else
          -- 1.4.2 blog_id__name => need a join
          debug('1.4.2', model.class_name, last_token or '/', token)
          column = token
          if not join_key then
            -- prefix with foreignkey name because a model can be referenced multiple times by the same model
            -- such as: Entry:where{blog_id__name='Tom', reposted_blog_id__name='Kate'}
            join_key = last_token
          else
            last_join_key = join_key
            join_key = join_key .. "__" .. last_token
          end
          if not self._join_keys then
            self._join_keys = {}
          end
          prefix = self._join_keys[join_key]
          if not prefix then
            local function join_cond_cb(ctx)
              local left_column = ctx[last_join_key or 1][last_token]
              if not left_column then
                error(last_token .. " is a invalid column for " .. ctx[last_join_key or 1][1])
              end
              local right_column = ctx[join_key][last_field.reference_column]
              return format("%s = %s", left_column, right_column)
            end
            prefix = self:_handle_manual_join(self._join_type or "INNER", model, join_cond_cb, join_key)
          end
        end
      else
        error("1.5 invalid field name: " .. token)
      end
      last_model = model
      if field.reference then
        model = field.reference
      end
      if field.model then
        json_keys = {}
      end
    elseif self._annotate and self._annotate[token] then
      -- 2. name that's registered in annotate:
      -- Blog:annotate{cnt=Count('entry')}:where{cnt__lt=2}:group_by{'name'}
      -- return expression like: Count('entry') or F('price') * 10
      debug('2', model.class_name, token)
      final_column = self._annotate[token]
    elseif json_keys then
      -- 3. attributes from a json field
      -- Blog.where{data__a='x'} => WHERE ("example_blog"."data" -> a) = '"x"'
      -- Blog.where{data__a__contains='x'} => WHERE ("example_blog"."data" -> a) @> '"x"'
      debug('3', model.class_name, token)
      if json_operators[token] then
        op = token
      else
        json_keys[#json_keys + 1] = token
      end
    else
      -- Blog:where{entry__rating=1}
      local reversed_field = model.reversed_fields[token] -- Entry.blog_id, Blog:where{entry=1}
      if reversed_field then
        -- 4. reversed foreignkey, join from current loop
        -- token = entry, reversed_name = blog_id
        debug('4', model.class_name, token)
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
        debug('5', model.class_name, token)
        if context == nil or not NON_OPERATOR_CONTEXTS[context] then -- where or having or Q
          -- 5.1 should be operator, check it
          assert(EXPR_OPERATORS[token], "5.1 invalid operator: " .. token)
        else
          -- 5.2 select/returning etc context, shouldn't reach here
          error("5.2 invalid column: " .. token)
        end
        op = token
        column = last_token
        break
      else
        error("parse column error, invalid name: " .. token .. " for model: " .. model.class_name)
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
    if #json_keys > 0 then
      final_column = format("%s #> [%s]", prefix .. '.' .. smart_quote(column),
        as_literal_without_brackets(json_keys))
    end
    if op == 'contains' then
      op = 'json_contains'
    elseif op == 'eq' then
      op = 'json_eq'
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
  error(format("invalid alias for having: '%s'", key))
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
    offset = self._offset
  }
  if self._set_operation then
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
---@return self|XodelInstance[]
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
    local col = self:_parse_column(key) .. ' AS ' .. alias
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
    local col = as_literal(key) .. ' AS ' .. alias
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
  --** by default, group by columns are selected
  self:select(a, ...)
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

---@param join_args string|Xodel join model or foreign key
---@param key string|fun(ctx:table):string join condition or left part of join cond or join callback
---@param op? string
---@param val? DBValue
---@return self
function Sql:join(join_args, key, op, val)
  return self:_base_join("INNER", join_args, key, op, val)
end

---@param join_args string|Xodel
---@param key string|fun(ctx:table):string
---@param op? string
---@param val? DBValue
---@return self
function Sql:inner_join(join_args, key, op, val)
  return self:_base_join("INNER", join_args, key, op, val)
end

---@param join_args string|Xodel
---@param key string|fun(ctx:table):string
---@param op? string
---@param val? DBValue
---@return self
function Sql:left_join(join_args, key, op, val)
  return self:_base_join("LEFT", join_args, key, op, val)
end

---@param join_args string|Xodel
---@param key string|fun(ctx:table):string
---@param op? string
---@param val? DBValue
---@return self
function Sql:right_join(join_args, key, op, val)
  return self:_base_join("RIGHT", join_args, key, op, val)
end

---@param join_args string|Xodel
---@param key string|fun(ctx:table):string
---@param op string
---@param val DBValue
---@return self
function Sql:full_join(join_args, key, op, val)
  return self:_base_join("FULL", join_args, key, op, val)
end

---@param join_args string|Xodel
---@param key string|fun(ctx:table):string
---@param op string
---@param val DBValue
---@return self
function Sql:cross_join(join_args, key, op, val)
  return self:_base_join("CROSS", join_args, key, op, val)
end

---@param n integer|string
---@return self
function Sql:limit(n)
  if n == nil then
    return self
  end

  if type(n) == "string" then
    ---@diagnostic disable-next-line: cast-local-type
    n = tonumber(n)
    if n == nil then
      error("invalid limit value: not a valid number")
    end
  end

  local MAX_LIMIT = 10000
  if type(n) ~= "number" or n ~= math.floor(n) or n <= 0 or n > MAX_LIMIT then
    error("invalid limit value: " .. tostring(n))
  end
  self._limit = n
  return self
end

---@param n integer|string
---@return self
function Sql:offset(n)
  if n == nil then
    return self
  end

  -- 如果是字符串类型，尝试转换为数字
  if type(n) == "string" then
    n = tonumber(n)
    if n == nil then
      error("invalid offset value: not a valid number")
    end
  end

  if type(n) ~= "number" or n ~= math.floor(n) or n < 0 then
    error("invalid offset value: " .. tostring(n))
  end
  self._offset = n
  return self
end

-- remove type QClass for luaLS's bug
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
      if self._where == nil then
        self._where = where_token
      else
        self._where = format("(%s) AND (%s)", self._where, where_token)
      end
      return self
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
  self._order = s
  return self
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
      self:_base_select(format("%s AS %s", func_token, alias))
    elseif func.__IS_FIELD_BUILDER__ then
      local exp_token = self:_resolve_field_builder(func)
      self._annotate[alias] = exp_token
      -- if not self._computed_columns then
      --   self._computed_columns = {}
      -- end
      -- self._computed_columns[alias] = exp_token
      self:_base_select(format("%s AS %s", exp_token, alias))
    end
  end
  return self
end

---@param rows Record|Record[]|Sql
---@param columns? string[]
---@return self
function Sql:insert(rows, columns)
  if not rows.__SQL_BUILDER__ then
    ---@cast rows Record|Record[]
    if not columns then
      columns = self.model.names -- self.model.names -- get_keys(rows)
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

---@param row Record|Sql
---@param columns? string[]
---@return self
function Sql:update(row, columns)
  if not row.__SQL_BUILDER__ then
    ---@cast row Record
    if not columns then
      columns = self.model.names -- get_keys(row, { self.model.auto_now_name })
    end
    for k, v in pairs(row) do
      row[k] = self:_resolve_F(v)
    end
    if not self._skip_validate then
      row = self.model:validate_update(row, columns)
    end
    row = self.model:_prepare_db_rows(row, columns)
    return Sql._base_update(self, row, columns)
  else
    ---@cast row Sql
    return Sql._base_update(self, row, columns)
  end
end

---@param rows Record[] rows to be merged into the table
---@param key? Keys key(s) to determine whether the row exists, when key is a column table, every column can't be empty
---@param columns? string[] columns to be inserted or updated, if not provided, attributes of the first row will be used
---@return self
function Sql:merge(rows, key, columns)
  rows, key, columns = self:_clean_bulk_params(rows, key, columns)
  if not self._skip_validate then
    rows = self.model:_validate_create_rows(rows, key, columns)
  end
  rows = self.model:_prepare_db_rows(rows, columns)
  return Sql._base_merge(self, rows, key, columns)
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
      key = self:_get_bulk_key(columns)
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

---@param statement string
---@return Array<XodelInstance>|Array<XodelInstance>[]
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
    ---@type Xodel
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
      ---@cast records Array<XodelInstance>
      return setmetatable(records, Array), num_queries
    end
  end
end

---@return Array<XodelInstance>
---@return number num_queries
function Sql:exec()
  return self:exec_statement(self:statement())
end

---@param cond? table|string|fun(ctx:table):string
---@param op? string
---@param dval? DBValue
---@return integer
function Sql:count(cond, op, dval)
  local res
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

---@param cond? table|string|fun(ctx:table):string
---@param op? string
---@param dval? DBValue
---@return XodelInstance|false
function Sql:try_get(cond, op, dval)
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

---@param cond? table|string|fun(ctx:table):string
---@param op? string
---@param dval? DBValue
---@return XodelInstance|false
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
    -- elseif #records == 0 then
    --   error("record not found")
    -- else
    --   error(format("multiple records returned: %d", #records))
  else
    return false
  end
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
  for i, name in ipairs(names or self.model.names) do
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
    error(fk_name .. " is not a valid forein key name for " .. self.table_name)
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
  local fk = self.model.foreignkey_fields[name]
  if fk == nil then
    error(name .. " is not a valid forein key name for " .. self.table_name)
  end
  local fkc = fk.reference_column
  local table_name = self.model.table_name
  local t_alias = table_name .. '_recursive'
  local seed_sql = self.model:create_sql():select(fkc, name):where(name, value)
  local recursive_sql = self.model:create_sql():select(fkc, name)
  local join_cond = format("%s.%s = %s.%s", recursive_sql._as or smart_quote(table_name), name, t_alias, fkc)
  recursive_sql:_base_join('INNER', t_alias, join_cond)
  if select_names then
    seed_sql:select(select_names)
    recursive_sql:select(select_names)
  end
  self:with_recursive(t_alias, seed_sql:union_all(recursive_sql))
  return self:from(t_alias .. ' AS ' .. (self._as or smart_quote(table_name)))
end

---@param params table
---@param defaults? table
---@param columns? string[]
---@return XodelInstance, boolean
function Sql:get_or_create(params, defaults, columns)
  local values_list, insert_columns = Sql:_get_insert_values_token(dict(params, defaults))
  local insert_columns_token = as_token(insert_columns)
  local all_columns_token = as_token(list(columns or { self.model.primary_key }, insert_columns):unique())
  local insert_sql = format('(INSERT INTO %s(%s) SELECT %s WHERE NOT EXISTS (%s) RETURNING %s)',
    self.model._table_name_token,
    insert_columns_token,
    as_literal_without_brackets(values_list),
    self.model:create_sql():select(1):where(params),
    all_columns_token
  )
  local inserted_set = Sql:new { model = self.model, table_name = 'NEW_RECORDS', _as = 'NEW_RECORDS' }
      :with(format("NEW_RECORDS(%s)", all_columns_token), insert_sql)
      :_base_select(all_columns_token):_base_select("TRUE AS __is_inserted__")
  -- main sql
  local selected_set = self:where(params):_base_select(all_columns_token):_base_select(
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

---@return self
function Sql:compact()
  self._compact = true
  return self
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
function Sql:meta_query(data)
  for i, arg_name in ipairs(select_args) do
    if data[arg_name] ~= nil then
      self = self[arg_name](self, unpack(ensure_array(data[arg_name])))
    end
  end
  if data.get or data.try_get or data.flat or data.exists then
    return self
  else
    return self:exec()
  end
end

---@param kwargs table
---@return Array<XodelInstance>
---@return number num_queries
function Sql:filter(kwargs)
  return self:where(kwargs):exec()
end

return Sql
