# 10 — 子查询

> Sql 对象可以作为值传入几乎所有接受值的 API 中，自动转换为子查询。这是一个隐藏但极其重要的特性。

## 核心机制

当一个 Sql 对象（带有 `__SQL_BUILDER__` 标记）作为值使用时，ORM 会自动调用其 `statement()` 方法并包裹在括号中：

```lua
-- as_literal 中的关键分支 (utils.lua)：
-- if value.__SQL_BUILDER__ then
--   return "(" .. value:statement() .. ")"
-- end
```

这意味着 **任何接受值参数的地方** 都可以传入 Sql 对象作为子查询。

---

## 在 where 中使用子查询

### where + __in 后缀（最常见）

```lua
-- 仅查询有高评分文章的 Blog
local high_rated = Entry:select('blog_id'):where{rating__gt=4}
Blog:where{id__in=high_rated}:exec()
-- WHERE T."id" IN (SELECT T."blog_id" FROM entry T WHERE T."rating" > 4)

-- 等价于 where_in（见下方）
```

### where + __notin 后缀

```lua
-- 排除有低评分文章的 Blog
local low_rated = Entry:select('blog_id'):where{rating__lt=2}
Blog:where{id__notin=low_rated}:exec()
-- WHERE T."id" NOT IN (SELECT T."blog_id" FROM entry T WHERE T."rating" < 2)
```

### where + 比较操作符

```lua
-- 评分大于平均值的 Entry
local avg_sub = Entry:select_literal('AVG(rating)')
Entry:where{rating__gt=avg_sub}:exec()
-- WHERE T."rating" > (SELECT AVG(rating) FROM entry T)

-- 等价于三参数形式
Entry:where("rating", ">", Entry:select_literal('AVG(rating)')):exec()
```

### where + 等值比较

```lua
-- 直接赋值子查询
Entry:where{blog_id=Blog:select('id'):where{name='First Blog'}}:exec()
-- WHERE T."blog_id" = (SELECT T."id" FROM blog T WHERE T."name" = 'First Blog')
-- ⚠️ 子查询必须恰好返回一行一列，否则 PG 报错
```

---

## Sql:where_in(cols, range) — 专用子查询 IN

```lua
---@param cols string|string[]   -- 列名或列名数组
---@param range Sql|table        -- 子查询或值数组
---@return self
```

### 单列子查询

```lua
-- 基础用法
Blog:where_in('id', Entry:select('blog_id'):where{rating__gt=3}):exec()
-- WHERE (T."id") IN (SELECT T."blog_id" FROM entry T WHERE T."rating" > 3)

-- 等价于 where + __in 后缀
Blog:where{id__in=Entry:select('blog_id'):where{rating__gt=3}}:exec()
```

### 多列子查询

```lua
-- 多列 IN
Entry:where_in(
  {'blog_id', 'rating'},
  Blog:select('id', 5):where{name__contains='Blog'}
):exec()
-- WHERE (T."blog_id", T."rating") IN (
--   SELECT T."id", 5 FROM blog T WHERE T."name" LIKE '%Blog%' ESCAPE '\'
-- )
```

---

## Sql:where_not_in(cols, range) — 子查询 NOT IN

```lua
---@param cols string|string[]
---@param range Sql|table
---@return self
```

```lua
-- 排除子查询结果
Blog:where_not_in('id', Entry:select('blog_id'):where{rating__lt=3}):exec()
-- WHERE (T."id") NOT IN (SELECT T."blog_id" FROM entry T WHERE T."rating" < 3)

-- 多列 NOT IN
Entry:where_not_in(
  {'blog_id', 'headline'},
  Entry:select('blog_id', 'headline'):where{rating=1}
):exec()
```

---

## 在 insert 中使用子查询

### SELECT 子查询插入

```lua
-- 从查询结果插入
Blog:insert(
  Blog:select('name', 'tagline'):where{id__gt=0}
):exec()
-- INSERT INTO blog AS T (name, tagline)
-- SELECT T."name", T."tagline" FROM blog T WHERE T."id" > 0
```

### RETURNING 子查询插入 (CTE)

当子查询来自 UPDATE/DELETE 的 RETURNING 时，自动使用 CTE：

