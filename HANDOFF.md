# 大鱼音频效果器开发交接

## 2026-11-02 默认目标 -3 dB 与构建 10 发行

用户要求将当前自动电平默认目标设为 -3，重新打包 APP 并推送文章。参考和低延迟两种电平器默认目标均改为 -3 dB；低延迟原上限 -9 dB 同步扩展至 -3 dB，AU 参数树及刻度一致。新建/重置生效，既有文档和预设保留已保存参数。除默认值和低延迟上限外，DSP 处理代码未改。原默认值相关既有检查同步更新，两个核心的分块、旁通、重置和渲染分配检查通过；未追加 FCP/试听验收。

最新正式版为 **1.2（10）**，四 AU 组件版本 65545，包含当前时间线预览及离线输出功能。正式 APP：`Outputs/Distribution/1.2-10/App/大鱼音频效果器.app`；安装包：`Outputs/Distribution/1.2-10/大鱼音频效果器安装包-1.2.pkg`。APP 和 PKG 已完成 Developer ID 签名、Apple 公证 Accepted、票据及 Gatekeeper 核验，包内 41 个文件与发行 APP 逐字节相同。发行证据见 `Analysis/Packaging/1.2-10/summary.json`；发文核验见 `Publication/2026-11-02/发布记录.md`。更新仍使用原文章 ID15770：https://dayu.media/15770/ 。原售价 50 元、会员免费及封面沿用。

未覆盖或安装到当前运行的开发 APP。旧发行包及开发成品保持原样；打包工程已切换至构建 10，构建 9 工程另存 `Packaging/大鱼音频效果器-1.2-build9.pkgforge`。修改前备份 `.codex-backups/before-default-minus3-build10-20261102.tar.gz`。下方 11 月 1 日记录是当时的状态，以本节的新版本和默认值为准。


## 2026-11-01 时间线式波形交互

用户要求波形像剪辑时间线：放大、缩小、适配窗口、点选位置播放。已在同一开发 App 接入整段原始波形索引、共享时间尺和绝对时间游标、横向滚动/总览导航、鼠标点播/拖动游标、Option 拖动平移、Command/Option 滚轮与捏合缩放、+/-/F/空格快捷键、毫秒时间码输入。主窗口右侧随窗口宽度扩展。处理效果按需分段预览，已生成范围保留波形，未生成区间不伪装成已处理；原音和效果切换保持绝对位置。

新增 `Common/Audio/AudioTimeline.swift`（显示范围、时间码、整段多分辨率波形索引）、`WaveformTimelineView.swift`（原生 AppKit 事件与无障碍、SwiftUI 绘制/控件）。`MediaPreviewModel` 负责绝对定位、取消过期请求、暂停保留游标、预读下一段并按音频设备时钟调度播放。跨 12 秒处理缓冲区会继续播放，不再作为试听结束点；只点击输出按钮才生成完整副本的规则保持。

验证入口：`bash Tests/run-preview-workflow-tests.sh`，原有 9 项 + 时间线 15 项自动检查通过；结果为 `preview-workflow-report.json` 和 `timeline-preview-report.json`，后者另含 3 项原生 UI 复核记录。最终 Release 与严格签名验证通过。渲染任务自行提交结果及结束忙碌状态，取消瞬时 UI 任务不会使有效预览停在更新中，旧代次隔离。最终主 App 已打开，原参数与原 MP3 恢复到 06:36.465、128 倍视图，暂停/待输出，三份同前缀源文件及已有副本的名称、大小、修改时间不变。源码备份 `.codex-backups/before-timeline-preview-20261101.tar.gz`。更新前用户最新参数备份 `/private/tmp/dayu-user-before-timeline.json`，参考电平目标约 -3.8608685、强度 80，素材仍为 `261027_005.MP3`，位置 396.4649206349206 秒（06:36）。最终恢复此最新状态，勿用早先 -12 的备份覆盖它。构建前必须从 App 菜单正常退出并确认进程结束，再覆盖 `Outputs/OfflineProcessing`；不要只假定发送 ⌘Q 就已退出。

