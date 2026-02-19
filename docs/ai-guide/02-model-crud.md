# 02 — Model 层 CRUD

> Model 层的创建、保存、校验 API。这些方法带有数据校验逻辑，返回 Record 实例。

## Record 实例

Model 层 CRUD 方法返回 `XodelInstance`（Record 实例），它是一个 Lua table，额外绑定了以下方法：

```lua
local record = Blog:create { name = 'My Blog' }

-- Record 实例方法
record:save(names?, key?)           -- 更新记录
record:save_create(names?, key?)     -- 创建副本
record:save_update(names?, key?)     -- 更新记录
record:validate(names?, key?)        -- 校验
record:validate_create(names?)       -- 创建校验
record:validate_update(names?)       -- 更新校验
record:delete(key?)                  -- 删除自身

-- 更新属性
record { tagline = 'new tagline' }   -- 调用 record 本身可批量更新属性
```

---

## Model:create(input) — 验证+创建+返回

```lua
---@param input Record
---@return XodelInstance     -- 返回记录实例，包含数据库生成的 id、ctime 等
```

内部流程: `validate_create` → `_prepare_for_db` → `INSERT ... RETURNING *` → `create_record`

### 示例

```lua
-- 创建用户
local user = User:create { username = 'admin', password = 'password' }
print(user.id)        -- 自增ID
print(user.username)  -- 'admin'
print(user.ctime)     -- 自动生成的创建时间
```

---

## Model:save(input, names?, key?) — 智能保存

```lua
---@param input Record      -- 输入数据
---@param names? string[]   -- 要保存的字段名列表（默认全部）
---@param key?  string      -- 查找键（默认主键）
---@return XodelInstance
```

自动判断：如果 `input[key]` 有值则 update，否则 create。

### 示例

```lua
-- 新建（没有 id 字段）
local blog = Blog:save { name = 'New Blog', tagline = 'Hello' }
-- blog.id 会被自动生成

-- 更新（有 id 字段）
blog.tagline = 'Updated tagline'
Blog:save(blog)
-- 等价于
blog:save()

-- 指定保存字段
Blog:save(blog, { 'tagline' })  -- 仅更新 tagline

-- 使用其他唯一键
Blog:save(blog, nil, 'name')  -- 用 name 字段作为查找键
```

---

## Model:save_create(input, names?, key?) — 验证+创建

```lua
---@param input Record
---@param names? string[]   -- 要校验的字段名列表（默认 model.names）
---@param key?  string      -- RETURNING 的列（默认 '*'）
---@return XodelInstance
```

### 示例

```lua
-- 基本创建
local author = Author:save_create {
  name = 'John Doe',
  email = 'john@example.com',
  age = 30
}

-- 仅校验指定字段
local author = Author:save_create(
  { name = 'Jane', email = 'jane@example.com', age = 28 },
  { 'name', 'email' }  -- 仅校验这两个字段
)
```

---

## Model:save_update(input, names?, key?) — 验证+更新

```lua
---@param input Record
---@param names? string[]   -- 要校验的字段名列表
---@param key?  string      -- 查找键（必须是 unique 或 primary_key 字段）
---@return XodelInstance
```

### 示例

```lua
-- 通过主键更新
local blog = Blog:save_update { id = 1, tagline = 'Updated!' }

-- 通过唯一键更新
local blog = Blog:save_update(
  { name = 'First Blog', tagline = 'Updated!' },
  nil,     -- names: 使用默认
  'name'   -- 用 name 字段查找记录
)

-- Record 实例方法
local blog = Blog:get { id = 1 }
blog.tagline = 'New tagline'
blog:save_update()
-- 等价于
Blog:save_update(blog)
```

---

## Model:validate(input, names?, key?) — 智能校验

```lua
---@param input Record
---@param names? string[]
---@param key? string     -- 默认 model.primary_key
---@return Record          -- 校验通过的清洗数据
-- error: ValidateError   -- 校验失败抛出错误
```

自动判断：如果 `input[key]` 有值则走 `validate_update`，否则走 `validate_create`。

### 示例

```lua
-- 创建校验（没有 id）
local data = Blog:validate { name = 'Test', tagline = 'Hello' }

-- 更新校验（有 id）
local data = Blog:validate { id = 1, tagline = 'Updated' }
```

---

## Model:validate_create(input, names?) — 创建校验

```lua
---@param input Record
---@param names? string[]   -- 要校验的字段名列表
---@return Record            -- 校验通过后的清洗数据
-- error: ValidateError     -- 校验失败抛出
```

