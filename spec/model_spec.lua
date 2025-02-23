---@diagnostic disable: param-type-mismatch
local utils = require("resty.utils")
local field = require "resty.fields"
local array = require "resty.array"
local migrate = require "resty.migrate"
local Model = require("./lib/resty/model")
local format = string.format
local Q = Model.Q
local F = Model.F
local Sum = Model.Sum
local Avg = Model.Avg
local Max = Model.Max
local Min = Model.Min
local Count = Model.Count

local function md(lang, s)
  print(format([[```%s
%s
```
]], lang, s))
end

local FORMAT_SQL = 10
local db_options = {
  DATABASE = 'test',
  USER = 'postgres',
  PASSWORD = 'postgres',
  DEBUG = function(statement)
    if FORMAT_SQL == 1 then
      md('sql', utils.exec([[cat << 'EOF' | npx sql-formatter -l postgresql
      %s
EOF]], statement))
    else
      md('sql', statement)
    end
  end,
}
Model.db_options = db_options
Model.auto_primary_key = true


---@class Blog
local Blog = Model:create_model {
  table_name = 'blog',
  fields = {
    { "name",    maxlength = 20, minlength = 2,              unique = true },
    { "tagline", type = 'text',  default = 'default tagline' },
  }
}

local BlogBin = Model:create_model {
  table_name = 'blog_bin',
  mixins = { Blog },
  fields = {
    { "name", unique = false },
    { "note", type = 'text' },
  }
}

-- define a structured json field from a abstract model
local Resume = Model:create_model {
  auto_primary_key = false,
  table_name = 'resume',
  unique_together = { 'start_date', 'end_date', 'company', 'position' },
  fields = {
    { "start_date",  type = 'date' },
    { "end_date",    type = 'date' },
    { "company",     maxlength = 20 },
    { "position",    maxlength = 20 },
    { "description", maxlength = 200 },
  }
}
---@class Author
local Author = Model:create_model {
  table_name = 'author',
  fields = {
    { "name",   maxlength = 200,  unique = true },
    { "email",  type = 'email' },
    { "age",    type = 'integer', max = 100 },
    { "resume", model = Resume },
  }
}

---@class Entry
local Entry = Model:create_model {
  table_name = 'entry',
  fields = {
    { 'blog_id',             reference = Blog, related_query_name = 'entry' },
    { 'reposted_blog_id',    reference = Blog, related_query_name = 'reposted_entry' },
    { "headline",            maxlength = 255,  compact = false },
    { "body_text",           type = 'text' },
    { "pub_date",            type = 'date' },
    { "mod_date",            type = 'date' },
    { "number_of_comments",  type = 'integer' },
    { "number_of_pingbacks", type = 'integer' },
    { "rating",              type = 'integer' },
  }
}

---@class ViewLog
local ViewLog = Model:create_model {
  table_name = 'view_log',
  fields = {
    { 'entry_id', reference = Entry },
    { "ctime",    type = 'datetime' },
  }
}

---@class Publisher
local Publisher = Model:create_model {
  table_name = 'publisher',
  fields = {
    { "name", maxlength = 300 },
  }
}

---@class Book
local Book = Model:create_model {
  table_name = 'book',
  fields = {
    { "name",         maxlength = 300,      compact = false },
    { "pages",        type = 'integer' },
    { "price",        type = 'float' },
    { "rating",       type = 'float' },
    { "author",       reference = Author },
    { 'publisher_id', reference = Publisher },
    { "pubdate",      type = 'date' },
  }
}

---@class Store
local Store = Model {
  table_name = 'store',
  fields = {
    { "name", maxlength = 300 },
  }
}

local model_list = {
  Blog,
  BlogBin,
  Author,
  Entry,
  ViewLog,
  Publisher,
  Book,
  Store,
}

---@return {[string]:Xodel}
local function crate_table_from_models()
  local res = {}
  for i = #model_list, 1, -1 do
    local model = model_list[i]
    assert(Blog.query("DROP TABLE IF EXISTS " .. model.table_name .. " CASCADE"))
  end
  for _, model in ipairs(model_list) do
    assert(Blog.query(migrate.get_table_defination(model)))
    res[model.class_name] = model
  end
  return res
end

local models = crate_table_from_models()


-- 初始化 Blog 数据
Blog:insert { name = 'My First Blog', tagline = 'Welcome to my blog' }:exec()
Blog:insert { name = 'Another Blog', tagline = 'Another interesting blog' }:exec()

-- 初始化 Author 数据
Author:insert { name = 'John Doe', email = 'john@example.com', age = 30,
  resume = { { start_date = '2015-01-01', end_date = '2020-01-01', company = 'Company A', position = 'Developer', description = 'Worked on various projects.' } } }
    :exec()
