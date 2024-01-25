# lua-resty-model
openresty super orm finally comes out!

# Requirements
- [lua-resty-validator](https://github.com/xiangnanscu/lua-resty-validator)
- [lua-resty-field](https://github.com/xiangnanscu/lua-resty-field)
- [lua-resty-sql](https://github.com/xiangnanscu/lua-resty-sql)
- [lua-resty-query](https://github.com/xiangnanscu/lua-resty-query)
- [lua-resty-array](https://github.com/xiangnanscu/lua-resty-array)
- [lua-resty-object](https://github.com/xiangnanscu/lua-resty-object)
- [lua-resty-dotenv](https://github.com/xiangnanscu/lua-resty-dotenv)
# Synopsis
```lua
local Model = require("resty.model")


local Usr = Model:create_model {
  table_name = 'usr',
  fields = {
    { name = 'id',         type = 'integer', primary_key = true, serial = true },
    { name = 'username',   maxlength = 5,    required = true,    unique = true },
    { name = 'permission', type = 'integer', default = 0,        max = 5 },
  }
}

local Dept = Model:create_model {
  table_name = 'dept',
  { name = 'name', maxlength = 10, unique = true }
}

local Profile = Model:create_model {
  table_name = 'profile',
  { name = 'usr_id',    reference = Usr,  reference_column = 'id' },
  { name = 'dept_name', reference = Dept, reference_column = 'name' },
  { name = 'age',       required = true,  type = 'integer',         default = 0 },
  { name = 'sex',       default = 'f',    choices = { 'f', 'm' } },
  { name = 'salary',    type = 'float',   default = 1000 },

}

-- create with fields: id, utime and ctime
local Message = Model {
  table_name = 'message',
  { name = 'creator', reference = Profile, },
  { name = "target",  reference = Profile, },
  { name = 'content', maxlength = 100,     compact = false },
}

local Evaluate = Model {
  table_name = 'evaluate',
  unique_together = { 'usr_id', 'year' },
  { name = 'usr_id', reference = Usr, },
  { name = "year",   type = 'year', },
  { name = 'rank',   maxlength = 1,   default = 'C' },
}

local Log = Model:create_model {
  table_name = 'log',
  fields = {
    { name = 'id',         type = 'integer', primary_key = true, serial = true },
    { name = 'delete_id',  type = 'integer', default = 0 },
    { name = 'model_name', type = 'string',  maxlength = 20 },
    { name = 'action',     maxlength = 10, }
  }
}

local Log2 = Model:create_model {
  table_name = 'log2',
  fields = {
    { name = 'buyer',  reference = Usr, },
    { name = 'seller', reference = Usr, },
  }
}

local Log3 = Model:create_model {
  table_name = 'log3',
  fields = {
    { name = 'start_log', reference = Log2, },
    { name = 'end_log',   reference = Log2, },
  }
}

local TableModel = Model:create_model {
  { name = 'ages',  type = 'array', field = { type = 'integer', max = 2 } },
  { name = 'users', type = 'table', model = Usr }
}
```


# Xodel:insert(rows:table|table[]|Sql, columns?:string[])

## insert one user
```lua
 usr:insert{permission=1, username ='u1'}:exec()
```

```sql
INSERT INTO
  usr (username, permission)
VALUES
  ('u1', 1)
```

```js
{
  affected_rows: 1,
}
```

ok 1 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) insert one user
## insert one user returning one column
```lua
 usr:insert{permission=1, username ='u2'}:returning('permission'):exec()
```

```sql
INSERT INTO
  usr (username, permission)
VALUES
  ('u2', 1)
RETURNING
  usr.permission
```

```js
[
  {
    permission: 1,
  },
]
```

ok 2 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) insert one user returning one column
## insert one user with default permission
```lua
 usr:insert{username ='u3'}:returning('permission'):exec()
```

```sql
INSERT INTO
  usr (username, permission)
VALUES
  ('u3', 0)
RETURNING
  usr.permission
```

```js
[
  {
    permission: 0,
  },
]
```

ok 3 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) insert one user with default permission
## insert one user returning two columns
```lua
 usr:insert{permission=1, username ='u4'}:returning('permission','username'):exec()
```

```sql
INSERT INTO
  usr (username, permission)
VALUES
  ('u4', 1)
RETURNING
  usr.permission,
  usr.username
```

```js
[
  {
    permission: 1,
    username  : "u4",
  },
]
```

ok 4 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) insert one user returning two columns
## insert one user returning one column in compact form
```lua
 usr:insert{permission=1, username ='u5'}:returning('username'):compact():exec()
```

```sql
INSERT INTO
  usr (username, permission)
VALUES
  ('u5', 1)
RETURNING
  usr.username
```

```js
[
  [
    "u5",
  ],
]
```

ok 5 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) insert one user returning one column in compact form
## insert two users
```lua
 usr:insert{{permission=1, username ='u6'}, {permission=1, username ='u7'}}:exec()
```

```sql
INSERT INTO
  usr (username, permission)
VALUES
  ('u6', 1),
  ('u7', 1)
```

```js
{
  affected_rows: 2,
}
```

ok 6 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) insert two users
## insert two users returning one column
```lua
 usr:insert{{permission=1, username ='u8'}, {permission=1, username ='u9'}}:returning('username'):exec()
```

```sql
INSERT INTO
  usr (username, permission)
VALUES
  ('u8', 1),
  ('u9', 1)
RETURNING
  usr.username
```

```js
[
  {
    username: "u8",
  },
  {
    username: "u9",
  },
]
```

ok 7 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) insert two users returning one column
## insert two users returning two columns
```lua
 usr:insert{{permission=2, username ='u10'}, {permission=3, username ='u11'}}:returning('username','permission'):exec()
```

```sql
INSERT INTO
  usr (username, permission)
VALUES
  ('u10', 2),
  ('u11', 3)
RETURNING
  usr.username,
  usr.permission
```

```js
[
  {
    permission: 2,
    username  : "u10",
  },
  {
    permission: 3,
    username  : "u11",
  },
]
```

ok 8 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) insert two users returning two columns
## insert two users returning one column in flatten form
```lua
 usr:insert{{permission=1, username ='u12'}, {permission=1, username ='u13'}}:returning('username'):flat()
```

