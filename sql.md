$ resty -I lib -I resty_modules/lualib -I resty_modules/site/lualib --main-conf 'env NODE_ENV;' --http-conf 'lua_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;' -I spec ngx_busted.lua -o TAP

```sql
DROP TABLE IF EXISTS store CASCADE
```

```sql
DROP TABLE IF EXISTS book CASCADE
```

```sql
DROP TABLE IF EXISTS publisher CASCADE
```

```sql
DROP TABLE IF EXISTS view_log CASCADE
```

```sql
DROP TABLE IF EXISTS entry CASCADE
```

```sql
DROP TABLE IF EXISTS author CASCADE
```

```sql
DROP TABLE IF EXISTS blog_bin CASCADE
```

```sql
DROP TABLE IF EXISTS blog CASCADE
```

```sql
CREATE TABLE blog(
  id SERIAL PRIMARY KEY NOT NULL,
  name varchar(20) NOT NULL UNIQUE,
  tagline text NOT NULL DEFAULT 'default tagline'
)
```

```sql
CREATE TABLE blog_bin(
  id SERIAL PRIMARY KEY NOT NULL,
  name varchar(256) NOT NULL DEFAULT '',
  tagline text NOT NULL DEFAULT 'default tagline',
  note text NOT NULL DEFAULT ''
)
```

```sql
CREATE TABLE author(
  id SERIAL PRIMARY KEY NOT NULL,
  name varchar(200) NOT NULL UNIQUE,
  email varchar(255) NOT NULL DEFAULT '',
  age integer ,
  resume jsonb DEFAULT '{}'
)
```

```sql
CREATE TABLE entry(
  id SERIAL PRIMARY KEY NOT NULL,
  blog_id integer REFERENCES "blog" ("id") ON DELETE CASCADE ON UPDATE CASCADE ,
  reposted_blog_id integer REFERENCES "blog" ("id") ON DELETE CASCADE ON UPDATE CASCADE ,
  headline varchar(255) NOT NULL DEFAULT '',
  body_text text NOT NULL DEFAULT '',
  pub_date date ,
  mod_date date ,
  number_of_comments integer ,
  number_of_pingbacks integer ,
  rating integer 
)
```

```sql
CREATE TABLE view_log(
  id SERIAL PRIMARY KEY NOT NULL,
  entry_id integer REFERENCES "entry" ("id") ON DELETE CASCADE ON UPDATE CASCADE ,
  ctime timestamp(0) WITH TIME ZONE 
)
```

```sql
CREATE TABLE publisher(
  id SERIAL PRIMARY KEY NOT NULL,
  name varchar(300) NOT NULL DEFAULT ''
)
```

```sql
CREATE TABLE book(
  id SERIAL PRIMARY KEY NOT NULL,
  name varchar(300) NOT NULL DEFAULT '',
  pages integer ,
  price float ,
  rating float ,
  author integer REFERENCES "author" ("id") ON DELETE CASCADE ON UPDATE CASCADE ,
  publisher_id integer REFERENCES "publisher" ("id") ON DELETE CASCADE ON UPDATE CASCADE ,
  pubdate date 
)
```

```sql
CREATE TABLE store(
  id SERIAL PRIMARY KEY NOT NULL,
  ctime timestamp(0) WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  utime timestamp(0) WITH TIME ZONE ,
  name varchar(300) NOT NULL DEFAULT ''
)
```

```sql
INSERT INTO
  blog AS T (name, tagline)
VALUES
  ('First Blog', 'Welcome to my blog')
```

```sql
INSERT INTO
  blog AS T (name, tagline)
VALUES
  ('Second Blog', 'Another interesting blog')
```

```sql
INSERT INTO
  author AS T (name, email, age, resume)
VALUES
  (
    'John Doe',
    'john@example.com',
    30,
    '[{"start_date":"2015-01-01","end_date":"2020-01-01","company":"CompanyA","position":"Developer","description":"Workedonvariousprojects."}]'
  )
```

```sql
INSERT INTO
  author AS T (name, email, age, resume)
VALUES
  (
    'Jane Smith',
    'jane@example.com',
    28,
    '[{"start_date":"2016-01-01","end_date":"2021-01-01","company":"CompanyB","position":"Designer","description":"Designeduserinterfaces."}]'
  )
```

```sql
INSERT INTO
  entry AS T (
    blog_id,
    reposted_blog_id,
    headline,
    body_text,
    pub_date,
    mod_date,
    number_of_comments,
    number_of_pingbacks,
    rating
  )
VALUES
  (
    1,
    DEFAULT,
    'First Entry',
    'This is the first entry in my blog.',
    '2023-01-01',
    '2023-01-02',
    5,
    2,
    4
  )
```

```sql
INSERT INTO
  entry AS T (
    blog_id,
    reposted_blog_id,
    headline,
    body_text,
    pub_date,
    mod_date,
    number_of_comments,
    number_of_pingbacks,
    rating
  )
VALUES
  (
    2,
    DEFAULT,
    'Second Entry',
    'This is the second entry in another blog.',
    '2023-01-03',
    '2023-01-04',
    3,
    1,
    5
  )
```

```sql
INSERT INTO
  entry AS T (
    blog_id,
    reposted_blog_id,
    headline,
    body_text,
    pub_date,
    mod_date,
    number_of_comments,
    number_of_pingbacks,
    rating
  )
VALUES
  (
    1,
    DEFAULT,
    'Third Entry',
    'This is the third entry in my blog.',
    '2023-01-01',
    '2023-01-02',
    5,
    2,
    4
  )
```

```sql
INSERT INTO
  view_log AS T (entry_id, ctime)
VALUES
  (1, '2023-01-01 10:00:00')
```

```sql
INSERT INTO
  view_log AS T (entry_id, ctime)
VALUES
  (2, '2023-01-03 12:00:00')
```

```sql
INSERT INTO
  publisher AS T (name)
VALUES
  ('PublisherA')
```

```sql
INSERT INTO
  publisher AS T (name)
VALUES
  ('PublisherB')
```

```sql
INSERT INTO book AS T (name, pages, price, rating, author
, publisher_id, pubdate) VALUES ('Book One', 300, 29.99, 4.5, 1, 1, '2022-01-01')
```

```sql
INSERT INTO
  book AS T (
    name,
    pages,
    price,
    rating,
    author,
    publisher_id,
    pubdate
  )
VALUES
  ('Book Two', 250, 19.99, 4, 2, 2, '2022-02-01')
```

```sql
INSERT INTO
  store AS T (name)
VALUES
  ('BookStoreA'),
  ('BookStoreB')
```

# Model:create_model mixins: unique被混合的模型被覆盖
# Xodel:select(a:(fun(ctx:table):string|table)|DBValue, b?:DBValue, ...:DBValue)
## select单个字段
```lua
      Blog:select('name'):where{id=1}:exec()
    
```

