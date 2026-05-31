# 高级查询

> **示例模型** 见 [orm-models-reference.md](orm-models-reference.md)。本文出现的 `Blog` / `Entry` / `Book` / `Author` / `ViewLog` / `BlogBin` / `Publisher` 等均按该 schema 定义。

---

## JOIN 查询

Model 通过双下划线语法自动推断 JOIN 关系，无需手动写 JOIN。

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

### Sql:join_type(jtype)

设置 JOIN 类型（影响后续自动 JOIN），默认 INNER。建议使用 `select_related_labels` 等替代方案：

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

> **⚠️ 陷阱：它不会 SELECT 模型自身字段。** `select_related_labels()` 内部只对每个外键调用 `select_related(fk, label_col)`，即只把「外键列 + 标签列」加入 SELECT。**模型自己的普通字段（name/address/status…）一个都不选**。
>
> ```lua
> -- 错误：结果只有 blog_id 和 blog_id__name，丢失 name/headline 等自身字段
> Entry:select_related_labels():get { id = 1 }
>
> -- 正确：补 :select(Model.field_names) 拉全自身字段
> Entry:select_related_labels():select(Entry.field_names):get { id = 1 }
> ```
>
> 例外：只需少数列的场景，故意写 `:select_related_labels():select('id','name')` 限定列，不是 bug。
> classview 的默认列表查询走 `get_base_sql`，依赖前端传 `query.select` 决定自身列；自定义 handler 里直接调用时务必自己补 `:select(...)`。

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

> **注意（annotate 别名后只能接一个 op）**：`annotate` 注册的别名展开成一段完整 SQL 表达式（`Count(...)` / `F(...) * ...`），它不是一个列，所以无法再 `__` traversal 进去；只允许 0 或 1 个比较 op（`cnt`、`cnt__gte=1`）：
> ```lua
> Blog:annotate{ x = Count('entry') }:where{ x__name__contains = 'a' }  -- error
> -- error: cannot traverse into annotation 'x' on model 'Blog': only a single
> --        trailing operator is allowed, got 'name__contains' ...
> ```
>
> **HAVING 同理**：`having{}` 的 key 只支持 `alias__op` 形态，不接受嵌套：
> ```lua
> :having{ cnt__nope__gte = 1 }  -- error: nested traversal is not supported
> :having{ cnt__bogus     = 1 }  -- error: invalid having operator 'bogus'
> ```

### Sql:alias(kwargs)

**签名：** 与 `annotate` 一致。

与 `annotate` 的唯一区别：**不**把表达式加入 SELECT 列表，只注册别名供后续 `where`/`having`/`order` 引用。用于"只拿它当筛选/排序依据、最终结果不需要这一列"的场景，等价于 Django 的 `alias()`。

```lua
-- 只想筛出评论数 > 5 的博客，但返回的 row 不带 cnt 列
Blog:alias { cnt = Count('entry') }
    :group('name')
    :having { cnt__gt = 5 }
    :exec()
-- SELECT T.name, T.tagline, ... (无 cnt 列)
-- FROM blog T LEFT JOIN entry T0 ...
-- GROUP BY T.name HAVING COUNT(T0.id) > 5
```

### Sql:aggregate(kwargs)

**签名：** `Sql:aggregate(kwargs: {[string]:Func|FClass}) -> table`

**终端方法**（立即执行）。对整个 queryset 计算单行聚合，返回 `{alias = value, ...}` 字典。与 `annotate` 的区别：不需要 `group_by`，也不会每行注解。

```lua
local stats = Book:aggregate {
  total = Count('id'),
  avg_price = Avg('price'),
  max_rating = Max('rating'),
}
-- stats = { total = 120, avg_price = 35.6, max_rating = 5 }

-- 配合 where 做条件聚合
local s = Order:where{ status = 'paid' }:aggregate { total = Sum('amount') }
-- SELECT SUM(T.amount) AS total FROM order T WHERE T.status = 'paid'
-- s = { total = 9876.5 }
```

### Sql:dates(field, kind, order?) / Sql:datetimes(field, kind, order?)

**终端方法**。提取日期/时间字段的**去重值数组**，按 `kind` 截断（`DATE_TRUNC`）。

