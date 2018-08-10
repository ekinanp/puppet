# Common code for AIX user/group providers.
class Puppet::Provider::AixObject < Puppet::Provider
  desc "Generic AIX resource provider"

  class << self
    #-------------
    # Mappings
    # ------------

    def mappings
      return @mappings if @mappings

      @mappings = {}
      @mappings[:aix_attribute] = {}
      @mappings[:puppet_property] = {}

      @mappings
    end

    # Add a mapping from a Puppet property to an AIX attribute. The mapping_info must include:
    #
    #   * :puppet_property       -- The puppet property corresponding to this attribute
    #   * :aix_attribute         -- The AIX attribute corresponding to this attribute. Defaults
    #                            to puppet_property if this is not provided.
    #   * :property_to_attribute -- A lambda that converts a Puppet Property to an AIX attribute
    #                            value. Defaults to the identity function if not provided.
    #   * :attribute_to_property -- A lambda that converts an AIX attribute to a Puppet property.
    #                            Defaults to the identity function if not provided.
    def mapping(mapping_info = {})
      identity_fn = lambda { |x| x }
      mapping_info[:aix_attribute] ||= mapping_info[:puppet_property]
      mapping_info[:property_to_attribute] ||= identity_fn
      mapping_info[:attribute_to_property] ||= identity_fn

      # This lets us write something like:
      #   @mappings[:aix_attribute][:uid].name
      #   @mappings[:aix_attribute][:uid].convert_property_value(value)
      #
      #   @mappings[:puppet_property][:id].name
      #   @mappings[:puppet_property][:id].convert_attribute_value(value)
      mappings[:aix_attribute][mapping_info[:puppet_property]] = create_mapped_object(
        mapping_info[:aix_attribute],
        :convert_property_value,
        mapping_info[:property_to_attribute]
      )
      mappings[:puppet_property][mapping_info[:aix_attribute]] = create_mapped_object(
        mapping_info[:puppet_property],
        :convert_attribute_value,
        mapping_info[:attribute_to_property]
      )
    end

    # Creates a mapping from a purely numeric Puppet property to
    # an attribute
    def numeric_mapping(mapping_info = {})
      property = mapping_info[:puppet_property]

      # We have this validation here b/c not all numeric properties
      # handle this at the property level (e.g. like the UID). Given
      # that, we might as well go ahead and do this validation for all
      # of our numeric properties. Doesn't hurt.
      mapping_info[:property_to_attribute] = lambda do |value|
        unless value.is_a?(Integer)
          raise ArgumentError, _("Invalid value #{value}: #{property} must be an Integer!")
        end

        value.to_s
      end

      # AIX will do the right validation to ensure numeric attributes
      # can't be set to non-numeric values, so no need for the extra clutter.
      mapping_info[:attribute_to_property] = lambda { |x| x.to_i }

      mapping(mapping_info)
    end

    #-------------
    # Useful Class Methods
    # ------------

    # Defines the getter and setter methods for each Puppet property that's mapped
    # to an AIX attribute. We define only a getter for the :attributes property.
    #
    # Provider subclasses should call this method after they've defined all of
    # their <puppet_property> => <aix_attribute> mappings.
    def mk_resource_methods
      # Define the Getter methods for each of our properties + the attributes
      # property
      properties = [:attributes]
      properties += mappings[:aix_attribute].keys
      properties.each do |property|
        # Define the getter
        define_method(property) do
          get(property)
        end

        # We have a custom setter for the :attributes property,
        # so no need to define it.
        next if property == :attributes

        # Define the setter
        define_method("#{property}=".to_sym) do |value|
          set(property, value)
        end
      end
    end

    # Parses a colon-separated list. Example includes something like:
    #   <item1>:<item2>:<item3>:<item4>
    #
    # Returns an array of the parsed items, e.g.
    #   [ <item1>, <item2>, <item3>, <item4> ]
    #
    # Note that colons inside items are escaped by #!
    def parse_colon_separated_list(list)
      # This helper splits a list separated by sep into its corresponding
      # items. Note that a key precondition here is that none of the items
      # in the list contain sep.
      #
      # Let A be the return value. Then one of our postconditions is:
      #   A.join(sep) == list
      split_list = lambda do |list, sep|
        next [""] if list.empty?

        # If list is our sep., then that means it held two
        # items both of which were empty.
        next ["", ""] if list == sep

        items = list.split(sep)

        # If list ends with sep., then our last item is empty
        # so we need to push it since String#split won't account
        # for this.
        items.push('') if list =~ /#{sep}\z/

        items
      end

      # ALGORITHM:
      # Treat the list as a list separated by '#!:' We will get something
      # like:
      #     [ <chunk1>, <chunk2>, ... <chunkn> ]
      #
      # Each chunk is now a list separated by ':' and none of the items
      # in each chunk contains an escaped ':'. Now, split each chunk on
      # ':' to get:
      #     [ [<piece11>, ..., <piece1n>], [<piece21>, ..., <piece2n], ... ]
      #
      # Now note that <item1> = <piece11>, <item2> = <piece12> in our original
      # list, and that <itemn> = <piece1n>#!:<piece21>. This is the main idea
      # behind what our inject method is trying to do at the end.
      chunks = split_list.call(list, '#!:')
      chunks.map! { |chunk| split_list.call(chunk, ':') }

      chunks.inject do |accum, chunk|
        left = accum.pop
        right = chunk.shift

        accum.push("#{left}:#{right}")
        accum += chunk
      end
    end

    # Parses the AIX objects from the command output, returning a hash of
    # <object_name> => <attributes>. Output should be of the form
    #   #name:<attr1>:<attr2> ...
    #   <name>:<value1>:<value2> ...
    #   #name:<attr1>:<attr2> ...
    #   <name>:<value1>:<value2> ...
    #
    # NOTE: We need to parse the colon-formatted output in case we have
    # space-separated attributes (e.g. 'gecos'). ":" characters are escaped
    # with a "#!".
    def parse_aix_objects(output)
      # Object names cannot begin with '#', so we are safe to
      # split individual users this way. We do not have to worry
      # about an empty list either since there is guaranteed to be
      # at least one instance of an AIX object (e.g. at least one
      # user or one group on the system).
      _, *objects = output.chomp.split(/^#/)

      objects.map do |object|
        attributes_line, values_line = object.chomp.split("\n")

        attributes = parse_colon_separated_list(attributes_line.chomp)
        attributes.map!(&:to_sym)

        values = parse_colon_separated_list(values_line.chomp)

        attributes_hash = attributes.zip(values).to_h

        object_name = attributes_hash.delete(:name)

        [object_name.to_s, attributes_hash]
      end.to_h
    end

    # Converts the given attributes hash to CLI args.
    def attributes_to_args(attributes)
      attributes.map do |attribute, value|
        "#{attribute}=#{value}"
      end
    end

    # Lists all instances of the given object, taking in an optional set
    # of ia_module arguments. Returns a hash of
    #   <object_name> => <id_property_value>
    def list_all
      id_property = mappings[:puppet_property][:id]

      # NOTE: We do not need to pass in the IA module arguments here
      # since we are only getting the id attribute.
      cmd = [command(:list), '-c', '-a', 'id', 'ALL']
      parse_aix_objects(execute(cmd)).map do |name, attributes|
        id = attributes.delete(:id)
        [name, id_property.convert_attribute_value(id)]
      end.to_h
    end

    #-------------
    # Provider API
    # ------------

    def instances
      list_all.map do |name, id|
        new({ :name => name })
      end
    end

    private

    # Creates the mapped object. The conversion_fn is the name of the function
    # we use to convert values to values in this mapped object's domain, while
    # conversion_fn_code is the conversion function's code (lambda we delegate
    # to).
    def create_mapped_object(name, conversion_fn, conversion_fn_code)
      obj = Object.new

      obj.class.send(:attr_accessor, :name)
      obj.name = name

      obj.define_singleton_method(conversion_fn) do |value|
        conversion_fn_code.call(value)
      end

      obj
    end
  end

  def ia_module_args
    return [] unless @resource[:ia_load_module]
    ["-R", @resource[:ia_load_module].to_s]
  end

  def lscmd
    [self.class.command(:list), '-c'] + ia_module_args + [@resource[:name]]
  end

  def addcmd(attributes)
    attribute_args = self.class.attributes_to_args(attributes)
    [self.class.command(:add)] + ia_module_args + attribute_args + [@resource[:name]]
  end

  def deletecmd
    [self.class.command(:delete)] + ia_module_args + [@resource[:name]]
  end

  def modifycmd(new_attributes)
    attribute_args = self.class.attributes_to_args(new_attributes)
    [self.class.command(:modify)] + ia_module_args + attribute_args + [@resource[:name]]
  end

  # Modifies the AIX object by setting its new attributes.
  def modify_object(new_attributes)
    execute(modifycmd(new_attributes))
    object_info(true) 
  end

  # Gets a Puppet property's value from @object_info
  def get(property)
    return :absent unless exists?
    @object_info[property] || :absent
  end

  # Sets a mapped Puppet property's value.
  def set(property, value)
    aix_attribute = self.class.mappings[:aix_attribute][property]
    modify_object(
      { aix_attribute.name => aix_attribute.convert_property_value(value) }
    )
  rescue Puppet::ExecutionFailure => detail
    raise Puppet::Error, _("Could not set %{property} on %{resource}[%{name}]: %{detail}") % { property: property, resource: @resource.class.name, name: @resource.name, detail: detail }, detail.backtrace
  end

  # Modifies the attribute property. Note we raise an error if the user specified
  # an AIX attribute corresponding to a Puppet property.
  def attributes=(new_attributes)
    # Check if the user's modifying a Puppet property. Raise an error if so.
    self.class.mappings[:aix_attribute].each do |property, aix_attribute|
      next unless new_attributes.key?(aix_attribute.name)
      detail = _("attributes is setting the #{property} property via. the #{aix_attribute.name} attribute! Please specify the #{property} property's value in the resource declaration.")

      raise Puppet::Error, _("Could not set attributes on %{resource}[%{name}]: %{detail}") % { resource: @resource.class.name, name: @resource.name, detail: detail }
    end

    modify_object(new_attributes)
  rescue Puppet::ExecutionFailure => detail
    raise Puppet::Error, _("Could not set attributes on %{resource}[%{name}]: %{detail}") % { resource: @resource.class.name, name: @resource.name, detail: detail }, detail.backtrace
  end

  # Collects the current property values of all mapped properties +
  # the attributes property.
  def object_info(refresh = false)
    return @object_info if @object_info && ! refresh
    @object_info = nil

    begin
      output = execute(lscmd)
    rescue Puppet::ExecutionFailure => detail
      Puppet.debug(_("aix.object_info(): Could not find #{@resource.class.name} #{@resource.name}: #{detail}"))

      return @object_info
    end

    aix_attributes = self.class.parse_aix_objects(output)[@resource.name]
    aix_attributes.each do |attribute, value|
      @object_info ||= {}

      # If our attribute has a Puppet property, then we store that. Else, we store it as part
      # of our :attributes property hash
      if (property = self.class.mappings[:puppet_property][attribute])
        @object_info[property.name] = property.convert_attribute_value(value)
      else
        @object_info[:attributes] ||= {}
        @object_info[:attributes][attribute] = value
      end
    end

    @object_info
  end

  #-------------
  # Provider API
  # ------------

  # Check that the AIX object exists
  def exists?
    ! object_info.nil?
  end

  # Creates a new instance of the resource
  def create
    # First, we figure out our user's attributes from the resource's should
    # parameter. Then we go through all of our Puppet properties corresponding
    # to AIX attributes and add those to our attributes hash. If the user already
    # passed-in an AIX attribute corresponding to a Puppet property via. the attributes
    # property itself, we throw an error. Otherwise, we pass in our final list of AIX
    # attributes to the addcmd.
    #
    # NOTE: We could also just call each property's setter method based on the @resource.should
    # value. We don't do that here b/c it's faster to do everything in bulk.
    attributes = @resource.should(:attributes) || {}
    self.class.mappings[:aix_attribute].each do |property, aix_attribute|
      if attributes.key?(aix_attribute.name)
        detail = _("attributes is setting the #{property} property via. the #{aix_attribute.name} attribute! Please specify the #{property} property's value in the resource declaration.")

        raise Puppet::Error, _("Could not create %{resource}[%{name}]: %{detail}") % { resource: @resource.class.name, name: @resource.name, detail: detail }
      end

      # Else, we can safely add this property to our AIX attributes hash, if it's
      # set
      property_should = @resource.should(property)
      next if property_should.nil?
      attributes[aix_attribute.name] = aix_attribute.convert_property_value(property_should)
    end

    execute(addcmd(attributes))
  rescue Puppet::ExecutionFailure => detail
    raise Puppet::Error, _("Could not create %{resource} %{name}: %{detail}") % { resource: @resource.class.name, name: @resource.name, detail: detail }, detail.backtrace
  end

  # Deletes this instance resource
  def delete
    execute(deletecmd)

    # Recollect the object info so that our current properties reflect
    # the actual state of the system. Otherwise, puppet resource reports
    # the wrong info. at the end. Note that this should return nil.
    object_info(true)
  rescue Puppet::ExecutionFailure => detail
    raise Puppet::Error, _("Could not delete %{resource} %{name}: %{detail}") % { resource: @resource.class.name, name: @resource.name, detail: detail }, detail.backtrace
  end
end