```sql
INSERT INTO
  usr (username, permission)
VALUES
  ('u12', 1),
  ('u13', 1)
RETURNING
  usr.username
```

```js
[
  "u12",
  "u13",
]
```

ok 9 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) insert two users returning one column in flatten form
## insert two users returning two columns in flatten form
```lua
 usr:insert{{permission=1, username ='u14'}, {permission=2, username ='u15'}}:returning('username','permission'):flat()
```

```sql
INSERT INTO
  usr (username, permission)
VALUES
  ('u14', 1),
  ('u15', 2)
RETURNING
  usr.username,
  usr.permission
```

```js
[
  "u14",
  1,
  "u15",
  2,
]
```

ok 10 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) insert two users returning two columns in flatten form
## insert one user with specific columns (permission being ignored)
```lua
 usr:insert({permission=4, username ='u16'}, {'username'}):returning('username','permission'):exec()
```

```sql
INSERT INTO
  usr (username)
VALUES
  ('u16')
RETURNING
  usr.username,
  usr.permission
```

```js
[
  {
    permission: 0,
    username  : "u16",
  },
]
```

ok 11 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) insert one user with specific columns (permission being ignored)
## insert one user with specific columns
```lua
 usr:insert({permission=4, username ='u17'}, {'username', 'permission'}):returning('username','permission'):exec()
```

```sql
INSERT INTO
  usr (username, permission)
VALUES
  ('u17', 4)
RETURNING
  usr.username,
  usr.permission
```

```js
[
  {
    permission: 4,
    username  : "u17",
  },
]
```

ok 12 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) insert one user with specific columns
## insert two users with specific columns (permission being ignored)
```lua
 usr:insert({{permission=4, username ='u18'},{permission=5, username ='u19'}}, {'username'}):returning('username','permission'):exec()
```

```sql
INSERT INTO
  usr (username)
VALUES
  ('u18'),
  ('u19')
RETURNING
  usr.username,
  usr.permission
```

```js
[
  {
    permission: 0,
    username  : "u18",
  },
  {
    permission: 0,
    username  : "u19",
  },
]
```

ok 13 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) insert two users with specific columns (permission being ignored)
## insert two users with specific columns
```lua
 usr:insert({{permission=4, username ='u20'},{permission=5, username ='u21'}}, {'username', 'permission'}):returning('username','permission'):exec()
```

```sql
INSERT INTO
  usr (username, permission)
VALUES
  ('u20', 4),
  ('u21', 5)
RETURNING
  usr.username,
  usr.permission
```

```js
[
  {
    permission: 4,
    username  : "u20",
  },
  {
    permission: 5,
    username  : "u21",
  },
]
```

ok 14 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) insert two users with specific columns
## insert users with default permission
```lua
 usr:insert{{username ='f1'},{username ='f2'}}:flat('permission')
```

```sql
INSERT INTO
  usr (username, permission)
VALUES
  ('f1', 0),
  ('f2', 0)
RETURNING
  usr.permission
```

```js
[
  0,
  0,
]
```

ok 15 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) insert users with default permission
## insert one user validate required failed
ok 16 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) insert one user validate required failed
## insert one user validate maxlength failed
ok 17 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) insert one user validate maxlength failed
## insert one user validate max failed
ok 18 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) insert one user validate max failed
## insert two users validate max failed
ok 19 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) insert two users validate max failed
# Xodel:create
## create
```lua
dept:returning('*'):create{name ='d1'}
```

```sql
INSERT INTO
  dept (name)
VALUES
  ('d1')
RETURNING
  *
```

```js
[
  {
    id  : 1,
    name: "d1",
  },
]
```

ok 20 - Xodel:create create
## create multiple rows
```lua
dept:returning('name'):create{{name ='d2'}, {name ='d3'}}
```

```sql
INSERT INTO
  dept (name)
VALUES
  ('d2'),
  ('d3')
RETURNING
  dept.name
```

```js
[
  {
    name: "d2",
  },
  {
    name: "d3",
  },
]
```

ok 21 - Xodel:create create multiple rows
# Xodel:count(cond?, op?, dval?)
## specify condition
```lua
usr:count{id__lt=3}
```

```sql
SELECT
  count(*)
FROM
  usr
WHERE
  usr.id < 3
```

```js
2
```

ok 22 - Xodel:count(cond?, op?, dval?) specify condition
## test with Xodel:all
```lua
dept:all()
```

```sql
SELECT
  *
FROM
  dept
```

```js
[
  {
    id  : 1,
    name: "d1",
  },
  {
    id  : 2,
    name: "d2",
  },
  {
    id  : 3,
    name: "d3",
  },
]
```

```lua
dept:count()
```

```sql
SELECT
  count(*)
FROM
  dept
```

```js
3
```

ok 23 - Xodel:count(cond?, op?, dval?) test with Xodel:all
# XodelInstance:save(names?:string[], key?:string)
## save basic
```lua
profile{usr_id=1, dept_name='d1', age=20}:save()
```

```sql
INSERT INTO
  profile (salary, usr_id, dept_name, age, sex)
VALUES
  (1000, 1, 'd1', 20, 'f')
RETURNING
  *
```

```js
{
  age      : 20,
  dept_name: "d1",
  id       : 1,
  salary   : 1000,
  sex      : "f",
  usr_id   : 1,
}
```

ok 24 - XodelInstance:save(names?:string[], key?:string) save basic
## save with specific names
```lua
profile{usr_id=2, dept_name='d2', salary=500, sex='m', age=50}:save{'usr_id','dept_name'}
```

```sql
INSERT INTO
  profile (dept_name, usr_id)
VALUES
  ('d2', 2)
RETURNING
  *
```

```js
{
  age      : 0,
  dept_name: "d2",
  id       : 2,
  salary   : 1000,
  sex      : "f",
  usr_id   : 2,
}
```

ok 25 - XodelInstance:save(names?:string[], key?:string) save with specific names
## save with primary key specified to update
```lua
profile{id=1, age=33}:save()
```

```sql
UPDATE profile
SET
  age = 33
WHERE
  profile.id = 1
RETURNING
  id
```

```js
{
  age: 33,
  id : 1,
}
```

