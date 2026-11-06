import 'dart:io';

import 'nic.dart';

Future<List<NicInfo>> probeLocalNics() async {
  if (Platform.isLinux || Platform.isAndroid) {
    final result = await Process.run('ip', ['-j', 'addr']).timeout(const Duration(seconds: 5));
    if (result.exitCode != 0) {
      throw Exception('ip -j addr 失败：${result.stderr}'.trim());
    }
    return parseIpJsonAddr(result.stdout.toString());
  }
  if (Platform.isWindows) {
    const script = r'''
$adapters = @(Get-NetAdapter | Select-Object Name, InterfaceDescription, Status)
$ips = @(Get-NetIPAddress | Where-Object { $_.AddressFamily -eq 'IPv4' -or $_.AddressFamily -eq 'IPv6' } | Select-Object InterfaceAlias, IPAddress)
@{ adapters = $adapters; ips = $ips } | ConvertTo-Json -Depth 4 -Compress
''';
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      script,
    ]).timeout(const Duration(seconds: 5));
    if (result.exitCode != 0) {
      stdout.writeln('Windows 网卡探测退出码 ${result.exitCode}，返回空列表');
      return const [];
    }
    try {
      return parseWindowsNetJson(result.stdout.toString());
    } catch (error) {
      stdout.writeln('Windows 网卡 JSON 解析失败：$error，返回空列表');
      return const [];
    }
  }
  return const [];
}
