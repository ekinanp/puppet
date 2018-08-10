require 'spec_helper'

describe 'Puppet::Type::Group::Provider::Aix' do
  let(:provider_class) { Puppet::Type.type(:group).provider(:aix) }

  let(:resource) do
    Puppet::Type.type(:group).new(
      :name   => 'test_aix_user',
      :ensure => :present
    )
  end
  let(:provider) do
    provider_class.new(resource)
  end

  describe '.users_to_members' do
    it 'converts the users attribute to the members property' do
      expect(provider_class.users_to_members('foo,bar')).to eql(['foo', 'bar'])
    end
  end

  describe '.members_to_users' do
    it 'returns the members property as-is if it is not an Array' do
      expect(provider_class.members_to_users('members')).to eql('members')
    end

    it 'returns the members property as a comma-separated string if it is an Array' do
      expect(provider_class.members_to_users(['user1', 'user2'])).to eql('user1,user2')
    end
  end
end
