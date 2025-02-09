$ resty -I lib -I resty_modules/lualib -I resty_modules/site/lualib --main-conf 'env NODE_ENV;' --http-conf 'lua_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;' -I spec ngx_busted.lua -o TAP

DROP TABLE IF EXISTS profile CASCADE
DROP TABLE IF EXISTS org_admin CASCADE
DROP TABLE IF EXISTS org CASCADE
DROP TABLE IF EXISTS usr_bak CASCADE
DROP TABLE IF EXISTS usr CASCADE
CREATE TABLE usr(
  name varchar(5) NOT NULL UNIQUE,
  id SERIAL PRIMARY KEY NOT NULL,
  permission integer DEFAULT 0
)
CREATE TABLE usr_bak(
  name varchar(5) NOT NULL UNIQUE,
  id SERIAL PRIMARY KEY NOT NULL,
  permission integer DEFAULT 0
)
CREATE TABLE org(
  id SERIAL PRIMARY KEY NOT NULL,
  name varchar(10) NOT NULL UNIQUE
)
CREATE TABLE org_admin(
  id SERIAL PRIMARY KEY NOT NULL,
  org integer REFERENCES "org" ("id") ON DELETE CASCADE ON UPDATE CASCADE ,
  usr integer REFERENCES "usr" ("id") ON DELETE CASCADE ON UPDATE CASCADE 
)
CREATE TABLE profile(
  id SERIAL PRIMARY KEY NOT NULL,
  usr integer REFERENCES "usr" ("id") ON DELETE CASCADE ON UPDATE CASCADE ,
  parent integer REFERENCES "profile" ("id") ON DELETE CASCADE ON UPDATE CASCADE ,
  child integer REFERENCES "profile" ("id") ON DELETE CASCADE ON UPDATE CASCADE ,
  age integer DEFAULT 1
)

INSERT INTO usr AS T (name, permission) VALUES ('u1', 1)
ok 1 - test insert insert one user

INSERT INTO usr AS T (name, permission) VALUES ('u2', 2) RETURNING *
ok 2 - test insert insert one user returning all

INSERT INTO usr AS T (name, permission) VALUES ('u3', 0) RETURNING T.permission
ok 3 - test insert insert one user using default

INSERT INTO usr AS T (name, permission) VALUES ('u4', 0), ('u5', 0) RETURNING T.name, T.permission
ok 4 - test insert insert two users

INSERT INTO usr AS T (name, permission) VALUES ('u6', 2) RETURNING T.name
ok 5 - test insert insert one user returning id in compact form

INSERT INTO usr AS T (name, permission) VALUES ('u7', 0), ('u8', 0) RETURNING T.name
ok 6 - test insert insert two users returning id in compact form

INSERT INTO usr_bak AS T (name, permission) SELECT T.name, T.permission FROM usr T WHERE T.permission = 2 RETURNING T.name, T.permission
SELECT T.name, T.permission FROM usr T WHERE T.permission = 2
ok 7 - test insert insert bak users from select subquery

SELECT T.name, T.permission FROM usr T WHERE T.permission = 1
WITH D(name, permission) AS (DELETE FROM usr T WHERE T.permission = 1 RETURNING T.name, T.permission) INSERT INTO usr_bak AS T (name, permission) SELECT name, permission FROM D RETURNING T.name, T.permission
ok 8 - test insert insert bak users from delete subquery

SELECT T.name, 3 AS permission FROM usr_bak T WHERE T.permission = 1
WITH D(name, permission) AS (DELETE FROM usr_bak T WHERE T.permission = 1 RETURNING T.name, 3) INSERT INTO usr AS T (name, permission) SELECT name, permission FROM D RETURNING T.name, T.permission
ok 9 - test insert insert users from delete subquery with specified columns

WITH D(name, permission) AS (UPDATE usr T SET permission = 3 WHERE T.permission = 1 RETURNING T.name, T.permission) INSERT INTO usr_bak AS T (name, permission) SELECT name, permission FROM D RETURNING T.name, T.permission
UPDATE usr T SET permission = 3 WHERE T.permission = 1 RETURNING T.name, T.permission
ok 10 - test insert insert bak users from update subquery

ok 11 - test insert insert one user validate required failed

ok 12 - test insert insert one user validate choices failed

ok 13 - test insert insert one user validate maxlength failed

ok 14 - test insert insert two users validate required failed at 2nd row

ok 15 - test insert insert two users validate maxlength failed at 2nd row

ok 16 - test insert insert two users validate choices failed at 1st row

ok 17 - test insert insert user skip validate
ok 18 - test insert update user skip validate

ok 19 - test insert insert one user with invalid columns

INSERT INTO profile AS T (usr, parent, child, age) VALUES (2, NULL, NULL, 82), (3, NULL, NULL, 62), (4, NULL, NULL, 42), (5, NULL, NULL, 52), (6, NULL, NULL, 32), (7, NULL, NULL, 12)
UPDATE profile T SET child = 2 WHERE T.usr = 2
UPDATE profile T SET parent = 1, child = 3 WHERE T.usr = 3
UPDATE profile T SET parent = 2 WHERE T.usr = 4
UPDATE profile T SET child = 5 WHERE T.usr = 5
UPDATE profile T SET parent = 4, child = 6 WHERE T.usr = 6
UPDATE profile T SET parent = 5 WHERE T.usr = 7
INSERT INTO org AS T (name) VALUES ('o1'), ('o2'), ('o3')
INSERT INTO org_admin AS T (org, usr) VALUES (1, 2), (2, 3), (3, 4)

SELECT T.id, T.permission FROM usr T
SELECT T.id, T.permission FROM usr T
ok 20 - test select where simple select

SELECT T1.age AS parent__age FROM profile T INNER JOIN profile T1 ON (T.parent = T1.id) ORDER BY T1.age ASC
ok 21 - test select where select auto join

SELECT T2.age AS parent__parent__age FROM profile T INNER JOIN profile T1 ON (T.parent = T1.id) INNER JOIN profile T2 ON (T1.parent = T2.id) ORDER BY T2.age ASC
ok 22 - test select where select auto join depth 2

SELECT T.usr, T1.age AS parent__age, T2.age AS parent__parent__age FROM profile T INNER JOIN profile T1 ON (T.parent = T1.id) INNER JOIN profile T2 ON (T1.parent = T2.id) ORDER BY T.usr ASC
ok 23 - test select where select auto join depth 2

