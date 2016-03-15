require 'socket'
require 'thread'

require 'ruby-mpd/version'
require 'ruby-mpd/exceptions'
require 'ruby-mpd/song'
require 'ruby-mpd/parser'
require 'ruby-mpd/playlist'

require 'ruby-mpd/plugins/information'
require 'ruby-mpd/plugins/playback_options'
require 'ruby-mpd/plugins/controls'
require 'ruby-mpd/plugins/queue'
require 'ruby-mpd/plugins/playlists'
require 'ruby-mpd/plugins/database'
require 'ruby-mpd/plugins/stickers'
require 'ruby-mpd/plugins/outputs'
require 'ruby-mpd/plugins/reflection'
require 'ruby-mpd/plugins/channels'

# @!macro [new] error_raise
#   @raise (see #send_command)
# @!macro [new] returnraise
#   @return [Boolean] returns true if successful.
#   @macro error_raise

# The main class/namespace of the MPD client.
class MPD
  include Parser

  include Plugins::Information
  include Plugins::PlaybackOptions
  include Plugins::Controls
  include Plugins::Queue
  include Plugins::Playlists
  include Plugins::Database
  include Plugins::Stickers
  include Plugins::Outputs
  include Plugins::Reflection
  include Plugins::Channels

  attr_reader :version, :hostname, :port

  # Initialize an MPD object with the specified hostname and port.
  # When called without arguments, 'localhost' and 6600 are used.
  #
  # When called with +callbacks: true+ as an optional argument,
  # callbacks will be enabled by starting a separate polling thread.
  #
  # @param [String] hostname Hostname of the daemon
  # @param [Integer] port Port of the daemon
  # @param [Hash] opts Optional parameters. Currently accepts +callbacks+
  def initialize(hostname = 'localhost', port = 6600, opts = {})
    @hostname = hostname
    @port = port
    @options = {callbacks: false}.merge(opts)
    @password = opts.delete(:password) || nil
    @socket = [nil, nil]
    reset_vars

    @mutex = Mutex.new
    @callbacks = {}
  end

  # This will register a block callback that will trigger whenever
  # that specific event happens.
  #
  #   mpd.on :volume do |volume|
  #     puts "Volume was set to #{volume}!"
  #   end
  #
  # One can also define separate methods or Procs and whatnot,
  # just pass them in as a parameter.
  #
  #  method = Proc.new {|volume| puts "Volume was set to #{volume}!" }
  #  mpd.on :volume, &method
  #
  # @param [Symbol] event The event we wish to listen for.
  # @param [Proc, Method] block The actual callback.
  # @return [void]
  def on(event, &block)
    (@callbacks[event] ||= []).push block
  end

  # Triggers an event, running it's callbacks.
  # @param [Symbol] event The event that happened.
  # @return [void]
  def emit(event, *args)
    return unless @callbacks[event]
    @callbacks[event].each { |handle| handle.call(*args) }
  end

  # Connect to the daemon.
  #
  # When called without any arguments, this will just connect to the server
  # and wait for your commands.
  #
  # @return [true] Successfully connected.
  # @raise [MPDError] If connect is called on an already connected instance.
  def connect(ctx_idle = false)
    raise ConnectionError, 'Already connected!' if connected?(ctx_idle)

    # by protocol, we need to get a 'OK MPD <version>' reply
    # should we fail to do so, the connection was unsuccessful
    unless response = socket(ctx_idle).gets
      reset_vars(ctx_idle)
      raise ConnectionError, 'Unable to connect (possibly too many connections open)'
    end

    send_command(:password, @password){ctx_idle} if @password
    @version = response.chomp.gsub('OK MPD ', '') # Read the version

    #if callbacks
    #  warn "Using 'true' or 'false' as an argument to MPD#connect has been deprecated, and will be removed in the future!"
    #  @options.merge!(callbacks: callbacks)
    #end

    callback_thread if @options[:callbacks]
    return true
  end

  # Check if the client is connected.
  #
  # @return [Boolean] True only if the server responds otherwise false.
  def connected?(ctx_idle = false)
    return false unless socket(ctx_idle, false)
    send_command(:ping){ctx_idle} rescue false
  end

  # Disconnect from the MPD daemon. This has no effect if the client is not
  # connected. Reconnect using the {#connect} method. This will also stop
  # the callback thread, thus disabling callbacks.
  # @return [Boolean] True if successfully disconnected, false otherwise.
  def disconnect(ctx_idle = false)
    if @cb_thread && !ctx_idle
      @cb_thread[:stop] = true
      socket(true, false).puts 'noidle'
    end

    s = socket(ctx_idle, false)
    return false unless s

    begin
      s.puts 'close'
      s.close
    rescue Errno::EPIPE
      # socket was forcefully closed
    end

    reset_vars(ctx_idle)
    return true
  end

  # Attempts to reconnect to the MPD daemon.
  # @return [Boolean] True if successfully reconnected, false otherwise.
  def reconnect(ctx_idle = false)
    disconnect(ctx_idle)
    connect(ctx_idle)
  end

  # Kills the MPD process.
  # @macro returnraise
  def kill
    send_command :kill
  end

  # Used for authentication with the server.
  # @param [String] pass Plaintext password
  # @macro returnraise
  def password(pass)
    send_command :password, pass
  end

  def authenticate
    send_command(:password, @password) if @password
  end

  # Ping the server.
  # @macro returnraise
  def ping
    send_command :ping
  end

  # Used to send a command to the server, and to recieve the reply.
  # Reply gets parsed. Synchronized on a mutex to be thread safe.
  #
  # Can be used to get low level direct access to MPD daemon. Not
  # recommended, should be just left for internal use by other
  # methods.
  #
  # @return (see #handle_server_response)
  # @raise [MPDError] if the command failed.
  def send_command(command, *args, &ctx)
    ctx_idle = block_given? && ctx.call
    raise ConnectionError, "Not connected to the server!" unless socket(ctx_idle)

    @mutex.lock unless ctx_idle
    begin
      socket(ctx_idle).puts convert_command(command, *args)
      response = handle_server_response(ctx_idle)
      return parse_response(command, response)
    rescue Errno::EPIPE, ConnectionError
      reconnect
      retry
    ensure
      @mutex.unlock unless ctx_idle
    end
  end

