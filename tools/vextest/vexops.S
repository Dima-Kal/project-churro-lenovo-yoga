// vexops.S — hand-encoded VEX AVX-VNNI / AVX-IFMA stubs for vextest.c.
// All reg stubs: ymm1/xmm1 = a (vvvv), ymm2/xmm2 = b (rm), ymm0/xmm0 = acc+dst.
// Encodings: C4 E2 <W'vvvv'Lpp> <op> <modrm>; byte2 = 0x71 (VNNI.128), 0x75 (VNNI.256),
// 0xF1 (IFMA.128, W1), 0xF5 (IFMA.256, W1); reg-form modrm = mod11 reg000 rm010 = 0xC2.
	.text
	.p2align 4

#define REGSTUB(name, b2, op)			\
	.globl name;				\
name:						\
	vmovdqu	(%rsi), %ymm1;			\
	vmovdqu	(%rdx), %ymm2;			\
	vmovdqu	(%rcx), %ymm0;			\
	.byte	0xc4, 0xe2, b2, op, 0xc2;	\
	vmovdqu	%ymm0, (%rdi);			\
	vzeroupper;				\
	ret

REGSTUB(op50_128_reg, 0x71, 0x50)
REGSTUB(op50_256_reg, 0x75, 0x50)
REGSTUB(op51_128_reg, 0x71, 0x51)
REGSTUB(op51_256_reg, 0x75, 0x51)
REGSTUB(op52_128_reg, 0x71, 0x52)
REGSTUB(op52_256_reg, 0x75, 0x52)
REGSTUB(op53_128_reg, 0x71, 0x53)
REGSTUB(op53_256_reg, 0x75, 0x53)
REGSTUB(opb4_128_reg, 0xf1, 0xb4)
REGSTUB(opb4_256_reg, 0xf5, 0xb4)
REGSTUB(opb5_128_reg, 0xf1, 0xb5)
REGSTUB(opb5_256_reg, 0xf5, 0xb5)

// vpdpwssd ymm0, ymm1, [rax]
	.globl op52_256_mem_ind
op52_256_mem_ind:
	vmovdqu	(%rsi), %ymm1
	vmovdqu	(%rcx), %ymm0
	movq	%rdx, %rax
	.byte	0xc4, 0xe2, 0x75, 0x52, 0x00
	vmovdqu	%ymm0, (%rdi)
	vzeroupper
	ret

// vpdpwssd ymm0, ymm1, [r9 + r10*2 + 64]  (SIB, extended index/base -> VEX X/B)
	.globl op52_256_mem_sib
op52_256_mem_sib:
	vmovdqu	(%rsi), %ymm1
	vmovdqu	(%rcx), %ymm0
	movq	%rdx, %r9
	subq	$64, %r9
	xorl	%r10d, %r10d
	.byte	0xc4, 0x82, 0x75, 0x52, 0x44, 0x51, 0x40
	vmovdqu	%ymm0, (%rdi)
	vzeroupper
	ret

// vpdpwssd ymm0, ymm1, [rip + vripdata]
	.globl op52_256_mem_rip
op52_256_mem_rip:
	vmovdqu	(%rsi), %ymm1
	vmovdqu	(%rcx), %ymm0
	movl	$32, %ecx
	pushq	%rdi
	pushq	%rsi
	movq	%rdx, %rsi
	leaq	vripdata(%rip), %rdi
	rep movsb
	popq	%rsi
	popq	%rdi
	.byte	0xc4, 0xe2, 0x75, 0x52, 0x05
	.long	vripdata - . - 4
	vmovdqu	%ymm0, (%rdi)
	vzeroupper
	ret

// vpdpwssd ymm8, ymm9, ymm10  (extended dst/src registers -> VEX R/B)
	.globl op52_256_reghi
op52_256_reghi:
	vmovdqu	(%rsi), %ymm9
	vmovdqu	(%rdx), %ymm10
	vmovdqu	(%rcx), %ymm8
	.byte	0xc4, 0x42, 0x35, 0x52, 0xc2
	vmovdqu	%ymm8, (%rdi)
	vzeroupper
	ret

// vpmadd52luq ymm0, ymm1, [r9 + r10*2 + 64]
	.globl opb4_256_mem_sib
opb4_256_mem_sib:
	vmovdqu	(%rsi), %ymm1
	vmovdqu	(%rcx), %ymm0
	movq	%rdx, %r9
	subq	$64, %r9
	xorl	%r10d, %r10d
	.byte	0xc4, 0x82, 0xf5, 0xb4, 0x44, 0x51, 0x40
	vmovdqu	%ymm0, (%rdi)
	vzeroupper
	ret

// --- GFNI: AFFINEQB = 66.0F3A.W1 0xCE /r ib, AFFINEINVQB = 66.0F3A.W1 0xCF /r ib,
//     MULB = 66.0F38.W0 0xCF /r (no imm) ---
#define GFSTUB(name, b2, op, imm...)		\
	.globl name;				\
