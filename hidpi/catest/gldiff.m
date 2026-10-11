// gldiff: run the same OpenGL 4.1 core work on the hardware renderer (Apple GL-on-Metal over NVMTL) and on Apple's
// software renderer, then compare the pixels. Steam's CEF (ANGLE on OpenGL) draws through this path.
// build: clang -fobjc-arc -O1 -o gldiff gldiff.m -framework OpenGL -framework IOSurface -framework Foundation -framework CoreFoundation
// run:   ./gldiff [test-substring]
#define GL_SILENCE_DEPRECATION 1
#import <Foundation/Foundation.h>
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>
#include <OpenGL/CGLIOSurface.h>
#include <IOSurface/IOSurface.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define W 64
#define H 64
static int gHW;
static const char *gName;

static CGLContextObj mkctx(int hw) {
    CGLPixelFormatAttribute a[16]; int n = 0;
    a[n++] = kCGLPFAOpenGLProfile; a[n++] = (CGLPixelFormatAttribute)kCGLOGLPVersion_GL4_Core;
    a[n++] = kCGLPFAColorSize; a[n++] = (CGLPixelFormatAttribute)24;
    a[n++] = kCGLPFAAlphaSize; a[n++] = (CGLPixelFormatAttribute)8;
    a[n++] = kCGLPFAAllowOfflineRenderers;
    if (hw) a[n++] = kCGLPFAAccelerated;
    else { a[n++] = kCGLPFARendererID; a[n++] = (CGLPixelFormatAttribute)kCGLRendererGenericFloatID; }
    a[n++] = 0;
    CGLPixelFormatObj pf; GLint np;
    if (CGLChoosePixelFormat(a, &pf, &np) || !pf) { fprintf(stderr, "no pixel format (hw=%d)\n", hw); exit(2); }
    CGLContextObj c; if (CGLCreateContext(pf, NULL, &c)) { fprintf(stderr, "no context\n"); exit(2); }
    CGLDestroyPixelFormat(pf);
    return c;
}

static GLuint sh(GLenum t, const char *src) {
    GLuint s = glCreateShader(t); glShaderSource(s, 1, &src, NULL); glCompileShader(s);
    GLint ok; glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) { char l[2048]; glGetShaderInfoLog(s, sizeof l, NULL, l); fprintf(stderr, "[%s] shader: %s\n", gName, l); exit(3); }
    return s;
}
static GLuint prog(const char *vs, const char *fs) {
    GLuint p = glCreateProgram(); glAttachShader(p, sh(GL_VERTEX_SHADER, vs)); glAttachShader(p, sh(GL_FRAGMENT_SHADER, fs));
    glBindAttribLocation(p, 0, "pos"); glBindAttribLocation(p, 1, "col"); glBindAttribLocation(p, 2, "uv"); glBindAttribLocation(p, 3, "inst");
    glBindFragDataLocation(p, 0, "o");
    glLinkProgram(p); GLint ok; glGetProgramiv(p, GL_LINK_STATUS, &ok);
    if (!ok) { char l[2048]; glGetProgramInfoLog(p, sizeof l, NULL, l); fprintf(stderr, "[%s] link: %s\n", gName, l); exit(3); }
    glUseProgram(p); return p;
}

static GLuint gFbo, gTex, gRectBuf;   // gRectBuf: rect() stream buffer, per context (reset in target())
static void target(void) {
    gRectBuf = 0;
    glGenTextures(1, &gTex); glBindTexture(GL_TEXTURE_2D, gTex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, W, H, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glGenFramebuffers(1, &gFbo); glBindFramebuffer(GL_FRAMEBUFFER, gFbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, gTex, 0);
    GLuint ds; glGenRenderbuffers(1, &ds); glBindRenderbuffer(GL_RENDERBUFFER, ds); glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, W, H);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_RENDERBUFFER, ds);
    glViewport(0, 0, W, H); glClearColor(0, 0, 0, 1); glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);
    GLuint vao; glGenVertexArrays(1, &vao); glBindVertexArray(vao);
}
static GLuint vbo(const void *d, size_t n) { GLuint b; glGenBuffers(1, &b); glBindBuffer(GL_ARRAY_BUFFER, b); glBufferData(GL_ARRAY_BUFFER, n, d, GL_STATIC_DRAW); return b; }
static void attr(GLuint idx, int comps, GLenum type, GLboolean norm, int stride, size_t off) {
    glEnableVertexAttribArray(idx); glVertexAttribPointer(idx, comps, type, norm, stride, (void *)off); }

static const char *VS_POS = "#version 410 core\nin vec2 pos; void main(){ gl_Position=vec4(pos,0,1); }";
static const char *FS_UCOL = "#version 410 core\nuniform vec4 c; out vec4 o; void main(){ o=c; }";
static float RECT[] = { -1,-1, 1,-1, -1,1, 1,1 };

