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

-- local NULL = setmetatable({},{__tostring=function(t) return 'NULL'end})
local version = '1.1'

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
local function compact(self)
    self._compact = true
    return self
end
local function exec(self, raw)
    local records, err = self.query(self:statement(), self._compact)
    if not records then
        return nil, err
    end
    if type(records) == 'table' then
        setmetatable(records, empty_array_mt)
    end
    if raw then
        return records
    end
    if self._is_select and not (self._group or self._group_string or self._having or self._having_string) then
        if self._select_join then
            for i, attrs in ipairs(records) do
                for i, field in ipairs(self.model.fields) do
                    local name = field.name
                    local value = attrs[name]
                    if value ~= nil then
                        local fk_model = self._select_join[name]
                        if not fk_model then
                            attrs[name], err = field.db_to_lua(value, attrs)
                        else
            -- 通过sql:join指定读取foreignkey的全部属性,因此field.db_to_lua使用的
            -- foreignkey_db_to_lua_validator按需读取属性的模式在此处不再适用
                            attrs[name], err = fk_model:db_to_lua(get_foreign_object(attrs, name..'__'))
                        end
                        if err then
                            return nil, err
                        end
                    end
                end
                records[i] = setmetatable(attrs, self.model)
            end
        else
            for i, attrs in ipairs(records) do
                records[i], err = self.model:db_to_lua(attrs)
                if err then
                    return nil, err
                end
            end
        end    
    end
    return records
end


local Model = {}
Model.__index = Model
function Model.new(cls, self)
    return setmetatable(self, cls)
end
function Model.bind_sql(cls, sql)
    sql.compact = compact
    sql.exec = exec
    cls.sql = sql
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
    subclass.__index = subclass
    setmetatable(subclass, cls)
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
function Model.db_to_lua(cls, attrs)
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
-- methods proxy to sql builder, `delete` is excluded
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
-- shortcuts
function Model.get(cls, params)
    local res, err = cls:where(params):exec(true)
    if not res then
        return nil, err
    elseif #res ~= 1 then
        return nil, 'should return 1 record, but get '..#res
    end
    return cls:db_to_lua(res[1])
end
function Model.all(cls)
    local res, err = cls.sql.query('SELECT * FROM '..cls._quoted_table_name)
    if not res then
        return nil, err
    end
    for i=1, #res do
        res[i] = cls:db_to_lua(res[i])
    end
    return res
end
function Model.delete(self)
    if self.id then
        return self.sql.query('DELETE FROM '..self._quoted_table_name..' WHERE id = '..self.id)       
    else
        return nil, 'id must be provided when deleting a record'
    end
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
            -- ** 只传入非nil的值给lua_to_db, 待观察实际情况
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
            -- 由于foreignkey_db_to_lua_validator的设计逻辑
            -- 假设profile是User的外键, info是Profile的外键, u = User:ger{id=1}, p = u.profile, p:save(), 
            -- 调用save时,将调用validate_for_update方法, 继而需要判断self的外键info的值是否为空.
            -- 如果直接self[name], 由于info不在self中, 将会触发__index方法, 继而发起数据库查询,更新self
            -- 继而将用一个表{id=...}表来代表self中的info值, 该值将无法通过foreignkey的client_to_lua检测(因为它要求外键是一个整数)
            -- foreignkey的设计也要求定义validator(value, model)的时候, 如果需要访问model的值,使用rawget(model,key)的形式
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
            else -- value经client_to_lua处理后又变回了nil, 说明是非必填的空字符
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
function Model.save(self)
    if self.id then
        local attrs, errors = self:validate_for_update() 
        if errors then
            return nil ,errors
        end
        local res, err = self.sql:new{}:update(attrs):where('id = '..self.id):exec(true) 
        if res then
            if res.affected_rows == 1 then
                return res
            elseif res.affected_rows == 0 then
                return nil, {__all='更新记录不存在'}
            else
                return nil, {__all='多条记录被更新'}
            end
        else
            return nil, {__all=err}
        end
    else
        local attrs, errors = validate_for_create(self)   
        if errors then
            return nil ,errors
        end
        local res, err = self.sql:new{}:create(attrs):exec(true)
        if res then
            self.id = res.insert_id
            return res
        else
            return nil, {__all=err}
        end
    end
end


return Model