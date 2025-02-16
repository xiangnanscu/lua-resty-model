local Model = require("resty.model")
local Q = Model.Q
local F = Model.F
local Sum = Model.Sum
local Avg = Model.Avg
local Max = Model.Max
local Min = Model.Min
local Count = Model.Count


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

Book:where { price = 100 }
Book:where { price__gt = 100 }
Book:where(-Q { price__gt = 100 })
Book:where(Q { price__gt = 100 } / Q { price__lt = 200 })
Book:where(-(Q { price__gt = 100 } / Q { price__lt = 200 }))
Book:where(Q { id = 1 } * (Q { price__gt = 100 } / Q { price__lt = 200 }))
Entry:where { blog_id = 1 }
Entry:where { blog_id__id = 1 }
Entry:where { blog_id__gt = 1 }
Entry:where { blog_id__id__gt = 1 }
Entry:where { blog_id__name = 'my blog name' }
Entry:where { blog_id__name__contains = 'my blog' }
ViewLog:where { entry_id__blog_id = 1 }
ViewLog:where { entry_id__blog_id__id = 1 }
ViewLog:where { entry_id__blog_id__name = 'my blog name' }
ViewLog:where { entry_id__blog_id__name__startswith = 'my' }
ViewLog:where { entry_id__blog_id__name__startswith = 'my', entry_id__headline = 'aa' }
-- reversed foreignkey
Blog:where { entry = 1 }
Blog:where { entry__id = 1 }
Blog:where { entry__rating = 1 }
Blog:where { entry__view_log = 1 }
Blog:where { entry__view_log__ctime__year = 2025 }
Blog:where(Q { entry__view_log = 1 } / Q { entry__view_log = 2 })
-- group by
Book:group_by { 'name' }:annotate { price_total = Sum('price') }
-- annotate + aggregate
Book:annotate { price_total = Sum('price') }
Book:annotate { Sum('price') }
-- annotate + aggregate + group by
Book:group_by { 'name' }:annotate { price_total = Sum('price') }
Book:group_by { 'name' }:annotate { Sum('price') }
-- annotate + aggregate + group by + having
Book:group_by { 'name' }:annotate { Sum('price') }:having { price_sum__gt = 100 }
Book:group_by { 'name' }:annotate { price_total = Sum('price') }:having { price_total__gt = 100 }
-- annotate + aggregate + group by + having + order by
Book:group_by { 'name' }:annotate { price_total = Sum('price') }:having { price_total__gt = 100 }:order_by { '-price_total' }
-- F expression
Book:annotate { double_price = F('price') * 2 }
Book:annotate { price_per_page = F('price') / F('pages') }
-- annotate  + reverse foreignkey
Blog:annotate { entry_count = Count('entry') }

-- update
Blog:update { name = F('name') .. ' updated' }
Entry:where { headline = F('blog_id__name') }
Entry:update { rating = F('rating') + 1 }
Entry:update { headline = F('blog_id__name') }
-- json field search
Author:where { resume__has_key = 'start_date' }
Author:where { resume__0__has_keys = { 'a', 'b' } }
Author:where { resume__has_any_keys = { 'a', 'b' } }
Author:where { resume__start_date__time = '12:00:00' }
Author:where { resume__contains = { start_date = '2025-01-01' } }
Author:where { resume__contained_by = { start_date = '2025-01-01' } }
-- select
ViewLog:where('entry_id__blog_id', 1)
ViewLog:where { entry_id__blog_id__gt = 1 }
Book:order_by('author', '-pubdate'):distinct('author')
Entry:increase('number_of_comments')
Entry:decrease('number_of_comments', 2)
