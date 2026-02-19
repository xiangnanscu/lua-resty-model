# delete

设置 DELETE 操作。可选传入 WHERE 条件。

## 函数签名

```lua
---@param cond? table|string|fun(ctx:table):string
---@param op? string
---@param dval? DBValue
---@return self
function Sql:delete(cond, op, dval)
```

## 基本用法

```lua
-- 删除指定条件的记录
Blog:delete{id = 1}:exec()
-- DELETE FROM blog T WHERE T.id = 1

-- 等同于
Blog:where{id = 1}:delete():exec()

-- 带 RETURNING
Blog:delete{name = 'Old Blog'}:returning('*'):exec()
-- DELETE FROM blog T WHERE T."name" = 'Old Blog' RETURNING *
```

## 条件支持所有 where 形式

```lua
-- 字符串条件
Blog:delete("T.id > 100"):exec()

-- 三参数
Blog:delete("id", ">", 100):exec()

-- Q 对象
Blog:delete(Q{id = 1} / Q{id = 2}):exec()
```

## 配合跨表

```lua
-- 删除 + USING (有 JOIN 时自动转换)
Entry:where{blog_id__name = 'Old Blog'}:delete():returning('*'):exec()
-- DELETE FROM entry T USING blog T1 WHERE (T.blog_id = T1.id) AND (T1."name" = 'Old Blog') RETURNING *
```
