# 01 — Model 定义

> 详细说明如何定义模型、字段类型、继承、Mixin 和抽象模型。

## Model:create_model(options) — 创建模型

```lua
---@param options ModelOpts
---@return Xodel  -- 返回 Model 代理对象
```

### 最简定义

```lua
local Model = require("xodel.model")

local Blog = Model:create_model {
  table_name = 'blog',   -- 必填（非抽象模型）
  fields = {
    { "name",    maxlength = 20, unique = true },
    { "tagline", type = 'text',  default = 'default tagline' },
  }
}
```

### 简写方式 (Model 直接调用)

```lua
-- Model(...) 等价于 Model:mix(BaseModel, ...)
local Store = Model {
  table_name = 'store',
  fields = {
    { "name", maxlength = 300 },
  }
}
```

### ModelOpts 完整参数

| 参数                      | 类型         | 默认值            | 说明                   |
| ------------------------- | ------------ | ----------------- | ---------------------- |
| `table_name`              | `string`     | **必填**          | 数据库表名             |
| `fields`                  | `table[]`    | **必填**          | 字段定义数组           |
| `auto_primary_key`        | `boolean`    | `true`            | 是否自动添加 `id` 主键 |
| `abstract`                | `boolean`    | `table_name==nil` | 是否为抽象模型         |
| `extends`                 | `table`      | `nil`             | 继承父模型             |
| `mixins`                  | `table[]`    | `nil`             | 混入其他模型           |
| `unique_together`         | `string[][]` | `nil`             | 联合唯一约束           |
| `class_name`              | `string`     | 自动生成          | 类名(CamelCase)        |
| `label`                   | `string`     | `table_name`      | 人类可读名称           |
| `db_config`               | `table`      | 全局配置          | 数据库连接配置         |
| `referenced_label_column` | `string`     | `nil`             | 外键关联显示列         |
| `preload`                 | `boolean`    | `true`            | 是否预加载             |
| `admin`                   | `table`      | `{}`              | 管理后台配置           |
| `is_role_model`           | `boolean`    | `nil`             | 是否为角色模型         |

---

## 自动字段

每个 Model 默认自动包含以下三个字段（由 `BaseModel` 注入）：

| 字段名  | 类型       | 说明                                                    |
| ------- | ---------- | ------------------------------------------------------- |
| `id`    | `integer`  | 自增主键 (serial)，可通过 `auto_primary_key=false` 禁用 |
| `ctime` | `datetime` | 创建时间 (`auto_now_add`)，自动填入                     |
| `utime` | `datetime` | 更新时间 (`auto_now`)，每次更新自动刷新                 |

---

## 字段定义语法

字段使用数组形式定义，第一个元素是字段名，第二个元素可选为 label，其余为选项：

```lua
-- 语法: { name, [label], option1=val, option2=val, ... }
{ "name", maxlength = 20 }                     -- 字段名="name"
{ "name", "姓名", maxlength = 200, unique = true } -- 带 label
{ "email", type = 'email' }                     -- 指定类型
{ "blog_id", reference = Blog }                 -- 外键
```

### 字段类型一览

| type            | DB 类型       | 说明           | 常用选项                                                 |
| --------------- | ------------- | -------------- | -------------------------------------------------------- |
| `string` (默认) | `varchar(N)`  | 字符串         | `maxlength`, `minlength`, `unique`, `default`, `choices` |
| `text`          | `text`        | 长文本         | `default`                                                |
| `integer`       | `integer`     | 整数           | `max`, `min`, `serial`, `primary_key`                    |
| `float`         | `float`       | 浮点数         | `max`, `min`                                             |
| `boolean`       | `boolean`     | 布尔值         | `default`                                                |
| `date`          | `date`        | 日期           | `auto_now`, `auto_now_add`                               |
| `datetime`      | `timestamp`   | 日期时间       | `auto_now`, `auto_now_add`                               |
| `year_month`    | `varchar(7)`  | 年月           | —                                                        |
| `year`          | `varchar(4)`  | 年             | —                                                        |
| `month`         | `varchar(2)`  | 月             | —                                                        |
| `time`          | `time`        | 时间           | —                                                        |
| `email`         | `varchar(N)`  | 邮箱(带校验)   | —                                                        |
| `password`      | `varchar(N)`  | 密码(哈希存储) | —                                                        |
| `json`          | `jsonb`       | JSON           | —                                                        |
| `array`         | `jsonb`       | 数组           | —                                                        |
| `foreignkey`    | 引用列类型    | 外键           | `reference`, `related_query_name`                        |
| `table`         | `jsonb`       | 结构化JSON     | `model`                                                  |
| `uuid`          | `uuid`        | UUID           | —                                                        |
| `id_card`       | `varchar(18)` | 身份证         | —                                                        |
| `alioss`        | `varchar(N)`  | 阿里云 OSS URL | —                                                        |

### 字段通用选项