SELECT T.usr FROM profile T INNER JOIN profile T1 ON (T.parent = T1.id) WHERE T1.age = 32 LIMIT 2
ok 24 - test select where where auto join

SELECT T1.name AS usr__name FROM profile T INNER JOIN usr T1 ON (T.usr = T1.id) INNER JOIN profile T2 ON (T.parent = T2.id) INNER JOIN profile T3 ON (T2.parent = T3.id) WHERE T3.age = 82 LIMIT 2
ok 25 - test select where where auto join depth 2 and diffent join tables

SELECT T1.name AS usr__name, T2.name AS org__name FROM org_admin T INNER JOIN usr T1 ON (T.usr = T1.id) INNER JOIN org T2 ON (T.org = T2.id) WHERE T2.name = 'o3'
ok 26 - test select where where auto join different tables

```sql
DROP TABLE IF EXISTS log3 CASCADE
```

```sql
DROP TABLE IF EXISTS log2 CASCADE
```

```sql
DROP TABLE IF EXISTS log CASCADE
```

```sql
DROP TABLE IF EXISTS evaluate CASCADE
```

```sql
DROP TABLE IF EXISTS message CASCADE
```

```sql
DROP TABLE IF EXISTS profile CASCADE
```

```sql
DROP TABLE IF EXISTS dept CASCADE
```

```sql
DROP TABLE IF EXISTS usr CASCADE
```

```sql
CREATE TABLE usr(
  id SERIAL PRIMARY KEY NOT NULL,
  username varchar(5) NOT NULL UNIQUE,
  permission integer DEFAULT 0
)
```

```sql
CREATE TABLE dept(
  id SERIAL PRIMARY KEY NOT NULL,
  name varchar(10) NOT NULL UNIQUE
)
```

```sql
CREATE TABLE profile(
  id SERIAL PRIMARY KEY NOT NULL,
  usr_id integer REFERENCES "usr" ("id") ON DELETE CASCADE ON UPDATE CASCADE ,
  dept_name varchar(10) REFERENCES "dept" ("name") ON DELETE CASCADE ON UPDATE CASCADE ,
  age integer NOT NULL DEFAULT 0,
  sex varchar(256) NOT NULL DEFAULT 'f',
  salary float DEFAULT 1000
)
```

```sql
CREATE TABLE message(
  id SERIAL PRIMARY KEY NOT NULL,
  ctime timestamp(0) WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  utime timestamp(0) WITH TIME ZONE ,
  creator integer REFERENCES "profile" ("id") ON DELETE CASCADE ON UPDATE CASCADE ,
  target integer REFERENCES "profile" ("id") ON DELETE CASCADE ON UPDATE CASCADE ,
  content varchar(100) NOT NULL DEFAULT ''
)
```

```sql
CREATE TABLE evaluate(
  id SERIAL PRIMARY KEY NOT NULL,
  ctime timestamp(0) WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  utime timestamp(0) WITH TIME ZONE ,
  usr_id integer REFERENCES "usr" ("id") ON DELETE CASCADE ON UPDATE CASCADE ,
  year integer ,
  rank varchar(1) NOT NULL DEFAULT 'C',
  UNIQUE(usr_id, year)
)
```

```sql
CREATE TABLE log(
  id SERIAL PRIMARY KEY NOT NULL,
  delete_id integer DEFAULT 0,
  model_name varchar(20) NOT NULL DEFAULT '',
  action varchar(10) NOT NULL DEFAULT ''
)
```

```sql
CREATE TABLE log2(
  id SERIAL PRIMARY KEY NOT NULL,
  buyer integer REFERENCES "usr" ("id") ON DELETE CASCADE ON UPDATE CASCADE ,
  seller integer REFERENCES "usr" ("id") ON DELETE CASCADE ON UPDATE CASCADE 
)
```

```sql
CREATE TABLE log3(
  id SERIAL PRIMARY KEY NOT NULL,
  start_log integer REFERENCES "log2" ("id") ON DELETE CASCADE ON UPDATE CASCADE ,
  end_log integer REFERENCES "log2" ("id") ON DELETE CASCADE ON UPDATE CASCADE 
)
```

# Xodel:insert(rows:table|table[]|Sql, columns?:string[])

## insert one user
```lua
 usr:insert{permission=1, username ='u1'}:exec() 
```

```sql
INSERT INTO
  usr AS T (username, permission)
VALUES
  ('u1', 1)
```

```js
{
  affected_rows: 1,
}
```

ok 27 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) insert one user
## insert one user returning one column
```lua
 usr:insert{permission=1, username ='u2'}:returning('permission'):exec() 
```

```sql
INSERT INTO
  usr AS T (username, permission)
VALUES
  ('u2', 1)
RETURNING
  T.permission
```

```js
[
  {
    permission: 1,
  },
]
```

ok 28 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) insert one user returning one column
## insert one user with default permission
```lua
 usr:insert{username ='u3'}:returning('permission'):exec() 
```

```sql
INSERT INTO
  usr AS T (username, permission)
VALUES
  ('u3', 0)
RETURNING
  T.permission
```

```js
[
  {
    permission: 0,
  },
]
```

ok 29 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) insert one user with default permission
## insert one user returning two columns
```lua
 usr:insert{permission=1, username ='u4'}:returning('permission','username'):exec() 
```

```sql
INSERT INTO
  usr AS T (username, permission)
VALUES
  ('u4', 1)
RETURNING
  T.permission,
  T.username
```

```js
[
  {
    permission: 1,
    username  : "u4",
  },
]
```

ok 30 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) insert one user returning two columns
## insert one user returning one column in compact form
```lua
 usr:insert{permission=1, username ='u5'}:returning('username'):compact():exec() 
```

```sql
INSERT INTO
  usr AS T (username, permission)
VALUES
  ('u5', 1)
RETURNING
  T.username
```

```js
[
  [
    "u5",
  ],
]
```

ok 31 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) insert one user returning one column in compact form
## insert two users
```lua
 usr:insert{{permission=1, username ='u6'}, {permission=1, username ='u7'}}:exec() 
```

```sql
INSERT INTO
  usr AS T (username, permission)
VALUES
  ('u6', 1),
  ('u7', 1)
```

```js
{
  affected_rows: 2,
}
```

ok 32 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) insert two users
## insert two users returning one column
```lua
 usr:insert{{permission=1, username ='u8'}, {permission=1, username ='u9'}}:returning('username'):exec() 
```

