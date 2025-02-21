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

local db_options = {
  DATABASE = 'test',
  USER = 'postgres',
  PASSWORD = 'postgres',
  DEBUG = function(statement)
    print(statement)
  end,
}
Model.db_options = db_options
Model.auto_primary_key = true


---@class Blog
local Blog = Model {
  table_name = 'blog',
  fields = {
    { "name",   maxlength = 100 },
    { "tagline" },
  }
}

-- define a structured json field from a abstract model
local Resume = Model:create_model {
  fields = {
    { "start_date",  type = 'date' },
    { "end_date",    type = 'date' },
    { "company",     maxlength = 200 },
    { "position",    maxlength = 200 },
    { "description", maxlength = 200 },
  }
}
---@class Author
local Author = Model {
  table_name = 'author',
  fields = {
    { "name",   maxlength = 200 },
    { "email",  type = 'email' },
    { "age",    type = 'integer' },
    { "resume", model = Resume },
  }
}

---@class Entry
local Entry = Model {
  table_name = 'entry',
  fields = {
    { 'blog_id',             reference = Blog, related_query_name = 'entry' },
    { 'reposted_blog_id',    reference = Blog, related_query_name = 'reposted_entry' },
    { "headline",            maxlength = 255 },
    { "body_text" },
    { "pub_date",            type = 'date' },
    { "mod_date",            type = 'date' },
    { "number_of_comments",  type = 'integer' },
    { "number_of_pingbacks", type = 'integer' },
    { "rating",              type = 'integer' },
  }
}

---@class ViewLog
local ViewLog = Model {
  table_name = 'view_log',
  fields = {
    { 'entry_id', reference = Entry },
    { "ctime",    type = 'datetime' },
  }
}

---@class Publisher
local Publisher = Model {
  table_name = 'publisher',
  fields = {
    { "name", maxlength = 300 },
  }
}

---@class Book
local Book = Model {
  table_name = 'book',
  fields = {
    { "name",         maxlength = 300 },
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
