"""Broader machine-code regression tests; run after assembling the body.

Run from _sd: python tests/test_driver.py
Uses synthetic FAT32 sectors only; no physical card or emulator image is changed.
"""
import random
from test_fat_offsets import Driver, SYMS, test_offsets_and_links, test_write_and_allocation, test_fragmented_load


def u32(d, prefix):
    return d.get(prefix+'_lo') | d.get(prefix+'_hi') << 16


def put32(d, prefix, value):
    d.put(prefix+'_lo', value & 65535)
    d.put(prefix+'_hi', value >> 16)


def test_eoc_boundaries():
    valid = [2, 63, 64, 127, 128, 65535, 65536,
             0x0ff7ffff, 0x0ff80000, 0x0fffffef]
    for top in (0, 0xa0000000, 0xf0000000):
        for value in valid + list(range(0x0ffffff8, 0x10000000)) + [0, 1] + list(range(0x0ffffff0, 0x0ffffff8)):
            d = Driver()
            d.fat(100, value | top)
            d.cluster(100)
            d.call('get_next_cluster')
            expected = 0 if value in valid else (1 if value >= 0x0ffffff8 else 2)
            assert d.get('chain_ended', 1) == expected, hex(value | top)
            assert u32(d, 'cur_cluster') == (value if expected == 0 else 100)


def test_errors_do_not_extend_chain():
    for broken in (0, 1, 0x0ffffff0, 0x0ffffff7, 'io'):
        d = Driver()
        d.fat(100, 101 if broken == 'io' else broken)
        d.cluster(100)
        d.call('stream_open')
        d.put('stream_sec_in_cluster', 1, 1)
        if broken == 'io':
            d.fail_reads.add(49)
        d.call('strm_advance')
        assert d.get('stream_eoc', 1) == 2
        before = len(d.io)
        for routine in ('stream_write_sector', 'stream_write_sector_from', 'stream_read_sector_to'):
            assert d.call(routine) != 0
        assert len(d.io) == before, 'I/O after broken chain'
    d = Driver()
    d.cluster(8192)  # first cluster outside a 64-sector FAT
    d.call('get_next_cluster')
    assert d.get('chain_ended', 1) == 2 and not d.io
    for routine in ('core_load512', 'core_save512'):
        d = Driver()
        d.cluster(100)
        d.call('stream_open')
        d.fail_reads.add(1213)
        d.fail_writes.add(1213)
        d.m.c, d.m.hl, d.m.b = 32, 0x4000, 1
        assert d.call(routine) == 15
        assert (d.m.c, d.m.hl) == (32, 0x4000)
        assert d.get('stream_sec_in_cluster', 1) == 0


def test_address_arithmetic():
    rng = random.Random(589)
    for _ in range(300):
        d = Driver()
        cluster = rng.randrange(2, 0x400000)
        spc = rng.choice((1, 2, 4, 8, 16, 32, 64, 128))
        data, base = rng.randrange(32, 200000), rng.randrange(0, 200000)
        d.cluster(cluster)
        d.put('sectors_per_cluster', spc, 1)
        put32(d, 'data_start', data)
        put32(d, 'addtop', base)
        d.call('cluster_to_sector')
        assert u32(d, 'fza_sector') == base+data+(cluster-2)*spc
        maximum = rng.randrange(1, 0xffffffff)
        put32(d, 'sd_lba_max', maximum)
        for lba in (0, maximum-1, maximum, 0xffffffff):
            d.m.hl, d.m.de = lba >> 16, lba & 65535
            d.call('set_lba32')
            d.call('lba_guard_check')
            assert bool(d.m.f & 1) == (lba < maximum)
        for block, lba in ((0, rng.randrange(0x400000)), (1, rng.randrange(0xffffffff))):
            d.put('sd_block_addressed', block, 1)
            d.m.hl, d.m.de = lba >> 16, lba & 65535
            d.call('set_lba32')
            d.call('compute_card_arg')
            p = SYMS['card_arg']
            assert int.from_bytes(d.m.memory[p:p+4], 'big') == lba*(1 if block else 512)