| 选项          | 类型      | 说明                           |
| ------------- | --------- | ------------------------------ | ------------ |
| `name`        | `string`  | 字段名 (数组第 1 个元素)       |
| `label`       | `string`  | 人类可读标签 (数组第 2 个元素) |
| `type`        | `string`  | 字段类型                       |
| `default`     | `any`     | 默认值                         |
| `required`    | `boolean` | 是否必填 (默认 `true`)         |
| `unique`      | `boolean` | 是否唯一                       |
| `primary_key` | `boolean` | 是否主键                       |
| `choices`     | `table`   | 可选值列表                     |
| `compact`     | `boolean` | false 则加入 detail_names      |
| `disabled`    | `boolean` | 是否禁用 (readonly)            |
| `reference`   | `Model    | "self"`                        | 外键引用模型 |
| `model`       | `Model`   | table 类型的子模型             |

---

## 外键定义

```lua
-- 外键字段名推荐以 _id 结尾（但不是强制的）
local Entry = Model:create_model {
  table_name = 'entry',
  fields = {
    -- reference: 目标模型
    -- related_query_name: 在目标模型上创建反向查询名
    { 'blog_id', reference = Blog, related_query_name = 'entry' },
    { 'reposted_blog_id', reference = Blog, related_query_name = 'reposted_entry' },
    { "headline", maxlength = 255 },
  }
}

-- 外键字段如果不以 _id 结尾也可以
local Book = Model:create_model {
  table_name = 'book',
  fields = {
    { "author", reference = Author },  -- 外键名 = author，实际列名 = author
    { 'publisher_id', reference = Publisher },
  }
}

-- 自引用
local Category = Model:create_model {
  table_name = 'category',
  fields = {
    { "name", maxlength = 100 },
    { "parent_id", reference = "self" },  -- 自引用用字符串 "self"
  }
}
```

### 外键自动推导

- `related_name` 默认为 `<table_name>_set`
- `related_query_name` 默认为 `<table_name>`
- 外键的 `reference_column` 默认为目标模型的 `primary_key`

---

## 结构化 JSON 字段 (table 类型)

用一个抽象 Model 定义 JSON 字段的结构：

```lua
-- 定义子结构(抽象模型)
local Resume = Model:create_model {
  auto_primary_key = false,
  table_name = 'resume',           -- 不会创建表，仅用于校验
  unique_together = { 'start_date', 'end_date', 'company', 'position' },
  fields = {
    { "start_date",  type = 'date' },
    { "end_date",    type = 'date' },
    { "company",     maxlength = 20 },
    { "position",    maxlength = 20 },
    { "description", maxlength = 200 },
  }
}

-- 在主模型中使用
local Author = Model:create_model {
  table_name = 'author',
  fields = {
    { "name", maxlength = 200, unique = true },
    { "resume", model = Resume },    -- 存储为 JSON 数组
  }
}

-- 存入数据时传入数组
Author:insert {
  name = 'John',
  resume = {
    { start_date='2015-01-01', end_date='2020-01-01', company='A', position='Dev', description='...' }
  }
}:exec()
```

---

## 联合唯一约束

```lua
local Resume = Model:create_model {
  auto_primary_key = false,
  table_name = 'resume',
  unique_together = { 'start_date', 'end_date', 'company', 'position' },
  fields = { ... }
}

-- 多组联合唯一
local Config = Model:create_model {
  table_name = 'config',
  unique_together = {
    { 'name', 'inst_id' },
    { 'code', 'inst_id' },
  },
  fields = { ... }
}
```

---

## 模型继承 (extends)

```lua
-- 父模型 (可通过 abstract = true 或省略 table_name 定义)
local Animal = Model:create_model {
  abstract = true,
  fields = {
    { "name", maxlength = 100 },
    { "age", type = 'integer' },
  }
}

-- 子模型继承父模型的字段，并可覆盖或新增
local Dog = Model:create_model {
  extends = Animal,
  table_name = 'dog',
  fields = {
    { "breed", maxlength = 50 },    -- 新增字段
    { "name", maxlength = 200 },     -- 覆盖父字段
  }
}
```

---

## Mixin (mixins)

```lua
-- Parent 模型
local Blog = Model:create_model {
  table_name = 'blog',
  fields = {
    { "name", maxlength = 20, unique = true },
    { "tagline", type = 'text', default = 'default tagline' },
  }
}

-- Mixin: 合并 Blog 的字段到 BlogBin
local BlogBin = Model:create_model {
  table_name = 'blog_bin',
  mixins = { Blog },            -- 继承 Blog 的所有字段定义
  fields = {
    { "name", unique = false },  -- 覆盖 Blog 的 name 字段 (去掉 unique)
    { "note", type = 'text' },   -- 新增字段
  }
}
-- BlogBin 拥有: id, ctime, utime, name, tagline, note
```

### mix 方法

```lua
-- Model:mix(...) 合并多个 ModelOpts 为一个新模型
local Combined = Model:mix(ModelA, ModelB, { fields = ... })
```

---

## Model 导出 (to_json)

```lua
-- 导出模型元信息 (用于前端 schema 生成等)
local json = Blog:to_json()           -- 导出所有字段
local json = Blog:to_json('name')     -- 仅导出 name 字段
local json = Blog:to_json({'name', 'tagline'})  -- 导出指定字段
```

---

## 命名约束

以下名称不能用作表名或列名：

1. PostgreSQL 保留字 (如 `user`, `order`, `group` 等) — 表名不可用，但系统会自动加引号处理
2. 包含 `__` 双下划线的名称 (用于操作符后缀和跨表查询路径)
3. 内部保留名: `T`, `D`, `U`, `V`, `W`, `NEW_RECORDS` (用于 SQL 别名)
