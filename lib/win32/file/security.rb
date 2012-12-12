require File.join(File.dirname(__FILE__), 'windows', 'constants')
require File.join(File.dirname(__FILE__), 'windows', 'structs')
require File.join(File.dirname(__FILE__), 'windows', 'functions')

class File
  include Windows::File::Constants
  include Windows::File::Functions
  extend Windows::File::Constants
  extend Windows::File::Structs
  extend Windows::File::Functions

  # The version of the win32-file library
  WIN32_FILE_SECURITY_VERSION = '1.0.0'

  class << self

    # Returns whether or not the root path is encryptable. If no root is
    # specified, it will check against the root of the current directory.
    # Be sure to include a trailing slash in the root path name.
    #
    # Examples:
    #
    #   p File.encryptable?
    #   p File.encryptable?("D:\\")
    #
    def encryptable?(file = nil)
      bool = false
      flags_ptr = FFI::MemoryPointer.new(:ulong)

      file = file.wincode if file

      unless GetVolumeInformationW(file, nil, 0, nil, nil, flags_ptr, nil, 0)
        raise SystemCallError.new("GetVolumeInformation", FFI.errno)
      end

      flags = flags_ptr.read_ulong

      if flags & FILE_SUPPORTS_ENCRYPTION > 0
        bool = true
      end

      bool
    end

    # Encrypts a file or directory. All data streams in a file are encrypted.
    # All new files created in an encrypted directory are encrypted.
    #
    # The caller must have the FILE_READ_DATA, FILE_WRITE_DATA,
    # FILE_READ_ATTRIBUTES, FILE_WRITE_ATTRIBUTES, and SYNCHRONIZE access
    # rights.
    #
    # Requires exclusive access to the file being encrypted, and will fail if
    # another process is using the file or the file is marked read-only. If the
    # file is compressed the file will be decompressed before encrypting it.
    #
    def encrypt(file)
      unless EncryptFileW(file.wincode)
        raise SystemCallError.new("EncryptFile", FFI.errno)
      end
      self
    end

    # Decrypts an encrypted file or directory.
    #
    # The caller must have the FILE_READ_DATA, FILE_WRITE_DATA,
    # FILE_READ_ATTRIBUTES, FILE_WRITE_ATTRIBUTES, and SYNCHRONIZE access
    # rights.
    #
    # Requires exclusive access to the file being decrypted, and will fail if
    # another process is using the file. If the file is not encrypted an error
    # is NOT raised, it's simply a no-op.
    #
    def decrypt(file)
      unless DecryptFileW(file.wincode, 0)
        raise SystemCallError.new("DecryptFile", FFI.errno)
      end
      self
    end

    # Returns a hash describing the current file permissions for the given
    # file.  The account name is the key, and the value is an integer mask
    # that corresponds to the security permissions for that file.
    #
    # To get a human readable version of the permissions, pass the value to
    # the +File.securities+ method.
    #
    # You may optionally specify a host as the second argument. If no host is
    # specified then the current host is used.
    #
    # Examples:
    #
    #   hash = File.get_permissions('test.txt')
    #
    #   p hash # => {"NT AUTHORITY\\SYSTEM"=>2032127, "BUILTIN\\Administrators"=>2032127, ...}
    #
    #   hash.each{ |name, mask|
    #     p name
    #     p File.securities(mask)
    #   }
    #
    def get_permissions(file, host=nil)
      size_needed_ptr = FFI::MemoryPointer.new(:ulong)
      security_ptr    = FFI::MemoryPointer.new(:ulong)

      wide_file = file.wincode
      wide_host = host ? host.wincode : nil

      # First pass, get the size needed
      bool = GetFileSecurityW(
        wide_file,
        DACL_SECURITY_INFORMATION,
        security_ptr,
        security_ptr.size,
        size_needed_ptr
      )

      errno = FFI.errno

      if !bool && errno != ERROR_INSUFFICIENT_BUFFER
        raise SystemCallError.new("GetFileSecurity", errno)
      end

      size_needed = size_needed_ptr.read_ulong

      security_ptr = FFI::MemoryPointer.new(size_needed)

      # Second pass, this time with the appropriately sized security pointer
      bool = GetFileSecurityW(
        wide_file,
        DACL_SECURITY_INFORMATION,
        security_ptr,
        security_ptr.size,
        size_needed_ptr
      )

      unless bool
        raise SystemCallError.new("GetFileSecurity", FFI.errno)
      end

      control_ptr  = FFI::MemoryPointer.new(:ulong)
      revision_ptr = FFI::MemoryPointer.new(:ulong)

      unless GetSecurityDescriptorControl(security_ptr, control_ptr, revision_ptr)
        raise SystemCallError.new("GetSecurityDescriptorControl", FFI.errno)
      end

      control = control_ptr.read_ulong

      if control & SE_DACL_PRESENT == 0
        raise ArgumentError, "No DACL present: explicit deny all"
      end

      dacl_pptr          = FFI::MemoryPointer.new(:pointer)
      dacl_present_ptr   = FFI::MemoryPointer.new(:bool)
      dacl_defaulted_ptr = FFI::MemoryPointer.new(:ulong)

      val = GetSecurityDescriptorDacl(
        security_ptr,
        dacl_present_ptr,
        dacl_pptr,
        dacl_defaulted_ptr
      )

      if val == 0
        raise SystemCallError.new("GetSecurityDescriptorDacl", FFI.errno)
      end

      acl = ACL.new(dacl_pptr.read_pointer)

      if acl[:AclRevision] == 0
        raise ArgumentError, "DACL is NULL: implicit access grant"
      end

      ace_count  = acl[:AceCount]
      perms_hash = {}

      0.upto(ace_count - 1){ |i|
        ace_pptr = FFI::MemoryPointer.new(:pointer)
        next unless GetAce(acl, i, ace_pptr)

        access = ACCESS_ALLOWED_ACE.new(ace_pptr.read_pointer)

        if access[:Header][:AceType] == ACCESS_ALLOWED_ACE_TYPE
          name = FFI::MemoryPointer.new(:uchar, 260)
          name_size = FFI::MemoryPointer.new(:ulong)
          name_size.write_ulong(name.size)

          domain = FFI::MemoryPointer.new(:uchar, 260)
          domain_size = FFI::MemoryPointer.new(:ulong)
          domain_size.write_ulong(domain.size)

          use_ptr = FFI::MemoryPointer.new(:pointer)

          val = LookupAccountSidW(
            wide_host,
            ace_pptr.read_pointer + 8,
            name,
            name_size,
            domain,
            domain_size,
            use_ptr
          )

          if val == 0
            raise SystemCallError.new("LookupAccountSid", FFI.errno)
          end

          # The x2 multiplier is necessary due to wide char strings.
          name = name.read_string(name_size.read_ulong * 2).delete(0.chr)
          domain = domain.read_string(domain_size.read_ulong * 2).delete(0.chr)
          mask =

          unless domain.empty?
            name = domain + '\\' + name
          end

          perms_hash[name] = access[:Mask]
        end
      }

      perms_hash
    end

    # Sets the file permissions for the given file name.  The 'permissions'
    # argument is a hash with an account name as the key, and the various
    # permission constants as possible values. The possible constant values
    # are:
    #
    # * FILE_READ_DATA
    # * FILE_WRITE_DATA
    # * FILE_APPEND_DATA
    # * FILE_READ_EA
    # * FILE_WRITE_EA
    # * FILE_EXECUTE
    # * FILE_DELETE_CHILD
    # * FILE_READ_ATTRIBUTES
    # * FILE_WRITE_ATTRIBUTES
    # * STANDARD_RIGHTS_ALL
    # * FULL
    # * READ
    # * ADD
    # * CHANGE
    # * DELETE
    # * READ_CONTROL
    # * WRITE_DAC
    # * WRITE_OWNER
    # * SYNCHRONIZE
    # * STANDARD_RIGHTS_REQUIRED
    # * STANDARD_RIGHTS_READ
    # * STANDARD_RIGHTS_WRITE
    # * STANDARD_RIGHTS_EXECUTE
    # * STANDARD_RIGHTS_ALL
    # * SPECIFIC_RIGHTS_ALL
    # * ACCESS_SYSTEM_SECURITY
    # * MAXIMUM_ALLOWED
    # * GENERIC_READ
    # * GENERIC_WRITE
    # * GENERIC_EXECUTE
    # * GENERIC_ALL
    #
    def set_permissions(file, perms)
      raise TypeError unless file.is_a?(String)
      raise TypeError unless perms.kind_of?(Hash)

      wide_file = file.wincode

      account_rights = 0
      sec_desc = FFI::MemoryPointer.new(:pointer, SECURITY_DESCRIPTOR_MIN_LENGTH)

      unless InitializeSecurityDescriptor(sec_desc, 1)
        raise SystemCallError.new("InitializeSecurityDescriptor", FFI.errno)
      end

      acl = ACL.new

      unless InitializeAcl(acl, acl.size, ACL_REVISION2)
        raise SystemCallError.new("InitializeAcl", FFI.errno)
      end

      perms.each{ |account, mask|
        next if mask.nil?

        server, account = account.split("\\")

        if ['BUILTIN', 'NT AUTHORITY'].include?(server.upcase)
          wide_server = nil
        else
          wide_server = server.wincode
        end

        wide_account = account.wincode

        sid = FFI::MemoryPointer.new(:pointer, 1024)

        sid_size = FFI::MemoryPointer.new(:ulong)
        sid_size.write_ulong(sid.size)

        use_ptr = FFI::MemoryPointer.new(:pointer)

        val = LookupAccountName(
           wide_server,
           wide_account,
           sid,
           sid_size,
           nil,
           0,
           snu_type
        )

        if val == 0
          raise ArgumentError, get_last_error
        end

=begin
        size = [0,0,0,0,0].pack('CCSLL').length # sizeof(ACCESS_ALLOWED_ACE)

        val = CopySid(
          ALLOW_ACE_LENGTH - size,
          all_ace_ptr + 8,  # address of all_ace_ptr->SidStart
          sid
        )

        if val == 0
          raise ArgumentError, get_last_error
        end

        if (GENERIC_ALL & mask).nonzero?
          account_rights = GENERIC_ALL & mask
        elsif (GENERIC_RIGHTS_CHK & mask).nonzero?
          account_rights = GENERIC_RIGHTS_MASK & mask
        end

        # all_ace_ptr->Header.AceFlags = INHERIT_ONLY_ACE|OBJECT_INHERIT_ACE
        all_ace[1] = (INHERIT_ONLY_ACE | OBJECT_INHERIT_ACE).chr

        # WHY DO I NEED THIS RUBY CORE TEAM? WHY?!?!?!?!?!?
        all_ace.force_encoding('ASCII-8BIT') if RUBY_VERSION.to_f >= 1.9

        2.times{
          if account_rights != 0
            all_ace[2,2] = [12 - 4 + GetLengthSid(sid)].pack('S')
            all_ace[4,4] = [account_rights].pack('L')

            val = AddAce(
              acl_new,
              ACL_REVISION2,
              MAXDWORD,
              all_ace_ptr,
              all_ace[2,2].unpack('S').first
            )

            if val == 0
              raise ArgumentError, get_last_error
            end

            # all_ace_ptr->Header.AceFlags = CONTAINER_INHERIT_ACE
            all_ace[1] = CONTAINER_INHERIT_ACE.chr
          else
            # all_ace_ptr->Header.AceFlags = 0
            all_ace[1] = 0.chr
          end

          account_rights = REST_RIGHTS_MASK & mask
        }
=end
      }

=begin
      unless SetSecurityDescriptorDacl(sec_desc, 1, acl_new, 0)
        raise ArgumentError, get_last_error
      end

      unless SetFileSecurityW(file, DACL_SECURITY_INFORMATION, sec_desc)
        raise ArgumentError, get_last_error
      end
=end

      self
    end

    # Returns an array of human-readable strings that correspond to the
    # permission flags.
    #
    # Example:
    #
    #   File.get_permissions('test.txt').each{ |name, mask|
    #     puts name
    #     p File.securities(mask)
    #   }
    #
    def securities(mask)
      sec_array = []

      security_rights = {
        'FULL'    => FULL,
        'DELETE'  => DELETE,
        'READ'    => READ,
        'CHANGE'  => CHANGE,
        'ADD'     => ADD
      }

      if mask == 0
        sec_array.push('NONE')
      else
        if (mask & FULL) ^ FULL == 0
          sec_array.push('FULL')
        else
          security_rights.each{ |string, numeric|
            if (numeric & mask) ^ numeric == 0
              sec_array.push(string)
            end
          }
        end
      end

      sec_array
    end
  end
end

p File.get_permissions('test.txt')
File.set_permissions('test.txt', {"scipio\\djberge" => File::FULL})
