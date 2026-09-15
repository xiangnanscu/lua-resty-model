# Model - PostgreSQL ORM for Lua (Django-inspired)

Model 是一个基于 Lua 的 PostgreSQL ORM 库，设计理念深受 Django ORM 启发。运行于 OpenResty (ngx_lua) 环境，使用 pgmoon 作为数据库驱动。

## 目录

- [orm-index.md](orm-index.md) — 总览与快速参考 (本文档)
- [orm-models-reference.md](orm-models-reference.md) — **示例模型 Schema (Reference)** — 其它文档共享同一套模型，先读这个
- [orm-model-definition.md](orm-model-definition.md) — 模型定义、字段类型、数据校验、记录操作、事务
- [orm-query-basics.md](orm-query-basics.md) — 基础 CRUD 查询、字段查找语法、执行控制
- [orm-query-advanced.md](orm-query-advanced.md) — 高级查询 (JOIN / 聚合 / CTE / 集合操作 / 行级锁)
- [orm-expressions.md](orm-expressions.md) — F 表达式 / Q 对象 / 聚合函数

---

## 数据库连接与超时

连接参数由 `lualib/model/query.lua` 的 `Query(options)` 组装，取值优先级是
**`options` 显式传值 > `.env` > 硬编码默认值**。

### 三个超时，各管各的

| `.env` 键              | `options` 键        | 默认值  | 谁来中止           | 管什么                                 |
| ---------------------- | ------------------- | ------- | ------------------ | -------------------------------------- |
| `PG_CONNECT_TIMEOUT`   | `CONNECT_TIMEOUT`   | `2000`  | 客户端             | TCP 连接 + startup/auth 握手           |
| `PG_QUERY_TIMEOUT`     | `QUERY_TIMEOUT`     | `10000` | 客户端（不发 cancel）| 单条 SQL 等回包                       |
| `PG_STATEMENT_TIMEOUT` | `STATEMENT_TIMEOUT` | 不下发  | **服务端（真 cancel）** | 单条 SQL 在 PG 上的执行时间       |

推荐配比：**`STATEMENT_TIMEOUT` < `QUERY_TIMEOUT`**（如 10000 / 12000）。
服务端先动手把查询 cancel 掉，客户端的读超时只做「PG 完全没响应」的兜底；
反过来配的话每次都是客户端先撒手，查询在服务端继续烧。

`STATEMENT_TIMEOUT` 只在**新建连接**上下发一次（会话级参数，池里复用的 socket 依然有效），
不配则一条 `SET` 都不发，省掉那次往返。也可以不走客户端、直接挂在库或角色上：

```sql
ALTER DATABASE mydb SET statement_timeout = '10s';
```

### `receive_message: failed to get type: timeout` 是什么

```
ERROR: lualib/model/query.lua:xxx: receive_message: failed to get type: timeout
```

**这不是 pgmoon 的 bug，也不是 PostgreSQL 出了问题**，是 pgmoon 等 PG 回包时**客户端读超时**，
即撞上了 `QUERY_TIMEOUT`。

历史坑：老版本只有 `PG_CONNECT_TIMEOUT` 一个旋钮，它经 `conn:settimeout()` 一次性设成
connect / send / **receive** 三个超时（cosocket `settimeout` 的语义，名字里的 "connect" 有误导性），
所以那个值实际上就是单条 SQL 的时限。web 端为了快速失败常把它配成 1 秒级，
于是所有报表查询和 CLI 脚本（迁移、回填、盘点）全被按握手的尺度砍掉。

**兼容**：没配 `PG_QUERY_TIMEOUT` 时仍回落到 `PG_CONNECT_TIMEOUT`（行为与升级前一致），
但会打一条 WARN 提醒去拆开配。

### 怎么确认是客户端超时而不是数据库的问题

客户端超时**不会给 PG 发 cancel**，服务端那条查询还在继续跑。报错的同时开另一个 psql：

