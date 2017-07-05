require "yast"

require "bootloader/udev_mapping"
require "bootloader/stage1_device"

require "yast2/target_file"
require "cfa/grub2/device_map"

require "y2storage"

module Bootloader
  # Class representing grub device map structure
  class DeviceMap
    extend Forwardable
    include Yast::Logger

    def_delegators :@model, :grub_device_for, :system_device_for, :grub_devices,
      :add_mapping, :remove_mapping

    def initialize
      # lazy load to avoid circular dependencies
      Yast.import "Arch"
      Yast.import "BootStorage"
      Yast.import "Mode"
      @model = CFA::Grub2::DeviceMap.new
    end

    def to_s
      "Device Map: #{to_hash}"
    end

    def read
      @model.load
    end

    def write
      log.info "writing device map: #{self}"
      @model.save
    end

    def size
      grub_devices.size
    end

    def empty?
      size == 0
    end

    def clear_mapping
      grub_devices.each do |grub_dev|
        remove_mapping(grub_dev)
      end
    end

    def contain_disk?(disk)
      disk = grub_device_for(disk) ||
        grub_device_for(::Bootloader::UdevMapping.to_mountby_device(disk))

      !disk.nil?
    end

    def disks_order
      sorted_disks.map { |d| system_device_for(d) }
    end

    def propose
      @model = CFA::Grub2::DeviceMap.new

      if Yast::Mode.config
        log.info("Skipping device map proposing in Config mode")
        return
      end

      fill_mapping

      order_boot_device

      reduce_to_bios_limit
    end

    def to_hash
      grub_devices.each_with_object({}) { |k, r| r[k] = system_device_for(k) }
    end

  private

    def sorted_disks
      grub_devices
        .select { |d| d.start_with?("hd") }
        .sort_by { |dev| dev[2..-1].to_i }
    end

    BIOS_LIMIT = 8
    # FATE #303548 - Grub: limit device.map to devices detected by BIOS Int 13
    # The function reduces records (devices) in device.map
    # Grub doesn't support more than 8 devices in device.map
    # @return [Boolean] true if device map was reduced
    def reduce_to_bios_limit
      if size <= BIOS_LIMIT
        log.info "device map not need to be reduced"
        return false
      end

      grub_devices = sorted_disks

      other_devices_size = size - grub_devices.size

      (BIOS_LIMIT - other_devices_size..(grub_devices.size - 1)).each do |index|
        remove_mapping(grub_devices[index])
      end

      log.info "device map after reduction #{self}"

      true
    end

    def order_boot_device
      # For us priority disk is device where /boot or / lives as we control this disk and
      # want to modify its MBR. So we get disk of such partition and change order to add it
      # to top of device map. For details see bnc#887808,bnc#880439
      boot_disk = Yast::BootStorage.disk_with_boot_partition
      priority_disks = ::Bootloader::Stage1Device.new(boot_disk.name).real_devices
      # if none of priority disk is hd0, then choose one and assign it
      return if any_first_device?(priority_disks)

      change_order(priority_disks.first)
    end

    def fill_mapping
      # storage-ng
      # BIOS-ID is not supported in libstorage-ng, so let's simply create a
      # mapping entry per disk for the time being (see commented code for the
      # real expected behavior)
      staging = Y2Storage::StorageManager.instance.y2storage_staging
      staging.disks.each_with_index do |disk, index|
        add_mapping("hd#{index}", disk.name)
      end
# rubocop:disable Style/BlockComments
=begin
      target_map = filtered_target_map
      log.info("Filtered target map: #{target_map}")

      # add devices with known bios_id
      # collect BIOS IDs which are used
      ids = {}
      target_map.each do |target_dev, target|
        bios_id = target["bios_id"] || ""
        next if bios_id.empty?

        index = if Yast::Arch.x86_64 || Yast::Arch.i386
          # it looks like 0x81. It is boot drive unit see http://en.wikipedia.org/wiki/Master_boot_record
          bios_id[2..-1].to_i(16) - 0x80
        else
          raise "no support for bios id '#{bios_id}' on #{Yast::Arch.architecture}"
        end
        # FATE #303548 - doesn't add disk with same bios_id with different name (multipath machine)
        if !ids[index]
          add_mapping("hd#{index}", target_dev)
          ids[index] = true
        end
      end
      # and guess other devices
      # don't use already used BIOS IDs
      target_map.each do |target_dev, target|
        next unless target.fetch("bios_id", "").empty?

        index = 0 # find free index
        index += 1 while ids[index]

        add_mapping("hd#{index}", target_dev)
        ids[index] = true
      end

      log.info "complete initial device map filling: #{self}"
=end
    end

    def filtered_target_map
      target_map = Yast::Storage.GetTargetMap.dup

      # select only disk devices
      target_map.select! do |_k, v|
        [:CT_DMRAID, :CT_DISK, :CT_DMMULTIPATH].include?(v["type"]) ||
          (v["type"] == :CT_MDPART &&
            mdraid_on_disk?(v["devices"] || [], target_map))
      end

      # filter out members of BIOS RAIDs and multipath devices
      target_map.delete_if do |k, v|
        [:UB_DMRAID, :UB_DMMULTIPATH].include?(v["used_by_type"]) ||
          (v["used_by_type"] == :UB_MDPART && disk_in_mdraid?(k, target_map))
      end

      target_map
    end

    # Returns true if any device from list devices is in device_mapping
    # marked as hd0.
    def any_first_device?(devices)
      devices.include?(system_device_for("hd0"))
    end

    # This function changes order of devices in device_mapping.
    # Priority device are always placed at first place    #
    def change_order(priority_device)
      log.info "Change order with priority_device: #{priority_device}"

      grub_dev = grub_device_for(priority_device)
      if !grub_dev
        log.warn("Unknown priority device '#{priority_device}'. Skipping")
        return
      end

      replaced_dev = system_device_for("hd0")
      remove_mapping("hd0")
      remove_mapping(grub_dev)
      add_mapping("hd0", priority_device)
      # switch order only if there was previously device at hd0. It can be empty e.g.
      # if bios_id is defined, but not for 0x80
      add_mapping(grub_dev, replaced_dev) if replaced_dev
    end

    # Check if MD raid is build on disks not on paritions
    # @param [Array<String>] devices - list of devices from MD raid
    # @param [Hash{String => map}] tm - unfiltered target map
    # @return - true if MD RAID is build on disks (not on partitions)
    def mdraid_on_disk?(devices, tm)
      devices.all? do |key|
        key == "" || tm[key]
      end
    end

    # Check if disk is in MDRaid it means completed disk is used in RAID
    # @param [String] disk (/dev/sda)
    # @param [Hash{String => map}] tm - target map
    # @return - true if disk (not only part of disk) is in MDRAID
    def disk_in_mdraid?(disk, tm)
      tm.values.any? do |disk_info|
        disk_info["type"] == :CT_MDPART &&
          (disk_info["devices"] || []).include?(disk)
      end
    end
  end
end
