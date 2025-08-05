# Model.lua 使用说明

本文档详细说明了 lua-resty-model 中 model.lua 文件所有公共方法的使用方式。文档使用与 model_spec.lua 相同的模型进行示例演示。

## 模型定义

### 测试模型结构

```lua
local Model = require("resty.model")

-- Blog 模型
local Blog = Model:create_model {
  table_name = 'blog',
  fields = {
    { "name", maxlength = 20, minlength = 2, unique = true, compact = false },
    { "tagline", type = 'text', default = 'default tagline' },
  }
}

-- Entry 模型
local Entry = Model:create_model {
  table_name = 'entry',
  fields = {
    { 'blog_id', reference = Blog, related_query_name = 'entry' },
    { 'reposted_blog_id', reference = Blog, related_query_name = 'reposted_entry' },
    { "headline", maxlength = 255, compact = false },
    { "body_text", type = 'text' },
    { "pub_date", type = 'date' },
    { "mod_date", type = 'date' },
    { "number_of_comments", type = 'integer' },
    { "number_of_pingbacks", type = 'integer' },
    { "rating", type = 'integer' },
  }
}

-- Author 模型
local Author = Model:create_model {
  table_name = 'author',
  fields = {
    { "name", maxlength = 200, unique = true, compact = false },
    { "email", type = 'email' },
    { "age", type = 'integer', max = 100, min = 10 },
    { "resume", model = Resume },
  }
}
```

---

## 1. 模型创建和配置方法 (Xodel 类)

### new(attrs?)

创建新的模型实例。

```lua
-- 方式1: 无参数创建
local model = Model:new()

-- 方式2: 传入属性表创建
local model = Model:new({
  table_name = 'test_table',
  fields = { { "name", maxlength = 50 } }
})
```

### create_model(options)

创建模型类，这是定义模型的主要方法。

```lua
-- 方式1: 基本模型定义
local SimpleModel = Model:create_model {
  table_name = 'simple',
  fields = {
    { "name", maxlength = 100 },
    { "description", type = 'text' }
  }
}

-- 方式2: 复杂模型定义（包含外键、唯一约束等）
local ComplexModel = Model:create_model {
  table_name = 'complex',
  auto_primary_key = true,
  unique_together = { 'field1', 'field2' },
  fields = {
    { "field1", maxlength = 50 },
    { "field2", type = 'integer' },
    { "reference_id", reference = SimpleModel }
  }
}

-- 方式3: 抽象模型定义
local AbstractModel = Model:create_model {
  abstract = true,
  fields = {
    { "common_field", maxlength = 100 }
  }
}

-- 方式4: 继承模型定义
local InheritedModel = Model:create_model {
  table_name = 'inherited',
  extends = AbstractModel,
  fields = {
    { "specific_field", type = 'text' }
  }
}
```

### transaction(callback)

执行数据库事务。

```lua
-- 方式1: 基本事务
Model:transaction(function()
  Blog:insert({ name = 'Test Blog 1', tagline = 'Test' }):exec()
  Blog:insert({ name = 'Test Blog 2', tagline = 'Test' }):exec()
end)

-- 方式2: 带返回值的事务
local result = Model:transaction(function()
  local blog = Blog:insert({ name = 'New Blog', tagline = 'New' }):returning('*'):exec()
  return blog[1]
end)
```

### atomic(func)

创建原子操作函数。

```lua
-- 方式1: 创建原子操作函数
local atomic_insert = Model:atomic(function(request)
  return Blog:insert(request.data):returning('*'):exec()
end)

-- 使用原子操作
local result = atomic_insert({ data = { name = 'Atomic Blog', tagline = 'Atomic' } })
```

### make_field_from_json(options)

从 JSON 配置创建字段。

```lua
-- 方式1: 创建基本字段
local string_field = Model:make_field_from_json({
  name = 'title',
  type = 'string',
  maxlength = 100
})

-- 方式2: 创建外键字段
local fk_field = Model:make_field_from_json({
  name = 'blog_id',
  type = 'foreignkey',
  reference = Blog
})

-- 方式3: 创建表字段
local table_field = Model:make_field_from_json({
  name = 'metadata',
  type = 'table',
  model = SomeModel
})
```

### create_sql()

创建 SQL 查询构建器。

```lua
-- 方式1: 创建基本查询构建器
local sql = Blog:create_sql()

-- 方式2: 链式调用
local results = Blog:create_sql():select('name'):where({ tagline = 'test' }):exec()
```

### is_model_class(model)

检查对象是否为模型类。

```lua
-- 方式1: 检查模型类
local is_model = Model:is_model_class(Blog) -- true
local is_not_model = Model:is_model_class({}) -- false
```

---

## 2. 查询构建方法 (SQL 构建器)

### select(a, b?, ...)

选择查询字段。