ok 26 - XodelInstance:save(names?:string[], key?:string) save with primary key specified to update
## save with primary key ignored and force create
```lua
profile{id=5, age=55, usr_id=3, dept_name='d3',}:save_create()
```

```sql
INSERT INTO
  profile (salary, usr_id, dept_name, age, sex)
VALUES
  (1000, 3, 'd3', 55, 'f')
RETURNING
  *
```

```js
{
  age      : 55,
  dept_name: "d3",
  id       : 3,
  salary   : 1000,
  sex      : "f",
  usr_id   : 3,
}
```

ok 27 - XodelInstance:save(names?:string[], key?:string) save with primary key ignored and force create
## save with wrong name
```lua
profile{usr_id=1, dept_name='d1', age=20}:save{'xxxx'}
```

ok 28 - XodelInstance:save(names?:string[], key?:string) save with wrong name
# Xodel:merge(rows:table[], key?:string|string[], columns?:string[])
## merge multiple rows returning inserted rows with all columns
```lua
usr:merge({{permission=4, username ='u1'},{permission=2, username ='u22'}}, 'username'):returning('*'):exec()
```

```sql
WITH
  V (permission, username) AS (
    VALUES
      (4::integer, 'u1'::varchar),
      (2, 'u22')
  ),
  U AS (
    UPDATE usr AS T
    SET
      permission = V.permission
    FROM
      V
    WHERE
      V.username = T.username
    RETURNING
      V.permission,
      V.username
  )
INSERT INTO
  usr (permission, username)
SELECT
  V.permission,
  V.username
FROM
  V
  LEFT JOIN U AS T ON (V.username = T.username)
WHERE
  T.username IS NULL
RETURNING
  *
```

```js
[
  {
    id        : 24,
    permission: 2,
    username  : "u22",
  },
]
```

ok 29 - Xodel:merge(rows:table[], key?:string|string[], columns?:string[]) merge multiple rows returning inserted rows with all columns
## merge multiple rows returning inserted rows with specific columns
```lua
usr:merge({{username ='u23'},{username ='u24'}}, 'username'):returning('username'):exec()
```

```sql
WITH
  V (username) AS (
    VALUES
      ('u23'::varchar),
      ('u24')
  ),
  U AS (
    SELECT
      V.username
    FROM
      V
      INNER JOIN usr AS T ON (V.username = T.username)
  )
INSERT INTO
  usr (username)
SELECT
  V.username
FROM
  V
  LEFT JOIN U AS T ON (V.username = T.username)
WHERE
  T.username IS NULL
RETURNING
  usr.username
```

```js
[
  {
    username: "u23",
  },
  {
    username: "u24",
  },
]
```

ok 30 - Xodel:merge(rows:table[], key?:string|string[], columns?:string[]) merge multiple rows returning inserted rows with specific columns
## merge multiple rows returning inserted rows with specific columns in compact form
```lua
usr:merge({{username ='u25'},{username ='u26'}}, 'username'):returning('username'):flat()
```

```sql
WITH
  V (username) AS (
    VALUES
      ('u25'::varchar),
      ('u26')
  ),
  U AS (
    SELECT
      V.username
    FROM
      V
      INNER JOIN usr AS T ON (V.username = T.username)
  )
INSERT INTO
  usr (username)
SELECT
  V.username
FROM
  V
  LEFT JOIN U AS T ON (V.username = T.username)
WHERE
  T.username IS NULL
RETURNING
  usr.username
```

```js
[
  "u25",
  "u26",
]
```

ok 31 - Xodel:merge(rows:table[], key?:string|string[], columns?:string[]) merge multiple rows returning inserted rows with specific columns in compact form
## merge multiple rows returning inserted rows with array key
```lua
evaluate:merge({{usr_id=1, year=2021, rank='A'},{usr_id=1, year=2022, rank='B'}}, {'usr_id', 'year'}):returning('rank'):flat()
```

```sql
WITH
  V (year, usr_id, rank) AS (
    VALUES
      (2021::integer, 1::integer, 'A'::varchar),
      (2022, 1, 'B')
  ),
  U AS (
    UPDATE evaluate AS T
    SET
      rank = V.rank
    FROM
      V
    WHERE
      V.usr_id = T.usr_id
      AND V.year = T.year
    RETURNING
      V.year,
      V.usr_id,
      V.rank
  )
INSERT INTO
  evaluate (year, usr_id, rank)
SELECT
  V.year,
  V.usr_id,
  V.rank
FROM
  V
  LEFT JOIN U AS T ON (
    V.usr_id = T.usr_id
    AND V.year = T.year
  )
WHERE
  T.usr_id IS NULL
RETURNING
  evaluate.rank
```

```js
[
  "A",
  "B",
]
```

ok 32 - Xodel:merge(rows:table[], key?:string|string[], columns?:string[]) merge multiple rows returning inserted rows with array key
## merge multiple rows returning inserted rows with array key and specific columns
```lua
evaluate:merge({{usr_id=2, year=2021, rank='A'},{usr_id=2, year=2022, rank='B'}}, {'usr_id', 'year'}, {'usr_id', 'year'}):returning('rank'):flat()
```

```sql
WITH
  V (usr_id, year) AS (
    VALUES
      (2::integer, 2021::integer),
      (2, 2022)
  ),
  U AS (
    SELECT
      V.usr_id,
      V.year
    FROM
      V
      INNER JOIN evaluate AS T ON (
        V.usr_id = T.usr_id
        AND V.year = T.year
      )
  )
INSERT INTO
  evaluate (usr_id, year)
SELECT
  V.usr_id,
  V.year
FROM
  V
  LEFT JOIN U AS T ON (
    V.usr_id = T.usr_id
    AND V.year = T.year
  )
WHERE
  T.usr_id IS NULL
RETURNING
  evaluate.rank
```

```js
[
  "C",
  "C",
]
```