```lua
-- 从 UPDATE 的 RETURNING 插入
Blog:insert(
  Entry:where{id=1}:update{headline='updated'}:returning('headline', 'body_text')
):returning('*'):exec()
-- WITH D(headline, body_text) AS (
--   UPDATE entry T SET "headline" = 'updated'
--   WHERE T."id" = 1 RETURNING T."headline", T."body_text"
-- )
-- INSERT INTO blog AS T (headline, body_text) SELECT headline, body_text FROM D
-- RETURNING *

-- 从 DELETE 的 RETURNING 插入
BlogArchive:insert(
  Blog:delete{id__lt=10}:returning('name', 'tagline')
):exec()
-- WITH D(name, tagline) AS (
--   DELETE FROM blog T WHERE T."id" < 10 RETURNING T."name", T."tagline"
-- )
-- INSERT INTO blog_archive AS T (name, tagline) SELECT name, tagline FROM D
```

---

## 在 upsert 中使用子查询

```lua
-- 子查询 upsert
Blog:upsert(
  Entry:select('headline', 'body_text'):where{rating__gt=3},
  'name',
  {'name', 'tagline'}
):exec()
-- WITH D(name, tagline) AS (SELECT ...)
-- INSERT INTO blog AS T (name, tagline) SELECT name, tagline FROM D
-- ON CONFLICT (name) DO UPDATE SET tagline = EXCLUDED.tagline
```

---

## 在 updates 中使用子查询

```lua
-- 从其他查询结果批量更新
Blog:updates(
  Entry:select('blog_id', 'headline'):where{rating__gt=3},
  'blog_id',                    -- 匹配键（映射到当前表的 blog_id）
  {'blog_id', 'tagline'}         -- 列映射
):exec()
```

---

## 子查询嵌套

子查询可以多层嵌套：

```lua
-- 二级嵌套
Blog:where_in('id',
  Entry:select('blog_id'):where_in('id',
    ViewLog:select('entry_id'):where{ctime__gt='2024-01-01'}
  )
):exec()
-- WHERE (T."id") IN (
--   SELECT T."blog_id" FROM entry T
--   WHERE (T."id") IN (
--     SELECT T."entry_id" FROM view_log T WHERE T."ctime" > '2024-01-01'
--   )
-- )
```

---

## 子查询 vs 自动 JOIN 对比

两种跨表查询方式各有优劣：

```lua
-- 方式1: 自动 JOIN（通过 __ 语法）
Entry:where{blog_id__name='First Blog'}:exec()
-- FROM entry T INNER JOIN blog T1 ON (...) WHERE T1."name" = 'First Blog'

-- 方式2: 子查询
Entry:where{blog_id__in=Blog:select('id'):where{name='First Blog'}}:exec()
-- WHERE T."blog_id" IN (SELECT T."id" FROM blog T WHERE T."name" = 'First Blog')
```

| 特性       | 自动 JOIN (`__`)   | 子查询                  |
| ---------- | ------------------ | ----------------------- |
| 语法简洁度 | ✅ 更简洁          | 较长                    |
| 适合场景   | 等值匹配、关联选择 | IN/NOT IN、聚合、EXISTS |
| 结果去重   | 可能产生重复行     | 天然去重                |
| 性能       | JOIN 通常更快      | 大数据量时有时更优      |
| 灵活度     | 仅限外键关系       | 任意查询                |

### 选择建议

- **简单等值跨表** → 优先用 `__` 自动 JOIN
- **IN/NOT IN 筛选** → 用子查询更自然
- **聚合子查询** → 只能用子查询
- **复杂多步逻辑** → 子查询 + CTE

---

## 综合示例

```lua
-- 1. 查找有"高评分文章"的博客，但排除有"低评分文章"的
Blog:where_in('id', Entry:select('blog_id'):where{rating__gte=4})
  :where_not_in('id', Entry:select('blog_id'):where{rating__lte=2})
  :exec()

-- 2. 评分高于同博客平均评分的文章
-- （需要用子查询，自动 JOIN 做不到这种）
Entry:where("rating > (" ..
  Entry:select_literal('AVG(rating)')
    :where("blog_id = T.blog_id")
    :statement()
  .. ")"):exec()

-- 3. 从删除的行中归档
Archived:insert(
  Blog:delete{id__in={1,2,3}}:returning('name', 'tagline')
):returning('*'):exec()

-- 4. where_in + 自动 JOIN 组合
Entry:where{blog_id__name__contains='Blog'}
  :where_in('id', ViewLog:select('entry_id'))
  :exec()
-- 两种跨表方式可以在同一查询中混用

-- 5. 子查询作为 annotate 值（通过 select_literal）
Blog:select('name')
  :select_literal('(' ..
    Entry:select_literal('COUNT(*)')
      :where('blog_id = T.id')
      :statement()
  .. ') AS entry_count')
  :exec()
-- SELECT T."name",
--   (SELECT COUNT(*) FROM entry T WHERE blog_id = T.id) AS entry_count
-- FROM blog T
```
