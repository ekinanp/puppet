# Group Puppet provider for AIX. It uses standard commands to manage groups:
#  mkgroup, rmgroup, lsgroup, chgroup
require 'puppet/provider/aix_object'

Puppet::Type.type(:group).provide :aix, :parent => Puppet::Provider::AixObject do
  desc "Group management for AIX."

  # This will the default provider for this platform
  defaultfor :operatingsystem => :aix
  confine :operatingsystem => :aix

  # Commands that manage the element
  commands :list      => "/usr/sbin/lsgroup"
  commands :add       => "/usr/bin/mkgroup"
  commands :delete    => "/usr/sbin/rmgroup"
  commands :modify    => "/usr/bin/chgroup"

  # Provider features
  has_features :manages_aix_lam
  has_features :manages_members

  class << self
    # Define some Puppet Property => AIX Attribute (and vice versa)
    # conversion functions here. This is so we can unit test them.

    def members_to_users(value)
      return value unless value.is_a?(Array)
      value.join(',')
    end

    def users_to_members(value)
      value.split(',')
    end
  end

  numeric_mapping puppet_property: :gid,
                  aix_attribute: :id

  mapping puppet_property: :members,
          aix_attribute: :users,
          property_to_attribute: method(:members_to_users),
          attribute_to_property: method(:users_to_members)

  # Now that we have all of our mappings, let's go ahead and make
  # the resource methods (property getters + setters for our mapped
  # properties + a getter for the attributes property).
  mk_resource_methods
end
