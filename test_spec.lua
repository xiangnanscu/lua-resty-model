local utils = require("resty.utils")
local sql = require "resty.sql"
local field = require "resty.fields"
local array = require "resty.array"
local migrate = require "resty.migrate"
local Model = require("./lib/resty/model")
local format = string.format
local Q = Model.Q

-- https://github.com/lunarmodules/busted/tree/master/busted/outputHandlers
local function md(lang, s)
  print(format([[```%s
%s
```
]], lang, s))
end
local db_config = {
  DATABASE = 'test',
  USER = 'postgres',
  PASSWORD = 'postgres',
  DEBUG = function(statement)
    --     md('sql', utils.exec([[cat << 'EOF' | npx sql-formatter -l postgresql
    -- %s
    -- EOF]], statement))
    md('sql', statement)
  end,
}
Model.db_config = db_config
Model.auto_primary_key = true


local Usr = Model:create_model {
  table_name = 'usr',
  fields = {
    { name = 'id',         type = 'integer', primary_key = true, serial = true },
    { name = 'username',   maxlength = 5,    required = true,    unique = true },
    { name = 'permission', type = 'integer', default = 0,        max = 5 },
  }
}

local Dept = Model:create_model {
  table_name = 'dept',
  { name = 'name', maxlength = 10, unique = true }
}

local Profile = Model:create_model {
  table_name = 'profile',
  { name = 'usr_id',    reference = Usr,  reference_column = 'id' },
  { name = 'dept_name', reference = Dept, reference_column = 'name' },
  { name = 'age',       required = true,  type = 'integer',         default = 0 },
  { name = 'sex',       default = 'f',    choices = { 'f', 'm' } },
  { name = 'salary',    type = 'float',   default = 1000 },

}

local Message = Model {
  table_name = 'message',
  { name = 'creator', reference = Profile, },
  { name = "target",  reference = Profile, },
  { name = 'content', maxlength = 100,     compact = false },
}

local Evaluate = Model {
  table_name = 'evaluate',
  unique_together = { 'usr_id', 'year' },
  { name = 'usr_id', reference = Usr, },
  { name = "year",   type = 'year', },
  { name = 'rank',   maxlength = 1,   default = 'C' },
}

local Log = Model:create_model {
  table_name = 'log',
  fields = {
    { name = 'id',         type = 'integer', primary_key = true, serial = true },
    { name = 'delete_id',  type = 'integer', default = 0 },
    { name = 'model_name', type = 'string',  maxlength = 20 },
    { name = 'action',     maxlength = 10, }
  }
}

local Log2 = Model:create_model {
  table_name = 'log2',
  fields = {
    { name = 'buyer',  reference = Usr, },
    { name = 'seller', reference = Usr, },
  }
}

local Log3 = Model:create_model {
  table_name = 'log3',
  fields = {
    { name = 'start_log', reference = Log2, },
    { name = 'end_log',   reference = Log2, },
  }
}

local TableModel = Model:create_model {
  { name = 'ages',  type = 'array', field = { type = 'integer', max = 2 } },
  { name = 'users', type = 'table', model = Usr }
}

local models = {
  Usr,
  Dept,
  Profile,
  Message,
  Evaluate,
  Log,
  Log2,
  Log3,
}
---comment
---@return {[string]:Xodel}
local function crate_table_from_models()
  local res = {}
  for i = #models, 1, -1 do
    local model = models[i]
    assert(Usr.query("DROP TABLE IF EXISTS " .. model.table_name .. " CASCADE"))
  end
  for _, model in ipairs(models) do
    assert(Usr.query(migrate.get_table_defination(model)))
    res[model.class_name] = model
  end
  return res
end

models = crate_table_from_models()

utils.repr.hide_address = true
local function eval(s, ctx)
  md('lua', s)
  local res = { utils.eval(s, utils.dict(models, { models = models, Q = Q }, ctx)) }
  local ins = res[1]
  if not Model:is_instance(ins) then
    md('js', utils.repr(ins))
  end
  local statement
  if Model:is_instance(ins) then
    statement = ins:statement()
    res = { statement }
  elseif ngx.re.match(tostring(ins), '^(SELECT|UPDATE|DELETE|INSERT|WITH)') then
    statement = ins
  end
  if statement then
    md('sql', statement)
  end
  return unpack(res)