def boot_sector(spc=64):
    b = bytearray(512)
    for offset, size, value in ((11, 2, 512), (13, 1, spc), (14, 2, 32),
                                (16, 1, 2), (32, 4, 10000000), (36, 4, 59430),
                                (44, 4, 12345), (48, 2, 1)):
        b[offset:offset+size] = value.to_bytes(size, 'little')
    b[510:512] = b'\x55\xaa'
    return b


def test_bpb_and_partition():
    for spc in (1, 2, 4, 8, 16, 32, 64, 128):
        d = Driver()
        d.m.set_memory_block(SYMS['sdbuf'], boot_sector(spc))
        assert d.call('verify_fat32') == 0
        d.call('parse_bpb')
        assert u32(d, 'data_start') == 32+2*59430
        assert u32(d, 'root_dir') == 32+2*59430+(12345-2)*spc
        assert u32(d, 'sd_lba_max') == 17+10000000
    for offset, value in ((510, 0), (511, 0), (11, 1), (22, 1), (17, 1), (13, 0), (13, 3)):
        d = Driver()
        b = boot_sector()
        b[offset] = value
        d.m.set_memory_block(SYMS['sdbuf'], b)
        assert d.call('verify_fat32') != 0, offset
    for slot in range(4):
        d = Driver()
        mbr = bytearray(512)
        mbr[510:512] = b'\x55\xaa'
        mbr[446+slot*16+4] = 0x0c
        mbr[446+slot*16+8:446+slot*16+12] = (70000).to_bytes(4, 'little')
        d.disk[70000] = boot_sector()
        d.m.set_memory_block(SYMS['sdbuf'], mbr)
        assert d.call('detect_partition') == 0
        assert u32(d, 'addtop') == 70000
    d = Driver()
    original = boot_sector()
    d.m.set_memory_block(SYMS['sdbuf'], original)
    assert d.call('detect_partition') == 0
    assert u32(d, 'addtop') == 0


def test_stream_read_write_all_cluster_sizes():
    rng = random.Random(731)
    for spc in (1, 2, 4, 8, 16, 32, 64, 128):
        d = Driver()
        d.put('sectors_per_cluster', spc, 1)
        chain = [319, 500, 320, 1023]
        for i, n in enumerate(chain):
            d.fat(n, chain[i+1] if i+1 < len(chain) else 0x0ffffff8)
            for s in range(spc):
                d.disk[1017+(n-2)*spc+s] = bytearray(512)
        payload = rng.randbytes(len(chain)*spc*512)
        start = 32*16384+4  # nonzero, even offset; exercise page overflow remainder
        d.ram[start:start+len(payload)] = payload
        d.cluster(chain[0])
        d.call('stream_open')
        d.m.c, d.m.hl = 32, 0x4004
        remaining = len(payload)//512
        while remaining:
            count = min(remaining, 127)
            d.m.b = count
            assert d.call('core_save512') == 0
            remaining -= count
        on_disk = b''.join(d.disk[1017+(n-2)*spc+s] for n in chain for s in range(spc))
        assert on_disk == payload, spc
        d.ram[start:start+len(payload)] = bytes(len(payload))
        d.cluster(chain[0])
        d.call('stream_open')
        d.m.c, d.m.hl = 32, 0x4004
        remaining = len(payload)//512
        while remaining:
            count = min(remaining, 113)
            d.m.b = count
            assert d.call('core_load512') == 0
            remaining -= count
        assert d.ram[start:start+len(payload)] == payload, spc
        d.cluster(chain[0])
        d.call('stream_open')
        for s in range(spc):
            assert d.call('stream_read_sector') == 0
            p = SYMS['sdbuf']
            assert bytes(d.m.memory[p:p+512]) == payload[s*512:(s+1)*512]


