# where

条件过滤，为 SQL 查询添加 `WHERE` 子句。支持多种调用形式，多次调用以 `AND` 逻辑叠加。

## 函数签名

```lua
---@param cond table|string|fun(ctx:table):string
---@param op? string
---@param dval? DBValue
---@return self
function Sql:where(cond, op, dval)
```

## 调用链

```
Sql:where(cond, op, dval)
│
├── 分支 1: cond 是 table 且不是逻辑构建器 (普通键值对)
│   ├── Sql:_get_condition_token_from_table(cond)
│   │   ├── 遍历每个 key-value:
│   │   │   ├── Sql:_parse_column(key)
│   │   │   │   ├── 1.1 普通字段 (如 "name")
│   │   │   │   ├── 1.2 JSON 字段属性 (如 "resume__company")
│   │   │   │   ├── 1.4.2 外键字段跳转 (如 "blog_id__name")
│   │   │   │   │   └── Sql:_handle_manual_join(...)
│   │   │   │   ├── 4 反向外键 (如 "entry__rating")
│   │   │   │   │   └── Sql:_handle_manual_join(...)
│   │   │   │   └── 5 操作符后缀 (如 "age__gt" → op="gt")
│   │   │   └── Sql:_get_expr_token(value, key, op)
│   │   │       ├── Sql:_resolve_F(value)
│   │   │       └── EXPR_OPERATORS[op](key, value)
│   │   └── 用 " AND " 拼接所有 token
│   └── Sql:_handle_where_token(token, "(%s) AND (%s)")
│
├── 分支 2: cond 是 table 且是逻辑构建器 (Q 对象)
│   ├── Sql:_resolve_Q(cond)
│   │   ├── q.logic == "NOT" → 递归
│   │   ├── q.left AND q.right → 递归左右子树
│   │   └── 叶子节点 → _get_condition_token_from_table(q.cond)
│   └── Sql:_handle_where_token(token, "(%s) AND (%s)")
│
└── 分支 3: cond 是 string 或 function
    ├── Sql:_get_condition_token(cond, op, dval)
    │   ├── op == nil:
    │   │   ├── string → 直接返回原始 SQL
    │   │   └── function → cond(self._join_proxy_models)
    │   ├── dval == nil (两参数):
    │   │   └── _parse_column(cond) .. " = " .. as_literal(op)
    │   └── 三参数:
    │       └── _parse_column(cond) .. op .. as_literal(dval)
    └── Sql:_handle_where_token(token, "(%s) AND (%s)")
```

---

## 形式 1: Table 键值对（最常用）

传入一个 table，key 表示字段名（可带操作符后缀），value 表示匹配值。多个键值对以 `AND` 连接。

### 1.1 等值匹配

```lua
-- 单条件
Blog:where{name = 'First Blog'}:exec()
```

```sql
SELECT * FROM blog T WHERE T."name" = 'First Blog'
```

```lua
-- 多条件 (AND)
Entry:where{blog_id = 1, rating = 4}:exec()
```

```sql
SELECT * FROM entry T WHERE T.blog_id = 1 AND T.rating = 4
```

### 1.2 比较操作符后缀

通过 `字段名__操作符` 语法使用不同的比较运算：

```lua
-- 大于 gt
Entry:where{rating__gt = 3}:exec()
-- WHERE T.rating > 3

-- 大于等于 gte
Entry:where{rating__gte = 3}:exec()
-- WHERE T.rating >= 3

-- 小于 lt
Entry:where{rating__lt = 5}:exec()
-- WHERE T.rating < 5

-- 小于等于 lte
Entry:where{rating__lte = 5}:exec()
-- WHERE T.rating <= 5

-- 不等于 ne
Entry:where{rating__ne = 3}:exec()
-- WHERE T.rating <> 3
```

### 1.3 IN / NOT IN

```lua
Entry:where{id__in = {1, 2, 3}}:exec()
-- WHERE T.id IN (1, 2, 3)

Entry:where{id__notin = {1, 2, 3}}:exec()
-- WHERE T.id NOT IN (1, 2, 3)
```