name:						\
	vmovdqu	(%rsi), %ymm1;			\
	vmovdqu	(%rdx), %ymm2;			\
	.byte	0xc4, 0xe3, b2, op, 0xc2, imm;	\
	vmovdqu	%ymm0, (%rdi);			\
	vzeroupper;				\
	ret

GFSTUB(opgb_128_reg, 0xf1, 0xce, 0x63)
GFSTUB(opgb_256_reg, 0xf5, 0xce, 0x63)
GFSTUB(opge_128_reg, 0xf1, 0xcf, 0xa4)
GFSTUB(opge_256_reg, 0xf5, 0xcf, 0xa4)

	.globl opgf_128_reg
opgf_128_reg:
	vmovdqu	(%rsi), %ymm1
	vmovdqu	(%rdx), %ymm2
	.byte	0xc4, 0xe2, 0x71, 0xcf, 0xc2
	vmovdqu	%ymm0, (%rdi)
	vzeroupper
	ret

	.globl opgf_256_reg
opgf_256_reg:
	vmovdqu	(%rsi), %ymm1
	vmovdqu	(%rdx), %ymm2
	.byte	0xc4, 0xe2, 0x75, 0xcf, 0xc2
	vmovdqu	%ymm0, (%rdi)
	vzeroupper
	ret

// vgf2p8affineqb ymm0, ymm1, [r9 + r10*2 + 64], 0x63  (map3: byte1 0x83)
	.globl opgb_256_mem_sib
opgb_256_mem_sib:
	vmovdqu	(%rsi), %ymm1
	movq	%rdx, %r9
	subq	$64, %r9
	xorl	%r10d, %r10d
	.byte	0xc4, 0x83, 0xf5, 0xce, 0x44, 0x51, 0x40, 0x63
	vmovdqu	%ymm0, (%rdi)
	vzeroupper
	ret

// --- SHA-NI, legacy NP: 0F 38 C8..CD /r, 0F 3A CC /r ib ---
// Convention: xmm2 = DEST/SRC1 (<- acc = rcx), xmm1 = SRC2 (<- b = rdx),
// xmm0 = implicit WK operand for sha256rnds2 (<- a = rsi)
#define SHASTUB(name, op)			\
	.globl name;				\
name:						\
	vmovdqu	(%rsi), %xmm0;			\
	vmovdqu	(%rdx), %xmm1;			\
	vmovdqu	(%rcx), %xmm2;			\
	.byte	0x0f, 0x38, op, 0xd1;		\
	vmovdqu	%xmm2, (%rdi);			\
	ret

SHASTUB(sha256rnds2_reg, 0xcb)
SHASTUB(sha256msg1_reg, 0xcc)
SHASTUB(sha256msg2_reg, 0xcd)
SHASTUB(sha1nexte_reg, 0xc8)
SHASTUB(sha1msg1_reg, 0xc9)
SHASTUB(sha1msg2_reg, 0xca)

// sha256msg2 xmm2, [rdx]  (mem operand; NP legacy cannot name r9/r10)
	.globl sha256msg2_mem_sib
sha256msg2_mem_sib:
	vmovdqu	(%rcx), %xmm2
	.byte	0x0f, 0x38, 0xcd, 0x12
	vmovdqu	%xmm2, (%rdi)
	ret

// sha1rnds4 xmm2, xmm1, imm  (NP 0F 3A CC /r ib)
#define SHA4STUB(name, imm)			\
	.globl name;				\
name:						\
	vmovdqu	(%rdx), %xmm1;			\
	vmovdqu	(%rcx), %xmm2;			\
	.byte	0x0f, 0x3a, 0xcc, 0xd1, imm;	\
	vmovdqu	%xmm2, (%rdi);			\
	ret

SHA4STUB(sha1rnds4_i0, 0)
SHA4STUB(sha1rnds4_i1, 1)
SHA4STUB(sha1rnds4_i2, 2)
SHA4STUB(sha1rnds4_i3, 3)

// --- vpclmulqdq: VEX.66.0F3A.W0 0x44 /r ib ---
#define PCMSTUB(name, b2, imm)			\
	.globl name;				\
name:						\
	vmovdqu	(%rsi), %ymm1;			\
	vmovdqu	(%rdx), %ymm2;			\
	.byte	0xc4, 0xe3, b2, 0x44, 0xc2, imm;\
	vmovdqu	%ymm0, (%rdi);			\
	vzeroupper;				\
	ret

PCMSTUB(pc_128_i00, 0x71, 0x00)
PCMSTUB(pc_256_i00, 0x75, 0x00)
PCMSTUB(pc_256_i11, 0x75, 0x11)
PCMSTUB(pc_256_i01, 0x75, 0x01)
PCMSTUB(pc_256_i10, 0x75, 0x10)

// VAES (VEX.256.66.0F38.WIG DC..DF): ymm0 = round(state = ymm1, key = ymm2)
REGSTUB(vaesenc_256_reg, 0x75, 0xdc)
REGSTUB(vaesenclast_256_reg, 0x75, 0xdd)
REGSTUB(vaesdec_256_reg, 0x75, 0xde)
REGSTUB(vaesdeclast_256_reg, 0x75, 0xdf)