## 2026-11-01 主 APP 离线处理增量

用户新增要求：主 APP 拖放音频后使用现有算法，在原目录输出处理副本；同时支持视频自动分离音轨、处理并合并为视频副本，视频不解码、不重编码，音轨沿用原格式参数。已实现，开发成品为 `Outputs/OfflineProcessing/大鱼音频效果器.app`；这是新功能开发构建，既有发行版 1.2（9）安装包与发布文章尚未更新。未在 FCP 进行本轮新功能验收，也未替换仍由 FCP 加载的 `Outputs/MultiEffect`。

用户随后纠正交互：**拖入只载入素材，先调参、预览波形和试听，再点击输出；不能拖入即输出。** 当前已调整为此流程。`AudioUnitHostModel.importMedia` 仅调用 `OfflineProcessingModel.stage` 并加载预览。`MediaPreviewRenderer` / `MediaPreviewModel` / `MediaPreviewView` 负责最多 12 秒片段的前后波形、原音/处理效果试听、长素材片段选择及视频音轨选择，前后各保留至多 10 秒音频上下文。参数变动后自动防抖更新预览，取消过期任务。只有 `exportMedia()` 可启动完整输出：点击时再次读取参数，要求与当前有效预览一致，然后按该快照处理全部导入文件。导入不请求原目录写权限，不产生相邻副本。

完整输出仍由 `OfflineProcessingModel` 串行调度独立 AUv3，支持取消与错误隔离。音频输出 Float32 WAV/超大 CAF，补偿固定延迟，帧数与输入一致；视频经原音轨时间范围分析、解码到临时 CAF、同一 AU 算法处理、按原编码重编码音轨，再对所有非音频轨道原样复制压缩采样。详见 `Analysis/OfflineProcessing/实现与验证.md`、原输出管线 `report.json` 及新交互 `preview-workflow-report.json`。本次预览改造前备份为 `.codex-backups/before-preview-workflow-20261101.tar.gz`。用户当前参考电平器参数已临时备份至 `/private/tmp/dayu-user-parameters-before-preview.json`，并在最终界面恢复；原素材为 `/Volumes/DayuMedia 4TB/2026.10.27/261027_005.MP3`。

`Shared/EffectKind.swift` 仅增加 `nonisolated` 类型标记供后台读取不可变组件配置；Extension/DSP 及 AU 算法未改。新功能前源文件备份为 `.codex-backups/before-offline-audio-20261101.tar.gz`。后续构建或更新 `Outputs/OfflineProcessing` 前先正常退出该开发 App，避免覆盖已加载扩展；不要为这个主 APP 功能清空 AU 缓存或操作现有 FCP 工程。

更新：2026-11-01。本轮已完成四组件架构及两个新效果的算法/UI接入；用户最终确认“验收通过不用测了”，已停止追加测试。用户明确选择 **ERA5 De-Clipper 5.4.00**，ERA4不是目标。先前交接已归档到 `.codex-backups/HANDOFF-before-multi-effect.md`，其中“降噪/修复未实现”等描述只代表旧状态。

## 当前入口