子查询作为 IN 值：

```lua
Entry:where{blog_id__in = Blog:select('id'):where{name__contains = 'Blog'}}:exec()
-- WHERE T.blog_id IN (SELECT T.id FROM blog T WHERE T."name" LIKE '%Blog%' ESCAPE '\')
```

### 1.4 LIKE / ILIKE 模糊匹配

```lua
-- 包含 (大小写敏感)
Blog:where{name__contains = 'Blog'}:exec()
-- WHERE T."name" LIKE '%Blog%' ESCAPE '\'

-- 包含 (大小写不敏感)
Blog:where{name__icontains = 'blog'}:exec()
-- WHERE T."name" ILIKE '%blog%' ESCAPE '\'

-- 以...开头
Blog:where{name__startswith = 'First'}:exec()
-- WHERE T."name" LIKE 'First%' ESCAPE '\'

-- 以...开头 (不区分大小写)
Blog:where{name__istartswith = 'first'}:exec()
-- WHERE T."name" ILIKE 'first%' ESCAPE '\'

-- 以...结尾
Blog:where{name__endswith = 'Blog'}:exec()
-- WHERE T."name" LIKE '%Blog' ESCAPE '\'

-- 以...结尾 (不区分大小写)
Blog:where{name__iendswith = 'blog'}:exec()
-- WHERE T."name" ILIKE '%blog' ESCAPE '\'
```

### 1.5 BETWEEN / 日期提取

```lua
-- 范围查询
Entry:where{rating__range = {3, 5}}:exec()
-- WHERE T.rating BETWEEN 3 AND 5

-- 按年份
Entry:where{pub_date__year = 2023}:exec()
-- WHERE T.pub_date BETWEEN '2023-01-01' AND '2023-12-31'

-- 按月份
Entry:where{pub_date__month = 1}:exec()
-- WHERE EXTRACT('month' FROM T.pub_date) = '1'

-- 按天
Entry:where{pub_date__day = 15}:exec()
-- WHERE EXTRACT('day' FROM T.pub_date) = '15'
```

### 1.6 正则表达式

```lua
-- 大小写敏感正则
Blog:where{name__regex = '^First'}:exec()
-- WHERE T."name" ~ '^First'

-- 大小写不敏感正则
Blog:where{name__iregex = '^first'}:exec()
-- WHERE T."name" ~* '^first'
```

### 1.7 NULL 判断

```lua
Author:where{email__null = true}:exec()
-- WHERE T.email IS NULL

Author:where{email__null = false}:exec()
-- WHERE T.email IS NOT NULL

-- isnull 与 null 等价
Author:where{email__isnull = true}:exec()
-- WHERE T.email IS NULL
```

### 1.8 JSON 字段查询

对于定义了 `model` 属性的结构化 JSON 字段或其他 JSON 类型字段，`__` 分隔表示 JSON 路径：

```lua
-- 等值匹配 JSON 属性 (自动使用 json_eq 操作符)
Author:where{resume__company = 'Company A'}:exec()
-- WHERE (T.resume #> ['company']) = '"Company A"'

-- 多级路径
Author:where{resume__company__name = 'Foo'}:exec()
-- WHERE (T.resume #> ['company', 'name']) = '"Foo"'

-- JSON contains (@>)
Author:where{resume__contains = {company = 'Company A'}}:exec()
-- WHERE (T.resume) @> '{"company":"Company A"}'

-- contained_by (<@)
Author:where{resume__contained_by = {company = 'Company A', position = 'Developer'}}:exec()
-- WHERE (T.resume) <@ '{"company":"Company A","position":"Developer"}'

-- has_key (检查键是否存在)
Author:where{resume__has_key = 'company'}:exec()
-- WHERE (T.resume) ? company

-- has_keys (所有键存在)
Author:where{resume__has_keys = {'company', 'position'}}:exec()
-- WHERE (T.resume) ?& ['company', 'position']

-- has_any_keys (任一键存在)
Author:where{resume__has_any_keys = {'company', 'position'}}:exec()
-- WHERE (T.resume) ?| ['company', 'position']
```