// wssd_chain_256(out=rdi, a=rsi, b=rdx, acc=rcx, rounds=r8)
// acc ymm0 chained: acc = vpdpwssd(acc, a[i & 63], b[i & 63]) for i in 0..rounds-1.
// vpdpwssd ymm0, ymm3, ymm4  =  c4 e2 65 52 c4  (vvvv=3 -> Vy=3, rm=4)
	.globl wssd_chain_256
wssd_chain_256:
	vmovdqu	(%rcx), %ymm0
	xorq	%r9, %r9
	cmpq	%r8, %r9
	jae	2f
1:	movq	%r9, %rax
	andq	$63, %rax
	shlq	$5, %rax
	vmovdqu	(%rsi,%rax), %ymm3
	vmovdqu	(%rdx,%rax), %ymm4
	.byte	0xc4, 0xe2, 0x65, 0x52, 0xc4
	incq	%r9
	cmpq	%r8, %r9
	jb	1b
2:	vmovdqu	%ymm0, (%rdi)
	vzeroupper
	ret

// same chaining shape but TCG-native ops (no #UD): used to isolate whether
// divergence comes from the emulation path or from the VM's context switching.
// xavg_chain_256: ymm0 = vpavgw(ymm0, ymm3, ymm4) chained — 66 0F E3 → C4 E2 65 E3 C4
	.globl xavg_chain_256
xavg_chain_256:
	vmovdqu	(%rcx), %ymm0
	xorq	%r9, %r9
	cmpq	%r8, %r9
	jae	2f
1:	movq	%r9, %rax
	andq	$63, %rax
	shlq	$5, %rax
	vmovdqu	(%rsi,%rax), %ymm3
	vmovdqu	(%rdx,%rax), %ymm4
	.byte	0xc4, 0xe2, 0x65, 0xe3, 0xc4
	incq	%r9
	cmpq	%r8, %r9
	jb	1b
2:	vmovdqu	%ymm0, (%rdi)
	vzeroupper
	ret

// wssd_chain_256r1: same chain but acc = ymm1 (vpdpwssd ymm1, ymm3, ymm4 = c4 e2 65 52 cc)
	.globl wssd_chain_256r1
wssd_chain_256r1:
	vmovdqu	(%rcx), %ymm1
	xorq	%r9, %r9
	cmpq	%r8, %r9
	jae	2f
1:	movq	%r9, %rax
	andq	$63, %rax
	shlq	$5, %rax
	vmovdqu	(%rsi,%rax), %ymm3
	vmovdqu	(%rdx,%rax), %ymm4
	.byte	0xc4, 0xe2, 0x65, 0x52, 0xcc
	incq	%r9
	cmpq	%r8, %r9
	jb	1b
2:	vmovdqu	%ymm1, (%rdi)
	vzeroupper
	ret

// m52_chain_256: chained IFMA: per round ymm0 = vpmadd52luq(ymm0, ymm3, ymm4)
// (accumulate into dst like vpdpwssd, but natively supported by TCG) — C4 E3 F5 B4 C4
	.globl m52_chain_256
m52_chain_256:
	vmovdqu	(%rcx), %ymm0
	xorq	%r9, %r9
	cmpq	%r8, %r9
	jae	2f
1:	movq	%r9, %rax
	andq	$63, %rax
	shlq	$5, %rax
	vmovdqu	(%rsi,%rax), %ymm3
	vmovdqu	(%rdx,%rax), %ymm4
	.byte	0xc4, 0xe2, 0xe5, 0xb4, 0xc4
	incq	%r9
	cmpq	%r8, %r9
	jb	1b
2:	vmovdqu	%ymm0, (%rdi)
	vzeroupper
	ret

// xpadd_chain_256: chained TCG-native accumulate: per round ymm0 = ymm0 + ymm3 - ymm4
// vpaddd ymm0,ymm0,ymm3 = c4 e1 7d fe c3  (vvvv=0)  vpsubd ymm0,ymm0,ymm4 = c4 e1 7d fa c4
	.globl xpadd_chain_256
xpadd_chain_256:
	vmovdqu	(%rcx), %ymm0
	xorq	%r9, %r9
	cmpq	%r8, %r9
	jae	2f
1:	movq	%r9, %rax
	andq	$63, %rax
	shlq	$5, %rax
	vmovdqu	(%rsi,%rax), %ymm3
	vmovdqu	(%rdx,%rax), %ymm4
	.byte	0xc4, 0xe1, 0x7d, 0xfe, 0xc3
	.byte	0xc4, 0xe1, 0x7d, 0xfa, 0xc4
	incq	%r9
	cmpq	%r8, %r9
	jb	1b
2:	vmovdqu	%ymm0, (%rdi)
	vzeroupper
	ret

	.data
	.p2align 5
vripdata:
	.fill	32, 1, 0
	.section .note.GNU-stack,"",@progbits
