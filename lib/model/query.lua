local pgmoon        = require "pgmoon"
local dotenv        = require "resty.dotenv"
-- 只为拿 NULL 哨兵：model.utils 不依赖本模块，不构成循环 require
local NULL          = require("model.utils").NULL

-- json/jsonb 读回用的独立 cjson 实例（B13）：pgmoon 默认的 decode 不开
-- decode_array_with_array_mt，库里的 `[]` 解出来是普通空表，原样写回就变成 `{}`。
-- 与 model.validator 里的编码实例配套，配置只作用于本实例，不动全局 cjson
local json_decoder  = require("cjson.safe").new()
json_decoder.decode_array_with_array_mt(true)

local function decode_json_value(_, val)
  local decoded = json_decoder.decode(val)
  if decoded == nil then
    -- 解不开就把原始文本交出去，别把库里的内容丢掉
    return val
  end
  return decoded
end
local type          = type
local table_concat  = table.concat
local string_format = string.format
local ngx           = ngx
local traceback     = debug.traceback

---@class QueryOpts
---@field DATABASE? string
---@field HOST? string the host to connect to (default: "127.0.0.1")
---@field PORT? number|string the port to connect to (default: "5432")
---@field USER? string the database username to authenticate (default: "postgres")
---@field PASSWORD? string password for authentication, may be required depending on server configuration
---@field POOL_NAME? string OpenResty only, name of pool to use when using OpenResty cosocket (default: "#{host}:#{port}:#{database}:#{user}")
---@field POOL_SIZE? number OpenResty only, Passed directly to OpenResty cosocket connect function
---@field SSL? boolean enable SSL
---@field SSL_VERIFY? boolean verify server certificate
---@field SSL_REQUIRED? boolean abort if the server does not support SSL connections
---@field SSL_VERSION? string efaults to highest available, no less than TLS v1.1
---@field CONNECT_TIMEOUT? number 毫秒。只覆盖 TCP 连接 + startup/auth 握手（默认 2000）
---@field QUERY_TIMEOUT? number 毫秒。连上之后单条 SQL 等回包的上限（默认 10000）。没配则回落到 CONNECT_TIMEOUT（老行为）
---@field STATEMENT_TIMEOUT? number|false 毫秒。服务端 `SET statement_timeout`，0 = 不限，false = 不下发。nil = 取 QUERY_TIMEOUT - 2000（不足 2s 时不下发）
---@field MAX_IDLE_TIMEOUT? number can be used to specify the maximal idle timeout (in milliseconds) for the current connection. If omitted, the default setting in the lua_socket_keepalive_timeout config directive will be used. If the 0 value is given, then the timeout interval is unlimited
---@field SOCKET_TYPE? string the type of socket to use, one of: "nginx", "luasocket", cqueues (default: "nginx" if in nginx, "luasocket" otherwise)
---@field APPLICATION_NAME? string
---@field BIGINT_AS_STRING? boolean bigint(int8) 列按原始十进制字符串读回，不经 tonumber（默认 false）
---@field CONVERT_NULL? boolean 非 compact 结果里 NULL 列也用 `Model.NULL` 占位而不是缺键（默认 false）
---@field BACKLOG? number|false OpenResty only, 池满后等连接的排队长度。默认取 POOL_SIZE，此时 POOL_SIZE 才是每 worker 的并发连接数硬上限；false = 不排队、不限连接数（老行为）
---@field DEBUG? fun(statement: string): nil