```sql
INSERT INTO
  usr AS T (username, permission)
VALUES
  ('u8', 1),
  ('u9', 1)
RETURNING
  T.username
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

ok 33 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) insert two users returning one column
## insert two users returning two columns
```lua
 usr:insert{{permission=2, username ='u10'}, {permission=3, username ='u11'}}:returning('username','permission'):exec() 
```

```sql
INSERT INTO
  usr AS T (username, permission)
VALUES
  ('u10', 2),
  ('u11', 3)
RETURNING
  T.username,
  T.permission
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

ok 34 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) insert two users returning two columns
## insert two users returning one column in flatten form
```lua
 usr:insert{{permission=1, username ='u12'}, {permission=1, username ='u13'}}:returning('username'):flat() 
```

```sql
INSERT INTO
  usr AS T (username, permission)
VALUES
  ('u12', 1),
  ('u13', 1)
RETURNING
  T.username
```

```js
[
  "u12",
  "u13",
]
```

ok 35 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) insert two users returning one column in flatten form
## insert two users returning two columns in flatten form
```lua
 usr:insert{{permission=1, username ='u14'}, {permission=2, username ='u15'}}:returning('username','permission'):flat() 
```

```sql
INSERT INTO
  usr AS T (username, permission)
VALUES
  ('u14', 1),
  ('u15', 2)
RETURNING
  T.username,
  T.permission
```

```js
[
  "u14",
  1,
  "u15",
  2,
]
```

ok 36 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) insert two users returning two columns in flatten form
## insert one user with specific columns (permission being ignored)
```lua
 usr:insert({permission=4, username ='u16'}, {'username'}):returning('username','permission'):exec() 
```

```sql
INSERT INTO
  usr AS T (username)
VALUES
  ('u16')
RETURNING
  T.username,
  T.permission
```

```js
[
  {
    permission: 0,
    username  : "u16",
  },
]
```

ok 37 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) insert one user with specific columns (permission being ignored)
## insert one user with specific columns
```lua
 usr:insert({permission=4, username ='u17'}, {'username', 'permission'}):returning('username','permission'):exec() 
```

```sql
INSERT INTO
  usr AS T (username, permission)
VALUES
  ('u17', 4)
RETURNING
  T.username,
  T.permission
```

```js
[
  {
    permission: 4,
    username  : "u17",
  },
]
```

ok 38 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) insert one user with specific columns
## insert two users with specific columns (permission being ignored)
```lua
 usr:insert({{permission=4, username ='u18'},{permission=5, username ='u19'}}, {'username'}):returning('username','permission'):exec() 
```

```sql
INSERT INTO
  usr AS T (username)
VALUES
  ('u18'),
  ('u19')
RETURNING
  T.username,
  T.permission
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

ok 39 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) insert two users with specific columns (permission being ignored)
## insert two users with specific columns
```lua
 usr:insert({{permission=4, username ='u20'},{permission=5, username ='u21'}}, {'username', 'permission'}):returning('username','permission'):exec() 
```

```sql
INSERT INTO
  usr AS T (username, permission)
VALUES
  ('u20', 4),
  ('u21', 5)
RETURNING
  T.username,
  T.permission
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

ok 40 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) insert two users with specific columns
## insert users with default permission
```lua
 usr:insert{{username ='f1'},{username ='f2'}}:flat('permission') 
```

```sql
INSERT INTO
  usr AS T (username, permission)
VALUES
  ('f1', 0),
  ('f2', 0)
RETURNING
  T.permission
```

```js
[
  0,
  0,
]
```

ok 41 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) insert users with default permission
## insert one user validate required failed
ok 42 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) insert one user validate required failed
## insert one user validate maxlength failed
ok 43 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) insert one user validate maxlength failed
## insert one user validate max failed
ok 44 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) insert one user validate max failed
## insert two users validate max failed
ok 45 - Xodel:insert(rows:table|table[]|Sql, columns?:string[]) insert two users validate max failed
# Xodel:insert
## create
```lua
dept:insert{name ='d1'}:returning('*'):execr()
```

```sql
INSERT INTO
  dept AS T (name)
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

ok 46 - Xodel:insert create
## create multiple rows
```lua
dept:insert{{name ='d2'}, {name ='d3'}}:returning('name'):execr()
```

```sql
INSERT INTO
  dept AS T (name)
VALUES
  ('d2'),
  ('d3')
RETURNING
  T.name
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

ok 47 - Xodel:insert create multiple rows
# Xodel:count(cond?, op?, dval?)
## specify condition
```lua
usr:count{id__lt=3}
```

```sql
SELECT
  count(*)
FROM
  usr T
WHERE
  T.id < 3
```

```js
2
```

ok 48 - Xodel:count(cond?, op?, dval?) specify condition
## test with Xodel:all
```lua
dept:execr()
```

```sql
SELECT
  *
FROM
  dept T
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
  dept T
```

```js
3
```

ok 49 - Xodel:count(cond?, op?, dval?) test with Xodel:all
# XodelInstance:save(names?:string[], key?:string)
## save basic
```lua
profile{usr_id=1, dept_name='d1', age=20}:save()
```

```sql
INSERT INTO
  profile AS T (age, salary, usr_id, sex, dept_name)
VALUES
  (20, 1000, 1, 'f', 'd1')
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

ok 50 - XodelInstance:save(names?:string[], key?:string) save basic
## save with specific names
```lua
profile{usr_id=2, dept_name='d2', salary=500, sex='m', age=50}:save{'usr_id','dept_name'}
```

```sql
INSERT INTO
  profile AS T (dept_name, usr_id)
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

ok 51 - XodelInstance:save(names?:string[], key?:string) save with specific names
## save with primary key specified to update
```lua
profile{id=1, age=33}:save()
```

```sql
UPDATE profile T
SET
  age = 33
WHERE
  T.id = 1
RETURNING
  id
```

```js
{
  age: 33,
  id : 1,
}
```

ok 52 - XodelInstance:save(names?:string[], key?:string) save with primary key specified to update
## save with primary key ignored and force create
```lua
profile{id=5, age=55, usr_id=3, dept_name='d3',}:save_create()
```

