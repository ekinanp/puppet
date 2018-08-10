require 'spec_helper'

describe 'Puppet::Type::User::Provider::Aix' do
  let(:provider_class) { Puppet::Type.type(:user).provider(:aix) }
  let(:group_provider_class) { Puppet::Type.type(:group).provider(:aix) }

  let(:resource) do
    Puppet::Type.type(:user).new(
      :name   => 'test_aix_user',
      :ensure => :present
    )
  end
  let(:provider) do
    provider_class.new(resource)
  end

  describe '.pgrp_to_gid' do
    let!(:groups) do
      objects = {
        'group1' => 1,
        'group2' => 2
      }

      group_provider_class.stubs(:list_all).returns(objects)

      objects
    end

    it 'raises an ArgumentError if the specified pgrp does not exist' do
      expect { provider_class.pgrp_to_gid('foo') }.to raise_error do |error|
        expect(error).to be_a(ArgumentError)

        expect(error.message).to match("FATAL")
      end
    end

    it 'returns the gid of the pgrp' do
      expect(provider_class.pgrp_to_gid('group1')).to eql(1)
    end
  end

  describe 'gid_to_pgrp' do
    let!(:groups) do
      objects = {
        'group1' => 1,
        'group2' => 2
      }

      group_provider_class.stubs(:list_all).returns(objects)

      objects
    end

    it 'raises an ArgumentError if the specified gid does not exist' do
      expect { provider_class.gid_to_pgrp(3) }.to raise_error do |error|
        expect(error).to be_a(ArgumentError)

        expect(error.message).to match("3")
      end
    end

    it 'returns the pgrp of the gid when the gid is a String' do
      expect(provider_class.gid_to_pgrp('group1')).to eql('group1')
    end

    it 'returns the pgrp of the gid when the gid is an Integer' do
      expect(provider_class.gid_to_pgrp(1)).to eql('group1')
    end
  end

  describe '.expires_to_expiry' do
    it 'returns absent if expires is 0' do
      expect(provider_class.expires_to_expiry('0')).to eql(:absent)
    end

    # TODO (PUP-9049): Remove this test if it is unnecessary
    it 'returns absent if the expiry attribute is not formatted properly' do
      expect(provider_class.expires_to_expiry('bad_format')).to eql(:absent)
    end

    it 'returns the password expiration date' do
      expect(provider_class.expires_to_expiry('0910122314')).to eql('2014-09-10')
    end
  end

  describe '.expiry_to_expires' do
    it 'returns 0 if the expiry date is 0000-00-00' do
      expect(provider_class.expiry_to_expires('0000-00-00')).to eql('0')
    end

    it 'returns 0 if the expiry date is "absent"' do
      expect(provider_class.expiry_to_expires('absent')).to eql('0')
    end

    it 'returns 0 if the expiry date is :absent' do
      expect(provider_class.expiry_to_expires(:absent)).to eql('0')
    end

    it 'returns the expires attribute value' do
      expect(provider_class.expiry_to_expires('2014-09-10')).to eql('0910000014')
    end
  end

  describe '.groups_to_groups' do
    it 'raises an ArgumentError if the groups are space-separated' do
      groups = "foo bar baz"
      expect { provider_class.groups_to_groups(groups) }.to raise_error do |error|
        expect(error).to be_a(ArgumentError)

        expect(error.message).to match(groups)
        expect(error.message).to match("Groups")
      end
    end
  end

  describe '#password' do
    before(:each) do
      @filesystem_open = Puppet::FileSystem.method(:open)

      # Not the preferred way to mock out Puppet::FileSystem.open, but Mocha
      # unfortunately does not let you compute dynamic return values. It's not
      # bad enough to justify an acceptance test, however. Note that we are explicit
      # with our arguments because the #password function explicitly calls
      # Puppet::FileSystem.open with three arguments.
      module Puppet::FileSystem
        def self.open(path, arg2, arg3, &block)
          unless path == "/etc/security/passwd"
            raise "Puppet::FileSystem.open is only mocked for /etc/security/passwd!"
          end
          path = my_fixture('aix_passwd_file.out')
          File.open(path) { |f| block.call(f) }
        end
      end
    end

    # Reset Puppet::FileSystem to what it was before these tests.
    after(:each) do
      module Puppet::FileSystem
        def self.open(arg1, arg2, arg3, &block)
          @filesystem_open.call(arg1, arg2, arg3, &block)
        end
      end
    end

    it "returns :absent if the user stanza doesn't exist" do
      resource[:name] = 'nonexistent_user'
      expect(provider.password).to eql(:absent)
    end

    it "returns absent if the user does not have a password" do
      resource[:name] = 'no_password_user'
      expect(provider.password).to eql(:absent)
    end

    it "returns the user's password" do
      expect(provider.password).to eql('some_password')
    end
  end

  describe '#password=' do
    let(:mock_tempfile) do
      mock_tempfile_obj = mock()
      mock_tempfile_obj.stubs(:<<)
      mock_tempfile_obj.stubs(:close)
      mock_tempfile_obj.stubs(:delete)
      mock_tempfile_obj.stubs(:path).returns('tempfile_path')

      Tempfile.stubs(:new)
        .with("puppet_#{provider.name}_pw", :encoding => Encoding::ASCII)
        .returns(mock_tempfile_obj)

      mock_tempfile_obj
    end
    let(:cmd) do
      [provider.class.command(:chpasswd), *provider.ia_module_args, '-e', '-c']
    end
    let(:execute_options) do
      {
        :failonfail => false,
        :combine => true,
        :stdinfile => mock_tempfile.path
      }
    end

    it 'raises a Puppet::Error if chpasswd fails' do
      provider.stubs(:execute).with(cmd, execute_options).returns("failed to change passwd!")
      expect { provider.password = 'foo' }.to raise_error do |error|
        expect(error).to be_a(Puppet::Error)
        expect(error.message).to match("failed to change passwd!")
      end
    end

    it "changes the user's password" do
      provider.expects(:execute).with(cmd, execute_options).returns("")
      provider.password = 'foo'
    end

    it "closes and deletes the tempfile" do
      provider.stubs(:execute).with(cmd, execute_options).returns("")

      mock_tempfile.expects(:close).times(2)
      mock_tempfile.expects(:delete)

      provider.password = 'foo'
    end
  end

  describe '#create' do
    it 'should create the user' do
      provider.resource.stubs(:should).with(anything).returns(nil)
      provider.resource.stubs(:should).with(:password).returns('password')

      provider.expects(:execute)
      provider.expects(:password=).with('password')

      provider.create
    end
  end
end
