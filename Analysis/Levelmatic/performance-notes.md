# Levelmatic 1.0.8 ARM64：延迟、实时性能与 limiter 静态证据

分析对象：`/Library/Audio/Plug-Ins/Components/Levelmatic.component/Contents/MacOS/Levelmatic`。身份 SHA-256 见同目录 `sha256.txt`。静态部分依据 macOS `nm` / `otool` 的 arm64 符号和反汇编；这些是普通 shell 的证据，不是 REA Evidence。第 5 节另附经主代理授权的只读 AUv2 动态 probe。未修改原版安装或绕过授权。

## 1. 对宿主报告的延迟约 7.5 秒（高置信度静态观察）

`Levelmatic::getLatency()` (`0x298c`)：

- `0x29a4` 读输出流 sampleRate。
- `0x29a8..0x29b8` 计算 `sampleRate * 5 * 0.00048828125`，后一个 double 的位模式为 `0x3f40000000000000`，即 `1 / 2048`。
- `0x29bc` 向正无穷取整；`0x29c0` 左移 11；`0x29c8` 除 sampleRate。

所以内部值为 `ceil(sampleRate * 5 / 2048) * 2048 / sampleRate` 秒。

AU 对外虚方法 `Levelmatic::GetLatency()` (`0x5e30`) 在 `0x5e38` 调上述函数，`0x5e3c..0x5e40` 再乘 `1.5`。

| sampleRate | 内部 getLatency | AU GetLatency |
|---|---:|---:|
| 44100 | 5.015510204 s | 7.523265306 s |
| 48000 | 5.034666667 s | 7.552000000 s |
| 96000 | 5.013333333 s | 7.520000000 s |

`GetTailTime()` (`0x5e4c`) 经 vtable 转发；本次未进一步证明该 vtable 槽最终指向哪一实现。7.5 秒为此构建代码路径的延迟返回值；随后第 5 节的 AUv2 probe 已验证 48kHz 的实际属性与合成信号首次输出。

推断：如此大的补偿/预读窗口会显著影响拖动、跳转后的恢复体验；不能仅凭静态分析断言这是用户时间线卡顿的唯一原因。

## 2. Render 内部存在互斥锁、分配、线程初始化

`Levelmatic::Render()` (`0x3760`) 中有直接 `std::mutex::lock` 调用，例如 `0x4354`, `0x45a8`, `0x4660`；有对应 unlock。`0x45a8..0x4654` 临界区涉及输入/输出电平历史的 RingBuffer 推入和裁剪。`0x4660..0x46cc` 临界区更新电平及时间戳。它们会与工作线程共享状态。

初始化/尺寸改变的条件分支中可见 `new`、vector resize、RingBuffer allocate：例如 `0x3b10`, `0x3b40`, `0x3b74`, `0x3be8`, `0x3c18`, `0x3dd4`, `0x3fe4`, `0x4018`。这说明这些动作发生在 Render 的可达路径，而不是证明每个 render block 都执行分配。

Render 在检查保存的 thread 指针为空后创建线程：

- `0x4058..0x40b8`：`pthread_create` (`0x40b0`)，worker 位于 `0x7008`，负责 `leveler()`。
- `0x40bc..0x411c`：`pthread_create` (`0x4114`)，worker 位于 `0x70f4`，负责 `limiter()`。
- `0x46d0..0x4734`：`pthread_create` (`0x4728`)，worker 位于 `0x71d4`，负责电平/状态超时更新。

这是按需初始化，不是每个 block 新建三个线程。Render 函数范围内未发现 `join()` 直接调用；全局存在 join 符号不能说明 Render 调用它。

工作线程行为：

- leveler worker (`0x7040..0x7070`) 查 RingBuffer 数据量，不够时 `usleep(10000)` (`0x7058..0x705c`)，否则调用 `leveler()` (`0x7068`)。
- limiter worker (`0x7130..0x7184`) 查输出空闲和输入数据量，不足时 `usleep(10000)` (`0x7148`, `0x716c`)，够时调用 `limiter()` (`0x717c`)。
- 电平/状态 worker (`0x7260..0x72f4`) 用两个 mutex 读写状态，并 `usleep(100000)` (`0x72e4..0x72ec`)。

推断：这套锁、轮询和跨线程缓冲架构带来调度开销及延迟不确定性。尚未实测锁争用时间，也未验证其线程优先级/Audio Workgroup 注册情况。

## 3. limiter 的处理链