---@class ConnOpts
---@field database string
---@field host string
---@field port number|string
---@field user string
---@field password? string
---@field pool_name? string OpenResty only, name of pool to use when using OpenResty cosocket (default: "#{host}:#{port}:#{database}:#{user}")
---@field pool_size? number OpenResty only, Passed directly to OpenResty cosocket connect function
---@field ssl? boolean enable SSL
---@field ssl_verify? boolean verify server certificate
---@field ssl_required? boolean abort if the server does not support SSL connections
---@field ssl_version? string defaults to highest available, no less than TLS v1.1
---@field connect_timeout? number 毫秒，TCP 连接 + 握手
---@field query_timeout? number 毫秒，单条 SQL 等回包
---@field statement_timeout? number 毫秒，服务端 statement_timeout；nil 表示不下发（已解析完默认值）
---@field max_idle_timeout number can be used to specify the maximal idle timeout (in milliseconds) for the current connection. If omitted, the default setting in the lua_socket_keepalive_timeout config directive will be used. If the 0 value is given, then the timeout interval is unlimited
---@field socket_type string the type of socket to use, one of: "nginx", "luasocket", cqueues (default: "nginx" if in nginx, "luasocket" otherwise)
---@field application_name string set the name of the connection as displayed in pg_stat_activity. (default: "pgmoon")
---@field bigint_as_string boolean bigint(int8) 列按原始十进制字符串读回
---@field convert_null boolean 非 compact 结果里 NULL 列也占位
---@field backlog? number OpenResty only, 池满后等连接的排队长度；nil 表示不排队（已解析完默认值）

---@class PgmoonConn
---@field sock_type string
---@field query fun(self: PgmoonConn, statement: string): table, number, table, string[]
---@field keepalive fun(self: PgmoonConn, max_idle_timeout: number): boolean, string
---@field disconnect fun(self: PgmoonConn): boolean, string
---@field compact? boolean
---@field convert_null? boolean

-- 惰性读取 .env：require 本模块不产生文件读取副作用，
-- 首次构造连接配置/执行查询时才加载
local ENV
local function get_env()
  if not ENV then
    ENV = dotenv()
  end
  return ENV
end

---布尔选项不能用 `a or b`（false 会被吞掉，导致 options 里的 false 无法覆盖 env）
local function coalesce(a, b)
  if a ~= nil then
    return a
  end
  return b
end

---WARN 统一出口：有 ngx 走 error log，脱 ngx（resty 脚本 / 纯 LuaJIT）走 stderr
---@param msg string
local function log_warn(msg)
  if ngx then
    ngx.log(ngx.WARN, msg)
  else
    io.stderr:write(msg, "\n")
  end
end

-- 超时旋钮拆分（见 docs/orm-index.md「数据库连接与超时」）：
-- 老版本只有 `PG_CONNECT_TIMEOUT` 一个值，经 `conn:settimeout()` 一次性设死
-- connect / send / **receive** 三者 —— 名字写着 connect，实际效果却是「单条 SQL 的时限」。
-- 这两个预算量级差 5 倍以上（握手 2s 级 vs 查询 10s 级），合成一个数必然有一头不合适，
-- 典型症状就是脚本/报表查询报 `receive_message: failed to get type: timeout`。
-- 现在拆成 CONNECT_TIMEOUT（只管握手）+ QUERY_TIMEOUT（只管查询）。
-- 老键仍然生效：QUERY_TIMEOUT 没配就回落到它，保证存量 .env 行为不变，只是提醒一次。
local warned_legacy_timeout = false
local function warn_legacy_timeout()
  if warned_legacy_timeout then
    return
  end
  warned_legacy_timeout = true
  log_warn("[model.query] PG_CONNECT_TIMEOUT 现在只管连接握手，" ..
    "单条 SQL 的时限请改用 PG_QUERY_TIMEOUT。" ..
    "建议 .env 写成 PG_CONNECT_TIMEOUT=2000 与 PG_QUERY_TIMEOUT=10000，" ..
    "详见 docs/orm-index.md「数据库连接与超时」")
end

---@param options QueryOpts
---@param env table
---@return number connect_timeout
---@return number query_timeout
local function resolve_timeouts(options, env)
  local legacy = tonumber(env.PG_CONNECT_TIMEOUT)
  local connect_timeout = options.CONNECT_TIMEOUT or legacy or 2000
  local query_timeout = options.QUERY_TIMEOUT or tonumber(env.PG_QUERY_TIMEOUT)
  if not query_timeout then
    -- 没有新键：沿用老键，行为与升级前完全一致
    query_timeout = legacy or 10000
    if legacy then
      warn_legacy_timeout()
    end
  end
  return connect_timeout, query_timeout
end

---.env 里的布尔开关统一按字符串 "true" 判定，未配置时为 false
local function get_env_flag(env, key)
  return env[key] == "true"
end

