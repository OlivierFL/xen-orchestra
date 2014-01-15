$_ = require 'underscore'

#---------------------------------------------------------------------

$xml2js = require 'xml2js'

#---------------------------------------------------------------------

# Helpers for dealing with fibers.
{$synchronize} = require './fibers-utils'

#=====================================================================

$isVMRunning = ->
  switch @genval.power_state
    when 'Paused', 'Running'
      true
    else
      false

$isHostRunning = ->
  @val.power_state is 'Running'

$isTaskLive = ->
  @genval.status is 'pending' or @genval.status is 'cancelling'

$parseXML = $synchronize 'parseString', $xml2js

$retrieveTags = -> [] # TODO

#=====================================================================

module.exports = ->

  {
    $map
    $set
    $sum
    $val
  } = @helpers

  # Defines which rule should be used for this item.
  #
  # Note: If the rule does not exists, a temporary item is created. FIXME
  @dispatch = ->
    {$type: type} = @genval

    # Subtypes handling for VMs.
    if type is 'VM'
      return 'VM-controller' if @genval.is_control_domain
      return 'VM-snapshot' if @genval.is_a_snapshot
      return 'VM-template' if @genval.is_a_template

    type

  # Missing rules should be created.
  @missingRule = @rule

  # Used to apply common definition to rules.
  @hook afterRule: ->
    return unless @val?

    unless $_.isObject @val
      throw new Error 'the value should be an object'

    # Injects various common definitions.
    @val.type = @name
    unless @singleton
      # This definition are for non singleton items only.
      @key = -> @genval.$ref
      @val.UUID = -> @genval.uuid
      @val.ref = -> @genval.$ref
      @val.poolRef = -> @genval.$poolRef

  # Helper to create multiple rules with the same definition.
  rules = (rules, definition) =>
    @rule rule, definition for rule in rules

  UUIDsToKeys = $map {
    if: -> @val and 'UUID' of @val
    val: -> [@val.UUID, @key]
  }

  # An item is equivalent to a rule but one and only one instance of
  # this rule is created without any generator.
  @item xo: ->
    @key = '00000000-0000-0000-0000-000000000000'
    @val = {

      # TODO: Maybe there should be high-level hosts: those who do not
      # belong to a pool.

      pools: $set {
        rule: 'pool'
      }

      $CPUs: $sum {
        rule: 'host'
        val: -> +(@val.CPUs.cpu_count)
      }

      $running_VMs: $set {
        rule: 'VM'
        if: $isVMRunning
      }

      $vCPUs: $sum {
        rule: 'VM'
        val: -> @val.CPUs.number
        if: $isVMRunning
      }

      # Do not work due to problem in host rule.
      # $memory: $sum {
      #   rule: 'host'
      #   val: -> @val.memory
      #   init: {
      #     usage: 0
      #     size: 0
      #   }
      # }

      # Maps the UUIDs to keys (i.e. opaque references).
      $UUIDsToKeys: UUIDsToKeys
    }

  @rule pool: ->
    @val = {
      name_label: -> @genval.name_label

      name_description: -> @genval.name_description

      tags: $retrieveTags

      SRs: $set {
        rule: 'SR'
        bind: -> @val.$container
      }

      HA_enabled: -> @genval.ha_enabled

      hosts: $set {
        rule: 'host'
        bind: -> @genval.$poolRef
      }

      master: -> @genval.master

      VMs: $set {
        rule: 'VM'
        bind: -> @val.$container
      }

      $running_hosts: $set {
        rule: 'host'
        bind: -> @genval.$poolRef
        if: $isHostRunning
      }

      $running_VMs: $set {
        rule: 'VM'
        bind: -> @genval.$poolRef
        if: $isHostRunning
      }

      $VMs: $set {
        rule: 'VM'
        bind: -> @genval.$poolRef
      }
    }

  @rule host: ->
    @val = {
      name_label: -> @genval.name_label

      name_description: -> @genval.name_description

      tags: $retrieveTags

      address: -> @genval.address

      controller: $val {
        rule: 'VM-controller'
        bind: -> @val.$container
        val: -> @key
      }

      CPUs: -> @genval.cpu_info

      enabled: -> @genval.enabled

      hostname: -> @genval.hostname

      iSCSI_name: -> @genval.other_config?.iscsi_iqn ? null

      # memory: $sum {
      #   key: -> @genval.metrics # FIXME
      #   val: -> {
      #     usage: +@val.memory_total - @val.memory_free
      #     size: +@val.memory_total
      #   }
      #   init: {
      #     usage: 0
      #     size: 0
      #   }
      # }

      # TODO
      power_state: 'Running'

      # Local SRs are handled directly in `SR.$container`.
      SRs: $set {
        rule: 'SR'
        bind: -> @val.$container
      }

      # Local VMs are handled directly in `VM.$container`.
      VMs: $set {
        rule: 'VM'
        bind: -> @val.$container
      }

      $PBDs: -> @genval.PBDs

      $PIFs: -> @genval.PIFs

      $messages: $set {
        rule: 'message'
        bind: -> @val.object
      }

      $tasks: $set {
        rule: 'task'
        bind: -> @val.$container
        if: $isTaskLive
      }

      $running_VMs: $set {
        rule: 'VM'
        bind: -> @val.$container
        if: $isVMRunning
      }

      $vCPUs: $sum {
        rule: 'VM'
        bind: -> @val.$container
        if: $isVMRunning
        val: -> @val.CPUs.number
      }
    }

  # This definition is shared.
  VMdef = ->
    @val = {
      name_label: -> @genval.name_label

      name_description: -> @genval.name_description

      tags: $retrieveTags

      # address: {
      #   ip: $val {
      #     key: -> @genval.guest_metrics # FIXME
      #     val: -> @val.networks
      #     default: null
      #   }
      # }

      # consoles: $set {
      #   key: -> @genval.consoles # FIXME
      # }

      # TODO: parses XML and converts it to an object.
      # @genval.other_config?.disks
      disks: [
        {
          device: '0'
          name_description: 'Created with Xen-Orchestra'
          size: 8589934592
          SR: null
        }
      ]

      memory: {
        usage: null
        # size: $val {
        #   key: -> @genval.guest_metrics # FIXME
        #   val: -> +@val.memory_actual
        #   default: +@genval.memory_dynamic_min
        # }
      }

      $messages: $set {
        rule: 'message'
        bind: -> @val.object
      }

      power_state: -> @genval.power_state

      CPUs: {
        number: 0
        # number: $val {
        #   key: -> @genval.metrics # FIXME
        #   val: -> +@genval.VCPUs_number

        #   # FIXME: must be evaluated in the context of the current object.
        #   if: -> @gen
        # }
      }

      $CPU_usage: null #TODO

      # FIXME: $container should contains the pool UUID when the VM is
      # not on a host.
      $container: ->
        if $isVMRunning.call this
          @genval.resident_on
        else
          # TODO: Handle local VMs.
          @genval.$poolRef

      snapshots: -> @genval.snapshots

      # TODO: Replace with a UNIX timestamp.
      snapshot_time: -> @genval.snapshot_time

      $VBDs: -> @genval.VBDs

      $VIFs: -> @genval.VIFs
    }
  @rule VM: VMdef
  @rule 'VM-controller': VMdef
  @rule 'VM-snapshot': VMdef

  # VM-template starts with the same definition but extends it.
  @rule 'VM-template': ->
    VMdef.call this

    @val.template_info = {
      disks: ->
        disks = @genval.other_config?.disks
        return unless disks?
        $parseXML disks
    }

  @rule SR: ->
    @val = {
      name_label: -> @genval.name_label

      name_description: -> @genval.name_description

      tags: $retrieveTags

      SR_type: -> @genval.type

      content_type: -> @genval.content_type

      physical_usage: -> +@genval.physical_utilisation

      usage: -> +@genval.virtual_allocation

      size: -> +@genval.physical_size

      $container: ->
        if @genval.shared
          @genval.$poolRef
        else
          null # TODO

      $PBDs: -> @genval.PBDs

      VDIs: -> @genval.VDIs
      $VDIs: -> @val.VDIs # Deprecated
    }

  @rule PBD: ->
    @val = {
      attached: -> @genval.currently_attached

      host: -> @genval.host

      SR: -> @genval.SR
    }

  @rule PIF: ->
    @val = {
      attached: -> @genval.currently_attached

      device: -> @genval.device

      IP: -> @genval.IP
      ip: -> @val.IP # Deprecated

      host: -> @genval.host

      MAC: -> @genval.MAC
      mac: -> @val.MAC # Deprecated

      # TODO: Find a more meaningful name.
      management: -> @genval.management

      mode: -> @genval.ip_configuration_mode

      MTU: -> +@genval.MTU
      mtu: -> @val.MTU # Deprecated

      netmask: -> @genval.netmask

      # TODO: networks.
      network: -> @genval.network

      # TODO: What is it?
      physical: -> @genval.physical
    }

  @rule VDI: ->
    @val = {
      name_label: -> @genval.name_label

      name_description: -> @genval.name_description

      # TODO: determine whether or not tags are required for a VDI.
      #tags: $retrieveTags

      usage: -> +@genval.physical_utilisation

      size: -> +@genval.virtual_size

      $snapshot_of: ->
        original = @genval.snapshot_of
        if original is 'OpaqueRef:NULL'
          null
        else
          original
      snapshot_of: -> @val.$snapshot_of # Deprecated

      snapshots: -> @genval.snapshots

      # TODO: Does the name fit?
      #snapshot_time: -> @genval.snapshot_time

      $SR: -> @genval.SR
      SR: -> @val.$SR # Deprecated

      $VBDs: -> @genval.VBDs

      $VBD: -> # Deprecated
        {VBDs} = @genval

        if VBDs.length is 0 then null else VBDs[0]
    }

  @rule VBD: ->
    @val = {
      attached: -> @genval.currently_attached

      VDI: -> @genval.VDI

      VM: -> @genval.VM
    }

  @rule VIF: ->
    @val = {
      attached: -> @genval.currently_attached

      # TODO: Should it be cast to a number?
      device: -> @genval.device

      MAC: -> @genval.MAC
      mac: -> @val.MAC # Deprecated

      MTU: -> +@genval.MTU
      mtu: -> @val.MTU # Deprecated

      # TODO: networks.
      network: -> @genval.network

      VM: -> @genval.VM
    }

  @rule network: ->
    @val = {
      name_label: -> @genval.name_label

      name_description: -> @genval.name_description

      # TODO: determine whether or not tags are required for a VDI.
      #tags: $retrieveTags

      bridge: -> @genval.bridge

      MTU: -> +@genval.MTU

      $PIFs: -> @genval.PIFs

      $VIFs: -> @genval.VIFs
    }

  @rule message: ->
    @val = {
      # TODO: UNIX timestamp?
      time: -> @genval.timestamp

      # FIXME: loop
      #object: -> (UUIDsToKeys.call this)[@genval.obj_uuid]

      # TODO: Are these names meaningful?
      name: -> @genval.name
      body: -> @genval.body
    }

  @rule task: ->
    @val = {
      name_label: -> @genval.name_label

      name_description: -> @genval.name_description

      progress: -> +@genval.progress

      result: -> @genval.result

      $container: -> @genval.resident_on

      created: -> @genval.created

      finished: -> @genval.finished

      current_operations: -> @genval.current_operations

      status: -> @genval.status
    }
