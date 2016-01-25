# encoding: utf-8
#
require "logstash/codecs/base"
require "logstash/namespace"
require "json"
require "zlib"

#
# IOS XR 6.0.0 wire format
#
# JSON Telemetry encoding
#
# ----------------------------------
#
#       +-----+-+-+-...++-+-+-...+-+-+-...++-+-+-...+
#       | Len |T|L|V...||T|L|V...|T|L|V...||T|L|V...|
#       +-----+-+-+-...++-+-+-...+-+-+-...++-+-+-...+
#
# Len - Length of encoded blocks (excluding length)
#
# T   - TSCodecTLVType
# L   - Length of block
# V   - Block (T == TS_CODEC_TLV_TYPE_COMPRESSOR_RESET => 0 length)
#
# ----------------------------------
TS_CODEC_HEADER_LENGTH_IN_BYTES = 4
#
# Payload is encoded as TLV, with two types
#
module TSCodecTLVType
  #
  # Type 1 carries signal to reset decompressor. No content is carried
  # in the compressor reset.
  #
  TS_CODEC_TLV_TYPE_COMPRESSOR_RESET = 1
  #
  # Type 2 carries compressed JSON
  #
  TS_CODEC_TLV_TYPE_JSON = 2
end

#
# IOS XR 6.1.0 wire format (version 2)
#
# JSON Telemetry encoding
#
# ----------------------------------
#
#       +-+-+-+-...-++-+-+-+-...-++-+-+-+-...+
#       |T|F|L|V... ||T|F|L|V... ||T|F|L|V...|
#       +-+-+-+-...-++-+-+-+-...-++-+-+-+-...+
#
# T   - 32 bits, type (JSON == 2), currently the only supported value (GPB
#       variant over TCP not supported by codec yet) TSCodecTLVTypeV2
# F   - 32 bits, 0x1 indicates ZLIB compression
# L   - Length of block excluding header
# V   - Data block
#
# ----------------------------------

TS_CODEC_HEADER_LENGTH_IN_BYTES_V2 = 12

module TSCodecTLVTypeV2
  #
  # Type 1 carries signal to reset decompressor. No content is carried
  # in the compressor reset.
  #
  TS_CODEC_TLV_TYPE_V2_JSON = 2
end

#
# Outermost description of the messages in the stream
#
module TSCodecState
  TS_CODEC_PENDING_HEADER = 1
  TS_CODEC_PENDING_DATA = 2
end

