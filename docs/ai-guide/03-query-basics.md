# 03 — 查询基础

> select / where / order / limit / offset 的基本用法。所有 Sql 方法均支持链式调用，且可通过 Model 代理调用。

## Model 代理机制

所有 `Sql` 的公共方法都可以通过 Model 直接调用，内部会自动创建 Sql 实例：

```lua
-- 以下两种方式完全等价:
Blog:where{name='test'}:exec()
Blog:create_sql():where{name='test'}:exec()

-- 链式调用
Blog:select('name', 'tagline'):where{id=1}:limit(10):exec()
```

---

## Sql:select(...) — 选择字段

```lua
---@param a DBValue|fun(ctx:table):string    -- 字段名、字段名数组或回调函数
---@param b? DBValue                         -- 第二个字段名
---@param ...? DBValue                       -- 更多字段名
---@return self
```

### 调用形式

```lua
-- 形式1: 单个字段名
Blog:select('name'):exec()
-- SELECT T."name" FROM blog T

-- 形式2: 多个字段名(变参)
Blog:select('name', 'tagline'):exec()
-- SELECT T."name", T."tagline" FROM blog T

-- 形式3: 字段名数组
Blog:select({'name', 'tagline'}):exec()
-- SELECT T."name", T."tagline" FROM blog T

-- 形式4: '*' 通配符
Blog:select('*'):exec()
-- SELECT * FROM blog T

-- 形式5: 跨表字段 (自动 JOIN)
Entry:select('headline', 'blog_id__name'):exec()
-- SELECT T."headline", T1."name" AS "blog_id__name" FROM entry T
--   INNER JOIN blog T1 ON (T."blog_id" = T1."id")

-- 形式6: 累加调用 (多次 select 会 append)
Blog:select('name'):select('tagline'):exec()
-- SELECT T."name", T."tagline" FROM blog T

-- 形式7: 回调函数
Blog:select(function(ctx)
  return 'T."name" || T."tagline"'
end):exec()
```

### 不调用 select 时

不调用 `select` 则默认 `SELECT *`。

---

## Sql:select_as(kwargs, as?) — 选择并重命名

```lua
---@param kwargs {[string]: string}|string  -- 字段名到别名的映射
---@param as? string                         -- 当 kwargs 是 string 时用此参数
---@return self
```

### 调用形式

```lua
-- 形式1: 字典形式
Blog:select_as{ name = 'blog_name', tagline = 'blog_tagline' }:exec()
-- SELECT T."name" AS "blog_name", T."tagline" AS "blog_tagline" FROM blog T

-- 形式2: 两个参数
Blog:select_as('name', 'blog_name'):exec()
-- SELECT T."name" AS "blog_name" FROM blog T

-- 形式3: 跨表字段重命名
Entry:select_as{ blog_id__name = 'blog_name' }:exec()
-- SELECT T1."name" AS "blog_name" FROM entry T INNER JOIN blog T1 ON (T."blog_id" = T1."id")
```

---

## Sql:select_literal(...) — 选择字面值

```lua
---@param a DBValue
---@param b? DBValue
---@param ...? DBValue
---@return self
```

不经过列名解析，直接作为字面值插入 SELECT。

```lua
-- 选择字面值
Blog:select_literal(1):exec()
-- SELECT 1 FROM blog T

Blog:select_literal('now()'):exec()
-- SELECT 'now()' FROM blog T  -- 注意: 会被引号包裹
```

---

## Sql:select_literal_as(kwargs) — 字面值并重命名

```lua
---@param kwargs {string: string}
---@return self
```

```lua
Blog:select_literal_as{ ['count(*)'] = 'total' }:exec()
-- SELECT 'count(*)' AS "total" FROM blog T
```

---

## Sql:where(cond, op?, dval?) — 过滤条件

```lua
---@param cond table|string|fun(ctx:table):string
---@param op? string
---@param dval? DBValue
---@return self
```

`where` 是最核心的过滤 API，支持 5 种调用形式。详见 [04-where-deep-dive.md](04-where-deep-dive.md)。

### 基本调用形式

