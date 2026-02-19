# 07 — 写入操作

> insert / update / upsert / merge / updates / align / gets / merge_gets / get_or_create 的详细用法。

## Sql:insert(rows, columns?) — 插入

```lua
---@param rows Record|Record[]|Sql   -- 单行、多行或子查询
---@param columns? string[]           -- 指定列 (默认 model.names)
---@return self
```

### 调用形式

```lua
-- 形式1: 单行插入
Blog:insert{name='New Blog', tagline='Hello'}:exec()
-- INSERT INTO blog AS T (name, tagline) VALUES ('New Blog', 'Hello')

-- 形式2: 单行 + returning
Blog:insert{name='New Blog'}:returning('*'):exec()
-- INSERT INTO blog AS T (name, tagline) VALUES ('New Blog', 'default tagline') RETURNING *

-- 形式3: 多行插入 (数组)
Store:insert{
  {name = 'Store A'},
  {name = 'Store B'}
}:exec()
-- INSERT INTO store AS T (name) VALUES ('Store A'), ('Store B')

-- 形式4: 指定列
Blog:insert({name='New Blog', tagline='Hello'}, {'name'}):exec()
-- INSERT INTO blog AS T (name) VALUES ('New Blog')

-- 形式5: 子查询插入
Blog:insert(
  Blog:select('name', 'tagline'):where{id__gt=0}
):exec()
-- INSERT INTO blog AS T (name, tagline) SELECT T."name", T."tagline" FROM blog T WHERE T."id" > 0

-- 形式6: RETURNING 子查询插入 (CTE)
Blog:insert(
  Entry:update{tagline='updated'}:returning{'name', 'tagline'}
):returning{'id', 'name'}:exec()
-- WITH D(name, tagline) AS (
--   UPDATE entry T SET tagline='updated' RETURNING T."name", T."tagline"
-- )
-- INSERT INTO blog AS T(name, tagline) SELECT name, tagline FROM D
-- RETURNING T."id", T."name"
```

### 数据校验

`insert` 默认会执行 `validate_create` 校验。可通过 `skip_validate()` 跳过:

```lua
Blog:skip_validate():insert{name='x'}:exec()
```

---

## Sql:update(row, columns?) — 更新

```lua
---@param row Record          -- 更新数据
---@param columns? string[]   -- 指定列 (默认 model.names)
---@return self
```

### 调用形式

```lua
-- 形式1: 基本更新 (需配合 where)
Blog:where{id=1}:update{tagline='Updated'}:exec()
-- UPDATE blog T SET "tagline" = 'Updated' WHERE T."id" = 1

-- 形式2: F 表达式更新
Entry:where{id=1}:update{rating = F('rating') + 1}:exec()
-- UPDATE entry T SET "rating" = (T."rating" + 1) WHERE T."id" = 1

-- 形式3: 指定更新列
Blog:where{id=1}:update({name='New', tagline='Hello'}, {'tagline'}):exec()
-- UPDATE blog T SET "tagline" = 'Hello' WHERE T."id" = 1

-- 形式4: 更新 + RETURNING
Blog:where{id=1}:update{tagline='Updated'}:returning('*'):exec()
-- UPDATE blog T SET "tagline" = 'Updated' WHERE T."id" = 1 RETURNING *

-- ⚠️ 不带 where 的 update 会更新全表！
Blog:update{tagline='All Updated'}:exec()
-- UPDATE blog T SET "tagline" = 'All Updated'
```

---

## Sql:upsert(rows, key?, columns?) — 插入或更新

```lua
---@param rows Record[]|Sql     -- 数据行或子查询
---@param key? Keys              -- 冲突键 (string 或 string[])
---@param columns? string[]      -- 列名
---@return self
```

PostgreSQL `INSERT ... ON CONFLICT DO UPDATE`。

### key 推导逻辑

如果不提供 `key`，按以下顺序自动推导:

1. `unique_together[1]` (联合唯一约束的第一组)
2. 第一个 `unique=true` 的字段
3. `primary_key`

### 调用形式

