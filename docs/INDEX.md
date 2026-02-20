# Xodel - PostgreSQL ORM for Lua (Django-inspired)

Xodel 是一个基于 Lua 的 PostgreSQL ORM 库，设计理念深受 Django ORM 启发。运行于 OpenResty (ngx_lua) 环境，使用 pgmoon 作为数据库驱动。

## 目录

- [INDEX.md](INDEX.md) — 总览与快速参考 (本文档)
- [model-definition.md](model-definition.md) — 模型定义与数据校验
- [query-basics.md](query-basics.md) — 基础 CRUD 查询
- [query-advanced.md](query-advanced.md) — 高级查询 (JOIN / 聚合 / CTE / 集合操作)
- [expressions.md](expressions.md) — F 表达式 / Q 对象 / 聚合函数

---

## 快速入门

```lua
local Model = require("xodel.model")
local Q = Model.Q
local F = Model.F
local Count = Model.Count
local Sum = Model.Sum
local Avg = Model.Avg
local Max = Model.Max
local Min = Model.Min
```

### 定义模型

```lua
local Blog = Model:create_model {
  table_name = 'blog',
  fields = {
    { "name",    maxlength = 20, unique = true },
    { "tagline", type = 'text',  default = 'default tagline' },
  }
}

local Entry = Model:create_model {
  table_name = 'entry',
  fields = {
    { 'blog_id',  reference = Blog, related_query_name = 'entry' },
    { "headline", maxlength = 255 },
    { "rating",   type = 'integer' },
  }
}
```

### CRUD 速览

```lua
-- 创建 (带校验)
local record = Blog:create { name = 'My Blog' }

-- 查询
local blogs = Blog:filter { name = 'My Blog' }             -- 返回数组
local blog  = Blog:get { name = 'My Blog' }                 -- 返回单条或 false

-- 更新
Blog:update { tagline = 'new tagline' }:where { name = 'My Blog' }:exec()

-- 删除
Blog:delete { name = 'My Blog' }:exec()

-- 插入 (不校验)
Blog:insert { name = 'Blog2', tagline = 'hi' }:exec()

-- 条件查询
Blog:select('name'):where { name__contains = 'Blog' }:order('-name'):limit(10):exec()
```

---

## 架构概览

```
Model (Xodel)
  ├── 模型定义: create_model, normalize, mix, merge_models
  ├── 数据校验: validate, validate_create, validate_update
  ├── 记录操作: create, save, save_create, save_update, load, create_record
  └── SQL 代理: 所有 Sql 方法可直接在 Model 上调用 (自动创建 Sql 实例)

Sql
  ├── 查询构建: select, where, order, group, limit, offset, distinct, having, from
  ├── CUD 操作: insert, update, delete, upsert, merge, updates, align, increase, decrease
  ├── 检索快捷: get, gets, filter, count, exists, flat, as_set, get_or_create
  ├── 关联查询: select_related, select_related_labels, where_recursive
  ├── 集合操作: union, union_all, except, except_all, intersect, intersect_all
  ├── CTE:      with, with_recursive, with_values
  ├── 执行:     exec, execr, statement, compact, raw, skip_validate
  └── 工具:     copy, clear, prepend, append, returning, as

表达式工具
  ├── F(column)        — 字段引用 (支持 +、-、*、/、%、^、|| 运算)
  ├── Q{cond}          — 复合条件 (支持 * AND、/ OR、- NOT)
  └── Count/Sum/Avg/Max/Min(column) — 聚合函数
```

---

## Model 代理机制

Model 实际是一个代理对象 (proxy)。调用 `Model:xxx()` 时：
- 如果 `xxx` 是 `Sql` 上的方法 → 自动创建 `Sql` 实例并转发调用
- 如果 `xxx` 是 `Model` 自身的方法 → 直接调用

因此可以直接在 Model 上链式调用 Sql 方法：

```lua
-- 以下两种写法等价：
Blog:select('name'):where{id=1}:exec()
Blog:create_sql():select('name'):where{id=1}:exec()
```

---

## 核心 API 速查表

### Model 定义与校验

| API | 说明 |
|-----|------|
| `Model:create_model(options)` | 创建模型类 |
| `Model(options)` | `create_model` 的简写（自带 BaseModel 混入） |
| `Model:mix(...)` | 混入多个模型配置创建新模型 |
| `Model:create(input)` | 创建记录（校验 + 插入 + 返回完整记录） |
| `Model:save(input, names?, key?)` | 智能保存（有主键则更新，否则创建） |
| `Model:save_create(input, names?, key?)` | 校验并创建 |
| `Model:save_update(input, names?, key?)` | 校验并更新 |
| `Model:validate(input, names?, key?)` | 智能校验 |
| `Model:validate_create(input, names?)` | 创建校验 |
| `Model:validate_update(input, names?)` | 更新校验 |
| `Model:load(data)` | 从数据库加载数据并转换 |
| `Model:create_record(data)` | 创建记录实例 |
| `Model:transaction(callback)` | 事务 |
| `Model:atomic(func)` | 将函数包装为原子操作 |
| `Model:to_json(names?)` | 将模型元数据导出为 JSON |
| `Model:create_sql()` | 创建 Sql 构建器实例 |
| `Model:create_sql_as(table_name, rows)` | 创建带 CTE 的 Sql 构建器 |

