# upsert

PostgreSQL `INSERT ... ON CONFLICT ... DO UPDATE`。根据唯一键判断：存在则更新，不存在则插入。

## 函数签名

```lua
---@param rows Record[]|Sql
---@param key? Keys    唯一键（字符串或字符串数组），默认取模型 primary_key 或 unique_together
---@param columns? string[]  要插入/更新的列，默认取 rows 的所有键
---@return self
function Sql:upsert(rows, key, columns)
```

## 基本用法

```lua
-- 按 name (unique) 唯一键 upsert
Blog:upsert(
  {{name = 'First Blog', tagline = 'Updated tagline'}},
  'name'
):returning('*'):exec()
-- INSERT INTO blog AS T (name, tagline)
-- VALUES ('First Blog', 'Updated tagline')
-- ON CONFLICT (name) DO UPDATE SET tagline = EXCLUDED.tagline
-- RETURNING *
```

## 复合唯一键

```lua
-- 使用多个字段作为唯一键
Model:upsert(rows, {'inst_id', 'name'}):returning('*'):exec()
-- ON CONFLICT (inst_id, name) DO UPDATE SET ...
```

## 从子查询 upsert

```lua
-- 从 SELECT 子查询 upsert
Blog:upsert(
  OtherBlog:select('name', 'tagline'),
  'name'
):returning('*'):exec()
```

---

# merge

批量 merge 操作：用 CTE `WITH ... AS (VALUES ...)` 构造虚拟表，然后通过 `UPDATE ... FROM` 和 `INSERT ... SELECT` 实现「存在则更新，不存在则插入」。

## 函数签名

```lua
---@param rows Record[]
---@param key? Keys
---@param columns? string[]
---@return self
function Sql:merge(rows, key, columns)
```

## 用法

```lua
Blog:merge(
  {
    {name = 'First Blog', tagline = 'new tagline'},
    {name = 'New Blog', tagline = 'hello'}
  },
  'name'
):returning('*'):exec()
```

生成类似：

```sql
WITH V(name, tagline) AS (VALUES ('First Blog', 'new tagline'), ('New Blog', 'hello')),
  U AS (UPDATE blog T SET tagline = V.tagline FROM V WHERE T."name" = V.name RETURNING T.*)
INSERT INTO blog (name, tagline)
  SELECT V.* FROM V WHERE NOT EXISTS (SELECT 1 FROM U WHERE U."name" = V.name)
RETURNING *
```

---

# updates

批量更新：通过 CTE 构造虚拟表，用 `UPDATE ... FROM` 批量更新匹配行。

## 函数签名

```lua
---@param rows Record[]|Sql
---@param key? Keys
---@param columns? string[]
---@return self
function Sql:updates(rows, key, columns)
```

## 用法

```lua
Entry:updates(
  {
    {id = 1, rating = 5},
    {id = 2, rating = 3}
  },
  'id',
  {'id', 'rating'}
):returning('*'):exec()
```

生成类似：

```sql
WITH V(id, rating) AS (VALUES (1::integer, 5::integer), (2, 3))
UPDATE entry T SET rating = V.rating FROM V WHERE T.id = V.id RETURNING *
```

## 从子查询批量更新

```lua
Entry:updates(
  Blog:select('id', 'name'):where{id__lt = 5},
  'id'
):returning('*'):exec()
```

---

# align

同步操作：先 upsert 所有提供的行，然后 **删除** 不在提供列表中的行。适用于完整覆盖式同步。

## 函数签名

```lua
---@param rows Record[]
---@param key? Keys
---@param columns? string[]
function Sql:align(rows, key, columns)
```

## 用法

```lua
-- 同步 blog 表，使其精确匹配提供的行
Blog:align(
  {
    {name = 'Blog A', tagline = 'desc A'},
    {name = 'Blog B', tagline = 'desc B'}
  },
  'name'
):returning('*'):exec()
```

生成类似：

```sql
WITH U AS (
  INSERT INTO blog AS T (name, tagline)
  VALUES ('Blog A', 'desc A'), ('Blog B', 'desc B')
  ON CONFLICT (name) DO UPDATE SET tagline = EXCLUDED.tagline
  RETURNING T."name"
)
DELETE FROM blog T WHERE (T."name") NOT IN (SELECT "name" FROM U) RETURNING *
```
