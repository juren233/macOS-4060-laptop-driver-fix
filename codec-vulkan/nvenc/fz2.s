 .text
_fz:
 vxorps %ymm0,%ymm0,%ymm0
 testq %rsi,%rsi
 je 2f
1:
 vmovups %ymm0,(%rdi)
 vmovups %ymm0,0x20(%rdi)
 addq $0x40,%rdi
 subq $0x40,%rsi
 ja 1b
2:
 sfence
 vzeroupper
 ret
