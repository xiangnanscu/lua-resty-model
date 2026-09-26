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

-- ⚠ 条件里有跨表 lookup 时会自动 JOIN, SELECT * 就带上了被 JOIN 表的列,
--   同名列 (id/ctime/status...) 被 JOIN 表的值覆盖:
local e = Entry:where{ blog_id__name = 'x' }:try_get{ headline = 'h' }
-- SELECT * FROM entry T INNER JOIN blog T1 ON (T.blog_id = T1.id) WHERE ...
-- e.id 是 blog 的 id! 拿它去 update/delete 会改错行。
-- 要用本表 id 时显式 select, 或把跨表条件写成子查询:
Entry:select('id', 'headline'):where{ blog_id__name = 'x' }:try_get{ headline = 'h' }
Entry:where{ blog_id__in = Blog:select('id'):where{ name = 'x' } }:try_get{ headline = 'h' }

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

**NULL 会占位。** `values_list` / `flat` / `as_set` / `dates` / `datetimes` 走的是
compact 结果集（按位置取列），所以 NULL 列一律用 `Model.NULL`（即 `ngx.null`）占位，
行的长度恒等于选中的列数，`flat` 的元素数恒等于 `count()`：

```lua
Entry:order('id'):values_list { 'id', 'rating' }
-- { {1, Model.NULL}, {2, 5}, {3, 4} }   -- 第一行 rating 为 NULL

Entry:order('id'):values_list('rating', { flat = true })
-- { Model.NULL, 5, 4 }                  -- 与同序的 id 列表一一对应
```

判空要用 `v == Model.NULL`，**不能**用 `if v then`：`ngx.null` 是个 userdata，在 Lua 里为真。

**非 compact 路径默认仍然缺键**：`exec()` / `get()` 返回的记录上，值为 NULL 的列是
`nil`（键不存在），这样 `if rec.x then` 这类既有写法不会因为升级而改变判断。需要
让 NULL 也占位（比如要把记录直接 JSON 序列化给前端、希望输出 `null` 而不是字段消失），
在连接配置里打开 `CONVERT_NULL = true` 或 `.env` 的 `PG_CONVERT_NULL=true`。

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

-- 值写 Model.NULL 也是 IS NULL（对齐 Django 的 col=None），不是恒假的 `= NULL`
Entry:where { rating = Model.NULL }:exec()
-- WHERE T.rating IS NULL
Entry:where { rating__ne = Model.NULL }:exec()
-- WHERE T.rating IS NOT NULL

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
>
> **服务器配置前提:** 本 ORM 的字符串字面量转义（`'` → `''`）依赖 PostgreSQL 的
> `standard_conforming_strings = on`（9.1 起的默认值）。请勿在服务器/数据库级把它改为
> `off`——那会让 `\'` 重新具有转义语义，破坏转义的完整性并产生注入面。

```lua
Blog:where("name = 'My Blog'"):exec()
-- WHERE name = 'My Blog'
```

#### 情形 4: 两参数 (字段名 + 值, 默认 =)

```lua
Blog:where("name", "My Blog"):exec()
-- WHERE T.name = 'My Blog'
```

> ⚠️ **值不能是 `nil`**：`where('name', nil)` 与 `where("name = 'x'")` 在 Lua 里
> 长得一模一样（都只有一个非 nil 实参），会被当成情形 3 的裸 SQL 而生成 `WHERE name`
> ——varchar 列 PG 会报类型错误（还能发现），boolean 列则**静默**变成「筛选该列为真的行」。
> 所以两参形式遇到 `nil` 会直接报错，提示改用 `where { name = Model.NULL }`
> 或 `where { name__isnull = true }`。值来自可能为 nil 的变量时，请先判断：
>
> ```lua
> if name ~= nil then q = q:where('name', name) end
> ```
>
> 这条检查对所有条件入口一致生效：`where` / `where_or` / `or_where` / `or_where_or` /
> `exclude`，以及把条件转给 `where` 的 `delete` / `count` / `get` / `try_get`。
> 例如 `Blog:delete('ok', nil)` 以前会生成 `DELETE ... WHERE ok`（删掉所有 ok 为真的行），
> 现在直接报错。
>
> 值写 `Model.NULL` 时与 table 形式一样翻译成 `IS NULL`（不是恒假的 `= NULL`）：
>
> ```lua
> Entry:where('rating', Model.NULL)          -- WHERE T.rating IS NULL
> Entry:where('rating', '=', Model.NULL)     -- WHERE T.rating IS NULL
> Entry:where('rating', '<>', Model.NULL)    -- WHERE T.rating IS NOT NULL（'!=' 同）
> ```
>
> 三参形式只翻译 `=` / `<>` / `!=`；`IS` / `IS NOT` 原样生成（本来就对），
> `>` / `<` 这类与 NULL 比较本身没有意义，也原样生成。

