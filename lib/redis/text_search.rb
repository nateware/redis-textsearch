# Redis::TextSearch - Use Redis to add text search to your app.
class Redis
  #
  # Redis::TextSearch enables high-performance text search in your app using
  # Redis.  You can perform text search on any type of data store or ORM.
  #
  module TextSearch
    class NoFinderMethod < StandardError; end
    class BadTextIndex < StandardError; end
    class BadConditions < StandardError; end

    DEFAULT_EXCLUDE_LIST = %w(a an and as at but by for in into of on onto to the)

    dir = File.expand_path(__FILE__.sub(/\.rb$/,''))
    autoload :Collection, File.join(dir, 'collection')

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
        klass.extend WpHelpers unless respond_to?(:wp_count)
        class << klass
          define_method(:per_page) { 30 } unless respond_to?(:per_page)
        end
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
      def text_search_find(ids, options)
        if defined?(ActiveModel)
          # guess that we're on Rails 3
          raise "text_search_find not implemented for Rails 3 (yet) - patches welcome"
        elsif defined?(ActiveRecord::Base) and ancestors.include?(ActiveRecord::Base)
          merge_text_search_conditions!(ids, options)
          all(options)
        elsif defined?(Sequel::Model) and ancestors.include?(Sequel::Model)
          self[primary_key.to_sym => ids].filter(options)
        elsif defined?(DataMapper::Resource) and included_modules.include?(DataMapper::Resource)          
          get(options.merge(primary_key.to_sym => ids))
        end
      end

      def merge_text_search_conditions!(ids, options)
        pk = "#{table_name}.#{primary_key}"
        case options[:conditions]
        when Array
          if options[:conditions][1].is_a?(Hash)
            options[:conditions][0] = "(#{options[:conditions][0]}) AND #{pk} IN (:text_search_ids)"
            options[:conditions][1][:text_search_ids] = ids
          else
            options[:conditions][0] = "(#{options[:conditions][0]}) AND #{pk} IN (?)"
            options[:conditions] << ids
          end
        when Hash
          if options[:conditions].has_key?(primary_key.to_sym)
            raise BadConditions, "Cannot specify primary key (#{pk}) in :conditions to #{self.name}.text_search"
          end
          options[:conditions][primary_key.to_sym] = ids
        when String
          options[:conditions] = ["(#{options[:conditions]}) AND #{pk} IN (?)", ids]
        else
          options.merge!(:conditions => {primary_key => ids})
        end
      end

      # Define fields to be indexed for text search.  To update the index, you must call
      # update_text_indexes after record save or at the appropriate point.
      def text_index(*args)
        options = args.last.is_a?(Hash) ? args.pop : {}
        options[:minlength] ||= 2
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
        options = args.length > 1 && args.last.is_a?(Hash) ? args.pop : {}
        fields = Array(options.delete(:fields) || @text_indexes.keys)
        finder = options.delete(:finder)
        unless finder
          unless defined?(:text_search_find)
            raise NoFinderMethod, "Could not detect how to find records; you must def text_search_find()"
          end
          finder = :text_search_find
        end

        #
        # Assemble set names for our intersection.
        # Accept two ways of doing search: either {:field => ['value','value'], :field => 'value'},
        # or 'value','value', :fields => [:field, :field].  The first is an AND, the latter an OR.
        #
        ids = []
        if args.empty?
          raise ArgumentError, "Must specify search string(s) to #{self.name}.text_search"
        elsif args.first.is_a?(Hash)
          sets = []
          args.first.each do |f,v|
            sets += text_search_sets_for(f,v)
          end
          # Execute single intersection (AND)
          ids = redis.set_intersect(*sets)
        else
          fields.each do |f|
            sets = text_search_sets_for(f,args)
            # Execute intersection per loop (OR)
            ids += redis.set_intersect(*sets)
          end
        end

        # Assemble our options for our finder conditions (destructive for speed)
        recalculate_count = options.has_key?(:conditions)

        # Calculate pagination if applicable. Presence of :page indicates we want pagination.
        # Adapted from will_paginate/finder.rb
        if options.has_key?(:page)
          page = options.delete(:page) || 1
          per_page = options.delete(:per_page) || self.per_page

          Redis::TextSearch::Collection.create(page, per_page, nil) do |pager|
            # Convert page/per_page to limit/offset
            options.merge!(:offset => pager.offset, :limit => pager.per_page)
            if ids.empty?
              pager.replace([])
              pager.total_entries = 0
            else
              pager.replace(send(finder, ids, options){ |*a| yield(*a) if block_given? })
              pager.total_entries = recalculate_count ? wp_count(options, [], finder.to_s) : ids.length  # hacked into will_paginate for compat
            end
          end
        else
          # Execute finder directly
          ids.empty? ? [] : send(finder, ids, options)
        end
      end

      # Filter and return self. Chainable.
      def text_filter(field)
        raise UnimplementedError
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

      def text_search_sets_for(field, values)
        key = @text_indexes[field][:key]
        Array(values).collect do |val|
          str = val.downcase.gsub(/[^\w\s]+/,'').gsub(/\s+/, '.')  # can't have " " in Redis cmd string
          "#{key}:#{str}"
        end
      end
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
          value = self.send(field).to_s
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
              while len <= val.length
                str = val[0,len].gsub(/\s+/, '.')  # can't have " " in Redis cmd string
                indexes << "#{options[:key]}:#{str}"
                len += 1
              end
            end
          end
          
          # Also left-anchor the cropped string if "full" is specified
          if options[:full]
            val = values.join('.')
            len = options[:minlength]
            while len <= val.length
              str = val[0,len].gsub(/\s+/, '.')  # can't have " " in Redis cmd string
              indexes << "#{options[:key]}:#{str}"
              len += 1
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

    end # InstanceMethods
    
    module WpHelpers
      # Does the not-so-trivial job of finding out the total number of entries
      # in the database. It relies on the ActiveRecord +count+ method.
      def wp_count(options, args, finder)
        excludees = [:count, :order, :limit, :offset, :readonly]
        if defined?(ActiveRecord::Calculations)
          excludees << :from unless ActiveRecord::Calculations::CALCULATIONS_OPTIONS.include?(:from)
        end

        # we may be in a model or an association proxy
        klass = (@owner and @reflection) ? @reflection.klass : self

        # Use :select from scope if it isn't already present.
        options[:select] = scope(:find, :select) unless options[:select]

        if options[:select] and options[:select] =~ /^\s*DISTINCT\b/i
          # Remove quoting and check for table_name.*-like statement.
          if options[:select].gsub('`', '') =~ /\w+\.\*/
            options[:select] = "DISTINCT #{klass.table_name}.#{klass.primary_key}"
          end
        else
          excludees << :select # only exclude the select param if it doesn't begin with DISTINCT
        end

        # count expects (almost) the same options as find
        count_options = options.except *excludees

        # merge the hash found in :count
        # this allows you to specify :select, :order, or anything else just for the count query
        count_options.update options[:count] if options[:count]

        # forget about includes if they are irrelevant (Rails 2.1)
        # if count_options[:include] and
        #     klass.private_methods.include_method?(:references_eager_loaded_tables?) and
        #     !klass.send(:references_eager_loaded_tables?, count_options)
        #   count_options.delete :include
        # end

        # we may have to scope ...
        counter = Proc.new { count(count_options) }

        count = if finder.index('find_') == 0 and klass.respond_to?(scoper = finder.sub('find', 'with'))
                  # scope_out adds a 'with_finder' method which acts like with_scope, if it's present
                  # then execute the count with the scoping provided by the with_finder
                  send(scoper, &counter)
                elsif finder =~ /^find_(all_by|by)_([_a-zA-Z]\w*)$/
                  # extract conditions from calls like "paginate_by_foo_and_bar"
                  attribute_names = $2.split('_and_')
                  conditions = construct_attributes_from_arguments(attribute_names, args)
                  with_scope(:find => { :conditions => conditions }, &counter)
                else
                  counter.call
                end

        count.respond_to?(:length) ? count.length : count
      end

    end  # WpHelpers
    
  end
end