### 查询构建

| API | 说明 |
|-----|------|
| `Sql:select(...)` | 选择列 |
| `Sql:select_as(kwargs, as?)` | 选择列并重命名 |
| `Sql:select_literal(...)` | 选择字面量 |
| `Sql:select_literal_as(kwargs)` | 选择字面量并重命名 |
| `Sql:where(cond, op?, dval?)` | WHERE 条件 (AND 连接) |
| `Sql:where_or(cond, op?, dval?)` | WHERE 条件 (表内 OR，多次调用 AND) |
| `Sql:or_where(cond, op?, dval?)` | OR WHERE 条件 |
| `Sql:or_where_or(cond, op?, dval?)` | OR WHERE 条件 (表内 OR) |
| `Sql:where_in(cols, range)` | WHERE IN |
| `Sql:where_not_in(cols, range)` | WHERE NOT IN |
| `Sql:having(cond)` | HAVING |
| `Sql:order(...)` / `order_by(...)` | ORDER BY (`-`前缀为 DESC) |
| `Sql:group(...)` / `group_by(...)` | GROUP BY (自动 select) |
| `Sql:limit(n)` | LIMIT |
| `Sql:offset(n)` | OFFSET |
| `Sql:distinct(...)` | DISTINCT / DISTINCT ON |
| `Sql:distinct_on(...)` | DISTINCT ON (自动 prepend ORDER BY) |
| `Sql:nulls_first()` | 排序 NULLS FIRST |
| `Sql:nulls_last()` | 排序 NULLS LAST |
| `Sql:from(...)` | FROM |
| `Sql:as(alias)` | 表别名 |

### CUD 操作

| API | 说明 |
|-----|------|
| `Sql:insert(rows, columns?)` | 插入（单条/批量/子查询） |
| `Sql:update(row, columns?)` | 更新 |
| `Sql:delete(cond?, op?, dval?)` | 删除 |
| `Sql:upsert(rows, key?, columns?)` | ON CONFLICT DO UPDATE |
| `Sql:merge(rows, key?, columns?)` | CTE 方式 merge（更安全的 upsert） |
| `Sql:updates(rows, key?, columns?)` | 批量更新 |
| `Sql:align(rows, key?, columns?)` | 对齐（upsert + 删除多余行） |
| `Sql:increase(name, amount?)` | 字段自增 |
| `Sql:decrease(name, amount?)` | 字段自减 |
| `Sql:returning(...)` | RETURNING 子句 |
| `Sql:returning_literal(...)` | RETURNING 字面量 |

### 快捷检索

| API | 说明 |
|-----|------|
| `Sql:get(cond?, op?, dval?)` | 获取单条记录 (不存在返回 false) |
| `Sql:try_get(...)` | `get` 的别名 |
| `Sql:gets(keys, columns?)` | 批量按键获取 |
| `Sql:merge_gets(rows, key, columns?)` | 合并获取（带额外列） |
| `Sql:filter(kwargs)` | where + exec 快捷方式 |
| `Sql:count(cond?, op?, dval?)` | 计数 |
| `Sql:exists()` | 是否存在 |
| `Sql:flat(col?)` | 扁平化结果 |
| `Sql:as_set()` | 转为 Set |
| `Sql:get_or_create(params, defaults?, columns?)` | 获取或创建 |

### 集合操作

| API | 说明 |
|-----|------|
| `Sql:union(other)` | UNION |
| `Sql:union_all(other)` | UNION ALL |
| `Sql:except(other)` | EXCEPT |
| `Sql:except_all(other)` | EXCEPT ALL |
| `Sql:intersect(other)` | INTERSECT |
| `Sql:intersect_all(other)` | INTERSECT ALL |

### CTE

| API | 说明 |
|-----|------|
| `Sql:with(name, token)` | WITH CTE |
| `Sql:with_recursive(name, token)` | WITH RECURSIVE CTE |
| `Sql:with_values(name, rows)` | WITH VALUES CTE |

### 关联与递归

| API | 说明 |
|-----|------|
| `Sql:select_related(fk, names, ...)` | 关联查询外键字段 |
| `Sql:select_related_labels(names?)` | 关联查询外键 label |
| `Sql:where_recursive(name, value, names?)` | 递归查询（树结构） |
| `Sql:annotate(kwargs)` | 聚合注解 |

### 执行与配置

| API | 说明 |
|-----|------|
| `Sql:exec()` | 执行 SQL |
| `Sql:execr()` | 执行并返回原始结果 |
| `Sql:statement()` | 生成 SQL 字符串 |
| `Sql:compact()` | 紧凑模式（返回数组而非对象） |
| `Sql:raw(bool?)` | 原始模式（不调用 field:load） |
| `Sql:skip_validate(bool?)` | 跳过校验 |
| `Sql:return_all()` | 返回所有结果集 |
| `Sql:copy()` | 复制 Sql 构建器 |
| `Sql:clear()` | 清空构建器 |
| `Sql:prepend(...)` | 前置 SQL 语句 |
| `Sql:append(...)` | 追加 SQL 语句 |