```sql
INSERT INTO
  profile AS T (age, salary, usr_id, sex, dept_name)
VALUES
  (55, 1000, 3, 'f', 'd3')
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

ok 53 - XodelInstance:save(names?:string[], key?:string) save with primary key ignored and force create
## save with wrong name
```lua
profile{usr_id=1, dept_name='d1', age=20}:save{'xxxx'}
```

ok 54 - XodelInstance:save(names?:string[], key?:string) save with wrong name
# Xodel:merge(rows:table[], key?:string|string[], columns?:string[])
## merge multiple rows returning inserted rows with all columns
```lua
usr:merge({{permission=4, username ='u1'},{permission=2, username ='u22'}}, 'username'):returning('*'):exec()
```

```sql
WITH
  V (username, permission) AS (
    VALUES
      ('u1'::varchar, 4::integer),
      ('u22', 2)
  ),
  U AS (
    UPDATE usr W
    SET
      permission = V.permission
    FROM
      V
    WHERE
      V.username = W.username
    RETURNING
      V.username,
      V.permission
  )
INSERT INTO
  usr AS T (username, permission)
SELECT
  V.username,
  V.permission
FROM
  V
  LEFT JOIN U AS W ON (V.username = W.username)
WHERE
  W.username IS NULL
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

ok 55 - Xodel:merge(rows:table[], key?:string|string[], columns?:string[]) merge multiple rows returning inserted rows with all columns
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
      INNER JOIN usr AS W ON (V.username = W.username)
  )
INSERT INTO
  usr AS T (username)
SELECT
  V.username
FROM
  V
  LEFT JOIN U AS W ON (V.username = W.username)
WHERE
  W.username IS NULL
RETURNING
  T.username
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

ok 56 - Xodel:merge(rows:table[], key?:string|string[], columns?:string[]) merge multiple rows returning inserted rows with specific columns
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
      INNER JOIN usr AS W ON (V.username = W.username)
  )
INSERT INTO
  usr AS T (username)
SELECT
  V.username
FROM
  V
  LEFT JOIN U AS W ON (V.username = W.username)
WHERE
  W.username IS NULL
RETURNING
  T.username
```

```js
[
  "u25",
  "u26",
]
```

ok 57 - Xodel:merge(rows:table[], key?:string|string[], columns?:string[]) merge multiple rows returning inserted rows with specific columns in compact form
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
    UPDATE evaluate W
    SET
      rank = V.rank
    FROM
      V
    WHERE
      V.usr_id = W.usr_id
      AND V.year = W.year
    RETURNING
      V.year,
      V.usr_id,
      V.rank
  )
INSERT INTO
  evaluate AS T (year, usr_id, rank)
SELECT
  V.year,
  V.usr_id,
  V.rank
FROM
  V
  LEFT JOIN U AS W ON (
    V.usr_id = W.usr_id
    AND V.year = W.year
  )
WHERE
  W.usr_id IS NULL
RETURNING
  T.rank
```

```js
[
  "A",
  "B",
]
```

ok 58 - Xodel:merge(rows:table[], key?:string|string[], columns?:string[]) merge multiple rows returning inserted rows with array key
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
      INNER JOIN evaluate AS W ON (
        V.usr_id = W.usr_id
        AND V.year = W.year
      )
  )
INSERT INTO
  evaluate AS T (usr_id, year)
SELECT
  V.usr_id,
  V.year
FROM
  V
  LEFT JOIN U AS W ON (
    V.usr_id = W.usr_id
    AND V.year = W.year
  )
WHERE
  W.usr_id IS NULL
RETURNING
  T.rank
```

```js
[
  "C",
  "C",
]
```

ok 59 - Xodel:merge(rows:table[], key?:string|string[], columns?:string[]) merge multiple rows returning inserted rows with array key and specific columns
## merge multiple rows validate max failed
ok 60 - Xodel:merge(rows:table[], key?:string|string[], columns?:string[]) merge multiple rows validate max failed
## merge multiple rows missing default unique value failed
ok 61 - Xodel:merge(rows:table[], key?:string|string[], columns?:string[]) merge multiple rows missing default unique value failed
# Xodel:upsert(rows:table[], key?:string|string[], columns?:string[])
## upsert multiple rows returning inserted rows with all columns
```lua
usr:upsert({{permission=4, username ='u1'},{permission=2, username ='u27'}}, 'username'):returning('username'):exec()
```

```sql
INSERT INTO
  usr AS T (username, permission)
VALUES
  ('u1', 4),
  ('u27', 2)
ON CONFLICT (username) DO
UPDATE
SET
  permission = EXCLUDED.permission
RETURNING
  T.username
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

ok 62 - Xodel:upsert(rows:table[], key?:string|string[], columns?:string[]) upsert multiple rows returning inserted rows with all columns
## upsert multiple rows returning inserted rows with specific columns in compact form
```lua
usr:upsert({{username ='u28'},{username ='u29'}}, 'username'):returning('username'):flat()
```

```sql
INSERT INTO
  usr AS T (username)
VALUES
  ('u28'),
  ('u29')
ON CONFLICT (username) DO NOTHING
RETURNING
  T.username
```

```js
[
  "u28",
  "u29",
]
```

ok 63 - Xodel:upsert(rows:table[], key?:string|string[], columns?:string[]) upsert multiple rows returning inserted rows with specific columns in compact form
## upsert multiple rows returning inserted rows with array key
```lua
evaluate:upsert({{usr_id=1, year=2021, rank='A'},{usr_id=1, year=2022, rank='B'}}, {'usr_id', 'year'}):returning('rank'):flat()
```

```sql
INSERT INTO
  evaluate AS T (year, usr_id, rank)
VALUES
  (2021, 1, 'A'),
  (2022, 1, 'B')
ON CONFLICT (usr_id, year) DO
UPDATE
SET
  rank = EXCLUDED.rank
RETURNING
  T.rank
```

```js
[
  "A",
  "B",
]
```

ok 64 - Xodel:upsert(rows:table[], key?:string|string[], columns?:string[]) upsert multiple rows returning inserted rows with array key
## upsert multiple rows validate max failed
ok 65 - Xodel:upsert(rows:table[], key?:string|string[], columns?:string[]) upsert multiple rows validate max failed
# Xodel.update
## update one user
```lua
 usr:update{permission=2}:where{id=1}:exec() 
```

```sql
UPDATE usr T
SET
  permission = 2
WHERE
  T.id = 1
```

```js
{
  affected_rows: 1,
}
```

ok 66 - Xodel.update update one user

## update one user returning one column
```lua
 usr:update{permission=3}:where{id=1}:returning('permission'):exec() 
```

```sql
UPDATE usr T
SET
  permission = 3
WHERE
  T.id = 1
RETURNING
  T.permission
```