```sql
SELECT
  T.name
FROM
  blog T
WHERE
  T.id = 1
```

```js
[
  {
    name: "First Blog",
  },
]
```

ok 1 - Xodel:select(a:(fun(ctx:table):string|table)|DBValue, b?:DBValue, ...:DBValue) select单个字段
## select多个字段
```lua
      Blog:select('name', 'tagline'):where{id=1}:exec()
    
```

```sql
SELECT
  T.name,
  T.tagline
FROM
  blog T
WHERE
  T.id = 1
```

```js
[
  {
    name   : "First Blog",
    tagline: "Welcome to my blog",
  },
]
```

ok 2 - Xodel:select(a:(fun(ctx:table):string|table)|DBValue, b?:DBValue, ...:DBValue) select多个字段
## select多个字段,使用table和vararg等效
```lua
      Blog:select{'name', 'tagline'}:where{id=1}:statement()
    
```

```js
"SELECT T.name, T.tagline FROM blog T WHERE T.id = 1"
```

```sql
SELECT
  T.name,
  T.tagline
FROM
  blog T
WHERE
  T.id = 1
```

```lua
      Blog:select('name', 'tagline'):where{id=1}:statement()
    
```

```js
"SELECT T.name, T.tagline FROM blog T WHERE T.id = 1"
```

```sql
SELECT
  T.name,
  T.tagline
FROM
  blog T
WHERE
  T.id = 1
```

ok 3 - Xodel:select(a:(fun(ctx:table):string|table)|DBValue, b?:DBValue, ...:DBValue) select多个字段,使用table和vararg等效
## select literal without alias
```lua
      Blog:select_literal('XXX'):select{'name'}:where{id=1}:exec()
    
```

```sql
SELECT
  'XXX',
  T.name
FROM
  blog T
WHERE
  T.id = 1
```

```js
[
  {
    "?column?": "XXX",
    name      : "First Blog",
  },
]
```

ok 4 - Xodel:select(a:(fun(ctx:table):string|table)|DBValue, b?:DBValue, ...:DBValue) select literal without alias
## select literal as
```lua
      Blog:select_literal_as{['XXX YYY'] = 'blog_name'}:select{'id'}:where{id=1}:exec()
    
```

```sql
SELECT
  'XXX YYY' AS blog_name,
  T.id
FROM
  blog T
WHERE
  T.id = 1
```

```js
[
  {
    blog_name: "XXX YYY",
    id       : 1,
  },
]
```

ok 5 - Xodel:select(a:(fun(ctx:table):string|table)|DBValue, b?:DBValue, ...:DBValue) select literal as
## select literal as
```lua
      Blog:select_literal_as{XXX_YYY = 'blog_name'}:select{'id'}:where{id=2}:exec()
    
```

```sql
SELECT
  'XXX_YYY' AS blog_name,
  T.id
FROM
  blog T
WHERE
  T.id = 2
```

```js
[
  {
    blog_name: "XXX_YYY",
    id       : 2,
  },
]
```

ok 6 - Xodel:select(a:(fun(ctx:table):string|table)|DBValue, b?:DBValue, ...:DBValue) select literal as
## select外键
```lua
      Book:select('name', 'author__name'):where{id=1}:exec()
    
```

```sql
SELECT
  T.name,
  T1.name AS author__name
FROM
  book T
  INNER JOIN author T1 ON (T.author = T1.id)
WHERE
  T.id = 1
```

```js
[
  {
    author__name: "John Doe",
    name        : "Book One",
  },
]
```

ok 7 - Xodel:select(a:(fun(ctx:table):string|table)|DBValue, b?:DBValue, ...:DBValue) select外键
## select as外键
```lua
      Book:select_as{name = 'book_name', author__name = 'author_name'}:where{id=1}:exec()
    
```

```sql
SELECT
  T.name AS book_name,
  T1.name AS author_name
FROM
  book T
  INNER JOIN author T1 ON (T.author = T1.id)
WHERE
  T.id = 1
```

```js
[
  {
    author_name: "John Doe",
    book_name  : "Book One",
  },
]
```

ok 8 - Xodel:select(a:(fun(ctx:table):string|table)|DBValue, b?:DBValue, ...:DBValue) select as外键
## select嵌套外键
```lua
      ViewLog:select('entry_id__blog_id__name'):where{id=1}:exec()
    
```

```sql
SELECT
  T2.name AS entry_id__blog_id__name
FROM
  view_log T
  INNER JOIN entry T1 ON (T.entry_id = T1.id)
  INNER JOIN blog T2 ON (T1.blog_id = T2.id)
WHERE
  T.id = 1
```

```js
[
  {
    entry_id__blog_id__name: "First Blog",
  },
]
```

ok 9 - Xodel:select(a:(fun(ctx:table):string|table)|DBValue, b?:DBValue, ...:DBValue) select嵌套外键
## select as嵌套外键
```lua
      ViewLog:select_as{entry_id__blog_id__name = 'blog_name'}:where{id=1}:exec()
    
```

```sql
SELECT
  T2.name AS blog_name
FROM
  view_log T
  INNER JOIN entry T1 ON (T.entry_id = T1.id)
  INNER JOIN blog T2 ON (T1.blog_id = T2.id)
WHERE
  T.id = 1
```

```js
[
  {
    blog_name: "First Blog",
  },
]
```

ok 10 - Xodel:select(a:(fun(ctx:table):string|table)|DBValue, b?:DBValue, ...:DBValue) select as嵌套外键
## select reversed foreign key
```lua
      Blog:select("id","name","entry__rating"):where{name='Second Blog'}:exec()
    
```

```sql
SELECT
  T.id,
  T.name,
  T1.rating AS entry__rating
FROM
  blog T
  INNER JOIN entry T1 ON (T.id = T1.blog_id)
WHERE
  T.name = 'Second Blog'
```

```js
[
  {
    entry__rating: 5,
    id           : 2,
    name         : "Second Blog",
  },
]
```

ok 11 - Xodel:select(a:(fun(ctx:table):string|table)|DBValue, b?:DBValue, ...:DBValue) select reversed foreign key
## select reversed foreign key with order_by
```lua
      Blog:select(
        "id",
        "name",
        "entry__headline"
      ):where{
        name = 'First Blog'
      }:order_by{'entry__headline'}:exec()
    
```

```sql
SELECT
  T.id,
  T.name,
  T1.headline AS entry__headline
FROM
  blog T
  INNER JOIN entry T1 ON (T.id = T1.blog_id)
WHERE
  T.name = 'First Blog'
ORDER BY
  T1.headline ASC
```

