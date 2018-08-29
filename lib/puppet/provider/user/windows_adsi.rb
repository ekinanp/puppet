require 'puppet/util/windows'

Puppet::Type.type(:user).provide :windows_adsi do
  desc "Local user management for Windows."

  defaultfor :operatingsystem => :windows
  confine    :operatingsystem => :windows

  has_features :manages_homedir,
               :manages_passwords,
               :manages_attributes

  class << self
    def unmunge_boolean(str)
      return true if str == 'true'
      return false if str == 'false'
      raise ArgumentError, _("'%{str}' is not a Boolean value! Boolean values are 'true' or 'false'") % { str: str }
    end

    def unmunge_string(str)
      str
    end
  end

  # This hash is used in the 'attributes' property
  # to figure out which userflag a given attribute maps to.
  #
  # TODO (PUP-9082): Maybe this and the AIX mappings code
  # could be used in a more generic way? This is pretty much
  # a one-way mapping. The refactor is not immediately obvious
  # right now, but worth looking into in the future.
  #
  # TODO (PUP-5216): Check the combinations carefully.
  # Issue is setting the expiration date in the password
  # functions.
  #
  ATTRIBUTES_USERFLAGS = {
    account_disabled:            :ADS_UF_ACCOUNTDISABLE,
    password_change_not_allowed: :ADS_UF_PASSWD_CANT_CHANGE,
    password_change_required:    :ADS_UF_PASSWORD_EXPIRED,
    password_never_expires:      :ADS_UF_DONT_EXPIRE_PASSWD
  }

  # Unlike our AIX attributes, our Windows attributes have a
  # fixed schema. Because the :attributes property munges values
  # to their string representation, we need to unmunge them here
  # when setting these values. Thus, this schema is a hash of
  #     <attribute> => <unmunge function>
  #
  # See #validate_and_unmunge
  #
  ATTRIBUTES_SCHEMA = {
    account_disabled:             method(:unmunge_boolean),
    full_name:                    method(:unmunge_string),
    password_change_not_allowed:  method(:unmunge_boolean),
    password_change_required:     method(:unmunge_boolean),
    password_never_expires:       method(:unmunge_boolean)
  }

  # Also unlike our AIX attributes, the ADS User does not validate all
  # of our attribute combinations prior to setting them (especially
  # those attributes that also correspond to userflags). Thus, it is
  # possible for a non-sensical combination like password_change_required == true
  # and password_change_not_allowed == true to occur. Thankfully because
  # our attributes are fixed, we can enumerate these invalid combinations
  # and then check them later when setting the attributes. Thus, each element
  # in this array is a pair of
  #     (Invalid combination, Reason why the combination is invalid).
  #
  # See #check_combinations
  #
  # NOTE: We could also rewrite this as ATTRIBUTES_CHECKS, which is an array
  # where each element is a check we do on our attributes value (a predicate).
  # Implementing this is more generic than what's done here, however doing so
  # would significantly clutter up the code and add an extra layer of indirection
  # without there being a clear use case for it. Thus for now, it is best to go
  # with the more straightfoward approach.
  ATTRIBUTES_INVALID_COMBINATIONS = [
    [
      { password_change_not_allowed: true, password_change_required: true },
      _("This is a contradiction")
    ],
    [
      { password_change_not_allowed: true, password_never_expires: false },
      _("It is not a good idea to disallow changing the password while also allowing it to expire.")
    ],
    [
      { password_change_required: true, password_never_expires: true },
      _("Unfortunately, password_change_required is enforced by immediately expiring the password. For a password that never expires, Windows will throw an 'Access Denied' error when you try to change the password upon the first login.")
    ]
  ]

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

    # Set the password to never expire by default, unless we're
    # explicitly managing the :password_never_expires attribute.
    # We can cleanly do this by just syncing the attributes
    # property (which also lets us check for any invalid combinations).
    #
    # NOTE: We use the string 'true' instead of the Boolean true
    # b/c our should value expects string values for the :attributes
    # property.
    attributes_should = @resource[:attributes] || {}
    attributes_should[:password_never_expires] ||= 'true'
    self.attributes = attributes_should
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
    ATTRIBUTES_USERFLAGS.each do |attribute, flag|
      # We need to stringify our values b/c that's what the
      # KeyValue property class expects.
      attributes_hash[attribute] = user.userflag_set?(flag).to_s
    end

    attributes_hash
  end

  # Here is where we check if our new_attributes have an invalid
  # combination. If they do, we _do_ _not_ error the Puppet run. We still
  # set our User attributes. However, we will log a warning notifying the
  # user of the invalid combination, including telling them why the
  # combination is invalid. The reason we do not error is because:
  #    * Some of these attributes correspond to DSC User resource
  #    properties. DSC does not check for these invalid combinations.
  #    Since some of our users may migrate from using DSC to using Puppet,
  #    we want to preserve as much of the existing DSC behavior as we can.
  #
  #    * There could be some weird, esoteric scenarios where some of these
  #    invalid combinations might be a good idea. Thus, it is better to err on
  #    the cautious side and log a warning than make some hasty (and possibly
  #    incorrect) judgment call.
  #
  # TODO: Should we just log a warning for all of the invalid combinations that
  # we find?
  #
  def check_combinations(new_attributes)
    invalid_combination, reason = ATTRIBUTES_INVALID_COMBINATIONS.find do |(combination, _)|
      combination.all? { |attribute, value| new_attributes[attribute] == value }
    end

    return unless invalid_combination

    invalid_combination_str = invalid_combination.map do |attribute, value|
      "#{attribute}=#{value}"
    end.join(', ')

    warning _("Setting %{invalid_combination} for the User attributes is not a good idea. Reason: %{reason}") % { invalid_combination: invalid_combination_str, reason: reason }
  end

  # Here we validate our new attributes against the attributes schema
  # and then unmunge our attribute values. We then check our unmunged
  # attribute values against our invalid attribute combinations before
  # proceeding to return the unmunged attributes.
  def validate_and_unmunge(new_attributes)
    unless new_attributes.keys.all? { |attribute| ATTRIBUTES_SCHEMA.keys.include?(attribute) }
      raise ArgumentError, _("The attributes property for a Windows user only accepts the %{allowable_keys} keys as input!") % { allowable_keys: schema.keys.join(', ') }
    end

    new_attributes = new_attributes.map do |attribute, value|
      munge = ATTRIBUTES_SCHEMA[attribute]
      begin
        [attribute, munge.call(value)] 
      rescue ArgumentError => e
        raise ArgumentError, _("Failed to munge the %{attribute} attribute's value. Detail: %{detail}") % { attribute: attribute, detail: e }
      end
    end
    new_attributes = Hash[new_attributes]

    check_combinations(new_attributes)

    new_attributes
  end

  # NOTE: There's a chance we can call this twice. One from password=,
  # and one when syncing this. Thankfully, this property is idempotent
  # so we're OK here.
  def attributes=(new_attributes)
    new_attributes = validate_and_unmunge(new_attributes)

    if (full_name = new_attributes.delete(:full_name))
      user['FullName'] = full_name
    end

    # The remaining attributes are mapped to userflags.
    attributes_to_add, attributes_to_remove = new_attributes.partition do |_, value|
      value == true
    end
    flags_to_add, flags_to_remove = [attributes_to_add, attributes_to_remove].map do |attributes|
      attributes.map { |(attribute, _)| ATTRIBUTES_USERFLAGS[attribute] }
    end

    user.set_userflags(*flags_to_add)
    user.unset_userflags(*flags_to_remove)
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
