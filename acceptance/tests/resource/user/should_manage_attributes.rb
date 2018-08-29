test_name "should correctly manage the attributes property for the User resource (AIX and Windows only)" do
  confine :to, :platform => /aix|windows/
  
  tag 'audit:medium',
      'audit:acceptance' # Could be done as integration tests, but would
                         # require changing the system running the test
                         # in ways that might require special permissions
                         # or be harmful to the system running the test
  
  require 'puppet/acceptance/common_tests.rb'
  extend Puppet::Acceptance::CommonTests::AttributesProperty

  agents.each do |agent|
    case agent['platform']
    when /aix/
      require 'puppet/acceptance/aix_util'
      extend Puppet::Acceptance::AixUtil

      initial_attributes = {
        'nofiles'       => 10000,
        'fsize'         => 100000,
        'data'          => 60000,
      }
      changed_attributes = {
        'nofiles' => -1,
        'data' => 40000
      }
    
      run_aix_attribute_property_tests_on(
        agent,
        'user',
        :uid,
        initial_attributes,
        changed_attributes
      )
    when /windows/
      def current_attributes_on(host, user)
        # This script will output each attribute on a separate line. Sample output includes
        # something like:
        #   full_name=<full_name>
        #   account_disabled=<account_disabled>
        #   password_change_not_allowed=<password_change_not_allowed>
        retrieve_user_attributes = <<-PS1
function Is-UserFlagSet($user, $flag) {
  # Only declare the flags we need. More can be added as we add
  # more attributes to the Windows user.
  $ADS_USERFLAGS = @{
    'ADS_UF_ACCOUNTDISABLE'     = 0x0002;
    'ADS_UF_PASSWD_CANT_CHANGE' = 0x0040;
  }

  $flag_set = ($user.get('UserFlags') -band $ADS_USERFLAGS[$flag]) -ne 0

  # 'true' and 'false' are 'True' and 'False' in Powershell, respectively,
  # so we need to convert them from their Powershell representation to their
  # Ruby one.
  ([string] $flag_set).ToLower()
}

# This lets us fail the test if an error occurs while running
# the script.
$ErrorActionPreference = 'Stop'

$user = [ADSI]"WinNT://./#{user},user"
$attributes = @{
  'full_name'                   = $user.FullName;
  'account_disabled'            = Is-UserFlagSet $user 'ADS_UF_ACCOUNTDISABLE'
  'password_change_not_allowed' = Is-UserFlagSet $user 'ADS_UF_PASSWD_CANT_CHANGE'
}

foreach ($attribute in $attributes.keys) {
  Write-Output "${attribute}=$($attributes[$attribute])"
}
  PS1
        
        stdout = execute_powershell_script_on(host, retrieve_user_attributes).stdout.chomp
  
        current_attributes = {}
        stdout.split("\n").each do |attribute|
          name, value = attribute.split('=')
          current_attributes[name] = value
        end
  
        current_attributes
      end

      username="pl#{rand(999999).to_i}"
      agent.user_absent(username)
      teardown { agent.user_absent(username) }

      initial_attributes = {
        'full_name'                   => 'Some Full Name',
        'account_disabled'            => 'true',
        'password_change_not_allowed' => 'true'
      }

      changed_attributes = {
        'full_name'                   => 'Another Full Name',
        'account_disabled'            => 'false',
      }

      run_common_attributes_property_tests_on(
        agent,
        'user',
        username,
        method(:current_attributes_on),
        initial_attributes,
        changed_attributes
      )

      # Good to ensure that our user's still present in case the
      # common attributes test decides to delete the created user
      # in the future.
      agent.user_present(username)

      step "Verify that Puppet errors when we specify an unmanaged attribute" do
        attributes = initial_attributes.merge('unmanaged_attribute' => 'value')
        manifest = resource_manifest('user', username, attributes: attributes)

        apply_manifest_on(agent, manifest) do |result|
          assert_match(/unmanaged_attribute.*full_name/, result.stderr, 'Puppet does not error if the user specifies an unmanaged Windows attribute')
        end
      end

      step "Verify that Puppet errors when we specify an invalid attribute value" do
        attributes = initial_attributes.merge('account_disabled' => 'string_value')
        manifest = resource_manifest('user', username, attributes: attributes)

        apply_manifest_on(agent, manifest) do |result|
          assert_match(/account_disabled.*Boolean/, result.stderr, 'Puppet does not error if the user specifies an invalid Windows attribute value')
        end
      end
    end
  end
end
