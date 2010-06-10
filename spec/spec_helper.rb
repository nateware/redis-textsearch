$LOAD_PATH.unshift File.expand_path(File.dirname(__FILE__) + '/../lib')
require 'bacon'
Bacon.summary_on_exit

require 'redis'
require 'redis/text_search'

Redis::TextSearch.redis = Redis.new(:host => ENV['REDIS_HOST'], :port => ENV['REDIS_PORT'])
