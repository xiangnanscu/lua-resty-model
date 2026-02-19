# 04 — where 深度解析

> 详细说明 `where` 的全部调用形式、操作符后缀、跨表查询、JSON 字段查询和 Q 对象。

## 函数签名

```lua
---@param cond table|string|fun(ctx:table):string
---@param op? string
---@param dval? DBValue
---@return self
function Sql:where(cond, op, dval)
```

---

## 调用链分析

```
Sql:where(cond, op, dval)
│
├── 分支①: cond 是 table 且不是 Q 对象 → 普通键值对
│   └── _get_condition_token_from_table(cond)
│       ├── 遍历每个 key-value
│       │   ├── _parse_column(key) → 解析字段名 + 操作符
│       │   └── _get_expr_token(value, key, op) → 生成 SQL 表达式
│       └── 用 " AND " 拼接所有 token
│
├── 分支②: cond 是 Q 对象 → 复合逻辑
│   └── _resolve_Q(cond) → 递归解析 Q 树
│
└── 分支③: cond 是 string 或 function
    └── _get_condition_token(cond, op, dval)
        ├── op == nil → 原始 SQL 字符串 或 回调函数
        ├── dval == nil → "column = value"
        └── 三参数 → "column op value"
```

---

## 形式 1: Table 键值对 (最常用)

```lua
Blog:where{name='First Blog'}:exec()
-- WHERE T."name" = 'First Blog'
```

### 多条件 (AND)

```lua
Entry:where{blog_id=1, rating=4}:exec()
-- WHERE T."blog_id" = 1 AND T."rating" = 4
```

### 操作符后缀

通过 `字段名__操作符` 语法使用不同比较操作:

```lua
-- 比较操作符
Entry:where{rating__gt=3}:exec()
-- WHERE T."rating" > 3

Entry:where{rating__gte=3}:exec()
-- WHERE T."rating" >= 3

Entry:where{rating__lt=5}:exec()
-- WHERE T."rating" < 5

Entry:where{rating__lte=5}:exec()
-- WHERE T."rating" <= 5

Entry:where{rating__ne=3}:exec()
-- WHERE T."rating" <> 3
```

### IN / NOT IN

```lua
Entry:where{id__in={1,2,3}}:exec()
-- WHERE T."id" IN (1, 2, 3)

Entry:where{id__notin={1,2,3}}:exec()
-- WHERE T."id" NOT IN (1, 2, 3)
```

### LIKE / ILIKE

```lua
Blog:where{name__contains='Blog'}:exec()
-- WHERE T."name" LIKE '%Blog%' ESCAPE '\'

Blog:where{name__icontains='blog'}:exec()
-- WHERE T."name" ILIKE '%blog%' ESCAPE '\'

Blog:where{name__startswith='First'}:exec()
-- WHERE T."name" LIKE 'First%' ESCAPE '\'

Blog:where{name__istartswith='first'}:exec()
-- WHERE T."name" ILIKE 'first%' ESCAPE '\'

Blog:where{name__endswith='Blog'}:exec()
-- WHERE T."name" LIKE '%Blog' ESCAPE '\'

Blog:where{name__iendswith='blog'}:exec()
-- WHERE T."name" ILIKE '%blog' ESCAPE '\'
```

### BETWEEN / 日期

```lua
Entry:where{rating__range={3,5}}:exec()
-- WHERE T."rating" BETWEEN 3 AND 5

Entry:where{pub_date__year=2023}:exec()
-- WHERE T."pub_date" BETWEEN '2023-01-01' AND '2023-12-31'

Entry:where{pub_date__month=1}:exec()
-- WHERE EXTRACT('month' FROM T."pub_date") = '1'

Entry:where{pub_date__day=15}:exec()
-- WHERE EXTRACT('day' FROM T."pub_date") = '15'
```

### 正则

```lua
Blog:where{name__regex='^First'}:exec()
-- WHERE T."name" ~ '^First'

Blog:where{name__iregex='^first'}:exec()
-- WHERE T."name" ~* '^first'
```

### NULL 检查

```lua
Author:where{email__null=true}:exec()
-- WHERE T."email" IS NULL

Author:where{email__null=false}:exec()
-- WHERE T."email" IS NOT NULL

-- isnull 与 null 功能相同
Author:where{email__isnull=true}:exec()
-- WHERE T."email" IS NULL
```

### F() 表达式

使用 `F()` 引用其他字段的值:

```lua
Entry:where{number_of_comments__gt=F('number_of_pingbacks')}:exec()
-- WHERE T."number_of_comments" > T."number_of_pingbacks"

Entry:where{rating__gt=F('number_of_comments') + 1}:exec()
-- WHERE T."rating" > (T."number_of_comments" + 1)
```

---

## 形式 2: 原始 SQL 字符串

```lua
Blog:where("T.\"name\" = 'First Blog'"):exec()
-- WHERE T."name" = 'First Blog'

-- ⚠️ 注意: 字符串不经过任何解析，需要自行处理引号和表别名
```

---

## 形式 3: 两参数 (字段名, 值)

```lua
Blog:where("name", "First Blog"):exec()
-- WHERE T."name" = 'First Blog'

-- 字段名支持操作符后缀和跨表查询
Entry:where("blog_id__name", "First Blog"):exec()
-- WHERE T1."name" = 'First Blog' (自动 JOIN blog)
```