```js
[
  {
    entry__headline: "First Entry",
    id             : 1,
    name           : "First Blog",
  },
  {
    entry__headline: "Third Entry",
    id             : 1,
    name           : "First Blog",
  },
]
```

ok 12 - Xodel:select(a:(fun(ctx:table):string|table)|DBValue, b?:DBValue, ...:DBValue) select reversed foreign key with order_by
## select reversed foreign key with order_by DESC
```lua
      Blog:select(
        "id",
        "name",
        "entry__headline"
      ):where{
        name = 'First Blog'
      }:order_by{'-entry__headline'}:exec()
    
```

```sql
SELECT
  T.id,
  T.name,
  T1.headline AS entry__headline
FROM
  blog T
  INNER JOIN entry T1 ON (T.id = T1.blog_id)
WHERE
  T.name = 'First Blog'
ORDER BY
  T1.headline DESC
```

```js
[
  {
    entry__headline: "Third Entry",
    id             : 1,
    name           : "First Blog",
  },
  {
    entry__headline: "First Entry",
    id             : 1,
    name           : "First Blog",
  },
]
```

ok 13 - Xodel:select(a:(fun(ctx:table):string|table)|DBValue, b?:DBValue, ...:DBValue) select reversed foreign key with order_by DESC
# Xodel:where
# where basic equal
```lua
 Book:where { price = 100 } 
```

```sql
SELECT
  *
FROM
  book T
WHERE
  T.price = 100
```

# where greater than
```lua
 Book:where { price__gt = 100 } 
```

```sql
SELECT
  *
FROM
  book T
WHERE
  T.price > 100
```

# where negative condition
```lua
 Book:where(-Q { price__gt = 100 }) 
```

```sql
SELECT
  *
FROM
  book T
WHERE
  NOT (T.price > 100)
```

# where combined conditions
```lua
 Book:where(Q { price__gt = 100 } / Q { price__lt = 200 }) 
```

```sql
SELECT
  *
FROM
  book T
WHERE
  (T.price > 100)
  OR (T.price < 200)
```

# where negated combined conditions
```lua
 Book:where(-(Q { price__gt = 100 } / Q { price__lt = 200 })) 
```

```sql
SELECT
  *
FROM
  book T
WHERE
  NOT (
    (T.price > 100)
    OR (T.price < 200)
  )
```

# where combined with AND
```lua
 Book:where(Q { id = 1 } * (Q { price__gt = 100 } / Q { price__lt = 200 })) 
```

```sql
SELECT
  *
FROM
  book T
WHERE
  (T.id = 1)
  AND (
    (T.price > 100)
    OR (T.price < 200)
  )
```

# where blog_id equals
```lua
 Entry:where { blog_id = 1 } 
```

```sql
SELECT
  *
FROM
  entry T
WHERE
  T.blog_id = 1
```

# where blog_id reference id
```lua
 Entry:where { blog_id__id = 1 } 
```

```sql
SELECT
  *
FROM
  entry T
WHERE
  T.blog_id = 1
```

# where blog_id greater than
```lua
 Entry:where { blog_id__gt = 1 } 
```

```sql
SELECT
  *
FROM
  entry T
WHERE
  T.blog_id > 1
```

# where blog_id reference id greater than
```lua
 Entry:where { blog_id__id__gt = 1 } 
```

```sql
SELECT
  *
FROM
  entry T
WHERE
  T.blog_id > 1
```

# where blog_id name equals
```lua
 Entry:where { blog_id__name = 'my blog name' } 
```

```sql
SELECT
  *
FROM
  entry T
  INNER JOIN blog T1 ON (T.blog_id = T1.id)
WHERE
  T1.name = 'my blog name'
```

# where blog_id name contains
```lua
 Entry:where { blog_id__name__contains = 'my blog' } 
```

```sql
SELECT
  *
FROM
  entry T
  INNER JOIN blog T1 ON (T.blog_id = T1.id)
WHERE
  T1.name LIKE '%my blog%'
```

# where view log entry_id blog_id equals
```lua
 ViewLog:where { entry_id__blog_id = 1 } 
```

```sql
SELECT
  *
FROM
  view_log T
  INNER JOIN entry T1 ON (T.entry_id = T1.id)
WHERE
  T1.blog_id = 1
```

# where view log entry_id blog_id reference id
```lua
 ViewLog:where { entry_id__blog_id__id = 1 } 
```

```sql
SELECT
  *
FROM
  view_log T
  INNER JOIN entry T1 ON (T.entry_id = T1.id)
WHERE
  T1.blog_id = 1
```

# where view log entry_id blog_id name equals
```lua
 ViewLog:where { entry_id__blog_id__name = 'my blog name' } 
```

```sql
SELECT
  *
FROM
  view_log T
  INNER JOIN entry T1 ON (T.entry_id = T1.id)
  INNER JOIN blog T2 ON (T1.blog_id = T2.id)
WHERE
  T2.name = 'my blog name'
```

# where view log entry_id blog_id name starts with
```lua
 ViewLog:where { entry_id__blog_id__name__startswith = 'my' } 
```

```sql
SELECT
  *
FROM
  view_log T
  INNER JOIN entry T1 ON (T.entry_id = T1.id)
  INNER JOIN blog T2 ON (T1.blog_id = T2.id)
WHERE
  T2.name LIKE 'my%'
```

# where view log entry_id blog_id name starts with and headline equals
```lua
 ViewLog:where { entry_id__blog_id__name__startswith = 'my' }:where { entry_id__headline = 'aa' } 
```

```sql
SELECT
  *
FROM
  view_log T
  INNER JOIN entry T1 ON (T.entry_id = T1.id)
  INNER JOIN blog T2 ON (T1.blog_id = T2.id)
WHERE
  (T2.name LIKE 'my%')
  AND (T1.headline = 'aa')
```

# where blog entry equals
```lua
 Blog:where { entry = 1 } 
```

```sql
SELECT
  *
FROM
  blog T
  INNER JOIN entry T1 ON (T.id = T1.blog_id)
WHERE
  T1.id = 1
```

```lua
 Blog:where { entry__id = 1 } 
```

```sql
SELECT
  *
FROM
  blog T
  INNER JOIN entry T1 ON (T.id = T1.blog_id)
WHERE
  T1.id = 1
```

# where blog entry rating equals
```lua
 Blog:where { entry__rating = 1 } 
```

```sql
SELECT
  *
FROM
  blog T
  INNER JOIN entry T1 ON (T.id = T1.blog_id)
WHERE
  T1.rating = 1
```

# where blog entry view log equals
```lua
 Blog:where { entry__view_log = 1 } 
```

```sql
SELECT
  *
FROM
  blog T
  INNER JOIN entry T1 ON (T.id = T1.blog_id)
  INNER JOIN view_log T2 ON (T1.id = T2.entry_id)
WHERE
  T2.id = 1
```