static void rect(float x0, float y0, float x1, float y1) {   // NDC rect via a stream buffer (re-specified every draw)
    float v[] = { x0,y0, x1,y0, x0,y1, x1,y1 };
    GLuint b = gRectBuf; if (!b) { glGenBuffers(1, &b); gRectBuf = b; }
    glBindBuffer(GL_ARRAY_BUFFER, b); glBufferData(GL_ARRAY_BUFFER, sizeof v, v, GL_STREAM_DRAW);
    attr(0, 2, GL_FLOAT, 0, 8, 0); glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

// ---------------------------------------------------------------- tests
static void t_clear(void) { glClearColor(0.2f, 0.4f, 0.6f, 1); glClear(GL_COLOR_BUFFER_BIT); }
static void t_solid(void) { GLuint p = prog(VS_POS, FS_UCOL); glUniform4f(glGetUniformLocation(p, "c"), 1, .5f, .25f, 1); rect(-.5f, -.5f, .5f, .5f); }
static void t_many_uniform_draws(void) {   // uniform changes between draws (Skia: one rect per uniform set)
    GLuint p = prog(VS_POS, FS_UCOL); GLint l = glGetUniformLocation(p, "c");
    for (int i = 0; i < 16; i++) { glUniform4f(l, (i & 1), (i >> 1 & 1), (i >> 2 & 1), 1);
        float x = -1 + (i % 4) * .5f, y = -1 + (i / 4) * .5f; rect(x, y, x + .5f, y + .5f); }
}
static void t_subdata_stream(void) {   // one buffer rewritten with glBufferSubData between draws
    GLuint p = prog(VS_POS, FS_UCOL); GLint l = glGetUniformLocation(p, "c");
    GLuint b; glGenBuffers(1, &b); glBindBuffer(GL_ARRAY_BUFFER, b); glBufferData(GL_ARRAY_BUFFER, 4096, NULL, GL_DYNAMIC_DRAW);
    attr(0, 2, GL_FLOAT, 0, 8, 0);
    for (int i = 0; i < 16; i++) { float x = -1 + (i % 4) * .5f, y = -1 + (i / 4) * .5f; float v[] = { x,y, x+.5f,y, x,y+.5f, x+.5f,y+.5f };
        glBufferSubData(GL_ARRAY_BUFFER, 0, sizeof v, v); glUniform4f(l, (i & 1), (i >> 1 & 1), .5f, 1); glDrawArrays(GL_TRIANGLE_STRIP, 0, 4); }
}
static void t_subdata_offsets(void) {   // ring buffer: each draw writes a new offset
    GLuint p = prog(VS_POS, FS_UCOL); GLint l = glGetUniformLocation(p, "c");
    GLuint b; glGenBuffers(1, &b); glBindBuffer(GL_ARRAY_BUFFER, b); glBufferData(GL_ARRAY_BUFFER, 4096, NULL, GL_DYNAMIC_DRAW);
    for (int i = 0; i < 16; i++) { float x = -1 + (i % 4) * .5f, y = -1 + (i / 4) * .5f; float v[] = { x,y, x+.5f,y, x,y+.5f, x+.5f,y+.5f };
        glBufferSubData(GL_ARRAY_BUFFER, i * 32, sizeof v, v); attr(0, 2, GL_FLOAT, 0, 8, i * 32);
        glUniform4f(l, .5f, (i & 1), (i >> 1 & 1), 1); glDrawArrays(GL_TRIANGLE_STRIP, 0, 4); }
}
static void t_mapbuffer(void) {   // glMapBufferRange invalidate/unsynchronized writes between draws (ANGLE streaming)
    GLuint p = prog(VS_POS, FS_UCOL); GLint l = glGetUniformLocation(p, "c");
    GLuint b; glGenBuffers(1, &b); glBindBuffer(GL_ARRAY_BUFFER, b); glBufferData(GL_ARRAY_BUFFER, 4096, NULL, GL_DYNAMIC_DRAW);
    for (int i = 0; i < 16; i++) { float x = -1 + (i % 4) * .5f, y = -1 + (i / 4) * .5f; float v[] = { x,y, x+.5f,y, x,y+.5f, x+.5f,y+.5f };
        GLbitfield fl = GL_MAP_WRITE_BIT | ((i & 1) ? GL_MAP_UNSYNCHRONIZED_BIT : GL_MAP_INVALIDATE_RANGE_BIT);
        void *m = glMapBufferRange(GL_ARRAY_BUFFER, i * 32, 32, fl); memcpy(m, v, 32); glUnmapBuffer(GL_ARRAY_BUFFER);
        attr(0, 2, GL_FLOAT, 0, 8, i * 32); glUniform4f(l, (i >> 1 & 1), .5f, (i & 1), 1); glDrawArrays(GL_TRIANGLE_STRIP, 0, 4); }
}
static void t_vcolor_ubyte(void) {
    prog("#version 410 core\nin vec2 pos; in vec4 col; out vec4 vc; void main(){ vc=col; gl_Position=vec4(pos,0,1); }",
         "#version 410 core\nin vec4 vc; out vec4 o; void main(){ o=vc; }");
    struct { float x, y; unsigned char c[4]; } v[] = { {-1,-1,{255,0,0,255}}, {1,-1,{0,255,0,255}}, {-1,1,{0,0,255,255}}, {1,1,{255,255,255,255}} };
    vbo(v, sizeof v); attr(0, 2, GL_FLOAT, 0, 12, 0); attr(1, 4, GL_UNSIGNED_BYTE, 1, 12, 8); glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}
static void t_vcolor_ushort_half(void) {
    prog("#version 410 core\nin vec2 pos; in vec4 col; out vec4 vc; void main(){ vc=col; gl_Position=vec4(pos,0,1); }",
         "#version 410 core\nin vec4 vc; out vec4 o; void main(){ o=vc; }");
    struct { short x, y; unsigned short c[4]; } v[] = { {-32767,-32767,{65535,0,0,65535}}, {32767,-32767,{0,65535,0,65535}}, {-32767,32767,{0,0,65535,65535}}, {32767,32767,{30000,30000,30000,65535}} };
    vbo(v, sizeof v); attr(0, 2, GL_SHORT, 1, 12, 0); attr(1, 4, GL_UNSIGNED_SHORT, 1, 12, 4); glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}
static void t_instanced(void) {   // per-instance rect + colour (Ganesh FillRectOp / atlas text style)
    prog("#version 410 core\nin vec2 pos; in vec4 inst; in vec4 col; out vec4 vc; void main(){ vc=col; gl_Position=vec4(mix(inst.xy,inst.zw,pos),0,1); }",
         "#version 410 core\nin vec4 vc; out vec4 o; void main(){ o=vc; }");
    float unit[] = { 0,0, 1,0, 0,1, 1,1 }; vbo(unit, sizeof unit); attr(0, 2, GL_FLOAT, 0, 8, 0);
    struct { float r[4]; unsigned char c[4]; } in[9];
    for (int i = 0; i < 9; i++) { float x = -1 + (i % 3) * .66f, y = -1 + (i / 3) * .66f; in[i] = (typeof(in[0])){ { x, y, x + .6f, y + .6f }, { i * 28, 255 - i * 28, (i & 1) * 255, 255 } }; }
    vbo(in, sizeof in); attr(3, 4, GL_FLOAT, 0, 20, 0); attr(1, 4, GL_UNSIGNED_BYTE, 1, 20, 16);
    glVertexAttribDivisor(3, 1); glVertexAttribDivisor(1, 1);
    glDrawArraysInstanced(GL_TRIANGLE_STRIP, 0, 4, 9);
}
static void t_instanced_baseinst_elements(void) {
    prog("#version 410 core\nin vec2 pos; in vec4 inst; in vec4 col; out vec4 vc; void main(){ vc=col; gl_Position=vec4(mix(inst.xy,inst.zw,pos),0,1); }",
         "#version 410 core\nin vec4 vc; out vec4 o; void main(){ o=vc; }");
    float unit[] = { 0,0, 1,0, 0,1, 1,1 }; vbo(unit, sizeof unit); attr(0, 2, GL_FLOAT, 0, 8, 0);
    struct { float r[4]; unsigned char c[4]; } in[4] = { {{-1,-1,0,0},{255,0,0,255}}, {{0,-1,1,0},{0,255,0,255}}, {{-1,0,0,1},{0,0,255,255}}, {{0,0,1,1},{255,255,0,255}} };
    GLuint ib = vbo(in, sizeof in); (void)ib; attr(3, 4, GL_FLOAT, 0, 20, 0); attr(1, 4, GL_UNSIGNED_BYTE, 1, 20, 16);
    glVertexAttribDivisor(3, 1); glVertexAttribDivisor(1, 1);
    unsigned short idx[] = { 9, 9, 0, 1, 2, 2, 1, 3 }; GLuint eb; glGenBuffers(1, &eb); glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, eb);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof idx, idx, GL_STATIC_DRAW);
    glDrawElementsInstanced(GL_TRIANGLES, 6, GL_UNSIGNED_SHORT, (void *)4, 2);           // instances 0,1
    attr(3, 4, GL_FLOAT, 0, 20, 40); attr(1, 4, GL_UNSIGNED_BYTE, 1, 20, 56);           // instances 2,3 by offset
    glDrawElementsInstanced(GL_TRIANGLES, 6, GL_UNSIGNED_SHORT, (void *)4, 2);
}
static void t_basevertex(void) {
    GLuint p = prog(VS_POS, FS_UCOL); glUniform4f(glGetUniformLocation(p, "c"), .3f, .9f, .6f, 1);
    float v[] = { 9,9, 9,9, 9,9, -.8f,-.8f, .2f,-.8f, -.8f,.2f, .2f,.2f };
    vbo(v, sizeof v); attr(0, 2, GL_FLOAT, 0, 8, 0);
    unsigned int idx[] = { 0, 1, 2, 2, 1, 3 }; GLuint eb; glGenBuffers(1, &eb); glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, eb);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof idx, idx, GL_STATIC_DRAW);
    glDrawElementsBaseVertex(GL_TRIANGLES, 6, GL_UNSIGNED_INT, 0, 3);
}
static void t_ubo(void) {
    GLuint p = prog("#version 410 core\nin vec2 pos; layout(std140) uniform U { vec4 off; vec4 c; mat3 m; }; out vec4 vc; void main(){ vc=c; gl_Position=vec4((m*vec3(pos,1)).xy+off.xy,0,1); }",
                    "#version 410 core\nin vec4 vc; out vec4 o; void main(){ o=vc; }");
    float u[] = { .1f,.2f,0,0, .9f,.1f,.5f,1, .5f,0,0,0, 0,.5f,0,0, 0,0,1,0 };
    GLuint ub; glGenBuffers(1, &ub); glBindBuffer(GL_UNIFORM_BUFFER, ub); glBufferData(GL_UNIFORM_BUFFER, sizeof u, u, GL_DYNAMIC_DRAW);
    glUniformBlockBinding(p, glGetUniformBlockIndex(p, "U"), 2); glBindBufferBase(GL_UNIFORM_BUFFER, 2, ub);
    vbo(RECT, sizeof RECT); attr(0, 2, GL_FLOAT, 0, 8, 0); glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    u[0] = -.6f; u[4] = .1f; u[5] = .8f; glBufferSubData(GL_UNIFORM_BUFFER, 0, sizeof u, u); glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}
