# 06 — 聚合与注解

> annotate / group_by / having / F / Count / Sum / Avg / Max / Min / increase / decrease

## 聚合函数

```lua
local Count = Model.Count
local Sum = Model.Sum
local Avg = Model.Avg
local Max = Model.Max
local Min = Model.Min

-- 基本用法
Count("id")          -- COUNT("id")
Sum("price")         -- SUM("price")
Avg("rating")        -- AVG("rating")
Max("pages")         -- MAX("pages")
Min("price")         -- MIN("price")

-- 带 filter 的用法 (TODO: 尚未完全实现)
Count { "id", filter = { rating__gt = 3 } }
```

---

## Sql:annotate(kwargs) — 添加聚合注解

```lua
---@param kwargs {[string]:table}   -- alias → 聚合函数/F表达式
---@return self
```

`annotate` 为查询添加计算列，支持聚合函数和 F 表达式。

### 调用形式

```lua
-- 形式1: 命名聚合
Blog:annotate{ entry_count = Count('entry') }:group_by('name'):exec()
-- SELECT T."name", COUNT(T1."id") AS entry_count
-- FROM blog T INNER JOIN entry T1 ON (T."id" = T1."blog_id")
-- GROUP BY T."name"

-- 形式2: 多个聚合
Book:annotate{
  total_price = Sum('price'),
  avg_rating = Avg('rating'),
  max_pages = Max('pages'),
}:group_by('publisher_id'):exec()
-- SELECT T."publisher_id",
--   SUM(T."price") AS total_price,
--   AVG(T."rating") AS avg_rating,
--   MAX(T."pages") AS max_pages
-- FROM book T GROUP BY T."publisher_id"

-- 形式3: 自动命名 (使用数组索引)
Book:annotate{ Count('id') }:group_by('publisher_id'):exec()
-- 自动命名为 "id_count" (column + suffix)
-- SELECT T."publisher_id", COUNT(T."id") AS id_count

-- 形式4: F 表达式注解
Book:annotate{ discounted = F('price') * 0.9 }:exec()
-- SELECT *, (T."price" * 0.9) AS discounted FROM book T

-- 形式5: 跨表聚合 (反向外键)
Blog:annotate{ entry_count = Count('entry') }:group_by('name'):exec()
-- 'entry' 是 Blog 的 reversed_field (related_query_name)
-- 自动 JOIN entry 表
```

### annotate 后在 where / having 中引用

注解名可以在后续的 `where` 和 `having` 中使用:

```lua
Blog:annotate{ cnt = Count('entry') }
  :where{ cnt__gt = 1 }       -- 在 where 中引用注解
  :group_by('name'):exec()

Blog:annotate{ cnt = Count('entry') }
  :having{ cnt__gt = 1 }       -- 在 having 中引用注解
  :group_by('name'):exec()
```

---

## Sql:group(...) / Sql:group_by(...)

```lua
---@param a string          -- 字段名
---@param ... string        -- 更多字段名
---@return self
```

`group_by` 是 `group` 的别名。**注意: `group` 会自动将分组字段加入 SELECT。**

### 调用形式

```lua
-- 形式1: 单字段
Entry:annotate{ cnt = Count('id') }:group_by('blog_id'):exec()
-- SELECT T."blog_id", COUNT(T."id") AS cnt
-- FROM entry T GROUP BY T."blog_id"

-- 形式2: 多字段
Entry:annotate{ cnt = Count('id') }:group_by('blog_id', 'rating'):exec()
-- SELECT T."blog_id", T."rating", COUNT(T."id") AS cnt
-- FROM entry T GROUP BY T."blog_id", T."rating"

-- 形式3: 数组
Entry:annotate{ cnt = Count('id') }:group_by({'blog_id', 'rating'}):exec()
-- 同上

-- 形式4: 跨表字段分组
Entry:annotate{ cnt = Count('id') }:group_by('blog_id__name'):exec()
-- SELECT T1."name" AS "blog_id__name", COUNT(T."id") AS cnt
-- FROM entry T INNER JOIN blog T1 ON (T."blog_id" = T1."id")
-- GROUP BY T1."name"
```

---

## Sql:having(cond) — 分组后过滤

```lua
---@param cond {[string]: DBValue}|QClass
---@return self
```

`having` 的键名必须是 `annotate` 中定义的别名。

### 调用形式

```lua
-- 形式1: 键值对
Blog:annotate{ cnt = Count('entry') }
  :group_by('name')
  :having{ cnt__gt = 1 }
  :exec()
-- HAVING COUNT(T1."id") > 1

-- 形式2: 带操作符后缀
Blog:annotate{ cnt = Count('entry') }
  :group_by('name')
  :having{ cnt__gte = 2 }
  :exec()
-- HAVING COUNT(T1."id") >= 2

-- 形式3: Q 对象
Blog:annotate{ cnt = Count('entry') }
  :group_by('name')
  :having(Q{cnt__gt=0} * Q{cnt__lt=10})
  :exec()
-- HAVING (COUNT(T1."id") > 0) AND (COUNT(T1."id") < 10)

-- 多次调用 (AND 叠加)
Blog:annotate{ cnt = Count('entry'), avg = Avg('entry__rating') }
  :group_by('name')
  :having{ cnt__gt = 0 }
  :having{ avg__gte = 3 }
  :exec()
-- HAVING (COUNT(T1."id") > 0) AND (AVG(T1."rating") >= 3)
```

