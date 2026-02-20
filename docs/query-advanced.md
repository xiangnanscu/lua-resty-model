# 高级查询

## 数据模型参考

```lua
local Blog = Model:create_model {
  table_name = 'blog',
  fields = {
    { "name",    maxlength = 20, unique = true, compact = false },
    { "tagline", type = 'text',  default = 'default tagline' },
  }
}

local Author = Model:create_model {
  table_name = 'author',
  fields = {
    { "name",  maxlength = 200, unique = true },
    { "email", type = 'email' },
    { "age",   type = 'integer', max = 100, min = 10 },
  }
}

local Entry = Model:create_model {
  table_name = 'entry',
  fields = {
    { 'blog_id',             reference = Blog, related_query_name = 'entry' },
    { 'reposted_blog_id',   reference = Blog, related_query_name = 'reposted_entry' },
    { "headline",            maxlength = 255 },
    { "body_text",           type = 'text' },
    { "pub_date",            type = 'date' },
    { "number_of_comments",  type = 'integer' },
    { "rating",              type = 'integer' },
  }
}

local Book = Model:create_model {
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
```

---

## JOIN 查询

Xodel 通过双下划线语法自动推断 JOIN 关系，无需手动写 JOIN。

### 正向外键 JOIN

通过 `外键名__关联字段` 自动 INNER JOIN：

```lua
-- Entry 有 blog_id 外键指向 Blog
Entry:select('headline', 'blog_id__name'):exec()
-- SELECT T.headline, T0.name AS "blog_id__name"
-- FROM entry T INNER JOIN blog T0 ON (T.blog_id = T0.id)

-- WHERE 中也会自动 JOIN
Entry:where { blog_id__name = 'My Blog' }:exec()
-- SELECT * FROM entry T
-- INNER JOIN blog T0 ON (T.blog_id = T0.id)
-- WHERE T0.name = 'My Blog'

-- 多层嵌套 JOIN (ViewLog -> Entry -> Blog)
ViewLog:where { entry_id__blog_id__name = 'My Blog' }:exec()
-- SELECT * FROM view_log T
-- INNER JOIN entry T0 ON (T.entry_id = T0.id)
-- INNER JOIN blog T1 ON (T0.blog_id = T1.id)
-- WHERE T1.name = 'My Blog'
```

### 同模型多外键

当一个模型有多个外键指向同一模型时，用外键名作为前缀区分：

```lua
-- Entry 有 blog_id 和 reposted_blog_id 都指向 Blog
Entry:where { blog_id__name = 'Blog A', reposted_blog_id__name = 'Blog B' }:exec()
-- INNER JOIN blog T0 ON (T.blog_id = T0.id)
-- INNER JOIN blog T1 ON (T.reposted_blog_id = T1.id)
-- WHERE T0.name = 'Blog A' AND T1.name = 'Blog B'
```

### 反向外键 JOIN

通过 `related_query_name` 反向查询：

```lua
-- Blog <- Entry.blog_id (related_query_name = 'entry')
Blog:where { entry__rating__gt = 3 }:exec()
-- SELECT * FROM blog T
-- INNER JOIN entry T0 ON (T.id = T0.blog_id)
-- WHERE T0.rating > 3

-- 反向 + 操作符
Blog:where { entry__headline__contains = 'lua' }:exec()
-- INNER JOIN entry T0 ON (T.id = T0.blog_id)
-- WHERE T0.headline LIKE '%lua%'
```

### 冗余外键后缀

`blog_id__id` 中的 `__id` 是冗余的（因为 blog_id 已经存储了 id），会自动回退：

```lua
Entry:where { blog_id__id = 1 }:exec()
-- 等价于 Entry:where { blog_id = 1 }:exec()
-- WHERE T.blog_id = 1 (不产生 JOIN)
```

### Sql:join_type(jtype)

设置 JOIN 类型（影响后续自动 JOIN），默认 INNER：

```lua
-- LEFT JOIN (允许空关联)
Entry:join_type("LEFT"):where { blog_id__name = 'Blog A' }:exec()
-- LEFT JOIN blog T0 ON (T.blog_id = T0.id) WHERE T0.name = 'Blog A'
```

---

## 关联查询 (Select Related)

