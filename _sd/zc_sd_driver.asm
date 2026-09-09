		DEVICE ZXSPECTRUM48

; From-scratch open SD/FAT32 driver for ZiFi, replacing the closed
; WDFCVBI2.COD -- built and hardware-tested incrementally in
; D:\ST\sjasmplus\sdtest\sdtest.asm across this whole investigation
; (see [[project-zifi-custom-sd-driver]]), this file assembles the
; SAME proven code into the jump-table shape zifi.asm's CORE equ #2002
; expects.
;
; Table layout confirmed by cross-referencing WC's own KERNEL.ASM
; START table (E:\zx-evo-master\pentevo\soft\WC\source\core32\
; KERNEL.ASM) -- byte-for-byte matching offsets (DEV_INI=+3, HDD=+9,
; LOAD512=+21, SAVE512=+24, DOS_SWP=+27, MKFILE=+57, MKDIR=+60,
; DELFL=+63, RENAME=+66, FENTRY=+78, LOADNON=+84, NXTETY=+87) for the
; first 31 entries, PLUS three more (SETDIR=+93, SETROOT=+96, SEEK0=
; +99) that WC's own core32 table does NOT have -- WDFCVBI2.COD's own
; table is a superset/independent implementation, not a live reference
; into whatever WC happens to be installed (confirmed by the user
; directly: Wild-Commander-Improved, which has the LFN bug already
; fixed in ITS OWN core32, did NOT fix ZiFi's bug -- so ZiFi's driver
; is definitely self-contained, not calling into WC's shared kernel).
;
; Loaded via spgbld's Block directive at #E000/page matching the
; original WDFCVBI2.COD placement -- the exact mechanism by which that
; maps to the fixed #2002 jump-table address is still not 100% proven
; (see [[project-zifi-custom-sd-driver]] for the open question), but
; the original driver's own DOS_SWP/LOAD512-real-address evidence
; found earlier in this investigation, PLUS this file being structured
; identically (jump table at the very start of the loaded block),
; should reproduce whatever that mechanism is. THIS IS THE FIRST REAL
; HARDWARE TEST of that hypothesis -- expect to iterate.
;
; Entries zifi.asm never calls (grepped for every CORE+n EQU it
; actually uses) are safe no-op/stub implementations: RDD/SDD/GIPAG/
; GLSTCAT/TLSTCAT/SRHFCL/MKSG/RFRH/GENTRY/TENTRY/DLSG/CHTOSE/LOAD256/
; NXTETY2/REINI, and the three raw "Z0" slots WC's own table leaves
; unimplemented too. NXTETY (directory enumeration, a different job
; from FENTRY's single-name search) is ALSO a stub for now -- zifi.asm's
; only reference to it (VYGREB/VYG) is commented-out dead code
; ("Выгребаем каталог, чисто по приколу" -- "just for fun"), never
; actually called by the real running program.

; NOTE: this code is invoked via zifi.asm's init_sd_card (line ~4134),
; which does "ld a,sd_driver_page(#0f) / jp set_page0" -- i.e. maps
; page #0F into PAGE0 (CPU slot 0, addresses #0000-#3FFF), NOT slot 3.
; CORE=#2002 is a slot-0 address, so every internal absolute JP/CALL in
; this file must be assembled as if it lives at #2002, not #E000 --
; otherwise the driver hangs the instant it's entered (confirmed on
; hardware: first attempt used ORG #E000 and hung on the boot banner).
;
; spgbld's Block directive only accepts 512-byte-aligned addresses, and
; #2002 isn't one -- so we can't just tell it to load at offset #2002
; directly (Block = #e002 -> "Block address is not a 512 multiple!").
; Instead we load at the aligned #e000 (page-offset #2000, same as the
; original WDFCVBI2.COD placement) and pad 2 bytes here so the actual
; jump table lands exactly on #2002 once loaded. This is almost
; certainly what WDFCVBI2.COD's own "DOS_SWP; DEPACK Driver" call was
; really doing at runtime (relocating itself those same 2 bytes) --
; padding at assembly time is simpler and needs no runtime relocator.
		ORG #2000
		DS 2			; pad offset #2000-#2001; jump table
					; below starts at #2002 = CORE

CONF		EQU #77
DATA		EQU #57

; Body-routine addresses (sdinit, dma_set_addr, sdread_lba, parse_bpb,
; core_fentry, get_next_cluster, write_fat_entry, find_by_name,
; sdwrite_lba, cur_cluster_hi/lo, target_name, dot_name,
; clear_dir_entry, and everything else from zc_sd_driver_body.asm) --
; imported here as plain EQU constants (generated from that file's own
; --sym dump by build.ps1) so every JP/CALL/reference below resolves
; correctly even though the actual body code isn't present in this
; file -- it's compressed and depacked at runtime by drv_dos_swp
; instead. See the fuller comment further down and
; [[project-zifi-custom-sd-driver]].
		INCLUDE "body_syms.inc"

;--- Build-time guard: the depacked body (ORG #0000..body_end, written
;--- by drv_dos_swp at runtime) MUST stay strictly under #2002 (CORE
;--- itself, this file's own resident jump table) -- otherwise depacking
;--- silently overwrites the START of THIS file's own resident code,
;--- every single time it runs. This isn't hypothetical: body growth
;--- crossed #2000 by 198 bytes in this exact project (body_end reached
;--- #20C6) and every CORE dispatch call (DEV_INI, HDD, FENTRY,
;--- everything) silently jumped to garbage as a result -- diagnosed
;--- the hard way via PEEKPHYS/checkpoint instrumentation after
;--- "zifi.ini not found" started happening. The threshold is #2002, not
;--- #2000: the 2 bytes at #2000-#2001 (see "DS 2" above) are pure
;--- alignment padding, never read by anything, so the depacked body may
;--- safely fill them too -- body_end==#2002 means the last byte written
;--- is at #2001, one below CORE. Never remove this check; if it fires,
;--- shrink zc_sd_driver_body.asm (or increase this IF condition's
;--- threshold together with confirming real headroom exists all the way
;--- to code_end below #4000) before doing anything else. See
;--- [[project-zifi-custom-sd-driver]]. ---
	IF body_end > #2002
		DEFB 1/0	; BODY OVERLAPS RESIDENT CODE -- FIX THIS, see comment above
	ENDIF

;=====================================================================
; Jump table -- 34 entries x 3 bytes (JP nnnn), offsets 0..99, must
; stay in this exact order/spacing to match every CORE+n EQU in
; zifi.asm.
;=====================================================================
		JP drv_seldev		; +0
		JP wrap_dev_init	; +3
		JP drv_stub_ok		; +6  REINI
		JP wrap_hdd		; +9
		JP drv_stub_fail	; +12 RDD
		JP drv_stub_fail	; +15 SDD
		JP drv_stub_fail	; +18 GIPAG
		JP wrap_load512		; +21
		JP wrap_save512		; +24
		JP wrap_dos_swp		; +27
		JP drv_stub_fail	; +30 GLSTCAT
		JP drv_stub_fail	; +33 TLSTCAT
		JP drv_stub_fail	; +36 SRHFCL
		JP drv_stub_fail	; +39 Z0
		JP drv_stub_fail	; +42 MKSG
		JP drv_stub_fail	; +45 Z0
		JP drv_stub_fail	; +48 RFRH
		JP drv_stub_fail	; +51 GENTRY
		JP drv_stub_fail	; +54 TENTRY
		JP wrap_mkfile		; +57
		JP wrap_mkdir		; +60
		JP wrap_delfl		; +63 DELFL
		JP wrap_renam		; +66 RENAM
		JP drv_stub_fail	; +69 DLSG
		JP drv_stub_fail	; +72 CHTOSE
		JP drv_stub_fail	; +75 Z0
		JP wrap_fentry		; +78
		JP drv_stub_fail	; +81 LOAD256
		JP wrap_loadnon		; +84
		JP drv_nxtety		; +87
		JP drv_stub_fail	; +90 NXTETY2
		JP wrap_setdir		; +93
		JP wrap_setroot		; +96
		JP wrap_seek0		; +99

;=====================================================================
; di/ei wrappers around every entry point that does real work while
; executing from CPU slot 0 (this whole driver only exists there while
; PAGE0 points at page #0F -- see the ORG note above). Found on
; hardware: zifi.asm's own "off_int_dma"/save_mode flag (which init_sd_
; card/sd_exit toggle around SD operations) does NOT cover everything --
; int_main's pt_play (zifi.asm ~line 2350, gated by a SEPARATE "music_sw"
; flag, not save_mode) calls set_music_pages_lite EVERY interrupt
; whenever a track is playing, which repages PAGE0 *and* PAGE1 *and*
; PAGE3 for the music player's own use. If that fires while we're mid-
; CORE-call: PAGE0 changing while we're actively EXECUTING CODE FROM
; SLOT 0 crashes/jumps to garbage the instant the interrupt returns
; (next instruction fetch reads the wrong page); PAGE3 changing mid-
; LOAD512/SAVE512 silently swaps the transfer's source/dest to whatever
; the music player last pointed it at instead of the real caller data --
; confirmed on hardware as the cause of downloaded files playing back as
; a constant garbage pattern instead of the real track. Wrapping the
; real logic in a plain di/ei critical section (bodies below are
; UNCHANGED, just called instead of jumped to) closes both holes
; regardless of music_sw/save_mode state. The original hardware-tested
; function bodies keep their own names/all internal early-return paths
; exactly as they were -- only the outer entry/exit changed.
;=====================================================================
; Every wrap_* below preserves IX across the real call (push/pop around
; it) -- ZiFi.asm's own CORE-ABI convention relies on IX surviving a
; CORE call unmolested (save_downloaded_file sets "ld ix,read_threads"
; ONCE, then keeps using (ix+thread.n) addressing across MULTIPLE CORE
; calls, including AFTER MKFILE returns, with no re-load in between).
; filter_name_to_83 (zc_sd_driver_body.asm, used by core_mkfile/
; core_mkdir's short-name generation) uses IX internally as a plain
; scratch pointer (ld ix,sn_base / ld ix,sn_ext) and never restores it
; -- so a caller relying on IX surviving MKFILE was silently reading
; save_64's (ix+thread.page)/(ix+thread.adress) from wherever sn_base/
; sn_ext happened to leave IX pointing (this driver's own low, #0000-
; based body addresses, still mapped into slot 0 at that point) instead
; of zifi's real read_threads struct -- confirmed as the actual root
; cause of "every download saves as identical, page/track-independent
; garbage" (2026-09-09): read_threads.page/adress were correct the
; WHOLE time, SAVE512 was just told to read from the wrong place by a
; stale IX. See [[project-zifi-custom-sd-driver]]. ---
wrap_dev_init	di
		push ix
		call drv_dev_init
		pop ix
		ei
		ret
wrap_hdd	di
		push ix
		call drv_hdd
		pop ix
		ei
		ret
;--- NO di/ei needed here, matching what a real disassembly of the
;--- ORIGINAL closed WDFCVBI2.COD driver's own SAVE512/LOAD512 turned
;--- out to do (hand-verified: zero real DI/EI opcodes anywhere in its
;--- transfer routine at #22DB). That disassembly also showed WHY it
;--- didn't need any: its transfer uses the TS-Conf DMA controller, not
;--- a CPU-driven page1_port+LDIR loop. core_save512/core_load512 (in
;--- zc_sd_driver_body.asm) now do the same -- DMA straight between the
;--- SD card and the caller's page, addressed by physical page number,
;--- never touching the CPU's slot mapping at all. Two di/ei variants
;--- around the OLD LDIR-based version were tried first and both made
;--- things WORSE on real hardware (di/ei around the whole transfer:
;--- audio noise + hangs on track switch; di/ei only around the brief
;--- PAGE1-touch+LDIR: full hangs with garbage on screen) -- di/ei
;--- was never going to fix it, since the LDIR's dependence on PAGE1
;--- staying stable across the whole copy was the real hazard, not a
;--- timing race di/ei could close (a write-only page port can't be
;--- restored after set_music_pages_lite clobbers it mid-transfer,
;--- di/ei or not). See [[project-zifi-custom-sd-driver]]. ---
wrap_load512	push ix
		call core_load512
		pop ix
		ret
wrap_save512	push ix
		call core_save512
		pop ix
		ret
wrap_mkfile	di
		push ix
		call core_mkfile
		pop ix
		ei
		ret
wrap_mkdir	di
		push ix
		call core_mkdir
		pop ix
		ei
		ret
wrap_fentry	di
		push ix
		call drv_fentry
		pop ix
		ei
		ret
wrap_loadnon	di
		push ix
		call drv_loadnon
		pop ix
		ei
		ret
wrap_setdir	di
		push ix
		call core_setdir
		pop ix
		ei
		ret
wrap_setroot	di
		push ix
		call core_setroot
		pop ix
		ei
		ret
wrap_seek0	di
		push ix
		call stream_open
		pop ix
		ei
		ret
wrap_delfl	di
		push ix
		call core_delfl
		pop ix
		ei
		ret
wrap_renam	di
		push ix
		call core_renam
		pop ix
		ei
		ret
; DOS_SWP now does real work (depacking the body -- see drv_dos_swp
; below), unlike every other entry here it previously had NO di/ei
; protection at all (harmless when it was a no-op). Real interrupts
; MUST stay off for the whole unpack: page #0F is mapped into slot 0
; the entire time, and zifi.asm's pt_play interrupt handler repages
; PAGE0/1/3 for the music player if it fires mid-CORE-call (see the
; header comment above) -- exactly the same risk this wrapping already
; protects every other substantive entry against.
; No `ei` here (unlike every other wrap_*): DOS_SWP is ALWAYS
; immediately followed by another di-guarded CORE call in zifi.asm's
; own fixed sequence (sd_init: CALL DOS_SWP; CALL DEV_INI; ...) -- so
; re-enabling interrupts here just to have the very next call disable
; them again is pointless, and genuinely risky while depacking: an
; interrupt landing in the gap would fire with PAGE0 still pointing at
; page #0F, jumping to #0038 (IM1 vector) which -- mid-depack -- can
; be anything from still-compressed garbage to not-yet-written body
; code, not a real ROM/interrupt handler. Confirmed by direct testing:
; this exact gap crashed a standalone depack test (wild PC, eventual
; HALT) until `ei` was removed here.
wrap_dos_swp	di
		call drv_dos_swp
		ret

;--- drv_stub_ok / drv_stub_fail: safe stubs for every CORE-table slot
;--- zifi.asm never actually calls (confirmed via its own CORE+n EQU
;--- list) -- Z (success-shaped) or NZ (not-found/error-shaped)
;--- respectively, whichever is the safer default for a function
;--- nothing should ever invoke. ---
drv_stub_ok	xor a
		ret
drv_stub_fail	xor a
		inc a
		ret

drv_seldev	xor a
		ret

;--- drv_dev_init: CORE+3, DEV_INI -- raw SD card init only (matches
;--- zifi.asm's own "CALL DEV_INI:JP NZ,ER0" -- HDD/partition search is
;--- a separate, later call). Z=ok, NZ=fail. ---
drv_dev_init	call sdinit
		ret

;--- drv_hdd: CORE+9, HDD ("SEARCH PARTITION" per WC's own naming) --
;--- reads sector 0, detects/validates the partition (detect_partition
;--- already does its own verify_fat32 check internally, falling back
;--- to sector 0 itself if no MBR partition table is present), then
;--- parses the real BPB. Z=ok, NZ=fail. ---
drv_hdd		ld hl,0
		ld de,0
		call set_lba32
		call sdread_lba
		ret nz

		call detect_partition
		ret nz

		call parse_bpb

		; Pre-warm the RTC read HERE, during sd_init's quiet pre-EI
		; window (zifi.asm calls sd_init at line ~56, then "ei" at
		; line 57 -- HDD runs before interrupts are even on and
		; before any active UI/video updates). rtc_to_fat_datetime's
		; own caching means every LATER call (from core_mkdir/
		; core_mkfile during the active WiFi-connect/download phase)
		; just reuses this result instead of touching the RTC chip
		; again. This matters because [[project-zifi-rtc-time-sync]]
		; already found -- the hard way, on this exact board -- that
		; touching #EFF7 (which this RTC read also does, to select
		; the CMOS/RTC register space) during an active UI phase can
		; cause real corruption even with correct di/ei and a proper
		; read-modify-write, for reasons never fully root-caused;
		; the only fix that actually worked there was moving WHEN
		; the touch happens, not how. Doing it here avoids the same
		; class of risk instead of re-discovering it the hard way.
		call rtc_to_fat_datetime

		xor a
		ret

;--- drv_dos_swp: CORE+27, DOS_SWP ("SELDEVnDRIVERinit" / "DEPACK
;--- Driver" per WC's/zifi's own naming) -- the original closed driver
;--- was compressed and self-relocated here; this driver now does the
;--- same thing for real, not just in spirit: the "body" (everything
;--- from sdinit onward -- DMA/SD/FAT32/CORE-ABI logic, built and
;--- hardware-tested as zc_sd_driver_body.asm) is compressed and stored
;--- as body_packed_start..body_packed_end below. Decompressing it to
;--- its true addresses (#0000-body_end, see body_syms.inc) is what
;--- makes those addresses (and every JP/CALL into them from this
;--- resident half, including the jump table indirectly via wrap_hdd
;--- etc, and DELFL/RENAM below) valid -- this MUST run before any
;--- other CORE entry point does real work, matching zifi.asm's own
;--- fixed call order (sd_init: CALL DOS_SWP; DEPACK Driver -- always
;--- immediately after paging page #0F into slot 0, always before
;--- DEV_INI/HDD/etc).
;---
;--- Hrust1, not ZX0: ZX0 (both the "standard" forward AND backward
;--- Z80 decoders, dzx0_standard(_back).asm by Einar Saukas) was tried
;--- first and, after extensive isolated Z80-harness testing (see
;--- [[project-zifi-custom-sd-driver]]), both directions turned out to
;--- decompress small/simple payloads (even ones with real
;--- back-references) correctly but produce garbage specifically on
;--- this driver's full 8027-byte body -- root cause never found
;--- despite real effort, abandoned as too large a time sink for an
;--- optional space optimization.
;---
;--- Chased a real, never-root-caused bug here for a long time: every
;--- attempt to fix load_ini's address-0 collision FROM THIS SIDE
;--- (padding the body with a sacrifice_buf, later an ORG shift to
;--- #0200 with zero added bytes) reliably broke BOTH Z80 Hrust
;--- decoders tried (hand-transcribed classic dehst.asm DEHRUST,
;--- confirmed byte-for-byte correct against source via automated
;--- diff; and hrust13.exe's own "-depacker" self-relocating output)
;--- the instant core_load512's fix (in zc_sd_driver_body.asm) grew
;--- the body by its own ~53 bytes, regardless of padding/positioning
;--- -- see [[project-zifi-custom-sd-driver]] for the full history.
;--- Root cause in either decoder never found under real time
;--- pressure. Fixed properly instead: zifi.asm's load_ini/parse_ini
;--- now use LOAD512's SAME slot-1/#4000/PAGE1 convention as SAVE512
;--- (see core_load512's own comment in zc_sd_driver_body.asm), so
;--- load_ini never touches address 0 at all anymore.
;---
;--- Hrust1 fully abandoned at this point (both the classic hand-
;--- transcribed dehst.asm DEHRUST -- confirmed byte-for-byte correct
;--- against source via automated diff, TWICE -- and hrust13.exe's own
;--- "-depacker" output kept producing wrong Z80 decompression results
;--- on data that a PC-side reference tool, dehrust1.exe, decoded
;--- correctly every single time, on EVERY size/content tried,
;--- including this exact 8018-byte body with no changes at all except
;--- core_load512's own content -- so dehrust1.exe was never actually
;--- validating what was assumed; root cause never found under real
;--- time pressure -- see [[project-zifi-custom-sd-driver]]).
;---
;--- Replaced with a trivial, self-written, fully-verified PackBits-
;--- style RLE (round-tripped byte-for-byte on the PC first, in
;--- PowerShell, before ever touching Z80 code): control byte C,
;--- C=128 is the end marker; C<128 is a literal run of C+1 bytes
;--- (copied verbatim); C>128 is a repeat run of (257-C) copies of the
;--- single byte that follows (257-C covers 2..128 for C=255..129; C=1
;--- unused/invalid, C=128 reserved as the terminator instead of a
;--- literal-run-of-1 encoding). Only ~12.5% compression is actually
;--- needed here (8018-byte body must fit under ~7076 bytes to leave
;--- room for the #2000-#3FFF dispatcher) -- this achieves 5929 bytes
;--- (~74%), comfortable margin, on real driver code (long runs of
;--- identical bytes are common in data tables/padding). ---
drv_dos_swp	ld ix,body_packed_start
		ld de,0
		call PB_DECODE
		xor a
		ret

;=====================================================================
; PB_DECODE: PackBits-style RLE decoder (see drv_dos_swp's comment for
; the format). IX=source, DE=dest. Doesn't touch SP.
;=====================================================================
PB_DECODE
PB_LOOP		ld a,(ix+0)
		inc ix
		cp 128
		ret z			; terminator
		bit 7,a
		jr z,PB_LITERAL

		neg			; a = 256-ctrl (ctrl in 129..255)
		inc a			; a = 257-ctrl (mod 256) = repeat count (2..128)
		ld b,a
		ld a,(ix+0)
		inc ix
PB_REP_LOOP	ld (de),a
		inc de
		djnz PB_REP_LOOP
		jr PB_LOOP

PB_LITERAL	inc a			; a = ctrl+1 = literal count (1..128)
		ld b,a
PB_LIT_LOOP	ld a,(ix+0)
		inc ix
		ld (de),a
		inc de
		djnz PB_LIT_LOOP
		jr PB_LOOP

;--- drv_fentry: CORE+78, FENTRY -- real ABI is HL -> {flag(1),
;--- name(1-255),0} (flag = file-vs-dir attribute filter, not yet
;--- implemented -- see [[project-zifi-custom-sd-driver]] Next steps).
;--- On a match, automatically opens a stream on the found entry's
;--- cluster (matching the real ABI's own doc: "SEEK0 is automatically
;--- called") so a caller can go straight into LOAD512/SAVE512/LOADNON
;--- without any extra setup, exactly like zifi.asm's own real call
;--- sites do (FENTRY then LOAD512, nothing in between). Z=NOT FOUND,
;--- NZ=FOUND + [DE,HL]=length. ---
drv_fentry	inc hl			; skip the flag byte (filter not
					; implemented yet -- matches by name
					; only)
		call core_fentry
		or a
		ret z			; not found

		ld hl,(fbn_cluster_hi)
		ld (cur_cluster_hi),hl
		ld hl,(fbn_cluster_lo)
		ld (cur_cluster_lo),hl
		call stream_open

		ld de,(fbn_size_hi)
		ld hl,(fbn_size_lo)
		ld a,1
		or a			; NZ (A=1, nonzero) -- found
		ret

;--- drv_loadnon: CORE+84, LOADNON -- advances the CURRENTLY OPEN
;--- stream (opened by the last drv_fentry match) by B sectors without
;--- reading/writing data. Real ABI doesn't document a return value
;--- beyond implicit success. ---
drv_loadnon	ld a,b
		or a
		ret z
dln_loop	push bc
		call strm_advance
		pop bc
		djnz dln_loop
		xor a
		ret

;--- drv_nxtety: CORE+87, NXTETY -- real ABI is a directory-listing
;--- iterator (GetNextEntryFromActiveDir), a genuinely different job
;--- from FENTRY's single-name search -- NOT YET BUILT. Stubbed as
;--- "always EndOfDir" (Z) since zifi.asm's only reference to it
;--- (VYGREB/VYG) is commented-out dead code, never actually called by
;--- the real running program -- revisit if that changes. ---
drv_nxtety	xor a
		ret

; CORE+99, SEEK0 (per FENTRY's own doc, "SEEK0 is automatically
; called" by FENTRY -- nothing in zifi.asm calls this directly) is
; wired straight to stream_open via wrap_seek0 in the jump-table
; wrapper block above -- no separate drv_seek0 needed.

;=====================================================================
; Everything that used to live inline below this point (ported,
; hardware-tested code from D:\ST\sjasmplus\sdtest\sdtest.asm -- DMA/
; SD/FAT32/CORE-ABI logic) now lives in zc_sd_driver_body.asm instead,
; compiled to its own true addresses (#0000 upward), compressed with
; ZX0 and depacked here at runtime by drv_dos_swp (see above) -- this
; is what freed enough room in this #2000-#3FFF half for DELFL/RENAM
; to fit alongside everything already here. body_syms.inc (included
; near the top of this file) supplies every body label as a plain EQU
; constant. See [[project-zifi-custom-sd-driver]].
;=====================================================================

;=====================================================================
; CORE ABI: DELFL/RENAM -- never actually called by zifi.asm (grepped
; the whole file for CALL DELFL/CALL RENAM, zero hits), but built
; anyway per explicit user request ("для полноты драйвера"). Both need
; to know exactly which directory entries to mark deleted (0xE5) --
; the short entry AND any preceding LFN run -- so find_by_name now
; tracks fbn_match_index_lo/fbn_match_run_start_lo (see above) for
; this purpose.
;=====================================================================

;--- core_free_chain: (cur_cluster_hi,cur_cluster_lo) -> frees every
;--- cluster in this FAT chain (FAT entry := 0, mirrored to all copies
;--- via write_fat_entry) by following get_next_cluster until chain_
;--- ended. A=0 ok, A=1 fail (disk error -- chain may be partially
;--- freed). ---
cfc_cur_hi	dw 0
cfc_cur_lo	dw 0
cfc_next_hi	dw 0
cfc_next_lo	dw 0
cfc_has_next	db 0

core_free_chain
		ld hl,(cur_cluster_hi)
		ld (cfc_cur_hi),hl
		ld hl,(cur_cluster_lo)
		ld (cfc_cur_lo),hl

cfc_loop	ld hl,(cfc_cur_hi)
		ld (cur_cluster_hi),hl
		ld hl,(cfc_cur_lo)
		ld (cur_cluster_lo),hl
		call get_next_cluster
		ld a,(chain_ended)
		or a
		jr nz,cfc_nonext
		ld hl,(cur_cluster_hi)
		ld (cfc_next_hi),hl
		ld hl,(cur_cluster_lo)
		ld (cfc_next_lo),hl
		ld a,1
		ld (cfc_has_next),a
		jr cfc_free_this
cfc_nonext	xor a
		ld (cfc_has_next),a

cfc_free_this	ld hl,(cfc_cur_hi)
		ld (cur_cluster_hi),hl
		ld hl,(cfc_cur_lo)
		ld (cur_cluster_lo),hl
		ld hl,0
		ld (new_val_hi),hl
		ld (new_val_lo),hl
		call write_fat_entry
		or a
		jr nz,cfc_fail

		ld a,(cfc_has_next)
		or a
		jr z,cfc_done
		ld hl,(cfc_next_hi)
		ld (cfc_cur_hi),hl
		ld hl,(cfc_next_lo)
		ld (cfc_cur_lo),hl
		jr cfc_loop

cfc_done	xor a
		ret
cfc_fail	xor a
		inc a
		ret

;--- core_mark_deleted_range: (cur_cluster_hi,cur_cluster_lo already
;--- set by caller to the directory) + cmdr_start_lo/cmdr_end_lo
;--- (logical 32-byte-entry-index range, inclusive) -> marks each
;--- entry's first byte 0xE5 (deleted). A=0 ok, A=1 fail (disk error). ---
cmdr_start_lo		dw 0
cmdr_end_lo		dw 0
cmdr_cur_index_lo	dw 0
cmdr_entptr		dw 0
cmdr_dirty		db 0
cmdr_this_sec_hi	dw 0
cmdr_this_sec_lo	dw 0

core_mark_deleted_range
		call stream_open
		ld hl,0
		ld (cmdr_cur_index_lo),hl

cmdr_sector_loop
		ld a,(stream_eoc)
		or a
		jp nz,cmdr_done

		call strm_calc_sector
		ld hl,(strm_sector_hi)
		ld (cmdr_this_sec_hi),hl
		ld hl,(strm_sector_lo)
		ld (cmdr_this_sec_lo),hl
		ld hl,(strm_sector_hi)
		ld de,(strm_sector_lo)
		call set_lba32
		call sdread_lba
		or a
		jr nz,cmdr_fail

		xor a
		ld (cmdr_dirty),a
		ld hl,sdbuf
		ld (cmdr_entptr),hl
		ld b,16

cmdr_entloop	ld hl,(cmdr_cur_index_lo)
		ld de,(cmdr_start_lo)
		or a
		sbc hl,de
		jr c,cmdr_notinrange

		ld hl,(cmdr_cur_index_lo)
		ld de,(cmdr_end_lo)
		or a
		sbc hl,de
		jr c,cmdr_inrange
		jr nz,cmdr_notinrange

cmdr_inrange	ld hl,(cmdr_entptr)
		ld (hl),#e5
		ld a,1
		ld (cmdr_dirty),a

cmdr_notinrange
		ld hl,(cmdr_cur_index_lo)
		inc hl
		ld (cmdr_cur_index_lo),hl
		ld hl,(cmdr_entptr)
		ld de,32
		add hl,de
		ld (cmdr_entptr),hl
		djnz cmdr_entloop

		ld a,(cmdr_dirty)
		or a
		jr z,cmdr_skip_write
		ld hl,(cmdr_this_sec_hi)
		ld de,(cmdr_this_sec_lo)
		call set_lba32
		call sdwrite_lba
		or a
		jr nz,cmdr_fail
cmdr_skip_write

		ld hl,(cmdr_cur_index_lo)
		ld de,(cmdr_end_lo)
		or a
		sbc hl,de
		jr c,cmdr_continue
		jr nz,cmdr_done

cmdr_continue	call strm_advance
		jp cmdr_sector_loop

cmdr_done	xor a
		ret
cmdr_fail	xor a
		inc a
		ret

;--- core_delfl: HL -> {flag(1),name(1-255),0} -> finds the entry (via
;--- find_by_name in the active directory), frees its FAT chain, and
;--- marks its short entry + any preceding LFN run deleted. Z=NOT
;--- FOUND, NZ=FILE DELETED -- matches real DELFL's documented ABI
;--- (note the inverted sense vs MKDIR/MKFILE's Z=success). ---

core_delfl	inc hl			; skip flag byte
		ld (cmk_name_ptr),hl

		ld hl,(active_dir_hi)
		ld (cur_cluster_hi),hl
		ld hl,(active_dir_lo)
		ld (cur_cluster_lo),hl
		ld hl,(cmk_name_ptr)
		call find_by_name
		or a
		ret z			; not found -- Z, matches real DELFL

		ld hl,(fbn_cluster_hi)
		ld (cur_cluster_hi),hl
		ld hl,(fbn_cluster_lo)
		ld (cur_cluster_lo),hl
		call core_free_chain

		ld hl,(fbn_match_run_start_lo)
		ld (cmdr_start_lo),hl
		ld hl,(fbn_match_index_lo)
		ld (cmdr_end_lo),hl
		ld hl,(active_dir_hi)
		ld (cur_cluster_hi),hl
		ld hl,(active_dir_lo)
		ld (cur_cluster_lo),hl
		call core_mark_deleted_range

		xor a
		inc a			; NZ -- FILE DELETED
		ret

;--- core_renam: HL -> {flag(1),oldname(1-255),0}, DE -> {newname
;--- (1-255),0} -> renames an entry in the active directory, preserving
;--- its cluster/size/attr (re-stamps date/time fresh). Z=NOT FOUND,
;--- NZ=SUCCESS -- matches real RENAM's documented ABI. Not
;--- transactional: the old entry is marked deleted before the new one
;--- is written, matching this driver's existing failure-mode
;--- conventions elsewhere (no rollback attempted) -- the real ABI has
;--- no code for "found but couldn't rename" to report anyway. ---
crn_newname_ptr	dw 0
crn_old_attr		db 0
crn_old_size_hi		dw 0
crn_old_size_lo		dw 0
crn_old_run_start_lo	dw 0
crn_old_match_index_lo	dw 0

core_renam	inc hl			; skip flag byte -- oldname starts here
		ld (cmk_name_ptr),hl
		ld (crn_newname_ptr),de

		ld hl,(active_dir_hi)
		ld (cur_cluster_hi),hl
		ld hl,(active_dir_lo)
		ld (cur_cluster_lo),hl
		ld hl,(cmk_name_ptr)
		call find_by_name
		or a
		ret z			; not found -- Z, matches real RENAM

		ld hl,(fbn_cluster_hi)
		ld (cmk_cluster_hi),hl
		ld hl,(fbn_cluster_lo)
		ld (cmk_cluster_lo),hl
		ld a,(fbn_attr)
		ld (crn_old_attr),a
		ld hl,(fbn_size_hi)
		ld (crn_old_size_hi),hl
		ld hl,(fbn_size_lo)
		ld (crn_old_size_lo),hl
		ld hl,(fbn_match_run_start_lo)
		ld (crn_old_run_start_lo),hl
		ld hl,(fbn_match_index_lo)
		ld (crn_old_match_index_lo),hl

		; refuse if the NEW name already exists -- generate_unique_
		; shortname only avoids SHORT-name collisions, so without this
		; explicit check RENAM could create a SECOND entry displaying
		; the same long name as an existing one (confirmed on hardware:
		; renaming into an already-used name did exactly that -- same
		; bug class as core_mkdir/core_mkfile's own duplicate-guard,
		; just missed here originally). Checked BEFORE touching the
		; old entry at all, so a refusal here leaves everything as-is.
		ld hl,(active_dir_hi)
		ld (cur_cluster_hi),hl
		ld hl,(active_dir_lo)
		ld (cur_cluster_lo),hl
		ld hl,(crn_newname_ptr)
		call find_by_name
		or a
		ret nz			; new name already exists -- refuse
					; (Z, matching RENAM's two-outcome ABI)

		ld hl,(crn_old_run_start_lo)
		ld (cmdr_start_lo),hl
		ld hl,(crn_old_match_index_lo)
		ld (cmdr_end_lo),hl
		ld hl,(active_dir_hi)
		ld (cur_cluster_hi),hl
		ld hl,(active_dir_lo)
		ld (cur_cluster_lo),hl
		call core_mark_deleted_range

		call rtc_to_fat_datetime
		call clear_dir_entry
		call stamp_dir_entry_datetime
		ld a,(crn_old_attr)
		ld (dir_entry_buf+11),a
		ld hl,(cmk_cluster_hi)
		ld (dir_entry_buf+20),hl
		ld hl,(cmk_cluster_lo)
		ld (dir_entry_buf+26),hl
		ld hl,(crn_old_size_lo)
		ld (dir_entry_buf+28),hl
		ld hl,(crn_old_size_hi)
		ld (dir_entry_buf+30),hl

		ld hl,(active_dir_hi)
		ld (cur_cluster_hi),hl
		ld hl,(active_dir_lo)
		ld (cur_cluster_lo),hl
		ld hl,(crn_newname_ptr)
		call filter_name_to_83
		call generate_unique_shortname
		or a
		jr nz,crn_done		; degenerate failure -- old entry
					; already deleted, nothing sane left
					; to roll back to; ABI has no code
					; for this anyway (see header comment)

		ld hl,(crn_newname_ptr)
		call build_lfn_entries

		ld hl,(active_dir_hi)
		ld (cur_cluster_hi),hl
		ld hl,(active_dir_lo)
		ld (cur_cluster_lo),hl
		call find_free_run
		or a
		jr nz,crn_done

		ld hl,(active_dir_hi)
		ld (cur_cluster_hi),hl
		ld hl,(active_dir_lo)
		ld (cur_cluster_lo),hl
		call write_name_entries

crn_done	xor a
		inc a			; NZ -- SUCCESS (per the real ABI's
					; two-outcome contract; see header
					; comment about the no-rollback
					; degenerate case)
		ret

;--- The PackBits-compressed body blob (see drv_dos_swp's comment for
;--- the format and PB_DECODE for the decoder). Produced by
;--- packbits_encode.ps1 (D:\Temp\claude\E--Claude\
;--- a54de7f1-2eb7-418e-8cf2-9a46028fb01b\scratchpad) -- no header, no
;--- footer, just the encoded stream ending in its own 0x80 terminator
;--- byte, so PB_DECODE needs no extra length/tail parameters at all. ---
body_packed_start:
		INCBIN "zc_sd_driver_body.pb"
body_packed_end:

code_end:

		SAVEBIN "zc_sd_driver.bin",#2000,code_end-#2000