```js
[
  {
    permission: 3,
  },
]
```

ok 67 - Xodel.update update one user returning one column
## update users returning two columns in table form
```lua
 usr:update{permission=3}:where{id__lt=3}:returning{'permission','id'}:exec() 
```

```sql
UPDATE usr T
SET
  permission = 3
WHERE
  T.id < 3
RETURNING
  T.permission,
  T.id
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

ok 68 - Xodel.update update users returning two columns in table form
## update users returning one column in flatten form
```lua
 usr:update{permission=3}:where{id__lt=3}:returning{'username'}:flat() 
```

```sql
UPDATE usr T
SET
  permission = 3
WHERE
  T.id < 3
RETURNING
  T.username
```

```js
[
  "u1",
  "u2",
]
```

ok 69 - Xodel.update update users returning one column in flatten form
## update by where with foreignkey
```lua
profile:update{age=11}:where{usr_id__username__contains='1'}:returning('age'):exec()
```

```sql
UPDATE profile T
SET
  age = 11
FROM
  usr T1
WHERE
  (T1.username LIKE '%1%')
  AND (T.usr_id = T1.id)
RETURNING
  T.age
```

```js
[
  {
    age: 11,
  },
]
```

ok 70 - Xodel.update update by where with foreignkey
## update returning foreignkey
```lua
profile:update { sex = 'm' }:where { id = 1 }:returning('id', 'usr_id__username'):exec()
```

```sql
UPDATE profile T
SET
  sex = 'm'
FROM
  usr T1
WHERE
  (T.id = 1)
  AND (T.usr_id = T1.id)
RETURNING
  T.id,
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

ok 71 - Xodel.update update returning foreignkey
# Xodel:updates(rows:table[], key?:string|string[], columns?:string[])
## updates partial
```lua
usr:updates({{permission=2, username ='u1'},{permission=3, username ='??'}}, 'username'):returning("*"):exec()
```

```sql
WITH
  V (username, permission) AS (
    VALUES
      ('u1'::varchar, 2::integer),
      ('??', 3)
  )
UPDATE usr T
SET
  permission = V.permission
FROM
  V
WHERE
  V.username = T.username
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

ok 72 - Xodel:updates(rows:table[], key?:string|string[], columns?:string[]) updates partial
## updates all
```lua
usr:updates({{permission=1, username ='u1'},{permission=3, username ='u3'}}, 'username'):returning("*"):exec()
```

```sql
WITH
  V (username, permission) AS (
    VALUES
      ('u1'::varchar, 1::integer),
      ('u3', 3)
  )
UPDATE usr T
SET
  permission = V.permission
FROM
  V
WHERE
  V.username = T.username
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

ok 73 - Xodel:updates(rows:table[], key?:string|string[], columns?:string[]) updates all
# Xodel.where
## where basic
```lua
 usr:select('username','id'):where{id=1}:exec() 
```

```sql
SELECT
  T.username,
  T.id
FROM
  usr T
WHERE
  T.id = 1
```

```js
[
  {
    id      : 1,
    username: "u1",
  },
]
```

ok 74 - Xodel.where where basic
## where or
```lua
 usr:select('id'):where{id=1}:or_where{id=2}:order('id'):flat() 
```

```sql
SELECT
  T.id
FROM
  usr T
WHERE
  T.id = 1
  OR T.id = 2
ORDER BY
  T.id ASC
```

```js
[
  1,
  2,
]
```

ok 75 - Xodel.where where or
## and where or
```lua
 usr:select('id'):where{id=1}:where_or{id=2, username='u3'}:order('id'):flat() 
```

```sql
SELECT
  T.id
FROM
  usr T
WHERE
  (T.id = 1)
  AND (
    T.id = 2
    OR T.username = 'u3'
  )
ORDER BY
  T.id ASC
```

```js
[

]
```

ok 76 - Xodel.where and where or
## or where and
```lua
 usr:select('id'):where{id=1}:or_where{id=2, username='u2'}:order('id'):flat() 
```

```sql
SELECT
  T.id
FROM
  usr T
WHERE
  T.id = 1
  OR T.id = 2
  AND T.username = 'u2'
ORDER BY
  T.id ASC
```

```js
[
  1,
  2,
]
```

ok 77 - Xodel.where or where and
## or where or
```lua
 usr:select('id'):where{id=1}:or_where_or{id=2, username='u3'}:order('id'):flat() 
```

```sql
SELECT
  T.id
FROM
  usr T
WHERE
  T.id = 1
  OR T.id = 2
  OR T.username = 'u3'
ORDER BY
  T.id ASC
```

```js
[
  1,
  2,
  3,
]
```

ok 78 - Xodel.where or where or
## where condition by 2 args
```lua
 usr:select('id'):where('id', 3):exec() 
```

```sql
SELECT
  T.id
FROM
  usr T
WHERE
  T.id = 3
```

```js
[
  {
    id: 3,
  },
]
```

ok 79 - Xodel.where where condition by 2 args
## where condition by 3 args
```lua
 usr:select('id'):where('id', '<',  3):flat() 
```

```sql
SELECT
  T.id
FROM
  usr T
WHERE
  T.id < 3
```

```js
[
  1,
  2,
]
```

ok 80 - Xodel.where where condition by 3 args
## where exists
```lua
usr:where_exists(usr:where{id=1})
```

```sql
SELECT
  *
FROM
  usr T
WHERE
  EXISTS (
    SELECT
      *
    FROM
      usr T
    WHERE
      T.id = 1
  )
```

ok 81 - Xodel.where where exists
## where null
```lua
usr:where_null("username")
```

```sql
SELECT
  *
FROM
  usr T
WHERE
  T.username IS NULL
```

ok 82 - Xodel.where where null
## where in
```lua
usr:where_in("id", {1,2,3})
```

```sql
SELECT
  *
FROM
  usr T
WHERE
  (T.id) IN (1, 2, 3)
```

ok 83 - Xodel.where where in
## where between
```lua
usr:where_between("id", 2, 4)
```

```sql
SELECT
  *
FROM
  usr T
WHERE
  T.id BETWEEN 2 AND 4
```

ok 84 - Xodel.where where between
## where not
```lua
usr:where_not("username", "foo")
```

```sql
SELECT
  *
FROM
  usr T
WHERE
  NOT (T.username = 'foo')
```

ok 85 - Xodel.where where not
## where not null
```lua
usr:where_not_null("username")
```

```sql
SELECT
  *
FROM
  usr T
WHERE
  T.username IS NOT NULL
```

