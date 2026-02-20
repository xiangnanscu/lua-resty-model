# 模型定义与数据校验

## 创建模型

### Model:create_model(options)

创建一个模型类。模型类是 Sql 查询的入口，也负责数据校验。

**签名:** `Model:create_model(options: ModelOpts) -> Xodel`

```lua
local Model = require("xodel.model")

local Blog = Model:create_model {
  table_name = 'blog',
  fields = {
    { "name",    maxlength = 20, unique = true },
    { "tagline", type = 'text',  default = 'default tagline' },
  }
}
```

### Model(options) — 简写形式

直接调用 `Model` 等价于 `Model:mix(BaseModel, options)`，会自动混入基础模型（含 id/ctime/utime）：

```lua
local Store = Model {
  table_name = 'store',
  fields = {
    { "name", maxlength = 300 },
  }
}
```

### ModelOpts 选项

| 选项 | 类型 | 说明 |
|------|------|------|
| `table_name` | string | 数据库表名（必填，除非 abstract） |
| `fields` | table | 字段定义列表 |
| `field_names` | string[] | 字段顺序（可选，默认按 fields 顺序） |
| `abstract` | boolean | 抽象模型（不生成表，仅用于继承） |
| `auto_primary_key` | boolean | 自动添加 `id` 主键（默认 true） |
| `primary_key` | string | 主键名 |
| `unique_together` | string[]∣string[][] | 联合唯一约束 |
| `extends` | Xodel | 继承父模型 |
| `mixins` | table[] | 混入其他模型 |
| `label` | string | 模型标签（默认等于 table_name） |
| `class_name` | string | 类名（自动从 table_name 转驼峰） |
| `db_config` | QueryOpts | 数据库连接配置 |
| `referenced_label_column` | string | 被外键引用时的展示列 |
| `preload` | boolean | 外键是否预加载选项 |
| `admin` | table | 管理后台配置 |

---

## 字段定义

字段使用快捷数组语法，数组前四个位置分别是 `name, label, type, required`：

```lua
-- 完整语法
{ name = "username", label = "用户名", type = "string", maxlength = 20, unique = true }

-- 快捷语法: 数组位置 [1]=name, [2]=label, [3]=type, [4]=required
{ "username", "用户名", "string", false, maxlength = 20, unique = true }

-- 最简语法: 只提供 name，type 默认为 string
{ "username", maxlength = 20 }
```

### 通用字段选项

| 选项 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `name` | string | (必填) | 字段名 |
| `type` | string | "string" | 字段类型 |
| `label` | string | name | 展示标签 |
| `required` | boolean | false | 是否必填 |
| `default` | any | (按类型) | 默认值（可以是函数） |
| `unique` | boolean | nil | 唯一约束 |
| `primary_key` | boolean | nil | 主键 |
| `null` | boolean | (auto) | 是否允许 NULL |
| `choices` | table∣string | nil | 可选值列表 |
| `strict` | boolean | nil | 启用 choices 校验（默认 true） |
| `disabled` | boolean | nil | 禁用编辑 |
| `index` | boolean | nil | 索引 |

### 各字段类型专有选项

#### string

```lua
{ "username", maxlength = 20, minlength = 2, compact = false, trim = true, pattern = "^[a-z]+$" }
```

| 选项 | 说明 |
|------|------|
| `maxlength` | 最大长度（必填，除非有 choices 或 length） |
| `minlength` | 最小长度 |
| `length` | 固定长度 |
| `compact` | 删除所有空格（默认 true） |
| `trim` | 去除首尾空格（默认 true） |
| `pattern` | 正则校验 |

#### integer

```lua
{ "age", type = 'integer', min = 0, max = 150 }
```

| 选项 | 说明 |
|------|------|
| `min` | 最小值 |
| `max` | 最大值 |
| `serial` | 自增序列 |

#### float

```lua
{ "price", type = 'float', min = 0 }
```

#### boolean

```lua
{ "active", type = 'boolean', default = true }
```

#### date / datetime / time

```lua
{ "pub_date", type = 'date' }
{ "ctime",    type = 'datetime', auto_now_add = true }
{ "utime",    type = 'datetime', auto_now = true }
```

| 选项 | 说明 |
|------|------|
| `auto_now_add` | 创建时自动设置当前时间 |
| `auto_now` | 每次更新时自动设置当前时间 |

#### text

```lua
{ "body", type = 'text', maxlength = 10000 }
```

#### json

```lua
{ "metadata", type = 'json' }
```

#### array

```lua
{ "tags", type = 'array', field = { maxlength = 20 } }
```

| 选项 | 说明 |
|------|------|
| `field` | 数组元素的字段定义 |