#### 情形 5: 三参数 (字段名 + 运算符 + 值)

```lua
Entry:where("rating", ">", 3):exec()
-- WHERE T.rating > 3

Entry:where("headline", "LIKE", '%lua%'):exec()
-- WHERE T.headline LIKE '%lua%'

-- 第三个参数为 nil 会直接报错（以前会退化成两参形式、把运算符当成值：
-- WHERE T.rating = '>'）。要判空请用 where { rating = Model.NULL } /
-- where { rating__isnull = true }；条件可选时请在外面判断
Entry:where("rating", ">", nil)   -- error: where('rating', '>', nil): value is nil ...

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
| 日期 | `year` | `>= 'yyyy-01-01' AND < 'yyyy+1-01-01'`（半开区间） | 年份（可用索引）。用半开区间而非 `BETWEEN ...-12-31`，否则 timestamp 列会漏掉 12-31 当天 00:00 之后的数据 |
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

> `row` **只接受 `{列 = 值}` 的 table**。裸 SQL 片段（`Blog:update("tagline = 'x'")`）
> 是内部通道，公开方法不提供，传入时报
> `update() expects a table of column = value, got string`；列运算请用 F 表达式
> （见下例）。传 Sql 子查询同样报错，按子查询批量更新请用 `updates(subquery, key)`。

> ⚠️ **不带 WHERE 的 UPDATE / DELETE 会在执行时被拒绝**：
>
> ```
> refuse to run UPDATE without WHERE on table blog: call :allow_full_table() if intended
> ```
>
> 漏写 `:where{}` 是最贵的一类事故，所以默认拦下。确实要作用于全表时显式声明：
>
> ```lua
> Blog:update { tagline = 'reset' }:allow_full_table():exec()
> ```
>
> 两点说明：
>
> - 检查只在**真正执行**（`exec()` / `execr()` 及走它们的终结方法）时进行。
>   `statement()` 只是拼字符串，写操作被当成子查询 / CTE 内嵌进外层语句
>   （`Blog:upsert(BlogBin:update{...}:returning{...})`）时由外层语句负责，都不会被拦。
> - **`delete()` 不传条件本身就是「删全表」的显式写法**（对齐 Django 的 `.all().delete()`），
>   不需要再调 `allow_full_table()`——前提是整条链上**没写过任何条件**。被拦的是
>   `update(row)` 漏条件、`delete(cond)` 的条件解析后为空，以及链上写了 `where` /
>   `exclude` 但条件全空的情况（`delete():where(filter)`、`where(filter):delete()`，
>   `filter` 为 `{}` 或 `Q {}`）。

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

-- 不传条件 = 清空整张表（Django 的 .all().delete() 同义），不需要 allow_full_table()
Blog:delete():exec()
-- DELETE FROM blog T
```

> 「删全表」只认**不传参数**的 `delete()`。传了参数但条件是 `nil`（典型是
> `Blog:delete(params.filter)` 里变量没取到值）会直接报错
> `delete(nil): condition is nil ...`，不会再等同于 `delete()` 把整张表删光：
>
> ```lua
> Blog:delete(params.filter)   -- filter 为 nil：报错
> Blog:delete()                -- 显式删全表
> ```
>
> 条件可选时请在调用前自己判断。
>
> 同理，无参 `delete()` 链上前后的 `where` / `exclude` 条件全空时，执行期同样拒绝，
> 不会把它当成显式删全表：
>
> ```lua
> local filter = params.filter or {}
> Blog:delete():where(filter):exec()   -- filter 为空：refuse to run DELETE without WHERE ...
> Blog:where(filter):delete():exec()   -- 同上
> Blog:delete():where(filter):allow_full_table():exec()  -- 确实要删全表时显式声明
> ```

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
-- 按非主键列匹配时必须显式传 key（Blog 有主键 id，不传 key 会默认用 id 匹配，
-- 而 rows 里没有 id → 抛 "ID不能为空"）
Blog:updates({
  { name = 'Blog 1', tagline = 'Updated 1' },
  { name = 'Blog 2', tagline = 'Updated 2' },
}, 'name'):exec()
-- WITH V(tagline, name) AS (VALUES ...)
-- UPDATE blog T SET tagline = V.tagline, utime = CURRENT_TIMESTAMP FROM V WHERE V.name = T.name

