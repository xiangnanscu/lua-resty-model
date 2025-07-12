---@diagnostic disable: param-type-mismatch
local utils = require("resty.utils")
local sql = require "resty.sql"
local field = require "resty.fields"
local array = require "resty.array"
local migrate = require "resty.migrate"
local Model = require("./lib/resty/model")
local format = string.format


local db_config = {
  DATABASE = 'test',
  USER = 'postgres',
  PASSWORD = 'postgres',
  DEBUG = function(statement)
    print(statement)
  end,
}
Model.db_config = db_config
Model.auto_primary_key = true


local Usr = Model:create_model {
  table_name = 'usr',
  fields = {
    id = { type = 'integer', primary_key = true, serial = true },
    name = { maxlength = 5, required = true, unique = true },
    permission = { type = 'integer', default = 0, choices = { 0, 1, 2, 3 } },
  }
}

local UsrBak = Model:create_model {
  table_name = 'usr_bak',
  mixins = { Usr }
}

local Org = Model:create_model {
  table_name = 'org',
  { 'name', maxlength = 10, unique = true }
}

local OrgAdmin = Model:create_model({
  table_name = "org_admin",
  fields = {
    usr = { reference = Usr },
    org = { reference = Org }
  },
})

local Profile = Model:create_model {
  table_name = 'profile',
  { 'usr',    reference = Usr },
  { 'parent', reference = "self" },
  { 'child',  reference = "self" },
  { 'age',    type = 'integer',  default = 1 },
}

local models = {
  Usr,
  UsrBak,
  Org,
  OrgAdmin,
  Profile,
}

---@return {[string]:Xodel}
local function crate_table_from_models()
  local res = {}
  for i = #models, 1, -1 do
    local model = models[i]
    assert(Usr.query("DROP TABLE IF EXISTS " .. model.table_name .. " CASCADE"))
  end
  for _, model in ipairs(models) do
    assert(Usr.query(migrate.get_table_defination(model)))
    res[model.table_name] = model
  end
  return res
end

models = crate_table_from_models()

utils.repr.hide_address = true

local default_permission = Usr.fields.permission.default

