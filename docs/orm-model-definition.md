# 模型定义与数据校验

> **示例模型** 见 [orm-models-reference.md](orm-models-reference.md)。本文涉及 `Blog` / `Author` / `Resume` / `BlogBin` 等，均按该 schema 定义。

## 创建模型

### Model:create_model(options)

创建一个模型类。模型类是 Sql 查询的入口，也负责数据校验。

**签名:** `Model:create_model(options: ModelOpts) -> Model`

```lua
local Model = require("model")

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

| 选项                      | 类型                | 说明                                 |
| ------------------------- | ------------------- | ------------------------------------ |
| `table_name`              | string              | 数据库表名（必填，除非 abstract）    |
| `fields`                  | table               | 字段定义列表                         |
| `field_names`             | string[]            | 字段顺序（可选，默认按 fields 顺序） |
| `abstract`                | boolean             | 抽象模型（不生成表，仅用于继承）     |
| `auto_primary_key`        | boolean             | 自动添加 `id` 主键（默认 true）      |
| `primary_key`             | string              | 主键名                               |
| `unique_together`         | string[]∣string[][] | 联合唯一约束                         |
| `extends`                 | Model               | 继承父模型                           |
| `mixins`                  | table[]             | 混入其他模型                         |
| `label`                   | string              | 模型标签（默认等于 table_name）      |
| `class_name`              | string              | 类名（自动从 table_name 转驼峰）     |
| `db_config`               | QueryOpts           | 数据库连接配置                       |
| `referenced_label_column` | string              | 被外键引用时的展示列                 |
| `preload`                 | boolean             | 外键是否预加载选项                   |
| `admin`                   | table               | 管理后台配置                         |

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

> **保留字段名陷阱**：字段名不能与模型类自身属性冲突，否则建模即报 `field name 'xxx' conflicts with model class attributes`。典型如 `label`（模型自带 `label` 元属性）、`name`、`fields`、`table_name` 等。需要"标签/名称"语义时改用 `code`、`title`、`seat_no` 等替代名。

### 通用字段选项

| 选项          | 类型         | 默认值   | 说明                           |
| ------------- | ------------ | -------- | ------------------------------ |
| `name`        | string       | (必填)   | 字段名                         |
| `type`        | string       | "string" | 字段类型                       |
| `label`       | string       | name     | 展示标签                       |
| `required`    | boolean      | false    | 是否必填                       |
| `default`     | any          | (按类型) | 默认值（可以是函数）           |
| `unique`      | boolean      | nil      | 唯一约束                       |
| `primary_key` | boolean      | nil      | 主键                           |
| `null`        | boolean      | (auto)   | 是否允许 NULL                  |
| `choices`     | table∣string | nil      | 可选值列表                     |
| `strict`      | boolean      | nil      | 启用 choices 校验（默认 true） |
| `disabled`    | boolean      | nil      | 禁用编辑                       |
| `index`       | boolean      | nil      | 索引                           |

### 各字段类型专有选项

#### string

```lua
{ "username", maxlength = 20, minlength = 2, compact = false, trim = true, pattern = "^[a-z]+$" }
```

| 选项        | 说明                                       |
| ----------- | ------------------------------------------ |
| `maxlength` | 最大长度（必填，除非有 choices 或 length） |
| `minlength` | 最小长度                                   |
| `length`    | 固定长度                                   |
| `compact`   | 删除所有空格（默认 true）                  |
| `trim`      | 去除首尾空格（默认 true）                  |
| `pattern`   | 正则校验                                   |

#### integer

```lua
{ "age", type = 'integer', min = 0, max = 150 }
```

| 选项     | 说明     |
| -------- | -------- |
| `min`    | 最小值   |
| `max`    | 最大值   |
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

| 选项           | 说明                       |
| -------------- | -------------------------- |
| `auto_now_add` | 创建时自动设置当前时间     |
| `auto_now`     | 每次更新时自动设置当前时间 |

> ⚠️ **时区依赖：** `auto_now`/`auto_now_add` 写入的是 `ngx.localtime()`（服务器本地时间、
> 不带时区偏移的字符串），而 `timezone = true`（默认）时 DDL 生成的是 `timestamptz` 列——
> PG 会按**数据库会话时区**解释这个字符串。请保证 nginx 所在机器与 PG 的 `timezone`
> 配置一致，否则写入的时间会整体偏移。

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

| 选项    | 说明               |
| ------- | ------------------ |
| `field` | 数组元素的字段定义 |

#### foreignkey (外键)

```lua
{ "blog_id", reference = Blog, related_query_name = 'entry' }
{ "author",  reference = Author }
{ "parent",  reference = "self" }    -- 自引用
```

| 选项                     | 默认值                 | 说明                      |
| ------------------------ | ---------------------- | ------------------------- |
| `reference`              | (必填)                 | 引用的模型 (或 "self")    |
| `reference_column`       | 引用模型的 primary_key | 引用列                    |
| `reference_label_column` | reference_column       | 展示列                    |
| `related_name`           | `{table_name}_set`     | 反向关联名                |
| `related_query_name`     | table_name             | 反向查询名 (用于跨表查询) |
| `on_delete`              | 'CASCADE'              | 删除策略                  |
| `on_update`              | 'CASCADE'              | 更新策略                  |

#### email / password / id_card / uuid

字符串子类，自带专用校验：

```lua
{ "email",   type = 'email' }      -- 校验合法邮箱（默认 maxlength = 255）
{ "secret",  type = 'password' }   -- StringField 子类，maxlength = 255
{ "id_no",   type = 'id_card' }    -- 校验中国大陆 18 位身份证（含日期/校验位）
{ "trace",   type = 'uuid' }       -- db_type = uuid，前端默认 disabled
```

继承自 `StringField`，因此 `compact` / `trim` / `pattern` / `minlength` / `maxlength` 等选项均可用。

#### year / month / year_month

```lua
{ "y",  type = 'year' }       -- IntegerField 子类，min=1000, max=9999
{ "m",  type = 'month' }      -- IntegerField 子类，min=1, max=12
{ "ym", type = 'year_month' } -- StringField 子类，maxlength=7，校验 'YYYY-MM' / 'YYYY.MM'
```

#### time

```lua
{ "open_at", type = 'time', precision = 0, timezone = true }
-- 校验 'HH:MM:SS' 格式
```

#### alioss / alioss_image / alioss_list / alioss_image_list

阿里云 OSS 文件字段，需要环境变量 `ALIOSS_URL`、`ALIOSS_SIZE`、`ALIOSS_LIFETIME` 等支持：

```lua
{ "avatar",  type = 'alioss_image', size = '1M', compress = '200K' }
{ "files",   type = 'alioss_list',  size = '5M' }
```

| 选项                | 说明                                   |
| ------------------- | -------------------------------------- |
| `size`              | 单文件大小上限，支持 `'1M'`, `'200K'`  |
| `compress`          | 自动压缩到目标大小（仅 image）         |
| `lifetime`          | 直传签名有效期（秒）                   |
| `key_id` / `key_secret` | OSS 凭证（默认从环境变量读取）     |
| `prefix`            | OSS 上传 key 前缀                      |
| `media_type`        | `image` / `video` 等                   |

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

| 选项             | 说明          |
| ---------------- | ------------- |
| `model`          | 子模型 (必填) |
| `max_rows`       | 最大行数      |
| `names`          | 校验字段列表  |
| `cascade_column` | 级联列名      |

> `max_rows` 只有**显式声明**时才在后端校验（超行数报错）；不声明时类默认值 1
> 仅作为前端展示提示，后端不限制行数。

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

所有校验失败都会 `error()` 一个 `ValidateError` 表，**类型恒为 `field_error`**。表格根据出错位置的不同会带额外字段：

| 字段          | 何时出现                              | 含义                            |
| ------------- | ------------------------------------- | ------------------------------- |
| `type`        | 总是                                  | 恒为 `'field_error'`            |
| `name`        | 总是                                  | 出错字段名                      |
| `label`       | 总是                                  | 字段 `label`（默认等于 `name`） |
| `message`     | 总是                                  | 错误描述（中文，可用 `error_messages` 覆盖） |
| `index`       | `table` / `array` 字段子元素出错时    | 出错的 1-based 行号             |
| `batch_index` | `insert` / `merge` / `upsert` / `updates` 批量调用时 | 出错的 1-based 行号 |

#### 单条 insert / update 出错

```lua
-- Blog.name maxlength = 20
Blog:insert{ name = 'This name is way too long ...' }:exec()
-- error: {
--   type    = 'field_error',
--   name    = 'name',
--   label   = 'name',
--   message = '字数不能多于20个',
-- }
```

#### 批量 insert / merge / upsert / updates 出错

错误包含 `batch_index` 指出第几行：

```lua
-- 第 2 行 age 超出 max
Author:upsert {
  { name = 'Tom',   age = 11  },
  { name = 'Jerry', age = 101 },   -- 第 2 行
}:exec()
-- error: {
--   type        = 'field_error',
--   name        = 'age',
--   label       = 'age',
--   message     = '值不能大于100',
--   batch_index = 2,
-- }
```

#### `table` 字段子元素出错（嵌套 message）

`table` 字段（如 `Author.resume`）中的某行子记录出错时，外层是 table 字段的错误，**内层 `message` 自身就是子记录的 `field_error`**，并带上 `index` 表示子数组的行号。

```lua
-- Resume.company maxlength = 20
Author:insert{ resume = { { company = string.rep('1', 30) } } }:exec()
-- error: {
--   type    = 'field_error',
--   name    = 'resume',
--   label   = 'resume',
--   index   = 1,                     -- resume 数组第 1 项
--   message = {
--     type    = 'field_error',
--     name    = 'company',
--     label   = 'company',
--     message = '字数不能多于20个',
--   },
-- }
```

如果该 insert 又是批量调用，外层再叠加 `batch_index`：

```lua
Author:insert{ { resume = { { company = string.rep('1', 30) } } } }:exec()
-- error: {
--   type        = 'field_error',
--   name        = 'resume',
--   label       = 'resume',
--   batch_index = 1,        -- 批量第 1 行
--   index       = 1,        -- resume 数组第 1 项
--   message     = { ... 同上 },
-- }
```

#### `merge` / `upsert` / `updates` 缺少 key

这些方法的"冲突键 / 主键"必须存在且非空，否则报 "<label>不能为空"：

```lua
-- updates 默认 key = primary_key (id)，下面这条没给 id
Blog:updates{ { tagline = 'Missing ID' } }:exec()
-- error: { type='field_error', name='id', label='id',
--          message='id不能为空', batch_index=1 }
```

#### 非法字段名

`insert` / `update` / `updates` 中提供模型未声明的字段时，会立即抛出（不是 `field_error` 表，是字符串）：

```lua
Author:updates({ { name = 'John Doe', age2 = 9 } }):exec()
-- error: invalid field name 'age2' for model 'author'
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

