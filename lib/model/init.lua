---@diagnostic disable: invisible
local Array = require "resty.array"
local Fields = require "model.fields"
local Func = require "model.func"
local F = require "model.f"
local Q = require "model.q"
local Query = require "model.query"
local Utils = require "model.utils"
local Sql = require "model.sql"


local setmetatable = setmetatable
local ipairs = ipairs
local tostring = tostring
local type = type
local pairs = pairs
local assert = assert
local error = error
local insert = table.insert
local format = string.format
local Count = Func.Count
local Sum = Func.Sum
local Avg = Func.Avg
local Max = Func.Max
local Min = Func.Min
local StdDev = Func.StdDev
local Variance = Func.Variance
local clone = Utils.clone
local NULL = Utils.NULL
local smart_quote = Utils.smart_quote
local make_token = Utils.make_token
local DEFAULT = Utils.DEFAULT
local list = Utils.list
local dict = Utils.dict
local to_camel_case = Utils.to_camel_case
local as_literal = Utils.as_literal
local as_token = Utils.as_token

--TODO: breaking change: select_as, select_literal_as, where_exists

---@alias ColumnContext "select"|"returning"|"aggregate"|"group_by"|"order_by"|"distinct"|"where"|"having"|"F"|"Q"
---@alias Keys string|string[]
---@alias SqlSet "_union"|"_union_all"| "_except"| "_except_all"|"_intersect"|"_intersect_all"
---@alias Token fun(): string
---@alias DBLoadValue string|number|integer|boolean|table|userdata
---@alias DBValue DBLoadValue|Token
---@alias Record {[string]:DBValue|Record[]}
---@alias Records Record|Record[]
---@alias JOIN_TYPE "INNER"|"LEFT"|"RIGHT"|"FULL"

---@class ValidateError
---@field name string
---@field message string
---@field label string
---@field type string
---@field index? integer returned by TableField's validate function, indicates the error row index
---@field batch_index? integer set by insert, upsert


-- Model defination
local normalize_field_shortcuts = Fields.basefield.normalize_field_shortcuts
local DEFAULT_PRIMARY_KEY = 'id'
local DEFAULT_CTIME_KEY = 'ctime'
local DEFAULT_UTIME_KEY = 'utime'
local DEFAULT_STRING_MAXLENGTH = 256

local MODEL_MERGE_NAMES = {
  admin = true,
  table_name = true,
  class_name = true,
  label = true,
  db_config = true,
  abstract = true,
  is_role_model = true,
  auto_primary_key = true,
  primary_key = true,
  unique_together = true,
  referenced_label_column = true,
  preload = true,
  app_label = true,
}
local BaseModel = {
  abstract = true,
  field_names = Array { DEFAULT_PRIMARY_KEY, DEFAULT_CTIME_KEY, DEFAULT_UTIME_KEY },
  fields = {
    [DEFAULT_PRIMARY_KEY] = { type = "integer", primary_key = true, serial = true },
    [DEFAULT_CTIME_KEY] = { label = "创建时间", type = "datetime", auto_now_add = true },
    [DEFAULT_UTIME_KEY] = { label = "更新时间", type = "datetime", auto_now = true }
  }
}

local API_TABLE_NAMES = {
  T = true,
  D = true,
  U = true,
  V = true,
  W = true,
  NEW_RECORDS = true,
}
local function check_conflicts(name)
  assert(type(name) == "string", format("name must be string, not %s (%s)", type(name), name))
  assert(not name:find("__", 1, true), "don't use __ in a table or column name")
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
    assert(type(name) == 'string', format("field_names must be string, not %s", type(name)))
  end
  return Array(field_names)
end

---@param row any
---@return boolean
local function is_sql_instance(row)
  local meta = getmetatable(row)
  return meta and meta.__SQL_BUILDER__
end

---@param ModelClass Model
local function make_record_meta(ModelClass)
  local RecordClass = {}

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

