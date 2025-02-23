local clone = require "table.clone"
local isarray = require("table.isarray")
local Validator = require "resty.validator"
local Array = require "resty.array"
local getenv = require("resty.dotenv").getenv
local get_payload = require "resty.alioss".get_payload
local string_format = string.format
local table_concat = table.concat
local table_insert = table.insert
local ipairs = ipairs
local setmetatable = setmetatable
local type = type
local rawset = rawset
local ngx_localtime = ngx.localtime


---@param a table
---@param b? table
---@return table
local function dict(a, b)
  local t = clone(a)
  if b then
    for k, v in pairs(b) do
      t[k] = v
    end
  end
  return t
end

---@param a table
---@param b? table
---@return table
local function list(a, b)
  local t = clone(a)
  if b then
    for _, v in ipairs(b) do
      t[#t + 1] = v
    end
  end
  return t
end

---@param tbl table
---@param func function
---@return Array
local function map(tbl, func)
  local res = Array()
  for i = 1, #tbl do
    res[i] = func(tbl[i])
  end
  return res
end

---@param s string
---@param sep? string
---@return Array
local function split(s, sep)
  local res = {}
  sep = sep or ""
  local i = 1
  local a, b
  while true do
    a, b = s:find(sep, i, true)
    if a then
      local e = s:sub(i, a - 1)
      i = b + 1
      res[#res + 1] = e
    else
      res[#res + 1] = s:sub(i)
      return res
    end
  end
end

---@alias AnyField
---| StringField
---| UUIDField
---| SfzhField
---| EmailField
---| PasswordField
---| TextField
---| IntegerField
---| FloatField
---| DatetimeField
---| DateField
---| YearMonthField
---| YearField
---| MonthField
---| TimeField
---| JsonField
---| ArrayField
---| TableField
---| ForeignkeyField
---| BooleanField
---| AliossField
---| AliossImageField
---| AliossListField
---| AliossImageListField


local INHERIT_METHODS = {
  new = true,
  __add = true,
  __sub = true,
  __mul = true,
  __div = true,
  __mod = true,
  __pow = true,
  __unm = true,
  __concat = true,
  __len = true,
  __eq = true,
  __lt = true,
  __le = true,
  __index = true,
  __newindex = true,
  __call = true,
  __tostring = true
}
local function class_new(cls, self)
  return setmetatable(self or {}, cls)
end

local function class__call(cls, attrs)
  local self = cls:new()
  self:init(attrs)
  return self
end

local function class__init(self, attrs)

end

---make a class with methods: __index, __call, new
---@generic T
---@param cls T
---@param parent? table
---@return T
local function class(cls, parent)
  if parent then
    for key, value in pairs(parent) do
      if cls[key] == nil then
        cls[key] = value
      end
    end
    setmetatable(cls, parent)
    for method, _ in pairs(INHERIT_METHODS) do
      if cls[method] == nil and parent[method] ~= nil then
        cls[method] = parent[method]
      end
    end
  end
  cls.new = cls.new or class_new
  cls.init = cls.init or class__init
  cls.__call = cls.__call or class__call
  cls.__index = cls
  return cls
end

local function utf8len(s)
  local _, cnt = s:gsub("[^\128-\193]", "")
  return cnt
end

local size_table = {
  k = 1024,
  m = 1024 * 1024,
  g = 1024 * 1024 * 1024,
  kb = 1024,
  mb = 1024 * 1024,
  gb = 1024 * 1024 * 1024
}

---@param t string|number
---@return integer
local function byte_size_parser(t)
  if type(t) == "string" then
    local unit = t:gsub("^(%d+)([^%d]+)$", "%2"):lower()
    local ts = t:gsub("^(%d+)([^%d]+)$", "%1"):lower()
    local bytes = size_table[unit]
    assert(bytes, "invalid size unit: " .. unit)
    local num = tonumber(ts)
    assert(num, "can't convert `" .. ts .. "` to a number")
    return num * bytes
  elseif type(t) == "number" then
    return t
  else
    error("invalid type:" .. type(t))
  end
end

local BaseField
local StringField
local UUIDField
local SfzhField
local EmailField
local PasswordField
local TextField
local IntegerField
local FloatField
local DatetimeField
local DateField
local YearMonthField
local YearField
local MonthField
local TimeField
local JsonField
local ArrayField
local TableField
local ForeignkeyField
local BooleanField
local AliossField
local AliossImageField
local AliossListField
local AliossImageListField

local function get_fields()
  return {
    string = StringField,
    uuid = UUIDField,
    sfzh = SfzhField,
    email = EmailField,
    password = PasswordField,
    text = TextField,
    integer = IntegerField,
    float = FloatField,
    datetime = DatetimeField,
    date = DateField,
    year_month = YearMonthField,
    year = YearField,
    month = MonthField,
    time = TimeField,
    json = JsonField,
    array = ArrayField,
    table = TableField,
    foreignkey = ForeignkeyField,
    boolean = BooleanField,
    alioss = AliossField,
    alioss_image = AliossImageField,
    alioss_list = AliossListField,
    alioss_image_list = AliossImageListField,
  }
end

local shortcuts_names = { 'name', 'label', 'type', 'required' }

---@param field AnyField
---@return AnyField
local function normalize_field_shortcuts(field)
  field = clone(field)
  for i, prop in ipairs(shortcuts_names) do
    if field[prop] == nil and field[i] ~= nil then
      field[prop] = field[i]
      field[i] = nil
    end
  end
  return field
end

local TABLE_MAX_ROWS = 1
local CHOICES_ERROR_DISPLAY_COUNT = 30
local DEFAULT_ERROR_MESSAGES = { required = "此项必填", choices = "无效选项" }
local DEFAULT_BOOLEAN_CHOICES = { { label = '是', value = true }, { label = '否', value = false } }
local VALID_FOREIGN_KEY_TYPES = {
  foreignkey = tostring,
  string = tostring,
  sfzh = tostring,
  integer = Validator.integer,
  float = tonumber,
  datetime = Validator.datetime,
  date = Validator.date,
  time = Validator.time
}
local NULL = ngx.null
local FK_TYPE_NOT_DEFIEND = {}

local PRIMITIVE_TYPES = {
  string = true,
  number = true,
  boolean = true,
  -- table = true,
}

local function clean_choice(c)
  if isarray(c) then
    local value, label, hint = unpack(c)
    return value, label or value, hint
  else
    local value = c.value
    local label = c.label
    local hint = c.hint
    return value, label or value, hint
  end
end

local function normalize_choice(c)
  if PRIMITIVE_TYPES[type(c)] then
    return { value = c, label = tostring(c) }
  elseif type(c) == "table" then
    local res = {}
    for k, v in pairs(c) do
      if type(k) == 'string' then
        res[k] = v
      end
    end
    local value, label, hint = clean_choice(c)
    res.value = value
    res.label = label
    res.hint = hint
    return res
  else
    error("invalid choice type:" .. type(c))
  end
end

local function string_choices_to_array(s)
  local choices = Array {}
  local spliter = s:find('\n') and '\n' or ','
  for _, line in ipairs(split(s, spliter)) do
    line = assert(Validator.trim(line))
    if line ~= "" then
      choices[#choices + 1] = line
    end
  end
  return choices
end

local function get_choices(raw_choices)
  if type(raw_choices) == 'string' then
    raw_choices = string_choices_to_array(raw_choices)
  end
  if type(raw_choices) ~= 'table' then
    error(string_format("choices type must be table ,not %s", type(raw_choices)))
  end
  return Array(raw_choices):map(normalize_choice)
end

local function serialize_choice(choice)
  return tostring(choice.value)
end

local function get_choices_error_message(choices)
  local valid_choices = table_concat(map(choices, serialize_choice), "，")
  return string_format("限下列选项：%s", valid_choices)
end

local function get_choices_validator(choices, message, is_array)
  if #choices <= CHOICES_ERROR_DISPLAY_COUNT then
    message = string_format("%s，%s", message, get_choices_error_message(choices))
  end
  local is_choice = {}
  for _, c in ipairs(choices) do
    is_choice[c.value] = true
  end
  if is_array then
    local function array_choices_validator(value)
      if type(value) ~= 'table' then
        return nil, "类型必须是数组，当前是：" .. type(value)
      end
      for i, e in ipairs(value) do
        if not is_choice[e] then
          return nil, string_format('“%s”%s', e, message)
        end
      end
      return value
    end

    return array_choices_validator
  else
    local function choices_validator(value)
      if not is_choice[value] then
        return nil, string_format('“%s”%s', value, message)
      else
        return value
      end
    end

    return choices_validator
  end
end

local base_option_names = {
  "primary_key",
  "null",
  "unique",
  "index",
  "db_type",
  "required",
  "disabled",
  "default",
  "label",
  "hint",
  "error_messages",
  "choices",
  "strict",
  "choices_url",
  "choices_url_method",
  "autocomplete",
  "max_display_count", -- 前端autocomplete.choices最大展示数
  "max_choices_count", -- 前端autocomplete.choices最大数
  "preload",
  "lazy",
  "tag",
  "group", -- fui联动choices
  "attrs",
}

---@class FieldAttrsOpts
---@field wx_phone boolean uniapp
---@field wx_avatar boolean uniapp
---@field limit string uniapp
---@field auto_size boolean|table antdv
---@field value_format string antdv
---@field time_format string antdv
---@field list_type string antdv
---@field multiple string antdv
---@field accept string antdv
---@field button_text string antdv
---@field tooltipVisible string antdv

---@class BaseField
---@overload fun(options: table): BaseField
---@operator add(BaseField): string
---@operator sub(BaseField): string
---@diagnostic disable-next-line: unknown-operator
---@operator eq(BaseField): string
---@field private __call function
---@field private __is_field_class__ true
---@field validators function[]
---@field option_names string[]
---@field attrs FieldAttrsOpts
---@field type string
---@field db_type? string
---@field name string
---@field label? string
---@field primary_key? boolean
---@field null? boolean
---@field unique? boolean
---@field index? boolean
---@field required? boolean
---@field disabled? boolean
---@field default? any
---@field hint? string
---@field error_messages? table
---@field group? boolean
---@field choices? Array
---@field strict? boolean
---@field choices_url? string
---@field max_choices_count? integer
---@field max_display_count? integer
---@field choices_url_method? "GET"|"POST"|"PATCH"|"PUT"|"OPTIONS"
---@field autocomplete? boolean
---@field preload? boolean
---@field lazy? boolean
---@field tag? string
---@field get_model fun(AnyField?):Xodel
BaseField = class({}, {
  __tostring = function(self)
    return self.table_name .. '.' .. self.name
  end,
  __add = function(self, b)
    if type(b) == 'number' then
      return string_format("%s.%s + %s", self.table_name, self.name, b)
    end
    return string_format("%s.%s + %s.%s", self.table_name, self.name, b.table_name, b.name)
  end,
  __sub = function(self, b)
    if type(b) == 'number' then
      return string_format("%s.%s - %s", self.table_name, self.name, b)
    end
    return string_format("%s.%s - %s.%s", self.table_name, self.name, b.table_name, b.name)
  end,
  -- __sub = true,
  -- __mul = true,
  -- __div = true,
  -- __mod = true,
  -- __pow = true,
  -- __unm = true,
  -- __concat = true,
  -- __lt = true,
  -- __le = true,
})
BaseField.__is_field_class__ = true
BaseField.option_names = {}
BaseField.normalize_field_shortcuts = normalize_field_shortcuts

---@param subcls table
---@return self
function BaseField:class(subcls)
  return class(subcls, self)
end

function BaseField.__call(cls, options)
  return cls:create_field(options)
end

---@param self AnyField
---@param options table
---@return AnyField
function BaseField.create_field(self, options)
  local res = self:new {}
  res:init(options)
  res.validators = res:get_validators {}
  return res
end

---@param options? table
---@return AnyField
function BaseField:new(options)
  return setmetatable(options or {}, self)
end

---@param options table
---@return self
function BaseField:init(options)
  self.name = assert(options.name, "you must define a name for a field")
  self.type = options.type
  for _, name in ipairs(self:get_option_names()) do
    if options[name] ~= nil then
      self[name] = options[name]
    end
  end
  if options.attrs then
    self.attrs = clone(options.attrs)
  end
  if self.required == nil then
    self.required = false
  end
  if self.db_type == nil then
    self.db_type = self.type
  end
  if self.label == nil then
    self.label = self.name
  end
  if self.null == nil then
    if self.required or self.db_type == 'varchar' or self.db_type == 'text' then
      self.null = false
    else
      self.null = true
    end
  end
  if not self.group and type(self.choices) == 'table' or type(self.choices) == 'string' then
    self.choices = get_choices(self.choices)
  end
  if self.autocomplete then
    if self.max_choices_count == nil then
      self.max_choices_count = tonumber(getenv('MAX_CHOICES_COUNT')) or 100
    end
    if self.max_display_count == nil then
      self.max_display_count = tonumber(getenv('MAX_DISPLAY_COUNT')) or 50
    end
  end
  return self
end

---@return Array<string>
function BaseField:get_option_names()
  return list(base_option_names, self.option_names)
end

---@param key string
---@return string
function BaseField:get_error_message(key)
  if self.error_messages and self.error_messages[key] then
    return self.error_messages[key]
  end
  return DEFAULT_ERROR_MESSAGES[key]
end

---@param validators function[]
---@return function[]
function BaseField:get_validators(validators)
  if self.required then
    table_insert(validators, 1, Validator.required(self:get_error_message('required')))
  else
    table_insert(validators, 1, Validator.not_required)
  end
  -- if type(self.choices_url) == 'string' and self.strict then
  --   local function dynamic_choices_validator(val)
  --     local message = self:get_error_message('choices')
  --     local choices = get_choices(http[self.choices_url_method or 'get'](self.choices_url).body)
  --     for _, c in ipairs(choices) do
  --       if val == c.value then
  --         return val
  --       end
  --     end
  --     if #choices <= CHOICES_ERROR_DISPLAY_COUNT then
  --       message = string_format("%s，%s", message, get_choices_error_message(choices))
  --     end
  --     return nil, message
  --   end
  --   table_insert(validators, dynamic_choices_validator)
  -- end
  if not self.group and type(self.choices) == 'table' and #self.choices > 0 and (self.strict == nil or self.strict) then
    self.static_choice_validator = get_choices_validator(
      self.choices,
      self:get_error_message('choices'),
      self.type == 'array')
    table_insert(validators, self.static_choice_validator)
  end
  return validators
end

---@return {[string]:any}
function BaseField:get_options()
  local ret = {
    name = self.name,
    type = self.type,
  }
  for _, name in ipairs(self:get_option_names()) do
    if rawget(self, name) ~= nil then
      ret[name] = self[name]
    end
  end
  if ret.attrs then
    ret.attrs = clone(ret.attrs)
  end
  return ret
end

---@return {[string]:any}
function BaseField:json()
  local res = self:get_options()
  if type(res.default) == 'function' then
    res.default = nil
  end
  if type(res.choices) == 'function' then
    res.choices = nil
  end
  if not res.tag then
    if type(res.choices) == 'table' and #res.choices > 0 and not res.autocomplete then
      res.tag = "select"
    else
      --   res.tag = "input"
    end
  end
  if res.tag == "input" and res.lazy == nil then
    res.lazy = true
  end
  if res.preload == nil and res.choices_url then
    res.preload = false
  end
  return res
end

---@param extra_attrs? {[string]:any}
---@return {[string]:any}
function BaseField:widget_attrs(extra_attrs)
  return dict({ required = self.required, readonly = self.disabled }, extra_attrs)
end

---@param value DBValue
---@return DBValue
---@overload fun(self:self, value:DBValue):nil
---@overload fun(self:self, value:DBValue):nil,string,integer?
function BaseField:validate(value)
  if type(value) == 'function' then
    return value
  end
  local err
  local index
  for _, validator in ipairs(self.validators) do
    ---@cast validator fun(DBValue):DBValue,string?,integer?
    value, err, index = validator(value)
    if value ~= nil then
      if err == nil then
      elseif value == err then
        -- keep the value, skip the rest validations
        return value
      else
        return nil, err, index
      end
    elseif err ~= nil then
      return nil, err, index
    else
      -- not-required validator, skip the rest validations
      return nil
    end
  end
  return value
end

---@return any
function BaseField:get_default()
  if type(self.default) == "function" then
    return self.default()
  elseif type(self.default) == "table" then
    return clone(self.default)
  else
    return self.default
  end
end

---@param message string error message
---@param index? integer
---@return {type:"field_error", message:string,name:string,label:string,index?:integer}
function BaseField:make_error(message, index)
  return {
    type = 'field_error',
    message = message,
    index = index,
    name = self.name,
    label = self.label,
  }
end

---@param value DBValue
---@return DBValue
function BaseField:to_form_value(value)
  -- Fields like alioss* need this
  return value
end

---@param value DBValue
---@return DBValue
function BaseField:to_post_value(value)
  return value
end

local function get_max_choice_length(choices)
  local n = 0
  for _, c in ipairs(choices) do
    local value = c.value
    local n1 = utf8len(value)
    if n1 > n then
      n = n1
    end
  end
  return n
end


---@class StringField:BaseField
---@field type "string"
---@field db_type "varchar"
---@field compact? boolean remove all spaces
---@field trim? boolean remove head and tail spaces
---@field pattern? string regex expression string that passed to ngx.re.match
---@field length? integer
---@field minlength? integer
---@field maxlength? integer
---@field input_type? string
StringField = BaseField:class {
  compact = false,
  trim = true,
  option_names = {
    "compact",
    "trim",
    "pattern",
    "length",
    "minlength",
    "maxlength",
    "input_type",
  },
}
function StringField:init(options)
  if not options.choices and not options.length and not options.maxlength then
    error(string_format("field '%s' must define maxlength or choices or length", options.name))
  end
  BaseField.init(self, dict({
    type = "string",
    db_type = "varchar",
  }, options))
  --TODO:考虑default为函数时,数据库层面应该为空字符串.从migrate.lua的serialize_defaut特定
  --可以考虑default函数传入nil时认定为migrate的情形, 自行返回空字符串
  if self.default == nil and not self.primary_key and not self.unique then
    self.default = ""
  end
  if self.choices and isarray(self.choices) and #self.choices > 0 then
    local n = get_max_choice_length(self.choices)
    assert(n > 0, "invalid string choices(empty choices or zero length value):" .. self.name)
    local m = self.length or self.maxlength
    if not m or n > m then
      self.maxlength = n
    end
  end
end

---@param validators function[]
---@return function[]
function StringField:get_validators(validators)
  for _, e in ipairs { "pattern", "length", "minlength", "maxlength" } do
    if self[e] then
      table_insert(validators, 1, Validator[e](self[e], self:get_error_message(e)))
    end
  end
  if self.compact then
    table_insert(validators, 1, Validator.delete_spaces)
  elseif self.trim then
    table_insert(validators, 1, Validator.trim)
  end
  table_insert(validators, 1, Validator.string)
  return BaseField.get_validators(self, validators)
end

---@param extra_attrs? {[string]:any}
---@return {[string]:any}
function StringField:widget_attrs(extra_attrs)
  local attrs = {
    -- maxlength = self.maxlength,
    minlength = self.minlength
    -- pattern = self.pattern,
  }
  return dict(BaseField.widget_attrs(self), dict(attrs, extra_attrs))
end

---@param value DBValue
---@return string
function StringField:to_form_value(value)
  if not value then
    return ""
  elseif type(value) == 'string' then
    return value
  else
    return tostring(value)
  end
end

---@param value string
---@return string
function StringField:to_post_value(value)
  if self.compact then
    if not value then
      return ""
    else
      return (value:gsub('%s', ''))
    end
  else
    return value or ""
  end
end

---@class UUIDField:BaseField
---@field type "uuid"
---@field db_type "uuid"
UUIDField = BaseField:class {}

function UUIDField:init(options)
  BaseField.init(self, dict({
    type = "uuid",
    db_type = "uuid",
  }, options))
end

function UUIDField:json()
  local json = BaseField.json(self)
  if json.disabled == nil then
    json.disabled = true
  end
  return json
end

---@class TextField:BaseField
---@field type "text"
---@field db_type "text"
---@field pattern? string regex expression string that passed to ngx.re.match
---@field length? integer
---@field minlength? integer
---@field maxlength? integer
TextField = BaseField:class {
  option_names = { "pattern", "length", "minlength", "maxlength" },
}
function TextField:init(options)
  BaseField.init(self, dict({
    type = "text",
    db_type = "text",
  }, options))
  if self.default == nil then
    self.default = ""
  end
  if self.attrs and self.attrs.auto_size == nil then
    self.attrs.auto_size = false
  end
end

function TextField:get_validators(validators)
  for _, e in ipairs { "pattern", "length", "minlength", "maxlength" } do
    if self[e] then
      table_insert(validators, 1, Validator[e](self[e], self:get_error_message(e)))
    end
  end
  table_insert(validators, 1, Validator.string)
  return BaseField.get_validators(self, validators)
end

---@class SfzhField:StringField
---@field type "sfzh"
---@field db_type "varchar"
SfzhField = StringField:class {
  option_names = { unpack(StringField.option_names) },
}

function SfzhField:init(options)
  StringField.init(self, dict({
    type = "sfzh",
    db_type = "varchar",
    length = 18
  }, options))
end

---@param validators function[]
---@return function[]
function SfzhField:get_validators(validators)
  table_insert(validators, 1, Validator.sfzh)
  return StringField.get_validators(self, validators)
end

---@class EmailField:StringField
---@field type "email"
---@field db_type "varchar"
EmailField = StringField:class {
  option_names = { unpack(StringField.option_names) },
}

function EmailField:init(options)
  StringField.init(self, dict({
    type = "email",
    db_type = "varchar",
    maxlength = 255
  }, options))
end

---@param validators function[]
---@return function[]
function EmailField:get_validators(validators)
  table_insert(validators, 1, Validator.email)
  return StringField.get_validators(self, validators)
end

---@class PasswordField:StringField
---@field type "password"
---@field db_type "varchar"
PasswordField = StringField:class {
  option_names = { unpack(StringField.option_names) },
}
function PasswordField:init(options)
  StringField.init(self, dict({
    type = "password",
    db_type = "varchar",
    maxlength = 255
  }, options))
end

---@class YearMonthField:StringField
---@field type "year_month"
---@field db_type "varchar"
YearMonthField = StringField:class {
  maxlength = 7,
  option_names = { unpack(StringField.option_names) },
}

function YearMonthField:init(options)
  StringField.init(self, dict({
    type = "year_month",
    db_type = "varchar",
  }, options))
end

---@param validators function[]
---@return function[]
function YearMonthField:get_validators(validators)
  table_insert(validators, 1, Validator.year_month)
  return BaseField.get_validators(self, validators)
end

local function add_min_or_max_validators(self, validators)
  for _, name in ipairs({ "min", "max" }) do
    if self[name] then
      table_insert(validators, 1, Validator[name](self[name], self:get_error_message(name)))
    end
  end
end

---@class IntegerField:BaseField
---@field type "integer"
---@field db_type "integer"
---@field min? number
---@field max? number
---@field step? number
---@field serial? boolean
IntegerField = BaseField:class {
  option_names = { "min", "max", "step", "serial" },
}

function IntegerField:init(options)
  BaseField.init(self, dict({
    type = "integer",
    db_type = "integer",
  }, options))
end

---@param validators function[]
---@return function[]
function IntegerField:get_validators(validators)
  add_min_or_max_validators(self, validators)
  table_insert(validators, 1, Validator.integer)
  return BaseField.get_validators(self, validators)
end

function IntegerField:json()
  local json = BaseField.json(self)
  if json.primary_key and json.disabled == nil then
    json.disabled = true
  end
  return json
end

---@param value ""|nil|integer
---@return integer|userdata
function IntegerField:prepare_for_db(value)
  if value == "" or value == nil then
    return NULL
  else
    return value --[[@as integer]]
  end
end

---@class YearField:IntegerField
---@field type "year"
---@field db_type "integer"
YearField = IntegerField:class {
  option_names = { unpack(IntegerField.option_names) },
}
function YearField:init(options)
  IntegerField.init(self, dict({
    type = "year",
    db_type = "integer",
    min = 1000,
    max = 9999
  }, options))
end

---@class MonthField:IntegerField
---@field type "month"
---@field db_type "integer"
MonthField = IntegerField:class {
  option_names = { unpack(IntegerField.option_names) },
}
function MonthField:init(options)
  IntegerField.init(self, dict({
    type = "month",
    db_type = "integer",
    min = 1,
    max = 12
  }, options))
end

---@class FloatField:BaseField
---@field type "float"
---@field db_type "float"
FloatField = BaseField:class {
  option_names = { "min", "max", "step", "precision" },
}
function FloatField:init(options)
  BaseField.init(self, dict({
    type = "float",
    db_type = "float",
  }, options))
end

function FloatField:get_validators(validators)
  add_min_or_max_validators(self, validators)
  table_insert(validators, 1, Validator.number)
  return BaseField.get_validators(self, validators)
end

---@param value ""|nil|number
---@return number|userdata
function FloatField:prepare_for_db(value)
  if value == "" or value == nil then
    return NULL
  else
    return value --[[@as number]]
  end
end

---@class BooleanField:BaseField
---@field type "boolean"
---@field db_type "boolean"
---@field cn boolean whether use chinese boolean
BooleanField = BaseField:class {
  option_names = { 'cn' },
}
function BooleanField:init(options)
  BaseField.init(self, dict({
    type = "boolean",
    db_type = "boolean",
  }, options))
  if self.choices == nil then
    self.choices = clone(DEFAULT_BOOLEAN_CHOICES)
  end
end

function BooleanField:get_validators(validators)
  if self.cn then
    table_insert(validators, 1, Validator.boolean_cn)
  else
    table_insert(validators, 1, Validator.boolean)
  end
  return BaseField.get_validators(self, validators)
end

---@param value ""|nil|boolean
---@return boolean|userdata
function BooleanField:prepare_for_db(value)
  if value == "" or value == nil then
    return NULL
  else
    return value --[[@as boolean]]
  end
end

---@class DatetimeField:BaseField
---@field type "datetime"
---@field db_type "timestamp"
---@field auto_now_add boolean
---@field auto_now boolean
---@field precision integer
---@field timezone boolean
DatetimeField = BaseField:class {
  precision = 0,
  timezone = true,
  option_names = {
    'auto_now_add',
    'auto_now',
    'precision',
    'timezone',
  },
}
function DatetimeField:init(options)
  BaseField.init(self, dict({
    type = "datetime",
    db_type = "timestamp",
  }, options))
  if self.auto_now_add then
    self.default = ngx_localtime
  end
end

function DatetimeField:get_validators(validators)
  table_insert(validators, 1, Validator.datetime)
  return BaseField.get_validators(self, validators)
end

function DatetimeField:json()
  local ret = BaseField.json(self)
  if ret.disabled == nil and (ret.auto_now or ret.auto_now_add) then
    ret.disabled = true
  end
  return ret
end

---@param value ""|nil|string
---@return string|userdata
function DatetimeField:prepare_for_db(value)
  if self.auto_now then
    return ngx_localtime()
  elseif value == "" or value == nil then
    return NULL
  else
    return value
  end
end

---@class DateField:BaseField
---@field type "date"
---@field db_type "date"
DateField = BaseField:class {
  option_names = {},
}
function DateField:init(options)
  BaseField.init(self, dict({
    type = "date",
    db_type = "date",
  }, options))
end

function DateField:get_validators(validators)
  table_insert(validators, 1, Validator.date)
  return BaseField.get_validators(self, validators)
end

---@param value ""|nil|string
---@return string|userdata
function DateField:prepare_for_db(value)
  if value == "" or value == nil then
    return NULL
  else
    return value
  end
end

---@class TimeField:BaseField
---@field type "time"
---@field db_type "time"
---@field precision integer
---@field timezone boolean
TimeField = BaseField:class {
  precision = 0,
  timezone = true,
  option_names = { 'precision', 'timezone' },
}
function TimeField:init(options)
  BaseField.init(self, dict({
    type = "time",
    db_type = "time",
  }, options))
end

function TimeField:get_validators(validators)
  table_insert(validators, 1, Validator.time)
  return BaseField.get_validators(self, validators)
end

---@param value ""|nil|string
---@return string|userdata
function TimeField:prepare_for_db(value)
  if value == "" or value == nil then
    return NULL
  else
    return value
  end
end

---@class ForeignkeyField:BaseField
---@field type "foreignkey"
---@field private FK_TYPE_NOT_DEFIEND table
---@field convert function
---@field reference Xodel
---@field reference_column string
---@field reference_label_column string
---@field reference_url? string
---@field on_delete? "CASCADE"|"NO ACTION"|"cascade"|"no action" default CASCADE
---@field on_update? "CASCADE"|"NO ACTION"|"cascade"|"no action" default CASCADE
---@field table_name? string
---@field admin_url_name? string
---@field models_url_name? string
---@field keyword_query_name? string default keyword
---@field limit_query_name? string default limit
---@field json_dereference? boolean whether defererence in json
---@field related_name string
---@field related_query_name string
---@field is_multiple boolean OneToOneField is not multiple
ForeignkeyField = BaseField:class {
  FK_TYPE_NOT_DEFIEND = FK_TYPE_NOT_DEFIEND,
  on_delete = 'CASCADE',
  on_update = 'CASCADE',
  admin_url_name = 'admin',
  models_url_name = 'model',
  keyword_query_name = 'keyword',
  limit_query_name = 'limit',
  convert = tostring,
  option_names = {
    "json_dereference",
    "reference",
    "reference_column",
    "reference_label_column",
    "reference_url",
    "on_delete",
    "on_update",
    "table_name",
    "admin_url_name",
    "models_url_name",
    "keyword_query_name",
    "limit_query_name",
    "related_name",
    "related_query_name",
    "is_multiple",
  },
}
function ForeignkeyField:init(options)
  BaseField.init(self, dict({
    type = "foreignkey",
    db_type = FK_TYPE_NOT_DEFIEND,
  }, options))
  local fk_model = self.reference
  if fk_model == "self" then
    -- used with Xodel._make_model_class
    return self
  end
  ---@cast fk_model Xodel
  self:setup_with_fk_model(fk_model)
end

---@param fk_model Xodel
function ForeignkeyField:setup_with_fk_model(fk_model)
  -- setup: reference_column, reference_label_column, db_type
  assert(type(fk_model) == "table" and fk_model.__IS_MODEL_CLASS__,
    string_format("a foreignkey must define a reference model. not %s(type: %s)", fk_model, type(fk_model)))
  local rc = self.reference_column or fk_model.primary_key or fk_model.DEFAULT_PRIMARY_KEY or "id"
  local fk = fk_model.fields[rc]
  assert(fk, string_format("invalid foreignkey name %s for foreign model %s",
    rc,
    fk_model.table_name or "[TABLE NAME NOT DEFINED YET]"))
  self.reference_column = rc
  local rlc = self.reference_label_column or fk_model.referenced_label_column or rc
  local _fk, _fk_of_fk = rlc:match("(%w+)__(%w+)")
  local check_key = _fk or rlc
  assert(fk_model.fields[check_key], string_format("invalid foreignkey label name %s for foreign model %s",
    check_key,
    fk_model.table_name or "[TABLE NAME NOT DEFINED YET]"))
  self.reference_label_column = rlc
  self.convert = assert(VALID_FOREIGN_KEY_TYPES[fk.type],
    string_format("invalid foreignkey (name:%s, type:%s)", fk.name, fk.type))
  assert(fk.primary_key or fk.unique, "foreignkey must be a primary key or unique key")
  if self.db_type == FK_TYPE_NOT_DEFIEND then
    self.db_type = fk.db_type or fk.type
  end
  if self.preload == nil then
    self.preload = fk_model.preload
  end
end

function ForeignkeyField:get_validators(validators)
  local fk_name = self.reference_column
  local function foreignkey_validator(v)
    local err
    if type(v) == "table" then
      v = v[fk_name]
    end
    v, err = self.convert(v)
    if err then
      local label_type = self.reference.fields[self.reference_label_column].type
      local value_type = self.reference.fields[self.reference_column].type
      if label_type ~= value_type then
        return nil, "输入错误" --前端autocomplete可能传来label值
      end
      return nil, tostring(err)
    end
    return v
  end

  table_insert(validators, 1, foreignkey_validator)
  return BaseField.get_validators(self, validators)
end

---@param value DBValue
---@return table
function ForeignkeyField:load(value)
  local fk_name = self.reference_column
  local fk_model = self.reference --[[@as Xodel]]
  local function __index(t, key)
    if fk_model[key] then
      -- perform sql only when key is in fields:
      return fk_model[key]
    elseif fk_model.fields[key] then
      local pk = rawget(t, fk_name)
      if not pk then
        return nil
      end
      local res = fk_model:get { [fk_name] = pk }
      if not res then
        return nil
      end
      for k, v in pairs(res) do
        rawset(t, k, v)
      end
      -- become an instance of fk_model
      fk_model:create_record(t)
      return t[key]
    else
      return nil
    end
  end

  return setmetatable({ [fk_name] = value }, { __index = __index })
end

function ForeignkeyField:json()
  local ret
  if self.json_dereference then
    ret = {
      name = self.name,
      label = self.label,
      type = self.reference.fields[self.reference_column].type,
      required = self.required,
    }
  else
    ret = BaseField.json(self)
    ret.reference = self.reference.table_name
    if self.autocomplete == nil then
      ret.autocomplete = true
    end
  end
  if ret.choices_url == nil then
    ret.choices_url = string_format([[/%s/choices?value=%s&label=%s]],
      self.reference.table_name,
      self.reference_column,
      self.reference_label_column)
  end
  if ret.reference_url == nil then
    ret.reference_url = string_format([[/%s/json]], self.reference.table_name)
  end
  return ret
end

---@param value any
---@return any
function ForeignkeyField:prepare_for_db(value)
  if value == "" or value == nil then
    return NULL
  else
    return value
  end
end

function ForeignkeyField:to_form_value(value)
  if type(value) == "table" then
    return value[self.reference_column]
  else
    return value
  end
end

---@class JsonField:BaseField
---@field type "json"
---@field db_type "jsonb"
JsonField = BaseField:class {
  option_names = {},
}
function JsonField:init(options)
  BaseField.init(self, dict({
    type = "json",
    db_type = "jsonb",
  }, options))
end

function JsonField:json()
  local json = BaseField.json(self)
  json.tag = "textarea"
  return json
end

function JsonField:prepare_for_db(value)
  if value == "" or value == nil then
    return NULL
  else
    return Validator.encode(value)
  end
end

local function skip_validate_when_string(v)
  if type(v) == "string" then
    return v, v
  else
    return v
  end
end

local function check_array_type(v)
  if not isarray(v) then
    return nil, "value of array field must be a array"
  else
    return v
  end
end

local function non_empty_array_required(message)
  message = message or "此项必填"
  local function array_required_validator(v)
    if #v == 0 then
      return nil, message
    else
      return v
    end
  end

  return array_required_validator
end

---@class BaseArrayField:JsonField
---@field field? AnyField
local BaseArrayField = JsonField:class {}

function BaseArrayField:init(options)
  JsonField.init(self, options)
  if type(self.default) == 'string' then
    self.default = string_choices_to_array(self.default)
  end
end

function BaseArrayField:get_validators(validators)
  if self.required then
    table_insert(validators, 1, non_empty_array_required(self:get_error_message('required')))
  end
  table_insert(validators, 1, check_array_type)
  table_insert(validators, 1, skip_validate_when_string)
  table_insert(validators, Validator.encode_as_array)
  return JsonField.get_validators(self, validators)
end

function BaseArrayField:to_form_value(value)
  if type(value) == 'table' and isarray(value) then
    return clone(value)
  else
    return {}
  end
end

---@class ArrayField:BaseArrayField
---@field type "array"
---@field field? AnyField
ArrayField = BaseArrayField:class {
  min = 1,
  option_names = { 'field', 'min' },
}
function ArrayField:init(options)
  BaseArrayField.init(self, dict({
    type = "array",
  }, options))
  if type(self.field) == 'table' then
    self.field = normalize_field_shortcuts(self.field)
    if not self.field.name then
      --为了解决validateFunction内array field覆盖parent值的问题
      self.field.name = self.name
    end
    local fields = get_fields()
    local array_field_cls = fields[self.field.type or 'string']
    if not array_field_cls then
      error("invalid array field type: " .. self.field.type)
    end
    self.field = array_field_cls:create_field(self.field)
  end
end

function ArrayField:get_options()
  local options = BaseField.get_options(self)
  if self.field then
    local array_field_options = self.field:get_options()
    options.field = array_field_options
  end
  return options
end

function ArrayField:get_validators(validators)
  if self.field then
    local function array_validator(value)
      local res = {}
      local field = self.field
      ---@cast field -nil
      for i, e in ipairs(value) do
        local val, err = field:validate(e)
        if err ~= nil then
          return nil, err, i
        end
        if field.default and (val == nil or val == "") then
          val, err = field:get_default()
          if val == nil then
            return nil, err, i
          end
        end
        res[i] = val
      end
      return res
    end
    table_insert(validators, 1, array_validator)
  end
  return BaseArrayField.get_validators(self, validators)
end

local function make_empty_array()
  return Array()
end

---@class TableField:BaseArrayField
---@field type "table"
---@field model Xodel
---@field names? string[]
---@field form_names? string[]
---@field cascade_column? string
---@field columns? string[]
---@field max_rows? integer
---@field uploadable? boolean
---@field ModelClass? Xodel
TableField = BaseArrayField:class {
  max_rows = TABLE_MAX_ROWS,
  option_names = { 'model', 'max_rows', 'uploadable', 'names', 'columns', 'form_names', 'cascade_column' },
}
function TableField:init(options)
  BaseArrayField.init(self, dict({
    type = "table",
  }, options))
  if type(self.model) ~= 'table' then
    error("please define model for a table field: " .. self.name)
  end
  if not self.model.__IS_MODEL_CLASS__ then
    self.model = self.ModelClass:create_model {
      extends = self.model.extends,
      mixins = self.model.mixins,
      abstract = self.model.abstract,
      admin = self.model.admin,
      table_name = self.model.table_name,
      class_name = self.model.class_name,
      label = self.model.label,
      fields = self.model.fields,
      field_names = self.model.field_names,
      auto_primary_key = self.model.auto_primary_key,
      primary_key = self.model.primary_key,
      unique_together = self.model.unique_together
    }
  end
  if not self.default or self.default == "" then
    self.default = make_empty_array
  end
  if not self.model.abstract and not self.model.table_name then
    self.model:materialize_with_table_name { table_name = self.name, label = self.label }
  end
end

function TableField:get_validators(validators)
  local function validate_by_each_field(rows)
    local err
    local res = {}
    local validate_names = self.names or self.form_names
    for i, row in ipairs(rows) do
      assert(type(row) == "table", "elements of table field must be table")
      row, err = self.model:validate_create(row, validate_names)
      if row == nil then
        return nil, err, i
      end
      res[i] = row
    end
    return res
  end

  table_insert(validators, 1, validate_by_each_field)
  return BaseArrayField.get_validators(self, validators)
end

function TableField:json()
  local ret = BaseArrayField.json(self)
  local model = {
    field_names = Array {},
    fields = {},
    table_name = self.model.table_name,
    label = self.model.label
  }
  for _, name in ipairs(self.model.field_names) do
    local field = self.model.fields[name]
    model.field_names:push(name)
    model.fields[name] = field:json()
  end
  ret.model = model
  return ret
end

function TableField:load(rows)
  if type(rows) ~= 'table' then
    error('value of table field must be table, not ' .. type(rows))
  end
  for i = 1, #rows do
    rows[i] = self.model:load(rows[i])
  end
  return Array(rows)
end

local ALIOSS_URL = getenv("ALIOSS_URL") or ""
local ALIOSS_SIZE = getenv("ALIOSS_SIZE") or "1M"
local ALIOSS_LIFETIME = tonumber(getenv("ALIOSS_LIFETIME") or 30) --[[@as integer]]

---@class AliossField:StringField
---@field type "alioss"
---@field db_type "varchar"
---@field size number|string
---@field size_arg string
---@field policy table
---@field payload table
---@field lifetime integer
---@field key_secret string
---@field key_id string
---@field times? integer 似乎无用
---@field width? number|string 似乎无用
---@field hash? boolean 似乎无用
---@field image? boolean
---@field prefix? string
---@field upload_url string
---@field payload_url? string
---@field input_type? string
---@field limit? integer
---@field media_type? string
AliossField = StringField:class {
  option_names = {
    "size",
    "size_arg",
    "policy",
    "payload",
    "lifetime",
    "key_secret",
    "key_id",
    "times",
    "width",
    "hash",
    "image",
    "prefix",
    "upload_url",
    "payload_url",
    "input_type",
    "limit",
    "media_type",
    unpack(StringField.option_names)
  },
}
function AliossField:init(options)
  StringField.init(self, dict({
    type = "alioss",
    db_type = "varchar",
    maxlength = 255,
  }, options))
  self:setup(options)
end

---@param self AliossField|AliossListField
---@param options AliossPayloadArgs
function AliossField.setup(self, options)
  local size = options.size or ALIOSS_SIZE
  self.key_secret = options.key_secret
  self.key_id = options.key_id
  self.size_arg = size
  self.size = byte_size_parser(size)
  self.lifetime = options.lifetime or ALIOSS_LIFETIME
  self.upload_url = options.upload_url or ALIOSS_URL
end

function AliossField:get_options()
  local ret = StringField.get_options(self)
  ret.size = ret.size_arg
  ret.size_arg = nil
  return ret
end

---@param options AliossPayloadArgs
---@return AliossPayload
function AliossField:get_payload(options)
  return get_payload(dict(self, options))
end

function AliossField:get_validators(validators)
  table_insert(validators, 1, Validator.url)
  return StringField.get_validators(self, validators)
end

---@param self AliossField|AliossListField
function AliossField:json()
  local ret = StringField.json(self)
  if ret.input_type == nil then
    ret.input_type = "file"
  end
  ret.key_secret = nil
  ret.key_id = nil
  return ret
end

---@param value string
---@return string
function AliossField:load(value)
  if value and value:sub(1, 1) == "/" then
    local scheme = getenv('VITE_HTTPS') == 'on' and 'https' or 'http'
    return scheme .. ':' .. value
  else
    return value
  end
end

---@class AliossImageField:AliossField
---@field type "alioss_image"
---@field db_type "varchar"
---@field media_type "image"
---@field image true
AliossImageField = AliossField:class {}
function AliossImageField:init(options)
  AliossField.init(self, dict({
    type = "alioss_image",
    db_type = "varchar",
    media_type = 'image',
    image = true,
  }, options))
end

---@class AliossListField:BaseArrayField
---@field type "alioss_list"
---@field db_type "jsonb"
AliossListField = BaseArrayField:class {
  option_names = { unpack(AliossField.option_names) },
}
function AliossListField:init(options)
  BaseArrayField.init(self, dict({
    type = "alioss_list",
    db_type = 'jsonb',
  }, options))
  AliossField.setup(self, options)
end

AliossListField.get_payload = AliossField.get_payload
AliossListField.get_options = AliossField.get_options

function AliossListField:json()
  return dict(AliossField.json(self), BaseArrayField.json(self))
end

---@class AliossImageListField:AliossListField
---@field type "alioss_image_list"
---@field db_type "jsonb"
AliossImageListField = AliossListField:class {}
function AliossImageListField:init(options)
  AliossListField.init(self, dict({
    type = "alioss_image_list",
    -- media_type = 'image',
    -- image = true,
  }, options))
end

local exports = get_fields()
exports.basefield = BaseField

return exports
