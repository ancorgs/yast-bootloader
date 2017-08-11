require "yast"
require "bootloader/sysconfig"

Yast.import "BootStorage"
Yast.import "Linuxrc"
Yast.import "Mode"
Yast.import "PackageSystem"

module Bootloader
  # Represents base for all kinds of bootloaders
  class BootloaderBase
    def initialize
      @read = false
      @proposed = false
    end

    # writes configuration to target disk
    def write
      write_sysconfig
      # in running system install package, for other modes, it need specific handling
      Yast::PackageSystem.InstallAll(packages) if Yast::Mode.normal
    end

    # reads configuration from target disk
    def read
      @read = true
    end

    # Proposes new configuration
    def propose
      @proposed = true
    end

    # @return [Array<String>] description for proposal summary page for given bootloader
    def summary
      []
    end

    # @return true if configuration is already read
    def read?
      @read
    end

    # @return true if configuration is already proposed
    def proposed?
      @proposed
    end

    # @return [Array<String>] packages required to configure given bootloader
    def packages
      res = []

      # added kexec-tools fate# 303395
      if !Yast::Mode.live_installation &&
          Yast::Linuxrc.InstallInf("kexec_reboot") != "0"
        res << "kexec-tools"
      end

      res
    end

    # done in common write but also in installation pre write as kernel update need it
    # @param prewrite [Boolean] true only in installation when scr is not yet switched
    def write_sysconfig(prewrite: false)
      sysconfig = Bootloader::Sysconfig.new(bootloader: name)
      prewrite ? sysconfig.pre_write : sysconfig.write
    end

    # merges other bootloader configuration into this one.
    # It have to be same bootloader type.
    def merge(other)
      raise "Invalid merge argument #{other.name} for #{name}" if name != other.name

      @read ||= other.read?
      @proposed ||= other.proposed?
    end
  end
end
