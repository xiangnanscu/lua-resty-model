# 08 — 高级用法

> CTE / WITH / WITH RECURSIVE / 集合操作 / 递归查询 / 事务 / 预置/追加语句

## Sql:with(name, token) — CTE (公共表表达式)

```lua
---@param name string         -- CTE 名称
---@param token string|Sql    -- CTE 内容 (SQL 字符串或 Sql 对象)
---@return self
```

### 调用形式

```lua
-- 形式1: 字符串 CTE
Blog:with('recent_blogs', "SELECT * FROM blog WHERE id > 0")
  :where("id IN (SELECT id FROM recent_blogs)")
  :exec()
-- WITH recent_blogs AS (SELECT * FROM blog WHERE id > 0)
-- SELECT * FROM blog T WHERE id IN (SELECT id FROM recent_blogs)

-- 形式2: Sql 对象作为 CTE
local recent = Blog:where{id__gt=0}:select('id', 'name')
Blog:with('recent_blogs', recent)
  :where("id IN (SELECT id FROM recent_blogs)")
  :exec()
-- WITH recent_blogs AS (SELECT T."id", T."name" FROM blog T WHERE T."id" > 0)
-- SELECT * FROM blog T WHERE id IN (SELECT id FROM recent_blogs)

-- 多个 CTE
Blog:with('cte1', "SELECT 1")
  :with('cte2', "SELECT 2")
  :exec()
-- WITH cte1 AS (SELECT 1), cte2 AS (SELECT 2) SELECT * FROM blog T
```

---

## Sql:with_values(name, rows) — CTE VALUES

```lua
---@param name string         -- CTE 名称
---@param rows Record[]       -- 数据行
---@return self
```

将数组数据注入 CTE VALUES:

```lua
Blog:with_values('V', { {id=1, name='a'}, {id=2, name='b'} })
  :where("T.id IN (SELECT id FROM V)")
  :exec()
-- WITH V(id, name) AS (VALUES (1, 'a'), (2, 'b'))
-- SELECT * FROM blog T WHERE T.id IN (SELECT id FROM V)
```

---

## Sql:with_recursive(name, token) — 递归 CTE

```lua
---@param name string
---@param token string|Sql
---@return self
```

```lua
-- 使用 where_recursive 快捷方式（推荐，见下方）
-- 或手动构建递归 CTE
Category:where_recursive('parent_id', 1, {'name'}):exec()
-- WITH RECURSIVE category_recursive AS (
--   SELECT T."id", T."parent_id", T."name" FROM category T WHERE T."parent_id" = 1
--   UNION ALL
--   SELECT T."id", T."parent_id", T."name" FROM category T
--     INNER JOIN category_recursive ON (T."parent_id" = category_recursive."id")
-- )
-- SELECT * FROM category_recursive AS category
```

---

## Sql:where_recursive(name, value, select_names?) — 快捷递归查询

```lua
---@param name string          -- 自引用外键字段名
---@param value any             -- 起始值
---@param select_names? string[] -- 额外选择字段
---@return self
```

自引用模型的快捷递归查询:

```lua
-- 假设 Category 有自引用外键 parent_id
Category:where_recursive('parent_id', 1):exec()
-- WITH RECURSIVE category_recursive AS (
--   SELECT T."id", T."parent_id" FROM category T WHERE T."parent_id" = 1
--   UNION ALL
--   SELECT T."id", T."parent_id" FROM category T
--     INNER JOIN category_recursive ON (T."parent_id" = category_recursive."id")
-- )
-- SELECT T."id", T."parent_id" FROM category_recursive AS category

-- 带额外选择字段
Category:where_recursive('parent_id', 1, {'name'}):exec()
-- 额外选择 name 字段
```

---

## 集合操作

所有集合操作接收另一个 Sql 对象作为参数:

### Sql:union(other_sql) — UNION (去重)

```lua
local q1 = Blog:where{id=1}:select('name')
local q2 = Blog:where{id=2}:select('name')

q1:union(q2):exec()
-- (SELECT T."name" FROM blog T WHERE T."id" = 1)
-- UNION
-- (SELECT T."name" FROM blog T WHERE T."id" = 2)
```

### Sql:union_all(other_sql) — UNION ALL (不去重)

```lua
q1:union_all(q2):exec()
-- (SELECT ...) UNION ALL (SELECT ...)
```

