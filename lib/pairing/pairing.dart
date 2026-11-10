/// 耳语配对模块：邀请码、二维码、URL scheme、手动批准。
///
/// 配对流程：
/// 1. 一方生成邀请码（Base32，含公钥 + 一次性 token，24h 有效）
/// 2. 对方扫描二维码或粘贴邀请码
/// 3. 邀请人收到配对请求，显示对方安全码，手动批准/拒绝
/// 4. 批准后建立会话，交换安全码

library;

export 'invitation_code.dart';
export 'pairing_manager.dart';
export 'pairing_page.dart';