# where blog entry view log ctime year equals
```lua
 Blog:where { entry__view_log__ctime__year = 2025 } 
```

```sql
SELECT
  *
FROM
  blog T
  INNER JOIN entry T1 ON (T.id = T1.blog_id)
  INNER JOIN view_log T2 ON (T1.id = T2.entry_id)
WHERE
  T2.ctime BETWEEN '2025-01-01' AND '2025-12-31'
```

# where blog entry view log combined conditions
```lua
 Blog:where(Q { entry__view_log = 1 } / Q { entry__view_log = 2 }) 
```

```sql
SELECT
  *
FROM
  blog T
  INNER JOIN entry T1 ON (T.id = T1.blog_id)
  INNER JOIN view_log T2 ON (T1.id = T2.entry_id)
WHERE
  (T2.id = 1)
  OR (T2.id = 2)
```

# group by book name with total price
```lua
 Book:group_by { 'name' }:annotate { price_total = Sum('price') } 
```

```sql
SELECT
  T.name,
  SUM(T.price) AS price_total
FROM
  book T
GROUP BY
  T.name
```

# annotate book with total price
```lua
 Book:annotate { price_total = Sum('price') } 
```

```sql
SELECT
  SUM(T.price) AS price_total
FROM
  book T
```

# annotate book with sum price
```lua
 Book:annotate { Sum('price') } 
```

```sql
SELECT
  SUM(T.price) AS price_sum
FROM
  book T
```

# group by book name with sum price
```lua
 Book:group_by { 'name' }:annotate { Sum('price') } 
```

```sql
SELECT
  T.name,
  SUM(T.price) AS price_sum
FROM
  book T
GROUP BY
  T.name
```

# group by book name with having condition
```lua
 Book:group_by { 'name' }:annotate { Sum('price') }:having { price_sum__gt = 100 } 
```

```sql
SELECT
  T.name,
  SUM(T.price) AS price_sum
FROM
  book T
GROUP BY
  T.name
HAVING
  SUM(T.price) > 100
```

# group by book name with having condition with Q object
```lua
 Book:group_by { 'name' }:annotate { Sum('price') }:having(Q { price_sum__lt = 100 } / Q { price_sum__gt = 200 }) 
```

```sql
SELECT
  T.name,
  SUM(T.price) AS price_sum
FROM
  book T
GROUP BY
  T.name
HAVING
  (SUM(T.price) < 100)
  OR (SUM(T.price) > 200)
```

# group by book name with having total price condition
```lua
 Book:group_by { 'name' }:annotate { price_total = Sum('price') }:having { price_total__gt = 100 } 
```

```sql
SELECT
  T.name,
  SUM(T.price) AS price_total
FROM
  book T
GROUP BY
  T.name
HAVING
  SUM(T.price) > 100
```

# group by book name with having total price condition and order by
```lua
 Book:group_by { 'name' }:annotate { price_total = Sum('price') }:having { price_total__gt = 100 }:order_by { '-price_total' } 
```

```sql
SELECT
  T.name,
  SUM(T.price) AS price_total
FROM
  book T
GROUP BY
  T.name
HAVING
  SUM(T.price) > 100
ORDER BY
  SUM(T.price) DESC
```

# annotate book with double price
```lua
 Book:annotate { double_price = F('price') * 2 } 
```

```sql
SELECT
  (T.price * 2) AS double_price
FROM
  book T
```

# annotate book with price per page
```lua
 Book:annotate { price_per_page = F('price') / F('pages') } 
```

```sql
SELECT
  (T.price / T.pages) AS price_per_page
FROM
  book T
```

# annotate blog with entry count
```lua
 Blog:annotate { entry_count = Count('entry') } 
```

```sql
SELECT
  COUNT(T1.id) AS entry_count
FROM
  blog T
  LEFT JOIN entry T1 ON (T.id = T1.blog_id)
```

# where author resume has key
```lua
 Author:where { resume__has_key = 'start_date' } 
```

```sql
SELECT
  *
FROM
  author T
WHERE
  (T.resume) ? start_date
```

# where author resume has keys
```lua
 Author:where { resume__0__has_keys = { 'a', 'b' } } 
```

```sql
SELECT
  *
FROM
  author T
WHERE
  (T.resume #> ['0']) ?& ['a', 'b']
```

# where author resume has any keys
```lua
 Author:where { resume__has_any_keys = { 'a', 'b' } } 
```

```sql
SELECT
  *
FROM
  author T
WHERE
  (T.resume) ?| ['a', 'b']
```

# where author resume start date time equals
```lua
 Author:where { resume__start_date__time = '12:00:00' } 
```

```sql
SELECT
  *
FROM
  author T
WHERE
  (T.resume #> ['start_date', 'time']) = '"12:00:00"'
```

# where author resume contains
```lua
 Author:where { resume__contains = { start_date = '2025-01-01' } } 
```

```sql
SELECT
  *
FROM
  author T
WHERE
  (T.resume) @> '{"start_date":"2025-01-01"}'
```

# where author resume contained by
```lua
 Author:where { resume__contained_by = { start_date = '2025-01-01' } } 
```

```sql
SELECT
  *
FROM
  author T
WHERE
  (T.resume) <@ '{"start_date":"2025-01-01"}'
```

# where view log entry_id equals
```lua
 ViewLog:where('entry_id__blog_id', 1) 
```

```sql
SELECT
  *
FROM
  view_log T
  INNER JOIN entry T1 ON (T.entry_id = T1.id)
WHERE
  T1.blog_id = 1
```

# where view log entry_id greater than
```lua
 ViewLog:where { entry_id__blog_id__gt = 1 } 
```

```sql
SELECT
  *
FROM
  view_log T
  INNER JOIN entry T1 ON (T.entry_id = T1.id)
WHERE
  T1.blog_id > 1
```

# Xodel:insert(rows:table|table[]|Sql, columns?:string[])
## 插入单行数据
```lua
Blog:insert{
  name = 'insert one row',
  tagline = 'insert one row'
}:exec()
    
```

```sql
INSERT INTO
  blog AS T (name, tagline)
VALUES
  ('insert one row', 'insert one row')
```

```js
{
  affected_rows: 1,
}
```

```sql
DELETE FROM blog T
WHERE
  T.name = 'insert one row'
```

ok 14 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) 插入单行数据
## 插入单行数据并返回特定字段
```lua
Blog:insert{
  name = 'Return Test Blog',
  tagline = 'Return test tagline'
}:returning{'id', 'name'}:exec()
    
```

```sql
INSERT INTO
  blog AS T (name, tagline)
VALUES
  ('Return Test Blog', 'Return test tagline')
RETURNING
  T.id,
  T.name
```