#
# The transport employing this codec will typically create
# multiple instances of the codec object and will typically do
# so in multiple threads (e.g. TCP spawns multiple threads
# with a codec per thread.)
#
# To turn on debugging, modify LS_OPTS in /etc/default/logstash to
# LS_OPTS="--debug"
#
# To view debugs, look at the file pointed at by LS_LOG_FILE
# which defaults to /var/log/logstash/logstash.log
#
class LogStash::Codecs::Telemetry < LogStash::Codecs::Base
  config_name "telemetry"

  #
  # Pick transformation we choose to apply in codec. The choice will
  # depend on the output plugin and downstream consumer.
  #
  # flat: flattens the JSON tree into path (as in path from root to leaf),
  #       and type (leaf name), and value.
  #  raw: passes the JSON segments as received.
  #
  config :xform, :validate => ["flat", "raw"], :default => "flat"

  #
  # Table of regexps is used when flattening, to identify the point to
  # flatten to down the JSON tree.
  #
  config :xform_flat_keys, :validate => :hash, :default => {}

  #
  # When flattening, we use a delimeter in the flattened path.
  #
  config :xform_flat_delimeter, :validate => :string, :default => "~"

  #
  # Wire format version number.
  #
  # XR 6.0 streams to the default version 1
  # XR 6.1 streams and later, require wire_format 2.
  #
  config :wire_format, :validate => :number, :default => 1

  #
  # Change state to reflect whether we are waiting for length or data.
  #
  private
  def ts_codec_change_state(state, pending_bytes)

    @logger.debug? &&
      @logger.debug("state transition", :from_state => @codec_state,
                    :to_state => state, :wait_for => pending_bytes)

    @codec_state = state
    @pending_bytes = pending_bytes
  end

  private
  def ts_codec_extract_path_key_value(path, data, filter_table, depth)
    #
    # yield path,type,value triples from "Data" hash
    #
    data.each do |branch,v|

      path_and_branch = path + @xform_flat_delimeter + branch
      new_filter_table = []
      yielded = false

      #
      # Let's see if operator configuration wishes to consider the
      # prefix path+branch as an atomic event. The rest of the branch
      # will contributed event content. Apply filters, and if we have
      # an exact match yield event:
      #
      # path=path+branch (matching filter),
      # type=<configured name assoc with filter>,
      # content (remaining branch, and possibly, extracted key)
      #
      # (If we have a prefix match as opposed to complete match, we
      # need to keep going down the JSON tree. Build table of
      # applicable subset of filters for next level down)
      #
      if not filter_table.nil?
        filter_table.each do |name_and_filter_hash|

          #
          # We avoid using shift and instead use depth index to
          # avoid cost of mutating and copying filters.  Yet another
          # argument to organise filters as tree.
          #
          filter = name_and_filter_hash[:filter]
          filter_regexp = filter[depth]
          if filter_regexp
            match = branch.match(filter_regexp)
            if match

              if (depth == 0)
                #
                # Looks like we're going to use this filter and we may
                # collect captured matches and carry them all the way
                # down. Discard any stale state at this point.
                #
                name_and_filter_hash[:captured_matches] = []
              end

              #
              # We have a complete match and can terminate here.
              #
              if not match.names.empty?
                #
                # If the key regexp captured any part of the path, we
                # track the captured named matches as an array of
                # pairs.
                #
                match.names.each do |fieldname|
                  name_and_filter_hash[:captured_matches] <<
                    [fieldname, match[fieldname]]
                end
              end # Captured fields in path

              if not filter[depth+1]

                #
                # We're out here on this branch. Collect all the captured
                # matches, and set them up as key, along with the subtree
                # beneath this point and yield
                #
                if name_and_filter_hash.empty?
                  value = v
                else
                  value = {
                    name_and_filter_hash[:name] => v,
                    "key" => Hash[name_and_filter_hash[:captured_matches]]
                  }
                end

                yield path_and_branch, name_and_filter_hash[:name], value
                #
                # Force move to next outer iteration - i.e. next key
                # in object at this level. Could use exception or
                # throw/catch.
                #
                yielded = true
                break

              else # We have a prefix match
                #
                # Filter matches at this level but there are more
                # level in the filter. Add reference to name and
                # filter hash in filter table for the next level.
                #
                new_filter_table << name_and_filter_hash
              end # full or prefix match

            end # match or no match of current level

          end # do we have a filter for this level
        end # filter iteration
      end # do we even have a filter table?

      if yielded
        next
      end

      if v.is_a? Hash

        #
        # Lets walk down into this object and see what it yields.
        #
        ts_codec_extract_path_key_value(path_and_branch, v,
                                        new_filter_table, depth + 1) do
          |newp, newk, newv|
          yield newp, newk, newv
        end

      else # This is not a hash, and therefore will be yielded (note: arrays too)
        yield path, branch, v
      end
    end # branch, v iteration over hash passed down
  end # ts_codec_extract_path_key_value


  public
  def register
    #
    # Initialise the state of the codec. Codec is always cloned from
    # this state.
    #
    @partial_stream = nil
    @codec_state = TSCodecState::TS_CODEC_PENDING_HEADER
    @zstream = Zlib::Inflate.new
    @data_compressed = 0

    if (@wire_format == 2)
      @pending_bytes = TS_CODEC_HEADER_LENGTH_IN_BYTES_V2
    else
      @pending_bytes = TS_CODEC_HEADER_LENGTH_IN_BYTES
    end

    @logger.info("Registering cisco telemetry stream codec")

    #
    # Preprocess the regexps strings provided, and build them out into
    # an array of hashes of the form (name, filter).
    #
    # filter Each is an array of regexps for every level in a path
    # down the JSON tree. We could have requested a JSON tree in
    # configuration, but this will be easier to configure.
    #
    filter_atom_arrays = []
    @filter_table = []

    begin
      @xform_flat_keys.each do |keyname, keyfilter|

        filter_atoms = keyfilter.split(@xform_flat_delimeter)
        filter_regexps = filter_atoms.map do |atom|
          Regexp.new("^" + atom + "$")
        end

        @filter_table << {
          :name => keyname,
          :filter => filter_regexps,
          :captured_matches => []}
      end
    rescue
      raise(LogStash::ConfigurationError, "xform_flat_keys processing failed")
    end

    if @xform == "flat"
      @logger.info("xform_flat filter table",
                   :filter_table => @filter_table.to_s)
    end

  end

  public
  def decode(data)

    connection_thread = Thread.current

    @logger.debug? &&
      @logger.debug("Transport passing data down",
                    :thread => connection_thread.to_s,
                    :length => data.length,
                    :prepending => @partial_data.nil? ? 0 : @partial_data.length,
                    :waiting_for => @pending_bytes)
    unless @partial_data.nil?
      data = @partial_data + data
      @partial_data = nil
    end

    while data.length >= @pending_bytes

      case @codec_state

      when TSCodecState::TS_CODEC_PENDING_HEADER
        #
        # Handle message header - just currently one field, length.
        #
        if (@wire_format == 2)
          next_message_type, @data_compressed, next_msg_length_in_bytes, data =
            data.unpack('NNNa*')
          #
          # In v2, compressor is never reset and a compressor per session is
          # used.
          #
          if next_message_type != TSCodecTLVTypeV2::TS_CODEC_TLV_TYPE_V2_JSON
            raise "Unexpected message type for v2 (v1 stream from XR 6.0?)"
          end
        else
          next_msg_length_in_bytes, data = data.unpack('Na*')
        end
        ts_codec_change_state(TSCodecState::TS_CODEC_PENDING_DATA,
                              next_msg_length_in_bytes)

      when TSCodecState::TS_CODEC_PENDING_DATA
        #
        # Extract the message expected without loosing track of remaining
        # data, and switch state ready for message header.
        #
        msg, data = data.unpack("a#{@pending_bytes}a*")

        if (@wire_format == 2)
          l = @pending_bytes
          ts_codec_change_state(TSCodecState::TS_CODEC_PENDING_HEADER,
                                TS_CODEC_HEADER_LENGTH_IN_BYTES_V2)
        else
          ts_codec_change_state(TSCodecState::TS_CODEC_PENDING_HEADER,
                                TS_CODEC_HEADER_LENGTH_IN_BYTES)
        end

        while msg != ""

          if (@wire_format == 2)
            #
            # Set type to JSON, asserted in header processing above
            #
            t = TSCodecTLVType::TS_CODEC_TLV_TYPE_JSON
          else
            t, l, msg = msg.unpack('NNa*')
            #
            # Format prior to v2 was always COMPRESSED JSON
            #
            @data_compressed = 1
          end
  
          case t

          when TSCodecTLVType::TS_CODEC_TLV_TYPE_JSON
            
            v, msg = msg.unpack("a#{l}a*")
            #dump = v.unpack('H*')

            if @data_compressed == 1
              decompressed_unit = @zstream.inflate(v)
              @logger.debug? &&
              @logger.debug("Parsed message", :zmsgtype => t, :zmsglength => l,
                            :msglength => decompressed_unit.length,
                            :decompressor => @zstream)
            else
              decompressed_unit = v
            end

            begin
              parsed_unit = JSON.parse(decompressed_unit)
            rescue JSON::ParserError => e
              @logger.info("JSON parse error: add text message", :exception => e,
                           :data => decompressed_unit)
              yield LogStash::Event.new("unparsed_message" => decompressed_unit)
            end

            case @xform
            when "raw"
              @logger.debug? &&
                @logger.debug("Yielding raw event", :event => parsed_unit)
              yield LogStash::Event.new(parsed_unit)

            when "flat"
              #
              # Flatten JSON to path+type (key), value
              #
              ts_codec_extract_path_key_value("DATA",
                                              parsed_unit["Data"],
                                              @filter_table, 0) do
                |path,type,content|

                event = {"path" => path,
                  "type" => type,
                  "content" => content,
                  "identifier" => parsed_unit['Identifier'],
                  "policy_name" => parsed_unit['Policy'],
                  "version" => parsed_unit['Version'],
                  "end_time" => parsed_unit['End Time']}

                @logger.debug? &&
                  @logger.debug("Yielding flat event", :event => event)
                yield LogStash::Event.new(event)
              end

            else
              @logger.error("Unsupported xform", :xform => xform)
            end

          when TSCodecTLVType::TS_CODEC_TLV_TYPE_COMPRESSOR_RESET
            @zstream = Zlib::Inflate.new
            @logger.debug? &&
              @logger.debug("Yielding COMPRESSOR RESET  decompressor",
                            :decompressor => @zstream)

          else
            # default case, something's gone awry
            @logger.error("Resetting connection on unknown TLV type",
                           :type => t)
            raise 'Unexpected message type in TLV:. Reset connection'
          end

        end # end look through TLVs

      end # handling header or payload case
    end # working through message

    unless data.nil? or data.length == 0
      @partial_data = data
      @logger.debug? &&
        @logger.debug("Stashing data which has not been consumed "\
                      "until transport hands us the rest",
                      :msglength => @partial_data.length,
                      :waiting_for => @pending_bytes)
    else
      @partial_data = nil
    end

  end # def decode


  public
  def encode(event)
    # do nothing on encode for now
    @logger.info("cisco telemetry: no encode facility")
  end # def encode

end # class LogStash::Codecs::TelemetryStream
