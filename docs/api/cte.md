# with / with_recursive / with_values

设置 `WITH` (CTE - 公共表表达式) 子句。

## 函数签名

```lua
---@param name string
---@param token string|Sql
---@return self
function Sql:with(name, token)

---@param name string
---@param token string|Sql
---@return self
function Sql:with_recursive(name, token)

---@param name string
---@param rows Record[]
---@return self
function Sql:with_values(name, rows)
```

## with

```lua
-- 使用 CTE
Blog:with('active_blogs', Blog:select('id', 'name'):where{id__lt = 5})
  :from('active_blogs')
  :exec()
-- WITH active_blogs AS (SELECT T.id, T."name" FROM blog T WHERE T.id < 5)
-- SELECT * FROM active_blogs

-- 多个 CTE (多次调用自动用逗号连接)
Blog:with('cte1', sql1):with('cte2', sql2):exec()
-- WITH cte1 AS (...), cte2 AS (...) SELECT ...
```

## with_recursive

```lua
-- 递归 CTE
Blog:with_recursive('tree', seed_sql:union_all(recursive_sql))
  :from('tree AS blog')
  :exec()
-- WITH RECURSIVE tree AS (... UNION ALL ...) SELECT * FROM tree AS blog
```

## with_values

用内联 VALUES 构造 CTE 虚拟表：

```lua
Blog:with_values('V', {{id = 1, name = 'a'}, {id = 2, name = 'b'}}):exec()
-- WITH V(id, name) AS (VALUES (1::integer, 'a'::varchar), (2, 'b'))
-- SELECT * FROM blog T
```

---

# union / union_all / except / except_all / intersect / intersect_all

集合操作，组合两个 SELECT 查询的结果。

## 函数签名

```lua
---@param other_sql Sql
---@return self
function Sql:union(other_sql)
function Sql:union_all(other_sql)
function Sql:except(other_sql)
function Sql:except_all(other_sql)
function Sql:intersect(other_sql)
function Sql:intersect_all(other_sql)
```

## 用法

```lua
-- UNION (去重)
Blog:select('name'):where{id = 1}:union(
  Blog:select('name'):where{id = 2}
):exec()
-- (SELECT T."name" FROM blog T WHERE T.id = 1) UNION (SELECT T."name" FROM blog T WHERE T.id = 2)

-- UNION ALL (不去重)
Blog:select('name'):where{id = 1}:union_all(
  Blog:select('name'):where{id = 2}
):exec()

-- EXCEPT
Blog:select('id'):except(
  Blog:select('id'):where{id__gt = 5}
):exec()

-- INTERSECT
Blog:select('id'):intersect(
  Blog:select('id'):where{id__lt = 10}
):exec()
```