static void t_uniform_arrays(void) {   // Skia passes uniforms as vec4 arrays / mat3
    GLuint p = prog("#version 410 core\nin vec2 pos; uniform mat3 m; uniform vec4 a[4]; flat out int k; out vec4 vc; void main(){ k=gl_VertexID; vc=a[gl_VertexID]; gl_Position=vec4((m*vec3(pos,1)).xy,0,1); }",
                    "#version 410 core\nin vec4 vc; flat in int k; uniform float s[4]; out vec4 o; void main(){ o=vc*s[k]; }");
    float m[9] = { .8f,0,0, 0,.8f,0, .1f,0,1 }; glUniformMatrix3fv(glGetUniformLocation(p, "m"), 1, 0, m);
    float a[16] = { 1,0,0,1, 0,1,0,1, 0,0,1,1, 1,1,1,1 }; glUniform4fv(glGetUniformLocation(p, "a"), 4, a);
    float s[4] = { 1, .5f, .75f, .25f }; glUniform1fv(glGetUniformLocation(p, "s"), 4, s);
    vbo(RECT, sizeof RECT); attr(0, 2, GL_FLOAT, 0, 8, 0); glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}
static unsigned char gImg[32 * 32 * 4];
static GLuint tex2d(GLenum ifmt, GLenum fmt, GLenum type, int w, int h, const void *d) {
    GLuint t; glGenTextures(1, &t); glBindTexture(GL_TEXTURE_2D, t); glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexImage2D(GL_TEXTURE_2D, 0, ifmt, w, h, 0, fmt, type, d);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    return t;
}
static const char *VS_UV = "#version 410 core\nin vec2 pos; out vec2 tc; void main(){ tc=pos*.5+.5; gl_Position=vec4(pos,0,1); }";
static void mkimg(void) { for (int y = 0; y < 32; y++) for (int x = 0; x < 32; x++) { unsigned char *p = gImg + (y * 32 + x) * 4;
    p[0] = x * 8; p[1] = y * 8; p[2] = ((x ^ y) & 8) ? 255 : 30; p[3] = 128 + ((x + y) & 127); } }
static void drawtex(const char *fs, GLenum target) {
    GLuint p = prog(VS_UV, fs); glUniform1i(glGetUniformLocation(p, "t"), 0); (void)target;
    vbo(RECT, sizeof RECT); attr(0, 2, GL_FLOAT, 0, 8, 0); glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}
static void t_tex_rgba(void) { mkimg(); tex2d(GL_RGBA8, GL_RGBA, GL_UNSIGNED_BYTE, 32, 32, gImg);
    drawtex("#version 410 core\nin vec2 tc; uniform sampler2D t; out vec4 o; void main(){ o=texture(t,tc); }", GL_TEXTURE_2D); }
static void t_tex_bgra(void) { mkimg(); tex2d(GL_RGBA8, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, 32, 32, gImg);
    drawtex("#version 410 core\nin vec2 tc; uniform sampler2D t; out vec4 o; void main(){ o=texture(t,tc); }", GL_TEXTURE_2D); }
static void t_tex_r8(void) { mkimg(); unsigned char r[32 * 32]; for (int i = 0; i < 32 * 32; i++) r[i] = gImg[i * 4];
    tex2d(GL_R8, GL_RED, GL_UNSIGNED_BYTE, 32, 32, r);
    drawtex("#version 410 core\nin vec2 tc; uniform sampler2D t; out vec4 o; void main(){ o=vec4(texture(t,tc).r, .5, texture(t,tc).a, 1); }", GL_TEXTURE_2D); }