`Levelmatic::limiter(unsigned)` (`0x58a8`) 先从各声道 RingBuffer 读入并 pop，传入共同 mutex (`0x5944..0x596c`)；按每个采样点求所有声道 `max(abs(sample))` (`0x59f4..0x5a10`)，因此所有声道共享检测信号，保留立体声联动。

包装层在 `0x5a20..0x5a3c` 调 `LookaheadLimiter::process`。传入参数的静态常量包括：

- 第一个 float：`0.2`（`__TEXT,__const + 0x164`）。
- 第二个 float：`1.2`（`__TEXT,__const + 0x16c`）。
- 第三个 float：实例字段 `+0x254`，在 Render 的 `0x3a6c..0x3a94` 由参数 3 经 dB 转线性计算。
- bool：true。

`LookaheadLimiter` 构造 (`0x6258`) 为每个声道和检测信号分配 `N = int(sampleRate * 0.2)` 长度延迟环，为两级平滑分配 `N/2` 环。

`LookaheadLimiter::process` (`0x5ab4`) 的每样本路径：

1. `0x5b20..0x5b44` 更新检测信号的滑动平方和；保存旧声道延迟样本并写入当前样本 (`0x5bb0..0x5bc4`)。
2. bool=true 走峰值模式：`0x5bdc..0x5c6c` 用缓存峰值/倒计时维护窗口峰值。新峰值超出缓存就更新并重置倒计时；倒计时失效时 `0x5c40..0x5c5c` 全扫描检测信号环。bool=false 的另一个分支可计算 RMS，但包装层传 true。
3. `0x5cb0..0x5cdc` 计算 reduction：`max(0, 1 - 1 / (peak * 1.2))`，再除 `N/2`。
4. `0x5ce0..0x5d20` 用两个长度 `N/2` 的运行和环做两级移动平均，平滑 reduction。
5. `0x5d24..0x5d5c` 释放包络：`reduction = max(smoothedReduction, previousReduction * exp(-1 / (sampleRate * releaseParam * 0.5)), 0)`。其中 releaseParam 为传入第一个 float 0.2，所以指数系数等价于约 100ms 时间常数。
6. `0x5d70..0x5db4` 输出共同延迟的声道样本：`delayed * (1 - reduction) * outputGain`。

变量名及语义为人工恢复，不是原版源码。该方法没有在这段指令范围内出现最终 hard clip；峰值上限及输出增益的完整映射还需结合原版参数定义和其他处理层核对。

## 4. 最明确的成本：limiter 每个样本构造临时 vector

在每样本循环 `0x5b20..0x5dfc` 内：

- `0x5b68..0x5b70` 调 `vector<float>(channelCount, 0)` 构造临时数组。
- `0x5bb0..0x5bbc` 把延迟读出的各声道样本写进该数组。
- `0x5d70..0x5db4` 使用数组输出。
- `0x5ddc..0x5de4` 释放该数组。
- `0x5dfc` 回到下一个样本。

这构成每采样点一次堆分配和释放；48kHz 下满速处理一秒音频即约 48000 对 allocation/deallocation/实例，另有每样本 `exp` (`0x5d40`) 与峰值窗口失效时的 O(N) 全扫描。它发生在 limiter 工作线程，不能描述为 audio callback 中每样本直接 malloc，但仍会给宿主进程带来堆和调度压力。

优化建议（新实现设计，不是原版观察）：延迟/检测/峰值队列在资源分配阶段一次分配；临时声道值用固定大小栈数组；固定指数系数只在采样率/参数改变时计算；滑动峰值用单调队列摊还 O(1)；实时回调单线程处理、禁止等待/互斥锁/堆分配；短前瞻替换多秒分段架构。是否保留原版完整离线分段行为是产品选择，与小延迟目标存在取舍。


## 5. 只读 AUv2 动态 probe（已完成）

源码：`Tests/LevelmaticReferenceProbe.mm`；参数/属性结果：`reference-query.json`；35 秒合成信号结果：`reference-probe.json`。每个子进程由 Python `subprocess.run(..., timeout=30)` 限时，无扬声器输出；实例化后正常 Uninitialize/Dispose；没有请求原版自定义 UI、没有授权修改。

48kHz、双声道、512 frames/block：