```lua
-- 形式1: 单行 upsert (自动推导 key 为 "name" 因为 unique=true)
Blog:upsert{
  {name = 'First Blog', tagline = 'updated by upsert'},
  {name = 'New Blog', tagline = 'inserted by upsert'}
}:exec()
-- INSERT INTO blog AS T (name, tagline)
-- VALUES ('First Blog', 'updated by upsert'), ('New Blog', 'inserted by upsert')
-- ON CONFLICT (name) DO UPDATE SET tagline = EXCLUDED.tagline

-- 形式2: 显式指定 key
Blog:upsert(
  { {name='Blog1', tagline='t1'}, {name='Blog2', tagline='t2'} },
  'name'
):exec()

-- 形式3: 联合 key
Blog:upsert(
  { {name='Blog1', tagline='t1'} },
  {'name', 'tagline'}          -- 联合冲突键
):exec()
-- ON CONFLICT (name, tagline) DO UPDATE SET ...

-- 形式4: 指定列
Blog:upsert(
  { {name='Blog1', tagline='t1'} },
  'name',
  {'name', 'tagline'}          -- 仅操作这些列
):exec()

-- 形式5: 子查询 upsert
Blog:upsert(
  Entry:update{tagline='updated'}:returning{'name', 'tagline'},
  'name'
):exec()
-- WITH D(name, tagline) AS (UPDATE entry T SET ... RETURNING ...)
-- INSERT INTO blog AS T (name, tagline) SELECT name, tagline FROM D
-- ON CONFLICT (name) DO UPDATE SET tagline = EXCLUDED.tagline

-- 形式6: upsert + returning
Blog:upsert{
  {name = 'First Blog', tagline = 'updated'}
}:returning('*'):exec()
```

---

## Sql:merge(rows, key?, columns?) — 合并 (仅插入新行)

```lua
---@param rows Record[]       -- 数据行
---@param key? Keys            -- 判断是否存在的键
---@param columns? string[]
---@return self
```

`merge` 与 `upsert` 不同：**仅插入不存在的行，已存在的行不更新**。

### 实现原理

使用 CTE + LEFT JOIN + WHERE IS NULL 实现:

```lua
-- 仅当 name 不存在时插入
Blog:merge{
  {name = 'First Blog', tagline = 'wont update'},   -- 已存在，跳过
  {name = 'Third Blog', tagline = 'will insert'}     -- 不存在，插入
}:exec()

-- SQL:
-- WITH
--   V(name, tagline) AS (VALUES ('First Blog', 'wont update'), ('Third Blog', 'will insert'))
--   U AS (SELECT * FROM blog WHERE name IN (SELECT name FROM V))
-- INSERT INTO blog AS T (name, tagline)
-- SELECT V.name, V.tagline FROM V
--   LEFT JOIN U AS W ON (V.name = W.name)
-- WHERE W.name IS NULL
```

### 指定 key

```lua
-- key 自动推导 (优先 unique 字段)
Blog:merge{
  {name = 'Blog1'}, {name = 'Blog2'}
}:exec()

-- 显式指定
Blog:merge(
  { {name = 'Blog1', tagline = 't1'} },
  'name'
):exec()

-- 联合 key
Blog:merge(
  { {name = 'Blog1', tagline = 't1'} },
  {'name', 'tagline'}
):exec()

-- 仅当 key 列相同时才被视为重复
Blog:merge(
  { {name = 'Blog1'} },
  'name',
  {'name'}        -- 仅操作 name 列
):exec()
```

---

## Sql:updates(rows, key?, columns?) — 批量更新

```lua
---@param rows Record[]|Sql     -- 更新数据
---@param key? Keys              -- 匹配键
---@param columns? string[]
---@return self
```

批量更新多行：通过 CTE VALUES + UPDATE FROM 实现。

```lua
-- 批量更新 Blog 的 tagline
Blog:updates{
  {name = 'First Blog', tagline = 'batch updated 1'},
  {name = 'Second Blog', tagline = 'batch updated 2'},
}:exec()
-- WITH V(name, tagline) AS (VALUES ('First Blog', 'batch updated 1'), ('Second Blog', 'batch updated 2'))
-- UPDATE blog T SET tagline = V.tagline
-- FROM V
-- WHERE V.name = T.name

-- 显式指定 key
Blog:updates(
  { {name='First Blog', tagline='updated'} },
  'name'
):exec()

-- 联合 key
Blog:updates(
  { {id=1, name='Updated', tagline='Updated'} },
  {'id', 'name'}
):exec()

-- 子查询 updates
Blog:updates(
  Entry:select('name', 'body_text'):where{id__gt=0},
  'name',
  {'name', 'tagline'}
):exec()
```

---

## Sql:align(rows, key?, columns?) — 对齐

```lua
---@param rows Record[]
---@param key? Keys
---@param columns? string[]
---@return self
```

`align` = `upsert` + 删除多余行。确保表中仅包含传入的行。

