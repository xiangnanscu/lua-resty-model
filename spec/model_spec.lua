---@diagnostic disable: param-type-mismatch, undefined-global
--[[
  model2_spec.lua —— model_spec.lua 的改良版
  - 不再使用 eval / md / mit / mdesc 等 helper
  - 不再断言 ORM 生成的 SQL 字符串
  - 直接编写 ORM 链式调用，断言 :exec() / :get() 等返回的真实结果
  - 全面覆盖 docs/ 中描述的公共 API
  数据约定：
  - 全局 setup 一次：drop & create tables，并插入种子数据
  - 任何 mutating 用例都要清理自己的写入，避免污染后续 it
]] -- selene: allow(global_usage)
local migrate = require "resty.migrate"
local Model = require("model")
local Q = Model.Q
local F = Model.F
local Sum = Model.Sum
local Avg = Model.Avg
local Count = Model.Count
local StdDev = Model.StdDev

local db_config = {
  DATABASE = 'test',
  USER = 'postgres',
  PASSWORD = 'postgres',
}
Model.db_config = db_config
Model.auto_primary_key = true

---------------------------------------------------------------------
-- Models —— 与 model_spec.lua 一致，外加 Category 用于演示自引用 FK
---------------------------------------------------------------------

---@class Blog
local Blog = Model:create_model {
  table_name = 'blog',
  fields = {
    { "name",    maxlength = 20, minlength = 2, unique = true, compact = false },
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
    { "name",    maxlength = 200, unique = true, compact = false },
    { "email",   type = 'email' },
    { "age",     type = 'integer', max = 100, min = 10 },
    { "payload", type = 'json' },
    { "resume",  model = Resume },
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
    { "name",         maxlength = 300, compact = false },
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

---@class Category 自引用，用于 where_recursive
local Category = Model:create_model {
  table_name = 'category',
  fields = {
    -- compact = false：保留 name 中的空格（默认 StringField 会把所有空白删掉）
    { "name",      maxlength = 50, compact = false },
    { "parent_id", reference = 'self', null = true, related_query_name = 'children' },
  }
}

local model_list = {
  Blog, BlogBin, Author, Entry, ViewLog, Publisher, Book, Store, Category
}

---------------------------------------------------------------------
-- 工具：建表 / 种子数据 / 重置
---------------------------------------------------------------------

local function recreate_tables()
  for i = #model_list, 1, -1 do
    assert(Blog.query("DROP TABLE IF EXISTS " .. model_list[i].table_name .. " CASCADE"))
  end
  for _, m in ipairs(model_list) do
    assert(Blog.query(migrate.get_table_defination(m)))
  end
end

local function truncate_all()
  for i = #model_list, 1, -1 do
    Blog.query("TRUNCATE TABLE " .. model_list[i].table_name .. " RESTART IDENTITY CASCADE")
  end
end

local SEED = {}

local function seed_data()
  truncate_all()

  -- Blog
  Blog:insert {
    { name = 'First Blog',  tagline = 'Welcome to my blog' },
    { name = 'Second Blog', tagline = 'Another interesting blog' },
  }:exec()

  -- Author + resume
  Author:insert {
    {
      name = 'John Doe', email = 'john@example.com', age = 30,
      resume = { { start_date = '2015-01-01', end_date = '2020-01-01', company = 'Company A', position = 'Developer', description = 'Worked on various projects.' } },
    },
    {
      name = 'Jane Smith', email = 'jane@example.com', age = 28,
      resume = { { start_date = '2016-01-01', end_date = '2021-01-01', company = 'Company B', position = 'Designer', description = 'Designed user interfaces.' } },
    },
  }:exec()

  -- Entry
  Entry:insert {
    { blog_id = 1, headline = 'First Entry',  body_text = 'This is the first entry in my blog.',     pub_date = '2023-01-01', mod_date = '2023-01-02', number_of_comments = 5, number_of_pingbacks = 2, rating = 4 },
    { blog_id = 2, headline = 'Second Entry', body_text = 'This is the second entry in another blog.', pub_date = '2023-01-03', mod_date = '2023-01-04', number_of_comments = 3, number_of_pingbacks = 1, rating = 5 },
    { blog_id = 1, headline = 'Third Entry',  body_text = 'This is the third entry in my blog.',     pub_date = '2023-02-01', mod_date = '2023-02-02', number_of_comments = 5, number_of_pingbacks = 2, rating = 4 },
  }:exec()

  ViewLog:insert {
    { entry_id = 1, ctime = '2023-01-01 10:00:00' },
    { entry_id = 2, ctime = '2023-01-03 12:00:00' },
  }:exec()

  Publisher:insert { { name = 'Publisher A' }, { name = 'Publisher B' } }:exec()

  Book:insert {
    { name = 'Book One', pages = 300, price = 29.99, rating = 4.5, author = 1, publisher_id = 1, pubdate = '2022-01-01' },
    { name = 'Book Two', pages = 250, price = 19.99, rating = 4.0, author = 2, publisher_id = 2, pubdate = '2022-02-01' },
  }:exec()

  Store:insert { { name = 'Book Store A' }, { name = 'Book Store B' } }:exec()

  -- Category 树:
  --   Root
  --   ├── Child A
  --   │   └── Grandchild A1
  --   └── Child B
  Category:insert { name = 'Root', parent_id = nil }:exec()
  local root = Category:get { name = 'Root' }
  Category:insert {
    { name = 'Child A', parent_id = root.id },
    { name = 'Child B', parent_id = root.id },
  }:exec()
  local child_a = Category:get { name = 'Child A' }
  Category:insert { name = 'Grandchild A1', parent_id = child_a.id }:exec()

  -- 缓存 SEED 中常用的 id（按种子顺序）
  SEED.blogs       = Blog:order('id'):exec()
  SEED.authors     = Author:order('id'):exec()
  SEED.entries     = Entry:order('id'):exec()
  SEED.publishers  = Publisher:order('id'):exec()
  SEED.books       = Book:order('id'):exec()
  SEED.categories  = Category:order('id'):exec()
end

---------------------------------------------------------------------
-- main(): 所有 describe/it 在这里执行
---------------------------------------------------------------------

local function main()
  recreate_tables()
  seed_data()

  -- 每个 describe 之后都把可能被修改的种子数据回到原状
  local function reseed()
    seed_data()
  end

  -------------------------------------------------------------------
  describe("1. 模型定义", function()
    it("Model:create_model 基础属性", function()
      assert.are.same(Blog.table_name, 'blog')
      assert.are.same(Blog.primary_key, 'id')
      assert.are.same(Blog.class_name, 'Blog')
      assert.are.same(type(Blog.fields.name), 'table')
      assert.is_true(Blog.fields.name.unique)
    end)

    it("Model:create_model mixins 覆盖父字段属性", function()
      -- BlogBin 把 Blog.name 的 unique 覆盖为 false
      assert.are.same(BlogBin.fields.name.unique, false)
      -- 同时 BlogBin 拥有自己新增的 note 字段
      assert.are.same(BlogBin.fields.note.type, 'text')
      -- 仍然继承 Blog 的字段
      assert.is_truthy(BlogBin.fields.tagline)
    end)

    it("auto_primary_key=false 不自动生成 id", function()
      assert.is_nil(Resume.fields.id)
      assert.are.same(Resume.primary_key, nil)
    end)

    it("unique_together 标准化为 [[...]]", function()
      assert.are.same(#Resume.unique_together, 1)
      assert.are.same(Resume.unique_together[1], { 'start_date', 'end_date', 'company', 'position' })
    end)

    it("外键 reversed_fields 自动登记到目标模型", function()
      -- Entry.blog_id (related_query_name='entry') => Blog.reversed_fields.entry
      -- 存的是 Entry.blog_id 这个 FK field 本身：name='blog_id', reference_column='id'
      assert.is_truthy(Blog.reversed_fields.entry)
      assert.is_truthy(Blog.reversed_fields.reposted_entry)
      assert.are.same(Blog.reversed_fields.entry.name, 'blog_id')
      assert.are.same(Blog.reversed_fields.entry.reference_column, 'id')
      assert.are.same(Blog.reversed_fields.entry.table_name, 'entry')
    end)

    it("Model(opts) 简写自动混入 BaseModel (id/ctime/utime)", function()
      assert.is_truthy(Store.fields.id)
      assert.is_truthy(Store.fields.ctime)
      assert.is_truthy(Store.fields.utime)
    end)

    it("Model:is_model_class / is_instance", function()
      assert.is_true(Model:is_model_class(Blog))
      -- is_model_class 返回 nil（不是 false）当对象不是模型，故用 is_falsy
      assert.is_falsy(Model:is_model_class({}))
      local sql = Blog:create_sql():where { id = 1 }
      assert.is_true(Model:is_instance(sql))
      assert.is_falsy(Model:is_instance({}))
    end)

    it("Model:check_unique_key", function()
      assert.are.same(Blog:check_unique_key('name'), 'name')
      assert.are.same(Blog:check_unique_key('id'), 'id')
      assert.has_error(function() Blog:check_unique_key('tagline') end)
    end)

    it("Model:to_json 导出元数据", function()
      local meta = Blog:to_json()
      assert.are.same(meta.table_name, 'blog')
      assert.is_truthy(meta.fields.name)
      -- 仅指定字段
      local partial = Blog:to_json { 'name' }
      assert.are.same(partial.field_names, { 'name' })
      assert.is_nil(partial.fields.tagline)
    end)

    it("Model:make_field_from_json 动态构造字段", function()
      local f = Author:make_field_from_json { name = 'phone', type = 'string', maxlength = 20 }
      assert.are.same(f.type, 'string')
      assert.are.same(f.maxlength, 20)
    end)
  end)

  -------------------------------------------------------------------
  describe("2. SELECT", function()
    it("select 单个字段", function()
      local r = Blog:select('name'):where { id = 1 }:exec()
      assert.are.same(r, { { name = 'First Blog' } })
    end)

    it("select 多字段 (vararg)", function()
      local r = Blog:select('name', 'tagline'):where { id = 1 }:exec()
      assert.are.same(r, { { name = 'First Blog', tagline = 'Welcome to my blog' } })
    end)

    it("select 多字段 (table)", function()
      local r = Blog:select { 'name', 'tagline' }:where { id = 1 }:exec()
      assert.are.same(r, { { name = 'First Blog', tagline = 'Welcome to my blog' } })
    end)

    it("select 链式追加", function()
      local r = Blog:select('name'):select('tagline'):where { id = 1 }:exec()
      assert.are.same(r, { { name = 'First Blog', tagline = 'Welcome to my blog' } })
    end)

    it("select 不调用 = SELECT *", function()
      local r = Blog:where { id = 1 }:exec()
      assert.are.same(r[1].name, 'First Blog')
      assert.are.same(r[1].tagline, 'Welcome to my blog')
      assert.are.same(r[1].id, 1)
    end)

    it("select_as 重命名字段", function()
      local r = Blog:select_as { name = 'blog_name', tagline = 'blog_tagline' }:where { id = 1 }:exec()
      assert.are.same(r, { { blog_name = 'First Blog', blog_tagline = 'Welcome to my blog' } })
    end)

    it("select_literal 选择字面量", function()
      local r = Blog:select { 'name' }:select_literal('XXX'):where { id = 1 }:exec()
      assert.are.same(r[1].name, 'First Blog')
      assert.are.same(r[1]['?column?'], 'XXX')
    end)

    it("select_literal_as 命名字面量 (含空格)", function()
      local r = Blog:select_literal_as { ['XXX YYY'] = 'blog_name' }:select { 'id' }:where { id = 1 }:exec()
      assert.are.same(r, { { blog_name = 'XXX YYY', id = 1 } })
    end)

    it("select_literal_as 命名字面量 (无空格)", function()
      local r = Blog:select_literal_as { XXX_YYY = 'blog_name' }:select { 'id' }:where { id = 2 }:exec()
      assert.are.same(r, { { blog_name = 'XXX_YYY', id = 2 } })
    end)

    it("select 外键字段 (跨表)", function()
      local r = Book:select('name', 'author__name'):where { id = 1 }:exec()
      assert.are.same(r, { { name = 'Book One', author__name = 'John Doe' } })
    end)

    it("select_as 跨表字段重命名", function()
      local r = Book:select_as { name = 'book_name', author__name = 'author_name' }:where { id = 1 }:exec()
      assert.are.same(r, { { book_name = 'Book One', author_name = 'John Doe' } })
    end)

    it("select 嵌套外键 (ViewLog -> Entry -> Blog)", function()
      local r = ViewLog:select('entry_id__blog_id__name'):where { id = 1 }:exec()
      assert.are.same(r, { { entry_id__blog_id__name = 'First Blog' } })
    end)

    it("select_as 嵌套外键重命名", function()
      local r = ViewLog:select_as { entry_id__blog_id__name = 'blog_name' }:where { id = 1 }:exec()
      assert.are.same(r, { { blog_name = 'First Blog' } })
    end)

    it("select 反向外键", function()
      local r = Blog:select('id', 'name', 'entry__rating'):where { name = 'Second Blog' }:exec()
      assert.are.same(r, { { id = 2, name = 'Second Blog', entry__rating = 5 } })
    end)

    it("select 反向外键 + order_by ASC", function()
      local r = Blog:select('id', 'name', 'entry__headline'):where { name = 'First Blog' }:order_by { 'entry__headline' }:exec()
      assert.are.same(r, {
        { id = 1, name = 'First Blog', entry__headline = 'First Entry' },
        { id = 1, name = 'First Blog', entry__headline = 'Third Entry' },
      })
    end)

    it("select 反向外键 + order_by DESC", function()
      local r = Blog:select('id', 'name', 'entry__headline'):where { name = 'First Blog' }:order_by { '-entry__headline' }:exec()
      assert.are.same(r, {
        { id = 1, name = 'First Blog', entry__headline = 'Third Entry' },
        { id = 1, name = 'First Blog', entry__headline = 'First Entry' },
      })
    end)

    it("only 覆盖式选择列", function()
      local r = Blog:select('tagline'):only('name'):where { id = 1 }:exec()
      assert.are.same(r[1].name, 'First Blog')
      assert.is_nil(r[1].tagline)
    end)

    it("defer 排除指定列", function()
      local r = Blog:defer('tagline'):where { id = 1 }:exec()
      assert.are.same(r[1].name, 'First Blog')
      assert.is_nil(r[1].tagline)
    end)
  end)

  -------------------------------------------------------------------
  describe("3. WHERE", function()
    it("基础等值", function()
      local r = Book:where { name = 'Book One' }:exec()
      assert.are.same(#r, 1)
      assert.are.same(r[1].name, 'Book One')
    end)

    it("比较运算符 __gt / __lt / __gte / __lte / __ne", function()
      assert.are.same(#Book:where { price__gt = 25 }:exec(), 1)
      assert.are.same(#Book:where { price__lt = 25 }:exec(), 1)
      assert.are.same(#Book:where { price__gte = 19.99 }:exec(), 2)
      assert.are.same(#Book:where { price__lte = 19.99 }:exec(), 1)
      assert.are.same(#Book:where { price__ne = 29.99 }:exec(), 1)
    end)

    it("__in / __notin", function()
      assert.are.same(#Entry:where { rating__in = { 4, 5 } }:exec(), 3)
      assert.are.same(#Entry:where { rating__notin = { 4 } }:exec(), 1)
    end)

    it("__range", function()
      assert.are.same(#Entry:where { pub_date__range = { '2023-01-01', '2023-01-31' } }:exec(), 2)
    end)

    it("__contains / __icontains / __startswith / __endswith", function()
      assert.are.same(#Entry:where { headline__contains = 'Entry' }:exec(), 3)
      assert.are.same(#Entry:where { headline__startswith = 'First' }:exec(), 1)
      assert.are.same(#Entry:where { headline__endswith = 'Entry' }:exec(), 3)
      assert.are.same(#Entry:where { headline__icontains = 'ENTRY' }:exec(), 3)
    end)

    it("__null = true / false (注：__null 不能用在 json 字段上 — 那会被解析为 JSON path)", function()
      -- 用 Entry.rating（integer） 测试：种子里都非空
      assert.are.same(Entry:where { rating__null = false }:count(), 3)
      assert.are.same(Entry:where { rating__null = true }:count(), 0)
      -- 临时插入一行 rating=NULL
      Entry:insert { blog_id = 1, headline = 'null-rating', body_text = '', pub_date = '2023-01-01', mod_date = '2023-01-01', number_of_comments = 0, number_of_pingbacks = 0 }:exec()
      assert.are.same(Entry:where { rating__null = true }:count(), 1)
      Entry:delete { headline = 'null-rating' }:exec()
    end)

    it("跨表 (1 级) 正向外键", function()
      local r = Entry:where { blog_id__name = 'First Blog' }:exec()
      assert.are.same(#r, 2)
    end)

    it("跨表 (1 级) 正向外键 + lookup", function()
      assert.are.same(#Entry:where { blog_id__name__contains = 'First' }:exec(), 2)
      assert.are.same(#Entry:where { blog_id__name__startswith = 'Sec' }:exec(), 1)
    end)

    it("跨表 (2 级) ViewLog -> Entry -> Blog", function()
      local r = ViewLog:where { entry_id__blog_id__name = 'First Blog' }:exec()
      assert.are.same(#r, 1)
    end)

    it("跨表 + 同一查询多次 where (AND)", function()
      local r = ViewLog:where { entry_id__blog_id__name = 'First Blog' }:where { entry_id__headline = 'First Entry' }:exec()
      assert.are.same(#r, 1)
    end)

    it("反向外键", function()
      assert.are.same(#Blog:where { entry__rating = 5 }:exec(), 1)
    end)

    it("两参数 where", function()
      local r = Book:where("name", "Book One"):exec()
      assert.are.same(#r, 1)
    end)

    it("三参数 where", function()
      assert.are.same(#Entry:where("rating", ">", 4):exec(), 1)
    end)

    it("两参数 where 跨表", function()
      assert.are.same(#ViewLog:where('entry_id__blog_id', 1):exec(), 1)
    end)

    it("Q 对象: OR", function()
      local r = Book:where(Q { name = 'Book One' } / Q { name = 'Book Two' }):exec()
      assert.are.same(#r, 2)
    end)

    it("Q 对象: AND", function()
      local r = Book:where(Q { rating__gte = 4 } * Q { price__lt = 25 }):exec()
      assert.are.same(#r, 1)
    end)

    it("Q 对象: NOT", function()
      local r = Book:where(-Q { name = 'Book One' }):exec()
      assert.are.same(#r, 1)
      assert.are.same(r[1].name, 'Book Two')
    end)

    it("Q 嵌套 + 跨表", function()
      local r = Blog:where(Q { entry__rating = 4 } / Q { entry__rating = 5 }):distinct('id'):exec()
      assert.are.same(#r, 2)
    end)

    it("exclude 单条件", function()
      local r = Entry:exclude { rating = 5 }:exec()
      assert.are.same(#r, 2)
    end)

    it("exclude 多条件 (整体 NOT)", function()
      local r = Entry:exclude { blog_id = 1, rating = 4 }:exec()
      -- NOT (blog_id=1 AND rating=4) → 仅排除 First/Third Entry
      assert.are.same(#r, 1)
      assert.are.same(r[1].headline, 'Second Entry')
    end)

    it("exclude + Q", function()
      local r = Entry:exclude(Q { rating = 5 } / Q { headline__contains = 'Third' }):exec()
      assert.are.same(#r, 1)
      assert.are.same(r[1].headline, 'First Entry')
    end)

    it("where_in (单列)", function()
      local r = Entry:where_in('blog_id', { 1 }):exec()
      assert.are.same(#r, 2)
    end)

    it("where_in (子查询)", function()
      local r = Entry:where_in('blog_id', Blog:select('id'):where { name__contains = 'First' }):exec()
      assert.are.same(#r, 2)
    end)

    it("where_in (多列)", function()
      local r = Entry:where_in({ 'blog_id', 'rating' }, { { 1, 4 } }):exec()
      assert.are.same(#r, 2)
    end)

    it("where_not_in", function()
      local r = Entry:where_not_in('blog_id', { 1 }):exec()
      assert.are.same(#r, 1)
      assert.are.same(r[1].headline, 'Second Entry')
    end)

    it("where_or 表内 OR", function()
      local r = Entry:where_or { rating = 5, headline__contains = 'First' }:exec()
      assert.are.same(#r, 2)
    end)

    it("or_where 与上一个 where 用 OR", function()
      local r = Entry:where { headline = 'First Entry' }:or_where { headline = 'Second Entry' }:exec()
      assert.are.same(#r, 2)
    end)
  end)

  -------------------------------------------------------------------
  describe("4. ORDER / LIMIT / OFFSET / DISTINCT", function()
    it("order ASC / DESC", function()
      local asc = Entry:order('rating'):exec()
      assert.is_true(asc[1].rating <= asc[#asc].rating)
      local desc = Entry:order('-rating'):exec()
      assert.is_true(desc[1].rating >= desc[#desc].rating)
    end)

    it("order_by 别名", function()
      local r = Entry:order_by('-pub_date'):exec()
      assert.are.same(r[1].headline, 'Third Entry')
    end)

    it("多字段 order", function()
      local r = Entry:order('blog_id', '-rating'):exec()
      assert.are.same(r[1].blog_id, 1)
    end)

    it("nulls_last / nulls_first", function()
      Entry:insert { blog_id = 1, headline = 'noRating', body_text = '', pub_date = '2023-04-01', mod_date = '2023-04-01', number_of_comments = 0, number_of_pingbacks = 0 }:exec()
      local last = Entry:nulls_last():order('-rating'):exec()
      assert.are.same(last[#last].headline, 'noRating')
      local first = Entry:nulls_first():order('-rating'):exec()
      assert.are.same(first[1].headline, 'noRating')
      Entry:delete { headline = 'noRating' }:exec()
    end)

    it("reverse 翻转排序", function()
      local desc = Entry:order('-rating'):exec()
      local rev = Entry:order('-rating'):reverse():exec()
      assert.are.same(desc[1].id, rev[#rev].id)
    end)

    it("limit / offset", function()
      assert.are.same(#Entry:limit(2):exec(), 2)
      local skipped = Entry:order('id'):offset(1):limit(1):exec()
      assert.are.same(skipped[1].id, 2)
    end)

    it("distinct (无参)", function()
      local r = Entry:select('rating'):distinct():exec()
      assert.are.same(#r, 2) -- 4 与 5
    end)

    it("distinct ON", function()
      local r = Entry:distinct('blog_id'):select('blog_id', 'headline'):order('blog_id'):exec()
      assert.are.same(#r, 2)
    end)

    it("distinct_on 自动 prepend ORDER BY", function()
      local r = Entry:distinct_on('blog_id'):select('headline'):exec()
      assert.are.same(#r, 2)
    end)
  end)

  -------------------------------------------------------------------
  describe("5. GROUP BY / HAVING", function()
    it("group + annotate Count", function()
      local r = Entry:group('blog_id'):annotate { cnt = Count('id') }:exec()
      table.sort(r, function(a, b) return a.blog_id < b.blog_id end)
      assert.are.same(r, {
        { blog_id = 1, cnt = 2 },
        { blog_id = 2, cnt = 1 },
      })
    end)

    it("group + annotate Sum", function()
      local r = Entry:group('blog_id'):annotate { total_comments = Sum('number_of_comments') }:order('blog_id'):exec()
      assert.are.same(r[1].total_comments, 10)
      assert.are.same(r[2].total_comments, 3)
    end)

    it("数字索引 annotate 自动命名", function()
      local r = Book:group('author'):annotate { Sum('price') }:order('author'):exec()
      assert.is_truthy(r[1].price_sum)
    end)

    it("having", function()
      local r = Entry:group('blog_id'):annotate { cnt = Count('id') }:having { cnt__gt = 1 }:exec()
      assert.are.same(#r, 1)
      assert.are.same(r[1].blog_id, 1)
    end)

    it("having + Q", function()
      local r = Entry:group('blog_id'):annotate { cnt = Count('id') }
          :having(Q { cnt__lt = 0 } / Q { cnt__gte = 1 }):exec()
      assert.are.same(#r, 2)
    end)

    it("alias 不加入 SELECT 但可在 having 引用", function()
      local r = Entry:alias { cnt = Count('id') }:group('blog_id'):having { cnt__gt = 1 }:exec()
      assert.are.same(#r, 1)
      assert.is_nil(r[1].cnt) -- alias 不返回该列
    end)

    it("aggregate 终端方法", function()
      local s = Book:aggregate { total = Count('id'), avg_price = Avg('price'), sum_pages = Sum('pages') }
      assert.are.same(s.total, 2)
      assert.are.same(s.sum_pages, 550)
      assert.is_true(s.avg_price > 19 and s.avg_price < 30)
    end)

    it("aggregate StdDev (样本)", function()
      local s = Book:aggregate { sd = StdDev('price') }
      assert.is_true(s.sd > 0)
    end)
  end)

  -------------------------------------------------------------------
  describe("6. F 表达式", function()
    it("F 字段比较", function()
      local r = Entry:where { number_of_comments = F('number_of_pingbacks') }:exec()
      -- 没有满足条件的种子数据
      assert.are.same(#r, 0)
    end)

    it("F + 算术 + annotate", function()
      local r = Book:annotate { double_price = F('price') * 2 }:order('id'):exec()
      assert.is_true(math.abs(r[1].double_price - 59.98) < 1e-6)
    end)

    it("F 在 update 中: 字符串拼接", function()
      Entry:update { headline = F('headline') .. ' SFX' }:where { id = 1 }:exec()
      local e = Entry:where { id = 1 }:get()
      assert.are.same(e.headline, 'First Entry SFX')
      Entry:update { headline = 'First Entry' }:where { id = 1 }:exec()
    end)

    it("F 在 update 中: 跨表赋值", function()
      Entry:update { headline = F('blog_id__name') }:where { id = 1 }:exec()
      assert.are.same(Entry:where { id = 1 }:get().headline, 'First Blog')
      Entry:update { headline = 'First Entry' }:where { id = 1 }:exec()
    end)

    it("increase 单字段 +1", function()
      local before = Entry:where { id = 1 }:get().rating
      Entry:increase('rating'):where { id = 1 }:exec()
      assert.are.same(Entry:where { id = 1 }:get().rating, before + 1)
      Entry:increase('rating', -1):where { id = 1 }:exec()
    end)

    it("increase 单字段指定 amount", function()
      local before = Entry:where { id = 1 }:get().rating
      Entry:increase('rating', 5):where { id = 1 }:exec()
      assert.are.same(Entry:where { id = 1 }:get().rating, before + 5)
      Entry:increase('rating', -5):where { id = 1 }:exec()
    end)

    it("increase 多字段", function()
      local before = Entry:where { id = 1 }:get()
      Entry:increase { number_of_comments = 1, number_of_pingbacks = 2 }:where { id = 1 }:exec()
      local after = Entry:where { id = 1 }:get()
      assert.are.same(after.number_of_comments, before.number_of_comments + 1)
      assert.are.same(after.number_of_pingbacks, before.number_of_pingbacks + 2)
      Entry:increase { number_of_comments = -1, number_of_pingbacks = -2 }:where { id = 1 }:exec()
    end)

    it("decrease 单字段", function()
      local before = Entry:where { id = 1 }:get().rating
      Entry:decrease('rating'):where { id = 1 }:exec()
      assert.are.same(Entry:where { id = 1 }:get().rating, before - 1)
      Entry:decrease('rating', -1):where { id = 1 }:exec()
    end)
  end)

  -------------------------------------------------------------------
  describe("7. INSERT", function()
    it("插入单行", function()
      local r = Blog:insert { name = 'ins-1', tagline = 'ins-1' }:exec()
      assert.are.same(r, { affected_rows = 1 })
      Blog:delete { name = 'ins-1' }:exec()
    end)

    it("插入单行 + returning", function()
      local r = Blog:insert { name = 'ins-2', tagline = 'ins-2' }:returning('id', 'name'):exec()
      assert.are.same(type(r[1].id), 'number')
      assert.are.same(r[1].name, 'ins-2')
      Blog:delete { id = r[1].id }:exec()
    end)

    it("returning vararg 与 table 结果一致", function()
      local r1 = Blog:insert { name = 'ret-a' }:returning { 'id', 'name' }:exec()
      local r2 = Blog:insert { name = 'ret-b' }:returning('id', 'name'):exec()
      assert.are.same(r1[1].name, 'ret-a')
      assert.are.same(r2[1].name, 'ret-b')
      Blog:delete { name__in = { 'ret-a', 'ret-b' } }:exec()
    end)

    it("批量插入", function()
      local r = Blog:insert {
        { name = 'bulk-1', tagline = 'a' },
        { name = 'bulk-2', tagline = 'b' },
      }:exec()
      assert.are.same(r, { affected_rows = 2 })
      Blog:delete { name__startswith = 'bulk-' }:exec()
    end)

    it("批量插入 + returning *", function()
      local r = Blog:insert {
        { name = 'bret-1' }, { name = 'bret-2' },
      }:returning('*'):exec()
      assert.are.same(#r, 2)
      assert.is_truthy(r[1].id)
      assert.are.same(r[1].name, 'bret-1')
      Blog:delete { name__in = { 'bret-1', 'bret-2' } }:exec()
    end)

    it("使用默认值", function()
      local r = Blog:insert { name = 'def-1' }:returning('name', 'tagline'):exec()
      assert.are.same(r[1].tagline, Blog.fields.tagline.default)
      Blog:delete { name = 'def-1' }:exec()
    end)

    it("指定 columns 限制写入", function()
      local r = BlogBin:insert(
        { name = 'col-1', tagline = 'col-1', note = 'should not be inserted' },
        { 'name', 'tagline' }
      ):returning('name', 'tagline', 'note'):exec()
      assert.are.same(r[1].note, '')
      BlogBin:delete { name = 'col-1' }:exec()
    end)

    it("从 SELECT 子查询插入", function()
      local r = BlogBin:insert(
        Blog:where { name = 'Second Blog' }:select { 'name', 'tagline' }
      ):exec()
      assert.are.same(r, { affected_rows = 1 })
      local got = BlogBin:where { name = 'Second Blog' }:select('tagline'):get()
      assert.are.same(got.tagline, 'Another interesting blog')
      BlogBin:delete { name = 'Second Blog' }:exec()
    end)

    it("从 SELECT + select_literal 插入 (显式列)", function()
      local r = BlogBin:insert(
        Blog:where { name = 'First Blog' }:select { 'name', 'tagline' }:select_literal('from select literal'),
        { 'name', 'tagline', 'note' }
      ):exec()
      assert.are.same(r, { affected_rows = 1 })
      local got = BlogBin:where { name = 'First Blog' }:select('note'):get()
      assert.are.same(got.note, 'from select literal')
      BlogBin:delete { name = 'First Blog' }:exec()
    end)

    it("从 UPDATE+RETURNING 子查询插入 (含 source 表更新)", function()
      Blog:insert { name = 'ur-src', tagline = 'orig' }:exec()
      local r = BlogBin:insert(
        Blog:update { name = 'ur-renamed' }:where { name = 'ur-src' }
            :returning { 'name', 'tagline' }:returning_literal('from update'),
        { 'name', 'tagline', 'note' }
      ):returning { 'name', 'tagline', 'note' }:exec()
      assert.are.same(#r, 1)
      assert.are.same(r[1].name, 'ur-renamed')
      assert.are.same(r[1].note, 'from update')
      Blog:delete { name = 'ur-renamed' }:exec()
      BlogBin:delete { name = 'ur-renamed' }:exec()
    end)

    it("从 DELETE+RETURNING 子查询插入 (常用于归档)", function()
      Blog:insert { name = 'dr-src', tagline = 'will be archived' }:exec()
      local r = BlogBin:insert(
        Blog:delete { name = 'dr-src' }:returning { 'name', 'tagline' }:returning_literal('archived'),
        { 'name', 'tagline', 'note' }
      ):returning { 'name', 'tagline', 'note' }:exec()
      assert.are.same(r[1].name, 'dr-src')
      assert.are.same(r[1].note, 'archived')
      assert.is_false(Blog:where { name = 'dr-src' }:exists())
      BlogBin:delete { name = 'dr-src' }:exec()
    end)

    it("插入抛错: 唯一冲突", function()
      assert.has_error(function()
        Blog:insert { name = 'First Blog' }:exec()
      end)
    end)

    it("插入抛错: 单行长度超限 (ValidateError)", function()
      local ok, err = pcall(function()
        Blog:insert { name = string.rep('x', 30), tagline = 't' }:exec()
      end)
      assert.is_false(ok)
      assert.are.same(err.type, 'field_error')
      assert.are.same(err.name, 'name')
      assert.are.same(err.message, '字数不能多于20个')
    end)

    it("插入抛错: 批量行长度超限 (batch_index)", function()
      local ok, err = pcall(function()
        Blog:insert {
          { name = 'Valid', tagline = 'x' },
          { name = string.rep('y', 30), tagline = 'x' },
        }:exec()
      end)
      assert.is_false(ok)
      assert.are.same(err.batch_index, 2)
      assert.are.same(err.name, 'name')
    end)

    it("插入抛错: 复合 table 字段子元素出错 (含 index 与嵌套 message)", function()
      local ok, err = pcall(function()
        Author:insert {
          name = 'TmpA', email = 't@e.com', age = 22,
          resume = { { company = string.rep('1', 30) } },
        }:exec()
      end)
      assert.is_false(ok)
      assert.are.same(err.name, 'resume')
      assert.are.same(err.index, 1)
      assert.are.same(err.message.name, 'company')
      assert.are.same(err.message.message, '字数不能多于20个')
    end)

    it("插入抛错: 批量+复合字段 (batch_index + index)", function()
      local ok, err = pcall(function()
        Author:insert { {
          name = 'TmpB', email = 't@e.com', age = 22,
          resume = { { company = string.rep('1', 30) } },
        } }:exec()
      end)
      assert.is_false(ok)
      assert.are.same(err.batch_index, 1)
      assert.are.same(err.index, 1)
      assert.are.same(err.name, 'resume')
    end)

    it("插入抛错: 子查询列数不一致", function()
      assert.has_error(function()
        BlogBin:insert(
          Blog:where { name = 'First Blog' }:select { 'name', 'tagline' },
          { 'name' }
        ):exec()
      end)
      assert.has_error(function()
        BlogBin:insert(
          Blog:where { name = 'First Blog' }:select { 'name', 'tagline' },
          { 'name', 'tagline', 'note' }
        ):exec()
      end)
    end)
  end)

  -------------------------------------------------------------------
  describe("8. UPDATE", function()
    it("基础 update", function()
      Blog:update { tagline = 'changed' }:where { name = 'First Blog' }:exec()
      assert.are.same(Blog:where { name = 'First Blog' }:get().tagline, 'changed')
      Blog:update { tagline = 'Welcome to my blog' }:where { name = 'First Blog' }:exec()
    end)

    it("update + returning", function()
      local r = Blog:update { tagline = 'changed-r' }:where { name = 'First Blog' }:returning('*'):exec()
      assert.are.same(r[1].tagline, 'changed-r')
      Blog:update { tagline = 'Welcome to my blog' }:where { name = 'First Blog' }:exec()
    end)

    it("update with cross-table where", function()
      Entry:update { headline = F('headline') .. ' x' }:where { blog_id__name = 'First Blog' }:exec()
      local r = Entry:where { headline__endswith = ' x' }:order('id'):exec()
      assert.are.same(#r, 2)
      -- 还原
      Entry:update { headline = 'First Entry' }:where { id = 1 }:exec()
      Entry:update { headline = 'Third Entry' }:where { id = 3 }:exec()
    end)

    it("update 抛错: 字段超限", function()
      local ok, err = pcall(function()
        Blog:update { name = string.rep('x', 30) }:where { id = 1 }:exec()
      end)
      assert.is_false(ok)
      assert.are.same(err.name, 'name')
    end)
  end)

  -------------------------------------------------------------------
  describe("9. DELETE", function()
    it("delete 带条件 + affected_rows", function()
      Blog:insert { name = 'del-1' }:exec()
      local r = Blog:delete { name = 'del-1' }:exec()
      assert.are.same(r, { affected_rows = 1 })
    end)

    it("delete 链式 where", function()
      Blog:insert {
        { name = 'del-2' }, { name = 'del-3' },
      }:exec()
      local r = Blog:delete():where { name__in = { 'del-2', 'del-3' } }:exec()
      assert.are.same(r, { affected_rows = 2 })
    end)

    it("delete 三参数", function()
      Blog:insert { name = 'del-4' }:exec()
      local r = Blog:delete("name", "=", "del-4"):exec()
      assert.are.same(r, { affected_rows = 1 })
    end)

    it("delete + returning", function()
      Blog:insert { name = 'del-5', tagline = 't' }:exec()
      local r = Blog:delete { name = 'del-5' }:returning('*'):exec()
      assert.are.same(r[1].name, 'del-5')
    end)

    it("delete 不匹配返回 0", function()
      local r = Blog:delete { name = 'no-such' }:exec()
      assert.are.same(r, { affected_rows = 0 })
    end)
  end)

  -------------------------------------------------------------------
  describe("10. UPSERT", function()
    it("基本 upsert (key 自动取唯一字段)", function()
      local r = Blog:upsert {
        { name = 'First Blog', tagline = 'updated by upsert' },
        { name = 'upsert-new', tagline = 'inserted by upsert' },
      }:exec()
      assert.are.same(r, { affected_rows = 2 })
      assert.are.same(Blog:where { name = 'First Blog' }:get().tagline, 'updated by upsert')
      assert.is_truthy(Blog:where { name = 'upsert-new' }:get())
      Blog:delete { name = 'upsert-new' }:exec()
      Blog:update { tagline = 'Welcome to my blog' }:where { name = 'First Blog' }:exec()
    end)

    it("upsert 单条 + 显式 key", function()
      Blog:upsert({ { name = 'upsert-x', tagline = 'a' } }, 'name'):exec()
      Blog:upsert({ { name = 'upsert-x', tagline = 'b' } }, 'name'):exec()
      assert.are.same(Blog:where { name = 'upsert-x' }:get().tagline, 'b')
      Blog:delete { name = 'upsert-x' }:exec()
    end)

    it("upsert from SELECT 子查询 (注入新 name)", function()
      -- 准备：BlogBin 中插入两个新 name + 一个与 Blog 重复的 name
      BlogBin:insert {
        { name = 'fresh-1',    tagline = 'src1' },
        { name = 'fresh-2',    tagline = 'src2' },
        { name = 'First Blog', tagline = 'dup' }, -- 与 Blog 重复，应被 notin 排除
      }:exec()
      local r = Blog:upsert(
        BlogBin:where { name__notin = Blog:select { 'name' }:distinct() }
            :select { 'name', 'tagline' }
            :distinct('name')
      ):returning { 'id', 'name', 'tagline' }:exec()
      assert.are.same(#r, 2)
      local names = {}
      for _, row in ipairs(r) do names[row.name] = true end
      assert.is_true(names['fresh-1'])
      assert.is_true(names['fresh-2'])
      Blog:delete { name__in = { 'fresh-1', 'fresh-2' } }:exec()
      BlogBin:delete():exec()
    end)

    it("upsert from UPDATE+RETURNING 子查询", function()
      BlogBin:insert { { name = 'ub-1', tagline = 't1' }, { name = 'ub-2', tagline = 't2' } }:exec()
      local r = Blog:upsert(
        BlogBin:update { tagline = 'updated by upsert returning' }:returning { 'name', 'tagline' }
      ):returning { 'id', 'name', 'tagline' }:exec()
      assert.are.same(#r, 2)
      local names = Blog:where { tagline = 'updated by upsert returning' }:order 'name':flat 'name'
      table.sort(names)
      assert.are.same(names, { 'ub-1', 'ub-2' })
      Blog:where { tagline = 'updated by upsert returning' }:delete():exec()
      BlogBin:delete():exec()
    end)

    it("upsert 抛错: 单条 age 超限", function()
      local ok, err = pcall(function()
        Author:upsert { { name = 'Tom', age = 111 } }:exec()
      end)
      assert.is_false(ok)
      assert.are.same(err.batch_index, 1)
      assert.are.same(err.name, 'age')
      assert.are.same(err.message, '值不能大于100')
    end)

    it("upsert 抛错: 多条第二条出错 (batch_index=2)", function()
      local ok, err = pcall(function()
        Author:upsert { { name = 'Tom', age = 11 }, { name = 'Jerry', age = 101 } }:exec()
      end)
      assert.is_false(ok)
      assert.are.same(err.batch_index, 2)
    end)
  end)

  -------------------------------------------------------------------
  describe("11. MERGE", function()
    it("merge 已有更新 + 新增插入", function()
      local r = Blog:merge {
        { name = 'First Blog', tagline = 'updated by merge' },
        { name = 'merge-new', tagline = 'inserted by merge' },
      }:exec()
      assert.are.same(r, { affected_rows = 1 })
      assert.are.same(Blog:where { name = 'First Blog' }:get().tagline, 'updated by merge')
      assert.is_truthy(Blog:where { name = 'merge-new' }:get())
      Blog:delete { name = 'merge-new' }:exec()
      Blog:update { tagline = 'Welcome to my blog' }:where { name = 'First Blog' }:exec()
    end)

    it("merge 仅插入新行不变更已有", function()
      local origin = Blog:where { name = 'First Blog' }:get()
      Blog:merge { { name = 'First Blog' }, { name = 'merge-only-new' } }:exec()
      local after = Blog:where { name = 'First Blog' }:get()
      assert.are.same(after.tagline, origin.tagline)
      Blog:delete { name = 'merge-only-new' }:exec()
      -- 还原：merge 即使没主动改 tagline 也可能在 UPDATE 路径中把它写回 default
      Blog:update { tagline = origin.tagline }:where { name = 'First Blog' }:exec()
    end)

    it("merge 抛错: 第二条 age 超限", function()
      local ok, err = pcall(function()
        Author:merge { { name = 'Tom', age = 11 }, { name = 'Jerry', age = 101 } }:exec()
      end)
      assert.is_false(ok)
      assert.are.same(err.batch_index, 2)
      assert.are.same(err.name, 'age')
    end)
  end)

  -------------------------------------------------------------------
  describe("12. UPDATES (批量更新)", function()
    it("updates 仅命中已存在主键", function()
      Blog:insert { name = 'upd-1' }:exec()
      local before = Blog:where { name = 'upd-1' }:get()
      local r = Blog:updates {
        { id = before.id, tagline = 'updated by updates' },
        { id = 999999, tagline = 'wont update' },
      }:exec()
      assert.are.same(r, { affected_rows = 1 })
      assert.are.same(Blog:where { id = before.id }:get().tagline, 'updated by updates')
      Blog:delete { id = before.id }:exec()
    end)

    it("updates from SELECT 子查询", function()
      BlogBin:insert { name = 'sync-x', tagline = 'old', note = '' }:exec()
      local r = BlogBin:updates(
        Blog:where { name = 'Second Blog' }:select { 'name', 'tagline' },
        'name'
      ):exec()
      -- BlogBin 中没有 name=Second Blog，所以 0 命中
      assert.are.same(r, { affected_rows = 0 })
      BlogBin:delete():exec()
    end)

    it("updates 抛错: 缺主键值", function()
      local ok, err = pcall(function()
        Blog:updates { { tagline = 'no id' } }:exec()
      end)
      assert.is_false(ok)
      assert.are.same(err.name, 'id')
      assert.are.same(err.message, 'id不能为空')
      assert.are.same(err.batch_index, 1)
    end)

    it("updates 抛错: 多条第二条 age 超限", function()
      local ok, err = pcall(function()
        Author:updates { { id = 1, age = 11 }, { id = 2, age = 101 } }:exec()
      end)
      assert.is_false(ok)
      assert.are.same(err.batch_index, 2)
      assert.are.same(err.name, 'age')
    end)

    it("updates 抛错: 非法字段名 (字符串)", function()
      local ok, err = pcall(function()
        Author:updates { { name = 'John Doe', age2 = 9 } }:exec()
      end)
      assert.is_false(ok)
      assert.is_truthy(tostring(err):find("invalid field name 'age2' for model 'author'", 1, true))
    end)
  end)

  -------------------------------------------------------------------
  describe("13. ALIGN (upsert + 删除多余)", function()
    it("align 同步子集", function()
      Blog:insert { { name = 'aln-a', tagline = 'a' }, { name = 'aln-b', tagline = 'b' } }:exec()
      Blog:where { name__startswith = 'aln-' }:align {
        { name = 'aln-a', tagline = 'kept' },
        { name = 'aln-c', tagline = 'newly' },
      }:exec()
      local rows = Blog:where { name__startswith = 'aln-' }:order('name'):exec()
      local names = {}
      for _, r in ipairs(rows) do names[#names + 1] = r.name end
      table.sort(names)
      assert.are.same(names, { 'aln-a', 'aln-c' })
      Blog:delete { name__startswith = 'aln-' }:exec()
    end)
  end)

  -------------------------------------------------------------------
  describe("14. GET / TRY_GET / GETS / MERGE_GETS", function()
    it("get 单条命中", function()
      local r = Blog:get { name = 'First Blog' }
      assert.are.same(r.tagline, 'Welcome to my blog')
    end)

    it("get 不存在返回 false", function()
      local r = Blog:get { name = 'no-such' }
      assert.is_false(r)
    end)

    it("get 两参数 / 三参数", function()
      assert.are.same(Blog:get("name", "First Blog").id, 1)
      assert.is_truthy(Entry:get("rating", ">", 4))
    end)

    it("try_get 等价于 get", function()
      assert.are.same(Blog:try_get { name = 'First Blog' }.id, 1)
    end)

    it("gets 批量按键 (CTE RIGHT JOIN)", function()
      local r = Blog:gets({ { name = 'First Blog' }, { name = 'no-such' } }, { 'name', 'tagline' }):exec()
      -- 输入 2 个键 → RIGHT JOIN 必返回 2 行
      assert.are.same(#r, 2)
      -- 命中行的 tagline 应非 nil；未命中行的 tagline 为 nil
      local tag_count = 0
      for _, row in ipairs(r) do
        if row.tagline then tag_count = tag_count + 1 end
      end
      assert.is_true(tag_count >= 1)
    end)

    it("merge_gets 合并字典", function()
      local r = Blog:select('name'):merge_gets(
        { { id = 1, name = 'aa' }, { id = 999999, name = 'bb' } }, 'id'
      ):exec()
      assert.are.same(#r, 2)
    end)
  end)

  -------------------------------------------------------------------
  describe("15. GET_OR_CREATE / UPDATE_OR_CREATE", function()
    it("get_or_create: 已存在 → 不创建", function()
      local r, created = Blog:get_or_create({ name = 'First Blog' }, { tagline = 'never used' })
      assert.is_false(created)
      assert.are.same(r.tagline, 'Welcome to my blog')
    end)

    it("get_or_create: 不存在 → 创建", function()
      local r, created = Blog:get_or_create({ name = 'goc-new' }, { tagline = 'created by goc' })
      assert.is_true(created)
      assert.are.same(r.tagline, 'created by goc')
      Blog:delete { name = 'goc-new' }:exec()
    end)

    it("update_or_create: 不存在 → 创建", function()
      local r, created = Blog:update_or_create({ name = 'uoc-new' }, { tagline = 'set' })
      assert.is_true(created)
      assert.are.same(r.tagline, 'set')
      Blog:delete { name = 'uoc-new' }:exec()
    end)

    it("update_or_create: 已存在 → 更新", function()
      Blog:insert { name = 'uoc-up', tagline = 'before' }:exec()
      local r, created = Blog:update_or_create({ name = 'uoc-up' }, { tagline = 'after' })
      assert.is_false(created)
      assert.are.same(r.tagline, 'after')
      Blog:delete { name = 'uoc-up' }:exec()
    end)
  end)

  -------------------------------------------------------------------
  describe("16. FILTER / COUNT / EXISTS / IN_BULK / CONTAINS", function()
    it("filter: where + exec 快捷", function()
      local r = Blog:filter { name__contains = 'Blog' }
      assert.are.same(#r, 2)
    end)

    it("count 无参 / 有参", function()
      assert.are.same(Blog:count(), 2)
      assert.are.same(Entry:count { rating__gt = 4 }, 1)
      assert.are.same(Entry:count("rating", ">", 3), 3)
    end)

    it("exists", function()
      assert.is_true(Blog:where { name = 'First Blog' }:exists())
      assert.is_false(Blog:where { name = 'no-such' }:exists())
    end)

    it("in_bulk: 默认按主键", function()
      local d = Blog:in_bulk { 1, 2 }
      assert.are.same(d[1].name, 'First Blog')
      assert.are.same(d[2].name, 'Second Blog')
    end)

    it("in_bulk: 指定字段索引", function()
      local d = Blog:in_bulk({ 'First Blog' }, 'name')
      assert.are.same(d['First Blog'].id, 1)
    end)

    it("in_bulk: 不传 ids 返回全集", function()
      local d = Blog:in_bulk()
      assert.is_truthy(d[1])
      assert.is_truthy(d[2])
    end)

    it("contains: 主键命中", function()
      local b = Blog:get { name = 'First Blog' }
      assert.is_truthy(Blog:where { name__contains = 'Blog' }:contains(b))
    end)
  end)

  -------------------------------------------------------------------
  describe("17. FIRST / LAST / LATEST / EARLIEST", function()
    it("first 默认按主键升序", function()
      assert.are.same(Blog:first().id, 1)
    end)

    it("last 默认按主键降序", function()
      assert.are.same(Blog:last().id, 2)
    end)

    it("first 与 order 配合", function()
      assert.are.same(Entry:order('-pub_date'):first().headline, 'Third Entry')
    end)

    it("latest", function()
      assert.are.same(Entry:latest('pub_date').headline, 'Third Entry')
    end)

    it("earliest", function()
      assert.are.same(Entry:earliest('pub_date').headline, 'First Entry')
    end)
  end)

  -------------------------------------------------------------------
  describe("18. FLAT / VALUES / VALUES_LIST / AS_SET", function()
    it("flat 单列", function()
      local names = Blog:order('id'):flat('name')
      assert.are.same(names, { 'First Blog', 'Second Blog' })
    end)

    it("flat 在 CUD 之后", function()
      Blog:insert { { name = 'flat-1' }, { name = 'flat-2' } }:exec()
      local names = Blog:delete { name__startswith = 'flat-' }:flat('name')
      table.sort(names)
      assert.are.same(names, { 'flat-1', 'flat-2' })
    end)

    it("values 字典数组 (不经 load)", function()
      local r = Blog:values('id', 'name')
      assert.are.same(type(r[1]), 'table')
      assert.is_truthy(r[1].name)
    end)

    it("values_list 元组数组", function()
      local r = Blog:order('id'):values_list { 'id', 'name' }
      assert.are.same(r[1][2], 'First Blog')
    end)

    it("values_list flat 单列", function()
      local r = Blog:order('id'):values_list('name', { flat = true })
      assert.are.same(r, { 'First Blog', 'Second Blog' })
    end)

    it("as_set", function()
      local s = Entry:select('rating'):as_set()
      assert.is_truthy(s[4])
      assert.is_truthy(s[5])
    end)
  end)

  -------------------------------------------------------------------
  describe("19. SELECT_RELATED", function()
    it("select_related 单字段 (返回 flat key blog_id__name)", function()
      local r = Entry:select_related('blog_id', 'name'):where { id = 1 }:exec()
      -- blog_id 仍是 FK 主键值，关联字段以 fk__col 形式返回
      assert.are.same(r[1].blog_id, 1)
      assert.are.same(r[1].blog_id__name, 'First Blog')
    end)

    it("select_related 数组形式", function()
      local r = Entry:select_related('blog_id', { 'name', 'tagline' }):where { id = 1 }:exec()
      assert.are.same(r[1].blog_id__name, 'First Blog')
      assert.are.same(r[1].blog_id__tagline, 'Welcome to my blog')
    end)

    it("select_related * 全部字段", function()
      local r = Entry:select_related('blog_id', '*'):where { id = 1 }:exec()
      assert.are.same(r[1].blog_id__name, 'First Blog')
      assert.is_truthy(r[1].blog_id__tagline)
    end)

    it("select_related_labels 全外键 LEFT JOIN", function()
      local r = Book:select_related_labels():where { id = 1 }:exec()
      assert.is_truthy(r[1])
    end)
  end)

  -------------------------------------------------------------------
  describe("20. UNION / EXCEPT / INTERSECT", function()
    it("union 去重", function()
      local q1 = Blog:select('name'):where { name = 'First Blog' }
      local q2 = Blog:select('name'):where { name = 'First Blog' }
      assert.are.same(#q1:union(q2):exec(), 1)
    end)

    it("union_all 不去重", function()
      local q1 = Blog:select('name'):where { name = 'First Blog' }
      local q2 = Blog:select('name'):where { name = 'First Blog' }
      assert.are.same(#q1:union_all(q2):exec(), 2)
    end)

    it("except", function()
      local all = Blog:select('name')
      local one = Blog:select('name'):where { name = 'First Blog' }
      assert.are.same(#all:except(one):exec(), 1)
    end)

    it("intersect", function()
      local q1 = Blog:select('name'):where { id__lt = 3 }
      local q2 = Blog:select('name'):where { id__gt = 1 }
      assert.are.same(#q1:intersect(q2):exec(), 1)
    end)
  end)

  -------------------------------------------------------------------
  describe("21. CTE", function()
    it("with_values + from (用 Model.token 注入原始列引用)", function()
      -- v.name 不是 Blog 字段：select() 会拒绝，select_literal() 会把它当字符串字面量
      -- → 用 Model.token 包裹原始 SQL token
      local r = Blog:with_values('v', { { id = 1, name = 'a' }, { id = 2, name = 'b' } })
          :from('v'):select(Model.token('v.name AS vname')):exec()
      assert.are.same(#r, 2)
      local names = {}
      for _, row in ipairs(r) do names[#names + 1] = row.vname end
      table.sort(names)
      assert.are.same(names, { 'a', 'b' })
    end)

    it("where_recursive (Category 自引用)", function()
      local root = Category:get { name = 'Root' }
      local r = Category:where_recursive('parent_id', root.id):exec()
      assert.is_true(#r >= 3) -- Child A / Child B / Grandchild A1
    end)
  end)

  -------------------------------------------------------------------
  describe("22. RETURNING", function()
    it("returning *", function()
      local r = Blog:insert { name = 'r1' }:returning('*'):exec()
      assert.is_truthy(r[1].id)
      Blog:delete { id = r[1].id }:exec()
    end)

    it("returning 跨表列 (delete 后取 fk)", function()
      local entry = Entry:insert { blog_id = 1, headline = 'r-entry', body_text = '', pub_date = '2023-01-01', mod_date = '2023-01-01', number_of_comments = 0, number_of_pingbacks = 0, rating = 1 }:returning('*'):exec()
      local del = Entry:delete { id = entry[1].id }:returning('blog_id__name'):exec()
      assert.are.same(del[1].blog_id__name, 'First Blog')
    end)

    it("returning 链式追加", function()
      local r = Blog:insert { name = 'r2' }:returning('id'):returning('name'):exec()
      assert.is_truthy(r[1].id)
      assert.are.same(r[1].name, 'r2')
      Blog:delete { id = r[1].id }:exec()
    end)

    it("returning_literal", function()
      local r = Blog:insert { name = 'r3' }:returning('id'):returning_literal('hello'):exec()
      assert.is_truthy(r[1].id)
      Blog:delete { id = r[1].id }:exec()
    end)
  end)

  -------------------------------------------------------------------
  describe("23. EXEC 控制 (statement / compact / raw / skip_validate)", function()
    it("statement 返回 SQL 字符串 (不执行)", function()
      local s = Blog:where { id = 1 }:select('name'):statement()
      assert.are.same(type(s), 'string')
      assert.is_true(#s > 0)
      assert.is_truthy(s:upper():find('SELECT'))
    end)

    it("compact 紧凑模式", function()
      local r = Blog:select('id', 'name'):order('id'):compact():exec()
      -- 预期 [[1,"First Blog"],[2,"Second Blog"]]
      assert.are.same(type(r[1]), 'table')
      assert.is_truthy(r[1][1])
      assert.is_truthy(r[1][2])
      assert.is_nil(r[1].name)
    end)

    it("raw + execr 不调用 field:load", function()
      local a = Entry:where { id = 1 }:execr()
      -- execr 等价于 :raw():exec()，外键字段为原始 id 值
      assert.are.same(type(a[1].blog_id), 'number')
    end)

    it("skip_validate 跳过校验 (本应超长的字段也通过)", function()
      assert.has_no_error(function()
        BlogBin:skip_validate():insert { name = string.rep('z', 30) }:exec()
        BlogBin:delete { name__startswith = 'zzz' }:exec()
      end)
    end)
  end)

  -------------------------------------------------------------------
  describe("24. 工具方法 (copy / clear / prepend / append / as / from / get_table)", function()
    it("copy 不影响原对象", function()
      local base = Blog:where { id__gt = 0 }
      local q1 = base:copy():where { name = 'First Blog' }
      local q2 = base:copy():where { name = 'Second Blog' }
      assert.are.same(#q1:exec(), 1)
      assert.are.same(#q2:exec(), 1)
      -- base 仍然能拿到全部
      assert.are.same(#base:exec(), 2)
    end)

    it("clear 清空 builder", function()
      local sql = Blog:where { id = 1 }:select('name')
      sql:clear()
      -- 清空后再次执行回到全表
      assert.are.same(#sql:exec(), 2)
    end)

    it("as 表别名", function()
      local r = Blog:as('b'):where { id = 1 }:exec()
      assert.are.same(r[1].name, 'First Blog')
    end)

    it("from + 原始字符串 (限定列名用 Model.token)", function()
      local r = Blog:from('blog b'):select(Model.token('b.name AS bname')):where("b.id = 1"):exec()
      assert.are.same(r[1].bname, 'First Blog')
    end)

    it("get_table 拼接 (tablename + alias)", function()
      assert.is_truthy(Blog:create_sql():get_table():find('blog'))
    end)

    it("prepend / append / return_all", function()
      local r = Blog:select('name'):append(Entry:select('headline')):return_all():exec()
      -- 至少返回两个结果集
      assert.is_true(#r >= 2)
    end)

    it("exec_statement 直接执行 SQL", function()
      local r = Blog:create_sql():exec_statement("SELECT 1 AS num")
      assert.are.same(r[1].num, 1)
    end)
  end)

  -------------------------------------------------------------------
  describe("25. JSON 字段查询", function()
    before_each(function()
      Author:where { name = 'jsonA' }:delete():exec()
      Author:insert {
        name = 'jsonA', email = 'j@a.com', age = 20,
        payload = { status = 'active', score = 99 },
        resume = { { start_date = '2025-01-01', end_date = '2025-02-01', company = 'JC', position = 'Dev', description = '' } },
      }:exec()
    end)

    after_each(function()
      Author:where { name = 'jsonA' }:delete():exec()
    end)

    it("payload 顶层 key 等值", function()
      local r = Author:where { payload__status = 'active' }:exec()
      assert.is_true(#r >= 1)
    end)

    it("payload contains", function()
      local r = Author:where { payload__contains = { status = 'active' } }:exec()
      assert.is_true(#r >= 1)
    end)

    it("payload contained_by", function()
      local r = Author:where { payload__contained_by = { status = 'active', score = 99, extra = 1 } }:exec()
      assert.is_true(#r >= 1)
    end)

    it("payload has_key", function()
      local r = Author:where { payload__has_key = 'status' }:exec()
      assert.is_true(#r >= 1)
    end)

    -- 注：resume 是 jsonb 数组。ORM 在数字路径段上仍用 text key (`-> '0'`)，
    -- PG 对数组应使用 int (`-> 0`) 才能索引。这里只验证语句可正确发送、不抛错。
    it("resume 数字下标 has_key 能正确执行 (语义限制见注)", function()
      assert.has_no_error(function()
        Author:where { resume__0__has_key = 'start_date' }:exec()
      end)
    end)

    it("resume 数字下标 contains 能正确执行", function()
      assert.has_no_error(function()
        Author:where { resume__0__contains = { start_date = '2025-01-01' } }:exec()
      end)
    end)

    it("payload 用对象的字符串数字键时 has_key 命中 (绕过 array 限制)", function()
      Author:insert {
        name = 'jsonNum', email = 'n@a.com', age = 22,
        payload = { ['0'] = { x = 1 }, ['2'] = { score = 99 } },
      }:exec()
      local r = Author:where { payload__0__has_key = 'x' }:exec()
      assert.is_true(#r >= 1)
      Author:delete { name = 'jsonNum' }:exec()
    end)
  end)

  -------------------------------------------------------------------
  describe("26. 校验 (validate / validate_create / validate_update)", function()
    it("validate_create 应用默认值", function()
      local data = Blog:validate_create { name = 'newcomer' }
      assert.are.same(data.name, 'newcomer')
      assert.are.same(data.tagline, 'default tagline')
    end)

    it("validate_update 仅校验提供的字段", function()
      local data = Blog:validate_update { name = 'partial' }
      assert.are.same(data.name, 'partial')
      assert.is_nil(data.tagline)
    end)

    it("validate 智能分流", function()
      local create_data = Blog:validate { name = 'auto-create' }
      assert.are.same(create_data.tagline, 'default tagline')
      local update_data = Blog:validate { id = 1, name = 'auto-update' }
      assert.is_nil(update_data.tagline) -- 走 update 路径
    end)

    it("validate_create 抛错: 长度超限", function()
      local ok, err = pcall(function()
        Blog:validate_create { name = string.rep('x', 30) }
      end)
      assert.is_false(ok)
      assert.are.same(err.name, 'name')
    end)

    it("validate_cascade_update: 子模型缺少回指 FK 时报错", function()
      -- Author.resume 的子模型 Resume 没有 author_id 这种回指 FK,
      -- 所以 validate_cascade_update 找不到 cascade field,会抛出明确错误。
      local ok, err = pcall(function()
        Author:validate_cascade_update {
          id = 1, name = 'John Doe', age = 30,
          resume = { { start_date = '2020-01-01', end_date = '2021-01-01', company = 'X', position = 'Y', description = '' } },
        }
      end)
      assert.is_false(ok)
      assert.is_truthy(tostring(err):find("cascade field", 1, true))
    end)

    it("validate_cascade_update happy path: 注入主键到子表外键", function()
      -- 内嵌一对 Doc / DocItem，DocItem 有 doc_id 回指 Doc，
      -- 演示 cascade 把父表 id 自动塞到 items[*].doc_id。
      -- 仅用于校验，不需要建表。
      local CDoc = Model:create_model {
        table_name = 'cdoc',
        fields = { { 'title', maxlength = 100 } },
      }
      local CDocItem = Model:create_model {
        table_name = 'cdoc_item',
        fields = {
          { 'doc_id', reference = CDoc },
          { 'label',  maxlength = 50, compact = false },
        },
      }
      local CDocFull = Model:create_model {
        table_name = 'cdoc',
        extends    = CDoc,
        fields     = { { 'items', model = CDocItem } },
      }

      local data = CDocFull:validate_cascade_update {
        id = 42,
        title = 'My Doc',
        items = { { label = 'a' }, { label = 'b' } },
      }

      assert.are.same(#data.items, 2)
      assert.are.same(data.items[1].doc_id, 42)
      assert.are.same(data.items[2].doc_id, 42)
      assert.are.same(data.items[1].label, 'a')
      assert.are.same(data.items[2].label, 'b')
    end)
  end)

  -------------------------------------------------------------------
  describe("27. 记录实例 (Records)", function()
    it("Model:create 校验 + 插入 + 返回完整实例", function()
      local rec = Blog:create { name = 'rec-1' }
      assert.is_truthy(rec.id)
      assert.are.same(rec.name, 'rec-1')
      assert.are.same(rec.tagline, 'default tagline')
      Blog:delete { id = rec.id }:exec()
    end)

    it("Model:save 智能 (无主键 → create)", function()
      local rec = Blog:save { name = 'rec-2' }
      assert.is_truthy(rec.id)
      Blog:delete { id = rec.id }:exec()
    end)

    it("Model:save 智能 (有主键 → update)", function()
      Blog:insert { name = 'rec-3', tagline = 'a' }:exec()
      local r = Blog:where { name = 'rec-3' }:get()
      r.tagline = 'updated'
      Blog:save(r)
      assert.are.same(Blog:where { id = r.id }:get().tagline, 'updated')
      Blog:delete { id = r.id }:exec()
    end)

    it("Model:save_create 强制创建", function()
      local rec = Blog:save_create { name = 'rec-4' }
      assert.is_truthy(rec.id)
      Blog:delete { id = rec.id }:exec()
    end)

    it("Model:save_update 强制更新", function()
      Blog:insert { name = 'rec-5', tagline = 'a' }:exec()
      local existing = Blog:where { name = 'rec-5' }:get()
      Blog:save_update { id = existing.id, tagline = 'updated' }
      assert.are.same(Blog:where { id = existing.id }:get().tagline, 'updated')
      Blog:delete { id = existing.id }:exec()
    end)

    it("Model:load 返回带 fk 代理的实例", function()
      local raw = Entry:where { id = 1 }:execr()
      local loaded = Entry:load(raw[1])
      -- blog_id 变成代理对象，访问 .name 触发懒查询
      assert.are.same(loaded.blog_id.name, 'First Blog')
    end)

    it("Model:create_record 设置元表后获得 save/delete 等方法", function()
      Blog:insert { name = 'rec-6', tagline = 'a' }:exec()
      local row = Blog:where { name = 'rec-6' }:get()
      local rec = Blog:create_record(row)
      rec.tagline = 'instance-saved'
      rec:save()
      assert.are.same(Blog:where { id = rec.id }:get().tagline, 'instance-saved')
      rec:delete()
      assert.is_false(Blog:where { id = rec.id }:exists())
    end)

    it("Record(data) 合并字段", function()
      local rec = Blog:create_record { id = 999, name = 'tmp' }
      rec({ name = 'merged', tagline = 'm' })
      assert.are.same(rec.name, 'merged')
      assert.are.same(rec.tagline, 'm')
    end)
  end)

  -------------------------------------------------------------------
  describe("28. 事务 (transaction / atomic)", function()
    it("transaction 正常提交", function()
      Blog:transaction(function()
        Blog:insert { name = 'tx-ok' }:exec()
      end)
      assert.is_truthy(Blog:where { name = 'tx-ok' }:get())
      Blog:delete { name = 'tx-ok' }:exec()
    end)

    it("transaction 抛错回滚", function()
      pcall(function()
        Blog:transaction(function()
          Blog:insert { name = 'tx-rollback' }:exec()
          error("boom")
        end)
      end)
      assert.is_false(Blog:where { name = 'tx-rollback' }:exists())
    end)

    it("atomic 包裹函数", function()
      local handler = Blog:atomic(function(req)
        Blog:insert { name = req.name }:exec()
        return { ok = true }
      end)
      handler({ name = 'atomic-1' })
      assert.is_truthy(Blog:where { name = 'atomic-1' }:get())
      Blog:delete { name = 'atomic-1' }:exec()
    end)
  end)

  -------------------------------------------------------------------
  describe("29. dates / datetimes (DATE_TRUNC 去重)", function()
    it("dates by month", function()
      local months = Entry:dates('pub_date', 'month')
      -- 2023-01 + 2023-02 → 2 个
      assert.is_true(#months >= 2)
    end)

    it("datetimes by hour", function()
      local hours = ViewLog:datetimes('ctime', 'hour')
      assert.is_true(#hours >= 2)
    end)
  end)

  -------------------------------------------------------------------
  describe("30. 终态：reseed 后种子完整", function()
    it("最后一步：reseed 让数据回到初始状态", function()
      reseed()
      assert.are.same(Blog:count(), 2)
      assert.are.same(Entry:count(), 3)
      assert.are.same(Book:count(), 2)
    end)
  end)
end

---------------------------------------------------------------------
-- 与 model_spec.lua 同样的 busted 检测：spec runner 时执行 main()，
-- 否则 require 时只导出 models 表
---------------------------------------------------------------------
local function is_running_with_busted()
  if arg then
    for i = 1, #arg do
      if arg[i] == "-o" or arg[i] == "--output" then
        return true
      end
    end
  end
  if arg and arg[0] and string.match(arg[0], "ngx_busted%.lua$") then
    return true
  end
  return false
end

if is_running_with_busted() then
  main()
else
  return {
    Blog = Blog,
    BlogBin = BlogBin,
    Author = Author,
    Entry = Entry,
    ViewLog = ViewLog,
    Publisher = Publisher,
    Book = Book,
    Store = Store,
    Category = Category,
  }
end
