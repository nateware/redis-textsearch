# Redis::TextSearch - Use Redis to add text search to your app.
class Redis
  #
  # Redis::TextSearch enables high-performance text search in your app.
  #
  module TextSearch
    class NoFinderMethod < StandardError; end
    class BadTextIndex < StandardError; end

    class << self
      def redis=(conn) @redis = conn end
      def redis
        @redis ||= $redis || raise(NotConnected, "Redis::TextSearch.redis not set to a Redis.new connection")
      end

      def included(klass)
        klass.instance_variable_set('@redis', @redis)
        klass.instance_variable_set('@text_indexes', {})
        klass.instance_variable_set('@finder_method', nil)
        klass.send :include, InstanceMethods
        klass.extend ClassMethods
        klass.guess_finder_method
      end
    end

    # These class methods are added to the class when you include Redis::TextSearch.
    module ClassMethods
      attr_accessor :redis
      attr_reader :text_indexes

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
      # +finder_method+ class method that takes an array of IDs as an argument.
      def guess_finder_method
        if defined?(ActiveRecord::Base) and is_a?(ActiveRecord::Base)
          instance_eval <<-EndMethod
            def finder_method(ids, options)
              all(options.merge(:conditions => {:#{primary_key} => ids}))
            end
          EndMethod
        elsif defined?(MongoRecord::Base) and is_a?(MongoRecord::Base)
          instance_eval <<-EndMethod
            def finder_method(ids, options)
              all(options.merge(:conditions => {:#{primary_key} => ids}))
            end
          EndMethod
        elsif respond_to?(:get)
          # DataMapper::Resource is an include, so is_a? won't work
          instance_eval <<-EndMethod
            def finder_method(ids, options)
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
        fields = Array(options[:fields] || @text_indexes.keys)
        unless defined?(:finder_method)
          raise NoFinderMethod, "Could not detect how to find records; you must def finder_method()"
        end

        # Assemble set names for our intersection
        # Must loop for each field, since it's an "or"
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
        finder_method(ids, options)
      end
    end

    module InstanceMethods #:nodoc:
      def redis() self.class.redis end
        
      # Update all text indexes for the given object.  Should be used in an +after_save+ hook
      # or other applicable area, for example r.update_text_indexes.  Can pass an array of
      # field names to restrict updates just to those fields.
      def update_text_indexes(*fields)
        fields = self.class.text_indexes.keys if fields.empty?
        fields.each do |name|
          options = self.class.text_indexes[name]
          value  = self.send(name)
          return false if value.length < options[:minlength]
          values = value.is_a?(Array) ? value : options[:split] ? value.split(options[:split]) : value
          values.each do |val|
            val.gsub!(/[^\w\s]+/,'')
            val.downcase!
            next if value.length < options[:minlength]
            if options[:exact]
              str = val.gsub(/\s+/, '.')  # can't have " " in Redis cmd string
              redis.sadd("#{options[:key]}:#{str}", id)
            else
              len = options[:minlength]
              redis.pipelined do |cmd|
                while len < val.length
                  str = val[0..len].gsub(/\s+/, '.')  # can't have " " in Redis cmd string
                  # puts "Post.redis.set_members('#{options[:key]}:#{str}').should == ['1']"
                  cmd.sadd("#{options[:key]}:#{str}", id)
                  len += 1
                end
              end
            end
          end
        end
      end
    end
  end
end
