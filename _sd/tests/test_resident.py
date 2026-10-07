"""Resident routines; build resident with --sym=resident_syms_new.txt first."""
import re
from test_fat_offsets import Driver, ROOT, SYMS, BODY

SYMS.update((name, int(value, 16)) for name, value in re.findall(
    r'^(\w+): EQU 0x([0-9A-Fa-f]+)$', (ROOT/'resident_syms_new.txt').read_text(), re.M))


def driver():
    d = Driver()
    d.m.set_memory_block(0x2000, (ROOT/'zc_sd_driver.bin').read_bytes())
    return d


def test_depacker():
    d = driver()
    d.m.set_memory_block(0, bytes(len(BODY)))
    assert d.call('drv_dos_swp') == 0
    assert bytes(d.m.memory[:len(BODY)]) == BODY
    assert bytes(d.m.memory[0x2000:0x2000+(ROOT/'zc_sd_driver.bin').stat().st_size]) == (ROOT/'zc_sd_driver.bin').read_bytes()


def test_free_chain():
    for broken in (False, True):
        d = driver()
        chain = [319, 500, 320, 1023]
        for i, n in enumerate(chain):
            d.fat(n, chain[i+1] if i+1 < len(chain) else 0x0ffffff8)
        d.cluster(chain[0])
        if broken:
            d.fail_reads.add(49+chain[0]//128)
            assert d.call('core_free_chain') != 0
            assert not [x for x in d.io if x[0].startswith('sdwrite')]
        else:
            assert d.call('core_free_chain') == 0
            for n in chain:
                sector, offset = divmod(n*4, 512)
                assert d.disk[49+sector][offset:offset+4] == bytes(4)


def test_file_abi():
    d = driver()
    d.put('rtc_cached', 1, 1)
    for s in range(49, 113):
        d.disk[s] = bytearray(512)
    d.fat(2, 0x0fffffff)
    d.disk[1017] = bytearray(512)
    d.disk[1018] = bytearray(512)
    d.put('root_cluster_lo', 2)
    d.put('next_search_valid', 1, 1)
    d.put('next_search_lo', 319)
    d.call('core_setroot')
    def arg(data):
        d.m.set_memory_block(0x9000, data+b'\0')
        d.m.hl = 0x9000
    arg(b'\0'+(1024).to_bytes(4, 'little')+b'Example long file.bin')
    d.m.ix = 0xabcd
    assert d.call('wrap_mkfile') == 0
    assert d.m.ix == 0xabcd
    arg(b'\0Example long file.bin')
    assert d.call('drv_fentry') == 1
    assert (d.m.de, d.m.hl) == (0, 1024)
    arg(b'\0Example long file.bin')
    d.m.set_memory_block(0x9200, b'Renamed long file.bin\0')
    d.m.de = 0x9200
    assert d.call('core_renam') == 1
    arg(b'\0Renamed long file.bin')
    assert d.call('drv_fentry') == 1
    arg(b'\0Example long file.bin')
    assert d.call('drv_fentry') == 0
    arg(b'\0Renamed long file.bin')
    assert d.call('core_delfl') == 1
    arg(b'\0Renamed long file.bin')
    assert d.call('drv_fentry') == 0


if __name__ == '__main__':
    for test in (test_depacker, test_free_chain, test_file_abi):
        test()
        print('PASS:', test.__name__)
