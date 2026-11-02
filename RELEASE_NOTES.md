# 大鱼音频效果器 1.2（构建 10）

发行日期：2026-11-02。Git 标签：`v1.2-build10`。

- 一个主 App 和一个 AUv3 扩展提供自动电平、低延迟自动电平、智能降噪、破音修复四种中文效果。
- 主 App 支持音视频时间线预览、波形缩放、原音与效果对比，以及在原目录输出处理副本。
- 两种自动电平的新建/重置默认目标均为 -3 dB，低延迟版目标范围为 -30 至 -3 dB；已有工程与预设保留已保存参数。
- 支持 Apple Silicon、macOS 14 及以上；可在 Final Cut Pro 的 Dayu 音频效果分类中使用。

## 安装与校验

下载 Release 附件 `DayuAudioEffects-1.2-build10-arm64.pkg`。安装前退出 Final Cut Pro 与主 App，安装后打开 `/Applications/大鱼音频效果器.app` 一次，再启动 Final Cut Pro。

安装包已完成 Developer ID 签名、Apple 公证和票据验证，大小 42,407,490 字节。

SHA256：`fe2091fd17645df2e29dda981ce3ea66da6438a54564cdf14f8b835396ff7c1b`。

源码与发行证据见 `Packaging/README.md`、`Analysis/Packaging/1.2-10/summary.json`。GitHub 会随标签提供源码归档；本次上传沿用现有正式安装包，未重新构建或追加音频/FCP 验收。