- 工程根：`/Volumes/DayuMedia 4TB/大鱼音频插件开发/大鱼音频效果器`。
- 最新发行成品：`Outputs/Distribution/1.2-9/App/大鱼音频效果器.app`，**1.2（9）**，组件版本65544，含新图标、发行签名与公证。原开发验收成品 `Outputs/MultiEffect/大鱼音频效果器.app` 为1.2（8）、组件版本65543，保持原样。不要用 Outputs/Release、Debug、FCPResponse 判断本轮功能。
- 文章已发布：https://dayu.media/15770/ ，整包50元、会员免费；文章ID15770、安装包附件15771、封面15772。核验及素材见 `Publication/2026-11-01/发布记录.md`，后续修改沿用同一文章ID。
- 一个主App、一个AUv3扩展、四个独立AudioComponents；主App可切换、独立缓存各效果状态。中文菜单和两个新中文面板均已接入。
- App ID `media.dayu.audio.leveler`；扩展ID `media.dayu.audio.leveler.Extension`，未改旧身份。
- Xcode项目内部文件叫 `大鱼音频效果器.xcodeproj/project.xcproj`，不是传统pbxproj。当前可构建，不要误判损坏。
- 验收平台：Apple Silicon / arm64、macOS14+；本机Xcode27.2。iOS/visionOS尚未验收。
- 此目录不是Git仓库；未找到适用AGENTS.md。改造前完整备份：`.codex-backups/before-multi-effect-20261101.tar.gz`。

## 组件、延迟、使用定位

四项共同为类型 `aufx`、厂商 `Dayu`；mono/stereo、Float32非交错，宿主最大块1–16384。

| FCP名称 | subtype | 48kHz固定延迟 | 支持率 | 定位 |
|---|---|---:|---|---|
| 大鱼自动电平 | dylv | 362496帧 / 7.552s | 8–384kHz | 原版长窗口参考，兼容旧项目 |
| 大鱼自动电平·低延迟 | dyll | 240帧 / 5ms | 8–384kHz | 因果电平器，日常剪辑；主App默认 |
| 大鱼智能降噪 | dydn | 30722帧 / 640.04167ms | 8–384kHz | AudioDenoise AI 1.0.6 模型及混合处理链 |
| 大鱼破音修复 | dycr | 7871帧 / 163.97917ms | 16–384kHz | ERA5 5.4.00检测、LPC双向修复及限制器 |

降噪重点验证32/44.1/48/96kHz；修复重点验证44.1/48/96kHz并做16/384k边界。支持范围不表示所有采样率、所有负载均有硬实时保证。修复44.1k延迟7232帧，96k15744帧。高质量复杂削波，尤其96kHz，应预渲染；不能笼统称高质量实时通过。

## 架构与新增效果的方法

`Shared/EffectKind.swift` 同时属于App和Extension；与 `Extension/DSP/EffectKind.hpp` 明确映射四种subtype。未知type/manufacturer/subtype初始化失败，不落入参考电平器。C++ kernel用variant只持有活动核心，默认值从对应Core取得。参数、延迟、采样率与界面均按kind分发。

运行链：Info.plist → AudioUnitViewController工厂 → AUAudioUnit → opaque AUProcessHelper → native ProcessHelperImpl → DSPKernel → Core。参数树不依赖UI。

关键文件（相对根）：

| 文件 | 用途 |
|---|---|
| Shared/EffectKind.swift | 组件身份、中文名称、状态key、最低采样率 |
| 大鱼音频效果器/Model/AudioUnitHostModel.swift | 主App选择、取消过期加载、每效果状态缓存 |
| 大鱼音频效果器/Common/Audio/SimplePlayEngine.swift | 切换前停播、断开节点、重连、中文错误 |
| 大鱼音频效果器Extension/Common/Audio Unit/_______ExtensionAudioUnit.swift | 参数树、总线协商、提前上报latency、状态 |
| 大鱼音频效果器Extension/Common/DSP/_______ExtensionAUProcessHelper.hpp | Swift可见opaque稳定引用 |
| 大鱼音频效果器Extension/Common/DSP/AUProcessHelper.mm | native稳定堆对象、事件、pull、seek、render |
| 大鱼音频效果器Extension/DSP/_______ExtensionDSPKernel.hpp | 四核心路由、原子参数、表计与波形 |
| 大鱼音频效果器Extension/UI/DayuEffectView.swift | 穷举界面路由 |
| 大鱼音频效果器Extension/UI/DenoiseMainView.swift | 降噪400×536参考布局、强度、输出、三频段、波形 |
| 大鱼音频效果器Extension/UI/DeclipMainView.swift | 修复300×420参考布局、类型、品质、A/B、增益、开关 |
| 大鱼音频效果器Extension/UI/EffectPanelControls.swift | 共享控件、中文预设存取 |