---

## F() 表达式 — 字段引用

```lua
local F = Model.F
```

`F()` 用于在查询中引用数据库字段值，支持算术运算:

### 基本用法

```lua
-- 引用字段
F("rating")              -- T."rating"

-- 算术运算
F("price") + 10          -- (T."price" + 10)
F("price") - 5           -- (T."price" - 5)
F("price") * 1.1         -- (T."price" * 1.1)
F("price") / 2           -- (T."price" / 2)
F("price") % 10          -- (T."price" % 10)
F("price") ^ 2           -- (T."price" ^ 2)

-- 字段间运算
F("price") + F("tax")    -- (T."price" + T."tax")
F("pages") * F("price")  -- (T."pages" * T."price")

-- 字符串拼接
F("first") .. F("last")  -- (T."first" || T."last")

-- 跨表字段
F("blog_id__name")       -- 自动 JOIN
```

### 在 where 中使用 F()

```lua
-- 字段间比较
Entry:where{number_of_comments__gt=F('number_of_pingbacks')}:exec()
-- WHERE T."number_of_comments" > T."number_of_pingbacks"

-- 表达式比较
Entry:where{rating__gte=F('number_of_comments') + F('number_of_pingbacks')}:exec()
-- WHERE T."rating" >= (T."number_of_comments" + T."number_of_pingbacks")
```

### 在 update 中使用 F()

```lua
-- 基于当前值更新
Entry:where{id=1}:update{rating = F('rating') + 1}:exec()
-- UPDATE entry T SET "rating" = (T."rating" + 1) WHERE T."id" = 1

Book:where{id=1}:update{price = F('price') * 0.9}:exec()
-- UPDATE book T SET "price" = (T."price" * 0.9) WHERE T."id" = 1
```

### 在 annotate 中使用 F()

```lua
Book:annotate{ discounted = F('price') * 0.9 }:exec()
-- SELECT *, (T."price" * 0.9) AS discounted FROM book T

Book:annotate{ total = F('price') * F('pages') }:exec()
-- SELECT *, (T."price" * T."pages") AS total FROM book T
```

---

## Sql:increase(name, amount?) — 递增

```lua
---@param name string|table     -- 字段名或 {字段名: 增量} 映射
---@param amount? number         -- 增量，默认 1
---@return self
```

### 调用形式

```lua
-- 形式1: 单字段递增 1
Entry:where{id=1}:increase('number_of_comments'):exec()
-- UPDATE entry T SET "number_of_comments" = T."number_of_comments" + 1 WHERE T."id" = 1

-- 形式2: 单字段指定增量
Entry:where{id=1}:increase('number_of_comments', 5):exec()
-- UPDATE entry T SET "number_of_comments" = T."number_of_comments" + 5 WHERE T."id" = 1

-- 形式3: 多字段递增 (table)
Entry:where{id=1}:increase{number_of_comments=3, number_of_pingbacks=2}:exec()
-- UPDATE entry T SET
--   "number_of_comments" = T."number_of_comments" + 3,
--   "number_of_pingbacks" = T."number_of_pingbacks" + 2
-- WHERE T."id" = 1
```

---

## Sql:decrease(name, amount?) — 递减

```lua
---@param name string|table
---@param amount? number         -- 减量，默认 1
---@return self
```

用法同 `increase`，方向相反:

```lua
-- 单字段递减 1
Entry:where{id=1}:decrease('rating'):exec()
-- UPDATE entry T SET "rating" = T."rating" - 1 WHERE T."id" = 1

-- 单字段指定减量
Entry:where{id=1}:decrease('rating', 2):exec()

-- 多字段
Entry:where{id=1}:decrease{number_of_comments=1, rating=2}:exec()
```

---

## 完整聚合查询示例

```lua
-- 每个博客的文章数和平均评分
Blog:annotate{
  entry_count = Count('entry'),
  avg_rating = Avg('entry__rating'),
}:group_by('name')
  :having{entry_count__gt=0}
  :order('-entry_count')
  :exec()

-- SQL:
-- SELECT T."name",
--   COUNT(T1."id") AS entry_count,
--   AVG(T1."rating") AS avg_rating
-- FROM blog T
--   INNER JOIN entry T1 ON (T."id" = T1."blog_id")
-- GROUP BY T."name"
-- HAVING COUNT(T1."id") > 0
-- ORDER BY entry_count DESC

-- 出版社汇总统计
Publisher:annotate{
  book_count = Count('publisher__id'),
  total_pages = Sum('publisher__pages'),
  avg_price = Avg('publisher__price'),
  min_price = Min('publisher__price'),
  max_price = Max('publisher__price'),
}:group_by('name'):exec()
```