- Instantiate、输入/输出格式设置、Initialize、ParameterList、Render、Dispose 均成功。
- `kAudioUnitProperty_Latency` 读取为 **7.552 秒**。
- 正弦输入从 frame 1 开始非零；输出第一次幅度 >1e-7 出现在 frame **362497**，即 **7.552020833 秒**，与 362496-frame 延迟相符。
- `kAudioUnitProperty_OfflineRender` 返回 -10879（不支持该 property），原版写 stderr `Unknown property 37`。后续通过 AU render callback 手动拉取的内存渲染仍成功。
- 枚举参数：Profile(id0)、Active(id1，当前1)、Strength(id2，0…100，默认/当前80)、Target(id3，-24…0，默认/当前-12)、Analyzing(id4，0…100)。
- 合成输入：0–10秒 -36dBFS RMS 正弦；10–20秒 -12dBFS RMS；20–25秒数字静音；25–35秒 -30dBFS RMS。频率997Hz，双声道一致。
- 35秒输入共1680000 frames 成功处理；本次整段子进程约1.234秒。此值包含原版工作线程/进程创建等，未做稳定统计、与新实现同条件基准对比或宿主实时调度测试，不可据此声称实时时间线性能。
- 输出稳定窗口：8–9秒约-21.791dBFS RMS；11/13/16秒约-21.149dBFS；18–24秒约-19.77…-19.85dBFS；28–31秒完全静音；33–34秒约-19.77…-19.79dBFS。加入7.552秒延迟对齐后，原始24dB的响度差被明显缩小，证实在做动态均衡。

当前为原版在此机器已有状态下的默认参数，试用/水印可能影响输出。没有得到授权状态、无水印标定或多 Profile 的全量测试，因此结果用于核对延迟与总体 leveling 行为，不能作为精确声音一致性的金标准，也不能仅凭该结果认定默认 Target 是最终输出 RMS 目标。

复现编译：

```sh
xcrun clang++ -std=c++17 -O2 -Wno-multichar Tests/LevelmaticReferenceProbe.mm -framework AudioToolbox -framework CoreFoundation -o /tmp/dayu-levelmatic-reference-probe
```

执行应继续通过30秒超时包装调用 `/tmp/dayu-levelmatic-reference-probe`（查询）或加 `--render`（35秒内存信号）。程序把原版 stdout 日志转到 stderr，JSON 保留原 stdout 通道。


## 6. Render 数据等待可长达约 3 秒（静态已确认）

`Render` 的 `0x42f0..0x4300` 调 `RingBuffer::readFront(output, bytes, 3, mutex)`。`readFront` (`0x14480`) 并非单纯 memcpy：

- `0x144b8..0x144c0` 算 `iterations = (waitArgument * 1000) | 1`，所以参数3时为3001。
- `0x144c4..0x144d4` 读可用数据量，不足则继续。
- `0x144e0..0x144f0` 调 `usleep(1000)`，递减iterations，再回查。
- 数据足够跳出等待；持续不足时约3001次1ms睡眠后报空缓冲并返回false。

因此音频 Render 回调本身存在可达的多秒阻塞路径。数据供应正常时不发生睡眠，不能说每个block都卡3秒；但拖动、跳转、后台线程滞后或缓冲不足时，这种路径是比“用了旧算法”更具体的卡顿机制证据。`readFront` 随后在 `0x14588` 对传入mutex加锁并拷贝请求字节。

## 7. limiter 包装层精确尺寸与尾部复用

令 `fs = uint(sampleRate)`，原版通常 block<=2048 时 chunk=2048（实际初始化路径 `max(hostFrameCount,2048)`）：

```text
W50 = int(double(fs) * .05)
N = int(float(fs) * .2f)
P = int(float(fs) * .2f + float(8 * W50))
workLength = chunk + P
extractOffset = (P - 4 * W50) / 2
```

48kHz：N=9600，P=28800，extractOffset=9600，workLength=30848。

每次 `Levelmatic::limiter` 只用 readFront 把 chunk 个新样本写进 `audio[c][0:chunk]`，其余长尾没有清零；`peaks` 全长清零后按所有声道/所有 workLength 采样重新求 max(abs)，内核处理完整长数组，再从 `audio[c][extractOffset:extractOffset+chunk]` 取输出。内核原地处理过的数组长尾会保留到下一次调用；内核环状态也没有在每次wrapper调用时重置。上述是对指令读写范围的恢复，不是补零假设。

