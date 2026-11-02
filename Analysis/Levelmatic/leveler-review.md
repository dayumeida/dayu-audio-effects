# LevelerCore 独立静态复核与原版参数矩阵对照

复核对象：`大鱼音频效果器Extension/DSP/LevelerCore.hpp`；最终源 SHA-256：`1eec62215c7b8e28cf532a02fbe241b566659dcf86d6bf926887bee196b0f134`。原版 universal binary SHA-256：`37762efa1fe8ec30cdf4e1a4e9017b355e78a1a95c19daf586fe0f8ba8c154b2`。

## 复核结论

当前默认算法在已测12种Strength/Target组合的35秒合成信号上，与已安装原版AUv2的每秒RMS和sample peak均一致到输出保留的5位小数；声明/实际首次输出延迟也一致。该结果支持主要电平算法、两遍分段、强度映射、OLA和limiter包装层恢复正确。它不等于任意音频、任意参数和Profile逐样本bit-exact证明。

## 静态链逐项核对

| 项目 | 原版ARM64证据 | 最终实现/结论 |
|---|---|---|
| 50ms RMS | `0x4f30..0x4f8c`，float平方和/除法，double加1e-8后转float，sqrtf/log10f | 流式累计相同能量；尾条件按`floor((window-1)/frame)`，保留整除时丢末bin行为 |
| Piece分段 | `0x50e8..0x5298`，初始约1s最短段；相邻有效RMS相差>=10dB才拆段 | 两次pass；保留n-2停止边界、-100dB未覆盖sentinel与原始db fallback |
| 活跃/归一化阈值 | Leveler实例字段+0xc=-36.6、+0x10=10、+0x18=-12、+0x1c=-10、+0x20=-40、+0x24=-92 | 默认参数对应；>=3个高于-40dB的bin、silent<=.95时归一化至-10…-12dB |
| Piece均方与精度 | `0x639c..0x6404` | float除法/sqrt/log恢复；零计数用有限fallback，避免内部NaN |
| 最终增益与相邻最小值 | `0x54dc..0x555c`，17倍cap、单次前向相邻min | 默认17倍、-92门槛、邻点min均一致 |
| 8tap平滑 | `0x5608..0x56a8`，常量来自`0x21a140` | `.1183,.1239,.1279,.1299,.1299,.1279,.1239,.1183`位模式、方向与边界已核对 |
| 样本插值 | `0x5730..0x5754`，double差值/步长再转float | 已恢复double插值 |
| Strength法则 | `0x39e0..0x3afc`、`0x4ac8..0x4b18`、`0x4400..0x4434` | 先float除100；<=80映射wet/dry；>80增加输入drive；保留原float中间round与mix顺序 |
| Hamming OLA | `0x1af8..0x1c4c`、`0x4d3c..0x4e78` | `.53836-.46164*cos(2πi/(N-1))`，50%重叠；首块/零重叠时直接copy，按原乘加顺序 |
| Limiter与chunk边界 | `0x58a8..0x5e2c` | 2048样本wrapper、.2s延迟环、.6s工作尾复用、双盒平滑、Target+1.6dB makeup恢复；stream初始对齐修复 |

## 本次复核推动修正的实质问题

1. `stageDelay=D-2047`让真实源数据在limiter首个chunk的offset1开始；原版从offset0开始。Target0时长尾复用产生可测差异。最终改为`D-2048`，limiter后加1帧纯wet延迟，保留总D。
2. Strength100的input drive必须先把24dB转float、再float除20后exp10；少这两次round时gain位模式为0x417d953a，原版为0x417d953b。Target0会把这1ulp差放大；恢复精度后矩阵残差归零。
3. 默认ceiling0关闭新增末级guard，保留原版可略超0dBFS的行为；负ceiling才是额外用户选项。
4. Piece RMS、归一化表达式顺序、增益插值、OLA与Strength混合采用原版浮点精度/运算顺序。构建/对照均用`-ffp-contract=off`。

## 12组合动态对照

全部48kHz、双声道同相信号、512帧block；每组合35秒。输入：0–10s -36dBFS RMS、10–20s -12dBFS RMS、20–25s数字静音、25–35s -30dBFS RMS；997Hz正弦。每个原版进程30秒超时，仅内存渲染，不输出扬声器、不打开原版UI、不改授权。

| Strength | Target | 最大每秒RMS差(dB) | 最大每秒peak差(dB) | 延迟/首次非零(frame) |
|---:|---:|---:|---:|---|
| 0 | -24 | 0.00000 | 0.00000 | 362496 / 362497 |
| 0 | -12 | 0.00000 | 0.00000 | 362496 / 362497 |
| 0 | 0 | 0.00000 | 0.00000 | 362496 / 362497 |
| 40 | -24 | 0.00000 | 0.00000 | 362496 / 362497 |
| 40 | -12 | 0.00000 | 0.00000 | 362496 / 362497 |
| 40 | 0 | 0.00000 | 0.00000 | 362496 / 362497 |
| 80 | -24 | 0.00000 | 0.00000 | 362496 / 362497 |
| 80 | -12 | 0.00000 | 0.00000 | 362496 / 362497 |
| 80 | 0 | 0.00000 | 0.00000 | 362496 / 362497 |
| 100 | -24 | 0.00000 | 0.00000 | 362496 / 362497 |
| 100 | -12 | 0.00000 | 0.00000 | 362496 / 362497 |
| 100 | 0 | 0.00000 | 0.00000 | 362496 / 362497 |

35个一秒窗口×12组合=420个RMS窗口与420个peak窗口，最大已报告差均为0.00000dB。总延迟362496帧=7.552秒；输入frame0本来为0，所以首次非零在362497帧。原版Strength80/100 Target0分别额外重复2次，所有已报告指标精确重复，见`original-repeatability.json`。

## 测试与复现

源码：`Tests/LevelerReferenceTests.cpp`、`Tests/LevelmaticReferenceProbe.mm`。完整矩阵、原版与新实现各秒指标保存在`parameter-matrix.json`；首次发现偏移问题的结果另存`parameter-matrix-before-chunk-alignment.json`。

```sh
xcrun clang++ -std=c++17 -O2 -ffp-contract=off Tests/LevelerReferenceTests.cpp -o /tmp/dayu-leveler-reference-tests
/tmp/dayu-leveler-reference-tests --strength 100 --target 0
```

最终Strength100/Target0也以AddressSanitizer+UndefinedBehaviorSanitizer完整渲染35秒通过，结果`leveler-reference-sanitized.json`，无越界/UB诊断。limiter独立数学转录在44.1/48/96kHz、mono/stereo也通过ASan/UBSan，见`limiter-equivalence-sanitized.json`。

## 边界与未覆盖

- 原版是已安装试用版本，水印/许可状态可能影响输出；没有绕过注册、读取注册码或移除原版水印。虽然本测试输出高度匹配，仍不能据此宣称无水印授权版本的所有行为已验证。
- 原版不支持OfflineRender property(-10879)，但AURenderCallback内存渲染成功；没有测Final Cut Pro实际拖动、播放调度和多实例锁争用。
- 本矩阵验证48kHz与一类稳态/阶跃合成信号；尚未对语音/音乐复杂素材、全部采样率、动态automation、不同Profile与极端host block进行原版逐样本比较。
- 新增maxBoost、response、noiseFloor、outputGain、负ceiling、平滑旁通等扩展参数不属于原版三个主要可见控制的全量动态对照；以上结论针对其默认值。
- 静态证据来自nm/otool，而非REA服务Evidence ID；指令地址只适用于本报告SHA-256的arm64 slice。