```lua
-- 形式1: Table 条件 (键值对，默认 AND)
Blog:where{name='First Blog'}:exec()
-- WHERE T."name" = 'First Blog'

Blog:where{name='First Blog', id=1}:exec()
-- WHERE T."name" = 'First Blog' AND T."id" = 1

-- 形式2: 字符串 SQL 片段
Blog:where("name = 'First Blog'"):exec()
-- WHERE name = 'First Blog'

-- 形式3: 两参数 (字段名, 值)
Blog:where("name", "First Blog"):exec()
-- WHERE T."name" = 'First Blog'

-- 形式4: 三参数 (字段名, 操作符, 值)
Entry:where("rating", ">", 3):exec()
-- WHERE T."rating" > 3

-- 形式5: 回调函数
Blog:where(function(ctx)
  return 'T."name" IS NOT NULL'
end):exec()
-- WHERE T."name" IS NOT NULL

-- 形式6: Q 对象 (复合逻辑)
Blog:where(Q{name='a'} / Q{name='b'}):exec()
-- WHERE (T."name" = 'a') OR (T."name" = 'b')

-- 多次调用 where (AND 叠加)
Blog:where{name='First Blog'}:where{id=1}:exec()
-- WHERE (T."name" = 'First Blog') AND (T."id" = 1)
```

---

## Sql:or_where(cond, op?, dval?) — OR 条件

```lua
---@param cond table|string|fun(ctx:table):string
---@param op? string
---@param dval? DBValue
---@return self
```

与已有 where 条件用 `OR` 连接:

```lua
Blog:where{id=1}:or_where{id=2}:exec()
-- WHERE T."id" = 1 OR T."id" = 2
```

---

## Sql:where_or(cond, op?, dval?) — 内部 OR 条件

```lua
---@param cond table|string|fun(ctx:table):string
---@param op? string
---@param dval? DBValue
---@return self
```

当 `cond` 是 table 时，table 中的条件用 `OR` 连接（而非默认的 `AND`），然后与已有 where 用 `AND` 连接:

```lua
Blog:where_or{name='First Blog', id=1}:exec()
-- WHERE T."name" = 'First Blog' OR T."id" = 1

-- 与 where 组合
Blog:where{tagline='test'}:where_or{name='a', name='b'}:exec()
-- WHERE (T."tagline" = 'test') AND (T."name" = 'a' OR T."name" = 'b')
```

---

## Sql:or_where_or(cond, op?, dval?) — OR + 内部 OR

```lua
---@param cond table|string|fun(ctx:table):string
---@param op? string
---@param dval? DBValue
---@return self
```

table 内部条件用 `OR`，与已有 where 也用 `OR` 连接:

```lua
Blog:where{id=1}:or_where_or{name='a', name='b'}:exec()
-- WHERE T."id" = 1 OR T."name" = 'a' OR T."name" = 'b'
```

---

## Sql:where_in(cols, range) — IN 子句

```lua
---@param cols string|string[]   -- 列名或列名数组
---@param range Sql|table        -- 子查询或值数组
---@return self
```

### 调用形式

```lua
-- 形式1: 单列 + 值列表
Blog:where_in('id', {1, 2, 3}):exec()
-- WHERE (T."id") IN (1, 2, 3)

-- 形式2: 单列 + 子查询
Blog:where_in('id', Entry:select('blog_id'):where{rating__gt=3}):exec()
-- WHERE (T."id") IN (SELECT T."blog_id" FROM entry T WHERE T."rating" > 3)

-- 形式3: 多列 + 值列表
Blog:where_in({'id', 'name'}, {{1, 'a'}, {2, 'b'}}):exec()
-- WHERE (T."id", T."name") IN ((1, 'a'), (2, 'b'))
```

---

## Sql:where_not_in(cols, range) — NOT IN 子句

```lua
---@param cols string|string[]
---@param range Sql|table
---@return self
```

用法同 `where_in`，生成 `NOT IN`:

```lua
Blog:where_not_in('id', {1, 2}):exec()
-- WHERE (T."id") NOT IN (1, 2)
```

---

## Sql:order(...) / Sql:order_by(...)

```lua
---@param a string|table|fun(ctx:table):string   -- 排序字段
---@param ...? string|FClass                       -- 更多排序字段
---@return self
```

`order_by` 是 `order` 的别名。

### 调用形式

```lua
-- 形式1: 单字段升序
Blog:order('name'):exec()
-- ORDER BY T."name"

-- 形式2: 降序 (前缀 '-')
Blog:order('-name'):exec()
-- ORDER BY T."name" DESC

-- 形式3: 多字段
Blog:order('name', '-id'):exec()
-- ORDER BY T."name", T."id" DESC

-- 形式4: 数组
Blog:order({'-name', 'id'}):exec()
-- ORDER BY T."name" DESC, T."id"

-- 形式5: 跨表字段排序
Entry:order('blog_id__name'):exec()
-- ORDER BY T1."name" (自动 JOIN blog)

-- 形式6: 回调函数
Blog:order(function(ctx)
  return 'T."name" COLLATE "C"'
end):exec()
```

---

## Sql:nulls_first() / Sql:nulls_last()

```lua
---@return self
```

控制 NULL 值在排序中的位置:

