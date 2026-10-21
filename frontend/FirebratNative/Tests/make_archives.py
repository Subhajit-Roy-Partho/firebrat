import pathlib, sys, zipfile, tarfile, io, json
root=pathlib.Path(sys.argv[1]);root.mkdir(parents=True, exist_ok=True)
payload=root/'payload.bin'
with payload.open('wb') as f:
    for _ in range(32): f.write(bytes(1024*1024))
manifest=b'{"book_id":"archive-test","sections":[]}'
with zipfile.ZipFile(root/'nested.zip','w',zipfile.ZIP_DEFLATED) as z:
    z.writestr('book/manifest.json',manifest);z.write(payload,'book/payload.bin')
with tarfile.open(root/'nested.tar.gz','w:gz',format=tarfile.PAX_FORMAT) as t:
    i=tarfile.TarInfo('book/manifest.json');i.size=len(manifest);t.addfile(i,io.BytesIO(manifest));t.add(payload,'book/payload.bin')
    i=tarfile.TarInfo('book/'+(('long-dir-'*10)+'/')*3+'file.txt');i.size=4;t.addfile(i,io.BytesIO(b'test'))
raw=bytearray((root/'nested.zip').read_bytes());at=raw.index(b'PK\x01\x02');raw[at+16]^=1;(root/'corrupt.zip').write_bytes(raw)
raw=bytearray((root/'nested.tar.gz').read_bytes());raw[-8]^=1;(root/'corrupt.tar.gz').write_bytes(raw)
with zipfile.ZipFile(root/'unsafe.zip','w') as z:z.writestr('../escaped.txt','bad')
