local cjson = require "cjson"
local Field = require "resty.field"
local empty_array_mt = require "cjson".empty_array_mt
local rawget = rawget
local setmetatable = setmetatable
local ipairs = ipairs
local tostring = tostring
local type = type
local pairs = pairs
local string_format = string.format
local table_concat = table.concat
local ngx_log = ngx.log
local ngx_ERR = ngx.ERR
local ngx_localtime = ngx.localtime
local match = ngx.re.match

local version = '1.2'

local function get_foreign_object(attrs, prefix)
    -- when in : attrs = {id=1, buyer__name='tom', buyer__id=2}, prefix = 'buyer__'
    -- when out: attrs = {id=1}, fk_instance = {name='tom', id=2}
    local fk_instance = {}
    local n = #prefix
    for k, v in pairs(attrs) do
        if k:sub(1, n) == prefix then
            fk_instance[k:sub(n+1)] = v
            attrs[k] = nil 
        end
    end
    return fk_instance
end
local function compact(sqlself)
    -- currently this only used in lua-resty-mysql
    sqlself._compact = true
    return sqlself
end
    

local Model = {}
Model.__index = Model
function Model.new(cls, self)
    return setmetatable(self, cls)
end
function Model.bind(cls, t)
    local query = t.query or error('you must provide a query function')
    local sql = t.sql or error('you must provide a sql class')
    -- step 1: define `exec` and `compact` to sql class
    local function exec(sqlself, raw)
        local records, err = query(sqlself:statement(), sqlself._compact)
        if not records then
            return nil, err
        end
        if type(records) == 'table' then
            setmetatable(records, empty_array_mt)
        end
        if raw then
            return records
        end
        if sqlself._is_select and not (
                sqlself._group or sqlself._group_string 
                or sqlself._having or sqlself._having_string) then
            if sqlself._select_join then
                for i, attrs in ipairs(records) do
                    for i, field in ipairs(sqlself.model.fields) do
                        local name = field.name
                        local value = attrs[name]
                        if value ~= nil then
                            local fk_model = sqlself._select_join[name]
                            if not fk_model then
                                attrs[name], err = field.db_to_lua(value, attrs)
                            else
                                -- `_select_join` means reading all attributes of a foreignkey, 
                                -- so the on-demand reading mode of `foreignkey_db_to_lua_validator` 
                                -- is not proper here
                                attrs[name], err = fk_model.db_to_lua(get_foreign_object(attrs, name..'__'))
                            end
                            if err then
                                return nil, err
                            end
                        end
                    end
                    records[i] = setmetatable(attrs, sqlself.model)
                end
            else
                for i, attrs in ipairs(records) do
                    records[i], err = sqlself.model.db_to_lua(attrs)
                    if err then
                        return nil, err
                    end
                end
            end    
        end
        return records
    end
    sql.compact = compact
    sql.exec = exec
    
    -- step 2: define model class methods who need `query` and `sql` as closures 
    function cls.get_sql()
        -- because model is a property of sql,
        -- here decouple sql from being a property of model
        return sql
    end
    function cls.all()
        local res, err = query('SELECT * FROM '..sql._quoted_table_name)
        if not res then
            return nil, err
        end
        for i=1, #res do
            res[i] = cls.db_to_lua(res[i])
        end
        return res
    end
    -- methods proxy to sql builder, use them like: cls.where():where():exec(),
    -- cls.where{}:select{}:exec() or cls.select{}:where{}:exec() 
    function cls.select(params)
        return sql:new{}:select(params)
    end
    function cls.where(params)
        return sql:new{}:where(params)
    end
    function cls.update(params)
        return sql:new{}:update(params)
    end
    function cls.create(params)
        return sql:new{}:create(params)
    end
    function cls.compact(params)
        return sql:new{}:compact(params)
    end
    function cls.group(params)
        return sql:new{}:group(params)
    end
    function cls.order(params)
        return sql:new{}:order(params)
    end
    function cls.having(params)
        return sql:new{}:having(params)
    end
    function cls.limit(params)
        return sql:new{}:limit(params)
    end
    function cls.offset(params)
        return sql:new{}:offset(params)
    end
    function cls.join(params)
        return sql:new{}:join(params)
    end
    -- these methods require no closure, but we still define them here to 
    -- uniforming calling class methods 
    function cls.get(params)
        local res, err = cls.where(params):exec(true)
        if not res then
            return nil, err
        elseif #res ~= 1 then
            return nil, 'expect 1 record, but get '..#res
        end
        return cls.db_to_lua(res[1])
    end    
    function cls.db_to_lua(attrs)
        local err
        for i, field in ipairs(cls.fields) do
            local name = field.name
            local value = attrs[name]
            if value ~= nil then
                attrs[name], err = field.db_to_lua(value, attrs)
                if err then
                    return nil, err
                end
            end
        end
        return setmetatable(attrs, cls)
    end
    -- instance methods, call them like: ins:delete() or ins:save()
    function cls.delete(self)
        if self.id then
            return query('DELETE FROM '..sql._quoted_table_name..' WHERE id = '..self.id)       
        else
            return nil, 'id must be provided when deleting a record'
        end
    end
    function cls.save(self)
        -- ** is `affected_rows` and `insert_id` coupled with pgmoon?
        if self.id then
            local attrs, errors = self:validate_for_update() 
            if errors then
                return nil ,errors
            end
            local res, err = sql:new{}:update(attrs):where('id = '..self.id):exec(true) 
            if res then
                if res.affected_rows == 1 then
                    return res
                elseif res.affected_rows == 0 then
                    return nil, {__all='this record doesnot exist'}
                else
                    return nil, {__all='multiple records are updated'}
                end
            else
                return nil, {__all=err}
            end
        else
            local attrs, errors = self:validate_for_create()   
            if errors then
                return nil ,errors
            end
            local res, err = sql:new{}:create(attrs):exec(true)
            if res then
                self.id = res.insert_id
                return res
            else
                return nil, {__all=err}
            end
        end
    end
