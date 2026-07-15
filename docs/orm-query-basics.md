# 基础 CRUD 查询

所有 Sql 方法均可通过 Model 代理直接调用，以下示例中 `Blog`、`Entry`、`Author`、`Book`、`ViewLog`、`BlogBin` 等均为 Model 实例。

> **示例模型** 见 [orm-models-reference.md](orm-models-reference.md)，全部示例均基于该 schema。

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

### Sql:only(...)

只加载指定字段（覆盖已有的 select）。与 `select(...)` 的区别：`only` 会先清空 `_select`，专用于限定返回列。

```lua
Blog:only('id', 'name'):exec()
-- SELECT T.id, T.name FROM blog T
```

### Sql:defer(...)

加载除指定字段外的所有 model 字段（从 `field_names` 中排除）。适合跳过大字段（如 TEXT/JSON）。

```lua
Blog:defer('tagline', 'body'):exec()
-- SELECT T.id, T.name, ... (不含 tagline 和 body) FROM blog T
```

### Sql:values(...)

返回**字典数组**而非 model 实例（相当于 `select(...) + raw():exec()`）。

```lua
local rows = Blog:values('id', 'name')
-- { {id=1, name='A'}, {id=2, name='B'}, ... }
-- 纯 table，不经过 model 的 load()/create_record()
```

> ⚠️ **alioss 字段 + raw 查询的坑**：`alioss`/`alioss_image` 存的是协议相对 URL（`//host/key`），
> 绝对化（补 `https:`）发生在 `AliossField:load`。`execr()`/`values()`/`raw():exec()` 跳过 load，
> 返回的仍是 `//host/key`。浏览器能按当前页 scheme 解析，但**微信小程序 `<video>`/`<image>`
> 不支持 `//` 开头的 URL**（表现：黑屏、时长 0、图片不显示）。给小程序用的接口要么用 `exec()`，
> 要么手动 `Model.fields.x:load(value)` 补回绝对 URL。

### Sql:values_list(fields, opts?)

返回**元组数组**（每行是个数组）。`opts.flat = true` 时对单列结果展平为一维数组。

```lua
Blog:values_list{'id', 'name'}
-- { {1, 'A'}, {2, 'B'}, ... }

Blog:values_list('name', { flat = true })
-- { 'A', 'B', ... }  -- 等价于 Blog:flat('name')
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
-- WHERE (T.resume -> 'company') = '"Google"'
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

> **安全警告:** 此形式不会对 `cond` 做任何转义，请勿将用户输入直接拼入字符串，否则会导致 SQL 注入。推荐使用键值对表（情形 1）或两参数形式（情形 4）。

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

-- 字段名同样支持双下划线跨表语法 (与 table 形式一致)
ViewLog:where('entry_id__blog_id', 1):exec()
-- INNER JOIN entry T1 ON ... WHERE T1.blog_id = 1
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

### Sql:exclude(cond, op?, dval?)

**签名：** 与 `where` 完全一致。语义为 `WHERE NOT (...)`，等价于 Django 的 `exclude()`。

```lua
-- 排除 rating 为 5 的记录
Entry:exclude{ rating = 5 }:exec()
-- WHERE NOT (T.rating = 5)

-- 多条件：整体取反
Entry:exclude{ blog_id = 1, rating__gt = 3 }:exec()
-- WHERE NOT (T.blog_id = 1 AND T.rating > 3)

-- 与 where 串联
Entry:where{ blog_id = 1 }:exclude{ rating__lt = 3 }:exec()
-- WHERE (T.blog_id = 1) AND (NOT (T.rating < 3))