static void t_tex_swizzle_alpha(void) {   // ANGLE emulates A8/L8 with R8 + swizzle
    mkimg(); unsigned char r[32 * 32]; for (int i = 0; i < 32 * 32; i++) r[i] = gImg[i * 4 + 1];
    tex2d(GL_R8, GL_RED, GL_UNSIGNED_BYTE, 32, 32, r);
    GLint sw[4] = { GL_ZERO, GL_ZERO, GL_ZERO, GL_RED }; glTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_RGBA, sw);
    drawtex("#version 410 core\nin vec2 tc; uniform sampler2D t; out vec4 o; void main(){ vec4 s=texture(t,tc); o=vec4(s.a, s.r+.2, s.g+.4, 1); }", GL_TEXTURE_2D); }
static void t_tex_swizzle_bgra(void) {
    mkimg(); tex2d(GL_RGBA8, GL_RGBA, GL_UNSIGNED_BYTE, 32, 32, gImg);
    GLint sw[4] = { GL_BLUE, GL_GREEN, GL_RED, GL_ONE }; glTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_RGBA, sw);
    drawtex("#version 410 core\nin vec2 tc; uniform sampler2D t; out vec4 o; void main(){ o=texture(t,tc); }", GL_TEXTURE_2D); }
static void t_tex_subimage(void) {   // glyph-atlas style: TexSubImage between draws
    GLuint p = prog(VS_UV, "#version 410 core\nin vec2 tc; uniform sampler2D t; out vec4 o; void main(){ o=vec4(texture(t,tc).r,0,0,1); }");
    glUniform1i(glGetUniformLocation(p, "t"), 0);
    unsigned char z[32 * 32] = {0}; tex2d(GL_R8, GL_RED, GL_UNSIGNED_BYTE, 32, 32, z);
    vbo(RECT, sizeof RECT);
    for (int i = 0; i < 4; i++) { unsigned char blk[16 * 16]; memset(blk, 60 + i * 60, sizeof blk);
        glTexSubImage2D(GL_TEXTURE_2D, 0, (i & 1) * 16, (i >> 1) * 16, 16, 16, GL_RED, GL_UNSIGNED_BYTE, blk);
        float x = -1 + (i & 1), y = -1 + (i >> 1); float v[] = { x,y, x+1,y, x,y+1, x+1,y+1 };
        glBufferData(GL_ARRAY_BUFFER, sizeof v, v, GL_STREAM_DRAW); attr(0, 2, GL_FLOAT, 0, 8, 0); glDrawArrays(GL_TRIANGLE_STRIP, 0, 4); }
}
static void t_tex_pbo_upload(void) {
    mkimg(); GLuint pb; glGenBuffers(1, &pb); glBindBuffer(GL_PIXEL_UNPACK_BUFFER, pb); glBufferData(GL_PIXEL_UNPACK_BUFFER, sizeof gImg, gImg, GL_STREAM_DRAW);
    tex2d(GL_RGBA8, GL_RGBA, GL_UNSIGNED_BYTE, 32, 32, NULL);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 32, 32, GL_RGBA, GL_UNSIGNED_BYTE, 0); glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
    drawtex("#version 410 core\nin vec2 tc; uniform sampler2D t; out vec4 o; void main(){ o=texture(t,tc); }", GL_TEXTURE_2D); }
static void t_texelfetch_linear_mip(void) {
    mkimg(); tex2d(GL_RGBA8, GL_RGBA, GL_UNSIGNED_BYTE, 32, 32, gImg); glGenerateMipmap(GL_TEXTURE_2D);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR);
    drawtex("#version 410 core\nin vec2 tc; uniform sampler2D t; out vec4 o; void main(){ o=texelFetch(t,ivec2(tc*32.),0)*.5+textureLod(t,tc,1.)*.5; }", GL_TEXTURE_2D); }
