module Fluent

class GELFOutput < BufferedOutput

  Plugin.register_output("gelf", self)

  config_param :use_record_host, :bool, :default => false
  config_param :add_msec_time, :bool, :default => false
  config_param :host, :string, :default => nil
  config_param :port, :integer, :default => 12201
  config_param :protocol, :string, :default => 'udp'

  # timestamp handling; main reason for this is that fluentd time ignores/loses sub-second precision
  config_param :xtime_override, :bool, :default => true
  config_param :xtime_key, :string, :default => 'stime'
  config_param :xtime_format, :string, :default => '%FT%T.%L%z' #ISO8601
  config_param :xtime_add_timezone, :bool, :default => false

  def initialize
    super
    require "gelf"
  end

  def configure(conf)
    super

    # a destination hostname or IP address must be provided
    raise ConfigError, "'host' parameter (hostname or address of Graylog2 server) is required" unless conf.has_key?('host')

    # choose protocol to pass to gelf-rb Notifier constructor
    # (@protocol is used instead of conf['protocol'] to leverage config_param default)
    if @protocol == 'udp' then @proto = GELF::Protocol::UDP
    elsif @protocol == 'tcp' then @proto = GELF::Protocol::TCP
    else raise ConfigError, "'protocol' parameter should be either 'udp' (default) or 'tcp'"
    end
  end

  def start
    super

    @conn = GELF::Notifier.new(@host, @port, 'WAN', {:facility => 'fluentd', :protocol => @proto})

    # Errors are not coming from Ruby so we use direct mapping
    @conn.level_mapping = 'direct'
    # file and line from Ruby are in this class, not relevant
    @conn.collect_file_and_line = false
  end

  def shutdown
    super
  end

  def format(tag, time, record)
    if defined? Fluent::EventTime and time.is_a? Fluent::EventTime then
      timestamp = time.sec + (time.nsec.to_f/1000000000).round(3)
    else
      timestamp = time
    end

    gelfentry = { :timestamp => timestamp, :_tag => tag }

    if @xtime_override
      if @xtime_add_timezone
        gelfentry[:timestamp] = DateTime.strptime(record[@xtime_key]+Time.now.zone, @xtime_format+'%z').strftime('%s.%L')
      else
        gelfentry[:timestamp] = DateTime.strptime(record[@xtime_key], @xtime_format).strftime('%s.%L')
      end
    end

    record.each_pair do |k,v|
      case k
      when 'version' then
        gelfentry[:_version] = v
      when 'timestamp' then
        gelfentry[:_timestamp] = v
      when 'host' then
        if @use_record_host then gelfentry[:host] = v
        else gelfentry[:_host] = v end
      when 'level' then
        case "#{v}".downcase
        # emergency and alert aren't supported by gelf-rb
        when '0', 'emergency' then gelfentry[:level] = GELF::UNKNOWN
        when '1', 'alert' then gelfentry[:level] = GELF::UNKNOWN
        when '2', 'critical', 'crit' then gelfentry[:level] = GELF::FATAL
        when '3', 'error', 'err' then gelfentry[:level] = GELF::ERROR
        when '4', 'warning', 'warn' then gelfentry[:level] = GELF::WARN
        # gelf-rb also skips notice
        when '5', 'notice' then gelfentry[:level] = GELF::INFO
        when '6', 'informational', 'info' then gelfentry[:level] = GELF::INFO
        when '7', 'debug' then gelfentry[:level] = GELF::DEBUG
        else gelfentry[:_level] = v
        end
      when 'short_message', 'full_message', 'facility', 'line', 'file' then
        gelfentry[k.to_sym] = v
      else
        gelfentry["_#{k}".to_sym] = v
      end
    end

    if !gelfentry.has_key?(:short_message) or gelfentry[:short_message].to_s.empty? then
      # allow other non-empty fields to masquerade as the short_message if it is unset
      if gelfentry.has_key?(:_message) and !gelfentry[:_message].to_s.empty? then
        gelfentry[:short_message] = gelfentry.delete(:_message)
      elsif gelfentry.has_key?(:_msg) and !gelfentry[:_msg].to_s.empty? then
        gelfentry[:short_message] = gelfentry.delete(:_msg)
      elsif gelfentry.has_key?(:_log) and !gelfentry[:_log].to_s.empty? then
        gelfentry[:short_message] = gelfentry.delete(:_log)
      elsif gelfentry.has_key?(:_record) and !gelfentry[:_record].to_s.empty? then
        gelfentry[:short_message] = gelfentry.delete(:_record)
      else
        # we must have a short_message, so provide placeholder
        gelfentry[:short_message] = '(no message)'
      end
    end

    gelfentry.to_msgpack
  end

  def write(chunk)
    chunk.msgpack_each do |data|
      @conn.notify!(data)
    end
  end

  def formatted_to_msgpack_binary
    true
  end
end


end

# vim: sw=2 ts=2 et
