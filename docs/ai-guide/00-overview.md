# lua-resty-model — AI 快速指南

> 一个借鉴 Django ORM 思想、面向 PostgreSQL 的 Lua ORM 库，运行于 OpenResty。

## 目录

| 文档                                                                 | 内容                                                                |
| -------------------------------------------------------------------- | ------------------------------------------------------------------- |
| [01-model-definition.md](01-model-definition.md)                     | Model 定义、字段类型、继承与 Mixin                                  |
| [02-model-crud.md](02-model-crud.md)                                 | Model 层 CRUD：create / save / validate                             |
| [03-query-basics.md](03-query-basics.md)                             | 查询基础：select / where / order / limit / offset                   |
| [04-where-deep-dive.md](04-where-deep-dive.md)                       | where 深度解析：操作符后缀、跨表查询、Q 对象                        |
| [05-auto-join.md](05-auto-join.md)                                   | 双下划线自动 JOIN：跨表查询、反向查询、JSON 路径、select_related    |
| [06-aggregation.md](06-aggregation.md)                               | 聚合与注解：annotate / group_by / having / F / Count / Sum          |
| [07-insert-update-upsert-merge.md](07-insert-update-upsert-merge.md) | 写入操作：insert / update / upsert / merge / updates / align / gets |
| [08-advanced.md](08-advanced.md)                                     | 高级用法：set 操作、CTE、递归查询、事务                             |
| [09-exec-and-helpers.md](09-exec-and-helpers.md)                     | 执行与辅助：exec / get / count / exists / flat / compact            |
| [10-subquery.md](10-subquery.md)                                     | 子查询：Sql 对象作为值、where_in 子查询、INSERT SELECT、嵌套        |

---

## 快速开始

### 1. 引入与初始化

```lua
local Model = require("xodel.model")
local Q = Model.Q       -- 复合条件构建器 (AND / OR / NOT)
local F = Model.F       -- 字段引用表达式
local Sum = Model.Sum   -- 聚合函数
local Avg = Model.Avg
local Max = Model.Max
local Min = Model.Min
local Count = Model.Count
```

### 2. 定义 Model

```lua
-- 方式1: create_model (推荐)
local Blog = Model:create_model {
  table_name = 'blog',
  fields = {
    { "name",    maxlength = 20, unique = true },
    { "tagline", type = 'text',  default = 'default tagline' },
  }
}

-- 方式2: 直接调用 Model(...)，等同于 Model:mix(BaseModel, ...)
local Store = Model {
  table_name = 'store',
  fields = {
    { "name", maxlength = 300 },
  }
}
```

每个 Model 自动包含 `id` (serial主键)、`ctime` (创建时间)、`utime` (更新时间) 三个字段。可通过 `auto_primary_key = false` 禁用自动主键。

### 3. 两大 API 分类

#### 📦 Model API — 模型定义与数据校验

| API                                      | 说明                          |
| ---------------------------------------- | ----------------------------- |
| `Model:create_model(opts)`               | 创建模型类                    |
| `Model:create(input)`                    | 验证+插入+返回 Record 实例    |
| `Model:save(input, names?, key?)`        | 自动判断 create 或 update     |
| `Model:save_create(input, names?, key?)` | 验证+插入                     |
| `Model:save_update(input, names?, key?)` | 验证+更新                     |
| `Model:validate(input, names?, key?)`    | 自动判断校验方式              |
| `Model:validate_create(input, names?)`   | 创建校验                      |
| `Model:validate_update(input, names?)`   | 更新校验                      |
| `Model:transaction(callback)`            | 事务                          |
| `Model:atomic(func)`                     | 返回事务包装函数              |
| `Model:load(data)`                       | 从数据库原始数据加载为 Record |
| `Model:create_record(data)`              | 创建 Record 实例(不写库)      |
| `Model:to_json(names?)`                  | 导出模型元信息                |

#### 🔍 Sql API — SQL 查询构建 (链式调用)

