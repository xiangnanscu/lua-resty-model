# update

设置 UPDATE 子句，通常配合 `where` 和 `exec` 使用。自动执行 `validate_update` 校验。

## 函数签名

```lua
---@param row Record
---@param columns? string[]
---@return self
function Sql:update(row, columns)
```

## 基本用法

```lua
-- 更新指定条件的记录
Blog:where{id = 1}:update{name = 'Updated Blog'}:returning('*'):exec()
-- UPDATE blog T SET name = 'Updated Blog' WHERE T.id = 1 RETURNING *

-- 更新多列
Entry:where{id = 1}:update{headline = 'New Headline', rating = 5}:returning('*'):exec()
```

## 使用 F() 表达式

```lua
-- 基于当前值更新
Entry:where{id = 1}:update{rating = F('rating') + 1}:returning('*'):exec()
-- UPDATE entry T SET rating = T.rating + 1 WHERE T.id = 1 RETURNING *
```

## 指定列

```lua
-- 仅更新指定列
Blog:where{id = 1}:update({name = 'New', tagline = 'Ignored'}, {'name'}):returning('*'):exec()
-- 只更新 name 列
```

---

# increase

对指定数值字段原子性加一（或指定值）。内部调用 `update` + `F()`。

## 函数签名

```lua
---@param name string|table
---@param amount? number
---@return self
function Sql:increase(name, amount)
```

## 用法

```lua
-- 默认 +1
Entry:where{id = 1}:increase('rating'):exec()
-- UPDATE entry T SET rating = T.rating + 1 WHERE T.id = 1

-- 指定增量
Entry:where{id = 1}:increase('rating', 5):exec()
-- UPDATE entry T SET rating = T.rating + 5 WHERE T.id = 1

-- 同时增加多个字段
Entry:where{id = 1}:increase{rating = 2, number_of_comments = 1}:exec()
-- UPDATE entry T SET rating = T.rating + 2, number_of_comments = T.number_of_comments + 1 WHERE T.id = 1
```

---

# decrease

对指定数值字段原子性减一（或指定值）。与 `increase` 对称。

## 函数签名

```lua
---@param name string|table
---@param amount? number
---@return self
function Sql:decrease(name, amount)
```

## 用法

```lua
Entry:where{id = 1}:decrease('rating'):exec()
-- UPDATE entry T SET rating = T.rating - 1 WHERE T.id = 1

Entry:where{id = 1}:decrease('rating', 3):exec()
-- UPDATE entry T SET rating = T.rating - 3 WHERE T.id = 1
```