static void t_blend_premul(void) {
    GLuint p = prog(VS_POS, FS_UCOL); GLint l = glGetUniformLocation(p, "c");
    glUniform4f(l, .8f, .2f, .1f, 1); rect(-1, -1, .3f, .3f);
    glEnable(GL_BLEND); glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
    glUniform4f(l, 0, .25f, .5f, .5f); rect(-.3f, -.3f, 1, 1);
    glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
    glUniform4f(l, 1, 1, 1, .3f); rect(-.6f, -.9f, .9f, -.5f);
    glBlendEquation(GL_MAX); glUniform4f(l, .1f, .1f, .9f, 1); rect(.5f, -1, 1, 1);
    glDisable(GL_BLEND);
}
static void t_scissor(void) {
    GLuint p = prog(VS_POS, FS_UCOL); GLint l = glGetUniformLocation(p, "c");
    glEnable(GL_SCISSOR_TEST);
    for (int i = 0; i < 4; i++) { glScissor(5 + i * 12, 3 + i * 9, 20, 30); glUniform4f(l, i * .25f, 1 - i * .25f, .5f, 1); rect(-1, -1, 1, 1); }
    glScissor(40, 40, 10, 10); glClearColor(1, 1, 0, 1); glClear(GL_COLOR_BUFFER_BIT);
    glDisable(GL_SCISSOR_TEST);
}
static void t_colormask(void) {
    GLuint p = prog(VS_POS, FS_UCOL); glUniform4f(glGetUniformLocation(p, "c"), 1, 1, 1, 1);
    glClearColor(.2f, .3f, .4f, .5f); glClear(GL_COLOR_BUFFER_BIT);
    glColorMask(1, 0, 1, 0); rect(-.5f, -.5f, .5f, .5f); glColorMask(1, 1, 1, 1);
}
static void t_stencil_path(void) {   // Skia stencil-then-cover
    GLuint p = prog(VS_POS, FS_UCOL); GLint l = glGetUniformLocation(p, "c");
    glEnable(GL_STENCIL_TEST); glColorMask(0, 0, 0, 0);
    glStencilFunc(GL_ALWAYS, 0, 0xff); glStencilOpSeparate(GL_FRONT, GL_KEEP, GL_KEEP, GL_INCR_WRAP); glStencilOpSeparate(GL_BACK, GL_KEEP, GL_KEEP, GL_DECR_WRAP);
    float fan[] = { 0,0, -.9f,-.9f, .9f,-.5f, -.2f,.9f, .9f,.9f, -.9f,.2f, .5f,-.9f, -.9f,-.9f };
    vbo(fan, sizeof fan); attr(0, 2, GL_FLOAT, 0, 8, 0); glDrawArrays(GL_TRIANGLE_FAN, 0, 8);
    glColorMask(1, 1, 1, 1); glStencilFunc(GL_NOTEQUAL, 0, 0xff); glStencilOp(GL_ZERO, GL_ZERO, GL_ZERO);
    glUniform4f(l, .9f, .7f, .1f, 1); rect(-1, -1, 1, 1);
    glStencilFunc(GL_EQUAL, 0, 0xff); glUniform4f(l, .1f, .2f, .6f, 1); rect(-1, -1, 0, 0);
    glDisable(GL_STENCIL_TEST);
}
static void t_stencil_clip_clear(void) {   // scissored stencil clear (Skia clip) then stencil-tested draw
    GLuint p = prog(VS_POS, FS_UCOL); GLint l = glGetUniformLocation(p, "c");
    glEnable(GL_SCISSOR_TEST); glScissor(8, 8, 30, 40); glClearStencil(0x80); glClear(GL_STENCIL_BUFFER_BIT); glDisable(GL_SCISSOR_TEST);
    glEnable(GL_STENCIL_TEST); glStencilFunc(GL_EQUAL, 0x80, 0x80); glStencilOp(GL_KEEP, GL_KEEP, GL_KEEP); glStencilMask(0);
    glUniform4f(l, .2f, .9f, .4f, 1); rect(-1, -1, 1, 1); glStencilMask(0xff); glDisable(GL_STENCIL_TEST);
}
static void t_depth(void) {
    GLuint p = prog("#version 410 core\nin vec2 pos; uniform float z; void main(){ gl_Position=vec4(pos,z,1); }", FS_UCOL); GLint l = glGetUniformLocation(p, "c"), zl = glGetUniformLocation(p, "z");
    glEnable(GL_DEPTH_TEST); glDepthFunc(GL_LESS);
    glUniform1f(zl, .2f); glUniform4f(l, 1, 0, 0, 1); rect(-.8f, -.8f, .4f, .4f);
    glUniform1f(zl, .5f); glUniform4f(l, 0, 1, 0, 1); rect(-.4f, -.4f, .8f, .8f);
    glUniform1f(zl, -.5f); glUniform4f(l, 0, 0, 1, 1); rect(0, -1, .2f, 1);
    glDisable(GL_DEPTH_TEST);
}
static void t_discard_fragcoord(void) {
    prog(VS_POS, "#version 410 core\nout vec4 o; void main(){ ivec2 p=ivec2(gl_FragCoord.xy); if(((p.x/4+p.y/4)&1)==1) discard; o=vec4(gl_FragCoord.x/64.,gl_FragCoord.y/64.,.5,1); }");
    rect(-1, -1, 1, 1);
}
static void t_fbo_sample(void) {   // render to texture, then sample it (offscreen surfaces / tiles)
    GLuint t = tex2d(GL_RGBA8, GL_RGBA, GL_UNSIGNED_BYTE, 32, 32, NULL);
    GLuint f; glGenFramebuffers(1, &f); glBindFramebuffer(GL_FRAMEBUFFER, f); glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, t, 0);
    glViewport(0, 0, 32, 32); glClearColor(.1f, .5f, .9f, 1); glClear(GL_COLOR_BUFFER_BIT);
    GLuint p = prog(VS_POS, FS_UCOL); glUniform4f(glGetUniformLocation(p, "c"), 1, .8f, 0, 1); rect(-.5f, -1, .2f, .6f);
    glBindFramebuffer(GL_FRAMEBUFFER, gFbo); glViewport(0, 0, W, H);
    glBindTexture(GL_TEXTURE_2D, t);
    drawtex("#version 410 core\nin vec2 tc; uniform sampler2D t; out vec4 o; void main(){ o=texture(t,tc*vec2(1,.5)+vec2(0,.25)); }", GL_TEXTURE_2D);
}
static void t_fbo_pingpong(void) {   // many small offscreen passes, each sampled by the next
    GLuint t[2], f[2];
    for (int i = 0; i < 2; i++) { t[i] = tex2d(GL_RGBA8, GL_RGBA, GL_UNSIGNED_BYTE, W, H, NULL); glGenFramebuffers(1, &f[i]);
        glBindFramebuffer(GL_FRAMEBUFFER, f[i]); glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, t[i], 0); glClearColor(0, 0, 0, 1); glClear(GL_COLOR_BUFFER_BIT); }
    GLuint p = prog(VS_UV, "#version 410 core\nin vec2 tc; uniform sampler2D t; uniform vec4 c; uniform vec4 r; out vec4 o; void main(){ vec4 s=texture(t,tc); bool in_=all(greaterThan(tc,r.xy))&&all(lessThan(tc,r.zw)); o=in_?c:s; }");
    GLint cl = glGetUniformLocation(p, "c"), rl = glGetUniformLocation(p, "r"); glUniform1i(glGetUniformLocation(p, "t"), 0);
    vbo(RECT, sizeof RECT); attr(0, 2, GL_FLOAT, 0, 8, 0);
    for (int i = 0; i < 12; i++) { glBindFramebuffer(GL_FRAMEBUFFER, f[(i + 1) & 1]); glBindTexture(GL_TEXTURE_2D, t[i & 1]);
        glUniform4f(cl, (i % 3) / 2.f, (i % 4) / 3.f, (i % 5) / 4.f, 1); float x = (i % 4) * .25f, y = (i / 4) * .33f; glUniform4f(rl, x, y, x + .2f, y + .3f);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4); }
    glBindFramebuffer(GL_FRAMEBUFFER, gFbo); glBindTexture(GL_TEXTURE_2D, t[0]);
    GLuint p2 = prog(VS_UV, "#version 410 core\nin vec2 tc; uniform sampler2D t; out vec4 o; void main(){ o=texture(t,tc); }"); glUniform1i(glGetUniformLocation(p2, "t"), 0);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}
static void t_blit(void) {
    GLuint t = tex2d(GL_RGBA8, GL_RGBA, GL_UNSIGNED_BYTE, 32, 32, (mkimg(), gImg));
    GLuint f; glGenFramebuffers(1, &f); glBindFramebuffer(GL_READ_FRAMEBUFFER, f); glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, t, 0);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, gFbo);
    glBlitFramebuffer(0, 0, 32, 32, 4, 4, 36, 36, GL_COLOR_BUFFER_BIT, GL_NEAREST);
    glBlitFramebuffer(8, 8, 24, 24, 40, 10, 60, 60, GL_COLOR_BUFFER_BIT, GL_NEAREST);
    glBlitFramebuffer(0, 0, 32, 32, 63, 40, 40, 63, GL_COLOR_BUFFER_BIT, GL_NEAREST);   // flipped
    glBindFramebuffer(GL_FRAMEBUFFER, gFbo);
}
static void t_copyteximage(void) {
    GLuint p = prog(VS_POS, FS_UCOL); GLint l = glGetUniformLocation(p, "c");
    glUniform4f(l, .9f, .3f, .6f, 1); rect(-1, -1, 0, 0); glUniform4f(l, .2f, .8f, .3f, 1); rect(-.5f, -.5f, .2f, .1f);
    GLuint t = tex2d(GL_RGBA8, GL_RGBA, GL_UNSIGNED_BYTE, 32, 32, NULL);
    glCopyTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 0, 0, 32, 32);
    glBindTexture(GL_TEXTURE_2D, t);
    GLuint p2 = prog("#version 410 core\nin vec2 pos; out vec2 tc; void main(){ tc=pos*.5+.5; gl_Position=vec4(pos*.5+.5,0,1); }",
                     "#version 410 core\nin vec2 tc; uniform sampler2D t; out vec4 o; void main(){ o=texture(t,tc); }");
    glUniform1i(glGetUniformLocation(p2, "t"), 0); vbo(RECT, sizeof RECT); attr(0, 2, GL_FLOAT, 0, 8, 0); glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}
