# 耳语（Whisper）发布说明

打 `v*` 标签并推送到 GitHub 后，CI 会构建安装包、生成 `SHA256SUMS`、用 GPG 签名，并创建 GitHub Release。**不要把私钥提交进仓库，也不要在对话里粘贴私钥。**

当前 `pubspec.yaml` 版本是 `1.0.1+2`（发行版本 `1.0.1`）。标签必须写成 `v1.0.1`，与 `pubspec.yaml` 里 `+` 前面的版本号一致，否则发布任务会失败。

注：`v1.0.0` 标签打在发布流程修复前的提交上，发布任务因 `download-artifact` 固定版本错误而失败，没有生成 Release。该标签保留不动，第一版正式发布为 `v1.0.1`。

## 产物

每个 Release 附带：

| 文件 | 说明 |
| --- | --- |
| `whisper_<版本>_amd64.deb` | Debian / Ubuntu 安装包 |
| `whisper-<版本>-x86_64.AppImage` | Linux AppImage（可直接运行） |
| `whisper-<版本>-linux-x64.tar.gz` | Linux 便携目录（内含 `bundle/`） |
| `Whisper-Setup-<版本>-x64.exe` | Windows 安装器（Inno Setup，**未做代码签名**） |
| `Whisper-<版本>-windows-x64.zip` | Windows 便携包 |
| `SHA256SUMS` | 上述安装包的 SHA-256 校验和 |
| `SHA256SUMS.asc` | 对 `SHA256SUMS` 的 GPG 分离签名 |

Windows 安装包没有购买代码签名证书，SmartScreen 可能提示“Windows 保护了你的电脑”。请先按下文校验哈希和签名，再点“更多信息 → 仍要运行”。

## 需要在 GitHub 填写的密钥（只列名字）

在仓库 **Settings → Secrets and variables → Actions → New repository secret** 添加：

| Secret 名称 | 用途 |
| --- | --- |
| `GPG_PRIVATE_KEY` | 用来签署 `SHA256SUMS` 的 GPG **私钥**。可以贴 ASCII 装甲文本（含 `BEGIN PGP PRIVATE KEY BLOCK`），也可以贴这段文本的 base64。CI 发布时导入，不会写入仓库。 |
| `GPG_PASSPHRASE` | 上述私钥的口令。 |

这两个 secret 只在打 `v*` 标签触发的 `release` 任务里使用。缺少任一个，发布会失败，不会发出未签名的 Release。

生成密钥、导出私钥、保管口令都由仓库所有者在自己的机器上完成，不要交给他人或自动化工具代填。公钥请自行公布（建议写进本仓库 README 的指纹处），私钥只放在上述 secret 和你自己的离线备份里。

密钥泄露时：立即在 GitHub 吊销并轮换这两个 secret，用新密钥重新签名，并在 Release 说明里公告。

## 发第一个版本

1. 确认要发布的提交已经在 `main` 上（通过 PR 合并）。
2. 确认 `pubspec.yaml` 的 `version:` 是你想发的发行号，例如 `1.0.0+1`。以后升版本时改这里，再开 PR 合并。
3. 按上一节配置好 `GPG_PRIVATE_KEY` 和 `GPG_PASSPHRASE`。
4. 在本地对已合并的 `main` 打标签并推送（不要由机器人代打）：

   ```bash
   git checkout main
   git pull --ff-only
   git tag -a v1.0.0 -m "耳语 1.0.0"
   git push origin v1.0.0
   ```

5. 在 GitHub Actions 里等待名为 `ci` 的工作流跑完。`release` 任务成功后，[Releases](https://github.com/TommyDeng/Whisper/releases) 会出现 `v1.0.0` 和上面的安装包。

以后发新版本：先改 `pubspec.yaml` 的版本并合并到 `main`，再打并推送对应的 `vX.Y.Z` 标签。带连字符的标签（例如 `v1.0.0-rc.1`）会标成 pre-release，同样要求与 pubspec 版本一致。

## 客户端自动更新依赖的约定

客户端「关于」里的更新功能（`lib/update/`）直接读 Release 的产物，下面两样不能随意改：

- 安装包文件名（见上面“产物”表）和 `SHA256SUMS` / `SHA256SUMS.asc`。
- 签名密钥：客户端内置了发布公钥（`lib/update/pgp_verify.dart` 的 `kReleasePublicKey`），只接受这把钥匙签的 `SHA256SUMS`。轮换密钥时，要先发一个内置新公钥、但仍用旧钥匙签名的版本，否则老客户端会拒绝更新，只能手动下载。

## 校验安装包

把公钥导入本地（只需一次），再下载 Release 里的安装包、`SHA256SUMS` 和 `SHA256SUMS.asc`：

```bash
# 验证签名（把 <指纹> 换成 README 里公布的公钥指纹）
gpg --verify SHA256SUMS.asc SHA256SUMS

# Linux：核对校验和
sha256sum -c SHA256SUMS

# Windows PowerShell：核对某个文件的哈希，与 SHA256SUMS 里对应行比较
Get-FileHash -Algorithm SHA256 Whisper-Setup-1.0.0-x64.exe
```

签名或哈希对不上就不要安装。

## 本地打包（可选）

先编译，再运行脚本（会把结果写到当前目录或 `OUTPUT_DIR`）：

```bash
flutter build linux --release
./packaging/linux/build-deb.sh
# AppImage 会按校验和下载固定版本的 appimagetool（1.9.1）
OUTPUT_DIR=packaging/dist ./packaging/linux/build-appimage.sh
```

Windows 在 Windows 机器上：

```text
flutter build windows --release
iscc /DMyAppVersion=1.0.0 packaging\windows\installer.iss
```

便携 zip 是把 `build\windows\x64\runner\Release\` 整目录打包。

## 本流程不覆盖的事

- 不会自动部署 Cloudflare Worker，也不会创建云资源。
- 应用内检查更新尚未实现；用户需自己到 GitHub Releases 下载。
- 不会替你打 tag，也不会在未配置密钥时静默发布。