```lua
Blog:order('-name'):nulls_last():exec()
-- ORDER BY T."name" DESC NULLS LAST

Blog:order('name'):nulls_first():exec()
-- ORDER BY T."name" NULLS FIRST
```

---

## Sql:limit(n) — 限制数量

```lua
---@param n integer|string       -- 正整数，最大 10000 (MAX_LIMIT)
---@return self
```

### 调用形式

```lua
Blog:limit(10):exec()            -- LIMIT 10
Blog:limit("10"):exec()          -- 字符串自动转数字

-- nil 被忽略（方便参数可选）
Blog:limit(nil):exec()           -- 无 LIMIT
```

---

## Sql:offset(n) — 偏移

```lua
---@param n integer|string       -- 非负整数
---@return self
```

### 调用形式

```lua
-- 分页
Blog:limit(10):offset(20):exec()
-- LIMIT 10 OFFSET 20

Blog:offset("20"):exec()         -- 字符串自动转数字
Blog:offset(nil):exec()          -- nil 被忽略
```

---

## Sql:from(...) — 自定义 FROM

```lua
---@param ... string
---@return self
```

```lua
-- 覆盖默认 FROM
Blog:from('blog T, entry E'):where("T.id = E.blog_id"):exec()
```

---

## Sql:distinct(...) — 去重

```lua
---@param ... string
---@return self
```

### 调用形式

```lua
-- 无参数: 全行去重
Blog:select('name'):distinct():exec()
-- SELECT DISTINCT T."name" FROM blog T

-- 有参数: DISTINCT ON (仅 PG 支持)
Entry:select('blog_id', 'headline'):distinct('blog_id'):exec()
-- SELECT DISTINCT ON (T."blog_id") T."blog_id", T."headline" FROM entry T
```

---

## Sql:distinct_on(...) — DISTINCT ON (自动排序)

```lua
---@param ... DBValue
---@return self
```

DISTINCT ON 自动在 ORDER BY 前添加 distinct 列（PG 要求 DISTINCT ON 必须在 ORDER BY 前面）:

```lua
Entry:select('blog_id', 'headline'):distinct_on('blog_id'):order('-pub_date'):exec()
-- SELECT DISTINCT ON (T."blog_id") T."blog_id", T."headline" FROM entry T
-- ORDER BY T."blog_id", T."pub_date" DESC
```

---

## Sql:returning(...) — RETURNING 子句

```lua
---@param a DBValue|fun(ctx:table):string
---@param b? DBValue
---@param ...? DBValue
---@return self
```

用于 INSERT/UPDATE/DELETE 后返回数据:

```lua
-- 返回指定列
Blog:insert{name='New Blog'}:returning('id', 'name'):exec()
-- INSERT INTO blog T (...) VALUES (...) RETURNING T."id", T."name"

-- 返回所有列
Blog:insert{name='New Blog'}:returning('*'):exec()
-- ... RETURNING *

-- 数组形式
Blog:delete{id=1}:returning({'id', 'name'}):exec()
```

---

## Sql:returning_literal(...) — 字面值 RETURNING

```lua
---@param a DBValue
---@param b? DBValue
---@param ...? DBValue
---@return self
```

不经过列名解析的 RETURNING。

```lua
Blog:insert{name='New'}:returning_literal('id'):exec()
```

---

## Sql:delete(cond?, op?, dval?) — 删除

```lua
---@param cond? table|string|fun(ctx:table):string
---@param op? string
---@param dval? DBValue
---@return self
```

### 调用形式

```lua
-- 形式1: 无参数 (需搭配 where 使用)
Blog:where{id=1}:delete():returning('*'):exec()
-- DELETE FROM blog T WHERE T."id" = 1 RETURNING *

-- 形式2: 带条件 (内部调用 where)
Blog:delete{id=1}:returning('*'):exec()
-- DELETE FROM blog T WHERE T."id" = 1 RETURNING *

-- 形式3: 字符串条件
Blog:delete("id = 1"):exec()

-- 形式4: 三参数条件
Blog:delete("id", ">", 10):exec()
```

---

## Sql:statement() — 获取 SQL 字符串

```lua
---@return string     -- 完整 SQL 语句
```

仅生成 SQL 字符串，不执行:

```lua
local sql = Blog:where{id=1}:statement()
print(sql)
-- SELECT * FROM blog T WHERE T."id" = 1
```

---

## Sql:copy() — 浅拷贝

```lua
---@return self
```

```lua
local q = Blog:where{id=1}
local q2 = q:copy():where{name='test'}
-- q 不受 q2 的影响
```

---

## Sql:clear() — 重置

```lua
---@return self
```

清除所有已设置的查询条件，保留 model 和 table_name。