#### foreignkey (外键)

```lua
{ "blog_id", reference = Blog, related_query_name = 'entry' }
{ "author",  reference = Author }
{ "parent",  reference = "self" }    -- 自引用
```

| 选项 | 默认值 | 说明 |
|------|--------|------|
| `reference` | (必填) | 引用的模型 (或 "self") |
| `reference_column` | 引用模型的 primary_key | 引用列 |
| `reference_label_column` | reference_column | 展示列 |
| `related_name` | `{table_name}_set` | 反向关联名 |
| `related_query_name` | table_name | 反向查询名 (用于跨表查询) |
| `on_delete` | 'CASCADE' | 删除策略 |
| `on_update` | 'CASCADE' | 更新策略 |

#### table (结构化子表)

用于在 JSON 字段中存储结构化数据，基于子模型校验：

```lua
local Resume = Model:create_model {
  auto_primary_key = false,
  table_name = 'resume',
  fields = {
    { "start_date",  type = 'date' },
    { "end_date",    type = 'date' },
    { "company",     maxlength = 20 },
    { "position",    maxlength = 20 },
  }
}

local Author = Model:create_model {
  table_name = 'author',
  fields = {
    { "name",   maxlength = 200 },
    { "resume", model = Resume },   -- table 字段
  }
}
```

| 选项 | 说明 |
|------|------|
| `model` | 子模型 (必填) |
| `max_rows` | 最大行数 |
| `names` | 校验字段列表 |
| `cascade_column` | 级联列名 |

---

## 模型继承与混入

### extends (继承)

```lua
local BaseContent = Model:create_model {
  abstract = true,
  fields = {
    { "title",   maxlength = 200 },
    { "content", type = 'text' },
  }
}

local Article = Model:create_model {
  extends = BaseContent,
  table_name = 'article',
  fields = {
    { "title", maxlength = 100 },   -- 覆盖父级字段属性
    { "author", maxlength = 50 },   -- 新增字段
  }
}
-- Article 拥有字段: id, ctime, utime, title(maxlength=100), content, author
```

### mixins (混入)

```lua
local BlogBin = Model:create_model {
  table_name = 'blog_bin',
  mixins = { Blog },         -- 混入 Blog 的所有字段
  fields = {
    { "name", unique = false },  -- 覆盖 Blog.name 的 unique 属性
    { "note", type = 'text' },   -- 新增字段
  }
}
```

### Model:mix(...)

手动混合多个模型定义：

```lua
local Combined = Model:mix(ModelA, ModelB, { table_name = 'combined', fields = { ... } })
```

### Model:merge_models(models)

合并多个模型配置：

```lua
local merged_opts = Model:merge_models { optsA, optsB }
```

### Model:merge_model(a, b)

合并两个模型配置：

```lua
local merged = Model:merge_model(optsA, optsB)
```

### unique_together

```lua
local Resume = Model:create_model {
  table_name = 'resume',
  unique_together = { 'start_date', 'end_date', 'company' },
  fields = { ... }
}

-- 多组联合唯一
local Config = Model:create_model {
  table_name = 'config',
  unique_together = { { 'key', 'scope' }, { 'name', 'version' } },
  fields = { ... }
}
```

---

## 数据校验

### Model:validate(input, names?, key?)

智能校验：根据主键值决定是创建校验还是更新校验。

```lua
-- 有主键 → validate_update
local data = Blog:validate({ id = 1, name = 'updated' })

-- 无主键 → validate_create
local data = Blog:validate({ name = 'new blog' })
```

### Model:validate_create(input, names?)

创建校验：所有 `required` 字段必须有值，空值字段使用 `default`。

```lua
local data = Blog:validate_create { name = 'New Blog' }
-- data = { name = 'New Blog', tagline = 'default tagline' }
```

### Model:validate_update(input, names?)

更新校验：只校验 input 中提供的字段，跳过未提供的字段。

```lua
local data = Blog:validate_update { name = 'Updated Blog' }
-- data = { name = 'Updated Blog' }  (tagline 未提供, 不校验)
```

### 校验错误

校验失败会 `error()` 一个 `ValidateError` 表：

```lua
-- ValidateError 结构:
{
  type = 'field_error',
  name = 'age',         -- 字段名
  label = '年龄',       -- 字段标签
  message = '最大值为100', -- 错误信息
  index = nil,          -- 仅 table 字段, 表示错误行号
  batch_index = nil,    -- 仅批量操作, 表示错误行号
}
```

---

## 记录操作

### Model:create(input)

创建记录：校验 → 插入 → 返回完整实例（包含 id/ctime/utime）。

```lua
local user = User:create { username = 'admin', password = 'secret' }
-- user.id, user.username, user.ctime, user.utime 均有值
```