```js
[
  {
    id  : 4,
    name: "Return Test Blog",
  },
]
```

```sql
DELETE FROM blog T
WHERE
  T.id = 4
```

ok 15 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) 插入单行数据并返回特定字段
## returning使用vararg和table等效
```lua
Blog:insert{
  name = 'Return Test Blog',
  tagline = 'Return test tagline'
}:returning{'id', 'name'}:statement()
    
```

```js
"INSERT INTO blog AS T (name, tagline) VALUES ('Return Test Blog', 'Return test tagline') RETURNING T.id, T.name"
```

```sql
INSERT INTO
  blog AS T (name, tagline)
VALUES
  ('Return Test Blog', 'Return test tagline')
RETURNING
  T.id,
  T.name
```

```lua
Blog:insert{
  name = 'Return Test Blog',
  tagline = 'Return test tagline'
}:returning('id', 'name'):statement()
    
```

```js
"INSERT INTO blog AS T (name, tagline) VALUES ('Return Test Blog', 'Return test tagline') RETURNING T.id, T.name"
```

```sql
INSERT INTO
  blog AS T (name, tagline)
VALUES
  ('Return Test Blog', 'Return test tagline')
RETURNING
  T.id,
  T.name
```

ok 16 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) returning使用vararg和table等效
## 批量插入多行数据
```lua
Blog:insert{
  { name = 'bulk insert 1', tagline = 'bulk insert 1' },
  { name = 'bulk insert 2', tagline = 'bulk insert 2' }
}:exec()
    
```

```sql
INSERT INTO
  blog AS T (name, tagline)
VALUES
  ('bulk insert 1', 'bulk insert 1'),
  ('bulk insert 2', 'bulk insert 2')
```

```js
{
  affected_rows: 2,
}
```

```sql
DELETE FROM blog T
WHERE
  T.name LIKE 'bulk insert%'
```

ok 17 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) 批量插入多行数据
## 批量插入并返回所有字段
```lua
Blog:insert{
  { name = 'bulk insert return 1', tagline = 'bulk insert return 1' },
  { name = 'bulk insert return 2', tagline = 'bulk insert return 2' }
}:returning('*'):exec()
    
```

```sql
INSERT INTO
  blog AS T (name, tagline)
VALUES
  ('bulk insert return 1', 'bulk insert return 1'),
  ('bulk insert return 2', 'bulk insert return 2')
RETURNING
  *
```

```js
[
  {
    id     : 7,
    name   : "bulk insert return 1",
    tagline: "bulk insert return 1",
  },
  {
    id     : 8,
    name   : "bulk insert return 2",
    tagline: "bulk insert return 2",
  },
]
```

```sql
DELETE FROM blog T
WHERE
  T.name LIKE 'bulk insert return%'
```

ok 18 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) 批量插入并返回所有字段
## 从子查询select插入数据
```lua
BlogBin:insert(Blog:where{name='Second Blog'}:select{'name', 'tagline'}):exec()
    
```

```sql
INSERT INTO
  blog_bin AS T (name, tagline)
SELECT
  T.name,
  T.tagline
FROM
  blog T
WHERE
  T.name = 'Second Blog'
```

```js
{
  affected_rows: 1,
}
```

ok 19 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) 从子查询select插入数据
## 检验上面插入的数据
```lua
BlogBin:where{name='Second Blog'}:select{'tagline'}:get()
    
```

```sql
SELECT
  T.tagline
FROM
  blog_bin T
WHERE
  T.name = 'Second Blog'
LIMIT
  2
```

```js
{
  tagline: "Another interesting blog",
}
```

ok 20 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) 检验上面插入的数据
## 从子查询select_literal插入数据
```lua
BlogBin:insert(
  Blog:where{ name = 'First Blog'}
  :select{'name', 'tagline'}
  :select_literal('select from another blog'),
  {'name', 'tagline', 'note'}
):exec()
    
```

```sql
INSERT INTO
  blog_bin AS T (name, tagline, note)
SELECT
  T.name,
  T.tagline,
  'select from another blog'
FROM
  blog T
WHERE
  T.name = 'First Blog'
```

```js
{
  affected_rows: 1,
}
```

ok 21 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) 从子查询select_literal插入数据
## 检验上面插入的数据select_literal
```lua
      BlogBin:where{name='First Blog'}:select{'note'}:get()
    
```

```sql
SELECT
  T.note
FROM
  blog_bin T
WHERE
  T.name = 'First Blog'
LIMIT
  2
```

```js
{
  note: "select from another blog",
}
```

ok 22 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) 检验上面插入的数据select_literal
## 从子查询update+returning插入数据
```sql
INSERT INTO
  blog AS T (name, tagline)
VALUES
  ('update returning', 'default tagline')
```

```lua
BlogBin:insert(
  Blog:update{
    name = 'update returning 2'
  }:where{
    name = 'update returning'
  }:returning{
  'name', 'tagline'
  }:returning_literal('update from another blog'),
  {'name', 'tagline', 'note'}
):returning{'name', 'tagline', 'note'}:exec()
    
```

```sql
WITH
  D (name, tagline, note) AS (
    UPDATE blog T
    SET
      name = 'update returning 2'
    WHERE
      T.name = 'update returning'
    RETURNING
      T.name,
      T.tagline,
      'update from another blog'
  )
INSERT INTO
  blog_bin AS T (name, tagline, note)
SELECT
  name,
  tagline,
  note
FROM
  D
RETURNING
  T.name,
  T.tagline,
  T.note
```

```js
[
  {
    name   : "update returning 2",
    note   : "update from another blog",
    tagline: "default tagline",
  },
]
```

```sql
SELECT
  T.name,
  T.tagline,
  T.note
FROM
  blog_bin T
WHERE
  T.name = 'update returning 2'
```

```sql
DELETE FROM blog T
WHERE
  T.name = 'update returning 2'
```

ok 23 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) 从子查询update+returning插入数据
## 从子查询delete+returning插入数据
```sql
INSERT INTO
  blog AS T (name, tagline)
VALUES
  ('delete returning', 'delete returning tagline')
```

```lua
BlogBin:insert(
  Blog:delete{
    name = 'delete returning'
  }:returning{
    'name', 'tagline'
  }:returning_literal('deleted from another blog'),
  {'name', 'tagline', 'note'}
):returning{'name', 'tagline', 'note'}:exec()
    
```

```sql
WITH
  D (name, tagline, note) AS (
    DELETE FROM blog T
    WHERE
      T.name = 'delete returning'
    RETURNING
      T.name,
      T.tagline,
      'deleted from another blog'
  )
INSERT INTO
  blog_bin AS T (name, tagline, note)
SELECT
  name,
  tagline,
  note
FROM
  D
RETURNING
  T.name,
  T.tagline,
  T.note
```