ok 86 - Xodel.where where not null
## where not in
```lua
usr:where_not_in("id", {1,2,3})
```

```sql
SELECT
  *
FROM
  usr T
WHERE
  (T.id) NOT IN (1, 2, 3)
```

ok 87 - Xodel.where where not in
## where not between
```lua
usr:where_not_between("id", 2, 4)
```

```sql
SELECT
  *
FROM
  usr T
WHERE
  T.id NOT BETWEEN 2 AND 4
```

ok 88 - Xodel.where where not between
## where not exists
```lua
usr:where_not_exists(usr:where{id=1})
```

```sql
SELECT
  *
FROM
  usr T
WHERE
  NOT EXISTS (
    SELECT
      *
    FROM
      usr T
    WHERE
      T.id = 1
  )
```

ok 89 - Xodel.where where not exists
## where by arithmetic operator: __ne
```lua
usr:where{id__ne=2}:select('id')
```

```sql
SELECT
  T.id
FROM
  usr T
WHERE
  T.id <> 2
```

ok 90 - Xodel.where where by arithmetic operator: __ne
## where by arithmetic operator: __lt
```lua
usr:where{id__lt=2}:select('id')
```

```sql
SELECT
  T.id
FROM
  usr T
WHERE
  T.id < 2
```

ok 91 - Xodel.where where by arithmetic operator: __lt
## where by arithmetic operator: __lte
```lua
usr:where{id__lte=2}:select('id')
```

```sql
SELECT
  T.id
FROM
  usr T
WHERE
  T.id <= 2
```

ok 92 - Xodel.where where by arithmetic operator: __lte
## where by arithmetic operator: __gt
```lua
usr:where{id__gt=2}:select('id')
```

```sql
SELECT
  T.id
FROM
  usr T
WHERE
  T.id > 2
```

ok 93 - Xodel.where where by arithmetic operator: __gt
## where by arithmetic operator: __gte
```lua
usr:where{id__gte=2}:select('id')
```

```sql
SELECT
  T.id
FROM
  usr T
WHERE
  T.id >= 2
```

ok 94 - Xodel.where where by arithmetic operator: __gte
## where by arithmetic operator: __eq
```lua
usr:where{id__eq=2}:select('id')
```

```sql
SELECT
  T.id
FROM
  usr T
WHERE
  T.id = 2
```

ok 95 - Xodel.where where by arithmetic operator: __eq
## where in
```lua
usr:where{username__in={'u1','u2'}}
```

```sql
SELECT
  *
FROM
  usr T
WHERE
  T.username IN ('u1', 'u2')
```

ok 96 - Xodel.where where in
## where contains
```lua
usr:where{username__contains='u'}
```

```sql
SELECT
  *
FROM
  usr T
WHERE
  T.username LIKE '%u%'
```

ok 97 - Xodel.where where contains
## where startswith
```lua
usr:where{username__startswith='u'}
```

```sql
SELECT
  *
FROM
  usr T
WHERE
  T.username LIKE 'u%'
```

ok 98 - Xodel.where where startswith
## where endswith
```lua
usr:where{username__endswith='u'}
```

```sql
SELECT
  *
FROM
  usr T
WHERE
  T.username LIKE '%u'
```

ok 99 - Xodel.where where endswith
## where null true
```lua
usr:where{username__null=true}
```

```sql
SELECT
  *
FROM
  usr T
WHERE
  T.username IS NULL
```

ok 100 - Xodel.where where null true
## where null false
```lua
usr:where{username__null=false}
```

```sql
SELECT
  *
FROM
  usr T
WHERE
  T.username IS NOT NULL
```

ok 101 - Xodel.where where null false
## where notin
```lua
usr:where{username__notin={'u1','u2'}}
```

```sql
SELECT
  *
FROM
  usr T
WHERE
  T.username NOT IN ('u1', 'u2')
```

ok 102 - Xodel.where where notin
## where foreignkey eq
```lua
profile:where{usr_id__username__eq='u1'}
```

```sql
SELECT
  *
FROM
  profile T
  INNER JOIN usr T1 ON (T.usr_id = T1.id)
WHERE
  T1.username = 'u1'
```

ok 103 - Xodel.where where foreignkey eq
## where foreignkey in
```lua
profile:where{usr_id__username__in={'u1','u2'}}
```

```sql
SELECT
  *
FROM
  profile T
  INNER JOIN usr T1 ON (T.usr_id = T1.id)
WHERE
  T1.username IN ('u1', 'u2')
```

ok 104 - Xodel.where where foreignkey in
## where foreignkey contains
```lua
profile:where{usr_id__username__contains='u'}
```

```sql
SELECT
  *
FROM
  profile T
  INNER JOIN usr T1 ON (T.usr_id = T1.id)
WHERE
  T1.username LIKE '%u%'
```

ok 105 - Xodel.where where foreignkey contains
## where foreignkey startswith
```lua
profile:where{usr_id__username__startswith='u'}
```

```sql
SELECT
  *
FROM
  profile T
  INNER JOIN usr T1 ON (T.usr_id = T1.id)
WHERE
  T1.username LIKE 'u%'
```

ok 106 - Xodel.where where foreignkey startswith
## where foreignkey endswith
```lua
profile:where{usr_id__username__endswith='u'}
```

```sql
SELECT
  *
FROM
  profile T
  INNER JOIN usr T1 ON (T.usr_id = T1.id)
WHERE
  T1.username LIKE '%u'
```

ok 107 - Xodel.where where foreignkey endswith
## where foreignkey null true
```lua
profile:where{usr_id__username__null=true}
```

```sql
SELECT
  *
FROM
  profile T
  INNER JOIN usr T1 ON (T.usr_id = T1.id)
WHERE
  T1.username IS NULL
```

ok 108 - Xodel.where where foreignkey null true
## where foreignkey null false
```lua
profile:where{usr_id__username__null=false}
```

```sql
SELECT
  *
FROM
  profile T
  INNER JOIN usr T1 ON (T.usr_id = T1.id)
WHERE
  T1.username IS NOT NULL
```

ok 109 - Xodel.where where foreignkey null false
## where foreignkey number operator ne
```lua
profile:where{usr_id__permission__ne=2}
```

```sql
SELECT
  *
FROM
  profile T
  INNER JOIN usr T1 ON (T.usr_id = T1.id)
WHERE
  T1.permission <> 2
```

