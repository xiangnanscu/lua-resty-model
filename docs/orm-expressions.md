# F 表达式 / Q 对象 / 聚合函数

## F 表达式

`F` 用于引用数据库字段值，可以构建字段间运算表达式。灵感来自 [Django F()](https://docs.djangoproject.com/en/dev/ref/models/expressions/#django.db.models.F)。

### 导入

```lua
local F = require("model").F
-- 或
local F = require("model.f")
```

### 基本用法

```lua
-- 引用字段
F('rating')     -- 引用 rating 字段

-- 在 update 中使用: 自增
Entry:update { rating = F('rating') + 1 }:where{ id = 1 }:exec()
-- UPDATE entry T SET rating = T.rating + 1 WHERE T.id = 1

-- 自减
Entry:update { rating = F('rating') - 1 }:where{ id = 1 }:exec()
-- UPDATE entry T SET rating = T.rating - 1 WHERE T.id = 1

-- 字段间运算
Book:update { price = F('price') * 0.9 }:exec()
-- UPDATE book T SET price = T.price * 0.9

-- 复合运算
Book:annotate { value = F('price') / F('pages') }:exec()
-- SELECT (T.price / T.pages) AS value, * FROM book T
```

### 支持的运算符

| 运算 | Lua 语法                           | SQL                           |
| ---- | ---------------------------------- | ----------------------------- |
| 加法 | `F('a') + F('b')` 或 `F('a') + 10` | `(T.a + T.b)` 或 `(T.a + 10)` |
| 减法 | `F('a') - F('b')`                  | `(T.a - T.b)`                 |
| 乘法 | `F('a') * F('b')`                  | `(T.a * T.b)`                 |
| 除法 | `F('a') / F('b')`                  | `(T.a / T.b)`                 |
| 取模 | `F('a') % F('b')`                  | `(T.a % T.b)`                 |
| 幂   | `F('a') ^ 2`                       | `(T.a ^ 2)`                   |
| 连接 | `F('a') .. F('b')`                 | `(T.a \|\| T.b)`              |

### 在 WHERE 中使用

```lua
-- 比较两个字段
Entry:where { number_of_comments = F('number_of_pingbacks') }:exec()
-- WHERE T.number_of_comments = T.number_of_pingbacks

-- 字段运算后比较
Entry:where { rating__gt = F('number_of_comments') + F('number_of_pingbacks') }:exec()
-- WHERE T.rating > (T.number_of_comments + T.number_of_pingbacks)
```

### 在 annotate 中使用

```lua
Book:annotate { price_per_page = F('price') / F('pages') }:exec()
-- SELECT (T.price / T.pages) AS price_per_page, * FROM book T
```

### 跨表 F 引用

F 表达式中的字段名支持双下划线语法（自动 JOIN）：

```lua
-- 虽然不太常见，但 F 引用会经过 _parse_column 解析
Entry:update { headline = F('blog_id__name') }:where{ id = 1 }:exec()
-- 自动 JOIN blog 并引用 blog.name
```

### increase / decrease 快捷方式

这两个方法底层使用 F 表达式：

```lua
-- 单字段
Entry:increase('rating'):where{ id = 1 }:exec()
-- 等价于 Entry:update{ rating = F('rating') + 1 }:where{id=1}:exec()

Entry:increase('rating', 5):where{ id = 1 }:exec()
-- 等价于 Entry:update{ rating = F('rating') + 5 }:where{id=1}:exec()

Entry:decrease('rating', 2):where{ id = 1 }:exec()
-- 等价于 Entry:update{ rating = F('rating') - 2 }:where{id=1}:exec()

-- 多字段
Entry:increase { rating = 1, number_of_comments = 2 }:where{ id = 1 }:exec()
-- UPDATE entry T SET
--   rating = T.rating + 1,
--   number_of_comments = T.number_of_comments + 2
-- WHERE T.id = 1

Entry:decrease { rating = 1, number_of_pingbacks = 3 }:where{ id = 1 }:exec()
```

---

## Q 对象

`Q` 用于构建复合逻辑条件（AND / OR / NOT），灵感来自 [Django Q()](https://docs.djangoproject.com/en/dev/ref/models/querysets/#django.db.models.Q)。

### 导入

```lua
local Q = require("model").Q
-- 或
local Q = require("model.q")
```

### 基本用法

```lua
-- 创建 Q 对象
Q { name = 'Tom' }
Q { age__gt = 18 }
Q { rating__in = {4, 5} }
```

### 逻辑运算符

| 运算 | Lua 语法          | 含义              |
| ---- | ----------------- | ----------------- |
| AND  | `Q{a=1} * Q{b=2}` | `(a=1) AND (b=2)` |
| OR   | `Q{a=1} / Q{b=2}` | `(a=1) OR (b=2)`  |
| NOT  | `-Q{a=1}`         | `NOT (a=1)`       |

注意：Lua 中 `*` 是乘法运算符，这里被重载为 AND；`/` 是除法运算符，被重载为 OR；`-` 是取负运算符，被重载为 NOT。

### 在 WHERE 中使用

```lua
-- OR
Blog:where(Q{name='Blog A'} / Q{name='Blog B'}):exec()
-- WHERE (T.name = 'Blog A') OR (T.name = 'Blog B')

-- AND (显式)
Entry:where(Q{blog_id=1} * Q{rating__gt=3}):exec()
-- WHERE (T.blog_id = 1) AND (T.rating > 3)

-- NOT
Blog:where(-Q{name='Excluded'}):exec()
-- WHERE NOT (T.name = 'Excluded')

-- 复合嵌套
Entry:where(
  (Q{blog_id=1} * Q{rating__gt=3}) / (Q{blog_id=2} * -Q{headline__contains='old'})
):exec()
-- WHERE ((T.blog_id = 1) AND (T.rating > 3)) OR ((T.blog_id = 2) AND (NOT (T.headline LIKE '%old%')))

-- Q 对象内支持所有字段查找语法
Blog:where(Q{name__startswith='A'} / Q{tagline__icontains='lua'}):exec()
-- WHERE (T.name LIKE 'A%') OR (T.tagline ILIKE '%lua%')

-- Q 对象内支持跨表查找
Blog:where(Q{entry__rating__gt=3} / Q{name='Default Blog'}):exec()
-- INNER JOIN entry T0 ON ... WHERE (T0.rating > 3) OR (T.name = 'Default Blog')
```

### 在 HAVING 中使用

```lua
Blog:annotate{ cnt = Count('entry') }
  :group('name')
  :having(Q{cnt__gt=1} / Q{cnt__lt=10})
  :exec()
-- HAVING (COUNT(T0.id) > 1) OR (COUNT(T0.id) < 10)
```

### Q 与 where 的区别

- `where{a=1, b=2}` → `a = 1 AND b = 2` (键值对始终 AND)
- `where_or{a=1, b=2}` → `a = 1 OR b = 2`
- `Q{a=1} / Q{b=2}` → `(a = 1) OR (b = 2)` (更灵活的组合)
- `Q{a=1, b=2}` → `a = 1 AND b = 2` (单个 Q 内部默认 AND)

多次 `where` 调用总是 AND 连接：

```lua
Blog:where(Q{a=1}/Q{b=2}):where{c=3}:exec()
-- WHERE ((a = 1) OR (b = 2)) AND (c = 3)
```

---

## 聚合函数

### 导入

```lua
local Count    = require("model").Count
local Sum      = require("model").Sum
local Avg      = require("model").Avg
local Max      = require("model").Max
local Min      = require("model").Min
local StdDev   = require("model").StdDev     -- 样本标准差
local Variance = require("model").Variance   -- 样本方差
```

### 用法

所有聚合函数可用于 `annotate`、`alias`、`aggregate` 方法，接受一个字段名参数：

```lua
Count('column')     -- COUNT(column)
Sum('column')       -- SUM(column)
Avg('column')       -- AVG(column)
Max('column')       -- MAX(column)
Min('column')       -- MIN(column)
StdDev('column')    -- STDDEV_SAMP(column)（样本标准差）
Variance('column')  -- VAR_SAMP(column)（样本方差）
```

`StdDev` / `Variance` 使用**样本**版本（分母为 n-1）。如需总体版本，需自己写 `F('STDDEV_POP(col)')` 或在 SQL 层处理。

### 基本聚合

```lua
-- 统计每个 Blog 的 Entry 数量
Blog:annotate { entry_count = Count('entry') }:group('name'):exec()
-- SELECT COUNT(T0.id) AS entry_count, T.name
-- FROM blog T LEFT JOIN entry T0 ON (T.id = T0.blog_id)
-- GROUP BY T.name

-- 返回结果: { {name='Blog 1', entry_count=3}, {name='Blog 2', entry_count=1} }
```

### 多聚合

```lua
Book:annotate {
  total_pages = Sum('pages'),
  avg_price   = Avg('price'),
  max_rating  = Max('rating'),
  min_price   = Min('price'),
  book_count  = Count('id'),
}:group('author'):exec()
-- SELECT
--   SUM(T.pages) AS total_pages,
--   AVG(T.price) AS avg_price,
--   MAX(T.rating) AS max_rating,
--   MIN(T.price) AS min_price,
--   COUNT(T.id) AS book_count,
--   T.author
-- FROM book T GROUP BY T.author
```

### 自动命名

当使用数字索引时，聚合函数自动以 `column + suffix` 命名：

```lua
Blog:annotate { Count('entry') }:group('name'):exec()
-- 别名自动为 'entry_count' (column='entry', suffix='_count')
-- 即 COUNT(T0.id) AS entry_count

Book:annotate { Sum('pages'), Avg('price') }:group('author'):exec()
-- SUM(T.pages) AS pages_sum
-- AVG(T.price) AS price_avg
```

| 函数  | suffix   |
| ----- | -------- |
| Count | `_count` |
| Sum   | `_sum`   |
| Avg   | `_avg`   |
| Max   | `_max`   |
| Min   | `_min`   |

### 跨表聚合

聚合函数的列名支持双下划线跨表语法（自动 LEFT JOIN）：

```lua
-- 聚合反向外键字段
Blog:annotate { total_comments = Sum('entry__number_of_comments') }:group('name'):exec()
-- LEFT JOIN entry T0 ON (T.id = T0.blog_id)
-- SELECT SUM(T0.number_of_comments) AS total_comments, T.name

-- 聚合多级关联
Blog:annotate { view_count = Count('entry__view_log') }:group('name'):exec()
-- LEFT JOIN entry T0 ON (T.id = T0.blog_id)
-- LEFT JOIN view_log T1 ON (T0.id = T1.entry_id)
-- SELECT COUNT(T1.id) AS view_count, T.name
```

注意：聚合时自动使用 LEFT JOIN（而非 INNER JOIN），确保没有关联记录的主表行也出现在结果中。

### 配合 HAVING / WHERE / ORDER

```lua
-- HAVING: 过滤聚合结果
Blog:annotate { cnt = Count('entry') }
  :group('name')
  :having { cnt__gte = 2 }
  :exec()
-- HAVING COUNT(T0.id) >= 2

-- WHERE: 在聚合中使用注解名
Blog:annotate { cnt = Count('entry') }
  :group('name')
  :where { cnt__lt = 100 }
  :exec()
-- 注意: 此处 cnt 在 WHERE 中会被解析为聚合表达式

-- ORDER: 按聚合结果排序
Blog:annotate { cnt = Count('entry') }
  :group('name')
  :order('-cnt')
  :exec()
-- ORDER BY COUNT(T0.id) DESC
```

---

## 工具函数

### Model.as_literal(value)

将 Lua 值转为 SQL 字面量：

```lua
Model.as_literal('hello')    -- "'hello'"
Model.as_literal(42)         -- "42"
Model.as_literal(true)       -- "TRUE"
Model.as_literal({1,2,3})   -- "(1, 2, 3)"
Model.as_literal(nil)        -- 报错
```

### Model.as_token(value)

将值转为 SQL token（不加引号）：

```lua
Model.as_token('hello')     -- "hello"
Model.as_token(42)          -- "42"
Model.as_token({1,2,3})    -- "1, 2, 3"
```

### Model.token(s)

创建原始 SQL token（函数形式，延迟求值）：

```lua
local raw = Model.token("NOW()")
Blog:insert{ name = 'test', ctime = raw }:exec()
-- 插入时 ctime 的值为 NOW() (不加引号)
```

### Model.NULL

表示 SQL NULL：

```lua
Entry:update { rating = Model.NULL }:where{id=1}:exec()
-- UPDATE entry T SET rating = NULL WHERE T.id = 1
```

### Model.DEFAULT

表示 SQL DEFAULT：

```lua
Blog:insert { name = 'test', tagline = Model.DEFAULT }:exec()
-- INSERT INTO blog AS T (name, tagline) VALUES ('test', DEFAULT)
```

---

## 完整示例

### 博客统计面板

```lua
-- 获取每个博客的文章数、平均评分、最新发布日期
local stats = Blog
  :annotate {
    entry_count = Count('entry'),
    avg_rating  = Avg('entry__rating'),
    latest_pub  = Max('entry__pub_date'),
  }
  :group('name')
  :having { entry_count__gt = 0 }
  :order('-entry_count')
  :limit(10)
  :exec()
```

### 复杂条件查询

```lua
-- 查找满足以下条件的文章:
-- (评分>4 且 博客名包含'tech') 或 (评论数>10 且 不是2020年之前发布的)
local entries = Entry:where(
  (Q{rating__gt=4} * Q{blog_id__name__contains='tech'})
  /
  (Q{number_of_comments__gt=10} * -Q{pub_date__lt='2020-01-01'})
):order('-pub_date'):limit(20):exec()
```

### 批量操作示例

```lua
-- 批量更新价格 (按作者)
Book:updates {
  { author = 1, price = 29.99 },
  { author = 2, price = 19.99 },
}:exec()

-- 对齐操作 (同步数据)
Blog:align {
  { name = 'Blog A', tagline = 'Active blog' },
  { name = 'Blog B', tagline = 'Another active blog' },
}:exec()
-- Blog 表中只保留这两条记录 (匹配 name)

-- 获取或创建
local blog, created = Blog:get_or_create(
  { name = 'Unique Blog' },
  { tagline = 'Created if not exists' }
)
```

### 事务中的复合操作

```lua
local result = Blog:transaction(function()
  local blog = Blog:create { name = 'New Blog' }
  Entry:insert {
    { blog_id = blog.id, headline = 'First Post', rating = 5 },
    { blog_id = blog.id, headline = 'Second Post', rating = 4 },
  }:exec()
  Entry:increase('rating'):where{ blog_id = blog.id, rating__lt = 5 }:exec()
  return blog
end)
```
