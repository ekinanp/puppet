#!/usr/bin/env ruby

require 'spec_helper'

# TODO: Some of these tests test dependencies that are beyond the scope
# of unit tests. For example, there's a lot of ADSI::User mocking going
# on. At some point, these should either be moved to integration tests,
# refactored to conform more to unit test standards, or be removed
# entirely.
describe Puppet::Type.type(:user).provider(:windows_adsi), :if => Puppet.features.microsoft_windows? do
  let(:resource) do
    Puppet::Type.type(:user).new(
      :title => 'testuser',
      :comment => 'Test J. User',
      :provider => :windows_adsi
    )
  end

  let(:provider) { resource.provider }
  let(:provider_class) { provider.class }

  let(:connection) { stub 'connection' }

  def stub_attributes(attributes)
    resource[:attributes] = attributes

    # When referencing resource[:attributes] in the provider code,
    # we reference the #should method of the attributes property.
    # This calls our getter, which is why we need to stub it here.
    provider.stubs(:attributes).returns(attributes) 
  end

  before :each do
    Puppet::Util::Windows::ADSI.stubs(:computer_name).returns('testcomputername')
    Puppet::Util::Windows::ADSI.stubs(:connect).returns connection
    # this would normally query the system, but not needed for these tests
    Puppet::Util::Windows::ADSI::User.stubs(:localized_domains).returns([])
  end

  describe ".instances" do
    it "should enumerate all users" do
      names = ['user1', 'user2', 'user3']
      stub_users = names.map{|n| stub(:name => n)}
      connection.stubs(:execquery).with('select name from win32_useraccount where localaccount = "TRUE"').returns(stub_users)

      expect(described_class.instances.map(&:name)).to match(names)
    end
  end

  it "should provide access to a Puppet::Util::Windows::ADSI::User object" do
    expect(provider.user).to be_a(Puppet::Util::Windows::ADSI::User)
  end

  describe "when retrieving the password property" do
    context "when the resource has a nil password" do
      it "should never issue a logon attempt" do
        resource.stubs(:[]).with(any_of(:name, :password)).returns(nil)
        Puppet::Util::Windows::User.expects(:logon_user).never
        provider.password
      end
    end
  end

  describe '#password=' do
    before(:each) do
      provider.user.stubs(:password=)
    end

    it "should set the user's password" do
      provider.user.expects(:password=).with('password')
      provider.user.expects(:set_userflags).with(:ADS_UF_DONT_EXPIRE_PASSWD)

      provider.password = 'password'
    end
  end

  describe '#attributes' do
    it 'should collect the current attributes on the system' do
      set_userflags   = [ :ADS_UF_ACCOUNTDISABLE ]
      unset_userflags = [ :ADS_UF_PASSWD_CANT_CHANGE ]

      set_userflags.each do |flag|
        provider.user.stubs(:userflag_set?).with(flag).returns(true)
      end
      unset_userflags.each do |flag|
        provider.user.stubs(:userflag_set?).with(flag).returns(false)
      end
      provider.user.stubs(:[]).with('FullName').returns('Johnny')

      expect(provider.attributes).to eql(
        {
          full_name: 'Johnny',
          account_disabled: 'true',
          password_change_not_allowed: 'false'
        }
      )
    end
  end

  describe "#validate_and_unmunge" do
    it "should not accept keys that aren't a part of the schema" do
      unmanaged_attributes = {
        :attribute_one => 'value_one',
        :attribute_two => 'value_two'
      }

      new_attributes = {
        :account_disabled => 'true',
        :password_change_required => 'true'
      }.merge(unmanaged_attributes)

      expect do
        provider.validate_and_unmunge(new_attributes)
      end.to raise_error(
        ArgumentError,
        /#{unmanaged_attributes.keys.join(', ')}.*#{provider.managed_attributes.join(', ')}/
      )
    end

    it "should raise an ArgumentError when it fails to unmunge an attribute" do
      attributes = {
        :account_disabled => 'foo',
      }

      expect do
        provider.validate_and_unmunge(attributes)
      end.to raise_error(
        ArgumentError,
        /Failed to unmunge.*account_disabled.*foo.*Boolean/
      )
    end

    it "should unmunge the attributes" do
      attributes = {
        :account_disabled            => 'true',
        :password_change_not_allowed => 'false',
        :full_name                   => 'Johnny'
      }
      unmunged_attributes = {
        :account_disabled            => true,
        :password_change_not_allowed => false,
        :full_name                   => 'Johnny'
      }

      expect(provider.validate_and_unmunge(attributes)).to eql(unmunged_attributes)
    end
  end

  describe "#attributes=" do
    def userflag_of(attribute)
      provider.userflag_of(attribute)
    end

    let(:user) { provider.user }

    it 'sets the new attributes' do
      new_attributes = {
        :full_name => 'Johnny',
        :account_disabled => 'true',
        :password_change_not_allowed => 'false'
      }

      user.expects(:[]=).with('FullName', 'Johnny')
      user.expects(:set_userflags).with(
        userflag_of(:account_disabled)
      )
      user.expects(:unset_userflags).with(
        userflag_of(:password_change_not_allowed)
      )

      provider.attributes = new_attributes
    end

    it 'can set userflag attributes' do
      new_attributes = {
        :account_disabled => 'true',
        :password_change_not_allowed => 'true'
      }

      user.expects(:set_userflags).with(
        userflag_of(:account_disabled),
        userflag_of(:password_change_not_allowed)
      )
      user.expects(:unset_userflags).with()

      provider.attributes = new_attributes
    end

    it 'can unset userflag attributes' do
      new_attributes = {
        :account_disabled => 'false',
        :password_change_not_allowed => 'false'
      }

      user.expects(:set_userflags).with()
      user.expects(:unset_userflags).with(
        userflag_of(:account_disabled),
        userflag_of(:password_change_not_allowed)
      )

      provider.attributes = new_attributes
    end
  end

  describe "when managing groups" do
    it 'should return the list of groups as an array of strings' do
      provider.user.stubs(:groups).returns nil
      groups = {'group1' => nil, 'group2' => nil, 'group3' => nil}
      Puppet::Util::Windows::ADSI::Group.expects(:name_sid_hash).returns(groups)

      expect(provider.groups).to eq(groups.keys)
    end

    it "should return an empty array if there are no groups" do
      provider.user.stubs(:groups).returns []

      expect(provider.groups).to eq([])
    end

    it 'should be able to add a user to a set of groups' do
      resource[:membership] = :minimum
      provider.user.expects(:set_groups).with('group1,group2', true)

      provider.groups = 'group1,group2'

      resource[:membership] = :inclusive
      provider.user.expects(:set_groups).with('group1,group2', false)

      provider.groups = 'group1,group2'
    end
  end

  describe "#groups_insync?" do

    let(:group1) { stub(:account => 'group1', :domain => '.', :sid => 'group1sid') }
    let(:group2) { stub(:account => 'group2', :domain => '.', :sid => 'group2sid') }
    let(:group3) { stub(:account => 'group3', :domain => '.', :sid => 'group3sid') }

    before :each do
      Puppet::Util::Windows::SID.stubs(:name_to_principal).with('group1').returns(group1)
      Puppet::Util::Windows::SID.stubs(:name_to_principal).with('group2').returns(group2)
      Puppet::Util::Windows::SID.stubs(:name_to_principal).with('group3').returns(group3)
    end

    it "should return true for same lists of members" do
      expect(provider.groups_insync?(['group1', 'group2'], ['group1', 'group2'])).to be_truthy
    end

    it "should return true for same lists of unordered members" do
      expect(provider.groups_insync?(['group1', 'group2'], ['group2', 'group1'])).to be_truthy
    end

    it "should return true for same lists of members irrespective of duplicates" do
      expect(provider.groups_insync?(['group1', 'group2', 'group2'], ['group2', 'group1', 'group1'])).to be_truthy
    end

    it "should return true when current group(s) and should group(s) are empty lists" do
      expect(provider.groups_insync?([], [])).to be_truthy
    end

    it "should return true when current groups is empty and should groups is nil" do
      expect(provider.groups_insync?([], nil)).to be_truthy
    end

    context "when membership => inclusive" do
      before :each do
        resource[:membership] = :inclusive
      end

      it "should return true when current and should contain the same groups in a different order" do
        expect(provider.groups_insync?(['group1', 'group2', 'group3'], ['group3', 'group1', 'group2'])).to be_truthy
      end

      it "should return false when current contains different groups than should" do
        expect(provider.groups_insync?(['group1'], ['group2'])).to be_falsey
      end

      it "should return false when current is nil" do
        expect(provider.groups_insync?(nil, ['group2'])).to be_falsey
      end

      it "should return false when should is nil" do
        expect(provider.groups_insync?(['group1'], nil)).to be_falsey
      end

      it "should return false when current contains members and should is empty" do
        expect(provider.groups_insync?(['group1'], [])).to be_falsey
      end

      it "should return false when current is empty and should contains members" do
        expect(provider.groups_insync?([], ['group2'])).to be_falsey
      end

      it "should return false when should groups(s) are not the only items in the current" do
        expect(provider.groups_insync?(['group1', 'group2'], ['group1'])).to be_falsey
      end

      it "should return false when current group(s) is not empty and should is an empty list" do
        expect(provider.groups_insync?(['group1','group2'], [])).to be_falsey
      end
    end

    context "when membership => minimum" do
      before :each do
        # this is also the default
        resource[:membership] = :minimum
      end

      it "should return false when current contains different groups than should" do
        expect(provider.groups_insync?(['group1'], ['group2'])).to be_falsey
      end

      it "should return false when current is nil" do
        expect(provider.groups_insync?(nil, ['group2'])).to be_falsey
      end

      it "should return true when should is nil" do
        expect(provider.groups_insync?(['group1'], nil)).to be_truthy
      end

      it "should return true when current contains members and should is empty" do
        expect(provider.groups_insync?(['group1'], [])).to be_truthy
      end

      it "should return false when current is empty and should contains members" do
        expect(provider.groups_insync?([], ['group2'])).to be_falsey
      end

      it "should return true when current group(s) contains at least the should list" do
        expect(provider.groups_insync?(['group1','group2'], ['group1'])).to be_truthy
      end

      it "should return true when current group(s) is not empty and should is an empty list" do
        expect(provider.groups_insync?(['group1','group2'], [])).to be_truthy
      end

      it "should return true when current group(s) contains at least the should list, even unordered" do
        expect(provider.groups_insync?(['group3','group1','group2'], ['group2','group1'])).to be_truthy
      end
    end
  end

  describe "when creating a user" do
    it "should create the user on the system and set its other properties" do
      resource[:groups]     = ['group1', 'group2']
      resource[:membership] = :inclusive
      resource[:comment]    = 'a test user'
      resource[:home]       = 'C:\Users\testuser'

      stub_attributes({ account_disabled: 'true' })
      # this should be invoked later in create
      provider.expects(:attributes=).with(resource[:attributes])

      user = stub 'user'
      Puppet::Util::Windows::ADSI::User.expects(:create).with('testuser').returns user

      user.stubs(:groups).returns(['group2', 'group3'])

      create = sequence('create')
      user.expects(:password=).in_sequence(create)
      user.expects(:set_userflags).with(:ADS_UF_DONT_EXPIRE_PASSWD)
      user.expects(:set_groups).with('group1,group2', false).in_sequence(create)
      user.expects(:[]=).with('Description', 'a test user')
      user.expects(:[]=).with('HomeDirectory', 'C:\Users\testuser')

      provider.create
    end

    it "should load the profile if managehome is set" do
      resource[:password] = '0xDeadBeef'
      resource[:managehome] = true

      provider.stubs(:password=)

      user = stub_everything 'user'
      Puppet::Util::Windows::ADSI::User.expects(:create).with('testuser').returns user
      Puppet::Util::Windows::User.expects(:load_profile).with('testuser', '0xDeadBeef')

      provider.create
    end

    it "should test a valid user password" do
      resource[:password] = 'plaintext'
      provider.user.expects(:password_is?).with('plaintext').returns true

      expect(provider.password).to eq('plaintext')

    end

    it "should test a bad user password" do
      resource[:password] = 'plaintext'
      provider.user.expects(:password_is?).with('plaintext').returns false

      expect(provider.password).to be_nil
    end

    it "should test a blank user password" do
      resource[:password] = ''
      provider.user.expects(:password_is?).with('').returns true

      expect(provider.password).to eq('')
    end

    it 'should not create a user if a group by the same name exists' do
      Puppet::Util::Windows::ADSI::User.expects(:create).with('testuser').raises( Puppet::Error.new("Cannot create user if group 'testuser' exists.") )
      expect{ provider.create }.to raise_error( Puppet::Error,
        /Cannot create user if group 'testuser' exists./ )
    end

    it "should fail with an actionable message when trying to create an active directory user" do
      resource[:name] = 'DOMAIN\testdomainuser'

      Puppet::Util::Windows::ADSI::Group.expects(:exists?).with(resource[:name]).returns(false)
      connection.expects(:Create)
      connection.stubs(:Get)
      connection.stubs(:Get).with('UserFlags').returns(0)
      connection.stubs(:Put)
      connection.expects(:SetInfo).raises( WIN32OLERuntimeError.new("(in OLE method `SetInfo': )\n    OLE error code:8007089A in Active Directory\n      The specified username is invalid.\r\n\n    HRESULT error code:0x80020009\n      Exception occurred."))

      expect{ provider.create }.to raise_error(
        Puppet::Error,
        /not able to create\/delete domain users/
      )
    end
  end

  it 'should be able to test whether a user exists' do
    Puppet::Util::Windows::SID.stubs(:name_to_principal).returns(nil)
    Puppet::Util::Windows::ADSI.stubs(:connect).returns stub('connection', :Class => 'User')
    expect(provider).to be_exists

    Puppet::Util::Windows::ADSI.stubs(:connect).returns nil
    expect(provider).not_to be_exists
  end

  it 'should be able to delete a user' do
    connection.expects(:Delete).with('user', 'testuser')

    provider.delete
  end

  it 'should not run commit on a deleted user' do
    connection.expects(:Delete).with('user', 'testuser')
    connection.expects(:SetInfo).never

    provider.delete
    provider.flush
  end

  it 'should delete the profile if managehome is set' do
    resource[:managehome] = true

    sid = 'S-A-B-C'
    Puppet::Util::Windows::SID.expects(:name_to_sid).with('testuser').returns(sid)
    Puppet::Util::Windows::ADSI::UserProfile.expects(:delete).with(sid)
    connection.expects(:Delete).with('user', 'testuser')

    provider.delete
  end

  it "should commit the user when flushed" do
    provider.user.expects(:commit)

    provider.flush
  end

  it "should return the user's SID as uid" do
    Puppet::Util::Windows::SID.expects(:name_to_sid).with('testuser').returns('S-1-5-21-1362942247-2130103807-3279964888-1111')

    expect(provider.uid).to eq('S-1-5-21-1362942247-2130103807-3279964888-1111')
  end

  it "should fail when trying to manage the uid property" do
    provider.expects(:fail).with { |msg| msg =~ /uid is read-only/ }
    provider.send(:uid=, 500)
  end

  [:gid, :shell].each do |prop|
    it "should fail when trying to manage the #{prop} property" do
      provider.expects(:fail).with { |msg| msg =~ /No support for managing property #{prop}/ }
      provider.send("#{prop}=", 'foo')
    end
  end
end
