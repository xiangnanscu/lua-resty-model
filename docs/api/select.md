# select

指定 SELECT 子句要查询的列。不调用时默认为 `SELECT *`。

## 函数签名

```lua
---@param a DBValue|fun(ctx:table):string
---@param b? DBValue
---@param ...? DBValue
---@return self
function Sql:select(a, b, ...)
```

## 基本用法

```lua
-- 查询单列
Blog:select('name'):exec()
-- SELECT T."name" FROM blog T

-- 查询多列
Entry:select('headline', 'rating'):exec()
-- SELECT T.headline, T.rating FROM entry T

-- 多次调用自动追加
Blog:select('name'):select('tagline'):exec()
-- SELECT T."name", T.tagline FROM blog T
```

## 外键跨表列

```lua
-- 跨外键选择列 (自动 JOIN)
Entry:select('headline', 'blog_id__name'):exec()
-- SELECT T.headline, T1."name"
-- FROM entry T INNER JOIN blog T1 ON (T.blog_id = T1.id)

-- 反向外键
Blog:select('name', 'entry__rating'):exec()
-- SELECT T."name", T1.rating
-- FROM blog T INNER JOIN entry T1 ON (T.id = T1.blog_id)
```

## 回调函数

```lua
Entry:select(function(ctx)
  return 'T.headline || T.body_text'
end):exec()
-- SELECT T.headline || T.body_text FROM entry T
```

## 传入 table (数组)

```lua
Entry:select({'headline', 'rating'}):exec()
-- SELECT T.headline, T.rating FROM entry T
```

---

# select_as

选择列并指定别名 (`AS`)。

## 函数签名

```lua
---@param kwargs {[string]: string}|string
---@param as? string
---@return self
function Sql:select_as(kwargs, as)
```

## 用法

```lua
-- 两参数形式
Blog:select_as('name', 'blog_name'):exec()
-- SELECT T."name" AS blog_name FROM blog T

-- table 形式: {字段名 = 别名}
Blog:select_as{name = 'blog_name', tagline = 'desc'}:exec()
-- SELECT T."name" AS blog_name, T.tagline AS "desc" FROM blog T

-- 支持跨表
Entry:select_as{blog_id__name = 'blog_name'}:exec()
-- SELECT T1."name" AS blog_name FROM entry T INNER JOIN blog T1 ON (T.blog_id = T1.id)
```

---

# select_literal

选择字面量表达式（不经过 `_parse_column` 解析）。

## 函数签名

```lua
---@param a DBValue
---@param b? DBValue
---@param ...? DBValue
---@return self
function Sql:select_literal(a, b, ...)
```

## 用法

```lua
Blog:select_literal("count(*)"):exec()
-- SELECT count(*) FROM blog T

Blog:select('name'):select_literal("count(*) OVER()"):exec()
-- SELECT T."name", count(*) OVER() FROM blog T
```

---

# select_literal_as

选择字面量表达式并指定别名。

## 函数签名

```lua
---@param kwargs {string: string}
---@return self
function Sql:select_literal_as(kwargs)
```

## 用法

```lua
Blog:select_literal_as{["count(*)"] = 'total'}:exec()
-- SELECT 'count(*)' AS total FROM blog T
```
