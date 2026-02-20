# 基础 CRUD 查询

所有 Sql 方法均可通过 Model 代理直接调用，以下示例中 `Blog`、`Entry` 等均为 Model 实例。

## 数据模型参考

以下示例基于此数据模型：

```lua
local Blog = Model:create_model {
  table_name = 'blog',
  fields = {
    { "name",    maxlength = 20, unique = true },
    { "tagline", type = 'text',  default = 'default tagline' },
  }
}

local Entry = Model:create_model {
  table_name = 'entry',
  fields = {
    { 'blog_id',             reference = Blog, related_query_name = 'entry' },
    { "headline",            maxlength = 255 },
    { "body_text",           type = 'text' },
    { "pub_date",            type = 'date' },
    { "number_of_comments",  type = 'integer' },
    { "rating",              type = 'integer' },
  }
}
```

---

## SELECT 查询

### Sql:select(...)

**签名:** `Sql:select(a, b?, ...) -> self`

选择查询列。支持多种调用形式：

```lua
-- 1. 单个字段名
Blog:select('name'):exec()
-- SELECT T.name FROM blog T

-- 2. 多个字段名（变参）
Blog:select('name', 'tagline'):exec()
-- SELECT T.name, T.tagline FROM blog T

-- 3. 字段名数组
Blog:select({'name', 'tagline'}):exec()
-- SELECT T.name, T.tagline FROM blog T

-- 4. 回调函数 (用于 JOIN 上下文)
Blog:select(function(ctx)
  return ctx[1].name    -- ctx[1] 是主表
end):exec()

-- 5. 链式追加 (多次调用会追加, 不会覆盖)
Blog:select('name'):select('tagline'):exec()
-- SELECT T.name, T.tagline FROM blog T

-- 6. 默认选择: 不调用 select 则为 SELECT *
Blog:where{id=1}:exec()
-- SELECT * FROM blog T WHERE T.id = 1

-- 7. 跨表字段 (自动 JOIN, 详见高级查询)
Entry:select('blog_id__name'):exec()
-- SELECT T0.name AS "blog_id__name" FROM entry T INNER JOIN blog T0 ON ...
```

### Sql:select_as(kwargs, as?)

**签名:** `Sql:select_as(kwargs: {[string]:string}|string, as?: string) -> self`

选择列并重命名：

```lua
-- 1. 字典形式
Blog:select_as { name = 'blog_name', tagline = 'blog_tagline' }:exec()
-- SELECT T.name AS "blog_name", T.tagline AS "blog_tagline" FROM blog T

-- 2. 双参数形式
Blog:select_as('name', 'blog_name'):exec()
-- SELECT T.name AS "blog_name" FROM blog T
```

### Sql:select_literal(...)

**签名:** `Sql:select_literal(a, b?, ...) -> self`

选择字面量值（不做列名解析）：

```lua
Blog:select('name'):select_literal(1):exec()
-- SELECT T.name, 1 FROM blog T

Blog:select_literal('hello', 42, true):exec()
-- SELECT 'hello', 42, TRUE FROM blog T
```

### Sql:select_literal_as(kwargs)

**签名:** `Sql:select_literal_as(kwargs: {string:string}) -> self`

选择字面量并命名：

```lua
Blog:select('name'):select_literal_as { ['hello'] = 'greeting' }:exec()
-- SELECT T.name, 'hello' AS "greeting" FROM blog T
```

---

## WHERE 条件

### Sql:where(cond, op?, dval?)

**签名:** `Sql:where(cond: table|string|function, op?: string, dval?: DBValue) -> self`

核心条件 API，多次调用以 AND 连接。

#### 情形 1: 键值对表 (最常用)