ok 33 - Xodel:merge(rows:table[], key?:string|string[], columns?:string[]) merge multiple rows returning inserted rows with array key and specific columns
## merge multiple rows validate max failed
ok 34 - Xodel:merge(rows:table[], key?:string|string[], columns?:string[]) merge multiple rows validate max failed
## merge multiple rows missing default unique value failed
ok 35 - Xodel:merge(rows:table[], key?:string|string[], columns?:string[]) merge multiple rows missing default unique value failed
# Xodel:upsert(rows:table[], key?:string|string[], columns?:string[])
## upsert multiple rows returning inserted rows with all columns
```lua
usr:upsert({{permission=4, username ='u1'},{permission=2, username ='u27'}}, 'username'):returning('username'):exec()
```

```sql
INSERT INTO
  usr (permission, username)
VALUES
  (4, 'u1'),
  (2, 'u27')
ON CONFLICT (username) DO
UPDATE
SET
  permission = EXCLUDED.permission
RETURNING
  usr.username
```

```js
[
  {
    username: "u1",
  },
  {
    username: "u27",
  },
]
```

ok 36 - Xodel:upsert(rows:table[], key?:string|string[], columns?:string[]) upsert multiple rows returning inserted rows with all columns
## upsert multiple rows returning inserted rows with specific columns in compact form
```lua
usr:upsert({{username ='u28'},{username ='u29'}}, 'username'):returning('username'):flat()
```

```sql
INSERT INTO
  usr (username)
VALUES
  ('u28'),
  ('u29')
ON CONFLICT (username) DO NOTHING
RETURNING
  usr.username
```

```js
[
  "u28",
  "u29",
]
```

ok 37 - Xodel:upsert(rows:table[], key?:string|string[], columns?:string[]) upsert multiple rows returning inserted rows with specific columns in compact form
## upsert multiple rows returning inserted rows with array key
```lua
evaluate:upsert({{usr_id=1, year=2021, rank='A'},{usr_id=1, year=2022, rank='B'}}, {'usr_id', 'year'}):returning('rank'):flat()
```

```sql
INSERT INTO
  evaluate (year, usr_id, rank)
VALUES
  (2021, 1, 'A'),
  (2022, 1, 'B')
ON CONFLICT (usr_id, year) DO
UPDATE
SET
  rank = EXCLUDED.rank
RETURNING
  evaluate.rank
```

```js
[
  "A",
  "B",
]
```

ok 38 - Xodel:upsert(rows:table[], key?:string|string[], columns?:string[]) upsert multiple rows returning inserted rows with array key
## upsert multiple rows validate max failed
ok 39 - Xodel:upsert(rows:table[], key?:string|string[], columns?:string[]) upsert multiple rows validate max failed
# Xodel.update
## update one user
```lua
 usr:update{permission=2}:where{id=1}:exec()
```

```sql
UPDATE usr
SET
  permission = 2
WHERE
  usr.id = 1
```

```js
{
  affected_rows: 1,
}
```

ok 40 - Xodel.update update one user
## update one user returning one column
```lua
 usr:update{permission=3}:where{id=1}:returning('permission'):exec()
```

```sql
UPDATE usr
SET
  permission = 3
WHERE
  usr.id = 1
RETURNING
  usr.permission
```

```js
[
  {
    permission: 3,
  },
]
```

ok 41 - Xodel.update update one user returning one column
## update users returning two columns in table form
```lua
 usr:update{permission=3}:where{id__lt=3}:returning{'permission','id'}:exec()
```

```sql
UPDATE usr
SET
  permission = 3
WHERE
  usr.id < 3
RETURNING
  usr.permission,
  usr.id
```

```js
[
  {
    id        : 1,
    permission: 3,
  },
  {
    id        : 2,
    permission: 3,
  },
]
```

ok 42 - Xodel.update update users returning two columns in table form
## update users returning one column in flatten form
```lua
 usr:update{permission=3}:where{id__lt=3}:returning{'username'}:flat()
```

```sql
UPDATE usr
SET
  permission = 3
WHERE
  usr.id < 3
RETURNING
  usr.username
```

```js
[
  "u1",
  "u2",
]
```

ok 43 - Xodel.update update users returning one column in flatten form
## update by where with foreignkey
```lua
profile:update{age=11}:where{usr_id__username__contains='1'}:returning('age'):exec()
```

```sql
UPDATE profile
SET
  age = 11
FROM
  usr T1
WHERE
  (profile.usr_id = T1.id)
  AND (T1.username LIKE '%1%')
RETURNING
  profile.age
```

```js
[
  {
    age: 11,
  },
]
```

ok 44 - Xodel.update update by where with foreignkey
## update returning foreignkey
```lua
profile:update { sex = 'm' }:where { id = 1 }:returning('id', 'usr_id__username'):exec()
```

```sql
UPDATE profile
SET
  sex = 'm'
FROM
  usr T1
WHERE
  (profile.id = 1)
  AND (profile.usr_id = T1.id)
RETURNING
  profile.id,
  T1.username AS usr_id__username
```

```js
[
  {
    id              : 1,
    usr_id__username: "u1",
  },
]
```

ok 45 - Xodel.update update returning foreignkey
# Xodel:updates(rows:table[], key?:string|string[], columns?:string[])
## updates partial
```lua
usr:updates({{permission=2, username ='u1'},{permission=3, username ='??'}}, 'username'):returning("*"):exec()
```

```sql
WITH
  V (permission, username) AS (
    VALUES
      (2::integer, 'u1'::varchar),
      (3, '??')
  )
UPDATE usr
SET
  permission = V.permission
FROM
  V
WHERE
  V.username = usr.username
RETURNING
  *
```

```js
[
  {
    id        : 1,
    permission: 2,
    username  : "u1",
  },
]
```

ok 46 - Xodel:updates(rows:table[], key?:string|string[], columns?:string[]) updates partial
## updates all
```lua
usr:updates({{permission=1, username ='u1'},{permission=3, username ='u3'}}, 'username'):returning("*"):exec()
```

```sql
WITH
  V (permission, username) AS (
    VALUES
      (1::integer, 'u1'::varchar),
      (3, 'u3')
  )
UPDATE usr
SET
  permission = V.permission
FROM
  V
WHERE
  V.username = usr.username
RETURNING
  *
```

```js
[
  {
    id        : 1,
    permission: 1,
    username  : "u1",
  },
  {
    id        : 3,
    permission: 3,
    username  : "u3",
  },
]
```

