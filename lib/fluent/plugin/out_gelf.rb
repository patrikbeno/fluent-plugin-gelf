module Fluent

class GELFOutput < BufferedOutput

  Plugin.register_output("gelf", self)    

  config_param :use_record_host, :bool, :default => false
  config_param :add_msec_time, :bool, :default => false
  config_param :host, :string, :default => nil
  config_param :port, :integer, :default => 12201
  config_param :protocol, :string, :default => 'udp'
  config_param :time_format, :string, :default => '%FT%T.%L%z'

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
    # time parameter is in seconds, and all sub-second information is lost. Use value from original record
    gelfentry = { :timestamp => DateTime.strptime(record['time'], @time_format).strftime('%s.%L'), :_tag => tag }

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
      when 'msec' then
        # msec must be three digits (leading/trailing zeroes)
        if @add_msec_time then 
          gelfentry[:timestamp] = "#{time.to_s}.#{v}".to_f
        else
          gelfentry[:_msec] = v
        end
      when 'short_message', 'full_message', 'facility', 'line', 'file' then
        gelfentry[k] = v
      else
        gelfentry['_'+k] = v
      end
    end

    if !gelfentry.has_key?('short_message') then
      gelfentry[:short_message] = record.to_json
    end

    gelfentry.to_msgpack
  end

  def write(chunk)
    chunk.msgpack_each do |data|
      @conn.notify!(data)
    end
  end

end


end

# vim: sw=2 ts=2 et