```lua
-- 方式1: 选择单个字段
Blog:select('name'):exec()

-- 方式2: 选择多个字段
Blog:select('name', 'tagline'):exec()

-- 方式3: 选择字段数组
Blog:select({'name', 'tagline'}):exec()

-- 方式4: 选择所有字段
Blog:select('*'):exec()

-- 方式5: 使用回调函数
Blog:select(function(ctx)
  return ctx[1].name .. ', ' .. ctx[1].tagline
end):exec()

-- 方式6: 选择计算字段
Blog:select('name'):annotate({count = Count('*')}):select('count'):exec()
```

### select_as(kwargs, as?)

选择字段并设置别名。

```lua
-- 方式1: 传入表形式
Blog:select_as({name = 'blog_name', tagline = 'blog_desc'}):exec()

-- 方式2: 传入字段名和别名
Blog:select_as('name', 'blog_title'):exec()
```

### select_literal(a, b?, ...)

选择字面值。

```lua
-- 方式1: 选择单个字面值
Blog:select_literal('Hello World'):exec()

-- 方式2: 选择多个字面值
Blog:select_literal(1, 'test', true):exec()

-- 方式3: 选择字面值数组
Blog:select_literal({1, 2, 3}):exec()
```

### select_literal_as(kwargs)

选择字面值并设置别名。

```lua
-- 方式1: 字面值别名
Blog:select_literal_as({
  ['Hello World'] = 'greeting',
  [42] = 'answer'
}):exec()
```

### where(cond, op?, dval?)

添加 WHERE 条件。

```lua
-- 方式1: 传入条件表
Blog:where({name = 'First Blog'}):exec()

-- 方式2: 传入多个条件
Blog:where({name = 'First Blog', tagline = 'Welcome'}):exec()

-- 方式3: 字符串条件
Blog:where('name = \'First Blog\''):exec()

-- 方式4: 字段名和值
Blog:where('name', 'First Blog'):exec()

-- 方式5: 字段名、操作符和值
Blog:where('name', '=', 'First Blog'):exec()

-- 方式6: 使用操作符后缀
Blog:where({name__contains = 'Blog'}):exec()
Blog:where({name__startswith = 'First'}):exec()
Blog:where({name__endswith = 'Blog'}):exec()
Blog:where({name__in = {'First Blog', 'Second Blog'}}):exec()
Blog:where({name__gt = 'A'}):exec()

-- 方式7: 使用Q对象
local Q = Model.Q
Blog:where(Q({name = 'First'}) / Q({name = 'Second'})):exec() -- OR
Blog:where(Q({name = 'First'}) * Q({tagline = 'Welcome'})):exec() -- AND
Blog:where(-Q({name = 'First'})):exec() -- NOT

-- 方式8: 使用回调函数
Blog:join(Entry, function(ctx)
  return ctx[1].id .. ' = ' .. ctx[2].blog_id
end):where(function(ctx)
  return ctx[2].rating .. ' > 4'
end):exec()
```

### where_in(cols, range)

添加 IN 条件。

```lua
-- 方式1: 单列IN条件
Blog:where_in('name', {'First Blog', 'Second Blog'}):exec()

-- 方式2: 多列IN条件
Entry:where_in({'blog_id', 'rating'}, {{1, 5}, {2, 4}}):exec()

-- 方式3: 子查询IN条件
local subquery = Entry:select('blog_id'):where({rating__gt = 4})
Blog:where_in('id', subquery):exec()
```

### where_not_in(cols, range)

添加 NOT IN 条件。

```lua
-- 方式1: 单列NOT IN条件
Blog:where_not_in('name', {'Test Blog'}):exec()

-- 方式2: 多列NOT IN条件
Entry:where_not_in({'blog_id', 'rating'}, {{1, 1}, {2, 2}}):exec()

-- 方式3: 子查询NOT IN条件
local subquery = Entry:select('blog_id'):where({rating__lt = 3})
Blog:where_not_in('id', subquery):exec()
```

### where_or(cond, op?, dval?)

添加 OR 条件。

```lua
-- 方式1: 表形式OR条件
Blog:where_or({name = 'First', tagline = 'Second'}):exec()

-- 方式2: 字段名和值
Blog:where({name = 'First'}):where_or('tagline', 'test'):exec()
```

### or_where(cond, op?, dval?)

使用 OR 连接前一个条件。

```lua
-- 方式1: OR连接
Blog:where({name = 'First'}):or_where({name = 'Second'}):exec()

-- 方式2: OR连接字段条件
Blog:where('name', 'First'):or_where('name', 'Second'):exec()
```

### or_where_or(cond, op?, dval?)

使用 OR 连接多个 OR 条件。

```lua
-- 方式1: 多重OR条件
Blog:where({name = 'A'}):or_where_or({name = 'B', tagline = 'C'}):exec()
```

### having(cond)

添加 HAVING 条件。

```lua
-- 方式1: 聚合条件
Blog:annotate({entry_count = Count('entry')}):group('name'):having({entry_count__gt = 2}):exec()

-- 方式2: Q对象HAVING条件
local Q = Model.Q
Blog:group('name'):having(Q({entry_count__gt = 1})):exec()
```

### order(a, ...)

添加排序。