- `dates`：`kind` 支持 `"year"`, `"month"`, `"week"`, `"day"`，返回 date 数组
- `datetimes`：`kind` 额外支持 `"hour"`, `"minute"`, `"second"`
- `order` 可传 `"ASC"`（默认）或 `"DESC"`

```lua
-- 找出有博文发布的所有月份
Entry:dates('pub_date', 'month')
-- { '2024-01-01', '2024-03-01', '2024-05-01' }（按月去重截断）

-- 日志按小时分桶
Log:where{ level = 'error' }:datetimes('created', 'hour', 'DESC')
-- { '2026-04-18 14:00:00', '2026-04-18 13:00:00', ... }
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

递归 CTE（用于树结构查询）。手动构建较复杂，推荐使用 `where_recursive` 快捷方法：

```lua
-- 手动构建递归 CTE（仅供了解原理）
local seed = Category:create_sql():select('id', 'parent_id'):where { parent_id = 1 }
local recursive = Category:create_sql():select('id', 'parent_id')
  :from('category T INNER JOIN cat_tree ON (T.parent_id = cat_tree.id)')
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

`json` / `table` 字段（以及任何带 `model` 属性的字段）支持 JSON 路径查询。**键名/数字下标**作为中间层时会被翻译为 PostgreSQL 的 `->` 或 `#>` 运算符；最末端的 lookup（默认 `eq`、或 `has_key` / `contains` / `gt` / `startswith` 等）作用在该子节点上。

> **路径段 vs 终止 op**：已知 lookup 名 (`gt`/`lt`/`gte`/`lte`/`ne`/`eq`/`contains`/`startswith`/`regex`/`has_key`/...) 始终被视为终止算子，**不会**被当成 JSON path 段。如果 JSON 里真有 key 叫 `gt`，请用 Q 或原始 SQL 表达。
>
> 提取方式按 op 自动选择：
> - **JSON-原生 op**（jsonb 比较 / 包含 / 键检查）：用 `->` / `#>` 提取 `jsonb`，RHS 走 `encode()` 编成 JSON 字面量，PG 自动隐式 cast 成 jsonb。
> - **文本类 op**（LIKE / regex / EXTRACT 系列）：用 `->>` / `#>>` 提取 `text`，再走对应 SQL 操作符。

### Author 模型示例

```lua
-- payload 是 json 字段
Author:where { payload__status = 'active' }:exec()
-- WHERE (T.payload -> 'status') = '"active"'

-- 数字下标：进入 jsonb 数组的第 2 个元素再读 score 键
Author:where { payload__2__score = 99 }:exec()
-- WHERE (T.payload #> ARRAY['2', 'score']) = '99'

-- 整体包含
Author:where { payload__contains = { status = 'active' } }:exec()
-- WHERE (T.payload) @> '{"status":"active"}'

Author:where { payload__contained_by = { status = 'active' } }:exec()
-- WHERE (T.payload) <@ '{"status":"active"}'

-- 顶层 key 检查
Author:where { payload__has_key = 'status' }:exec()
-- WHERE (T.payload) ? 'status'
```

### 普通比较 op 走 jsonb 比较

```lua
Author:where { payload__score__gt  = 50 }:exec()
-- WHERE (T.payload -> 'score') > '50'

Author:where { payload__score__lte = 99 }:exec()
-- WHERE (T.payload -> 'score') <= '99'

Author:where { payload__status__ne = 'active' }:exec()
-- WHERE (T.payload -> 'status') <> '"active"'

-- 多段 + 比较：用 #> 提取后比较
Author:where { payload__a__b__gt = 1 }:exec()
-- WHERE (T.payload #> ARRAY['a', 'b']) > '1'
```

注意：PG jsonb 比较要求两侧类型一致（数字-数字、字符串-字符串）。如果 JSON 里 `score` 存的是 `"99"`（字符串）而 RHS 给数字 `99`，PG 会报错；这是数据契约问题，不是 ORM bug。

### 文本类 op 切到 `->>` 文本提取