```sql
select now() - query_start, state, left(query, 80)
from pg_stat_activity
where datname = current_database() and state <> 'idle';
```

还能看到它 `active`，就说明是客户端超时；查询已经不在了才需要怀疑连接被服务端切断
（或者是 `statement_timeout` 生效了 —— 那种情况报的是 PG 的
`canceling statement due to statement timeout`，不是这条）。

### 脚本怎么写

脚本不要继承 web 那套量级，三个都显式传，把 `.env` 顶掉（`options` 优先于 `.env`）：

```lua
local query = Query {
  DATABASE = ...,
  CONNECT_TIMEOUT = 5000,
  QUERY_TIMEOUT = 600000, -- 10 分钟
  STATEMENT_TIMEOUT = 0,  -- 解开服务端护栏，0 = 不限
}
```

只放宽客户端是不够的：库或角色上挂着 `statement_timeout` 的话，SQL 照样被 PG 自己 cancel。

调大 `.env` 里的 `PG_QUERY_TIMEOUT` 来迁就脚本是错的解法 —— 那会连带放宽 web 请求的闸门。

### 其它连接项

| `.env` 键                | `options` 键          | 默认值  | 说明                                            |
| ------------------------ | --------------------- | ------- | ----------------------------------------------- |
| `PGHOST` / `PGPORT`      | `HOST` / `PORT`       | `127.0.0.1` / `5432` |                                    |
| `PGDATABASE` / `PGUSER` / `PGPASSWORD` | `DATABASE` / `USER` / `PASSWORD` | `postgres` |                 |
| `PG_MAX_IDLE_TIMEOUT`    | `MAX_IDLE_TIMEOUT`    | `10000` | 连接归还池后的最大空闲时间（毫秒）              |
| `PG_POOL_SIZE`           | `POOL_SIZE`           | `100`   | 连接池大小                                      |
| `PG_POOL_NAME`           | `POOL_NAME`           | `host:port:database:user` | 同名共享同一个池与同一份 Query 实例 |
| `PG_SSL` / `PG_SSL_VERIFY` / `PG_SSL_REQUIRED` | `SSL` / `SSL_VERIFY` / `SSL_REQUIRED` | 关 | 布尔项走 `coalesce`，`false` 能覆盖 env |

`Query(options)` 按 `pool_name` 缓存实例：同一 `host:port:database:user` 反复调用拿到的是
**同一个 Query**，三个超时以首次构造时为准。这是有意为之 —— 事务连接
（`transaction`）要靠共享实例才能让跨 model 的写入进同一个事务。
换句话说，想给某个脚本单独放宽超时，它得是这个进程里第一个构造该 pool 的人，
否则要么换 `POOL_NAME`，要么老老实实走同一份配置。

---

## 快速入门

