# Redis::TextSearch - Use Redis to add text search to your app.
class Redis
  #
  # Redis::TextSearch enables high-performance text search in your app.
  #
  module TextSearch
    class NoFinderMethod < StandardError; end
    class BadTextIndex < StandardError; end

    DEFAULT_EXCLUDE_LIST = %w(a an and as at but by for in into of on onto to)

    class << self
      def redis=(conn) @redis = conn end
      def redis
        @redis ||= $redis || raise(NotConnected, "Redis::TextSearch.redis not set to a Redis.new connection")
      end

      def included(klass)
        klass.instance_variable_set('@redis', @redis)
        klass.instance_variable_set('@text_indexes', {})
        klass.instance_variable_set('@text_search_find', nil)
        klass.instance_variable_set('@text_index_exclude_list', DEFAULT_EXCLUDE_LIST)
        klass.send :include, InstanceMethods
        klass.extend ClassMethods
        klass.guess_text_search_find
      end
    end

    # These class methods are added to the class when you include Redis::TextSearch.
    module ClassMethods
      attr_accessor :redis
      attr_reader :text_indexes
      
      # Words to exclude from text indexing.  By default, includes common
      # English prepositions like "a", "an", "the", "and", "or", etc.
      # This is an accessor to an array, so you can use += or << to add to it.
      # See the constant +DEFAULT_EXCLUDE_LIST+ for the default list.
      attr_accessor :text_index_exclude_list

      # Set the Redis prefix to use. Defaults to model_name
      def prefix=(prefix) @prefix = prefix end
      def prefix #:nodoc:
        @prefix ||= self.name.to_s.
          sub(%r{(.*::)}, '').
          gsub(/([A-Z]+)([A-Z][a-z])/,'\1_\2').
          gsub(/([a-z\d])([A-Z])/,'\1_\2').
          downcase
      end
      
      def field_key(name, id) #:nodoc:
        "#{prefix}:#{id}:#{name}"
      end
      
      # This is called when the class is imported, and uses reflection to guess
      # how to retrieve records.  You can override it by explicitly defining a
      # +text_search_find+ class method that takes an array of IDs as an argument.
      def guess_text_search_find
        if defined?(ActiveRecord::Base) and is_a?(ActiveRecord::Base)
          instance_eval <<-EndMethod
            def text_search_find(ids, options)
              all(options.merge(:conditions => {:#{primary_key} => ids}))
            end
          EndMethod
        elsif defined?(MongoRecord::Base) and is_a?(MongoRecord::Base)
          instance_eval <<-EndMethod
            def text_search_find(ids, options)
              all(options.merge(:conditions => {:#{primary_key} => ids}))
            end
          EndMethod
        elsif respond_to?(:get)
          # DataMapper::Resource is an include, so is_a? won't work
          instance_eval <<-EndMethod
            def text_search_find(ids, options)
              get(ids, options)
            end
          EndMethod
        end
      end

      # Define fields to be indexed for text search.  To update the index, you must call
      # update_text_indexes after record save or at the appropriate point.
      def text_index(*args)
        options = args.last.is_a?(Hash) ? args.pop : {}
        options[:minlength] ||= 1
        options[:split] ||= /\s+/
        raise ArgumentError, "Must specify fields to index to #{self.name}.text_index" unless args.length > 0
        args.each do |name|
          @text_indexes[name.to_sym] = options.merge(:key => field_key(name, 'text_index'))
        end
      end

      # Perform text search and return results from database. Options:
      #
      #   'string', 'string2'
      #   :fields
      #   :page
      #   :per_page
      def text_search(*args)
        options = args.last.is_a?(Hash) ? args.pop : {}
        fields = Array(options.delete(:fields) || @text_indexes.keys)
        finder = options.delete(:find)
        unless finder
          unless defined?(:text_search_find)
            raise NoFinderMethod, "Could not detect how to find records; you must def text_search_find()"
          end
          finder = :text_search_find
        end

        # Assemble set names for our intersection.  Must loop for each field, since it's an "or".
        # Accept two ways of doing search: either [:field, 'value'], [:field, 'value'], or
        # 'value','value', :fields => [:field, :field].  The first is an intersection, the latter
        # a union.
        if args.empty?
          
        
        
        raise ArgumentError, "Must specify search string(s) to #{self.name}.text_search" unless args.length > 0
        ids = []
        fields.each do |name|
          opts = @text_indexes[name].merge(options)
          keys = args.collect do |val|
            str = val.downcase.gsub(/[^\w\s]+/,'').gsub(/\s+/, '.')  # can't have " " in Redis cmd string
            "#{opts[:key]}:#{str}"
          end

          # Execute intersection
          if keys.length > 1
            ids += redis.set_intersect(*keys)
          else
            ids += redis.set_members(keys.first)
          end
        end

        # Calculate pagination if applicable
        if options[:page]
          per_page = options[:per_page] || self.respond_to?(:per_page) ? per_page : 10
        end

        # Execute finder
        send(finder, ids, options)
      end

      # Delete all text indexes for the given id.
      def delete_text_indexes(id, *fields)
        fields = @text_indexes.keys if fields.empty?
        fields.each do |field|
          redis.pipelined do |pipe|
            text_indexes_for(id, field).each do |key|
              pipe.srem(key, id)
            end
            pipe.del field_key("#{field}_indexes", id)
          end
        end
      end

      def text_indexes_for(id, field) #:nodoc:
        (redis.get(field_key("#{field}_indexes", id)) || '').split(';')
      end
    end
    
    # This applies a filter to the specified field and returns self. 
    def text_filter
      
    end

    module InstanceMethods #:nodoc:
      def redis() self.class.redis end
      def field_key(name) #:nodoc:
        self.class.field_key(name, id)
      end

      # Retrieve the options for the given field
      def text_index_options_for(field)
        self.class.text_indexes[field] ||
          raise(BadTextIndex, "No such text index #{field} in #{self.class.name}")
      end
      
      # Retrieve the reverse-mapping of text indexes for a given field.  Designed
      # as a utility method but maybe you will find it useful.
      def text_indexes_for(field)
        self.class.text_indexes_for(id, field)
      end
      
      # Retrieve all text indexes
      def text_indexes
        fields = self.class.text_indexes.keys
        fields.collect{|f| text_indexes_for(f)}.flatten
      end

      # Update all text indexes for the given object.  Should be used in an +after_save+ hook
      # or other applicable area, for example r.update_text_indexes.  Can pass an array of
      # field names to restrict updates just to those fields.
      def update_text_indexes(*fields)
        fields = self.class.text_indexes.keys if fields.empty?
        fields.each do |field|
          options = self.class.text_indexes[field]
          value = self.send(field)
          return false if value.length < options[:minlength]  # too short to index
          indexes = []

          # If values is array, like :tags => ["a", "b"], use as-is
          # Otherwise, split words on /\s+/ so :title => "Hey there" => ["Hey", "there"]
          values = value.is_a?(Array) ? value : options[:split] ? value.split(options[:split]) : value
          values.each do |val|
            val.gsub!(/[^\w\s]+/,'')
            val.downcase!
            next if value.length < options[:minlength]
            next if self.class.text_index_exclude_list.include? value
            if options[:exact]
              str = val.gsub(/\s+/, '.')  # can't have " " in Redis cmd string
              indexes << "#{options[:key]}:#{str}"
            else
              len = options[:minlength]
              while len < val.length
                str = val[0..len].gsub(/\s+/, '.')  # can't have " " in Redis cmd string
                indexes << "#{options[:key]}:#{str}"
                len += 1
              end
            end
          end

          # Determine what, if anything, needs to be done.  If the indexes are unchanged,
          # don't make any trips to Redis.  Saves tons of useless network calls.
          old_indexes = text_indexes_for(field)
          new_indexes = indexes - old_indexes
          del_indexes = old_indexes - indexes

          # No change, so skip
          # puts "[#{field}] old=#{old_indexes.inspect} / idx=#{indexes.inspect} / new=#{new_indexes.inspect} / del=#{del_indexes.inspect}"
          next if new_indexes.empty? and del_indexes.empty?

          # Add new indexes
          exec_pipelined_index_cmd(:sadd, new_indexes)

          # Delete indexes no longer used
          exec_pipelined_index_cmd(:srem, del_indexes)
          
          # Replace our reverse map of indexes
          redis.set field_key("#{field}_indexes"), indexes.join(';')
        end # fields.each
      end

      # Delete all text indexes that the object is a member of.  Should be used in
      # an +after_destroy+ hook to remove the dead object.
      def delete_text_indexes(*fields)
        fields = self.class.text_indexes.keys if fields.empty?
        fields.each do |field|
          del_indexes = text_indexes_for(field)
          exec_pipelined_index_cmd(:srem, del_indexes)
          redis.del field_key("#{field}_indexes")
        end
      end

      private
      
      def exec_pipelined_index_cmd(cmd, indexes)
        return if indexes.empty?
        redis.pipelined do |pipe|
          indexes.each do |key|
            pipe.send(cmd, key, id)
          end
        end
      end
      
    end
  end
end
