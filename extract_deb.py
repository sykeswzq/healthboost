import tarfile, io, os, struct

inner_deb = 'releases/extracted_v2215/inner.deb'
out_dir = 'releases/extracted_v2215/v2'
os.makedirs(out_dir, exist_ok=True)

with open(inner_deb, 'rb') as f:
    data = f.read()

print(f'Total file size: {len(data)} bytes')

# Proper ar format parsing
# ar header: name(16) mtime(12) uid(6) gid(6) mode(8) size(10) footer(2) = 60 bytes
pos = 8  # Skip magic
member_count = 0

while pos + 60 <= len(data):
    header = data[pos:pos+60]

    # Parse fields
    name = header[0:16].decode('ascii', errors='replace').rstrip()
    mtime = int(header[16:28].decode('ascii').strip() or '0')
    uid = int(header[28:34].decode('ascii').strip() or '0')
    gid = int(header[34:40].decode('ascii').strip() or '0')
    mode = int(header[40:48].decode('ascii').strip() or '0')
    size = int(header[48:58].decode('ascii').strip() or '0')
    footer = header[58:60]

    # Validate
    if size > len(data) - pos - 60:
        print(f'Invalid size {size} at pos {pos} (name={name!r}), stopping')
        break

    # Data starts after header
    data_start = pos + 60
    file_data = data[data_start:data_start + size]

    print(f'Member {member_count}: "{name}" offset={pos}, size={size}, mode={mode:o}')

    # Extract based on name
    if name == 'debian-binary':
        with open(os.path.join(out_dir, 'debian-binary'), 'wb') as fw:
            fw.write(file_data)
        print(f'  -> debian-binary written')

    elif name == 'control.tar.gz':
        tf = tarfile.open(fileobj=io.BytesIO(file_data), mode='r:gz')
        members = tf.getnames()
        print(f'  Control tar contents: {members}')
        tf.extractall(out_dir)
        tf.close()
        print(f'  -> Extracted to {out_dir}')

    elif 'data.tar' in name:
        if name.endswith('.gz'):
            tf = tarfile.open(fileobj=io.BytesIO(file_data), mode='r:gz')
            members = tf.getnames()
            print(f'  Data tar contents ({len(members)} entries):')
            for m in sorted(members)[:20]:
                print(f'    - {m}')
            if len(members) > 20:
                print(f'    ... and {len(members)-20} more')
            tf.extractall(out_dir)
            tf.close()
            print(f'  -> Extracted to {out_dir}')
        else:
            with open(os.path.join(out_dir, 'data.tar'), 'wb') as fw:
                fw.write(file_data)
            print(f'  -> Wrote data.tar')

    elif name == '//':
        print(f'  (long filename entry)')

    # Move past data, handle odd padding
    pos = data_start + size
    if size % 2 == 1:
        pos += 1  # Skip odd padding byte

    member_count += 1

print(f'\nTotal members: {member_count}')