end

local function mit(s, func)
  it(s, function()
    print('## ', s)
    return func()
  end)
end
local function mdesc(s, func)
  describe(s, function()
    print('# ', s)
    return func()
  end)
end
local default_permission = Usr.fields.permission.default
local default_rank = Evaluate.fields.rank.default
mdesc("Xodel:insert(rows:table|table[]|Sql, columns?:string[])", function()
  mit("insert one user", function()
    local res = eval [[ Usr:insert{permission=1, username ='u1'}:exec() ]]
    assert.are.same(res, { affected_rows = 1 })
  end)
  mit("insert one user returning one column", function()
    local res = eval [[ Usr:insert{permission=1, username ='u2'}:returning('permission'):exec() ]]
    assert.are.same(res, { { permission = 1 } })
  end)
  mit("insert one user with default permission", function()
    local res = eval [[ Usr:insert{username ='u3'}:returning('permission'):exec() ]]
    assert.are.same(res, { { permission = 0 } })
  end)
  mit("insert one user returning two columns", function()
    local res = eval [[ Usr:insert{permission=1, username ='u4'}:returning('permission','username'):exec() ]]
    assert.are.same(res, { { permission = 1, username = 'u4' } })
  end)
  mit("insert one user returning one column in compact form", function()
    local res = eval [[ Usr:insert{permission=1, username ='u5'}:returning('username'):compact():exec() ]]
    assert.are.same(res, { { 'u5' } })
  end)
  mit("insert two users", function()
    local res = eval [[ Usr:insert{{permission=1, username ='u6'}, {permission=1, username ='u7'}}:exec() ]]
    assert.are.same(res, { affected_rows = 2 })
  end)
  mit("insert two users returning one column", function()
    local res = eval [[ Usr:insert{{permission=1, username ='u8'}, {permission=1, username ='u9'}}:returning('username'):exec() ]]
    assert.are.same(res, { { username = 'u8' }, { username = 'u9' } })
  end)
  mit("insert two users returning two columns", function()
    local res = eval [[ Usr:insert{{permission=2, username ='u10'}, {permission=3, username ='u11'}}:returning('username','permission'):exec() ]]
    assert.are.same(res, { { username = 'u10', permission = 2 }, { username = 'u11', permission = 3 } })
  end)
  mit("insert two users returning one column in flatten form", function()
    local res = eval [[ Usr:insert{{permission=1, username ='u12'}, {permission=1, username ='u13'}}:returning('username'):flat() ]]
    assert.are.same(res, { 'u12', 'u13' })
  end)
  mit("insert two users returning two columns in flatten form", function()
    local res = eval [[ Usr:insert{{permission=1, username ='u14'}, {permission=2, username ='u15'}}:returning('username','permission'):flat() ]]
    assert.are.same(res, { 'u14', 1, 'u15', 2 })
  end)
  mit("insert one user with specific columns (permission being ignored)", function()
    local res = eval [[ Usr:insert({permission=4, username ='u16'}, {'username'}):returning('username','permission'):exec() ]]
    assert.are.same(res, { { permission = 0, username = 'u16' } })
  end)
  mit("insert one user with specific columns", function()
    local res = eval [[ Usr:insert({permission=4, username ='u17'}, {'username', 'permission'}):returning('username','permission'):exec() ]]
    assert.are.same(res, { { permission = 4, username = 'u17' } })
  end)
  mit("insert two users with specific columns (permission being ignored)", function()
    local res = eval [[ Usr:insert({{permission=4, username ='u18'},{permission=5, username ='u19'}}, {'username'}):returning('username','permission'):exec() ]]
    assert.are.same(res, { { permission = 0, username = 'u18' }, { permission = 0, username = 'u19' } })
  end)
  mit("insert two users with specific columns", function()
    local res = eval [[ Usr:insert({{permission=4, username ='u20'},{permission=5, username ='u21'}}, {'username', 'permission'}):returning('username','permission'):exec() ]]
    assert.are.same(res, { { permission = 4, username = 'u20' }, { permission = 5, username = 'u21' } })
  end)
  mit("insert users with default permission", function()
    local res = eval [[ Usr:insert{{username ='f1'},{username ='f2'}}:flat('permission') ]]
    assert.are.same(res, { 0, 0 })
  end)
  mit("insert one user validate required failed", function()
    local expected = {
      type = 'field_error',
      name = 'username',
      label = 'username',
      message = '此项必填'
    }
    assert.Error(function()
      models.Usr:insert { permission = 1 }:exec()
    end, expected)
  end)
  mit("insert one user validate maxlength failed", function()
    local expected = {
      type = 'field_error',
      name = 'username',
      label = 'username',
      message = format('字数不能多于%s个', models.Usr.fields.username.maxlength)
    }
    assert.Error(function()
      models.Usr:insert { username = '123456' }:exec()
    end, expected)
  end)
  mit("insert one user validate max failed", function()
    local expected = {
      type = 'field_error',
      name = 'permission',
      label = 'permission',
      message = format('值不能大于%s', models.Usr.fields.permission.max)
    }
    assert.Error(function()
      models.Usr:insert { username = 'foo', permission = 6 }:exec()
    end, expected)
  end)
  mit("insert two users validate max failed", function()
    local expected = {
      batch_index = 2,
      type = 'field_error',
      name = 'permission',
      label = 'permission',
      message = format('值不能大于%s', models.Usr.fields.permission.max)
    }
    assert.Error(function()
      models.Usr:insert { { username = 'foo', permission = 1 }, { username = 'bar', permission = 7 } }:exec()
    end, expected)
  end)
end)
mdesc("Xodel:insert", function()
  mit("create", function()
    local res = eval [[Dept:insert{name ='d1'}:returning('*'):execr()]]
    assert.are.same(res, { { id = 1, name = 'd1' } })
  end)
  mit("create multiple rows", function()
    local res = eval [[Dept:insert{{name ='d2'}, {name ='d3'}}:returning('name'):execr()]]
    assert.are.same(res, { { name = 'd2' }, { name = 'd3' } })
  end)
end)
mdesc("Xodel:count(cond?, op?, dval?)", function()
  mit("specify condition", function()
    local cnt = eval [[Usr:count{id__lt=3}]]
    assert.are.same(cnt, 2)
  end)
  mit("test with Xodel:all", function()
    local us = eval [[Dept:execr()]]
    local cnt = eval [[Dept:count()]]
    assert.are.same(#us, cnt)
  end)
end)
mdesc("XodelInstance:save(names?:string[], key?:string)", function()
  local default_age = Profile.fields.age.default
  local default_sex = Profile.fields.sex.default
  local default_salary = Profile.fields.salary.default
  mit("save basic", function()
    local res = eval [[Profile{usr_id=1, dept_name='d1', age=20}:save()]]
    res.id = nil
    assert.are.same(res, { usr_id = 1, dept_name = 'd1', age = 20, salary = default_salary, sex = default_sex, })
  end)
  mit("save with specific names", function()
    local res = eval [[Profile{usr_id=2, dept_name='d2', salary=500, sex='m', age=50}:save{'usr_id','dept_name'}]]
    res.id = nil
    assert.are.same(res, { usr_id = 2, dept_name = 'd2', age = default_age, salary = default_salary, sex = default_sex, })
  end)
  mit("save with primary key specified to update", function()
    local res = eval [[Profile{id=1, age=33}:save()]]
    assert.are.same(res, { id = 1, age = 33 })
  end)
  mit("save with primary key ignored and force create", function()
    local res = eval [[Profile{id=5, age=55, usr_id=3, dept_name='d3',}:save_create()]]
    assert.are.same(res, { id = 3, age = 55, dept_name = 'd3', usr_id = 3, salary = default_salary, sex = default_sex, })
  end)
  mit("save with wrong name", function()
    assert.Error(function()
      eval [[Profile{usr_id=1, dept_name='d1', age=20}:save{'xxxx'}]]
    end, "invalid field name 'xxxx' for model 'profile'")
  end)
end)
mdesc("Xodel:merge(rows:table[], key?:string|string[], columns?:string[])", function()
  mit("merge multiple rows returning inserted rows with all columns", function()
    local res = eval [[Usr:merge({{permission=4, username ='u1'},{permission=2, username ='u22'}}, 'username'):returning('*'):exec()]]
    local object = require("resty.object")
    assert.are.True(object.contains(res[1], { permission = 2, username = 'u22' }))
  end)
  mit("merge multiple rows returning inserted rows with specific columns", function()
    local res = eval [[Usr:merge({{username ='u23'},{username ='u24'}}, 'username'):returning('username'):exec()]]
    assert.are.same(res, { { username = 'u23' }, { username = 'u24' } })
  end)
  mit("merge multiple rows returning inserted rows with specific columns in compact form", function()
    local res = eval [[Usr:merge({{username ='u25'},{username ='u26'}}, 'username'):returning('username'):flat()]]
    assert.are.same(res, { 'u25', 'u26' })
  end)
  mit("merge multiple rows returning inserted rows with array key", function()
    local res = eval [[Evaluate:merge({{usr_id=1, year=2021, rank='A'},{usr_id=1, year=2022, rank='B'}}, {'usr_id', 'year'}):returning('rank'):flat()]]
    assert.are.same(res, { 'A', 'B' })
  end)
  mit("merge multiple rows returning inserted rows with array key and specific columns", function()
    local res = eval [[Evaluate:merge({{usr_id=2, year=2021, rank='A'},{usr_id=2, year=2022, rank='B'}}, {'usr_id', 'year'}, {'usr_id', 'year'}):returning('rank'):flat()]]
    assert.are.same(res, { default_rank, default_rank })
  end)
  mit("merge multiple rows validate max failed", function()
    local expected = {
      batch_index = 1,
      type = 'field_error',
      name = 'permission',
      label = 'permission',
      message = format('值不能大于%s', models.Usr.fields.permission.max)
    }
    assert.Error(function()
      models.Usr:merge({ { permission = 14, username = 'u1' } }, 'username'):exec()
    end, expected)
  end)
  mit("merge multiple rows missing default unique value failed", function()
    local pk = 'username'
    local expected = {
      batch_index = 2,
      type = 'field_error',
      name = pk,
      label = pk,
      message = pk .. '不能为空'
    }
    assert.Error(function()
      models.Usr:merge { { permission = 1, username = 'u1', }, { permission = 1, } }:exec()
    end, expected)
  end)
end)
mdesc("Xodel:upsert(rows:table[], key?:string|string[], columns?:string[])", function()
  mit("upsert multiple rows returning inserted rows with all columns", function()
    local res = eval [[Usr:upsert({{permission=4, username ='u1'},{permission=2, username ='u27'}}, 'username'):returning('username'):exec()]]
    assert.are.same(res, { { username = 'u1' }, { username = 'u27' } })
  end)
  mit("upsert multiple rows returning inserted rows with specific columns in compact form", function()
    local res = eval [[Usr:upsert({{username ='u28'},{username ='u29'}}, 'username'):returning('username'):flat()]]
    assert.are.same(res, { 'u28', 'u29' })
  end)
  mit("upsert multiple rows returning inserted rows with array key", function()
    local res = eval [[Evaluate:upsert({{usr_id=1, year=2021, rank='A'},{usr_id=1, year=2022, rank='B'}}, {'usr_id', 'year'}):returning('rank'):flat()]]
    assert.are.same(res, { 'A', 'B' })
  end)
  mit("upsert multiple rows validate max failed", function()
    local expected = {
      batch_index = 1,
      type = 'field_error',
      name = 'permission',
      label = 'permission',
      message = format('值不能大于%s', models.Usr.fields.permission.max)
    }
    assert.Error(function()
      models.Usr:upsert({ { permission = 14, username = 'u1' } }, 'username'):exec()
    end, expected)
  end)
end)
mdesc("Xodel.update", function()
  mit("update one user", function()
    local res = eval [[ Usr:update{permission=2}:where{id=1}:exec() ]]
    assert.are.same(res, { affected_rows = 1 })
  end)
  mit("update one user returning one column", function()
    local res = eval [[ Usr:update{permission=3}:where{id=1}:returning('permission'):exec() ]]
    assert.are.same(res, { { permission = 3 } })
  end)
  mit("update users returning two columns in table form", function()
    local res = eval [[ Usr:update{permission=3}:where{id__lt=3}:returning{'permission','id'}:exec() ]]
    assert.are.same(res, { { id = 1, permission = 3 }, { id = 2, permission = 3 } })
  end)
  mit("update users returning one column in flatten form", function()
    local res = eval [[ Usr:update{permission=3}:where{id__lt=3}:returning{'username'}:flat() ]]
    assert.are.same(res, { 'u1', 'u2' })
  end)
  mit("update by where with foreignkey", function()
    local res = eval [[Profile:update{age=11}:where{usr_id__username__contains='1'}:returning('age'):exec()]]
    assert.are.same(res, { { age = 11 } })
  end)
  mit("update returning foreignkey", function()
    local res = eval [[Profile:update { sex = 'm' }:where { id = 1 }:returning('id', 'usr_id__username'):exec()]]
    assert.are.same(res[1], { id = 1, usr_id__username = 'u1' })
  end)
end)
mdesc("Xodel:updates(rows:table[], key?:string|string[], columns?:string[])", function()
  mit("updates partial", function()
    local res = eval [[Usr:updates({{permission=2, username ='u1'},{permission=3, username ='??'}}, 'username'):returning("*"):exec()]]
    assert.are.same(res, { { permission = 2, username = 'u1', id = 1 } })
  end)
  mit("updates all", function()
    local res = eval [[Usr:updates({{permission=1, username ='u1'},{permission=3, username ='u3'}}, 'username'):returning("*"):exec()]]
    assert.are.same(res, { { permission = 1, username = 'u1', id = 1 }, { permission = 3, username = 'u3', id = 3 } })
  end)
end)
mdesc("Xodel.where", function()
  mit("where basic", function()
    local res = eval [[ Usr:select('username','id'):where{id=1}:exec() ]]
    assert.are.same(res, { { id = 1, username = 'u1' } })
  end)
  mit("where condition by 2 args", function()
    local res = eval [[ Usr:select('id'):where('id', 3):exec() ]]
    assert.are.same(res, { { id = 3 } })
  end)
  mit("where condition by 3 args", function()
    local res = eval [[ Usr:select('id'):where('id', '<',  3):flat() ]]
    assert.are.same(res, { 1, 2 })
  end)
  local ops = { lt = "<", lte = "<=", gt = ">", gte = ">=", ne = "<>", eq = "=" }
  for key, op in pairs(ops) do
    mit("where by arithmetic operator: __" .. key, function()
      local statement = eval(format([[Usr:where{id__%s=2}:select('id')]], key))
      assert.are.same(statement, format([[SELECT T.id FROM usr T WHERE T.id %s 2]], op))
    end)
  end
  mit("where in", function()
    local res = eval [[Usr:where{username__in={'u1','u2'}}]]
    assert.are.same(res, [[SELECT * FROM usr T WHERE T.username IN ('u1', 'u2')]])
  end)
  mit("where contains", function()
    local res = eval [[Usr:where{username__contains='u'}]]
    assert.are.same(res, [[SELECT * FROM usr T WHERE T.username LIKE '%u%']])
  end)
  mit("where startswith", function()
    local res = eval [[Usr:where{username__startswith='u'}]]
    assert.are.same(res, [[SELECT * FROM usr T WHERE T.username LIKE 'u%']])
  end)
  mit("where endswith", function()
    local res = eval [[Usr:where{username__endswith='u'}]]
    assert.are.same(res, [[SELECT * FROM usr T WHERE T.username LIKE '%u']])
  end)
  mit("where null true", function()
    local res = eval [[Usr:where{username__null=true}]]
    assert.are.same(res, [[SELECT * FROM usr T WHERE T.username IS NULL]])
  end)
  mit("where null false", function()
    local res = eval [[Usr:where{username__null=false}]]
    assert.are.same(res, [[SELECT * FROM usr T WHERE T.username IS NOT NULL]])
  end)
  mit("where notin", function()
    local res = eval [[Usr:where{username__notin={'u1','u2'}}]]
    assert.are.same(res, [[SELECT * FROM usr T WHERE T.username NOT IN ('u1', 'u2')]])
  end)
  mit("where foreignkey eq", function()
    local res = eval [[Profile:where{usr_id__username__eq='u1'}]]
    assert.are.same(res,
      [[SELECT * FROM profile T INNER JOIN usr T1 ON (T.usr_id = T1.id) WHERE T1.username = 'u1']])
  end)
  mit("where foreignkey in", function()
    local res = eval [[Profile:where{usr_id__username__in={'u1','u2'}}]]
    assert.are.same(res,
      [[SELECT * FROM profile T INNER JOIN usr T1 ON (T.usr_id = T1.id) WHERE T1.username IN ('u1', 'u2')]])
  end)
  mit("where foreignkey contains", function()
    local res = eval [[Profile:where{usr_id__username__contains='u'}]]
    assert.are.same(res,
      [[SELECT * FROM profile T INNER JOIN usr T1 ON (T.usr_id = T1.id) WHERE T1.username LIKE '%u%']])
  end)
  mit("where foreignkey startswith", function()
    local res = eval [[Profile:where{usr_id__username__startswith='u'}]]
    assert.are.same(res,
      [[SELECT * FROM profile T INNER JOIN usr T1 ON (T.usr_id = T1.id) WHERE T1.username LIKE 'u%']])
  end)
  mit("where foreignkey endswith", function()
    local res = eval [[Profile:where{usr_id__username__endswith='u'}]]
    assert.are.same(res,
      [[SELECT * FROM profile T INNER JOIN usr T1 ON (T.usr_id = T1.id) WHERE T1.username LIKE '%u']])
  end)
  mit("where foreignkey null true", function()
    local res = eval [[Profile:where{usr_id__username__null=true}]]
    assert.are.same(res,
      [[SELECT * FROM profile T INNER JOIN usr T1 ON (T.usr_id = T1.id) WHERE T1.username IS NULL]])
  end)
  mit("where foreignkey null false", function()
    local res = eval [[Profile:where{usr_id__username__null=false}]]
    assert.are.same(res,
      [[SELECT * FROM profile T INNER JOIN usr T1 ON (T.usr_id = T1.id) WHERE T1.username IS NOT NULL]])
  end)
  for key, op in pairs(ops) do
    mit("where foreignkey number operator " .. key, function()
      local statement = eval(format([[Profile:where{usr_id__permission__%s=2}]], key))
      assert.are.same(statement,
        format([[SELECT * FROM profile T INNER JOIN usr T1 ON (T.usr_id = T1.id) WHERE T1.permission %s 2]], op))
    end)
  end
end)
mdesc("Xodel.select", function()
  mit("select fk column", function()
    local res = eval [[Profile:select('id', 'usr_id__username'):where { id = 1 }:exec()]]
    assert.are.same(res[1], { id = 1, usr_id__username = 'u1' })
  end)
end)
mdesc("Xodel:get(cond?, op?, dval?)", function()
  mit("basic", function()
    local u = eval [[Usr:get{id=3}]]
    assert.are.same(u, { id = 3, permission = 3, username = 'u3' })
  end)
  local fu
  mit("model load foreign row", function()
    local p = models.Profile:get { id = 1 }
    fu = p.usr_id
    assert.are.same(fu, { id = 1 })
  end)
  mit("fetch extra foreignkey field from database on demand", function()
    assert.are.same(fu.username, 'u1')
    assert.are.same(getmetatable(fu), Usr.RecordClass)
  end)
  mit("model load foreign row with specified columns", function()
    local p = eval [[Profile:load_fk('usr_id', 'username', 'permission'):get{id=1}]]
    assert.are.same(p, { usr_id = { username = 'u1', permission = 1 } })
  end)
  mit("model load foreign row with all columns by *", function()
    local p = eval [[Profile:load_fk('usr_id', '*'):get{id=1}]]
    local u = models.Usr:get { id = p.usr_id.id }
    assert.are.same(p, { usr_id = u })
  end)
  mit("model load foreign row with specified columns two api are the same", function()
    local p1 = eval [[Profile:select("sex"):load_fk('usr_id', 'username', 'permission'):get{id=1}]]
    local p2 = eval [[Profile:select("sex"):load_fk('usr_id', {'username', 'permission'}):get{id=1}]]
    assert.are.same(p1, p2)
  end)
  mit("Xodel:get(cond?, op?, dval?)", function()
    assert.Error(function()
      eval [[Usr:get{id__lt=3}]]
    end, 'multiple records returned: 2')
  end)
end)
mdesc("Xodel:get_or_create(params:table, defaults?:table, columns?:string[])", function()
  mit("basic", function()
    local res, created = eval([[Usr:get_or_create{username='goc'}]])
    assert.are.same(res, { username = 'goc', id = res.id })
    assert.are.same(created, true)
  end)
  mit("model get_or_create with defaults", function()
    local res, created = eval([[Usr:get_or_create({username='goc2'}, {permission = 5})]])
    assert.are.same(res, { username = 'goc2', id = res.id, permission = 5 })
    assert.are.same(created, true)
  end)
end)
describe("Xodel api:", function()
  mit("test chat model", function()
    local res1 = models.Message:insert({
      { id = 1, creator = 1, target = 2, content = 'c121' },
      { id = 2, creator = 1, target = 2, content = 'c122' },
      { id = 3, creator = 2, target = 1, content = 'c123' },
      { id = 4, creator = 1, target = 3, content = 'c131' },
      { id = 5, creator = 1, target = 3, content = 'c132' },
      { id = 6, creator = 3, target = 1, content = 'c133' },
      { id = 7, creator = 1, target = 3, content = 'c134' },
      { id = 8, creator = 2, target = 3, content = 'c231' }, }):returning('*'):execr()
    -- SELECT DISTINCT ON (CASE WHEN creator=1 THEN target ELSE creator END)  creator, target, content
    -- FROM message
    -- WHERE creator=1 OR target=1
    -- ORDER BY CASE WHEN creator=1 THEN target ELSE creator END, -id;
    -- local res = models.Message:distinct(sql.token 'CASE WHEN creator=1 THEN target ELSE creator END')
    --     :where(Q { creator = 1 } / Q { target = 1 })
    --     :select('creator', 'target', 'content'):order("-id"):execr()
    -- assert.are.same(res, {
    --   { creator = 2, target = 1, content = 'c123' },
    --   { creator = 1, target = 3, content = 'c134' } })
  end)

  mit("go crazy with where clause with recursive join", function()
    local message = models.Message:save { creator = 1, target = 2, content = 'crazy' }
    local p = models.Profile:get { id = message.creator }
    local u = models.Usr:get { id = p.usr_id.id }
    local res = models.Message:where {
      id = message.id,
      creator__usr_id__username__contains = u.username:sub(2),
      creator__age = p.age }:select(
      'id',
      'creator__age',
      'creator__usr_id__username'):exec()
    assert.are.same(res, { { id = message.id, creator__age = 11, creator__usr_id__username = 'u1' } })
    local res2 = models.Message:select(
      'id',
      'creator__age',
      'creator__usr_id__username'):where { id = message.id }:exec()
    assert.are.same(res, res2)
  end)
end)
mdesc("etc", function()
  mit("wrong fk name", function()
    assert.Error(function()
      eval [[Message:where {creator__usr_id__views=0}:exec()]]
    end, '5.1 invalid operator: views')
  end)
  mit("wrong fk name3", function()
    assert.Error(function()
      eval [[Message:select('creator__usr_id__views'):exec()]]
    end, '5.2 invalid column: views')
  end)
  mit("test shortcuts join", function()
    local p = eval [[Profile:join('dept_name'):get { id = 1 }]]
    assert.are.same(p.dept_name, { name = 'd1' })
  end)
  mit("sql select_as", function()
    local res = eval [[Usr:select_as{id = 'value', username = 'label'}:where { id = 2 }:exec()]]
    assert.are.same(res, { { value = 2, label = 'u2' } })
  end)
  mit("sql select_as foreignkey", function()
    local res = eval [[Profile:select_as{usr_id__permission = 'uperm'}:where { id = 2 }:exec()]]
    assert.are.same(res, { { uperm = 3 } })
  end)
end)
mdesc("sql injection", function()
  mit("where key", function()
    local segment = 'id=1;select * FROM usr T where id'
    assert.Error(function()
      models.Usr:where { [segment] = 2 }:exec()
    end, string.format("parse column error, invalid name: %s", segment))
  end)
  mit("where value", function()
    local segment = [[1 or 1=1]]
    assert.Error(function()
      models.Usr:where { id = segment }:exec()
    end, string.format('ERROR: invalid input syntax for type integer: "%s" (34)', segment))
  end)
  mit("order", function()
    local segment = 'id;select * from usr'
    assert.Error(function()
      models.Usr:order(segment):exec()
    end, string.format("invalid order arg format: %s", segment))
  end)
  mit("select", function()
    local segment = '1;select * from usr;select username'
    assert.Error(function()
      models.Usr:select(segment):exec()
    end, string.format("parse column error, invalid name: %s", segment))
  end)
end)
mdesc("Xodel:delete(cond?, op?, dval?)", function()
  mit("model class delete all", function()
    local res = eval([[Evaluate:delete{}:exec()]])
    assert.are.same(res, { affected_rows = 4 })
  end)

  mit("model instance delete", function()
    models.Message:delete {}:exec()
    models.Message:delete {}:exec()
    local du = Profile:get { id = 1 }
    local res = eval([[du:delete()]], { du = du })
    assert.are.same(res, { { id = du.id } })
  end)
  mit("model instance delete use non primary key", function()
    local du = models.Usr:get { id = 1 }
    local res = eval([[du:delete('username')]], { du = du })
    assert.are.same(res, { { username = 'u1' } })
  end)
  mit("create with foreign model returning all", function()
    local u = models.Usr:get { id = 3 }
    local res = eval([[Profile:insert{usr_id=u, age=12}:returning("*"):execr()]], { u = u })
    assert.are.same(res[1].usr_id, 3)
  end)
  mit("insert from delete returning", function()
    local u = models.Usr:get { id = 2 }
    local p = eval [[Log:insert(Profile:delete { id = 2 }:returning('id'):returning_literal("usr", "delete"),
      { 'delete_id', 'model_name', "action" }):returning("*"):execr()]]
    assert.are.same(p[1].delete_id, u.id)
  end)
end)

mdesc("field stuff", function()
  mit("table field validate", function()
    assert.Error(function()
        TableModel:save { users = { { username = 'foo' }, { username = 'foo234' } } }
      end,
      ---@diagnostic disable-next-line: param-type-mismatch
      {
        label = 'users',
        index = 2,
        message = {
          label = 'username',
          message = '字数不能多于5个',
          name = 'username',
          type = 'field_error'
        },
        name = 'users',
        type = 'field_error'
      })
  end)
  mit("array field validate", function()
    assert.Error(function()
        TableModel:save { ages = { 1, 20 } }
      end,
      ---@diagnostic disable-next-line: param-type-mismatch
      {
        label = 'ages',
        index = 2,
        message = '值不能大于2',
        name = 'ages',
        type = 'field_error'
      })
  end)
  mit("alioss_list", function()
    local af = field.alioss_list { name = 'pics', size = '2m', key_id = "key_id", key_secret = "key_secret" }
    local j = af:json()
    assert.are.same({ type = j.type, db_type = j.db_type, name = j.name, size = j.size, },
      { type = 'alioss_list', db_type = 'jsonb', name = 'pics', size = '2m', })
  end)
  -- mit("different join", function()
  --   local q = Log3:where { start_log__buyer__username = 'foo', start_log__seller__username = 'bar' }
  --   utils.loger(table.keys(q._join_keys))
  --   assert.are.same(q:statement(), 'aaa')
  -- end)
end)
