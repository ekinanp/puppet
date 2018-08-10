test_name "should correctly manage the attributes property for the Group (AIX only)" do
  confine :to, :platform => /aix/
  
  tag 'audit:medium',
      'audit:refactor',  # Use block style `test_run`
      'audit:acceptance' # Could be done as integration tests, but would
                         # require changing the system running the test
                         # in ways that might require special permissions
                         # or be harmful to the system running the test
  
  require 'puppet/acceptance/aix_util'
  extend Puppet::Acceptance::AixUtil

  # These are the default set of attributes for our group
  attributes = {
    'admin' => true
  }
  changed_attributes = {
    'admin' => false
  }

  run_attribute_management_tests('group', :gid, attributes, changed_attributes)

end