```lua
-- 等值条件
Blog:where { name = 'My Blog' }:exec()
-- WHERE T.name = 'My Blog'

-- 多条件 (AND)
Entry:where { blog_id = 1, rating = 5 }:exec()
-- WHERE T.blog_id = 1 AND T.rating = 5

-- 操作符后缀
Entry:where { rating__gt = 3 }:exec()
-- WHERE T.rating > 3

Entry:where { headline__contains = 'lua' }:exec()
-- WHERE T.headline LIKE '%lua%' ESCAPE '\'

Entry:where { rating__in = {3, 4, 5} }:exec()
-- WHERE T.rating IN (3, 4, 5)

Entry:where { pub_date__range = {'2023-01-01', '2023-12-31'} }:exec()
-- WHERE T.pub_date BETWEEN '2023-01-01' AND '2023-12-31'

Entry:where { rating__null = true }:exec()
-- WHERE T.rating IS NULL

-- 跨表查询 (自动 JOIN)
Entry:where { blog_id__name = 'My Blog' }:exec()
-- INNER JOIN blog T0 ON T.blog_id = T0.id WHERE T0.name = 'My Blog'

-- 反向外键查询
Blog:where { entry__rating__gt = 3 }:exec()
-- INNER JOIN entry T0 ON T.id = T0.blog_id WHERE T0.rating > 3

-- JSON 字段查询
Author:where { resume__company = 'Google' }:exec()
-- WHERE (T.resume #> ['company']) = '"Google"'
```

#### 情形 2: Q 对象 (复合逻辑)

```lua
local Q = Model.Q

-- OR 条件
Blog:where(Q{name='Blog A'} / Q{name='Blog B'}):exec()
-- WHERE (T.name = 'Blog A') OR (T.name = 'Blog B')

-- NOT 条件
Blog:where(-Q{name='Blog A'}):exec()
-- WHERE NOT (T.name = 'Blog A')

-- 复合
Blog:where(Q{name='A'} * Q{tagline__contains='lua'} / -Q{id__gt=10}):exec()
-- WHERE ((name = 'A') AND (tagline LIKE '%lua%')) OR (NOT (id > 10))
```

#### 情形 3: 原始 SQL 字符串

```lua
Blog:where("name = 'My Blog'"):exec()
-- WHERE name = 'My Blog'
```

#### 情形 4: 两参数 (字段名 + 值, 默认 =)

```lua
Blog:where("name", "My Blog"):exec()
-- WHERE T.name = 'My Blog'
```

#### 情形 5: 三参数 (字段名 + 运算符 + 值)

```lua
Entry:where("rating", ">", 3):exec()
-- WHERE T.rating > 3

Entry:where("headline", "LIKE", '%lua%'):exec()
-- WHERE T.headline LIKE '%lua%'
```

#### 情形 6: 回调函数 (JOIN 上下文)

```lua
Blog:where(function(ctx)
  return ctx[1].name .. " = 'My Blog'"
end):exec()
```

#### 多次调用 (AND 链接)

```lua
Entry:where{ blog_id = 1 }:where{ rating__gt = 3 }:exec()
-- WHERE (T.blog_id = 1) AND (T.rating > 3)
```

### Sql:where_or(cond, op?, dval?)

表内条件用 OR 连接，多次调用仍用 AND 连接：

```lua
Entry:where_or { blog_id = 1, rating = 5 }:exec()
-- WHERE T.blog_id = 1 OR T.rating = 5

Entry:where_or{ blog_id = 1, rating = 5 }:where_or{ headline__contains = 'lua' }:exec()
-- WHERE (T.blog_id = 1 OR T.rating = 5) AND (T.headline LIKE '%lua%')
```

### Sql:or_where(cond, op?, dval?)

与前一个 WHERE 用 OR 连接：

```lua
Entry:where{ blog_id = 1 }:or_where{ blog_id = 2 }:exec()
-- WHERE T.blog_id = 1 OR T.blog_id = 2
```

### Sql:or_where_or(cond, op?, dval?)

与前一个 WHERE 用 OR 连接，表内条件也用 OR：

```lua
Entry:where{ blog_id = 1 }:or_where_or{ rating = 5, headline__contains = 'lua' }:exec()
-- WHERE T.blog_id = 1 OR T.rating = 5 OR T.headline LIKE '%lua%'
```

### Sql:where_in(cols, range)

**签名:** `Sql:where_in(cols: string|string[], range: Sql|table) -> self`