```lua
Author:where { payload__name__startswith = 'Al' }:exec()
-- WHERE T.payload ->> 'name' LIKE 'Al%' ESCAPE '\'

Author:where { payload__name__icontains = 'ALI' }:exec()
-- WHERE T.payload ->> 'name' ILIKE '%ALI%' ESCAPE '\'

Author:where { payload__name__iregex = '^al' }:exec()
-- WHERE T.payload ->> 'name' ~* '^al'

-- 多段 + 文本 op
Author:where { payload__a__b__startswith = 'x' }:exec()
-- WHERE T.payload #>> ARRAY['a', 'b'] LIKE 'x%' ESCAPE '\'
```

### table 字段（结构化 jsonb 数组）

`Author.resume` 是 `table` 字段，存为 `jsonb` 数组（每个元素由 `Resume` 子模型校验）。下标 `0`、`1`、`2`…按数组位置访问。

```lua
Author:where { resume__0__has_key      = 'start_date' }:exec()
-- WHERE (T.resume -> '0') ? 'start_date'

Author:where { resume__1__has_keys     = { 'a', 'b' } }:exec()
-- WHERE (T.resume -> '1') ?& ARRAY['a', 'b']

Author:where { resume__2__has_any_keys = { 'a', 'b' } }:exec()
-- WHERE (T.resume -> '2') ?| ARRAY['a', 'b']

Author:where { resume__1__contains     = { start_date = '2025-01-01' } }:exec()
-- WHERE (T.resume -> '1') @> '{"start_date":"2025-01-01"}'

Author:where { resume__2__contained_by = { start_date = '2025-01-01' } }:exec()
-- WHERE (T.resume -> '2') <@ '{"start_date":"2025-01-01"}'
```

### 支持的 lookup 速查

| lookup           | 提取方式 | SQL                              |
| ---------------- | -------- | -------------------------------- |
| (默认) `eq`      | `->`     | `(field -> 'k') = '"v"'`         |
| `ne`             | `->`     | `(field -> 'k') <> '"v"'`        |
| `gt` / `gte` / `lt` / `lte` | `->` | `(field -> 'k') > '5'` (jsonb 比较) |
| `contains`       | `->`     | `(field -> 'k') @> '...'`        |
| `contained_by`   | `->`     | `(field -> 'k') <@ '...'`        |
| `has_key`        | `->`     | `(field -> 'k') ? 'x'`           |
| `has_keys`       | `->`     | `(field -> 'k') ?& ARRAY[...]`   |
| `has_any_keys`   | `->`     | `(field -> 'k') ?\| ARRAY[...]`  |
| `startswith` / `endswith` / `icontains` 等 LIKE 系列 | `->>` | `field ->> 'k' LIKE 'x%'` |
| `iexact`         | `->>`    | `field ->> 'k' ILIKE 'v'`        |
| `regex` / `iregex` | `->>`  | `field ->> 'k' ~ 'pat'`          |
| `date` / `time` / `year` / `month` 等 EXTRACT 系列 | `->>` | 见 [基础 lookup 表](orm-query-basics.md#常用-lookup-速查) |

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
-- 1) 来源是 UPDATE + RETURNING：把变化"同步"到目标表
Blog:upsert(
  BlogBin:update{ tagline = 'synced' }:returning{'name', 'tagline'}
):returning{'id', 'name'}:exec()
-- WITH V(name, tagline) AS (UPDATE blog_bin T SET ... RETURNING T.name, T.tagline)
-- INSERT INTO blog AS T (name, tagline) SELECT name, tagline FROM V
-- ON CONFLICT (name) DO UPDATE SET tagline = EXCLUDED.tagline
-- RETURNING T.id, T.name

-- 2) 来源是 SELECT：只插入目标表"还没有"的 name
--    (NOT IN + DISTINCT 的常见配方)
Blog:upsert(
  BlogBin
    :where { name__notin = Blog:select{'name'}:distinct() }
    :select { 'name', 'tagline' }
    :distinct('name')
):returning{ 'id', 'name', 'tagline' }:exec()
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

## 行级锁：select_for_update

`select_for_update()` 在查询末尾追加 PostgreSQL 的 `FOR UPDATE` 子句，对选中行加写锁，防止并发事务修改或删除。典型场景：读-修改-写（先查当前值，再基于它更新）。

### ⚠️ 必须在事务内使用

**这是一个极其重要的约束**。PostgreSQL 的行锁在事务提交/回滚时释放：

