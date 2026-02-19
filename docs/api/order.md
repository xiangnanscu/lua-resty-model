# order / order_by

设置 `ORDER BY` 子句。`order_by` 是 `order` 的别名。

## 函数签名

```lua
---@param a string|table|fun(ctx:table):string
---@param ...? string|FClass
---@return self
function Sql:order(a, ...)
function Sql:order_by(...)  -- 别名
```

## 基本用法

```lua
-- 升序 (默认)
Entry:order('rating'):exec()
-- ORDER BY T.rating

-- 降序: 字段名前加 -
Entry:order('-rating'):exec()
-- ORDER BY T.rating DESC

-- 多列排序
Entry:order('-rating', 'pub_date'):exec()
-- ORDER BY T.rating DESC, T.pub_date
```

## 跨表排序

```lua
-- 按外键关联表的字段排序
Entry:order('blog_id__name'):exec()
-- ORDER BY T1."name" (自动 INNER JOIN blog)
```

## table 形式

```lua
Entry:order{'-rating', 'pub_date'}:exec()
-- ORDER BY T.rating DESC, T.pub_date
```

## 回调函数

```lua
Entry:order(function(ctx)
  return 'T.rating DESC NULLS LAST'
end):exec()
```

---

# nulls_first / nulls_last

设置排序中 NULL 值的位置。影响后续 `order` 调用。

## 函数签名

```lua
---@return self
function Sql:nulls_first()

---@return self
function Sql:nulls_last()
```

## 用法

```lua
Entry:nulls_last():order('rating'):exec()
-- ORDER BY T.rating NULLS LAST

Entry:nulls_first():order('-pub_date'):exec()
-- ORDER BY T.pub_date DESC NULLS FIRST
```