```lua
-- 单列 IN
Entry:where_in('blog_id', {1, 2, 3}):exec()
-- WHERE (T.blog_id) IN (1, 2, 3)

-- 子查询 IN
Entry:where_in('blog_id', Blog:select('id'):where{name__contains='lua'}):exec()
-- WHERE (T.blog_id) IN (SELECT T.id FROM blog T WHERE T.name LIKE '%lua%')

-- 多列 IN
Entry:where_in({'blog_id', 'rating'}, {{1, 5}, {2, 4}}):exec()
-- WHERE (T.blog_id, T.rating) IN ((1, 5), (2, 4))
```

### Sql:where_not_in(cols, range)

```lua
Entry:where_not_in('blog_id', {1, 2}):exec()
-- WHERE (T.blog_id) NOT IN (1, 2)
```

---

## ORDER BY

### Sql:order(...) / Sql:order_by(...)

**签名:** `Sql:order(a: string|table|function, ...) -> self`

`-` 前缀表示 DESC，默认 ASC：

```lua
-- 单字段升序
Blog:order('name'):exec()
-- ORDER BY T.name ASC

-- 单字段降序
Blog:order('-name'):exec()
-- ORDER BY T.name DESC

-- 多字段
Entry:order('blog_id', '-rating'):exec()
-- ORDER BY T.blog_id ASC, T.rating DESC

-- 数组
Entry:order({'-rating', 'pub_date'}):exec()
-- ORDER BY T.rating DESC, T.pub_date ASC

-- 回调函数
Entry:order(function(ctx)
  return ctx[1].rating .. " DESC"
end):exec()
```

### Sql:nulls_first() / Sql:nulls_last()

控制 NULL 排序位置（需在 `order` 之前调用）：

```lua
Entry:nulls_last():order('-rating'):exec()
-- ORDER BY T.rating DESC NULLS LAST

Entry:nulls_first():order('pub_date'):exec()
-- ORDER BY T.pub_date ASC NULLS FIRST
```

---

## GROUP BY / HAVING

### Sql:group(...) / Sql:group_by(...)

**签名:** `Sql:group(a: string, ...) -> self`

GROUP BY 会自动将分组列加入 SELECT：

```lua
Blog:group('name'):exec()
-- SELECT T.name FROM blog T GROUP BY T.name

-- 配合聚合
Blog:annotate{cnt=Count('entry')}:group('name'):exec()
-- SELECT COUNT(T0.id) AS cnt, T.name FROM blog T LEFT JOIN entry T0 ON ... GROUP BY T.name
```

### Sql:having(cond)

**签名:** `Sql:having(cond: {[string]:DBValue}|QClass) -> self`

需配合 `annotate` 使用，条件中的列名为 annotate 的别名：

```lua
Blog:annotate{cnt=Count('entry')}:group('name'):having{cnt__gt=2}:exec()
-- HAVING COUNT(T0.id) > 2

-- 使用 Q 对象
Blog:annotate{cnt=Count('entry')}:group('name')
  :having(Q{cnt__gt=1} / Q{cnt__lt=10}):exec()
-- HAVING (COUNT(T0.id) > 1) OR (COUNT(T0.id) < 10)
```

---

## LIMIT / OFFSET

### Sql:limit(n)

```lua
Blog:limit(10):exec()
-- LIMIT 10

Blog:limit('5'):exec()  -- 字符串自动转数字
-- LIMIT 5
```

限制: n 必须是 1 到 `Sql.MAX_LIMIT`(默认 10000) 之间的正整数。

### Sql:offset(n)

```lua
Blog:offset(20):exec()
-- OFFSET 20

Blog:limit(10):offset(20):exec()
-- LIMIT 10 OFFSET 20
```

---

## DISTINCT

### Sql:distinct(...)

```lua
-- DISTINCT (无参数)
Blog:select('name'):distinct():exec()
-- SELECT DISTINCT T.name FROM blog T

-- DISTINCT ON
Entry:distinct('blog_id'):select('headline'):order('blog_id'):exec()
-- SELECT DISTINCT ON(T.blog_id) T.headline FROM entry T ORDER BY T.blog_id ASC
```