ok 47 - Xodel:updates(rows:table[], key?:string|string[], columns?:string[]) updates all
# Xodel.where
## where basic
```lua
 usr:select('username','id'):where{id=1}:exec()
```

```sql
SELECT
  usr.username,
  usr.id
FROM
  usr
WHERE
  usr.id = 1
```

```js
[
  {
    id      : 1,
    username: "u1",
  },
]
```

ok 48 - Xodel.where where basic
## where or
```lua
 usr:select('id'):where{id=1}:or_where{id=2}:order('id'):flat()
```

```sql
SELECT
  usr.id
FROM
  usr
WHERE
  usr.id = 1
  OR usr.id = 2
ORDER BY
  usr.id ASC
```

```js
[
  1,
  2,
]
```

ok 49 - Xodel.where where or
## and where or
```lua
 usr:select('id'):where{id=1}:where_or{id=2, username='u3'}:order('id'):flat()
```

```sql
SELECT
  usr.id
FROM
  usr
WHERE
  (usr.id = 1)
  AND (
    usr.id = 2
    OR usr.username = 'u3'
  )
ORDER BY
  usr.id ASC
```

```js
[

]
```

ok 50 - Xodel.where and where or
## or where and
```lua
 usr:select('id'):where{id=1}:or_where{id=2, username='u2'}:order('id'):flat()
```

```sql
SELECT
  usr.id
FROM
  usr
WHERE
  usr.id = 1
  OR usr.id = 2
  AND usr.username = 'u2'
ORDER BY
  usr.id ASC
```

```js
[
  1,
  2,
]
```

ok 51 - Xodel.where or where and
## or where or
```lua
 usr:select('id'):where{id=1}:or_where_or{id=2, username='u3'}:order('id'):flat()
```

```sql
SELECT
  usr.id
FROM
  usr
WHERE
  usr.id = 1
  OR usr.id = 2
  OR usr.username = 'u3'
ORDER BY
  usr.id ASC
```

```js
[
  1,
  2,
  3,
]
```

ok 52 - Xodel.where or where or
## where condition by 2 args
```lua
 usr:select('id'):where('id', 3):exec()
```

```sql
SELECT
  usr.id
FROM
  usr
WHERE
  usr.id = 3
```

```js
[
  {
    id: 3,
  },
]
```

ok 53 - Xodel.where where condition by 2 args
## where condition by 3 args
```lua
 usr:select('id'):where('id', '<',  3):flat()
```

```sql
SELECT
  usr.id
FROM
  usr
WHERE
  usr.id < 3
```

```js
[
  1,
  2,
]
```

ok 54 - Xodel.where where condition by 3 args
## where exists
```lua
usr:where_exists(usr:where{id=1})
```

```sql
SELECT
  *
FROM
  usr
WHERE
  EXISTS (
    SELECT
      *
    FROM
      usr
    WHERE
      usr.id = 1
  )
```

ok 55 - Xodel.where where exists
## where null
```lua
usr:where_null("username")
```

```sql
SELECT
  *
FROM
  usr
WHERE
  usr.username IS NULL
```

ok 56 - Xodel.where where null
## where in
```lua
usr:where_in("id", {1,2,3})
```

```sql
SELECT
  *
FROM
  usr
WHERE
  (usr.id) IN (1, 2, 3)
```

ok 57 - Xodel.where where in
## where between
```lua
usr:where_between("id", 2, 4)
```

```sql
SELECT
  *
FROM
  usr
WHERE
  usr.id BETWEEN 2 AND 4
```

ok 58 - Xodel.where where between
## where not
```lua
usr:where_not("username", "foo")
```

```sql
SELECT
  *
FROM
  usr
WHERE
  NOT (usr.username = 'foo')
```

ok 59 - Xodel.where where not
## where not null
```lua
usr:where_not_null("username")
```

```sql
SELECT
  *
FROM
  usr
WHERE
  usr.username IS NOT NULL
```

ok 60 - Xodel.where where not null
## where not in
```lua
usr:where_not_in("id", {1,2,3})
```

```sql
SELECT
  *
FROM
  usr
WHERE
  (usr.id) NOT IN (1, 2, 3)
```

ok 61 - Xodel.where where not in
## where not between
```lua
usr:where_not_between("id", 2, 4)
```

```sql
SELECT
  *
FROM
  usr
WHERE
  usr.id NOT BETWEEN 2 AND 4
```

ok 62 - Xodel.where where not between
## where not exists
```lua
usr:where_not_exists(usr:where{id=1})
```

```sql
SELECT
  *
FROM
  usr
WHERE
  NOT EXISTS (
    SELECT
      *
    FROM
      usr
    WHERE
      usr.id = 1
  )
```

ok 63 - Xodel.where where not exists
## where by arithmetic operator: __ne
```lua
usr:where{id__ne=2}:select('id')
```

```sql
SELECT
  usr.id
FROM
  usr
WHERE
  usr.id <> 2
```

ok 64 - Xodel.where where by arithmetic operator: __ne
## where by arithmetic operator: __lt
```lua
usr:where{id__lt=2}:select('id')
```

```sql
SELECT
  usr.id
FROM
  usr
WHERE
  usr.id < 2
```

ok 65 - Xodel.where where by arithmetic operator: __lt
## where by arithmetic operator: __lte
```lua
usr:where{id__lte=2}:select('id')
```

```sql
SELECT
  usr.id
FROM
  usr
WHERE
  usr.id <= 2
```

ok 66 - Xodel.where where by arithmetic operator: __lte
## where by arithmetic operator: __gt
```lua
usr:where{id__gt=2}:select('id')
```

```sql
SELECT
  usr.id
FROM
  usr
WHERE
  usr.id > 2
```

ok 67 - Xodel.where where by arithmetic operator: __gt
## where by arithmetic operator: __gte
```lua
usr:where{id__gte=2}:select('id')
```

```sql
SELECT
  usr.id
FROM
  usr
WHERE
  usr.id >= 2
```

ok 68 - Xodel.where where by arithmetic operator: __gte
## where by arithmetic operator: __eq
```lua
usr:where{id__eq=2}:select('id')
```

```sql
SELECT
  usr.id
FROM
  usr
WHERE
  usr.id = 2
```

ok 69 - Xodel.where where by arithmetic operator: __eq
## where in
```lua
usr:where{username__in={'u1','u2'}}
```

