// glfeat: the OpenGL features NullMoth 2.3.6's GL draw path makes work, each checked by reading pixels back.
// An offscreen GL 4.1 core context (Apple's GL-on-Metal over the NVMTL plugin) renders into a 64x64 RGBA8 FBO.
//   depthbias   a quad drawn over an identical quad with GL_LESS passes only through glPolygonOffset (depth bias)
//   provoking   a flat varying takes the LAST vertex's value (GL's default convention)
//   divisor     per-instance colour with glVertexAttribDivisor(…, 2): instances 0,1 share a colour, 2,3 the next
//   restart     a triangle strip with glPrimitiveRestartIndex(0xffff) enabled breaks at the restart index
//   texbuf      an isamplerBuffer over a GL_R8I buffer texture reads the bytes back (Minecraft 26's buffer textures)
//   texbuf32    a GL_R32F buffer texture through samplerBuffer
// Prints one line per test (PASS/FAIL + what was read) and the summary line "glfeat: N of 6 PASS".
//   cc -O2 -o glfeat glfeat.c -framework OpenGL
#define GL_SILENCE_DEPRECATION
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { W = 64, H = 64 };
static GLuint shader(GLenum type, const char *src) {
	GLuint s = glCreateShader(type); glShaderSource(s, 1, &src, NULL); glCompileShader(s);
	GLint ok = 0; glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
	if (!ok) { char log[1024]; glGetShaderInfoLog(s, sizeof log, NULL, log); fprintf(stderr, "shader: %s\n", log); exit(2); }
	return s;
}
static GLuint program(const char *vs, const char *fs) {
	GLuint p = glCreateProgram(); glAttachShader(p, shader(GL_VERTEX_SHADER, vs)); glAttachShader(p, shader(GL_FRAGMENT_SHADER, fs));
	glBindAttribLocation(p, 0, "pos"); glBindAttribLocation(p, 1, "col");
	glLinkProgram(p); GLint ok = 0; glGetProgramiv(p, GL_LINK_STATUS, &ok);
	if (!ok) { char log[1024]; glGetProgramInfoLog(p, sizeof log, NULL, log); fprintf(stderr, "link: %s\n", log); exit(2); }
	return p;
}
static void px(int x, int y, unsigned char out[4]) { glReadPixels(x, y, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, out); }
static int near(const unsigned char p[4], int r, int g, int b) { return abs(p[0] - r) <= 8 && abs(p[1] - g) <= 8 && abs(p[2] - b) <= 8; }
static void clear(void) { glClearColor(0, 0, 0, 1); glClearDepth(1); glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT); }

static const char *kVS =
	"#version 410\nin vec3 pos; in vec3 col; out vec3 vcol; uniform vec2 shift;\n"
	"void main() { vcol = col; gl_Position = vec4(pos.xy + shift, pos.z, 1.0); }\n";
static const char *kFS = "#version 410\nin vec3 vcol; out vec4 o; void main() { o = vec4(vcol, 1.0); }\n";

