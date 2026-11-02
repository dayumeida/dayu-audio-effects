# AudioDenoise AI 1.0.6：目标模式、恢复证据与移植结果

日期：2026-11-01，Asia/Shanghai。目标模式为本机原装 **AudioDenoise AI 1.0.6 的正常启用、默认频段算法路径**；学习模型、窗口、频段、强度与增益均恢复。工程/UI/AU/FCP 集成由主任务验证；本文记录独立 DSP 与原装运行对照。

## 目标身份与证据范围

- 原组件：`/Library/Audio/Plug-Ins/Components/AudioDenoise AI.component`。
- 主体为 arm64/x86_64 通用 Mach-O；注册 `aufx/adai/CPop`。
- 主体 SHA-256：`211a86e4ad5b9603723de40ed6c7c3638d5efcdc9022496bfe4c161919370294`。
- `rea-doctor.json` 是 REA 6.4.0 的真实诊断：无已连接 MCP 注册，Hopper/Ghidra/IDA 提供者均不可用。没有修改用户 REA 配置或安装分析引擎。
- 本文其余算法证据来自 `nm`、`otool`、资源解析、原装正常试用 AU 和独立 DSP 单元探测，**不是 REA 反编译 Evidence**。保留完整 `symbols.txt`、`disassembly-arm64.txt` 和聚焦函数 `.asm`。
- 未修改原组件、签名或授权文件。原装 AU 的许可状态保持原样。

## 恢复的原装活跃处理链

`Render` 位于 arm64 VM `0x5c20bc`；`processData` 为 `0x5c4d68`；`getLatency` 为 `0x5c4c84`；原后台音频处理函数为 `0x5c5134`。

1. 各声道进入宿主采样率环形历史；双声道先平均为单声道模型输入。
2. 每窗 `floor(Fs * 16384 / 32000)` 个宿主样本。以 r8brain 重采样到 32 kHz，恰好 16384 个 Float32 波形样本；每窗清空重采样状态，并用零输入冲刷至所需输出长度。
3. 调用原资源中的波形 U-Net。模型输入 `Input1`、输出 `Eltwise2` 均为 `[1,1,1,16384]`。这条链直接处理波形。
4. 默认三频段算法先求 `residual = inputMono - denoised`；根据 Low/Mid/High 加回残差频段，得到 `processedMono`。
5. 重采样回宿主采样率；头尾各裁 `floor(Fs * 4128 / 32000)`。相邻有效窗重叠 128 个**宿主**样本，按 `(k+1)/128` 交叉淡化。因此 hop 为 `windowFrames - 2*crop - 128`。
6. 各原声道 `out = (1 - strength/100) * dryChannel + (strength/100) * processedMono`；再乘 `10^(outputGain/20)`。

原装在首次窗口前反复复制第一宿主输入块来填 crop 历史（`Render@0x5c33c0`），因此启动声响随宿主块大小变化。移植版采用确定性的零历史，保持块大小不变性和 FCP 跳转后可重复启动。这是明确保留的行为差异。

原装 `getLatency` 用五次推理实测计时，返回 `0.512 + 128/Fs + 1.1*平均推理秒数`，并在渲染中创建后台线程、使用锁/等待。移植版固定延迟、分摊运算：

`latencyFrames = ceil(Fs * 0.64) + 2`

32/44.1/48/96 kHz 分别为 20482 / 28226 / 30722 / 61442 帧。窗口从约 383 ms 未来上下文齐备后开始，推理与重采样等阶段分摊到约 225 ms 预算内；固定延迟留出余量。资源分配前可用同一静态公式上报。

## 模型与原装资源

`Contents/Resources/left.png` 实际为编码的 ONNX 数据，原装资源解码函数位于 `0x5d10e0`。`decode_model.py` 只读原资源并在分析目录产生模型；不操作授权。模型为 37,805,550 字节，SHA-256 `c5b58a4c91a250a9829cf8c4aab6e81eaf1092d0a09048117a98dc8f8e9dcc15`。

模型包含 20 次 valid Conv、19 次 BatchNorm（epsilon 0.001）、10 次 LeakyReLU（alpha 0.2）、9 次 Swish、9 次最近邻放大与 skip concat。卷积宽度均为 9；编码首层 stride 1，其后九层 stride 2；解码放大 2 倍、卷积 stride 1。最近邻使用 `align_corners / round_prefer_floor`，须按 Float32 乘除顺序取整，不能用精确有理数替代。

