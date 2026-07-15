local pgmoon        = require "pgmoon"
local dotenv        = require "resty.dotenv"
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
---@field CONNECT_TIMEOUT? number set the timeout value in milliseconds for subsequent socket operations (connect, receive, and iterators returned from receiveuntil).
---@field MAX_IDLE_TIMEOUT? number can be used to specify the maximal idle timeout (in milliseconds) for the current connection. If omitted, the default setting in the lua_socket_keepalive_timeout config directive will be used. If the 0 value is given, then the timeout interval is unlimited
---@field SOCKET_TYPE? string the type of socket to use, one of: "nginx", "luasocket", cqueues (default: "nginx" if in nginx, "luasocket" otherwise)
---@field APPLICATION_NAME? string
---@field BACKLOG? number OpenResty only, specify the size of the connection pool. If omitted and no backlog option was provided, no pool will be created. If omitted but backlog was provided, the pool will be created with a default size equal to the value of the lua_socket_pool_size directive
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
---@field connect_timeout? number set the timeout value in milliseconds for subsequent socket operations (connect, receive, and iterators returned from receiveuntil).
---@field max_idle_timeout number can be used to specify the maximal idle timeout (in milliseconds) for the current connection. If omitted, the default setting in the lua_socket_keepalive_timeout config directive will be used. If the 0 value is given, then the timeout interval is unlimited
---@field socket_type string the type of socket to use, one of: "nginx", "luasocket", cqueues (default: "nginx" if in nginx, "luasocket" otherwise)
---@field application_name string set the name of the connection as displayed in pg_stat_activity. (default: "pgmoon")
---@field backlog number OpenResty only, specify the size of the connection pool. If omitted and no backlog option was provided, no pool will be created. If omitted but backlog was provided, the pool will be created with a default size equal to the value of the lua_socket_pool_size directive

---@class PgmoonConn
---@field sock_type string
---@field query fun(self: PgmoonConn, statement: string): table, number, table, string[]
---@field keepalive fun(self: PgmoonConn, max_idle_timeout: number): boolean, string
---@field disconnect fun(self: PgmoonConn): boolean, string
---@field compact? boolean

local ENV_CONFIG    = dotenv { ".env" }

---@param options QueryOpts
---@return ConnOpts
local function get_connect_table(options)
  local res = {
    host = options.HOST or ENV_CONFIG.PGHOST or "127.0.0.1",
    port = options.PORT or tonumber(ENV_CONFIG.PGPORT) or 5432,
    database = options.DATABASE or ENV_CONFIG.PGDATABASE or "postgres",
    user = options.USER or ENV_CONFIG.PGUSER or "postgres",
    password = options.PASSWORD or ENV_CONFIG.PGPASSWORD,
    ssl = options.SSL or ENV_CONFIG.PG_SSL == "true" or false,
    ssl_verify = options.SSL_VERIFY or ENV_CONFIG.PG_SSL_VERIFY or nil,
    ssl_required = options.SSL_REQUIRED or ENV_CONFIG.PG_SSL_REQUIRED or nil,
    pool_name = options.POOL_NAME or ENV_CONFIG.PG_POOL_NAME or nil,
    pool_size = options.POOL_SIZE or tonumber(ENV_CONFIG.PG_POOL_SIZE) or 100,
    connect_timeout = options.CONNECT_TIMEOUT or tonumber(ENV_CONFIG.PG_CONNECT_TIMEOUT) or 10000,
    max_idle_timeout = options.MAX_IDLE_TIMEOUT or tonumber(ENV_CONFIG.PG_MAX_IDLE_TIMEOUT) or 10000,
    socket_type = options.SOCKET_TYPE,
    application_name = options.APPLICATION_NAME,
    backlog = options.BACKLOG,
  }
  if not res.pool_name then
    res.pool_name = tostring(res.host) ..
        ":" .. tostring(res.port) ..
        ":" .. tostring(res.database) ..
        ":" .. tostring(res.user)
  end
  return res
end

---@param statement Model|table
---@return string
local function process_statement_table(statement)
  if type(statement.statement) == 'function' then
    ---@cast statement Model
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

ConnProxy.__call = function(self, attrs)
  return self:new(attrs or {})
end

function ConnProxy:new(attrs)
  return setmetatable(attrs or {}, self)
end

function ConnProxy:release()
  local ok, err
  if self.conn.sock_type == "nginx" then
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
  if ENV_CONFIG.DEBUG_SQL == 'on' then
    self.debug(statement)
  end
  self.conn.compact = compact
  local result, num_queries, notifications, notices = self.conn:query(statement)
  if result == nil then
    -- ignore the rest return values when error
    error(num_queries)
  else
    return result, num_queries, notifications, notices
  end
end

function ConnProxy:begin()
  return self:query("BEGIN")
end

function ConnProxy:commit()
  return self:query("COMMIT")
end

function ConnProxy:savepoint(name)
  return self:query("SAVEPOINT " .. name)
end

function ConnProxy:rollback()
  return self:query("ROLLBACK")
end

function ConnProxy:rollback_to(name)
  return self:query("ROLLBACK TO SAVEPOINT " .. name)
end

-- function ConnProxy:release(name)
--   return self:query("RELEASE SAVEPOINT " .. name)
-- end

---@param options QueryOpts
---@param connect_table ConnOpts
local function create_query(options, connect_table)
  local connect_timeout = connect_table.connect_timeout
  local debug_func = options.DEBUG or print
  -- local max_idle_timeout = connect_table.max_idle_timeout
  -- local pool_size = connect_table.pool_size

  ---@return ConnProxy
  local function make_conn()
    local conn = pgmoon.new(connect_table)
    conn:settimeout(connect_timeout)
    local ok, err = conn:connect()
    if not ok then
      error(err)
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
      pcall(conn.rollback, conn)
      conn:release()
      error(cb_res, 0) -- 原样重抛（level 0，不加本文件位置），保持错误对象供上层分类
    end
    -- COMMIT 可能因网络中断或延迟约束（deferred constraint）抛错；
    -- release 用 finally 语义放在判断之前，保证连接必然归还，避免 DB 故障下池耗尽。
    local committed, commit_err = pcall(conn.commit, conn)
    conn:release()
    if not committed then
      error(commit_err, 0)
    end
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

---@param options? QueryOpts
local function Query(options)
  options = options or {}
  local connect_table = get_connect_table(options)
  local cached = query_cache[connect_table.pool_name]
  if cached then
    return cached
  end
  local q = create_query(options, connect_table)
  query_cache[connect_table.pool_name] = q
  return q
end

return Query