```js
[
  {
    name   : "delete returning",
    note   : "deleted from another blog",
    tagline: "delete returning tagline",
  },
]
```

```sql
DELETE FROM blog T
WHERE
  T.name = 'delete returning'
```

ok 24 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) 从子查询delete+returning插入数据
## 从子查询delete+returning插入数据,未明确指定列
```sql
INSERT INTO
  blog AS T (name, tagline)
VALUES
  ('delete returning', 'no column')
```

```lua
BlogBin:insert(
  Blog:delete { name = 'delete returning' }
  :returning { 'name', 'tagline' }
):returning { 'name', 'tagline', 'note' }:exec()
    
```

```sql
WITH
  D (name, tagline) AS (
    DELETE FROM blog T
    WHERE
      T.name = 'delete returning'
    RETURNING
      T.name,
      T.tagline
  )
INSERT INTO
  blog_bin AS T (name, tagline)
SELECT
  name,
  tagline
FROM
  D
RETURNING
  T.name,
  T.tagline,
  T.note
```

```js
[
  {
    name   : "delete returning",
    note   : "",
    tagline: "no column",
  },
]
```

```sql
DELETE FROM blog T
WHERE
  T.name = 'delete returning'
```

ok 25 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) 从子查询delete+returning插入数据,未明确指定列
## 指定列名插入数据
```lua
BlogBin:insert({
  name = 'Column Test Blog',
  tagline = 'Column test tagline',
  note = 'should not be inserted'
}, {'name', 'tagline'}):returning('name', 'tagline','note'):exec()
    
```

```sql
INSERT INTO
  blog_bin AS T (name, tagline)
VALUES
  ('Column Test Blog', 'Column test tagline')
RETURNING
  T.name,
  T.tagline,
  T.note
```

```js
[
  {
    name   : "Column Test Blog",
    note   : "",
    tagline: "Column test tagline",
  },
]
```

```sql
DELETE FROM blog_bin T
WHERE
  T.name = 'Column Test Blog'
```

ok 26 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) 指定列名插入数据
## 插入数据并使用默认值
```lua
Blog:insert{name = 'Default Test Blog'}:returning{'name', 'tagline'}:exec()
    
```

```sql
INSERT INTO
  blog AS T (name, tagline)
VALUES
  ('Default Test Blog', 'default tagline')
RETURNING
  T.name,
  T.tagline
```

```js
[
  {
    name   : "Default Test Blog",
    tagline: "default tagline",
  },
]
```

```sql
DELETE FROM blog T
WHERE
  T.name = 'Default Test Blog'
```

ok 27 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) 插入数据并使用默认值
# Xodel:insert抛出异常的情况
## 唯一性错误
```lua
 Blog:insert{name='First Blog'}:exec() 
```

```sql
INSERT INTO
  blog AS T (name, tagline)
VALUES
  ('First Blog', 'default tagline')
```

ok 28 - Xodel:insert抛出异常的情况 唯一性错误
## 传入名称过长
```lua
Blog:insert{
  name = 'This name is way too long and exceeds the maximum length',
  tagline = 'Test tagline'
}:exec()
      
```

ok 29 - Xodel:insert抛出异常的情况 传入名称过长
## 插入多行时其中某行名称过长
```lua
Blog:insert{
  { name = 'Valid Blog', tagline = 'Valid tagline' },
  { name = 'This name is way too long and exceeds the maximum length', tagline = 'Another tagline' }
}:exec()
      
```

ok 30 - Xodel:insert抛出异常的情况 插入多行时其中某行名称过长
## 插入复合字段出错(Author的resume字段)
```lua
Author:insert{resume={{company='123456789012345678901234567890'}}}:exec()
      
```

ok 31 - Xodel:insert抛出异常的情况 插入复合字段出错(Author的resume字段)
## 插入多行复合字段出错(Author的resume字段)
```lua
Author:insert{{resume={{company='123456789012345678901234567890'}}}}:exec()
      
```

ok 32 - Xodel:insert抛出异常的情况 插入多行复合字段出错(Author的resume字段)
## 从子查询插入数据列数不一致而出错1
```lua
BlogBin:insert(
  Blog:where { name = 'First Blog' }
  :select { 'name', 'tagline' },
  { 'name' }
):exec()
      
```

```sql
INSERT INTO
  blog_bin AS T (name)
SELECT
  T.name,
  T.tagline
FROM
  blog T
WHERE
  T.name = 'First Blog'
```

ok 33 - Xodel:insert抛出异常的情况 从子查询插入数据列数不一致而出错1
## 从子查询插入数据列数不一致而出错2
```lua
BlogBin:insert(
  Blog:where { name = 'First Blog' }
  :select { 'name', 'tagline' },
  { 'name', 'tagline', 'note' }
):exec()
      
```

```sql
INSERT INTO
  blog_bin AS T (name, tagline, note)
SELECT
  T.name,
  T.tagline
FROM
  blog T
WHERE
  T.name = 'First Blog'
```

ok 34 - Xodel:insert抛出异常的情况 从子查询插入数据列数不一致而出错2
# Xodel:update
## update basic
```lua
Blog:where { name = 'First Blog' }
  :update { tagline = 'changed tagline' }
  :returning('*'):exec()

```

```sql
UPDATE blog T
SET
  tagline = 'changed tagline'
WHERE
  T.name = 'First Blog'
RETURNING
  *
```

```js
[
  {
    id     : 1,
    name   : "First Blog",
    tagline: "changed tagline",
  },
]
```

ok 35 - Xodel:update update basic
## update with join
```lua
Entry:update { headline = F('blog_id__name') }
  :where { id = 1 }
  :returning('headline'):exec()
    
```

```sql
UPDATE entry T
SET
  headline = T1.name
FROM
  blog AS T1
WHERE
  (T.id = 1)
  AND (T.blog_id = T1.id)
RETURNING
  T.headline
```

```js
[
  {
    headline: "First Blog",
  },
]
```

```sql
SELECT
  T.headline
FROM
  entry T
WHERE
  T.id = 1
LIMIT
  2
```

ok 36 - Xodel:update update with join
## update with function
```lua
Entry:update {
  headline = F('headline') .. ' suffix by function'
}:where {
  id = 1
}:returning('headline'):exec()
    
```

```sql
UPDATE entry T
SET
  headline = (T.headline || ' suffix by function')
WHERE
  T.id = 1
RETURNING
  T.headline
```

```js
[
  {
    headline: "First Blog suffix by function",
  },
]
```

```sql
SELECT
  T.headline
FROM
  entry T
WHERE
  T.id = 1
LIMIT
  2
```