```lua
local Model = require("model")
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
Model (Model)
  ├── 模型定义: create_model, normalize, mix, merge_models
  ├── 数据校验: validate, validate_create, validate_update
  ├── 记录操作: create, save, save_create, save_update, load, create_record
  └── SQL 代理: 所有 Sql 方法可直接在 Model 上调用 (自动创建 Sql 实例)

Sql
  ├── 查询构建: select, where, exclude, order, reverse, group, limit, offset, distinct, having, from
  ├── 字段选择: values, values_list, only, defer
  ├── CUD 操作: insert, update, delete, upsert, merge, updates, align, increase, decrease, update_or_create
  ├── 检索快捷: get, gets, filter, count, exists, contains, flat, as_set, get_or_create, in_bulk
  ├── 单行取值: first, last, latest, earliest
  ├── 聚合:     annotate, alias, aggregate
  ├── 日期分组: dates, datetimes
  ├── 关联查询: select_related, select_related_labels, where_recursive
  ├── 集合操作: union, union_all, except, except_all, intersect, intersect_all
  ├── CTE:      with, with_recursive, with_values
  ├── 行级锁:   select_for_update (需在事务内，见 orm-query-advanced.md)
  ├── 调试:     explain
  ├── 空集:     none, all
  ├── 执行:     exec, execr, statement, compact, raw, skip_validate
  └── 工具:     copy, clear, prepend, append, returning, as

表达式工具
  ├── F(column)                          — 字段引用 (支持 +、-、*、/、%、^、|| 运算)
  ├── Q{cond}                            — 复合条件 (支持 * AND、/ OR、- NOT)
  └── Count/Sum/Avg/Max/Min/StdDev/Variance(column) — 聚合函数
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

| API                                            | 说明                                         |
| ---------------------------------------------- | -------------------------------------------- |
| `Model:create_model(options)`                  | 创建模型类                                   |
| `Model(options)`                               | `create_model` 的简写（自带 BaseModel 混入） |
| `Model:mix(...)`                               | 混入多个模型配置创建新模型                   |
| `Model:create(input)`                          | 创建记录（校验 + 插入 + 返回完整记录）       |
| `Model:save(input, names?, key?)`              | 智能保存（有主键则更新，否则创建）           |
| `Model:save_create(input, names?, key?)`       | 校验并创建                                   |
| `Model:save_update(input, names?, key?)`       | 校验并更新                                   |
| `Model:validate(input, names?, key?)`          | 智能校验                                     |
| `Model:validate_create(input, names?)`         | 创建校验                                     |
| `Model:validate_update(input, names?)`         | 更新校验                                     |
| `Model:validate_cascade_update(input, names?)` | 级联更新校验                                 |
| `Model:load(data)`                             | 从数据库加载数据并转换                       |
| `Model:create_record(data)`                    | 创建记录实例                                 |
| `Model:transaction(callback)`                  | 事务                                         |
| `Model:atomic(func)`                           | 将函数包装为原子操作                         |
| `Model:to_json(names?)`                        | 将模型元数据导出为 JSON                      |
| `Model:save_cascade_update(input, names?, key?)` | 级联更新（同时同步 table 字段子表）        |
| `Model:create_sql()`                           | 创建 Sql 构建器实例                          |
| `Model:create_sql_as(table_name, rows)`        | 创建带 CTE 的 Sql 构建器                     |
| `Model:make_field_from_json(options)`          | 根据描述动态实例化字段                       |
| `Model:check_unique_key(key)`                  | 校验字段是否为主键或唯一键                   |
| `Model:is_model_class(model)`                  | 是否为模型类                                 |
| `Model:is_instance(row)`                       | 是否为 Sql builder 实例                      |
| `Model:merge_models(opts[])` / `merge_model(a, b)` | 合并模型选项 (供 mixins/extends 使用)    |

### 查询构建

| API                                 | 说明                                |
| ----------------------------------- | ----------------------------------- |
| `Sql:select(...)`                   | 选择列                              |
| `Sql:select_as(kwargs, as?)`        | 选择列并重命名                      |
| `Sql:select_literal(...)`           | 选择字面量                          |
| `Sql:select_literal_as(kwargs)`     | 选择字面量并重命名                  |
| `Sql:where(cond, op?, dval?)`       | WHERE 条件 (AND 连接)               |
| `Sql:where_or(cond, op?, dval?)`    | WHERE 条件 (表内 OR，多次调用 AND)  |
| `Sql:or_where(cond, op?, dval?)`    | OR WHERE 条件                       |
| `Sql:or_where_or(cond, op?, dval?)` | OR WHERE 条件 (表内 OR)             |
| `Sql:where_in(cols, range)`         | WHERE IN                            |
| `Sql:where_not_in(cols, range)`     | WHERE NOT IN                        |
| `Sql:having(cond)`                  | HAVING                              |
| `Sql:order(...)` / `order_by(...)`  | ORDER BY (`-`前缀为 DESC)           |
| `Sql:group(...)` / `group_by(...)`  | GROUP BY (自动 select)              |
| `Sql:limit(n)`                      | LIMIT                               |
| `Sql:offset(n)`                     | OFFSET                              |
| `Sql:distinct(...)`                 | DISTINCT / DISTINCT ON              |
| `Sql:distinct_on(...)`              | DISTINCT ON (自动 prepend ORDER BY) |
| `Sql:nulls_first()`                 | 排序 NULLS FIRST                    |
| `Sql:nulls_last()`                  | 排序 NULLS LAST                     |
| `Sql:from(...)`                     | FROM                                |
| `Sql:as(alias)`                     | 表别名                              |
| `Sql:exclude(cond, op?, dval?)`     | `WHERE NOT (...)`                   |
| `Sql:reverse()`                     | 翻转当前 ORDER BY 方向              |
| `Sql:only(...)`                     | 覆盖式选择列                        |
| `Sql:defer(...)`                    | 排除指定列                          |
| `Sql:values(...)`                   | 返回字典数组（不经 model:load）     |
| `Sql:values_list(fields, opts?)`    | 返回元组数组（`flat=true` 自动展平）|
| `Sql:join_type(jtype)`              | 设置后续自动 JOIN 类型              |
| `Sql:select_for_update(opts?)`      | 行级写锁 `FOR UPDATE` (需事务)      |
| `Sql:using(...)`                    | DELETE 的 USING 子句                |
| `Sql:get_table()`                   | 获取 `表名 + 别名` 字符串           |
| `Sql:none()`                        | 恒空查询 (`WHERE FALSE`)            |
| `Sql:all()`                         | 返回 builder 副本（等价 `:copy()`，对齐 Django） |

### CUD 操作

| API                                 | 说明                              |
| ----------------------------------- | --------------------------------- |
| `Sql:insert(rows, columns?)`        | 插入（单条/批量/子查询）          |
| `Sql:update(row, columns?)`         | 更新                              |
| `Sql:delete(cond?, op?, dval?)`     | 删除                              |
| `Sql:upsert(rows, key?, columns?)`  | ON CONFLICT DO UPDATE             |
| `Sql:merge(rows, key?, columns?)`   | CTE 方式 merge（更安全的 upsert） |
| `Sql:updates(rows, key?, columns?)` | 批量更新                          |
| `Sql:align(rows, key?, columns?)`   | 对齐（upsert + 删除多余行）       |
| `Sql:increase(name, amount?)`       | 字段自增                          |
| `Sql:decrease(name, amount?)`       | 字段自减                          |
| `Sql:returning(...)`                | RETURNING 子句                    |
| `Sql:returning_literal(...)`        | RETURNING 字面量                  |

### 快捷检索

| API                                              | 说明                            |
| ------------------------------------------------ | ------------------------------- |
| `Sql:get(cond?, op?, dval?)`                     | 获取单条记录 (不存在返回 false) |
| `Sql:try_get(...)`                               | `get` 的别名                    |
| `Sql:gets(keys, columns?)`                       | 批量按键获取                    |
| `Sql:merge_gets(rows, key, columns?)`            | 合并获取（带额外列）            |
| `Sql:filter(kwargs)`                             | where + exec 快捷方式           |
| `Sql:count(cond?, op?, dval?)`                   | 计数                            |
| `Sql:exists()`                                   | 是否存在                        |
| `Sql:flat(col?)`                                 | 扁平化结果                      |
| `Sql:as_set()`                                   | 转为 Set                        |
| `Sql:get_or_create(params, defaults?, columns?)` | 获取或创建                      |
| `Sql:update_or_create(params, defaults?, ...)`   | 更新或创建（命中即 UPDATE）     |
| `Sql:first()` / `Sql:last()`                     | 单条记录（无 order 时按主键）   |
| `Sql:latest(...)` / `Sql:earliest(...)`          | 按指定字段取最新/最早一条       |
| `Sql:contains(obj)`                              | 集合是否包含指定对象            |
| `Sql:in_bulk(ids?, field_name?)`                 | 按主键/指定列取字典             |
| `Sql:explain(opts?)`                             | 返回 PostgreSQL 查询计划         |

### 集合操作

| API                        | 说明          |
| -------------------------- | ------------- |
| `Sql:union(other)`         | UNION         |
| `Sql:union_all(other)`     | UNION ALL     |
| `Sql:except(other)`        | EXCEPT        |
| `Sql:except_all(other)`    | EXCEPT ALL    |
| `Sql:intersect(other)`     | INTERSECT     |
| `Sql:intersect_all(other)` | INTERSECT ALL |

### CTE

| API                               | 说明               |
| --------------------------------- | ------------------ |
| `Sql:with(name, token)`           | WITH CTE           |
| `Sql:with_recursive(name, token)` | WITH RECURSIVE CTE |
| `Sql:with_values(name, rows)`     | WITH VALUES CTE    |

### 关联与递归

| API                                        | 说明               |
| ------------------------------------------ | ------------------ |
| `Sql:select_related(fk, names, ...)`       | 关联查询外键字段   |
| `Sql:select_related_labels(names?)`        | 关联查询外键 label |
| `Sql:where_recursive(name, value, names?)` | 递归查询（树结构） |
| `Sql:annotate(kwargs)`                     | 聚合注解（加入 SELECT）|
| `Sql:alias(kwargs)`                        | 注解但不加入 SELECT |
| `Sql:aggregate(kwargs)`                    | 终端聚合，返回字典 |
| `Sql:dates(field, kind, order?)`           | 去重日期值数组（DATE_TRUNC）|
| `Sql:datetimes(field, kind, order?)`       | 去重日期时间值数组 |

### 执行与配置

| API                        | 说明                          |
| -------------------------- | ----------------------------- |
| `Sql:exec()`               | 执行 SQL                      |
| `Sql:execr()`              | 执行并返回原始结果            |
| `Sql:statement()`          | 生成 SQL 字符串               |
| `Sql:compact()`            | 紧凑模式（返回数组而非对象）  |
| `Sql:raw(bool?)`           | 原始模式（不调用 field:load） |
| `Sql:skip_validate(bool?)` | 跳过校验                      |
| `Sql:return_all()`         | 返回所有结果集                |
| `Sql:copy()`               | 复制 Sql 构建器               |
| `Sql:clear()`              | 清空构建器                    |
| `Sql:prepend(...)`         | 前置 SQL 语句                 |
| `Sql:append(...)`          | 追加 SQL 语句                 |
| `Sql:exec_statement(stmt)` | 直接执行原始 SQL 字符串       |
| `Sql:commit(bool?)`        | 是否提交（默认 true）         |
| `Sql:meta_query(data)`     | 声明式查询                    |

### 表达式

| API          | 说明           |
| ------------ | -------------- |
| `F(column)`  | 字段引用表达式 |
| `Q{cond}`    | 逻辑条件构建器 |
| `Count(col)`    | COUNT 聚合          |
| `Sum(col)`      | SUM 聚合            |
| `Avg(col)`      | AVG 聚合            |
| `Max(col)`      | MAX 聚合            |
| `Min(col)`      | MIN 聚合            |
| `StdDev(col)`   | STDDEV_SAMP（样本） |
| `Variance(col)` | VAR_SAMP（样本）    |
| `Model.NULL`    | SQL `NULL` 占位     |
| `Model.DEFAULT` | SQL `DEFAULT` 占位  |
| `Model.token(s)`| 原始 SQL token 工厂 |
| `Model.as_token(v)` / `Model.as_literal(v)` | Lua 值转 SQL token / 字面量 |

---

## WHERE 条件 — 字段查找语法 (Field Lookups)

借鉴 Django 的双下划线语法，通过 `字段名__操作符` 指定查询条件：

| 查找                | 示例                             | 生成 SQL                                         |
| ------------------- | -------------------------------- | ------------------------------------------------ |
| (默认 eq)           | `{name='Tom'}`                   | `name = 'Tom'`                                   |
| `__lt`              | `{age__lt=18}`                   | `age < 18`                                       |
| `__lte`             | `{age__lte=18}`                  | `age <= 18`                                      |
| `__gt`              | `{age__gt=18}`                   | `age > 18`                                       |
| `__gte`             | `{age__gte=18}`                  | `age >= 18`                                      |
| `__ne`              | `{age__ne=18}`                   | `age <> 18`                                      |
| `__in`              | `{id__in={1,2,3}}`               | `id IN (1, 2, 3)`                                |
| `__notin`           | `{id__notin={1,2}}`              | `id NOT IN (1, 2)`                               |
| `__contains`        | `{name__contains='om'}`          | `name LIKE '%om%'`                               |
| `__icontains`       | `{name__icontains='om'}`         | `name ILIKE '%om%'`                              |
| `__startswith`      | `{name__startswith='T'}`         | `name LIKE 'T%'`                                 |
| `__istartswith`     | `{name__istartswith='t'}`        | `name ILIKE 't%'`                                |
| `__endswith`        | `{name__endswith='m'}`           | `name LIKE '%m'`                                 |
| `__iendswith`       | `{name__iendswith='M'}`          | `name ILIKE '%M'`                                |
| `__null`            | `{age__null=true}`               | `age IS NULL`                                    |
| `__null`            | `{age__null=false}`              | `age IS NOT NULL`                                |
| `__range`           | `{age__range={18,30}}`           | `age BETWEEN 18 AND 30`                          |
| `__year`            | `{pub_date__year=2023}`          | `pub_date >= '2023-01-01' AND < '2024-01-01'` |
| `__month`           | `{pub_date__month=1}`            | `EXTRACT('month' FROM pub_date) = '1'`           |
| `__day`             | `{pub_date__day=15}`             | `EXTRACT('day' FROM pub_date) = '15'`            |
| `__regex`           | `{name__regex='^T'}`             | `name ~ '^T'`                                    |
| `__iregex`          | `{name__iregex='^t'}`            | `name ~* '^t'`                                   |
| `__has_key`         | `{data__has_key='a'}`            | `(data) ? 'a'`                                   |
| `__has_keys`        | `{data__has_keys={'a','b'}}`     | `(data) ?& ['a','b']`                            |
| `__has_any_keys`    | `{data__has_any_keys={'a','b'}}` | `(data) ?\| ['a','b']`                           |
| `__contains` (json) | `{data__a__contains='x'}`        | `(data #> ['a']) @> '"x"'`                       |
| `__contained_by`    | `{data__contained_by={a=1}}`     | `(data) <@ '{"a":1}'`                            |

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

| 类型                | db_type      | 说明                     |
| ------------------- | ------------ | ------------------------ |
| `string`            | varchar      | 字符串，需指定 maxlength |
| `text`              | text         | 长文本                   |
| `integer`           | integer      | 整数                     |
| `float`             | float        | 浮点数                   |
| `boolean`           | boolean      | 布尔                     |
| `date`              | date         | 日期                     |
| `datetime`          | timestamp    | 日期时间                 |
| `time`              | time         | 时间                     |
| `json`              | jsonb        | JSON                     |
| `array`             | jsonb        | 数组 (存为 jsonb)        |
| `foreignkey`        | (同引用字段) | 外键                     |
| `table`             | jsonb        | 结构化 JSON (基于子模型) |
| `email`             | varchar      | 邮箱                     |
| `password`          | varchar      | 密码                     |
| `uuid`              | uuid         | UUID                     |
| `year`              | integer      | 年份                     |
| `month`             | integer      | 月份                     |
| `year_month`        | varchar      | 年月                     |
| `alioss`            | varchar      | 阿里云 OSS 文件          |
| `alioss_image`      | varchar      | 阿里云 OSS 图片          |
| `alioss_list`       | jsonb        | OSS 文件列表             |
| `alioss_image_list` | jsonb        | OSS 图片列表             |
