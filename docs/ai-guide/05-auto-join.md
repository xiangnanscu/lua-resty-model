# 05 — 双下划线自动 JOIN

> `__` 语法是本 ORM 最核心的特性之一。通过在字段名中使用 `__` 分隔，可以自动跨越外键关系进行 JOIN，无需手动编写 JOIN 子句。本文系统讲解其在各 API 中的用法。

## 核心机制：`_parse_column(key)` 解析规则

当 ORM 遇到包含 `__` 的字段名时，内部 `_parse_column` 函数按以下优先级逐段解析：

```
字段名: blog_id__name__contains
         ───┬──  ──┬─  ───┬────
            │      │      └── 3. 操作符后缀 (op)
            │      └── 2. 引用表的字段 (触发JOIN)
            └── 1. 当前表的外键字段
```

**解析优先级**（每个 `__` 分割的 token 按此顺序判断）：

1. **当前 model 的字段** → 如果是外键，记录引用关系
2. **annotate 注册名** → 直接使用注解表达式
3. **JSON 字段属性** → 当前字段是 `table` 类型时，后续 token 作为 JSON 路径
4. **反向外键名** → `related_query_name` 匹配，触发反向 JOIN
5. **操作符后缀** → `gt`、`contains`、`in` 等表达式操作符

---

## 适用的 API

`__` 跨表语法可用于以下所有 API：

| API           | 示例                                   | 说明                     |
| ------------- | -------------------------------------- | ------------------------ |
| `select()`    | `select('blog_id__name')`              | 选择关联表的字段         |
| `select_as()` | `select_as{blog_id__name='blog_name'}` | 选择并重命名             |
| `where()`     | `where{blog_id__name='First Blog'}`    | 按关联表字段过滤         |
| `order()`     | `order('blog_id__name')`               | 按关联表字段排序         |
| `group_by()`  | `group_by('blog_id__name')`            | 按关联表字段分组         |
| `annotate()`  | `annotate{cnt=Count('entry')}`         | 反向外键聚合             |
| `flat()`      | `flat('blog_id__name')`                | 提取关联表字段的扁平数组 |
| `F()`         | `F('blog_id__name')`                   | F 表达式中引用关联字段   |

---

## 正向查询：外键 → 引用表

### 基本语法

```lua
-- Entry.blog_id → Blog
-- 格式: 外键字段名__引用表字段名

-- 在 select 中
Entry:select('headline', 'blog_id__name'):exec()
-- SELECT T."headline", T1."name" AS "blog_id__name"
-- FROM entry T INNER JOIN blog T1 ON (T."blog_id" = T1."id")

-- 在 where 中
Entry:where{blog_id__name='First Blog'}:exec()
-- SELECT * FROM entry T
--   INNER JOIN blog T1 ON (T."blog_id" = T1."id")
-- WHERE T1."name" = 'First Blog'

-- 在 order 中
Entry:order('blog_id__name'):exec()
-- SELECT * FROM entry T
--   INNER JOIN blog T1 ON (T."blog_id" = T1."id")
-- ORDER BY T1."name" ASC

-- 在 group_by 中
Entry:annotate{cnt=Count('id')}:group_by('blog_id__name'):exec()
-- SELECT T1."name" AS "blog_id__name", COUNT(T."id") AS cnt
-- FROM entry T INNER JOIN blog T1 ON (T."blog_id" = T1."id")
-- GROUP BY T1."name"
```

### 冗余后缀自动跳过

当跨表路径指向的正好是外键引用列本身时，ORM 会智能跳过 JOIN:

```lua
-- blog_id 引用 Blog.id，所以 blog_id__id 等价于 blog_id
Entry:where{blog_id__id=1}:exec()
-- WHERE T."blog_id" = 1  (不会JOIN，因为 id 就是外键引用列)
```

### 同表多外键

一个 Model 可以有多个外键指向同一个表，ORM 会为每个外键关系创建独立的 JOIN:

```lua
-- Entry 有 blog_id 和 reposted_blog_id 两个外键都指向 Blog
Entry:where{blog_id__name='Blog A', reposted_blog_id__name='Blog B'}:exec()
-- SELECT * FROM entry T
--   INNER JOIN blog T1 ON (T."blog_id" = T1."id")
--   INNER JOIN blog T2 ON (T."reposted_blog_id" = T2."id")
-- WHERE T1."name" = 'Blog A' AND T2."name" = 'Blog B'
-- 注意: T1 和 T2 是同一个表的不同别名
```

---

## 多级跨表查询

支持链式穿透多个外键关系：