int main(void) {
	CGLPixelFormatAttribute attrs[] = { kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_GL4_Core, kCGLPFAAccelerated, 0 };
	CGLPixelFormatObj pf; GLint npf; CGLContextObj ctx;
	if (CGLChoosePixelFormat(attrs, &pf, &npf) || !pf || CGLCreateContext(pf, NULL, &ctx)) { printf("no GL 4.1 context\nglfeat: 0 of 6 PASS\n"); return 1; }
	CGLSetCurrentContext(ctx);
	GLuint fbo, rb[2]; glGenFramebuffers(1, &fbo); glGenRenderbuffers(2, rb);
	glBindRenderbuffer(GL_RENDERBUFFER, rb[0]); glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, W, H);
	glBindRenderbuffer(GL_RENDERBUFFER, rb[1]); glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, W, H);
	glBindFramebuffer(GL_FRAMEBUFFER, fbo);
	glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb[0]);
	glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, rb[1]);
	glViewport(0, 0, W, H);
	GLuint vao; glGenVertexArrays(1, &vao); glBindVertexArray(vao);
	GLuint vb, ib; glGenBuffers(1, &vb); glGenBuffers(1, &ib);
	int pass = 0; unsigned char p[4], q[4];

	// depthbias: red quad at z=0, then green quad at z=0 with GL_LESS: only a negative polygon offset lets it through
	{
		GLuint prog = program(kVS, kFS); glUseProgram(prog); glUniform2f(glGetUniformLocation(prog, "shift"), 0, 0);
		const float red[] = { -1,-1,0, 1,0,0,  1,-1,0, 1,0,0,  -1,1,0, 1,0,0,  1,1,0, 1,0,0 };
		const float grn[] = { -1,-1,0, 0,1,0,  1,-1,0, 0,1,0,  -1,1,0, 0,1,0,  1,1,0, 0,1,0 };
		glBindBuffer(GL_ARRAY_BUFFER, vb);
		glEnableVertexAttribArray(0); glEnableVertexAttribArray(1);
		clear(); glEnable(GL_DEPTH_TEST); glDepthFunc(GL_LESS);
		glBufferData(GL_ARRAY_BUFFER, sizeof red, red, GL_STATIC_DRAW);
		glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 24, 0); glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 24, (void *)12);
		glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
		glEnable(GL_POLYGON_OFFSET_FILL); glPolygonOffset(-1.0f, -4.0f);
		glBufferData(GL_ARRAY_BUFFER, sizeof grn, grn, GL_STATIC_DRAW);
		glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 24, 0); glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 24, (void *)12);
		glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
		glDisable(GL_POLYGON_OFFSET_FILL); glDisable(GL_DEPTH_TEST); glFinish();
		px(W / 2, H / 2, p); int ok = near(p, 0, 255, 0); pass += ok;
		printf("depthbias %s (centre %d,%d,%d: green = offset applied, red = ignored)\n", ok ? "PASS" : "FAIL", p[0], p[1], p[2]);
		glDeleteProgram(prog);
	}
	// provoking: flat colour of a triangle whose vertices are red, green, blue -> GL's default takes the last (blue)
	{
		const char *vs = "#version 410\nin vec3 pos; in vec3 col; flat out vec3 vcol; void main() { vcol = col; gl_Position = vec4(pos, 1.0); }\n";
		const char *fs = "#version 410\nflat in vec3 vcol; out vec4 o; void main() { o = vec4(vcol, 1.0); }\n";
		GLuint prog = program(vs, fs); glUseProgram(prog);
		const float tri[] = { -1,-1,0, 1,0,0,  3,-1,0, 0,1,0,  -1,3,0, 0,0,1 };
		glBindBuffer(GL_ARRAY_BUFFER, vb); glBufferData(GL_ARRAY_BUFFER, sizeof tri, tri, GL_STATIC_DRAW);
		glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 24, 0); glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 24, (void *)12);
		// indexed, as the renderer's index rewrite only ever touched indexed draws
		const unsigned short idx[] = { 0, 1, 2 };
		glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ib); glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof idx, idx, GL_STATIC_DRAW);
		clear(); glDrawElements(GL_TRIANGLES, 3, GL_UNSIGNED_SHORT, 0); glFinish();
		px(W / 4, H / 4, p);
		clear(); glDrawArrays(GL_TRIANGLES, 0, 3); glFinish(); px(W / 4, H / 4, q);
		int ok = near(p, 0, 0, 255) && near(q, 0, 0, 255); pass += ok;
		printf("provoking %s (indexed %d,%d,%d / arrays %d,%d,%d: blue = last vertex)\n", ok ? "PASS" : "FAIL", p[0], p[1], p[2], q[0], q[1], q[2]);
		glDeleteProgram(prog);
	}
	// divisor: 4 instances side by side, per-instance colour with divisor 2 -> red red green green
	{
		const char *vs = "#version 410\nin vec3 pos; in vec3 col; out vec3 vcol;\n"
			"void main() { vcol = col; gl_Position = vec4(pos.x * 0.25 - 0.75 + 0.5 * float(gl_InstanceID), pos.y, 0.0, 1.0); }\n";
		GLuint prog = program(vs, kFS); glUseProgram(prog);
		const float quad[] = { -1,-1,0, 1,-1,0, -1,1,0, 1,1,0 };
		const float cols[] = { 1,0,0, 0,1,0, 0,0,1, 1,1,1 };
		GLuint cb; glGenBuffers(1, &cb);
		glBindBuffer(GL_ARRAY_BUFFER, vb); glBufferData(GL_ARRAY_BUFFER, sizeof quad, quad, GL_STATIC_DRAW);
		glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 12, 0);
		glBindBuffer(GL_ARRAY_BUFFER, cb); glBufferData(GL_ARRAY_BUFFER, sizeof cols, cols, GL_STATIC_DRAW);
		glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 12, 0); glVertexAttribDivisor(1, 2);
		clear(); glDrawArraysInstanced(GL_TRIANGLE_STRIP, 0, 4, 4); glFinish();
		unsigned char c[4][4]; for (int i = 0; i < 4; i++) px(W / 8 + i * W / 4, H / 2, c[i]);
		int ok = near(c[0], 255, 0, 0) && near(c[1], 255, 0, 0) && near(c[2], 0, 255, 0) && near(c[3], 0, 255, 0); pass += ok;
		printf("divisor %s (instances %d,%d,%d | %d,%d,%d | %d,%d,%d | %d,%d,%d: want red red green green)\n", ok ? "PASS" : "FAIL",
		       c[0][0], c[0][1], c[0][2], c[1][0], c[1][1], c[1][2], c[2][0], c[2][1], c[2][2], c[3][0], c[3][1], c[3][2]);
		glVertexAttribDivisor(1, 0); glDeleteBuffers(1, &cb); glDeleteProgram(prog);
	}
	// restart: a strip of two separate quads joined by 0xffff; with restart on, the gap between them stays black
	{
		GLuint prog = program(kVS, kFS); glUseProgram(prog); glUniform2f(glGetUniformLocation(prog, "shift"), 0, 0);
		const float v[] = { -1,-1,0, 1,1,1, -0.5f,-1,0, 1,1,1, -1,1,0, 1,1,1, -0.5f,1,0, 1,1,1,
		                    0.5f,-1,0, 1,1,1, 1,-1,0, 1,1,1, 0.5f,1,0, 1,1,1, 1,1,0, 1,1,1 };
		const unsigned short idx[] = { 0, 1, 2, 3, 0xffff, 4, 5, 6, 7 };
		glBindBuffer(GL_ARRAY_BUFFER, vb); glBufferData(GL_ARRAY_BUFFER, sizeof v, v, GL_STATIC_DRAW);
		glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 24, 0); glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 24, (void *)12);
		glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ib); glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof idx, idx, GL_STATIC_DRAW);
		glEnable(GL_PRIMITIVE_RESTART); glPrimitiveRestartIndex(0xffff);
		clear(); glDrawElements(GL_TRIANGLE_STRIP, 9, GL_UNSIGNED_SHORT, 0); glFinish();
		glDisable(GL_PRIMITIVE_RESTART);
		unsigned char l[4], m[4], r[4]; px(W / 8, H / 2, l); px(W / 2, H / 2, m); px(W - W / 16, H / 2, r);
		int ok = near(l, 255, 255, 255) && near(m, 0, 0, 0) && near(r, 255, 255, 255); pass += ok;
		printf("restart %s (left %d / gap %d / right %d: want white, black, white)\n", ok ? "PASS" : "FAIL", l[0], m[0], r[0]);
		glDeleteProgram(prog);
	}
	// texbuf: an R8I buffer texture read through isamplerBuffer by texelFetch; the quad's colour is byte 5 (=200) / 255
	{
		const char *vs = "#version 410\nin vec3 pos; void main() { gl_Position = vec4(pos, 1.0); }\n";
		const char *fs = "#version 410\nuniform isamplerBuffer tb; out vec4 o;\n"
			"void main() { int v = texelFetch(tb, 5).r; o = vec4(float(v) / 127.0, float(texelFetch(tb, 2).r) / 127.0, 0.0, 1.0); }\n";
		GLuint prog = program(vs, fs); glUseProgram(prog);
		const signed char bytes[16] = { 0, 1, 64, 3, 4, 100, 6, 7 };
		GLuint tbo, tex; glGenBuffers(1, &tbo); glBindBuffer(GL_TEXTURE_BUFFER, tbo); glBufferData(GL_TEXTURE_BUFFER, sizeof bytes, bytes, GL_STATIC_DRAW);
		glGenTextures(1, &tex); glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_BUFFER, tex); glTexBuffer(GL_TEXTURE_BUFFER, GL_R8I, tbo);
		glUniform1i(glGetUniformLocation(prog, "tb"), 0);
		const float quad[] = { -1,-1,0, 1,-1,0, -1,1,0, 1,1,0 };
		glBindBuffer(GL_ARRAY_BUFFER, vb); glBufferData(GL_ARRAY_BUFFER, sizeof quad, quad, GL_STATIC_DRAW);
		glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 12, 0); glDisableVertexAttribArray(1);
		clear(); glDrawArrays(GL_TRIANGLE_STRIP, 0, 4); glFinish(); px(W / 2, H / 2, p);
		int ok = near(p, 201, 129, 0); pass += ok;   // 100/127, 64/127
		printf("texbuf %s (centre %d,%d,%d: want 201,129,0)\n", ok ? "PASS" : "FAIL", p[0], p[1], p[2]);
		glDeleteTextures(1, &tex); glDeleteBuffers(1, &tbo); glDeleteProgram(prog);
	}
	// texbuf32: a GL_R32F buffer texture through samplerBuffer (Minecraft 26's other buffer-texture format)
	{
		const char *vs = "#version 410\nin vec3 pos; void main() { gl_Position = vec4(pos, 1.0); }\n";
		const char *fs = "#version 410\nuniform samplerBuffer tb; out vec4 o;\n"
			"void main() { o = vec4(texelFetch(tb, 3).r, texelFetch(tb, 1).r, 0.0, 1.0); }\n";
		GLuint prog = program(vs, fs); glUseProgram(prog);
		const float vals[8] = { 0.1f, 0.25f, 0.3f, 0.75f, 0.5f, 0.6f, 0.7f, 0.8f };
		GLuint tbo, tex; glGenBuffers(1, &tbo); glBindBuffer(GL_TEXTURE_BUFFER, tbo); glBufferData(GL_TEXTURE_BUFFER, sizeof vals, vals, GL_STATIC_DRAW);
		glGenTextures(1, &tex); glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_BUFFER, tex); glTexBuffer(GL_TEXTURE_BUFFER, GL_R32F, tbo);
		glUniform1i(glGetUniformLocation(prog, "tb"), 0);
		const float quad[] = { -1,-1,0, 1,-1,0, -1,1,0, 1,1,0 };
		glBindBuffer(GL_ARRAY_BUFFER, vb); glBufferData(GL_ARRAY_BUFFER, sizeof quad, quad, GL_STATIC_DRAW);
		glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 12, 0);
		clear(); glDrawArrays(GL_TRIANGLE_STRIP, 0, 4); glFinish(); px(W / 2, H / 2, p);
		int ok = near(p, 191, 64, 0); pass += ok;
		printf("texbuf32 %s (centre %d,%d,%d: want 191,64,0)\n", ok ? "PASS" : "FAIL", p[0], p[1], p[2]);
		glDeleteTextures(1, &tex); glDeleteBuffers(1, &tbo); glDeleteProgram(prog);
	}
	GLenum err = glGetError();
	printf("glfeat: %d of 6 PASS (glGetError 0x%x)\n", pass, err);
	return pass == 6 ? 0 : 1;
}
