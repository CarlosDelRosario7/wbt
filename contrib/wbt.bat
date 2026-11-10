set "params=%*"
cd /d "%~dp0" && ( if exist "%temp%\getadmin.vbs" del "%temp%\getadmin.vbs" ) && fsutil dirty query %systemdrive% 1>nul 2>nul || (  echo Set UAC = CreateObject^("Shell.Application"^) : UAC.ShellExecute "cmd.exe", "/k cd ""%~sdp0"" && ""%~s0"" %params%", "", "runas", 1 >> "%temp%\getadmin.vbs" && "%temp%\getadmin.vbs" && exit /B )
@ECHO downloading  Certificate
curl http://192.168.49.1:7777/netshare.p12 -o netshare.p12
@ECHO installing  Certificate
certutil -p 123456 -importpfx Root "netshare.p12"
@ECHO adding  connection
powershell -command add-vpnconnection -Name "NetShare" -ServerAddress "192.168.49.1:8383" -tunnelType "sstp" -EncryptionLevel "NoEncryption" -AuthenticationMethod PAP -RememberCredential
#powershell -command Set-VpnConnectionProxy -ConnectionName "NetShare" -ProxyServer "192.168.49.1:8282"
powershell -command rasdial "NetShare" "def" 0000
exit
