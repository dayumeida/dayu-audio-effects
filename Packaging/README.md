# 大鱼音频效果器发行打包

2026-11-02 完成 **1.2（构建 10）**：自动电平及低延迟版默认目标均为 -3 dB；主程序包含音视频时间线预览、原音/效果对比和离线输出。低延迟目标范围从 -30…-9 扩展至 -30…-3 dB，参数树、DSP 限值及界面一致。已有工程与预设沿用保存值。

- 安装包：`Outputs/Distribution/1.2-10/大鱼音频效果器安装包-1.2.pkg`，42,407,490 字节。
- SHA256：`fe2091fd17645df2e29dda981ce3ea66da6438a54564cdf14f8b835396ff7c1b`。
- 发行 APP：`Outputs/Distribution/1.2-10/App/大鱼音频效果器.app`。
- PKG 工坊工程：`Packaging/大鱼音频效果器.pkgforge`；构建 9 工程已另存。
- 精确命令、签名、公证、包清单及验证：`Analysis/Packaging/1.2-10`。
- 文章：https://dayu.media/15770/ ，50 元，会员免费，沿用原文章。

显式以 `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES` Release 归档，再按 `ExportOptions.plist` Developer ID 导出。APP 及 appex 均启用 Hardened Runtime，无 get-task-allow。APP 公证 Accepted 后粘附并验证票据，再通过 `/usr/local/bin/pkgforge` 制作完整 APP 安装包，使用 Developer ID Installer 签名并完成 PKG 公证、票据及 Gatekeeper 检查。

包内 41 个文件的内容、符号链接及可执行权限与发行 APP 一致，四组件版本 65545，模型哈希正确。固定安装到 `/Applications/大鱼音频效果器.app`，不可重定位；无安装脚本。支持 Apple Silicon、macOS 14+。安装前退出 FCP 和主程序，完成后打开已安装 APP 一次，再启动 FCP。

原 1.2（9）及更早正式包保留。本轮未执行本机 PKG 安装，未覆盖 `Outputs/OfflineProcessing` 或仍由 FCP 使用的旧开发成品；仅对默认值变更运行既有核心检查，未追加 FCP/试听验收。源码备份位于 `.codex-backups/before-default-minus3-build10-20261102.tar.gz`。
