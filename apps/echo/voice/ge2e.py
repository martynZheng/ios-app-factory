"""不依赖 PyTorch 的 GE2E（Resemblyzer）推理：读旧格式的 .pt、算梅尔谱、跑 3 层 LSTM。用来验证，再一行行移植到 Swift。"""
import pickle, struct, collections, numpy as np

class _Storage:
    def __init__(self, dtype, size): self.dtype, self.size, self.data = dtype, size, None
class _Lazy:
    def __init__(self, storage, offset, size, stride): self.s, self.o, self.size, self.stride = storage, offset, size, stride
    def numpy(self):
        base = self.s.data
        item = base.itemsize
        return np.lib.stride_tricks.as_strided(base[self.o:], shape=self.size, strides=[x * item for x in self.stride]).copy()

DT = {'FloatStorage': np.float32, 'LongStorage': np.int64, 'IntStorage': np.int32, 'DoubleStorage': np.float64}

def load_legacy_pt(path):
    f = open(path, 'rb')
    objs = {}
    class U(pickle.Unpickler):
        def find_class(self, mod, name):
            if mod == 'torch._utils' and name == '_rebuild_tensor_v2':
                return lambda storage, offset, size, stride, *a: _Lazy(storage, offset, size, stride)
            if mod == 'torch' and name in DT:
                return name
            if mod == 'collections' and name == 'OrderedDict': return collections.OrderedDict
            return super().find_class(mod, name)
        def persistent_load(self, pid):
            assert pid[0] == 'storage'
            dtype, key, loc, size = pid[1], pid[2], pid[3], pid[4]
            if key not in objs: objs[key] = _Storage(DT[dtype], size)
            return objs[key]
    pickle.load(f); pickle.load(f); pickle.load(f)          # magic, protocol, sys info
    result = U(f).load()
    keys = pickle.load(f)
    for k in keys:
        n = struct.unpack('<q', f.read(8))[0]
        st = objs[k]
        st.data = np.frombuffer(f.read(n * np.dtype(st.dtype).itemsize), dtype=st.dtype)
    def conv(x):
        if isinstance(x, _Lazy): return x.numpy()
        if isinstance(x, dict): return {k: conv(v) for k, v in x.items()}
        return x
    return conv(result)

SR, NFFT, HOP, NMELS = 16000, 400, 160, 40

def hz_to_mel(f):  # Slaney（librosa 默认，htk=False）
    f = np.asanyarray(f, dtype=np.float64)
    f_sp = 200.0 / 3; mels = f / f_sp
    min_log_hz = 1000.0; min_log_mel = min_log_hz / f_sp; logstep = np.log(6.4) / 27.0
    return np.where(f >= min_log_hz, min_log_mel + np.log(np.maximum(f, 1e-10) / min_log_hz) / logstep, mels)

def mel_to_hz(m):
    m = np.asanyarray(m, dtype=np.float64)
    f_sp = 200.0 / 3; freqs = f_sp * m
    min_log_hz = 1000.0; min_log_mel = min_log_hz / f_sp; logstep = np.log(6.4) / 27.0
    return np.where(m >= min_log_mel, min_log_hz * np.exp(logstep * (m - min_log_mel)), freqs)

def mel_basis():
    """librosa.filters.mel(sr=16000, n_fft=400, n_mels=40)：Slaney 刻度、Slaney 归一化。"""
    fftfreqs = np.linspace(0, SR / 2, 1 + NFFT // 2)
    mel_f = mel_to_hz(np.linspace(hz_to_mel(0), hz_to_mel(SR / 2), NMELS + 2))
    fdiff = np.diff(mel_f)
    ramps = mel_f[:, None] - fftfreqs[None, :]
    w = np.zeros((NMELS, 1 + NFFT // 2))
    for i in range(NMELS):
        lower = -ramps[i] / fdiff[i]; upper = ramps[i + 2] / fdiff[i + 1]
        w[i] = np.maximum(0, np.minimum(lower, upper))
    enorm = 2.0 / (mel_f[2:NMELS + 2] - mel_f[:NMELS])
    return (w * enorm[:, None]).astype(np.float32)

def hann():
    n = np.arange(NFFT)
    return (0.5 - 0.5 * np.cos(2 * np.pi * n / NFFT)).astype(np.float32)   # periodic

def dft_mats():
    n = np.arange(NFFT)[:, None]; k = np.arange(NFFT // 2 + 1)[None, :]
    ang = 2 * np.pi * n * k / NFFT
    return np.cos(ang).astype(np.float32), (-np.sin(ang)).astype(np.float32)

def melspec(wav):
    """center=True，两端各补 n_fft/2 的反射。功率谱（不取对数）。"""
    pad = NFFT // 2
    y = np.pad(wav, pad, mode='reflect')
    n_frames = 1 + (len(y) - NFFT) // HOP
    frames = np.stack([y[i * HOP: i * HOP + NFFT] for i in range(n_frames)]) * hann()[None, :]
    C, S = dft_mats()
    re = frames @ C; im = frames @ S
    power = re * re + im * im
    return (power @ mel_basis().T).astype(np.float32)          # (frames, 40)

def sigmoid(x): return 1 / (1 + np.exp(-x))

class GE2E:
    def __init__(self, path):
        sd = load_legacy_pt(path)['model_state']
        self.layers = []
        for l in range(3):
            self.layers.append((sd[f'lstm.weight_ih_l{l}'], sd[f'lstm.weight_hh_l{l}'], sd[f'lstm.bias_ih_l{l}'] + sd[f'lstm.bias_hh_l{l}']))
        self.W, self.b = sd['linear.weight'], sd['linear.bias']

    def embed_partial(self, mel):          # mel: (160, 40)
        x = mel
        for (Wih, Whh, b) in self.layers:
            H = Whh.shape[1]; h = np.zeros(H, np.float32); c = np.zeros(H, np.float32)
            pre = x @ Wih.T + b            # (T, 4H)，门顺序 i, f, g, o
            out = np.zeros((x.shape[0], H), np.float32)
            for t in range(x.shape[0]):
                g = pre[t] + Whh @ h
                i, f, gg, o = sigmoid(g[:H]), sigmoid(g[H:2*H]), np.tanh(g[2*H:3*H]), sigmoid(g[3*H:])
                c = f * c + i * gg; h = o * np.tanh(c); out[t] = h
            x = out
        e = np.maximum(0, self.W @ h + self.b)
        return e / (np.linalg.norm(e) + 1e-9)

    def embed(self, wav, rate=1.3, min_coverage=0.75):
        """与 resemblyzer.embed_utterance 相同的切片方式。"""
        rms = np.sqrt(np.mean(wav ** 2)) + 1e-9
        gain = 10 ** ((-30 - 20 * np.log10(rms)) / 20)
        if gain > 1: wav = wav * gain
        n_frames = int(np.ceil((len(wav) + 1) / HOP))
        step = int(round(SR / rate / HOP))
        slices = list(range(0, max(1, n_frames - 160 + step + 1), step))
        last = slices[-1] * HOP
        if (len(wav) - last) / (160 * HOP) < min_coverage and len(slices) > 1: slices = slices[:-1]
        need = slices[-1] * HOP + 160 * HOP
        if need >= len(wav): wav = np.pad(wav, (0, need - len(wav)))
        mel = melspec(wav)
        parts = np.array([self.embed_partial(mel[s:s + 160]) for s in slices])
        e = parts.mean(0)
        return e / np.linalg.norm(e), parts
