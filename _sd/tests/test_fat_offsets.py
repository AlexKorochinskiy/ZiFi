"""Run assembled driver routines with an in-memory block device.

Requires Python package z80 and a fresh body build with --sym=body_syms_new.txt.
Run: python tests/test_fat_offsets.py
SPI/DMA sector I/O is intercepted; FAT traversal and LOAD512 execute as Z80 code.
"""
from pathlib import Path
import re
import z80

ROOT = Path(__file__).resolve().parents[1]
SYMS = dict((name, int(value, 16)) for name, value in re.findall(
    r"^(\w+): EQU 0x([0-9A-Fa-f]+)$",
    (ROOT / 'body_syms_new.txt').read_text(), re.M))
BODY = (ROOT / 'zc_sd_driver_body.bin').read_bytes()


class Driver:
    def __init__(self):
        self.m = z80.Z80Machine()
        self.m.set_memory_block(0, BODY)
        self.disk = {}
        self.fail_reads = set()
        self.fail_writes = set()
        self.io = []
        self.ram = bytearray(256 * 16384)
        self.hooks = {SYMS[n]: n for n in
                      ('sdread_lba', 'sdread_lba_to', 'sdwrite_lba',
                       'sdwrite_lba_from', 'write_fsinfo_hint')}
        self.hooks.update({SYMS[n]: n for n in
                           ('sdwrite_multi_start', 'sdwrite_multi_block', 'sdwrite_multi_stop')})
        self.multi_lba = None
        for address in [0xff00, *self.hooks]:
            self.m.set_breakpoint(address)
        self.put('reserved_sectors', 32)
        self.put('fatsz32_lo', 64)
        self.put('addtop_lo', 17)
        self.put('data_start_lo', 1000)
        self.put('sectors_per_cluster', 2, 1)
        self.put('num_fats', 2, 1)

    def put(self, name, value, size=2):
        self.m.set_memory_block(SYMS[name], value.to_bytes(size, 'little'))

    def get(self, name, size=2):
        return int.from_bytes(self.m.memory[SYMS[name]:SYMS[name]+size], 'little')

    def cluster(self, value):
        self.put('cur_cluster_lo', value & 65535)
        self.put('cur_cluster_hi', value >> 16)

    def fat(self, cluster, value):
        sector, offset = divmod(cluster * 4, 512)
        block = self.disk.setdefault(49 + sector, bytearray(512))
        block[offset:offset+4] = value.to_bytes(4, 'little')

    def call(self, name):
        self.m.sp = 0xfef0
        self.m.set_memory_block(self.m.sp, b'\x00\xff')
        self.m.pc = SYMS[name]
        for _ in range(10000):
            self.m.ticks_to_stop = 100000
            self.m.run()
            if self.m.pc == 0xff00:
                return self.m.a
            hook = self.hooks.get(self.m.pc)
            if not hook:
                continue
            failed = False
            if hook == 'sdwrite_multi_start':
                p = SYMS['lba_arg']
                self.multi_lba = int.from_bytes(self.m.memory[p:p+4], 'big')
            elif hook == 'sdwrite_multi_stop':
                self.multi_lba = None
            elif hook == 'sdwrite_multi_block':
                assert self.multi_lba is not None
                p = SYMS['sdbuf']
                self.disk[self.multi_lba] = bytearray(self.m.memory[p:p+512])
                self.io.append((hook, self.multi_lba))
                self.multi_lba += 1
            elif hook != 'write_fsinfo_hint':
                lba = int.from_bytes(self.m.memory[SYMS['lba_arg']:SYMS['lba_arg']+4], 'big')
                self.io.append((hook, lba))
                failed = lba in (self.fail_reads if hook.startswith('sdread') else self.fail_writes)
                if failed:
                    pass
                elif hook == 'sdwrite_lba_from':
                    source = self.get('dma_xfer_page', 1)*16384 + (self.get('dma_xfer_off') & 16383)
                    self.disk[lba] = self.ram[source:source+512]
                elif hook == 'sdwrite_lba':
                    p = SYMS['sdbuf']
                    self.disk[lba] = bytearray(self.m.memory[p:p+512])
                elif hook == 'sdread_lba':
                    self.m.set_memory_block(SYMS['sdbuf'], self.disk[lba])
                    # Real sdread_lba resets the DMA destination to sdbuf.
                    self.put('dma_xfer_page', 15, 1)
                    self.put('dma_xfer_off', SYMS['sdbuf'])
                else:
                    dest = self.get('dma_xfer_page', 1)*16384 + (self.get('dma_xfer_off') & 16383)
                    self.ram[dest:dest+512] = self.disk[lba]
            self.m.af = 0x0100 if failed else 0x0040
            self.m.pc = int.from_bytes(self.m.memory[self.m.sp:self.m.sp+2], 'little')
            self.m.sp += 2
            if self.m.pc == 0xff00:
                return self.m.a
        raise AssertionError(f'{name}: execution did not return')


