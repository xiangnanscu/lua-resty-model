# 05 — JOIN 与关联查询

> JOIN 的各种形式（字符串、Model、回调）以及 select_related 用法。

## JOIN 方法一览

| 方法                               | JOIN 类型    |
| ---------------------------------- | ------------ |
| `join(args, key, op?, val?)`       | `INNER JOIN` |
| `inner_join(args, key, op?, val?)` | `INNER JOIN` |
| `left_join(args, key, op?, val?)`  | `LEFT JOIN`  |
| `right_join(args, key, op?, val?)` | `RIGHT JOIN` |
| `full_join(args, key, op?, val?)`  | `FULL JOIN`  |
| `cross_join(args, key, op?, val?)` | `CROSS JOIN` |

所有 JOIN 方法签名相同:

```lua
---@param join_args string|Xodel   -- 表名字符串 或 Model 对象
---@param key string|fun(ctx:table):string  -- JOIN 条件
---@param op? string
---@param val? DBValue
---@return self
```

---

## 形式 1: 通过外键名 JOIN (最简)

传入外键字段名，自动推导 JOIN 条件:

```lua
-- join_args 是一个外键字段名
Entry:select('headline', 'blog_id'):join('blog_id'):exec()
-- SELECT T."headline", T."blog_id"
-- FROM entry T INNER JOIN blog T1 ON (T."blog_id" = T1."id")
```

---

## 形式 2: 字符串表名 + 条件

```lua
-- 形式 2a: 三参数 (表名, 左列, 右列)
Entry:select('headline'):join('blog', 'T.blog_id', '=', 'blog.id'):exec()
-- FROM entry T INNER JOIN blog ON (T.blog_id = blog.id)

-- 形式 2b: 两参数 (表名, 条件字符串)
Entry:select('headline'):join('blog', 'T.blog_id = blog.id'):exec()
-- FROM entry T INNER JOIN blog ON (T.blog_id = blog.id)
```

---

## 形式 3: Model 对象 + 回调函数

传入 Model 对象时，第二个参数是回调函数，通过 `ctx` 参数获取各表别名:

```lua
-- join_args 是 Model 对象, key 是回调函数
Entry:select('headline'):join(Blog, function(ctx)
  return string.format("%s = %s",
    ctx.entry.blog_id,    -- T."blog_id"
    ctx.blog.id            -- T1."id"
  )
end):exec()
-- FROM entry T INNER JOIN blog T1 ON (T."blog_id" = T1."id")
```

回调函数的 `ctx` 参数是一个代理对象，按 `table_name` 索引，提供 `table_alias.column` 格式的列引用。

---

## 各种 JOIN 类型示例

```lua
-- LEFT JOIN
Entry:select('headline', 'blog_id__name')
  :left_join(Blog, function(ctx)
    return string.format("%s = %s", ctx.entry.blog_id, ctx.blog.id)
  end):exec()

-- RIGHT JOIN
Blog:select('name'):right_join('entry', 'T.id = entry.blog_id'):exec()

-- FULL JOIN
Blog:select('name'):full_join('entry', 'T.id = entry.blog_id'):exec()

-- CROSS JOIN
Blog:select('name'):cross_join('entry', 'T.id = entry.blog_id'):exec()
```

---

## 隐式 JOIN (通过 where/select 的跨表语法)

在 `where` 或 `select` 中使用 `__` 分隔的跨表字段会自动注册 JOIN:

```lua
-- select 跨表字段自动 JOIN
Entry:select('headline', 'blog_id__name'):exec()
-- SELECT T."headline", T1."name" AS "blog_id__name"
-- FROM entry T INNER JOIN blog T1 ON (T."blog_id" = T1."id")

-- where 跨表字段自动 JOIN
Entry:where{blog_id__name='First Blog'}:exec()
-- SELECT * FROM entry T INNER JOIN blog T1 ON (T."blog_id" = T1."id")
-- WHERE T1."name" = 'First Blog'

-- 可通过 join_type 方法改变默认 JOIN 类型
Entry:join_type("LEFT"):where{blog_id__name='First Blog'}:exec()
-- FROM entry T LEFT JOIN blog T1 ON (T."blog_id" = T1."id")
```

---

## Sql:select_related(fk_name, select_names?, ...) — 关联查询

```lua
---@param fk_name string|ForeignkeyField    -- 外键字段名
---@param select_names string[]|string       -- 要选择的关联字段
---@param more_name? string
---@param ... string
---@return self
```

`select_related` 是高级关联查询方法，用于将外键展开为关联模型的字段:

### 调用形式

```lua
-- 形式1: 只传外键名（仅加入 JOIN，不额外选择字段）
Entry:select_related('blog_id'):exec()
-- 返回的 blog_id 字段值会被加载为 Blog Record 实例

-- 形式2: 字符串字段名
Entry:select_related('blog_id', 'name'):exec()
-- SELECT T."blog_id", T1."name" AS "blog_id__name"
-- FROM entry T INNER JOIN blog T1 ON (T."blog_id" = T1."id")

-- 形式3: 多字段（变参）
Entry:select_related('blog_id', 'name', 'tagline'):exec()
-- SELECT T."blog_id", T1."name" AS "blog_id__name", T1."tagline" AS "blog_id__tagline"

-- 形式4: 字段数组
Entry:select_related('blog_id', {'name', 'tagline'}):exec()
-- 同上

-- 形式5: 通配符 '*' 选择关联模型全部字段
Entry:select_related('blog_id', '*'):exec()
-- SELECT T."blog_id", T1."id" AS "blog_id__id", T1."name" AS "blog_id__name",
--        T1."tagline" AS "blog_id__tagline", T1."ctime" AS "blog_id__ctime", ...

-- 形式6: 嵌套关联 (多级外键)
ViewLog:select_related('entry_id', 'blog_id__name'):exec()
-- SELECT T."entry_id", T2."name" AS "entry_id__blog_id__name"
-- 会自动 JOIN entry 和 blog
```

### select_related 的数据加载

使用 `select_related` 后，`exec()` 返回的 Record 会自动将外键字段值还原为关联模型的 Record 实例:

```lua
local entries = Entry:select('headline'):select_related('blog_id', 'name', 'tagline'):exec()
for _, entry in ipairs(entries) do
  print(entry.headline)          -- 'First Entry'
  print(entry.blog_id.name)      -- 'First Blog'  (自动加载为 Blog Record)
  print(entry.blog_id.tagline)   -- 'Welcome to my blog'
end
```

---

## Sql:select_related_labels(names?) — 自动关联标签

```lua
---@param names? string[]
---@return self
```

自动为所有外键字段进行 `LEFT JOIN`，选择 `referenced_label_column` (标签列):

```lua
Entry:select_related_labels():exec()
-- 自动 LEFT JOIN 所有外键引用表，选择其标签列
```

---

## join_type(jtype) — 设置默认 JOIN 类型

```lua
---@param jtype string     -- "INNER"|"LEFT"|"RIGHT"|"FULL"
---@return self
```

影响后续隐式 JOIN (通过 `where`/`select` 的跨表语法触发的 JOIN) 的类型:

```lua
-- 默认是 INNER JOIN
Entry:where{blog_id__name='First Blog'}:exec()
-- ... INNER JOIN blog ...

-- 改为 LEFT JOIN
Entry:join_type("LEFT"):where{blog_id__name='First Blog'}:exec()
-- ... LEFT JOIN blog ...
```
