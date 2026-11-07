import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/ice/candidate.dart';
import 'package:whisper/ice/nic.dart';
import 'package:whisper/ice/path_stats.dart';
import 'package:whisper/ice/scheduler.dart';

void main() {
  final nics = [
    const NicInfo(name: 'eth0', kind: NicKind.lan, addresses: ['192.168.1.10']),
    const NicInfo(name: 'zt0', kind: NicKind.zerotier, addresses: ['10.147.17.8']),
    const NicInfo(name: 'lo', kind: NicKind.loopback, addresses: ['127.0.0.1']),
  ];

  ParsedCandidate parse(String line) {
    final parsed = parseCandidateLine(line, nics);
    expect(parsed, isNotNull);
    return parsed!;
  }

  test('classifies ZeroTier, LAN, and virtual adapters', () {
    expect(classifyInterface(name: 'eth0'), NicKind.lan);
    expect(classifyInterface(name: 'ztosf4zq2y'), NicKind.zerotier);
    expect(
      classifyInterface(name: 'Ethernet 2', description: 'ZeroTier Virtual Port'),
      NicKind.zerotier,
    );
    expect(classifyInterface(name: 'docker0'), NicKind.other);
    expect(classifyInterface(name: 'tailscale0'), NicKind.other);
    expect(classifyInterface(name: 'vEthernet', description: 'Hyper-V Virtual Ethernet Adapter'), NicKind.other);
  });

  test('parses ip -j and Windows adapter JSON', () {
    final linux = parseIpJsonAddr('''
[
  {"ifname":"lo","operstate":"UNKNOWN","addr_info":[{"family":"inet","local":"127.0.0.1"}]},
  {"ifname":"eth0","operstate":"UP","addr_info":[{"family":"inet","local":"192.168.1.10"}]},
  {"ifname":"zt0","operstate":"UNKNOWN","addr_info":[{"family":"inet","local":"10.147.17.8"}]},
  {"ifname":"docker0","operstate":"DOWN","addr_info":[{"family":"inet","local":"172.17.0.1"}]}
]
''');
    expect(linux.map((nic) => nic.name), ['lo', 'eth0', 'zt0']);
    expect(linux[2].kind, NicKind.zerotier);

    final windows = parseWindowsNetJson('''
{
  "adapters": {"Name":"ZeroTier One","InterfaceDescription":"ZeroTier Virtual Port","Status":"Up"},
  "ips": {"InterfaceAlias":"ZeroTier One","IPAddress":"10.147.17.9"}
}
''');
    expect(windows.single.kind, NicKind.zerotier);
    expect(windows.single.addresses, ['10.147.17.9']);
  });

  test('rewrites host local preference and leaves srflx alone', () {
    const original = 2122260223;
    final lan = parse('candidate:1 1 UDP $original 192.168.1.10 10000 typ host generation 0');
    final zt = parse('candidate:2 1 UDP $original 10.147.17.8 10001 typ host generation 0');
    final srflx = parse(
      'candidate:3 1 UDP 1686052607 203.0.113.8 20000 typ srflx raddr 192.168.1.10 rport 10000',
    );
    expect(lan.tier, PathTier.lan);
    expect(localPreferenceOf(lan.rewrittenPriority), 65535);
    expect(typePreferenceOf(lan.rewrittenPriority), typePreferenceOf(original));
    expect(localPreferenceOf(zt.rewrittenPriority), 40960);
    expect(lan.rewrittenPriority, greaterThan(zt.rewrittenPriority));
    expect(srflx.rewrittenPriority, 1686052607);
    expect(srflx.signaledLine, contains('203.0.113.8'));
    expect(parse('candidate:4 1 UDP $original abcd.local 9 typ host').tier, PathTier.mdnsHost);
  });

  test('releases LAN first, then the rest after fallback', () {
    final scheduler = CandidateScheduler(nics: nics, fallback: const Duration(seconds: 5));
    final start = DateTime.utc(2026);
    scheduler.add(parse('candidate:3 1 UDP 1686052607 203.0.113.8 20000 typ srflx raddr 192.168.1.10 rport 10000'), now: start);
    expect(scheduler.drain(start), isEmpty);
    scheduler.add(parse('candidate:2 1 UDP 2122260223 10.147.17.8 10001 typ host'), now: start.add(const Duration(seconds: 1)));
    scheduler.add(parse('candidate:1 1 UDP 2122260223 192.168.1.10 10000 typ host'), now: start.add(const Duration(seconds: 1)));
    final preferred = scheduler.drain(start.add(const Duration(seconds: 1)));
    expect(preferred.map((item) => item.parsed.address), ['192.168.1.10']);
    expect(scheduler.drain(start.add(const Duration(seconds: 1))), isEmpty);
    final rest = scheduler.drain(start.add(const Duration(seconds: 6)));
    expect(rest.map((item) => item.parsed.address), ['203.0.113.8', '10.147.17.8']);
  });

  test('uses ZeroTier when gathering finishes without a LAN candidate', () {
    final scheduler = CandidateScheduler(nics: nics, fallback: const Duration(seconds: 5));
    final start = DateTime.utc(2026);
    scheduler.add(parse('candidate:2 1 UDP 2122260223 10.147.17.8 10001 typ host'), now: start);
    scheduler.add(parse('candidate:3 1 UDP 1686052607 203.0.113.8 20000 typ srflx raddr 10.147.17.8 rport 10001'), now: start);
    scheduler.markGatheringComplete();
    expect(scheduler.drain(start).single.parsed.address, '10.147.17.8');
    expect(scheduler.describe(), contains('ZeroTier'));
    expect(scheduler.drain(start.add(const Duration(seconds: 5))).single.parsed.address, '203.0.113.8');
  });

  test('seals after connect so later fallback does not release candidates', () {
    final scheduler = CandidateScheduler(nics: nics, fallback: const Duration(seconds: 5));
    final start = DateTime.utc(2026);
    scheduler.add(parse('candidate:1 1 UDP 2122260223 192.168.1.10 10000 typ host'), now: start);
    scheduler.add(parse('candidate:3 1 UDP 1686052607 203.0.113.8 20000 typ srflx raddr 192.168.1.10 rport 10000'), now: start);
    expect(scheduler.drain(start).single.parsed.tier, PathTier.lan);
    scheduler.seal();
    expect(scheduler.drain(start.add(const Duration(seconds: 30))), isEmpty);
    expect(scheduler.describe(), contains('不再发布'));
  });

  test('stops preferring interfaces when host candidates are mDNS or nics are unknown', () {
    final scheduler = CandidateScheduler(nics: nics);
    final start = DateTime.utc(2026);
    scheduler.add(parse('candidate:1 1 UDP 2122260223 abcd.local 9 typ host'), now: start);
    scheduler.add(parse('candidate:3 1 UDP 1686052607 203.0.113.8 20000 typ srflx raddr 192.168.1.10 rport 9'), now: start);
    expect(scheduler.drain(start).map((item) => item.parsed.address), ['abcd.local', '203.0.113.8']);
    expect(scheduler.bypassReason, BypassReason.mdns);

    final blind = CandidateScheduler(nics: const [], nicMapReady: true);
    blind.add(parseCandidateLine('candidate:1 1 UDP 2122260223 192.168.1.10 9 typ host', const [])!, now: start);
    expect(blind.drain(start), isNotEmpty);
    expect(blind.bypassReason, BypassReason.noNicMap);
  });

  test('reads the selected pair and DTLS state', () {
    const reports = [
      {
        'id': 'T1',
        'type': 'transport',
        'selectedCandidatePairId': 'P1',
        'dtlsState': 'connected',
        'dtlsCipher': 'TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256',
        'srtpCipher': 'AES_CM_128_HMAC_SHA1_80',
      },
      {
        'id': 'P1',
        'type': 'candidate-pair',
        'localCandidateId': 'L1',
        'remoteCandidateId': 'R1',
        'state': 'succeeded',
        'nominated': true,
      },
      {
        'id': 'L1',
        'type': 'local-candidate',
        'candidateType': 'host',
        'address': '10.147.17.8',
        'port': 50000,
        'protocol': 'udp',
      },
      {
        'id': 'R1',
        'type': 'remote-candidate',
        'candidateType': 'host',
        'address': '10.147.17.9',
        'port': 50001,
        'protocol': 'udp',
      },
    ];
    final zt = interpretPath(reports, nics);
    expect(zt.label, 'ZeroTier');
    expect(zt.dtlsActive, isTrue);
    expect(zt.srtpCipher, contains('AES_CM'));

    final relay = interpretPath([
      {
        'id': 'P',
        'type': 'candidate-pair',
        'selected': true,
        'localCandidateId': 'L',
        'remoteCandidateId': 'R',
      },
      {'id': 'L', 'type': 'local-candidate', 'candidateType': 'relay', 'address': '1.2.3.4', 'port': 3478},
      {'id': 'R', 'type': 'remote-candidate', 'candidateType': 'relay', 'address': '5.6.7.8', 'port': 3478},
    ], nics);
    expect(relay.label, '中继');

    final public = interpretPath([
      {
        'id': 'P',
        'type': 'candidate-pair',
        'nominated': 'true',
        'state': 'succeeded',
        'localCandidateId': 'L',
        'remoteCandidateId': 'R',
      },
      {'id': 'L', 'type': 'local-candidate', 'candidateType': 'srflx', 'ip': '203.0.113.8', 'port': 20000},
      {'id': 'R', 'type': 'remote-candidate', 'candidateType': 'srflx', 'ip': '198.51.100.9', 'port': 20001},
    ], nics);
    expect(public.label, '公网 P2P');
  });

  test('Windows LAN and ZeroTier names share one classification with the scheduler', () {
    const ztName = 'ZeroTier One [166359304e7a07aa]';
    const lanName = '以太网 3';
    const lanDescription = 'Realtek PCIe 2.5GbE Family Controller';
    expect(classifyInterface(name: ztName), NicKind.zerotier);
    expect(classifyInterface(name: lanName, description: lanDescription), NicKind.lan);
    expect(normalizeIp('fe80::abcd%3'), normalizeIp('[fe80::abcd%14]'));
    expect(
      kindForAddress('fe80::abcd%3', [
        NicInfo(
          name: lanName,
          description: lanDescription,
          kind: NicKind.lan,
          addresses: ['192.168.31.180', 'fe80::abcd%14'],
        ),
      ]),
      NicKind.lan,
    );

    final discovered = <NicInfo>[];
    final scheduler = CandidateScheduler(nics: discovered, fallback: const Duration(seconds: 5));
    final start = DateTime.utc(2026);
    ParsedCandidate line(String address, int priority, String type) {
      return parseCandidateLine('candidate:1 1 UDP $priority $address 9 typ $type', const [])!;
    }

    scheduler.add(line('192.168.31.180', 2122260223, 'host'), now: start);
    scheduler.add(line('10.30.249.106', 2122260223, 'host'), now: start);
    scheduler.add(line('203.0.113.8', 1686052607, 'srflx'), now: start);
    expect(scheduler.drain(start), isEmpty);
    expect(scheduler.describe(), '正在识别网卡，先不发布候选');
    expect(scheduler.bypassReason, isNot(BypassReason.noNicMap));

    discovered.addAll([
      NicInfo(
        name: ztName,
        description: 'ZeroTier Virtual Port',
        kind: classifyInterface(name: ztName, description: 'ZeroTier Virtual Port'),
        addresses: ['10.30.249.106'],
      ),
      NicInfo(
        name: lanName,
        description: lanDescription,
        kind: classifyInterface(name: lanName, description: lanDescription),
        addresses: ['192.168.31.180', 'fe80::abcd%14'],
      ),
    ]);
    scheduler.noteNicMapReady();
    final preferred = scheduler.drain(start);
    expect(preferred.map((item) => item.parsed.address), ['192.168.31.180']);
    expect(scheduler.tierOf(preferred.single), PathTier.lan);
    expect((int.parse(scheduler.lineToSignal(preferred.single).split(' ')[3]) >> 8) & 0xffff, 65535);
    expect(scheduler.describe(), contains('局域网'));
    expect(scheduler.bypassReason, BypassReason.none);

    final rest = scheduler.drain(start.add(const Duration(seconds: 5)));
    expect(rest.map((item) => item.parsed.address), containsAll(['10.30.249.106', '203.0.113.8']));
    expect(scheduler.tierOf(rest.firstWhere((item) => item.parsed.address == '10.30.249.106')), PathTier.zerotier);
  });

  test('SPIKE_ONLY_TIER publishes one tier and never falls back', () {
    final windows = [
      const NicInfo(name: 'ZeroTier One [166359304e7a07aa]', kind: NicKind.zerotier, addresses: ['10.30.249.106']),
      const NicInfo(name: '以太网 3', kind: NicKind.lan, addresses: ['192.168.31.180']),
    ];
    ParsedCandidate host(String address) {
      return parseCandidateLine('candidate:1 1 UDP 2122260223 $address 9 typ host', windows)!;
    }

    final start = DateTime.utc(2026);
    final zerotierOnly = CandidateScheduler(
      nics: windows,
      nicMapReady: true,
      fallback: const Duration(seconds: 5),
      onlyTier: PathTier.zerotier,
    );
    zerotierOnly.add(host('192.168.31.180'), now: start);
    zerotierOnly.add(host('10.30.249.106'), now: start);
    zerotierOnly.add(parseCandidateLine('candidate:3 1 UDP 1686052607 203.0.113.8 9 typ srflx', windows)!, now: start);
    zerotierOnly.add(parseCandidateLine('candidate:4 1 UDP 2122260223 abcd.local 9 typ host', windows)!, now: start);
    zerotierOnly.markGatheringComplete();
    expect(zerotierOnly.drain(start).map((item) => item.parsed.address), ['10.30.249.106']);
    expect(zerotierOnly.drain(start.add(const Duration(minutes: 2))), isEmpty);
    expect(zerotierOnly.describe(), contains('ZeroTier'));
    expect(zerotierOnly.describe(), contains('不回退'));
    zerotierOnly.seal();
    expect(zerotierOnly.describe(), contains('已连通'));
    expect(zerotierOnly.describe(), isNot(contains('正在识别网卡')));
    zerotierOnly.refreshStatus(start.add(const Duration(minutes: 2)));
    expect(zerotierOnly.describe(), contains('已连通'));
    expect(zerotierOnly.describe(), isNot(contains('正在识别网卡')));

    final waiting = CandidateScheduler(
      nics: const [],
      nicMapReady: false,
      onlyTier: PathTier.zerotier,
      nicMapWait: const Duration(seconds: 15),
    );
    waiting.add(parseCandidateLine('candidate:1 1 UDP 2122260223 10.30.249.106 9 typ host', const [])!, now: start);
    expect(waiting.drain(start), isEmpty);
    expect(waiting.describe(), contains('正在识别网卡'));
    waiting.seal();
    expect(waiting.describe(), contains('已连通'));
    expect(waiting.describe(), isNot(contains('正在识别网卡')));

    final srflxOnly = CandidateScheduler(nics: windows, nicMapReady: true, onlyTier: PathTier.srflx);
    srflxOnly.add(host('192.168.31.180'), now: start);
    srflxOnly.add(parseCandidateLine('candidate:3 1 UDP 1686052607 203.0.113.8 9 typ srflx', windows)!, now: start);
    srflxOnly.markGatheringComplete();
    expect(srflxOnly.drain(start).map((item) => item.parsed.address), ['203.0.113.8']);
    expect(srflxOnly.drain(start.add(const Duration(minutes: 2))), isEmpty);
  });
}