def test_offsets_and_links():
    d = Driver()
    for n in range(128):
        d.fat(256+n, 2000+n)
    for n in range(128):
        d.cluster(256+n)
        assert d.call('cluster_to_fatpos') == 0
        assert d.get('gnc_fatsec_lo') == 34
        assert d.get('gnc_inoff') == n*4, n
        d.call('get_next_cluster')
        assert d.get('chain_ended', 1) == 0
        assert d.get('cur_cluster_lo') == 2000+n, n
    for n in (65535, 65536, 0x123456):
        d.put('fatsz32_lo', 65535)
        d.cluster(n)
        assert d.call('cluster_to_fatpos') == 0
        sector = d.get('gnc_fatsec_lo') | d.get('gnc_fatsec_hi') << 16
        assert sector == 32 + n//128
        assert d.get('gnc_inoff') == (n % 128)*4


def test_write_and_allocation():
    for n in range(128):
        d = Driver()
        original = bytearray(b'\x55\x55\x55\xa5'*128)
        d.disk[51] = original[:]
        d.cluster(256+n)
        d.put('new_val_lo', 0x3456)
        d.put('new_val_hi', 0x0123)
        assert d.call('write_fat_entry') == 0
        expected = original[:]
        expected[n*4:n*4+4] = b'\x56\x34\x23\xa1'
        assert d.disk[51] == expected, n
        assert d.disk[115] == expected, n
    for start, free in ((319, 320), (320, 321), (356, 357), (383, 384)):
        d = Driver()
        for n in range(256, 512):
            d.fat(n, 0x0fffffff)
        d.fat(free, 0)
        d.put('next_search_valid', 1, 1)
        d.put('next_search_lo', start)
        assert d.call('find_free_cluster') == 0
        assert d.get('free_cluster_lo') == free, (start, free)


def test_fragmented_load():
    d = Driver()
    chain = [319, 500, 320, 1023, 384, 383, 356, 256] * 1
    # 40 non-adjacent clusters, 40 KiB: crosses FAT sectors and RAM pages.
    chain += [1300 + n*137 for n in range(32)]
    expected = bytearray()
    for index, cluster in enumerate(chain):
        d.fat(cluster, chain[index+1] if index+1 < len(chain) else 0x0fffffff)
        for sector in range(2):
            data = bytearray((index*19 + sector*71 + i) % 256 for i in range(512))
            d.disk[1017+(cluster-2)*2+sector] = data
            expected.extend(data)
    d.cluster(chain[0])
    d.call('stream_open')
    d.m.c, d.m.hl = 32, 0x4000
    for count in (13, 27, 40):
        d.m.b = count
        assert d.call('core_load512') == 0
    assert d.ram[32*16384:32*16384+len(expected)] == expected
    assert (d.m.c, d.m.hl) == (34, 0x6000)
    d.m.b = 1
    assert d.call('core_load512') == 15


if __name__ == '__main__':
    for test in (test_offsets_and_links, test_write_and_allocation, test_fragmented_load):
        test()
        print(f'PASS: {test.__name__}')