### 1.9 F() 表达式（引用其他字段值）

使用 `F()` 在 WHERE 条件中引用当前记录的其他字段：

```lua
-- 比较两个字段
Entry:where{number_of_comments__gt = F('number_of_pingbacks')}:exec()
-- WHERE T.number_of_comments > T.number_of_pingbacks

-- F() 支持算术运算 (+, -, *, /, %, ^, ||)
Entry:where{rating__gt = F('number_of_comments') + 1}:exec()
-- WHERE T.rating > (T.number_of_comments + 1)

Entry:where{rating__gte = F('number_of_pingbacks') * 2}:exec()
-- WHERE T.rating >= (T.number_of_pingbacks * 2)
```

### 1.10 正向外键跨表查询（自动 JOIN）

通过 `外键字段__目标模型字段` 语法自动触发 JOIN：

```lua
-- Entry.blog_id → Blog.name
Entry:where{blog_id__name = 'First Blog'}:exec()
```

```sql
SELECT * FROM entry T
  INNER JOIN blog T1 ON (T.blog_id = T1.id)
WHERE T1."name" = 'First Blog'
```

```lua
-- 多级外键: ViewLog → Entry → Blog
ViewLog:where{entry_id__blog_id__name = 'First Blog'}:exec()
```

```sql
SELECT * FROM view_log T
  INNER JOIN entry T1 ON (T.entry_id = T1.id)
  INNER JOIN blog T2 ON (T1.blog_id = T2.id)
WHERE T2."name" = 'First Blog'
```

```lua
-- 外键跨表 + 操作符后缀
Entry:where{blog_id__name__contains = 'Blog'}:exec()
```

```sql
SELECT * FROM entry T
  INNER JOIN blog T1 ON (T.blog_id = T1.id)
WHERE T1."name" LIKE '%Blog%' ESCAPE '\'
```

```lua
-- 同一模型多次引用 (Entry 有 blog_id 和 reposted_blog_id 都指向 Blog)
Entry:where{blog_id__name = 'First Blog', reposted_blog_id__name = 'Second Blog'}:exec()
-- 自动为两个外键分别生成不同的 JOIN 别名
```

### 1.11 反向外键跨表查询

通过 `related_query_name__字段` 语法进行反向关联查询（自动 JOIN）：

```lua
-- Blog ← Entry (Entry 定义了 related_query_name = 'entry')
Blog:where{entry__rating = 4}:exec()
```

```sql
SELECT * FROM blog T
  INNER JOIN entry T1 ON (T.id = T1.blog_id)
WHERE T1.rating = 4
```

```lua
-- 反向外键 + 操作符后缀
Blog:where{entry__rating__gt = 3}:exec()
```

```sql
SELECT * FROM blog T
  INNER JOIN entry T1 ON (T.id = T1.blog_id)
WHERE T1.rating > 3
```

---

## 形式 2: 原始 SQL 字符串

传入字符串，直接作为 WHERE 条件，不做任何解析或转义。

```lua
Blog:where("T.\"name\" = 'First Blog'"):exec()
```

```sql
SELECT * FROM blog T WHERE T."name" = 'First Blog'
```

> ⚠️ **注意**：字符串不经过任何解析，需自行处理引号转义和表别名（默认主表别名为 `T`）。

---

## 形式 3: 两参数 (字段名, 值)

传入字段名和值，自动生成 `= ` 的等值判断。字段名支持 `_parse_column` 解析，包括外键跨表。

```lua
Blog:where("name", "First Blog"):exec()
```

```sql
SELECT * FROM blog T WHERE T."name" = 'First Blog'
```

```lua
-- 字段名支持外键跨表
Entry:where("blog_id__name", "First Blog"):exec()
```

```sql
SELECT * FROM entry T
  INNER JOIN blog T1 ON (T.blog_id = T1.id)
WHERE T1."name" = 'First Blog'
```

---