-- 支持 Q 对象
Entry:exclude(Q{rating=5} / Q{headline__contains='draft'}):exec()
-- WHERE NOT ((T.rating = 5) OR (T.headline LIKE '%draft%'))
```

### 所有字段查询后缀（field lookups）

在 `where` / `exclude` / `filter` 的 table 条件中，`field__op = value` 形式支持以下 `op` 后缀：

| 类别 | 后缀 | 生成的 SQL | 说明 |
|------|------|-----------|------|
| 比较 | `eq`（默认） | `field = value` | 等值 |
| 比较 | `ne` | `field <> value` | 不等 |
| 比较 | `lt` / `lte` / `gt` / `gte` | `<` / `<=` / `>` / `>=` | 大小比较 |
| 集合 | `in` / `notin` | `IN (...)` / `NOT IN (...)` | 列表匹配 |
| 集合 | `range` | `BETWEEN v1 AND v2` | 闭区间（值为 `{v1, v2}`） |
| 字符串 | `contains` / `icontains` | `LIKE '%v%'` / `ILIKE '%v%'` | 包含（i = 不区分大小写） |
| 字符串 | `startswith` / `istartswith` | `LIKE 'v%'` / `ILIKE 'v%'` | 前缀匹配 |
| 字符串 | `endswith` / `iendswith` | `LIKE '%v'` / `ILIKE '%v'` | 后缀匹配 |
| 字符串 | `iexact` | `ILIKE value` | 不区分大小写全匹配（无通配符） |
| 正则 | `regex` / `iregex` | `~ 'pat'` / `~* 'pat'` | PostgreSQL 正则 |
| NULL | `null` / `isnull` | `IS NULL` / `IS NOT NULL` | 值为 `true`/`false` |
| 日期 | `date` | `field::date = v` | 日期部分等值 |
| 日期 | `year` | `BETWEEN 'yyyy-01-01' AND 'yyyy-12-31'` | 年份（范围形式，可用索引） |
| 日期 | `iso_year` | `EXTRACT('isoyear' FROM ...)` | ISO 8601 年（周历） |
| 日期 | `month` / `day` | `EXTRACT('month'/'day' ...)` | 月份 / 日 |
| 日期 | `quarter` | `EXTRACT('quarter' ...)` | 季度（1-4） |
| 日期 | `week` | `EXTRACT('week' ...)` | ISO 周数（1-53） |
| 日期 | `week_day` | `EXTRACT('dow' ...) + 1` | 星期几（**1=Sunday, 7=Saturday**，与 Django 一致） |
| 日期 | `iso_week_day` | `EXTRACT('isodow' ...)` | ISO 星期几（1=Monday, 7=Sunday） |
| 时间 | `time` | `field::time = v` | 时间部分等值 |
| 时间 | `hour` / `minute` / `second` | `EXTRACT(...)` | 时 / 分 / 秒 |
| JSON | `has_key` | `field ? 'k'` | 顶层含某 key |
| JSON | `has_keys` | `field ?& [...]` | 含所有 key |
| JSON | `has_any_keys` | `field ?\| [...]` | 含任一 key |
| JSON | `contains` (在 json/jsonb 字段上) | `field @> '...'` | JSON 包含 |
| JSON | `contained_by` | `field <@ '...'` | 被 JSON 包含 |

**JSON 路径**：键名/数字下标作为中间层时，会被解析为 PG 的 `->` / `#>` 运算符，最末端的 lookup（`eq` / `has_key` / `contains` 等）作用在该子节点上。

- **JSON-原生 lookup**（`eq` / `ne` / `gt` / `gte` / `lt` / `lte` / `contains` / `contained_by` / `has_key` / `has_keys` / `has_any_keys`）：用 `->` / `#>` 提取 `jsonb`，RHS 也按 JSON 字面量编码，PG 走 jsonb-vs-jsonb 比较。
- **文本类 lookup**（`startswith` / `istartswith` / `endswith` / `iendswith` / `contains` 的 LIKE 行为不适用 — 这里 `contains` 仍是 JSON 包含；`icontains` / `iexact` / `regex` / `iregex` / 日期提取系列）：用 `->>` / `#>>` 提取为 `text`，再走对应 SQL 操作符。
- 已识别 lookup 名（`gt` / `startswith` / …）始终被当作终止算子，**不会**当成 JSON 路径段。如果 JSON 里恰好有 key 叫 `gt`，请用 Q / 原始 SQL。

