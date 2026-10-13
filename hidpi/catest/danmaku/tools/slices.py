# slices.py <trace.json> [thread-name] : inclusive/self time of complete slices on one thread of the GPU process
import sys, json, collections
ev = json.load(open(sys.argv[1])); want = sys.argv[2] if len(sys.argv) > 2 else "CrGpuMain"
names = {(e["pid"], e["tid"]): e["args"]["name"] for e in ev if e.get("ph") == "M" and e.get("name") == "thread_name"}
pn = {e["pid"]: e["args"]["name"] for e in ev if e.get("ph") == "M" and e.get("name") == "process_name"}
tids = [k for k, v in names.items() if v == want and "GPU" in pn.get(k[0], "")]
for k in tids:
    xs = []; st = {}
    for e in ev:
        if (e.get("pid"), e.get("tid")) != k: continue
        if e.get("ph") == "X": xs.append((e["ts"], e["ts"] + e.get("dur", 0), e["name"]))
        elif e.get("ph") == "B": st.setdefault(e["name"], []).append(e["ts"])
        elif e.get("ph") == "E" and st.get(e.get("name")): xs.append((st[e["name"]].pop(), e["ts"], e["name"]))
    xs.sort(key=lambda x: (x[0], -x[1])); t0 = min(x[0] for x in xs); t1 = max(x[1] for x in xs)
    inc = collections.Counter(); selfc = collections.Counter(); stack = []; kids = collections.Counter()
    for i, (a, b, n) in enumerate(xs):
        while stack and stack[-1][1] <= a: stack.pop()
        if stack: kids[stack[-1][3]] += b - a
        stack.append((a, b, n, i)); inc[n] += b - a
    for i, (a, b, n) in enumerate(xs): selfc[n] += (b - a) - kids[i]
    span = t1 - t0; print(f"{pn.get(k[0])} {want}: span {span/1e6:.2f} s")
    for n, v in inc.most_common(28): print(f"  {100*v/span:5.1f}% incl {100*selfc[n]/span:5.1f}% self  {n}")
