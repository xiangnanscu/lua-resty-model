# group / group_by

设置 `GROUP BY` 子句。`group_by` 是 `group` 的别名。

> **注意**: 调用 `group` 时会自动将分组列加入到 `SELECT` 中。

## 函数签名

```lua
---@param a string
---@param ... string
function Sql:group(a, ...)
function Sql:group_by(...)  -- 别名
```

## 基本用法

```lua
Entry:group('blog_id'):annotate{cnt = Count('id')}:exec()
-- SELECT T.blog_id, COUNT(T.id) AS cnt FROM entry T GROUP BY T.blog_id
```

## 多列分组

```lua
Entry:group('blog_id', 'rating'):annotate{cnt = Count('id')}:exec()
-- SELECT T.blog_id, T.rating, COUNT(T.id) AS cnt
-- FROM entry T GROUP BY T.blog_id, T.rating
```

---

# having

设置 `HAVING` 子句，用于对聚合结果进行过滤。多次调用以 `AND` 叠加。

## 函数签名

```lua
---@param cond {[string]: DBValue}|QClass
function Sql:having(cond)
```

## 用法

```lua
-- 筛选文章数大于 2 的博客
Entry:group('blog_id'):annotate{cnt = Count('id')}:having{cnt__gt = 2}:exec()
-- SELECT T.blog_id, COUNT(T.id) AS cnt
-- FROM entry T GROUP BY T.blog_id HAVING COUNT(T.id) > 2

-- having 中也支持操作符后缀和 Q 对象
Entry:group('blog_id')
  :annotate{avg_rating = Avg('rating')}
  :having{avg_rating__gte = 3}
  :exec()
```

---

# annotate

为查询添加聚合注解列。注解名可用于后续 `where`、`having`、`order` 中。

## 函数签名

```lua
---@param kwargs {[string]:table}
function Sql:annotate(kwargs)
```

## 支持的聚合函数

- `Count(column)` — COUNT
- `Sum(column)` — SUM
- `Avg(column)` — AVG
- `Max(column)` — MAX
- `Min(column)` — MIN

## 用法

```lua
-- 命名聚合
Blog:group('name'):annotate{entry_count = Count('entry')}:exec()
-- SELECT T."name", COUNT(T1.id) AS entry_count
-- FROM blog T INNER JOIN entry T1 ON (T.id = T1.blog_id)
-- GROUP BY T."name"

-- 未命名时自动推导名称: column + suffix (如 id_count)
Blog:group('name'):annotate{Count('entry')}:exec()

-- 多个聚合
Entry:group('blog_id'):annotate{
  avg_rating = Avg('rating'),
  max_rating = Max('rating'),
  total_comments = Sum('number_of_comments')
}:exec()

-- 聚合后 where (基于注解名)
Blog:group('name')
  :annotate{cnt = Count('entry')}
  :where{cnt__lt = 2}
  :exec()

-- F() 表达式注解
Entry:group('blog_id'):annotate{
  score = F('rating') * F('number_of_comments')
}:exec()
```
