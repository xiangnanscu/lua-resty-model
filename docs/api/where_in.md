# where_in / where_not_in

设置 `WHERE column IN (...)` 或 `WHERE column NOT IN (...)` 条件。

## 函数签名

```lua
---@param cols Keys    列名（字符串或字符串数组）
---@param range table|Sql  值列表或子查询
---@return self
function Sql:where_in(cols, range)

---@param cols Keys
---@param range table|Sql
---@return self
function Sql:where_not_in(cols, range)
```

## 基本用法

```lua
-- 单列 IN
Entry:where_in('id', {1, 2, 3}):exec()
-- WHERE T.id IN (1, 2, 3)

-- 单列 NOT IN
Entry:where_not_in('id', {1, 2, 3}):exec()
-- WHERE T.id NOT IN (1, 2, 3)
```

## 子查询

```lua
-- IN 子查询
Entry:where_in('blog_id', Blog:select('id'):where{name__contains = 'Blog'}):exec()
-- WHERE T.blog_id IN (SELECT T.id FROM blog T WHERE T."name" LIKE '%Blog%' ESCAPE '\')
```

## 复合键 IN

```lua
-- 多列 IN
Entry:where_in({'blog_id', 'rating'}, {{1, 5}, {2, 4}}):exec()
-- WHERE (T.blog_id, T.rating) IN ((1, 5), (2, 4))
```

---

# where_or / or_where / or_where_or

where 的变体方法，控制内部条件和与已有 WHERE 子句的逻辑连接方式。

## 函数签名

```lua
---@param cond table|string|fun(ctx:table):string
---@param op? string
---@param dval? DBValue
---@return self
function Sql:where_or(cond, op, dval)    -- table 内 OR, 与已有 AND
function Sql:or_where(cond, op, dval)    -- table 内 AND, 与已有 OR
function Sql:or_where_or(cond, op, dval) -- 全 OR
```

## 对比

| 方法                 | table 内条件连接 | 与已有 `_where` 连接 |
| -------------------- | :--------------: | :------------------: |
| `where(table)`       |      `AND`       |        `AND`         |
| `where_or(table)`    |       `OR`       |        `AND`         |
| `or_where(table)`    |      `AND`       |         `OR`         |
| `or_where_or(table)` |       `OR`       |         `OR`         |

## 示例

```lua
-- where_or: table 内用 OR 连接, 整体用 AND
Blog:where{id = 3}:where_or{id = 1, name = 'a'}:exec()
-- WHERE (T.id = 3) AND (T.id = 1 OR T."name" = 'a')

-- or_where: table 内用 AND, 整体用 OR
Blog:where{id = 1}:or_where{id = 2}:exec()
-- WHERE T.id = 1 OR T.id = 2

-- or_where_or: 全部 OR
Blog:where{id = 3}:or_where_or{id = 1, name = 'a'}:exec()
-- WHERE T.id = 3 OR T.id = 1 OR T."name" = 'a'
```