```lua
-- ViewLog.entry_id → Entry.blog_id → Blog
ViewLog:where{entry_id__blog_id__name='First Blog'}:exec()
-- SELECT * FROM view_log T
--   INNER JOIN entry T1 ON (T."entry_id" = T1."id")
--   INNER JOIN blog T2 ON (T1."blog_id" = T2."id")
-- WHERE T2."name" = 'First Blog'

-- 多级 select
ViewLog:select('entry_id__blog_id__name', 'entry_id__headline'):exec()
-- SELECT T2."name" AS "entry_id__blog_id__name",
--        T1."headline" AS "entry_id__headline"
-- FROM view_log T
--   INNER JOIN entry T1 ON (T."entry_id" = T1."id")
--   INNER JOIN blog T2 ON (T1."blog_id" = T2."id")

-- 多级 + 操作符后缀
ViewLog:where{entry_id__blog_id__name__contains='Blog'}:exec()
-- WHERE T2."name" LIKE '%Blog%' ESCAPE '\'
```

---

## 反向查询：引用表 → 子表

通过 `related_query_name` 属性，可以从父表查询子表:

```lua
-- Entry 的 blog_id 外键定义了 related_query_name = 'entry'
-- 因此可以在 Blog 上用 'entry' 进行反向查询

-- 反向 where
Blog:where{entry__rating=4}:exec()
-- SELECT * FROM blog T
--   INNER JOIN entry T1 ON (T."id" = T1."blog_id")
-- WHERE T1."rating" = 4

-- 反向 where + 操作符
Blog:where{entry__rating__gt=3}:exec()
-- WHERE T1."rating" > 3

Blog:where{entry__headline__contains='First'}:exec()
-- WHERE T1."headline" LIKE '%First%' ESCAPE '\'

-- 反向 annotate (聚合)
Blog:annotate{entry_count=Count('entry')}:group_by('name'):exec()
-- SELECT T."name", COUNT(T1."id") AS entry_count
-- FROM blog T
--   LEFT JOIN entry T1 ON (T."id" = T1."blog_id")
-- GROUP BY T."name"
-- 注意: 反向聚合自动使用 LEFT JOIN（避免无子表记录的父表被过滤）

-- 反向多级
Blog:where{entry__view_log__id__gt=0}:exec()
-- Blog ← Entry ← ViewLog 的多级反向穿透
```

### related_query_name 推断规则

```lua
-- 如果显式指定
{ "blog_id", reference = Blog, related_query_name = 'entry' }

-- 如果未指定，默认使用外键字段名去掉 _id 后缀
-- 例如 blog_id → related_query_name = 'blog'
-- 但如果有冲突（如多个外键指向同一表），需要显式指定
```

---

## 跨表查询 + 操作符后缀组合

`__` 同时用于跨表和操作符后缀，ORM 通过优先级正确区分：

```lua
-- 跨表 + gt 操作符
Entry:where{blog_id__name__startswith='First'}:exec()
-- WHERE T1."name" LIKE 'First%' ESCAPE '\'

-- 反向跨表 + in 操作符
Blog:where{entry__rating__in={4,5}}:exec()
-- WHERE T1."rating" IN (4, 5)

-- 反向跨表 + range 操作符
Blog:where{entry__rating__range={3,5}}:exec()
-- WHERE T1."rating" BETWEEN 3 AND 5

-- 多级跨表 + 操作符
ViewLog:where{entry_id__blog_id__name__icontains='blog'}:exec()
-- WHERE T2."name" ILIKE '%blog%' ESCAPE '\'
```

---

## JSON 字段路径查询

当字段类型为 `table`（结构化 JSON），`__` 分隔表示 JSON 路径而非外键：

```lua
-- Author.resume 是 table 类型
-- resume__company 表示 resume -> 'company'

Author:where{resume__company='CompanyA'}:exec()
-- WHERE (T."resume" #> ['company']) = '"CompanyA"'

-- 嵌套 JSON 路径
Author:where{resume__address__city='Beijing'}:exec()
-- WHERE (T."resume" #> ['address','city']) = '"Beijing"'

-- JSON 操作符
Author:where{resume__company__contains='Corp'}:exec()
-- WHERE (T."resume" -> 'company') @> '"Corp"'

Author:where{resume__null=true}:exec()
-- WHERE T."resume" IS NULL
```

### JSON 专用操作符

| 操作符                  | SQL   | 示例                             |
| ----------------------- | ----- | -------------------------------- |
| `contains` (JSON上下文) | `@>`  | `{data__a__contains='x'}`        |
| `has_key`               | `?`   | `{data__has_key='a'}`            |
| `has_keys`              | `?&`  | `{data__has_keys={'a','b'}}`     |
| `has_any_keys`          | `?\|` | `{data__has_any_keys={'a','b'}}` |
| `contained_by`          | `<@`  | `{data__contained_by={a=1}}`     |

---

## JOIN 类型控制

### 默认 JOIN 类型

| 场景                    | 默认 JOIN 类型 |
| ----------------------- | -------------- |
| `where` 中的正向跨表    | `INNER JOIN`   |
| `where` 中的反向跨表    | `INNER JOIN`   |
| `annotate` 中的反向聚合 | `LEFT JOIN`    |
| `select_related_labels` | `LEFT JOIN`    |