```lua
-- payload 是 json 字段；2 表示数字下标 (json 数组)
Author:where { payload__status = 'active' }       -- (T.payload -> 'status') = '"active"'
Author:where { payload__2__score = 99 }            -- (T.payload #> ARRAY['2','score']) = '99'
Author:where { payload__contains    = { status = 'active' } } -- (T.payload) @> '{"status":"active"}'
Author:where { payload__contained_by = { status = 'active' } } -- (T.payload) <@ '{"status":"active"}'
Author:where { payload__has_key = 'status' }       -- (T.payload) ? 'status'

-- 普通比较 op 直接作用在 JSON 路径上（jsonb 比较，RHS 自动 JSON 编码）
Author:where { payload__score__gt  = 50 }          -- (T.payload -> 'score') > '50'
Author:where { payload__score__lte = 99 }          -- (T.payload -> 'score') <= '99'
Author:where { payload__status__ne = 'active' }    -- (T.payload -> 'status') <> '"active"'

-- 文本类 lookup 自动切 ->>（文本提取），再走 LIKE / ~ / EXTRACT
Author:where { payload__name__startswith = 'Al' }  -- T.payload ->> 'name' LIKE 'Al%' ESCAPE '\'
Author:where { payload__name__iregex     = '^al' } -- T.payload ->> 'name' ~* '^al'

-- resume 是 table 字段（jsonb 数组），下标 0/1/2 选取数组元素
Author:where { resume__0__has_key      = 'start_date' }    -- (T.resume -> '0') ? 'start_date'
Author:where { resume__1__has_keys     = { 'a', 'b' } }    -- (T.resume -> '1') ?& ARRAY['a','b']
Author:where { resume__2__has_any_keys = { 'a', 'b' } }    -- (T.resume -> '2') ?| ARRAY['a','b']
Author:where { resume__1__contains     = { start_date = '2025-01-01' } }
-- (T.resume -> '1') @> '{"start_date":"2025-01-01"}'
```

```lua
-- 一些新增 lookup 的示例
Order:where{ created__week_day = 2 }:exec()    -- 所有周一创建的订单（Django: 1=Sunday，所以 2=Monday）
Order:where{ created__iso_week_day = 1 }:exec() -- ISO: 周一
Log:where{ created__hour = 14 }:exec()          -- 下午 2 点
User:where{ email__iexact = 'FOO@bar.com' }     -- 大小写不敏感精确匹配
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

### Sql:reverse()

翻转当前排序方向（ASC↔DESC，NULLS FIRST↔NULLS LAST）。无排序时无操作。

```lua
Entry:order('-rating', 'pub_date'):reverse():exec()
-- ORDER BY T.rating ASC, T.pub_date DESC

Entry:nulls_last():order('-rating'):reverse():exec()
-- ORDER BY T.rating ASC NULLS FIRST
```

常用于配合 `last()` 或从尾部翻页。

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

#### 子查询插入（SELECT / UPDATE / DELETE）

`insert` 的第一个参数也可以是另一个 `Sql` 实例。如果该子查询是 UPDATE/DELETE 加 `RETURNING`，本 ORM 会自动包成一个 CTE（`WITH D(...) AS (...)`）再 `INSERT ... SELECT ... FROM D`。

```lua
-- 1) 从 SELECT 结果插入
BlogBin:insert(
  Blog:where{ name = 'Second Blog' }:select{'name', 'tagline'}
):exec()

-- 2) 从 SELECT + select_literal 插入（必须显式给出列名，否则 PG 报错）
BlogBin:insert(
  Blog:where{ name = 'First Blog' }
      :select{'name', 'tagline'}
      :select_literal('select from another blog'),
  { 'name', 'tagline', 'note' }    -- 显式列名
):exec()

-- 3) 从 UPDATE + RETURNING 插入；source 表自身也会被更新
BlogBin:insert(
  Blog:update{ name = 'update returning 2' }
      :where{ name = 'update returning' }
      :returning{ 'name', 'tagline' }
      :returning_literal('update from another blog'),
  { 'name', 'tagline', 'note' }
):returning{ 'name', 'tagline', 'note' }:exec()
-- 等价 SQL: WITH D(name, tagline, note) AS (UPDATE blog ... RETURNING ...)
--          INSERT INTO blog_bin AS T (name, tagline, note) SELECT name, tagline, note FROM D
--          RETURNING T.name, T.tagline, T.note

-- 4) 从 DELETE + RETURNING 插入（典型场景：搬运到归档表）
BlogBin:insert(
  Blog:delete{ name = 'delete returning' }
      :returning{ 'name', 'tagline' }
      :returning_literal('deleted from another blog'),
  { 'name', 'tagline', 'note' }
):returning{ 'name', 'tagline', 'note' }:exec()
```

#### 子查询列数与目标列不一致

PostgreSQL 在 `INSERT ... SELECT` 列数与目标列不一致时直接报错。本 ORM 把 SQL 原样下发，不做客户端校验：

```lua
-- 子查询 2 列、目标 1 列 → ERROR: INSERT has more expressions than target columns
BlogBin:insert(
  Blog:where{ name = 'First Blog' }:select{ 'name', 'tagline' },
  { 'name' }
):exec()

