/// 哪些文件当作图片：在聊天里直接显示，收到时不用确认就自动保存。
library;

/// 自动接收的图片大小上限。更大的仍按普通文件处理，等用户确认。
const kAutoImageMaxBytes = 20 * 1024 * 1024;

/// 根据文件名（或路径）判断是否是常见图片。只看扩展名，不读文件内容。
bool isImageFileName(String name) => imageExtension(name) != null;

/// 文件名里的图片扩展名（小写，不带点）；不是常见图片时为 null。
String? imageExtension(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return null;
  final ext = name.substring(dot + 1).toLowerCase();
  return const {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'}.contains(ext)
      ? ext
      : null;
}
