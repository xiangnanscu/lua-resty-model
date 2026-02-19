# returning / returning_literal

设置 `RETURNING` 子句，用于让 INSERT / UPDATE / DELETE 操作返回指定列。

## 函数签名

```lua
---@param a DBValue|fun(ctx:table):string
---@param b? DBValue
---@param ...? DBValue
---@return self
function Sql:returning(a, b, ...)

---@param a DBValue
---@param b? DBValue
---@param ...? DBValue
---@return self
function Sql:returning_literal(a, b, ...)
```

## returning

```lua
-- 返回所有列
Blog:insert{name = 'New'}:returning('*'):exec()
-- RETURNING *

-- 返回指定列
Blog:insert{name = 'New'}:returning('id', 'name'):exec()
-- RETURNING T.id, T."name"

-- 多次调用追加
Blog:insert{name = 'New'}:returning('id'):returning('name'):exec()
-- RETURNING T.id, T."name"

-- UPDATE RETURNING
Blog:where{id = 1}:update{name = 'Updated'}:returning('*'):exec()

-- DELETE RETURNING
Blog:delete{id = 1}:returning('id'):exec()
```

## returning_literal

与 `returning` 类似，但值不经过 `_parse_column` 解析，直接作为字面量：

```lua
Blog:insert{name = 'New'}:returning_literal("currval('blog_id_seq')"):exec()
```
