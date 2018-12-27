local Field = require "resty.field"
local utils = require "resty.utils"
local empty_array_mt = require "cjson".empty_array_mt
local rawget = rawget
local setmetatable = setmetatable
local ipairs = ipairs
local tostring = tostring
local type = type
local pairs = pairs
local string_format = string.format
local table_concat = table.concat
local table_insert = table.insert
local ngx_log = ngx.log
local ngx_ERR = ngx.ERR
local ngx_localtime = ngx.localtime
local match = ngx.re.match
local math_floor = math.floor

local version = '1.3'

local function is_valid_id(id)
    local id = tonumber(id)
    if not id or id ~= math_floor(id) then
        return
    end
    return id
end
local function insert_unique_name(t, name)
    if not utils.list_has(t, name) then
        table_insert(t, name)
    end
end
local function __call_record_update(record, data)
    for k, v in pairs(data) do
        record[k] = v
    end
    return record
end
local function __call_make_concrete_model(cls, ...)
    local model = setmetatable({}, cls)
    local fields = {}
    local field_names = {}
    local _array_field_names = {}
    for i, mixin_model in ipairs{...} do  
        assert(type(mixin_model)=='table', 'mixin model must be a table')
        if not mixin_model.fields then
            mixin_model = {fields = mixin_model}
        end
        assert(type(mixin_model.fields)=='table', 'mixin model must define fields')
        for k, v in pairs(mixin_model) do
            if tonumber(k) ~= k then
                model[k] = v
            end
        end
        for k, field in pairs(mixin_model.fields) do
            if tonumber(k) == k then
                local name = field.name
                assert(name, 'you must define name for a field if you use array form')
                insert_unique_name(_array_field_names, name)
                fields[name] = field
            else
                if field.name then
                    assert(field.name==k, 'key must equals field name if you use map form')
                else
                    field.name = k
                    field.label = field.label or k
                end
                fields[k] = field
            end
            insert_unique_name(field_names, field.name) 
        end
    end
    model.fields = fields
    -- field_names
    if not model.field_names then
        if #_array_field_names == #field_names then
            model.field_names = _array_field_names
        else
            table.sort(field_names)
            model.field_names = field_names
        end
    end
    if not model.table_name then
        ngx_log(ngx.WARN, "define a model without table_name, make sure define it sometime")
    end
    -- ensure id 
    if not model.fields.id then
        model.fields.id = Field.integer{name="id", primary_key=true}
        table.insert(model.field_names, 1, 'id')
    end
    -- foreign_keys
    model.foreign_keys = {}
    for name, field in pairs(model.fields) do
        assert(not model[name], string_format('field name `%s` conflicts with model class attributes', name))
        local fk_model = field.reference
        if fk_model then
            model.foreign_keys[name] = field
        end
    end
    model.__index = model
    model.__call = __call_record_update
    return model
end
local function __call_model_new(model, data) 
    return model:new(data) 
end
local Model = setmetatable({}, {__call = __call_make_concrete_model})
Model.NULL = {}
Model.__index = Model
Model.__call = __call_model_new
function Model.new(cls, self)
    return setmetatable(self or {}, cls)
end
function Model.all(cls)
    local res, err = cls.query('SELECT * FROM '..cls.sql._quoted_table_name)
    if not res then
        return nil, err
    end
    for i=1, #res do
        res[i], err = cls:db_to_lua(res[i])
        if err then
            return nil, err
        end
    end
    return setmetatable(res, empty_array_mt)
end
function Model.get(cls, params, select_names)
    local res, err = cls.sql:new{}:select(select_names):where(params):limit(2):exec(true)
    if not res then
        return nil, err
    elseif #res ~= 1 then
        return nil, 'not one record returned', #res
    else
        return cls:db_to_lua(res[1])
    end
end    
function Model.get_or_create(cls, params, select_names)
    -- local ins, is_create_or_err = model:get_or_create
    local res, err = cls.sql:new{}:select(select_names):where(params):limit(2):exec(true)
    if res == nil then
        return nil, err
    elseif #res == 1 then
        local ins, err = cls:db_to_lua(res[1])
        if ins == nil then
            return nil, err
        else
            return ins, 1
        end
    elseif #res == 0 then
        local ins, err = cls:new(params):save()
        if ins == nil then
            return nil, err
        else
            return ins, 0
        end
    else
        return nil, 'multiple records returned'
    end
end
function Model.db_to_lua(cls, attrs)
    local err
    for i, name in ipairs(cls.field_names) do
        local field = cls.fields[name]
        local value = attrs[name]
        if value ~= nil then
            -- because value may be limited by select
            -- we should only check non-nil value here
            attrs[name], err = field.db_to_lua(value, attrs)
            if err then
                return nil, string_format('read "%s" from db failed: %s', name, err)
            end
        end
    end
    return setmetatable(attrs, cls)