```lua
-- 方式1: 单字段排序
Blog:order('name'):exec()

-- 方式2: 多字段排序
Blog:order('name', 'tagline'):exec()

-- 方式3: 指定排序方向
Blog:order('+name'):exec() -- ASC
Blog:order('-name'):exec() -- DESC

-- 方式4: 排序数组
Blog:order({'name', '-tagline'}):exec()

-- 方式5: 使用回调函数
Blog:order(function(ctx)
  return ctx[1].name .. ' DESC'
end):exec()
```

### order_by(...)

order 方法的别名。

```lua
-- 与order方法相同的调用方式
Blog:order_by('name'):exec()
Blog:order_by('-tagline'):exec()
```

### group(a, ...)

添加分组。

```lua
-- 方式1: 单字段分组
Blog:group('name'):exec()

-- 方式2: 多字段分组
Entry:group('blog_id', 'rating'):exec()

-- 方式3: 分组数组
Entry:group({'blog_id', 'pub_date'}):exec()
```

### group_by(...)

group 方法的别名。

```lua
-- 与group方法相同的调用方式
Blog:group_by('name'):exec()
```

### limit(n)

限制结果数量。

```lua
-- 方式1: 整数限制
Blog:limit(10):exec()

-- 方式2: 字符串数字
Blog:limit('5'):exec()
```

### offset(n)

设置结果偏移。

```lua
-- 方式1: 整数偏移
Blog:offset(10):exec()

-- 方式2: 字符串数字
Blog:offset('5'):exec()

-- 方式3: 分页查询
Blog:limit(10):offset(20):exec() -- 第3页，每页10条
```

### distinct(...)

去重查询。

```lua
-- 方式1: 全部去重
Blog:distinct():exec()

-- 方式2: 指定字段去重
Entry:distinct('blog_id'):exec()

-- 方式3: 多字段去重
Entry:distinct('blog_id', 'rating'):exec()
```

### join(join_args, key, op?, val?)

内连接。

```lua
-- 方式1: 外键自动连接
Entry:join('blog_id'):exec() -- 自动连接到Blog表

-- 方式2: 手动连接模型
Entry:join(Blog, function(ctx)
  return ctx[1].blog_id .. ' = ' .. ctx[2].id
end):exec()

-- 方式3: 字符串表名连接
Entry:join('blog', 'entry.blog_id', '=', 'blog.id'):exec()

-- 方式4: 简化连接条件
Entry:join('blog', 'entry.blog_id = blog.id'):exec()
```

### inner_join(join_args, key, op?, val?)

内连接（与 join 相同）。

```lua
-- 所有调用方式与join相同
Entry:inner_join(Blog, function(ctx)
  return ctx[1].blog_id .. ' = ' .. ctx[2].id
end):exec()
```

### left_join(join_args, key, op?, val?)

左连接。

```lua
-- 方式1: 左连接模型
Blog:left_join(Entry, function(ctx)
  return ctx[1].id .. ' = ' .. ctx[2].blog_id
end):exec()

-- 方式2: 左连接表名
Blog:left_join('entry', 'blog.id = entry.blog_id'):exec()
```

### right_join(join_args, key, op?, val?)

右连接。

```lua
-- 方式1: 右连接模型
Blog:right_join(Entry, function(ctx)
  return ctx[1].id .. ' = ' .. ctx[2].blog_id
end):exec()
```

### full_join(join_args, key, op?, val?)

全连接。

```lua
-- 方式1: 全连接
Blog:full_join(Entry, function(ctx)
  return ctx[1].id .. ' = ' .. ctx[2].blog_id
end):exec()
```

### cross_join(join_args, key, op?, val?)

交叉连接。

```lua
-- 方式1: 交叉连接
Blog:cross_join('entry'):exec()
```

### annotate(kwargs)

添加聚合字段。

```lua
-- 方式1: 基本聚合
local Count = Model.Count
Blog:annotate({entry_count = Count('entry')}):exec()

-- 方式2: 多种聚合函数
local Sum, Avg, Max, Min = Model.Sum, Model.Avg, Model.Max, Model.Min
Entry:annotate({
  total_comments = Sum('number_of_comments'),
  avg_rating = Avg('rating'),
  max_rating = Max('rating'),
  min_rating = Min('rating')
}):exec()

-- 方式3: F表达式聚合
local F = Model.F
Entry:annotate({
  total_interactions = F('number_of_comments') + F('number_of_pingbacks')
}):exec()

-- 方式4: 带过滤的聚合
Entry:annotate({
  high_rating_count = Count({column = 'id', filter = 'rating > 4'})
}):exec()
```

### from(...)

指定 FROM 子句。

```lua
-- 方式1: 单表
Blog:from('blog'):exec()

-- 方式2: 多表
Blog:from('blog', 'entry'):exec()

-- 方式3: 子查询
local subquery = Entry:select('blog_id'):where({rating__gt = 4})
Blog:from('(' .. subquery:statement() .. ') as high_rated'):exec()
```

### using(...)

指定 USING 子句（用于 DELETE）。

```lua
-- 方式1: DELETE with USING
Blog:delete():using('entry'):where('blog.id = entry.blog_id AND entry.rating < 2'):exec()
```

---

## 3. 数据操作方法 (CRUD)

