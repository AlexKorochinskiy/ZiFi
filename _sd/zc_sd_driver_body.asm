		DEVICE ZXSPECTRUM48

; zc_sd_driver_body.asm -- the "packed body" half of zc_sd_driver.asm,
; split out so it can be compressed (ZX0, backward mode) and depacked
; at runtime by drv_dos_swp in the main driver file, freeing enough
; room in the resident #2000-#3FFF window for DELFL/RENAM.
; See [[project-zifi-custom-sd-driver]].
;
; Assembled standalone to compute this code's TRUE final runtime
; addresses (needed both for the compressor's input and so the main
; driver file can reference these labels via body_syms.inc, generated
; from this file's own --sym dump). NOT block-loaded directly by
; spgbld -- only zc_sd_driver.bin (built from the main file) is.
;
; ORG #0000: nothing here needs to avoid the RST vectors (#0000-#0038)
; -- this driver never executes an RST instruction (confirmed via
; grep), and real interrupts are held off (di) for the entire window
; page #0F is mapped into slot 0, including through drv_dos_swp's own
; unpack call, so there's no IM1/IM2 vector-table conflict either.
;
; Historical note: zifi.asm's own load_ini (reading zifi.ini at boot)
; used to call the real LOAD512 with HL=#0000/PAGE3, directly
; clobbering this body's own code at address 0 (confirmed empirically,
; and root-caused to load_ini sharing a "quick scratch = address 0"
; assumption inherited from the ORIGINAL closed WDFCVBI2.COD, whose
; own depacked body lived up near #3C00, never touching #0000 at all
; -- confirmed via a real disassembly of WDFCVBI2.COD's own DOS_SWP).
; Tried fixing this from THIS side first (a sacrifice_buf filler, then
; an ORG shift to #0200) -- both reliably broke BOTH Z80 Hrust decoders
; tried (root cause never found, not a transcription bug either time).
; Fixed instead on the zifi.asm side: load_ini/parse_ini now use
; LOAD512's SAME slot-1/#4000/PAGE1 convention as SAVE512 (see
; core_load512's own comment below), so nothing ever touches address 0
; here anymore -- ORG #0000 is safe again, no shift/buffer needed.
		ORG #0000

CONF		EQU #77
DATA		EQU #57

sdinit		call csh
		ld de,512+10
		call cycl

		ld de,8000
1		dec de
		ld a,d
		or e
		jp z,sdinit_fail
		call do_cmd0
		jr nz,1b
		dec a
		jp nz,1b

		call do_cmd8
		push af
		ld bc,DATA
		in e,(c)
		in e,(c)
		in h,(c)
		in l,(c)
		pop af
		jr nz,1b
		bit 2,a
		jr z,sd_v2

;--- legacy path: SDv1 (ACMD41) then MMC (CMD1) ---
		ld de,8000
2		dec de
		ld a,d
		or e
		jr z,3f
		ld h,0
		call do_acmd41
		jr nz,2b
		cp 1
		jr z,2b
		or a
		jr nz,3f
		jr sd_fbs

3		ld de,8000
4		dec de
		ld a,d
		or e
		jr z,sdinit_fail
		call do_cmd1
		jr nz,4b
		cp 1
		jr z,4b
		or a
		jr nz,sdinit_fail

sd_fbs		call do_cmd16
		jr nz,sdinit_fail
		or a
		jr nz,sdinit_fail
		jr sdinit_ok

sd_v2		ld de,#01aa
		or a
		sbc hl,de
		jr nz,sdinit_fail

		ld de,8000
5		dec de
		ld a,d
		or e
		jr z,sdinit_fail
		ld h,#40
		call do_acmd41
		jr nz,5b
		cp 1
		jr z,5b
		or a
		jr nz,sdinit_fail

		; ACMD41 just succeeded (card left the busy state) -- read
		; its OCR (4 more bytes, MSB-first) for the REAL CCS bit
		; (bit 30 = bit 6 of the first byte) instead of assuming
		; every card that speaks the v2 protocol is block-addressed.
		; A genuine SDv2 card can still be an SDSC (<=2GB) card. See
		; [[project-zifi-custom-sd-driver]].
		ld bc,DATA
		in a,(c)
		bit 6,a
		jr z,sd_v2_ocr_rest
		ld a,1
		ld (sd_block_addressed),a
sd_v2_ocr_rest	in a,(c)	; discard the remaining 3 OCR bytes
		in a,(c)
		in a,(c)

sdinit_ok	call csh
		xor a
		ret

sdinit_fail	call csh
		xor a
		inc a
		ret

;--- set_lba32: HL=bits31-16, DE=bits15-0 -> stores into lba_arg (MSB
;--- first). Do this BEFORE calling sdread_lba, not with the LBA sitting
;--- in registers across the call -- csl calls wait, which uses DE as a
;--- busy-loop counter and never restores it, so DE (and only DE) comes
;--- back scrambled. That's exactly what broke the register-argument
;--- version earlier: H/L survived, D/E didn't. Routing the argument
;--- through memory instead sidesteps the whole problem. ---
set_lba32	ld a,h
		ld (lba_arg),a
		ld a,l
		ld (lba_arg+1),a
		ld a,d
		ld (lba_arg+2),a
		ld a,e
		ld (lba_arg+3),a
		ret

lba_arg		ds 4

;--- lba_guard_check: the just-set lba_arg (4 bytes, H,L,D,E big-endian
;--- order per set_lba32) against sd_lba_max_hi/lo. Carry SET = in
;--- range (OK), carry CLEAR = out of range (refuse) -- same 32-bit-
;--- compare shape as cluster_to_fatpos's own bounds check. This is the
;--- LBA-range guard from the Zuma article's §34.2: a byte-addressing-
;--- vs-block-addressing mixup sending a CMD17 argument 512x too large
;--- has bricked a card until power-cycle on this exact hardware family
;--- before (needing a real power cycle to recover, same symptom this
;--- project's own interface-2 CS_ON experiment hit) -- refusing
;--- locally, before the request ever reaches the card, is the safety
;--- net for that whole class of bug. Checked inside sdread_lba/
;--- sdwrite_multi_start themselves (not every set_lba32 call site) so
;--- it can't be bypassed by a future caller that forgets to check it. ---
lba_guard_check
		ld a,(lba_arg+2)
		ld h,a
		ld a,(lba_arg+3)
		ld l,a
		ld de,(sd_lba_max_lo)
		or a
		sbc hl,de
		ld a,(lba_arg+0)
		ld h,a
		ld a,(lba_arg+1)
		ld l,a
		ld de,(sd_lba_max_hi)
		sbc hl,de
		ret

;=====================================================================
; Card addressing mode (SDSC byte-addressed vs SDHC/SDXC block-
; addressed) -- see [[project-zifi-custom-sd-driver]]. Every card this
; project has hardware-tested on is block-addressed (>=4GB); this only
; matters for a genuine old/small SDSC (<=2GB) card, which interprets
; the same CMD17/18/24/25 argument as a byte offset, not a sector
; number -- sending a raw sector number to one would silently read/
; write from the wrong place (off by a factor of 512).
;=====================================================================
sd_block_addressed	db 0	; 0=byte-addressed (SDSC/legacy default),
				; 1=block-addressed (SDHC/SDXC, set only
				; after a confirmed CCS=1 in sdinit)
card_arg		ds 4

;--- compute_card_arg: converts lba_arg (32-bit sector number, MSB-
;--- first) into card_arg (the actual bytes to send as the CMD17/18/24/
;--- 25 argument) -- identical to lba_arg when sd_block_addressed=1,
;--- or lba_arg<<9 (sector number -> byte offset, 512=2^9) when 0. Any
;--- legitimate SDSC-range sector number's top byte is always 0 (max
;--- ~4,194,304 sectors for a 2GB card fits in 23 bits), so shifting
;--- left by a full byte first (dropping the original top byte) then
;--- one more bit is exact, not lossy, for every value this path can
;--- actually be reached with. ---
compute_card_arg
		ld a,(sd_block_addressed)
		or a
		jr z,cca_shift
		ld hl,lba_arg
		ld de,card_arg
		ld bc,4
		ldir
		ret
cca_shift	ld a,(lba_arg+3)	; e = bits7-0
		ld e,a
		ld a,(lba_arg+2)	; d = bits15-8
		ld d,a
		ld a,(lba_arg+1)	; c = bits23-16
		ld c,a
		; (lba_arg+0, bits31-24, is always 0 here -- dropped by the
		; byte-shift below, see header comment)
		ld b,c			; shift left by one whole byte:
		ld c,d			; b=old c, c=old d, d=old e, e=0
		ld d,e
		ld e,0
		sla e			; then one more bit, 32-bit-wide,
		rl d			; LSB-first chain (e -> d -> c -> b)
		rl c
		rl b
		ld a,b
		ld (card_arg+0),a
		ld a,c
		ld (card_arg+1),a
		ld a,d
		ld (card_arg+2),a
		ld a,e
		ld (card_arg+3),a
		ret

;=====================================================================
; DMA-accelerated 512-byte SPI<->sdbuf transfer, replacing the original
; CPU IN/OUT byte loops (each ~40+ T-states/byte, vs. DMA moving the
; whole 256-word block in hardware). Register map and calling
; convention confirmed against a REAL working example in this exact
; SDK, per the user's own pointer: E:\zx-evo-master\pentevo\sdk\
; ft812sdk\lib\esp32\esp32.c's esp_send_dma/esp_recv_dma -- and that
; file's own SPI_CTRL/SPI_DATA ports (confirmed via its tsconf.h:
; __sfr __at 0x77 SPI_CTRL, __at 0x57 SPI_DATA) are the EXACT SAME
; ports this driver's CONF/DATA already use -- same shared SPI/DMA
; hardware, just talking to whichever device is currently CS-selected
; (SD here, ESP32 there). No address-alignment requirement appears
; anywhere in that reference code (plain 16-bit address + a separate
; page byte) -- the "must be 512-aligned" note from WC's own SD_ZC.ASM
; investigated earlier in this project looks like WC's own internal
; simplification, not a real hardware constraint, so sdbuf's existing
; (unaligned) address is used as-is.
;
; DMASADDR/DMADADDR = 16-bit address (L/H) + a separate page byte.
; DMALEN = (length_in_bytes/2)-1 (per-unit length in WORDS: 512/2-1=
; 255). DMANUM = (unit_count)-1 -- always 0 here (one 512-byte sector
; per call), matching this driver's existing per-sector cluster-chain-
; following structure; DMANUM>0 would need physically contiguous
; sectors, not guaranteed across a cluster boundary.
;
; Caller contract: send the command/argument bytes and consume the
; response/data token via the CPU as before (di/ei-protected CORE entry
; already covers this, see the wrap_* functions) -- these two helpers
; ONLY replace the raw byte-shuffling loop, nothing else about the SD
; protocol. BC is left pointing at dma_ctr on return, NOT at DATA --
; callers that go on to bang more bytes on DATA must reload BC.
;=====================================================================
own_page	equ #0f		; this driver's own physical page, matching
				; zifi.asm's own "sd_driver_page equ #0f"
				; (which we can't reference directly -- that
				; constant lives in zifi.asm, not this file)
dma_daddrl	equ #1daf
dma_daddrh	equ #1eaf
dma_daddrx	equ #1faf
dma_saddrl	equ #1aaf
dma_saddrh	equ #1baf
dma_saddrx	equ #1caf
dma_len		equ #26af
dma_num		equ #28af
dma_ctr		equ #27af

;--- dma_xfer_off/dma_xfer_page: the shared DMA target address, set by
;--- the caller right before calling dma_recv_ext/dma_send_ext below --
;--- sdread_lba/sdwrite_multi_block point it at the fixed sdbuf/own_page
;--- pair for the general-purpose SD<->sdbuf path; core_save512/
;--- core_load512 (via stream_write_sector_from/stream_read_sector_to)
;--- point it at the CALLER's own page+offset instead, DMAing the
;--- 512-byte payload DIRECTLY between the SD card and that memory,
;--- bypassing sdbuf AND the page1_port/LDIR dance entirely. That LDIR
;--- needed PAGE1 mapped to the caller's page for the whole copy -- but
;--- PAGE1 is also one of the pages set_music_pages_lite repages on
;--- every interrupt during playback (zifi.asm's pt_play), and there's
;--- no way to restore a write-only page port after an interrupt
;--- clobbers it. DMA addresses RAM by physical page number directly,
;--- never touching the CPU's slot mapping at all, so it's immune to
;--- this regardless of what any interrupt does to PAGE0/1/3 in the
;--- meantime -- matching how the original closed WDFCVBI2.COD driver's
;--- own LOAD512/SAVE512 worked (confirmed via disassembly to use this
;--- same DMA mechanism, and to need zero di/ei protection because of
;--- it). See [[project-zifi-custom-sd-driver]] "noise mixed with
;--- melody".
;---
;--- The high byte IS masked to the low 6 bits (AND #3F) here -- the
;--- earlier assumption that the DMA hardware itself truncates a raw
;--- address to 14 bits turned out to be unverified for an address with
;--- H>=#40: sdbuf's own address never exercised that case (this whole
;--- compressed body sits under #2100, H always <#40 there already, so
;--- masking or not made no observable difference for the sdbuf/
;--- own_page path) -- it only ever LOOKED confirmed for that reason. A
;--- slot-1 address like #4000-#7FFF (exactly what ZiFi's own SAVE512/
;--- LOAD512 callers pass) has H in #40-#7F, where an unmasked write
;--- puts the WRONG high offset byte on the DMA port (off by a whole
;--- #4000) -- caught immediately on real testing via "Error parsing
;--- ini file" (load_ini's own LOAD512 call, HL=#4000). WC's own
;--- DSDZC.ASM computes the equivalent value via repeated SUB #40 (H mod
;--- #40); AND #3F is arithmetically identical and much cheaper here
;--- since only a single 16KB-aligned page ever matters. ---
dma_xfer_off	dw 0
dma_xfer_page	db 0

;--- set_dma_sdbuf: points dma_xfer_off/page at the fixed sdbuf/own_page
;--- pair -- shared by sdread_lba/sdwrite_multi_block/sdwrite_lba
;--- instead of each inlining the same 4 instructions. ---
set_dma_sdbuf	ld hl,sdbuf
		ld (dma_xfer_off),hl
		ld a,own_page
		ld (dma_xfer_page),a
		ret

dma_set_addr_ext
		ld b,h
		ld c,l
		ld a,(dma_xfer_off)
		out (c),a
		inc b
		ld a,(dma_xfer_off+1)
		and #3f
		out (c),a
		inc b
		ld a,(dma_xfer_page)
		out (c),a
		ret

dma_recv_ext	ld hl,dma_daddrl
		call dma_set_addr_ext
		ld bc,dma_len
		ld a,255
		out (c),a
		ld bc,dma_num
		xor a
		out (c),a
		ld bc,dma_ctr
		ld a,#42
		out (c),a
		jr dma_wait

dma_send_ext	ld hl,dma_saddrl
		call dma_set_addr_ext
		ld bc,dma_len
		ld a,255
		out (c),a
		ld bc,dma_num
		xor a
		out (c),a
		ld bc,dma_ctr
		ld a,#c2
		out (c),a
		; falls into dma_wait

dma_wait	in a,(c)		; dma_ctr/dma_status share one port
		add a,a			; bit7 (busy) into carry
		jr c,dma_wait
		ret

;--- sdread_lba: read the sector set via set_lba32 into sdbuf (sets the
;--- DMA target to the fixed sdbuf/own_page pair, then falls into
;--- sdread_lba_to's shared command-sending+DMA logic). ---
sdread_lba	call set_dma_sdbuf
		; falls into sdread_lba_to

;--- sdread_lba_to: same read, but DMAs the 512-byte payload directly to
;--- whatever (dma_xfer_page,dma_xfer_off) is CURRENTLY set to --
;--- sdread_lba (above) points it at sdbuf/own_page first; a caller that
;--- wants it to land elsewhere (core_load512's path, via
;--- stream_read_sector_to) sets those two variables itself and calls
;--- this entry point directly, skipping the sdbuf default. Same
;--- instruction shape as the original hardcoded-immediate version that
;--- was first proven to work (out (c),a for every byte) -- only the
;--- source of each A load differs (memory instead of an immediate). ---
sdread_lba_to	ld a,%01000000+17
		ld (cmdlba_op),a
		call send_cmd_lba
		jp nc,sdread_lba_oob
		; falls into sdread_common

sdread_common	call resp
		or a
		jr nz,sdread_fail

		call wtdo
		cp #fe
		jr nz,sdread_fail

		call dma_recv_ext

		in a,(DATA)
		in a,(DATA)

		call csh
		xor a
		ret

sdread_fail	call csh
		xor a
		inc a
		ret

sdread_lba_oob	; out-of-range LBA refused before ever touching the SPI
		; bus (no csh needed -- nothing was selected)
		xor a
		inc a
		ret

;--- CMD25 (WRITE_MULTIPLE_BLOCK) write, split into three pieces so a
;--- run of CONSECUTIVE sectors (e.g. zero-filling a whole cluster) can
;--- share ONE open session instead of paying the full CMD25-open +
;--- R1-wait + stop-token + settling-reads + busy-wait overhead on
;--- EVERY sector -- a real problem hit in practice: zero-filling a
;--- 64-sector cluster one full session per sector was slow enough to
;--- feel like a hang. NOT CMD24 (single-block write), which this used
;--- at first and failed on real hardware. Ported from WC core32's own
;--- SDDSE/SAVDS (SD_ZC.ASM), the proven, shipped write path on this
;--- hardware: it never uses CMD24 at all, always CMD25 even for a
;--- single sector, with data token 0xFC (not CMD24's 0xFE) and a
;--- trailing stop token 0xFD + settling reads. Mirrors the read side's
;--- own lesson (CMD18 was proven unstable, CMD17 wasn't) -- for writes
;--- the roles are reversed: don't assume CMD24 by analogy, port what's
;--- actually shipped.
;---
;--- sdwrite_multi_start: opens a session at the sector set via
;--- set_lba32. Follow with 1+ calls to sdwrite_multi_block (each
;--- writing sdbuf as the NEXT consecutive sector) and then exactly one
;--- call to sdwrite_multi_stop. A=0 ok, A=1 fail. ---
sdwrite_multi_start
		ld a,%01000000+25	; CMD25 = WRITE_MULTIPLE_BLOCK
		ld (cmdlba_op),a
		call send_cmd_lba
		jp nc,sdread_lba_oob	; shared with sdread's own OOB path --
					; both just refuse before touching SPI
		call resp
		or a
		jp nz,sdread_fail
		call wait
		xor a
		ret

;--- send_cmd_lba: shared CMD-framing sequence for sdread_lba_to's CMD17
;--- and sdwrite_multi_start's CMD25 -- identical apart from the opcode
;--- byte (set by the caller into cmdlba_op first). Checks the LBA
;--- range, computes card_arg, selects the card, and sends the 6-byte
;--- command frame (opcode + card_arg's 4 bytes + trailing 0xFF CRC
;--- placeholder). Carry SET = sent, NC = out of range (nothing was
;--- selected, caller should bail to sdread_lba_oob). ---
cmdlba_op	db 0

send_cmd_lba	call lba_guard_check
		ret nc
		call compute_card_arg
		call csh
		call csl
		ld bc,DATA
		ld a,(cmdlba_op)
		out (c),a
		ld hl,card_arg
		ld a,(hl)
		out (c),a
		inc hl
		ld a,(hl)
		out (c),a
		inc hl
		ld a,(hl)
		out (c),a
		inc hl
		ld a,(hl)
		out (c),a
		ld a,#ff
		out (c),a
		scf
		ret

;--- sdwrite_multi_block: writes sdbuf as the next block of an open
;--- session (sets the DMA source to the fixed sdbuf/own_page pair, then
;--- falls into sdwrite_multi_block_from's shared token+DMA+response
;--- logic). Does NOT send CMD25 or the stop token. A=0 ok, A=1 fail. ---
sdwrite_multi_block
		call set_dma_sdbuf
		; falls into sdwrite_multi_block_from

;--- sdwrite_multi_block_from: same write, but DMAs the 512-byte payload
;--- directly FROM whatever (dma_xfer_page,dma_xfer_off) is CURRENTLY
;--- set to -- sdwrite_multi_block (above) points it at sdbuf/own_page
;--- first; a caller that wants it sourced elsewhere (core_save512's
;--- path, via stream_write_sector_from) sets those two variables itself
;--- and calls this entry point directly. Caller must have already
;--- opened a session via sdwrite_multi_start. Token 0xFC + 512 bytes +
;--- CRC placeholder + response token + busy-wait. Does NOT send CMD25
;--- or the stop token. A=0 ok, A=1 fail. ---
sdwrite_multi_block_from
		ld bc,DATA
		ld a,#fc		; data token for a CMD25 block (0xFC, not 0xFE)
		out (c),a

		call dma_send_ext

		ld bc,DATA		; dma_send_ext left BC pointing at the DMA
					; control port, not DATA -- restore it before
					; the CRC bytes/response-token read below
		ld a,#ff		; 2 dummy CRC bytes (CRC checking is off)
		out (c),a
		out (c),a

2		in a,(c)		; data response token: skip leading idle 0xFF
		cp #ff			; bytes first (matches WC's own DRESP)
		jr z,2b
		and #1f			; xxx0AAA1, AAA=010 accepted
		cp #05
		jp nz,sdread_fail

		call wait		; busy while this block programs
		xor a
		ret

;--- sdwrite_multi_stop: sends the stop-transmission token, settles,
;--- waits for busy to clear, and deselects. Closes a session opened by
;--- sdwrite_multi_start. A=0 always. ---
sdwrite_multi_stop
		ld bc,DATA
		ld a,#fd		; stop transmission token
		out (c),a
		ld b,16			; settling reads (matches WC's SNB)
1		in a,(c)
		djnz 1b
		call wait

		call csh
		xor a
		ret

;--- sdwrite_lba: write the sector set via set_lba32 from sdbuf, as a
;--- lone single-sector session (start+block+stop). For a run of
;--- consecutive sectors, use sdwrite_multi_start/_block/_stop directly
;--- instead to share one session. A=0 ok, A=1 fail. ---
sdwrite_lba	call set_dma_sdbuf
		; falls into sdwrite_lba_from

;--- sdwrite_lba_from: same write, but via sdwrite_multi_block_from --
;--- the DMA-direct-to-caller-memory path used by
;--- stream_write_sector_from. sdwrite_lba (above) points the DMA source
;--- at sdbuf/own_page first; falling straight through here reuses the
;--- exact same session-open/block/stop sequence either way. ---
sdwrite_lba_from
		call sdwrite_multi_start
		or a
		jp nz,sdread_fail
		call sdwrite_multi_block_from
		or a
		jp nz,sdread_fail
		jp sdwrite_multi_stop

;--- low-level primitives ---
csh		push bc
		push af
		ld bc,CONF
		ld a,%00000011
		out (c),a
		ld bc,DATA
		ld a,#ff
		out (c),a
		pop af
		pop bc
		ret

csl		push bc
		push af
		ld bc,CONF
		ld a,%00000001
		out (c),a
		ld bc,DATA
		ld a,#ff
		out (c),a
		pop af
		pop bc
		jp wait

wait		push bc
		push af
		ld bc,DATA
		ld de,60000
1		in a,(c)
		inc a
		jr z,2f
		dec de
		ld a,d
		or e
		jr nz,1b
2		pop af
		pop bc
		ret

wtdo		push bc
		push de
		ld bc,DATA
		ld de,60000
1		in a,(c)
		cp #ff
		jr nz,2f
		dec de
		ld a,d
		or e
		jr nz,1b
2		pop de
		pop bc
		ret

resp		push de
		push bc
		ld bc,DATA
		ld d,10
1		in a,(c)
		bit 7,a
		jr z,2f
		dec d
		jr nz,1b
		inc d
2		pop bc
		pop de
		ret

cycl		; DE = number of #FF clock bytes to send
		ld bc,DATA
1		ld a,#ff
		out (c),a
		dec de
		ld a,d
		or e
		jr nz,1b
		ret

cmd00		db %01000000+0,0,0,0,0,#95
cmd08		db %01000000+8,0,0,1,#aa,#87
cmd16		db %01000000+16,0,0,2,0,#ff

do_cmd0		ld hl,cmd00
		jp send_frame
do_cmd8		ld hl,cmd08
		jp send_frame
do_cmd16	ld hl,cmd16
		jp send_frame
do_cmd1		ld a,%01000000+1
		call cmdo
		jp resp
do_cmd55	ld a,%01000000+55
		call cmdo
		jp resp

;--- send a pre-built 6-byte command frame pointed to by HL ---
send_frame	call csh
		call csl
		ld bc,DATA
		outi
		outi
		outi
		outi
		outi
		outi
		jp resp

;--- send a simple command: A=opcode, all-zero args, CRC=#FF ---
cmdo		call csh
		call csl
cmdx		ld bc,DATA
		out (c),a
		xor a
		out (c),a
		out (c),a
		out (c),a
		out (c),a
		ld a,#ff
		out (c),a
		ret

;--- ACMD41: H = argument high byte (0, or #40 for HCS), rest zero ---
do_acmd41	call do_cmd55
		call csh
		call csl
		ld bc,DATA
		ld a,%01000000+41
		out (c),a
		out (c),h
		xor a
		out (c),a
		out (c),a
		out (c),a
		ld a,#ff
		out (c),a
		jp resp

;=====================================================================
; FAT32 geometry: parse the BPB (sdbuf must hold sector 0) and locate
; the root directory sector, then scan it for a "ZIFI" 8.3 entry.
;=====================================================================

;--- addtop_hi/lo: LBA offset of the FAT32 volume within the whole
;--- device (0 unless a partition table was found). WC core32's HDD
;--- calls this ADDTOP and adds it via XSPOZ to every sector number it
;--- reads (FAT sectors, data-cluster sectors, the BPB itself) -- SD
;--- cards vary on whether they even have a partition table at all
;--- (this project's own card doesn't -- BPB sits directly at LBA0). ---

addtop_hi	dw 0
addtop_lo	dw 0

;--- add_addtop: HL:DE (32-bit sector, hi:lo) += (addtop_hi:addtop_lo).
;--- Call this right before set_lba32 for any FAT-area or data-cluster
;--- sector -- NOT for the values stored in root_dir_hi/lo, data_start_
;--- hi/lo etc, which stay partition-relative (matching WC's own SDFAT/
;--- BFTSZ convention: ADDTOP is added only at actual read time). ---
add_addtop	push bc
		ld bc,(addtop_lo)
		ex de,hl
		add hl,bc
		ex de,hl
		ld bc,(addtop_hi)
		adc hl,bc
		pop bc
		ret

;--- detect_partition: sdbuf must already hold sector 0. Scans up to 4
;--- MBR partition entries (offset 446, 16 bytes each) for a FAT32 type
;--- byte (0x0B or 0x0C). If found, sets addtop_hi/lo to that
;--- partition's start LBA and re-reads its first sector into sdbuf (the
;--- real BPB). If the 55 AA signature is missing or no entry matches,
;--- addtop_hi/lo stays 0 and sdbuf is left untouched -- the original
;--- sector 0 is then treated as the BPB directly, matching a card
;--- formatted without any partition table (confirmed: what this
;--- project's own card does). Doesn't follow extended-partition chains
;--- (type 0x05/0x0F) -- rare enough on an SD card that it's an accepted
;--- simplification for now, not full MBR support.
;---
;--- A raw FAT32 BPB (no partition table at all) also ends in 55 AA --
;--- every valid boot sector does -- so a "partition type" match here
;--- could be a false positive: the reserved bytes at offset 446-509 of
;--- a real BPB could coincidentally contain 0x0B/0x0C at one of the 4
;--- checked spots. So a tentative match is only trusted if re-reading
;--- that sector ALSO passes verify_fat32; otherwise this falls back to
;--- the original sector 0 (kept in sec0_copy) with ADDTOP=0. A=0 unless
;--- even the fallback read failed outright (shouldn't happen -- sdbuf
;--- already held sector 0 successfully before this was ever called). ---
sec0_copy	ds 512

detect_partition
		xor a
		ld (addtop_hi),a
		ld (addtop_hi+1),a
		ld (addtop_lo),a
		ld (addtop_lo+1),a

		ld hl,sdbuf
		ld de,sec0_copy
		ld bc,512
		ldir

		ld a,(sdbuf+510)
		cp #55
		jr nz,dp_none
		ld a,(sdbuf+511)
		cp #aa
		jr nz,dp_none

		ld hl,sdbuf+446
		ld b,4
dp_loop		ld (dp_entry),hl
		push hl
		ld de,4
		add hl,de
		ld a,(hl)
		pop hl
		cp #0b
		jr z,dp_found
		cp #0c
		jr z,dp_found
		ld de,16
		add hl,de
		djnz dp_loop
dp_none		xor a
		ret

dp_found	ld hl,(dp_entry)
		ld de,8
		add hl,de		; hl -> LBA-start field (entry+8, 4 bytes LE)
		ld a,(hl)
		ld (addtop_lo),a
		inc hl
		ld a,(hl)
		ld (addtop_lo+1),a
		inc hl
		ld a,(hl)
		ld (addtop_hi),a
		inc hl
		ld a,(hl)
		ld (addtop_hi+1),a

		ld hl,(addtop_hi)
		ld de,(addtop_lo)
		call set_lba32
		call sdread_lba
		or a
		jr nz,dp_fallback

		call verify_fat32
		or a
		ret z			; genuinely looks like a BPB -- keep it

dp_fallback	xor a
		ld (addtop_hi),a
		ld (addtop_hi+1),a
		ld (addtop_lo),a
		ld (addtop_lo+1),a
		ld hl,sec0_copy
		ld de,sdbuf
		ld bc,512
		ldir
		xor a
		ret

dp_entry	dw 0

;--- verify_fat32: sdbuf must hold sector 0. A=0 if this really looks like
;--- a FAT32 volume, A=1 if not (don't trust the rest of the parsed BPB
;--- fields, and don't attempt the FAT32-only root-dir-by-cluster walk).
;--- SD cards vary a lot card to card -- checks the boot sector 55 AA
;--- signature, that BytesPerSector is actually 512 (not every device
;--- uses that), and that FATSz16 (offset 22-23) is 0 -- FAT32 always
;--- routes the FAT size through FATSz32 (offset 36) instead and zeroes
;--- the legacy FAT16-only field, so a nonzero FATSz16 means this is
;--- FAT12/FAT16, not FAT32, and the rest of this driver doesn't apply.
;--- Also checks RootEntryCount==0 (another FAT16-only field FAT32
;--- always zeroes), SectorsPerCluster is a nonzero power of 2 (as the
;--- spec requires), and FATSz32 itself is nonzero -- all cross-checked
;--- against WC core32's own HDD routine, which performs exactly these
;--- same checks before trusting a BPB. ---
verify_fat32	ld a,(sdbuf+510)
		cp #55
		jr nz,vf_bad
		ld a,(sdbuf+511)
		cp #aa
		jr nz,vf_bad

		ld hl,(sdbuf+11)	; BytesPerSector
		ld de,512
		or a
		sbc hl,de
		jr nz,vf_bad

		ld hl,(sdbuf+22)	; FATSz16 -- must be 0 on FAT32
		ld a,h
		or l
		jr nz,vf_bad

		ld hl,(sdbuf+17)	; RootEntryCount -- must be 0 on FAT32
		ld a,h			; (a leftover FAT12/16 field FAT32 zeroes)
		or l
		jr nz,vf_bad

		ld a,(sdbuf+13)		; SectorsPerCluster must be a nonzero
		or a			; power of 2 (1,2,4,...,128) -- test via
		jr z,vf_bad		; V & (V-1) == 0
		ld b,a
		dec a
		and b
		jr nz,vf_bad

		ld hl,(sdbuf+36)	; FATSz32 must be nonzero (32-bit)
		ld a,h
		or l
		jr nz,vf_ok
		ld hl,(sdbuf+38)
		ld a,h
		or l
		jr z,vf_bad

vf_ok		xor a
		ret

vf_bad		xor a
		inc a
		ret

;--- parse_bpb: reads BPB fields out of sdbuf (offsets per the standard
;--- FAT32 BPB layout), computes DataStartSector and RootDirSector as
;--- true 32-bit values, and fills diag_buf for on-screen display.
;--- FATSz32 alone can be tens of thousands of sectors on a real card
;--- (30MB+ FAT tables are normal) -- ReservedSectorCount + NumFATs*
;--- FATSz32 overflowed 16 bits on the first try (32 + 2*59430 =
;--- 118892 > 65535), silently wrapping to a wrong-but-in-range sector
;--- that just happened to read back as all zeroes. All the sector-
;--- number math below uses ADC HL,DE across (hi,lo) 16-bit halves. ---

diag_buf	ds 20

parse_bpb	ld hl,(sdbuf+32)	; TotalSectors32 low16 (u32 @ offset 32)
		ld (total_sectors_lo),hl
		ld hl,(sdbuf+34)	; TotalSectors32 high16
		ld (total_sectors_hi),hl

		ld hl,(sdbuf+14)	; ReservedSectorCount (u16)
		ld (reserved_sectors),hl
		ld a,h
		ld (diag_buf+0),a
		ld a,l
		ld (diag_buf+1),a

		ld hl,(sdbuf+48)	; FSInfoSector (u16, sector # within volume)
		ld (fsinfo_sector),hl

		ld a,(sdbuf+16)		; NumFATs (u8)
		ld (num_fats),a
		ld (diag_buf+2),a

		ld a,(sdbuf+13)		; SectorsPerCluster (u8)
		ld (sectors_per_cluster),a
		ld (diag_buf+3),a

		ld hl,(sdbuf+38)	; FATSz32 high16
		ld (fatsz32_hi),hl
		ld a,h
		ld (diag_buf+4),a
		ld a,l
		ld (diag_buf+5),a
		ld hl,(sdbuf+36)	; FATSz32 low16
		ld (fatsz32_lo),hl
		ld a,h
		ld (diag_buf+6),a
		ld a,l
		ld (diag_buf+7),a

		ld hl,(sdbuf+46)	; RootCluster high16
		ld (root_cluster_hi),hl
		ld a,h
		ld (diag_buf+8),a
		ld a,l
		ld (diag_buf+9),a
		ld hl,(sdbuf+44)	; RootCluster low16
		ld (root_cluster_lo),hl
		ld a,h
		ld (diag_buf+10),a
		ld a,l
		ld (diag_buf+11),a

		; NumFATs * FATSz32 (32-bit product via repeated 32-bit add --
		; NumFATs is always tiny, 1 or 2, so this is at most 2 iterations)
		ld hl,0
		ld (prod_lo),hl
		ld (prod_hi),hl
		ld a,(num_fats)
		or a
		jr z,mul1_done
		ld b,a
mul1_loop	ld hl,(prod_lo)
		ld de,(fatsz32_lo)
		add hl,de
		ld (prod_lo),hl
		ld hl,(prod_hi)
		ld de,(fatsz32_hi)
		adc hl,de
		ld (prod_hi),hl
		djnz mul1_loop
mul1_done

		; DataStartSector = ReservedSectorCount + (NumFATs*FATSz32)
		ld hl,(reserved_sectors)
		ld de,(prod_lo)
		add hl,de
		ld (data_start_lo),hl
		ld hl,0
		ld de,(prod_hi)
		adc hl,de
		ld (data_start_hi),hl
		ld a,h
		ld (diag_buf+12),a
		ld a,l
		ld (diag_buf+13),a

		; RootCluster - 2 (32-bit)
		ld hl,(root_cluster_lo)
		ld de,2
		or a
		sbc hl,de
		ld (rc2_lo),hl
		ld hl,(root_cluster_hi)
		ld de,0
		sbc hl,de
		ld (rc2_hi),hl

		; (RootCluster-2) * SectorsPerCluster (32-bit product, repeated
		; 32-bit add -- SectorsPerCluster is a small power of 2, <=128)
		ld hl,0
		ld (prod2_lo),hl
		ld (prod2_hi),hl
		ld a,(sectors_per_cluster)
		or a
		jr z,mul2_done
		ld b,a
mul2_loop	ld hl,(prod2_lo)
		ld de,(rc2_lo)
		add hl,de
		ld (prod2_lo),hl
		ld hl,(prod2_hi)
		ld de,(rc2_hi)
		adc hl,de
		ld (prod2_hi),hl
		djnz mul2_loop
mul2_done

		; RootDirSector = DataStartSector + (RootCluster-2)*SectorsPerCluster
		ld hl,(data_start_lo)
		ld de,(prod2_lo)
		add hl,de
		ld (root_dir_lo),hl
		ld hl,(data_start_hi)
		ld de,(prod2_hi)
		adc hl,de
		ld (root_dir_hi),hl
		ld a,h
		ld (diag_buf+14),a
		ld a,l
		ld (diag_buf+15),a
		ld hl,(root_dir_lo)
		ld a,h
		ld (diag_buf+16),a
		ld a,l
		ld (diag_buf+17),a

		; sd_lba_max = ADDTOP + TotalSectors32 -- one past the last
		; valid absolute LBA on this card/partition. Computed here
		; (not in detect_partition) because it needs TotalSectors32,
		; which only exists once the real BPB has been parsed --
		; ADDTOP itself is already finalized by the time parse_bpb
		; runs (detect_partition runs first, see start:).
		ld hl,(addtop_lo)
		ld de,(total_sectors_lo)
		add hl,de
		ld (sd_lba_max_lo),hl
		ld hl,(addtop_hi)
		ld de,(total_sectors_hi)
		adc hl,de
		ld (sd_lba_max_hi),hl
		ret

total_sectors_lo	dw 0
total_sectors_hi	dw 0
; default #FFFFFFFF ("unbounded") until parse_bpb computes the real
; value -- CRITICAL: sector-0 and detect_partition's own reads happen
; BEFORE parse_bpb ever runs, so a 0 default here would refuse even
; the very first boot read (0 >= 0), bricking the driver from the
; first sector on. #FFFFFFFF is effectively "no restriction yet".
sd_lba_max_lo		dw #ffff
sd_lba_max_hi		dw #ffff

reserved_sectors	dw 0
num_fats		db 0
sectors_per_cluster	db 0
fatsz32_lo		dw 0
fatsz32_hi		dw 0
root_cluster_lo		dw 0
root_cluster_hi		dw 0
prod_lo			dw 0
prod_hi			dw 0
data_start_lo		dw 0
data_start_hi		dw 0
rc2_lo			dw 0
rc2_hi			dw 0
prod2_lo		dw 0
prod2_hi		dw 0
root_dir_lo		dw 0
root_dir_hi		dw 0

;--- find_zifi: scans sdbuf (one already-read 512-byte dir sector, 16 x
;--- 32-byte entries) for an 8.3 short-name entry matching target_name
;--- (caller fills this 11-byte buffer before calling find_zifi_all --
;--- despite the name, it's not hardcoded to "ZIFI" any more). A=1 (plus
;--- zifi_cluster_hi/zifi_cluster/zifi_size_hi/zifi_size) if found, A=2
;--- if this sector hit the true 0x00 end-of-directory marker (caller
;--- should stop entirely, not just this sector), A=0 if this sector's
;--- 16 entries didn't match (caller should read the next sector and
;--- try again -- a directory cluster can be many sectors; 0xE5 =
;--- deleted entry, skipped). ---

zifi_cluster_hi	dw 0
zifi_cluster	dw 0
zifi_size_hi	dw 0
zifi_size	dw 0
target_name	db "ZIFI       "	; 11 bytes: caller-set 8.3 name to search for

find_zifi	ld hl,sdbuf
		ld b,16
fz_loop		ld a,(hl)
		or a
		jr z,fz_end
		cp #e5
		jr z,fz_skip
		push hl
		push bc
		ld de,target_name
		ld b,11
fz_cmp		ld a,(de)
		cp (hl)
		jr nz,fz_cmpfail
		inc hl
		inc de
		djnz fz_cmp
		pop bc
		pop hl
		jr fz_found
fz_cmpfail	pop bc
		pop hl
fz_skip		ld de,32
		add hl,de
		djnz fz_loop
		xor a
		ret

fz_end		ld a,2
		ret

fz_found	push hl
		ld de,20		; cluster high16 at entry+20
		add hl,de
		ld a,(hl)
		ld (zifi_cluster_hi),a
		inc hl
		ld a,(hl)
		ld (zifi_cluster_hi+1),a
		pop hl
		push hl
		ld de,26		; cluster low16 (+26/27), then size (+28..31)
		add hl,de
		ld a,(hl)
		ld (zifi_cluster),a
		inc hl
		ld a,(hl)
		ld (zifi_cluster+1),a
		inc hl
		ld a,(hl)
		ld (zifi_size),a
		inc hl
		ld a,(hl)
		ld (zifi_size+1),a
		inc hl
		ld a,(hl)
		ld (zifi_size_hi),a
		inc hl
		ld a,(hl)
		ld (zifi_size_hi+1),a
		pop hl
		ld a,1
		ret

;--- find_zifi_all: scans the WHOLE directory cluster chain starting at
;--- whatever cluster the caller has already put in (cur_cluster_hi,
;--- cur_cluster_lo) -- e.g. (root_cluster_hi,root_cluster_lo) to search
;--- the root, or a found subdirectory's own cluster to search inside
;--- it -- for an 8.3 entry matching target_name. A cluster can hold far
;--- more than one sector's worth of entries (e.g. 64 sectors = 1024
;--- entries here), and the directory itself can span MORE than one
;--- cluster once it grows -- a directory is just a cluster chain like
;--- any other file, so this follows the FAT chain (via get_next_cluster)
;--- whenever the current cluster runs out without finding it or hitting
;--- the true end-of-directory marker. A=1+zifi_cluster_hi/zifi_cluster/
;--- zifi_size_hi/zifi_size if found, A=0 if not (read error, true
;--- end-of-directory, or the chain ends with no match). ---
fza_remaining	db 0

find_zifi_all
fza_cluster	call cluster_to_sector
		ld hl,(fza_sector_hi)
		ld de,(fza_sector_lo)
		call set_lba32
		ld a,(sectors_per_cluster)
		ld (fza_remaining),a
fza_loop	call sdread_lba
		or a
		jr nz,fza_stop
		call find_zifi
		cp 1
		jr z,fza_done
		cp 2
		jr z,fza_stop

		; advance lba_arg by 1 sector (32-bit increment, MSB-first bytes,
		; LSB-to-MSB ripple carry via a small loop instead of unrolling)
		ld hl,lba_arg+3
		ld b,4
fza_inc_loop	ld a,(hl)
		inc a
		ld (hl),a
		jr nz,fza_next
		dec hl
		djnz fza_inc_loop
fza_next	ld hl,fza_remaining
		dec (hl)
		jr nz,fza_loop

		; this cluster is exhausted with no match -- follow the FAT
		; chain to the next cluster of the directory, if there is one
		call get_next_cluster
		ld a,(chain_ended)
		or a
		jr nz,fza_stop
		jr fza_cluster

fza_stop	xor a
		ret
fza_done	ld a,1
		ret

;--- cluster_to_sector: (cur_cluster_hi,cur_cluster_lo) -> fza_sector_hi/
;--- fza_sector_lo = DataStartSector + (cluster-2)*SectorsPerCluster.
;--- Same formula as parse_bpb's RootDirSector computation, generalized
;--- to any cluster number so the FAT-chain walk above can locate each
;--- cluster's data as it follows the chain. ---

c2s_lo		dw 0
c2s_hi		dw 0
c2s_prod_lo	dw 0
c2s_prod_hi	dw 0
fza_sector_lo	dw 0
fza_sector_hi	dw 0

cluster_to_sector
		ld hl,(cur_cluster_lo)
		ld de,2
		or a
		sbc hl,de
		ld (c2s_lo),hl
		ld hl,(cur_cluster_hi)
		ld de,0
		sbc hl,de
		ld (c2s_hi),hl

		ld hl,0
		ld (c2s_prod_lo),hl
		ld (c2s_prod_hi),hl
		ld a,(sectors_per_cluster)
		or a
		jr z,c2s_done
		ld b,a
c2s_loop	ld hl,(c2s_prod_lo)
		ld de,(c2s_lo)
		add hl,de
		ld (c2s_prod_lo),hl
		ld hl,(c2s_prod_hi)
		ld de,(c2s_hi)
		adc hl,de
		ld (c2s_prod_hi),hl
		djnz c2s_loop
c2s_done	ld hl,(data_start_lo)
		ld de,(c2s_prod_lo)
		add hl,de
		ex de,hl
		ld hl,(data_start_hi)
		ld bc,(c2s_prod_hi)
		adc hl,bc
		call add_addtop		; offset by ADDTOP here, at read time
		ld (fza_sector_hi),hl
		ld (fza_sector_lo),de
		ret

;--- cluster_to_fatpos: (cur_cluster_hi,cur_cluster_lo) -> gnc_fatsec_hi/
;--- gnc_fatsec_lo (the FAT sector, partition-relative -- caller adds
;--- ADDTOP) and gnc_inoff (byte offset within that sector). Shared by
;--- get_next_cluster (reading a chain link) and write_fat_entry
;--- (writing one, for MKDIR/MKFILE). FAT32 entries are 4 bytes; the
;--- entry for cluster N is at byte N*4 of the FAT, i.e. FAT sector =
;--- ReservedSectorCount + (N*4)/BytesPerSector, offset (N*4) mod
;--- BytesPerSector within it -- since BytesPerSector is always 512
;--- (checked by verify_fat32), that's cluster>>7 / (cluster&0x7F)*4.
;--- Bounds-checks the FAT-sector offset against FATSz32 first (matches
;--- WC core32's CURIT) so a corrupted/out-of-range cluster number is
;--- rejected instead of blindly read from or written to. A=0 ok, A=1
;--- out of range. ---
cur_cluster_hi	dw 0
cur_cluster_lo	dw 0
gnc_hi		dw 0
gnc_lo		dw 0
gnc_fatsec_hi	dw 0
gnc_fatsec_lo	dw 0
gnc_inoff	db 0

cluster_to_fatpos
		ld hl,(cur_cluster_hi)
		ld (gnc_hi),hl
		ld hl,(cur_cluster_lo)
		ld (gnc_lo),hl
		ld b,7
ctf_shr		ld hl,(gnc_hi)
		srl h
		rr l
		ld (gnc_hi),hl
		ld hl,(gnc_lo)
		rr h
		rr l
		ld (gnc_lo),hl
		djnz ctf_shr

		ld hl,(gnc_lo)
		ld de,(fatsz32_lo)
		or a
		sbc hl,de
		ld hl,(gnc_hi)
		ld de,(fatsz32_hi)
		sbc hl,de
		jr nc,ctf_bad

		ld hl,(reserved_sectors)
		ld de,(gnc_lo)
		add hl,de
		ld (gnc_fatsec_lo),hl
		ld hl,0
		ld de,(gnc_hi)
		adc hl,de
		ld (gnc_fatsec_hi),hl

		ld hl,(cur_cluster_lo)
		ld a,l
		and #7f
		add a,a
		add a,a
		ld (gnc_inoff),a
		xor a
		ret

ctf_bad		xor a
		inc a
		ret

;--- get_next_cluster: reads the FAT32 table entry for the cluster in
;--- (cur_cluster_hi,cur_cluster_lo) and, if it isn't an end-of-chain
;--- marker, replaces cur_cluster_hi/lo with the next cluster. Sets
;--- chain_ended=1 on end-of-chain (masked entry >=0x0FFFFFF8), an
;--- out-of-range cluster, or a read error, 0 otherwise. ---

chain_ended	db 0
nxt_lo		dw 0
nxt_hi		dw 0

get_next_cluster
		call cluster_to_fatpos
		or a
		jr nz,gnc_end

		ld hl,(gnc_fatsec_hi)
		ld de,(gnc_fatsec_lo)
		call add_addtop		; offset by ADDTOP here, at read time
		call set_lba32
		call sdread_lba
		or a
		jr nz,gnc_end

		ld a,(gnc_inoff)
		ld l,a
		ld h,0
		ld de,sdbuf
		add hl,de
		ld a,(hl)
		ld (nxt_lo),a
		inc hl
		ld a,(hl)
		ld (nxt_lo+1),a
		inc hl
		ld a,(hl)
		ld (nxt_hi),a
		inc hl
		ld a,(hl)
		and #0f
		ld (nxt_hi+1),a

		ld hl,(nxt_hi)
		ld a,h
		cp #0f
		jr nz,gnc_have_next
		ld a,l
		cp #f8
		jr c,gnc_have_next

gnc_end		ld a,1
		ld (chain_ended),a
		ret

gnc_have_next	ld hl,(nxt_lo)
		ld (cur_cluster_lo),hl
		ld hl,(nxt_hi)
		ld (cur_cluster_hi),hl
		xor a
		ld (chain_ended),a
		ret

;=====================================================================
; Write path: free-cluster search, FAT entry write (mirrored to every
; FAT copy), cluster zero-fill, and directory-entry write -- the pieces
; MKDIR (and later MKFILE) need. Ported in spirit from WC core32's
; SRHFCL/GENBU (free-cluster search), the FAT-write half of BUtoFAT/
; SVFATM (mirror to every FAT copy), and MKDIR/SVHDFL/SRHDRN's free-
; slot search, simplified where this test doesn't need the general
; case (e.g. always exactly one cluster, no directory-growth-on-full).
;=====================================================================

;--- write_fat_entry: writes (new_val_hi,new_val_lo) into the FAT entry
;--- for the cluster in (cur_cluster_hi,cur_cluster_lo), mirroring the
;--- write to every one of NumFATs copies -- WC core32 calls this
;--- SVFATM. This is the exact bug class already found and fixed once
;--- before in WC Improved's stock driver (FAT copy #2+ silently going
;--- stale because only copy #1 was ever written) -- chkdsk flags
;--- exactly this kind of desync, so it's not optional here. Reads+
;--- patches the primary copy's sector once, then writes that same
;--- patched buffer to every copy's corresponding sector (FATsector +
;--- i*FATSz32) rather than re-reading each copy -- correct as long as
;--- all copies started in sync, which they should have. A=0 ok, A=1
;--- fail (out of range, or a read/write error). ---

new_val_hi	dw 0
new_val_lo	dw 0
wfe_remaining	db 0
wfe_sector_hi	dw 0
wfe_sector_lo	dw 0

write_fat_entry
		call cluster_to_fatpos
		or a
		jr nz,wfe_fail

		ld hl,(gnc_fatsec_hi)
		ld (wfe_sector_hi),hl
		ld hl,(gnc_fatsec_lo)
		ld (wfe_sector_lo),hl

		ld hl,(wfe_sector_hi)
		ld de,(wfe_sector_lo)
		call add_addtop
		call set_lba32
		call sdread_lba
		or a
		jr nz,wfe_fail

		ld a,(gnc_inoff)
		ld l,a
		ld h,0
		ld de,sdbuf
		add hl,de
		ld a,(new_val_lo)
		ld (hl),a
		inc hl
		ld a,(new_val_lo+1)
		ld (hl),a
		inc hl
		ld a,(new_val_hi)
		ld (hl),a
		inc hl
		ld a,(hl)		; top nibble of the 4th byte is reserved --
		and #f0			; preserve whatever's already on disk there
		ld b,a
		ld a,(new_val_hi+1)
		and #0f
		or b
		ld (hl),a

		ld a,(num_fats)
		ld (wfe_remaining),a
wfe_loop	ld hl,(wfe_sector_hi)
		ld de,(wfe_sector_lo)
		call add_addtop
		call set_lba32
		call sdwrite_lba	; sdbuf (already patched) reused as-is
		or a
		jr nz,wfe_fail

		ld hl,(wfe_sector_lo)
		ld de,(fatsz32_lo)
		add hl,de
		ld (wfe_sector_lo),hl
		ld hl,(wfe_sector_hi)
		ld de,(fatsz32_hi)
		adc hl,de
		ld (wfe_sector_hi),hl

		ld hl,wfe_remaining
		dec (hl)
		jr nz,wfe_loop

		xor a
		ret
wfe_fail	xor a
		inc a
		ret

;--- read_fsinfo_hint: reads the FSInfo sector (BPB offset 48) and, if
;--- its two signatures check out, extracts FSI_Nxt_Free (offset 492) as
;--- a starting hint for find_free_cluster -- FAT32's whole reason for
;--- having this field is to avoid scanning the FAT from cluster 2 every
;--- time, which on a card that already has real files can mean
;--- scanning past thousands of used entries first (a real problem hit
;--- in practice, even with the sector-batched scan below). Falls back
;--- to "no hint" if the signatures don't check out or the value is the
;--- documented "unknown" sentinel (all 4 bytes 0xFF). This is a
;--- starting GUESS only, not gospel -- find_free_cluster still verifies
;--- an entry is really free before trusting it, and falls back to a
;--- from-cluster-2 scan if starting from the hint finds nothing (worth
;--- remembering: WC core32's own shipped build doesn't trust this hint
;--- at all, always rescanning from scratch -- noted earlier this
;--- session as a real-world reliability concern with the field). ---

fsinfo_sector	dw 0
fsinfo_hint_hi	dw 0
fsinfo_hint_lo	dw 0
fsinfo_valid	db 0

read_fsinfo_hint
		xor a
		ld (fsinfo_valid),a

		ld hl,0
		ld de,(fsinfo_sector)
		call add_addtop
		call set_lba32
		call sdread_lba
		or a
		ret nz

		ld hl,(sdbuf+0)		; lead signature "RRaA" (0x41615252 LE)
		ld de,#5252
		or a
		sbc hl,de
		ret nz
		ld hl,(sdbuf+2)
		ld de,#4161
		or a
		sbc hl,de
		ret nz

		ld hl,(sdbuf+484)	; struct signature "rrAa" (0x61417272 LE)
		ld de,#7272
		or a
		sbc hl,de
		ret nz
		ld hl,(sdbuf+486)
		ld de,#6141
		or a
		sbc hl,de
		ret nz

		ld hl,(sdbuf+492)	; FSI_Nxt_Free (u32 LE); all-0xFF = unknown
		ld a,h
		and l
		ld b,a
		ld hl,(sdbuf+494)
		ld a,h
		and l
		and b
		cp #ff
		ret z

		ld hl,(sdbuf+492)
		ld (fsinfo_hint_lo),hl
		ld hl,(sdbuf+494)
		ld (fsinfo_hint_hi),hl
		ld a,1
		ld (fsinfo_valid),a
		ret

;--- write_fsinfo_hint: writes (next_search_hi,next_search_lo) -- already
;--- computed as the just-allocated cluster+1 -- into FSI_Nxt_Free
;--- (offset 492) of the FSInfo sector, and decrements FSI_Free_Count
;--- (offset 488) by 1 unless it's the "unknown" sentinel (all 4 bytes
;--- 0xFF). Keeps the hint honest for whoever reads it next, including a
;--- future run of THIS driver -- unlike WC core32's own shipped build,
;--- which never touches this field at all (confirmed on hardware to be
;--- why the hint was stale: it pointed near the ZIFI folder's own
;--- cluster, i.e. frozen since roughly when the card was first set up,
;--- while everything written since -- by WC -- never advanced it).
;--- Called right after a successful allocation; best-effort only --
;--- the allocation itself already succeeded regardless of whether this
;--- does. A=0 ok, A=1 fail (non-fatal to the caller). ---
write_fsinfo_hint
		ld hl,0
		ld de,(fsinfo_sector)
		call add_addtop
		call set_lba32
		call sdread_lba
		or a
		ret nz

		ld hl,(sdbuf+488)	; FSI_Free_Count -- skip if "unknown" (0xFFFFFFFF)
		ld a,h
		and l
		ld b,a
		ld hl,(sdbuf+490)
		ld a,h
		and l
		and b
		cp #ff
		jr z,wfi_skip_count

		ld hl,(sdbuf+488)
		ld de,1
		or a
		sbc hl,de
		ld (sdbuf+488),hl
		jr nc,wfi_skip_count
		ld hl,(sdbuf+490)
		ld de,1
		sbc hl,de
		ld (sdbuf+490),hl

wfi_skip_count	ld hl,(next_search_lo)
		ld (sdbuf+492),hl
		ld hl,(next_search_hi)
		ld (sdbuf+494),hl

		ld hl,0
		ld de,(fsinfo_sector)
		call add_addtop
		call set_lba32
		jp sdwrite_lba

;--- find_free_cluster: scans the FAT for a free entry (4-byte value ==
;--- 0). Sets free_cluster_hi/lo if found. A=0 ok, A=1 not found
;--- (scanned the whole FAT from cluster 2 onward -- volume genuinely
;--- full). Reads each FAT sector ONCE and checks all of its remaining
;--- entries from memory before moving to the next sector, instead of
;--- issuing a fresh disk read per cluster checked -- a real problem hit
;--- in practice on a card that already has real files on it.
;---
;--- Where the scan STARTS: prefers next_search_hi/lo, an in-memory
;--- cache of "one past the last cluster this session actually
;--- allocated", over the on-disk FSInfo hint -- real hardware test
;--- confirmed the FSInfo hint (FSI_Nxt_Free) is genuinely STALE on a
;--- heavily-used card (30000+ files): it pointed to cluster 0x1B91,
;--- deep inside a ~530000-cluster contiguous used region that had to
;--- be scanned past anyway, costing ~4100 sector reads. That's exactly
;--- why WC core32's own shipped build doesn't trust this field either
;--- (noted earlier this session, now empirically confirmed). The
;--- in-memory cache only helps for the 2nd+ allocation THIS boot --
;--- the very first one still has to pay the full scan once, same as
;--- WC's own FSTFRC starting cold at boot. Uses (and leaves modified)
;--- cur_cluster_hi/lo, same as get_next_cluster. ---

free_cluster_hi	dw 0
free_cluster_lo	dw 0
ffc_ptr		dw 0
ffc_count	db 0

ffc_sectors_read	dw 0
next_search_valid	db 0
next_search_hi		dw 0
next_search_lo		dw 0

find_free_cluster
		ld hl,0
		ld (ffc_sectors_read),hl

		ld a,(next_search_valid)
		or a
		jr z,ffc_use_hint
		ld hl,(next_search_hi)
		ld (cur_cluster_hi),hl
		ld hl,(next_search_lo)
		ld (cur_cluster_lo),hl
		jp ffc_scan

ffc_use_hint	call read_fsinfo_hint
		ld a,(fsinfo_valid)
		or a
		jr z,ffc_from2
		ld hl,(fsinfo_hint_hi)
		ld (cur_cluster_hi),hl
		ld hl,(fsinfo_hint_lo)
		ld (cur_cluster_lo),hl
		call ffc_scan
		or a
		ret z		; found starting from the hint

ffc_from2	ld hl,0
		ld (cur_cluster_hi),hl
		ld hl,2
		ld (cur_cluster_lo),hl
		jp ffc_scan

ffc_scan	call cluster_to_fatpos
		or a
		jp nz,ffc_fail

		ld hl,(gnc_fatsec_hi)
		ld de,(gnc_fatsec_lo)
		call add_addtop
		call set_lba32
		call sdread_lba
		or a
		jp nz,ffc_fail
		ld hl,(ffc_sectors_read)
		inc hl
		ld (ffc_sectors_read),hl

		ld a,(gnc_inoff)
		ld l,a
		ld h,0
		ld de,sdbuf
		add hl,de
		ld (ffc_ptr),hl

		; how many of this sector's 128 entries are left from here on
		; (the first sector checked may not start at entry 0, since
		; cluster 2 isn't necessarily sector-aligned)
		ld a,(cur_cluster_lo)
		and #7f
		ld b,a
		ld a,128
		sub b
		ld (ffc_count),a

ffc_entloop	ld hl,(ffc_ptr)
		ld a,(hl)
		or a
		jr nz,ffc_entnext
		inc hl
		ld a,(hl)
		or a
		jr nz,ffc_entnext
		inc hl
		ld a,(hl)
		or a
		jr nz,ffc_entnext
		inc hl
		ld a,(hl)
		and #0f
		jr nz,ffc_entnext

		ld hl,(cur_cluster_hi)
		ld (free_cluster_hi),hl
		ld hl,(cur_cluster_lo)
		ld (free_cluster_lo),hl

		; remember cluster+1 as the starting point for the NEXT search
		; this boot -- avoids re-scanning the same used region on every
		; later allocation this session (matches WC core32's own
		; FSTFRC in-memory caching pattern)
		ld hl,(cur_cluster_lo)
		inc hl
		ld (next_search_lo),hl
		ld a,h
		or l
		jr nz,ffc_nsv
		ld hl,(cur_cluster_hi)
		inc hl
		ld (next_search_hi),hl
		jr ffc_nsv2
ffc_nsv		ld hl,(cur_cluster_hi)
		ld (next_search_hi),hl
ffc_nsv2	ld a,1
		ld (next_search_valid),a

		; persist the updated hint to disk too -- unlike WC core32,
		; which never touches this field at all (confirmed the real
		; cause of the stale hint found on hardware), so the NEXT
		; session (not just this one) starts from an honest position
		call write_fsinfo_hint

		xor a
		ret

ffc_entnext	ld hl,(ffc_ptr)
		ld de,4
		add hl,de
		ld (ffc_ptr),hl

		ld hl,(cur_cluster_lo)
		inc hl
		ld (cur_cluster_lo),hl
		ld a,h
		or l
		jr nz,ffc_nowrap
		ld hl,(cur_cluster_hi)
		inc hl
		ld (cur_cluster_hi),hl
ffc_nowrap	ld a,(ffc_count)
		dec a
		ld (ffc_count),a
		jr nz,ffc_entloop
		jp ffc_scan

ffc_fail	xor a
		inc a
		ret

;--- zero_fill_cluster: writes SectorsPerCluster sectors of all-zero
;--- data to the cluster in (cur_cluster_hi,cur_cluster_lo) -- a fresh
;--- cluster on disk can hold anything left over from whatever used it
;--- last, and FAT32 doesn't guarantee zeroed free space. Uses ONE
;--- sdwrite_multi_start/_block/_stop session for the whole cluster
;--- (consecutive sectors) instead of a separate session per sector --
;--- with SectorsPerCluster=64 on this card, that's 63 fewer CMD25-open/
;--- R1-wait/stop-token/busy-wait round trips, which is most of what
;--- made this feel like a hang before. A=0 ok, A=1 fail (a write error
;--- partway through). ---

zfc_remaining	db 0

zero_fill_cluster
		call cluster_to_sector	; already ADDTOP-offset
		ld hl,sdbuf
		ld de,sdbuf+1
		ld bc,511
		ld (hl),0
		ldir

		ld hl,(fza_sector_hi)
		ld de,(fza_sector_lo)
		call set_lba32
		call sdwrite_multi_start
		or a
		jr nz,zfc_fail

		ld a,(sectors_per_cluster)
		ld (zfc_remaining),a
zfc_loop	call sdwrite_multi_block
		or a
		jr nz,zfc_fail
		ld hl,zfc_remaining
		dec (hl)
		jr nz,zfc_loop

		jp sdwrite_multi_stop

zfc_fail	xor a
		inc a
		ret

;--- write_dir_entry: writes the 32-byte entry at dir_entry_buf into the
;--- first free slot (0x00 = end of directory / 0xE5 = deleted) found
;--- while scanning the directory cluster chain starting at
;--- (cur_cluster_hi,cur_cluster_lo) -- follows the FAT chain via
;--- get_next_cluster if a whole cluster has no free slot. Does NOT grow
;--- the directory with a new cluster if the entire existing chain is
;--- full (accepted limitation here -- ZiFi's own root/zifi dirs are
;--- nowhere near that). A=0 ok, A=1 fail (read/write error, or no free
;--- slot anywhere in the existing chain). ---

dir_entry_buf	ds 32
wde_remaining	db 0
wde_sector_hi	dw 0
wde_sector_lo	dw 0
wde_slotptr	dw 0

write_dir_entry
wde_cluster	call cluster_to_sector
		ld hl,(fza_sector_hi)
		ld (wde_sector_hi),hl
		ld hl,(fza_sector_lo)
		ld (wde_sector_lo),hl
		ld a,(sectors_per_cluster)
		ld (wde_remaining),a

wde_sec_loop	ld hl,(wde_sector_hi)
		ld de,(wde_sector_lo)
		call set_lba32
		call sdread_lba
		or a
		jr nz,wde_fail

		ld hl,sdbuf
		ld b,16
wde_entloop	ld a,(hl)
		or a
		jr z,wde_slot
		cp #e5
		jr z,wde_slot
		ld de,32
		add hl,de
		djnz wde_entloop

		ld hl,(wde_sector_lo)
		inc hl
		ld (wde_sector_lo),hl
		ld a,h
		or l
		jr nz,wde_next
		ld hl,(wde_sector_hi)
		inc hl
		ld (wde_sector_hi),hl
wde_next	ld hl,wde_remaining
		dec (hl)
		jr nz,wde_sec_loop

		call get_next_cluster
		ld a,(chain_ended)
		or a
		jr nz,wde_fail
		jr wde_cluster

wde_slot	ld (wde_slotptr),hl
		ld hl,dir_entry_buf
		ld de,(wde_slotptr)
		ld bc,32
		ldir

		ld hl,(wde_sector_hi)
		ld de,(wde_sector_lo)
		call set_lba32
		call sdwrite_lba
		ret

wde_fail	xor a
		inc a
		ret

;=====================================================================
; Cluster-chain streaming: generic sector-at-a-time read/write that
; follows a file's/directory's FAT chain automatically, allocating a
; new cluster on demand when writing past the current end -- the
; building block a real LOAD512/SAVE512 (and any multi-cluster file,
; which every previous MKFILE test here deliberately avoided by staying
; under one 32KB cluster) actually need. Caller sets (cur_cluster_hi,
; cur_cluster_lo) to the file's first cluster, calls stream_open once,
; then stream_read_sector/stream_write_sector repeatedly (one 512-byte
; sector at a time, via sdbuf).
;=====================================================================


stream_cluster_hi	dw 0
stream_cluster_lo	dw 0
stream_sec_in_cluster	db 0
stream_eoc		db 0
strm_sector_hi		dw 0
strm_sector_lo		dw 0

;--- stream_open: (cur_cluster_hi,cur_cluster_lo) -> starts a stream at
;--- that cluster's first sector. Cluster 0 means "root" (matches the
;--- convention already used for a subdirectory's ".." entry). ---
stream_open	ld hl,(cur_cluster_hi)
		ld a,h
		or l
		jr nz,strm_open_nz
		ld hl,(cur_cluster_lo)
		ld a,h
		or l
		jr nz,strm_open_nz
		ld hl,(root_cluster_hi)
		ld (cur_cluster_hi),hl
		ld hl,(root_cluster_lo)
		ld (cur_cluster_lo),hl
strm_open_nz	ld hl,(cur_cluster_hi)
		ld (stream_cluster_hi),hl
		ld hl,(cur_cluster_lo)
		ld (stream_cluster_lo),hl
		xor a
		ld (stream_sec_in_cluster),a
		ld (stream_eoc),a
		ret

;--- strm_calc_sector: (stream_cluster_hi,stream_cluster_lo,
;--- stream_sec_in_cluster) -> strm_sector_hi/lo (absolute sector,
;--- ADDTOP-offset already applied via cluster_to_sector). Clobbers
;--- cur_cluster_hi/lo (sets them to the stream's current cluster). ---
strm_calc_sector
		ld hl,(stream_cluster_hi)
		ld (cur_cluster_hi),hl
		ld hl,(stream_cluster_lo)
		ld (cur_cluster_lo),hl
		call cluster_to_sector
		ld hl,(fza_sector_lo)
		ld a,(stream_sec_in_cluster)
		ld d,0
		ld e,a
		add hl,de
		ld (strm_sector_lo),hl
		ld hl,(fza_sector_hi)
		ld de,0
		adc hl,de
		ld (strm_sector_hi),hl
		ret

;--- strm_advance: moves the stream position forward by one sector,
;--- crossing into the next cluster (via get_next_cluster) if that was
;--- the last sector of the current one. Sets stream_eoc=1 if the chain
;--- ends there. Always returns A=0 (advancing itself can't fail --
;--- get_next_cluster's own failure just means stream_eoc becomes 1,
;--- which the NEXT read/write call reports). ---
strm_advance	ld a,(stream_sec_in_cluster)
		inc a
		ld b,a			; b = candidate new sec_in_cluster
		ld a,(sectors_per_cluster)
		cp b			; NC+NZ (sectors_per_cluster > b) -> still
		jr nc,strm_adv_test_z	; within this cluster; Z or C -> cross over
		jr strm_adv_cross
strm_adv_test_z	jr z,strm_adv_cross
		ld a,b
		ld (stream_sec_in_cluster),a
		xor a
		ret
strm_adv_cross	xor a
		ld (stream_sec_in_cluster),a
		ld hl,(stream_cluster_hi)
		ld (cur_cluster_hi),hl
		ld hl,(stream_cluster_lo)
		ld (cur_cluster_lo),hl
		call get_next_cluster
		ld hl,(cur_cluster_hi)
		ld (stream_cluster_hi),hl
		ld hl,(cur_cluster_lo)
		ld (stream_cluster_lo),hl
		ld a,(chain_ended)
		ld (stream_eoc),a
		xor a
		ret
strm_adv_same	ld a,b
		ld (stream_sec_in_cluster),a
		xor a
		ret

;--- stream_read_sector: reads the sector at the current stream
;--- position into sdbuf, then advances. A=0 ok, A=1 read error, A=2
;--- already at end of chain (nothing read). ---
stream_read_sector
		ld a,(stream_eoc)
		or a
		jr nz,strm_read_eoc

		call strm_calc_sector
		ld hl,(strm_sector_hi)
		ld de,(strm_sector_lo)
		call set_lba32
		call sdread_lba
		or a
		ret nz

		; save the just-read sector before strm_advance's cluster-
		; crossing path (get_next_cluster) clobbers sdbuf with its own
		; FAT-sector scratch -- same class of bug as write_fat_entry's
		; sdbuf reuse (see stream_write_sector/stream_data_save), just
		; on the read side: reading the LAST sector of a cluster read
		; the right data from disk, but by the time the caller checked
		; sdbuf, the chain-follow that runs immediately afterward (to
		; find the next cluster, so the FOLLOWING read knows where to
		; go) had already overwritten it
		ld hl,sdbuf
		ld de,stream_data_save
		ld bc,512
		ldir
		call strm_advance
		ld hl,stream_data_save
		ld de,sdbuf
		ld bc,512
		ldir
		xor a
		ret

strm_read_eoc	ld a,2
		ret

;--- stream_read_sector_to: identical to stream_read_sector, except the
;--- sector is DMA'd directly to (dma_xfer_page,dma_xfer_off) -- caller
;--- must set those two variables first -- instead of sdbuf. No
;--- sdbuf-save/restore dance needed here (unlike stream_read_sector's
;--- own stream_data_save shuffle): the caller's data never touches
;--- sdbuf at all in this path, so get_next_cluster's own FAT-sector
;--- scratch use of sdbuf (inside strm_advance, on a cluster-boundary
;--- crossing) can't clobber it. Used by core_load512, see
;--- dma_xfer_off's own comment above. ---
stream_read_sector_to
		ld a,(stream_eoc)
		or a
		jr nz,strm_read_eoc

		call strm_calc_sector
		ld hl,(strm_sector_hi)
		ld de,(strm_sector_lo)
		call set_lba32
		call sdread_lba_to
		or a
		ret nz

		jp strm_advance

;--- stream_write_sector: writes sdbuf to the current stream position,
;--- extending the cluster chain (allocating a new cluster and linking
;--- it via write_fat_entry, replacing the previous cluster's EOC
;--- marker) if the stream has run past the end. A=0 ok, A=1 fail
;--- (alloc/link/write error). ---
stream_data_save	ds 512	; scratch: the caller's pending sector data,
				; saved off while find_free_cluster/write_fat_entry
				; below reuse sdbuf as their OWN FAT-sector
				; read/patch/write scratch (found on hardware: without
				; this save/restore, a cluster-boundary-crossing write
				; got the just-written FAT sector's bytes into the
				; new cluster's data instead of the real file data --
				; both our own readback and Windows chkdsk caught this
				; as real on-disk corruption, not just a readback bug)

stream_write_sector
		ld a,(stream_eoc)
		or a
		jr z,strm_write_have

		ld hl,sdbuf
		ld de,stream_data_save
		ld bc,512
		ldir

		call find_free_cluster
		or a
		ret nz

		ld hl,(stream_cluster_hi)
		ld (cur_cluster_hi),hl
		ld hl,(stream_cluster_lo)
		ld (cur_cluster_lo),hl
		ld hl,(free_cluster_hi)
		ld (new_val_hi),hl
		ld hl,(free_cluster_lo)
		ld (new_val_lo),hl
		call write_fat_entry		; old last cluster -> new cluster
		or a
		ret nz

		ld hl,(free_cluster_hi)
		ld (cur_cluster_hi),hl
		ld hl,(free_cluster_lo)
		ld (cur_cluster_lo),hl
		ld hl,#0fff
		ld (new_val_hi),hl
		ld hl,#ffff
		ld (new_val_lo),hl
		call write_fat_entry		; new cluster -> EOC
		or a
		ret nz

		ld hl,(free_cluster_hi)
		ld (stream_cluster_hi),hl
		ld hl,(free_cluster_lo)
		ld (stream_cluster_lo),hl
		xor a
		ld (stream_sec_in_cluster),a
		ld (stream_eoc),a

		ld hl,stream_data_save
		ld de,sdbuf
		ld bc,512
		ldir

strm_write_have	call strm_calc_sector
		ld hl,(strm_sector_hi)
		ld de,(strm_sector_lo)
		call set_lba32
		call sdwrite_lba
		or a
		ret nz

		jp strm_advance

;--- stream_write_sector_from: identical to stream_write_sector, except
;--- the sector is DMA'd directly FROM (dma_xfer_page,dma_xfer_off) --
;--- caller must set those two variables first -- instead of sdbuf. On
;--- a cluster-boundary crossing (new cluster needed), find_free_cluster/
;--- write_fat_entry still freely reuse sdbuf as their own FAT-sector
;--- scratch, same as before -- that part is fine, sdbuf's raw bytes
;--- were never the caller's data in this path. BUT find_free_cluster/
;--- write_fat_entry also call sdread_lba/sdwrite_lba internally, which
;--- (via set_dma_sdbuf) overwrite the SHARED dma_xfer_page/dma_xfer_off
;--- pair with own_page/sdbuf -- so by the time strm_write_have2 below
;--- calls sdwrite_lba_from, it was DMAing from sdbuf/own_page (whatever
;--- FAT-sector bytes write_fat_entry last touched) instead of the
;--- caller's real page, on every single new-cluster allocation -- i.e.
;--- the first block of every brand-new file. This is exactly the same
;--- clobbering hazard stream_write_sector's own stream_data_save guards
;--- against, just against dma_xfer_page/off instead of sdbuf's bytes --
;--- confirmed as the real cause of "every download saves as identical
;--- garbage" (2026-09-09), see [[project-zifi-custom-sd-driver]]. Fix:
;--- reload the pair from sv512_page/sv512_off (core_save512's own
;--- persistent copy, untouched by find_free_cluster/write_fat_entry --
;--- they only touch dma_xfer_page/off and their own gnc_*/wfe_*/
;--- cur_cluster_* state) right before the real write below, instead of
;--- adding new scratch bytes to save/restore -- costs 12 bytes instead
;--- of ~27, fits the body's tight #2000 budget. Used by core_save512,
;--- see dma_xfer_off's own comment above. ---
stream_write_sector_from
		ld a,(stream_eoc)
		or a
		jr z,strm_write_have2

		call find_free_cluster
		or a
		ret nz

		ld hl,(stream_cluster_hi)
		ld (cur_cluster_hi),hl
		ld hl,(stream_cluster_lo)
		ld (cur_cluster_lo),hl
		ld hl,(free_cluster_hi)
		ld (new_val_hi),hl
		ld hl,(free_cluster_lo)
		ld (new_val_lo),hl
		call write_fat_entry		; old last cluster -> new cluster
		or a
		ret nz

		ld hl,(free_cluster_hi)
		ld (cur_cluster_hi),hl
		ld hl,(free_cluster_lo)
		ld (cur_cluster_lo),hl
		ld hl,#0fff
		ld (new_val_hi),hl
		ld hl,#ffff
		ld (new_val_lo),hl
		call write_fat_entry		; new cluster -> EOC
		or a
		ret nz

		ld hl,(free_cluster_hi)
		ld (stream_cluster_hi),hl
		ld hl,(free_cluster_lo)
		ld (stream_cluster_lo),hl
		xor a
		ld (stream_sec_in_cluster),a
		ld (stream_eoc),a

		ld a,(sv512_page)
		ld (dma_xfer_page),a
		ld hl,(sv512_off)
		ld (dma_xfer_off),hl

strm_write_have2
		call strm_calc_sector
		ld hl,(strm_sector_hi)
		ld de,(strm_sector_lo)
		call set_lba32
		call sdwrite_lba_from
		or a
		ret nz

		jp strm_advance

;=====================================================================
; RTC read + FAT32 directory-entry date/time stamping.
;
; Ports/protocol ported from zifi.asm's own write_rtc (verified working
; on this exact hardware, see [[project-zifi-rtc-time-sync]]): #EFF7 is
; a SHARED system register (video mode/turbo/cache bits, not a
; dedicated CMOS-enable bit) -- must read-modify-write it, a literal
; write stomps unrelated bits. #DFF7 selects a DS1685-style RTC
; register index, #BFF7 is the data port for whichever register is
; selected. Register map (from zifi.asm's own write_rtc): 0x00=seconds,
; 0x02=minutes, 0x04=hours, 0x07=date, 0x08=month, 0x09=year (last 2
; digits only), 0x0B=register B (0x82=SET+24hr while reading, freezes
; the clock for a consistent snapshot; 0x02=24hr, running -- zifi.asm's
; own idle/teardown value, restored here the same way). All fields are
; BCD (confirmed via zifi.asm's code_time_rtc, which packs two ASCII
; digits directly as BCD nibbles, no decimal-to-binary step) -- this
; reads the RTC's raw registers and does its OWN correct BCD->binary
; conversion, since we need real binary values to pack into FAT's
; date/time bit fields, not just to redisplay as digits.
;
; NOT yet tested on hardware -- first attempt, ported carefully from a
; write path proven to work, but reading has never been exercised here.
;=====================================================================


rtc_sec		db 0
rtc_min		db 0
rtc_hour	db 0
rtc_date	db 0
rtc_month	db 0
rtc_year	db 0

read_rtc_datetime
		; READ-ONLY -- never writes any RTC chip register (0x00-0x0D).
		; The earlier version froze/restored register B (SET bit) for
		; a torn-read-proof snapshot, but that means two real WRITES
		; to the RTC's own register B every call, x8 calls/boot in
		; this test suite. The user's own previously-proven-safe
		; reference (D:\ST\DivMmc\RTC-master\rtc_gluk.asm, an ESXDOS
		; RTC.SYS actually used without RTC data glitches) reads
		; seconds/minutes/hours/date/month/year/register-B via plain
		; INI, with NO write to register B at all, ever. Matching that
		; exactly here: a torn read (a field rolling over mid-read) is
		; rare and merely produces an off-by-a-few-seconds date/time
		; stamp, self-correcting next call -- utterly harmless next to
		; the real risk of a write leaving register B (or the DM/SET
		; bits) in a bad state on real hardware.
		;
		; No di/ei here anymore -- this only ever really runs once,
		; from inside drv_hdd, which is now itself di/ei-wrapped (see
		; the jump-table wrappers below); a local ei here would have
		; re-enabled interrupts before that OUTER di's critical
		; section was actually done.
		ld bc,#eff7
		in a,(c)
		or #80
		out (c),a

		; register B: read-only, for the DM bit (bit 2: 0=BCD,
		; nonzero=binary) -- zifi.asm's own write_rtc always forces
		; BCD when IT writes, but something else could leave the chip
		; in binary mode, so this checks rather than assumes. No SET/
		; freeze write -- see comment above.
		ld a,#0b
		ld b,#df
		out (c),a
		ld b,#bf
		in a,(c)
		and #04
		ld (rtc_dm),a		; 0=BCD, nonzero=binary

		ld a,#00		; seconds
		ld b,#df
		out (c),a
		ld b,#bf
		in a,(c)
		ld (rtc_sec),a

		ld a,#02		; minutes
		ld b,#df
		out (c),a
		ld b,#bf
		in a,(c)
		ld (rtc_min),a

		ld a,#04		; hours
		ld b,#df
		out (c),a
		ld b,#bf
		in a,(c)
		ld (rtc_hour),a

		ld a,#07		; date
		ld b,#df
		out (c),a
		ld b,#bf
		in a,(c)
		ld (rtc_date),a

		ld a,#08		; month
		ld b,#df
		out (c),a
		ld b,#bf
		in a,(c)
		ld (rtc_month),a

		ld a,#09		; year (last 2 digits)
		ld b,#df
		out (c),a
		ld b,#bf
		in a,(c)
		ld (rtc_year),a

		; nothing to restore -- register B was only ever read (see
		; header comment), never written
		ld bc,#eff7
		in a,(c)
		and #7f
		out (c),a
		ret

rtc_dm		db 0

;--- rtc_field_to_bin: A=raw RTC register value -> A=binary, honoring
;--- the RTC's own DM (data-mode) bit captured in rtc_dm by
;--- read_rtc_datetime (0=BCD -> convert, nonzero=already binary ->
;--- pass through). Checking this instead of assuming BCD matters
;--- because something other than zifi.asm's own write_rtc (which
;--- always forces BCD when it writes) could leave the chip in binary
;--- mode. ---
rtc_field_to_bin
		push bc
		ld b,a
		ld a,(rtc_dm)
		or a
		ld a,b
		pop bc
		ret nz
		jp bcd_to_bin

;--- bcd_to_bin: A=BCD byte (0x00-0x99) -> A=binary (0-99) ---
bcd_to_bin	push bc
		ld c,a
		and #0f
		ld b,a			; b = units digit
		ld a,c
		and #f0
		rrca
		rrca
		rrca
		rrca			; a = tens digit
		ld c,a
		add a,a
		add a,a
		add a,a
		add a,c
		add a,c			; a = tens*10
		add a,b			; + units
		pop bc
		ret

;--- rtc_to_fat_datetime: reads the RTC and packs it into fat_date/
;--- fat_time (standard FAT32 directory-entry format). Assumes a
;--- 2000+YY year, matching how zifi.asm's own write_rtc stores just
;--- the last 2 digits of a 4-digit SNTP-sourced year into the RTC. ---
fat_date	dw 0
fat_time	dw 0
rtc_cached	db 0

rtc_to_fat_datetime
		; touch the real RTC chip at most ONCE per boot -- this test
		; suite calls rtc_to_fat_datetime 8 times (once per MKDIR/
		; MKFILE-shaped test), and unlike zifi.asm's own write_rtc
		; (called exactly once, at one deliberate point), doing the
		; full di/select-register/read sequence 8 times back-to-back
		; is real, repeated stress on hardware this project has
		; already found to be timing-sensitive in not-fully-understood
		; ways (see [[project-zifi-rtc-time-sync]]). All 8 call sites
		; just want "the current stamp for this test run" -- a single
		; real read, reused, is both safer and more correct than 8
		; independent (and needlessly different-by-a-few-seconds)
		; reads of the same boot.
		ld a,(rtc_cached)
		or a
		ret nz

		call read_rtc_datetime

		ld a,(rtc_year)
		call rtc_field_to_bin
		add a,20		; (2000+YY)-1980 = YY+20
		ld h,a
		ld l,0
		add hl,hl		; hl = (year-1980) << 9
		ld (fat_date),hl

		ld a,(rtc_month)
		call rtc_field_to_bin
		ld h,0
		ld l,a
		add hl,hl
		add hl,hl
		add hl,hl
		add hl,hl
		add hl,hl		; hl = month << 5
		ld de,(fat_date)
		add hl,de
		ld (fat_date),hl

		ld a,(rtc_date)
		call rtc_field_to_bin
		ld h,0
		ld l,a			; day, no shift (bits 4-0)
		ld de,(fat_date)
		add hl,de
		ld (fat_date),hl

		ld a,(rtc_hour)
		call rtc_field_to_bin
		ld h,a
		ld l,0
		add hl,hl
		add hl,hl
		add hl,hl		; hl = hour << 11 (== (hour<<8)*8)
		ld (fat_time),hl

		ld a,(rtc_min)
		call rtc_field_to_bin
		ld h,0
		ld l,a
		add hl,hl
		add hl,hl
		add hl,hl
		add hl,hl
		add hl,hl		; hl = minute << 5
		ld de,(fat_time)
		add hl,de
		ld (fat_time),hl

		ld a,(rtc_sec)
		call rtc_field_to_bin
		srl a			; 2-second resolution
		ld h,0
		ld l,a
		ld de,(fat_time)
		add hl,de
		ld (fat_time),hl

		ld a,1
		ld (rtc_cached),a
		ret

;--- stamp_dir_entry_datetime: writes fat_time/fat_date (already
;--- computed by rtc_to_fat_datetime) into the CURRENT dir_entry_buf's
;--- CrtTime/CrtDate/LstAccDate/WrtTime/WrtDate fields. Leaves
;--- CrtTimeTenth (offset 13) at 0 -- hundredths-of-a-second precision
;--- the RTC doesn't provide anyway. Call after clear_dir_entry (which
;--- already zeroed these), before the cluster/size fields. ---
stamp_dir_entry_datetime
		ld hl,(fat_time)
		ld (dir_entry_buf+14),hl	; CrtTime
		ld (dir_entry_buf+22),hl	; WrtTime
		ld hl,(fat_date)
		ld (dir_entry_buf+16),hl	; CrtDate
		ld (dir_entry_buf+18),hl	; LstAccDate
		ld (dir_entry_buf+24),hl	; WrtDate
		ret

;--- test_mkdir: creates a directory named "TESTDIR" in the root, to
;--- exercise the whole write path end to end: free-cluster search, FAT
;--- entry write (mirrored to every FAT copy), cluster zero-fill, the
;--- new directory's own "." and ".." entries, and its entry written
;--- into the parent (the root). A=0 ok, A=1 fail. ---

;--- sdbuf MUST be word-aligned (even address) -- the TS-Conf DMA
;--- controller masks the low bit off BOTH DMASAL and DMADAL (silently
;--- rounding down to the nearest even address, since DMA moves 16-bit
;--- words) -- confirmed against the emulator's own io.cpp
;--- (TSW_DMASAL/TSW_DMADAL: "val & 0xFE"). sdbuf had no explicit
;--- alignment before and just happened to land on an even address in
;--- every earlier build of this driver -- today's edits shifted the
;--- preceding code size by an odd amount, landing it on an ODD address
;--- for the first time, which silently shifted every DMA transfer
;--- to/from sdbuf one byte early (byte-for-byte otherwise correct --
;--- confirmed via a full 512-byte diff against the real card image).
;--- This explains "zifi.ini not found" surviving even after the
;--- #2000-overlap fix, and is likely what actually happened on real
;--- hardware too (this masking is real DMA hardware behavior, not an
;--- emulator quirk) -- ALIGN 2 makes this impossible to regress by
;--- accident again. See [[project-zifi-custom-sd-driver]]. ---
		ALIGN 2
sdbuf		ds 512

;=====================================================================
; VFAT long-filename support: real ZiFi calls FENTRY/MKDIR/MKFILE with
; free-form ASCII names (e.g. "downloads" = 9 chars, a date folder like
; "2026_09_05" = 10 chars) that don't fit an 8.3 short name (8-char
; base limit) -- WDFCVBI2.COD's real, confirmed short-name-collision
; bug (the whole reason this project exists) lives in exactly this
; machinery, so this driver needs a correct, from-scratch
; implementation, not a shortcut. Short name generation follows the
; standard Windows "basis name" scheme: uppercase, drop disallowed
; chars/spaces, truncate to 6+"~N"+ext when needed, N chosen to avoid a
; collision with what's already in the target directory. LFN entries
; (attr 0x0F) store the long name in reverse sequence order immediately
; before the short entry, each carrying the short entry's checksum so a
; reader can detect an orphaned/corrupt LFN run (this is the actual
; mechanism the original \downloads corruption happened in).
;=====================================================================

;--- lfn_checksum: HL -> 11-byte short name -> A = standard FAT LFN
;--- checksum (RRCA is a circular rotate-right, exactly the "wrap low
;--- bit into bit 7" step the algorithm needs -- no separate rotate-
;--- through-carry dance required). ---

lfn_checksum	ld b,11
		xor a
lfnck_loop	rrca
		add a,(hl)
		inc hl
		djnz lfnck_loop
		ret

;--- classify_char: A = input byte -> A = filtered/uppercased byte,
;--- carry SET if this byte is allowed in an 8.3 short name (A-Z after
;--- uppercasing, 0-9, or one of a small punctuation allowlist), carry
;--- CLEAR if not (space, dot, or anything else -- caller drops it and
;--- must remember a long name is needed). ---
cc_symbols	db "!#$%&'()-@^_`{}~",0

classify_char	cp 'a'
		jr c,cc_up
		cp 'z'+1
		jr nc,cc_up
		sub 'a'-'A'
cc_up		cp 'A'
		jr c,cc_dig
		cp 'Z'+1
		jr c,cc_yes
cc_dig		cp '0'
		jr c,cc_sym
		cp '9'+1
		jr c,cc_yes
cc_sym		ld b,a
		ld hl,cc_symbols
cc_symloop	ld a,(hl)
		or a
		jr z,cc_no
		cp b
		jr z,cc_symyes
		inc hl
		jr cc_symloop
cc_symyes	ld a,b
cc_yes		scf
		ret
cc_no		xor a
		ret

;--- filter_name_to_83: HL -> NUL-terminated ASCII name (caller-owned,
;--- not modified) -> sn_base (8 bytes, space-padded), sn_ext (3 bytes,
;--- space-padded), sn_needs_lfn (1 if the short name had to drop/
;--- truncate/case-fold anything -- i.e. a real long name is needed),
;--- sn_name_len (name length excluding the NUL, for the LFN
;--- entry-count calculation later). The extension is whatever follows
;--- the LAST '.' in the name (an earlier '.' is just an invalid
;--- character in the base, same as any other disallowed byte). ---
sn_base		ds 8
sn_ext		ds 3
sn_needs_lfn	db 0
sn_name_len	dw 0
sn_dot_pos	dw 0		; 0xFFFF = no dot in the name
sn_base_len	dw 0		; length of the base substring (before ext)
fn83_charbuf	db 0		; scratch: classify_char's filtered byte, held
				; across the flag-clobbering slot-count compare

filter_name_to_83
		push hl
		ld bc,0
		ld de,#ffff
		ld (sn_dot_pos),de
fn83_scan	ld a,(hl)
		or a
		jr z,fn83_scandone
		cp '.'
		jr nz,fn83_scan_next
		ld (sn_dot_pos),bc
fn83_scan_next	inc hl
		inc bc
		jr fn83_scan
fn83_scandone	ld (sn_name_len),bc
		pop hl

		ld a,' '
		ld (sn_base+0),a
		ld (sn_base+1),a
		ld (sn_base+2),a
		ld (sn_base+3),a
		ld (sn_base+4),a
		ld (sn_base+5),a
		ld (sn_base+6),a
		ld (sn_base+7),a
		ld (sn_ext+0),a
		ld (sn_ext+1),a
		ld (sn_ext+2),a
		xor a
		ld (sn_needs_lfn),a

		; base substring length = (no dot) ? name_len : dot_pos
		ld de,(sn_dot_pos)
		ld a,d
		cp #ff
		jr nz,fn83_have_baselen
		ld a,e
		cp #ff
		jr nz,fn83_have_baselen
		ld de,(sn_name_len)
fn83_have_baselen
		ld (sn_base_len),de

		; walk the base substring, filtering into sn_base (up to 8).
		; hl still points at the start of the original name (from the
		; pop above); de = remaining base chars to consume; c = how
		; many of the 8 sn_base slots are filled so far; ix -> next
		; free slot. classify_char returns the filtered char in A
		; *and* sets/clears carry in the same instruction, so the char
		; is stashed to a scratch byte before any flag-clobbering
		; count compare, then reloaded once the compare is done.
		ld bc,0
		ld ix,sn_base
fn83_base_loop	ld a,e
		or d
		jr z,fn83_ext		; de==0 -- consumed the whole base substring
		dec de
		ld a,(hl)
		inc hl
		call classify_char
		jr nc,fn83_base_bad
		ld (fn83_charbuf),a
		ld a,c
		cp 8
		jr nc,fn83_base_full
		ld a,(fn83_charbuf)
		ld (ix+0),a
		inc ix
		inc c
		jr fn83_base_loop
fn83_base_full	ld a,1
		ld (sn_needs_lfn),a
		jr fn83_base_loop
fn83_base_bad	ld a,1
		ld (sn_needs_lfn),a
		jr fn83_base_loop

		; hl now points exactly at the '.' (if the name had one) or at
		; the terminating NUL (if it didn't) -- the base loop above
		; consumed exactly sn_base_len chars, which by construction
		; equals sn_dot_pos when a dot exists.
fn83_ext	ld de,(sn_dot_pos)
		ld a,d
		cp #ff
		jr nz,fn83_ext_go
		ld a,e
		cp #ff
		ret z			; no dot at all -- sn_ext stays blank, done

fn83_ext_go	inc hl			; hl = ext start pointer
		push hl
		ld hl,(sn_name_len)
		ld bc,(sn_dot_pos)
		or a
		sbc hl,bc
		dec hl			; hl = ext_len (name_len - dot_pos - 1)
		push hl
		pop de			; de = ext_len (counter)
		pop hl			; hl = ext start pointer, restored

		ld bc,0
		ld ix,sn_ext
fn83_ext_loop	ld a,e
		or d
		ret z			; consumed the whole ext substring
		dec de
		ld a,(hl)
		inc hl
		call classify_char
		jr nc,fn83_ext_bad
		ld (fn83_charbuf),a
		ld a,c
		cp 3
		jr nc,fn83_ext_full
		ld a,(fn83_charbuf)
		ld (ix+0),a
		inc ix
		inc c
		jr fn83_ext_loop
fn83_ext_full	ld a,1
		ld (sn_needs_lfn),a
		jr fn83_ext_loop
fn83_ext_bad	ld a,1
		ld (sn_needs_lfn),a
		jr fn83_ext_loop

;--- generate_unique_shortname: (cur_cluster_hi,cur_cluster_lo already
;--- set by caller to the target directory) + HL -> the same NUL-
;--- terminated ASCII name filter_name_to_83 was just run on -> builds
;--- the final 11-byte short name into target_name (ready for
;--- find_zifi_all / write_dir_entry), trying "~1".."~9" (6-char
;--- truncated base) then "~10".."~99" (5-char truncated base) whenever
;--- sn_needs_lfn is set, re-checking find_zifi_all each try so the
;--- result never collides with an existing entry in that directory.
;--- A=0 ok, A=1 fail (exhausted ~99, directory has too many
;--- collisions -- not expected in practice here). ---
gus_suffix	db 0		; numeric tail, 1-99

generate_unique_shortname
		ld a,(sn_needs_lfn)
		or a
		jr nz,gus_needs_suffix

		; short name fits as-is (already validated by the caller's
		; classify pass into sn_base/sn_ext) -- just check it doesn't
		; happen to already exist under this exact 8.3 name
		ld hl,sn_base
		ld de,target_name
		ld bc,8
		ldir
		ld hl,sn_ext
		ld bc,3
		ldir
		call find_zifi_all
		or a
		jr z,gus_ok		; not found -- this exact name is free
		; collides with an existing exact-8.3 entry -- fall back to
		; the ~N scheme too, same as if truncation had been needed
gus_needs_suffix
		ld a,1
		ld (gus_suffix),a
gus_try		ld a,(gus_suffix)
		cp 10
		jr c,gus_try_1digit
		; 2-digit suffix: 5 base chars + "~" + 2 digits = 8
		ld hl,sn_base
		ld de,target_name
		ld bc,5
		ldir
		ld de,target_name+5
		ld a,'~'
		ld (de),a
		inc de
		ld a,(gus_suffix)
		call bin_to_2dig
		ld (de),a
		inc de
		ld a,b			; second digit, set by bin_to_2dig
		ld (de),a
		jr gus_have_candidate
gus_try_1digit	; 1-digit suffix: 6 base chars + "~" + 1 digit = 8
		ld hl,sn_base
		ld de,target_name
		ld bc,6
		ldir
		ld de,target_name+6
		ld a,'~'
		ld (de),a
		inc de
		ld a,(gus_suffix)
		add a,'0'
		ld (de),a
gus_have_candidate
		ld hl,sn_ext
		ld de,target_name+8
		ld bc,3
		ldir

		call find_zifi_all
		or a
		jr z,gus_ok		; not found -- this candidate is free

		ld hl,gus_suffix
		inc (hl)
		ld a,(hl)
		cp 100
		jr c,gus_try
		xor a
		inc a
		ret			; exhausted 1..99

gus_ok		xor a
		ret

;--- bin_to_2dig: A = 10..99 -> A = tens digit ('1'-'9'), B = ones
;--- digit ('0'-'9'). Small helper, only ever called with 2-digit
;--- input here. ---
bin_to_2dig	ld b,0
btd_loop	cp 10
		jr c,btd_done
		sub 10
		inc b
		jr btd_loop
btd_done	; b = tens count (0-9), a = ones remainder (0-9)
		ld c,a
		ld a,b
		add a,'0'	; tens digit char
		ld b,a
		ld a,c
		add a,'0'	; ones digit char
		ld c,a
		ld a,b		; final A = tens char
		ld b,c		; final B = ones char
		ret

;--- test_shortname_gen: exercises filter_name_to_83 + generate_unique_
;--- shortname against a few real ZiFi-shaped names (some short enough
;--- to fit 8.3 as-is, some needing truncation) and prints each result
;--- (generated 11-byte short name + whether an LFN was judged
;--- necessary) -- checked here in isolation, on real hardware, before
;--- building the LFN-entry writer and long-name-aware FENTRY on top of

wne_max_lfn	equ 8
wne_entries_buf	ds (wne_max_lfn+1)*32
wne_slot_count	db 0

lfn_char_dest	db 1,3,5,7,9,14,16,18,20,22,24,28,30

ble_name_ptr	dw 0
ble_lfn_count	db 0
ble_checksum	db 0
ble_j		db 0
ble_charpos	dw 0
ble_entry_ptr	dw 0

build_lfn_entries
		ld (ble_name_ptr),hl
		ld a,(sn_needs_lfn)
		or a
		jr nz,ble_multi

		; no LFN needed -- just the short entry
		ld hl,dir_entry_buf
		ld de,wne_entries_buf
		ld bc,32
		ldir
		ld hl,target_name
		ld de,wne_entries_buf
		ld bc,11
		ldir
		ld a,1
		ld (wne_slot_count),a
		ret

ble_multi	; lfn_count = ceil((name_len+1)/13) = (name_len+13)/13
		ld hl,(sn_name_len)
		ld de,13
		add hl,de
		ld b,0
ble_divloop	ld de,13
		or a
		sbc hl,de
		jr c,ble_divdone
		inc b
		jr ble_divloop
ble_divdone	ld a,b
		ld (ble_lfn_count),a
		inc a
		ld (wne_slot_count),a

		ld hl,target_name
		call lfn_checksum
		ld (ble_checksum),a

		ld a,(ble_lfn_count)
		ld (ble_j),a

ble_lfn_loop	ld a,(ble_j)
		or a
		jp z,ble_lfn_done

		; storage index i = lfn_count - j; entry_ptr = wne_entries_buf
		; + i*32
		ld b,a
		ld a,(ble_lfn_count)
		sub b
		ld l,a
		ld h,0
		add hl,hl
		add hl,hl
		add hl,hl
		add hl,hl
		add hl,hl
		ld de,wne_entries_buf
		add hl,de
		ld (ble_entry_ptr),hl

		; zero the whole 32-byte entry first -- simplifies padding,
		; only the bytes that need something other than 0x00 (the
		; 0xFF pad bytes) are patched explicitly below
		ld d,h
		ld e,l
		inc de
		ld bc,31
		ld (hl),0
		ldir

		; seq byte = j | (0x40 "last" bit, only on the highest j)
		ld hl,(ble_entry_ptr)
		ld a,(ble_j)
		ld b,a
		ld a,(ble_lfn_count)
		cp b
		jr nz,ble_notlast
		ld a,b
		or #40
		jr ble_seqset
ble_notlast	ld a,b
ble_seqset	ld (hl),a

		ld hl,(ble_entry_ptr)
		ld de,11
		add hl,de
		ld a,#0f
		ld (hl),a		; attr = ATTR_LONG_NAME

		ld hl,(ble_entry_ptr)
		ld de,13
		add hl,de
		ld a,(ble_checksum)
		ld (hl),a

		; char_offset (0-based index into the name) = (j-1)*13
		ld a,(ble_j)
		dec a
		ld b,a
		ld hl,0
ble_mul13	ld a,b
		or a
		jr z,ble_mul13done
		ld de,13
		add hl,de
		dec b
		jr ble_mul13
ble_mul13done	ld (ble_charpos),hl

		ld b,0			; b = k, which of the 13 char slots
ble_charloop	ld a,b
		cp 13
		jr nc,ble_lfn_next

		ld hl,(ble_charpos)
		push bc
		ld c,b
		ld b,0
		add hl,bc
		pop bc			; hl = charpos = ble_charpos + k

		push hl
		ld de,(sn_name_len)
		or a
		sbc hl,de
		pop hl			; flags from the compare survive the
					; pop (only POP AF touches flags);
					; hl restored to charpos itself
		jr z,ble_char_isnull
		jr c,ble_char_isreal
		ld a,#ff
		jr ble_char_have
ble_char_isreal	push hl
		ld hl,(ble_name_ptr)
		pop de
		add hl,de
		ld a,(hl)
		jr ble_char_have
ble_char_isnull	xor a
ble_char_have	push af
		ld hl,lfn_char_dest
		ld d,0
		ld e,b
		add hl,de
		ld e,(hl)
		ld hl,(ble_entry_ptr)
		ld d,0
		add hl,de
		pop af
		ld (hl),a
		inc hl
		cp #ff
		jr nz,ble_char_hi0
		ld (hl),#ff
		jr ble_char_nextk
ble_char_hi0	ld (hl),0
ble_char_nextk	inc b
		jr ble_charloop

ble_lfn_next	ld hl,ble_j
		dec (hl)
		jp ble_lfn_loop

ble_lfn_done	; short entry goes right after the last LFN entry, at
		; wne_entries_buf + lfn_count*32
		ld a,(ble_lfn_count)
		ld l,a
		ld h,0
		add hl,hl
		add hl,hl
		add hl,hl
		add hl,hl
		add hl,hl
		ld de,wne_entries_buf
		add hl,de
		ld (ble_entry_ptr),hl

		push hl
		pop de
		ld hl,dir_entry_buf
		ld bc,32
		ldir

		ld hl,target_name
		ld de,(ble_entry_ptr)
		ld bc,11
		ldir
		ret

;--- find_free_run: (cur_cluster_hi,cur_cluster_lo already set by
;--- caller to the target directory's first cluster) + wne_slot_count
;--- (already set, e.g. by build_lfn_entries) -> wne_free_index_hi/lo,
;--- the logical 32-byte-entry index (counted from the directory's own
;--- start) where a run of wne_slot_count consecutive free (0x00 or
;--- 0xE5) slots begins. Grows the directory with one freshly
;--- allocated, ZERO-FILLED cluster (via the same find_free_cluster/
;--- write_fat_entry pair stream_write_sector's own on-demand
;--- allocation uses) whenever the existing chain runs out before
;--- enough free slots are found -- zero-filled specifically because a
;--- directory (unlike a file) has no SIZE field bounding valid
;--- entries, so any non-zero leftover byte past the true end could be
;--- mistaken for a real entry by a scan. A=0 ok, A=1 fail (disk
;--- error only -- running out of chain always grows instead of
;--- failing). ---

wne_run_len		db 0
wne_run_start_hi	dw 0
wne_run_start_lo	dw 0
wne_cur_index_hi	dw 0
wne_cur_index_lo	dw 0
wne_free_index_hi	dw 0
wne_free_index_lo	dw 0

find_free_run	call stream_open
		xor a
		ld (wne_run_len),a
		ld hl,0
		ld (wne_cur_index_hi),hl
		ld (wne_cur_index_lo),hl

ffr_sector_loop	ld a,(stream_eoc)
		or a
		jr z,ffr_have_sector
		call ffr_grow_dir
		or a
		jp nz,ffr_fail
		jr ffr_sector_loop

ffr_have_sector	call strm_calc_sector
		ld hl,(strm_sector_hi)
		ld de,(strm_sector_lo)
		call set_lba32
		call sdread_lba
		or a
		jr nz,ffr_fail

		ld hl,sdbuf
		ld b,16
ffr_entloop	push bc
		ld a,(hl)
		or a
		jr z,ffr_free
		cp #e5
		jr z,ffr_free
		xor a
		ld (wne_run_len),a
		jr ffr_advance_index

ffr_free	ld a,(wne_run_len)
		or a
		jr nz,ffr_free_cont
		ld de,(wne_cur_index_lo)
		ld (wne_run_start_lo),de
		ld de,(wne_cur_index_hi)
		ld (wne_run_start_hi),de
ffr_free_cont	ld a,(wne_run_len)
		inc a
		ld (wne_run_len),a
		ld c,a
		ld a,(wne_slot_count)
		cp c
		jr nz,ffr_advance_index

		ld de,(wne_run_start_lo)
		ld (wne_free_index_lo),de
		ld de,(wne_run_start_hi)
		ld (wne_free_index_hi),de
		pop bc
		xor a
		ret

ffr_advance_index
		ld de,(wne_cur_index_lo)
		inc de
		ld (wne_cur_index_lo),de
		ld a,d
		or e
		jr nz,ffr_no_hi_carry
		ld de,(wne_cur_index_hi)
		inc de
		ld (wne_cur_index_hi),de
ffr_no_hi_carry
		pop bc
		ld de,32
		add hl,de
		djnz ffr_entloop

		call strm_advance
		jp ffr_sector_loop

ffr_fail	xor a
		inc a
		ret

;--- ffr_grow_dir: links a freshly allocated, zero-filled cluster onto
;--- the end of the directory chain stream_cluster_hi/lo currently
;--- points at (the true last cluster, since find_free_run only calls
;--- this once stream_eoc says the chain has ended there), then resets
;--- the stream to continue scanning into it. Mirrors stream_write_
;--- sector's own on-demand allocation exactly, plus an explicit
;--- zero_fill_cluster (stream_write_sector doesn't need that for a
;--- FILE, since slack space past its SIZE field is legitimately
;--- ignored -- a directory has no such bound). ---
ffr_grow_dir	ld hl,(stream_cluster_hi)
		ld (cur_cluster_hi),hl
		ld hl,(stream_cluster_lo)
		ld (cur_cluster_lo),hl
		call find_free_cluster
		or a
		ret nz

		ld hl,(stream_cluster_hi)
		ld (cur_cluster_hi),hl
		ld hl,(stream_cluster_lo)
		ld (cur_cluster_lo),hl
		ld hl,(free_cluster_hi)
		ld (new_val_hi),hl
		ld hl,(free_cluster_lo)
		ld (new_val_lo),hl
		call write_fat_entry
		or a
		ret nz

		ld hl,(free_cluster_hi)
		ld (cur_cluster_hi),hl
		ld hl,(free_cluster_lo)
		ld (cur_cluster_lo),hl
		ld hl,#0fff
		ld (new_val_hi),hl
		ld hl,#ffff
		ld (new_val_lo),hl
		call write_fat_entry
		or a
		ret nz

		ld hl,(free_cluster_hi)
		ld (cur_cluster_hi),hl
		ld hl,(free_cluster_lo)
		ld (cur_cluster_lo),hl
		call zero_fill_cluster
		or a
		ret nz

		ld hl,(free_cluster_hi)
		ld (stream_cluster_hi),hl
		ld hl,(free_cluster_lo)
		ld (stream_cluster_lo),hl
		xor a
		ld (stream_sec_in_cluster),a
		ld (stream_eoc),a
		ret

;--- write_name_entries: (cur_cluster_hi,cur_cluster_lo already set by
;--- caller to the target directory's first cluster) + wne_free_index_
;--- hi/lo + wne_slot_count (both already set by find_free_run) +
;--- wne_entries_buf (already filled by build_lfn_entries) -> writes
;--- those wne_slot_count consecutive 32-byte entries to disk at the
;--- located run. Walks the directory stream from its very start again
;--- (simpler and safe -- these directories are small -- than trying to
;--- seek directly to an arbitrary mid-stream sector), patching and
;--- writing back only the sectors that actually contain one or more of
;--- the target slots. A=0 ok, A=1 fail (disk error). ---
wne_w_entptr		dw 0
wne_w_entcount		db 0
wne_w_dirty		db 0
wne_w_this_sec_hi	dw 0
wne_w_this_sec_lo	dw 0

write_name_entries
		call stream_open
		ld hl,0
		ld (wne_cur_index_lo),hl

wne_w_sector_loop
		; stop once cur_index has reached free_index+slot_count (all
		; slots placed) -- 16-bit compare only, matching the same
		; simplification find_free_run's index tracking already makes
		; (this project's directories never approach 65536 entries)
		ld hl,(wne_free_index_lo)
		ld a,(wne_slot_count)
		ld d,0
		ld e,a
		add hl,de
		ld de,(wne_cur_index_lo)
		or a
		sbc hl,de
		jr z,wne_w_done
		jr nc,wne_w_continue
wne_w_done	xor a
		ret

wne_w_continue	ld a,(stream_eoc)
		or a
		jp nz,wne_w_fail	; shouldn't happen -- find_free_run
					; already grew the chain if needed

		call strm_calc_sector
		ld hl,(strm_sector_hi)
		ld (wne_w_this_sec_hi),hl
		ld hl,(strm_sector_lo)
		ld (wne_w_this_sec_lo),hl
		ld hl,(strm_sector_hi)
		ld de,(strm_sector_lo)
		call set_lba32
		call sdread_lba
		or a
		jr nz,wne_w_fail

		xor a
		ld (wne_w_dirty),a
		ld hl,sdbuf
		ld (wne_w_entptr),hl
		ld a,16
		ld (wne_w_entcount),a

wne_w_entloop	ld hl,(wne_cur_index_lo)
		ld de,(wne_free_index_lo)
		or a
		sbc hl,de		; hl = cur_index - free_index
		jr c,wne_w_notinrange	; cur_index < free_index -- too early
		ld a,h
		or a
		jr nz,wne_w_notinrange	; delta > 255 -- past the run
		ld a,l			; a = delta -- the entries_buf slot
					; number, IF it's < slot_count
		ld b,a
		ld a,(wne_slot_count)
		cp b
		jr c,wne_w_notinrange	; slot_count < delta+1 -- past the run
		jr z,wne_w_notinrange	; slot_count == delta -- also past
					; (valid range is delta 0..slot_count-1)

		ld l,b
		ld h,0
		add hl,hl
		add hl,hl
		add hl,hl
		add hl,hl
		add hl,hl
		ld de,wne_entries_buf
		add hl,de		; hl = source (wne_entries_buf+delta*32)
		ld de,(wne_w_entptr)	; de = destination (this sdbuf entry)
		push de
		ld bc,32
		ldir
		pop de
		ld a,1
		ld (wne_w_dirty),a

wne_w_notinrange
		ld hl,(wne_cur_index_lo)
		inc hl
		ld (wne_cur_index_lo),hl
		ld hl,(wne_w_entptr)
		ld de,32
		add hl,de
		ld (wne_w_entptr),hl
		ld hl,wne_w_entcount
		dec (hl)
		jr nz,wne_w_entloop

		ld a,(wne_w_dirty)
		or a
		jr z,wne_w_skip_write
		ld hl,(wne_w_this_sec_hi)
		ld de,(wne_w_this_sec_lo)
		call set_lba32
		call sdwrite_lba
		or a
		jp nz,wne_w_fail
wne_w_skip_write
		call strm_advance
		jp wne_w_sector_loop

wne_w_fail	xor a
		inc a
		ret

;--- test_lfn_write: creates a SUBDIRECTORY named "long_name_test_dir"
;--- (18 chars, needs LFN) inside the already-existing TESTDIRA -- the
;--- first real disk write exercising build_lfn_entries/find_free_run/
;--- write_name_entries together. Deliberately scoped to TESTDIRA (a
;--- test-only directory from earlier in this file), not root, so noth-
;--- ing near the card's real ZiFi/downloads data is touched. Verified
;--- externally (Windows Explorer/dir over the card reader showing the
;--- long name correctly, plus chkdsk finding no new corruption) rather
;--- than by a from-scratch long-name search, since that (FENTRY-style
;--- LFN reconstruction) hasn't been built yet -- this test's whole
;--- point is proving the entries this driver just wrote are valid
;--- enough for an independent, already-correct FAT32 reader (Windows'
;--- own) to parse. A=0 ok, A=1 fail (tlw_stage: 0=TESTDIRA not found,
;--- 1=find_free_cluster, 2=write_fat_entry, 3=zero_fill_cluster,
;--- 4=generate_unique_shortname, 5=find_free_run, 6=write_name_entries). ---

;=====================================================================
; Long-name-aware directory search (real FENTRY's job): reconstructs a
; long name from any valid LFN entries immediately preceding a short
; entry (checksum-verified against that short entry -- an orphaned/
; corrupt LFN run, exactly the class of bug that started this whole
; project, is detected and falls back to the short name instead of
; trusting garbage), case-insensitively, matching FAT's own semantics.
;=====================================================================

;--- to_upper: A -> A, uppercased if a-z, unchanged otherwise. Plain
;--- case-fold only, unlike classify_char (which also REJECTS bytes
;--- like '.' that a general string compare must still accept). ---
to_upper	cp 'a'
		ret c
		cp 'z'+1
		ret nc
		sub 'a'-'A'
		ret

;--- str_eq_ci: hl,de -> two NUL-terminated strings -> Z if equal
;--- (case-insensitive), NZ otherwise. ---
str_eq_ci	ld a,(hl)
		call to_upper
		ld b,a
		ld a,(de)
		call to_upper
		cp b
		jr nz,seci_ne
		or a
		jr z,seci_eq
		inc hl
		inc de
		jr str_eq_ci
seci_ne		xor a
		inc a
		ret
seci_eq		xor a
		ret

;--- render_shortname: hl -> 11-byte short name -> de -> dest buffer,
;--- writes "BASE.EXT" (or just "BASE" if the extension is blank),
;--- trimming trailing spaces, NUL-terminated. hl/de both clobbered. ---
render_shortname
		push de
		ld b,8
rsn_base	ld a,(hl)
		cp ' '
		jr z,rsn_base_skip
		ld (de),a
		inc hl
		inc de
		djnz rsn_base
		jr rsn_ext_prep
rsn_base_skip	inc hl
		djnz rsn_base_skip
rsn_ext_prep	ld a,(hl)
		cp ' '
		jr z,rsn_done
		ld a,'.'
		ld (de),a
		inc de
		ld b,3
rsn_ext		ld a,(hl)
		cp ' '
		jr z,rsn_done
		ld (de),a
		inc hl
		inc de
		djnz rsn_ext
rsn_done	xor a
		ld (de),a
		pop de
		ret

;--- find_by_name: (cur_cluster_hi,cur_cluster_lo already set by caller
;--- to the directory to search) + HL -> NUL-terminated ASCII name ->
;--- A=1 + fbn_cluster_hi/fbn_cluster_lo/fbn_size_hi/fbn_size_lo/
;--- fbn_attr if found, A=0 if not. Also tracks fbn_match_index_lo (the
;--- matched short entry's own logical 32-byte-entry index, counted
;--- from the directory's start) and fbn_match_run_start_lo (the index
;--- where its preceding LFN run started, or the same as fbn_match_
;--- index_lo if no LFN was involved) -- used by core_delfl/core_renam
;--- to know exactly which entries to mark deleted. ---
fbn_name_ptr		dw 0
fbn_lfn_buf		ds (wne_max_lfn*13)+1
fbn_lfn_checksum	db 0
fbn_lfn_seen		db 0
fbn_acc_dest		dw 0
fbn_cluster_hi		dw 0
fbn_cluster_lo		dw 0
fbn_size_hi		dw 0
fbn_size_lo		dw 0
fbn_attr		db 0
fbn_render_buf		ds 13
fbn_cur_index_lo	dw 0
fbn_run_start_lo	dw 0
fbn_match_index_lo	dw 0
fbn_match_run_start_lo	dw 0

find_by_name	ld (fbn_name_ptr),hl
		call stream_open
		xor a
		ld (fbn_lfn_seen),a
		ld hl,0
		ld (fbn_cur_index_lo),hl

fbn_sector_loop	ld a,(stream_eoc)
		or a
		jp nz,fbn_notfound

		call strm_calc_sector
		ld hl,(strm_sector_hi)
		ld de,(strm_sector_lo)
		call set_lba32
		call sdread_lba
		or a
		jp nz,fbn_notfound

		ld hl,sdbuf
		ld b,16
fbn_entloop	push bc
		ld a,(hl)
		or a
		jp z,fbn_notfound_pop
		cp #e5
		jr z,fbn_deleted

		push hl
		ld de,11
		add hl,de
		ld a,(hl)
		pop hl
		cp #0f
		jr z,fbn_is_lfn

		call fbn_try_match
		jp z,fbn_matched
		xor a
		ld (fbn_lfn_seen),a
		jr fbn_next

fbn_is_lfn	ld a,(fbn_lfn_seen)
		or a
		jr nz,fbn_lfn_cont
		ld de,(fbn_cur_index_lo)
		ld (fbn_run_start_lo),de
fbn_lfn_cont	call fbn_accumulate_lfn
		jr fbn_next

fbn_deleted	xor a
		ld (fbn_lfn_seen),a
		jr fbn_next

fbn_next	pop bc
		ld de,32
		add hl,de
		push hl
		ld hl,(fbn_cur_index_lo)
		inc hl
		ld (fbn_cur_index_lo),hl
		pop hl
		djnz fbn_entloop

		call strm_advance
		jp fbn_sector_loop

fbn_notfound_pop
		pop bc
fbn_notfound	xor a
		ret

fbn_matched	pop bc
		ld hl,(fbn_cur_index_lo)
		ld (fbn_match_index_lo),hl
		ld a,(fbn_lfn_seen)
		or a
		jr z,fbn_matched_norun
		ld hl,(fbn_run_start_lo)
		jr fbn_matched_setrun
fbn_matched_norun
		ld hl,(fbn_cur_index_lo)
fbn_matched_setrun
		ld (fbn_match_run_start_lo),hl
		xor a
		inc a
		ret

;--- fbn_accumulate_lfn: hl -> a 32-byte LFN entry in sdbuf -> extracts
;--- its 13 characters into fbn_lfn_buf at (seq-1)*13, remembers the
;--- checksum from the highest-sequence ("last"/0x40-flagged) entry. hl
;--- preserved on return. ---
fbn_accumulate_lfn
		ld a,1
		ld (fbn_lfn_seen),a

		ld a,(hl)
		and #40
		jr z,fbn_acc_nocs
		push hl
		ld de,13
		add hl,de
		ld a,(hl)
		ld (fbn_lfn_checksum),a
		pop hl
fbn_acc_nocs	ld a,(hl)
		and #1f
		or a
		ret z
		cp wne_max_lfn+1
		ret nc

		dec a
		ld d,0
		ld e,a
		push hl
		ld hl,0
		ld b,e
		ld a,b
		or a
		jr z,fbn_acc_mul_done
fbn_acc_mul	ld de,13
		add hl,de
		djnz fbn_acc_mul
fbn_acc_mul_done
		ld de,fbn_lfn_buf
		add hl,de
		ld (fbn_acc_dest),hl
		pop hl

		ld b,0
fbn_acc_charloop
		ld a,b
		cp 13
		ret nc

		push hl
		push bc
		ld hl,lfn_char_dest
		ld d,0
		ld e,b
		add hl,de
		ld e,(hl)
		pop bc
		pop hl
		push hl
		ld d,0
		add hl,de
		ld a,(hl)
		ld c,a
		inc hl
		ld a,(hl)
		pop hl

		or a
		jr nz,fbn_acc_pad
		ld a,c
		or a
		jr z,fbn_acc_null

		push hl
		ld hl,(fbn_acc_dest)
		ld d,0
		ld e,b
		add hl,de
		ld (hl),c
		pop hl
		jr fbn_acc_pad

fbn_acc_null	push hl
		ld hl,(fbn_acc_dest)
		ld d,0
		ld e,b
		add hl,de
		ld (hl),0
		pop hl

fbn_acc_pad	inc b
		jr fbn_acc_charloop

;--- fbn_try_match: hl -> a 32-byte short entry in sdbuf -> Z if it
;--- matches fbn_name_ptr's target (via the accumulated LFN, checksum-
;--- verified, or the rendered short name otherwise), NZ if not. On a
;--- match, also fills fbn_cluster_hi/lo/fbn_size_hi/lo. hl preserved
;--- on return either way. ---
fbn_try_match	ld a,(fbn_lfn_seen)
		or a
		jr z,fbn_tm_short

		push hl
		call lfn_checksum
		ld b,a
		pop hl
		ld a,(fbn_lfn_checksum)
		cp b
		jr nz,fbn_tm_short

		push hl
		ld de,fbn_lfn_buf
		ld hl,(fbn_name_ptr)
		call str_eq_ci
		pop hl
		jr z,fbn_tm_yes
		ret

fbn_tm_short	push hl
		ld de,fbn_render_buf
		call render_shortname
		ld de,fbn_render_buf
		ld hl,(fbn_name_ptr)
		call str_eq_ci
		pop hl
		ret nz

fbn_tm_yes	push hl
		ld de,11
		add hl,de
		ld a,(hl)
		ld (fbn_attr),a
		pop hl
		push hl
		ld de,20
		add hl,de
		ld a,(hl)
		ld (fbn_cluster_hi),a
		inc hl
		ld a,(hl)
		ld (fbn_cluster_hi+1),a
		pop hl
		push hl
		ld de,26
		add hl,de
		ld a,(hl)
		ld (fbn_cluster_lo),a
		inc hl
		ld a,(hl)
		ld (fbn_cluster_lo+1),a
		inc hl
		ld a,(hl)
		ld (fbn_size_lo),a
		inc hl
		ld a,(hl)
		ld (fbn_size_lo+1),a
		inc hl
		ld a,(hl)
		ld (fbn_size_hi),a
		inc hl
		ld a,(hl)
		ld (fbn_size_hi+1),a
		pop hl
		xor a
		ret


;=====================================================================
; CORE ABI: persistent "active directory" state, matching real ZiFi's
; actual usage pattern confirmed by reading zifi.asm's own call sites
; (load_ini/set_download_dir): FENTRY("zifi") -> SETDIR -> FENTRY
; ("zifi.ini") -> LOAD512 -> SETROOT. Everything above this point
; (find_by_name etc.) takes an explicit cur_cluster_hi/lo per call;
; these wrap that with the persistent state ZiFi's own calling
; convention needs.
;=====================================================================

active_dir_hi	dw 0
active_dir_lo	dw 0

;--- core_setroot: makes the root directory the active directory. ---
core_setroot	ld hl,(root_cluster_hi)
		ld (active_dir_hi),hl
		ld hl,(root_cluster_lo)
		ld (active_dir_lo),hl
		ret

;--- core_setdir: makes the directory the last core_fentry call found
;--- (fbn_cluster_hi/lo) the active directory -- matches real SETDIR's
;--- doc, "Set DIR found by ENTRY active". ---
core_setdir	ld hl,(fbn_cluster_hi)
		ld (active_dir_hi),hl
		ld hl,(fbn_cluster_lo)
		ld (active_dir_lo),hl
		ret

;--- core_fentry: HL -> NUL-terminated ASCII name -> searches the
;--- ACTIVE directory (active_dir_hi/lo, not a caller-supplied cluster)
;--- via find_by_name. A=1+found (fbn_cluster_hi/lo/fbn_size_hi/lo
;--- set), A=0 not found. ---
core_fentry	push hl
		ld hl,(active_dir_hi)
		ld (cur_cluster_hi),hl
		ld hl,(active_dir_lo)
		ld (cur_cluster_lo),hl
		pop hl
		jp find_by_name

;--- test_setdir_flow: exercises the real ZiFi call pattern end to end
;--- -- SETROOT, FENTRY("TESTDIRA"), SETDIR, FENTRY("long_name_test_
;--- dir3") -- using ONLY the persistent active_dir state (no explicit
;--- cur_cluster pokes from the caller), matching how zifi.asm's own
;--- load_ini/set_download_dir actually call these. A=0 ok, A=1 fail
;--- (tsdf_stage: 0=TESTDIRA not found, 1=long_name_test_dir3 not found
;--- inside it). ---

;=====================================================================
; CORE ABI: LOAD512/SAVE512 -- paged-memory bulk transfer.
;
; SAVE512: i: C=page number, HL=a READY slot-1 CPU address
; (0x4000-0x7FFF, used directly, no offset). Confirmed via zifi.asm's
; real call site (zifi_get, ~line 306-315: "call set_page1" then
; thread.adress = get_buffer = #4000, passed as-is to SAVE512) --
; confirmed as the real cause of "noise mixed with melody" in
; downloaded tracks (see [[project-zifi-custom-sd-driver]]) when this
; used to be assumed as a 0-based slot-3 offset instead.
;
; LOAD512: i: C=page number, HL=a 0-based OFFSET (this driver adds
; 0xC000 -- slot 3 -- internally). NOT the same slot/convention as
; SAVE512 -- confirmed via zifi.asm's ONLY real LOAD512 call site
; (load_ini, ~line 3970: C=download_page, HL=0x0000) cross-checked
; against parse_ini (~line 3978: reads the result back via "call
; set_page3 / ld hl,#c000") -- i.e. LOAD512's destination really is
; PAGE3/0xC000, unlike SAVE512's PAGE1/0x4000. Sharing SAVE512's
; convention here was an unverified assumption-by-symmetry that broke
; zifi.ini parsing ("Error parsing ini file") once SAVE512 itself
; started working correctly and load_ini could actually run.
;
; Both: B=block count (512B each), always page-boundary-aligned (a
; page is exactly 32 blocks). o: C,HL=new position (advanced by
; B*512 bytes, wrapping to the next page every 32 blocks); A=#0F on
; EndOfChain. Caller must have already positioned the stream via
; stream_open on the target file/directory's first cluster.
;=====================================================================

page1_port	equ #11af

sv512_page	db 0
sv512_off	dw 0
sv512_count	db 0

;--- core_save512: writes B blocks FROM (page C, offset HL) TO the
;--- current stream position, advancing the stream automatically
;--- (allocating new clusters on demand, same as stream_write_sector_from
;--- always has). A=0 ok, A=#0F if a block's disk write failed (can't
;--- grow the chain -- e.g. card full). ---
;--- No di/ei needed here anymore (matches the original closed
;--- WDFCVBI2.COD driver's own zero-di/ei SAVE512/LOAD512): the
;--- page1_port+LDIR dance that needed PAGE1 held stable across the
;--- whole copy is GONE -- stream_write_sector_from DMAs each block
;--- straight from (sv512_page,sv512_off) to the SD card, addressed by
;--- physical page number, never touching the CPU's slot mapping at
;--- all. That mapping was the actual hazard: set_music_pages_lite
;--- repages PAGE0/1/3 on every interrupt during playback, and a
;--- write-only page port can't be restored afterward -- so any
;--- interrupt firing mid-LDIR could silently redirect part of the
;--- 512-byte copy to whatever page music had just switched to. DMA
;--- sidesteps that mechanism entirely. See
;--- [[project-zifi-custom-sd-driver]] "noise mixed with melody". ---
core_save512	ld a,c
		ld (sv512_page),a
		ld (sv512_off),hl
		ld a,b
		ld (sv512_count),a

sv512_loop	ld a,(sv512_count)
		or a
		jr z,sv512_done

		ld a,(sv512_page)
		ld (dma_xfer_page),a
		ld hl,(sv512_off)
		ld (dma_xfer_off),hl

		call stream_write_sector_from
		or a
		jr nz,sv512_eoc

		call sv512_advance
		ld hl,sv512_count
		dec (hl)
		jr sv512_loop

sv512_done	ld a,(sv512_page)
		ld c,a
		ld hl,(sv512_off)
		xor a
		ret

sv512_eoc	ld a,(sv512_page)
		ld c,a
		ld hl,(sv512_off)
		ld a,#0f
		ret

;--- core_load512: reads B blocks FROM the current stream position
;--- INTO (page C, offset HL), advancing the stream. A=0 ok, A=#0F if
;--- the chain ended (a real read error is also reported as #0F here --
;--- ZiFi's own real call sites don't actually branch on this return
;--- value, they track position via a separately precomputed block
;--- count instead, so exact error-code fidelity beyond "did it stop
;--- early" isn't load-bearing).
;---
;--- SAME slot/offset convention as SAVE512 (PAGE1/direct address),
;--- but its OWN SEPARATE lv512_page/off/count/advance state -- NOT
;--- shared with sv512_* anymore. An earlier version shared state
;--- (kept this byte-for-byte identical to core_save512, to sidestep a
;--- since-abandoned Hrust compression mystery -- see
;--- [[project-zifi-custom-sd-driver]]), but that's a real hazard: a
;--- download's SAVE512 can be mid-transfer (multiple blocks, DI-
;--- protected only for ONE block at a time between di/ei pairs) while
;--- something else (music/playlist code) calls LOAD512 in between --
;--- confirmed on hardware as the cause of renewed "noise mixed with
;--- melody" plus playlist-switch hangs after the shared-state version
;--- shipped. Separate state costs ~15 bytes now that the body is
;--- compressed with a byte-for-byte self-verified PackBits RLE
;--- instead of Hrust (see zc_sd_driver.asm's drv_dos_swp) -- no more
;--- mystery size-dependent decoder bug to worry about. ---
lv512_page	db 0
lv512_off	dw 0
lv512_count	db 0

core_load512	ld a,c
		ld (lv512_page),a
		ld (lv512_off),hl
		ld a,b
		ld (lv512_count),a

lv512_loop	ld a,(lv512_count)
		or a
		jr z,lv512_done

		ld a,(lv512_page)
		ld (dma_xfer_page),a
		ld hl,(lv512_off)
		ld (dma_xfer_off),hl

		call stream_read_sector_to
		or a
		jr nz,lv512_eoc

		call lv512_advance
		ld hl,lv512_count
		dec (hl)
		jr lv512_loop

;--- lv512_advance: same wrap logic as sv512_advance (slot-1,
;--- 0x4000-0x7FFF, one page = 32 blocks), just against lv512_*'s own
;--- separate state. ---
lv512_advance	ld hl,(lv512_off)
		ld de,512
		add hl,de
		ld a,h
		cp #80
		jr c,lv512_nowrap
		ld hl,#4000
		ld a,(lv512_page)
		inc a
		ld (lv512_page),a
lv512_nowrap	ld (lv512_off),hl
		ret

lv512_done	ld a,(lv512_page)
		ld c,a
		ld hl,(lv512_off)
		xor a
		ret

lv512_eoc	ld a,(lv512_page)
		ld c,a
		ld hl,(lv512_off)
		ld a,#0f
		ret

;--- sv512_advance: sv512_off += 512, wrapping to sv512_page+1 (back to
;--- slot-1 offset 0x4000, NOT 0 -- see header comment on the real
;--- 0x4000-0x7FFF convention) once it would leave the 0x4000-0x7FFF
;--- range, i.e. reach 0x8000 (one page = exactly 32 blocks). ---
sv512_advance	ld hl,(sv512_off)
		ld de,512
		add hl,de
		ld a,h
		cp #80
		jr c,sv512_nowrap
		ld hl,#4000
		ld a,(sv512_page)
		inc a
		ld (sv512_page),a
sv512_nowrap	ld (sv512_off),hl
		ret

;--- test_load512_save512: creates "P512TEST.BIN" inside TESTDIRA (via
;--- SETROOT/FENTRY/SETDIR -- dogfooding that machinery, not just the
;--- LFN pipeline directly) if it doesn't already exist, fills page 0
;--- offset 0 (0xC000) with a known byte, SAVE512s one block into the
;--- file, corrupts page 0 with a DIFFERENT byte (so a stale-memory
;--- false pass is impossible), LOAD512s the block back, and checks the
;--- original byte reappeared. A=0 ok, A=1 fail (tls_stage: 0=TESTDIRA
;--- not found, 1=find_free_cluster, 2=write_fat_entry, 3=zero_fill_
;--- cluster, 4=generate_unique_shortname, 5=find_free_run, 6=write_
;--- name_entries, 7=SAVE512 unexpected EOC, 8=LOAD512 unexpected EOC,
;--- 9=readback mismatch). ---

;=====================================================================
; CORE ABI: MKDIR/MKFILE -- create a directory/file with a free-form
; name in the ACTIVE directory (active_dir_hi/lo -- caller must have
; already SETROOT/SETDIR'd there), using the VFAT machinery (duplicate-
; guard via find_by_name, short-name generation, LFN entries). Z=
; success, NZ=error (A: 1=name not valid, 2=index fatality [unused --
; nothing in this driver currently produces it], 3=already exists,
; 255=unknown error) -- matches real MKDIR/MKFILE's documented ABI.
; Both are generalized versions of test_lfn_write's own (hardware-
; confirmed) logic, parameterized by name and active_dir instead of a
; fixed test name/TESTDIRA.
;=====================================================================

cmk_name_ptr	dw 0
cmk_cluster_hi	dw 0
cmk_cluster_lo	dw 0
cmk_sec_hi	dw 0
cmk_sec_lo	dw 0

;--- core_mkdir: HL -> {name(1-255), 0} -> creates a subdirectory (with
;--- its own "."/".." entries) in the active directory. ---
core_mkdir	ld (cmk_name_ptr),hl

		ld b,0
cmkd_lenloop	ld a,(hl)
		or a
		jr z,cmkd_lendone
		inc hl
		inc b
		jr nz,cmkd_lenloop
cmkd_toolong	ld a,1
		or a
		ret
cmkd_lendone	ld a,b
		or a
		jr z,cmkd_toolong

		ld hl,(active_dir_hi)
		ld (cur_cluster_hi),hl
		ld hl,(active_dir_lo)
		ld (cur_cluster_lo),hl
		ld hl,(cmk_name_ptr)
		call find_by_name
		or a
		jr z,cmkd_alloc
		ld a,3
		or a
		ret

cmkd_alloc	ld hl,(active_dir_hi)
		ld (cur_cluster_hi),hl
		ld hl,(active_dir_lo)
		ld (cur_cluster_lo),hl
		call find_free_cluster
		or a
		jr z,cmkd_have_cl
		ld a,255
		or a
		ret

cmkd_have_cl	ld hl,(free_cluster_hi)
		ld (cmk_cluster_hi),hl
		ld hl,(free_cluster_lo)
		ld (cmk_cluster_lo),hl

		ld hl,(free_cluster_hi)
		ld (cur_cluster_hi),hl
		ld hl,(free_cluster_lo)
		ld (cur_cluster_lo),hl
		ld hl,#0fff
		ld (new_val_hi),hl
		ld hl,#ffff
		ld (new_val_lo),hl
		call write_fat_entry
		or a
		jr z,cmkd_zf
		ld a,255
		or a
		ret

cmkd_zf		ld hl,(cmk_cluster_hi)
		ld (cur_cluster_hi),hl
		ld hl,(cmk_cluster_lo)
		ld (cur_cluster_lo),hl
		call zero_fill_cluster
		or a
		jr z,cmkd_dots
		ld a,255
		or a
		ret

cmkd_dots	call rtc_to_fat_datetime
		call clear_dir_entry
		call stamp_dir_entry_datetime
		ld hl,dot_name
		ld de,dir_entry_buf
		ld bc,11
		ldir
		ld a,#10
		ld (dir_entry_buf+11),a
		ld hl,(cmk_cluster_hi)
		ld (dir_entry_buf+20),hl
		ld hl,(cmk_cluster_lo)
		ld (dir_entry_buf+26),hl

		ld hl,(cmk_cluster_hi)
		ld (cur_cluster_hi),hl
		ld hl,(cmk_cluster_lo)
		ld (cur_cluster_lo),hl
		call cluster_to_sector
		ld hl,(fza_sector_hi)
		ld (cmk_sec_hi),hl
		ld hl,(fza_sector_lo)
		ld (cmk_sec_lo),hl
		ld hl,(cmk_sec_hi)
		ld de,(cmk_sec_lo)
		call set_lba32
		call sdread_lba
		or a
		jr z,cmkd_dot_ok
		ld a,255
		or a
		ret
cmkd_dot_ok	ld hl,dir_entry_buf
		ld de,sdbuf
		ld bc,32
		ldir

		call clear_dir_entry
		call stamp_dir_entry_datetime
		ld hl,dotdot_name
		ld de,dir_entry_buf
		ld bc,11
		ldir
		ld a,#10
		ld (dir_entry_buf+11),a
		ld hl,(active_dir_hi)
		ld (dir_entry_buf+20),hl
		ld hl,(active_dir_lo)
		ld (dir_entry_buf+26),hl
		ld hl,dir_entry_buf
		ld de,sdbuf+32
		ld bc,32
		ldir

		ld hl,(cmk_sec_hi)
		ld de,(cmk_sec_lo)
		call set_lba32
		call sdwrite_lba
		or a
		jr z,cmkd_ownentry
		ld a,255
		or a
		ret

cmkd_ownentry	call clear_dir_entry
		call stamp_dir_entry_datetime
		ld a,#10
		ld (dir_entry_buf+11),a
		ld hl,(cmk_cluster_hi)
		ld (dir_entry_buf+20),hl
		ld hl,(cmk_cluster_lo)
		ld (dir_entry_buf+26),hl

		ld hl,(active_dir_hi)
		ld (cur_cluster_hi),hl
		ld hl,(active_dir_lo)
		ld (cur_cluster_lo),hl
		ld hl,(cmk_name_ptr)
		call filter_name_to_83
		call generate_unique_shortname
		or a
		jr z,cmkd_buildlfn
		ld a,255
		or a
		ret

cmkd_buildlfn	ld hl,(cmk_name_ptr)
		call build_lfn_entries

		ld hl,(active_dir_hi)
		ld (cur_cluster_hi),hl
		ld hl,(active_dir_lo)
		ld (cur_cluster_lo),hl
		call find_free_run
		or a
		jr z,cmkd_final
		ld a,255
		or a
		ret

cmkd_final	ld hl,(active_dir_hi)
		ld (cur_cluster_hi),hl
		ld hl,(active_dir_lo)
		ld (cur_cluster_lo),hl
		call write_name_entries
		or a
		ret z
		ld a,255
		or a
		ret

;--- core_mkfile: HL -> {flag(1), length(4,LE32), name(1-255), 0} ->
;--- creates a file with that name and declared size in the active
;--- directory, allocating+EOC-marking its first cluster. Does NOT
;--- write any data or zero-fill the cluster (matching plain FAT
;--- practice for files -- unlike a directory, slack space beyond the
;--- declared SIZE is legitimately ignorable) -- the caller writes real
;--- data afterward via SAVE512, same as real ZiFi's own MKFILE-then-
;--- SAVE512 pattern (save_downloaded_file). ---
cmkf_len_hi	dw 0
cmkf_len_lo	dw 0

core_mkfile	inc hl			; skip the flag byte (unused here --
					; this driver doesn't yet distinguish
					; anything by it)
		ld a,(hl)
		ld (cmkf_len_lo),a
		inc hl
		ld a,(hl)
		ld (cmkf_len_lo+1),a
		inc hl
		ld a,(hl)
		ld (cmkf_len_hi),a
		inc hl
		ld a,(hl)
		ld (cmkf_len_hi+1),a
		inc hl
		ld (cmk_name_ptr),hl	; hl now -> the name itself

		push hl
		ld b,0
cmkf_lenloop	ld a,(hl)
		or a
		jr z,cmkf_lendone
		inc hl
		inc b
		jr nz,cmkf_lenloop
		pop hl
		ld a,1
		or a
		ret
cmkf_lendone	pop hl
		ld a,b
		or a
		jr nz,cmkf_havelen
		ld a,1
		or a
		ret

cmkf_havelen	ld hl,(active_dir_hi)
		ld (cur_cluster_hi),hl
		ld hl,(active_dir_lo)
		ld (cur_cluster_lo),hl
		ld hl,(cmk_name_ptr)
		call find_by_name
		or a
		jr z,cmkf_alloc
		ld a,3
		or a
		ret

cmkf_alloc	ld hl,(active_dir_hi)
		ld (cur_cluster_hi),hl
		ld hl,(active_dir_lo)
		ld (cur_cluster_lo),hl
		call find_free_cluster
		or a
		jr z,cmkf_havecl
		ld a,255
		or a
		ret

cmkf_havecl	ld hl,(free_cluster_hi)
		ld (cmk_cluster_hi),hl
		ld hl,(free_cluster_lo)
		ld (cmk_cluster_lo),hl

		ld hl,(free_cluster_hi)
		ld (cur_cluster_hi),hl
		ld hl,(free_cluster_lo)
		ld (cur_cluster_lo),hl
		ld hl,#0fff
		ld (new_val_hi),hl
		ld hl,#ffff
		ld (new_val_lo),hl
		call write_fat_entry
		or a
		jr z,cmkf_entry
		ld a,255
		or a
		ret

cmkf_entry	call rtc_to_fat_datetime
		call clear_dir_entry
		call stamp_dir_entry_datetime
		ld a,#20		; ATTR_ARCHIVE
		ld (dir_entry_buf+11),a
		ld hl,(cmk_cluster_hi)
		ld (dir_entry_buf+20),hl
		ld hl,(cmk_cluster_lo)
		ld (dir_entry_buf+26),hl
		ld hl,(cmkf_len_lo)
		ld (dir_entry_buf+28),hl
		ld hl,(cmkf_len_hi)
		ld (dir_entry_buf+30),hl

		ld hl,(active_dir_hi)
		ld (cur_cluster_hi),hl
		ld hl,(active_dir_lo)
		ld (cur_cluster_lo),hl
		ld hl,(cmk_name_ptr)
		call filter_name_to_83
		call generate_unique_shortname
		or a
		jr z,cmkf_buildlfn
		ld a,255
		or a
		ret

cmkf_buildlfn	ld hl,(cmk_name_ptr)
		call build_lfn_entries

		ld hl,(active_dir_hi)
		ld (cur_cluster_hi),hl
		ld hl,(active_dir_lo)
		ld (cur_cluster_lo),hl
		call find_free_run
		or a
		jr z,cmkf_final
		ld a,255
		or a
		ret

cmkf_final	ld hl,(active_dir_hi)
		ld (cur_cluster_hi),hl
		ld hl,(active_dir_lo)
		ld (cur_cluster_lo),hl
		call write_name_entries
		or a
		jr z,cmkf_open_stream
		ld a,255
		or a
		ret

; Real zifi.asm calls SAVE512 immediately after MKFILE with no FENTRY/
; SEEK0 in between (matching FENTRY's own "SEEK0 is automatically
; called" convention, which drv_fentry implements by opening a stream
; on its match) -- MKFILE must do the same on the file it just created,
; or SAVE512 writes into whatever stream was left open by the PREVIOUS
; operation (e.g. the parent directory itself) instead of the new
; file's own cluster. Confirmed on hardware as a real bug: downloaded
; files read back as stale leftover disk content (an old test string in
; one, raw directory-entry bytes in another) because their own cluster
; was never actually written.
cmkf_open_stream
		ld hl,(cmk_cluster_hi)
		ld (cur_cluster_hi),hl
		ld hl,(cmk_cluster_lo)
		ld (cur_cluster_lo),hl
		call stream_open
		xor a
		ret

;--- test_core_mkdir_mkfile: exercises the real ABI end to end --
;--- SETROOT/FENTRY("TESTDIRA")/SETDIR, MKDIR("core_test_dir") (or
;--- find it if a prior run already made it -- A=3 is treated as
;--- success here, not a test failure), FENTRY+SETDIR into it, then
;--- MKFILE via a real {flag,length(4),name,0} buffer matching zifi.
;--- asm's own FILE buffer layout. Does NOT write any file data (that's
;--- SAVE512's job, already proven separately) -- this only proves
;--- MKDIR/MKFILE themselves produce valid, correctly-placed entries.
;--- A=0 ok, A=1 fail (tcmm_stage: 0=TESTDIRA not found, 1=MKDIR, 2=
;--- FENTRY into the new dir, 3=MKFILE). ---

dot_name	db ".          "	; 11 bytes
dotdot_name	db "..         "	; 11 bytes
mkdir_sec_hi	dw 0
mkdir_sec_lo	dw 0

clear_dir_entry
		ld hl,dir_entry_buf
		ld de,dir_entry_buf+1
		ld bc,31
		ld (hl),0
		ldir
		ret

body_end:

		SAVEBIN "zc_sd_driver_body.bin",#0000,body_end-#0000
