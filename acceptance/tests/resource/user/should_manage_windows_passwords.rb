test_name "should correctly manage the password property on Windows" do
  confine :to, :platform => /windows/
  
  tag 'audit:medium',
      'audit:acceptance' # Could be done as integration tests, but would
                         # require changing the system running the test
                         # in ways that might require special permissions
                         # or be harmful to the system running the test

  require 'puppet/acceptance/windows_utils.rb'
  extend Puppet::Acceptance::WindowsUtils

  # TODO: Extract this manifest generation function into a common
  # utility function to make things easier.

  def resource_manifest(resource, name, params)
    params_str = params.map do |param, value|
      value_str = value.to_s
      value_str = "\"#{value_str}\"" if value.is_a?(String)
      
      "  #{param} => #{value_str}"
    end.join(",\n")
      
    <<-MANIFEST
#{resource} { '#{name}':
  #{params_str}
}
MANIFEST
  end

  agents.each do |agent|
    username="pl#{rand(999999).to_i}"
    agent.user_absent(username)
    teardown { agent.user_absent(username) }

    current_password = 'my_password'

    step "Ensure that the user can be created with the specified password" do
      manifest = resource_manifest('user', username, ensure: :present, password: current_password)

      apply_manifest_on(agent, manifest)
      assert(user_password_is?(agent, username, current_password), "Puppet fails to set the user's password when creating the user!")
    end

    step "Verify that the user's password is set to never expire" do
      attributes = current_attributes_on(agent, username)
      assert_equal(attributes['password_never_expires'], 'true', "Puppet fails to set the user's password to never expire")
    end

    step "Ensure that Puppet noops when the password is already set" do
      manifest = resource_manifest('user', username, password: current_password)

      apply_manifest_on(agent, manifest, catch_changes: true)
    end

    current_password = 'new_password'

    step "Ensure that Puppet can change the user's password" do
      manifest = resource_manifest('user', username, password: current_password)

      apply_manifest_on(agent, manifest)
      assert(user_password_is?(agent, username, current_password), "Puppet fails to change the user's password!")
    end

    step "Verify that the user's password is still set to never expire" do
      attributes = current_attributes_on(agent, username)
      assert_equal(attributes['password_never_expires'], 'true', "Puppet fails to set the user's password to never expire")
    end

    step "password_change_required attribute" do
      step "Set the attribute to true" do
        manifest = resource_manifest(
          'user',
          username,
          attributes: { 'password_change_required' => true, 'password_never_expires' => false }
        )

        apply_manifest_on(agent, manifest)
  
        attributes = current_attributes_on(agent, username)
        assert_equal(attributes['password_change_required'], 'true', "Puppet failed to set the password_change_required attribute to true")
      end

      step "Verify that Puppet prints a warning message when trying to change the password" do
        manifest = resource_manifest('user', username, password: "#{current_password}_should_not_be_set")

        apply_manifest_on(agent, manifest) do |result|
          assert_match(/#{username}.*to.*change.*password/, result.stderr.chomp, "Puppet fails to print a warning message when attempting to change the password")
        end
      end

      step "Set the attribute back to false (necessary for validating the credentials)" do
        manifest = resource_manifest(
          'user',
          username,
          attributes: { 'password_change_required' => false }
        )

        apply_manifest_on(agent, manifest)
  
        attributes = current_attributes_on(agent, username)
        assert_equal(attributes['password_change_required'], 'false', "Puppet failed to set the password_change_required attribute back to false")
      end

      step "Verify that Puppet did not change the password" do
        assert(user_password_is?(agent, username, current_password), "Puppet changed the user's password even when password_change_required was set to true")
      end
    end
  end
end
