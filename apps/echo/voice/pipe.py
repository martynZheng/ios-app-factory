"""参考实现：Kaldi Fbank（纯 numpy，Swift 照抄）+ CAM++ 声纹 + pyannote 分段。"""
import numpy as np, onnxruntime as ort

SR = 16000
def mel_scale(f): return 1127.0 * np.log(1.0 + f / 700.0)

def kaldi_fbank(wav, num_bins=80):
    """Kaldi 默认：25ms/10ms、snip_edges、去直流、预加重 0.97、Povey 窗、512 点 FFT、功率谱、20Hz–奈奎斯特的梅尔、log。"""
    flen, shift, nfft = 400, 160, 512
    if len(wav) < flen: return np.zeros((0, num_bins), np.float32)
    n = 1 + (len(wav) - flen) // shift
    frames = np.stack([wav[i*shift:i*shift+flen] for i in range(n)]).astype(np.float64)
    frames -= frames.mean(axis=1, keepdims=True)
    pre = frames.copy(); pre[:, 1:] -= 0.97 * frames[:, :-1]; pre[:, 0] -= 0.97 * frames[:, 0]
    win = (0.5 - 0.5 * np.cos(2 * np.pi * np.arange(flen) / (flen - 1))) ** 0.85
    pre *= win
    spec = np.abs(np.fft.rfft(pre, n=nfft)) ** 2               # (n, 257)
    lo, hi = mel_scale(20.0), mel_scale(SR / 2)
    delta = (hi - lo) / (num_bins + 1)
    fft_bin = SR / nfft
    W = np.zeros((num_bins, nfft // 2 + 1))
    for b in range(num_bins):
        l, c, r = lo + b * delta, lo + (b + 1) * delta, lo + (b + 2) * delta
        for k in range(nfft // 2):                            # Kaldi 不用最后一个（奈奎斯特）频点
            m = mel_scale(fft_bin * k)
            if l < m < r:
                W[b, k] = (m - l) / (c - l) if m <= c else (r - m) / (r - c)
    feats = spec @ W.T
    return np.log(np.maximum(feats, np.finfo(np.float32).eps)).astype(np.float32)

class CamPlus:
    def __init__(self, path): self.s = ort.InferenceSession(path)
    def embed(self, wav):
        f = kaldi_fbank(wav)
        if len(f) < 10: return None
        f = f - f.mean(axis=0, keepdims=True)                 # global-mean
        e = self.s.run(None, {'x': f[None]})[0][0]
        return e / np.linalg.norm(e)

class Segmenter:
    """pyannote segmentation-3.0：10 秒一窗，输出约 589 帧 × 7 类（powerset：无人、1、2、3、1+2、1+3、2+3）。"""
    POWER = [(), (0,), (1,), (2,), (0, 1), (0, 2), (1, 2)]
    def __init__(self, path): self.s = ort.InferenceSession(path)
    def run(self, wav10s):
        x = np.zeros(160000, np.float32); x[:len(wav10s)] = wav10s[:160000]
        y = self.s.run(None, {'x': x[None, None]})[0][0]      # (frames, 7) log 概率
        cls = y.argmax(axis=1)
        act = np.zeros((len(cls), 3), bool)
        for t, c in enumerate(cls):
            for spk in self.POWER[c]: act[t, spk] = True
        return act                                             # 每帧每个局部说话人是否在说
    @staticmethod
    def frame_time(i): return (i * 270 + 991 / 2) / SR