所有 Sql 方法均可通过 Model 代理调用 (自动创建 Sql 实例):

```lua
-- 以下两种方式等价:
Blog:where{name='test'}:exec()
Blog:create_sql():where{name='test'}:exec()
```

**核心查询:**

| API                              | 说明     |
| -------------------------------- | -------- |
| `:select(...)`                   | 选择字段 |
| `:where(cond, op?, dval?)`       | 过滤条件 |
| `:order(...)` / `:order_by(...)` | 排序     |
| `:limit(n)`                      | 限制数量 |
| `:offset(n)`                     | 偏移     |
| `:group(...)` / `:group_by(...)` | 分组     |
| `:having(cond)`                  | 分组过滤 |
| `:distinct(...)`                 | 去重     |

**写入操作:**

| API                              | 说明                       |
| -------------------------------- | -------------------------- |
| `:insert(rows, columns?)`        | 插入                       |
| `:update(row, columns?)`         | 更新                       |
| `:delete(cond?, op?, dval?)`     | 删除                       |
| `:upsert(rows, key?, columns?)`  | 插入或更新 (ON CONFLICT)   |
| `:merge(rows, key?, columns?)`   | 合并 (仅插入新行)          |
| `:updates(rows, key?, columns?)` | 批量更新                   |
| `:align(rows, key?, columns?)`   | 对齐 (upsert + 删除多余行) |

**执行与结果:**

| API                         | 说明                          |
| --------------------------- | ----------------------------- |
| `:exec()`                   | 执行并返回 Record[]           |
| `:execr()`                  | 执行并返回原始结果(不经 load) |
| `:get(cond?, op?, dval?)`   | 获取单条(找不到返回 false)    |
| `:count(cond?, op?, dval?)` | 返回计数                      |
| `:exists()`                 | 返回 boolean                  |
| `:flat(col?)`               | 返回扁平数组                  |
| `:statement()`              | 仅返回 SQL 字符串(不执行)     |

---

## 数据模型总览 (seed.lua)

以下是 seed.lua 中定义的完整数据模型及其关系：

```
User (users)
  ├── username: string(20), unique
  └── password: text

Blog (blog)
  ├── name: string(20), unique
  └── tagline: text, default='default tagline'

Author (author)
  ├── name: string(200), unique
  ├── email: email
  ├── age: integer [10, 100]
  └── resume: table(Resume)  ← 结构化JSON字段
       ├── start_date: date
       ├── end_date: date
       ├── company: string(20)
       ├── position: string(20)
       └── description: string(200)

Entry (entry)
  ├── blog_id → Blog (related_query_name='entry')
  ├── reposted_blog_id → Blog (related_query_name='reposted_entry')
  ├── headline: string(255)
  ├── body_text: text
  ├── pub_date: date
  ├── mod_date: date
  ├── number_of_comments: integer
  ├── number_of_pingbacks: integer
  └── rating: integer

ViewLog (view_log)
  ├── entry_id → Entry
  └── ctime: datetime

Publisher (publisher)
  └── name: string(300)

Book (book)
  ├── name: string(300)
  ├── pages: integer
  ├── price: float
  ├── rating: float
  ├── author → Author
  ├── publisher_id → Publisher
  └── pubdate: date

Store (store)
  └── name: string(300)
```

### 初始数据

| 表        | ID  | 关键数据                                               |
| --------- | --- | ------------------------------------------------------ |
| User      | 1   | admin                                                  |
| User      | 2   | user                                                   |
| Blog      | 1   | name='First Blog'                                      |
| Blog      | 2   | name='Second Blog'                                     |
| Author    | 1   | name='John Doe', age=30                                |
| Author    | 2   | name='Jane Smith', age=28                              |
| Entry     | 1   | blog_id=1, headline='First Entry', rating=4            |
| Entry     | 2   | blog_id=2, headline='Second Entry', rating=5           |
| Entry     | 3   | blog_id=1, headline='Third Entry', rating=4            |
| ViewLog   | 1   | entry_id=1                                             |
| ViewLog   | 2   | entry_id=2                                             |
| Publisher | 1   | name='Publisher A'                                     |
| Publisher | 2   | name='Publisher B'                                     |
| Book      | 1   | name='Book One', author=1, publisher_id=1, price=29.99 |
| Book      | 2   | name='Book Two', author=2, publisher_id=2, price=19.99 |
| Store     | 1   | name='Book Store A'                                    |
| Store     | 2   | name='Book Store B'                                    |