---@param ModelClass Model
---@return Model
local function create_model_proxy(ModelClass)
  local proxy = {}
  local function __index(_, k)
    local sql_k = Sql[k]
    if type(sql_k) == 'function' then
      return function(_, ...)
        return sql_k(ModelClass:create_sql(), ...)
      end
    end
    local model_k = ModelClass[k]
    if type(model_k) == 'function' then
      return function(cls, ...)
        if cls == proxy then
          return model_k(ModelClass, ...)
        else
          error(format("Invalid call to model proxy method %s: the first argument must be itself.", k))
        end
      end
    else
      return model_k
    end
  end
  local function __newindex(t, k, v)
    rawset(ModelClass, k, v)
  end
  local function __call(t, ...)
    return ModelClass:create_record(...)
  end
  return setmetatable(proxy, {
    __call = __call,
    __index = __index,
    __newindex = __newindex
  })
end

---@class Model:Sql
---@operator call:Model
---@field private __index Model
---@field private __normalized__? boolean
---@field _table_name_token string
---@field __IS_MODEL_CLASS__? boolean
---@field private __SQL_BUILDER__? boolean
---@field DEFAULT  fun():'DEFAULT'
---@field NULL  userdata
---@field db_config? QueryOpts
---@field as_token  fun(DBValue):string
---@field as_literal  fun(DBValue):string
---@field default_related_name string The name that will be used by default for the relation from a related object back to this one. The default is <model_name>_set
---@field RecordClass table
---@field extends? table
---@field admin? table
---@field is_role_model? boolean
---@field table_name string
---@field class_name string
---@field referenced_label_column? string
---@field preload? boolean
---@field label string
---@field app_label string
---@field fields {[string]:AnyField}
---@field field_names Array<string>
---@field mixins? table[]
---@field abstract? boolean
---@field auto_primary_key? boolean
---@field primary_key string
---@field unique_together? string[]|string[][]
---@field names Array<string>
---@field detail_names Array<string>
---@field auto_now_name string
---@field auto_now_add_name string
---@field foreignkey_fields {[string]:ForeignkeyField}
---@field column_cache {[string]:string}
---@field clean? function
---@field name_to_label {[string]:string}
---@field label_to_name {[string]:string}
---@field reversed_fields {[string]:ForeignkeyField}
local Model = {
  __SQL_BUILDER__ = true,
  smart_quote = smart_quote,
  query = Query {},
  auto_primary_key = true,
  DEFAULT_PRIMARY_KEY = DEFAULT_PRIMARY_KEY,
  NULL = NULL,
  DEFAULT = DEFAULT,
  token = make_token,
  as_token = as_token,
  as_literal = as_literal,
  Q = Q,
  F = F,
  Count = Count,
  Sum = Sum,
  Avg = Avg,
  Max = Max,
  Min = Min,
  StdDev = StdDev,
  Variance = Variance,
}
setmetatable(Model, {
  __call = function(t, ...)
    return t:mix(BaseModel, ...)
  end
})

Model.__index = Model

---@class ModelOpts
---@field private __normalized__? boolean
---@field app_label? string
---@field extends? table
---@field mixins? table[]
---@field abstract? boolean
---@field is_role_model? boolean
---@field admin? table
---@field table_name? string
---@field class_name? string
---@field label? string
---@field fields? {[string]:table}
---@field field_names? Array<string>
---@field auto_primary_key? boolean
---@field primary_key? string
---@field unique_together? string[]|string[][]
---@field db_config? QueryOpts
---@field referenced_label_column? string
---@field preload? boolean

---@param attrs? table
---@return Model
function Model:new(attrs)
  return setmetatable(attrs or {}, self)
end

---@param options ModelOpts
---@return Model
function Model:create_model(options)
  return self:_make_model_class(self:normalize(options))
end

---@param callback function
function Model:transaction(callback)
  return self.query.transaction(callback)
end

function Model:atomic(func)
  return function(request)
    return self:transaction(function()
      return func(request)
    end)
  end
end

---@param options {[string]:any}
---@return AnyField
function Model:make_field_from_json(options)
  assert(not options[1])
  assert(options.name, "no name provided")
  options = clone(options)
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
  return res
end

---@return Sql
function Model:create_sql()
  local table_token = self._table_name_token

  if not table_token then
    local table_name = self.table_name or error("table_name not set")
    table_token = smart_quote(table_name)
  end
  return Sql:new {
    model = self,
    table_name = table_token,
    _as = "T"
  }
end

---@param table_name string
---@param rows Record[]
---@return Sql
function Model:create_sql_as(table_name, rows)
  -- rows will NOT be processed by _prepare_db_rows
  local alias_sql = Sql:new { model = self, table_name = table_name, _as = 'T' }
  return alias_sql:with_values(table_name, rows)