ok 110 - Xodel.where where foreignkey number operator ne
## where foreignkey number operator lt
```lua
profile:where{usr_id__permission__lt=2}
```

```sql
SELECT
  *
FROM
  profile T
  INNER JOIN usr T1 ON (T.usr_id = T1.id)
WHERE
  T1.permission < 2
```

ok 111 - Xodel.where where foreignkey number operator lt
## where foreignkey number operator lte
```lua
profile:where{usr_id__permission__lte=2}
```

```sql
SELECT
  *
FROM
  profile T
  INNER JOIN usr T1 ON (T.usr_id = T1.id)
WHERE
  T1.permission <= 2
```

ok 112 - Xodel.where where foreignkey number operator lte
## where foreignkey number operator gt
```lua
profile:where{usr_id__permission__gt=2}
```

```sql
SELECT
  *
FROM
  profile T
  INNER JOIN usr T1 ON (T.usr_id = T1.id)
WHERE
  T1.permission > 2
```

ok 113 - Xodel.where where foreignkey number operator gt
## where foreignkey number operator gte
```lua
profile:where{usr_id__permission__gte=2}
```

```sql
SELECT
  *
FROM
  profile T
  INNER JOIN usr T1 ON (T.usr_id = T1.id)
WHERE
  T1.permission >= 2
```

ok 114 - Xodel.where where foreignkey number operator gte
## where foreignkey number operator eq
```lua
profile:where{usr_id__permission__eq=2}
```

```sql
SELECT
  *
FROM
  profile T
  INNER JOIN usr T1 ON (T.usr_id = T1.id)
WHERE
  T1.permission = 2
```

ok 115 - Xodel.where where foreignkey number operator eq
# Xodel.select
## select fk column
```lua
profile:select('id', 'usr_id__username'):where { id = 1 }:exec()
```

```sql
SELECT
  T.id,
  T1.username AS usr_id__username
FROM
  profile T
  INNER JOIN usr T1 ON (T.usr_id = T1.id)
WHERE
  T.id = 1
```

```js
[
  {
    id              : 1,
    usr_id__username: "u1",
  },
]
```

ok 116 - Xodel.select select fk column
# Xodel:get(cond?, op?, dval?)
## basic
```lua
usr:get{id=3}
```

```sql
SELECT
  *
FROM
  usr T
WHERE
  T.id = 3
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

ok 117 - Xodel:get(cond?, op?, dval?) basic
## model load foreign row
```sql
SELECT
  *
FROM
  profile T
WHERE
  T.id = 1
LIMIT
  2
```

ok 118 - Xodel:get(cond?, op?, dval?) model load foreign row
## fetch extra foreignkey field from database on demand
```sql
SELECT
  *
FROM
  usr T
WHERE
  T.id = 1
LIMIT
  2
```

ok 119 - Xodel:get(cond?, op?, dval?) fetch extra foreignkey field from database on demand
## model load foreign row with specified columns
```lua
profile:load_fk('usr_id', 'username', 'permission'):get{id=1}
```

```sql
SELECT
  T.usr_id,
  T1.username AS usr_id__username,
  T1.permission AS usr_id__permission
FROM
  profile T
  INNER JOIN usr T1 ON (T.usr_id = T1.id)
WHERE
  T.id = 1
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

ok 120 - Xodel:get(cond?, op?, dval?) model load foreign row with specified columns
## model load foreign row with all columns by *
```lua
profile:load_fk('usr_id', '*'):get{id=1}
```

```sql
SELECT
  T.usr_id,
  T.usr_id AS usr_id__id,
  T1.username AS usr_id__username,
  T1.permission AS usr_id__permission
FROM
  profile T
  INNER JOIN usr T1 ON (T.usr_id = T1.id)
WHERE
  T.id = 1
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
  usr T
WHERE
  T.id = 1
LIMIT
  2
```

ok 121 - Xodel:get(cond?, op?, dval?) model load foreign row with all columns by *
## model load foreign row with specified columns two api are the same
```lua
profile:select("sex"):load_fk('usr_id', 'username', 'permission'):get{id=1}
```

```sql
SELECT
  T.sex,
  T.usr_id,
  T1.username AS usr_id__username,
  T1.permission AS usr_id__permission
FROM
  profile T
  INNER JOIN usr T1 ON (T.usr_id = T1.id)
WHERE
  T.id = 1
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
  T.sex,
  T.usr_id,
  T1.username AS usr_id__username,
  T1.permission AS usr_id__permission
FROM
  profile T
  INNER JOIN usr T1 ON (T.usr_id = T1.id)
WHERE
  T.id = 1
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

ok 122 - Xodel:get(cond?, op?, dval?) model load foreign row with specified columns two api are the same
## Xodel:get(cond?, op?, dval?)
```lua
usr:get{id__lt=3}
```

```sql
SELECT
  *
FROM
  usr T
WHERE
  T.id < 3
LIMIT
  2