### insert(rows, columns?)

插入数据。

```lua
-- 方式1: 插入单条记录
Blog:insert({name = 'New Blog', tagline = 'New tagline'}):exec()

-- 方式2: 插入多条记录
Blog:insert({
  {name = 'Blog 1', tagline = 'Tagline 1'},
  {name = 'Blog 2', tagline = 'Tagline 2'}
}):exec()

-- 方式3: 指定列插入
Blog:insert({name = 'Blog 3'}, {'name'}):exec()

-- 方式4: 从子查询插入
local subquery = BlogBin:select('name', 'tagline'):where({note = 'approved'})
Blog:insert(subquery):exec()

-- 方式5: 带RETURNING的插入
Blog:insert({name = 'Blog with ID'}):returning('*'):exec()
```

### update(row, columns?)

更新数据。

```lua
-- 方式1: 更新记录
Blog:where({name = 'Old Name'}):update({tagline = 'Updated tagline'}):exec()

-- 方式2: 指定列更新
Blog:where({id = 1}):update({tagline = 'New tagline'}, {'tagline'}):exec()

-- 方式3: 使用F表达式更新
local F = Model.F
Entry:where({id = 1}):update({
  number_of_comments = F('number_of_comments') + 1
}):exec()

-- 方式4: 从子查询更新
local subquery = Entry:select('AVG(rating)'):where({blog_id = 1})
Blog:where({id = 1}):update('rating = (' .. subquery:statement() .. ')'):exec()

-- 方式5: 带RETURNING的更新
Blog:where({id = 1}):update({tagline = 'Updated'}):returning('*'):exec()
```

### delete(cond?, op?, dval?)

删除数据。

```lua
-- 方式1: 无条件删除（删除所有）
Blog:delete():exec()

-- 方式2: 带条件删除
Blog:delete({name = 'Test Blog'}):exec()

-- 方式3: 先设置条件再删除
Blog:where({tagline__contains = 'test'}):delete():exec()

-- 方式4: 复杂条件删除
Blog:delete('name', 'LIKE', '%test%'):exec()

-- 方式5: 带RETURNING的删除
Blog:delete({id = 1}):returning('*'):exec()
```

### upsert(rows, key?, columns?)

插入或更新（PostgreSQL 的 INSERT ON CONFLICT）。

```lua
-- 方式1: 基本upsert
Blog:upsert({name = 'Unique Blog', tagline = 'New or Updated'}):exec()

-- 方式2: 指定唯一键
Blog:upsert({
  {name = 'Blog 1', tagline = 'Tagline 1'},
  {name = 'Blog 2', tagline = 'Tagline 2'}
}, 'name'):exec()

-- 方式3: 多列唯一键
Entry:upsert({
  blog_id = 1,
  headline = 'Test',
  rating = 5
}, {'blog_id', 'headline'}):exec()

-- 方式4: 指定更新列
Blog:upsert({name = 'Test', tagline = 'Updated'}, 'name', {'tagline'}):exec()

-- 方式5: 从子查询upsert
local subquery = BlogBin:select('name', 'tagline'):where({approved = true})
Blog:upsert(subquery, 'name'):exec()
```

### merge(rows, key?, columns?)

合并操作（使用 CTE 的 upsert 模式）。

```lua
-- 方式1: 基本merge
Blog:merge({
  {name = 'Blog 1', tagline = 'Merged 1'},
  {name = 'Blog 2', tagline = 'Merged 2'}
}):exec()

-- 方式2: 指定合并键
Blog:merge({
  {name = 'Unique', tagline = 'Merged'}
}, 'name'):exec()

-- 方式3: 指定列
Blog:merge({
  {name = 'Test', tagline = 'Merged', extra = 'ignored'}
}, 'name', {'name', 'tagline'}):exec()
```

### updates(rows, key?, columns?)

批量更新。

```lua
-- 方式1: 批量更新多行
Blog:updates({
  {name = 'First Blog', tagline = 'Updated 1'},
  {name = 'Second Blog', tagline = 'Updated 2'}
}):exec()

-- 方式2: 指定更新键
Blog:updates({
  {id = 1, tagline = 'New tagline 1'},
  {id = 2, tagline = 'New tagline 2'}
}, 'id'):exec()

-- 方式3: 指定更新列
Blog:updates({
  {name = 'Blog 1', tagline = 'Updated'}
}, 'name', {'tagline'}):exec()
```

### align(rows, key?, columns?)

对齐操作（upsert + 删除不匹配的行）。

```lua
-- 方式1: 基本对齐
Blog:align({
  {name = 'Keep 1', tagline = 'Kept'},
  {name = 'Keep 2', tagline = 'Kept'}
}):exec() -- 只保留这两行，删除其他行

-- 方式2: 指定对齐键
Entry:align({
  {blog_id = 1, headline = 'Keep 1'},
  {blog_id = 1, headline = 'Keep 2'}
}, 'headline'):exec()
```

### gets(keys, columns?)

批量获取指定键的记录。

