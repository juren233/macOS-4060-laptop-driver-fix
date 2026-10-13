# thleaf.py <sample.txt> <thread-substr> : self-time leaves for one thread, + inclusive time of selected nvmtl functions
import sys,re
txt=open(sys.argv[1]).read().split("Sort by top of stack")[0].splitlines()
pat=re.compile(r'^([ +!:|]*)(\d+) (.*?)  \(in ([^)]*)\)'); tp=re.compile(r'^\s+(\d+) Thread_\d+(.*)')
on=False; rows=[]
for l in txt:
    t=tp.match(l)
    if t: on = sys.argv[2] in t.group(2); continue
    if on:
        m=pat.match(l)
        if m: rows.append((len(m.group(1)),int(m.group(2)),m.group(3)))
selfc={}; incl={}
for i,(d,n,fn) in enumerate(rows):
    ch=0; j=i+1; cd=None
    while j<len(rows) and rows[j][0]>d:
        if cd is None: cd=rows[j][0]
        if rows[j][0]==cd: ch+=rows[j][1]
        j+=1
    selfc[fn]=selfc.get(fn,0)+n-ch
tot=sum(selfc.values())
print("total",tot)
for k,v in sorted(selfc.items(),key=lambda x:-x[1])[:25]: print(f"{v:6d} {100*v/tot:5.1f}% {k[:90]}")
# inclusive (outermost occurrence only)
want=["nvmtlSurfaceIn","nvmtl_surface_in_for_cb","commit","nvmtl_vk_image_write_async","drawPrimitives","drawIndexedPrimitives","newTextureWithDescriptor","setFragmentTexture","endEncoding","renderCommandEncoderWithDescriptor","nvk_","nvmtl_"]
for w in want:
    s=0; stack=[]
    for (d,n,fn) in rows:
        while stack and stack[-1]>=d: stack.pop()
        if w in fn and not stack: s+=n; stack.append(d)
        elif stack: pass
    print(f"incl {w}: {s}")
