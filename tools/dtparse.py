import struct,sys,os
def parse(path,outdir):
    d=open(path,'rb').read()
    if d[:4]!=b'\xd7\xb7\xab\x1e':
        print("not a dt_table:",path); return
    (magic,total,hdrsz,esz,ecnt,eoff,pagesz,ver)=struct.unpack('>8I',d[:32])
    print(f"{os.path.basename(path)}: total={total} entries={ecnt} entry_size={esz} version={ver}")
    os.makedirs(outdir,exist_ok=True)
    for i in range(ecnt):
        o=eoff+i*esz
        (dsz,doff,dtid,dtrev,cust0,cust1,cust2,cust3)=struct.unpack('>8I',d[o:o+32])
        print(f"  [{i}] size={dsz} off=0x{doff:x} id=0x{dtid:x} rev=0x{dtrev:x} custom={cust0:#x},{cust1:#x},{cust2:#x},{cust3:#x}")
        open(f"{outdir}/{i:02d}_id{dtid:#x}_rev{dtrev:#x}.dtb","wb").write(d[doff:doff+dsz])
parse(sys.argv[1],sys.argv[2])