```sql
SELECT
  *
FROM
  usr
WHERE
  usr.username IN ('u1', 'u2')
```

ok 70 - Xodel.where where in
## where contains
```lua
usr:where{username__contains='u'}
```

```sql
SELECT
  *
FROM
  usr
WHERE
  usr.username LIKE '%u%'
```

ok 71 - Xodel.where where contains
## where startswith
```lua
usr:where{username__startswith='u'}
```

```sql
SELECT
  *
FROM
  usr
WHERE
  usr.username LIKE 'u%'
```

ok 72 - Xodel.where where startswith
## where endswith
```lua
usr:where{username__endswith='u'}
```

```sql
SELECT
  *
FROM
  usr
WHERE
  usr.username LIKE '%u'
```

ok 73 - Xodel.where where endswith
## where null true
```lua
usr:where{username__null=true}
```

```sql
SELECT
  *
FROM
  usr
WHERE
  usr.username IS NULL
```

ok 74 - Xodel.where where null true
## where null false
```lua
usr:where{username__null=false}
```

```sql
SELECT
  *
FROM
  usr
WHERE
  usr.username IS NOT NULL
```

ok 75 - Xodel.where where null false
## where notin
```lua
usr:where{username__notin={'u1','u2'}}
```

```sql
SELECT
  *
FROM
  usr
WHERE
  usr.username NOT IN ('u1', 'u2')
```

ok 76 - Xodel.where where notin
## where foreignkey eq
```lua
profile:where{usr_id__username__eq='u1'}
```

```sql
SELECT
  *
FROM
  profile
  INNER JOIN usr T1 ON (profile.usr_id = T1.id)
WHERE
  T1.username = 'u1'
```

ok 77 - Xodel.where where foreignkey eq
## where foreignkey in
```lua
profile:where{usr_id__username__in={'u1','u2'}}
```

```sql
SELECT
  *
FROM
  profile
  INNER JOIN usr T1 ON (profile.usr_id = T1.id)
WHERE
  T1.username IN ('u1', 'u2')
```

ok 78 - Xodel.where where foreignkey in
## where foreignkey contains
```lua
profile:where{usr_id__username__contains='u'}
```

```sql
SELECT
  *
FROM
  profile
  INNER JOIN usr T1 ON (profile.usr_id = T1.id)
WHERE
  T1.username LIKE '%u%'
```

ok 79 - Xodel.where where foreignkey contains
## where foreignkey startswith
```lua
profile:where{usr_id__username__startswith='u'}
```

```sql
SELECT
  *
FROM
  profile
  INNER JOIN usr T1 ON (profile.usr_id = T1.id)
WHERE
  T1.username LIKE 'u%'
```

ok 80 - Xodel.where where foreignkey startswith
## where foreignkey endswith
```lua
profile:where{usr_id__username__endswith='u'}
```

```sql
SELECT
  *
FROM
  profile
  INNER JOIN usr T1 ON (profile.usr_id = T1.id)
WHERE
  T1.username LIKE '%u'
```

ok 81 - Xodel.where where foreignkey endswith
## where foreignkey null true
```lua
profile:where{usr_id__username__null=true}
```

```sql
SELECT
  *
FROM
  profile
  INNER JOIN usr T1 ON (profile.usr_id = T1.id)
WHERE
  T1.username IS NULL
```

ok 82 - Xodel.where where foreignkey null true
## where foreignkey null false
```lua
profile:where{usr_id__username__null=false}
```

```sql
SELECT
  *
FROM
  profile
  INNER JOIN usr T1 ON (profile.usr_id = T1.id)
WHERE
  T1.username IS NOT NULL
```

ok 83 - Xodel.where where foreignkey null false
## where foreignkey number operator ne
```lua
profile:where{usr_id__permission__ne=2}
```

```sql
SELECT
  *
FROM
  profile
  INNER JOIN usr T1 ON (profile.usr_id = T1.id)
WHERE
  T1.permission <> 2
```

ok 84 - Xodel.where where foreignkey number operator ne
## where foreignkey number operator lt
```lua
profile:where{usr_id__permission__lt=2}
```

```sql
SELECT
  *
FROM
  profile
  INNER JOIN usr T1 ON (profile.usr_id = T1.id)
WHERE
  T1.permission < 2
```

ok 85 - Xodel.where where foreignkey number operator lt
## where foreignkey number operator lte
```lua
profile:where{usr_id__permission__lte=2}
```

```sql
SELECT
  *
FROM
  profile
  INNER JOIN usr T1 ON (profile.usr_id = T1.id)
WHERE
  T1.permission <= 2
```

ok 86 - Xodel.where where foreignkey number operator lte
## where foreignkey number operator gt
```lua
profile:where{usr_id__permission__gt=2}
```

```sql
SELECT
  *
FROM
  profile
  INNER JOIN usr T1 ON (profile.usr_id = T1.id)
WHERE
  T1.permission > 2
```

ok 87 - Xodel.where where foreignkey number operator gt
## where foreignkey number operator gte
```lua
profile:where{usr_id__permission__gte=2}
```

```sql
SELECT
  *
FROM
  profile
  INNER JOIN usr T1 ON (profile.usr_id = T1.id)
WHERE
  T1.permission >= 2
```

ok 88 - Xodel.where where foreignkey number operator gte
## where foreignkey number operator eq
```lua
profile:where{usr_id__permission__eq=2}
```

```sql
SELECT
  *
FROM
  profile
  INNER JOIN usr T1 ON (profile.usr_id = T1.id)
WHERE
  T1.permission = 2
```

ok 89 - Xodel.where where foreignkey number operator eq
# Xodel.select
## select fk column
```lua
profile:select('id', 'usr_id__username'):where { id = 1 }:exec()
```

```sql
SELECT
  profile.id,
  T1.username AS usr_id__username
FROM
  profile
  INNER JOIN usr T1 ON (profile.usr_id = T1.id)
WHERE
  profile.id = 1
```

```js
[
  {
    id              : 1,
    usr_id__username: "u1",
  },
]
```

ok 90 - Xodel.select select fk column
# Xodel:get(cond?, op?, dval?)
## basic
```lua
usr:get{id=3}
```