```lua
-- 方式1: 获取指定ID的记录
Blog:gets({{id = 1}, {id = 2}}):exec()

-- 方式2: 获取复合键记录
Entry:gets({
  {blog_id = 1, headline = 'First'},
  {blog_id = 2, headline = 'Second'}
}):exec()

-- 方式3: 指定获取列
Blog:gets({{name = 'First'}, {name = 'Second'}}, {'name'}):exec()
```

### merge_gets(rows, key, columns?)

合并获取（使用 CTE VALUES + RIGHT JOIN）。

```lua
-- 方式1: 基本合并获取
Blog:select('name'):merge_gets({
  {id = 1, name = 'Expected 1'},
  {id = 2, name = 'Expected 2'}
}, 'id'):exec()

-- 方式2: 指定列
Blog:merge_gets({
  {name = 'Blog 1', tagline = 'Tag 1'},
  {name = 'Blog 2', tagline = 'Tag 2'}
}, 'name', {'name', 'tagline'}):exec()
```

---

## 4. 查询执行方法

### exec()

执行查询并返回模型实例。

```lua
-- 方式1: 基本执行
local blogs = Blog:select('*'):exec()

-- 方式2: 链式调用执行
local results = Blog:where({name__contains = 'test'}):order('name'):exec()
```

### execr()

执行查询并返回原始数据。

```lua
-- 方式1: 返回原始数据
local raw_data = Blog:select('*'):execr()

-- 方式2: 等价于raw():exec()
local raw_data2 = Blog:select('*'):raw():exec()
```

### exec_statement(statement)

执行 SQL 语句。

```lua
-- 方式1: 执行自定义SQL
local results = Blog:exec_statement("SELECT * FROM blog WHERE name LIKE '%test%'")

-- 方式2: 执行复杂查询
local custom_sql = [[
  WITH blog_stats AS (
    SELECT blog_id, COUNT(*) as entry_count
    FROM entry GROUP BY blog_id
  )
  SELECT b.*, bs.entry_count
  FROM blog b
  LEFT JOIN blog_stats bs ON b.id = bs.blog_id
]]
local results = Blog:exec_statement(custom_sql)
```

### get(cond?, op?, dval?)

获取单条记录。

```lua
-- 方式1: 无条件获取（获取第一条）
local blog = Blog:get()

-- 方式2: 条件获取
local blog = Blog:get({name = 'First Blog'})

-- 方式3: 字段条件获取
local blog = Blog:get('name', 'First Blog')

-- 方式4: 操作符条件获取
local blog = Blog:get('id', '>', 1)

-- 方式5: 复杂条件获取
local entry = Entry:where({rating__gt = 4}):get()
```

### try_get(cond?, op?, dval?)

尝试获取单条记录，找不到返回 false。

```lua
-- 方式1: 尝试获取
local blog = Blog:try_get({name = 'Maybe Exists'})
if blog then
  -- 找到了
else
  -- 没找到
end

-- 方式2: 各种条件方式（与get相同）
local blog = Blog:try_get('name', 'Test')
local blog = Blog:try_get('id', '>', 100)
```

### count(cond?, op?, dval?)

计数查询。

```lua
-- 方式1: 总数统计
local total = Blog:count()

-- 方式2: 条件统计
local count = Blog:count({tagline__contains = 'test'})

-- 方式3: 字段条件统计
local count = Entry:count('rating', '>', 4)

-- 方式4: 复杂条件统计
local count = Entry:where({pub_date__year = 2023}):count()
```

### exists()

检查是否存在记录。

```lua
-- 方式1: 检查是否有记录
local has_blogs = Blog:exists()

-- 方式2: 条件存在检查
local has_test_blogs = Blog:where({name__contains = 'test'}):exists()
```

### flat(col?)

扁平化结果。

```lua
-- 方式1: 扁平化所有字段
local flat_data = Blog:select('name'):flat()

-- 方式2: 扁平化指定列
local names = Blog:flat('name')

-- 方式3: 配合其他操作
local high_ratings = Entry:where({rating__gt = 4}):flat('rating')
```

### as_set()

将结果转换为集合。

```lua
-- 方式1: 转换为集合
local name_set = Blog:select('name'):as_set()

-- 方式2: 用于去重和集合操作
local unique_ratings = Entry:select('rating'):as_set()
```

---

## 5. 查询修饰方法

### returning(a, b?, ...)

指定 RETURNING 子句。

```lua
-- 方式1: 返回单个字段
Blog:insert({name = 'New'}):returning('id'):exec()

-- 方式2: 返回多个字段
Blog:insert({name = 'New'}):returning('id', 'name'):exec()

-- 方式3: 返回所有字段
Blog:insert({name = 'New'}):returning('*'):exec()

-- 方式4: 使用字段数组
Blog:update({tagline = 'Updated'}):returning({'id', 'name', 'tagline'}):exec()

-- 方式5: 配合DELETE使用
Blog:delete({id = 1}):returning('name'):exec()
```

### returning_literal(a, b?, ...)

返回字面值。

```lua
-- 方式1: 返回字面值
Blog:insert({name = 'New'}):returning_literal('SUCCESS'):exec()

-- 方式2: 返回多个字面值
Blog:update({tagline = 'Updated'}):returning_literal(1, 'UPDATED', true):exec()
```

