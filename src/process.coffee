client              = require './client'
fs                  = require 'fs'
{exists, dirname}   = require 'path'
{pause, isFunction} = require './util'
{debug}             = require './util'
{LineBuffer}        = require './util'
{spawn, exec}       = require 'child_process'
{EventEmitter}      = require 'events'
{Stream}            = require 'net'

packageLib = fs.realpathSync __dirname
packageBin = fs.realpathSync "#{__dirname}/../bin"

# **Process** manages a single Ruby worker process.
#
# A Process requires a path to a rackup config file _(config.ru)_.
#
#     process.createProcess("/path/to/app/config.ru");
#
# You can set a idle time so the process dies after a
# specified amount of milliseconds.
#
#     var ms = 15 * 60 * 1000;
#     process.createProcess("/path/to/app/config.ru", { idle: ms });
#
# A Process has 5 states:
#
# > `null`: Not started or dead
# >
# > `spawning`: Is booting and can't accept a connection yet
# >
# > `ready`: Is ready to accept a connection and handle a request
# >
# > `busy`: Is currently handling a request, not ready
# >
# > `quitting`: Was set a kill signal and is shutting down
#
# Anytime a process changes states, an event is fired with the new
# state name. When the process becomes `ready`, a `ready` is fired.
#
# Other events:
#
# > **Event: 'error'**
# >
# > `function (exception) { }`
# >
# > Emitted when an error occurs.
# >
# > **Event: 'spawn'**
# >
# > `function (exception) { }`
# >
# > Emitted when the process moves from `spawning` to `ready` state.
# >
# > **Event: 'exit'**
# >
# > `function () { }`
# >
# > Emitted when the Process terminates.
# >
# > **Event: 'idle'**
# >
# > `function () { }`
# >
# > Emitted when the Process times out because of inactivity.
#
exports.Process = class Process extends EventEmitter
  constructor: (@config, options) ->
    self = @
    @id = Math.floor Math.random() * 1000

    options ?= {}
    @idle  = options.idle
    @cwd   = options.cwd ? dirname(@config)
    @env   = options.env ? {}

    # Set initial state to `null`
    @state = null

    @_connectionQueue = []
    @_activeConnection = null

    raiseConfigError = ->
      self.emit 'error', new Error "configuration \"#{@config}\" doesn't exist"

    # Raise an exception unless `config` exists
    if @config?
      exists @config, (ok) ->
        raiseConfigError() if !ok
    else
      raiseConfigError()

    @on 'ready', ->
      self._processConnections()

    @on 'error', (error) ->
      callback = self._activeConnection
      self._activeConnection = null

      if callback
        callback error
      else if self.listeners('error').length <= 1
        throw error

    # Push back the idle time everytime a request is handled
    @on 'busy', ->
      self.deferTimeout()

  spawn: (callback) ->
    return if @state

    debug "spawning process"

    if callback?
      onSpawn = (err) =>
        @removeListener 'ready', onSpawn
        @removeListener 'error', onSpawn
        callback err

      @on 'ready', onSpawn
      @on 'error', onSpawn

    @changeState 'spawning'

    @sockPath = "#{tmpFile()}.sock"

    # Copy process environment
    env = {}
    for key, value of process.env
      env[key] = value

    for key, value of @env
      env[key] = value

    env['PATH']    = "#{packageBin}:#{env['PATH']}"
    env['RUBYLIB'] = "#{packageLib}:#{env['RUBYLIB']}"

    @heartbeat = new Stream

    @heartbeat.on 'connect', =>
      debug "process spawned"
      @emit 'spawn'

    @heartbeat.on 'data', (data) =>
      if "#{@child.pid}\n" is data.toString()
        @changeState 'ready'
      else
        try
          exception   = JSON.parse data
          error       = new Error exception.message
          error.name  = exception.name
          error.stack = exception.stack

          debug "heartbeat error", error
          @emit 'error', error
        catch e
          debug "heartbeat error", e
          @emit 'error', new Error "unknown process error"

    tryConnect @heartbeat, @sockPath, (err) =>
      if err and out
        @emit 'error', new Error out
      else if err
        @emit 'error', err

    # Spawn a Ruby server connecting to our `@sockPath`
    @child = spawn "nack_worker", [@config, @sockPath],
      cwd: @cwd
      env: env

    # Expose `stdout` and `stderr` on Process
    @stdout = @child.stdout
    @stderr = @child.stderr

    out = null
    logData = (data) ->
      out ?= ""
      out += data.toString()

    @stdout.on 'data', logData
    @stderr.on 'data', logData

    @on 'spawn', =>
      out = null
      @stdout.removeListener 'data', logData
      @stderr.removeListener 'data', logData

    # When the child process exists, clear out state and emit `exit`
    @child.on 'exit', (code, signal) =>
      debug "process exited"

      @clearTimeout()
      @heartbeat.destroy() if @heartbeat

      @state = @sockPath = null
      @child = @heartbeat = null
      @stdout = @stderr = null

      @_connectionQueue = []
      @_activeConnection = null

      @emit 'exit'

    @

  # Change the current state and fire a corresponding event
  changeState: (state) ->
    self = this
    if @state != state
      @state = state
      # State change events are always asynchronous
      process.nextTick -> self.emit state

  # Clear current timeout handler.
  clearTimeout: ->
    if @_timeoutId
      clearTimeout @_timeoutId

  # Defer the current idle timer.
  deferTimeout: ->
    self = this
    if @idle
      # Clear the current timer
      @clearTimeout()

      callback = ->
        self.emit 'idle'
        self.quit()

      # Register a new timer
      @_timeoutId = setTimeout callback, @idle

  _processConnections: ->
    self = @

    unless @_activeConnection
      @_activeConnection = @_connectionQueue.shift()

    if @_activeConnection and @state is 'ready'
      # Immediately flag process as `busy`
      @changeState 'busy'

      # Create a connection to our sock path
      connection = client.createConnection @sockPath

      # When the connection closes, change the state back to ready.
      connection.on 'close', ->
        self._activeConnection = null
        self.changeState 'ready'

      @_activeConnection null, connection
    else
      @spawn()

  # Create a new **Client** connection
  createConnection: (callback) ->
    @_connectionQueue.push callback
    @_processConnections()
    @

  # Proxies a `http.ServerRequest` and `http.ServerResponse` to the process
  proxy: (req, res, next) =>
    debug "proxy #{req.method} #{req.url}"

    # Pause request so we don't miss any `data` or `end` events.
    resume = pause req

    @createConnection (err, connection) ->
      if err
        next err
      else
        connection.proxy req, res, next

      # Flush any events captured while we were establishing
      # our client connection
      resume()

  # Send `SIGKILL` to process.
  # This will kill it for sure.
  kill: ->
    debug "process kill"

    if @child
      @changeState 'quitting'
      @child.kill 'SIGKILL'
      @heartbeat.destroy() if @heartbeat

  # Send `SIGTERM` to process.
  # This will immediately kill it.
  terminate: ->
    debug "process terminate"

    if @child
      @changeState 'quitting'
      @child.kill 'SIGTERM'
      @heartbeat.destroy() if @heartbeat

      timeout = setTimeout =>
        if @state is 'quitting'
          @kill()
      , 10000
      @once 'exit', -> clearTimeout timeout

  # Send `SIGTERM` to process.
  # The process will finish serving its request and gracefully quit.
  quit: ->
    debug "process quit"

    if @child
      @changeState 'quitting'
      @child.kill 'SIGQUIT'
      @heartbeat.destroy() if @heartbeat

      timeout = setTimeout =>
        if @state is 'quitting'
          @terminate()
      , 3000
      @once 'exit', -> clearTimeout timeout

  # Quit and respawn process
  restart: (callback) ->
    debug "process restart"

    @once 'exit', => @spawn callback
    @quit()

# Public API for creating a **Process**
exports.createProcess = (args...) ->
  new Process args...

# Generates a random path.
tmpFile = ->
  pid  = process.pid
  rand = Math.floor Math.random() * 10000000000
  "/tmp/nack." + pid + "." + rand

# TODO: Don't poll FS
onceFileExists = (path, callback, timeout = 3000) ->
  timeoutError = null
  timeoutId = setTimeout ->
    timeoutError = new Error "timeout: waiting for #{path}"
  , timeout

  decay = 1

  statPath = (err, stat) ->
    if !err and stat and stat.isSocket()
      clearTimeout timeoutId
      callback err, path
    else if timeoutError
      callback timeoutError, path
    else
      setTimeout ->
        fs.stat path, statPath
      , decay *= 2

  statPath()

tryConnect = (connection, path, callback) ->
  errors = 0

  reconnect = ->
    onceFileExists path, (err) ->
      return callback err if err
      connection.connect path

  onError = (err) ->
    if err and ++errors > 3
      connection.removeListener 'error', onError
      callback new Error "timeout: couldn't connect to #{path}"
    else
      reconnect()

  connection.on 'error', onError

  connection.on 'connect', ->
    connection.removeListener 'error', onError
    callback null, connection

  reconnect()