end

---@param model any
---@return boolean
function Model:is_model_class(model)
  return type(model) == 'table' and model.__IS_MODEL_CLASS__
end

---@param name string
function Model:check_field_name(name)
  check_conflicts(name);
  assert(not Utils.IS_PG_KEYWORDS[name:upper()],
    format("%s is a postgresql reserved word, can't be used as a table or column name", name))
  assert(not Sql.EXPR_OPERATORS[name:upper()],
    format("%s is a sql expression operator, can't be used as a table or column name", name))
  if (self[name] ~= nil and name ~= 'class') then
    error(format("field name '%s' conflicts with model class attributes", name))
  end
end

---@private
---@param opts ModelOpts
---@return Model
function Model:_make_model_class(opts)
  local auto_primary_key
  if opts.auto_primary_key == nil then
    auto_primary_key = Model.auto_primary_key
  else
    auto_primary_key = opts.auto_primary_key
  end
  local ModelClass = dict(self, {
    table_name = opts.table_name,
    class_name = opts.class_name,
    admin = opts.admin or {},
    label = opts.label or opts.table_name,
    fields = opts.fields,
    field_names = opts.field_names,
    mixins = opts.mixins,
    extends = opts.extends,
    abstract = opts.abstract,
    is_role_model = opts.is_role_model,
    primary_key = opts.primary_key,
    unique_together = opts.unique_together,
    auto_primary_key = auto_primary_key,
    referenced_label_column = opts.referenced_label_column,
    preload = opts.preload,
    app_label = opts.app_label,
    names = Array {},
    detail_names = Array {},
    foreignkey_fields = {},
    reversed_fields = {},
  })
  if ModelClass.preload == nil then
    ModelClass.preload = true
  end
  local options = opts.db_config or self.db_config
  if options then
    ModelClass.query = Query(options)
  end
  ModelClass.__index = ModelClass
  local pk_defined = false
  for _, name in ipairs(ModelClass.field_names) do
    local field = ModelClass.fields[name]
    field.get_model = function() return ModelClass end
    if field.primary_key then
      local pk_name = field.name
      assert(not pk_defined, format('duplicated primary key: "%s" and "%s"', pk_name, pk_defined))
      pk_defined = pk_name
      ModelClass.primary_key = pk_name
      if not field.serial then
        ModelClass.names:push(pk_name)
      end
    else
      ModelClass.detail_names:push(name)
      if field.auto_now then
        ModelClass.auto_now_name = field.name
      elseif field.auto_now_add then
        ModelClass.auto_now_add_name = field.name
      else
        ModelClass.names:push(name)
      end
    end
  end
  -- move to resolve_foreignkey_self
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
        error(format("invalid unique_together name %s for model %s", name, ModelClass.table_name))
      end
    end
    uniques:push(Array(clone(unique_group)))
  end
  ModelClass.unique_together = uniques
  ModelClass.__IS_MODEL_CLASS__ = true
  if ModelClass.table_name then
    ModelClass:materialize_with_table_name { table_name = ModelClass.table_name }
  end
  ModelClass:set_label_name_dict()
  ModelClass:ensure_admin_list_names();
  if ModelClass.auto_now_add_name then
    ModelClass:ensure_ctime_list_names(ModelClass.auto_now_add_name);
  end
  Model.resolve_foreignkey_self(ModelClass)
  if not opts.abstract then
    Model.resolve_foreignkey_related(ModelClass)
  end
  local proxy = create_model_proxy(ModelClass)
  return proxy
end