最后输出 8192 个学习残差，两边各 pad 4096 后与原输入相加。原包装另留 32 个模型采样边缘余量，故每窗有效 8128 个模型域样本。

- 原模型常量：9,447,713 个参数。
- BN 融合后生产权重：9,439,997 个 Float32，37,759,988 字节。
- 每完整模型窗：617,742,432 MAC，约 1.235 GFLOP。
- `model-graph.json`、`model-shapes.json`、`DenoiseModelData.hpp` 给出全部形状、stride、skip 裁剪和权重偏移。
- `export_weights.py` 将 ONNX 常量融合 BN，生成 `dayu-denoise-weights.bin`。生产运行不依赖 Python、ONNX Runtime 或 OpenCV。

## 频段恢复与参数

原注册参数为：0 Profile（预设代理），1 Active，2 Strength，3 Output Gain，4 Low，5 Mid，6 High，7 Analyzing（状态）。实际可写 DSP 控制为 1–6；0/7 不进入控制写入。范围/默认值见 `parameters-48k.json`。

默认 `new_smallknobs_algo=1` 使用第三个分频器：构造采样率 64000、交叉频率 500 和 4000 Hz，但输入为 32 kHz，实际等效分界为 250/2000 Hz。两级 LR4（各两次二阶低通/高通）分出三个频段，低频另经 Q=0.5 的 AllPass 做相位补偿。

`processedMono = denoised + lowResidual*(1-Low/100) + midResidual*(1-Mid/100) + highResidual*(1-High/100)`

三个值均为 100 时直接使用模型输出。原装代码还含未暴露给普通面板的旧频段分支，本次目标模式为正常默认活跃分支。

LR 的 sin 系数实际为 `0.7071067932881648`（原 Q 为 Float32），而非直接用数学常量 sqrt(0.5)。DF2 状态、FMA 顺序、交替 ±1e-8 的反非正规数项均已恢复。`BandProbe.mm` 从正常加载的原组件调用独立分频器；`BandCompare.cpp` 直接调用移植类比较。三频段各 16384 点 impulse **逐样本相同**，见 `band-comparison-native.json`。这条有限单元对照不等同于整个插件任意输入 bit-exact。

## 当前可靠实现 v3.1

最终文件在本分析目录根部：

- `AudioDenoiseCore.hpp`：独立 8 地址 schema、模型资源加载、r8brain 窗口、环形缓冲、频段与混合、固定延迟、旁通、表计和波形。
- `DenoiseInference.hpp`：共享不可变权重缓存（锁只在 prepare）、全部预分配的特征/工作缓冲、64 时点 tile、按输出通道拆分、每步至多 4096 个 im2col Float32，以及 prepare 阶段的每层 CPU 成本校准。render 不读时钟。
- `DenoiseMatmul.hpp`：自有单线程 NEON 4 输出通道 × 8 时点微内核；无系统矩阵分发器、堆分配或内部线程。
- `DenoiseModelData.hpp` 与 `dayu-denoise-weights.bin`：固定形状和原模型融合权重。

`loadModel(path)` 必须在控制线程调用，失败应拒绝 AU 资源分配。随后 `prepare(rate)` 分配并预热；`reset/process/set/rampParameter/setBypass` 不分配。生产集成需将草稿 `#include "CDSPResampler.h"` 改为工程内 ThirdParty 路径。

降噪过程分成 gather/down/network/residual/up/publish，小阶段输入输出每次至多 256 个样本。各频段控制在固定窗口开始时快照；强度/输出增益和旁通在宿主音频线程处理。旁通保留同一延迟并以 5 ms 平滑切换。