static void t_msaa_resolve(void) {
    GLuint rb, f; glGenRenderbuffers(1, &rb); glBindRenderbuffer(GL_RENDERBUFFER, rb); glRenderbufferStorageMultisample(GL_RENDERBUFFER, 4, GL_RGBA8, W, H);
    glGenFramebuffers(1, &f); glBindFramebuffer(GL_FRAMEBUFFER, f); glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb);
    glClearColor(.1f, .1f, .1f, 1); glClear(GL_COLOR_BUFFER_BIT);
    GLuint p = prog(VS_POS, FS_UCOL); glUniform4f(glGetUniformLocation(p, "c"), 1, .9f, .2f, 1);
    float tri[] = { -.9f,-.9f, .9f,-.6f, -.3f,.9f }; vbo(tri, sizeof tri); attr(0, 2, GL_FLOAT, 0, 8, 0); glDrawArrays(GL_TRIANGLES, 0, 3);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, f); glBindFramebuffer(GL_DRAW_FRAMEBUFFER, gFbo);
    glBlitFramebuffer(0, 0, W, H, 0, 0, W, H, GL_COLOR_BUFFER_BIT, GL_NEAREST); glBindFramebuffer(GL_FRAMEBUFFER, gFbo);
}
static IOSurfaceRef mksurf(int w, int h) {
    int bpr = w * 4; bpr = (bpr + 63) & ~63;
    NSDictionary *d = @{ (id)kIOSurfaceWidth: @(w), (id)kIOSurfaceHeight: @(h), (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfaceBytesPerRow: @(bpr),
                         (id)kIOSurfacePixelFormat: @((unsigned)'BGRA') };
    return IOSurfaceCreate((__bridge CFDictionaryRef)d);
}
static GLuint surftex(IOSurfaceRef s, int w, int h) {
    GLuint t; glGenTextures(1, &t); glBindTexture(GL_TEXTURE_RECTANGLE, t);
    CGLError e = CGLTexImageIOSurface2D(CGLGetCurrentContext(), GL_TEXTURE_RECTANGLE, GL_RGBA, w, h, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, s, 0);
    if (e) { fprintf(stderr, "[%s] CGLTexImageIOSurface2D %d\n", gName, e); exit(4); }
    glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_MIN_FILTER, GL_NEAREST); glTexParameteri(GL_TEXTURE_RECTANGLE, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    return t;
}
static const char *FS_RECT = "#version 410 core\nin vec2 tc; uniform sampler2DRect t; uniform vec2 sz; out vec4 o; void main(){ o=texture(t,tc*sz); }";
static void t_iosurface_cpu_sample(void) {   // CPU-written IOSurface sampled as a rectangle texture (raster tiles / images)
    IOSurfaceRef s = mksurf(32, 32); IOSurfaceLock(s, 0, NULL); unsigned char *b = IOSurfaceGetBaseAddress(s); size_t bpr = IOSurfaceGetBytesPerRow(s);
    mkimg(); for (int y = 0; y < 32; y++) for (int x = 0; x < 32; x++) { unsigned char *p = b + y * bpr + x * 4, *q = gImg + (y * 32 + x) * 4; p[0] = q[2]; p[1] = q[1]; p[2] = q[0]; p[3] = 255; }
    IOSurfaceUnlock(s, 0, NULL);
    surftex(s, 32, 32); GLuint p = prog(VS_UV, FS_RECT); glUniform1i(glGetUniformLocation(p, "t"), 0); glUniform2f(glGetUniformLocation(p, "sz"), 32, 32);
    vbo(RECT, sizeof RECT); attr(0, 2, GL_FLOAT, 0, 8, 0); glDrawArrays(GL_TRIANGLE_STRIP, 0, 4); CFRelease(s);
}
static void t_iosurface_render_sample(void) {   // GPU raster into an IOSurface tile, then composite it (Chromium zero-copy tiles)
    IOSurfaceRef s[4]; GLuint t[4], f[4];
    GLuint p = prog(VS_POS, FS_UCOL); GLint l = glGetUniformLocation(p, "c");
    for (int i = 0; i < 4; i++) { s[i] = mksurf(32, 32); t[i] = surftex(s[i], 32, 32); glGenFramebuffers(1, &f[i]); glBindFramebuffer(GL_FRAMEBUFFER, f[i]);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_RECTANGLE, t[i], 0); glViewport(0, 0, 32, 32);
        glClearColor(i * .3f, .2f, 1 - i * .3f, 1); glClear(GL_COLOR_BUFFER_BIT); glUseProgram(p); glUniform4f(l, 1, 1, i * .3f, 1);
        rect(-.8f + i * .2f, -.8f, -.2f + i * .2f, .8f - i * .3f); }
    glFlush();
    glBindFramebuffer(GL_FRAMEBUFFER, gFbo); glViewport(0, 0, W, H);
    GLuint p2 = prog("#version 410 core\nin vec2 pos; uniform vec2 o2; out vec2 tc; void main(){ tc=pos*.5+.5; gl_Position=vec4((pos*.5+.5)+o2,0,1); }", FS_RECT);
    glUniform1i(glGetUniformLocation(p2, "t"), 0); glUniform2f(glGetUniformLocation(p2, "sz"), 32, 32); GLint ol = glGetUniformLocation(p2, "o2");
    vbo(RECT, sizeof RECT); attr(0, 2, GL_FLOAT, 0, 8, 0);
    for (int i = 0; i < 4; i++) { glBindTexture(GL_TEXTURE_RECTANGLE, t[i]); glUniform2f(ol, (i & 1) - 1.f, (i >> 1) - 1.f); glDrawArrays(GL_TRIANGLE_STRIP, 0, 4); }
    for (int i = 0; i < 4; i++) CFRelease(s[i]);
}
static void t_iosurface_rerender(void) {   // the same IOSurface tile redrawn between composites (tile reuse while scrolling)
    IOSurfaceRef s = mksurf(32, 32); GLuint t = surftex(s, 32, 32), f; glGenFramebuffers(1, &f);
    glBindFramebuffer(GL_FRAMEBUFFER, f); glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_RECTANGLE, t, 0);
    GLuint p = prog(VS_POS, FS_UCOL); GLint l = glGetUniformLocation(p, "c");
    GLuint p2 = prog("#version 410 core\nin vec2 pos; uniform vec2 o2; out vec2 tc; void main(){ tc=pos*.5+.5; gl_Position=vec4((pos*.5+.5)+o2,0,1); }", FS_RECT);
    glUniform1i(glGetUniformLocation(p2, "t"), 0); glUniform2f(glGetUniformLocation(p2, "sz"), 32, 32); GLint ol = glGetUniformLocation(p2, "o2");
    GLuint rb = vbo(RECT, sizeof RECT);
    for (int i = 0; i < 4; i++) {
        glBindFramebuffer(GL_FRAMEBUFFER, f); glViewport(0, 0, 32, 32); glUseProgram(p);
        glClearColor(.2f * i, .9f - .2f * i, .4f, 1); glClear(GL_COLOR_BUFFER_BIT); glUniform4f(l, 1, .5f, .2f * i, 1); rect(-.5f, -.5f + .2f * i, .5f, .2f * i);
        glBindFramebuffer(GL_FRAMEBUFFER, gFbo); glViewport(0, 0, W, H); glUseProgram(p2); glBindTexture(GL_TEXTURE_RECTANGLE, t);
        glBindBuffer(GL_ARRAY_BUFFER, rb); attr(0, 2, GL_FLOAT, 0, 8, 0); glUniform2f(ol, (i & 1) - 1.f, (i >> 1) - 1.f); glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    }
    CFRelease(s);
}
static void t_tex_respecify(void) {   // the same texture name re-specified with new contents between draws
    GLuint p = prog("#version 410 core\nin vec2 pos; uniform vec2 o2; out vec2 tc; void main(){ tc=pos*.5+.5; gl_Position=vec4((pos*.5+.5)+o2,0,1); }",
                    "#version 410 core\nin vec2 tc; uniform sampler2D t; out vec4 o; void main(){ o=texture(t,tc); }");
    glUniform1i(glGetUniformLocation(p, "t"), 0); GLint ol = glGetUniformLocation(p, "o2");
    GLuint t = tex2d(GL_RGBA8, GL_RGBA, GL_UNSIGNED_BYTE, 32, 32, NULL); vbo(RECT, sizeof RECT); attr(0, 2, GL_FLOAT, 0, 8, 0);
    mkimg();
    for (int i = 0; i < 4; i++) { for (int k = 0; k < 32 * 32; k++) { gImg[k * 4 + 3] = 255; gImg[k * 4 + 2] = i * 80; }
        glBindTexture(GL_TEXTURE_2D, t); glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 32, 32, 0, GL_RGBA, GL_UNSIGNED_BYTE, gImg);
        glUniform2f(ol, (i & 1) - 1.f, (i >> 1) - 1.f); glDrawArrays(GL_TRIANGLE_STRIP, 0, 4); }
}
static void t_multi_tex_units(void) {
    mkimg(); GLuint a = tex2d(GL_RGBA8, GL_RGBA, GL_UNSIGNED_BYTE, 32, 32, gImg);
    unsigned char r[32 * 32]; for (int i = 0; i < 32 * 32; i++) r[i] = (i * 7) & 255; glActiveTexture(GL_TEXTURE3); GLuint b = tex2d(GL_R8, GL_RED, GL_UNSIGNED_BYTE, 32, 32, r);
    glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, a); (void)b;
    GLuint p = prog(VS_UV, "#version 410 core\nin vec2 tc; uniform sampler2D t; uniform sampler2D m; out vec4 o; void main(){ o=texture(t,tc)*texture(m,tc).r; }");
    glUniform1i(glGetUniformLocation(p, "t"), 0); glUniform1i(glGetUniformLocation(p, "m"), 3);
    vbo(RECT, sizeof RECT); attr(0, 2, GL_FLOAT, 0, 8, 0); glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}
