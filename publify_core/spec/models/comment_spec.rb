require 'rails_helper'
require 'support/dns_mock'

describe Comment, type: :model do
  let(:blog) { build_stubbed :blog }

  let(:published_article) { build_stubbed(:article, published_at: Time.now - 1.hour, blog: blog) }

  def valid_comment(options = {})
    Comment.new({ author: 'Bob', article: published_article, body: 'nice post', ip: '1.2.3.4' }.merge(options))
  end

  describe '#permalink_url' do
    before(:each) do
      @c = build_stubbed(:comment)
    end

    subject { @c.permalink_url }

    it 'should render permalink to comment in public part' do
      is_expected.to eq("#{@c.article.permalink_url}#comment-#{@c.id}")
    end
  end

  describe '#save' do
    it 'should save good comment' do
      c = build(:comment, url: 'http://www.google.de')
      assert c.save
      assert_equal 'http://www.google.de', c.url
    end

    it 'should save spam comment' do
      c = build(:comment, body: 'test <a href="http://fakeurl.com">body</a>')
      assert c.save
      assert_equal 'http://fakeurl.com', c.url
    end

    it 'does not save when article comment window is closed' do
      article = build :article, published_at: 1.year.ago
      article.blog.sp_article_auto_close = 30
      comment = build(:comment, author: 'Old Spammer', body: 'Old trackback body', article: article)
      expect(comment.save).to be_falsey
      expect(comment.errors[:article_id]).not_to be_empty
    end

    it 'should change old comment' do
      c = build(:comment, body: 'Comment body <em>italic</em> <strong>bold</strong>')
      assert c.save
      assert c.errors.empty?
    end

    it 'should save a valid comment' do
      c = build :comment
      expect(c.save).to be_truthy
      expect(c.errors).to be_empty
    end

    it 'should not save with article not allow comment' do
      c = build(:comment, article: build_stubbed(:article, allow_comments: false))
      expect(c.save).not_to be_truthy
      expect(c.errors).not_to be_empty
    end
  end

  describe '#save' do
    it 'should generate guid' do
      c = build :comment, guid: nil
      assert c.save
      assert c.guid.size > 15
    end

    it 'preserves urls starting with https://' do
      c = build :comment, url: 'https://example.com/'
      c.save
      expect(c.url).to eq('https://example.com/')
    end

    it 'preserves urls starting with http://' do
      c = build :comment, url: 'http://example.com/'
      c.save
      expect(c.url).to eq('http://example.com/')
    end

    it 'prepends http:// to urls without protocol' do
      c = build :comment, url: 'example.com'
      c.save
      expect(c.url).to eq('http://example.com')
    end
  end

  describe '#classify_content' do
    it 'should reject spam rbl' do
      comment = valid_comment(
        author: 'Spammer',
        body: <<-EOS,
          This is just some random text.
          &lt;a href="http://chinaaircatering.com"&gt;without any senses.&lt;/a&gt;.
          Please disregard.
        EOS
        url: 'http://buy-computer.us')
      comment.classify_content
      expect(comment).to be_spammy
      expect(comment).not_to be_status_confirmed
    end

    it 'should not define spam a comment rbl with lookup succeeds' do
      comment = valid_comment(author: 'Not a Spammer', body: 'Useful commentary!', url: 'http://www.bofh.org.uk')
      comment.classify_content
      expect(comment).not_to be_spammy
      expect(comment).not_to be_status_confirmed
    end

    it 'should reject spam with uri limit' do
      comment = valid_comment(author: 'Yet Another Spammer', body: %( <a href="http://www.one.com/">one</a> <a href="http://www.two.com/">two</a> <a href="http://www.three.com/">three</a> <a href="http://www.four.com/">four</a> ), url: 'http://www.uri-limit.com')
      comment.classify_content
      expect(comment).to be_spammy
      expect(comment).not_to be_status_confirmed
    end
  end

  it 'should have good relation' do
    article = build_stubbed(:article)
    comment = build_stubbed(:comment, article: article)
    assert comment.article
    assert_equal article, comment.article
  end

  describe 'reject xss' do
    before(:each) do
      @comment = Comment.new do |c|
        c.body = 'Test foo <script>do_evil();</script>'
        c.author = 'Bob'
        c.article = build_stubbed(:article, blog: blog)
      end
    end
    ['', 'textile', 'markdown', 'smartypants', 'markdown smartypants'].each do |filter|
      it "should reject with filter '#{filter}'" do
        # XXX: This makes sure text filter can be 'found' in the database
        # FIXME: TextFilter objects should not be in the database!
        sym = filter.empty? ? :none : filter.to_sym
        create sym

        blog.comment_text_filter = filter

        assert @comment.html(:body) !~ /<script>/
      end
    end
  end

  describe 'change state' do
    it 'should become unpublished if withdrawn' do
      c = build :comment
      assert c.published?
      assert c.withdraw!
      assert !c.published?
      assert c.spam?
      assert c.status_confirmed?
    end

    it 'should becomes confirmed if withdrawn' do
      unconfirmed = build(:comment, state: 'presumed_ham')
      expect(unconfirmed).not_to be_status_confirmed
      unconfirmed.withdraw!
      expect(unconfirmed).to be_status_confirmed
    end
  end

  it 'should have good default filter' do
    blog = create :blog
    create :textile
    create :markdown
    blog.text_filter = :textile
    blog.comment_text_filter = :markdown
    a = create(:comment)
    assert_equal 'markdown', a.default_text_filter.name
  end

  describe '#classify_content' do
    describe 'with feedback moderation enabled' do
      before(:each) do
        allow(blog).to receive(:sp_global) { false }
        allow(blog).to receive(:default_moderate_comments) { true }
      end

      it 'should mark comment as presumably spam' do
        comment = Comment.new do |c|
          c.body = 'Test foo'
          c.author = 'Bob'
          c.article = build_stubbed(:article, blog: blog)
        end

        comment.classify_content

        assert !comment.published?
        assert comment.presumed_spam?
        assert !comment.status_confirmed?
      end

      it 'should mark comment from known user as confirmed ham' do
        comment = Comment.new do |c|
          c.body = 'Test foo'
          c.author = 'Henri'
          c.article = build_stubbed(:article, blog: blog)
          c.user = build_stubbed(:user)
        end

        comment.classify_content

        assert comment.published?
        assert comment.ham?
        assert comment.status_confirmed?
      end
    end
  end

  describe 'spam', integration: true do
    let!(:comment) { create(:comment, state: 'spam') }
    let!(:ham_comment) { create(:comment, state: 'ham') }
    it 'returns only spam comment' do
      expect(Comment.spam).to eq([comment])
    end
  end

  describe 'not_spam', integration: true do
    let!(:comment) { create(:comment, state: 'spam') }
    let!(:ham_comment) { create(:comment, state: 'ham') }
    let!(:presumed_spam_comment) { create(:comment, state: 'presumed_spam') }
    it 'returns all comment that not_spam' do
      expect(Comment.not_spam).to match_array [ham_comment, presumed_spam_comment]
    end
  end

  describe 'presumed_spam', integration: true do
    let!(:comment) { create(:comment, state: 'spam') }
    let!(:ham_comment) { create(:comment, state: 'ham') }
    let!(:presumed_spam_comment) { create(:comment, state: 'presumed_spam') }
    it 'returns only presumed_spam' do
      expect(Comment.presumed_spam).to eq([presumed_spam_comment])
    end
  end

  describe 'last_published', integration: true do
    let(:date) { DateTime.new(2012, 12, 23, 12, 47) }
    let!(:comment_1) { create(:comment, body: '1', created_at: date + 1.day) }
    let!(:comment_4) { create(:comment, body: '4', created_at: date + 4.days) }
    let!(:comment_2) { create(:comment, body: '2', created_at: date + 2.days) }
    let!(:comment_6) { create(:comment, body: '6', created_at: date + 6.days) }
    let!(:comment_3) { create(:comment, body: '3', created_at: date + 3.days) }
    let!(:comment_5) { create(:comment, body: '5', created_at: date + 5.days) }

    it 'respond only 5 last_published' do
      expect(Comment.last_published).to eq([comment_6, comment_5, comment_4, comment_3, comment_2])
    end
  end

  describe '#generate_html' do
    it 'renders email addresses in the body' do
      comment = build_stubbed(:comment, body: 'foo@example.com')
      expect(comment.generate_html(:body)).to match /mailto:/
    end
  end
end
