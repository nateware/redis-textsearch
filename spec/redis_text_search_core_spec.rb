
require File.expand_path(File.dirname(__FILE__) + '/spec_helper')

class Post
  include Redis::TextSearch

  text_index :title
  text_index :tags, :exact => true

  def self.text_search_find(ids, options)
    options.empty? ? ids : [ids, options]
  end

  def self.first(ids, options)
    
  end

  def initialize(attrib)
    @attrib = attrib
    @id = attrib[:id] || 1
  end
  def id; @id; end
  def method_missing(name, *args)
    @attrib[name] || super
  end
end

TITLES = [
  'Some plain text',
  'More plain textstring',
  'Come get somebody personal',
  '*Welcome to Nate\'s new BLOG!!',
]

TAGS = [
  ['personal', 'nontechnical'],
  ['mysql', 'technical'],
  ['gaming','technical']
]


describe Redis::TextSearch do
  before :all do
    @post  = Post.new(:title => TITLES[0], :tags => TAGS[0], :id => 1)
    @post2 = Post.new(:title => TITLES[1], :tags => TAGS[1], :id => 2)
    @post3 = Post.new(:title => TITLES[2], :tags => TAGS[2], :id => 3)
    
    @post.delete_text_indexes
    @post2.delete_text_indexes
    Post.delete_text_indexes(3)
  end

  after :all do
    @post.delete_text_indexes
    @post2.delete_text_indexes
    Post.delete_text_indexes(3)
  end
  
  it "should define text indexes in the class" do
    Post.text_indexes[:title][:key].should   == 'post:text_index:title'
    Post.text_indexes[:tags][:key].should == 'post:text_index:tags'
  end

  it "should update text indexes correctly" do
    @post.update_text_indexes
    @post2.update_text_indexes

    Post.redis.set_members('post:text_index:title:so').should == ['1']
    Post.redis.set_members('post:text_index:title:som').should == ['1']
    Post.redis.set_members('post:text_index:title:some').should == ['1']
    Post.redis.set_members('post:text_index:title:pl').sort.should == ['1','2']
    Post.redis.set_members('post:text_index:title:pla').sort.should == ['1','2']
    Post.redis.set_members('post:text_index:title:plai').sort.should == ['1','2']
    Post.redis.set_members('post:text_index:title:plain').sort.should == ['1','2']
    Post.redis.set_members('post:text_index:title:te').sort.should == ['1','2']
    Post.redis.set_members('post:text_index:title:tex').sort.should == ['1','2']
    Post.redis.set_members('post:text_index:title:text').sort.should == ['1','2']
    Post.redis.set_members('post:text_index:title:texts').should == ['2']
    Post.redis.set_members('post:text_index:title:textst').should == ['2']
    Post.redis.set_members('post:text_index:title:textstr').should == ['2']
    Post.redis.set_members('post:text_index:title:textstri').should == ['2']
    Post.redis.set_members('post:text_index:title:textstrin').should == ['2']
    Post.redis.set_members('post:text_index:title:textstring').should == ['2']
    Post.redis.set_members('post:text_index:tags:pe').should == []
    Post.redis.set_members('post:text_index:tags:per').should == []
    Post.redis.set_members('post:text_index:tags:pers').should == []
    Post.redis.set_members('post:text_index:tags:perso').should == []
    Post.redis.set_members('post:text_index:tags:person').should == []
    Post.redis.set_members('post:text_index:tags:persona').should == []
    Post.redis.set_members('post:text_index:tags:personal').should == ['1']
    Post.redis.set_members('post:text_index:tags:no').should == []
    Post.redis.set_members('post:text_index:tags:non').should == []
    Post.redis.set_members('post:text_index:tags:nont').should == []
    Post.redis.set_members('post:text_index:tags:nonte').should == []
    Post.redis.set_members('post:text_index:tags:nontec').should == []
    Post.redis.set_members('post:text_index:tags:nontech').should == []
    Post.redis.set_members('post:text_index:tags:nontechn').should == []
    Post.redis.set_members('post:text_index:tags:nontechni').should == []
    Post.redis.set_members('post:text_index:tags:nontechnic').should == []
    Post.redis.set_members('post:text_index:tags:nontechnica').should == []
    Post.redis.set_members('post:text_index:tags:nontechnical').should == ['1']
  end

  it "should search text indexes and return records" do
    Post.text_search('some').should == ['1']
    @post3.update_text_indexes
    Post.text_search('some').sort.should == ['1','3']
    Post.text_search('plain').sort.should == ['1','2']
    Post.text_search('plain','text').sort.should == ['1','2']
    Post.text_search('plain','textstr').sort.should == ['2']
    Post.text_search('some','text').sort.should == ['1']
    Post.text_search('nontechnical').sort.should == ['1']
    Post.text_search('personal').sort.should == ['1','3']
    Post.text_search('personal', :fields => :tags).sort.should == ['1']
    Post.text_search('personal', :fields => [:tags]).sort.should == ['1']
    Post.text_search('nontechnical', :fields => [:title]).sort.should == []
  end
  
  
  it "should delete text indexes" do
    @post.delete_text_indexes
    @post.text_indexes.should == []
  end
  
  it "should pass options thru to find" do
    Post.text_search('some', :order => 'updated_at desc').should == [['3'], {:order=>"updated_at desc"}]
    Post.text_search('some', :select => 'id,username').should == [['3'], {:select => 'id,username'}]
  end
  
  xit "should have a text_filter method" do
    Post.text_filter(:tags, 'technical')
    Post.text_filter([:tags, 'technical'], [:title, 'some', 'where'])
    Post.text_filter(:tags => ['technical','ruby'], :title => 'some')  # IN
    Post.text_filter(:tags => 'technical', :title => 'some')
  end
end
