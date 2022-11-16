require 'rails_helper'

RSpec.describe UnfollowService, type: :service do
  let(:sender) { Fabricate(:account, username: 'alice') }

  subject { UnfollowService.new }

  describe 'local' do
    let(:bob) { Fabricate(:user, email: 'bob@example.com', account: Fabricate(:account, username: 'bob')).account }

    before do
      sender.follow!(bob)
      subject.call(sender, bob)
    end

    it 'destroys the following relation' do
      expect(sender.following?(bob)).to be false
    end
  end

  describe 'remote ActivityPub' do
    let(:bob) { Fabricate(:user, email: 'bob@example.com', account: Fabricate(:account, username: 'bob', protocol: :activitypub, domain: 'example.com', inbox_url: 'http://example.com/inbox')).account }

    before do
      sender.follow!(bob)
      stub_request(:post, 'http://example.com/inbox').to_return(status: 200)
      subject.call(sender, bob)
    end

    it 'destroys the following relation' do
      expect(sender.following?(bob)).to be false
    end

    it 'sends an unfollow activity' do
      expect(a_request(:post, 'http://example.com/inbox')).to have_been_made.once
    end
  end

  describe 'remote ActivityPub (reverse)' do
    let(:bob) { Fabricate(:user, email: 'bob@example.com', account: Fabricate(:account, username: 'bob', protocol: :activitypub, domain: 'example.com', inbox_url: 'http://example.com/inbox')).account }

    before do
      bob.follow!(sender)
      stub_request(:post, 'http://example.com/inbox').to_return(status: 200)
      subject.call(bob, sender)
    end

    it 'destroys the following relation' do
      expect(bob.following?(sender)).to be false
    end

    it 'sends a reject activity' do
      expect(a_request(:post, 'http://example.com/inbox')).to have_been_made.once
    end
  end

  describe 'secondary datacenters' do
    let(:bob) { Fabricate(:user, email: 'bob@example.com', account: Fabricate(:account, username: 'bob')).account }

    before do
      sender.follow!(bob)
      allow(ENV).to receive(:fetch).with('SECONDARY_DCS', false).and_return('foo, bar')
    end

    it 'creates jobs for secondary datacenters' do
      Sidekiq::Testing.fake! do
        expect(Sidekiq::Queues['foo'].size).to eq(0)
        expect(Sidekiq::Queues['bar'].size).to eq(0)

        subject.call(sender, bob)        
        expect(Sidekiq::Queues['pull'].size).to eq(1)

        UnmergeWorker.perform_one

        expect(Sidekiq::Queues['foo'].size).to eq(2)
        expect(Sidekiq::Queues['bar'].size).to eq(2)
        expect(Sidekiq::Queues['foo'].first['class']).to eq(InvalidateFollowCacheWorker.name)
        expect(Sidekiq::Queues['foo'].second['class']).to eq(UnmergeWorker.name)

        Sidekiq::Worker.drain_all

        expect(Sidekiq::Queues['foo'].size).to eq(0)
        expect(Sidekiq::Queues['bar'].size).to eq(0)          
      end
    end
  end
end
