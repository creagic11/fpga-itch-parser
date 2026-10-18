"""Reference models for the top-of-book engine.

HwBook mirrors the hardware's rules exactly: a 4-way set-associative order table
(set = ref low bits, tag = next 32 bits), a 4,096-tick price window from a base
price, collisions/duplicates/out-of-window orders counted and not booked, and a
BBO update whenever the best bid or offer changes.

FullBook is an ordinary unbounded order book (dicts). When HwBook hits none of its
limits, both must produce the same BBO stream.
"""
from __future__ import annotations

ADD, EXEC, EXEC_PX, CANCEL, DELETE, REPLACE, TRADE = 1, 2, 3, 4, 5, 6, 7


def best(levels: dict, sell: bool):
    live = [k for k, q in levels.items() if q]
    if not live:
        return None
    return min(live) if sell else max(live)


class HwBook:
    def __init__(self, base: int, set_bits: int = 12, win_bits: int = 12, ways: int = 4):
        self.base, self.set_bits, self.nlvl, self.ways = base, set_bits, 1 << win_bits, ways
        self.sets: dict[int, list] = {}
        self.lv = {False: {}, True: {}}           # sell? -> {index: qty}
        self.last = (0, 0, 0, 0)
        self.c = dict(events=0, bbo=0, out_of_window=0, collisions=0, unknown=0, duplicates=0)
        self.live = 0

    def _idx(self, price: int):
        d = price - self.base
        if d < 0 or d % 100 or d // 100 >= self.nlvl:
            return None
        return d // 100

    def _where(self, ref: int):
        s = ref & ((1 << self.set_bits) - 1)
        tag = (ref >> self.set_bits) & 0xFFFFFFFF
        return self.sets.setdefault(s, [None] * self.ways), tag

    def _ref_ok(self, ref: int) -> bool:
        return ref < (1 << (self.set_bits + 32))

    def _add(self, ref, sell, price, shares) -> bool:
        idx = self._idx(price)
        if not self._ref_ok(ref) or idx is None:
            self.c["out_of_window"] += 1
            return False
        ways, tag = self._where(ref)
        if any(w and w["tag"] == tag for w in ways):
            self.c["duplicates"] += 1
            return False
        free = [i for i, w in enumerate(ways) if w is None]
        if not free:
            self.c["collisions"] += 1
            return False
        ways[free[0]] = dict(tag=tag, sell=sell, idx=idx, qty=shares)
        lv = self.lv[sell]
        lv[idx] = lv.get(idx, 0) + shares
        self.live += 1
        return True

    def event(self, t, ref, new_ref, shares, price, sell, seq):
        """Apply one event; return the BBO tuple (bid_px, bid_qty, ask_px, ask_qty, seq) or None."""
        self.c["events"] += 1
        if t in (TRADE, 0):
            return None
        changed = False
        if t == ADD:
            changed = self._add(ref, sell, price, shares)
        else:
            ways, tag = self._where(ref)
            hit = next((i for i, w in enumerate(ways) if w and w["tag"] == tag), None)
            if not self._ref_ok(ref) or hit is None:
                self.c["unknown"] += 1
            else:
                o = ways[hit]
                whole = t in (DELETE, REPLACE) or shares >= o["qty"]
                red = o["qty"] if whole else shares
                if whole:
                    ways[hit] = None
                    self.live -= 1
                else:
                    o["qty"] -= shares
                lv = self.lv[o["sell"]]
                lv[o["idx"]] -= red
                if lv[o["idx"]] == 0:
                    del lv[o["idx"]]
                changed = True
                if t == REPLACE:
                    self._add(new_ref, o["sell"], price, shares)
        if not changed:
            return None
        b, a = best(self.lv[False], False), best(self.lv[True], True)
        cur = (self.base + 100 * b if b is not None else 0, self.lv[False][b] if b is not None else 0,
               self.base + 100 * a if a is not None else 0, self.lv[True][a] if a is not None else 0)
        if cur == self.last:
            return None
        self.last = cur
        self.c["bbo"] += 1
        return cur + (seq,)


class FullBook:
    """Unbounded book with the C++ BookBuilder's BBO-change rule."""

    def __init__(self):
        self.orders, self.lv, self.last = {}, {False: {}, True: {}}, (0, 0, 0, 0)

    def _take(self, ref, n):
        o = self.orders.get(ref)
        if not o:
            return False
        n = min(n, o[2])
        o[2] -= n
        lv = self.lv[o[0]]
        lv[o[1]] -= n
        if lv[o[1]] == 0:
            del lv[o[1]]
        if o[2] == 0:
            del self.orders[ref]
        return o

    def event(self, t, ref, new_ref, shares, price, sell, seq):
        if t in (TRADE, 0):
            return None
        if t == ADD:
            self.orders[ref] = [sell, price, shares]
            self.lv[sell][price] = self.lv[sell].get(price, 0) + shares
        elif t == REPLACE:
            o = self.orders.get(ref)
            if not o:
                return None
            s = o[0]
            self._take(ref, o[2])
            self.orders[new_ref] = [s, price, shares]
            self.lv[s][price] = self.lv[s].get(price, 0) + shares
        elif t == DELETE:
            o = self.orders.get(ref)
            if not o or not self._take(ref, o[2]):
                return None
        elif not self._take(ref, shares):
            return None
        b, a = best(self.lv[False], False), best(self.lv[True], True)
        cur = (b or 0, self.lv[False][b] if b else 0, a or 0, self.lv[True][a] if a else 0)
        if cur == self.last:
            return None
        self.last = cur
        return cur + (seq,)
