require 'puppet/util/windows'

Puppet::Type.type(:user).provide :windows_adsi do
  desc "Local user management for Windows."

  defaultfor :operatingsystem => :windows
  confine    :operatingsystem => :windows

  has_features :manages_homedir,
               :manages_passwords,
               :manages_attributes

  class << self
    # Unlike our AIX attributes, our Windows attributes have a
    # fixed schema. Because the :attributes property munges values
    # to their string representation, we need to unmunge them here
    # when setting these values. Thus, this schema is a hash of
    #     <attribute> => <unmunge function>
    #
    # See #validate_and_unmunge
    attr_reader :attributes_schema
    
    # This hash is used in the 'attributes' property
    # to figure out which userflag a given attribute maps to.
    attr_reader :userflags

    def attribute(info = {})
      info[:unmunge_fn] ||= lambda { |x| x }

      @attributes_schema ||= {}
      @attributes_schema[info[:name]] = info[:unmunge_fn]
    end

    def userflag_attribute(info = {})
      @userflags ||= {}
      @userflags[info[:name]] = info.delete(:flag)

      info[:unmunge_fn] = method(:unmunge_boolean)
      attribute(info)
    end

    def unmunge_boolean(str)
      return true if str == 'true'
      return false if str == 'false'
      raise ArgumentError, _("'%{str}' is not a Boolean value! Boolean values are 'true' or 'false'") % { str: str }
    end
  end

  # It would be great if we could manage the password_never_expires
  # and password_change_required attributes. Doing so would make our User
  # resource identical to DSC's User resource. We do not yet do this now,
  # however, because our User resource sets password_never_expires to always
  # be true whenever we create a User or set a new password on them.
  # If password_never_expires is true, then password_change_required can never
  # be set to true because doing so involves setting the ADS_UF_PASSWORD_EXPIRED
  # flag (i.e. expiring the User's current password). DSC's User resource manages
  # password_never_expires separately from the password property, which is why they
  # can manage these two attributes.
  #
  # We can do the same thing on our end. Existing customers who want their passwords
  # to never expire would just have to set password_never_expires to true when specifying
  # the attributes property in all of their manifests whenever they're creating a new user
  # or changing an existing user's password.
  #
  # Refer to https://docs.microsoft.com/en-us/powershell/dsc/userresource
  # for more details on DSC's User resource.
  #
  # We can also manage many more attributes than what's listed here. All of
  # the userflags can probably be individually managed. See
  #   https://docs.microsoft.com/en-us/windows/desktop/api/iads/ne-iads-ads_user_flag
  #
  # We can also manage the AccountExpirationDate

  attribute name: :full_name

  userflag_attribute name: :account_disabled,
                     flag: :ADS_UF_ACCOUNTDISABLE

  userflag_attribute name: :password_change_not_allowed,
                     flag: :ADS_UF_PASSWD_CANT_CHANGE

  def managed_attributes
    self.class.attributes_schema.keys
  end

  def unmunge_attribute(attribute, str_value)
    unmunge = self.class.attributes_schema[attribute]

    begin
      [attribute, unmunge.call(str_value)] 
    rescue ArgumentError => e
      raise ArgumentError, _("Failed to unmunge the %{attribute} attribute's value from its string representation. Detail: %{detail}") % { attribute: attribute, detail: e }
    end
  end

  def userflag_attributes
    self.class.userflags.keys
  end

  def userflag_of(attribute)
    self.class.userflags[attribute]
  end

  def initialize(value={})
    super(value)
    @deleted = false
  end

  def user
    @user ||= Puppet::Util::Windows::ADSI::User.new(@resource[:name])
  end

  def groups
    @groups ||= Puppet::Util::Windows::ADSI::Group.name_sid_hash(user.groups)
    @groups.keys
  end

  def groups=(groups)
    user.set_groups(groups, @resource[:membership] == :minimum)
  end

  def groups_insync?(current, should)
    return false unless current

    # By comparing account SIDs we don't have to worry about case
    # sensitivity, or canonicalization of account names.

    # Cannot use munge of the group property to canonicalize @should
    # since the default array_matching comparison is not commutative

    # dupes automatically weeded out when hashes built
    current_groups = Puppet::Util::Windows::ADSI::Group.name_sid_hash(current)
    specified_groups = Puppet::Util::Windows::ADSI::Group.name_sid_hash(should)

    current_sids = current_groups.keys.to_a
    specified_sids = specified_groups.keys.to_a

    if @resource[:membership] == :inclusive
      current_sids.sort == specified_sids.sort
    else
      (specified_sids & current_sids) == specified_sids
    end
  end

  def groups_to_s(groups)
    return '' if groups.nil? || !groups.kind_of?(Array)
    groups = groups.map do |group_name|
      sid = Puppet::Util::Windows::SID.name_to_principal(group_name)
      if sid.account =~ /\\/
        account, _ = Puppet::Util::Windows::ADSI::Group.parse_name(sid.account)
      else
        account = sid.account
      end
      resource.debug("#{sid.domain}\\#{account} (#{sid.sid})")
      "#{sid.domain}\\#{account}"
    end
    return groups.join(',')
  end

  def create
    @user = Puppet::Util::Windows::ADSI::User.create(@resource[:name])
    self.password = @resource[:password]

    [:comment, :home, :groups, :attributes].each do |prop|
      send("#{prop}=", @resource[prop]) if @resource[prop]
    end

    if @resource.managehome?
      Puppet::Util::Windows::User.load_profile(@resource[:name], @resource[:password])
    end
  end

  def exists?
    Puppet::Util::Windows::ADSI::User.exists?(@resource[:name])
  end

  def delete
    # lookup sid before we delete account
    sid = uid if @resource.managehome?

    Puppet::Util::Windows::ADSI::User.delete(@resource[:name])

    if sid
      Puppet::Util::Windows::ADSI::UserProfile.delete(sid)
    end

    @deleted = true
  end

  # Only flush if we created or modified a user, not deleted
  def flush
    @user.commit if @user && !@deleted
  end

  def comment
    user['Description']
  end

  def comment=(value)
    user['Description'] = value
  end

  def home
    user['HomeDirectory']
  end

  def home=(value)
    user['HomeDirectory'] = value
  end

  def password
    # avoid a LogonUserW style password check when the resource is not yet
    # populated with a password (as is the case with `puppet resource user`)
    return nil if @resource[:password].nil?
    user.password_is?( @resource[:password] ) ? @resource[:password] : nil
  end

  def password=(value)
    user.password = value
    user.set_userflags(:ADS_UF_DONT_EXPIRE_PASSWD)
  end

  def uid
    Puppet::Util::Windows::SID.name_to_sid(@resource[:name])
  end

  def uid=(value)
    fail "uid is read-only"
  end

  def attributes
    attributes_hash = {}
    attributes_hash[:full_name] = user['FullName']

    # The remaining attributes are mapped to userflags
    userflag_attributes.each do |attribute|
      flag = userflag_of(attribute)

      # We need to stringify our values b/c that's what the
      # KeyValue property class expects.
      attributes_hash[attribute] = user.userflag_set?(flag).to_s
    end

    attributes_hash
  end

  def validate_and_unmunge(new_attributes)
    unmanaged_attributes = new_attributes.keys.reject { |attribute| managed_attributes.include?(attribute) }
    unless unmanaged_attributes.empty?
      raise ArgumentError, _("Cannot manage the %{unmanaged_attributes} attributes. The manageable attributes are %{managed_attributes}.") % { unmanaged_attributes: unmanaged_attributes.join(', '), managed_attributes: managed_attributes.join(', ') }
    end

    new_attributes = new_attributes.map do |attribute, value|
      unmunge_attribute(attribute, value)
    end

    Hash[new_attributes]
  end

  def attributes=(new_attributes)
    new_attributes = validate_and_unmunge(new_attributes)

    if (full_name = new_attributes.delete(:full_name))
      user['FullName'] = full_name
    end

    # The remaining attributes are mapped to userflags.
    attributes_to_add, attributes_to_remove = new_attributes.partition do |_, value|
      value == true
    end
    flags_to_set, flags_to_unset = [attributes_to_add, attributes_to_remove].map do |attributes|
      attributes.map { |(attribute, _)| userflag_of(attribute) }
    end

    user.set_userflags(*flags_to_set)
    user.unset_userflags(*flags_to_unset)
  end

  [:gid, :shell].each do |prop|
    define_method(prop) { nil }
    define_method("#{prop}=") do |v|
      fail "No support for managing property #{prop} of user #{@resource[:name]} on Windows"
    end
  end

  def self.instances
    Puppet::Util::Windows::ADSI::User.map { |u| new(:ensure => :present, :name => u.name) }
  end
end