### Model:validate_cascade_update(input, names?)

级联校验：在 `validate_update` 的基础上，额外将主表主键值注入到 table 字段关联子表的外键中。

```lua
local data = Author:validate_cascade_update {
  id = 1,
  name = 'John',
  resume = {
    { start_date = '2020-01-01', end_date = '2023-01-01', company = 'Google', position = 'Dev' }
  }
}
-- data.resume 中的每条记录会自动注入 author_id = 1
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

### Model:make_field_from_json(options)

根据描述对象（来自 `to_json`、外部配置等）实例化一个字段对象。常用于动态构建模型或工具脚本：

```lua
local AnyField = Author:make_field_from_json {
  name      = 'phone',
  type      = 'string',
  maxlength = 20,
}
```

`options.type` 为空时会按 `reference` / `model` 推断为 `foreignkey` / `table`，否则默认 `string`。`string` / `alioss` 类型若未给 `maxlength`，会自动设为 256。

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

判断是否为 Sql builder 实例（通过 `create_sql` 创建）：

```lua
local sql = Blog:create_sql():where { id = 1 }
Model:is_instance(sql) -- true
Model:is_instance({})  -- false
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

| 字段    | 类型             | 说明                    |
| ------- | ---------------- | ----------------------- |
| `id`    | integer (serial) | 自增主键                |
| `ctime` | datetime         | 创建时间 (auto_now_add) |
| `utime` | datetime         | 更新时间 (auto_now)     |

关闭自动主键：

```lua
local Resume = Model:create_model {
  auto_primary_key = false,
  table_name = 'resume',
  fields = { ... }
}
```
