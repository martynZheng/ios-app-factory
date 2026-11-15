# 本机声音模型

| 文件 | 来源 | 许可证 |
|---|---|---|
| `App/Resources/campplus.onnx` | 3D-Speaker CAM++ `iic/speech_campplus_sv_zh_en_16k-common_advanced`（ModelScope），sherpa-onnx 转的 ONNX：`huggingface.co/csukuangfj/speaker-embedding-models` 里的 `3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx` | Apache 2.0 |
| `App/Resources/segmentation.onnx` | pyannote `segmentation-3.0`，sherpa-onnx 转的 ONNX：`huggingface.co/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0` 的 `model.onnx` | MIT（`LICENSE-pyannote-segmentation`） |

手机上用 ONNX Runtime（SPM：`microsoft/onnxruntime-swift-package-manager`）运行。

- `pipe.py`：Kaldi Fbank 的纯 numpy 实现（和 kaldi-native-fbank 比对过，最大误差 7e-4）、CAM++ 和分段的调用方式。Swift 的 `Voice/VoiceModels.swift` 逐行对应。
- `diarize.py`：手机上的分离算法（10 秒窗、步长 5 秒；每窗每个局部说话人取单独在说的部分算声纹；先比“我”再比认识的人；每个时刻取离窗中心最近的窗）。

实测（DeepSeek 合成的两种声音；干净、加噪 10 dB、远处混响三种环境混在一起比）：CAM++ 同一人 0.49–0.93、不同人 0.03–0.35；
一段 27 秒、6 次轮流说话的对话，用另外 4 句录入“我”之后，6 段全部判对。