---

## 形式 4: 三参数 (字段名, 操作符, 值)

```lua
Entry:where("rating", ">", 3):exec()
-- WHERE T."rating" > 3

Entry:where("rating", ">=", 3):exec()
-- WHERE T."rating" >= 3

Entry:where("rating", "<>", 3):exec()
-- WHERE T."rating" <> 3

-- 支持的 PG 操作符: =, <>, <, >, <=, >=, !=, LIKE, ILIKE, IN, NOT IN, ...
```

---

## 形式 5: 回调函数

```lua
Blog:where(function(ctx)
  return 'T."name" IS NOT NULL AND T."id" > 0'
end):exec()
-- WHERE T."name" IS NOT NULL AND T."id" > 0

-- ctx 参数在有 JOIN 时提供各表的代理信息
Entry:where(function(ctx)
  return string.format("%s = %s",
    ctx.entry.blog_id,      -- T."blog_id"
    ctx.blog.id             -- T1."id"
  )
end):exec()
```

---

## 形式 6: Q 对象 (复合逻辑)

```lua
local Q = Model.Q

-- OR: 使用 / 运算符
Blog:where(Q{name='First Blog'} / Q{name='Second Blog'}):exec()
-- WHERE (T."name" = 'First Blog') OR (T."name" = 'Second Blog')

-- AND: 使用 * 运算符
Blog:where(Q{name='First Blog'} * Q{id=1}):exec()
-- WHERE (T."name" = 'First Blog') AND (T."id" = 1)

-- NOT: 使用 - 一元运算符
Blog:where(-Q{name='First Blog'}):exec()
-- WHERE NOT (T."name" = 'First Blog')

-- 复合嵌套
Blog:where(
  (Q{name='First Blog'} / Q{name='Second Blog'}) * -Q{id__gt=100}
):exec()
-- WHERE ((T."name" = 'First Blog') OR (T."name" = 'Second Blog'))
--   AND NOT (T."id" > 100)

-- Q 内也支持操作符后缀
Blog:where(Q{name__contains='Blog'} / Q{id__in={1,2,3}}):exec()
-- WHERE (T."name" LIKE '%Blog%' ESCAPE '\') OR (T."id" IN (1, 2, 3))
```

---

## 跨表查询 (自动 JOIN)

where 的 table 键中使用 `__` 分隔，可以跨越外键关系。详见 [05-auto-join.md](05-auto-join.md)。

```lua
-- 正向: Entry.blog_id → Blog.name
Entry:where{blog_id__name='First Blog'}:exec()
-- WHERE T1."name" = 'First Blog' (自动 INNER JOIN blog)

-- 多级: ViewLog → Entry → Blog
ViewLog:where{entry_id__blog_id__name='First Blog'}:exec()

-- 反向: Blog ← Entry (via related_query_name='entry')
Blog:where{entry__rating__gt=3}:exec()
-- WHERE T1."rating" > 3 (自动 INNER JOIN entry)

-- 跨表 + 操作符后缀组合
Entry:where{blog_id__name__contains='Blog'}:exec()
```

---

## JSON 字段查询

对于 JSON/JSONB 类型字段，`__` 分隔表示 JSON 路径:

```lua
-- 假设有一个 data 字段是 json 类型
-- data__a 表示 data -> 'a'
Model:where{data__a='value'}:exec()
-- WHERE (T."data" #> ['a']) = '"value"'

-- 嵌套路径
Model:where{data__a__b='value'}:exec()
-- WHERE (T."data" #> ['a','b']) = '"value"'

-- JSON contains
Model:where{data__a__contains='x'}:exec()
-- WHERE (T."data" -> 'a') @> '"x"'
```

---

## where 变体对比

| 方法                 | 内部条件连接 | 与已有 where 连接 | 用途                    |
| -------------------- | ------------ | ----------------- | ----------------------- |
| `where(table)`       | `AND`        | `AND`             | 常规 AND 过滤           |
| `where_or(table)`    | `OR`         | `AND`             | table 内 OR，与已有 AND |
| `or_where(table)`    | `AND`        | `OR`              | table 内 AND，与已有 OR |
| `or_where_or(table)` | `OR`         | `OR`              | 全部 OR                 |

### 完整示例

```lua
-- where + where: (A AND B) AND (C AND D)
Blog:where{id=1, name='a'}:where{tagline='b'}:exec()
-- WHERE (T."id" = 1 AND T."name" = 'a') AND (T."tagline" = 'b')

-- where + or_where: (A AND B) OR (C AND D)
Blog:where{id=1}:or_where{id=2}:exec()
-- WHERE T."id" = 1 OR T."id" = 2

-- where_or: (A OR B) AND (C)
Blog:where{id=3}:where_or{id=1, name='a'}:exec()
-- WHERE (T."id" = 3) AND (T."id" = 1 OR T."name" = 'a')

-- or_where_or: (A) OR (B OR C)
Blog:where{id=3}:or_where_or{id=1, name='a'}:exec()
-- WHERE T."id" = 3 OR T."id" = 1 OR T."name" = 'a'
```
