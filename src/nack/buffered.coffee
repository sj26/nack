{EventEmitter} = require 'events'

# **BufferedReadStream** wraps any readable stream and captures any events
# it fires. The events are held in a buffer until `flush` is called.
#
#     http.createServer (req, res) ->
#       bufferedReq = new BufferedReadStream req
#       fs.readFile path, () ->
#         bufferedReq.on 'data' (chunk) ->
#           console.log
#
exports.BufferedReadStream = class BufferedReadStream extends EventEmitter
  constructor: (@stream) ->
    @readable = true
    @_queue = []
    @_flushed = false

    queueEvent = (event, args...) =>
      if @_flushed
        @emit event, args...
      else
        @_queue.push ['emit', event, args...]

    # Listen and queue up any events on the `@stream`
    @stream.on 'data',  (args...) -> queueEvent 'data', args...
    @stream.on 'end',   (args...) -> queueEvent 'end', args...
    @stream.on 'error', (args...) -> queueEvent 'error', args...
    @stream.on 'close', (args...) -> queueEvent 'close', args...
    @stream.on 'fd',    (args...) -> queueEvent 'fd', args...

    # Tell the `@stream` to pause and stop emitting new events
    @stream.pause()

    # Foward any properties to `@stream`
    for all name, fun of @stream when !this[name] and name[0] != '_'
      @__defineGetter__ name, (args...) -> @stream[name]

  # Ignore requests to resume the stream
  resume: ->

  # Ignore requrests to pause the stream
  pause: ->

  flush: ->
    # Tell the `@stream` to resume
    try
      @stream.resume()
    catch error
      # Stream is probably closed now

    # Flush the event buffer and re-emit the events.
    for [fun, args...] in @_queue
      switch fun
        when 'emit'
          @emit args...

    @_flushed = true

    # Emit a `drain` event to signal the buffer is empty.
    @emit 'drain'

exports.BufferedWriteStream = class BufferedWriteStream extends EventEmitter
  constructor: (@stream) ->
    @writeable = true
    @_queue = []
    @_flushed = false

    @stream.on 'drain', => @emit 'drain'
    @stream.on 'error', (exception) => @emit 'error', exception
    @stream.on 'close', => @emit 'close'

  write: (args...) ->
    if @_flushed
      @stream.write args...
    else
      @_queue.push ['write', args...]
      false

  end: (args...) ->
    if @_flushed
      @stream.end args...
    else
      @_queue.push ['end', args...]
      false

  destroy: ->
    if @_flushed
      @stream.destroy()
    else
      @_queue.push ['destroy']
      false

  flush: ->
    for [fun, args...] in @_queue
      switch fun
        when 'write'
          @stream.write args...
        when 'end'
          @stream.end args...
        when 'destroy'
          @stream.destroy args...

    @_flushed = true
    @emit 'drain'

exports.BufferedLineStream = class BufferedLineStream extends EventEmitter
  constructor: (@stream) ->
    @readable = true
    @_buffer = ""
    @_flushed = false

    @stream.on 'data',  (args...) => @write args...
    @stream.on 'end',   (args...) => @end args...

    @stream.on 'error', (args...) => @emit 'error', args...
    @stream.on 'close', (args...) => @emit 'close', args...
    @stream.on 'fd',    (args...) => @emit 'fd', args...

    for all name, fun of @stream when !this[name] and name[0] != '_'
      @__defineGetter__ name, (args...) -> @stream[name]

  write: (chunk) ->
    @_buffer += chunk

    while (index = @_buffer.indexOf("\n")) != -1
      line     = @_buffer[0...index]
      @_buffer = @_buffer[index+1...@_buffer.length]

      @emit 'data', line

  end: (args...) ->
    if args.length > 0
      @write args...

    @emit 'end'