使用的是 [avaneev/r8brain-free-src](https://github.com/avaneev/r8brain-free-src) commit `cb2abb9977efe2471979b380ed95daa56ab4fdb9`，ReqTransBand=2%、ReqAtten=206.91 dB、linear phase。原嵌入版本为较早版本；整链动态对照支持当前主要采样率上的数值近似，不能据此声明所有重采样组合逐位相同。

## 验证结果

1. 独立 ONNX Runtime 对照：同一 16384 点正弦输入，完整原模型 vs 最终自有推理内核，max error `2.5332e-7`、RMS error `4.8138e-8`。逐层证据保留在 `test-layer-*.f32` 与 `test-native-layer-*.f32`。
2. 原装正常试用 AU 整链对照：8 秒确定性谐波加噪声，原 AU 每块按实时速度 paced，移植版流式输出。按原 AU `ceil(latency*Fs)` 和移植版固定延迟对齐。排除首源秒（启动填充差异）后的 5 组 mono 对照如下，详情 `whole-chain-comparison.json`。

| Fs | Strength | Low/Mid/High | RMS error | max error |
|---:|---:|---|---:|---:|
| 32000 | 80 | 100/100/100 | 9.858e-08 | 4.247e-07 |
| 32000 | 100 | 0/100/100 | 1.377e-07 | 5.960e-07 |
| 44100 | 80 | 100/100/100 | 1.445e-07 | 3.092e-06 |
| 48000 | 100 | 100/100/100 | 1.757e-07 | 3.416e-06 |
| 96000 | 80 | 100/100/100 | 1.688e-07 | 4.932e-06 |

3. `CoreValidation.cpp`：32/44.1/48/96 kHz × block 1/17/64/128/512/16384，24 个新鲜 render std::thread；stereo、参数 ramp、NaN/Inf。每组 2 秒后 reset 再播放。malloc_logger 可用，所有 render 分配计数 0，块大小差异 0，reset 重放差异 0，全部输出有限。见 `core-validation-final.jsonl`。
4. 相同矩阵通过 ASan/UBSan，退出 0，Sanitizer 日志为空，见 `core-validation-asan.jsonl/log`。最终原分频器逐样本对照另见 `band-comparison-native.json`。

这些数据不是任意输入整插件 bit-exact、语音质量普遍提升，或 FCP 时间线性能的证明。整链原装对照为 mono；双声道稳定性在本机 DSP 测试中覆盖，原装完整 stereo 参数矩阵仍可扩展。

## 性能试验与明确淘汰的路径

普通 cblas_sgemm 即便单线程、完整图预热，仍在 render 打包时调用 malloc_type_posix_memalign。vDSP_mmul 与逐列 GEMV 也有重复分配。`allocation-trace.txt` 及 `candidates/` 保留调用栈和数据。

BNNSMatMul 显式工作区达到约 9.7 ms/窗，但单输出最终层仍有隐藏打包分配；用 NEON 替换最终层后，**新鲜线程首次仍经 BLASStateRetain/TLV 发生一次 calloc**。故该路径未用于最终可靠实现。自定义 BNNS allocator 未覆盖内部那条路径。

最终选择自有纯 NEON。M1 Max 本轮单次 10 窗稳态测量约 32.7 ms/窗（3697 个有限步骤）；这是具体机器和负载下的均值。典型 48 kHz 每窗推进约 251.3 ms，可据此评估单实例 CPU 成本，但离线吞吐与 FCP 波形重建耗时不同。各块的平均/最大耗时见验证 JSONL；更小块的 deadline 与调度最坏情况不能由均值保证。

**FCP 实机验收由主任务负责：**长素材波形、连续播放、频繁跳转、多实例压力、界面菜单与保存恢复。本文没有测量 FCP 44 分钟素材波形重建秒数；8–384 kHz 的数值协商能力也不等同于所有采样率/块大小均满足硬实时预算。

## UI

`original-ui.png` 为正常原装 Cocoa AU 离屏截图，像素 800×1072，逻辑尺寸 400×536。`ui-capture.log` 保留每个真实控件的 AppKit frame/动作/显示值。UI 松散 TIFF 来自原 `AudioDenoiseAIView.bundle`。原页面为顶部品牌/开关、中部输出滑杆/大强度钮/电平表/波形/保存载入重置帮助，底部三频段小钮；主任务据此在项目内实现中文菜单与大鱼品牌。

## 剩余边界

- 启动历史明确改为确定性零填充；固定 640 ms 延迟取代原硬件相关报告值。
- 原装正常默认路径与实际模型已移植；隐藏实验频段分支不属于本目标模式。
- 有限模型、分频器、整链输入对照均已记录；没有全输入等价证明。
- 权重在同一进程多实例间共享，DSP 历史各实例独立；不同宿主进程仍需各自加载。
- 最终源码和资源哈希见 `final-summary.json`，FCP 观察结果需另行记录。