### Sql:select_related(fk_name, select_names, ...)

**签名:** `Sql:select_related(fk_name: string, select_names: string[]|string, more_name?: string, ...) -> self`

查询外键关联对象的字段。返回结果中外键字段变为完整对象（调用 `field:load`）。

```lua
-- 选择外键的特定字段
Entry:select_related('blog_id', 'name'):exec()
-- SELECT T.blog_id, T0.name AS "blog_id__name" FROM entry T
-- INNER JOIN blog T0 ON (T.blog_id = T0.id)
-- 返回中 entry.blog_id = { id = 1, name = 'Blog 1' } (对象形式)

-- 选择外键的所有字段
Entry:select_related('blog_id', '*'):exec()
-- SELECT T.blog_id, T0.id AS "blog_id__id", T0.name AS "blog_id__name", ... FROM entry T

-- 选择多个字段
Entry:select_related('blog_id', 'name', 'tagline'):exec()
-- SELECT T.blog_id, T0.name AS "blog_id__name", T0.tagline AS "blog_id__tagline"

-- 数组形式
Entry:select_related('blog_id', {'name', 'tagline'}):exec()

-- 仅关联不选择额外字段
Entry:select_related('blog_id'):exec()
-- SELECT T.blog_id FROM entry T ...
```

### Sql:select_related_labels(names?)

自动查询所有外键的展示列（LEFT JOIN）：

```lua
Entry:select_related_labels():exec()
-- 为每个外键字段自动 LEFT JOIN 并选择 reference_label_column

-- 指定只处理某些字段
Entry:select_related_labels { 'blog_id' }:exec()
```

---

## 聚合与注解

### Sql:annotate(kwargs)

**签名:** `Sql:annotate(kwargs: {[string]:Func|FClass}) -> self`

为查询添加聚合注解。注解名不能与模型字段名冲突。

```lua
local Count = Model.Count
local Sum   = Model.Sum
local Avg   = Model.Avg
local Max   = Model.Max
local Min   = Model.Min

-- 基本聚合
Blog:annotate { entry_count = Count('entry') }:group('name'):exec()
-- SELECT COUNT(T0.id) AS entry_count, T.name
-- FROM blog T LEFT JOIN entry T0 ON (T.id = T0.blog_id)
-- GROUP BY T.name

-- 多个聚合
Book:annotate {
  total_pages = Sum('pages'),
  avg_price   = Avg('price'),
  max_rating  = Max('rating'),
  min_rating  = Min('rating'),
}:group('author'):exec()

-- 数字索引形式 (自动以 column + suffix 命名)
Blog:annotate { Count('entry') }:group('name'):exec()
-- 自动命名为 entry_count (column=entry, suffix=_count)

-- F 表达式注解
Book:annotate { price_per_page = F('price') / F('pages') }:exec()
-- SELECT (T.price / T.pages) AS price_per_page, * FROM book T

-- 跨表聚合 (反向外键)
Blog:annotate { total_comments = Sum('entry__number_of_comments') }:group('name'):exec()
-- LEFT JOIN entry T0 ON (T.id = T0.blog_id)
-- SELECT SUM(T0.number_of_comments) AS total_comments, T.name

-- 配合 HAVING
Blog:annotate { cnt = Count('entry') }:group('name'):having { cnt__gt = 2 }:exec()
-- HAVING COUNT(T0.id) > 2

-- annotate 值可在 where/order 中使用
Blog:annotate { cnt = Count('entry') }:group('name'):where { cnt__lt = 5 }:order('-cnt'):exec()
```

---

## CTE (Common Table Expressions)

### Sql:with(name, token)

**签名:** `Sql:with(name: string, token: string|Sql) -> self`

```lua
-- 字符串形式的 CTE
Blog:with('recent_blogs', Blog:select('id', 'name'):where{id__gt=5})
  :from('recent_blogs'):select('name'):exec()
-- WITH recent_blogs AS (SELECT T.id, T.name FROM blog T WHERE T.id > 5)
-- SELECT name FROM recent_blogs

-- 多个 CTE
Blog:with('cte1', Blog:select('id'):where{id__gt=5})
  :with('cte2', Entry:select('blog_id'):where{rating__gt=3})
  :select('id'):exec()
```