end
function Model._check_id_field(cls)
    local id_field
    for i, field in ipairs(cls.fields) do
        if name == 'id' then
            id_field = field
        end
    end
    if not id_field then
        table.insert(cls.fields, 1, Field.integer{name="id", primary_key=true})
    end
end
function Model.class(cls, subclass)
    assert(
        type(subclass) == 'table' and 
        subclass.table_name and 
        subclass.fields,
        "you must provide a model class with table_name and fields"
    )
    setmetatable(subclass, cls)
    subclass.__index = subclass
    subclass:_check_id_field() 
    subclass.fields_dict = {}
    subclass._referenced_models = {}
    subclass.foreign_keys = {}
    for i, field in ipairs(subclass.fields) do
        local name = field.name
        assert(not subclass[name], string_format('`%s` conflicts with Model attributes', name))
        local fk_model = field.reference
        if fk_model then
            subclass.foreign_keys[name] = field
            fk_model._referenced_models[subclass.table_name] = subclass
        end
        subclass.fields_dict[name] = field
    end
    return subclass
end

-- {
--   "affected_rows": 1,
--   "insert_id": 204195,
--   "server_status": 2,
--   "warning_count": 4,
-- }
local function make_error(errors, name, err, row, col)
    if row and col then 
        errors[name] = {row=row-1, col=col, message=err}
    else
        errors[name] = err
    end
end
function Model.validate_for_create(self)
    local attrs = {}
    local errors = {}
    local res, value, err, row, col
    for i, field in ipairs(self.fields) do
        local name = field.name
        value, err, row, col = field.client_to_lua(self[name], self)
        if err ~= nil then
            make_error(errors, name, err, row, col)
        else 
            if value == nil and field.default then
                value = field:get_default()
            end
            -- ** pass non-nil to lua_to_db
            if value ~= nil then
                value, err, row, col = field.lua_to_db(value, self)
                if err ~= nil then
                    make_error(errors, name, err, row, col)
                else             
                    attrs[name] = value
                end
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
function Model.validate_for_update(self)
    local attrs = {}
    local errors = {}
    local res, value, err, row, col
    for i, field in ipairs(self.fields) do
        local name = field.name
        if name == 'id' then
            -- ** do nothting? for update logic, this seems OK.
        elseif field.auto_now then
            value = ngx_localtime()
            attrs[name] = value
        elseif rawget(self, name) ~= nil  then 
            -- Why `rawget` here? if use `self[name]`, this case:
            -- u = User:get{id=1}; p = u.profile; p:save(), will raise error
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
                value = field:get_empty_value_to_update()
                attrs[name] = value
            end 
        else
            -- no value for this field, ignored
        end
    end
    if next(errors) ~= nil then
        return nil, errors
    end
    return attrs
end
    
return Model