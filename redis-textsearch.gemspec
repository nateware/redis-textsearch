spec = Gem::Specification.new do |s|
  s.name = 'redis-textsearch'
  s.version = '0.1.0'
  s.summary = "Fast text search and word indexes using Redis"
  s.description = %{Redis::TextSearch is a lightweight library that enables indexed text search from any class or data store}
  s.files = Dir['lib/**/*.rb'] + Dir['spec/**/*.rb']
  s.require_path = 'lib'
  s.autorequire = 'redis/text_search'
  s.has_rdoc = true
  s.extra_rdoc_files = Dir['[A-Z]*']
  s.rdoc_options << '--title' <<  'Redis::TextSearch -- Fast text search using Redis'
  s.author = "Nate Wiger"
  s.email = "nate@wiger.org"
  s.homepage = "http://github.com/nateware/redis-textsearch"
end