local EXTEND_ATTRS = { 'table_name', 'label', 'referenced_label_column', 'preload' }
---@param options ModelOpts
---@return ModelOpts
function Model:normalize(options)
  local extends = options.extends
  local abstract
  if options.abstract ~= nil then
    abstract = not not options.abstract
  else
    abstract = options.table_name == nil
  end
  local model = {
    table_name = options.table_name,
    admin = clone(options.admin or {}),
  }
  for _, extend_attr in ipairs(EXTEND_ATTRS) do
    if options[extend_attr] == nil and extends and extends[extend_attr] then
      model[extend_attr] = extends[extend_attr]
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
    if not abstract then
      self.check_field_name(model, name)
    end
    local field = opts_fields[name]
    if not field then
      local tname = model.table_name or '[abstract model]'
      if extends then
        field = extends.fields[name]
        if not field then
          error(format("'%s' field name '%s' is not in fields and parent fields", tname, name))
        else
          field = ensure_field_as_options(field, name)
        end
      else
        error(format("Model class '%s's field name '%s' is not in fields", tname, name))
      end
    elseif extends and extends.fields[name] then
      local pfield = extends.fields[name]
      local m_field = dict(pfield:get_options(), field)
      if pfield.attrs or field.attrs then
        m_field.attrs = dict(pfield.attrs, field.attrs)
      end
      field = m_field
      if pfield.model and field.model then
        field.model = self:create_model {
          abstract = true,
          extends = pfield.model,
          fields = field.model.fields,
          field_names = field.model.field_names
        }
      end
    end
    model.fields[name] = self:make_field_from_json(dict(field, { name = name }))
  end
  for key, value in pairs(options) do
    if model[key] == nil and MODEL_MERGE_NAMES[key] then
      model[key] = value
    end
  end
  if not options.unique_together and extends and extends.unique_together then
    model.unique_together = extends.unique_together:filter(function(group)
      return Array.every(group, function(name)
        return model.fields[name]
      end)
    end)
  end
  local unique_together = model.unique_together or {}
  if type(unique_together[1]) == 'string' then
    unique_together = { unique_together }
  end
  model.unique_together = unique_together
  model.abstract = abstract
  model.__normalized__ = true
  if options.mixins then
    local models = list(options.mixins, { model })
    local merge_model = self:merge_models(models)
    return merge_model
  else
    return model
  end
end

function Model:set_label_name_dict()
  self.label_to_name = {}
  self.name_to_label = {}
  for name, field in pairs(self.fields) do
    self.label_to_name[field.label] = name
    self.name_to_label[name] = field.label
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

function Model:ensure_admin_list_names()
  self.admin.list_names = Array(clone(self.admin.list_names or {}));
  if #self.admin.list_names == 0 then
    self.admin.list_names = get_admin_list_names(self)
  end
end

function Model:ensure_ctime_list_names(ctime_name)
  local admin = assert(self.admin)
  if not admin.list_names:includes(ctime_name) then
    admin.list_names = list(admin.list_names, { ctime_name })
  end
end

function Model:resolve_foreignkey_self()
  for _, name in ipairs(self.field_names) do
    local field = self.fields[name]
    local fk_model = field.reference
    if fk_model == "self" then
      ---@cast field ForeignkeyField
      fk_model = self
      field.reference = self
      field:setup_with_fk_model(self)
    end
    if fk_model then
      self.foreignkey_fields[name] = field --[[@as ForeignkeyField]]
    end
  end
end

function Model:resolve_foreignkey_related()
  for _, name in ipairs(self.field_names) do
    local field = self.fields[name] --[[@as ForeignkeyField]]
    local fk_model = field.reference
    if fk_model then
      if field.related_name == nil then
        field.related_name = format("%s_set", self.table_name)
      end
      if field.related_query_name == nil then
        field.related_query_name = self.table_name
      end
      -- reversed foreignkey field
      local rqn = field.related_query_name
      assert(not self.fields[rqn],
        format("model '%s'.'%s' related_query_name '%s' conflicts with field name", self.table_name, field.name, rqn))
      fk_model.reversed_fields[rqn] = field
      -- { -- Blog / Poll
      --   is_reversed = true,
      --   name = field.related_query_name,                     -- entry / poll_log
      --   reference = self,                                     -- Entry / PollLog
      --   reference_column = name                              -- blog_id / poll_id
      -- }
      --define: Entry.blog_id   {name='blog_id',  reference=Blog,    related_query_name=entry, }
      --reversed: {name='entry',    reference=Entry,   reference_column='blog_id'}
    end
  end
end