### Sql:distinct_on(...)

自动将 DISTINCT ON 列 prepend 到 ORDER BY (PG 要求 DISTINCT ON 列必须在 ORDER BY 前面)：

```lua
Entry:distinct_on('blog_id'):select('headline'):exec()
-- SELECT DISTINCT ON(T.blog_id) T.headline FROM entry T ORDER BY T.blog_id
```

---

## INSERT

### Sql:insert(rows, columns?)

**签名:** `Sql:insert(rows: Record|Record[]|Sql, columns?: string[]) -> self`

插入操作，默认会进行数据校验。

#### 单行插入

```lua
Blog:insert { name = 'Blog 1', tagline = 'Hello' }:exec()
-- INSERT INTO blog AS T (name, tagline) VALUES ('Blog 1', 'Hello')
```

#### 批量插入

```lua
Blog:insert {
  { name = 'Blog 1', tagline = 'Hello' },
  { name = 'Blog 2', tagline = 'World' },
}:exec()
-- INSERT INTO blog AS T (name, tagline) VALUES ('Blog 1', 'Hello'), ('Blog 2', 'World')
```

#### 子查询插入

```lua
-- 从另一个表的查询结果插入
Blog:insert(
  BlogBin:select{'name', 'tagline'}:where{name__contains='copy'}
):exec()
-- INSERT INTO blog AS T (name, tagline) SELECT T.name, T.tagline FROM blog_bin T WHERE ...
```

#### 配合 RETURNING

```lua
local result = Blog:insert{ name='Blog 1' }:returning('*'):exec()
-- INSERT INTO blog AS T (name, tagline) VALUES (...) RETURNING *
-- result[1] = { id=..., name='Blog 1', tagline='...', ctime=..., utime=... }

local ids = Blog:insert{
  { name = 'A' }, { name = 'B' }
}:returning('id'):exec()
-- result = { {id=1}, {id=2} }
```

#### 跳过校验

```lua
Blog:skip_validate():insert{ name = 'Blog 1' }:exec()
```

#### 指定列

```lua
Blog:insert({ name = 'Blog 1', tagline = 'hi' }, {'name'}):exec()
-- 只插入 name 列
```

---

## UPDATE

### Sql:update(row, columns?)

**签名:** `Sql:update(row: Record, columns?: string[]) -> self`

更新操作，通常配合 `where` 使用。默认会进行校验。

```lua
-- 基本更新
Blog:update{ tagline = 'new tagline' }:where{ name = 'Blog 1' }:exec()
-- UPDATE blog T SET tagline = 'new tagline', utime = CURRENT_TIMESTAMP WHERE T.name = 'Blog 1'

-- F 表达式更新
Entry:update{ rating = F('rating') + 1 }:where{ blog_id = 1 }:exec()
-- UPDATE entry T SET rating = T.rating + 1 WHERE T.blog_id = 1

-- 带 RETURNING
local updated = Blog:update{ tagline = 'new' }:where{ name = 'Blog 1' }:returning('*'):exec()
```

### Sql:increase(name, amount?)

**签名:** `Sql:increase(name: string|table, amount?: number) -> self`

字段自增（基于 F 表达式）：

```lua
-- 单字段自增 1
Entry:increase('rating'):where{ id = 1 }:exec()
-- UPDATE entry T SET rating = T.rating + 1 WHERE T.id = 1

-- 单字段自增指定值
Entry:increase('rating', 5):where{ id = 1 }:exec()
-- UPDATE entry T SET rating = T.rating + 5 WHERE T.id = 1

-- 多字段自增
Entry:increase{ rating = 1, number_of_comments = 2 }:where{ id = 1 }:exec()
-- UPDATE entry T SET rating = T.rating + 1, number_of_comments = T.number_of_comments + 2 WHERE ...
```

### Sql:decrease(name, amount?)

字段自减，用法同 `increase`：

```lua
Entry:decrease('rating'):where{ id = 1 }:exec()
-- UPDATE entry T SET rating = T.rating - 1 WHERE T.id = 1
```

---

## DELETE

