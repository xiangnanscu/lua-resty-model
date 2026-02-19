# Model API

Model (Xodel) 层面的公共 API，用于模型定义、数据校验和 CRUD 快捷操作。

> **注意**: 所有 Sql 方法（如 `where`, `select`, `insert` 等）都可以通过 Model 代理直接调用。Model 内部自动创建 Sql 实例并转发。

---

## 模型定义

### Xodel(options) / Xodel:create_model(options)

创建新模型类。`Xodel(options)` 自动混入 BaseModel（含 id, ctime, utime 字段）。

```lua
local Model = require("xodel.model")

local Blog = Model {
  table_name = "blog",
  fields = {
    name = { type = "string", unique = true, maxlength = 100 },
    tagline = { type = "string", maxlength = 200 }
  }
}
-- 自动包含 id (serial primary key), ctime, utime
```

### Xodel:mix(...)

合并多个模型定义。

```lua
local TimestampMixin = { abstract = true, fields = { ... } }
local MyModel = Model:mix(TimestampMixin, { table_name = "my_table", fields = { ... } })
```

---

## 快捷 CRUD

### create(input)

校验 + 插入 + 返回实例。等价于 `save_create(input, self.names, '*')`。

```lua
---@param input Record
---@return XodelInstance
function Xodel:create(input)
```

```lua
local blog = Blog:create{name = 'New Blog', tagline = 'desc'}
-- blog 是 XodelInstance，包含数据库分配的 id、ctime、utime
print(blog.id, blog.name)
```

### save(input, names, key)

智能保存：有主键值则更新，否则创建。

```lua
---@param input Record
---@param names? string[]
---@param key? string
---@return XodelInstance
function Xodel:save(input, names, key)
```

```lua
-- 无 id → 创建
local blog = Blog:save{name = 'New Blog'}

-- 有 id → 更新
blog.tagline = 'Updated'
Blog:save(blog)
```

### save_create(input, names, key)

强制创建：校验 → `_prepare_for_db` → INSERT → RETURNING → 返回实例。

```lua
---@param input Record
---@param names? string[]
---@param key? string
---@return XodelInstance
function Xodel:save_create(input, names, key)
```

### save_update(input, names, key)

强制更新：校验 → `_prepare_for_db` → UPDATE → RETURNING → 返回实例。要求 input 中必须包含主键或唯一键的值。

```lua
---@param input Record
---@param names? string[]
---@param key? string
---@return XodelInstance
function Xodel:save_update(input, names, key)
```

```lua
local blog = Blog:save_update{id = 1, name = 'Updated Name'}
```

### save_cascade_update(input, names, key)

级联更新：更新主记录的同时，处理嵌套的子表（TableField）数据。

```lua
---@param input Record
---@param names? string[]
---@param key? string
---@return XodelInstance
function Xodel:save_cascade_update(input, names, key)
```

---

## 数据校验

### validate(input, names, key)

智能校验：有主键值则走 `validate_update`，否则走 `validate_create`。

```lua
---@param input Record
---@param names? string[]
---@param key? string
---@return Record
function Xodel:validate(input, names, key)
```

### validate_create(input, names)

创建校验：所有必填字段检查 + 字段级校验。

```lua
---@param input Record
---@param names? string[]
---@return Record
function Xodel:validate_create(input, names)
```

```lua
local data = Blog:validate_create{name = 'Test'}
-- 通过所有字段校验后返回清洁数据
-- 校验失败则抛出 ValidateError
```

### validate_update(input, names)

更新校验：仅校验提供的字段，允许部分更新。

```lua
---@param input Record
---@param names? string[]
---@return Record
function Xodel:validate_update(input, names)
```

---

## 实例与记录

### create_record(data)

将原始数据 table 包装为 XodelInstance（绑定 RecordClass 元表）。

```lua
---@param data Record
---@return XodelInstance
function Xodel:create_record(data)
```

### load(data)

加载数据库原始记录：对每个字段执行 `field:load()` 转换（如 JSON 反序列化、外键延迟加载等）。

```lua
---@param data Record
---@return XodelInstance
function Xodel:load(data)
```

### is_instance(row)

判断给定值是否是当前模型的实例。

```lua
---@param row any
---@return boolean
function Xodel:is_instance(row)
```

---

## 事务

### transaction(callback)

在数据库事务中执行回调。

```lua
function Xodel:transaction(callback)
```

```lua
Blog:transaction(function()
  Blog:create{name = 'A'}
  Blog:create{name = 'B'}
  -- 全部成功或全部回滚
end)
```

### atomic(func)

将函数包装为事务性函数（返回一个新函数，每次调用自动开启事务）。

```lua
function Xodel:atomic(func)
```

```lua
local handler = Blog:atomic(function(request)
  -- 整个 handler 在事务中执行
end)
```

---

## 实例方法 (XodelInstance)

通过 `create`, `save`, `get` 等返回的 XodelInstance 支持以下方法：

```lua
local blog = Blog:create{name = 'Test'}

-- 删除
blog:delete()
-- DELETE FROM blog WHERE id = <id>

-- 保存 (更新)
blog.name = 'Updated'
blog:save()

-- 校验
blog:validate()
blog:validate_create()
blog:validate_update()
```

---

## 工具方法

### create_sql()

创建一个空的 Sql 实例，关联到当前模型。

```lua
---@return Sql
function Xodel:create_sql()
```

### create_sql_as(table_name, rows)

创建带 CTE VALUES 的 Sql 实例。

```lua
---@param table_name string
---@param rows Record[]
---@return Sql
function Xodel:create_sql_as(table_name, rows)
```

### to_json(names)

将模型定义序列化为 JSON 格式。

```lua
---@param names? string[]|string
---@return ModelOpts
function Xodel:to_json(names)
```

### is_model_class(model)

判断给定值是否是模型类。

```lua
---@param model any
---@return boolean
function Xodel:is_model_class(model)
```

---

## 类属性

| 属性                    | 类型     | 说明                                                |
| ----------------------- | -------- | --------------------------------------------------- |
| `table_name`            | string   | 数据库表名                                          |
| `class_name`            | string   | 类名 (CamelCase)                                    |
| `label`                 | string   | 模型中文标签                                        |
| `fields`                | table    | 字段定义 `{name: AnyField}`                         |
| `field_names`           | Array    | 有序字段名列表                                      |
| `names`                 | Array    | 可写字段名 (排除 serial PK, auto_now, auto_now_add) |
| `primary_key`           | string   | 主键字段名                                          |
| `unique_together`       | Array    | 联合唯一约束                                        |
| `foreignkey_fields`     | table    | 外键字段映射                                        |
| `reversed_fields`       | table    | 反向外键映射                                        |
| `Q`                     | class    | Q 逻辑构建器                                        |
| `F`                     | class    | F 字段表达式                                        |
| `Count/Sum/Avg/Max/Min` | class    | 聚合函数构造器                                      |
| `NULL`                  | userdata | 数据库 NULL 值                                      |
| `DEFAULT`               | function | 数据库 DEFAULT 值                                   |
