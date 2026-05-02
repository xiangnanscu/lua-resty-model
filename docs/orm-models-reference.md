# 文档示例数据模型 (Reference Schema)

本仓库的 ORM 文档共享同一套示例模型，其它文档（`orm-query-basics.md` / `orm-query-advanced.md` / `orm-expressions.md` / `orm-model-definition.md`）的所有 SQL 示例均假设以下模型已经定义。

---

## 1. 模型清单

| 模型        | 表名        | 用途                                             |
| ----------- | ----------- | ------------------------------------------------ |
| `Blog`      | `blog`      | 博客主表，演示基础 CRUD、`unique` 字段           |
| `BlogBin`   | `blog_bin`  | 通过 `mixins = { Blog }` 演示混入与字段覆盖      |
| `Resume`    | `resume`    | 抽象/无主键的子模型，作为 `Author.resume` 的结构 |
| `Author`    | `author`    | 含 `email`、`integer`、`json`、`table` 字段      |
| `Entry`     | `entry`     | 通过 `blog_id` 演示外键 / 反向外键 / 多外键      |
| `ViewLog`   | `view_log`  | 演示多级嵌套外键查询                             |
| `Publisher` | `publisher` | `Book` 的关联表                                  |
| `Book`      | `book`      | 演示聚合、F 表达式、跨表 join                    |
| `Store`     | `store`     | 演示 `Model(opts)` 简写（自带 `id/ctime/utime`） |

---

## 2. 完整定义

```lua
local Model = require("model")

-- Model 的全局配置（仅展示，实际项目通常放在初始化模块）
Model.db_config = {
  DATABASE = 'test',
  USER     = 'postgres',
  PASSWORD = 'postgres',
}
Model.auto_primary_key = true   -- 默认即为 true，自动添加 id

---------------------------------------------------------------------
-- 1) Blog —— 基础模型，name 唯一
---------------------------------------------------------------------
local Blog = Model:create_model {
  table_name = 'blog',
  fields = {
    { "name",    maxlength = 20, minlength = 2, unique = true, compact = false },
    { "tagline", type = 'text',  default = 'default tagline' },
  }
}

---------------------------------------------------------------------
-- 2) BlogBin —— 通过 mixins 复用 Blog 的字段，并覆盖 name.unique
---------------------------------------------------------------------
local BlogBin = Model:create_model {
  table_name = 'blog_bin',
  mixins = { Blog },
  fields = {
    { "name", unique = false },     -- 覆盖 Blog.name 的 unique 属性
    { "note", type = 'text' },      -- 新增字段
  }
}

---------------------------------------------------------------------
-- 3) Resume —— 用作 Author.resume (table 字段) 的子模型
--    auto_primary_key = false 关闭自增主键
--    unique_together  联合唯一约束
---------------------------------------------------------------------
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

---------------------------------------------------------------------
-- 4) Author —— 演示 email / integer / json / table 字段
---------------------------------------------------------------------
local Author = Model:create_model {
  table_name = 'author',
  fields = {
    { "name",    maxlength = 200, unique = true, compact = false },
    { "email",   type = 'email' },
    { "age",     type = 'integer', max = 100, min = 10 },
    { "payload", type = 'json' },
    { "resume",  model = Resume },                    -- 结构化 jsonb (table 字段)
  }
}

---------------------------------------------------------------------
-- 5) Entry —— 同模型多外键 (blog_id 与 reposted_blog_id 都指向 Blog)
---------------------------------------------------------------------
local Entry = Model:create_model {
  table_name = 'entry',
  fields = {
    { 'blog_id',             reference = Blog, related_query_name = 'entry' },
    { 'reposted_blog_id',    reference = Blog, related_query_name = 'reposted_entry' },
    { "headline",            maxlength = 255, compact = false },
    { "body_text",           type = 'text' },
    { "pub_date",            type = 'date' },
    { "mod_date",            type = 'date' },
    { "number_of_comments",  type = 'integer' },
    { "number_of_pingbacks", type = 'integer' },
    { "rating",              type = 'integer' },
  }
}

---------------------------------------------------------------------
-- 6) ViewLog —— 演示多级 JOIN: ViewLog -> Entry -> Blog
---------------------------------------------------------------------
local ViewLog = Model:create_model {
  table_name = 'view_log',
  fields = {
    { 'entry_id', reference = Entry },
    { "ctime",    type = 'datetime' },
  }
}

---------------------------------------------------------------------
-- 7) Publisher —— Book 的关联表
---------------------------------------------------------------------
local Publisher = Model:create_model {
  table_name = 'publisher',
  fields = {
    { "name", maxlength = 300 },
  }
}

---------------------------------------------------------------------
-- 8) Book —— 演示聚合 / F 表达式 / 多外键
---------------------------------------------------------------------
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

---------------------------------------------------------------------
-- 9) Store —— 用 Model(...) 简写 (自动 mixin BaseModel: id/ctime/utime)
---------------------------------------------------------------------
local Store = Model {
  table_name = 'store',
  fields = {
    { "name", maxlength = 300 },
  }
}
```

---

## 3. 关键关系图

```
Blog ────┐                           Resume (无主键, 联合唯一)
         │ 1                               ▲
         │                                 │ json 嵌入 (table 字段)
         │ N                          Author ───┐
       Entry ──── N : 1 ── Blog (reposted_blog_id)
         │ 1
         │
         │ N
       ViewLog
                                     Publisher
                                       ▲ 1
                                       │
                                       │ N
                                       Book ── N : 1 ── Author
```

- `Entry.blog_id` (related_query_name=`entry`) → `Blog`
- `Entry.reposted_blog_id` (related_query_name=`reposted_entry`) → `Blog`
- `ViewLog.entry_id` → `Entry`
- `Book.author` → `Author`，`Book.publisher_id` → `Publisher`
- `Author.resume` 为 `table` 字段，存为 `jsonb`，结构由 `Resume` 校验

---

## 4. BaseModel 默认字段

非抽象模型如果不显式设置 `auto_primary_key = false`，会自动追加：

| 字段    | 类型             | 说明                                             |
| ------- | ---------------- | ------------------------------------------------ |
| `id`    | `integer serial` | 主键（自增）                                     |
| `ctime` | `datetime`       | `auto_now_add = true`，由 `ngx.localtime()` 填充 |
| `utime` | `datetime`       | `auto_now = true`，每次 update 时刷新            |

`Model(opts)` 是 `Model:mix(BaseModel, opts)` 的简写：会显式混入这三个字段。`Model:create_model(opts)` 也会自动添加 `id`（除非手动指定 `primary_key`），但不会添加 `ctime/utime`。`Resume` 通过 `auto_primary_key = false` 关闭了主键自动注入。