-- 子查询 2 列、目标 3 列 → ERROR: INSERT has more target columns than expressions
BlogBin:insert(
  Blog:where{ name = 'First Blog' }:select{ 'name', 'tagline' },
  { 'name', 'tagline', 'note' }
):exec()
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

-- vararg 与 table 等价：以下两行生成的 SQL 完全一致
Blog:insert{ name = 'A' }:returning{'id', 'name'}:statement()
Blog:insert{ name = 'A' }:returning('id', 'name'):statement()
```

> **约定**：`select` / `returning` / `order` / `group` / `distinct` 等接受列名的方法都同时支持 vararg 与 table 两种形式，效果完全一致。文档其余地方按可读性自由选择，不再单独列出对照。

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

**签名:** `Sql:merge(rows: Record[]|Sql, key?: Keys, columns?: string[]) -> self`

使用 CTE 实现的 merge 操作：先更新已有行，再插入新行。比 upsert 更安全（避免某些并发问题），且**不要求目标列上存在数据库唯一约束**（手动 join 匹配）。

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

-- 子查询作为数据源（与 upsert/updates 一致；columns 自动从子查询的 select/returning 提取）
Blog:merge(
  BlogBin:select{ 'name', 'tagline' }:where{ name__contains = 'sync' }, 'name'
):exec()
-- WITH V(name, tagline) AS (SELECT ...), U AS (UPDATE ... RETURNING ...)
-- INSERT INTO blog ... SELECT ... FROM V LEFT JOIN U ... WHERE ... IS NULL
```

**校验语义（重要）：** merge 同时承担插入与更新，整批行统一按 `validate_create` 校验（只校验你**实际传入的列**，未传的列不报必填）。因此它偏 **insert 语义**：

- 传入列里若是空值（`''`/`nil`）且该列有默认值，会被回填为模型默认值——即使该行命中的是"更新已存在行"分支，也会用默认值覆盖旧值。
- 若需**精确更新已存在行**（保留空值、不触发默认值、不做插入），请改用 `updates`。

---

## 批量更新

### Sql:updates(rows, key?, columns?)

**签名:** `Sql:updates(rows: Record[]|Sql, key?: Keys, columns?: string[]) -> self`

通过 CTE VALUES 实现批量更新（仅更新已存在行，不插入）：

```lua
Blog:updates {
  { name = 'Blog 1', tagline = 'Updated 1' },
  { name = 'Blog 2', tagline = 'Updated 2' },
}:exec()
-- WITH V(tagline, name) AS (VALUES ...)
-- UPDATE blog T SET tagline = V.tagline, utime = CURRENT_TIMESTAMP FROM V WHERE V.name = T.name

-- 子查询作为数据源
Blog:updates(
  BlogBin:select{'name', 'tagline'}:where{name__contains='sync'}
):exec()
```

**与 merge 不同的更新语义：**

- **自动刷新 `auto_now`**：与单行 `update` 一致，批量更新也会把 `auto_now` 列置为 `CURRENT_TIMESTAMP`（无需传入该列）。
- **空值不回填默认值**：传入 `''`/`nil` 时保留校验后的空值（非 unique → `''`，unique → `NULL`），**不会**用模型默认值覆盖旧值。
- **默认匹配键优先主键**：不显式传 `key` 时，默认用主键作匹配键；只有无主键的模型才回退到唯一字段。避免误用 payload 中的唯一列（其值是新值，会匹配不到旧行）。如需按非主键列匹配，显式传 `key`。

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

**签名:** `Sql:get_or_create(params, defaults?, columns?) -> ModelInstance, boolean`

获取或创建：如果符合条件的记录存在则返回，否则创建。

```lua
local blog, created = Blog:get_or_create(
  { name = 'Blog 1' },                    -- 查找条件
  { tagline = 'default tagline' }          -- 默认值 (仅在创建时使用)
)
-- created = true 表示是新创建的
-- created = false 表示已存在
```

### Sql:update_or_create(params, defaults?, columns?)

**签名：** `(params, defaults?, columns?) -> ModelInstance, boolean`