---@param opts {table_name:string, label?:string}
---@return Model
function Model:materialize_with_table_name(opts)
  local table_name = opts.table_name
  local label = opts.label
  if not table_name then
    local names_hint = self.field_names and self.field_names:join(",") or "no field_names"
    error(format("you must define table_name for a non-abstract model (%s)", names_hint))
  end
  check_conflicts(table_name)
  self.table_name = table_name
  self._table_name_token = smart_quote(table_name)
  self.class_name = to_camel_case(table_name)
  self.label = self.label or label or table_name
  self.abstract = false
  if not self.primary_key and self.auto_primary_key then
    local pk_name = DEFAULT_PRIMARY_KEY
    assert(not self.fields[pk_name], format("field '%s' already exists", pk_name))
    self.primary_key = pk_name
    self.fields[pk_name] = Fields.integer:create_field { name = pk_name, primary_key = true, serial = true }
    insert(self.field_names, 1, pk_name)
  end
  for name, field in pairs(self.fields) do
    field._column_token = smart_quote(name)
    if field.reference then
      field.table_name = table_name
    end
  end
  self.RecordClass = make_record_meta(self)
  return self
end

---@param ... ModelOpts
---@return Model
function Model:mix(...)
  return self:_make_model_class(self:merge_models { ... })
end