- 在事务内：锁持续到事务结束，其他事务的相同行会阻塞或按选项处理
- **不在事务内（autocommit 模式）**：每条 SQL 是独立事务，`SELECT FOR UPDATE` 执行完立即提交并释放锁，**等于无效操作但不会报错**

本 ORM 没有像 Django 那样自动检测"是否在事务中"的机制，**误用不会报错**。必须自己确保调用处于事务上下文。

### 进入事务的两种方式

**方式一：classview 设置 `atomic = true`**（推荐，覆盖整个请求）

```lua
local TransferView = ClassView:class {
  model = models.Account,
  atomic = true,  -- 整个 post 在一个事务中
  post = function(self, request)
    local from = self.model:where{id=request.data.from_id}
                           :select_for_update()
                           :get()
    local to = self.model:where{id=request.data.to_id}
                         :select_for_update()
                         :get()
    assert(from.balance >= request.data.amount, "余额不足")
    self.model:where{id=from.id}:update{balance = F'balance' - request.data.amount}
    self.model:where{id=to.id}:update{balance = F'balance' + request.data.amount}
    return { ok = true }
  end,
}
```

**方式二：`Model:transaction(callback)`**（细粒度控制）

```lua
models.Account:transaction(function()
  local account = models.Account:where{id=1}:select_for_update():get()
  if account.balance >= 100 then
    models.Account:where{id=1}:update{balance = F'balance' - 100}
  end
end)
```

### 参数说明

`select_for_update(opts)` 接受可选配置表：

| 选项 | SQL 子句 | 行为 |
|------|---------|------|
| `nowait = true` | `FOR UPDATE NOWAIT` | 行被锁时立即报错，不等待 |
| `skip_locked = true` | `FOR UPDATE SKIP LOCKED` | 行被锁时跳过该行（用于任务队列） |
| `of = 'self'` 或 `of = {'author', ...}` | `FOR UPDATE OF <alias>` | 多表 join 时只锁指定表的行，见下方别名解析 |
| `no_key = true` | `FOR NO KEY UPDATE` | 弱锁，允许其他事务加外键引用锁 |

示例：

```lua
-- 任务队列：抢占一条未锁定的任务
local job = models.Job:where{status='pending'}
                      :select_for_update{skip_locked=true}
                      :limit(1)
                      :get()

-- 立即失败而非等待
local row = models.X:where{id=1}
                    :select_for_update{nowait=true}
                    :get()
```

### `of` 参数的别名解析（类似 Django）

多表 join 查询中，`FOR UPDATE OF` 后面必须写表别名（如 `T`、`T1`）。手写别名容易出错，所以 `of` 支持符号名：

- **`'self'`** → 主表别名（`self._as`，默认 `T`）
- **关系名**（FK 字段名或 `select_related` 参数）→ 对应的 join 别名（`T1`、`T2` 等）
- **其他字符串** → 原样输出（用户自己写的表名/别名）

别名解析在 `statement()` 生成时进行（lazy），**调用顺序不敏感**：先后写 `select_for_update` 再写 `select_related` 也能正确翻译。

```lua
-- Blog 有 FK author -> Author
-- 只锁 Blog 自己的行，不锁 author 表
Blog:select_related('author')
    :where{author__name='张三'}
    :select_for_update{of='self'}
    :exec()
-- → SELECT ... FROM blog T LEFT JOIN author T1 ON ... WHERE T1.name='张三' FOR UPDATE OF T

-- 同时锁 Blog 和 author
Blog:select_related('author')
    :select_for_update{of={'self', 'author'}}
    :exec()
-- → ... FOR UPDATE OF T, T1
```

### 常见陷阱

1. **functionview 里裸用**：functionview 默认无事务，`select_for_update()` 无效。如必须用，在 handler 内显式用 `Model:transaction(function() ... end)` 包裹。
2. **`get_or_create` / `upsert` 替代不了它**：这些方法自身原子性有限，在并发下仍需事务 + 锁保证一致性。
3. **与 GROUP BY / DISTINCT 冲突**：PostgreSQL 不允许 `FOR UPDATE` 与聚合、`DISTINCT`、`UNION` 等一起使用，会报错。
4. **与 `LIMIT` 组合要小心**：`FOR UPDATE LIMIT 1` 只锁被返回的行，未被选中的行不锁；高并发下多个 worker 可能同时选到同一行——用 `skip_locked` 解决。
