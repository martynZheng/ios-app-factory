"""把 Resemblyzer 自带的 GE2E 声纹模型（MIT）导出成 App 直接读的 float32 二进制：
   magic 'GE2E' | int32 版本 | 梅尔滤波器 40×201 | 汉宁窗 400 | 3 层 LSTM（Wih, Whh, 合并后的偏置）| 线性层 W 256×256, b 256
用法：python export.py <Resemblyzer 包里的 pretrained.pt> <输出 ge2e.bin>
不需要 PyTorch（ge2e.py 自己读旧格式的 .pt）。"""
import sys, struct, numpy as np
from ge2e import load_legacy_pt, mel_basis, hann

sd = load_legacy_pt(sys.argv[1])['model_state']
parts = [mel_basis(), hann()]
for l in range(3):
    parts += [sd[f'lstm.weight_ih_l{l}'], sd[f'lstm.weight_hh_l{l}'], sd[f'lstm.bias_ih_l{l}'] + sd[f'lstm.bias_hh_l{l}']]
parts += [sd['linear.weight'], sd['linear.bias']]
with open(sys.argv[2], 'wb') as f:
    f.write(b'GE2E'); f.write(struct.pack('<i', 1))
    for p in parts: f.write(np.ascontiguousarray(p, dtype='<f4').tobytes())
print('floats:', sum(p.size for p in parts))