不要把复杂FFT/网络模板实现重新内联到Swift可见helper头；曾造成Swift C++ interop模板全局析构链接错误。render中的pull block参数须保持 `__unsafe_unretained`；强引用曾触发新音频线程第一次ObjC Block类初始化分配。同步调用的block生命周期由宿主保证。

## 已有电平器兼容性

dylv/dyll身份、参数地址0–6、默认值、旧JSON及无tag状态解释保持。EffectFactoryTests分别2400个不规则块与旧核心memcmp一致。参考LevelerCore SHA256仍为：

`1eec62215c7b8e28cf532a02fbe241b566659dcf86d6bf926887bee196b0f134`

参考版是Levelmatic1.0.8的约5秒窗口、两遍分段归一化、17倍增益上限、8点平滑、Hamming OLA、原版限制器和长尾反馈。旧12组参数矩阵420组逐秒RMS/峰值达到报告精度，不是任意输入bit-exact证明。低延迟版是300ms过去RMS、10ms控制、快降慢升及5ms前瞻的独立因果算法，两者不能静默替换。

## 降噪恢复与证据边界

目标 `/Library/Audio/Plug-Ins/Components/AudioDenoise AI.component`，1.0.6，二进制SHA256 `211a86e4ad5b9603723de40ed6c7c3638d5efcdc9022496bfe4c161919370294`。

已恢复嵌入模型、20层卷积raw-waveform U-Net、BN、16384帧@32k网络窗口、双侧4128裁切、128点交叉淡化、重采样、三频段残差及强度/增益混合；不是STFT噪声门。原装立体声平均后进单声道网络，再与各原声道混合。生产为纯NEON预分配矩阵运算，按工作量分stage执行。SGEMM/BNNS候选的隐藏malloc/TLS分配未带入生产。

模型文件：`Extension/UI/Resources/dayu-denoise-weights.bin`（约37.8MB，SHA256 `d76d1ec54a541328438e50fb81197eb0fa4630f9cdad14b693363d285ce323d6`）。只读权重按路径共享，加载/缓存锁仅在prepare；缺失模型拒绝分配，不能偷偷旁通。

重采样源码 `DSP/ThirdParty/r8brain` 来自官方 avaneev/r8brain-free-src commit cb2abb9977efe2471979b380ed95daa56ab4fdb9，保留LICENSE，使用fft4g头实现。所选配置已验证，不能宣称所有采样率逐bit等同原装的嵌入版本。

为FCP调度，原装动态延迟、worker等待改为固定 `ceil(Fs×0.64)+2` 帧。原版启动会重复第一宿主块，生产采用零历史，保证分块和跳转确定性。启动部分有明确差异。五组原装正常试用AU稳定区间对照（排除首个源秒、按各自延迟对齐）：RMS差9.86e-8–1.76e-7，最大差4.25e-7–4.93e-6；三频段脉冲已测逐样本一致。无任意输入完全bit-exact承诺。

完整证据：`Analysis/AudioDenoiseAI/report.md`、`whole-chain-comparison.json`、`final-summary.json`。final v3.1分析核心hash与生产的include/comment有路径差异；生产manifest另记实际hash。

## ERA5修复恢复与证据边界

用户选择ERA5，不再参照ERA4声音。目标 `/Library/Audio/Plug-Ins/Components/ERA5_DeClipperFxFactory.component`，5.4.00，二进制SHA256 `270172733d583f2023436baa5e6c5dc2c87342a88f1cbe8f5026e63fbaa910f5`。

恢复直方图阈值检测、两类型区域、Burg LPC（标准100阶/高质量150阶）、双向外推、Bessel样条与原版立体声联动3ms限制器。原装48k延迟5368帧，生产增加一hop2503帧，用确定性工作单元分摊高峰运算，总延迟7871帧；没有worker锁和等待。