static void t_sampler_object(void) {
    mkimg(); tex2d(GL_RGBA8, GL_RGBA, GL_UNSIGNED_BYTE, 32, 32, gImg);
    GLuint s; glGenSamplers(1, &s); glSamplerParameteri(s, GL_TEXTURE_MIN_FILTER, GL_LINEAR); glSamplerParameteri(s, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glSamplerParameteri(s, GL_TEXTURE_WRAP_S, GL_REPEAT); glSamplerParameteri(s, GL_TEXTURE_WRAP_T, GL_MIRRORED_REPEAT); glBindSampler(0, s);
    drawtex("#version 410 core\nin vec2 tc; uniform sampler2D t; out vec4 o; void main(){ o=texture(t,tc*2.3-.4); }", GL_TEXTURE_2D);
    glBindSampler(0, 0);
}
static void t_points_lines(void) {
    GLuint p = prog(VS_POS, FS_UCOL); glUniform4f(glGetUniformLocation(p, "c"), 1, 1, .5f, 1);
    float v[] = { -.9f,-.9f, .9f,.7f, -.9f,.5f, .5f,-.9f }; vbo(v, sizeof v); attr(0, 2, GL_FLOAT, 0, 8, 0); glDrawArrays(GL_LINES, 0, 4);
    glDrawArrays(GL_LINE_STRIP, 0, 4);
}
static void t_tri_strip_restart(void) {
    GLuint p = prog(VS_POS, FS_UCOL); glUniform4f(glGetUniformLocation(p, "c"), .4f, .8f, 1, 1);
    float v[] = { -1,-1, 0,-1, -1,0, 0,0, .2f,.2f, 1,.2f, .2f,1, 1,1 }; vbo(v, sizeof v); attr(0, 2, GL_FLOAT, 0, 8, 0);
    unsigned short idx[] = { 0, 1, 2, 3, 0xffff, 4, 5, 6, 7 }; GLuint eb; glGenBuffers(1, &eb); glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, eb);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof idx, idx, GL_STATIC_DRAW);
    glEnable(GL_PRIMITIVE_RESTART); glPrimitiveRestartIndex(0xffff); glDrawElements(GL_TRIANGLE_STRIP, 9, GL_UNSIGNED_SHORT, 0); glDisable(GL_PRIMITIVE_RESTART);
}
static void t_int_attr_flat(void) {
    prog("#version 410 core\nin vec2 pos; in ivec4 col; flat out ivec4 k; void main(){ k=col; gl_Position=vec4(pos,0,1); }",
         "#version 410 core\nflat in ivec4 k; out vec4 o; void main(){ o=vec4(k)/255.; }");
    struct { float x, y; unsigned char c[4]; } v[] = { {-1,-1,{200,10,10,255}}, {1,-1,{10,200,10,255}}, {-1,1,{10,10,200,255}}, {1,1,{200,200,10,255}} };
    vbo(v, sizeof v); attr(0, 2, GL_FLOAT, 0, 12, 0); glEnableVertexAttribArray(1); glVertexAttribIPointer(1, 4, GL_UNSIGNED_BYTE, 12, (void *)8);
    glDrawArrays(GL_TRIANGLES, 0, 3); glDrawArrays(GL_TRIANGLES, 1, 3);
}
static void t_vertexid_noattr(void) {   // attribute-less draw (ANGLE/Chromium blit helpers)
    prog("#version 410 core\nvoid main(){ vec2 p=vec2((gl_VertexID&1)*2-1, (gl_VertexID>>1)*2-1)*.7; gl_Position=vec4(p,0,1); }",
         "#version 410 core\nout vec4 o; void main(){ o=vec4(.3,.6,.9,1); }");
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}
static void t_halffloat_tex(void) {
    unsigned short h[32 * 32 * 4]; for (int i = 0; i < 32 * 32; i++) { h[i*4] = 0x3800; h[i*4+1] = (i & 31) < 16 ? 0x3c00 : 0x3400; h[i*4+2] = 0x3000; h[i*4+3] = 0x3c00; }
    tex2d(GL_RGBA16F, GL_RGBA, GL_HALF_FLOAT, 32, 32, h);
    drawtex("#version 410 core\nin vec2 tc; uniform sampler2D t; out vec4 o; void main(){ o=texture(t,tc); }", GL_TEXTURE_2D); }