---服务端护栏的默认值（D10）：客户端读超时不会给 PG 发 cancel，超时的查询会在服务端
---一直跑到自己结束。默认让服务端比客户端早 2 秒动手，慢查询风暴时不会在 PG 上堆积。
---显式值优先级：`options.STATEMENT_TIMEOUT` > `PG_STATEMENT_TIMEOUT` > 派生默认值。
---`0` 表示服务端不限（照常下发 `SET statement_timeout = 0`）；
---`false` / `PG_STATEMENT_TIMEOUT=off` 表示一条 `SET` 都不发（完全回到老行为）。
---@param options QueryOpts
---@param env table
---@param query_timeout number
---@return number? statement_timeout nil 表示不下发
local function resolve_statement_timeout(options, env, query_timeout)
  if options.STATEMENT_TIMEOUT == false or env.PG_STATEMENT_TIMEOUT == "off" then
    return nil
  end
  local explicit = options.STATEMENT_TIMEOUT or tonumber(env.PG_STATEMENT_TIMEOUT)
  if explicit ~= nil then
    return explicit
  end
  -- 派生值必须为正：QUERY_TIMEOUT 本身就小于 2s 的池子（脚本里为了快速失败会这么配）
  -- 派生出来会是负数或 0，下发后每条 SQL 都会被服务端立刻 cancel。这种情况不下发，
  -- 让客户端读超时独自兜底
  local derived = query_timeout - 2000
  if derived > 0 then
    return derived
  end
  return nil
end

---连接数上限（D10）：cosocket 的 `pool_size` 只限制**空闲**连接数，不设 `backlog`
---时并发峰值会无限制新建连接，8 个 worker 很容易越过 PG 的 `max_connections`，
---报 `too many clients already`。给 `backlog` 一个默认值后 `pool_size` 才真正成为
---「每 worker 并发连接数上限」，超出的请求排队而不是压垮 PG。
---配比建议：`pool_size × worker 数 ≤ max_connections × 0.8`，见 docs/orm-index.md。
---`BACKLOG = false` / `PG_BACKLOG=off` 回到「不排队、无上限」的老行为。
---@param options QueryOpts
---@param env table
---@param pool_size number
---@return number? backlog nil 表示不启用排队
local function resolve_backlog(options, env, pool_size)
  if options.BACKLOG == false or env.PG_BACKLOG == "off" then
    return nil
  end
  return options.BACKLOG or tonumber(env.PG_BACKLOG) or pool_size
end

---@param options QueryOpts
---@return ConnOpts
local function get_connect_table(options)
  local env = get_env()
  local connect_timeout, query_timeout = resolve_timeouts(options, env)
  local res = {
    host = options.HOST or env.PGHOST or "127.0.0.1",
    port = options.PORT or tonumber(env.PGPORT) or 5432,
    database = options.DATABASE or env.PGDATABASE or "postgres",
    user = options.USER or env.PGUSER or "postgres",
    password = options.PASSWORD or env.PGPASSWORD,
    ssl = coalesce(options.SSL, env.PG_SSL == "true"),
    ssl_verify = coalesce(options.SSL_VERIFY, env.PG_SSL_VERIFY),
    ssl_required = coalesce(options.SSL_REQUIRED, env.PG_SSL_REQUIRED),
    pool_name = options.POOL_NAME or env.PG_POOL_NAME or nil,
    pool_size = options.POOL_SIZE or tonumber(env.PG_POOL_SIZE) or 100,
    connect_timeout = connect_timeout,
    query_timeout = query_timeout,
    statement_timeout = resolve_statement_timeout(options, env, query_timeout),
    max_idle_timeout = options.MAX_IDLE_TIMEOUT or tonumber(env.PG_MAX_IDLE_TIMEOUT) or 10000,
    socket_type = options.SOCKET_TYPE,
    application_name = options.APPLICATION_NAME,
    bigint_as_string = coalesce(options.BIGINT_AS_STRING, get_env_flag(env, "PG_BIGINT_AS_STRING")),
    convert_null = coalesce(options.CONVERT_NULL, get_env_flag(env, "PG_CONVERT_NULL")),
  }
  res.backlog = resolve_backlog(options, env, res.pool_size)
  if not res.pool_name then
    res.pool_name = tostring(res.host) ..
        ":" .. tostring(res.port) ..
        ":" .. tostring(res.database) ..
        ":" .. tostring(res.user)
  end
  return res