原装存在残差数组越界读取：150个double的缓冲被读到435/870乃至相邻声道；部分长输入同一原装进程间输出不确定。生产只使用有效激励，后续零激励作纯AR预测，修复UB，不复制堆布局偶然值。这意味着不能宣称所有输入四模式都逐样本等同原装；安全同步参考与生产调度路径已测四模式逐样本一致。七个生产头与 `Analysis/DeClipper/final-header-manifest.json` 完全一致。

用户本次WAV为5.65秒、48k双声道24bit、271200帧，路径：
`/Users/dayu/Movies/FCPX千问识音交接/incoming-qwen-share-1793470011166-1/大鱼多插件长素材验证-011166-1.wav`

它不是44分钟MP3。此真实WAV四模式原装正常AU与移植核心各542400个Float32样本完全一致；实际AUv3默认模式也与核心逐样本一致。检测/修复实际触发，默认限制器压回重建峰。统一RMS对照后用户仍认为无效，并确认“原版就没啥效果”。因此本例是忠实移植对照通过、主观修复改善有限；**不能写成素材修复成功**。没有干净真值，不能断言失真一定来自ADC或AAC。不要擅自加入另一套增强算法或改变默认值。

见 `Analysis/DeClipper/UserClip/USER_CLIP_FINDINGS.md`；试听在 `Outputs/破音素材试听/`，原文件未改。

## 参数、预设、文档状态

AU fullState/fullStateForDocument加 `dayuEffectKind`；拒绝其他已标记效果的状态，在调用super前检查。无tag旧电平器文档兼容。只恢复有限的可写参数。

- 原两电平器：地址0–6不变，state key `dayuLevelerParameters`，原JSON `format=dayu-leveler` / mode=reference或low-latency；缺mode视为reference。
- 降噪：地址1active默认1、2strength80、3outputGain0(-24..24)、4low100、5mid100、6high100、7analyzing只读。0是内部保留位置，不创建AU参数。
- 修复：0quality0(标准)、1active1、2processingType0(类型一)、3outputGain0(-30..5)、4declip1。
- 新效果预设：`format=dayu-effect`、version1、effect=audio-denoise-ai或era5-declipper；不冒称原厂私有预设兼容。A/B是当前编辑器会话参数槽。

## 实时与FCP约束

渲染不做文件IO、模型加载、堆分配、互斥锁、sleep、创建线程或GPU等待。prepare分配全部资源；参数和表计原子化，UI10Hz读。资源分配前按格式上报正确固定latency；修复<16kHz在总线协商时拒绝，不等到allocate才失败（AUVal曾因此失败，现已修正）。

有效sampleTime不连续则reset；无效时间戳按连续计数回退。旁通保留延迟；切换参数不临时改变latency。新线程malloc_logger带正向控制，真实native helper的32/128/512/16384帧测试两新效果C和C++分配都为0。早期interpose不完整的报告不作零分配证据。

FCP测试使用独立资源库 `Outputs/FCPValidation/大鱼多插件验证.fcpbundle`，项目“大鱼多插件长素材验证”，48kHz，原长音频为44:02.73的44.1k MP3。用户在末尾追加了短视频、分离音频及另一个40秒音视频片段（含降噪实例），当前测试项目44:48:22，保留其改动。用户原资源库10.27中的原项目未改。

本轮FCP观察与精确范围见 `Analysis/MultiEffect/验收报告.md`。最终浏览器已恢复响应，用户明确验收通过；没有待用户恢复UI的阻塞步骤。后续无需为本轮继续测量，除非用户提出新问题。UI读取效果库分类曾长时间等待；采样显示AX在枚举大量分类，隐藏效果浏览器后恢复，不能直接归因DSP。**固定音频延迟、离线p99、AUVal通过都不等于44分钟时间线波形冷重建耗时。该精确耗时尚未测得。**