def test_grow_fragmented_file():
    d = Driver()
    for n in range(256, 512):
        d.fat(n, 0x0fffffff)
    free = [320, 356, 383, 400]
    for n in free:
        d.fat(n, 0)
    d.put('next_search_valid', 1, 1)
    d.put('next_search_lo', 320)
    d.cluster(319)
    d.call('stream_open')
    payload = random.Random(52).randbytes(10*512)
    d.ram[32*16384:32*16384+len(payload)] = payload
    d.m.c, d.m.hl, d.m.b = 32, 0x4000, 10
    assert d.call('core_save512') == 0
    chain = [319]+free
    actual = b''.join(d.disk[1017+(n-2)*2+s] for n in chain for s in range(2))
    assert actual == payload
    for index, n in enumerate(chain):
        sector, offset = divmod(n*4, 512)
        value = int.from_bytes(d.disk[49+sector][offset:offset+4], 'little') & 0x0fffffff
        assert value == (chain[index+1] if index+1 < len(chain) else 0x0fffffff)
        assert d.disk[49+sector] == d.disk[113+sector]


def test_directories_and_long_names():
    d = Driver()
    d.put('rtc_cached', 1, 1)
    d.put('fat_date', 0x5d47)
    d.put('fat_time', 0x6d5d)
    for sector in range(49, 113):
        d.disk[sector] = bytearray(512)
    d.fat(2, 0x0fffffff)
    d.put('root_cluster_lo', 2)
    d.call('core_setroot')
    d.disk[1017] = bytearray(512)
    d.disk[1018] = bytearray(512)
    d.put('next_search_valid', 1, 1)
    d.put('next_search_lo', 320)
    def arg(data):
        d.m.set_memory_block(0x9000, data + b'\0')
        d.m.hl = 0x9000
    arg(b'Long directory name')
    assert d.call('core_mkdir') == 0
    arg(b'long DIRECTORY name')
    assert d.call('core_fentry') == 1
    directory = u32(d, 'fbn_cluster')
    assert directory == 320
    first = d.disk[1017+(directory-2)*2]
    assert first[:11] == b'.          '
    assert first[32:43] == b'..         '
    assert int.from_bytes(first[58:60], 'little') == 2
    d.call('core_setdir')
    # Multiple colliding short names, LFN runs crossing sectors, directory growth.
    names = [f'Long music filename number {i:02d}.pt3'.encode() for i in range(18)]
    for name in names:
        arg(b'\0'+(12345).to_bytes(4, 'little')+name)
        assert d.call('core_mkfile') == 0, name
    clusters = set()
    for name in names:
        arg(name.upper())
        assert d.call('core_fentry') == 1, name
        assert u32(d, 'fbn_size') == 12345
        clusters.add(u32(d, 'fbn_cluster'))
    assert len(clusters) == len(names)
    before = {n: bytes(b) for n, b in d.disk.items()}
    arg(b'\0'+(12345).to_bytes(4, 'little')+names[0])
    assert d.call('core_mkfile') == 3
    assert before == d.disk


def test_fsinfo():
    for free_count in (0xffffffff, 100000, 65536):
        d = Driver()
        addr = SYMS['write_fsinfo_hint']
        d.m.clear_breakpoint(addr)
        del d.hooks[addr]
        b = bytearray(512)
        for offset, value in ((0, 0x41615252), (484, 0x61417272),
                              (488, free_count), (492, 65535)):
            b[offset:offset+4] = value.to_bytes(4, 'little')
        d.disk[18] = b
        d.put('fsinfo_sector', 1)
        d.call('read_fsinfo_hint')
        assert d.get('fsinfo_valid', 1) == 1
        assert u32(d, 'fsinfo_hint') == 65535
        put32(d, 'next_search', 65536)
        assert d.call('write_fsinfo_hint') == 0
        assert int.from_bytes(d.disk[18][492:496], 'little') == 65536
        assert int.from_bytes(d.disk[18][488:492], 'little') == (free_count if free_count == 0xffffffff else free_count-1)