end

---把 builder 直接交给 query() 就是执行它，与 Sql:exec() 过同一道全表写防呆
---（ORM 内部传进来的都是字符串，走到这里的只有调用方的 `Model.query(builder)`）
---@param sql Model
local function check_full_table_write(sql)
  ---@diagnostic disable-next-line: invisible
  local check = sql._check_full_table_write
  if type(check) == 'function' then
    check(sql)
  end
end

---@param statement Model|table
---@return string
local function process_statement_table(statement)
  if type(statement.statement) == 'function' then
    ---@cast statement Model
    check_full_table_write(statement)
    return statement:statement()
  elseif statement[1] then
    ---@cast statement table
    local statements = {}
    for _, query in ipairs(statement) do
      if type(query) == 'string' then
        if query ~= "" then
          statements[#statements + 1] = query
        end
      elseif type(query) == 'table' and type(query.statement) == 'function' then
        check_full_table_write(query)
        statements[#statements + 1] = query:statement()
      else
        error(string_format("invalid type '%s' for statements passing to query", type(query)))
      end
    end
    return table_concat(statements, ";")
  else
    error("empty table passed to query")
  end
end

---@class ConnProxy
---@field conn PgmoonConn
---@field options ConnOpts
---@field debug fun(statement: string): nil
local ConnProxy = {}
ConnProxy.__index = ConnProxy

function ConnProxy:new(attrs)
  return setmetatable(attrs or {}, self)
end

function ConnProxy:release()
  local ok, err
  if self.broken then
    -- 传输层错误（读超时/断链）之后 socket 上还滞留着——或即将到达——上一条查询的回包，
    -- 协议状态没有同步到 ReadyForQuery。cosocket 的 setkeepalive 在读超时后依然返回成功，
    -- 这条脏 socket 一旦进池，下一个借到它的查询读到的是上一条的结果集，并从此永久错位一格。
    -- 这种连接只能关掉。
    -- 关闭本身也可能抛错（socket 已被对端断开），pcall 兜住：连接无论如何不再进池
    local closed, close_err = pcall(self.disconnect, self)
    ok, err = closed, (closed and nil or close_err)
  elseif self.conn.sock_type == "nginx" then
    ok, err = self:keepalive()
  else
    ok, err = self:disconnect()
  end
  if not ok then
    if ngx then
      ngx.log(ngx.ERR, err)
    else
      io.stderr:write(tostring(err), "\n")
    end
  end
  return ok, err
end

function ConnProxy:keepalive()
  return self.conn:keepalive(self.options.max_idle_timeout)
end

function ConnProxy:disconnect()
  return self.conn:disconnect()
end

---@param statement string|table
---@param compact? boolean
---@return table result query result table
---@return number num_queries number of queries
---@return table notifications notifications
---@return string[] notices notices
function ConnProxy:query(statement, compact)
  if type(statement) == 'table' then
    statement = process_statement_table(statement)
  end
  local env = get_env()
  if env.DEBUG_SQL == 'on' then
    self.debug(statement)
  end
  self.conn.compact = compact
  -- compact 结果集的语义是「按位置取列」，而 pgmoon 在 convert_null = false 时
  -- **不写入** NULL 列，整行就少一格：`values_list({'id','rating'})` 对 NULL 行返回
  -- `{1}` 而不是 `{1, NULL}`，`flat` 的元素数也会少于行数，与同序的 id 列表对不上（B5）。
  -- 位置敏感的路径一律要占位，所以 compact 查询无条件打开；
  -- 非 compact 路径默认保持「缺键」的老行为（`ngx.null` 为真值，会改变 `if rec.x then` 的判断），
  -- 需要的业务用 CONVERT_NULL 显式打开（D3 第二档）
  self.conn.convert_null = compact == true or self.options.convert_null == true
  -- pgmoon 的两种失败形态必须分开对待（pgmoon/init.lua receive_query_result 末尾）：
  --   PG 报错（已收到 ReadyForQuery，协议状态同步）：nil, err, result, num_queries, notifications, notices
  --   传输层错误（超时/断链，协议状态未同步）      ：nil, err
  -- 判据就是第 4 个返回值是不是 number：不是 number 就说明这轮根本没等到 ReadyForQuery。
  local result, num_queries, notifications, notices = self.conn:query(statement)
  if result ~= nil then
    return result, num_queries, notifications, notices
  end
  -- 出错分支下返回值整体右移一格：num_queries 位上是错误信息，notices 位上才是 num_queries
  local err, pg_num_queries = num_queries, notices
  if type(pg_num_queries) ~= 'number' then
    -- 传输层错误：连接不可再用，release() 会把它关掉而不是放回池子
    self.broken = true
  elseif self.in_transaction and not self.aborted then
    -- 事务内的 PG 报错：此后整个会话进入 aborted 状态，COMMIT 会被 PG 当作 ROLLBACK
    -- 静默执行。记下首个错误，transaction() 在 callback 正常返回时据此拒绝提交（B2）
    self.aborted = true
    self.aborted_error = err
  end
  -- ignore the rest return values when error
  error(err)
end

---事务状态机：begin 置位，commit/rollback 清零，rollback_to 让事务从 aborted 恢复可用
function ConnProxy:begin()
  local res = self:query("BEGIN")
  self.in_transaction = true
  return res
end

function ConnProxy:commit()
  local res = self:query("COMMIT")
  self.in_transaction = false
  self.aborted = false
  self.aborted_error = nil
  return res
end

function ConnProxy:savepoint(name)
  return self:query("SAVEPOINT " .. name)
end

function ConnProxy:rollback()
  local res = self:query("ROLLBACK")
  self.in_transaction = false
  self.aborted = false
  self.aborted_error = nil
  return res
end

function ConnProxy:rollback_to(name)
  local res = self:query("ROLLBACK TO SAVEPOINT " .. name)
  -- 回到 savepoint 之后事务重新可写，之前那次报错不再阻止提交
  self.aborted = false
  self.aborted_error = nil
  return res
end

-- function ConnProxy:release(name)
--   return self:query("RELEASE SAVEPOINT " .. name)
-- end

-- 执行阶段守卫（S3/D9）：cosocket（`ngx.socket.tcp`）只在下面这些阶段可用。
-- 其它阶段发查询，错误会从 pgmoon 深处以 `API disabled in the context of ...` 的形式抛出，
-- 栈顶指向 pgmoon 内部，完全看不出是「在错误的阶段查库」。最常见的触发路径不是有人
-- 手写查询，而是 content 阶段取出的记录带着外键惰性代理，到了 log_by_lua 做审计序列化时
-- 才第一次访问 `record.fk.xxx`，那一下才真正发 SQL（见 ForeignkeyField:load 与 Model.LAZY_FK）。
local COSOCKET_PHASES = {
  rewrite = true,
  access = true,
  content = true,
  timer = true,
  preread = true,
  ssl_cert = true,
  ssl_session_fetch = true,
  ssl_client_hello = true,
}

---@param connect_table ConnOpts
---@return fun(): nil
local function make_phase_guard(connect_table)
  local socket_type = connect_table.socket_type
  return function()
    if not ngx or not ngx.get_phase then
      -- 纯 LuaJIT / 单元测试：没有阶段这回事
      return
    end
    if socket_type and socket_type ~= "nginx" then
      -- 显式走 luasocket / cqueues，不受 cosocket 的阶段限制
      return
    end
    local phase = ngx.get_phase()
    if COSOCKET_PHASES[phase] then
      return
    end
    if phase == "init" then
      -- pgmoon 的 socket.new 在 init 阶段自己回落到 luasocket（迁移脚本的常见写法）
      return
    end
    error(string_format(
      "[model.query] refuse to run SQL in the '%s' phase: cosocket API is disabled there. " ..
      "Allowed phases: rewrite/access/content/timer/preread/ssl_*. " ..
      "If this came from a foreign key attribute access (lazy load), fetch it in the " ..
      "request phase with select_related(), or set Model.LAZY_FK = false to surface it earlier.",
      phase), 0)
  end
end

---@param options QueryOpts
---@param connect_table ConnOpts
local function create_query(options, connect_table)
  local connect_timeout = connect_table.connect_timeout
  local query_timeout = connect_table.query_timeout
  local statement_timeout = connect_table.statement_timeout
  local bigint_as_string = connect_table.bigint_as_string
  local debug_func = options.DEBUG or print
  local check_phase = make_phase_guard(connect_table)
  -- local max_idle_timeout = connect_table.max_idle_timeout
  -- local pool_size = connect_table.pool_size

  ---@return ConnProxy
  local function make_conn()
    local conn = pgmoon.new(connect_table)
    -- 握手期用 connect_timeout：pgmoon 的 connect() 在新建连接上还会跑
    -- startup message + auth + wait_until_ready，都要读服务端回包，所以这个值
    -- 不只是 TCP connect 的预算。复用池里的连接时这几步会跳过
    conn:settimeout(connect_timeout)
    local ok, err = conn:connect()
    if not ok then
      error(err)
    end
    -- 连上之后换成 query_timeout：cosocket 的 settimeout 会一直作用到这个 socket
    -- 后续所有 receive 上，也就是「单条 SQL 等回包的上限」。与握手不是一个量级，
    -- 混用会让报表/迁移这类慢查询按握手的尺度被砍掉
    conn:settimeout(query_timeout)
    -- pgmoon 默认的 NULL 哨兵是它自己的 `{"NULL"}` 表，与 ORM 对外的 `Model.NULL`
    -- （ngx.null）不是同一个对象。统一成后者，调用方才能用 `v == Model.NULL` 判断占位
    conn.NULL = NULL
    -- json(114) / jsonb(3802) 改用本模块的 decoder，保住空数组（B13）
    conn:set_type_deserializer(114, "json", decode_json_value)
    conn:set_type_deserializer(3802, "json", decode_json_value)
    -- bigint 读回（B3/D4）：pgmoon 把 oid 20(int8) 归到 "number" 类，一律 tonumber，
    -- 超过 2^53 的值末位直接错掉且不报错。打开这个开关后 int8 按原始十进制字符串返回，
    -- 精度由调用方决定怎么用（字符串比较 / int64 cdata / 直接透传给前端）。
    -- 默认关：开启会把 `rec.id` 从 number 变成 string，是行为变化，必须由业务方自己选
    if bigint_as_string then
      conn:set_type_deserializer(20, "int8_text", function(_, val)
        return val
      end)
    end
    -- 新建连接上的会话初始化。下面两条都是**会话级**参数，池里复用的 socket 上依然有效，
    -- 所以只在复用次数为 0 时下发；两条 SET 拼成一条简单查询走一次往返，
    -- 复用连接的热路径上一条多余的往返都不留。
    local sock = conn.sock
    local times = sock and sock.getreusedtimes and sock:getreusedtimes()
    if not times or times == 0 then
      -- 强制 standard_conforming_strings = on（S2）：model/utils.lua 的 as_literal 与
      -- model/expr.lua 的 LIKE/正则转义都只处理单引号、不转义反斜杠，其安全性隐含依赖
      -- 该参数为 on（PG 9.1 起的默认值）。它可以在库级/角色级被改成 off，那时 `\'` 能
      -- 逃逸字符串字面量造成注入，`ESCAPE '\'` 的语义也一并变掉。这里把「约定」变成
      -- 建连时的「强制」，代价并到下面这一次往返里，等于零。
      local sets = { "SET standard_conforming_strings = on" }
      -- 服务端护栏。客户端超时不会给 PG 发 cancel（查询会继续烧 CPU 到跑完），
      -- 真正能中止查询的只有 statement_timeout
      if statement_timeout then
        -- 走 %d 前先取整：配成小数时 string.format("%d") 会直接抛错
        sets[#sets + 1] = string_format("SET statement_timeout = %d", math.floor(statement_timeout))
      end
      local set_ok, set_err = conn:query(table_concat(sets, "; "))
      if not set_ok then
        -- 设不上就别把这条半吊子连接放回池里：转义假设不成立的连接，继续用比连不上更危险
        pcall(conn.disconnect, conn)
        error("failed to init session (standard_conforming_strings/statement_timeout): " .. tostring(set_err))
      end
    end
    return ConnProxy:new { conn = conn, options = connect_table, debug = debug_func }
  end

  -- 当前事务连接的 ambient 存储：按运行协程隔离，而非 ngx.ctx。
  -- 1) 脱 ngx：纯 LuaJIT / resty-cli / 脚本里 coroutine.running() 是标准 Lua，照常工作；
  -- 2) 隔离更准：每个 ngx.thread.spawn 轻线程是独立协程 → 独立 key → 独立连接，
  --    杜绝多轻线程共用同一 pgmoon socket 并发发查询导致的线协议错乱。
  -- 弱键：协程被回收后条目自动消失，不泄漏。
  local txn_conns = setmetatable({}, { __mode = "k" })
  local MAIN = {} -- 无协程的纯主线程（如 init/脚本顶层）的哨兵 key

  local function txn_key()
    return coroutine.running() or MAIN
  end

  local function get_conn()
    local conn = txn_conns[txn_key()]
    if conn then
      return conn, true
    end
    return make_conn(), false
  end


  ---@param statement string|table
  ---@param compact? boolean
  ---@return table result query result table
  ---@return number num_queries number of queries
  ---@return table notifications notifications
  ---@return string[] notices notices
  local function send_query(statement, compact)
    -- https://github.com/xiangnanscu/pgmoon/blob/master/pgmoon/init.lua#L545
    -- nil,  err_msg, result, num_queries, notifications, notices
    -- result, num_queries, notifications, notices
    check_phase()
    local conn, is_transaction = get_conn()
    if is_transaction then
      -- 事务连接的生命周期由 transaction() 负责，出错直接上抛
      return conn:query(statement, compact)
    end
    -- 非事务连接必须先归还再抛错：ConnProxy:query 失败时 error()，
    -- 若不 pcall，出错的连接既不进池也不关闭，连接池被慢性掏空
    local ok, result, num_queries, notifications, notices = pcall(conn.query, conn, statement, compact)
    conn:release()
    if not ok then
      error(result, 0)
    end
    return result, num_queries, notifications, notices
  end


  -- 错误通道统一为「抛错」：失败一律 error 重抛，交给 app.lua 唯一的错误分类器
  -- （field_error→422 / error{"msg"}→512 / 其它→500+ErrorLog）。绝不在此降级成
  -- return nil,err——那样会丢失 512 分类、traceback 与 ErrorLog 日志，使 atomic=true
  -- 悄悄改变错误码。成功时才返回 callback 的多值结果。
  local function transaction(callback)
    check_phase()
    local key = txn_key()
    if txn_conns[key] then
      -- 嵌套 atomic 是调用方 bug，抛错让上层记 ErrorLog（500），别静默返回
      error("transaction already started")
    end
    local conn = make_conn()
    -- BEGIN 失败也要释放连接，否则泄漏（不进池、不关闭）
    local began, begin_err = pcall(conn.begin, conn)
    if not began then
      conn:release()
      error(begin_err, 0)
    end
    txn_conns[key] = conn
    -- 用 xpcall+traceback 捕获，保留 callback 内真实崩溃栈（与非 atomic 路径一致）
    local ok, cb_res, cb_err, cb_status = xpcall(callback, traceback, conn)
    txn_conns[key] = nil
    if not ok then
      -- 回滚可能因网络中断再次抛错；pcall 兜住，保证 release 必然执行一次，
      -- 且回滚的二次错误不掩盖 callback 根因 cb_res。
      -- 连接已因传输层错误损坏时跳过 ROLLBACK：那条 ROLLBACK 只会读到滞留的回包并
      -- 「成功」，反而把脏状态坐实（B1）。
      if not conn.broken then
        pcall(conn.rollback, conn)
      end
      conn:release()
      error(cb_res, 0) -- 原样重抛（level 0，不加本文件位置），保持错误对象供上层分类
    end
    if conn.aborted then
      -- callback 把某条 SQL 的 PG 报错吞掉了（「先试插入，失败就走另一条路」这种写法）。
      -- 此时 PG 会话已 aborted，COMMIT 等于 ROLLBACK 且不报错，调用方会拿到「成功」
      -- 而一个字节都没写进去。主动回滚并抛错，把假成功变成显式失败（B2）。
      local first_error = conn.aborted_error
      if not conn.broken then
        pcall(conn.rollback, conn)
      end
      conn:release()
      error("transaction aborted by earlier error: " .. tostring(first_error), 0)
    end
    -- COMMIT 可能因网络中断或延迟约束（deferred constraint）抛错；
    -- release 用 finally 语义放在判断之前，保证连接必然归还，避免 DB 故障下池耗尽。
    local committed, commit_err = pcall(conn.commit, conn)
    conn:release()
    if not committed then
      error(commit_err, 0)
    end
    -- 注意：只透传 callback 的前 3 个返回值（xpcall 捕获处即已截断），
    -- 需要更多返回值请打包成 table
    return cb_res, cb_err, cb_status
  end


  return setmetatable({
    query = send_query,
    transaction = transaction
  }, {
    __call = function(t, ...)
      return send_query(...)
    end
  })
end

-- 按 pool_name（host:port:database:user）缓存 Query 实例：
-- 同一连接配置的所有 model 共享同一份 txn_conns，保证 A:transaction 的
-- callback 内经由 B model 发出的查询进入同一事务连接——否则每个 model
-- 各持一个 Query 实例，跨 model 写入会拿新连接自动提交，逃逸事务回滚。
-- 注意：同 pool_name 下 pool_size/timeout/DEBUG 等以首个实例为准，
-- 与 pgmoon 连接池按 pool_name 复用 socket 的语义一致。
local query_cache = {}
-- 缓存命中时用来比对「这次传进来的配置和当初建池时的一样吗」。只列真正会改变连接行为的键：
-- DEBUG（函数）、pool_name（就是缓存键本身）不在内。
local POOL_SENSITIVE_KEYS = {
  'host', 'port', 'database', 'user', 'password',
  'connect_timeout', 'query_timeout', 'statement_timeout', 'max_idle_timeout',
  'pool_size', 'backlog',
  'ssl', 'ssl_verify', 'ssl_required',
  'socket_type', 'application_name', 'bigint_as_string', 'convert_null',
}
-- 每个 (pool_name, key) 只提醒一次，避免热路径刷屏
local warned_pool_conflict = {}
local query_configs = {}

---缓存命中但配置不同：静默沿用旧配置是 D10 点名的坑——
---「脚本里把 QUERY_TIMEOUT 调到 10 分钟却没生效」，因为 web 侧的同名池先建好了。
---行为不变（仍以首个实例为准，事务共享连接依赖这点），但必须留下痕迹。
---@param pool_name string
---@param cached ConnOpts
---@param incoming ConnOpts
local function warn_pool_conflict(pool_name, cached, incoming)
  for _, key in ipairs(POOL_SENSITIVE_KEYS) do
    if cached[key] ~= incoming[key] then
      local warn_key = pool_name .. "|" .. key
      if not warned_pool_conflict[warn_key] then
        warned_pool_conflict[warn_key] = true
        -- 口令不进日志
        local old_value = key == 'password' and '***' or tostring(cached[key])
        local new_value = key == 'password' and '***' or tostring(incoming[key])
        log_warn(string_format(
          "[model.query] Query{POOL_NAME=%q} 已被构造过，%s 以首次构造的值为准：" ..
          "沿用 %s，忽略本次传入的 %s。需要不同配置请换一个 POOL_NAME，" ..
          "详见 docs/orm-index.md「数据库连接与超时」",
          pool_name, key, old_value, new_value))
      end
    end
  end
end

---@param options? QueryOpts
local function Query(options)
  options = options or {}
  local connect_table = get_connect_table(options)
  local pool_name = connect_table.pool_name --[[@as string]] -- get_connect_table 保证已填
  local cached = query_cache[pool_name]
  if cached then
    warn_pool_conflict(pool_name, query_configs[pool_name], connect_table)
    return cached
  end
  local q = create_query(options, connect_table)
  query_cache[pool_name] = q
  query_configs[pool_name] = connect_table
  return q
end

return Query
