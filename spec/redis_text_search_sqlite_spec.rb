
require File.expand_path(File.dirname(__FILE__) + '/spec_helper')

require 'active_record'
ActiveRecord::Base.establish_connection(:adapter => 'sqlite3', :database => 'test.db')
ActiveRecord::Base.logger = Logger.new(STDOUT)

def check_result_ids(results, ids, sort=true)
  results.length.should == ids.length
  if results.length > 0
    results.first.should be_kind_of(ActiveRecord::Base)
  end
  if sort
    results.collect{|m| m.id}.sort.should == ids.sort
  else
    results.collect{|m| m.id}.should == ids
  end
end
  
class Post < ActiveRecord::Base
  include Redis::TextSearch
  include Marshal

  text_index :title
  text_index :tags, :exact => true
end

class CreatePosts < ActiveRecord::Migration
  def self.up
    create_table :posts do |t|
      t.string :title
      t.string :tags
      t.timestamps
    end
  end

  def self.down
    drop_table :posts
  end
end

TITLES = [
  'Some plain text',
  'More plain textstring comments',
  'Come get somebody personal comments',
  '*Welcome to Nate\'s new BLOG!!',
]

TAGS = [
  ['personal', 'nontechnical'],
  ['mysql', 'technical'],
  ['gaming','technical']
]


describe Redis::TextSearch do
  before :all do
    CreatePosts.up
    
    @post  = Post.new(:title => TITLES[0], :tags => TAGS[0] * ' ')
    # @post.id = 1
    @post.save!
    # sleep 1 # sqlite timestamps
    @post2 = Post.new(:title => TITLES[1], :tags => TAGS[1] * ' ')
    # @post2.id = 2
    @post2.save!
    # sleep 1 # sqlite timestamps
    @post3 = Post.new(:title => TITLES[2], :tags => TAGS[2] * ' ')
    # @post3.id = 3
    @post3.save!
    # sleep 1 # sqlite timestamps

    @post.delete_text_indexes
    @post2.delete_text_indexes
    Post.delete_text_indexes(3)
  end

  after :all do 
    CreatePosts.down
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
    check_result_ids Post.text_search('some'), [1]
    @post3.update_text_indexes
    check_result_ids Post.text_search('some'), [1,3]

    check_result_ids Post.text_search('plain'), [1,2]
    check_result_ids Post.text_search('plain','text'), [1,2]
    check_result_ids Post.text_search('plain','textstr'), [2]
    check_result_ids Post.text_search('some','TExt'), [1]
    check_result_ids Post.text_search('techNIcal'), [2,3]
    check_result_ids Post.text_search('nontechnical'), [1]
    check_result_ids Post.text_search('personal'), [1,3]
    check_result_ids Post.text_search('personAL', :fields => :tags), [1]
    check_result_ids Post.text_search('PERsonal', :fields => [:tags]), [1]
    check_result_ids Post.text_search('nontechnical', :fields => [:title]), []
  end

  it "should pass options thru to find" do
    check_result_ids Post.text_search('some', :order => 'id desc'), [3,1], false
    res = Post.text_search('some', :select => 'id,title', :order => 'tags desc')
    check_result_ids res, [1,3]
    res.first.title.should == TITLES[0]
    res.last.title.should == TITLES[2]

    error = nil
    begin
      res.first.tags
    rescue => error
    end
    error.should be_kind_of ActiveRecord::MissingAttributeError
    
    error = nil
    begin
      res.first.updated_at
    rescue => error
    end
    error.should be_kind_of ActiveRecord::MissingAttributeError

    error = nil
    begin
      res.first.created_at
    rescue => error
    end
    error.should be_kind_of ActiveRecord::MissingAttributeError
  end

  it "should handle pagination" do
    res = Post.text_search('some', :page => 1, :per_page => 1, :order => 'id desc')
    check_result_ids res, [3]
    res.total_entries.should == 2
    res.total_pages.should == 2
    res.per_page.should == 1
    res.current_page.should == 1

    res = Post.text_search('some', :page => 2, :per_page => 1, :order => 'id desc')
    check_result_ids res, [1]
    res.total_entries.should == 2
    res.total_pages.should == 2
    res.per_page.should == 1
    res.current_page.should == 2

    res = Post.text_search('some', :page => 2, :per_page => 5)
    check_result_ids res, []
    res.total_entries.should == 2
    res.total_pages.should == 1
    res.per_page.should == 5
    res.current_page.should == 2
  end

  it "should support a hash to the text_search method" do
    check_result_ids Post.text_search(:tags => 'technical'), [2,3]
    check_result_ids Post.text_search(:tags => 'nontechnical'), [1]
    check_result_ids Post.text_search(:tags => 'technical', :title => 'plain'), [2]
    check_result_ids Post.text_search(:tags => ['technical','MYsql'], :title => 'Mo'), [2]
    check_result_ids Post.text_search(:tags => ['technical','MYsql'], :title => 'some'), []
    check_result_ids Post.text_search(:tags => 'technical', :title => 'comments'), [2,3]
  end

  # MUST BE LAST!!!!!!
  it "should delete text indexes" do
    @post.delete_text_indexes
    @post2.delete_text_indexes
    Post.delete_text_indexes(3)
    @post.text_indexes.should == []
    @post2.text_indexes.should == []
    @post3.text_indexes.should == []
  end
end
