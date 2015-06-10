require "yast"

Yast.import "Stage"

module Bootloader
  # class is responsible for detection, encryption and writing of grub2 password protection
  class GRUB2Pwd
    attr_accessor :used, :unrestricted
    alias_method :used?, :used
    alias_method :unrestricted?, :unrestricted

    def initialize
      # TODO offline upgrade should somehow read it when we need grub2 -> grub2 modifications
      if Yast::Stage.initial
        propose
      else
        read
      end
    end

    def write
      if used?
        enable
      else
        disable
      end
    end

    def password=(value)
      @encrypted_password = encrypt(value)
    end

    def password?
      !@encrypted_password.nil?
    end

    private

    def propose
      @used = false
      @unrestricted = false # TODO ensure it in FATE
      @encrypted_password = nil # not set by default
    end

    def read
      if !read_used
        propose
        return
      end

      @used = true
      content = Yast::SCR.Read(
        Yast::Path.new(".target.string"),
        PWD_ENCRYPTION_FILE
      )

      unrestricted_lines = content.lines.grep(/unrestricted_menuentry_users/)
      @unrestricted = !unrestricted_lines.empty?

      pwd_line = content.lines.grep(/password_pbkdf2 root/).first

      if !pwd_line
        raise "Cannot find encrypted password, YaST2 password generator in /etc/grub.d is probably modified."
      end

      @encrypted_password = pwd_line[/password_pbkdf2 root (\S+)/, 1]
    end

    YAST_BASH_PATH = Yast::Path.new(".target.bash_output")
    PWD_ENCRYPTION_FILE = "/etc/grub.d/42_password"
    def read_used
      Yast.import "FileUtils"

      Yast::FileUtils.Exists PWD_ENCRYPTION_FILE
    end

    def unrestricted?
      if !used?
        raise "Wrong code call: 'unrestricted?' called when password protection not set."
      end

    end

    def enable
      raise "Wrong code: password not written" unless @encrypted_password

      file_content = "#! /bin/sh\n" \
        "exec tail -n +3 $0\n" \
        "# File created by YaST and next password change in YaST will overwrite it\n" \
        "set superusers=\"root\"\n" \
        "password_pbkdf2 root #{@encrypted_password}\n" \
        "export superusers"

      if @unrestricted
        file_content << "\nset unrestricted_menuentry_users=\"$superusers\"\n\n" \
          "export unrestricted_menuentry_users"
      end

      Yast::SCR.Write(
        Yast::Path.new(".target.string"),
        [PWD_ENCRYPTION_FILE, 0700],
        file_content
      )
    end

    def disable
      return unless used?

      Yast::SCR.Execute(YAST_BASH_PATH, "rm '#{PWD_ENCRYPTION_FILE}'")
    end

    def encrypt(password)
      Yast.import "String"

      quoted_password = Yast::String.Quote(password)
      result = Yast::WFM.Execute(YAST_BASH_PATH,
        "echo '#{quoted_password}\n#{quoted_password}\n' | LANG=C grub2-mkpasswd-pbkdf2"
      )

      if result["exit"] != 0
        raise "Failed to create encrypted password for grub2. Command output: #{result["stderr"]}"
      end

      pwd_line = result["stdout"].split("\n").grep(/password is/).first
      if !pwd_line
        raise "INTERNAL ERROR: output do not contain encrypted password. Output: #{result["stdout"]}"
      end

      ret = pwd_line[/^.*password is\s*(\S+)/, 1]
      if !ret
        raise "INTERNAL ERROR: output do not contain encrypted password. Output: #{result["stdout"]}"
      end

      ret
    end
  end
end