### Sql:join_type(jtype) — 覆盖默认类型

```lua
---@param jtype string   -- "INNER" | "LEFT" | "RIGHT" | "FULL"
---@return self
```

```lua
-- 改为 LEFT JOIN（避免空外键行被过滤）
Entry:join_type('LEFT'):where{blog_id__name='First Blog'}:exec()
-- FROM entry T LEFT JOIN blog T1 ON (T."blog_id" = T1."id")
-- WHERE T1."name" = 'First Blog'
```

### JOIN 去重

同一个跨表路径多次出现时，ORM 只生成一次 JOIN：

```lua
Entry:select('blog_id__name'):where{blog_id__tagline__contains='test'}:exec()
-- 只生成 1 次 INNER JOIN blog T1 ON (...)
-- 因为 blog_id 路径相同，共享 T1 别名
```

---

## Sql:select_related(fk_name, select_names, ...) — 外键展开

```lua
---@param fk_name string|ForeignkeyField  -- 外键字段名
---@param select_names string[]|string|'*' -- 要选择的引用表字段
---@param more_name? string
---@param ... string
---@return self
```

将外键 ID 替换为关联模型的完整 Record 实例（`exec()` 时外键字段值变为嵌套对象）:

### 调用形式

```lua
-- 形式1: 仅标记为 related（不选择额外字段）
Entry:select_related('blog_id'):exec()
-- exec 后 entry.blog_id 是 Blog Record 实例

-- 形式2: 选择引用表的特定字段
Entry:select_related('blog_id', 'name'):exec()
-- SELECT T."blog_id", T1."name" AS "blog_id__name"
-- exec 后 entry.blog_id = { id=1, name='First Blog' }

-- 形式3: 选择多个字段（变参）
Entry:select_related('blog_id', 'name', 'tagline'):exec()
-- SELECT T."blog_id", T1."name" AS "blog_id__name", T1."tagline" AS "blog_id__tagline"

-- 形式4: 字段名数组
Entry:select_related('blog_id', {'name', 'tagline'}):exec()

-- 形式5: 通配符 '*' 选择全部字段
Entry:select_related('blog_id', '*'):exec()
-- 选择 Blog 的所有字段

-- 形式6: 嵌套外键展开
Entry:select_related('blog_id', 'author_id__name'):exec()
-- 如果 Blog 有 author_id 外键，可以嵌套展开
```

### 与普通 select 跨表的区别

```lua
-- select 跨表: 返回扁平结构
Entry:select('headline', 'blog_id__name'):exec()
-- { headline='First Entry', blog_id__name='First Blog' }  -- 扁平

-- select_related: 返回嵌套 Record
Entry:select_related('blog_id', 'name'):select('headline'):exec()
-- { headline='First Entry', blog_id={ id=1, name='First Blog' } }  -- 嵌套
```

---

## Sql:select_related_labels(names?) — 自动标签展开

```lua
---@param names? string[]   -- 要处理的字段名列表，默认全部字段
---@return self
```

自动对所有外键字段进行 `select_related`，选择其 `reference_label_column`：

```lua
-- 自动为所有外键选择标签列
Entry:select_related_labels():exec()
-- 对每个外键字段（如 blog_id），自动 LEFT JOIN 并选择
-- Blog 的 label 列（通常是 name）

-- 指定字段
Entry:select_related_labels({'blog_id'}):exec()
```

> 注意: `select_related_labels` 内部自动调用 `join_type("LEFT")`。

---

## 综合示例

```lua
-- 1. 跨表筛选 + 选择 + 排序
Entry:select('headline', 'blog_id__name', 'rating')
  :where{blog_id__name__startswith='First'}
  :order('-blog_id__name', '-rating')
  :exec()

-- 2. 反向聚合 + 筛选
Blog:annotate{
  entry_count = Count('entry'),
  avg_rating = Avg('entry__rating'),
}:group_by('name')
  :having{entry_count__gt=0}
  :order('-entry_count')
  :exec()

-- 3. 多级穿透
ViewLog:select('entry_id__headline', 'entry_id__blog_id__name')
  :where{entry_id__blog_id__name__contains='Blog'}
  :order('-entry_id__blog_id__name')
  :limit(10)
  :exec()

-- 4. select_related 嵌套对象
Entry:select('headline')
  :select_related('blog_id', 'name', 'tagline')
  :where{rating__gte=4}
  :exec()
-- 返回: { headline='...', blog_id={ id=1, name='...', tagline='...' } }

-- 5. flat 跨表提取
local blog_names = Entry:flat('blog_id__name')
-- blog_names = {'First Blog', 'Second Blog', 'First Blog'}

-- 6. F 表达式跨表
Entry:annotate{blog_info = F('blog_id__name')}:exec()
```