### 表达式

| API | 说明 |
|-----|------|
| `F(column)` | 字段引用表达式 |
| `Q{cond}` | 逻辑条件构建器 |
| `Count(col)` | COUNT 聚合 |
| `Sum(col)` | SUM 聚合 |
| `Avg(col)` | AVG 聚合 |
| `Max(col)` | MAX 聚合 |
| `Min(col)` | MIN 聚合 |

---

## WHERE 条件 — 字段查找语法 (Field Lookups)

借鉴 Django 的双下划线语法，通过 `字段名__操作符` 指定查询条件：

| 查找 | 示例 | 生成 SQL |
|------|------|----------|
| (默认 eq) | `{name='Tom'}` | `name = 'Tom'` |
| `__lt` | `{age__lt=18}` | `age < 18` |
| `__lte` | `{age__lte=18}` | `age <= 18` |
| `__gt` | `{age__gt=18}` | `age > 18` |
| `__gte` | `{age__gte=18}` | `age >= 18` |
| `__ne` | `{age__ne=18}` | `age <> 18` |
| `__in` | `{id__in={1,2,3}}` | `id IN (1, 2, 3)` |
| `__notin` | `{id__notin={1,2}}` | `id NOT IN (1, 2)` |
| `__contains` | `{name__contains='om'}` | `name LIKE '%om%'` |
| `__icontains` | `{name__icontains='om'}` | `name ILIKE '%om%'` |
| `__startswith` | `{name__startswith='T'}` | `name LIKE 'T%'` |
| `__istartswith` | `{name__istartswith='t'}` | `name ILIKE 't%'` |
| `__endswith` | `{name__endswith='m'}` | `name LIKE '%m'` |
| `__iendswith` | `{name__iendswith='M'}` | `name ILIKE '%M'` |
| `__null` | `{age__null=true}` | `age IS NULL` |
| `__null` | `{age__null=false}` | `age IS NOT NULL` |
| `__range` | `{age__range={18,30}}` | `age BETWEEN 18 AND 30` |
| `__year` | `{pub_date__year=2023}` | `pub_date BETWEEN '2023-01-01' AND '2023-12-31'` |
| `__month` | `{pub_date__month=1}` | `EXTRACT('month' FROM pub_date) = '1'` |
| `__day` | `{pub_date__day=15}` | `EXTRACT('day' FROM pub_date) = '15'` |
| `__regex` | `{name__regex='^T'}` | `name ~ '^T'` |
| `__iregex` | `{name__iregex='^t'}` | `name ~* '^t'` |
| `__has_key` | `{data__has_key='a'}` | `(data) ? 'a'` |
| `__has_keys` | `{data__has_keys={'a','b'}}` | `(data) ?& ['a','b']` |
| `__has_any_keys` | `{data__has_any_keys={'a','b'}}` | `(data) ?| ['a','b']` |
| `__contains` (json) | `{data__a__contains='x'}` | `(data #> ['a']) @> '"x"'` |
| `__contained_by` | `{data__contained_by={a=1}}` | `(data) <@ '{"a":1}'` |

### 跨表查找（自动 JOIN）

```lua
-- 正向外键: Entry.blog_id -> Blog
Entry:where { blog_id__name = 'My Blog' }:exec()
-- 生成: INNER JOIN blog T0 ON T.blog_id = T0.id WHERE T0.name = 'My Blog'

-- 反向外键: Blog <- Entry.blog_id (related_query_name = 'entry')
Blog:where { entry__rating__gt = 3 }:exec()
-- 生成: INNER JOIN entry T0 ON T.id = T0.blog_id WHERE T0.rating > 3
```

---

## 字段类型

| 类型 | db_type | 说明 |
|------|---------|------|
| `string` | varchar | 字符串，需指定 maxlength |
| `text` | text | 长文本 |
| `integer` | integer | 整数 |
| `float` | float | 浮点数 |
| `boolean` | boolean | 布尔 |
| `date` | date | 日期 |
| `datetime` | timestamp | 日期时间 |
| `time` | time | 时间 |
| `json` | jsonb | JSON |
| `array` | jsonb | 数组 (存为 jsonb) |
| `foreignkey` | (同引用字段) | 外键 |
| `table` | jsonb | 结构化 JSON (基于子模型) |
| `email` | varchar | 邮箱 |
| `password` | varchar | 密码 |
| `uuid` | uuid | UUID |
| `year` | integer | 年份 |
| `month` | integer | 月份 |
| `year_month` | varchar | 年月 |
| `alioss` | varchar | 阿里云 OSS 文件 |
| `alioss_image` | varchar | 阿里云 OSS 图片 |
| `alioss_list` | jsonb | OSS 文件列表 |
| `alioss_image_list` | jsonb | OSS 图片列表 |