ok 37 - Xodel:update update with function
## increase
```sql
SELECT
  T.rating
FROM
  entry T
WHERE
  T.id = 1
LIMIT
  2
```

```lua
 Entry:increase { rating = 1 }:where{id=1}:returning('rating'):exec() 
```

```sql
UPDATE entry T
SET
  rating = (T.rating + 1)
WHERE
  T.id = 1
RETURNING
  T.rating
```

```js
[
  {
    rating: 5,
  },
]
```

ok 38 - Xodel:update increase
## increase two fields
```sql
SELECT
  *
FROM
  entry T
WHERE
  T.id = 1
LIMIT
  2
```

```lua
 Entry:increase { number_of_comments = 1, number_of_pingbacks=2 }:where{id=1}:returning('*'):exec() 
```

```sql
UPDATE entry T
SET
  number_of_comments = (T.number_of_comments + 1),
  number_of_pingbacks = (T.number_of_pingbacks + 2)
WHERE
  T.id = 1
RETURNING
  *
```

```js
[
  {
    blog_id            : 1,
    body_text          : "This is the first entry in my blog.",
    headline           : "First Blog suffix by function",
    id                 : 1,
    mod_date           : "2023-01-02",
    number_of_comments : 6,
    number_of_pingbacks: 4,
    pub_date           : "2023-01-01",
    rating             : 5,
  },
]
```

ok 39 - Xodel:update increase two fields
## increase string args
```sql
SELECT
  T.rating
FROM
  entry T
WHERE
  T.id = 1
LIMIT
  2
```

```lua
 Entry:increase('rating', 2):where{id=1}:returning('rating'):exec() 
```

```sql
UPDATE entry T
SET
  rating = (T.rating + 2)
WHERE
  T.id = 1
RETURNING
  T.rating
```

```js
[
  {
    rating: 7,
  },
]
```

ok 40 - Xodel:update increase string args
## update with where join
```lua
Entry:update {
  headline = F('headline') .. ' from first blog'
}:where {
  blog_id__name = 'First Blog'
}:returning('id', 'headline'):exec()
    
```

```sql
UPDATE entry T
SET
  headline = (T.headline || ' from first blog')
FROM
  blog AS T1
WHERE
  (T1.name = 'First Blog')
  AND (T.blog_id = T1.id)
RETURNING
  T.id,
  T.headline
```

```js
[
  {
    headline: "Third Entry from first blog",
    id      : 3,
  },
  {
    headline: "First Blog suffix by function from first blog",
    id      : 1,
  },
]
```

```sql
SELECT
  T.id,
  T.headline
FROM
  entry T
WHERE
  T.headline LIKE '% from first blog'
```

ok 41 - Xodel:update update with where join
# Xodel:merge

## merge basic
```lua
Blog:merge {
  { name = 'First Blog', tagline = 'updated by merge' },
  { name = 'Blog added by merge', tagline = 'inserted by merge' },
}:exec() 
```

```sql
WITH
  V (name, tagline) AS (
    VALUES
      ('First Blog'::varchar, 'updated by merge'::text),
      ('Blog added by merge', 'inserted by merge')
  ),
  U AS (
    UPDATE blog W
    SET
      tagline = V.tagline
    FROM
      V
    WHERE
      V.name = W.name
    RETURNING
      V.name,
      V.tagline
  )
INSERT INTO
  blog AS T (name, tagline)
SELECT
  V.name,
  V.tagline
FROM
  V
  LEFT JOIN U AS W ON (V.name = W.name)
WHERE
  W.name IS NULL
```

```js
{
  affected_rows: 1,
}
```

```sql
SELECT
  T.tagline
FROM
  blog T
WHERE
  T.name = 'First Blog'
LIMIT
  2
```

```sql
DELETE FROM blog T
WHERE
  T.name = 'Blog added by merge'
```

ok 42 - Xodel:merge merge basic
## merge insert only
```sql
SELECT
  *
FROM
  blog T
WHERE
  T.name = 'First Blog'
LIMIT
  2
```

```lua
 Blog:merge { { name = 'First Blog' }, { name = 'Blog added by merge' } }:exec() 
```

```sql
WITH
  V (name) AS (
    VALUES
      ('First Blog'::varchar),
      ('Blog added by merge')
  ),
  U AS (
    SELECT
      V.name
    FROM
      V
      INNER JOIN blog AS W ON (V.name = W.name)
  )
INSERT INTO
  blog AS T (name)
SELECT
  V.name
FROM
  V
  LEFT JOIN U AS W ON (V.name = W.name)
WHERE
  W.name IS NULL
```

```js
{
  affected_rows: 1,
}
```

```sql
SELECT
  *
FROM
  blog T
WHERE
  T.name = 'First Blog'
LIMIT
  2
```

```sql
SELECT
  T.name,
  T.tagline
FROM
  blog T
WHERE
  T.name = 'Blog added by merge'
LIMIT
  2
```

```sql
DELETE FROM blog T
WHERE
  T.name = 'Blog added by merge'
```

ok 43 - Xodel:merge merge insert only
## merge抛出异常的情况
```lua
 Author:merge { { name = 'Tom', age = 11 }, { name = 'Jerry', age = 101 } }:exec() 
```

ok 44 - Xodel:merge merge抛出异常的情况
# Xodel:upsert
## upsert basic
```lua
Blog:upsert {
{ name = 'First Blog', tagline = 'updated by upsert' },
{ name = 'Blog added by upsert', tagline = 'inserted by upsert' },
}:exec()
    
```

```sql
INSERT INTO
  blog AS T (name, tagline)
VALUES
  ('First Blog', 'updated by upsert'),
  ('Blog added by upsert', 'inserted by upsert')
ON CONFLICT (name) DO
UPDATE
SET
  tagline = EXCLUDED.tagline
```

```js
{
  affected_rows: 2,
}
```

```sql
SELECT
  T.tagline
FROM
  blog T
WHERE
  T.name = 'First Blog'
LIMIT
  2
```

```sql
SELECT
  T.name,
  T.tagline
FROM
  blog T
WHERE
  T.name = 'Blog added by upsert'
LIMIT
  2
```

```sql
DELETE FROM blog T
WHERE
  T.name = 'Blog added by upsert'
```

ok 45 - Xodel:upsert upsert basic
## upsert from returning
```sql
SELECT
  *
FROM
  blog_bin T
```

```sql
DELETE FROM blog_bin T
```

```sql
INSERT INTO
  blog_bin AS T (name, tagline, note)
VALUES
  ('B1', 'tag1', ''),
  ('B2', 'tag2', '')
```

```lua
Blog:upsert(
  BlogBin
    :update { tagline = 'updated by upsert returning' }
    :returning {'name', 'tagline'}
):returning{'id','name', 'tagline'}:exec()
    
```