Author:insert { name = 'Jane Smith', email = 'jane@example.com', age = 28,
  resume = { { start_date = '2016-01-01', end_date = '2021-01-01', company = 'Company B', position = 'Designer', description = 'Designed user interfaces.' } } }
    :exec()

-- 初始化 Entry 数据
Entry:insert { blog_id = 1, headline = 'First Entry', body_text = 'This is the first entry in my blog.', pub_date = '2023-01-01', mod_date = '2023-01-02', number_of_comments = 5, number_of_pingbacks = 2, rating = 4 }
    :exec()
Entry:insert { blog_id = 2, headline = 'Second Entry', body_text = 'This is the second entry in another blog.', pub_date = '2023-01-03', mod_date = '2023-01-04', number_of_comments = 3, number_of_pingbacks = 1, rating = 5 }
    :exec()
Entry:insert { blog_id = 1, headline = 'Third Entry', body_text = 'This is the third entry in my blog.', pub_date = '2023-01-01', mod_date = '2023-01-02', number_of_comments = 5, number_of_pingbacks = 2, rating = 4 }
    :exec()

-- 初始化 ViewLog 数据
ViewLog:insert { entry_id = 1, ctime = '2023-01-01 10:00:00' }:exec()
ViewLog:insert { entry_id = 2, ctime = '2023-01-03 12:00:00' }:exec()

-- 初始化 Publisher 数据
Publisher:insert { name = 'Publisher A' }:exec()
Publisher:insert { name = 'Publisher B' }:exec()

-- 初始化 Book 数据
Book:insert { name = 'Book One', pages = 300, price = 29.99, rating = 4.5, author = 1, publisher_id = 1, pubdate = '2022-01-01' }
    :exec()
Book:insert { name = 'Book Two', pages = 250, price = 19.99, rating = 4.0, author = 2, publisher_id = 2, pubdate = '2022-02-01' }
    :exec()

-- 初始化 Store 数据
Store:insert { { name = 'Book Store A' }, { name = 'Book Store B' } }:exec()


local function eval(s, ctx)
  md('lua', s)
  local res = { utils.eval(s,
    utils.dict(models, { models = models, Q = Q, F = F, Sum = Sum, Avg = Avg, Max = Max, Min = Min, Count = Count }, ctx)) }
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

local default_tagline = Blog.fields.tagline.default


mdesc("Model:create_model mixins: unique被混合的模型被覆盖", function()
  assert.are.same(BlogBin.fields.name.unique, false)
end)

mdesc("Xodel:select(a:(fun(ctx:table):string|table)|DBValue, b?:DBValue, ...:DBValue)", function()
  mit("select单个字段", function()
    local res = eval [[
      Blog:select('name'):where{id=1}:exec()
    ]]
    assert.are.same(res, { { name = 'My First Blog' } })
  end)

  mit("select多个字段", function()
    local res = eval [[
      Blog:select('name', 'tagline'):where{id=1}:exec()
    ]]
    assert.are.same(res, { { name = 'My First Blog', tagline = 'Welcome to my blog' } })
  end)

  mit("select多个字段,使用table和vararg等效", function()
    local s1 = eval [[
      Blog:select{'name', 'tagline'}:where{id=1}:statement()
    ]]
    local s2 = eval [[
      Blog:select('name', 'tagline'):where{id=1}:statement()
    ]]
    assert.are.same(s1, s2)
  end)

  mit("select literal without alias", function()
    local res = eval [[
      Blog:select_literal('XXX'):select{'name'}:where{id=1}:exec()
    ]]
    assert.are.same(res, { { name = 'My First Blog', ['?column?'] = 'XXX' } })
  end)

  mit("select literal as", function()
    local res = eval [[
      Blog:select_literal_as{['XXX YYY'] = 'blog_name'}:select{'id'}:where{id=1}:exec()
    ]]
    assert.are.same(res, { { blog_name = 'XXX YYY', id = 1 } })
  end)

  mit("select literal as", function()
    local res = eval [[
      Blog:select_literal_as{XXX_YYY = 'blog_name'}:select{'id'}:where{id=2}:exec()
    ]]
    assert.are.same(res, { { blog_name = 'XXX_YYY', id = 2 } })
  end)

  mit("select外键", function()
    local res = eval [[
      Book:select('name', 'author__name'):where{id=1}:exec()
    ]]
    assert.are.same(res, { { name = 'Book One', author__name = 'John Doe' } })
  end)

  mit("select as外键", function()
    local res = eval [[
      Book:select_as{name = 'book_name', author__name = 'author_name'}:where{id=1}:exec()
    ]]
    assert.are.same(res, { { book_name = 'Book One', author_name = 'John Doe' } })
  end)

  mit("select嵌套外键", function()
    local res = eval [[
      ViewLog:select('entry_id__blog_id__name'):where{id=1}:exec()
    ]]
    assert.are.same(res, { { entry_id__blog_id__name = 'My First Blog' } })
  end)

  mit("select as嵌套外键", function()
    local res = eval [[
      ViewLog:select_as{entry_id__blog_id__name = 'blog_name'}:where{id=1}:exec()
    ]]
    assert.are.same(res, { { blog_name = 'My First Blog' } })
  end)

  mit("select reversed foreign key", function()
    local res = eval [[
      Blog:select("id","name","entry__rating"):where{name='Another Blog'}:exec()
    ]]
    assert.are.same(res, { { id = 2, name = 'Another Blog', entry__rating = 5 } })
  end)

  mit("select reversed foreign key with order_by", function()
    local res = eval [[
      Blog:select(
        "id",
        "name",
        "entry__headline"
      ):where{
        name = 'My First Blog'
      }:order_by{'entry__headline'}:exec()
    ]]
    assert.are.same(res, {
      { id = 1, name = 'My First Blog', entry__headline = 'First Entry' },
      { id = 1, name = 'My First Blog', entry__headline = 'Third Entry' } })
  end)

  mit("select reversed foreign key with order_by DESC", function()
    local res = eval [[
      Blog:select(
        "id",
        "name",
        "entry__headline"
      ):where{
        name = 'My First Blog'
      }:order_by{'-entry__headline'}:exec()
    ]]
    assert.are.same(res, {
      { id = 1, name = 'My First Blog', entry__headline = 'Third Entry' },
      { id = 1, name = 'My First Blog', entry__headline = 'First Entry' },
    })
  end)
end)

