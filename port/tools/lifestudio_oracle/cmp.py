# cmp.py <refdir> <testdir>: per-file max abs vertex error (NaN = vertex not written)
import struct,sys,os,math
ref,tst=sys.argv[1],sys.argv[2]; worst=(0,None); tot=0; bad=0
rows=[]
for fn in sorted(os.listdir(ref)):
    a=open(os.path.join(ref,fn),'rb').read(); 
    if not os.path.exists(os.path.join(tst,fn)): print('missing',fn); continue
    b=open(os.path.join(tst,fn),'rb').read()
    if len(a)!=len(b): print('size',fn,len(a),len(b)); bad+=1; continue
    n=len(a)//4; fa=struct.unpack('<%df'%n,a); fb=struct.unpack('<%df'%n,b)
    mx=0; mi=-1; nanm=0
    for i,(x,y) in enumerate(zip(fa,fb)):
        if math.isnan(x)!=math.isnan(y): nanm+=1; continue
        if math.isnan(x): continue
        e=abs(x-y)
        if e>mx: mx=e; mi=i
    rows.append((mx,fn,mi//3,nanm)); tot+=1
    if mx>worst[0]: worst=(mx,fn)
rows.sort(reverse=True)
for r in rows[:int(sys.argv[3]) if len(sys.argv)>3 else 8]: print('  %-14s max %.3g at vertex %d nan-mismatch %d'%(r[1],r[0],r[2],r[3]))
print('files',tot,'size-mismatch',bad,'worst',worst)