### raw(is_raw?)

设置返回原始数据。

```lua
-- 方式1: 启用原始模式
Blog:select('*'):raw():exec()

-- 方式2: 显式设置
Blog:select('*'):raw(true):exec()

-- 方式3: 禁用原始模式
Blog:select('*'):raw(false):exec()
```

### compact()

设置紧凑模式。

```lua
-- 方式1: 启用紧凑模式
Blog:select('*'):compact():exec()

-- 方式2: 配合其他方法
Blog:select('name'):compact():flat()
```

### skip_validate(bool?)

跳过验证。

```lua
-- 方式1: 跳过验证
Blog:skip_validate():insert({name = 'Skip Validation'}):exec()

-- 方式2: 显式设置
Blog:skip_validate(true):update({tagline = 'No Validation'}):exec()

-- 方式3: 恢复验证
Blog:skip_validate(false):insert({name = 'With Validation'}):exec()
```

### return_all()

返回所有结果。

```lua
-- 方式1: 返回所有结果（包括中间结果）
Blog:prepend("SET LOCAL work_mem = '16MB'"):select('*'):return_all():exec()
```

---

## 6. 高级查询方法

### with(name, token)

添加 CTE（公用表表达式）。

```lua
-- 方式1: 基本CTE
local subquery = Entry:select('blog_id', 'COUNT(*) as entry_count'):group('blog_id')
Blog:with('blog_stats', subquery):select('*'):join('blog_stats', 'blog.id = blog_stats.blog_id'):exec()

-- 方式2: 字符串CTE
Blog:with('numbers', '(VALUES (1), (2), (3))'):select('*'):exec()

-- 方式3: 多个CTE
Blog:with('first_cte', Entry:select('blog_id'):limit(1))
    :with('second_cte', Blog:select('name'):limit(1))
    :select('*'):exec()
```

### with_recursive(name, token)

添加递归 CTE。

```lua
-- 方式1: 递归查询
local recursive_query = [[
  SELECT id, name, parent_id, 1 as level FROM categories WHERE parent_id IS NULL
  UNION ALL
  SELECT c.id, c.name, c.parent_id, r.level + 1
  FROM categories c
  JOIN category_tree r ON c.parent_id = r.id
]]
Blog:with_recursive('category_tree', recursive_query):from('category_tree'):exec()
```

### with_values(name, rows)

使用 VALUES 创建 CTE。

```lua
-- 方式1: 创建临时数据
Blog:with_values('test_data', {
  {name = 'Test 1', value = 1},
  {name = 'Test 2', value = 2}
}):from('test_data'):exec()
```

### union(other_sql)

联合查询。

```lua
-- 方式1: 基本联合
local query1 = Blog:select('name'):where({tagline__contains = 'test'})
local query2 = Blog:select('name'):where({name__startswith = 'Test'})
query1:union(query2):exec()
```

### union_all(other_sql)

全联合查询。

```lua
-- 方式1: 全联合（包含重复）
local query1 = Blog:select('name')
local query2 = BlogBin:select('name')
query1:union_all(query2):exec()
```

### except(other_sql)

差集查询。

```lua
-- 方式1: 差集
local all_blogs = Blog:select('name')
local test_blogs = Blog:select('name'):where({name__contains = 'test'})
all_blogs:except(test_blogs):exec()
```

### except_all(other_sql)

全差集查询。

```lua
-- 方式1: 全差集
local query1 = Blog:select('name')
local query2 = Blog:select('name'):where({id__gt = 10})
query1:except_all(query2):exec()
```

### intersect(other_sql)

交集查询。

```lua
-- 方式1: 交集
local popular_blogs = Blog:select('name'):where({id__in = {1, 2, 3}})
local recent_blogs = Blog:select('name'):where({id__in = {2, 3, 4}})
popular_blogs:intersect(recent_blogs):exec()
```

### intersect_all(other_sql)

全交集查询。

```lua
-- 方式1: 全交集
local query1 = Blog:select('name')
local query2 = Blog:select('name'):where({tagline__isnull = false})
query1:intersect_all(query2):exec()
```

---

## 7. 关联查询方法

### select_related(fk_name, select_names, more_name?, ...)

选择关联对象。

```lua
-- 方式1: 选择外键对象
Entry:select_related('blog_id'):exec()

-- 方式2: 选择外键的特定字段
Entry:select_related('blog_id', 'name'):exec()

-- 方式3: 选择外键的多个字段
Entry:select_related('blog_id', 'name', 'tagline'):exec()

-- 方式4: 选择外键的所有字段
Entry:select_related('blog_id', '*'):exec()

-- 方式5: 选择字段数组
Entry:select_related('blog_id', {'name', 'tagline'}):exec()

-- 方式6: 深度关联
Entry:select_related('blog_id', 'author__name'):exec()
```

### select_related_labels(names?)

选择外键标签字段。

```lua
-- 方式1: 选择所有外键标签
Entry:select_related_labels():exec()

-- 方式2: 选择指定字段的外键标签
Entry:select_related_labels({'blog_id'}):exec()
```