### Sql:delete(cond?, op?, dval?)

**签名:** `Sql:delete(cond?: table|string|function, op?: string, dval?: DBValue) -> self`

```lua
-- 带条件删除
Blog:delete { name = 'Old Blog' }:exec()
-- DELETE FROM blog T WHERE T.name = 'Old Blog'

-- 先构建条件再删除
Blog:delete():where { id__lt = 5 }:exec()
-- DELETE FROM blog T WHERE T.id < 5

-- 三参数形式
Blog:delete("id", ">", 100):exec()
-- DELETE FROM blog T WHERE T.id > 100

-- 带 RETURNING
local deleted = Blog:delete{ name = 'Old' }:returning('*'):exec()
```

---

## UPSERT (INSERT ON CONFLICT)

### Sql:upsert(rows, key?, columns?)

**签名:** `Sql:upsert(rows: Record[]|Sql, key?: Keys, columns?: string[]) -> self`

PostgreSQL 的 `INSERT ... ON CONFLICT DO UPDATE`。key 是冲突检测的唯一键。

```lua
-- 单行 upsert (key 自动推断为 unique 字段或 primary_key)
Blog:upsert { name = 'Blog 1', tagline = 'updated tagline' }:exec()
-- INSERT INTO blog AS T (name, tagline) VALUES ('Blog 1', 'updated tagline')
-- ON CONFLICT (name) DO UPDATE SET tagline = EXCLUDED.tagline

-- 批量 upsert
Blog:upsert {
  { name = 'Blog 1', tagline = 'updated' },
  { name = 'New Blog', tagline = 'inserted' },
}:exec()

-- 指定 key
Blog:upsert({ { name = 'Blog 1', tagline = 'hi' } }, 'name'):exec()

-- 复合 key
Config:upsert({ { key = 'a', scope = 'b', value = '1' } }, {'key', 'scope'}):exec()

-- key 列与 columns 完全一致时 → DO NOTHING
Blog:upsert({ { name = 'Blog 1' } }, 'name'):exec()
-- INSERT INTO blog AS T (name) VALUES ('Blog 1') ON CONFLICT (name) DO NOTHING

-- 子查询 upsert
Blog:upsert(
  BlogBin:update{ tagline = 'from bin' }:returning{'name', 'tagline'}
):returning{'id', 'name'}:exec()
```

---

## MERGE (CTE 方式)

### Sql:merge(rows, key?, columns?)

**签名:** `Sql:merge(rows: Record[], key?: Keys, columns?: string[]) -> self`

使用 CTE 实现的 merge 操作：先更新已有行，再插入新行。比 upsert 更安全（避免某些并发问题）。

```lua
Blog:merge {
  { name = 'Blog 1', tagline = 'updated' },
  { name = 'New Blog', tagline = 'inserted' },
}:exec()
-- WITH
--   V(tagline, name) AS (VALUES ('updated'::text, 'Blog 1'::varchar), ('inserted', 'New Blog')),
--   U AS (UPDATE blog W SET tagline = V.tagline FROM V WHERE V.name = W.name
--         RETURNING V.tagline, V.name)
-- INSERT INTO blog AS T (tagline, name)
-- SELECT V.tagline, V.name FROM V LEFT JOIN U AS W ON (V.name = W.name)
-- WHERE W.name IS NULL
```

---

## 批量更新

### Sql:updates(rows, key?, columns?)

**签名:** `Sql:updates(rows: Record[]|Sql, key?: Keys, columns?: string[]) -> self`

通过 CTE VALUES 实现批量更新：

```lua
Blog:updates {
  { name = 'Blog 1', tagline = 'Updated 1' },
  { name = 'Blog 2', tagline = 'Updated 2' },
}:exec()
-- WITH V(tagline, name) AS (VALUES ...)
-- UPDATE blog T SET tagline = V.tagline FROM V WHERE V.name = T.name

-- 子查询作为数据源
Blog:updates(
  BlogBin:select{'name', 'tagline'}:where{name__contains='sync'}
):exec()
```

---

## ALIGN (对齐)

### Sql:align(rows, key?, columns?)

