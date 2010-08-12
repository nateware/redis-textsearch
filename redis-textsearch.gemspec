spec = Gem::Specification.new do |s|
  s.name = 'redis-textsearch'
  s.version = '0.2.0'
  s.summary = "Fast text search and word indexes using Redis"
  s.description = %{Crazy fast text search using Redis. Works with any ORM or data store.}
  s.files = Dir['lib/**/*.rb'] + Dir['spec/**/*.rb']
  s.require_path = 'lib'
  s.rubyforge_project = 'redis-textsearch'
  s.has_rdoc = true
  s.extra_rdoc_files = Dir['[A-Z]*']
  s.rdoc_options << '--title' <<  'Redis::TextSearch -- Crazy fast text search using Redis'
  s.author = "Nate Wiger"
  s.email = "nate@wiger.org"
  s.homepage = "http://github.com/nateware/redis-textsearch"
  s.requirements << 'redis, v2.0.4 or greater'
  s.add_dependency('redis', '>= 2.0.4')
end