```sql
WITH
  V (name, tagline) AS (
    UPDATE blog_bin T
    SET
      tagline = 'updated by upsert returning'
    RETURNING
      T.name,
      T.tagline
  )
INSERT INTO
  blog AS T (name, tagline)
SELECT
  name,
  tagline
FROM
  V
ON CONFLICT (name) DO
UPDATE
SET
  tagline = EXCLUDED.tagline
RETURNING
  T.id,
  T.name,
  T.tagline
```

```js
[
  {
    id     : 18,
    name   : "B1",
    tagline: "updated by upsert returning",
  },
  {
    id     : 19,
    name   : "B2",
    tagline: "updated by upsert returning",
  },
]
```

```sql
SELECT
  T.name
FROM
  blog T
WHERE
  T.tagline = 'updated by upsert returning'
ORDER BY
  T.name ASC
```

```sql
DELETE FROM blog T
WHERE
  T.tagline = 'updated by upsert returning'
```

```sql
DELETE FROM blog_bin T
```

```sql
INSERT INTO
  blog_bin AS T (name, tagline, note)
VALUES
  ('Second Blog', 'Another interesting blog', ''),
  (
    'First Blog',
    'Welcome to my blog',
    'select from another blog'
  ),
  (
    'update returning 2',
    'default tagline',
    'update from another blog'
  ),
  (
    'delete returning',
    'delete returning tagline',
    'deleted from another blog'
  ),
  ('delete returning', 'no column', '')
```

ok 46 - Xodel:upsert upsert from returning
## upsert from select
```lua
Blog:upsert(
  BlogBin
    :where {
      name__notin = Blog:select {'name'}:distinct()
    }
    :select {'name', 'tagline'}
    :distinct('name')
):returning{'id','name', 'tagline'}:exec()
    
```

```sql
INSERT INTO
  blog AS T (name, tagline)
SELECT DISTINCT
  ON (T.name) T.name,
  T.tagline
FROM
  blog_bin T
WHERE
  T.name NOT IN (
    SELECT DISTINCT
      T.name
    FROM
      blog T
  )
ON CONFLICT (name) DO
UPDATE
SET
  tagline = EXCLUDED.tagline
RETURNING
  T.id,
  T.name,
  T.tagline
```

```js
[
  {
    id     : 20,
    name   : "delete returning",
    tagline: "delete returning tagline",
  },
  {
    id     : 21,
    name   : "update returning 2",
    tagline: "default tagline",
  },
]
```

```sql
DELETE FROM blog T
WHERE
  T.id IN (20, 21)
```

ok 47 - Xodel:upsert upsert from select
# upsert抛出异常的情况
## single upsert
```lua
  Author:upsert { { name = 'Tom', age = 111 } }:exec() 
```

ok 48 - upsert抛出异常的情况 single upsert
## multiple upsert
```lua
  Author:upsert { { name = 'Tom', age = 11 }, { name = 'Jerry', age = 101 } }:exec() 
```

ok 49 - upsert抛出异常的情况 multiple upsert
# Xodel:updates
## updates basic
```sql
INSERT INTO
  blog AS T (name, tagline)
VALUES
  ('Third Blog', 'default tagline')
```

```lua
Blog:updates({
  { name = 'Third Blog', tagline = 'Updated by updates' },
  { name = 'Fourth Blog', tagline = 'wont update' }
}):exec()
    
```

```sql
WITH
  V (name, tagline) AS (
    VALUES
      ('Third Blog'::varchar, 'Updated by updates'::text),
      ('Fourth Blog', 'wont update')
  )
UPDATE blog T
SET
  tagline = V.tagline
FROM
  V
WHERE
  V.name = T.name
```

```js
{
  affected_rows: 1,
}
```

```sql
SELECT
  T.tagline
FROM
  blog T
WHERE
  T.name = 'Third Blog'
LIMIT
  2
```

```sql
DELETE FROM blog T
WHERE
  T.name = 'Third Blog'
```

ok 50 - Xodel:updates updates basic
## updates from SELECT subquery
```lua
BlogBin:updates(
  Blog
    :where { name = 'Second Blog' }
    :select { 'name', 'tagline' },
  'name'
):exec()
    
```

```sql
WITH
  V (name, tagline) AS (
    SELECT
      T.name,
      T.tagline
    FROM
      blog T
    WHERE
      T.name = 'Second Blog'
  )
UPDATE blog_bin T
SET
  tagline = V.tagline
FROM
  V
WHERE
  V.name = T.name
```

```js
{
  affected_rows: 1,
}
```

```sql
SELECT
  T.tagline
FROM
  blog_bin T
WHERE
  T.name = 'Second Blog'
LIMIT
  2
```

ok 51 - Xodel:updates updates from SELECT subquery
## updates from UPDATE subquery
```sql
WITH
  D (name, tagline) AS (
    INSERT INTO
      blog AS T (name, tagline)
    VALUES
      ('Third Blog', 'Third interesting blog')
    RETURNING
      T.name,
      T.tagline
  )
INSERT INTO
  blog_bin AS T (name, tagline)
SELECT
  name,
  tagline
FROM
  D
```

```lua
BlogBin:updates(
  Blog
    :where { name = 'Third Blog' }
    :update { tagline = 'XXX' }
    :returning { 'name', 'tagline' },
  'name'
):exec()
    
```

```sql
WITH
  V (name, tagline) AS (
    UPDATE blog T
    SET
      tagline = 'XXX'
    WHERE
      T.name = 'Third Blog'
    RETURNING
      T.name,
      T.tagline
  )
UPDATE blog_bin T
SET
  tagline = V.tagline
FROM
  V
WHERE
  V.name = T.name
```

```js
{
  affected_rows: 1,
}
```

```sql
SELECT
  T.tagline
FROM
  blog_bin T
WHERE
  T.name = 'Third Blog'
LIMIT
  2
```

```sql
SELECT
  T.tagline
FROM
  blog T
WHERE
  T.name = 'Third Blog'
LIMIT
  2
```

```sql
DELETE FROM blog T
WHERE
  T.name = 'Third Blog'
```

ok 52 - Xodel:updates updates from UPDATE subquery
# updates抛出异常的情况
## updates without primary key
```lua
Blog:updates{
  { tagline = 'Missing ID' }
}:exec()
      
```

ok 53 - updates抛出异常的情况 updates without primary key
## multiple updates
```lua
  Author:updates{ { id = 1, age = 11 }, { id = 2, age = 101 } }:exec() 
```

ok 54 - updates抛出异常的情况 multiple updates
## updates with invalid field
```lua
Author:updates({
  { name = 'John Doe', age2 = 9 }
}):exec()
      
```

ok 55 - updates抛出异常的情况 updates with invalid field
1..55