### where_recursive(name, value, select_names?)

递归查询（自引用外键）。

```lua
-- 假设有自引用的Category模型
-- 方式1: 基本递归查询
Category:where_recursive('parent_id', 1):exec()

-- 方式2: 指定选择字段
Category:where_recursive('parent_id', 1, {'name', 'level'}):exec()
```

---

## 8. 数据验证和模型操作方法

### create(input)

创建记录（插入并返回模型实例）。

```lua
-- 方式1: 创建记录
local blog = Blog:create({name = 'New Blog', tagline = 'Created blog'})
```

### save(input, names?, key?)

保存记录（自动判断插入或更新）。

```lua
-- 方式1: 新记录保存（插入）
local new_blog = Blog:save({name = 'Saved Blog', tagline = 'Saved'})

-- 方式2: 已存在记录保存（更新）
local existing_blog = Blog:save({id = 1, tagline = 'Updated by save'})

-- 方式3: 指定字段保存
local blog = Blog:save({name = 'Test', tagline = 'Test'}, {'tagline'})

-- 方式4: 指定唯一键
local blog = Blog:save({name = 'Update by name', tagline = 'New'}, nil, 'name')
```

### save_create(input, names?, key?)

强制创建保存。

```lua
-- 方式1: 创建保存
local blog = Blog:save_create({name = 'Force Create', tagline = 'Created'})

-- 方式2: 指定字段创建
local blog = Blog:save_create({name = 'Test', tagline = 'Test'}, {'name', 'tagline'})

-- 方式3: 指定返回键
local blog = Blog:save_create({name = 'Test'}, nil, 'name')
```

### save_update(input, names?, key?)

强制更新保存。

```lua
-- 方式1: 更新保存
local blog = Blog:save_update({id = 1, tagline = 'Force Updated'})

-- 方式2: 指定字段更新
local blog = Blog:save_update({id = 1, tagline = 'Updated'}, {'tagline'})

-- 方式3: 指定唯一键更新
local blog = Blog:save_update({name = 'First Blog', tagline = 'Updated'}, nil, 'name')
```

### validate(input, names?, key?)

验证数据。

```lua
-- 方式1: 验证数据
local validated = Blog:validate({name = 'Test Blog', tagline = 'Test'})

-- 方式2: 指定验证字段
local validated = Blog:validate({name = 'Test', extra = 'ignored'}, {'name'})

-- 方式3: 指定验证键
local validated = Blog:validate({id = 1, tagline = 'Test'}, nil, 'id')
```

### validate_create(input, names?)

验证创建数据。

```lua
-- 方式1: 验证创建
local validated = Blog:validate_create({name = 'New Blog', tagline = 'New'})

-- 方式2: 指定验证字段
local validated = Blog:validate_create({name = 'Test'}, {'name'})
```

### validate_update(input, names?)

验证更新数据。

```lua
-- 方式1: 验证更新
local validated = Blog:validate_update({tagline = 'Updated'})

-- 方式2: 指定验证字段
local validated = Blog:validate_update({name = 'New Name', tagline = 'New'}, {'tagline'})
```

### load(data)

加载原始数据为模型实例。

```lua
-- 方式1: 加载数据
local raw_data = {id = 1, name = 'Test Blog', tagline = 'Test'}
local blog_instance = Blog:load(raw_data)
```

### create_record(data)

创建记录实例。

```lua
-- 方式1: 创建记录实例
local record = Blog:create_record({id = 1, name = 'Test', tagline = 'Test'})
```

---

## 9. 工具和辅助方法

### copy()

复制查询构建器。

```lua
-- 方式1: 复制查询
local base_query = Blog:where({tagline__isnull = false})
local query1 = base_query:copy():where({name__startswith = 'A'})
local query2 = base_query:copy():where({name__startswith = 'B'})
```

### clear()

清除查询构建器。

```lua
-- 方式1: 清除查询
local query = Blog:select('name'):where({id = 1})
query:clear() -- 清除所有条件，保留模型和表名
query:select('*'):exec()
```

### as(table_alias)

设置表别名。

```lua
-- 方式1: 设置别名
Blog:as('b'):select('b.name'):exec()

-- 方式2: 在JOIN中使用别名
Blog:as('b1'):join(Blog:as('b2'), 'b1.id != b2.id'):exec()
```

### statement()

获取 SQL 语句。

```lua
-- 方式1: 获取SQL语句
local sql = Blog:select('*'):where({name = 'test'}):statement()
print(sql) -- 打印生成的SQL
```

### get_table()

获取表名（含别名）。

```lua
-- 方式1: 获取表名
local table_name = Blog:get_table() -- "blog"

-- 方式2: 含别名的表名
local table_name = Blog:as('b'):get_table() -- "blog b"
```

### prepend(...)

在 SQL 前面添加语句。

```lua
-- 方式1: 添加前置语句
Blog:prepend("SET LOCAL work_mem = '16MB'"):select('*'):exec()

-- 方式2: 添加多个前置语句
Blog:prepend("BEGIN", "SET TRANSACTION ISOLATION LEVEL READ COMMITTED"):select('*'):exec()
```