**校验规则:**

1. 遍历 `names`（默认 `model.names`，不含自动字段）中的每个字段
2. 如果字段值为 `nil` 且有 `default`，使用默认值
3. 如果字段值为 `nil` 且 `required = true`，抛出必填错误
4. 对非 `nil` 值运行字段的 `validators` 链（类型检查、长度、范围、自定义校验器等）

### 示例

```lua
-- 正常校验
local data = Blog:validate_create { name = 'Test', tagline = 'Hello' }
-- data = { name = 'Test', tagline = 'Hello' }

-- 校验失败示例
local ok, err = pcall(Blog.validate_create, Blog, { tagline = 'no name' })
-- err = { type='field_error', name='name', label='name', message='此项必填' }

-- 仅校验部分字段
local data = Blog:validate_create({ name = 'Test' }, { 'name' })
```

---

## Model:validate_update(input, names?) — 更新校验

```lua
---@param input Record
---@param names? string[]
---@return Record
```

与 `validate_create` 不同：

- 跳过 `nil` 值字段（更新时允许部分更新）
- 不检查 `required`
- 仅校验有值的字段

### 示例

```lua
-- 部分更新校验 — tagline 可以不传
local data = Blog:validate_update { name = 'Updated Name' }
-- data = { name = 'Updated Name' }

-- 值为 nil 的字段被跳过
local data = Blog:validate_update { id = 1, name = nil, tagline = 'Updated' }
-- data = { tagline = 'Updated' }
```

---

## ValidateError 错误格式

```lua
---@class ValidateError
---@field type string       -- 固定为 'field_error'
---@field name string       -- 字段名
---@field label string      -- 字段标签
---@field message string    -- 错误信息
---@field index? integer    -- TableField 的错误行索引
---@field batch_index? integer  -- 批量操作时的行索引
```

### 捕获校验错误

```lua
local ok, err = pcall(function()
  return Blog:create { name = '' }  -- name 太短 (minlength=2)
end)

if not ok then
  if type(err) == 'table' and err.type == 'field_error' then
    print(err.name)     -- "name"
    print(err.message)  -- 错误详情
    print(err.label)    -- "name"
  end
end
```

---

## Model:save_cascade_update(input, names?, key?) — 级联更新

```lua
---@param input Record      -- 包含嵌套 table 类型字段的数据
---@param names? string[]
---@param key?  string
---@return XodelInstance
```

用于更新包含 `table` 类型字段（结构化 JSON）的记录，会同时处理嵌套数据的级联操作。

### 示例

```lua
-- 更新 Author 的同时更新其 resume 字段
Author:save_cascade_update {
  id = 1,
  name = 'Updated Name',
  resume = {
    { start_date='2015-01-01', end_date='2020-01-01', company='NewCo', position='Lead', description='...' }
  }
}
```

---

## Model:load(data) — 从数据库加载

```lua
---@param data Record
---@return XodelInstance
```

对数据库返回的原始数据进行字段级 `load` 转换（如 JSON 反序列化），然后包装为 Record 实例。

### 示例

```lua
-- 通常不需要手动调用，exec() 会自动调用 load
-- 仅在需要手动处理原始数据时使用
local raw = { id = 1, name = 'Test', resume = '{"company":"A"}' }
local record = Author:load(raw)
-- record.resume 现在是 Lua table
```

---

## Model:create_record(data) — 创建 Record 实例

```lua
---@param data table
---@return XodelInstance
```

将普通 table 包装为 Record 实例（不写库，不校验）。

```lua
local record = Blog:create_record { id = 1, name = 'Test' }
-- record 具有 save/delete 等方法
record:save()
```

---

## Model:transaction(callback) — 事务

```lua
---@param callback function
---@return any    -- callback 的返回值
```

### 示例

```lua
Blog:transaction(function()
  Blog:create { name = 'Blog A' }
  Blog:create { name = 'Blog B' }
  -- 如果任何操作失败，全部回滚
end)
```

---

## Model:atomic(func) — 返回事务包装函数

```lua
---@param func fun(request):any
---@return fun(request):any
```

适用于 web 请求处理，将整个请求处理函数包在事务中。

### 示例

```lua
-- 在路由处理中使用
local handler = Blog:atomic(function(request)
  Blog:create { name = request.name }
  Entry:create { blog_id = 1, headline = request.headline }
  return { code = 200 }
end)
-- handler 自动在事务中运行
```