**签名:** `Sql:align(rows: Record[], key?: Keys, columns?: string[]) -> self`

对齐操作: upsert 给定行 + 删除不在给定行中的数据。适合"同步子集"场景。

```lua
-- 确保 blog 表中恰好只有这两条记录 (匹配 name)
Blog:where{ name__startswith = 'sync_' }:align {
  { name = 'sync_1', tagline = 'a' },
  { name = 'sync_2', tagline = 'b' },
}:exec()
-- WITH U AS (INSERT INTO blog ... ON CONFLICT (name) DO UPDATE ... RETURNING name)
-- DELETE FROM blog T WHERE (T.name) NOT IN (SELECT name FROM U) RETURNING *
```

---

## 快捷检索方法

### Sql:get(cond?, op?, dval?)

获取单条记录，不存在返回 `false`：

```lua
local blog = Blog:get { name = 'Blog 1' }
if blog then
  print(blog.name)
end

-- 无条件 (需确保只有一条)
local single = Blog:where{id=1}:get()

-- 两参数
local blog = Blog:get("name", "Blog 1")

-- 三参数
local blog = Entry:get("rating", ">", 4)
```

### Sql:try_get(...)

`get` 的别名，用法完全一致。

### Sql:gets(keys, columns?)

**签名:** `Sql:gets(keys: Record[], columns?: string[]) -> self`

批量按键获取（使用 CTE RIGHT JOIN）：

```lua
local results = Resume:gets {
  { start_date = '2025-01-01', end_date = '2025-01-02', company = 'Company A' },
  { start_date = '2025-01-03', end_date = '2025-02-02', company = 'Company B' },
}:exec()
-- WITH V(start_date, end_date, company) AS (VALUES ...)
-- SELECT * FROM resume T RIGHT JOIN V ON (V.start_date = T.start_date AND ...)
```

### Sql:merge_gets(rows, key, columns?)

合并获取：在 gets 基础上额外返回传入的列：

```lua
Blog:select('name'):merge_gets(
  { { id = 1, name = 'aa' }, { id = 2, name = 'bb' } },
  'id'
):exec()
-- WITH V(id, name) AS (VALUES ...)
-- SELECT T.name, V.* FROM blog T RIGHT JOIN V ON (V.id = T.id)
```

### Sql:filter(kwargs)

`where` + `exec` 的快捷方式：

```lua
local blogs = Blog:filter { name__contains = 'Blog' }
-- 等价于 Blog:where{name__contains='Blog'}:exec()
```

### Sql:count(cond?, op?, dval?)

返回计数：

```lua
-- 无条件计数
local n = Blog:count()

-- 带条件
local n = Entry:count { rating__gt = 3 }

-- 两参数
local n = Entry:count("rating", 5)

-- 三参数
local n = Entry:count("rating", ">", 3)
```

### Sql:exists()

返回布尔值：

```lua
local has = Blog:where{name='Blog 1'}:exists()
-- SELECT EXISTS (SELECT 1 FROM blog T WHERE T.name = 'Blog 1' LIMIT 1)
```

### Sql:flat(col?)

扁平化结果，返回单列值数组：

```lua
-- 指定列
local names = Blog:flat('name')
-- { 'Blog 1', 'Blog 2', ... }

-- CUD 操作的 flat
local ids = Blog:delete{id__lt=5}:flat('id')
-- { 1, 2, 3, 4 }

-- 无参数: 对整行扁平化
local rows = Blog:select('name'):flat()
-- { 'Blog 1', 'Blog 2', ... }
```

### Sql:as_set()

转为 Set（去重集合）：

```lua
local name_set = Blog:select('name'):as_set()
-- Set { 'Blog 1', 'Blog 2' }
```

### Sql:get_or_create(params, defaults?, columns?)

**签名:** `Sql:get_or_create(params, defaults?, columns?) -> XodelInstance, boolean`

获取或创建：如果符合条件的记录存在则返回，否则创建。

```lua
local blog, created = Blog:get_or_create(
  { name = 'Blog 1' },                    -- 查找条件
  { tagline = 'default tagline' }          -- 默认值 (仅在创建时使用)
)
-- created = true 表示是新创建的
-- created = false 表示已存在
```