### append(...)

在 SQL 后面添加语句。

```lua
-- 方式1: 添加后置语句
Blog:select('*'):append("COMMIT"):exec()

-- 方式2: 添加多个后置语句
Blog:select('*'):append("ANALYZE blog", "COMMIT"):exec()
```

---

## 10. 字段操作和表达式

### increase(name, amount?)

字段自增。

```lua
-- 方式1: 单字段自增1
Entry:where({id = 1}):increase('number_of_comments'):exec()

-- 方式2: 单字段自增指定数量
Entry:where({id = 1}):increase('number_of_comments', 5):exec()

-- 方式3: 多字段自增
Entry:where({id = 1}):increase({
  number_of_comments = 2,
  number_of_pingbacks = 1
}):exec()
```

### decrease(name, amount?)

字段自减。

```lua
-- 方式1: 单字段自减1
Entry:where({id = 1}):decrease('number_of_comments'):exec()

-- 方式2: 单字段自减指定数量
Entry:where({id = 1}):decrease('number_of_comments', 3):exec()

-- 方式3: 多字段自减
Entry:where({id = 1}):decrease({
  number_of_comments = 1,
  number_of_pingbacks = 2
}):exec()
```

---

## 11. 批量操作和性能优化方法

### filter(kwargs)

过滤查询（where 的便捷方法）。

```lua
-- 方式1: 基本过滤
local blogs = Blog:filter({tagline__contains = 'test'})

-- 等价于
local blogs = Blog:where({tagline__contains = 'test'}):exec()
```

### meta_query(data)

元查询（配置式查询）。

```lua
-- 方式1: 配置式查询
local results = Blog:meta_query({
  select = {'name', 'tagline'},
  where = {tagline__contains = 'test'},
  order = {'-name'},
  limit = 10
})

-- 方式2: 包含聚合的元查询
local results = Entry:meta_query({
  select = {'blog_id'},
  where = {rating__gt = 4},
  group = {'blog_id'},
  having = {rating__avg__gt = 4.5},
  order = {'blog_id'}
})
```

### get_or_create(params, defaults?, columns?)

获取或创建记录。

```lua
-- 方式1: 基本获取或创建
local blog, created = Blog:get_or_create(
  {name = 'Maybe Exists'},
  {tagline = 'Default tagline'}
)

-- 方式2: 指定返回列
local blog, created = Blog:get_or_create(
  {name = 'Test'},
  {tagline = 'Default'},
  {'id', 'name'}
)

-- created 为 true 表示新创建，false 表示已存在
```

---

## 12. 已弃用方法

### commit(bool)

设置提交模式（已弃用）。

```lua
-- 已弃用方法
Blog:commit(true):select('*'):exec()
```

### join_type(jtype)

设置连接类型（已弃用）。

```lua
-- 已弃用方法，直接使用具体的join方法
Blog:join_type('LEFT'):join(Entry, 'condition'):exec()

-- 推荐使用
Blog:left_join(Entry, 'condition'):exec()
```

---

## 使用示例综合演示

### 复杂查询示例

```lua
-- 查询评分高于平均分的文章，包含博客信息和统计数据
local high_rated_entries = Entry
  :select('headline', 'rating', 'pub_date')
  :select_related('blog_id', 'name')
  :annotate({
    blog_avg_rating = Avg('rating'),
    comment_rating_ratio = F('number_of_comments') / F('rating')
  })
  :where('rating > (SELECT AVG(rating) FROM entry)')
  :where({pub_date__year = 2023})
  :order('-rating', 'pub_date')
  :limit(10)
  :exec()

-- 批量操作示例
local batch_blogs = {
  {name = 'Batch Blog 1', tagline = 'First batch'},
  {name = 'Batch Blog 2', tagline = 'Second batch'},
  {name = 'Batch Blog 3', tagline = 'Third batch'}
}

-- 批量插入
Blog:insert(batch_blogs):returning('*'):exec()

-- 批量更新（根据name更新tagline）
Blog:updates({
  {name = 'Batch Blog 1', tagline = 'Updated first'},
  {name = 'Batch Blog 2', tagline = 'Updated second'}
}, 'name'):exec()

-- 复杂CTE查询
local blog_stats = Blog
  :with('entry_stats', Entry
    :select('blog_id')
    :annotate({
      entry_count = Count('*'),
      avg_rating = Avg('rating'),
      total_comments = Sum('number_of_comments')
    })
    :group('blog_id')
  )
  :select('name', 'tagline')
  :select('entry_stats.entry_count', 'entry_stats.avg_rating', 'entry_stats.total_comments')
  :join('entry_stats', 'blog.id = entry_stats.blog_id')
  :where('entry_stats.entry_count > 0')
  :order('-entry_stats.avg_rating')
  :exec()
```

这份文档涵盖了 model.lua 中所有公共方法的详细使用方式，每个方法都提供了多种调用方式的具体示例。通过这些示例，开发者可以快速掌握 lua-resty-model 的各种功能和用法。
