# limit

设置 `LIMIT` 子句，限制返回的行数。

## 函数签名

```lua
---@param n integer|string
---@return self
function Sql:limit(n)
```

## 用法

```lua
Blog:limit(10):exec()
-- SELECT * FROM blog T LIMIT 10

-- 字符串自动转数字
Blog:limit("5"):exec()
-- LIMIT 5
```

## 约束

- `n` 必须为正整数
- 不可超过 `Sql.MAX_LIMIT`（默认值由系统配置）
- `nil` 值被忽略（不设限制）

---

# offset

设置 `OFFSET` 子句，跳过指定行数。

## 函数签名

```lua
---@param n integer|string
---@return self
function Sql:offset(n)
```

## 用法

```lua
Blog:limit(10):offset(20):exec()
-- SELECT * FROM blog T LIMIT 10 OFFSET 20

-- 分页示例
local page = 3
local page_size = 10
Blog:limit(page_size):offset((page - 1) * page_size):exec()
```

## 约束

- `n` 必须为非负整数
- `nil` 值被忽略