```lua
-- 对齐 Blog 数据：upsert 给定行，删除不在列表中的行
Blog:align{
  {name = 'Blog A', tagline = 'Tag A'},
  {name = 'Blog B', tagline = 'Tag B'},
}:returning('*'):exec()

-- SQL:
-- WITH U AS (
--   INSERT INTO blog AS T (name, tagline) VALUES ...
--   ON CONFLICT (name) DO UPDATE SET tagline = EXCLUDED.tagline
--   RETURNING T.name
-- )
-- DELETE FROM blog T
-- WHERE (T.name) NOT IN (SELECT name FROM U)
-- RETURNING *
```

---

## Sql:gets(keys, columns?) — 批量获取

```lua
---@param keys Record[]          -- 要查询的键值对数组
---@param columns? string[]      -- 键的列名
---@return self
```

通过 CTE VALUES + RIGHT JOIN 批量获取多行。

```lua
-- 联合唯一键批量获取
local Resume = Model:create_model {
  auto_primary_key = false,
  table_name = 'resume',
  unique_together = { 'start_date', 'end_date', 'company', 'position' },
  fields = { ... }
}

Resume:gets{
  {start_date='2025-01-01', end_date='2025-01-02', company='company1'},
  {start_date='2025-01-03', end_date='2025-02-02', company='company2'},
}:exec()

-- SQL:
-- WITH V(start_date, end_date, company) AS (
--   VALUES ('2025-01-01'::date, '2025-01-02'::date, 'company1'::varchar),
--          ('2025-01-03', '2025-02-02', 'company2')
-- )
-- SELECT * FROM resume T
-- RIGHT JOIN V ON (V.start_date = T.start_date AND V.end_date = T.end_date AND V.company = T.company)

-- 单键批量获取
Blog:gets{
  {name='First Blog'},
  {name='Second Blog'},
  {name='Non Existent'}  -- 不存在的记录也会返回（RIGHT JOIN）
}:exec()
```

---

## Sql:merge_gets(rows, key, columns?) — 合并查询

```lua
---@param rows Record[]
---@param key Keys
---@param columns? string[]
---@return self
```

与 `gets` 类似，但额外 SELECT 主表字段和 V.\* :

```lua
Blog:select('name'):merge_gets(
  { {id=1, name='aa'}, {id=2, name='bb'} },
  'id'
):exec()

-- SQL:
-- WITH V(id, name) AS (
--   VALUES (1::integer, 'aa'::varchar), (2, 'bb')
-- )
-- SELECT T."name", V.*
-- FROM blog T
-- RIGHT JOIN V ON (V.id = T.id)
```

---

## Sql:get_or_create(params, defaults?, columns?) — 获取或创建

```lua
---@param params table          -- 查找条件
---@param defaults? table       -- 创建时的额外默认值
---@param columns? string[]     -- 返回的列
---@return XodelInstance, boolean  -- 记录, 是否新创建
```

原子操作：查找匹配 `params` 的记录，不存在则创建。

```lua
-- 获取或创建
local blog, created = Blog:get_or_create(
  { name = 'My Blog' },              -- 查找条件
  { tagline = 'Default Tagline' }      -- 创建时的额外值
)

if created then
  print("新创建的记录:", blog.id)
else
  print("已存在的记录:", blog.id)
end

-- params 和 defaults 合并后作为创建数据
-- 查找仅使用 params
```

---

## Sql:skip_validate(bool?) — 跳过校验

```lua
---@param bool? boolean    -- 默认 true
---@return self
```

对 `insert` / `upsert` / `merge` / `updates` 等操作跳过数据校验:

```lua
Blog:skip_validate():insert{name='x'}:exec()
```

---

## 批量操作 key 推导规则

当 `key` 参数为 `nil` 时，按以下优先级自动推导：

1. `unique_together[1]` — 联合唯一约束的第一组
2. 第一个 `unique = true` 的字段
3. `primary_key` — 主键

```lua
-- Blog 有 name(unique=true)，所以 key 自动为 'name'
Blog:upsert{ {name='Blog1', tagline='t1'} }:exec()

-- Resume 有 unique_together = {'start_date','end_date','company','position'}
-- 所以 key 自动为 {'start_date','end_date','company','position'}
Resume:gets{ {start_date='2025-01-01', end_date='2025-01-02', company='c1'} }:exec()
```

---

## 批量操作 columns 推导规则

当 `columns` 参数为 `nil` 时:

- `insert`: 使用 `model.names`（全部可写字段）
- `upsert/merge/updates`: 从第一行数据的 keys 中提取列名