---@param models ModelOpts[]
---@return ModelOpts
function Model:merge_models(models)
  assert(#models >= 2, "provide at least two models to merge")
  local merged = models[1]
  for i = 2, #models do
    merged = self:merge_model(merged, models[i])
  end
  return merged
end

---@param a ModelOpts
---@param b ModelOpts
---@return ModelOpts
function Model:merge_model(a, b)
  local A = a.__normalized__ and a or self:normalize(a)
  local B = b.__normalized__ and b or self:normalize(b)
  local C = {}
  local field_names = A.field_names:concat(B.field_names):unique()
  local fields = {}
  for i, name in ipairs(field_names) do
    local af = A.fields[name]
    local bf = B.fields[name]
    if af and bf then
      fields[name] = Model:merge_field(af, bf)
    elseif af then
      fields[name] = af
    elseif bf then
      fields[name] = bf
    else
      error(
        format("can't find field %s for model %s and %s", name, A.table_name, B.table_name))
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
  return self:normalize(C)
end

---@param a AnyField
---@param b AnyField
---@return AnyField
function Model:merge_field(a, b)
  local aopts = is_field_class(a) and a:get_options() or clone(a)
  local bopts = is_field_class(b) and b:get_options() or clone(b)
  local options = dict(aopts, bopts)
  if aopts.attrs or bopts.attrs then
    options.attrs = dict(aopts.attrs, bopts.attrs)
  end
  if aopts.model and bopts.model then
    options.model = self:merge_model(aopts.model, bopts.model)
  end
  return self:make_field_from_json(options)
end

---@param names? string[]|string
---@return ModelOpts
function Model:to_json(names)
  local reversed_fields = {}
  for name, field in pairs(self.reversed_fields) do
    if field.reference then
      reversed_fields[name] = {
        name = field.name,
        reference = field.reference.table_name,
        reference_column = field.reference_column
      }
    end
  end
  if not names then
    return {
      table_name = self.table_name,
      class_name = self.class_name,
      primary_key = self.primary_key,
      label = self.label or self.table_name,
      app_label = self.app_label,
      names = clone(self.names),
      field_names = clone(self.field_names),
      label_to_name = clone(self.label_to_name),
      name_to_label = clone(self.name_to_label),
      admin = clone(self.admin),
      unique_together = clone(self.unique_together),
      detail_names = clone(self.detail_names),
      reversed_fields = reversed_fields,
      fields = self.field_names:map(function(name)
        return { name, self.fields[name]:json() }
      end):reduce(function(acc, pair)
        acc[pair[1]] = pair[2]
        return acc
      end, {}),
    }
  else
    if type(names) ~= 'table' then
      names = { names }
    end
    local label_to_name = {}
    local name_to_label = {}
    local fields = {}
    for i, name in ipairs(names) do
      local field = self.fields[name]
      label_to_name[field.label] = name
      name_to_label[field.name] = field.label
      fields[name] = field:json()
    end
    return {
      table_name = self.table_name,
      class_name = self.class_name,
      primary_key = self.primary_key,
      label = self.label or self.table_name,
      app_label = self.app_label,
      names = names,
      field_names = names,
      label_to_name = label_to_name,
      name_to_label = name_to_label,
      admin = clone(self.admin),
      unique_together = clone(self.unique_together),
      detail_names = clone(self.detail_names),
      reversed_fields = reversed_fields,
      fields = fields,
    }
  end
end

---@param key  string
---@return string
function Model:check_unique_key(key)
  local pkf = self.fields[key]
  if not pkf then
    error("invalid field name: " .. key)
  end
  if not (pkf.primary_key or pkf.unique) then
    error(format("field '%s' is not primary_key or not unique", key))
  end
  return key
end

-- https://docs.djangoproject.com/en/5.1/ref/models/querysets/#methods-that-do-not-return-querysets
function Model:create(input)
  return self:save_create(input, self.names, '*')
end

---@param input Record
---@param names? string[]
---@param key?  string
---@return ModelInstance
function Model:save(input, names, key)
  local uk = key or self.primary_key
  names = names or self.names
  if rawget(input, uk) ~= nil then
    return self:save_update(input, names, uk)
  else
    return self:save_create(input, names, key)
  end
end

---@param input Record
---@param names? string[]
---@param key?  string
---@return ModelInstance
function Model:save_create(input, names, key)
  names = names or self.names
  local data = self:validate_create(input, names)
  local prepared = self:_prepare_for_db(data, names)
  local created = self:create_sql():_base_insert(prepared):_base_returning(key or '*'):execr()
  for k, v in pairs(created[1]) do
    data[k] = v
  end
  return self:create_record(data)
end

---@param input Record
---@param names? string[]
---@param key?  string
---@return ModelInstance
function Model:save_update(input, names, key)
  names = names or self.names
  local data = self:validate_update(input, names)
  if not key then
    key = self.primary_key
  else
    key = self:check_unique_key(key)
  end
  local look_value = input[key]
  if look_value == nil then
    error("no primary or unique key value for save_update")
  end
  local prepared = self:_prepare_for_db(data, names)
  local updated = self:create_sql():_base_update(prepared):where { [key] = look_value }
      :_base_returning(key):execr()
  ---@cast updated Record
  if #updated == 1 then
    data[key] = updated[1][key]
    return self:create_record(data)
  elseif #updated == 0 then
    error(format("update failed, record does not exist(model:%s, key:%s, value:%s)", self.table_name,
      key, look_value))
  else
    error(format("expect 1 but %s records are updated(model:%s, key:%s, value:%s)",
      #updated,
      self.table_name,
      key,
      look_value))
  end
end

---@param data Record
---@param columns? string[]
---@return Record
function Model:_prepare_for_db(data, columns)
  local prepared = {}
  for _, name in ipairs(columns or self.names) do
    local field = self.fields[name]
    if not field then
      error(format("invalid field name '%s' for model '%s'", name, self.table_name))
    end
    local value = data[name]
    if field.prepare_for_db and (value ~= nil or field.auto_now) then
      local val, err = field:prepare_for_db(value)
      if val == nil and err then
        error(self:make_field_error(name, err))
      else
        prepared[name] = val
      end
    else
      prepared[name] = value
    end
  end
  return prepared
end

---@param input Record user input
---@param names? string[] field names to validate, default: model.names
---@param key? string key to check if the input is validated as an update or create, default: model.primary_key
---@return Record
function Model:validate(input, names, key)
  if rawget(input, key or self.primary_key) ~= nil then
    return self:validate_update(input, names or self.names)
  else
    return self:validate_create(input, names or self.names)
  end
end

local function throw_field_error(name, table_name)
  error(format("invalid field name '%s' for model '%s'", name, table_name))
end

---@param input Record
---@param names? string[]
---@return Record
function Model:validate_create(input, names)
  if next(input) == nil then
    error("empty input for validate_create")
  end
  ---@type Record
  local data = {}
  for _, name in ipairs(names or self.names) do
    local field = self.fields[name]
    if not field then
      throw_field_error(name, self.table_name)
    end
    local value, err, index = field:validate(rawget(input, name))
    if err ~= nil then
      error(self:make_field_error(name, err, index))
    elseif field.default and (value == nil or value == "") then
      if type(field.default) ~= "function" then
        value = field.default
      else
        value, err = field.default()
        if value == nil then
          ---@cast err string
          error(self:make_field_error(name, tostring(err), index))
        end
      end
    end
    data[name] = value
  end
  return data
end

---@param input Record
---@param names? string[]
---@return Record
function Model:validate_update(input, names)
  ---@type Record
  local data = {}
  for _, name in ipairs(names or self.names) do
    local field = self.fields[name]
    if not field then
      throw_field_error(name, self.table_name)
    end
    local err, index
    local value = rawget(input, name)
    if value ~= nil then
      value, err, index = field:validate(value)
      if err ~= nil then
        error(self:make_field_error(name, err, index))
      elseif value == nil then
        -- value is nil again after validate, its a non-required field whose value is empty string.
        -- for unique fields, use NULL to avoid duplicate key violation (multiple '' would conflict,
        -- but multiple NULLs are allowed by SQL unique constraints).
        -- for non-unique fields, use empty string to make _prepare_for_db work.
        data[name] = field.unique and NULL or ""
      else
        data[name] = value
      end
    end
  end
  return data
end

---@param tf TableField like MegaDoc.dests
---@return ForeignkeyField? like Dest.doc_id
function Model:_get_cascade_field(tf)
  if tf.cascade_column then
    return tf.model.fields[tf.cascade_column]
  end
  local table_validate_columns = tf.names or tf.form_names or tf.model.names
  for i, column in ipairs(table_validate_columns) do
    local fk = tf.model.fields[column]
    if fk == nil then
      error(format("cascade field '%s' not found for model '%s'", column, self.table_name))
    end
    if fk.type == 'foreignkey' and fk.reference.table_name == self.table_name then
      return fk
    end
  end
end

---@param callback fun(tf:TableField, fk:ForeignkeyField)
function Model:_walk_cascade_fields(callback)
  for _, name in ipairs(self.names) do
    local field = self.fields[name]
    if field.type == 'table' and not field.model.abstract then
      local fk = self:_get_cascade_field(field)
      if not fk then
        error(format("cascade field '%s' not found for model '%s'", field.name, self.table_name))
      end
      callback(field, fk)
    end
  end
end

---@param input Record
---@param names? string[]
---@return Record
function Model:validate_cascade_update(input, names)
  local data = self:validate_update(input, names)
  self:_walk_cascade_fields(function(tf, fk)
    local rows = data[tf.name] ---@cast rows Record[]
    if not rows then
      return
    end
    for _, row in ipairs(rows) do
      row[fk.name] = input[fk.reference_column]
    end
  end)
  return data
end

---@param input Record
---@param names? string[]
---@param key?  string
---@return ModelInstance
function Model:save_cascade_update(input, names, key)
  names = Array(names or self.names)
  local data = self:validate_cascade_update(input, names)
  if not key then
    key = self.primary_key
  else
    key = self:check_unique_key(key)
  end
  local look_value = input[key]
  if look_value == nil then
    error("no primary or unique key value for save_update")
  end
  local names_without_tablefield = names:filter(function(name)
    return self.fields[name].type ~= 'table'
  end)
  local prepared = self:_prepare_for_db(data, names_without_tablefield)
  local updated_sql = self:create_sql():_base_update(prepared):where { [key] = look_value }
      :_base_returning(key):_base_returning(names_without_tablefield)
  self:_walk_cascade_fields(function(tf, fk)
    local rows = data[tf.name] ---@cast rows Record[]
    if not rows then
      return
    end
    if #rows > 0 then
      local align_sql = tf.model:where { [fk.name] = input[fk.reference_column] }:skip_validate():align(rows)
      updated_sql:prepend(align_sql)
    else
      local delete_sql = tf.model:delete():where { [fk.name] = input[fk.reference_column] }
      updated_sql:prepend(delete_sql)
    end
  end)
  local ins = updated_sql:exec()
  if #ins == 0 then
    error("no record updated")
  end
  return ins[1]
end

---@param rows Record|Record[]
---@param key Keys
function Model:_check_upsert_key_error(rows, key)
  assert(key, "no key for upsert")
  if #rows > 0 then
    ---@cast rows Record[]
    if type(key) == "string" then
      for i, row in ipairs(rows) do
        if row[key] == nil or row[key] == '' then
          local label = self.fields[key].label
          local err = self:make_field_error(key, label .. "不能为空")
          err.batch_index = i
          error(err)
        end
      end
    else
      for i, row in ipairs(rows) do
        for _, k in ipairs(key) do
          if row[k] == nil or row[k] == '' then
            local label = self.fields[k].label
            local err = self:make_field_error(k, label .. "不能为空")
            err.batch_index = i
            error(err)
          end
        end
      end
    end
  elseif type(key) == "string" then
    ---@cast rows Record
    local label = self.fields[key].label
    if rows[key] == nil or rows[key] == '' then
      error(self:make_field_error(key, label .. "不能为空"))
    end
  else
    ---@cast rows Record
    for _, k in ipairs(key) do
      if rows[k] == nil or rows[k] == '' then
        local label = self.fields[k].label
        error(self:make_field_error(k, label .. "不能为空"))
      end
    end
  end
end

---@param name string field name
---@param err string error message
---@param index? integer error row index returned by TableField's validate function
---@return ValidateError
function Model:make_field_error(name, err, index)
  local field = assert(self.fields[name], "invalid field name: " .. name)
  return {
    type = 'field_error',
    message = err,
    index = index,
    name = field.name,
    label = field.label,
  }
end

---@param data Record
---@return ModelInstance
function Model:load(data)
  for _, name in ipairs(self.names) do
    local field = self.fields[name]
    local value = data[name]
    if value ~= nil and field.load then
      data[name] = field:load(value)
    end
  end
  return self:create_record(data)
end

---used in merge and upsert
---@param rows Record|Record[]
---@param columns string[]
---@return Records
function Model:_validate_create_data(rows, columns)
  if rows[1] then
    ---@cast rows Record[]
    ---@type Record[]
    local cleaned = {}
    for index, row in ipairs(rows) do
      local ok, validated_row = pcall(self.validate_create, self, row, columns)
      if not ok then
        ---@cast validated_row ValidateError
        if type(validated_row) == 'table' then
          validated_row.batch_index = index
        end
        error(validated_row)
      end
      cleaned[index] = validated_row
    end
    return cleaned
  else
    ---@cast rows Record
    local ok, cleaned = pcall(self.validate_create, self, rows, columns)
    if not ok then
      error(cleaned)
    end
    return cleaned
  end
end

---@param rows Record|Record[]
---@param columns string[]
---@return Records
function Model:_validate_update_data(rows, columns)
  if rows[1] then
    ---@cast rows Record[]
    ---@type Record[]
    local cleaned = {}
    for index, row in ipairs(rows) do
      local ok, validated_row = pcall(self.validate_update, self, row, columns)
      if not ok then
        ---@cast validated_row ValidateError
        if type(validated_row) == 'table' then
          validated_row.batch_index = index
        end
        error(validated_row)
      end
      cleaned[index] = validated_row
    end
    return cleaned
  else
    ---@cast rows Record
    local ok, cleaned = pcall(self.validate_update, self, rows, columns)
    if not ok then
      error(cleaned)
    end
    return cleaned
  end
end

---used in merge and upsert
---@param rows Record|Record[]
---@param key Keys
---@param columns string[]
---@return Records
function Model:_validate_create_rows(rows, key, columns)
  self:_check_upsert_key_error(rows, key)
  return self:_validate_create_data(rows, columns)
end

---@param rows Record|Record[]
---@param key Keys
---@param columns string[]
---@return Records
function Model:_validate_update_rows(rows, key, columns)
  self:_check_upsert_key_error(rows, key)
  return self:_validate_update_data(rows, columns)
end

---@param rows Record|Record[]
---@param columns string[]
---@return Records
function Model:_prepare_db_rows(rows, columns)
  if rows[1] then
    ---@cast rows Record[]
    ---@type Record[]
    local cleaned = {}
    for i, row in ipairs(rows) do
      local ok, prow = pcall(self._prepare_for_db, self, row, columns)
      if not ok then
        if type(prow) == 'table' then
          prow.batch_index = i
        end
        error(prow)
      else
        cleaned[i] = prow
      end
    end
    return cleaned
  else
    ---@cast rows Record
    local ok, prow = pcall(self._prepare_for_db, self, rows, columns)
    if not ok then
      error(prow)
    else
      return prow
    end
  end
end

---@param row any
---@return boolean
function Model:is_instance(row)
  return is_sql_instance(row)
end

---@param data table
---@return ModelInstance
function Model:create_record(data)
  return setmetatable(data, self.RecordClass)
end

local whitelist = { DEFAULT = true, as_token = true, as_literal = true, __call = true, new = true, token = true }
for k, v in pairs(Sql) do
  if type(v) == 'function' and not whitelist[k] then
    assert(Model[k] == nil, format("Model.%s can't be defined as Sql.%s already exists", k, k))
  end
end
return Model
