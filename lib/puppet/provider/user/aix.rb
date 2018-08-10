# User Puppet provider for AIX. It uses standard commands to manage users:
#  mkuser, rmuser, lsuser, chuser
#
# Notes:
# - AIX users can have expiry date defined with minute granularity,
#   but Puppet does not allow it. There is a ticket open for that (#5431)
#
# - AIX maximum password age is in WEEKs, not days
#
# See https://puppet.com/docs/puppet/latest/provider_development.html
# for more information
require 'puppet/provider/aix_object'
require 'tempfile'
require 'date'

Puppet::Type.type(:user).provide :aix, :parent => Puppet::Provider::AixObject do
  desc "User management for AIX."

  defaultfor :operatingsystem => :aix
  confine :operatingsystem => :aix

  # Commands that manage the element
  commands :list      => "/usr/sbin/lsuser"
  commands :add       => "/usr/bin/mkuser"
  commands :delete    => "/usr/sbin/rmuser"
  commands :modify    => "/usr/bin/chuser"

  commands :chpasswd  => "/bin/chpasswd"

  # Provider features
  has_features :manages_aix_lam
  has_features :manages_homedir, :manages_passwords, :manages_shell
  has_features :manages_expiry,  :manages_password_age

  class << self
    def load_group_provider
      @group_provider ||= Puppet::Type.type(:group).provider(:aix)
    end

    # Define some Puppet Property => AIX Attribute (and vice versa)
    # conversion functions here.

    def pgrp_to_gid(value)
      load_group_provider

      _, gid = @group_provider.list_all.find { |group, gid| group == value }
      unless gid
        raise ArgumentError, _("FATAL: No gid exists for the primary AIX group #{value}!")
      end

      gid
    end
  
    def gid_to_pgrp(value)
      load_group_provider

      groups = @group_provider.list_all
      if value.is_a?(String) 
        pgrp, _ = groups.find { |group, gid| group == value }
      else
        pgrp, _ = groups.find { |group, gid| gid == value }
      end

      unless pgrp
        raise ArgumentError, _("No AIX pgrp exists with a gid of #{value}!")
      end

      pgrp
    end

    def expires_to_expiry(value)
      return :absent if value == '0'

      # TODO (PUP-9049): Do we need this check? AIX already does validation when you try
      # to set this value. Could be useful in case future AIX platforms change the
      # format. Note expires attribute is formatted as mmddHHMMYY per
      # https://docs.oracle.com/cd/E19944-01/819-4520/AIX.html
      unless (match_obj = /\A(\d\d)(\d\d)(\d\d)(\d\d)(\d\d)\z/.match(value))
        #TRANSLATORS 'AIX' is the name of an operating system and should not be translated
        Puppet.warning(_("Could not convert AIX expires date '%{value}' on %{class_name}[%{resource_name}]") % { value: value, class_name: @resource.class.name, resource_name: @resource.name })
        return :absent
      end

      month, day, year = match_obj[1], match_obj[2], match_obj[-1]
      return "20#{year}-#{month}-#{day}"
    end

    def expiry_to_expires(value)
      return '0' if value == "0000-00-00" || value.to_sym == :absent
      
      DateTime.parse(value, "%Y-%m-%d %H:%M")
        .strftime("%m%d%H%M%y")
    end

    # We do some validation before-hand to ensure the value's an Array,
    # a String, etc. in the property. This routine does a final check to
    # ensure our value doesn't have whitespace before we convert it to
    # an attribute.
    def groups_to_groups(value)
      if value =~ /\s/
        raise ArgumentError, _("Invalid value #{value}: Groups must be comma separated!")
      end

      value
    end
  end

  mapping puppet_property: :gid,
          aix_attribute: :pgrp,
          property_to_attribute: method(:gid_to_pgrp),
          attribute_to_property: method(:pgrp_to_gid)

  numeric_mapping puppet_property: :uid,
                  aix_attribute: :id

  mapping puppet_property: :groups, 
          property_to_attribute: method(:groups_to_groups)

  mapping puppet_property: :home
  mapping puppet_property: :shell

  mapping puppet_property: :expiry,
          aix_attribute: :expires,
          property_to_attribute: method(:expiry_to_expires),
          attribute_to_property: method(:expires_to_expiry)

  numeric_mapping puppet_property: :password_max_age,
                  aix_attribute: :maxage

  numeric_mapping puppet_property: :password_min_age,
                  aix_attribute: :minage

  numeric_mapping puppet_property: :password_warn_days,
                  aix_attribute: :pwdwarntime

  mapping puppet_property: :comment,
          aix_attribute: :gecos

  # Now that we have all of our mappings, let's go ahead and make
  # the resource methods (property getters + setters for our mapped
  # properties + a getter for the attributes property).
  mk_resource_methods

  # Helper function that parses the password from the given
  # password filehandle. This is here to make testing easier
  # since we cannot configure Mocha to mock out a method and
  # have it return a block's value, meaning we cannot test
  # #password directly (not in a simple and obvious way, at least).
  # @api private
  def parse_password(f)
    # From the docs, a user stanza is formatted as (newlines are explicitly stated for clarity):
    #   <user>:\n
    #     <attribute1>=<value1>\n
    #     <attribute2>=<value2>\n
    #   \n
    #
    # The fact that each stanza ends with an additional newline significantly
    # simplifies the code here because we can split at that additional newline,
    # effectively parsing each stanza.
    stanza = f.read.split(/^$\n/).find { |stanza| stanza =~ /\A#{@resource[:name]}:/ }
    return :absent unless stanza

    # Now find the password, if it exists
    match_obj = /password\s*=\s*(\S*)$/.match(stanza)
    return :absent unless match_obj

    match_obj[1]
  end

  #- **password**
  #    The user's password, in whatever encrypted format the local machine
  #    requires. Be sure to enclose any value that includes a dollar sign ($)
  #    in single quotes (').  Requires features manages_passwords.
  #
  # Retrieve the password parsing the /etc/security/passwd file.
  def password
    # AIX reference indicates this file is ASCII
    # https://www.ibm.com/support/knowledgecenter/en/ssw_aix_72/com.ibm.aix.files/passwd_security.htm
    Puppet::FileSystem.open("/etc/security/passwd", nil, "r:ASCII") do |f|
      parse_password(f)
    end
  end

  def password=(value)
    user = @resource[:name]

    begin
      # Puppet execute does not support strings as input, only files.
      # The password is expected to be in an encrypted format given -e is specified:
      # https://www.ibm.com/support/knowledgecenter/ssw_aix_71/com.ibm.aix.cmds1/chpasswd.htm
      # /etc/security/passwd is specified as an ASCII file per the AIX documentation
      tempfile = nil
      tempfile = Tempfile.new("puppet_#{user}_pw", :encoding => Encoding::ASCII)
      tempfile << "#{user}:#{value}\n"
      tempfile.close()
  
      # Options '-e', '-c', use encrypted password and clear flags
      # Must receive "user:enc_password" as input
      # command, arguments = {:failonfail => true, :combine => true}
      # Fix for bugs #11200 and #10915
      cmd = [self.class.command(:chpasswd), *ia_module_args, '-e', '-c']
      execute_options = {
        :failonfail => false,
        :combine => true,
        :stdinfile => tempfile.path
      }
      output = execute(cmd, execute_options)

      # chpasswd can return 1, even on success (at least on AIX 6.1); empty output
      # indicates success
      if output != ""
        raise Puppet::ExecutionFailure, "chpasswd said #{output}"
      end
    rescue Puppet::ExecutionFailure  => detail
      raise Puppet::Error, "Could not set password on #{@resource.class.name}[#{@resource.name}]: #{detail}", detail.backtrace
    ensure
      if tempfile
        # Extra close will noop. This is in case the write to our tempfile
        # fails.
        tempfile.close()
        tempfile.delete()
      end
    end
  end

  def create
    super

    if (password = @resource.should(:password))
      self.password = password
    end
  end

  # UNSUPPORTED
  #- **profile_membership**
  #    Whether specified roles should be treated as the only roles
  #    of which the user is a member or whether they should merely
  #    be treated as the minimum membership list.  Valid values are
  #    `inclusive`, `minimum`.
  # UNSUPPORTED
  #- **profiles**
  #    The profiles the user has.  Multiple profiles should be
  #    specified as an array.  Requires features manages_solaris_rbac.
  # UNSUPPORTED
  #- **project**
  #    The name of the project associated with a user  Requires features
  #    manages_solaris_rbac.
  # UNSUPPORTED
  #- **role_membership**
  #    Whether specified roles should be treated as the only roles
  #    of which the user is a member or whether they should merely
  #    be treated as the minimum membership list.  Valid values are
  #    `inclusive`, `minimum`.
  # UNSUPPORTED
  #- **roles**
  #    The roles the user has.  Multiple roles should be
  #    specified as an array.  Requires features manages_solaris_rbac.
  # UNSUPPORTED
  #- **key_membership**
  #    Whether specified key value pairs should be treated as the only
  #    attributes
  #    of the user or whether they should merely
  #    be treated as the minimum list.  Valid values are `inclusive`,
  #    `minimum`.
  # UNSUPPORTED
  #- **keys**
  #    Specify user attributes in an array of keyvalue pairs  Requires features
  #    manages_solaris_rbac.
  # UNSUPPORTED
  #- **allowdupe**
  #  Whether to allow duplicate UIDs.  Valid values are `true`, `false`.
  # UNSUPPORTED
  #- **auths**
  #    The auths the user has.  Multiple auths should be
  #    specified as an array.  Requires features manages_solaris_rbac.
  # UNSUPPORTED
  #- **auth_membership**
  #    Whether specified auths should be treated as the only auths
  #    of which the user is a member or whether they should merely
  #    be treated as the minimum membership list.  Valid values are
  #    `inclusive`, `minimum`.
  # UNSUPPORTED

end