```sql
SELECT
  *
FROM
  usr
WHERE
  usr.id = 3
LIMIT
  2
```

```js
{
  id        : 3,
  permission: 3,
  username  : "u3",
}
```

ok 91 - Xodel:get(cond?, op?, dval?) basic
## model load foreign row
```sql
SELECT
  *
FROM
  profile
WHERE
  profile.id = 1
LIMIT
  2
```

ok 92 - Xodel:get(cond?, op?, dval?) model load foreign row
## fetch extra foreignkey field from database on demand
```sql
SELECT
  *
FROM
  usr
WHERE
  usr.id = 1
LIMIT
  2
```

ok 93 - Xodel:get(cond?, op?, dval?) fetch extra foreignkey field from database on demand

## model load foreign row with specified columns
```lua
profile:load_fk('usr_id', 'username', 'permission'):get{id=1}
```

```sql
SELECT
  profile.usr_id,
  T1.username AS usr_id__username,
  T1.permission AS usr_id__permission
FROM
  profile
  INNER JOIN usr T1 ON (profile.usr_id = T1.id)
WHERE
  profile.id = 1
LIMIT
  2
```

```js
{
  usr_id: {
    permission: 1,
    username  : "u1",
  },
}
```

ok 94 - Xodel:get(cond?, op?, dval?) model load foreign row with specified columns
## model load foreign row with all columns by *
```lua
profile:load_fk('usr_id', '*'):get{id=1}
```

```sql
SELECT
  profile.usr_id,
  profile.usr_id AS usr_id__id,
  T1.username AS usr_id__username,
  T1.permission AS usr_id__permission
FROM
  profile
  INNER JOIN usr T1 ON (profile.usr_id = T1.id)
WHERE
  profile.id = 1
LIMIT
  2
```

```js
{
  usr_id: {
    id        : 1,
    permission: 1,
    username  : "u1",
  },
}
```

```sql
SELECT
  *
FROM
  usr
WHERE
  usr.id = 1
LIMIT
  2
```

ok 95 - Xodel:get(cond?, op?, dval?) model load foreign row with all columns by *
## model load foreign row with specified columns two api are the same
```lua
profile:select("sex"):load_fk('usr_id', 'username', 'permission'):get{id=1}
```

```sql
SELECT
  profile.sex,
  profile.usr_id,
  T1.username AS usr_id__username,
  T1.permission AS usr_id__permission
FROM
  profile
  INNER JOIN usr T1 ON (profile.usr_id = T1.id)
WHERE
  profile.id = 1
LIMIT
  2
```

```js
{
  sex   : "m",
  usr_id: {
    permission: 1,
    username  : "u1",
  },
}
```

```lua
profile:select("sex"):load_fk('usr_id', {'username', 'permission'}):get{id=1}
```

```sql
SELECT
  profile.sex,
  profile.usr_id,
  T1.username AS usr_id__username,
  T1.permission AS usr_id__permission
FROM
  profile
  INNER JOIN usr T1 ON (profile.usr_id = T1.id)
WHERE
  profile.id = 1
LIMIT
  2
```

```js
{
  sex   : "m",
  usr_id: {
    permission: 1,
    username  : "u1",
  },
}
```

ok 96 - Xodel:get(cond?, op?, dval?) model load foreign row with specified columns two api are the same
## Xodel:get(cond?, op?, dval?)
```lua
usr:get{id__lt=3}
```

```sql
SELECT
  *
FROM
  usr
WHERE
  usr.id < 3
LIMIT
  2
```

ok 97 - Xodel:get(cond?, op?, dval?) Xodel:get(cond?, op?, dval?)
# Xodel:get_or_create(params:table, defaults?:table, columns?:string[])
## basic
```lua
usr:get_or_create{username='goc'}
```

```sql
WITH
  new_records (id, username) AS (
    INSERT INTO
      usr (username)
    SELECT
      'goc'
    WHERE
      NOT EXISTS (
        SELECT
          1
        FROM
          usr
        WHERE
          usr.username = 'goc'
      )
    RETURNING
      id,
      username
  )
SELECT
  id,
  username,
  TRUE AS __is_inserted__
FROM
  new_records AS new_records
UNION ALL
(
  SELECT
    id,
    username,
    FALSE AS __is_inserted__
  FROM
    usr
  WHERE
    usr.username = 'goc'
)
```

```js
{
  id      : 33,
  username: "goc",
}
```

ok 98 - Xodel:get_or_create(params:table, defaults?:table, columns?:string[]) basic
## model get_or_create with defaults
```lua
usr:get_or_create({username='goc2'}, {permission = 5})
```

```sql
WITH
  new_records (id, permission, username) AS (
    INSERT INTO
      usr (permission, username)
    SELECT
      5,
      'goc2'
    WHERE
      NOT EXISTS (
        SELECT
          1
        FROM
          usr
        WHERE
          usr.username = 'goc2'
      )
    RETURNING
      id,
      permission,
      username
  )
SELECT
  id,
  permission,
  username,
  TRUE AS __is_inserted__
FROM
  new_records AS new_records
UNION ALL
(
  SELECT
    id,
    permission,
    username,
    FALSE AS __is_inserted__
  FROM
    usr
  WHERE
    usr.username = 'goc2'
)
```

```js
{
  id        : 34,
  permission: 5,
  username  : "goc2",
}
```

ok 99 - Xodel:get_or_create(params:table, defaults?:table, columns?:string[]) model get_or_create with defaults
## test chat model
```sql
INSERT INTO
  message (creator, target, content)
VALUES
  (1, 2, 'c121'),
  (1, 2, 'c122'),
  (2, 1, 'c123'),
  (1, 3, 'c131'),
  (1, 3, 'c132'),
  (3, 1, 'c133'),
  (1, 3, 'c134'),
  (2, 3, 'c231')
RETURNING
  *
```

```sql
SELECT DISTINCT
  ON (
    CASE
      WHEN creator = 1 THEN target
      ELSE creator
    END
  ) message.creator,
  message.target,
  message.content
FROM
  message
WHERE
  message.creator = 1
  OR message.target = 1
ORDER BY
  CASE
    WHEN creator = 1 THEN target
    ELSE creator
  END,
  message.id DESC
```

