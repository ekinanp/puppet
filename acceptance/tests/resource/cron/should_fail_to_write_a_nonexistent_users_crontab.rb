test_name "The crontab provider should fail to write a nonexistent user's crontab" do
  confine :except, :platform => 'windows'
  confine :except, :platform => /^eos-/ # See PUP-5500
  confine :except, :platform => /^fedora-28/
  tag 'audit:medium',
      'audit:unit'
  
  require 'puppet/acceptance/common_utils'
  extend Puppet::Acceptance::BeakerUtils
  extend Puppet::Acceptance::CronUtils
  extend Puppet::Acceptance::ManifestUtils

  agents.each do |agent|
    username = "pl#{rand(999999).to_i}"
    nonexistent_username = "pl#{rand(999999).to_i}"

    teardown do
      run_cron_on(agent, :remove, username)
      user_absent(agent, username)

      user_absent(agent, nonexistent_username)
    end

    step "Ensure that the existent user exists" do
      user_present(agent, username)
    end

    step "Ensure that the nonexistent user does not exist" do
      user_absent(agent, nonexistent_username)
    end

    puppet_result = nil
    step "Create the existent + nonexistent user's crontab entries with Puppet" do
      manifest = [
        cron_manifest('first_entry', command: "ls", user: username),
        cron_manifest('second_entry', command: "ls", user: nonexistent_username),
      ].join("\n\n")

      puppet_result = apply_manifest_on(agent, manifest)
    end

    step "Verify that Puppet fails to evaluate a Cron resource associated with a nonexistent user" do
      assert_match(/Cron.*second_entry/, puppet_result.stderr, "Puppet successfully evaluates a Cron resource associated with a nonexistent user")
    end
  end
end
