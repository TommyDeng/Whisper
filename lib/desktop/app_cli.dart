/// 第二次启动传给已有进程的命令行参数（桌面「退出」动作会带上 `--quit`）。
library;

/// 桌面文件和 GApplication 约定的退出参数。
const kQuitArg = '--quit';

/// 开机自启动时带上：启动后不弹窗口，直接待在托盘。由原生层读取。
const kHiddenArg = '--hidden';

/// [args] 里是否要求已有进程真正退出，而不是把窗口请到前台。
bool wantsQuit(Iterable<String> args) => args.contains(kQuitArg);