static void t_readpixels_midframe(void) {   // glReadPixels between draws (Chromium readbacks)
    GLuint p = prog(VS_POS, FS_UCOL); GLint l = glGetUniformLocation(p, "c");
    glUniform4f(l, 1, 0, 0, 1); rect(-1, -1, 0, 0);
    unsigned char px[4]; glReadPixels(5, 5, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
    glUniform4f(l, px[0] / 255.f * .5f, 1, 0, 1); rect(0, 0, 1, 1);
}
static void t_fence_sync(void) {
    GLuint p = prog(VS_POS, FS_UCOL); GLint l = glGetUniformLocation(p, "c");
    for (int i = 0; i < 4; i++) { glUniform4f(l, i * .3f, .5f, 1 - i * .3f, 1); rect(-1 + i * .5f, -1, -.5f + i * .5f, 1);
        GLsync s = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0); glFlush(); glClientWaitSync(s, GL_SYNC_FLUSH_COMMANDS_BIT, 1000000000ull); glDeleteSync(s); }
}

typedef void (*tfn)(void);
static struct { const char *n; tfn f; } T[] = {
#define X(n) { #n, t_##n }
    X(clear), X(solid), X(many_uniform_draws), X(subdata_stream), X(subdata_offsets), X(mapbuffer), X(vcolor_ubyte), X(vcolor_ushort_half),
    X(instanced), X(instanced_baseinst_elements), X(basevertex), X(ubo), X(uniform_arrays), X(tex_rgba), X(tex_bgra), X(tex_r8),
    X(tex_swizzle_alpha), X(tex_swizzle_bgra), X(tex_subimage), X(tex_pbo_upload), X(texelfetch_linear_mip), X(blend_premul), X(scissor),
    X(colormask), X(stencil_path), X(stencil_clip_clear), X(depth), X(discard_fragcoord), X(fbo_sample), X(fbo_pingpong), X(blit),
    X(copyteximage), X(msaa_resolve), X(iosurface_cpu_sample), X(iosurface_render_sample), X(iosurface_rerender), X(tex_respecify),
    X(multi_tex_units), X(sampler_object), X(points_lines), X(tri_strip_restart), X(int_attr_flat), X(vertexid_noattr), X(halffloat_tex),
    X(readpixels_midframe), X(fence_sync),
#undef X
};

static void run(int hw, int i, unsigned char *out) {
    CGLContextObj c = mkctx(hw); CGLSetCurrentContext(c); gHW = hw; gName = T[i].n;
    target(); T[i].f();
    glBindFramebuffer(GL_FRAMEBUFFER, gFbo); glFinish();
    glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, out);
    GLenum e = glGetError(); if (e) fprintf(stderr, "[%s] %s GL error 0x%x\n", gName, hw ? "hw" : "sw", e);
    CGLSetCurrentContext(NULL); CGLDestroyContext(c);
}
static void dump(const char *path, const unsigned char *px) {
    FILE *f = fopen(path, "wb"); fprintf(f, "P6\n%d %d\n255\n", W, H);
    for (int y = H - 1; y >= 0; y--) for (int x = 0; x < W; x++) fwrite(px + (y * W + x) * 4, 1, 3, f);
    fclose(f);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        { CGLContextObj c = mkctx(1); CGLSetCurrentContext(c); printf("hw: %s | %s\n", glGetString(GL_RENDERER), glGetString(GL_VERSION));
          CGLSetCurrentContext(NULL); CGLDestroyContext(c); c = mkctx(0); CGLSetCurrentContext(c); printf("sw: %s | %s\n", glGetString(GL_RENDERER), glGetString(GL_VERSION)); CGLSetCurrentContext(NULL); CGLDestroyContext(c); }
        const char *dumpdir = getenv("GLDIFF_DUMP");
        int fails = 0, n = 0, reps = getenv("GLDIFF_REPS") ? atoi(getenv("GLDIFF_REPS")) : 1;
        for (int i = 0; i < (int)(sizeof T / sizeof T[0]); i++) {
            if (argc > 1 && !strstr(T[i].n, argv[1])) continue;
            static unsigned char hw[W * H * 4], sw[W * H * 4];
            run(0, i, sw);
            int worst = 0, bad = 0, badreps = 0;
            for (int r = 0; r < reps; r++) {
                run(1, i, hw); int b = 0;
                for (int k = 0; k < W * H; k++) { int d = 0; for (int ch = 0; ch < 4; ch++) { int x = abs(hw[k * 4 + ch] - sw[k * 4 + ch]); if (x > d) d = x; }
                    if (d > worst) worst = d; if (d > 3) b++; }
                if (b) { badreps++; if (b > bad) bad = b; }
            }
            n++;
            printf("%-30s %s  (%d px differ, max delta %d%s)\n", T[i].n, bad ? "FAIL" : "ok  ", bad, worst,
                   reps > 1 ? [[NSString stringWithFormat:@", %d/%d runs bad", badreps, reps] UTF8String] : "");
            if (bad) fails++;
            if (dumpdir && bad) { char p[512]; snprintf(p, sizeof p, "%s/%s.hw.ppm", dumpdir, T[i].n); dump(p, hw); snprintf(p, sizeof p, "%s/%s.sw.ppm", dumpdir, T[i].n); dump(p, sw); }
        }
        printf("%d/%d differ\n", fails, n);
        return fails ? 1 : 0;
    }
}
