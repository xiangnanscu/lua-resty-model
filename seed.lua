local Model = require("xodel.model")
local Q = Model.Q
local F = Model.F
local Sum = Model.Sum
local Avg = Model.Avg
local Max = Model.Max
local Min = Model.Min
local Count = Model.Count

local User = Model:create_model {
  table_name = 'users', -- test pg reserved word
  fields = {
    { "username", maxlength = 20, minlength = 2, unique = true },
    { "password", type = 'text' },
    -- { "from",     type = 'text',  default = 'China' }, -- test pg reserved word
  }
}

---@class Blog
local Blog = Model:create_model {
  table_name = 'blog',
  fields = {
    { "name",    maxlength = 20, minlength = 2,              unique = true, compact = false },
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
    { "name", "姓名", maxlength = 200, unique = true, compact = false },
    { "email", type = 'email' },
    { "age", type = 'integer', max = 100, min = 10 },
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

-- 初始化 User 数据
User:create { username = 'admin', password = 'password' }
User:create { username = 'user', password = 'password' }

-- 初始化 Blog 数据
Blog:insert { name = 'First Blog', tagline = 'Welcome to my blog' }:exec()
Blog:insert { name = 'Second Blog', tagline = 'Another interesting blog' }:exec()

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