### Sql:except(other_sql) — EXCEPT (差集)

```lua
local all_blogs = Blog:select('name')
local excluded = Blog:where{id=1}:select('name')

all_blogs:except(excluded):exec()
-- (SELECT T."name" FROM blog T) EXCEPT (SELECT T."name" FROM blog T WHERE T."id" = 1)
```

### Sql:except_all(other_sql) — EXCEPT ALL

```lua
all_blogs:except_all(excluded):exec()
```

### Sql:intersect(other_sql) — INTERSECT (交集)

```lua
local q1 = Blog:where{id__in={1,2}}:select('name')
local q2 = Blog:where{id__in={2,3}}:select('name')

q1:intersect(q2):exec()
-- 结果: 仅 id=2 的 blog name
```

### Sql:intersect_all(other_sql) — INTERSECT ALL

```lua
q1:intersect_all(q2):exec()
```

---

## Sql:as(table_alias) — 设置表别名

```lua
---@param table_alias string   -- 自定义别名
---@return self
```

```lua
-- 默认别名是 T
Blog:as('b'):where{id=1}:statement()
-- SELECT * FROM blog "b" WHERE "b"."id" = 1

-- 清除别名
Blog:as(nil):statement()
```

---

## Sql:prepend(...) — 前置语句

```lua
---@param ... Sql|string       -- 在主语句前执行的语句
---@return self
```

```lua
Blog:prepend("SET search_path TO public"):where{id=1}:exec()
-- SET search_path TO public; SELECT * FROM blog T WHERE T."id" = 1

-- Sql 对象作为前置
Blog:prepend(Blog:delete{id=100}):where{id__gt=0}:exec()
-- 先执行 DELETE，再执行 SELECT
```

---

## Sql:append(...) — 追加语句

```lua
---@param ... Sql|string       -- 在主语句后执行的语句
---@return self
```

```lua
Blog:where{id=1}:append("SELECT count(*) FROM blog"):exec()
-- SELECT * FROM blog T WHERE T."id" = 1; SELECT count(*) FROM blog
```

---

## Sql:return_all() — 返回全部结果集

```lua
---@return self
```

当使用 `prepend` 或 `append` 时，`exec()` 默认只返回主查询结果。`return_all()` 让 `exec()` 返回包含所有语句结果的数组:

```lua
local results = Blog:where{id=1}
  :append(Blog:where{id=2})
  :return_all()
  :exec()
-- results[1] = 主查询结果
-- results[2] = append 查询结果
```

---

## Model:transaction(callback) — 事务

```lua
---@param callback function
---@return any
```

### 示例

```lua
Blog:transaction(function()
  local blog = Blog:create { name = 'New Blog' }
  Entry:create { blog_id = blog.id, headline = 'First Entry', rating = 5 }
  -- 如果任何操作失败，全部回滚
  return blog
end)
```

---

## Model:atomic(func) — 事务包装器

```lua
---@param func fun(request):any
---@return fun(request):any
```

适用于 web 请求处理:

```lua
local handler = Blog:atomic(function(request)
  Blog:create { name = request.name }
  Entry:create { blog_id = 1, headline = request.headline }
  return { code = 200 }
end)
-- handler 执行时自动包在事务中
```

---

## Sql:compact() — 紧凑模式

```lua
---@return self
```

结果以数组而非键值对形式返回（不包含列名，节省内存）:

```lua
local results = Blog:select('id', 'name'):compact():exec()
-- results = {{1, 'First Blog'}, {2, 'Second Blog'}}
-- 而非 {{id=1, name='First Blog'}, {id=2, name='Second Blog'}}
```

---

## Sql:raw(is_raw?) — 原始模式

```lua
---@param is_raw? boolean   -- 默认 true
---@return self
```

跳过 `model:load()` 处理，直接返回原始数据库结果（不进行 JSON 反序列化等转换）:

```lua
local results = Author:raw():exec()
-- results[1].resume 是原始 JSON 字符串，而非 Lua table
```

---

## Sql:filter(kwargs) — where + exec 快捷方式

```lua
---@param kwargs table
---@return Array<XodelInstance>
```

等价于 `self:where(kwargs):exec()`:

```lua
local entries = Entry:filter{blog_id=1}
-- 等价于 Entry:where{blog_id=1}:exec()
```