```

ok 123 - Xodel:get(cond?, op?, dval?) Xodel:get(cond?, op?, dval?)
# Xodel:get_or_create(params:table, defaults?:table, columns?:string[])
## basic
```lua
usr:get_or_create{username='goc'}
```

```sql
WITH
  new_records (id, username) AS (
    INSERT INTO
      "usr" (username)
    SELECT
      'goc'
    WHERE
      NOT EXISTS (
        SELECT
          1
        FROM
          usr T
        WHERE
          T.username = 'goc'
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
  new_records new_records
UNION ALL
(
  SELECT
    id,
    username,
    FALSE AS __is_inserted__
  FROM
    usr T
  WHERE
    T.username = 'goc'
)
```

```js
{
  id      : 33,
  username: "goc",
}
```

ok 124 - Xodel:get_or_create(params:table, defaults?:table, columns?:string[]) basic
## model get_or_create with defaults
```lua
usr:get_or_create({username='goc2'}, {permission = 5})
```

```sql
WITH
  new_records (id, username, permission) AS (
    INSERT INTO
      "usr" (username, permission)
    SELECT
      'goc2',
      5
    WHERE
      NOT EXISTS (
        SELECT
          1
        FROM
          usr T
        WHERE
          T.username = 'goc2'
      )
    RETURNING
      id,
      username,
      permission
  )
SELECT
  id,
  username,
  permission,
  TRUE AS __is_inserted__
FROM
  new_records new_records
UNION ALL
(
  SELECT
    id,
    username,
    permission,
    FALSE AS __is_inserted__
  FROM
    usr T
  WHERE
    T.username = 'goc2'
)
```

```js
{
  id        : 34,
  permission: 5,
  username  : "goc2",
}
```

ok 125 - Xodel:get_or_create(params:table, defaults?:table, columns?:string[]) model get_or_create with defaults
## test chat model
```sql
INSERT INTO
  message AS T (creator, target, content)
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
  ) T.creator,
  T.target,
  T.content
FROM
  message T
WHERE
  T.target = 1
  OR T.creator = 1
ORDER BY
  CASE
    WHEN creator = 1 THEN target
    ELSE creator
  END,
  T.id DESC
```

ok 126 - Xodel api: test chat model
## where by exp
```sql
SELECT
  T.creator,
  T.target
FROM
  message T
WHERE
  T.target = 2
  and T.creator = 1
  or T.target = 1
  and T.creator = 2
```

```sql
SELECT
  T.creator,
  T.target
FROM
  message T
WHERE
  NOT (
    T.target = 2
    or T.creator = 1
  )
  AND NOT (
    T.target = 1
    or T.creator = 2
  )
```

ok 127 - Xodel api: where by exp
## go crazy with where clause with recursive join
```sql
INSERT INTO
  message AS T (target, content, creator)
VALUES
  (2, 'crazy', 1)
RETURNING
  *
```

```sql
SELECT
  *
FROM
  profile T
WHERE
  T.id = 1
LIMIT
  2
```

```sql
SELECT
  *
FROM
  usr T
WHERE
  T.id = 1
LIMIT
  2
```

```sql
SELECT
  T.id,
  T1.age AS creator__age,
  T2.username AS creator__usr_id__username
FROM
  message T
  INNER JOIN profile T1 ON (T.creator = T1.id)
  INNER JOIN usr T2 ON (T1.usr_id = T2.id)
WHERE
  T2.username LIKE '%1%'
  AND T.id = 9
  AND T1.age = 11
```

```sql
SELECT
  T.id,
  T1.age AS creator__age,
  T2.username AS creator__usr_id__username
FROM
  message T
  INNER JOIN profile T1 ON (T.creator = T1.id)
  INNER JOIN usr T2 ON (T1.usr_id = T2.id)
WHERE
  T.id = 9
```

ok 128 - Xodel api: go crazy with where clause with recursive join
# etc
## wrong fk name
```lua
models.message:where {creator__usr_id__views=0}:exec()
```

ok 129 - etc wrong fk name
## wrong fk name3
```lua
models.message:select('creator__usr_id__views'):exec()
```

ok 130 - etc wrong fk name3
## test shortcuts join
```lua
profile:join('dept_name'):get { id = 1 }
```

```sql
SELECT
  *
FROM
  profile T
  INNER JOIN dept T1 ON (T.dept_name = T1.name)
WHERE
  T.id = 1
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

ok 131 - etc test shortcuts join
## sql select_as
```lua
usr:select_as('id', 'value'):select_as('username', 'label'):where { id = 2 }:exec()
```

```sql
SELECT
  T.id AS value,
  T.username AS label
FROM
  usr T
WHERE
  T.id = 2
```

```js
[
  {
    label: "u2",
    value: 2,
  },
]
```

ok 132 - etc sql select_as
## sql select_as foreignkey
```lua
profile:select_as('usr_id__permission', 'uperm'):where { id = 2 }:exec()
```

```sql
SELECT
  T1.permission AS uperm
FROM
  profile T
  INNER JOIN usr T1 ON (T.usr_id = T1.id)
WHERE
  T.id = 2
```

```js
[
  {
    uperm: 3,
  },
]
```

ok 133 - etc sql select_as foreignkey
# sql injection
## where key
ok 134 - sql injection where key
## where value
```sql
SELECT
  *
FROM
  usr T
WHERE
  T.id = '1 or 1=1'
```

ok 135 - sql injection where value
## order
ok 136 - sql injection order
## select
ok 137 - sql injection select
# Xodel:delete(cond?, op?, dval?)
## model class delete all
```lua
evaluate:delete{}:exec()
```

```sql
DELETE FROM evaluate T
```

```js
{
  affected_rows: 4,
}
```

ok 138 - Xodel:delete(cond?, op?, dval?) model class delete all

## model instance delete
```sql
DELETE FROM message T
```

```sql
DELETE FROM message T
```

```sql
SELECT
  *
FROM
  profile T
WHERE
  T.id = 1
LIMIT
  2
```

```lua
du:delete()
```

```sql
DELETE FROM profile T
WHERE
  T.id = 1
RETURNING
  T.id
```

```js
[
  {
    id: 1,
  },
]
```

ok 139 - Xodel:delete(cond?, op?, dval?) model instance delete
## model instance delete use non primary key
```sql
SELECT
  *
FROM
  usr T
WHERE
  T.id = 1
LIMIT
  2
```

```lua
du:delete('username')
```

```sql
DELETE FROM usr T
WHERE
  T.username = 'u1'
RETURNING
  T.username
```

```js
[
  {
    username: "u1",
  },
]
```

ok 140 - Xodel:delete(cond?, op?, dval?) model instance delete use non primary key
## create with foreign model returning all
```sql
SELECT
  *
FROM
  usr T
WHERE
  T.id = 3
LIMIT
  2
```

```lua
profile:insert{usr_id=u, age=12}:returning("*"):execr()
```

```sql
INSERT INTO
  profile AS T (usr_id, dept_name, age, sex, salary)
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

ok 141 - Xodel:delete(cond?, op?, dval?) create with foreign model returning all
## insert from delete returning
```sql
SELECT
  *
FROM
  usr T
WHERE
  T.id = 2
LIMIT
  2
```

```lua
log:insert(profile:delete { id = 2 }:returning('id'):returning_literal("usr", "delete"),
      { 'delete_id', 'model_name', "action" }):returning("*"):execr()
```

```sql
WITH
  D (delete_id, model_name, action) AS (
    DELETE FROM profile T
    WHERE
      T.id = 2
    RETURNING
      T.id,
      'usr',
      'delete'
  )
INSERT INTO
  log AS T (delete_id, model_name, action)
SELECT
  delete_id,
  model_name,
  action
FROM
  D
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

ok 142 - Xodel:delete(cond?, op?, dval?) insert from delete returning
# field stuff
## table field validate
ok 143 - field stuff table field validate
## array field validate
ok 144 - field stuff array field validate
## alioss_list
ok 145 - field stuff alioss_list
1..145

