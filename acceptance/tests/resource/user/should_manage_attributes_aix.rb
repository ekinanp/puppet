test_name "should correctly manage the attributes property (AIX only)" do
  confine :to, :platform => /aix/
  
  tag 'audit:medium',
      'audit:refactor',  # Use block style `test_run`
      'audit:acceptance' # Could be done as integration tests, but would
                         # require changing the system running the test
                         # in ways that might require special permissions
                         # or be harmful to the system running the test
  
  require 'puppet/acceptance/aix_util'
  extend Puppet::Acceptance::AixUtil

  def assert_lsuser_attributes_on(agent, name, expected_attributes)
    assert_object_attributes_on(agent, :user_get, name, expected_attributes)
  end

  def assert_puppet_changed_user_attributes(result, name, changed_attributes)
    assert_puppet_changed_object_attributes(result, 'User', name, changed_attributes)
  end

  def user_manifest(name, params)
    object_resource_manifest('user', name, params)
  end

  name = "johnny"
  teardown do
    agents.each { |agent| agent.user_absent(name) }
  end
 
  # TODO: Add an acceptance test that ensures we error if we pass in an attribute corresponding
  # to another Puppet property. This should be done after the refactor work.
  agents.each do |agent|
    # These are the default set of attributes for our user
    attributes = {
      'nofiles'       => 10000,
      'fsize'         => 100000,
      'data'          => '60000',
    }
  
    step "Ensure that the user can be created with the specified attributes" do
      manifest = user_manifest(name, ensure: :present, attributes: to_kv_array(attributes))
      apply_manifest_on(agent, manifest)
      assert_lsuser_attributes_on(agent, name, attributes)
    end

    step "Ensure that Puppet noops when the specified attributes are already set" do
      manifest = user_manifest(name, attributes: to_kv_array(attributes))
      apply_manifest_on(agent, manifest, catch_changes: true)
    end

    step "Ensure that Puppet updates only the specified attributes and nothing else" do
      changed_attributes = {}
      changed_attributes['nofiles'] = -1 
      changed_attributes['data'] = 40000
      attributes = attributes.merge(changed_attributes)

      manifest = user_manifest(name, attributes: to_kv_array(attributes))

      apply_manifest_on(agent, manifest) do |result|
        assert_puppet_changed_user_attributes(result, name, changed_attributes)
      end
      assert_lsuser_attributes_on(agent, name, attributes)
    end

    step "Ensure that Puppet accepts a hash for the attributes property" do
      attributes['nofiles'] = 10000
      manifest = user_manifest(name, attributes: attributes)
      apply_manifest_on(agent, manifest)
      assert_lsuser_attributes_on(agent, name, attributes)
    end

    step "Ensure that `puppet resource user` outputs valid Puppet code" do
      on(agent, puppet("resource user #{name}")) do |result|
        manifest = result.stdout.chomp
        apply_manifest_on(agent, manifest)
      end
    end
  end
end
