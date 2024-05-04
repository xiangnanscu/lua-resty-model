---@diagnostic disable: invisible
-- https://www.postgreSql.org/docs/current/sql-select.html
-- https://www.postgreSql.org/docs/current/sql-insert.html
-- https://www.postgreSql.org/docs/current/sql-update.html
-- https://www.postgreSql.org/docs/current/sql-delete.html
local clone = require "table.clone"
local Fields = require "resty.fields"
local Sql = require "resty.sql"
local Query = require "resty.query"
local Array = require "resty.array"
local Object = require "resty.object"
local utils = require "resty.utils"
local getenv = require "resty.dotenv".getenv
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
local match = ngx.re.match
local NULL = Sql.NULL

local default_query = Query {
  HOST = getenv "PGHOST" or "127.0.0.1",
  PORT = getenv "PGPORT" or 5432,
  DATABASE = getenv "PGDATABASE" or "postgres",
  USER = getenv "PGUSER" or "postgres",
  PASSWORD = getenv "PGPASSWORD" or "",
}
local normalize_field_shortcuts = Fields.basefield.normalize_field_shortcuts
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
  label = true,
  db_options = true,
  abstract = true,
  auto_primary_key = true,
  primary_key = true,
  unique_together = true,
  referenced_label_column = true,
  preload = true,
}

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

local function check_reserved(name)
  assert(type(name) == "string", string_format("name must by string, not %s (%s)", type(name), name))
  assert(not name:find("__", 1, true), "don't use __ in a field name")
  assert(not IS_PG_KEYWORDS[name:upper()], string_format("%s is a postgresql reserved word", name))
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

---@param json {[string]:any}
---@param kwargs? {[string]:any}
---@return AnyField
local function make_field_from_json(json, kwargs)
  local options = dict(json, kwargs)
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
  return fcls:create_field(options)
end


---@param row any
---@return boolean
local function is_sql_instance(row)
  local meta = getmetatable(row)
  return meta and meta.__SQL_BUILDER__
end

local as_token = Sql.as_token
local as_literal = Sql.as_literal
local as_literal_without_brackets = Sql.as_literal_without_brackets


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
---@field make_field_from_json fun(table):AnyField
---@field RecordClass table
---@field extends? table
---@field admin? table
---@field table_name string
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
  make_field_from_json = make_field_from_json,
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
---@field __normalized__? boolean
---@field extends? table
---@field mixins? table[]
---@field abstract? boolean
---@field admin? table
---@field table_name? string
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
---@return Sql
function Xodel.create_sql(cls)
  return Sql:new { model = cls, table_name = cls.table_name } --:as('T')
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
  -- for _, field in pairs(model.fields) do
  --   if field.db_type == field.FK_TYPE_NOT_DEFIEND then
  --     local fk = model.fields[field.reference_column]
  --     field.db_type = fk.db_type or fk.type
  --   end
  -- end
  local uniques = Array {}
  for i, unique_group in ipairs(ModelClass.unique_together or {}) do
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
      __newindex = disable_setting_model_attrs
    })
  end
  local proxy = create_model_proxy(ModelClass)
  Xodel.resolve_self_foreignkey(proxy)
  return proxy
end

---@param cls Xodel
---@param options ModelOpts
---@return ModelOpts
function Xodel.normalize(cls, options)
  local extends = options.extends
  local model = {
    admin = clone(options.admin or {}),
  }
  for _, extend_attr in ipairs({ 'table_name', 'label', 'referenced_label_column', 'preload' }) do
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
    model.fields[name] = make_field_from_json(field, { name = name })
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

---@param cls Xodel
function Xodel.ensure_admin_list_names(cls)
  cls.admin.list_names = Array(clone(cls.admin.list_names or {}));
  if #cls.admin.list_names == 0 then
    cls.admin.list_names = cls.names:filter(function(name)
      local f = cls.fields[name]
      return f.type ~= 'table'
    end);
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
  return make_field_from_json(options)
end

---@param cls Xodel
---@param names? string[]|string
function Xodel.to_json(cls, names)
  if not names then
    return {
      table_name = cls.table_name,
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
      elseif field.type ~= 'uuid' then
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
      return nil, cls:parse_error_message(clean_err)
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
      return nil, cls:parse_error_message(clean_err)
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
  return field:make_error(err, index)
end

---@param cls Xodel
---@param err ValidateError
---@return ValidateErrorObject
function Xodel.parse_error_message(cls, err)
  if type(err) == 'table' then
    return err
  end
  local captured = match(err, '^(?<name>.+?)~(?<message>.+?)$', 'josui')
  if not captured then
    error("can't parse this model error message: " .. err)
  else
    local name = captured.name
    local message = captured.message
    return cls:make_field_error(name, message)
  end
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

---@param cls Xodel
---@param rows Record|Record[]
---@param columns? string[]
---@return Records?, string[]|ValidateError
function Xodel.validate_create_data(cls, rows, columns)
  local err_obj, cleaned
  -- TODO: columns没有提供值时从rows里面获取
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
local select_args = { 'load_fk', 'where', 'where_or', 'or_where', 'or_where_or',
  'select', 'order', 'group', 'having', 'limit', 'offset', 'distinct', 'raw', 'get', }
---@param cls Xodel
---@param data table
---@return table
function Xodel.meta_query(cls, data)
  if data.update then
    local records = cls:create_sql():update(data.update)
    for i, arg_name in ipairs(update_args) do
      if data[arg_name] ~= nil then
        records = records[arg_name](records, data[arg_name])
      end
      if data[arg_name .. '_array'] then
        records = records[arg_name](records, unpack(data[arg_name .. '_array']))
      end
    end
    return records:exec()
  elseif data.insert then
    local records = cls:create_sql():insert(data.insert)
    for i, arg_name in ipairs(insert_args) do
      if data[arg_name] ~= nil then
        records = records[arg_name](records, data[arg_name])
      end
      if data[arg_name .. '_array'] then
        records = records[arg_name](records, unpack(data[arg_name .. '_array']))
      end
    end
    return records:exec()
  else
    local records = cls:create_sql()
    for i, arg_name in ipairs(select_args) do
      if data[arg_name] ~= nil then
        records = records[arg_name](records, data[arg_name])
      end
      if data[arg_name .. '_array'] then
        records = records[arg_name](records, unpack(data[arg_name .. '_array']))
      end
    end
    if data.get then
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