private

  # Initialize instance variables on new object, or on disconnect.
  def reset_vars(ctx_idle = false)
    @socket[ctx_idle ? 0 : 1] = nil
    @version = nil
    @tags = nil
  end

  IDLE_CALLBACKS = Set[:subscription, :sticker, :output, :stored_playlist]

  # Constructs a callback loop thread and/or resumes it.
  # @return [Thread]
  def callback_thread
    @cb_thread ||= Thread.new(self) do |mpd|
      old_status = {}

      while true
        mpd.connect(true) unless mpd.connected?(true)

        change = mpd.send_command(:idle){true}
        status = mpd.status rescue {}

        status[:connection] = mpd.connected?

        status[:time] ||= [nil, nil] # elapsed, total
        status[:audio] ||= [nil, nil, nil] # samp, bits, chans
        status[:song] = mpd.current rescue nil
        status[:updating_db] ||= nil
        status[change] = true if IDLE_CALLBACKS.include? change

        status.each do |key, val|
          next if val == old_status[key] # skip unchanged keys
          emit key, *val # splat arrays
        end

        IDLE_CALLBACKS.each do |key|
          status.delete key
        end

        old_status = status
        sleep 0.1

        if Thread.current[:stop]
          mpd.disconnect(true)
          Thread.stop
        end
      end
    end
    @cb_thread[:stop] = false
    @cb_thread.run if @cb_thread.stop?
  end

  # Handles the server's response (called inside {#send_command}).
  # Repeatedly reads the server's response from the socket.
  #
  # @return (see Parser#build_response)
  # @return [true] If "OK" is returned.
  # @raise [MPDError] If an "ACK" is returned.
  def handle_server_response(ctx_idle)
    msg = ''
    while true
      case line = socket(ctx_idle).gets
      when "OK\n"
        break
      when /^ACK/
        error = line
        break
      when nil
        raise ConnectionError, 'Connection closed'
      else
        msg << line
      end
    end

    return msg unless error
    err = error.match(/^ACK \[(?<code>\d+)\@(?<pos>\d+)\] \{(?<command>.*)\} (?<message>.+)$/)
    raise SERVER_ERRORS[err[:code].to_i], "[#{err[:command]}] #{err[:message]}"
  end

  def socket(ctx_idle = false, init = true)
    idx = ctx_idle ? 0 : 1
    if init
      @socket[idx] ||= File.exist?(@hostname) ? UNIXSocket.new(@hostname) : TCPSocket.new(@hostname, @port)
    end
    @socket[idx]
  end

  SERVER_ERRORS = {
    1 => NotListError,
    2 => ServerArgumentError,
    3 => IncorrectPassword,
    4 => PermissionError,
    5 => ServerError,

    50 => NotFound,
    51 => PlaylistMaxError,
    52 => SystemError,
    53 => PlaylistLoadError,
    54 => AlreadyUpdating,
    55 => NotPlaying,
    56 => AlreadyExists
  }

end
