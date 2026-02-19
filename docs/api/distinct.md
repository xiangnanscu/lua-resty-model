# distinct

设置 `DISTINCT` 或 `DISTINCT ON(columns)` 去重。

## 函数签名

```lua
---@param ... string
---@return self
function Sql:distinct(...)
```

## 用法

```lua
-- 全局去重
Blog:select('name'):distinct():exec()
-- SELECT DISTINCT T."name" FROM blog T

-- DISTINCT ON (PostgreSQL特有)
Entry:distinct('blog_id'):order('blog_id', '-rating'):exec()
-- SELECT DISTINCT ON(T.blog_id) * FROM entry T ORDER BY T.blog_id, T.rating DESC
```

---

# distinct_on

显式设置 `DISTINCT ON(columns)`，同时将这些列自动添加到 `ORDER BY` 前面（PostgreSQL 要求 DISTINCT ON 列必须出现在 ORDER BY 开头）。

## 函数签名

```lua
---@param ... DBValue
---@return self
function Sql:distinct_on(...)
```

## 用法

```lua
Entry:distinct_on('blog_id'):order('-rating'):exec()
-- SELECT DISTINCT ON(T.blog_id) * FROM entry T ORDER BY T.blog_id, T.rating DESC
-- 自动将 blog_id 插入 ORDER BY 前面
```