mdesc("Xodel:where", function()
  mdesc("where basic equal", function()
    local res = eval [[ Book:where { price = 100 } ]]
    assert.are.same(res, "SELECT * FROM book T WHERE T.price = 100")
  end)

  mdesc("where greater than", function()
    local res = eval [[ Book:where { price__gt = 100 } ]]
    assert.are.same(res, "SELECT * FROM book T WHERE T.price > 100")
  end)

  mdesc("where negative condition", function()
    local res = eval [[ Book:where(-Q { price__gt = 100 }) ]]
    assert.are.same(res, "SELECT * FROM book T WHERE NOT (T.price > 100)")
  end)

  mdesc("where combined conditions", function()
    local res = eval [[ Book:where(Q { price__gt = 100 } / Q { price__lt = 200 }) ]]
    assert.are.same(res, "SELECT * FROM book T WHERE (T.price > 100) OR (T.price < 200)")
  end)

  mdesc("where negated combined conditions", function()
    local res = eval [[ Book:where(-(Q { price__gt = 100 } / Q { price__lt = 200 })) ]]
    assert.are.same(res, "SELECT * FROM book T WHERE NOT ((T.price > 100) OR (T.price < 200))")
  end)

  mdesc("where combined with AND", function()
    local res = eval [[ Book:where(Q { id = 1 } * (Q { price__gt = 100 } / Q { price__lt = 200 })) ]]
    assert.are.same(res, "SELECT * FROM book T WHERE (T.id = 1) AND ((T.price > 100) OR (T.price < 200))")
  end)

  mdesc("where blog_id equals", function()
    local res = eval [[ Entry:where { blog_id = 1 } ]]
    assert.are.same(res, "SELECT * FROM entry T WHERE T.blog_id = 1")
  end)

  mdesc("where blog_id reference id", function()
    local res = eval [[ Entry:where { blog_id__id = 1 } ]]
    assert.are.same(res, "SELECT * FROM entry T WHERE T.blog_id = 1")
  end)

  mdesc("where blog_id greater than", function()
    local res = eval [[ Entry:where { blog_id__gt = 1 } ]]
    assert.are.same(res, "SELECT * FROM entry T WHERE T.blog_id > 1")
  end)

  mdesc("where blog_id reference id greater than", function()
    local res = eval [[ Entry:where { blog_id__id__gt = 1 } ]]
    assert.are.same(res, "SELECT * FROM entry T WHERE T.blog_id > 1")
  end)

  mdesc("where blog_id name equals", function()
    local res = eval [[ Entry:where { blog_id__name = 'my blog name' } ]]
    assert.are.same(res, "SELECT * FROM entry T INNER JOIN blog T1 ON (T.blog_id = T1.id) WHERE T1.name = 'my blog name'")
  end)

  mdesc("where blog_id name contains", function()
    local res = eval [[ Entry:where { blog_id__name__contains = 'my blog' } ]]
    assert.are.same(res, "SELECT * FROM entry T INNER JOIN blog T1 ON (T.blog_id = T1.id) WHERE T1.name LIKE '%my blog%'")
  end)

  mdesc("where view log entry_id blog_id equals", function()
    local res = eval [[ ViewLog:where { entry_id__blog_id = 1 } ]]
    assert.are.same(res, "SELECT * FROM view_log T INNER JOIN entry T1 ON (T.entry_id = T1.id) WHERE T1.blog_id = 1")
  end)

  mdesc("where view log entry_id blog_id reference id", function()
    local res = eval [[ ViewLog:where { entry_id__blog_id__id = 1 } ]]
    assert.are.same(res, "SELECT * FROM view_log T INNER JOIN entry T1 ON (T.entry_id = T1.id) WHERE T1.blog_id = 1")
  end)

  mdesc("where view log entry_id blog_id name equals", function()
    local res = eval [[ ViewLog:where { entry_id__blog_id__name = 'my blog name' } ]]
    assert.are.same(res,
      "SELECT * FROM view_log T INNER JOIN entry T1 ON (T.entry_id = T1.id) INNER JOIN blog T2 ON (T1.blog_id = T2.id) WHERE T2.name = 'my blog name'")
  end)

  mdesc("where view log entry_id blog_id name starts with", function()
    local res = eval [[ ViewLog:where { entry_id__blog_id__name__startswith = 'my' } ]]
    assert.are.same(res,
      "SELECT * FROM view_log T INNER JOIN entry T1 ON (T.entry_id = T1.id) INNER JOIN blog T2 ON (T1.blog_id = T2.id) WHERE T2.name LIKE 'my%'")
  end)

  mdesc("where view log entry_id blog_id name starts with and headline equals", function()
    local res = eval [[ ViewLog:where { entry_id__blog_id__name__startswith = 'my' }:where { entry_id__headline = 'aa' } ]]
    assert.are.same(res,
      [[SELECT * FROM view_log T INNER JOIN entry T1 ON (T.entry_id = T1.id) INNER JOIN blog T2 ON (T1.blog_id = T2.id) WHERE (T2.name LIKE 'my%') AND (T1.headline = 'aa')]])
  end)

  mdesc("where blog entry equals", function()
    local s1 = eval [[ Blog:where { entry = 1 } ]]
    local s2 = eval [[ Blog:where { entry__id = 1 } ]]
    assert.are.same(s1, s2)
  end)

  mdesc("where blog entry rating equals", function()
    local res = eval [[ Blog:where { entry__rating = 1 } ]]
    assert.are.same(res, "SELECT * FROM blog T INNER JOIN entry T1 ON (T.id = T1.blog_id) WHERE T1.rating = 1")
  end)

  mdesc("where blog entry view log equals", function()
    local res = eval [[ Blog:where { entry__view_log = 1 } ]]
    assert.are.same(res,
      "SELECT * FROM blog T INNER JOIN entry T1 ON (T.id = T1.blog_id) INNER JOIN view_log T2 ON (T1.id = T2.entry_id) WHERE T2.id = 1")
  end)

  mdesc("where blog entry view log ctime year equals", function()
    local res = eval [[ Blog:where { entry__view_log__ctime__year = 2025 } ]]
    assert.are.same(res,
      "SELECT * FROM blog T INNER JOIN entry T1 ON (T.id = T1.blog_id) INNER JOIN view_log T2 ON (T1.id = T2.entry_id) WHERE T2.ctime BETWEEN '2025-01-01' AND '2025-12-31'")
  end)

  mdesc("where blog entry view log combined conditions", function()
    local res = eval [[ Blog:where(Q { entry__view_log = 1 } / Q { entry__view_log = 2 }) ]]
    assert.are.same(res,
      "SELECT * FROM blog T INNER JOIN entry T1 ON (T.id = T1.blog_id) INNER JOIN view_log T2 ON (T1.id = T2.entry_id) WHERE (T2.id = 1) OR (T2.id = 2)")
  end)

  mdesc("group by book name with total price", function()
    local res = eval [[ Book:group_by { 'name' }:annotate { price_total = Sum('price') } ]]
    assert.are.same(res, "SELECT T.name, SUM(T.price) AS price_total FROM book T GROUP BY T.name")
  end)

  mdesc("annotate book with total price", function()
    local res = eval [[ Book:annotate { price_total = Sum('price') } ]]
    assert.are.same(res, "SELECT SUM(T.price) AS price_total FROM book T")
  end)

  mdesc("annotate book with sum price", function()
    local res = eval [[ Book:annotate { Sum('price') } ]]
    assert.are.same(res, "SELECT SUM(T.price) AS price_sum FROM book T")
  end)

  mdesc("group by book name with sum price", function()
    local res = eval [[ Book:group_by { 'name' }:annotate { Sum('price') } ]]
    assert.are.same(res, "SELECT T.name, SUM(T.price) AS price_sum FROM book T GROUP BY T.name")
  end)

  mdesc("group by book name with having condition", function()
    local res = eval [[ Book:group_by { 'name' }:annotate { Sum('price') }:having { price_sum__gt = 100 } ]]
    assert.are.same(res, "SELECT T.name, SUM(T.price) AS price_sum FROM book T GROUP BY T.name HAVING SUM(T.price) > 100")
  end)

  mdesc("group by book name with having total price condition", function()
    local res = eval [[ Book:group_by { 'name' }:annotate { price_total = Sum('price') }:having { price_total__gt = 100 } ]]
    assert.are.same(res,
      "SELECT T.name, SUM(T.price) AS price_total FROM book T GROUP BY T.name HAVING SUM(T.price) > 100")
  end)

  mdesc("group by book name with having total price condition and order by", function()
    local res = eval [[ Book:group_by { 'name' }:annotate { price_total = Sum('price') }:having { price_total__gt = 100 }:order_by { '-price_total' } ]]
    assert.are.same(res,
      "SELECT T.name, SUM(T.price) AS price_total FROM book T GROUP BY T.name HAVING SUM(T.price) > 100 ORDER BY SUM(T.price) DESC")
  end)

  mdesc("annotate book with double price", function()
    local res = eval [[ Book:annotate { double_price = F('price') * 2 } ]]
    assert.are.same(res, "SELECT (T.price * 2) AS double_price FROM book T")
  end)

  mdesc("annotate book with price per page", function()
    local res = eval [[ Book:annotate { price_per_page = F('price') / F('pages') } ]]
    assert.are.same(res, "SELECT (T.price / T.pages) AS price_per_page FROM book T")
  end)

  mdesc("annotate blog with entry count", function()
    local res = eval [[ Blog:annotate { entry_count = Count('entry') } ]]
    assert.are.same(res, "SELECT COUNT(T1.id) AS entry_count FROM blog T LEFT JOIN entry T1 ON (T.id = T1.blog_id)")
  end)

  mdesc("where author resume has key", function()
    local res = eval [[ Author:where { resume__has_key = 'start_date' } ]]
    assert.are.same(res, "SELECT * FROM author T WHERE (T.resume) ? start_date")
  end)

  mdesc("where author resume has keys", function()
    local res = eval [[ Author:where { resume__0__has_keys = { 'a', 'b' } } ]]
    assert.are.same(res, "SELECT * FROM author T WHERE (T.resume #> ['0']) ?& ['a', 'b']")
  end)

  mdesc("where author resume has any keys", function()
    local res = eval [[ Author:where { resume__has_any_keys = { 'a', 'b' } } ]]
    assert.are.same(res, "SELECT * FROM author T WHERE (T.resume) ?| ['a', 'b']")
  end)

  mdesc("where author resume start date time equals", function()
    local res = eval [[ Author:where { resume__start_date__time = '12:00:00' } ]]
    assert.are.same(res, [[SELECT * FROM author T WHERE (T.resume #> ['start_date', 'time']) = '"12:00:00"']])
  end)

  mdesc("where author resume contains", function()
    local res = eval [[ Author:where { resume__contains = { start_date = '2025-01-01' } } ]]
    assert.are.same(res, [[SELECT * FROM author T WHERE (T.resume) @> '{"start_date":"2025-01-01"}']])
  end)

  mdesc("where author resume contained by", function()
    local res = eval [[ Author:where { resume__contained_by = { start_date = '2025-01-01' } } ]]
    assert.are.same(res, [[SELECT * FROM author T WHERE (T.resume) <@ '{"start_date":"2025-01-01"}']])
  end)

  mdesc("where view log entry_id equals", function()
    local res = eval [[ ViewLog:where('entry_id__blog_id', 1) ]]
    assert.are.same(res, "SELECT * FROM view_log T INNER JOIN entry T1 ON (T.entry_id = T1.id) WHERE T1.blog_id = 1")
  end)

  mdesc("where view log entry_id greater than", function()
    local res = eval [[ ViewLog:where { entry_id__blog_id__gt = 1 } ]]
    assert.are.same(res, "SELECT * FROM view_log T INNER JOIN entry T1 ON (T.entry_id = T1.id) WHERE T1.blog_id > 1")
  end)
end)

mdesc("Xodel:insert(rows:table|table[]|Sql, columns?:string[])", function()
  mit("插入单行数据", function()
    local res = eval [[
      Blog:insert{
        name = 'insert one row',
        tagline = 'insert one row'
      }:exec()
    ]]
    assert.are.same(res, { affected_rows = 1 })
    Blog:delete { name = 'insert one row' }:exec()
  end)

  mit("插入单行数据并返回特定字段", function()
    local res = eval [[
      Blog:insert{
        name = 'Return Test Blog',
        tagline = 'Return test tagline'
      }:returning{'id', 'name'}:exec()
    ]]
    assert.are.same(type(res[1].id), 'number')
    assert.are.same(res[1].name, 'Return Test Blog')
    Blog:delete { id = res[1].id }:exec()
  end)

  mit("returning使用vararg和table等效", function()
    local s1 = eval [[
      Blog:insert{
        name = 'Return Test Blog',
        tagline = 'Return test tagline'
      }:returning{'id', 'name'}:statement()
    ]]
    local s2 = eval [[
      Blog:insert{
        name = 'Return Test Blog',
        tagline = 'Return test tagline'
      }:returning('id', 'name'):statement()
    ]]
    assert.are.same(s1, s2)
  end)

  mit("批量插入多行数据", function()
    local res = eval [[
      Blog:insert{
        { name = 'bulk insert 1', tagline = 'bulk insert 1' },
        { name = 'bulk insert 2', tagline = 'bulk insert 2' }
      }:exec()
    ]]
    assert.are.same(res, { affected_rows = 2 })
    local deleted = Blog:delete { name__startswith = 'bulk insert' }:exec()
    assert.are.same(deleted, { affected_rows = 2 })
  end)

  mit("批量插入并返回所有字段", function()
    local res = eval [[
      Blog:insert{
        { name = 'bulk insert return 1', tagline = 'bulk insert return 1' },
        { name = 'bulk insert return 2', tagline = 'bulk insert return 2' }
      }:returning('*'):exec()
    ]]
    assert.are.same(#res, 2)
    assert.are.same(res[1].name, 'bulk insert return 1')
    assert.are.same(res[2].name, 'bulk insert return 2')
    local deleted = Blog:delete { name__startswith = 'bulk insert return' }:exec()
    assert.are.same(deleted, { affected_rows = 2 })
  end)

  mit("从子查询select插入数据", function()
    local res = eval [[
      BlogBin:insert(Blog:where{name='Another Blog'}:select{'name', 'tagline'}):exec()
    ]]
    assert.are.same(res, { affected_rows = 1 })
  end)

  mit("检验上面插入的数据", function()
    local res = eval [[
      BlogBin:where{name='Another Blog'}:select{'tagline'}:get()
    ]]
    assert.are.same(res, { tagline = 'Another interesting blog' })
  end)

  mit("从子查询select_literal插入数据", function()
    local res = eval [[
      BlogBin:insert(
        Blog:where{ name = 'My First Blog'}
        :select{'name', 'tagline'}
        :select_literal('select from another blog'),
        {'name', 'tagline', 'note'}
      ):exec()
    ]]
    assert.are.same(res, { affected_rows = 1 })
  end)

  mit("检验上面插入的数据select_literal", function()
    local res = eval [[
      BlogBin:where{name='My First Blog'}:select{'note'}:get()
    ]]
    assert.are.same(res, { note = 'select from another blog' })
  end)

  mit("从子查询update+returning插入数据", function()
    Blog:insert { name = 'Update Returning' }:exec()
    local res = eval [[
      BlogBin:insert(
        Blog:update{
          name = 'Update Returning 2'
        }:where{
          name = 'Update Returning'
        }:returning{
        'name', 'tagline'
        }:returning_literal('update from another blog'),
        {'name', 'tagline', 'note'}
      ):returning{'name', 'tagline', 'note'}:exec()
    ]]
    local inserted = BlogBin:where { name = 'Update Returning 2' }:select { 'name', 'tagline', 'note' }:exec()
    assert.are.same(inserted,
      { { name = 'Update Returning 2', tagline = 'default tagline', note = 'update from another blog' } })
    local deleted = Blog:delete { name = 'Update Returning 2' }:exec()
    assert.are.same(deleted, { affected_rows = 1 })
  end)

  mit("从子查询delete+returning插入数据", function()
    Blog:insert { name = 'delete returning', tagline = 'delete returning tagline' }:exec()
    local res = eval [[
      BlogBin:insert(
        Blog:delete{
          name = 'delete returning'
        }:returning{
          'name', 'tagline'
        }:returning_literal('deleted from another blog'),
        {'name', 'tagline', 'note'}
      ):returning{'name', 'tagline', 'note'}:exec()
    ]]
    assert.are.same(res,
      { { name = 'delete returning', tagline = 'delete returning tagline', note = 'deleted from another blog' } })
    local deleted = Blog:delete { name = 'delete returning' }:exec()
    assert.are.same(deleted, { affected_rows = 0 }) -- already deleted
  end)

  mit("从子查询delete+returning插入数据,未明确指定列", function()
    Blog:insert { name = 'delete returning', tagline = 'no column' }:exec()
    local res = eval [[
      BlogBin:insert(Blog:delete{name='delete returning'}:returning{'name', 'tagline'}):returning{'name', 'tagline', 'note'}:exec()
    ]]
    assert.are.same(res,
      { { name = 'delete returning', tagline = 'no column', note = '' } })
    local deleted = Blog:delete { name = 'delete returning' }:exec()
    assert.are.same(deleted, { affected_rows = 0 }) -- already deleted
  end)

  mit("指定列名插入数据", function()
    local res = eval [[
      BlogBin:insert({
        name = 'Column Test Blog',
        tagline = 'Column test tagline',
        note = 'should not be inserted'
      }, {'name', 'tagline'}):returning('name', 'tagline','note'):exec()
    ]]
    assert.are.same(res, { { name = 'Column Test Blog', tagline = 'Column test tagline', note = '' } })
    local deleted = BlogBin:delete { name = 'Column Test Blog' }:exec()
    assert.are.same(deleted, { affected_rows = 1 })
  end)

  mit("插入数据并使用默认值", function()
    local res = eval [[
      Blog:insert{name = 'Default Test Blog'}:returning{'name', 'tagline'}:exec()
    ]]
    assert.are.same(res[1].tagline, default_tagline)
    assert.are.same(res[1].name, 'Default Test Blog')
    local deleted = Blog:delete { name = 'Default Test Blog' }:exec()
    assert.are.same(deleted, { affected_rows = 1 })
  end)
end)

mdesc("Xodel:insert抛出异常的情况", function()
  mit("唯一性错误", function()
    assert.error(function()
      eval [[ Blog:insert{name='My First Blog'}:exec() ]]
    end)
  end)
  mit("传入非法字段", function()
    assert.error(function()
      eval [[
        Blog:insert{
          illegal_field = 'Test Blog',
          tagline = 'Test tagline'
        }:exec()
      ]]
    end, "invalid field name 'illegal_field' for model 'blog'")
  end)

  mit("传入名称过长", function()
    assert.error(function()
      eval [[
        Blog:insert{
          name = 'This name is way too long and exceeds the maximum length',
          tagline = 'Test tagline'
        }:exec()
      ]]
    end, {
      label = 'name',
      message = '字数不能多于20个',
      name = 'name',
      type = 'field_error'
    })
  end)

  mit("插入多行时其中某行名称过长", function()
    assert.error(function()
      eval [[
        Blog:insert{
          { name = 'Valid Blog', tagline = 'Valid tagline' },
          { name = 'This name is way too long and exceeds the maximum length', tagline = 'Another tagline' }
        }:exec()
      ]]
    end, {
      batch_index = 2,
      label = 'name',
      message = '字数不能多于20个',
      name = 'name',
      type = 'field_error',
    })
  end)

  mit("插入复合字段出错(Author的resume字段)", function()
    assert.error(function()
      eval [[
        Author:insert{resume={{company='123456789012345678901234567890'}}}:exec()
      ]]
    end, {
      index = 1,
      name = 'resume',
      message = {
        label = 'company',
        message = '字数不能多于20个',
        name = 'company',
        type = 'field_error'
      },
      type = 'field_error',
      label = 'resume'
    })
  end)

  mit("插入多行复合字段出错(Author的resume字段)", function()
    assert.error(function()
      eval [[
        Author:insert{{resume={{company='123456789012345678901234567890'}}}}:exec()
      ]]
    end, {
      batch_index = 1,
      index = 1,
      name = 'resume',
      message = {
        label = 'company',
        message = '字数不能多于20个',
        name = 'company',
        type = 'field_error'
      },
      type = 'field_error',
      label = 'resume'
    })
  end)

  mit("从子查询插入数据列数不一致而出错1", function()
    assert.Error(function()
      eval [[
        BlogBin:insert(Blog:where{name='My First Blog'}:select{'name', 'tagline'},{'name'}):exec()
      ]]
    end, "ERROR: INSERT has more expressions than target columns (49)")
  end)

  mit("从子查询插入数据列数不一致而出错2", function()
    assert.Error(function()
      eval [[
        BlogBin:insert(Blog:where{name='My First Blog'}:select{'name', 'tagline'},{'name', 'tagline', 'note'}):exec()
      ]]
    end, "ERROR: INSERT has more target columns than expressions (43)")
  end)
end)

mdesc("Xodel:update", function()
  mdesc("update basic", function()
    local res = eval [[ Blog:where{name='My First Blog'}:update{tagline='changed tagline'}:returning('*'):exec() ]]
    assert.are.same(res, { { name = 'My First Blog', tagline = 'changed tagline', id = 1 } })
  end)

  mdesc("update with join", function()
    local res = eval [[ Entry:update { headline = F('blog_id__name') }:where{id=1}:returning('headline'):exec() ]]
    local entry = Entry:where { id = 1 }:select { 'headline' }:get()
    assert.are.same(res, { entry })
  end)

  mdesc("update with function", function()
    local res = eval [[ Entry:update { headline = F('headline')..' suffix by function' }:where{id=1}:returning('headline'):exec() ]]
    local entry = Entry:where { id = 1 }:select { 'headline' }:get()
    assert.are.same(entry.headline, 'My First Blog suffix by function')
  end)

  mdesc("increase", function()
    local entry = Entry:where { id = 1 }:select { 'rating' }:get()
    local res = eval [[ Entry:increase { rating = 1 }:where{id=1}:returning('rating'):exec() ]]
    assert.are.same(res[1].rating, entry.rating + 1)
  end)

  mdesc("increase two fields", function()
    local entry = Entry:where { id = 1 }:get()
    local res = eval [[ Entry:increase { number_of_comments = 1, number_of_pingbacks=2 }:where{id=1}:returning('*'):exec() ]]
    assert.are.same(res[1].number_of_comments, entry.number_of_comments + 1)
    assert.are.same(res[1].number_of_pingbacks, entry.number_of_pingbacks + 2)
  end)

  mdesc("increase string args", function()
    local entry = Entry:where { id = 1 }:select { 'rating' }:get()
    local res = eval [[ Entry:increase('rating', 2):where{id=1}:returning('rating'):exec() ]]
    assert.are.same(res[1].rating, entry.rating + 2)
  end)

  mdesc("update with where join", function()
    local res = eval [[ Entry:update { headline = F('headline')..' from first blog' }:where{blog_id__name='My First Blog'}:returning('id','headline'):exec() ]]
    assert.are.same(res, Entry:where { headline__endswith = ' from first blog' }:select { 'id', 'headline' }:exec())
  end)
end)

mdesc("Xodel:merge", function()
  mdesc("merge basic", function()
    local res = eval [[
    Blog:merge {
      { name = 'My First Blog', tagline = 'updated by merge' },
      { name = 'Blog added by merge', tagline = 'inserted by merge' },
    }:exec() ]]
    assert.are.same(res, { affected_rows = 1 })
    local updated = Blog:where { name = 'My First Blog' }:select { 'tagline' }:get()
    assert.are.same(updated.tagline, 'updated by merge')
    local deleted = Blog:delete { name = 'Blog added by merge' }:exec()
    assert.are.same(deleted, { affected_rows = 1 })
  end)

  mdesc("merge insert only", function()
    local origin = Blog:where { name = 'My First Blog' }:get()
    local res = eval [[ Blog:merge { { name = 'My First Blog' }, { name = 'Blog added by merge' } }:exec() ]]
    assert.are.same(res, { affected_rows = 1 })
    local updated = Blog:where { name = 'My First Blog' }:get()
    assert.are.same(updated, origin)
    local inserted = Blog:where { name = 'Blog added by merge' }:select { 'name', 'tagline' }:get()
    assert.are.same(inserted, { name = 'Blog added by merge', tagline = 'default tagline' })
    local deleted = Blog:delete { name = 'Blog added by merge' }:exec()
    assert.are.same(deleted, { affected_rows = 1 })
  end)

  mdesc("merge抛出异常的情况", function()
    assert.error(function()
      eval [[ Author:merge { { name = 'Tom', age = 11 }, { name = 'Jerry', age = 101 } }:exec() ]]
    end, {
      batch_index = 2,
      message = '值不能大于100',
      name = 'age',
      label = 'age',
      type = 'field_error'
    })
  end)

  mdesc("Xodel:upsert", function()
    mit("upsert basic", function()
      local res = eval [[
      Blog:upsert {
        { name = 'My First Blog', tagline = 'updated by upsert' },
        { name = 'Blog added by upsert', tagline = 'inserted by upsert' },
      }:exec()
      ]]
      assert.are.same(res, { affected_rows = 2 })
      local updated = Blog:where { name = 'My First Blog' }:select { 'tagline' }:get()
      assert.are.same(updated.tagline, 'updated by upsert')
      local inserted = Blog:where { name = 'Blog added by upsert' }:select { 'name', 'tagline' }:get()
      assert.are.same(inserted, { name = 'Blog added by upsert', tagline = 'inserted by upsert' })
      local deleted = Blog:delete { name = 'Blog added by upsert' }:exec()
      assert.are.same(deleted, { affected_rows = 1 })
    end)
    mit("upsert from sub query", function()
      local res = eval [[
        Blog:upsert(BlogBin:where{name='My First Blog'}:select{'name', 'tagline'}):exec()
      ]]
      assert.are.same(res, { affected_rows = 2 })
    end)
  end)
end)