原版 workLength 随初始化时 host block 大小变化。新实现固定按 prepare 的 maxFrames 选择 `max(maxFrames,2048)`，以保证任意随后host block拼接稳定。对于原版运行时改变内部chunk尺寸、不同构建或特殊非标准采样率，未做逐样本动态核对。

## 8. 可直接移植的峰值模式数学伪代码与优化实现

已写入 `大鱼音频效果器Extension/DSP/ReferenceLimiter.hpp`，类为 `dayu::ReferenceLimiter`。初始化所有数组为0：

```text
channelDelay[channels][N]
peakRing[N]
box1[N/2], box2[N/2]
readIndex=boxIndex=0
cachedPeak=countdown=sum1=sum2=reduction=0
alpha = float(exp(-1 / double((float(fs)*.2f)*.5f)))
```

原版每样本的有效bool=true路径：

```text
p = max(abs(input channels))
peakRing[readIndex] = p
countdown -= 1
if countdown < 0:
    cachedPeak = max(peakRing)
    countdown = N
else if abs(p) > cachedPeak:
    cachedPeak = abs(p)
    countdown = N

r = cachedPeak * 1.2f
raw = (r > 1) ? 1 - 1/r : 0
new1 = raw / float(N/2)
sum1 = (sum1 + new1) - box1[boxIndex]
box1[boxIndex] = new1
new2 = sum1 / float(N/2)
sum2 = (sum2 + new2) - box2[boxIndex]
box2[boxIndex] = new2
reduction = max(sum2, max(reduction * alpha, 0))
for channel:
    old = channelDelay[channel][readIndex]
    channelDelay[channel][readIndex] = input[channel]
    output[channel] = (old * (1 - reduction)) * outputGain
readIndex = (readIndex+1) mod N
boxIndex = (boxIndex+1) mod (N/2)
```

`outputGain = float(10^((double(Target)+1.6)/20))`，见 Render `0x3a6c..0x3a94`；第二个常量1.6位于 `__TEXT,__const` 的 `0x21a0c8`。

优化数学保持方式：

- 用固定容量单调队列维护真正滑动最大值，仅在原版 countdown<0 的同一时刻读取它；仍保留原版缓存峰值和N+1倒计时行为，避免简单“每样本用新窗口max”改变1个采样的包络。
- alpha 在prepare时算一次，原版每样本exp的输入恒定，因此不改变数值系数。
- 不构造原版每样本临时vector；先取每声道延迟样本再写回即可。完整wrapper的工作数组、延迟、队列和双盒环均在prepare分配。
- 峰值分支不用的rolling RMS平方和未计算；它不参与bool=true的输出链。
- 原版授权状态不属于音量算法：Render `0x4488` 查 `+0x20d`，为false时 `0x44a0` 调 `AudioWatermark::mixWaterMark`。新代码不包含原版水印、注册或其授权模块。

接口：`prepare(sr,capacityChannels,maxFrames)`，`reset()`，`process(...,channels,frames,targetDB)` 接任意mono/stereo planar帧数；capacityChannels=2可处理mono。流式累计初次引入 `chunkFrames()-1` 帧等待，可由 `streamingLatencyFrames()` 查询，外层AU需要计入/抵消该延迟。`processReadyChunk` 给已有完整chunk的调度器使用，没有额外累计等待；二者不能在不reset的同一实例中混用。

验证：`Tests/ReferenceLimiterTests.cpp` 使用保留原版全扫描和每样本exp的独立朴素数学转录做对照，44100/48000/96000、mono/stereo、14个随机/脉冲/静音chunk；逐样本最大误差0。任意1…777帧拼接加原地处理与chunk输出完全一致；processing阶段自定义C++ `new`计数0。结果见 `limiter-equivalence.json`。这是“静态数学转录对照”，不是无试用水印的原版二进制逐样本等价证明。

## 9. Declip/OpenCV 是否在已追踪链中运行

Render `0x3b04..0x3b2c` 在对象 `+0x588` 为空时分配并调用Declip构造；但已追踪的 Render/leveler/limiter 不存在 `Declip::declip` 调用。整份arm64反汇编的直接分支搜索找到ctor、Declip自身内部对apply_window/sliding_bark的调用，未找到外部对 `Declip::declip` 的直接BL。

所以只能确认“保留并初始化Declip/OpenCV代码，未在已追踪主要音频链发现declip处理调用”，不能把符号存在说成正在做FFT/去削波，也不能据此把OpenCV归为时间线卡顿原因。未覆盖任意间接函数指针、其他架构和未触发Profile分支。