end
function Model.select(cls, params)
    return cls.sql:new{}:select(params)
end
function Model.where(cls, params)
    return cls.sql:new{}:where(params)
end
function Model.update(cls, params)
    return cls.sql:new{}:update(params)
end
function Model.create(cls, params)
    return cls.sql:new{}:create(params)
end
function Model.compact(cls, params)
    return cls.sql:new{}:compact(params)
end
function Model.group(cls, params)
    return cls.sql:new{}:group(params)
end
function Model.order(cls, params)
    return cls.sql:new{}:order(params)
end
function Model.having(cls, params)
    return cls.sql:new{}:having(params)
end
function Model.limit(cls, params)
    return cls.sql:new{}:limit(params)
end
function Model.offset(cls, params)
    return cls.sql:new{}:offset(params)
end
function Model.join(cls, params)
    return cls.sql:new{}:join(params)
end
function Model.returning(cls, params)
    return cls.sql:new{}:returning(params)
end
-- {
--   "affected_rows": 1,
--   "insert_id": 204195,
--   "server_status": 2,
--   "warning_count": 4,
-- }
local function make_error(errors, name, err, row, col)
    if row and col then 
        errors[string_format('%s__%s__%s', name, row-1, col)] = err
    else
        errors[name] = err
    end
end
-- instance methods, call them like: ins:delete() or ins:save()
function Model.delete(self)
    local id = is_valid_id(self.id)
    if not id then
        return nil, 'id must be provided when deleting a record'
    end
    return self.query('DELETE FROM '..self.sql._quoted_table_name..' WHERE id = '..id)
end
function Model.save(self, names)
    if self.id then
        local attrs, errors = self:validate_for_update(names) 
        if errors then
            return nil ,errors
        end
        attrs.id = nil 
        local res, err = self.sql:new{}:update(attrs):where('id = '..self.id):exec(true) 
        if res then
            if res.affected_rows == 1 then
                return self
            elseif res.affected_rows == 0 then
                return nil, {__all='update failed: record does not exist'}
            else
                return nil, {__all='multiple records are updated'}
            end
        else
            return nil, {__all=err}
        end
    else
        local attrs, errors = self:validate_for_create(names)   
        if errors then
            return nil ,errors
        end
        local res, err = self.sql:new{}:returning('id'):create(attrs):exec(true)
-- {
--   1            : {
--     id: 23,
--   },
--   affected_rows: 1,
-- }
        if res then
            self.id = res[1].id
            return self
        else
            return nil, {__all=err}
        end
    end
end
function Model.validate_for_create(self, names)
    local attrs = {}
    local errors = {}
    local res, value, err, row, col
    for i, name in ipairs(names or self.field_names) do
        local field = self.fields[name]
        value, err, row, col = field.client_to_lua(self[name], self)
        if err ~= nil then
            make_error(errors, name, err, row, col)
        else 
            if value == nil and field.default then
                value = field:get_default()
            end
            value, err, row, col = field.lua_to_db(value, self)
            if err ~= nil then
                make_error(errors, name, err, row, col)
            else             
                attrs[name] = value
            end
        end
    end
    if next(errors) ~= nil then
        return nil, errors
    end
    return attrs
end
-- {
--   "affected_rows": 1,
--   "insert_id": 0,
--   "message" : "(Rows matched: 1  Changed: 1  Warnings: 0",
--   "server_status": 2,
--   "warning_count": 0,
-- }
function Model.validate_for_update(self, names)
    local attrs = {}
    local errors = {}
    local res, value, err, row, col
    for i, name in ipairs(names or self.field_names) do
        local field = self.fields[name]
        if rawget(self, name) ~= nil  then 
            -- Why `rawget` here? if use `self[name]`, this case:
            -- u = User.get{id=1}; p = u.profile; p:save(), 
            -- and maxium recursion error happens
            value, err, row, col = field.client_to_lua(self[name], self)
            if err ~= nil then
                make_error(errors, name, err, row, col)
            elseif value ~= nil then 
                value, err, row, col = field.lua_to_db(value, self)
                if err ~= nil then
                    make_error(errors, name, err, row, col)
                else             
                    attrs[name] = value
                end
            else 
                -- value is nil again after `client_to_lua`,
                -- its a non-required field whose value is empty string.
                value = field:get_empty_value_to_update(self)
                attrs[name] = value
            end 
        elseif field.auto_now then
            attrs[name] = ngx_localtime()
        end
    end
    if next(errors) ~= nil then
        return nil, errors
    end
    return attrs
end
    
return Model