### Sql:with_recursive(name, token)

**签名:** `Sql:with_recursive(name: string, token: string|Sql) -> self`

递归 CTE（用于树结构查询）：

```lua
-- 手动构建递归 CTE
local seed = Category:create_sql():select('id', 'parent_id'):where { parent_id = 1 }
local recursive = Category:create_sql():select('id', 'parent_id')
local join_cond = "T.parent_id = cat_tree.id"
recursive:_base_join('INNER', 'cat_tree', join_cond)
Category:with_recursive('cat_tree', seed:union_all(recursive))
  :from('cat_tree AS category'):exec()
```

### Sql:where_recursive(name, value, select_names?)

**签名:** `Sql:where_recursive(name: string, value: any, select_names?: string[]) -> self`

快捷递归查询（自引用外键树）：

```lua
-- 假设 Category 有 parent_id 外键指向自身
Category:where_recursive('parent_id', 1):exec()
-- WITH RECURSIVE category_recursive AS (
--   SELECT id, parent_id FROM category T WHERE T.parent_id = 1
--   UNION ALL
--   SELECT id, parent_id FROM category T
--     INNER JOIN category_recursive ON (T.parent_id = category_recursive.id)
-- )
-- SELECT * FROM category_recursive AS category

-- 带额外选择列
Category:where_recursive('parent_id', 1, {'name', 'level'}):exec()
```

### Sql:with_values(name, rows)

**签名:** `Sql:with_values(name: string, rows: Record[]) -> self`

快捷创建 VALUES CTE：

```lua
Blog:with_values('v', { {id=1, name='a'}, {id=2, name='b'} })
  :from('v'):select('v.name'):exec()
-- WITH v(id, name) AS (VALUES (1::integer, 'a'::varchar), (2, 'b'))
-- SELECT v.name FROM v
```

---

## 集合操作

### Sql:union(other_sql) / Sql:union_all(other_sql)

```lua
local q1 = Blog:select('name'):where { id__lt = 5 }
local q2 = Blog:select('name'):where { id__gt = 10 }

-- UNION (去重)
q1:union(q2):exec()
-- (SELECT T.name FROM blog T WHERE T.id < 5) UNION (SELECT T.name FROM blog T WHERE T.id > 10)

-- UNION ALL (不去重)
q1:union_all(q2):exec()
```

### Sql:except(other_sql) / Sql:except_all(other_sql)

```lua
local all_blogs = Blog:select('name')
local excluded  = Blog:select('name'):where { name__contains = 'old' }

all_blogs:except(excluded):exec()
-- (SELECT ...) EXCEPT (SELECT ...)
```

### Sql:intersect(other_sql) / Sql:intersect_all(other_sql)

```lua
local set_a = Blog:select('name'):where { id__lt = 10 }
local set_b = Blog:select('name'):where { id__gt = 5 }

set_a:intersect(set_b):exec()
-- (SELECT ...) INTERSECT (SELECT ...)
```

### 链式集合操作

```lua
local q1 = Blog:select('name'):where{id=1}
local q2 = Blog:select('name'):where{id=2}
local q3 = Blog:select('name'):where{id=3}

q1:union_all(q2):union_all(q3):exec()
-- ((SELECT ...) UNION ALL (SELECT ...)) UNION ALL (SELECT ...)
```

---

## JSON 字段查询

当模型字段类型为 `json`、`table` 或有 `model` 属性时，支持 JSON 路径查询：

```lua
-- Author.resume 是一个 table 字段（存为 jsonb）
-- 假设 resume 的子模型有 company 字段

-- JSON 属性查询
Author:where { resume__company = 'Google' }:exec()
-- WHERE (T.resume #> ['company']) = '"Google"'

-- 嵌套 JSON 属性
Author:where { resume__address__city = 'Beijing' }:exec()
-- WHERE (T.resume #> ['address', 'city']) = '"Beijing"'

-- JSON contains
Author:where { resume__company__contains = 'oo' }:exec()
-- WHERE (T.resume #> ['company']) @> '"oo"'

-- has_key
Author:where { data__has_key = 'email' }:exec()
-- WHERE (T.data) ? 'email'

-- has_keys
Author:where { data__has_keys = {'email', 'phone'} }:exec()
-- WHERE (T.data) ?& ['email', 'phone']

-- has_any_keys
Author:where { data__has_any_keys = {'email', 'phone'} }:exec()
-- WHERE (T.data) ?| ['email', 'phone']

-- json_contains (完整对象匹配)
Author:where { resume__contains = {company='Google'} }:exec()
-- WHERE (T.resume) @> '{"company":"Google"}'

-- contained_by
Author:where { data__contained_by = {a=1, b=2, c=3} }:exec()
-- WHERE (T.data) <@ '{"a":1,"b":2,"c":3}'
```