### Model:save(input, names?, key?)

智能保存：有主键值则更新，否则创建。

```lua
-- 创建 (无 id)
local blog = Blog:save { name = 'New Blog', tagline = 'hello' }

-- 更新 (有 id)
blog.tagline = 'updated'
local updated = Blog:save(blog)
```

### Model:save_create(input, names?, key?)

强制创建（即使 input 中有主键值也会创建新记录）。

```lua
local blog = Blog:save_create { name = 'Blog 1' }
```

### Model:save_update(input, names?, key?)

强制更新。input 中必须有 key 对应的值。

```lua
local blog = Blog:save_update({ id = 1, name = 'Updated' })

-- 使用自定义 key:
local blog = Blog:save_update({ name = 'Updated', tagline = 'hi' }, nil, 'name')
```

### Model:save_cascade_update(input, names?, key?)

级联更新：同时更新主表和 table 字段关联的子表。

```lua
local author = Author:save_cascade_update {
  id = 1,
  name = 'John',
  resume = {
    { start_date = '2020-01-01', end_date = '2023-01-01', company = 'Google', position = 'Dev' }
  }
}
```

### Model:load(data)

从数据库记录加载数据，调用每个字段的 `load` 方法进行转换（如外键创建代理对象）：

```lua
local entry = Entry:load({ id = 1, blog_id = 2, headline = 'Hello' })
-- entry.blog_id 变为外键代理对象，访问 entry.blog_id.name 会自动查询 Blog
```

### Model:create_record(data)

创建记录实例（设置元表），使实例拥有 `save`、`delete`、`validate` 等方法：

```lua
local record = Blog:create_record { id = 1, name = 'Test' }
record:save()     -- 等价于 Blog:save(record)
record:delete()   -- 等价于 Blog:create_sql():delete{id=1}:returning('id'):exec()
```

### 记录实例方法

通过 `create`、`save`、`load` 等返回的实例自带以下方法：

```lua
record:save(names?, key?)            -- 保存 (创建或更新)
record:save_create(names?, key?)     -- 强制创建
record:save_update(names?, key?)     -- 强制更新
record:validate(names?, key?)        -- 校验
record:validate_create(names?)       -- 创建校验
record:validate_update(names?)       -- 更新校验
record:delete(key?)                  -- 删除 (默认用 primary_key)
record(data)                         -- 合并数据: record({ name = 'new name' })
```

---

## 事务

### Model:transaction(callback)

```lua
local result, err = Blog:transaction(function()
  Blog:create { name = 'Blog A' }
  Entry:create { blog_id = 1, headline = 'Entry 1' }
  return { success = true }
end)
-- 任何错误会自动 ROLLBACK
```

### Model:atomic(func)

将函数包装为事务：

```lua
local handler = Blog:atomic(function(request)
  -- 此函数内的所有数据库操作都在事务中
  Blog:create { name = request.name }
  return { ok = true }
end)
-- 使用: handler(request)
```

---

## 其他 Model API

### Model:create_sql()

创建并返回一个 Sql 构建器实例：

```lua
local sql = Blog:create_sql()
sql:select('name'):where{id=1}:exec()
```

### Model:create_sql_as(table_name, rows)

创建带 CTE VALUES 的 Sql 构建器（用于自定义虚拟表）：

```lua
local sql = Blog:create_sql_as('custom_table', {
  { id = 1, name = 'a' },
  { id = 2, name = 'b' },
})
```

### Model:to_json(names?)

将模型元数据导出为 JSON（用于前端表单生成等）：

```lua
-- 导出全部字段
local json = Blog:to_json()

-- 导出指定字段
local json = Blog:to_json { 'name', 'tagline' }
```

### Model:is_model_class(model)

```lua
Model:is_model_class(Blog) -- true
Model:is_model_class({})   -- false
```

### Model:is_instance(row)

```lua
local blog = Blog:create { name = 'test' }
Blog:is_instance(blog) -- true
```

### Model:check_unique_key(key)

验证字段是否为主键或唯一键：

```lua
Blog:check_unique_key('name') -- 'name' (Blog.name 是 unique 的)
Blog:check_unique_key('tagline') -- error: field 'tagline' is not primary_key or not unique
```

---

## 自动字段

模型默认自带三个自动字段（除非 `auto_primary_key = false`）：

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | integer (serial) | 自增主键 |
| `ctime` | datetime | 创建时间 (auto_now_add) |
| `utime` | datetime | 更新时间 (auto_now) |

关闭自动主键：

```lua
local Resume = Model:create_model {
  auto_primary_key = false,
  table_name = 'resume',
  fields = { ... }
}
```