按 `params` 查找记录：存在则用 `defaults` 更新，不存在则用 `params + defaults` 创建。返回 `(记录, 是否新建)`。

```lua
local user, created = User:update_or_create(
  { email = 'a@b.com' },                -- 查找键
  { nickname = 'Alice', login_at = ngx.time() }  -- 更新/创建的值
)
-- created = true：新建
-- created = false：已存在且已被 UPDATE
```

**⚠️ 并发提醒：** 与 `get_or_create` 类似，底层是两条 SQL（先 SELECT 再 UPDATE/INSERT），并发下有 race condition。高并发场景请包在 `atomic` classview 里，或改用 `upsert()`。

### Sql:first() / Sql:last()

返回单条记录（或 `nil`）。未设置 `order` 时自动按主键排序（`first` 升序，`last` 降序）。

```lua
Blog:first()                       -- 最小 id 的一条
Blog:order('-pub_date'):first()    -- 最新的一条
Blog:last()                        -- 最大 id 的一条

-- last 会翻转已有 order：
Blog:order('pub_date'):last()      -- ORDER BY pub_date DESC LIMIT 1
```

### Sql:latest(field, ...) / Sql:earliest(field, ...)

按指定字段取最新/最早一条。至少传一个字段，会**清除**之前的 order 并用指定字段排序。

```lua
Entry:latest('pub_date')              -- ORDER BY pub_date DESC LIMIT 1
Entry:latest('pub_date', 'id')        -- ORDER BY pub_date DESC, id DESC LIMIT 1
Entry:earliest('created')             -- ORDER BY created ASC LIMIT 1
```

### Sql:contains(obj)

检查指定对象是否在当前 queryset 中（按主键匹配）：

```lua
if Blog:where{status='active'}:contains(blog) then
  -- blog 的主键存在于 active 博客集中
end
```

### Sql:in_bulk(ids?, field_name?)

按 id 数组批量取，返回 `{id = record}` 字典：

```lua
Blog:in_bulk({1, 2, 3})
-- { [1] = blog1, [2] = blog2, [3] = blog3 }

-- 按其他字段索引
User:in_bulk({'alice', 'bob'}, 'username')
-- { alice = user1, bob = user2 }

-- 不传 ids 则返回全集的字典
Blog:in_bulk()
```

### Sql:none()

返回恒为空的 queryset（`WHERE FALSE`）。用于条件分支统一返回类型：

```lua
local qs = user.is_superuser and Blog or Blog:none()
qs:filter{ status = 'active' }  -- 非管理员返回 []
```

### Sql:all()

返回当前 Sql 构建器的**副本**（等价于 `:copy()`），对齐 Django 的 `QuerySet.all()`。常用于"以一个基础查询为起点，分叉出多条互不影响的过滤链"：

```lua
local base = Blog:where { id__gt = 0 }

local actives  = base:all():filter { status = 'active' }
local archived = base:all():filter { status = 'archived' }
-- base 不会被这两次 filter 污染
```

### Sql:explain(opts?)

返回 PostgreSQL 查询计划。用于分析慢查询：

```lua
local plan = Blog:where{status='active'}:order('-pub_date'):explain{ analyze = true }
-- plan 是 EXPLAIN 输出的每行数组
```

`opts` 支持 `analyze`、`verbose`、`format = "JSON"` 等 PG 选项。

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
-- blogs 是 Array<ModelInstance>
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

---

## 声明式查询

### Sql:meta_query(data)

**签名:** `Sql:meta_query(data: selectArgs) -> table`

通过一个配置表一次性指定多个查询参数，支持的字段包括：`select`、`select_related`、`select_related_labels`、`where`、`order`、`group`、`having`、`limit`、`offset`、`distinct`、`raw`、`compact`、`flat`、`get`、`try_get`、`exists`。

```lua
-- 声明式查询
local results = Blog:meta_query {
  select = { 'name', 'tagline' },
  where = { name__contains = 'Blog' },
  order = { '-name' },
  limit = 10,
}
-- 等价于 Blog:select('name','tagline'):where{name__contains='Blog'}:order('-name'):limit(10):exec()

-- 使用 get
local blog = Blog:meta_query {
  get = { name = 'Blog 1' },
}
-- 等价于 Blog:get{name='Blog 1'}
```
