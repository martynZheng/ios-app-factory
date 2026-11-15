"""手机上要跑的说话人分离算法（Swift 照抄）：
1. 10 秒一窗、步长 5 秒跑 pyannote 分段，得到每窗每帧 3 个“局部说话人”是否在说；
2. 每窗每个局部说话人，取他“单独在说”的采样拼起来（≥1 秒）算 CAM++ 声纹；
3. 声纹先比“我”，再比认识的人，都不像就新建；
4. 每个时刻取离窗中心最近的那一窗的结果，得到整段的“谁在说”时间线。"""
import numpy as np
from pipe import CamPlus, Segmenter
SR=16000; WIN=160000; STEP=80000; SHIFT=270; RF=991

def diarize(wav, seg, cam, me=None, me_th=0.52, spk_th=0.50, book=None):
    book = book if book is not None else []          # [(id, centroid, count)]
    n = len(wav)
    starts = list(range(0, max(1, n - WIN + STEP), STEP)) if n > WIN else [0]
    chunks = []
    for s in starts:
        act = seg.run(wav[s:s+WIN])                  # (589, 3)
        F = act.shape[0]
        labels = [None]*3
        for k in range(3):
            alone = act[:, k] & (act.sum(1) == 1)
            if alone.sum() * SHIFT / SR < 0.8: continue
            idx = []
            for t in np.nonzero(alone)[0]:
                a = s + t*SHIFT; idx.append((a, min(a+SHIFT, n)))
            pieces = [wav[a:b] for a, b in idx if b > a]
            if not pieces: continue
            sample = np.concatenate(pieces)
            if len(sample) < SR: continue
            e = cam.embed(sample)
            if e is None: continue
            if me is not None and float(e @ me) >= me_th:
                labels[k] = 'me'; continue
            best = max(range(len(book)), key=lambda i: float(e @ book[i][1]), default=None)
            if best is not None and float(e @ book[best][1]) >= spk_th:
                bid, c, cnt = book[best]; c = c*cnt + e; c /= np.linalg.norm(c); book[best] = (bid, c, cnt+1); labels[k] = bid
            else:
                bid = 'S%d' % len(book); book.append((bid, e, 1)); labels[k] = bid
        chunks.append((s, act, labels))
    # 时间线：每 0.1 秒取离窗中心最近的一窗
    timeline = []
    for t in np.arange(0, n/SR, 0.1):
        best = min(chunks, key=lambda c: abs((c[0] + WIN/2)/SR - t))
        s, act, labels = best
        f = int((t*SR - s - RF/2) / SHIFT)
        if f < 0 or f >= act.shape[0]: timeline.append(()); continue
        timeline.append(tuple(labels[k] for k in range(3) if act[f, k] and labels[k] is not None))
    return timeline, book