## 形式 4: 三参数 (字段名, 操作符, 值)

传入字段名、PostgreSQL 操作符和值。操作符需为合法的 PG 操作符（`=`, `<>`, `<`, `>`, `<=`, `>=`, `!=`, `LIKE`, `ILIKE`, `IN`, `NOT IN`, …），系统会进行合法性校验。

```lua
Entry:where("rating", ">", 3):exec()
-- WHERE T.rating > 3

Entry:where("rating", ">=", 3):exec()
-- WHERE T.rating >= 3

Entry:where("rating", "<>", 3):exec()
-- WHERE T.rating <> 3

Entry:where("headline", "LIKE", '%Entry%'):exec()
-- WHERE T.headline LIKE '%Entry%'
```

---

## 形式 5: 回调函数

传入一个函数，该函数接收 `ctx` 参数（JOIN 上下文中各表的代理模型信息），返回 WHERE 条件字符串。

```lua
-- 简单用法
Blog:where(function(ctx)
  return 'T."name" IS NOT NULL AND T.id > 0'
end):exec()
```

```sql
SELECT * FROM blog T WHERE T."name" IS NOT NULL AND T.id > 0
```

```lua
-- 在有 JOIN 的场景下使用 ctx
Entry:where(function(ctx)
  -- ctx 在 JOIN 模式下提供各表的列映射
  return string.format("%s = %s",
    ctx[1].blog_id,   -- 主表 Entry 的 blog_id 列
    ctx[2].id          -- JOIN 的 Blog 表的 id 列
  )
end):exec()
```

---

## 形式 6: Q 对象（复合逻辑）

使用 `Q` 构建器进行复杂逻辑组合。支持运算符重载：

- `*` → AND
- `/` → OR
- `-` (一元) → NOT

```lua
local Q = Model.Q

-- OR 逻辑
Blog:where(Q{name = 'First Blog'} / Q{name = 'Second Blog'}):exec()
```

```sql
SELECT * FROM blog T
WHERE (T."name" = 'First Blog') OR (T."name" = 'Second Blog')
```

```lua
-- AND 逻辑
Blog:where(Q{name = 'First Blog'} * Q{id = 1}):exec()
```

```sql
SELECT * FROM blog T
WHERE (T."name" = 'First Blog') AND (T.id = 1)
```

```lua
-- NOT 逻辑
Blog:where(-Q{name = 'First Blog'}):exec()
```

```sql
SELECT * FROM blog T WHERE NOT (T."name" = 'First Blog')
```

```lua
-- 复合嵌套
Blog:where(
  (Q{name = 'First Blog'} / Q{name = 'Second Blog'}) * -Q{id__gt = 100}
):exec()
```

```sql
SELECT * FROM blog T
WHERE ((T."name" = 'First Blog') OR (T."name" = 'Second Blog'))
  AND NOT (T.id > 100)
```

```lua
-- Q 内也支持操作符后缀
Blog:where(Q{name__contains = 'Blog'} / Q{id__in = {1, 2, 3}}):exec()
```

```sql
SELECT * FROM blog T
WHERE (T."name" LIKE '%Blog%' ESCAPE '\') OR (T.id IN (1, 2, 3))
```

---

## 多次调用叠加

多次调用 `where` 时，条件以 `AND` 叠加：

```lua
Blog:where{id = 1}:where{name = 'First Blog'}:exec()
```

```sql
SELECT * FROM blog T
WHERE (T.id = 1) AND (T."name" = 'First Blog')
```

不同形式可混合使用：

```lua
Entry:where{blog_id = 1}:where("rating", ">", 3):where{pub_date__year = 2023}:exec()
```

```sql
SELECT * FROM entry T
WHERE ((T.blog_id = 1) AND (T.rating > 3))
  AND (T.pub_date BETWEEN '2023-01-01' AND '2023-12-31')
```

---

## where 变体方法