---

## 常用表达式辅助

### F() — 字段引用

```lua
local F = Model.F
-- 引用数据库字段值，支持算术运算
F("rating")            -- 引用 rating 字段
F("price") * 1.1       -- price * 1.1
F("price") + F("tax")  -- price + tax
F("first") .. F("last") -- first || last (字符串连接)
```

### Q() — 复合查询条件

```lua
local Q = Model.Q
-- AND: 使用 * 运算符
Q{name='a'} * Q{age=1}              -- name='a' AND age=1
-- OR: 使用 / 运算符
Q{name='a'} / Q{name='b'}           -- name='a' OR name='b'
-- NOT: 使用 - 一元运算符
-Q{name='a'}                        -- NOT (name='a')
-- 复合
(Q{name='a'} / Q{name='b'}) * -Q{age__lt=18}
```

### 聚合函数

```lua
Count("id")       -- COUNT(id)
Sum("price")      -- SUM(price)
Avg("rating")     -- AVG(rating)
Max("pages")      -- MAX(pages)
Min("price")      -- MIN(price)
```

---

## where 操作符速查表

通过字段名后缀 `__操作符` 使用 (全部 22 个):

| 后缀              | SQL                       | 示例                         |
| ----------------- | ------------------------- | ---------------------------- | -------------------------------- |
| `eq` (默认)       | `= val`                   | `{name='Tom'}`               |
| `lt`              | `< val`                   | `{age__lt=18}`               |
| `lte`             | `<= val`                  | `{age__lte=18}`              |
| `gt`              | `> val`                   | `{age__gt=18}`               |
| `gte`             | `>= val`                  | `{age__gte=18}`              |
| `ne`              | `<> val`                  | `{age__ne=18}`               |
| `in`              | `IN (...)`                | `{id__in={1,2,3}}`           |
| `notin`           | `NOT IN (...)`            | `{id__notin={1,2,3}}`        |
| `contains`        | `LIKE '%val%'`            | `{name__contains='test'}`    |
| `icontains`       | `ILIKE '%val%'`           | `{name__icontains='test'}`   |
| `startswith`      | `LIKE 'val%'`             | `{name__startswith='A'}`     |
| `istartswith`     | `ILIKE 'val%'`            | `{name__istartswith='a'}`    |
| `endswith`        | `LIKE '%val'`             | `{name__endswith='z'}`       |
| `iendswith`       | `ILIKE '%val'`            | `{name__iendswith='Z'}`      |
| `range`           | `BETWEEN a AND b`         | `{age__range={18,30}}`       |
| `year`            | 按年筛选                  | `{pub_date__year=2023}`      |
| `month`           | 按月筛选                  | `{pub_date__month=1}`        |
| `day`             | 按日筛选                  | `{pub_date__day=15}`         |
| `regex`           | `~ 'pattern'`             | `{name__regex='^A'}`         |
| `iregex`          | `~* 'pattern'`            | `{name__iregex='^a'}`        |
| `null` / `isnull` | `IS NULL` / `IS NOT NULL` | `{email__null=true}`         |
| `has_key`         | `? key`                   | `{data__has_key='a'}`        |
| `has_keys`        | `?& [keys]`               | `{data__has_keys={'a','b'}}` |
| `has_any_keys`    | `?                        | [keys]`                      | `{data__has_any_keys={'a','b'}}` |
| `json_contains`   | `@> 'json'`               | `{data__a__contains='x'}`    |
| `contained_by`    | `<@ 'json'`               | `{data__contained_by={a=1}}` |