---

## RETURNING 子句

### Sql:returning(...)

**签名:** `Sql:returning(a, b?, ...) -> self`

用于 INSERT/UPDATE/DELETE，指定返回列：

```lua
-- 返回所有列
Blog:insert{name='A'}:returning('*'):exec()

-- 返回指定列
Blog:insert{name='A'}:returning('id', 'name'):exec()

-- 返回数组
Blog:insert{name='A'}:returning({'id', 'name'}):exec()

-- 跨表列
Entry:delete{id=1}:returning('blog_id__name'):exec()

-- 回调
Blog:insert{name='A'}:returning(function(ctx)
  return ctx[1].name
end):exec()

-- 链式追加
Blog:insert{name='A'}:returning('id'):returning('name'):exec()
```

### Sql:returning_literal(...)

RETURNING 字面量：

```lua
Blog:insert{name='A'}:returning('id'):returning_literal(true):exec()
-- RETURNING T.id, TRUE
```

---

## 执行与输出控制

### Sql:exec()

执行 SQL 并返回结果数组。SELECT 查询默认调用 `field:load` 转换（如外键代理）：

```lua
local blogs = Blog:where{id=1}:exec()
-- blogs 是 Array<XodelInstance>
```

### Sql:execr()

执行并返回原始结果（不调用 `field:load`）：

```lua
local blogs = Blog:where{id=1}:execr()
-- 等价于 Blog:where{id=1}:raw():exec()
```

### Sql:statement()

生成 SQL 字符串（不执行）：

```lua
local sql = Blog:where{id=1}:select('name'):statement()
-- "SELECT T.name FROM blog T WHERE T.id = 1"
```

### Sql:compact()

紧凑模式：返回数组的数组（而非对象的数组），性能更好：

```lua
local result = Blog:select('id', 'name'):compact():exec()
-- { {1, 'Blog 1'}, {2, 'Blog 2'} } 而非 { {id=1, name='Blog 1'}, ... }
```

### Sql:raw(is_raw?)

原始模式：不调用 `field:load` 转换。默认 true：

```lua
Blog:raw():exec()        -- 不转换
Blog:raw(false):exec()   -- 转换 (相当于取消 raw)
```

### Sql:skip_validate(bool?)

跳过插入/更新时的数据校验：

```lua
Blog:skip_validate():insert{name='x'}:exec()
Blog:skip_validate(false):insert{name='y'}:exec()  -- 取消跳过
```

### Sql:return_all()

当使用 `prepend` 或 `append` 时，返回所有结果集（而非仅主查询结果）：

```lua
local all = Blog:select('name'):return_all():exec()
```

### Sql:copy()

复制当前 Sql 构建器（深拷贝）：

```lua
local base = Blog:where{id__gt=0}
local q1 = base:copy():where{name='A'}
local q2 = base:copy():where{name='B'}
```

### Sql:clear()

清空构建器（保留 model 和 table_name）：

```lua
local sql = Blog:where{id=1}:select('name')
sql:clear()  -- 回到初始状态
```

### Sql:prepend(...) / Sql:append(...)

前置/追加额外 SQL 语句：

```lua
local sql = Blog:select('name')
sql:prepend("SET LOCAL work_mem = '64MB'")
sql:append(Entry:select('headline'))
sql:exec()
-- SET LOCAL work_mem = '64MB'; SELECT T.name FROM blog T; SELECT ...
```

---

## 表别名与 FROM

### Sql:as(alias)

```lua
Blog:as('b'):select('name'):exec()
-- SELECT "b".name FROM blog "b"
```

### Sql:from(...)

```lua
Blog:from('blog b'):select('b.name'):exec()
-- SELECT b.name FROM blog b
```

### Sql:get_table()

获取表名（含别名）的 token：

```lua
Blog:get_table()  -- 'blog T'
```

### Sql:using(...)

DELETE 操作的 USING 子句：

```lua
Entry:delete():using('blog'):where("entry.blog_id = blog.id"):exec()
```