ok 100 - Xodel api: test chat model
## where by exp
```sql
SELECT
  message.creator,
  message.target
FROM
  message
WHERE
  message.creator = 1
  and message.target = 2
  or message.creator = 2
  and message.target = 1
```

```sql
SELECT
  message.creator,
  message.target
FROM
  message
WHERE
  NOT (
    message.creator = 1
    or message.target = 2
  )
  AND NOT (
    message.creator = 2
    or message.target = 1
  )
```

ok 101 - Xodel api: where by exp
## go crazy with where clause with recursive join
```sql
INSERT INTO
  message (content, creator, target)
VALUES
  ('crazy', 1, 2)
RETURNING
  *
```

```sql
SELECT
  *
FROM
  profile
WHERE
  profile.id = 1
LIMIT
  2
```

```sql
SELECT
  *
FROM
  usr
WHERE
  usr.id = 1
LIMIT
  2
```

```sql
SELECT
  message.id,
  T1.age AS creator__age,
  T2.username AS creator__usr_id__username
FROM
  message
  INNER JOIN profile T1 ON (message.creator = T1.id)
  INNER JOIN usr T2 ON (T1.usr_id = T2.id)
WHERE
  T1.age = 11
  AND message.id = 9
  AND T2.username LIKE '%1%'
```

```sql
SELECT
  message.id,
  T1.age AS creator__age,
  T2.username AS creator__usr_id__username
FROM
  message
  INNER JOIN profile T1 ON (message.creator = T1.id)
  INNER JOIN usr T2 ON (T1.usr_id = T2.id)
WHERE
  message.id = 9
```

ok 102 - Xodel api: go crazy with where clause with recursive join
# etc
## wrong fk name
```lua
models.message:where {creator__usr_id__views=0}:exec()
```

ok 103 - etc wrong fk name
## wrong fk name3
```lua
models.message:select('creator__usr_id__views'):exec()
```

ok 104 - etc wrong fk name3
## test shortcuts join
```lua
profile:join('dept_name'):get { id = 1 }
```

```sql
SELECT
  *
FROM
  profile
  INNER JOIN dept dept ON (profile.dept_name = dept.name)
WHERE
  profile.id = 1
LIMIT
  2
```

```js
{
  age      : 11,
  dept_name: {
    name: "d1",
  },
  id       : 1,
  name     : "d1",
  salary   : 1000,
  sex      : "m",
  usr_id   : {
    id: 1,
  },
}
```

ok 105 - etc test shortcuts join
## sql select_as
```lua
usr:select_as('id', 'value'):select_as('username', 'label'):where { id = 2 }:exec()
```

```sql
SELECT
  usr.id AS value,
  usr.username AS label
FROM
  usr
WHERE
  usr.id = 2
```

```js
[
  {
    label: "u2",
    value: 2,
  },
]
```

ok 106 - etc sql select_as
## sql select_as foreignkey
```lua
profile:select_as('usr_id__permission', 'uperm'):where { id = 2 }:exec()
```

```sql
SELECT
  T1.permission AS uperm
FROM
  profile
  INNER JOIN usr T1 ON (profile.usr_id = T1.id)
WHERE
  profile.id = 2
```

```js
[
  {
    uperm: 3,
  },
]
```

ok 107 - etc sql select_as foreignkey
# sql injection
## where key
ok 108 - sql injection where key
## where value
```sql
SELECT
  *
FROM
  usr
WHERE
  usr.id = '1 or 1=1'
```

ok 109 - sql injection where value
## order
ok 110 - sql injection order
## select
ok 111 - sql injection select
# Xodel:delete(cond?, op?, dval?)
## model class delete all
```lua
evaluate:delete{}:exec()
```

```sql
DELETE FROM evaluate
```

```js
{
  affected_rows: 4,
}
```

ok 112 - Xodel:delete(cond?, op?, dval?) model class delete all
## model instance delete
```sql
DELETE FROM message
```

```sql
DELETE FROM message
```

```sql
SELECT
  *
FROM
  profile
WHERE
  profile.id = 1
LIMIT
  2
```

```lua
du:delete()
```

```sql
DELETE FROM profile
WHERE
  profile.id = 1
RETURNING
  profile.id
```

```js
[
  {
    id: 1,
  },
]
```

ok 113 - Xodel:delete(cond?, op?, dval?) model instance delete
## model instance delete use non primary key
```sql
SELECT
  *
FROM
  usr
WHERE
  usr.id = 1
LIMIT
  2
```

```lua
du:delete('username')
```

```sql
DELETE FROM usr
WHERE
  usr.username = 'u1'
RETURNING
  usr.username
```

```js
[
  {
    username: "u1",
  },
]
```

ok 114 - Xodel:delete(cond?, op?, dval?) model instance delete use non primary key
## create with foreign model returning all
```sql
SELECT
  *
FROM
  usr
WHERE
  usr.id = 3
LIMIT
  2
```

```lua
profile:returning("*"):create{usr_id=u, age=12}
```

```sql
INSERT INTO
  profile (usr_id, dept_name, age, sex, salary)
VALUES
  (3, DEFAULT, 12, 'f', 1000)
RETURNING
  *
```

```js
[
  {
    age   : 12,
    id    : 4,
    salary: 1000,
    sex   : "f",
    usr_id: 3,
  },
]
```

ok 115 - Xodel:delete(cond?, op?, dval?) create with foreign model returning all
## insert from delete returning
```sql
SELECT
  *
FROM
  usr
WHERE
  usr.id = 2
LIMIT
  2
```

```lua
log:returning("*"):create(
      profile:delete { id = 2 }:returning('id'):returning_literal("usr", "delete"),
      { 'delete_id', 'model_name', "action" })
```

```sql
WITH
  d (delete_id, model_name, action) AS (
    DELETE FROM profile
    WHERE
      profile.id = 2
    RETURNING
      profile.id,
      'usr',
      'delete'
  )
INSERT INTO
  log(delete_id, model_name, action)
SELECT
  delete_id,
  model_name,
  action
FROM
  d
RETURNING
  *
```

```js
[
  {
    action    : "delete",
    delete_id : 2,
    id        : 1,
    model_name: "usr",
  },
]
```