def test_rtc_encoding():
    for binary in (False, True):
        d = Driver()
        rtc = {0: 59, 2: 42, 4: 23, 7: 7, 8: 10, 9: 26}
        selected = [0]
        def output(port, value):
            if port == 0xdff7:
                selected[0] = value
        def input_(port):
            if port != 0xbff7:
                return 0
            if selected[0] == 11:
                return 4 if binary else 0
            value = rtc.get(selected[0], 0)
            return value if binary else (value//10)*16+value%10
        d.m.set_output_callback(output)
        d.m.set_input_callback(input_)
        d.call('rtc_to_fat_datetime')
        assert d.get('fat_date') == ((2026-1980)<<9 | 10<<5 | 7)
        assert d.get('fat_time') == (23<<11 | 42<<5 | 59//2)


def test_dma_registers():
    for routine, base, control in (('dma_recv_ext', 0x1daf, 0x42), ('dma_send_ext', 0x1aaf, 0xc2)):
        for offset in (0x4000, 0x4004, 0x7ffe):
            d = Driver()
            ports = {}
            d.m.set_output_callback(lambda port, value: ports.__setitem__(port, value))
            d.m.set_input_callback(lambda port: 0)
            d.put('dma_xfer_off', offset)
            d.put('dma_xfer_page', 32, 1)
            d.call(routine)
            assert ports == {base: offset & 255, base+256: (offset>>8)&63,
                             base+512: 32, 0x26af: 255, 0x28af: 0, 0x27af: control}


def test_sd_initialization():
    from collections import deque
    d = Driver()
    for kind in ('sdhc', 'sdsc', 'legacy', 'mmc', 'busy'):
        commands, frame, response = [], [], deque()
        selected = [False]
        def output(port, value):
            if port & 255 == 0x77:
                selected[0] = value == 1
                if not selected[0]:
                    frame.clear()
                    response.clear()
            if port & 255 != 0x57 or not selected[0]:
                return
            if not frame and not 0x40 <= value <= 0x7f:
                return
            frame.append(value)
            if len(frame) != 6:
                return
            command = frame[0] & 63
            commands.append((command, int.from_bytes(bytes(frame[1:5]), 'big')))
            assert len(commands) < 16010, 'Initialization retry counter never expires'
            answers = {0: [1], 8: [1, 0, 0, 1, 0xaa] if kind in ('sdhc', 'sdsc', 'busy') else [5],
                       55: [1], 41: [1 if kind == 'busy' else (5 if kind == 'mmc' else 0)], 1: [0], 16: [0],
                       58: [0, 0xc0 if kind == 'sdhc' else 0x80, 0xff, 0x80, 0]}
            response.extend(answers[command])
            frame.clear()
        def input_(port):
            return response.popleft() if response else 255
        d.m.set_output_callback(output)
        d.m.set_input_callback(input_)
        result = d.call('sdinit')
        if kind == 'busy':
            assert result != 0
            continue
        assert result == 0, kind
        assert d.get('sd_block_addressed', 1) == int(kind == 'sdhc'), kind
        ids = [c for c, _ in commands]
        if kind in ('sdhc', 'sdsc'):
            assert ids.index(41) < ids.index(58)
        if kind != 'sdhc':
            assert (16, 512) in commands, (kind, commands)


if __name__ == '__main__':
    tests = [value for name, value in list(globals().items()) if name.startswith('test_')]
    failures = []
    for test in tests:
        try:
            test()
            print('PASS:', test.__name__, flush=True)
        except Exception as exc:
            import traceback
            traceback.print_exc()
            failures.append(test.__name__)
    assert not failures, failures
    print(f'{len(tests)} test groups passed')