describe("test insert", function()
  it("insert one user", function()
    local res = Usr:insert { permission = 1, name = 'u1' }:exec()
    assert.are.same(res, { affected_rows = 1 })
  end)
  it("insert one user returning all", function()
    local res = Usr:insert { permission = 2, name = 'u2' }:returning("*"):exec()
    assert.are.same(res, { { id = 2, name = 'u2', permission = 2 } })
  end)
  it("insert one user using default", function()
    local res = Usr:insert { name = 'u3' }:returning("permission"):exec()
    assert.are.same(res, { { permission = default_permission } })
  end)
  it("insert two users", function()
    local rows = { { name = 'u4' }, { name = 'u5' } }
    local res = Usr:insert(rows):returning { "name", "permission" }:exec()
    assert.are.same(res,
      { { name = 'u4', permission = default_permission }, { name = 'u5', permission = default_permission } })
  end)
  it("insert one user returning id in compact form", function()
    local res = Usr:insert { permission = 2, name = 'u6' }:returning("name"):compact():exec()
    assert.are.same(res, { { 'u6' } })
  end)
  it("insert two users returning id in compact form", function()
    local res = Usr:insert { { name = 'u7' }, { name = 'u8' } }:returning("name"):compact():exec()
    assert.are.same(res, { { 'u7' }, { 'u8' } })
  end)
  it("insert bak users from select subquery", function()
    local subsql = Usr:select("name", "permission"):where { permission = 2 }
    local res = UsrBak:insert(subsql):returning("name", "permission"):exec()
    local res2 = subsql:exec()
    assert.are.same(res, res2)
  end)
  it("insert bak users from delete subquery", function()
    local p1_users = Usr:where { permission = 1 }:select { "name", "permission" }:exec()
    local subsql = Usr:delete { permission = 1 }:returning("name", "permission")
    local res = UsrBak:insert(subsql):returning("name", "permission"):exec()
    assert.are.same(res, p1_users)
  end)
  it("insert users from delete subquery with specified columns", function()
    local p1_users = UsrBak:where { permission = 1 }:select { "name" }:select_literal_as { [3] = 'permission' }:exec()
    local subsql = UsrBak:delete { permission = 1 }:returning("name"):returning_literal(3)
    local res = Usr:insert(subsql, { 'name', 'permission' }):returning("name", "permission"):exec()
    assert.are.same(res, p1_users)
  end)
  it("insert bak users from update subquery", function()
    local subsql = Usr:update { permission = 3 }:where { permission = 1 }:returning { "name", "permission" }
    local res = UsrBak:insert(subsql):returning("name", "permission"):exec()
    assert.are.same(res, subsql:exec())
  end)
  it("insert one user validate required failed", function()
    local expected = {
      type = 'field_error',
      name = 'name',
      label = 'name',
      message = '此项必填'
    }
    assert.Error(function()
      Usr:insert { permission = 1 }:exec()
    end, expected)
  end)
  it("insert one user validate choices failed", function()
    local invalid_permission = 6
    local expected = {
      type = 'field_error',
      name = 'permission',
      label = 'permission',
      message = format('“%s”无效选项，限下列选项：0，1，2，3', invalid_permission)
    }
    assert.Error(function()
      Usr:insert { permission = invalid_permission, name = 'u' }:exec()
    end, expected)
  end)
  it("insert one user validate maxlength failed", function()
    local expected = {
      type = 'field_error',
      name = 'name',
      label = 'name',
      message = format('字数不能多于%s个', Usr.fields.name.maxlength)
    }
    assert.Error(function()
      Usr:insert { name = '123456' }:exec()
    end, expected)
  end)
  it("insert two users validate required failed at 2nd row", function()
    local expected = {
      type = 'field_error',
      batch_index = 2,
      name = 'name',
      label = 'name',
      message = '此项必填'
    }
    assert.Error(function()
      Usr:insert { { name = 'u', permission = 1 }, { permission = 1 } }:exec()
    end, expected)
  end)
  it("insert two users validate maxlength failed at 2nd row", function()
    local expected = {
      type = 'field_error',
      batch_index = 2,
      name = 'name',
      label = 'name',
      message = format('字数不能多于%s个', Usr.fields.name.maxlength)
    }
    assert.Error(function()
      Usr:insert { { name = 'u', permission = 1 }, { name = '123456', permission = 1 } }:exec()
    end, expected)
  end)
  it("insert two users validate choices failed at 1st row", function()
    local invalid_permission = 7
    local expected = {
      type = 'field_error',
      batch_index = 1,
      name = 'permission',
      label = 'permission',
      message = format('“%s”无效选项，限下列选项：0，1，2，3', invalid_permission)
    }
    assert.Error(function()
      Usr:insert { { name = 'u', permission = invalid_permission }, { permission = 1 } }:exec()
    end, expected)
  end)
  it("insert user skip validate", function()
    local invalid_permission = 7
    assert.Not.Error(function()
      Usr:skip_validate():insert { name = 'u', permission = invalid_permission }
    end)
  end)
  it("update user skip validate", function()
    local invalid_permission = 7
    assert.Not.Error(function()
      Usr:skip_validate():update { name = 'u', permission = invalid_permission }
    end)
  end)
  it("insert one user with invalid columns", function()
    local invalid_name = 'xx'
    assert.Error(function()
      Usr:insert({ permission = 1, name = 'u1' }, { invalid_name })
    end, format("invalid field name '%s' for model 'usr'", invalid_name))
  end)
end)
describe("test select where", function()
  Profile:insert {
    { usr = 2, age = 82 },
    { usr = 3, age = 62 },
    { usr = 4, age = 42 },

    { usr = 5, age = 52 },
    { usr = 6, age = 32 },
    { usr = 7, age = 12 },
  }:exec()
  Profile:update { child = 2, }:where { usr = 2 }:exec()
  Profile:update { child = 3, parent = 1 }:where { usr = 3 }:exec()
  Profile:update { parent = 2 }:where { usr = 4 }:exec()

  Profile:update { child = 5, }:where { usr = 5 }:exec()
  Profile:update { child = 6, parent = 4 }:where { usr = 6 }:exec()
  Profile:update { parent = 5 }:where { usr = 7 }:exec()
  it("simple select", function()
    local res = Usr:select('id', "permission"):exec()
    local res2 = Usr:select { 'id', "permission" }:exec()
    assert.are.same(res, res2)
  end)
  it("select auto join", function()
    local res = Profile:select("parent__age"):order("parent__age"):exec()
    assert.are.same(32, res[1].parent__age)
  end)
  it("select auto join depth 2", function()
    local res = Profile:select("parent__parent__age"):order("parent__parent__age"):exec()
    assert.are.same(52, res[1].parent__parent__age)
  end)
  it("select auto join depth 2", function()
    local res = Profile:select("usr"):select("parent__age"):select("parent__parent__age"):order("usr")
        :exec()
    assert.are.same({ 4, 7 }, { res[1].usr, res[#res].usr })
  end)
  it("where auto join", function()
    local res = Profile:select("usr"):where { parent__age = 32 }:raw():get()
    assert.are.same(7, res.usr)
  end)
  it("where auto join depth 2 and diffent join tables", function()
    local res = Profile:select("usr__name"):where { parent__parent__age = 82 }:get()
    assert.are.same({ usr__name = 'u4' }, res)
  end)
  Org:insert { { name = 'o1' }, { name = 'o2' }, { name = 'o3' } }:exec()
  OrgAdmin:insert { { usr = 2, org = 1 }, { usr = 3, org = 2 }, { usr = 4, org = 3 } }:exec()
  it("where auto join different tables", function()
    local res = OrgAdmin:select("usr__name", "org__name"):where { org__name = 'o3' }:exec()
    assert.are.same({ org__name = 'o3', usr__name = 'u4' }, res[1])
  end)
end)
