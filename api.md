# lua-resty-model API 文档

## 目录
- [Xodel类方法](#xodel类方法)
- [SQL代理方法](#sql代理方法)

## Xodel类方法

### 基础方法

#### new(attrs)
创建一个新的Xodel实例。
- 参数:
  - attrs: 可选，初始化属性表
- 返回: Xodel实例

#### create_model(options)
根据选项创建一个新的模型类。
- 参数:
  - options: 模型配置选项
    - table_name: 表名
    - class_name: 类名
    - fields: 字段定义
    - field_names: 字段名列表
    - admin: 管理选项
    - label: 标签
    - extends: 继承的模型
    - mixins: 混入的模型列表
    - abstract: 是否为抽象模型
    - auto_primary_key: 是否自动生成主键
    - primary_key: 主键名
    - unique_together: 联合唯一约束
    - db_options: 数据库选项
    - referenced_label_column: 引用标签列
    - preload: 是否预加载
- 返回: 新的模型类

#### make_field_from_json(options)
从JSON配置创建字段。
- 参数:
  - options: 字段配置选项
    - name: 字段名
    - type: 字段类型
    - label: 字段标签
    - 其他字段特定选项
- 返回: 字段实例

#### create_sql()
创建一个新的SQL构建器实例。
- 返回: Sql实例

#### mix(...)
混合多个模型类。
- 参数:
  - ...: 要混合的模型类列表
- 返回: 新的混合模型类

### 数据操作方法

#### save(input, names, key)
保存记录(自动判断是创建还是更新)。
- 参数:
  - input: 要保存的数据
  - names: 可选，要保存的字段名列表
  - key: 可选，用于查找记录的键
- 返回: 保存后的记录实例

#### save_create(input, names, key)
创建新记录。
- 参数:
  - input: 要创建的数据
  - names: 可选，要创建的字段名列表
  - key: 可选，返回的键
- 返回: 创建的记录实例

#### save_update(input, names, key)
更新已有记录。
- 参数:
  - input: 要更新的数据
  - names: 可选，要更新的字段名列表
  - key: 可选，用于查找记录的键
- 返回: 更新后的记录实例

#### save_cascade_update(input, names, key)
级联更新记录。
- 参数:
  - input: 要更新的数据
  - names: 可选，要更新的字段名列表
  - key: 可选，用于查找记录的键
- 返回: 更新后的记录实例

#### get_or_create(params, defaults, columns)
获取记录，如果不存在则创建。
- 参数:
  - params: 查询参数
  - defaults: 可选，创建时的默认值
  - columns: 可选，要返回的列
- 返回: [记录实例, 是否新创建]

### 验证方法

#### validate(input, names, key)
验证数据(自动判断是创建还是更新验证)。
- 参数:
  - input: 要验证的数据
  - names: 可选，要验证的字段名列表
  - key: 可选，用于判断是创建还是更新的键
- 返回: [验证后的数据, 错误信息]

#### validate_create(input, names)
验证创建数据。
- 参数:
  - input: 要验证的数据
  - names: 可选，要验证的字段名列表
- 返回: [验证后的数据, 错误信息]

#### validate_update(input, names)
验证更新数据。
- 参数:
  - input: 要验证的数据
  - names: 可选，要验证的字段名列表
- 返回: [验证后的数据, 错误信息]

#### validate_cascade_update(input, names)
验证级联更新数据。
- 参数:
  - input: 要验证的数据
  - names: 可选，要验证的字段名列表
- 返回: [验证后的数据, 错误信息]

### 工具方法

#### load(data)
从数据库数据加载记录实例。
- 参数:
  - data: 数据库返回的原始数据
- 返回: 记录实例

#### create_record(data)
创建记录实例。
- 参数:
  - data: 记录数据
- 返回: 记录实例

#### to_json(names)
将模型转换为JSON格式。
- 参数:
  - names: 可选，要包含的字段名列表
- 返回: JSON格式的模型定义

## SQL代理方法

以下方法都是对SQL构建器的代理，可以直接在模型类上调用。

### 查询方法

#### select(...)
选择字段。
- 参数:
  - ...: 字段名列表或字段表达式
- 返回: SQL构建器实例

#### where(cond, op, dval)
添加WHERE条件。
- 参数:
  - cond: 条件表达式或条件表
  - op: 可选，操作符
  - dval: 可选，比较值
- 返回: SQL构建器实例

#### order(...)
排序。
- 参数:
  - ...: 排序字段列表
- 返回: SQL构建器实例

#### group(...)
分组。
- 参数:
  - ...: 分组字段列表
- 返回: SQL构建器实例

#### having(cond, op, dval)
添加HAVING条件。
- 参数:
  - cond: 条件表达式或条件表
  - op: 可选，操作符
  - dval: 可选，比较值
- 返回: SQL构建器实例

#### limit(n)
限制返回记录数。
- 参数:
  - n: 限制数量
- 返回: SQL构建器实例

#### offset(n)
设置偏移量。
- 参数:
  - n: 偏移量
- 返回: SQL构建器实例

### 修改方法

#### insert(rows, columns)
插入记录。
- 参数:
  - rows: 要插入的数据
  - columns: 可选，要插入的列
- 返回: SQL构建器实例

#### update(row, columns)
更新记录。
- 参数:
  - row: 要更新的数据
  - columns: 可选，要更新的列
- 返回: SQL构建器实例

#### delete(cond, op, dval)
删除记录。
- 参数:
  - cond: 可选，条件表达式或条件表
  - op: 可选，操作符
  - dval: 可选，比较值
- 返回: SQL构建器实例

### 连接方法

#### join(join_args, key, op, val)
内连接。
- 参数:
  - join_args: 连接表
  - key: 连接键
  - op: 可选，连接操作符
  - val: 可选，连接值
- 返回: SQL构建器实例

#### left_join(join_args, key, op, val)
左连接。
- 参数同join

#### right_join(join_args, key, op, val)
右连接。
- 参数同join

#### full_join(join_args, key, op, val)
全连接。
- 参数同join

### 聚合方法

#### count(cond, op, dval)
计数。
- 参数:
  - cond: 可选，条件表达式或条件表
  - op: 可选，操作符
  - dval: 可选，比较值
- 返回: 记录数量

#### exists()
检查是否存在记录。
- 返回: 布尔值

### 结果处理方法

#### exec()
执行SQL并返回结果。
- 返回: 记录列表

#### get(cond, op, dval)
获取单条记录。
- 参数:
  - cond: 可选，条件表达式或条件表
  - op: 可选，操作符
  - dval: 可选，比较值
- 返回: 记录实例

#### try_get(cond, op, dval)
尝试获取单条记录。
- 参数同get
- 返回: 记录实例或false

#### flat(col)
将结果扁平化为单列值列表。
- 参数:
  - col: 可选，要扁平化的列
- 返回: 值列表

### 其他方法

#### as(table_alias)
设置表别名。
- 参数:
  - table_alias: 别名
- 返回: SQL构建器实例

#### raw(is_raw)
设置是否返回原始结果。
- 参数:
  - is_raw: 可选，是否返回原始结果
- 返回: SQL构建器实例

#### compact()
设置返回紧凑结果。
- 返回: SQL构建器实例

#### returning(...)
设置返回字段。
- 参数:
  - ...: 返回字段列表
- 返回: SQL构建器实例

### 批量操作方法

#### merge(rows, key, columns)
合并多条记录（存在则更新，不存在则插入）。
- 参数:
  - rows: 要合并的数据列表
  - key: 用于判断记录是否存在的键
  - columns: 可选，要操作的列
- 返回: SQL构建器实例

#### upsert(rows, key, columns)
批量更新插入。
- 参数:
  - rows: 要操作的数据列表
  - key: 用于判断记录是否存在的键
  - columns: 可选，要操作的列
- 返回: SQL构建器实例

#### updates(rows, key, columns)
批量更新多条记录。
- 参数:
  - rows: 要更新的数据列表
  - key: 用于定位记录的键
  - columns: 可选，要更新的列
- 返回: SQL构建器实例

### 集合操作方法

#### union(other_sql)
UNION操作。
- 参数:
  - other_sql: 另一个SQL查询
- 返回: SQL构建器实例

#### union_all(other_sql)
UNION ALL操作。
- 参数:
  - other_sql: 另一个SQL查询
- 返回: SQL构建器实例

#### except(other_sql)
EXCEPT操作。
- 参数:
  - other_sql: 另一个SQL查询
- 返回: SQL构建器实例

#### intersect(other_sql)
INTERSECT操作。
- 参数:
  - other_sql: 另一个SQL查询
- 返回: SQL构建器实例

### 外键相关方法

#### load_fk(fk_name, select_names, ...)
加载外键关联数据。
- 参数:
  - fk_name: 外键字段名
  - select_names: 要选择的关联字段
  - ...: 更多要选择的关联字段
- 返回: SQL构建器实例

#### load_fk_labels(names)
加载外键标签字段。
- 参数:
  - names: 可选，要加载标签的字段名列表
- 返回: SQL构建器实例

### 条件构建方法

#### where_in(cols, range)
WHERE IN条件。
- 参数:
  - cols: 字段名或字段名列表
  - range: 值范围
- 返回: SQL构建器实例

#### where_not_in(cols, range)
WHERE NOT IN条件。
- 参数:
  - cols: 字段名或字段名列表
  - range: 值范围
- 返回: SQL构建器实例

#### where_null(col)
WHERE IS NULL条件。
- 参数:
  - col: 字段名
- 返回: SQL构建器实例

#### where_not_null(col)
WHERE IS NOT NULL条件。
- 参数:
  - col: 字段名
- 返回: SQL构建器实例

#### where_between(col, low, high)
WHERE BETWEEN条件。
- 参数:
  - col: 字段名
  - low: 范围下限
  - high: 范围上限
- 返回: SQL构建器实例

### WITH子句方法

#### with(name, token)
添加WITH子句。
- 参数:
  - name: CTE名称
  - token: 可选，CTE定义
- 返回: SQL构建器实例

#### with_recursive(name, token)
添加WITH RECURSIVE子句。
- 参数:
  - name: CTE名称
  - token: 可选，CTE定义
- 返回: SQL构建器实例

#### with_values(name, rows)
使用VALUES添加WITH子句。
- 参数:
  - name: CTE名称
  - rows: 值列表
- 返回: SQL构建器实例

### 递归查询方法

#### where_recursive(name, value, select_names)
递归查询。
- 参数:
  - name: 递归字段名
  - value: 起始值
  - select_names: 可选，要选择的字段
- 返回: SQL构建器实例

### 聚合函数

#### Count(column)
COUNT聚合函数。
- 参数:
  - column: 要计数的列
- 返回: 聚合函数对象

#### Sum(column)
SUM聚合函数。
- 参数:
  - column: 要求和的列
- 返回: 聚合函数对象

#### Avg(column)
AVG聚合函数。
- 参数:
  - column: 要求平均的列
- 返回: 聚合函数对象

#### Max(column)
MAX聚合函数。
- 参数:
  - column: 要求最大值的列
- 返回: 聚合函数对象

#### Min(column)
MIN聚合函数。
- 参数:
  - column: 要求最小值的列
- 返回: 聚合函数对象

### 字段表达式

#### F(column)
创建字段表达式。
- 参数:
  - column: 字段名
- 返回: 字段表达式对象

支持的运算符:
- +: 加法
- -: 减法
- *: 乘法
- /: 除法
- %: 取模
- ^: 幂运算
- ||: 字符串连接

### 逻辑表达式

#### Q(cond)
创建逻辑表达式。
- 参数:
  - cond: 条件表达式
- 返回: 逻辑表达式对象

支持的运算符:
- *: AND
- /: OR
- -: NOT

### 工具方法

#### increase(name, amount)
增加字段值。
- 参数:
  - name: 字段名
  - amount: 可选，增加量（默认为1）
- 返回: SQL构建器实例

#### decrease(name, amount)
减少字段值。
- 参数:
  - name: 字段名
  - amount: 可选，减少量（默认为1）
- 返回: SQL构建器实例

#### statement()
获取SQL语句。
- 返回: SQL语句字符串

#### skip_validate(bool)
设置是否跳过验证。
- 参数:
  - bool: 可选，是否跳过（默认为true）
- 返回: SQL构建器实例

#### return_all()
设置返回所有结果。
- 返回: SQL构建器实例

### 常量

#### NULL
表示SQL NULL值的常量。

#### DEFAULT
表示SQL DEFAULT值的常量。

## 使用示例

### 模型定义
```lua
-- 基本模型定义
local Blog = Model {
  table_name = 'blog',
  fields = {
    { "name",   maxlength = 100 },
    { "tagline" },
  }
}

-- 定义结构化JSON字段
local Resume = Model:create_model {
  fields = {
    { "start_date",  type = 'date' },
    { "end_date",    type = 'date' },
    { "company",     maxlength = 200 },
    { "position",    maxlength = 200 },
    { "description", maxlength = 200 },
  }
}

-- 使用JSON字段的模型
local Author = Model {
  table_name = 'author',
  fields = {
    { "name",   maxlength = 200 },
    { "email",  type = 'email' },
    { "age",    type = 'integer' },
    { "resume", model = Resume },  -- 结构化JSON字段
  }
}

-- 带外键关联的模型
local Entry = Model {
  table_name = 'entry',
  fields = {
    { 'blog_id',             reference = Blog, related_query_name = 'entry' },
    { 'reposted_blog_id',    reference = Blog, related_query_name = 'reposted_entry' },
    { "headline",            maxlength = 255 },
    { "body_text" },
    { "pub_date",            type = 'date' },
    { "mod_date",            type = 'date' },
    { "number_of_comments",  type = 'integer' },
    { "number_of_pingbacks", type = 'integer' },
    { "rating",              type = 'integer' },
  }
}
```

### 基础查询
```lua
-- 简单条件查询
Book:where { price = 100 }                    -- WHERE price = 100
Book:where { price__gt = 100 }               -- WHERE price > 100

-- 使用Q表达式构建复杂条件
Book:where(-Q { price__gt = 100 })           -- WHERE NOT (price > 100)
Book:where(Q { price__gt = 100 } / Q { price__lt = 200 })  -- WHERE (price > 100) OR (price < 200)
Book:where(-(Q { price__gt = 100 } / Q { price__lt = 200 }))  -- WHERE NOT ((price > 100) OR (price < 200))
```

### 外键查询
```lua
-- 基本外键查询
Entry:where { blog_id = 1 }                   -- WHERE blog_id = 1
Entry:where { blog_id__id = 1 }              -- WHERE blog_id = 1
Entry:where { blog_id__gt = 1 }              -- WHERE blog_id > 1
Entry:where { blog_id__name = 'my blog name' }  -- WHERE EXISTS (SELECT 1 FROM blog WHERE blog.id = entry.blog_id AND blog.name = 'my blog name')

-- 多级外键查询
ViewLog:where { entry_id__blog_id = 1 }
ViewLog:where { entry_id__blog_id__name = 'my blog name' }
ViewLog:where { entry_id__blog_id__name__startswith = 'my' }

-- 反向外键查询
Blog:where { entry = 1 }                      -- 查找有指定entry的blog
Blog:where { entry__rating = 1 }             -- 查找有指定rating的entry的blog
Blog:where { entry__view_log = 1 }           -- 多级反向查询
```

### 聚合和分组
```lua
-- 基本分组
Book:group_by { 'name' }

-- 分组加聚合
Book:group_by { 'name' }:annotate { price_total = Sum('price') }
Book:group_by { 'name' }:annotate { Sum('price') }  -- 自动使用price_sum作为别名

-- 分组加聚合加条件
Book:group_by { 'name' }
    :annotate { price_total = Sum('price') }
    :having { price_total__gt = 100 }
    :order_by { '-price_total' }

-- 反向关联聚合
Blog:annotate { entry_count = Count('entry') }  -- 统计每个blog的entry数量
```

### 字段表达式
```lua
-- 基本运算
Book:annotate { double_price = F('price') * 2 }
Book:annotate { price_per_page = F('price') / F('pages') }

-- 在更新中使用
Blog:update { name = F('name') .. ' updated' }  -- 字符串连接
Entry:update { rating = F('rating') + 1 }       -- 数值增加
Entry:update { headline = F('blog_id__name') }  -- 使用关联字段
```

### JSON字段操作
```lua
-- JSON字段查询
Author:where { resume__has_key = 'start_date' }
Author:where { resume__has_keys = { 'company', 'position' } }
Author:where { resume__has_any_keys = { 'start_date', 'end_date' } }
Author:where { resume__contains = { start_date = '2025-01-01' } }
Author:where { resume__contained_by = { start_date = '2025-01-01' } }

-- JSON字段内部属性查询
Author:where { resume__start_date__time = '12:00:00' }
```

### 排序和去重
```lua
-- 多字段排序
Book:order_by('author', '-pubdate')  -- 按author升序，pubdate降序

-- 去重
Book:order_by('author', '-pubdate'):distinct('author')  -- 选择不同的author
```

### 计数器操作
```lua
-- 增加计数
Entry:increase('number_of_comments')        -- 增加1
Entry:decrease('number_of_comments', 2)     -- 减少2
```

### 批量操作
```lua
-- 批量插入或更新
local books = {
  { name = "Book 1", price = 100 },
  { name = "Book 2", price = 200 }
}
Book:upsert(books, 'name')  -- 使用name作为唯一键

-- 批量合并
local authors = {
  { name = "Author 1", age = 30 },
  { name = "Author 2", age = 40 }
}
Author:merge(authors, 'name')  -- 存在则更新，不存在则插入

-- 批量更新
local updates = {
  { id = 1, price = 150 },
  { id = 2, price = 250 }
}
Book:updates(updates, 'id')  -- 批量更新多本书的价格
```

### 复杂查询组合
```lua
-- 组合多个条件和操作
Book:where { price__gt = 100 }
    :where { rating__gte = 4.0 }
    :annotate { total_value = F('price') * F('rating') }
    :order_by { '-total_value' }
    :limit(10)
    :exec()

-- 使用WITH子句
local expensive_books = Book:select('author_id')
    :where { price__gt = 100 }
    :group_by { 'author_id' }
    :having { Count('*') __gt = 2 }

Author:with('prolific_authors', expensive_books)
    :where { id = F'prolific_authors.author_id' }
    :exec()
```

### 高级查询示例

#### 子查询
```lua
-- 使用子查询查找有高评分文章的博客
local high_rated_entries = Entry:select('blog_id')
    :where { rating__gte = 4 }
    :group_by { 'blog_id' }
    :having { Count('*') __gte = 2 }

Blog:where { id = F'high_rated_entries.blog_id' }
    :with('high_rated_entries', high_rated_entries)
    :exec()

-- 查找评分高于平均值的文章
local avg_rating = Entry:select('AVG(rating)'):statement()
Entry:where { rating__gt = F(format('(%s)', avg_rating)) }:exec()
```

#### 复杂条件组合
```lua
-- 组合多个条件查询热门博客
local popular_blogs = Blog:where(
    (Q { entry__rating__gte = 4 } * Q { entry__number_of_comments__gte = 10 })
    /
    (Q { entry__number_of_pingbacks__gte = 5 } * Q { entry__pub_date__year = 2024 })
):exec()

-- 使用多个子查询
local active_authors = Author:select('id')
    :where { book__rating__gte = 4 }
    :group_by { 'id' }
    :having { Count('*') __gte = 3 }

local recent_books = Book:select('publisher_id')
    :where { pubdate__year = 2024 }
    :group_by { 'publisher_id' }
    :having { Count('*') __gte = 5 }

Publisher:with('active_authors', active_authors)
    :with('recent_books', recent_books)
    :where {
        id = F'recent_books.publisher_id',
        book__author = F'active_authors.id'
    }:exec()
```

#### 高级聚合查询
```lua
-- 计算每个出版社的统计数据
Publisher:annotate {
    book_count = Count('book'),
    total_pages = Sum('book__pages'),
    avg_price = Avg('book__price'),
    max_rating = Max('book__rating'),
    min_rating = Min('book__rating'),
    price_per_page = F('total_pages') / F('book_count')
}:where { book_count__gt = 0 }
 :order_by { '-price_per_page' }
 :exec()

-- 计算每个博客的统计信息
Blog:annotate {
    entry_count = Count('entry'),
    avg_rating = Avg('entry__rating'),
    total_comments = Sum('entry__number_of_comments'),
    engagement_score = F('total_comments') / F('entry_count')
}:where { entry_count__gt = 10 }
 :order_by { '-engagement_score' }
 :exec()
```

#### 递归查询示例
```lua
-- 假设Blog有一个parent_id字段指向父博客
-- 查找某个博客的所有子博客（包括子的子）
Blog:where_recursive('parent_id', 1, {'id', 'name', 'parent_id'})
    :order_by { 'id' }
    :exec()

-- 查找某个作者的所有推荐书籍（通过Book表的recommended_by字段）
Book:where_recursive('recommended_by', 1, {
    'id', 'name', 'recommended_by', 'rating'
}):where { rating__gte = 4 }
 :order_by { '-rating' }
 :exec()
```

#### 批量数据处理
```lua
-- 批量更新博客评分
local entries = Entry:select('blog_id')
    :annotate { avg_rating = Avg('rating') }
    :group_by { 'blog_id' }
    :having { Count('*') __gte = 5 }
    :exec()

local updates = Array(entries):map(function(e)
    return {
        id = e.blog_id,
        rating = e.avg_rating
    }
end)

Blog:updates(updates, 'id')

-- 批量合并带有JSON字段的数据
local author_updates = {
    {
        name = "Author 1",
        resume = {
            company = "Company A",
            position = "Senior Developer",
            start_date = "2024-01-01"
        }
    },
    {
        name = "Author 2",
        resume = {
            company = "Company B",
            position = "Tech Lead",
            start_date = "2024-02-01"
        }
    }
}

Author:merge(author_updates, 'name')
```

#### 复杂JOIN查询
```lua
-- 多表JOIN查询获取完整的文章信息
Entry:select {
    'id', 'headline', 'rating',
    'blog_id__name AS blog_name',
    'blog_id__tagline AS blog_tagline'
}:join(ViewLog, function(ctx)
    return format("%s = %s", ctx[1].id, ctx[2].entry_id)
end):join(Blog, function(ctx)
    return format("%s = %s", ctx[1].blog_id, ctx[3].id)
end):where {
    rating__gt = 3,
    blog_id__name__contains = "Tech"
}:group_by {
    'id', 'headline', 'rating', 'blog_name', 'blog_tagline'
}:having {
    Count('view_log.id') __gt = 100
}:order_by {
    '-rating', 'blog_name'
}:exec()
```

#### 事务性操作
```lua
-- 创建新博客同时创建第一篇文章
local blog = Blog:save_create {
    name = "New Tech Blog",
    tagline = "Latest in Technology"
}

Entry:save_create {
    blog_id = blog.id,
    headline = "Welcome to " .. blog.name,
    body_text = "This is our first post!",
    pub_date = ngx.localtime(),
    rating = 5
}

-- 更新文章同时更新相关统计
local entry = Entry:get { id = 1 }
entry.rating = entry.rating + 1
entry:save()

Blog:where { id = entry.blog_id }
    :update { total_rating = F'total_rating + 1' }
    :exec()
```

#### 高级JSON操作
```lua
-- 复杂JSON字段查询
Author:where {
    resume__company__contains = "Tech",
    resume__position__contains = "Senior",
    resume__start_date__year = 2024
}:annotate {
    experience_days = F"DATE_PART('day', NOW() - resume->>'start_date')::integer"
}:order_by {
    '-experience_days'
}:exec()

-- 更新JSON字段的特定属性
Author:where { name = "Author 1" }
    :update {
        resume = F"jsonb_set(resume, '{position}', '\"Senior Architect\"')"
    }:exec()
```