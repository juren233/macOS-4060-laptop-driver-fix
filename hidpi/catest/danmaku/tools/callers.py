# callers.py <sample.txt> <leaf-regex> : aggregated caller chains (Chrome frames collapsed) of matching leaf frames (self time only)
import sys,re
lines=open(sys.argv[1]).read().split("Sort by top of stack")[0].splitlines()
leaf=re.compile(sys.argv[2]); stack=[]; agg={}; thread=None
pat=re.compile(r'^([ +!:|]*)(\d+) (.*?)  \(in ([^)]*)\)'); tp=re.compile(r'^\s+(\d+) Thread_\d+(.*)')
rows=[]
for l in lines:
    t=tp.match(l)
    if t: thread=t.group(2).strip()[:40]; stack=[]; continue
    m=pat.match(l)
    if not m: continue
    rows.append((len(m.group(1)),int(m.group(2)),m.group(3),m.group(4),thread))
for i,(d,n,fn,lib,th) in enumerate(rows):
    while stack and stack[-1][0]>=d: stack.pop()
    stack.append((d,fn,lib))
    child=sum(r[1] for r in rows[i+1:i+400] if r[0]==d+2) if i+1<len(rows) and rows[i+1][0]>d else 0
    # self time = n minus direct children
    j=i+1; ch=0
    while j<len(rows) and rows[j][0]>d:
        if rows[j][0]==min(r[0] for r in rows[i+1:j+1]): pass
        j+=1
    if leaf.search(fn):
        chain=[]; 
        for s in reversed(stack[:-1]):
            nm=s[1] if s[1]!="ChromeMain" else "chrome"
            if not chain or chain[-1]!=nm: chain.append(nm[:50])
            if len(chain)>=6: break
        k=f"[{th}] {fn[:30]} <- "+" <- ".join(chain); agg[k]=agg.get(k,0)+n
for k,v in sorted(agg.items(),key=lambda x:-x[1])[:int(sys.argv[3]) if len(sys.argv)>3 else 12]: print(v,k)
