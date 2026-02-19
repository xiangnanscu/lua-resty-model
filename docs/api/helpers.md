# as

设置表别名。主表默认别名为 `T`。

## 函数签名

```lua
---@param table_alias string
---@return self
function Sql:as(table_alias)
```

## 用法

```lua
Blog:as('b'):exec()
-- SELECT * FROM blog b
```

---

# from

设置 `FROM` 子句，覆盖或追加来源表。

## 函数签名

```lua
---@param ... string
---@return self
function Sql:from(...)
```

## 用法

```lua
-- 从 CTE 查询
Blog:with('vt', some_sql):from('vt'):exec()

-- 多次调用追加
Blog:from('other_table'):exec()
```

---

# using

设置 `USING` 子句，用于 DELETE 操作中引入关联表。

## 函数签名

```lua
---@param ... string
function Sql:using(...)
```

## 用法

```lua
-- 通常由跨表 delete 自动生成，不需要手动调用
Entry:where{blog_id__name = 'Old'}:delete():exec()
-- DELETE FROM entry T USING blog T1 WHERE ...
```

---

# copy

深拷贝当前 Sql 实例。修改拷贝不影响原实例。

## 函数签名

```lua
---@return self
function Sql:copy()
```

## 用法

```lua
local base = Blog:where{id__gt = 0}
local q1 = base:copy():where{name = 'A'}:exec()
local q2 = base:copy():where{name = 'B'}:exec()
-- base 不受影响
```

---

# clear

重置 Sql 实例的所有查询状态（保留 model, table_name, \_as），可重新构建查询。

## 函数签名

```lua
---@return self
function Sql:clear()
```

---

# skip_validate

跳过 insert/update/upsert/merge 等操作的数据校验。

## 函数签名

```lua
---@param bool? boolean  默认 true
---@return self
function Sql:skip_validate(bool)
```

## 用法

```lua
Blog:skip_validate():insert{name = 'Raw Data'}:returning('*'):exec()
```

---

# join_type

设置后续自动 JOIN (由 `_parse_column` 触发) 的默认 JOIN 类型。

## 函数签名

```lua
---@param jtype string  "INNER"|"LEFT"|"RIGHT"|"FULL"
---@return self
function Sql:join_type(jtype)
```

## 用法

```lua
-- 使外键跨表查询使用 LEFT JOIN 而非默认的 INNER JOIN
Entry:join_type("LEFT"):where{blog_id__name = 'Blog'}:exec()
-- FROM entry T LEFT JOIN blog T1 ON (T.blog_id = T1.id)
```

---

# get_table

返回完整表名 (含别名)。

## 函数签名

```lua
---@return string
function Sql:get_table()
```

## 用法

```lua
local t = Blog:create_sql():get_table()
-- "blog T"
```

---

# statement

将当前 Sql 实例编译为完整 SQL 字符串。不执行查询。

## 函数签名

```lua
---@return string
function Sql:statement()
```

## 用法

```lua
local sql_text = Blog:where{id = 1}:statement()
-- "SELECT * FROM blog T WHERE T.id = 1"

-- 用于调试
print(Blog:where{name__contains = 'Blog'}:statement())
```

---

# prepend / append

在主 SQL 语句前/后插入额外的 SQL 语句，用分号 `;` 连接，一次性发送给数据库执行。

## 函数签名

```lua
---@param ... Sql|string
---@return self
function Sql:prepend(...)

---@param ... Sql|string
---@return self
function Sql:append(...)
```

## 用法

```lua
-- 在主查询前执行其他语句
local lock_sql = "LOCK TABLE blog IN SHARE MODE"
Blog:prepend(lock_sql):exec()
-- LOCK TABLE blog IN SHARE MODE;SELECT * FROM blog T

-- 传入 Sql 实例
local cleanup = Blog:delete{id__gt = 100}
Blog:append(cleanup):exec()
```