不要一边运行宿主一边覆盖它已加载的App/扩展文件。验证中出现过一次停止响应，恰逢构建替换；日志有已加载bundle找不到的错误，未取得可定因的崩溃栈。需固定成品后重启宿主复核，不能把这一轮计为通过。不要全局清AU缓存/杀所有音频服务；只检查本项目PluginKit路径，必要时正常重启FCP。

## 构建与验证

在工程根目录：

```sh
xcodebuild -project '大鱼音频效果器.xcodeproj' \
  -scheme '大鱼音频效果器' -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/dayu-multi-effect \
  "CONFIGURATION_BUILD_DIR=$PWD/Outputs/MultiEffect" build
codesign --verify --deep --strict 'Outputs/MultiEffect/大鱼音频效果器.app'
Tests/run-tests.sh
xcrun swiftc -parse-as-library Tests/AUv3MultiEffectSmoke.swift -o .build-tests/AUv3MultiEffectSmoke
.build-tests/AUv3MultiEffectSmoke
auval -v aufx dylv Dayu
auval -v aufx dyll Dayu
auval -v aufx dydn Dayu
auval -v aufx dycr Dayu
```

保留 `-O3 -ffp-contract=off`，不用fast-math。关闭ENABLE_DEBUG_DYLIB和ENABLE_PREVIEWS，保留现有签名。包含vDSP的standalone/helper测试必须链接Accelerate。Tests/run-tests.sh覆盖旧核心、native helper、随机短读取、工厂、两新核心及ASan/UBSan。真实AUv3 smoke覆盖四组件默认值、分配前延迟、声音、document state与跨效果拒绝；不能只拿standalone测试代替。

最终日志与生产hash清单集中在 `Analysis/MultiEffect`。算法深层证据仍分别放 `Analysis/Levelmatic`、`Analysis/AudioDenoiseAI`、`Analysis/DeClipper`。REA本机没有可用native反编译引擎；本轮使用普通静态工具、模型解析、正常试用AU和只读运行观测，并未绕过授权，也不把普通nm/otool冒称REA原生证据。

## 发行安装包（2026-11-01）

用户另行要求用PKG工坊CLI完成发行签名与公证，随后生成图标、封面并重新打包发布，现已完成。最新可分发文件：`Outputs/Distribution/1.2-9/大鱼音频效果器安装包-1.2.pkg`。版本1.2（9），四组件版本65544；未改算法、参数或组件身份。图标与封面由内置image_gen生成，源文件和最终提示词保存在Branding及Publication目录。改动前备份为 `.codex-backups/before-branding-1.2-9.tar.gz`。

发行App位于 `Outputs/Distribution/1.2-9/App/大鱼音频效果器.app`，App/appex均为Developer ID Application签名，匹配Direct Provisioning Profile，无调试权限。App和PKG均经Apple公证并粘附票据，Gatekeeper通过；PKG使用Developer ID Installer签名。包内41个文件与发行App逐字节一致，四组件和模型完整，固定安装到Applications且不可重定位。安装包42,163,781字节，SHA256为 `0547cb1bef423a2ac8db33bdaefc2cfec9a1a8e61205216e6c4bbb51dd0a3b43`，上传后的文件哈希相同。

PKG工坊工程：`Packaging/大鱼音频效果器.pkgforge`；方法与证据见 `Packaging/README.md` 和 `Analysis/Packaging/1.2-9/发行记录.md`。原构建8工程另存 `Packaging/大鱼音频效果器-1.2-build8.pkgforge`。开发验收成品Outputs/MultiEffect保持原样。发行归档必须显式指定ARCHS=arm64和ONLY_ACTIVE_ARCH=YES；仅指定destination不足以防止Archive额外生成未验收的Intel切片。

安装前手动退出FCP与主App，安装后打开App一次再启动FCP。发行范围仍为Apple Silicon、macOS14+。未在此机执行PKG安装，没有追加音频/FCP测试。
