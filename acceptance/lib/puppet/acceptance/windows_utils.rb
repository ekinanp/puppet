require 'puppet/acceptance/common_utils'

module Puppet
  module Acceptance
    module WindowsUtils
      require 'puppet/acceptance/windows_utils/service.rb'

      def profile_base(agent)
        ruby = Puppet::Acceptance::CommandUtils.ruby_command(agent)
        getbasedir = <<'END'
require 'win32/dir'
puts Dir::PROFILE.match(/(.*)\\\\[^\\\\]*/)[1]
END
        on(agent, "#{ruby} -e \"#{getbasedir}\"").stdout.chomp
      end

      def current_attributes_on(host, user)
        retrieve_user_attributes = <<-PS1
function Is-UserFlagSet($user, $flag) {
  # Only declare the flags we need. More can be added as we add
  # more attributes to the Windows user.
  $ADS_USERFLAGS = @{
    'ADS_UF_ACCOUNTDISABLE'     = 0x0002;
    'ADS_UF_PASSWD_CANT_CHANGE' = 0x0040;
    'ADS_UF_DONT_EXPIRE_PASSWD' = 0x10000
  }

  $flag_set = ($user.get('UserFlags') -band $ADS_USERFLAGS[$flag]) -ne 0

  # 'true' and 'false' are 'True' and 'False' in Powershell, respectively,
  # so we need to convert them from their Powershell representation to their
  # Ruby one.
  "'$(([string] $flag_set).ToLower())'"
}

# This lets us fail the test if an error occurs while running
# the script.
$ErrorActionPreference = 'Stop'

$user = [ADSI]"WinNT://./#{user},user"
$attributes = @{
  'full_name'                   = "'$($user.FullName)'";
  'password_change_required'    = If ($user.PasswordExpired -eq 1) { "'true'" } Else { "'false'" };
  'disabled'                    = Is-UserFlagSet $user 'ADS_UF_ACCOUNTDISABLE';
  'password_change_not_allowed' = Is-UserFlagSet $user 'ADS_UF_PASSWD_CANT_CHANGE';
  'password_never_expires'      = Is-UserFlagSet $user 'ADS_UF_DONT_EXPIRE_PASSWD';
}

Write-Output "{"
foreach ($attribute in $attributes.keys) {
  Write-Output "  '${attribute}' => $($attributes[$attribute]),"
}
Write-Output "}"
  PS1

        stdout = execute_powershell_script_on(host, retrieve_user_attributes).stdout.chomp
        Kernel.eval(stdout)
      end

      def user_password_is?(host, user, password)
        test_user_password = <<-PS1
Add-Type -AssemblyName System.DirectoryServices.AccountManagement
$ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext(
  [System.DirectoryServices.AccountManagement.ContextType]::Machine,
  $env:COMPUTERNAME
)

# 'true' and 'false' are 'True' and 'False' in Powershell, respectively, so
# we need to convert them from their Powershell representation to their
# Ruby one.
([string] $ctx.ValidateCredentials("#{user}", "#{password}")).ToLower()
PS1

        stdout = execute_powershell_script_on(host, test_user_password).stdout.chomp
        Kernel.eval(stdout)
      end
    end
  end
end