| 方法                 | table 内条件连接 | 与已有 `_where` 连接 | 典型场景                |
| -------------------- | :--------------: | :------------------: | ----------------------- |
| `where(table)`       |      `AND`       |        `AND`         | 常规 AND 过滤（默认）   |
| `where_or(table)`    |       `OR`       |        `AND`         | table 内部 OR，整体 AND |
| `or_where(table)`    |      `AND`       |         `OR`         | table 内部 AND，整体 OR |
| `or_where_or(table)` |       `OR`       |         `OR`         | 全部以 OR 连接          |

### 变体示例

```lua
-- where + where → (A AND B) AND (C)
Blog:where{id = 1, name = 'a'}:where{tagline = 'b'}:exec()
-- WHERE (T.id = 1 AND T."name" = 'a') AND (T.tagline = 'b')

-- where + or_where → (A) OR (B)
Blog:where{id = 1}:or_where{id = 2}:exec()
-- WHERE T.id = 1 OR T.id = 2

-- where_or → (A) AND (B OR C)
Blog:where{id = 3}:where_or{id = 1, name = 'a'}:exec()
-- WHERE (T.id = 3) AND (T.id = 1 OR T."name" = 'a')

-- or_where_or → (A) OR (B OR C)
Blog:where{id = 3}:or_where_or{id = 1, name = 'a'}:exec()
-- WHERE T.id = 3 OR T.id = 1 OR T."name" = 'a'
```

---

## 完整操作符后缀参考

| 操作符后缀      | 生成的 SQL                                  | 示例值类型           |
| --------------- | ------------------------------------------- | -------------------- | ---------------- |
| `eq` (默认)     | `key = value`                               | 任意标量             |
| `lt`            | `key < value`                               | 数字/字符串          |
| `lte`           | `key <= value`                              | 数字/字符串          |
| `gt`            | `key > value`                               | 数字/字符串          |
| `gte`           | `key >= value`                              | 数字/字符串          |
| `ne`            | `key <> value`                              | 任意标量             |
| `in`            | `key IN (v1, v2, ...)`                      | table (数组)         |
| `notin`         | `key NOT IN (v1, v2, ...)`                  | table (数组)         |
| `contains`      | `key LIKE '%value%'`                        | 字符串               |
| `icontains`     | `key ILIKE '%value%'`                       | 字符串               |
| `startswith`    | `key LIKE 'value%'`                         | 字符串               |
| `istartswith`   | `key ILIKE 'value%'`                        | 字符串               |
| `endswith`      | `key LIKE '%value'`                         | 字符串               |
| `iendswith`     | `key ILIKE '%value'`                        | 字符串               |
| `range`         | `key BETWEEN v1 AND v2`                     | `{v1, v2}`           |
| `year`          | `key BETWEEN 'YYYY-01-01' AND 'YYYY-12-31'` | 数字 (年份)          |
| `month`         | `EXTRACT('month' FROM key) = 'value'`       | 数字 (1-12)          |
| `day`           | `EXTRACT('day' FROM key) = 'value'`         | 数字 (1-31)          |
| `regex`         | `key ~ 'pattern'`                           | 字符串               |
| `iregex`        | `key ~* 'pattern'`                          | 字符串               |
| `null`          | `key IS NULL` / `key IS NOT NULL`           | boolean              |
| `isnull`        | `key IS NULL` / `key IS NOT NULL`           | boolean              |
| `has_key`       | `(key) ? value`                             | 字符串 (键名)        |
| `has_keys`      | `(key) ?& [v1, v2]`                         | table (键名数组)     |
| `has_any_keys`  | `(key) ?                                    | [v1, v2]`            | table (键名数组) |
| `json_contains` | `(key) @> 'json'`                           | table (JSON 对象)    |
| `json_eq`       | `(key) = 'json'`                            | 任意 (JSON 化后比较) |
| `contained_by`  | `(key) <@ 'json'`                           | table (JSON 对象)    |

> **注意**: `json_contains` 和 `json_eq` 通常不直接作为后缀使用，而是由 JSON 字段路径解析自动映射。当字段定义了 `model` 属性时，`contains` 自动映射为 `json_contains`，`eq` 自动映射为 `json_eq`。