---

## 子查询

多种 API 支持 Sql 实例作为参数（子查询）。

### WHERE IN 子查询

```lua
Entry:where_in('blog_id',
  Blog:select('id'):where { name__contains = 'lua' }
):exec()
-- WHERE (T.blog_id) IN (SELECT T.id FROM blog T WHERE T.name LIKE '%lua%')
```

### INSERT 子查询

```lua
Blog:insert(
  BlogBin:select{'name', 'tagline'}:where{ name__startswith = 'copy' }
):exec()
-- INSERT INTO blog AS T (name, tagline) SELECT T.name, T.tagline FROM blog_bin T WHERE ...
```

### INSERT FROM CUD 子查询

```lua
Blog:insert(
  BlogBin:update{ tagline = 'moved' }:returning{'name', 'tagline'}
):returning('*'):exec()
-- WITH D(name, tagline) AS (UPDATE blog_bin T SET tagline = 'moved' RETURNING T.name, T.tagline)
-- INSERT INTO blog AS T (name, tagline) SELECT name, tagline FROM D RETURNING *
```

### UPSERT 子查询

```lua
Blog:upsert(
  BlogBin:update{ tagline = 'synced' }:returning{'name', 'tagline'}
):returning{'id', 'name'}:exec()
-- WITH V(name, tagline) AS (UPDATE blog_bin T SET ... RETURNING T.name, T.tagline)
-- INSERT INTO blog AS T (name, tagline) SELECT name, tagline FROM V
-- ON CONFLICT (name) DO UPDATE SET tagline = EXCLUDED.tagline
-- RETURNING T.id, T.name
```

### UPDATES 子查询

```lua
Blog:updates(
  BlogBin:select{'name', 'tagline'}:where{name__contains='sync'}
):exec()
-- WITH V(name, tagline) AS (SELECT T.name, T.tagline FROM blog_bin T WHERE ...)
-- UPDATE blog T SET tagline = V.tagline FROM V WHERE V.name = T.name
```

### F 表达式中的子查询

F 表达式中可以使用 Sql 构建器：

```lua
Entry:where { rating = F('rating') }:exec()
-- WHERE T.rating = T.rating

Entry:update { rating = F('rating') + 1 }:where{id=1}:exec()
-- UPDATE entry T SET rating = T.rating + 1 WHERE T.id = 1
```

---

## 多语句执行

### Sql:prepend(...) / Sql:append(...)

在主 SQL 前后拼接额外语句：

```lua
-- 前置语句
local sql = Blog:select('name')
sql:prepend("SET LOCAL work_mem = '128MB'")
sql:exec()
-- SET LOCAL work_mem = '128MB'; SELECT T.name FROM blog T

-- 追加语句
Blog:select('name')
  :append(Entry:select('headline'))
  :return_all()
  :exec()
-- SELECT T.name FROM blog T; SELECT T.headline FROM entry T
-- return_all() 确保返回所有结果集

-- 同时前置和追加
local sql = Blog:select('name')
sql:prepend("BEGIN")
sql:append("COMMIT")
sql:return_all():exec()
```

### Sql:exec_statement(statement)

直接执行 SQL 字符串：

```lua
local results = Blog:create_sql():exec_statement("SELECT 1 AS num")
```

---

## Sql:copy() 与查询复用

```lua
-- 创建基础查询
local base = Blog:where { id__gt = 0 }

-- 复制后各自扩展
local q1 = base:copy():where { name = 'A' }:exec()
local q2 = base:copy():where { name = 'B' }:exec()
-- base 不受影响
```

注意：不使用 `copy()` 的话，链式调用会修改原始对象。