-- 有 id 时可省略 key（默认按主键匹配）
Blog:updates {
  { id = 1, tagline = 'Updated 1' },
  { id = 2, tagline = 'Updated 2' },
}:exec()

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
-- DELETE FROM blog T WHERE (T.name LIKE 'sync\_%' ESCAPE '\') AND (T.name) NOT IN (SELECT name FROM U) RETURNING *
--                          ^^^^ 前置 where 会进入 DELETE，这正是限定删除范围的安全边界
```

> ⚠️ **align 会删数据，务必先用 where 圈定范围**
>
> 上例的 `:where{ name__startswith = 'sync_' }` **不是可选项**——它决定了 DELETE 的作用域。
> 省略前置 where 时，`DELETE ... WHERE key NOT IN (SELECT key FROM U)` 会作用于**整张表**，
> 把所有不在本次 rows 里的存量行全部删除。
>
> 另注：当对齐列只有键列（`columns` 与 `key` 重合）时，实现会用
> `ON CONFLICT ... DO UPDATE SET <key> = EXCLUDED.<key>` 的空更新而非 `DO NOTHING`——
> 因为 PG 规定 `DO NOTHING` 跳过的冲突行**不出现在 RETURNING 中**，
> 若走 DO NOTHING，CTE `U` 只含新插入行，随后的 DELETE 会把已存在行全部误删。

---

## 快捷检索方法

### Sql:get(cond?, op?, dval?)

获取单条记录，不存在返回 `false`：

> ⚠️ **命中多行时同样返回 `false`**，与「不存在」用的是同一个返回值。实现是
> `limit(2)` 之后只在 `#records == 1` 时返回记录，所以下面这个常见写法在数据
> 已经重复时会**越修越多**：
>
> ```lua
> local r = Blog:get { name = n }
> if not r then Blog:create { name = n } end  -- ⚠️ 重复数据下又插一条
> ```
>
> 需要区分两种情况就别用 `get()`：
>
> ```lua
> local rows = Blog:where { name = n }:limit(2):exec()
> if #rows == 0 then ... elseif #rows > 1 then error("数据重复: " .. n) end
> ```
>
> 唯一键上的「取不到就建」请用原子的 `get_or_create()`，它靠
> `INSERT ... ON CONFLICT` 保证并发下也只有一条。

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

**签名:** `Sql:get_or_create(params, defaults?, columns?) -> Record, boolean`

获取或创建：如果符合条件的记录存在则返回，否则创建。**原子操作**——底层是单条
`INSERT ... ON CONFLICT (params列) DO UPDATE SET k = EXCLUDED.k RETURNING ..., (xmax = 0)`，
并发下多个请求恰好一个 `created = true`，其余拿到同一条现有记录，不会重复插入。

```lua
local blog, created = Blog:get_or_create(
  { name = 'Blog 1' },                    -- 查找条件
  { tagline = 'default tagline' }          -- 默认值 (仅在创建时使用)
)
-- created = true 表示是新创建的
-- created = false 表示已存在
```

**前提与代价：**

- `params` 的列集合必须命中**唯一约束**（`unique` 字段或 `unique_together`），
  否则 PG 报 `no unique or exclusion constraint matching the ON CONFLICT specification`。
  任意非唯一条件的"找一条"请用 `get()`。
- 已存在时执行的是 no-op 更新（只回写冲突键自身）：不改其它列、不刷新 `auto_now`，
  但仍产生一次行版本写入。高频只读探测场景请直接用 `get()`。
- 校验口径与 `update_or_create` 完全一致：`params + defaults` 先过 `validate_update`
  再过 `prepare_for_db`，`skip_validate()` 可跳过校验（`prepare_for_db` 照常）。
  这意味着字符串同样会被 `compact`/`trim`，所以 `' 张三'` 与 `'张三'` 是同一条，
  json 值会被正确编码，整数字段的 `''` 写成 NULL 而不是让 PG 报 `invalid input syntax`。

### Sql:update_or_create(params, defaults?, columns?)

**签名：** `(params, defaults?, columns?) -> Record, boolean`

按 `params` 查找记录：存在则用 `defaults` 更新（并刷新 `auto_now`），不存在则用
`params + defaults` 创建。返回 `(记录, 是否新建)`。**原子操作**——底层是单条
`INSERT ... ON CONFLICT (params列) DO UPDATE SET defaults列 = EXCLUDED.defaults列 RETURNING ...`。

```lua
local user, created = User:update_or_create(
  { email = 'a@b.com' },                -- 查找键 (必须命中唯一约束)
  { nickname = 'Alice', login_at = ngx.time() }  -- 更新/创建的值
)
-- created = true：新建
-- created = false：已存在且已被 UPDATE
```

与 `get_or_create` 相同的唯一约束前提。`defaults` 为空时退化为 `get_or_create`。
校验按 `validate_update` 语义（只校验提供的值，不回填模型默认值、不检查 required），
可用 `skip_validate()` 跳过。

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

-- 传空数组返回空表（对齐 Django 的 in_bulk([])），不是全集
Blog:in_bulk({})
-- {}
```

> 「id 列表恰好为空」与「不筛选」是两回事：前者应当返回空表。把请求里的 id 列表
> 直接传进来是常见写法，早期版本在列表为空时会把整张表拉回来。

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

> ⚠️ **`exec()` 默认就是 raw 语义**：不显式 `raw(false)` 时，`exec()`/`get()` 返回的是
> **裸字典**（无 RecordClass 元表）——没有 `rec:save()`/`rec:delete()` 这些实例方法，
> 外键/alioss 等字段也不做 `load` 转换，`select_related` 的关联字段以 `fk__col`
> 平铺键返回。需要实例方法时二选一：
>
> ```lua
> local rec = Blog:raw(false):where{id=1}:get()   -- 查询时转换
> local rec = Blog:create_record(Blog:get{id=1})  -- 或事后手动挂元表
> rec:save()
> ```

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

#### 只接受数据，不接受裸 SQL

`meta_query` 的定位就是「把请求参数原样喂进来」，所以入口做了类型白名单：

| 参数                                                            | 只接受                                                     |
| --------------------------------------------------------------- | ---------------------------------------------------------- |
| `where` / `get` / `try_get` / `having`                          | table。数组形式只放行 `{列, 值}` / `{列, 运算符, 值}`      |
| `select` / `order` / `group` / `flat` / `select_related` / `select_related_labels` | 字符串（或字符串数组）                  |
| `limit` / `offset`                                              | 数字或数字字符串                                           |
| `raw` / `compact` / `exists`                                    | 布尔                                                       |
| `distinct`                                                      | 布尔（整体 DISTINCT）或字符串列表（DISTINCT ON）           |

```lua
Blog:meta_query { where = "1=1" }        -- ✗ 报错：raw SQL string is not accepted here
Blog:meta_query { where = { "1=1" } }    -- ✗ 报错：单元素数组解包后还是 where(string)
Blog:meta_query { get   = "1=1" }        -- ✗ 报错
Blog:meta_query { where = { 'rating', '>', 3 } }  -- ✓ 三参形式
Blog:meta_query { where = { rating__gt = 3 } }    -- ✓ 键值对（推荐）
```

`where(string)` 这些裸 SQL 分支在链式 API 上是有意保留的（见「情形 3」），
但不能从**数据通道**到达——否则请求体里的一行字符串就能拼进 SQL。

布尔开关（`raw` / `compact` / `exists` / `distinct`）只有「开」一种调用形态：
值为 `false` 时直接跳过，不会像早期版本那样把 `false` 解包成 `compact(false)`
（那个方法忽略入参，照样把 compact 打开）。

---

## 裸 SQL 入口清单

下面这些入口**不做任何转义**，一律不能接受用户输入。需要把请求参数带进条件，
请走键值对表 / 两参形式 / `Q` 对象 / `Model.as_literal()`：

| 入口                                         | 说明                                      |
| -------------------------------------------- | ----------------------------------------- |
| `where(string)` / `where_or` / `or_where` / `exclude(string)` / `having(string)` | 条件片段原样拼入 |
| `where(function(ctx))` / `select(function)` / `order(function)` | 回调的返回值原样拼入 |
| `from(...)` / `using(...)`                   | 表名/子句原样拼入                         |
| `with(name, string)` / `with_recursive(name, string)` | CTE 定义原样拼入                 |
| `Model.token(s)`                             | 显式声明「这是 SQL token，别加引号」      |
| `exec_statement(stmt)` / `Model.query(stmt)` | 直接执行整条 SQL                          |

转义的安全性还有一条服务器前提：字符串字面量只转义单引号（`'` → `''`），
这隐含要求 `standard_conforming_strings = on`。ORM 现在会在**每条新建连接**上强制
`SET standard_conforming_strings = on`，设不上就拒绝使用这条连接，所以库级/角色级
被改成 `off` 也不会让转义假设失效。
